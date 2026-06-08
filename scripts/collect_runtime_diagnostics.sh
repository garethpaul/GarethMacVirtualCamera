#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/GarethVideoCam.app}"
LOG_WINDOW="${2:-30m}"
EXPECTED_APP_PATH="/Applications/GarethVideoCam.app"
APP_ID="com.garethpaul.GarethVideoCam"
EXTENSION_ID="com.garethpaul.GarethVideoCam.Extension"
EXTENSION_PATH="${APP_PATH}/Contents/Library/SystemExtensions/${EXTENSION_ID}.systemextension"
VIDEO_PATH="${EXTENSION_PATH}/Contents/Resources/video.mp4"
LOG_SUBSYSTEM="com.garethpaul.GarethVideoCam"
HOST_SYSTEM_EXTENSION_ENTITLEMENT="com.apple.developer.system-extension.install"
EXTENSION_INFO_PLIST="${EXTENSION_PATH}/Contents/Info.plist"

section() {
  printf '\n== %s ==\n' "$1"
}

run_if_available() {
  local command_name="$1"
  shift

  if command -v "$command_name" >/dev/null 2>&1; then
    "$command_name" "$@" || true
  else
    printf '%s is not available on this host.\n' "$command_name"
  fi
}

read_info_plist_value() {
  local bundle_path="$1"
  local key="$2"
  local info_plist="${bundle_path}/Contents/Info.plist"
  local value=""

  if [ -f "$info_plist" ]; then
    if [ -x /usr/libexec/PlistBuddy ]; then
      value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$info_plist" 2>/dev/null || true)"
    fi

    if [ -z "$value" ] && [ -x /usr/bin/plutil ]; then
      value="$(/usr/bin/plutil -extract "$key" raw -o - "$info_plist" 2>/dev/null || true)"
    fi
  fi

  if [ -z "$value" ] && [ -x /usr/bin/defaults ]; then
    value="$(/usr/bin/defaults read "${bundle_path}/Contents/Info" "$key" 2>/dev/null || true)"
  fi

  printf '%s\n' "$value"
}

print_bundle_metadata() {
  local bundle_path="$1"
  local bundle_identifier
  local short_version
  local build_version

  bundle_identifier="$(read_bundle_identifier "$bundle_path")"
  short_version="$(read_info_plist_value "$bundle_path" CFBundleShortVersionString)"
  build_version="$(read_info_plist_value "$bundle_path" CFBundleVersion)"

  printf 'Bundle identifier: %s\n' "${bundle_identifier:-unknown}"
  printf 'Bundle short version: %s\n' "${short_version:-unknown}"
  printf 'Bundle build version: %s\n' "${build_version:-unknown}"
}

read_bundle_identifier() {
  local bundle_path="$1"

  read_info_plist_value "$bundle_path" CFBundleIdentifier
}

read_extension_mach_service_name() {
  local info_plist="$EXTENSION_INFO_PLIST"
  local value=""

  if [ -f "$info_plist" ]; then
    if [ -x /usr/libexec/PlistBuddy ]; then
      value="$(/usr/libexec/PlistBuddy -c "Print :CMIOExtension:CMIOExtensionMachServiceName" "$info_plist" 2>/dev/null || true)"
    fi

    if [ -z "$value" ] && [ -x /usr/bin/plutil ]; then
      value="$(/usr/bin/plutil -extract CMIOExtension.CMIOExtensionMachServiceName raw -o - "$info_plist" 2>/dev/null || true)"
    fi
  fi

  printf '%s\n' "$value"
}

read_team_identifier() {
  local bundle_path="$1"
  local signing_detail
  local team_identifier

  signing_detail="$(/usr/bin/codesign -dv "$bundle_path" 2>&1 || true)"
  team_identifier="$(printf '%s\n' "$signing_detail" | /usr/bin/awk -F= '/^TeamIdentifier=/{ print $2; exit }')"

  case "$team_identifier" in
    ""|"not set")
      return 1
      ;;
    *)
      printf '%s\n' "$team_identifier"
      ;;
  esac
}

has_boolean_entitlement() {
  local bundle_path="$1"
  local entitlement="$2"
  local entitlements_file
  local entitlement_value

  entitlements_file="$(/usr/bin/mktemp -t gareth-entitlements.XXXXXX)" || return 1

  if ! /usr/bin/codesign -d --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
    /bin/rm -f "$entitlements_file"
    return 1
  fi

  entitlement_value="$(/usr/libexec/PlistBuddy -c "Print :${entitlement}" "$entitlements_file" 2>/dev/null || true)"
  /bin/rm -f "$entitlements_file"

  [ "$entitlement_value" = "true" ]
}

file_byte_count() {
  local file_path="$1"

  /usr/bin/stat -f %z "$file_path" 2>/dev/null || /usr/bin/stat -c %s "$file_path" 2>/dev/null || true
}

print_file_sha256() {
  local file_path="$1"
  local checksum

  if [ -x /usr/bin/shasum ]; then
    checksum="$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{ print $1 }')"
    printf 'Video SHA-256: %s\n' "${checksum:-unknown}"
  elif command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "$file_path" | /usr/bin/awk '{ print $1 }')"
    printf 'Video SHA-256: %s\n' "${checksum:-unknown}"
  else
    printf 'Video SHA-256: checksum tool unavailable\n'
  fi
}

print_yes_no_unknown() {
  local label="$1"
  local value="$2"

  printf '%s: %s\n' "$label" "$value"
}

print_readiness_check() {
  local label="$1"
  local value="$2"

  readiness_total_count=$((readiness_total_count + 1))

  case "$value" in
    yes)
      readiness_ready_count=$((readiness_ready_count + 1))
      ;;
    no)
      readiness_blocked_count=$((readiness_blocked_count + 1))
      ;;
    *)
      readiness_unknown_count=$((readiness_unknown_count + 1))
      ;;
  esac

  print_yes_no_unknown "$label" "$value"
}

print_readiness_rollup() {
  local readiness_result="ready"

  if [ "$readiness_blocked_count" -gt 0 ]; then
    readiness_result="blocked"
  elif [ "$readiness_unknown_count" -gt 0 ]; then
    readiness_result="incomplete"
  fi

  printf 'Runtime readiness result: %s\n' "$readiness_result"
  printf 'Runtime readiness checks ready: %s/%s\n' "$readiness_ready_count" "$readiness_total_count"
  printf 'Runtime readiness checks blocked: %s\n' "$readiness_blocked_count"
  printf 'Runtime readiness checks unknown: %s\n' "$readiness_unknown_count"
}

run_readiness_rollup_self_test() {
  readiness_ready_count=0
  readiness_blocked_count=0
  readiness_unknown_count=0
  readiness_total_count=0

  print_readiness_check "Ready fixture" "yes"
  print_readiness_check "Blocked fixture" "no"
  print_readiness_check "Unknown fixture" "unknown"
  print_readiness_rollup
}

if [ "${GARETH_DIAGNOSTICS_SELF_TEST:-}" = "readiness-rollup" ]; then
  run_readiness_rollup_self_test
  exit 0
fi

print_quarantine_status() {
  local label="$1"
  local bundle_path="$2"
  local quarantine_value

  if [ ! -e "$bundle_path" ]; then
    printf '%s quarantine attribute: unknown; path is missing.\n' "$label"
    return
  fi

  if [ ! -x /usr/bin/xattr ]; then
    printf '%s quarantine attribute: unknown; xattr is not available on this host.\n' "$label"
    return
  fi

  if quarantine_value="$(/usr/bin/xattr -p com.apple.quarantine "$bundle_path" 2>/dev/null)"; then
    printf '%s quarantine attribute: present (%s)\n' "$label" "$quarantine_value"
  else
    printf '%s quarantine attribute: absent\n' "$label"
  fi
}

section "Host"
printf 'Log window: %s\n' "$LOG_WINDOW"
run_if_available sw_vers
run_if_available uname -a
run_if_available xcodebuild -version

section "Application"
printf 'App path: %s\n' "$APP_PATH"
if [ -d "$APP_PATH" ]; then
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 || true
  /usr/bin/codesign -dv "$APP_PATH" 2>&1 || true
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 || true
  run_if_available spctl --assess --type execute --verbose=4 "$APP_PATH"
  print_bundle_metadata "$APP_PATH"
else
  printf 'App bundle is not installed at the requested path.\n'
fi

section "Application Location Check"
printf 'Expected app path: %s\n' "$EXPECTED_APP_PATH"
printf 'Actual app path: %s\n' "$APP_PATH"
case "$APP_PATH" in
  /Applications/*)
    printf 'App path is inside /Applications: yes\n'
    ;;
  *)
    printf 'App path is inside /Applications: no\n'
    ;;
esac

if [ "$APP_PATH" = "$EXPECTED_APP_PATH" ]; then
  printf 'App path matches expected app path: yes\n'
else
  printf 'App path matches expected app path: no\n'
fi

section "Quarantine Check"
print_quarantine_status "App" "$APP_PATH"
print_quarantine_status "Extension" "$EXTENSION_PATH"

section "Embedded System Extension"
printf 'Extension path: %s\n' "$EXTENSION_PATH"
if [ -d "$EXTENSION_PATH" ]; then
  /usr/bin/codesign --verify --strict --verbose=2 "$EXTENSION_PATH" 2>&1 || true
  /usr/bin/codesign -dv "$EXTENSION_PATH" 2>&1 || true
  /usr/bin/codesign -d --entitlements :- "$EXTENSION_PATH" 2>&1 || true
  run_if_available spctl --assess --type execute --verbose=4 "$EXTENSION_PATH"
  print_bundle_metadata "$EXTENSION_PATH"
else
  printf 'Expected embedded system extension was not found.\n'
fi

section "Embedded Extension Runtime Metadata"
printf 'Extension Info.plist path: %s\n' "$EXTENSION_INFO_PLIST"
if [ -d "$EXTENSION_PATH" ]; then
  extension_executable="$(read_info_plist_value "$EXTENSION_PATH" CFBundleExecutable)"
  extension_executable_path="${EXTENSION_PATH}/Contents/MacOS/${extension_executable}"
  extension_mach_service_name="$(read_extension_mach_service_name)"

  printf 'Extension CFBundleExecutable: %s\n' "${extension_executable:-unknown}"
  if [ -n "$extension_executable" ]; then
    printf 'Extension executable path: %s\n' "$extension_executable_path"
    if [ -f "$extension_executable_path" ]; then
      printf 'Extension executable exists: yes\n'
      if [ -x "$extension_executable_path" ]; then
        printf 'Extension executable is executable: yes\n'
      else
        printf 'Extension executable is executable: no\n'
      fi
    else
      printf 'Extension executable exists: no\n'
      printf 'Extension executable is executable: no\n'
    fi
  else
    printf 'Extension executable path: unknown\n'
    printf 'Extension executable exists: unknown\n'
    printf 'Extension executable is executable: unknown\n'
  fi
  printf 'Extension CMIO Mach service: %s\n' "${extension_mach_service_name:-unknown}"
else
  printf 'Extension runtime metadata requires the embedded system extension bundle.\n'
fi

section "Bundled Video"
printf 'Video path: %s\n' "$VIDEO_PATH"
if [ -f "$VIDEO_PATH" ]; then
  video_byte_count="$(file_byte_count "$VIDEO_PATH")"
  printf 'Video resource exists: yes\n'
  printf 'Video byte size: %s\n' "${video_byte_count:-unknown}"
  if [ "$video_byte_count" = "0" ]; then
    printf 'Video resource is empty: yes\n'
  else
    printf 'Video resource is empty: no\n'
  fi
  print_file_sha256 "$VIDEO_PATH"
  /bin/ls -lh "$VIDEO_PATH" 2>/dev/null || true
  run_if_available mdls \
    -name kMDItemCodecs \
    -name kMDItemPixelWidth \
    -name kMDItemPixelHeight \
    -name kMDItemDurationSeconds \
    "$VIDEO_PATH"
else
  printf 'Video resource exists: no\n'
  printf 'Expected bundled video resource was not found.\n'
fi

section "Bundle Identifier Check"
if [ -d "$APP_PATH" ]; then
  app_bundle_identifier="$(read_bundle_identifier "$APP_PATH")"
  printf 'Expected app bundle identifier: %s\n' "$APP_ID"
  printf 'Actual app bundle identifier: %s\n' "${app_bundle_identifier:-unknown}"

  if [ "$app_bundle_identifier" = "$APP_ID" ]; then
    printf 'App bundle identifier matches: yes\n'
  else
    printf 'App bundle identifier matches: no\n'
  fi
else
  printf 'App bundle identifier check requires the app bundle.\n'
fi

if [ -d "$EXTENSION_PATH" ]; then
  extension_bundle_identifier="$(read_bundle_identifier "$EXTENSION_PATH")"
  printf 'Expected extension bundle identifier: %s\n' "$EXTENSION_ID"
  printf 'Actual extension bundle identifier: %s\n' "${extension_bundle_identifier:-unknown}"

  if [ "$extension_bundle_identifier" = "$EXTENSION_ID" ]; then
    printf 'Extension bundle identifier matches: yes\n'
  else
    printf 'Extension bundle identifier matches: no\n'
  fi
else
  printf 'Extension bundle identifier check requires the embedded system extension bundle.\n'
fi

section "Signing Team Match"
if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  app_team_identifier=""
  extension_team_identifier=""

  if app_team_identifier="$(read_team_identifier "$APP_PATH")"; then
    printf 'App team identifier: %s\n' "$app_team_identifier"
  else
    printf 'App team identifier: unknown\n'
  fi

  if extension_team_identifier="$(read_team_identifier "$EXTENSION_PATH")"; then
    printf 'Extension team identifier: %s\n' "$extension_team_identifier"
  else
    printf 'Extension team identifier: unknown\n'
  fi

  if [ -n "$app_team_identifier" ] && [ -n "$extension_team_identifier" ]; then
    if [ "$app_team_identifier" = "$extension_team_identifier" ]; then
      printf 'Team identifiers match: yes\n'
    else
      printf 'Team identifiers match: no\n'
    fi
  else
    printf 'Team identifiers match: unknown\n'
  fi
else
  printf 'Signing team comparison requires both the app and embedded system extension bundles.\n'
fi

section "Entitlement Check"
printf 'Expected app System Extension entitlement: %s\n' "$HOST_SYSTEM_EXTENSION_ENTITLEMENT"
if [ -d "$APP_PATH" ]; then
  if has_boolean_entitlement "$APP_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT"; then
    printf 'App System Extension entitlement present: yes\n'
  else
    printf 'App System Extension entitlement present: no\n'
  fi
else
  printf 'App System Extension entitlement present: unknown; app bundle is missing.\n'
fi

if [ -d "$EXTENSION_PATH" ]; then
  if has_boolean_entitlement "$EXTENSION_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT"; then
    printf 'Extension carries host-only System Extension entitlement: yes\n'
  else
    printf 'Extension carries host-only System Extension entitlement: no\n'
  fi
else
  printf 'Extension carries host-only System Extension entitlement: unknown; embedded extension is missing.\n'
fi

section "Runtime Readiness Summary"
readiness_ready_count=0
readiness_blocked_count=0
readiness_unknown_count=0
readiness_total_count=0

if [ "$APP_PATH" = "$EXPECTED_APP_PATH" ]; then
  print_readiness_check "Application location ready" "yes"
else
  print_readiness_check "Application location ready" "no"
fi

if [ -d "$APP_PATH" ]; then
  app_bundle_identifier="$(read_bundle_identifier "$APP_PATH")"
  if [ "$app_bundle_identifier" = "$APP_ID" ]; then
    print_readiness_check "App bundle identifier ready" "yes"
  else
    print_readiness_check "App bundle identifier ready" "no"
  fi

  if /usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    print_readiness_check "App signature ready" "yes"
  else
    print_readiness_check "App signature ready" "no"
  fi

  if has_boolean_entitlement "$APP_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT"; then
    print_readiness_check "App System Extension entitlement ready" "yes"
  else
    print_readiness_check "App System Extension entitlement ready" "no"
  fi
else
  print_readiness_check "App bundle identifier ready" "unknown"
  print_readiness_check "App signature ready" "unknown"
  print_readiness_check "App System Extension entitlement ready" "unknown"
fi

if [ -d "$EXTENSION_PATH" ]; then
  extension_bundle_identifier="$(read_bundle_identifier "$EXTENSION_PATH")"
  extension_executable="$(read_info_plist_value "$EXTENSION_PATH" CFBundleExecutable)"
  extension_mach_service_name="$(read_extension_mach_service_name)"
  if [ "$extension_bundle_identifier" = "$EXTENSION_ID" ]; then
    print_readiness_check "Extension bundle identifier ready" "yes"
  else
    print_readiness_check "Extension bundle identifier ready" "no"
  fi

  if /usr/bin/codesign --verify --strict "$EXTENSION_PATH" >/dev/null 2>&1; then
    print_readiness_check "Extension signature ready" "yes"
  else
    print_readiness_check "Extension signature ready" "no"
  fi

  if has_boolean_entitlement "$EXTENSION_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT"; then
    print_readiness_check "Extension host-only entitlement absent" "no"
  else
    print_readiness_check "Extension host-only entitlement absent" "yes"
  fi

  if [ -n "$extension_executable" ] && [ -f "${EXTENSION_PATH}/Contents/MacOS/${extension_executable}" ] && [ -x "${EXTENSION_PATH}/Contents/MacOS/${extension_executable}" ]; then
    print_readiness_check "Extension executable ready" "yes"
  else
    print_readiness_check "Extension executable ready" "no"
  fi

  if [ -n "$extension_mach_service_name" ]; then
    print_readiness_check "Extension CMIO Mach service ready" "yes"
  else
    print_readiness_check "Extension CMIO Mach service ready" "no"
  fi
else
  print_readiness_check "Extension bundle identifier ready" "unknown"
  print_readiness_check "Extension signature ready" "unknown"
  print_readiness_check "Extension host-only entitlement absent" "unknown"
  print_readiness_check "Extension executable ready" "unknown"
  print_readiness_check "Extension CMIO Mach service ready" "unknown"
fi

if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  app_team_identifier="$(read_team_identifier "$APP_PATH" || true)"
  extension_team_identifier="$(read_team_identifier "$EXTENSION_PATH" || true)"
  if [ -n "$app_team_identifier" ] && [ -n "$extension_team_identifier" ] && [ "$app_team_identifier" = "$extension_team_identifier" ]; then
    print_readiness_check "Signing Team match ready" "yes"
  elif [ -n "$app_team_identifier" ] && [ -n "$extension_team_identifier" ]; then
    print_readiness_check "Signing Team match ready" "no"
  else
    print_readiness_check "Signing Team match ready" "unknown"
  fi
else
  print_readiness_check "Signing Team match ready" "unknown"
fi

if [ -f "$VIDEO_PATH" ]; then
  video_byte_count="$(file_byte_count "$VIDEO_PATH")"
  if [ -n "$video_byte_count" ] && [ "$video_byte_count" != "0" ]; then
    print_readiness_check "Bundled video ready" "yes"
  else
    print_readiness_check "Bundled video ready" "no"
  fi
else
  print_readiness_check "Bundled video ready" "no"
fi

print_readiness_rollup

section "System Extension Registration"
if [ -x /usr/bin/systemextensionsctl ]; then
  registration_output="$(/usr/bin/systemextensionsctl list 2>&1 || true)"

  if printf '%s\n' "$registration_output" | /usr/bin/grep -F "$EXTENSION_ID" >/dev/null; then
    print_yes_no_unknown "Extension registration entry present" "yes"
  else
    print_yes_no_unknown "Extension registration entry present" "no"
  fi

  printf 'Full systemextensionsctl list output:\n'
  if [ -n "$registration_output" ]; then
    printf '%s\n' "$registration_output"
  else
    printf 'systemextensionsctl list produced no output.\n'
  fi
else
  printf 'systemextensionsctl is not available on this host.\n'
  print_yes_no_unknown "Extension registration entry present" "unknown"
fi

section "Camera Devices"
run_if_available system_profiler SPCameraDataType

section "Running App and Extension Processes"
if [ -x /bin/ps ]; then
  /bin/ps -axo pid,ppid,stat,comm,args | /usr/bin/awk -v app_id="$APP_ID" -v extension_id="$EXTENSION_ID" -v script_pid="$$" '
    NR == 1 {
      print
      next
    }
    $1 == script_pid || $4 ~ /(^|\/)awk$/ || index($0, "collect_runtime_diagnostics.sh") {
      next
    }
    index($0, "GarethVideoCam") || index($0, app_id) || index($0, extension_id) {
      print
      matches += 1
    }
    END {
      if (matches == 0) {
        print "No running GarethVideoCam app or extension processes found."
      }
    }
  ' || true
else
  printf 'ps is not available on this host.\n'
fi

section "Recent Gareth Video Cam Logs"
if command -v log >/dev/null 2>&1; then
  /usr/bin/log show --last "$LOG_WINDOW" --style compact --predicate "subsystem == '${LOG_SUBSYSTEM}'" 2>/dev/null || true
else
  printf 'log is not available on this host.\n'
fi

section "Recent System Extension and Camera Logs"
if command -v log >/dev/null 2>&1; then
  /usr/bin/log show --last "$LOG_WINDOW" --style compact --predicate "process == 'systemextensionsd' OR subsystem == 'com.apple.systemextension' OR subsystem == 'com.apple.systemextensions' OR subsystem == 'com.apple.CoreMediaIO' OR eventMessage CONTAINS[c] '${EXTENSION_ID}'" 2>/dev/null || true
else
  printf 'log is not available on this host.\n'
fi
