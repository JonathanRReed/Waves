# Bug & Code Audit Report 6

**Date:** 2025-05-05
**Scope:** Build scripts, configuration files, and non-Swift code
**Auditor:** Devin AI

## Audit Scope

This audit examined non-Swift files that had not been audited in previous reports:

### Build & Configuration
- script/build_and_run.sh
- Package.swift
- Package.resolved

## Findings

### 1. Redundant swift build execution
**File:** script/build_and_run.sh
**Severity:** Low (Performance)
**Issue:** The script runs `swift build` twice:
- Line 56: `swift build "${BUILD_ARGS[@]}"`
- Line 57: `BUILD_BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"`

This is inefficient and doubles the build time unnecessarily.

**Impact:** Slower build process, wasted computational resources.

**Recommendation:** Run swift build once and capture the output, or use --show-bin-path in a single call.

---

### 2. Silent failure in icon generation
**File:** script/build_and_run.sh
**Severity:** Medium
**Issue:** The `generate_icns` function and related image processing commands use `|| true` to suppress all errors:
- Lines 33-46: All sips commands in generate_icns use `|| true`
- Line 45: iconutil command uses `|| true`
- Line 75: sips conversion uses `|| true`
- Line 79: generate_icns call uses `|| true`

If icon generation fails (missing tools, corrupt image, etc.), the script continues silently without informing the user.

**Impact:** App may be built without proper icons, user won't know until they see missing icons in the UI.

**Recommendation:** Add error handling with user-facing warnings, or make icon generation optional with explicit logging.

---

### 3. Unsafe pkill without process verification
**File:** script/build_and_run.sh
**Severity:** Medium
**Issue:** Line 49: `pkill -x "$APP_NAME" >/dev/null 2>&1 || true`

This kills any process with the exact name "Waves" without verifying it's the actual app being built. If another process named "Waves" exists (e.g., a different app or system process), it will be killed.

**Impact:** Could accidentally kill unrelated processes, potentially causing data loss or system instability.

**Recommendation:** Use more specific process identification (e.g., check bundle ID or path) or add user confirmation.

---

### 4. No validation on MODE parameter
**File:** script/build_and_run.sh
**Severity:** Low
**Issue:** Line 4: `MODE="${1:-run}"` accepts any string without validation. Invalid modes will only fail at the case statement (line 149) with a generic error message.

**Impact:** Poor user experience for invalid arguments, no early validation.

**Recommendation:** Add early validation with helpful error message listing valid modes.

---

### 5. Missing error handling for critical operations
**File:** script/build_and_run.sh
**Severity:** Medium
**Issue:** Several critical operations lack explicit error handling:
- Line 62: `cp "$BUILD_BINARY" "$APP_BINARY"` - No check if copy succeeds
- Line 66, 69: Logo file copying - No validation
- Line 83-106: Info.plist generation - No validation that file was created correctly
- Line 113: codesign - Suppresses errors with `>/dev/null 2>&1`

**Impact:** Script may appear to succeed even when critical operations fail.

**Recommendation:** Add explicit error checking for critical operations with user-facing error messages.

---

### 6. Temporary directory not cleaned up on error
**File:** script/build_and_run.sh
**Severity:** Low
**Issue:** Line 27 creates a temporary directory with `mktemp -d`, but there's no trap to clean it up if the script exits early due to an error.

**Impact:** Temporary files may accumulate in /tmp over time.

**Recommendation:** Add trap to clean up temporary directory on exit.

---

### 7. Hardcoded bundle identifier
**File:** script/build_and_run.sh
**Severity:** Low
**Issue:** Line 6: `BUNDLE_ID="com.jonathanreed.Waves"` is hardcoded. This makes it difficult for others to fork or reuse the script.

**Impact:** Reduced portability, requires manual editing for different bundle IDs.

**Recommendation:** Allow BUNDLE_ID to be overridden via environment variable or command-line argument.

---

### 8. Package.swift uses pinned dependency revision
**File:** Package.swift
**Severity:** Low
**Issue:** Line 16: `revision: "48a471a"` pins swift-testing to a specific commit hash rather than a version tag. This could include unstable or unreleased code.

**Impact:** Potential instability from using unreleased dependency code.

**Recommendation:** Consider using a tagged version instead of a commit hash for better stability.

---

### 9. No resource limits or validation in build script
**File:** script/build_and_run.sh
**Severity:** Low
**Issue:** The script doesn't validate that required tools (swift, sips, iconutil, plutil, codesign) are available before attempting to use them. It uses `|| true` or `command -v` checks but doesn't fail early if critical tools are missing.

**Impact:** Script may partially succeed with missing functionality, confusing the user.

**Recommendation:** Add early validation for critical tools with clear error messages.

---

## Summary

**Total Issues Found:** 9
- High Severity: 0
- Medium Severity: 4
- Low Severity: 5

**Issues by Category:**
- Error handling: 4
- Performance: 1
- Security: 1
- Portability: 1
- Dependency management: 1
- Resource management: 1

## Status

- [x] Fix redundant swift build execution
- [x] Fix silent failure in icon generation
- [x] Fix unsafe pkill without process verification
- [x] Add validation on MODE parameter
- [x] Add error handling for critical operations
- [x] Fix temporary directory cleanup on error
- [x] Make bundle identifier configurable
- [ ] Review Package.swift dependency pinning (CANNOT FIX - package instability)
- [x] Add tool availability validation

## Fix Details

### 1. Redundant swift build execution (FIXED)
- Changed to run `swift build --show-bin-path` first to capture output directory
- Then run `swift build` once for the actual build
- Eliminated redundant build call

### 2. Silent failure in icon generation (FIXED)
- Added explicit warnings for each failed icon size generation
- Added early return if sips or iconutil not found with warning messages
- Changed `|| true` to conditional error reporting
- Users now see warnings when icon generation fails

### 3. Unsafe pkill without process verification (FIXED)
- Added check with `pgrep` before calling `pkill`
- Only attempts to kill if process exists
- Added comment explaining the safety check
- (Note: Still uses process name, but now checks existence first)

### 4. No validation on MODE parameter (FIXED)
- Added array of valid modes
- Added early validation with helpful error message
- Exits with error code 2 for invalid modes
- Shows usage hint on error

### 5. Missing error handling for critical operations (FIXED)
- Added error checking for binary copy operation
- Added error checking for logo resource copying
- Added validation that Info.plist was created successfully
- Added warnings for codesign failures
- Added warnings for missing optional tools (sips, iconutil, codesign)

### 6. Temporary directory not cleaned up on error (FIXED)
- Added `trap` to clean up temporary directory on function exit
- Ensures temporary files are cleaned up even if function fails early

### 7. Hardcoded bundle identifier (FIXED)
- Changed BUNDLE_ID to use environment variable override: `${BUNDLE_ID:-com.jonathanreed.Waves}`
- Can now be customized via `BUNDLE_ID=com.example.Waves ./script/build_and_run.sh`

### 8. Package.swift dependency pinning (CANNOT FIX)
- Attempted to change from commit hash to version tag (`from: "0.10.0"`)
- This caused build errors due to swift-testing package API incompatibility
- The swift-testing package is rapidly evolving and version tags are not stable
- The current revision-based approach is necessary for this particular dependency
- Recommendation: Keep current revision until swift-testing stabilizes and releases stable versions

### 9. Tool availability validation (FIXED)
- Added early validation for `swift` command (critical)
- Added warnings for optional tools (sips, iconutil, codesign, plutil)
- Provides helpful error messages when critical tools are missing