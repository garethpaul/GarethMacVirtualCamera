#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APP_ID="com.garethpaul.GarethVideoCam"
EXTENSION_ID="com.garethpaul.GarethVideoCam.Extension"
EXTENSION_NAME="com.garethpaul.GarethVideoCam.Extension.systemextension"
APP_CAMERA_USAGE_DESCRIPTION="Gareth Video Cam publishes a virtual camera stream."
APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION="Gareth Video Cam installs a camera extension that makes the bundled video available as a virtual camera."
EXTENSION_CAMERA_USAGE_DESCRIPTION="Gareth Video Cam publishes the bundled video as a virtual camera stream."
EXTENSION_SYSTEM_EXTENSION_USAGE_DESCRIPTION="$APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION"

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

write_diagnostics_fixture_script() {
  local script_path="$1"
  local stale_self_test="$2"

  python3 - "$script_path" "$stale_self_test" <<'PY'
from pathlib import Path
import sys

script_path = Path(sys.argv[1])
stale_self_test = sys.argv[2]

passing_outputs = {
    "resource-discovery": [
        "Diagnostics parser source: adjacent script resource",
        "Diagnostics parser available: yes",
    ],
    "executable-readiness": [
        "Executable ready fixture: yes",
        "Executable non-executable fixture: no",
    ],
    "team-id": [
        "Team ID match fixture: yes",
        "Team ID mismatch fixture: no",
    ],
    "application-identity": [
        "App path match fixture: yes",
        "Bundle identifier missing fixture: no",
    ],
    "video-metadata": [
        "Video metadata spaced width fixture: 1280",
        "Video metadata quoted duration fixture: 12.5",
        "Video metadata negative duration fixture: no",
    ],
    "application-group": [
        "Application group shared fixture ready: yes",
        "Application group dotted-prefix fixture ready: no",
        "Application group list format fixture: ABCDE12345.com.garethpaul.GarethVideoCam, ZYXWV98765.com.garethpaul.GarethVideoCam",
    ],
    "mach-service": [
        "Mach service direct fixture ready: yes",
        "Mach service dotted-prefix fixture ready: no",
        "Mach service unresolved fixture resolved: no",
    ],
    "video-parser": [
        "Video parser metadata ready fixture: yes",
    ],
}

stale_outputs = {
    "team-id": [
        "Team ID match fixture: no",
        "Team ID mismatch fixture: no",
    ],
    "application-identity": [
        "App path match fixture: no",
        "Bundle identifier missing fixture: yes",
    ],
    "video-metadata": [
        "Video metadata spaced width fixture: 640",
        "Video metadata quoted duration fixture: 0",
        "Video metadata negative duration fixture: yes",
    ],
    "application-group": [
        "Application group shared fixture ready: no",
        "Application group dotted-prefix fixture ready: yes",
        "Application group list format fixture: none",
    ],
    "mach-service": [
        "Mach service direct fixture ready: no",
        "Mach service dotted-prefix fixture ready: yes",
        "Mach service unresolved fixture resolved: yes",
    ],
}

if stale_self_test not in stale_outputs:
    raise SystemExit(f"Unknown stale diagnostics fixture: {stale_self_test}")

outputs = dict(passing_outputs)
outputs[stale_self_test] = stale_outputs[stale_self_test]

case_lines = []
for self_test, lines in outputs.items():
    case_lines.append(f"  {self_test})")
    for line in lines:
        case_lines.append(f"    printf '{line}\\n'")
    case_lines.append("    ;;")

script_path.write_text("""#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_PROJECT_SCRIPT="${SCRIPT_DIR}/validate_project.py"
case "${GARETH_DIAGNOSTICS_SELF_TEST:-}" in
""" + "\n".join(case_lines) + """
esac
""")
PY
}

write_stale_team_id_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "team-id"
}

write_stale_application_identity_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "application-identity"
}

write_stale_video_metadata_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "video-metadata"
}

write_stale_application_group_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "application-group"
}

write_stale_mach_service_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "mach-service"
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
  set_info_plist_key "$app_path" "NSCameraUsageDescription" "$APP_CAMERA_USAGE_DESCRIPTION"
  set_info_plist_key "$app_path" "NSSystemExtensionUsageDescription" "$APP_SYSTEM_EXTENSION_USAGE_DESCRIPTION"
  set_info_plist_key "$extension_path" "NSCameraUsageDescription" "$EXTENSION_CAMERA_USAGE_DESCRIPTION"
  set_info_plist_key "$extension_path" "NSSystemExtensionUsageDescription" "$EXTENSION_SYSTEM_EXTENSION_USAGE_DESCRIPTION"
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

MISSING_APP_PRODUCTS="$TMP_DIR/missing-app/Products"
mkdir -p "$MISSING_APP_PRODUCTS/Debug"

if PRODUCTS_PATH="$MISSING_APP_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-app.out" 2>"$TMP_DIR/missing-app.err"; then
  printf 'Expected verifier to reject a missing app product.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app product" "$TMP_DIR/missing-app.err"; then
  printf 'Verifier failure did not explain the missing app product.\n' >&2
  cat "$TMP_DIR/missing-app.err" >&2
  exit 1
fi

MISSING_EMBEDDED_EXTENSION_PRODUCTS="$TMP_DIR/missing-embedded-extension/Products"
write_product_fixture "$MISSING_EMBEDDED_EXTENSION_PRODUCTS" Debug
rm -rf "$MISSING_EMBEDDED_EXTENSION_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME"

if PRODUCTS_PATH="$MISSING_EMBEDDED_EXTENSION_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-embedded-extension.out" 2>"$TMP_DIR/missing-embedded-extension.err"; then
  printf 'Expected verifier to reject a missing embedded system extension.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug embedded system extension" "$TMP_DIR/missing-embedded-extension.err"; then
  printf 'Verifier failure did not explain the missing embedded system extension.\n' >&2
  cat "$TMP_DIR/missing-embedded-extension.err" >&2
  exit 1
fi

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

MISSING_DIAGNOSTICS_PARSER_PRODUCTS="$TMP_DIR/missing-diagnostics-parser/Products"
write_product_fixture "$MISSING_DIAGNOSTICS_PARSER_PRODUCTS" Debug
rm "$MISSING_DIAGNOSTICS_PARSER_PRODUCTS/Debug/GarethVideoCam.app/Contents/Resources/validate_project.py"

if PRODUCTS_PATH="$MISSING_DIAGNOSTICS_PARSER_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-diagnostics-parser.out" 2>"$TMP_DIR/missing-diagnostics-parser.err"; then
  printf 'Expected verifier to reject a missing runtime diagnostics parser.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app runtime diagnostics parser" "$TMP_DIR/missing-diagnostics-parser.err"; then
  printf 'Verifier failure did not explain the missing runtime diagnostics parser.\n' >&2
  cat "$TMP_DIR/missing-diagnostics-parser.err" >&2
  exit 1
fi

STALE_TEAM_ID_DIAGNOSTICS_PRODUCTS="$TMP_DIR/stale-team-id-diagnostics/Products"
write_product_fixture "$STALE_TEAM_ID_DIAGNOSTICS_PRODUCTS" Debug
write_stale_team_id_diagnostics_fixture "$STALE_TEAM_ID_DIAGNOSTICS_PRODUCTS" Debug

if PRODUCTS_PATH="$STALE_TEAM_ID_DIAGNOSTICS_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/stale-team-id-diagnostics.out" 2>"$TMP_DIR/stale-team-id-diagnostics.err"; then
  printf 'Expected verifier to reject stale bundled runtime diagnostics Team ID self-test output.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app bundled runtime diagnostics Team ID self-test output" "$TMP_DIR/stale-team-id-diagnostics.err"; then
  printf 'Verifier failure did not explain the stale bundled runtime diagnostics Team ID self-test output.\n' >&2
  cat "$TMP_DIR/stale-team-id-diagnostics.err" >&2
  exit 1
fi

STALE_APPLICATION_IDENTITY_DIAGNOSTICS_PRODUCTS="$TMP_DIR/stale-application-identity-diagnostics/Products"
write_product_fixture "$STALE_APPLICATION_IDENTITY_DIAGNOSTICS_PRODUCTS" Debug
write_stale_application_identity_diagnostics_fixture "$STALE_APPLICATION_IDENTITY_DIAGNOSTICS_PRODUCTS" Debug

if PRODUCTS_PATH="$STALE_APPLICATION_IDENTITY_DIAGNOSTICS_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/stale-application-identity-diagnostics.out" 2>"$TMP_DIR/stale-application-identity-diagnostics.err"; then
  printf 'Expected verifier to reject stale bundled runtime diagnostics application-identity self-test output.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app bundled runtime diagnostics application-identity self-test output" "$TMP_DIR/stale-application-identity-diagnostics.err"; then
  printf 'Verifier failure did not explain the stale bundled runtime diagnostics application-identity self-test output.\n' >&2
  cat "$TMP_DIR/stale-application-identity-diagnostics.err" >&2
  exit 1
fi

STALE_VIDEO_METADATA_DIAGNOSTICS_PRODUCTS="$TMP_DIR/stale-video-metadata-diagnostics/Products"
write_product_fixture "$STALE_VIDEO_METADATA_DIAGNOSTICS_PRODUCTS" Debug
write_stale_video_metadata_diagnostics_fixture "$STALE_VIDEO_METADATA_DIAGNOSTICS_PRODUCTS" Debug

if PRODUCTS_PATH="$STALE_VIDEO_METADATA_DIAGNOSTICS_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/stale-video-metadata-diagnostics.out" 2>"$TMP_DIR/stale-video-metadata-diagnostics.err"; then
  printf 'Expected verifier to reject stale bundled runtime diagnostics video-metadata self-test output.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app bundled runtime diagnostics video-metadata self-test output" "$TMP_DIR/stale-video-metadata-diagnostics.err"; then
  printf 'Verifier failure did not explain the stale bundled runtime diagnostics video-metadata self-test output.\n' >&2
  cat "$TMP_DIR/stale-video-metadata-diagnostics.err" >&2
  exit 1
fi

STALE_APPLICATION_GROUP_DIAGNOSTICS_PRODUCTS="$TMP_DIR/stale-application-group-diagnostics/Products"
write_product_fixture "$STALE_APPLICATION_GROUP_DIAGNOSTICS_PRODUCTS" Debug
write_stale_application_group_diagnostics_fixture "$STALE_APPLICATION_GROUP_DIAGNOSTICS_PRODUCTS" Debug

if PRODUCTS_PATH="$STALE_APPLICATION_GROUP_DIAGNOSTICS_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/stale-application-group-diagnostics.out" 2>"$TMP_DIR/stale-application-group-diagnostics.err"; then
  printf 'Expected verifier to reject stale bundled runtime diagnostics application-group self-test output.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app bundled runtime diagnostics application-group self-test output" "$TMP_DIR/stale-application-group-diagnostics.err"; then
  printf 'Verifier failure did not explain the stale bundled runtime diagnostics application-group self-test output.\n' >&2
  cat "$TMP_DIR/stale-application-group-diagnostics.err" >&2
  exit 1
fi

STALE_MACH_SERVICE_DIAGNOSTICS_PRODUCTS="$TMP_DIR/stale-mach-service-diagnostics/Products"
write_product_fixture "$STALE_MACH_SERVICE_DIAGNOSTICS_PRODUCTS" Debug
write_stale_mach_service_diagnostics_fixture "$STALE_MACH_SERVICE_DIAGNOSTICS_PRODUCTS" Debug

if PRODUCTS_PATH="$STALE_MACH_SERVICE_DIAGNOSTICS_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/stale-mach-service-diagnostics.out" 2>"$TMP_DIR/stale-mach-service-diagnostics.err"; then
  printf 'Expected verifier to reject stale bundled runtime diagnostics mach-service self-test output.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app bundled runtime diagnostics mach-service self-test output" "$TMP_DIR/stale-mach-service-diagnostics.err"; then
  printf 'Verifier failure did not explain the stale bundled runtime diagnostics mach-service self-test output.\n' >&2
  cat "$TMP_DIR/stale-mach-service-diagnostics.err" >&2
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

NON_EXECUTABLE_EXTENSION_PRODUCTS="$TMP_DIR/non-executable-extension/Products"
write_product_fixture "$NON_EXECUTABLE_EXTENSION_PRODUCTS" Debug
chmod 0644 "$NON_EXECUTABLE_EXTENSION_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME/Contents/MacOS/$EXTENSION_ID"

if PRODUCTS_PATH="$NON_EXECUTABLE_EXTENSION_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/non-executable-extension.out" 2>"$TMP_DIR/non-executable-extension.err"; then
  printf 'Expected verifier to reject a non-executable extension binary.\n' >&2
  exit 1
fi

if ! grep -q "Missing or non-executable Debug extension executable" "$TMP_DIR/non-executable-extension.err"; then
  printf 'Verifier failure did not explain the non-executable extension binary.\n' >&2
  cat "$TMP_DIR/non-executable-extension.err" >&2
  exit 1
fi

MISSING_EXTENSION_EXECUTABLE_KEY_PRODUCTS="$TMP_DIR/missing-extension-executable-key/Products"
write_product_fixture "$MISSING_EXTENSION_EXECUTABLE_KEY_PRODUCTS" Debug
remove_info_plist_key "$MISSING_EXTENSION_EXECUTABLE_KEY_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "CFBundleExecutable"

if PRODUCTS_PATH="$MISSING_EXTENSION_EXECUTABLE_KEY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-extension-executable-key.out" 2>"$TMP_DIR/missing-extension-executable-key.err"; then
  printf 'Expected verifier to reject a missing extension executable declaration.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension CFBundleExecutable" "$TMP_DIR/missing-extension-executable-key.err"; then
  printf 'Verifier failure did not explain the missing extension executable declaration.\n' >&2
  cat "$TMP_DIR/missing-extension-executable-key.err" >&2
  exit 1
fi

MISSING_APP_EXECUTABLE_PRODUCTS="$TMP_DIR/missing-app-executable/Products"
write_product_fixture "$MISSING_APP_EXECUTABLE_PRODUCTS" Debug
rm "$MISSING_APP_EXECUTABLE_PRODUCTS/Debug/GarethVideoCam.app/Contents/MacOS/GarethVideoCam"

if PRODUCTS_PATH="$MISSING_APP_EXECUTABLE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-app-executable.out" 2>"$TMP_DIR/missing-app-executable.err"; then
  printf 'Expected verifier to reject a missing app executable.\n' >&2
  exit 1
fi

if ! grep -q "Missing or non-executable Debug app executable" "$TMP_DIR/missing-app-executable.err"; then
  printf 'Verifier failure did not explain the missing app executable.\n' >&2
  cat "$TMP_DIR/missing-app-executable.err" >&2
  exit 1
fi

NON_EXECUTABLE_APP_PRODUCTS="$TMP_DIR/non-executable-app/Products"
write_product_fixture "$NON_EXECUTABLE_APP_PRODUCTS" Debug
chmod 0644 "$NON_EXECUTABLE_APP_PRODUCTS/Debug/GarethVideoCam.app/Contents/MacOS/GarethVideoCam"

if PRODUCTS_PATH="$NON_EXECUTABLE_APP_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/non-executable-app.out" 2>"$TMP_DIR/non-executable-app.err"; then
  printf 'Expected verifier to reject a non-executable app binary.\n' >&2
  exit 1
fi

if ! grep -q "Missing or non-executable Debug app executable" "$TMP_DIR/non-executable-app.err"; then
  printf 'Verifier failure did not explain the non-executable app binary.\n' >&2
  cat "$TMP_DIR/non-executable-app.err" >&2
  exit 1
fi

MISSING_APP_EXECUTABLE_KEY_PRODUCTS="$TMP_DIR/missing-app-executable-key/Products"
write_product_fixture "$MISSING_APP_EXECUTABLE_KEY_PRODUCTS" Debug
remove_info_plist_key "$MISSING_APP_EXECUTABLE_KEY_PRODUCTS/Debug/GarethVideoCam.app" "CFBundleExecutable"

if PRODUCTS_PATH="$MISSING_APP_EXECUTABLE_KEY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-app-executable-key.out" 2>"$TMP_DIR/missing-app-executable-key.err"; then
  printf 'Expected verifier to reject a missing app executable declaration.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app CFBundleExecutable" "$TMP_DIR/missing-app-executable-key.err"; then
  printf 'Verifier failure did not explain the missing app executable declaration.\n' >&2
  cat "$TMP_DIR/missing-app-executable-key.err" >&2
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

MISSING_EXTENSION_USAGE_PRODUCTS="$TMP_DIR/missing-extension-usage/Products"
write_product_fixture "$MISSING_EXTENSION_USAGE_PRODUCTS" Debug
remove_info_plist_key "$MISSING_EXTENSION_USAGE_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "NSSystemExtensionUsageDescription"

if PRODUCTS_PATH="$MISSING_EXTENSION_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-extension-usage.out" 2>"$TMP_DIR/missing-extension-usage.err"; then
  printf 'Expected verifier to reject a missing extension usage description.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension NSSystemExtensionUsageDescription" "$TMP_DIR/missing-extension-usage.err"; then
  printf 'Verifier failure did not explain the missing extension usage description.\n' >&2
  cat "$TMP_DIR/missing-extension-usage.err" >&2
  exit 1
fi

MISSING_APP_CAMERA_USAGE_PRODUCTS="$TMP_DIR/missing-app-camera-usage/Products"
write_product_fixture "$MISSING_APP_CAMERA_USAGE_PRODUCTS" Debug
remove_info_plist_key "$MISSING_APP_CAMERA_USAGE_PRODUCTS/Debug/GarethVideoCam.app" "NSCameraUsageDescription"

if PRODUCTS_PATH="$MISSING_APP_CAMERA_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-app-camera-usage.out" 2>"$TMP_DIR/missing-app-camera-usage.err"; then
  printf 'Expected verifier to reject a missing app camera usage description.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app NSCameraUsageDescription" "$TMP_DIR/missing-app-camera-usage.err"; then
  printf 'Verifier failure did not explain the missing app camera usage description.\n' >&2
  cat "$TMP_DIR/missing-app-camera-usage.err" >&2
  exit 1
fi

MISSING_EXTENSION_CAMERA_USAGE_PRODUCTS="$TMP_DIR/missing-extension-camera-usage/Products"
write_product_fixture "$MISSING_EXTENSION_CAMERA_USAGE_PRODUCTS" Debug
remove_info_plist_key "$MISSING_EXTENSION_CAMERA_USAGE_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "NSCameraUsageDescription"

if PRODUCTS_PATH="$MISSING_EXTENSION_CAMERA_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-extension-camera-usage.out" 2>"$TMP_DIR/missing-extension-camera-usage.err"; then
  printf 'Expected verifier to reject a missing extension camera usage description.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension NSCameraUsageDescription" "$TMP_DIR/missing-extension-camera-usage.err"; then
  printf 'Verifier failure did not explain the missing extension camera usage description.\n' >&2
  cat "$TMP_DIR/missing-extension-camera-usage.err" >&2
  exit 1
fi

WRONG_APP_SYSTEM_EXTENSION_USAGE_PRODUCTS="$TMP_DIR/wrong-app-system-extension-usage/Products"
write_product_fixture "$WRONG_APP_SYSTEM_EXTENSION_USAGE_PRODUCTS" Debug
set_info_plist_key "$WRONG_APP_SYSTEM_EXTENSION_USAGE_PRODUCTS/Debug/GarethVideoCam.app" "NSSystemExtensionUsageDescription" "System extension usage fixture"

if PRODUCTS_PATH="$WRONG_APP_SYSTEM_EXTENSION_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-app-system-extension-usage.out" 2>"$TMP_DIR/wrong-app-system-extension-usage.err"; then
  printf 'Expected verifier to reject a wrong app system extension usage description.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app NSSystemExtensionUsageDescription" "$TMP_DIR/wrong-app-system-extension-usage.err"; then
  printf 'Verifier failure did not explain the wrong app system extension usage description.\n' >&2
  cat "$TMP_DIR/wrong-app-system-extension-usage.err" >&2
  exit 1
fi

WRONG_EXTENSION_SYSTEM_EXTENSION_USAGE_PRODUCTS="$TMP_DIR/wrong-extension-system-extension-usage/Products"
write_product_fixture "$WRONG_EXTENSION_SYSTEM_EXTENSION_USAGE_PRODUCTS" Debug
set_info_plist_key "$WRONG_EXTENSION_SYSTEM_EXTENSION_USAGE_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "NSSystemExtensionUsageDescription" "System extension usage fixture"

if PRODUCTS_PATH="$WRONG_EXTENSION_SYSTEM_EXTENSION_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-extension-system-extension-usage.out" 2>"$TMP_DIR/wrong-extension-system-extension-usage.err"; then
  printf 'Expected verifier to reject a wrong extension system extension usage description.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug extension NSSystemExtensionUsageDescription" "$TMP_DIR/wrong-extension-system-extension-usage.err"; then
  printf 'Verifier failure did not explain the wrong extension system extension usage description.\n' >&2
  cat "$TMP_DIR/wrong-extension-system-extension-usage.err" >&2
  exit 1
fi

WRONG_APP_USAGE_PRODUCTS="$TMP_DIR/wrong-app-usage/Products"
write_product_fixture "$WRONG_APP_USAGE_PRODUCTS" Debug
set_info_plist_key "$WRONG_APP_USAGE_PRODUCTS/Debug/GarethVideoCam.app" "NSCameraUsageDescription" "Camera usage fixture"

if PRODUCTS_PATH="$WRONG_APP_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-app-usage.out" 2>"$TMP_DIR/wrong-app-usage.err"; then
  printf 'Expected verifier to reject a wrong app camera usage description.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug app NSCameraUsageDescription" "$TMP_DIR/wrong-app-usage.err"; then
  printf 'Verifier failure did not explain the wrong app camera usage description.\n' >&2
  cat "$TMP_DIR/wrong-app-usage.err" >&2
  exit 1
fi

MISSING_APP_DISPLAY_PRODUCTS="$TMP_DIR/missing-app-display/Products"
write_product_fixture "$MISSING_APP_DISPLAY_PRODUCTS" Debug
remove_info_plist_key "$MISSING_APP_DISPLAY_PRODUCTS/Debug/GarethVideoCam.app" "CFBundleDisplayName"

if PRODUCTS_PATH="$MISSING_APP_DISPLAY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-app-display.out" 2>"$TMP_DIR/missing-app-display.err"; then
  printf 'Expected verifier to reject a missing app display name.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app CFBundleDisplayName" "$TMP_DIR/missing-app-display.err"; then
  printf 'Verifier failure did not explain the missing app display name.\n' >&2
  cat "$TMP_DIR/missing-app-display.err" >&2
  exit 1
fi

MISSING_EXTENSION_DISPLAY_PRODUCTS="$TMP_DIR/missing-extension-display/Products"
write_product_fixture "$MISSING_EXTENSION_DISPLAY_PRODUCTS" Debug
remove_info_plist_key "$MISSING_EXTENSION_DISPLAY_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "CFBundleDisplayName"

if PRODUCTS_PATH="$MISSING_EXTENSION_DISPLAY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/missing-extension-display.out" 2>"$TMP_DIR/missing-extension-display.err"; then
  printf 'Expected verifier to reject a missing extension display name.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension CFBundleDisplayName" "$TMP_DIR/missing-extension-display.err"; then
  printf 'Verifier failure did not explain the missing extension display name.\n' >&2
  cat "$TMP_DIR/missing-extension-display.err" >&2
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

WRONG_EXTENSION_DISPLAY_PRODUCTS="$TMP_DIR/wrong-extension-display/Products"
write_product_fixture "$WRONG_EXTENSION_DISPLAY_PRODUCTS" Debug
set_info_plist_key "$WRONG_EXTENSION_DISPLAY_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "CFBundleDisplayName" "GarethVideoCamExtension"

if PRODUCTS_PATH="$WRONG_EXTENSION_DISPLAY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-extension-display.out" 2>"$TMP_DIR/wrong-extension-display.err"; then
  printf 'Expected verifier to reject a wrong extension display name.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug extension CFBundleDisplayName" "$TMP_DIR/wrong-extension-display.err"; then
  printf 'Verifier failure did not explain the wrong extension display name.\n' >&2
  cat "$TMP_DIR/wrong-extension-display.err" >&2
  exit 1
fi

WRONG_EXTENSION_USAGE_PRODUCTS="$TMP_DIR/wrong-extension-usage/Products"
write_product_fixture "$WRONG_EXTENSION_USAGE_PRODUCTS" Debug
set_info_plist_key "$WRONG_EXTENSION_USAGE_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" "NSCameraUsageDescription" "Camera usage fixture"

if PRODUCTS_PATH="$WRONG_EXTENSION_USAGE_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/wrong-extension-usage.out" 2>"$TMP_DIR/wrong-extension-usage.err"; then
  printf 'Expected verifier to reject a wrong extension camera usage description.\n' >&2
  exit 1
fi

if ! grep -q "Unexpected Debug extension NSCameraUsageDescription" "$TMP_DIR/wrong-extension-usage.err"; then
  printf 'Verifier failure did not explain the wrong extension camera usage description.\n' >&2
  cat "$TMP_DIR/wrong-extension-usage.err" >&2
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
