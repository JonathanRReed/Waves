# Wave Link Controller and Compatibility Design

## Goal

Let Waves and Elgato Wave Link run together without duplicate or bypass audio.
Waves remains the preferred per-app interface. Wave Link remains the audio owner
for effects, Stream Deck integration, monitor routing, and stream mixes whenever
Wave Link compatibility is enabled and verified Wave Link audio is active.

## Nonnegotiable Invariant

Compatibility mode permits only one process-tap owner.

When a signed, supported Wave Link process owns active Core Audio output, Waves
must not create, retain, recover, or rebuild a per-app process tap for any
ordinary app. This rule applies before an app begins playing and does not depend
on the app row PID, browser helper layout, bundle nesting, or readable Wave Link
tap membership.

This conservative rule closes the idle-to-playing race that allowed browser and
Electron helpers to become audible through two renderers.

## Settings

Settings > Mixer contains a Wave Link section with:

- **Wave Link compatibility**, enabled by default.
- **Per-app controller**, with Waves as the default and Elgato Wave Link as the
  alternative.

Changing either setting persists immediately and reconciles managed routes.

## Waves Controller Through Wave Link

When compatibility and the Waves controller are both selected, Waves controls
Wave Link instead of creating a second Core Audio tap.

The bridge:

- discovers Wave Link's loopback port from `ws-info.json` (Wave Link 3 picks a
  new port on every launch and publishes it there), falling back to scanning
  the documented 1884-1893 range;
- connects only to `ws://127.0.0.1:<port>` through `URLSessionWebSocketTask`,
  and only after `lsof` proves the port's listener is the signed Wave Link
  process;
- uses the `streamdeck://` origin expected by Wave Link;
- sends JSON-RPC 2.0 requests, one serialized apply sequence at a time, and
  closes the socket after each sequence;
- requires `getApplicationInfo` to return `appID = EWL` and
  `interfaceRevision >= 1` (the value Wave Link 3.0-3.2 report; earlier Wave
  Link generations answer `egwl` with a different protocol and are rejected)
  before any mutation;
- uses `getChannels` to match an exact app bundle identifier to a software
  channel;
- uses `setChannel` for volume and mute;
- may use `addToChannel` only to move an exact app bundle identifier to an empty
  software channel;
- reads channels again after mutation and reports success only when the requested
  state is confirmed.

A channel is safe for per-app control only when it contains exactly one app.
Waves may move an app to an empty software channel to establish that condition.
If no unique or empty channel exists, the bridge fails closed. Waves leaves the
app monitoring-only, creates no process tap, and explains that a dedicated Wave
Link software channel is required.

Boost, per-app EQ, and per-app output-device routing are unavailable for a
bridge-managed app because Wave Link's channel protocol does not provide those
Waves DSP stages. The interface must describe that limitation instead of
claiming they were applied.

## Wave Link Controller

When Elgato Wave Link is selected, ordinary apps remain monitoring-only in
Waves. Volume, mute, effects, and mix changes happen in Wave Link.

## Legacy Wave Link Generations

Wave Link 1.x and 2.x ship as `com.elgato.WaveLink` under the same Elgato team
and are verified with their own descriptor. While a verified legacy Wave Link
owns output, ordinary apps receive the same monitoring-only protection, but the
bridge is never attempted: the legacy loopback protocol (`egwl`, integer
levels, different method names) predates the channel contract, so volume and
mute stay in Wave Link itself.

## Compatibility Disabled

When compatibility is disabled, Waves bypasses Wave Link-specific ownership and
mixed-output safeguards. This is an expert escape hatch for a custom signal
path. The interface warns that duplicate or silent audio can result.

## Mixed Output

Waves never wraps Wave Link's mixed output while compatibility is enabled. A
nested route could duplicate, mute, or feed back the entire mix.

## Failure Behavior

The bridge never falls back to a Waves process tap after a connection, protocol,
mapping, timeout, or confirmation failure. Failures leave the route
monitoring-only. Disabling compatibility is the only explicit way to restore the
old unmanaged coexistence behavior.

## Verification

Tests cover:

- verified Wave Link activity yielding idle and active apps before tap creation;
- browser, Electron, helper, and ordinary rows receiving the same global
  ownership decision;
- Wave Link mixed-output exclusion;
- JSON-RPC handshake validation;
- exact bundle-to-channel matching;
- unique-channel volume and mute updates;
- empty-channel assignment;
- shared-channel and protocol failures remaining monitoring-only;
- compatibility opt-out reclaiming Waves routes;
- no controller factory call while verified Wave Link ownership is active.
