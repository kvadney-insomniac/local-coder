#!/usr/bin/env bash
# audit-fix-loop.sh - Self-sustaining audit → fix → re-audit loop.
#
# Loops until the prod-readiness audit scores 10/10:
#   1. Wait for any existing run-local-overnight.sh to finish
#   2. Run re-audit (writes audit .md, outputs OVERALL_SCORE=X.X)
#   3. If 10/10 → exit success
#   4. If < 10  → generate new task queue, run overnight runner, loop
#
# Usage (recommended - run in background):
#   nohup bash scripts/audit-fix-loop.sh > /tmp/audit-fix-loop.log 2>&1 &
#
# Log: /tmp/audit-fix-loop.log

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:?REPO_ROOT must be set - source config/config.sh first}"   # .../your-project
LOG="/tmp/audit-fix-loop.log"
OVERNIGHT_RUNNER="${SCRIPT_DIR}/run-local-overnight.sh"

# Starting round (1 = the initial audit already done; we begin at 2)
ROUND=2

# --------------------------------------------------------------------------
# Logging helper
# --------------------------------------------------------------------------
log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*" | tee -a "${LOG}"
}

# --------------------------------------------------------------------------
# Wait until no run-local-overnight.sh is running (poll every 60s)
# --------------------------------------------------------------------------
wait_for_overnight() {
    local count
    while true; do
        count=$(pgrep -f "run-local-overnight.sh" | wc -l | tr -d ' ')
        if [[ "${count}" -eq 0 ]]; then
            log "No overnight runner detected - proceeding."
            return 0
        fi
        log "Overnight runner still running (${count} process(es)). Waiting 60s…"
        sleep 60
    done
}

# --------------------------------------------------------------------------
# Run the audit via claude CLI, return the OVERALL_SCORE value
# --------------------------------------------------------------------------
run_audit() {
    local round="$1"
    local audit_date
    audit_date="$(date +%Y-%m-%d)"
    local audit_file="backend/docs/prod-readiness-audit-${audit_date}-round-${round}.md"

    local audit_prompt
    audit_prompt="Run a production readiness audit of this codebase. \
Read previous audits at backend/docs/prod-readiness-audit-*.md for context. \
Check actual code to verify which gaps are fixed vs remaining. \
Score each dimension 1-10: Security, Reliability, Observability, Testing, \
Infrastructure, Code Quality, Compliance. \
Write to ${audit_file}. \
Output OVERALL_SCORE=X.X as the last line. \
Commit to dev."

    log "ROUND ${round}: Running audit → ${audit_file}"

    local output
    output=$(
        cd "${REPO_ROOT}" && \
        claude --dangerously-skip-permissions --model "${LOCAL_CODER_DEFAULT_MODEL:-claude-opus-5-5}" \
            -p "${audit_prompt}" < /dev/null 2>&1
    )
    local exit_code=$?

    log "Audit claude exit code: ${exit_code}"
    echo "${output}" >> "${LOG}"

    # Parse OVERALL_SCORE=X.X from output
    local score
    score=$(echo "${output}" | grep -oE 'OVERALL_SCORE=[0-9]+(\.[0-9]+)?' | tail -1 | cut -d= -f2)

    # Fallback: check the written audit file
    if [[ -z "${score}" ]]; then
        local full_path="${REPO_ROOT}/${audit_file}"
        if [[ -f "${full_path}" ]]; then
            score=$(grep -oE 'OVERALL_SCORE=[0-9]+(\.[0-9]+)?' "${full_path}" | tail -1 | cut -d= -f2)
        fi
    fi

    if [[ -z "${score}" ]]; then
        log "WARNING: Could not parse OVERALL_SCORE from audit output. Defaulting to 0."
        score="0"
    fi

    log "ROUND ${round}: Audit score = ${score}"
    echo "${score}"
}

# --------------------------------------------------------------------------
# Generate a new task queue for remaining gaps, then run it
# --------------------------------------------------------------------------
run_fix_pass() {
    local round="$1"
    local queue_file="${SCRIPT_DIR}/overnight-queue-round-${round}.yaml"

    local queue_prompt
    queue_prompt="Read the latest backend/docs/prod-readiness-audit-*.md. \
For every remaining gap below 10, create tasks in queues/queue-round-${round}.yaml \
matching the format in overnight-queue-10x.yaml. \
Each task: id, priority, repo, estimated_minutes, detailed prompt with files/changes/tests/commit message. \
Only include unfixed gaps. \
Commit to dev."

    log "ROUND ${round}: Generating task queue → ${queue_file}"

    local output
    output=$(
        cd "${REPO_ROOT}" && \
        claude --dangerously-skip-permissions --model "${LOCAL_CODER_DEFAULT_MODEL:-claude-opus-5-5}" \
            -p "${queue_prompt}" < /dev/null 2>&1
    )
    local exit_code=$?

    log "Queue generation claude exit code: ${exit_code}"
    echo "${output}" >> "${LOG}"

    if [[ ! -f "${queue_file}" ]]; then
        log "ERROR: Queue file not created at ${queue_file}. Skipping fix pass."
        return 1
    fi

    local task_count
    task_count=$(grep -c '^\s*id:' "${queue_file}" 2>/dev/null || echo 0)
    log "ROUND ${round}: Queue has ${task_count} task(s). Starting overnight runner…"

    nohup bash "${OVERNIGHT_RUNNER}" "${queue_file}" \
        >> "/tmp/overnight-round-${round}.log" 2>&1

    log "ROUND ${round}: Overnight runner finished (exit $?)."
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
log "════════════════════════════════════════════════════════"
log "audit-fix-loop.sh started. Target: 10/10. Starting at round ${ROUND}."
log "════════════════════════════════════════════════════════"

while true; do
    log "─── ROUND ${ROUND} ──────────────────────────────────────────"

    # Step 1: wait for any existing overnight runner
    wait_for_overnight

    # Step 2: run audit
    score=$(run_audit "${ROUND}")

    # Step 3: check if done
    # Compare as integers by stripping decimal; treat 10 or 10.0 as done
    score_int=$(echo "${score}" | awk '{printf "%d", $1 * 10}')  # e.g. 9.5 → 95, 10 → 100
    if [[ "${score_int}" -ge 100 ]]; then
        log "════════════════════════════════════════════════════════"
        log "SUCCESS: Score ${score}/10 - production readiness is 10/10!"
        log "════════════════════════════════════════════════════════"
        exit 0
    fi

    log "Score ${score}/10 - gaps remain. Generating fix queue for round ${ROUND}…"

    # Steps 5-6: generate queue and run fixes
    run_fix_pass "${ROUND}"

    ROUND=$((ROUND + 1))
done
