#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Waves"
BUNDLE_ID="${BUNDLE_ID:-com.jonathanreed.Waves}"
LOG_SUBSYSTEM="com.jonathanreed.Waves"
MIN_SYSTEM_VERSION="14.2"
APP_VERSION="${APP_VERSION:-1.1.0}"
APP_BUILD="${APP_BUILD:-2}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SWIFT_SDK="${SWIFT_SDK:-}"
SMOKE_SECONDS="${SMOKE_SECONDS:-5}"

# Some Command Line Tools releases install a newer default SDK whose SwiftUI
# interface references SwiftUIMacros without shipping that macro plugin. Prefer
# the compatible macOS 26 SDK on those machines so local builds remain usable.
if [ -z "$SWIFT_SDK" ] \
  && [ ! -f /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib ] \
  && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]; then
  SWIFT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
fi

SWIFT_BUILD=(swift build)
if [ -n "$SWIFT_SDK" ]; then
  SWIFT_BUILD+=(--sdk "$SWIFT_SDK")
fi

VALID_MODES=("run" "--dmg" "--release-check" "release-check" "--publication-check" "publication-check" "--notarize" "notarize" "--debug" "debug" "--logs" "logs" "--telemetry" "telemetry" "--verify" "verify" "--package-smoke" "package-smoke")
if [[ ! " ${VALID_MODES[*]} " =~ " ${MODE} " ]]; then
  echo "Error: Invalid mode '$MODE'" >&2
  echo "usage: $0 [run|--dmg|--release-check|--publication-check|--notarize|--debug|--logs|--telemetry|--verify|--package-smoke]" >&2
  exit 2
fi

is_notarize_mode() {
  [ "$MODE" = "--notarize" ] || [ "$MODE" = "notarize" ]
}

is_publication_check_mode() {
  [ "$MODE" = "--publication-check" ] || [ "$MODE" = "publication-check" ]
}

is_verify_mode() {
  [ "$MODE" = "--verify" ] || [ "$MODE" = "verify" ]
}

is_package_smoke_mode() {
  [ "$MODE" = "--package-smoke" ] || [ "$MODE" = "package-smoke" ]
}

is_existing_package_mode() {
  is_publication_check_mode || is_verify_mode || is_package_smoke_mode
}

is_distribution_build_mode() {
  [ "$MODE" = "--dmg" ] \
    || [ "$MODE" = "--release-check" ] \
    || [ "$MODE" = "release-check" ] \
    || [ "$MODE" = "--notarize" ] \
    || [ "$MODE" = "notarize" ]
}

require_command() {
  local command_name="$1"
  local purpose="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: $command_name is required $purpose." >&2
    exit 1
  fi
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

  require_command xcrun "for notarytool and stapler"
fi

if ! is_existing_package_mode; then
  require_command swift "to build Waves"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DSYM_BUNDLE="$DIST_DIR/$APP_NAME.app.dSYM"
DSYM_BINARY="$DSYM_BUNDLE/Contents/Resources/DWARF/$APP_NAME"
LOGO_RESOURCE="$ROOT_DIR/Sources/Waves/Resources/waves-logo.png"
APP_ICON_NAME="waves-logo"
RESOURCE_BUNDLE_NAME="${APP_NAME}_${APP_NAME}.bundle"
SMOKE_LOG_PATH="${SMOKE_LOG_PATH:-$DIST_DIR/package-smoke.log}"
ACTIVE_MOUNT_DIR=""
ACTIVE_STAGING_DIR=""
ACTIVE_SMOKE_HOME=""
SMOKE_PID=""

stop_smoke_process() {
  local process_id="$1"
  local attempt

  if kill -0 "$process_id" >/dev/null 2>&1; then
    kill "$process_id" >/dev/null 2>&1 || true
    for ((attempt = 0; attempt < 10; attempt++)); do
      if ! kill -0 "$process_id" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
  fi
  if kill -0 "$process_id" >/dev/null 2>&1; then
    kill -9 "$process_id" >/dev/null 2>&1 || true
  fi
  wait "$process_id" >/dev/null 2>&1 || true
}

cleanup() {
  if [ -n "$SMOKE_PID" ]; then
    stop_smoke_process "$SMOKE_PID"
  fi
  SMOKE_PID=""

  if [ -n "$ACTIVE_MOUNT_DIR" ]; then
    hdiutil detach "$ACTIVE_MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    rm -rf "$ACTIVE_MOUNT_DIR"
  fi
  ACTIVE_MOUNT_DIR=""

  if [ -n "$ACTIVE_STAGING_DIR" ]; then
    rm -rf "$ACTIVE_STAGING_DIR"
  fi
  ACTIVE_STAGING_DIR=""

  if [ -n "$ACTIVE_SMOKE_HOME" ]; then
    rm -rf "$ACTIVE_SMOKE_HOME"
  fi
  ACTIVE_SMOKE_HOME=""
}
trap cleanup EXIT

plist_value() {
  local plist_path="$1"
  local key="$2"

  # plutil treats "." as a key-path separator; escape literal dots so dotted
  # keys such as com.apple.security.device.audio-input resolve as one key.
  /usr/bin/plutil -extract "${key//./\\.}" raw -o - "$plist_path"
}

require_plist_value() {
  local plist_path="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual

  if ! actual="$(plist_value "$plist_path" "$key" 2>/dev/null)"; then
    echo "Error: $label is missing $key." >&2
    exit 1
  fi

  if [ "$actual" != "$expected" ]; then
    echo "Error: $label has $key=$actual; expected $expected." >&2
    exit 1
  fi
}

require_universal_binary() {
  local binary_path="$1"
  local label="$2"
  local archs

  require_command lipo "to inspect $label architectures"
  if [ ! -f "$binary_path" ]; then
    echo "Error: $label is missing at $binary_path." >&2
    exit 1
  fi

  archs="$(lipo -archs "$binary_path")"
  case " $archs " in
    *" arm64 "*) ;;
    *)
      echo "Error: $label is missing arm64; found: $archs." >&2
      exit 1
      ;;
  esac
  case " $archs " in
    *" x86_64 "*) ;;
    *)
      echo "Error: $label is missing x86_64; found: $archs." >&2
      exit 1
      ;;
  esac

  set -- $archs
  if [ "$#" -ne 2 ]; then
    echo "Error: $label must contain exactly arm64 and x86_64; found: $archs." >&2
    exit 1
  fi
}

minimum_os_for_arch() {
  local binary_path="$1"
  local expected_arch="$2"
  local key
  local value
  local remainder
  local version_key=""

  while read -r key value remainder; do
    if [ "$key" = "cmd" ] && [ "$value" = "LC_BUILD_VERSION" ]; then
      version_key="minos"
      continue
    fi
    if [ "$key" = "cmd" ] && [ "$value" = "LC_VERSION_MIN_MACOSX" ]; then
      version_key="version"
      continue
    fi
    if [ -n "$version_key" ] && [ "$key" = "$version_key" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < <(otool -arch "$expected_arch" -l "$binary_path")

  return 1
}

validate_minimum_os() {
  local binary_path="$1"
  local label="$2"
  local arch
  local actual

  require_command otool "to inspect $label deployment targets"
  for arch in arm64 x86_64; do
    if ! actual="$(minimum_os_for_arch "$binary_path" "$arch")"; then
      echo "Error: Could not read the $arch minimum macOS version from $label." >&2
      exit 1
    fi
    if [ "$actual" != "$MIN_SYSTEM_VERSION" ] && [ "$actual" != "$MIN_SYSTEM_VERSION.0" ]; then
      echo "Error: $label has a $arch minimum macOS version of $actual; expected $MIN_SYSTEM_VERSION." >&2
      exit 1
    fi
  done
}

uuid_for_arch() {
  local binary_path="$1"
  local expected_arch="$2"
  local marker
  local uuid
  local arch_token
  local remainder

  while read -r marker uuid arch_token remainder; do
    if [ "$marker" = "UUID:" ] && [ "$arch_token" = "($expected_arch)" ]; then
      printf '%s\n' "$uuid"
      return 0
    fi
  done < <(dwarfdump --uuid "$binary_path")

  return 1
}

validate_dsym() {
  local app_uuid
  local dsym_uuid
  local arch

  if [ ! -d "$DSYM_BUNDLE" ]; then
    if command -v dsymutil >/dev/null 2>&1; then
      echo "Error: $DSYM_BUNDLE is missing even though dsymutil is available." >&2
      exit 1
    fi
    echo "Warning: dSYM validation skipped because dsymutil is not available." >&2
    return
  fi

  require_universal_binary "$DSYM_BINARY" "Waves dSYM"

  if ! command -v dwarfdump >/dev/null 2>&1; then
    echo "Warning: dSYM UUID matching skipped because dwarfdump is not available." >&2
    return
  fi

  for arch in arm64 x86_64; do
    if ! app_uuid="$(uuid_for_arch "$APP_BINARY" "$arch")"; then
      echo "Error: Could not read the $arch UUID from $APP_BINARY." >&2
      exit 1
    fi
    if ! dsym_uuid="$(uuid_for_arch "$DSYM_BINARY" "$arch")"; then
      echo "Error: Could not read the $arch UUID from $DSYM_BINARY." >&2
      exit 1
    fi
    if [ "$app_uuid" != "$dsym_uuid" ]; then
      echo "Error: dSYM UUID mismatch for $arch ($dsym_uuid != $app_uuid)." >&2
      exit 1
    fi
  done
}

generate_icns() {
  local source="$1"
  local output_icns="$2"
  local tmp_dir
  local iconset_dir

  tmp_dir="$(mktemp -d)"
  iconset_dir="$tmp_dir/$APP_ICON_NAME.iconset"
  mkdir -p "$iconset_dir"

  if ! command -v sips >/dev/null 2>&1; then
    echo "Warning: sips not found, skipping icon generation" >&2
    rm -rf "$tmp_dir"
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

  if ! command -v iconutil >/dev/null 2>&1; then
    echo "Warning: iconutil not found, skipping .icns generation" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! iconutil --convert icns "$iconset_dir" --output "$output_icns" >/dev/null 2>&1; then
    echo "Warning: Failed to create .icns file" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir"
}

build_app_bundle() {
  local build_output_dir
  local build_binary
  local resource_bundle
  local source_logo=""
  local privacy_manifest="$ROOT_DIR/PrivacyInfo.xcprivacy"
  local entitlements="${APP_BUNDLE}.entitlements"

  mkdir -p "$DIST_DIR"

  if pgrep -x "$APP_NAME" >/dev/null 2>&1 && command -v pkill >/dev/null 2>&1; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  fi

  if is_distribution_build_mode; then
    local arm64_scratch="$ROOT_DIR/.build/arm64"
    local x86_64_scratch="$ROOT_DIR/.build/x86_64"
    local arm64_bin_dir
    local x86_64_bin_dir

    require_command lipo "for universal distribution builds"
    "${SWIFT_BUILD[@]}" --scratch-path "$arm64_scratch" -c release --triple arm64-apple-macosx -Xswiftc -g
    "${SWIFT_BUILD[@]}" --scratch-path "$x86_64_scratch" -c release --triple x86_64-apple-macosx -Xswiftc -g
    arm64_bin_dir="$("${SWIFT_BUILD[@]}" --scratch-path "$arm64_scratch" -c release --triple arm64-apple-macosx --show-bin-path)"
    x86_64_bin_dir="$("${SWIFT_BUILD[@]}" --scratch-path "$x86_64_scratch" -c release --triple x86_64-apple-macosx --show-bin-path)"
    build_output_dir="$ROOT_DIR/.build/universal/release"
    mkdir -p "$build_output_dir"
    lipo -create "$arm64_bin_dir/$APP_NAME" "$x86_64_bin_dir/$APP_NAME" -output "$build_output_dir/$APP_NAME"

    # Bundle.module resources are architecture-independent; use the arm64 copy.
    rm -rf "$build_output_dir/$RESOURCE_BUNDLE_NAME"
    cp -R "$arm64_bin_dir/$RESOURCE_BUNDLE_NAME" "$build_output_dir/"
  else
    build_output_dir="$("${SWIFT_BUILD[@]}" --show-bin-path)"
    "${SWIFT_BUILD[@]}"
  fi
  build_binary="$build_output_dir/$APP_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"

  if ! cp "$build_binary" "$APP_BINARY"; then
    echo "Error: Failed to copy binary to $APP_BINARY" >&2
    exit 1
  fi
  chmod +x "$APP_BINARY"

  resource_bundle="$build_output_dir/$RESOURCE_BUNDLE_NAME"
  if [ ! -d "$resource_bundle" ]; then
    echo "Error: SwiftPM resource bundle not found at $resource_bundle" >&2
    exit 1
  fi
  if ! cp -R "$resource_bundle" "$APP_RESOURCES/"; then
    echo "Error: Failed to copy resource bundle to $APP_RESOURCES" >&2
    exit 1
  fi

  if [ -f "$LOGO_RESOURCE" ]; then
    source_logo="$LOGO_RESOURCE"
  elif is_distribution_build_mode; then
    echo "Error: App icon source is missing at $LOGO_RESOURCE" >&2
    exit 1
  fi

  if [ -f "$privacy_manifest" ]; then
    if command -v plutil >/dev/null 2>&1; then
      plutil -lint "$privacy_manifest" >/dev/null
    fi
    if cp "$privacy_manifest" "$APP_RESOURCES/PrivacyInfo.xcprivacy"; then
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

  if [ -n "$source_logo" ]; then
    if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
      if ! generate_icns "$source_logo" "$APP_RESOURCES/$APP_ICON_NAME.icns" && is_distribution_build_mode; then
        echo "Error: Failed to generate app icon at $APP_RESOURCES/$APP_ICON_NAME.icns" >&2
        exit 1
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

  if is_distribution_build_mode; then
    rm -rf "$DSYM_BUNDLE"
    if command -v dsymutil >/dev/null 2>&1; then
      if ! dsymutil "$APP_BINARY" -o "$DSYM_BUNDLE"; then
        echo "Error: dsymutil is available but failed to create $DSYM_BUNDLE." >&2
        exit 1
      fi
      validate_dsym
    else
      echo "Warning: dsymutil is unavailable; no dSYM will be produced." >&2
    fi
  fi

  # Core Audio process taps require audio-input under the hardened runtime. Keep
  # this file outside the bundle so only the embedded signature carries it.
  cat >"$entitlements" <<'ENTITLEMENTS_PLIST'
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
      codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    elif ! codesign --force --entitlements "$entitlements" --sign - "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "Warning: Failed to ad hoc sign app bundle" >&2
    fi
  else
    echo "Warning: codesign not found, skipping code signing" >&2
  fi

  rm -f "$entitlements"
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

validate_app_bundle() {
  local bundle_path="$1"
  local label="$2"
  local contents="$bundle_path/Contents"
  local binary="$contents/MacOS/$APP_NAME"
  local resources="$contents/Resources"
  local info_plist="$contents/Info.plist"
  local entitlement_file
  local entitlement_value

  require_command plutil "to validate $label metadata"
  require_command codesign "to validate $label entitlements"

  if [ ! -x "$binary" ]; then
    echo "Error: $label executable is missing or not executable at $binary." >&2
    exit 1
  fi
  if [ ! -f "$info_plist" ]; then
    echo "Error: $label Info.plist is missing at $info_plist." >&2
    exit 1
  fi

  plutil -lint "$info_plist" >/dev/null
  require_plist_value "$info_plist" CFBundleExecutable "$APP_NAME" "$label"
  require_plist_value "$info_plist" CFBundleIdentifier "$BUNDLE_ID" "$label"
  require_plist_value "$info_plist" CFBundleName "$APP_NAME" "$label"
  require_plist_value "$info_plist" CFBundleShortVersionString "$APP_VERSION" "$label"
  require_plist_value "$info_plist" CFBundleVersion "$APP_BUILD" "$label"
  require_plist_value "$info_plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION" "$label"
  require_plist_value "$info_plist" CFBundleIconFile "$APP_ICON_NAME" "$label"

  if [ ! -f "$resources/$APP_ICON_NAME.icns" ]; then
    echo "Error: $label is missing $resources/$APP_ICON_NAME.icns." >&2
    exit 1
  fi
  if [ ! -d "$resources/$RESOURCE_BUNDLE_NAME" ]; then
    echo "Error: $label is missing its SwiftPM resource bundle at $resources/$RESOURCE_BUNDLE_NAME." >&2
    exit 1
  fi
  if [ ! -f "$resources/PrivacyInfo.xcprivacy" ]; then
    echo "Error: $label is missing PrivacyInfo.xcprivacy." >&2
    exit 1
  fi
  plutil -lint "$resources/PrivacyInfo.xcprivacy" >/dev/null
  if ! cmp -s "$ROOT_DIR/PrivacyInfo.xcprivacy" "$resources/PrivacyInfo.xcprivacy"; then
    echo "Error: $label contains an unexpected privacy manifest." >&2
    exit 1
  fi

  require_universal_binary "$binary" "$label executable"
  validate_minimum_os "$binary" "$label executable"
  codesign --verify --deep --strict "$bundle_path"

  entitlement_file="$(mktemp)"
  if ! codesign -d --entitlements :- "$bundle_path" >"$entitlement_file" 2>/dev/null; then
    rm -f "$entitlement_file"
    echo "Error: Failed to read entitlements from $label." >&2
    exit 1
  fi
  if ! entitlement_value="$(plist_value "$entitlement_file" com.apple.security.device.audio-input 2>/dev/null)"; then
    rm -f "$entitlement_file"
    echo "Error: $label is missing the audio-input entitlement required for per-app routing." >&2
    exit 1
  fi
  rm -f "$entitlement_file"

  if [ "$entitlement_value" != "true" ] && [ "$entitlement_value" != "1" ]; then
    echo "Error: $label has an invalid audio-input entitlement value: $entitlement_value." >&2
    exit 1
  fi
}

mount_dmg() {
  require_command hdiutil "to inspect $DMG_PATH"

  ACTIVE_MOUNT_DIR="$(mktemp -d)"
  if ! hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$ACTIVE_MOUNT_DIR" >/dev/null; then
    rm -rf "$ACTIVE_MOUNT_DIR"
    ACTIVE_MOUNT_DIR=""
    echo "Error: Failed to mount $DMG_PATH." >&2
    exit 1
  fi
}

unmount_dmg() {
  if [ -n "$ACTIVE_MOUNT_DIR" ]; then
    if ! hdiutil detach "$ACTIVE_MOUNT_DIR" -quiet >/dev/null; then
      echo "Error: Failed to detach $ACTIVE_MOUNT_DIR." >&2
      exit 1
    fi
    rm -rf "$ACTIVE_MOUNT_DIR"
    ACTIVE_MOUNT_DIR=""
  fi
}

validate_mounted_layout_and_identity() {
  local mounted_app="$ACTIVE_MOUNT_DIR/$APP_NAME.app"
  local applications_link="$ACTIVE_MOUNT_DIR/Applications"
  local entry
  local entry_count=0
  local saw_app=0
  local saw_applications=0
  local built_cdhash
  local mounted_cdhash

  while IFS= read -r -d '' entry; do
    entry_count=$((entry_count + 1))
    case "${entry##*/}" in
      "$APP_NAME.app") saw_app=1 ;;
      Applications) saw_applications=1 ;;
      *)
        echo "Error: $DMG_PATH contains unexpected volume-root entry ${entry##*/}." >&2
        exit 1
        ;;
    esac
  done < <(find "$ACTIVE_MOUNT_DIR" -mindepth 1 -maxdepth 1 -print0)

  if [ "$entry_count" -ne 2 ] || [ "$saw_app" -ne 1 ] || [ "$saw_applications" -ne 1 ]; then
    echo "Error: $DMG_PATH root must contain only $APP_NAME.app and Applications." >&2
    exit 1
  fi
  if [ ! -L "$applications_link" ]; then
    echo "Error: $applications_link is not a symbolic link." >&2
    exit 1
  fi
  if [ "$(readlink "$applications_link")" != "/Applications" ]; then
    echo "Error: $applications_link must target /Applications." >&2
    exit 1
  fi
  if [ ! -d "$mounted_app" ]; then
    echo "Error: $DMG_PATH does not contain $APP_NAME.app at its volume root." >&2
    exit 1
  fi

  validate_app_bundle "$mounted_app" "mounted $APP_NAME.app"

  if ! cmp -s "$APP_BINARY" "$mounted_app/Contents/MacOS/$APP_NAME"; then
    echo "Error: The mounted app executable does not match $APP_BINARY." >&2
    exit 1
  fi
  if ! cmp -s "$INFO_PLIST" "$mounted_app/Contents/Info.plist"; then
    echo "Error: The mounted app Info.plist does not match $INFO_PLIST." >&2
    exit 1
  fi
  if ! diff -qr "$APP_BUNDLE" "$mounted_app" >/dev/null; then
    echo "Error: The app in $DMG_PATH does not exactly match $APP_BUNDLE." >&2
    exit 1
  fi

  built_cdhash="$(codesign -dvvv "$APP_BUNDLE" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
  mounted_cdhash="$(codesign -dvvv "$mounted_app" 2>&1 | sed -n 's/^CDHash=//p' | head -n 1)"
  if [ -z "$built_cdhash" ] || [ "$built_cdhash" != "$mounted_cdhash" ]; then
    echo "Error: The mounted app code identity does not match $APP_BUNDLE." >&2
    exit 1
  fi
}

validate_unsigned_package() {
  if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE does not exist. Run --release-check or --notarize first." >&2
    exit 1
  fi
  if [ ! -f "$DMG_PATH" ]; then
    echo "Error: $DMG_PATH does not exist. Run --release-check or --notarize first." >&2
    exit 1
  fi

  require_command hdiutil "to validate $DMG_PATH"
  hdiutil imageinfo "$DMG_PATH" >/dev/null
  validate_app_bundle "$APP_BUNDLE" "built $APP_NAME.app"
  validate_dsym
  mount_dmg
  validate_mounted_layout_and_identity
  unmount_dmg

  echo "Validated existing universal package without requiring Developer ID or notarization credentials."
}

create_dmg() {
  require_command hdiutil "to create $DMG_PATH"
  require_command ditto "to stage $APP_NAME.app"

  mkdir -p "$DIST_DIR"
  ACTIVE_STAGING_DIR="$(mktemp -d "$DIST_DIR/.dmg-staging.XXXXXX")"
  ditto "$APP_BUNDLE" "$ACTIVE_STAGING_DIR/$APP_NAME.app"
  ln -s /Applications "$ACTIVE_STAGING_DIR/Applications"

  rm -f "$DMG_PATH"
  hdiutil create -volname "$APP_NAME" -srcfolder "$ACTIVE_STAGING_DIR" -ov -format UDZO "$DMG_PATH"
  hdiutil imageinfo "$DMG_PATH" >/dev/null

  rm -rf "$ACTIVE_STAGING_DIR"
  ACTIVE_STAGING_DIR=""
}

release_check() {
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Warning: SIGN_IDENTITY is not set. The app will be ad hoc signed for local validation, not public distribution." >&2
  fi

  create_dmg
  validate_unsigned_package
}

notarize_release() {
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Error: SIGN_IDENTITY must be set to a Developer ID Application identity for notarization." >&2
    exit 2
  fi
  if [ -z "$NOTARY_PROFILE" ]; then
    echo "Error: NOTARY_PROFILE must be set to a notarytool keychain profile." >&2
    exit 2
  fi

  require_command xcrun "for notarytool and stapler"
  release_check
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  if command -v spctl >/dev/null 2>&1; then
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
  fi
}

publication_check() {
  local signature_info

  validate_unsigned_package
  require_command codesign "for publication checks"
  require_command spctl "for publication checks"
  require_command xcrun "for stapler validation"

  signature_info="$(codesign -dvvv "$APP_BUNDLE" 2>&1 || true)"
  if printf '%s\n' "$signature_info" | grep -Fq "Signature=adhoc"; then
    echo "Error: $APP_BUNDLE is ad hoc signed. Public builds require a Developer ID Application signature." >&2
    exit 1
  fi
  if ! printf '%s\n' "$signature_info" | grep -Fq "Authority=Developer ID Application:"; then
    echo "Error: $APP_BUNDLE is not signed by a Developer ID Application identity." >&2
    exit 1
  fi
  if printf '%s\n' "$signature_info" | grep -Fq "TeamIdentifier=not set" \
    || ! printf '%s\n' "$signature_info" | grep -Fq "TeamIdentifier="; then
    echo "Error: $APP_BUNDLE has no TeamIdentifier. Public builds require a Developer ID Application signature." >&2
    exit 1
  fi

  codesign --verify --deep --strict "$APP_BUNDLE"
  spctl --assess --type execute --verbose "$APP_BUNDLE"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
}

append_system_smoke_log() {
  local process_id="$1"

  if [ -x /usr/bin/log ]; then
    {
      printf '\n--- unified log for process %s ---\n' "$process_id"
      /usr/bin/log show --last 2m --style compact --predicate "processIdentifier == $process_id" || true
    } >>"$SMOKE_LOG_PATH" 2>&1
  fi
}

package_smoke() {
  local mounted_app
  local mounted_binary
  local smoke_pid
  local iteration
  local smoke_iterations
  local smoke_home
  local smoke_session

  if [[ ! "$SMOKE_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: SMOKE_SECONDS must be a positive integer." >&2
    exit 2
  fi

  validate_unsigned_package
  mount_dmg
  mounted_app="$ACTIVE_MOUNT_DIR/$APP_NAME.app"
  mounted_binary="$mounted_app/Contents/MacOS/$APP_NAME"
  mkdir -p "$(dirname "$SMOKE_LOG_PATH")"
  : >"$SMOKE_LOG_PATH"

  ACTIVE_SMOKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/waves-package-smoke.XXXXXX")"
  smoke_home="$ACTIVE_SMOKE_HOME/home"
  mkdir -m 700 "$smoke_home"
  smoke_session="$smoke_home/Library/Application Support/Waves/session.json"

  HOME="$smoke_home" CFFIXED_USER_HOME="$smoke_home" \
    "$mounted_binary" >>"$SMOKE_LOG_PATH" 2>&1 &
  smoke_pid=$!
  SMOKE_PID="$smoke_pid"
  smoke_iterations=$((SMOKE_SECONDS * 2))

  for ((iteration = 0; iteration < smoke_iterations; iteration++)); do
    if ! kill -0 "$smoke_pid" >/dev/null 2>&1; then
      wait "$smoke_pid" >/dev/null 2>&1 || true
      append_system_smoke_log "$smoke_pid"
      SMOKE_PID=""
      echo "Error: Packaged $APP_NAME exited before the ${SMOKE_SECONDS}-second smoke window completed. See $SMOKE_LOG_PATH." >&2
      exit 1
    fi
    sleep 0.5
  done

  stop_smoke_process "$smoke_pid"
  append_system_smoke_log "$smoke_pid"
  SMOKE_PID=""
  if [ -e "$smoke_session" ]; then
    echo "Error: Packaged $APP_NAME wrote a session before first-run privacy consent." >&2
    exit 1
  fi
  rm -rf "$ACTIVE_SMOKE_HOME"
  ACTIVE_SMOKE_HOME=""
  unmount_dmg

  echo "Packaged $APP_NAME stayed alive for ${SMOKE_SECONDS} seconds; test process was terminated."
}

if ! is_existing_package_mode; then
  build_app_bundle
fi

case "$MODE" in
  run)
    open_app
    ;;
  --dmg)
    release_check
    /usr/bin/open "$DMG_PATH"
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
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$LOG_SUBSYSTEM\""
    ;;
  --verify|verify)
    validate_unsigned_package
    ;;
  --package-smoke|package-smoke)
    package_smoke
    ;;
  *)
    echo "usage: $0 [run|--dmg|--release-check|--publication-check|--notarize|--debug|--logs|--telemetry|--verify|--package-smoke]" >&2
    exit 2
    ;;
esac
