import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func waveLinkBridgeControlsAnExactDedicatedSoftwareChannel() async throws {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "channel-browser",
        name: "Browser",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: [.init(id: "com.example.browser")]
      )
    ]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  let confirmation = try await bridge.apply(
    bundleIdentifier: "com.example.browser",
    volume: 0.35,
    isMuted: true
  )

  #expect(confirmation.channelID == "channel-browser")
  #expect(confirmation.appliedVolume == 0.35)
  #expect(confirmation.isMuted)
  #expect(await rpc.addRequests == [])
  #expect(await rpc.setRequests.count == 1)
}

@Test func waveLinkBridgeMovesAnAppFromASharedChannelBeforeControllingIt() async throws {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "shared",
        name: "Voice Apps",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.tinyspeck.slackmacgap")],
        mixes: [.init(id: "personal", level: 1, isMuted: false)]
      ),
      .init(
        id: "empty",
        name: "Aux 1",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: [],
        mixes: [.init(id: "personal", level: 1, isMuted: false)]
      ),
    ]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  let confirmation = try await bridge.apply(
    bundleIdentifier: "us.zoom.xos",
    volume: 0,
    isMuted: false
  )

  #expect(confirmation.channelID == "empty")
  #expect(await rpc.addRequests == [.init(appID: "us.zoom.xos", channelID: "empty")])
  #expect(await rpc.setRequests.last?.level == 0)
}

@Test func waveLinkBridgeFailsClosedWhenNoDedicatedSoftwareChannelIsAvailable() async {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "shared",
        name: "Voice Apps",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.tinyspeck.slackmacgap")],
        mixes: [.init(id: "personal", level: 1, isMuted: false)]
      )
    ]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.setRequests.isEmpty)
}

@Test func waveLinkBridgeRejectsAnUnexpectedLoopbackApplication() async {
  let rpc = WaveLinkRPCStub(channels: [], applicationID: "NotWaveLink")
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.channelRequestCount == 0)
}

@Test func waveLinkBridgeRejectsAnUnverifiedLoopbackPeerBeforeSendingRPC() async {
  let rpc = WaveLinkRPCStub(channels: [])
  let bridge = WaveLinkControlBridge(
    request: { method, params in
      try await rpc.request(method: method, params: params)
    },
    validatePeer: {
      throw WaveLinkControlBridgeError.unverifiedLoopbackPeer
    }
  )

  await #expect(throws: WaveLinkControlBridgeError.unverifiedLoopbackPeer) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.applicationInfoRequestCount == 0)
}

@Test func waveLinkBridgeRejectsAPreRevisionOneInterface() async {
  let rpc = WaveLinkRPCStub(channels: [], interfaceRevision: 0)
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.incompatibleApplication) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.channelRequestCount == 0)
}

@Test func waveLinkBridgeFinishesTheTransportSequenceAfterSuccessAndFailure() async throws {
  final class SequenceCounter: @unchecked Sendable {
    var finished = 0
  }
  let counter = SequenceCounter()
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "channel-browser",
        name: "Browser",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: [.init(id: "com.example.browser")]
      )
    ]
  )
  let bridge = WaveLinkControlBridge(
    request: { method, params in
      try await rpc.request(method: method, params: params)
    },
    finishSequence: { counter.finished += 1 }
  )

  _ = try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.5, isMuted: false)
  #expect(counter.finished == 1)

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "com.example.other", volume: 0.5, isMuted: false)
  }
  #expect(counter.finished == 2)
}

private actor WaveLinkRPCStub {
  struct AddRequest: Codable, Equatable, Sendable {
    let appID: String
    let channelID: String

    enum CodingKeys: String, CodingKey {
      case appID = "appId"
      case channelID = "channelId"
    }
  }

  struct SetRequest: Codable, Equatable, Sendable {
    let id: String
    let level: Float
    let isMuted: Bool
  }

  private var channels: [WaveLinkChannel]
  private let applicationID: String
  private let interfaceRevision: Int
  private let mixesAfterAdd: [WaveLinkChannelMix]?
  private let sourceMixesAfterAdd: [WaveLinkChannelMix]?
  private let roundsChannelLevels: Bool
  private(set) var applicationInfoRequestCount = 0
  private(set) var addRequests: [AddRequest] = []
  private(set) var setRequests: [SetRequest] = []
  private(set) var channelRequestCount = 0

  // Wave Link 3.0-3.2 report interfaceRevision 1, so the stub defaults to the
  // value real installs answer with.
  init(
    channels: [WaveLinkChannel], applicationID: String = "EWL", interfaceRevision: Int = 1,
    mixesAfterAdd: [WaveLinkChannelMix]? = nil,
    sourceMixesAfterAdd: [WaveLinkChannelMix]? = nil,
    roundsChannelLevels: Bool = false
  ) {
    self.channels = channels
    self.applicationID = applicationID
    self.interfaceRevision = interfaceRevision
    self.mixesAfterAdd = mixesAfterAdd
    self.sourceMixesAfterAdd = sourceMixesAfterAdd
    self.roundsChannelLevels = roundsChannelLevels
  }

  func request(method: String, params: Data?) throws -> Data {
    let encoder = JSONEncoder()
    switch method {
    case "getApplicationInfo":
      applicationInfoRequestCount += 1
      return try encoder.encode(
        WaveLinkApplicationInfo(
          interfaceRevision: interfaceRevision,
          appID: applicationID,
          name: "Wave Link 3"
        )
      )
    case "getChannels":
      channelRequestCount += 1
      return try encoder.encode(WaveLinkChannelsResponse(channels: channels))
    case "addToChannel":
      let request = try JSONDecoder().decode(AddRequest.self, from: try #require(params))
      addRequests.append(request)
      let sourceIndex = channels.firstIndex { channel in
        channel.apps.contains { $0.id == request.appID }
      }
      for index in channels.indices {
        channels[index].apps.removeAll(where: { $0.id == request.appID })
      }
      if let sourceIndex, let sourceMixesAfterAdd {
        channels[sourceIndex].mixes = sourceMixesAfterAdd
      }
      guard let index = channels.firstIndex(where: { $0.id == request.channelID }) else {
        throw WaveLinkControlBridgeError.protocolViolation("Unknown channel")
      }
      channels[index].apps.append(.init(id: request.appID))
      if let mixesAfterAdd { channels[index].mixes = mixesAfterAdd }
      return Data("{}".utf8)
    case "setChannel":
      let request = try JSONDecoder().decode(SetRequest.self, from: try #require(params))
      setRequests.append(request)
      guard let index = channels.firstIndex(where: { $0.id == request.id }) else {
        throw WaveLinkControlBridgeError.protocolViolation("Unknown channel")
      }
      channels[index].level = roundsChannelLevels ? (request.level * 100).rounded() / 100 : request.level
      channels[index].isMuted = request.isMuted
      return Data("{}".utf8)
    default:
      throw WaveLinkControlBridgeError.protocolViolation("Unexpected method \(method)")
    }
  }
}

@Test func waveLinkBridgeRefusesToRelocateAnAppForAutomation() async throws {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "shared",
        name: "Voice Apps",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.tinyspeck.slackmacgap")],
        mixes: [.init(id: "personal", level: 1, isMuted: false)]
      ),
      .init(
        id: "empty", name: "Aux 1", type: "Software", level: 1, isMuted: false, apps: [],
        mixes: [.init(id: "personal", level: 1, isMuted: false)]
      ),
    ]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.relocationNotPermitted("us.zoom.xos")) {
    try await bridge.apply(
      bundleIdentifier: "us.zoom.xos",
      volume: 0.5,
      isMuted: true,
      allowsChannelRelocation: false
    )
  }
  #expect(await rpc.addRequests.isEmpty)
  #expect(await rpc.setRequests.isEmpty)
  #expect(await bridge.currentStatus().phase == .failed)

  // A user gesture may move it, and the confirmation says so.
  let confirmation = try await bridge.apply(
    bundleIdentifier: "us.zoom.xos",
    volume: 0.5,
    isMuted: true,
    allowsChannelRelocation: true
  )
  #expect(confirmation.relocated)
  #expect(confirmation.channelID == "empty")
}

@Test func waveLinkBridgeRecordsStatusFromAReadOnlyInspection() async throws {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(id: "music", name: "Music", type: "Software", level: 0.8, isMuted: false, apps: [.init(id: "com.spotify.client")]),
      .init(
        id: "aux", name: "Aux 1", type: "Software", level: 1, isMuted: false, apps: [],
        mixes: [.init(id: "personal", level: 1, isMuted: false)]
      ),
      .init(id: "mic", name: "Wave:3", type: "Hardware", level: 1, isMuted: false, apps: []),
    ]
  )
  let bridge = WaveLinkControlBridge(
    request: { method, params in
      try await rpc.request(method: method, params: params)
    },
    describeConnection: {
      WaveLinkConnectionDescription(endpoint: "127.0.0.1:53832", processIdentifier: 1_366)
    }
  )

  #expect(await bridge.currentStatus().phase == .idle)
  let status = await bridge.inspect()
  #expect(status.phase == .connected)
  #expect(status.endpoint == "127.0.0.1:53832")
  #expect(status.processIdentifier == 1_366)
  #expect(status.applicationName == "Wave Link 3")
  #expect(status.interfaceRevision == 1)
  #expect(status.softwareChannelCount == 2)
  #expect(status.freeSoftwareChannelCount == 1)
  #expect(status.channels.map(\.name) == ["Music", "Aux 1", "Wave:3"])
  #expect(status.summaryLine.contains("2 software channels, 1 free"))
  // Inspection never mutates.
  #expect(await rpc.addRequests.isEmpty)
  #expect(await rpc.setRequests.isEmpty)

  let failing = WaveLinkControlBridge(request: { _, _ in
    throw WaveLinkControlBridgeError.unavailable("Wave Link 3 is not running.")
  })
  let failure = await failing.inspect()
  #expect(failure.phase == .failed)
  #expect(failure.lastError?.contains("not running") == true)
}

@Test func waveLinkBridgeDoesNotMoveAnAppToAnUnroutedEmptyChannel() async throws {
  let channels = try JSONDecoder().decode(
    WaveLinkChannelsResponse.self,
    from: Data(
      #"{"channels":[{"id":"shared","name":"Voice Apps","type":"Software","level":1,"isMuted":false,"apps":[{"id":"us.zoom.xos"},{"id":"com.example.chat"}],"mixes":[{"id":"personal","level":1,"isMuted":false}]},{"id":"empty","name":"Unrouted","type":"Software","level":1,"isMuted":false,"apps":[],"mixes":[]}]}"#.utf8
    )
  ).channels
  let rpc = WaveLinkRPCStub(channels: channels)
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.addRequests.isEmpty)
  #expect(await rpc.setRequests.isEmpty)
}

@Test func waveLinkBridgeExplainsADedicatedChannelWithoutAMix() async throws {
  let channel = try JSONDecoder().decode(
    WaveLinkChannel.self,
    from: Data(
      #"{"id":"zoom","name":"Zoom","type":"Software","level":1,"isMuted":false,"apps":[{"id":"us.zoom.xos"}],"mixes":[]}"#.utf8
    )
  )
  let rpc = WaveLinkRPCStub(channels: [channel])
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.setRequests.isEmpty)
}

@Test func waveLinkDiagnosticsAcceptAFullSetOfDedicatedChannels() {
  let channel = WaveLinkChannel(
    id: "zoom", name: "Zoom", type: "Software", level: 0.5,
    isMuted: false, apps: [.init(id: "us.zoom.xos")], mixes: [.init(id: "personal")]
  )
  let status = WaveLinkBridgeStatus(phase: .connected, channels: [channel.statusSummary])
  #expect(WorkspaceAudioControlBackend.diagnosticsStatus(for: status) == .passed)
}

@Test func waveLinkDiagnosticsExplainAChannelWithoutAMix() {
  let channel = WaveLinkChannel(
    id: "zoom", name: "Zoom", type: "Software", level: 0.5,
    isMuted: false, apps: [.init(id: "us.zoom.xos")], mixes: []
  )
  let status = WaveLinkBridgeStatus(phase: .connected, channels: [channel.statusSummary])
  #expect(WorkspaceAudioControlBackend.diagnosticsStatus(for: status) == .warning)
  #expect(WorkspaceAudioControlBackend.diagnosticsDetail(for: status).contains("not added to a mix"))
  #expect(status.freeSoftwareChannelCount == 0)
}

@Test func waveLinkDiagnosticsIgnoreAnEmptyUnroutedChannel() {
  let occupied = WaveLinkChannel(
    id: "zoom", name: "Zoom", type: "Software", level: 0.5,
    isMuted: false, apps: [.init(id: "us.zoom.xos")],
    mixes: [.init(id: "personal", level: 1, isMuted: false)]
  )
  let unused = WaveLinkChannel(
    id: "unused", name: "Unused", type: "Software", level: 1,
    isMuted: false, apps: [], mixes: []
  )
  let status = WaveLinkBridgeStatus(
    phase: .connected,
    channels: [occupied.statusSummary, unused.statusSummary]
  )

  #expect(WorkspaceAudioControlBackend.diagnosticsStatus(for: status) == .passed)
  #expect(!WorkspaceAudioControlBackend.diagnosticsDetail(for: status).contains("not added to a mix"))
  #expect(status.freeSoftwareChannelCount == 0)
}

@Test func waveLinkStatusDoesNotReportIncompleteMixMetadataAsFree() {
  let incomplete = WaveLinkChannel(
    id: "empty", name: "Empty", type: "Software", level: 1,
    isMuted: false, apps: [], mixes: [.init(id: "personal")]
  )
  let status = WaveLinkBridgeStatus(
    phase: .connected,
    channels: [incomplete.statusSummary]
  )

  #expect(status.freeSoftwareChannelCount == 0)
  #expect(status.summaryLine.contains("0 free"))
}

@Test func waveLinkStatusDecodesAChannelSummaryWithoutRelocationReadiness() throws {
  let status = try JSONDecoder().decode(
    WaveLinkBridgeStatus.self,
    from: Data(
      #"{"phase":"connected","channels":[{"id":"empty","name":"Empty","isSoftware":true,"appIdentifiers":[],"level":1,"isMuted":false,"mixCount":1}],"updatedAt":0}"#.utf8
    )
  )

  #expect(status.channels.first?.isRelocationReady == nil)
  #expect(status.freeSoftwareChannelCount == 0)
}

@Test(arguments: ["differentMix", "differentLevel", "differentMute", "missingSource", "missingTarget", "missingLevel", "missingMute", "duplicateMix"])
func waveLinkBridgeRejectsRelocationThatCannotPreserveMixSettings(_ scenario: String) async throws {
  let originalMix: [String: Any] = ["id": "personal", "level": 0.75, "isMuted": false]
  var targetMix = originalMix
  switch scenario {
  case "differentMix": targetMix["id"] = "stream"
  case "differentLevel": targetMix["level"] = 0
  case "differentMute": targetMix["isMuted"] = true
  case "missingLevel": targetMix.removeValue(forKey: "level")
  case "missingMute": targetMix.removeValue(forKey: "isMuted")
  default: break
  }
  var source: [String: Any] = [
    "id": "shared", "name": "Voice Apps", "type": "Software", "level": 1, "isMuted": false,
    "apps": [["id": "us.zoom.xos"], ["id": "com.example.chat"]], "mixes": [originalMix],
  ]
  var destination: [String: Any] = [
    "id": "empty", "name": "Empty", "type": "Software", "level": 1, "isMuted": false,
    "apps": [], "mixes": scenario == "duplicateMix" ? [targetMix, targetMix] : [targetMix],
  ]
  if scenario == "missingSource" { source.removeValue(forKey: "mixes") }
  if scenario == "missingTarget" { destination.removeValue(forKey: "mixes") }
  let channels = try JSONDecoder().decode(
    [WaveLinkChannel].self,
    from: JSONSerialization.data(withJSONObject: [source, destination])
  )
  let rpc = WaveLinkRPCStub(channels: channels)
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.addRequests.isEmpty)
  #expect(await rpc.setRequests.isEmpty)
}

@Test func waveLinkBridgePreservesMultipleMixesRegardlessOfTheirOrder() async throws {
  let personal = WaveLinkChannelMix(id: "personal", level: 0.8, isMuted: false)
  let stream = WaveLinkChannelMix(id: "stream", level: 0.5, isMuted: true)
  let rpc = WaveLinkRPCStub(channels: [
    .init(
      id: "shared", name: "Voice Apps", type: "Software", level: 1, isMuted: false,
      apps: [.init(id: "us.zoom.xos"), .init(id: "com.example.chat")], mixes: [personal, stream]
    ),
    .init(
      id: "empty", name: "Empty", type: "Software", level: 1, isMuted: false,
      apps: [], mixes: [stream, personal]
    ),
  ])
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })
  let result = try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
  #expect(result.relocated)
  #expect(result.channelID == "empty")
  #expect(await rpc.addRequests.count == 1)
  #expect(await rpc.setRequests.count == 1)
}

@Test func waveLinkBridgeStopsIfMixSettingsChangeDuringRelocation() async throws {
  let personal = WaveLinkChannelMix(id: "personal", level: 1, isMuted: false)
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "shared", name: "Voice Apps", type: "Software", level: 1, isMuted: false,
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.example.chat")], mixes: [personal]
      ),
      .init(
        id: "empty", name: "Empty", type: "Software", level: 1, isMuted: false,
        apps: [], mixes: [personal]
      ),
    ],
    mixesAfterAdd: [.init(id: "stream", level: 1, isMuted: false)]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })
  do {
    _ = try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
    Issue.record("A changed mix must not be confirmed as a successful app control.")
  } catch {
    guard case .readBackMismatch = error as? WaveLinkControlBridgeError else {
      Issue.record("Expected a read-back failure, received \(error).")
      return
    }
  }
  #expect(await rpc.addRequests.count == 1)
  #expect(await rpc.setRequests.isEmpty)
}

@Test func waveLinkBridgeStopsIfSourceMixSettingsChangeDuringRelocation() async throws {
  let personal = WaveLinkChannelMix(id: "personal", level: 1, isMuted: false)
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "shared", name: "Voice Apps", type: "Software", level: 1, isMuted: false,
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.example.chat")], mixes: [personal]
      ),
      .init(
        id: "empty", name: "Empty", type: "Software", level: 1, isMuted: false,
        apps: [], mixes: [personal]
      ),
    ],
    sourceMixesAfterAdd: [.init(id: "stream", level: 1, isMuted: false)]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.addRequests.count == 1)
  #expect(await rpc.setRequests.isEmpty)
}

@Test func waveLinkBridgeUsesWholePercentLevelsForFractionalSliderValues() async throws {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "zoom", name: "Zoom", type: "Software", level: 1, isMuted: false,
        apps: [.init(id: "us.zoom.xos")]
      )
    ],
    roundsChannelLevels: true
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })
  let result = try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.18112664, isMuted: false)
  #expect(result.appliedVolume == 0.18)
  #expect(await rpc.setRequests.last?.level == 0.18)
}
