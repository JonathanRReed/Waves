import Foundation

public enum AppDiscoveryPolicy {
  public static func logicalAppID(bundleID: String?, displayName: String, pid: Int32? = nil) -> String {
    // Validate input length limits
    let maxBundleIDLength = 256
    let maxDisplayNameLength = 256

    let sanitizedBundleID = bundleID?.prefix(maxBundleIDLength)
    let sanitizedDisplayName = String(displayName.prefix(maxDisplayNameLength))

    let normalizedName = normalizedProcessName(sanitizedDisplayName)

    if let sanitizedBundleID, !sanitizedBundleID.isEmpty {
      if isCompanionAudioProcess(named: sanitizedDisplayName, bundleID: String(sanitizedBundleID)) {
        if let pid {
          return "\(sanitizedBundleID)::\(normalizedName)::pid-\(pid)"
        }
        return "\(sanitizedBundleID)::\(normalizedName)"
      }
      return String(sanitizedBundleID)
    }

    return normalizedName.isEmpty ? "unknown-app" : "name-\(normalizedName)"
  }

  public static func inferCategory(bundleID: String?, displayName: String) -> AppCategory {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()

    if token.contains("safari") || token.contains("chrome") || token.contains("firefox")
      || token.contains("arc") || token.contains("browser")
    {
      return .browser
    }

    if token.contains("zoom") || token.contains("meet") || token.contains("teams")
      || token.contains("webex") || token.contains("facetime")
    {
      return .conferencing
    }

    if token.contains("spotify") || token.contains("music") || token.contains("vlc")
      || token.contains("podcast") || token.contains("tv")
    {
      return .media
    }

    if token.contains("discord") || token.contains("slack") || token.contains("messages")
      || token.contains("telegram")
    {
      return .communication
    }

    if token.hasPrefix("com.apple.") {
      return .system
    }

    return .unknown
  }

  public static func normalizedProcessName(_ displayName: String) -> String {
    displayName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9]+"#,
        with: "-",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  public static func isManageableApp(named displayName: String, bundleID: String?) -> Bool {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()

    if excludedProcessMarkers.contains(where: { token.contains($0) }) {
      return false
    }

    return true
  }

  public static func isCompanionAudioProcess(named displayName: String, bundleID: String?) -> Bool {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()
    return companionProcessMarkers.contains(where: { token.contains($0) })
  }

  public static func iconName(for category: AppCategory) -> String {
    switch category {
    case .browser:
      return "globe"
    case .conferencing:
      return "video.fill"
    case .media:
      return "music.note"
    case .communication:
      return "bubble.left.and.bubble.right.fill"
    case .system:
      return "gearshape.fill"
    case .unknown:
      return "app.fill"
    }
  }

  public static func bundleFamilyMatches(appBundleID: String, candidateBundleID: String?) -> Bool {
    guard let candidateBundleID, !candidateBundleID.isEmpty else { return false }
    if candidateBundleID == appBundleID {
      return true
    }

    return bundleFamilyRoots(for: appBundleID).contains { root in
      candidateBundleID.hasPrefix(root + ".")
    }
  }

  public static func bundleFamilyRoots(for bundleID: String) -> [String] {
    var roots = [bundleID]

    let token = bundleID.lowercased()
    let components = bundleID.split(separator: ".").map(String.init)
    let shouldIncludeSiblingHelperRoot =
      token.contains("zen-browser") || token.contains("firefox") || token.contains("mozilla")

    if shouldIncludeSiblingHelperRoot && components.count > 2 {
      roots.append(components.dropLast().joined(separator: "."))
    }

    return Array(Set(roots)).sorted()
  }

  private static let excludedProcessMarkers = [
    "daemon",
    "updater",
    "launcher",
    "agent",
    "service",
    "crashpad",
    "login item",
    "xpc",
    "helper",
    "web content",
    "networking",
    "graphics and media",
    "isolated",
    "renderer",
    "gpu",
    "utility process",
    "plugincontainer",
    "content synchronizer",
    "extension helper",
  ]

  private static let companionProcessMarkers = [
    "helper",
    "web content",
    "networking",
    "graphics and media",
    "isolated",
    "renderer",
    "gpu",
    "utility process",
    "plugincontainer",
    "content synchronizer",
    "extension helper",
  ]
}
