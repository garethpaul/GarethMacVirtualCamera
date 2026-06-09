# AGENTS.md

## Repository purpose

A macOS CoreMediaIO camera extension packaged in a SwiftUI host app. The extension publishes the bundled `Extension/video.mp4` as a virtual camera named `Gareth Video Cam`.

## Project structure

- `Makefile` - repository verification targets
- `scripts` - baseline checks and helper scripts
- `docs` - plans, notes, and generated README assets
- `GarethVideoCam.xcodeproj` - Xcode project
- `Extension` - repository source or sample assets
- `GarethVideoCam` - repository source or sample assets

## Development commands

- Install dependencies: no repository-specific install command is documented.
- Full baseline: `make check`
- Local Apple development: `open GarethVideoCam.xcodeproj`
- If a command above skips because a platform toolchain is missing, verify on a machine with that SDK before claiming platform behavior is tested.

## Coding conventions

- Preserve legacy Xcode project settings and signing assumptions unless the change is explicitly about modernization.

## Testing guidance

- Test-related files detected: `docs/plans/2026-06-08-validate-project-parser-test.md`, `scripts/test_build_unsigned.sh`, `scripts/test_collect_runtime_diagnostics.sh`, `scripts/test_scan_build_log.py`, `scripts/test_validate_project.py`, `scripts/test_verify_build_products.sh`
- Start with the narrowest relevant test or Make target, then run `make check` before handing off if the change is not documentation-only.
- Keep README verification notes in sync when commands, fixtures, or supported toolchains change.

## PR / change guidance

- Keep diffs focused on the requested repository and avoid unrelated modernization or formatting churn.
- Preserve public APIs, sample behavior, file formats, and documented environment variables unless the task explicitly changes them.
- Update tests, README notes, or docs/plans when behavior, security posture, or validation commands change.
- Call out skipped platform validation, legacy toolchain assumptions, and any risky files touched in the final summary.

## Safety and gotchas

- No repo-specific secrets are documented; keep local credentials, build outputs, and machine-specific files out of commits.

## Agent workflow

1. Inspect the README, Makefile, manifests, and the files directly related to the request.
2. Make the smallest source or docs change that satisfies the task; avoid generated, vendored, or local-environment files unless required.
3. Run the narrowest useful validation first, then `make check` or the documented package/platform gate when available.
4. If a required SDK, service credential, or external runtime is unavailable, record the skipped command and why.
5. Summarize changed files, commands run, and remaining risks or follow-up validation.
