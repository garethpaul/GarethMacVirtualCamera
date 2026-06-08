#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_OUTPUT_PATH="${BUILD_OUTPUT_PATH:-.build/Xcode}"
PRODUCTS_PATH="${PRODUCTS_PATH:-$BUILD_OUTPUT_PATH/Products}"
APP_NAME="${APP_NAME:-GarethVideoCam.app}"
EXTENSION_NAME="${EXTENSION_NAME:-com.garethpaul.GarethVideoCam.Extension.systemextension}"
APP_ID="${APP_ID:-com.garethpaul.GarethVideoCam}"
EXTENSION_ID="${EXTENSION_ID:-com.garethpaul.GarethVideoCam.Extension}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Gareth Video Cam}"
EXTENSION_DISPLAY_NAME="${EXTENSION_DISPLAY_NAME:-Gareth Video Cam Extension}"
APP_CAMERA_USAGE_DESCRIPTION="${APP_CAMERA_USAGE_DESCRIPTION:-Gareth Video Cam publishes a virtual camera stream.}"
APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION="${APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION:-Gareth Video Cam installs a camera extension that makes the bundled video available as a virtual camera.}"
EXTENSION_CAMERA_USAGE_DESCRIPTION="${EXTENSION_CAMERA_USAGE_DESCRIPTION:-Gareth Video Cam publishes the bundled video as a virtual camera stream.}"
EXTENSION_SYSTEM_EXTENSION_USAGE_DESCRIPTION="${EXTENSION_SYSTEM_EXTENSION_USAGE_DESCRIPTION:-Gareth Video Cam installs a camera extension that makes the bundled video available as a virtual camera.}"
EXPECTED_VIDEO_WIDTH="${EXPECTED_VIDEO_WIDTH:-1280}"
EXPECTED_VIDEO_HEIGHT="${EXPECTED_VIDEO_HEIGHT:-720}"
EXPECTED_VIDEO_FRAME_RATE="${EXPECTED_VIDEO_FRAME_RATE:-24}"

if [ "$#" -gt 0 ]; then
  configurations=("$@")
else
  configurations=(Debug Release)
fi

read_info_plist_string() {
  local bundle_path="$1"
  local key="$2"
  local info_plist="$bundle_path/Contents/Info.plist"

  if [ ! -f "$info_plist" ]; then
    return
  fi

  python3 - "$info_plist" "$key" 2>/dev/null <<'PY' || true
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    value = plistlib.load(info_file).get(sys.argv[2], "")

if value:
    print(value)
PY
}

read_bundle_identifier() {
  local bundle_path="$1"

  read_info_plist_string "$bundle_path" CFBundleIdentifier
}

read_bundle_executable() {
  local bundle_path="$1"

  read_info_plist_string "$bundle_path" CFBundleExecutable
}

read_bundle_short_version() {
  local bundle_path="$1"

  read_info_plist_string "$bundle_path" CFBundleShortVersionString
}

read_bundle_build_version() {
  local bundle_path="$1"

  read_info_plist_string "$bundle_path" CFBundleVersion
}

read_extension_mach_service_name() {
  local bundle_path="$1"
  local info_plist="$bundle_path/Contents/Info.plist"

  if [ ! -f "$info_plist" ]; then
    return
  fi

  python3 - "$info_plist" 2>/dev/null <<'PY' || true
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    cmio_extension = plistlib.load(info_file).get("CMIOExtension", {})

mach_service_name = cmio_extension.get("CMIOExtensionMachServiceName", "")
if mach_service_name:
    print(mach_service_name)
PY
}

mach_service_matches_expected_identifier() {
  local mach_service_name="$1"
  local extension_identifier="$2"
  local team_prefixed_suffix=".$extension_identifier"
  local team_prefix

  if [ "$mach_service_name" = "$extension_identifier" ]; then
    return 0
  fi

  if [[ "$mach_service_name" == *"$team_prefixed_suffix" ]]; then
    team_prefix="${mach_service_name%"$team_prefixed_suffix"}"
    if [[ "$team_prefix" =~ ^[[:alnum:]]+$ ]]; then
      return 0
    fi
  fi

  return 1
}

verify_bundle_executable() {
  local configuration="$1"
  local bundle_label="$2"
  local bundle_path="$3"
  local executable_name
  local executable_path

  executable_name="$(read_bundle_executable "$bundle_path")"
  if [ -z "$executable_name" ]; then
    printf 'Missing %s %s CFBundleExecutable.\n' "$configuration" "$bundle_label" >&2
    exit 1
  fi

  executable_path="$bundle_path/Contents/MacOS/$executable_name"
  if [ ! -f "$executable_path" ] || [ ! -x "$executable_path" ]; then
    printf 'Missing or non-executable %s %s executable: %s\n' "$configuration" "$bundle_label" "$executable_path" >&2
    exit 1
  fi
}

verify_info_plist_string() {
  local configuration="$1"
  local bundle_label="$2"
  local bundle_path="$3"
  local key="$4"
  local value

  value="$(read_info_plist_string "$bundle_path" "$key")"
  if [ -z "$value" ]; then
    printf 'Missing %s %s %s.\n' "$configuration" "$bundle_label" "$key" >&2
    exit 1
  fi
}

verify_info_plist_value() {
  local configuration="$1"
  local bundle_label="$2"
  local bundle_path="$3"
  local key="$4"
  local expected_value="$5"
  local actual_value

  actual_value="$(read_info_plist_string "$bundle_path" "$key")"
  if [ -z "$actual_value" ]; then
    printf 'Missing %s %s %s.\n' "$configuration" "$bundle_label" "$key" >&2
    exit 1
  fi

  if [ "$actual_value" != "$expected_value" ]; then
    printf 'Unexpected %s %s %s: %s\n' "$configuration" "$bundle_label" "$key" "$actual_value" >&2
    exit 1
  fi
}

verify_app_diagnostics_resources() {
  local configuration="$1"
  local app_path="$2"
  local script_path="$app_path/Contents/Resources/collect_runtime_diagnostics.sh"
  local parser_path="$app_path/Contents/Resources/validate_project.py"
  local resource_self_test_output
  local executable_self_test_output
  local team_identifier_self_test_output
  local application_identity_self_test_output
  local video_metadata_self_test_output
  local application_group_self_test_output
  local mach_service_self_test_output
  local parser_self_test_output

  if [ ! -f "$script_path" ]; then
    printf 'Missing %s app runtime diagnostics script: %s\n' "$configuration" "$script_path" >&2
    exit 1
  fi

  if [ ! -f "$parser_path" ]; then
    printf 'Missing %s app runtime diagnostics parser: %s\n' "$configuration" "$parser_path" >&2
    exit 1
  fi

  if ! /usr/bin/grep -F "VALIDATE_PROJECT_SCRIPT" "$script_path" >/dev/null; then
    printf 'Unexpected %s app runtime diagnostics script content: %s\n' "$configuration" "$script_path" >&2
    exit 1
  fi

  if ! /usr/bin/grep -F "mp4_video_metadata" "$parser_path" >/dev/null; then
    printf 'Unexpected %s app runtime diagnostics parser content: %s\n' "$configuration" "$parser_path" >&2
    exit 1
  fi

  if ! resource_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=resource-discovery /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics resource self-test.\n' "$configuration" >&2
    printf '%s\n' "$resource_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$resource_self_test_output" | /usr/bin/grep -F "Diagnostics parser source: adjacent script resource" >/dev/null \
    || ! printf '%s\n' "$resource_self_test_output" | /usr/bin/grep -F "Diagnostics parser available: yes" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics resource self-test output.\n' "$configuration" >&2
    printf '%s\n' "$resource_self_test_output" >&2
    exit 1
  fi

  if ! executable_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=executable-readiness /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics executable-readiness self-test.\n' "$configuration" >&2
    printf '%s\n' "$executable_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$executable_self_test_output" | /usr/bin/grep -F "Executable ready fixture: yes" >/dev/null \
    || ! printf '%s\n' "$executable_self_test_output" | /usr/bin/grep -F "Executable non-executable fixture: no" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics executable-readiness self-test output.\n' "$configuration" >&2
    printf '%s\n' "$executable_self_test_output" >&2
    exit 1
  fi

  if ! team_identifier_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=team-id /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics Team ID self-test.\n' "$configuration" >&2
    printf '%s\n' "$team_identifier_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$team_identifier_self_test_output" | /usr/bin/grep -F "Team ID match fixture: yes" >/dev/null \
    || ! printf '%s\n' "$team_identifier_self_test_output" | /usr/bin/grep -F "Team ID mismatch fixture: no" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics Team ID self-test output.\n' "$configuration" >&2
    printf '%s\n' "$team_identifier_self_test_output" >&2
    exit 1
  fi

  if ! application_identity_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=application-identity /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics application-identity self-test.\n' "$configuration" >&2
    printf '%s\n' "$application_identity_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$application_identity_self_test_output" | /usr/bin/grep -F "App path match fixture: yes" >/dev/null \
    || ! printf '%s\n' "$application_identity_self_test_output" | /usr/bin/grep -F "Bundle identifier missing fixture: no" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics application-identity self-test output.\n' "$configuration" >&2
    printf '%s\n' "$application_identity_self_test_output" >&2
    exit 1
  fi

  if ! video_metadata_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=video-metadata /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics video-metadata self-test.\n' "$configuration" >&2
    printf '%s\n' "$video_metadata_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$video_metadata_self_test_output" | /usr/bin/grep -F "Video metadata spaced width fixture: 1280" >/dev/null \
    || ! printf '%s\n' "$video_metadata_self_test_output" | /usr/bin/grep -F "Video metadata quoted duration fixture: 12.5" >/dev/null \
    || ! printf '%s\n' "$video_metadata_self_test_output" | /usr/bin/grep -F "Video metadata negative duration fixture: no" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics video-metadata self-test output.\n' "$configuration" >&2
    printf '%s\n' "$video_metadata_self_test_output" >&2
    exit 1
  fi

  if ! application_group_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=application-group /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics application-group self-test.\n' "$configuration" >&2
    printf '%s\n' "$application_group_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$application_group_self_test_output" | /usr/bin/grep -F "Application group shared fixture ready: yes" >/dev/null \
    || ! printf '%s\n' "$application_group_self_test_output" | /usr/bin/grep -F "Application group dotted-prefix fixture ready: no" >/dev/null \
    || ! printf '%s\n' "$application_group_self_test_output" | /usr/bin/grep -F "Application group list format fixture: ABCDE12345.com.garethpaul.GarethVideoCam, ZYXWV98765.com.garethpaul.GarethVideoCam" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics application-group self-test output.\n' "$configuration" >&2
    printf '%s\n' "$application_group_self_test_output" >&2
    exit 1
  fi

  if ! mach_service_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=mach-service /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics mach-service self-test.\n' "$configuration" >&2
    printf '%s\n' "$mach_service_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$mach_service_self_test_output" | /usr/bin/grep -F "Mach service direct fixture ready: yes" >/dev/null \
    || ! printf '%s\n' "$mach_service_self_test_output" | /usr/bin/grep -F "Mach service dotted-prefix fixture ready: no" >/dev/null \
    || ! printf '%s\n' "$mach_service_self_test_output" | /usr/bin/grep -F "Mach service unresolved fixture resolved: no" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics mach-service self-test output.\n' "$configuration" >&2
    printf '%s\n' "$mach_service_self_test_output" >&2
    exit 1
  fi

  if ! parser_self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST=video-parser GARETH_DIAGNOSTICS_VIDEO_FIXTURE="$ROOT/Extension/video.mp4" /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics parser self-test.\n' "$configuration" >&2
    printf '%s\n' "$parser_self_test_output" >&2
    exit 1
  fi

  if ! printf '%s\n' "$parser_self_test_output" | /usr/bin/grep -F "Video parser metadata ready fixture: yes" >/dev/null; then
    printf 'Unexpected %s app bundled runtime diagnostics parser self-test output.\n' "$configuration" >&2
    printf '%s\n' "$parser_self_test_output" >&2
    exit 1
  fi
}

verify_extension_cmio_metadata() {
  local configuration="$1"
  local bundle_path="$2"
  local mach_service_name

  mach_service_name="$(read_extension_mach_service_name "$bundle_path")"
  if [ -z "$mach_service_name" ]; then
    printf 'Missing %s extension CMIOExtensionMachServiceName.\n' "$configuration" >&2
    exit 1
  fi

  if [[ "$mach_service_name" == *'$('* || "$mach_service_name" == *'${'* ]]; then
    printf 'Unresolved %s extension CMIOExtensionMachServiceName: %s\n' "$configuration" "$mach_service_name" >&2
    exit 1
  fi

  if ! mach_service_matches_expected_identifier "$mach_service_name" "$EXTENSION_ID"; then
    printf 'Unexpected %s extension CMIOExtensionMachServiceName: %s\n' "$configuration" "$mach_service_name" >&2
    exit 1
  fi
}

verify_bundled_video_metadata() {
  local configuration="$1"
  local video_path="$2"

  python3 - "$ROOT/scripts/validate_project.py" "$video_path" "$EXPECTED_VIDEO_WIDTH" "$EXPECTED_VIDEO_HEIGHT" "$EXPECTED_VIDEO_FRAME_RATE" "$configuration" <<'PY'
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True

validator_path = Path(sys.argv[1])
video_path = Path(sys.argv[2])
expected_width = int(sys.argv[3])
expected_height = int(sys.argv[4])
expected_frame_rate = int(sys.argv[5])
configuration = sys.argv[6]

spec = importlib.util.spec_from_file_location("validate_project", validator_path)
validator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(validator)

metadata = validator.mp4_video_metadata(video_path)
dimensions = metadata.get("dimensions")
frame_rate = metadata.get("frame_rate")
duration_seconds = metadata.get("duration_seconds")

if dimensions is None:
    print(f"Missing {configuration} bundled video dimensions: {video_path}", file=sys.stderr)
    raise SystemExit(1)

if dimensions != (expected_width, expected_height):
    print(
        f"Unexpected {configuration} bundled video dimensions: "
        f"{dimensions[0]}x{dimensions[1]}",
        file=sys.stderr,
    )
    raise SystemExit(1)

if frame_rate != expected_frame_rate:
    print(
        f"Unexpected {configuration} bundled video frame rate: "
        f"{frame_rate or 'unknown'}",
        file=sys.stderr,
    )
    raise SystemExit(1)

if duration_seconds is None or duration_seconds <= 0:
    print(f"Missing {configuration} bundled video duration: {video_path}", file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_aligned_bundle_versions() {
  local configuration="$1"
  local app_path="$2"
  local extension_path="$3"
  local app_short_version
  local app_build_version
  local extension_short_version
  local extension_build_version

  app_short_version="$(read_bundle_short_version "$app_path")"
  app_build_version="$(read_bundle_build_version "$app_path")"
  extension_short_version="$(read_bundle_short_version "$extension_path")"
  extension_build_version="$(read_bundle_build_version "$extension_path")"

  if [ -z "$app_short_version" ] || [ -z "$extension_short_version" ] || [ "$app_short_version" != "$extension_short_version" ]; then
    printf 'Mismatched %s bundle short versions: app=%s extension=%s\n' "$configuration" "${app_short_version:-unknown}" "${extension_short_version:-unknown}" >&2
    exit 1
  fi

  if [ -z "$app_build_version" ] || [ -z "$extension_build_version" ] || [ "$app_build_version" != "$extension_build_version" ]; then
    printf 'Mismatched %s bundle build versions: app=%s extension=%s\n' "$configuration" "${app_build_version:-unknown}" "${extension_build_version:-unknown}" >&2
    exit 1
  fi
}

for configuration in "${configurations[@]}"; do
  app_path="$PRODUCTS_PATH/$configuration/$APP_NAME"
  extension_path="$app_path/Contents/Library/SystemExtensions/$EXTENSION_NAME"
  video_path="$extension_path/Contents/Resources/video.mp4"

  if [ ! -d "$app_path" ]; then
    printf 'Missing %s app product: %s\n' "$configuration" "$app_path" >&2
    exit 1
  fi

  app_bundle_identifier="$(read_bundle_identifier "$app_path")"
  if [ "$app_bundle_identifier" != "$APP_ID" ]; then
    printf 'Unexpected %s app bundle identifier: %s\n' "$configuration" "${app_bundle_identifier:-unknown}" >&2
    exit 1
  fi

  verify_bundle_executable "$configuration" "app" "$app_path"
  verify_info_plist_value "$configuration" "app" "$app_path" "CFBundleDisplayName" "$APP_DISPLAY_NAME"
  verify_info_plist_value "$configuration" "app" "$app_path" "NSCameraUsageDescription" "$APP_CAMERA_USAGE_DESCRIPTION"
  verify_info_plist_value "$configuration" "app" "$app_path" "NSSystemExtensionUsageDescription" "$APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION"
  verify_app_diagnostics_resources "$configuration" "$app_path"

  if [ ! -d "$extension_path" ]; then
    printf 'Missing %s embedded system extension: %s\n' "$configuration" "$extension_path" >&2
    exit 1
  fi

  extension_bundle_identifier="$(read_bundle_identifier "$extension_path")"
  if [ "$extension_bundle_identifier" != "$EXTENSION_ID" ]; then
    printf 'Unexpected %s extension bundle identifier: %s\n' "$configuration" "${extension_bundle_identifier:-unknown}" >&2
    exit 1
  fi

  verify_aligned_bundle_versions "$configuration" "$app_path" "$extension_path"
  verify_bundle_executable "$configuration" "extension" "$extension_path"
  verify_info_plist_value "$configuration" "extension" "$extension_path" "CFBundleDisplayName" "$EXTENSION_DISPLAY_NAME"
  verify_info_plist_value "$configuration" "extension" "$extension_path" "NSCameraUsageDescription" "$EXTENSION_CAMERA_USAGE_DESCRIPTION"
  verify_info_plist_value "$configuration" "extension" "$extension_path" "NSSystemExtensionUsageDescription" "$EXTENSION_SYSTEM_EXTENSION_USAGE_DESCRIPTION"
  verify_extension_cmio_metadata "$configuration" "$extension_path"

  if [ ! -s "$video_path" ]; then
    printf 'Missing or empty %s bundled video resource: %s\n' "$configuration" "$video_path" >&2
    exit 1
  fi
  verify_bundled_video_metadata "$configuration" "$video_path"

  printf 'Verified %s app product, embedded system extension, versions, executables, display metadata, privacy usage strings, resolved CMIO metadata, and bundled video metadata.\n' "$configuration"
done
