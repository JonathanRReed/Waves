#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_TEMPLATE="$ROOT_DIR/script/tsan-harness"
RESOLVED_FILE="$ROOT_DIR/Package.resolved"

if [ ! -f "$RESOLVED_FILE" ]; then
  echo "Error: tracked Package.resolved is required for the TSan harness." >&2
  exit 1
fi

HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/waves-tsan-harness.XXXXXX")"
cleanup() {
  rm -rf "$HARNESS_ROOT"
}
trap cleanup EXIT INT TERM HUP

ditto "$ROOT_DIR/Sources" "$HARNESS_ROOT/Sources"
ditto "$HARNESS_TEMPLATE/Package.swift" "$HARNESS_ROOT/Package.swift"
ditto "$RESOLVED_FILE" "$HARNESS_ROOT/Package.resolved"
ditto "$HARNESS_TEMPLATE/Sources/Waves/TSanAppSupport.swift" \
  "$HARNESS_ROOT/Sources/Waves/TSanAppSupport.swift"
ditto "$HARNESS_TEMPLATE/Sources/WavesTSanHarness" "$HARNESS_ROOT/Sources/WavesTSanHarness"

swift run \
  --package-path "$HARNESS_ROOT" \
  --scratch-path "$ROOT_DIR/.build/tsan-harness" \
  --disable-automatic-resolution \
  --sanitize=thread \
  WavesTSanHarness
