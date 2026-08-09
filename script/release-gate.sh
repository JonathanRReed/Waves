#!/usr/bin/env bash
set -euo pipefail

if [ -n "${WAVES_RELEASE_METADATA+x}" ] || [ -n "${SWIFT_SDK+x}" ]; then
  echo "Error: Release environment overrides are prohibited." >&2
  exit 2
fi
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_TOOL="$ROOT_DIR/script/release_tool.rb"
PHASE="${1:-preflight}"

case "$PHASE" in
  preflight|candidate|publication) ;;
  *)
    echo "usage: $0 [preflight|candidate|publication]" >&2
    exit 2
    ;;
esac

require_command() {
  local command_name="$1"
  local purpose="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: $command_name is required $purpose." >&2
    exit 1
  fi
}

for command_name in git ruby swift; do
  require_command "$command_name" "for the Waves release preflight"
done

if [ ! -f "$RELEASE_TOOL" ]; then
  echo "Error: Release evidence contract not found at $RELEASE_TOOL." >&2
  exit 1
fi
if [ ! -x "$ROOT_DIR/script/quality-gate.sh" ]; then
  echo "Error: Shared quality gate is missing or not executable." >&2
  exit 1
fi
if [ ! -x "$ROOT_DIR/script/build_and_run.sh" ]; then
  echo "Error: Package builder is missing or not executable." >&2
  exit 1
fi

cd "$ROOT_DIR"

run_preflight() {
  local evidence_path="${1:-}"
  local expected_revision
  expected_revision="${WAVES_EXPECTED_REVISION:-$(git rev-parse HEAD)}"

  ruby "$RELEASE_TOOL" metadata validate >/dev/null
  ruby "$RELEASE_TOOL" validate-repository
  ruby "$RELEASE_TOOL" validate-workflows

  ruby -I"$ROOT_DIR/script" -e '
    require "release_tool"
    WavesRelease::GitContract.clean_exact_revision!(
      root: ARGV.fetch(0), expected_revision: ARGV.fetch(1)
    )
  ' "$ROOT_DIR" "$expected_revision"

  if [ -L "$ROOT_DIR/dist" ]; then
    echo "Error: Artifact destination dist must not be a symbolic link." >&2
    exit 1
  fi
  if [ -e "$ROOT_DIR/dist" ] && [ ! -d "$ROOT_DIR/dist" ]; then
    echo "Error: Artifact destination dist exists but is not a directory." >&2
    exit 1
  fi
  if [ ! -w "$ROOT_DIR" ]; then
    echo "Error: Repository root is not writable for the dist artifact destination." >&2
    exit 1
  fi

  local history_arguments=(history v1.4.4 HEAD)
  if [ -n "$evidence_path" ]; then
    history_arguments+=("$evidence_path")
  fi
  ruby "$RELEASE_TOOL" "${history_arguments[@]}"
  echo "Waves release preflight passed at $expected_revision."
}

verify_signed_candidate() {
  local evidence_path="$1"
  local profile="$2"
  local revision
  revision="$(git rev-parse HEAD)"

  developer_dir="$(/usr/bin/xcode-select -p)"
  swift_path="$(/usr/bin/xcrun --find swift)"
  sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  ruby "$RELEASE_TOOL" trusted-toolchain "$developer_dir" "$sdk_path" "$swift_path" >/dev/null

  for command_name in codesign hdiutil lipo otool plutil shasum spctl xcrun; do
    require_command "$command_name" "to validate the signed candidate"
  done
  if command -v dwarfdump >/dev/null 2>&1; then
    :
  else
    echo "Error: dwarfdump is required to validate candidate dSYM identities." >&2
    exit 1
  fi

  ruby "$RELEASE_TOOL" evidence validate "$profile" "$evidence_path" "$revision"
  "$ROOT_DIR/script/build_and_run.sh" --publication-check
  ruby "$RELEASE_TOOL" verify-artifacts "$evidence_path"
  echo "Signed candidate artifacts match $profile evidence at $revision."
}

case "$PHASE" in
  preflight)
    run_preflight "${WAVES_RELEASE_EVIDENCE:-}"
    ;;
  candidate)
    evidence_path="${WAVES_RELEASE_EVIDENCE:-$ROOT_DIR/dist/release-evidence.candidate.json}"
    if [ ! -f "$evidence_path" ] || [ ! -f "$evidence_path.sha256" ]; then
      echo "Error: Candidate release gate requires a sealed evidence manifest and SHA-256 sidecar at $evidence_path." >&2
      exit 1
    fi
    run_preflight "$evidence_path"
    verify_signed_candidate "$evidence_path" candidate
    ;;
  publication)
    tag="${WAVES_RELEASE_TAG:-$(git describe --tags --exact-match 2>/dev/null || true)}"
    if [ -z "$tag" ]; then
      echo "Error: Publication release gate requires exact annotated tag v$(ruby "$RELEASE_TOOL" metadata version)." >&2
      exit 1
    fi
    temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/waves-publication-evidence.XXXXXX")"
    trap 'rm -rf "$temporary_directory"' EXIT INT TERM HUP
    embedded_manifest="$temporary_directory/release-evidence.publication.json"
    ruby "$RELEASE_TOOL" publication-tag "$tag" "$embedded_manifest"
    run_preflight "$embedded_manifest"
    verify_signed_candidate "$embedded_manifest" publication
    ;;
esac

echo "Waves release gate phase '$PHASE' passed."
