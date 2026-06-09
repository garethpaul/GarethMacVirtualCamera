# Build Log Archive Failed Scan

status: completed

## Context

The Xcode build-log scanner fails on warnings, errors, nonzero command failures,
build failure summaries, build-failed banners, and test-failed banners. Xcode
archive logs can also emit a top-level `** ARCHIVE FAILED **` banner that should
be treated as actionable if the scanner is reused for archive output.

## Completed Scope

- Added `** ARCHIVE FAILED **` to the actionable Xcode log pattern.
- Added scanner test coverage for archive-failed banners.
- Extended project validation and docs so the scanner contract remains visible.

## Verification

- `./scripts/test_scan_build_log.py`
- `./scripts/check_project.sh`
- `make check`
