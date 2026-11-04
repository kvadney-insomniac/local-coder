#!/usr/bin/env bash
# memory-watchdog.sh - Periodic memory pressure monitor.
# Pauses local-coder workers when the system is thrashing, resumes when pressure drops.
#
# Run via launchd (com.your-project.memory-watchdog.plist) or manually:
#   while true; do bash memory-watchdog.sh; sleep 120; done

set -uo pipefail

LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs"
LOG_FILE="${LOG_DIR}/memory-watchdog.log"
PAUSE_FLAG="/tmp/local-coder-paused.flag"

mkdir -p "${LOG_DIR}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"; }

TOTAL_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
COMPRESSOR_PAGES=$(vm_stat | awk '/stored in compressor/{gsub(/\./,"",$5); print $5}')
COMPRESSOR_MB=$(( ${COMPRESSOR_PAGES:-0} * 4096 / 1024 / 1024 ))
THRESHOLD=$(( TOTAL_MB / 2 ))

if [[ "${COMPRESSOR_MB}" -gt "${THRESHOLD}" ]]; then
    log "MEMORY PRESSURE: ${COMPRESSOR_MB}MB compressed / ${TOTAL_MB}MB total (threshold: ${THRESHOLD}MB)"

    # Kill orphan browsers and vitest first - cheapest way to free memory
    CHROME_COUNT=$(pgrep -f "chrome-headless-shell" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${CHROME_COUNT:-0}" -gt 0 ]]; then
        pgrep -f "chrome-headless-shell" | xargs kill 2>/dev/null || true
        log "Killed ${CHROME_COUNT} orphan chrome-headless-shell processes"
    fi

    VITEST_COUNT=$(pgrep -c -f 'vitest' 2>/dev/null || echo 0)
    if [[ "${VITEST_COUNT:-0}" -gt 4 ]]; then
        pkill -f vitest 2>/dev/null || true
        log "Killed ${VITEST_COUNT} orphan vitest processes"
    fi

    # Report Claude Desktop memory if running
    if pgrep -f "Claude.app" >/dev/null 2>&1; then
        CLAUDE_PID=$(pgrep -f "Claude Helper" 2>/dev/null | head -1)
        if [[ -n "${CLAUDE_PID}" ]]; then
            CLAUDE_RSS_KB=$(ps -o rss= -p "${CLAUDE_PID}" 2>/dev/null | tr -d ' ')
            log "Claude Desktop Helper RSS: $(( ${CLAUDE_RSS_KB:-0} / 1024 ))MB - consider quitting it"
        fi
    fi

    # Pause overnight workers (SIGSTOP) - they resume when memory frees
    WORKER_PIDS=$(pgrep -f "run-local-overnight.sh" 2>/dev/null || true)
    if [[ -n "${WORKER_PIDS}" ]]; then
        log "Pausing local-coder workers: $(echo ${WORKER_PIDS} | tr '\n' ' ')"
        echo "${WORKER_PIDS}" | xargs kill -STOP 2>/dev/null || true
        date > "${PAUSE_FLAG}"
    fi
else
    # If workers were paused, resume them
    if [[ -f "${PAUSE_FLAG}" ]]; then
        PAUSED_SINCE=$(cat "${PAUSE_FLAG}")
        log "Memory pressure resolved (${COMPRESSOR_MB}MB compressed) - resuming workers (paused since ${PAUSED_SINCE})"
        pgrep -f "run-local-overnight.sh" | xargs kill -CONT 2>/dev/null || true
        rm -f "${PAUSE_FLAG}"
    fi
fi

# Rotate watchdog log if >5MB
LOG_SIZE=$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo 0)
if [[ "${LOG_SIZE}" -gt 5242880 ]]; then
    mv "${LOG_FILE}" "${LOG_FILE}.$(date +%Y%m%d).bak"
fi
