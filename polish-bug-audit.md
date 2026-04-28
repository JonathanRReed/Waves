# Waves: Polish & Bug Audit

---

## 1. Critical Bugs

### 🔴 Data Race on `TapRenderState`
`WorkspaceAudioControlBackend.swift:903-978` — `UnsafeMutablePointer<TapRenderState>` is read by the Core Audio real-time callback and written by `apply(volume:muted:)` from the actor-isolated backend. **Fix**: serialize `apply()` onto `callbackQueue`, or use `OSAllocatedUnfairLock`.

### 🔴 `WavesApp` `@State` Actor-Init Violation
`WavesApp.swift:9-14` — `@MainActor` class `AppStore` is initialized in `@State` which may run off-main. Swift 6 strict mode will flag this. **Fix**: lazy-init in `.task` or explicit `@MainActor init`.

---

## 2. High-Priority Bugs

### 🟠 `errorMessage` Is Write-Only
`AppStore.swift:30` — Set in 8 error paths, never bound to UI. Users see toasts but the persistent `errorMessage` is orphaned state. **Fix**: either wire to a banner or remove.

### 🟠 `isLoading` Set Twice in `start()`
`AppStore.swift:132,142` — `isLoading = false` appears in `defer` and is also set manually before `backend.start()`. The manual set is redundant and may race with `defer` if `start()` throws quickly.

### 🟠 `PreviewAudioControlBackend` Confuses `isActive` with `isAudible`
`PreviewAudioControlBackend.swift:32` — `isActive = isAudible` conflates frontmost-app state with audio-detect state. In preview mode this misleads UI.

### 🟠 `MenuBarMixerView` Uses `speaker.wave.1.fill`, `MixerRowView` Uses `speaker.wave.2.fill`
Inconsistent mute icon between menu bar and main window.

---

## 3. Medium Polish / UX

### 🟡 No Keyboard Shortcuts
Main window lacks `⌘R` (refresh), `⌘S` (save preset), `⌘,` (settings). Menu bar presets menu is mouse-only.

### 🟡 `MenuBarMixerView` "Login" Toggle Is Ambiguous
The toggle label is just "Login" — should read "Launch at login".

### 🟡 `AppToastStack` Frame Modifiers Stack Confusingly
`AppToasts.swift:12-14` — nested `.frame(maxWidth:)` calls with different alignments may produce unexpected layout.

### 🟡 `DiagnosticsPanel` Uses Plain Text for Status
Could reuse `RoutingStateIndicator` color convention instead of manual `Circle()` + `Text`.

### 🟡 `CompatibilityReportView` Is Unused
Defined but never shown in any view hierarchy. Likely orphaned.

### 🟡 `GlassCard` Is Defined But Never Used
`GlassCard.swift` — nice component, zero call sites.

---

## 4. Code Quality / Dead Code

### 🟢 ~370 Lines of Dead Code in Backend
- `AudioProcessCandidate` struct (lines 8-12) — never instantiated
- `TapLoopbackPlayer` class (lines 1261-1424) — zero references
- `TapPCMBufferQueue` class (lines 1426-1626) — only used by dead player
- `createController(for app:)` overload (lines 232-235) — never called

### 🟢 Duplicate Logic
- `canControlAudio`, `sliderHelp`, `muteHelp` duplicated in `MixerRowView` + `CompactMixerRow`
- `RoutingState` -> `Color` switch duplicated in `RoutingStateIndicator` + `RoutingStateDot`
- `isCompanionAudioProcess` and `isManageableApp` share 90% of marker strings

### 🟢 Stale Imports
- `import AVFoundation` in `WorkspaceAudioControlBackend.swift` — only for dead `TapLoopbackPlayer`
- `import ServiceManagement` in `WavesApp.swift` — never used directly

### 🟢 Dead Preference Properties
`UserPreferences.swift:8-9` — `menuBarCompactMode` and `accentColorName` are defined but never read by any view.

---

## 5. Performance

### 🟡 `visibleApps` Re-sorts on Every Access
`AppStore.swift:69-73` — computed property sorts every call. Called by `pinnedApps`, `activeApps`, `recentApps`, and `sourceInventorySummary`. **Fix**: cache after `refresh()` or use lazy collection.

### 🟡 `buildSnapshot` Iterates `mergedApps` 4 Times
`WorkspaceAudioControlBackend.swift:481-556` — could consolidate routing-state loop, `disposeControllers`, and support-matrix build into a single pass.

---

## 6. Silent Failures / Error Handling

### 🟡 Persistence Stores Use `try?` Everywhere
`PreferencesStore`, `PresetStore`, `SessionStore` all silently swallow encode/decode and disk-write errors. If the sandbox is locked or disk is full, the app appears to work but loses all settings silently.

### 🟡 `deinit` Indentation Bug
`WorkspaceAudioControlBackend.swift:1143` — `deinit` has a leading space before `func`, invalid Swift syntax. Compiler currently accepts it but lint/formatters will break.

---

## 7. Missing / Incomplete

| Feature | Status | Location |
|---------|--------|----------|
| `KeyPathComparator` definition | Not found in repo | `AppStore.swift:384` |
| Live audio metering | Stub (peak/rms exist but not driven by real audio) | `AudioApp.swift:15-16` |
| Device change listener | Not implemented | N/A |
| Auto-restore on reconnect | `recentDeviceIDs` carried but unused | `AudioSessionSnapshot.swift:6` |
| Keyboard shortcuts | Not implemented | N/A |
| Menu bar dynamic icon | Hardcoded `speaker.wave.2.fill` | `WavesApp.swift:34` |

---

## Summary

**Immediate fixes (before any release):**
1. Fix `TapRenderState` data race (serialization or lock).
2. Fix `@MainActor` init in `WavesApp`.
3. Remove dead `TapLoopbackPlayer` + `TapPCMBufferQueue` (~370 lines).
4. Add keyboard shortcuts (`⌘R`, `⌘,`).
5. Make persistence errors non-silent (log or surface to UI).

**Short-term polish:**
1. Cache `visibleApps` or switch to lazy sorting.
2. Deduplicate `MixerRowView` helpers.
3. Wire `errorMessage` to a banner or remove it.
4. Unify mute icons across menu bar and main window.

**Notes:** Architecture is solid. UI looks good. Backend is close but the concurrency bugs are real blockers for production audio code.
