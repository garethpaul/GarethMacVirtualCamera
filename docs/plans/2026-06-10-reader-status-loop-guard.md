# Reader Status Loop Guard

status: completed

## Context

When `copyNextSampleBuffer()` returns nil, the camera extension currently
restarts the bundled video unless the asset reader is explicitly failed. A nil
sample while the reader is still reading is not an end-of-file signal, and
cancelled, unknown, or future reader states should not silently reopen the
asset.

## Priority

Restarting on the wrong reader state can jump playback, churn asset readers, or
continue after cancellation. Frame delivery should distinguish temporary
sample unavailability from a completed loop and terminal failures.

## Implementation

- Require a current asset reader before handling a nil sample.
- Return and wait for the next timer tick while the reader remains `.reading`.
- Restart the bundled video only after `.completed`.
- Stop the streaming session for failed, cancelled, unknown, or future states.
- Preserve actionable reader errors in extension logs.
- Extend the project validator, validator mutation tests, and operational docs.

## Verification

- `python3 scripts/test_validate_project.py`
- `python3 scripts/validate_project.py`
- `make check`
- `make lint`
- `make test`
- `make build`
- `git diff --check`
- Mutations removing the reading wait or completed-only loop gate must fail.
- Hosted macOS project validation.
