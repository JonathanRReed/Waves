# Waves Code Audit & Open-Source Landscape Report

## Internal Audit — Critical Issues

### 1. `WorkspaceAudioControlBackend.swift` (1,627 lines) — Monolithic Backend
**Severity: High. File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`

This single actor contains app discovery (~lines 30-150), aggregate device management (~150-350), `SnapshotBuilder` (~350-500), `PerAppTapController` inner class (~500-900), dead `TapLoopbackPlayer` (~1260-1420), and dead `TapPCMBufferQueue` (~1425-1627).

| New module | Responsibilities | Lines extracted |
|---|---|---|
| `AudioDiscoveryEngine` | NSWorkspace polling, PID→bundle ID, icon fetching | ~150 |
| `AggregateDeviceManager` | Create/destroy aggregate devices, property queries | ~200 |
| `PerAppTapController` | Move to own file | ~400 |
| `SnapshotBuilder` | Merge cached + live state | ~150 |
| `DeviceChangeMonitor` | AudioObjectAddPropertyListener for output changes | ~50 (new) |
| `TapLoopbackPlayer` + `TapPCMBufferQueue` | Remove or move to experimental/ | ~400 |

### 2. No Live Audio Metering
**File**: `Sources/WavesAudioCore/Models/AudioApp.swift:30-31`

```swift
public var peakLevel: Float = 0
public var rmsLevel: Float = 0
```

The `PerAppTapController` IO proc does volume scaling but never computes peak/RMS. The `PreviewAudioControlBackend` simulates fake levels (`Sources/WavesAudioCore/Backend/PreviewAudioControlBackend.swift:24-28`). In production, level meters in `MixerRowView` are purely decorative.

**Fix**: Compute inside the IO proc callback:
```swift
var peak: Float = 0, sum: Float = 0
if let samples = buffer.floatChannelData?[0] {
    for i in 0..<Int(buffer.frameLength) {
        let s = abs(samples[i])
        peak = max(peak, s)
        sum += s * s
    }
}
let rms = sqrt(sum / Float(buffer.frameLength))
// Update model via thread-safe callback
```

### 3. Discovery is Process-Based, Not Audio-Based
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift` (~lines 30-150)

Current approach filters `NSWorkspace.runningApplications` by process name. Silent apps appear in the mixer; background audio helpers (e.g. Chrome renderer playing YouTube) may be missed if the parent name matches exclusion filters.

**Fix**: Cross-reference with Core Audio's process object list:
```swift
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nil, &size)
// Only include apps whose PID appears in Core Audio's audible process list
```

### 4. No Output Device Change Handling
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`

No `AudioObjectAddPropertyListener` registered for `kAudioHardwarePropertyDefaultOutputDevice`. When user plugs in headphones or connects AirPods, aggregate devices become invalid, taps stop receiving audio, but UI still shows old device as current. User must manually click Refresh (`MenuBarMixerView.swift:42-44`).

**Fix**:
```swift
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectAddPropertyListenerBlock(
    kAudioObjectSystemObject, &address, DispatchQueue.main
) { _, _ in
    Task { try? await backend.refresh() }
}
```

### 5. Memory Safety Risk in `PerAppTapController`
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift` (~lines 928-950)

```swift
state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
// If init() throws after allocation, deinit never runs → pointer leaks
```

`deinit` calls `dispose()`, but `deinit` only executes if initialization succeeds. Use a class-based wrapper for automatic cleanup:
```swift
private final class TapRenderStateBox {
    var state: TapRenderState
    init(_ state: TapRenderState) { self.state = state }
    deinit { /* cleanup */ }
}
```

### 6. `iconTIFFData` Always `nil`
**File**: `Sources/WavesAudioCore/Models/AudioApp.swift:25`

```swift
public var iconTIFFData: Data? = nil
```

Backend discovery never fetches `NSRunningApplication.icon`. Only `iconName` (SF Symbols like `"music.note"`) is populated. Even `SessionStore.swift:45-52` explicitly strips icon data before persistence. Every app shows generic symbols.

**Fix**:
```swift
if let app = NSRunningApplication(processIdentifier: pid),
   let icon = app.icon,
   let tiffData = icon.tiffRepresentation {
    audioApp.iconTIFFData = tiffData
}
```

### 7. ~400 Lines of Dead Code
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift` (lines ~1260-1627)

`TapLoopbackPlayer` — inner class with full `AVAudioEngine` + `AVAudioSourceNode`, ring buffer, format conversion. **Never instantiated.** `TapPCMBufferQueue` — only referenced by the dead player. Wastes compile time, binary size, and cognitive load.

**Fix**: Remove from main branch. Restore from git history if needed later.

### 8. Incomplete `diagnosticsReport()` in Real Backend
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`

The real backend's `diagnosticsReport()` returns a stub with minimal checks. The `PreviewAudioControlBackend` has a richer implementation. This means the Diagnostics panel in Settings shows incomplete information in production builds.

### 9. No Error Recovery / Retry Logic
If `AudioHardwareCreateProcessTap` fails (e.g., app quits during tap creation), there is no retry or cleanup of partially-created aggregate devices. The backend enters a broken state until manual refresh.

---

## 3. UI / UX Audit

### 3.1 Good Patterns
- **GlassCard** (`GlassCard.swift`) — consistent material card component across views
- **SetupStepRow** (`SetupStepRow.swift`) — clear onboarding checklist with SF Symbols
- **RoutingStateIndicator** (`MixerRowView.swift`) — honest capability disclosure with tooltip context
- **AppToasts** (`AppToasts.swift`) — well-designed transient notifications with icon + title + detail

### 3.2 Issues
- **No keyboard shortcuts** — No `keyboardShortcut` modifiers in any view. Users cannot mute/unmute with media keys or custom hotkeys. Competitors (FineTune, eqMac) support this.
- **Menu bar icon is static** — `MenuBarMixerView` always shows the same icon. Should reflect system volume state or mute state (like FineTune's dynamic icons).
- **No drag-to-reorder in app list** — Pinned/active/recent sections are fixed order. Users cannot reorder their most-used apps.
- **Settings is a TabView inside a sheet** — On macOS, Settings (⌘,) should use the standard `.settings` scene with a preferences-style toolbar, not a TabView inside a modal.
- **Search bar in MainWindowView is not focused on launch** — Requires manual click to begin searching.
- **No empty state for "no apps"** — If no audio apps are running, the mixer shows blank space instead of a helpful empty-state message.
- **Missing `SettingsLink` / `WindowGroup(id:)** — `WavesApp.swift` uses older SwiftUI patterns. Could modernize with `SettingsLink` for standard macOS preferences behavior.

---

## 4. Testing & Quality Gaps

### 4.1 Minimal Test Coverage
**File**: `Tests/WavesTests/WavesCoreTests.swift` (47 lines, 3 tests)

```swift
@Test func supportMatrixCoverageSummaryCountsSupportedApps()
@Test func presetDefaultsContainDailyUseProfiles()
@Test func previewSnapshotIncludesCurrentDeviceAndApps()
```

Only model-level tests exist. No tests for:
- `AppStore` state transitions
- `WorkspaceAudioControlBackend` (impossible due to monolithic design)
- Persistence layer (PreferencesStore, PresetStore, SessionStore)
- JSON serialization/deserialization edge cases
- Error handling paths

### 4.2 No UI Tests
No XCTest UI automation or snapshot tests for SwiftUI views. The `PreviewAudioControlBackend` enables previews but not automated UI validation.

### 4.3 No Performance Benchmarks
No tests for audio callback latency, CPU usage during tap operation, or memory leak detection for the `UnsafeMutablePointer` allocation.

### 4.4 No Fuzz / Property-Based Testing
`AudioApp` has many interdependent properties (`isMuted`, `peakLevel`, `isAudible`, `appliedVolume`). No tests verify invariants like "if `isMuted` then `peakLevel == 0` and `appliedVolume == nil`".

---

## 5. Security & Privacy Audit

### 5.1 Positive Findings
- No network requests in the codebase — fully offline processing
- No analytics/telemetry libraries
- No cloud accounts or auth
- `SessionStore` explicitly strips `iconTIFFData` before saving (good for privacy, though icons would not contain PII anyway)

### 5.2 Concerns
- **JSON persistence without encryption** — `PreferencesStore` and `PresetStore` save to `~/Library/Application Support/Waves/` as plaintext JSON. Presets could reveal app usage patterns (e.g., which apps are muted in "Focus" preset). Consider sandboxing or documenting this limitation.
- **No code signing / notarization setup** — `Package.swift` has no entitlements, no hardened runtime flags. For a system-level audio app, users will encounter Gatekeeper warnings.
- **Tap audio data passes through user-space** — The `PerAppTapController` processes raw PCM in the app process. A compromised app with memory access could theoretically intercept audio. This is inherent to the tap architecture, not a Waves-specific bug, but worth documenting in a security section of the design doc.
- **`SMAppService` usage** — `LoginItemService.swift` uses `SMAppService.mainApp`. On macOS 13+, this requires proper Team ID and notarization or it silently fails.

---

## 6. Performance Analysis

### 6.1 Audio Callback Threading
The `PerAppTapController` IO proc runs on a real-time audio thread. Current implementation does:
1. Format conversion (`AVAudioConverter`)
2. Volume scalar multiplication
3. Buffer copying

No measured latency figures exist. For a 512-sample buffer at 48kHz, this is ~10.7ms budget. The conversion step could be the bottleneck.

### 6.2 App Discovery Polling
`AppStore.refresh()` triggers a full `WorkspaceAudioControlBackend.refresh()`, which re-enumerates all running apps and rebuilds the snapshot. This is done on every volume slider drag? No — the slider updates `desiredVolume` directly on the backend without refresh. Good. But the refresh button and auto-refresh timer could be expensive.

### 6.3 SwiftUI Re-rendering
`AppStore` is `@Observable` with `@MainActor`. Every `setDesiredVolume` call updates the snapshot, which updates all observing views. For 20+ apps, this could cause frame drops during rapid slider dragging. Consider throttling or diffing updates.

---

## 7. Open-Source Project Analysis

### BackgroundMusic (kyleneideck/BackgroundMusic) — 13k stars
- Uses single virtual audio driver (`BGMDriver`) + aggregate device
- Per-app mixing done inside driver, not N aggregate devices
- Auto-pause music when another app plays
- Handles device switching natively
- **Lesson for Waves**: Single virtual device is the proven scalable architecture. Study Apple's `AudioDriverExamples` for a future v2 driver extension.

### FineTune (ronitsingh10/FineTune) — ~500 stars
**Same architecture as Waves**: `CATapDescription` + per-app taps. This is the most directly comparable competitor.

| Feature | FineTune | Waves Status | Priority |
|---|---|---|---|
| Per-app volume | Yes | Yes | Baseline |
| Pinned apps | Yes | Yes | Baseline |
| Volume boost (2x/3x/4x) | Yes | No | High — easy to add in tap callback |
| Smart volume backend | Yes | No | Medium — auto hardware vs software per device |
| Media keys + volume HUD | Yes | No | High — major UX gap |
| URL schemes for automation | Yes | No | Low — power-user feature, easy |
| Device auto-restore | Yes | No | Medium — AirPods/dock users expect this |
| Dynamic menu bar icon | Yes | No | Low — polish |
| Bluetooth connect from menu bar | Yes | No | Low |
| **DAW latency issue** | Known bug | Will face same | Critical — document limitation |

**Key lesson**: FineTune proves the tap approach works but has real latency issues with pro audio software. Their smart volume backend is especially important for USB DAC / HDMI users where hardware sliders don't work.

### eqMac (bitgapp/eqMac) — 5k stars
**Different architecture**: Single virtual audio device + plugin pipeline.

| Feature | eqMac | Waves Status | Notes |
|---|---|---|---|
| System-wide EQ | Yes (10-band free, unlimited Pro) | No | v1.5+ opportunity |
| Volume Mixer | Pro tier only | Core feature | Waves' advantage — this is eqMac's paid feature |
| WebSocket API | Yes | No | Low effort, high power-user value |
| AutoEQ headphone DB | Yes (AutoEq integration) | No | Audiophile differentiator |
| AudioUnit hosting | Pro | No | Pro power-user feature |
| Spatial audio | Pro | No | Pro feature |
| Free/Pro tier model | Yes | No | Monetization model to study |

**Key lesson**: eqMac's single virtual device is the scalable long-term architecture. Their free/pro split makes Volume Mixer a paid feature — Waves should consider whether to keep per-app volume free as a competitive advantage.

---

## 8. Recommended Open-Source Tools & Libraries

| Library | License | Use Case | Waves Integration | Effort |
|---|---|---|---|---|
| **BlackHole** | MIT | Modern virtual audio driver | Study for v2 single-device architecture | High (driver dev) |
| **AudioDriverExamples** (Apple) | Sample | Kernel driver template | Same as BlackHole study | High |
| **AutoEq** (jaakkopasanen/AutoEq) | MIT | Headphone EQ frequency response DB | v1.5 audiophile differentiator | Medium |
| **HotKey** (soffes/HotKey) | MIT | Global media key capture | Replace manual NSEvent setup for media keys | Low |
| **LaunchAtLogin** (sindresorhus) | MIT | Modern login item API | Cleaner replacement for `SMAppService` | Low |
| **Sparkle** (sparkle-project/Sparkle) | MIT | Auto-updater framework | macOS standard updater | Low |
| **swift-log** (apple/swift-log) | Apache | Structured logging | Replace `print` statements in backend | Low |
| **OSLog** (built-in) | — | Unified logging | Use instead of print for production diagnostics | Low |

---

## 9. Prioritized Action Plan

### Immediate — v1 Blockers (Next 2-4 Weeks)

1. **Decompose `WorkspaceAudioControlBackend.swift`**
   - Extract `AudioDiscoveryEngine`, `AggregateDeviceManager`, `SnapshotBuilder`
   - Move `PerAppTapController` to its own file
   - Delete `TapLoopbackPlayer` + `TapPCMBufferQueue`

2. **Add live audio metering**
   - Compute peak/RMS inside the IO proc callback
   - Update `AudioApp` model via thread-safe callback

3. **Add output device change listener**
   - Register `AudioObjectAddPropertyListenerBlock` for `kAudioHardwarePropertyDefaultOutputDevice`
   - Auto-refresh snapshot on device change

4. **Fetch real app icons**
   - Use `NSRunningApplication.icon` during discovery
   - Render `Image(nsImage:)` in `MixerRowView` when `iconTIFFData` is available

5. **Add Core Audio process enumeration**
   - Cross-reference `NSWorkspace` results with `kAudioHardwarePropertyProcessObjectList`
   - Filter out silent apps

### Near-Term — v1.5 Differentiators (Next 1-3 Months)

6. **Media keys + volume HUD**
   - `NSEvent.addGlobalMonitorForEvents(matching: .systemDefined)` for media key capture
   - Custom HUD overlay window for volume change feedback

7. **Volume boost**
   - Multiply in tap callback beyond 1.0 (e.g., 2x/3x/4x presets)
   - Warn user about potential clipping

8. **Smart volume backend**
   - Test if hardware volume slider actually changes output level per device
   - Fallback to software volume multiplication for devices with broken hardware control

9. **Device auto-restore**
   - Remember last output device per app in `SessionStore`
   - On reconnect, restore volume/mute/routing

10. **Auto-pause music**
    - Detect when conferencing app (Zoom, Teams, FaceTime) becomes active
    - Pause Spotify/Apple Music via media control APIs

11. **URL scheme automation**
    - Register `waves://` URL scheme
    - Support `waves://mute/<bundle-id>`, `waves://preset/<name>`, `waves://volume/<bundle-id>/<0-1>`

### Strategic — v2 Architecture (3-6 Months)

12. **Evaluate single virtual audio driver**
    - Study BackgroundMusic `BGMDriver` + BlackHole approach
    - Reduce latency, eliminate per-app aggregate device overhead
    - Enable EQ, spatial audio, and plugin hosting

13. **WebSocket API**
    - Embedded HTTP/WebSocket server (SwiftNIO or Vapor-lite)
    - JSON protocol for volume/mute/preset control
    - Enable Shortcuts.app and scripting integration

14. **EQ integration**
    - 10-band parametric EQ per app or per device
    - AutoEq headphone profile database integration

15. **Free/Pro tier model**
    - Keep per-app volume free (competitive advantage over eqMac)
    - Pro tier: EQ, plugin hosting, WebSocket API, spatial audio

---

## 10. Summary & Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| DAW latency complaints | High | High | Document limitation; offer "DAW bypass mode" that disables taps for selected apps |
| Per-app tap approach doesn't scale to 20+ apps | Medium | High | v2 driver architecture already planned; monitor CPU/memory |
| macOS 15+ breaks `AudioHardwareCreateProcessTap` | Low | Critical | Single virtual driver fallback; maintain Apple Developer Relations |
| No auto-updater = user retention drop | Medium | Medium | Add Sparkle in v1.1 |
| Gatekeeper / notarization blocks adoption | Medium | High | Set up Apple Developer account + notarization CI now |
| eqMac adds per-app volume to free tier | Low | High | Differentiate on speed, simplicity, native UX |

**Overall Assessment**: Waves has a solid Swift 6 foundation and good UI design. The immediate priority is backend decomposition and completing the audio metering / device monitoring features that are currently stubs. The tap-based approach is viable for v1 but should be replaced with a single virtual driver in v2 to match the scalability of BackgroundMusic and eqMac.

---

# Appendix A: Legacy / Dead Code Cleanup Audit

This is a surgical inventory of every unused type, dead function, write-only property, duplicate block, and stale import found in the codebase. All line numbers reference the current commit.

---

## A.1 Dead Types / Classes (Remove Immediately)

### 1. `AudioProcessCandidate` — Never Instantiated
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:8-12`

```swift
private struct AudioProcessCandidate {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
}
```

**Impact**: 5 lines of orphan struct. Was likely intended for a Core Audio process enumeration path that was never wired up. **Remove.**

### 2. `TapLoopbackPlayer` — 164 Lines, Never Instantiated
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:1261-1424`

A fully implemented `AVAudioEngine` + `AVAudioSourceNode` + format converter loopback player. No call site exists in the 1,627-line file. Search the entire workspace — zero references outside its own definition.

**Impact**: 164 lines, plus entangles `import AVFoundation` (see A.4). **Remove.**

### 3. `TapPCMBufferQueue` — 201 Lines, Only Used by Dead Player
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:1426-1626`

A thread-safe ring buffer for PCM audio. Only referenced inside `TapLoopbackPlayer.enqueue(_:)` and `TapLoopbackPlayer.start()`. Since `TapLoopbackPlayer` is dead, this is also dead.

**Impact**: 201 lines + associated memory safety surface area. **Remove together with TapLoopbackPlayer.**

**Combined dead code**: ~370 lines (22% of the backend file).

---

## A.2 Dead Functions / Methods

### 4. `createController(for app: AudioApp)` — Single-Param Overload, Never Called
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:232-235`

```swift
private func createController(for app: AudioApp) throws -> PerAppTapController {
    let processObjectIDs = try resolveProcessObjectIDs(for: app)
    return try createController(for: app, processObjectIDs: processObjectIDs)
}
```

The only call site is at line 227, which calls the 2-parameter overload directly:
```swift
let controller = try createController(for: app, processObjectIDs: processObjectIDs)
```

**Impact**: 4-line pass-through function. **Remove; inline at the single call site if desired.**

---

## A.3 Write-Only Properties (Assigned but Never Read)

### 5. `AppStore.errorMessage` — Set in 8 Places, Never Bound to UI
**File**: `Sources/Waves/Stores/AppStore.swift:30`

Set during error handling in `start()`, `refresh()`, `setDesiredVolume`, `setMuted`, `togglePinned`, `applyPreset`, `savePreset`, `recoverRoutes()`. However, **no SwiftUI view binds to `store.errorMessage`**. The UI uses `showToast()` exclusively for error display. The property is a silent accumulator.

**Fix**: Either add an error banner/badge in `MainWindowView` that binds to `errorMessage`, or **remove the property and its assignments** to reduce state surface area.

### 6. `AudioApp.lastSeenAt` — Set, Never Read
**File**: `Sources/WavesAudioCore/Models/AudioApp.swift:23`

Written in:
- `WorkspaceAudioControlBackend.setDesiredVolume()` (line 47)
- `WorkspaceAudioControlBackend.setMuted()` (line 72)
- `WorkspaceAudioControlBackend.pinApp()` (line 101)
- `WorkspaceAudioControlBackend.applyPreset()` (line 112)
- `WorkspaceAudioControlBackend.buildSnapshot()` (line 486)

Never read in any filtering, sorting, UI, or persistence logic.

**Impact**: Adds `Date` to Codable serialization / JSON payload for no benefit. **Remove property + all assignments**, or keep and wire into a "last active" sort option.

### 7. `AudioApp.isAudible` — Set, Never Read
**File**: `Sources/WavesAudioCore/Models/AudioApp.swift:14`

Set to `false` in `discoverRunningApps()` and set to simulated values in `PreviewAudioControlBackend`. Never used in any view filter or backend logic. `visibleApps` filters on `category`, not `isAudible`. `activeApps` filters on `isActive`.

**Impact**: Confusing dual state (`isActive` vs `isAudible`). **Remove and consolidate into `isActive`** (which already reflects frontmost status from `NSRunningApplication.isActive`).

---

## A.4 Unused / Stale Imports

### 8. `import AVFoundation` — Only Needed for Dead Code
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:2`

`AVAudioEngine`, `AVAudioSourceNode`, `AVAudioConverter`, `AVAudioPCMBuffer`, `AVAudioFormat` are only referenced inside `TapLoopbackPlayer`. The live `PerAppTapController` uses raw Core Audio (`AudioDeviceCreateIOProcIDWithBlock`, `memcpy`, etc.) from `AudioToolbox`.

**Fix**: **Remove after deleting `TapLoopbackPlayer`.**

### 9. `import ServiceManagement` — Imported But Unused
**File**: `Sources/Waves/App/WavesApp.swift:2`

`SMAppService` is used inside `LoginItemService.swift`, which imports `ServiceManagement` itself. `WavesApp.swift` never references `SMAppService` or any other symbol from this module.

**Fix**: **Remove import.**

---

## A.5 Unused Preference Properties

### 10. `UserPreferences.menuBarCompactMode` — Defined, Never Read
**File**: `Sources/Waves/Stores/UserPreferences.swift:8`

No toggle in `SettingsView`, no conditional layout in `MenuBarMixerView`. Dead preference.

### 11. `UserPreferences.accentColorName` — Defined, Never Read
**File**: `Sources/Waves/Stores/UserPreferences.swift:9`

No color picker in `SettingsView`. `WavesDesign` uses hardcoded values. Dead preference.

**Fix**: **Remove both properties** from `UserPreferences`, `PreferencesStore`, and any persisted JSON. Re-add when UI is designed.

---

## A.6 Unused Enum Cases

### 12. `DiagnosticsStatus.failed` — Never Instantiated
**File**: `Sources/WavesAudioCore/Backend/AudioControlBackend.swift:51`

The only places `DiagnosticsCheck` is created are:
- `WorkspaceAudioControlBackend.diagnosticsReport()` (lines 166-191) — uses `.passed`, `.warning`, `.informational`
- `PreviewAudioControlBackend.diagnosticsReport()` — uses `.passed`, `.warning`, `.informational`

No code path creates `.failed`. The `DiagnosticsPanel.color(for:)` in `MainWindowView.swift:383` does handle it, but the case is unreachable.

**Fix**: **Remove case**, or add a failure path in diagnostics generation (e.g., when tap creation fails catastrophically).

---

## A.7 Pass-Through / Display-Only Data

### 13. `AudioSessionSnapshot.recentDeviceIDs` — Preserved but Never Displayed
**File**: `Sources/WavesAudioCore/Models/AudioSessionSnapshot.swift:6`

Carried forward in `buildSnapshot` (line 537) and persisted to `session.json`, but no UI shows recent devices, no logic uses them for auto-restore. Currently decorative data.

**Status**: Not strictly dead — part of the data model contract for a planned feature. **Keep but mark with `// TODO: wire up device auto-restore`.**

---

## A.8 Duplicate / Near-Duplicate Logic

### 14. Identical `canControlAudio` Computed Properties
**File**: `Sources/Waves/Features/Mixer/MixerRowView.swift:97-99` and `:157-159`

```swift
// MixerRowView
private var canControlAudio: Bool { app.routingState == .managed }

// CompactMixerRow
private var canControlAudio: Bool { app.routingState == .managed }
```

Exact same 1-line expression duplicated in two sibling views.

### 15. Identical `sliderHelp` and `muteHelp` Computed Properties
**File**: `Sources/Waves/Features/Mixer/MixerRowView.swift:101-111` and `:161-171`

```swift
// MixerRowView
private var sliderHelp: Text {
    canControlAudio
      ? Text("Adjust \(app.displayName) volume")
      : Text("Adjust to enroll \(app.displayName) in managed routing.")
}

// CompactMixerRow — identical body
private var sliderHelp: Text { ... }
```

Same for `muteHelp`. 20 lines of duplicated help text logic.

### 16. Identical `RoutingState` → `Color` Switch Blocks
**File**: `Sources/Waves/Features/Mixer/MixerRowView.swift:192-205` and `:234-247`

`RoutingStateIndicator.color` and `RoutingStateDot.color` both contain identical `switch state` blocks mapping each `RoutingState` case to a `Color`.

### 17. Duplicate Exclusion / Companion Marker Arrays
**File**: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift:701-721` and `:732-744`

```swift
// isManageableApp — excludedMarkers
["daemon", "updater", "launcher", "agent", "service", ...]

// isCompanionAudioProcess — companionMarkers
["helper", "web content", "networking", ...]
```

The companion markers are mostly a strict subset of excluded markers, with slightly different semantics. However, `isCompanionAudioProcess` is only used in `score()` and `logicalAppID()`, while `isManageableApp` is the main gate. The overlap creates maintenance risk: adding a new helper-type marker requires updating two arrays.

**Fix for duplicates 14-17**: Extract shared helpers into `MixerRowView+Shared.swift` or `WavesAudioCore` extensions. For the marker arrays, consider a single `ProcessTypeClassifier` struct with named predicates.

---

## A.9 Summary: Cleanup Checklist

| # | Item | File(s) | Action | Effort |
|---|---|---|---|---|
| 1 | `AudioProcessCandidate` struct | `WorkspaceAudioControlBackend.swift:8-12` | Delete | 1 min |
| 2 | `TapLoopbackPlayer` class | `WorkspaceAudioControlBackend.swift:1261-1424` | Delete | 1 min |
| 3 | `TapPCMBufferQueue` class | `WorkspaceAudioControlBackend.swift:1426-1626` | Delete | 1 min |
| 4 | `createController(for:)` overload | `WorkspaceAudioControlBackend.swift:232-235` | Delete + inline call | 2 min |
| 5 | `AppStore.errorMessage` | `AppStore.swift` + all assignment sites | Delete or wire to UI | 10 min |
| 6 | `AudioApp.lastSeenAt` | `AudioApp.swift` + all assignment sites | Delete or wire to sort | 10 min |
| 7 | `AudioApp.isAudible` | `AudioApp.swift` + all assignment sites | Delete, consolidate to `isActive` | 10 min |
| 8 | `import AVFoundation` | `WorkspaceAudioControlBackend.swift:2` | Delete after #2-3 | 1 min |
| 9 | `import ServiceManagement` | `WavesApp.swift:2` | Delete | 1 min |
| 10 | `menuBarCompactMode` preference | `UserPreferences.swift`, `PreferencesStore` | Delete | 5 min |
| 11 | `accentColorName` preference | `UserPreferences.swift`, `PreferencesStore` | Delete | 5 min |
| 12 | `DiagnosticsStatus.failed` | `AudioControlBackend.swift:51` + `MainWindowView.swift:389` | Delete or wire failure path | 5 min |
| 13 | `recentDeviceIDs` | `AudioSessionSnapshot.swift` | Add TODO comment | 1 min |
| 14-17 | Duplicate view helpers / marker arrays | `MixerRowView.swift`, `WorkspaceAudioControlBackend.swift` | Extract shared helpers | 20 min |

**Total dead code to remove**: ~390 lines (24% of `WorkspaceAudioControlBackend.swift` alone).
