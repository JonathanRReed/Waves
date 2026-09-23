## 2025-05-18 - Non-Finite Float Clamping Bypass in Model Initializers
**Vulnerability:** In IEEE 754 arithmetic in Swift, `max(a, min(b, Float.nan))` evaluates to `NaN`. Initializers that rely solely on `max`/`min` for range clamping allow `NaN` and `Infinity` to bypass clamping logic and leak into model state. When converting `NaN` volume floats to `Int` for UI percentage labels, Swift throws a fatal runtime exception.
**Learning:** `max`/`min` operations do not guard against `NaN` because floating-point comparisons with `NaN` evaluate to false.
**Prevention:** Always check `value.isFinite` before applying `max`/`min` clamping when accepting floating-point inputs in initializers and decoders.
