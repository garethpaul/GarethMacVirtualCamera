---
title: Location-Independent Project Verification
date: 2026-06-13
status: planned
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

Pending implementation.

## Verification Completed

Pending implementation and validation. Run `make check` before completion.
