# Gareth Mac Virtual Camera

A macOS CoreMediaIO camera extension packaged in a SwiftUI host app. The extension publishes the bundled `Extension/video.mp4` as a virtual camera named `Gareth Video Cam`.

## Current Target

- Xcode 26.5 with the macOS 26.5 SDK
- macOS Tahoe 26.5.1 as the current compatibility reference
- Deployment target: macOS 14.0 or later
- Host app bundle ID: `com.garethpaul.GarethVideoCam`
- Camera extension bundle ID: `com.garethpaul.GarethVideoCam.Extension`

## Build And Run

Open `GarethVideoCam.xcodeproj` in Xcode, select the shared `GarethVideoCam` scheme, then build and run.

The shared scheme replaces `/Applications/GarethVideoCam.app` with the freshly built app before launch. macOS only activates system extensions from apps located in `/Applications`.

## Validate

This workspace does not require Xcode for metadata checks:

```sh
./scripts/validate_project.py
```

For a CI-equivalent unsigned compile on macOS with Xcode installed:

```sh
runner_arch="$(uname -m)"
for configuration in Debug Release; do
  xcodebuild \
    -project GarethVideoCam.xcodeproj \
    -target GarethVideoCam \
    -configuration "${configuration}" \
    ARCHS="${runner_arch}" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build 2>&1 | tee "build-${configuration}.log"

  ./scripts/scan_build_log.py "build-${configuration}.log"
done
```

Pushes and pull requests to `main` also run `.github/workflows/macos-build.yml` on GitHub's `macos-26` runner. That workflow validates metadata, performs unsigned Debug and Release target builds, captures the Xcode logs, and fails on source warnings. Xcode 26.5 currently emits an AppIntents metadata processor notice for targets without AppIntents; CI filters only that known tool notice.

## Runtime Activation

Runtime activation still requires a macOS host with a valid Apple Developer signing identity, the System Extension entitlement, and user approval in System Settings. The app must run from `/Applications/GarethVideoCam.app`; the shared Xcode scheme replaces the app there before launch for local testing.

The app disables install and uninstall actions when it is not running from `/Applications`, when the host app bundle identifier does not match the expected identifier, when its app signature is invalid, when the signed app is missing the System Extension entitlement, when the embedded `video.mp4` resource is missing or empty, when the bundled system extension signature is invalid, or when the app and extension signing Team IDs are missing or do not match. It shows and copies a readiness checklist for those activation gates, exposes a primary System Settings approval shortcut when macOS is waiting for user approval, can reveal the app and embedded extension in Finder, and can copy a diagnostics snapshot with a generation timestamp, bundle identifiers, the current app path, app and extension signing status, Team IDs, bundled extension metadata, the pending request direction, the last recorded failure, and recent request activity.

After approving the camera extension in System Settings, it should appear in camera pickers as `Gareth Video Cam`.

To collect runtime evidence from a signed macOS host:

```sh
./scripts/collect_runtime_diagnostics.sh /Applications/GarethVideoCam.app
```

Pass a second argument to change the unified-log window, for example `1h`.

The diagnostics script reports host tool versions, app and extension bundle versions, bundled-video byte size, checksum, metadata, expected application-location and bundle identifier checks, code-signing status, matching Team IDs, Gatekeeper assessment, signed entitlements, explicit host System Extension entitlement checks, a runtime-readiness summary, embedded system-extension metadata, `systemextensionsctl` registration, camera device inventory, recent `com.garethpaul.GarethVideoCam` unified logs, and recent system-extension/CMIO log context.
