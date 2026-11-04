#!/usr/bin/env bash
# Cloud Run Claude Coder — entrypoint
#
# Required env vars:
#   GITHUB_TOKEN       GitHub PAT (repo + workflow + read:org scopes)
#   ANTHROPIC_API_KEY  Anthropic API key for Claude Code
#   REPO_URL           Full HTTPS GitHub URL (e.g. https://github.com/Org/backend)
#   BRANCH             Base branch (e.g. dev)
#   TASK_PROMPT        Natural-language task description
#
# Optional env vars:
#   TASK_TYPE              ID from task-catalog.yaml (for model/turn selection)
#   MODEL                  Claude model override (default: LOCAL_CODER_DEFAULT_MODEL or claude-opus-5-5)
#   MAX_TURNS              Max agentic turns (default: 50)
#   TASK_TIMEOUT_SECONDS   Hard wall-clock timeout for the claude invocation (default: 0 = none)
#   FEATURE_BRANCH         Branch name to create (default: local-coder/YYYYMMDD-HHMMSS)
#   ISSUE_NUMBER           GitHub issue to comment on when done
#   INSTALL_DEPS           "true" to pip/npm install repo deps first (slower)
#   DRY_RUN                "true" to run Claude but skip commit/push/PR
#   GCS_LOG_BUCKET         GCS bucket for run logs (default: ${GCS_LOG_BUCKET:-your-log-bucket})

set -euo pipefail

# --------------------------------------------------------------------------
# Validate required env vars
# --------------------------------------------------------------------------
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
: "${REPO_URL:?REPO_URL is required}"
: "${BRANCH:?BRANCH is required}"
: "${TASK_PROMPT:?TASK_PROMPT is required}"

TASK_TYPE="${TASK_TYPE:-custom}"
MODEL="${MODEL:-${LOCAL_CODER_DEFAULT_MODEL:-claude-opus-5-5}}"
MAX_TURNS="${MAX_TURNS:-50}"
TASK_TIMEOUT_SECONDS="${TASK_TIMEOUT_SECONDS:-0}"
FEATURE_BRANCH="${FEATURE_BRANCH:-}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
INSTALL_DEPS="${INSTALL_DEPS:-false}"
DRY_RUN="${DRY_RUN:-false}"
GCS_LOG_BUCKET="${GCS_LOG_BUCKET:-${GCS_LOG_BUCKET:-your-log-bucket}}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID="run-${TIMESTAMP}"
WORK_BRANCH="${FEATURE_BRANCH:-local-coder/${TIMESTAMP}}"
ORG_REPO=$(echo "$REPO_URL" | sed 's|.*github.com/||' | sed 's|\.git$||')
PR_URL=""
FILES_CHANGED=0
COST_ESTIMATE="N/A"
RUN_STATUS="unknown"

# --------------------------------------------------------------------------
# GCS log helper
# --------------------------------------------------------------------------
upload_logs() {
    if [ -z "$GCS_LOG_BUCKET" ]; then return; fi
    local status="$1"
    local pr_url="${2:-}"
    local end_time
    end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local start_epoch end_epoch duration
    start_epoch=$(date -d "$START_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null || echo 0)
    end_epoch=$(date +%s)
    duration=$((end_epoch - start_epoch))

    # Extract cost estimate from Claude output
    COST_ESTIMATE=$(grep -oE '\$[0-9]+\.[0-9]+' /tmp/claude-output.log 2>/dev/null | tail -1 \
        || grep -iE 'cost:?\s*\$?[0-9]+\.[0-9]+' /tmp/claude-output.log 2>/dev/null | tail -1 \
        || echo "N/A")

    local summary
    summary=$(python3 -c "
import json
print(json.dumps({
    'run_id': '${RUN_ID}',
    'task_type': '${TASK_TYPE}',
    'task_prompt': '''${TASK_PROMPT}''',
    'model': '${MODEL}',
    'repo': '${ORG_REPO}',
    'branch': '${BRANCH}',
    'work_branch': '${WORK_BRANCH}',
    'status': '${status}',
    'start_time': '${START_TIME}',
    'end_time': '${end_time}',
    'duration_seconds': ${duration},
    'pr_url': '${pr_url}',
    'cost_estimate': '${COST_ESTIMATE}',
    'files_changed': ${FILES_CHANGED},
    'dry_run': ${DRY_RUN},
}))
" 2>/dev/null || echo '{"status":"log-error"}')

    echo "$summary" | gcs_upload - \
        "gs://${GCS_LOG_BUCKET}/runs/${RUN_ID}/summary.json" \
        "application/json" 2>/dev/null || true

    gcs_upload /tmp/claude-output.log \
        "gs://${GCS_LOG_BUCKET}/runs/${RUN_ID}/claude-output.log" \
        "text/plain" 2>/dev/null || true
}

# Trap to always upload logs on exit (even on error)
trap 'upload_logs "$RUN_STATUS" "$PR_URL"' EXIT

# --------------------------------------------------------------------------
# Configure git identity — all commits attributed to Local Coder
# --------------------------------------------------------------------------
export GIT_AUTHOR_NAME="Local Coder"
export GIT_AUTHOR_EMAIL="local-coder@example.com"
export GIT_COMMITTER_NAME="Local Coder"
export GIT_COMMITTER_EMAIL="local-coder@example.com"

git config --global user.email "local-coder@example.com"
git config --global user.name "Local Coder"
git config --global init.defaultBranch main

# Authenticate gh CLI.
# When GITHUB_TOKEN is injected as an env var (e.g. from GCP Secret Manager),
# `gh auth login --with-token` exits non-zero because gh detects the env var
# and refuses to store a duplicate credential. Since GITHUB_TOKEN in env is
# sufficient for all gh operations, we skip the login and only run setup-git.
#
# NOTE: Newer gh CLI versions (2.45+) may exit non-zero when GITHUB_TOKEN is
# set in env because the credential helper is already configured via the env
# var. We use || true to handle this gracefully — GITHUB_TOKEN in env is
# sufficient for all git and gh operations regardless.
gh auth setup-git 2>&1 || true

echo "=== Startup diagnostics ==="
echo "gh version: $(gh --version 2>&1 | head -1)"
echo "git version: $(git --version 2>&1)"
echo "claude version: $(claude --version 2>&1 || echo 'check failed')"
echo "REPO_URL: $REPO_URL"
echo "BRANCH: $BRANCH"
echo "MODEL: $MODEL"
echo "==========================="

# --------------------------------------------------------------------------
# Ensure local-coder label exists in the target repo
# --------------------------------------------------------------------------
gh label create "local-coder" \
    --repo "$ORG_REPO" \
    --color "0075ca" \
    --description "Automated PR from Local Coder (Claude on Cloud Run)" \
    2>/dev/null || true  # idempotent — ignore if already exists

# --------------------------------------------------------------------------
# Clone repo
# --------------------------------------------------------------------------
echo "=== Cloud Run Claude Coder ==="
echo "Run ID:  $RUN_ID"
echo "Repo:    $ORG_REPO"
echo "Base:    $BRANCH → $WORK_BRANCH"
echo "Task:    [$TASK_TYPE] $TASK_PROMPT"
echo "Model:   $MODEL  (max_turns=$MAX_TURNS, timeout=${TASK_TIMEOUT_SECONDS:-none}s)"
echo "DryRun:  $DRY_RUN"
echo "=============================="

AUTH_URL=$(echo "$REPO_URL" | sed "s|https://|https://x-access-token:${GITHUB_TOKEN}@|")
git clone --depth=1 "$AUTH_URL" /workspace/repo
cd /workspace/repo

# --------------------------------------------------------------------------
# Check out base branch, create feature branch
# --------------------------------------------------------------------------
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull origin "$BRANCH"
git checkout -b "$WORK_BRANCH"
echo "On branch: $WORK_BRANCH"

# --------------------------------------------------------------------------
# Optional: install deps
# --------------------------------------------------------------------------
if [ "$INSTALL_DEPS" = "true" ]; then
    echo "Installing dependencies..."
    if [ -f "requirements.txt" ]; then
        pip install --no-cache-dir -r requirements.txt -q
    fi
    if [ -f "package.json" ]; then
        npm ci --silent
    fi
fi

# --------------------------------------------------------------------------
# Run Claude Code
# --------------------------------------------------------------------------
touch /tmp/claude-output.log

echo "Starting Claude Code ($MODEL, max_turns=$MAX_TURNS${TASK_TIMEOUT_SECONDS:+, timeout=${TASK_TIMEOUT_SECONDS}s})..."
set +e
if [ "${TASK_TIMEOUT_SECONDS:-0}" -gt 0 ]; then
    timeout "$TASK_TIMEOUT_SECONDS" \
        claude \
            --model "$MODEL" \
            --dangerously-skip-permissions \
            --max-turns "$MAX_TURNS" \
            -p "$TASK_PROMPT" \
        2>&1 | tee /tmp/claude-output.log
    CLAUDE_EXIT=${PIPESTATUS[0]}
    if [ "$CLAUDE_EXIT" -eq 124 ]; then
        echo "ERROR: Claude Code timed out after ${TASK_TIMEOUT_SECONDS}s"
    fi
else
    claude \
        --model "$MODEL" \
        --dangerously-skip-permissions \
        --max-turns "$MAX_TURNS" \
        -p "$TASK_PROMPT" \
        2>&1 | tee /tmp/claude-output.log
    CLAUDE_EXIT=${PIPESTATUS[0]}
fi
set -e

if [ "$CLAUDE_EXIT" -ne 0 ]; then
    echo "ERROR: Claude Code exited with status $CLAUDE_EXIT"
    RUN_STATUS="error"
    if [ -n "$ISSUE_NUMBER" ]; then
        gh issue comment "$ISSUE_NUMBER" --repo "$ORG_REPO" --body \
"### [local-coder] Task Failed — $RUN_ID

**Task:** \`$TASK_TYPE\` — $TASK_PROMPT
**Model:** $MODEL | **Branch:** \`$WORK_BRANCH\`
**Error:** Claude Code exited with status \`$CLAUDE_EXIT\`

Check Cloud Run logs for details: \`gcloud run jobs executions list --job=claude-coder --project=${GCP_PROJECT_ID:-your-gcp-project} --region=us-central1\`" 2>/dev/null || true
    fi
    exit "$CLAUDE_EXIT"
fi

# --------------------------------------------------------------------------
# DRY_RUN: show diff and exit without committing
# --------------------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo "=== DRY RUN — changes Claude would commit ==="
    git status --short || true
    echo ""
    git diff HEAD || true
    RUN_STATUS="dry-run"
    exit 0
fi

# --------------------------------------------------------------------------
# Check for file changes (tracked modifications + new untracked files)
# git diff --name-only HEAD misses new untracked files; git status --porcelain
# catches everything: modifications (M), additions (A), and untracked (??)
# --------------------------------------------------------------------------
FILES_CHANGED=$(git status --porcelain | wc -l | tr -d ' ')

if [ "$FILES_CHANGED" -eq 0 ]; then
    echo "No file changes — nothing to commit."
    RUN_STATUS="no-changes"
    if [ -n "$ISSUE_NUMBER" ]; then
        gh issue comment "$ISSUE_NUMBER" --repo "$ORG_REPO" --body \
"### [local-coder] No Changes — $RUN_ID

**Task:** \`$TASK_TYPE\` — $TASK_PROMPT
**Model:** $MODEL

Claude completed the task but made no file changes." 2>/dev/null || true
    fi
    exit 0
fi

# --------------------------------------------------------------------------
# Commit with [local-coder] prefix and required trailers
# --------------------------------------------------------------------------
git add -A

SUBJECT=$(echo "$TASK_PROMPT" | head -c 68 | tr '\n' ' ')
git commit -m "[local-coder] ${SUBJECT}

Task-Type: ${TASK_TYPE}
Model: ${MODEL}
Run-Id: ${RUN_ID}

Co-Authored-By: Local Coder <local-coder@example.com>
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

# --------------------------------------------------------------------------
# Push feature branch
# --------------------------------------------------------------------------
git push origin "$WORK_BRANCH"
echo "Pushed: $WORK_BRANCH ($FILES_CHANGED files changed)"

# --------------------------------------------------------------------------
# Git tag — local-coder/YYYY-MM-DD-HHMMSS
# --------------------------------------------------------------------------
TAG="local-coder/$(date +%Y-%m-%d-%H%M%S)"
git tag "$TAG" -m "[local-coder] $TASK_TYPE run $RUN_ID"
git push origin "$TAG"
echo "Tagged: $TAG"

# --------------------------------------------------------------------------
# Create PR with local-coder label
# --------------------------------------------------------------------------
PR_TITLE="[local-coder] $(echo "$TASK_PROMPT" | head -c 60)"

CLAUDE_TAIL=$(tail -80 /tmp/claude-output.log \
    | sed 's/`/\\`/g; s/\$/\\$/g' \
    || echo "(no output captured)")

PR_URL=$(gh pr create \
    --repo "$ORG_REPO" \
    --title "$PR_TITLE" \
    --base "$BRANCH" \
    --head "$WORK_BRANCH" \
    --label "local-coder" \
    --body "## Task

**Type:** \`$TASK_TYPE\`
**Model:** \`$MODEL\` | **Max turns:** $MAX_TURNS | **Run ID:** \`$RUN_ID\`

$TASK_PROMPT

## Changes

- **Files changed:** $FILES_CHANGED
- **Branch:** \`$WORK_BRANCH\` → \`$BRANCH\`
- **Tag:** \`$TAG\`
- **Cost estimate:** $COST_ESTIMATE

## Claude Output

<details>
<summary>Expand run log (last 80 lines)</summary>

\`\`\`
$CLAUDE_TAIL
\`\`\`

</details>

---
> 🤖 Autonomously generated by [Local Coder](https://github.com/YourProject-Hedge-Fund-Guy/devops/tree/main/local-coder) on GCP Cloud Run
> Timestamp: $TIMESTAMP | GCS logs: \`gs://${GCS_LOG_BUCKET}/runs/${RUN_ID}/\`")

echo "PR created: $PR_URL"
RUN_STATUS="success"

# --------------------------------------------------------------------------
# Comment on linked GitHub issue (if provided)
# --------------------------------------------------------------------------
if [ -n "$ISSUE_NUMBER" ]; then
    gh issue comment "$ISSUE_NUMBER" --repo "$ORG_REPO" --body \
"### [local-coder] Task Complete — $RUN_ID

**PR:** $PR_URL
**Task:** \`$TASK_TYPE\` — $TASK_PROMPT
**Files changed:** $FILES_CHANGED | **Cost:** $COST_ESTIMATE | **Model:** $MODEL" 2>/dev/null || true
fi

echo "=== Local Coder done ($RUN_STATUS) ==="
