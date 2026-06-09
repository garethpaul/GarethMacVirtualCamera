#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATE_PROJECT_SCRIPT="${SCRIPT_DIR}/validate_project.py"
DIAGNOSTICS_PARSER_SOURCE="adjacent script resource"
if [ ! -f "$VALIDATE_PROJECT_SCRIPT" ]; then
  VALIDATE_PROJECT_SCRIPT="${ROOT}/scripts/validate_project.py"
  DIAGNOSTICS_PARSER_SOURCE="repository fallback"
fi
APP_PATH="${1:-/Applications/GarethVideoCam.app}"
LOG_WINDOW="${2:-30m}"
EXPECTED_APP_PATH="/Applications/GarethVideoCam.app"
APP_ID="com.garethpaul.GarethVideoCam"
EXTENSION_ID="com.garethpaul.GarethVideoCam.Extension"
EXTENSION_PATH="${APP_PATH}/Contents/Library/SystemExtensions/${EXTENSION_ID}.systemextension"
VIDEO_PATH="${EXTENSION_PATH}/Contents/Resources/video.mp4"
LOG_SUBSYSTEM="com.garethpaul.GarethVideoCam"
HOST_SYSTEM_EXTENSION_ENTITLEMENT="com.apple.developer.system-extension.install"
APP_GROUP_ENTITLEMENT="com.apple.security.application-groups"
APP_GROUP_BASE_ID="com.garethpaul.GarethVideoCam"
EXPECTED_CAMERA_NAME="Gareth Video Cam"
EXPECTED_VIDEO_WIDTH="1280"
EXPECTED_VIDEO_HEIGHT="720"
EXPECTED_VIDEO_FRAME_RATE="24"
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

python3_command() {
  if [ "${GARETH_DIAGNOSTICS_SKIP_PYTHON:-0}" = "1" ]; then
    return
  fi

  if [ -x /usr/bin/python3 ]; then
    printf '/usr/bin/python3\n'
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  fi
}

plist_xml_string_value() {
  /usr/bin/awk '
    /^[[:space:]]*<\?xml/ { next }
    /^[[:space:]]*<!DOCTYPE/ { next }
    /^[[:space:]]*<plist/ { next }
    /^[[:space:]]*<\/plist>/ { next }
    /^[[:space:]]*<string>.*<\/string>[[:space:]]*$/ {
      if (saw_value) {
        invalid = 1
      }
      value = $0
      sub(/^[[:space:]]*<string>/, "", value)
      sub(/<\/string>[[:space:]]*$/, "", value)
      trimmed_value = value
      sub(/^[[:space:]]+/, "", trimmed_value)
      sub(/[[:space:]]+$/, "", trimmed_value)
      if (trimmed_value != value) {
        invalid = 1
      } else if (trimmed_value != "") {
        print value
      }
      saw_value = 1
      next
    }
    NF { invalid = 1 }
    END {
      if (invalid || !saw_value) {
        exit 1
      }
    }'
}

read_plist_string_value() {
  local info_plist="$1"
  local key_path="$2"
  local python_bin=""
  local plistbuddy_key_path
  local value=""

  if [ ! -f "$info_plist" ]; then
    return 0
  fi

  python_bin="$(python3_command)"
  if [ -n "$python_bin" ]; then
    "$python_bin" - "$info_plist" "$key_path" 2>/dev/null <<'PY' || true
import plistlib
import sys

with open(sys.argv[1], "rb") as info_file:
    value = plistlib.load(info_file)

for key in sys.argv[2].split("."):
    if not isinstance(value, dict):
        value = None
        break
    value = value.get(key)

if isinstance(value, str):
    trimmed_value = value.strip()
    if trimmed_value and trimmed_value == value:
        print(value)
PY
    return 0
  fi

  plistbuddy_key_path="${key_path//./:}"
  if [ -x /usr/libexec/PlistBuddy ]; then
    if [ -x /usr/bin/plutil ]; then
      /usr/bin/plutil -lint "$info_plist" >/dev/null 2>/dev/null || return 0
    fi

    value="$(/usr/libexec/PlistBuddy -x -c "Print :${plistbuddy_key_path}" "$info_plist" 2>/dev/null | plist_xml_string_value || true)"
  fi

  if [ -z "$value" ] && [ -x /usr/bin/plutil ]; then
    value="$(/usr/bin/plutil -extract "$key_path" xml1 -o - "$info_plist" 2>/dev/null | plist_xml_string_value || true)"
  fi

  printf '%s\n' "$value"
}

read_info_plist_value() {
  local bundle_path="$1"
  local key="$2"
  local info_plist="${bundle_path}/Contents/Info.plist"

  read_plist_string_value "$info_plist" "$key"
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

path_matches_expected_value() {
  local actual_path="$1"
  local expected_path="$2"

  if [ "$actual_path" = "$expected_path" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

application_location_readiness_value() {
  local actual_path="$1"
  local expected_path="$2"

  if [ -d "$actual_path" ] && [ "$(path_matches_expected_value "$actual_path" "$expected_path")" = "yes" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

bundle_identifier_matches_expected_value() {
  local bundle_identifier="$1"
  local expected_identifier="$2"

  if [ -n "$bundle_identifier" ] && [ "$bundle_identifier" = "$expected_identifier" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

executable_readiness_value() {
  local executable_name="$1"
  local executable_path="$2"

  if [ -n "$executable_name" ] && [ -f "$executable_path" ] && [ -x "$executable_path" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

bundle_executable_path() {
  local bundle_path="$1"
  local executable_name

  executable_name="$(read_info_plist_value "$bundle_path" CFBundleExecutable)"
  if [ -n "$executable_name" ]; then
    printf '%s\n' "${bundle_path}/Contents/MacOS/${executable_name}"
  fi
}

bundle_executable_architectures() {
  local bundle_path="$1"
  local executable_path

  executable_path="$(bundle_executable_path "$bundle_path")"
  if [ -n "$executable_path" ] && [ -f "$executable_path" ] && [ -x /usr/bin/lipo ]; then
    /usr/bin/lipo -archs "$executable_path" 2>/dev/null | /usr/bin/awk '{ for (arch_index = 1; arch_index <= NF; arch_index += 1) print $arch_index }' || true
  fi
}

bundle_versions_match_readiness_value() {
  local app_short_version="$1"
  local app_build_version="$2"
  local extension_short_version="$3"
  local extension_build_version="$4"

  if [ -n "$app_short_version" ] \
    && [ -n "$app_build_version" ] \
    && [ -n "$extension_short_version" ] \
    && [ -n "$extension_build_version" ] \
    && [ "$app_short_version" = "$extension_short_version" ] \
    && [ "$app_build_version" = "$extension_build_version" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

read_extension_mach_service_name() {
  read_plist_string_value "$EXTENSION_INFO_PLIST" "CMIOExtension.CMIOExtensionMachServiceName"
}

contains_unresolved_build_setting() {
  local value="$1"

  if [[ "$value" == *'$('* || "$value" == *'${'* ]]; then
    return 0
  fi

  return 1
}

mach_service_resolved_value() {
  local mach_service_name="$1"

  if [ -z "$mach_service_name" ]; then
    printf 'unknown\n'
  elif contains_unresolved_build_setting "$mach_service_name"; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
}

mach_service_matches_expected_value() {
  local mach_service_name="$1"
  local extension_identifier="$2"
  local team_prefixed_suffix=".$extension_identifier"
  local team_prefix

  if [ -z "$mach_service_name" ]; then
    printf 'unknown\n'
  elif [ "$mach_service_name" = "$extension_identifier" ]; then
    printf 'yes\n'
  elif [[ "$mach_service_name" == *"$team_prefixed_suffix" ]]; then
    team_prefix="${mach_service_name%"$team_prefixed_suffix"}"
    if [[ "$team_prefix" =~ ^[[:alnum:]]{10}$ ]]; then
      printf 'yes\n'
    else
      printf 'no\n'
    fi
  else
    printf 'no\n'
  fi
}

mach_service_readiness_value() {
  local mach_service_name="$1"
  local extension_identifier="$2"

  if [ "$(mach_service_resolved_value "$mach_service_name")" = "yes" ] \
    && [ "$(mach_service_matches_expected_value "$mach_service_name" "$extension_identifier")" = "yes" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

read_team_identifier() {
  local bundle_path="$1"
  local signing_detail
  local team_identifiers

  signing_detail="$(/usr/bin/codesign -d --all-architectures -v "$bundle_path" 2>&1 || true)"
  team_identifiers="$(printf '%s\n' "$signing_detail" | /usr/bin/awk -F= '
    /^TeamIdentifier=/ {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value ~ /^[[:alnum:]]{10}$/) {
        print value
      }
    }' | /usr/bin/sort -u)"

  if [ -z "$team_identifiers" ]; then
    return 1
  fi

  printf '%s\n' "$team_identifiers"
}

team_identifiers_match_value() {
  local app_team_identifiers="$1"
  local extension_team_identifiers="$2"
  local app_team_identifier_count
  local extension_team_identifier_count
  local app_team_identifier
  local extension_team_identifier

  app_team_identifier_count="$(printf '%s\n' "$app_team_identifiers" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  extension_team_identifier_count="$(printf '%s\n' "$extension_team_identifiers" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  app_team_identifier="$(printf '%s\n' "$app_team_identifiers" | /usr/bin/awk 'NF { print; exit }')"
  extension_team_identifier="$(printf '%s\n' "$extension_team_identifiers" | /usr/bin/awk 'NF { print; exit }')"

  if [ "$app_team_identifier_count" = "1" ] \
    && [ "$extension_team_identifier_count" = "1" ] \
    && team_identifier_is_valid "$app_team_identifier" \
    && team_identifier_is_valid "$extension_team_identifier" \
    && [ "$app_team_identifier" = "$extension_team_identifier" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

team_identifier_is_valid() {
  local team_identifier="$1"

  [[ "$team_identifier" =~ ^[[:alnum:]]{10}$ ]]
}

boolean_entitlement_value() {
  local bundle_path="$1"
  local entitlement="$2"
  local architectures
  local architecture
  local entitlement_values=""
  local entitlement_value

  architectures="$(bundle_executable_architectures "$bundle_path")"
  if [ -z "$architectures" ]; then
    read_boolean_entitlement_for_architecture "$bundle_path" "$entitlement" ""
    return
  fi

  while IFS= read -r architecture; do
    [ -n "$architecture" ] || continue
    entitlement_value="$(read_boolean_entitlement_for_architecture "$bundle_path" "$entitlement" "$architecture")"
    entitlement_values="${entitlement_values}${entitlement_value}
"
  done <<EOF
$architectures
EOF

  boolean_entitlement_all_architectures_value "$entitlement_values"
}

read_boolean_entitlement_for_architecture() {
  local bundle_path="$1"
  local entitlement="$2"
  local architecture="$3"
  local entitlements_file
  local entitlement_value

  entitlements_file="$(/usr/bin/mktemp -t gareth-entitlements.XXXXXX)" || {
    printf 'unknown\n'
    return
  }

  if [ -n "$architecture" ]; then
    if ! /usr/bin/codesign -d --architecture "$architecture" --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
      /bin/rm -f "$entitlements_file"
      printf 'unknown\n'
      return
    fi
  elif ! /usr/bin/codesign -d --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
    /bin/rm -f "$entitlements_file"
    printf 'unknown\n'
    return
  fi

  if ! entitlement_value="$(read_boolean_entitlement_from_entitlements_file "$entitlements_file" "$entitlement")"; then
    /bin/rm -f "$entitlements_file"
    printf 'unknown\n'
    return
  fi
  /bin/rm -f "$entitlements_file"
  printf '%s\n' "$entitlement_value"
}

read_boolean_entitlement_from_entitlements_file() {
  local entitlements_file="$1"
  local entitlement="$2"
  local plistbuddy_output
  local python_bin=""

  python_bin="$(python3_command)"

  if [ -n "$python_bin" ]; then
    "$python_bin" - "$entitlements_file" "$entitlement" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as entitlements_file:
    entitlements = plistlib.load(entitlements_file)

value = entitlements.get(sys.argv[2], False)
if not isinstance(value, bool):
    sys.exit(1)

print("yes" if value else "no")
PY
  elif [ -x /usr/libexec/PlistBuddy ]; then
    if [ -x /usr/bin/plutil ]; then
      /usr/bin/plutil -lint "$entitlements_file" >/dev/null 2>/dev/null || return 1
    fi

    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -x -c "Print :${entitlement}" "$entitlements_file" 2>/dev/null)"; then
      printf 'no\n'
      return
    fi

    printf '%s\n' "$plistbuddy_output" | /usr/bin/awk '
        /^[[:space:]]*<\?xml/ { next }
        /^[[:space:]]*<!DOCTYPE/ { next }
        /^[[:space:]]*<plist/ { next }
        /^[[:space:]]*<\/plist>/ { next }
        /^[[:space:]]*<true\/>[[:space:]]*$/ {
          if (value != "") {
            invalid = 1
          }
          value = "yes"
          next
        }
        /^[[:space:]]*<false\/>[[:space:]]*$/ {
          if (value != "") {
            invalid = 1
          }
          value = "no"
          next
        }
        NF { invalid = 1 }
        END {
          if (invalid || value == "") {
            exit 1
          }
          print value
        }'
  else
    return 1
  fi
}

print_signed_entitlements() {
  local label="$1"
  local bundle_path="$2"
  local architectures
  local architecture

  architectures="$(bundle_executable_architectures "$bundle_path")"
  if [ -z "$architectures" ]; then
    /usr/bin/codesign -d --entitlements :- "$bundle_path" 2>&1 || true
    return
  fi

  while IFS= read -r architecture; do
    [ -n "$architecture" ] || continue
    printf '%s signed entitlements architecture: %s\n' "$label" "$architecture"
    /usr/bin/codesign -d --architecture "$architecture" --entitlements :- "$bundle_path" 2>&1 || true
  done <<EOF
$architectures
EOF
}

boolean_entitlement_all_architectures_value() {
  local entitlement_values="$1"
  local entitlement_value
  local value_count=0
  local saw_missing="no"
  local saw_unknown="no"

  while IFS= read -r entitlement_value; do
    [ -n "$entitlement_value" ] || continue
    value_count=$((value_count + 1))
    case "$entitlement_value" in
      yes)
        ;;
      no)
        saw_missing="yes"
        ;;
      *)
        saw_unknown="yes"
        ;;
    esac
  done <<EOF
$entitlement_values
EOF

  if [ "$value_count" -eq 0 ] || [ "$saw_unknown" = "yes" ]; then
    printf 'unknown\n'
  elif [ "$saw_missing" = "yes" ]; then
    printf 'no\n'
  else
    printf 'yes\n'
  fi
}

extension_host_only_entitlement_absent_readiness_value() {
  local extension_signature_ready="$1"
  local host_only_entitlement_present="$2"

  if [ "$extension_signature_ready" = "yes" ] && [ "$host_only_entitlement_present" = "no" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

read_application_groups() {
  local bundle_path="$1"
  local architectures
  local architecture
  local architecture_count=0
  local architecture_groups=""
  local groups

  architectures="$(bundle_executable_architectures "$bundle_path")"
  if [ -z "$architectures" ]; then
    read_application_groups_for_architecture "$bundle_path" ""
    return
  fi

  while IFS= read -r architecture; do
    [ -n "$architecture" ] || continue
    architecture_count=$((architecture_count + 1))
    groups="$(read_application_groups_for_architecture "$bundle_path" "$architecture")" || return 1
    architecture_groups="${architecture_groups}${groups}
"
  done <<EOF
$architectures
EOF

  common_application_groups_for_architectures "$architecture_groups" "$architecture_count"
}

read_application_groups_for_architecture() {
  local bundle_path="$1"
  local architecture="$2"
  local entitlements_file
  local groups_file

  entitlements_file="$(/usr/bin/mktemp -t gareth-entitlements.XXXXXX)" || return 1
  groups_file="$(/usr/bin/mktemp -t gareth-application-groups.XXXXXX)" || {
    /bin/rm -f "$entitlements_file"
    return 1
  }

  if [ -n "$architecture" ]; then
    if ! /usr/bin/codesign -d --architecture "$architecture" --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
      /bin/rm -f "$entitlements_file" "$groups_file"
      return 1
    fi
  elif ! /usr/bin/codesign -d --entitlements :- "$bundle_path" >"$entitlements_file" 2>/dev/null; then
    /bin/rm -f "$entitlements_file" "$groups_file"
    return 1
  fi

  if ! read_application_groups_from_entitlements_file "$entitlements_file" >"$groups_file" 2>/dev/null; then
    /bin/rm -f "$entitlements_file" "$groups_file"
    return 1
  fi

  if ! /usr/bin/sort -u "$groups_file"; then
    /bin/rm -f "$entitlements_file" "$groups_file"
    return 1
  fi

  /bin/rm -f "$entitlements_file" "$groups_file"
}

read_application_groups_from_entitlements_file() {
  local entitlements_file="$1"
  local python_bin=""
  local plistbuddy_output

  python_bin="$(python3_command)"

  if [ -n "$python_bin" ]; then
    "$python_bin" - "$entitlements_file" "$APP_GROUP_ENTITLEMENT" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as entitlements_file:
    entitlements = plistlib.load(entitlements_file)

groups = entitlements.get(sys.argv[2], [])
if not isinstance(groups, list):
    sys.exit(1)

for group in groups:
    if not isinstance(group, str):
        sys.exit(1)
    if group.strip() != group:
        sys.exit(1)
    if group:
        print(group)
PY
  elif [ -x /usr/libexec/PlistBuddy ]; then
    if [ -x /usr/bin/plutil ]; then
      /usr/bin/plutil -lint "$entitlements_file" >/dev/null 2>/dev/null || return 1
    fi

    if ! plistbuddy_output="$(/usr/libexec/PlistBuddy -x -c "Print :${APP_GROUP_ENTITLEMENT}" "$entitlements_file" 2>/dev/null)"; then
      return
    fi

    printf '%s\n' "$plistbuddy_output" | /usr/bin/awk '
        /^[[:space:]]*<\?xml/ { next }
        /^[[:space:]]*<!DOCTYPE/ { next }
        /^[[:space:]]*<plist/ { next }
        /^[[:space:]]*<\/plist>/ { next }
        /^[[:space:]]*<array>[[:space:]]*$/ {
          if (saw_array) {
            invalid = 1
          }
          saw_array = 1
          next
        }
        /^[[:space:]]*<\/array>[[:space:]]*$/ { saw_end = 1; next }
        /^[[:space:]]*<string>.*<\/string>[[:space:]]*$/ {
          if (!saw_array || saw_end) {
            invalid = 1
            next
          }
          group = $0
          sub(/^[[:space:]]*<string>/, "", group)
          sub(/<\/string>[[:space:]]*$/, "", group)
          trimmed_group = group
          sub(/^[[:space:]]+/, "", trimmed_group)
          sub(/[[:space:]]+$/, "", trimmed_group)
          if (trimmed_group != group) {
            invalid = 1
            next
          }
          if (group != "") {
            print group
          }
          next
        }
        NF { invalid = 1 }
        END {
          if (!saw_array || !saw_end || invalid) {
            exit 1
          }
        }'
  else
    return 1
  fi
}

common_application_groups_for_architectures() {
  local architecture_groups="$1"
  local architecture_count="$2"

  if [ "$architecture_count" -le 0 ]; then
    return
  fi

  printf '%s\n' "$architecture_groups" | /usr/bin/awk -v architecture_count="$architecture_count" '
    NF {
      group_counts[$0] += 1
    }
    END {
      for (application_group in group_counts) {
        if (group_counts[application_group] == architecture_count) {
          print application_group
        }
      }
    }' | /usr/bin/sort
}

format_application_groups() {
  local groups="$1"

  format_line_values "$groups"
}

format_line_values() {
  local values="$1"

  printf '%s\n' "$values" | /usr/bin/awk '
    NF {
      if (out) {
        out = out ", " $0
      } else {
        out = $0
      }
    }
    END {
      if (out) {
        print out
      } else {
        print "none"
      }
    }'
}

application_group_matches_expected_identifier() {
  local application_group="$1"
  local team_prefixed_suffix=".$APP_GROUP_BASE_ID"
  local team_prefix

  if [[ "$application_group" == *"$team_prefixed_suffix" ]]; then
    team_prefix="${application_group%"$team_prefixed_suffix"}"
    if [[ "$team_prefix" =~ ^[[:alnum:]]{10}$ ]]; then
      return 0
    fi
  fi

  return 1
}

application_groups_expected_present_value() {
  local groups="$1"

  while IFS= read -r application_group; do
    [ -n "$application_group" ] || continue
    if ! contains_unresolved_build_setting "$application_group" \
      && application_group_matches_expected_identifier "$application_group"; then
      printf 'yes\n'
      return
    fi
  done <<EOF
$groups
EOF

  printf 'no\n'
}

application_groups_share_expected_value() {
  local app_groups="$1"
  local extension_groups="$2"

  while IFS= read -r app_group; do
    [ -n "$app_group" ] || continue
    if contains_unresolved_build_setting "$app_group" \
      || ! application_group_matches_expected_identifier "$app_group"; then
      continue
    fi

    if printf '%s\n' "$extension_groups" | /usr/bin/grep -F -x -- "$app_group" >/dev/null; then
      printf 'yes\n'
      return
    fi
  done <<EOF
$app_groups
EOF

  printf 'no\n'
}

application_groups_ready_value() {
  local app_groups="$1"
  local extension_groups="$2"

  if [ "$(application_groups_expected_present_value "$app_groups")" = "yes" ] \
    && [ "$(application_groups_expected_present_value "$extension_groups")" = "yes" ] \
    && [ "$(application_groups_share_expected_value "$app_groups" "$extension_groups")" = "yes" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

camera_device_present_value() {
  local camera_inventory="$1"
  local expected_camera_name="$2"

  if [ -z "$camera_inventory" ]; then
    printf 'unknown\n'
  elif printf '%s\n' "$camera_inventory" | /usr/bin/awk -v expected_camera_name="$expected_camera_name" '
    {
      camera_name = $0
      sub(/^[[:space:]]+/, "", camera_name)
      sub(/[[:space:]]+$/, "", camera_name)
      sub(/:$/, "", camera_name)
      if (camera_name == expected_camera_name) {
        found = 1
      }
    }
    END {
      exit found ? 0 : 1
    }'; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

extension_registration_entries() {
  local registration_output="$1"
  local extension_identifier="$2"

  printf '%s\n' "$registration_output" | /usr/bin/awk -v extension_identifier="$extension_identifier" '
    {
      for (field_index = 1; field_index <= NF; field_index += 1) {
        if ($field_index == extension_identifier) {
          print
          next
        }
      }
    }'
}

extension_registration_present_value() {
  local registration_output="$1"
  local extension_identifier="$2"

  if [ -z "$registration_output" ]; then
    printf 'unknown\n'
  elif [ -n "$(extension_registration_entries "$registration_output" "$extension_identifier")" ]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

extension_registration_activated_enabled_value() {
  local registration_output="$1"
  local extension_identifier="$2"
  local entries

  if [ -z "$registration_output" ]; then
    printf 'unknown\n'
    return
  fi

  entries="$(extension_registration_entries "$registration_output" "$extension_identifier")"
  if [ -z "$entries" ]; then
    printf 'no\n'
  elif printf '%s\n' "$entries" | /usr/bin/awk '
    match($0, /\[[^]]+\]/) {
      bracket = substr($0, RSTART + 1, RLENGTH - 2)
      token_count = split(bracket, status_tokens, /[[:space:]]+/)
      has_activated = 0
      has_enabled = 0
      for (status_index = 1; status_index <= token_count; status_index += 1) {
        if (status_tokens[status_index] == "activated") {
          has_activated = 1
        } else if (status_tokens[status_index] == "enabled") {
          has_enabled = 1
        }
      }
      if (has_activated && has_enabled) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

is_unsigned_integer() {
  local value="$1"

  [[ "$value" =~ ^[0-9]+$ ]]
}

file_byte_count() {
  local file_path="$1"
  local byte_count

  if byte_count="$(/usr/bin/stat -f %z "$file_path" 2>/dev/null)" && is_unsigned_integer "$byte_count"; then
    printf '%s\n' "$byte_count"
    return
  fi

  if byte_count="$(/usr/bin/stat -c %s "$file_path" 2>/dev/null)" && is_unsigned_integer "$byte_count"; then
    printf '%s\n' "$byte_count"
  fi
}

mdls_metadata_value() {
  local metadata_output="$1"
  local metadata_key="$2"

  /usr/bin/awk -v metadata_key="$metadata_key" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, metadata_key) == 1) {
        value = substr(line, length(metadata_key) + 1)
        if (value ~ /^[[:space:]]*=[[:space:]]*/) {
          sub(/^[[:space:]]*=[[:space:]]*/, "", value)
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          gsub(/^"|"$/, "", value)
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          print value
          exit
        }
      }
    }' <<< "$metadata_output"
}

mp4_parser_metadata_output() {
  local video_path="$1"
  local python_bin

  python_bin="$(python3_command)"
  if [ -z "$python_bin" ]; then
    printf 'python3 is not available for bundled-video MP4 metadata parsing.\n'
    return 1
  fi

  if [ ! -f "$VALIDATE_PROJECT_SCRIPT" ]; then
    printf 'MP4 parser source is not available at %s.\n' "$VALIDATE_PROJECT_SCRIPT"
    return 1
  fi

  "$python_bin" - "$VALIDATE_PROJECT_SCRIPT" "$video_path" <<'PY'
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True
parser_path = Path(sys.argv[1])
video_path = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("gareth_validate_project", parser_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

try:
    metadata = module.mp4_video_metadata(video_path)
except Exception as error:
    print(f"MP4 parser error = {error}")
    sys.exit(1)

dimensions = metadata.get("dimensions")
if dimensions is None:
    width = ""
    height = ""
else:
    width, height = dimensions

def metadata_field_value(value):
    return "" if value is None else value

print(f"MP4 parser pixel width = {width}")
print(f"MP4 parser pixel height = {height}")
print(f"MP4 parser frame rate = {metadata_field_value(metadata.get('frame_rate'))}")
print(f"MP4 parser duration seconds = {metadata_field_value(metadata.get('duration_seconds'))}")
PY
}

preferred_metadata_value() {
  local preferred_value="$1"
  local fallback_value="$2"

  case "$preferred_value" in
    ""|"(null)"|"null")
      printf '%s\n' "$fallback_value"
      ;;
    *)
      printf '%s\n' "$preferred_value"
      ;;
  esac
}

metadata_number_matches_expected_value() {
  local actual_value="$1"
  local expected_value="$2"

  /usr/bin/awk -v actual_value="$actual_value" -v expected_value="$expected_value" '
    BEGIN {
      if (actual_value == "" || actual_value == "(null)" || actual_value == "null") {
        print "unknown"
      } else if (actual_value ~ /^-?[0-9]+([.][0-9]+)?$/ && actual_value + 0 == expected_value + 0) {
        print "yes"
      } else {
        print "no"
      }
    }'
}

metadata_positive_number_value() {
  local actual_value="$1"

  /usr/bin/awk -v actual_value="$actual_value" '
    BEGIN {
      if (actual_value == "" || actual_value == "(null)" || actual_value == "null") {
        print "unknown"
      } else if (actual_value ~ /^-?[0-9]+([.][0-9]+)?$/ && actual_value + 0 > 0) {
        print "yes"
      } else {
        print "no"
      }
    }'
}

video_metadata_readiness_value() {
  local pixel_width="$1"
  local pixel_height="$2"
  local frame_rate="$3"
  local duration_seconds="$4"
  local width_ready
  local height_ready
  local frame_rate_ready
  local duration_ready

  width_ready="$(metadata_number_matches_expected_value "$pixel_width" "$EXPECTED_VIDEO_WIDTH")"
  height_ready="$(metadata_number_matches_expected_value "$pixel_height" "$EXPECTED_VIDEO_HEIGHT")"
  frame_rate_ready="$(metadata_number_matches_expected_value "$frame_rate" "$EXPECTED_VIDEO_FRAME_RATE")"
  duration_ready="$(metadata_positive_number_value "$duration_seconds")"

  if [ "$width_ready" = "yes" ] \
    && [ "$height_ready" = "yes" ] \
    && [ "$frame_rate_ready" = "yes" ] \
    && [ "$duration_ready" = "yes" ]; then
    printf 'yes\n'
  elif [ "$width_ready" = "no" ] \
    || [ "$height_ready" = "no" ] \
    || [ "$frame_rate_ready" = "no" ] \
    || [ "$duration_ready" = "no" ]; then
    printf 'no\n'
  else
    printf 'unknown\n'
  fi
}

print_file_sha256() {
  local file_path="$1"
  local checksum

  if [ -x /usr/bin/shasum ]; then
    checksum="$(/usr/bin/shasum -a 256 "$file_path" 2>/dev/null | /usr/bin/awk '{ print $1 }' || true)"
    printf 'Video SHA-256: %s\n' "${checksum:-unknown}"
  elif command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "$file_path" 2>/dev/null | /usr/bin/awk '{ print $1 }' || true)"
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

print_diagnostics_resources() {
  printf 'Diagnostics script path: %s\n' "${BASH_SOURCE[0]}"
  printf 'Diagnostics script directory: %s\n' "$SCRIPT_DIR"
  printf 'Diagnostics parser path: %s\n' "$VALIDATE_PROJECT_SCRIPT"
  printf 'Diagnostics parser source: %s\n' "$DIAGNOSTICS_PARSER_SOURCE"

  if [ -f "$VALIDATE_PROJECT_SCRIPT" ]; then
    printf 'Diagnostics parser available: yes\n'
  else
    printf 'Diagnostics parser available: no\n'
  fi
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
      if [ -z "$readiness_first_blocked_label" ]; then
        readiness_first_blocked_label="$label"
      fi
      ;;
    *)
      readiness_unknown_count=$((readiness_unknown_count + 1))
      if [ -z "$readiness_first_unknown_label" ]; then
        readiness_first_unknown_label="$label"
      fi
      ;;
  esac

  print_yes_no_unknown "$label" "$value"
}

print_missing_app_readiness_checks() {
  print_readiness_check "App bundle identifier ready" "no"
  print_readiness_check "App signature ready" "no"
  print_readiness_check "App System Extension entitlement ready" "no"
  print_readiness_check "App executable ready" "no"
}

print_missing_extension_readiness_checks() {
  print_readiness_check "Extension bundle identifier ready" "no"
  print_readiness_check "Extension signature ready" "no"
  print_readiness_check "Extension host-only entitlement absent" "no"
  print_readiness_check "Extension executable ready" "no"
  print_readiness_check "Extension CMIO Mach service ready" "no"
}

print_missing_bundle_comparison_readiness_checks() {
  print_readiness_check "Bundle versions match ready" "no"
  print_readiness_check "Signing Team match ready" "no"
  print_readiness_check "Application group match ready" "no"
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
  if [ -n "$readiness_first_blocked_label" ]; then
    printf 'Runtime readiness next action: resolve %s\n' "$readiness_first_blocked_label"
  elif [ -n "$readiness_first_unknown_label" ]; then
    printf 'Runtime readiness next action: inspect %s\n' "$readiness_first_unknown_label"
  else
    printf 'Runtime readiness next action: submit the system extension request\n'
  fi
}

print_activation_evidence_summary() {
  local registration_present_value="$1"
  local registration_activated_enabled_value="$2"
  local camera_device_present_value="$3"
  local activation_ready_count=0
  local activation_blocked_count=0
  local activation_unknown_count=0
  local activation_total_count=0
  local activation_first_blocked_label=""
  local activation_first_unknown_label=""
  local activation_result="active"
  local label
  local value

  while IFS='|' read -r label value; do
    activation_total_count=$((activation_total_count + 1))

    case "$value" in
      yes)
        activation_ready_count=$((activation_ready_count + 1))
        ;;
      no)
        activation_blocked_count=$((activation_blocked_count + 1))
        if [ -z "$activation_first_blocked_label" ]; then
          activation_first_blocked_label="$label"
        fi
        ;;
      *)
        activation_unknown_count=$((activation_unknown_count + 1))
        if [ -z "$activation_first_unknown_label" ]; then
          activation_first_unknown_label="$label"
        fi
        ;;
    esac
  done <<EOF
Extension registration entry present|$registration_present_value
Extension registration activated enabled|$registration_activated_enabled_value
Expected virtual camera device present|$camera_device_present_value
EOF

  if [ "$activation_blocked_count" -gt 0 ]; then
    activation_result="blocked"
  elif [ "$activation_unknown_count" -gt 0 ]; then
    activation_result="incomplete"
  fi

  printf 'Runtime activation evidence result: %s\n' "$activation_result"
  printf 'Runtime activation evidence checks ready: %s/%s\n' "$activation_ready_count" "$activation_total_count"
  printf 'Runtime activation evidence checks blocked: %s\n' "$activation_blocked_count"
  printf 'Runtime activation evidence checks unknown: %s\n' "$activation_unknown_count"
  if [ -n "$activation_first_blocked_label" ]; then
    printf 'Runtime activation evidence next action: resolve %s\n' "$activation_first_blocked_label"
  elif [ -n "$activation_first_unknown_label" ]; then
    printf 'Runtime activation evidence next action: inspect %s\n' "$activation_first_unknown_label"
  else
    printf 'Runtime activation evidence next action: open a camera picker and confirm Gareth Video Cam is selectable\n'
  fi
}

reset_readiness_rollup_counters() {
  readiness_ready_count=0
  readiness_blocked_count=0
  readiness_unknown_count=0
  readiness_total_count=0
  readiness_first_blocked_label=""
  readiness_first_unknown_label=""
}

run_readiness_rollup_blocked_self_test() {
  reset_readiness_rollup_counters

  print_readiness_check "Ready fixture" "yes"
  print_readiness_check "Blocked fixture" "no"
  print_readiness_check "Unknown fixture" "unknown"
  print_readiness_rollup
}

run_readiness_rollup_unknown_self_test() {
  reset_readiness_rollup_counters

  print_readiness_check "Ready fixture" "yes"
  print_readiness_check "Unknown fixture" "unknown"
  print_readiness_rollup
}

run_readiness_rollup_ready_self_test() {
  reset_readiness_rollup_counters

  print_readiness_check "Ready fixture" "yes"
  print_readiness_rollup
}

run_missing_runtime_bundles_self_test() {
  local missing_app_path="${TMPDIR:-/tmp}/gareth-runtime-missing-bundles-self-test-$$.app"

  /bin/rm -rf "$missing_app_path"
  reset_readiness_rollup_counters

  print_readiness_check "Application location ready" "$(application_location_readiness_value "$missing_app_path" "$missing_app_path")"
  print_missing_app_readiness_checks
  print_missing_extension_readiness_checks
  print_missing_bundle_comparison_readiness_checks
  print_readiness_check "Bundled video ready" "no"
  print_readiness_check "Bundled video metadata ready" "no"
  print_readiness_rollup
}

run_bundle_version_match_self_test() {
  printf 'Bundle version match fixture: %s\n' "$(bundle_versions_match_readiness_value "1.0" "100" "1.0" "100")"
  printf 'Bundle version short mismatch fixture: %s\n' "$(bundle_versions_match_readiness_value "1.0" "100" "2.0" "100")"
  printf 'Bundle version build mismatch fixture: %s\n' "$(bundle_versions_match_readiness_value "1.0" "100" "1.0" "101")"
  printf 'Bundle version missing fixture: %s\n' "$(bundle_versions_match_readiness_value "1.0" "" "1.0" "100")"
}

run_executable_readiness_self_test() {
  local temp_dir
  local executable_path

  temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gareth-executable.XXXXXX")" || return 1
  executable_path="$temp_dir/Runner"

  printf 'Executable missing name fixture: %s\n' "$(executable_readiness_value "" "$executable_path")"
  printf 'Executable missing file fixture: %s\n' "$(executable_readiness_value "Runner" "$executable_path")"

  : >"$executable_path"
  /bin/chmod 0644 "$executable_path"
  printf 'Executable non-executable fixture: %s\n' "$(executable_readiness_value "Runner" "$executable_path")"

  /bin/chmod 0755 "$executable_path"
  printf 'Executable ready fixture: %s\n' "$(executable_readiness_value "Runner" "$executable_path")"

  /bin/rm -rf "$temp_dir"
}

run_application_identity_self_test() {
  local temp_dir
  local existing_app_path
  local blank_app_path
  local blank_info_value
  local blank_mach_service_value
  local scalar_app_path
  local scalar_info_value
  local scalar_mach_service_value
  local string_app_path
  local string_info_value
  local string_mach_service_value
  local untrimmed_app_path
  local untrimmed_info_value
  local untrimmed_mach_service_value

  temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gareth-app-location.XXXXXX")" || return 1
  existing_app_path="$temp_dir/GarethVideoCam.app"
  string_app_path="$temp_dir/StringMetadata.app"
  scalar_app_path="$temp_dir/ScalarMetadata.app"
  blank_app_path="$temp_dir/BlankMetadata.app"
  untrimmed_app_path="$temp_dir/UntrimmedMetadata.app"
  /bin/mkdir -p "$existing_app_path"
  /bin/mkdir -p "$string_app_path/Contents" "$scalar_app_path/Contents" "$blank_app_path/Contents" "$untrimmed_app_path/Contents"

  cat >"$string_app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.StringMetadata</string>
  <key>CMIOExtension</key>
  <dict>
    <key>CMIOExtensionMachServiceName</key>
    <string>com.example.StringMetadata.Extension</string>
  </dict>
</dict>
</plist>
PLIST

  cat >"$scalar_app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <true/>
  <key>CMIOExtension</key>
  <dict>
    <key>CMIOExtensionMachServiceName</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

  cat >"$blank_app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>   </string>
  <key>CMIOExtension</key>
  <dict>
    <key>CMIOExtensionMachServiceName</key>
    <string>   </string>
  </dict>
</dict>
</plist>
PLIST

  cat >"$untrimmed_app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string> com.example.UntrimmedMetadata </string>
  <key>CMIOExtension</key>
  <dict>
    <key>CMIOExtensionMachServiceName</key>
    <string> com.example.UntrimmedMetadata.Extension </string>
  </dict>
</dict>
</plist>
PLIST

  printf 'App path match fixture: %s\n' "$(path_matches_expected_value "/Applications/GarethVideoCam.app" "/Applications/GarethVideoCam.app")"
  printf 'App path mismatch fixture: %s\n' "$(path_matches_expected_value "/Users/example/GarethVideoCam.app" "/Applications/GarethVideoCam.app")"
  printf 'Application location existing fixture: %s\n' "$(application_location_readiness_value "$existing_app_path" "$existing_app_path")"
  printf 'Application location missing fixture: %s\n' "$(application_location_readiness_value "$temp_dir/Missing.app" "$temp_dir/Missing.app")"
  printf 'Application location mismatch fixture: %s\n' "$(application_location_readiness_value "$existing_app_path" "/Applications/GarethVideoCam.app")"
  printf 'Bundle identifier match fixture: %s\n' "$(bundle_identifier_matches_expected_value "$APP_ID" "$APP_ID")"
  printf 'Bundle identifier mismatch fixture: %s\n' "$(bundle_identifier_matches_expected_value "com.example.WrongApp" "$APP_ID")"
  printf 'Bundle identifier missing fixture: %s\n' "$(bundle_identifier_matches_expected_value "" "$APP_ID")"
  string_info_value="$(read_info_plist_value "$string_app_path" CFBundleIdentifier)"
  scalar_info_value="$(read_info_plist_value "$scalar_app_path" CFBundleIdentifier)"
  blank_info_value="$(read_info_plist_value "$blank_app_path" CFBundleIdentifier)"
  untrimmed_info_value="$(read_info_plist_value "$untrimmed_app_path" CFBundleIdentifier)"
  local EXTENSION_INFO_PLIST="$string_app_path/Contents/Info.plist"
  string_mach_service_value="$(read_extension_mach_service_name)"
  EXTENSION_INFO_PLIST="$scalar_app_path/Contents/Info.plist"
  scalar_mach_service_value="$(read_extension_mach_service_name)"
  EXTENSION_INFO_PLIST="$blank_app_path/Contents/Info.plist"
  blank_mach_service_value="$(read_extension_mach_service_name)"
  EXTENSION_INFO_PLIST="$untrimmed_app_path/Contents/Info.plist"
  untrimmed_mach_service_value="$(read_extension_mach_service_name)"
  printf 'Info.plist string metadata fixture: %s\n' "${string_info_value:-missing}"
  printf 'Info.plist scalar metadata fixture: %s\n' "${scalar_info_value:-missing}"
  printf 'Info.plist blank string metadata fixture: %s\n' "${blank_info_value:-missing}"
  printf 'Info.plist untrimmed string metadata fixture: %s\n' "${untrimmed_info_value:-missing}"
  printf 'Info.plist nested string metadata fixture: %s\n' "${string_mach_service_value:-missing}"
  printf 'Info.plist nested scalar metadata fixture: %s\n' "${scalar_mach_service_value:-missing}"
  printf 'Info.plist nested blank string metadata fixture: %s\n' "${blank_mach_service_value:-missing}"
  printf 'Info.plist nested untrimmed string metadata fixture: %s\n' "${untrimmed_mach_service_value:-missing}"

  /bin/rm -rf "$temp_dir"
}

run_team_identifier_self_test() {
  local multiple_team_identifiers=$'ABCDE12345\nZYXWV98765'

  printf 'Team ID match fixture: %s\n' "$(team_identifiers_match_value "ABCDE12345" "ABCDE12345")"
  printf 'Team ID mismatch fixture: %s\n' "$(team_identifiers_match_value "ABCDE12345" "ZYXWV98765")"
  printf 'Team ID missing app fixture: %s\n' "$(team_identifiers_match_value "" "ABCDE12345")"
  printf 'Team ID missing extension fixture: %s\n' "$(team_identifiers_match_value "ABCDE12345" "")"
  printf 'Team ID short fixture: %s\n' "$(team_identifiers_match_value "ABC123" "ABC123")"
  printf 'Team ID dotted fixture: %s\n' "$(team_identifiers_match_value "ABCDE12345.com" "ABCDE12345.com")"
  printf 'Team ID multiple app fixture: %s\n' "$(team_identifiers_match_value "$multiple_team_identifiers" "ABCDE12345")"
  printf 'Team ID multiple extension fixture: %s\n' "$(team_identifiers_match_value "ABCDE12345" "$multiple_team_identifiers")"
}

run_extension_host_entitlement_self_test() {
  local all_architectures_present=$'yes\nyes'
  local missing_architecture=$'yes\nno'
  local unreadable_architecture=$'yes\nunknown'
  local temp_dir
  local malformed_entitlements
  local malformed_boolean_value
  local scalar_entitlements
  local scalar_boolean_status
  local scalar_boolean_value

  printf 'Boolean entitlement all architectures present fixture: %s\n' "$(boolean_entitlement_all_architectures_value "$all_architectures_present")"
  printf 'Boolean entitlement missing architecture fixture: %s\n' "$(boolean_entitlement_all_architectures_value "$missing_architecture")"
  printf 'Boolean entitlement unreadable architecture fixture: %s\n' "$(boolean_entitlement_all_architectures_value "$unreadable_architecture")"
  printf 'Boolean entitlement empty architecture fixture: %s\n' "$(boolean_entitlement_all_architectures_value "")"
  temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gareth-boolean-entitlements.XXXXXX")" || return 1
  malformed_entitlements="$temp_dir/bad-entitlements.plist"
  printf 'not a plist' >"$malformed_entitlements"
  malformed_boolean_value="$(read_boolean_entitlement_from_entitlements_file "$malformed_entitlements" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT" 2>/dev/null || printf 'unknown\n')"
  printf 'Boolean entitlement malformed plist fixture: %s\n' "$malformed_boolean_value"
  scalar_entitlements="$temp_dir/scalar-entitlements.plist"
  cat >"$scalar_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>${HOST_SYSTEM_EXTENSION_ENTITLEMENT}</key>
  <string>true</string>
</dict>
</plist>
PLIST
  scalar_boolean_value="$(read_boolean_entitlement_from_entitlements_file "$scalar_entitlements" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT" 2>/dev/null || printf 'unknown\n')"
  printf 'Boolean entitlement scalar fixture: %s\n' "$scalar_boolean_value"
  set +e
  scalar_boolean_value="$(GARETH_DIAGNOSTICS_SKIP_PYTHON=1 read_boolean_entitlement_from_entitlements_file "$scalar_entitlements" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT" 2>/dev/null)"
  scalar_boolean_status=$?
  set -e
  if [ "$scalar_boolean_status" -eq 0 ]; then
    printf 'Boolean entitlement fallback scalar fixture: %s\n' "$scalar_boolean_value"
  else
    printf 'Boolean entitlement fallback scalar fixture: unknown\n'
  fi
  /bin/rm -rf "$temp_dir"
  printf 'Extension host entitlement valid absent fixture: %s\n' "$(extension_host_only_entitlement_absent_readiness_value "yes" "no")"
  printf 'Extension host entitlement valid present fixture: %s\n' "$(extension_host_only_entitlement_absent_readiness_value "yes" "yes")"
  printf 'Extension host entitlement invalid signature fixture: %s\n' "$(extension_host_only_entitlement_absent_readiness_value "no" "no")"
  printf 'Extension host entitlement unreadable fixture: %s\n' "$(extension_host_only_entitlement_absent_readiness_value "yes" "unknown")"
}

run_mach_service_self_test() {
  printf 'Mach service direct fixture resolved: %s\n' "$(mach_service_resolved_value "$EXTENSION_ID")"
  printf 'Mach service direct fixture matches expected: %s\n' "$(mach_service_matches_expected_value "$EXTENSION_ID" "$EXTENSION_ID")"
  printf 'Mach service direct fixture ready: %s\n' "$(mach_service_readiness_value "$EXTENSION_ID" "$EXTENSION_ID")"
  printf 'Mach service team-prefixed fixture ready: %s\n' "$(mach_service_readiness_value "ABCDE12345.$EXTENSION_ID" "$EXTENSION_ID")"
  printf 'Mach service short-prefix fixture ready: %s\n' "$(mach_service_readiness_value "ABC123.$EXTENSION_ID" "$EXTENSION_ID")"
  printf 'Mach service dotted-prefix fixture ready: %s\n' "$(mach_service_readiness_value "com.example.$EXTENSION_ID" "$EXTENSION_ID")"
  printf 'Mach service unresolved fixture resolved: %s\n' "$(mach_service_resolved_value '$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)')"
  printf 'Mach service wrong fixture matches expected: %s\n' "$(mach_service_matches_expected_value "com.example.WrongMachService" "$EXTENSION_ID")"
  printf 'Mach service missing fixture ready: %s\n' "$(mach_service_readiness_value "" "$EXTENSION_ID")"
}

run_application_group_self_test() {
  local direct_group="$APP_GROUP_BASE_ID"
  local shared_group="ABCDE12345.$APP_GROUP_BASE_ID"
  local other_team_group="ZYXWV98765.$APP_GROUP_BASE_ID"
  local short_prefix_group="ABC123.$APP_GROUP_BASE_ID"
  local wrong_group="ABCDE12345.com.example.Other"
  local dotted_prefix_group="com.example.$APP_GROUP_BASE_ID"
  local formatted_groups
  local common_groups
  local missing_common_groups
  local temp_dir
  local malformed_entitlements
  local non_string_entitlements
  local untrimmed_entitlements
  local scalar_entitlements
  local malformed_entitlements_status

  printf 'Application group direct fixture ready: %s\n' "$(application_groups_ready_value "$direct_group" "$direct_group")"
  printf 'Application group shared fixture ready: %s\n' "$(application_groups_ready_value "$shared_group" "$shared_group")"
  printf 'Application group missing fixture ready: %s\n' "$(application_groups_ready_value "" "$shared_group")"
  printf 'Application group mismatched fixture ready: %s\n' "$(application_groups_ready_value "$shared_group" "$other_team_group")"
  printf 'Application group short-prefix fixture ready: %s\n' "$(application_groups_ready_value "$short_prefix_group" "$short_prefix_group")"
  printf 'Application group wrong suffix fixture ready: %s\n' "$(application_groups_ready_value "$wrong_group" "$wrong_group")"
  printf 'Application group dotted-prefix fixture ready: %s\n' "$(application_groups_ready_value "$dotted_prefix_group" "$dotted_prefix_group")"
  printf 'Application group unresolved fixture ready: %s\n' "$(application_groups_ready_value '$(TeamIdentifierPrefix)com.garethpaul.GarethVideoCam' '$(TeamIdentifierPrefix)com.garethpaul.GarethVideoCam')"
  printf 'Application group empty format fixture: %s\n' "$(format_application_groups "")"
  formatted_groups="$(format_application_groups "$shared_group"$'\n'"$other_team_group")"
  printf 'Application group list format fixture: %s\n' "$formatted_groups"
  common_groups="$(common_application_groups_for_architectures "$shared_group"$'\n'"$other_team_group"$'\n'"$shared_group" 2)"
  printf 'Application group all architectures common fixture: %s\n' "$(format_application_groups "$common_groups")"
  missing_common_groups="$(common_application_groups_for_architectures "$shared_group"$'\n'"$other_team_group" 2)"
  printf 'Application group missing architecture common fixture: %s\n' "$(format_application_groups "$missing_common_groups")"

  temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gareth-app-groups.XXXXXX")" || return 1
  malformed_entitlements="$temp_dir/bad-entitlements.plist"
  printf 'not a plist' >"$malformed_entitlements"
  set +e
  read_application_groups_from_entitlements_file "$malformed_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group malformed entitlements readable fixture: yes\n'
  else
    printf 'Application group malformed entitlements readable fixture: no\n'
  fi
  scalar_entitlements="$temp_dir/scalar-entitlements.plist"
  cat >"$scalar_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>${APP_GROUP_ENTITLEMENT}</key>
  <string>ABCDE12345.${APP_GROUP_BASE_ID}</string>
</dict>
</plist>
PLIST
  set +e
  read_application_groups_from_entitlements_file "$scalar_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group scalar entitlements readable fixture: yes\n'
  else
    printf 'Application group scalar entitlements readable fixture: no\n'
  fi
  non_string_entitlements="$temp_dir/non-string-entitlements.plist"
  cat >"$non_string_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>${APP_GROUP_ENTITLEMENT}</key>
  <array>
    <string>ABCDE12345.${APP_GROUP_BASE_ID}</string>
    <true/>
  </array>
</dict>
</plist>
PLIST
  set +e
  read_application_groups_from_entitlements_file "$non_string_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group non-string entitlements readable fixture: yes\n'
  else
    printf 'Application group non-string entitlements readable fixture: no\n'
  fi
  untrimmed_entitlements="$temp_dir/untrimmed-entitlements.plist"
  cat >"$untrimmed_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>${APP_GROUP_ENTITLEMENT}</key>
  <array>
    <string> ABCDE12345.${APP_GROUP_BASE_ID} </string>
  </array>
</dict>
</plist>
PLIST
  set +e
  read_application_groups_from_entitlements_file "$untrimmed_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group untrimmed entitlements readable fixture: yes\n'
  else
    printf 'Application group untrimmed entitlements readable fixture: no\n'
  fi
  set +e
  GARETH_DIAGNOSTICS_SKIP_PYTHON=1 read_application_groups_from_entitlements_file "$scalar_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group fallback scalar entitlements readable fixture: yes\n'
  else
    printf 'Application group fallback scalar entitlements readable fixture: no\n'
  fi
  set +e
  GARETH_DIAGNOSTICS_SKIP_PYTHON=1 read_application_groups_from_entitlements_file "$non_string_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group fallback non-string entitlements readable fixture: yes\n'
  else
    printf 'Application group fallback non-string entitlements readable fixture: no\n'
  fi
  set +e
  GARETH_DIAGNOSTICS_SKIP_PYTHON=1 read_application_groups_from_entitlements_file "$untrimmed_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group fallback untrimmed entitlements readable fixture: yes\n'
  else
    printf 'Application group fallback untrimmed entitlements readable fixture: no\n'
  fi
  set +e
  GARETH_DIAGNOSTICS_SKIP_PYTHON=1 read_application_groups_from_entitlements_file "$malformed_entitlements" >/dev/null 2>/dev/null
  malformed_entitlements_status=$?
  set -e
  if [ "$malformed_entitlements_status" -eq 0 ]; then
    printf 'Application group fallback malformed entitlements readable fixture: yes\n'
  else
    printf 'Application group fallback malformed entitlements readable fixture: no\n'
  fi
  /bin/rm -rf "$temp_dir"
}

run_camera_device_self_test() {
  local present_inventory
  local missing_inventory
  local substring_inventory

  present_inventory=$'Camera:\n\n    Gareth Video Cam:\n\n      Model ID: Virtual Camera\n'
  missing_inventory=$'Camera:\n\n    FaceTime HD Camera:\n\n      Model ID: Built-In Camera\n'
  substring_inventory=$'Camera:\n\n    Not Gareth Video Cam:\n\n      Model ID: Other Virtual Camera\n'

  printf 'Camera device present fixture: %s\n' "$(camera_device_present_value "$present_inventory" "$EXPECTED_CAMERA_NAME")"
  printf 'Camera device missing fixture: %s\n' "$(camera_device_present_value "$missing_inventory" "$EXPECTED_CAMERA_NAME")"
  printf 'Camera device substring fixture: %s\n' "$(camera_device_present_value "$substring_inventory" "$EXPECTED_CAMERA_NAME")"
  printf 'Camera device empty fixture: %s\n' "$(camera_device_present_value "" "$EXPECTED_CAMERA_NAME")"
}

run_video_metadata_self_test() {
  local metadata_output
  local spaced_metadata_output

  metadata_output=$'kMDItemPixelWidth = 1280\nkMDItemPixelHeight = 720\nkMDItemDurationSeconds = 12.5\n'
  spaced_metadata_output=$'  kMDItemPixelWidth   =   "1280"  \n  kMDItemDurationSeconds   =   " 12.5 "  \n'

  printf 'Video metadata parsed width fixture: %s\n' "$(mdls_metadata_value "$metadata_output" kMDItemPixelWidth)"
  printf 'Video metadata parsed height fixture: %s\n' "$(mdls_metadata_value "$metadata_output" kMDItemPixelHeight)"
  printf 'Video metadata parsed duration fixture: %s\n' "$(mdls_metadata_value "$metadata_output" kMDItemDurationSeconds)"
  printf 'Video metadata spaced width fixture: %s\n' "$(mdls_metadata_value "$spaced_metadata_output" kMDItemPixelWidth)"
  printf 'Video metadata quoted duration fixture: %s\n' "$(mdls_metadata_value "$spaced_metadata_output" kMDItemDurationSeconds)"
  printf 'Video metadata preferred parser fixture: %s\n' "$(preferred_metadata_value "1280" "640")"
  printf 'Video metadata blank fallback fixture: %s\n' "$(preferred_metadata_value "" "640")"
  printf 'Video metadata null fallback fixture: %s\n' "$(preferred_metadata_value "null" "640")"
  printf 'Video metadata parenthesized null fallback fixture: %s\n' "$(preferred_metadata_value "(null)" "640")"
  printf 'Video metadata ready fixture: %s\n' "$(video_metadata_readiness_value "1280" "720" "24" "12.5")"
  printf 'Video metadata decimal fixture: %s\n' "$(video_metadata_readiness_value "1280.0" "720.0" "24.0" "12.5")"
  printf 'Video metadata non-numeric width fixture: %s\n' "$(video_metadata_readiness_value "wide" "720" "24" "12.5")"
  printf 'Video metadata wrong width fixture: %s\n' "$(video_metadata_readiness_value "640" "720" "24" "12.5")"
  printf 'Video metadata wrong frame rate fixture: %s\n' "$(video_metadata_readiness_value "1280" "720" "30" "12.5")"
  printf 'Video metadata missing frame rate fixture: %s\n' "$(video_metadata_readiness_value "1280" "720" "" "12.5")"
  printf 'Video metadata missing duration fixture: %s\n' "$(video_metadata_readiness_value "1280" "720" "24" "")"
  printf 'Video metadata zero duration fixture: %s\n' "$(video_metadata_readiness_value "1280" "720" "24" "0")"
  printf 'Video metadata negative duration fixture: %s\n' "$(video_metadata_readiness_value "1280" "720" "24" "-1")"
}

run_file_byte_count_self_test() {
  local temp_dir
  local fixture_path

  temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gareth-byte-count.XXXXXX")" || return 1
  fixture_path="$temp_dir/video.bin"

  printf 'abcde' >"$fixture_path"
  printf 'File byte count fixture: %s\n' "$(file_byte_count "$fixture_path")"
  print_file_sha256 "$temp_dir/missing-video.mp4"

  /bin/rm -rf "$temp_dir"
}

run_video_parser_self_test() {
  local video_fixture="${GARETH_DIAGNOSTICS_VIDEO_FIXTURE:-$VIDEO_PATH}"
  local parser_output
  local parser_width
  local parser_height
  local parser_frame_rate
  local parser_duration

  parser_output="$(mp4_parser_metadata_output "$video_fixture" 2>&1 || true)"
  printf '%s\n' "$parser_output"
  parser_width="$(mdls_metadata_value "$parser_output" "MP4 parser pixel width")"
  parser_height="$(mdls_metadata_value "$parser_output" "MP4 parser pixel height")"
  parser_frame_rate="$(mdls_metadata_value "$parser_output" "MP4 parser frame rate")"
  parser_duration="$(mdls_metadata_value "$parser_output" "MP4 parser duration seconds")"

  printf 'Video parser pixel width fixture: %s\n' "$parser_width"
  printf 'Video parser pixel height fixture: %s\n' "$parser_height"
  printf 'Video parser frame rate fixture: %s\n' "$parser_frame_rate"
  printf 'Video parser duration fixture: %s\n' "$parser_duration"
  printf 'Video parser metadata ready fixture: %s\n' "$(video_metadata_readiness_value "$parser_width" "$parser_height" "$parser_frame_rate" "$parser_duration")"
}

run_registration_self_test() {
  local active_output
  local reversed_output
  local waiting_output
  local deactivated_output
  local longer_identifier_output
  local missing_output

  active_output=$'2 extension(s)\n--- com.apple.system_extension.cmio\n* * ABCDE12345 com.garethpaul.GarethVideoCam.Extension (1.18/7) Gareth Video Cam Extension [activated enabled]\n'
  reversed_output=$'1 extension(s)\n--- com.apple.system_extension.cmio\n* * ABCDE12345 com.garethpaul.GarethVideoCam.Extension (1.18/7) Gareth Video Cam Extension [enabled activated]\n'
  waiting_output=$'1 extension(s)\n--- com.apple.system_extension.cmio\n* * ABCDE12345 com.garethpaul.GarethVideoCam.Extension (1.18/7) Gareth Video Cam Extension [activated waiting for user]\n'
  deactivated_output=$'1 extension(s)\n--- com.apple.system_extension.cmio\n* * ABCDE12345 com.garethpaul.GarethVideoCam.Extension (1.18/7) Gareth Video Cam Extension [deactivated enabled]\n'
  longer_identifier_output=$'1 extension(s)\n--- com.apple.system_extension.cmio\n* * ABCDE12345 com.garethpaul.GarethVideoCam.Extension.Helper (1.18/7) Gareth Video Cam Extension Helper [activated enabled]\n'
  missing_output=$'0 extension(s)\n'

  printf 'Registration active fixture present: %s\n' "$(extension_registration_present_value "$active_output" "$EXTENSION_ID")"
  printf 'Registration active fixture activated enabled: %s\n' "$(extension_registration_activated_enabled_value "$active_output" "$EXTENSION_ID")"
  printf 'Registration reversed fixture activated enabled: %s\n' "$(extension_registration_activated_enabled_value "$reversed_output" "$EXTENSION_ID")"
  printf 'Registration waiting fixture activated enabled: %s\n' "$(extension_registration_activated_enabled_value "$waiting_output" "$EXTENSION_ID")"
  printf 'Registration deactivated fixture activated enabled: %s\n' "$(extension_registration_activated_enabled_value "$deactivated_output" "$EXTENSION_ID")"
  printf 'Registration longer identifier fixture present: %s\n' "$(extension_registration_present_value "$longer_identifier_output" "$EXTENSION_ID")"
  printf 'Registration longer identifier fixture activated enabled: %s\n' "$(extension_registration_activated_enabled_value "$longer_identifier_output" "$EXTENSION_ID")"
  printf 'Registration missing fixture present: %s\n' "$(extension_registration_present_value "$missing_output" "$EXTENSION_ID")"
  printf 'Registration empty fixture present: %s\n' "$(extension_registration_present_value "" "$EXTENSION_ID")"
}

run_activation_evidence_self_test() {
  print_activation_evidence_summary "yes" "yes" "yes"
  print_activation_evidence_summary "no" "no" "yes"
  print_activation_evidence_summary "yes" "unknown" "yes"
  print_activation_evidence_summary "unknown" "unknown" "unknown"
}

case "${GARETH_DIAGNOSTICS_SELF_TEST:-}" in
  resource-discovery)
    print_diagnostics_resources
    exit 0
    ;;
  readiness-rollup|readiness-rollup-blocked)
    run_readiness_rollup_blocked_self_test
    exit 0
    ;;
  readiness-rollup-unknown)
    run_readiness_rollup_unknown_self_test
    exit 0
    ;;
  readiness-rollup-ready)
    run_readiness_rollup_ready_self_test
    exit 0
    ;;
  missing-runtime-bundles)
    run_missing_runtime_bundles_self_test
    exit 0
    ;;
  bundle-version-match)
    run_bundle_version_match_self_test
    exit 0
    ;;
  executable-readiness)
    run_executable_readiness_self_test
    exit 0
    ;;
  application-identity)
    run_application_identity_self_test
    exit 0
    ;;
  team-id)
    run_team_identifier_self_test
    exit 0
    ;;
  extension-host-entitlement)
    run_extension_host_entitlement_self_test
    exit 0
    ;;
  mach-service)
    run_mach_service_self_test
    exit 0
    ;;
  application-group)
    run_application_group_self_test
    exit 0
    ;;
  camera-device)
    run_camera_device_self_test
    exit 0
    ;;
  video-metadata)
    run_video_metadata_self_test
    exit 0
    ;;
  file-byte-count)
    run_file_byte_count_self_test
    exit 0
    ;;
  video-parser)
    run_video_parser_self_test
    exit 0
    ;;
  registration)
    run_registration_self_test
    exit 0
    ;;
  activation-evidence)
    run_activation_evidence_self_test
    exit 0
    ;;
esac

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
run_if_available xcode-select -p
run_if_available xcodebuild -version
run_if_available swift --version
run_if_available xcrun --sdk macosx --show-sdk-version
run_if_available xcrun --sdk macosx --show-sdk-path

section "Diagnostics Resources"
print_diagnostics_resources

section "Application"
printf 'App path: %s\n' "$APP_PATH"
if [ -d "$APP_PATH" ]; then
  /usr/bin/codesign --verify --all-architectures --deep --strict --verbose=2 "$APP_PATH" 2>&1 || true
  /usr/bin/codesign -d --all-architectures -v "$APP_PATH" 2>&1 || true
  print_signed_entitlements "App" "$APP_PATH"
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

section "Application Runtime Metadata"
if [ -d "$APP_PATH" ]; then
  app_executable="$(read_info_plist_value "$APP_PATH" CFBundleExecutable)"
  app_executable_path="${APP_PATH}/Contents/MacOS/${app_executable}"
  app_executable_architectures="$(bundle_executable_architectures "$APP_PATH")"

  printf 'App CFBundleExecutable: %s\n' "${app_executable:-unknown}"
  if [ -n "$app_executable" ]; then
    printf 'App executable path: %s\n' "$app_executable_path"
    if [ -f "$app_executable_path" ]; then
      printf 'App executable exists: yes\n'
      if [ -x "$app_executable_path" ]; then
        printf 'App executable is executable: yes\n'
      else
        printf 'App executable is executable: no\n'
      fi
    else
      printf 'App executable exists: no\n'
      printf 'App executable is executable: no\n'
    fi
  else
    printf 'App executable path: unknown\n'
    printf 'App executable exists: unknown\n'
    printf 'App executable is executable: unknown\n'
  fi

  if [ -n "$app_executable_architectures" ]; then
    printf 'App executable architectures: %s\n' "$(format_line_values "$app_executable_architectures")"
  else
    printf 'App executable architectures: unknown\n'
  fi
else
  printf 'Application runtime metadata requires the app bundle.\n'
fi

section "Quarantine Check"
print_quarantine_status "App" "$APP_PATH"
print_quarantine_status "Extension" "$EXTENSION_PATH"

section "Embedded System Extension"
printf 'Extension path: %s\n' "$EXTENSION_PATH"
if [ -d "$EXTENSION_PATH" ]; then
  /usr/bin/codesign --verify --all-architectures --strict --verbose=2 "$EXTENSION_PATH" 2>&1 || true
  /usr/bin/codesign -d --all-architectures -v "$EXTENSION_PATH" 2>&1 || true
  print_signed_entitlements "Extension" "$EXTENSION_PATH"
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
  extension_executable_architectures="$(bundle_executable_architectures "$EXTENSION_PATH")"
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
  if [ -n "$extension_executable_architectures" ]; then
    printf 'Extension executable architectures: %s\n' "$(format_line_values "$extension_executable_architectures")"
  else
    printf 'Extension executable architectures: unknown\n'
  fi
  printf 'Extension CMIO Mach service: %s\n' "${extension_mach_service_name:-unknown}"
  printf 'Extension CMIO Mach service resolved: %s\n' "$(mach_service_resolved_value "$extension_mach_service_name")"
  printf 'Extension CMIO Mach service matches expected identifier: %s\n' "$(mach_service_matches_expected_value "$extension_mach_service_name" "$EXTENSION_ID")"
else
  printf 'Extension runtime metadata requires the embedded system extension bundle.\n'
fi

video_pixel_width=""
video_pixel_height=""
video_frame_rate=""
video_duration_seconds=""

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
  printf 'Expected video pixel width: %s\n' "$EXPECTED_VIDEO_WIDTH"
  printf 'Expected video pixel height: %s\n' "$EXPECTED_VIDEO_HEIGHT"
  printf 'Expected video frame rate: %s\n' "$EXPECTED_VIDEO_FRAME_RATE"
  if command -v mdls >/dev/null 2>&1; then
    video_metadata_output="$(mdls \
      -name kMDItemCodecs \
      -name kMDItemPixelWidth \
      -name kMDItemPixelHeight \
      -name kMDItemDurationSeconds \
      "$VIDEO_PATH" 2>&1 || true)"
    printf '%s\n' "$video_metadata_output"
    video_pixel_width="$(mdls_metadata_value "$video_metadata_output" kMDItemPixelWidth)"
    video_pixel_height="$(mdls_metadata_value "$video_metadata_output" kMDItemPixelHeight)"
    video_duration_seconds="$(mdls_metadata_value "$video_metadata_output" kMDItemDurationSeconds)"
  else
    printf 'mdls is not available on this host.\n'
  fi
  video_parser_output="$(mp4_parser_metadata_output "$VIDEO_PATH" 2>&1 || true)"
  printf '%s\n' "$video_parser_output"
  parsed_video_pixel_width="$(mdls_metadata_value "$video_parser_output" "MP4 parser pixel width")"
  parsed_video_pixel_height="$(mdls_metadata_value "$video_parser_output" "MP4 parser pixel height")"
  parsed_video_frame_rate="$(mdls_metadata_value "$video_parser_output" "MP4 parser frame rate")"
  parsed_video_duration_seconds="$(mdls_metadata_value "$video_parser_output" "MP4 parser duration seconds")"
  video_pixel_width="$(preferred_metadata_value "$parsed_video_pixel_width" "$video_pixel_width")"
  video_pixel_height="$(preferred_metadata_value "$parsed_video_pixel_height" "$video_pixel_height")"
  video_frame_rate="$(preferred_metadata_value "$parsed_video_frame_rate" "$video_frame_rate")"
  video_duration_seconds="$(preferred_metadata_value "$parsed_video_duration_seconds" "$video_duration_seconds")"
  print_yes_no_unknown "Video pixel width ready" "$(metadata_number_matches_expected_value "$video_pixel_width" "$EXPECTED_VIDEO_WIDTH")"
  print_yes_no_unknown "Video pixel height ready" "$(metadata_number_matches_expected_value "$video_pixel_height" "$EXPECTED_VIDEO_HEIGHT")"
  print_yes_no_unknown "Video frame rate ready" "$(metadata_number_matches_expected_value "$video_frame_rate" "$EXPECTED_VIDEO_FRAME_RATE")"
  print_yes_no_unknown "Video duration ready" "$(metadata_positive_number_value "$video_duration_seconds")"
  print_yes_no_unknown "Video metadata ready" "$(video_metadata_readiness_value "$video_pixel_width" "$video_pixel_height" "$video_frame_rate" "$video_duration_seconds")"
else
  printf 'Video resource exists: no\n'
  printf 'Expected bundled video resource was not found.\n'
  print_yes_no_unknown "Video metadata ready" "no"
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

section "Bundle Version Match"
if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  app_short_version="$(read_info_plist_value "$APP_PATH" CFBundleShortVersionString)"
  app_build_version="$(read_info_plist_value "$APP_PATH" CFBundleVersion)"
  extension_short_version="$(read_info_plist_value "$EXTENSION_PATH" CFBundleShortVersionString)"
  extension_build_version="$(read_info_plist_value "$EXTENSION_PATH" CFBundleVersion)"

  printf 'App bundle short version: %s\n' "${app_short_version:-unknown}"
  printf 'App bundle build version: %s\n' "${app_build_version:-unknown}"
  printf 'Extension bundle short version: %s\n' "${extension_short_version:-unknown}"
  printf 'Extension bundle build version: %s\n' "${extension_build_version:-unknown}"

  if [ -n "$app_short_version" ] && [ -n "$extension_short_version" ] && [ "$app_short_version" = "$extension_short_version" ]; then
    printf 'Bundle short versions match: yes\n'
  else
    printf 'Bundle short versions match: no\n'
  fi

  if [ -n "$app_build_version" ] && [ -n "$extension_build_version" ] && [ "$app_build_version" = "$extension_build_version" ]; then
    printf 'Bundle build versions match: yes\n'
  else
    printf 'Bundle build versions match: no\n'
  fi
else
  printf 'Bundle version comparison requires both the app and embedded system extension bundles.\n'
fi

section "Signing Team Match"
if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  app_team_identifier=""
  extension_team_identifier=""

  if app_team_identifier="$(read_team_identifier "$APP_PATH")"; then
    printf 'App team identifier: %s\n' "$(format_line_values "$app_team_identifier")"
  else
    printf 'App team identifier: unknown\n'
  fi

  if extension_team_identifier="$(read_team_identifier "$EXTENSION_PATH")"; then
    printf 'Extension team identifier: %s\n' "$(format_line_values "$extension_team_identifier")"
  else
    printf 'Extension team identifier: unknown\n'
  fi

  printf 'Team identifiers match: %s\n' "$(team_identifiers_match_value "$app_team_identifier" "$extension_team_identifier")"
else
  printf 'Signing team comparison requires both the app and embedded system extension bundles.\n'
fi

section "Entitlement Check"
printf 'Expected app System Extension entitlement: %s\n' "$HOST_SYSTEM_EXTENSION_ENTITLEMENT"
printf 'Expected application group suffix: %s\n' "$APP_GROUP_BASE_ID"
app_application_groups=""
app_application_groups_readable="no"
extension_application_groups=""
extension_application_groups_readable="no"
if [ -d "$APP_PATH" ]; then
  app_system_extension_entitlement_present="$(boolean_entitlement_value "$APP_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT")"
  if [ "$app_system_extension_entitlement_present" = "unknown" ]; then
    printf 'App System Extension entitlement present: unknown; signed entitlements could not be read.\n'
  elif [ "$app_system_extension_entitlement_present" = "yes" ]; then
    printf 'App System Extension entitlement present: yes\n'
  else
    printf 'App System Extension entitlement present: no\n'
  fi

  if app_application_groups="$(read_application_groups "$APP_PATH")"; then
    app_application_groups_readable="yes"
    printf 'App application groups: %s\n' "$(format_application_groups "$app_application_groups")"
    printf 'App expected application group present: %s\n' "$(application_groups_expected_present_value "$app_application_groups")"
  else
    printf 'App application groups: unknown; signed entitlements could not be read.\n'
    printf 'App expected application group present: unknown\n'
  fi
else
  printf 'App System Extension entitlement present: unknown; app bundle is missing.\n'
  printf 'App application groups: unknown; app bundle is missing.\n'
  printf 'App expected application group present: unknown\n'
fi

if [ -d "$EXTENSION_PATH" ]; then
  extension_host_only_entitlement_present="$(boolean_entitlement_value "$EXTENSION_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT")"
  if [ "$extension_host_only_entitlement_present" = "unknown" ]; then
    printf 'Extension carries host-only System Extension entitlement: unknown; signed entitlements could not be read.\n'
  elif [ "$extension_host_only_entitlement_present" = "yes" ]; then
    printf 'Extension carries host-only System Extension entitlement: yes\n'
  else
    printf 'Extension carries host-only System Extension entitlement: no\n'
  fi

  if extension_application_groups="$(read_application_groups "$EXTENSION_PATH")"; then
    extension_application_groups_readable="yes"
    printf 'Extension application groups: %s\n' "$(format_application_groups "$extension_application_groups")"
    printf 'Extension expected application group present: %s\n' "$(application_groups_expected_present_value "$extension_application_groups")"
  else
    printf 'Extension application groups: unknown; signed entitlements could not be read.\n'
    printf 'Extension expected application group present: unknown\n'
  fi
else
  printf 'Extension carries host-only System Extension entitlement: unknown; embedded extension is missing.\n'
  printf 'Extension application groups: unknown; embedded extension is missing.\n'
  printf 'Extension expected application group present: unknown\n'
fi

if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  if [ "$app_application_groups_readable" = "yes" ] && [ "$extension_application_groups_readable" = "yes" ]; then
    printf 'Application groups share expected value: %s\n' "$(application_groups_share_expected_value "$app_application_groups" "$extension_application_groups")"
  else
    printf 'Application groups share expected value: unknown; signed entitlements could not be read.\n'
  fi
else
  printf 'Application groups share expected value: unknown\n'
fi

section "Runtime Readiness Summary"
reset_readiness_rollup_counters
print_readiness_check "Application location ready" "$(application_location_readiness_value "$APP_PATH" "$EXPECTED_APP_PATH")"

if [ -d "$APP_PATH" ]; then
  app_bundle_identifier="$(read_bundle_identifier "$APP_PATH")"
  print_readiness_check "App bundle identifier ready" "$(bundle_identifier_matches_expected_value "$app_bundle_identifier" "$APP_ID")"

  if /usr/bin/codesign --verify --all-architectures --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    print_readiness_check "App signature ready" "yes"
  else
    print_readiness_check "App signature ready" "no"
  fi

  if [ "$(boolean_entitlement_value "$APP_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT")" = "yes" ]; then
    print_readiness_check "App System Extension entitlement ready" "yes"
  else
    print_readiness_check "App System Extension entitlement ready" "no"
  fi

  app_executable="$(read_info_plist_value "$APP_PATH" CFBundleExecutable)"
  print_readiness_check "App executable ready" "$(executable_readiness_value "$app_executable" "${APP_PATH}/Contents/MacOS/${app_executable}")"
else
  print_missing_app_readiness_checks
fi

if [ -d "$EXTENSION_PATH" ]; then
  extension_bundle_identifier="$(read_bundle_identifier "$EXTENSION_PATH")"
  extension_executable="$(read_info_plist_value "$EXTENSION_PATH" CFBundleExecutable)"
  extension_mach_service_name="$(read_extension_mach_service_name)"
  extension_signature_ready="no"
  extension_host_only_entitlement_present="no"
  print_readiness_check "Extension bundle identifier ready" "$(bundle_identifier_matches_expected_value "$extension_bundle_identifier" "$EXTENSION_ID")"

  if /usr/bin/codesign --verify --all-architectures --strict "$EXTENSION_PATH" >/dev/null 2>&1; then
    extension_signature_ready="yes"
  fi
  print_readiness_check "Extension signature ready" "$extension_signature_ready"

  extension_host_only_entitlement_present="$(boolean_entitlement_value "$EXTENSION_PATH" "$HOST_SYSTEM_EXTENSION_ENTITLEMENT")"
  print_readiness_check "Extension host-only entitlement absent" "$(extension_host_only_entitlement_absent_readiness_value "$extension_signature_ready" "$extension_host_only_entitlement_present")"

  print_readiness_check "Extension executable ready" "$(executable_readiness_value "$extension_executable" "${EXTENSION_PATH}/Contents/MacOS/${extension_executable}")"

  print_readiness_check "Extension CMIO Mach service ready" "$(mach_service_readiness_value "$extension_mach_service_name" "$EXTENSION_ID")"
else
  print_missing_extension_readiness_checks
fi

if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  app_short_version="$(read_info_plist_value "$APP_PATH" CFBundleShortVersionString)"
  app_build_version="$(read_info_plist_value "$APP_PATH" CFBundleVersion)"
  extension_short_version="$(read_info_plist_value "$EXTENSION_PATH" CFBundleShortVersionString)"
  extension_build_version="$(read_info_plist_value "$EXTENSION_PATH" CFBundleVersion)"
  print_readiness_check "Bundle versions match ready" "$(bundle_versions_match_readiness_value "$app_short_version" "$app_build_version" "$extension_short_version" "$extension_build_version")"
else
  print_readiness_check "Bundle versions match ready" "no"
fi

if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  app_team_identifier="$(read_team_identifier "$APP_PATH" || true)"
  extension_team_identifier="$(read_team_identifier "$EXTENSION_PATH" || true)"
  print_readiness_check "Signing Team match ready" "$(team_identifiers_match_value "$app_team_identifier" "$extension_team_identifier")"
else
  print_readiness_check "Signing Team match ready" "no"
fi

if [ -d "$APP_PATH" ] && [ -d "$EXTENSION_PATH" ]; then
  if [ "$app_application_groups_readable" = "yes" ] && [ "$extension_application_groups_readable" = "yes" ]; then
    print_readiness_check "Application group match ready" "$(application_groups_ready_value "$app_application_groups" "$extension_application_groups")"
  else
    print_readiness_check "Application group match ready" "no"
  fi
else
  print_readiness_check "Application group match ready" "no"
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

if [ -f "$VIDEO_PATH" ]; then
  print_readiness_check "Bundled video metadata ready" "$(video_metadata_readiness_value "$video_pixel_width" "$video_pixel_height" "$video_frame_rate" "$video_duration_seconds")"
else
  print_readiness_check "Bundled video metadata ready" "no"
fi

print_readiness_rollup

registration_present="unknown"
registration_activated_enabled="unknown"
camera_device_present="unknown"

section "System Extension Registration"
if [ -x /usr/bin/systemextensionsctl ]; then
  if registration_output="$(/usr/bin/systemextensionsctl list 2>&1)"; then
    registration_entries="$(extension_registration_entries "$registration_output" "$EXTENSION_ID")"
    registration_present="$(extension_registration_present_value "$registration_output" "$EXTENSION_ID")"
    registration_activated_enabled="$(extension_registration_activated_enabled_value "$registration_output" "$EXTENSION_ID")"

    print_yes_no_unknown "Extension registration entry present" "$registration_present"
    print_yes_no_unknown "Extension registration activated enabled" "$registration_activated_enabled"

    printf 'Matching system extension registration entries:\n'
    if [ -n "$registration_entries" ]; then
      printf '%s\n' "$registration_entries"
    else
      printf 'No matching system extension registration entries.\n'
    fi
  else
    printf 'systemextensionsctl list failed; registration evidence is unknown.\n'
    print_yes_no_unknown "Extension registration entry present" "unknown"
    print_yes_no_unknown "Extension registration activated enabled" "unknown"
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
  print_yes_no_unknown "Extension registration activated enabled" "unknown"
fi

section "Camera Devices"
printf 'Expected virtual camera device: %s\n' "$EXPECTED_CAMERA_NAME"
if command -v system_profiler >/dev/null 2>&1; then
  if camera_inventory="$(system_profiler SPCameraDataType 2>&1)"; then
    camera_device_present="$(camera_device_present_value "$camera_inventory" "$EXPECTED_CAMERA_NAME")"
    print_yes_no_unknown "Expected virtual camera device present" "$camera_device_present"
  else
    printf 'system_profiler SPCameraDataType failed; camera evidence is unknown.\n'
    print_yes_no_unknown "Expected virtual camera device present" "unknown"
  fi

  printf 'Full system_profiler SPCameraDataType output:\n'
  if [ -n "$camera_inventory" ]; then
    printf '%s\n' "$camera_inventory"
  else
    printf 'system_profiler SPCameraDataType produced no output.\n'
  fi
else
  printf 'system_profiler is not available on this host.\n'
  print_yes_no_unknown "Expected virtual camera device present" "unknown"
fi

section "Runtime Activation Evidence"
print_activation_evidence_summary "$registration_present" "$registration_activated_enabled" "$camera_device_present"

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
