#!/usr/bin/env bash
# Unit tests for scripts/run-local-overnight.sh modes that never call claude.
# Sourced by tests/run-tests.sh; every test_* function runs in its own subshell.

_setup() {
    WORK="$(make_tmp_dir)"
    export REPO_ROOT="${WORK}/repo"
    export LOCAL_CODER_LOGS_DIR="${WORK}/logs"
    export LOCAL_CODER_SKIP_RESOURCE_GATES=1
    export QUEUE="${LOCAL_CODER_ROOT}/queues/example.yaml"
    mkdir -p "${REPO_ROOT}"
}

test_help_exits_zero() {
    _setup
    run_runner --help
    assert_exit 0 "${RUN_RC}"
    assert_contains "${RUN_OUT}" "--dry-run"
}

test_unknown_option_exits_one() {
    _setup
    run_runner --bogus
    assert_exit 1 "${RUN_RC}"
    assert_contains "${RUN_OUT}" "Unknown option"
}

test_requires_repo_root() {
    _setup
    unset REPO_ROOT
    run_runner --list
    assert_exit 1 "${RUN_RC}"
    assert_contains "${RUN_OUT}" "REPO_ROOT must be set"
}

test_list_shows_tasks_sorted_by_priority() {
    _setup
    run_runner --list
    assert_exit 0 "${RUN_RC}"
    assert_contains "${RUN_OUT}" "[P2] example-dead-import"
    assert_contains "${RUN_OUT}" "[P2] example-add-test"
    assert_contains "${RUN_OUT}" "[P3] example-readme-typo"
    # P2 rows must precede the P3 row
    local p2_line p3_line
    p2_line=$(grep -n '\[P2\] example-dead-import' <<<"${RUN_OUT}" | cut -d: -f1)
    p3_line=$(grep -n '\[P3\] example-readme-typo' <<<"${RUN_OUT}" | cut -d: -f1)
    [[ "${p2_line}" -lt "${p3_line}" ]] || _fail "P2 task listed after P3 task"
}

test_list_passes_model_through() {
    _setup
    run_runner --list
    assert_contains "${RUN_OUT}" "model=claude-opus-5-5"
}

test_priority_filter() {
    _setup
    run_runner --list --priority P3
    assert_contains "${RUN_OUT}" "example-readme-typo"
    assert_not_contains "${RUN_OUT}" "example-dead-import"
    assert_not_contains "${RUN_OUT}" "example-add-test"
}

test_skip_argument() {
    _setup
    run_runner --list --skip example-dead-import,example-add-test
    assert_contains "${RUN_OUT}" "example-readme-typo"
    assert_not_contains "${RUN_OUT}" "[P2] example-dead-import"
    assert_not_contains "${RUN_OUT}" "[P2] example-add-test"
}

test_completed_file_skips_tasks() {
    _setup
    mkdir -p "${LOCAL_CODER_LOGS_DIR}"
    echo "example-readme-typo" > "${LOCAL_CODER_LOGS_DIR}/example.completed.txt"
    run_runner --list
    assert_not_contains "${RUN_OUT}" "[P3] example-readme-typo"
    assert_contains "${RUN_OUT}" "[P2] example-dead-import"
    assert_contains "${RUN_OUT}" "Completed (from ${LOCAL_CODER_LOGS_DIR}/example.completed.txt)"
}

test_dry_run_invokes_nothing_and_records_nothing() {
    _setup
    export PATH="${TESTS_DIR}/fake-bin:${PATH}"
    export FAKE_CLAUDE_LOG_DIR="${WORK}/fake-claude"
    run_runner --dry-run
    assert_exit 0 "${RUN_RC}"
    assert_contains "${RUN_OUT}" "*** DRY RUN ***"
    assert_contains "${RUN_OUT}" "[DRY RUN] Would run:"
    assert_contains "${RUN_OUT}" "claude --dangerously-skip-permissions -p '<prompt>' --model claude-opus-5-5"
    assert_contains "${RUN_OUT}" "3 queued  |  3 succeeded  |  0 failed"
    assert_file_missing "${WORK}/fake-claude"
    assert_eq "" "$(cat "${LOCAL_CODER_LOGS_DIR}/example.completed.txt")" "dry run must not mark tasks completed"
}

test_default_model_fills_missing_model_field() {
    _setup
    cat > "${WORK}/no-model.yaml" <<'EOF'
version: "1"
queue:
  - id: t1
    priority: P2
    category: test
    title: "no model field"
    target_repo: backend
    prompt: "do a thing"
EOF
    export LOCAL_CODER_DEFAULT_MODEL="sonnet"
    run_runner --list --queue "${WORK}/no-model.yaml"
    assert_exit 0 "${RUN_RC}"
    assert_contains "${RUN_OUT}" "model=sonnet"
}

test_queue_stem_names_completed_file() {
    _setup
    cp "${LOCAL_CODER_ROOT}/queues/example.yaml" "${WORK}/overnight-queue.yaml"
    run_runner --list --queue "${WORK}/overnight-queue.yaml"
    assert_contains "${RUN_OUT}" "Completed (from ${LOCAL_CODER_LOGS_DIR}/completed.txt)"
    assert_file_exists "${LOCAL_CODER_LOGS_DIR}/completed.txt"
}

test_resource_gates_return_when_skipped() {
    _setup
    # Source only the helper definitions by running them through bash -c with
    # the script's functions extracted; simplest is to call the script's
    # helpers in a subshell after defining the env they read.
    local out
    out=$(bash -c '
        SKIP_RESOURCE_GATES=1
        source <(sed -n "/^_cpu_cores()/,/^_wait_for_memory_headroom()/p" "'"${LOCAL_CODER_ROOT}"'/scripts/run-local-overnight.sh" | sed "\$d")
        _wait_for_cpu_headroom && echo cpu-ok
        cores=$(_cpu_cores); [[ "$cores" -ge 1 ]] && echo cores-ok
        read -r avail total comp < <(_memory_stats_mb)
        [[ "$avail" -ge 0 && "$total" -ge 0 && "$comp" -ge 0 ]] && echo mem-ok
    ')
    assert_contains "${out}" "cpu-ok"
    assert_contains "${out}" "cores-ok"
    assert_contains "${out}" "mem-ok"
}
