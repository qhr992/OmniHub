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
echo "==> which player the now-playing bridge shows"
clang -O -Wall -o build/player-choice-test Tools/player-choice-test/main.c
./build/player-choice-test

echo
echo "==> which online lyrics belong to the playing track"
swiftc -O -swift-version 5 -target "$TARGET" -o build/lyrics-test \
  Sources/LyricsProvider.swift Tools/lyrics-test/main.swift
./build/lyrics-test

echo
echo "==> scroll stitcher (synthetic frames)"
swiftc -O -swift-version 5 -target "$TARGET" -o build/stitch-test \
  Sources/ScrollStitcher.swift Tools/stitch/main.swift
./build/stitch-test
