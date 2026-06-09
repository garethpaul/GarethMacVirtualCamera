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

set_info_plist_boolean_key() {
  local bundle_path="$1"
  local key="$2"
  local value="$3"

  python3 - "$bundle_path/Contents/Info.plist" "$key" "$value" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    info = plistlib.load(info_file)

info[sys.argv[2]] = sys.argv[3] == "true"

with open(sys.argv[1], "wb") as info_file:
    plistlib.dump(info, info_file)
PY
}

set_extension_mach_service_boolean() {
  local bundle_path="$1"
  local value="$2"

  python3 - "$bundle_path/Contents/Info.plist" "$value" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    info = plistlib.load(info_file)

info.setdefault("CMIOExtension", {})["CMIOExtensionMachServiceName"] = sys.argv[2] == "true"

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
        "Diagnostics script path:",
        "Diagnostics script directory:",
        "Diagnostics parser path:",
        "Diagnostics parser source: adjacent script resource",
        "Diagnostics parser available: yes",
    ],
    "readiness-rollup": [
        "Ready fixture: yes",
        "Blocked fixture: no",
        "Unknown fixture: unknown",
        "Runtime readiness result: blocked",
        "Runtime readiness checks ready: 1/3",
        "Runtime readiness checks blocked: 1",
        "Runtime readiness checks unknown: 1",
        "Runtime readiness next action: resolve Blocked fixture",
    ],
    "readiness-rollup-unknown": [
        "Ready fixture: yes",
        "Unknown fixture: unknown",
        "Runtime readiness result: incomplete",
        "Runtime readiness checks ready: 1/2",
        "Runtime readiness checks blocked: 0",
        "Runtime readiness checks unknown: 1",
        "Runtime readiness next action: inspect Unknown fixture",
    ],
    "readiness-rollup-ready": [
        "Ready fixture: yes",
        "Runtime readiness result: ready",
        "Runtime readiness checks ready: 1/1",
        "Runtime readiness checks blocked: 0",
        "Runtime readiness checks unknown: 0",
        "Runtime readiness next action: submit the system extension request",
    ],
    "missing-runtime-bundles": [
        "Application location ready: no",
        "App bundle identifier ready: no",
        "App signature ready: no",
        "App System Extension entitlement ready: no",
        "App executable ready: no",
        "Extension bundle identifier ready: no",
        "Extension signature ready: no",
        "Extension host-only entitlement absent: no",
        "Extension executable ready: no",
        "Extension CMIO Mach service ready: no",
        "Bundle versions match ready: no",
        "Signing Team match ready: no",
        "Application group match ready: no",
        "Bundled video ready: no",
        "Bundled video metadata ready: no",
        "Runtime readiness result: blocked",
        "Runtime readiness checks ready: 0/15",
        "Runtime readiness checks blocked: 15",
        "Runtime readiness checks unknown: 0",
        "Runtime readiness next action: resolve Application location ready",
    ],
    "bundle-version-match": [
        "Bundle version match fixture: yes",
        "Bundle version short mismatch fixture: no",
        "Bundle version build mismatch fixture: no",
        "Bundle version missing fixture: no",
    ],
    "executable-readiness": [
        "Executable missing name fixture: no",
        "Executable missing file fixture: no",
        "Executable ready fixture: yes",
        "Executable non-executable fixture: no",
    ],
    "team-id": [
        "Team ID match fixture: yes",
        "Team ID mismatch fixture: no",
        "Team ID missing app fixture: no",
        "Team ID missing extension fixture: no",
        "Team ID short fixture: no",
        "Team ID dotted fixture: no",
        "Team ID multiple app fixture: no",
        "Team ID multiple extension fixture: no",
    ],
    "extension-host-entitlement": [
        "Boolean entitlement all architectures present fixture: yes",
        "Boolean entitlement missing architecture fixture: no",
        "Boolean entitlement unreadable architecture fixture: unknown",
        "Boolean entitlement empty architecture fixture: unknown",
        "Boolean entitlement malformed plist fixture: unknown",
        "Boolean entitlement scalar fixture: unknown",
        "Boolean entitlement fallback scalar fixture: unknown",
        "Extension host entitlement valid absent fixture: yes",
        "Extension host entitlement valid present fixture: no",
        "Extension host entitlement invalid signature fixture: no",
        "Extension host entitlement unreadable fixture: no",
    ],
    "application-identity": [
        "App path match fixture: yes",
        "App path mismatch fixture: no",
        "Application location existing fixture: yes",
        "Application location missing fixture: no",
        "Application location mismatch fixture: no",
        "Bundle identifier match fixture: yes",
        "Bundle identifier mismatch fixture: no",
        "Bundle identifier missing fixture: no",
        "Info.plist string metadata fixture: com.example.StringMetadata",
        "Info.plist scalar metadata fixture: missing",
        "Info.plist blank string metadata fixture: missing",
        "Info.plist nested string metadata fixture: com.example.StringMetadata.Extension",
        "Info.plist nested scalar metadata fixture: missing",
        "Info.plist nested blank string metadata fixture: missing",
    ],
    "video-metadata": [
        "Video metadata parsed width fixture: 1280",
        "Video metadata parsed height fixture: 720",
        "Video metadata parsed duration fixture: 12.5",
        "Video metadata spaced width fixture: 1280",
        "Video metadata quoted duration fixture: 12.5",
        "Video metadata preferred parser fixture: 1280",
        "Video metadata blank fallback fixture: 640",
        "Video metadata null fallback fixture: 640",
        "Video metadata parenthesized null fallback fixture: 640",
        "Video metadata ready fixture: yes",
        "Video metadata decimal fixture: yes",
        "Video metadata non-numeric width fixture: no",
        "Video metadata wrong width fixture: no",
        "Video metadata wrong frame rate fixture: no",
        "Video metadata missing frame rate fixture: unknown",
        "Video metadata missing duration fixture: unknown",
        "Video metadata zero duration fixture: no",
        "Video metadata negative duration fixture: no",
    ],
    "file-byte-count": [
        "File byte count fixture: 5",
    ],
    "application-group": [
        "Application group direct fixture ready: no",
        "Application group shared fixture ready: yes",
        "Application group missing fixture ready: no",
        "Application group mismatched fixture ready: no",
        "Application group short-prefix fixture ready: no",
        "Application group wrong suffix fixture ready: no",
        "Application group dotted-prefix fixture ready: no",
        "Application group unresolved fixture ready: no",
        "Application group empty format fixture: none",
        "Application group list format fixture: ABCDE12345.com.garethpaul.GarethVideoCam, ZYXWV98765.com.garethpaul.GarethVideoCam",
        "Application group all architectures common fixture: ABCDE12345.com.garethpaul.GarethVideoCam",
        "Application group missing architecture common fixture: none",
        "Application group malformed entitlements readable fixture: no",
        "Application group scalar entitlements readable fixture: no",
        "Application group non-string entitlements readable fixture: no",
        "Application group untrimmed entitlements readable fixture: no",
        "Application group fallback scalar entitlements readable fixture: no",
        "Application group fallback non-string entitlements readable fixture: no",
        "Application group fallback untrimmed entitlements readable fixture: no",
        "Application group fallback malformed entitlements readable fixture: no",
    ],
    "mach-service": [
        "Mach service direct fixture resolved: yes",
        "Mach service direct fixture matches expected: yes",
        "Mach service direct fixture ready: yes",
        "Mach service team-prefixed fixture ready: yes",
        "Mach service short-prefix fixture ready: no",
        "Mach service dotted-prefix fixture ready: no",
        "Mach service unresolved fixture resolved: no",
        "Mach service wrong fixture matches expected: no",
        "Mach service missing fixture ready: no",
    ],
    "camera-device": [
        "Camera device present fixture: yes",
        "Camera device missing fixture: no",
        "Camera device substring fixture: no",
        "Camera device empty fixture: unknown",
    ],
    "registration": [
        "Registration active fixture present: yes",
        "Registration active fixture activated enabled: yes",
        "Registration reversed fixture activated enabled: yes",
        "Registration waiting fixture activated enabled: no",
        "Registration deactivated fixture activated enabled: no",
        "Registration longer identifier fixture present: no",
        "Registration longer identifier fixture activated enabled: no",
        "Registration missing fixture present: no",
        "Registration empty fixture present: unknown",
    ],
    "activation-evidence": [
        "Runtime activation evidence result: active",
        "Runtime activation evidence checks ready: 3/3",
        "Runtime activation evidence next action: open a camera picker and confirm Gareth Video Cam is selectable",
        "Runtime activation evidence result: blocked",
        "Runtime activation evidence next action: resolve Extension registration entry present",
        "Runtime activation evidence result: incomplete",
        "Runtime activation evidence checks ready: 0/3",
        "Runtime activation evidence checks unknown: 3",
        "Runtime activation evidence next action: inspect Extension registration activated enabled",
        "Runtime activation evidence next action: inspect Extension registration entry present",
    ],
    "video-parser": [
        "Video parser pixel width fixture: 1280",
        "Video parser pixel height fixture: 720",
        "Video parser frame rate fixture: 24",
        "Video parser duration fixture: 3.0833333333333335",
        "Video parser metadata ready fixture: yes",
    ],
}

stale_outputs = {
    "resource-discovery": [
        "Diagnostics parser source: repository fallback",
        "Diagnostics parser available: no",
    ],
    "readiness-rollup": [
        "Ready fixture: no",
        "Blocked fixture: yes",
        "Unknown fixture: yes",
        "Runtime readiness result: ready",
        "Runtime readiness checks ready: 3/3",
        "Runtime readiness checks blocked: 0",
        "Runtime readiness checks unknown: 0",
        "Runtime readiness next action: none",
    ],
    "missing-runtime-bundles": [
        "Application location ready: yes",
        "App bundle identifier ready: unknown",
        "App signature ready: unknown",
        "App System Extension entitlement ready: yes",
        "App executable ready: yes",
        "Extension bundle identifier ready: unknown",
        "Extension signature ready: unknown",
        "Extension host-only entitlement absent: yes",
        "Extension executable ready: yes",
        "Extension CMIO Mach service ready: yes",
        "Bundle versions match ready: unknown",
        "Signing Team match ready: unknown",
        "Application group match ready: unknown",
        "Bundled video ready: yes",
        "Bundled video metadata ready: yes",
        "Runtime readiness result: ready",
        "Runtime readiness checks ready: 1/15",
        "Runtime readiness checks blocked: 0",
        "Runtime readiness checks unknown: 12",
        "Runtime readiness next action: inspect App bundle identifier ready",
    ],
    "executable-readiness": [
        "Executable missing name fixture: yes",
        "Executable missing file fixture: yes",
        "Executable ready fixture: no",
        "Executable non-executable fixture: yes",
    ],
    "bundle-version-match": [
        "Bundle version match fixture: no",
        "Bundle version short mismatch fixture: yes",
        "Bundle version build mismatch fixture: yes",
        "Bundle version missing fixture: yes",
    ],
    "team-id": [
        "Team ID match fixture: no",
        "Team ID mismatch fixture: no",
        "Team ID missing app fixture: unknown",
        "Team ID missing extension fixture: unknown",
        "Team ID short fixture: yes",
        "Team ID dotted fixture: yes",
        "Team ID multiple app fixture: yes",
        "Team ID multiple extension fixture: yes",
    ],
    "extension-host-entitlement": [
        "Boolean entitlement all architectures present fixture: no",
        "Boolean entitlement missing architecture fixture: yes",
        "Boolean entitlement unreadable architecture fixture: no",
        "Boolean entitlement empty architecture fixture: yes",
        "Boolean entitlement malformed plist fixture: yes",
        "Boolean entitlement scalar fixture: yes",
        "Boolean entitlement fallback scalar fixture: yes",
        "Extension host entitlement valid absent fixture: yes",
        "Extension host entitlement valid present fixture: yes",
        "Extension host entitlement invalid signature fixture: yes",
        "Extension host entitlement unreadable fixture: yes",
    ],
    "application-identity": [
        "App path match fixture: no",
        "App path mismatch fixture: yes",
        "Application location existing fixture: no",
        "Application location missing fixture: yes",
        "Application location mismatch fixture: yes",
        "Bundle identifier match fixture: no",
        "Bundle identifier mismatch fixture: yes",
        "Bundle identifier missing fixture: yes",
    ],
    "video-metadata": [
        "Video metadata parsed width fixture: 640",
        "Video metadata parsed height fixture: 360",
        "Video metadata parsed duration fixture: 0",
        "Video metadata spaced width fixture: 640",
        "Video metadata quoted duration fixture: 0",
        "Video metadata preferred parser fixture: 640",
        "Video metadata blank fallback fixture: 1280",
        "Video metadata null fallback fixture: 1280",
        "Video metadata parenthesized null fallback fixture: 1280",
        "Video metadata ready fixture: no",
        "Video metadata decimal fixture: no",
        "Video metadata non-numeric width fixture: yes",
        "Video metadata wrong width fixture: yes",
        "Video metadata wrong frame rate fixture: yes",
        "Video metadata missing frame rate fixture: no",
        "Video metadata missing duration fixture: no",
        "Video metadata zero duration fixture: yes",
        "Video metadata negative duration fixture: yes",
    ],
    "file-byte-count": [
        "File byte count fixture: 4",
    ],
    "application-group": [
        "Application group direct fixture ready: no",
        "Application group shared fixture ready: no",
        "Application group missing fixture ready: yes",
        "Application group mismatched fixture ready: yes",
        "Application group short-prefix fixture ready: yes",
        "Application group wrong suffix fixture ready: yes",
        "Application group dotted-prefix fixture ready: yes",
        "Application group unresolved fixture ready: yes",
        "Application group empty format fixture: value",
        "Application group list format fixture: none",
        "Application group all architectures common fixture: none",
        "Application group missing architecture common fixture: value",
        "Application group malformed entitlements readable fixture: yes",
        "Application group scalar entitlements readable fixture: yes",
        "Application group non-string entitlements readable fixture: yes",
        "Application group untrimmed entitlements readable fixture: yes",
        "Application group fallback scalar entitlements readable fixture: yes",
        "Application group fallback non-string entitlements readable fixture: yes",
        "Application group fallback untrimmed entitlements readable fixture: yes",
        "Application group fallback malformed entitlements readable fixture: yes",
    ],
    "mach-service": [
        "Mach service direct fixture resolved: no",
        "Mach service direct fixture matches expected: no",
        "Mach service direct fixture ready: no",
        "Mach service team-prefixed fixture ready: no",
        "Mach service short-prefix fixture ready: yes",
        "Mach service dotted-prefix fixture ready: yes",
        "Mach service unresolved fixture resolved: yes",
        "Mach service wrong fixture matches expected: yes",
        "Mach service missing fixture ready: yes",
    ],
    "camera-device": [
        "Camera device present fixture: no",
        "Camera device missing fixture: yes",
        "Camera device substring fixture: yes",
        "Camera device empty fixture: yes",
    ],
    "registration": [
        "Registration active fixture present: no",
        "Registration active fixture activated enabled: no",
        "Registration reversed fixture activated enabled: no",
        "Registration waiting fixture activated enabled: yes",
        "Registration deactivated fixture activated enabled: yes",
        "Registration longer identifier fixture present: yes",
        "Registration longer identifier fixture activated enabled: yes",
        "Registration missing fixture present: yes",
        "Registration empty fixture present: yes",
    ],
    "activation-evidence": [
        "Runtime activation evidence result: inactive",
        "Runtime activation evidence checks ready: 1/3",
        "Runtime activation evidence next action: none",
    ],
    "video-parser": [
        "Video parser pixel width fixture: 640",
        "Video parser pixel height fixture: 360",
        "Video parser frame rate fixture: 30",
        "Video parser duration fixture: 0",
        "Video parser metadata ready fixture: no",
    ],
}

if stale_self_test not in stale_outputs:
    raise SystemExit(f"Unknown stale diagnostics fixture: {stale_self_test}")

outputs = dict(passing_outputs)
outputs[stale_self_test] = stale_outputs[stale_self_test]

def shell_single_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"

case_lines = []
for self_test, lines in outputs.items():
    case_lines.append(f"  {self_test})")
    for line in lines:
        case_lines.append(f"    printf '%s\\n' {shell_single_quote(line)}")
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

write_stale_extension_host_entitlement_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "extension-host-entitlement"
}

write_stale_resource_discovery_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "resource-discovery"
}

write_stale_readiness_rollup_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "readiness-rollup"
}

write_stale_missing_runtime_bundles_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "missing-runtime-bundles"
}

write_stale_executable_readiness_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "executable-readiness"
}

write_stale_bundle_version_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "bundle-version-match"
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

write_stale_file_byte_count_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "file-byte-count"
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

write_stale_camera_device_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "camera-device"
}

write_stale_registration_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "registration"
}

write_stale_activation_evidence_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "activation-evidence"
}

write_stale_video_parser_diagnostics_fixture() {
  local products_path="$1"
  local configuration="$2"
  write_diagnostics_fixture_script "$products_path/$configuration/GarethVideoCam.app/Contents/Resources/collect_runtime_diagnostics.sh" "video-parser"
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

assert_stale_diagnostics_rejected() {
  local fixture_name="$1"
  local fixture_writer="$2"
  local verifier_label="$3"
  local self_test_label="$4"
  local products_path="$TMP_DIR/$fixture_name/Products"

  write_product_fixture "$products_path" Debug
  "$fixture_writer" "$products_path" Debug

  if PRODUCTS_PATH="$products_path" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/$fixture_name.out" 2>"$TMP_DIR/$fixture_name.err"; then
    printf 'Expected verifier to reject stale bundled runtime diagnostics %s self-test output.\n' "$self_test_label" >&2
    exit 1
  fi

  if ! grep -q "Unexpected Debug app bundled runtime diagnostics $verifier_label self-test output" "$TMP_DIR/$fixture_name.err"; then
    printf 'Verifier failure did not explain the stale bundled runtime diagnostics %s self-test output.\n' "$self_test_label" >&2
    cat "$TMP_DIR/$fixture_name.err" >&2
    exit 1
  fi
}

GOOD_PRODUCTS="$TMP_DIR/good/Products"
for configuration in Debug Release; do
  write_product_fixture "$GOOD_PRODUCTS" "$configuration"
done

PRODUCTS_PATH="$GOOD_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" >/dev/null

BAD_PYTHON_PRODUCTS="$TMP_DIR/bad-python/Products"
write_product_fixture "$BAD_PYTHON_PRODUCTS" Debug

set +e
PYTHON3_BIN="$TMP_DIR/missing-python3" PRODUCTS_PATH="$BAD_PYTHON_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/bad-python.out" 2>"$TMP_DIR/bad-python.err"
bad_python_status=$?
set -e

if [ "$bad_python_status" -eq 0 ]; then
  printf 'Expected verifier to reject a missing configured Python interpreter.\n' >&2
  exit 1
fi

if ! grep -q "Configured PYTHON3_BIN is not executable or not found" "$TMP_DIR/bad-python.err"; then
  printf 'Verifier failure did not explain the missing configured Python interpreter.\n' >&2
  cat "$TMP_DIR/bad-python.err" >&2
  exit 1
fi

set +e
PYTHON3_BIN="$TMP_DIR/missing-python3" PRODUCTS_PATH="$GOOD_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" "../Debug" >"$TMP_DIR/invalid-configuration.out" 2>"$TMP_DIR/invalid-configuration.err"
invalid_configuration_status=$?
set -e

if [ "$invalid_configuration_status" -ne 2 ]; then
  printf 'Expected verifier to reject an invalid configuration before resolving Python, got %s.\n' "$invalid_configuration_status" >&2
  cat "$TMP_DIR/invalid-configuration.out" >&2
  cat "$TMP_DIR/invalid-configuration.err" >&2
  exit 1
fi

if ! grep -q "Invalid Xcode configuration name: ../Debug" "$TMP_DIR/invalid-configuration.err"; then
  printf 'Verifier failure did not explain the invalid configuration name.\n' >&2
  cat "$TMP_DIR/invalid-configuration.err" >&2
  exit 1
fi

set +e
PYTHON3_BIN="$TMP_DIR/missing-python3" PRODUCTS_PATH="$GOOD_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" ".." >"$TMP_DIR/dot-segment-configuration.out" 2>"$TMP_DIR/dot-segment-configuration.err"
dot_segment_configuration_status=$?
set -e

if [ "$dot_segment_configuration_status" -ne 2 ]; then
  printf 'Expected verifier to reject a dot-segment configuration before resolving Python, got %s.\n' "$dot_segment_configuration_status" >&2
  cat "$TMP_DIR/dot-segment-configuration.out" >&2
  cat "$TMP_DIR/dot-segment-configuration.err" >&2
  exit 1
fi

if ! grep -q "Invalid Xcode configuration name: .." "$TMP_DIR/dot-segment-configuration.err"; then
  printf 'Verifier failure did not explain the dot-segment configuration name.\n' >&2
  cat "$TMP_DIR/dot-segment-configuration.err" >&2
  exit 1
fi

set +e
PYTHON3_BIN="$TMP_DIR/missing-python3" \
  PRODUCTS_PATH="$GOOD_PRODUCTS" \
  EXPECTED_VIDEO_WIDTH="wide" \
  "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/invalid-expected-video.out" 2>"$TMP_DIR/invalid-expected-video.err"
invalid_expected_video_status=$?
set -e

if [ "$invalid_expected_video_status" -ne 2 ]; then
  printf 'Expected verifier to reject invalid expected video metadata before resolving Python, got %s.\n' "$invalid_expected_video_status" >&2
  cat "$TMP_DIR/invalid-expected-video.out" >&2
  cat "$TMP_DIR/invalid-expected-video.err" >&2
  exit 1
fi

if ! grep -q "Invalid expected video width: wide" "$TMP_DIR/invalid-expected-video.err"; then
  printf 'Verifier failure did not explain the invalid expected video metadata.\n' >&2
  cat "$TMP_DIR/invalid-expected-video.err" >&2
  exit 1
fi

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

assert_stale_diagnostics_rejected "stale-resource-discovery-diagnostics" write_stale_resource_discovery_diagnostics_fixture "resource" "resource-discovery"
assert_stale_diagnostics_rejected "stale-readiness-rollup-diagnostics" write_stale_readiness_rollup_diagnostics_fixture "readiness-rollup" "readiness-rollup"
assert_stale_diagnostics_rejected "stale-missing-runtime-bundles-diagnostics" write_stale_missing_runtime_bundles_diagnostics_fixture "missing-runtime-bundles" "missing-runtime-bundles"
assert_stale_diagnostics_rejected "stale-bundle-version-diagnostics" write_stale_bundle_version_diagnostics_fixture "bundle-version" "bundle-version-match"
assert_stale_diagnostics_rejected "stale-executable-readiness-diagnostics" write_stale_executable_readiness_diagnostics_fixture "executable-readiness" "executable-readiness"
assert_stale_diagnostics_rejected "stale-team-id-diagnostics" write_stale_team_id_diagnostics_fixture "Team ID" "Team ID"
assert_stale_diagnostics_rejected "stale-extension-host-entitlement-diagnostics" write_stale_extension_host_entitlement_diagnostics_fixture "extension-host-entitlement" "extension-host-entitlement"
assert_stale_diagnostics_rejected "stale-application-identity-diagnostics" write_stale_application_identity_diagnostics_fixture "application-identity" "application-identity"
assert_stale_diagnostics_rejected "stale-video-metadata-diagnostics" write_stale_video_metadata_diagnostics_fixture "video-metadata" "video-metadata"
assert_stale_diagnostics_rejected "stale-file-byte-count-diagnostics" write_stale_file_byte_count_diagnostics_fixture "file-byte-count" "file-byte-count"
assert_stale_diagnostics_rejected "stale-application-group-diagnostics" write_stale_application_group_diagnostics_fixture "application-group" "application-group"
assert_stale_diagnostics_rejected "stale-mach-service-diagnostics" write_stale_mach_service_diagnostics_fixture "mach-service" "mach-service"
assert_stale_diagnostics_rejected "stale-camera-device-diagnostics" write_stale_camera_device_diagnostics_fixture "camera-device" "camera-device"
assert_stale_diagnostics_rejected "stale-registration-diagnostics" write_stale_registration_diagnostics_fixture "registration" "registration"
assert_stale_diagnostics_rejected "stale-activation-evidence-diagnostics" write_stale_activation_evidence_diagnostics_fixture "activation-evidence" "activation-evidence"
assert_stale_diagnostics_rejected "stale-video-parser-diagnostics" write_stale_video_parser_diagnostics_fixture "parser" "video-parser"

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

NON_STRING_DISPLAY_PRODUCTS="$TMP_DIR/non-string-display/Products"
write_product_fixture "$NON_STRING_DISPLAY_PRODUCTS" Debug
set_info_plist_boolean_key "$NON_STRING_DISPLAY_PRODUCTS/Debug/GarethVideoCam.app" "CFBundleDisplayName" true

if PRODUCTS_PATH="$NON_STRING_DISPLAY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/non-string-display.out" 2>"$TMP_DIR/non-string-display.err"; then
  printf 'Expected verifier to reject a non-string app display name.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app CFBundleDisplayName" "$TMP_DIR/non-string-display.err"; then
  printf 'Verifier failure did not explain the non-string app display name.\n' >&2
  cat "$TMP_DIR/non-string-display.err" >&2
  exit 1
fi

BLANK_DISPLAY_PRODUCTS="$TMP_DIR/blank-display/Products"
write_product_fixture "$BLANK_DISPLAY_PRODUCTS" Debug
set_info_plist_key "$BLANK_DISPLAY_PRODUCTS/Debug/GarethVideoCam.app" "CFBundleDisplayName" "   "

if PRODUCTS_PATH="$BLANK_DISPLAY_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/blank-display.out" 2>"$TMP_DIR/blank-display.err"; then
  printf 'Expected verifier to reject a blank app display name.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug app CFBundleDisplayName" "$TMP_DIR/blank-display.err"; then
  printf 'Verifier failure did not explain the blank app display name.\n' >&2
  cat "$TMP_DIR/blank-display.err" >&2
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

BLANK_CMIO_PRODUCTS="$TMP_DIR/blank-cmio/Products"
write_product_fixture "$BLANK_CMIO_PRODUCTS" Debug "$EXTENSION_ID" "   "

if PRODUCTS_PATH="$BLANK_CMIO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/blank-cmio.out" 2>"$TMP_DIR/blank-cmio.err"; then
  printf 'Expected verifier to reject blank CMIO extension metadata.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension CMIOExtensionMachServiceName" "$TMP_DIR/blank-cmio.err"; then
  printf 'Verifier failure did not explain the blank CMIO extension metadata.\n' >&2
  cat "$TMP_DIR/blank-cmio.err" >&2
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

NON_STRING_CMIO_PRODUCTS="$TMP_DIR/non-string-cmio/Products"
write_product_fixture "$NON_STRING_CMIO_PRODUCTS" Debug
set_extension_mach_service_boolean "$NON_STRING_CMIO_PRODUCTS/Debug/GarethVideoCam.app/Contents/Library/SystemExtensions/$EXTENSION_NAME" true

if PRODUCTS_PATH="$NON_STRING_CMIO_PRODUCTS" "$ROOT/scripts/verify_build_products.sh" Debug >"$TMP_DIR/non-string-cmio.out" 2>"$TMP_DIR/non-string-cmio.err"; then
  printf 'Expected verifier to reject non-string CMIO extension metadata.\n' >&2
  exit 1
fi

if ! grep -q "Missing Debug extension CMIOExtensionMachServiceName" "$TMP_DIR/non-string-cmio.err"; then
  printf 'Verifier failure did not explain the non-string CMIO extension metadata.\n' >&2
  cat "$TMP_DIR/non-string-cmio.err" >&2
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
