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
    require("invalidFrameDuration" in extension_source and "throw CameraExtensionError.invalidFrameDuration" in extension_source and "streamProperties.frameDuration" in extension_source,
            "extension stream should reject unsupported frame-duration requests",
            failures)
    require("case needsApplicationLocation" in host_source and "canSubmitSystemExtensionRequests" in host_source,
            "host app should model the /Applications requirement before submitting system-extension requests",
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
    require("case needsSigning" in host_source and "requestReadinessMessage" in host_source and "App Signature" in host_source and "Extension Signature" in host_source,
            "host app should surface signing readiness in state, controls, and details",
            failures)
    require(".disabled(manager.isBusy || !manager.canSubmitSystemExtensionRequests)" in host_source,
            "host app should disable install controls when system-extension requests cannot be submitted",
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
    require("nsError.domain" in host_source and "unknown code \\(errorCode)" in host_source,
            "host app should preserve system-extension failure domain and code diagnostics",
            failures)
    require("diagnosticSummary" in host_source and "NSPasteboard.general" in host_source and "Copy Diagnostics" in host_source,
            "host app should expose copyable diagnostics for activation troubleshooting",
            failures)
    require("applicationVersion" in host_source and "App Version" in host_source and "CFBundleShortVersionString" in host_source,
            "host app should show and copy app version diagnostics",
            failures)
    require("func copyDiagnostics() {\n        refreshExtensionInfo()" in host_source,
            "host app should refresh readiness before copying diagnostics",
            failures)
    require("Button(action: manager.refreshExtensionInfo)" in host_source and "Refresh Status" in host_source,
            "host app should let users refresh extension and signing readiness in-place",
            failures)
    require("case .idle, .ready, .needsApplicationLocation, .needsSigning, .deactivated, .failed:" in host_source,
            "host app should let a successful refresh recover from stale readiness failures",
            failures)
    require("private struct DetailsActions" in host_source and "ViewThatFits(in: .horizontal)" in host_source,
            "host app should keep details actions responsive at narrower window widths",
            failures)
    require("activateFileViewerSelecting" in host_source and "Reveal App" in host_source,
            "host app should let users reveal the running app bundle in Finder",
            failures)
    require("openSystemSettings" in host_source and "System Settings" in host_source and "/System/Applications/System Settings.app" in host_source,
            "host app should provide a System Settings shortcut for extension approval",
            failures)
    require("CI-equivalent unsigned compile" in readme_text and "-target GarethVideoCam" in readme_text,
            "README should document the CI-equivalent unsigned target build",
            failures)
    require("Runtime Activation" in readme_text and "valid Apple Developer signing identity" in readme_text,
            "README should document signed runtime activation requirements",
            failures)
    require("System Settings shortcut" in readme_text and "diagnostics snapshot" in readme_text and "bundled system extension signature is invalid" in readme_text,
            "README should document the in-app approval and diagnostics actions",
            failures)
    require("collect_runtime_diagnostics.sh" in readme_text and "bundle versions" in readme_text and "Gatekeeper assessment" in readme_text and "signed entitlements" in readme_text and "systemextensionsctl" in readme_text and "unified-log window" in readme_text and "system-extension/CMIO log context" in readme_text,
            "README should document collecting runtime diagnostics on macOS",
            failures)
    require("ACTIONABLE_PATTERN" in build_log_scanner_source and "IGNORED_LINE_TOKEN_GROUPS" in build_log_scanner_source and "all(token.lower() in normalized_line" in build_log_scanner_source,
            "build-log scanner should fail on warnings while narrowly ignoring known Xcode AppIntents metadata noise",
            failures)
    require("test_ignores_appintents_metadata_notice" in build_log_scanner_test_source and "test_fails_on_actionable_warning" in build_log_scanner_test_source and "test_fails_on_other_appintents_warning" in build_log_scanner_test_source,
            "build-log scanner should have regression coverage for ignored and actionable warnings",
            failures)
    require("codesign -d --entitlements :-" in runtime_diagnostics_source and "spctl --assess" in runtime_diagnostics_source and "systemextensionsctl list" in runtime_diagnostics_source and "Bundle short version:" in runtime_diagnostics_source and "Bundle build version:" in runtime_diagnostics_source and "CFBundleShortVersionString" in runtime_diagnostics_source and "CFBundleVersion" in runtime_diagnostics_source and "LOG_WINDOW" in runtime_diagnostics_source and "systemextensionsd" in runtime_diagnostics_source and "com.apple.CoreMediaIO" in runtime_diagnostics_source,
            "runtime diagnostics script should collect labeled entitlements, Gatekeeper assessment, bundle versions, system-extension registration, configurable log windows, and recent app/system-extension logs",
            failures)

    scheme_path = ROOT / "GarethVideoCam.xcodeproj/xcshareddata/xcschemes/GarethVideoCam.xcscheme"
    scheme = ET.parse(scheme_path).getroot()
    require(scheme.attrib.get("LastUpgradeVersion") == "2600",
            "shared scheme is not marked as upgraded for Xcode 26",
            failures)

    scheme_text = scheme_path.read_text()
    require("/usr/bin/ditto" in scheme_text and "/Applications/${FULL_PRODUCT_NAME}" in scheme_text and "/bin/rm -rf" in scheme_text and "/Applications/*.app" in scheme_text,
            "shared scheme should replace the app in /Applications with a guarded path before system-extension testing",
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
