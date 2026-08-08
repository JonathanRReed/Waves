import AppKit
import Foundation
import WavesAudioCore

enum AppRuntimeDiscovery {
  static func discoverRunningApps(
    currentBundleID: String?,
    audiblePIDs: Set<pid_t>,
    audibleParentBundlePaths: Set<String>,
    knownIconData: [String: Data] = [:]
  ) -> [AudioApp] {
    let runningApps = NSWorkspace.shared.runningApplications
      .filter { app in
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        guard app.activationPolicy != .prohibited else { return false }
        guard let localizedName = app.localizedName, !localizedName.isEmpty else { return false }
        guard app.bundleIdentifier != currentBundleID else { return false }
        return true
      }

    let candidateApps =
      runningApps
      .filter { app in
        let localizedName = app.localizedName ?? ""
        guard
          AppDiscoveryPolicy.isManageableApp(
            named: localizedName,
            bundleID: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path
          )
        else { return false }
        return true
      }
      .sorted {
        ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
      }

    var representativesByLogicalID: [String: NSRunningApplication] = [:]
    for app in candidateApps {
      let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: app.bundleIdentifier, displayName: app.localizedName ?? "")
      if let existing = representativesByLogicalID[logicalID] {
        representativesByLogicalID[logicalID] = AppRuntimeDiscovery.preferredRepresentative(current: existing, candidate: app)
      } else {
        representativesByLogicalID[logicalID] = app
      }
    }

    return representativesByLogicalID.values
      .sorted {
        ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
      }
      .map { app in
        let bundleID = app.bundleIdentifier
        let name = app.localizedName ?? "Unknown App"
        let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: bundleID, displayName: name)
        let category = AppDiscoveryPolicy.inferCategory(bundleID: bundleID, displayName: name)
        let pid = app.processIdentifier
        let familyApps = AppRuntimeDiscovery.processFamily(for: app, in: runningApps)
        let familyPIDs = Set(familyApps.map(\.processIdentifier))
        // An app is audible if a process in its NSWorkspace family is producing
        // output, OR — crucially for Chromium/Electron apps — if a helper whose
        // enclosing top-level app is this app is producing output. The latter is
        // the only signal that lights up browsers, whose audio is emitted by a
        // sandboxed "Audio Service" helper that never appears in the family set.
        let isAudibleByPID = !audiblePIDs.isEmpty && !familyPIDs.isDisjoint(with: audiblePIDs)
        let isAudibleByBundle =
          app.bundleURL.map { bundleURL in
            audibleParentBundlePaths.contains { candidate in
              URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
                == bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
            }
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
          iconTIFFData: knownIconData[logicalID] ?? AppRuntimeDiscovery.iconTIFFData(for: app),
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
          volumeBoost: 1.0
        )
      }
  }

  static func iconTIFFData(for app: NSRunningApplication) -> Data? {
    if let icon = app.icon {
      return iconPNGData(from: icon)
    }

    if let bundleURL = app.bundleURL {
      return iconPNGData(from: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    if let bundleID = app.bundleIdentifier,
      let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    {
      return iconPNGData(from: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    return nil
  }

  static func iconPNGData(from icon: NSImage) -> Data? {
    let size = NSSize(width: 64, height: 64)
    let resized = NSImage(size: size)
    resized.lockFocus()
    icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    resized.unlockFocus()

    guard let tiffData = resized.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData)
    else {
      return nil
    }

    return bitmap.representation(using: .png, properties: [:])
  }

  static func preferredRepresentative(
    current: NSRunningApplication,
    candidate: NSRunningApplication
  ) -> NSRunningApplication {
    score(candidate) >= score(current) ? candidate : current
  }

  static func processFamily(
    for app: NSRunningApplication,
    in runningApps: [NSRunningApplication]
  ) -> [NSRunningApplication] {
    let appName = app.localizedName ?? ""
    let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: app.bundleIdentifier, displayName: appName)

    return runningApps.filter { candidate in
      if candidate.processIdentifier == app.processIdentifier {
        return true
      }

      if let bundleID = app.bundleIdentifier,
        AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: candidate.bundleIdentifier)
      {
        return true
      }

      return AppDiscoveryPolicy.logicalAppID(
        bundleID: candidate.bundleIdentifier,
        displayName: candidate.localizedName ?? ""
      ) == logicalID
    }
  }

  static func isStillRunning(_ app: AudioApp, currentBundleID: String?) -> Bool {
    NSWorkspace.shared.runningApplications.contains { candidate in
      guard candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
      guard candidate.bundleIdentifier != currentBundleID else { return false }

      if let pid = app.pid, candidate.processIdentifier == pid {
        return true
      }

      if let bundleID = app.bundleID,
        AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: candidate.bundleIdentifier)
      {
        return true
      }

      return AppDiscoveryPolicy.logicalAppID(
        bundleID: candidate.bundleIdentifier,
        displayName: candidate.localizedName ?? ""
      ) == app.logicalID
    }
  }

  static func score(_ app: NSRunningApplication) -> Int {
    let token = [app.bundleIdentifier ?? "", app.localizedName ?? ""].joined(separator: " ").lowercased()
    var value = 0

    if app.activationPolicy == .regular {
      value += 8
    } else if app.activationPolicy == .accessory {
      value += 2
    }

    if app.isActive {
      value += 4
    }

    if app.bundleURL?.pathExtension == "app" {
      value += 2
    }

    if app.icon != nil {
      value += 1
    }

    if let localizedName = app.localizedName,
      !AppDiscoveryPolicy.isCompanionAudioProcess(named: localizedName, bundleID: app.bundleIdentifier)
    {
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
}
