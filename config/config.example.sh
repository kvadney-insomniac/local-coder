# local-coder configuration — copy to config.sh and edit, then `source config/config.sh`
# before running any of the launcher scripts.

# ---- Required ---------------------------------------------------------------

# Absolute path to the git repo the agent will work on. The runner cd's here
# before every task. Multiple repos = multiple worker lanes (see launch-*.sh).
export REPO_ROOT="${REPO_ROOT:-$HOME/code/your-repo}"

# GitHub handle the board worker treats as "yours". PRs from this handle are
# eligible for auto-merge; rescue mode skips PRs from this handle.
export BOARD_OWNER="${BOARD_OWNER:-your-github-handle}"

# Comma-separated handles whose PRs the worker should NEVER touch
# (teammates, bots, etc.). board-worker.sh will refuse to rescue these.
export BOARD_REAP_HUMAN_ASSIGNEES="${BOARD_REAP_HUMAN_ASSIGNEES:-teammate1,teammate2}"

# Git identity for commits authored by the agent.
export LOCAL_CODER_GIT_NAME="${LOCAL_CODER_GIT_NAME:-Local Coder}"
export LOCAL_CODER_GIT_EMAIL="${LOCAL_CODER_GIT_EMAIL:-local-coder@example.com}"

# ---- Optional (Cloud Run / GCS upload path) ---------------------------------
# Only needed if you run the Cloud Run job variant. Pure-local runs ignore these.

export GCP_PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project}"
export GCS_LOG_BUCKET="${GCS_LOG_BUCKET:-your-log-bucket}"

# ---- Optional (staging smoke tests) -----------------------------------------
# board-worker.sh probes these after merging a PR to confirm staging is healthy.

export STAGING_BACKEND_URL="${STAGING_BACKEND_URL:-https://your-backend-staging.example.com}"
export STAGING_FRONTEND_URL="${STAGING_FRONTEND_URL:-https://your-frontend-staging.example.com}"

# ---- Optional (test commands) -----------------------------------------------
# Some scripts run a "quick test" gate before committing. Customize per stack.

export BACKEND_TEST_CMD="${BACKEND_TEST_CMD:-python -m pytest tests/ -q}"
export FRONTEND_TEST_CMD="${FRONTEND_TEST_CMD:-npm test -- --run}"
