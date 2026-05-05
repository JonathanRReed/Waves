import SwiftUI
import WavesAudioCore

struct HelpView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        headerSection
        quickStartSection
        keyboardShortcutsSection
        urlSchemeSection
        presetsSection
        troubleshootingSection
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Waves Help")
        .font(.title.weight(.bold))
      Text("Your comprehensive guide to Waves audio control")
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }

  private var quickStartSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Quick Start")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        helpStep(
          number: 1,
          title: "Launch Waves",
          description: "Waves automatically detects running audio applications"
        )
        helpStep(
          number: 2,
          title: "Adjust Volumes",
          description: "Use the volume sliders to control each app individually"
        )
        helpStep(
          number: 3,
          title: "Mute Apps",
          description: "Click the speaker icon to mute or unmute specific apps"
        )
        helpStep(
          number: 4,
          title: "Pin Apps",
          description: "Right-click apps to pin them for quick access"
        )
      }
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var keyboardShortcutsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keyboard Shortcuts")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        shortcutRow(
          action: "Increase volume",
          keys: "⌘⌥↑"
        )
        shortcutRow(
          action: "Decrease volume",
          keys: "⌘⌥↓"
        )
        shortcutRow(
          action: "Toggle mute",
          keys: "⌘⌥M"
        )
        shortcutRow(
          action: "Refresh app list",
          keys: "⌘R"
        )
        shortcutRow(
          action: "Save preset",
          keys: "⌘S"
        )
        shortcutRow(
          action: "Open Settings",
          keys: "⌘,"
        )
      }
      .font(.system(.body, design: .monospaced))

      Text("Enable keyboard shortcuts in General Settings to use these globally.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var urlSchemeSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("URL Scheme Automation")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        urlSchemeRow(
          scheme: "waves://set-volume",
          params: "app=APP_ID&volume=0.5",
          description: "Set volume (0.0-1.0)"
        )
        urlSchemeRow(
          scheme: "waves://mute",
          params: "app=APP_ID&muted=true",
          description: "Mute or unmute"
        )
        urlSchemeRow(
          scheme: "waves://apply-preset",
          params: "name=Focus",
          description: "Apply named preset"
        )
        urlSchemeRow(
          scheme: "waves://refresh",
          params: "",
          description: "Refresh session"
        )
      }

      Text("Use these URL schemes to integrate Waves with other automation tools and workflows.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var presetsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Presets")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        Text("• Click the + button in the toolbar to save a new preset")
        Text("• Enter a name to save your current volume configuration")
        Text("• Click on presets in the sidebar to apply them")
        Text("• Export presets to share with others")
        Text("• Import presets from JSON files")
      }
      .font(.body)

      Text("Presets remember volume and mute states for all running apps.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private var troubleshootingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Troubleshooting")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        troubleshootingItem(
          issue: "No audio apps detected",
          solution: "Ensure apps are playing sound, enable 'Show system processes', or refresh (⌘R)"
        )
        troubleshootingItem(
          issue: "Volume changes not applying",
          solution: "Check Diagnostics in Advanced settings, try 'Recover routes now'"
        )
        troubleshootingItem(
          issue: "Keyboard shortcuts not working",
          solution: "Enable in Settings, check accessibility permissions, verify no conflicts"
        )
        troubleshootingItem(
          issue: "Device switching issues",
          solution: "Enable 'Auto-restore device', manually recover routes, check device connection"
        )
      }
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  private func helpStep(number: Int, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.headline.weight(.bold))
        .foregroundStyle(WavesDesign.accent)
        .frame(width: 24, height: 24)
        .background(WavesDesign.accent.opacity(0.15), in: Circle())

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func shortcutRow(action: String, keys: String) -> some View {
    HStack {
      Text(action)
        .foregroundStyle(.secondary)
      Spacer()
      Text(keys)
        .fontWeight(.medium)
    }
  }

  private func urlSchemeRow(scheme: String, params: String, description: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(scheme)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(WavesDesign.accent)
        if !params.isEmpty {
          Text("?")
            .foregroundStyle(.secondary)
          Text(params)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func troubleshootingItem(issue: String, solution: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(issue)
        .font(.subheadline.weight(.semibold))
      Text(solution)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}