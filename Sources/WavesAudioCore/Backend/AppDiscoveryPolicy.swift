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

    if !normalizedName.isEmpty {
      return "name-\(normalizedName)"
    }

    // Names with no ASCII alphanumerics (e.g. CJK-only process names) normalize
    // to empty; hashing the raw name keeps such apps distinct so persisted
    // volume/mute for one is never restored onto another. Only a genuinely
    // empty name falls back to the shared "unknown-app" id.
    let trimmedName = sanitizedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return "unknown-app" }
    return "unnamed-\(String(fnv1aHash(trimmedName), radix: 16))"
  }

  static func fnv1aHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }

  public static func inferCategory(bundleID: String?, displayName: String) -> AppCategory {
    let rawToken = [bundleID ?? "", displayName].joined(separator: " ")
    let token = rawToken.lowercased()
    let words = searchWords(in: rawToken)

    if token.contains("safari") || token.contains("chrome") || token.contains("chromium")
      || token.contains("firefox") || token.contains("brave") || token.contains("vivaldi")
      || token.contains("helium") || words.contains("edge") || words.contains("opera")
      || token.contains("microsoft.edge") || token.contains("operasoftware")
      || words.contains("arc") || token.contains("browser")
    {
      // Match "arc" only as a whole word so unrelated apps like "Archive
      // Utility" or "Monarch" are not misclassified as browsers.
      return .browser
    }

    if token.contains("zoom") || words.contains("meet") || token.contains("teams")
      || token.contains("webex") || token.contains("facetime")
    {
      return .conferencing
    }

    if token.contains("spotify") || words.contains("music") || token.contains("vlc")
      || token.contains("podcast") || words.contains("tv") || token.contains("quicktime")
    {
      // "quicktime" must be classified as media here, before the com.apple.
      // system fallback below, or the default "hide system processes" filter
      // hides an actively-playing QuickTime Player.
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

  private static func searchWords(in token: String) -> Set<String> {
    // Split separators and camel-case product names so short, real app names like
    // "GoogleMeet", "MeetInOne", "YouTubeMusic", and "AppleTV" keep matching
    // without reintroducing false positives such as "Meeting Notes" or "TVRemote".
    let camelSeparated = token.replacingOccurrences(
      of: #"([a-z0-9])([A-Z])"#,
      with: "$1 $2",
      options: .regularExpression
    )
    return Set(camelSeparated.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
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

  public static func treatsMissingAudioProcessAsPermanent(
    bundleID: String?,
    displayName: String,
    category: AppCategory
  ) -> Bool {
    if isLikelyAudioCapableApp(bundleID: bundleID, displayName: displayName, category: category) {
      return false
    }

    // Unknown user-facing apps are not safe to call permanently silent. Games,
    // niche browsers, web wrappers, creative tools, and Electron apps often have
    // no Core Audio process object until playback starts or a helper spins up.
    guard category == .system else { return false }
    return true
  }

  public static func isLikelyAudioCapableApp(
    bundleID: String?,
    displayName: String,
    category: AppCategory
  ) -> Bool {
    switch category {
    case .browser, .conferencing, .media, .communication:
      return true
    case .system:
      return false
    case .unknown:
      break
    }

    let rawToken = [bundleID ?? "", displayName].joined(separator: " ")
    let token = rawToken.lowercased()
    let words = searchWords(in: rawToken)
    return token.contains("electron")
      || token.contains("chromium")
      || token.contains("chrome")
      || token.contains("browser")
      || token.contains("helium")
      || words.contains("audio")
      || words.contains("music")
      || words.contains("video")
      || words.contains("player")
      || words.contains("stream")
      || words.contains("game")
      || words.contains("call")
      || words.contains("meet")
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

  /// Given the absolute executable path of an audio-producing process, returns
  /// the path of the **outermost** `.app` bundle that contains it, or nil when
  /// the executable doesn't live inside an app bundle.
  ///
  /// Chromium-based browsers (Chrome, Helium, Brave, Edge, Arc) and Electron
  /// apps emit audio from a sandboxed helper/"Audio Service" subprocess whose
  /// executable lives **inside** the parent app — e.g.
  /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper
  /// (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)`. Those
  /// helpers are absent from `NSWorkspace.runningApplications`, so the only way
  /// to attribute their audio to the user-facing app is to walk the executable
  /// path back to the enclosing top-level `.app`. Returning the *outermost*
  /// bundle (`Google Chrome.app`, not the nested `… Helper.app`) yields the
  /// parent the user actually recognizes.
  public static func topLevelAppBundlePath(forExecutablePath path: String) -> String? {
    guard !path.isEmpty else { return nil }
    var rebuilt = ""
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      rebuilt += "/" + component
      if component.hasSuffix(".app") {
        return rebuilt
      }
    }
    return nil
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
