#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-GarethVideoCam.xcodeproj}"
TARGET_NAME="${TARGET_NAME:-GarethVideoCam}"
BUILD_ARCH="${BUILD_ARCH:-}"
BUILD_OUTPUT_PATH="${BUILD_OUTPUT_PATH:-.build/Xcode}"
BUILD_LOG_PATH="${BUILD_LOG_PATH:-$BUILD_OUTPUT_PATH/Logs}"

if [ "$#" -gt 0 ]; then
  configurations=("$@")
else
  configurations=(Debug Release)
fi

validate_configuration_name() {
  local configuration="$1"

  if [[ ! "$configuration" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    printf 'Invalid Xcode configuration name: %s\n' "$configuration" >&2
    exit 2
  fi
}

validate_build_arch_name() {
  local build_arch="$1"

  if [[ ! "$build_arch" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    printf 'Invalid Xcode build architecture: %s\n' "$build_arch" >&2
    exit 2
  fi
}

for configuration in "${configurations[@]}"; do
  validate_configuration_name "$configuration"
done

if [ -z "$BUILD_ARCH" ]; then
  BUILD_ARCH="$(/usr/bin/uname -m)"
fi

validate_build_arch_name "$BUILD_ARCH"

if ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'xcodebuild is required to build GarethVideoCam; install Xcode and select it with xcode-select.\n' >&2
  exit 127
fi

mkdir -p "$BUILD_LOG_PATH"

for configuration in "${configurations[@]}"; do
  xcodebuild \
    -project "$PROJECT_PATH" \
    -target "$TARGET_NAME" \
    -configuration "$configuration" \
    ARCHS="$BUILD_ARCH" \
    SYMROOT="$BUILD_OUTPUT_PATH/Products" \
    OBJROOT="$BUILD_OUTPUT_PATH/Intermediates" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build 2>&1 | tee "$BUILD_LOG_PATH/build-${configuration}.log"
done
