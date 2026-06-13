---
title: All-Branch Hosted Validation
date: 2026-06-13
status: planned
execution: code
---

## Context

The macOS workflow limits both `push` and `pull_request` events to `main`.
Stacked remediation branches therefore receive no hosted validation: PR #7 is
open and locally verified, but GitHub never ran the maintained macOS 26, Xcode
26.5, unsigned-build, product-verification, or log-scan job for that PR.

## Priority

This is the highest-value remaining isolated delivery gap because the Linux
development host cannot compile Swift, run Xcode, or validate the packaged app
and camera extension. Every feature head needs the existing hosted build before
it can be considered merge-ready, including heads whose PR base is another
feature branch.

## Prioritized Backlog

1. Run the canonical workflow for pushes to every branch.
2. Run the same workflow for pull requests targeting every branch.
3. Preserve manual dispatch, read-only permissions, pinned actions, bounded
   runtime, concurrency cancellation, and the complete validation/build job.
4. Add exact trigger-policy and hostile-mutation contracts plus repository
   guidance.
5. Keep workflow-path filtering and broader runner-cost optimization separate.

## Implementation

- Remove branch filters from the workflow's `push` and `pull_request` triggers.
- Extend project validation with one exact top-level trigger contract.
- Add mutation tests that restore the push filter, restore the pull-request
  filter, or remove pull-request coverage.
- Update README, SECURITY, VISION, CHANGES, and AGENTS guidance with the
  all-branch hosted gate.

## Verification Plan

- Run focused validator tests, direct project validation, all shell suites, all
  four Make gates, Python/shell syntax, plist/project/scheme parsing,
  whitespace checks, and intended-file secret/artifact scans.
- Restore main-only push filtering, restore main-only pull-request filtering,
  and remove pull-request coverage; each hostile mutation must fail.
- Require both canonical push and pull-request jobs to pass on the exact
  implementation head, with a bounded CodeQL snapshot and no watch loop.

## Work Completed

- Pending implementation.

## Verification Completed

- Pending implementation and verification.
