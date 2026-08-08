import Testing
import WavesAudioCore

@testable import Waves

@Test func verifiedActiveWaveLinkUsesCoreAudioOutputFallbackWhenSystemTapOwnershipIsUnavailable() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: []
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
  #expect(conflict.detail.contains("Core Audio output"))
}

@Test func unrelatedReadableTapDoesNotBecomeAWaveLinkPublicMembershipClaim() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [
        .init(id: 10, description: .readable(.init(processObjectIDs: [1], isExclusive: false)))
      ]
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
  #expect(conflict.detail.contains("monitoring only"))
}

@Test func unrelatedUnreadableTapDoesNotBecomeAWaveLinkMembershipClaim() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [
        .init(id: 10, description: .unreadable)
      ]
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
}

@Test func wavesCreatedPrivateTapDoesNotBecomeAWaveLinkMembershipClaim() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [.init(id: 10, description: .privateTap)]
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
}

@Test func unrelatedExclusiveTapDoesNotBecomeAWaveLinkPublicMembershipClaim() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 2, pid: 102, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [
        .init(id: 10, description: .readable(.init(processObjectIDs: [2], isExclusive: true)))
      ]
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
}

@Test func multipleUnrelatedTapOwnersDoNotCreateAWaveLinkMembershipClaim() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 2, pid: 102, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [
        .init(id: 10, description: .readable(.init(processObjectIDs: [1], isExclusive: false))),
        .init(id: 11, description: .readable(.init(processObjectIDs: [2], isExclusive: false))),
      ]
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
}

@Test func spoofedWaveLinkBundleMetadataCannotDisableAnOrdinaryRoute() {
  let spoofed = AudioApp(
    id: "spoofed",
    pid: 101,
    bundleID: "com.elgato.WaveLink3",
    displayName: "Not Wave Link",
    category: .media,
    routingState: .managed,
    compatibility: .supported
  )
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: []
    )
  )

  #expect(service.conflict(for: spoofed) == nil)
}

@Test func verifiedWaveLinkTargetIsNeverEligibleForAWavesRenderer() {
  let waveLink = routerTestApp(id: "wave-link", pid: 202)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 3, pid: 202, isRunningOutput: true)
      ],
      taps: []
    )
  )

  let conflict = try! #require(service.conflict(for: waveLink))
  #expect(conflict.kind == .routerMixedOutput)
  #expect(conflict.detail.contains("mixed output"))
}

@Test func descriptorMismatchWrongTeamAndStaleIdentityDoNotCreateConflicts() {
  let target = routerTestApp(id: "target", pid: 101)
  let snapshot = VerifiedRouterObservationSnapshot(
    processObjects: [
      .init(id: 1, pid: 101, isRunningOutput: true),
      .init(id: 3, pid: 202, isRunningOutput: true),
    ],
    taps: [
      .init(id: 10, description: .readable(.init(processObjectIDs: [1], isExclusive: false)))
    ]
  )

  for identity in [
    VerifiedRouterProcessIdentity(pid: 202, teamIdentifier: "WRONGTEAM", matchesDesignatedRequirement: true),
    VerifiedRouterProcessIdentity(pid: 202, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: false),
    VerifiedRouterProcessIdentity(pid: 404, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true),
  ] {
    let service = VerifiedRouterConflictService(
      descriptors: [.waveLink3_2_2],
      snapshotProvider: { snapshot },
      identityVerifier: { _, _ in identity }
    )
    #expect(service.conflict(for: target) == nil)
  }
}

@Test func multipleVerifiedRouterProcessesPreserveTheUnattributableFallbackExplanation() {
  let target = routerTestApp(id: "target", pid: 101)
  let publicSnapshot = VerifiedRouterObservationSnapshot(
    processObjects: [
      .init(id: 1, pid: 101, isRunningOutput: true),
      .init(id: 3, pid: 202, isRunningOutput: true),
      .init(id: 4, pid: 303, isRunningOutput: true),
    ],
    taps: [
      .init(id: 10, description: .readable(.init(processObjectIDs: [1], isExclusive: false)))
    ]
  )
  let privateSnapshot = VerifiedRouterObservationSnapshot(
    processObjects: publicSnapshot.processObjects,
    taps: [.init(id: 11, description: .unreadable)]
  )
  let makeService: (VerifiedRouterObservationSnapshot) -> VerifiedRouterConflictService = { snapshot in
    VerifiedRouterConflictService(
      descriptors: [.waveLink3_2_2],
      snapshotProvider: { snapshot },
      identityVerifier: { pid, _ in
        guard pid == 202 || pid == 303 else { return nil }
        return .init(pid: pid, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
      }
    )
  }

  #expect(makeService(publicSnapshot).conflict(for: target)?.kind == .unattributableTapFallback)
  let fallback = try! #require(makeService(privateSnapshot).conflict(for: target))
  #expect(fallback.kind == .unattributableTapFallback)
  #expect(fallback.detail.contains("more than one verified routing process"))
}

@Test func emptyTapMembershipDoesNotInhibitVerifiedOutputFallback() {
  let target = routerTestApp(id: "target", pid: 101)
  let snapshot = VerifiedRouterObservationSnapshot(
    processObjects: [
      .init(id: 1, pid: 101, isRunningOutput: true),
      .init(id: 3, pid: 202, isRunningOutput: true),
    ],
    taps: [.init(id: 10, description: .readable(.init(processObjectIDs: [], isExclusive: false)))]
  )
  let service = VerifiedRouterConflictService(
    descriptors: [.waveLink3_2_2],
    snapshotProvider: { snapshot },
    identityVerifier: { pid, descriptor in
      guard pid == 202, descriptor == .waveLink3_2_2 else { return nil }
      return .init(pid: 202, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
    }
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .unattributableTapFallback)
  #expect(conflict.detail.contains("cannot publicly attribute"))
}

@Test func everySupportedDescriptorHasAConstructibleRequirement() {
  let allRequirementsAreConstructible = VerifiedRouterDescriptor.supported.allSatisfy {
    $0.hasConstructibleRequirement
  }
  #expect(allRequirementsAreConstructible)
}

@Test func verifiedRouterActivitySnapshotScansOnceForMultipleApps() {
  let scans = RouterActivityScanCounter()
  let snapshot = VerifiedRouterObservationSnapshot(
    processObjects: [
      .init(id: 1, pid: 101, isRunningOutput: true),
      .init(id: 2, pid: 202, isRunningOutput: true),
    ],
    taps: []
  )
  let service = VerifiedRouterConflictService(
    descriptors: [.waveLink3_2_2],
    snapshotProvider: {
      scans.increment()
      return snapshot
    },
    identityVerifier: { pid, _ in
      guard pid == 202 else { return nil }
      return .init(pid: pid, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
    }
  )

  let activity = service.activitySnapshot()
  let first = routerTestApp(id: "first", pid: 101)
  let second = routerTestApp(id: "second", pid: 303)

  #expect(scans.value == 2)
  #expect(activity.conflict(for: first)?.kind == .unattributableTapFallback)
  #expect(activity.conflict(for: second) == nil)
  #expect(scans.value == 2)
}

@Test func backendPrecomputesVerifiedRouterActivityOnceForMultipleApps() async {
  let scans = RouterActivityScanCounter()
  let observed = VerifiedRouterObservationSnapshot(
    processObjects: [
      .init(id: 1, pid: 101, isRunningOutput: true),
      .init(id: 2, pid: 202, isRunningOutput: true),
      .init(id: 3, pid: 303, isRunningOutput: true),
    ],
    taps: []
  )
  let service = VerifiedRouterConflictService(
    descriptors: [.waveLink3_2_2],
    snapshotProvider: {
      scans.increment()
      return observed
    },
    identityVerifier: { pid, _ in
      guard pid == 202 else { return nil }
      return .init(pid: pid, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
    }
  )
  let first = routerTestApp(id: "first", pid: 101)
  let second = routerTestApp(id: "second", pid: 303)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: AudioSessionSnapshot(
      apps: [first, second],
      currentDevice: nil,
      recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: true,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true
      )
    ),
    intentRouteApplyOverride: { _, _ in },
    verifiedRouterActivityProvider: { service.activitySnapshot() }
  )

  await backend.updateAudioLevels(at: .zero)

  #expect(scans.value == 2)
}

@MainActor
@Test func liveCompositionPassesTheVerifiedProviderToItsBackendFactory() async {
  var capturedProvider: WorkspaceAudioControlBackend.VerifiedRouterConflictProvider?
  var capturedActivityProvider: WorkspaceAudioControlBackend.VerifiedRouterActivityProvider?
  let target = routerTestApp(id: "target", pid: 101)
  _ = WavesComposition.makeLiveBackend(
    serviceFactory: {
      verifiedRouterService(
        snapshot: .init(
          processObjects: [
            .init(id: 1, pid: 101, isRunningOutput: true),
            .init(id: 3, pid: 202, isRunningOutput: true),
          ],
          taps: [.init(id: 10, description: .readable(.init(processObjectIDs: [1], isExclusive: false)))]
        )
      )
    },
    backendFactory: { provider, activityProvider in
      capturedProvider = provider
      capturedActivityProvider = activityProvider
      return WorkspaceAudioControlBackend(
        testingSnapshot: .empty,
        intentRouteApplyOverride: { _, _ in },
        verifiedRouterConflictProvider: provider,
        verifiedRouterActivityProvider: activityProvider
      )
    }
  )

  #expect(capturedProvider?(target)?.kind == .unattributableTapFallback)
  #expect(capturedActivityProvider?().conflict(for: target)?.kind == .unattributableTapFallback)
}

private func verifiedRouterService(
  snapshot: VerifiedRouterObservationSnapshot
) -> VerifiedRouterConflictService {
  VerifiedRouterConflictService(
    descriptors: [.waveLink3_2_2],
    snapshotProvider: { snapshot },
    identityVerifier: { pid, _ in
      guard pid == 202 else { return nil }
      return .init(pid: 202, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
    }
  )
}

private func routerTestApp(id: String, pid: Int32) -> AudioApp {
  AudioApp(
    id: id,
    pid: pid,
    bundleID: "com.example.\(id)",
    displayName: id,
    category: .media,
    routingState: .managed,
    compatibility: .supported
  )
}

private final class RouterActivityScanCounter: @unchecked Sendable {
  private var count = 0

  var value: Int { count }

  func increment() {
    count += 1
  }
}
