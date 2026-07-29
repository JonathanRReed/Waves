import AudioToolbox

/// Decides whether a managed route is still rendering, from the IO-render
/// callback counts observed across successive level polls.
///
/// This exists as its own pure type because the rule it encodes is subtle and
/// was got wrong once, expensively. Through 1.3.0 a route was judged dead when
/// its measured *level* stayed near zero for six seconds — but an app can hold
/// its output IO open and emit digital silence indefinitely: a call with nobody
/// talking, a stream between cues, a paused game, a DAW on a quiet bar. Those
/// routes were torn down and rebuilt every six seconds for as long as the app
/// ran, with an audible dropout each time.
///
/// The rule now: liveness is whether the IO proc *ran*, never how loud it was.
enum RouteLivenessJudgment {
  /// Whether the route produced at least one IO callback since the last poll.
  ///
  /// The first observation always reports rendering: a single sample cannot
  /// prove absence, and the caller needs a baseline before it can compare. That
  /// deliberately biases toward a false "alive" for exactly one poll, because
  /// the cost of a wrong "dead" is destroying and rebuilding a working route,
  /// while the cost of a wrong "alive" is one extra 250 ms poll before the
  /// count starts.
  static func isRendering(currentTick: UInt64, previousTick: UInt64?) -> Bool {
    guard let previousTick else { return true }
    return currentTick != previousTick
  }
}
