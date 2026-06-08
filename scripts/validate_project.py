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
    video_metadata = {"dimensions": None, "frame_rate": None, "duration_seconds": None}

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
                media_duration = None
                sample_durations = []

                for media_atom_type, atom_start, atom_end in iter_atoms(media_start, media_end):
                    if media_atom_type == "mdhd":
                        mdhd = parse_mdhd(atom_start, atom_end)
                        if mdhd is not None:
                            timescale, media_duration = mdhd
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

                if handler == "vide" and timescale and media_duration is not None:
                    video_metadata["duration_seconds"] = media_duration / timescale

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
    video_duration_seconds = video_metadata.get("duration_seconds")
    require(video_dimensions is not None,
            "Extension/video.mp4 should expose parseable video dimensions",
            failures)
    require(video_frame_rate is not None,
            "Extension/video.mp4 should expose a constant parseable video frame rate",
            failures)
    require(video_duration_seconds is not None and video_duration_seconds > 0,
            "Extension/video.mp4 should expose a positive video duration",
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
    check_project_path = ROOT / "scripts/check_project.sh"
    check_project_source = check_project_path.read_text()
    build_unsigned_path = ROOT / "scripts/build_unsigned.sh"
    build_unsigned_source = build_unsigned_path.read_text()
    verify_build_products_path = ROOT / "scripts/verify_build_products.sh"
    verify_build_products_source = verify_build_products_path.read_text()
    verify_build_products_test_path = ROOT / "scripts/test_verify_build_products.sh"
    verify_build_products_test_source = verify_build_products_test_path.read_text()
    build_log_scanner_source = (ROOT / "scripts/scan_build_log.py").read_text()
    build_log_scanner_test_source = (ROOT / "scripts/test_scan_build_log.py").read_text()
    runtime_diagnostics_source = (ROOT / "scripts/collect_runtime_diagnostics.sh").read_text()
    runtime_diagnostics_test_path = ROOT / "scripts/test_collect_runtime_diagnostics.sh"
    runtime_diagnostics_test_source = runtime_diagnostics_test_path.read_text()
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
    require("Swift 6 language mode" in readme_text and project_text.count("SWIFT_VERSION = 6.0;") == 4 and "SWIFT_VERSION = 5.0;" not in project_text,
            "app and extension targets should use Swift 6 language mode",
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
    require("Ignoring stale stream preparation completion" in extension_source and "Ignoring stale stream preparation failure" in extension_source,
            "extension should log ignored stale asynchronous stream preparation results",
            failures)
    require("tooManyStreamingClients" in extension_source and "_streamingCounter < UInt32.max" in extension_source,
            "extension should guard the active streaming client counter from overflow",
            failures)
    require("Attached streaming client; active clients" in extension_source and "Detached streaming client; active clients" in extension_source,
            "extension should log multi-client streaming attach and detach counts",
            failures)
    require("Preparing stream with bundled video" in extension_source,
            "extension should log initial bundled-video stream preparation",
            failures)
    require("guard _timer == nil else" in extension_source and "Duplicate stream timer start ignored" in extension_source,
            "extension should keep stream timer startup idempotent",
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
    require("CMSampleBufferDataIsReady(sampleBuffer)" in extension_source and "Skipping sample buffer that is not ready" in extension_source,
            "extension should skip asset-reader sample buffers that are not ready",
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
    require("Camera extension service started" in extension_main_source,
            "extension entry point should log successful service startup before entering the run loop",
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
    require("timing.duration = CameraExtensionConfiguration.frameDuration" in extension_source and "if !timing.duration.flags.contains(.valid)" not in extension_source,
            "extension should retime every emitted sample to the advertised fixed frame duration",
            failures)
    require("case needsApplicationLocation" in host_source and "case needsBundleIdentifier" in host_source and "canSubmitSystemExtensionRequests" in host_source,
            "host app should model the /Applications and host bundle identifier requirements before submitting system-extension requests",
            failures)
    require("@MainActor\nfinal class SystemExtensionRequestManager" in host_source and "@preconcurrency OSSystemExtensionRequestDelegate" in host_source,
            "host system-extension request manager should keep UI state mutations isolated to the main actor",
            failures)
    require('expectedApplicationBundlePath = "/Applications/GarethVideoCam.app"' in host_source and "applicationLocationReadinessDetail" in host_source and "isRunningFromExpectedApplicationPath" in host_source and "Expected App Path" in host_source,
            "host app should require and display the exact expected /Applications app path",
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
    require("extensionHostOnlyEntitlementReadinessDetail" in host_source and "Extension Entitlement Required" in host_source and "Extension Host Entitlement" in host_source and "Extension Host-Only Entitlement:" in host_source,
            "host app should verify the signed embedded extension omits the host-only System Extension entitlement before submitting requests",
            failures)
    require("case needsSigning" in host_source and "requestReadinessMessage" in host_source and "App Signature" in host_source and "Extension Signature" in host_source,
            "host app should surface signing readiness in state, controls, and details",
            failures)
    require("requestReadinessStatus" in host_source and "requestReadinessDetail" in host_source and "requestReadinessNextAction" in host_source and "Request Readiness" in host_source and "Readiness Detail" in host_source and "Readiness Next Action" in host_source and "Request Readiness Next Action:" in host_source,
            "host app should show and copy exact system-extension request readiness blockers and next actions",
            failures)
    require("bundleVersionReadinessDetail" in host_source and "Bundle Version Match" in host_source and "Bundle Version Check:" in host_source and "Version Match Required" in host_source and "bundleVersionStatus" in host_source,
            "host app should verify and copy app and embedded extension bundle version alignment before submitting requests",
            failures)
    require("HeaderView(manager: manager)" in host_source and 'Text(manager.requestReadinessDetail ?? "System extension requests can be submitted.")' in host_source,
            "host app header should surface the current request readiness detail",
            failures)
    require("struct ReadinessCheck" in host_source and "readinessChecks" in host_source and "readinessProgressSummary" in host_source and "requestReadinessNextAction" in host_source and "ReadinessPanel(manager: manager)" in host_source and "ReadinessRow" in host_source and "Team ID Match" in host_source and "Bundle Version Match" in host_source and "Extension Host Entitlement" in host_source and "Extension Metadata" in host_source and "Bundled Video" in host_source and "Readiness Summary:" in host_source and "Readiness Checks:" in host_source,
            "host app should show and copy a compact readiness summary, next action, and checklist for activation gates",
            failures)
    require("let checks = manager.readinessChecks" in host_source and "ForEach(Array(checks.enumerated()), id: \\.element.id)" in host_source,
            "host readiness panel should render a stable checklist snapshot",
            failures)
    require("applicationIdentifierReadinessDetail" in host_source and "applicationBundleIdentifierStatus" in host_source and "App Bundle ID Check" in host_source and "App Identifier Required" in host_source,
            "host app should block requests when the host bundle identifier does not match the expected identifier",
            failures)
    require("lastFailureDetail" in host_source and "Last Failure" in host_source and "No failure recorded." in host_source and "Readiness Failed" in host_source and "Request Failed" in host_source,
            "host app should preserve the last readiness or request failure in details and copied diagnostics",
            failures)
    require("private func recordReadinessBlock" in host_source and "lastFailureDetail = detail" in host_source,
            "host app should record install/uninstall readiness blocks as the last failure detail",
            failures)
    require("firstActivity.level == level" in host_source and "activity.removeFirst()" in host_source,
            "host app should collapse duplicate adjacent activity entries",
            failures)
    require(".disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)" in host_source,
            "host app should disable install controls when system-extension requests cannot be submitted",
            failures)
    require("private var extensionIdentity" in host_source and "private var requestButtons" in host_source and "private var installButton" in host_source and "private var uninstallButton" in host_source,
            "host app should keep install actions responsive at narrower window widths",
            failures)
    require("manager.state == .needsApproval" in host_source and "private var approvalButton" in host_source and "Open System Settings to approve the pending camera extension request." in host_source,
            "host app should surface the System Settings approval action in the primary overview panel",
            failures)
    require("case .locatingExtension, .activating, .needsApproval, .deactivating, .requiresRestart:" in host_source,
            "host app should keep controls disabled while approval or restart is pending",
            failures)
    require("private enum RequestKind" in host_source and "pendingRequestKind = .activation" in host_source and "pendingRequestKind = .deactivation" in host_source,
            "host app should track whether the pending system-extension request is install or uninstall",
            failures)
    require("displayVersion(for properties: OSSystemExtensionProperties)" in host_source and "properties.bundleVersion" in host_source and "Self.displayVersion(for: existing)" in host_source,
            "host app should log replacement app-extension versions with short and build numbers",
            failures)
    require("case deactivated" in host_source and "return .deactivated" in host_source and "Uninstall Completed" in host_source,
            "host app should report successful deactivation separately from activation",
            failures)
    require("case .completed:" in host_source and "case .willCompleteAfterReboot:" in host_source and "@unknown default:" in host_source and "switch result.rawValue" not in host_source,
            "host app should handle system-extension request results with typed enum cases",
            failures)
    require("case .willCompleteAfterReboot:\n            pendingRequestKind = requestKind" in host_source,
            "host app should preserve the deferred request direction when macOS requires restart",
            failures)
    require(f'expectedExtensionBundleIdentifier = "{EXTENSION_BUNDLE_ID}"' in host_source and "unexpectedBundleIdentifier" in host_source,
            "host app should verify the bundled system extension identifier before submitting requests",
            failures)
    require("executableName" in host_source and "executablePath" in host_source and "machServiceName" in host_source and "CFBundleExecutable" in host_source and "validateExtensionExecutable" in host_source and "CMIOExtensionMachServiceName" in host_source and "videoPath" in host_source and "videoByteCount" in host_source and "Contents" in host_source and "MacOS" in host_source and "Resources" in host_source and "video.mp4" in host_source and "fileExists(atPath: videoURL.path, isDirectory:" in host_source,
            "host app should capture executable, CMIO, and bundled-video resource metadata from the embedded extension",
            failures)
    require("missingExtensionExecutable" in host_source and "invalidExtensionExecutable" in host_source and "missingExtensionMachService" in host_source and "missingBundledVideoResource" in host_source and "emptyBundledVideoResource" in host_source and "bundledVideoByteCount" in host_source,
            "host app should fail readiness when embedded extension metadata or video resource is missing",
            failures)
    require("extensionInfo != nil" in host_source and "extensionMetadataReadinessDetail == nil" in host_source and "bundledVideoReadinessDetail == nil" in host_source and "isExtensionMetadataFailureDetail" in host_source and "isBundledVideoFailureDetail" in host_source,
            "host app should make extension metadata and bundled-video readiness explicit system-extension request gates",
            failures)
    require("Extension Executable:" in host_source and "Extension Executable Path:" in host_source and "Extension CMIO Mach Service:" in host_source and "CMIO Mach Service" in host_source and "Bundled Video Path" in host_source and "Bundled Video Size" in host_source and "Video Path" in host_source and "Video Size" in host_source,
            "host app should show and copy extension metadata and bundled-video diagnostics",
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
    require("diagnosticTimestamp(from:" in host_source and "$0.level.title" in host_source and "$0.title): \\($0.detail)" in host_source,
            "host app copied diagnostics should include timestamps and severity for recent activity",
            failures)
    require("hostOperatingSystemVersion" in host_source and "ProcessInfo.processInfo.operatingSystemVersionString" in host_source and "macOS Version:" in host_source and "DetailRow(title: \"macOS Version\"" in host_source,
            "host app should show and copy the host macOS version in diagnostics",
            failures)
    require("QuarantineStatus" in host_source and "getxattr" in host_source and "ENOATTR" in host_source and "App Quarantine" in host_source and "Extension Quarantine" in host_source and "App Quarantine Detail:" in host_source and "Extension Quarantine Detail:" in host_source,
            "host app should show and copy app and extension quarantine extended attribute diagnostics",
            failures)
    require("stateGuidanceDetail" in host_source and "State Guidance:" in host_source and "DetailRow(title: \"State Guidance\"" in host_source and "requestKind.restartDetail" in host_source,
            "host app should show and copy guidance for approval and restart-required states",
            failures)
    require("pendingRequestStatus" in host_source and "Pending Request:" in host_source and "diagnosticTitle" in host_source and "DetailRow(title: \"Pending Request\"" in host_source,
            "host app should show and copy pending system-extension request direction diagnostics",
            failures)
    require("didCopyDiagnostics" in host_source and "Diagnostics Copy Failed" in host_source,
            "host app should report clipboard failures when copying diagnostics",
            failures)
    require("applicationVersion" in host_source and "displayVersion(shortVersion:" in host_source and "Extension Version" in host_source and "App Version" in host_source and "Bundle Version Check" in host_source and "CFBundleShortVersionString" in host_source and "CFBundleVersion" in host_source,
            "host app should show and copy app and extension short/build version diagnostics and alignment status",
            failures)
    require("System Extension Entitlement" in host_source and "App System Extension Entitlement:" in host_source and "Extension Host-Only Entitlement" in host_source and "extensionHostOnlyEntitlementStatus" in host_source,
            "host app should show and copy app and extension System Extension entitlement diagnostics",
            failures)
    require("expectedApplicationBundleIdentifier" in host_source and "applicationBundleIdentifier" in host_source and "Expected App ID" in host_source and "Actual App ID" in host_source and "App Bundle ID Check" in host_source and "Expected Extension ID" in host_source and "Expected App Path:" in host_source,
            "host app should show and copy expected and actual bundle identifier and app path diagnostics",
            failures)
    require("func copyDiagnostics() {\n        refreshExtensionInfo()" in host_source,
            "host app should refresh readiness before copying diagnostics",
            failures)
    require("refreshStatus()" in host_source and "Status Refreshed" in host_source and "Button(action: manager.refreshStatus)" in host_source and "Refresh Status" in host_source,
            "host app should let users refresh extension and signing readiness in-place with activity feedback",
            failures)
    require("didCompleteInitialAppearance" in host_source and "guard didCompleteInitialAppearance else" in host_source,
            "host app should avoid duplicating the manager startup refresh on first view appearance",
            failures)
    require("@Environment(\\.scenePhase)" in host_source and ".onChange(of: scenePhase)" in host_source and "newScenePhase == .active" in host_source,
            "host app should refresh readiness when it becomes active after external approval changes",
            failures)
    require("#Preview" in host_source and "PreviewProvider" not in host_source,
            "host app should use the modern SwiftUI preview syntax",
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
    require("ForEach(Array(items.enumerated()), id: \\.element.id)" in host_source,
            "host activity panel should render a stable activity snapshot",
            failures)
    require(".frame(minWidth: 720, minHeight: 560)" in app_entry_source and ".windowResizability(.contentMinSize)" in app_entry_source,
            "host app should allow a compact but bounded resizable window",
            failures)
    require('CommandMenu("Camera")' in app_entry_source and 'Button("Install Camera Extension")' in app_entry_source and "systemExtensionRequestManager.install()" in app_entry_source and 'Button("Uninstall Camera Extension")' in app_entry_source and "systemExtensionRequestManager.uninstall()" in app_entry_source and 'Button("Refresh Status")' in app_entry_source and "systemExtensionRequestManager.refreshStatus()" in app_entry_source and 'Button("Copy Diagnostics")' in app_entry_source and "systemExtensionRequestManager.copyDiagnostics()" in app_entry_source and 'Button("Open System Settings")' in app_entry_source and 'Button("Reveal App in Finder")' in app_entry_source and "systemExtensionRequestManager.revealApplicationInFinder()" in app_entry_source and 'Button("Reveal Extension in Finder")' in app_entry_source and "systemExtensionRequestManager.revealBundledExtensionInFinder()" in app_entry_source and ".disabled(!systemExtensionRequestManager.canRevealBundledExtension)" in app_entry_source,
            "host app should expose native macOS menu commands for common camera actions",
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
    require("./scripts/check_project.sh" in readme_text and "project metadata validation, build-log scanner tests, runtime diagnostics tests, build-product verifier tests, shell syntax checks, and whitespace checks" in readme_text and "bundle identifiers, aligned bundle versions, declared executables, CoreMediaIO extension metadata, and the bundled video resource" in readme_text,
            "README should document the local pre-push project check",
            failures)
    require("CI-equivalent unsigned compile" in readme_text and "./scripts/build_unsigned.sh" in readme_text and "./scripts/scan_build_log.py build-Debug.log build-Release.log" in readme_text and ".build/Xcode" in readme_text and "BUILD_OUTPUT_PATH" in readme_text,
            "README should document the CI-equivalent unsigned Debug and Release target builds with log scanning",
            failures)
    require("verifies the built app products contain the embedded system extension, aligned bundle versions, declared executables, CoreMediaIO extension metadata, and bundled video" in readme_text,
            "README should document CI build-product verification",
            failures)
    require("parseable dimensions, frame rate, and positive video duration" in readme_text,
            "README should document bundled-video metadata validation",
            failures)
    require("Runtime Activation" in readme_text and "valid Apple Developer signing identity" in readme_text,
            "README should document signed runtime activation requirements",
            failures)
    require("not running from `/Applications/GarethVideoCam.app`" in readme_text and "refreshes readiness when the app becomes active" in readme_text and "shows and copies a readiness summary, next action, and checklist" in readme_text and "primary System Settings approval shortcut" in readme_text and "reveal the app and embedded extension in Finder" in readme_text and "diagnostics snapshot" in readme_text and "generation timestamp" in readme_text and "macOS version" in readme_text and "bundle identifiers" in readme_text and "bundle version match status" in readme_text and "expected and current app paths" in readme_text and "app and extension quarantine status" in readme_text and "host app bundle identifier does not match the expected identifier" in readme_text and "missing the System Extension entitlement" in readme_text and "app and embedded extension bundle versions do not match" in readme_text and "embedded extension executable or CMIO Mach service metadata is missing" in readme_text and "embedded `video.mp4` resource is missing or empty" in readme_text and "bundled system extension signature is invalid" in readme_text and "embedded system extension carries the host-only System Extension entitlement" in readme_text and "Team IDs" in readme_text and "extension host-only entitlement status" in readme_text and "bundled extension executable and CMIO Mach service metadata" in readme_text and "pending request direction" in readme_text and "last recorded failure" in readme_text and "timestamped recent request activity with severity" in readme_text,
            "README should document the in-app approval and diagnostics actions",
            failures)
    require("collect_runtime_diagnostics.sh" in readme_text and "Info.plist bundle versions and identifiers" in readme_text and "bundled-video byte size, checksum, metadata" in readme_text and "expected application-location and bundle identifier checks" in readme_text and "app executable metadata" in readme_text and "quarantine attributes" in readme_text and "matching Team IDs" in readme_text and "Gatekeeper assessment" in readme_text and "signed entitlements" in readme_text and "explicit host and extension System Extension entitlement checks" in readme_text and "counted runtime-readiness summary with a next-action hint" in readme_text and "embedded system-extension executable and CMIO Mach service metadata" in readme_text and "systemextensionsctl" in readme_text and "registration presence and full list output" in readme_text and "camera device inventory" in readme_text and "running app/extension processes" in readme_text and "unified-log window" in readme_text and "system-extension/CMIO log context" in readme_text,
            "README should document collecting runtime diagnostics on macOS",
            failures)
    require("ACTIONABLE_PATTERN" in build_log_scanner_source and "IGNORED_LINE_TOKEN_GROUPS" in build_log_scanner_source and "all(token.lower() in normalized_line" in build_log_scanner_source,
            "build-log scanner should fail on warnings while narrowly ignoring known Xcode AppIntents metadata noise",
            failures)
    require("BUILD_LOG [BUILD_LOG ...]" in build_log_scanner_source and "for build_log_path in (Path(argument) for argument in sys.argv[1:])" in build_log_scanner_source and "actionable_lines_in(build_log_path)" in build_log_scanner_source,
            "build-log scanner should accept and scan multiple build logs",
            failures)
    require("enumerate(build_log, start=1)" in build_log_scanner_source and "{build_log_path}:{line_number}:" in build_log_scanner_source,
            "build-log scanner should print the build-log path and line number for actionable findings",
            failures)
    require("test_ignores_appintents_metadata_notice" in build_log_scanner_test_source and "test_fails_on_actionable_warning" in build_log_scanner_test_source and "test_fails_on_other_appintents_warning" in build_log_scanner_test_source and "test_scans_multiple_build_logs" in build_log_scanner_test_source and ":2: SwiftCompile warning: real source warning" in build_log_scanner_test_source,
            "build-log scanner should have regression coverage for ignored and actionable warnings",
            failures)
    require("xcodebuild" in build_unsigned_source and "-target \"$TARGET_NAME\"" in build_unsigned_source and "CODE_SIGNING_ALLOWED=NO" in build_unsigned_source and "CODE_SIGNING_REQUIRED=NO" in build_unsigned_source and "BUILD_ARCH" in build_unsigned_source and "RUNNER_ARCH" not in build_unsigned_source and "BUILD_OUTPUT_PATH" in build_unsigned_source and "SYMROOT=\"$BUILD_OUTPUT_PATH/Products\"" in build_unsigned_source and "OBJROOT=\"$BUILD_OUTPUT_PATH/Intermediates\"" in build_unsigned_source and "-derivedDataPath" not in build_unsigned_source and "configurations=(Debug Release)" in build_unsigned_source and "build-${configuration}.log" in build_unsigned_source,
            "unsigned build script should perform Debug and Release app target builds without code signing",
            failures)
    require(build_unsigned_path.stat().st_mode & 0o111,
            "unsigned build script should be executable",
            failures)
    require("GarethVideoCam.app" in verify_build_products_source and "com.garethpaul.GarethVideoCam.Extension.systemextension" in verify_build_products_source and "Contents/Library/SystemExtensions" in verify_build_products_source and "Contents/Resources/video.mp4" in verify_build_products_source and "read_bundle_identifier" in verify_build_products_source and "read_bundle_short_version" in verify_build_products_source and "read_bundle_build_version" in verify_build_products_source and "verify_aligned_bundle_versions" in verify_build_products_source and "Mismatched %s bundle short versions" in verify_build_products_source and "Mismatched %s bundle build versions" in verify_build_products_source and "read_bundle_executable" in verify_build_products_source and "verify_bundle_executable" in verify_build_products_source and "read_extension_mach_service_name" in verify_build_products_source and "verify_extension_cmio_metadata" in verify_build_products_source and "CMIOExtensionMachServiceName" in verify_build_products_source and "Contents/Info.plist" in verify_build_products_source and "Contents/MacOS" in verify_build_products_source and "CFBundleExecutable" in verify_build_products_source and "CFBundleShortVersionString" in verify_build_products_source and "CFBundleVersion" in verify_build_products_source and "plistlib" in verify_build_products_source and "PlistBuddy" not in verify_build_products_source and "Debug Release" in verify_build_products_source,
            "build-product verifier should check app, embedded extension, bundle identifiers, aligned bundle versions, declared executables, CoreMediaIO metadata, and bundled video",
            failures)
    require(verify_build_products_path.stat().st_mode & 0o111,
            "build-product verifier script should be executable",
            failures)
    require("write_product_fixture" in verify_build_products_test_source and "write_executable_fixture" in verify_build_products_test_source and "com.example.WrongExtension" in verify_build_products_test_source and "Unexpected Debug extension bundle identifier" in verify_build_products_test_source and "Missing or empty Debug bundled video resource" in verify_build_products_test_source and "Missing or non-executable Debug extension executable" in verify_build_products_test_source and "Missing Debug extension CMIOExtensionMachServiceName" in verify_build_products_test_source and "Mismatched Debug bundle short versions" in verify_build_products_test_source and "Mismatched Debug bundle build versions" in verify_build_products_test_source and "Build-product verifier tests passed." in verify_build_products_test_source,
            "build-product verifier should have fixture coverage for passing products, bundle identifier failures, version mismatches, missing executables, missing CoreMediaIO metadata, and missing bundled video",
            failures)
    require(verify_build_products_test_path.stat().st_mode & 0o111,
            "build-product verifier test script should be executable",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup-unknown" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup-ready" in runtime_diagnostics_test_source and "Runtime readiness result: blocked" in runtime_diagnostics_test_source and "Runtime readiness result: incomplete" in runtime_diagnostics_test_source and "Runtime readiness result: ready" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 1/3" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 1/2" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 1/1" in runtime_diagnostics_test_source and "Runtime readiness next action: resolve Blocked fixture" in runtime_diagnostics_test_source and "Runtime readiness next action: inspect Unknown fixture" in runtime_diagnostics_test_source and "Runtime readiness next action: submit the system extension request" in runtime_diagnostics_test_source and "Runtime diagnostics tests passed." in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover blocked, unknown, and ready counted readiness rollups",
            failures)
    require(runtime_diagnostics_test_path.stat().st_mode & 0o111,
            "runtime diagnostics test script should be executable",
            failures)
    require("./scripts/validate_project.py" in check_project_source and "./scripts/test_scan_build_log.py" in check_project_source and "./scripts/test_collect_runtime_diagnostics.sh" in check_project_source and "./scripts/test_verify_build_products.sh" in check_project_source and "bash -n ./scripts/collect_runtime_diagnostics.sh" in check_project_source and "bash -n ./scripts/build_unsigned.sh" in check_project_source and "bash -n ./scripts/verify_build_products.sh" in check_project_source and "bash -n ./scripts/test_collect_runtime_diagnostics.sh" in check_project_source and "bash -n ./scripts/test_verify_build_products.sh" in check_project_source and "git diff --check" in check_project_source and "git diff-tree --check --root --no-commit-id -r HEAD" in check_project_source,
            "project check script should run validation, scanner tests, shell syntax checks, and whitespace checks",
            failures)
    require(check_project_path.stat().st_mode & 0o111,
            "project check script should be executable",
            failures)
    require("codesign -d --entitlements :-" in runtime_diagnostics_source and "spctl --assess" in runtime_diagnostics_source and "systemextensionsctl list" in runtime_diagnostics_source and "registration_output" in runtime_diagnostics_source and "Extension registration entry present" in runtime_diagnostics_source and "Full systemextensionsctl list output:" in runtime_diagnostics_source and "grep -F \"$EXTENSION_ID\"" in runtime_diagnostics_source and "Camera Devices" in runtime_diagnostics_source and "SPCameraDataType" in runtime_diagnostics_source and "Running App and Extension Processes" in runtime_diagnostics_source and "/bin/ps -axo" in runtime_diagnostics_source and "script_pid=\"$$\"" in runtime_diagnostics_source and "collect_runtime_diagnostics.sh" in runtime_diagnostics_source and "$4 ~ /(^|\\/)awk$/" in runtime_diagnostics_source and "Bundle short version:" in runtime_diagnostics_source and "Bundle build version:" in runtime_diagnostics_source and "read_info_plist_value" in runtime_diagnostics_source and "read_extension_mach_service_name" in runtime_diagnostics_source and "EXTENSION_INFO_PLIST" in runtime_diagnostics_source and "Application Runtime Metadata" in runtime_diagnostics_source and "App CFBundleExecutable:" in runtime_diagnostics_source and "App executable path:" in runtime_diagnostics_source and "App executable exists:" in runtime_diagnostics_source and "App executable is executable:" in runtime_diagnostics_source and "App executable ready" in runtime_diagnostics_source and "Embedded Extension Runtime Metadata" in runtime_diagnostics_source and "Extension CFBundleExecutable:" in runtime_diagnostics_source and "Extension executable path:" in runtime_diagnostics_source and "Extension executable exists:" in runtime_diagnostics_source and "Extension executable is executable:" in runtime_diagnostics_source and "Extension CMIO Mach service:" in runtime_diagnostics_source and "Extension executable ready" in runtime_diagnostics_source and "Extension CMIO Mach service ready" in runtime_diagnostics_source and "print_readiness_check" in runtime_diagnostics_source and "print_readiness_rollup" in runtime_diagnostics_source and "Runtime readiness result:" in runtime_diagnostics_source and "Runtime readiness checks ready:" in runtime_diagnostics_source and "Runtime readiness checks blocked:" in runtime_diagnostics_source and "Runtime readiness checks unknown:" in runtime_diagnostics_source and "Runtime readiness next action:" in runtime_diagnostics_source and "readiness_first_blocked_label" in runtime_diagnostics_source and "readiness_first_unknown_label" in runtime_diagnostics_source and "readiness_ready_count" in runtime_diagnostics_source and "readiness_blocked_count" in runtime_diagnostics_source and "readiness_unknown_count" in runtime_diagnostics_source and "Contents/Info.plist" in runtime_diagnostics_source and "PlistBuddy -c \"Print :${key}\"" in runtime_diagnostics_source and "Print :CMIOExtension:CMIOExtensionMachServiceName" in runtime_diagnostics_source and "plutil -extract \"$key\" raw" in runtime_diagnostics_source and "plutil -extract CMIOExtension.CMIOExtensionMachServiceName raw" in runtime_diagnostics_source and "CFBundleShortVersionString" in runtime_diagnostics_source and "CFBundleVersion" in runtime_diagnostics_source and "LOG_WINDOW" in runtime_diagnostics_source and "Bundled Video" in runtime_diagnostics_source and "VIDEO_PATH" in runtime_diagnostics_source and "Video resource exists:" in runtime_diagnostics_source and "Video byte size:" in runtime_diagnostics_source and "Video resource is empty:" in runtime_diagnostics_source and "Video SHA-256:" in runtime_diagnostics_source and "print_file_sha256" in runtime_diagnostics_source and "kMDItemPixelWidth" in runtime_diagnostics_source and "kMDItemPixelHeight" in runtime_diagnostics_source and "kMDItemDurationSeconds" in runtime_diagnostics_source and "Application Location Check" in runtime_diagnostics_source and "EXPECTED_APP_PATH" in runtime_diagnostics_source and "App path is inside /Applications:" in runtime_diagnostics_source and "App path matches expected app path:" in runtime_diagnostics_source and "Quarantine Check" in runtime_diagnostics_source and "print_quarantine_status" in runtime_diagnostics_source and "com.apple.quarantine" in runtime_diagnostics_source and "Bundle Identifier Check" in runtime_diagnostics_source and "read_bundle_identifier" in runtime_diagnostics_source and "App bundle identifier matches:" in runtime_diagnostics_source and "Extension bundle identifier matches:" in runtime_diagnostics_source and "Signing Team Match" in runtime_diagnostics_source and "read_team_identifier" in runtime_diagnostics_source and "Team identifiers match:" in runtime_diagnostics_source and "Entitlement Check" in runtime_diagnostics_source and "HOST_SYSTEM_EXTENSION_ENTITLEMENT" in runtime_diagnostics_source and "has_boolean_entitlement" in runtime_diagnostics_source and "App System Extension entitlement present:" in runtime_diagnostics_source and "Extension carries host-only System Extension entitlement:" in runtime_diagnostics_source and "Runtime Readiness Summary" in runtime_diagnostics_source and "print_yes_no_unknown" in runtime_diagnostics_source and 'if [ "$APP_PATH" = "$EXPECTED_APP_PATH" ]; then' in runtime_diagnostics_source and "Application location ready" in runtime_diagnostics_source and "App bundle identifier ready" in runtime_diagnostics_source and "App signature ready" in runtime_diagnostics_source and "App System Extension entitlement ready" in runtime_diagnostics_source and "Extension bundle identifier ready" in runtime_diagnostics_source and "Extension signature ready" in runtime_diagnostics_source and "Extension host-only entitlement absent" in runtime_diagnostics_source and "Signing Team match ready" in runtime_diagnostics_source and "Bundled video ready" in runtime_diagnostics_source and "systemextensionsd" in runtime_diagnostics_source and "com.apple.CoreMediaIO" in runtime_diagnostics_source,
            "runtime diagnostics script should collect labeled entitlements, entitlement readiness, readiness summary, Gatekeeper assessment, bundle versions, quarantine status, system-extension registration, camera inventory, process inventory, configurable log windows, and recent app/system-extension logs",
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
        require("FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true" in workflow_text,
                "macOS build workflow should opt JavaScript actions into Node 24",
                failures)
        require("Xcode_26.5" in workflow_text,
                "macOS build workflow should explicitly select Xcode 26.5",
                failures)
        require("./scripts/test_scan_build_log.py" in workflow_text,
                "macOS build workflow should test the build-log scanner",
                failures)
        require("./scripts/test_verify_build_products.sh" in workflow_text and "Test build product verifier" in workflow_text,
                "macOS build workflow should test the build-product verifier",
                failures)
        require("./scripts/test_collect_runtime_diagnostics.sh" in workflow_text and "Test runtime diagnostics" in workflow_text,
                "macOS build workflow should test runtime diagnostics helpers",
                failures)
        require("bash -n ./scripts/collect_runtime_diagnostics.sh" in workflow_text and "bash -n ./scripts/build_unsigned.sh" in workflow_text and "bash -n ./scripts/verify_build_products.sh" in workflow_text and "bash -n ./scripts/test_collect_runtime_diagnostics.sh" in workflow_text and "bash -n ./scripts/test_verify_build_products.sh" in workflow_text,
                "macOS build workflow should syntax-check the runtime diagnostics, unsigned build, and build-product verifier scripts",
                failures)
        require("git diff-tree --check --root --no-commit-id -r HEAD" in workflow_text,
                "macOS build workflow should check committed whitespace",
                failures)
        require("./scripts/build_unsigned.sh" in workflow_text,
                "macOS build workflow should perform the shared unsigned xcodebuild script",
                failures)
        require("./scripts/verify_build_products.sh" in workflow_text and "Verify build products" in workflow_text,
                "macOS build workflow should verify unsigned app products after building",
                failures)
        require("-target \"$TARGET_NAME\"" in build_unsigned_source,
                "unsigned build script should build the app target without running scheme post-actions",
                failures)
        require("BUILD_ARCH=\"${BUILD_ARCH:-$(uname -m)}\"" in build_unsigned_source and "ARCHS=\"$BUILD_ARCH\"" in build_unsigned_source,
                "unsigned build script should build the target for the runner architecture",
                failures)
        require("BUILD_OUTPUT_PATH=\"${BUILD_OUTPUT_PATH:-.build/Xcode}\"" in build_unsigned_source and "SYMROOT=\"$BUILD_OUTPUT_PATH/Products\"" in build_unsigned_source and "OBJROOT=\"$BUILD_OUTPUT_PATH/Intermediates\"" in build_unsigned_source and "-derivedDataPath" not in build_unsigned_source,
                "unsigned build script should use overridable repository-local target build output paths",
                failures)
        require("configurations=(Debug Release)" in build_unsigned_source,
                "unsigned build script should build both Debug and Release configurations",
                failures)
        require("build-Debug.log" in workflow_text and "build-Release.log" in workflow_text,
                "macOS build workflow should capture separate Debug and Release logs",
                failures)
        require("./scripts/scan_build_log.py build-Debug.log build-Release.log" in workflow_text,
                "macOS build workflow should scan captured Debug and Release xcodebuild output",
                failures)
        require("actions/upload-artifact@v7.0.1" in workflow_text and "xcode-build-logs" in workflow_text and "path: build-*.log" in workflow_text and "if-no-files-found: ignore" in workflow_text,
                "macOS build workflow should upload captured Xcode build logs for later inspection",
                failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    print("Project validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
