#!/usr/bin/env bash
set -euo pipefail

if [ -n "${WAVES_RELEASE_METADATA+x}" ]; then
  echo "Error: WAVES_RELEASE_METADATA override is prohibited." >&2
  exit 2
fi
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

if [ "$#" -ne 3 ]; then
  echo "usage: $0 candidate|publication INPUT_JSON OUTPUT_JSON" >&2
  exit 2
fi

PROFILE="$1"
INPUT_PATH="$2"
OUTPUT_PATH="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$PROFILE" in
  candidate|publication) ;;
  *)
    echo "Error: Evidence profile must be candidate or publication." >&2
    exit 2
    ;;
esac

ruby "$ROOT_DIR/script/release_tool.rb" evidence seal "$PROFILE" "$INPUT_PATH" "$OUTPUT_PATH"
