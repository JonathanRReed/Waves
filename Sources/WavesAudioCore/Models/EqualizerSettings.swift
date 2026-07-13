import Foundation

public enum EqualizerMode: String, Codable, CaseIterable, Hashable, Sendable {
  case simple
  case advanced

  public var displayName: String {
    switch self {
    case .simple: "Simple"
    case .advanced: "Advanced"
    }
  }
}

public enum EqualizerPreset: String, Codable, CaseIterable, Hashable, Sendable {
  case flat
  case voiceFocus
  case warm
  case bassReduce
  case trebleSoften
  case custom

  public var displayName: String {
    switch self {
    case .flat: "Flat"
    case .voiceFocus: "Voice Focus"
    case .warm: "Warm"
    case .bassReduce: "Bass Reduce"
    case .trebleSoften: "Treble Soften"
    case .custom: "Custom"
    }
  }

  public static var selectablePresets: [EqualizerPreset] {
    allCases.filter { $0 != .custom }
  }
}

public enum AdaptiveAppRole: String, Codable, CaseIterable, Hashable, Sendable {
  case auto
  case voice
  case media
  case ignore

  public var displayName: String {
    switch self {
    case .auto: "Auto"
    case .voice: "Voice"
    case .media: "Media"
    case .ignore: "Ignore"
    }
  }
}

public enum AdaptiveMixMode: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case speechFocus
  case loudnessBalance
  case both

  public var displayName: String {
    switch self {
    case .off: "Off"
    case .speechFocus: "Speech Focus"
    case .loudnessBalance: "Loudness Balance"
    case .both: "Both"
    }
  }

  public var usesSpeechFocus: Bool {
    self == .speechFocus || self == .both
  }

  public var usesLoudnessBalance: Bool {
    self == .loudnessBalance || self == .both
  }
}

public enum EqualizerFilterKind: String, Codable, Hashable, Sendable {
  case lowShelf
  case peaking
  case highShelf
}

public struct EqualizerBandDefinition: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let label: String
  public let frequency: Double
  public let q: Double
  public let filterKind: EqualizerFilterKind

  public init(
    id: String,
    label: String,
    frequency: Double,
    q: Double,
    filterKind: EqualizerFilterKind
  ) {
    self.id = id
    self.label = label
    self.frequency = frequency
    self.q = q
    self.filterKind = filterKind
  }
}

public enum EqualizerBandCatalog {
  public static let simple: [EqualizerBandDefinition] = [
    EqualizerBandDefinition(id: "low", label: "Low", frequency: 120, q: 0.707, filterKind: .lowShelf),
    EqualizerBandDefinition(id: "mid", label: "Mid", frequency: 1_500, q: 0.9, filterKind: .peaking),
    EqualizerBandDefinition(id: "high", label: "High", frequency: 6_000, q: 0.707, filterKind: .highShelf),
  ]

  public static let advanced: [EqualizerBandDefinition] = [
    EqualizerBandDefinition(id: "60", label: "60 Hz", frequency: 60, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "120", label: "120 Hz", frequency: 120, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "250", label: "250 Hz", frequency: 250, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "500", label: "500 Hz", frequency: 500, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "1000", label: "1 kHz", frequency: 1_000, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "2000", label: "2 kHz", frequency: 2_000, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "4000", label: "4 kHz", frequency: 4_000, q: 1.0, filterKind: .peaking),
    EqualizerBandDefinition(id: "8000", label: "8 kHz", frequency: 8_000, q: 1.0, filterKind: .peaking),
  ]

  public static func bands(for mode: EqualizerMode) -> [EqualizerBandDefinition] {
    switch mode {
    case .simple: simple
    case .advanced: advanced
    }
  }
}

public struct EqualizerSettings: Codable, Hashable, Sendable {
  public static let minimumGainDB: Float = -12
  public static let maximumGainDB: Float = 12

  public var isEnabled: Bool
  public var mode: EqualizerMode
  public private(set) var simpleGainsDB: [Float]
  public private(set) var advancedGainsDB: [Float]
  public private(set) var simplePreset: EqualizerPreset
  public private(set) var advancedPreset: EqualizerPreset
  public var adaptiveRole: AdaptiveAppRole

  public init(
    isEnabled: Bool = false,
    mode: EqualizerMode = .simple,
    simpleGainsDB: [Float] = [],
    advancedGainsDB: [Float] = [],
    simplePreset: EqualizerPreset = .flat,
    advancedPreset: EqualizerPreset = .flat,
    adaptiveRole: AdaptiveAppRole = .auto
  ) {
    self.isEnabled = isEnabled
    self.mode = mode
    self.simpleGainsDB = Self.normalized(
      simpleGainsDB,
      count: EqualizerBandCatalog.simple.count
    )
    self.advancedGainsDB = Self.normalized(
      advancedGainsDB,
      count: EqualizerBandCatalog.advanced.count
    )
    self.simplePreset = simplePreset
    self.advancedPreset = advancedPreset
    self.adaptiveRole = adaptiveRole
  }

  public var activeGainsDB: [Float] {
    gains(for: mode)
  }

  public var selectedPreset: EqualizerPreset {
    preset(for: mode)
  }

  public var headroomCompensationDB: Float {
    -max(0, activeGainsDB.max() ?? 0)
  }

  public func gains(for mode: EqualizerMode) -> [Float] {
    switch mode {
    case .simple: simpleGainsDB
    case .advanced: advancedGainsDB
    }
  }

  public func preset(for mode: EqualizerMode) -> EqualizerPreset {
    switch mode {
    case .simple: simplePreset
    case .advanced: advancedPreset
    }
  }

  public mutating func setGain(_ gainDB: Float, at index: Int, mode targetMode: EqualizerMode? = nil) {
    let targetMode = targetMode ?? mode
    switch targetMode {
    case .simple:
      guard simpleGainsDB.indices.contains(index) else { return }
      simpleGainsDB[index] = Self.clamped(gainDB)
      simplePreset = .custom
    case .advanced:
      guard advancedGainsDB.indices.contains(index) else { return }
      advancedGainsDB[index] = Self.clamped(gainDB)
      advancedPreset = .custom
    }
  }

  public mutating func applyPreset(_ preset: EqualizerPreset, mode targetMode: EqualizerMode? = nil) {
    guard preset != .custom else { return }
    let targetMode = targetMode ?? mode
    let curve = Self.curve(for: preset, mode: targetMode)
    switch targetMode {
    case .simple:
      simpleGainsDB = curve
      simplePreset = preset
    case .advanced:
      advancedGainsDB = curve
      advancedPreset = preset
    }
  }

  public mutating func resetActiveMode() {
    applyPreset(.flat)
  }

  public static func curve(for preset: EqualizerPreset, mode: EqualizerMode) -> [Float] {
    switch (mode, preset) {
    case (.simple, .flat), (.simple, .custom):
      [0, 0, 0]
    case (.simple, .voiceFocus):
      [-6, 3, -3]
    case (.simple, .warm):
      [2.5, 1, -1.5]
    case (.simple, .bassReduce):
      [-7, -2, 0]
    case (.simple, .trebleSoften):
      [0, 0, -5]
    case (.advanced, .flat), (.advanced, .custom):
      Array(repeating: 0, count: EqualizerBandCatalog.advanced.count)
    case (.advanced, .voiceFocus):
      [-8, -6, -3, 0, 2, 3, -1, -4]
    case (.advanced, .warm):
      [2.5, 2, 1.5, 1, 0, -0.5, -1.5, -2.5]
    case (.advanced, .bassReduce):
      [-9, -7, -4, -2, 0, 0, 0, 0]
    case (.advanced, .trebleSoften):
      [0, 0, 0, 0, -0.5, -1.5, -4, -6]
    }
  }

  private enum CodingKeys: String, CodingKey {
    case isEnabled
    case mode
    case simpleGainsDB
    case advancedGainsDB
    case simplePreset
    case advancedPreset
    case adaptiveRole
  }

  public init(from decoder: Decoder) throws {
    let defaults = EqualizerSettings()
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      self = defaults
      return
    }

    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback
    }

    self.init(
      isEnabled: value(.isEnabled, defaults.isEnabled),
      mode: value(.mode, defaults.mode),
      simpleGainsDB: value(.simpleGainsDB, defaults.simpleGainsDB),
      advancedGainsDB: value(.advancedGainsDB, defaults.advancedGainsDB),
      simplePreset: value(.simplePreset, defaults.simplePreset),
      advancedPreset: value(.advancedPreset, defaults.advancedPreset),
      adaptiveRole: value(.adaptiveRole, defaults.adaptiveRole)
    )
  }

  private static func normalized(_ gains: [Float], count: Int) -> [Float] {
    (0..<count).map { index in
      index < gains.count ? clamped(gains[index]) : 0
    }
  }

  private static func clamped(_ value: Float) -> Float {
    guard value.isFinite else { return 0 }
    return min(maximumGainDB, max(minimumGainDB, value))
  }
}
