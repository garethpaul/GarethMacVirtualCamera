#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

output="$(GARETH_DIAGNOSTICS_SELF_TEST=readiness-rollup "$ROOT/scripts/collect_runtime_diagnostics.sh")"

require_output() {
  local expected="$1"

  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf 'Missing expected diagnostics self-test output: %s\n' "$expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

require_output "Ready fixture: yes"
require_output "Blocked fixture: no"
require_output "Unknown fixture: unknown"
require_output "Runtime readiness result: blocked"
require_output "Runtime readiness checks ready: 1/3"
require_output "Runtime readiness checks blocked: 1"
require_output "Runtime readiness checks unknown: 1"
require_output "Runtime readiness next action: resolve Blocked fixture"

printf 'Runtime diagnostics tests passed.\n'
