#!/usr/bin/env bash
# Unit tests for the fake claude CLI used by the smoke test. If the real CLI's
# flag surface changes, update tests/fake-bin/claude and these tests together.

_setup() {
    WORK="$(make_tmp_dir)"
    export FAKE_CLAUDE_LOG_DIR="${WORK}/log"
    export PATH="${TESTS_DIR}/fake-bin:${PATH}"
    make_git_repo "${WORK}/repo"
    cd "${WORK}/repo" || return 1
}

test_version_flag() {
    _setup
    local out
    out=$(claude --version)
    assert_contains "${out}" "fake"
}

test_records_flags_and_prompt() {
    _setup
    FAKE_CLAUDE_ACTION=noop claude --dangerously-skip-permissions -p "hello there" --model opus --max-turns 7 >/dev/null
    local env prompt
    env=$(cat "${FAKE_CLAUDE_LOG_DIR}"/invocation-*.env)
    prompt=$(cat "${FAKE_CLAUDE_LOG_DIR}"/prompt-*.txt)
    assert_contains "${env}" "model=opus"
    assert_contains "${env}" "max_turns=7"
    assert_contains "${env}" "skip_permissions=true"
    assert_eq "hello there" "${prompt}"
}

test_reads_prompt_from_stdin() {
    _setup
    echo "piped prompt" | FAKE_CLAUDE_ACTION=noop claude -p >/dev/null
    assert_eq "piped prompt" "$(cat "${FAKE_CLAUDE_LOG_DIR}"/prompt-*.txt | tr -d '\n')"
}

test_edit_and_commit_creates_commit() {
    _setup
    claude -p "x" --model m >/dev/null
    assert_file_exists "SMOKE.txt"
    assert_eq "2" "$(git rev-list --count HEAD)"
}

test_edit_only_leaves_tree_dirty() {
    _setup
    FAKE_CLAUDE_ACTION=edit-only claude -p "x" >/dev/null
    assert_file_exists "SMOKE.txt"
    assert_eq "1" "$(git rev-list --count HEAD)"
    assert_contains "$(git status --porcelain)" "?? SMOKE.txt"
}

test_fail_action_exits_one() {
    _setup
    local rc=0
    FAKE_CLAUDE_ACTION=fail claude -p "x" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "${rc}"
}

test_json_output_format() {
    _setup
    local out
    out=$(FAKE_CLAUDE_ACTION=noop claude -p "x" --output-format json | tail -1)
    echo "${out}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["type"]=="result"'
}

test_unknown_flag_exits_two() {
    _setup
    local rc=0
    claude --definitely-not-a-flag >/dev/null 2>&1 || rc=$?
    assert_exit 2 "${rc}"
}
