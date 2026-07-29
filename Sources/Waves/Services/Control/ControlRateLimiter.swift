import Foundation

/// A per-connection token bucket.
///
/// Dials are legitimately chatty — a fast twist is a burst of rotate events — so
/// this has to allow a real burst while still bounding a runaway client. A
/// bucket does that naturally: the burst size is the ceiling on a spike, and the
/// refill rate is the sustained ceiling.
///
/// Deliberately not shared across connections. One misbehaving client should not
/// be able to throttle a well-behaved one.
struct ControlRateLimiter {
  /// Generous enough for a full dial sweep landing at once.
  static let burst = 60
  /// Sustained commands per second. Well above a dial's real rate (a fast twist
  /// is ~10-20 ticks/s) and far below anything that could load the audio actor.
  static let refillPerSecond = 30.0

  private var tokens: Double
  private var lastRefill: TimeInterval

  init(now: TimeInterval) {
    tokens = Double(Self.burst)
    lastRefill = now
  }

  /// Consumes a token if one is available. Returns false when the caller should
  /// be told `.rateLimited`.
  mutating func allow(now: TimeInterval) -> Bool {
    let elapsed = max(0, now - lastRefill)
    lastRefill = now
    tokens = min(Double(Self.burst), tokens + elapsed * Self.refillPerSecond)
    guard tokens >= 1 else { return false }
    tokens -= 1
    return true
  }
}
