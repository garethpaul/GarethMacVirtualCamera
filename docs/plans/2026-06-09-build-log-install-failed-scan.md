# Build Log Install Failed Scan

status: completed

## Context

The Xcode build-log scanner already fails on warnings, errors, nonzero command
failures, build/test failure summaries, and build, archive, analyze, clean, and
test failed banners. Xcode can also emit a top-level `** INSTALL FAILED **`
banner when install actions fail, especially when a reused scanner is pointed at
run or install logs.

## Completed Scope

- Added `** INSTALL FAILED **` to the actionable Xcode log pattern and the
  ignored-line disqualifier.
- Added scanner regression coverage for install-failed banners.
- Extended project validation and mutation tests so install-failed scanning
  remains enforced.
- Updated README, VISION, and CHANGES.

## Verification

- `./scripts/test_scan_build_log.py`
- `./scripts/test_validate_project.py`
- `./scripts/check_project.sh`
- `make check`
- `git diff --check`
