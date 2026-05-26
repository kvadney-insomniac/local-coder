#!/usr/bin/env bash
# launch-overnight.sh — Launch all 9 overnight board runners in parallel.
#
# Usage:
#   bash scripts/launch-overnight.sh              # launch all 9 runners
#   bash scripts/launch-overnight.sh --dry-run    # print without executing
#   bash scripts/launch-overnight.sh --stop       # kill all running runners
#   bash scripts/launch-overnight.sh --status     # show running runners + recent log tails
#
# Each runner gets its own:
#   - queue YAML file (domain-partitioned)
#   - log file in logs/<name>.log
#   - completed file in logs/<name>.completed.txt
#
# Monitor:
#   tail -f logs/backend-worker-1.log
#   tail -f logs/*.log
#
# Stop all:
#   bash scripts/launch-overnight.sh --stop

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
PIDS_FILE="${LOG_DIR}/overnight-pids.txt"
RUNNER="${SCRIPT_DIR}/run-local-overnight.sh"

mkdir -p "${LOG_DIR}/screenshots"

# --------------------------------------------------------------------------
# Pre-flight: Claude Desktop + overnight workers = OOM on ≤32 GB machines.
# Claude Desktop with 10+ MCP servers consumes 8-15 GB resident memory.
# Warn but don't block — the memory watchdog will handle pressure dynamically.
# --------------------------------------------------------------------------
if pgrep -f "Claude.app" >/dev/null 2>&1; then
    RAM_GB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
    echo "⚠️  Claude Desktop is running — it will compete for RAM with overnight workers."
    echo "   On a ${RAM_GB}GB machine, this may cause memory pressure."
    echo "   Consider quitting Claude Desktop before overnight runs."
    echo ""
fi

# --------------------------------------------------------------------------
# Runner definitions: NAME → queue file
# --------------------------------------------------------------------------
declare -a RUNNER_NAMES=(
    "backend-worker-1"
    "backend-worker-2"
    "backend-worker-3"
    "frontend-worker-1"
    "frontend-worker-2"
    "staging-verifier-backend"
    "staging-verifier-frontend"
    "ideas-triage-backend"
    "ideas-triage-frontend"
)

runner_queue_file() {
    case "$1" in
        backend-worker-1)          echo "overnight-queue-backend-worker-1.yaml" ;;
        backend-worker-2)          echo "overnight-queue-backend-worker-2.yaml" ;;
        backend-worker-3)          echo "overnight-queue-backend-worker-3.yaml" ;;
        frontend-worker-1)         echo "overnight-queue-frontend-worker-1.yaml" ;;
        frontend-worker-2)         echo "overnight-queue-frontend-worker-2.yaml" ;;
        staging-verifier-backend)  echo "overnight-queue-staging-verify-backend.yaml" ;;
        staging-verifier-frontend) echo "overnight-queue-staging-verify-frontend.yaml" ;;
        ideas-triage-backend)      echo "overnight-queue-ideas-backend.yaml" ;;
        ideas-triage-frontend)     echo "overnight-queue-ideas-frontend.yaml" ;;
        *) echo ""; return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# --stop mode: kill all tracked runners
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--stop" ]]; then
    echo "Stopping all overnight runners..."
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
    # Belt-and-suspenders: kill any remaining runner processes
    pkill -f "run-local-overnight.sh" 2>/dev/null || true
    echo "Done."
    exit 0
fi

# --------------------------------------------------------------------------
# --status mode: show which runners are active
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--status" ]]; then
    echo ""
    echo "=== Overnight Runner Status ==="
    echo ""
    for NAME in "${RUNNER_NAMES[@]}"; do
        LOG="${LOG_DIR}/${NAME}.log"
        COMPLETED="${LOG_DIR}/overnight-queue-${NAME/backend-worker/backend_worker}.completed.txt"
        STATUS="not started"
        if [[ -f "${LOG}" ]]; then
            LAST_LINE="$(tail -1 "${LOG}" 2>/dev/null || echo '')"
            MOD_TIME="$(stat -f '%Sm' -t '%H:%M' "${LOG}" 2>/dev/null || date -r "${LOG}" '+%H:%M' 2>/dev/null || echo '?')"
            STATUS="last activity ${MOD_TIME}: ${LAST_LINE:0:60}"
        fi
        echo "  [${NAME}] ${STATUS}"
    done
    echo ""
    echo "Running processes:"
    ps aux | grep "run-local-overnight.sh" | grep -v grep | awk '{print "  PID="$2, $NF}' || echo "  (none)"
    echo ""
    exit 0
fi

# --------------------------------------------------------------------------
# --dry-run mode
# --------------------------------------------------------------------------
DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
    echo "*** DRY RUN — would launch these runners: ***"
    echo ""
fi

# --------------------------------------------------------------------------
# Launch runners
# --------------------------------------------------------------------------

# Safety check: count how many FRONTEND runners are configured.
# Each frontend runner can trigger Playwright (headless Chrome). Running more
# than MAX_FRONTEND_RUNNERS at once has caused CPU saturation (incident 2026-05-12:
# 57 Chrome processes → 99% CPU → GitHub unreachable). The Playwright lock in
# run-local-overnight.sh serializes Playwright runs, but limiting the count here
# reduces queue pressure and wasted wait time.
MAX_FRONTEND_RUNNERS=2
CONFIGURED_FRONTEND=0
for _n in "${RUNNER_NAMES[@]}"; do
    [[ "$_n" == *frontend* ]] && CONFIGURED_FRONTEND=$(( CONFIGURED_FRONTEND + 1 ))
done
if [[ "${CONFIGURED_FRONTEND}" -gt "${MAX_FRONTEND_RUNNERS}" ]]; then
    echo "⚠️  WARNING: ${CONFIGURED_FRONTEND} frontend runners configured (max recommended: ${MAX_FRONTEND_RUNNERS})"
    echo "   Multiple frontend workers run Playwright simultaneously → Chrome process explosion."
    echo "   Consider reducing to ${MAX_FRONTEND_RUNNERS} frontend workers in RUNNER_NAMES."
    echo "   (The Playwright lock will serialize them, but extra workers still burn CPU waiting.)"
    echo ""
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Overnight Board Runners — Launch                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Started:  $(date)"
echo "  Runners:  ${#RUNNER_NAMES[@]} (${CONFIGURED_FRONTEND} frontend)"
echo "  Logs:     ${LOG_DIR}/"
echo ""

# Clear old PIDs file
printf "# Overnight runner PIDs — launched %s\n" "$(date)" > "${PIDS_FILE}"

for NAME in "${RUNNER_NAMES[@]}"; do
    QUEUE_FILE="${SCRIPT_DIR}/$(runner_queue_file "$NAME")"
    LOG="${LOG_DIR}/${NAME}.log"

    if [[ ! -f "${QUEUE_FILE}" ]]; then
        echo "  SKIP ${NAME} — queue file not found: ${QUEUE_FILE}"
        continue
    fi

    if [[ -n "$DRY_RUN" ]]; then
        echo "  [DRY RUN] Would launch: ${NAME}"
        echo "    Queue: ${QUEUE_FILE}"
        echo "    Log:   ${LOG}"
        echo ""
        continue
    fi

    # Each runner gets LOOP_NAME set so the stagger logic in run-local-overnight.sh fires
    LOOP_NAME="${NAME}" nohup bash "${RUNNER}" \
        --queue "${QUEUE_FILE}" \
        > "${LOG}" 2>&1 &

    PID=$!
    echo "${NAME}=${PID}" >> "${PIDS_FILE}"
    echo "  ✓ ${NAME}"
    echo "    PID=${PID}  queue=$(basename "${QUEUE_FILE}")  log=$(basename "${LOG}")"
    echo ""

    # Stagger launches to avoid thundering herd — workers fire their first claude
    # call 45–135s after launch, so 15s between launches spreads them across a
    # 2+ minute window and prevents simultaneous startup kills.
    sleep 15
done

if [[ -z "$DRY_RUN" ]]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                   All runners launched                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  PIDs saved: ${PIDS_FILE}"
    echo ""
    echo "  Monitor:  tail -f ${LOG_DIR}/*.log"
    echo "  Status:   bash scripts/launch-overnight.sh --status"
    echo "  Stop all: bash scripts/launch-overnight.sh --stop"
    echo ""
fi
