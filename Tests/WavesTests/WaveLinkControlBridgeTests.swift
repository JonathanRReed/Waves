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

@Test(arguments: [-0.1 as Float, 1.1 as Float])
func waveLinkChannelInitializerPreservesRawFiniteLevel(_ level: Float) {
  let channel = WaveLinkChannel(
    id: "channel-browser", name: "Browser", type: "Software", level: level,
    isMuted: false, apps: [.init(id: "com.example.browser")])
  #expect(channel.level == level)
}

@Test(arguments: ["NaN", "Infinity", "-Infinity", "-0.1", "1.1"])
func waveLinkChannelDecodeFlagsInvalidLevelsWithoutFailingTheList(_ value: String) throws {
  // One channel with an unexpected level must not make the whole channel list
  // undecodable. It is flagged so it can never confirm a change.
  let decoder = JSONDecoder()
  decoder.nonConformingFloatDecodingStrategy = .convertFromString(
    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
  let literal = Float(value)?.isFinite == true ? value : "\"\(value)\""
  let data = Data("{\"id\":\"channel-browser\",\"level\":\(literal),\"isMuted\":false}".utf8)
  let channel = try decoder.decode(WaveLinkChannel.self, from: data)
  #expect(!channel.reportsValidState)
  #expect(channel.level.isFinite)
}

@Test(arguments: [0 as Float, 0.35 as Float, 1 as Float])
func waveLinkChannelDecodePreservesValidLevels(_ level: Float) throws {
  let data = Data("{\"id\":\"channel-browser\",\"level\":\(level)}".utf8)
  let channel = try JSONDecoder().decode(WaveLinkChannel.self, from: data)
  #expect(channel.level == level)
}

@Test(arguments: [
  #"{"id":"hardware","type":"Hardware"}"#,
  #"{"id":"hardware","type":"Hardware","level":null,"isMuted":null}"#,
  #"{"id":"unknown"}"#,
])
func waveLinkChannelDecodeRetainsDefaultForUnreportedHardwareLevel(_ json: String) throws {
  let channel = try JSONDecoder().decode(WaveLinkChannel.self, from: Data(json.utf8))
  #expect(channel.level == 1)
  #expect(!channel.isMuted)
}

@Test(arguments: [
  #"{"id":"browser","type":"Software","isMuted":false}"#,
  #"{"id":"browser","type":"software","level":null,"isMuted":false}"#,
])
func waveLinkChannelDecodeFlagsAnUnreportedSoftwareLevel(_ json: String) throws {
  let channel = try JSONDecoder().decode(WaveLinkChannel.self, from: Data(json.utf8))
  #expect(!channel.reportsValidState)
}

@Test(arguments: [
  #"{"id":"browser","type":"Software","level":0.5}"#,
  #"{"id":"browser","type":"software","level":0.5,"isMuted":null}"#,
])
func waveLinkChannelDecodeFlagsAnUnreportedSoftwareMute(_ json: String) throws {
  let channel = try JSONDecoder().decode(WaveLinkChannel.self, from: Data(json.utf8))
  #expect(!channel.reportsValidState)
}

@Test func waveLinkChannelDecodeAcceptsAFullyReportedChannel() throws {
  let json = #"{"id":"browser","type":"Software","level":0.35,"isMuted":true}"#
  let channel = try JSONDecoder().decode(WaveLinkChannel.self, from: Data(json.utf8))
  #expect(channel.reportsValidState)
  #expect(channel.level == 0.35)
  #expect(channel.isMuted)
}

@Test func waveLinkBridgeControlsAnAppWhenOtherChannelsReportUnexpectedLevels() async throws {
  // Wave Link returns every channel in one list. A hardware channel or another
  // app's channel with a level outside 0...1 must not stop Waves controlling
  // the app whose own channel reports a valid state.
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(id: "mic", name: "Wave:3", type: "Hardware", level: 1.5, isMuted: false, apps: []),
      .init(
        id: "channel-music", name: "Music", type: "Software", level: 2,
        isMuted: false, apps: [.init(id: "com.example.music")]),
      .init(
        id: "channel-browser", name: "Browser", type: "Software", level: 1,
        isMuted: false, apps: [.init(id: "com.example.browser")]),
    ]
  )
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  let confirmation = try await bridge.apply(
    bundleIdentifier: "com.example.browser", volume: 0.5, isMuted: false)

  #expect(confirmation.appliedVolume == 0.5)
  #expect(await rpc.setRequests.map(\.id) == ["channel-browser"])
}

@Test(arguments: [(requested: 0 as Float, received: -0.1 as Float), (requested: 1 as Float, received: 2 as Float)])
func waveLinkBridgeRejectsOutOfRangeBoundaryReadback(testCase: (requested: Float, received: Float)) async {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "channel-browser", name: "Browser", type: "Software", level: 0.5,
        isMuted: false, apps: [.init(id: "com.example.browser")])
    ],
    readBackLevel: testCase.received
  )
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { _ in }
  )
  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(
      bundleIdentifier: "com.example.browser", volume: testCase.requested, isMuted: false)
  }
  #expect(await rpc.setRequests.count == 1)
  #expect(await bridge.currentStatus().phase == .failed)
}

@Test(arguments: ["omitted", "null"])
func waveLinkBridgeNeverConfirmsAnUnreportedFullScaleReadback(_ representation: String) async {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "channel-browser", name: "Browser", type: "Software", level: 0.5,
        isMuted: false, apps: [.init(id: "com.example.browser")])
    ],
    readBackLevelRepresentation: representation
  )
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { _ in }
  )
  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 1, isMuted: false)
  }
  #expect(await rpc.setRequests.count == 1)
  #expect(await bridge.currentStatus().phase == .failed)
}

@Test(arguments: ["omitted", "null"])
func waveLinkBridgeNeverConfirmsAnUnreportedUnmutedReadback(_ representation: String) async {
  let rpc = WaveLinkRPCStub(
    channels: [
      .init(
        id: "channel-browser", name: "Browser", type: "Software", level: 0.5,
        isMuted: true, apps: [.init(id: "com.example.browser")])
    ],
    readBackMuteRepresentation: representation
  )
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { _ in }
  )
  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.5, isMuted: false)
  }
  #expect(await rpc.setRequests.count == 1)
  #expect(await bridge.currentStatus().phase == .failed)
}

/// How the stub's channel level follows a `setChannel`, for the behavior
/// suspected on real hardware where large steps did not confirm.
enum WaveLinkLevelResponse: Sendable {
  /// The next read shows the new level.
  case immediate
  /// Reads show the old level until the given read, then the new one.
  case late(reads: Int)
  /// Reads move in equal steps from the old level to the new one, reaching it
  /// on the given read.
  case ramp(reads: Int)

  func level(from: Float, to: Float, afterReads reads: Int) -> Float {
    switch self {
    case .immediate:
      return to
    case .late(let settleRead):
      return reads >= settleRead ? to : from
    case .ramp(let settleRead):
      guard reads < settleRead else { return to }
      return from + (to - from) * Float(reads) / Float(settleRead)
    }
  }
}

/// Records the waits the bridge asks for instead of sleeping.
private final class RecordedSleeps: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Duration] = []
  var durations: [Duration] { lock.withLock { recorded } }
  func record(_ duration: Duration) { lock.withLock { recorded.append(duration) } }
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
  private let readBackLevel: Float?
  private let readBackLevelRepresentation: String?
  private let readBackMuteRepresentation: String?
  private let levelResponse: WaveLinkLevelResponse
  /// The level a channel shows once an app joins it, as if Wave Link reset it.
  private let levelAfterAdd: Float?
  /// The channel a `setChannel` is still taking effect on, as Wave Link might
  /// fade or apply it after answering.
  private var settling: (channelID: String, from: Float, to: Float, reads: Int)?
  private(set) var applicationInfoRequestCount = 0
  private(set) var addRequests: [AddRequest] = []
  private(set) var setRequests: [SetRequest] = []
  private(set) var channelRequestCount = 0
  /// Every mutating call in order, as "method:channel".
  private(set) var mutations: [String] = []

  // Wave Link 3.0-3.2 report interfaceRevision 1, so the stub defaults to the
  // value real installs answer with.
  init(
    channels: [WaveLinkChannel], applicationID: String = "EWL", interfaceRevision: Int = 1,
    mixesAfterAdd: [WaveLinkChannelMix]? = nil,
    sourceMixesAfterAdd: [WaveLinkChannelMix]? = nil,
    roundsChannelLevels: Bool = false,
    readBackLevel: Float? = nil,
    readBackLevelRepresentation: String? = nil,
    readBackMuteRepresentation: String? = nil,
    levelResponse: WaveLinkLevelResponse = .immediate,
    levelAfterAdd: Float? = nil
  ) {
    self.channels = channels
    self.applicationID = applicationID
    self.interfaceRevision = interfaceRevision
    self.mixesAfterAdd = mixesAfterAdd
    self.sourceMixesAfterAdd = sourceMixesAfterAdd
    self.roundsChannelLevels = roundsChannelLevels
    self.readBackLevel = readBackLevel
    self.readBackLevelRepresentation = readBackLevelRepresentation
    self.readBackMuteRepresentation = readBackMuteRepresentation
    self.levelResponse = levelResponse
    self.levelAfterAdd = levelAfterAdd
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
      if var settling, let index = channels.firstIndex(where: { $0.id == settling.channelID }) {
        settling.reads += 1
        self.settling = settling
        channels[index].level = levelResponse.level(from: settling.from, to: settling.to, afterReads: settling.reads)
      }
      let data = try encoder.encode(WaveLinkChannelsResponse(channels: channels))
      guard let updatedChannelID = setRequests.last?.id,
        readBackLevelRepresentation != nil || readBackMuteRepresentation != nil
      else { return data }
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      var channelObjects = try #require(object["channels"] as? [[String: Any]])
      let index = try #require(channelObjects.firstIndex { $0["id"] as? String == updatedChannelID })
      if let representation = readBackLevelRepresentation {
        if representation == "null" {
          channelObjects[index]["level"] = NSNull()
        } else {
          channelObjects[index].removeValue(forKey: "level")
        }
      }
      if let representation = readBackMuteRepresentation {
        if representation == "null" {
          channelObjects[index]["isMuted"] = NSNull()
        } else {
          channelObjects[index].removeValue(forKey: "isMuted")
        }
      }
      object["channels"] = channelObjects
      return try JSONSerialization.data(withJSONObject: object)
    case "addToChannel":
      let request = try JSONDecoder().decode(AddRequest.self, from: try #require(params))
      addRequests.append(request)
      mutations.append("addToChannel:\(request.channelID)")
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
      if let levelAfterAdd {
        channels[index].level = levelAfterAdd
        settling = nil
      }
      return Data("{}".utf8)
    case "setChannel":
      let request = try JSONDecoder().decode(SetRequest.self, from: try #require(params))
      setRequests.append(request)
      mutations.append("setChannel:\(request.id)")
      guard let index = channels.firstIndex(where: { $0.id == request.id }) else {
        throw WaveLinkControlBridgeError.protocolViolation("Unknown channel")
      }
      let target = readBackLevel ?? (roundsChannelLevels ? (request.level * 100).rounded() / 100 : request.level)
      settling = (request.id, channels[index].level, target, 0)
      channels[index].level = levelResponse.level(from: channels[index].level, to: target, afterReads: 0)
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
  #expect(await rpc.mutations == ["setChannel:empty", "addToChannel:empty", "setChannel:empty"])
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
  #expect(
    await rpc.addRequests == [
      .init(appID: "us.zoom.xos", channelID: "empty"),
      .init(appID: "us.zoom.xos", channelID: "shared"),
    ]
  )
  // Only the empty channel was prepared; the app's own level was never set.
  #expect(await rpc.setRequests.map(\.id) == ["empty"])
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
  #expect(
    await rpc.addRequests == [
      .init(appID: "us.zoom.xos", channelID: "empty"),
      .init(appID: "us.zoom.xos", channelID: "shared"),
    ]
  )
  // Only the empty channel was prepared; the app's own level was never set.
  #expect(await rpc.setRequests.map(\.id) == ["empty"])
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

// MARK: - Confirming a change Wave Link applies over time

private func browserChannel(level: Float = 1, isMuted: Bool = false) -> WaveLinkChannel {
  .init(
    id: "channel-browser", name: "Browser", type: "Software", level: level,
    isMuted: isMuted, apps: [.init(id: "com.example.browser")])
}

@Test(arguments: [WaveLinkLevelResponse.late(reads: 3), .ramp(reads: 4)])
func waveLinkBridgeConfirmsALargeStepThatWaveLinkReachesOverSeveralReads(
  _ response: WaveLinkLevelResponse
) async throws {
  // The owner's report: a jump from 100% to 10% did not take while small
  // steps did. A single immediate read-back sees the old or an intermediate
  // level when Wave Link applies the level after answering setChannel.
  let rpc = WaveLinkRPCStub(channels: [browserChannel(level: 1)], levelResponse: response)
  let sleeps = RecordedSleeps()
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { sleeps.record($0) }
  )

  let confirmation = try await bridge.apply(
    bundleIdentifier: "com.example.browser", volume: 0.1, isMuted: false)

  #expect(confirmation.appliedVolume == 0.1)
  #expect(await rpc.setRequests.count == 1)
  #expect(await bridge.currentStatus().phase == .connected)
  // It stops reading as soon as the requested level shows.
  let settleRead = if case .late(let reads) = response { reads } else { 4 }
  #expect(sleeps.durations == Array(WaveLinkControlBridge.confirmationDelays.prefix(settleRead - 1)))
}

@Test func waveLinkBridgeReportsTheLastLevelWaveLinkShowedWhenItNeverConfirms() async throws {
  let rpc = WaveLinkRPCStub(channels: [browserChannel(level: 1)], readBackLevel: 0.5)
  let sleeps = RecordedSleeps()
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { sleeps.record($0) }
  )

  await #expect(
    throws: WaveLinkControlBridgeError.unconfirmed(
      .readBackMismatch("Requested 0.1, muted true; received 0.5, muted true."),
      observed: WaveLinkChannelState(level: 0.5, isMuted: true)
    )
  ) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.1, isMuted: true)
  }
  // One immediate read plus one per wait, bounded well under a second.
  #expect(sleeps.durations == WaveLinkControlBridge.confirmationDelays)
  #expect(sleeps.durations.reduce(.zero, +) == .milliseconds(600))
  #expect(await rpc.channelRequestCount == 2 + WaveLinkControlBridge.confirmationDelays.count)
  #expect(await rpc.setRequests.count == 1)
  #expect(await bridge.currentStatus().phase == .failed)
}

@Test func waveLinkBridgeKeepsWhatWaveLinkShowedWhenItsWaitIsCancelled() async throws {
  let rpc = WaveLinkRPCStub(channels: [browserChannel(level: 0.2)], readBackLevel: 0.55)
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    // A newer edit cancels the task while it waits for the next read.
    sleep: { _ in throw CancellationError() }
  )

  await #expect(
    throws: WaveLinkControlBridgeError.unconfirmed(
      .readBackMismatch("A newer change replaced this one before Wave Link confirmed it."),
      observed: WaveLinkChannelState(level: 0.55, isMuted: false)
    )
  ) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 1, isMuted: false)
  }
  #expect(await rpc.setRequests.count == 1)
}

@Test func waveLinkBridgeConfirmsAReadBackInTheSameWholePercent() async throws {
  // Waves sends whole percents, and Wave Link stores whole percents. A value
  // it reports a fraction of a percent away names the same level.
  let rpc = WaveLinkRPCStub(channels: [browserChannel(level: 1)], readBackLevel: 0.354)
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { _ in }
  )

  let confirmation = try await bridge.apply(
    bundleIdentifier: "com.example.browser", volume: 0.35, isMuted: false)

  #expect(confirmation.appliedVolume == 0.354)
  #expect(await rpc.channelRequestCount == 2)
}

@Test func waveLinkBridgeStopsWaitingForConfirmationOnceANewerChangeReplacesIt() async throws {
  let rpc = WaveLinkRPCStub(channels: [browserChannel(level: 1)], levelResponse: .late(reads: 5))
  let sleeps = RecordedSleeps()
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { sleeps.record($0) }
  )

  await #expect(
    throws: WaveLinkControlBridgeError.unconfirmed(
      .readBackMismatch("A newer change replaced this one before Wave Link confirmed it."),
      observed: WaveLinkChannelState(level: 1, isMuted: false)
    )
  ) {
    try await bridge.apply(
      bundleIdentifier: "com.example.browser", volume: 0.1, isMuted: false,
      allowsChannelRelocation: true, isCurrent: { false })
  }
  #expect(sleeps.durations.isEmpty)
  #expect(await rpc.channelRequestCount == 2)
}

@Test func waveLinkBridgeReportsAFailedSetAsUnconfirmed() async throws {
  // A setChannel that times out may still have reached Wave Link.
  let rpc = WaveLinkRPCStub(channels: [browserChannel(level: 1)])
  let bridge = WaveLinkControlBridge(
    request: { method, params in
      if method == "setChannel" {
        throw WaveLinkControlBridgeError.unavailable("Wave Link did not answer within the request time limit.")
      }
      return try await rpc.request(method: method, params: params)
    },
    sleep: { _ in }
  )

  await #expect(
    throws: WaveLinkControlBridgeError.unconfirmed(
      .unavailable("Wave Link did not answer within the request time limit."), observed: nil)
  ) {
    try await bridge.apply(bundleIdentifier: "com.example.browser", volume: 0.1, isMuted: false)
  }
}

// MARK: - Reporting channels without a valid state

@Test func waveLinkConnectionTestFlagsASoftwareChannelWithoutAValidState() async throws {
  // A missing level decodes as placeholder 1.00, unmuted. The connection test
  // must not show that as a healthy channel.
  let listing = Data(
    #"{"channels":[{"id":"browser","name":"Browser","type":"Software","isMuted":false,"apps":[{"id":"com.example.browser"}],"mixes":[{"id":"personal","level":1,"isMuted":false}]},{"id":"mic","name":"Wave:3","type":"Hardware"}]}"#.utf8
  )
  let rpc = WaveLinkRPCStub(channels: [])
  // Served as Wave Link sent it: the stub re-encodes channels with their
  // placeholder values, which would hide the missing level.
  let bridge = WaveLinkControlBridge(request: { method, params in
    method == "getChannels" ? listing : try await rpc.request(method: method, params: params)
  })

  let status = await bridge.inspect()

  #expect(status.phase == .connected)
  #expect(status.channels.map(\.reportsValidState) == [false, false])
  // The hardware channel's omitted level is normal and is not counted.
  #expect(status.softwareChannelsWithoutValidStateCount == 1)
  #expect(status.summaryLine.contains("1 did not report a valid level and mute"))
  #expect(WorkspaceAudioControlBackend.diagnosticsStatus(for: status) == .warning)
  #expect(
    WorkspaceAudioControlBackend.diagnosticsDetail(for: status)
      .contains("did not report a valid level and mute for a software channel"))

  let export = DiagnosticsExportFormatter.format(
    metadata: DiagnosticsMetadata(bundleInfo: [:], operatingSystemVersion: "Version 27.0"),
    captureAuthorization: nil,
    session: .empty,
    apps: [],
    availableOutputDeviceCount: 0,
    diagnostics: nil,
    waveLinkBridge: status,
    persistenceFailureCount: 0,
    lastPersistenceError: nil,
    shutdownResult: nil
  )
  #expect(export.contains("Browser · software · level and mute not validly reported"))
  #expect(!export.contains("Browser · software · level 1.00"))
}

@Test func waveLinkStatusDecodesAChannelSummaryWithoutAValidStateFlag() throws {
  let status = try JSONDecoder().decode(
    WaveLinkBridgeStatus.self,
    from: Data(
      #"{"phase":"connected","channels":[{"id":"zoom","name":"Zoom","isSoftware":true,"appIdentifiers":["us.zoom.xos"],"level":0.5,"isMuted":false,"mixCount":1}],"updatedAt":0}"#.utf8
    )
  )

  #expect(status.channels.first?.reportsValidState == nil)
  #expect(status.softwareChannelsWithoutValidStateCount == 0)
  #expect(WorkspaceAudioControlBackend.diagnosticsStatus(for: status) == .passed)
}

// MARK: - Undoing a relocation that does not complete

private func sharedAndEmptyChannels() -> [WaveLinkChannel] {
  let personal = WaveLinkChannelMix(id: "personal", level: 1, isMuted: false)
  return [
    .init(
      id: "shared", name: "Voice Apps", type: "Software", level: 1, isMuted: false,
      apps: [.init(id: "us.zoom.xos"), .init(id: "com.example.chat")], mixes: [personal]
    ),
    .init(id: "empty", name: "Aux 1", type: "Software", level: 1, isMuted: false, apps: [], mixes: [personal]),
  ]
}

private final class CallCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int {
    lock.withLock {
      count += 1; return count
    }
  }
}

/// Fails the given call of one method, counting from 1, and passes every
/// other call to the stub.
private func failing(
  _ method: String,
  call failingCall: Int,
  with error: WaveLinkControlBridgeError,
  _ rpc: WaveLinkRPCStub
) -> WaveLinkControlBridge.Request {
  let calls = CallCount()
  return { requested, params in
    if requested == method, calls.next() == failingCall { throw error }
    return try await rpc.request(method: requested, params: params)
  }
}

@Test func waveLinkBridgePreparesTheEmptyChannelBeforeMovingAnAppIntoIt() async throws {
  // A muted app must never play unmuted at the empty channel's old level
  // between the move and the level change.
  let rpc = WaveLinkRPCStub(channels: sharedAndEmptyChannels())
  let bridge = WaveLinkControlBridge(request: { method, params in
    try await rpc.request(method: method, params: params)
  })

  let confirmation = try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.2, isMuted: true)

  #expect(confirmation.relocated)
  #expect(await rpc.mutations == ["setChannel:empty", "addToChannel:empty", "setChannel:empty"])
  #expect(await rpc.setRequests.first == .init(id: "empty", level: 0.2, isMuted: true))
}

@Test func waveLinkBridgeRefusesToMoveAnAppWhenTheEmptyChannelCannotBePrepared() async throws {
  let rpc = WaveLinkRPCStub(channels: sharedAndEmptyChannels())
  let bridge = WaveLinkControlBridge(
    request: failing("setChannel", call: 1, with: .unavailable("setChannel: Invalid params"), rpc)
  )

  // Moving first would let the app play on the empty channel at its old level,
  // unmuted. Nothing has changed, so this is not an unconfirmed change.
  await #expect(
    throws: WaveLinkControlBridgeError.readBackMismatch(
      "Wave Link did not confirm the level and mute for Aux 1 before the move, so the app was left on its current channel."
    )
  ) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.2, isMuted: true)
  }
  #expect(await rpc.addRequests.isEmpty)
}

@Test func waveLinkBridgeRefusesToMoveAnAppOntoAChannelThatDoesNotShowTheRequestedLevel() async throws {
  let rpc = WaveLinkRPCStub(channels: sharedAndEmptyChannels(), readBackLevel: 0.5)
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { _ in }
  )

  // The empty channel never shows the requested level, so the app is not
  // moved onto it at all.
  await #expect(
    throws: WaveLinkControlBridgeError.readBackMismatch(
      "Wave Link did not confirm the level and mute for Aux 1 before the move, so the app was left on its current channel."
    )
  ) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.2, isMuted: false)
  }
  #expect(await rpc.addRequests.isEmpty)
}

@Test func waveLinkBridgeMovesAnAppBackWhenTheMoveCannotBeReadBack() async throws {
  let rpc = WaveLinkRPCStub(channels: sharedAndEmptyChannels())
  // The first listing finds the channels and the second confirms the empty
  // channel is ready; the third, right after the move, fails.
  let bridge = WaveLinkControlBridge(
    request: failing("getChannels", call: 3, with: .unavailable("getChannels: timed out"), rpc)
  )

  await #expect(throws: WaveLinkControlBridgeError.unavailable("getChannels: timed out")) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 0.2, isMuted: false)
  }
  #expect(
    await rpc.addRequests == [
      .init(appID: "us.zoom.xos", channelID: "empty"),
      .init(appID: "us.zoom.xos", channelID: "shared"),
    ]
  )
}

@Test func waveLinkBridgeReportsAnUnconfirmedChangeWhenItCannotMoveAnAppBack() async throws {
  // The empty channel is ready before the move, then shows another level once
  // the app has joined it and never reaches the requested one.
  let rpc = WaveLinkRPCStub(
    channels: sharedAndEmptyChannels(), levelResponse: .late(reads: 100), levelAfterAdd: 0.5)
  let bridge = WaveLinkControlBridge(
    request: failing("addToChannel", call: 2, with: .unavailable("addToChannel: timed out"), rpc),
    sleep: { _ in }
  )

  // The app may still be on the new channel, so Waves must treat its level
  // as uncertain and show what Wave Link last reported.
  await #expect(
    throws: WaveLinkControlBridgeError.unconfirmed(
      .readBackMismatch("Requested 1.0, muted false; received 0.5, muted false."),
      observed: WaveLinkChannelState(level: 0.5, isMuted: false))
  ) {
    try await bridge.apply(bundleIdentifier: "us.zoom.xos", volume: 1, isMuted: false)
  }
}

@Test func waveLinkBridgeLeavesAMovedAppForTheNewerChangeThatReplacedIt() async throws {
  let rpc = WaveLinkRPCStub(
    channels: sharedAndEmptyChannels(), levelResponse: .late(reads: 5), levelAfterAdd: 0.5)
  let bridge = WaveLinkControlBridge(
    request: { method, params in try await rpc.request(method: method, params: params) },
    sleep: { _ in }
  )

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await bridge.apply(
      bundleIdentifier: "us.zoom.xos", volume: 1, isMuted: false,
      allowsChannelRelocation: true, isCurrent: { false })
  }
  // The newer change sets the app's new channel next; moving the app back
  // would only make it move again.
  #expect(await rpc.addRequests == [.init(appID: "us.zoom.xos", channelID: "empty")])
}
