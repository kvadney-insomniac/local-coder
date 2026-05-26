#!/usr/bin/env bash
# board-worker.sh — Board-driven local coder worker.
#
# Pulls tasks directly from the GitHub project board instead of static YAML queues.
# Four modes, each targeting a different board column:
#
#   --mode ideas          Ideas → flesh out → Backlog
#   --mode backlog        Backlog → branch → implement → PR (auto-moves on merge)
#   --mode verify-staging "ui testing in staging" → curl/screenshot verify → comment pass/fail
#   --mode rescue         In Progress → find CI-red PR → fix → push (author-filtered)
#   --mode reap           In Progress → if no branch/PR/assignee → return to Backlog
#
# Usage:
#   bash board-worker.sh --mode backlog --target backend
#   bash board-worker.sh --mode ideas --target both --dry-run
#   bash board-worker.sh --mode verify-staging
#
# Options:
#   --mode <mode>         Required. One of: ideas, backlog, verify-staging
#   --target <filter>     backend | frontend | both (default: both)
#   --dry-run             Print tasks without executing
#   --max-tasks <n>       Max tasks to process this session (default: 20)
#   --help                Show this help
#
# Background (recommended):
#   BOARD_WORKER_NAME=backlog-backend nohup bash board-worker.sh --mode backlog --target backend \
#     > logs/backlog-backend.log 2>&1 &

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/board-lib.sh"

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
MODE=""
TARGET_FILTER="both"
DRY_RUN="false"
MAX_TASKS=20
BOARD_WORKER_NAME="${BOARD_WORKER_NAME:-board-worker-$$}"

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)       MODE="$2";           shift 2 ;;
        --target)     TARGET_FILTER="$2";  shift 2 ;;
        --dry-run)    DRY_RUN="true";      shift ;;
        --max-tasks)  MAX_TASKS="$2";      shift 2 ;;
        --help|-h)
            sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "ERROR: --mode is required (ideas | backlog | verify-staging)" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------
trap 'board_cleanup' EXIT INT TERM HUP
board_cleanup_orphan_browsers
board_cleanup_orphan_vitest

COMPLETED_FILE=$(board_completed_file "${BOARD_WORKER_NAME}")
touch "${COMPLETED_FILE}"

# Session-only skip cache. Rescue/reap mark items they couldn't address
# (no PR, has open PR, has branch, etc) as "skipped" so the inner loop
# doesn't re-poll them within this session. Crucially this is per-PID
# and discarded on exit — next session re-evaluates state, since whether
# an issue is rescue/reap-able depends on the current PR/branch state.
# Without this separation, skipped items would either (a) be re-polled
# forever in-session, or (b) be marked permanently completed and never
# re-checked when their state changes — the 2026-05-15 bug that made
# rescue exit after 3 iterations because 41 prior-session skips had
# poisoned the completed file.
SKIPPED_FILE=$(mktemp -t "board-worker-skip-XXXXXX")
_orig_cleanup=$(declare -f board_cleanup 2>/dev/null || true)
trap "rm -f \"${SKIPPED_FILE}\"; board_cleanup" EXIT INT TERM HUP

PROCESSED=0
FAILED=0
FAILED_ISSUES=()
START_EPOCH=$(date +%s)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Board Worker — ${MODE}                              "
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Started:  $(date)"
echo "  Mode:     ${MODE}"
echo "  Target:   ${TARGET_FILTER}"
echo "  Worker:   ${BOARD_WORKER_NAME}"
echo "  Max:      ${MAX_TASKS} tasks"
[[ "$DRY_RUN" == "true" ]] && echo "  Mode:     *** DRY RUN ***"
echo ""

# --------------------------------------------------------------------------
# Mode: IDEAS — flesh out issues and move to Backlog
# --------------------------------------------------------------------------
run_ideas_mode() {
    local issue_num="$1" repo="$2" item_id="$3" title="$4"
    local workdir
    workdir=$(board_repo_workdir "$repo")

    local prompt
    prompt="IDEAS TRIAGE — Convert Issue #${issue_num} into a well-defined Backlog item.

You are working in the ${repo} repo at ${workdir}.

STEP 1 — Read the issue:
  gh issue view ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} --json body,title,labels

STEP 2 — Research the feature area (2-3 targeted greps + file reads):
  grep -r \"<keywords from title>\" ${workdir}/app/ --include=\"*.py\" -l 2>/dev/null | head -5
  (or for frontend: grep in ${workdir}/src/ --include=\"*.ts\" --include=\"*.tsx\")

STEP 3 — Write a structured issue body using this EXACT template:

## Problem
<1-2 sentences: what user or technical need does this address>

## Acceptance Criteria
- [ ] <specific testable criterion>
- [ ] <another criterion>
- [ ] Unit/integration tests written and passing
- [ ] No regression in related features

## Technical Approach
**Files to modify:**
- \`<path>\` — <what changes>

**Pattern to follow:** <reference existing similar code>

**Migration needed:** Yes / No

**Cross-repo:** Backend only / Frontend only / Both

## Complexity
**S / M / L / XL** — <one sentence justification>

## Dependencies
- #<N> — <title> — <why>
(or: None)

## Out of Scope
- <what this does NOT include>

STEP 4 — Update the issue body:
  Write the new body to /tmp/issue-body-${issue_num}.md
  gh issue edit ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} --body \"\$(cat /tmp/issue-body-${issue_num}.md)\"
  rm /tmp/issue-body-${issue_num}.md

STEP 5 — Post a comment:
  gh issue comment ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} \\
    --body \"Triaged from Ideas to Backlog by board-worker. Added acceptance criteria, technical approach, and complexity estimate.\"

If the issue is too ambiguous to triage, post a comment saying so and leave it in Ideas.
Otherwise, output exactly: ISSUE_COMPLETE:#${issue_num}"

    local task_label="ideas-${repo}-${issue_num}"
    board_run_claude "${workdir}" "${prompt}" "claude-opus-4-6" "P1" "${task_label}"
    local exit_code=$?

    local task_log="${BOARD_LOGS_DIR}/${task_label}.log"
    if [[ $exit_code -eq 0 ]] && grep -q "ISSUE_COMPLETE:#${issue_num}" "${task_log}" 2>/dev/null; then
        board_move_item "${item_id}" "${BOARD_OPT_BACKLOG}"
        echo "  [board] #${issue_num} moved to Backlog"
        return 0
    else
        echo "  [skip] #${issue_num} not moved (incomplete or ambiguous)"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Mode: BACKLOG — implement and PR
# --------------------------------------------------------------------------
run_backlog_mode() {
    local issue_num="$1" repo="$2" item_id="$3" title="$4" priority="$5"
    local workdir
    workdir=$(board_repo_workdir "$repo")
    local stack
    stack=$(board_stack_hint "$repo")
    local test_cmd
    test_cmd=$(board_test_cmd "$repo")
    local slug
    slug=$(board_slugify "$title")

    # Pre-flight: if a branch with this issue number already exists on
    # origin, another worker has already started this issue. Skip rather
    # than re-implementing on top of their work-in-progress branch.
    # (Advisor flag 2026-05-18.)
    if git -C "${workdir}" ls-remote --heads origin "local-coder/${issue_num}-*" 2>/dev/null | grep -q .; then
        echo "  [skip] #${issue_num} — origin already has local-coder/${issue_num}-* branch"
        return 2
    fi

    # NOTE: assignment, In Progress move, and lock-acquire are intentionally
    # deferred until AFTER Claude has actually pushed a branch (see post-run
    # block below). This makes failed attempts leave NO board trace, which
    # was the dominant source of comment-spam noise pre-2026-05-18.

    local issue_body
    issue_body=$(board_get_issue_body "${issue_num}" "${repo}")

    local prompt
    prompt="You are working on the YourProject Hedge Fund ${repo} repo at ${workdir}.
Stack: ${stack}

## Issue #${issue_num}: ${title}

${issue_body}

## Workflow — FULL PIPELINE (implement → PR → review → fix → merge)

### Phase 1: Implement
1. cd ${workdir}
2. git checkout dev && git pull origin dev
3. git checkout -b local-coder/${issue_num}-${slug}
4. Implement fully per the Acceptance Criteria in the issue body above
5. Run the full CI script before creating the PR:
   bash scripts/run-all-ci.sh
   If it fails, fix the issues and re-run until it passes.
6. git add -A && git commit -m '[local-coder] feat: resolve #${issue_num} — ${title}

Co-Authored-By: Local Coder <local-coder@example.com>
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>'
7. git push origin local-coder/${issue_num}-${slug}
8. Tick off any acceptance criteria you completed in the issue body:
   BODY=\$(gh issue view ${issue_num} --repo ${BOARD_PROJECT_OWNER}/${repo} --json body --jq '.body')
   # Replace - [ ] with - [x] for completed criteria, then:
   gh issue edit ${issue_num} --repo ${BOARD_PROJECT_OWNER}/${repo} --body \"\$UPDATED_BODY\"

### Phase 2: Create PR
9. gh pr create --title 'feat: resolve #${issue_num} — ${title}' \\
     --body 'closes #${issue_num}

Co-Authored-By: Local Coder <local-coder@example.com>
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>' \\
     --repo ${BOARD_PROJECT_OWNER}/${repo}
   Capture the PR number from the output.

### Phase 3: Self-review and fix
10. Review your own PR for issues:
    gh pr diff <PR_NUMBER> --repo ${BOARD_PROJECT_OWNER}/${repo}
    Check for: missing error handling, unused imports, broken tests, type errors,
    security issues (SQL injection, XSS, hardcoded secrets), missing closes #N in body.
11. If you find issues: fix them, commit, push. Repeat step 10 until clean.

### Phase 4: Merge
12. Merge the PR (squash merge to dev):
    gh pr merge <PR_NUMBER> --squash --repo ${BOARD_PROJECT_OWNER}/${repo}
    If merge fails (conflicts, checks), diagnose and fix. Pull dev, rebase, push, retry.

### Phase 5: Verify
13. Verify the board column updated:
    gh issue view ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} --json projectItems --jq '.projectItems[0].status.name'
    Expected: 'ui testing in staging' (auto-set by GitHub Actions on dev merge).
14. Wait 60 seconds for staging deploy, then smoke-test:
    curl -s -o /dev/null -w '%{http_code}' ${STAGING_BACKEND_URL:-https://your-backend-staging.example.com}/health
    curl -s -o /dev/null -w '%{http_code}' ${STAGING_FRONTEND_URL:-https://your-frontend-staging.example.com}
15. Output exactly: ISSUE_COMPLETE:#${issue_num}"

    local task_label="backlog-${repo}-${issue_num}"
    board_run_claude "${workdir}" "${prompt}" "claude-opus-4-6" "${priority}" "${task_label}"
    local exit_code=$?

    local task_log="${BOARD_LOGS_DIR}/${task_label}.log"

    # Work-then-claim (B5, 2026-05-18): only touch the board if Claude
    # actually pushed a branch. Detect via `git ls-remote` against the
    # canonical local-coder/<issue>-<slug> pattern; an exact slug match
    # isn't required (slugs can vary slightly) — any branch starting
    # with local-coder/<issue>- is treated as proof of work.
    local pushed_branch
    pushed_branch=$(git -C "${workdir}" ls-remote --heads origin "local-coder/${issue_num}-*" 2>/dev/null \
        | awk '{print $2}' | sed 's|^refs/heads/||' | head -1)

    if [[ -n "$pushed_branch" ]]; then
        # Worker reached at least Phase 1; claim the board now.
        board_assign_issue "${issue_num}" "${repo}"
        board_move_item "${item_id}" "${BOARD_OPT_IN_PROGRESS}"
        board_post_claim "${issue_num}" "${repo}"
        echo "  [board] #${issue_num} claimed (post-push) → In Progress, branch=${pushed_branch}"
    fi

    if [[ $exit_code -eq 0 ]] && grep -q "ISSUE_COMPLETE:#${issue_num}" "${task_log}" 2>/dev/null; then
        echo "  [done] #${issue_num} — full pipeline complete (implemented, reviewed, merged)"
        board_clear_fail_counter "${issue_num}" "${repo}"
        return 0
    fi

    # Check what stage we got to
    local pr_num
    pr_num=$(gh pr list --repo "${BOARD_PROJECT_OWNER}/${repo}" --state all \
        --search "closes #${issue_num}" --json number,state --jq '.[0] | "\(.number):\(.state)"' 2>/dev/null)
    local pr_number="${pr_num%%:*}"
    local pr_state="${pr_num##*:}"

    if [[ -n "$pr_number" ]] && [[ "$pr_number" != "null" ]]; then
        if [[ "$pr_state" == "MERGED" ]]; then
            echo "  [done] #${issue_num} — PR #${pr_number} merged (sentinel missed but merge confirmed)"
            board_clear_fail_counter "${issue_num}" "${repo}"
            return 0
        else
            # PR exists but not merged — try to merge it ourselves
            echo "  [partial] #${issue_num} — PR #${pr_number} exists (${pr_state}), attempting merge..."
            if gh pr merge "${pr_number}" --squash --repo "${BOARD_PROJECT_OWNER}/${repo}" 2>/dev/null; then
                echo "  [done] #${issue_num} — PR #${pr_number} merged by post-processing"
                sleep 10
                local board_col
                board_col=$(gh issue view "${issue_num}" -R "${BOARD_PROJECT_OWNER}/${repo}" \
                    --json projectItems --jq '.projectItems[0].status.name' 2>/dev/null)
                echo "  [board] #${issue_num} now in column: ${board_col}"
                board_clear_fail_counter "${issue_num}" "${repo}"
                return 0
            else
                echo "  [stuck] #${issue_num} — PR #${pr_number} merge failed. Left for manual review."
                board_handle_failure "${issue_num}" "${repo}" "${task_log}" \
                    "PR #${pr_number} could not be auto-merged"
                return 1
            fi
        fi
    fi

    # No PR. If we never even pushed a branch, leave NO trace on the issue —
    # this is the noise-reduction win from B5. Only count toward the failure
    # threshold (which only fires comment+label after 3 consecutive misses).
    if [[ -z "$pushed_branch" ]]; then
        echo "  [fail-silent] #${issue_num} — no branch pushed, no PR. No board action taken."
    else
        echo "  [fail] #${issue_num} — branch ${pushed_branch} pushed but no PR. Unassigning."
        board_unassign_issue "${issue_num}" "${repo}"
    fi
    board_handle_failure "${issue_num}" "${repo}" "${task_log}" "no PR created"
    return 1
}

# --------------------------------------------------------------------------
# Failure counter (B4, 2026-05-18)
# --------------------------------------------------------------------------
# Pre-2026-05-18 the worker posted a "did not complete" comment on every
# failed iteration. Issue #1051 collected 277 such comments. Replace that
# with a per-issue rolling counter file. We only post a GitHub comment +
# apply needs-human-triage on the 3rd consecutive miss. A success on any
# iteration clears the counter.
#
# Counter files live next to the worker logs: <logs>/<repo>-<issue>.fail-count
BOARD_FAIL_THRESHOLD="${BOARD_FAIL_THRESHOLD:-3}"

board_fail_counter_file() {
    local issue_num="$1" repo="$2"
    echo "${BOARD_LOGS_DIR}/${repo}-${issue_num}.fail-count"
}

board_clear_fail_counter() {
    local issue_num="$1" repo="$2"
    rm -f "$(board_fail_counter_file "${issue_num}" "${repo}")" 2>/dev/null || true
}

board_handle_failure() {
    local issue_num="$1" repo="$2" task_log="$3" reason="${4:-no PR created}"
    local f
    f=$(board_fail_counter_file "${issue_num}" "${repo}")
    local count=0
    [[ -f "$f" ]] && count=$(cat "$f" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "${count}" > "$f"
    if [[ "${count}" -ge "${BOARD_FAIL_THRESHOLD}" ]]; then
        echo "  [triage] #${issue_num} hit failure threshold (${count}) — labeling needs-human-triage"
        gh issue edit "${issue_num}" --repo "${BOARD_PROJECT_OWNER}/${repo}" \
            --add-label "needs-human-triage" >/dev/null 2>&1 || true
        board_comment_issue "${issue_num}" "${repo}" \
            "**board-worker** has failed this issue ${count} times (latest reason: ${reason}). Marking as needs-human-triage. Log: \`${task_log}\`"
        # Reset so post-triage attempts get another 3-strike window.
        board_clear_fail_counter "${issue_num}" "${repo}"
    else
        echo "  [fail-count] #${issue_num} miss ${count}/${BOARD_FAIL_THRESHOLD} (silent)"
    fi
}

# --------------------------------------------------------------------------
# Mode: RESCUE — unblock In Progress issues whose PR is CI-red
# --------------------------------------------------------------------------
# Author allowlist: only auto-fix PRs we own. Pushing commits to a human's
# branch silently is rude and risks colliding with their in-flight work.
# MUST be exported — the rescue mode passes this to a python subprocess via
# os.environ.get(). Without `export`, the python sees an empty string,
# split(',') returns [''], and every author check fails as "not in allowlist".
# (Bug found 2026-05-15: rescue processed 0 items in 8 min because every
# ${BOARD_OWNER:-your-github-handle} PR was rejected on a misread allowlist.)
export BOARD_RESCUE_AUTHOR_ALLOWLIST="${BOARD_RESCUE_AUTHOR_ALLOWLIST:-${BOARD_OWNER:-your-github-handle},your-github-handle,local-coder}"

run_rescue_mode() {
    local issue_num="$1" repo="$2" item_id="$3" title="$4"
    local workdir
    workdir=$(board_repo_workdir "$repo")

    # Find open PR closing this issue
    local pr_info
    pr_info=$(gh pr list -R "${BOARD_PROJECT_OWNER}/${repo}" -s open --limit 100 \
        --search "in:body closes #${issue_num} OR in:body fixes #${issue_num} OR in:body resolves #${issue_num}" \
        --json number,author,headRefName,statusCheckRollup 2>/dev/null | \
        python3 -c "
import json, sys, os
prs = json.load(sys.stdin)
if not prs: sys.exit(0)
pr = prs[0]
allow = os.environ.get('BOARD_RESCUE_AUTHOR_ALLOWLIST', '').split(',')
author = pr['author']['login']
author_ok = author in allow
fails = [c for c in (pr.get('statusCheckRollup') or []) if (c.get('conclusion') == 'FAILURE' or c.get('state') == 'FAILURE')]
print(json.dumps({'pr': pr['number'], 'author': author, 'author_ok': author_ok, 'branch': pr['headRefName'], 'fails': [f.get('name','?') for f in fails]}))
")

    if [[ -z "$pr_info" ]]; then
        echo "  [skip] #${issue_num} — no open PR closing this issue (reap mode handles these)"
        # Return 2 = "skipped without doing work". The main loop reads this
        # exit code to NOT count the iteration against MAX_TASKS, so the
        # worker doesn't burn its entire budget on no-op skips when the
        # column is dominated by items this mode can't address.
        return 2
    fi

    local pr_num pr_author author_ok pr_branch fail_names
    pr_num=$(echo "$pr_info"     | python3 -c "import sys,json; print(json.load(sys.stdin)['pr'])")
    pr_author=$(echo "$pr_info"  | python3 -c "import sys,json; print(json.load(sys.stdin)['author'])")
    author_ok=$(echo "$pr_info"  | python3 -c "import sys,json; print(json.load(sys.stdin)['author_ok'])")
    pr_branch=$(echo "$pr_info"  | python3 -c "import sys,json; print(json.load(sys.stdin)['branch'])")
    fail_names=$(echo "$pr_info" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)['fails']))")

    if [[ "$author_ok" != "True" ]]; then
        echo "  [skip] #${issue_num} — PR #${pr_num} authored by ${pr_author}, not in rescue allowlist"
        return 2
    fi

    if [[ -z "$fail_names" ]]; then
        echo "  [skip] #${issue_num} — PR #${pr_num} has no failing checks"
        return 2
    fi

    echo "  [rescue] #${issue_num} → PR #${pr_num} (branch=${pr_branch}) failing: ${fail_names}"

    # Now that we know there's a real PR to fix and we own it, claim the issue
    # so concurrent workers see it as taken.
    board_post_claim "${issue_num}" "${repo}"

    # Pull the first failing check's log for context
    local fail_log_excerpt
    fail_log_excerpt=$(gh pr checks "${pr_num}" -R "${BOARD_PROJECT_OWNER}/${repo}" --json name,link \
        --jq '.[] | select(.bucket == "fail") | .link' 2>/dev/null | head -1 | \
        awk -F/ '{print $(NF-2)}' | xargs -I{} gh run view {} -R "${BOARD_PROJECT_OWNER}/${repo}" --log-failed 2>/dev/null | \
        grep -iE "error|fail|traceback" | grep -v "UNKNOWN STEP" | head -30)

    local prompt
    prompt="RESCUE — PR #${pr_num} (closes #${issue_num}) is failing CI. Fix it.

Repo: ${repo} at ${workdir}
Branch: ${pr_branch}
Failing checks: ${fail_names}

## Failing check log excerpt
\`\`\`
${fail_log_excerpt:-<no log captured>}
\`\`\`

## Workflow
1. cd ${workdir}
2. git fetch origin && git checkout ${pr_branch} && git pull origin ${pr_branch}
3. Diagnose the failure from the log above. Most common patterns:
   - 'multiple heads' → \`git merge origin/dev\` then \`PYTHONPATH=. python -m alembic merge heads -m 'merge heads'\`
   - Test failure → read the assertion, fix root cause (code or test, whichever is wrong)
   - Lint/ruff → \`ruff check --fix .\` then \`ruff format .\`
   - pip-audit CVE → upgrade the package to the listed fixed version in pyproject.toml + uv.lock
4. Run \`bash scripts/run-all-ci.sh\` locally. Must exit 0 before pushing.
5. Commit:
   git add -A && git commit -m '[local-coder] fix: rescue CI for PR #${pr_num}

Co-Authored-By: Local Coder <local-coder@example.com>'
6. git push origin ${pr_branch}
7. Wait for CI: \`gh pr checks ${pr_num} -R ${BOARD_PROJECT_OWNER}/${repo} --watch\`
8. If CI passes, attempt squash merge: \`gh pr merge ${pr_num} --squash -R ${BOARD_PROJECT_OWNER}/${repo}\`
9. Output exactly: ISSUE_COMPLETE:#${issue_num}

If you cannot resolve the failure cleanly (e.g., unresolvable merge conflict, broken test that requires
product decision), post an issue comment summarizing the blocker and exit. Do NOT force-merge.
Do NOT use --no-verify.
Do NOT push to dev or prod directly."

    local task_label="rescue-${repo}-${issue_num}"
    board_run_claude "${workdir}" "${prompt}" "claude-opus-4-6" "P1" "${task_label}"
    local exit_code=$?

    local task_log="${BOARD_LOGS_DIR}/${task_label}.log"
    if [[ $exit_code -eq 0 ]] && grep -q "ISSUE_COMPLETE:#${issue_num}" "${task_log}" 2>/dev/null; then
        echo "  [done] #${issue_num} — PR #${pr_num} rescue complete"
        return 0
    else
        echo "  [partial] #${issue_num} — rescue did not reach ISSUE_COMPLETE. Log: ${task_log}"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Mode: REAP — return orphan In Progress items to Backlog
# --------------------------------------------------------------------------
# An "orphan" is an In Progress issue with:
#   - no open PR closing it
#   - no merged PR closing it
#   - no remote branch containing the issue number
#   - no human assignee outside the bot allowlist
# These accumulate when board automation flips the column on push but the
# branch is later deleted, the PR is closed unmerged, or the worker crashed
# before reaching gh pr create. Without reap they sit forever, inflating
# the "In Progress" count and hiding real WIP.
BOARD_REAP_HUMAN_ASSIGNEES="${BOARD_REAP_HUMAN_ASSIGNEES:-teammate1,teammate2}"

run_reap_mode() {
    local issue_num="$1" repo="$2" item_id="$3" title="$4"

    # 1. Human-assignee guardrail — never move issues out of a human's column
    local assignees
    assignees=$(gh issue view "$issue_num" -R "${BOARD_PROJECT_OWNER}/${repo}" \
        --json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null)
    if [[ -n "$assignees" ]]; then
        local human_match=""
        IFS=',' read -ra _humans <<< "$BOARD_REAP_HUMAN_ASSIGNEES"
        for h in "${_humans[@]}"; do
            [[ ",$assignees," == *",$h,"* ]] && human_match="$h" && break
        done
        if [[ -n "$human_match" ]]; then
            echo "  [skip] #${issue_num} — assigned to ${human_match} (human-owned)"
            return 2
        fi
    fi

    # 2. Open PR check — if there IS a PR, this isn't orphan work, it's rescue's job
    local has_open_pr
    has_open_pr=$(gh pr list -R "${BOARD_PROJECT_OWNER}/${repo}" -s open --limit 5 \
        --search "in:body closes #${issue_num} OR in:body fixes #${issue_num} OR in:body resolves #${issue_num}" \
        --json number --jq 'length' 2>/dev/null)
    if [[ "${has_open_pr:-0}" -gt 0 ]]; then
        echo "  [skip] #${issue_num} — has open PR (rescue mode handles)"
        return 2
    fi

    # 3. Merged PR check — board automation should have moved it; flag for manual fix
    local merged_pr
    merged_pr=$(gh pr list -R "${BOARD_PROJECT_OWNER}/${repo}" -s merged --limit 5 \
        --search "in:body closes #${issue_num} OR in:body fixes #${issue_num} OR in:body resolves #${issue_num}" \
        --json number,baseRefName --jq '[.[] | select(.baseRefName=="dev" or .baseRefName=="prod") | .number] | first // ""' 2>/dev/null)
    if [[ -n "$merged_pr" ]]; then
        echo "  [stuck] #${issue_num} — PR #${merged_pr} already merged but column not advanced"
        board_comment_issue "${issue_num}" "${repo}" \
            "🤖 **board-worker reap:** This issue is in 'In Progress' but PR #${merged_pr} is already merged. The column-automation Action did not fire — possibly because \`closes #${issue_num}\` was added to the PR body *after* merge. the operator should move this card manually."
        return 0
    fi

    # 4. Remote branch check — if a branch exists, the next worker may still PR; leave it
    local matching_branch
    matching_branch=$(git -C "$(board_repo_workdir "$repo")" branch -r 2>/dev/null \
        | sed 's|origin/||; s/^[[:space:]]*//' \
        | grep -E "(^|[^0-9])${issue_num}([^0-9]|$)" | head -1 || true)
    if [[ -n "$matching_branch" ]]; then
        echo "  [skip] #${issue_num} — remote branch '${matching_branch}' exists (worker may still create PR)"
        return 2
    fi

    # 5. Truly orphan — move back to Backlog with explanation
    echo "  [reap] #${issue_num} → moving to Backlog (no branch, no PR, no merged PR)"
    board_comment_issue "${issue_num}" "${repo}" \
        "🤖 **board-worker reap (${BOARD_WORKER_NAME}):** Moving this issue back to 'Backlog'.

Audit on $(date -u +%Y-%m-%d):
- No open PR closes this issue
- No merged PR closes this issue
- No remote branch with issue number \`${issue_num}\`
- No human assignee

The column was likely set by a worker that pushed a branch and later deleted it, or crashed before creating a PR. The issue is ready for re-pickup from Backlog."
    board_unassign_issue "${issue_num}" "${repo}"
    board_move_item "${item_id}" "${BOARD_OPT_BACKLOG}"
    return 0
}

# --------------------------------------------------------------------------
# Mode: VERIFY-STAGING — test issues in staging
# --------------------------------------------------------------------------
run_verify_staging_mode() {
    local issue_num="$1" repo="$2" item_id="$3" title="$4"
    local workdir
    workdir=$(board_repo_workdir "$repo")

    local staging_backend="${STAGING_BACKEND_URL:-https://your-backend-staging.example.com}"
    local staging_frontend="${STAGING_FRONTEND_URL:-https://your-frontend-staging.example.com}"
    local staging_token
    staging_token=$(cat ~/.claude/secrets/staging-auth-bypass-token.txt 2>/dev/null || echo "")

    local prompt
    prompt="STAGING VERIFICATION — Verify Issue #${issue_num} (${repo}): ${title}

CRITICAL: Do NOT promote any issue to 'prod release ready'. That is the operator's decision only.

STEP 1 — Read issue and linked PRs:
  gh issue view ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} --json body,title,comments

STEP 2 — Verify staging is healthy:
  curl -s -o /dev/null -w '%{http_code}' ${staging_backend}/health
  curl -s -o /dev/null -w '%{http_code}' ${staging_frontend}

STEP 3 — Verify the specific feature from the issue:
  Read the acceptance criteria from the issue body.
  For each criterion, construct a curl command or describe what you'd check.

  For backend API features, use the staging auth bypass:
    curl -s -H 'Authorization: Bearer staging-bypass:${staging_token}' \\
      '${staging_backend}/<endpoint>' | python3 -m json.tool | head -20

  For frontend features, describe what pages to check and what to look for.

STEP 4 — Post verification comment:
  gh issue comment ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} --body '## Staging Verification
**Issue:** #${issue_num} — ${title}
**Verified by:** board-worker verify-staging ($(date +%Y-%m-%d))
**Staging backend:** ${staging_backend}
**Staging frontend:** ${staging_frontend}

### Checks
- [ ] Staging health: <status>
- [ ] Feature-specific: <what was checked and result>

### Result: PASS / FAIL
<explanation>
'

STEP 5 — If FAIL: add label 'staging-fail':
  gh issue edit ${issue_num} -R ${BOARD_PROJECT_OWNER}/${repo} --add-label staging-fail

Output exactly: ISSUE_COMPLETE:#${issue_num}"

    local task_label="verify-${repo}-${issue_num}"
    board_run_claude "${workdir}" "${prompt}" "claude-opus-4-6" "P2" "${task_label}"
    local exit_code=$?

    local task_log="${BOARD_LOGS_DIR}/${task_label}.log"
    if [[ $exit_code -eq 0 ]] && grep -q "ISSUE_COMPLETE:#${issue_num}" "${task_log}" 2>/dev/null; then
        echo "  [verified] #${issue_num} staging check complete"
        return 0
    else
        echo "  [fail] #${issue_num} verification incomplete"
        return 1
    fi
}

# --------------------------------------------------------------------------
# Main loop
# --------------------------------------------------------------------------
while [[ $PROCESSED -lt $MAX_TASKS ]]; do
    # Determine column to query
    local_status=""
    case "$MODE" in
        ideas)          local_status="Ideas" ;;
        backlog)        local_status="Backlog" ;;
        verify-staging) local_status="ui testing in staging" ;;
        rescue)         local_status="In Progress" ;;
        reap)           local_status="In Progress" ;;
        *)
            echo "ERROR: Unknown mode '$MODE'" >&2
            exit 1
            ;;
    esac

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Querying board: ${local_status} (target: ${TARGET_FILTER})..."

    # Get next unprocessed item
    NEXT_ITEM=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local_num=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['issue_num'])")
        local_assigned=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['assigned'])")

        # Skip completed (persisted across sessions — real work was done)
        if board_is_completed "${local_num}" "${COMPLETED_FILE}"; then
            continue
        fi

        # Skip session-only (rescue/reap skipped this item earlier this run
        # because state didn't match. State may change between sessions, so
        # this is intentionally not persisted.)
        if grep -q "^${local_num}\$" "${SKIPPED_FILE}" 2>/dev/null; then
            continue
        fi

        # For backlog mode, skip already-assigned issues (someone else claimed them)
        if [[ "$MODE" == "backlog" ]] && [[ "$local_assigned" == "True" ]]; then
            continue
        fi

        # Inter-worker claim check: skip items recently claimed by another
        # worker (within BOARD_CLAIM_WINDOW_MIN). This is the cross-process
        # dedup that the per-worker .board-completed.txt files don't provide.
        local_repo=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin)['repo'])")
        claim_holder=$(board_get_active_lock_holder "${local_num}" "${local_repo}")
        if [[ -n "${claim_holder}" ]]; then
            echo "  [claim] #${local_num} already claimed by ${claim_holder} — skipping"
            continue
        fi

        NEXT_ITEM="$line"
        break
    done < <(board_query_items "${local_status}" "${TARGET_FILTER}")

    if [[ -z "$NEXT_ITEM" ]]; then
        echo "  No more items in '${local_status}'. Done."
        break
    fi

    # Extract fields
    ISSUE_NUM=$(echo "$NEXT_ITEM" | python3 -c "import sys,json; print(json.load(sys.stdin)['issue_num'])")
    REPO=$(echo "$NEXT_ITEM" | python3 -c "import sys,json; print(json.load(sys.stdin)['repo'])")
    TITLE=$(echo "$NEXT_ITEM" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['title'])")
    ITEM_ID=$(echo "$NEXT_ITEM" | python3 -c "import sys,json; print(json.load(sys.stdin)['item_id'])")
    PRIORITY=$(echo "$NEXT_ITEM" | python3 -c "import sys,json; print(json.load(sys.stdin)['priority'])")

    echo ""
    echo "  [${PRIORITY}] #${ISSUE_NUM} (${REPO}): ${TITLE}"

    # Claim ordering:
    #   ideas / verify-staging   — claim pre-work (every queued item is workable
    #                              and read-only enough that a no-trace failure
    #                              is acceptable)
    #   backlog                  — DO NOT pre-claim (B5, 2026-05-18). Defer
    #                              claim until after Claude has pushed a branch
    #                              so failed attempts leave no trace on the board.
    #   rescue / reap            — claim inside the mode fn after eligibility
    #                              check, to avoid spamming locks on filter-misses.
    case "$MODE" in
        ideas|verify-staging)
            board_post_claim "${ISSUE_NUM}" "${REPO}"
            ;;
    esac

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would process with mode=${MODE}"
        echo ""
        PROCESSED=$((PROCESSED + 1))
        board_mark_completed "${ISSUE_NUM}" "${COMPLETED_FILE}"
        continue
    fi

    # Resource gates
    board_wait_for_cpu
    board_wait_for_memory

    # Playwright lock — only for tasks that actually run a browser.
    # Frontend backlog tasks run npm test / vitest / playwright; verify-staging
    # is curl-and-comment by design (per run_verify_staging_mode prompt) and
    # does not need the lock. Locking verify-staging caps parallelism at 1 for
    # no benefit; unlocking it ~triples staging-verify throughput (2026-05-14).
    HOLDS_LOCK="false"
    if [[ "$REPO" == "frontend" ]] && [[ "$MODE" == "backlog" ]]; then
        board_acquire_playwright_lock
        HOLDS_LOCK="true"
    fi

    # Dispatch.
    # Exit codes:
    #   0 = success (counts against MAX_TASKS)
    #   1 = failure (counts against MAX_TASKS, also increments FAILED)
    #   2 = skipped without doing work (does NOT count against MAX_TASKS)
    #       Used by rescue/reap when an item doesn't match their criteria —
    #       prevents the worker from burning its budget on filter-misses when
    #       most items in the column belong to a different mode.
    TASK_EXIT=0
    case "$MODE" in
        ideas)          run_ideas_mode "$ISSUE_NUM" "$REPO" "$ITEM_ID" "$TITLE" || TASK_EXIT=$? ;;
        backlog)        run_backlog_mode "$ISSUE_NUM" "$REPO" "$ITEM_ID" "$TITLE" "$PRIORITY" || TASK_EXIT=$? ;;
        verify-staging) run_verify_staging_mode "$ISSUE_NUM" "$REPO" "$ITEM_ID" "$TITLE" || TASK_EXIT=$? ;;
        rescue)         run_rescue_mode "$ISSUE_NUM" "$REPO" "$ITEM_ID" "$TITLE" || TASK_EXIT=$? ;;
        reap)           run_reap_mode   "$ISSUE_NUM" "$REPO" "$ITEM_ID" "$TITLE" || TASK_EXIT=$? ;;
    esac

    # Release Playwright lock
    if [[ "$HOLDS_LOCK" == "true" ]]; then
        board_release_playwright_lock
        sleep 5
    fi

    # Post-task vitest cleanup — only relevant when we actually ran tests,
    # which only happens for backlog mode on frontend.
    if [[ "$REPO" == "frontend" ]] && [[ "$MODE" == "backlog" ]]; then
        pkill -f vitest 2>/dev/null || true
    fi

    if [[ $TASK_EXIT -eq 2 ]]; then
        # Skipped without work — session-only dedup, not persisted across runs.
        # Doesn't count against MAX_TASKS budget either.
        echo "${ISSUE_NUM}" >> "${SKIPPED_FILE}"
    elif [[ $TASK_EXIT -eq 0 ]]; then
        # Real work succeeded — persist so subsequent sessions don't re-do it.
        board_mark_completed "${ISSUE_NUM}" "${COMPLETED_FILE}"
        PROCESSED=$((PROCESSED + 1))
    else
        # Real work failed — persist (don't retry in this session) and count.
        board_mark_completed "${ISSUE_NUM}" "${COMPLETED_FILE}"
        PROCESSED=$((PROCESSED + 1))
        FAILED=$((FAILED + 1))
        FAILED_ISSUES+=("#${ISSUE_NUM}")
    fi

    echo ""
    sleep 5
done

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
END_EPOCH=$(date +%s)
TOTAL_ELAPSED=$(( (END_EPOCH - START_EPOCH) / 60 ))

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Board Worker Complete                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Finished:  $(date)"
echo "  Duration:  ${TOTAL_ELAPSED}min"
echo "  Tasks:     ${PROCESSED} processed  |  ${FAILED} failed"
echo "  Logs:      ${BOARD_LOGS_DIR}/"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "  Failed issues: ${FAILED_ISSUES[*]}"
    echo ""
    exit 1
fi
