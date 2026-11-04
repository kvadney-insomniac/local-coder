#!/usr/bin/env bash
# launch-board-workers.sh - Launch board-driven local coder workers.
#
# Replaces launch-overnight.sh for board-driven mode. Instead of static YAML
# queues, workers pull tasks directly from the GitHub project board.
#
# Usage:
#   bash scripts/launch-board-workers.sh              # launch all workers
#   bash scripts/launch-board-workers.sh --dry-run    # print without executing
#   bash scripts/launch-board-workers.sh --stop       # kill all running workers
#   bash scripts/launch-board-workers.sh --status     # show running workers
#
# Workers launched:
#   1. ideas-triage       - Ideas → Backlog (both repos)
#   2. backlog-backend    - Backlog → implement → PR (backend only)
#   3. backlog-frontend   - Backlog → implement → PR (frontend only)
#   4. staging-verifier   - "ui testing in staging" → verify → comment
#   5. rescue-backend     - In Progress backend PRs with CI-red → fix & push (author-filtered)
#   6. reap-both          - In Progress orphans (no branch/PR/assignee) → return to Backlog
#
# Monitor:
#   tail -f logs/ideas-triage.log
#   tail -f logs/backlog-*.log

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PIDS_FILE="${LOG_DIR}/board-worker-pids.txt"
WORKER="${SCRIPT_DIR}/board-worker.sh"

mkdir -p "${LOG_DIR}"

# --------------------------------------------------------------------------
# Pre-launch cleanup: reclaim memory from stale processes and Docker cruft
# --------------------------------------------------------------------------
if [[ "${1:-}" != "--stop" ]] && [[ "${1:-}" != "--status" ]]; then
    echo "Pre-launch cleanup..."

    # Kill claude processes older than 3 hours (orphans from previous worker sessions)
    STALE_CLAUDE_PIDS=$(ps -eo pid,etime,comm | grep -E "claude$" | grep -v grep | awk '{
        split($2, t, /:/);
        if (length(t) == 3 && t[1] >= 3) print $1
    }')
    if [[ -n "$STALE_CLAUDE_PIDS" ]]; then
        STALE_COUNT=$(echo "$STALE_CLAUDE_PIDS" | wc -w | tr -d ' ')
        echo "$STALE_CLAUDE_PIDS" | xargs kill 2>/dev/null || true
        echo "  Killed ${STALE_COUNT} stale claude processes (3+ hours old)"
    fi

    # Remove stale testcontainers (ryuk, test-migration-pg) left by old test runs
    DOCKER="/opt/homebrew/bin/docker"
    if [[ -x "$DOCKER" ]]; then
        STALE_CONTAINERS=$("$DOCKER" ps -q --filter "name=testcontainers-" --filter "name=test-migration-" 2>/dev/null)
        if [[ -n "$STALE_CONTAINERS" ]]; then
            echo "$STALE_CONTAINERS" | xargs "$DOCKER" rm -f 2>/dev/null || true
            echo "  Removed stale test containers"
        fi
        PRUNED=$("$DOCKER" system prune -f 2>/dev/null | tail -1)
        echo "  Docker prune: ${PRUNED}"
    fi

    echo ""
fi

# --------------------------------------------------------------------------
# Claude Desktop memory warning
# --------------------------------------------------------------------------
if pgrep -f "Claude.app" >/dev/null 2>&1; then
    RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    echo "⚠️  Claude Desktop is running - it will compete for RAM with board workers."
    echo "   On a ${RAM_GB}GB machine, this may cause memory pressure."
    echo "   Consider quitting Claude Desktop before running board workers."
    echo ""
fi

# --------------------------------------------------------------------------
# Worker definitions: NAME:MODE:TARGET
# --------------------------------------------------------------------------
declare -a WORKER_CONFIGS=(
    "backlog-backend:backlog:backend"
    "backlog-backend-2:backlog:backend"
    "backlog-backend-3:backlog:backend"
    "backlog-frontend:backlog:frontend"
    "staging-verifier:verify-staging:both"
    "rescue-backend:rescue:backend"
    "reap-both:reap:both"
)

# --------------------------------------------------------------------------
# --stop mode
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--stop" ]]; then
    echo "Stopping all board workers..."
    if [[ -f "${PIDS_FILE}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            NAME="${line%%=*}"
            PID="${line##*=}"
            if kill -0 "${PID}" 2>/dev/null; then
                kill "${PID}" 2>/dev/null && echo "  Stopped ${NAME} (PID ${PID})"
            else
                echo "  ${NAME} (PID ${PID}) already stopped"
            fi
        done < "${PIDS_FILE}"
        rm -f "${PIDS_FILE}"
    fi
    pkill -f "board-worker.sh" 2>/dev/null || true
    echo "Done."
    exit 0
fi

# --------------------------------------------------------------------------
# --status mode
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--status" ]]; then
    echo ""
    echo "=== Board Worker Status ==="
    echo ""
    for CONFIG in "${WORKER_CONFIGS[@]}"; do
        NAME="${CONFIG%%:*}"
        LOG="${LOG_DIR}/${NAME}.log"
        STATUS="not started"
        if [[ -f "${LOG}" ]]; then
            LAST_LINE="$(tail -1 "${LOG}" 2>/dev/null || echo '')"
            MOD_TIME="$(stat -f '%Sm' -t '%H:%M' "${LOG}" 2>/dev/null || echo '?')"
            STATUS="last activity ${MOD_TIME}: ${LAST_LINE:0:80}"
        fi
        # Count completed issues
        COMPLETED_FILE="${LOG_DIR}/${NAME}.board-completed.txt"
        COMPLETED_COUNT=0
        [[ -f "${COMPLETED_FILE}" ]] && COMPLETED_COUNT=$(grep -c '^[0-9]' "${COMPLETED_FILE}" 2>/dev/null || echo 0)
        echo "  [${NAME}] completed=${COMPLETED_COUNT} | ${STATUS}"
    done
    echo ""
    echo "Running processes:"
    ps aux | grep "board-worker.sh" | grep -v grep | awk '{print "  PID="$2, $NF}' || echo "  (none)"
    echo ""
    exit 0
fi

# --------------------------------------------------------------------------
# --dry-run mode
# --------------------------------------------------------------------------
DRY_RUN=""
PASS_DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="true"
    PASS_DRY_RUN="--dry-run"
    echo "*** DRY RUN ***"
    echo ""
fi

# --------------------------------------------------------------------------
# Launch workers
# --------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Board Workers - Launch                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Started:  $(date)"
echo "  Workers:  ${#WORKER_CONFIGS[@]}"
echo "  Logs:     ${LOG_DIR}/"
echo ""

printf "# Board worker PIDs - launched %s\n" "$(date)" > "${PIDS_FILE}"

for CONFIG in "${WORKER_CONFIGS[@]}"; do
    NAME="${CONFIG%%:*}"
    REMAINDER="${CONFIG#*:}"
    MODE="${REMAINDER%%:*}"
    TARGET="${REMAINDER#*:}"
    LOG="${LOG_DIR}/${NAME}.log"

    if [[ -n "$DRY_RUN" ]]; then
        echo "  [DRY RUN] Would launch: ${NAME}"
        echo "    Mode: ${MODE}, Target: ${TARGET}"
        echo "    Log: ${LOG}"
        echo ""
        continue
    fi

    BOARD_WORKER_NAME="${NAME}" nohup bash "${WORKER}" \
        --mode "${MODE}" \
        --target "${TARGET}" \
        ${PASS_DRY_RUN} \
        > "${LOG}" 2>&1 &

    PID=$!
    echo "${NAME}=${PID}" >> "${PIDS_FILE}"
    echo "  ✓ ${NAME}"
    echo "    PID=${PID}  mode=${MODE}  target=${TARGET}  log=$(basename "${LOG}")"
    echo ""

    # Stagger launches
    sleep 15
done

if [[ -z "$DRY_RUN" ]]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                   All board workers launched                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  PIDs saved: ${PIDS_FILE}"
    echo ""
    echo "  Monitor:  tail -f ${LOG_DIR}/backlog-*.log ${LOG_DIR}/ideas-*.log"
    echo "  Status:   bash scripts/launch-board-workers.sh --status"
    echo "  Stop all: bash scripts/launch-board-workers.sh --stop"
    echo ""
fi
