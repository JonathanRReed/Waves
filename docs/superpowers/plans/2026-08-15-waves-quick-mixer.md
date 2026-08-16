# Waves Quick Mixer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the oversized 440-point menu-bar panel with a compact 372-point quick mixer that prioritizes pinned and live apps, hides excluded apps, moves secondary controls into a row menu, and preserves Waves' routing and accessibility guarantees.

**Architecture:** Keep `MenuBarExtra(.window)` and make the menu-bar feature a small set of SwiftUI views under `Features/Mixer/MenuBar`. Introduce one pure layout-policy type that accepts pinned, live, and recent snapshots, deduplicates by logical app identity, removes excluded apps, caps the entire list at seven rows, and reports overflow. Keep route capability and accessibility policy shared with the main mixer instead of duplicating audio rules.

**Tech Stack:** Swift 6, SwiftUI, AppKit at existing window-opening edges, Swift Testing, Swift Package Manager, existing rendered UI harness.

## Global Constraints

- Deployment target remains macOS 14.2 or later.
- Release builds remain universal for Apple Silicon and Intel.
- Keep `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- The menu-bar width is exactly 372 points.
- The menu-bar list shows at most seven unique apps total.
- Excluded apps never appear in the menu-bar quick mixer.
- Pinned apps precede live apps; live apps precede recent apps.
- Existing route capability, VoiceOver, Increase Contrast, Reduce Transparency, and Reduce Motion behavior remains intact.
- No audio backend or realtime callback behavior changes in this plan.
- Use two-space Swift indentation and existing naming conventions.

---

### Task 1: Define and test the quick-list policy

**Files:**
- Create: `Sources/Waves/Features/Mixer/MenuBar/MenuBarLayout.swift`
- Create: `Tests/WavesTests/MenuBarLayoutTests.swift`

**Interfaces:**
- Consumes: `[AudioApp]` snapshots and a caller-supplied exclusion predicate.
- Produces:
  - `enum MenuBarAppGroup: String, Hashable, Sendable { case pinned, live, recent }`
  - `struct MenuBarAppItem: Identifiable, Hashable, Sendable`
  - `struct MenuBarAppListSnapshot: Equatable, Sendable`
  - `enum MenuBarLayout { static let panelWidth: CGFloat; static let maximumVisibleApps: Int; static func makeAppList(...) -> MenuBarAppListSnapshot }`

- [ ] **Step 1: Write the failing policy tests**

Create `Tests/WavesTests/MenuBarLayoutTests.swift`:

```swift
import Testing
import WavesAudioCore

@testable import Waves

@Test func menuBarLayoutUsesApprovedCompactMetrics() {
  #expect(MenuBarLayout.panelWidth == 372)
  #expect(MenuBarLayout.maximumVisibleApps == 7)
}

@Test func menuBarListOrdersDeduplicatesExcludesAndCapsGlobally() {
  let pinned = [
    menuBarApp("pinned-a", name: "Pinned A", pinned: true),
    menuBarApp("shared", name: "Shared", pinned: true),
  ]
  let live = [
    menuBarApp("shared", name: "Shared", state: .live),
    menuBarApp("live-a", name: "Live A", state: .live),
    menuBarApp("excluded", name: "Excluded", state: .live),
  ]
  let recent = (1...8).map {
    menuBarApp("recent-\($0)", name: "Recent \($0)", state: .recent)
  }

  let snapshot = MenuBarLayout.makeAppList(
    pinned: pinned,
    live: live,
    recent: recent,
    isExcluded: { $0.logicalID == "excluded" }
  )

  #expect(snapshot.items.map(\.app.logicalID) == [
    "pinned-a", "shared", "live-a", "recent-1", "recent-2", "recent-3", "recent-4",
  ])
  #expect(snapshot.items.map(\.group) == [
    .pinned, .pinned, .live, .recent, .recent, .recent, .recent,
  ])
  #expect(snapshot.hiddenCount == 4)
  #expect(snapshot.overflowFocus == .recent)
}

@Test func menuBarListOmitsRecentWhenDisabled() {
  let snapshot = MenuBarLayout.makeAppList(
    pinned: [],
    live: [menuBarApp("live", name: "Live", state: .live)],
    recent: [menuBarApp("recent", name: "Recent", state: .recent)],
    includesRecent: false,
    isExcluded: { _ in false }
  )

  #expect(snapshot.items.map(\.app.logicalID) == ["live"])
  #expect(snapshot.hiddenCount == 0)
  #expect(snapshot.overflowFocus == nil)
}

private func menuBarApp(
  _ id: String,
  name: String,
  pinned: Bool = false,
  state: RoutingState = .managed
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: id,
    pid: 42,
    bundleID: "test.\(id)",
    displayName: name,
    category: .media,
    desiredVolume: 0.5,
    appliedVolume: 0.5,
    isPinned: pinned,
    routingState: state,
    compatibility: .supported
  )
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter MenuBarLayoutTests
```

Expected: compilation failure because `MenuBarLayout`, `MenuBarAppGroup`, and `MenuBarAppListSnapshot` do not exist.

- [ ] **Step 3: Implement the minimal pure policy**

Create `Sources/Waves/Features/Mixer/MenuBar/MenuBarLayout.swift`:

```swift
import CoreGraphics
import WavesAudioCore

enum MenuBarAppGroup: String, Hashable, Sendable {
  case pinned
  case live
  case recent
}

struct MenuBarAppItem: Identifiable, Hashable, Sendable {
  let app: AudioApp
  let group: MenuBarAppGroup

  var id: String { app.logicalID }
}

struct MenuBarAppListSnapshot: Equatable, Sendable {
  let items: [MenuBarAppItem]
  let hiddenCount: Int
  let overflowFocus: SourceFilter?
}

enum MenuBarLayout {
  static let panelWidth: CGFloat = 372
  static let maximumVisibleApps = 7
  static let maximumSectionsHeight: CGFloat = 420
  static let liveWaveformHeight: CGFloat = 28

  static func makeAppList(
    pinned: [AudioApp],
    live: [AudioApp],
    recent: [AudioApp],
    includesRecent: Bool = true,
    isExcluded: (AudioApp) -> Bool
  ) -> MenuBarAppListSnapshot {
    var seen = Set<String>()
    var all: [MenuBarAppItem] = []

    func append(_ apps: [AudioApp], group: MenuBarAppGroup) {
      for app in apps where !isExcluded(app) && seen.insert(app.logicalID).inserted {
        all.append(MenuBarAppItem(app: app, group: group))
      }
    }

    append(pinned, group: .pinned)
    append(live, group: .live)
    if includesRecent {
      append(recent, group: .recent)
    }

    let visible = Array(all.prefix(maximumVisibleApps))
    let hiddenCount = max(0, all.count - visible.count)
    let overflowFocus: SourceFilter? = hiddenCount == 0 ? nil : {
      guard let firstHidden = all.dropFirst(visible.count).first else { return nil }
      switch firstHidden.group {
      case .pinned: return .pinned
      case .live: return .frontmost
      case .recent: return .recent
      }
    }()

    return MenuBarAppListSnapshot(
      items: visible,
      hiddenCount: hiddenCount,
      overflowFocus: overflowFocus
    )
  }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter MenuBarLayoutTests
```

Expected: all three tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waves/Features/Mixer/MenuBar/MenuBarLayout.swift Tests/WavesTests/MenuBarLayoutTests.swift
git commit -m "test: define compact menu bar layout policy"
```

---

### Task 2: Wire the approved width and remove duplicate layout ownership

**Files:**
- Modify: `Sources/Waves/App/WavesApp.swift`
- Modify: `Sources/Waves/Shared/UI/DesignSystem.swift`
- Modify: `Tests/WavesTests/RenderedUISmokeTests.swift`

**Interfaces:**
- Consumes: `MenuBarLayout.panelWidth` from Task 1.
- Produces: one width source for the scene, toast stack, and rendering tests.

- [ ] **Step 1: Add a failing contract assertion**

In `Tests/WavesTests/RenderedUISmokeTests.swift`, add to `primarySurfaceAccessibilityAndKeyboardContractsMatchRenderedControls()`:

```swift
#expect(MenuBarLayout.panelWidth == 372)
```

Replace menu render sizes that use `WavesDesign.menuBarPanelWidth` with `MenuBarLayout.panelWidth`.

- [ ] **Step 2: Run the rendered contract test and verify RED**

Run:

```bash
swift test --filter primarySurfaceAccessibilityAndKeyboardContractsMatchRenderedControls
```

Expected: failure until all menu-bar width references are migrated.

- [ ] **Step 3: Migrate production references**

In `WavesApp.swift`:

```swift
.frame(width: MenuBarLayout.panelWidth)
```

In the menu-bar toast overlay, use:

```swift
.frame(maxWidth: MenuBarLayout.panelWidth - 40)
```

Delete `WavesDesign.menuBarPanelWidth` from `DesignSystem.swift` after code search confirms no remaining references.

- [ ] **Step 4: Run focused tests and search for stale references**

Run:

```bash
swift test --filter primarySurfaceAccessibilityAndKeyboardContractsMatchRenderedControls
rg "menuBarPanelWidth" Sources Tests
```

Expected: test passes and `rg` returns no matches.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waves/App/WavesApp.swift Sources/Waves/Shared/UI/DesignSystem.swift Tests/WavesTests/RenderedUISmokeTests.swift
git commit -m "refactor: centralize compact menu bar metrics"
```

---

### Task 3: Extract the panel shell, context controls, and footer

**Files:**
- Replace: `Sources/Waves/Features/Mixer/MenuBarMixerView.swift`
- Create: `Sources/Waves/Features/Mixer/MenuBar/MenuBarHeader.swift`
- Create: `Sources/Waves/Features/Mixer/MenuBar/MenuBarContextControls.swift`
- Create: `Sources/Waves/Features/Mixer/MenuBar/MenuBarFooter.swift`
- Create: `Tests/WavesTests/MenuBarPresentationTests.swift`

**Interfaces:**
- Consumes: `AppStore`, `MenuBarLayout`, `HeaderWaveform`, existing profile/device actions.
- Produces:
  - `struct MenuBarHeader: View`
  - `struct MenuBarContextControls: View`
  - `struct MenuBarFooter: View`
  - `struct MenuBarPresentationState: Equatable, Sendable`

- [ ] **Step 1: Write failing presentation-state tests**

Create `Tests/WavesTests/MenuBarPresentationTests.swift`:

```swift
import Testing

@testable import Waves

@Test func idleQuickMixerDoesNotReserveWaveformSpace() {
  let state = MenuBarPresentationState(hasLiveAudio: false, isSettling: false)
  #expect(state.showsWaveform == false)
}

@Test func liveOrSettlingQuickMixerShowsCompactWaveform() {
  #expect(MenuBarPresentationState(hasLiveAudio: true, isSettling: false).showsWaveform)
  #expect(MenuBarPresentationState(hasLiveAudio: false, isSettling: true).showsWaveform)
  #expect(MenuBarLayout.liveWaveformHeight == 28)
}
```

- [ ] **Step 2: Run and verify RED**

```bash
swift test --filter MenuBarPresentationTests
```

Expected: compilation failure because `MenuBarPresentationState` does not exist.

- [ ] **Step 3: Implement the panel shell and state**

`MenuBarMixerView.swift` becomes root composition only:

```swift
import SwiftUI

struct MenuBarPresentationState: Equatable, Sendable {
  let hasLiveAudio: Bool
  let isSettling: Bool
  var showsWaveform: Bool { hasLiveAudio || isSettling }
}

struct MenuBarMixerView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 10) {
        if store.privacySetupPresentationState == .hidden {
          MenuBarHeader()
          MenuBarContextControls()
          MenuBarAppList()
          Divider()
          MenuBarFooter()
        } else {
          PrivacySetupSurface(style: .compact)
          Divider()
          MenuBarFooter()
        }
      }
      .padding(12)

      AppToastStack()
        .padding(.top, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: MenuBarLayout.panelWidth - 40)
    }
    .task { store.start() }
    .onAppear { store.beginLiveLevels() }
    .onDisappear { store.endLiveLevels() }
  }
}
```

Do not apply `WavesBackground()` to the root. Let the system popover own the outer material.

`MenuBarHeader` contains the 26-point mark, status text, refresh button, and a conditional 28-point waveform below the title row. Reuse the existing status wording and accessibility labels.

`MenuBarContextControls` places output and profile menus in one `HStack(spacing: 8)` with each menu receiving `.frame(maxWidth: .infinity)`.

`MenuBarFooter` contains `Open Waves…`, a spacer, and a gear button with `Open Settings` accessibility text. Do not include Launch at Login.

- [ ] **Step 4: Run focused tests and parse the extracted files**

```bash
swift test --filter MenuBarPresentationTests
swiftc -frontend -parse Sources/Waves/Features/Mixer/MenuBarMixerView.swift Sources/Waves/Features/Mixer/MenuBar/MenuBarHeader.swift Sources/Waves/Features/Mixer/MenuBar/MenuBarContextControls.swift Sources/Waves/Features/Mixer/MenuBar/MenuBarFooter.swift
```

Expected: tests pass and parse succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waves/Features/Mixer/MenuBarMixerView.swift Sources/Waves/Features/Mixer/MenuBar Tests/WavesTests/MenuBarPresentationTests.swift
git commit -m "refactor: extract compact menu bar shell"
```

---

### Task 4: Build the unified app list and two-line row

**Files:**
- Create: `Sources/Waves/Features/Mixer/MenuBar/MenuBarAppList.swift`
- Create: `Sources/Waves/Features/Mixer/MenuBar/MenuBarAppRow.swift`
- Modify: `Sources/Waves/Features/Mixer/MixerRowView.swift`
- Modify: `Tests/WavesTests/MenuBarLayoutTests.swift`
- Modify: `Tests/WavesTests/UIAccessibilityTask9Tests.swift`

**Interfaces:**
- Consumes: `MenuBarLayout.makeAppList`, `MixerRouteControlPolicy`, `MixerRowAccessibility`, AppStore actions.
- Produces:
  - `struct MenuBarAppList: View`
  - `struct MenuBarAppRow: View`
  - shared `MixerRowActionsMenu` extracted from the existing context-menu implementation.

- [ ] **Step 1: Add failing row-action and overflow tests**

Extend `MenuBarLayoutTests.swift`:

```swift
@Test func overflowFocusUsesTheFirstHiddenGroup() {
  let pinned = (1...7).map { menuBarApp("p\($0)", name: "Pinned \($0)", pinned: true) }
  let live = [menuBarApp("live", name: "Live", state: .live)]

  let snapshot = MenuBarLayout.makeAppList(
    pinned: pinned,
    live: live,
    recent: [],
    isExcluded: { _ in false }
  )

  #expect(snapshot.hiddenCount == 1)
  #expect(snapshot.overflowFocus == .frontmost)
}
```

Add accessibility expectations in `UIAccessibilityTask9Tests.swift` for a menu-bar row:

```swift
#expect(MenuBarRowAccessibility.moreActionsLabel(for: app) == "More actions for Keyboard Player")
#expect(MenuBarRowAccessibility.volumeValue(for: app) == "62%")
```

- [ ] **Step 2: Run and verify RED**

```bash
swift test --filter 'MenuBarLayoutTests|UIAccessibilityTask9Tests'
```

Expected: failure because `MenuBarRowAccessibility` does not exist.

- [ ] **Step 3: Implement `MenuBarAppList`**

The view computes one snapshot:

```swift
let snapshot = MenuBarLayout.makeAppList(
  pinned: store.pinnedApps,
  live: store.liveApps,
  recent: store.recentApps,
  includesRecent: store.preferences.showRecentApps,
  isExcluded: store.isExcluded
)
```

Render one capped `ScrollView` with rows grouped only when group transitions occur. Use a measured natural height capped by `MenuBarLayout.maximumSectionsHeight`. If `snapshot.items` is empty, render the existing All Quiet copy and Refresh action.

When `hiddenCount > 0`, render one button:

```swift
Button {
  if let focus = snapshot.overflowFocus { store.focusSource(focus) }
  openWindow(id: AppSceneID.mainWindow)
  NSApp.activate(ignoringOtherApps: true)
} label: {
  Label("View \(snapshot.hiddenCount) more in Waves", systemImage: "ellipsis.circle")
}
```

- [ ] **Step 4: Implement `MenuBarAppRow` and shared actions**

Create a two-line row with this shape:

```swift
VStack(alignment: .leading, spacing: 5) {
  HStack(spacing: 8) {
    AppIconView(app: app).frame(width: 20, height: 20)
    Text(app.displayName).font(.caption.weight(.medium)).lineLimit(1).layoutPriority(1)
    RoutingStateDot(app: app)
    Spacer(minLength: 6)
    Text(MenuBarRowAccessibility.volumeValue(for: app))
      .font(.caption2.monospacedDigit())
      .foregroundStyle(.secondary)
    muteButton
    Menu { MixerRowActionsMenu(app: app, opensMainWindow: true) } label: {
      Image(systemName: "ellipsis")
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
  }

  Slider(...)
    .controlSize(.small)
    .tint(theme.accent)
}
```

Move pin, boost, EQ, output, mute-shortcut, exclusion, and route-recovery actions into `MixerRowActionsMenu`. Keep the main window's existing context menu wired to the same shared view. Keep slider commit behavior and all capability gates.

Add:

```swift
enum MenuBarRowAccessibility {
  static func moreActionsLabel(for app: AudioApp) -> String {
    "More actions for \(app.displayName)"
  }

  static func volumeValue(for app: AudioApp) -> String {
    "\(Int((app.desiredVolume * 100).rounded()))%"
  }
}
```

Delete `CompactMixerRow` only after all references are migrated and rendered route-state evidence uses `MenuBarAppRow` instead.

- [ ] **Step 5: Run focused tests**

```bash
swift test --filter 'MenuBarLayoutTests|UIAccessibilityTask9Tests|primarySurfaceAccessibilityAndKeyboardContractsMatchRenderedControls'
```

Expected: all focused tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Waves/Features/Mixer/MenuBar Sources/Waves/Features/Mixer/MixerRowView.swift Tests/WavesTests/MenuBarLayoutTests.swift Tests/WavesTests/UIAccessibilityTask9Tests.swift
git commit -m "feat: add compact two-line menu mixer rows"
```

---

### Task 5: Add rendered compactness and accessibility evidence

**Files:**
- Modify: `Tests/WavesTests/RenderedUISmokeTests.swift`
- Modify: test fixture helpers in the same file only where necessary.

**Interfaces:**
- Consumes: new menu-bar views and layout policy.
- Produces: reproducible PNG evidence for width, density, long labels, idle/live state, and accessibility variants.

- [ ] **Step 1: Add rendered cases before changing fixture behavior**

Add a new test:

```swift
@Test @MainActor func quickMixerRendersCompactDensityAndAccessibilityVariants() async throws {
  let fixture = try await makeRenderedUIFixture()

  for width in [CGFloat(360), MenuBarLayout.panelWidth, CGFloat(380)] {
    let menu = MenuBarMixerView()
      .environment(fixture.store)
      .wavesTheme(palette: .waves, appearance: .dark)
      .frame(width: width)
      .fixedSize(horizontal: false, vertical: true)

    try renderEvidence(
      menu,
      filename: "menu-compact-\(Int(width)).png",
      size: NSSize(width: width, height: 620),
      appearance: .dark
    )
  }

  let accessible = MenuBarMixerView()
    .environment(fixture.store)
    .environment(
      \.wavesAccessibilityOverrides,
      WavesAccessibilityOverrides(
        reduceMotion: true,
        reduceTransparency: true,
        increasedContrast: true
      )
    )
    .wavesTheme(palette: .graphite, appearance: .light)
    .frame(width: MenuBarLayout.panelWidth)

  try renderEvidence(
    accessible,
    filename: "menu-compact-accessibility.png",
    size: NSSize(width: MenuBarLayout.panelWidth, height: 620),
    appearance: .light
  )
}
```

Add fixtures with a long app name, long device name, long profile name, more than seven eligible apps, and excluded apps.

- [ ] **Step 2: Run and verify the new render test fails for any remaining old assumptions**

```bash
WAVES_QA_OUTPUT="$PWD/.build/menu-evidence" swift test --filter quickMixerRendersCompactDensityAndAccessibilityVariants
```

Expected before final fixture updates: failure or visual evidence showing stale compact-row assumptions.

- [ ] **Step 3: Make the minimum fixture and view adjustments needed**

Ensure:

- No excluded app appears in menu evidence.
- Seven app rows maximum are visible.
- Long labels truncate on screen but remain complete in accessibility values.
- Idle evidence contains no blank 56-point waveform card.
- Footer actions remain visible.

- [ ] **Step 4: Run the full rendered UI subset**

```bash
WAVES_QA_OUTPUT="$PWD/.build/menu-evidence" swift test --filter 'RenderedUISmokeTests|quickMixerRendersCompactDensityAndAccessibilityVariants'
```

Expected: pass and PNGs written under `.build/menu-evidence`.

- [ ] **Step 5: Commit**

```bash
git add Tests/WavesTests/RenderedUISmokeTests.swift
git commit -m "test: cover compact menu mixer variants"
```

---

### Task 6: Remove legacy menu code and run release-grade verification

**Files:**
- Delete or reduce: `Sources/Waves/Features/Mixer/MenuBarMixerView.swift` legacy nested types already moved.
- Modify: `docs/DESIGN.md`
- Modify: `docs/PRODUCT.md` only to describe the new quick-mixer behavior, not release status.
- Modify: `CHANGELOG.md` under an Unreleased section.

**Interfaces:**
- Consumes: completed menu-bar feature.
- Produces: clean source layout, current design documentation, verified branch.

- [ ] **Step 1: Search for stale structures and wording**

```bash
rg "CompactMixerRow|CompactSection|menuBarPanelWidth|Launch at login" Sources/Waves/Features/Mixer Sources/Waves/App Tests/WavesTests
```

Expected: no old compact-row or per-section implementation references; `Launch at login` remains only in settings-related source/tests.

- [ ] **Step 2: Update documentation**

Document the 372-point quick mixer, unified seven-app cap, two-line rows, hidden excluded apps, secondary actions menu, conditional compact waveform, and settings-only launch-at-login control.

Add an Unreleased changelog entry with concrete user-visible behavior. Avoid marketing language.

- [ ] **Step 3: Run formatting and focused verification**

```bash
swift-format lint --recursive Sources Tests
swift test --filter 'MenuBarLayoutTests|MenuBarPresentationTests|MenuBarLayoutTests|UIAccessibilityTask9Tests|RenderedUISmokeTests'
```

Expected: no formatting violations and all menu-related tests pass.

- [ ] **Step 4: Run the repository quality gate**

```bash
./script/quality-gate.sh full
```

Expected: build, tests, rendered UI checks, packaging checks, and bounded release evidence all pass.

- [ ] **Step 5: Inspect the final diff**

```bash
git diff --check main...HEAD
git diff --stat main...HEAD
git status --short
```

Expected: no whitespace errors, no generated evidence accidentally staged, and a clean working tree.

- [ ] **Step 6: Commit documentation cleanup**

```bash
git add Sources Tests docs CHANGELOG.md
git commit -m "docs: record the compact quick mixer"
```

- [ ] **Step 7: Open a pull request**

Use the title:

```text
Redesign the menu bar as a compact quick mixer
```

The body must include:

- Why the old 440-point panel was oversized.
- The 372-point width and seven-row global cap.
- Controls moved into the row menu.
- Accessibility and rendered-UI coverage.
- Exact verification commands and results.
- Any hardware-specific behavior not covered by automation.
