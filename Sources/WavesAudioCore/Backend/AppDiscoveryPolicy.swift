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

  public static func isManageableApp(
    named displayName: String,
    bundleID: String?,
    bundlePath: String? = nil
  ) -> Bool {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()

    // Nested app bundles are helpers owned by the outer app, not independent
    // mixer sources. Zoom's caphost.app is the concrete failure this prevents:
    // exposing both caphost and zoom.us created two controllers for the same
    // Core Audio process and played the call twice with a small delay.
    if let bundlePath, isNestedAppBundlePath(bundlePath) {
      return false
    }

    if excludedProcessMarkers.contains(where: { token.contains($0) }) {
      return false
    }

    return true
  }

  /// Returns the user-facing name of a third-party router that Waves must not
  /// wrap, or of a live router that would replay the same upstream app audio.
  ///
  /// Wave Link 3 uses Core Audio process taps for per-app routing. If both apps
  /// tap Zoom, a browser, or another source, each router renders its own copy to
  /// the output device. Waves must leave the upstream source untouched while
  /// Wave Link's monitor mix is active.
  public static func competingAudioRouterName(
    for targetBundleID: String?,
    among apps: [AudioApp]
  ) -> String? {
    let normalizedTarget = targetBundleID?.lowercased()
    // Never put Waves around the router's mixed output. Wave Link can carry
    // every monitored application in this one process, so one incompatible
    // callback would otherwise silence the entire personal mix at once.
    if let normalizedTarget,
      let routerName = competingAudioRouterBundleIDs[normalizedTarget]
    {
      return routerName
    }

    // `AudioApp.isActive` also means frontmost. Opening Wave Link's window is
    // not proof that it is monitoring audio and must not tear down every Waves
    // route. `.live` is the discovery signal backed by a running Core Audio
    // output stream.
    for app in apps where app.routingState == .live {
      guard
        let bundleID = app.bundleID?.lowercased(),
        let routerName = competingAudioRouterBundleIDs[bundleID]
      else {
        continue
      }
      return routerName
    }
    return nil
  }

  public static func isNestedAppBundlePath(_ bundlePath: String) -> Bool {
    let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
    guard bundleURL.pathExtension == "app",
      let outerPath = topLevelAppBundlePath(forExecutablePath: bundleURL.path)
    else {
      return false
    }
    return URL(fileURLWithPath: outerPath).standardizedFileURL.path != bundleURL.path
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

  /// Verifies helper attribution by the executable's actual enclosing bundle,
  /// not by an Info.plist identifier that another local app can self-declare.
  public static func executablePath(
    _ executablePath: String,
    belongsToAppBundleAt appBundlePath: String
  ) -> Bool {
    guard let enclosingPath = topLevelAppBundlePath(forExecutablePath: executablePath) else { return false }
    let enclosingURL = URL(fileURLWithPath: enclosingPath)
      .standardizedFileURL.resolvingSymlinksInPath()
    let appURL = URL(fileURLWithPath: appBundlePath)
      .standardizedFileURL.resolvingSymlinksInPath()
    return enclosingURL.path == appURL.path
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

  /// Authorizes a candidate helper using immutable live process identity.
  /// Bundle identifiers are never authority by themselves. Both processes must
  /// live inside the same canonical outer app bundle and belong to the same
  /// authenticated signer family.
  public static func runtimeFamilyMatches(
    target: AppRuntimeIdentity,
    candidate: AppRuntimeIdentity
  ) -> Bool {
    guard !target.outerBundlePath.isEmpty,
      target.outerBundlePath == candidate.outerBundlePath,
      executablePath(
        target.executablePath,
        belongsToAppBundleAt: target.outerBundlePath
      ),
      executablePath(
        candidate.executablePath,
        belongsToAppBundleAt: candidate.outerBundlePath
      )
    else {
      return false
    }

    let targetSigning = target.signingIdentity
    let candidateSigning = candidate.signingIdentity
    guard !targetSigning.identifier.isEmpty,
      !candidateSigning.identifier.isEmpty,
      !targetSigning.designatedRequirement.isEmpty,
      !candidateSigning.designatedRequirement.isEmpty,
      !targetSigning.codeDirectoryHash.isEmpty,
      !candidateSigning.codeDirectoryHash.isEmpty
    else {
      return false
    }
    switch (targetSigning.teamIdentifier, candidateSigning.teamIdentifier) {
    case let (targetTeam?, candidateTeam?):
      return !targetTeam.isEmpty && targetTeam == candidateTeam
    case (nil, nil):
      // Ad hoc code has no authenticated developer family. Without separately
      // verified sealed-bundle membership, only the exact securely bound signed
      // identity is authoritative. A chosen child identifier is not proof that
      // independently signed code belongs to the target.
      return targetSigning == candidateSigning
    default:
      return false
    }
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

  private static let competingAudioRouterBundleIDs = ["com.elgato.wavelink3": "Elgato Wave Link"]
}
