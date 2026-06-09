# Build Log Command Summary Scan

Date: 2026-06-09

Status: Completed

## Context

The build-log scanner already failed on actionable warnings, `error:` lines,
nonzero command failures, and build-failed banners. Xcode can also summarize a
failure with `The following build commands failed:` in archived logs, so that
summary should block the same validation path.

## Scope

- Preserve ignored AppIntents metadata noise filtering.
- Treat build command failure summary lines as actionable build-log failures.
- Add scanner regression coverage for the exact Xcode summary text.
- Keep `validate_project.py` checking that scanner coverage exists.

## Verification

- `PYTHONDONTWRITEBYTECODE=1 make check`
- `git diff --check`
