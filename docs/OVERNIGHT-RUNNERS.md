# Overnight Board Runners

Perpetual autonomous agents that work through the GitHub project board 24/7. Nine runners run in parallel, each owning a specific domain or workflow.

## Quick Start

```bash
# Launch all 9 runners
bash scripts/launch-overnight.sh

# Or with nohup to survive terminal close
nohup bash scripts/launch-overnight.sh > logs/launcher.log 2>&1 &

# Monitor
tail -f logs/*.log

# Stop everything
bash scripts/launch-overnight.sh --stop
```

## Runner Architecture

```
launch-overnight.sh
├── backend-worker-1   ← FPA / FactFinder / LangGraph / agentic issues
├── backend-worker-2   ← domain B (e.g. PDF/export issues)
├── backend-worker-3   ← API routes / strategy / search issues
├── frontend-worker-1  ← FactFinder UI / settings pages (priority frontend)
├── frontend-worker-2  ← Remaining frontend Backlog + Todo (overflow)
├── staging-verifier-backend   ← Screenshots + comments on backend staging items
├── staging-verifier-frontend  ← Screenshots + comments on frontend staging items
├── ideas-triage-backend       ← Backend Ideas → well-defined Backlog
└── ideas-triage-frontend      ← Frontend Ideas + untracked issues → Backlog
```

Each runner is driven by `run-local-overnight.sh --queue <queue-file>`. They run independently with separate completed-task tracking files.

## Board Flow

```
Ideas ──(ideas-triage)──→ Backlog ──(board-worker)──→ testing in staging
                                                              │
                                                    (staging-verifier)
                                                              │
                                                    [human approval]
                                                              │
                                                       prod release ready
```

The runners automate the first three stages. Human approval is required before anything reaches "prod release ready."

## Queue Files

| Runner | Queue File |
|--------|-----------|
| backend-worker-1 | `overnight-queue-backend-worker-1.yaml` |
| backend-worker-2 | `overnight-queue-backend-worker-2.yaml` |
| backend-worker-3 | `overnight-queue-backend-worker-3.yaml` |
| frontend-worker-1 | `overnight-queue-frontend-worker-1.yaml` |
| frontend-worker-2 | `overnight-queue-frontend-worker-2.yaml` |
| staging-verifier-backend | `overnight-queue-staging-verify-backend.yaml` |
| staging-verifier-frontend | `overnight-queue-staging-verify-frontend.yaml` |
| ideas-triage-backend | `overnight-queue-ideas-backend.yaml` |
| ideas-triage-frontend | `overnight-queue-ideas-frontend.yaml` |

Each queue file ends with a `regen` task (P3) that generates a `<queue>-next.yaml` file for the next round. The runner detects this and continues perpetually.

## Perpetual Operation

1. Each runner processes its queue top-to-bottom
2. The last task (`*-regen`) queries the board for remaining work and writes a `*-next.yaml` file
3. `run-local-overnight.sh` detects the next-file and loops
4. If no work remains, the regen task writes a polling queue that rechecks periodically

This creates a perpetual loop with no manual intervention required.

## Collision Prevention

Multiple workers may try to pick the same issue. Prevention mechanism:

- Each worker checks for a "board-worker picking up" comment posted within the last 4 hours before claiming
- If a claim comment exists: skip to the next eligible issue
- Workers are domain-partitioned (worker-1 takes domain A, worker-2 takes domain B, etc.) to reduce collision probability

## Staging Verification Rules

The staging verifiers:
1. Navigate to staging using the auth-bypass token (`~/.claude/secrets/staging-auth-bypass-token.txt`)
2. Take screenshots saved to `logs/screenshots/`
3. Post a structured comment on the GitHub issue with PASS/FAIL status
4. Add `staging-fail` label on failure
5. **NEVER auto-promote to "prod release ready"** - all promotions require human approval

## Monitoring

```bash
# Live log for one runner
tail -f logs/backend-worker-1.log

# All runners at once
tail -f logs/*.log

# Current status summary
bash scripts/launch-overnight.sh --status

# See completed tasks per runner
cat logs/overnight-queue-backend-worker-1.completed.txt

# See screenshots
ls -lh logs/screenshots/

# Count how many issues have been verified today
gh issue list -R YourProject-Hedge-Fund-Guy/backend --state open --limit 100 \
  --json number,comments \
  --jq '.[] | select(.comments[].body | contains("Staging Verification"))' | wc -l
```

## Stopping

```bash
# Graceful stop (waits for current task to finish)
bash scripts/launch-overnight.sh --stop

# Force stop all claude processes
pkill -f "run-local-overnight.sh"
pkill -f "claude --dangerously-skip-permissions"
```

## Adding a New Runner

1. Create a new queue YAML in `scripts/overnight-queue-<name>.yaml`
2. Follow the existing queue format: `queue:` key, tasks with `id/priority/category/title/target_repo/model/estimated_duration_minutes/prompt`
3. End the queue with a regen task that writes `overnight-queue-<name>-next.yaml`
4. Add the runner to `launch-overnight.sh` RUNNER_NAMES and RUNNER_QUEUES arrays
5. Add permissions to `.claude/settings.json` if needed

## Troubleshooting

**Runner stopped after one task:**
- Check the task log: `cat logs/<task-id>.log`
- Common cause: STOP condition hit (NEEDS_SECRET, NEEDS_DESIGN, etc.)
- The runner continues to the next task - check the main runner log

**"Startup kill detected":**
- macOS killed claude before it could start (resource pressure)
- `run-local-overnight.sh` retries once automatically with jitter
- If it happens repeatedly, lower the number of parallel runners

**Queue file not found:**
- `ls scripts/overnight-queue-*.yaml` to check all exist
- If a `-next.yaml` file exists but the main file doesn't, rename: `mv ...-next.yaml ...yaml`

**Board column not moving:**
- Check that the PR had `closes #N` in the body (the hook enforces this)
- Check GitHub Actions ran the board-update workflow
- Manually update: `gh project item-edit ...`

**Two workers claimed the same issue:**
- Both will try to create branches - the second push will see a branch already exists
- Resolution: one will fail PR creation; the other completes. The failed one picks a different issue next round.

## Skills Reference

These skills are invokable from any Claude Code session:

| Skill | Command | Description |
|-------|---------|-------------|
| Board Worker | `/board-worker` | Implement one Backlog issue end-to-end |
| Staging Verifier | `/staging-verifier` | Verify one "testing in staging" issue with screenshots |
| Ideas Triage | `/ideas-triage` | Convert one Ideas issue to a well-defined Backlog item |
