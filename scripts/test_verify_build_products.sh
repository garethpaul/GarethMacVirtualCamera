#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_ID="com.garethpaul.GarethVideoCam"
EXTENSION_ID="com.garethpaul.GarethVideoCam.Extension"
EXTENSION_NAME="com.garethpaul.GarethVideoCam.Extension.systemextension"

write_info_plist() {
  local bundle_path="$1"
  local bundle_identifier="$2"

  mkdir -p "$bundle_path/Contents"
  python3 - "$bundle_path/Contents/Info.plist" "$bundle_identifier" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as info_file:
    plistlib.dump({"CFBundleIdentifier": sys.argv[2]}, info_file)
PY
}

write_product_fixture() {
  local products_path="$1"
  local configuration="$2"
  local extension_identifier="${3:-$EXTENSION_ID}"
  local app_path="$products_path/$configuration/GarethVideoCam.app"
  local extension_path="$app_path/Contents/Library/SystemExtensions/$EXTENSION_NAME"
  local video_path="$extension_path/Contents/Resources/video.mp4"

  write_info_plist "$app_path" "$APP_ID"
  write_info_plist "$extension_path" "$extension_identifier"
  mkdir -p "$(dirname "$video_path")"
  printf 'video fixture\n' > "$video_path"
}

GOOD_PRODUCTS="$TMP_DIR/good/Products"
for configuration in Debug Release; do
  write_product_fixture "$GOOD_PRODUCTS" "$configuration"
done

PRODUCTS_PATH="$GOOD_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" >/dev/null

BAD_PRODUCTS="$TMP_DIR/bad/Products"
write_product_fixture "$BAD_PRODUCTS" Debug "com.example.WrongExtension"

if PRODUCTS_PATH="$BAD_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"; then
  printf 'Expected verifier to reject a bad extension bundle identifier.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug extension bundle identifier" "$TMP_DIR/bad.err"; then
  printf 'Verifier failure did not explain the bad extension bundle identifier.\n' >&2
  cat "$TMP_DIR/bad.err" >&2
  exit 1
fi

MISSING_VIDEO_PRODUCTS="$TMP_DIR/missing-video/Products"
write_product_fixture "$MISSING_VIDEO_PRODUCTS" Debug
rm "$MISSING_VIDEO_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME/Contents/Resources/video.mp4"

if PRODUCTS_PATH="$MISSING_VIDEO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-video.out" 2>"$TMP_DIR/missing-video.err"; then
  printf 'Expected verifier to reject a missing bundled video resource.\n' >&2
  exit 1
fi

if ! grep -q "Missing or empty Debug bundled video resource" "$TMP_DIR/missing-video.err"; then
  printf 'Verifier failure did not explain the missing bundled video resource.\n' >&2
  cat "$TMP_DIR/missing-video.err" >&2
  exit 1
fi

printf 'Build-product verifier tests passed.\n'
