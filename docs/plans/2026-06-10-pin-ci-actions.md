# Pin CI Actions

status: completed

## Context

The macOS build workflow already used current Node 24-capable actions, but
referenced mutable release tags. A compromised or moved tag could change code
executed with the workflow token.

## Changes

- Pinned `actions/checkout` v6.0.3 and `actions/upload-artifact` v7.0.1 to their
  official commit SHAs.
- Disabled persisted checkout credentials so later build and validation steps
  cannot reuse the workflow token through the local Git configuration.
- Updated project validation to require those exact action commits.
- Added dependency-free structural workflow validation and mutation tests that
  reject floating or duplicate checkout actions plus missing, duplicate,
  relocated, or contradictory credential settings.

## Verification

- `make check`
- `git diff --check`
- Hosted macOS build workflow
