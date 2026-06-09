# Validate Project Parser Test

Status: Completed

## Context

`scripts/validate_project.py` parses MP4 metadata from the bundled camera loop
video. The parser already handles truncated atoms in most paths, but an empty
`mdhd` payload could index past the atom boundary before returning unknown
metadata.

## Objectives

- Make malformed empty `mdhd` atoms return unknown metadata rather than raising.
- Add a focused validator unit test that imports `validate_project.py` and feeds
  a synthetic malformed MP4 fixture.
- Run the validator unit test from `scripts/check_project.sh`.
- Extend `scripts/validate_project.py` so the new test remains part of the
  checked validation baseline.

## Verification

- `make check`
- `./scripts/check_project.sh`
- `git diff --check`
