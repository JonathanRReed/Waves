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
    // Re-probe real capture authorization so opening Advanced reflects the
    // current TCC state rather than the result cached at the last refresh.
    // The probe creates and immediately destroys a private tap with no IO
    // proc, so it is side-effect-free and cheap.
    if reprobeCaptureAuthorization {
      refreshCaptureAuthorization()
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

    return DiagnosticsReport(
      summary: recoverabilitySummary,
      checks: [
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
              ? "Waves owns routes that Wave Link cannot bypass. Verified Wave Link paths remain monitoring only to prevent duplicate audio."
              : "Elgato Wave Link owns ordinary per-app routes while it is active. Waves monitors those apps."
            : "Wave Link compatibility is disabled. Waves applies no Wave Link-specific route safeguards."
        ),
        DiagnosticsCheck(
          title: "Route recovery",
          status: routeRecoveryStatus,
          detail: routeRecoveryDetail
        ),
        DiagnosticsCheck(
          title: "Support matrix",
          status: .informational,
          detail: snapshot.supportMatrix.coverageSummary
        ),
      ]
    )
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
  @discardableResult
  func refreshCaptureAuthorization() -> CaptureAuthorizationResult {
    guard !isShuttingDown else { return captureAuthorization }
    guard #available(macOS 14.2, *) else {
      captureAuthorization = .unsupported
      return captureAuthorization
    }

    // A live managed route is stronger evidence of the capture grant than this
    // probe: it *is* a process tap, already created and rendering. Re-probing
    // behind one meant building and tearing down a system-wide tap against
    // coreaudiod twice every 8 seconds — the silent session refresh calls
    // `refresh()` and `diagnosticsReport()`, and both used to probe — for the
    // entire life of the process.
    if captureAuthorization == .authorized,
      controllers.values.contains(where: \.isActive)
    {
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
