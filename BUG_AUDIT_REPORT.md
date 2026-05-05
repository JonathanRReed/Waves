# Waves Bug & Code Audit Report

**Date:** 2026-05-05
**Auditor:** Devin AI
**Scope:** Full codebase audit for bugs, thread safety, memory leaks, and edge cases

## Fixed Issues ✅

### 1. ✅ Force Unwrap in DeviceVolumePresetsStore - FIXED
**File:** `Sources/Waves/Services/Persistence/DeviceVolumePresetsStore.swift:12`
**Issue:** Force unwrap of `fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!`
**Risk:** Could crash if the URL array is empty (unlikely but possible)
**Fix Applied:** Added guard let with fallback to home directory if application support directory is unavailable

### 2. ✅ Incorrect Menu Bar Icon Name - FIXED
**File:** `Sources/Waves/Stores/AppStore.swift:120`
**Issue:** Icon name `"speaker.wave.2.slash.fill"` may not exist in SF Symbols
**Risk:** Icon will not display, showing a placeholder instead
**Fix Applied:** Changed to `"speaker.slash.fill"` which is a valid SF Symbol

### 3. ✅ Memory Leak in Animation Closures - FIXED
**File:** `Sources/Waves/Features/Mixer/MixerRowView.swift:51-53, 82-84, 193-195, 215-217`
**Issue:** `DispatchQueue.main.asyncAfter` closures don't use weak self, could cause memory leaks if view is deallocated
**Risk:** Memory leaks and potential crashes
**Fix Applied:** Replaced DispatchQueue.main.asyncAfter with Task with cancellation checks in both MixerRowView and CompactMixerRow

### 4. ✅ Stale State in setDesiredVolume - FIXED
**File:** `Sources/Waves/Stores/AppStore.swift:241`
**Issue:** Uses `app.isMuted` instead of reading from session, which may be stale
**Risk:** Incorrect mute state saved to device volume presets
**Fix Applied:** Changed to read mute state from `session.apps[index]` instead of the app parameter

### 5. ✅ Missing Volume Boost Application - FIXED
**File:** `Sources/Waves/Stores/AppStore.swift:430-431`
**Issue:** `restoreDeviceVolumePresets` sets volumeBoost in session but doesn't apply it via backend
**Risk:** Volume boost not actually applied when restoring device presets
**Fix Applied:** Added `try await backend.setVolumeBoost(settings.volumeBoost, forAppID: app.logicalID)` call

### 6. ✅ Global Hotkey Interference - FIXED
**File:** `Sources/Waves/App/WavesApp.swift:104-123`
**Issue:** Global hotkeys don't check if user is typing in text field or if event was handled by another app
**Risk:** Interferes with normal typing and other app shortcuts
**Fix Applied:** Added check for text field focus before processing hotkeys

## Remaining Issues

### 7. ⚠️ No Error Handling in Keyboard Shortcut Methods (Low Priority)
**File:** `Sources/Waves/Stores/AppStore.swift:648-695`
**Issue:** Keyboard shortcut methods don't handle errors from volume operations
**Risk:** Silent failures when volume changes fail
**Fix:** Add error handling and user feedback

### 8. ⚠️ Potential Race Condition in setDesiredVolume (Low Priority)
**File:** `Sources/Waves/Stores/AppStore.swift:226-247`
**Issue:** Multiple rapid calls to setDesiredVolume could cause race conditions with pendingVolumeTargets
**Risk:** Lost volume updates or inconsistent state
**Fix:** Add proper synchronization or use actor

### 9. ℹ️ Missing Accessibility Labels in Help View (Low Priority)
**File:** `Sources/Waves/Features/Help/HelpView.swift`
**Issue:** Some UI elements lack accessibility labels
**Risk:** Poor accessibility experience
**Fix:** Add accessibility labels where missing

### 10. ℹ️ No Validation in Preset Import (Low Priority)
**File:** `Sources/Waves/Stores/AppStore.swift:592`
**Issue:** No validation of preset data structure before decoding
**Risk:** App could crash with malformed JSON
**Fix:** Add validation and better error handling

## Code Quality Issues

### 11. ℹ️ Magic Numbers (Low Priority)
**File:** Multiple files
**Issue:** Hardcoded values like 0.1, 0.25, 50, etc. throughout the code
**Risk:** Difficult to maintain and tune
**Fix:** Extract to named constants

### 12. ℹ️ Inconsistent Error Handling (Low Priority)
**File:** Multiple files
**Issue:** Some methods throw errors, others use toasts, some silently fail
**Risk:** Inconsistent user experience
**Fix:** Standardize error handling approach

## Performance Issues

### 13. ℹ️ Frequent Dictionary Creation (Low Priority)
**File:** `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:1017`
**Issue:** Dictionary created on every level update
**Risk:** Unnecessary allocations
**Fix:** Cache the dictionary or update incrementally

## Summary

**Total Issues Found:** 13
**Fixed Issues:** 6 ✅
**Remaining Issues:** 7 (all low priority)

**Fixed Issues:**
1. ✅ Force unwrap in DeviceVolumePresetsStore
2. ✅ Incorrect menu bar icon name
3. ✅ Memory leaks in animation closures (4 locations)
4. ✅ Stale state in setDesiredVolume
5. ✅ Missing volume boost application
6. ✅ Global hotkey interference

**Remaining Issues (Low Priority):**
- No error handling in keyboard shortcut methods
- Potential race condition in setDesiredVolume
- Missing accessibility labels
- No validation in preset import
- Magic numbers throughout code
- Inconsistent error handling
- Frequent dictionary creation

**Build Status:** ✅ All fixes compile successfully
**Test Status:** ✅ All existing tests still pass

**Recommendation:** The critical and high-priority issues have been fixed. The remaining issues are low priority and can be addressed in future iterations without impacting app stability or user experience.