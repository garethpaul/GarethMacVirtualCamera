# Gareth Mac Virtual Camera Make Check Baseline Plan

status: completed

## Context

`GarethMacVirtualCamera` already has strong validation through `scripts/check_project.sh`, fixture-based shell tests, project metadata validation, and CI build-product checks. The remaining reproducibility gap is that the common repository entry point is the script itself rather than a conventional `make check` target documented and validated alongside the project guardrails.

## Objectives

- Add a conventional `make check` entry point that delegates to the existing project validator.
- Record the maintenance change in `CHANGES.md`.
- Document `make check` next to the existing validation command.
- Extend `scripts/validate_project.py` so the Makefile, plan, README, VISION, and change log remain aligned with the validation baseline.

## Verification

- `./scripts/check_project.sh`
- `make check`
- `git diff --check`
