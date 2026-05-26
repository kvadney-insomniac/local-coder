#!/usr/bin/env bash
# telemetry-collect.sh — Non-invasive board-worker telemetry collector.
#
# Polls the worker logs in logs/ and produces:
#   - logs/telemetry-snapshot.json  (overwritten — current rollup)
#   - logs/telemetry-history.csv    (appended — one row per snapshot)
#
# Does NOT wrap the claude CLI. Pure read-only observation. Safe to run on a
# schedule (launchd StartInterval=300).
#
# Per worker we extract from <name>.log:
#   iter           — count of "Board Worker —" batch starts
#   done           — sum of "Tasks: N processed" values
#   idle           — count of batches where Tasks == "0 processed | 0 failed"
#   productive     — iter - idle
#   work_min       — sum of "Duration: N min" lines
#   bytes_in       — size of all task .log files attributable to this worker
#                    (rough stdin+stdout byte proxy for Claude Max token burn)
#   last_seen      — mtime of the worker's main .log
#
# Idempotent. Re-running rewrites the snapshot from scratch (no incremental
# state). The CSV grows monotonically.
#
# Usage:
#   bash telemetry-collect.sh
#
# Env:
#   TELEMETRY_VERBOSE=1   echo per-worker numbers to stdout

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
SNAPSHOT="${LOG_DIR}/telemetry-snapshot.json"
HISTORY="${LOG_DIR}/telemetry-history.csv"

# Worker names from perpetual-board-workers.sh WORKER_CONFIGS
WORKERS=(
    "ideas-triage:ideas:both"
    "backlog-backend:backlog:backend"
    "backlog-backend-2:backlog:backend"
    "backlog-backend-3:backlog:backend"
    "backlog-frontend:backlog:frontend"
    "staging-verifier:verify-staging:both"
    "rescue-backend:rescue:backend"
    "reap-both:reap:both"
)

now_epoch=$(date +%s)
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "${LOG_DIR}"

# Emit CSV header on first write
if [[ ! -f "${HISTORY}" ]]; then
    echo "timestamp,worker,mode,target,iter,done,idle,productive,work_min,bytes_in,task_log_count,last_seen_age_sec" > "${HISTORY}"
fi

# Build JSON workers array
JSON_WORKERS=""
TOTAL_ITER=0
TOTAL_DONE=0
TOTAL_IDLE=0
TOTAL_WORK_MIN=0
TOTAL_BYTES=0
TOTAL_TASK_LOGS=0

for entry in "${WORKERS[@]}"; do
    NAME="${entry%%:*}"
    rest="${entry#*:}"
    MODE="${rest%%:*}"
    TARGET="${rest#*:}"

    WORKER_LOG="${LOG_DIR}/${NAME}.log"

    iter=0; done=0; idle=0; work_min=0; bytes_in=0; task_log_count=0
    last_seen_age=-1

    if [[ -f "${WORKER_LOG}" ]]; then
        iter=$(grep -c "Board Worker — " "${WORKER_LOG}" 2>/dev/null || echo 0)
        # Sum "  Tasks:     N processed" values
        done=$(grep -E "^  Tasks: +[0-9]+ processed" "${WORKER_LOG}" 2>/dev/null \
            | awk '{s+=$2} END {print s+0}')
        idle=$(grep -cE "^  Tasks: +0 processed +\| +0 failed" "${WORKER_LOG}" 2>/dev/null || echo 0)
        work_min=$(grep -E "^  Duration: +[0-9]+min" "${WORKER_LOG}" 2>/dev/null \
            | awk '{gsub("min","",$2); s+=$2} END {print s+0}')

        mtime=$(stat -f %m "${WORKER_LOG}" 2>/dev/null || echo "${now_epoch}")
        last_seen_age=$(( now_epoch - mtime ))
    fi

    productive=$(( iter - idle ))
    [[ $productive -lt 0 ]] && productive=0

    # Per-task log files (proxy for claude CLI bytes consumed by this worker).
    # Worker NAME alone doesn't appear in task labels — task labels are like
    # backlog-backend-<issue>.log, ideas-backend-<issue>.log, rescue-backend-<issue>.log,
    # verify-backend-<issue>.log. Map worker → label prefix:
    LABEL_PREFIX=""
    case "$MODE" in
        ideas)          LABEL_PREFIX="ideas-" ;;
        backlog)        LABEL_PREFIX="backlog-" ;;
        verify-staging) LABEL_PREFIX="verify-" ;;
        rescue)         LABEL_PREFIX="rescue-" ;;
        reap)           LABEL_PREFIX="reap-" ;;
    esac

    if [[ -n "${LABEL_PREFIX}" ]]; then
        # All backlog-* workers share label prefix "backlog-<repo>-<issue>.log"
        # so we attribute task-log bytes to the MODE+TARGET combo, then divide
        # by the number of workers in that combo to avoid double-counting.
        # Build glob: backlog-backend-*.log or ideas-{backend,frontend}-*.log etc.
        case "$TARGET" in
            backend)  GLOB="${LABEL_PREFIX}backend-*.log" ;;
            frontend) GLOB="${LABEL_PREFIX}frontend-*.log" ;;
            both)     GLOB="${LABEL_PREFIX}*-*.log" ;;
        esac

        # Count workers sharing this (mode,target) for fair attribution
        SHARERS=0
        for e2 in "${WORKERS[@]}"; do
            m2="${e2#*:}"; m2="${m2%%:*}"
            t2="${e2##*:}"
            [[ "$m2" == "$MODE" ]] && [[ "$t2" == "$TARGET" ]] && SHARERS=$((SHARERS + 1))
        done
        [[ $SHARERS -lt 1 ]] && SHARERS=1

        # Sum byte sizes of matching task logs
        shopt -s nullglob
        total_bytes=0
        total_files=0
        for f in "${LOG_DIR}"/${GLOB}; do
            sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
            total_bytes=$((total_bytes + sz))
            total_files=$((total_files + 1))
        done
        shopt -u nullglob

        bytes_in=$(( total_bytes / SHARERS ))
        task_log_count=$(( total_files / SHARERS ))
    fi

    [[ "${TELEMETRY_VERBOSE:-0}" == "1" ]] && \
        echo "  ${NAME}: iter=${iter} done=${done} idle=${idle} work=${work_min}min bytes=${bytes_in}"

    TOTAL_ITER=$(( TOTAL_ITER + iter ))
    TOTAL_DONE=$(( TOTAL_DONE + done ))
    TOTAL_IDLE=$(( TOTAL_IDLE + idle ))
    TOTAL_WORK_MIN=$(( TOTAL_WORK_MIN + work_min ))
    TOTAL_BYTES=$(( TOTAL_BYTES + bytes_in ))
    TOTAL_TASK_LOGS=$(( TOTAL_TASK_LOGS + task_log_count ))

    # Append CSV row
    echo "${now_iso},${NAME},${MODE},${TARGET},${iter},${done},${idle},${productive},${work_min},${bytes_in},${task_log_count},${last_seen_age}" >> "${HISTORY}"

    # JSON fragment
    [[ -n "${JSON_WORKERS}" ]] && JSON_WORKERS="${JSON_WORKERS},"
    JSON_WORKERS="${JSON_WORKERS}
    {
      \"name\": \"${NAME}\",
      \"mode\": \"${MODE}\",
      \"target\": \"${TARGET}\",
      \"iter\": ${iter},
      \"done\": ${done},
      \"idle\": ${idle},
      \"productive\": ${productive},
      \"work_min\": ${work_min},
      \"bytes_in\": ${bytes_in},
      \"task_log_count\": ${task_log_count},
      \"last_seen_age_sec\": ${last_seen_age}
    }"
done

# Write snapshot atomically
TMP_SNAPSHOT="${SNAPSHOT}.tmp.$$"
cat > "${TMP_SNAPSHOT}" <<EOF
{
  "timestamp": "${now_iso}",
  "timestamp_epoch": ${now_epoch},
  "totals": {
    "iter": ${TOTAL_ITER},
    "done": ${TOTAL_DONE},
    "idle": ${TOTAL_IDLE},
    "productive": $((TOTAL_ITER - TOTAL_IDLE)),
    "work_min": ${TOTAL_WORK_MIN},
    "bytes_in": ${TOTAL_BYTES},
    "task_log_count": ${TOTAL_TASK_LOGS}
  },
  "workers": [${JSON_WORKERS}
  ]
}
EOF
mv "${TMP_SNAPSHOT}" "${SNAPSHOT}"

[[ "${TELEMETRY_VERBOSE:-0}" == "1" ]] && \
    echo "Wrote ${SNAPSHOT} and appended ${#WORKERS[@]} rows to ${HISTORY}"

exit 0
