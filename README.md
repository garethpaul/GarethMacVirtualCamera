# GarethVideoCam

A macOS virtual camera extension that provides a system-wide virtual camera device for video streaming applications.

## Requirements

- **Xcode 26.0** or later
- **macOS 15.0** (Sequoia) or later
- **Swift 6.2**
- Valid Apple Developer account for code signing

## Features

- Virtual camera extension using CoreMediaIO
- System-wide camera device integration
- Video file streaming support
- SwiftUI-based management interface
- System extension installation and management

## Setup Instructions

### Prerequisites

1. **Install Xcode 26.0**: Download from the Mac App Store or Apple Developer portal
2. **Verify System Requirements**: Ensure you're running macOS 15.0 or later
3. **Developer Account**: A valid Apple Developer account is required for code signing

### Building the Project

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd GarethVideoCam
   ```

2. Open the project in Xcode:
   ```bash
   open GarethVideoCam.xcodeproj
   ```

3. Configure code signing:
   - Select the project in Xcode
   - Update the Development Team in both targets (GarethVideoCam and Extension)
   - Ensure bundle identifiers are unique to your team

4. Build and run the project:
   - Select the GarethVideoCam scheme
   - Build and run (⌘+R)

### Installation

1. Build and run the app
2. Click "Install" to install the system extension
3. Grant necessary permissions when prompted
4. The virtual camera will appear in video applications as "GarethVideoCam"

### Usage

- **Install Extension**: Click "Install" to add the virtual camera to the system
- **Uninstall Extension**: Click "Uninstall" to remove the virtual camera
- **Video Source**: Place your video file as `video.mp4` in the Extension bundle

## Architecture

- **GarethVideoCam**: Main SwiftUI application for extension management
- **Extension**: System extension providing the virtual camera functionality
- **ExtensionProvider**: Core implementation of the camera device using CoreMediaIO

## Compatibility

This project has been updated for:
- Xcode 26.0 with Swift 6.2
- Modern Swift concurrency patterns
- Latest macOS SDK features
- Updated build settings and deployment targets

## Troubleshooting

### Common Issues

1. **Extension Installation Fails**: Ensure the app is in `/Applications` folder
2. **Code Signing Issues**: Verify your Development Team is set correctly
3. **Permission Denied**: Check System Preferences > Privacy & Security > Extensions
4. **Camera Not Appearing**: Restart video applications after installation

### System Requirements

- The app must be in `/Applications` to install system extensions
- System Integrity Protection (SIP) must allow system extensions
- User approval is required for system extension installation

## Development Notes

- Uses CoreMediaIO framework for virtual camera implementation
- SwiftUI for modern macOS interface
- System Extensions framework for extension management
- AVFoundation for video processing

## License

[Add your license information here]
