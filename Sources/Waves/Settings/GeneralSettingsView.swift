import SwiftUI

struct GeneralSettingsView: View {
  @Environment(AppStore.self) private var store
  @Environment(UpdaterService.self) private var updaterService
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

  var body: some View {
    SettingsForm {
      Section("Appearance") {
        Picker("Appearance", selection: PreferenceBinding.durable(store: store, \.appearance)) {
          ForEach(WavesAppearance.allCases) { appearance in
            Text(appearance.displayName).tag(appearance)
          }
        }

        Picker("Palette", selection: PreferenceBinding.durable(store: store, \.palette)) {
          ForEach(WavesPalette.allCases) { palette in
            Text(palette.displayName).tag(palette)
          }
        }
        .help("The color family Waves uses. Both palettes work in light and dark appearance.")
      }

      Section("Menu Bar & Login") {
        Toggle(isOn: $showMenuBarExtra) {
          Text("Show Waves in the menu bar")
          Text("Waves keeps running either way. Reopen this window from the Dock.")
        }
        Toggle(
          isOn: Binding(
            get: { store.launchAtLoginEnabled },
            set: { store.launchAtLoginEnabled = $0 }
          )
        ) {
          Text("Launch at login")
          Text("Start Waves automatically when you log in.")
        }
        if store.launchAtLoginRequiresApproval {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
              "Needs your approval in System Settings > General > Login Items.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(WavesDesign.warning)
            Button("Open Login Items") {
              store.openLoginItemsSettings()
            }
            .font(.caption)
          }
        }
      }

      SettingsUpdatesSection()
    }
  }

}

/// The Updates section, shared verbatim between Settings > General and the
/// About window so version and update state read the same everywhere.
struct SettingsUpdatesSection: View {
  @Environment(UpdaterService.self) private var updaterService

  var body: some View {
    Section {
      LabeledContent("Version") {
        HStack(spacing: 10) {
          Text(AppVersion.display)
            .foregroundStyle(.secondary)
          Button("Check for Updates…") {
            updaterService.checkForUpdates()
          }
          .disabled(!updaterService.canCheckForUpdates)
        }
      }

      Toggle(
        isOn: Binding(
          get: { updaterService.automaticallyChecksForUpdates },
          set: { updaterService.automaticallyChecksForUpdates = $0 }
        )
      ) {
        Text("Check for updates automatically")
        Text("Sparkle asks once before the first automatic check.")
      }

      LabeledContent("Release notes") {
        Link("waves.jonathanrreed.com", destination: URL(string: "https://waves.jonathanrreed.com")!)
          .font(.callout)
      }
    } header: {
      Text("Updates")
    } footer: {
      Text(
        "A check downloads the signed update feed from waves.jonathanrreed.com and nothing else. Waves makes no network requests until you check or turn on automatic checks."
      )
    }
  }
}

/// Reads the app's version once. "1.3.0 (6)" in a packaged build,
/// "Development" from `swift run`.
enum AppVersion {
  static var short: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  static var build: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }

  static var display: String {
    if let build { return "\(short) (\(build))" }
    return short
  }
}
