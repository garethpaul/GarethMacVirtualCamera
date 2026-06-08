#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
WORK_DIR="$TMP_DIR/work"
CALL_LOG="$TMP_DIR/xcodebuild-calls.log"
mkdir -p "$FAKE_BIN" "$WORK_DIR"

cat >"$FAKE_BIN/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

configuration="unknown"
previous=""
for argument in "$@"; do
  if [ "$previous" = "-configuration" ]; then
    configuration="$argument"
    break
  fi
  previous="$argument"
done

{
  printf 'CALL'
  for argument in "$@"; do
    printf '\t%s' "$argument"
  done
  printf '\n'
} >>"$XCODEBUILD_CALL_LOG"
printf 'xcodebuild fixture for %s\n' "$configuration"

if [ "${XCODEBUILD_SHOULD_FAIL:-}" = "1" ]; then
  printf 'xcodebuild fixture failure for %s\n' "$configuration"
  exit 65
fi
SH
chmod +x "$FAKE_BIN/xcodebuild"

require_file_contains() {
  local file_path="$1"
  local expected="$2"

  if ! grep -F -- "$expected" "$file_path" >/dev/null; then
    printf 'Expected %s to contain: %s\n' "$file_path" "$expected" >&2
    printf '%s\n' "--- $file_path ---" >&2
    cat "$file_path" >&2
    exit 1
  fi
}

(
  cd "$WORK_DIR"
  PATH="$FAKE_BIN:$PATH" \
    XCODEBUILD_CALL_LOG="$CALL_LOG" \
    PROJECT_PATH="Fixture.xcodeproj" \
    TARGET_NAME="FixtureCamera" \
    BUILD_ARCH="arm64" \
    BUILD_OUTPUT_PATH="$TMP_DIR/XcodeProducts" \
    "$ROOT/scripts/build_unsigned.sh" Debug Release >/dev/null
)

if [ "$(wc -l <"$CALL_LOG")" -ne 2 ]; then
  printf 'Expected two xcodebuild invocations.\n' >&2
  cat "$CALL_LOG" >&2
  exit 1
fi

require_file_contains "$CALL_LOG" $'-project\tFixture.xcodeproj'
require_file_contains "$CALL_LOG" $'-target\tFixtureCamera'
require_file_contains "$CALL_LOG" $'-configuration\tDebug'
require_file_contains "$CALL_LOG" $'-configuration\tRelease'
require_file_contains "$CALL_LOG" $'ARCHS=arm64'
require_file_contains "$CALL_LOG" $'SYMROOT='"$TMP_DIR"$'/XcodeProducts/Products'
require_file_contains "$CALL_LOG" $'OBJROOT='"$TMP_DIR"$'/XcodeProducts/Intermediates'
require_file_contains "$CALL_LOG" $'CODE_SIGNING_ALLOWED=NO'
require_file_contains "$CALL_LOG" $'CODE_SIGNING_REQUIRED=NO'
require_file_contains "$CALL_LOG" $'COMPILER_INDEX_STORE_ENABLE=NO'
require_file_contains "$WORK_DIR/build-Debug.log" "xcodebuild fixture for Debug"
require_file_contains "$WORK_DIR/build-Release.log" "xcodebuild fixture for Release"

FAIL_WORK_DIR="$TMP_DIR/failure-work"
FAIL_CALL_LOG="$TMP_DIR/xcodebuild-failure-calls.log"
mkdir -p "$FAIL_WORK_DIR"

set +e
(
  cd "$FAIL_WORK_DIR"
  PATH="$FAKE_BIN:$PATH" \
    XCODEBUILD_CALL_LOG="$FAIL_CALL_LOG" \
    XCODEBUILD_SHOULD_FAIL=1 \
    "$ROOT/scripts/build_unsigned.sh" Debug >"$TMP_DIR/build-unsigned-failure.out" 2>"$TMP_DIR/build-unsigned-failure.err"
)
failure_status=$?
set -e

if [ "$failure_status" -eq 0 ]; then
  printf 'Expected unsigned build script to propagate xcodebuild failure.\n' >&2
  exit 1
fi

if [ "$failure_status" -ne 65 ]; then
  printf 'Expected unsigned build script to exit 65, got %s.\n' "$failure_status" >&2
  cat "$TMP_DIR/build-unsigned-failure.out" >&2
  cat "$TMP_DIR/build-unsigned-failure.err" >&2
  exit 1
fi

require_file_contains "$FAIL_WORK_DIR/build-Debug.log" "xcodebuild fixture failure for Debug"

printf 'Unsigned build script tests passed.\n'
