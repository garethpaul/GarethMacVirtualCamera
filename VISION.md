## Gareth Mac Virtual Camera Vision

This document explains the current state and direction of the project.
Project overview and developer docs: [`README.md`](README.md)

Gareth Mac Virtual Camera is a macOS CoreMediaIO camera extension packaged in a
SwiftUI host app. It publishes a bundled MP4 as a virtual camera named `Gareth
Video Cam`.

The goal is a robust, inspectable virtual camera sample with strong validation
before runtime activation. Project details, validation commands, and activation
requirements live in [`README.md`](README.md).

The current focus is:

Priority:

- Preserve the host app and embedded camera extension relationship
- Keep build-product, entitlement, signing, and bundled-video validation strong
- Maintain local checks and CI-equivalent unsigned build paths
- Run hosted macOS validation for pushes and pull requests on every branch,
  including stacked pull requests
- Keep third-party CI actions pinned to reviewed commit SHAs and covered by
  validator mutation tests
- Keep build-log scanning strict for warnings, errors, failed Xcode commands,
  and build/archive/analyze/clean/install/test failure banners
- Keep unsigned build configuration and architecture inputs constrained before
  log files are written
- Loop bundled video only after asset-reader completion; wait while reads are
  active and stop on cancelled or invalid reader states
- Cancel prepared asset readers when asynchronous startup is cancelled, loses
  its device source, or is superseded before the reader is installed
- Commit loop offset, presentation-time, and host-timebase state only after a
  camera sample is successfully retimed
- Keep `make lint`, `make test`, `make build`, and `make check` aligned with
  `./scripts/check_project.sh`
- Make runtime activation blockers clear to users

Next priorities:

- Keep diagnostics aligned with macOS and Xcode changes
- Improve runtime evidence collection as activation states evolve
- Preserve strict validation around bundle IDs, app groups, entitlements, and
  video metadata
- Document signed-host evidence when testing on real developer machines

Contribution rules:

- One PR = one focused validation, runtime, extension, UI, or documentation change.
- Run `./scripts/check_project.sh` before pushing.
- For build-affecting changes, run the unsigned build and log scanner when Xcode
  is available.
- Do not weaken activation checks to make local testing easier.

## Security And Privacy

Canonical security policy and reporting:

- [`SECURITY.md`](SECURITY.md)

Virtual camera extensions interact with a sensitive media surface. The app
should keep activation explicit, signed, and user-approved.

Do not add hidden camera capture, external streaming, or entitlement shortcuts.
Signing, app-group, and system-extension checks are part of the product safety
model.

## What We Will Not Merge (For Now)

- Runtime activation shortcuts that bypass signing or user approval
- Hidden capture, upload, or streaming behavior
- Validation removals without stronger replacement checks
- Bundle ID, entitlement, or app-group changes without diagnostics updates

This list is a roadmap guardrail, not a permanent rule.
Strong user demand and strong technical rationale can change it.
