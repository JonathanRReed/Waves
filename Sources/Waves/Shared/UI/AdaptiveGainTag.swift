import SwiftUI

/// What a row says about the gain Adaptive Mix is applying to its app.
///
/// The engine publishes up to ten values a second, and its smoothing makes a
/// value hover around any threshold or rounding boundary for a while. Both
/// edges have hysteresis so the tag neither blinks in and out nor flips between
/// two numbers.
enum AdaptiveGainReadout {
  /// The tag appears once the gain is at least this far from zero.
  static let appearThreshold: Float = 0.5
  /// Once shown, it stays until the gain is closer to zero than this.
  static let releaseThreshold: Float = 0.35
  /// The shown number changes only when the gain is further than this from it.
  static let changeThreshold: Float = 0.75

  /// The whole-dB value to show, or nil for no tag, given the current gain and
  /// the value shown last time.
  static func displayedDecibels(gain: Float?, previous: Int?) -> Int? {
    guard let gain, gain.isFinite else { return nil }
    let magnitude = abs(gain)
    guard magnitude >= (previous == nil ? appearThreshold : releaseThreshold) else { return nil }
    if let previous, abs(gain - Float(previous)) <= changeThreshold {
      return previous
    }
    let rounded = Int(gain.rounded())
    // Never show "0 dB": a gain big enough to keep the tag reads as one.
    return rounded == 0 ? (gain < 0 ? -1 : 1) : rounded
  }

  static func text(decibels: Int) -> String {
    "\(decibels < 0 ? "\u{2212}" : "+")\(abs(decibels)) dB"
  }

  static func accessibilityLabel(decibels: Int, appName: String) -> String {
    let direction = decibels < 0 ? "down" : "up"
    return "Adaptive Mix is turning \(appName) \(direction) by \(abs(decibels)) dB right now."
  }
}

/// A quiet tag naming the gain Adaptive Mix is applying to one app.
///
/// This is a leaf on purpose: `adaptiveGainsDBByAppID` changes at the engine's
/// 10 Hz cadence, so only this view may read it. The row that hosts it never
/// re-renders for a gain change.
struct AdaptiveGainTag: View {
  @Environment(AppStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  let appID: String
  let appName: String
  @State private var decibels: Int?

  var body: some View {
    let gain = store.adaptiveGainsDBByAppID[appID]
    // With nothing shown yet there is no hysteresis to apply, so the first
    // frame can show the tag without waiting for the state update below.
    let shown = decibels ?? AdaptiveGainReadout.displayedDecibels(gain: gain, previous: nil)
    Group {
      if let decibels = shown {
        tag(decibels: decibels)
          .transition(.opacity)
      }
    }
    .onChange(of: gain, initial: true) { oldGain, newGain in
      let next = AdaptiveGainReadout.displayedDecibels(gain: newGain, previous: decibels)
      guard next != decibels else { return }
      // A row that opens mid-adjustment shows the tag at once; only later
      // changes fade.
      if oldGain != newGain, !reduceMotion {
        withAnimation(.easeOut(duration: 0.2)) { decibels = next }
      } else {
        decibels = next
      }
    }
  }

  private func tag(decibels: Int) -> some View {
    // The widest value the tag is likely to show reserves its width, so a
    // change from -4 to -12 dB never nudges anything beside it.
    ZStack {
      Text(AdaptiveGainReadout.text(decibels: -88)).hidden()
      Text(AdaptiveGainReadout.text(decibels: decibels))
        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(decibels)))
    }
    .font(.caption2.monospacedDigit().weight(.medium))
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Color.secondary.opacity(contrast == .increased ? 0.24 : 0.12), in: Capsule())
    .overlay {
      if contrast == .increased {
        Capsule().strokeBorder(Color.secondary, lineWidth: 1)
      }
    }
    .fixedSize()
    .help(AdaptiveGainReadout.accessibilityLabel(decibels: decibels, appName: appName))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AdaptiveGainReadout.accessibilityLabel(decibels: decibels, appName: appName))
  }
}
