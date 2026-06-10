# Pin CI Actions

status: completed

## Context

The macOS build workflow already used current Node 24-capable actions, but
referenced mutable release tags. A compromised or moved tag could change code
executed with the workflow token.

## Changes

- Pinned `actions/checkout` v6.0.2 and `actions/upload-artifact` v7.0.1 to their
  official commit SHAs.
- Updated project validation to require those exact action commits.
- Added mutation tests that reject regressions to floating action tags.

## Verification

- `make check`
- `git diff --check`
- Hosted macOS build workflow
