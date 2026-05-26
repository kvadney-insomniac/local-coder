# local-coder

An autonomous coding agent harness built on top of the [Claude CLI](https://docs.anthropic.com/en/docs/claude-code). It runs Claude in a loop on your laptop, picks up tasks from a queue (or directly from your GitHub project board), edits code, runs tests, opens PRs, and gets out of the way.

This was extracted from a private monorepo and genericized so it can be dropped onto any single-repo or multi-repo project.

> Heads up: this is the "framework" — the scripts, the queue format, the loop. The actual tasks (and your project's conventions) live in your own repo's `CLAUDE.md` and queue YAMLs.

## What it does

- **Board worker** (`scripts/board-worker.sh`): polls your GitHub project board for issues in an "In Progress" column assigned to you, claims one, branches, codes, tests, opens a PR, optionally merges, smoke-tests staging.
- **Queue runner** (`scripts/run-local-overnight.sh`): reads a YAML queue, runs each task end-to-end. Designed for unattended overnight runs.
- **Audit loop** (`scripts/audit-scan.sh` + `audit-fix-loop.sh`): scans for code-quality / security signals and files GitHub issues for each, then optionally fixes them.
- **Resource hygiene** (`scripts/memory-watchdog.sh`): pauses workers when the host machine is under memory pressure. Built after one too many runaway-Playwright incidents.
- **Telemetry** (`scripts/telemetry-collect.sh` + `telemetry-report.sh`): per-task timing, success rate, model usage.

## Prerequisites

- macOS or Linux with `bash`, `jq`, `yq`, `gh` (GitHub CLI), and `git` on PATH
- The [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) authenticated against a Claude Max subscription (or API key)
- A target git repo with a `CLAUDE.md` describing your conventions
- (Optional) A GitHub Projects board if you want the board-worker mode

## Quickstart

```bash
git clone https://github.com/<you>/local-coder
cd local-coder

# 1) Configure
cp config/config.example.sh config/config.sh
$EDITOR config/config.sh        # set REPO_ROOT, BOARD_OWNER, etc.
source config/config.sh

# 2) Try a queue run against the example queue
QUEUE=queues/example.yaml bash scripts/run-local-overnight.sh

# 3) Or kick off the board worker (needs a GitHub Projects board)
bash scripts/board-worker.sh
```

## Repo layout

```
scripts/      — runner, board worker, audit, telemetry, watchdog
config/       — config.example.sh, task-catalog.yaml
queues/       — example queue YAMLs (add your own)
docs/         — CLAUDE.md (rules the agent reads), runbooks
```

## Safety model

This harness intentionally constrains the agent:

- It only commits to a fresh `local-coder/YYYYMMDD-HHMMSS` feature branch
- It never force-pushes
- It refuses to touch `.env`, `*.tfvars`, `secrets/`, `credentials*`
- Every commit is prefixed `[local-coder]` and co-authored to `local-coder@example.com` so you can filter every automated change with `git log --grep="\[local-coder\]"`
- The board worker's "rescue" mode has an explicit allowlist; it will not touch PRs authored by anyone outside it (configurable via `BOARD_REAP_HUMAN_ASSIGNEES`)

Read `docs/CLAUDE.md` for the full rule set the agent operates under.

## What this isn't

- Not a hosted service. Runs on your laptop / workstation. Cost = your Claude subscription.
- Not a code-review tool. It writes code; review it yourself before merging anything load-bearing.
- Not magic. Garbage tasks in → garbage PRs out. The queue prompts matter.

## License

MIT. See [LICENSE](LICENSE).
