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

On macOS with Xcode installed, also run:

```sh
xcodebuild -project GarethVideoCam.xcodeproj -scheme GarethVideoCam -configuration Debug build
```

Pushes and pull requests to `main` also run `.github/workflows/macos-build.yml` on GitHub's `macos-26` runner. That workflow validates metadata and performs an unsigned Debug build so CI can catch Apple SDK compile regressions without requiring a signing certificate.

After approving the camera extension in System Settings, it should appear in camera pickers as `Gareth Video Cam`.
