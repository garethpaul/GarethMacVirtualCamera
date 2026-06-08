#!/usr/bin/env bash
set -euo pipefail

BUILD_OUTPUT_PATH="${BUILD_OUTPUT_PATH:-.build/Xcode}"
PRODUCTS_PATH="${PRODUCTS_PATH:-$BUILD_OUTPUT_PATH/Products}"
APP_NAME="${APP_NAME:-GarethVideoCam.app}"
EXTENSION_NAME="${EXTENSION_NAME:-com.garethpaul.GarethVideoCam.Extension.systemextension}"
APP_ID="${APP_ID:-com.garethpaul.GarethVideoCam}"
EXTENSION_ID="${EXTENSION_ID:-com.garethpaul.GarethVideoCam.Extension}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Gareth Video Cam}"
EXTENSION_DISPLAY_NAME="${EXTENSION_DISPLAY_NAME:-Gareth Video Cam Extension}"

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
  if [ "$actual_value" != "$expected_value" ]; then
    printf 'Unexpected %s %s %s: %s\n' "$configuration" "$bundle_label" "$key" "${actual_value:-unknown}" >&2
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

  if [ "$mach_service_name" != "$EXTENSION_ID" ] && [[ "$mach_service_name" != *".$EXTENSION_ID" ]]; then
    printf 'Unexpected %s extension CMIOExtensionMachServiceName: %s\n' "$configuration" "$mach_service_name" >&2
    exit 1
  fi
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
  verify_info_plist_string "$configuration" "app" "$app_path" "NSCameraUsageDescription"
  verify_info_plist_string "$configuration" "app" "$app_path" "NSSystemExtensionUsageDescription"

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
  verify_info_plist_string "$configuration" "extension" "$extension_path" "NSCameraUsageDescription"
  verify_info_plist_string "$configuration" "extension" "$extension_path" "NSSystemExtensionUsageDescription"
  verify_extension_cmio_metadata "$configuration" "$extension_path"

  if [ ! -s "$video_path" ]; then
    printf 'Missing or empty %s bundled video resource: %s\n' "$configuration" "$video_path" >&2
    exit 1
  fi

  printf 'Verified %s app product, embedded system extension, versions, executables, display metadata, privacy usage strings, resolved CMIO metadata, and bundled video.\n' "$configuration"
done
