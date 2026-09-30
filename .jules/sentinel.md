## 2025-05-18 - Non-Finite Float Clamping Bypass in Model Initializers
**Vulnerability:** In IEEE 754 arithmetic in Swift, `max(a, min(b, Float.nan))` evaluates to `NaN`. Initializers that rely solely on `max`/`min` for range clamping allow `NaN` and `Infinity` to bypass clamping logic and leak into model state. When converting `NaN` volume floats to `Int` for UI percentage labels, Swift throws a fatal runtime exception.
**Learning:** `max`/`min` operations do not guard against `NaN` because floating-point comparisons with `NaN` evaluate to false.
**Prevention:** Always check `value.isFinite` before applying `max`/`min` clamping when accepting floating-point inputs in initializers and decoders.

## 2025-05-19 - Floating-Point Integer Conversion Fatal Trap in JSON Formatting
**Vulnerability:** In Swift, checking `number.rounded(.towardZero) == number` before casting `Int64(number)` fails to prevent fatal overflow traps when `number` exceeds `Int64.max` (e.g. `1e20`). When formatting large numbers in JSON responses, `Int64(number)` crashes the process.
**Learning:** `number.rounded(.towardZero) == number` evaluates to `true` for integer-valued `Double`s of any magnitude, but `Int64(number)` panics if the number is out of `Int64` bounds.
**Prevention:** Always use `Int64(exactly: number)` to safely attempt exact integer conversion without runtime panics.
