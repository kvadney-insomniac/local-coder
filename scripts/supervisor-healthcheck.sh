#!/usr/bin/env bash
# supervisor-healthcheck.sh - Re-spawn dead perpetual-board-worker supervisors.
#
# Designed to be invoked every ~60s by launchd. Idempotent: a no-op when every
# registered supervisor PID is alive. If any are dead, re-launches just those
# (in-process detached subshells), updates the PID file, and logs the action.
#
# Skipped entirely if the intentional-stop marker exists, so `--stop` is sticky.
#
# Written for bash 3.x (macOS default) - no associative arrays.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LAUNCHER="${SCRIPT_DIR}/perpetual-board-workers.sh"
PIDS_FILE="${LOG_DIR}/perpetual-supervisor-pids.txt"
STOP_MARKER="${LOG_DIR}/supervisors-stopped.marker"
HC_LOG="${LOG_DIR}/supervisor-healthcheck.log"

mkdir -p "${LOG_DIR}"

log() {
    echo "[$(date '+%F %T')] $*" >> "${HC_LOG}"
}

# Don't fight an intentional stop.
if [[ -f "${STOP_MARKER}" ]]; then
    exit 0
fi

# Nothing to do if the launcher has never been started.
if [[ ! -f "${PIDS_FILE}" ]]; then
    exit 0
fi

# Source the launcher for WORKER_CONFIGS + run_supervisor without launching.
export PERPETUAL_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "${LAUNCHER}"
unset PERPETUAL_SOURCE_ONLY

# Look up a CONFIG line by NAME via linear scan of WORKER_CONFIGS.
lookup_config() {
    local want="$1" cfg
    for cfg in "${WORKER_CONFIGS[@]}"; do
        if [[ "${cfg%%:*}" == "${want}" ]]; then
            echo "${cfg}"
            return 0
        fi
    done
    return 1
}

# Parallel indexed arrays: NAMES[i] -> PIDS[i].
NAMES=()
PIDS=()
HEADER_LINE=""
while IFS= read -r line; do
    if [[ -z "$line" ]]; then continue; fi
    if [[ "$line" == \#* ]]; then HEADER_LINE="$line"; continue; fi
    NAMES+=("${line%%=*}")
    PIDS+=("${line##*=}")
done < "${PIDS_FILE}"

# Identify dead supervisor indices.
DEAD_IDX=()
for i in "${!NAMES[@]}"; do
    if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        DEAD_IDX+=("$i")
    fi
done

if [[ ${#DEAD_IDX[@]} -eq 0 ]]; then
    exit 0
fi

DEAD_NAMES=""
for i in "${DEAD_IDX[@]}"; do
    DEAD_NAMES+="${NAMES[$i]} "
done
log "detected ${#DEAD_IDX[@]} dead supervisor(s): ${DEAD_NAMES}"

# Respawn each dead supervisor using the launcher's own run_supervisor func.
for i in "${DEAD_IDX[@]}"; do
    NAME="${NAMES[$i]}"
    CONFIG="$(lookup_config "${NAME}" || true)"
    if [[ -z "${CONFIG}" ]]; then
        log "  skip ${NAME}: no WORKER_CONFIGS entry"
        continue
    fi
    REM="${CONFIG#*:}"
    MODE="${REM%%:*}"
    TARGET="${REM#*:}"

    # Launch supervisor as a backgrounded subshell. The launchd plist sets
    # AbandonProcessGroup=true so this child survives healthcheck.sh exiting.
    (
        run_supervisor "${NAME}" "${MODE}" "${TARGET}"
    ) > "${LOG_DIR}/${NAME}.supervisor.stdout.log" 2>&1 < /dev/null &
    NEW_PID=$!
    disown "${NEW_PID}" 2>/dev/null || true
    PIDS[$i]="${NEW_PID}"
    log "  respawned ${NAME} mode=${MODE} target=${TARGET} pid=${NEW_PID}"
done

# Rewrite PID file, preserving original order + original header.
TMP="${PIDS_FILE}.tmp.$$"
{
    if [[ -n "${HEADER_LINE}" ]]; then
        echo "${HEADER_LINE}"
    fi
    echo "# Healthcheck respawn at $(date) - replaced:${DEAD_NAMES:+ }${DEAD_NAMES}"
    for i in "${!NAMES[@]}"; do
        echo "${NAMES[$i]}=${PIDS[$i]}"
    done
} > "${TMP}"
mv "${TMP}" "${PIDS_FILE}"

log "pid file updated"
exit 0
