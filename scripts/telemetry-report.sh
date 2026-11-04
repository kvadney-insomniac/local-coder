#!/usr/bin/env bash
# telemetry-report.sh - Human-readable rollup from telemetry-snapshot.json.
#
# Reads logs/telemetry-snapshot.json (produced by telemetry-collect.sh) and
# prints a table. PRs(24h) is looked up via gh and cached for 1 hour at
# logs/telemetry-prs-cache.json so the report doesn't hammer GitHub.
#
# Usage:
#   bash telemetry-report.sh
#   bash telemetry-report.sh --no-prs   # skip the gh lookup
#
# Env:
#   PR_CACHE_TTL=3600   override cache TTL in seconds (default 3600)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
SNAPSHOT="${LOG_DIR}/telemetry-snapshot.json"
PR_CACHE="${LOG_DIR}/telemetry-prs-cache.json"
PR_CACHE_TTL="${PR_CACHE_TTL:-3600}"

SKIP_PRS="false"
[[ "${1:-}" == "--no-prs" ]] && SKIP_PRS="true"

if [[ ! -f "${SNAPSHOT}" ]]; then
    echo "ERROR: ${SNAPSHOT} not found. Run telemetry-collect.sh first." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Refresh PR cache if stale
# --------------------------------------------------------------------------
refresh_pr_cache() {
    local since
    since=$(date -u -v -24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

    local owner="YourProject-Hedge-Fund-Guy"
    local be_count=0 fe_count=0
    if command -v gh >/dev/null 2>&1; then
        be_count=$(gh pr list -R "${owner}/backend" --state all --limit 100 \
            --search "author:${BOARD_OWNER:-your-github-handle} created:>${since}" --json number 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        fe_count=$(gh pr list -R "${owner}/frontend" --state all --limit 100 \
            --search "author:${BOARD_OWNER:-your-github-handle} created:>${since}" --json number 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    fi

    cat > "${PR_CACHE}" <<EOF
{
  "fetched_at_epoch": $(date +%s),
  "since": "${since}",
  "backend_prs_24h": ${be_count},
  "frontend_prs_24h": ${fe_count}
}
EOF
}

if [[ "${SKIP_PRS}" != "true" ]]; then
    refresh=true
    if [[ -f "${PR_CACHE}" ]]; then
        fetched=$(python3 -c "import json;print(json.load(open('${PR_CACHE}'))['fetched_at_epoch'])" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$(( now - fetched ))
        [[ $age -lt $PR_CACHE_TTL ]] && refresh=false
    fi
    $refresh && refresh_pr_cache
fi

BE_PRS=0; FE_PRS=0
if [[ -f "${PR_CACHE}" ]]; then
    BE_PRS=$(python3 -c "import json;print(json.load(open('${PR_CACHE}'))['backend_prs_24h'])" 2>/dev/null || echo 0)
    FE_PRS=$(python3 -c "import json;print(json.load(open('${PR_CACHE}'))['frontend_prs_24h'])" 2>/dev/null || echo 0)
fi

# --------------------------------------------------------------------------
# Render report (python for clean column formatting + JSON parsing)
# --------------------------------------------------------------------------
BE_PRS="${BE_PRS}" FE_PRS="${FE_PRS}" SNAPSHOT="${SNAPSHOT}" python3 <<'PYEOF'
import json, os, datetime

snap_path = os.environ['SNAPSHOT']
be_prs = int(os.environ.get('BE_PRS', 0) or 0)
fe_prs = int(os.environ.get('FE_PRS', 0) or 0)

with open(snap_path) as f:
    snap = json.load(f)

ts = snap.get('timestamp', '?')
totals = snap.get('totals', {})
workers = snap.get('workers', [])

# Attribute PRs(24h) to backlog-* and rescue-* workers (the modes that produce PRs).
# Split per-target equally across worker count.
def _share(workers, mode, target, total):
    candidates = [w for w in workers if w['mode'] == mode and (w['target'] == target or target == 'both')]
    if not candidates: return {}
    per = total // len(candidates) if candidates else 0
    rem = total - per * len(candidates)
    out = {}
    for i, w in enumerate(candidates):
        out[w['name']] = per + (1 if i < rem else 0)
    return out

be_share = {}
fe_share = {}
for mode in ('backlog', 'rescue'):
    be_share.update(_share(workers, mode, 'backend', be_prs if mode=='backlog' else 0))
    fe_share.update(_share(workers, mode, 'frontend', fe_prs if mode=='backlog' else 0))
# Rescue produces some PRs (fixes) - attribute proportionally to repo of the worker
for w in workers:
    if w['mode'] == 'rescue' and w['target'] == 'backend':
        # Add rescue's share - split rescue's 24h activity equally with backlog
        pass

pr_attr = {}
for w in workers:
    name = w['name']
    if w['mode'] == 'backlog' and w['target'] == 'backend':
        pr_attr[name] = be_share.get(name, 0)
    elif w['mode'] == 'backlog' and w['target'] == 'frontend':
        pr_attr[name] = fe_share.get(name, 0)
    else:
        pr_attr[name] = 0

print()
print(f"Board Worker Telemetry - snapshot {ts}")
print(f"{'='*94}")
print(f"{'Worker':<22} {'Mode':<16} {'Iter':>6} {'Done':>6} {'Idle':>6} {'Work(min)':>10} {'KB-in':>10} {'PRs(24h)':>9}")
print(f"{'-'*94}")

total_iter=total_done=total_idle=total_work=total_bytes=total_prs=0
for w in workers:
    name = w['name']
    mode = w['mode']
    target = w['target']
    mode_label = f"{mode}/{target}" if target != 'both' else mode
    if len(mode_label) > 15: mode_label = mode_label[:15]
    iter_ = int(w.get('iter', 0))
    done = int(w.get('done', 0))
    idle = int(w.get('idle', 0))
    work = int(w.get('work_min', 0))
    bytes_in = int(w.get('bytes_in', 0))
    kb = bytes_in // 1024
    prs = pr_attr.get(name, 0)
    total_iter += iter_; total_done += done; total_idle += idle
    total_work += work; total_bytes += bytes_in; total_prs += prs
    print(f"{name:<22} {mode_label:<16} {iter_:>6} {done:>6} {idle:>6} {work:>10} {kb:>10} {prs:>9}")

print(f"{'-'*94}")
total_kb = total_bytes // 1024
total_mb = total_bytes // (1024*1024)
print(f"{'TOTAL':<22} {'':<16} {total_iter:>6} {total_done:>6} {total_idle:>6} {total_work:>10} {total_kb:>10} {be_prs+fe_prs:>9}")
print()
print(f"PRs by repo (24h, author=${BOARD_OWNER:-your-github-handle}): backend={be_prs}  frontend={fe_prs}")
print(f"Total task-log volume (proxy for Claude Max byte burn): {total_mb} MB across {sum(int(w.get('task_log_count',0)) for w in workers)} task logs")
print()
print(f"Caveats:")
print(f"  - bytes_in is stdout/log byte count, NOT a real token count")
print(f"  - PRs(24h) attribution is approximate (split evenly across backlog workers of the same target)")
print(f"  - work_min comes from worker batch summaries; in-flight batches not yet counted")
PYEOF
