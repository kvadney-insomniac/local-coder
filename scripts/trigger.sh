#!/usr/bin/env bash
# trigger.sh — kick off a Local Coder job on demand
#
# Usage:
#   ./trigger.sh "task description"  [OPTIONS]
#   ./trigger.sh --task <task-id>    [OPTIONS]   (use a predefined task from task-catalog.yaml)
#   ./trigger.sh --list-tasks                    (show available task IDs)
#
# Options:
#   --task <id>          Load prompt + model from task-catalog.yaml
#   --branch <branch>    Base branch (default: dev)
#   --repo <name|url>    Repo shortname or full GitHub URL (default: backend)
#                        Shortnames: backend, frontend, devops
#   --feature <branch>   Feature branch name (default: local-coder/TIMESTAMP)
#   --issue <number>     GitHub issue number to comment on when done
#   --model <model>      Override model (default from catalog or claude-opus-4-6)
#   --max-turns <n>      Override max turns (default from catalog or 50)
#   --install-deps       Install repo deps before running (slower)
#   --dry-run            Run Claude but skip commit/push/PR
#   --timeout <seconds>  Hard wall-clock timeout for the Claude invocation (default: catalog value or none)
#   --no-wait            Don't wait for job completion (fire and forget)
#   --list-tasks         List available task IDs from catalog
#   --help               Show this help
#
# Examples:
#   ./trigger.sh "Fix all failing EVS tests"
#   ./trigger.sh "Add docstrings to portfolio service" --repo backend
#   ./trigger.sh --task lint-sweep --repo backend
#   ./trigger.sh --task deps-audit --repo frontend
#   ./trigger.sh "Implement issue #42" --repo backend --issue 42 --feature feat/issue-42
#   ./trigger.sh --task bug-fixes --dry-run
#   ./trigger.sh --task perf-audit --timeout 3600

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG="${SCRIPT_DIR}/task-catalog.yaml"

PROJECT_ID="${CLOUD_CODER_PROJECT:-${GCP_PROJECT_ID:-your-gcp-project}}"
REGION="${CLOUD_CODER_REGION:-us-central1}"
JOB_NAME="claude-coder"

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
TASK_PROMPT=""
TASK_TYPE="custom"
BRANCH="dev"
REPO="backend"
FEATURE_BRANCH=""
ISSUE_NUMBER=""
MODEL="claude-opus-4-6"
MAX_TURNS="50"
TASK_TIMEOUT_SECONDS=""
INSTALL_DEPS="false"
DRY_RUN="false"
WAIT="--wait"

# --------------------------------------------------------------------------
# Catalog helpers (require python3 + PyYAML)
# --------------------------------------------------------------------------
catalog_get() {
    local task_id="$1"
    local field="$2"
    python3 -c "
import yaml, sys
catalog = yaml.safe_load(open('${CATALOG}'))
task = next((t for t in catalog['tasks'] if t['id'] == '${task_id}'), None)
if not task:
    print('', end='')
    sys.exit(0)
val = task.get('${field}', catalog.get('defaults', {}).get('${field}', ''))
print(val, end='')
" 2>/dev/null || true
}

list_tasks() {
    python3 -c "
import yaml
catalog = yaml.safe_load(open('${CATALOG}'))
print('Available task IDs:')
print('')
for t in catalog['tasks']:
    model = t.get('model', 'claude-opus-4-6')
    print(f\"  {t['id']:<20} [{model}]  {t['name']}\")
    print(f\"                       {t['description'][:80]}\")
    print()
" 2>/dev/null || echo "(could not read catalog — install PyYAML: pip install pyyaml)"
}

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
if [ $# -eq 0 ]; then
    echo "Usage: $0 \"<task prompt>\" [OPTIONS]  or  $0 --task <id> [OPTIONS]"
    echo "Run $0 --help for full usage, or $0 --list-tasks for task IDs."
    exit 1
fi

# First positional arg is the task prompt (unless it starts with --)
if [[ "$1" != --* ]]; then
    TASK_PROMPT="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)         TASK_TYPE="$2";              shift 2 ;;
        --branch)       BRANCH="$2";                shift 2 ;;
        --repo)         REPO="$2";                  shift 2 ;;
        --feature)      FEATURE_BRANCH="$2";        shift 2 ;;
        --issue)        ISSUE_NUMBER="$2";           shift 2 ;;
        --model)        MODEL="$2";                  shift 2 ;;
        --max-turns)    MAX_TURNS="$2";              shift 2 ;;
        --timeout)      TASK_TIMEOUT_SECONDS="$2";  shift 2 ;;
        --install-deps) INSTALL_DEPS="true";         shift ;;
        --dry-run)      DRY_RUN="true";              shift ;;
        --no-wait)      WAIT="";                     shift ;;
        --list-tasks)   list_tasks;             exit 0 ;;
        --help|-h)
            sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --------------------------------------------------------------------------
# Load from task catalog if --task was specified
# --------------------------------------------------------------------------
if [ "$TASK_TYPE" != "custom" ]; then
    CATALOG_PROMPT=$(catalog_get "$TASK_TYPE" "prompt")
    CATALOG_MODEL=$(catalog_get "$TASK_TYPE" "model")
    CATALOG_TURNS=$(catalog_get "$TASK_TYPE" "max_turns")
    CATALOG_REPO=$(catalog_get "$TASK_TYPE" "repo")
    CATALOG_TIMEOUT=$(catalog_get "$TASK_TYPE" "timeout_seconds")

    if [ -z "$CATALOG_PROMPT" ]; then
        echo "ERROR: Unknown task ID '$TASK_TYPE'. Run $0 --list-tasks to see options."
        exit 1
    fi

    # Use catalog values unless overridden by flags
    [ -z "$TASK_PROMPT"              ] && TASK_PROMPT="$CATALOG_PROMPT"
    [ -n "$CATALOG_MODEL"            ] && MODEL="$CATALOG_MODEL"
    [ -n "$CATALOG_TURNS"            ] && MAX_TURNS="$CATALOG_TURNS"
    # --timeout flag takes priority over catalog; catalog fills in if not set
    [ -z "$TASK_TIMEOUT_SECONDS" ] && [ -n "$CATALOG_TIMEOUT" ] && TASK_TIMEOUT_SECONDS="$CATALOG_TIMEOUT"
    # Only use catalog repo default if user didn't specify one
    [ "$REPO" = "backend" ] && [ -n "$CATALOG_REPO" ] && REPO="$CATALOG_REPO"
fi

if [ -z "$TASK_PROMPT" ]; then
    echo "ERROR: No task prompt. Provide a description or use --task <id>."
    exit 1
fi

# --------------------------------------------------------------------------
# Resolve repo shortname → GitHub URL
# --------------------------------------------------------------------------
case "$REPO" in
    backend)  REPO_URL="https://github.com/YourProject-Hedge-Fund-Guy/backend" ;;
    frontend) REPO_URL="https://github.com/YourProject-Hedge-Fund-Guy/frontend" ;;
    devops)   REPO_URL="https://github.com/YourProject-Hedge-Fund-Guy/devops" ;;
    https://*) REPO_URL="$REPO" ;;
    *)
        echo "ERROR: Unknown repo '$REPO'. Use: backend, frontend, devops, or a full HTTPS URL."
        exit 1
        ;;
esac

# --------------------------------------------------------------------------
# Build env-var overrides via a YAML flags file
# (--update-env-vars breaks on special chars like [ ] ` in prompt text)
# --------------------------------------------------------------------------
# Strip newlines from TASK_PROMPT — Cloud Run env vars must be single-line.
TASK_PROMPT_CLEAN=$(echo "$TASK_PROMPT" | tr '\n' ' ' | sed 's/  */ /g')

# Export into _CC_* namespace so Python reads them safely from os.environ
export _CC_TASK_PROMPT="$TASK_PROMPT_CLEAN"
export _CC_TASK_TYPE="$TASK_TYPE"
export _CC_REPO_URL="$REPO_URL"
export _CC_BRANCH="$BRANCH"
export _CC_MODEL="$MODEL"
export _CC_MAX_TURNS="$MAX_TURNS"
export _CC_INSTALL_DEPS="$INSTALL_DEPS"
export _CC_DRY_RUN="$DRY_RUN"
[ -n "${FEATURE_BRANCH:-}"       ] && export _CC_FEATURE_BRANCH="$FEATURE_BRANCH"
[ -n "${ISSUE_NUMBER:-}"         ] && export _CC_ISSUE_NUMBER="$ISSUE_NUMBER"
[ -n "${TASK_TIMEOUT_SECONDS:-}" ] && export _CC_TASK_TIMEOUT_SECONDS="$TASK_TIMEOUT_SECONDS"

_TMPFLAGS=$(mktemp /tmp/local-coder-flags-XXXXXX)
mv "$_TMPFLAGS" "${_TMPFLAGS}.yaml"
_TMPFLAGS="${_TMPFLAGS}.yaml"
# shellcheck disable=SC2064
trap "rm -f $_TMPFLAGS" EXIT

python3 - <<'PYEOF' > "$_TMPFLAGS"
import yaml, os
env_vars = {k[4:]: v for k, v in os.environ.items() if k.startswith('_CC_')}
# gcloud --flags-file requires keys with the -- prefix
print(yaml.dump({'--update-env-vars': env_vars}, default_flow_style=False, allow_unicode=True))
PYEOF

# --------------------------------------------------------------------------
# Print summary
# --------------------------------------------------------------------------
echo ""
echo "=== Local Coder Trigger ==="
echo "Job:     $JOB_NAME @ $PROJECT_ID/$REGION"
echo "Repo:    $REPO_URL"
echo "Branch:  $BRANCH"
echo "Model:   $MODEL  (max_turns=$MAX_TURNS)"
echo "Task:    [$TASK_TYPE] $TASK_PROMPT_CLEAN" | head -c 200
echo ""
[ -n "${FEATURE_BRANCH:-}"       ] && echo "Feature: $FEATURE_BRANCH"
[ -n "${ISSUE_NUMBER:-}"         ] && echo "Issue:   #$ISSUE_NUMBER"
[ -n "${TASK_TIMEOUT_SECONDS:-}" ] && echo "Timeout: ${TASK_TIMEOUT_SECONDS}s"
[ "$DRY_RUN" = "true"            ] && echo "Mode:    DRY RUN (no commit/push/PR)"
[ -z "$WAIT"                     ] && echo "Mode:    fire-and-forget (no --wait)"
echo "==========================="
echo ""

# --------------------------------------------------------------------------
# Execute
# --------------------------------------------------------------------------
gcloud run jobs execute "$JOB_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --flags-file="$_TMPFLAGS" \
    $WAIT

echo "Done."
