#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE_RUNNER="$ROOT_DIR/script/run_phase.rb"
REQUESTED_PHASE="${1:-full}"

if [ ! -f "$PHASE_RUNNER" ]; then
  echo "Error: Phase runner not found at $PHASE_RUNNER." >&2
  exit 1
fi

case "$REQUESTED_PHASE" in
  full|infra|format|build|tests|tsan|package|audit) ;;
  *)
    echo "usage: $0 [full|infra|format|build|tests|tsan|package|audit]" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
QUALITY_HOME="$(mktemp -d "${TMPDIR:-/tmp}/waves-quality-home.XXXXXX")"
cleanup() {
  rm -rf "$QUALITY_HOME"
}
trap cleanup EXIT INT TERM HUP

run_phase() {
  local timeout="$1"
  local label="$2"
  shift 2
  ruby "$PHASE_RUNNER" "$timeout" "$label" "$@"
}

run_infra() {
  run_phase "${WAVES_PHASE_TIMEOUT_INFRA:-300}" "Release infrastructure self-tests" \
    ruby -I"$ROOT_DIR/script" "$ROOT_DIR/script/tests/release_infra_test.rb"
  run_phase "${WAVES_PHASE_TIMEOUT_INFRA:-300}" "Process-group deadline self-tests" \
    ruby "$ROOT_DIR/script/tests/run_phase_test.rb"
  run_phase "${WAVES_PHASE_TIMEOUT_INFRA:-300}" "Repository release contract" \
    ruby "$ROOT_DIR/script/release_tool.rb" validate-repository
  run_phase "${WAVES_PHASE_TIMEOUT_INFRA:-300}" "Repository workflow contract" \
    ruby "$ROOT_DIR/script/release_tool.rb" validate-workflows
}

run_format() {
  run_phase "${WAVES_PHASE_TIMEOUT_FORMAT:-300}" "Strict recursive Swift format and lint" \
    swift format lint --recursive --parallel --strict \
    Sources Tests Package.swift script/tsan-harness
}

run_build() {
  run_phase "${WAVES_PHASE_TIMEOUT_BUILD:-900}" "Swift debug build" swift build
  run_phase "${WAVES_PHASE_TIMEOUT_BUILD:-1200}" "Swift release build" swift build -c release
}

run_tests() {
  run_phase "${WAVES_PHASE_TIMEOUT_TESTS:-1800}" "Ordinary isolated Swift test suite" \
    /usr/bin/env HOME="$QUALITY_HOME" CFFIXED_USER_HOME="$QUALITY_HOME" swift test
}

run_tsan() {
  run_phase "${WAVES_PHASE_TIMEOUT_TSAN:-1800}" "Focused Thread Sanitizer suite" \
    /usr/bin/env HOME="$QUALITY_HOME" CFFIXED_USER_HOME="$QUALITY_HOME" \
    "$ROOT_DIR/script/run-tsan-harness.sh"
}

run_package() {
  run_phase "${WAVES_PHASE_TIMEOUT_PACKAGE:-2400}" "Universal unsigned app, dSYM, and DMG construction" \
    "$ROOT_DIR/script/build_and_run.sh" --release-check
  run_phase "${WAVES_PHASE_TIMEOUT_PACKAGE:-900}" "Existing package verification" \
    "$ROOT_DIR/script/build_and_run.sh" --verify
  run_phase "${WAVES_PHASE_TIMEOUT_SMOKE:-300}" "Packaged GUI smoke" \
    /usr/bin/env HOME="$QUALITY_HOME" CFFIXED_USER_HOME="$QUALITY_HOME" \
    SMOKE_LOG_PATH="$ROOT_DIR/dist/package-smoke-process.log" \
    "$ROOT_DIR/script/build_and_run.sh" --package-smoke
}

run_audit() {
  run_phase "${WAVES_PHASE_TIMEOUT_AUDIT:-300}" "Realtime callback source audit" \
    "$ROOT_DIR/script/audit-realtime-callback.sh"
}

if [ "$REQUESTED_PHASE" = "full" ]; then
  run_infra
  run_format
  run_build
  run_tests
  run_tsan
  run_package
  run_audit
else
  "run_${REQUESTED_PHASE}"
fi

echo "Waves quality gate phase '$REQUESTED_PHASE' passed."
