import AudioToolbox
import Foundation
import WavesAudioCore

enum OutputDeviceInventory {
  static func allDeviceIDs(logWarning: (String) -> Void) -> [AudioObjectID] {
    let elementSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let maximumDeviceCount = 256
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
      return []
    }
    guard size % elementSize == 0 else {
      logWarning("Ignoring malformed device list byte size \(size); expected a multiple of \(elementSize).")
      return []
    }
    let count = Int(size / elementSize)
    guard count <= maximumDeviceCount, count > 0 else { return [] }
    let expectedSize = size
    var readSize = expectedSize
    var ids = [AudioObjectID](repeating: .unknown, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &readSize, &ids) == noErr else {
      return []
    }
    guard readSize == expectedSize else {
      logWarning("Ignoring device list read that returned \(readSize) bytes; expected \(expectedSize).")
      return []
    }
    return ids.filter { $0 != .unknown }
  }

  static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }
    return size > 0
  }

  static func deviceUID(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
    guard size == UInt32(MemoryLayout<CFString?>.size) else { return nil }
    var rawUID: CFString?
    let status = withUnsafeMutablePointer(to: &rawUID) {
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, size == UInt32(MemoryLayout<CFString?>.size), let rawUID else { return nil }
    return rawUID as String
  }

  static func kind(uid: String, name: String) -> DeviceKind {
    let token = "\(uid) \(name)".lowercased()
    if token.contains("bluetooth") || token.contains("airpods") || token.contains("beats") {
      return .bluetooth
    }
    if token.contains("display") || token.contains("hdmi") || token.contains("usb-c") {
      return .display
    }
    if token.contains("aggregate") || token.contains("multi-output") {
      return .aggregate
    }
    if token.contains("waves") || token.contains("blackhole") || token.contains("soundflower") || token.contains("eqmac") {
      return .virtual
    }
    if token.contains("speaker") || token.contains("built-in") || token.contains("macbook") {
      return .builtInOutput
    }
    return .unknown
  }
}

struct DefaultOutputDeviceChange {
  private(set) var lastKnownUID: String?

  mutating func recordInitialUID(_ uid: String?) {
    lastKnownUID = uid
  }

  mutating func didChange(
    selectors: [AudioObjectPropertySelector],
    currentUID: String?
  ) -> Bool {
    defer { lastKnownUID = currentUID }
    return selectors.contains(kAudioHardwarePropertyDefaultOutputDevice)
      || (lastKnownUID != nil && currentUID != lastKnownUID)
  }
}
