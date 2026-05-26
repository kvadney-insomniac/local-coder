#!/usr/bin/env bash
# continuous-audit-supervisor.sh — Keep continuous-audit-loop.sh alive forever.
#
# Background: on 2026-05-21 the inner loop died mid-sleep because a parallel
# board-worker wiped logs/, breaking later log writes. The
# supervisor sits *outside* that directory dependency: its own PID + log live
# in /tmp so it survives any cleanup the workers do to the repo tree.
#
# Behavior: until-loop that re-execs continuous-audit-loop.sh after any exit,
# with a 30s backoff. On SIGTERM/SIGINT it kills the child and exits cleanly.
#
# Usage:
#   AUDIT_DRY_RUN=0 AUDIT_MAX_NEW=10 AUDIT_INTERVAL=21600 \
#     nohup bash scripts/continuous-audit-supervisor.sh \
#     > /tmp/continuous-audit-supervisor.out 2>&1 &

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="${SCRIPT_DIR}/continuous-audit-loop.sh"
SUP_PID_FILE="/tmp/continuous-audit-supervisor.pid"
SUP_LOG="/tmp/continuous-audit-supervisor.log"

sup_log() { echo "[$(date '+%F %T')] [supervisor] $*" | tee -a "${SUP_LOG}"; }

# Reject duplicate supervisor.
if [[ -f "${SUP_PID_FILE}" ]]; then
    old=$(cat "${SUP_PID_FILE}" 2>/dev/null || echo "")
    if [[ -n "${old}" ]] && kill -0 "${old}" 2>/dev/null; then
        sup_log "ABORT: supervisor already running (PID ${old})."
        exit 1
    fi
    rm -f "${SUP_PID_FILE}"
fi
echo $$ > "${SUP_PID_FILE}"

CHILD_PID=""
shutdown() {
    sup_log "received signal — killing child ${CHILD_PID:-?} and exiting"
    if [[ -n "${CHILD_PID}" ]] && kill -0 "${CHILD_PID}" 2>/dev/null; then
        kill -TERM "${CHILD_PID}" 2>/dev/null || true
        wait "${CHILD_PID}" 2>/dev/null || true
    fi
    rm -f "${SUP_PID_FILE}"
    exit 0
}
trap shutdown INT TERM
trap 'rm -f "${SUP_PID_FILE}"' EXIT

sup_log "════════════════════════════════════════════"
sup_log "supervisor started (PID $$) — wrapping ${LOOP}"
sup_log "════════════════════════════════════════════"

restart_count=0
while true; do
    sup_log "starting loop (restart_count=${restart_count})"
    # Run the loop in the foreground so we wait for it. Pass-through env vars.
    bash "${LOOP}" &
    CHILD_PID=$!
    sup_log "loop PID=${CHILD_PID}"
    wait "${CHILD_PID}"
    exit_code=$?
    sup_log "loop exited code=${exit_code} — backing off 30s then restarting"
    restart_count=$((restart_count + 1))
    sleep 30
done
