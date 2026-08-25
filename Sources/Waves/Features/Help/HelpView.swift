import SwiftUI
import WavesAudioCore

struct HelpView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        headerSection
        educationSection
        quickStartSection
        soundSection
        routingSection
        keyboardShortcutsSection
        urlSchemeSection
        externalControlSection
        profilesSection
        troubleshootingSection
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var educationSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Learn Waves")
        .font(.headline)

      Text(
        "Review the 1.5 update, rerun the required Mac readiness guide, or take the optional tour on the live mixer. Your saved mix and preferences stay in place."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Button("What’s New in 1.5") {
          store.showWhatsNew()
        }
        .buttonStyle(.bordered)

        Button("Run Guided Setup") {
          store.runRequiredSetupReplay()
        }
        .buttonStyle(.bordered)

        Button("Take the Mixer Tour") {
          store.startGuidedMixerTour()
        }
        .wavesGlassProminentButton()
      }
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
  }

  private var soundSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sound, EQ, and Sidechain Focus")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        bullet(
          "All equalizers live in Sound, in the sidebar. One card edits the shared All Managed Audio curve or any single app; switch with the chips above the sliders"
        )
        bullet("An app row's EQ button jumps straight to that app's curve in Sound")
        bullet(
          "Tell Waves what each app plays (Music, Meeting, Game…), then set its priority: Foreground, Normal, Background, or Never Adjust"
        )
        bullet(
          "Smart Hybrid moves the app in front up one priority tier while it's audible. Your assigned priorities still set the limits"
        )
        bullet("Follow Front App makes the audible app in front the foreground directly")
        bullet("Voice and meeting apps need actual speech before anything ducks for them")
        bullet(
          "While the sound is being shaped, the wave visualizer shows it: EQ'd streams get more texture, ducked streams ride lower, and small EQ / Focus chips name what's active"
        )
      }

      Text(
        "Adaptive Mix only turns apps down temporarily. It never pauses or mutes anything, and your manual levels stay put."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
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

  private var routingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Routing and Wave Link")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        bullet("Managed means Waves owns the app's route and its audio controls are available")
        bullet(
          "Monitoring only means Waves can see the app but is not currently changing its audio path"
        )
        bullet(
          "Choose the per-app controller in Settings > Mixer. Waves keeps ordinary apps manageable, or Wave Link takes ownership while Waves monitors them"
        )
        bullet(
          "With compatibility enabled, Waves never wraps Wave Link's mixed output. Adjust upstream apps inside Wave Link"
        )
        bullet(
          "Disable Wave Link compatibility only for a custom routing workaround. Waves then applies no Wave Link-specific duplicate-route safeguards"
        )
        bullet(
          "If audio geometry changes, Waves retries in the background. Recovery failed exposes Recover Routes, which rebuilds every Waves-managed route"
        )
      }

      Text(
        "When Waves is selected, route apps to Wave Link virtual channels if Wave Link should decide what the monitor or stream hears. Do not assign the same app through both mixers."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
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

      // Read from the live bindings rather than repeating the defaults: these
      // are editable now, so hard-coded keys here would confidently name a
      // shortcut the user had already changed.
      VStack(alignment: .leading, spacing: 8) {
        globalShortcutRow("Increase volume", .frontmostVolumeUp)
        globalShortcutRow("Decrease volume", .frontmostVolumeDown)
        globalShortcutRow("Toggle mute", .frontmostMute)
      }
      .font(.system(.body, design: .monospaced))

      Text(
        "Turn these on in Settings ▸ Shortcuts & Automation, then click any of them to record your own. They act on whichever app is in front."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text("App shortcuts")
        .font(.subheadline.weight(.semibold))

      Text(
        "Give one specific app its own mute or volume shortcut and it works no matter what is in front. Add one under App Shortcuts in Settings ▸ Shortcuts & Automation, or right-click the app in the mixer and choose Assign Mute Shortcut. Nothing is assigned by default."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Text("In-window shortcuts")
        .font(.subheadline.weight(.semibold))

      VStack(alignment: .leading, spacing: 8) {
        shortcutRow(
          action: "Select an app",
          keys: "↑ / ↓"
        )
        shortcutRow(
          action: "Mute selected app",
          keys: "Space / M"
        )
        shortcutRow(
          action: "Selected volume",
          keys: "= / -"
        )
        shortcutRow(
          action: "Boost / Pin",
          keys: "B / P"
        )
        shortcutRow(
          action: "Equalizer / Output",
          keys: "E / O"
        )
        shortcutRow(
          action: "Recover all managed routes",
          keys: "R"
        )
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

      Text(
        "The single-key commands act on the selected mixer row. E and O are disabled when Waves must yield control. R is available only when the selected route has exhausted automatic recovery, and it rebuilds all Waves-managed routes. ⌘N and ⌘R work while the mixer window is focused; ⌘, opens Settings from any Waves window."
      )
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

      Text(
        "Turn on URL scheme automation in Settings > Shortcuts & Automation before using these. When it is off, external waves:// URLs are inert."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(16)
    .wavesCard(cornerRadius: 12)
  }

  private var externalControlSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("External Control")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        bullet(
          "Allow external control in Settings > Shortcuts & Automation only for local tools you trust"
        )
        bullet(
          "Waves listens on a private Unix socket for your macOS user. It does not open a network port"
        )
        bullet(
          "The repository's wavesctl tool lists apps, changes volume or mute, reads icons, and watches state changes using protocol version 1"
        )
        bullet(
          "The Stream Deck companion is a separate app and is not bundled with Waves. It controls only routes Waves reports as managed"
        )
      }

      Text(
        "URL automation and external socket control are separate features. Both are off by default."
      )
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
        bullet("A profile is a group of apps you use together, like Work or Gaming")
        bullet("Use the + in the sidebar's Profiles section to create one")
        bullet("Pick which apps belong, and optionally capture their current levels")
        bullet("Select a profile in the sidebar to focus just those apps")
        bullet("Profiles that carry levels show an Apply Levels button")
        bullet(
          "After applying levels, Reset Mix in the toolbar puts every app back the way it was: apply Meeting for the call, reset when it ends"
        )
        bullet(
          "Right-click a profile and choose Apply at Startup to make it your baseline mix on every launch"
        )
        bullet("Switch profiles from the menu bar, and export or import them as JSON")
      }

      Text(
        "Membership-only profiles just group apps. Capture levels to also save each app's volume, mute, and boost."
      )
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
          solution: "Play sound in an app first, refresh (⌘R), or turn on Show system processes in Settings > Mixer"
        )
        troubleshootingItem(
          issue: "Volume changes not applying",
          solution:
            "Check Per-app controller in Settings > Mixer. Wave Link-owned routes must be adjusted in Wave Link. Custom workarounds can disable Wave Link compatibility, which also disables duplicate-route safeguards. For a failed Waves route, use Recover Routes, then check Diagnostics"
        )
        troubleshootingItem(
          issue: "An app shows a red Core Audio error",
          solution:
            "Some apps never produce sound (menu-bar utilities, CLI tools) and can't be managed. Right-click the row and choose 'Exclude from Waves' to stop the warning"
        )
        troubleshootingItem(
          issue: "Keyboard shortcuts not working",
          solution:
            "Check Settings > Shortcuts & Automation: shortcuts must be turned on, and a combination another app already claimed is shown there in orange. An app shortcut also needs that app to be running"
        )
        troubleshootingItem(
          issue: "Device switching issues",
          solution:
            "Open Setup & Repair to check the output, rebuild managed routes, or open the matching Sound pane"
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

  /// Names the chord actually bound to an action, or says plainly that there
  /// isn't one — a blank would read as a rendering bug.
  private func globalShortcutRow(_ title: String, _ action: HotkeyAction) -> some View {
    let binding = store.preferences.hotkeys.bindings.first { $0.action == action }
    return shortcutRow(action: title, keys: binding?.displayString ?? "Not set")
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
