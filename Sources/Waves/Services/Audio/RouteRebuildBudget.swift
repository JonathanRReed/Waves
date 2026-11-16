import Foundation

/// Who asked for a controller to be built.
enum RouteWorkOrigin: Equatable, Sendable {
  /// A user edit, profile, automation command, or explicit Recover Routes.
  /// Always allowed, always counted.
  case userInitiated
  /// Work Waves started on its own: device-change rehoming, pinned-route
  /// reattachment, route maintenance, format/wake revalidation.
  case automatic
}

/// One backend-wide ceiling on the process taps and aggregate devices Waves
/// builds on its own.
///
/// Every creation is visible to every other audio client on the Mac: the tap
/// list and the device list change, twice per rebuild. Waves has shipped three
/// separate loops that rebuilt routes without end (1.3.1 every six seconds per
/// silent app, 1.4.4, and 1.7.0 four times a second on a geometry mismatch).
/// Each was bounded locally after the fact. This is the bound that does not
/// depend on finding the next loop first.
///
/// A token bucket: automatic work spends one token per creation attempt, a
/// token returns every `refillInterval`, and the bucket holds enough for a
/// burst that rebuilds every live route a few times (a device change, then a
/// Bluetooth mode switch). An empty bucket trips a cooldown that doubles on
/// each consecutive trip, so a loop decays to a trickle instead of settling
/// into a steady rate. User-initiated work never spends tokens and is never
/// refused.
struct RouteRebuildBudget: Sendable {
  static let minimumCapacity = 16
  static let tokensPerLiveRoute = 3

  private let refillInterval: Duration
  private let baseCooldown: Duration
  private let maximumCooldown: Duration

  private(set) var automaticCount = 0
  private(set) var userInitiatedCount = 0
  private(set) var refusedCount = 0
  /// Spent tokens. Tracking the deficit rather than the balance lets the
  /// capacity follow the live-route count without re-basing anything.
  private var spent: Double = 0
  private var lastRefill: Duration?
  private var cooldownUntil: Duration?
  private var consecutiveTrips = 0

  init(
    refillInterval: Duration = .seconds(10),
    baseCooldown: Duration = .seconds(30),
    maximumCooldown: Duration = .seconds(600)
  ) {
    self.refillInterval = refillInterval
    self.baseCooldown = baseCooldown
    self.maximumCooldown = maximumCooldown
  }

  static func capacity(liveRouteCount: Int) -> Int {
    max(minimumCapacity, tokensPerLiveRoute * max(0, liveRouteCount))
  }

  /// Records one creation attempt and says whether it may proceed.
  mutating func request(
    _ origin: RouteWorkOrigin,
    liveRouteCount: Int,
    at now: Duration
  ) -> Bool {
    refill(at: now)
    guard origin == .automatic else {
      userInitiatedCount += 1
      return true
    }
    if let cooldownUntil {
      guard now >= cooldownUntil else {
        refusedCount += 1
        return false
      }
      self.cooldownUntil = nil
    }
    let capacity = Double(Self.capacity(liveRouteCount: liveRouteCount))
    guard spent + 1 <= capacity else {
      consecutiveTrips += 1
      cooldownUntil = now + cooldown(forTrip: consecutiveTrips)
      refusedCount += 1
      return false
    }
    spent += 1
    automaticCount += 1
    return true
  }

  /// Whether automatic work would be refused right now.
  func isCeilingActive(liveRouteCount: Int, at now: Duration) -> Bool {
    if let cooldownUntil, now < cooldownUntil { return true }
    var probe = self
    probe.refill(at: now)
    return probe.spent + 1 > Double(Self.capacity(liveRouteCount: liveRouteCount))
  }

  /// An explicit user recovery clears the cooldown and refills the bucket,
  /// so the automatic repair that follows it is not refused. The counts stay.
  mutating func resetForUserRecovery() {
    spent = 0
    cooldownUntil = nil
    consecutiveTrips = 0
  }

  func diagnosticsSummary(liveRouteCount: Int, at now: Duration) -> String {
    let ceiling: String
    if let cooldownUntil, now < cooldownUntil {
      let remaining = (cooldownUntil - now).components.seconds
      ceiling = "active (automatic rebuilds paused for \(max(1, remaining)) more seconds)"
    } else if isCeilingActive(liveRouteCount: liveRouteCount, at: now) {
      ceiling = "active (waiting for the budget to refill)"
    } else {
      ceiling = "inactive"
    }
    return
      "Route builds this session: \(automaticCount) automatic, \(userInitiatedCount) user-initiated, \(refusedCount) automatic refused. Automatic-rebuild ceiling: \(ceiling)."
  }

  private mutating func refill(at now: Duration) {
    defer { lastRefill = now }
    guard let lastRefill, now > lastRefill, spent > 0 else { return }
    let elapsed = now - lastRefill
    spent = max(0, spent - elapsed / refillInterval)
    if spent == 0 { consecutiveTrips = 0 }
  }

  private func cooldown(forTrip trip: Int) -> Duration {
    var delay = baseCooldown
    for _ in 1..<max(1, trip) {
      delay *= 2
      if delay >= maximumCooldown { return maximumCooldown }
    }
    return min(delay, maximumCooldown)
  }
}
