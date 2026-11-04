#!/usr/bin/env bash
# check-deps.sh: verify every tool the harness calls is installed and current enough.
#
# Usage:
#   bash scripts/check-deps.sh              # check everything, including the claude CLI
#   bash scripts/check-deps.sh --no-claude  # skip the claude CLI (CI with a fake model)
#
# Exit codes:
#   0  all required tools present
#   1  one or more required tools missing or too old
#
# Sources for the minimum versions:
#   bash 4+     : associative arrays and ${var@Q} used in scripts/
#   python 3.9+ : f-strings and dict ordering relied on in the YAML parsers
#   PyYAML 6+   : yaml.safe_load as used in run-local-overnight.sh
#   git 2.31+   : the version the Claude Code docs require for cloud uploads;
#                 https://code.claude.com/docs/en/claude-code-on-the-web
#   gh 2.x      : used for issues, PRs, labels, and project boards
#   jq 1.6+     : used by audit-scan.sh and telemetry scripts
#   timeout     : GNU coreutils; macOS users need `brew install coreutils`

set -uo pipefail

CHECK_CLAUDE="true"
for arg in "$@"; do
    case "$arg" in
        --no-claude) CHECK_CLAUDE="false" ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

MISSING=0
ok()   { printf '  [ok]      %-10s %s\n' "$1" "$2"; }
bad()  { printf '  [MISSING] %-10s %s\n' "$1" "$2"; MISSING=$((MISSING + 1)); }

# version_ge "have" "want": true when have >= want (dotted numeric compare)
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

echo "local-coder dependency check"

# bash
if version_ge "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" "4.0"; then
    ok bash "${BASH_VERSION}"
else
    bad bash "need 4.0 or newer, have ${BASH_VERSION}"
fi

# git
if command -v git >/dev/null 2>&1; then
    v=$(git --version | awk '{print $3}')
    if version_ge "$v" "2.31"; then ok git "$v"; else bad git "need 2.31 or newer, have $v"; fi
else
    bad git "not on PATH"
fi

# jq
if command -v jq >/dev/null 2>&1; then
    v=$(jq --version 2>&1 | sed 's/^jq-//')
    if version_ge "$v" "1.6"; then ok jq "$v"; else bad jq "need 1.6 or newer, have $v"; fi
else
    bad jq "not on PATH"
fi

# gh
if command -v gh >/dev/null 2>&1; then
    v=$(gh --version 2>&1 | head -1 | awk '{print $3}')
    if version_ge "$v" "2.0"; then ok gh "$v"; else bad gh "need 2.0 or newer, have $v"; fi
else
    bad gh "not on PATH (https://cli.github.com)"
fi

# timeout (GNU coreutils)
if command -v timeout >/dev/null 2>&1; then
    ok timeout "$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1; then
    bad timeout "found gtimeout only; symlink it as timeout or add coreutils gnubin to PATH"
else
    bad timeout "not on PATH (macOS: brew install coreutils)"
fi

# python3 + PyYAML
if command -v python3 >/dev/null 2>&1; then
    v=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    if version_ge "$v" "3.9"; then ok python3 "$v"; else bad python3 "need 3.9 or newer, have $v"; fi
    if python3 -c 'import yaml' 2>/dev/null; then
        yv=$(python3 -c 'import yaml; print(yaml.__version__)')
        if version_ge "$yv" "6.0"; then ok PyYAML "$yv"; else bad PyYAML "need 6.0 or newer, have $yv"; fi
    else
        bad PyYAML "pip install -r requirements-dev.txt"
    fi
else
    bad python3 "not on PATH"
fi

# claude CLI
if [[ "$CHECK_CLAUDE" == "true" ]]; then
    if command -v claude >/dev/null 2>&1; then
        v=$(claude --version 2>&1 | head -1)
        ok claude "$v"
        # Flags the harness passes; fail loudly if the CLI drops one.
        help_text=$(claude --help 2>&1 || true)
        for flag in --print --model --max-turns --dangerously-skip-permissions; do
            if grep -q -- "$flag" <<<"$help_text"; then
                ok "claude" "accepts $flag"
            else
                bad "claude" "no longer advertises $flag; see https://code.claude.com/docs/en/cli-reference"
            fi
        done
    else
        bad claude "not on PATH (https://code.claude.com/docs/en/quickstart)"
    fi
else
    echo "  [skip]    claude     (--no-claude)"
fi

echo
if [[ $MISSING -gt 0 ]]; then
    echo "${MISSING} problem(s) found."
    exit 1
fi
echo "All dependencies present."
