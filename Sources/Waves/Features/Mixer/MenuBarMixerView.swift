import AppKit
import SwiftUI
import WavesAudioCore

struct MenuBarMixerView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  // Seed at the cap so the scroller measures DOWN to fit on the first preference
  // update, rather than growing up from a 1pt collapse (a visible first-frame
  // flash). Content at/above the cap is already correct.
  @State private var sectionsHeight: CGFloat = 440
  private static let maxSectionsHeight: CGFloat = 440

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 14) {
        // Pinned chrome — header, the live waves band, and the output/profile
        // pickers stay put while only the app sections below scroll.
        MenuBarHeader()

        // The "mixed waves" band — a live visualization of the combined audio
        // energy of everything currently playing. Quiet when silent, alive when
        // sound is flowing. Rendered on a solid content surface (not glass) per
        // Apple's material guidance for real-time graphics.
        HeaderWaveform(height: 40)
          .padding(.horizontal, 4)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color.black.opacity(0.22))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(WavesDesign.stroke)
          )

        // Output device and profile pickers are the two most-used quick
        // controls, so they sit as a tight cluster (Control Center groups
        // related compact rows close together, not with full section spacing).
        VStack(spacing: 6) {
          OutputDevicePicker()
          ProfileQuickPicker()
        }

        if store.isLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Refreshing audio sessions")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Refreshing audio sessions, in progress")
        }

        sectionsScroller

        Divider()

        footer
      }
      .padding(14)

      AppToastStack()
        .padding(.top, 10)
        .padding(.trailing, 10)
        .frame(maxWidth: WavesDesign.menuBarPanelWidth - 40)
    }
    // `.menuBarExtraStyle(.window)` gives this popover raw system vibrancy
    // with no tint of its own, unlike the Settings/Onboarding windows (which
    // both sit on WavesBackground()) — without this, whatever's behind the
    // popover on the user's desktop (wallpaper, another window) shows through
    // as an uncontrolled color blob instead of the app's calm dark backdrop.
    .background(WavesBackground())
    .task {
      store.start()
    }
    .onAppear { store.beginLiveLevels() }
    .onDisappear { store.endLiveLevels() }
  }

  /// The Pinned / Live / Recent sections in a height-capped scroller, so a long
  /// list never pushes the footer (Settings / Launch-at-login / Open Waves) off
  /// the bottom of the screen. The scroller fits its content up to
  /// `maxSectionsHeight`, then scrolls — chrome and footer stay pinned, the way
  /// Control Center caps its list rather than its chrome.
  private var sectionsScroller: some View {
    // De-duplicate apps across sections: an app pinned by the user renders only
    // under "Pinned", never again under "Live" or "Recent".
    let pinnedIDs = Set(store.pinnedApps.map(\.logicalID))
    let liveApps = store.liveApps.filter { !pinnedIDs.contains($0.logicalID) }
    let recentApps = store.recentApps.filter { !pinnedIDs.contains($0.logicalID) }
    let isEmpty = store.pinnedApps.isEmpty && liveApps.isEmpty && recentApps.isEmpty

    return ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if !store.pinnedApps.isEmpty {
          CompactSection(title: "Pinned", systemImage: "pin.fill", apps: store.pinnedApps, focusFilter: .pinned)
        }

        CompactSection(title: "Live", systemImage: "waveform", apps: liveApps, focusFilter: .frontmost)

        if store.preferences.showRecentApps {
          CompactSection(title: "Recent", systemImage: "clock", apps: recentApps, maxVisible: 3, focusFilter: .recent)
        }

        if !store.isLoading && isEmpty {
          allQuietState
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: SectionsHeightKey.self, value: proxy.size.height)
        }
      )
    }
    .frame(height: min(max(sectionsHeight, 1), Self.maxSectionsHeight))
    .scrollBounceBehavior(.basedOnSize)
    .onPreferenceChange(SectionsHeightKey.self) { sectionsHeight = $0 }
  }

  private var allQuietState: some View {
    VStack(spacing: 10) {
      WavesMark(size: 34)
        .opacity(0.85)
      Text("All quiet")
        .font(.callout.weight(.semibold))
      Text("Play audio in an app and it shows up here, ready to mix.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      // Settings lives in the footer; a single Refresh keeps this state focused.
      Button("Refresh") {
        store.refresh()
      }
      .controlSize(.small)
      .accessibilityLabel("Refresh app list")
      .padding(.top, 2)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 22)
    .padding(.horizontal, 12)
  }

  private var footer: some View {
    HStack {
      Button("Open Waves") {
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
      }
      .accessibilityLabel("Open Waves main window")

      Button("Settings") {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
      }
      .accessibilityLabel("Open Settings")

      Spacer()

      // Show the label, not just a bare switch — a lone toggle reads as
      // meaningless without hovering for the tooltip.
      Toggle(
        isOn: Binding(
          get: { store.launchAtLoginEnabled },
          set: { store.launchAtLoginEnabled = $0 }
        )
      ) {
        Text("Launch at login")
      }
      .toggleStyle(.switch)
      .help("Launch Waves automatically at login")
    }
    .controlSize(.small)
  }
}

/// Measures the menu-bar sections' natural height so the scroller can fit content
/// up to a cap, then scroll — instead of a fixed-height frame that reserves empty
/// space when only one app is playing.
private struct SectionsHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// The menu-bar panel header: the Waves mark (which gently animates while audio
/// is live), a live-state status line, and a refresh control.
private struct MenuBarHeader: View {
  @Environment(AppStore.self) private var store
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: 10) {
      WavesMark(size: 26, live: store.hasLiveAudio)

      VStack(alignment: .leading, spacing: 1) {
        Text("Waves")
          .font(.headline)
        Text(statusLine)
          .font(.caption2)
          // Under Increase Contrast, raw cyan on the popover can fail contrast;
          // fall back to primary text there (mirrors RoutingStateIndicator).
          .foregroundStyle(
            store.hasLiveAudio
              ? (contrast == .increased ? Color.primary : WavesDesign.accent)
              : Color.secondary
          )
          .lineLimit(1)
          .contentTransition(.numericText())
      }

      Spacer()

      Button {
        store.refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.callout)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .clipShape(Circle())
      .accessibilityLabel("Refresh app list")
      .help("Refresh the app list")
      .keyboardShortcut("r", modifiers: [.command])
    }
  }

  private var statusLine: String {
    // Real playing count (no linger), so the header text follows the live signal
    // like the ribbon — it never keeps claiming "1 app playing" after silence.
    let live = store.actuallyLiveApps.count
    if store.visibleApps.contains(where: \.isMuted) && live == 0 {
      return "Muted"
    }
    switch live {
    case 0: return "Nothing playing"
    case 1: return "1 app playing"
    default: return "\(live) apps playing"
    }
  }
}

/// Compact output-device switcher for the menu-bar panel — the most frequent
/// action a menu-bar audio utility performs ("Control Center for app audio").
private struct OutputDevicePicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.availableDevices) { device in
        Button {
          store.selectOutputDevice(device)
        } label: {
          if device.id == store.currentDeviceID {
            Label(device.name, systemImage: "checkmark")
          } else {
            Text(device.name)
          }
        }
      }
      if store.availableDevices.isEmpty {
        Text("No output devices found").foregroundStyle(.secondary)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "hifispeaker.fill")
          .foregroundStyle(.secondary)
        Text(store.currentDeviceName)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
    }
    .menuStyle(.borderlessButton)
    .wavesCard()
    .accessibilityLabel("Output device")
    .accessibilityValue(store.currentDeviceName)
    .help("Switch the system output device")
    .onAppear { store.refreshOutputDevices() }
  }
}

private struct ProfileQuickPicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.profiles) { profile in
        Button {
          store.applyProfile(profile)
        } label: {
          if profile.id == store.activeProfileID {
            Label(profile.name, systemImage: "checkmark")
          } else {
            Text(profile.name)
          }
        }
      }
      if store.profiles.isEmpty {
        Text("No profiles yet").foregroundStyle(.secondary)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "rectangle.stack")
          .foregroundStyle(.secondary)
        Text(activeProfileName)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
    }
    .menuStyle(.borderlessButton)
    .wavesCard()
    .accessibilityLabel("Profile")
    .accessibilityValue(activeProfileName)
    .help("Switch profile")
  }

  private var activeProfileName: String {
    guard let id = store.activeProfileID,
          let profile = store.profiles.first(where: { $0.id == id }) else {
      return "Profiles"
    }
    return profile.name
  }
}

private struct CompactSection: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  var systemImage: String?
  let apps: [AudioApp]
  var maxVisible: Int = 4
  /// The scope this section corresponds to in the main window's sidebar, so
  /// "N more in Waves" can ask the window to switch there instead of leaving
  /// it on whatever scope it already happened to be showing.
  var focusFilter: SourceFilter?

  var body: some View {
    if !apps.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        WavesSectionHeader(
          title,
          systemImage: systemImage,
          trailing: AnyView(
            Text("\(apps.count)")
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(WavesDesign.tertiaryColor)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.15), in: Capsule())
          )
        )

        VStack(spacing: 2) {
          ForEach(apps.prefix(maxVisible)) { app in
            CompactMixerRow(app: app)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                  .fill(Color.white.opacity(0.04))
              )
              // Rows ease in/out as apps enter or leave the section (e.g. when a
              // just-silenced app finishes lingering in Live), so membership
              // changes glide instead of popping. Under Reduce Motion this
              // degrades to a plain fade with no slide/scale (mirrors AppToasts).
              .transition(reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                  ))
          }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: apps.map(\.id))

        if apps.count > maxVisible {
          Button {
            if let focusFilter {
              store.focusSource(focusFilter)
            }
            openWindow(id: AppSceneID.mainWindow)
            NSApp.activate(ignoringOtherApps: true)
          } label: {
            Label("\(apps.count - maxVisible) more in Waves", systemImage: "ellipsis.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .wavesLinkPointer()
          .accessibilityHint("Opens the main Waves window to show all \(title.lowercased()) apps.")
        }
      }
    }
  }
}
