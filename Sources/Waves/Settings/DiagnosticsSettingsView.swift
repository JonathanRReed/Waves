import SwiftUI
import WavesAudioCore

struct DiagnosticsSettingsView: View {
  @Environment(AppStore.self) private var store
  let onOpenSetup: () -> Void

  var body: some View {
    SettingsForm {
      Section {
        LabeledContent("Current device", value: store.currentDeviceName)
        if let kind = store.session.currentDevice?.kind {
          LabeledContent("Device type", value: kind.displayName)
        }
        LabeledContent("Running apps", value: store.sourceInventorySummary)
      } header: {
        Text("Audio")
      } footer: {
        Text(
          "Waves captures each managed app's audio with a Core Audio process tap, applies your volume, mute, boost, and EQ, and plays it to the output device. Everything is processed on this Mac."
        )
      }

      Section {
        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "arrow.clockwise")
        }
        .disabled(!store.isAudioRunning || store.isRecovering)
        .help("Reattaches per-app audio routes. Try this if volume or mute stops working for an app.")
        Button {
          onOpenSetup()
        } label: {
          Label("Open Setup & Repair", systemImage: "wrench.and.screwdriver")
        }
        Button {
          store.copyDiagnosticsToPasteboard()
        } label: {
          Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
        }
        .disabled(store.diagnostics == nil)
        .help("Copies a plain-text route health report for a bug report.")
      } header: {
        Text("Repair")
      }

      if let diagnostics = store.diagnostics {
        Section("Checks") {
          ForEach(diagnostics.checks) { check in
            DiagnosticsCheckRow(check: check)
          }
        }
      } else {
        Section {
          DiagnosticsUnavailableView()
        }
      }
    }
    .onAppear {
      // Settings panes are switched by destroying/recreating view identity
      // (see SettingsView.paneContent), not by a native TabView that keeps
      // inactive tabs alive — so onAppear fires every time this pane is
      // revisited, not just once. Diagnostics already has its own explicit
      // "Refresh Diagnostics" action for re-probing on demand, so only
      // auto-refresh the first time there's nothing to show yet; don't redo
      // the backend snapshot rebuild + capture-permission re-probe on every
      // tab click.
      if store.isAudioRunning, store.diagnostics == nil {
        store.refreshDiagnostics()
      }
    }
  }
}

private struct DiagnosticsCheckRow: View {
  let check: DiagnosticsCheck

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Shape-differentiated glyph per status so color-blind sighted users can
      // distinguish pass/warn/fail/info by shape, not hue alone. Hidden from
      // VoiceOver; the combined label below carries the status word.
      Image(systemName: check.status.symbolName)
        .foregroundStyle(check.status.color)
        .accessibilityHidden(true)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(check.title)
        Text(check.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(check.status.statusWord): \(check.title). \(check.detail)")
  }
}

private struct DiagnosticsUnavailableView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Diagnostics are not loaded", systemImage: "waveform.path.ecg")
        .font(.headline)

      Text(
        store.session.backendStatus.lastError
          ?? "Refresh diagnostics to check permissions, route recovery, and app support."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Button {
          store.refreshDiagnostics()
        } label: {
          Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
        }
        .wavesGlassProminentButton()
        .disabled(!store.isAudioRunning)

        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "waveform.path")
        }
        .buttonStyle(.bordered)
        .disabled(!store.isAudioRunning || store.isRecovering)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}
