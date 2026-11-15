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

  func allDeviceIDs() -> [AudioObjectID] {
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

    let mailbox = deviceChangeMailbox
    if deviceChangeTask == nil {
      deviceChangeTask = Task { [weak self, mailbox] in
        for await _ in mailbox.wakeups {
          guard !Task.isCancelled else { break }
          var changes = mailbox.takePending()
          guard !changes.isEmpty else { continue }
          if changes.isDisjoint(with: [.defaultOutput, .deviceInventory]) {
            // A Bluetooth profile switch or a wake raises a burst of rate,
            // stream, and alive events. Let it settle, then revalidate once.
            try? await Task.sleep(for: WorkspaceAudioControlBackend.formatEventDebounce)
            guard !Task.isCancelled else { break }
            changes.formUnion(mailbox.takePending())
          }
          await self?.performDeviceChangePass(changes: changes)
          await Task.yield()
        }
      }
    }
    let listenerBlock: AudioObjectPropertyListenerBlock = { count, addresses in
      mailbox.enqueue(.outputChanges(in: UnsafeBufferPointer(start: addresses, count: Int(count))))
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
    syncDeviceFormatListeners()
    addWakeObserver()
  }

  func removeDeviceChangeListener() -> [CleanupDegradation] {
    removeWakeObserver()
    let formatDegradations = deviceFormatListeners.remove()
    guard let listenerBlock = deviceChangeListenerBlock else {
      deviceChangeListenerSelectors.removeAll()
      return formatDegradations
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
    return formatDegradations + checkedCleanupDegradations(from: observations)
  }

  private func performDeviceChangePass(changes: AudioPropertyChanges) async {
    guard !isShuttingDown, !Task.isCancelled else { return }
    let currentDefaultUID = try? currentDefaultOutputDeviceUID()
    let defaultOutputChanged = defaultOutputDeviceChange.didChange(
      selectors: changes.outputSelectors,
      currentUID: currentDefaultUID
    )
    let externalDeviceUIDs = currentExternalDeviceUIDs()
    let inventoryChanged = externalDeviceUIDs != lastKnownExternalDeviceUIDs
    lastKnownExternalDeviceUIDs = externalDeviceUIDs
    if inventoryChanged {
      syncDeviceFormatListeners()
    }

    await applyDeviceChangePlan(
      DeviceChangePassPlan(defaultOutputChanged: defaultOutputChanged, inventoryChanged: inventoryChanged),
      availableDeviceUIDs: { Set(self.allDeviceIDs().compactMap(OutputDeviceInventory.deviceUID)) },
      restoreDefaultFollowingRoutes: { try await self.autoRestoreDevice() }
    )
    guard !isShuttingDown else { return }
    if !changes.isDisjoint(with: [.deviceFormat, .wake]) {
      await revalidateRouteFormats(now: Self.monotonicRouteTime())
    }
  }

  func applyDeviceChangePlan(
    _ plan: DeviceChangePassPlan,
    availableDeviceUIDs: () -> Set<String>,
    restoreDefaultFollowingRoutes: () async throws -> AudioSessionSnapshot
  ) async {
    guard plan.reconcilesPinnedRoutes || plan.rehomesDefaultFollowingRoutes else { return }
    // Pinned routes first. Unplugging a device that was both the default and
    // a pinned destination raises both changes at once, and the inventory
    // change is consumed by this pass; skipping it here left routes to the
    // vanished device marked managed until something else rebuilt them.
    if plan.reconcilesPinnedRoutes {
      await reconcilePinnedRoutesAfterDeviceInventoryChange(availableUIDs: availableDeviceUIDs())
      guard !isShuttingDown else { return }
    }
    if plan.rehomesDefaultFollowingRoutes {
      do {
        _ = try await restoreDefaultFollowingRoutes()
        guard !isShuttingDown else { return }
        logger.info("Output device changed, managed routes restored")
      } catch {
        guard !isShuttingDown else { return }
        refreshGlobalRouteHealth(latestError: error.localizedDescription)
        logger.error("Output device change recovery failed: \(error.localizedDescription)")
      }
    }
    guard !isShuttingDown else { return }
    // Notify observers (the store) so they can refresh UI state and restore
    // per-device volume presets, regardless of whether restoration succeeded.
    deviceChangeContinuation.yield()
  }

  func applyDeviceChangePlanForTesting(
    _ plan: DeviceChangePassPlan,
    availableDeviceUIDs: Set<String>
  ) async {
    await applyDeviceChangePlan(
      plan,
      availableDeviceUIDs: { availableDeviceUIDs },
      restoreDefaultFollowingRoutes: { try await self.restoreDefaultFollowingRoutesForTesting() }
    )
  }

  /// UIDs of every device that is not one of Waves's own private aggregates.
  private func currentExternalDeviceUIDs() -> Set<String> {
    Set(
      allDeviceIDs()
        .compactMap(OutputDeviceInventory.deviceUID)
        .filter { !$0.hasPrefix("com.waves.aggregate.") }
    )
  }

  private func reconcilePinnedRoutesAfterDeviceInventoryChange(availableUIDs: Set<String>) async {
    guard !availableUIDs.isEmpty else { return }

    var lastError: String?
    var routesNeedingReattach: Set<String> = []

    for app in snapshot.apps {
      guard let targetDeviceUID = app.targetDeviceUID else { continue }
      let isActivelyManaged = app.routingState == .managed || controllers[app.id]?.isActive == true
      let targetIsAvailable = availableUIDs.contains(targetDeviceUID)

      if isActivelyManaged, !targetIsAvailable {
        releaseRoute(runtimeID: app.id)
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
      await reattachRoutes(forLogicalIDs: routesNeedingReattach, origin: .automatic)
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

/// What one coalesced device-change pass has to do.
struct DeviceChangePassPlan: Equatable, Sendable {
  /// Re-tap routes that follow the system default, only when the effective
  /// default changed. Plain inventory churn, such as plugging in an unused
  /// interface, must not tear down audible routes.
  let rehomesDefaultFollowingRoutes: Bool
  /// Reconcile pinned routes whenever a device outside Waves appeared or
  /// disappeared, including in the same pass as a default change. Waves's
  /// own aggregate create/destroy is filtered out before this point; reacting
  /// to it fed rebuilds back into themselves.
  let reconcilesPinnedRoutes: Bool

  init(defaultOutputChanged: Bool, inventoryChanged: Bool) {
    rehomesDefaultFollowingRoutes = defaultOutputChanged
    reconcilesPinnedRoutes = inventoryChanged
  }
}
