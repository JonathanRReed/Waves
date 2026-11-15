import Foundation

/// One check for audio numbers that arrive from outside Waves: a control-socket
/// request, a `waves://` URL, or a file on disk.
///
/// Every boundary has the same two questions — is the number finite, and is it
/// inside the range the UI enforces — and two honest answers:
///
/// - `validated` is for commands. Anything non-finite or out of range is
///   refused, so the sender gets an error instead of a guess.
/// - `clamped` and `sanitized` are for data Waves has to keep going with
///   (persisted settings, a volume an existing protocol-1 client already sends
///   slightly out of range). Finite values are clamped into range; non-finite
///   values become `nil` (`clamped`) or the documented fallback (`sanitized`).
///
/// Values are checked as `Double` before narrowing, so a number too large for
/// `Float` cannot turn into infinity and slip past a later comparison.
public struct LevelRange: Hashable, Sendable {
  public let bounds: ClosedRange<Float>
  /// What `sanitized` returns for a value that is missing or not finite.
  public let fallback: Float

  public init(bounds: ClosedRange<Float>, fallback: Float) {
    precondition(bounds.lowerBound.isFinite && bounds.upperBound.isFinite)
    precondition(bounds.contains(fallback))
    self.bounds = bounds
    self.fallback = fallback
  }

  /// Linear app volume. 1 is the app's own level; Waves never goes above it.
  public static let volume = LevelRange(bounds: 0...1, fallback: 1)
  /// Per-app boost multiplier, as offered by the mixer's Boost menu.
  public static let boost = LevelRange(bounds: 1...4, fallback: 1)
  /// One equalizer band's gain in decibels.
  public static let equalizerGainDB = LevelRange(
    bounds: EqualizerSettings.minimumGainDB...EqualizerSettings.maximumGainDB,
    fallback: 0
  )

  /// Longest decimal text `validated(text:)` will parse. Real values are a few
  /// characters; anything longer is refused before parsing.
  public static let maximumTextLength = 32

  /// The value if it is finite and inside `bounds`; otherwise `nil`.
  public func validated(_ value: Double?) -> Float? {
    guard let value, value.isFinite,
      value >= Double(bounds.lowerBound), value <= Double(bounds.upperBound)
    else { return nil }
    return min(max(Float(value), bounds.lowerBound), bounds.upperBound)
  }

  public func validated(_ value: Float?) -> Float? {
    validated(value.map(Double.init))
  }

  /// Parses short decimal text (a URL query value) and validates it.
  public func validated(text: String?) -> Float? {
    guard let text, !text.isEmpty, text.utf8.count <= Self.maximumTextLength else { return nil }
    return validated(Double(text))
  }

  /// A finite value clamped into `bounds`; `nil` when missing or not finite.
  public func clamped(_ value: Double?) -> Float? {
    guard let value, value.isFinite else { return nil }
    let clamped = min(max(value, Double(bounds.lowerBound)), Double(bounds.upperBound))
    return Float(clamped)
  }

  public func clamped(_ value: Float?) -> Float? {
    clamped(value.map(Double.init))
  }

  /// For stored data: a finite value clamped into `bounds`, otherwise `fallback`.
  public func sanitized(_ value: Double?) -> Float {
    clamped(value) ?? fallback
  }

  public func sanitized(_ value: Float?) -> Float {
    sanitized(value.map(Double.init))
  }
}
