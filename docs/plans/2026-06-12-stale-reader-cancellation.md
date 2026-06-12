# Stale Asset Reader Cancellation

status: completed

## Context

Stream preparation creates and starts an `AVAssetReader` asynchronously before
dispatching its installation onto the serialized stream queue. A rapid stop or
replacement start can cancel that preparation task or advance
`streamGeneration` after the reader has started but before the queued completion
runs.

The generation guard correctly prevents stale reader state from becoming the
active stream, but the abandoned reader is currently released without an
explicit `cancelReading()` call. Media work should be stopped deliberately when
the extension has already rejected the preparation result.

## Priority

Camera extensions run in a constrained system process and can receive rapid
client start/stop transitions. Explicitly cancelling abandoned readers avoids
unnecessary file and decoder work and makes stream teardown ownership clear.

## Prioritized Backlog

1. Cancel a newly created reader when task cancellation is observed after
   `makeAssetReader` succeeds.
2. Cancel the reader when its queued completion finds that the device source
   was released or fails the stream-generation guard.
3. Preserve active reader installation, loop restart, timer, and multi-client
   counter behavior.
4. Extend project validation, mutation coverage, and maintenance docs.

## Implementation

- Call `readerState.assetReader.cancelReading()` before returning from the
  post-reader task-cancellation branch.
- Cancel the same reader when the queued completion has no live device source
  and inside the stale-completion guard on `_timerQueue`.
- Keep stale preparation failures unchanged because they do not carry a started
  reader state.
- Update `validate_project.py`, its mutation suite, README, SECURITY, VISION,
  and CHANGES.

## Verification

- `./scripts/test_validate_project.py`
- `./scripts/check_project.sh`
- `make check`
- `make lint`
- `make test`
- `make build`
- `git diff --check`
- Mutations removing cancellation from the task-cancelled, released-source, or
  stale-completion path must fail.
- Hosted macOS/Xcode unsigned Debug and Release builds must pass.
