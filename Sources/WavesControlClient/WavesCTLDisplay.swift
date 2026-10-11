public enum WavesCTLDisplay {
  /// Formats a daemon-supplied volume as a bounded percentage for terminal output.
  public static func percentage(_ value: WavesControlJSONValue?) -> Int {
    guard let number = value?.numberValue, number.isFinite else { return 0 }
    let clamped = max(0.0, min(1.0, number))
    return Int((clamped * 100).rounded())
  }
}
