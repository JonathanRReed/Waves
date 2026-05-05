# Bug & Code Audit Report 5

**Date:** 2025-05-05
**Scope:** Previously unaudited Swift files
**Auditor:** Devin AI

## Audit Scope

This audit examined the following files that had not been audited in previous reports:

### UI Components
- MenuBarMixerView.swift
- AppToasts.swift
- DesignSystem.swift
- SetupStepRow.swift
- WavesBrandLogo.swift

### Services
- LoginItemService.swift

### Models (WavesAudioCore)
- AudioSessionSnapshot.swift
- Preset.swift
- SupportMatrix.swift
- AudioApp.swift
- AudioDevice.swift

### Tests
- WavesCoreTests.swift

## Findings

### 1. Missing validation on AudioApp model properties
**File:** Sources/WavesAudioCore/Models/AudioApp.swift
**Severity:** Medium
**Issue:** The AudioApp model lacks validation on critical properties:
- `displayName` has no length limit (could be arbitrarily long)
- `id` and `logicalID` have no length limits
- `notes` has no length limit
- `iconTIFFData` has no size limit (could be very large)
- `volumeBoost` has no bounds validation (could be negative or extremely large)

**Impact:** Could lead to excessive memory usage, UI rendering issues, or unexpected behavior.

**Recommendation:** Add validation in the initializer or use computed properties with bounds checking.

---

### 2. Missing validation on AudioDevice model properties
**File:** Sources/WavesAudioCore/Models/AudioDevice.swift
**Severity:** Medium
**Issue:** The AudioDevice model lacks validation on:
- `name` has no length limit
- `id` has no length limit

**Impact:** Could lead to excessive memory usage or UI rendering issues.

**Recommendation:** Add length limits on string properties.

---

### 3. Missing validation on PresetEntry model properties
**File:** Sources/WavesAudioCore/Models/Preset.swift
**Severity:** Medium
**Issue:** The PresetEntry model lacks validation on:
- `appID` has no length limit
- `desiredVolume` has no bounds validation (should be 0.0-1.0)

**Impact:** Could lead to invalid volume values causing unexpected behavior.

**Recommendation:** Add length limit on appID and bounds validation on desiredVolume.

---

### 4. Missing validation on SupportMatrixEntry model properties
**File:** Sources/WavesAudioCore/Models/SupportMatrix.swift
**Severity:** Medium
**Issue:** The SupportMatrixEntry model lacks validation on:
- `appID` has no length limit
- `displayName` has no length limit
- `notes` has no length limit

**Impact:** Could lead to excessive memory usage or UI rendering issues.

**Recommendation:** Add length limits on string properties.

---

### 5. Force unwrap in test file
**File:** Tests/WavesTests/WavesCoreTests.swift
**Severity:** Low
**Issue:** Multiple test functions use `try!` without proper error handling:
- Line 173: `let data = try! encoder.encode(app)`
- Line 175: `let decoded = try! decoder.decode(AudioApp.self, from: data)`
- Line 217: `let data = try! encoder.encode(snapshot)`
- Line 219: `let decoded = try! decoder.decode(AudioSessionSnapshot.self, from: data)`
- Line 240: `let data = try! encoder.encode(preset)`
- Line 242: `let decoded = try! decoder.decode(Preset.self, from: data)`

**Impact:** If encoding/decoding fails, tests will crash instead of failing gracefully.

**Recommendation:** Use `try` with proper error handling or `#expect(throws:)` for testing error conditions.

---

### 6. WavesBrandLogo static image loading not thread-safe
**File:** Sources/Waves/Shared/UI/WavesBrandLogo.swift
**Severity:** Low
**Issue:** The `logoImage` static computed property performs file I/O operations without synchronization. While Swift guarantees thread-safe initialization of static let, the file operations themselves could have issues if multiple threads try to access simultaneously.

**Impact:** Potential race condition during image loading (though unlikely in practice due to static let semantics).

**Recommendation:** Consider using a lazy loaded static with proper synchronization or dispatch_once pattern.

---

### 7. No validation on BackendStatus.lastError length
**File:** Sources/WavesAudioCore/Models/AudioSessionSnapshot.swift
**Severity:** Low
**Issue:** The `lastError` string in BackendStatus has no length limit.

**Impact:** Could lead to excessive memory usage if error messages are very long.

**Recommendation:** Add length limit (e.g., 1000 characters).

---

## Summary

**Total Issues Found:** 7
- High Severity: 0
- Medium Severity: 4
- Low Severity: 3

**Issues by Category:**
- Missing input validation: 5
- Thread safety: 1
- Test error handling: 1

## Status

- [x] Fix missing validation on AudioApp model properties
- [x] Fix missing validation on AudioDevice model properties
- [x] Fix missing validation on PresetEntry model properties
- [x] Fix missing validation on SupportMatrixEntry model properties
- [x] Fix force unwrap in test file
- [x] Fix WavesBrandLogo static image loading thread safety
- [x] Add validation on BackendStatus.lastError length

## Fix Details

### 1. AudioApp model validation (FIXED)
- Added 256 character limit on `id`, `logicalID`, `bundleID`, and `displayName`
- Added 10MB size limit on `iconTIFFData` with truncation
- Added clamping on `desiredVolume` and `appliedVolume` to [0.0, 1.0]
- Added 1000 character limit on `notes`
- Added clamping on `volumeBoost` to [0.0, 10.0]

### 2. AudioDevice model validation (FIXED)
- Added 256 character limit on `id` and `name`

### 3. PresetEntry model validation (FIXED)
- Added 256 character limit on `appID`
- Added clamping on `desiredVolume` to [0.0, 1.0]

### 4. SupportMatrixEntry model validation (FIXED)
- Added 256 character limit on `appID` and `displayName`
- Added 1000 character limit on `notes`

### 5. Test file force unwrap (FIXED)
- Replaced `try!` with `try` in all encoding/decoding tests
- Tests now properly handle errors via Swift Testing framework

### 6. WavesBrandLogo thread safety (FIXED)
- Added serial DispatchQueue for image loading
- Ensures thread-safe file I/O operations

### 7. BackendStatus.lastError validation (FIXED)
- Added 1000 character limit on `lastError`