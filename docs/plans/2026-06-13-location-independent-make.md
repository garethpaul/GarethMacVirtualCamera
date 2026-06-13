---
title: Location-Independent Project Verification
date: 2026-06-13
status: completed
execution: code
---

## Context

The maintained project gate succeeds from the checkout but fails when the
absolute Makefile is invoked from another working directory. Both the Make
recipe and `scripts/check_project.sh` resolve repository paths through the
caller's current directory.

## Priority

This is the next isolated reliability gap because CI and local automation
should be able to load the repository Makefile without first changing
directories. The fix must preserve the complete validator, fixture, shell,
whitespace, unsigned-build, product-verification, and hosted macOS baseline.

## Requirements

- Derive the repository root from `MAKEFILE_LIST` in `Makefile`.
- Invoke `scripts/check_project.sh` through the rooted Make path.
- Make `scripts/check_project.sh` enter its own repository root before running
  the existing relative commands.
- Add validator and mutation-test contracts for the rooted Makefile, rooted
  check script, completed plan, external-run evidence, and synchronized
  guidance.
- Keep Swift, Xcode project, entitlements, signing, workflow, fixtures, and
  bundled media unchanged.

## Verification Plan

- Run focused validator tests, direct project validation, all shell fixture
  suites, and all four Make gates at repository root.
- Run all four Make gates from /tmp through the absolute Makefile path.
- Reject caller-relative Makefile, missing check-script root, plan-status,
  plan-evidence, and documentation mutations.
- Run Python and shell syntax, plist/project/scheme parsing, `git diff --check`,
  exact-path review, secret/signing inspection, and generated-artifact checks.

## Non-Goals

- Changing camera sample processing, runtime activation, host UI, dependencies,
  Xcode project settings, entitlements, signing, or hosted workflow policy.
- Claiming signed extension activation or live virtual-camera output on this
  Linux host.

## Work Completed

- Rooted the Make entry point from the loaded Makefile and invoked the
  maintained checker through its absolute repository path.
- Made `scripts/check_project.sh` enter its own repository root before running
  the existing relative validation commands.
- Added validator and mutation-test contracts for behavior, completed evidence,
  and synchronized guidance without touching application or project files.

## Verification Completed

- `./scripts/validate_project.py`, `./scripts/test_validate_project.py`, and
  `./scripts/check_project.sh` passed.
- All four Make gates (`make lint`, `make test`, `make build`, and `make check`)
  passed at repository root and from /tmp through the absolute Makefile path.
- The caller-relative Makefile mutation failed.
- The missing check-script root mutation failed.
- The plan-status mutation failed.
- The plan-evidence mutation failed.
- The documentation mutation failed.
- Python and shell syntax, plist/project/scheme parsing, `git diff --check`,
  exact intended-path review, added-line secret/signing inspection, and
  generated-artifact inspection passed.
- Signed extension activation and live virtual-camera output were unavailable
  on this Linux host and are not claimed.
