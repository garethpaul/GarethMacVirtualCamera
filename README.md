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

The shared scheme copies the built app to `/Applications/GarethVideoCam.app` before launch. macOS only activates system extensions from apps located in `/Applications`.

## Validate

This workspace does not require Xcode for metadata checks:

```sh
./scripts/validate_project.py
```

For a CI-equivalent unsigned compile on macOS with Xcode installed:

```sh
runner_arch="$(uname -m)"
xcodebuild \
  -project GarethVideoCam.xcodeproj \
  -target GarethVideoCam \
  -configuration Debug \
  ARCHS="${runner_arch}" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
```

Pushes and pull requests to `main` also run `.github/workflows/macos-build.yml` on GitHub's `macos-26` runner. That workflow validates metadata, performs the unsigned Debug target build, captures the Xcode log, and fails on source warnings. Xcode 26.5 currently emits an AppIntents metadata processor notice for targets without AppIntents; CI filters only that known tool notice.

## Runtime Activation

Runtime activation still requires a macOS host with a valid Apple Developer signing identity, the System Extension entitlement, and user approval in System Settings. The app must run from `/Applications/GarethVideoCam.app`; the shared Xcode scheme copies the built app there before launch for local testing.

The app disables install and uninstall actions when it is not running from `/Applications`, exposes a System Settings shortcut for approval, and can copy a diagnostics snapshot with the current app path, bundled extension metadata, and recent request activity.

After approving the camera extension in System Settings, it should appear in camera pickers as `Gareth Video Cam`.
