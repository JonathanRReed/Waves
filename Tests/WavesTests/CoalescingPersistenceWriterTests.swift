import Foundation
import Testing

@testable import Waves

@Test func coalescingWriterWritesActiveThenNewestPendingAndCompletesEveryWaiter() async throws {
  let harness = ControlledPersistenceWrite(blockedAttempts: [1])
  let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.coalescing") {
    try harness.write($0)
  }

  let first = Task { try await writer.save(0) }
  await harness.waitUntilAttemptStarted(1)

  var coalesced: [Task<Void, Error>] = []
  for value in 1...40 {
    coalesced.append(Task { try await writer.save(value) })
    await waitUntilAccepted(writer, count: UInt64(value + 1))
  }

  harness.release(attempt: 1)
  try await first.value
  for task in coalesced {
    try await task.value
  }

  #expect(harness.writtenValues == [0, 40])
}

@Test func coalescingWriterPropagatesActiveAndPendingErrorsThenRecovers() async throws {
  let harness = ControlledPersistenceWrite(
    blockedAttempts: [1],
    failuresByValue: [1: .active, 3: .pending]
  )
  let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.errors") {
    try harness.write($0)
  }

  let active = Task { try await writer.save(1) }
  await harness.waitUntilAttemptStarted(1)
  let replacedPending = Task { try await writer.save(2) }
  await waitUntilAccepted(writer, count: 2)
  let newestPending = Task { try await writer.save(3) }
  await waitUntilAccepted(writer, count: 3)

  let flush = Task { try await writer.flush() }
  await waitUntilFlushBarriers(writer, count: 2)
  harness.release(attempt: 1)

  #expect(await persistenceError(from: active) == .active)
  #expect(await persistenceError(from: replacedPending) == .pending)
  #expect(await persistenceError(from: newestPending) == .pending)
  #expect(await persistenceError(from: flush) == .active)
  let idleFlushAfterFailure = Task { try await writer.flush() }
  #expect(await persistenceError(from: idleFlushAfterFailure) == .pending)

  try await writer.save(4)
  try await writer.flush()
  #expect(harness.writtenValues == [1, 3, 4])
}

@Test func coalescingWriterFlushExcludesNewIndependentPendingSave() async throws {
  let harness = ControlledPersistenceWrite(blockedAttempts: [1, 2])
  let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.flush.boundary") {
    try harness.write($0)
  }

  let first = Task { try await writer.save(1) }
  await harness.waitUntilAttemptStarted(1)

  let flushCompletion = AsyncFlag()
  let flush = Task {
    try await writer.flush()
    await flushCompletion.set()
  }
  await waitUntilFlushBarriers(writer, count: 1)

  let afterFlush = Task { try await writer.save(2) }
  await waitUntilAccepted(writer, count: 2)
  harness.release(attempt: 1)
  await harness.waitUntilAttemptStarted(2)

  #expect(await flushCompletion.waitUntilSet())
  #expect(harness.writtenValues == [1, 2])

  harness.release(attempt: 2)
  try await first.value
  try await flush.value
  try await afterFlush.value
}

@Test func coalescingWriterFlushFollowsPendingReplacementAcceptedAfterBarrier() async throws {
  let harness = ControlledPersistenceWrite(blockedAttempts: [1, 2])
  let writer = CoalescingPersistenceWriter<Int>(label: "test.persistence.flush.replacement") {
    try harness.write($0)
  }

  let active = Task { try await writer.save(1) }
  await harness.waitUntilAttemptStarted(1)
  let beforeFlush = Task { try await writer.save(2) }
  await waitUntilAccepted(writer, count: 2)

  let flushCompletion = AsyncFlag()
  let flush = Task {
    try await writer.flush()
    await flushCompletion.set()
  }
  await waitUntilFlushBarriers(writer, count: 2)

  let replacement = Task { try await writer.save(3) }
  await waitUntilAccepted(writer, count: 3)
  harness.release(attempt: 1)
  await harness.waitUntilAttemptStarted(2)

  #expect(harness.writtenValues == [1, 3])
  #expect(await flushCompletion.isSet == false)

  harness.release(attempt: 2)
  #expect(await flushCompletion.waitUntilSet())
  try await active.value
  try await beforeFlush.value
  try await replacement.value
  try await flush.value
}

@Test func coalescingWriterOwnerLifetimeDoesNotStrandSaveOrFlushWaiters() async throws {
  let harness = ControlledPersistenceWrite(blockedAttempts: [1])
  var writer: CoalescingPersistenceWriter<Int>? = CoalescingPersistenceWriter(
    label: "test.persistence.owner"
  ) {
    try harness.write($0)
  }
  weak let weakWriter = writer
  let submittedWriter = try #require(writer)

  let save = Task { try await submittedWriter.save(1) }
  await harness.waitUntilAttemptStarted(1)
  let flush = Task { try await submittedWriter.flush() }
  await waitUntilFlushBarriers(submittedWriter, count: 1)

  writer = nil
  #expect(weakWriter != nil)
  harness.release(attempt: 1)

  try await save.value
  try await flush.value
}

private enum PersistenceWriteTestError: Error, Equatable {
  case active
  case pending
}

private final class ControlledPersistenceWrite: @unchecked Sendable {
  private let lock = NSLock()
  private let gates: [Int: DispatchSemaphore]
  private let failuresByValue: [Int: PersistenceWriteTestError]
  private var attempts = 0
  private var values: [Int] = []

  init(
    blockedAttempts: Set<Int> = [],
    failuresByValue: [Int: PersistenceWriteTestError] = [:]
  ) {
    self.gates = Dictionary(
      uniqueKeysWithValues: blockedAttempts.map { ($0, DispatchSemaphore(value: 0)) }
    )
    self.failuresByValue = failuresByValue
  }

  func write(_ value: Int) throws {
    let attempt: Int
    let failure: PersistenceWriteTestError?
    lock.lock()
    attempts += 1
    attempt = attempts
    values.append(value)
    failure = failuresByValue[value]
    lock.unlock()

    gates[attempt]?.wait()
    if let failure {
      throw failure
    }
  }

  func release(attempt: Int) {
    gates[attempt]?.signal()
  }

  func waitUntilAttemptStarted(_ expected: Int) async {
    while attemptCount < expected {
      await Task.yield()
    }
  }

  var attemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return attempts
  }

  var writtenValues: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private actor AsyncFlag {
  private(set) var isSet = false

  func set() {
    isSet = true
  }

  func waitUntilSet() async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(1)
    while !isSet, clock.now < deadline {
      await Task.yield()
    }
    return isSet
  }
}

private func waitUntilAccepted(
  _ writer: CoalescingPersistenceWriter<Int>,
  count: UInt64
) async {
  while writer.acceptedSaveCount < count {
    await Task.yield()
  }
}

private func waitUntilFlushBarriers(
  _ writer: CoalescingPersistenceWriter<Int>,
  count: Int
) async {
  while writer.flushBarrierCount < count {
    await Task.yield()
  }
}

private func persistenceError(
  from task: Task<Void, Error>
) async -> PersistenceWriteTestError? {
  do {
    try await task.value
    return nil
  } catch let error as PersistenceWriteTestError {
    return error
  } catch {
    return nil
  }
}
