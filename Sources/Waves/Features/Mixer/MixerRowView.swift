import AppKit
import SwiftUI
import WavesAudioCore

enum MixerRowAccessibility {
  static let outputDeviceMenuLabel = "Output Device"

  static func volumeLabel(for app: AudioApp) -> String {
    "Volume for \(app.displayName)"
  }

  static func equalizerLabel(for app: AudioApp) -> String {
    "Open equalizer for \(app.displayName)"
  }

  static func muteLabel(for app: AudioApp) -> String {
    app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)"
  }

  static func recoveryLabel(for app: AudioApp) -> String {
    "Recover \(app.displayName) route"
  }
}

struct MixerRouteControlPolicy: Equatable, Sendable {
  let allowsAudioControl: Bool
  let offersRecovery: Bool
  let sliderHelp: String
  let muteHelp: String
  let controlHint: String

  init(app: AudioApp) {
    switch app.routeHealthContext {
    case .verifiedRouterOwnership:
      self.init(
        allowsAudioControl: false,
        offersRecovery: false,
        reason: "Wave Link controls this route. Adjust the app in Wave Link."
      )
    case .unattributableRouterFallback:
      self.init(
        allowsAudioControl: false,
        offersRecovery: false,
        reason: "Waves is yielding this route because Wave Link ownership cannot be publicly attributed. Adjust the app in Wave Link."
      )
    case .routerMixedOutput:
      self.init(
        allowsAudioControl: false,
        offersRecovery: false,
        reason: "Waves leaves Wave Link mixed output untouched. Adjust upstream apps in Wave Link."
      )
    case .geometryRecoveryInProgress:
      self.init(
        allowsAudioControl: false,
        offersRecovery: false,
        reason: "Waves is rebuilding this route. Controls return when recovery finishes."
      )
    case .geometryRecoveryExhausted:
      self.init(
        allowsAudioControl: false,
        offersRecovery: true,
        reason: "Route recovery stopped. Use Recover Routes before changing this app."
      )
    case nil:
      let isManaged = app.routingState == .managed
      self.init(
        allowsAudioControl: true,
        offersRecovery: false,
        sliderHelp: isManaged
          ? "Adjust \(app.displayName) volume"
          : "Move the slider and Waves starts managing \(app.displayName).",
        muteHelp: isManaged
          ? (app.isMuted ? "Unmute" : "Mute")
          : "Mute it and Waves starts managing \(app.displayName).",
        controlHint: "Adjusts this app through Waves."
      )
    }
  }

  private init(allowsAudioControl: Bool, offersRecovery: Bool, reason: String) {
    self.init(
      allowsAudioControl: allowsAudioControl,
      offersRecovery: offersRecovery,
      sliderHelp: reason,
      muteHelp: reason,
      controlHint: reason
    )
  }

  private init(
    allowsAudioControl: Bool,
    offersRecovery: Bool,
    sliderHelp: String,
    muteHelp: String,
    controlHint: String
  ) {
    self.allowsAudioControl = allowsAudioControl
    self.offersRecovery = offersRecovery
    self.sliderHelp = sliderHelp
    self.muteHelp = muteHelp
    self.controlHint = controlHint
  }
}

struct MixerRowView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  let app: AudioApp
  @State private var animateMuteChange = false
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 10) {
        AppIconView(app: app)

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(app.displayName)
              .font(.callout.weight(.medium))
              .lineLimit(1)

            if app.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pinned")
            }

            if isExcluded {
              Text("Excluded")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.secondary.opacity(0.15), in: Capsule())
                .accessibilityLabel("Excluded from Waves")
            }
          }

          HStack(spacing: 6) {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)

            // Hide the managed/live route chip for excluded apps — Waves isn't
            // controlling them, so showing a route state would be misleading.
            if !isExcluded {
              RoutingStateIndicator(app: app)
              if routePolicy.offersRecovery {
                RouteRecoveryButton(app: app, compact: false)
              }
            }
          }
        }
        .frame(minWidth: 150, idealWidth: 240, maxWidth: .infinity, alignment: .leading)

        Spacer(minLength: 10)

        Slider(
          value: Binding(
            get: { Double(app.desiredVolume) },
            set: { newValue in
              store.setDesiredVolume(Float(newValue), for: app)
            }
          ),
          in: 0...1,
          onEditingChanged: { isEditing in
            if !isEditing {
              store.commitDesiredVolume(for: app)
            }
          }
        )
        .controlSize(.small)
        .tint(theme.accent)
        .frame(minWidth: 150, idealWidth: 210, maxWidth: 250)
        .help(sliderHelp)
        .accessibilityLabel(MixerRowAccessibility.volumeLabel(for: app))
        .accessibilityValue("\(Int((app.desiredVolume * 100).rounded()))%")
        .accessibilityHint(routePolicy.controlHint)
        .accessibilityAdjustableAction { direction in
          adjustVolume(direction)
        }
        .disabled(isExcluded || !routePolicy.allowsAudioControl)

        Text("\(Int((app.desiredVolume * 100).rounded()))%")
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .frame(width: 40, alignment: .trailing)
          .contentTransition(.numericText())
          .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: app.desiredVolume)
          .accessibilityHidden(true)

        BoostMenu(app: app, compact: false)
          .disabled(isExcluded || !routePolicy.allowsAudioControl)
          .help(routePolicy.allowsAudioControl ? "Set boost for \(app.displayName)" : routePolicy.controlHint)

        Button {
          store.focusEqualizer(for: app)
        } label: {
          Image(systemName: "slider.horizontal.3")
            .foregroundStyle(theme.accentOrSecondary(equalizerIsEnabled))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(routePolicy.allowsAudioControl ? "Equalizer for \(app.displayName)" : routePolicy.controlHint)
        .accessibilityLabel(MixerRowAccessibility.equalizerLabel(for: app))
        .accessibilityValue(equalizerIsEnabled ? "On" : "Off")
        .accessibilityHint(routePolicy.controlHint)
        .disabled(isExcluded || !routePolicy.allowsAudioControl)

        Button {
          store.setMuted(!app.isMuted, for: app)
          if !reduceMotion { animateMuteChange.toggle() }
        } label: {
          Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            // Morph the speaker ⇄ slash glyph instead of hard-cutting; the bounce
            // below is the trigger accent. Falls back to a plain swap under Reduce
            // Motion (the button's accessibilityLabel still announces the change).
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
            .symbolEffect(.bounce, value: animateMuteChange)
            // A comfortable, stable tap target around the small glyph.
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(muteHelp)
        .accessibilityLabel(MixerRowAccessibility.muteLabel(for: app))
        .accessibilityHint(routePolicy.controlHint)
        .sensoryFeedback(.selection, trigger: app.isMuted)
        .disabled(isExcluded || !routePolicy.allowsAudioControl)
      }
      // Dim excluded rows, but lift the floor under Increase Contrast so the
      // already-secondary text doesn't fall below a legible ratio.
      .opacity(isExcluded ? (contrast == .increased ? 0.85 : 0.55) : 1)

      // A permanently-unroutable app's explanation is summarized once above
      // the list (see UnroutableAppsBanner) instead of repeated verbatim on
      // every such row — the Error chip above is still enough context here.
      // Genuine (possibly transient) route errors keep their inline reason.
      if app.routingState == .error, !app.hasNoAudioCapability, let notes = app.notes {
        Text(notes)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 40)
      }
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    // A quiet hover highlight so pointing at a row reads as interactive — the
    // native list feel — without shifting layout (background, not scale).
    .background(
      RoundedRectangle(cornerRadius: WavesDesign.chipCornerRadius, style: .continuous)
        .fill(isHovering ? theme.selectionFill : Color.clear)
    )
    .onHover { isHovering = $0 }
    .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovering)
    // Quiet cyan level meter on managed/live rows, fed by the store's
    // visibility-gated live-level poll. Overlay so it never shifts layout.
    .overlay(alignment: .bottomLeading) {
      if showsLevelMeter {
        RowLevelMeter(rms: meterRMS, peak: meterPeak)
      }
    }
    .contextMenu {
      MixerRowContextMenuItems(app: app, opensMainWindow: false)
    }
    .accessibilityAction(named: app.isPinned ? "Unpin" : "Pin") {
      store.togglePinned(app)
    }
    .accessibilityAction(named: isExcluded ? "Manage with Waves" : "Exclude from Waves") {
      store.setExcluded(!isExcluded, for: app)
    }
  }

  private var isExcluded: Bool { store.isExcluded(app) }
  private var equalizerIsEnabled: Bool { store.equalizerSettings(for: app).isEnabled }
  private var routePolicy: MixerRouteControlPolicy { MixerRouteControlPolicy(app: app) }

  private var showsLevelMeter: Bool {
    !app.isMuted && !isExcluded && (app.routingState == .managed || app.routingState == .live)
  }

  private var meterRMS: Float { store.liveLevels[app.logicalID]?.rms ?? 0 }
  private var meterPeak: Float { store.liveLevels[app.logicalID]?.peak ?? 0 }

  private var subtitle: String {
    var parts: [String] = []

    // Use isRecentlyLive (not isLive) so a row that just went quiet keeps reading
    // "Playing audio" for the linger window instead of flickering to "Frontmost
    // app" / "Running app" while it's still sitting in the Live list.
    if store.isRecentlyLive(app) {
      parts.append("Playing audio")
    } else if app.isActive {
      parts.append("Frontmost app")
    }

    if app.category != .unknown, app.category != .system {
      parts.append(app.category.displayName)
    } else if parts.isEmpty {
      parts.append("Running app")
    }

    // Show the routed device when the app is pinned to a non-default output.
    if app.targetDeviceUID != nil {
      parts.append("→ \(store.targetDevice(for: app)?.name ?? "Custom output")")
    }

    return parts.joined(separator: ", ")
  }

  private var sliderHelp: Text {
    Text(routePolicy.sliderHelp)
  }

  private var muteHelp: Text {
    Text(routePolicy.muteHelp)
  }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
    guard routePolicy.allowsAudioControl else { return }
    let step: Float = 0.05
    let nextValue: Float

    switch direction {
    case .increment:
      nextValue = min(app.desiredVolume + step, 1)
    case .decrement:
      nextValue = max(app.desiredVolume - step, 0)
    @unknown default:
      return
    }

    store.setDesiredVolume(nextValue, for: app)
    store.commitDesiredVolume(for: app)
  }
}

/// The Equalizer / Pin / Output Device / Exclude actions shared by both row densities, so
/// the menu-bar's compact row never silently falls behind the main window's
/// full row in capability — a menu-bar-first user can route an app to a
/// different output device or exclude it without opening the main window.
private struct MixerRowContextMenuItems: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  let app: AudioApp
  let opensMainWindow: Bool

  private var isExcluded: Bool { store.isExcluded(app) }
  private var routePolicy: MixerRouteControlPolicy { MixerRouteControlPolicy(app: app) }

  /// Shows the current chord when there is one, so the menu doubles as the
  /// answer to "did I already give this app a shortcut?".
  private var muteShortcutTitle: String {
    // Say where it opens when it isn't here. The Equalizer item directly above
    // sets this convention, and without it the menu-bar panel silently yanks
    // the full mixer window forward.
    guard let binding = store.preferences.hotkeys.binding(for: .muteApp(app.logicalID)) else {
      return opensMainWindow ? "Set Mute Shortcut in Waves…" : "Assign Mute Shortcut…"
    }
    return opensMainWindow
      ? "Mute Shortcut in Waves: \(binding.displayString)…"
      : "Mute Shortcut: \(binding.displayString)…"
  }

  var body: some View {
    Button(opensMainWindow ? "Open Equalizer in Waves" : "Equalizer") {
      store.focusEqualizer(for: app, source: opensMainWindow ? .running : nil)
      if opensMainWindow {
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    .disabled(isExcluded || !routePolicy.allowsAudioControl)

    if !isExcluded, routePolicy.allowsAudioControl {
      Button(muteShortcutTitle) {
        // The compact menu-bar panel has nowhere to put a sheet, so the request
        // travels to the main window the same way the equalizer does.
        store.requestMuteShortcutAssignment(for: app)
        if opensMainWindow {
          openWindow(id: AppSceneID.mainWindow)
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }

    Divider()

    Button(app.isPinned ? "Unpin" : "Pin") {
      store.togglePinned(app)
    }
    if !isExcluded, routePolicy.allowsAudioControl {
      Menu(MixerRowAccessibility.outputDeviceMenuLabel) {
        Button {
          store.setOutputDevice(nil, for: app)
        } label: {
          if app.targetDeviceUID == nil { Label("System Default", systemImage: "checkmark") } else { Text("System Default") }
        }
        if store.availableDevices.isEmpty {
          Divider()
          // Mirror the menu-bar OutputDevicePicker's empty state so the
          // per-app submenu doesn't silently collapse to just "System
          // Default" when no real output devices are available.
          Text("No output devices found")
            .accessibilityLabel("No output devices found")
        } else {
          Divider()
          ForEach(store.availableDevices) { device in
            Button {
              store.setOutputDevice(device, for: app)
            } label: {
              if app.targetDeviceUID == device.id { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
            }
          }
        }
      }
      .onAppear {
        store.refreshOutputDevices()
      }
    }
    Divider()
    Button(isExcluded ? "Manage with Waves" : "Exclude from Waves") {
      store.setExcluded(!isExcluded, for: app)
    }
  }
}

struct CompactMixerRow: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  let app: AudioApp
  @State private var animateMuteChange = false

  var body: some View {
    HStack(spacing: 8) {
      Button {
        store.togglePinned(app)
      } label: {
        Image(systemName: app.isPinned ? "pin.fill" : "pin")
          .font(.caption)
          .foregroundStyle(theme.accentOrTertiary(app.isPinned))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help(app.isPinned ? "Unpin from the top" : "Pin to the top")
      .accessibilityLabel(app.isPinned ? "Unpin \(app.displayName)" : "Pin \(app.displayName) to top")

      AppIconView(app: app)
        .frame(width: 18, height: 18)

      // Match the full row's weight treatment (medium) for the primary label so
      // the two densities read as the same design language; size steps down to
      // .caption to fit the compact row's tighter metrics (icon, pin, dot are
      // already caption/caption2 scale here).
      Text(app.displayName)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        // Without this, an ordinary 7-8 character name (e.g. "CodexBar")
        // truncates to "Codex…" — the row's fixed-width trailing controls
        // (slider/percent/boost/mute) already claim most of the panel's
        // fixed 400pt width, so the name needs priority over Spacer() to get
        // its fair share before SwiftUI starts compressing it.
        .layoutPriority(1)

      if isExcluded {
        Text("Excluded")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          // Without this, the compact row's tight spacing (the app-name
          // Text just before this now has its own .layoutPriority(1), so it
          // claims space first) squeezed this single word into a 3-line
          // vertical wrap ("Ex-/clu-/ded") instead of fitting on one line —
          // fixedSize forces SwiftUI to honor this label's true single-line
          // width rather than compressing its height to fit.
          .fixedSize()
          .accessibilityLabel("Excluded from Waves")
      } else {
        RoutingStateDot(app: app)
        if routePolicy.offersRecovery {
          RouteRecoveryButton(app: app, compact: true)
        }
      }

      Spacer()

      Slider(
        value: Binding(
          get: { Double(app.desiredVolume) },
          set: { newValue in
            store.setDesiredVolume(Float(newValue), for: app)
          }
        ),
        in: 0...1,
        onEditingChanged: { isEditing in
          if !isEditing {
            store.commitDesiredVolume(for: app)
          }
        }
      )
      .controlSize(.small)
      .tint(theme.accent)
      .frame(width: 104)
      .padding(.trailing, 2)
      .help(sliderHelp)
      .accessibilityLabel(MixerRowAccessibility.volumeLabel(for: app))
      .accessibilityValue("\(Int((app.desiredVolume * 100).rounded()))%")
      .accessibilityHint(routePolicy.controlHint)
      .accessibilityAdjustableAction { direction in
        adjustVolume(direction)
      }
      .disabled(isExcluded || !routePolicy.allowsAudioControl)

      // Numeric parity with the full row, so a menu-bar-first user dragging the
      // short slider can read the target they're setting.
      Text("\(Int((app.desiredVolume * 100).rounded()))%")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 30, alignment: .trailing)
        .contentTransition(.numericText())
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: app.desiredVolume)
        .accessibilityHidden(true)

      BoostMenu(app: app, compact: true)
        .disabled(isExcluded || !routePolicy.allowsAudioControl)
        .help(routePolicy.allowsAudioControl ? "Set boost for \(app.displayName)" : routePolicy.controlHint)

      Button {
        store.focusEqualizer(for: app, source: .running)
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        Text("EQ")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(theme.accentOrSecondary(equalizerIsEnabled))
          .frame(width: 28, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help(routePolicy.allowsAudioControl ? "Open equalizer for \(app.displayName)" : routePolicy.controlHint)
      .accessibilityLabel(MixerRowAccessibility.equalizerLabel(for: app))
      .accessibilityValue(equalizerIsEnabled ? "On" : "Off")
      .accessibilityHint(routePolicy.controlHint)
      .disabled(isExcluded || !routePolicy.allowsAudioControl)

      Button {
        store.setMuted(!app.isMuted, for: app)
        if !reduceMotion { animateMuteChange.toggle() }
      } label: {
        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          // Match the full row: morph the speaker ⇄ slash glyph instead of cutting.
          .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
          .symbolEffect(.bounce, value: animateMuteChange)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help(muteHelp)
      .accessibilityLabel(MixerRowAccessibility.muteLabel(for: app))
      .accessibilityHint(routePolicy.controlHint)
      .disabled(isExcluded || !routePolicy.allowsAudioControl)
    }
    .opacity(isExcluded ? (contrast == .increased ? 0.85 : 0.55) : 1)
    // Mirror the main window's quiet cyan level meter so a menu-bar-first user
    // gets the same per-row "playing" feedback. Reuses the store's live-level
    // poll (already started by the menu panel) and an overlay so layout never
    // shifts. Same RowLevelMeter as the full row.
    .overlay(alignment: .bottomLeading) {
      if showsLevelMeter {
        RowLevelMeter(rms: meterRMS, peak: meterPeak)
      }
    }
    .contextMenu {
      // Full parity with the main window's row. Equalizer opens the main
      // window because an inspector is too large for the compact menu panel.
      MixerRowContextMenuItems(app: app, opensMainWindow: true)
    }
    .accessibilityAction(named: app.isPinned ? "Unpin" : "Pin") {
      store.togglePinned(app)
    }
    .accessibilityAction(named: isExcluded ? "Manage with Waves" : "Exclude from Waves") {
      store.setExcluded(!isExcluded, for: app)
    }
  }

  private var isExcluded: Bool { store.isExcluded(app) }
  private var equalizerIsEnabled: Bool { store.equalizerSettings(for: app).isEnabled }
  private var routePolicy: MixerRouteControlPolicy { MixerRouteControlPolicy(app: app) }

  private var showsLevelMeter: Bool {
    !app.isMuted && !isExcluded && (app.routingState == .managed || app.routingState == .live)
  }

  private var meterRMS: Float { store.liveLevels[app.logicalID]?.rms ?? 0 }
  private var meterPeak: Float { store.liveLevels[app.logicalID]?.peak ?? 0 }

  private var sliderHelp: Text {
    Text(routePolicy.sliderHelp)
  }

  private var muteHelp: Text {
    Text(routePolicy.muteHelp)
  }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
    guard routePolicy.allowsAudioControl else { return }
    let step: Float = 0.05
    let nextValue: Float

    switch direction {
    case .increment:
      nextValue = min(app.desiredVolume + step, 1)
    case .decrement:
      nextValue = max(app.desiredVolume - step, 0)
    @unknown default:
      return
    }

    store.setDesiredVolume(nextValue, for: app)
    store.commitDesiredVolume(for: app)
  }
}

private struct RouteRecoveryButton: View {
  @Environment(AppStore.self) private var store
  let app: AudioApp
  let compact: Bool

  var body: some View {
    Button {
      store.recoverRoutes()
    } label: {
      if compact {
        Image(systemName: "arrow.clockwise")
          .frame(width: 18, height: 18)
      } else {
        Label("Recover", systemImage: "arrow.clockwise")
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(store.isRecovering)
    .help("Recover this route")
    .accessibilityLabel(MixerRowAccessibility.recoveryLabel(for: app))
    .accessibilityHint("Reattaches active per-app audio routes through Waves.")
  }
}

private struct BoostMenu: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  let app: AudioApp
  let compact: Bool

  private let boostOptions: [Float] = [1, 2, 3, 4]

  var body: some View {
    Menu {
      ForEach(boostOptions, id: \.self) { boost in
        Button {
          store.setVolumeBoost(boost, for: app)
        } label: {
          if boost == app.volumeBoost {
            Label("\(Int(boost))x", systemImage: "checkmark")
          } else {
            Text("\(Int(boost))x")
          }
        }
      }
    } label: {
      // Boost reads as a status signal: quiet at the 1× default, cyan + bold once
      // the app is actually boosted, so a glance finds the boosted rows.
      Text("\(Int(app.volumeBoost))x")
        .font(.caption.monospacedDigit().weight(isBoosted ? .semibold : (compact ? .regular : .medium)))
        .foregroundStyle(theme.accentOrTertiary(isBoosted))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        // Match the adjacent mute/pin buttons' 22pt minimum compact tap target —
        // a bare Text label only hit-tests its glyph bounds, which sat well under
        // HIG's ~22pt floor and made this an easy mis-click next to the mute
        // button. The frame (not just the text) is what's clickable here.
        .frame(width: compact ? 34 : 38, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .help("Set boost for \(app.displayName)")
    .accessibilityLabel("Boost for \(app.displayName)")
    .accessibilityValue("\(Int(app.volumeBoost))x")
  }

  private var isBoosted: Bool { app.volumeBoost > 1 }
}

private extension RouteHealthPresentation.Tone {
  func indicatorColor(accent: Color) -> Color {
    switch self {
    case .active: accent
    case .success: WavesDesign.success
    case .neutral: .secondary
    case .warning: WavesDesign.warning
    case .error: WavesDesign.error
    }
  }
}

private struct RoutingStateIndicator: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.wavesTheme) private var theme
  let app: AudioApp

  @ViewBuilder
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: presentation.symbolName)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 10)
        .symbolEffect(
          .variableColor.iterative,
          isActive: app.routingState == .live && !reduceMotion
        )

      Text(presentation.title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(backgroundOpacity), in: Capsule())
    .overlay {
      if contrast == .increased {
        Capsule().strokeBorder(color, lineWidth: 1)
      }
    }
    .help(Text(presentation.help))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(presentation.accessibilityLabel))
    .accessibilityValue(Text(presentation.accessibilityValue))
    .accessibilityHint(Text(presentation.help))
  }

  private var presentation: RouteHealthPresentation { RouteHealthPresentation(app: app) }
  private var color: Color { presentation.tone.indicatorColor(accent: theme.accent) }

  private var backgroundOpacity: Double {
    if contrast == .increased { return 0.28 }
    return presentation.tone == .neutral ? 0.08 : 0.12
  }
}

private struct RoutingStateDot: View {
  @Environment(\.wavesTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let app: AudioApp

  var body: some View {
    Image(systemName: presentation.symbolName)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .frame(width: 12, height: 12)
      // Match the main window: a live source's waveform shimmers while playing.
      .symbolEffect(.variableColor.iterative, isActive: app.routingState == .live && !reduceMotion)
      .help(Text(presentation.help))
      .accessibilityLabel(Text(presentation.accessibilityLabel))
      .accessibilityValue(Text(presentation.accessibilityValue))
      .accessibilityHint(Text(presentation.help))
  }

  private var presentation: RouteHealthPresentation { RouteHealthPresentation(app: app) }
  private var color: Color { presentation.tone.indicatorColor(accent: theme.accent) }
}

/// Caches decoded app icons so the icon PNG/TIFF is not re-decoded on every
/// SwiftUI body evaluation (which happens on every level/volume update).
@MainActor
private enum AppIconCache {
  static let shared = NSCache<NSString, NSImage>()

  static func icon(for app: AudioApp) -> NSImage? {
    guard let data = app.iconTIFFData else { return nil }
    let key = app.id as NSString
    if let cached = shared.object(forKey: key) {
      return cached
    }
    guard let image = NSImage(data: data) else { return nil }
    shared.setObject(image, forKey: key)
    return image
  }
}

struct AppIconView: View {
  let app: AudioApp

  var body: some View {
    Group {
      if let icon = AppIconCache.icon(for: app) {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
          .frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else {
        Image(systemName: app.iconName ?? "app")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(.tertiary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    }
    // The app name is already shown as text beside the icon, so the icon is
    // decorative for VoiceOver.
    .accessibilityHidden(true)
  }
}
