#!/usr/bin/env bash
# Runs the unit tests that do not need a running app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$ROOT_DIR/Tests"
BUILD_DIR="$ROOT_DIR/build/tests"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

swiftc \
  -O \
  "$ROOT_DIR/Sources/SwipeDetector.swift" \
  "$TEST_DIR/main.swift" \
  -framework AppKit \
  -o "$BUILD_DIR/SwipeDetectorTests"

"$BUILD_DIR/SwipeDetectorTests"

swiftc \
  -O \
  "$ROOT_DIR/Sources/FinderActivationIntent.swift" \
  "$TEST_DIR/FinderActivationIntent/main.swift" \
  -framework AppKit \
  -framework ApplicationServices \
  -o "$BUILD_DIR/FinderActivationIntentTests"

"$BUILD_DIR/FinderActivationIntentTests"

swiftc \
  -O \
  "$ROOT_DIR/Sources/PerfLog.swift" \
  "$ROOT_DIR/Sources/DoubleCommandDetector.swift" \
  "$TEST_DIR/DoubleCommand/main.swift" \
  -import-objc-header "$ROOT_DIR/Sources/NativeHelpers.h" \
  "$ROOT_DIR/Sources/NativeHelpers.m" \
  -framework AppKit \
  -framework CoreGraphics \
  -o "$BUILD_DIR/DoubleCommandTests"

"$BUILD_DIR/DoubleCommandTests"
