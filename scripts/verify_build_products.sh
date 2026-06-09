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

python3_command() {
  if [ -n "${PYTHON3_BIN:-}" ]; then
    if command -v "$PYTHON3_BIN" >/dev/null 2>&1; then
      command -v "$PYTHON3_BIN"
      return
    fi

    printf 'Configured PYTHON3_BIN is not executable or not found: %s\n' "$PYTHON3_BIN" >&2
    exit 1
  fi

  if [ -x /usr/bin/python3 ]; then
    printf '/usr/bin/python3\n'
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    printf 'python3 is required to verify build products.\n' >&2
    exit 1
  fi
}

PYTHON3_BIN="$(python3_command)"

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

  "$PYTHON3_BIN" - "$info_plist" "$key" 2>/dev/null <<'PY' || true
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

  "$PYTHON3_BIN" - "$info_plist" 2>/dev/null <<'PY' || true
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

verify_app_diagnostics_self_test() {
  local configuration="$1"
  local app_path="$2"
  local script_path="$3"
  local self_test="$4"
  local failure_label="$5"
  local self_test_output
  local expected_output

  shift 5

  if [ "$self_test" = "video-parser" ]; then
    if ! self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST="$self_test" GARETH_DIAGNOSTICS_VIDEO_FIXTURE="$ROOT/Extension/video.mp4" /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
      printf 'Failed %s app bundled runtime diagnostics %s self-test.\n' "$configuration" "$failure_label" >&2
      printf '%s\n' "$self_test_output" >&2
      exit 1
    fi
  elif ! self_test_output="$(GARETH_DIAGNOSTICS_SELF_TEST="$self_test" /bin/bash "$script_path" "$app_path" 1m 2>&1)"; then
    printf 'Failed %s app bundled runtime diagnostics %s self-test.\n' "$configuration" "$failure_label" >&2
    printf '%s\n' "$self_test_output" >&2
    exit 1
  fi

  for expected_output in "$@"; do
    if ! printf '%s\n' "$self_test_output" | /usr/bin/grep -F "$expected_output" >/dev/null; then
      printf 'Unexpected %s app bundled runtime diagnostics %s self-test output.\n' "$configuration" "$failure_label" >&2
      printf '%s\n' "$self_test_output" >&2
      exit 1
    fi
  done
}

verify_app_diagnostics_resources() {
  local configuration="$1"
  local app_path="$2"
  local script_path="$app_path/Contents/Resources/collect_runtime_diagnostics.sh"
  local parser_path="$app_path/Contents/Resources/validate_project.py"

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

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "resource-discovery" "resource" \
    "Diagnostics script path:" \
    "Diagnostics script directory:" \
    "Diagnostics parser path:" \
    "Diagnostics parser source: adjacent script resource" \
    "Diagnostics parser available: yes"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "readiness-rollup" "readiness-rollup" \
    "Ready fixture: yes" \
    "Blocked fixture: no" \
    "Unknown fixture: unknown" \
    "Runtime readiness result: blocked" \
    "Runtime readiness checks ready: 1/3" \
    "Runtime readiness checks blocked: 1" \
    "Runtime readiness checks unknown: 1" \
    "Runtime readiness next action: resolve Blocked fixture"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "readiness-rollup-unknown" "readiness-rollup-unknown" \
    "Ready fixture: yes" \
    "Unknown fixture: unknown" \
    "Runtime readiness result: incomplete" \
    "Runtime readiness checks ready: 1/2" \
    "Runtime readiness checks blocked: 0" \
    "Runtime readiness checks unknown: 1" \
    "Runtime readiness next action: inspect Unknown fixture"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "readiness-rollup-ready" "readiness-rollup-ready" \
    "Ready fixture: yes" \
    "Runtime readiness result: ready" \
    "Runtime readiness checks ready: 1/1" \
    "Runtime readiness checks blocked: 0" \
    "Runtime readiness checks unknown: 0" \
    "Runtime readiness next action: submit the system extension request"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "missing-runtime-bundles" "missing-runtime-bundles" \
    "Application location ready: no" \
    "App bundle identifier ready: no" \
    "App signature ready: no" \
    "App System Extension entitlement ready: no" \
    "App executable ready: no" \
    "Extension bundle identifier ready: no" \
    "Extension signature ready: no" \
    "Extension host-only entitlement absent: no" \
    "Extension executable ready: no" \
    "Extension CMIO Mach service ready: no" \
    "Bundle versions match ready: no" \
    "Signing Team match ready: no" \
    "Application group match ready: no" \
    "Bundled video ready: no" \
    "Bundled video metadata ready: no" \
    "Runtime readiness result: blocked" \
    "Runtime readiness checks ready: 0/15" \
    "Runtime readiness checks blocked: 15" \
    "Runtime readiness checks unknown: 0" \
    "Runtime readiness next action: resolve Application location ready"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "bundle-version-match" "bundle-version" \
    "Bundle version match fixture: yes" \
    "Bundle version short mismatch fixture: no" \
    "Bundle version build mismatch fixture: no" \
    "Bundle version missing fixture: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "executable-readiness" "executable-readiness" \
    "Executable missing name fixture: no" \
    "Executable missing file fixture: no" \
    "Executable ready fixture: yes" \
    "Executable non-executable fixture: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "team-id" "Team ID" \
    "Team ID match fixture: yes" \
    "Team ID mismatch fixture: no" \
    "Team ID missing app fixture: no" \
    "Team ID missing extension fixture: no" \
    "Team ID multiple app fixture: no" \
    "Team ID multiple extension fixture: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "extension-host-entitlement" "extension-host-entitlement" \
    "Boolean entitlement all architectures present fixture: yes" \
    "Boolean entitlement missing architecture fixture: no" \
    "Boolean entitlement unreadable architecture fixture: unknown" \
    "Boolean entitlement empty architecture fixture: unknown" \
    "Extension host entitlement valid absent fixture: yes" \
    "Extension host entitlement valid present fixture: no" \
    "Extension host entitlement invalid signature fixture: no" \
    "Extension host entitlement unreadable fixture: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "application-identity" "application-identity" \
    "App path match fixture: yes" \
    "App path mismatch fixture: no" \
    "Application location existing fixture: yes" \
    "Application location missing fixture: no" \
    "Application location mismatch fixture: no" \
    "Bundle identifier match fixture: yes" \
    "Bundle identifier mismatch fixture: no" \
    "Bundle identifier missing fixture: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "video-metadata" "video-metadata" \
    "Video metadata parsed width fixture: 1280" \
    "Video metadata parsed height fixture: 720" \
    "Video metadata parsed duration fixture: 12.5" \
    "Video metadata spaced width fixture: 1280" \
    "Video metadata quoted duration fixture: 12.5" \
    "Video metadata preferred parser fixture: 1280" \
    "Video metadata blank fallback fixture: 640" \
    "Video metadata null fallback fixture: 640" \
    "Video metadata parenthesized null fallback fixture: 640" \
    "Video metadata ready fixture: yes" \
    "Video metadata decimal fixture: yes" \
    "Video metadata non-numeric width fixture: no" \
    "Video metadata wrong width fixture: no" \
    "Video metadata wrong frame rate fixture: no" \
    "Video metadata missing frame rate fixture: unknown" \
    "Video metadata missing duration fixture: unknown" \
    "Video metadata zero duration fixture: no" \
    "Video metadata negative duration fixture: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "application-group" "application-group" \
    "Application group direct fixture ready: yes" \
    "Application group shared fixture ready: yes" \
    "Application group missing fixture ready: no" \
    "Application group mismatched fixture ready: no" \
    "Application group wrong suffix fixture ready: no" \
    "Application group dotted-prefix fixture ready: no" \
    "Application group unresolved fixture ready: no" \
    "Application group empty format fixture: none" \
    "Application group list format fixture: ABCDE12345.com.garethpaul.GarethVideoCam, ZYXWV98765.com.garethpaul.GarethVideoCam" \
    "Application group all architectures common fixture: ABCDE12345.com.garethpaul.GarethVideoCam" \
    "Application group missing architecture common fixture: none"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "mach-service" "mach-service" \
    "Mach service direct fixture resolved: yes" \
    "Mach service direct fixture matches expected: yes" \
    "Mach service direct fixture ready: yes" \
    "Mach service team-prefixed fixture ready: yes" \
    "Mach service dotted-prefix fixture ready: no" \
    "Mach service unresolved fixture resolved: no" \
    "Mach service wrong fixture matches expected: no" \
    "Mach service missing fixture ready: no"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "camera-device" "camera-device" \
    "Camera device present fixture: yes" \
    "Camera device missing fixture: no" \
    "Camera device substring fixture: no" \
    "Camera device empty fixture: unknown"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "registration" "registration" \
    "Registration active fixture present: yes" \
    "Registration active fixture activated enabled: yes" \
    "Registration reversed fixture activated enabled: yes" \
    "Registration waiting fixture activated enabled: no" \
    "Registration deactivated fixture activated enabled: no" \
    "Registration longer identifier fixture present: no" \
    "Registration longer identifier fixture activated enabled: no" \
    "Registration missing fixture present: no" \
    "Registration empty fixture present: unknown"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "activation-evidence" "activation-evidence" \
    "Runtime activation evidence result: active" \
    "Runtime activation evidence checks ready: 3/3" \
    "Runtime activation evidence next action: open a camera picker and confirm Gareth Video Cam is selectable" \
    "Runtime activation evidence result: blocked" \
    "Runtime activation evidence next action: resolve Extension registration entry present" \
    "Runtime activation evidence result: incomplete" \
    "Runtime activation evidence checks ready: 0/3" \
    "Runtime activation evidence checks unknown: 3" \
    "Runtime activation evidence next action: inspect Extension registration activated enabled" \
    "Runtime activation evidence next action: inspect Extension registration entry present"

  verify_app_diagnostics_self_test "$configuration" "$app_path" "$script_path" "video-parser" "parser" \
    "Video parser pixel width fixture: 1280" \
    "Video parser pixel height fixture: 720" \
    "Video parser frame rate fixture: 24" \
    "Video parser duration fixture: 3.0833333333333335" \
    "Video parser metadata ready fixture: yes"
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

  "$PYTHON3_BIN" - "$ROOT/scripts/validate_project.py" "$video_path" "$EXPECTED_VIDEO_WIDTH" "$EXPECTED_VIDEO_HEIGHT" "$EXPECTED_VIDEO_FRAME_RATE" "$configuration" <<'PY'
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
  verify_app_diagnostics_resources "$configuration" "$app_path"

  printf 'Verified %s app product, embedded system extension, versions, executables, display metadata, privacy usage strings, resolved CMIO metadata, and bundled video metadata.\n' "$configuration"
done
