import AudioToolbox
import Foundation
import WavesAudioCore

/// The parts of an output device's format that a built route depends on.
/// The tap's format plan, `EqualizerDSP`, and `VoiceBandEnergyAnalyzer` all
/// take the sample rate once, at construction, and the IO callback's geometry
/// check compares buffer sizes, not rates. A same-device rate change (48 kHz
/// to 96 kHz in Audio MIDI Setup) therefore passes that check while every EQ
/// band sits an octave off. Rebuilding is the existing, bounded way to give a
/// route a new format.
struct DeviceFormatSignature: Equatable, Sendable {
  let sampleRate: Double
  let outputChannelCount: Int
}

enum DeviceFormatObservation: Equatable, Sendable {
  case alive(DeviceFormatSignature)
  /// Listed but reporting not alive (a Bluetooth link dropping, a device
  /// mid-reset), or listed but unreadable.
  case notAlive
  /// No longer in the device list.
  case missing
}

/// The device a live route renders to, and that device's format when the
/// route was built. The device is always known to whatever built the route;
/// its format is optional metadata that a failed read leaves nil, without
/// losing the device. A route with no recorded format is rebuilt once its
/// device next reports one, which records it.
struct RouteOutputBinding: Equatable, Sendable {
  let deviceUID: String
  let signature: DeviceFormatSignature?
}

enum RouteFormatRevalidation {
  struct Decision: Equatable, Sendable {
    var runtimeIDsToRebuild: Set<String> = []
    /// Devices observed not alive in this pass. A route bound to one of them
    /// is rebuilt once the device is alive again, whatever its format.
    var devicesSeenNotAlive: Set<String> = []
  }

  /// Which routes to rebuild after rate, stream-format, alive, or wake events.
  ///
  /// Only a device that is alive now is worth rebuilding on. A missing
  /// device is the default-output and inventory passes' job (rehome, or the
  /// pinned-route policy), and a device that is not alive yet would only fail.
  /// A route whose device still matches its recorded format is left alone:
  /// the rebuild records the format it was built for, so the event a rebuild
  /// itself causes finds nothing to do, which is what keeps this from looping.
  static func decide(
    bindings: [String: RouteOutputBinding],
    observations: [String: DeviceFormatObservation],
    devicesPreviouslySeenNotAlive: Set<String>
  ) -> Decision {
    var decision = Decision()
    for (deviceUID, observation) in observations where observation == .notAlive {
      decision.devicesSeenNotAlive.insert(deviceUID)
    }
    for (runtimeID, binding) in bindings {
      guard case .alive(let current) = observations[binding.deviceUID] else {
        if devicesPreviouslySeenNotAlive.contains(binding.deviceUID) {
          decision.devicesSeenNotAlive.insert(binding.deviceUID)
        }
        continue
      }
      if current != binding.signature || devicesPreviouslySeenNotAlive.contains(binding.deviceUID) {
        decision.runtimeIDsToRebuild.insert(runtimeID)
      }
    }
    return decision
  }
}

extension OutputDeviceInventory {
  static func formatObservation(_ deviceID: AudioObjectID) -> DeviceFormatObservation {
    guard isAlive(deviceID),
      let sampleRate = nominalSampleRate(deviceID),
      let channels = outputChannelCount(deviceID)
    else { return .notAlive }
    return .alive(DeviceFormatSignature(sampleRate: sampleRate, outputChannelCount: channels))
  }

  static func isAlive(_ deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
      size == UInt32(MemoryLayout<UInt32>.size)
    else { return false }
    return value != 0
  }

  static func nominalSampleRate(_ deviceID: AudioObjectID) -> Double? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr,
      size == UInt32(MemoryLayout<Float64>.size), rate.isFinite, rate > 0
    else { return nil }
    return rate
  }

  /// Total output channels across the device's output streams.
  static func outputChannelCount(_ deviceID: AudioObjectID) -> Int? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
      size >= UInt32(MemoryLayout<AudioBufferList>.size),
      size <= UInt32(NativeAudioStreamConfigurationPlan.maximumPropertyByteCount)
    else { return nil }
    let capacity = Int(size)
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: capacity,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr,
      Int(size) <= capacity,
      NativeAudioStreamConfigurationPlan.streamCount(
        in: UnsafeRawBufferPointer(start: raw, count: Int(size))
      ) != nil
    else { return nil }
    let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }
}

/// Per-device listeners for the format events a built route depends on. The
/// native calls are injectable so tests never register on real devices.
struct DeviceFormatListenerNativeCalls: Sendable {
  let add: @Sendable (AudioObjectID, AudioObjectPropertyAddress, RouterObservationListenerBlockReference) -> OSStatus
  let remove: @Sendable (AudioObjectID, AudioObjectPropertyAddress, RouterObservationListenerBlockReference) -> OSStatus
  /// Read on the listener queue when a device's alive state changes.
  let isAlive: @Sendable (AudioObjectID) -> Bool

  init(
    add: @escaping @Sendable (AudioObjectID, AudioObjectPropertyAddress, RouterObservationListenerBlockReference) -> OSStatus,
    remove: @escaping @Sendable (AudioObjectID, AudioObjectPropertyAddress, RouterObservationListenerBlockReference) -> OSStatus,
    isAlive: @escaping @Sendable (AudioObjectID) -> Bool = { _ in true }
  ) {
    self.add = add
    self.remove = remove
    self.isAlive = isAlive
  }

  static func live(on queue: DispatchQueue) -> Self {
    Self(
      add: { deviceID, address, listener in
        var address = address
        return AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener.block)
      },
      remove: { deviceID, address, listener in
        var address = address
        return AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener.block)
      },
      isAlive: OutputDeviceInventory.isAlive
    )
  }
}

/// Owns the per-device format listeners. Every registration stays owned
/// until its own removal succeeds (or reports the device already gone), so a
/// failed removal is reported and retried rather than forgotten, and the
/// owner cleans up whatever it still holds when it is released.
final class DeviceFormatListenerLifecycle: @unchecked Sendable {
  static let addresses: [AudioObjectPropertyAddress] = [
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    ),
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    ),
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    ),
  ]

  private let nativeCalls: DeviceFormatListenerNativeCalls
  /// Device object → the device UID it was registered for, its listener
  /// block, and the addresses registered with it. One block per device, so a
  /// callback knows which device it is for. Core Audio can give a returning
  /// device a new object ID, and can reuse an object ID for another device,
  /// so a registration is reused only while both its object ID and its UID
  /// still match.
  private var installed: [AudioObjectID: (uid: String, listener: RouterObservationListenerBlockReference, addresses: [AudioObjectPropertyAddress])] = [:]
  /// The device list the last sync was given. Kept apart from `installed`,
  /// which also holds registrations kept only because their removal failed:
  /// those describe where a device used to be, not where it was last seen,
  /// so they must never make an unchanged device look as if it moved.
  private var lastObservedDevices: [AudioObjectID: String] = [:]
  private let notAliveLock = NSLock()
  private var notAliveDeviceUIDs: Set<String> = []

  init(nativeCalls: DeviceFormatListenerNativeCalls) {
    self.nativeCalls = nativeCalls
  }

  deinit {
    _ = remove()
  }

  /// Registrations still owned, for diagnostics and tests.
  var registrationCount: Int { installed.values.reduce(0) { $0 + $1.addresses.count } }

  /// Devices seen not alive by a listener callback since the last call. The
  /// revalidation pass runs after a 500 ms debounce and reads only the final
  /// state, so a device that drops and comes back inside that window would
  /// otherwise look as if nothing had happened, and its routes, whose
  /// aggregates may not have survived, would not be rebuilt.
  func takeDevicesSeenNotAlive() -> Set<String> {
    notAliveLock.withLock {
      defer { notAliveDeviceUIDs.removeAll() }
      return notAliveDeviceUIDs
    }
  }

  /// Listens on exactly `devices` (object ID → UID): new devices gain
  /// listeners, departed ones lose them. A device keeps whatever listeners it
  /// accepted; the next sync adds only the ones it refused, and retries any
  /// removal that failed.
  ///
  /// An object ID that now names another device loses its old registrations
  /// before the new device gets its own block. A UID that now lives on a
  /// different object than in the previous sync's list is a device that went
  /// away and came back: whatever a route's aggregate was built on may not
  /// have survived, so it is recorded as seen not alive, exactly as if its
  /// alive listener had caught it. Recorded once, on the sync that sees the
  /// move.
  func sync(
    devices: [AudioObjectID: String],
    onChange: @escaping @Sendable () -> Void
  ) -> [CleanupDegradation] {
    var degradations: [CleanupDegradation] = []
    var previousObjectByUID: [String: AudioObjectID] = [:]
    for (deviceID, uid) in lastObservedDevices { previousObjectByUID[uid] = deviceID }
    lastObservedDevices = devices
    for deviceID in installed.keys.sorted() where devices[deviceID] != installed[deviceID]?.uid {
      degradations += removeListeners(from: deviceID)
    }
    for (deviceID, uid) in devices.sorted(by: { $0.key < $1.key }) {
      if let previous = previousObjectByUID[uid], previous != deviceID {
        notAliveLock.withLock { _ = notAliveDeviceUIDs.insert(uid) }
      }
      // An old registration on this object that would not come off yet; the
      // next sync retries the removal before registering the new device.
      if let entry = installed[deviceID], entry.uid != uid { continue }
      let listener = installed[deviceID]?.listener ?? makeListener(deviceID: deviceID, uid: uid, onChange: onChange)
      let owned = installed[deviceID]?.addresses ?? []
      var added: [AudioObjectPropertyAddress] = []
      // Each address in `addresses` has its own selector.
      for address in Self.addresses where !owned.contains(where: { $0.mSelector == address.mSelector }) {
        let status = nativeCalls.add(deviceID, address, listener)
        if status == noErr {
          added.append(address)
        } else {
          degradations.append(
            CleanupDegradation(
              stage: .listenerInstallation,
              nativeStatus: status,
              detail: "Add device format listener selector \(address.mSelector)"
            ))
        }
      }
      if !added.isEmpty {
        installed[deviceID] = (uid, listener, owned + added)
      }
    }
    return degradations
  }

  /// Removes every owned registration. One whose removal fails stays owned
  /// and is reported; calling again retries only those.
  func remove() -> [CleanupDegradation] {
    installed.keys.sorted().flatMap { removeListeners(from: $0) }
  }

  /// The block does not capture the lifecycle strongly: Core Audio retains
  /// it, and that must not keep the owner (and so its deinit cleanup) alive.
  private func makeListener(
    deviceID: AudioObjectID,
    uid: String,
    onChange: @escaping @Sendable () -> Void
  ) -> RouterObservationListenerBlockReference {
    let isAlive = nativeCalls.isAlive
    return RouterObservationListenerBlockReference { [weak self] count, addresses in
      let aliveChanged = (0..<Int(count)).contains {
        addresses[$0].mSelector == kAudioDevicePropertyDeviceIsAlive
      }
      if aliveChanged, !isAlive(deviceID), let self {
        self.notAliveLock.withLock { _ = self.notAliveDeviceUIDs.insert(uid) }
      }
      onChange()
    }
  }

  private func removeListeners(from deviceID: AudioObjectID) -> [CleanupDegradation] {
    guard let entry = installed[deviceID] else { return [] }
    var degradations: [CleanupDegradation] = []
    var stillOwned: [AudioObjectPropertyAddress] = []
    for address in entry.addresses {
      let status = nativeCalls.remove(deviceID, address, entry.listener)
      // A device that has already gone away takes its listeners with it.
      guard status != noErr, status != kAudioHardwareBadObjectError else { continue }
      stillOwned.append(address)
      degradations.append(
        CleanupDegradation(
          stage: .listenerRemoval,
          nativeStatus: status,
          detail: "Remove device format listener selector \(address.mSelector)"
        ))
    }
    installed[deviceID] = stillOwned.isEmpty ? nil : (entry.uid, entry.listener, stillOwned)
    return degradations
  }
}
