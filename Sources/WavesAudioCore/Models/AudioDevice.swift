import Foundation

public struct AudioDevice: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public var name: String
  public var kind: DeviceKind
  public var isCurrent: Bool
  public var isManagedRouteAvailable: Bool
  public var volumeControlMode: VolumeControlMode

  public init(
    id: String,
    name: String,
    kind: DeviceKind,
    isCurrent: Bool = false,
    isManagedRouteAvailable: Bool = false,
    volumeControlMode: VolumeControlMode = .software
  ) {
    // Validate string lengths to prevent excessive memory usage
    self.id = String(id.prefix(256))
    self.name = String(name.prefix(256))
    self.kind = kind
    self.isCurrent = isCurrent
    self.isManagedRouteAvailable = isManagedRouteAvailable
    self.volumeControlMode = volumeControlMode
  }
}

public enum DeviceKind: String, Codable, CaseIterable, Hashable, Sendable {
  case builtInOutput = "built_in_output"
  case bluetooth
  case display
  case virtual
  case aggregate
  case unknown

  public var displayName: String {
    switch self {
    case .builtInOutput:
      "Built-in Output"
    case .bluetooth:
      "Bluetooth"
    case .display:
      "Display"
    case .virtual:
      "Virtual"
    case .aggregate:
      "Aggregate"
    case .unknown:
      "Unknown"
    }
  }
}

public enum VolumeControlMode: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
  case hardware
  case software
  case automatic

  public var id: Self { self }

  public var displayName: String {
    switch self {
    case .hardware:
      "Hardware"
    case .software:
      "Software"
    case .automatic:
      "Automatic"
    }
  }

  public var description: String {
    switch self {
    case .hardware:
      "Prefer the system output device when a route supports it"
    case .software:
      "Control volume per-app using Waves routing"
    case .automatic:
      "Let Waves choose based on the current route"
    }
  }
}
