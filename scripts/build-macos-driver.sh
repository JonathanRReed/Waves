#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER_PROJECT_DIR="$ROOT_DIR/native/macos/WavesAudioDriver"
BUILD_DIR="$DRIVER_PROJECT_DIR/build"

rm -rf "$BUILD_DIR"
cmake -S "$DRIVER_PROJECT_DIR" -B "$BUILD_DIR" >&2
cmake --build "$BUILD_DIR" -j4 >&2

echo "$BUILD_DIR/WavesAudio.driver"
