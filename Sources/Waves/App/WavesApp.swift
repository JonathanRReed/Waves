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
      profileStore: ProfileStore(),
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
        // Applied at the scene root (above NavigationSplitView's sidebar list and
        // any toolbar/segmented chrome) so Waves' cyan signal accent wins over the
        // user's *system* accent-color preference everywhere AppKit auto-tints
        // "selectable" chrome (sidebar icons, toolbar item highlights). Without
        // this, a non-blue system accent (e.g. Red) bleeds into sidebar icons that
        // are explicitly styled `.secondary` in SwiftUI — the system accent wins
        // at the AppKit bridging layer for that one specific effect.
        .tint(WavesDesign.accent)
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

      // Replace the empty auto-generated Help menu (search field only) with a
      // discoverable "Waves Help" entry. The full guide lives in the Help tab of
      // Settings (SettingsView.swift), so this opens the standard Settings window
      // — a far more visible entry point than burying Help six tabs deep.
      CommandGroup(replacing: .help) {
        SettingsLink {
          Text("Waves Help")
        }
      }
    }

    Settings {
      SettingsView()
        .environment(store)
        // 500pt was tall enough to satisfy the constraint but not the
        // content — Help and the longer Audio/Advanced panes opened needing
        // 4-5 scroll gestures just to read top to bottom, which reads as
        // cramped rather than "a real Settings window." 640 shows
        // meaningfully more per screen (closer to System Settings' own
        // proportions) while still fitting comfortably on a 13" display.
        .frame(minWidth: 720, minHeight: 640)
    }

    MenuBarExtra(isInserted: $showMenuBarExtra) {
      MenuBarMixerView()
        .environment(store)
        .frame(width: WavesDesign.menuBarPanelWidth)
        .tint(WavesDesign.accent)
    } label: {
      // The accessibility label must live on the status-item label itself —
      // VoiceOver reads this view for the menu-bar item, not the popover
      // content above.
      Image(systemName: store.menuBarIconName)
        .accessibilityLabel(Text(menuBarAccessibilityLabel))
    }
    .menuBarExtraStyle(.window)
  }

  /// VoiceOver label for the menu-bar item, mirroring the three states that
  /// drive `store.menuBarIconName` (muted / playing / idle) so the icon-only
  /// status is perceivable without sight.
  private var menuBarAccessibilityLabel: String {
    if store.visibleApps.contains(where: \.isMuted) {
      return "Waves — muted"
    }
    // Mirror menuBarIconName: "playing" tracks the real signal, not the lingering
    // Live list, so the icon and its label never disagree.
    if store.hasLiveAudio {
      return "Waves — playing"
    }
    return "Waves — idle"
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var bootstrapStore: AppStore?

  private var store: AppStore?
  private var eventMonitor: Any?
  private var localEventMonitor: Any?

  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "URLScheme")

  func applicationDidFinishLaunching(_ notification: Notification) {
    store = Self.bootstrapStore
    store?.start()
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

  // Login-item status can go stale: if the user enables/disables "Open at
  // Login" from System Settings (not from inside Waves) while Waves is
  // running, the in-app toggle doesn't notice on its own. Re-sync from the
  // system every time Waves becomes active — cheap (a single SMAppService
  // status read) and covers the common case of the user returning from
  // System Settings after changing it there.
  func applicationDidBecomeActive(_ notification: Notification) {
    store?.reconcileLoginItemStatus()
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
      _ = self?.handleGlobalKeyEvent(event)
    }
    // Global monitors never see events while Waves itself is frontmost, so a
    // local monitor covers the hotkeys with the mixer/Settings focused.
    // Returning nil consumes a handled event, keeping ⌘⌥M from also firing
    // the Window menu's "Minimize All".
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      if self?.handleGlobalKeyEvent(event) == true {
        return nil
      }
      return event
    }
  }

  private func removeGlobalHotkeys() {
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
      eventMonitor = nil
    }
    if let monitor = localEventMonitor {
      NSEvent.removeMonitor(monitor)
      localEventMonitor = nil
    }
  }

  /// Returns `true` when the event matched a Waves hotkey and was acted on.
  private func handleGlobalKeyEvent(_ event: NSEvent) -> Bool {
    guard let store = store,
          store.preferences.enableKeyboardShortcuts else { return false }

    // Check if user is typing in a text field
    if let focusedElement = NSApp.keyWindow?.firstResponder,
       focusedElement.isKind(of: NSTextView.self) || focusedElement.isKind(of: NSTextField.self) {
      return false
    }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // `contains` (not equality) because the arrow keys carry .function/
    // .numericPad flags; .control/.shift are excluded so third-party chords
    // like ⌃⌥⌘↓ don't also trigger Waves.
    let isCmdOption = modifiers.contains(.command) && modifiers.contains(.option)
      && !modifiers.contains(.control) && !modifiers.contains(.shift)

    guard isCmdOption else { return false }

    switch event.keyCode {
    case 126: // Up arrow
      store.increaseVolumeForFrontmostApp()
      return true
    case 125: // Down arrow
      store.decreaseVolumeForFrontmostApp()
      return true
    case 46: // M key
      store.toggleMuteForFrontmostApp()
      return true
    default:
      return false
    }
  }

  // URL-scheme delivery is handled authoritatively by the manual kAEGetURL
  // Apple Event handler installed in `setupURLSchemeHandler()`, which replaces
  // AppKit's default GetURL dispatch. A separate `application(_:open:)` entry
  // point would be unreachable for `waves://` invocations, so it is omitted.

  private func handleURLScheme(_ url: URL) {
    guard url.scheme == "waves" else { return }
    store?.handleURLScheme(url)
  }

}

enum AppSceneID {
  static let mainWindow = "main-window"
}
