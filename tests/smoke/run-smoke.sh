#!/usr/bin/env bash
# run-smoke.sh: run one tiny queue end to end through run-local-overnight.sh
# with a fake claude CLI, then check every side effect the real loop relies on.
#
# What it proves:
#   1. the runner parses a queue, builds the prompt, and invokes `claude` with
#      the expected flags from inside the target repo
#   2. a successful task lands in the completed file and the per-task log
#   3. a second run skips the completed task (idempotent re-runs)
#   4. a failing task is reported, exits non-zero, and is NOT marked completed
#
# No network, no model, no subscription. Runs in about five seconds.

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SMOKE_DIR}/../lib.sh"

export PATH="${TESTS_DIR}/fake-bin:${PATH}"
export LOCAL_CODER_SKIP_RESOURCE_GATES=1

WORK="$(make_tmp_dir)"
export REPO_ROOT="${WORK}/target-repo"
export LOCAL_CODER_LOGS_DIR="${WORK}/logs"
export FAKE_CLAUDE_LOG_DIR="${WORK}/fake-claude"
export QUEUE="${SMOKE_DIR}/smoke-queue.yaml"
make_git_repo "${REPO_ROOT}"

echo "== smoke: fake claude is $(command -v claude)"
claude --version | grep -q fake || { echo "real claude on PATH ahead of the fake"; exit 1; }

# ---------------------------------------------------------------- run 1: success
echo "== smoke: run 1 (expect success)"
run_runner
echo "${RUN_OUT}" | sed 's/^/   | /'
assert_exit 0 "${RUN_RC}" "runner exit code"
assert_not_contains "${RUN_OUT}" "syntax error" "runner must not emit bash errors"
assert_not_contains "${RUN_OUT}" "command not found" "runner must not call missing tools"
assert_contains "${RUN_OUT}" "smoke-write-marker completed" "success line"
assert_contains "${RUN_OUT}" "1 queued  |  1 succeeded  |  0 failed" "summary"

COMPLETED="${LOCAL_CODER_LOGS_DIR}/smoke-queue.completed.txt"
assert_file_exists "${COMPLETED}"
assert_eq "smoke-write-marker" "$(cat "${COMPLETED}")" "completed file content"

TASK_LOG="${LOCAL_CODER_LOGS_DIR}/smoke-write-marker.log"
assert_file_exists "${TASK_LOG}"
assert_contains "$(cat "${TASK_LOG}")" "fake claude: committed SMOKE.txt" "task log captured claude output"

assert_file_exists "${REPO_ROOT}/SMOKE.txt"
assert_eq "2" "$(git -C "${REPO_ROOT}" rev-list --count HEAD)" "one new commit in target repo"
assert_contains "$(git -C "${REPO_ROOT}" log -1 --format=%s)" "[local-coder] smoke" "commit subject"

INVOCATION="$(cat "${FAKE_CLAUDE_LOG_DIR}"/invocation-*.env)"
assert_contains "${INVOCATION}" "cwd=${REPO_ROOT}" "claude ran inside REPO_ROOT"
assert_contains "${INVOCATION}" "model=claude-opus-5-5" "model passed through from queue"
assert_contains "${INVOCATION}" "skip_permissions=true" "runner passes --dangerously-skip-permissions"

PROMPT="$(cat "${FAKE_CLAUDE_LOG_DIR}"/prompt-*.txt)"
assert_contains "${PROMPT}" "IMPORTANT RULES FOR THIS TASK" "preamble prepended"
assert_contains "${PROMPT}" "create a file named SMOKE.txt" "task prompt delivered"

# Prompt temp files must not leak.
if ls "${TMPDIR:-/tmp}"/claude-prompt-smoke-write-marker-*.txt >/dev/null 2>&1; then
    _fail "prompt temp file left behind in ${TMPDIR:-/tmp}"
fi

# ---------------------------------------------------------------- run 2: idempotent
echo "== smoke: run 2 (expect the completed task to be skipped)"
run_runner
assert_exit 0 "${RUN_RC}" "runner exit code on re-run"
assert_contains "${RUN_OUT}" "0 queued  |  0 succeeded  |  0 failed" "nothing re-run"
assert_eq "1" "$(find "${FAKE_CLAUDE_LOG_DIR}" -name 'invocation-*' | wc -l | tr -d ' ')" "claude not invoked again"

# ---------------------------------------------------------------- run 3: failure
echo "== smoke: run 3 (expect a reported failure, not marked completed)"
: > "${COMPLETED}"
export FAKE_CLAUDE_ACTION=fail
run_runner
assert_exit 1 "${RUN_RC}" "runner exits 1 when a task fails"
assert_contains "${RUN_OUT}" "smoke-write-marker FAILED (exit 1)" "failure line"
assert_contains "${RUN_OUT}" "1 queued  |  0 succeeded  |  1 failed" "failure summary"
assert_eq "" "$(cat "${COMPLETED}")" "failed task not recorded as completed"
assert_contains "$(cat "${TASK_LOG}")" "simulated failure" "stderr captured in task log"

echo
if [[ "${_ASSERT_FAILURES}" -gt 0 ]]; then
    echo "SMOKE TEST FAILED: ${_ASSERT_FAILURES} assertion(s)"
    exit 1
fi
echo "SMOKE TEST PASSED"
