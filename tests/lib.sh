#!/usr/bin/env bash
# lib.sh: tiny assertion helpers shared by the unit and smoke tests.
# Source this file; do not run it. Zero dependencies beyond bash and coreutils.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_CODER_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
export TESTS_DIR LOCAL_CODER_ROOT

_ASSERT_FAILURES=0

_fail() {
    echo "    ASSERT FAILED: $*" >&2
    _ASSERT_FAILURES=$((_ASSERT_FAILURES + 1))
    return 1
}

assert_eq() {            # assert_eq <expected> <actual> [message]
    [[ "$1" == "$2" ]] || _fail "${3:-values differ}: expected '$1', got '$2'"
}

assert_contains() {      # assert_contains <haystack> <needle> [message]
    [[ "$1" == *"$2"* ]] || _fail "${3:-text missing}: expected to find '$2'"
}

assert_not_contains() {  # assert_not_contains <haystack> <needle> [message]
    [[ "$1" != *"$2"* ]] || _fail "${3:-text present}: did not expect '$2'"
}

assert_file_exists() {   # assert_file_exists <path>
    [[ -e "$1" ]] || _fail "file missing: $1"
}

assert_file_missing() {  # assert_file_missing <path>
    [[ ! -e "$1" ]] || _fail "file should not exist: $1"
}

assert_exit() {          # assert_exit <expected_code> <actual_code> [message]
    [[ "$1" -eq "$2" ]] || _fail "${3:-exit code}: expected $1, got $2"
}

# make_tmp_dir: a fresh directory under the test scratch root, auto-removed on exit.
_TMP_ROOT="${TMPDIR:-/tmp}/local-coder-tests-$$"
mkdir -p "${_TMP_ROOT}"
trap 'rm -rf "${_TMP_ROOT}"' EXIT
make_tmp_dir() {
    mktemp -d "${_TMP_ROOT}/XXXXXX"
}

# make_git_repo <dir>: initialise a throwaway git repo with one commit.
make_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "tests@example.com"
    git -C "$dir" config user.name "local-coder tests"
    git -C "$dir" config commit.gpgsign false
    echo "# target repo" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
}

# run_runner <args...>: run the queue runner with test-friendly env, capture
# stdout+stderr into $RUN_OUT and the exit code into $RUN_RC. Never aborts.
run_runner() {
    set +e
    RUN_OUT=$(bash "${LOCAL_CODER_ROOT}/scripts/run-local-overnight.sh" "$@" 2>&1)
    RUN_RC=$?
    set -e
    export RUN_OUT RUN_RC
}
