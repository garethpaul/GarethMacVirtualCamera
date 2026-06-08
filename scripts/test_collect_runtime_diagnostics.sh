#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_output() {
  local output="$1"
  local expected="$2"

  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf 'Missing expected diagnostics self-test output: %s\n' "$expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

blocked_output="$(GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup "$ROOT/scripts/collect_runtime_diagnostics.sh")"
unknown_output="$(GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup-unknown "$ROOT/scripts/collect_runtime_diagnostics.sh")"
ready_output="$(GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup-ready "$ROOT/scripts/collect_runtime_diagnostics.sh")"
bundle_version_output="$(GARETH_DIAGNOSTICS_SELF_TEST=bundle-version-match "$ROOT/scripts/collect_runtime_diagnostics.sh")"
mach_service_output="$(GARETH_DIAGNOSTICS_SELF_TEST=mach-service "$ROOT/scripts/collect_runtime_diagnostics.sh")"
application_group_output="$(GARETH_DIAGNOSTICS_SELF_TEST=application-group "$ROOT/scripts/collect_runtime_diagnostics.sh")"
camera_device_output="$(GARETH_DIAGNOSTICS_SELF_TEST=camera-device "$ROOT/scripts/collect_runtime_diagnostics.sh")"
registration_output="$(GARETH_DIAGNOSTICS_SELF_TEST=registration "$ROOT/scripts/collect_runtime_diagnostics.sh")"

require_output "$blocked_output" "Ready fixture: yes"
require_output "$blocked_output" "Blocked fixture: no"
require_output "$blocked_output" "Unknown fixture: unknown"
require_output "$blocked_output" "Runtime readiness result: blocked"
require_output "$blocked_output" "Runtime readiness checks ready: 1/3"
require_output "$blocked_output" "Runtime readiness checks blocked: 1"
require_output "$blocked_output" "Runtime readiness checks unknown: 1"
require_output "$blocked_output" "Runtime readiness next action: resolve Blocked fixture"

require_output "$unknown_output" "Ready fixture: yes"
require_output "$unknown_output" "Unknown fixture: unknown"
require_output "$unknown_output" "Runtime readiness result: incomplete"
require_output "$unknown_output" "Runtime readiness checks ready: 1/2"
require_output "$unknown_output" "Runtime readiness checks blocked: 0"
require_output "$unknown_output" "Runtime readiness checks unknown: 1"
require_output "$unknown_output" "Runtime readiness next action: inspect Unknown fixture"

require_output "$ready_output" "Ready fixture: yes"
require_output "$ready_output" "Runtime readiness result: ready"
require_output "$ready_output" "Runtime readiness checks ready: 1/1"
require_output "$ready_output" "Runtime readiness checks blocked: 0"
require_output "$ready_output" "Runtime readiness checks unknown: 0"
require_output "$ready_output" "Runtime readiness next action: submit the system extension request"

require_output "$bundle_version_output" "Bundle version match fixture: yes"
require_output "$bundle_version_output" "Bundle version short mismatch fixture: no"
require_output "$bundle_version_output" "Bundle version build mismatch fixture: no"
require_output "$bundle_version_output" "Bundle version missing fixture: no"

require_output "$mach_service_output" "Mach service direct fixture resolved: yes"
require_output "$mach_service_output" "Mach service direct fixture matches expected: yes"
require_output "$mach_service_output" "Mach service direct fixture ready: yes"
require_output "$mach_service_output" "Mach service team-prefixed fixture ready: yes"
require_output "$mach_service_output" "Mach service unresolved fixture resolved: no"
require_output "$mach_service_output" "Mach service wrong fixture matches expected: no"
require_output "$mach_service_output" "Mach service missing fixture ready: no"

require_output "$application_group_output" "Application group shared fixture ready: yes"
require_output "$application_group_output" "Application group missing fixture ready: no"
require_output "$application_group_output" "Application group mismatched fixture ready: no"
require_output "$application_group_output" "Application group wrong suffix fixture ready: no"
require_output "$application_group_output" "Application group unresolved fixture ready: no"

require_output "$camera_device_output" "Camera device present fixture: yes"
require_output "$camera_device_output" "Camera device missing fixture: no"
require_output "$camera_device_output" "Camera device empty fixture: unknown"

require_output "$registration_output" "Registration active fixture present: yes"
require_output "$registration_output" "Registration active fixture activated enabled: yes"
require_output "$registration_output" "Registration waiting fixture activated enabled: no"
require_output "$registration_output" "Registration missing fixture present: no"
require_output "$registration_output" "Registration empty fixture present: unknown"

printf 'Runtime diagnostics tests passed.\n'
