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

- discovers Wave Link's loopback port by asking the kernel (libproc) which TCP
  ports the code-signature-verified Wave Link 3 process is listening on. Wave
  Link 3 picks an ephemeral port on every launch (real installs have answered
  on 50845 and 53832, well outside the 1884-1893 range community clients scan)
  and the macOS location of its `ws-info.json` is undocumented, so any port a
  readable `ws-info.json` names is used only to order the candidates;
- connects only to `ws://127.0.0.1:<port>` through `URLSessionWebSocketTask`,
  and accepts a candidate only after it answers `getApplicationInfo` as Wave
  Link 3; the pid whose listener it is has already passed the designated
  requirement check;
- uses the `streamdeck://` origin expected by Wave Link, and sends an explicit
  `"params": null` for parameterless calls as the official plugin does;
- sends JSON-RPC 2.0 requests, one serialized sequence at a time (a Settings
  connection test and an apply never interleave), skipping the notifications
  Wave Link pushes on the same socket; the socket stays open for two seconds
  after a sequence so a slider drag reuses one connection, then closes while
  idle so a Wave Link restart on a new port is picked up by rediscovery;
- moves an app to an empty channel only for a user gesture. Automation
  (conferencing auto-pause) may adjust an app that already has its own channel
  and is refused otherwise, because re-routing an app inside Wave Link changes
  what the stream and monitor mixes hear;
- records a `WaveLinkBridgeStatus` (endpoint, application info, channel
  layout, last error) after every sequence, shown in Settings › Mixer with a
  read-only **Test Connection** action, in Diagnostics, and in the diagnostics
  export;
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
