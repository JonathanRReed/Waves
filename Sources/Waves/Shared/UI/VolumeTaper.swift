import Foundation

/// Maps a volume slider's thumb position to the stored linear volume and back.
///
/// Stored volume is linear amplitude, so a linear slider put half-way at only
/// 6 dB down and crowded most of the audible range into its bottom fifth. The
/// thumb now sits at the square root of the stored volume: half-way is about
/// 12 dB down, which tracks perceived loudness much more closely.
///
/// This is presentation only. The stored value, the percentage label,
/// VoiceOver's value, profiles, automation, and the Stream Deck all keep using
/// the linear volume.
enum VolumeTaper {
  /// Thumb distance moved by one keyboard or VoiceOver step.
  ///
  /// Steps are taken in thumb space so every press moves the thumb the same
  /// distance and changes loudness by a similar, audible amount: about 0.9 dB
  /// near the top and a few dB near the bottom. A 5% step in value space was
  /// under 0.5 dB at the top, too small to hear, and 26 dB on the first step up
  /// from silence.
  static let step = 0.05

  /// The thumb position, 0...1, for a stored linear volume.
  static func position(forVolume volume: Float) -> Double {
    guard !volume.isNaN else { return 0 }
    return min(max(Double(volume), 0), 1).squareRoot()
  }

  /// The stored linear volume for a thumb position, or nil for NaN.
  static func volume(forPosition position: Double) -> Float? {
    guard !position.isNaN else { return nil }
    let clamped = min(max(position, 0), 1)
    return Float(clamped * clamped)
  }

  /// The volume one step up or down from `volume`, rounded to a whole percent
  /// so the label and VoiceOver read exactly what is stored. Always moves by at
  /// least one percent unless already at the end of the range.
  static func steppedVolume(from volume: Float, increasing: Bool) -> Float {
    let current = position(forVolume: volume)
    let currentPercent = (current * current * 100).rounded()
    let target = current + (increasing ? step : -step)
    var nextPercent = (Double(Self.volume(forPosition: target) ?? 0) * 100).rounded()
    if increasing, nextPercent <= currentPercent {
      nextPercent = currentPercent + 1
    } else if !increasing, nextPercent >= currentPercent {
      nextPercent = currentPercent - 1
    }
    return Float(min(max(nextPercent, 0), 100) / 100)
  }
}
