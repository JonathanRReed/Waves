import Foundation

public struct SupportMatrix: Codable, Hashable, Sendable {
  public var entries: [SupportMatrixEntry]

  public init(entries: [SupportMatrixEntry]) {
    self.entries = entries
  }

  public var coverageSummary: String {
    let supportedCount = entries.filter { $0.state == .supported }.count
    return "\(supportedCount)/\(entries.count) validated"
  }
}

public struct SupportMatrixEntry: Identifiable, Codable, Hashable, Sendable {
  public var id: String { appID }
  public var appID: String
  public var displayName: String
  public var category: AppCategory
  public var state: CompatibilityState
  public var notes: String?

  public init(
    appID: String,
    displayName: String,
    category: AppCategory,
    state: CompatibilityState,
    notes: String? = nil
  ) {
    self.appID = appID
    self.displayName = displayName
    self.category = category
    self.state = state
    self.notes = notes
  }
}
