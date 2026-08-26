import Foundation
import Testing

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
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.tinyspeck.slackmacgap")]
      ),
      .init(
        id: "empty",
        name: "Aux 1",
        type: "Software",
        level: 1,
        isMuted: false,
        apps: []
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
        apps: [.init(id: "us.zoom.xos"), .init(id: "com.tinyspeck.slackmacgap")]
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
  private(set) var applicationInfoRequestCount = 0
  private(set) var addRequests: [AddRequest] = []
  private(set) var setRequests: [SetRequest] = []
  private(set) var channelRequestCount = 0

  // Wave Link 3.0-3.2 report interfaceRevision 1, so the stub defaults to the
  // value real installs answer with.
  init(channels: [WaveLinkChannel], applicationID: String = "EWL", interfaceRevision: Int = 1) {
    self.channels = channels
    self.applicationID = applicationID
    self.interfaceRevision = interfaceRevision
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
      for index in channels.indices {
        channels[index].apps.removeAll(where: { $0.id == request.appID })
      }
      guard let index = channels.firstIndex(where: { $0.id == request.channelID }) else {
        throw WaveLinkControlBridgeError.protocolViolation("Unknown channel")
      }
      channels[index].apps.append(.init(id: request.appID))
      return Data("{}".utf8)
    case "setChannel":
      let request = try JSONDecoder().decode(SetRequest.self, from: try #require(params))
      setRequests.append(request)
      guard let index = channels.firstIndex(where: { $0.id == request.id }) else {
        throw WaveLinkControlBridgeError.protocolViolation("Unknown channel")
      }
      channels[index].level = request.level
      channels[index].isMuted = request.isMuted
      return Data("{}".utf8)
    default:
      throw WaveLinkControlBridgeError.protocolViolation("Unexpected method \(method)")
    }
  }
}
