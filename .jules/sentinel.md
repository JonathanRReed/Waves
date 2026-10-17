## 2025-05-18 - Non-Finite Float Clamping Bypass in Model Initializers
**Vulnerability:** In IEEE 754 arithmetic in Swift, `max(a, min(b, Float.nan))` evaluates to `NaN`. Initializers that rely solely on `max`/`min` for range clamping allow `NaN` and `Infinity` to bypass clamping logic and leak into model state. When converting `NaN` volume floats to `Int` for UI percentage labels, Swift throws a fatal runtime exception.
**Learning:** `max`/`min` operations do not guard against `NaN` because floating-point comparisons with `NaN` evaluate to false.
**Prevention:** Always check `value.isFinite` before applying `max`/`min` clamping when accepting floating-point inputs in initializers and decoders.

## 2025-05-19 - Floating-Point Integer Conversion Fatal Trap in JSON Formatting
**Vulnerability:** In Swift, checking `number.rounded(.towardZero) == number` before casting `Int64(number)` fails to prevent fatal overflow traps when `number` exceeds `Int64.max` (e.g. `1e20`). When formatting large numbers in JSON responses, `Int64(number)` crashes the process.
**Learning:** `number.rounded(.towardZero) == number` evaluates to `true` for integer-valued `Double`s of any magnitude, but `Int64(number)` panics if the number is out of `Int64` bounds.
**Prevention:** Always use `Int64(exactly: number)` to safely attempt exact integer conversion without runtime panics.

## Token Bucket Rate Limiter Non-Finite Timestamp Guarding
**Vulnerability:** In Swift token-bucket rate limiters taking `TimeInterval` inputs, non-finite values (`NaN` or `Infinity`) cause `now - lastRefill` to evaluate to `NaN` or `Infinity`. Arithmetic with `NaN` converts `tokens` to `NaN`, permanently corrupting the bucket state and locking out all subsequent requests on that connection.
**Learning:** `max(0, Double.nan)` evaluates to `NaN` in Swift, propagating through token calculations and permanently corrupting state. Defensive hardening protects internal bucket calculations from non-finite time inputs.
**Prevention:** Always check `now.isFinite` and `elapsed.isFinite` before performing token bucket calculations with `TimeInterval` timestamps.

## 2025-05-20 - Unbounded C String Conversion on proc_pidpath Buffers
**Vulnerability:** `proc_pidpath` populates a stack CChar buffer without null-terminating if the path length meets or exceeds the buffer capacity. Calling `String(cString:)` on a non-null-terminated buffer causes an out-of-bounds stack memory overread.
**Learning:** `proc_pidpath` returns the number of bytes written. If `length >= bufferSize`, the buffer is truncated and lacks a null-terminator byte.
**Prevention:** Always check `Int(length) < bufferSize` before passing fixed CChar buffers filled by `proc_pidpath` to `String(cString:)`.
