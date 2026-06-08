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
  local executable_name="$3"
  local mach_service_name="$4"
  local short_version="$5"
  local build_version="$6"

  mkdir -p "$bundle_path/Contents"
  python3 - "$bundle_path/Contents/Info.plist" "$bundle_identifier" "$executable_name" "$mach_service_name" "$short_version" "$build_version" <<'PY'
import plistlib
import sys

info = {
    "CFBundleExecutable": sys.argv[3],
    "CFBundleIdentifier": sys.argv[2],
    "CFBundleShortVersionString": sys.argv[5],
    "CFBundleVersion": sys.argv[6],
    "NSCameraUsageDescription": "Camera usage fixture",
    "NSSystemExtensionUsageDescription": "System extension usage fixture",
}

if sys.argv[4]:
    info["CMIOExtension"] = {
        "CMIOExtensionMachServiceName": sys.argv[4],
    }

with open(sys.argv[1], "wb") as info_file:
    plistlib.dump(info, info_file)
PY
}

set_info_plist_key() {
  local bundle_path="$1"
  local key="$2"
  local value="$3"

  python3 - "$bundle_path/Contents/Info.plist" "$key" "$value" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    info = plistlib.load(info_file)

info[sys.argv[2]] = sys.argv[3]

with open(sys.argv[1], "wb") as info_file:
    plistlib.dump(info, info_file)
PY
}

write_executable_fixture() {
  local bundle_path="$1"
  local executable_name="$2"
  local executable_path="$bundle_path/Contents/MacOS/$executable_name"

  mkdir -p "$(dirname "$executable_path")"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$executable_path"
  chmod +x "$executable_path"
}

remove_info_plist_key() {
  local bundle_path="$1"
  local key="$2"

  python3 - "$bundle_path/Contents/Info.plist" "$key" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    info = plistlib.load(info_file)

info.pop(sys.argv[2], None)

with open(sys.argv[1], "wb") as info_file:
    plistlib.dump(info, info_file)
PY
}

write_product_fixture() {
  local products_path="$1"
  local configuration="$2"
  local extension_identifier="${3:-$EXTENSION_ID}"
  local extension_mach_service_name="${4-$EXTENSION_ID}"
  local app_short_version="${5:-1.0}"
  local extension_short_version="${6:-$app_short_version}"
  local app_build_version="${7:-100}"
  local extension_build_version="${8:-$app_build_version}"
  local app_path="$products_path/$configuration/GarethVideoCam.app"
  local extension_path="$app_path/Contents/Library/SystemExtensions/$EXTENSION_NAME"
  local video_path="$extension_path/Contents/Resources/video.mp4"
  local app_resources_path="$app_path/Contents/Resources"

  write_info_plist "$app_path" "$APP_ID" "GarethVideoCam" "" "$app_short_version" "$app_build_version"
  write_info_plist "$extension_path" "$extension_identifier" "$EXTENSION_ID" "$extension_mach_service_name" "$extension_short_version" "$extension_build_version"
  set_info_plist_key "$app_path" "CFBundleDisplayName" "Gareth Video Cam"
  set_info_plist_key "$extension_path" "CFBundleDisplayName" "Gareth Video Cam Extension"
  write_executable_fixture "$app_path" "GarethVideoCam"
  write_executable_fixture "$extension_path" "$EXTENSION_ID"
  mkdir -p "$app_resources_path"
  cp "$ROOT/scripts/collect_runtime_diagnostics.sh" "$app_resources_path/collect_runtime_diagnostics.sh"
  cp "$ROOT/scripts/validate_project.py" "$app_resources_path/validate_project.py"
  mkdir -p "$(dirname "$video_path")"
  cp "$ROOT/Extension/video.mp4" "$video_path"
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

MISSING_DIAGNOSTICS_PRODUCTS="$TMP_DIR/missing-diagnostics/Products"
write_product_fixture "$MISSING_DIAGNOSTICS_PRODUCTS" Debug
rm "$MISSING_DIAGNOSTICS_PRODUCTS/Debug/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh"

if PRODUCTS_PATH="$MISSING_DIAGNOSTICS_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-diagnostics.out" 2>"$TMP_DIR/missing-diagnostics.err"; then
  printf 'Expected verifier to reject a missing runtime diagnostics script.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app runtime diagnostics script" "$TMP_DIR/missing-diagnostics.err"; then
  printf 'Verifier failure did not explain the missing runtime diagnostics script.\n' >&2
  cat "$TMP_DIR/missing-diagnostics.err" >&2
  exit 1
fi

BAD_VIDEO_METADATA_PRODUCTS="$TMP_DIR/bad-video-metadata/Products"
write_product_fixture "$BAD_VIDEO_METADATA_PRODUCTS" Debug
printf 'video fixture\n' > "$BAD_VIDEO_METADATA_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME/Contents/Resources/video.mp4"

if PRODUCTS_PATH="$BAD_VIDEO_METADATA_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/bad-video-metadata.out" 2>"$TMP_DIR/bad-video-metadata.err"; then
  printf 'Expected verifier to reject an unparsable bundled video resource.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug bundled video dimensions" "$TMP_DIR/bad-video-metadata.err"; then
  printf 'Verifier failure did not explain the unparsable bundled video metadata.\n' >&2
  cat "$TMP_DIR/bad-video-metadata.err" >&2
  exit 1
fi

MISSING_EXECUTABLE_PRODUCTS="$TMP_DIR/missing-executable/Products"
write_product_fixture "$MISSING_EXECUTABLE_PRODUCTS" Debug
rm "$MISSING_EXECUTABLE_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME/Contents/MacOS/$EXTENSION_ID"

if PRODUCTS_PATH="$MISSING_EXECUTABLE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-executable.out" 2>"$TMP_DIR/missing-executable.err"; then
  printf 'Expected verifier to reject a missing extension executable.\n' >&2
  exit 1
fi

if ! grep -q "Missing or non-executable Debug extension executable" "$TMP_DIR/missing-executable.err"; then
  printf 'Verifier failure did not explain the missing extension executable.\n' >&2
  cat "$TMP_DIR/missing-executable.err" >&2
  exit 1
fi

MISSING_USAGE_PRODUCTS="$TMP_DIR/missing-usage/Products"
write_product_fixture "$MISSING_USAGE_PRODUCTS" Debug
remove_info_plist_key "$MISSING_USAGE_PRODUCTS/Debug/GarethVideoCam.app" "NSSystemExtensionUsageDescription"

if PRODUCTS_PATH="$MISSING_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-usage.out" 2>"$TMP_DIR/missing-usage.err"; then
  printf 'Expected verifier to reject a missing app usage description.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app NSSystemExtensionUsageDescription" "$TMP_DIR/missing-usage.err"; then
  printf 'Verifier failure did not explain the missing app usage description.\n' >&2
  cat "$TMP_DIR/missing-usage.err" >&2
  exit 1
fi

WRONG_DISPLAY_PRODUCTS="$TMP_DIR/wrong-display/Products"
write_product_fixture "$WRONG_DISPLAY_PRODUCTS" Debug
set_info_plist_key "$WRONG_DISPLAY_PRODUCTS/Debug/GarethVideoCam.app" "CFBundleDisplayName" "GarethVideoCam"

if PRODUCTS_PATH="$WRONG_DISPLAY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-display.out" 2>"$TMP_DIR/wrong-display.err"; then
  printf 'Expected verifier to reject a wrong app display name.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app CFBundleDisplayName" "$TMP_DIR/wrong-display.err"; then
  printf 'Verifier failure did not explain the wrong app display name.\n' >&2
  cat "$TMP_DIR/wrong-display.err" >&2
  exit 1
fi

MISSING_CMIO_PRODUCTS="$TMP_DIR/missing-cmio/Products"
write_product_fixture "$MISSING_CMIO_PRODUCTS" Debug "$EXTENSION_ID" ""

if PRODUCTS_PATH="$MISSING_CMIO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-cmio.out" 2>"$TMP_DIR/missing-cmio.err"; then
  printf 'Expected verifier to reject missing CMIO extension metadata.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension CMIOExtensionMachServiceName" "$TMP_DIR/missing-cmio.err"; then
  printf 'Verifier failure did not explain the missing CMIO extension metadata.\n' >&2
  cat "$TMP_DIR/missing-cmio.err" >&2
  exit 1
fi

UNRESOLVED_CMIO_PRODUCTS="$TMP_DIR/unresolved-cmio/Products"
write_product_fixture "$UNRESOLVED_CMIO_PRODUCTS" Debug "$EXTENSION_ID" '$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'

if PRODUCTS_PATH="$UNRESOLVED_CMIO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/unresolved-cmio.out" 2>"$TMP_DIR/unresolved-cmio.err"; then
  printf 'Expected verifier to reject unresolved CMIO extension metadata.\n' >&2
  exit 1
fi

if ! grep -q "Unresolved Debug extension CMIOExtensionMachServiceName" "$TMP_DIR/unresolved-cmio.err"; then
  printf 'Verifier failure did not explain unresolved CMIO extension metadata.\n' >&2
  cat "$TMP_DIR/unresolved-cmio.err" >&2
  exit 1
fi

WRONG_CMIO_PRODUCTS="$TMP_DIR/wrong-cmio/Products"
write_product_fixture "$WRONG_CMIO_PRODUCTS" Debug "$EXTENSION_ID" "com.example.WrongMachService"

if PRODUCTS_PATH="$WRONG_CMIO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-cmio.out" 2>"$TMP_DIR/wrong-cmio.err"; then
  printf 'Expected verifier to reject an unexpected CMIO Mach service name.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug extension CMIOExtensionMachServiceName" "$TMP_DIR/wrong-cmio.err"; then
  printf 'Verifier failure did not explain the unexpected CMIO extension metadata.\n' >&2
  cat "$TMP_DIR/wrong-cmio.err" >&2
  exit 1
fi

DOTTED_PREFIX_CMIO_PRODUCTS="$TMP_DIR/dotted-prefix-cmio/Products"
write_product_fixture "$DOTTED_PREFIX_CMIO_PRODUCTS" Debug "$EXTENSION_ID" "com.example.$EXTENSION_ID"

if PRODUCTS_PATH="$DOTTED_PREFIX_CMIO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/dotted-prefix-cmio.out" 2>"$TMP_DIR/dotted-prefix-cmio.err"; then
  printf 'Expected verifier to reject a CMIO Mach service name with a dotted non-Team-ID prefix.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug extension CMIOExtensionMachServiceName" "$TMP_DIR/dotted-prefix-cmio.err"; then
  printf 'Verifier failure did not explain the dotted-prefix CMIO extension metadata.\n' >&2
  cat "$TMP_DIR/dotted-prefix-cmio.err" >&2
  exit 1
fi

SHORT_VERSION_MISMATCH_PRODUCTS="$TMP_DIR/short-version-mismatch/Products"
write_product_fixture "$SHORT_VERSION_MISMATCH_PRODUCTS" Debug "$EXTENSION_ID" "$EXTENSION_ID" "1.0" "2.0"

if PRODUCTS_PATH="$SHORT_VERSION_MISMATCH_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/short-version-mismatch.out" 2>"$TMP_DIR/short-version-mismatch.err"; then
  printf 'Expected verifier to reject mismatched bundle short versions.\n' >&2
  exit 1
fi

if ! grep -q "Mismatched Debug bundle short versions" "$TMP_DIR/short-version-mismatch.err"; then
  printf 'Verifier failure did not explain the mismatched bundle short versions.\n' >&2
  cat "$TMP_DIR/short-version-mismatch.err" >&2
  exit 1
fi

BUILD_VERSION_MISMATCH_PRODUCTS="$TMP_DIR/build-version-mismatch/Products"
write_product_fixture "$BUILD_VERSION_MISMATCH_PRODUCTS" Debug "$EXTENSION_ID" "$EXTENSION_ID" "1.0" "1.0" "100" "101"

if PRODUCTS_PATH="$BUILD_VERSION_MISMATCH_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/build-version-mismatch.out" 2>"$TMP_DIR/build-version-mismatch.err"; then
  printf 'Expected verifier to reject mismatched bundle build versions.\n' >&2
  exit 1
fi

if ! grep -q "Mismatched Debug bundle build versions" "$TMP_DIR/build-version-mismatch.err"; then
  printf 'Verifier failure did not explain the mismatched bundle build versions.\n' >&2
  cat "$TMP_DIR/build-version-mismatch.err" >&2
  exit 1
fi

printf 'Build-product verifier tests passed.\n'
