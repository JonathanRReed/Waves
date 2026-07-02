import SwiftUI
import WavesAudioCore

struct HelpView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        headerSection
        quickStartSection
        keyboardShortcutsSection
        urlSchemeSection
        profilesSection
        troubleshootingSection
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Waves Help")
        .font(.title2.weight(.semibold))
      Text("How to control per-app audio with Waves.")
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
    .wavesCard(cornerRadius: 12)
  }

  private var keyboardShortcutsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keyboard Shortcuts")
        .font(.headline)

      Text("Global shortcuts")
        .font(.subheadline.weight(.semibold))

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
      }
      .font(.system(.body, design: .monospaced))

      Text("Enable keyboard shortcuts in General Settings to use these globally.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("App shortcuts")
        .font(.subheadline.weight(.semibold))

      VStack(alignment: .leading, spacing: 8) {
        shortcutRow(
          action: "Refresh app list",
          keys: "⌘R"
        )
        shortcutRow(
          action: "New profile",
          keys: "⌘N"
        )
        shortcutRow(
          action: "Open Settings",
          keys: "⌘,"
        )
      }
      .font(.system(.body, design: .monospaced))

      Text("⌘N and ⌘R work while the mixer window is focused; ⌘, opens Settings from any Waves window.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
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
          scheme: "waves://apply-profile",
          params: "name=Focus",
          description: "Apply a named profile"
        )
        urlSchemeRow(
          scheme: "waves://refresh",
          params: "",
          description: "Refresh session"
        )
      }

      Text("Enable URL scheme automation in General Settings before using these commands.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
  }

  private var profilesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Profiles")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        bullet("A profile is a group of apps you use together — like Work or Gaming")
        bullet("Use the + in the sidebar’s Profiles section to create one")
        bullet("Pick which apps belong, and optionally capture their current levels")
        bullet("Select a profile in the sidebar to focus just those apps")
        bullet("Profiles that carry levels show an “Apply Levels” button")
        bullet("Switch profiles from the menu bar, and export/import them as JSON")
      }

      Text("Membership-only profiles just group apps; capture levels to also save each app’s volume, mute, and boost.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
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
          solution: "Use 'Recover Routes' in the toolbar or Audio settings, then check Diagnostics in Advanced settings"
        )
        troubleshootingItem(
          issue: "An app shows a red Core Audio error",
          solution: "Some apps never produce sound (menu-bar utilities, CLI tools) and can't be managed — right-click the row and choose 'Exclude from Waves' to stop the warning"
        )
        troubleshootingItem(
          issue: "Keyboard shortcuts not working",
          solution: "Enable in Settings, check accessibility permissions, verify no conflicts"
        )
        troubleshootingItem(
          issue: "Device switching issues",
          solution: "Routes restore automatically; if needed, manually recover routes and check device connection"
        )
      }
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
  }

  private func helpStep(number: Int, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      // Instructional chrome stays neutral — cyan is reserved for live/selected
      // audio state (the Signal Rarity Rule in DESIGN.md).
      Text("\(number)")
        .font(.headline.weight(.bold))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(Color.secondary.opacity(0.15), in: Circle())

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

  /// A hang-indented bullet so wrapped lines align under the text, not the dot,
  /// and VoiceOver reads the sentence rather than a literal "bullet" prefix.
  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•").foregroundStyle(.secondary)
      Text(text)
    }
    .font(.body)
  }

  private func urlSchemeRow(scheme: String, params: String, description: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // Reference code, not live audio state — keep it neutral (the monospaced
      // font already sets it apart) so cyan stays reserved for "live/active".
      HStack {
        Text(scheme)
          .font(.system(.body, design: .monospaced))
        if !params.isEmpty {
          Text("?")
            .foregroundStyle(.secondary)
          Text(params)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        }
      }
      .textSelection(.enabled)
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
