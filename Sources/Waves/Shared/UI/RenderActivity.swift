import AppKit
import Observation
import SwiftUI

/// How hard animated surfaces should be working right now.
///
/// Ordered from cheapest to most expensive so call sites can compare.
enum RenderCadence: Comparable, Sendable {
  /// Nothing of Waves is on screen. Animated surfaces must mount no clock at
  /// all — not a slow one. A paused surface still draws its current pose once
  /// so it is correct the instant it becomes visible again.
  case paused
  /// Visible, but Waves is not the active app. The user can see the window, so
  /// motion still has to be there — it just does not need to be perfect. Half
  /// rate is not perceptible on a glanceable meter from across the desk and
  /// halves the frame cost of a window somebody is only monitoring.
  case background
  /// Visible and frontmost: full display rate.
  case foreground

  /// Minimum interval for a `TimelineView(.animation(minimumInterval:))`.
  /// `nil` means "follow the display", which is what `.animation` does with no
  /// interval — the right answer when the user is actually looking at it.
  var minimumInterval: Double? {
    switch self {
    case .paused: nil // never mounted; see `isAnimating`
    case .background: 1.0 / 30.0
    case .foreground: nil
    }
  }

  /// Whether a repeating clock should be mounted at all.
  var isAnimating: Bool { self != .paused }
}

/// Tracks whether any Waves surface is actually on screen, so animated views can
/// stop doing work nobody can see.
///
/// Why this exists: Waves is a menu-bar utility people leave running for days.
/// Through 1.3.0 every animated surface was gated purely on *audio being
/// present* — a live route kept the waveform and every row meter rendering at
/// display rate indefinitely, whether or not a single pixel of Waves was
/// visible. One live source across a three-day session pinned roughly two CPU
/// cores and tripped the macOS CPU resource limit. Silence was handled; being
/// unwatched was not.
///
/// AppKit already answers "can the user see any of this". `NSApplication`'s
/// `occlusionState` carries `.visible` while at least one window is on screen
/// and not fully covered, and clears it when every window is closed, minimized,
/// on an inactive Space, or completely behind another window. The menu-bar
/// popover is itself a window, so an open menu keeps its contents live for free.
///
/// Visibility and activation are deliberately separate signals: an occluded
/// window must render nothing, but a *visible* background window still has to
/// animate — just more cheaply. Collapsing the two would either waste work or
/// freeze a window the user is watching.
@MainActor
@Observable
final class RenderActivityMonitor {
  /// True while at least one Waves window is on screen and not fully occluded.
  private(set) var isVisible: Bool {
    didSet {
      guard isVisible != oldValue else { return }
      onVisibilityChange?(isVisible)
    }
  }
  /// True while Waves is the active application.
  private(set) var isActive: Bool

  /// Notified on every visibility transition. Wired to the store's level-poll
  /// gate at app construction. This lives on the monitor rather than in a view's
  /// `onChange` because no single view is reliably alive across the transitions
  /// that matter: with the main window closed, opening the menu-bar panel makes
  /// the app visible again with `MainWindowView` long gone.
  @ObservationIgnored var onVisibilityChange: ((Bool) -> Void)?

  var cadence: RenderCadence {
    guard isVisible else { return .paused }
    return isActive ? .foreground : .background
  }

  /// Owns the notification tokens and unregisters them when the monitor dies.
  /// A separate, non-isolated box because `deinit` on a `@MainActor` type cannot
  /// touch isolated stored properties under strict concurrency — and hopping to
  /// the main actor from `deinit` would resurrect `self`.
  private final class ObserverTokens: @unchecked Sendable {
    let center: NotificationCenter
    var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }

    deinit {
      for token in tokens { center.removeObserver(token) }
    }
  }

  @ObservationIgnored private let observers: ObserverTokens
  @ObservationIgnored private let center: NotificationCenter

  /// - Parameters:
  ///   - application: injectable so tests can drive state without a real app.
  ///   - center: injectable for the same reason.
  init(
    application: NSApplication? = nil,
    center: NotificationCenter = .default
  ) {
    self.center = center
    self.observers = ObserverTokens(center: center)
    // Seeded from the real application state, which under a test host reports
    // not-visible. That is correct for the monitor; views rendered outside a
    // Waves scene stay animated via `RenderCadenceEnvironmentKey.defaultValue`,
    // not via this. Tests that need a known starting point call
    // `setStateForTesting` first.
    let app = application ?? NSApplication.shared
    isVisible = app.occlusionState.contains(.visible)
    isActive = app.isActive

    observe(NSApplication.didChangeOcclusionStateNotification) { [weak self] app in
      self?.isVisible = app.occlusionState.contains(.visible)
    }
    observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in
      self?.isActive = true
    }
    observe(NSApplication.didResignActiveNotification) { [weak self] _ in
      self?.isActive = false
    }
    // Occlusion does not change when the app is hidden via ⌘H on every macOS
    // release, so track hide/unhide explicitly rather than trusting one signal.
    observe(NSApplication.didHideNotification) { [weak self] _ in
      self?.isVisible = false
    }
    observe(NSApplication.didUnhideNotification) { [weak self] app in
      self?.isVisible = app.occlusionState.contains(.visible)
    }
  }

  private func observe(
    _ name: Notification.Name,
    handler: @escaping @MainActor (NSApplication) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        handler(NSApplication.shared)
      }
    }
    observers.tokens.append(token)
  }

  /// Test-only: drive the signals directly without an AppKit event loop.
  func setStateForTesting(isVisible: Bool, isActive: Bool) {
    self.isVisible = isVisible
    self.isActive = isActive
  }
}

private struct RenderCadenceEnvironmentKey: EnvironmentKey {
  /// Views rendered outside a Waves scene (previews, snapshot tests) should
  /// animate normally rather than silently freezing.
  static let defaultValue = RenderCadence.foreground
}

extension EnvironmentValues {
  /// How expensive animated surfaces are allowed to be right now. Read this in
  /// any view that mounts a repeating clock.
  var renderCadence: RenderCadence {
    get { self[RenderCadenceEnvironmentKey.self] }
    set { self[RenderCadenceEnvironmentKey.self] = newValue }
  }
}

extension View {
  /// Publishes the monitor's current cadence to a scene's subtree.
  func renderCadence(_ monitor: RenderActivityMonitor) -> some View {
    environment(\.renderCadence, monitor.cadence)
  }
}
