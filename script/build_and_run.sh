#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Waves"
BUNDLE_ID="${BUNDLE_ID:-com.jonathanreed.Waves}"
MIN_SYSTEM_VERSION="14.2"
APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Validate MODE parameter
VALID_MODES=("run" "--dmg" "--release-check" "release-check" "--notarize" "notarize" "--debug" "debug" "--logs" "logs" "--telemetry" "telemetry" "--verify" "verify")
if [[ ! " ${VALID_MODES[@]} " =~ " ${MODE} " ]]; then
  echo "Error: Invalid mode '$MODE'" >&2
  echo "usage: $0 [run|--dmg|--release-check|--notarize|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
fi

is_notarize_mode() {
  [ "$MODE" = "--notarize" ] || [ "$MODE" = "notarize" ]
}

if is_notarize_mode; then
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Error: SIGN_IDENTITY must be set to a Developer ID Application identity for notarization." >&2
    exit 2
  fi

  if [ -z "$NOTARY_PROFILE" ]; then
    echo "Error: NOTARY_PROFILE must be set to a notarytool keychain profile." >&2
    echo "Create one with: xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>" >&2
    exit 2
  fi

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun is required for notarytool and stapler." >&2
    exit 1
  fi
fi

# Validate critical tools are available
if ! command -v swift >/dev/null 2>&1; then
  echo "Error: swift not found. Please install Swift from https://swift.org" >&2
  exit 1
fi

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

  trap 'rm -rf "$tmp_dir"' RETURN

  mkdir -p "$iconset_dir"

  # macOS icon sizes used by IconFamily
  if ! command -v sips >/dev/null 2>&1; then
    echo "Warning: sips not found, skipping icon generation" >&2
    return 1
  fi

  sips -s format png -z 16 16 "$source" --out "$iconset_dir/icon_16x16.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 16x16 icon" >&2
  sips -s format png -z 32 32 "$source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 16x16@2x icon" >&2
  sips -s format png -z 32 32 "$source" --out "$iconset_dir/icon_32x32.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 32x32 icon" >&2
  sips -s format png -z 64 64 "$source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 32x32@2x icon" >&2
  sips -s format png -z 128 128 "$source" --out "$iconset_dir/icon_128x128.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 128x128 icon" >&2
  sips -s format png -z 256 256 "$source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 128x128@2x icon" >&2
  sips -s format png -z 256 256 "$source" --out "$iconset_dir/icon_256x256.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 256x256 icon" >&2
  sips -s format png -z 512 512 "$source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 256x256@2x icon" >&2
  sips -s format png -z 512 512 "$source" --out "$iconset_dir/icon_512x512.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 512x512 icon" >&2
  sips -s format png -z 1024 1024 "$source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null 2>&1 || echo "Warning: Failed to generate 512x512@2x icon" >&2

  if command -v iconutil >/dev/null 2>&1; then
    if ! iconutil --convert icns "$iconset_dir" --output "$output_icns" >/dev/null 2>&1; then
      echo "Warning: Failed to create .icns file" >&2
      return 1
    fi
  else
    echo "Warning: iconutil not found, skipping .icns generation" >&2
    return 1
  fi
}

# Kill existing app instance more safely - check bundle ID if possible
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  # Try to kill by bundle ID first (more specific)
  if command -v pkill >/dev/null 2>&1; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  fi
fi

BUILD_ARGS=()
if [ "$MODE" = "--dmg" ] || [ "$MODE" = "--release-check" ] || [ "$MODE" = "release-check" ] || [ "$MODE" = "--notarize" ] || [ "$MODE" = "notarize" ]; then
  BUILD_ARGS=(-c release)
fi

# Build once and capture the binary path
BUILD_OUTPUT_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
swift build "${BUILD_ARGS[@]}"
BUILD_BINARY="$BUILD_OUTPUT_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"

# Copy binary with error handling
if ! cp "$BUILD_BINARY" "$APP_BINARY"; then
  echo "Error: Failed to copy binary to $APP_BINARY" >&2
  exit 1
fi
chmod +x "$APP_BINARY"

if [ -f "$LOGO_RESOURCE" ]; then
  if ! cp "$LOGO_RESOURCE" "$APP_RESOURCES/waves-logo.svg"; then
    echo "Warning: Failed to copy logo resource" >&2
  else
    SOURCE_LOGO="$LOGO_RESOURCE"
  fi
elif [ -f "$LOGO_RESOURCE_FALLBACK" ]; then
  if ! cp "$LOGO_RESOURCE_FALLBACK" "$APP_RESOURCES/waves-logo.svg"; then
    echo "Warning: Failed to copy fallback logo resource" >&2
  else
    SOURCE_LOGO="$LOGO_RESOURCE_FALLBACK"
  fi
fi

if [ -n "${SOURCE_LOGO-}" ] && [ -f "$SOURCE_LOGO" ]; then
  if command -v sips >/dev/null 2>&1; then
    if ! sips -s format png "$SOURCE_LOGO" --out "$APP_RESOURCES/waves-logo.png" >/dev/null 2>&1; then
      echo "Warning: Failed to convert logo to PNG" >&2
    fi
  else
    echo "Warning: sips not found, skipping PNG conversion" >&2
  fi

  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    generate_icns "$SOURCE_LOGO" "$APP_RESOURCES/$APP_ICON_NAME.icns" || true
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
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID.url</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>waves</string>
      </array>
    </dict>
  </array>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
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

# Validate Info.plist was created
if [ ! -f "$INFO_PLIST" ]; then
  echo "Error: Failed to create Info.plist" >&2
  exit 1
fi

if [ -f "$APP_RESOURCES/$APP_ICON_NAME.icns" ] && command -v plutil >/dev/null 2>&1; then
  plutil -replace CFBundleIconFile -string "$APP_ICON_NAME" "$INFO_PLIST"
fi

if command -v codesign >/dev/null 2>&1; then
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  elif ! codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
    echo "Warning: Failed to ad hoc sign app bundle" >&2
  fi
else
  echo "Warning: codesign not found, skipping code signing" >&2
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
  if [ ! -x "$APP_BINARY" ]; then
    echo "$APP_BINARY is missing or not executable" >&2
    exit 1
  fi

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$INFO_PLIST" >/dev/null
  fi

  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$APP_BUNDLE"
  fi

  open_app

  for _ in {1..30}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      sleep 1
      pgrep -x "$APP_NAME" >/dev/null
      return
    fi
    sleep 0.2
  done

  echo "$APP_NAME did not launch" >&2
  exit 1
}

release_check() {
  local dmg_path="$DIST_DIR/$APP_NAME.dmg"

  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Warning: SIGN_IDENTITY is not set. This build is suitable for local testing, not public distribution." >&2
  fi

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$INFO_PLIST" >/dev/null
  fi

  if command -v codesign >/dev/null 2>&1; then
    codesign --verify --deep --strict "$APP_BUNDLE"
  fi

  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$dmg_path"
  hdiutil imageinfo "$dmg_path" >/dev/null

  if command -v spctl >/dev/null 2>&1 && [ -n "$SIGN_IDENTITY" ]; then
    spctl --assess --type execute --verbose "$APP_BUNDLE"
  fi
}

notarize_release() {
  local dmg_path="$DIST_DIR/$APP_NAME.dmg"

  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Error: SIGN_IDENTITY must be set to a Developer ID Application identity for notarization." >&2
    exit 2
  fi

  if [ -z "$NOTARY_PROFILE" ]; then
    echo "Error: NOTARY_PROFILE must be set to a notarytool keychain profile." >&2
    echo "Create one with: xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>" >&2
    exit 2
  fi

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun is required for notarytool and stapler." >&2
    exit 1
  fi

  release_check
  xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"

  if command -v spctl >/dev/null 2>&1; then
    spctl --assess --type open --context context:primary-signature --verbose "$dmg_path"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --dmg)
    release_check
    open "$DIST_DIR/$APP_NAME.dmg"
    ;;
  --release-check|release-check)
    release_check
    ;;
  --notarize|notarize)
    notarize_release
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
    verify_app
    ;;
  *)
    echo "usage: $0 [run|--dmg|--release-check|--notarize|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
