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
HOST_SYSTEM_EXTENSION_ENTITLEMENT = "com.apple.developer.system-extension.install"
APP_SANDBOX_ENTITLEMENT = "com.apple.security.app-sandbox"
APP_GROUP_ENTITLEMENT = "com.apple.security.application-groups"
EXPECTED_APP_ENTITLEMENT_KEYS = {
    HOST_SYSTEM_EXTENSION_ENTITLEMENT,
    APP_SANDBOX_ENTITLEMENT,
    APP_GROUP_ENTITLEMENT,
}
EXPECTED_EXTENSION_ENTITLEMENT_KEYS = {
    APP_SANDBOX_ENTITLEMENT,
    APP_GROUP_ENTITLEMENT,
}
CHECKOUT_ACTION = "actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10"
CHECKOUT_RELEASE = "v6.0.3"
ARTIFACT_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
ARTIFACT_RELEASE = "v7.0.1"


def workflow_steps(workflow_text):
    lines = workflow_text.splitlines()
    steps = []

    for header_index, line in enumerate(lines):
        header_match = re.fullmatch(r"(\s*)steps:\s*", line)
        if not header_match:
            continue

        header_indent = len(header_match.group(1))
        step_starts = []
        index = header_index + 1

        while index < len(lines):
            current_line = lines[index]
            if current_line.strip():
                current_indent = len(current_line) - len(current_line.lstrip())
                if current_indent <= header_indent:
                    break
                if current_indent == header_indent + 2 and re.match(r"\s*-\s+", current_line):
                    step_starts.append(index)
            index += 1

        for position, start in enumerate(step_starts):
            end = step_starts[position + 1] if position + 1 < len(step_starts) else index
            steps.append({"start": start, "end": end, "lines": lines[start:end]})

    return steps


def workflow_action_references(step):
    references = []

    for offset, line in enumerate(step["lines"]):
        match = re.fullmatch(r"\s*(?:-\s*)?uses:\s*([^\s#]+)(?:\s+#\s*(.*?))?\s*", line)
        if match:
            references.append({
                "line": step["start"] + offset,
                "reference": match.group(1),
                "annotation": match.group(2) or "",
                "step": step,
            })

    return references


def workflow_key_occurrences(workflow_text, key):
    occurrences = []
    pattern = re.compile(rf"(\s*){re.escape(key)}:\s*([^\s#]+)\s*(?:#.*)?")

    for line_number, line in enumerate(workflow_text.splitlines()):
        match = pattern.fullmatch(line)
        if match:
            occurrences.append({
                "line": line_number,
                "indent": len(match.group(1)),
                "value": match.group(2),
            })

    return occurrences


def workflow_key_is_direct_step_input(step, occurrence):
    relative_line = occurrence["line"] - step["start"]
    if relative_line < 0 or relative_line >= len(step["lines"]):
        return False

    for index in range(relative_line - 1, -1, -1):
        line = step["lines"][index]
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent >= occurrence["indent"]:
            continue
        return line.strip() == "with:" and occurrence["indent"] == indent + 2

    return False


def workflow_top_level_block(workflow_text, key):
    lines = workflow_text.splitlines()
    header = f"{key}:"
    matching_headers = [index for index, line in enumerate(lines) if line == header]
    if len(matching_headers) != 1:
        return None

    start = matching_headers[0]
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line and not line.startswith((" ", "\t")):
            break
        end += 1

    return lines[start:end]


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

    if len(header) < 24 or struct.unpack(">I", header[8:12])[0] != 13 or header[12:16] != b"IHDR":
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
        if payload_start >= payload_end:
            return None

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

        if version != 0:
            return None

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
        if data[payload_start] != 0:
            return None
        return data[payload_start + 8:payload_start + 12].decode("latin1")

    def parse_stts(payload_start, payload_end):
        if payload_start + 8 > payload_end:
            return []
        if data[payload_start] != 0:
            return []

        entry_count = struct.unpack(">I", data[payload_start + 4:payload_start + 8])[0]
        entry_offset = payload_start + 8
        max_entry_count = (payload_end - entry_offset) // 8
        if entry_count > max_entry_count:
            return []

        entries = []

        for _ in range(entry_count):
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
        if payload_start + 8 > payload_end:
            return None
        if data[payload_start] != 0:
            return None

        entry_count = struct.unpack(">I", data[payload_start + 4:payload_start + 8])[0]
        sample_descriptions = list(iter_atoms(payload_start + 8, payload_end))
        if entry_count > len(sample_descriptions):
            return None

        for atom_type, sample_start, sample_end in sample_descriptions[:entry_count]:
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
                track_dimensions = None

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
                                            track_dimensions = video_dimensions

                if handler == "vide" and timescale and media_duration is not None:
                    video_metadata["duration_seconds"] = media_duration / timescale

                if handler == "vide" and track_dimensions is not None:
                    video_metadata["dimensions"] = track_dimensions

                if handler == "vide" and timescale and len(sample_durations) == 1:
                    sample_count, sample_delta = sample_durations[0]
                    if sample_count and sample_delta and timescale % sample_delta == 0:
                        video_metadata["frame_rate"] = timescale // sample_delta

    return video_metadata


def expected_icon_pixel_size(image):
    size = image.get("size")
    scale_value = image.get("scale")

    if not isinstance(size, str) or not isinstance(scale_value, str):
        return None

    if size.strip() != size or scale_value.strip() != scale_value:
        return None

    size_parts = size.split("x", maxsplit=1)
    if len(size_parts) != 2:
        return None

    if not scale_value.endswith("x"):
        return None

    scale_digits = scale_value.removesuffix("x")
    if not re.fullmatch(r"[0-9]+", size_parts[0]) or not re.fullmatch(r"[0-9]+", size_parts[1]) or not re.fullmatch(r"[0-9]+", scale_digits):
        return None

    try:
        point_width = int(size_parts[0])
        point_height = int(size_parts[1])
        scale = int(scale_digits)
    except ValueError:
        return None

    if point_width <= 0 or point_height <= 0 or point_width != point_height or scale <= 0:
        return None

    return point_width * scale


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

    require(set(app_entitlements.keys()) == EXPECTED_APP_ENTITLEMENT_KEYS,
            "host app entitlements should contain only the System Extension, app sandbox, and shared app-group keys",
            failures)
    require(set(extension_entitlements.keys()) == EXPECTED_EXTENSION_ENTITLEMENT_KEYS,
            "extension entitlements should contain only app sandbox and shared app-group keys",
            failures)
    require(app_entitlements.get(HOST_SYSTEM_EXTENSION_ENTITLEMENT) is True,
            "host app is missing the System Extension entitlement",
            failures)
    require(app_entitlements.get(APP_SANDBOX_ENTITLEMENT) is True,
            "host app should remain sandboxed",
            failures)
    require(extension_entitlements.get(APP_SANDBOX_ENTITLEMENT) is True,
            "extension should remain sandboxed",
            failures)
    require(app_entitlements.get(APP_GROUP_ENTITLEMENT) == [APP_GROUP],
            "host app should declare exactly the shared expected app group",
            failures)
    require(extension_entitlements.get(APP_GROUP_ENTITLEMENT) == [APP_GROUP],
            "extension should declare exactly the shared expected app group",
            failures)
    require(HOST_SYSTEM_EXTENSION_ENTITLEMENT not in extension_entitlements,
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
    require(video_path.is_file() and video_path.stat().st_size > 0,
            "Extension/video.mp4 is missing, empty, or not a file",
            failures)
    video_metadata = mp4_video_metadata(video_path) if video_path.is_file() else {}
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
            require(icon_path.is_file() and icon_path.stat().st_size > 0,
                    f"app icon file is missing, empty, or not a file: {icon_filename}",
                    failures)
            if icon_path.is_file():
                expected_size = expected_icon_pixel_size(icon_entry)
                require(expected_size is not None and png_dimensions(icon_path) == (expected_size, expected_size),
                        f"app icon file has incorrect pixel dimensions: {icon_filename}",
                        failures)

    accent_colors = accent_color.get("colors", [])
    require(any("color" in color for color in accent_colors),
            "accent color catalog should define an explicit color",
            failures)

    project_text = (ROOT / "GarethVideoCam.xcodeproj/project.pbxproj").read_text()
    app_entry_source = (ROOT / "GarethVideoCam/GarethVideoCam.swift").read_text()
    host_source = (ROOT / "GarethVideoCam/ContentView.swift").read_text()
    header_view_source = ""
    details_actions_source = ""
    if "private struct HeaderView" in host_source and "private struct ActionPanel" in host_source:
        header_view_source = host_source.split("private struct HeaderView", 1)[1].split("private struct ActionPanel", 1)[0]
    if "private struct DetailsActions" in host_source and "private struct ActivityPanel" in host_source:
        details_actions_source = host_source.split("private struct DetailsActions", 1)[1].split("private struct ActivityPanel", 1)[0]
    extension_source = (ROOT / "Extension/ExtensionProvider.swift").read_text()
    sample_timestamp_validator_source = (ROOT / "Extension/SampleTimestampValidator.swift").read_text()
    extension_main_source = (ROOT / "Extension/main.swift").read_text()
    package_source = (ROOT / "Package.swift").read_text()
    sample_timestamp_test_source = (ROOT / "Tests/CameraTimelineTests/SampleTimestampValidatorTests.swift").read_text()
    readme_text = (ROOT / "README.md").read_text()
    vision_text = (ROOT / "VISION.md").read_text()
    security_text = (ROOT / "SECURITY.md").read_text()
    agents_text = (ROOT / "AGENTS.md").read_text()
    readme_overview_path = ROOT / "docs/readme-overview.svg"
    readme_overview_text = ""
    readme_overview_xml_valid = False
    if readme_overview_path.exists():
        readme_overview_text = readme_overview_path.read_text()
        try:
            ET.fromstring(readme_overview_text)
            readme_overview_xml_valid = True
        except ET.ParseError:
            readme_overview_xml_valid = False
    gitignore_text = (ROOT / ".gitignore").read_text()
    makefile_path = ROOT / "Makefile"
    makefile_text = makefile_path.read_text() if makefile_path.exists() else ""
    changes_path = ROOT / "CHANGES.md"
    changes_text = changes_path.read_text() if changes_path.exists() else ""
    plan_path = ROOT / "docs/plans/2026-06-08-make-check-baseline.md"
    plan_text = plan_path.read_text() if plan_path.exists() else ""
    stale_reader_plan_path = ROOT / "docs/plans/2026-06-12-stale-reader-cancellation.md"
    stale_reader_plan_text = stale_reader_plan_path.read_text() if stale_reader_plan_path.exists() else ""
    transactional_timing_plan_path = ROOT / "docs/plans/2026-06-13-transactional-sample-timing.md"
    transactional_timing_plan_text = transactional_timing_plan_path.read_text() if transactional_timing_plan_path.exists() else ""
    all_branch_ci_plan_path = ROOT / "docs/plans/2026-06-13-all-branch-hosted-validation.md"
    all_branch_ci_plan_text = all_branch_ci_plan_path.read_text() if all_branch_ci_plan_path.exists() else ""
    location_independent_make_plan_path = ROOT / "docs/plans/2026-06-13-location-independent-make.md"
    location_independent_make_plan_text = location_independent_make_plan_path.read_text() if location_independent_make_plan_path.exists() else ""
    docs_plan_paths = sorted((ROOT / "docs/plans").glob("*.md"))
    check_project_path = ROOT / "scripts/check_project.sh"
    check_project_source = check_project_path.read_text()
    build_unsigned_path = ROOT / "scripts/build_unsigned.sh"
    build_unsigned_source = build_unsigned_path.read_text()
    build_unsigned_test_path = ROOT / "scripts/test_build_unsigned.sh"
    build_unsigned_test_source = build_unsigned_test_path.read_text()
    verify_build_products_path = ROOT / "scripts/verify_build_products.sh"
    verify_build_products_source = verify_build_products_path.read_text()
    verify_build_products_test_path = ROOT / "scripts/test_verify_build_products.sh"
    verify_build_products_test_source = verify_build_products_test_path.read_text()
    build_log_scanner_source = (ROOT / "scripts/scan_build_log.py").read_text()
    build_log_scanner_test_source = (ROOT / "scripts/test_scan_build_log.py").read_text()
    runtime_diagnostics_source = (ROOT / "scripts/collect_runtime_diagnostics.sh").read_text()
    runtime_diagnostics_test_path = ROOT / "scripts/test_collect_runtime_diagnostics.sh"
    runtime_diagnostics_test_source = runtime_diagnostics_test_path.read_text()
    validate_project_source = (ROOT / "scripts/validate_project.py").read_text()
    validate_project_test_path = ROOT / "scripts/test_validate_project.py"
    validate_project_test_source = validate_project_test_path.read_text() if validate_project_test_path.exists() else ""
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
    require(project_text.count("MACOSX_DEPLOYMENT_TARGET = 14.0;") == 6,
            "project app, extension, and project build configurations should keep the macOS 14.0 deployment target",
            failures)
    require(project_text.count("SDKROOT = macosx;") == 2,
            "project Debug and Release build configurations should use the macOS SDK",
            failures)
    require(".build/" in gitignore_text and "__pycache__/" in gitignore_text and "build-*.log" in gitignore_text and "*.xcresult" in gitignore_text,
            "gitignore should exclude local Xcode build products, logs, and result bundles",
            failures)
    require(makefile_path.exists()
            and ".PHONY: build check lint test" in makefile_text
            and "lint test build: check" in makefile_text
            and 'override ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))' in makefile_text
            and '"$(ROOT)/scripts/check_project.sh"' in makefile_text
            and "test_validator_rejects_overrideable_makefile_root" in validate_project_test_source,
            "Makefile should protect its root and expose lint, test, build, and check validation entry points",
            failures)
    mutation_test_names = re.findall(
        r"^def (test_validator_rejects_[^\(]+)\(",
        validate_project_test_source,
        re.MULTILINE,
    )
    mutation_test_calls = re.findall(
        r"^\s+(test_validator_rejects_[^\(]+)\(\)",
        validate_project_test_source,
        re.MULTILINE,
    )
    missing_mutation_test_calls = sorted(set(mutation_test_names) - set(mutation_test_calls))
    require(
        not missing_mutation_test_calls,
        "validator mutation tests missing from test_validate_project.main(): "
        + ", ".join(missing_mutation_test_calls),
        failures,
    )
    require('ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"' in check_project_source
            and 'cd "$ROOT"' in check_project_source,
            "check_project should enter its repository root before running relative commands",
            failures)
    require(plan_path.exists() and "status: completed" in plan_text and "make check" in plan_text and "./scripts/check_project.sh" in plan_text,
            "docs/plans should record the completed make-check baseline plan",
            failures)
    require(docs_plan_paths,
            "docs/plans should contain completed maintenance plans",
            failures)
    for docs_plan_path in docs_plan_paths:
        docs_plan_text = docs_plan_path.read_text()
        require("status: completed" in docs_plan_text.lower(),
                f"{docs_plan_path.relative_to(ROOT)} should record completed status",
                failures)
        require("make check" in docs_plan_text,
                f"{docs_plan_path.relative_to(ROOT)} should document make check verification",
                failures)
    stale_reader_statuses = re.findall(r"^status: .+$", stale_reader_plan_text, flags=re.MULTILINE)
    stale_reader_sections = stale_reader_plan_text.split("## Verification Completed\n", 1)
    stale_reader_verification = stale_reader_sections[1] if len(stale_reader_sections) == 2 else ""
    stale_reader_required_evidence = (
        "`./scripts/test_validate_project.py`, `./scripts/check_project.sh`, all four",
        "Pull-request run `27393152277`",
        "push run `27393226357`",
        "CodeQL run `27402321140`",
        "three required `cancelReading()` calls",
    )
    require(stale_reader_statuses == ["status: completed"]
            and all(item in stale_reader_verification for item in stale_reader_required_evidence)
            and re.search(r"\b(?:pending|todo|tbd)\b", stale_reader_verification, re.IGNORECASE) is None
            and "test_validator_rejects_stale_reader_plan_status_regression" in validate_project_test_source
            and "test_validator_rejects_stale_reader_plan_evidence_regression" in validate_project_test_source,
            "stale reader cancellation plan should record completed status and actual verification",
            failures)
    transactional_timing_statuses = re.findall(r"^status: .+$", transactional_timing_plan_text, flags=re.MULTILINE)
    transactional_timing_sections = transactional_timing_plan_text.split("## Verification Completed\n", 1)
    transactional_timing_verification = transactional_timing_sections[1] if len(transactional_timing_sections) == 2 else ""
    transactional_timing_required_evidence = (
        "`./scripts/test_validate_project.py`",
        "`./scripts/validate_project.py`",
        "`./scripts/check_project.sh`",
        "All four Make gates",
        "early timestamp offset mutation failed",
        "early last presentation mutation failed",
        "validator removal mutation failed",
        "hosted pull-request check",
    )
    require(transactional_timing_statuses == ["status: completed"]
            and all(item in transactional_timing_verification for item in transactional_timing_required_evidence)
            and re.search(r"\b(?:pending|todo|tbd|not run)\b", transactional_timing_verification, re.IGNORECASE) is None
            and "test_validator_rejects_transactional_timing_plan_status_regression" in validate_project_test_source
            and "test_validator_rejects_transactional_timing_plan_evidence_regression" in validate_project_test_source,
            "transactional sample timing plan should record completed status and actual verification",
            failures)
    all_branch_ci_statuses = re.findall(r"^status: .+$", all_branch_ci_plan_text, flags=re.MULTILINE)
    all_branch_ci_sections = all_branch_ci_plan_text.split("## Verification Completed\n", 1)
    all_branch_ci_verification = all_branch_ci_sections[1] if len(all_branch_ci_sections) == 2 else ""
    all_branch_ci_required_evidence = (
        "`./scripts/test_validate_project.py`",
        "`./scripts/validate_project.py`",
        "All four Make gates",
        "main-only push mutation failed",
        "main-only pull-request mutation failed",
        "missing pull-request mutation failed",
        "hosted push and pull-request checks",
    )
    require(all_branch_ci_statuses == ["status: completed"]
            and all(item in all_branch_ci_verification for item in all_branch_ci_required_evidence)
            and re.search(r"\b(?:pending|todo|tbd|not run)\b", all_branch_ci_verification, re.IGNORECASE) is None
            and "test_validator_rejects_main_only_push_validation" in validate_project_test_source
            and "test_validator_rejects_main_only_pull_request_validation" in validate_project_test_source
            and "test_validator_rejects_missing_pull_request_validation" in validate_project_test_source,
            "all-branch hosted validation plan should record completed status and actual verification",
            failures)
    location_independent_make_statuses = re.findall(r"^status: .+$", location_independent_make_plan_text, flags=re.MULTILINE)
    location_independent_make_sections = location_independent_make_plan_text.split("## Verification Completed\n", 1)
    location_independent_make_verification = location_independent_make_sections[1] if len(location_independent_make_sections) == 2 else ""
    location_independent_make_required_evidence = (
        "`./scripts/test_validate_project.py`",
        "`./scripts/validate_project.py`",
        "`./scripts/check_project.sh`",
        "All four Make gates",
        "from /tmp",
        "caller-relative Makefile mutation failed",
        "missing check-script root mutation failed",
        "plan-status mutation failed",
        "plan-evidence mutation failed",
        "documentation mutation failed",
    )
    require(location_independent_make_statuses == ["status: completed"]
            and all(item in location_independent_make_verification for item in location_independent_make_required_evidence)
            and re.search(r"\b(?:pending|todo|tbd|not run)\b", location_independent_make_verification, re.IGNORECASE) is None
            and "test_validator_rejects_caller_relative_makefile" in validate_project_test_source
            and "test_validator_rejects_missing_check_project_root" in validate_project_test_source
            and "test_validator_rejects_location_independent_make_plan_status_regression" in validate_project_test_source
            and "test_validator_rejects_location_independent_make_plan_evidence_regression" in validate_project_test_source
            and "test_validator_rejects_location_independent_make_documentation_regression" in validate_project_test_source,
            "location-independent Make plan should record completed status and actual verification",
            failures)
    require("absolute Makefile path" in readme_text
            and "Made project verification independent" in changes_text,
            "README and CHANGES should document location-independent project verification",
            failures)
    require(changes_path.exists() and "make lint" in changes_text and "make test" in changes_text and "make build" in changes_text and "make check" in changes_text and "docs/plans/" in changes_text,
            "CHANGES should record the Makefile validation gate baseline",
            failures)
    require("<!-- README-OVERVIEW-IMAGE -->" in readme_text and "![Project overview](docs/readme-overview.svg)" in readme_text,
            "README should include the project overview SVG near the top",
            failures)
    require("make lint" in readme_text and "make test" in readme_text and "make build" in readme_text and "make check" in readme_text and "./scripts/check_project.sh" in readme_text,
            "README should document the validation script and Makefile gate entry points",
            failures)
    require("make lint" in vision_text and "make test" in vision_text and "make build" in vision_text and "make check" in vision_text and "./scripts/check_project.sh" in vision_text,
            "VISION should keep the Makefile gate entry points aligned with the project script",
            failures)
    require("make lint" in agents_text and "make test" in agents_text and "make build" in agents_text and "make check" in agents_text and "./scripts/check_project.sh" in agents_text,
            "AGENTS should document the Makefile gate entry points and check script",
            failures)
    require("CHECK_SKIP_SWIFT" in agents_text and "swift is unavailable" in agents_text,
            "AGENTS should document partial validation when the Swift toolchain is unavailable",
            failures)
    require("at most 24 hours" in agents_text and "[`SECURITY.md`](SECURITY.md)" in agents_text,
            "AGENTS should document the bounded runtime diagnostic log window and security policy link",
            failures)
    require("no greater than 24" in readme_text and "absolute path ending in" in readme_text and "capped at 24 hours" in security_text and "at most 24 hours" in vision_text,
            "README, SECURITY, and VISION should document the bounded runtime diagnostic log window",
            failures)
    require(readme_overview_path.exists() and readme_overview_path.stat().st_size > 0,
            "README overview SVG should exist and be non-empty",
            failures)
    require(readme_overview_xml_valid,
            "README overview SVG should be valid XML",
            failures)
    required_overview_fragments = (
        "Gareth Mac Virtual Camera project overview",
        "SwiftUI host app plus CoreMediaIO camera extension",
        "Host App",
        "CMIO Extension",
        "Virtual Camera",
        "Gareth Video Cam",
        "check_project.sh plus CI build",
        "Runtime Evidence",
        "signed host, entitlement, approval",
        "Documented gates: build, validation, activation.",
    )
    require(all(fragment in readme_overview_text for fragment in required_overview_fragments),
            "README overview SVG should describe the actual virtual camera architecture, validation, and runtime evidence path",
            failures)
    forbidden_overview_fragments = (
        "Apple platform application or",
        "Objective-C/Swift sample",
        "Generated overview of the repository",
        "VirtualCamera for Mac that Plays MP4 in Loop",
        "Manifests: None detected",
        "Integrations: None detected",
        "Tests: scripts/test_collect_runti",
        "me_diagnostics.sh,",
        "authentication, database",
        "file_parsing, mobile_privacy",
    )
    require(not any(fragment in readme_overview_text for fragment in forbidden_overview_fragments),
            "README overview SVG should avoid generic generated labels and clipped test names",
            failures)
    require("Canonical security policy and reporting:" in vision_text and "[`SECURITY.md`](SECURITY.md)" in vision_text,
            "VISION should link the canonical security policy",
            failures)
    required_security_fragments = (
        "Gareth Mac Virtual Camera is a macOS SwiftUI host app with an embedded CoreMediaIO system extension.",
        "Extension/video.mp4",
        "Gareth Video Cam",
        "system-extension activation, deactivation, approval, and registration handling",
        "host and extension code signing, Team ID matching, and entitlement validation",
        "shared app-group configuration between the host app and embedded extension",
        "bundled-video parsing, metadata validation, and pixel-buffer stream-format checks",
        "runtime diagnostics that collect signing, entitlement, process, camera inventory, and unified-log evidence",
        "shell scripts and CI workflows that build, verify, or scan project artifacts",
        "Do not add hidden camera capture, external streaming, upload behavior, entitlement shortcuts",
        "./scripts/check_project.sh",
        ".github/workflows/macos-build.yml",
    )
    require(all(fragment in security_text for fragment in required_security_fragments),
            "SECURITY should describe the actual virtual camera threat model and validation surfaces",
            failures)
    forbidden_security_fragments = (
        "Project summary: VirtualCamera for Mac that Plays MP4 in Loop",
        "Apple platform application or Swift sample",
        "Review found authentication",
        "Review found external API integrations",
        "Review found network clients",
        "Review found database",
    )
    require(not any(fragment in security_text for fragment in forbidden_security_fragments),
            "SECURITY should avoid generic generated claims that do not match this project",
            failures)
    require("Swift 6 language mode" in readme_text and project_text.count("SWIFT_VERSION = 6.0;") == 4 and "SWIFT_VERSION = 5.0;" not in project_text,
            "app and extension targets should use Swift 6 language mode",
            failures)
    required_readme_target_fragments = (
        "Stable CI toolchain: Xcode 26.5 with the macOS 26.5 SDK",
        "Stable macOS compatibility reference: macOS Tahoe 26.5.1",
        "Deployment target: macOS 14.0 or later",
        "Pre-release watch items as of June 9, 2026: Xcode 26.6 beta, macOS 26.6 beta (25G5028f), Xcode 27 beta (27A5194q, Swift 6.4, macOS 27 SDK, Apple silicon-only installer), and macOS Golden Gate 27 beta (26A5353q)",
        "keep CI on stable Xcode 26.5 until those prerelease toolchains are stable and available on GitHub-hosted runners",
    )
    require("## Current Target" in readme_text and all(fragment in readme_text for fragment in required_readme_target_fragments),
            "README should distinguish stable CI target versions from prerelease Apple toolchain watch items",
            failures)
    require(project_text.count("ENABLE_HARDENED_RUNTIME = YES;") >= 4,
            "all app and extension configurations should enable hardened runtime",
            failures)
    require(project_text.count("CODE_SIGN_ENTITLEMENTS = GarethVideoCam/Entitlements.entitlements;") == 2,
            "host app Debug and Release configurations should use the host entitlements file",
            failures)
    require(project_text.count("CODE_SIGN_ENTITLEMENTS = Extension/Extension.entitlements;") == 2,
            "extension Debug and Release configurations should use the extension entitlements file",
            failures)
    require("$(SYSTEM_EXTENSIONS_FOLDER_PATH)" in project_text and "Embed System Extensions" in project_text,
            "project should embed the extension in the app SystemExtensions folder",
            failures)
    require('"Gareth Video Cam";' in project_text and '"Gareth Video Cam publishes a virtual camera stream."' in project_text and '"Gareth Video Cam Extension"' in project_text and '"Gareth Video Cam publishes the bundled video as a virtual camera stream."' in project_text,
            "project should use product-specific generated Info.plist display and privacy strings",
            failures)
    require('explicitFileType = "wrapper.system-extension";' in project_text and 'productType = "com.apple.product-type.system-extension";' in project_text,
            "project should keep the extension configured as a system extension product",
            failures)
    require("video.mp4 in Resources" in project_text,
            "project should bundle Extension/video.mp4 in the extension resources",
            failures)
    require("collect_runtime_diagnostics.sh in Resources" in project_text and "validate_project.py in Resources" in project_text and "Runtime Diagnostics" in project_text,
            "project should bundle runtime diagnostics helpers in the host app resources",
            failures)
    require("Preview Assets.xcassets in Resources" not in project_text and "DEVELOPMENT_ASSET_PATHS" in project_text,
            "project should keep preview assets available for previews without bundling them in app resources",
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
    require("""            if Task.isCancelled {
                readerState.assetReader.cancelReading()
                return
            }""" in extension_source,
            "extension should cancel a prepared asset reader when stream preparation is cancelled",
            failures)
    require("""                guard let self else {
                    readerState.assetReader.cancelReading()
                    return
                }""" in extension_source,
            "extension should cancel a prepared asset reader when its device source is released",
            failures)
    require("""                guard self.isCurrentStreamPreparation(generation: generation, videoURL: videoURL) else {
                    readerState.assetReader.cancelReading()
                    logger.debug("Ignoring stale stream preparation completion")""" in extension_source,
            "extension should cancel a prepared asset reader when its queued completion becomes stale",
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
    require("invalidVideoDimensions" in extension_source and "guard let displayDimensions = Self.displayDimensions" in extension_source and "-> CMVideoDimensions?" in extension_source and "roundedWidth.isFinite" in extension_source and "roundedHeight.isFinite" in extension_source and "roundedWidth <= CGFloat(Int32.max)" in extension_source and "roundedHeight <= CGFloat(Int32.max)" in extension_source and "test_validator_rejects_missing_video_dimension_unwrap_guard" in validate_project_test_source and "test_validator_rejects_missing_finite_video_dimension_guard" in validate_project_test_source,
            "extension should reject non-finite or out-of-range bundled-video dimensions before integer conversion",
            failures)
    require("guard nominalFrameRate.isFinite," in extension_source and "test_validator_rejects_missing_non_finite_video_frame_rate_guard" in validate_project_test_source,
            "extension should reject non-finite bundled-video frame rates before streaming",
            failures)
    require("unexpectedVideoDimensions" in extension_source and "unexpectedVideoFrameRate" in extension_source,
            "extension should report actionable bundled-video track mismatches",
            failures)
    require("Unable to loop the bundled video: \\(error.localizedDescription" in extension_source,
            "extension should log loop restart failures with actionable error details",
            failures)
    require("guard let assetReader else" in extension_source and
            "case .reading:\n            return" in extension_source and
            "case .completed:\n            break" in extension_source and
            "case .failed:" in extension_source and
            "case .cancelled:\n            logger.error(\"Asset reader was cancelled while streaming\")\n            stopStreamingSession()" in extension_source and
            "case .unknown:\n            logger.error(\"Asset reader entered an unknown state while streaming\")\n            stopStreamingSession()" in extension_source and
            "@unknown default:" in extension_source and
            "test_validator_rejects_reader_loop_while_reading" in validate_project_test_source and
            "test_validator_rejects_reader_loop_before_completion" in validate_project_test_source,
            "extension should loop bundled video only after the asset reader completes",
            failures)
    require("CMSampleBufferDataIsReady(sampleBuffer)" in extension_source and "Skipping sample buffer that is not ready" in extension_source,
            "extension should skip asset-reader sample buffers that are not ready",
            failures)
    require("validateSampleBufferPixelBuffer(sampleBuffer)" in extension_source and "CMSampleBufferGetImageBuffer(sampleBuffer)" in extension_source and "Skipping sample buffer without a CVPixelBuffer image buffer" in extension_source,
            "extension should skip sample buffers that do not expose a CVPixelBuffer",
            failures)
    require("CVPixelBufferGetPixelFormatType(imageBuffer)" in extension_source and "pixelFormat == CameraExtensionConfiguration.pixelFormat" in extension_source and "Skipping sample buffer with unexpected pixel format" in extension_source,
            "extension should skip sample buffers whose pixel format does not match the advertised stream format",
            failures)
    require("CVPixelBufferGetWidth(imageBuffer)" in extension_source and "CVPixelBufferGetHeight(imageBuffer)" in extension_source and "Skipping sample buffer with unexpected pixel buffer dimensions" in extension_source,
            "extension should skip sample buffers whose dimensions do not match the advertised stream dimensions",
            failures)
    require("private static func isFiniteTime(_ time: CMTime) -> Bool" in extension_source and "return time.isNumeric" in extension_source and "guard Self.isFiniteTime(presentationTime)" in extension_source and "guard Self.isFiniteTime(timing.decodeTimeStamp)" in extension_source and "guard Self.isFiniteTime(adjustedDecodeTime)" in extension_source and "Skipping sample buffer with non-finite adjusted decode timestamp" in extension_source and "guard Self.isFiniteTime(hostTime)" in extension_source,
            "extension should reject non-finite sample and host times before retiming",
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
    require("invalidFrameDuration" in extension_source and "throw CameraExtensionError.invalidFrameDuration" in extension_source and "streamProperties.frameDuration" in extension_source and "frameDuration.isNumeric" in extension_source and "!frameDuration.flags.contains(.indefinite)" in extension_source and "test_validator_rejects_missing_non_finite_stream_duration_guard" in validate_project_test_source,
            "extension stream should reject unsupported, indefinite, or non-finite frame-duration requests",
            failures)
    require("guard duration.isNumeric," in extension_source and "duration.flags.contains(.valid)" in extension_source and "CameraExtensionError.invalidVideoDuration" in extension_source and "test_validator_rejects_missing_non_finite_asset_duration_guard" in validate_project_test_source,
            "extension should reject non-finite bundled-video durations before loop scheduling",
            failures)
    require("validFrameDurations: [CameraExtensionConfiguration.frameDuration]" in extension_source,
            "extension stream should advertise the fixed frame duration it enforces",
            failures)
    require('UUID(uuidString:' not in extension_source and "static let deviceID = UUID(uuid:" in extension_source and "static let streamID = UUID(uuid:" in extension_source,
            "extension should use stable byte-literal UUIDs instead of force-unwrapped UUID string parsing",
            failures)
    require("timing.duration = CameraExtensionConfiguration.frameDuration" in extension_source and "if !timing.duration.flags.contains(.valid)" not in extension_source,
            "extension should retime every emitted sample to the advertised fixed frame duration",
            failures)
    require("CMSampleBufferGetNumSamples(sampleBuffer) == 1" in extension_source and "Skipping sample buffer with unexpected sample count" in extension_source and "let timingStatus = CMSampleBufferGetSampleTimingInfo" in extension_source and "guard timingStatus == noErr else" in extension_source and "Failed to read sample timing info" in extension_source and "let copyStatus = CMSampleBufferCreateCopyWithNewTiming" in extension_source and "guard copyStatus == noErr, let retimedSampleBuffer = copiedSampleBuffer else" in extension_source and "Failed to retime sample buffer" in extension_source and "test_validator_rejects_missing_sample_count_retiming_guard" in validate_project_test_source and "test_validator_rejects_missing_sample_timing_status_guard" in validate_project_test_source and "test_validator_rejects_missing_retimed_copy_status_guard" in validate_project_test_source,
            "extension should require one-sample buffers and CoreMedia retiming calls to succeed before streaming",
            failures)
    require("private var hostPresentationTimebase: CMTime?" in extension_source and "hostPresentationTime(for assetPresentationTime: CMTime" in extension_source and "timebase: CMTime?) -> (presentationTime: CMTime, timebase: CMTime)?" in extension_source and "let hostScaledAssetPresentationTime = CMTimeConvertScale(assetPresentationTime" in extension_source and "let basePresentationTime = CMTimeSubtract(currentHostTime, assetPresentationTime)" in extension_source and "let hostPresentationTime = CMTimeAdd(timebase, assetPresentationTime)" in extension_source and "hostTimeInNanoseconds: hostTimeInNanoseconds" in extension_source,
            "extension should retime emitted sample timestamps into the advertised host-time clock domain",
            failures)
    require("enum SampleTimestampValidator" in sample_timestamp_validator_source
            and "CMTimeCompare(presentationTime, previousPresentationTime) > 0" in sample_timestamp_validator_source
            and extension_source.count("SampleTimestampValidator.strictlyAdvances") == 2
            and "duplicate or regressing presentation timestamp" in extension_source
            and "duplicate or regressing host presentation timestamp" in extension_source
            and "testRejectsDuplicateSyntheticSampleTimestamp" in sample_timestamp_test_source
            and "testRejectsRegressingSyntheticSampleTimestamp" in sample_timestamp_test_source,
            "extension should reject duplicate or regressing source and host timestamps",
            failures)
    require('let failureDescription = nextAssetReader.error?.localizedDescription ?? "unknown error"' in extension_source
            and "nextAssetReader.cancelReading()" in extension_source
            and "throw CameraExtensionError.assetReaderFailedToStart(failureDescription)" in extension_source
            and "test_validator_rejects_missing_failed_reader_cancellation" in validate_project_test_source,
            "extension should cancel a partially started reader before propagating startup failure",
            failures)
    require("SampleTimestampValidator.swift in Sources" in project_text
            and 'name: "CameraTimeline"' in package_source
            and ".macOS(.v14)" in package_source
            and 'swift test --scratch-path "$SWIFT_TEST_SCRATCH"' in check_project_source
            and "python3 -m py_compile" in check_project_source
            and "CHECK_SKIP_SWIFT" in check_project_source,
            "project checks should compile and run the synthetic sample timestamp unit tests",
            failures)
    restart_index = extension_source.find("let nextReaderState = try makeAssetReader")
    loop_commit_index = extension_source.find("advanceLoopTiming(by: assetDuration)", restart_index)
    reader_install_index = extension_source.find("installAssetReaderState(nextReaderState)", loop_commit_index)
    require(min(restart_index, loop_commit_index, reader_install_index) >= 0
            and restart_index < loop_commit_index < reader_install_index,
            "extension should start the replacement reader before committing loop timing state",
            failures)
    candidate_offset_index = extension_source.find("let candidateTimestampOffset = timestampOffset")
    retimed_sample_index = extension_source.find("guard let retimedSampleBuffer = retimedSampleBuffer(from: sampleBuffer")
    offset_commit_index = extension_source.find("timestampOffset = candidateTimestampOffset", retimed_sample_index)
    presentation_commit_index = extension_source.find("lastPresentationTime = presentationTime", retimed_sample_index)
    host_presentation_commit_index = extension_source.find("lastHostPresentationTime = hostTiming.presentationTime", retimed_sample_index)
    timebase_commit_index = extension_source.find("hostPresentationTimebase = hostTiming.timebase", retimed_sample_index)
    stream_send_index = extension_source.find("_streamSource.stream.send(retimedSampleBuffer", retimed_sample_index)
    require(
        min(candidate_offset_index, retimed_sample_index, offset_commit_index,
            presentation_commit_index, host_presentation_commit_index,
            timebase_commit_index, stream_send_index) >= 0
        and candidate_offset_index < retimed_sample_index
        < offset_commit_index < presentation_commit_index < host_presentation_commit_index
        < timebase_commit_index < stream_send_index
        and extension_source.find("timestampOffset = candidateTimestampOffset") == offset_commit_index
        and extension_source.find("lastPresentationTime = presentationTime") == presentation_commit_index
        and extension_source.find("lastHostPresentationTime = hostTiming.presentationTime") == host_presentation_commit_index
        and extension_source.find("hostPresentationTimebase = hostTiming.timebase") == timebase_commit_index
        and "timestampOffset = CMTimeAdd(timestampOffset, assetDuration)" not in extension_source
        and "test_validator_rejects_early_timestamp_offset_commit" in validate_project_test_source
        and "test_validator_rejects_early_last_presentation_commit" in validate_project_test_source
        and "test_validator_rejects_missing_transactional_timing_validator" in validate_project_test_source,
        "extension should commit sample timing state only after retiming succeeds",
        failures,
    )
    require("case needsApplicationLocation" in host_source and "case needsBundleIdentifier" in host_source and "case needsApplicationExecutable" in host_source and "canSubmitActivationRequest" in host_source and "canSubmitDeactivationRequest" in host_source and "prepareForHostSystemExtensionRequest" in host_source and "prepareForSystemExtensionDeactivationRequest" in host_source,
            "host app should model the /Applications, host bundle identifier, and host executable requirements before submitting system-extension requests",
            failures)
    require("@MainActor\nfinal class SystemExtensionRequestManager" in host_source and "@preconcurrency OSSystemExtensionRequestDelegate" in host_source,
            "host system-extension request manager should keep UI state mutations isolated to the main actor",
            failures)
    require('expectedApplicationBundlePath = "/Applications/GarethVideoCam.app"' in host_source and "applicationLocationReadinessDetail" in host_source and "isRunningFromExpectedApplicationPath" in host_source and "Expected App Path" in host_source,
            "host app should require and display the exact expected /Applications app path",
            failures)
    code_signing_unknown_state = """enum CodeSigningStatus: Equatable {
        case valid(String, String?, Set<String>, Set<String>)
        case invalid(String)
        case unknown(String)
"""
    require("import Security" in host_source and code_signing_unknown_state in host_source and "isUnknown" in host_source and "SecStaticCodeCheckValidityWithErrors" in host_source and "kSecCSCheckAllArchitectures" in host_source and "validationError" in host_source and "takeRetainedValue" in host_source and "CFErrorCopyDescription" in host_source and "signing information could not be read" in host_source,
            "host app should distinguish unknown and invalid code-signing states, validate all architecture slices, and preserve detailed validation errors before submitting system-extension requests",
            failures)
    require("appCodeSigningStatus" in host_source and "extensionCodeSigningStatus" in host_source and "Extension Signing Required" in host_source and "The embedded system extension code signature is valid across all architecture slices." in host_source and "System extension signature has not been checked because the embedded extension could not be loaded." in host_source,
            "host app should validate both the container app and embedded system-extension signatures before submitting requests",
            failures)
    require("SecCodeCopySigningInformation" in host_source and "kSecCodeInfoTeamIdentifier" in host_source and "signingTeamReadinessDetail" in host_source and "Team Identifier Required" in host_source,
            "host app should verify matching app and embedded system-extension signing team identifiers before submitting requests",
            failures)
    require("isTeamIdentifier" in host_source and "^[A-Za-z0-9]{10}$" in host_source and "!teamIdentifier.isEmpty,\n              isTeamIdentifier(teamIdentifier) else" in host_source,
            "host app should validate signing Team IDs before comparing app and extension signatures",
            failures)
    require("private static func wholeRegularExpressionMatch(_ value: String, pattern: String) -> Bool" in host_source and "guard let range = value.range(of: pattern, options: .regularExpression) else" in host_source and "range == value.startIndex..<value.endIndex" in host_source and "wholeRegularExpressionMatch(teamIdentifier, pattern:" in host_source and "wholeRegularExpressionMatch(groupIdentifier, pattern:" in host_source and "wholeRegularExpressionMatch(machServiceName, pattern:" in host_source and "    test_validator_rejects_missing_host_whole_regex_match_guard()" in validate_project_test_source,
            "host app should require whole-string regex matches for Team IDs, app groups, and CMIO Mach services",
            failures)
    require("requiredSystemExtensionInstallEntitlement" in host_source and "kSecCodeInfoEntitlementsDict" in host_source and "hasEnabledEntitlement" in host_source and "appEntitlementReadinessDetail" in host_source and "Entitlement Required" in host_source,
            "host app should verify the signed app has the System Extension entitlement before submitting requests",
            failures)
    require("guard let isEnabled = value as? Bool else" in host_source and "if let number = value as? NSNumber" not in host_source,
            "host app should only accept boolean signed entitlement values",
            failures)
    require("extensionHostOnlyEntitlementReadinessDetail" in host_source and "Extension Entitlement Required" in host_source and "Extension Host Entitlement" in host_source and "Extension Host-Only Entitlement:" in host_source,
            "host app should verify the signed embedded extension omits the host-only System Extension entitlement before submitting requests",
            failures)
    require("applicationGroupsEntitlement" in host_source and "applicationGroupReadinessDetail" in host_source and "Application Group Required" in host_source and "Application Group" in host_source and "App Application Groups:" in host_source and "Extension Application Groups:" in host_source and "Application Group Check:" in host_source and "Shared Application Group:" in host_source and "entitlementValue as? String" not in host_source,
            "host app should verify, show, and copy matching app-group entitlements before submitting requests",
            failures)
    require("let trimmedGroupIdentifier = groupIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)" in host_source and "groupIdentifier.rangeOfCharacter(from: .newlines) == nil" in host_source and "trimmedGroupIdentifier == groupIdentifier" in host_source and "    test_validator_rejects_untrimmed_signed_app_group_values()" in validate_project_test_source and "    test_validator_rejects_multiline_signed_app_group_values()" in validate_project_test_source,
            "host app should reject blank, untrimmed, or multiline signed app-group entitlement values",
            failures)
    require(host_source.count("^[A-Za-z0-9]{10}\\\\.") >= 2,
            "host app should restrict Team-ID-prefixed app groups and CMIO Mach services to 10-character Team IDs",
            failures)
    require("groupIdentifier == baseIdentifier" not in host_source and "Team ID-prefixed application group ending in" in host_source,
            "host app should require Team-ID-prefixed app-group identifiers rather than bare group names",
            failures)
    require("NSRegularExpression.escapedPattern(for: baseIdentifier)" in host_source and "^[A-Za-z0-9]{10}\\\\." in host_source,
            "host app should only accept Team-ID-prefixed app-group identifiers",
            failures)
    require("case needsSigning" in host_source and "requestReadinessMessage" in host_source and "checked app signature" in host_source and "checked system extension signature" in host_source and "App Signature" in host_source and "Extension Signature" in host_source,
            "host app should surface unknown and invalid signing readiness in state, controls, and details",
            failures)
    require("case needsExtensionMetadata" in host_source and "case needsBundledVideo" in host_source and "Extension Metadata Required" in host_source and "Bundled Video Required" in host_source and "recordReadinessBlock(state: .needsExtensionMetadata" in host_source and "recordReadinessBlock(state: .needsBundledVideo" in host_source,
            "host app should report extension metadata and bundled-video packaging blockers as distinct readiness states",
            failures)
    require("requestReadinessStatus" in host_source and "requestReadinessDetail" in host_source and "requestReadinessNextAction" in host_source and "Request Readiness" in host_source and "Readiness Detail" in host_source and "Readiness Next Action" in host_source and "Request Readiness Next Action:" in host_source,
            "host app should show and copy exact system-extension request readiness blockers and next actions",
            failures)
    require("activationRequestReadinessStatus" in host_source and "activationRequestReadinessDetail" in host_source and "deactivationRequestReadinessStatus" in host_source and "deactivationRequestReadinessDetail" in host_source and "Activation Request Readiness:" in host_source and "Activation Request Detail:" in host_source and "Deactivation Request Readiness:" in host_source and "Deactivation Request Detail:" in host_source and 'DetailRow(title: "Activation Request Readiness"' in host_source and 'DetailRow(title: "Deactivation Request Readiness"' in host_source,
            "host app should show and copy request-specific activation and deactivation readiness evidence",
            failures)
    require("case needsBundleVersion" in host_source and "Version Mismatch" in host_source and "bundleVersionReadinessDetail" in host_source and "Bundle Version Match" in host_source and "Bundle Version Check:" in host_source and "Version Match Required" in host_source and "recordReadinessBlock(state: .needsBundleVersion" in host_source and "bundleVersionStatus" in host_source and "applicationShortVersionValue" in host_source and "applicationBuildVersionValue" in host_source and "shortVersion: String?" in host_source and "buildVersion: String?" in host_source and "Bundle Short Version Match" in host_source and "Bundle Build Version Match" in host_source,
            "host app should verify, show, and copy app and embedded extension short/build bundle version alignment before submitting requests",
            failures)
    require("HeaderView(manager: manager)" in host_source and 'Text(manager.requestReadinessDetail ?? "System extension requests can be submitted.")' in host_source and "private var headerActions" in header_view_source and "headerActionButtons" in header_view_source and 'Button(action: manager.refreshStatus)' in header_view_source and 'Label("Refresh", systemImage: "arrow.clockwise")' in header_view_source and 'Button(action: manager.copyActivationChecklist)' in header_view_source and 'Label("Copy Checklist", systemImage: "checklist")' in header_view_source and 'Button(action: manager.copyDiagnostics)' in header_view_source and 'Label("Copy Diagnostics", systemImage: "doc.on.doc")' in header_view_source and "test_validator_rejects_missing_header_action_buttons" in validate_project_test_source,
            "host app header should surface the current request readiness detail and primary refresh, checklist, and diagnostics actions",
            failures)
    require("struct ReadinessCheck" in host_source and "readinessChecks" in host_source and "readinessProgressSummary" in host_source and "summaryParts" in host_source and "joined(separator: \", \")" in host_source and "requestReadinessNextAction" in host_source and "ReadinessPanel(manager: manager)" in host_source and "ReadinessRow" in host_source and "Team ID Match" in host_source and "Bundle Version Match" in host_source and "App Executable" in host_source and "Extension Executable" in host_source and "Extension Host Entitlement" in host_source and "Application Group" in host_source and "Extension Metadata" in host_source and "Bundled Video" in host_source and "Readiness Summary:" in host_source and "Readiness Checks:" in host_source,
            "host app should show and copy a compact readiness summary with ready, blocked, and pending counts, next action, and checklist for activation gates",
            failures)
    require("case evidence" in host_source and "RuntimeEvidencePanel(manager: manager)" in host_source and "private struct RuntimeEvidencePanel" in host_source and "struct RuntimeEvidenceCheck" in host_source and "runtimeEvidenceChecks" in host_source and "runtimeEvidenceExpectedDiagnostics" in host_source and "Runtime Evidence" in host_source and "Current Readiness" in host_source and "Next Action" in host_source and "Command Source" in host_source and "Diagnostics Command" in host_source and "Application location ready" in host_source and "App bundle identifier ready" in host_source and "App signature ready" in host_source and "App System Extension entitlement ready" in host_source and "App executable ready" in host_source and "Extension bundle identifier ready" in host_source and "Extension signature ready" in host_source and "Extension host-only entitlement absent" in host_source and "Extension executable ready" in host_source and "Extension CMIO Mach service ready" in host_source and "Bundle versions match ready" in host_source and "Signing Team match ready" in host_source and "ForEach(Array(manager.runtimeEvidenceChecks.enumerated()), id: \\.element.id)" in host_source,
            "host app should show a dedicated runtime evidence section with expected signed-host diagnostics",
            failures)
    require("Bundled video ready" in host_source and "Bundled video metadata ready" in host_source and 'RuntimeEvidenceCheck(id: "video-metadata"' in host_source,
            "host app runtime evidence should include bundled-video resource and metadata readiness",
            failures)
    require("let checks = manager.readinessChecks" in host_source and "ForEach(Array(checks.enumerated()), id: \\.element.id)" in host_source,
            "host readiness panel should render a stable checklist snapshot",
            failures)
    require("private var readinessTitle" in host_source and "private var readinessDetail" in host_source and "private var readinessStatus" in host_source and "Text(check.status.title)" in host_source and ".fixedSize(horizontal: true, vertical: false)" in host_source,
            "host readiness checklist rows should keep titles, details, and status labels responsive and readable",
            failures)
    require("applicationIdentifierReadinessDetail" in host_source and "applicationBundleIdentifierStatus" in host_source and "App Bundle ID Check" in host_source and "App Identifier Required" in host_source,
            "host app should block requests when the host bundle identifier does not match the expected identifier",
            failures)
    require("applicationExecutableReadinessDetail" in host_source and "App Executable Required" in host_source and "App Executable" in host_source and "App Executable Path:" in host_source and "App Executable Check:" in host_source,
            "host app should block requests when the host app executable is missing or not executable",
            failures)
    require("lastFailureDetail" in host_source and "Last Failure" in host_source and "No failure recorded." in host_source and "Readiness Failed" in host_source and "Request Failed" in host_source and "extensionLoadFailureDetail" in host_source and "Extension Load Failure:" in host_source and 'DetailRow(title: "Extension Load Failure"' in host_source,
            "host app should preserve the last readiness, extension-load, or request failure in details and copied diagnostics",
            failures)
    require("private func recordReadinessBlock" in host_source and "lastFailureDetail = detail" in host_source,
            "host app should record install/uninstall readiness blocks as the last failure detail",
            failures)
    require("firstActivity.level == level" in host_source and "activity.removeFirst()" in host_source,
            "host app should collapse duplicate adjacent activity entries",
            failures)
    require(".disabled(manager.isBusy || !manager.canSubmitActivationRequest)" in host_source and ".disabled(manager.isBusy || !manager.canSubmitDeactivationRequest)" in host_source,
            "host app should disable install and uninstall controls against their request-specific readiness gates",
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
    require("extensionBundleURLs.count == 1" in host_source and "multipleBundledExtensions" in host_source and "Expected exactly one bundled .systemextension" in host_source and "extensionBundleURLs.map(\\.lastPathComponent)" in host_source and "test_validator_rejects_missing_host_duplicate_extension_guard" in validate_project_test_source,
            "host app should reject ambiguous products with multiple bundled system extensions",
            failures)
    require("executableName" in host_source and "executablePath" in host_source and "machServiceName" in host_source and "CFBundleExecutable" in host_source and "validateExtensionExecutable" in host_source and "CMIOExtensionMachServiceName" in host_source and "videoPath" in host_source and "videoByteCount" in host_source and "videoMetadata" in host_source and "BundledVideoMetadata" in host_source and "VideoDimensions" in host_source and "Contents" in host_source and "MacOS" in host_source and "Resources" in host_source and "video.mp4" in host_source and "fileExists(atPath: videoURL.path, isDirectory:" in host_source,
            "host app should capture executable, CMIO, and bundled-video resource metadata from the embedded extension",
            failures)
    require("missingExtensionExecutable" in host_source and "invalidExtensionExecutable" in host_source and "missingExtensionMachService" in host_source and "missingBundledVideoResource" in host_source and "emptyBundledVideoResource" in host_source and "unreadableBundledVideoMetadata" in host_source and "bundledVideoByteCount" in host_source and "bundledVideoMetadata(at:" in host_source and "expectedBundledVideoWidth" in host_source and "expectedBundledVideoHeight" in host_source and "expectedBundledVideoFrameRate" in host_source and "parseable video dimensions" in host_source and "parseable constant video frame rate" in host_source and "positive video duration" in host_source,
            "host app should fail readiness when embedded extension metadata or video resource metadata is missing or unexpected",
            failures)
    require('guard let executableName = Self.infoPlistString(in: extensionBundle, key: "CFBundleExecutable")' in host_source and "private static func extensionMachServiceName(in bundle: Bundle) -> String?" in host_source and 'cmioExtension["CMIOExtensionMachServiceName"] as? String' in host_source and "trimmedValue == value" in host_source and "value.rangeOfCharacter(from: .newlines) == nil" in host_source and "trimmedMachServiceName == machServiceName" in host_source and "machServiceName.rangeOfCharacter(from: .newlines) == nil" in host_source and "guard let machServiceName = Self.extensionMachServiceName(in: extensionBundle)" in host_source and "test_validator_rejects_raw_extension_executable_metadata" in validate_project_test_source and "test_validator_rejects_untrimmed_host_info_plist_metadata" in validate_project_test_source and "test_validator_rejects_multiline_host_info_plist_metadata" in validate_project_test_source and "test_validator_rejects_raw_extension_cmio_metadata" in validate_project_test_source and "test_validator_rejects_untrimmed_host_cmio_metadata" in validate_project_test_source and "test_validator_rejects_multiline_host_cmio_metadata" in validate_project_test_source,
            "host app should reject blank, untrimmed, or multiline embedded extension Info.plist and CMIO metadata strings",
            failures)
    require("private static func isExecutableName(_ executableName: String) -> Bool" in host_source and "!executableName.isEmpty" in host_source and "!executableName.contains(\"/\")" in host_source and "invalidExtensionExecutableName" in host_source and "guard Self.isExecutableName(executableName)" in host_source and "test_validator_rejects_missing_host_executable_name_shape_guard" in validate_project_test_source,
            "host app should reject blank or path-like embedded extension executable names",
            failures)
    require("MP4Atom" in host_source and "atoms(in data:" in host_source and "atomType(in data:" in host_source and "readUInt16" in host_source and "readUInt32" in host_source and "readUInt64" in host_source and "parseMdhd" in host_source and "guard version == 0 else" in host_source and "version != 0" in validate_project_source and "parseHdlr" in host_source and "parseStts" in host_source and "findSttsEntries" in host_source and "parseStsdDimensions" in host_source and "var trackDimensions: VideoDimensions?" in host_source and "trackDimensions = dimensions" in host_source and "videoMetadata.dimensions = trackDimensions" in host_source and "track_dimensions = None" in validate_project_source and "track_dimensions = video_dimensions" in validate_project_source and 'video_metadata["dimensions"] = track_dimensions' in validate_project_source and host_source.count("guard data[payloadStart] == 0 else") >= 3 and validate_project_source.count("data[payload_start] != 0") >= 3 and "avc1" in host_source and "hvc1" in host_source and "hev1" in host_source and "mp4v" in host_source,
            "host app should parse bundled MP4 video dimensions, frame rate, and duration for readiness",
            failures)
    require("sampleCount > 0" in host_source and "sample_count, sample_delta = sample_durations[0]" in validate_project_source and "sample_count and sample_delta" in validate_project_source and "test_zero_sample_count_stts_does_not_report_frame_rate" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_sample_count_guard" in validate_project_test_source,
            "host app should only accept positive-sample MP4 timing entries when parsing bundled-video frame rate",
            failures)
    require("timescale % sampleDelta == 0" in host_source and validate_project_source.count("timescale % sample_delta == 0") >= 2 and "test_non_integer_stts_rate_does_not_report_frame_rate" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_integer_frame_rate_guard" in validate_project_test_source,
            "host app should only report MP4 frame rates with exact integer sample timing",
            failures)
    require("Int(entryCount) <= maxEntryCount" in host_source and "sampleDescriptions.prefix(Int(entryCount))" in host_source and "entry_count > max_entry_count" in validate_project_source and "sample_descriptions[:entry_count]" in validate_project_source,
            "host app should reject incomplete MP4 timing and sample-description tables",
            failures)
    require("extensionInfo != nil" in host_source and "extensionExecutableReadinessDetail == nil" in host_source and "extensionMetadataReadinessDetail == nil" in host_source and "bundledVideoReadinessDetail == nil" in host_source and "extensionLoadFailureDetail" in host_source and "isExtensionExecutableFailureDetail" in host_source and "isExtensionMetadataFailureDetail" in host_source and "isBundledVideoFailureDetail" in host_source and "isBundledExtensionFailureDetail" in host_source and "bundled .systemextension" in host_source and "Expected bundled extension" in host_source and "containsUnresolvedBuildSetting" in host_source and "isExpectedMachServiceName" in host_source and "Team ID-prefixed value ending in" in host_source and "bundledVideoMetadataSummary" in host_source,
            "host app should make extension executable, resolved CMIO Mach service, and bundled-video readiness explicit system-extension request gates",
            failures)
    require("NSRegularExpression.escapedPattern(for: extensionIdentifier)" in host_source and "^[A-Za-z0-9]{10}\\\\." in host_source,
            "host app should only accept direct or single Team-ID-prefixed CMIO Mach service identifiers",
            failures)
    require("App Executable Path:" in host_source and "App Executable Check:" in host_source and "Extension Load Failure:" in host_source and "Extension Executable:" in host_source and "Extension Executable Path:" in host_source and "Extension Executable Check:" in host_source and "Extension CMIO Mach Service:" in host_source and "Extension CMIO Mach Service Resolved:" in host_source and "Extension CMIO Mach Service Identifier Match:" in host_source and "Extension Bundle Path" in host_source and "Extension Executable" in host_source and "Extension Executable Path" in host_source and "Extension CMIO Mach Service" in host_source and "Extension CMIO Mach Service Resolved" in host_source and "Extension CMIO Mach Service Identifier Match" in host_source and "Bundled Video Path" in host_source and "Bundled Video Size" in host_source and "Bundled Video Dimensions" in host_source and "Bundled Video Frame Rate" in host_source and "Bundled Video Duration" in host_source,
            "host app should show and copy app executable, extension load, extension executable, CMIO Mach service readiness, and bundled-video diagnostics",
            failures)
    require("nsError.domain" in host_source and "unknown code \\(errorCode)" in host_source,
            "host app should preserve system-extension failure domain and code diagnostics",
            failures)
    require("diagnosticSummary" in host_source and "NSPasteboard.general" in host_source and "Copy Diagnostics" in host_source and "Expected Runtime Evidence:" in host_source and "runtimeEvidenceExpectedDiagnostics" in host_source,
            "host app should expose copyable diagnostics with expected runtime evidence for activation troubleshooting",
            failures)
    require("runtimeDiagnosticsCommand" in host_source and "runtimeDiagnosticsCommandSource" in host_source and "Bundled app resource" in host_source and "Repository fallback" in host_source and "Runtime Diagnostics Command Source:" in host_source and "Runtime Command Source" in host_source and "copyRuntimeDiagnosticsCommand" in host_source and "bundledRuntimeDiagnosticsScriptPath" in host_source and "Bundle.main.url(forResource: \"collect_runtime_diagnostics\"" in host_source and "shellQuoted" in host_source and "/bin/bash \\(Self.shellQuoted(scriptPath)) \\(Self.shellQuoted(expectedApplicationPath)) 1h" in host_source and "Diagnostics Command Copied" in host_source and "Diagnostics Command Copy Failed" in host_source and "Copy Command" in host_source,
            "host app should expose a copyable bundled runtime diagnostics command with its source",
            failures)
    require("bundledRuntimeDiagnosticsScriptPath" in host_source and "fileExists(atPath: scriptURL.path, isDirectory: &isDirectory)" in host_source and "!isDirectory.boolValue" in host_source and "test_validator_rejects_directory_runtime_diagnostics_script_resource" in validate_project_test_source,
            "host app should only expose a bundled runtime diagnostics command for a file resource",
            failures)
    require("copyRuntimeEvidenceExpectedDiagnostics" in host_source and "Expected Evidence Copied" in host_source and "Expected Evidence Copy Failed" in host_source and "Copy Expected Lines" in host_source and "Copy the expected signed-host diagnostics lines." in host_source,
            "host app should expose a copyable expected runtime evidence lines action",
            failures)
    require("activationChecklist" in host_source and "copyActivationChecklist" in host_source and "Gareth Video Cam Signed Runtime Activation Checklist" in host_source and "Current Request Detail:" in host_source and "Current Readiness Summary:" in host_source and "Last Failure:" in host_source and "Run the Diagnostics Command below on the signed macOS host." in host_source and "Confirm the diagnostics report the expected signed-host evidence lines." in host_source and "Expected Diagnostics:" in host_source and "Runtime activation evidence result" in host_source and "runtimeEvidenceExpectedDiagnostics" in host_source and "Diagnostics Command Source:" in host_source and "runtimeDiagnosticsCommandSource" in host_source and "Diagnostics Command:" in host_source and "runtimeDiagnosticsCommand" in host_source and "Checklist Copied" in host_source and "Checklist Copy Failed" in host_source and "Copy Checklist" in host_source,
            "host app should expose a copyable signed runtime activation checklist with current readiness context",
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
    require("applicationVersion" in host_source and "displayVersion(shortVersion:" in host_source and "infoPlistString(in:" in host_source and "trimmingCharacters(in: .whitespacesAndNewlines)" in host_source and "Extension Version" in host_source and "App Version" in host_source and "App Bundle Short Version" in host_source and "App Bundle Build Version" in host_source and "Extension Bundle Short Version" in host_source and "Extension Bundle Build Version" in host_source and "Bundle Short Version Match" in host_source and "Bundle Build Version Match" in host_source and "CFBundleShortVersionString" in host_source and "CFBundleVersion" in host_source,
            "host app should show and copy exact app and extension short/build version diagnostics and alignment status",
            failures)
    require("System Extension Entitlement" in host_source and "App System Extension Entitlement:" in host_source and "Extension Host-Only Entitlement" in host_source and "extensionHostOnlyEntitlementStatus" in host_source and "App Application Groups" in host_source and "Extension Application Groups" in host_source and "applicationGroupStatus" in host_source,
            "host app should show and copy app and extension entitlement diagnostics",
            failures)
    require("expectedApplicationBundleIdentifier" in host_source and "applicationBundleIdentifier" in host_source and "Expected App ID" in host_source and "Actual App ID" in host_source and "App Bundle ID Check" in host_source and "Expected Extension ID" in host_source and "Expected App Path:" in host_source and "App Executable Path:" in host_source,
            "host app should show and copy expected and actual bundle identifier, app path, and app executable diagnostics",
            failures)
    require("func copyDiagnostics() {\n        let didRefresh = refreshExtensionInfo()" in host_source and "copySuccessDetail(\"Copied current app and extension status to the clipboard.\"" in host_source,
            "host app should refresh readiness and preserve refresh-failure context before copying diagnostics",
            failures)
    require("func copyActivationChecklist() {\n        let didRefresh = refreshExtensionInfo()" in host_source and "func copyRuntimeDiagnosticsCommand() {\n        let didRefresh = refreshExtensionInfo()" in host_source and "func copyRuntimeEvidenceExpectedDiagnostics() {\n        let didRefresh = refreshExtensionInfo()" in host_source and "private func copySuccessDetail" in host_source and "Refresh found:" in host_source,
            "host app should refresh readiness and preserve refresh-failure context before copying runtime evidence checklists and commands",
            failures)
    require("refreshStatus()" in host_source and "Status Refreshed" in host_source and "Button(action: manager.refreshStatus)" in host_source and "Refresh Status" in host_source,
            "host app should let users refresh extension and signing readiness in-place with activity feedback",
            failures)
    require("func refreshAfterAppBecameActive()" in host_source and "previousState = state" in host_source and "didChangeVisibleStatus" in host_source and "Status Updated" in host_source,
            "host app should record automatic foreground refreshes only when visible readiness changes",
            failures)
    require("private let maximumActivityItems = 20" in host_source and "if activity.count > maximumActivityItems" in host_source and "activity.removeLast(activity.count - maximumActivityItems)" in host_source and "test_validator_rejects_missing_activity_limit" in validate_project_test_source,
            "host app should cap request activity so long troubleshooting sessions stay bounded",
            failures)
    require("didCompleteInitialAppearance" in host_source and "guard didCompleteInitialAppearance else" in host_source,
            "host app should avoid duplicating the manager startup refresh on first view appearance",
            failures)
    require("@Environment(\\.scenePhase)" in host_source and ".onChange(of: scenePhase)" in host_source and "newScenePhase == .active" in host_source and "systemExtensionRequestManager.refreshAfterAppBecameActive()" in host_source,
            "host app should refresh readiness when it becomes active after external approval changes",
            failures)
    require("#Preview" in host_source and "PreviewProvider" not in host_source,
            "host app should use the modern SwiftUI preview syntax",
            failures)
    require("case .idle, .ready, .needsApplicationLocation, .needsBundleIdentifier, .needsApplicationExecutable, .needsBundleVersion, .needsExtensionMetadata, .needsBundledVideo, .needsSigning, .deactivated, .failed:" in host_source,
            "host app should let a successful refresh recover from stale readiness failures",
            failures)
    require("private struct DetailsActions" in host_source and "ViewThatFits(in: .horizontal)" in host_source,
            "host app should keep details actions responsive at narrower window widths",
            failures)
    require("Button(action: manager.copyRuntimeEvidenceExpectedDiagnostics)" in details_actions_source and "Copy Expected Lines" in details_actions_source and "Copy the expected signed-host diagnostics lines." in details_actions_source,
            "host details actions should expose the expected runtime evidence copy action",
            failures)
    require("private static let titleColumnWidth: CGFloat = 220" in host_source and ".frame(width: Self.titleColumnWidth" in host_source and "private var titleLabel" in host_source and "private var valueText" in host_source,
            "host app should keep diagnostic detail rows responsive with a stable readable title column",
            failures)
    require("private var activityTitle" in host_source and "private var activityDetail" in host_source and "private var activityTimestamp" in host_source and ".fixedSize(horizontal: true, vertical: false)" in host_source,
            "host app should keep activity rows responsive and readable at narrower window widths",
            failures)
    require("ForEach(Array(items.enumerated()), id: \\.element.id)" in host_source,
            "host activity panel should render a stable activity snapshot",
            failures)
    require(".frame(minWidth: 720, minHeight: 560)" in app_entry_source and ".windowResizability(.contentMinSize)" in app_entry_source,
            "host app should allow a compact but bounded resizable window",
            failures)
    require('CommandMenu("Camera")' in app_entry_source and 'Button("Install Camera Extension")' in app_entry_source and "systemExtensionRequestManager.install()" in app_entry_source and ".disabled(systemExtensionRequestManager.isBusy || !systemExtensionRequestManager.canSubmitActivationRequest)" in app_entry_source and 'Button("Uninstall Camera Extension")' in app_entry_source and "systemExtensionRequestManager.uninstall()" in app_entry_source and ".disabled(systemExtensionRequestManager.isBusy || !systemExtensionRequestManager.canSubmitDeactivationRequest)" in app_entry_source and 'Button("Refresh Status")' in app_entry_source and "systemExtensionRequestManager.refreshStatus()" in app_entry_source and 'Button("Copy Diagnostics")' in app_entry_source and "systemExtensionRequestManager.copyDiagnostics()" in app_entry_source and 'Button("Copy Activation Checklist")' in app_entry_source and "systemExtensionRequestManager.copyActivationChecklist()" in app_entry_source and 'Button("Copy Runtime Diagnostics Command")' in app_entry_source and "systemExtensionRequestManager.copyRuntimeDiagnosticsCommand()" in app_entry_source and 'Button("Copy Expected Runtime Evidence")' in app_entry_source and "systemExtensionRequestManager.copyRuntimeEvidenceExpectedDiagnostics()" in app_entry_source and 'Button("Open System Settings")' in app_entry_source and 'Button("Reveal App in Finder")' in app_entry_source and "systemExtensionRequestManager.revealApplicationInFinder()" in app_entry_source and 'Button("Reveal Extension in Finder")' in app_entry_source and "systemExtensionRequestManager.revealBundledExtensionInFinder()" in app_entry_source and ".disabled(!systemExtensionRequestManager.canRevealBundledExtension)" in app_entry_source,
            "host app should expose native macOS menu commands for common camera actions",
            failures)
    require('.keyboardShortcut("r", modifiers: [.command])' in app_entry_source and '.keyboardShortcut("c", modifiers: [.command, .shift])' in app_entry_source and '.keyboardShortcut("l", modifiers: [.command, .shift])' in app_entry_source and '.keyboardShortcut("d", modifiers: [.command, .shift])' in app_entry_source and '.keyboardShortcut("e", modifiers: [.command, .shift])' in app_entry_source,
            "host app should provide native keyboard shortcuts for repeated status and evidence commands",
            failures)
    require("activateFileViewerSelecting" in host_source and "Reveal App" in host_source,
            "host app should let users reveal the running app bundle in Finder",
            failures)
    require("revealBundledExtensionInFinder" in host_source and "canRevealBundledExtension" in host_source and "Reveal Extension" in host_source and "Extension Revealed" in host_source and ".disabled(!manager.canRevealBundledExtension)" in host_source,
            "host app should let users reveal the embedded system extension bundle in Finder only when it is loaded",
            failures)
    require("Submit a macOS system extension activation request." in host_source and "Refresh app, extension, signing, and readiness status." in host_source and "Copy the current readiness and diagnostics snapshot." in host_source and "Copy the signed runtime activation checklist." in host_source and "Copy the runtime diagnostics command." in host_source,
            "host app action buttons should expose concise hover help",
            failures)
    require("func openSystemSettings() {\n        let requestKind = pendingRequestKind ?? .activation" in host_source and "System Settings" in host_source and "/System/Applications/System Settings.app" in host_source and "detail: requestKind.approvalDetail" in host_source,
            "host app should provide request-specific System Settings guidance for extension approval",
            failures)
    require("didOpenSettings" in host_source and "System Settings Unavailable" in host_source,
            "host app should report System Settings launch failures",
            failures)
    require("./scripts/check_project.sh" in readme_text and "project metadata validation, five synthetic CoreMedia timestamp unit tests, validator mutation tests for recent runtime-readiness guardrails, build-log scanner tests, unsigned build script tests, runtime diagnostics tests, build-product verifier tests, shell syntax checks, and whitespace checks" in readme_text and "bundle identifiers, aligned bundle versions, declared executables, display metadata, product-specific privacy usage strings, bundled runtime diagnostics self-tests, resolved CoreMediaIO extension metadata, and bundled-video resource metadata" in readme_text and "exact host and extension entitlement keys, shared app-group values, Xcode entitlement file bindings" in readme_text and "decoded pixel-buffer and host-clock sample-timing guards" in readme_text,
            "README should document the local pre-push project check",
            failures)
    require("CI-equivalent unsigned compile" in readme_text and "./scripts/build_unsigned.sh" in readme_text and "./scripts/scan_build_log.py .build/Xcode/Logs/build-Debug.log .build/Xcode/Logs/build-Release.log" in readme_text and ".build/Xcode" in readme_text and ".build/Xcode/Logs" in readme_text and "BUILD_OUTPUT_PATH" in readme_text and "BUILD_LOG_PATH" in readme_text,
            "README should document the CI-equivalent unsigned Debug and Release target builds with log scanning",
            failures)
    require("runs `make check`, performs unsigned Debug and Release target builds" in readme_text and "verifies the built app products contain the embedded system extension, aligned bundle versions, declared executables, display metadata, product-specific privacy usage strings, bundled runtime diagnostics self-tests, resolved CoreMediaIO extension metadata, and bundled-video metadata" in readme_text and "captures the Xcode logs under `.build/Xcode/Logs`" in readme_text and "scans any captured `build-*.log` output including partial logs from failed builds" in readme_text and "build-failed, archive-failed, analyze-failed, clean-failed, install-failed, and test-failed banners" in readme_text,
            "README should document CI build-product verification and log scanning failure modes",
            failures)
    require("parseable dimensions, frame rate, and positive video duration" in readme_text,
            "README should document bundled-video metadata validation",
            failures)
    require("decoded pixel-buffer and host-clock sample-timing guards" in readme_text and "stream-format regressions" in readme_text,
            "README should document decoded pixel-buffer stream-format validation",
            failures)
    require("Runtime Activation" in readme_text and "valid Apple Developer signing identity" in readme_text,
            "README should document signed runtime activation requirements",
            failures)
    require("not running from `/Applications/GarethVideoCam.app`" in readme_text and "keeps uninstall available when only activation packaging checks fail" in readme_text and "activation and deactivation request readiness and details" in readme_text and "reports extension metadata and bundled-video packaging blockers as distinct readiness states" in readme_text and "reports extension load failures separately from unchecked or invalid signatures" in readme_text and "refreshes readiness when the app becomes active" in readme_text and "shows and copies a readiness summary with ready, blocked, and pending counts, next action, and checklist" in readme_text and "Runtime Evidence section with the expected signed-host diagnostics, collection command, and command source" in readme_text and "can copy the exact expected runtime evidence lines" in readme_text and "can copy a signed runtime activation checklist with the expected diagnostics lines and collection command" in readme_text and "current request detail, readiness summary, and last recorded failure" in readme_text and "can copy the exact bundled runtime diagnostics command for signed-host evidence collection" in readme_text and "primary System Settings approval shortcut" in readme_text and "reveal the app and embedded extension in Finder" in readme_text and "diagnostics snapshot" in readme_text and "generation timestamp" in readme_text and "macOS version" in readme_text and "bundle identifiers" in readme_text and "exact app and extension short/build bundle versions" in readme_text and "bundle short/build version match status" in readme_text and "expected and current app paths" in readme_text and "runtime diagnostics command source" in readme_text and "expected signed-host evidence lines" in readme_text and "app and extension quarantine status" in readme_text and "host app bundle identifier does not match the expected identifier" in readme_text and "missing the System Extension entitlement" in readme_text and "app and embedded extension bundle versions do not match" in readme_text and "embedded extension executable or CMIO Mach service metadata is missing, unresolved, or unexpected" in readme_text and "embedded `video.mp4` resource is missing, empty, or has unexpected metadata" in readme_text and "bundled system extension signature is invalid" in readme_text and "embedded system extension carries the host-only System Extension entitlement" in readme_text and "app and extension do not share an expected app-group entitlement" in readme_text and "signed app-group values and match status" in readme_text and "Team IDs" in readme_text and "extension load failure status" in readme_text and "extension host-only entitlement status" in readme_text and "bundled extension executable, resolved CMIO Mach service status, CMIO Mach service identifier match status" in readme_text and "bundled-video size and metadata values" in readme_text and "pending request direction" in readme_text and "last recorded failure" in readme_text and "timestamped recent request activity with severity" in readme_text,
            "README should document the in-app approval and diagnostics actions",
            failures)
    require("Signed runtime activation checklist:" in readme_text and "System Extension entitlement and app-group entitlement" in readme_text and "/Applications/GarethVideoCam.app" in readme_text and "Confirm the in-app readiness summary has no blocked checks" in readme_text and "Approve the pending camera extension in System Settings" in readme_text and "Runtime Evidence section's Copy Command action" in readme_text and "bundled app resource or a repository fallback" in readme_text and "Runtime readiness result: ready" in readme_text and "Application location ready: yes" in readme_text and "App bundle identifier ready: yes" in readme_text and "App signature ready: yes" in readme_text and "App System Extension entitlement ready: yes" in readme_text and "App executable ready: yes" in readme_text and "Extension bundle identifier ready: yes" in readme_text and "Extension signature ready: yes" in readme_text and "Extension host-only entitlement absent: yes" in readme_text and "Extension executable ready: yes" in readme_text and "Extension CMIO Mach service ready: yes" in readme_text and "Bundle versions match ready: yes" in readme_text and "Signing Team match ready: yes" in readme_text and "Application group match ready: yes" in readme_text and "Bundled video ready: yes" in readme_text and "Bundled video metadata ready: yes" in readme_text and "Runtime activation evidence result: active" in readme_text and "Extension registration entry present: yes" in readme_text and "Extension registration activated enabled: yes" in readme_text and "Expected virtual camera device present: yes" in readme_text and "camera pickers should list `Gareth Video Cam`" in readme_text,
            "README should document a signed-host activation checklist with expected diagnostics",
            failures)
    require("Camera menu provides keyboard shortcuts" in readme_text and "Command-R refreshes status" in readme_text and "Command-Shift-C copies diagnostics" in readme_text and "Command-Shift-L copies the activation checklist" in readme_text and "Command-Shift-D copies the runtime diagnostics command" in readme_text and "Command-Shift-E copies the expected runtime evidence lines" in readme_text,
            "README should document native Camera menu shortcuts for repeated evidence collection",
            failures)
    require("Bundled video metadata ready: yes" in readme_text and "metadata readiness for expected dimensions/frame rate and positive duration" in readme_text,
            "README should document bundled-video metadata readiness diagnostics",
            failures)
    require("collect_runtime_diagnostics.sh" in readme_text and "diagnostics helper resource paths and parser availability" in readme_text and "Info.plist bundle versions and identifiers" in readme_text and "app/extension bundle-version match status" in readme_text and "bundled-video byte size, checksum, metadata" in readme_text and "expected application-location and bundle identifier checks" in readme_text and "app executable metadata" in readme_text and "quarantine attributes" in readme_text and "matching ten-character Team IDs" in readme_text and "Gatekeeper assessment" in readme_text and "signed entitlements" in readme_text and "explicit host and extension System Extension entitlement checks that mark unreadable signed entitlements as unknown" in readme_text and "signed Team-ID-prefixed app-group arrays and match readiness that mark unreadable or malformed app-group entitlements as unknown" in readme_text and "counted runtime-readiness summary with a next-action hint" in readme_text and "embedded system-extension executable metadata" in readme_text and "resolved CMIO Mach service status" in readme_text and "systemextensionsctl" in readme_text and "registration presence, activated/enabled state, matching entries, and full list output" in readme_text and "expected virtual-camera device presence with full camera inventory" in readme_text and "unknown runtime activation evidence when `systemextensionsctl` or `system_profiler` fail" in readme_text and "counted runtime-activation evidence summary with a next-action hint" in readme_text and "running app/extension processes" in readme_text and "unified-log window" in readme_text and "system-extension/CMIO log context" in readme_text,
            "README should document collecting runtime diagnostics on macOS",
            failures)
    require("all-architecture code-signing status and signature details" in readme_text,
            "README should document all-architecture runtime diagnostics signature details",
            failures)
    require("System Extension entitlement checks that mark unreadable signed entitlements as unknown and run across architecture slices" in readme_text,
            "README should document all-architecture runtime diagnostics boolean entitlement checks",
            failures)
    require("signed Team-ID-prefixed app-group arrays and match readiness that mark unreadable or malformed app-group entitlements as unknown and use only values present across architecture slices" in readme_text,
            "README should document all-architecture runtime diagnostics app-group checks",
            failures)
    require("app executable metadata and architecture slices" in readme_text and "embedded system-extension executable metadata and architecture slices" in readme_text,
            "README should document runtime diagnostics executable architecture reporting",
            failures)
    require("signed entitlements across architecture slices" in readme_text,
            "README should document runtime diagnostics per-architecture signed entitlement dumps",
            failures)
    require("ACTIONABLE_PATTERN" in build_log_scanner_source and "BUILD FAILED" in build_log_scanner_source and "TEST FAILED" in build_log_scanner_source and "ANALYZE FAILED" in build_log_scanner_source and "CLEAN FAILED" in build_log_scanner_source and build_log_scanner_source.count("INSTALL FAILED") >= 2 and "testing failed:" in build_log_scanner_source and "the following build commands failed:" in build_log_scanner_source and "warnings/errors/failures" in build_log_scanner_source and "IGNORED_LINE_TOKEN_GROUPS" in build_log_scanner_source and '"warning:"' in build_log_scanner_source and "all(token.lower() in normalized_line" in build_log_scanner_source and "test_validator_rejects_broad_appintents_log_ignore" in validate_project_test_source and "test_validator_rejects_missing_install_failed_banner_scan" in validate_project_test_source,
            "build-log scanner should fail on warnings, errors, build/analyze/clean/install/test-failed banners, build/test failure summaries, and nonzero Xcode command failures while narrowly ignoring known Xcode AppIntents metadata noise",
            failures)
    require("IGNORED_LINE_DISQUALIFYING_PATTERN" in build_log_scanner_source and "warning:.*warning:" in build_log_scanner_source and "if IGNORED_LINE_DISQUALIFYING_PATTERN.search(line):" in build_log_scanner_source and "test_fails_on_appintents_warning_with_embedded_error" in build_log_scanner_test_source and "test_fails_on_appintents_warning_with_embedded_warning" in build_log_scanner_test_source and "test_validator_rejects_missing_appintents_ignore_disqualifier" in validate_project_test_source and "test_validator_rejects_missing_appintents_same_line_warning_disqualifier" in validate_project_test_source,
            "build-log scanner should not hide additional warnings or failures on ignored AppIntents warning lines",
            failures)
    require("BUILD_LOG [BUILD_LOG ...]" in build_log_scanner_source and "for build_log_path in (Path(argument) for argument in sys.argv[1:])" in build_log_scanner_source and "actionable_lines_in(build_log_path)" in build_log_scanner_source,
            "build-log scanner should accept and scan multiple build logs",
            failures)
    require("build_log_path.is_file()" in build_log_scanner_source and "Build log is not a regular file:" in build_log_scanner_source,
            "build-log scanner should reject directory or non-file arguments before opening them",
            failures)
    require("BuildLogReadError" in build_log_scanner_source and "except OSError as error" in build_log_scanner_source and "Build log is not readable:" in build_log_scanner_source and "test_validator_rejects_missing_unreadable_build_log_guard" in validate_project_test_source,
            "build-log scanner should report unreadable log files without a traceback",
            failures)
    require("enumerate(build_log, start=1)" in build_log_scanner_source and "{build_log_path}:{line_number}:" in build_log_scanner_source,
            "build-log scanner should print the build-log path and line number for actionable findings",
            failures)
    require("test_ignores_appintents_metadata_notice" in build_log_scanner_test_source and "test_fails_on_actionable_warning" in build_log_scanner_test_source and "test_fails_on_other_appintents_warning" in build_log_scanner_test_source and "test_fails_on_appintents_error_notice" in build_log_scanner_test_source and "test_fails_on_appintents_warning_with_embedded_error" in build_log_scanner_test_source and "test_fails_on_appintents_warning_with_embedded_warning" in build_log_scanner_test_source and "test_fails_on_nonzero_command_failure" in build_log_scanner_test_source and "test_fails_on_build_commands_failed_summary" in build_log_scanner_test_source and "test_fails_on_build_failed_banner" in build_log_scanner_test_source and "test_fails_on_archive_failed_banner" in build_log_scanner_test_source and "test_fails_on_analyze_failed_banner" in build_log_scanner_test_source and "test_fails_on_clean_failed_banner" in build_log_scanner_test_source and "test_fails_on_install_failed_banner" in build_log_scanner_test_source and "ARCHIVE FAILED" in build_log_scanner_source and "ANALYZE FAILED" in build_log_scanner_source and "CLEAN FAILED" in build_log_scanner_source and "INSTALL FAILED" in build_log_scanner_source and "test_fails_on_testing_failed_summary" in build_log_scanner_test_source and "test_fails_on_test_failed_banner" in build_log_scanner_test_source and "test_scans_multiple_build_logs" in build_log_scanner_test_source and "test_fails_on_missing_build_log" in build_log_scanner_test_source and "test_fails_on_directory_build_log" in build_log_scanner_test_source and "test_fails_on_unreadable_build_log" in build_log_scanner_test_source and "test_requires_build_log_argument" in build_log_scanner_test_source and "Build log not found:" in build_log_scanner_test_source and "Build log is not a regular file:" in build_log_scanner_test_source and "Build log is not readable:" in build_log_scanner_test_source and "Usage: scan_build_log.py BUILD_LOG [BUILD_LOG ...]" in build_log_scanner_test_source and ":2: SwiftCompile warning: real source warning" in build_log_scanner_test_source,
            "build-log scanner should have regression coverage for ignored warnings, actionable warnings, build/test command failure summaries, build/archive/analyze/clean/install/test-failed banners, unreadable and missing build logs, and missing CLI arguments",
            failures)
    require("xcodebuild" in build_unsigned_source and "command -v xcodebuild" in build_unsigned_source and "xcodebuild is required to build GarethVideoCam" in build_unsigned_source and "exit 127" in build_unsigned_source and "-target \"$TARGET_NAME\"" in build_unsigned_source and "CODE_SIGNING_ALLOWED=NO" in build_unsigned_source and "CODE_SIGNING_REQUIRED=NO" in build_unsigned_source and 'BUILD_ARCH="${BUILD_ARCH:-}"' in build_unsigned_source and 'BUILD_ARCH="$(/usr/bin/uname -m)"' in build_unsigned_source and "RUNNER_ARCH" not in build_unsigned_source and "BUILD_OUTPUT_PATH" in build_unsigned_source and 'BUILD_LOG_PATH="${BUILD_LOG_PATH:-$BUILD_OUTPUT_PATH/Logs}"' in build_unsigned_source and "mkdir -p \"$BUILD_LOG_PATH\"" in build_unsigned_source and "SYMROOT=\"$BUILD_OUTPUT_PATH/Products\"" in build_unsigned_source and "OBJROOT=\"$BUILD_OUTPUT_PATH/Intermediates\"" in build_unsigned_source and "-derivedDataPath" not in build_unsigned_source and "configurations=(Debug Release)" in build_unsigned_source and 'tee "$BUILD_LOG_PATH/build-${configuration}.log"' in build_unsigned_source and "validate_configuration_name" in build_unsigned_source and "validate_configuration_name \"$configuration\"" in build_unsigned_source and "validate_build_arch_name" in build_unsigned_source and "validate_build_arch_name \"$BUILD_ARCH\"" in build_unsigned_source and "^[A-Za-z0-9_][A-Za-z0-9_.-]*$" in build_unsigned_source and "Invalid Xcode configuration name:" in build_unsigned_source and "Invalid Xcode build architecture:" in build_unsigned_source and "test_validator_rejects_missing_unsigned_build_architecture_guard" in validate_project_test_source and build_unsigned_source.index('validate_configuration_name "$configuration"') < build_unsigned_source.index("/usr/bin/uname -m") < build_unsigned_source.index('validate_build_arch_name "$BUILD_ARCH"') < build_unsigned_source.index("command -v xcodebuild") < build_unsigned_source.index('mkdir -p "$BUILD_LOG_PATH"'),
            "unsigned build script should perform Debug and Release app target builds without code signing",
            failures)
    require("FAKE_BIN" in build_unsigned_test_source and "XCODEBUILD_CALL_LOG" in build_unsigned_test_source and "PROJECT_PATH=\"Fixture.xcodeproj\"" in build_unsigned_test_source and "TARGET_NAME=\"FixtureCamera\"" in build_unsigned_test_source and "BUILD_ARCH=\"arm64\"" in build_unsigned_test_source and "BUILD_OUTPUT_PATH=\"$TMP_DIR/XcodeProducts\"" in build_unsigned_test_source and "$TMP_DIR/XcodeProducts/Logs/build-Debug.log" in build_unsigned_test_source and "$DEFAULT_WORK_DIR/.build/Xcode/Logs/build-Debug.log" in build_unsigned_test_source and "CODE_SIGNING_ALLOWED=NO" in build_unsigned_test_source and "CODE_SIGNING_REQUIRED=NO" in build_unsigned_test_source and "COMPILER_INDEX_STORE_ENABLE=NO" in build_unsigned_test_source and "DEFAULT_WORK_DIR" in build_unsigned_test_source and "Expected default unsigned build to invoke Debug and Release configurations." in build_unsigned_test_source and "build-Debug.log" in build_unsigned_test_source and "build-Release.log" in build_unsigned_test_source and "XCODEBUILD_SHOULD_FAIL=1" in build_unsigned_test_source and "failure_status" in build_unsigned_test_source and "xcodebuild fixture failure for Debug" in build_unsigned_test_source and "missing_xcodebuild_status" in build_unsigned_test_source and "xcodebuild is required to build GarethVideoCam" in build_unsigned_test_source and "missing_xcodebuild_invalid_status" in build_unsigned_test_source and "Expected invalid configuration to be rejected before missing xcodebuild" in build_unsigned_test_source and "missing_xcodebuild_invalid_arch_status" in build_unsigned_test_source and "Expected invalid BUILD_ARCH to be rejected before missing xcodebuild" in build_unsigned_test_source and "INVALID_CALL_LOG" in build_unsigned_test_source and "../Release" in build_unsigned_test_source and "Invalid Xcode configuration name: ../Release" in build_unsigned_test_source and "dot_segment_status" in build_unsigned_test_source and "Invalid Xcode configuration name: .." in build_unsigned_test_source and "invalid_build_arch_status" in build_unsigned_test_source and "Expected invalid BUILD_ARCH to be rejected before xcodebuild" in build_unsigned_test_source and "Invalid Xcode build architecture: ../arm64" in build_unsigned_test_source,
            "unsigned build script test should stub xcodebuild and verify project, target, architecture, signing, output path, default configurations, log arguments, missing xcodebuild, dot-segment configuration rejection, and xcodebuild failure propagation",
            failures)
    require(build_unsigned_test_path.stat().st_mode & 0o111,
            "unsigned build script test should be executable",
            failures)
    require(build_unsigned_path.stat().st_mode & 0o111,
            "unsigned build script should be executable",
            failures)
    require("GarethVideoCam.app" in verify_build_products_source and "com.garethpaul.GarethVideoCam.Extension.systemextension" in verify_build_products_source and "Contents/Library/SystemExtensions" in verify_build_products_source and "Contents/Resources/video.mp4" in verify_build_products_source and "read_bundle_identifier" in verify_build_products_source and "read_bundle_short_version" in verify_build_products_source and "read_bundle_build_version" in verify_build_products_source and "verify_aligned_bundle_versions" in verify_build_products_source and "Mismatched %s bundle short versions" in verify_build_products_source and "Mismatched %s bundle build versions" in verify_build_products_source and "read_bundle_executable" in verify_build_products_source and "verify_bundle_executable" in verify_build_products_source and "verify_info_plist_string" in verify_build_products_source and "verify_info_plist_value" in verify_build_products_source and "verify_app_diagnostics_resources" in verify_build_products_source and "verify_app_diagnostics_self_test" in verify_build_products_source and 'GARETH_DIAGNOSTICS_SELF_TEST="$self_test"' in verify_build_products_source and "collect_runtime_diagnostics.sh" in verify_build_products_source and "Missing %s app runtime diagnostics script" in verify_build_products_source and "Missing %s app runtime diagnostics parser" in verify_build_products_source and "resource-discovery" in verify_build_products_source and "Diagnostics script path:" in verify_build_products_source and "Diagnostics script directory:" in verify_build_products_source and "Diagnostics parser path:" in verify_build_products_source and "Diagnostics parser source: adjacent script resource" in verify_build_products_source and "Diagnostics parser available: yes" in verify_build_products_source and "video-parser" in verify_build_products_source and "GARETH_DIAGNOSTICS_VIDEO_FIXTURE" in verify_build_products_source and "Video parser pixel width fixture: 1280" in verify_build_products_source and "Video parser pixel height fixture: 720" in verify_build_products_source and "Video parser frame rate fixture: 24" in verify_build_products_source and "Video parser duration fixture: 3.0833333333333335" in verify_build_products_source and "Video parser metadata ready fixture: yes" in verify_build_products_source and "APP_DISPLAY_NAME" in verify_build_products_source and "EXTENSION_DISPLAY_NAME" in verify_build_products_source and "CFBundleDisplayName" in verify_build_products_source and "display metadata" in verify_build_products_source and "NSCameraUsageDescription" in verify_build_products_source and "NSSystemExtensionUsageDescription" in verify_build_products_source and "read_extension_mach_service_name" in verify_build_products_source and "verify_extension_cmio_metadata" in verify_build_products_source and "mach_service_matches_expected_identifier" in verify_build_products_source and "team_prefixed_suffix" in verify_build_products_source and "^[[:alnum:]]{10}$" in verify_build_products_source and "verify_bundled_video_metadata" in verify_build_products_source and "validate_project.py" in verify_build_products_source and "mp4_video_metadata" in verify_build_products_source and "dont_write_bytecode" in verify_build_products_source and "EXPECTED_VIDEO_WIDTH" in verify_build_products_source and "EXPECTED_VIDEO_HEIGHT" in verify_build_products_source and "EXPECTED_VIDEO_FRAME_RATE" in verify_build_products_source and "Unexpected {configuration} bundled video dimensions" in verify_build_products_source and "Unexpected {configuration} bundled video frame rate" in verify_build_products_source and "CMIOExtensionMachServiceName" in verify_build_products_source and "Unresolved %s extension CMIOExtensionMachServiceName" in verify_build_products_source and "Unexpected %s extension CMIOExtensionMachServiceName" in verify_build_products_source and "Contents/Info.plist" in verify_build_products_source and "Contents/MacOS" in verify_build_products_source and "CFBundleExecutable" in verify_build_products_source and "CFBundleShortVersionString" in verify_build_products_source and "CFBundleVersion" in verify_build_products_source and "plistlib" in verify_build_products_source and "PlistBuddy" not in verify_build_products_source and "Debug Release" in verify_build_products_source,
            "build-product verifier should check app, embedded extension, bundle identifiers, aligned bundle versions, declared executables, display metadata, privacy usage strings, diagnostics resources, resolved CoreMediaIO metadata, and bundled video",
            failures)
    require("python3_command()" in verify_build_products_source and "PYTHON3_BIN=\"$(python3_command)\"" in verify_build_products_source and "Configured PYTHON3_BIN is not executable or not found" in verify_build_products_source and 'PYTHON3_BIN" = "-"' in verify_build_products_source and "/usr/bin/python3" in verify_build_products_source and "command -v python3" in verify_build_products_source and '"$PYTHON3_BIN" - "$info_plist"' in verify_build_products_source and '"$PYTHON3_BIN" - "$ROOT/scripts/validate_project.py"' in verify_build_products_source and "PYTHON3_BIN=\"$TMP_DIR/missing-python3\"" in verify_build_products_test_source and "missing configured Python interpreter" in verify_build_products_test_source and 'PYTHON3_BIN="-"' in verify_build_products_test_source and "dash PYTHON3_BIN override" in verify_build_products_test_source and "newline PYTHON3_BIN override" in verify_build_products_test_source,
            "build-product verifier should resolve one explicit Python 3 interpreter before parsing plists or bundled-video metadata",
            failures)
    require("validate_configuration_name" in verify_build_products_source and "^[A-Za-z0-9_][A-Za-z0-9_.-]*$" in verify_build_products_source and "Invalid Xcode configuration name:" in verify_build_products_source and 'validate_configuration_name "$configuration"' in verify_build_products_source and 'PYTHON3_BIN="$(python3_command)"' in verify_build_products_source and verify_build_products_source.index('validate_configuration_name "$configuration"') < verify_build_products_source.index('PYTHON3_BIN="$(python3_command)"') and "invalid_configuration_status" in verify_build_products_test_source and "Expected verifier to reject an invalid configuration before resolving Python" in verify_build_products_test_source and "Invalid Xcode configuration name: ../Debug" in verify_build_products_test_source and "dot_segment_configuration_status" in verify_build_products_test_source and "Invalid Xcode configuration name: .." in verify_build_products_test_source,
            "build-product verifier should reject invalid configuration names before resolving Python or product paths",
            failures)
    require("validate_positive_integer" in verify_build_products_source and "Invalid expected video %s: %s" in verify_build_products_source and 'validate_positive_integer "width" "$EXPECTED_VIDEO_WIDTH"' in verify_build_products_source and 'validate_positive_integer "height" "$EXPECTED_VIDEO_HEIGHT"' in verify_build_products_source and 'validate_positive_integer "frame rate" "$EXPECTED_VIDEO_FRAME_RATE"' in verify_build_products_source and 'validate_configuration_name "$configuration"' in verify_build_products_source and 'PYTHON3_BIN="$(python3_command)"' in verify_build_products_source and verify_build_products_source.index('validate_configuration_name "$configuration"') < verify_build_products_source.index('validate_positive_integer "width" "$EXPECTED_VIDEO_WIDTH"') < verify_build_products_source.index('PYTHON3_BIN="$(python3_command)"') and "invalid_expected_video_status" in verify_build_products_test_source and "Expected verifier to reject invalid expected video metadata before resolving Python" in verify_build_products_test_source and "Invalid expected video width: wide" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_expected_video_metadata_guard" in validate_project_test_source,
            "build-product verifier should reject invalid expected video metadata before resolving Python or product paths",
            failures)
    require(validate_project_source.count("video_path.is_file()") >= 3 and "test_directory_video_fixture_reports_validation_failure" in validate_project_test_source and "test_validator_rejects_missing_source_video_file_guard" in validate_project_test_source,
            "project validator should reject non-file source video fixtures without a traceback",
            failures)
    require(validate_project_source.count("icon_path.is_file()") >= 3 and "test_directory_icon_fixture_reports_validation_failure" in validate_project_test_source and "test_validator_rejects_missing_icon_file_guard" in validate_project_test_source,
            "project validator should reject non-file app icon fixtures without a traceback",
            failures)
    require("verify_exactly_one_embedded_system_extension" in verify_build_products_source and "Unexpected %s embedded system extension count" in verify_build_products_source and 'verify_exactly_one_embedded_system_extension "$configuration" "$app_path"' in verify_build_products_source and "test_validator_rejects_missing_build_product_duplicate_extension_guard" in validate_project_test_source,
            "build-product verifier should reject duplicate embedded system extensions",
            failures)
    require("find \"$system_extensions_path\" -maxdepth 1 -name '*.systemextension' -print" in verify_build_products_source and "-type d -name '*.systemextension'" not in verify_build_products_source and "stray embedded system extension file" in verify_build_products_test_source and "test_validator_rejects_directory_only_embedded_extension_count" in validate_project_test_source,
            "build-product verifier should count every top-level .systemextension path",
            failures)
    require('[ ! -f "$video_path" ] || [ ! -s "$video_path" ]' in verify_build_products_source and "directory bundled video resource" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_video_file_guard" in validate_project_test_source,
            "build-product verifier should reject non-file bundled video resources before parsing metadata",
            failures)
    require("is_executable_name()" in verify_build_products_source and '[ -n "$executable_name" ]' in verify_build_products_source and "Invalid %s %s CFBundleExecutable" in verify_build_products_source and "path-like extension executable declaration" in verify_build_products_test_source and "path-like app executable declaration" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_executable_name_guard" in validate_project_test_source,
            "build-product verifier should reject blank or path-like CFBundleExecutable values",
            failures)
    require('"readiness-rollup"' in verify_build_products_source and '"readiness-rollup-unknown"' in verify_build_products_source and '"readiness-rollup-ready"' in verify_build_products_source and '"missing-runtime-bundles"' in verify_build_products_source and "Ready fixture: yes" in verify_build_products_source and "Blocked fixture: no" in verify_build_products_source and "Unknown fixture: unknown" in verify_build_products_source and "Runtime readiness result: blocked" in verify_build_products_source and "Runtime readiness checks ready: 1/3" in verify_build_products_source and "Runtime readiness checks blocked: 1" in verify_build_products_source and "Runtime readiness checks unknown: 1" in verify_build_products_source and "Runtime readiness result: incomplete" in verify_build_products_source and "Runtime readiness checks ready: 1/2" in verify_build_products_source and "Runtime readiness checks blocked: 0" in verify_build_products_source and "Runtime readiness result: ready" in verify_build_products_source and "Runtime readiness checks ready: 1/1" in verify_build_products_source and "Application location ready: no" in verify_build_products_source and "App signature ready: no" in verify_build_products_source and "Extension CMIO Mach service ready: no" in verify_build_products_source and "Bundled video metadata ready: no" in verify_build_products_source and "Runtime readiness checks ready: 0/15" in verify_build_products_source and "Runtime readiness checks blocked: 15" in verify_build_products_source and "Runtime readiness checks unknown: 0" in verify_build_products_source and "Runtime readiness next action: resolve Application location ready" in verify_build_products_source and "Runtime readiness next action: submit the system extension request" in verify_build_products_source,
            "build-product verifier should run bundled runtime diagnostics readiness-rollup and missing-bundle self-tests",
            failures)
    require('"bundle-version-match"' in verify_build_products_source and "Bundle version match fixture: yes" in verify_build_products_source and "Bundle version short mismatch fixture: no" in verify_build_products_source and "Bundle version build mismatch fixture: no" in verify_build_products_source and "Bundle version missing fixture: no" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics bundle-version self-test",
            failures)
    require('"executable-readiness"' in verify_build_products_source and "Executable missing name fixture: no" in verify_build_products_source and "Executable missing file fixture: no" in verify_build_products_source and "Executable ready fixture: yes" in verify_build_products_source and "Executable non-executable fixture: no" in verify_build_products_source and "Executable path-like name fixture: no" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics executable-readiness self-test",
            failures)
    require('"team-id"' in verify_build_products_source and "Team ID match fixture: yes" in verify_build_products_source and "Team ID mismatch fixture: no" in verify_build_products_source and "Team ID missing app fixture: no" in verify_build_products_source and "Team ID missing extension fixture: no" in verify_build_products_source and "Team ID short fixture: no" in verify_build_products_source and "Team ID dotted fixture: no" in verify_build_products_source and "Team ID multiple app fixture: no" in verify_build_products_source and "Team ID multiple extension fixture: no" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics Team ID self-test",
            failures)
    require('"extension-host-entitlement"' in verify_build_products_source and "Extension host entitlement valid absent fixture: yes" in verify_build_products_source and "Extension host entitlement valid present fixture: no" in verify_build_products_source and "Extension host entitlement invalid signature fixture: no" in verify_build_products_source and "Extension host entitlement unreadable fixture: no" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics extension host entitlement self-test",
            failures)
    require("Boolean entitlement all architectures present fixture: yes" in verify_build_products_source and "Boolean entitlement missing architecture fixture: no" in verify_build_products_source and "Boolean entitlement unreadable architecture fixture: unknown" in verify_build_products_source and "Boolean entitlement empty architecture fixture: unknown" in verify_build_products_source and "Boolean entitlement malformed plist fixture: unknown" in verify_build_products_source and "Boolean entitlement scalar fixture: unknown" in verify_build_products_source and "Boolean entitlement fallback scalar fixture: unknown" in verify_build_products_source and "Boolean entitlement scalar fixture: yes" in verify_build_products_test_source and "Boolean entitlement fallback scalar fixture: yes" in verify_build_products_test_source,
            "build-product verifier should check bundled runtime diagnostics all-architecture boolean entitlement self-tests",
            failures)
    require('"application-identity"' in verify_build_products_source and "App path match fixture: yes" in verify_build_products_source and "App path mismatch fixture: no" in verify_build_products_source and "Application location existing fixture: yes" in verify_build_products_source and "Application location missing fixture: no" in verify_build_products_source and "Application location mismatch fixture: no" in verify_build_products_source and "Bundle identifier match fixture: yes" in verify_build_products_source and "Bundle identifier mismatch fixture: no" in verify_build_products_source and "Bundle identifier missing fixture: no" in verify_build_products_source and "Info.plist string metadata fixture: com.example.StringMetadata" in verify_build_products_source and "Info.plist scalar metadata fixture: missing" in verify_build_products_source and "Info.plist blank string metadata fixture: missing" in verify_build_products_source and "Info.plist untrimmed string metadata fixture: missing" in verify_build_products_source and "Info.plist multiline string metadata fixture: missing" in verify_build_products_source and "Info.plist nested string metadata fixture: com.example.StringMetadata.Extension" in verify_build_products_source and "Info.plist nested scalar metadata fixture: missing" in verify_build_products_source and "Info.plist nested blank string metadata fixture: missing" in verify_build_products_source and "Info.plist nested untrimmed string metadata fixture: missing" in verify_build_products_source and "Info.plist nested multiline string metadata fixture: missing" in verify_build_products_source and "Info.plist untrimmed string metadata fixture: missing" in verify_build_products_test_source and "Info.plist multiline string metadata fixture: missing" in verify_build_products_test_source and "Info.plist nested untrimmed string metadata fixture: missing" in verify_build_products_test_source and "Info.plist nested multiline string metadata fixture: missing" in verify_build_products_test_source and "test_validator_rejects_missing_packaged_multiline_info_plist_verifier" in validate_project_test_source,
            "build-product verifier should run the bundled runtime diagnostics application-identity self-test",
            failures)
    require('"video-metadata"' in verify_build_products_source and "Video metadata parsed width fixture: 1280" in verify_build_products_source and "Video metadata parsed height fixture: 720" in verify_build_products_source and "Video metadata parsed duration fixture: 12.5" in verify_build_products_source and "Video metadata spaced width fixture: 1280" in verify_build_products_source and "Video metadata quoted duration fixture: 12.5" in verify_build_products_source and "Video metadata preferred parser fixture: 1280" in verify_build_products_source and "Video metadata blank fallback fixture: 640" in verify_build_products_source and "Video metadata null fallback fixture: 640" in verify_build_products_source and "Video metadata parenthesized null fallback fixture: 640" in verify_build_products_source and "Video metadata ready fixture: yes" in verify_build_products_source and "Video metadata decimal fixture: yes" in verify_build_products_source and "Video metadata non-numeric width fixture: no" in verify_build_products_source and "Video metadata wrong width fixture: no" in verify_build_products_source and "Video metadata wrong frame rate fixture: no" in verify_build_products_source and "Video metadata missing frame rate fixture: unknown" in verify_build_products_source and "Video metadata missing duration fixture: unknown" in verify_build_products_source and "Video metadata zero duration fixture: no" in verify_build_products_source and "Video metadata negative duration fixture: no" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics video-metadata self-test",
            failures)
    require('"file-byte-count"' in verify_build_products_source and "File byte count fixture: 5" in verify_build_products_source and "Video SHA-256: unknown" in verify_build_products_source and "Video SHA-256: unknown" in verify_build_products_test_source,
            "build-product verifier should run the bundled runtime diagnostics file-byte-count self-test",
            failures)
    require('"application-group"' in verify_build_products_source and "Application group direct fixture ready: no" in verify_build_products_source and "Application group shared fixture ready: yes" in verify_build_products_source and "Application group missing fixture ready: no" in verify_build_products_source and "Application group mismatched fixture ready: no" in verify_build_products_source and "Application group short-prefix fixture ready: no" in verify_build_products_source and "Application group wrong suffix fixture ready: no" in verify_build_products_source and "Application group dotted-prefix fixture ready: no" in verify_build_products_source and "Application group unresolved fixture ready: no" in verify_build_products_source and "Application group empty format fixture: none" in verify_build_products_source and "Application group list format fixture: ABCDE12345.com.garethpaul.GarethVideoCam, ZYXWV98765.com.garethpaul.GarethVideoCam" in verify_build_products_source and "Application group malformed entitlements readable fixture: no" in verify_build_products_source and "Application group scalar entitlements readable fixture: no" in verify_build_products_source and "Application group non-string entitlements readable fixture: no" in verify_build_products_source and "Application group untrimmed entitlements readable fixture: no" in verify_build_products_source and "Application group multiline entitlements readable fixture: no" in verify_build_products_source and "Application group fallback scalar entitlements readable fixture: no" in verify_build_products_source and "Application group fallback non-string entitlements readable fixture: no" in verify_build_products_source and "Application group fallback untrimmed entitlements readable fixture: no" in verify_build_products_source and "Application group fallback encoded multiline entitlements readable fixture: no" in verify_build_products_source and "Application group fallback malformed entitlements readable fixture: no" in verify_build_products_source and "Application group malformed entitlements readable fixture: yes" in verify_build_products_test_source and "Application group scalar entitlements readable fixture: yes" in verify_build_products_test_source and "Application group non-string entitlements readable fixture: yes" in verify_build_products_test_source and "Application group untrimmed entitlements readable fixture: yes" in verify_build_products_test_source and "Application group multiline entitlements readable fixture: yes" in verify_build_products_test_source and "Application group fallback scalar entitlements readable fixture: yes" in verify_build_products_test_source and "Application group fallback non-string entitlements readable fixture: yes" in verify_build_products_test_source and "Application group fallback untrimmed entitlements readable fixture: yes" in verify_build_products_test_source and "Application group fallback encoded multiline entitlements readable fixture: yes" in verify_build_products_test_source and "Application group fallback malformed entitlements readable fixture: yes" in verify_build_products_test_source and "test_validator_rejects_missing_packaged_multiline_app_group_verifier" in validate_project_test_source and "test_validator_rejects_missing_packaged_fallback_encoded_multiline_app_group_verifier" in validate_project_test_source,
            "build-product verifier should run the bundled runtime diagnostics application-group self-test",
            failures)
    require("Application group all architectures common fixture: ABCDE12345.com.garethpaul.GarethVideoCam" in verify_build_products_source and "Application group missing architecture common fixture: none" in verify_build_products_source,
            "build-product verifier should check bundled runtime diagnostics all-architecture application-group self-tests",
            failures)
    require('"mach-service"' in verify_build_products_source and "Mach service direct fixture resolved: yes" in verify_build_products_source and "Mach service direct fixture matches expected: yes" in verify_build_products_source and "Mach service direct fixture ready: yes" in verify_build_products_source and "Mach service team-prefixed fixture ready: yes" in verify_build_products_source and "Mach service short-prefix fixture ready: no" in verify_build_products_source and "Mach service dotted-prefix fixture ready: no" in verify_build_products_source and "Mach service unresolved fixture resolved: no" in verify_build_products_source and "Mach service wrong fixture matches expected: no" in verify_build_products_source and "Mach service missing fixture ready: no" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics mach-service self-test",
            failures)
    require('"camera-device"' in verify_build_products_source and "Camera device present fixture: yes" in verify_build_products_source and "Camera device missing fixture: no" in verify_build_products_source and "Camera device substring fixture: no" in verify_build_products_source and "Camera device empty fixture: unknown" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics camera-device self-test",
            failures)
    require('"registration"' in verify_build_products_source and "Registration active fixture present: yes" in verify_build_products_source and "Registration active fixture activated enabled: yes" in verify_build_products_source and "Registration reversed fixture activated enabled: yes" in verify_build_products_source and "Registration waiting fixture activated enabled: no" in verify_build_products_source and "Registration deactivated fixture activated enabled: no" in verify_build_products_source and "Registration longer identifier fixture present: no" in verify_build_products_source and "Registration longer identifier fixture activated enabled: no" in verify_build_products_source and "Registration missing fixture present: no" in verify_build_products_source and "Registration empty fixture present: unknown" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics registration self-test",
            failures)
    require('"activation-evidence"' in verify_build_products_source and "Runtime activation evidence result: active" in verify_build_products_source and "Runtime activation evidence checks ready: 3/3" in verify_build_products_source and "Runtime activation evidence next action: open a camera picker and confirm Gareth Video Cam is selectable" in verify_build_products_source and "Runtime activation evidence result: blocked" in verify_build_products_source and "Runtime activation evidence next action: resolve Extension registration entry present" in verify_build_products_source and "Runtime activation evidence result: incomplete" in verify_build_products_source and "Runtime activation evidence checks ready: 0/3" in verify_build_products_source and "Runtime activation evidence checks unknown: 3" in verify_build_products_source and "Runtime activation evidence next action: inspect Extension registration activated enabled" in verify_build_products_source and "Runtime activation evidence next action: inspect Extension registration entry present" in verify_build_products_source,
            "build-product verifier should run the bundled runtime diagnostics activation-evidence self-test",
            failures)
    require('verify_bundled_video_metadata "$configuration" "$video_path"\n  verify_app_diagnostics_resources "$configuration" "$app_path"' in verify_build_products_source,
            "build-product verifier should run bundled app diagnostics self-tests after extension and video metadata checks",
            failures)
    require("APP_CAMERA_USAGE_DESCRIPTION" in verify_build_products_source and "APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION" in verify_build_products_source and "EXTENSION_CAMERA_USAGE_DESCRIPTION" in verify_build_products_source and "EXTENSION_SYSTEM_EXTENSION_USAGE_DESCRIPTION" in verify_build_products_source and "verify_info_plist_value \"$configuration\" \"app\" \"$app_path\" \"NSCameraUsageDescription\"" in verify_build_products_source and "verify_info_plist_value \"$configuration\" \"extension\" \"$extension_path\" \"NSCameraUsageDescription\"" in verify_build_products_source,
            "build-product verifier should require exact product-specific app and extension privacy usage strings",
            failures)
    require("if isinstance(value, str):" in verify_build_products_source and "if \"\\n\" in value or \"\\r\" in value:" in verify_build_products_source and "trimmed_value = value.strip()" in verify_build_products_source and "if trimmed_value and trimmed_value == value:" in verify_build_products_source and "set_info_plist_boolean_key" in verify_build_products_test_source and "non-string app display name" in verify_build_products_test_source and "blank app display name" in verify_build_products_test_source and "untrimmed app display name" in verify_build_products_test_source and "multiline app display name" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_blank_info_plist_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_untrimmed_info_plist_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_multiline_info_plist_guard" in validate_project_test_source,
            "build-product verifier should reject non-string, blank, untrimmed, or multiline Info.plist display and privacy strings",
            failures)
    require("if isinstance(mach_service_name, str):" in verify_build_products_source and "if \"\\n\" in mach_service_name or \"\\r\" in mach_service_name:" in verify_build_products_source and "trimmed_mach_service_name = mach_service_name.strip()" in verify_build_products_source and "if trimmed_mach_service_name and trimmed_mach_service_name == mach_service_name:" in verify_build_products_source and "non-string CMIO extension metadata" in verify_build_products_test_source and "blank CMIO extension metadata" in verify_build_products_test_source and "untrimmed CMIO extension metadata" in verify_build_products_test_source and "multiline CMIO extension metadata" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_blank_cmio_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_cmio_string_type_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_untrimmed_cmio_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_multiline_cmio_guard" in validate_project_test_source,
            "build-product verifier should reject non-string, blank, untrimmed, or multiline CMIO Mach-service metadata as missing",
            failures)
    require(verify_build_products_path.stat().st_mode & 0o111,
            "build-product verifier script should be executable",
            failures)
    require("write_product_fixture" in verify_build_products_test_source and "write_executable_fixture" in verify_build_products_test_source and "remove_info_plist_key" in verify_build_products_test_source and "set_info_plist_key" in verify_build_products_test_source and "cp \"$ROOT/scripts/collect_runtime_diagnostics.sh\"" in verify_build_products_test_source and "cp \"$ROOT/scripts/validate_project.py\"" in verify_build_products_test_source and "cp \"$ROOT/Extension/video.mp4\"" in verify_build_products_test_source and "Missing Debug app product" in verify_build_products_test_source and "Missing Debug embedded system extension" in verify_build_products_test_source and "com.example.WrongExtension" in verify_build_products_test_source and "Unexpected Debug extension bundle identifier" in verify_build_products_test_source and "Missing Debug app CFBundleDisplayName" in verify_build_products_test_source and "blank app display name" in verify_build_products_test_source and "untrimmed app display name" in verify_build_products_test_source and "multiline app display name" in verify_build_products_test_source and "Missing Debug extension CFBundleDisplayName" in verify_build_products_test_source and "Unexpected Debug app CFBundleDisplayName" in verify_build_products_test_source and "Unexpected Debug extension CFBundleDisplayName" in verify_build_products_test_source and "Missing Debug app NSSystemExtensionUsageDescription" in verify_build_products_test_source and "Missing Debug extension NSSystemExtensionUsageDescription" in verify_build_products_test_source and "Missing Debug app NSCameraUsageDescription" in verify_build_products_test_source and "Missing Debug extension NSCameraUsageDescription" in verify_build_products_test_source and "Unexpected Debug app NSSystemExtensionUsageDescription" in verify_build_products_test_source and "Unexpected Debug extension NSSystemExtensionUsageDescription" in verify_build_products_test_source and "Unexpected Debug app NSCameraUsageDescription" in verify_build_products_test_source and "Unexpected Debug extension NSCameraUsageDescription" in verify_build_products_test_source and "Missing Debug app runtime diagnostics script" in verify_build_products_test_source and "directory runtime diagnostics script" in verify_build_products_test_source and "Missing Debug app runtime diagnostics parser" in verify_build_products_test_source and "directory runtime diagnostics parser" in verify_build_products_test_source and "Missing or empty Debug bundled video resource" in verify_build_products_test_source and "directory bundled video resource" in verify_build_products_test_source and "Missing Debug bundled video dimensions" in verify_build_products_test_source and "unparsable bundled video metadata" in verify_build_products_test_source and "Missing or non-executable Debug app executable" in verify_build_products_test_source and "non-executable app binary" in verify_build_products_test_source and "Missing or non-executable Debug extension executable" in verify_build_products_test_source and "non-executable extension binary" in verify_build_products_test_source and "Missing Debug app CFBundleExecutable" in verify_build_products_test_source and "missing app executable declaration" in verify_build_products_test_source and "Invalid Debug app CFBundleExecutable" in verify_build_products_test_source and "path-like app executable declaration" in verify_build_products_test_source and "Missing Debug extension CFBundleExecutable" in verify_build_products_test_source and "missing extension executable declaration" in verify_build_products_test_source and "Invalid Debug extension CFBundleExecutable" in verify_build_products_test_source and "path-like extension executable declaration" in verify_build_products_test_source and "Missing Debug extension CMIOExtensionMachServiceName" in verify_build_products_test_source and "blank CMIO extension metadata" in verify_build_products_test_source and "untrimmed CMIO extension metadata" in verify_build_products_test_source and "multiline CMIO extension metadata" in verify_build_products_test_source and "Unresolved Debug extension CMIOExtensionMachServiceName" in verify_build_products_test_source and "Unexpected Debug extension CMIOExtensionMachServiceName" in verify_build_products_test_source and "com.example.WrongMachService" in verify_build_products_test_source and "com.example.$EXTENSION_ID" in verify_build_products_test_source and "dotted-prefix CMIO extension metadata" in verify_build_products_test_source and "Mismatched Debug bundle short versions" in verify_build_products_test_source and "Mismatched Debug bundle build versions" in verify_build_products_test_source and "Build-product verifier tests passed." in verify_build_products_test_source,
            "build-product verifier should have fixture coverage for passing products, bundle identifier failures, display metadata failures, version mismatches, missing executables, missing privacy usage strings, missing diagnostics resources, missing/unresolved/unexpected CoreMediaIO metadata, and missing bundled video",
            failures)
    require('if [ ! -f "$script_path" ]; then' in verify_build_products_source and 'if [ ! -f "$parser_path" ]; then' in verify_build_products_source and "directory runtime diagnostics script" in verify_build_products_test_source and "directory runtime diagnostics parser" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_diagnostics_file_guards" in validate_project_test_source,
            "build-product verifier should reject non-file runtime diagnostics resources",
            failures)
    require("duplicate embedded system extension" in verify_build_products_test_source and "stray embedded system extension file" in verify_build_products_test_source and "Unexpected Debug embedded system extension count: 2" in verify_build_products_test_source,
            "build-product verifier tests should cover duplicate embedded system-extension rejection",
            failures)
    require("isinstance(cmio_extension, dict)" in verify_build_products_source and "if isinstance(mach_service_name, str):" in verify_build_products_source and "trimmed_mach_service_name = mach_service_name.strip()" in verify_build_products_source and "if trimmed_mach_service_name and trimmed_mach_service_name == mach_service_name:" in verify_build_products_source and "set_extension_mach_service_boolean" in verify_build_products_test_source and "non-string CMIO extension metadata" in verify_build_products_test_source and "blank CMIO extension metadata" in verify_build_products_test_source and "untrimmed CMIO extension metadata" in verify_build_products_test_source and "test_validator_rejects_missing_build_product_blank_cmio_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_cmio_string_type_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_untrimmed_cmio_guard" in validate_project_test_source,
            "build-product verifier should reject non-string, blank, or untrimmed CMIO Mach-service metadata as missing",
            failures)
    require("write_diagnostics_fixture_script" in verify_build_products_test_source and "stale_outputs" in verify_build_products_test_source and "shell_single_quote" in verify_build_products_test_source and "printf '%s\\\\n'" in verify_build_products_test_source and "assert_stale_diagnostics_rejected()" in verify_build_products_test_source and 'local fixture_writer="$2"' in verify_build_products_test_source and '"$fixture_writer" "$products_path" Debug' in verify_build_products_test_source and '"Unexpected Debug app bundled runtime diagnostics $verifier_label self-test output"' in verify_build_products_test_source,
            "build-product verifier tests should share a helper for stale bundled runtime diagnostics self-test rejection",
            failures)
    require('assert_stale_diagnostics_rejected "stale-resource-discovery-diagnostics" write_stale_resource_discovery_diagnostics_fixture "resource" "resource-discovery"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-readiness-rollup-diagnostics" write_stale_readiness_rollup_diagnostics_fixture "readiness-rollup" "readiness-rollup"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-missing-runtime-bundles-diagnostics" write_stale_missing_runtime_bundles_diagnostics_fixture "missing-runtime-bundles" "missing-runtime-bundles"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-bundle-version-diagnostics" write_stale_bundle_version_diagnostics_fixture "bundle-version" "bundle-version-match"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-executable-readiness-diagnostics" write_stale_executable_readiness_diagnostics_fixture "executable-readiness" "executable-readiness"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-team-id-diagnostics" write_stale_team_id_diagnostics_fixture "Team ID" "Team ID"' in verify_build_products_test_source,
            "build-product verifier tests should reject stale resource, readiness-rollup, missing-runtime-bundles, bundle-version, executable-readiness, and Team ID diagnostics self-test output",
            failures)
    require('assert_stale_diagnostics_rejected "stale-extension-host-entitlement-diagnostics" write_stale_extension_host_entitlement_diagnostics_fixture "extension-host-entitlement" "extension-host-entitlement"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-application-identity-diagnostics" write_stale_application_identity_diagnostics_fixture "application-identity" "application-identity"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-video-metadata-diagnostics" write_stale_video_metadata_diagnostics_fixture "video-metadata" "video-metadata"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-file-byte-count-diagnostics" write_stale_file_byte_count_diagnostics_fixture "file-byte-count" "file-byte-count"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-application-group-diagnostics" write_stale_application_group_diagnostics_fixture "application-group" "application-group"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-mach-service-diagnostics" write_stale_mach_service_diagnostics_fixture "mach-service" "mach-service"' in verify_build_products_test_source,
            "build-product verifier tests should reject stale extension-host-entitlement, identity, video-metadata, file-byte-count, application-group, and mach-service diagnostics self-test output",
            failures)
    require('assert_stale_diagnostics_rejected "stale-camera-device-diagnostics" write_stale_camera_device_diagnostics_fixture "camera-device" "camera-device"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-registration-diagnostics" write_stale_registration_diagnostics_fixture "registration" "registration"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-activation-evidence-diagnostics" write_stale_activation_evidence_diagnostics_fixture "activation-evidence" "activation-evidence"' in verify_build_products_test_source and 'assert_stale_diagnostics_rejected "stale-video-parser-diagnostics" write_stale_video_parser_diagnostics_fixture "parser" "video-parser"' in verify_build_products_test_source,
            "build-product verifier tests should reject stale camera-device, registration, activation-evidence, and parser diagnostics self-test output",
            failures)
    require(verify_build_products_test_path.stat().st_mode & 0o111,
            "build-product verifier test script should be executable",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=resource-discovery" in runtime_diagnostics_test_source and "Diagnostics parser source: adjacent script resource" in runtime_diagnostics_test_source and "Diagnostics parser available: yes" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup-unknown" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup-ready" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=missing-runtime-bundles" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=bundle-version-match" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=mach-service" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=application-group" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=camera-device" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=registration" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=activation-evidence" in runtime_diagnostics_test_source and "Runtime readiness result: blocked" in runtime_diagnostics_test_source and "Runtime readiness result: incomplete" in runtime_diagnostics_test_source and "Runtime readiness result: ready" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 1/3" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 1/2" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 1/1" in runtime_diagnostics_test_source and "Runtime readiness checks ready: 0/15" in runtime_diagnostics_test_source and "Runtime readiness checks blocked: 15" in runtime_diagnostics_test_source and "Runtime readiness checks unknown: 0" in runtime_diagnostics_test_source and "Runtime readiness next action: resolve Blocked fixture" in runtime_diagnostics_test_source and "Runtime readiness next action: resolve Application location ready" in runtime_diagnostics_test_source and "Runtime readiness next action: inspect Unknown fixture" in runtime_diagnostics_test_source and "Runtime readiness next action: submit the system extension request" in runtime_diagnostics_test_source and "Bundle version match fixture: yes" in runtime_diagnostics_test_source and "Bundle version short mismatch fixture: no" in runtime_diagnostics_test_source and "Bundle version build mismatch fixture: no" in runtime_diagnostics_test_source and "Bundle version missing fixture: no" in runtime_diagnostics_test_source and "Mach service direct fixture ready: yes" in runtime_diagnostics_test_source and "Mach service team-prefixed fixture ready: yes" in runtime_diagnostics_test_source and "Mach service unresolved fixture resolved: no" in runtime_diagnostics_test_source and "Mach service wrong fixture matches expected: no" in runtime_diagnostics_test_source and "Application group direct fixture ready: no" in runtime_diagnostics_test_source and "Application group shared fixture ready: yes" in runtime_diagnostics_test_source and "Application group mismatched fixture ready: no" in runtime_diagnostics_test_source and "Application group unresolved fixture ready: no" in runtime_diagnostics_test_source and "Camera device present fixture: yes" in runtime_diagnostics_test_source and "Camera device missing fixture: no" in runtime_diagnostics_test_source and "Camera device substring fixture: no" in runtime_diagnostics_test_source and "Camera device empty fixture: unknown" in runtime_diagnostics_test_source and "Registration active fixture activated enabled: yes" in runtime_diagnostics_test_source and "Registration waiting fixture activated enabled: no" in runtime_diagnostics_test_source and "Registration deactivated fixture activated enabled: no" in runtime_diagnostics_test_source and "Registration longer identifier fixture present: no" in runtime_diagnostics_test_source and "Registration longer identifier fixture activated enabled: no" in runtime_diagnostics_test_source and "Registration empty fixture present: unknown" in runtime_diagnostics_test_source and "Runtime activation evidence result: active" in runtime_diagnostics_test_source and "Runtime activation evidence result: blocked" in runtime_diagnostics_test_source and "Runtime activation evidence result: incomplete" in runtime_diagnostics_test_source and "Runtime activation evidence checks unknown: 3" in runtime_diagnostics_test_source and "Runtime activation evidence next action: resolve Extension registration entry present" in runtime_diagnostics_test_source and "Runtime activation evidence next action: inspect Extension registration activated enabled" in runtime_diagnostics_test_source and "Runtime activation evidence next action: inspect Extension registration entry present" in runtime_diagnostics_test_source and "Runtime diagnostics tests passed." in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover blocked, unknown, ready, and missing-bundle counted readiness rollups plus bundle-version, Mach-service, app-group, camera-device, registration-state, and activation-evidence comparison",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=executable-readiness" in runtime_diagnostics_test_source and "Executable missing name fixture: no" in runtime_diagnostics_test_source and "Executable missing file fixture: no" in runtime_diagnostics_test_source and "Executable non-executable fixture: no" in runtime_diagnostics_test_source and "Executable ready fixture: yes" in runtime_diagnostics_test_source and "Executable path-like name fixture: no" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover executable readiness comparisons",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=application-identity" in runtime_diagnostics_test_source and "App path match fixture: yes" in runtime_diagnostics_test_source and "App path mismatch fixture: no" in runtime_diagnostics_test_source and "Application location existing fixture: yes" in runtime_diagnostics_test_source and "Application location missing fixture: no" in runtime_diagnostics_test_source and "Application location mismatch fixture: no" in runtime_diagnostics_test_source and "Bundle identifier match fixture: yes" in runtime_diagnostics_test_source and "Bundle identifier mismatch fixture: no" in runtime_diagnostics_test_source and "Bundle identifier missing fixture: no" in runtime_diagnostics_test_source and "Info.plist string metadata fixture: com.example.StringMetadata" in runtime_diagnostics_test_source and "Info.plist scalar metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist blank string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist untrimmed string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist multiline string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested string metadata fixture: com.example.StringMetadata.Extension" in runtime_diagnostics_test_source and "Info.plist nested scalar metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested blank string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested untrimmed string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested multiline string metadata fixture: missing" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover application path, bundle identifier, and typed Info.plist metadata comparisons",
            failures)
    require("read_plist_string_value" in runtime_diagnostics_source and "if isinstance(value, str):" in runtime_diagnostics_source and "trimmed_value = value.strip()" in runtime_diagnostics_source and '"\\n" in value or "\\r" in value' in runtime_diagnostics_source and "if trimmed_value and trimmed_value == value:" in runtime_diagnostics_source and "trimmed_value = value" in runtime_diagnostics_source and "if (trimmed_value != value)" in runtime_diagnostics_source and "Info.plist scalar metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist blank string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist untrimmed string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist multiline string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested scalar metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested blank string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested untrimmed string metadata fixture: missing" in runtime_diagnostics_test_source and "Info.plist nested multiline string metadata fixture: missing" in runtime_diagnostics_test_source and "test_validator_rejects_missing_runtime_diagnostics_info_plist_string_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_blank_info_plist_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_untrimmed_info_plist_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_multiline_info_plist_guard" in validate_project_test_source,
            "runtime diagnostics should reject non-string, blank, untrimmed, or multiline Info.plist metadata values",
            failures)
    require("/bin/rm -rf \"$missing_app_path\"" in runtime_diagnostics_source and "temp_dir=\"$(/usr/bin/mktemp -d" in runtime_diagnostics_source and "/bin/mkdir -p \"$existing_app_path\"" in runtime_diagnostics_source and "/bin/rm -rf \"$temp_dir\"" in runtime_diagnostics_source,
            "runtime diagnostics self-test fixtures should use guarded absolute macOS setup and cleanup tools",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=team-id" in runtime_diagnostics_test_source and "Team ID match fixture: yes" in runtime_diagnostics_test_source and "Team ID mismatch fixture: no" in runtime_diagnostics_test_source and "Team ID missing app fixture: no" in runtime_diagnostics_test_source and "Team ID missing extension fixture: no" in runtime_diagnostics_test_source and "Team ID short fixture: no" in runtime_diagnostics_test_source and "Team ID dotted fixture: no" in runtime_diagnostics_test_source and "Team ID multiple app fixture: no" in runtime_diagnostics_test_source and "Team ID multiple extension fixture: no" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover signing Team ID readiness comparisons",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=extension-host-entitlement" in runtime_diagnostics_test_source and "Extension host entitlement valid absent fixture: yes" in runtime_diagnostics_test_source and "Extension host entitlement valid present fixture: no" in runtime_diagnostics_test_source and "Extension host entitlement invalid signature fixture: no" in runtime_diagnostics_test_source and "Extension host entitlement unreadable fixture: no" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover extension host-only entitlement readiness comparisons",
            failures)
    require("Boolean entitlement all architectures present fixture: yes" in runtime_diagnostics_test_source and "Boolean entitlement missing architecture fixture: no" in runtime_diagnostics_test_source and "Boolean entitlement unreadable architecture fixture: unknown" in runtime_diagnostics_test_source and "Boolean entitlement empty architecture fixture: unknown" in runtime_diagnostics_test_source and "Boolean entitlement malformed plist fixture: unknown" in runtime_diagnostics_test_source and "Boolean entitlement scalar fixture: unknown" in runtime_diagnostics_test_source and "Boolean entitlement fallback scalar fixture: unknown" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover all-architecture boolean entitlement comparisons",
            failures)
    require("not isinstance(value, bool)" in runtime_diagnostics_source and "PlistBuddy -x -c \"Print :${entitlement}\"" in runtime_diagnostics_source and "Boolean entitlement scalar fixture: unknown" in runtime_diagnostics_test_source and "Boolean entitlement fallback scalar fixture: unknown" in runtime_diagnostics_test_source,
            "runtime diagnostics should reject scalar boolean entitlement values",
            failures)
    require("Registration reversed fixture activated enabled: yes" in runtime_diagnostics_test_source and "Registration deactivated fixture activated enabled: no" in runtime_diagnostics_test_source and "[enabled activated]" in runtime_diagnostics_source and "[deactivated enabled]" in runtime_diagnostics_source and "bracket = substr($0, RSTART + 1, RLENGTH - 2)" in runtime_diagnostics_source and "token_count = split(bracket, status_tokens" in runtime_diagnostics_source and 'status_tokens[status_index] == "activated"' in runtime_diagnostics_source and 'status_tokens[status_index] == "enabled"' in runtime_diagnostics_source,
            "runtime diagnostics registration checks should use exact activated/enabled status tokens in either order",
            failures)
    require("GARETH_DIAGNOSTICS_SELF_TEST=video-metadata" in runtime_diagnostics_test_source and "Video metadata preferred parser fixture: 1280" in runtime_diagnostics_test_source and "Video metadata spaced width fixture: 1280" in runtime_diagnostics_test_source and "Video metadata quoted duration fixture: 12.5" in runtime_diagnostics_test_source and "Video metadata blank fallback fixture: 640" in runtime_diagnostics_test_source and "Video metadata null fallback fixture: 640" in runtime_diagnostics_test_source and "Video metadata parenthesized null fallback fixture: 640" in runtime_diagnostics_test_source and "Video metadata ready fixture: yes" in runtime_diagnostics_test_source and "Video metadata decimal fixture: yes" in runtime_diagnostics_test_source and "Video metadata non-numeric width fixture: no" in runtime_diagnostics_test_source and "Video metadata wrong width fixture: no" in runtime_diagnostics_test_source and "Video metadata wrong frame rate fixture: no" in runtime_diagnostics_test_source and "Video metadata missing frame rate fixture: unknown" in runtime_diagnostics_test_source and "Video metadata missing duration fixture: unknown" in runtime_diagnostics_test_source and "Video metadata zero duration fixture: no" in runtime_diagnostics_test_source and "Video metadata negative duration fixture: no" in runtime_diagnostics_test_source and "GARETH_DIAGNOSTICS_SELF_TEST=video-parser" in runtime_diagnostics_test_source and "Video parser pixel width fixture: 1280" in runtime_diagnostics_test_source and "Video parser frame rate fixture: 24" in runtime_diagnostics_test_source and "Video parser metadata ready fixture: yes" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover bundled-video metadata readiness comparisons",
            failures)
    require("zero-duration.mp4" in runtime_diagnostics_test_source and "MP4 parser duration seconds = 0" in runtime_diagnostics_test_source and "Video parser metadata ready fixture: no" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover zero-valued parser video metadata readiness",
            failures)
    require(runtime_diagnostics_source.count('if [[ "$team_prefix" =~ ^[[:alnum:]]{10}$ ]]; then') >= 2,
            "runtime diagnostics should restrict Team-ID-prefixed app groups and CMIO Mach services to 10-character Team IDs",
            failures)
    require("Mach service dotted-prefix fixture ready: no" in runtime_diagnostics_test_source and "Mach service short-prefix fixture ready: no" in runtime_diagnostics_test_source and "com.example.$EXTENSION_ID" in runtime_diagnostics_source and "^[[:alnum:]]{10}$" in runtime_diagnostics_source,
            "runtime diagnostics test should reject CMIO Mach service names with dotted non-Team-ID prefixes",
            failures)
    require("Application group dotted-prefix fixture ready: no" in runtime_diagnostics_test_source and "Application group short-prefix fixture ready: no" in runtime_diagnostics_test_source and "dotted_prefix_group" in runtime_diagnostics_source and "application_group_matches_expected_identifier" in runtime_diagnostics_source,
            "runtime diagnostics test should reject app groups with dotted non-Team-ID prefixes",
            failures)
    require('if [ "$application_group" = "$APP_GROUP_BASE_ID" ]; then' not in runtime_diagnostics_source and "Application group direct fixture ready: no" in runtime_diagnostics_test_source,
            "runtime diagnostics should require Team-ID-prefixed app-group identifiers rather than bare group names",
            failures)
    require("Application group empty format fixture: none" in runtime_diagnostics_test_source and "Application group list format fixture: ABCDE12345.com.garethpaul.GarethVideoCam, ZYXWV98765.com.garethpaul.GarethVideoCam" in runtime_diagnostics_test_source and "Application group malformed entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group scalar entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group non-string entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group untrimmed entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group multiline entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group fallback untrimmed entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group fallback encoded multiline entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group fallback malformed entitlements readable fixture: no" in runtime_diagnostics_test_source and "format_application_groups" in runtime_diagnostics_source and "formatted_groups" in runtime_diagnostics_source and "malformed_entitlements_status" in runtime_diagnostics_source and "GARETH_DIAGNOSTICS_SKIP_PYTHON" in runtime_diagnostics_source and "plutil -lint" in runtime_diagnostics_source and "not isinstance(groups, list)" in runtime_diagnostics_source and "not isinstance(group, str)" in runtime_diagnostics_source and 'if ! read_application_groups_from_entitlements_file "$entitlements_file" >"$groups_file" 2>/dev/null; then' in runtime_diagnostics_source,
            "runtime diagnostics test should cover empty and multi-value app-group formatting",
            failures)
    require("not isinstance(group, str)" in runtime_diagnostics_source and "Application group non-string entitlements readable fixture: no" in runtime_diagnostics_test_source,
            "runtime diagnostics should reject non-string app-group entitlement array members",
            failures)
    require("group.strip() != group" in runtime_diagnostics_source and "trimmed_group != group" in runtime_diagnostics_source and "Application group untrimmed entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group fallback untrimmed entitlements readable fixture: no" in runtime_diagnostics_test_source and "test_validator_rejects_missing_runtime_diagnostics_untrimmed_app_group_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_fallback_untrimmed_app_group_guard" in validate_project_test_source,
            "runtime diagnostics should reject untrimmed app-group entitlement strings",
            failures)
    require('"\\n" in group or "\\r" in group' in runtime_diagnostics_source and "Application group multiline entitlements readable fixture: no" in runtime_diagnostics_test_source and "test_validator_rejects_missing_runtime_diagnostics_multiline_app_group_guard" in validate_project_test_source,
            "runtime diagnostics should reject multiline app-group entitlement strings",
            failures)
    require("group ~ /&#([xX]0*[Aa]|0*10);/" in runtime_diagnostics_source and "Application group fallback encoded multiline entitlements readable fixture: no" in runtime_diagnostics_test_source and "test_validator_rejects_missing_runtime_diagnostics_fallback_encoded_multiline_app_group_guard" in validate_project_test_source,
            "runtime diagnostics should reject encoded multiline app-group entitlement strings in the PlistBuddy fallback parser",
            failures)
    require("Application group fallback scalar entitlements readable fixture: no" in runtime_diagnostics_test_source and "Application group fallback non-string entitlements readable fixture: no" in runtime_diagnostics_test_source and "plistbuddy_output" in runtime_diagnostics_source and "PlistBuddy -x -c \"Print :${APP_GROUP_ENTITLEMENT}\"" in runtime_diagnostics_source and "<array>" in runtime_diagnostics_source and "<string>.*<\\/string>" in runtime_diagnostics_source,
            "runtime diagnostics should reject non-array or non-string app-group entitlements in the PlistBuddy fallback parser",
            failures)
    require("Application group all architectures common fixture: ABCDE12345.com.garethpaul.GarethVideoCam" in runtime_diagnostics_test_source and "Application group missing architecture common fixture: none" in runtime_diagnostics_test_source,
            "runtime diagnostics test should cover all-architecture application-group comparisons",
            failures)
    require("is_unsigned_integer" in runtime_diagnostics_source and "stat -f %z" in runtime_diagnostics_source and "stat -c %s" in runtime_diagnostics_source and "run_file_byte_count_self_test" in runtime_diagnostics_source and "file-byte-count" in runtime_diagnostics_source and "File byte count fixture: %s" in runtime_diagnostics_source and "GARETH_DIAGNOSTICS_SELF_TEST=file-byte-count" in runtime_diagnostics_test_source and "File byte count fixture: 5" in runtime_diagnostics_test_source,
            "runtime diagnostics should report clean numeric bundled-video byte counts across BSD and GNU stat variants",
            failures)
    require('shasum -a 256 "$file_path" 2>/dev/null' in runtime_diagnostics_source and 'sha256sum "$file_path" 2>/dev/null' in runtime_diagnostics_source and "Video SHA-256: unknown" in runtime_diagnostics_test_source and "test_validator_rejects_missing_runtime_diagnostics_checksum_failure_guard" in validate_project_test_source,
            "runtime diagnostics should report unknown video checksums without exiting when checksum commands fail",
            failures)
    require(runtime_diagnostics_test_path.stat().st_mode & 0o111,
            "runtime diagnostics test script should be executable",
            failures)
    require("is_executable_name()" in runtime_diagnostics_source and """  if is_executable_name "$executable_name" && [ -f "$executable_path" ] && [ -x "$executable_path" ]; then
""" in runtime_diagnostics_source and """  if is_executable_name "$executable_name"; then
    printf '%s\\n' "${bundle_path}/Contents/MacOS/${executable_name}"
  fi""" in runtime_diagnostics_source and "Executable path-like name fixture: %s" in runtime_diagnostics_source and "Executable path-like name fixture: no" in runtime_diagnostics_test_source and 'app_executable_path="$(bundle_executable_path "$APP_PATH")"' in runtime_diagnostics_source and 'extension_executable_path="$(bundle_executable_path "$EXTENSION_PATH")"' in runtime_diagnostics_source and "test_validator_rejects_missing_runtime_diagnostics_executable_name_guard" in validate_project_test_source,
            "runtime diagnostics should reject path-like executable names before readiness and path reporting",
            failures)
    require("executable_readiness_value" in runtime_diagnostics_source and "run_executable_readiness_self_test" in runtime_diagnostics_source and "executable-readiness" in runtime_diagnostics_source and "Executable ready fixture: %s" in runtime_diagnostics_source and "App executable ready\" \"$(executable_readiness_value" in runtime_diagnostics_source and "Extension executable ready\" \"$(executable_readiness_value" in runtime_diagnostics_source,
            "runtime diagnostics script should test and reuse executable readiness comparisons",
            failures)
    require("bundle_executable_architectures" in runtime_diagnostics_source and "App executable architectures:" in runtime_diagnostics_source and "Extension executable architectures:" in runtime_diagnostics_source,
            "runtime diagnostics script should report app and extension executable architecture slices",
            failures)
    require("print_signed_entitlements" in runtime_diagnostics_source and "%s signed entitlements architecture: %s" in runtime_diagnostics_source and 'print_signed_entitlements "App" "$APP_PATH"' in runtime_diagnostics_source and 'print_signed_entitlements "Extension" "$EXTENSION_PATH"' in runtime_diagnostics_source,
            "runtime diagnostics script should print signed entitlements per executable architecture slice",
            failures)
    require("path_matches_expected_value" in runtime_diagnostics_source and "application_location_readiness_value" in runtime_diagnostics_source and "bundle_identifier_matches_expected_value" in runtime_diagnostics_source and "run_application_identity_self_test" in runtime_diagnostics_source and "application-identity" in runtime_diagnostics_source and "Application location ready\" \"$(application_location_readiness_value" in runtime_diagnostics_source and "App bundle identifier ready\" \"$(bundle_identifier_matches_expected_value" in runtime_diagnostics_source and "Extension bundle identifier ready\" \"$(bundle_identifier_matches_expected_value" in runtime_diagnostics_source,
            "runtime diagnostics script should test and reuse application path and bundle identifier readiness comparisons",
            failures)
    require("codesign -d --all-architectures -v" in runtime_diagnostics_source and "team_identifiers_match_value" in runtime_diagnostics_source and "team_identifier_is_valid" in runtime_diagnostics_source and "^[[:alnum:]]{10}$" in runtime_diagnostics_source and "format_line_values" in runtime_diagnostics_source and "run_team_identifier_self_test" in runtime_diagnostics_source and "team-id" in runtime_diagnostics_source and "Team ID multiple app fixture: %s" in runtime_diagnostics_source and "Team identifiers match: %s" in runtime_diagnostics_source and "Signing Team match ready\" \"$(team_identifiers_match_value" in runtime_diagnostics_source,
            "runtime diagnostics script should test and reuse all-architecture signing Team ID readiness comparisons",
            failures)
    require("codesign -dv" not in runtime_diagnostics_source and runtime_diagnostics_source.count("codesign -d --all-architectures -v") >= 3,
            "runtime diagnostics script should print signing details across all architecture slices",
            failures)
    require("boolean_entitlement_value" in runtime_diagnostics_source and "read_boolean_entitlement_from_entitlements_file" in runtime_diagnostics_source and "plutil -lint" in runtime_diagnostics_source and "unknown; signed entitlements could not be read." in runtime_diagnostics_source and "not isinstance(value, bool)" in runtime_diagnostics_source and "PlistBuddy -x -c \"Print :${entitlement}\"" in runtime_diagnostics_source and "extension_host_only_entitlement_absent_readiness_value" in runtime_diagnostics_source and "run_extension_host_entitlement_self_test" in runtime_diagnostics_source and "extension-host-entitlement" in runtime_diagnostics_source and "Extension host-only entitlement absent\" \"$(extension_host_only_entitlement_absent_readiness_value" in runtime_diagnostics_source,
            "runtime diagnostics script should test and reuse extension host-only entitlement readiness comparisons",
            failures)
    boolean_entitlement_architecture_block = """if ! /usr/bin/codesign -d --architecture "$architecture" --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
      /bin/rm -f "$entitlements_file"
      printf 'unknown\\n'
      return
    fi"""
    require("bundle_executable_architectures" in runtime_diagnostics_source and "/usr/bin/lipo -archs" in runtime_diagnostics_source and boolean_entitlement_architecture_block in runtime_diagnostics_source and "boolean_entitlement_all_architectures_value" in runtime_diagnostics_source and "Boolean entitlement missing architecture fixture: %s" in runtime_diagnostics_source,
            "runtime diagnostics script should read boolean entitlements across all executable architecture slices",
            failures)
    require("read_application_groups_for_architecture" in runtime_diagnostics_source and "read_application_groups_from_entitlements_file" in runtime_diagnostics_source and "common_application_groups_for_architectures" in runtime_diagnostics_source and 'common_application_groups_for_architectures "$architecture_groups" "$architecture_count"' in runtime_diagnostics_source and "Application group missing architecture common fixture: %s" in runtime_diagnostics_source,
            "runtime diagnostics script should require app-group values across all executable architecture slices",
            failures)
    require("./scripts/validate_project.py" in check_project_source and "PYTHONDONTWRITEBYTECODE=1 ./scripts/test_validate_project.py" in check_project_source and "./scripts/test_scan_build_log.py" in check_project_source and "./scripts/test_build_unsigned.sh" in check_project_source and "./scripts/test_collect_runtime_diagnostics.sh" in check_project_source and "./scripts/test_verify_build_products.sh" in check_project_source and "bash -n ./scripts/collect_runtime_diagnostics.sh" in check_project_source and "bash -n ./scripts/build_unsigned.sh" in check_project_source and "bash -n ./scripts/test_build_unsigned.sh" in check_project_source and "bash -n ./scripts/verify_build_products.sh" in check_project_source and "bash -n ./scripts/check_project.sh" in check_project_source and "bash -n ./scripts/test_collect_runtime_diagnostics.sh" in check_project_source and "bash -n ./scripts/test_verify_build_products.sh" in check_project_source and "git diff --check" in check_project_source and "git diff-tree --check --root --no-commit-id -r HEAD" in check_project_source,
            "project check script should run validation, scanner tests, shell syntax checks, and whitespace checks",
            failures)
    require("./scripts/test_validate_project.py" in check_project_source,
            "project check script should run validate_project unit tests",
            failures)
    require(check_project_path.stat().st_mode & 0o111,
            "project check script should be executable",
            failures)
    require(validate_project_test_path.exists() and validate_project_test_path.stat().st_mode & 0o111,
            "validate_project unit test script should exist and be executable",
            failures)
    require("sys.dont_write_bytecode = True" in validate_project_test_source and "malformed mdhd" in validate_project_test_source and "test_unsupported_mdhd_version_does_not_report_duration" in validate_project_test_source and "test_unsupported_hdlr_version_does_not_report_duration" in validate_project_test_source and "test_unsupported_stts_version_does_not_report_frame_rate" in validate_project_test_source and "test_non_integer_stts_rate_does_not_report_frame_rate" in validate_project_test_source and "test_unsupported_stsd_version_does_not_report_dimensions" in validate_project_test_source and "test_non_video_track_stsd_does_not_report_dimensions" in validate_project_test_source and "mp4_video_metadata" in validate_project_test_source and "assert_validator_rejects_mutation" in validate_project_test_source and "test_validator_rejects_missing_indefinite_stream_duration_guard" in validate_project_test_source and "test_validator_rejects_missing_non_finite_stream_duration_guard" in validate_project_test_source and "test_validator_rejects_missing_non_finite_asset_duration_guard" in validate_project_test_source and "test_validator_rejects_missing_video_dimension_unwrap_guard" in validate_project_test_source and "test_validator_rejects_missing_finite_video_dimension_guard" in validate_project_test_source and "test_validator_rejects_missing_non_finite_video_frame_rate_guard" in validate_project_test_source and "test_validator_rejects_missing_non_finite_sample_time_guard" in validate_project_test_source and "test_validator_rejects_missing_sample_count_retiming_guard" in validate_project_test_source and "test_validator_rejects_missing_sample_timing_status_guard" in validate_project_test_source and "test_validator_rejects_missing_retimed_copy_status_guard" in validate_project_test_source and "test_validator_rejects_missing_host_time_sample_retiming" in validate_project_test_source and "test_validator_rejects_missing_unknown_signature_state" in validate_project_test_source and "test_validator_rejects_missing_all_architecture_signature_validation" in validate_project_test_source and "test_validator_rejects_missing_signing_information_unknown_guard" in validate_project_test_source and "test_validator_rejects_missing_host_team_identifier_shape_guard" in validate_project_test_source and "test_validator_rejects_numeric_boolean_entitlement_acceptance" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_untrimmed_app_group_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_multiline_app_group_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_fallback_untrimmed_app_group_guard" in validate_project_test_source and "test_validator_rejects_missing_runtime_diagnostics_multiline_info_plist_guard" in validate_project_test_source and "test_validator_rejects_loose_team_id_prefix_lengths" in validate_project_test_source and "test_validator_rejects_bare_application_group_acceptance" in validate_project_test_source and "test_validator_rejects_missing_extension_load_failure_detail_row" in validate_project_test_source and "test_validator_rejects_untrimmed_host_info_plist_metadata" in validate_project_test_source and "test_validator_rejects_multiline_host_info_plist_metadata" in validate_project_test_source and "test_validator_rejects_untrimmed_host_cmio_metadata" in validate_project_test_source and "test_validator_rejects_multiline_host_cmio_metadata" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_mdhd_version_guard" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_full_box_version_guards" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_video_track_dimension_gate" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_sample_count_guard" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_integer_frame_rate_guard" in validate_project_test_source and "test_validator_rejects_broad_appintents_log_ignore" in validate_project_test_source and "test_validator_rejects_missing_partial_ci_log_scan" in validate_project_test_source and "test_validator_rejects_missing_unreadable_build_log_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_python_resolver" in validate_project_test_source and "test_validator_rejects_missing_build_product_configuration_guard" in validate_project_test_source and "test_validator_rejects_missing_packaged_file_byte_count_verifier" in validate_project_test_source and "test_validator_rejects_missing_packaged_multiline_app_group_verifier" in validate_project_test_source and "test_validator_rejects_missing_packaged_multiline_info_plist_verifier" in validate_project_test_source,
            "validate_project unit tests should cover malformed MP4 metadata parsing and mutation rejection for recent runtime-readiness guardrails",
            failures)
    require("test_validator_rejects_missing_build_product_info_plist_string_type_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_blank_info_plist_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_multiline_info_plist_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_blank_cmio_guard" in validate_project_test_source and "test_validator_rejects_missing_build_product_multiline_cmio_guard" in validate_project_test_source,
            "validate_project unit tests should cover build-product Info.plist string type, blank-string, and multiline guard mutation rejection",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_all_architecture_details" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics all-architecture signature detail mutation rejection",
            failures)
    transactional_timing_message = '"extension should commit sample ' + 'timing state only after retiming succeeds"'
    require(transactional_timing_message in validate_project_source and "test_validator_rejects_missing_transactional_timing_validator" in validate_project_test_source,
            "validate_project should enforce transactional sample timing state",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_all_architecture_entitlements" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics all-architecture boolean entitlement mutation rejection",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_scalar_boolean_entitlement_guard" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics scalar boolean entitlement mutation rejection",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_all_architecture_application_groups" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics all-architecture app-group mutation rejection",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_non_string_app_group_guard" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics non-string app-group mutation rejection",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_multiline_app_group_guard" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics multiline app-group mutation rejection",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_fallback_scalar_app_group_guard" in validate_project_test_source,
            "validate_project unit tests should cover runtime diagnostics fallback scalar app-group mutation rejection",
            failures)
    require("test_truncated_stts_entry_count_does_not_report_frame_rate" in validate_project_test_source and "test_zero_stsd_entry_count_does_not_report_dimensions" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_complete_stts_entry_guard" in validate_project_test_source and "test_validator_rejects_missing_host_mp4_stsd_entry_count_guard" in validate_project_test_source,
            "validate_project unit tests should cover MP4 table entry-count mismatch rejection",
            failures)
    require("len(header) < 24" in validate_project_source and "header[12:16] != b\"IHDR\"" in validate_project_source and "test_truncated_png_signature_does_not_raise" in validate_project_test_source and "test_non_ihdr_png_header_does_not_report_dimensions" in validate_project_test_source and "test_validator_rejects_missing_png_ihdr_guard" in validate_project_test_source,
            "app icon validator should reject malformed PNG headers without raising",
            failures)
    require(validate_project_source.count("except ValueError") >= 2 and validate_project_source.count("point_width != point_height") >= 2 and "scale_value.endswith(\"x\")" in validate_project_source and validate_project_source.count("size.strip() != size") >= 2 and validate_project_source.count("scale_value.strip() != scale_value") >= 2 and "re.fullmatch(r\"[0-9]+\", size_parts[0])" in validate_project_source and "re.fullmatch(r\"[0-9]+\", size_parts[1])" in validate_project_source and "re.fullmatch(r\"[0-9]+\", scale_digits)" in validate_project_source and validate_project_source.count("expected_size is not None") >= 2 and "test_malformed_icon_size_metadata_does_not_raise" in validate_project_test_source and "test_validator_rejects_missing_icon_size_metadata_guard" in validate_project_test_source and "test_validator_rejects_missing_icon_scale_suffix_guard" in validate_project_test_source and "test_validator_rejects_untrimmed_icon_size_metadata" in validate_project_test_source and "test_validator_rejects_permissive_icon_integer_metadata" in validate_project_test_source,
            "app icon validator should reject malformed icon catalog size metadata without raising",
            failures)
    require("codesign -d --entitlements :-" in runtime_diagnostics_source and "codesign --verify --all-architectures" in runtime_diagnostics_source and "spctl --assess" in runtime_diagnostics_source and "systemextensionsctl list" in runtime_diagnostics_source and "systemextensionsctl list failed; registration evidence is unknown." in runtime_diagnostics_source and "registration_output" in runtime_diagnostics_source and "extension_registration_entries" in runtime_diagnostics_source and "extension_registration_present_value" in runtime_diagnostics_source and "extension_registration_activated_enabled_value" in runtime_diagnostics_source and "Extension registration entry present" in runtime_diagnostics_source and "Extension registration activated enabled" in runtime_diagnostics_source and "Matching system extension registration entries:" in runtime_diagnostics_source and "Full systemextensionsctl list output:" in runtime_diagnostics_source and "field_index <= NF" in runtime_diagnostics_source and "$field_index == extension_identifier" in runtime_diagnostics_source and "Camera Devices" in runtime_diagnostics_source and "SPCameraDataType" in runtime_diagnostics_source and "system_profiler SPCameraDataType failed; camera evidence is unknown." in runtime_diagnostics_source and "EXPECTED_CAMERA_NAME" in runtime_diagnostics_source and "camera_device_present_value" in runtime_diagnostics_source and "Expected virtual camera device:" in runtime_diagnostics_source and "Expected virtual camera device present" in runtime_diagnostics_source and "Full system_profiler SPCameraDataType output:" in runtime_diagnostics_source and "Runtime Activation Evidence" in runtime_diagnostics_source and "print_activation_evidence_summary" in runtime_diagnostics_source and "Runtime activation evidence result:" in runtime_diagnostics_source and "Runtime activation evidence checks ready:" in runtime_diagnostics_source and "Runtime activation evidence next action:" in runtime_diagnostics_source and "Running App and Extension Processes" in runtime_diagnostics_source and "/bin/ps -axo" in runtime_diagnostics_source and "script_pid=\"$$\"" in runtime_diagnostics_source and "collect_runtime_diagnostics.sh" in runtime_diagnostics_source and "Diagnostics Resources" in runtime_diagnostics_source and "print_diagnostics_resources" in runtime_diagnostics_source and "Diagnostics script path:" in runtime_diagnostics_source and "Diagnostics parser path:" in runtime_diagnostics_source and "Diagnostics parser source:" in runtime_diagnostics_source and "Diagnostics parser available:" in runtime_diagnostics_source and "DIAGNOSTICS_PARSER_SOURCE" in runtime_diagnostics_source and "$4 ~ /(^|\\/)awk$/" in runtime_diagnostics_source and "Bundle short version:" in runtime_diagnostics_source and "Bundle build version:" in runtime_diagnostics_source and "read_info_plist_value" in runtime_diagnostics_source and "read_plist_string_value" in runtime_diagnostics_source and "plist_xml_string_value" in runtime_diagnostics_source and "if trimmed_value and trimmed_value == value:" in runtime_diagnostics_source and "read_extension_mach_service_name" in runtime_diagnostics_source and "contains_unresolved_build_setting" in runtime_diagnostics_source and "mach_service_resolved_value" in runtime_diagnostics_source and "mach_service_matches_expected_value" in runtime_diagnostics_source and "mach_service_readiness_value" in runtime_diagnostics_source and "EXTENSION_INFO_PLIST" in runtime_diagnostics_source and "CMIOExtension.CMIOExtensionMachServiceName" in runtime_diagnostics_source and "bundle_versions_match_readiness_value" in runtime_diagnostics_source and "APP_GROUP_ENTITLEMENT" in runtime_diagnostics_source and "APP_GROUP_BASE_ID" in runtime_diagnostics_source and "read_application_groups" in runtime_diagnostics_source and "application_groups_ready_value" in runtime_diagnostics_source and "Application group match ready" in runtime_diagnostics_source and "Application groups share expected value:" in runtime_diagnostics_source and "Application groups share expected value: unknown; signed entitlements could not be read." in runtime_diagnostics_source and "App application groups:" in runtime_diagnostics_source and "Extension application groups:" in runtime_diagnostics_source and "Expected application group suffix:" in runtime_diagnostics_source and "Bundle Version Match" in runtime_diagnostics_source and "App bundle short version:" in runtime_diagnostics_source and "App bundle build version:" in runtime_diagnostics_source and "Extension bundle short version:" in runtime_diagnostics_source and "Extension bundle build version:" in runtime_diagnostics_source and "Bundle short versions match:" in runtime_diagnostics_source and "Bundle build versions match:" in runtime_diagnostics_source and "Bundle versions match ready" in runtime_diagnostics_source and "Application Runtime Metadata" in runtime_diagnostics_source and "App CFBundleExecutable:" in runtime_diagnostics_source and "App executable path:" in runtime_diagnostics_source and "App executable exists:" in runtime_diagnostics_source and "App executable is executable:" in runtime_diagnostics_source and "App executable ready" in runtime_diagnostics_source and "Embedded Extension Runtime Metadata" in runtime_diagnostics_source and "Extension CFBundleExecutable:" in runtime_diagnostics_source and "Extension executable path:" in runtime_diagnostics_source and "Extension executable exists:" in runtime_diagnostics_source and "Extension executable is executable:" in runtime_diagnostics_source and "Extension CMIO Mach service:" in runtime_diagnostics_source and "Extension CMIO Mach service resolved:" in runtime_diagnostics_source and "Extension CMIO Mach service matches expected identifier:" in runtime_diagnostics_source and "Extension executable ready" in runtime_diagnostics_source and "Extension CMIO Mach service ready" in runtime_diagnostics_source and "print_readiness_check" in runtime_diagnostics_source and "print_readiness_rollup" in runtime_diagnostics_source and "Runtime readiness result:" in runtime_diagnostics_source and "Runtime readiness checks ready:" in runtime_diagnostics_source and "Runtime readiness checks blocked:" in runtime_diagnostics_source and "Runtime readiness checks unknown:" in runtime_diagnostics_source and "Runtime readiness next action:" in runtime_diagnostics_source and "readiness_first_blocked_label" in runtime_diagnostics_source and "readiness_first_unknown_label" in runtime_diagnostics_source and "readiness_ready_count" in runtime_diagnostics_source and "readiness_blocked_count" in runtime_diagnostics_source and "readiness_unknown_count" in runtime_diagnostics_source and "Contents/Info.plist" in runtime_diagnostics_source and "PlistBuddy -x -c \"Print :${plistbuddy_key_path}\"" in runtime_diagnostics_source and "plutil -extract \"$key_path\" xml1" in runtime_diagnostics_source and "CFBundleShortVersionString" in runtime_diagnostics_source and "CFBundleVersion" in runtime_diagnostics_source and "LOG_WINDOW" in runtime_diagnostics_source and "Bundled Video" in runtime_diagnostics_source and "VIDEO_PATH" in runtime_diagnostics_source and "Video resource exists:" in runtime_diagnostics_source and "Video byte size:" in runtime_diagnostics_source and "Video resource is empty:" in runtime_diagnostics_source and "Video SHA-256:" in runtime_diagnostics_source and "print_file_sha256" in runtime_diagnostics_source and "kMDItemPixelWidth" in runtime_diagnostics_source and "kMDItemPixelHeight" in runtime_diagnostics_source and "kMDItemDurationSeconds" in runtime_diagnostics_source and "Application Location Check" in runtime_diagnostics_source and "EXPECTED_APP_PATH" in runtime_diagnostics_source and "App path is inside /Applications:" in runtime_diagnostics_source and "App path matches expected app path:" in runtime_diagnostics_source and "Quarantine Check" in runtime_diagnostics_source and "print_quarantine_status" in runtime_diagnostics_source and "com.apple.quarantine" in runtime_diagnostics_source and "Bundle Identifier Check" in runtime_diagnostics_source and "read_bundle_identifier" in runtime_diagnostics_source and "App bundle identifier matches:" in runtime_diagnostics_source and "Extension bundle identifier matches:" in runtime_diagnostics_source and "Signing Team Match" in runtime_diagnostics_source and "read_team_identifier" in runtime_diagnostics_source and "Team identifiers match:" in runtime_diagnostics_source and "Entitlement Check" in runtime_diagnostics_source and "HOST_SYSTEM_EXTENSION_ENTITLEMENT" in runtime_diagnostics_source and "boolean_entitlement_value" in runtime_diagnostics_source and "App System Extension entitlement present:" in runtime_diagnostics_source and "Extension carries host-only System Extension entitlement:" in runtime_diagnostics_source and "Runtime Readiness Summary" in runtime_diagnostics_source and "print_yes_no_unknown" in runtime_diagnostics_source and 'if [ "$APP_PATH" = "$EXPECTED_APP_PATH" ]; then' in runtime_diagnostics_source and "Application location ready" in runtime_diagnostics_source and "App bundle identifier ready" in runtime_diagnostics_source and "App signature ready" in runtime_diagnostics_source and "App System Extension entitlement ready" in runtime_diagnostics_source and "Extension bundle identifier ready" in runtime_diagnostics_source and "Extension signature ready" in runtime_diagnostics_source and "Extension host-only entitlement absent" in runtime_diagnostics_source and "Signing Team match ready" in runtime_diagnostics_source and "Bundled video ready" in runtime_diagnostics_source and "systemextensionsd" in runtime_diagnostics_source and "com.apple.CoreMediaIO" in runtime_diagnostics_source,
            "runtime diagnostics script should collect labeled entitlements, app-group readiness, readiness summary, activation evidence, Gatekeeper assessment, bundle versions, quarantine status, system-extension registration, camera inventory, process inventory, configurable log windows, and recent app/system-extension logs",
            failures)
    require("run_if_available xcode-select -p" in runtime_diagnostics_source and "run_if_available xcodebuild -version" in runtime_diagnostics_source and "run_if_available swift --version" in runtime_diagnostics_source and "run_if_available xcrun --sdk macosx --show-sdk-version" in runtime_diagnostics_source and "run_if_available xcrun --sdk macosx --show-sdk-path" in runtime_diagnostics_source and "selected developer directory, Swift version, macOS SDK version and path" in readme_text,
            "runtime diagnostics should report selected developer directory, Swift, and macOS SDK evidence",
            failures)
    require("validate_log_window" in runtime_diagnostics_source and
            "validate_app_path" in runtime_diagnostics_source and
            "App path must be an absolute .app bundle path." in runtime_diagnostics_source and
            "no greater than 24h" in runtime_diagnostics_source and
            "require_rejected_log_window" in runtime_diagnostics_test_source and
            "require_accepted_log_window" in runtime_diagnostics_test_source and
            "require_rejected_app_path" in runtime_diagnostics_test_source,
            "runtime diagnostics should bound caller-selected log history",
            failures)
    require("test_validator_rejects_missing_runtime_diagnostics_app_path_guard" in validate_project_test_source,
            "runtime diagnostics app-path guard should have mutation coverage",
            failures)
    require("runuser" in build_log_scanner_test_source and "nobody" in build_log_scanner_test_source,
            "build-log scanner tests should exercise unreadable logs with dropped privileges when running as root",
            failures)
    require("camera_name = $0" in runtime_diagnostics_source and "sub(/^[[:space:]]+/, \"\", camera_name)" in runtime_diagnostics_source and "sub(/[[:space:]]+$/, \"\", camera_name)" in runtime_diagnostics_source and "sub(/:$/, \"\", camera_name)" in runtime_diagnostics_source and "camera_name == expected_camera_name" in runtime_diagnostics_source,
            "runtime diagnostics camera-device parser should compare exact normalized camera names",
            failures)
    require("EXPECTED_VIDEO_WIDTH" in runtime_diagnostics_source and "EXPECTED_VIDEO_HEIGHT" in runtime_diagnostics_source and "EXPECTED_VIDEO_FRAME_RATE" in runtime_diagnostics_source and "mdls_metadata_value" in runtime_diagnostics_source and "mp4_parser_metadata_output" in runtime_diagnostics_source and "run_video_parser_self_test" in runtime_diagnostics_source and "video-parser" in runtime_diagnostics_source and "validate_project.py" in runtime_diagnostics_source and "MP4 parser frame rate" in runtime_diagnostics_source and "metadata_number_matches_expected_value" in runtime_diagnostics_source and "metadata_positive_number_value" in runtime_diagnostics_source and "video_metadata_readiness_value" in runtime_diagnostics_source and "Expected video pixel width:" in runtime_diagnostics_source and "Expected video frame rate:" in runtime_diagnostics_source and "Video pixel width ready" in runtime_diagnostics_source and "Video pixel height ready" in runtime_diagnostics_source and "Video frame rate ready" in runtime_diagnostics_source and "Video duration ready" in runtime_diagnostics_source and "Bundled video metadata ready" in runtime_diagnostics_source,
            "runtime diagnostics script should report bundled-video metadata readiness for expected dimensions, frame rate, and positive duration",
            failures)
    require("metadata_field_value" in runtime_diagnostics_source and "metadata.get('duration_seconds') or ''" not in runtime_diagnostics_source and "test_validator_rejects_missing_runtime_diagnostics_zero_parser_metadata_guard" in validate_project_test_source,
            "runtime diagnostics should preserve zero-valued parser video metadata instead of treating it as missing",
            failures)

    scheme_path = ROOT / "GarethVideoCam.xcodeproj/xcshareddata/xcschemes/GarethVideoCam.xcscheme"
    scheme = ET.parse(scheme_path).getroot()
    require(scheme.attrib.get("LastUpgradeVersion") == "2600",
            "shared scheme is not marked as upgraded for Xcode 26",
            failures)

    scheme_text = scheme_path.read_text()
    require("/usr/bin/ditto" in scheme_text and "/Applications/${FULL_PRODUCT_NAME}" in scheme_text and "/bin/rm -rf" in scheme_text and "/Applications/*.app" in scheme_text and "Built app bundle is missing" in scheme_text and "${CODESIGNING_FOLDER_PATH:-}" in scheme_text and "<PreActions>" in scheme_text and 'FilePath = "/Applications/GarethVideoCam.app"' in scheme_text,
            "shared scheme should replace the app in /Applications with source and destination guards before system-extension testing",
            failures)
    scheme_copy_scripts = [
        action.attrib.get("scriptText", "")
        for action in scheme.findall(".//ActionContent")
        if "/Applications/${FULL_PRODUCT_NAME}" in action.attrib.get("scriptText", "")
        and "/usr/bin/ditto" in action.attrib.get("scriptText", "")
    ]
    require(bool(scheme_copy_scripts),
            "shared scheme should include at least one app install-copy action",
            failures)
    require(all("Built app bundle is missing" in script and "${CODESIGNING_FOLDER_PATH:-}" in script for script in scheme_copy_scripts),
            "shared scheme install-copy actions should check the built app path before removing /Applications/GarethVideoCam.app",
            failures)
    require(all("Built app bundle is missing" in script and "/bin/rm -rf" in script and script.index("Built app bundle is missing") < script.index("/bin/rm -rf") for script in scheme_copy_scripts),
            "shared scheme install-copy actions should validate the built app path before rm -rf",
            failures)

    workflow_path = ROOT / ".github/workflows/macos-build.yml"
    require(workflow_path.exists(),
            "macOS build workflow is missing",
            failures)
    if workflow_path.exists():
        workflow_text = workflow_path.read_text()
        expected_trigger_block = [
            "on:",
            "  push:",
            "  pull_request:",
            "  workflow_dispatch:",
            "",
        ]
        require(workflow_top_level_block(workflow_text, "on") == expected_trigger_block,
                "macOS build workflow should validate pushes and pull requests for every branch",
                failures)
        checkout_references = [
            reference
            for step in workflow_steps(workflow_text)
            for reference in workflow_action_references(step)
            if reference["reference"].startswith("actions/checkout@")
        ]
        require(len(checkout_references) == 1,
                "macOS build workflow should contain exactly one checkout action step",
                failures)
        if len(checkout_references) == 1:
            checkout_reference = checkout_references[0]
            require(checkout_reference["reference"] == CHECKOUT_ACTION,
                    "macOS build workflow should pin the Node 24-capable checkout action",
                    failures)
            require(checkout_reference["annotation"] == CHECKOUT_RELEASE,
                    "macOS build workflow should label the checkout action with its exact release",
                    failures)
            credential_occurrences = workflow_key_occurrences(workflow_text, "persist-credentials")
            checkout_credentials = [
                occurrence
                for occurrence in credential_occurrences
                if checkout_reference["step"]["start"] <= occurrence["line"] < checkout_reference["step"]["end"]
                and workflow_key_is_direct_step_input(checkout_reference["step"], occurrence)
            ]
            require(len(credential_occurrences) == 1
                    and len(checkout_credentials) == 1
                    and checkout_credentials[0]["value"] == "false",
                    "macOS build workflow checkout should disable persisted credentials exactly once in the checkout step",
                    failures)
        artifact_references = [
            reference
            for step in workflow_steps(workflow_text)
            for reference in workflow_action_references(step)
            if reference["reference"].startswith("actions/upload-artifact@")
        ]
        require(len(artifact_references) == 1,
                "macOS build workflow should contain exactly one upload-artifact action step",
                failures)
        if len(artifact_references) == 1:
            artifact_reference = artifact_references[0]
            require(artifact_reference["reference"] == ARTIFACT_ACTION,
                    "macOS build workflow should pin the upload-artifact action",
                    failures)
            require(artifact_reference["annotation"] == ARTIFACT_RELEASE,
                    "macOS build workflow should label the upload-artifact action with its exact release",
                    failures)
        require("runs-on: macos-26" in workflow_text,
                "macOS build workflow should run on the macOS 26 runner",
                failures)
        require("FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true" in workflow_text,
                "macOS build workflow should opt JavaScript actions into Node 24",
                failures)
        require("permissions:\n  contents: read" in workflow_text,
                "macOS build workflow should limit repository token permissions to read-only contents",
                failures)
        require("concurrency:" in workflow_text and "group: macos-build-${{ github.ref }}" in workflow_text and "cancel-in-progress: true" in workflow_text,
                "macOS build workflow should cancel superseded branch builds",
                failures)
        require("timeout-minutes: 20" in workflow_text,
                "macOS build workflow should bound job runtime",
                failures)
        require("Xcode_26.5" in workflow_text,
                "macOS build workflow should explicitly select Xcode 26.5",
                failures)
        require("sw_vers" in workflow_text and "xcode-select -p" in workflow_text and "xcodebuild -version" in workflow_text and "swift --version" in workflow_text and "xcrun --sdk macosx --show-sdk-version" in workflow_text and "xcrun --sdk macosx --show-sdk-path" in workflow_text,
                "macOS build workflow should print selected macOS, Xcode, Swift, and SDK evidence",
                failures)
        require("Run local validation baseline" in workflow_text and "make check" in workflow_text,
                "macOS build workflow should run the conventional make check validation baseline",
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
        require('BUILD_ARCH="${BUILD_ARCH:-}"' in build_unsigned_source and 'BUILD_ARCH="$(/usr/bin/uname -m)"' in build_unsigned_source and 'validate_build_arch_name "$BUILD_ARCH"' in build_unsigned_source and "ARCHS=\"$BUILD_ARCH\"" in build_unsigned_source,
                "unsigned build script should build the target for the runner architecture",
                failures)
        require("BUILD_OUTPUT_PATH=\"${BUILD_OUTPUT_PATH:-.build/Xcode}\"" in build_unsigned_source and 'BUILD_LOG_PATH="${BUILD_LOG_PATH:-$BUILD_OUTPUT_PATH/Logs}"' in build_unsigned_source and "SYMROOT=\"$BUILD_OUTPUT_PATH/Products\"" in build_unsigned_source and "OBJROOT=\"$BUILD_OUTPUT_PATH/Intermediates\"" in build_unsigned_source and "-derivedDataPath" not in build_unsigned_source,
                "unsigned build script should use overridable repository-local target build output paths",
                failures)
        require("configurations=(Debug Release)" in build_unsigned_source,
                "unsigned build script should build both Debug and Release configurations",
                failures)
        require("configurations=(Debug Release)" in build_unsigned_source and 'tee "$BUILD_LOG_PATH/build-${configuration}.log"' in build_unsigned_source,
                "unsigned build script should capture Debug and Release logs under the configured build output path",
                failures)
        require("Scan Xcode logs for warnings and failures" in workflow_text and "if: always() && hashFiles('.build/Xcode/Logs/build-*.log') != ''" in workflow_text and "./scripts/scan_build_log.py .build/Xcode/Logs/build-*.log" in workflow_text,
                "macOS build workflow should scan any captured Debug or Release xcodebuild output even after failed build steps",
                failures)
        require("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" in workflow_text and "xcode-build-logs" in workflow_text and "path: .build/Xcode/Logs/build-*.log" in workflow_text and "if-no-files-found: ignore" in workflow_text and "test_validator_rejects_incorrect_artifact_release_annotation" in validate_project_test_source,
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
