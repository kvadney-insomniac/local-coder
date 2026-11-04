#!/usr/bin/env bash
# board-lib.sh — Shared functions for board-driven local coder workers.
# Source this file; do not execute directly.
#
# Provides:
#   Board constants & GraphQL helpers (query items, move items, assign/unassign)
#   Safety mechanisms extracted from run-local-overnight.sh (CPU/mem gates, Playwright lock, cleanup)
#   Discipline preamble injected into every Claude invocation

# --------------------------------------------------------------------------
# Board constants
# --------------------------------------------------------------------------
BOARD_PROJECT_OWNER="YourProject-Hedge-Fund-Guy"
BOARD_PROJECT_NUMBER=10
BOARD_PROJECT_ID="PVT_kwDODpQbDc4BU10i"
BOARD_STATUS_FIELD_ID="PVTSSF_lADODpQbDc4BU10izhFF2ME"
# Assignee for worker-claimed issues. Default is the operator's personal account
# until the `local-coder-bot` GitHub user is provisioned (see
# LOCAL-CODER-BOT-SETUP.md). Override via env var to swap without code change.
BOARD_ASSIGNEE="${BOARD_ASSIGNEE:-${BOARD_OWNER:-your-github-handle}}"

# Status option IDs (from live board query 2026-05-13)
BOARD_OPT_IDEAS="563c1c95"
BOARD_OPT_BACKLOG="7ad74ff1"
BOARD_OPT_ASSIGNED="f55ad682"
BOARD_OPT_IN_PROGRESS="d1448f2d"
BOARD_OPT_REDO="a7b885d5"
BOARD_OPT_UI_TESTING="d39d1564"
BOARD_OPT_PROD_READY="acd154ac"
BOARD_OPT_RELEASED="e1a87156"

# Paths
BOARD_REPO_ROOT="${BOARD_REPO_ROOT:-${REPO_ROOT:?REPO_ROOT must be set — source config/config.sh first}}"
BOARD_LOGS_DIR="${BOARD_LOGS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logs}"
BOARD_BACKEND_DIR="${BOARD_REPO_ROOT}/backend"
BOARD_FRONTEND_DIR="${BOARD_REPO_ROOT}/frontend"
BOARD_DEVOPS_DIR="${BOARD_REPO_ROOT}/devops"

mkdir -p "${BOARD_LOGS_DIR}"

# --------------------------------------------------------------------------
# Discipline preamble — prepended to every Claude invocation
# --------------------------------------------------------------------------
read -r -d '' BOARD_PREAMBLE <<'PREAMBLE_EOF' || true
IMPORTANT RULES FOR THIS TASK — READ BEFORE DOING ANYTHING:
1. Work on the dev branch directly unless told to create a feature branch.
2. Do NOT delete or comment-out existing features to fix errors — fix the actual error.
3. Before committing, run the full test suite and verify it passes (no new failures beyond known baseline).
4. Commit with a clear, accurate message describing what changed and why.
5. If tests fail due to your changes, fix them before committing. Pre-existing failures (~63 backend) are OK.
6. Backend test command: cd backend && ${BACKEND_TEST_CMD:-python -m pytest tests/ --tb=short -q}
7. Frontend test command: cd frontend && npm run build && npm test -- --run
8. Scope strictly to the task — no speculative refactoring or unrequested features.

TASK:
PREAMBLE_EOF

# --------------------------------------------------------------------------
# Repo helpers
# --------------------------------------------------------------------------
board_repo_workdir() {
    local repo="$1"
    case "$repo" in
        backend)  echo "${BOARD_BACKEND_DIR}" ;;
        frontend) echo "${BOARD_FRONTEND_DIR}" ;;
        devops)   echo "${BOARD_DEVOPS_DIR}" ;;
        *)        echo "${BOARD_REPO_ROOT}" ;;
    esac
}

board_stack_hint() {
    local repo="$1"
    case "$repo" in
        backend)  echo "FastAPI / Python backend. Boring code over clever. Run pytest after changes." ;;
        frontend) echo "Next.js 14 / TypeScript / Tailwind frontend. Match existing component patterns." ;;
        devops)   echo "Terraform / GCP / GitHub Actions devops repo." ;;
        *)        echo "" ;;
    esac
}

board_test_cmd() {
    local repo="$1"
    case "$repo" in
        backend)  echo "${BACKEND_TEST_CMD:-python -m pytest tests/ --tb=short -q}" ;;
        frontend) echo "npm run build && npm test -- --run" ;;
        *)        echo "echo 'no automated tests'" ;;
    esac
}

# --------------------------------------------------------------------------
# Board GraphQL helpers
# --------------------------------------------------------------------------
board_move_item() {
    local item_id="$1"
    local option_id="$2"
    gh api graphql -f query="
      mutation {
        updateProjectV2ItemFieldValue(input: {
          projectId: \"${BOARD_PROJECT_ID}\"
          itemId: \"${item_id}\"
          fieldId: \"${BOARD_STATUS_FIELD_ID}\"
          value: { singleSelectOptionId: \"${option_id}\" }
        }) { projectV2Item { id } }
      }
    " 2>/dev/null
}

board_query_items() {
    local status_name="$1"
    local target_filter="${2:-both}"

    local cursor=""
    local has_next="true"
    local all_nodes="[]"

    while [[ "${has_next}" == "true" ]]; do
        local after_clause=""
        if [[ -n "${cursor}" ]]; then
            after_clause=", after: \"${cursor}\""
        fi
        local page
        page=$(gh api graphql -f query='
        {
          organization(login: "'"${BOARD_PROJECT_OWNER}"'") {
            projectV2(number: '"${BOARD_PROJECT_NUMBER}"') {
              items(first: 100'"${after_clause}"') {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id
                  fieldValues(first: 20) {
                    nodes {
                      ... on ProjectV2ItemFieldSingleSelectValue {
                        name
                        field { ... on ProjectV2SingleSelectField { name } }
                      }
                    }
                  }
                  content {
                    ... on Issue {
                      number title
                      repository { name }
                      labels(first: 10) { nodes { name } }
                      assignees(first: 3) { nodes { login } }
                    }
                  }
                }
              }
            }
          }
        }' 2>/dev/null)
        if [[ -z "${page}" ]]; then
            break
        fi
        # Merge this page's nodes into all_nodes
        all_nodes=$(python3 -c "
import json, sys
prev = json.loads(sys.argv[1])
page = json.loads(sys.argv[2])
nodes = page.get('data', {}).get('organization', {}).get('projectV2', {}).get('items', {}).get('nodes', []) or []
print(json.dumps(prev + nodes))
" "${all_nodes}" "${page}")
        has_next=$(echo "${page}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pi = d.get('data', {}).get('organization', {}).get('projectV2', {}).get('items', {}).get('pageInfo', {}) or {}
print('true' if pi.get('hasNextPage') else 'false')
")
        cursor=$(echo "${page}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pi = d.get('data', {}).get('organization', {}).get('projectV2', {}).get('items', {}).get('pageInfo', {}) or {}
print(pi.get('endCursor') or '')
")
        if [[ -z "${cursor}" ]]; then
            break
        fi
    done

    echo "${all_nodes}" | python3 -c "
import json, sys

items = json.load(sys.stdin)

SKIP_LABELS = {'epic', 'needs-design', 'agentic-autonomy'}
PRIO_ORDER  = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3, None: 50}
STATUS_FILTER = '${status_name}'
TARGET = '${target_filter}'

candidates = []
for item in items:
    content = item.get('content') or {}
    if not content.get('number'): continue

    fvs = {(f.get('field') or {}).get('name'): f.get('name')
           for f in item.get('fieldValues', {}).get('nodes', []) if f}
    status   = fvs.get('Status', '')
    priority = fvs.get('Priority')

    if status != STATUS_FILTER: continue

    labels    = {l['name'] for l in content.get('labels', {}).get('nodes', [])}
    assignees = [a['login'] for a in content.get('assignees', {}).get('nodes', [])]
    repo      = content.get('repository', {}).get('name', '')

    # Treat the repo owner as non-blocking — GitHub auto-assigns the issue
    # author, which would otherwise make every fresh Backlog item look claimed.
    NON_BLOCKING_ASSIGNEES = {'${BOARD_OWNER:-your-github-handle}', 'your-github-handle'}
    blocking_assignees = [a for a in assignees if a not in NON_BLOCKING_ASSIGNEES]

    if labels & SKIP_LABELS: continue

    if TARGET == 'backend'  and repo != 'backend':  continue
    if TARGET == 'frontend' and repo != 'frontend': continue

    candidates.append({
        'item_id':  item['id'],
        'issue_num': content['number'],
        'repo':     repo,
        'title':    content['title'],
        'priority': priority or 'P2',
        'labels':   list(labels),
        'assigned': bool(blocking_assignees),
    })

candidates.sort(key=lambda x: PRIO_ORDER.get(x['priority'], 50))
for c in candidates:
    print(json.dumps(c))
"
}

board_assign_issue() {
    local issue_num="$1"
    local repo="$2"
    gh issue edit "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --add-assignee "${BOARD_ASSIGNEE}" 2>/dev/null || true
}

# ---- Inter-worker coordination via issue-body lock marker ---------------
# Each worker, when it commits to picking up an issue, embeds an HTML
# comment in the issue body:
#
#     <!-- lc-lock: worker=<name> until=<ISO-8601-Z> -->
#
# Other workers parse the body for this marker, compare `until` to now,
# and skip the issue if a different worker holds a live lock. When the
# lock expires the next worker overwrites it.
#
# Caveat: `gh issue edit --body` is a full-body read-modify-write. Two
# workers racing simultaneously can clobber each other. The collision
# window is small (one HTTP roundtrip) and the per-worker failure is
# benign (the loser's lock is overwritten and it proceeds anyway, then
# the next iteration sees the winner's lock and skips).

BOARD_LOCK_BODY_RE='<!--[[:space:]]*lc-lock:[^>]*-->'
BOARD_CLAIM_WINDOW_MIN="${BOARD_CLAIM_WINDOW_MIN:-30}"

# Strip any existing lc-lock marker from a body string (stdin → stdout).
_board_strip_lock_marker() {
    sed -E 's|<!--[[:space:]]*lc-lock:[^>]*-->||g'
}

# Read the active lock holder from an issue body, if the lock is unexpired
# and held by someone other than $self. Returns worker name on stdout, or
# empty if no blocking lock.
board_get_active_lock_holder() {
    local issue_num="$1"
    local repo="$2"
    local self="${BOARD_WORKER_NAME:-unknown}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    gh issue view "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --json body --jq '.body' 2>/dev/null \
        | python3 -c "
import re, sys
body = sys.stdin.read()
m = re.search(r'<!--\s*lc-lock:\s*worker=(\S+)\s+until=(\S+?)\s*-->', body)
if not m: sys.exit(0)
worker, until = m.group(1), m.group(2)
now = '${now}'
self_name = '${self}'
# ISO-8601 Z strings sort lexicographically as time order.
if until <= now: sys.exit(0)        # lock expired — free
if worker == self_name: sys.exit(0) # our own lock — not blocking
print(worker)
" 2>/dev/null
}

# Acquire (or refresh) the body lock for this issue. Strips any prior
# lc-lock marker and appends a fresh one with `until = now + window`.
board_post_claim() {
    local issue_num="$1"
    local repo="$2"
    local self="${BOARD_WORKER_NAME:-unknown}"
    local until
    until=$(date -u -v+"${BOARD_CLAIM_WINDOW_MIN}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "+${BOARD_CLAIM_WINDOW_MIN} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || echo "2099-01-01T00:00:00Z")
    local body
    body=$(gh issue view "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --json body --jq '.body' 2>/dev/null || echo "")
    local new_body
    new_body=$(printf '%s' "${body}" | _board_strip_lock_marker)
    # Trim trailing whitespace, then append the new marker on its own line.
    new_body=$(printf '%s\n\n<!-- lc-lock: worker=%s until=%s -->\n' \
        "$(printf '%s' "${new_body}" | sed -E 's/[[:space:]]+$//')" \
        "${self}" "${until}")
    gh issue edit "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --body "${new_body}" >/dev/null 2>&1 || true
}

# Remove our lock marker from the issue body. Safe no-op if none present.
board_release_claim() {
    local issue_num="$1"
    local repo="$2"
    local body
    body=$(gh issue view "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --json body --jq '.body' 2>/dev/null || echo "")
    if ! printf '%s' "${body}" | grep -Eq "${BOARD_LOCK_BODY_RE}"; then
        return 0
    fi
    local new_body
    new_body=$(printf '%s' "${body}" | _board_strip_lock_marker | sed -E 's/[[:space:]]+$//')
    gh issue edit "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --body "${new_body}" >/dev/null 2>&1 || true
}

board_unassign_issue() {
    local issue_num="$1"
    local repo="$2"
    gh issue edit "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --remove-assignee "${BOARD_ASSIGNEE}" 2>/dev/null || true
}

board_get_issue_body() {
    local issue_num="$1"
    local repo="$2"
    gh issue view "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --json body --jq '.body' 2>/dev/null
}

board_comment_issue() {
    local issue_num="$1"
    local repo="$2"
    local body="$3"
    gh issue comment "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --body "$body" 2>/dev/null || true
}

board_get_item_id() {
    local issue_num="$1"
    local repo="$2"
    gh issue view "$issue_num" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
        --json projectItems --jq '.projectItems[0].id' 2>/dev/null
}

# --------------------------------------------------------------------------
# Completion tracking (by issue number)
# --------------------------------------------------------------------------
board_completed_file() {
    local worker_name="$1"
    echo "${BOARD_LOGS_DIR}/${worker_name}.board-completed.txt"
}

board_is_completed() {
    local issue_num="$1"
    local completed_file="$2"
    grep -qx "${issue_num}" "${completed_file}" 2>/dev/null
}

board_mark_completed() {
    local issue_num="$1"
    local completed_file="$2"
    echo "${issue_num}" >> "${completed_file}"
}

# --------------------------------------------------------------------------
# Orphan cleanup (extracted from run-local-overnight.sh)
# --------------------------------------------------------------------------
board_cleanup_orphan_browsers() {
    local chrome_count
    chrome_count=$(pgrep -f "chrome-headless-shell" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${chrome_count:-0}" -gt 10 ]]; then
        echo "  [cleanup] ${chrome_count} orphaned chrome-headless-shell — killing"
        pkill -f "chrome-headless-shell" 2>/dev/null || true
        sleep 2
    fi
}

board_cleanup_orphan_vitest() {
    local vitest_count
    vitest_count=$(pgrep -c -f 'vitest' 2>/dev/null || echo 0)
    if [[ "${vitest_count:-0}" -gt 4 ]]; then
        echo "  [cleanup] ${vitest_count} orphaned vitest processes — killing"
        pkill -f vitest 2>/dev/null || true
        sleep 2
    fi
}

# --------------------------------------------------------------------------
# Playwright global mutex (extracted from run-local-overnight.sh)
# --------------------------------------------------------------------------
BOARD_PLAYWRIGHT_LOCK_DIR="${BOARD_LOGS_DIR}/playwright.lock.d"

board_acquire_playwright_lock() {
    local waited=0
    while ! mkdir "${BOARD_PLAYWRIGHT_LOCK_DIR}" 2>/dev/null; do
        local holder="(unknown)"
        [[ -f "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder" ]] && holder=$(cat "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder")
        if [[ $waited -eq 0 ]]; then
            echo "  [lock] Playwright lock held by ${holder} — waiting..."
        fi
        sleep 30
        waited=$((waited + 30))
        if [[ $waited -gt 60 ]] && [[ -f "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder" ]]; then
            local holder_pid
            holder_pid=$(cat "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder" | cut -d: -f1)
            if [[ -n "${holder_pid}" ]] && ! kill -0 "${holder_pid}" 2>/dev/null; then
                echo "  [lock] Holder PID ${holder_pid} is dead — breaking stale lock"
                rm -rf "${BOARD_PLAYWRIGHT_LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi
        if [[ $waited -gt 5400 ]]; then
            echo "  [lock] Wait exceeded 90 min — breaking lock"
            rm -rf "${BOARD_PLAYWRIGHT_LOCK_DIR}" 2>/dev/null || true
        fi
    done
    echo "$$:${BOARD_WORKER_NAME:-board-worker}" > "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder"
}

board_release_playwright_lock() {
    if [[ -d "${BOARD_PLAYWRIGHT_LOCK_DIR}" ]]; then
        local holder=""
        [[ -f "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder" ]] && holder=$(cat "${BOARD_PLAYWRIGHT_LOCK_DIR}/holder")
        local holder_pid
        holder_pid=$(echo "${holder}" | cut -d: -f1)
        if [[ "${holder_pid}" == "$$" ]]; then
            rm -rf "${BOARD_PLAYWRIGHT_LOCK_DIR}" 2>/dev/null || true
        fi
    fi
}

# --------------------------------------------------------------------------
# CPU load gate (extracted from run-local-overnight.sh)
# --------------------------------------------------------------------------
board_wait_for_cpu() {
    local cores
    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    local threshold
    threshold=$(( cores + cores / 2 ))
    local waited=0
    while true; do
        local load
        load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' | cut -d. -f1)
        if [[ "${load:-0}" -le "${threshold}" ]]; then
            break
        fi
        if [[ $waited -eq 0 ]]; then
            echo "  [gate] CPU load ${load} > threshold ${threshold} — waiting..."
        fi
        sleep 30
        waited=$((waited + 30))
        if [[ $waited -gt 600 ]]; then
            echo "  [gate] CPU still loaded after 10 min — proceeding"
            break
        fi
    done
}

# --------------------------------------------------------------------------
# Memory pressure gate (extracted from run-local-overnight.sh)
# --------------------------------------------------------------------------
board_wait_for_memory() {
    local MAX_ATTEMPTS=20
    local attempt=0
    while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
        local FREE_PAGES INACTIVE_PAGES AVAIL_MB
        FREE_PAGES=$(vm_stat | awk '/Pages free/{gsub(/\./,"",$3); print $3}')
        INACTIVE_PAGES=$(vm_stat | awk '/Pages inactive/{gsub(/\./,"",$3); print $3}')
        AVAIL_MB=$(( (${FREE_PAGES:-0} + ${INACTIVE_PAGES:-0}) * 4096 / 1024 / 1024 ))

        local COMPRESSOR_PAGES TOTAL_MB COMPRESSOR_MB
        COMPRESSOR_PAGES=$(vm_stat | awk '/stored in compressor/{gsub(/\./,"",$5); print $5}')
        TOTAL_MB=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
        COMPRESSOR_MB=$(( ${COMPRESSOR_PAGES:-0} * 4096 / 1024 / 1024 ))
        if [[ "${COMPRESSOR_MB}" -gt $(( TOTAL_MB / 2 )) ]]; then
            if [[ $attempt -eq 0 ]]; then
                echo "  [gate] Memory compressor thrashing: ${COMPRESSOR_MB}MB compressed (${TOTAL_MB}MB total)"
                board_cleanup_orphan_vitest
                board_cleanup_orphan_browsers
            fi
            sleep 30
            attempt=$((attempt + 1))
            continue
        fi

        # On macOS, AVAIL_MB is misleading — the OS aggressively uses RAM for
        # file cache, so "available" stays low even with zero pressure. The
        # compressor check above is the real thrashing signal. Keep this at 0
        # so it never blocks; the compressor + launchd memory-watchdog handle
        # real pressure.
        if [[ "${AVAIL_MB}" -gt 0 ]]; then
            return 0
        fi
        if [[ $attempt -eq 0 ]]; then
            echo "  [gate] AVAIL_MB=0 (extreme) — waiting..."
            board_cleanup_orphan_vitest
        fi
        sleep 30
        attempt=$((attempt + 1))
    done
    echo "  [gate] Memory pressure persists after 10 min — proceeding"
}

# --------------------------------------------------------------------------
# Run Claude on a task (with timeout, retry, logging)
# --------------------------------------------------------------------------
BOARD_ACTIVE_CHILD_PID=""

board_run_claude() {
    local workdir="$1"
    local prompt="$2"
    local model="${3:-${LOCAL_CODER_DEFAULT_MODEL:-claude-opus-5-5}}"
    local priority="${4:-P2}"
    local task_label="${5:-task}"
    local task_log="${BOARD_LOGS_DIR}/${task_label}.log"

    local TASK_TIMEOUT
    case "$priority" in
        P0) TASK_TIMEOUT=7200 ;;
        P1) TASK_TIMEOUT=5400 ;;
        P2) TASK_TIMEOUT=3600 ;;
        P3) TASK_TIMEOUT=2400 ;;
        *)  TASK_TIMEOUT=5400 ;;
    esac

    local PROMPT_FILE="/tmp/claude-prompt-${task_label}-$$.txt"
    printf '%s' "${BOARD_PREAMBLE}
${prompt}" > "$PROMPT_FILE"

    local MAX_ATTEMPTS=3
    local ATTEMPT=1
    local EXIT_CODE=0
    local TASK_START
    TASK_START=$(date +%s)

    while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
        local JITTER=$(( (RANDOM % 91) + 45 ))
        [[ $ATTEMPT -gt 1 ]] && echo "  [retry] Attempt ${ATTEMPT} (waiting ${JITTER}s)..." && sleep "${JITTER}"

        EXIT_CODE=0
        (
            cd "${workdir}"
            timeout "${TASK_TIMEOUT}" \
            claude --dangerously-skip-permissions \
                   -p "$(cat "${PROMPT_FILE}")" \
                   --model "${model}" \
                   < /dev/null
        ) 2>&1 | tee "${task_log}" &
        BOARD_ACTIVE_CHILD_PID=$!
        wait "${BOARD_ACTIVE_CHILD_PID}" || EXIT_CODE=$?
        BOARD_ACTIVE_CHILD_PID=""

        if [[ "${EXIT_CODE}" -eq 124 ]]; then
            echo "  [timeout] Task exceeded ${TASK_TIMEOUT}s — killed" >> "${task_log}"
            break
        fi

        local LOG_LINES
        LOG_LINES=$(wc -l < "${task_log}" 2>/dev/null || echo 0)
        if [[ "${EXIT_CODE}" -eq 137 ]] && [[ "${LOG_LINES}" -lt 5 ]]; then
            echo "  [startup-kill] Exit 137, ${LOG_LINES} log lines — will retry" >> "${task_log}"
            ATTEMPT=$((ATTEMPT + 1))
            continue
        fi

        break
    done

    rm -f "${PROMPT_FILE}"

    local TASK_END ELAPSED
    TASK_END=$(date +%s)
    ELAPSED=$(( (TASK_END - TASK_START) / 60 ))

    if [[ $EXIT_CODE -eq 0 ]]; then
        echo "  [done] ${task_label} completed in ${ELAPSED}min"
    else
        echo "  [fail] ${task_label} FAILED (exit ${EXIT_CODE}) after ${ELAPSED}min"
    fi

    return $EXIT_CODE
}

# --------------------------------------------------------------------------
# Cleanup trap helper
# --------------------------------------------------------------------------
board_cleanup() {
    if [[ -n "${BOARD_ACTIVE_CHILD_PID:-}" ]]; then
        kill -- "-${BOARD_ACTIVE_CHILD_PID}" 2>/dev/null || kill "${BOARD_ACTIVE_CHILD_PID}" 2>/dev/null || true
        wait "${BOARD_ACTIVE_CHILD_PID}" 2>/dev/null || true
    fi
    rm -f /tmp/claude-prompt-*-$$.txt 2>/dev/null || true
    board_release_playwright_lock
}

# --------------------------------------------------------------------------
# Slug helper (title → branch-safe slug)
# --------------------------------------------------------------------------
board_slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40
}
