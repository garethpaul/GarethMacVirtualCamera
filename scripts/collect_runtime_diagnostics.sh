#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/GarethVideoCam.app}"
LOG_WINDOW="${2:-30m}"
EXTENSION_ID="com.garethpaul.GarethVideoCam.Extension"
EXTENSION_PATH="${APP_PATH}/Contents/Library/SystemExtensions/${EXTENSION_ID}.systemextension"
LOG_SUBSYSTEM="com.garethpaul.GarethVideoCam"

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

print_bundle_metadata() {
  local bundle_path="$1"
  local info_plist="${bundle_path}/Contents/Info"
  local bundle_identifier
  local short_version
  local build_version

  bundle_identifier="$(/usr/bin/defaults read "$info_plist" CFBundleIdentifier 2>/dev/null || true)"
  short_version="$(/usr/bin/defaults read "$info_plist" CFBundleShortVersionString 2>/dev/null || true)"
  build_version="$(/usr/bin/defaults read "$info_plist" CFBundleVersion 2>/dev/null || true)"

  printf 'Bundle identifier: %s\n' "${bundle_identifier:-unknown}"
  printf 'Bundle short version: %s\n' "${short_version:-unknown}"
  printf 'Bundle build version: %s\n' "${build_version:-unknown}"
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

section "System Extension Registration"
if [ -x /usr/bin/systemextensionsctl ]; then
  /usr/bin/systemextensionsctl list | /usr/bin/grep -E "${EXTENSION_ID}|enabled|activated|waiting|terminated|replaced" || true
else
  printf 'systemextensionsctl is not available on this host.\n'
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
