import AppKit
import Carbon
import SwiftUI
import WavesAudioCore
import OSLog

@main
@MainActor
struct WavesApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
  @State private var store: AppStore

  init() {
    let store = AppStore(
      backend: WorkspaceAudioControlBackend(),
      preferencesStore: PreferencesStore(),
      presetStore: PresetStore(),
      sessionStore: SessionStore(),
      loginItemService: LoginItemService(),
      deviceVolumePresetsStore: DeviceVolumePresetsStore()
    )
    _store = State(initialValue: store)
    AppDelegate.bootstrapStore = store
  }

  var body: some Scene {
    // A single, unique main window for this menu-bar utility. `Window` (rather
    // than `WindowGroup`) prevents duplicate mixer windows from being opened.
    Window("Waves", id: AppSceneID.mainWindow) {
      MainWindowView()
        .environment(store)
        .frame(minWidth: 980, minHeight: 620)
        .task {
          appDelegate.setStore(store)
          store.start()
        }
    }
    .defaultSize(width: 1100, height: 680)
    .commands {
      // The Settings scene below already provides the standard "Settings…"
      // item (⌘,) in the app menu, so no custom command is needed here.
      CommandGroup(after: .toolbar) {
        Button("Refresh") {
          store.refresh()
        }
        .keyboardShortcut("r", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environment(store)
        .frame(minWidth: 720, minHeight: 500)
    }

    MenuBarExtra(
      "Waves",
      systemImage: store.menuBarIconName,
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
  static var bootstrapStore: AppStore?

  private var store: AppStore?
  private var eventMonitor: Any?

  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "URLScheme")

  func applicationDidFinishLaunching(_ notification: Notification) {
    store = Self.bootstrapStore
    store?.start()
    applyLogoBranding()
    NSApp.setActivationPolicy(.regular)
    // Waves' visual language is a dark audio-console surface (see DESIGN.md).
    // Pin the app to a dark appearance so custom dark gradients never sit under
    // light-mode (near-black) system label colors, which would render the
    // Settings, Help, and Onboarding text effectively invisible in light mode.
    NSApp.appearance = NSAppearance(named: .darkAqua)
    setupURLSchemeHandler()
    updateGlobalHotkeysState()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardShortcutsPreferenceChanged),
      name: .wavesKeyboardShortcutsPreferenceChanged,
      object: nil
    )
  }

  @objc private func keyboardShortcutsPreferenceChanged() {
    updateGlobalHotkeysState()
  }

  /// Installs the system-wide key monitor only while the user has keyboard
  /// shortcuts enabled, so Waves never observes global keystrokes otherwise.
  private func updateGlobalHotkeysState() {
    let enabled = store?.preferences.enableKeyboardShortcuts ?? false
    if enabled {
      setupGlobalHotkeys()
    } else {
      removeGlobalHotkeys()
    }
  }

  func setStore(_ store: AppStore?) {
    self.store = store
  }

  func applicationWillTerminate(_ notification: Notification) {
    removeGlobalHotkeys()
    removeURLSchemeHandler()
    store?.shutdown()
  }

  private func setupURLSchemeHandler() {
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  private func removeURLSchemeHandler() {
    NSAppleEventManager.shared().removeEventHandler(
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
          let url = URL(string: urlString) else {
      logger.warning("URL scheme invocation rejected: Missing URL payload")
      return
    }

    handleURLScheme(url)
  }

  private func setupGlobalHotkeys() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      self?.handleGlobalKeyEvent(event)
    }
  }

  private func removeGlobalHotkeys() {
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
      eventMonitor = nil
    }
  }

  private func handleGlobalKeyEvent(_ event: NSEvent) {
    guard let store = store,
          store.preferences.enableKeyboardShortcuts else { return }

    // Check if user is typing in a text field
    if let focusedElement = NSApp.keyWindow?.firstResponder,
       focusedElement.isKind(of: NSTextView.self) || focusedElement.isKind(of: NSTextField.self) {
      return
    }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let isCmdOption = modifiers.contains(.command) && modifiers.contains(.option)

    guard isCmdOption else { return }

    switch event.keyCode {
    case 126: // Up arrow
      store.increaseVolumeForFrontmostApp()
    case 125: // Down arrow
      store.decreaseVolumeForFrontmostApp()
    case 46: // M key
      store.toggleMuteForFrontmostApp()
    default:
      break
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handleURLScheme(url)
    }
  }

  private func handleURLScheme(_ url: URL) {
    guard url.scheme == "waves" else { return }
    store?.handleURLScheme(url)
  }

  private func applyLogoBranding() {
    guard let logoImage = WavesBrandAssets.logoImage else { return }
    NSApp.applicationIconImage = logoImage
  }
}

enum AppSceneID {
  static let mainWindow = "main-window"
}
