import Foundation

public enum AppIntentApplyOutcome: Hashable, Sendable {
  case applied
  case noChange
  case superseded
  case excluded
  case unavailable
  case unsupported
  case failed
}

public struct AppIntentApplyResult: Hashable, Sendable {
  public var appID: String
  public var generation: UInt64
  public var outcome: AppIntentApplyOutcome
  public var resultingApp: AudioApp?
  public var backendStatus: BackendStatus
  public var detail: String?

  public init(
    appID: String,
    generation: UInt64,
    outcome: AppIntentApplyOutcome,
    resultingApp: AudioApp?,
    backendStatus: BackendStatus,
    detail: String? = nil
  ) {
    self.appID = String(appID.prefix(256))
    self.generation = generation
    self.outcome = outcome
    self.resultingApp = resultingApp
    self.backendStatus = backendStatus
    self.detail = detail.map { String($0.prefix(1000)) }
  }
}

public enum ProfileRowApplyOutcome: Hashable, Sendable {
  case membershipOnly
  case applied
  case noChange
  case superseded
  case excluded
  case unavailable
  case unsupported
  case failed

  public init(appIntentOutcome: AppIntentApplyOutcome) {
    switch appIntentOutcome {
    case .applied: self = .applied
    case .noChange: self = .noChange
    case .superseded: self = .superseded
    case .excluded: self = .excluded
    case .unavailable: self = .unavailable
    case .unsupported: self = .unsupported
    case .failed: self = .failed
    }
  }
}

public struct ProfileRowApplyResult: Hashable, Sendable {
  public var entryIndex: Int
  public var appID: String
  public var generation: UInt64
  public var outcome: ProfileRowApplyOutcome
  public var resultingApp: AudioApp?
  public var detail: String?

  public init(
    entryIndex: Int,
    appID: String,
    generation: UInt64,
    outcome: ProfileRowApplyOutcome,
    resultingApp: AudioApp?,
    detail: String? = nil
  ) {
    self.entryIndex = max(0, entryIndex)
    self.appID = String(appID.prefix(256))
    self.generation = generation
    self.outcome = outcome
    self.resultingApp = resultingApp
    self.detail = detail.map { String($0.prefix(1000)) }
  }
}

public struct ProfileApplyResult: Hashable, Sendable {
  public var rows: [ProfileRowApplyResult]
  public var backendStatus: BackendStatus

  public init(rows: [ProfileRowApplyResult], backendStatus: BackendStatus) {
    self.rows = rows
    self.backendStatus = backendStatus
  }
}

public enum AudioCapabilityMode: Hashable, Sendable {
  case full
  case limited
}

public enum CaptureAuthorizationResult: Hashable, Sendable {
  case authorized
  case notGranted
  case undetermined
  case unsupported
  case probeFailed(nativeStatus: Int32)

  /// Conservative mapping for the Core Audio process-tap capability probe.
  /// Core Audio does not provide a reliable denial-only status in this codebase,
  /// so ambiguous native failures remain probe failures rather than guessed denial.
  public static func fromProbe(
    isPlatformSupported: Bool,
    nativeStatus: Int32
  ) -> CaptureAuthorizationResult {
    guard isPlatformSupported else { return .unsupported }
    return nativeStatus == 0 ? .authorized : .probeFailed(nativeStatus: nativeStatus)
  }
}

/// Resolves output-device truth without inventing or carrying forward a current device.
public struct OutputDeviceReadiness: Hashable, Sendable {
  public let currentDevice: AudioDevice?
  public let recentDeviceIDs: [String]
  public let errorDetail: String?

  public init(
    currentDevice: AudioDevice?,
    previousRecentDeviceIDs: [String],
    failureDetail: String? = nil
  ) {
    self.currentDevice = currentDevice
    var confirmedIDs = Set(previousRecentDeviceIDs.filter {
      !$0.isEmpty && $0 != "system-output"
    })
    if let currentDevice {
      confirmedIDs.insert(currentDevice.id)
      self.errorDetail = nil
    } else {
      self.errorDetail = failureDetail
        ?? "Waves could not identify the current output device. Check the system Sound output and retry."
    }
    self.recentDeviceIDs = confirmedIDs.sorted()
  }

  public var isReady: Bool { currentDevice != nil }
}

public enum CleanupStage: Hashable, Sendable {
  case authorizationProbe
  case listenerRemoval
  case ioProcStop
  case ioProcDestroy
  case aggregateDeviceDestroy
  case processTapDestroy
  case controllerDisposal
}

public struct CleanupDegradation: Hashable, Sendable {
  public var appID: String?
  public var stage: CleanupStage
  public var nativeStatus: Int32?
  public var detail: String?

  public init(
    appID: String? = nil,
    stage: CleanupStage,
    nativeStatus: Int32? = nil,
    detail: String? = nil
  ) {
    self.appID = appID.map { String($0.prefix(256)) }
    self.stage = stage
    self.nativeStatus = nativeStatus
    self.detail = detail.map { String($0.prefix(1000)) }
  }
}

public enum BackendShutdownCompletion: Hashable, Sendable {
  case clean
  case degraded
  case timedOut
  /// The legacy backend completed `stop()` but did not expose native cleanup results.
  case unverified
}

public struct BackendShutdownResult: Hashable, Sendable {
  public var completion: BackendShutdownCompletion
  public var degradations: [CleanupDegradation]

  public init(
    completion: BackendShutdownCompletion,
    degradations: [CleanupDegradation] = []
  ) {
    self.completion = completion
    self.degradations = degradations
  }

  /// Builds the checked native-cleanup result without allowing an internally
  /// inconsistent `.clean` result to carry failure rows.
  public init(checkedDegradations degradations: [CleanupDegradation]) {
    self.completion = degradations.isEmpty ? .clean : .degraded
    self.degradations = degradations
  }
}
