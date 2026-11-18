#!/bin/bash
# Build and run the verification harnesses.
set -euo pipefail
cd "$(dirname "$0")"
TARGET="arm64-apple-macos14.0"
mkdir -p build

echo "==> capture pipeline (real screen)"
swiftc -O -swift-version 5 -target "$TARGET" -o build/capture-test \
  Sources/ScreenCapture.swift Tools/capture-test/main.swift
./build/capture-test

echo
echo "==> scroll stitcher (synthetic frames)"
swiftc -O -swift-version 5 -target "$TARGET" -o build/stitch-test \
  Sources/ScrollStitcher.swift Tools/stitch/main.swift
./build/stitch-test
