# Security Policy

## Supported Versions

The supported security scope for Gareth Mac Virtual Camera is the current default branch, `main`. Older commits, tags, branches, forks, demos, and generated artifacts are not actively supported unless the repository explicitly marks them as maintained.

Gareth Mac Virtual Camera is a macOS SwiftUI host app with an embedded CoreMediaIO system extension. The extension publishes the bundled `Extension/video.mp4` as a virtual camera named `Gareth Video Cam`.

## Reporting a Vulnerability

Report suspected vulnerabilities through GitHub private vulnerability reporting or a draft GitHub Security Advisory for `garethpaul/GarethMacVirtualCamera` when that option is available. If private reporting is unavailable, contact the repository owner through GitHub and avoid posting exploit details publicly until the issue can be assessed.

Do not open a public issue that includes exploit code, secrets, personal data, or detailed reproduction steps for an unpatched vulnerability.

## What to Include

Helpful reports include:

- the affected file, entitlement, bundle identifier, script, workflow, or runtime path
- the macOS version, Xcode version, branch, and commit SHA used
- a concise impact statement explaining what an attacker or untrusted local process could do
- reproduction steps using test data, local apps, and devices you control
- relevant logs, diagnostics, screenshots, or proof-of-concept snippets without private data

## Project Security Posture

Virtual camera extensions operate on a privacy-sensitive media surface. Changes should preserve explicit user approval, valid signing, expected bundle identifiers, expected app-group entitlements, and the System Extension entitlement model.

Security-sensitive surfaces include:

- system-extension activation, deactivation, approval, and registration handling
- host and extension code signing, Team ID matching, and entitlement validation
- shared app-group configuration between the host app and embedded extension
- bundled-video parsing, metadata validation, and pixel-buffer stream-format checks
- transactional sample-timing state that is committed only after retiming succeeds
- completed-reader-only bundled-video loop handling
- explicit cancellation of prepared asset readers abandoned by stream startup
  cancellation or stale generation checks
- runtime diagnostics that collect signing, entitlement, process, camera inventory, and unified-log evidence
- shell scripts and CI workflows that build, verify, or scan project artifacts

Do not add hidden camera capture, external streaming, upload behavior, entitlement shortcuts, or activation paths that bypass macOS signing and user approval.

## Safe Research Guidelines

Good-faith research is welcome when it stays within these boundaries:

- use only devices, data, and infrastructure that you own or have explicit permission to test
- avoid destructive actions, persistence, spam, phishing, social engineering, or denial-of-service testing
- minimize access to personal data and stop testing immediately if private data is exposed
- do not exfiltrate secrets or third-party data
- report the minimum evidence needed to verify impact
- keep vulnerability details confidential until the maintainer has assessed the report

## Dependency and Supply Chain Security

This repository does not use a root package dependency manifest. If dependencies are added later, use trusted package managers, keep lockfiles in sync when lockfiles exist, and avoid committing credentials, private keys, tokens, generated secrets, or machine-local configuration.

Build and validation changes should keep `./scripts/check_project.sh`, `.github/workflows/macos-build.yml`, `./scripts/build_unsigned.sh`, `./scripts/verify_build_products.sh`, and `./scripts/scan_build_log.py` aligned so local and CI evidence stay comparable.
Keep third-party workflow actions pinned to reviewed commit SHAs; update the
validator and mutation tests with any intentional action upgrade. Checkout must
keep `persist-credentials: false` in its own `with` mapping so later build steps
cannot reuse the workflow token through local Git configuration.
Unsigned-build architecture overrides should remain single architecture tokens
so local and CI builds do not write ambiguous `ARCHS` values into evidence.

## Maintainer Response

The maintainer will review complete reports as availability allows, prioritize issues by exploitability and impact, and coordinate a fix or mitigation when the affected code is still maintained. For sample, archived, or educational repository states, remediation may be documentation, validation, dependency updates, or clearly marking unsupported code rather than a production-style release.
