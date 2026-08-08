import Testing
import WavesAudioCore

@testable import Waves

@Test func publicTapMembershipYieldsOnlyTheClaimedProcessFamily() {
  let target = routerTestApp(id: "target", pid: 101)
  let unrelated = routerTestApp(id: "unrelated", pid: 102)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 2, pid: 102, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [
        .init(id: 10, description: .readable(.init(processObjectIDs: [1], isExclusive: false)))
      ]
    )
  )

  #expect(service.conflict(for: target)?.kind == .publicTapMembership)
  #expect(service.conflict(for: unrelated) == nil)
}

@Test func privateVerifiedTapFallbackYieldsConservativelyWithAnExplanation() {
  let target = routerTestApp(id: "target", pid: 101)
  let service = verifiedRouterService(
    snapshot: .init(
      processObjects: [
        .init(id: 1, pid: 101, isRunningOutput: true),
        .init(id: 3, pid: 202, isRunningOutput: true),
      ],
      taps: [
        .init(id: 10, description: .privateTap)
      ]
    )
  )

  let conflict = try! #require(service.conflict(for: target))
  #expect(conflict.kind == .privateOrUnreadableTapFallback)
  #expect(conflict.detail.contains("could not read"))
  #expect(conflict.detail.contains("tap membership"))
  #expect(conflict.detail.contains("monitoring only"))
}

@Test func exclusiveTapClaimsEveryCurrentProcessExceptItsExcludedMembership() {
  let claimed = routerTestApp(id: "claimed", pid: 101)
  let excluded = routerTestApp(id: "excluded", pid: 102)
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

  #expect(service.conflict(for: claimed)?.kind == .publicTapMembership)
  #expect(service.conflict(for: excluded) == nil)
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
      descriptors: [.waveLink3_1_1],
      snapshotProvider: { snapshot },
      identityVerifier: { _, _ in identity }
    )
    #expect(service.conflict(for: target) == nil)
  }
}

@Test func multipleVerifiedRouterProcessesUnionPublicClaimsAndConservativelyHandlePrivateTaps() {
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
      descriptors: [.waveLink3_1_1],
      snapshotProvider: { snapshot },
      identityVerifier: { pid, _ in
        guard pid == 202 || pid == 303 else { return nil }
        return .init(pid: pid, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
      }
    )
  }

  #expect(makeService(publicSnapshot).conflict(for: target)?.kind == .publicTapMembership)
  let fallback = try! #require(makeService(privateSnapshot).conflict(for: target))
  #expect(fallback.kind == .privateOrUnreadableTapFallback)
  #expect(fallback.detail.contains("more than one verified routing process"))
}

@Test func emptyPublicMembershipDoesNotClaimAnOrdinaryRoute() {
  let target = routerTestApp(id: "target", pid: 101)
  let snapshot = VerifiedRouterObservationSnapshot(
    processObjects: [
      .init(id: 1, pid: 101, isRunningOutput: true),
      .init(id: 3, pid: 202, isRunningOutput: true),
    ],
    taps: [.init(id: 10, description: .readable(.init(processObjectIDs: [], isExclusive: false)))]
  )
  let service = VerifiedRouterConflictService(
    descriptors: [.waveLink3_1_1],
    snapshotProvider: { snapshot },
    identityVerifier: { pid, descriptor in
      guard pid == 202, descriptor == .waveLink3_1_1 else { return nil }
      return .init(pid: 202, teamIdentifier: "Y93VXCB8Q5", matchesDesignatedRequirement: true)
    }
  )

  #expect(service.conflict(for: target) == nil)
}

@Test func everySupportedDescriptorHasAConstructibleRequirement() {
  let allRequirementsAreConstructible = VerifiedRouterDescriptor.supported.allSatisfy {
    $0.hasConstructibleRequirement
  }
  #expect(allRequirementsAreConstructible)
}

@MainActor
@Test func liveCompositionPassesTheVerifiedProviderToItsBackendFactory() async {
  var capturedProvider: WorkspaceAudioControlBackend.VerifiedRouterConflictProvider?
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
    backendFactory: { provider in
      capturedProvider = provider
      return WorkspaceAudioControlBackend(
        testingSnapshot: .empty,
        intentRouteApplyOverride: { _, _ in },
        verifiedRouterConflictProvider: provider
      )
    }
  )

  #expect(capturedProvider?(target)?.kind == .publicTapMembership)
}

private func verifiedRouterService(
  snapshot: VerifiedRouterObservationSnapshot
) -> VerifiedRouterConflictService {
  VerifiedRouterConflictService(
    descriptors: [.waveLink3_1_1],
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
