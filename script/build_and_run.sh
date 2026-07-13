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
VALID_MODES=("run" "--dmg" "--release-check" "release-check" "--publication-check" "publication-check" "--notarize" "notarize" "--debug" "debug" "--logs" "logs" "--telemetry" "telemetry" "--verify" "verify")
if [[ ! " ${VALID_MODES[@]} " =~ " ${MODE} " ]]; then
  echo "Error: Invalid mode '$MODE'" >&2
  echo "usage: $0 [run|--dmg|--release-check|--publication-check|--notarize|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
fi

is_notarize_mode() {
  [ "$MODE" = "--notarize" ] || [ "$MODE" = "notarize" ]
}

is_publication_check_mode() {
  [ "$MODE" = "--publication-check" ] || [ "$MODE" = "publication-check" ]
}

is_distribution_build_mode() {
  [ "$MODE" = "--dmg" ] \
    || [ "$MODE" = "--release-check" ] \
    || [ "$MODE" = "release-check" ] \
    || [ "$MODE" = "--notarize" ] \
    || [ "$MODE" = "notarize" ]
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
if ! is_publication_check_mode && ! command -v swift >/dev/null 2>&1; then
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
LOGO_RESOURCE="$ROOT_DIR/Sources/Waves/Resources/waves-logo.png"
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

if ! is_publication_check_mode; then
  # Kill existing app instance more safely - check bundle ID if possible
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    # Try to kill by bundle ID first (more specific)
    if command -v pkill >/dev/null 2>&1; then
      pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    fi
  fi

  # Build once and capture the binary path.
  if [ "$MODE" = "--dmg" ] || [ "$MODE" = "--release-check" ] || [ "$MODE" = "release-check" ] || [ "$MODE" = "--notarize" ] || [ "$MODE" = "notarize" ]; then
    # Distribution builds are universal (Apple Silicon + Intel) to match the
    # README/cask support claims. Debug `run` stays host-arch for speed.
    # `swift build --arch arm64 --arch x86_64` requires Xcode's XCBuild, which
    # Command Line Tools installs lack, so build each slice and lipo them.
    if ! command -v lipo >/dev/null 2>&1; then
      echo "Error: lipo is required for universal distribution builds." >&2
      exit 1
    fi
    swift build -c release --triple arm64-apple-macosx
    swift build -c release --triple x86_64-apple-macosx
    ARM64_BIN_DIR="$(swift build -c release --triple arm64-apple-macosx --show-bin-path)"
    X86_64_BIN_DIR="$(swift build -c release --triple x86_64-apple-macosx --show-bin-path)"
    BUILD_OUTPUT_DIR="$ROOT_DIR/.build/universal/release"
    mkdir -p "$BUILD_OUTPUT_DIR"
    lipo -create "$ARM64_BIN_DIR/$APP_NAME" "$X86_64_BIN_DIR/$APP_NAME" -output "$BUILD_OUTPUT_DIR/$APP_NAME"
    # The resource bundle is architecture-independent; take one slice's copy.
    rm -rf "$BUILD_OUTPUT_DIR/${APP_NAME}_${APP_NAME}.bundle"
    cp -R "$ARM64_BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" "$BUILD_OUTPUT_DIR/"
  else
    BUILD_OUTPUT_DIR="$(swift build --show-bin-path)"
    swift build
  fi
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

  # SwiftPM resource bundle (Bundle.module). Without it the generated accessor
  # falls back to an absolute path in this machine's .build directory and the
  # app fatalErrors at launch on every other machine.
  RESOURCE_BUNDLE="$BUILD_OUTPUT_DIR/${APP_NAME}_${APP_NAME}.bundle"
  if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Error: SwiftPM resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
  fi
  if ! cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"; then
    echo "Error: Failed to copy resource bundle to $APP_RESOURCES" >&2
    exit 1
  fi

  if [ -f "$LOGO_RESOURCE" ]; then
    if ! cp "$LOGO_RESOURCE" "$APP_RESOURCES/waves-logo.png"; then
      echo "Warning: Failed to copy logo resource" >&2
    else
      SOURCE_LOGO="$LOGO_RESOURCE"
    fi
  elif is_distribution_build_mode; then
    echo "Error: App icon source is missing at $LOGO_RESOURCE" >&2
    exit 1
  fi

  # Apple privacy manifest (required-reason APIs). Lives at the app bundle's
  # Resources root.
  PRIVACY_MANIFEST="$ROOT_DIR/PrivacyInfo.xcprivacy"
  if [ -f "$PRIVACY_MANIFEST" ]; then
    if command -v plutil >/dev/null 2>&1; then
      plutil -lint "$PRIVACY_MANIFEST" >/dev/null
    fi
    if cp "$PRIVACY_MANIFEST" "$APP_RESOURCES/PrivacyInfo.xcprivacy"; then
      if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$APP_RESOURCES/PrivacyInfo.xcprivacy" >/dev/null
      fi
    elif is_distribution_build_mode; then
      echo "Error: Failed to copy privacy manifest into $APP_RESOURCES" >&2
      exit 1
    else
      echo "Warning: Failed to copy privacy manifest" >&2
    fi
  elif is_distribution_build_mode; then
    echo "Error: PrivacyInfo.xcprivacy is required for distribution packaging." >&2
    exit 1
  fi

  if [ -n "${SOURCE_LOGO-}" ] && [ -f "$SOURCE_LOGO" ]; then
    if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
      if ! generate_icns "$SOURCE_LOGO" "$APP_RESOURCES/$APP_ICON_NAME.icns"; then
        if is_distribution_build_mode; then
          echo "Error: Failed to generate app icon at $APP_RESOURCES/$APP_ICON_NAME.icns" >&2
          exit 1
        fi
      fi
    elif is_distribution_build_mode; then
      echo "Error: sips and iconutil are required to generate the distribution app icon." >&2
      exit 1
    fi
  elif is_distribution_build_mode; then
    echo "Error: No app icon source was available for distribution packaging." >&2
    exit 1
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
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 Jonathan Reed. All rights reserved.</string>
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
  <string>Waves captures audio from selected apps so it can apply per-app volume, mute, equalizer, and adaptive mixing controls before playing the audio back to your output device.</string>
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
  elif is_distribution_build_mode; then
    echo "Error: Distribution bundle is missing $APP_RESOURCES/$APP_ICON_NAME.icns" >&2
    exit 1
  fi

  # Entitlements: Core Audio process taps require the audio-input entitlement.
  # Under the hardened runtime (used for notarized distribution) audio capture
  # is denied without it. The app is intentionally not sandboxed because process
  # taps and the global hotkey monitor need that access.
  # Write the entitlements file OUTSIDE the bundle so codesign does not seal it
  # into the signature (which would break verification once it is removed).
  ENTITLEMENTS="${APP_BUNDLE}.entitlements"
  cat >"$ENTITLEMENTS" <<'ENTITLEMENTS_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS_PLIST

  if command -v codesign >/dev/null 2>&1; then
    if [ -n "$SIGN_IDENTITY" ]; then
      codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    elif ! codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "Warning: Failed to ad hoc sign app bundle" >&2
    fi
  else
    echo "Warning: codesign not found, skipping code signing" >&2
  fi

  # The entitlements file is consumed by codesign and does not belong in the bundle.
  rm -f "$ENTITLEMENTS"
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
    plutil -lint "$ROOT_DIR/PrivacyInfo.xcprivacy" >/dev/null
    plutil -lint "$APP_RESOURCES/PrivacyInfo.xcprivacy" >/dev/null
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

publication_check() {
  local dmg_path="$DIST_DIR/$APP_NAME.dmg"
  local signature_info
  local entitlements_file
  local mount_dir
  local mounted_app
  local built_cdhash
  local mounted_cdhash

  if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE does not exist. Run --release-check or --notarize first." >&2
    exit 1
  fi

  if [ ! -f "$dmg_path" ]; then
    echo "Error: $dmg_path does not exist. Run --release-check or --notarize first." >&2
    exit 1
  fi

  if [ ! -f "$APP_RESOURCES/$APP_ICON_NAME.icns" ]; then
    echo "Error: $APP_BUNDLE is missing its app icon. Rebuild with --release-check or --notarize." >&2
    exit 1
  fi

  if [ ! -f "$APP_RESOURCES/PrivacyInfo.xcprivacy" ]; then
    echo "Error: $APP_BUNDLE is missing PrivacyInfo.xcprivacy. Rebuild with --release-check or --notarize." >&2
    exit 1
  fi

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$ROOT_DIR/PrivacyInfo.xcprivacy" >/dev/null
    plutil -lint "$APP_RESOURCES/PrivacyInfo.xcprivacy" >/dev/null
  fi

  if ! command -v codesign >/dev/null 2>&1; then
    echo "Error: codesign is required for publication checks." >&2
    exit 1
  fi

  signature_info="$(codesign -dvvv "$APP_BUNDLE" 2>&1 || true)"

  if echo "$signature_info" | grep -q "Signature=adhoc"; then
    echo "Error: $APP_BUNDLE is ad hoc signed. Public builds require a Developer ID Application signature." >&2
    exit 1
  fi

  if echo "$signature_info" | grep -q "TeamIdentifier=not set"; then
    echo "Error: $APP_BUNDLE has no TeamIdentifier. Public builds require a Developer ID Application signature." >&2
    exit 1
  fi

  codesign --verify --deep --strict "$APP_BUNDLE"
  entitlements_file="$(mktemp)"

  if ! codesign -d --entitlements :- "$APP_BUNDLE" >"$entitlements_file" 2>/dev/null; then
    rm -f "$entitlements_file"
    echo "Error: Failed to read entitlements from $APP_BUNDLE." >&2
    exit 1
  fi
  if ! tr -d '[:space:]' <"$entitlements_file" \
    | grep -Fq "<key>com.apple.security.device.audio-input</key><true/>"; then
    rm -f "$entitlements_file"
    echo "Error: $APP_BUNDLE is missing the audio-input entitlement required for per-app routing." >&2
    exit 1
  fi
  rm -f "$entitlements_file"

  hdiutil imageinfo "$dmg_path" >/dev/null
  mount_dir="$(mktemp -d)"
  if ! hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null; then
    rm -rf "$mount_dir"
    echo "Error: Failed to mount $dmg_path for publication validation." >&2
    exit 1
  fi
  mounted_app="$mount_dir/$APP_NAME.app"
  if [ ! -d "$mounted_app" ]; then
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    rm -rf "$mount_dir"
    echo "Error: $dmg_path does not contain $APP_NAME.app at its volume root." >&2
    exit 1
  fi
  built_cdhash="$(codesign -dvvv "$APP_BUNDLE" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
  mounted_cdhash="$(codesign -dvvv "$mounted_app" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
  if [ -z "$built_cdhash" ] || [ "$built_cdhash" != "$mounted_cdhash" ]; then
    hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1 || true
    rm -rf "$mount_dir"
    echo "Error: $dmg_path contains an app that does not match $APP_BUNDLE." >&2
    exit 1
  fi
  hdiutil detach "$mount_dir" -quiet >/dev/null
  rm -rf "$mount_dir"

  if ! command -v spctl >/dev/null 2>&1; then
    echo "Error: spctl is required for publication checks." >&2
    exit 1
  fi

  spctl --assess --type execute --verbose "$APP_BUNDLE"
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun is required for stapler validation." >&2
    exit 1
  fi
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg_path"
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
  --publication-check|publication-check)
    publication_check
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
    echo "usage: $0 [run|--dmg|--release-check|--publication-check|--notarize|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
