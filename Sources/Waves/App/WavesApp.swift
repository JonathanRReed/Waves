import AppKit
import Carbon
import OSLog
import SwiftUI
import WavesAudioCore

enum WavesURLPolicy {
  static let maxPayloadBytes = 8 * 1_024

  static func parse(_ value: String) -> URL? {
    guard value.utf8.count <= maxPayloadBytes else { return nil }
    return URL(string: value)
  }
}

@main
@MainActor
struct WavesApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
  @Environment(\.openWindow) private var openWindow
  @State private var store: AppStore
  @State private var updaterService = UpdaterService()
  /// Drives every animated surface's clock, and the level poll's cadence.
  /// See `RenderActivityMonitor`. Assigned in `init` so it can be wired to the
  /// store before any scene exists.
  @State private var renderActivity: RenderActivityMonitor

  init() {
    self.init(composition: .live)
  }

  init(composition: WavesComposition) {
    let store = composition.makeStore()
    _store = State(initialValue: store)

    // Suspend the backend level poll whenever no Waves window is on screen.
    // Driven from occlusion, not `onDisappear`, which never fires for a window
    // that is merely occluded, behind another app, or on an inactive Space.
    let monitor = RenderActivityMonitor()
    monitor.onVisibilityChange = { [weak store] isVisible in
      store?.setUISurfaceVisible(isVisible)
    }
    store.setUISurfaceVisible(monitor.isVisible)
    _renderActivity = State(initialValue: monitor)

    AppDelegate.bootstrapStore = store
  }

  var body: some Scene {
    // A single, unique main window for this menu-bar utility. `Window` (rather
    // than `WindowGroup`) prevents duplicate mixer windows from being opened.
    Window("Waves", id: AppSceneID.mainWindow) {
      MainWindowView()
        .environment(store)
        .environment(updaterService)
        .frame(minWidth: 980, minHeight: 620)
        .wavesTheme(
          palette: store.preferences.palette,
          appearance: store.preferences.appearance
        )
        .renderCadence(renderActivity)
        .task {
          appDelegate.setStore(store)
          store.start()
        }
    }
    .defaultSize(width: 1100, height: 680)
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .commands {
      // Replace the stock About panel with our own window: same version info,
      // plus the update check right where Mac users look for it first.
      CommandGroup(replacing: .appInfo) {
        Button("About Waves") {
          openWindow(id: AppSceneID.aboutWindow)
          NSApp.activate(ignoringOtherApps: true)
        }
      }

      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          updaterService.checkForUpdates()
        }
        .disabled(!updaterService.canCheckForUpdates)
      }

      // The Settings scene below already provides the standard "Settings…"
      // item (⌘,) in the app menu, so no custom command is needed here.
      CommandGroup(after: .toolbar) {
        Button("Refresh") {
          store.refresh()
        }
        .disabled(!store.isAudioRunning || store.isRefreshing)
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
        // Otherwise this opens Settings on whichever pane it last showed —
        // usually General — leaving the user to go find Help themselves, which
        // is exactly what this menu item promised to do for them.
        .simultaneousGesture(TapGesture().onEnded {
          store.requestSettingsPane(.help)
        })
      }
    }

    Window("About Waves", id: AppSceneID.aboutWindow) {
      AboutView()
        .environment(updaterService)
        .wavesTheme(
          palette: store.preferences.palette,
          appearance: store.preferences.appearance
        )
    }
    .windowResizability(.contentSize)
    .defaultPosition(.center)

    Settings {
      SettingsView()
        .environment(store)
        .environment(updaterService)
        // 500pt was tall enough to satisfy the constraint but not the
        // content — Help and the longer Audio/Advanced panes opened needing
        // 4-5 scroll gestures just to read top to bottom, which reads as
        // cramped rather than "a real Settings window." 640 shows
        // meaningfully more per screen (closer to System Settings' own
        // proportions) while still fitting comfortably on a 13" display.
        .frame(minWidth: 720, minHeight: 640)
        .wavesTheme(
          palette: store.preferences.palette,
          appearance: store.preferences.appearance
        )
        .renderCadence(renderActivity)
    }

    MenuBarExtra(isInserted: $showMenuBarExtra) {
      MenuBarMixerView()
        .environment(store)
        .environment(updaterService)
        .frame(width: WavesDesign.menuBarPanelWidth)
        .wavesTheme(
          palette: store.preferences.palette,
          appearance: store.preferences.appearance
        )
        .renderCadence(renderActivity)
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
  /// drive the glyph so the icon-only status is perceivable without sight.
  /// Shares `store.menuBarStatus` with the icon and the panel header, so the
  /// spoken label can never contradict what is on screen.
  private var menuBarAccessibilityLabel: String {
    switch store.menuBarStatus {
    case .setup: "Waves, finish setup"
    case .playing: "Waves, playing"
    case .muted: "Waves, muted"
    case .idle: "Waves, idle"
    }
  }
}

enum AppTerminationOutcome: Hashable, Sendable {
  case clean(AppShutdownResult)
  case degraded(AppShutdownResult)
  case timedOut
}

enum AppTerminationRequestDecision: Hashable, Sendable {
  case terminateNow
  case terminateLater
}

private actor FirstTerminationOutcome {
  private var outcome: AppTerminationOutcome?
  private var waiters: [CheckedContinuation<AppTerminationOutcome, Never>] = []

  func resolve(_ outcome: AppTerminationOutcome) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: outcome)
    }
  }

  func value() async -> AppTerminationOutcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

enum AppTerminationTimeoutDecision {
  static func awaitShutdown(
    timeout: Duration,
    operation: @escaping @MainActor @Sendable () async -> AppShutdownResult
  ) async -> AppTerminationOutcome {
    let firstOutcome = FirstTerminationOutcome()

    Task { @MainActor in
      let result = await operation()
      await firstOutcome.resolve(
        result.completion == .clean ? .clean(result) : .degraded(result)
      )
    }
    Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await firstOutcome.resolve(.timedOut)
    }

    return await firstOutcome.value()
  }
}

@MainActor
final class AppTerminationCoordinator {
  private enum State {
    case idle
    case running
    case completed(AppTerminationOutcome)
  }

  private let timeout: Duration
  private var state: State = .idle
  private var terminationTask: Task<Void, Never>?

  init(timeout: Duration = .seconds(5)) {
    self.timeout = timeout
  }

  var completedOutcome: AppTerminationOutcome? {
    guard case .completed(let outcome) = state else { return nil }
    return outcome
  }

  func requestTermination(
    shutdown: @escaping @MainActor @Sendable () async -> AppShutdownResult,
    report: @escaping @MainActor @Sendable (AppTerminationOutcome) -> Void,
    reply: @escaping @MainActor @Sendable (Bool) -> Void
  ) -> AppTerminationRequestDecision {
    switch state {
    case .running:
      return .terminateLater
    case .completed:
      return .terminateNow
    case .idle:
      state = .running
      terminationTask = Task { @MainActor [self] in
        let outcome = await AppTerminationTimeoutDecision.awaitShutdown(
          timeout: timeout,
          operation: shutdown
        )
        guard case .running = state else { return }
        state = .completed(outcome)
        report(outcome)
        reply(true)
        terminationTask = nil
      }
      return .terminateLater
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var bootstrapStore: AppStore?

  private var store: AppStore?
  private var eventMonitor: Any?
  private var localEventMonitor: Any?
  private let terminationCoordinator = AppTerminationCoordinator()
  /// Records what actually failed during cleanup, before the process goes away.
  private let shutdownReportStore = ShutdownReportStore()
  /// Accepts commands from the Stream Deck plugin, `wavesctl`, and anything else
  /// local. Nil until the user turns external control on.
  private var controlServer: ControlServer?
  private var controlObservation: NSObjectProtocol?

  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "URLScheme")
  private let lifecycleLogger = Logger(subsystem: "com.jonathanreed.Waves", category: "Lifecycle")

  func applicationDidFinishLaunching(_ notification: Notification) {
    store = Self.bootstrapStore
    // Read before anything can overwrite it, so this launch's Diagnostics can
    // report exactly how the previous one ended — then consume it.
    //
    // Clearing is what makes the report trustworthy. It is written only on a
    // graceful quit, so leaving it behind means a force-quit, a panic, or a
    // macOS resource-limit kill would show the *previous* graceful quit's
    // "clean" result as if it described the crash. That is the exact incident
    // class this release exists for, and a stale "clean" is worse than nothing.
    // An abnormal exit now leaves no file, and the next launch honestly reports
    // that nothing was recorded.
    store?.previousShutdownReport = shutdownReportStore.load()
    shutdownReportStore.clear()
    store?.start()
    reconcileControlServer()
    NSApp.setActivationPolicy(.regular)
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

  /// Starts or stops the control socket to match the preference.
  ///
  /// Called at launch and whenever the toggle changes, so turning external
  /// control on takes effect immediately — a plugin that was showing "turn this
  /// on in Waves" connects on its next retry rather than needing a relaunch.
  func reconcileControlServer() {
    guard let store else { return }
    let shouldRun = store.preferences.enableExternalControl

    if shouldRun, controlServer == nil {
      let server = ControlServer(handler: ControlCommandHandler(store: store))
      do {
        try server.start()
        controlServer = server
        store.controlBroadcast = { [weak server] response in
          server?.broadcast(response)
        }
      } catch {
        lifecycleLogger.error(
          "Could not open the control socket: \(String(describing: error), privacy: .public)")
        store.reportExternalControlUnavailable()
      }
    } else if !shouldRun, let server = controlServer {
      server.stop()
      controlServer = nil
      store.controlBroadcast = nil
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    removeGlobalHotkeys()
    removeURLSchemeHandler()
    // Unlink the socket before anything else can block: a leftover file would
    // make the next launch look like it is recovering from a crash.
    controlServer?.stop()
    controlServer = nil

    guard let store else { return .terminateNow }
    if store.shutdownResult != nil { return .terminateNow }

    let decision = terminationCoordinator.requestTermination(
      shutdown: { await store.shutdown() },
      report: { [lifecycleLogger, shutdownReportStore] outcome in
        // Persist first, log second. This runs before the reply that lets the
        // process exit, and the write is synchronous, so the detail survives even
        // when the log entries that describe it later age out of the log store —
        // which is exactly how the 1.3.0 degraded cleanup became unexplainable.
        shutdownReportStore.save(ShutdownReport(outcome: outcome))

        switch outcome {
        case .clean:
          lifecycleLogger.info("Termination cleanup completed cleanly")
        case .degraded(let result):
          lifecycleLogger.error(
            "Termination cleanup degraded: \(result.persistenceDegradations.count, privacy: .public) persistence issue(s), backend \(String(describing: result.backendResult?.completion), privacy: .public)"
          )
          for row in result.backendResult?.degradations ?? [] {
            lifecycleLogger.error(
              "Cleanup stage \(row.stage.name, privacy: .public) failed with native status \(row.nativeStatus.map(String.init) ?? "none", privacy: .public)"
            )
          }
        case .timedOut:
          lifecycleLogger.error(
            "Termination cleanup timed out after the bounded wait; termination will proceed")
        }
      },
      reply: { shouldTerminate in
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
      }
    )

    switch decision {
    case .terminateNow:
      return .terminateNow
    case .terminateLater:
      return .terminateLater
    }
  }

  /// Synchronous, idempotent last-chance removal only. Async cleanup starts from
  /// applicationShouldTerminate so AppKit can hold and later release termination.
  func applicationWillTerminate(_ notification: Notification) {
    removeGlobalHotkeys()
    removeURLSchemeHandler()
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

  @objc private func handleGetURLEvent(
    _ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor
  ) {
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = WavesURLPolicy.parse(urlString)
    else {
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
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
      [weak self] event in
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
      store.preferences.enableKeyboardShortcuts
    else { return false }

    // Check if user is typing in a text field
    if let focusedElement = NSApp.keyWindow?.firstResponder,
      focusedElement.isKind(of: NSTextView.self) || focusedElement.isKind(of: NSTextField.self)
    {
      return false
    }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // `contains` (not equality) because the arrow keys carry .function/
    // .numericPad flags; .control/.shift are excluded so third-party chords
    // like ⌃⌥⌘↓ don't also trigger Waves.
    let isCmdOption =
      modifiers.contains(.command) && modifiers.contains(.option)
      && !modifiers.contains(.control) && !modifiers.contains(.shift)

    guard isCmdOption, [126, 125, 46].contains(event.keyCode) else { return false }
    guard store.isAudioRunning else {
      store.promptToFinishSetup()
      presentSetupWindowIfAvailable()
      return true
    }

    switch event.keyCode {
    case 126:  // Up arrow
      store.increaseVolumeForFrontmostApp()
    case 125:  // Down arrow
      store.decreaseVolumeForFrontmostApp()
    case 46:  // M key
      store.toggleMuteForFrontmostApp()
    default:
      break
    }
    return true
  }

  // URL-scheme delivery is handled authoritatively by the manual kAEGetURL
  // Apple Event handler installed in `setupURLSchemeHandler()`, which replaces
  // AppKit's default GetURL dispatch. A separate `application(_:open:)` entry
  // point would be unreachable for `waves://` invocations, so it is omitted.

  private func handleURLScheme(_ url: URL) {
    guard url.scheme == "waves", let store else { return }
    guard store.isAudioRunning else {
      store.promptToFinishSetup()
      presentSetupWindowIfAvailable()
      return
    }
    store.handleURLScheme(url)
  }

  private func presentSetupWindowIfAvailable() {
    NSApp.activate(ignoringOtherApps: true)
    let window = NSApp.windows.first { $0.title == "Waves" }
    window?.makeKeyAndOrderFront(nil)
  }

}

enum AppSceneID {
  static let mainWindow = "main-window"
  static let aboutWindow = "about-window"
}
