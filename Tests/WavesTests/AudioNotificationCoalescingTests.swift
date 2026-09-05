import AudioToolbox
import Foundation
import Testing

@testable import Waves

@Test(arguments: [false, true])
func backendDeviceNotificationsRetainOnlyOnePendingRefresh(testingInitializer: Bool) async {
  let backend =
    testingInitializer
    ? WorkspaceAudioControlBackend(testingSnapshot: .empty)
    : WorkspaceAudioControlBackend()
  for _ in 0..<10_000 { backend.deviceChangeContinuation.yield() }
  backend.deviceChangeContinuation.finish()

  var refreshes = 0
  for await _ in backend.deviceChangeEvents { refreshes += 1 }
  #expect(refreshes == 1)
  _ = await backend.shutdownWithResult()
}

@Test func audioPropertyMailboxUnionsBurstsAndKeepsOneFollowupWake() async throws {
  let mailbox = AudioPropertyChangeMailbox()
  var wakeups = mailbox.wakeups.makeAsyncIterator()
  mailbox.enqueue(.deviceInventory)
  try #require(await wakeups.next() != nil)
  #expect(mailbox.takePending() == .deviceInventory)

  // The consumer is busy with its first pass while native callbacks continue.
  mailbox.enqueue(.defaultOutput)
  DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
    mailbox.enqueue(.deviceInventory)
  }
  try #require(await wakeups.next() != nil)
  #expect(mailbox.takePending() == [.defaultOutput, .deviceInventory])
  #expect(mailbox.takePending().isEmpty)

  // An arrival after the exchange still wakes the same consumer.
  mailbox.enqueue(.deviceInventory)
  try #require(await wakeups.next() != nil)
  #expect(mailbox.takePending() == .deviceInventory)
  mailbox.finish()
  #expect(await wakeups.next() == nil)
}

@Test func audioPropertyMailboxFinishesWithNoPendingWorkAndRejectsLateCallbacks() async {
  let mailbox = AudioPropertyChangeMailbox()
  mailbox.enqueue([.defaultOutput, .deviceInventory, .routerObservation])
  mailbox.finish()
  mailbox.enqueue(.defaultOutput)
  #expect(mailbox.takePending().isEmpty)
  var wakeCount = 0
  for await _ in mailbox.wakeups { wakeCount += 1 }
  #expect(wakeCount <= 1)
}

@Test func outputPropertyFlagsIgnoreUnrelatedSelectorsWithoutLosingDefaultChanges() {
  let addresses = [
    kAudioHardwarePropertyDevices,
    kAudioObjectPropertyName,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDevices,
  ].map {
    AudioObjectPropertyAddress(
      mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
  }
  let changes = addresses.withUnsafeBufferPointer { AudioPropertyChanges.outputChanges(in: $0) }
  #expect(changes == [.defaultOutput, .deviceInventory])
  #expect(changes.outputSelectors == [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices])
  let unrelated = Array(addresses[1...1])
  #expect(unrelated.withUnsafeBufferPointer { AudioPropertyChanges.outputChanges(in: $0) }.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func backendRouterConsumerStopsEvenWhenNativeRemovalFails() async throws {
  let callbacks = NotificationCallbackRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: .empty,
    routerObservationNativeCalls: .init(
      add: { _, listener in
        callbacks.retain(listener); return noErr
      },
      remove: { _, _ in -50 }
    )
  )
  #expect(await backend.addRouterObservationListeners().isEmpty)
  let consumer = try #require(await backend.routerObservationTask)
  let before = await backend.routerObservationGeneration
  callbacks.deliverBurst()
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while await backend.routerObservationGeneration == before, ContinuousClock.now < deadline {
    await Task.yield()
  }
  #expect(await backend.routerObservationGeneration > before)

  let result = await backend.shutdownWithResult()
  #expect(result.degradations.contains { $0.stage == .listenerRemoval })
  await consumer.value
  #expect(await backend.routerObservationTask == nil)
  #expect(await backend.deviceChangeTask == nil)
  let stoppedGeneration = await backend.routerObservationGeneration
  callbacks.deliverBurst()
  #expect(await backend.routerObservationGeneration == stoppedGeneration)
}

@Test(.timeLimit(.minutes(1)))
func releasingBackendStopsItsWaitingNotificationConsumer() async throws {
  var backend: WorkspaceAudioControlBackend? = WorkspaceAudioControlBackend(
    testingSnapshot: .empty,
    routerObservationNativeCalls: .init(add: { _, _ in noErr }, remove: { _, _ in noErr })
  )
  _ = await backend?.addRouterObservationListeners()
  let consumer = try #require(await backend?.routerObservationTask)
  weak var releasedBackend = backend
  backend = nil
  #expect(releasedBackend == nil)
  releasedBackend = nil
  #expect(consumer.isCancelled)
  consumer.cancel()
  await consumer.value
}

private final class NotificationCallbackRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var listener: RouterObservationListenerBlockReference?

  func retain(_ listener: RouterObservationListenerBlockReference) {
    lock.withLock { self.listener = listener }
  }

  func deliverBurst() {
    guard let listener = lock.withLock({ listener }) else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTapList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    for _ in 0..<10_000 { listener.block(1, &address) }
  }
}
