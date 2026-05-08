import AppKit
import SwiftUI
import WavesAudioCore
import OSLog

@main
@MainActor
struct WavesApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
  @State private var store = AppStore(
    backend: WorkspaceAudioControlBackend(),
    preferencesStore: PreferencesStore(),
    presetStore: PresetStore(),
    sessionStore: SessionStore(),
    loginItemService: LoginItemService(),
    deviceVolumePresetsStore: DeviceVolumePresetsStore()
  )

  var body: some Scene {
    WindowGroup("Waves", id: AppSceneID.mainWindow) {
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
      CommandGroup(replacing: .appSettings) {
        Button("Settings...") {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .keyboardShortcut(",", modifiers: .command)
      }
      CommandGroup(after: .appInfo) {
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
  private var store: AppStore?
  private var eventMonitor: Any?

  // Rate limiting for URL scheme (max 10 requests per minute)
  private let urlSchemeRateLimiter = RateLimiter(maxRequests: 10, timeWindow: 60.0)
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "URLScheme")

  func applicationDidFinishLaunching(_ notification: Notification) {
    applyLogoBranding()
    NSApp.setActivationPolicy(.regular)
    setupGlobalHotkeys()
  }

  func setStore(_ store: AppStore?) {
    self.store = store
  }

  func applicationWillTerminate(_ notification: Notification) {
    removeGlobalHotkeys()
  }

  private func setupGlobalHotkeys() {
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
    // Check if URL scheme is enabled
    guard store?.preferences.enableURLScheme == true else {
      logger.warning("URL scheme invocation rejected: URL scheme is disabled")
      return
    }

    // Apply rate limiting
    guard urlSchemeRateLimiter.check() else {
      logger.warning("URL scheme invocation rejected: Rate limit exceeded")
      return
    }

    guard url.scheme == "waves" else { return }

    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    guard let host = components?.host else { return }

    // Log the URL scheme invocation for audit purposes
    logger.info("URL scheme invoked: \(host, privacy: .public)")

    switch host {
    case "set-volume":
      handleSetVolume(components)
    case "mute":
      handleMute(components)
    case "apply-preset":
      handleApplyPreset(components)
    case "refresh":
      handleRefresh()
    default:
      logger.warning("URL scheme invoked with unknown host: \(host, privacy: .public)")
    }
  }

  private func handleSetVolume(_ components: URLComponents?) {
    guard let appID = components?.queryItems?.first(where: { $0.name == "app" })?.value,
          let volumeValue = components?.queryItems?.first(where: { $0.name == "volume" })?.value,
          let volume = Float(volumeValue) else { return }

    // Validate input length
    guard appID.count <= 256, volumeValue.count <= 32 else { return }

    // Validate volume range
    guard volume >= 0.0, volume <= 1.0 else { return }

    if let store = store {
      if let app = store.session.apps.first(where: { $0.logicalID == appID || $0.id == appID }) {
        store.setDesiredVolume(volume, for: app)
        store.commitDesiredVolume(for: app)
        logger.info("Set volume for app: \(appID, privacy: .public) to \(volume)")
      }
    }
  }

  private func handleMute(_ components: URLComponents?) {
    guard let appID = components?.queryItems?.first(where: { $0.name == "app" })?.value,
          let muteValue = components?.queryItems?.first(where: { $0.name == "muted" })?.value,
          let shouldMute = Bool(muteValue) else { return }

    // Validate input length
    guard appID.count <= 256, muteValue.count <= 16 else { return }

    if let store = store {
      if let app = store.session.apps.first(where: { $0.logicalID == appID || $0.id == appID }) {
        store.setMuted(shouldMute, for: app)
        logger.info("Set mute for app: \(appID, privacy: .public) to \(shouldMute)")
      }
    }
  }

  private func handleApplyPreset(_ components: URLComponents?) {
    guard let presetName = components?.queryItems?.first(where: { $0.name == "name" })?.value else { return }

    // Validate input length
    guard presetName.count <= 256 else { return }

    if let store = store {
      if let preset = store.presets.first(where: { $0.name == presetName }) {
        store.applyPreset(preset)
        logger.info("Applied preset: \(presetName, privacy: .public)")
      }
    }
  }

  private func handleRefresh() {
    store?.refresh()
    logger.info("Refreshed audio sessions")
  }

  private func applyLogoBranding() {
    guard let logoImage = WavesBrandAssets.logoImage else { return }
    NSApp.applicationIconImage = logoImage
  }
}

enum AppSceneID {
  static let mainWindow = "main-window"
}

// Simple rate limiter for URL scheme invocations
private class RateLimiter {
  private var requestTimes: [Date] = []
  private let maxRequests: Int
  private let timeWindow: TimeInterval
  private let queue = DispatchQueue(label: "com.waves.ratelimiter", attributes: .concurrent)

  init(maxRequests: Int, timeWindow: TimeInterval) {
    self.maxRequests = maxRequests
    self.timeWindow = timeWindow
  }

  func check() -> Bool {
    return queue.sync(flags: .barrier) {
      let now = Date()
      let cutoff = now.addingTimeInterval(-timeWindow)

      // Remove old requests outside the time window
      requestTimes.removeAll { $0 < cutoff }

      // Check if we've exceeded the limit
      if requestTimes.count >= maxRequests {
        return false
      }

      // Add this request
      requestTimes.append(now)
      return true
    }
  }
}
