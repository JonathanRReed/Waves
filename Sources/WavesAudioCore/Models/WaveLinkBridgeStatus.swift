import Foundation

/// The last known state of the Wave Link 3 control bridge, for Settings,
/// Diagnostics, and the diagnostics export. Purely descriptive: nothing here
/// feeds a routing decision, so it can be shown and copied freely.
public struct WaveLinkBridgeStatus: Hashable, Codable, Sendable {
  public enum Phase: String, Codable, Hashable, Sendable {
    /// No exchange has been attempted in this process yet.
    case idle
    /// The most recent exchange succeeded.
    case connected
    /// The most recent exchange failed; `lastError` says why.
    case failed
  }

  public struct ChannelSummary: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isSoftware: Bool
    public var appIdentifiers: [String]
    public var level: Float
    public var isMuted: Bool

    public init(
      id: String,
      name: String,
      isSoftware: Bool,
      appIdentifiers: [String],
      level: Float,
      isMuted: Bool
    ) {
      self.id = id
      self.name = name
      self.isSoftware = isSoftware
      self.appIdentifiers = appIdentifiers
      self.level = level
      self.isMuted = isMuted
    }

    /// A software channel holding no app is one Waves can claim for an app
    /// that needs independent control.
    public var isFreeSoftwareChannel: Bool { isSoftware && appIdentifiers.isEmpty }
  }

  public var phase: Phase
  /// `127.0.0.1:<port>` of the accepted control listener.
  public var endpoint: String?
  public var processIdentifier: Int32?
  public var applicationName: String?
  public var applicationVersion: String?
  public var interfaceRevision: Int?
  public var channels: [ChannelSummary]
  public var lastError: String?
  public var lastSuccessAt: Date?
  public var lastFailureAt: Date?
  public var updatedAt: Date

  public init(
    phase: Phase = .idle,
    endpoint: String? = nil,
    processIdentifier: Int32? = nil,
    applicationName: String? = nil,
    applicationVersion: String? = nil,
    interfaceRevision: Int? = nil,
    channels: [ChannelSummary] = [],
    lastError: String? = nil,
    lastSuccessAt: Date? = nil,
    lastFailureAt: Date? = nil,
    updatedAt: Date = .now
  ) {
    self.phase = phase
    self.endpoint = endpoint
    self.processIdentifier = processIdentifier
    self.applicationName = applicationName
    self.applicationVersion = applicationVersion
    self.interfaceRevision = interfaceRevision
    self.channels = channels
    self.lastError = lastError
    self.lastSuccessAt = lastSuccessAt
    self.lastFailureAt = lastFailureAt
    self.updatedAt = updatedAt
  }

  public static let idle = WaveLinkBridgeStatus()

  public var softwareChannelCount: Int { channels.filter(\.isSoftware).count }
  public var freeSoftwareChannelCount: Int { channels.filter(\.isFreeSoftwareChannel).count }

  /// One line for a status row: what Waves is talking to and whether the
  /// channel layout leaves room for independent per-app control.
  public var summaryLine: String {
    switch phase {
    case .idle:
      return "Not checked yet."
    case .failed:
      return lastError ?? "The last Wave Link exchange failed."
    case .connected:
      var parts: [String] = []
      let name = applicationName ?? "Wave Link"
      if let applicationVersion, !applicationVersion.isEmpty {
        parts.append("Connected to \(name) \(applicationVersion)")
      } else {
        parts.append("Connected to \(name)")
      }
      if let endpoint {
        parts.append("at \(endpoint)")
      }
      let software = softwareChannelCount
      if software > 0 {
        let free = freeSoftwareChannelCount
        parts.append(
          "· \(software) software channel\(software == 1 ? "" : "s"), \(free) free"
        )
      }
      return parts.joined(separator: " ")
    }
  }
}
