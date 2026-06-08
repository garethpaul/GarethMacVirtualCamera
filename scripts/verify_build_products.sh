#!/usr/bin/env bash
set -euo pipefail

BUILD_OUTPUT_PATH="${BUILD_OUTPUT_PATH:-.build/Xcode}"
PRODUCTS_PATH="${PRODUCTS_PATH:-$BUILD_OUTPUT_PATH/Products}"
APP_NAME="${APP_NAME:-GarethVideoCam.app}"
EXTENSION_NAME="${EXTENSION_NAME:-com.garethpaul.GarethVideoCam.Extension.systemextension}"
APP_ID="${APP_ID:-com.garethpaul.GarethVideoCam}"
EXTENSION_ID="${EXTENSION_ID:-com.garethpaul.GarethVideoCam.Extension}"

if [ "$#" -gt 0 ]; then
  configurations=("$@")
else
  configurations=(Debug Release)
fi

read_bundle_identifier() {
  local bundle_path="$1"
  local info_plist="$bundle_path/Contents/Info.plist"

  if [ ! -f "$info_plist" ]; then
    return
  fi

  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info_plist" 2>/dev/null || true
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

  if [ ! -d "$extension_path" ]; then
    printf 'Missing %s embedded system extension: %s\n' "$configuration" "$extension_path" >&2
    exit 1
  fi

  extension_bundle_identifier="$(read_bundle_identifier "$extension_path")"
  if [ "$extension_bundle_identifier" != "$EXTENSION_ID" ]; then
    printf 'Unexpected %s extension bundle identifier: %s\n' "$configuration" "${extension_bundle_identifier:-unknown}" >&2
    exit 1
  fi

  if [ ! -s "$video_path" ]; then
    printf 'Missing or empty %s bundled video resource: %s\n' "$configuration" "$video_path" >&2
    exit 1
  fi

  printf 'Verified %s app product, embedded system extension, and bundled video.\n' "$configuration"
done
