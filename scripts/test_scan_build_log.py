#!/usr/bin/env python3
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "scripts" / "scan_build_log.py"


def run_scanner(*contents_by_file):
    build_log_paths = []

    try:
        for contents in contents_by_file:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as build_log:
                build_log.write(contents)
                build_log_paths.append(Path(build_log.name))

        return subprocess.run(
            [sys.executable, str(SCANNER), *(str(build_log_path) for build_log_path in build_log_paths)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        for build_log_path in build_log_paths:
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
    result = run_scanner("note: harmless\nSwiftCompile warning: real source warning\n")
    require(result.returncode == 1, result.stdout + result.stderr)
    require("real source warning" in result.stdout, result.stdout)
    require(":2: SwiftCompile warning: real source warning" in result.stdout, result.stdout)


def test_fails_on_other_appintents_warning():
    result = run_scanner("appintentsmetadataprocessor warning: unexpected metadata failure\n")
    require(result.returncode == 1, result.stdout + result.stderr)
    require("unexpected metadata failure" in result.stdout, result.stdout)


def test_fails_on_actionable_error():
    result = run_scanner("SwiftCompile error: real source error\n")
    require(result.returncode == 1, result.stdout + result.stderr)
    require("real source error" in result.stdout, result.stdout)


def test_scans_multiple_build_logs():
    result = run_scanner(
        "note: harmless debug build output\n",
        "note: harmless\nSwiftCompile warning: release source warning\n",
    )
    require(result.returncode == 1, result.stdout + result.stderr)
    require("release source warning" in result.stdout, result.stdout)
    require(":2: SwiftCompile warning: release source warning" in result.stdout, result.stdout)


def main():
    test_ignores_appintents_metadata_notice()
    test_fails_on_actionable_warning()
    test_fails_on_other_appintents_warning()
    test_fails_on_actionable_error()
    test_scans_multiple_build_logs()
    print("Build-log scanner tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
