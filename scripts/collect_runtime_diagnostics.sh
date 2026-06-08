#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/GarethVideoCam.app}"
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

section "Host"
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
  /usr/bin/defaults read "${EXTENSION_PATH}/Contents/Info" CFBundleIdentifier 2>/dev/null || true
else
  printf 'Expected embedded system extension was not found.\n'
fi

section "System Extension Registration"
if [ -x /usr/bin/systemextensionsctl ]; then
  /usr/bin/systemextensionsctl list | /usr/bin/grep -E "${EXTENSION_ID}|enabled|activated|waiting|terminated|replaced" || true
else
  printf 'systemextensionsctl is not available on this host.\n'
fi

section "Recent Gareth Video Cam Logs"
if command -v log >/dev/null 2>&1; then
  /usr/bin/log show --last 30m --style compact --predicate "subsystem == '${LOG_SUBSYSTEM}'" 2>/dev/null || true
else
  printf 'log is not available on this host.\n'
fi
