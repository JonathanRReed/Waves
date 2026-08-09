import Darwin
import Foundation

public enum WavesControlProtocol {
  public static let version = 1
  public static let maximumLineBytes = 64 * 1024
  public static let ioTimeoutSeconds: TimeInterval = 5
}

public enum WavesControlJSONValue: Equatable, Sendable {
  case object([String: WavesControlJSONValue])
  case array([WavesControlJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
}

public typealias JSONValue = WavesControlJSONValue

public enum WavesCTLValidationError: Error, Equatable, Sendable {
  case usage(String)
}

public enum WavesCTLIOOperation: Equatable, Sendable {
  case read
  case write
}

public enum WavesCTLTransportError: Error, Equatable, Sendable {
  case socketCreationFailed(Int32)
  case socketConfigurationFailed(String)
  case socketPathTooLong(String)
  case connectionFailed(String)
  case timeout(WavesCTLIOOperation)
  case writeFailed(Int32)
  case readFailed(Int32)
  case unexpectedEOF
  case oversizedFrame
  case malformedJSON
  case unexpectedResponse
}

public enum WavesCTLCommand: Equatable, Sendable {
  case apps
  case icon(app: String)
  case volume(app: String, value: Double)
  case nudge(app: String, delta: Double)
  case mute(app: String, muted: Bool)
  case toggle(app: String)
  case watch
  case raw([String: WavesControlJSONValue])

  public static func parse(_ arguments: [String]) throws -> WavesCTLCommand {
    guard let command = arguments.first else {
      throw WavesCTLValidationError.usage(WavesCTLUsage.text)
    }

    switch command {
    case "apps":
      guard arguments.count == 1 else { throw WavesCTLValidationError.usage(WavesCTLUsage.text) }
      return .apps

    case "icon":
      guard arguments.count == 2 else { throw WavesCTLValidationError.usage("usage: wavesctl icon <app-id>") }
      return .icon(app: arguments[1])

    case "volume":
      guard arguments.count == 3 else {
        throw WavesCTLValidationError.usage("usage: wavesctl volume <app-id> <0..1>")
      }
      guard let value = Double(arguments[2]), value.isFinite, (0...1).contains(value) else {
        throw WavesCTLValidationError.usage("usage: wavesctl volume <app-id> <0..1>")
      }
      return .volume(app: arguments[1], value: value)

    case "nudge":
      guard arguments.count == 3 else {
        throw WavesCTLValidationError.usage(
          "usage: wavesctl nudge <app-id> <delta>   (e.g. -0.02, what one dial tick sends)")
      }
      guard let delta = Double(arguments[2]), delta.isFinite else {
        throw WavesCTLValidationError.usage(
          "usage: wavesctl nudge <app-id> <delta>   (e.g. -0.02, what one dial tick sends)")
      }
      return .nudge(app: arguments[1], delta: delta)

    case "mute":
      guard arguments.count == 2 else { throw WavesCTLValidationError.usage("usage: wavesctl mute <app-id>") }
      return .mute(app: arguments[1], muted: true)

    case "unmute":
      guard arguments.count == 2 else {
        throw WavesCTLValidationError.usage("usage: wavesctl unmute <app-id>")
      }
      return .mute(app: arguments[1], muted: false)

    case "toggle":
      guard arguments.count == 2 else {
        throw WavesCTLValidationError.usage("usage: wavesctl toggle <app-id>")
      }
      return .toggle(app: arguments[1])

    case "watch":
      guard arguments.count == 1 else { throw WavesCTLValidationError.usage("usage: wavesctl watch") }
      return .watch

    case "raw":
      guard arguments.count == 2 else {
        throw WavesCTLValidationError.usage("usage: wavesctl raw '{\"id\":1,\"cmd\":\"list-apps\"}'")
      }
      let object = try parseRawJSONObject(arguments[1])
      return .raw(object)

    default:
      throw WavesCTLValidationError.usage(WavesCTLUsage.text)
    }
  }

  public func requestObject(id: Int = 1) -> [String: WavesControlJSONValue] {
    switch self {
    case .apps:
      return ["id": .number(Double(id)), "cmd": .string("list-apps")]
    case .icon(let app):
      return ["id": .number(Double(id)), "cmd": .string("get-icon"), "app": .string(app)]
    case .volume(let app, let value):
      return [
        "id": .number(Double(id)), "cmd": .string("set-volume"), "app": .string(app),
        "volume": .number(value),
      ]
    case .nudge(let app, let delta):
      return [
        "id": .number(Double(id)), "cmd": .string("adjust-volume"), "app": .string(app),
        "delta": .number(delta),
      ]
    case .mute(let app, let muted):
      return [
        "id": .number(Double(id)), "cmd": .string("set-mute"), "app": .string(app),
        "muted": .bool(muted),
      ]
    case .toggle(let app):
      return ["id": .number(Double(id)), "cmd": .string("toggle-mute"), "app": .string(app)]
    case .watch:
      return ["id": .number(Double(id)), "cmd": .string("subscribe")]
    case .raw(let object):
      return object
    }
  }

  public func request(id: Int = 1) -> [String: WavesControlJSONValue] {
    requestObject(id: id)
  }

  private static func parseRawJSONObject(_ source: String) throws -> [String: WavesControlJSONValue] {
    guard let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    else {
      throw WavesCTLValidationError.usage("usage: wavesctl raw '{\"id\":1,\"cmd\":\"list-apps\"}'")
    }
    guard let dictionary = WavesControlJSONValue.makeJSONObject(object) else {
      throw WavesCTLValidationError.usage("usage: wavesctl raw '{\"id\":1,\"cmd\":\"list-apps\"}'")
    }
    guard !dictionary.isEmpty else {
      throw WavesCTLValidationError.usage("usage: wavesctl raw '{\"id\":1,\"cmd\":\"list-apps\"}'")
    }
    return dictionary
  }
}

public enum WavesCTLUsage {
  public static let text = """
    usage: wavesctl <command> [options]

    Commands:
      apps                       List the apps Waves knows about
      icon <app-id>              Base64 PNG icon for one app
      volume <app-id> <0..1>     Set an app's volume
      nudge  <app-id> <delta>    Change an app's volume by a delta (what a dial sends)
      mute   <app-id>            Mute an app
      unmute <app-id>            Unmute an app
      toggle <app-id>            Toggle an app's mute
      watch                      Subscribe and print state changes until interrupted
      raw '<json>'               Send one raw request line

    The socket path can be overridden with WAVES_CONTROL_SOCKET.

    If this cannot connect, check that Waves is running and that
    Settings > Shortcuts & Automation > "Allow external control" is on.
    """
}

public enum WavesControlWriteResult: Equatable, Sendable {
  case written(Int)
  case failed(Int32)
}

public enum WavesControlReadResult: Equatable, Sendable {
  case data(Data)
  case eof
  case failed(Int32)
}

public protocol WavesControlSocketSystem: Sendable {
  func openSocket() throws -> Int32
  func setNoSIGPIPE(_ fd: Int32) throws
  func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) throws
  func connect(_ fd: Int32, path: String) throws
  func write(_ fd: Int32, data: Data, offset: Int) -> WavesControlWriteResult
  func read(_ fd: Int32, maximumBytes: Int) -> WavesControlReadResult
  func close(_ fd: Int32)
}

public struct DarwinWavesControlSocketSystem: WavesControlSocketSystem {
  public init() {}

  public func openSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WavesCTLTransportError.socketCreationFailed(errno) }
    return fd
  }

  public func setNoSIGPIPE(_ fd: Int32) throws {
    var value: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
      throw WavesCTLTransportError.socketConfigurationFailed("SO_NOSIGPIPE")
    }
  }

  public func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) throws {
    var timeout = timeval(
      tv_sec: Int(seconds.rounded(.down)),
      tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1) * 1_000_000).rounded(.down))
    )
    guard
      setsockopt(
        fd,
        SOL_SOCKET,
        option,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
      ) == 0
    else {
      let name = option == SO_RCVTIMEO ? "SO_RCVTIMEO" : "SO_SNDTIMEO"
      throw WavesCTLTransportError.socketConfigurationFailed(name)
    }
  }

  public func connect(_ fd: Int32, path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < 104 else {
      throw WavesCTLTransportError.socketPathTooLong(path)
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      path.withCString { source in
        strncpy(
          UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
          source,
          103
        )
      }
    }

    let result = withUnsafeBytes(of: &address) { raw -> Int32 in
      guard let base = raw.baseAddress else { return -1 }
      return Darwin.connect(
        fd,
        base.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_un>.size)
      )
    }
    guard result == 0 else {
      throw WavesCTLTransportError.connectionFailed(path)
    }
  }

  public func write(_ fd: Int32, data: Data, offset: Int) -> WavesControlWriteResult {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return .written(0) }
      let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      if written >= 0 { return .written(written) }
      return .failed(errno)
    }
  }

  public func read(_ fd: Int32, maximumBytes: Int) -> WavesControlReadResult {
    var buffer = [UInt8](repeating: 0, count: maximumBytes)
    let count = Darwin.read(fd, &buffer, maximumBytes)
    if count > 0 {
      return .data(Data(buffer.prefix(count)))
    }
    if count == 0 { return .eof }
    return .failed(errno)
  }

  public func close(_ fd: Int32) {
    Darwin.close(fd)
  }
}

public final class WavesControlSocketClient {
  private let fd: Int32
  private let system: any WavesControlSocketSystem
  private var buffer = Data()

  public init(
    path: String,
    system: some WavesControlSocketSystem = DarwinWavesControlSocketSystem()
  ) throws {
    self.system = system
    let fd = try system.openSocket()
    self.fd = fd
    do {
      try system.setNoSIGPIPE(fd)
      try system.setTimeout(fd, option: SO_RCVTIMEO, seconds: WavesControlProtocol.ioTimeoutSeconds)
      try system.setTimeout(fd, option: SO_SNDTIMEO, seconds: WavesControlProtocol.ioTimeoutSeconds)
      try system.connect(fd, path: path)
    } catch {
      system.close(fd)
      throw error
    }
  }

  deinit {
    system.close(fd)
  }

  public func send(_ object: [String: WavesControlJSONValue]) throws {
    var payload = try encodeJSONObject(object)
    payload.append(0x0A)

    var offset = 0
    while offset < payload.count {
      switch system.write(fd, data: payload, offset: offset) {
      case .written(let count):
        guard count > 0 else { throw WavesCTLTransportError.writeFailed(EPIPE) }
        offset += count
      case .failed(let code):
        if code == EINTR { continue }
        if code == EAGAIN || code == EWOULDBLOCK || code == ETIMEDOUT {
          throw WavesCTLTransportError.timeout(.write)
        }
        throw WavesCTLTransportError.writeFailed(code)
      }
    }
  }

  public func receive() throws -> [String: WavesControlJSONValue] {
    while true {
      if let object = try popBufferedLine() { return object }

      switch system.read(fd, maximumBytes: 8192) {
      case .data(let data):
        buffer.append(data)
        if buffer.firstIndex(of: 0x0A) == nil, buffer.count > WavesControlProtocol.maximumLineBytes {
          throw WavesCTLTransportError.oversizedFrame
        }
      case .eof:
        throw WavesCTLTransportError.unexpectedEOF
      case .failed(let code):
        if code == EINTR { continue }
        if code == EAGAIN || code == EWOULDBLOCK || code == ETIMEDOUT {
          throw WavesCTLTransportError.timeout(.read)
        }
        throw WavesCTLTransportError.readFailed(code)
      }
    }
  }

  public func request(_ object: [String: WavesControlJSONValue]) throws -> [String: WavesControlJSONValue] {
    try send(object)
    while true {
      let response = try receive()
      if response["event"] == nil { return response }
    }
  }

  private func popBufferedLine() throws -> [String: WavesControlJSONValue]? {
    guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }

    let line = buffer[..<newline]
    buffer.removeSubrange(...newline)

    guard line.count <= WavesControlProtocol.maximumLineBytes else {
      throw WavesCTLTransportError.oversizedFrame
    }

    var trimmed = Data(line)
    if trimmed.last == 0x0D { trimmed.removeLast() }
    if trimmed.isEmpty { return try popBufferedLine() }

    guard
      let object = try? JSONSerialization.jsonObject(with: trimmed),
      let dictionary = WavesControlJSONValue.makeJSONObject(object),
      isExpectedResponseShape(dictionary)
    else {
      if (try? JSONSerialization.jsonObject(with: trimmed)) != nil {
        throw WavesCTLTransportError.unexpectedResponse
      }
      throw WavesCTLTransportError.malformedJSON
    }

    return dictionary
  }

  private func isExpectedResponseShape(_ dictionary: [String: WavesControlJSONValue]) -> Bool {
    if dictionary.isEmpty { return false }
    if dictionary["ok"] != nil || dictionary["event"] != nil { return true }
    return false
  }
}

extension WavesControlJSONValue {
  fileprivate static func makeJSONObject(_ value: Any) -> [String: WavesControlJSONValue]? {
    guard let dictionary = make(value)?.privateObjectValue else { return nil }
    return dictionary
  }

  fileprivate var privateObjectValue: [String: WavesControlJSONValue]? {
    guard case .object(let object) = self else { return nil }
    return object
  }

  fileprivate static func make(_ value: Any) -> WavesControlJSONValue? {
    switch value {
    case let object as [String: Any]:
      var result: [String: WavesControlJSONValue] = [:]
      for key in object.keys.sorted() {
        guard let converted = make(object[key] as Any) else { return nil }
        result[key] = converted
      }
      return .object(result)
    case let array as [Any]:
      var result: [WavesControlJSONValue] = []
      result.reserveCapacity(array.count)
      for item in array {
        guard let converted = make(item) else { return nil }
        result.append(converted)
      }
      return .array(result)
    case let string as String:
      return .string(string)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return .bool(number.boolValue)
      }
      let value = number.doubleValue
      guard value.isFinite else { return nil }
      return .number(value)
    case _ as NSNull:
      return .null
    default:
      return nil
    }
  }
}

extension WavesControlJSONValue: CustomStringConvertible {
  public var description: String {
    switch self {
    case .object(let object):
      let items = object.keys.sorted().compactMap { key -> String? in
        guard let value = object[key] else { return nil }
        return "\"\(key)\": \(value.description)"
      }.joined(separator: ", ")
      return "{\(items)}"
    case .array(let array):
      return "[" + array.map(\.description).joined(separator: ", ") + "]"
    case .string(let string):
      return "\"" + string.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    case .number(let number):
      if number.rounded(.towardZero) == number {
        return String(Int64(number))
      }
      return String(number)
    case .bool(let flag):
      return flag ? "true" : "false"
    case .null:
      return "null"
    }
  }

  public var objectValue: [String: WavesControlJSONValue]? {
    guard case .object(let object) = self else { return nil }
    return object
  }

  public var arrayValue: [WavesControlJSONValue]? {
    guard case .array(let array) = self else { return nil }
    return array
  }

  public var stringValue: String? {
    guard case .string(let string) = self else { return nil }
    return string
  }

  public var numberValue: Double? {
    guard case .number(let number) = self else { return nil }
    return number
  }

  public var boolValue: Bool? {
    guard case .bool(let flag) = self else { return nil }
    return flag
  }
}

extension WavesCTLValidationError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .usage(let message):
      return message
    }
  }
}

extension WavesCTLTransportError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .socketCreationFailed:
      return "Could not create a control socket."
    case .socketConfigurationFailed(let option):
      return "Could not configure the control socket (\(option))."
    case .socketPathTooLong(let path):
      return "Socket path is too long: \(path)"
    case .connectionFailed(let path):
      return """
        Could not connect to Waves at \(path)

        Check that Waves is running, and that
        Settings > Shortcuts & Automation > "Allow external control" is turned on.
        """
    case .timeout(.write):
      return "Timed out writing to Waves."
    case .timeout(.read):
      return "Timed out waiting for Waves to reply."
    case .writeFailed(let code):
      return "Control write failed with errno \(code)."
    case .readFailed(let code):
      return "Control read failed with errno \(code)."
    case .unexpectedEOF:
      return "Waves closed the connection before a complete reply arrived."
    case .oversizedFrame:
      return "Waves sent an oversized control frame."
    case .malformedJSON:
      return "Waves sent malformed JSON."
    case .unexpectedResponse:
      return "Waves sent an unexpected response shape."
    }
  }
}

private func encodeJSONObject(_ object: [String: WavesControlJSONValue]) throws -> Data {
  var output = ""
  try appendJSON(.object(object), into: &output)
  return Data(output.utf8)
}

private func appendJSON(_ value: WavesControlJSONValue, into output: inout String) throws {
  switch value {
  case .object(let object):
    output.append("{")
    let keys = object.keys.sorted()
    for (index, key) in keys.enumerated() {
      if index > 0 { output.append(",") }
      try appendJSONString(key, into: &output)
      output.append(":")
      guard let nested = object[key] else { continue }
      try appendJSON(nested, into: &output)
    }
    output.append("}")

  case .array(let array):
    output.append("[")
    for (index, nested) in array.enumerated() {
      if index > 0 { output.append(",") }
      try appendJSON(nested, into: &output)
    }
    output.append("]")

  case .string(let string):
    try appendJSONString(string, into: &output)

  case .number(let number):
    if number.rounded(.towardZero) == number {
      output.append(String(Int64(number)))
    } else {
      output.append(String(number))
    }

  case .bool(let flag):
    output.append(flag ? "true" : "false")

  case .null:
    output.append("null")
  }
}

private func appendJSONString(_ value: String, into output: inout String) throws {
  let encoded = try JSONSerialization.data(withJSONObject: [value], options: [])
  let text = String(decoding: encoded, as: UTF8.self)
  output.append(contentsOf: text.dropFirst().dropLast())
}
