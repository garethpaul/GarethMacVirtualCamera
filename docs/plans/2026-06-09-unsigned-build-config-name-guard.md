# Unsigned Build Config Name Guard

status: completed

## Context

`scripts/build_unsigned.sh` writes per-configuration logs named
`build-${configuration}.log`. Configuration names are normally `Debug` and
`Release`, but the script also accepts positional configuration arguments.
Path-like names should be rejected before log paths are created or `xcodebuild`
is invoked.

## Completed Scope

- Added validation for unsigned-build configuration names.
- Added shell coverage that rejects `../Release` before the `xcodebuild` stub is
  called.
- Extended the project validator and validator mutation tests so `make check`
  preserves the guard.
- Documented the unsigned build input boundary in README, VISION, and CHANGES.

## Verification

- `./scripts/test_build_unsigned.sh`
- `./scripts/test_validate_project.py`
- `./scripts/check_project.sh`
- `make check`
