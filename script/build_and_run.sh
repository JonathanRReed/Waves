#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Waves"
BUNDLE_ID="com.jonathanreed.Waves"
MIN_SYSTEM_VERSION="14.2"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
LOGO_RESOURCE="$ROOT_DIR/Sources/Waves/Resources/waves-logo.svg"
LOGO_RESOURCE_FALLBACK="$ROOT_DIR/waves-logo.svg"
APP_ICON_NAME="waves-logo"

generate_icns() {
  local source="$1"
  local output_icns="$2"
  local tmp_dir
  local iconset_dir

  tmp_dir="$(mktemp -d)"
  iconset_dir="$tmp_dir/$APP_ICON_NAME.iconset"

  mkdir -p "$iconset_dir"

  # macOS icon sizes used by IconFamily
  sips -s format png -z 16 16 "$source" --out "$iconset_dir/icon_16x16.png" >/dev/null 2>&1 || true
  sips -s format png -z 32 32 "$source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null 2>&1 || true
  sips -s format png -z 32 32 "$source" --out "$iconset_dir/icon_32x32.png" >/dev/null 2>&1 || true
  sips -s format png -z 64 64 "$source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null 2>&1 || true
  sips -s format png -z 128 128 "$source" --out "$iconset_dir/icon_128x128.png" >/dev/null 2>&1 || true
  sips -s format png -z 256 256 "$source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null 2>&1 || true
  sips -s format png -z 256 256 "$source" --out "$iconset_dir/icon_256x256.png" >/dev/null 2>&1 || true
  sips -s format png -z 512 512 "$source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null 2>&1 || true
  sips -s format png -z 512 512 "$source" --out "$iconset_dir/icon_512x512.png" >/dev/null 2>&1 || true
  sips -s format png -z 1024 1024 "$source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null 2>&1 || true

  if command -v iconutil >/dev/null 2>&1; then
    iconutil --convert icns "$iconset_dir" --output "$output_icns" >/dev/null 2>&1 || true
  fi
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUILD_ARGS=()
if [ "$MODE" = "--dmg" ]; then
  BUILD_ARGS=(-c release)
fi

swift build "${BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [ -f "$LOGO_RESOURCE" ]; then
  cp "$LOGO_RESOURCE" "$APP_RESOURCES/waves-logo.svg"
  SOURCE_LOGO="$LOGO_RESOURCE"
elif [ -f "$LOGO_RESOURCE_FALLBACK" ]; then
  cp "$LOGO_RESOURCE_FALLBACK" "$APP_RESOURCES/waves-logo.svg"
  SOURCE_LOGO="$LOGO_RESOURCE_FALLBACK"
fi

if [ -n "${SOURCE_LOGO-}" ] && [ -f "$SOURCE_LOGO" ]; then
  if command -v sips >/dev/null 2>&1; then
    sips -s format png "$SOURCE_LOGO" --out "$APP_RESOURCES/waves-logo.png" >/dev/null 2>&1 || true
  fi

  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    generate_icns "$SOURCE_LOGO" "$APP_RESOURCES/$APP_ICON_NAME.icns"
  fi
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Waves captures audio from selected apps so it can apply per-app volume and mute controls before playing the audio back to your output device.</string>
</dict>
</plist>
PLIST

if [ -f "$APP_RESOURCES/$APP_ICON_NAME.icns" ] && command -v plutil >/dev/null 2>&1; then
  plutil -replace CFBundleIconFile -string "$APP_ICON_NAME" "$INFO_PLIST"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --dmg)
    hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DIST_DIR/$APP_NAME.dmg"
    open "$DIST_DIR/$APP_NAME.dmg"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--dmg|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
