#!/usr/bin/env python3
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "scripts" / "scan_build_log.py"


def run_scanner(contents):
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as build_log:
        build_log.write(contents)
        build_log_path = Path(build_log.name)

    try:
        return subprocess.run(
            [sys.executable, str(SCANNER), str(build_log_path)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        build_log_path.unlink(missing_ok=True)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def test_ignores_appintents_metadata_notice():
    result = run_scanner(
        "appintentsmetadataprocessor warning: Metadata extraction skipped. "
        "No AppIntents.framework dependency found.\n"
    )
    require(result.returncode == 0, result.stdout + result.stderr)
    require("No actionable" in result.stdout, result.stdout)


def test_fails_on_actionable_warning():
    result = run_scanner("SwiftCompile warning: real source warning\n")
    require(result.returncode == 1, result.stdout + result.stderr)
    require("real source warning" in result.stdout, result.stdout)


def test_fails_on_actionable_error():
    result = run_scanner("SwiftCompile error: real source error\n")
    require(result.returncode == 1, result.stdout + result.stderr)
    require("real source error" in result.stdout, result.stdout)


def main():
    test_ignores_appintents_metadata_notice()
    test_fails_on_actionable_warning()
    test_fails_on_actionable_error()
    print("Build-log scanner tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
