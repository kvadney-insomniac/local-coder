# Continuous Audit

Periodic, deterministic code-quality scanner that files GitHub issues onto the
project board (#10). Mirrors the local-coder loop pattern in this directory but
does **not** call Claude - the scanner is pure static-analysis, so cost is zero
and findings are reproducible.

## What gets audited

| Layer | Tool | Catches |
|---|---|---|
| `backend/app/**.py` | `vulture --min-confidence 80` | Unused functions/vars/classes |
| `backend/app/**.py` | `ruff` (rules `F,B,SIM,RUF,PERF,PLW`) | Bugs, smells, perf footguns |
| `backend/app/**.py` | `grep` | `TODO/FIXME/XXX/HACK`, `raise NotImplementedError` |
| `frontend/src/**.{ts,tsx}` | `ts-prune` | Dead exports |
| `frontend/src/**.{ts,tsx}` | `eslint --format json` | Lint warnings & errors |
| `frontend/src/**.{ts,tsx}` | `grep` | TODO markers |

Each finding becomes one GitHub issue with labels `audit` + a category label
(`audit:dead-code`, `audit:incomplete`, `audit:quality`, `audit:stub`).

## Files

| File | Role |
|---|---|
| `audit-scan.sh` | Run all tools, emit unified findings JSON, deterministic fingerprint per finding |
| `audit-file-issues.py` | Dedupe against existing issues, create new ones, attach to project board |
| `continuous-audit-loop.sh` | PID-locked driver: scan → file → sleep, repeat forever |

## Install (prereqs)

```bash
# Backend tools
pip install vulture ruff jq    # jq via brew if missing

# Frontend tools (one-time, in frontend/)
cd frontend && npm install --save-dev ts-prune

# gh CLI must be authed as ${BOARD_OWNER:-your-github-handle}
gh auth status
```

`jq` is required by the shell scanner. `python3` for the issue filer.

## Manual run (dry-run first, always)

```bash
# 1. Scan only - writes JSON, no GitHub calls
bash scripts/audit-scan.sh
# stdout's last line is the path, e.g.
#   logs/audit-findings-20260521-...json

# 2. Inspect the proposed issues (dry-run is the default)
python3 scripts/audit-file-issues.py \
    logs/audit-findings-*.json

# 3. Actually file (capped at 10 by default)
python3 scripts/audit-file-issues.py \
    logs/audit-findings-*.json --apply
```

## Continuous run

```bash
nohup bash scripts/continuous-audit-loop.sh \
     > /tmp/continuous-audit-loop.log 2>&1 &
```

Tunables (env vars):

| Var | Default | Meaning |
|---|---|---|
| `AUDIT_INTERVAL` | `21600` | Seconds between scans (6h) |
| `AUDIT_MAX_NEW` | `10` | Cap on new issues per round - prevents flooding |
| `AUDIT_DRY_RUN` | `0` | `1` to log what *would* be filed without creating |

PID lock lives at `logs/continuous-audit-loop.pid` - a second
invocation refuses to start while the first is alive (same pattern as
`demo-prep-loop.sh` and `parallel-loop.sh`).

## launchd (auto-start on login)

Install once:

```bash
cp scripts/com.your-project.continuous-audit.plist \
   ~/Library/LaunchAgents/com.your-project.continuous-audit.plist
launchctl load ~/Library/LaunchAgents/com.your-project.continuous-audit.plist
```

(The plist isn't checked in yet - model it on
`scripts/com.your-project.memory-watchdog.plist` referenced in the root
`CLAUDE.md`.)

## Dedup model

Every issue body carries a hidden trailer:

```
<!-- audit-fingerprint: <sha256> -->
```

The fingerprint is a SHA-256 over
`category | repo | file | rule | normalized-evidence`, where
`normalized-evidence` collapses whitespace and replaces line numbers with `N`.
That way:

- Renaming the issue title does **not** un-dedupe.
- A reformatted file does **not** create a duplicate.
- Closing an issue (any reason) suppresses future re-files - closed counts as
  "won't fix" so the scanner won't churn the board.

To force a re-file: delete the original issue (not close), or change the rule
code emitted by the scanner.

## How to silence a noisy rule

1. **Globally**: remove the rule from the `--select` list in `audit-scan.sh`
   (e.g., drop `PLW` if ruff PLW warnings are too chatty).
2. **For one file**: add the standard tool ignore (`# noqa: F401`,
   `// eslint-disable-line`, `# vulture: ignore`).
3. **For one finding**: close the issue with the `wontfix` label - the
   fingerprint trailer prevents re-files.

## Why static tools, not Claude

The neighboring `audit-fix-loop.sh` uses Claude to score the codebase 1-10 across
seven dimensions - that's the right tool for a holistic readiness narrative.
But for filing one ticket per smell, deterministic tools are:

- **Free** - no token spend per scan.
- **Reproducible** - the same `ruff F401` finds the same line every time, so
  fingerprints stay stable.
- **Fast** - a full scan is seconds, not minutes.

The output JSON is structured enough that a later enhancement could pipe it
through Claude for *triage* (grouping related findings, drafting a unified PR
plan) without re-running the scan.

## Board placement

New issues are added to project #10 via `gh project item-add`. The project's
default landing column is **Inbox**; you can move them to Backlog manually or
extend `audit-file-issues.py` to set the Status field directly using the
GraphQL helpers in `board-lib.sh` (`board_move_item`).
