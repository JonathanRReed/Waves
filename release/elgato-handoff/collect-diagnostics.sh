#!/bin/bash -p
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL="C.UTF-8"
unset BASH_ENV ENV CDPATH GLOBIGNORE RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE
unset DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH LD_PRELOAD
umask 077

if [ "$#" -ne 1 ] || [[ "$1" != /* ]]; then
  echo "usage: ./collect-diagnostics.sh ABSOLUTE_OUTPUT_DIRECTORY" >&2
  exit 2
fi

OUTPUT_ROOT="$1"
if [ -e "$OUTPUT_ROOT" ] || [ -L "$OUTPUT_ROOT" ]; then
  echo "Error: diagnostics output already exists: $OUTPUT_ROOT" >&2
  exit 1
fi

/bin/mkdir -m 700 "$OUTPUT_ROOT"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

/usr/bin/sw_vers >"$OUTPUT_ROOT/macos.txt"
/usr/bin/uname -a >"$OUTPUT_ROOT/kernel.txt"
/usr/sbin/system_profiler SPAudioDataType SPUSBDataType -detailLevel mini \
  >"$OUTPUT_ROOT/audio-and-usb.txt"
/usr/bin/pgrep -fl 'Waves|WaveLink|Wave Link|Stream Deck' \
  >"$OUTPUT_ROOT/relevant-processes.txt" || true
/usr/bin/shasum -a 256 \
  "$SCRIPT_ROOT/Waves-1.5.0-13.dmg" \
  "$SCRIPT_ROOT/com.jonathanreed.waves.streamDeckPlugin" \
  >"$OUTPUT_ROOT/handoff-artifact-checksums.txt"

if [ -d /Applications/Waves.app ]; then
  /usr/bin/codesign -d --verbose=4 /Applications/Waves.app \
    >"$OUTPUT_ROOT/installed-waves-signature.txt" 2>&1 || true
  /usr/sbin/spctl -a -t exec -vv /Applications/Waves.app \
    >"$OUTPUT_ROOT/installed-waves-gatekeeper.txt" 2>&1 || true
  /usr/bin/xcrun stapler validate /Applications/Waves.app \
    >"$OUTPUT_ROOT/installed-waves-stapling.txt" 2>&1 || true
  {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      /Applications/Waves.app/Contents/Info.plist
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      /Applications/Waves.app/Contents/Info.plist
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
      /Applications/Waves.app/Contents/Info.plist
    /usr/libexec/PlistBuddy -c 'Print :WavesSourceRevision' \
      /Applications/Waves.app/Contents/Info.plist
  } >"$OUTPUT_ROOT/installed-waves-identity.txt" 2>&1 || true
else
  printf '%s\n' 'Waves is not installed at /Applications/Waves.app.' \
    >"$OUTPUT_ROOT/installed-waves-identity.txt"
fi

/bin/cp "$SCRIPT_ROOT/handoff.json" "$OUTPUT_ROOT/handoff.json"
/bin/cp "$SCRIPT_ROOT/TEST-CHECKLIST.md" "$OUTPUT_ROOT/TEST-CHECKLIST.md"

/usr/bin/printf '%s\n' \
  'In Waves, open Settings > Diagnostics and choose Copy Diagnostics.' \
  'Save that text as waves-diagnostics.txt in this directory before returning it.' \
  'Do not add unrelated logs, credentials, browser data, or other user files.' \
  >"$OUTPUT_ROOT/ADD-WAVES-DIAGNOSTICS.txt"

echo "Collected bounded Elgato test diagnostics at $OUTPUT_ROOT"
