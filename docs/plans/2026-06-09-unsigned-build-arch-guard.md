# Unsigned Build Architecture Guard

status: completed

## Context

`scripts/build_unsigned.sh` passes `BUILD_ARCH` into the Xcode `ARCHS` build
setting. The script normally discovers a runner architecture with
`/usr/bin/uname -m`, but CI and local callers can override it. Invalid or
path-like architecture overrides should be rejected before the script resolves
`xcodebuild` or creates build logs.

## Completed Scope

- Added single-token validation for unsigned-build architecture values.
- Added shell coverage that rejects `../arm64` before both missing-`xcodebuild`
  handling and the `xcodebuild` stub.
- Extended the project validator and validator mutation tests so `make check`
  preserves the guard.
- Documented the unsigned build architecture input boundary in README, VISION,
  SECURITY, and CHANGES.

## Verification

- `./scripts/test_build_unsigned.sh`
- `./scripts/test_validate_project.py`
- `./scripts/check_project.sh`
- `make lint`
- `make test`
- `make build`
- `make check`
- `git diff --check`
