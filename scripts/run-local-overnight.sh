#!/usr/bin/env bash
# run-local-overnight.sh - Run overnight queue tasks using the LOCAL claude CLI.
# Uses the user's Claude Max subscription - no API key or GCP needed.
#
# Usage:
#   bash run-local-overnight.sh              # run all remaining tasks sequentially
#   bash run-local-overnight.sh --dry-run    # print tasks without executing
#   bash run-local-overnight.sh --queue <path>  # use a specific queue YAML file
#   bash run-local-overnight.sh --priority P1  # run only P1 tasks
#   bash run-local-overnight.sh --list       # list pending tasks and exit
#   bash run-local-overnight.sh --skip p1-foo,p2-bar  # comma-separated IDs to skip
#
# Background (recommended):
#   nohup bash scripts/run-local-overnight.sh \
#     > logs/overnight-$(date +%Y%m%d).log 2>&1 &
#
# State:
#   Completed task IDs are written to logs/completed.txt
#   so re-runs skip already-finished tasks automatically.
#
# Per-task logs:
#   logs/<task-id>.log

set -uo pipefail
# NOTE: -e intentionally omitted. A non-zero claude exit must NOT kill the outer
# loop. We capture exit codes explicitly with ||. Combined with the stdin fix
# below (< /dev/null on the claude invocation), this makes the loop robust.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CODER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# REPO_ROOT = the target repo the agent will edit. Set this in config/config.sh.
REPO_ROOT="${REPO_ROOT:?REPO_ROOT must be set - source config/config.sh first}"
# Allow demo-prep-loop.sh (and other callers) to override the queue file via env var
QUEUE="${QUEUE:-${LOCAL_CODER_ROOT}/queues/example.yaml}"
# LOCAL_CODER_LOGS_DIR lets tests and multi-checkout setups keep logs out of the tree.
LOGS_DIR="${LOCAL_CODER_LOGS_DIR:-${LOCAL_CODER_ROOT}/logs}"
# Model used when a queue task has no "model" field. Any alias or full model
# name the claude CLI accepts works here (see docs/COMPARED-TO-CLAUDE-CODE.md).
DEFAULT_MODEL="${LOCAL_CODER_DEFAULT_MODEL:-claude-opus-5-5}"
# Set LOCAL_CODER_SKIP_RESOURCE_GATES=1 to bypass the CPU and memory gates
# (CI runners and tests; never for real overnight runs on a shared laptop).
SKIP_RESOURCE_GATES="${LOCAL_CODER_SKIP_RESOURCE_GATES:-0}"

# --------------------------------------------------------------------------
# Cleanup: kill active claude subprocess and temp files on exit/signal.
# ACTIVE_CHILD_PID is set in run_task() while a task is running.
# --------------------------------------------------------------------------
ACTIVE_CHILD_PID=""
_overnight_cleanup() {
    if [[ -n "${ACTIVE_CHILD_PID:-}" ]]; then
        # Kill the pipeline process group (covers both the subshell and tee)
        kill -- "-${ACTIVE_CHILD_PID}" 2>/dev/null || kill "${ACTIVE_CHILD_PID}" 2>/dev/null || true
        wait "${ACTIVE_CHILD_PID}" 2>/dev/null || true
    fi
    # Clean up any temp prompt files left by this PID
    rm -f "${TMPDIR:-/tmp}"/claude-prompt-*-$$.txt 2>/dev/null || true
    # Release Playwright lock if we hold it
    _release_playwright_lock
}
trap '_overnight_cleanup' EXIT INT TERM HUP

# --------------------------------------------------------------------------
# Startup: kill any orphaned Playwright/Chrome processes from previous runs.
# Multiple local-coder workers running frontend tasks simultaneously can
# accumulate dozens of headless Chrome processes that saturate CPU.
# --------------------------------------------------------------------------
_cleanup_orphan_browsers() {
    local chrome_count
    chrome_count=$(pgrep -f "chrome-headless-shell" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${chrome_count:-0}" -gt 10 ]]; then
        echo "  ⚠️  Found ${chrome_count} orphaned chrome-headless-shell processes - cleaning up..."
        pkill -f "chrome-headless-shell" 2>/dev/null || true
        sleep 2
    fi
}
_cleanup_orphan_browsers

# --------------------------------------------------------------------------
# Kill accumulated vitest/node orphans from previous frontend task runs.
# Each claude invocation that runs `npm test -- --run` can leave behind
# node (vitest) worker processes that don't exit cleanly when the parent
# claude process is killed by timeout or crash. Without this guard, they
# accumulate over overnight sessions and exhaust RAM (observed: 7 processes,
# ~826 MB combined, 16+ hours old, system at 98% memory usage 2026-05-12).
# Threshold: >4 vitest processes = definite leak (normal max is 2 workers
# for one concurrent frontend task, per maxWorkers in vitest.config.mts).
# --------------------------------------------------------------------------
_cleanup_orphan_vitest() {
    local vitest_count
    # pgrep -c prints "0" AND exits 1 when nothing matches, so an "|| echo 0"
    # fallback would yield "0\n0" and break the arithmetic test below.
    vitest_count=$(pgrep -c -f 'vitest' 2>/dev/null)
    vitest_count="${vitest_count:-0}"
    if [[ "${vitest_count}" -gt 4 ]]; then
        echo "  ⚠️  Found ${vitest_count} orphaned vitest processes - cleaning up..."
        pkill -f vitest 2>/dev/null || true
        sleep 2
    fi
}
_cleanup_orphan_vitest


# --------------------------------------------------------------------------
# Playwright global mutex - serializes all Playwright/browser test runs
# across every concurrent local-coder worker on this machine.
#
# Root cause: multiple frontend workers running simultaneously each spawn
# Playwright, which launches headless Chrome. 8+ workers × ~7 Chrome procs
# = 56+ processes → 99% CPU → GitHub TLS timeouts, SSH failures, 500 errors.
#
# Fix: before running any frontend task, acquire this lock. Other workers
# queue up and wait. Only one Playwright session runs at a time.
# --------------------------------------------------------------------------
PLAYWRIGHT_LOCK_DIR="${LOGS_DIR}/playwright.lock.d"

_acquire_playwright_lock() {
    local waited=0
    while ! mkdir "${PLAYWRIGHT_LOCK_DIR}" 2>/dev/null; do
        local holder="(unknown)"
        [[ -f "${PLAYWRIGHT_LOCK_DIR}/holder" ]] && holder=$(cat "${PLAYWRIGHT_LOCK_DIR}/holder")
        if [[ $waited -eq 0 ]]; then
            echo "  ⏳ Playwright lock held by ${holder} - waiting (max 90 min)..."
        fi
        sleep 30
        waited=$((waited + 30))
        # Stale lock guard: if holder process is dead, break the lock
        if [[ $waited -gt 60 ]] && [[ -f "${PLAYWRIGHT_LOCK_DIR}/holder" ]]; then
            local holder_pid
            holder_pid=$(cat "${PLAYWRIGHT_LOCK_DIR}/holder" | cut -d: -f1)
            if [[ -n "${holder_pid}" ]] && ! kill -0 "${holder_pid}" 2>/dev/null; then
                echo "  ⚠️  Playwright lock holder PID ${holder_pid} is dead - breaking stale lock"
                rm -rf "${PLAYWRIGHT_LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi
        if [[ $waited -gt 5400 ]]; then
            echo "  ⚠️  Playwright lock wait exceeded 90 min - breaking lock"
            rm -rf "${PLAYWRIGHT_LOCK_DIR}" 2>/dev/null || true
        fi
    done
    echo "$$:${LOOP_NAME:-${_QUEUE_STEM}}" > "${PLAYWRIGHT_LOCK_DIR}/holder"
    echo "  🔒 Playwright lock acquired"
}

_release_playwright_lock() {
    if [[ -d "${PLAYWRIGHT_LOCK_DIR}" ]]; then
        local holder=""
        [[ -f "${PLAYWRIGHT_LOCK_DIR}/holder" ]] && holder=$(cat "${PLAYWRIGHT_LOCK_DIR}/holder")
        local holder_pid
        holder_pid=$(echo "${holder}" | cut -d: -f1)
        # Only release if we own the lock
        if [[ "${holder_pid}" == "$$" ]]; then
            rm -rf "${PLAYWRIGHT_LOCK_DIR}" 2>/dev/null || true
            echo "  🔓 Playwright lock released"
        fi
    fi
}

# --------------------------------------------------------------------------
# CPU load gate - don't start a new task if machine is already under load.
# Prevents cascading slowdowns when multiple workers pile up simultaneously.
# --------------------------------------------------------------------------
# Portable helpers: macOS reports through sysctl/vm_stat, Linux through /proc.
_cpu_cores() {
    local n
    n=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    echo "${n:-4}"
}

_load_avg_1min() {
    local load
    if [[ -r /proc/loadavg ]]; then
        load=$(cut -d' ' -f1 /proc/loadavg)
    else
        load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
    fi
    echo "${load%%.*}"
}

# Prints "<avail_mb> <total_mb> <compressed_mb>". compressed_mb is 0 on Linux.
_memory_stats_mb() {
    if [[ -r /proc/meminfo ]]; then
        awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END{printf "%d %d 0\n", a/1024, t/1024}' /proc/meminfo
        return
    fi
    local free_pages inactive_pages compressor_pages total_bytes
    free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/{gsub(/\./,"",$3); print $3}')
    inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive/{gsub(/\./,"",$3); print $3}')
    compressor_pages=$(vm_stat 2>/dev/null | awk '/stored in compressor/{gsub(/\./,"",$5); print $5}')
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    echo "$(( (${free_pages:-0} + ${inactive_pages:-0}) * 4096 / 1024 / 1024 )) \
$(( ${total_bytes:-0} / 1024 / 1024 )) \
$(( ${compressor_pages:-0} * 4096 / 1024 / 1024 ))"
}

_wait_for_cpu_headroom() {
    [[ "${SKIP_RESOURCE_GATES}" == "1" ]] && return 0
    local cores
    cores=$(_cpu_cores)
    # Threshold: load avg > 1.5x core count = saturated (each core has 1.5 tasks)
    local threshold=$(( cores + cores / 2 ))
    local waited=0
    while true; do
        local load
        load=$(_load_avg_1min)
        if [[ "${load:-0}" -le "${threshold}" ]]; then
            break
        fi
        if [[ $waited -eq 0 ]]; then
            echo "  ⏳ CPU load avg ${load} > threshold ${threshold} (${cores} cores) - waiting for headroom..."
        fi
        sleep 30
        waited=$((waited + 30))
        if [[ $waited -gt 600 ]]; then
            echo "  ⚠️  CPU still loaded after 10 min - proceeding anyway"
            break
        fi
    done
}

# --------------------------------------------------------------------------
# Memory pressure gate - don't start a new task if RAM is nearly exhausted.
# Vitest/Node processes accumulating from previous tasks can exhaust memory
# even when CPU load appears acceptable. Requires 4 GB free+inactive pages
# before launching the next claude invocation.
# --------------------------------------------------------------------------
_wait_for_memory_headroom() {
    [[ "${SKIP_RESOURCE_GATES}" == "1" ]] && return 0
    local MAX_ATTEMPTS=20
    local attempt=0
    while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
        local AVAIL_MB TOTAL_MB COMPRESSOR_MB
        read -r AVAIL_MB TOTAL_MB COMPRESSOR_MB < <(_memory_stats_mb)

        # Check compressor thrashing, the real OOM signal on macOS.
        # macOS compresses pages aggressively, so free+inactive can look OK
        # even when the system is in a death spiral. Linux reports 0 here.
        if [[ "${TOTAL_MB}" -gt 0 ]] && [[ "${COMPRESSOR_MB}" -gt $(( TOTAL_MB / 2 )) ]]; then
            if [[ $attempt -eq 0 ]]; then
                echo "  ⚠️  Memory compressor thrashing: ${COMPRESSOR_MB}MB compressed (${TOTAL_MB}MB total RAM)"
                if pgrep -f "Claude.app" >/dev/null 2>&1; then
                    echo "  ⚠️  Claude Desktop is running - likely the memory hog. Consider quitting it."
                fi
                _cleanup_orphan_vitest
                _cleanup_orphan_browsers
            fi
            sleep 30
            attempt=$((attempt + 1))
            continue
        fi

        if [[ "${AVAIL_MB}" -gt 6144 ]]; then
            return 0
        fi
        if [[ $attempt -eq 0 ]]; then
            echo "  ⏳ Low memory (${AVAIL_MB}MB free+inactive) - waiting for headroom..."
            _cleanup_orphan_vitest
        fi
        sleep 30
        attempt=$((attempt + 1))
    done
    echo "  ⚠️  Memory pressure persists after 10 min - proceeding anyway"
}

# --------------------------------------------------------------------------
# Tasks already completed - skip these unconditionally
# --------------------------------------------------------------------------
HARDCODED_SKIP=(
    p1-rate-limit-auth
    p1-csp-headers
    p1-pg-statement-timeout
    p1-generate-plan-timeout
    p1-sse-streaming-timeout
    p1-token-budget
    p1-upgrade-gpt4o
    p2-structured-logging
    p2-frontend-error-boundaries
    p2-ssl-db-connections
)

# --------------------------------------------------------------------------
# Discipline preamble prepended to every task prompt
# --------------------------------------------------------------------------
read -r -d '' PREAMBLE <<'PREAMBLE_EOF' || true
IMPORTANT RULES FOR THIS TASK - READ BEFORE DOING ANYTHING:
1. Work on the dev branch directly. Do NOT create worktrees or feature branches.
2. Do NOT delete or comment-out existing features to fix errors - fix the actual error.
3. Before committing, run the full test suite and verify it passes (no new failures beyond known baseline).
4. Commit with a clear, accurate message describing what changed and why.
5. If tests fail due to your changes, fix them before committing. Pre-existing failures (~63 backend) are OK.
6. Backend test command: cd backend && ${BACKEND_TEST_CMD:-python -m pytest tests/ --tb=short -q}
7. Frontend test command: cd frontend && npm run build && npm test -- --run
8. Scope strictly to the task - no speculative refactoring or unrequested features.

TASK:
PREAMBLE_EOF

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
DRY_RUN="false"
LIST_ONLY="false"
PRIORITY_FILTER=""
EXTRA_SKIP_IDS=""

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN="true";          shift ;;
        --list)       LIST_ONLY="true";        shift ;;
        --queue)      QUEUE="$2";              shift 2 ;;
        --priority)   PRIORITY_FILTER="$2";   shift 2 ;;
        --skip)       EXTRA_SKIP_IDS="$2";    shift 2 ;;
        --help|-h)
            sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Derive completed-file from queue name so parallel runners don't share state.
# Default (no --queue) maps overnight-queue.yaml → completed.txt for backward compat.
_QUEUE_STEM="$(basename "${QUEUE%.yaml}")"
if [[ "$_QUEUE_STEM" == "overnight-queue" ]]; then
    COMPLETED_FILE="${LOGS_DIR}/completed.txt"
else
    COMPLETED_FILE="${LOGS_DIR}/${_QUEUE_STEM}.completed.txt"
fi

# --------------------------------------------------------------------------
# Ensure logs directory exists
# --------------------------------------------------------------------------
mkdir -p "${LOGS_DIR}"
touch "${COMPLETED_FILE}"

# --------------------------------------------------------------------------
# Build full skip set: hardcoded + completed.txt + --skip arg
# --------------------------------------------------------------------------
ALL_SKIP_CSV=""
for id in "${HARDCODED_SKIP[@]}"; do
    ALL_SKIP_CSV="${ALL_SKIP_CSV}${id},"
done
# Add completed.txt entries
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    ALL_SKIP_CSV="${ALL_SKIP_CSV}${line},"
done < "${COMPLETED_FILE}"
# Add --skip arg
if [[ -n "$EXTRA_SKIP_IDS" ]]; then
    ALL_SKIP_CSV="${ALL_SKIP_CSV}${EXTRA_SKIP_IDS},"
fi

# --------------------------------------------------------------------------
# Parse queue with Python (handles multi-line YAML prompts correctly)
# --------------------------------------------------------------------------
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: PyYAML required. Run: pip install pyyaml" >&2
    exit 1
fi

# Compute round numbers in bash so they can be passed into the Python heredoc
# without f-string expansion conflicts (bash expands ${VAR} inside unquoted
# heredocs, so Python f-strings with {var} would be mangled by bash first).
_QUEUE_BASENAME="$(basename "${QUEUE}")"
_CURRENT_ROUND="$(echo "${_QUEUE_BASENAME}" | grep -oE '[0-9]+' | head -1)"
_NEXT_ROUND="$(( _CURRENT_ROUND > 0 ? _CURRENT_ROUND + 1 : 0 ))"

read_queue() {
    python3 - <<PYEOF
import yaml, json, sys

with open("${QUEUE}") as f:
    data = yaml.safe_load(f)

tasks = data.get("queue", [])

ORDER = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
tasks.sort(key=lambda t: (ORDER.get(t["priority"], 99),))

skip_raw = "${ALL_SKIP_CSV}"
skip_ids = set(s.strip() for s in skip_raw.split(",") if s.strip())

priority_filter = "${PRIORITY_FILTER}"

# Round numbers pre-computed by bash to avoid f-string/heredoc conflicts.
current_round_str = "${_CURRENT_ROUND}"
next_round_str    = "${_NEXT_ROUND}"
current_round = int(current_round_str) if current_round_str.isdigit() else None
next_round    = int(next_round_str)    if next_round_str.isdigit() and int(next_round_str) > 0 else None

# Check whether the queue already contains a p3-generate-next-round task.
has_meta = any(t["id"] == "p3-generate-next-round" or t.get("category") == "meta" for t in tasks)

output_tasks = []
for t in tasks:
    if t["id"] in skip_ids:
        continue
    if priority_filter and t["priority"] != priority_filter:
        continue
    output_tasks.append(t)

# --- Inject meta-task at the very end if missing ---
# Skip injection when a priority filter is active or round number is unknown.
if not has_meta and not priority_filter and next_round is not None:
    # Build prompt with plain string concatenation - no f-strings so this
    # heredoc stays safe even when bash expansion is active.
    meta_prompt = (
        "You are the continuous improvement loop generator for the YourProject\n"
        "5/8 customer demo readiness sprint. Your job is to generate the next\n"
        "round of the overnight queue so the loop never stops.\n\n"
        "CONTEXT:\n"
        "- Demo date: 2026-05-08.\n"
        "- This is round " + str(current_round) + ". You are writing round " + str(next_round) + ".\n"
        "- The goal: be fully demo-ready for a real customer by 5/8.\n\n"
        "CRITICAL RULE - VERIFY BEFORE QUEUING:\n"
        "Do NOT queue a task based on what a previous round's YAML said it would fix.\n"
        "You MUST run the actual commands below and use the LIVE OUTPUT to decide what\n"
        "still needs work. If a problem is already fixed, do not queue it - that wastes\n"
        "a task slot and burns time. Every task you write must target a gap that is\n"
        "CONFIRMED PRESENT in the live output you capture in Step 1.\n\n"
        "STEP 1 - Capture live state (run ALL of these, record the output):\n"
        "1. Backend test results:\n"
        "     cd ${REPO_ROOT:-/path/to/your/repo}/backend && \\\n"
        "     ${BACKEND_TEST_CMD:-python -m pytest tests/ --tb=no -q} 2>&1 | tail -5\n"
        "   Record: total passed, failed, errors.\n"
        "2. Frontend build warnings:\n"
        "     cd ${REPO_ROOT:-/path/to/your/repo}/frontend && \\\n"
        "     npm run build 2>&1 | grep -iE 'warn|deprecat|error' | grep -v '^>' | head -20\n"
        "   Record: exact warning text and count. If zero warnings, note that.\n"
        "3. Frontend bundle sizes:\n"
        "     cd ${REPO_ROOT:-/path/to/your/repo}/frontend && \\\n"
        "     npm run build 2>&1 | grep 'First Load JS'\n"
        "   Record: shared chunk size and the 3 largest route chunks.\n"
        "4. Playwright E2E status:\n"
        "     cd ${REPO_ROOT:-/path/to/your/repo}/frontend && \\\n"
        "     npx playwright test --reporter=list 2>&1 | tail -10 || echo 'Playwright not set up'\n"
        "   Record: passed/failed/skipped counts.\n"
        "5. Completed task IDs:\n"
        "     cat logs/completed.txt\n"
        "   Record: count of completed IDs.\n\n"
        "STEP 2 - Cross-reference against the previous round:\n"
        "Read queues/queue-round-" + str(current_round) + ".yaml.\n"
        "For EACH task in that file: check whether the live output from Step 1 confirms\n"
        "it is now fixed/done. If it is done, mark it [DONE - skip]. If it is still\n"
        "present in the live output, mark it [STILL OPEN - consider re-queuing].\n"
        "Only tasks that are STILL OPEN (or newly discovered) should appear in round " + str(next_round) + ".\n\n"
        "STEP 3 - Write queues/queue-round-" + str(next_round) + ".yaml.\n"
        "The file MUST:\n"
        "1. Start with a comment header that includes the ACTUAL live metrics from Step 1\n"
        "   (e.g. '# Backend: 2992 passed, 84 failed | Frontend build: 0 warnings | ...')\n"
        "2. Contain 8-12 tasks targeting CONFIRMED gaps from Step 1 only\n"
        "3. Include at least 2 E2E/Playwright tasks if Playwright is set up\n"
        "4. Each task prompt must state the BEFORE metric it is targeting\n"
        "   (e.g. 'Currently: 84 backend test failures. Fix X so the count drops.')\n"
        "5. End with a p3-generate-next-round task referencing round " + str(next_round + 1) + "\n"
        "6. Follow the EXACT same YAML format as overnight-queue-round-" + str(current_round) + ".yaml\n"
        "7. Commit:\n"
        "     git add queues/queue-round-" + str(next_round) + ".yaml && \\\n"
        "     git commit -m '[local-coder] chore: generate overnight-queue-round-" + str(next_round) + ".yaml'\n"
    )
    injected_meta = {
        "id":          "p3-generate-next-round",
        "priority":    "P3",
        "category":    "meta",
        "title":       "Generate overnight-queue-round-" + str(next_round) + ".yaml for continuous loop",
        "prompt":      meta_prompt.strip(),
        "target_repo": "devops",
        "model":       "${DEFAULT_MODEL}",
        "duration":    20,
    }
    output_tasks.append(injected_meta)

for t in output_tasks:
    row = {
        "id":          t["id"],
        "priority":    t["priority"],
        "category":    t["category"],
        "title":       t["title"],
        "prompt":      t["prompt"].strip(),
        "target_repo": t["target_repo"],
        "model":       t.get("model", "${DEFAULT_MODEL}"),
        "duration":    t.get("estimated_duration_minutes", t.get("duration", 30)),
    }
    print(json.dumps(row))
PYEOF
}

# --------------------------------------------------------------------------
# --list mode
# --------------------------------------------------------------------------
if [[ "$LIST_ONLY" == "true" ]]; then
    echo ""
    echo "=== Pending Local Overnight Tasks ==="
    echo ""
    read_queue | python3 -c "
import sys, json
for line in sys.stdin:
    t = json.loads(line)
    print(f\"  [{t['priority']}] {t['id']:<40} repo={t['target_repo']:<8} ~{t['duration']}min  model={t['model']}\")
    print(f\"        {t['title']}\")
    print()
" || true
    echo "Hardcoded skip (already done):"
    for id in "${HARDCODED_SKIP[@]}"; do echo "  - $id"; done
    echo ""
    echo "Completed (from ${COMPLETED_FILE}):"
    cat "${COMPLETED_FILE}" | grep -v '^#' | grep -v '^$' | sed 's/^/  - /' || echo "  (none)"
    echo ""
    exit 0
fi

# --------------------------------------------------------------------------
# Resolve working directory for a target_repo
# --------------------------------------------------------------------------
repo_workdir() {
    local repo="$1"
    case "$repo" in
        backend)  echo "${REPO_ROOT}/backend"  ;;
        frontend) echo "${REPO_ROOT}/frontend" ;;
        devops)   echo "${REPO_ROOT}/devops"   ;;
        *)        echo "${REPO_ROOT}"          ;;
    esac
}

# --------------------------------------------------------------------------
# Run a single task
# --------------------------------------------------------------------------
run_task() {
    local json_line="$1"

    local TASK_ID PRIORITY TITLE REPO MODEL DURATION PROMPT
    TASK_ID=$(echo "$json_line"  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    PRIORITY=$(echo "$json_line" | python3 -c "import sys,json; print(json.load(sys.stdin)['priority'])")
    TITLE=$(echo "$json_line"    | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
    REPO=$(echo "$json_line"     | python3 -c "import sys,json; print(json.load(sys.stdin)['target_repo'])")
    MODEL=$(echo "$json_line"    | python3 -c "import sys,json; print(json.load(sys.stdin)['model'])")
    DURATION=$(echo "$json_line" | python3 -c "import sys,json; print(json.load(sys.stdin)['duration'])")
    PROMPT=$(echo "$json_line"   | python3 -c "import sys,json; print(json.load(sys.stdin)['prompt'])")

    local WORKDIR
    WORKDIR=$(repo_workdir "$REPO")
    local TASK_LOG="${LOGS_DIR}/${TASK_ID}.log"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[$PRIORITY] ${TASK_ID}"
    echo "  Title:   ${TITLE}"
    echo "  Repo:    ${REPO}  (workdir: ${WORKDIR})"
    echo "  Model:   ${MODEL}"
    echo "  Est:     ~${DURATION}min"
    echo "  Log:     ${TASK_LOG}"
    echo ""

    # Build full prompt: preamble + task body
    local FULL_PROMPT
    FULL_PROMPT="${PREAMBLE}
${PROMPT}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would run:"
        echo "    cd ${WORKDIR}"
        echo "    claude --dangerously-skip-permissions -p '<prompt>' --model ${MODEL}"
        echo ""
        return 0
    fi

    # CPU + memory gates: wait for headroom before starting any task.
    # Prevents new tasks from piling on when machine is already saturated.
    _wait_for_cpu_headroom
    _wait_for_memory_headroom

    # Playwright lock: serialize all frontend tasks to prevent browser process explosion.
    # Frontend tasks run Playwright which spawns headless Chrome. Multiple workers
    # doing this simultaneously caused 57 Chrome processes → 99% CPU (incident 2026-05-12).
    local HOLDS_PLAYWRIGHT_LOCK="false"
    if [[ "${REPO}" == "frontend" ]]; then
        _acquire_playwright_lock
        HOLDS_PLAYWRIGHT_LOCK="true"
    fi

    # Write prompt to temp file to avoid shell quoting issues with long strings.
    # Use task ID + PID for uniqueness: macOS mktemp does not support suffixes after X's.
    local PROMPT_FILE="${TMPDIR:-/tmp}/claude-prompt-${TASK_ID}-$$.txt"
    printf '%s' "$FULL_PROMPT" > "$PROMPT_FILE"

    local TASK_START TASK_END ELAPSED
    TASK_START=$(date +%s)

    echo "  Started: $(date)"
    echo ""

    # Run claude from the target repo directory
    # --dangerously-skip-permissions: suppress all permission prompts
    # -p: non-interactive prompt mode (reads prompt from stdin or arg)
    local EXIT_CODE=0
    # CRITICAL: redirect stdin from /dev/null.
    # The while loop driving this function reads from a process substitution
    # pipe <(read_queue). Without this redirect, claude inherits that stdin fd
    # and consumes the remaining queue lines, causing the loop to exit after 1 task.
    # Timeout: 90 minutes max per task. If claude hangs (known failure mode on
    # heavy pytest tasks), kill it and mark the task failed so the loop continues.
    local TASK_TIMEOUT
    case "$PRIORITY" in
        P0) TASK_TIMEOUT=7200 ;;   # 120 min
        P1) TASK_TIMEOUT=5400 ;;   # 90 min
        P2) TASK_TIMEOUT=3600 ;;   # 60 min
        P3) TASK_TIMEOUT=2400 ;;   # 40 min
        *)  TASK_TIMEOUT=5400 ;;
    esac
    local MAX_ATTEMPTS=3
    local ATTEMPT=1

    while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
        # Jitter: 45-135s random delay so simultaneous startup kills don't re-collide
        local JITTER=$(( (RANDOM % 91) + 45 ))
        [[ $ATTEMPT -gt 1 ]] && echo "  ↻ Retry attempt ${ATTEMPT} (startup kill - waiting ${JITTER}s with jitter to stagger re-attempts)..."
        [[ $ATTEMPT -gt 1 ]] && sleep "${JITTER}"

        EXIT_CODE=0
        # Background the pipeline so we can capture the PID for cleanup.
        # $! after a pipeline gives the last command's PID (tee). Killing the
        # process group (-PID) takes down both the subshell and tee together.
        (
            cd "${WORKDIR}"
            timeout "${TASK_TIMEOUT}" \
            claude --dangerously-skip-permissions \
                   -p "$(cat "${PROMPT_FILE}")" \
                   --model "${MODEL}" \
                   < /dev/null
        ) 2>&1 | tee "${TASK_LOG}" &
        ACTIVE_CHILD_PID=$!
        wait "${ACTIVE_CHILD_PID}" || EXIT_CODE=$?
        ACTIVE_CHILD_PID=""

        # timeout exits 124 when it kills the process
        if [[ "${EXIT_CODE}" -eq 124 ]]; then
            echo "" >> "${TASK_LOG}"
            echo "⚠️  TIMEOUT: task exceeded ${TASK_TIMEOUT}s limit and was killed." >> "${TASK_LOG}"
            echo "   Marking as failed and continuing to next task." >> "${TASK_LOG}"
            break  # timeout = task ran but was too slow, no point retrying
        fi

        # Startup kill: exit 137 (SIGKILL) with an empty or near-empty log
        # means the OS killed claude before it could do anything - retry once.
        local LOG_LINES
        LOG_LINES=$(wc -l < "${TASK_LOG}" 2>/dev/null || echo 0)
        if [[ "${EXIT_CODE}" -eq 137 ]] && [[ "${LOG_LINES}" -lt 5 ]]; then
            echo "  ⚠️  Startup kill detected (exit 137, ${LOG_LINES} log lines) - will retry." >> "${TASK_LOG}"
            ATTEMPT=$((ATTEMPT + 1))
            continue
        fi

        break  # task ran (success or real failure), stop retrying
    done

    rm -f "${PROMPT_FILE}"

    TASK_END=$(date +%s)
    ELAPSED=$(( (TASK_END - TASK_START) / 60 ))

    # Release Playwright lock as soon as the task finishes (before returning)
    if [[ "${HOLDS_PLAYWRIGHT_LOCK}" == "true" ]]; then
        _release_playwright_lock
        HOLDS_PLAYWRIGHT_LOCK="false"
        # Brief pause so the next worker can acquire the lock without racing
        sleep 5
    fi

    # Post-task vitest cleanup: unconditionally kill any vitest workers left
    # behind by this task's claude invocation. Timeout/SIGKILL don't propagate
    # to grandchild node processes. This is safe to do unconditionally because
    # the Playwright lock above guarantees only one frontend task runs at a time -
    # there is no concurrent legitimate vitest process to protect here.
    if [[ "${REPO}" == "frontend" ]]; then
        pkill -f vitest 2>/dev/null || true
    fi

    if [[ $EXIT_CODE -eq 0 ]]; then
        echo ""
        echo "  ✓ ${TASK_ID} completed in ${ELAPSED}min"
        # Record as completed so re-runs skip it
        echo "${TASK_ID}" >> "${COMPLETED_FILE}"
    else
        echo ""
        echo "  ✗ ${TASK_ID} FAILED (exit ${EXIT_CODE}) after ${ELAPSED}min - continuing to next task"
        echo "    See: ${TASK_LOG}"
    fi

    echo ""
    return $EXIT_CODE
}

# --------------------------------------------------------------------------
# Main run loop
# --------------------------------------------------------------------------
TOTAL=0
LAUNCHED=0
FAILED=0
FAILED_TASKS=()
START_EPOCH=$(date +%s)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Local Coder - Local Overnight Run                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Started:    $(date)"
echo "  Queue:      ${QUEUE}"
echo "  Repo root:  ${REPO_ROOT}"
echo "  Logs:       ${LOGS_DIR}/"
echo "  Completed:  ${COMPLETED_FILE}"
[[ -n "$PRIORITY_FILTER" ]] && echo "  Filter:     ${PRIORITY_FILTER} only"
[[ -n "$EXTRA_SKIP_IDS"  ]] && echo "  Extra skip: ${EXTRA_SKIP_IDS}"
[[ "$DRY_RUN" == "true"  ]] && echo "  Mode:       *** DRY RUN ***"
echo ""

if [[ -n "${LOOP_NAME:-}" ]]; then
    _STAGGER=$(( RANDOM % 120 ))
    [[ $_STAGGER -gt 0 ]] && { echo "  Parallel stagger: ${_STAGGER}s (LOOP_NAME=${LOOP_NAME})"; sleep "$_STAGGER"; }
fi

while IFS= read -r line; do
    TOTAL=$((TOTAL + 1))
    _TASK_ID=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    if run_task "$line"; then
        LAUNCHED=$((LAUNCHED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_TASKS+=("${_TASK_ID}")
    fi
done < <(read_queue)

END_EPOCH=$(date +%s)
TOTAL_ELAPSED=$(( (END_EPOCH - START_EPOCH) / 60 ))

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Overnight Run Complete                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Finished:  $(date)"
echo "  Duration:  ${TOTAL_ELAPSED}min"
echo "  Tasks:     ${TOTAL} queued  |  ${LAUNCHED} succeeded  |  ${FAILED} failed"
echo "  Logs:      ${LOGS_DIR}/"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "  Failed tasks (this run):"
    for _fid in "${FAILED_TASKS[@]}"; do
        echo "    ${LOGS_DIR}/${_fid}.log"
    done
    echo ""
    exit 1
fi
