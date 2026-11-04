#!/usr/bin/env bash
# run-tests.sh: discover and run tests/unit/*.test.sh.
#
# Each test file defines functions named test_*. Every function runs in its own
# subshell with `set -e`, so a failing command or assertion fails just that test.
#
# Usage:
#   bash tests/run-tests.sh            # run everything
#   bash tests/run-tests.sh runner     # run only files whose name contains "runner"

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"
PASS=0
FAIL=0
FAILED_NAMES=()

for file in "${TESTS_DIR}"/unit/*.test.sh; do
    [[ -n "$FILTER" && "$(basename "$file")" != *"$FILTER"* ]] && continue
    echo "== $(basename "$file")"
    mapfile -t names < <(grep -oE '^test_[A-Za-z0-9_]+' "$file")
    for name in "${names[@]}"; do
        if (
            set -e
            # shellcheck source=tests/lib.sh
            source "${TESTS_DIR}/lib.sh"
            # shellcheck disable=SC1090
            source "$file"
            "$name"
            [[ "${_ASSERT_FAILURES}" -eq 0 ]]
        ) >"${TMPDIR:-/tmp}/local-coder-test-$$.out" 2>&1; then
            echo "  PASS $name"
            PASS=$((PASS + 1))
        else
            echo "  FAIL $name"
            sed 's/^/      /' "${TMPDIR:-/tmp}/local-coder-test-$$.out"
            FAIL=$((FAIL + 1))
            FAILED_NAMES+=("$(basename "$file"):$name")
        fi
    done
done
rm -f "${TMPDIR:-/tmp}/local-coder-test-$$.out"

echo
echo "unit tests: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
    printf '  %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
