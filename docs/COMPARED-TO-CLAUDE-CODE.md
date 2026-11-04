# How local-coder differs from Claude Code's own agent features

local-coder is a bash loop around `claude -p`. Since it was written, Claude Code has
grown built-in features that cover much of what the loop does: non-interactive runs,
cloud sessions, scheduled tasks, parallel agents, hooks, sandboxing, and cost reporting.
This page maps each part of the harness to the closest built-in feature and says where
they differ, so you can decide which pieces of the harness are still worth running.

Every statement about Claude Code below is cited to a page on code.claude.com/docs.
All pages were read on 2026-11-03; the docs change often, so re-check before relying
on a detail. Statements about the harness cite files in this repository.

## Summary

| Harness piece | Closest Claude Code feature | Main difference |
| :- | :- | :- |
| `claude -p` wrapper in `run-local-overnight.sh` | Headless mode via the Agent SDK CLI [1] | Harness reads plain text output; the CLI offers JSON with cost and session metadata [1] |
| `--dangerously-skip-permissions` on the laptop | Permission modes, auto mode, the Bash sandbox [3][4] | The docs limit bypass mode to isolated containers or VMs [3]; the harness runs it on the host |
| Rules in `docs/CLAUDE.md` and the prompt preamble | CLAUDE.md memory files and hooks [5][6] | Memory is context, not enforcement; hooks are deterministic [5][6] |
| Queue YAML plus `nohup` loop | Cloud scheduled tasks, `/loop`, Desktop scheduled tasks, GitHub Actions schedules [7][8][9] | Cloud tasks run without the laptop but on a fresh clone [8] |
| Parallel workers with locks and resource gates | Agent view, worktrees, subagents, agent teams [10] | Worktrees isolate files per session; the harness shares one checkout per repo [10] |
| `entrypoint.sh` Cloud Run job | Cloud sessions with `claude --cloud` and PR auto-fix [11] | Cloud sessions keep git credentials outside the sandbox and count toward plan usage [11] |
| Cost grep in `entrypoint.sh` and `telemetry-*.sh` | `--output-format json`, `/usage`, `--max-budget-usd` [1][12][2] | Structured, per-model cost figures instead of a regex over text [1] |
| Model IDs in queue YAML | `--model` with aliases or full names [13] | Aliases track the newest model; full names pin a version [13] |

## 1. Running a task without a human

**What the harness does.** `scripts/run-local-overnight.sh` runs each queue task as
`claude --dangerously-skip-permissions -p "$PROMPT" --model "$MODEL" < /dev/null` from
the target repo, under `timeout`, and treats a non-zero exit as a failed task. The
Cloud Run variant in `scripts/entrypoint.sh` adds `--max-turns`.

**What Claude Code offers.** The `-p` (or `--print`) flag is the documented way to run
Claude Code non-interactively. The docs describe it as the Agent SDK's CLI form: "The
Agent SDK gives you the same tools, agent loop, and context management that power
Claude Code. It's available as a CLI for scripts and CI/CD, or as Python and TypeScript
packages for full programmatic control." [1] A run "exits with code 0 on success and a
non-zero code when the run fails, so your scripts can branch on the exit status." [1]

Two flags matter for a harness:

- `--max-turns`: "Limit the number of agentic turns (print mode only). No limit by
  default." [2]
- `--max-budget-usd`: a spend cap for print mode; if the cap is reached, "Claude Code
  stops the remaining background work instead of waiting." [1][2]

The docs recommend `--bare` for scripts: it skips "auto-discovery of hooks, skills,
custom commands, subagents, installed plugins, MCP servers, auto memory, and CLAUDE.md"
and "is the recommended mode for scripted and SDK calls, and will become the default
for `-p` in a future release." [1] Without it, "a `-p` session runs the hooks in a
project's `.claude/settings.json` and connects the servers in its `.mcp.json`, even in
a folder you've never trusted." [1] Note that bare mode "doesn't use your subscription
login" and needs `ANTHROPIC_API_KEY`. [1]

**Difference.** The harness does not pass `--bare`, so whatever hooks and MCP servers
the target repo configures run during an overnight task. That is sometimes what you
want (the repo's own CLAUDE.md loads) and sometimes a surprise. The harness also does
not set `--max-turns` in the local runner, only in `entrypoint.sh`, so a local task is
bounded only by the wall-clock `timeout`.

## 2. Permissions and isolation

**What the harness does.** Every invocation passes `--dangerously-skip-permissions` and
runs on the operator's laptop. Safety comes from prose rules (`docs/CLAUDE.md`), the
preamble in `run-local-overnight.sh`, and the git conventions in the README.

**What Claude Code offers.** The flag is "Equivalent to `--permission-mode
bypassPermissions`." [2] The permission modes page says of that mode: "Only use this
mode in isolated environments like containers, VMs, or dev containers without internet
access, where Claude Code cannot damage your host system" and "`bypassPermissions`
offers no protection against prompt injection or unintended actions." [3] On Linux and
macOS, Claude Code refuses to start in this mode as root or under sudo. [3]

Alternatives documented for unattended runs:

- Auto mode: "A separate classifier model reviews actions before they run, blocking
  anything that escalates beyond your request, targets unrecognized infrastructure, or
  appears driven by hostile content Claude read." [3]
- `dontAsk` plus `--allowedTools` for "locked-down CI runs": every call that would
  prompt is denied. [1][3]
- `--permission-prompts none` for scheduled jobs where nobody can answer a prompt. [1]
- Since v2.1.302, `claude -p` runs "start in Manual mode when nothing sets a permission
  mode," so a bare `-p` call denies anything that needs approval. [1]

Separately from modes, the Bash sandbox is "a boundary that the operating system
enforces around the shell commands Claude runs on your machine." It is "off by
default," uses Seatbelt on macOS and `bubblewrap` plus `socat` on Linux, and covers
shell commands only; "Claude's file tools, MCP servers, and hooks run outside it." [4]
Deny rules in settings "block in every mode, including `bypassPermissions`." [3]

**Difference.** The harness's threat model is "trusted repo, trusted queue, trusted
laptop." The docs now give three cheaper layers than a prose rule set: a sandbox for
shell commands, deny rules that survive bypass mode, and auto mode's classifier. The
harness's resource gates (CPU, memory, Playwright lock) have no built-in counterpart in
the pages cited here; they exist because many workers share one laptop.

## 3. Project rules: CLAUDE.md

**What the harness does.** `docs/CLAUDE.md` holds the rule set the agent is meant to
follow, and the README tells operators to keep a `CLAUDE.md` in the target repo.

**What Claude Code offers.** CLAUDE.md files "give Claude persistent instructions for a
project, your personal workflow, or your entire organization" and are read "at the
start of every session." [5] They load from a managed policy path, `~/.claude/CLAUDE.md`,
and `./CLAUDE.md` or `./.claude/CLAUDE.md`, in that order; files in subdirectories load
on demand, and `AGENTS.md` can stand in for the project file. [5] Files can pull in
others with `@path/to/import`. [5] The docs suggest keeping each file under 200 lines
and moving path-specific rules into `.claude/rules/`. [5] Claude also keeps "auto
memory," notes it writes itself. [5]

The key caveat: "Claude treats them as context, not enforced configuration. To block an
action regardless of what Claude decides, use a PreToolUse hook instead." [5]

**Difference.** `docs/CLAUDE.md` lives in this repository, but the CLI runs with the
target repo as its working directory, so Claude never reads this file unless the target
repo's own CLAUDE.md imports it or the operator copies it. The harness's rules
(never force-push, never touch `.env`, one logical commit) are the kind the docs say
to enforce with hooks or deny rules rather than prose.

## 4. Enforcing rules: hooks

**What the harness does.** Enforcement happens after the fact in bash: `entrypoint.sh`
counts changed files, writes the commit with required trailers, and pushes; the
runner retries startup kills and records completions. Nothing stops a destructive
command while it is running.

**What Claude Code offers.** "Hooks are user-defined shell commands. Claude Code runs
them at specific points in its lifecycle, which gives you deterministic control: certain
actions always happen rather than relying on the LLM to choose to run them." [6] Events
include `SessionStart`, `PreToolUse` ("Before a tool call executes. Can block it"),
`PermissionRequest`, `PostToolUse`, and `PostToolUseFailure`. [6] The guide's example
blocks edits to `.env`, lock files, and `.git/` by exiting with code 2 from a
`PreToolUse` hook, and Claude "receives feedback explaining why the edit was blocked."
[6] A `PermissionRequest` hook can approve on your behalf by returning
`"behavior": "allow"`. [6]

**Difference.** The harness's "never modify `.env`, secrets, credentials, or
`*.tfvars`" rule maps directly onto the documented `PreToolUse` example. A hook in the
target repo's `.claude/settings.json` would enforce it in every session, including
interactive ones, with no change to the harness.

## 5. Scheduling and unattended runs

**What the harness does.** A queue YAML is consumed top to bottom; the docs recommend
`nohup` for overnight runs, and `docs/OVERNIGHT-RUNNERS.md` describes a perpetual loop
where the last task writes the next queue file.

**What Claude Code offers.** Three documented options, compared in one table on the
scheduled tasks page [7]:

- Cloud scheduled tasks ("formerly routines") are "a saved Claude Code configuration:
  a prompt, one or more repositories, and a set of connectors, packaged once and run
  automatically." Triggers are a schedule, an HTTP API call, or a GitHub event. They
  run on Anthropic-managed cloud infrastructure or a self-hosted environment, "so they
  keep working when your laptop is closed." [8] "Each repository is cloned at the start
  of a run. Claude creates `claude/`-prefixed branches for its changes." [8] Runs on
  Anthropic's cloud begin in auto mode unless it is unavailable. [8] They are in
  research preview and available on Pro, Max, Ultra, Team, and Enterprise plans. [8]
- `/loop` runs a prompt on an interval inside an open session, with a one-minute
  minimum and a seven-day expiry; "Tasks only fire while Claude Code is running and
  idle." [7]
- Desktop scheduled tasks run on your machine with access to local files. [7]
- GitHub Actions with a `schedule` trigger; note that "GitHub runs scheduled workflows
  only from the default branch and, in public repositories, disables the schedule after
  60 days without repository activity." [9]

**Difference.** The harness keeps the laptop on and works against a live checkout, with
whatever is installed locally. Cloud scheduled tasks give "No (fresh clone)" access to
local files [7], so anything that depends on local state (a running database, a
staging token on disk) stays with the harness. The harness's "regen" meta-task, which
writes the next queue, has no direct equivalent in the pages cited; the closest is a
cloud task with a GitHub trigger that reacts to each PR event. [8]

## 6. Parallel workers

**What the harness does.** `launch-overnight.sh` and `parallel-loop.sh` start several
runners against the same `REPO_ROOT`, serialised by a Playwright lock, CPU and memory
gates, and PID files.

**What Claude Code offers.** Five documented approaches: subagents, agent view, agent
teams, dynamic workflows, and projects. [10] Agent view is "One screen to dispatch and
monitor sessions running in the background, opened with `claude agents`." [10]
"Worktrees give each session a separate git checkout, so parallel sessions each edit
their own copy of the files," and "A session you dispatch from agent view moves into a
worktree of its own before it edits files." [10] Agent teams are "Experimental and
disabled by default." [10] The page warns that "Running several sessions or subagents
at once multiplies token usage." [10]

**Difference.** The harness's workers share one working tree per target repo and rely
on domain partitioning plus locks to avoid collisions. Worktrees remove the file-level
collision entirely. The harness's CPU, memory, and browser-process gates address a
different problem (host exhaustion) that the docs cited here do not cover.

## 7. Cloud sessions and pull request follow-up

**What the harness does.** `entrypoint.sh` is a Cloud Run job: it clones the repo with a
PAT, runs Claude, commits with trailers, pushes, tags, creates a PR with `gh`, and
uploads logs to GCS. `board-worker.sh` optionally merges and smoke-tests staging.

**What Claude Code offers.** "A cloud session is a Claude Code session that runs on
cloud infrastructure instead of on your machine." It "counts toward your plan's usage
limits alongside the rest of your Claude and Claude Code usage, and there's no separate
charge for the cloud VM." [11] Start one with `claude --cloud "task"`; "The task runs in
the cloud while you continue working locally." [11] In Anthropic-hosted environments
"git credentials and signing keys stay outside the sandbox, and a proxy authenticates on
the session's behalf with scoped credentials." [11] Auto-fix lets Claude watch a PR:
"when a check fails or a reviewer leaves a comment, Claude investigates and pushes a fix
if one is clear." It requires the Claude GitHub App. [11]

The GitHub Action is the CI-hosted alternative: "Mention `@claude` in a pull request or
issue comment to have Claude analyze code, implement changes, and push commits. You can
also give the Claude Code GitHub Action a prompt to run automatically on any GitHub
event." [9] It authenticates with an API key or with `CLAUDE_CODE_OAUTH_TOKEN`, "an
OAuth token that authenticates with your Claude subscription," generated by
`claude setup-token`. [9]

**Difference.** The harness stores a GitHub PAT and an API key as job environment
variables; cloud sessions keep credentials off the VM. The harness's PR body, labels,
tags, and issue comments are custom; cloud sessions and the Action produce their own.
The harness's post-merge staging smoke test and board-column updates are outside what
the cited pages describe.

## 8. Cost and telemetry

**What the harness does.** `entrypoint.sh` greps a dollar amount out of Claude's text
output for a cost estimate; `telemetry-collect.sh` and `telemetry-report.sh` summarise
per-task timing and outcomes from logs.

**What Claude Code offers.** With `--output-format json`, "the response payload
includes `total_cost_usd` and a per-model cost breakdown, so scripted callers can track
spend without consulting the usage dashboard." Both figures "are client-side estimates
and can differ from your actual bill." [1] `/usage` shows session totals, and for
subscribers "usage [is] included in their subscription, so the session cost figure isn't
relevant for billing purposes." [12] `--max-budget-usd` caps a print-mode run. [2]
OpenTelemetry export "is the only option that streams per-user token and cost metrics
into your own observability stack in near real time." [12]

**Difference.** The regex in `entrypoint.sh` is fragile and the local runner records no
cost at all. Switching the invocation to `--output-format json` and reading
`total_cost_usd` and `session_id` with `jq` would give the telemetry scripts reliable
input. On a Max subscription the dollar figure is informational only. [12]

## 9. Model selection

**What the harness does.** Each queue task names a model; the default is
`claude-opus-5-5`, overridable with `LOCAL_CODER_DEFAULT_MODEL`.

**What Claude Code offers.** `--model` "Sets the model for the current session with a
model alias such as `sonnet`, `opus`, `haiku`, or `fable`, or a model's full name." [2]
On the Anthropic API the `opus`, `sonnet`, and `haiku` aliases resolve to Opus 5.5,
Sonnet 5.5, and Haiku 5.5; "To pin to a specific version, use the full model name, for
example `claude-opus-5-5`." [13] For Pro, Max, Ultra, Team, Enterprise, and API
accounts the default model is Opus 5.5. [13] Effort levels (`low` through `max`) can be
set with `--effort` or `CLAUDE_CODE_EFFORT_LEVEL`. [13]

**Difference.** Pinning a full name in the queue keeps overnight runs reproducible;
an alias would silently move to the next release. The harness exposes no effort
setting; adding `--effort` to the invocation is a one-line change if cheaper runs are
wanted.

## What this means for the harness

- Keep: the queue format, the resource gates, the board worker, the static audit
  scanner, and the telemetry scripts. Nothing in the cited pages replaces them.
- Consider adopting: `--output-format json` for cost and session IDs [1]; a
  `PreToolUse` hook for the secrets rule [6]; `--max-turns` and `--max-budget-usd` on
  the local runner [2]; the Bash sandbox or deny rules alongside bypass mode [3][4];
  worktrees for parallel workers [10].
- Consider replacing: the Cloud Run job with cloud sessions or cloud scheduled tasks
  when local state is not needed [8][11]; the `nohup` loop with a cloud scheduled task
  for runs that must survive the laptop sleeping [7][8].

## Sources

All accessed 2026-11-03.

1. Run Claude Code programmatically (headless). https://code.claude.com/docs/en/headless
2. CLI reference. https://code.claude.com/docs/en/cli-reference
3. Choose a permission mode. https://code.claude.com/docs/en/permission-modes
4. Configure the sandboxed Bash tool. https://code.claude.com/docs/en/sandboxing
5. How Claude remembers your project. https://code.claude.com/docs/en/memory
6. Automate actions with hooks. https://code.claude.com/docs/en/hooks-guide
7. Run prompts on a schedule. https://code.claude.com/docs/en/scheduled-tasks
8. Automate work with scheduled tasks (formerly routines). https://code.claude.com/docs/en/routines
9. Claude Code GitHub Actions. https://code.claude.com/docs/en/github-actions
10. Run agents in parallel. https://code.claude.com/docs/en/agents
11. Use Claude Code in the cloud. https://code.claude.com/docs/en/claude-code-on-the-web
12. Manage costs effectively. https://code.claude.com/docs/en/costs
13. Model configuration. https://code.claude.com/docs/en/model-config

Harness files referenced: `scripts/run-local-overnight.sh`, `scripts/entrypoint.sh`,
`scripts/board-worker.sh`, `scripts/launch-overnight.sh`, `scripts/parallel-loop.sh`,
`scripts/telemetry-collect.sh`, `docs/CLAUDE.md`, `docs/OVERNIGHT-RUNNERS.md`.
