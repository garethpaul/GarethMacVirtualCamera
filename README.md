# Gareth Mac Virtual Camera

A macOS CoreMediaIO camera extension packaged in a SwiftUI host app. The extension publishes the bundled `Extension/video.mp4` as a virtual camera named `Gareth Video Cam`.

## Current Target

- Xcode 26.5 with the macOS 26.5 SDK
- Swift 6 language mode
- macOS Tahoe 26.5.1 as the current compatibility reference
- Deployment target: macOS 14.0 or later
- Host app bundle ID: `com.garethpaul.GarethVideoCam`
- Camera extension bundle ID: `com.garethpaul.GarethVideoCam.Extension`

## Build And Run

Open `GarethVideoCam.xcodeproj` in Xcode, select the shared `GarethVideoCam` scheme, then build and run.

The shared scheme replaces `/Applications/GarethVideoCam.app` with the freshly built app before launch. macOS only activates system extensions from apps located in `/Applications`.

## Validate

This workspace does not require Xcode for local validation checks:

```sh
./scripts/check_project.sh
```

The check script runs project metadata validation, build-log scanner tests, runtime diagnostics tests, build-product verifier tests, shell syntax checks, and whitespace checks. The build-product verifier checks bundle identifiers, aligned bundle versions, declared executables, display metadata, privacy usage strings, resolved CoreMediaIO extension metadata, and the bundled video resource. The validator also checks the bundled `Extension/video.mp4` for parseable dimensions, frame rate, and positive video duration so resource regressions fail before runtime activation.

For a CI-equivalent unsigned compile on macOS with Xcode installed:

```sh
./scripts/build_unsigned.sh
./scripts/scan_build_log.py build-Debug.log build-Release.log
```

The unsigned build script writes Xcode build products and intermediates to `.build/Xcode` by default; set `BUILD_OUTPUT_PATH` to override it.

Pushes and pull requests to `main` also run `.github/workflows/macos-build.yml` on GitHub's `macos-26` runner. That workflow validates metadata, performs unsigned Debug and Release target builds, verifies the built app products contain the embedded system extension, aligned bundle versions, declared executables, display metadata, privacy usage strings, resolved CoreMediaIO extension metadata, and bundled video, captures the Xcode logs, and fails on source warnings. Xcode 26.5 currently emits an AppIntents metadata processor notice for targets without AppIntents; CI filters only that known tool notice.

## Runtime Activation

Runtime activation still requires a macOS host with a valid Apple Developer signing identity, the System Extension entitlement, and user approval in System Settings. The app must run from `/Applications/GarethVideoCam.app`; the shared Xcode scheme replaces the app there before launch for local testing.

The app disables install and uninstall actions when it is not running from `/Applications/GarethVideoCam.app`, when the host app bundle identifier does not match the expected identifier, when its app signature is invalid, when the signed app is missing the System Extension entitlement, when the app and embedded extension bundle versions do not match, when the embedded extension executable or CMIO Mach service metadata is missing, unresolved, or unexpected, when the embedded `video.mp4` resource is missing or empty, when the bundled system extension signature is invalid, when the embedded system extension carries the host-only System Extension entitlement, when the app and extension do not share an expected app-group entitlement, or when the app and extension signing Team IDs are missing or do not match. It reports extension metadata and bundled-video packaging blockers as distinct readiness states, refreshes readiness when the app becomes active, shows and copies a readiness summary, next action, and checklist for those activation gates, exposes a primary System Settings approval shortcut when macOS is waiting for user approval, can reveal the app and embedded extension in Finder, and can copy a diagnostics snapshot with a generation timestamp, macOS version, bundle identifiers, exact app and extension short/build bundle versions, bundle short/build version match status, the expected and current app paths, app and extension quarantine status, app and extension signing status, extension host-only entitlement status, signed app-group values and match status, Team IDs, bundled extension executable, resolved CMIO Mach service status, CMIO Mach service identifier match status, the pending request direction, the last recorded failure, and timestamped recent request activity with severity.

Signed runtime activation checklist:

1. Build with an Apple Developer team that has the System Extension entitlement and app-group entitlement.
2. Run the shared Xcode scheme so it replaces `/Applications/GarethVideoCam.app`, then open the app from that path.
3. Confirm the in-app readiness summary has no blocked checks, then choose Install.
4. Approve the pending camera extension in System Settings if macOS requests approval.
5. Run `./scripts/collect_runtime_diagnostics.sh /Applications/GarethVideoCam.app 1h`.
6. Confirm the diagnostics report `Runtime readiness result: ready`, `Extension registration entry present: yes`, `Application group match ready: yes`, and `Expected virtual camera device present: yes`.

After approval, camera pickers should list `Gareth Video Cam`.

To collect runtime evidence from a signed macOS host:

```sh
./scripts/collect_runtime_diagnostics.sh /Applications/GarethVideoCam.app
```

Pass a second argument to change the unified-log window, for example `1h`.

The diagnostics script reports host tool versions, app and extension Info.plist bundle versions and identifiers, app/extension bundle-version match status, bundled-video byte size, checksum, metadata, expected application-location and bundle identifier checks, app executable metadata, quarantine attributes, code-signing status, matching Team IDs, Gatekeeper assessment, signed entitlements, explicit host and extension System Extension entitlement checks, signed app-group values and match readiness, a counted runtime-readiness summary with a next-action hint, embedded system-extension executable metadata, resolved CMIO Mach service status, `systemextensionsctl` registration presence and full list output, expected virtual-camera device presence with full camera inventory, running app/extension processes, recent `com.garethpaul.GarethVideoCam` unified logs, and recent system-extension/CMIO log context.
