import AudioToolbox
import Foundation
import WavesAudioCore

// MARK: - Diagnostics and capture-authorization probing

extension WorkspaceAudioControlBackend {
  func diagnosticsReport() async -> DiagnosticsReport {
    await diagnosticsReport(reprobeCaptureAuthorization: true)
  }

  func diagnosticsReport(reprobeCaptureAuthorization: Bool) async -> DiagnosticsReport {
    guard !isShuttingDown else {
      return DiagnosticsReport(
        summary: "The audio backend is shutting down.",
        checks: []
      )
    }
    // Re-probe real capture authorization so opening Diagnostics reflects the
    // current TCC state rather than the result cached at the last refresh.
    // This is the one periodic-free path that deliberately pays for a fresh
    // system-wide probe tap; see `refreshCaptureAuthorization(force:)`.
    if reprobeCaptureAuthorization {
      refreshCaptureAuthorization(force: true)
    }
    refreshGlobalRouteHealth()

    // A hard route failure is one where the OS and capture permission are both
    // fine yet real routes errored — that is genuinely broken, not transient or
    // unsupported, so the Route recovery check should read as .failed (red).
    let hasRouteErrors = hasBlockingRouteErrors(in: snapshot.apps)
    let routeRecoveryStatus: DiagnosticsStatus
    if snapshot.backendStatus.isRouteRecoveryHealthy {
      routeRecoveryStatus = .passed
    } else if supportsPerAppRouting, captureAuthorization == .authorized, hasRouteErrors {
      routeRecoveryStatus = .failed
    } else {
      routeRecoveryStatus = .warning
    }

    var checks = [
      DiagnosticsCheck(
        title: "Audio component",
        status: snapshot.backendStatus.isAudioComponentInstalled ? .passed : .warning,
        detail: snapshot.backendStatus.isAudioComponentInstalled
          ? "Process tap routing is supported on this system."
          : "Per-app routing needs macOS 14.2 or newer."
      ),
      DiagnosticsCheck(
        title: "Audio capture permission",
        status: captureAuthorizationStatus,
        detail: captureAuthorizationDetail
      ),
      DiagnosticsCheck(
        title: "Per-app controller",
        status: .informational,
        detail: waveLinkCompatibilityEnabled
          ? perAppAudioController == .waves
            ? "Waves is the per-app mixer. While Wave Link is mixing, Waves sends volume and mute through Wave Link channels instead of adding a second audio route."
            : "Elgato Wave Link owns per-app levels while it is active. Waves only monitors those apps."
          : "Wave Link compatibility is off. Waves applies no Wave Link-specific route safeguards."
      ),
    ]
    if let bridgeStatus = await waveLinkBridgeStatus(), waveLinkCompatibilityEnabled {
      checks.append(
        DiagnosticsCheck(
          title: "Wave Link bridge",
          status: Self.diagnosticsStatus(for: bridgeStatus),
          detail: Self.diagnosticsDetail(for: bridgeStatus)
        ))
    }
    checks.append(
      DiagnosticsCheck(
        title: "Route recovery",
        status: routeRecoveryStatus,
        detail: routeRecoveryDetail
      ))
    checks.append(
      DiagnosticsCheck(
        title: "Support matrix",
        status: .informational,
        detail: snapshot.supportMatrix.coverageSummary
      ))
    return DiagnosticsReport(summary: recoverabilitySummary, checks: checks)
  }

  static func diagnosticsStatus(for bridge: WaveLinkBridgeStatus) -> DiagnosticsStatus {
    switch bridge.phase {
    case .idle: .informational
    case .connected: bridge.softwareChannelCount > 0 && bridge.freeSoftwareChannelCount == 0 ? .warning : .passed
    case .failed: .warning
    }
  }

  static func diagnosticsDetail(for bridge: WaveLinkBridgeStatus) -> String {
    switch bridge.phase {
    case .idle:
      return "No Wave Link exchange has happened yet. Use Test Connection in Settings › Mixer to check it now."
    case .failed:
      return bridge.summaryLine
    case .connected:
      if bridge.softwareChannelCount > 0, bridge.freeSoftwareChannelCount == 0 {
        return bridge.summaryLine
          + ". Every software channel holds an app, so only apps that already have their own channel can be controlled from Waves."
      }
      return bridge.summaryLine + "."
    }
  }

  private var captureAuthorizationStatus: DiagnosticsStatus {
    CaptureAuthorizationPresentation(captureAuthorization).status
  }

  private var captureAuthorizationDetail: String {
    CaptureAuthorizationPresentation(captureAuthorization).detail
  }

  private var routeRecoveryDetail: String {
    if snapshot.backendStatus.isRouteRecoveryHealthy {
      return "Per-app routing is active and can be reapplied."
    }
    if let lastError = snapshot.backendStatus.lastError {
      return lastError
    }
    return "Per-app routing is not ready. Refresh diagnostics, verify the output device, and retry route recovery."
  }

  private var recoverabilitySummary: String {
    guard snapshot.backendStatus.isAudioComponentInstalled else {
      return "Per-app routing is not available on this OS version."
    }
    guard captureAuthorization == .authorized else {
      return "Per-app routing is not ready because audio capture authorization could not be confirmed."
    }
    guard snapshot.currentDevice != nil else {
      return "Per-app routing is not ready because the current output device could not be identified."
    }

    let managed = snapshot.apps.filter { $0.routingState == .managed }.count
    return "Per-app routing is active for this session. Managed routes currently available: \(managed)."
  }

  var supportsPerAppRouting: Bool {
    if #available(macOS 14.2, *) {
      return true
    }

    return false
  }

  /// Probes audio-capture authorization by creating and immediately destroying
  /// a private global process tap. This codebase has no authoritative
  /// denial-only OSStatus, so every nonzero native status remains `.probeFailed`.
  ///
  /// An `.authorized` verdict is sticky unless `force` is set. The probe is a
  /// *system-wide* tap: coreaudiod has to attach it to every process that is
  /// rendering and detach it again, which every other audio client on the
  /// machine observes as a tap-list change. Repeating that on the 8-second
  /// session refresh for the life of the process — which is exactly what
  /// happened whenever Waves held no route of its own, such as the whole time
  /// Wave Link owns per-app audio — is churn that fragile clients (video
  /// conferencing apps in particular) have no reason to absorb. The grant
  /// cannot be revoked behind a running app without a relaunch, and a later
  /// failed tap creation reports its own error, so the cached verdict stays
  /// truthful. Explicit diagnostics refreshes still force a fresh probe.
  @discardableResult
  func refreshCaptureAuthorization(force: Bool = false) -> CaptureAuthorizationResult {
    guard !isShuttingDown else { return captureAuthorization }
    guard #available(macOS 14.2, *) else {
      captureAuthorization = .unsupported
      return captureAuthorization
    }

    if captureAuthorization == .authorized, !force {
      return captureAuthorization
    }

    if let captureAuthorizationProbe {
      captureAuthorization = captureAuthorizationProbe()
      return captureAuthorization
    }

    // A probe tap whose destroy failed is a private system-wide tap stranded in
    // coreaudiod. Retry those before creating another one.
    retryLeakedProbeTapDestroys()

    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "Waves-CapabilityProbe"
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .unmuted

    var tapID: AudioObjectID = .unknown
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    if status == noErr, tapID != .unknown {
      let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
      retainCleanupStatus(
        destroyStatus,
        stage: .authorizationProbe,
        detail: "Destroy audio-capture authorization probe tap"
      )
      if destroyStatus != noErr {
        // Keep the ID rather than discarding it, so the next pass can try again
        // instead of leaking one more global tap every probe.
        leakedProbeTapIDs.append(tapID)
      }
    }

    captureAuthorization = CaptureAuthorizationResult.fromProbe(
      isPlatformSupported: true,
      nativeStatus: status
    )
    if case .probeFailed(let nativeStatus) = captureAuthorization {
      logger.warning("Audio-capture authorization probe could not be verified (OSStatus: \(nativeStatus))")
    }
    return captureAuthorization
  }

  /// Retries destroying probe taps whose first destroy failed, newest last.
  /// Bounded: anything still failing after `maxProbeTapDestroyRetries` rounds is
  /// recorded once and dropped, so this can never grow without limit.
  private func retryLeakedProbeTapDestroys() {
    guard !leakedProbeTapIDs.isEmpty else { return }
    var stillLeaked: [AudioObjectID] = []
    for tapID in leakedProbeTapIDs {
      let status = AudioHardwareDestroyProcessTap(tapID)
      if status == noErr {
        // Core Audio recycles object IDs, so a surviving count keyed on a freed
        // ID would silently shorten the retry budget of whatever gets that ID
        // next. Clear it the moment the ID stops being ours.
        probeTapDestroyAttempts.removeValue(forKey: tapID)
        continue
      }
      let attempts = (probeTapDestroyAttempts[tapID] ?? 0) + 1
      probeTapDestroyAttempts[tapID] = attempts
      if attempts >= maxProbeTapDestroyRetries {
        retainCleanupStatus(
          status,
          stage: .authorizationProbe,
          detail: "Gave up destroying authorization probe tap after \(attempts) attempts"
        )
        probeTapDestroyAttempts.removeValue(forKey: tapID)
        continue
      }
      stillLeaked.append(tapID)
    }
    leakedProbeTapIDs = stillLeaked
  }
}

struct CaptureAuthorizationPresentation: Hashable, Sendable {
  let status: DiagnosticsStatus
  let detail: String
  let backendErrorDetail: String?

  init(_ result: CaptureAuthorizationResult) {
    switch result {
    case .authorized:
      status = .passed
      detail = "Audio capture is granted. Waves can apply per-app volume, mute, and boost."
      backendErrorDetail = nil
    case .notGranted:
      status = .failed
      detail = "Audio capture is not granted, so per-app controls cannot take effect. Allow Waves to record audio in System Settings › Privacy & Security › Microphone, then refresh."
      backendErrorDetail = detail
    case .undetermined:
      status = .warning
      detail = "Audio capture status is not yet known. Refresh to check."
      backendErrorDetail = nil
    case .unsupported:
      status = .warning
      detail = "Per-app routing needs macOS 14.2 or newer."
      backendErrorDetail = nil
    case .probeFailed(let nativeStatus):
      status = .failed
      detail = "Waves could not verify audio capture authorization (OSStatus: \(nativeStatus)). Refresh to retry; if it persists, restart Waves and check the current output device."
      backendErrorDetail = detail
    }
  }
}
