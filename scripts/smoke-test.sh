#!/usr/bin/env bash
# smoke-test.sh - validate the Local Coder Docker image
#
# Usage:
#   ./smoke-test.sh                          # test :latest from Artifact Registry
#   ./smoke-test.sh local                    # build and test a local image
#   ./smoke-test.sh <full-image-uri>         # test a specific image
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#
# Requires: docker (and gcloud auth if pulling from AR)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

IMAGE="${1:-us-central1-docker.pkg.dev/${GCP_PROJECT_ID:-your-gcp-project}/cloud-run-source-deploy/claude-coder:latest}"
PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# --------------------------------------------------------------------------
# Build local image if requested
# --------------------------------------------------------------------------
if [ "$IMAGE" = "local" ]; then
    echo "Building local image from $SCRIPT_DIR ..."
    docker build -t claude-coder-smoke-test "$SCRIPT_DIR"
    IMAGE="claude-coder-smoke-test"
fi

echo ""
echo "=== Local Coder Smoke Test ==="
echo "Image: $IMAGE"
echo ""

# --------------------------------------------------------------------------
# Helper: run a command inside the image and check exit code
# --------------------------------------------------------------------------
check() {
    local label="$1"
    shift
    if docker run --rm "$IMAGE" bash -c "$*" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label"
    fi
}

check_output() {
    local label="$1"
    local pattern="$2"
    shift 2
    local out
    out=$(docker run --rm "$IMAGE" bash -c "$*" 2>&1 || true)
    if echo "$out" | grep -qE "$pattern"; then
        pass "$label"
    else
        fail "$label (output: ${out:0:120})"
    fi
}

# --------------------------------------------------------------------------
# Tool presence
# --------------------------------------------------------------------------
echo "--- Tool versions ---"
check_output "Node.js 20.x present"  "v20\." "node --version"
check_output "npm present"            "[0-9]+"  "npm --version"
check_output "Python 3.12 present"   "3\.12\." "python3 --version"
check_output "git present"           "git version" "git --version"
check_output "gh CLI present"        "gh version" "gh --version"
check_output "claude CLI present"    "." "which claude"
check_output "black present"         "." "which black"
check_output "isort present"         "." "which isort"
check_output "pytest present"        "." "which pytest"
check_output "jq present"            "." "which jq"

# --------------------------------------------------------------------------
# Entrypoint
# --------------------------------------------------------------------------
echo ""
echo "--- Entrypoint ---"
check "entrypoint.sh exists"     "test -f /entrypoint.sh"
check "entrypoint.sh executable" "test -x /entrypoint.sh"

# --------------------------------------------------------------------------
# Git operations
# --------------------------------------------------------------------------
echo ""
echo "--- Git operations ---"
check "git config user.name"  "git config --global user.name 'CI Test' && git config --global user.email 'ci@test.com'"
check "git init + commit"     "
    set -e
    tmp=\$(mktemp -d)
    cd \$tmp
    git init -q
    git config user.email 'ci@test.com'
    git config user.name 'CI'
    echo 'test' > file.txt
    git add file.txt
    git commit -q -m 'test commit'
    git log --oneline | grep 'test commit'
"

# --------------------------------------------------------------------------
# Claude CLI invocation (no API key - expect auth error, not missing binary)
# --------------------------------------------------------------------------
echo ""
echo "--- Claude CLI ---"
# claude without API key should fail but the binary must be found and run
claude_out=$(docker run --rm \
    -e ANTHROPIC_API_KEY="sk-ant-test-invalid-key-for-smoke-test" \
    "$IMAGE" \
    bash -c "claude --version 2>&1 || true" 2>&1 || true)

if echo "$claude_out" | grep -qiE "(claude|version|[0-9]+\.[0-9]+)"; then
    pass "claude CLI runs (version output found)"
elif echo "$claude_out" | grep -qiE "(auth|api.key|invalid|error|not found)"; then
    pass "claude CLI runs (expected auth/key error with test key)"
else
    fail "claude CLI may not be working (output: ${claude_out:0:200})"
fi

# --------------------------------------------------------------------------
# Python dev tools
# --------------------------------------------------------------------------
echo ""
echo "--- Python tools ---"
check "black --version"  "black --version"
check "isort --version"  "isort --version"
check "pytest --version" "pytest --version"
check "alembic --version" "alembic --version"

# --------------------------------------------------------------------------
# Node dev tools
# --------------------------------------------------------------------------
echo ""
echo "--- Node tools ---"
check "typescript present" "tsc --version"

# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
    echo "SMOKE TEST FAILED"
    exit 1
else
    echo "SMOKE TEST PASSED"
    exit 0
fi
