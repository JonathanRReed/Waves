#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PATH="${WAVES_REALTIME_SOURCE:-$ROOT_DIR/Sources/Waves/Services/Audio/PerAppTapController.swift}"

if [ ! -f "$SOURCE_PATH" ]; then
  echo "Error: Realtime callback source not found at $SOURCE_PATH." >&2
  exit 1
fi

CALLBACK_BODY="$(
  awk '
    /REALTIME_CALLBACK_AUDIT_BEGIN/ { inside = 1; found_begin = 1; next }
    /REALTIME_CALLBACK_AUDIT_END/ { inside = 0; found_end = 1; next }
    inside { print }
    END { if (!found_begin || !found_end || inside) exit 2 }
  ' "$SOURCE_PATH"
)" || {
  echo "Error: Realtime callback audit markers are missing or malformed in $SOURCE_PATH." >&2
  exit 1
}

FORBIDDEN='(^|[^[:alnum:]_])(Task|await|DispatchQueue|NSLock|os_unfair_lock|malloc|calloc|realloc|free|print|logger|NotificationCenter|Array|Dictionary|Set)\b'
if printf '%s\n' "$CALLBACK_BODY" | grep -En "$FORBIDDEN"; then
  echo "Error: Realtime callback contains forbidden allocation, lock, task, logging, or UI work." >&2
  exit 1
fi

echo "Realtime callback boundary audit passed."
