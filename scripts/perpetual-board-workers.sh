#!/usr/bin/env bash
# perpetual-board-workers.sh — Respawn supervisor for board workers.
#
# Wraps each named worker in board-worker.sh in a forever loop, sleeping
# between iterations so an empty board doesn't burn CPU or GitHub API quota.
# Each worker respawns independently.
#
# Usage:
#   bash scripts/perpetual-board-workers.sh            # launch supervisors
#   bash scripts/perpetual-board-workers.sh --stop     # kill supervisors + workers
#   bash scripts/perpetual-board-workers.sh --status   # show alive supervisors
#
# Idle backoff: if a batch completes 0 tasks (likely no claimable work),
# sleep IDLE_SLEEP before respawning. If tasks ran, sleep ACTIVE_SLEEP.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
WORKER="${SCRIPT_DIR}/board-worker.sh"
PIDS_FILE="${LOG_DIR}/perpetual-supervisor-pids.txt"
STOP_MARKER="${LOG_DIR}/supervisors-stopped.marker"

mkdir -p "${LOG_DIR}"

IDLE_SLEEP="${IDLE_SLEEP:-180}"
ACTIVE_SLEEP="${ACTIVE_SLEEP:-30}"

# Allow healthcheck to source this script for run_supervisor + WORKER_CONFIGS
# without executing the launch logic.
: "${PERPETUAL_SOURCE_ONLY:=0}"

declare -a WORKER_CONFIGS=(
    "ideas-triage:ideas:both"
    "backlog-backend:backlog:backend"
    "backlog-backend-2:backlog:backend"
    "backlog-backend-3:backlog:backend"
    "backlog-frontend:backlog:frontend"
    "staging-verifier:verify-staging:both"
    "rescue-backend:rescue:backend"
    "reap-both:reap:both"
)

# --------------------------------------------------------------------------
# --stop
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--stop" ]]; then
    echo "Stopping perpetual supervisors..."
    if [[ -f "${PIDS_FILE}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            NAME="${line%%=*}"; PID="${line##*=}"
            if kill -0 "${PID}" 2>/dev/null; then
                kill "${PID}" 2>/dev/null && echo "  Stopped supervisor ${NAME} (PID ${PID})"
            fi
        done < "${PIDS_FILE}"
        rm -f "${PIDS_FILE}"
    fi
    pkill -f "perpetual-board-workers.sh" 2>/dev/null || true
    pkill -f "board-worker.sh" 2>/dev/null || true
    touch "${STOP_MARKER}"
    echo "Done. (intentional-stop marker created)"
    exit 0
fi

# --------------------------------------------------------------------------
# --status
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--status" ]]; then
    echo "=== Perpetual Supervisor Status ==="
    if [[ -f "${PIDS_FILE}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            NAME="${line%%=*}"; PID="${line##*=}"
            if kill -0 "${PID}" 2>/dev/null; then
                ETIME=$(ps -o etime= -p "$PID" 2>/dev/null | tr -d ' ')
                echo "  [alive ${ETIME}] ${NAME} (PID ${PID})"
            else
                echo "  [DEAD] ${NAME} (PID ${PID})"
            fi
        done < "${PIDS_FILE}"
    else
        echo "  (no supervisors registered)"
    fi
    echo ""
    echo "Active board-worker.sh processes:"
    ps aux | grep "board-worker.sh" | grep -v grep | awk '{print "  PID="$2, $(NF-3), $(NF-2), $(NF-1), $NF}' || echo "  (none)"
    exit 0
fi

# --------------------------------------------------------------------------
# Supervisor loop for a single worker name.
# Runs in a subprocess; respawns board-worker.sh forever with idle backoff.
# --------------------------------------------------------------------------
run_supervisor() {
    local NAME="$1" MODE="$2" TARGET="$3"
    local LOG="${LOG_DIR}/${NAME}.log"
    local SUP_LOG="${LOG_DIR}/${NAME}.supervisor.log"
    local COMPLETED_FILE="${LOG_DIR}/${NAME}.board-completed.txt"

    echo "[$(date '+%F %T')] supervisor start name=${NAME} mode=${MODE} target=${TARGET}" >> "${SUP_LOG}"

    while true; do
        local BEFORE=0 AFTER=0
        if [[ -f "${COMPLETED_FILE}" ]]; then
            BEFORE=$(grep -c '^[0-9]' "${COMPLETED_FILE}" 2>/dev/null || true)
            BEFORE=${BEFORE:-0}
        fi

        BOARD_WORKER_NAME="${NAME}" bash "${WORKER}" \
            --mode "${MODE}" \
            --target "${TARGET}" \
            >> "${LOG}" 2>&1

        if [[ -f "${COMPLETED_FILE}" ]]; then
            AFTER=$(grep -c '^[0-9]' "${COMPLETED_FILE}" 2>/dev/null || true)
            AFTER=${AFTER:-0}
        fi
        local DELTA=$(( AFTER - BEFORE ))

        if [[ "$DELTA" -gt 0 ]]; then
            echo "[$(date '+%F %T')] batch done delta=${DELTA} active_sleep=${ACTIVE_SLEEP}" >> "${SUP_LOG}"
            sleep "${ACTIVE_SLEEP}"
        else
            echo "[$(date '+%F %T')] batch idle (no claims) idle_sleep=${IDLE_SLEEP}" >> "${SUP_LOG}"
            sleep "${IDLE_SLEEP}"
        fi
    done
}

# --------------------------------------------------------------------------
# Healthcheck source-only mode: function definitions are now in scope, so
# return to caller without executing the launch logic below.
# --------------------------------------------------------------------------
if [[ "${PERPETUAL_SOURCE_ONLY}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# --------------------------------------------------------------------------
# Bail out if supervisors already running
# --------------------------------------------------------------------------
if [[ -f "${PIDS_FILE}" ]]; then
    ALIVE=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        PID="${line##*=}"
        kill -0 "${PID}" 2>/dev/null && ALIVE=$((ALIVE+1))
    done < "${PIDS_FILE}"
    if [[ "$ALIVE" -gt 0 ]]; then
        echo "ERROR: ${ALIVE} supervisor(s) already running. Stop first:"
        echo "  bash $0 --stop"
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# Launch one supervisor per worker config
# --------------------------------------------------------------------------
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Perpetual board worker supervisors — launching             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Started:       $(date)"
echo "  Supervisors:   ${#WORKER_CONFIGS[@]}"
echo "  Idle sleep:    ${IDLE_SLEEP}s   (between idle batches)"
echo "  Active sleep:  ${ACTIVE_SLEEP}s  (between productive batches)"
echo ""

rm -f "${STOP_MARKER}"
printf "# Perpetual supervisor PIDs — launched %s\n" "$(date)" > "${PIDS_FILE}"

for CONFIG in "${WORKER_CONFIGS[@]}"; do
    NAME="${CONFIG%%:*}"
    REM="${CONFIG#*:}"
    MODE="${REM%%:*}"
    TARGET="${REM#*:}"

    (
        # Re-exec this script as a supervisor for one worker.
        # Using `bash -c` keeps the supervisor independent of the parent shell.
        run_supervisor "${NAME}" "${MODE}" "${TARGET}"
    ) > "${LOG_DIR}/${NAME}.supervisor.stdout.log" 2>&1 &

    PID=$!
    echo "${NAME}=${PID}" >> "${PIDS_FILE}"
    echo "  ✓ ${NAME}  PID=${PID}  mode=${MODE}  target=${TARGET}"
    sleep 5
done

echo ""
echo "  PIDs:    ${PIDS_FILE}"
echo "  Status:  bash $0 --status"
echo "  Stop:    bash $0 --stop"
