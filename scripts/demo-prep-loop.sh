#!/usr/bin/env bash
# demo-prep-loop.sh - Infinite improvement loop for 5/8 customer demo readiness.
#
# How it works:
#   1. Starts at round 87 (rounds 1-86 already completed)
#   2. Runs run-local-overnight.sh with each round's queue file
#   3. The last task in every queue (p3-generate-next-round) writes the NEXT
#      round's queue file - that's what makes this loop infinite
#   4. After each round completes, increments round counter and waits for
#      the next queue file to appear (written by the meta-task)
#   5. Stops automatically on or after 2026-05-08 (post-demo date)
#
# Launch (recommended):
#   nohup bash scripts/demo-prep-loop.sh \
#     > logs/demo-prep-$(date +%Y%m%d-%H%M%S).log 2>&1 &
#   echo "Demo prep loop PID=$!"
#
# Monitor:
#   tail -f logs/demo-prep-*.log
#
# Stop:
#   kill <PID>   # or kill $(pgrep -f demo-prep-loop.sh)
#
# State:
#   - Completed tasks: logs/completed.txt (shared with overnight runner)
#   - Per-round logs: logs/round-N-TIMESTAMP.log
#   - Queue files: queues/queue-round-N.yaml

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:?REPO_ROOT must be set - source config/config.sh first}"
OVERNIGHT="${SCRIPT_DIR}/run-local-overnight.sh"
LOGS_DIR="${SCRIPT_DIR}/logs"
DEMO_DATE="2026-05-08"

mkdir -p "${LOGS_DIR}"

# --------------------------------------------------------------------------
# PID lock - prevent duplicate instances from stacking up as orphans.
# If another demo-prep-loop is already running, refuse to start.
# --------------------------------------------------------------------------
PID_FILE="${LOGS_DIR}/demo-prep-loop.pid"
if [[ -f "${PID_FILE}" ]]; then
    OLD_PID=$(cat "${PID_FILE}" 2>/dev/null || echo "")
    if [[ -n "${OLD_PID}" ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: demo-prep-loop already running (PID ${OLD_PID}). Exiting to prevent orphan accumulation."
        echo "  To restart: kill ${OLD_PID} first, then re-run."
        exit 1
    fi
fi
echo "$$" > "${PID_FILE}"

# --------------------------------------------------------------------------
# Cleanup: remove PID file and kill the active overnight runner on exit.
# --------------------------------------------------------------------------
CURRENT_OVERNIGHT_PID=""
_demo_prep_cleanup() {
    rm -f "${PID_FILE}" 2>/dev/null || true
    if [[ -n "${CURRENT_OVERNIGHT_PID:-}" ]]; then
        kill -- "-${CURRENT_OVERNIGHT_PID}" 2>/dev/null || kill "${CURRENT_OVERNIGHT_PID}" 2>/dev/null || true
        wait "${CURRENT_OVERNIGHT_PID}" 2>/dev/null || true
    fi
}
trap '_demo_prep_cleanup' EXIT INT TERM HUP

# Starting round - rounds 1-86 are in HARDCODED_SKIP in run-local-overnight.sh
# Round 87 is the first new round created by this plan
START_ROUND="${START_ROUND:-87}"

# Max wait for a queue file to appear after the meta-task generates it (30 min)
MAX_WAIT_SECONDS=1800

# --------------------------------------------------------------------------
# Logging helper
# --------------------------------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*"
}

# --------------------------------------------------------------------------
# Check if we're past the demo date
# --------------------------------------------------------------------------
past_demo_date() {
    [[ "$(date +%Y-%m-%d)" > "${DEMO_DATE}" ]]
}

# --------------------------------------------------------------------------
# Wait for a queue file to appear (the meta-task writes it)
# Polls every 60s up to MAX_WAIT_SECONDS
# --------------------------------------------------------------------------
wait_for_queue() {
    local queue_file="$1"
    local waited=0

    if [[ -f "${queue_file}" ]]; then
        return 0
    fi

    log "Waiting for queue file: ${queue_file}"
    while [[ ! -f "${queue_file}" ]] && [[ $waited -lt $MAX_WAIT_SECONDS ]]; do
        sleep 60
        waited=$((waited + 60))
        log "  Still waiting... (${waited}s / ${MAX_WAIT_SECONDS}s)"
    done

    if [[ ! -f "${queue_file}" ]]; then
        log "ERROR: Queue file never appeared after ${MAX_WAIT_SECONDS}s: ${queue_file}"
        return 1
    fi

    log "Queue file ready: ${queue_file}"
    return 0
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
ROUND="${START_ROUND}"
LOOP_START=$(date +%s)

log "╔══════════════════════════════════════════════════════════════╗"
log "║          Demo-Prep Infinite Loop - Starting                  ║"
log "╚══════════════════════════════════════════════════════════════╝"
log "  Demo date:   ${DEMO_DATE}"
log "  Start round: ${ROUND}"
log "  Repo root:   ${REPO_ROOT}"
log "  Logs dir:    ${LOGS_DIR}/"
log ""

while true; do
    # ------------------------------------------------------------------
    # Stop condition: past demo date
    # ------------------------------------------------------------------
    if past_demo_date; then
        log "Demo date ${DEMO_DATE} reached - loop complete. Great work!"
        log "Total rounds run: $((ROUND - START_ROUND))"
        exit 0
    fi

    # ------------------------------------------------------------------
    # Locate queue file for this round
    # ------------------------------------------------------------------
    QUEUE_FILE="${SCRIPT_DIR}/overnight-queue-round-${ROUND}.yaml"

    if ! wait_for_queue "${QUEUE_FILE}"; then
        log "FATAL: Could not find queue for round ${ROUND} - exiting."
        log "To continue manually: QUEUE=${QUEUE_FILE} bash ${OVERNIGHT}"
        exit 1
    fi

    # ------------------------------------------------------------------
    # Reset the meta-task in completed.txt so it always re-runs each round.
    # The meta-task id "p3-generate-next-round" is a fixed string shared
    # across all rounds - without this, it gets skipped after round 1 runs it.
    # ------------------------------------------------------------------
    COMPLETED_FILE="${LOGS_DIR}/completed.txt"
    if [[ -f "${COMPLETED_FILE}" ]]; then
        # Remove the line in-place (BSD sed on macOS requires -i '')
        sed -i '' '/^p3-generate-next-round$/d' "${COMPLETED_FILE}" 2>/dev/null || \
            sed -i '/^p3-generate-next-round$/d' "${COMPLETED_FILE}"
        log "  Cleared p3-generate-next-round from completed.txt (will re-run for round ${ROUND})"
    fi

    # ------------------------------------------------------------------
    # Run the round
    # ------------------------------------------------------------------
    ROUND_LOG="${LOGS_DIR}/round-${ROUND}-$(date +%Y%m%d-%H%M%S).log"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "ROUND ${ROUND}: Starting - queue: $(basename ${QUEUE_FILE})"
    log "  Log: ${ROUND_LOG}"
    log ""

    ROUND_START=$(date +%s)

    # Run overnight runner with this round's queue file
    # QUEUE env var is picked up by run-local-overnight.sh (patched to support it)
    QUEUE="${QUEUE_FILE}" bash "${OVERNIGHT}" 2>&1 | tee "${ROUND_LOG}" &
    CURRENT_OVERNIGHT_PID=$!
    wait "${CURRENT_OVERNIGHT_PID}" || true
    ROUND_EXIT=$?
    CURRENT_OVERNIGHT_PID=""

    ROUND_END=$(date +%s)
    ROUND_ELAPSED=$(( (ROUND_END - ROUND_START) / 60 ))

    if [[ $ROUND_EXIT -eq 0 ]]; then
        log "ROUND ${ROUND}: Completed successfully in ${ROUND_ELAPSED}min"
    else
        log "ROUND ${ROUND}: Finished with failures (exit ${ROUND_EXIT}) after ${ROUND_ELAPSED}min"
        log "  Some tasks may have failed - check ${ROUND_LOG}"
        log "  Continuing to next round anyway (failures are non-fatal)"
    fi

    # ------------------------------------------------------------------
    # Check demo date again before continuing
    # ------------------------------------------------------------------
    if past_demo_date; then
        log "Demo date reached after round ${ROUND} - stopping."
        exit 0
    fi

    # ------------------------------------------------------------------
    # Advance to next round
    # ------------------------------------------------------------------
    ROUND=$((ROUND + 1))
    log "Advancing to round ${ROUND}..."
    log "(The meta-task in round $((ROUND - 1)) should have generated overnight-queue-round-${ROUND}.yaml)"
    log ""
done
