import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WavesAudioCore

struct AppIconRaster: Sendable {
  let width: Int
  let height: Int
  let bytesPerRow: Int
  let rgbaBytes: Data
}

struct AppIconEncodingExecutor: Sendable {
  typealias Operation = @Sendable () -> Data?
  typealias Execute = @Sendable (@escaping Operation) async -> Data?

  private let execute: Execute

  init(execute: @escaping Execute) {
    self.execute = execute
  }

  func callAsFunction(_ operation: @escaping Operation) async -> Data? {
    await execute(operation)
  }

  static let detached = AppIconEncodingExecutor { operation in
    await Task.detached(priority: .utility) {
      operation()
    }.value
  }
}

struct AppIconEncoder: Sendable {
  typealias Encode = @Sendable (AppIconRaster) -> Data?
  private let operation: Encode
  private let executor: AppIconEncodingExecutor

  init(
    operation: @escaping Encode = Self.encodePNG,
    executor: AppIconEncodingExecutor = .detached
  ) {
    self.operation = operation
    self.executor = executor
  }

  func encode(_ raster: AppIconRaster) async -> Data? {
    let operation = operation
    return await executor {
      operation(raster)
    }
  }

  private static func encodePNG(_ raster: AppIconRaster) -> Data? {
    guard raster.width > 0, raster.height > 0,
      raster.bytesPerRow >= raster.width * 4,
      raster.rgbaBytes.count >= raster.bytesPerRow * raster.height,
      let provider = CGDataProvider(data: raster.rgbaBytes as CFData),
      let image = CGImage(
        width: raster.width,
        height: raster.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: raster.bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else { return nil }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}

enum AppRuntimeDiscovery {
  enum ActivationPolicy: Sendable {
    case regular
    case accessory
    case prohibited
  }

  struct CapturedApplication: Sendable {
    let pid: pid_t
    let bundleID: String?
    let localizedName: String
    let bundlePath: String?
    let activationPolicy: ActivationPolicy
    let isActive: Bool
    let iconTIFFData: Data?
    let runtimeIdentity: AppRuntimeIdentity?

    init(
      pid: pid_t,
      bundleID: String?,
      localizedName: String,
      bundlePath: String?,
      activationPolicy: ActivationPolicy,
      isActive: Bool,
      iconTIFFData: Data?,
      runtimeIdentity: AppRuntimeIdentity? = nil
    ) {
      self.pid = pid
      self.bundleID = bundleID
      self.localizedName = localizedName
      self.bundlePath = bundlePath
      self.activationPolicy = activationPolicy
      self.isActive = isActive
      self.iconTIFFData = iconTIFFData
      self.runtimeIdentity = runtimeIdentity
    }
  }

  struct Capture: Sendable {
    let applications: [CapturedApplication]
  }

  /// The AppKit boundary. `NSWorkspace`, `NSRunningApplication`, icon lookup,
  /// and image rasterization never escape this main-actor capture.
  @MainActor
  static func captureRunningApplications(
    currentBundleID: String?,
    knownIconData: [String: Data] = [:],
    iconEncoder: AppIconEncoder = AppIconEncoder()
  ) async -> Capture {
    var applications: [CapturedApplication] = []
    for app in NSWorkspace.shared.runningApplications {
      guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
      guard app.activationPolicy != .prohibited else { continue }
      guard let localizedName = app.localizedName, !localizedName.isEmpty else { continue }
      guard app.bundleIdentifier != currentBundleID else { continue }

      let logicalID = AppDiscoveryPolicy.logicalAppID(
        bundleID: app.bundleIdentifier,
        displayName: localizedName
      )
      // Only apps that can become mixer rows need an icon. Helpers, agents,
      // renderer processes, and nested bundles are captured for process-family
      // resolution but are rejected by discovery a moment later; rasterizing
      // and PNG-encoding their icons on every 8-second pass was dozens of
      // image encodes a minute that were thrown away unread.
      let bundlePath = app.bundleURL?.path
      let isManageable = AppDiscoveryPolicy.isManageableApp(
        named: localizedName,
        bundleID: app.bundleIdentifier,
        bundlePath: bundlePath
      )
      let iconData =
        isManageable
        ? await resolveIconData(
          logicalID: logicalID,
          knownIconData: knownIconData,
          captureRaster: { iconRaster(for: app) },
          iconEncoder: iconEncoder
        )
        : nil
      applications.append(
        CapturedApplication(
          pid: app.processIdentifier,
          bundleID: app.bundleIdentifier,
          localizedName: localizedName,
          bundlePath: bundlePath,
          activationPolicy: activationPolicy(for: app.activationPolicy),
          isActive: app.isActive,
          iconTIFFData: iconData,
          runtimeIdentity: RuntimeProcessIdentityCache.shared.identity(
            pid: app.processIdentifier
          )
        ))
    }
    return Capture(applications: applications)
  }

  @MainActor
  static func resolveIconData(
    logicalID: String,
    knownIconData: [String: Data],
    captureRaster: @MainActor () -> AppIconRaster?,
    iconEncoder: AppIconEncoder
  ) async -> Data? {
    if let known = knownIconData[logicalID] {
      return known
    }
    guard let raster = captureRaster() else { return nil }
    return await iconEncoder.encode(raster)
  }

  private static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// Pure transformation for detached discovery work. The input is Sendable and
  /// contains every value that would otherwise require AppKit access.
  static func discoverRunningApps(
    from capture: Capture,
    currentBundleID: String?,
    audiblePIDs: Set<pid_t>,
    audibleParentBundlePaths: Set<String>
  ) -> [AudioApp] {
    let runningApps = capture.applications.filter { app in
      app.bundleID != currentBundleID && app.activationPolicy != .prohibited
    }
    // Canonicalize the audible parent paths once. Each canonicalization is an
    // lstat per path component; doing it inside the candidate × audible loop
    // was on the order of a thousand lstats per 8-second pass.
    let canonicalAudibleParentBundlePaths = Set(audibleParentBundlePaths.map(canonicalPath))

    let candidateApps =
      runningApps
      .filter { app in
        let localizedName = app.localizedName
        guard
          AppDiscoveryPolicy.isManageableApp(
            named: localizedName,
            bundleID: app.bundleID,
            bundlePath: app.bundlePath
          )
        else { return false }
        return true
      }
      .sorted {
        $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
      }

    var representativesByLogicalID: [String: CapturedApplication] = [:]
    for app in candidateApps {
      let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: app.bundleID, displayName: app.localizedName)
      if let existing = representativesByLogicalID[logicalID] {
        representativesByLogicalID[logicalID] = AppRuntimeDiscovery.preferredRepresentative(current: existing, candidate: app)
      } else {
        representativesByLogicalID[logicalID] = app
      }
    }

    return representativesByLogicalID.values
      .sorted {
        $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
      }
      .map { app in
        let bundleID = app.bundleID
        let name = app.localizedName
        let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: bundleID, displayName: name)
        let category = AppDiscoveryPolicy.inferCategory(bundleID: bundleID, displayName: name)
        let pid = app.pid
        let familyApps = AppRuntimeDiscovery.processFamily(for: app, in: runningApps)
        let familyPIDs = Set(familyApps.map(\.pid))
        // An app is audible if a process in its NSWorkspace family is producing
        // output, OR — crucially for Chromium/Electron apps — if a helper whose
        // enclosing top-level app is this app is producing output. The latter is
        // the only signal that lights up browsers, whose audio is emitted by a
        // sandboxed "Audio Service" helper that never appears in the family set.
        let isAudibleByPID = !audiblePIDs.isEmpty && !familyPIDs.isDisjoint(with: audiblePIDs)
        let isAudibleByBundle =
          app.bundlePath.map { bundlePath in
            canonicalAudibleParentBundlePaths.contains(canonicalPath(bundlePath))
          } ?? false
        let isAudible = isAudibleByPID || isAudibleByBundle
        let isFrontmost = familyApps.contains(where: \.isActive)
        let routeState: RoutingState = isAudible ? .live : .monitorOnly

        return AudioApp(
          id: logicalID,
          logicalID: logicalID,
          pid: pid,
          bundleID: bundleID,
          displayName: name,
          iconName: AppDiscoveryPolicy.iconName(for: category),
          iconTIFFData: app.iconTIFFData,
          category: category,
          isActive: isAudible || isFrontmost,
          peakLevel: 0,
          rmsLevel: 0,
          desiredVolume: 1,
          appliedVolume: 1,
          isMuted: false,
          isPinned: false,
          routingState: routeState,
          compatibility: .supported,
          notes: nil,
          volumeBoost: 1.0,
          runtimeIdentity: app.runtimeIdentity
        )
      }
  }

  @MainActor
  private static func iconRaster(for app: NSRunningApplication) -> AppIconRaster? {
    let icon: NSImage
    if let runningIcon = app.icon {
      icon = runningIcon
    } else if let bundleURL = app.bundleURL {
      icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
    } else if let bundleID = app.bundleIdentifier,
      let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    {
      icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
    } else {
      return nil
    }

    let width = 64
    let height = 64
    let bytesPerRow = width * 4
    var bytes = Data(count: bytesPerRow * height)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let baseAddress = buffer.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { return nil }
    return AppIconRaster(width: width, height: height, bytesPerRow: bytesPerRow, rgbaBytes: bytes)
  }

  static func preferredRepresentative(
    current: CapturedApplication,
    candidate: CapturedApplication
  ) -> CapturedApplication {
    score(candidate) >= score(current) ? candidate : current
  }

  static func processFamily(
    for app: CapturedApplication,
    in runningApps: [CapturedApplication]
  ) -> [CapturedApplication] {
    return runningApps.filter { candidate in
      if let targetIdentity = app.runtimeIdentity,
        let candidateIdentity = candidate.runtimeIdentity
      {
        return AppDiscoveryPolicy.runtimeFamilyMatches(
          target: targetIdentity,
          candidate: candidateIdentity
        )
      }

      return candidate.pid == app.pid
    }
  }

  static func isStillRunning(_ app: AudioApp, in capture: Capture, currentBundleID: String?) -> Bool {
    capture.applications.contains { candidate in
      guard candidate.bundleID != currentBundleID else { return false }

      guard let storedIdentity = app.runtimeIdentity,
        let currentIdentity = candidate.runtimeIdentity
      else {
        return false
      }
      return currentIdentity == storedIdentity
    }
  }

  static func score(_ app: CapturedApplication) -> Int {
    let token = [app.bundleID ?? "", app.localizedName].joined(separator: " ").lowercased()
    var value = 0

    if app.activationPolicy == .regular {
      value += 8
    } else if app.activationPolicy == .accessory {
      value += 2
    }

    if app.isActive {
      value += 4
    }

    if URL(fileURLWithPath: app.bundlePath ?? "").pathExtension == "app" {
      value += 2
    }

    if app.iconTIFFData != nil {
      value += 1
    }

    if !AppDiscoveryPolicy.isCompanionAudioProcess(named: app.localizedName, bundleID: app.bundleID) {
      value += 6
    } else {
      value -= 4
    }

    if ["daemon", "updater", "agent", "service", "crashpad", "login item", "xpc"]
      .contains(where: { token.contains($0) })
    {
      value -= 6
    }

    return value
  }

  @MainActor
  private static func activationPolicy(for policy: NSApplication.ActivationPolicy) -> ActivationPolicy {
    switch policy {
    case .regular: .regular
    case .accessory: .accessory
    case .prohibited: .prohibited
    @unknown default: .prohibited
    }
  }
}
