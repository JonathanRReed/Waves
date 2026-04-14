import AppKit
import ServiceManagement
import SwiftUI
import WavesAudioCore

@main
struct WavesApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = AppStore(
    backend: WorkspaceAudioControlBackend(),
    preferencesStore: PreferencesStore(),
    presetStore: PresetStore(),
    loginItemService: LoginItemService()
  )
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

  var body: some Scene {
    WindowGroup("Waves", id: AppSceneID.mainWindow) {
      MainWindowView()
        .environment(store)
        .frame(minWidth: 980, minHeight: 620)
    }
    .defaultSize(width: 1100, height: 680)

    Settings {
      SettingsView()
        .environment(store)
        .frame(minWidth: 720, minHeight: 500)
    }

    MenuBarExtra(
      "Waves",
      systemImage: "speaker.wave.2.fill",
      isInserted: $showMenuBarExtra
    ) {
      MenuBarMixerView()
        .environment(store)
        .frame(width: 400)
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

enum AppSceneID {
  static let mainWindow = "main-window"
}
