# GarethMacVirtualCamera

A macOS virtual camera application that creates a system extension for streaming video content as a virtual camera source.

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
