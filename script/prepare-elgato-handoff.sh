#!/bin/bash -p

unset CDPATH WAVES_RELEASE_ENTRY_DIRECTORY WAVES_RELEASE_ENVIRONMENT_HELPER \
  WAVES_RELEASE_PROHIBITED_OVERRIDE 2>/dev/null || :
case "${BASH_SOURCE[0]}" in
  */*) ;;
  *)
    printf 'Error: prepare-elgato-handoff.sh must be executed through a direct path.\n' >&2
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

if [ "$#" -ne 4 ]; then
  printf 'usage: %s ABSOLUTE_CANDIDATE_EVIDENCE ABSOLUTE_PLUGIN_PACKAGE PLUGIN_REVISION ABSOLUTE_OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi

CANDIDATE_EVIDENCE="$1"
PLUGIN_PACKAGE="$2"
PLUGIN_REVISION="$3"
OUTPUT_DIRECTORY="$4"

for candidate_path in "$CANDIDATE_EVIDENCE" "$PLUGIN_PACKAGE" "$OUTPUT_DIRECTORY"; do
  if [[ "$candidate_path" != /* ]] || [[ "$candidate_path" == *$'\n'* ]] \
    || [[ "$candidate_path" == *$'\r'* ]] || [ "${#candidate_path}" -gt 4096 ]; then
    printf 'Error: handoff paths must be absolute, bounded, and single-line.\n' >&2
    exit 2
  fi
done
if [[ ! "$PLUGIN_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'Error: plugin revision must be a lowercase 40-character Git revision.\n' >&2
  exit 2
fi
if [ ! -f "$CANDIDATE_EVIDENCE" ] || [ -L "$CANDIDATE_EVIDENCE" ] \
  || [ ! -f "$CANDIDATE_EVIDENCE.sha256" ] || [ -L "$CANDIDATE_EVIDENCE.sha256" ]; then
  printf 'Error: canonical candidate evidence and sidecar are required.\n' >&2
  exit 1
fi
if [ ! -f "$PLUGIN_PACKAGE" ] || [ -L "$PLUGIN_PACKAGE" ]; then
  printf 'Error: a regular Stream Deck plugin package is required.\n' >&2
  exit 1
fi

WAVES_RELEASE_EVIDENCE="$CANDIDATE_EVIDENCE" \
  "$ROOT_DIR/script/release-gate.sh" candidate
/usr/bin/ruby --disable-gems "$ROOT_DIR/script/release_tool.rb" elgato-handoff prepare \
  "$CANDIDATE_EVIDENCE" "$PLUGIN_PACKAGE" "$PLUGIN_REVISION" "$OUTPUT_DIRECTORY"
/usr/bin/ruby --disable-gems "$ROOT_DIR/script/release_tool.rb" elgato-handoff verify \
  "$OUTPUT_DIRECTORY"
