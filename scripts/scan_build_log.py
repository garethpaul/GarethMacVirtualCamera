#!/usr/bin/env python3
import re
import sys
from pathlib import Path


ACTIONABLE_PATTERN = re.compile(r"warning:|error:", re.IGNORECASE)
IGNORED_LINE_TOKEN_GROUPS = (
    (
        "appintentsmetadataprocessor",
        "Metadata extraction skipped. No AppIntents.framework dependency found.",
    ),
)


def is_ignored(line):
    normalized_line = line.lower()
    return any(
        all(token.lower() in normalized_line for token in token_group)
        for token_group in IGNORED_LINE_TOKEN_GROUPS
    )


def main():
    if len(sys.argv) != 2:
        print("Usage: scan_build_log.py BUILD_LOG", file=sys.stderr)
        return 2

    build_log_path = Path(sys.argv[1])
    if not build_log_path.exists():
        print(f"Build log not found: {build_log_path}", file=sys.stderr)
        return 2

    actionable_lines = []
    with build_log_path.open("r", encoding="utf-8", errors="replace") as build_log:
        for line_number, line in enumerate(build_log, start=1):
            if ACTIONABLE_PATTERN.search(line) and not is_ignored(line):
                actionable_lines.append((line_number, line.rstrip()))

    if actionable_lines:
        print("Actionable build warnings/errors found:")
        for line_number, line in actionable_lines:
            print(f"{build_log_path}:{line_number}: {line}")
        return 1

    print("No actionable build warnings/errors found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
