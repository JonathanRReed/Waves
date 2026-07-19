import Foundation

typealias PersistenceDataWrite = @Sendable (Data, URL) throws -> Void

enum PrivateAtomicPersistenceFile {
  static func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try PersistenceSecurity.setPrivateFilePermissions(url)
  }
}

/// Serializes full-value persistence while retaining only the newest payload
/// waiting behind an active write. Every caller whose value is replaced waits
/// for that newest replacement, because supported stores write complete values.
final class CoalescingPersistenceWriter<Value: Sendable>: @unchecked Sendable {
  typealias WriteOperation = @Sendable (Value) throws -> Void

  private final class FlushWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingWrites: Int
    private var firstError: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(writeCount: Int, continuation: CheckedContinuation<Void, Error>) {
      self.remainingWrites = writeCount
      self.continuation = continuation
    }

    func writeCompleted(with result: Result<Void, Error>) {
      let resolution: (CheckedContinuation<Void, Error>, Result<Void, Error>)?

      lock.lock()
      if case .failure(let error) = result, firstError == nil {
        firstError = error
      }
      remainingWrites -= 1
      if remainingWrites == 0, let continuation {
        self.continuation = nil
        resolution = (continuation, firstError.map(Result.failure) ?? .success(()))
      } else {
        resolution = nil
      }
      lock.unlock()

      if let resolution {
        resolution.0.resume(with: resolution.1)
      }
    }
  }

  private struct PendingWrite {
    let id: UInt64
    var value: Value
    var saveWaiters: [CheckedContinuation<Void, Error>]
    var flushWaiters: [FlushWaiter]
  }

  private let queue: DispatchQueue
  private let write: WriteOperation
  private let lock = NSLock()
  private var active: PendingWrite?
  private var pending: PendingWrite?
  private var nextWriteID: UInt64 = 0
  private var acceptedSaves: UInt64 = 0
  // The newest completed full-value write defines recovered/failed idle state.
  // Flushes issued while idle surface that result; a later successful save
  // replaces an earlier failure and restores successful flush behavior.
  private var lastCompletedResult: Result<Void, Error>?

  init(label: String, qos: DispatchQoS = .userInitiated, write: @escaping WriteOperation) {
    self.queue = DispatchQueue(label: label, qos: qos)
    self.write = write
  }

  init(queue: DispatchQueue, write: @escaping WriteOperation) {
    self.queue = queue
    self.write = write
  }

  /// Completes when `value`, or a newer full-value replacement coalesced over it,
  /// has finished its durable write. A failed write fails every waiter represented
  /// by that write; a later save starts or joins fresh work and can recover.
  func save(_ value: Value) async throws {
    try await withCheckedThrowingContinuation { continuation in
      enqueue(value, waiter: continuation)
    }
  }

  /// Waits asynchronously for every write representing values accepted before
  /// this call. A later save is excluded unless it replaces a pending value that
  /// this flush already needs; in that case the replacement is the durable value
  /// that satisfies the earlier save and therefore also satisfies the flush. An
  /// idle flush reports the newest completed write result until a later save
  /// succeeds and establishes recovery.
  func flush() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      let writeCount = (active == nil ? 0 : 1) + (pending == nil ? 0 : 1)
      guard writeCount > 0 else {
        let result = lastCompletedResult ?? .success(())
        lock.unlock()
        continuation.resume(with: result)
        return
      }

      let waiter = FlushWaiter(writeCount: writeCount, continuation: continuation)
      active?.flushWaiters.append(waiter)
      pending?.flushWaiters.append(waiter)
      lock.unlock()
    }
  }

  /// Monotonic acceptance count used by focused concurrency tests.
  var acceptedSaveCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return acceptedSaves
  }

  /// Number of active/pending write batches currently carrying a flush barrier.
  var flushBarrierCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return (active?.flushWaiters.count ?? 0) + (pending?.flushWaiters.count ?? 0)
  }

  private func enqueue(_ value: Value, waiter: CheckedContinuation<Void, Error>) {
    let shouldStart: Bool

    lock.lock()
    acceptedSaves &+= 1
    if var pending {
      pending.value = value
      pending.saveWaiters.append(waiter)
      self.pending = pending
      shouldStart = false
    } else if active != nil {
      nextWriteID &+= 1
      pending = PendingWrite(
        id: nextWriteID,
        value: value,
        saveWaiters: [waiter],
        flushWaiters: []
      )
      shouldStart = false
    } else {
      nextWriteID &+= 1
      active = PendingWrite(
        id: nextWriteID,
        value: value,
        saveWaiters: [waiter],
        flushWaiters: []
      )
      shouldStart = true
    }
    lock.unlock()

    if shouldStart {
      // Capture strongly until the drain reaches an idle state. A store owner can
      // disappear while callers are suspended without abandoning continuations.
      queue.async { self.drain() }
    }
  }

  private func drain() {
    while true {
      let writeID: UInt64
      let value: Value

      lock.lock()
      guard let current = active else {
        lock.unlock()
        return
      }
      writeID = current.id
      value = current.value
      lock.unlock()

      let result = Result { try write(value) }

      let completed: PendingWrite
      let shouldContinue: Bool
      lock.lock()
      guard let completedActive = active, completedActive.id == writeID else {
        lock.unlock()
        preconditionFailure("Persistence writer active batch changed during a write")
      }
      completed = completedActive
      lastCompletedResult = result
      self.active = pending
      pending = nil
      shouldContinue = self.active != nil
      lock.unlock()

      for waiter in completed.saveWaiters {
        waiter.resume(with: result)
      }
      for waiter in completed.flushWaiters {
        waiter.writeCompleted(with: result)
      }

      if !shouldContinue {
        return
      }
    }
  }
}
