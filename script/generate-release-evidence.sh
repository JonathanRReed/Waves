#!/bin/bash -p

unset CDPATH WAVES_RELEASE_ENTRY_DIRECTORY WAVES_RELEASE_ENVIRONMENT_HELPER \
  WAVES_RELEASE_PROHIBITED_OVERRIDE 2>/dev/null || :
case "${BASH_SOURCE[0]}" in
  */*) ;;
  *)
    printf 'Error: generate-release-evidence.sh must be executed through a direct path.\n' >&2
    exit 2
    ;;
esac
WAVES_RELEASE_ENTRY_DIRECTORY="$(builtin cd -P -- "${BASH_SOURCE[0]%/*}" && builtin pwd -P)" || exit 2
WAVES_RELEASE_ENVIRONMENT_HELPER="$WAVES_RELEASE_ENTRY_DIRECTORY/release_environment.sh"
if [ ! -f "$WAVES_RELEASE_ENVIRONMENT_HELPER" ] || [ -L "$WAVES_RELEASE_ENVIRONMENT_HELPER" ]; then
  printf 'Error: trusted release environment helper is missing or is a symbolic link.\n' >&2
  exit 2
fi
if [ -n "${WAVES_RELEASE_METADATA+x}" ]; then
  WAVES_RELEASE_PROHIBITED_OVERRIDE=1
fi
source "$WAVES_RELEASE_ENVIRONMENT_HELPER"
waves_release_environment_bootstrap
if [ -n "$WAVES_RELEASE_PROHIBITED_OVERRIDE" ]; then
  printf 'Error: WAVES_RELEASE_METADATA override is prohibited.\n' >&2
  exit 2
fi
ROOT_DIR="$(builtin cd -P -- "$WAVES_RELEASE_ENTRY_DIRECTORY/.." && builtin pwd -P)" || exit 2
unset WAVES_RELEASE_ENTRY_DIRECTORY WAVES_RELEASE_ENVIRONMENT_HELPER \
  WAVES_RELEASE_PROHIBITED_OVERRIDE
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf 'usage: %s candidate|publication INPUT_JSON OUTPUT_JSON\n' "$0" >&2
  exit 2
fi

PROFILE="$1"
INPUT_PATH="$2"
OUTPUT_PATH="$3"

case "$PROFILE" in
  candidate|publication) ;;
  *)
    printf 'Error: Evidence profile must be candidate or publication.\n' >&2
    exit 2
    ;;
esac

/usr/bin/ruby --disable-gems "$ROOT_DIR/script/release_tool.rb" \
  evidence seal "$PROFILE" "$INPUT_PATH" "$OUTPUT_PATH"
