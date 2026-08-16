import SwiftUI

struct MenuBarPresentationState: Equatable, Sendable {
  let hasLiveAudio: Bool
  let isSettling: Bool

  var showsWaveform: Bool {
    hasLiveAudio || isSettling
  }
}

struct MenuBarMixerView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var keepsWaveformMounted = false

  private static let waveformSettleDuration = Duration.milliseconds(1_800)

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 10) {
        if store.privacySetupPresentationState == .hidden {
          MenuBarHeader()

          if presentationState.showsWaveform {
            HeaderWaveform(height: MenuBarLayout.liveWaveformHeight)
              .padding(.horizontal, 2)
              .padding(.vertical, 3)
              .frame(maxWidth: .infinity)
              .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .fill(theme.contentFill)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .strokeBorder(theme.stroke)
              )
              .transition(
                reduceMotion
                  ? .opacity
                  : .opacity.combined(with: .move(edge: .top))
              )
          }

          MenuBarContextControls()

          if store.isLoading {
            loadingIndicator
          }

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
      .animation(
        reduceMotion ? nil : .smooth(duration: 0.2),
        value: presentationState.showsWaveform
      )

      AppToastStack()
        .padding(.top, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: MenuBarLayout.panelWidth - 32)
    }
    // MenuBarExtra(.window) already owns the outer popover material. Keeping
    // this content clear avoids stacking a custom blur and dark rectangle
    // inside the system window.
    .task {
      store.start()
    }
    .task(id: store.hasLiveAudio) {
      await updateWaveformMountState()
    }
    .onAppear { store.beginLiveLevels() }
    .onDisappear { store.endLiveLevels() }
  }

  private var presentationState: MenuBarPresentationState {
    MenuBarPresentationState(
      hasLiveAudio: store.hasLiveAudio,
      isSettling: keepsWaveformMounted && !store.hasLiveAudio
    )
  }

  private var loadingIndicator: some View {
    HStack(spacing: 7) {
      ProgressView()
        .controlSize(.small)
      Text("Refreshing audio sessions")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Refreshing audio sessions, in progress")
  }

  private func updateWaveformMountState() async {
    if store.hasLiveAudio {
      keepsWaveformMounted = true
      return
    }

    guard keepsWaveformMounted else { return }
    try? await Task.sleep(for: Self.waveformSettleDuration)
    guard !Task.isCancelled, !store.hasLiveAudio else { return }
    keepsWaveformMounted = false
  }
}
