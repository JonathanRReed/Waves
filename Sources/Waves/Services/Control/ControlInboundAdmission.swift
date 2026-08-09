import Foundation

enum ControlInboundFrameDecision: Equatable {
  case request(ControlRequest, retainedByteCount: Int)
  case failure(id: Int?, error: ControlError, shouldClose: Bool)
}

private struct ControlAdmissionTokenBucket {
  private let capacity: Double
  private let refillPerSecond: Double
  private var tokens: Double
  private var lastRefill: TimeInterval

  init(capacity: Int, refillPerSecond: Double, now: TimeInterval) {
    self.capacity = Double(max(0, capacity))
    self.refillPerSecond = max(0, refillPerSecond)
    tokens = Double(max(0, capacity))
    lastRefill = now
  }

  mutating func allow(cost: Int, now: TimeInterval) -> Bool {
    let elapsed = max(0, now - lastRefill)
    lastRefill = now
    tokens = min(capacity, tokens + elapsed * refillPerSecond)
    let cost = Double(max(0, cost))
    guard tokens >= cost else { return false }
    tokens -= cost
    return true
  }
}

/// Charges bounded frame and byte work before JSON decoding. Malformed and
/// rate-rejected frames share one small abuse budget, so invalid JSON cannot
/// bypass admission by failing before a decoded request exists.
struct ControlInboundAdmission {
  static let byteBurst = 256 * 1024
  static let byteRefillPerSecond = 128 * 1024.0
  static let maximumAbuseStrikes = 3

  private var frameBucket: ControlAdmissionTokenBucket
  private var byteBucket: ControlAdmissionTokenBucket
  private let maximumAbuseStrikes: Int
  private var abuseStrikes = 0

  init(now: TimeInterval) {
    self.init(
      frameBurst: ControlRateLimiter.burst,
      frameRefillPerSecond: ControlRateLimiter.refillPerSecond,
      byteBurst: Self.byteBurst,
      byteRefillPerSecond: Self.byteRefillPerSecond,
      maximumAbuseStrikes: Self.maximumAbuseStrikes,
      now: now
    )
  }

  init(
    frameBurst: Int,
    frameRefillPerSecond: Double,
    byteBurst: Int,
    byteRefillPerSecond: Double,
    maximumAbuseStrikes: Int,
    now: TimeInterval
  ) {
    frameBucket = ControlAdmissionTokenBucket(
      capacity: frameBurst,
      refillPerSecond: frameRefillPerSecond,
      now: now
    )
    byteBucket = ControlAdmissionTokenBucket(
      capacity: byteBurst,
      refillPerSecond: byteRefillPerSecond,
      now: now
    )
    self.maximumAbuseStrikes = max(1, maximumAbuseStrikes)
  }

  mutating func classify(
    _ frame: Data,
    now: TimeInterval
  ) -> ControlInboundFrameDecision {
    classify(frame, now: now, decode: ControlCodec.decode)
  }

  mutating func classify(
    _ frame: Data,
    now: TimeInterval,
    decode: (Data) -> ControlRequest?
  ) -> ControlInboundFrameDecision {
    let requestID = ControlCodec.requestIDPrefix(frame)
    let frameAllowed = frameBucket.allow(cost: 1, now: now)
    let bytesAllowed = byteBucket.allow(cost: frame.count, now: now)
    guard frameAllowed, bytesAllowed else {
      return rejection(id: requestID, error: .rateLimited)
    }
    guard let request = decode(frame) else {
      return rejection(id: requestID, error: .malformedRequest)
    }
    return .request(request, retainedByteCount: frame.count)
  }

  private mutating func rejection(
    id: Int?,
    error: ControlError
  ) -> ControlInboundFrameDecision {
    abuseStrikes += 1
    return .failure(
      id: id,
      error: error,
      shouldClose: abuseStrikes >= maximumAbuseStrikes
    )
  }
}

/// Bounds decoded requests that have been admitted but not yet completed by
/// the main-actor handler. The head remains in the queue while it is active, so
/// both count and retained-frame bytes include in-flight work.
struct ControlPendingRequestQueue {
  static let maximumCount = 32
  static let maximumRetainedBytes = 256 * 1024

  private struct Entry {
    let request: ControlRequest
    let retainedByteCount: Int
  }

  private let maximumCount: Int
  private let maximumRetainedBytes: Int
  private var entries: [Entry] = []
  private(set) var retainedByteCount = 0

  init(
    maximumCount: Int = Self.maximumCount,
    maximumRetainedBytes: Int = Self.maximumRetainedBytes
  ) {
    self.maximumCount = max(0, maximumCount)
    self.maximumRetainedBytes = max(0, maximumRetainedBytes)
  }

  var count: Int { entries.count }
  var first: ControlRequest? { entries.first?.request }

  mutating func enqueue(_ request: ControlRequest, retainedByteCount: Int) -> Bool {
    let retainedByteCount = max(0, retainedByteCount)
    guard entries.count < maximumCount,
      retainedByteCount <= maximumRetainedBytes - self.retainedByteCount
    else { return false }
    entries.append(Entry(request: request, retainedByteCount: retainedByteCount))
    self.retainedByteCount += retainedByteCount
    return true
  }

  @discardableResult
  mutating func removeFirst() -> ControlRequest? {
    guard !entries.isEmpty else { return nil }
    let entry = entries.removeFirst()
    retainedByteCount -= entry.retainedByteCount
    return entry.request
  }

  mutating func removeAll() {
    entries.removeAll()
    retainedByteCount = 0
  }
}
