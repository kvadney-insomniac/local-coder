#!/usr/bin/env bash
# audit-scan.sh — Run static-analysis tools across backend + frontend and emit a
# unified findings JSON. No GitHub calls, no LLM calls. Pure deterministic scan.
#
# Output: $BOARD_LOGS_DIR/audit-findings-YYYYMMDD-HHMMSS.json
# Echoes the output path on stdout (last line) so callers can pipe it.
#
# Finding schema (one per array element):
#   {
#     "category":     "dead-code" | "incomplete" | "quality" | "stub",
#     "tool":         "vulture" | "ruff" | "ts-prune" | "eslint" | "grep-todo",
#     "repo":         "backend" | "frontend",
#     "file":         "<path relative to repo root>",
#     "line":         <int or null>,
#     "rule":         "<tool-specific rule code, e.g. F401, no-unused-vars>",
#     "severity":     1..5,   // 5 = highest
#     "evidence":     "<short snippet — used in dedup fingerprint>",
#     "fingerprint":  "<sha256 hex>"
#   }
#
# The fingerprint covers (category|repo|file|rule|normalized-evidence) so the same
# smell de-dupes even after line-number drift or title rewording.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=board-lib.sh
source "${SCRIPT_DIR}/board-lib.sh"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${BOARD_LOGS_DIR}/audit-findings-${TS}.json"
TMP="$(mktemp -d -t audit-scan-XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

echo "[audit-scan] start ${TS} → ${OUT}" >&2

# Make backend venv's tools (vulture, ruff) discoverable without activation.
if [[ -d "${BOARD_BACKEND_DIR}/.venv/bin" ]]; then
    export PATH="${BOARD_BACKEND_DIR}/.venv/bin:${PATH}"
fi

# --------------------------------------------------------------------------
# Tool availability — degrade gracefully if a tool isn't installed.
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# BACKEND scans
# --------------------------------------------------------------------------
backend_findings="${TMP}/backend.jsonl"
: > "${backend_findings}"

if [[ -d "${BOARD_BACKEND_DIR}/app" ]]; then
    cd "${BOARD_BACKEND_DIR}"

    # Dead code — vulture. Min confidence 80 keeps noise reasonable.
    if have vulture; then
        vulture app --min-confidence 80 2>/dev/null \
            | awk -F: 'NF>=3 {
                file=$1; line=$2;
                msg=$0; sub(/^[^:]+:[^:]+:[^:]*: /, "", msg);
                printf "%s\t%s\t%s\n", file, line, msg
              }' \
            | while IFS=$'\t' read -r f l msg; do
                jq -cn --arg file "$f" --arg line "$l" --arg ev "$msg" \
                    '{category:"dead-code", tool:"vulture", repo:"backend",
                      file:$file, line:($line|tonumber? // null),
                      rule:"vulture-80", severity:3, evidence:$ev}'
              done >> "${backend_findings}"
    else
        echo "[audit-scan] vulture not installed — skipping backend dead-code" >&2
    fi

    # Lint smells — ruff. Pick a curated rule set; JSON output is stable.
    if have ruff; then
        ruff check app --select F,B,SIM,RUF,PERF,PLW --output-format json 2>/dev/null \
            | jq -c --arg root "${BOARD_BACKEND_DIR}/" '.[] | {
                category:"quality", tool:"ruff", repo:"backend",
                file:(.filename | sub("^" + $root; "")),
                line:.location.row,
                rule:.code,
                severity:(if (.code|startswith("F")) then 4 else 3 end),
                evidence:.message
              }' >> "${backend_findings}" 2>/dev/null || true
    fi

    # Incomplete / stubs — TODO/FIXME/HACK/XXX + NotImplementedError. One row per match.
    grep -rEn --include='*.py' \
        '(TODO|FIXME|XXX|HACK)[: ]|raise NotImplementedError' app 2>/dev/null \
        | awk -F: '{
            file=$1; line=$2;
            $1=""; $2=""; sub(/^  /, ""); ev=$0;
            gsub(/"/, "\\\"", ev);
            printf "%s\t%s\t%s\n", file, line, ev
          }' \
        | while IFS=$'\t' read -r f l msg; do
            cat=$(echo "$msg" | grep -q NotImplementedError && echo "stub" || echo "incomplete")
            jq -cn --arg file "$f" --arg line "$l" --arg ev "$msg" --arg cat "$cat" \
                '{category:$cat, tool:"grep-todo", repo:"backend",
                  file:$file, line:($line|tonumber? // null),
                  rule:"todo-marker", severity:2, evidence:$ev}'
          done >> "${backend_findings}"
fi

# --------------------------------------------------------------------------
# FRONTEND scans
# --------------------------------------------------------------------------
frontend_findings="${TMP}/frontend.jsonl"
: > "${frontend_findings}"

if [[ -d "${BOARD_FRONTEND_DIR}/src" ]]; then
    cd "${BOARD_FRONTEND_DIR}"

    # Dead exports — ts-prune. Available via npx if installed in node_modules.
    if [[ -d node_modules ]] && npx --no-install ts-prune --version >/dev/null 2>&1; then
        npx --no-install ts-prune 2>/dev/null \
            | grep -v ' - used in module$' \
            | awk -F: 'NF>=2 {
                file=$1; line=$2; rest=$3;
                printf "%s\t%s\t%s\n", file, line, rest
              }' \
            | while IFS=$'\t' read -r f l rest; do
                jq -cn --arg file "$f" --arg line "$l" --arg ev "${rest:-unused export}" \
                    '{category:"dead-code", tool:"ts-prune", repo:"frontend",
                      file:$file, line:($line|tonumber? // null),
                      rule:"unused-export", severity:3, evidence:$ev}'
              done >> "${frontend_findings}"
    else
        echo "[audit-scan] ts-prune not installed (frontend) — skipping" >&2
    fi

    # ESLint — only if a config exists. Pick the JSON formatter; tolerate non-zero exit.
    if [[ -f .eslintrc.json || -f eslint.config.js || -f eslint.config.mjs ]]; then
        npx --no-install eslint src --format json --no-eslintrc=false \
            > "${TMP}/eslint.json" 2>/dev/null || true
        if [[ -s "${TMP}/eslint.json" ]]; then
            jq -c '
                .[] as $f | $f.messages[]
                | select(.severity >= 1)
                | {
                    category:"quality", tool:"eslint", repo:"frontend",
                    file:($f.filePath | sub("^.*/frontend/"; "")),
                    line:.line,
                    rule:(.ruleId // "eslint-unknown"),
                    severity:(if .severity==2 then 4 else 2 end),
                    evidence:.message
                  }' "${TMP}/eslint.json" >> "${frontend_findings}" 2>/dev/null || true
        fi
    fi

    # TODO/FIXME markers in TS/TSX
    grep -rEn --include='*.ts' --include='*.tsx' \
        '(TODO|FIXME|XXX|HACK)[: ]' src 2>/dev/null \
        | awk -F: '{
            file=$1; line=$2;
            $1=""; $2=""; sub(/^  /, ""); ev=$0;
            printf "%s\t%s\t%s\n", file, line, ev
          }' \
        | while IFS=$'\t' read -r f l msg; do
            jq -cn --arg file "$f" --arg line "$l" --arg ev "$msg" \
                '{category:"incomplete", tool:"grep-todo", repo:"frontend",
                  file:$file, line:($line|tonumber? // null),
                  rule:"todo-marker", severity:2, evidence:$ev}'
          done >> "${frontend_findings}"
fi

# --------------------------------------------------------------------------
# Combine + fingerprint + write final JSON array.
# --------------------------------------------------------------------------
#
# Fingerprint is a sha256 over `category|repo|file|rule|normalized-evidence`.
# Normalization strips line-number-ish digits and surrounding whitespace so the
# same smell hashes the same even if the file moved or got reformatted.
python3 - "$backend_findings" "$frontend_findings" "$OUT" <<'PY'
import hashlib, json, re, sys
from pathlib import Path

inputs, out_path = sys.argv[1:-1], sys.argv[-1]
findings = []
for p in inputs:
    p = Path(p)
    if not p.exists():
        continue
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            findings.append(json.loads(line))
        except json.JSONDecodeError:
            continue

def normalize(ev: str) -> str:
    ev = re.sub(r"\b\d+\b", "N", ev or "")
    ev = re.sub(r"\s+", " ", ev).strip().lower()
    return ev[:200]

for f in findings:
    key = "|".join([
        f.get("category", ""),
        f.get("repo", ""),
        f.get("file", ""),
        f.get("rule", ""),
        normalize(f.get("evidence", "")),
    ])
    f["fingerprint"] = hashlib.sha256(key.encode()).hexdigest()

# De-dup within this scan by fingerprint (keeps highest severity).
seen = {}
for f in findings:
    fp = f["fingerprint"]
    if fp not in seen or f.get("severity", 0) > seen[fp].get("severity", 0):
        seen[fp] = f

Path(out_path).write_text(json.dumps(list(seen.values()), indent=2))
print(f"[audit-scan] wrote {len(seen)} unique findings → {out_path}", file=sys.stderr)
PY

echo "${OUT}"
