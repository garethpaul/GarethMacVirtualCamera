---
title: Transactional Sample Timing State
date: 2026-06-13
status: in_progress
execution: code
---

## Context

`processSampleBuffer` currently updates `timestampOffset` and
`lastPresentationTime` immediately after reading a finite presentation
timestamp. Later host-clock conversion, nanosecond conversion, or sample-buffer
retiming can still reject the frame. That rejected frame then influences loop
detection and timestamps for later valid frames.

## Priority

This is the highest-impact remaining isolated stream correctness issue because
it can turn one rejected media sample into persistent timing drift for the
active camera stream. The fix preserves accepted-frame timing while making
state changes transactional.

## Prioritized Backlog

1. Compute candidate loop offset and presentation state without mutating the
   installed stream timing fields.
2. Validate host timing and create the retimed sample using candidate values.
3. Commit `timestampOffset` and `lastPresentationTime` only after all fallible
   validation and retiming steps succeed.
4. Add validator and mutation-test contracts for timing-state ordering.
5. Keep signed runtime and real CMIO client verification as separate evidence.

## Implementation

- Use a local candidate offset in `processSampleBuffer` and derive adjusted
  presentation time from it.
- Move persistent timing assignments below successful retiming and directly
  before stream send.
- Extend `scripts/validate_project.py` and its mutation suite with an
  order-sensitive transactional timing contract.
- Update README, SECURITY, VISION, and CHANGES with the rejected-frame boundary.

## Verification Plan

- Run focused validator tests, all Python and shell suites, all four Make gates,
  plist/project/scheme parsing, diff, and intended-file secret checks.
- Restore early offset mutation, restore early last-time mutation, and remove
  the ordering validator; each hostile mutation must fail.
- Take one bounded exact-head pull-request and CodeQL snapshot after push; do
  not poll.
