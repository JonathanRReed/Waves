import AppKit
import SwiftUI
import WavesAudioCore

struct MixerRowView: View {
  @Environment(AppStore.self) private var store
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
              RoutingStateIndicator(state: app.routingState)
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
        .tint(WavesDesign.accent)
        .frame(minWidth: 150, idealWidth: 210, maxWidth: 250)
        .help(sliderHelp)
        .accessibilityLabel("Volume for \(app.displayName)")
        .accessibilityValue("\(Int((app.desiredVolume * 100).rounded()))%")
        .accessibilityHint("Adjusts the per-app volume target.")
        .accessibilityAdjustableAction { direction in
          adjustVolume(direction)
        }
        .disabled(isExcluded)

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
          .disabled(isExcluded)

        Button {
          store.focusEqualizer(for: app)
        } label: {
          Image(systemName: "slider.horizontal.3")
            .foregroundStyle(WavesDesign.accentOrSecondary(equalizerIsEnabled))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Equalizer for \(app.displayName)")
        .accessibilityLabel("Open equalizer for \(app.displayName)")
        .accessibilityValue(equalizerIsEnabled ? "On" : "Off")
        .disabled(isExcluded)

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
        .accessibilityLabel(app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
        .sensoryFeedback(.selection, trigger: app.isMuted)
        .disabled(isExcluded)
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
        .fill(Color.white.opacity(isHovering ? 0.05 : 0))
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

  private var canControlAudio: Bool {
    app.routingState == .managed
  }

  private var sliderHelp: Text {
    canControlAudio
      ? Text("Adjust \(app.displayName) volume")
      : Text("Adjust to enroll \(app.displayName) in managed routing.")
  }

  private var muteHelp: Text {
    canControlAudio
      ? Text(app.isMuted ? "Unmute" : "Mute")
      : Text("Mute to enroll \(app.displayName) in managed routing.")
  }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
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

private struct MixerRowHelpers {
  static func canControlAudio(_ app: AudioApp) -> Bool {
    app.routingState == .managed
  }

  static func sliderHelp(for app: AudioApp) -> Text {
    canControlAudio(app)
      ? Text("Adjust \(app.displayName) volume")
      : Text("Adjust to enroll \(app.displayName) in managed routing.")
  }

  static func muteHelp(for app: AudioApp) -> Text {
    canControlAudio(app)
      ? Text(app.isMuted ? "Unmute" : "Mute")
      : Text("Mute to enroll \(app.displayName) in managed routing.")
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

  var body: some View {
    Button(opensMainWindow ? "Open Equalizer in Waves" : "Equalizer") {
      store.focusEqualizer(for: app, source: opensMainWindow ? .running : nil)
      if opensMainWindow {
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    .disabled(isExcluded)

    Divider()

    Button(app.isPinned ? "Unpin" : "Pin") {
      store.togglePinned(app)
    }
    if !isExcluded {
      Menu("Output Device") {
        Button {
          store.setOutputDevice(nil, for: app)
        } label: {
          if app.targetDeviceUID == nil { Label("System Default", systemImage: "checkmark") }
          else { Text("System Default") }
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
              if app.targetDeviceUID == device.id { Label(device.name, systemImage: "checkmark") }
              else { Text(device.name) }
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
          .foregroundStyle(WavesDesign.accentOrTertiary(app.isPinned))
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
        RoutingStateDot(state: app.routingState, notes: app.notes)
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
      .tint(WavesDesign.accent)
      .frame(width: 104)
      .padding(.trailing, 2)
      .help(sliderHelp)
      .accessibilityLabel("Volume for \(app.displayName)")
      .accessibilityValue("\(Int((app.desiredVolume * 100).rounded()))%")
      .accessibilityHint("Adjusts the per-app volume target.")
      .accessibilityAdjustableAction { direction in
        adjustVolume(direction)
      }
      .disabled(isExcluded)

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
        .disabled(isExcluded)

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
      .accessibilityLabel(app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
      .accessibilityHint(app.isMuted ? "Restores audio for this app." : "Silences this app.")
      .disabled(isExcluded)
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

  private var showsLevelMeter: Bool {
    !app.isMuted && !isExcluded && (app.routingState == .managed || app.routingState == .live)
  }

  private var meterRMS: Float { store.liveLevels[app.logicalID]?.rms ?? 0 }
  private var meterPeak: Float { store.liveLevels[app.logicalID]?.peak ?? 0 }

  private var canControlAudio: Bool {
    MixerRowHelpers.canControlAudio(app)
  }

  private var sliderHelp: Text {
    MixerRowHelpers.sliderHelp(for: app)
  }

  private var muteHelp: Text {
    MixerRowHelpers.muteHelp(for: app)
  }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
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

private struct BoostMenu: View {
  @Environment(AppStore.self) private var store
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
        .foregroundStyle(WavesDesign.accentOrTertiary(isBoosted))
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

private extension RoutingState {
  var indicatorColor: Color {
    switch self {
    case .managed:
      .green
    case .live:
      WavesDesign.accent
    case .monitorOnly:
      .secondary
    case .recent:
      .secondary
    case .error:
      .red
    }
  }
}

private struct RoutingStateIndicator: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let state: RoutingState

  @ViewBuilder
  var body: some View {
    if state != .monitorOnly {
      HStack(spacing: 4) {
        Image(systemName: symbolName)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(color)
          .frame(width: 10)
          // The Live badge's waveform gently cycles its bars while audio is
          // playing — a quiet "this is alive" pulse — and holds still otherwise
          // and under Reduce Motion.
          .symbolEffect(.variableColor.iterative, isActive: state == .live && !reduceMotion)

        Text(state.displayName)
          .font(.caption2.weight(.medium))
          .foregroundStyle(color)
          .lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(backgroundOpacity), in: Capsule())
      // Under Increase Contrast, add a solid outline so the chip reads as a
      // distinct element rather than a faint tint.
      .overlay {
        if contrast == .increased {
          Capsule().strokeBorder(color, lineWidth: 1)
        }
      }
      .help(Text(helpText))
      .accessibilityLabel(Text(helpText))
    }
  }

  private var color: Color { state.indicatorColor }

  private var backgroundOpacity: Double {
    if contrast == .increased { return 0.28 }
    switch state {
    case .monitorOnly, .recent:
      return 0.08
    default:
      return 0.12
    }
  }

  private var symbolName: String {
    switch state {
    case .managed:
      "checkmark.circle.fill"
    case .live:
      "waveform"
    case .monitorOnly:
      "checkmark.circle"
    case .recent:
      "clock.fill"
    case .error:
      "exclamationmark.triangle.fill"
    }
  }

  private var helpText: String {
    switch state {
    case .managed:
      "Managed route is active."
    case .live:
      "Live audio source detected."
    case .monitorOnly:
      "Ready to manage. Move the slider or mute the app to start per-app control."
    case .recent:
      "Recent audio source."
    case .error:
      "Route setup failed."
    }
  }
}

private struct RoutingStateDot: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let state: RoutingState
  // When the route errored, the failure reason is otherwise visible only in
  // the full window's inline note; surface it here so a menu-bar user can see
  // why volume/mute didn't take effect (hover tooltip + VoiceOver).
  var notes: String? = nil

  var body: some View {
    Image(systemName: symbolName)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .frame(width: 12, height: 12)
      // Match the main window: a live source's waveform shimmers while playing.
      .symbolEffect(.variableColor.iterative, isActive: state == .live && !reduceMotion)
      .help(Text(helpText))
      .accessibilityLabel(Text("Route state: \(state.displayName)"))
      .accessibilityValue(Text(errorNote ?? ""))
  }

  /// The failure reason, only when the route actually errored.
  private var errorNote: String? {
    guard state == .error, let notes, !notes.isEmpty else { return nil }
    return notes
  }

  private var helpText: String {
    if let errorNote { return "\(state.displayName): \(errorNote)" }
    return state.displayName
  }

  private var color: Color { state.indicatorColor }

  private var symbolName: String {
    switch state {
    case .managed:
      "checkmark.circle.fill"
    case .live:
      "waveform"
    case .monitorOnly:
      "checkmark.circle"
    case .recent:
      "clock.fill"
    case .error:
      "exclamationmark.triangle.fill"
    }
  }
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
