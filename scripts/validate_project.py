#!/usr/bin/env python3
import plistlib
import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_GROUP = "$(TeamIdentifierPrefix)com.garethpaul.GarethVideoCam"
APP_BUNDLE_ID = "com.garethpaul.GarethVideoCam"
EXTENSION_BUNDLE_ID = "com.garethpaul.GarethVideoCam.Extension"
LEGACY_EXTENSION_BUNDLE_ID = "com.gareth.GarethVideoCam.Extension"


def load_plist(relative_path):
    with (ROOT / relative_path).open("rb") as file:
        return plistlib.load(file)


def load_json(relative_path):
    with (ROOT / relative_path).open("r", encoding="utf-8") as file:
        return json.load(file)


def png_dimensions(path):
    with path.open("rb") as file:
        header = file.read(24)

    if header[:8] != b"\x89PNG\r\n\x1a\n":
        return None

    width, height = struct.unpack(">II", header[16:24])
    return width, height


def mp4_video_metadata(path):
    data = path.read_bytes()
    video_metadata = {"dimensions": None, "frame_rate": None}

    def iter_atoms(start, end):
        offset = start
        while offset + 8 <= end:
            atom_size = struct.unpack(">I", data[offset:offset + 4])[0]
            atom_type = data[offset + 4:offset + 8].decode("latin1")
            header_size = 8

            if atom_size == 1:
                if offset + 16 > end:
                    return
                atom_size = struct.unpack(">Q", data[offset + 8:offset + 16])[0]
                header_size = 16
            elif atom_size == 0:
                atom_size = end - offset

            if atom_size < header_size or offset + atom_size > end:
                return

            yield atom_type, offset + header_size, offset + atom_size
            offset += atom_size

    def parse_mdhd(payload_start, payload_end):
        version = data[payload_start]

        if version == 1:
            timescale_offset = payload_start + 20
            duration_offset = payload_start + 24
            if duration_offset + 8 > payload_end:
                return None
            return (
                struct.unpack(">I", data[timescale_offset:timescale_offset + 4])[0],
                struct.unpack(">Q", data[duration_offset:duration_offset + 8])[0],
            )

        timescale_offset = payload_start + 12
        duration_offset = payload_start + 16
        if duration_offset + 4 > payload_end:
            return None
        return (
            struct.unpack(">I", data[timescale_offset:timescale_offset + 4])[0],
            struct.unpack(">I", data[duration_offset:duration_offset + 4])[0],
        )

    def parse_hdlr(payload_start, payload_end):
        if payload_start + 12 > payload_end:
            return None
        return data[payload_start + 8:payload_start + 12].decode("latin1")

    def parse_stts(payload_start, payload_end):
        if payload_start + 8 > payload_end:
            return []

        entry_count = struct.unpack(">I", data[payload_start + 4:payload_start + 8])[0]
        entries = []
        entry_offset = payload_start + 8

        for _ in range(entry_count):
            if entry_offset + 8 > payload_end:
                break
            entries.append(struct.unpack(">II", data[entry_offset:entry_offset + 8]))
            entry_offset += 8

        return entries

    def find_stts_entries(start, end):
        for atom_type, payload_start, payload_end in iter_atoms(start, end):
            if atom_type == "stts":
                return parse_stts(payload_start, payload_end)
            if atom_type in {"minf", "stbl"}:
                nested_entries = find_stts_entries(payload_start, payload_end)
                if nested_entries:
                    return nested_entries
        return []

    def parse_stsd_dimensions(payload_start, payload_end):
        for atom_type, sample_start, sample_end in iter_atoms(payload_start + 8, payload_end):
            if atom_type in {"avc1", "hvc1", "hev1", "mp4v"} and sample_start + 28 <= sample_end:
                return struct.unpack(">HH", data[sample_start + 24:sample_start + 28])
        return None

    for atom_type, payload_start, payload_end in iter_atoms(0, len(data)):
        if atom_type != "moov":
            continue

        for track_type, track_start, track_end in iter_atoms(payload_start, payload_end):
            if track_type != "trak":
                continue

            for media_type, media_start, media_end in iter_atoms(track_start, track_end):
                if media_type != "mdia":
                    continue

                handler = None
                timescale = None
                sample_durations = []

                for media_atom_type, atom_start, atom_end in iter_atoms(media_start, media_end):
                    if media_atom_type == "mdhd":
                        mdhd = parse_mdhd(atom_start, atom_end)
                        if mdhd is not None:
                            timescale, _ = mdhd
                    elif media_atom_type == "hdlr":
                        handler = parse_hdlr(atom_start, atom_end)
                    elif media_atom_type == "minf":
                        sample_durations = find_stts_entries(atom_start, atom_end)
                        for minf_atom_type, minf_start, minf_end in iter_atoms(atom_start, atom_end):
                            if minf_atom_type == "stbl":
                                for stbl_atom_type, stbl_start, stbl_end in iter_atoms(minf_start, minf_end):
                                    if stbl_atom_type == "stsd":
                                        video_dimensions = parse_stsd_dimensions(stbl_start, stbl_end)
                                        if video_dimensions is not None:
                                            video_metadata["dimensions"] = video_dimensions

                if handler == "vide" and timescale and len(sample_durations) == 1:
                    _, sample_delta = sample_durations[0]
                    if sample_delta and timescale % sample_delta == 0:
                        video_metadata["frame_rate"] = timescale // sample_delta

    return video_metadata


def expected_icon_pixel_size(image):
    point_size = int(image.get("size", "0x0").split("x", maxsplit=1)[0])
    scale = int(image.get("scale", "1x").removesuffix("x"))
    return point_size * scale


def require(condition, message, failures):
    if not condition:
        failures.append(message)


def main():
    failures = []

    app_entitlements = load_plist("GarethVideoCam/Entitlements.entitlements")
    extension_entitlements = load_plist("Extension/Extension.entitlements")
    extension_info = load_plist("Extension/Info.plist")
    app_icon = load_json("GarethVideoCam/Assets.xcassets/AppIcon.appiconset/Contents.json")
    accent_color = load_json("GarethVideoCam/Assets.xcassets/AccentColor.colorset/Contents.json")

    require(app_entitlements.get("com.apple.developer.system-extension.install") is True,
            "host app is missing the System Extension entitlement",
            failures)
    require(app_entitlements.get("com.apple.security.app-sandbox") is True,
            "host app should remain sandboxed",
            failures)
    require(extension_entitlements.get("com.apple.security.app-sandbox") is True,
            "extension should remain sandboxed",
            failures)
    require(APP_GROUP in app_entitlements.get("com.apple.security.application-groups", []),
            "host app is missing the shared app group",
            failures)
    require(APP_GROUP in extension_entitlements.get("com.apple.security.application-groups", []),
            "extension is missing the shared app group",
            failures)
    require("com.apple.developer.system-extension.install" not in extension_entitlements,
            "extension should not carry the host-only System Extension entitlement",
            failures)

    cmio_info = extension_info.get("CMIOExtension", {})
    require(cmio_info.get("CMIOExtensionMachServiceName") == "$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)",
            "extension mach service name must derive from PRODUCT_BUNDLE_IDENTIFIER",
            failures)
    require("NSSystemExtensionUsageDescription" in extension_info,
            "extension Info.plist is missing NSSystemExtensionUsageDescription",
            failures)

    video_path = ROOT / "Extension/video.mp4"
    require(video_path.exists() and video_path.stat().st_size > 0,
            "Extension/video.mp4 is missing or empty",
            failures)
    video_metadata = mp4_video_metadata(video_path) if video_path.exists() else {}
    video_dimensions = video_metadata.get("dimensions")
    video_frame_rate = video_metadata.get("frame_rate")
    require(video_dimensions is not None,
            "Extension/video.mp4 should expose parseable video dimensions",
            failures)
    require(video_frame_rate is not None,
            "Extension/video.mp4 should expose a constant parseable video frame rate",
            failures)
    require(not (ROOT / "GarethVideoCam/video.mp4").exists(),
            "duplicate host-app video.mp4 should not be checked in",
            failures)

    icon_filenames = [image.get("filename") for image in app_icon.get("images", [])]
    require(len([filename for filename in icon_filenames if filename]) == 10,
            "app icon catalog should include concrete PNG files for all macOS icon slots",
            failures)
    for icon_filename in icon_filenames:
        if icon_filename:
            icon_entry = next(image for image in app_icon.get("images", []) if image.get("filename") == icon_filename)
            icon_path = ROOT / "GarethVideoCam/Assets.xcassets/AppIcon.appiconset" / icon_filename
            require(icon_path.exists() and icon_path.stat().st_size > 0,
                    f"app icon file is missing or empty: {icon_filename}",
                    failures)
            if icon_path.exists():
                expected_size = expected_icon_pixel_size(icon_entry)
                require(png_dimensions(icon_path) == (expected_size, expected_size),
                        f"app icon file has incorrect pixel dimensions: {icon_filename}",
                        failures)

    accent_colors = accent_color.get("colors", [])
    require(any("color" in color for color in accent_colors),
            "accent color catalog should define an explicit color",
            failures)

    project_text = (ROOT / "GarethVideoCam.xcodeproj/project.pbxproj").read_text()
    app_entry_source = (ROOT / "GarethVideoCam/GarethVideoCam.swift").read_text()
    host_source = (ROOT / "GarethVideoCam/ContentView.swift").read_text()
    extension_source = (ROOT / "Extension/ExtensionProvider.swift").read_text()
    extension_main_source = (ROOT / "Extension/main.swift").read_text()
    readme_text = (ROOT / "README.md").read_text()
    build_log_scanner_source = (ROOT / "scripts/scan_build_log.py").read_text()
    build_log_scanner_test_source = (ROOT / "scripts/test_scan_build_log.py").read_text()
    runtime_diagnostics_source = (ROOT / "scripts/collect_runtime_diagnostics.sh").read_text()
    require(f"PRODUCT_BUNDLE_IDENTIFIER = {APP_BUNDLE_ID};" in project_text,
            "project is missing the host app bundle identifier",
            failures)
    require(f"PRODUCT_BUNDLE_IDENTIFIER = {EXTENSION_BUNDLE_ID};" in project_text,
            "project is missing the extension bundle identifier",
            failures)
    require(LEGACY_EXTENSION_BUNDLE_ID not in project_text,
            "project still references the legacy extension bundle identifier",
            failures)
    require("LastUpgradeCheck = 2600;" in project_text,
            "project is not marked as upgraded for Xcode 26",
            failures)
    require(project_text.count("ENABLE_HARDENED_RUNTIME = YES;") >= 4,
            "all app and extension configurations should enable hardened runtime",
            failures)
    require("$(SYSTEM_EXTENSIONS_FOLDER_PATH)" in project_text and "Embed System Extensions" in project_text,
            "project should embed the extension in the app SystemExtensions folder",
            failures)
    require('"Gareth Video Cam publishes a virtual camera stream."' in project_text and '"Gareth Video Cam Extension"' in project_text and '"Gareth Video Cam publishes the bundled video as a virtual camera stream."' in project_text,
            "project should use product-specific generated Info.plist display and privacy strings",
            failures)
    require('explicitFileType = "wrapper.system-extension";' in project_text and 'productType = "com.apple.product-type.system-extension";' in project_text,
            "project should keep the extension configured as a system extension product",
            failures)
    require("video.mp4 in Resources" in project_text,
            "project should bundle Extension/video.mp4 in the extension resources",
            failures)
    marketing_versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", project_text))
    build_versions = set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project_text))
    require(len(marketing_versions) == 1,
            "app and extension marketing versions should stay aligned",
            failures)
    require(len(build_versions) == 1,
            "app and extension build versions should stay aligned",
            failures)
    require("tracks(withMediaType:" not in extension_source and "AVAsset(url:" not in extension_source,
            "extension should use modern asynchronous AVAsset loading APIs",
            failures)
    require("streamGeneration" in extension_source and "isCurrentStreamPreparation" in extension_source,
            "extension should ignore stale asynchronous stream preparation completions",
            failures)
    require("advanceLoopTiming(by: assetDuration)" in extension_source and "private func advanceLoopTiming(by duration: CMTime)" in extension_source,
            "extension should advance timestamps explicitly at bundled-video loop boundaries",
            failures)
    if video_dimensions is not None:
        video_width, video_height = video_dimensions
        require(f"CMVideoDimensions(width: {video_width}, height: {video_height})" in extension_source,
                "extension stream dimensions should match the bundled video dimensions",
                failures)
    if video_frame_rate is not None:
        require(f"static let frameRate: Int32 = {video_frame_rate}" in extension_source,
                "extension stream frame rate should match the bundled video frame rate",
                failures)
    require("validateVideoTrack(naturalSize:" in extension_source and "preferredTransform:" in extension_source and "displayDimensions(naturalSize:" in extension_source and "videoTrack.load(.naturalSize)" in extension_source and "videoTrack.load(.preferredTransform)" in extension_source and "videoTrack.load(.nominalFrameRate)" in extension_source,
            "extension should validate bundled-video display dimensions and frame rate before streaming",
            failures)
    require("unexpectedVideoDimensions" in extension_source and "unexpectedVideoFrameRate" in extension_source,
            "extension should report actionable bundled-video track mismatches",
            failures)
    require("Unable to loop the bundled video: \\(error.localizedDescription" in extension_source,
            "extension should log loop restart failures with actionable error details",
            failures)
    require("CMTimeConvertScale(hostTime" in extension_source and "CMTimeGetSeconds(hostTime)" not in extension_source,
            "extension should convert host timestamps with integer CoreMedia scaling",
            failures)
    require("kCVPixelBufferWidthKey" in extension_source and "kCVPixelBufferHeightKey" in extension_source and "kCVPixelBufferIOSurfacePropertiesKey" in extension_source,
            "extension asset reader should produce pixel buffers matching the advertised stream dimensions",
            failures)
    require("isPreparingStream" not in extension_source,
            "extension should not keep unused stream preparation state",
            failures)
    require("fatalError(" not in extension_source and "fatalError(" not in extension_main_source,
            "extension startup should log initialization failures instead of crashing with fatalError",
            failures)
    require("Failed to start camera extension service" in extension_main_source and "exit(EXIT_FAILURE)" in extension_main_source,
            "extension entry point should log startup failures before exiting",
            failures)
    require("invalidActiveFormatIndex" in extension_source and "throw CameraExtensionError.invalidActiveFormatIndex" in extension_source,
            "extension stream should reject unsupported active format indices",
            failures)
    require("streamProperties.activeFormatIndex = activeFormatIndex" in extension_source,
            "extension stream should report the stored active format index",
            failures)
    require("invalidFrameDuration" in extension_source and "throw CameraExtensionError.invalidFrameDuration" in extension_source and "streamProperties.frameDuration" in extension_source,
            "extension stream should reject unsupported frame-duration requests",
            failures)
    require("validFrameDurations: [CameraExtensionConfiguration.frameDuration]" in extension_source,
            "extension stream should advertise the fixed frame duration it enforces",
            failures)
    require("case needsApplicationLocation" in host_source and "case needsBundleIdentifier" in host_source and "canSubmitSystemExtensionRequests" in host_source,
            "host app should model the /Applications and host bundle identifier requirements before submitting system-extension requests",
            failures)
    require("import Security" in host_source and "CodeSigningStatus" in host_source and "SecStaticCodeCheckValidityWithErrors" in host_source,
            "host app should check code-signing validity before submitting system-extension requests",
            failures)
    require("appCodeSigningStatus" in host_source and "extensionCodeSigningStatus" in host_source and "Extension Signing Required" in host_source and "The embedded system extension code signature is valid." in host_source,
            "host app should validate both the container app and embedded system-extension signatures before submitting requests",
            failures)
    require("SecCodeCopySigningInformation" in host_source and "kSecCodeInfoTeamIdentifier" in host_source and "signingTeamReadinessDetail" in host_source and "Team Identifier Required" in host_source,
            "host app should verify matching app and embedded system-extension signing team identifiers before submitting requests",
            failures)
    require("requiredSystemExtensionInstallEntitlement" in host_source and "kSecCodeInfoEntitlementsDict" in host_source and "hasEnabledEntitlement" in host_source and "appEntitlementReadinessDetail" in host_source and "Entitlement Required" in host_source,
            "host app should verify the signed app has the System Extension entitlement before submitting requests",
            failures)
    require("case needsSigning" in host_source and "requestReadinessMessage" in host_source and "App Signature" in host_source and "Extension Signature" in host_source,
            "host app should surface signing readiness in state, controls, and details",
            failures)
    require("requestReadinessStatus" in host_source and "requestReadinessDetail" in host_source and "Request Readiness" in host_source and "Readiness Detail" in host_source,
            "host app should show and copy exact system-extension request readiness blockers",
            failures)
    require("struct ReadinessCheck" in host_source and "readinessChecks" in host_source and "ReadinessPanel(manager: manager)" in host_source and "ReadinessRow" in host_source and "Team ID Match" in host_source and "Readiness Checks:" in host_source,
            "host app should show and copy a compact readiness checklist for activation gates",
            failures)
    require("applicationIdentifierReadinessDetail" in host_source and "applicationBundleIdentifierStatus" in host_source and "App Bundle ID Check" in host_source and "App Identifier Required" in host_source,
            "host app should block requests when the host bundle identifier does not match the expected identifier",
            failures)
    require("lastFailureDetail" in host_source and "Last Failure" in host_source and "No failure recorded." in host_source and "Readiness Failed" in host_source and "Request Failed" in host_source,
            "host app should preserve the last readiness or request failure in details and copied diagnostics",
            failures)
    require(".disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)" in host_source,
            "host app should disable install controls when system-extension requests cannot be submitted",
            failures)
    require("private var extensionIdentity" in host_source and "private var requestButtons" in host_source and "private var installButton" in host_source and "private var uninstallButton" in host_source,
            "host app should keep install actions responsive at narrower window widths",
            failures)
    require("case .locatingExtension, .activating, .needsApproval, .deactivating, .requiresRestart:" in host_source,
            "host app should keep controls disabled while approval or restart is pending",
            failures)
    require("private enum RequestKind" in host_source and "pendingRequestKind = .activation" in host_source and "pendingRequestKind = .deactivation" in host_source,
            "host app should track whether the pending system-extension request is install or uninstall",
            failures)
    require("case deactivated" in host_source and "return .deactivated" in host_source and "Uninstall Completed" in host_source,
            "host app should report successful deactivation separately from activation",
            failures)
    require("case .completed:" in host_source and "case .willCompleteAfterReboot:" in host_source and "@unknown default:" in host_source and "switch result.rawValue" not in host_source,
            "host app should handle system-extension request results with typed enum cases",
            failures)
    require(f'expectedExtensionBundleIdentifier = "{EXTENSION_BUNDLE_ID}"' in host_source and "unexpectedBundleIdentifier" in host_source,
            "host app should verify the bundled system extension identifier before submitting requests",
            failures)
    require("videoPath" in host_source and "videoByteCount" in host_source and "Contents" in host_source and "Resources" in host_source and "video.mp4" in host_source and "fileExists(atPath: videoURL.path, isDirectory:" in host_source,
            "host app should capture bundled-video resource metadata from the embedded extension",
            failures)
    require("missingBundledVideoResource" in host_source and "emptyBundledVideoResource" in host_source and "bundledVideoByteCount" in host_source,
            "host app should fail readiness when the embedded extension video resource is missing or empty",
            failures)
    require("Bundled Video Path" in host_source and "Bundled Video Size" in host_source and "Video Path" in host_source and "Video Size" in host_source,
            "host app should show and copy bundled-video diagnostics",
            failures)
    require("nsError.domain" in host_source and "unknown code \\(errorCode)" in host_source,
            "host app should preserve system-extension failure domain and code diagnostics",
            failures)
    require("diagnosticSummary" in host_source and "NSPasteboard.general" in host_source and "Copy Diagnostics" in host_source,
            "host app should expose copyable diagnostics for activation troubleshooting",
            failures)
    require("diagnosticGeneratedAt" in host_source and "Generated At:" in host_source and "ISO8601DateFormatter" in host_source,
            "host app copied diagnostics should include an ISO-8601 generation timestamp",
            failures)
    require("didCopyDiagnostics" in host_source and "Diagnostics Copy Failed" in host_source,
            "host app should report clipboard failures when copying diagnostics",
            failures)
    require("applicationVersion" in host_source and "App Version" in host_source and "CFBundleShortVersionString" in host_source,
            "host app should show and copy app version diagnostics",
            failures)
    require("System Extension Entitlement" in host_source and "App System Extension Entitlement:" in host_source,
            "host app should show and copy app System Extension entitlement diagnostics",
            failures)
    require("expectedApplicationBundleIdentifier" in host_source and "applicationBundleIdentifier" in host_source and "Expected App ID" in host_source and "Actual App ID" in host_source and "App Bundle ID Check" in host_source and "Expected Extension ID" in host_source,
            "host app should show and copy expected and actual bundle identifier diagnostics",
            failures)
    require("func copyDiagnostics() {\n        refreshExtensionInfo()" in host_source,
            "host app should refresh readiness before copying diagnostics",
            failures)
    require("refreshStatus()" in host_source and "Status Refreshed" in host_source and "Button(action: manager.refreshStatus)" in host_source and "Refresh Status" in host_source,
            "host app should let users refresh extension and signing readiness in-place with activity feedback",
            failures)
    require("case .idle, .ready, .needsApplicationLocation, .needsBundleIdentifier, .needsSigning, .deactivated, .failed:" in host_source,
            "host app should let a successful refresh recover from stale readiness failures",
            failures)
    require("private struct DetailsActions" in host_source and "ViewThatFits(in: .horizontal)" in host_source,
            "host app should keep details actions responsive at narrower window widths",
            failures)
    require("private var titleLabel" in host_source and "private var valueText" in host_source,
            "host app should keep diagnostic detail rows responsive at narrower window widths",
            failures)
    require("private var activityTitle" in host_source and "private var activityTimestamp" in host_source,
            "host app should keep activity rows responsive at narrower window widths",
            failures)
    require(".frame(minWidth: 720, minHeight: 560)" in app_entry_source and ".windowResizability(.contentMinSize)" in app_entry_source,
            "host app should allow a compact but bounded resizable window",
            failures)
    require("activateFileViewerSelecting" in host_source and "Reveal App" in host_source,
            "host app should let users reveal the running app bundle in Finder",
            failures)
    require("revealBundledExtensionInFinder" in host_source and "canRevealBundledExtension" in host_source and "Reveal Extension" in host_source and "Extension Revealed" in host_source and ".disabled(!manager.canRevealBundledExtension)" in host_source,
            "host app should let users reveal the embedded system extension bundle in Finder only when it is loaded",
            failures)
    require("Submit a macOS system extension activation request." in host_source and "Refresh app, extension, signing, and readiness status." in host_source and "Copy the current readiness and diagnostics snapshot." in host_source,
            "host app action buttons should expose concise hover help",
            failures)
    require("openSystemSettings" in host_source and "System Settings" in host_source and "/System/Applications/System Settings.app" in host_source,
            "host app should provide a System Settings shortcut for extension approval",
            failures)
    require("didOpenSettings" in host_source and "System Settings Unavailable" in host_source,
            "host app should report System Settings launch failures",
            failures)
    require("CI-equivalent unsigned compile" in readme_text and "-target GarethVideoCam" in readme_text and "for configuration in Debug Release" in readme_text and "build-${configuration}.log" in readme_text and "./scripts/scan_build_log.py \"build-${configuration}.log\"" in readme_text,
            "README should document the CI-equivalent unsigned Debug and Release target builds with log scanning",
            failures)
    require("Runtime Activation" in readme_text and "valid Apple Developer signing identity" in readme_text,
            "README should document signed runtime activation requirements",
            failures)
    require("shows and copies a readiness checklist" in readme_text and "System Settings shortcut" in readme_text and "reveal the app and embedded extension in Finder" in readme_text and "diagnostics snapshot" in readme_text and "generation timestamp" in readme_text and "bundle identifiers" in readme_text and "host app bundle identifier does not match the expected identifier" in readme_text and "missing the System Extension entitlement" in readme_text and "bundled system extension signature is invalid" in readme_text and "Team IDs" in readme_text and "last recorded failure" in readme_text,
            "README should document the in-app approval and diagnostics actions",
            failures)
    require("collect_runtime_diagnostics.sh" in readme_text and "bundle versions" in readme_text and "bundled-video byte size, checksum, metadata" in readme_text and "expected application-location and bundle identifier checks" in readme_text and "matching Team IDs" in readme_text and "Gatekeeper assessment" in readme_text and "signed entitlements" in readme_text and "explicit host System Extension entitlement checks" in readme_text and "runtime-readiness summary" in readme_text and "systemextensionsctl" in readme_text and "unified-log window" in readme_text and "system-extension/CMIO log context" in readme_text,
            "README should document collecting runtime diagnostics on macOS",
            failures)
    require("ACTIONABLE_PATTERN" in build_log_scanner_source and "IGNORED_LINE_TOKEN_GROUPS" in build_log_scanner_source and "all(token.lower() in normalized_line" in build_log_scanner_source,
            "build-log scanner should fail on warnings while narrowly ignoring known Xcode AppIntents metadata noise",
            failures)
    require("enumerate(build_log, start=1)" in build_log_scanner_source and "{build_log_path}:{line_number}:" in build_log_scanner_source,
            "build-log scanner should print the build-log path and line number for actionable findings",
            failures)
    require("test_ignores_appintents_metadata_notice" in build_log_scanner_test_source and "test_fails_on_actionable_warning" in build_log_scanner_test_source and "test_fails_on_other_appintents_warning" in build_log_scanner_test_source and ":2: SwiftCompile warning: real source warning" in build_log_scanner_test_source,
            "build-log scanner should have regression coverage for ignored and actionable warnings",
            failures)
    require("codesign -d --entitlements :-" in runtime_diagnostics_source and "spctl --assess" in runtime_diagnostics_source and "systemextensionsctl list" in runtime_diagnostics_source and "Bundle short version:" in runtime_diagnostics_source and "Bundle build version:" in runtime_diagnostics_source and "CFBundleShortVersionString" in runtime_diagnostics_source and "CFBundleVersion" in runtime_diagnostics_source and "LOG_WINDOW" in runtime_diagnostics_source and "Bundled Video" in runtime_diagnostics_source and "VIDEO_PATH" in runtime_diagnostics_source and "Video resource exists:" in runtime_diagnostics_source and "Video byte size:" in runtime_diagnostics_source and "Video resource is empty:" in runtime_diagnostics_source and "Video SHA-256:" in runtime_diagnostics_source and "print_file_sha256" in runtime_diagnostics_source and "kMDItemPixelWidth" in runtime_diagnostics_source and "kMDItemPixelHeight" in runtime_diagnostics_source and "kMDItemDurationSeconds" in runtime_diagnostics_source and "Application Location Check" in runtime_diagnostics_source and "EXPECTED_APP_PATH" in runtime_diagnostics_source and "App path is inside /Applications:" in runtime_diagnostics_source and "App path matches expected app path:" in runtime_diagnostics_source and "Bundle Identifier Check" in runtime_diagnostics_source and "read_bundle_identifier" in runtime_diagnostics_source and "App bundle identifier matches:" in runtime_diagnostics_source and "Extension bundle identifier matches:" in runtime_diagnostics_source and "Signing Team Match" in runtime_diagnostics_source and "read_team_identifier" in runtime_diagnostics_source and "Team identifiers match:" in runtime_diagnostics_source and "Entitlement Check" in runtime_diagnostics_source and "HOST_SYSTEM_EXTENSION_ENTITLEMENT" in runtime_diagnostics_source and "has_boolean_entitlement" in runtime_diagnostics_source and "App System Extension entitlement present:" in runtime_diagnostics_source and "Extension carries host-only System Extension entitlement:" in runtime_diagnostics_source and "Runtime Readiness Summary" in runtime_diagnostics_source and "print_yes_no_unknown" in runtime_diagnostics_source and "Application location ready" in runtime_diagnostics_source and "App bundle identifier ready" in runtime_diagnostics_source and "App signature ready" in runtime_diagnostics_source and "App System Extension entitlement ready" in runtime_diagnostics_source and "Extension bundle identifier ready" in runtime_diagnostics_source and "Extension signature ready" in runtime_diagnostics_source and "Extension host-only entitlement absent" in runtime_diagnostics_source and "Signing Team match ready" in runtime_diagnostics_source and "Bundled video ready" in runtime_diagnostics_source and "systemextensionsd" in runtime_diagnostics_source and "com.apple.CoreMediaIO" in runtime_diagnostics_source,
            "runtime diagnostics script should collect labeled entitlements, entitlement readiness, readiness summary, Gatekeeper assessment, bundle versions, system-extension registration, configurable log windows, and recent app/system-extension logs",
            failures)

    scheme_path = ROOT / "GarethVideoCam.xcodeproj/xcshareddata/xcschemes/GarethVideoCam.xcscheme"
    scheme = ET.parse(scheme_path).getroot()
    require(scheme.attrib.get("LastUpgradeVersion") == "2600",
            "shared scheme is not marked as upgraded for Xcode 26",
            failures)

    scheme_text = scheme_path.read_text()
    require("/usr/bin/ditto" in scheme_text and "/Applications/${FULL_PRODUCT_NAME}" in scheme_text and "/bin/rm -rf" in scheme_text and "/Applications/*.app" in scheme_text and "<PreActions>" in scheme_text and 'FilePath = "/Applications/GarethVideoCam.app"' in scheme_text,
            "shared scheme should replace the app in /Applications with a guarded launch pre-action before system-extension testing",
            failures)

    workflow_path = ROOT / ".github/workflows/macos-build.yml"
    require(workflow_path.exists(),
            "macOS build workflow is missing",
            failures)
    if workflow_path.exists():
        workflow_text = workflow_path.read_text()
        require("runs-on: macos-26" in workflow_text,
                "macOS build workflow should run on the macOS 26 runner",
                failures)
        require("actions/checkout@v6" in workflow_text,
                "macOS build workflow should use a Node 24-capable checkout action",
                failures)
        require("Xcode_26.5" in workflow_text,
                "macOS build workflow should explicitly select Xcode 26.5",
                failures)
        require("./scripts/test_scan_build_log.py" in workflow_text,
                "macOS build workflow should test the build-log scanner",
                failures)
        require("bash -n ./scripts/collect_runtime_diagnostics.sh" in workflow_text,
                "macOS build workflow should syntax-check the runtime diagnostics script",
                failures)
        require("xcodebuild" in workflow_text and "CODE_SIGNING_ALLOWED=NO" in workflow_text,
                "macOS build workflow should perform an unsigned xcodebuild",
                failures)
        require("-target GarethVideoCam" in workflow_text,
                "macOS build workflow should build the app target without running scheme post-actions",
                failures)
        require("runner_arch=\"$(uname -m)\"" in workflow_text and "ARCHS=\"${runner_arch}\"" in workflow_text,
                "macOS build workflow should build the target for the runner architecture",
                failures)
        require("for configuration in Debug Release" in workflow_text,
                "macOS build workflow should build both Debug and Release configurations",
                failures)
        require("build-Debug.log" in workflow_text and "build-Release.log" in workflow_text,
                "macOS build workflow should capture separate Debug and Release logs",
                failures)
        require("./scripts/scan_build_log.py build-Debug.log" in workflow_text and "./scripts/scan_build_log.py build-Release.log" in workflow_text,
                "macOS build workflow should scan captured Debug and Release xcodebuild output",
                failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    print("Project validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
