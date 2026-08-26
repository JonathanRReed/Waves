import Foundation
import Testing

@testable import Waves

@Test func waveLinkDiscoveryPrefersThePublishedPortBeforeTheFallbackRange() {
  let ports = WaveLinkEndpointDiscovery.candidatePorts(publishedPort: 49_204)
  #expect(ports.first == 49_204)
  #expect(Array(ports.dropFirst()) == WaveLinkEndpointDiscovery.fallbackPorts)

  let overlapping = WaveLinkEndpointDiscovery.candidatePorts(publishedPort: 1_885)
  #expect(overlapping.first == 1_885)
  #expect(overlapping.count == WaveLinkEndpointDiscovery.fallbackPorts.count)

  let unpublished = WaveLinkEndpointDiscovery.candidatePorts(publishedPort: nil)
  #expect(unpublished == WaveLinkEndpointDiscovery.fallbackPorts)
}

@Test func waveLinkDiscoveryParsesOnlyValidWSInfoPorts() {
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 1884}"#.utf8)) == 1_884)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 49204}"#.utf8)) == 49_204)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 0}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 65536}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": -5}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": "1884"}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data("not json".utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data("{}".utf8)) == nil)
}

@Test func waveLinkDiscoveryChecksTheContainerWSInfoLocationFirst() {
  let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
  let urls = WaveLinkEndpointDiscovery.wsInfoCandidateURLs(homeDirectory: home)
  #expect(
    urls.map(\.path) == [
      "/Users/example/Library/Containers/com.elgato.WaveLink3/Data/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
      "/Users/example/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
    ]
  )
}

@Test func waveLinkDiscoveryPairsListenerPIDsWithTheirPorts() {
  let output = """
    p1366
    f9
    n127.0.0.1:1884
    f10
    n[::1]:1884
    p42
    f5
    n*:1893
    n127.0.0.1:49204
    nlocalhost.socket
    """
  let listeners = WaveLinkEndpointDiscovery.parseListeners(output)
  #expect(
    listeners == [
      .init(pid: 1_366, port: 1_884),
      .init(pid: 42, port: 1_893),
      .init(pid: 42, port: 49_204),
    ]
  )
}

@Test func waveLinkDiscoveryVerifiesListenersInCandidatePriorityOrder() throws {
  let listeners: [WaveLinkEndpointDiscovery.Listener] = [
    .init(pid: 99, port: 49_204),
    .init(pid: 1_366, port: 1_884),
  ]
  let verifyOnly1366: WaveLinkLoopbackPeerVerifier.IdentityVerifier = { pid, descriptor in
    guard pid == 1_366 else { return nil }
    return VerifiedRouterProcessIdentity(
      pid: pid,
      teamIdentifier: descriptor.teamIdentifier,
      matchesDesignatedRequirement: true
    )
  }

  // The published port wins when its listener verifies.
  let verifyEverything: WaveLinkLoopbackPeerVerifier.IdentityVerifier = { pid, descriptor in
    VerifiedRouterProcessIdentity(
      pid: pid,
      teamIdentifier: descriptor.teamIdentifier,
      matchesDesignatedRequirement: true
    )
  }
  let published = try WaveLinkEndpointDiscovery.verifiedEndpoint(
    candidatePorts: [49_204, 1_884],
    listeners: listeners,
    identityVerifier: verifyEverything
  )
  #expect(published == .init(pid: 99, port: 49_204))

  // An unverified squatter on the published port cannot shadow the verified
  // fallback listener.
  let fallback = try WaveLinkEndpointDiscovery.verifiedEndpoint(
    candidatePorts: [49_204, 1_884],
    listeners: listeners,
    identityVerifier: verifyOnly1366
  )
  #expect(fallback == .init(pid: 1_366, port: 1_884))
}

@Test func waveLinkDiscoveryDistinguishesMissingAndUnverifiedListeners() {
  #expect(throws: WaveLinkControlBridgeError.self) {
    try WaveLinkEndpointDiscovery.verifiedEndpoint(
      candidatePorts: [1_884],
      listeners: [],
      identityVerifier: { _, _ in nil }
    )
  }
  #expect(throws: WaveLinkControlBridgeError.unverifiedLoopbackPeer) {
    try WaveLinkEndpointDiscovery.verifiedEndpoint(
      candidatePorts: [1_884],
      listeners: [.init(pid: 7, port: 1_884)],
      identityVerifier: { _, _ in nil }
    )
  }
}

@Test func waveLinkEndpointResolverCachesOnlyWhileTheProcessRevalidates() async throws {
  final class Counter: @unchecked Sendable {
    var discoveries = 0
    var revalidations = 0
  }
  let counter = Counter()
  let resolver = WaveLinkVerifiedEndpointResolver(
    discover: {
      counter.discoveries += 1
      return .init(pid: 1_366, port: 1_884)
    },
    revalidateCached: { _ in
      counter.revalidations += 1
      return counter.revalidations > 1
    }
  )

  let first = try await resolver.verifiedEndpoint()
  #expect(first == .init(pid: 1_366, port: 1_884))
  #expect(counter.discoveries == 1)

  // First reuse attempt fails revalidation and rediscover; second reuses.
  _ = try await resolver.verifiedEndpoint()
  #expect(counter.discoveries == 2)
  _ = try await resolver.verifiedEndpoint()
  #expect(counter.discoveries == 2)

  await resolver.invalidate()
  _ = try await resolver.verifiedEndpoint()
  #expect(counter.discoveries == 3)
}
