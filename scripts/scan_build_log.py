#!/usr/bin/env python3
import re
import sys
from pathlib import Path


ACTIONABLE_PATTERN = re.compile(
    r"warning:|error:|failed with a nonzero exit code|the following build commands failed:|testing failed:|\*\* BUILD FAILED \*\*|\*\* ARCHIVE FAILED \*\*|\*\* ANALYZE FAILED \*\*|\*\* CLEAN FAILED \*\*|\*\* TEST FAILED \*\*",
    re.IGNORECASE,
)
IGNORED_LINE_TOKEN_GROUPS = (
    (
        "appintentsmetadataprocessor",
        "warning:",
        "Metadata extraction skipped. No AppIntents.framework dependency found.",
    ),
)


class BuildLogReadError(Exception):
    def __init__(self, build_log_path, error):
        self.build_log_path = build_log_path
        self.error = error
        super().__init__(f"{build_log_path}: {error}")


def is_ignored(line):
    normalized_line = line.lower()
    return any(
        all(token.lower() in normalized_line for token in token_group)
        for token_group in IGNORED_LINE_TOKEN_GROUPS
    )


def actionable_lines_in(build_log_path):
    actionable_lines = []
    try:
        with build_log_path.open("r", encoding="utf-8", errors="replace") as build_log:
            for line_number, line in enumerate(build_log, start=1):
                if ACTIONABLE_PATTERN.search(line) and not is_ignored(line):
                    actionable_lines.append((build_log_path, line_number, line.rstrip()))
    except OSError as error:
        raise BuildLogReadError(build_log_path, error) from error

    return actionable_lines


def main():
    if len(sys.argv) < 2:
        print("Usage: scan_build_log.py BUILD_LOG [BUILD_LOG ...]", file=sys.stderr)
        return 2

    actionable_lines = []
    for build_log_path in (Path(argument) for argument in sys.argv[1:]):
        if not build_log_path.exists():
            print(f"Build log not found: {build_log_path}", file=sys.stderr)
            return 2
        if not build_log_path.is_file():
            print(f"Build log is not a regular file: {build_log_path}", file=sys.stderr)
            return 2

        try:
            actionable_lines.extend(actionable_lines_in(build_log_path))
        except BuildLogReadError as error:
            detail = error.error.strerror or str(error.error)
            print(f"Build log is not readable: {error.build_log_path}: {detail}", file=sys.stderr)
            return 2

    if actionable_lines:
        print("Actionable Xcode log warnings/errors/failures found:")
        for build_log_path, line_number, line in actionable_lines:
            print(f"{build_log_path}:{line_number}: {line}")
        return 1

    print("No actionable Xcode log warnings/errors/failures found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
