#!/usr/bin/env python3
"""Fail if any tracked text file contains an em dash or an en dash.

Usage: check-dashes.py [paths...]   (default: every file in `git ls-files`)
Exit 1 and list file:line for each hit; exit 0 and print a short OK otherwise.
"""
import subprocess
import sys
from pathlib import Path

BAD = {chr(0x2014): "em dash", chr(0x2013): "en dash"}
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".ico", ".woff", ".woff2", ".lock"}


def tracked_files():
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
    return [Path(p) for p in out.splitlines()]


def main(argv):
    paths = [Path(a) for a in argv] or tracked_files()
    hits = []
    for path in paths:
        if path.suffix.lower() in BINARY_SUFFIXES or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            for ch, label in BAD.items():
                if ch in line:
                    hits.append(f"{path}:{n}: {label}")
    if hits:
        print("\n".join(hits))
        return 1
    print("no em dash or en dash in tracked files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
