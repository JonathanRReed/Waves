#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Waves"
APP_BUNDLE_PATH="$ROOT_DIR/src-tauri/target/release/bundle/macos/${APP_NAME}.app"
DMG_DIR="$ROOT_DIR/src-tauri/target/release/bundle/dmg"
ARCH_SUFFIX="$(uname -m)"
VERSION="$(plutil -extract version raw -o - "$ROOT_DIR/src-tauri/tauri.conf.json")"
DMG_PATH="$DMG_DIR/${APP_NAME}_${VERSION}_${ARCH_SUFFIX}.dmg"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/src-tauri/target/release/${APP_NAME}.dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

bun run release:app

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "App bundle not found at $APP_BUNDLE_PATH" >&2
  exit 1
fi

mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"

ditto "$APP_BUNDLE_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Built DMG at: $DMG_PATH"
