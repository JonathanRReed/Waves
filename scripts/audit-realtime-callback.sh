#!/bin/sh
set -eu

source_file="${1:-Sources/Waves/Services/Audio/PerAppTapController.swift}"

if [ ! -f "$source_file" ]; then
  echo "missing callback source: $source_file" >&2
  exit 1
fi

extract_region() {
  name="$1"
  begin="REALTIME_CALLBACK_AUDIT_BEGIN $name"
  end="REALTIME_CALLBACK_AUDIT_END $name"
  begin_count=$(grep -c "$begin" "$source_file" || true)
  end_count=$(grep -c "$end" "$source_file" || true)
  if [ "$begin_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    echo "callback audit markers for $name must each appear exactly once" >&2
    exit 1
  fi
  awk -v begin="$begin" -v end="$end" '
    index($0, begin) { in_region = 1; next }
    index($0, end) { if (!in_region) exit 1; exit }
    in_region { print }
    END { if (!in_region) exit 1 }
  ' "$source_file"
}

callback_body=$(for region in callback validatesCallbackGeometry renderTappedAudio zeroOutput; do
  extract_region "$region" || exit 1
done) || {
  echo "could not structurally locate the complete Core Audio callback region" >&2
  exit 1
}

forbidden='NSLock|\.lock\(|\.try\(|UnsafeMutablePointer.*allocate|Logger|logger\.|Task[[:space:]]*\{|await |NSWorkspace|AudioObjectGet|AudioHardware|Sec[A-Z]|FileManager|DispatchQueue\.main|SwiftUI|AppKit'
if printf '%s\n' "$callback_body" | grep -nE "$forbidden"; then
  echo "forbidden operation in Core Audio render callback" >&2
  exit 1
fi

echo "realtime callback audit passed: $source_file"
