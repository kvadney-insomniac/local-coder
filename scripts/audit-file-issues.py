#!/usr/bin/env python3
"""audit-file-issues.py — Turn an audit-scan findings JSON into GitHub issues.

Reads a findings JSON written by audit-scan.sh, dedupes against existing
audit-labeled issues by an embedded fingerprint trailer, and creates new issues
on the appropriate repo with `gh issue create`. Newly created issues are added
to the org project board (#10) so they land in Backlog like any other ticket.

Invariants:
  - Never reopens a closed audit issue automatically (closed = "won't fix").
  - Caps issues filed per run via --max-new (default 10).
  - Severity * recency drives ordering; ties broken by file path.
  - Dry-run by default — pass --apply to actually create issues.

The fingerprint lives in the body as:  <!-- audit-fingerprint: <sha256> -->
That trailer is the source of truth for dedup; titles can drift freely.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Iterable

# Repo slugs match the local-coder board-lib repo names.
REPO_SLUGS = {
    "backend": "YourProject-Hedge-Fund-Guy/backend",
    "frontend": "YourProject-Hedge-Fund-Guy/frontend",
}

PROJECT_OWNER = "YourProject-Hedge-Fund-Guy"
PROJECT_NUMBER = 10

AUDIT_LABEL = "audit"
CATEGORY_LABELS = {
    "dead-code":  "audit:dead-code",
    "incomplete": "audit:incomplete",
    "quality":    "audit:quality",
    "stub":       "audit:stub",
}

FINGERPRINT_TRAILER_RE = re.compile(r"<!--\s*audit-fingerprint:\s*([0-9a-f]{64})\s*-->")


# --------------------------------------------------------------------------
# gh helpers — thin wrappers, log on failure but never raise unless --apply.
# --------------------------------------------------------------------------
def gh(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=check)


def existing_fingerprints(repo_slug: str) -> set[str]:
    """Return fingerprints from every audit-labeled issue (open or closed)."""
    fps: set[str] = set()
    # Search all states — a closed "won't fix" still counts so we don't refile it.
    cp = gh([
        "issue", "list", "-R", repo_slug,
        "--label", AUDIT_LABEL,
        "--state", "all",
        "--limit", "1000",
        "--json", "number,body",
    ], check=False)
    if cp.returncode != 0:
        print(f"[file-issues] gh issue list failed for {repo_slug}: {cp.stderr.strip()}",
              file=sys.stderr)
        return fps
    try:
        items = json.loads(cp.stdout or "[]")
    except json.JSONDecodeError:
        return fps
    for item in items:
        body = item.get("body") or ""
        m = FINGERPRINT_TRAILER_RE.search(body)
        if m:
            fps.add(m.group(1))
    return fps


def ensure_labels(repo_slug: str, labels: Iterable[str]) -> None:
    """Create any missing labels. Cheap and idempotent."""
    for label in set(labels):
        gh([
            "label", "create", label,
            "-R", repo_slug,
            "--color", "ededed",
            "--description", "Auto-filed by continuous-audit",
            "--force",
        ], check=False)


# --------------------------------------------------------------------------
# Issue assembly
# --------------------------------------------------------------------------
def title_for(finding: dict) -> str:
    cat = finding.get("category", "issue")
    rule = finding.get("rule", "")
    file = finding.get("file", "?")
    short_ev = (finding.get("evidence") or "").strip().splitlines()[0][:80]
    base = f"[audit:{cat}] {file}"
    if rule:
        base += f" ({rule})"
    if short_ev:
        base += f" — {short_ev}"
    return base[:240]


def body_for(finding: dict) -> str:
    return (
        f"**Category:** `{finding.get('category')}`\n"
        f"**Tool:** `{finding.get('tool')}`\n"
        f"**Rule:** `{finding.get('rule')}`\n"
        f"**Severity:** {finding.get('severity')}/5\n"
        f"**File:** `{finding.get('file')}`"
        + (f" : {finding['line']}" if finding.get("line") else "")
        + "\n\n"
        "**Evidence:**\n"
        f"```\n{(finding.get('evidence') or '').strip()}\n```\n\n"
        "_Auto-filed by `scripts/continuous-audit-loop.sh`. "
        "Close with `wontfix` to suppress permanently — the fingerprint trailer "
        "keeps it from being re-filed._\n\n"
        f"<!-- audit-fingerprint: {finding['fingerprint']} -->\n"
    )


def rank_key(finding: dict) -> tuple:
    # Higher severity first; then F-series ruff codes (real bugs) before others;
    # then by file path so output is deterministic.
    rule = finding.get("rule", "")
    bug_bonus = 1 if rule.startswith("F") else 0
    return (-int(finding.get("severity", 0)), -bug_bonus, finding.get("file", ""))


# --------------------------------------------------------------------------
# Issue creation
# --------------------------------------------------------------------------
def create_issue(repo_slug: str, finding: dict, apply: bool) -> str | None:
    title = title_for(finding)
    body = body_for(finding)
    labels = [AUDIT_LABEL, CATEGORY_LABELS.get(finding["category"], "audit")]

    if not apply:
        print(f"[file-issues] DRY-RUN would create: {repo_slug} :: {title}")
        return None

    ensure_labels(repo_slug, labels)
    cp = gh([
        "issue", "create",
        "-R", repo_slug,
        "--title", title,
        "--body", body,
        "--label", ",".join(labels),
    ], check=False)
    if cp.returncode != 0:
        print(f"[file-issues] gh issue create failed: {cp.stderr.strip()}", file=sys.stderr)
        return None
    # gh prints the issue URL on stdout.
    url = (cp.stdout or "").strip().splitlines()[-1] if cp.stdout else ""
    if url:
        # Best-effort: add to project board. Failure is non-fatal — the issue
        # itself exists and humans can drag it onto the board.
        add = gh([
            "project", "item-add",
            str(PROJECT_NUMBER),
            "--owner", PROJECT_OWNER,
            "--url", url,
        ], check=False)
        if add.returncode != 0:
            print(f"[file-issues] gh project item-add failed (non-fatal): "
                  f"{add.stderr.strip()}", file=sys.stderr)
    return url


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("findings_json", type=Path)
    ap.add_argument("--max-new", type=int, default=10,
                    help="Cap on new issues filed this run (default: 10).")
    ap.add_argument("--apply", action="store_true",
                    help="Actually create issues. Default is dry-run.")
    args = ap.parse_args()

    if not args.findings_json.exists():
        print(f"[file-issues] missing findings file: {args.findings_json}", file=sys.stderr)
        return 2

    findings = json.loads(args.findings_json.read_text())
    if not findings:
        print("[file-issues] no findings to file.")
        return 0

    # Group by repo, build dedup index per repo from existing issues.
    by_repo: dict[str, list[dict]] = {}
    for f in findings:
        repo = f.get("repo")
        if repo not in REPO_SLUGS:
            continue
        by_repo.setdefault(repo, []).append(f)

    created = 0
    cap = args.max_new
    summary = Counter()

    for repo, items in by_repo.items():
        slug = REPO_SLUGS[repo]
        seen = existing_fingerprints(slug)
        items.sort(key=rank_key)
        for f in items:
            if created >= cap:
                break
            if f["fingerprint"] in seen:
                summary[f"{repo}:dup"] += 1
                continue
            url = create_issue(slug, f, args.apply)
            seen.add(f["fingerprint"])  # avoid double-counting inside this run
            created += 1                # dry-run counts too, so cap is honored
            if args.apply and url:
                summary[f"{repo}:new"] += 1
            elif not args.apply:
                summary[f"{repo}:would-create"] += 1
        if created >= cap:
            break

    print(f"[file-issues] summary: {dict(summary)} (cap={cap}, apply={args.apply})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
