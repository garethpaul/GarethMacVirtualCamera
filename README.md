# GarethMacVirtualCamera

A powerful macOS virtual camera application that creates a CoreMediaIO system extension for streaming video content as a virtual camera source. This application allows you to use any video file as a camera input for video conferencing, streaming, and other applications that require camera access.

## Features

- 🎥 **Virtual Camera**: Creates a system-wide virtual camera that appears in all camera-compatible applications
- 📹 **Video Streaming**: Streams any MP4 video file in a continuous loop
- 🔄 **Seamless Looping**: Automatically restarts video playback when it reaches the end
- 📱 **High Quality**: Supports 1080p HD video streaming at 30 FPS
- ⚡ **Performance Optimized**: Uses CoreMediaIO framework for efficient video processing
- 🛡️ **System Integration**: Implemented as a macOS System Extension for robust operation
- 🎛️ **SwiftUI Interface**: Modern, native macOS user interface
- 🔒 **Privacy Focused**: All video processing happens locally on your device

## Technical Overview

### Architecture

The application consists of two main components:

1. **Main Application** (`GarethVideoCam/`):
   - SwiftUI-based user interface
   - System extension management
   - User interaction and controls

2. **System Extension** (`Extension/`):
   - CoreMediaIO extension provider
   - Video streaming engine
   - AVFoundation-based video processing

### Key Technologies

- **CoreMediaIO**: Apple's framework for creating virtual cameras and audio devices
- **AVFoundation**: Video file reading and processing
- **SwiftUI**: Modern declarative UI framework
- **System Extensions**: macOS's secure extension architecture
- **CoreVideo**: Low-level video processing and pixel buffer management

## Installation

### Prerequisites

- **macOS 14.0 or later** (Sonoma)
- **Xcode 14.0 or later**
- **Apple Developer Account** (for code signing)
- **Swift 5.0 or later**

### System Requirements

- Intel Mac or Apple Silicon Mac
- Administrator privileges for system extension installation
- Camera permissions for the application

### Installation Steps

#### 1. Clone the Repository

```bash
git clone <repository-url>
cd GarethMacVirtualCamera
```

#### 2. Open in Xcode

```bash
open GarethVideoCam.xcodeproj
```

#### 3. Configure Code Signing

1. Select the `GarethVideoCam` project in the navigator
2. Under "Signing & Capabilities" for both targets:
   - **GarethVideoCam**: Set your Team and Bundle Identifier
   - **Extension**: Set your Team and Bundle Identifier
3. Ensure both targets have valid provisioning profiles

#### 4. Build and Run

1. Select the `GarethVideoCam` scheme
2. Choose your target device (Mac)
3. Click **Run** (⌘R) or **Product → Run**

#### 5. System Extension Installation

When you first run the application:

1. The app will request permission to install a system extension
2. Go to **System Preferences → Privacy & Security → General**
3. Click **Allow** next to the blocked system extension
4. You may need to restart the application after allowing the extension

#### 6. Camera Permissions

Grant camera permissions when prompted:
- Go to **System Preferences → Privacy & Security → Camera**
- Enable access for **GarethVideoCam**

### Verification

After installation, verify the virtual camera is working:

1. Open any video conferencing app (Zoom, Teams, FaceTime, etc.)
2. Go to camera settings
3. Look for "GarethVideoCam" in the camera source list
4. Select it to use the virtual camera

### Troubleshooting

#### System Extension Issues

If the system extension fails to load:

```bash
# Check system extension status
systemextensionsctl list

# Reset system extensions (if needed)
systemextensionsctl reset
```

#### Build Issues

- Ensure your development team is set correctly
- Check that all bundle identifiers are unique
- Verify macOS deployment target is set to 14.0 or later

#### Permission Issues

- Check **System Preferences → Privacy & Security → Camera**
- Check **System Preferences → Privacy & Security → General** for blocked extensions
- Restart the application after granting permissions

### Development Setup

For developers wanting to modify the code:

1. The main app is in `GarethVideoCam/`
2. The system extension code is in `Extension/`
3. Video file should be placed in both directories as `video.mp4`
4. Modify `ExtensionProvider.swift` to customize video streaming behavior

### Uninstallation

To remove the application and system extension:

1. Quit the GarethVideoCam application
2. Delete the app from Applications folder
3. Remove the system extension:
   ```bash
   systemextensionsctl uninstall <TEAM_ID> com.gareth.GarethVideoCam.Extension
   ```

## Usage

Once installed, the virtual camera will appear as "GarethVideoCam" in any application that accesses camera sources. The extension streams the bundled `video.mp4` file in a loop at 1080p resolution and 30 FPS.

### Compatible Applications

The virtual camera works with any application that supports camera input, including:

- **Video Conferencing**: Zoom, Microsoft Teams, Google Meet, Skype, FaceTime
- **Streaming Software**: OBS Studio, Streamlabs, XSplit
- **Social Media**: Discord, Slack, WhatsApp Web
- **Development Tools**: Browser-based video testing, WebRTC applications
- **Creative Software**: Any app with camera input support

### Basic Usage Steps

1. **Launch the Application**: Open GarethVideoCam from your Applications folder
2. **Activate Extension**: Click the activation button to start the system extension
3. **Select in Target App**: Open your video application and select "GarethVideoCam" as the camera source
4. **Enjoy**: Your video file will now stream as your camera input

## Advanced Configuration

### Custom Video Files

To use your own video file:

1. **Prepare Your Video**:
   - Format: MP4 (H.264 codec recommended)
   - Resolution: Any resolution (will be scaled to 1920x1080)
   - Frame Rate: 30 FPS recommended for best performance
   - Duration: Any length (will loop automatically)

2. **Replace the Video File**:
   ```bash
   # Navigate to the app bundle
   cd /Applications/GarethVideoCam.app/Contents/Resources/
   
   # Backup original (optional)
   mv video.mp4 video_original.mp4
   
   # Copy your video file
   cp /path/to/your/video.mp4 video.mp4
   ```

3. **Rebuild Extension** (for development):
   - Replace `video.mp4` in both `GarethVideoCam/` and `Extension/` directories
   - Rebuild the project in Xcode

### Performance Tuning

The application includes several performance optimizations:

- **Metal Compatibility**: Pixel buffers are Metal-compatible for GPU acceleration
- **Efficient Memory Management**: Uses CVPixelBufferPool for memory reuse
- **Optimized Frame Rate**: Configurable frame rate (default: 30 FPS)
- **Background Processing**: Video processing happens on dedicated dispatch queues

### Technical Configuration

Key parameters that can be modified in `ExtensionProvider.swift`:

```swift
// Video dimensions (default: 1920x1080)
let dims = CMVideoDimensions(width: 1920, height: 1080)

// Frame rate (default: 30 FPS)
let kFrameRate: Int = 30

// Pixel format (default: 420YpCbCr8BiPlanarFullRange)
kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
```

## Development

### Project Structure

```
GarethMacVirtualCamera/
├── GarethVideoCam/              # Main application
│   ├── GarethVideoCam.swift     # App entry point
│   ├── ContentView.swift        # Main UI
│   ├── Assets.xcassets/         # App assets
│   ├── Entitlements.entitlements # App permissions
│   └── video.mp4               # Video file
├── Extension/                   # System extension
│   ├── ExtensionProvider.swift  # Core extension logic
│   ├── main.swift              # Extension entry point
│   ├── Info.plist              # Extension metadata
│   ├── Extension.entitlements   # Extension permissions
│   └── video.mp4               # Video file (copy)
└── GarethVideoCam.xcodeproj/   # Xcode project
```

### Key Classes and Components

#### ExtensionDeviceSource
- Main device source class
- Manages video streaming and asset reading
- Handles frame timing and presentation timestamps
- Provides looping functionality

#### ExtensionStreamSource
- Stream source implementation
- Manages stream properties and format
- Handles client authorization
- Controls stream start/stop operations

#### ExtensionProviderSource
- Top-level provider source
- Manages device registration
- Handles client connections
- Provides provider properties

### Building from Source

1. **Clone and Setup**:
   ```bash
   git clone <repository-url>
   cd GarethMacVirtualCamera
   open GarethVideoCam.xcodeproj
   ```

2. **Configure Signing**:
   - Set your development team for both targets
   - Update bundle identifiers to be unique
   - Ensure proper entitlements are configured

3. **Build Configuration**:
   - Debug: Includes debug symbols and logging
   - Release: Optimized for distribution

4. **Testing**:
   - Use Xcode's built-in testing tools
   - Test with various video applications
   - Monitor system extension status with `systemextensionsctl list`

### Contributing

We welcome contributions! Here's how to get started:

1. **Fork the Repository**: Create your own fork on GitHub
2. **Create a Branch**: `git checkout -b feature/your-feature-name`
3. **Make Changes**: Implement your feature or bug fix
4. **Test Thoroughly**: Ensure your changes work across different macOS versions
5. **Submit a Pull Request**: Describe your changes and their benefits

#### Development Guidelines

- Follow Swift coding conventions
- Add comments for complex video processing logic
- Test on both Intel and Apple Silicon Macs
- Ensure compatibility with macOS 14.0+
- Update documentation for any API changes

#### Common Development Tasks

- **Adding New Video Formats**: Modify pixel format settings in `ExtensionProvider.swift`
- **Changing Resolution**: Update `CMVideoDimensions` in the device source
- **Adjusting Frame Rate**: Modify `kFrameRate` constant
- **Adding UI Features**: Extend `ContentView.swift` with SwiftUI components

## Troubleshooting

### Common Issues and Solutions

#### "System Extension Blocked" Error
**Problem**: macOS blocks the system extension installation.
**Solution**: 
1. Go to System Preferences → Privacy & Security → General
2. Click "Allow" next to the blocked extension
3. Restart the application

#### Camera Not Appearing in Applications
**Problem**: Virtual camera doesn't show up in camera selection.
**Solution**:
1. Ensure the system extension is loaded: `systemextensionsctl list`
2. Restart the target application
3. Check camera permissions in System Preferences

#### Video Playback Issues
**Problem**: Video appears corrupted or doesn't play smoothly.
**Solution**:
1. Verify video file format (MP4 with H.264)
2. Check video resolution and frame rate
3. Monitor system resources and CPU usage

#### Build Errors
**Problem**: Project fails to build in Xcode.
**Solution**:
1. Clean build folder (⇧⌘K)
2. Verify code signing settings
3. Check macOS deployment target (14.0+)
4. Ensure all dependencies are available

### Advanced Troubleshooting

#### System Extension Debugging

```bash
# List all system extensions
systemextensionsctl list

# Check extension status
systemextensionsctl list | grep GarethVideoCam

# Reset all system extensions (use with caution)
systemextensionsctl reset

# View system logs
log stream --predicate 'subsystem == "com.garethpaul.GarethVideoCam"'
```

#### Performance Monitoring

```bash
# Monitor CPU usage
top -pid $(pgrep GarethVideoCam)

# Check memory usage
vmmap $(pgrep GarethVideoCam)

# Monitor system extension activity
sudo fs_usage -w -f filesys GarethVideoCam
```

## License

This project is available under the MIT License. See the LICENSE file for more details.

## Support

If you encounter issues or have questions:

1. Check the troubleshooting section above
2. Search existing GitHub issues
3. Create a new issue with detailed information about your problem
4. Include system information (macOS version, hardware, etc.)

## Acknowledgments

- Built using Apple's CoreMediaIO framework
- Inspired by the need for flexible virtual camera solutions on macOS
- Thanks to the Swift and macOS development community
