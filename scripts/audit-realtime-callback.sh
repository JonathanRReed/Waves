#!/bin/sh
set -eu

source_file="${1:-Sources/Waves/Services/Audio/PerAppTapController.swift}"
callback_start='AudioDeviceCreateIOProcIDWithBlock'

if [ ! -f "$source_file" ]; then
  echo "missing callback source: $source_file" >&2
  exit 1
fi

callback_body=$(awk -v marker="$callback_start" '
  index($0, marker) { found = 1 }
  found {
    print
    opens += gsub(/\{/, "{")
    closes += gsub(/\}/, "}")
    if (opens > 0 && opens == closes) exit
  }
  END { if (!found || opens == 0 || opens != closes) exit 1 }
' "$source_file") || {
  echo "could not structurally locate the Core Audio render callback" >&2
  exit 1
}

forbidden='NSLock|\.lock\(|\.try\(|UnsafeMutablePointer.*allocate|Logger|logger\.|Task[[:space:]]*\{|await |NSWorkspace|AudioObjectGet|AudioHardware|Sec[A-Z]|FileManager|DispatchQueue\.main|SwiftUI|AppKit'
if printf '%s\n' "$callback_body" | grep -nE "$forbidden"; then
  echo "forbidden operation in Core Audio render callback" >&2
  exit 1
fi

echo "realtime callback audit passed: $source_file"
