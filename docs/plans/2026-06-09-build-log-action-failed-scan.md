# Build Log Action Failed Scan

status: completed

## Context

The Xcode build-log scanner already treats warnings, errors, command failures,
build/archive/test failed banners, and build/test summaries as actionable.
Xcode can also emit top-level analyze-failed or clean-failed banners when those
actions are used, and those should not pass through a reused scanner.

## Completed Scope

- Added `** ANALYZE FAILED **` and `** CLEAN FAILED **` to the actionable Xcode
  log pattern.
- Added scanner regression coverage for both action-failed banners.
- Extended project validation and docs so the scanner contract remains visible.

## Verification

- `./scripts/test_scan_build_log.py`
- `./scripts/test_validate_project.py`
- `./scripts/check_project.sh`
- `make check`
- `git diff --check`
