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
    WavesCTLTerminalText.sanitized(
      "error: \(response["error"]?.stringValue ?? "unknown")\n"
        + (response["message"]?.stringValue ?? "")))
}

/// Every line that carries daemon-supplied text goes through the sanitizer
/// before it reaches the terminal.
private func emit(_ line: String) {
  print(WavesCTLTerminalText.sanitized(line))
}

let command: WavesCTLCommand
do {
  command = try WavesCTLCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as WavesCTLValidationError {
  fail("\(error.description)\n\n\(usage)", code: 2)
} catch {
  fail("Invalid command.\n\n\(usage)", code: 2)
}

if command == .help {
  print(usage)
  exit(0)
}

do {
  let client = try WavesControlSocketClient(path: socketPath, ioTimeoutSeconds: command.ioTimeoutSeconds)
  let hello = try client.request([
    "id": .number(0), "cmd": .string("hello"), "client": .string("wavesctl"),
    "protocol": .number(1),
  ])
  describe(hello)
  if let serverCommand = command.serverCommand,
    let message = WavesControlCapabilities(hello: hello).unsupportedMessage(for: serverCommand)
  {
    fail(WavesCTLTerminalText.sanitized(message))
  }

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
      emit(
        "\(id.padding(toLength: max(width, id.count), withPad: " ", startingAt: 0))  "
          + "\(String(format: "%3d", WavesCTLDisplay.percentage(app["volume"])))%  \(name)  \(flags)")
    }

  case .icon:
    let response = try client.request(command.request(id: 1))
    describe(response)
    emit(response["icon"]?.stringValue ?? "(no icon)")

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

  case .boost(_, let requested):
    let response = try client.request(command.request(id: 1))
    describe(response)
    print("boost: \(response["boost"]?.numberValue ?? requested)x")

  case .profile:
    let response = try client.request(command.request(id: 1))
    let counts = response["profile"]?.objectValue
    if let counts {
      let parts = [
        ("applied", "applied"), ("partial", "levels only"), ("savedForLater", "saved for later"),
        ("skipped", "skipped"), ("failed", "failed"),
      ]
      .compactMap { key, label -> String? in
        guard let count = counts[key]?.numberValue, count > 0 else { return nil }
        return "\(Int(count)) \(label)"
      }
      emit("profile: \(counts["name"]?.stringValue ?? "?")\(parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")")")
    }
    describe(response)

  case .refresh:
    let response = try client.request(command.request(id: 1))
    describe(response)
    print("refreshed: \(response["apps"]?.arrayValue?.count ?? 0) apps")

  case .help:
    print(usage)

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
        emit("\(name): \(id) \(WavesCTLDisplay.percentage(changed["volume"]))%\(muted ? " muted" : "")")
      } else {
        emit(name)
      }
    }

  case .raw:
    let response = try client.request(command.request(id: 1))
    emit(JSONValue.object(response).description)
  }
} catch let error as WavesCTLTransportError {
  fail(error.description)
} catch {
  fail("Control request failed: \(error.localizedDescription)")
}
