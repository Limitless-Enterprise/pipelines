#!/usr/bin/env python3
"""Fail if runtime scripts/workflows contain redacted auth placeholders."""

from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SEARCH_ROOTS = [ROOT / "scripts", ROOT / ".github" / "workflows"]
SKIP_NAMES = {Path(__file__).name}
PLACEHOLDERS = [
    "ACTI" + "..." + "KEN",
    "SOUR" + "..." + "EN",
    "DEPL" + "..." + "git",
    "x-access-token:" + "***",
    "AUTHORIZATION: basic " + "***",
]
EXTENSIONS = {".sh", ".py", ".yml", ".yaml"}

failures: list[str] = []
for search_root in SEARCH_ROOTS:
    if not search_root.exists():
        continue
    for path in sorted(search_root.rglob("*")):
        if not path.is_file() or path.suffix not in EXTENSIONS or path.name in SKIP_NAMES:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for placeholder in PLACEHOLDERS:
            if placeholder in text:
                rel = path.relative_to(ROOT)
                failures.append(f"{rel}: contains placeholder {placeholder!r}")

if failures:
    print("Auth placeholder regression check failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print("Auth placeholder regression check passed.")
