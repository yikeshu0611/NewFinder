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
  "$ROOT_DIR/Sources/SwipeDownDetector.swift" \
  "$TEST_DIR/main.swift" \
  -framework AppKit \
  -o "$BUILD_DIR/SwipeDownDetectorTests"

"$BUILD_DIR/SwipeDownDetectorTests"
