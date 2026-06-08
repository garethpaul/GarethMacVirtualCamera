#!/usr/bin/env python3
import plistlib
import re
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


def require(condition, message, failures):
    if not condition:
        failures.append(message)


def main():
    failures = []

    app_entitlements = load_plist("GarethVideoCam/Entitlements.entitlements")
    extension_entitlements = load_plist("Extension/Extension.entitlements")
    extension_info = load_plist("Extension/Info.plist")

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

    project_text = (ROOT / "GarethVideoCam.xcodeproj/project.pbxproj").read_text()
    host_source = (ROOT / "GarethVideoCam/ContentView.swift").read_text()
    extension_source = (ROOT / "Extension/ExtensionProvider.swift").read_text()
    extension_main_source = (ROOT / "Extension/main.swift").read_text()
    readme_text = (ROOT / "README.md").read_text()
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
    require("isPreparingStream" not in extension_source,
            "extension should not keep unused stream preparation state",
            failures)
    require("fatalError(" not in extension_source and "fatalError(" not in extension_main_source,
            "extension startup should log initialization failures instead of crashing with fatalError",
            failures)
    require("Failed to start camera extension service" in extension_main_source and "exit(EXIT_FAILURE)" in extension_main_source,
            "extension entry point should log startup failures before exiting",
            failures)
    require("case needsApplicationLocation" in host_source and "canSubmitSystemExtensionRequests" in host_source,
            "host app should model the /Applications requirement before submitting system-extension requests",
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
    require(f'expectedExtensionBundleIdentifier = "{EXTENSION_BUNDLE_ID}"' in host_source and "unexpectedBundleIdentifier" in host_source,
            "host app should verify the bundled system extension identifier before submitting requests",
            failures)
    require("nsError.domain" in host_source and "unknown code \\(errorCode)" in host_source,
            "host app should preserve system-extension failure domain and code diagnostics",
            failures)
    require("CI-equivalent unsigned compile" in readme_text and "-target GarethVideoCam" in readme_text,
            "README should document the CI-equivalent unsigned target build",
            failures)
    require("Runtime Activation" in readme_text and "valid Apple Developer signing identity" in readme_text,
            "README should document signed runtime activation requirements",
            failures)

    scheme_path = ROOT / "GarethVideoCam.xcodeproj/xcshareddata/xcschemes/GarethVideoCam.xcscheme"
    scheme = ET.parse(scheme_path).getroot()
    require(scheme.attrib.get("LastUpgradeVersion") == "2600",
            "shared scheme is not marked as upgraded for Xcode 26",
            failures)

    scheme_text = scheme_path.read_text()
    require("/usr/bin/ditto" in scheme_text and "/Applications/${FULL_PRODUCT_NAME}" in scheme_text,
            "shared scheme no longer copies the app into /Applications for system-extension testing",
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
        require("xcodebuild" in workflow_text and "CODE_SIGNING_ALLOWED=NO" in workflow_text,
                "macOS build workflow should perform an unsigned xcodebuild",
                failures)
        require("-target GarethVideoCam" in workflow_text,
                "macOS build workflow should build the app target without running scheme post-actions",
                failures)
        require("runner_arch=\"$(uname -m)\"" in workflow_text and "ARCHS=\"${runner_arch}\"" in workflow_text,
                "macOS build workflow should build the target for the runner architecture",
                failures)
        require("tee build.log" in workflow_text,
                "macOS build workflow should capture xcodebuild output",
                failures)
        require("grep -Ei \"warning:|error:\"" in workflow_text and "appintentsmetadataprocessor" in workflow_text,
                "macOS build workflow should fail on source warnings while ignoring Xcode AppIntents metadata noise",
                failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    print("Project validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
