#!/usr/bin/env bash

# Keep every local Swift entry point on the same SDK. Some Command Line Tools
# ship the macOS 27 SwiftUI interface without its required State macro plugin.
waves_compatible_swift_sdk() {
  local default_sdk="$1"
  local swift_path="$2"
  local toolchain_lib="${swift_path%/*}/../lib/swift/host/plugins"
  local sdk_directory="${default_sdk%/*}"
  local resolved_sdk="$default_sdk"
  local sdk_version
  local candidate

  if [ -d "$default_sdk" ]; then
    resolved_sdk="$(cd -P "$default_sdk" && pwd -P)"
  fi
  sdk_version="${resolved_sdk##*/MacOSX}"
  sdk_version="${sdk_version%.sdk}"
  sdk_version="${sdk_version%%.*}"
  case "$sdk_version" in
    ''|*[!0-9]*) printf '%s\n' "$default_sdk"; return ;;
  esac
  if [ "$sdk_version" -lt 27 ]; then
    printf '%s\n' "$default_sdk"
    return
  fi

  if [ ! -f "$toolchain_lib/libSwiftUIMacros.dylib" ]; then
    for candidate in "$sdk_directory/MacOSX26.5.sdk" "$sdk_directory/MacOSX26.sdk"; do
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return
      fi
    done
  fi
  printf '%s\n' "$default_sdk"
}
