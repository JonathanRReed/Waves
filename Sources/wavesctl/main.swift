import Foundation
import WavesControlClient

private let socketPath =
  ProcessInfo.processInfo.environment["WAVES_CONTROL_SOCKET"]
  ?? NSHomeDirectory() + "/Library/Application Support/Waves/control.sock"

private let usage = WavesCTLUsage.text

private func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

private func describe(_ response: [String: JSONValue]) {
  guard response["ok"]?.boolValue == false else { return }
  fail(
    "error: \(response["error"]?.stringValue ?? "unknown")\n"
      + (response["message"]?.stringValue ?? ""))
}

private func percent(_ value: JSONValue?) -> Int {
  Int(((value?.numberValue ?? 0) * 100).rounded())
}

let command: WavesCTLCommand
do {
  command = try WavesCTLCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as WavesCTLValidationError {
  fail("\(error.description)\n\n\(usage)", code: 2)
} catch {
  fail("Invalid command.\n\n\(usage)", code: 2)
}

do {
  let client = try WavesControlSocketClient(path: socketPath)
  describe(
    try client.request([
      "id": .number(0), "cmd": .string("hello"), "client": .string("wavesctl"),
      "protocol": .number(1),
    ]))

  switch command {
  case .apps:
    let response = try client.request(command.request(id: 1))
    describe(response)
    let apps = response["apps"]?.arrayValue?.compactMap(\.objectValue) ?? []
    guard !apps.isEmpty else {
      print("Waves is not showing any apps right now.")
      exit(0)
    }
    let width = apps.compactMap { $0["id"]?.stringValue?.count }.max() ?? 0
    for app in apps {
      let id = app["id"]?.stringValue ?? "?"
      let name = app["name"]?.stringValue ?? "?"
      let flags = [
        app["muted"]?.boolValue == true ? "muted" : nil,
        app["live"]?.boolValue == true ? "live" : nil,
        app["managed"]?.boolValue == true ? "managed" : nil,
      ].compactMap { $0 }.joined(separator: " ")
      print(
        "\(id.padding(toLength: max(width, id.count), withPad: " ", startingAt: 0))  "
          + "\(String(format: "%3d", percent(app["volume"])))%  \(name)  \(flags)")
    }

  case .icon:
    let response = try client.request(command.request(id: 1))
    describe(response)
    print(response["icon"]?.stringValue ?? "(no icon)")

  case .volume(_, let requested):
    let response = try client.request(command.request(id: 1))
    describe(response)
    print("volume: \(response["volume"]?.numberValue ?? requested)")

  case .nudge:
    let response = try client.request(command.request(id: 1))
    describe(response)
    print("volume: \(response["volume"]?.numberValue ?? 0)")

  case .mute(_, _):
    let response = try client.request(command.request(id: 1))
    describe(response)
    print("muted: \(response["muted"]?.boolValue ?? false)")

  case .toggle:
    let response = try client.request(command.request(id: 1))
    describe(response)
    print("muted: \(response["muted"]?.boolValue ?? false)")

  case .watch:
    describe(try client.request(command.request(id: 1)))
    print("Watching Waves. Change something in the app, or with another wavesctl, to see pushes.")
    print("Ctrl-C to stop.")
    while true {
      let event = try client.receive()
      guard let name = event["event"]?.stringValue else { continue }
      if let changed = event["changed"]?.objectValue {
        let id = changed["id"]?.stringValue ?? "?"
        let muted = changed["muted"]?.boolValue == true
        print("\(name): \(id) \(percent(changed["volume"]))%\(muted ? " muted" : "")")
      } else {
        print(name)
      }
    }

  case .raw:
    let response = try client.request(command.request(id: 1))
    let ordered = response.keys.sorted().map { key in
      "  \"\(key)\": \(response[key]!.description)"
    }.joined(separator: ",\n")
    print("{\n\(ordered)\n}")
  }
} catch let error as WavesCTLTransportError {
  fail(error.description)
} catch {
  fail("Control request failed: \(error.localizedDescription)")
}
