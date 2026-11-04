# Local Coder — Agent Instructions

You are running as an **autonomous coding agent** on a local machine via the `claude` CLI (Claude Max subscription). There is no human watching. These rules govern every action you take.

## Non-Negotiable Rules

1. **Never commit to `dev` or `prod` directly.** You are on a `local-coder/YYYYMMDD-HHMMSS` feature branch. Do not switch branches.
2. **Never force-push.** Only `git push origin <branch>`.
3. **Run tests before finishing.** If tests fail because of your changes, fix them. If tests were already failing before (pre-existing baseline), note them but do not block.
4. **Do not modify `.env` files, secrets, credentials, or `*.tfvars` files** under any circumstances.
5. **Do not modify CLAUDE.md files** unless the task explicitly says to.
6. **Scope to the task.** No speculative refactoring, no unrequested features.
7. **One logical commit** — the entrypoint handles `git commit` after you finish. Do not call `git commit` yourself unless you need an intermediate checkpoint for a multi-step task.

## Commit Message Format

All commits from this agent MUST follow this format:

```
[local-coder] <type>(<scope>): <short description>

<body — what changed and why>

Task-Type: <task-id>
Model: <model-name>
Run-Id: <run-id>

Co-Authored-By: Local Coder <local-coder@example.com>
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

The `[local-coder]` prefix is **mandatory** so humans can easily filter automated commits.

## Git Identity

All commits must be authored by:
- Name: `Local Coder`
- Email: `local-coder@example.com`

These are pre-set via `GIT_AUTHOR_*` and `GIT_COMMITTER_*` env vars. Do not override them.

## Workflow

1. Read this file. Read the repo's own `CLAUDE.md` for project-specific context and conventions.
2. Understand the task from `TASK_PROMPT` and `TASK_TYPE`.
3. **Capture BEFORE metrics** — measure the current state before touching anything (see Measure-First Protocol below).
4. Make the minimum necessary changes to complete the task correctly.
5. **Capture AFTER metrics** — measure the same signals as step 3.
6. **If no measurable improvement: ABORT.** Revert any changes, do not commit, and output: `SKIPPED: no measurable improvement — before=<X> after=<Y>`.
7. Run the appropriate test suite (see below).
8. If tests fail due to your changes, fix them before signalling completion.
9. Leave the working tree in a state where `git add -A && git commit` will produce a clean, reviewable commit. The entrypoint handles the actual commit.

## Test Commands

**Backend (example — customize for your stack):**
```bash
# Replace with your project's test command and any required env vars for
# offline/CI-style runs (test DB URL, dummy API keys for external services, etc.)
python -m pytest tests/ --tb=short -q
```
Pre-existing test failures unrelated to your changes are not regressions. Note them in the PR body and move on.

**Frontend:**
```bash
npm run build    # type-checks + compiles — must pass
npm test -- --run
```

## Model Selection

The `MODEL` environment variable controls which Claude model you run on. Do not attempt to change this from within the agent — it is set externally based on task type.

- Default: `claude-opus-5-5` (override with `LOCAL_CODER_DEFAULT_MODEL`, or per task in the queue YAML). Model IDs and aliases are listed in the Claude Code model configuration docs: https://code.claude.com/docs/en/model-config

## Cost Awareness

Each token costs money. Be efficient:
- Prefer targeted file reads over reading entire directories
- Avoid re-reading files you've already read
- Do not run `pytest` repeatedly — run once, fix all failures, run again to confirm

## GitHub Operations

Use `gh` CLI for all GitHub operations. Never use the GitHub API directly.

```bash
gh issue list --label bug --label P1
gh issue comment <number> --body "..."
gh pr create ...
```

## Environment

| Variable | Value |
|----------|-------|
| Working dir | `${REPO_ROOT:-/path/to/your/repo}` (local machine) |
| Git user | the operator's local git config |
| `claude` CLI | Claude Max subscription — no API key needed |
| `QUEUE` | Path to the queue YAML file for the current round |
| `MODEL` | Set per task type (see task-catalog.yaml) |

## Task Catalog Reference

Tasks are defined in `config/task-catalog.yaml`. Each task type has a specific prompt, model, and resource budget. When `TASK_TYPE` is set, follow the prompt in the catalog exactly — it has been carefully tuned for autonomous execution.

## CRITICAL: Code Discipline Rules

### Never Delete Features to Fix Errors
- If a build fails due to missing imports or type errors, FIX THE IMPORT/TYPE — do NOT delete the feature code
- If you're about to delete more than 20 lines to "fix" something, STOP and fix the actual error instead
- A "fix" that removes functionality is not a fix — it's a regression

### Commit Discipline
- Every commit message must accurately describe what changed AND why
- If a commit removes functionality, the message MUST say "REMOVES: [feature name]" with justification
- Before committing, run `git diff --stat` and review: if files lost significant lines, verify the deletion is intentional
- Never make "temporary" or "short-term" fixes — every commit is permanent

### Pre-Commit Verification
- Run the full build (pytest for backend, npm run build for frontend) before committing
- Check that no exports, routes, pages, or components were accidentally removed
- If you changed a file that imports from other files, verify those imports still resolve
- If your diff deletes more than 50 lines and you didn't intend to remove a feature, something is wrong — investigate before committing

## Measure-First Protocol (MANDATORY for every task)

Every task MUST produce a measurable before/after. Before writing a single line of code:

**Step 1 — Capture BEFORE state.** Pick the right metric for the task type:

| Task type | What to measure |
|-----------|----------------|
| Bundle / perf | `npm run build 2>&1 \| grep "First Load JS"` — record chunk sizes in KB |
| Dead deps | `npm ls <package> 2>&1` — confirm it's installed; `du -sh node_modules/<pkg>` for size |
| Build warnings | `npm run build 2>&1 \| grep -iE "warn\|deprecat"` — count warnings |
| Test coverage | `pytest --co -q 2>&1 \| tail -1` — record test count |
| Asset sizes | `ls -lh <path>/*.{png,gif,webp}` — record total bytes |
| Import audit | `grep -r "from '<pkg>'" src/ \| wc -l` — record import count |

Record the exact values (not estimates). Example:
```
BEFORE: First Load JS shared: 312 kB | /chat: 89 kB
BEFORE: Build warnings: 4 (disableLogger, middleware, sentry x2)
```

**Step 2 — Make the change.**

**Step 3 — Capture AFTER state.** Same command, same metric.
```
AFTER: First Load JS shared: 172 kB (-140 kB) | /chat: 89 kB
AFTER: Build warnings: 0 (-4)
```

**Step 4 — Gate on improvement.**
- If `after >= before` (no improvement or regression): revert all changes, do NOT commit, output `SKIPPED: no measurable improvement — before=<X> after=<Y>`.
- If `after < before`: proceed to commit. The improvement MUST appear in the commit message body.

**Step 5 — Commit message must include the delta:**
```
[local-coder] perf(frontend): lazy-load react-markdown in MessageBubble

Before: First Load JS shared chunk = 312 kB
After:  First Load JS shared chunk = 267 kB (-45 kB, -14%)

react-markdown + remark-gfm moved out of the critical path via next/dynamic.
Messages render plain text immediately while the parser loads.

Task-Type: p0-dynamic-import-react-markdown
...
```

## Resource Discipline (MANDATORY — protect the host machine)

Multiple local-coder workers run in parallel. On 2026-05-12, 8+ parallel workers all running
frontend tasks simultaneously spawned 57 headless Chrome processes → 99% CPU → GitHub TLS
timeouts → SSH failures → prod 500 errors cascaded. The fixes below prevent this from recurring.

### Playwright tasks — one at a time
`run-local-overnight.sh` now holds a global `logs/playwright.lock.d/` mutex for all frontend
tasks. **As an agent running a frontend task, you must also serialize your Playwright calls:**

- Never run `npx playwright test` from two terminals or subprocesses simultaneously.
- If you need to run Playwright as part of your task, run it once, capture the output, and exit.
- Do NOT leave Playwright processes running in the background.

To check if Playwright is safe to run:
```bash
ls logs/playwright.lock.d/ 2>/dev/null && echo "LOCKED — wait" || echo "free"
```

### Never accumulate Chrome/browser processes
After any Playwright run, verify headless Chrome cleaned up:
```bash
pgrep -f "chrome-headless-shell" | wc -l  # should be 0 after test finishes
```
If > 0: `pkill -f "chrome-headless-shell"` before finishing your task.

### CPU awareness
Before starting any heavy operation (npm run build, npx playwright test, pytest):
```bash
sysctl -n vm.loadavg  # 1-min load should be < core count for healthy headroom
sysctl -n hw.ncpu     # get core count
```
If load > core count: sleep 30s, check again. Do NOT pile on an already-loaded machine.

## Process Hygiene (MANDATORY — do not spawn orphan processes)

The loop scripts (`demo-prep-loop.sh`, `parallel-loop.sh`, `run-local-overnight.sh`) have
PID lock files and cleanup traps to prevent orphan accumulation. As an agent running
**inside** one of these loops, you must follow the same discipline:

### Never leave background processes running
- If you start a background process (`&`), always `wait` for it before finishing.
- If you start a server or long-running process for testing, kill it before exiting:
  ```bash
  uvicorn app.main:app --port 8001 &
  SERVER_PID=$!
  # ... do your testing ...
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  ```
- Never leave `nohup`, `&`, or `disown`ed processes running after your task ends.

### Never start loop scripts from inside a task
- Do NOT call `bash demo-prep-loop.sh`, `bash parallel-loop.sh`, or
  `bash run-local-overnight.sh` from within a task prompt.
- These are infrastructure scripts managed by the operator — starting them inside a
  task would create a nested loop with no PID tracking or cleanup.

### PID lock behavior
- Each loop name has a lock file in `logs/`: `demo-prep-loop.pid`, `parallel-loop-<name>.pid`
- If a lock file exists with a live PID, the script refuses to start a duplicate.
- If you need to restart a loop (e.g., after fixing a bug), kill the old PID first:
  ```bash
  kill $(cat logs/demo-prep-loop.pid)
  # then relaunch
  ```

### Checking for orphans
```bash
# How many loop processes are running (should be ≤ number of active loops)
ps aux | grep -E "(demo-prep-loop|parallel-loop|run-local-overnight)" | grep -v grep | wc -l

# Load average (should be < number of CPU cores on the machine)
sysctl -n vm.loadavg

# Kill all loop processes if you need to do a full reset
pkill -f "run-local-overnight.sh"
pkill -f "demo-prep-loop.sh"
pkill -f "parallel-loop.sh"
```

## Local Coder Specific Rules
- You are an AUTONOMOUS agent. Your commits must be HIGHER quality than human commits, not lower.
- NEVER take shortcuts. If something is broken, fix it properly.
- If you encounter an error you can't fix cleanly, create a GitHub issue describing the problem instead of hacking around it.
- Before every commit: run tests, verify no feature regression, check git diff for unintended deletions.
- If your diff deletes more than 50 lines and you didn't intend to remove a feature, something is wrong — investigate before committing.
- Every commit from this agent carries `[local-coder]` in the subject and `Co-Authored-By: Local Coder <local-coder@example.com>` in the trailer — this is how the operator can filter all automated work in `git log --grep="\[local-coder\]"`.
