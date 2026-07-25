import Foundation

public enum AdaptiveContentType: String, Codable, CaseIterable, Hashable, Sendable {
  case lectureOrVoice
  case meeting
  case music
  case videoOrMedia
  case game
  case other

  public var displayName: String {
    switch self {
    case .lectureOrVoice: "Lecture or Voice"
    case .meeting: "Meeting"
    case .music: "Music"
    case .videoOrMedia: "Video or Media"
    case .game: "Game"
    case .other: "Other"
    }
  }

  public var usesSpeechActivation: Bool {
    self == .lectureOrVoice || self == .meeting
  }
}

public enum AdaptivePriority: String, Codable, CaseIterable, Hashable, Sendable {
  case foreground
  case normal
  case background
  case neverAdjust

  public var displayName: String {
    switch self {
    case .foreground: "Foreground"
    case .normal: "Normal"
    case .background: "Background"
    case .neverAdjust: "Never Adjust"
    }
  }

  /// Ordered focus tier. Never Adjust has no tier because it does not
  /// participate in adaptive gain decisions.
  public var focusRank: Int? {
    switch self {
    case .foreground: 2
    case .normal: 1
    case .background: 0
    case .neverAdjust: nil
    }
  }
}

public enum AdaptiveStrategy: String, Codable, CaseIterable, Hashable, Sendable {
  case lectureFocus
  case mediaFirst
  case balanced
  case custom

  public var displayName: String {
    switch self {
    case .lectureFocus: "Lecture Focus"
    case .mediaFirst: "Media First"
    case .balanced: "Balanced"
    case .custom: "Custom"
    }
  }
}

public enum AdaptiveFocusMode: String, Codable, CaseIterable, Hashable, Sendable {
  case assignedPriorities
  case followFrontApp
  case smartHybrid

  public var displayName: String {
    switch self {
    case .assignedPriorities: "Assigned Priorities"
    case .followFrontApp: "Follow Front App"
    case .smartHybrid: "Smart Hybrid"
    }
  }
}

public struct AdaptiveAppPolicy: Codable, Hashable, Sendable {
  public var contentType: AdaptiveContentType
  public var priority: AdaptivePriority

  public init(
    contentType: AdaptiveContentType = .other,
    priority: AdaptivePriority = .normal
  ) {
    self.contentType = contentType
    self.priority = priority
  }

  public static func migrating(
    legacyRole: AdaptiveAppRole,
    category: AppCategory,
    bundleIdentifier: String? = nil,
    displayName: String? = nil
  ) -> AdaptiveAppPolicy {
    switch legacyRole {
    case .auto:
      AdaptiveAppPolicy(
        contentType: AdaptiveMixing.inferredContentType(
          category: category,
          bundleIdentifier: bundleIdentifier,
          displayName: displayName
        ),
        priority: .normal
      )
    case .voice:
      AdaptiveAppPolicy(contentType: .lectureOrVoice, priority: .normal)
    case .media:
      AdaptiveAppPolicy(
        contentType: AdaptiveMixing.inferredMediaContentType(
          bundleIdentifier: bundleIdentifier,
          displayName: displayName
        ),
        priority: .background
      )
    case .ignore:
      AdaptiveAppPolicy(contentType: .other, priority: .neverAdjust)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case contentType
    case priority
  }

  public init(from decoder: Decoder) throws {
    let defaults = AdaptiveAppPolicy()
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      self = defaults
      return
    }
    self.contentType =
      (try? container.decodeIfPresent(
        AdaptiveContentType.self,
        forKey: .contentType
      )) ?? nil ?? defaults.contentType
    self.priority =
      (try? container.decodeIfPresent(
        AdaptivePriority.self,
        forKey: .priority
      )) ?? nil ?? defaults.priority
  }
}

public struct AdaptiveMixInput: Hashable, Sendable {
  public var appID: String
  public var policy: AdaptiveAppPolicy
  public var isManaged: Bool
  public var isMuted: Bool
  public var rms: Float
  public var voiceBandEnergy: Float
  public var isFrontmost: Bool

  public init(
    appID: String,
    policy: AdaptiveAppPolicy,
    isManaged: Bool,
    isMuted: Bool,
    rms: Float,
    voiceBandEnergy: Float,
    isFrontmost: Bool = false
  ) {
    self.appID = appID
    self.policy = policy
    self.isManaged = isManaged
    self.isMuted = isMuted
    self.rms = rms.isFinite ? max(0, rms) : 0
    self.voiceBandEnergy = voiceBandEnergy.isFinite ? max(0, voiceBandEnergy) : 0
    self.isFrontmost = isFrontmost
  }
}

/// Product constants and pure calculations shared by the adaptive coordinator.
public enum AdaptiveMixing {
  public static let speechThresholdDBFS = -42.0
  public static let minimumVoiceBandEnergyRatio = 0.55
  public static let speechActivationFrameCount = 2
  public static let speechHangDuration: TimeInterval = 0.6

  public static let speechDuckDB = -10.0
  public static let speechDuckAttackDuration: TimeInterval = 0.12
  public static let speechDuckReleaseDuration: TimeInterval = 0.9

  public static let loudnessAverageTimeConstant: TimeInterval = 3
  public static let loudnessTargetDBFS = -24.0
  public static let loudnessSilenceFloorDBFS = -50.0
  public static let minimumLoudnessTrimDB = -6.0
  public static let maximumLoudnessTrimDB = 3.0
  public static let downwardCorrectionDBPerSecond = 1.0
  public static let upwardCorrectionDBPerSecond = 0.5

  public static let minimumCombinedGainDB = -18.0
  public static let maximumCombinedGainDB = 3.0

  public static let activityThresholdDBFS = -50.0
  public static let gentlePriorityReductionDB = -4.0
  public static let moderatePriorityReductionDB = -6.0
  public static let strongPriorityReductionDB = -10.0

  public static func inferredContentType(
    category: AppCategory,
    bundleIdentifier: String? = nil,
    displayName: String? = nil
  ) -> AdaptiveContentType {
    switch category {
    case .conferencing, .communication:
      return .meeting
    case .media:
      return inferredMediaContentType(
        bundleIdentifier: bundleIdentifier,
        displayName: displayName
      )
    case .browser, .system, .unknown:
      return .other
    }
  }

  public static func inferredMediaContentType(
    bundleIdentifier: String? = nil,
    displayName: String? = nil
  ) -> AdaptiveContentType {
    let identity = [bundleIdentifier, displayName]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    let musicMarkers = [
      "spotify", "music", "tidal", "deezer", "qobuz", "pandora",
    ]
    return musicMarkers.contains(where: identity.contains) ? .music : .videoOrMedia
  }

  public static func policy(
    for strategy: AdaptiveStrategy,
    contentType: AdaptiveContentType,
    existingPolicy: AdaptiveAppPolicy? = nil
  ) -> AdaptiveAppPolicy {
    switch strategy {
    case .lectureFocus:
      let priority: AdaptivePriority
      switch contentType {
      case .lectureOrVoice:
        priority = .foreground
      case .music:
        priority = .background
      case .meeting, .videoOrMedia, .game, .other:
        priority = .normal
      }
      return AdaptiveAppPolicy(contentType: contentType, priority: priority)
    case .mediaFirst:
      let priority: AdaptivePriority
      switch contentType {
      case .music, .videoOrMedia:
        priority = .foreground
      case .meeting:
        priority = .background
      case .lectureOrVoice, .game, .other:
        priority = .normal
      }
      return AdaptiveAppPolicy(contentType: contentType, priority: priority)
    case .balanced:
      return AdaptiveAppPolicy(contentType: contentType, priority: .normal)
    case .custom:
      return existingPolicy
        ?? AdaptiveAppPolicy(contentType: contentType, priority: .normal)
    }
  }

  public static func priorityAttenuationDB(
    focus: AdaptivePriority?,
    app: AdaptivePriority
  ) -> Double {
    guard let focus, app != .neverAdjust else { return 0 }
    switch (focus, app) {
    case (.foreground, .normal):
      return gentlePriorityReductionDB
    case (.foreground, .background):
      return strongPriorityReductionDB
    case (.normal, .background):
      return moderatePriorityReductionDB
    case (.foreground, .foreground),
      (.normal, .foreground),
      (.normal, .normal),
      (.background, .foreground),
      (.background, .normal),
      (.background, .background),
      (.foreground, .neverAdjust),
      (.normal, .neverAdjust),
      (.background, .neverAdjust),
      (.neverAdjust, _):
      return 0
    }
  }

  /// Loudness can deepen a required priority reduction, but it cannot raise a
  /// lower-priority stream above the attenuation selected by the matrix.
  public static func combinedPolicyGainDB(
    priorityAttenuationDB: Double,
    loudnessTrimDB: Double
  ) -> Double {
    let safePriority =
      priorityAttenuationDB.isFinite
      ? min(0, max(minimumCombinedGainDB, priorityAttenuationDB))
      : 0
    let safeTrim =
      loudnessTrimDB.isFinite
      ? min(maximumLoudnessTrimDB, max(minimumLoudnessTrimDB, loudnessTrimDB))
      : 0
    let allowedTrim = safePriority < 0 ? min(0, safeTrim) : safeTrim
    return min(
      maximumCombinedGainDB,
      max(minimumCombinedGainDB, safePriority + allowedTrim)
    )
  }

  /// Converts a linear RMS amplitude to dBFS. Invalid or silent input is silence.
  public static func decibels(forAmplitude amplitude: Double) -> Double {
    guard amplitude.isFinite, amplitude > 0 else { return -.infinity }
    return 20 * log10(amplitude)
  }

  /// Returns voice-band energy as a fraction of full-band mean-square energy.
  public static func voiceBandEnergyRatio(
    fullBandRMS: Double,
    voiceBandEnergy: Double
  ) -> Double {
    guard
      fullBandRMS.isFinite,
      voiceBandEnergy.isFinite,
      fullBandRMS > 0,
      voiceBandEnergy >= 0
    else {
      return 0
    }

    let fullBandEnergy = fullBandRMS * fullBandRMS
    guard fullBandEnergy.isFinite, fullBandEnergy > 0 else { return 0 }
    return voiceBandEnergy / fullBandEnergy
  }

  /// Resolves automatic roles without guessing for neutral app categories.
  public static func resolvedRole(
    _ configuredRole: AdaptiveAppRole,
    category: AppCategory
  ) -> AdaptiveAppRole {
    guard configuredRole == .auto else { return configuredRole }

    switch category {
    case .conferencing:
      return .voice
    case .media:
      return .media
    case .browser, .communication, .system, .unknown:
      return .auto
    }
  }

  public static func isSpeechDuckEligible(
    role: AdaptiveAppRole,
    category: AppCategory
  ) -> Bool {
    resolvedRole(role, category: category) == .media
  }

  public static func isLoudnessBalanceEligible(
    role: AdaptiveAppRole,
    category: AppCategory
  ) -> Bool {
    resolvedRole(role, category: category) != .ignore
  }

  /// Combines the enabled temporary gain layers without changing manual gain.
  public static func combinedGainDB(
    mode: AdaptiveMixMode,
    role: AdaptiveAppRole,
    category: AppCategory,
    speechDuckDB: Double,
    loudnessTrimDB: Double
  ) -> Double {
    guard mode != .off else { return 0 }

    let resolved = resolvedRole(role, category: category)
    guard resolved != .ignore else { return 0 }

    let safeDuck = speechDuckDB.isFinite ? speechDuckDB : 0
    let safeTrim = loudnessTrimDB.isFinite ? loudnessTrimDB : 0
    let gain: Double

    switch mode {
    case .off:
      return 0
    case .speechFocus:
      gain = resolved == .media ? safeDuck : 0
    case .loudnessBalance:
      gain = safeTrim
    case .both:
      gain = safeTrim + (resolved == .media ? safeDuck : 0)
    }

    return min(maximumCombinedGainDB, max(minimumCombinedGainDB, gain))
  }

  static func elapsedDuration(_ elapsed: TimeInterval) -> TimeInterval {
    guard elapsed.isFinite, elapsed > 0 else { return 0 }
    return elapsed
  }

  static func move(
    _ value: Double,
    toward target: Double,
    maximumChange: Double
  ) -> Double {
    let change = max(0, maximumChange)
    if target < value {
      return max(target, value - change)
    }
    if target > value {
      return min(target, value + change)
    }
    return value
  }
}

/// Deterministic speech threshold, activation, and hang state.
public struct SpeechDetectionState: Hashable, Sendable {
  public private(set) var isSpeechActive: Bool
  public private(set) var consecutiveQualifyingFrames: Int
  public private(set) var hangRemaining: TimeInterval

  public init(
    isSpeechActive: Bool = false,
    consecutiveQualifyingFrames: Int = 0,
    hangRemaining: TimeInterval = 0
  ) {
    self.isSpeechActive = isSpeechActive
    self.consecutiveQualifyingFrames = max(0, consecutiveQualifyingFrames)
    self.hangRemaining = max(0, hangRemaining.isFinite ? hangRemaining : 0)
  }

  /// Evaluates one analysis frame. `voiceBandEnergy` is mean-square energy.
  @discardableResult
  public mutating func update(
    fullBandRMS: Double,
    voiceBandEnergy: Double,
    elapsed: TimeInterval
  ) -> Bool {
    let thresholdRMS = pow(10, AdaptiveMixing.speechThresholdDBFS / 20)
    let voiceRatio = AdaptiveMixing.voiceBandEnergyRatio(
      fullBandRMS: fullBandRMS,
      voiceBandEnergy: voiceBandEnergy
    )
    let qualifies =
      fullBandRMS.isFinite
      && fullBandRMS >= thresholdRMS
      && voiceRatio >= AdaptiveMixing.minimumVoiceBandEnergyRatio

    if qualifies {
      consecutiveQualifyingFrames = min(
        AdaptiveMixing.speechActivationFrameCount,
        consecutiveQualifyingFrames + 1
      )

      if consecutiveQualifyingFrames >= AdaptiveMixing.speechActivationFrameCount {
        isSpeechActive = true
        hangRemaining = AdaptiveMixing.speechHangDuration
      }
      return isSpeechActive
    }

    consecutiveQualifyingFrames = 0
    guard isSpeechActive else {
      hangRemaining = 0
      return false
    }

    let duration = AdaptiveMixing.elapsedDuration(elapsed)
    hangRemaining = max(0, hangRemaining - duration)
    if hangRemaining <= 1e-9 {
      hangRemaining = 0
      isSpeechActive = false
    }
    return isSpeechActive
  }
}

/// Smooth attack and release state for the fixed speech duck.
public struct SpeechDuckingState: Hashable, Sendable {
  public private(set) var currentGainDB: Double

  public init(currentGainDB: Double = 0) {
    let safeGain = currentGainDB.isFinite ? currentGainDB : 0
    self.currentGainDB = min(0, max(AdaptiveMixing.speechDuckDB, safeGain))
  }

  @discardableResult
  public mutating func update(
    isSpeechActive: Bool,
    isEligible: Bool,
    elapsed: TimeInterval
  ) -> Double {
    let target = isSpeechActive && isEligible ? AdaptiveMixing.speechDuckDB : 0
    let duration = AdaptiveMixing.elapsedDuration(elapsed)

    if target < currentGainDB {
      let rate =
        abs(AdaptiveMixing.speechDuckDB)
        / AdaptiveMixing.speechDuckAttackDuration
      currentGainDB = AdaptiveMixing.move(
        currentGainDB,
        toward: target,
        maximumChange: rate * duration
      )
    } else {
      let rate =
        abs(AdaptiveMixing.speechDuckDB)
        / AdaptiveMixing.speechDuckReleaseDuration
      currentGainDB = AdaptiveMixing.move(
        currentGainDB,
        toward: target,
        maximumChange: rate * duration
      )
    }

    return currentGainDB
  }
}

/// Exponential RMS averaging and rate-limited loudness correction state.
public struct LoudnessTrimState: Hashable, Sendable {
  public private(set) var averagedRMS: Double?
  public private(set) var currentGainDB: Double

  public init(
    averagedRMS: Double? = nil,
    currentGainDB: Double = 0
  ) {
    if let averagedRMS, averagedRMS.isFinite, averagedRMS >= 0 {
      self.averagedRMS = averagedRMS
    } else {
      self.averagedRMS = nil
    }

    let safeGain = currentGainDB.isFinite ? currentGainDB : 0
    self.currentGainDB = min(
      AdaptiveMixing.maximumLoudnessTrimDB,
      max(AdaptiveMixing.minimumLoudnessTrimDB, safeGain)
    )
  }

  @discardableResult
  public mutating func update(
    rms: Double,
    isEligible: Bool,
    elapsed: TimeInterval
  ) -> Double {
    let duration = AdaptiveMixing.elapsedDuration(elapsed)
    let safeRMS = rms.isFinite ? max(0, rms) : 0

    if isEligible {
      if let averagedRMS {
        let alpha = 1 - exp(-duration / AdaptiveMixing.loudnessAverageTimeConstant)
        self.averagedRMS = averagedRMS + alpha * (safeRMS - averagedRMS)
      } else {
        averagedRMS = safeRMS
      }
    } else {
      averagedRMS = nil
    }

    let instantaneousDBFS = AdaptiveMixing.decibels(forAmplitude: safeRMS)
    let target: Double
    if !isEligible || instantaneousDBFS < AdaptiveMixing.loudnessSilenceFloorDBFS {
      target = 0
    } else {
      let averageDBFS = AdaptiveMixing.decibels(forAmplitude: averagedRMS ?? 0)
      let requested = AdaptiveMixing.loudnessTargetDBFS - averageDBFS
      target = min(
        AdaptiveMixing.maximumLoudnessTrimDB,
        max(AdaptiveMixing.minimumLoudnessTrimDB, requested)
      )
    }

    let rate =
      target < currentGainDB
      ? AdaptiveMixing.downwardCorrectionDBPerSecond
      : AdaptiveMixing.upwardCorrectionDBPerSecond
    currentGainDB = AdaptiveMixing.move(
      currentGainDB,
      toward: target,
      maximumChange: rate * duration
    )
    return currentGainDB
  }
}

/// Smooths arbitrary adaptive-policy targets while preserving the established
/// 120 ms attack and 900 ms release behavior.
public struct AdaptivePolicyGainState: Hashable, Sendable {
  public private(set) var currentGainDB: Double
  private var transitionTargetGainDB: Double
  private var transitionRateDBPerSecond: Double

  public init(currentGainDB: Double = 0) {
    let safeGain = currentGainDB.isFinite ? currentGainDB : 0
    let clamped = min(
      AdaptiveMixing.maximumCombinedGainDB,
      max(AdaptiveMixing.minimumCombinedGainDB, safeGain)
    )
    self.currentGainDB = clamped
    self.transitionTargetGainDB = clamped
    self.transitionRateDBPerSecond = 0
  }

  @discardableResult
  public mutating func update(
    targetGainDB: Double,
    elapsed: TimeInterval
  ) -> Double {
    let safeTarget = targetGainDB.isFinite ? targetGainDB : 0
    let target = min(
      AdaptiveMixing.maximumCombinedGainDB,
      max(AdaptiveMixing.minimumCombinedGainDB, safeTarget)
    )
    if target != transitionTargetGainDB {
      transitionTargetGainDB = target
      let duration =
        target < currentGainDB
        ? AdaptiveMixing.speechDuckAttackDuration
        : AdaptiveMixing.speechDuckReleaseDuration
      transitionRateDBPerSecond = abs(target - currentGainDB) / duration
    }

    currentGainDB = AdaptiveMixing.move(
      currentGainDB,
      toward: target,
      maximumChange: transitionRateDBPerSecond
        * AdaptiveMixing.elapsedDuration(elapsed)
    )
    return currentGainDB
  }
}

/// Stateful, deterministic coordinator for the 1.2 content and priority model.
/// Audio samples never enter this value. It consumes only transient RMS and
/// voice-band energy measurements and emits temporary per-app gain values.
public struct AdaptivePolicyEngine: Sendable {
  public var usesLoudnessCorrection: Bool
  public var focusMode: AdaptiveFocusMode
  private var speechDetectionStates: [String: SpeechDetectionState] = [:]
  private var loudnessTrimStates: [String: LoudnessTrimState] = [:]
  private var gainStates: [String: AdaptivePolicyGainState] = [:]

  public init(
    usesLoudnessCorrection: Bool = true,
    focusMode: AdaptiveFocusMode = .smartHybrid
  ) {
    self.usesLoudnessCorrection = usesLoudnessCorrection
    self.focusMode = focusMode
  }

  public mutating func reset() {
    speechDetectionStates.removeAll()
    loudnessTrimStates.removeAll()
    gainStates.removeAll()
  }

  public mutating func update(
    inputs: [AdaptiveMixInput],
    elapsed: TimeInterval
  ) -> [String: Float] {
    let liveIDs = Set(inputs.map(\.appID))
    speechDetectionStates = speechDetectionStates.filter { liveIDs.contains($0.key) }
    loudnessTrimStates = loudnessTrimStates.filter { liveIDs.contains($0.key) }
    gainStates = gainStates.filter { liveIDs.contains($0.key) }

    var activePriorityRanks: [Int] = []
    activePriorityRanks.reserveCapacity(inputs.count)
    var effectivePriorities: [String: AdaptivePriority] = [:]
    effectivePriorities.reserveCapacity(inputs.count)

    for input in inputs {
      let routeIsEligible = input.isManaged && !input.isMuted
      let isActive: Bool
      if input.policy.contentType.usesSpeechActivation {
        var state = speechDetectionStates[input.appID] ?? SpeechDetectionState()
        let detected = state.update(
          fullBandRMS: routeIsEligible ? Double(input.rms) : 0,
          voiceBandEnergy: routeIsEligible ? Double(input.voiceBandEnergy) : 0,
          elapsed: elapsed
        )
        speechDetectionStates[input.appID] = state
        isActive = routeIsEligible && detected
      } else {
        isActive =
          routeIsEligible
          && AdaptiveMixing.decibels(forAmplitude: Double(input.rms))
            >= AdaptiveMixing.activityThresholdDBFS
      }

      let effectivePriority = effectivePriority(for: input, isActive: isActive)
      effectivePriorities[input.appID] = effectivePriority
      if isActive, let focusRank = effectivePriority.focusRank {
        activePriorityRanks.append(focusRank)
      }
    }

    let focusPriority: AdaptivePriority?
    switch activePriorityRanks.max() {
    case 2: focusPriority = .foreground
    case 1: focusPriority = .normal
    case 0: focusPriority = .background
    default: focusPriority = nil
    }

    var result: [String: Float] = [:]
    result.reserveCapacity(inputs.count)
    for input in inputs {
      if input.policy.priority == .neverAdjust {
        loudnessTrimStates.removeValue(forKey: input.appID)
        gainStates.removeValue(forKey: input.appID)
        result[input.appID] = 0
        continue
      }

      let routeIsEligible = input.isManaged && !input.isMuted
      let priorityGain =
        routeIsEligible
        ? AdaptiveMixing.priorityAttenuationDB(
          focus: focusPriority,
          app: effectivePriorities[input.appID] ?? input.policy.priority
        )
        : 0

      let loudnessGain: Double
      if usesLoudnessCorrection {
        var state = loudnessTrimStates[input.appID] ?? LoudnessTrimState()
        loudnessGain = state.update(
          rms: Double(input.rms),
          isEligible: routeIsEligible,
          elapsed: elapsed
        )
        loudnessTrimStates[input.appID] = state
      } else {
        loudnessTrimStates.removeValue(forKey: input.appID)
        loudnessGain = 0
      }

      let targetGain = AdaptiveMixing.combinedPolicyGainDB(
        priorityAttenuationDB: priorityGain,
        loudnessTrimDB: loudnessGain
      )
      var gainState = gainStates[input.appID] ?? AdaptivePolicyGainState()
      let gain = gainState.update(targetGainDB: targetGain, elapsed: elapsed)
      gainStates[input.appID] = gainState
      result[input.appID] = Float(gain)
    }
    return result
  }

  private func effectivePriority(
    for input: AdaptiveMixInput,
    isActive: Bool
  ) -> AdaptivePriority {
    let assignedPriority = input.policy.priority
    guard input.isFrontmost,
      isActive,
      assignedPriority != .neverAdjust
    else {
      return assignedPriority
    }

    switch focusMode {
    case .assignedPriorities:
      return assignedPriority
    case .followFrontApp:
      return .foreground
    case .smartHybrid:
      switch assignedPriority {
      case .background:
        return .normal
      case .normal, .foreground:
        return .foreground
      case .neverAdjust:
        return .neverAdjust
      }
    }
  }
}

/// Allocation-free two-pole voice-band energy analysis for tap buffers.
///
/// A first-order 200 Hz high-pass followed by a first-order 4 kHz low-pass
/// provides the stable energy ratio needed by the product heuristic without
/// retaining or exporting audio samples. Keep this object confined to the
/// owning audio controller's serial callback queue.
public final class VoiceBandEnergyAnalyzer {
  private struct ChannelState {
    var previousInput = 0.0
    var highPassOutput = 0.0
    var lowPassOutput = 0.0
  }

  public let sampleRate: Double
  public let channelCount: Int
  private let highPassAlpha: Double
  private let lowPassAlpha: Double
  private var states: [ChannelState]

  public init(sampleRate: Double, channelCount: Int) {
    self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
    self.channelCount = max(1, channelCount)
    let timeStep = 1 / self.sampleRate
    let highPassRC = 1 / (2 * Double.pi * 200)
    let lowPassRC = 1 / (2 * Double.pi * 4_000)
    self.highPassAlpha = highPassRC / (highPassRC + timeStep)
    self.lowPassAlpha = timeStep / (lowPassRC + timeStep)
    self.states = Array(repeating: ChannelState(), count: self.channelCount)
  }

  public func reset() {
    for index in states.indices {
      states[index] = ChannelState()
    }
  }

  public func analyze(
    _ data: UnsafeRawPointer,
    byteCount: Int,
    format: TapSampleFormat,
    bufferChannelCount: Int,
    channelOffset: Int = 0
  ) -> (energySum: Float, sampleCount: UInt32) {
    let localChannelCount = max(1, bufferChannelCount)
    guard byteCount > 0,
      channelOffset >= 0,
      channelOffset + localChannelCount <= channelCount
    else {
      return (0, 0)
    }

    switch format {
    case .float32:
      let pointer = data.assumingMemoryBound(to: Float.self)
      return analyzeSamples(
        count: byteCount / MemoryLayout<Float>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) }
      )
    case .int16:
      let pointer = data.assumingMemoryBound(to: Int16.self)
      let scale = Double(Int16.max)
      return analyzeSamples(
        count: byteCount / MemoryLayout<Int16>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) / scale }
      )
    case .int32:
      let pointer = data.assumingMemoryBound(to: Int32.self)
      let scale = Double(Int32.max)
      return analyzeSamples(
        count: byteCount / MemoryLayout<Int32>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) / scale }
      )
    case .unknown:
      return (0, 0)
    }
  }

  private func analyzeSamples(
    count: Int,
    bufferChannelCount: Int,
    channelOffset: Int,
    read: (Int) -> Double
  ) -> (energySum: Float, sampleCount: UInt32) {
    guard count >= bufferChannelCount else { return (0, 0) }
    let frameCount = count / bufferChannelCount
    var sum = 0.0
    var samples: UInt32 = 0

    for frame in 0..<frameCount {
      for localChannel in 0..<bufferChannelCount {
        let sampleIndex = frame * bufferChannelCount + localChannel
        let channel = channelOffset + localChannel
        let input = read(sampleIndex)
        let safeInput = input.isFinite ? input : 0
        var state = states[channel]
        let highPassed =
          highPassAlpha
          * (state.highPassOutput + safeInput - state.previousInput)
        let bandPassed =
          state.lowPassOutput + lowPassAlpha
          * (highPassed - state.lowPassOutput)
        state.previousInput = safeInput
        state.highPassOutput = highPassed
        state.lowPassOutput = bandPassed
        states[channel] = state
        sum += bandPassed * bandPassed
        samples &+= 1
      }
    }

    guard sum.isFinite else { return (0, samples) }
    return (Float(sum), samples)
  }
}
