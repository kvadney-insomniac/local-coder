#!/usr/bin/env bash
# continuous-audit-loop.sh — Periodically scan the codebase and file GitHub
# issues for dead code, incomplete code, and quality smells.
#
# Modeled on audit-fix-loop.sh, but:
#   - Scanner = deterministic static-analysis tools (no LLM cost)
#   - Output = GitHub issues on the project board, not a markdown audit doc
#   - Loop never "finishes" — it runs indefinitely on AUDIT_INTERVAL seconds
#
# Usage:
#   nohup bash scripts/continuous-audit-loop.sh \
#        > /tmp/continuous-audit-loop.log 2>&1 &
#
# Env knobs:
#   AUDIT_INTERVAL    seconds between scans (default 21600 = 6h)
#   AUDIT_MAX_NEW     cap on issues filed per round (default 10)
#   AUDIT_DRY_RUN     "1" to skip issue creation (default "0")
#
# Discipline (mirrors other local-coder loops):
#   - PID lock at logs/continuous-audit-loop.pid — refuses dup start
#   - CPU/mem gates from board-lib before each scan
#   - Cleanup trap kills children, removes PID file on exit

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=board-lib.sh
source "${SCRIPT_DIR}/board-lib.sh"

# PID file lives in /tmp so it survives parallel board workers that nuke
# logs/ during their cleanup passes (observed 2026-05-21).
PID_FILE="/tmp/continuous-audit-loop.pid"
LOG="${BOARD_LOGS_DIR}/continuous-audit-loop.log"

AUDIT_INTERVAL="${AUDIT_INTERVAL:-21600}"   # 6h default
AUDIT_MAX_NEW="${AUDIT_MAX_NEW:-10}"
AUDIT_DRY_RUN="${AUDIT_DRY_RUN:-0}"

# Self-heal the logs dir on every call — another worker may have rm-rf'd it.
ensure_logs_dir() {
    mkdir -p "${BOARD_LOGS_DIR}" 2>/dev/null || true
}

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    ensure_logs_dir
    echo "[${ts}] $*" | tee -a "${LOG}"
}

# --------------------------------------------------------------------------
# Lock — refuse to start if a live previous loop is already running.
# --------------------------------------------------------------------------
if [[ -f "${PID_FILE}" ]]; then
    old_pid=$(cat "${PID_FILE}" 2>/dev/null || echo "")
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        log "ABORT: continuous-audit-loop already running (PID ${old_pid})."
        exit 1
    fi
    log "Stale PID file (PID ${old_pid:-?} not alive) — removing."
    rm -f "${PID_FILE}"
fi
echo $$ > "${PID_FILE}"

cleanup() {
    log "cleanup: removing PID file"
    rm -f "${PID_FILE}"
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
log "════════════════════════════════════════════════════════"
log "continuous-audit-loop started (interval=${AUDIT_INTERVAL}s, "
log "  max-new=${AUDIT_MAX_NEW}, dry-run=${AUDIT_DRY_RUN}, PID $$)"
log "════════════════════════════════════════════════════════"

round=1
while true; do
    log "─── ROUND ${round} ──────────────────────────────────────────"

    # Resource gates — don't pile onto a saturated machine.
    board_wait_for_cpu
    board_wait_for_memory

    # 1. Scan — produces a findings JSON path on stdout.
    findings_path=$(bash "${SCRIPT_DIR}/audit-scan.sh" 2>>"${LOG}" | tail -1)
    if [[ -z "${findings_path}" || ! -f "${findings_path}" ]]; then
        log "ERROR: audit-scan did not produce a findings file; skipping round."
    else
        log "scan complete → ${findings_path}"

        # 2. File issues (dry-run unless AUDIT_DRY_RUN=0)
        apply_flag=""
        [[ "${AUDIT_DRY_RUN}" == "0" ]] && apply_flag="--apply"
        python3 "${SCRIPT_DIR}/audit-file-issues.py" \
            "${findings_path}" \
            --max-new "${AUDIT_MAX_NEW}" \
            ${apply_flag} 2>&1 | tee -a "${LOG}"
    fi

    log "round ${round} done — sleeping ${AUDIT_INTERVAL}s"
    round=$((round + 1))
    sleep "${AUDIT_INTERVAL}"
done
