# Gareth Mac Virtual Camera Make Gate Aliases

status: completed

## Context

The project already has a strong `make check` baseline through
`scripts/check_project.sh`, but the local pre-push gate also expects
`make lint`, `make test`, and `make build`. Without those aliases, the first
gate command fails before reaching the validator and mutation tests.

## Objectives

- Provide stable Makefile targets for lint, test, build, and check.
- Keep the targets delegated to the existing project validation pipeline.
- Extend `scripts/validate_project.py` and its mutation tests so the aliases
  remain covered.
- Document the gate targets in README, VISION, and CHANGES.

## Verification

- `make lint`
- `make test`
- `make build`
- `make check`
- `git diff --check`
