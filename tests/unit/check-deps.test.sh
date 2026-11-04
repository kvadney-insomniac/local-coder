#!/usr/bin/env bash
# Unit tests for scripts/check-deps.sh.

test_passes_on_this_machine_without_claude() {
    local out rc=0
    out=$(bash "${LOCAL_CODER_ROOT}/scripts/check-deps.sh" --no-claude 2>&1) || rc=$?
    echo "${out}"
    assert_exit 0 "${rc}"
    assert_contains "${out}" "[ok]      PyYAML"
    assert_contains "${out}" "[skip]    claude"
}

test_accepts_fake_claude() {
    local out rc=0
    out=$(PATH="${TESTS_DIR}/fake-bin:${PATH}" bash "${LOCAL_CODER_ROOT}/scripts/check-deps.sh" 2>&1) || rc=$?
    echo "${out}"
    # The fake CLI has no --help, so the flag probes report missing flags: that
    # is the intended signal when a CLI stops advertising a flag.
    assert_exit 1 "${rc}"
    assert_contains "${out}" "[ok]      claude     0.0.0-fake"
    assert_contains "${out}" "no longer advertises --print"
}

test_reports_missing_tool() {
    local work out rc=0
    work="$(make_tmp_dir)"
    # Build a PATH with everything except jq.
    mkdir -p "${work}/bin"
    for tool in bash git gh python3 timeout sort head awk sed grep cat tr; do
        p=$(command -v "$tool") && ln -s "$p" "${work}/bin/$tool"
    done
    out=$(PATH="${work}/bin" bash "${LOCAL_CODER_ROOT}/scripts/check-deps.sh" --no-claude 2>&1) || rc=$?
    echo "${out}"
    assert_exit 1 "${rc}"
    assert_contains "${out}" "[MISSING] jq"
}

test_help() {
    local out
    out=$(bash "${LOCAL_CODER_ROOT}/scripts/check-deps.sh" --help)
    assert_contains "${out}" "--no-claude"
}
