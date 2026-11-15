import AudioToolbox
import Foundation
import OSLog
import WavesAudioCore

/// One process that Core Audio reports as running audio input right now.
///
/// This is metadata only: which process has an input stream running. Waves
/// never opens, reads, or records the input itself.
struct MicrophoneCaptureProcess: Hashable, Sendable {
  let pid: pid_t
  /// Bundle ID Core Audio reports for the process. For a helper this is the
  /// helper's own ID, such as `com.google.Chrome.helper`.
  var reportedBundleID: String?
  /// Canonical path of the outermost `.app` that contains the executable, so a
  /// browser or Electron helper maps to the app the user knows. Nil for a
  /// process that does not live inside an app bundle.
  var owningAppBundlePath: String?
  /// Bundle ID of `owningAppBundlePath`.
  var owningAppBundleID: String?
}

/// Reports which processes are running audio input, for opt-in call detection.
@MainActor
protocol MicrophoneActivityMonitoring: AnyObject {
  var isRunning: Bool { get }
  /// Begins observing. `onChange` runs on the main actor whenever the set of
  /// processes running input may have changed; callers then read
  /// `capturingProcesses()`. Calling `start` while running does nothing.
  func start(onChange: @escaping @MainActor () -> Void)
  /// Stops observing and removes every listener. Safe to call when stopped.
  func stop()
  /// Processes running audio input right now. Empty while stopped.
  func capturingProcesses() -> [MicrophoneCaptureProcess]
}

/// Reads `kAudioProcessPropertyIsRunningInput` on Core Audio's process objects.
///
/// Observation uses property listeners: one on the system object's process
/// list and one per process object for its input state. A slow fallback poll
/// covers a missed notification. Nothing is registered and nothing runs while
/// stopped, so a user who never turns the feature on pays nothing.
@MainActor
final class CoreAudioMicrophoneActivityMonitor: MicrophoneActivityMonitoring {
  /// Listener notifications are the primary signal; this only bounds how long a
  /// missed one can go unnoticed.
  static let fallbackPollInterval = Duration.seconds(5)

  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "CallDetection")
  private let listenerQueue = DispatchQueue(label: "com.jonathanreed.Waves.microphone-activity")
  private var onChange: (@MainActor () -> Void)?
  private var processListListener: AudioObjectPropertyListenerBlock?
  private var inputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
  private var pollTask: Task<Void, Never>?
  private var isChangeScheduled = false

  var isRunning: Bool { onChange != nil }

  init() {}

  func start(onChange: @escaping @MainActor () -> Void) {
    guard self.onChange == nil else { return }
    self.onChange = onChange

    var listAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
    let listListener = Self.makeListener(owner: self, rebuildsInputListeners: true)
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &listAddress, listenerQueue, listListener)
    if status == noErr {
      processListListener = listListener
    } else {
      logger.warning("Process list listener unavailable (OSStatus: \(status)); relying on the fallback poll.")
    }
    syncInputListeners()

    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.fallbackPollInterval)
        guard !Task.isCancelled, let self, self.isRunning else { return }
        self.syncInputListeners()
        self.onChange?()
      }
    }
  }

  func stop() {
    guard onChange != nil else { return }
    onChange = nil
    pollTask?.cancel()
    pollTask = nil
    if let processListListener {
      var listAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &listAddress, listenerQueue, processListListener)
      self.processListListener = nil
    }
    for objectID in Array(inputListeners.keys) {
      removeInputListener(objectID)
    }
  }

  func capturingProcesses() -> [MicrophoneCaptureProcess] {
    guard isRunning else { return [] }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return processObjectIDs().compactMap { objectID in
      guard readUInt32(objectID, kAudioProcessPropertyIsRunningInput) == 1,
        let pid = readPID(objectID), pid > 0, pid != ownPID
      else { return nil }
      // Same helper-to-app resolution the backend uses for routing: walk the
      // executable path out to the outermost `.app`.
      let owningPath = RuntimeProcessIdentity.probe(pid: pid)?.outerBundlePath
      return MicrophoneCaptureProcess(
        pid: pid,
        reportedBundleID: readBundleID(objectID),
        owningAppBundlePath: owningPath,
        owningAppBundleID: owningPath.flatMap { Bundle(path: $0)?.bundleIdentifier }
      )
    }
  }

  // MARK: - Listeners

  /// Nonisolated on purpose: Core Audio calls the block on `listenerQueue`, and
  /// a closure formed on the main actor would trap there under Swift 6's
  /// isolation checks. The block only hops back to the main actor.
  private nonisolated static func makeListener(
    owner: CoreAudioMicrophoneActivityMonitor,
    rebuildsInputListeners: Bool
  ) -> AudioObjectPropertyListenerBlock {
    let listener: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = {
      [weak owner] _, _ in
      Task { @MainActor [weak owner] in
        owner?.scheduleChange(rebuildsInputListeners: rebuildsInputListeners)
      }
    }
    return listener
  }

  /// Coalesces a burst of notifications (a browser starting several helpers)
  /// into one callback.
  private func scheduleChange(rebuildsInputListeners: Bool) {
    guard isRunning else { return }
    if rebuildsInputListeners { syncInputListeners() }
    guard !isChangeScheduled else { return }
    isChangeScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.isChangeScheduled = false
      self.onChange?()
    }
  }

  /// Keeps exactly one input-state listener per live process object.
  private func syncInputListeners() {
    guard isRunning else { return }
    let current = Set(processObjectIDs())
    for objectID in Set(inputListeners.keys).subtracting(current) {
      removeInputListener(objectID)
    }
    for objectID in current.subtracting(inputListeners.keys) {
      var address = Self.address(kAudioProcessPropertyIsRunningInput)
      let listener = Self.makeListener(owner: self, rebuildsInputListeners: false)
      if AudioObjectAddPropertyListenerBlock(objectID, &address, listenerQueue, listener) == noErr {
        inputListeners[objectID] = listener
      }
    }
  }

  private func removeInputListener(_ objectID: AudioObjectID) {
    guard let listener = inputListeners.removeValue(forKey: objectID) else { return }
    var address = Self.address(kAudioProcessPropertyIsRunningInput)
    // The object may already be gone; Core Audio drops its listeners with it.
    AudioObjectRemovePropertyListenerBlock(objectID, &address, listenerQueue, listener)
  }

  // MARK: - Property reads

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private func processObjectIDs() -> [AudioObjectID] {
    var address = Self.address(kAudioHardwarePropertyProcessObjectList)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
    let elementSize = MemoryLayout<AudioObjectID>.size
    guard size > 0, Int(size) % elementSize == 0 else { return [] }
    var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / elementSize)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.prefix(Int(size) / elementSize).filter { $0 != .unknown }
  }

  private func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = Self.address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
      size == UInt32(MemoryLayout<UInt32>.size)
    else { return nil }
    return value
  }

  private func readPID(_ objectID: AudioObjectID) -> pid_t? {
    var address = Self.address(kAudioProcessPropertyPID)
    var pid = pid_t()
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr,
      size == UInt32(MemoryLayout<pid_t>.size)
    else { return nil }
    return pid
  }

  private func readBundleID(_ objectID: AudioObjectID) -> String? {
    var address = Self.address(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
      let string = value?.takeRetainedValue() as String?,
      !string.isEmpty
    else { return nil }
    return string
  }
}
