import SwiftUI
import WavesAudioCore

struct MuteShortcutContext: Identifiable {
  let id: String
}

/// Records the keyboard shortcuts for one app, opened from that app's row in the
/// mixer.
///
/// The same assignments live in Settings ▸ Shortcuts & Automation. This exists because the row
/// is where the thought occurs — deciding to mute Slack from anywhere happens
/// while looking at Slack's row, not while reading a settings list.
struct MuteShortcutSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  let appID: String

  private var appName: String {
    FriendlyAppName.resolve(appID, in: store.session.apps)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Shortcuts for \(appName)")
          .font(.headline)
        Text("These act on \(appName) from anywhere, whatever app is in front.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        row("Toggle mute", .muteApp(appID))
        row("Volume up", .volumeUpApp(appID))
        row("Volume down", .volumeDownApp(appID))
      }

      if !store.preferences.enableKeyboardShortcuts {
        // The shortcut records and persists fine with the master switch off; it
        // simply will not fire. Say so here rather than letting someone record
        // one and conclude Waves is broken.
        Label(
          "Keyboard shortcuts are turned off, so these won't fire yet.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Button("Turn On Keyboard Shortcuts") {
          store.setKeyboardShortcutsEnabled(true)
        }
        .controlSize(.small)
        .disabled(!store.isAudioRunning)
      }

      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func row(_ title: String, _ action: HotkeyAction) -> some View {
    let binding = store.preferences.hotkeys.binding(for: action)
    return HStack {
      Text(title)
      Spacer(minLength: 16)
      ShortcutRecorder(
        binding: binding,
        isUnavailable: binding.map(store.isHotkeyRejected) ?? false,
        onRecord: { chord in
          switch store.assignHotkey(chord, to: action, replacing: binding?.id) {
          case .success: nil
          case .failure(let error): store.hotkeyMessage(for: error)
          }
        },
        onClear: {
          if let binding { store.removeHotkey(id: binding.id) }
        }
      )
    }
  }
}
