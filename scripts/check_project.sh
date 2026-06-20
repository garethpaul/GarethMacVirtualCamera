#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/validate_project.py
PYTHONDONTWRITEBYTECODE=1 ./scripts/test_validate_project.py
SWIFT_TEST_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SWIFT_TEST_SCRATCH"' EXIT
swift test --scratch-path "$SWIFT_TEST_SCRATCH"
rm -rf "$SWIFT_TEST_SCRATCH"
trap - EXIT
./scripts/test_scan_build_log.py
./scripts/test_build_unsigned.sh
./scripts/test_collect_runtime_diagnostics.sh
./scripts/test_verify_build_products.sh
bash -n ./scripts/collect_runtime_diagnostics.sh
bash -n ./scripts/build_unsigned.sh
bash -n ./scripts/test_build_unsigned.sh
bash -n ./scripts/verify_build_products.sh
bash -n ./scripts/check_project.sh
bash -n ./scripts/test_collect_runtime_diagnostics.sh
bash -n ./scripts/test_verify_build_products.sh
git diff --check
git diff-tree --check --root --no-commit-id -r HEAD
