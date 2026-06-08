# GarethMacVirtualCamera

## Overview

`garethpaul/GarethMacVirtualCamera` is an Apple platform application or Objective-C/Swift sample. VirtualCamera for Mac that Plays MP4 in Loop

This README is based on the checked-in source, manifests, scripts, and repository metadata on the `main` branch. The project language mix found during review was: shell (6), Swift (4), Python (3).

## Repository Contents

- `README.md` - project overview and local usage notes
- `.github` - source or example code
- `Extension` - source or example code
- `GarethVideoCam` - source or example code
- `GarethVideoCam.xcodeproj` - Xcode project file
- `scripts` - source or example code
- `SECURITY.md` - security reporting and disclosure guidance
- `VISION.md` - project direction and maintenance guardrails

Additional scan context:

- Source directories: .github, Extension, GarethVideoCam, scripts
- Dependency and build manifests: none detected
- Entry points or build surfaces: GarethVideoCam.xcodeproj
- Test-looking files: scripts/test_collect_runtime_diagnostics.sh, scripts/test_scan_build_log.py, scripts/test_verify_build_products.sh

## Getting Started

### Prerequisites

- Git
- macOS with Xcode for building Apple platform projects

### Setup

```bash
git clone https://github.com/garethpaul/GarethMacVirtualCamera.git
cd GarethMacVirtualCamera
```

The setup commands above are derived from repository files. Legacy mobile, Python, or JavaScript samples may require older SDKs or package versions than a modern workstation uses by default.

## Running or Using the Project

- Open `GarethVideoCam.xcodeproj` in Xcode, choose the app or sample scheme, and run it on the matching simulator/device.

## Testing and Verification

- Xcode's test action or `xcodebuild test` with the appropriate scheme and destination

When the required SDK or runtime is unavailable, use static checks and source review first, then verify on a machine that has the matching platform toolchain.

## Configuration and Secrets

- No required secret or credential file was identified in the repository scan. If you add integrations later, keep secrets out of git.

## Security and Privacy Notes

- Review changes touching authentication or token handling; examples from the scan include scripts/scan_build_log.py.
- Review changes touching network requests, sockets, or service endpoints; examples from the scan include Extension/Info.plist.
- Review changes touching mobile permissions or privacy-sensitive device data; examples from the scan include Extension/ExtensionProvider.swift, Extension/Info.plist, Extension/main.swift, GarethVideoCam/ContentView.swift, and 5 more.
- Review changes touching file, media, JSON, XML, CSV, OCR, or data parsing; examples from the scan include .github/workflows/macos-build.yml, Extension/ExtensionProvider.swift, Extension/Info.plist, scripts/validate_project.py.
- Review changes touching shell execution, subprocess, or dynamic evaluation; examples from the scan include scripts/test_scan_build_log.py.
- Review changes touching database, model, or persistence code; examples from the scan include Extension/ExtensionProvider.swift, scripts/collect_runtime_diagnostics.sh, scripts/validate_project.py.

## Maintenance Notes

- This looks like an Apple platform project or sample. Xcode, Swift, CocoaPods, and deployment target versions may need to match the original project era.
- See `SECURITY.md` for vulnerability reporting and safe research guidance.
- See `VISION.md` for project direction and contribution guardrails.

## Contributing

Keep changes small and tied to the project that is already present in this repository. For code changes, document the toolchain used, avoid committing generated dependency directories or local configuration, and update this README when setup or verification steps change.

## Existing Project Notes

Prior README summary:

> Gareth Mac Virtual Camera <!-- README-OVERVIEW-IMAGE --> A macOS CoreMediaIO camera extension packaged in a SwiftUI host app. The extension publishes the bundled `Extension/video.mp4` as a virtual camera named `Gareth Video Cam`. Current Target - Xcode 26.5 with the macOS 26.5 SDK - Swift 6 language mode - macOS Tahoe 26.5.1 as the current compatibility reference

