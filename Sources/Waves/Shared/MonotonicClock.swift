import Darwin
import Foundation

/// Seconds on `CLOCK_MONOTONIC`: it never moves when the user, NTP, or a
/// time-zone change sets the wall clock, and it keeps counting through sleep.
///
/// Rate limiters must read this rather than `Date()`. With the wall clock,
/// setting the system time back reopened a spent quota and setting it forward
/// refilled a token bucket in one step.
enum MonotonicClock {
  static func seconds() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
  }
}
