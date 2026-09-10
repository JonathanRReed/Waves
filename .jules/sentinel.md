## 2025-05-18 - Input Validation for Floating-Point Socket Commands
**Vulnerability:** Non-finite floating-point numbers (`NaN`, `Infinity`) received over IPC/control sockets could bypass numeric range checks or cause undefined behavior when passed to audio state clamping functions (`max(0, min(1, volume))`).
**Learning:** Decoded `Float` parameters from JSON RPC/socket payloads can contain `NaN` or non-finite values if a custom encoder or raw payload passes non-standard values or special JSON numeric strings.
**Prevention:** Always validate floating point parameters with `.isFinite` before applying arithmetic or clamping operations.
