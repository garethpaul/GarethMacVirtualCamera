# GarethVideoCam - Virtual Camera for macOS

GarethVideoCam is a macOS virtual camera application that creates a virtual camera device using a CoreMediaIO system extension. This allows you to stream video content (like an MP4 file) as a virtual camera source that can be used in video conferencing applications, streaming software, and other applications that support camera input.

## Features

- Creates a virtual camera device on macOS
- Streams video content from an MP4 file
- 1080p HD video support at 30fps
- System extension architecture for reliable operation
- Simple SwiftUI interface for installation and management

## System Requirements

- macOS 10.15 (Catalina) or later
- Xcode 13.0 or later (for building from source)
- Developer account for code signing (if distributing)
- Administrator privileges for system extension installation

## Installation

### Option 1: Build from Source (Recommended)

1. **Clone or download the repository**
   ```bash
   git clone <repository-url>
   cd GarethVideoCam
   ```

2. **Open the project in Xcode**
   ```bash
   open GarethVideoCam.xcodeproj
   ```

3. **Configure code signing**
   - Select the project in Xcode's navigator
   - Choose your development team for both the app and extension targets
   - Ensure both `GarethVideoCam` and `Extension` targets have valid signing certificates

4. **Build the application**
   - Select the `GarethVideoCam` scheme
   - Choose `Product > Build` or press `⌘+B`

5. **Run the application**
   - Press `⌘+R` to run the app
   - The app will open with Install/Uninstall buttons

6. **Install the system extension**
   - Click the "Install" button in the app
   - You may see a system dialog asking for permission to install the extension
   - Go to **System Preferences > Security & Privacy > General**
   - Click "Allow" next to the blocked system extension
   - The extension should now be installed and active

### Option 2: Pre-built Application

If you have a pre-built `.app` file:

1. **Move the app to Applications folder**
   ```bash
   sudo cp -R GarethVideoCam.app /Applications/
   ```

2. **Launch the application**
   ```bash
   open /Applications/GarethVideoCam.app
   ```

3. **Follow steps 6 from Option 1** to install the system extension

## Usage

1. **Install the extension** using the app's "Install" button
2. **Open any video application** that supports camera input (Zoom, Teams, OBS, etc.)
3. **Select "GarethVideoCam"** as your camera source
4. The virtual camera will stream the bundled video content

### Customizing Video Content

To use your own video file:

1. Replace `video.mp4` in both the main app bundle and extension bundle
2. Ensure the video file is named exactly `video.mp4`
3. Rebuild and reinstall the application
4. The video should be in a compatible format (H.264 recommended)

## Troubleshooting

### Extension Installation Issues

**"Extension blocked" message:**
- Go to System Preferences > Security & Privacy > General
- Click "Allow" next to the GarethVideoCam extension

**"Container App for Extension has to be in /Applications":**
- Move the app to the Applications folder before installing the extension

**Code signing issues:**
- Ensure you have a valid developer account
- Check that both app and extension targets are properly signed
- Try cleaning the build folder (`⌘+Shift+K`) and rebuilding

### Virtual Camera Not Appearing

1. **Restart video applications** after installing the extension
2. **Check system extension status:**
   ```bash
   systemextensionsctl list
   ```
3. **Reset system extension if needed:**
   - Uninstall using the app's "Uninstall" button
   - Restart your Mac
   - Reinstall the extension

### Performance Issues

- Ensure your Mac meets the minimum system requirements
- Close unnecessary applications while using the virtual camera
- Check Activity Monitor for high CPU usage

## Uninstalling

1. **Open GarethVideoCam app**
2. **Click "Uninstall" button**
3. **Restart your Mac** (recommended)
4. **Delete the app** from Applications folder if desired

## Development

### Project Structure

- `GarethVideoCam/` - Main SwiftUI application
- `Extension/` - CoreMediaIO system extension
- `video.mp4` - Sample video content (in both bundles)

### Key Components

- **ExtensionProvider.swift** - Main system extension logic
- **ContentView.swift** - SwiftUI interface for installation
- **SystemExtensionRequestManager** - Handles extension installation/removal

### Building for Distribution

1. Configure proper code signing with your developer account
2. Archive the application (`Product > Archive`)
3. Export for distribution outside the App Store
4. Notarize the application for macOS Gatekeeper compatibility

## License

[Add your license information here]

## Support

[Add support contact information or issue tracking details here]
