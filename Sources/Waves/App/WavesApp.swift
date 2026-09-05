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
    self.init(
      composition: .live,
      performanceRecorder: LaunchPerformanceRecorder.activateLive()
    )
  }

  init(composition: WavesComposition) {
    self.init(composition: composition, performanceRecorder: nil)
  }

  private init(
    composition: WavesComposition,
    performanceRecorder: LaunchPerformanceRecorder?
  ) {
    let store = composition.makeStore()
    performanceRecorder?.mark(.storeReady)
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
          // Captured here rather than in the delegate because `openWindow` is a
          // SwiftUI scene action with no AppKit equivalent, and the whole point
          // of the Show Waves shortcut is that it works when this window is
          // *closed* — from a full-screen app, where the menu bar is hidden and
          // there is otherwise no way to reach Waves at all. This task runs at
          // launch, while the window exists; the captured action stays valid
          // afterwards and re-creates the scene on demand.
          store.onShowMixerRequested = {
            openWindow(id: AppSceneID.mainWindow)
            NSApp.activate(ignoringOtherApps: true)
          }
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
        .simultaneousGesture(
          TapGesture().onEnded {
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
        .frame(width: MenuBarLayout.panelWidth)
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
    operation: @escaping @MainActor @Sendable () async -> AppShutdownResult,
    started: @escaping @MainActor @Sendable (Task<Void, Never>) -> Void = { _ in }
  ) async -> AppTerminationOutcome {
    let firstOutcome = FirstTerminationOutcome()

    let shutdownTask = Task { @MainActor in
      let result = await operation()
      await firstOutcome.resolve(
        result.completion == .clean ? .clean(result) : .degraded(result)
      )
    }
    await started(shutdownTask)
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      await firstOutcome.resolve(.timedOut)
    }

    let outcome = await firstOutcome.value()
    timeoutTask.cancel()
    if case .timedOut = outcome {
      shutdownTask.cancel()
    }
    return outcome
  }
}

@MainActor
final class AppTerminationCoordinator {
  static let productionTimeout: Duration = .milliseconds(250)

  private enum State {
    case idle
    case running
    case completed(AppTerminationOutcome)
  }

  private let timeout: Duration
  private var state: State = .idle
  private var terminationTask: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?

  init(timeout: Duration = productionTimeout) {
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
          operation: shutdown,
          started: { self.shutdownTask = $0 }
        )
        guard case .running = state else { return }
        state = .completed(outcome)
        if case .timedOut = outcome {
          shutdownTask?.cancel()
        }
        report(outcome)
        reply(true)
        shutdownTask = nil
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
  /// Carbon hot keys: they consume the keystroke and need no Accessibility
  /// permission, unlike the NSEvent monitors this replaced.
  private let hotkeyCenter = HotkeyCenter()
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
    // Seed the shortcuts that used to be hard-coded, before anything registers.
    store?.migrateHotkeysIfNeeded()
    store?.onHotkeysChanged = { [weak self] in
      self?.updateGlobalHotkeysState()
    }
    store?.isChordAvailable = { [weak self] chord in
      // No delegate means no registration either, so nothing can be blocked.
      self?.isHotkeyChordAvailable(chord) ?? true
    }
    store?.onHotkeySuspensionChange = { [weak self] suspended in
      if suspended {
        self?.hotkeyCenter.pause()
      } else {
        self?.hotkeyCenter.resume()
      }
    }
    hotkeyCenter.onRejected = { [weak store] rejected in
      store?.reportRejectedHotkeys(rejected)
    }
    store?.onExternalControlPreferenceChange = { [weak self] in
      self?.reconcileControlServer()
    }
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
    store?.reconcileLoginItemStatus(force: true)
  }

  /// Registers Waves's hot keys only while the user has keyboard shortcuts
  /// enabled, and re-registers from scratch whenever the bindings change.
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
      // The broadcast closure is installed only while a client is connected.
      // With it installed for the life of the socket, every level tick built
      // and diffed the whole control roster just to drop it on an empty
      // connection list.
      let server = ControlServer(
        handler: ControlCommandHandler(store: store),
        onConnectionCountChange: { [weak self, weak store] count in
          guard let store else { return }
          if count > 0, store.controlBroadcast == nil {
            store.controlBroadcast = { [weak self] response in
              self?.controlServer?.broadcast(response)
            }
          } else if count == 0 {
            store.controlBroadcast = nil
          }
        }
      )
      do {
        try server.start()
        controlServer = server
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
    guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
      logger.warning("URL scheme invocation rejected: Missing URL payload")
      return
    }

    handleURLScheme(urlString)
  }

  private func setupGlobalHotkeys() {
    guard let store else { return }
    hotkeyCenter.onPress = { [weak store] action in
      store?.performHotkey(action)
    }
    let rejected = hotkeyCenter.apply(store.preferences.hotkeys.bindings)
    guard !rejected.isEmpty else { return }
    // Another app already owns those chords. Say which, once — a shortcut that
    // silently never fires is the worst possible outcome here.
    store.reportRejectedHotkeys(rejected)
  }

  private func removeGlobalHotkeys() {
    hotkeyCenter.unregisterAll()
  }

  /// True when the system would accept this chord, used by the recorder so a
  /// clash with another app is reported while the field is still open.
  func isHotkeyChordAvailable(_ chord: HotkeyChord) -> Bool {
    hotkeyCenter.isChordAvailable(chord)
  }

  // URL-scheme delivery is handled authoritatively by the manual kAEGetURL
  // Apple Event handler installed in `setupURLSchemeHandler()`, which replaces
  // AppKit's default GetURL dispatch. A separate `application(_:open:)` entry
  // point would be unreachable for `waves://` invocations, so it is omitted.

  private func handleURLScheme(_ rawURLString: String) {
    guard let store else { return }
    URLAutomationRouter(
      isEnabled: { store.preferences.enableURLScheme },
      admitInvocation: { store.admitURLAutomationInvocation() },
      isAudioRunning: { store.isAudioRunning },
      parse: WavesURLPolicy.parse,
      promptForSetup: { store.promptToFinishSetup() },
      presentSetup: { self.presentSetupWindowIfAvailable() },
      perform: { store.handleURLScheme($0, invocationAlreadyAdmitted: true) }
    ).handle(rawURLString: rawURLString)
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
