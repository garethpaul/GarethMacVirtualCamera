# Build Log Nonzero Failure Scan

Date: 2026-06-09

Status: Completed

## Context

The build-log scanner already failed on actionable warnings and `error:` lines,
but Xcode can also report failed compiler commands as `failed with a nonzero
exit code` without a nearby `error:` token. Those failures should block the
same validation path.

## Scope

- Preserve ignored AppIntents metadata noise filtering.
- Treat nonzero command failure lines as actionable build-log failures.
- Add scanner regression coverage for the nonzero failure text.
- Keep `validate_project.py` checking that scanner coverage exists.

## Verification

- `PYTHONDONTWRITEBYTECODE=1 make check`
- `git diff --check`
