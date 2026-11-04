#!/usr/bin/env bash
# local-coder-status.sh - view recent Local Coder run summaries from GCS
#
# Usage:
#   ./local-coder-status.sh            # show last 10 runs
#   ./local-coder-status.sh 20         # show last 20 runs
#   ./local-coder-status.sh <run-id>   # show full log for a specific run
#   ./local-coder-status.sh --tail     # stream the most recent log live
#   ./local-coder-status.sh --jobs     # list Cloud Run Job executions (live status)
#
# Requires: gcloud (authenticated), gsutil or gcloud storage

set -euo pipefail

PROJECT_ID="${CLOUD_CODER_PROJECT:-${GCP_PROJECT_ID:-your-gcp-project}}"
REGION="${CLOUD_CODER_REGION:-us-central1}"
JOB_NAME="${CLOUD_CODER_JOB:-claude-coder}"
BUCKET="${GCS_LOG_BUCKET:-your-log-bucket}"

# --------------------------------------------------------------------------
# Helper: pretty-print a JSON run summary
# --------------------------------------------------------------------------
print_summary() {
    local json="$1"
    echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
status = d.get('status', 'unknown')
icon = '✓' if status == 'success' else ('⚠' if status == 'no-changes' else '✗')
print(f\"  {icon} [{d.get('run_id','?')}]\")
print(f\"    Task:     {d.get('task_type','?')} - {d.get('task_prompt','')[:80]}\")
print(f\"    Repo:     {d.get('repo','?')}  branch: {d.get('work_branch','?')}\")
print(f\"    Status:   {status}\")
print(f\"    Duration: {d.get('duration_seconds','?')}s\")
print(f\"    Model:    {d.get('model','?')}\")
print(f\"    Cost est: {d.get('cost_estimate','N/A')}\")
if d.get('pr_url'):
    print(f\"    PR:       {d.get('pr_url')}\")
if d.get('files_changed') is not None:
    print(f\"    Files:    {d.get('files_changed')} changed\")
print()
" 2>/dev/null || echo "  (could not parse summary: $json)"
}

# --------------------------------------------------------------------------
# --jobs mode: list Cloud Run Job executions via gcloud
# --------------------------------------------------------------------------
if [ "${1:-}" = "--jobs" ]; then
    echo "=== Recent Cloud Run Job Executions ==="
    gcloud run jobs executions list \
        --job="$JOB_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --format="table(name,createTime,completionTime,conditions[0].type:label=STATUS)" \
        --limit=20
    exit 0
fi

# --------------------------------------------------------------------------
# --tail mode: stream the latest run log
# --------------------------------------------------------------------------
if [ "${1:-}" = "--tail" ]; then
    echo "=== Streaming most recent run log ==="
    latest=$(gcloud storage ls "gs://${BUCKET}/runs/" --project="$PROJECT_ID" 2>/dev/null \
        | sort | tail -1 | sed 's|/$||')
    if [ -z "$latest" ]; then
        echo "No runs found in gs://${BUCKET}/runs/"
        exit 1
    fi
    echo "Log: $latest/claude-output.log"
    echo "---"
    gcloud storage cat "${latest}/claude-output.log" --project="$PROJECT_ID" 2>/dev/null \
        || echo "(log not found)"
    exit 0
fi

# --------------------------------------------------------------------------
# Specific run ID: show full log
# --------------------------------------------------------------------------
if [[ "${1:-}" == run-* ]]; then
    RUN_ID="$1"
    echo "=== Run: $RUN_ID ==="
    echo ""
    echo "--- Summary ---"
    gcloud storage cat "gs://${BUCKET}/runs/${RUN_ID}/summary.json" \
        --project="$PROJECT_ID" 2>/dev/null | python3 -m json.tool || echo "(no summary)"
    echo ""
    echo "--- Claude Output ---"
    gcloud storage cat "gs://${BUCKET}/runs/${RUN_ID}/claude-output.log" \
        --project="$PROJECT_ID" 2>/dev/null || echo "(no log)"
    exit 0
fi

# --------------------------------------------------------------------------
# Default: list recent runs with summaries
# --------------------------------------------------------------------------
LIMIT="${1:-10}"
echo "=== Recent Local Coder Runs (last $LIMIT) ==="
echo ""

# List run directories, sorted newest-first
run_dirs=$(gcloud storage ls "gs://${BUCKET}/runs/" --project="$PROJECT_ID" 2>/dev/null \
    | sort -r | head -"$LIMIT" || true)

if [ -z "$run_dirs" ]; then
    echo "No runs found in gs://${BUCKET}/runs/"
    echo ""
    echo "Tip: check live job status with:  $0 --jobs"
    exit 0
fi

while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    dir="${dir%/}"  # strip trailing slash
    summary=$(gcloud storage cat "${dir}/summary.json" --project="$PROJECT_ID" 2>/dev/null || true)
    if [ -n "$summary" ]; then
        print_summary "$summary"
    else
        echo "  ? $dir (no summary.json)"
    fi
done <<< "$run_dirs"

echo "---"
echo "Commands:"
echo "  $0 <run-id>     full log for a specific run"
echo "  $0 --tail       stream the most recent log"
echo "  $0 --jobs       Cloud Run execution list (with live status)"
