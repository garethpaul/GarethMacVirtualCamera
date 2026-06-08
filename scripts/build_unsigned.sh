#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-GarethVideoCam.xcodeproj}"
TARGET_NAME="${TARGET_NAME:-GarethVideoCam}"
RUNNER_ARCH="${RUNNER_ARCH:-$(uname -m)}"

if [ "$#" -gt 0 ]; then
  configurations=("$@")
else
  configurations=(Debug Release)
fi

for configuration in "${configurations[@]}"; do
  xcodebuild \
    -project "$PROJECT_PATH" \
    -target "$TARGET_NAME" \
    -configuration "$configuration" \
    ARCHS="$RUNNER_ARCH" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    COMPILER_INDEX_STORE_ENABLE=NO \
    build 2>&1 | tee "build-${configuration}.log"
done
