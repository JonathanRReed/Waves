import AudioToolbox
import Foundation
import WavesAudioCore

// MARK: - Output devices and device-change handling

extension WorkspaceAudioControlBackend {
  func currentDefaultOutputDeviceUID() throws -> String {
    try outputDeviceUID(for: currentDefaultOutputDeviceID())
  }

  private func outputDeviceUID(for deviceID: AudioObjectID) throws -> String {
    var uidAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var uidSize: UInt32 = 0
    try withStatusCheck(
      AudioObjectGetPropertyDataSize(deviceID, &uidAddress, 0, nil, &uidSize),
      action: "read default output uid size"
    )
    let expectedUIDSize = UInt32(MemoryLayout<CFString?>.size)
    guard uidSize == expectedUIDSize else {
      throw BackendError.managedRouteUnavailable(
        "Default output UID returned \(uidSize) bytes; expected \(expectedUIDSize)."
      )
    }

    var readSize = expectedUIDSize
    var rawUID: CFString?
    let uidStatus = withUnsafeMutablePointer(to: &rawUID) {
      AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &readSize, $0)
    }
    try withStatusCheck(uidStatus, action: "read default output uid")
    guard readSize == expectedUIDSize else {
      throw BackendError.managedRouteUnavailable(
        "Default output UID returned \(readSize) bytes; expected \(expectedUIDSize)."
      )
    }

    guard let rawUID else {
      throw BackendError.managedRouteUnavailable("No output device UID returned.")
    }

    return rawUID as String
  }

  func currentOutputDevice() throws -> AudioDevice {
    let deviceID = try currentDefaultOutputDeviceID()
    let uid = try outputDeviceUID(for: deviceID)
    let name =
      (try? stringProperty(
        deviceID,
        selector: kAudioObjectPropertyName,
        action: "read default output name"
      )) ?? "System Output"

    return AudioDevice(
      id: uid,
      name: name,
      kind: OutputDeviceInventory.kind(uid: uid, name: name),
      isCurrent: true,
      isManagedRouteAvailable: supportsPerAppRouting
    )
  }

  private func currentDefaultOutputDeviceID() throws -> AudioObjectID {
    var selectorAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try withStatusCheck(
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &selectorAddress, 0, nil, &size, &deviceID),
      action: "read default output device"
    )

    guard deviceID != .unknown else {
      throw BackendError.managedRouteUnavailable("No default output device found.")
    }

    return deviceID
  }

  func availableOutputDevices() async -> [AudioDevice] {
    guard !isShuttingDown, supportsPerAppRouting else { return [] }
    let currentUID = try? currentDefaultOutputDeviceUID()
    var devices: [AudioDevice] = []
    for deviceID in allDeviceIDs() where OutputDeviceInventory.hasOutputStreams(deviceID) {
      guard let uid = OutputDeviceInventory.deviceUID(deviceID) else { continue }
      // Skip Waves' own private aggregate devices so they never appear as
      // user-selectable outputs.
      if uid.hasPrefix("com.waves.aggregate.") { continue }
      let name = (try? stringProperty(deviceID, selector: kAudioObjectPropertyName, action: "read device name")) ?? "Output Device"
      let kind = OutputDeviceInventory.kind(uid: uid, name: name)
      // Note: do NOT also filter on a "waves" name substring. This app's own
      // aggregates are reliably identified by the com.waves.aggregate. UID prefix
      // above; a name-based test would wrongly hide legitimate third-party
      // hardware from Waves Audio (a real vendor) whose names contain "waves".
      devices.append(
        AudioDevice(
          id: uid,
          name: name,
          kind: kind,
          isCurrent: uid == currentUID,
          isManagedRouteAvailable: supportsPerAppRouting
        ))
    }
    return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func setDefaultOutputDevice(uid: String) async throws {
    try ensureAcceptingOperations()
    guard let deviceID = allDeviceIDs().first(where: { OutputDeviceInventory.deviceUID($0) == uid }) else {
      throw BackendError.managedRouteUnavailable("That output device is no longer available.")
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var mutableID = deviceID
    try withStatusCheck(
      AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioObjectID>.size),
        &mutableID
      ),
      action: "set default output device"
    )
    // The default-device listener fires from here, driving auto-restore + a
    // deviceChangeEvents emission that refreshes the UI.
  }

  func setOutputDevice(uid: String?, forAppID appID: String) async throws {
    try ensureAcceptingOperations()
    let app = try legacyApp(forAppID: appID)
    let values = intentControlValues(for: app)
    let result = await applyAppIntent(
      AppRouteIntent(
        appID: app.logicalID,
        desiredVolume: values.desiredVolume,
        isMuted: values.isMuted,
        volumeBoost: values.volumeBoost,
        equalizerSettings: values.equalizerSettings,
        targetDeviceUID: uid,
        generation: nextLegacyGeneration(),
        reason: .userEdit
      ))
    try validateLegacyApplyResult(result)
  }

  func isDeviceAvailable(uid: String) -> Bool {
    allDeviceIDs().contains { OutputDeviceInventory.deviceUID($0) == uid }
  }

  /// Input streams the device with `uid` exposes, or 0 when it has none or
  /// cannot be found. Feeds the tap controller's input stream layout.
  func inputStreamCount(forDeviceUID uid: String) -> Int {
    guard let deviceID = allDeviceIDs().first(where: { OutputDeviceInventory.deviceUID($0) == uid }) else {
      return 0
    }
    return OutputDeviceInventory.inputStreamCount(deviceID)
  }

  private func allDeviceIDs() -> [AudioObjectID] {
    OutputDeviceInventory.allDeviceIDs { message in
      logger.warning("\(message, privacy: .public)")
    }
  }

  private func stringProperty(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    action: String
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0
    try withStatusCheck(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &propertySize),
      action: "\(action) size"
    )
    let expectedSize = UInt32(MemoryLayout<CFString?>.size)
    guard propertySize == expectedSize else {
      throw BackendError.managedRouteUnavailable(
        "\(action) returned an invalid string property size."
      )
    }

    var readSize = expectedSize
    var rawValue: CFString?
    let status = withUnsafeMutablePointer(to: &rawValue) {
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &readSize, $0)
    }
    try withStatusCheck(status, action: action)
    guard readSize == expectedSize else {
      throw BackendError.managedRouteUnavailable(
        "\(action) returned \(readSize) bytes; expected \(expectedSize)."
      )
    }

    guard let rawValue else {
      throw BackendError.managedRouteUnavailable("\(action) returned no value.")
    }

    return rawValue as String
  }

  func addDeviceChangeListener() {
    guard !isShuttingDown else { return }
    // Avoid registering a second listener (and leaking the previous block) if
    // start() runs more than once.
    guard deviceChangeListenerBlock == nil else { return }

    let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
      let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
      Task { [weak self] in
        await self?.handleDeviceChange(selectors: selectors)
      }
    }

    let selectors: [AudioObjectPropertySelector] = [
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioHardwarePropertyDevices,
    ]

    for selector in selectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main,
        listenerBlock
      )

      if status == noErr {
        deviceChangeListenerSelectors.append(selector)
      } else {
        logger.error("Failed to add device change listener \(selector): \(status)")
      }
    }

    if !deviceChangeListenerSelectors.isEmpty {
      deviceChangeListenerBlock = listenerBlock
    }
  }

  func removeDeviceChangeListener() -> [CleanupDegradation] {
    guard let listenerBlock = deviceChangeListenerBlock else {
      deviceChangeListenerSelectors.removeAll()
      return []
    }

    var observations: [CleanupStatusObservation] = []
    for selector in deviceChangeListenerSelectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      observations.append(
        CleanupStatusObservation(
          stage: .listenerRemoval,
          nativeStatus: AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listenerBlock
          ),
          detail: "Remove device listener selector \(selector)"
        ))
    }

    deviceChangeListenerSelectors.removeAll()
    deviceChangeListenerBlock = nil
    return checkedCleanupDegradations(from: observations)
  }

  private func handleDeviceChange(selectors: [AudioObjectPropertySelector]) async {
    guard !isShuttingDown else { return }
    // macOS commonly raises the default-output change twice in quick
    // succession (Bluetooth connect, dock, display wake). Two overlapping
    // passes on this reentrant actor each rebuilt every managed route, so the
    // second pass replaced and disposed the controllers the first had just
    // created: twice the tap and aggregate churn, and two dropouts per app.
    // Fold later events into one follow-up pass instead.
    if isHandlingDeviceChange {
      pendingDeviceChangeSelectors = (pendingDeviceChangeSelectors ?? []) + selectors
      return
    }
    isHandlingDeviceChange = true
    defer { isHandlingDeviceChange = false }
    var currentSelectors = selectors
    while true {
      await performDeviceChangePass(selectors: currentSelectors)
      guard !isShuttingDown, let pending = pendingDeviceChangeSelectors else { return }
      pendingDeviceChangeSelectors = nil
      currentSelectors = pending
    }
  }

  private func performDeviceChangePass(selectors: [AudioObjectPropertySelector]) async {
    let currentDefaultUID = try? currentDefaultOutputDeviceUID()
    let defaultOutputChanged = defaultOutputDeviceChange.didChange(
      selectors: selectors,
      currentUID: currentDefaultUID
    )
    let externalDeviceUIDs = currentExternalDeviceUIDs()
    let inventoryChanged = externalDeviceUIDs != lastKnownExternalDeviceUIDs
    lastKnownExternalDeviceUIDs = externalDeviceUIDs

    if defaultOutputChanged {
      // Re-tap managed routes only when the effective default output changed.
      // Plain device inventory churn, such as plugging in an unused interface,
      // should not tear down audible routes.
      do {
        _ = try await autoRestoreDevice()
        guard !isShuttingDown else { return }
        logger.info("Output device changed, managed routes restored")
      } catch {
        guard !isShuttingDown else { return }
        refreshGlobalRouteHealth(latestError: error.localizedDescription)
        logger.error("Output device change recovery failed: \(error.localizedDescription)")
      }
    } else {
      // Every Waves route rebuild creates and destroys a private aggregate,
      // and each of those raises this same inventory event. When nothing
      // outside Waves changed there is nothing to reconcile and nothing for
      // the store to refresh; reacting anyway fed the rebuild back into
      // itself (a pinned route whose device accepts an aggregate but fails to
      // start could loop without end).
      guard inventoryChanged else { return }
      await reconcilePinnedRoutesAfterDeviceInventoryChange()
    }
    guard !isShuttingDown else { return }
    // Notify observers (the store) so they can refresh UI state and restore
    // per-device volume presets, regardless of whether restoration succeeded.
    deviceChangeContinuation.yield()
  }

  /// UIDs of every device that is not one of Waves's own private aggregates.
  private func currentExternalDeviceUIDs() -> Set<String> {
    Set(
      allDeviceIDs()
        .compactMap(OutputDeviceInventory.deviceUID)
        .filter { !$0.hasPrefix("com.waves.aggregate.") }
    )
  }

  private func reconcilePinnedRoutesAfterDeviceInventoryChange() async {
    let availableUIDs = Set(allDeviceIDs().compactMap(OutputDeviceInventory.deviceUID))
    guard !availableUIDs.isEmpty else { return }

    var lastError: String?
    var routesNeedingReattach: Set<String> = []

    for app in snapshot.apps {
      guard let targetDeviceUID = app.targetDeviceUID else { continue }
      let isActivelyManaged = app.routingState == .managed || controllers[app.id]?.isActive == true
      let targetIsAvailable = availableUIDs.contains(targetDeviceUID)

      if isActivelyManaged, !targetIsAvailable {
        if let controller = controllers.removeValue(forKey: app.id) {
          retainCleanupDegradations(disposeController(controller))
        }
        controllerGenerationByRuntimeID.removeValue(forKey: app.id)
        staleRouteTicks.removeValue(forKey: app.logicalID)
        lastRenderTickByAppID.removeValue(forKey: app.logicalID)
        let error = BackendError.managedRouteUnavailable(
          "The chosen output device for \(app.displayName) is unavailable. Pick another in the app's Output Device menu."
        )
        if let index = snapshot.apps.firstIndex(where: { $0.id == app.id || $0.logicalID == app.logicalID }) {
          markRouteError(at: index, error: error)
          snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
          snapshot.apps[index].peakLevel = 0
          snapshot.apps[index].rmsLevel = 0
        }
        lastError = error.localizedDescription
      } else if app.routingState == .error, targetIsAvailable, !app.hasNoAudioCapability {
        routesNeedingReattach.insert(app.logicalID)
      }
    }

    if !routesNeedingReattach.isEmpty {
      await reattachRoutes(forLogicalIDs: routesNeedingReattach)
      if lastError != nil {
        refreshGlobalRouteHealth(latestError: lastError)
        snapshot.updatedAt = .now
      }
    } else if lastError != nil {
      refreshGlobalRouteHealth(latestError: lastError)
      snapshot.updatedAt = .now
    }
  }
}
