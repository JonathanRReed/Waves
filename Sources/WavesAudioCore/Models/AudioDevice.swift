import Foundation

public struct AudioDevice: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public var name: String
  public var kind: DeviceKind
  public var isCurrent: Bool
  public var isManagedRouteAvailable: Bool

  public init(
    id: String,
    name: String,
    kind: DeviceKind,
    isCurrent: Bool = false,
    isManagedRouteAvailable: Bool = false
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.isCurrent = isCurrent
    self.isManagedRouteAvailable = isManagedRouteAvailable
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
