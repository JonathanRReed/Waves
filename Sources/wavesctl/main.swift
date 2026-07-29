import Darwin
import Foundation

// A tiny client for Waves's control socket.
//
// This exists so the whole control surface is exercisable from a terminal, with
// no Stream Deck and no plugin. When something does not work, it answers the
// only question that matters first: is it Waves, or is it the client?

let socketPath = ProcessInfo.processInfo.environment["WAVES_CONTROL_SOCKET"]
  ?? NSHomeDirectory() + "/Library/Application Support/Waves/control.sock"

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

func usage() -> Never {
  let text = """
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
  Settings > Advanced > "Allow external control" is on.
  """
  print(text)
  exit(2)
}

// MARK: - Connection

final class ControlClient {
  private let fd: Int32
  private var buffer = Data()

  init(path: String) {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("Could not create a socket.") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < 104 else { fail("Socket path is too long: \(path)") }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      path.withCString { source in
        strncpy(
          UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
      }
    }

    // See ControlServer.start(): rebinding sockaddr_un to sockaddr traps on
    // current runtimes because their strides differ.
    let result = withUnsafeBytes(of: &address) { raw -> Int32 in
      guard let base = raw.baseAddress else { return -1 }
      return connect(
        fd,
        base.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_un>.size)
      )
    }
    guard result == 0 else {
      fail("""
        Could not connect to Waves at \(path)

        Check that Waves is running, and that
        Settings > Advanced > "Allow external control" is turned on.
        """)
    }
  }

  deinit { Darwin.close(fd) }

  func send(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else {
      fail("Could not encode the request.")
    }
    data.append(0x0A)
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count {
        let written = write(fd, base.advanced(by: offset), raw.count - offset)
        if written <= 0 { break }
        offset += written
      }
    }
  }

  /// Reads one complete line, or nil at EOF.
  func receive() -> [String: Any]? {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<newline])
        buffer = Data(buffer[buffer.index(after: newline)...])
        if line.isEmpty { continue }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
      }
      var chunk = [UInt8](repeating: 0, count: 8_192)
      let count = read(fd, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(contentsOf: chunk[0..<count])
    }
  }

  /// Sends a request and returns its response, skipping any pushes that arrive
  /// first (they are unsolicited and carry no id).
  @discardableResult
  func request(_ object: [String: Any]) -> [String: Any] {
    send(object)
    while let response = receive() {
      if response["event"] == nil { return response }
    }
    fail("Waves closed the connection.")
  }
}

func describe(_ response: [String: Any]) {
  if let ok = response["ok"] as? Bool, !ok {
    let error = response["error"] as? String ?? "unknown"
    let message = response["message"] as? String ?? ""
    fail("error: \(error)\n\(message)")
  }
}

// MARK: - Commands

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
arguments.removeFirst()

@MainActor
func requiredApp() -> String {
  guard let app = arguments.first else { fail("This command needs an app id. Try: wavesctl apps") }
  return app
}

let client = ControlClient(path: socketPath)
let hello = client.request(["id": 0, "cmd": "hello", "client": "wavesctl", "protocol": 1])
describe(hello)

switch command {
case "apps":
  let response = client.request(["id": 1, "cmd": "list-apps"])
  describe(response)
  let apps = response["apps"] as? [[String: Any]] ?? []
  guard !apps.isEmpty else {
    print("Waves is not showing any apps right now.")
    exit(0)
  }
  // Aligned so the ids are scannable — this list is meant to be read, then
  // copied from.
  let width = apps.compactMap { ($0["id"] as? String)?.count }.max() ?? 0
  for app in apps {
    let id = app["id"] as? String ?? "?"
    let name = app["name"] as? String ?? "?"
    let volume = (app["volume"] as? Double).map { Int(($0 * 100).rounded()) } ?? 0
    let muted = (app["muted"] as? Bool) == true
    let live = (app["live"] as? Bool) == true
    let managed = (app["managed"] as? Bool) == true
    let flags = [muted ? "muted" : nil, live ? "live" : nil, managed ? "managed" : nil]
      .compactMap { $0 }.joined(separator: " ")
    print("\(id.padding(toLength: max(width, id.count), withPad: " ", startingAt: 0))  \(String(format: "%3d", volume))%  \(name)  \(flags)")
  }

case "icon":
  let response = client.request(["id": 1, "cmd": "get-icon", "app": requiredApp()])
  describe(response)
  print(response["icon"] as? String ?? "(no icon)")

case "volume":
  let app = requiredApp()
  guard arguments.count >= 2, let value = Double(arguments[1]) else {
    fail("usage: wavesctl volume <app-id> <0..1>")
  }
  let response = client.request(["id": 1, "cmd": "set-volume", "app": app, "volume": value])
  describe(response)
  print("volume: \(response["volume"] as? Double ?? value)")

case "nudge":
  let app = requiredApp()
  guard arguments.count >= 2, let delta = Double(arguments[1]) else {
    fail("usage: wavesctl nudge <app-id> <delta>   (e.g. -0.02, what one dial tick sends)")
  }
  let response = client.request(["id": 1, "cmd": "adjust-volume", "app": app, "delta": delta])
  describe(response)
  print("volume: \(response["volume"] as? Double ?? 0)")

case "mute", "unmute":
  let response = client.request([
    "id": 1, "cmd": "set-mute", "app": requiredApp(), "muted": command == "mute",
  ])
  describe(response)
  print("muted: \(response["muted"] as? Bool ?? false)")

case "toggle":
  let response = client.request(["id": 1, "cmd": "toggle-mute", "app": requiredApp()])
  describe(response)
  print("muted: \(response["muted"] as? Bool ?? false)")

case "watch":
  describe(client.request(["id": 1, "cmd": "subscribe"]))
  print("Watching Waves. Change something in the app — or with another wavesctl — to see pushes.")
  print("Ctrl-C to stop.")
  while let event = client.receive() {
    guard let name = event["event"] as? String else { continue }
    if let changed = event["changed"] as? [String: Any] {
      let id = changed["id"] as? String ?? "?"
      let volume = (changed["volume"] as? Double).map { Int(($0 * 100).rounded()) } ?? 0
      let muted = (changed["muted"] as? Bool) == true
      print("\(name): \(id) \(volume)%\(muted ? " muted" : "")")
    } else {
      print(name)
    }
  }

case "raw":
  guard let line = arguments.first,
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
  else {
    fail("usage: wavesctl raw '{\"id\":1,\"cmd\":\"list-apps\"}'")
  }
  let response = client.request(object)
  if let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted]) {
    print(String(decoding: data, as: UTF8.self))
  }

default:
  usage()
}
