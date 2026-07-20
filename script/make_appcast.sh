#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 VERSION [DMG_PATH] [OUTPUT_PATH]" >&2
  exit 2
}

require_command() {
  local command_name="$1"
  local purpose="$2"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: $command_name is required $purpose." >&2
    exit 1
  fi
}

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  usage
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Error: VERSION must match X.Y.Z with numeric components and no leading zeroes." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${2:-$ROOT_DIR/dist/Waves.dmg}"
OUTPUT_PATH="${3:-$ROOT_DIR/dist/appcast.xml}"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
SIGN_UPDATE="${SIGN_UPDATE:-}"
MIN_SYSTEM_VERSION="14.2"
DOWNLOAD_URL="https://github.com/JonathanRReed/Waves/releases/download/v$VERSION/Waves.dmg"

require_command awk "to extract and format release notes"
require_command sed "to format release notes"
require_command hdiutil "to inspect the release disk image"
require_command plutil "to read release metadata"
require_command stat "to measure the release disk image"

if [ ! -f "$CHANGELOG_PATH" ]; then
  echo "Error: Changelog not found at $CHANGELOG_PATH." >&2
  exit 1
fi
if [ ! -f "$DMG_PATH" ]; then
  echo "Error: DMG not found at $DMG_PATH." >&2
  exit 1
fi

if [ -z "$SIGN_UPDATE" ]; then
  while IFS= read -r candidate; do
    SIGN_UPDATE="$candidate"
    break
  done < <(find "$ROOT_DIR/.build/artifacts" -type f -path '*/bin/sign_update' -perm -111 -print 2>/dev/null | LC_ALL=C sort)
fi
if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
  echo "Error: Sparkle sign_update was not found under $ROOT_DIR/.build/artifacts." >&2
  echo "Set SIGN_UPDATE to the executable path if Sparkle is built elsewhere." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/waves-appcast.XXXXXX")"
MOUNT_POINT="$TMP_DIR/mount"
MOUNTED=0

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

RELEASE_NOTES_MD="$TMP_DIR/release-notes.md"
RELEASE_NOTES_HTML="$TMP_DIR/release-notes.html"
NEW_ITEM="$TMP_DIR/item.xml"
SOURCE_APPCAST="$TMP_DIR/source-appcast.xml"
RENDERED_APPCAST="$TMP_DIR/appcast.xml"

awk -v version="$VERSION" '
  BEGIN { heading = "## [" version "]" }
  $0 == heading || index($0, heading " - ") == 1 {
    in_section = 1
    found = 1
    next
  }
  in_section && /^## \[/ { exit }
  in_section {
    lines[++count] = $0
    if ($0 !~ /^[[:space:]]*$/) {
      last_nonempty = count
    }
  }
  END {
    if (!found || last_nonempty == 0) {
      exit 1
    }
    first_nonempty = 1
    while (first_nonempty <= last_nonempty && lines[first_nonempty] ~ /^[[:space:]]*$/) {
      first_nonempty++
    }
    for (i = first_nonempty; i <= last_nonempty; i++) {
      print lines[i]
    }
  }
' "$CHANGELOG_PATH" >"$RELEASE_NOTES_MD" || {
  echo "Error: CHANGELOG.md has no non-empty release notes section for $VERSION." >&2
  exit 1
}

awk '
  function escape_html(text,    escaped, i, character) {
    escaped = ""
    for (i = 1; i <= length(text); i++) {
      character = substr(text, i, 1)
      if (character == "&") {
        escaped = escaped "&amp;"
      } else if (character == "<") {
        escaped = escaped "&lt;"
      } else if (character == ">") {
        escaped = escaped "&gt;"
      } else if (character == "\"") {
        escaped = escaped "&quot;"
      } else {
        escaped = escaped character
      }
    }
    return escaped
  }
  function close_item() {
    if (in_item) {
      print "</li>"
      in_item = 0
    }
  }
  function close_list() {
    close_item()
    if (in_list) {
      print "</ul>"
      in_list = 0
    }
  }
  function close_paragraph() {
    if (in_paragraph) {
      print "</p>"
      in_paragraph = 0
    }
  }
  /^### / {
    close_paragraph()
    close_list()
    sub(/^### /, "")
    print "<h3>" escape_html($0) "</h3>"
    next
  }
  /^- / {
    close_paragraph()
    if (!in_list) {
      print "<ul>"
      in_list = 1
    }
    close_item()
    sub(/^- /, "")
    printf "  <li>%s", escape_html($0)
    in_item = 1
    next
  }
  in_list && /^[[:space:]]+/ {
    sub(/^[[:space:]]+/, "")
    printf " %s", escape_html($0)
    next
  }
  /^[[:space:]]*$/ {
    close_paragraph()
    close_list()
    next
  }
  {
    close_list()
    if (!in_paragraph) {
      printf "<p>%s", escape_html($0)
      in_paragraph = 1
    } else {
      printf " %s", escape_html($0)
    }
  }
  END {
    close_paragraph()
    close_list()
  }
' "$RELEASE_NOTES_MD" | sed -E 's/\*\*([^*]+)\*\*/<strong>\1<\/strong>/g' >"$RELEASE_NOTES_HTML"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1
INFO_PLIST="$MOUNT_POINT/Waves.app/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "Error: $DMG_PATH does not contain Waves.app at its volume root." >&2
  exit 1
fi
SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
if [ "$SHORT_VERSION" != "$VERSION" ]; then
  echo "Error: $DMG_PATH contains version $SHORT_VERSION; expected $VERSION." >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: $DMG_PATH contains invalid build number $BUILD_NUMBER." >&2
  exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

DMG_LENGTH="$(stat -f '%z' "$DMG_PATH")"
ED_SIGNATURE="$("$SIGN_UPDATE" -p "$DMG_PATH")"
if [[ ! "$DMG_LENGTH" =~ ^[0-9]+$ ]]; then
  echo "Error: Could not determine the byte length of $DMG_PATH." >&2
  exit 1
fi
if [[ ! "$ED_SIGNATURE" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
  echo "Error: sign_update returned an invalid EdDSA signature." >&2
  exit 1
fi

{
  echo '    <item>'
  echo "      <title>Version $VERSION</title>"
  echo "      <sparkle:version>$BUILD_NUMBER</sparkle:version>"
  echo "      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>"
  echo '      <description><![CDATA['
  cat "$RELEASE_NOTES_HTML"
  echo '      ]]></description>'
  echo "      <enclosure url=\"$DOWNLOAD_URL\" length=\"$DMG_LENGTH\" type=\"application/octet-stream\" sparkle:edSignature=\"$ED_SIGNATURE\"/>"
  echo '    </item>'
} >"$NEW_ITEM"

if [ -f "$OUTPUT_PATH" ]; then
  cp "$OUTPUT_PATH" "$SOURCE_APPCAST"
else
  cat >"$SOURCE_APPCAST" <<'APPCAST'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Waves Updates</title>
    <link>https://waves.jonathanrreed.com/appcast.xml</link>
    <description>Waves release updates.</description>
    <language>en</language>
  </channel>
</rss>
APPCAST
fi

if ! awk -v version="$VERSION" -v item_path="$NEW_ITEM" '
  function insert_item(    item_line) {
    while ((getline item_line < item_path) > 0) {
      print item_line
    }
    close(item_path)
    inserted = 1
  }
  !in_item && /^[[:space:]]*<item([[:space:]>])/ {
    if (!inserted) {
      insert_item()
    }
    in_item = 1
    matches_version = 0
    item = $0 ORS
    next
  }
  in_item {
    item = item $0 ORS
    if (index($0, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") > 0) {
      matches_version = 1
    }
    if ($0 ~ /^[[:space:]]*<\/item>[[:space:]]*$/) {
      if (!matches_version) {
        printf "%s", item
      }
      item = ""
      in_item = 0
      matches_version = 0
    }
    next
  }
  /^[[:space:]]*<\/channel>[[:space:]]*$/ && !inserted {
    insert_item()
  }
  { print }
  END {
    if (in_item) {
      exit 2
    }
    if (!inserted) {
      exit 3
    }
  }
' "$SOURCE_APPCAST" >"$RENDERED_APPCAST"; then
  echo "Error: Existing appcast is missing a usable channel or contains an incomplete item." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
cp "$RENDERED_APPCAST" "$OUTPUT_PATH"
printf 'Wrote %s for Waves %s (build %s).\n' "$OUTPUT_PATH" "$VERSION" "$BUILD_NUMBER"
