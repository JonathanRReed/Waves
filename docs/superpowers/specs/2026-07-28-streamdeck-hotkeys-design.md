# Waves 1.4 — External Control, Per-App Mute Hotkeys, and a Stream Deck Plugin

Date: 2026-07-28
Status: historical design with implemented Waves-side and companion work
Baseline: `95a43d8` (Waves 1.3.1)

> Historical design record. The body below preserves the original 1.4 proposal,
> including its old version targets, implementation order, and tool assumptions.
> Use the current-status section for 1.5 truth.

## Current status on 2026-08-09

- Waves 1.5.0 build 13 implements the same-user Unix socket, protocol version 1,
  complete bounded replies, subscriptions, `wavesctl`, and app-specific hotkeys.
- External control and URL automation remain separate opt-ins. Both default to
  off. The socket is local to the current macOS user and is not a network API.
- The Stream Deck companion is a separately versioned Bun project at
  `/Users/jonathanreed/Downloads/waves-streamdeck`. It is not bundled in the
  Waves app or DMG.
- Wave Link audio coexistence belongs to Waves. The companion can act only on
  routes Waves reports as managed, and it cannot override a Wave Link handoff.
- Companion typecheck, unit, validator, package, and live packaged-socket tests
  are required for the 1.5 candidate. Remote Wave Link and physical Stream Deck
  hardware validation is still unverified and remains a hard publication gate.
- Marketplace submission and App Intents are not part of Waves 1.5.

## Why

Waves can already do everything a hardware mixer would ask of it — per-app volume,
mute, boost, routing — but only through its own windows. Two gaps follow from
that:

1. There is no way to reach a **specific** app without looking at the screen.
   Every keyboard shortcut today acts on the *frontmost* app, which is exactly
   the app you do not need a shortcut for.
2. There is no way for anything outside Waves to read or change state. The URL
   scheme fires commands one way and answers nothing, so no external surface can
   show whether an app is muted.

This release closes both, and takes a hard efficiency and craft pass over the
existing app while it does. The efficiency work is the point, not a side effect:
1.3.1 fixed a runaway, but "not broken" is not the same as "fast".

## Goals

- Twist a dial on a Stream Deck + to change one specific app's volume, and have
  it feel like a hardware knob.
- Press a key to mute one specific app, and see its real mute state on the key.
- Press a keyboard shortcut to mute one specific app, with no shortcut assigned
  by default.
- Make the app measurably faster and lighter at launch, at idle, and under the
  hand.
- Regress nothing.

## Non-goals

- Stream Deck Marketplace submission. The manifest will conform so it stays
  possible, but distribution here is `streamdeck pack` and a local install.
- Windows support for the plugin. The plugin talks to a macOS-only app.
- Remote or network control. The control surface is same-machine, same-user only,
  by construction.
- Any redesign of the mixer's visual language. The craft work is consistency and
  defect removal, not restyling.

## Track A — Control surface

### Transport

A Unix domain socket at `~/Library/Application Support/Waves/control.sock`, mode
`0600`, inside the existing `0700` support directory.

Chosen over a loopback HTTP/WebSocket server because:

- **Latency.** A dial emits a stream of rotate events; a socket write is
  sub-millisecond. This is the difference between a knob and a laggy slider.
- **Attack surface.** No TCP port means nothing on the network can reach it, no
  macOS firewall prompt, no port collisions, and — importantly — no web page in
  a browser can POST to it, which is a real hazard for `127.0.0.1` servers.
- **Authorization for free.** Filesystem permissions already restrict access to
  the same user. As defence in depth the server also verifies the peer's uid via
  `getpeereid` and drops any connection whose uid differs from its own.

Rejected: extending the URL scheme. Each command would be an `open waves://…`
process spawn (~100 ms) with no push channel, so dials would be unusable and key
state would have to be polled from a file.

### Protocol

Newline-delimited JSON, one object per line, UTF-8. Requests carry a client-chosen
`id`; responses echo it. Unsolicited server pushes carry `event` and no `id`.

```
→ {"id":1,"cmd":"hello","client":"streamdeck","protocol":1}
← {"id":1,"ok":true,"protocol":1,"app":"1.4.0","build":"8"}

→ {"id":2,"cmd":"list-apps"}
← {"id":2,"ok":true,"apps":[
     {"id":"com.spotify.client","name":"Spotify","running":true,
      "muted":false,"volume":0.80,"live":true,"managed":true}]}

→ {"id":3,"cmd":"adjust-volume","app":"com.spotify.client","delta":-0.02}
← {"id":3,"ok":true,"volume":0.78}

→ {"id":4,"cmd":"subscribe"}
← {"id":4,"ok":true}
← {"event":"app-changed","app":{"id":"com.spotify.client","muted":true,…}}
← {"event":"apps-changed"}

← {"id":9,"ok":false,"error":"unknown-app","message":"No app with that identifier."}
```

Commands: `hello`, `list-apps`, `get-icon`, `set-volume`, `adjust-volume`,
`set-mute`, `toggle-mute`, `subscribe`, `unsubscribe`.

Design notes that matter:

- **`adjust-volume` takes a delta, not an absolute.** A dial should never have to
  read-then-write; that races itself on a fast twist and overshoots. Waves owns
  clamping to `0…1` and returns the resulting value.
- **`get-icon` is separate from `list-apps`.** Icons are the heaviest field, and
  a client needs them once per app, not on every list. Returns a base64 PNG at a
  fixed size; the client caches by app id.
- **Protocol version is explicit** and checked in `hello`. A client speaking a
  version the app does not support gets a clean refusal, not a mystery.
- **Identifiers are `logicalID`**, the same stable key Waves persists everywhere
  else, so a binding survives the app quitting and relaunching.

### Security and limits

- Off by default, behind a new `enableExternalControl` preference, mirroring the
  existing `enableURLScheme` gate. A client that connects while disabled gets a
  refusal explaining where to turn it on, so the plugin can say something useful
  rather than appearing broken.
- Peer uid verified on accept.
- Per-line size cap and a per-connection rate limit, reusing the shape of the
  URL scheme's existing limiter.
- Connection cap, so a misbehaving client cannot exhaust descriptors.
- The socket is unlinked on shutdown, and a stale socket file from a crash is
  detected and replaced rather than aborting startup.
- No command can read arbitrary state: the surface is exactly the nine commands
  above, and no path, file, or shell input is ever accepted.

### Lifecycle

Created when the preference is on and the backend is running; torn down when
either stops. Clients see a clean EOF and reconnect with backoff.

## Track B — Per-app mute hotkeys

### Mechanism change

Replace `NSEvent.addGlobalMonitorForEvents` with Carbon `RegisterEventHotKey`.

This is a defect fix, not a preference. Today's global monitor:

- **Cannot consume the event.** ⌘⌥M mutes the frontmost app *and* the keystroke
  still reaches that app. Carbon hotkeys consume.
- **Requires Accessibility permission** for keyDown monitoring. Carbon hotkeys do
  not, so a permission prompt disappears from the product.
- **Cannot detect conflicts.** `RegisterEventHotKey` fails when a chord is already
  claimed, so Waves can say "⌘⌥⇧S is already in use" the moment you record it,
  instead of silently never firing.

### Model

```swift
struct HotkeyBinding: Codable, Hashable, Identifiable {
  var id: UUID
  var action: HotkeyAction     // .muteApp(logicalID) | .frontmostMute | .frontmostVolumeUp/Down
  var keyCode: UInt16
  var modifiers: NSEvent.ModifierFlags
}
```

Persisted in `UserPreferences`. Per-app mute bindings start **empty** — nothing is
assigned by default, so the app claims no chords the user did not choose, and
Raycast/Karabiner hyper setups compose freely.

The three existing frontmost shortcuts (⌘⌥↑, ⌘⌥↓, ⌘⌥M) are migrated into this
model as pre-filled bindings, editable and clearable. Removing them outright
would silently break shortcuts documented in Help and relied on today.

### Interface

- **Settings ▸ Shortcuts**: the binding list, each row a recorder. An "Add app
  shortcut" control picks an app from the same roster the mixer shows.
- **Mixer row context menu**: "Assign Mute Shortcut…" jumps straight to that app's
  recorder, because that is where the thought occurs.
- Recording accepts any modifier combination including full hyper. A chord that
  fails to register shows an inline explanation on the row.
- Duplicate chords inside Waves are rejected before registration with a pointer
  to the binding that owns it.

## Track C — Stream Deck plugin

### Layout

```
streamdeck/
  com.jonathanreed.waves.sdPlugin/
    manifest.json
    bin/plugin.js            # rollup output
    imgs/                    # action + key + touch icons
    ui/mute.html             # property inspectors
    ui/volume.html
  src/
    plugin.ts
    waves-client.ts          # socket client: framing, reconnect, subscription
    actions/mute-app.ts
    actions/app-volume.ts
  package.json
  rollup.config.mjs
```

Requirements from the current SDK: Node 24+, Stream Deck 7.1+,
`@elgato/streamdeck` v2+, `SDKVersion: 3`. UUIDs are lowercase reverse-DNS, and
`Version` is four-part `{major}.{minor}.{patch}.{build}`.

### Actions

**`com.jonathanreed.waves.mute-app`** — `Controllers: ["Keypad"]`, two states.

- `onKeyDown` → `toggle-mute`.
- Key image is the app's icon, drawn with a muted treatment in state 1 and dimmed
  when the app is not running.
- Reflects state pushed from Waves, so muting in the app updates the key.

**`com.jonathanreed.waves.app-volume`** — `Controllers: ["Encoder", "Keypad"]`.

- `onDialRotate` → `adjust-volume` with `delta = ticks × step`. Default step 2%.
  When `payload.pressed` is true, step drops to 0.5% — rotate-while-pressed is
  fine adjustment, which costs nothing and feels considered.
- `onDialDown` / `onTouchTap` → `toggle-mute`.
- Touch strip uses the built-in `$B1` layout: app name as title, the app icon,
  the percentage as value, and the bar as the indicator.
- As a Keypad it behaves as a volume nudge, so the action is usable on an MK.2.

### Property Inspector

Uses `sdpi-components`' data source mechanism, which exists for exactly this:

```html
<sdpi-item label="App">
  <sdpi-select setting="appID" datasource="getApps"
               loading="Asking Waves…" hot-reload></sdpi-select>
</sdpi-item>
```

The component asks the plugin for `getApps`; the plugin asks Waves `list-apps`
and replies via `sendToPropertyInspector` with `{value, label}` items. Running
apps are listed first, remembered-but-closed apps below, so a binding can be made
for an app that is not open right now.

### Degraded states

The plugin must be honest rather than dead when Waves is not cooperating. Three
distinct cases, three distinct key treatments and Property Inspector messages:

1. **Waves not running** — key dimmed, "Waves isn't running".
2. **External control disabled** — key dimmed, "Turn on external control in
   Waves ▸ Settings ▸ Shortcuts & Automation". This is the first-run case and must not look
   like a bug.
3. **Bound app not running** — key shows the app icon dimmed; a press shows an
   alert rather than silently doing nothing.

Reconnection uses capped exponential backoff, so a quit-and-relaunched Waves
reconnects on its own.

## Track D — Snow Leopard pass

An efficiency and craft audit against this baseline confirmed 28 improvements
(rejecting 12) and produced a 43-entry inventory of user-facing capabilities. The
work below is grouped by what a user would actually notice. Every item has a
mechanism and a magnitude; none is a restyling opinion.

### D1 — Launch feel

**The first frame is wrong for returning users.** `startupState` begins `.idle`,
which maps to `.startingAudio` whenever privacy setup is complete, so
`primarySurface` paints `PrivacySetupSurface` — a full-window "Starting Waves"
splash with a spinner — as the first frame of a 980×620 window. Meanwhile the
previous session (37 apps on this machine) has *already been loaded synchronously*
in `AppStore.init`. `store.start()` only runs from `.task`, i.e. after that frame.
When it completes, the surface swaps to `NavigationSplitView` — a full view-identity
change plus toolbar population, not a crossfade.

So the app makes the user watch a splash while the data it needs is already in
memory. Fix: render the mixer immediately when there is a restored session and
privacy/guided setup are complete, reserving the splash for genuinely blocked
states. Two consequences must be handled or the fix trades a splash for a lie:
`isLoading` is false on exactly this path, so the existing "Refreshing" pill must
be gated on `store.isLoading || !store.isAudioRunning`; and rows are read-only
until `startupState == .running`, so controls need dimming rather than firing a
"Finish setup" toast on an early click.

**Managed routes are rebuilt serially before the mixer is usable.**
`reapplyRestoredAudioState` creates a process tap *and* a private aggregate device
per configured app, one after another, inside startup. Make it concurrent and move
it off the gate.

**Every launch re-encodes ~40 icons** through a `lockFocus` + TIFF round-trip.
1.3.1 stopped re-encoding on each 8 s rebuild by carrying icons forward, but the
first pass still pays for all of them. Cache to disk keyed by bundle id + mtime.

**Diagnostics, capture authorization, and full device enumeration all complete
before the mixer is un-gated.** None is needed to show a mixer; defer them.

### D2 — Direct manipulation

**The volume slider sends nothing to the backend until you let go.** `setDesiredVolume`
only writes an optimistic projection; the sole path to a real transaction is
`commitDesiredVolume`, wired to `onEditingChanged(false)`. The DSP gain therefore
does not move until mouse-up — the audio *jumps* at the end of a drag instead of
following the handle. This is the single worst "feel" defect in the app, and the
EQ already does it correctly with an 80 ms trailing debounce.

Fix by mirroring `scheduleEqualizerTransaction`: a debounced intermediate
transaction with `persistencePolicy: .none`, leaving `commitDesiredVolume` as the
only persisting, toast-bearing boundary. Two hazards the implementation must
respect: intermediate applies must never take the branch that rebuilds a tap
(a helper process appearing mid-drag would otherwise cause an audible dropout), and
the new debounce tasks must join `drainAppIntentTransactions` or the transaction
tests will race.

**Profile apply is the only user-facing control with no optimistic projection** —
every other control updates instantly and reconciles.

**Opening the menu-bar panel waits a full poll interval** before showing fresh
levels. Kick a poll on open.

### D3 — Theme and craft

**The signature waveform ignores the theme entirely.** `MixedWaveformView` reads
`reduceMotion`, `colorSchemeContrast` and `renderCadence` — but never
`\.wavesTheme`. Every colour is a compile-time constant. Since `appearance`
defaults to `.system`, a user on macOS Light hits this with no opt-in: the resting
baseline is white at 10% over a near-white surface, about **1.0:1 contrast — it is
invisible**, and the live sum only reaches ~1.13:1. Increase Contrast lifts the
baseline to 28% white, which is still ~1.0:1. On Graphite it is worse than
invisible: a hardcoded cyan waveform sits 40 pt above a row meter that correctly
reads `theme.accentGradientColors`.

This is the app's signature surface, broken by default, and it is the highest-value
craft fix in the release.

**Four surfaces hardcode white/black opacities** instead of theme tokens and
invert in Light appearance.

**Motion is inconsistent** in ways that read as unfinished: the main window's
mixer list snaps rows in and out while the menu bar's identical list eases them;
menu-bar rows animate out but their containing section pops; EQ scope chips reflow
the row unanimated. **Exactly one control in the app has a hover state**, and the
row documented as its twin has none. **The hover highlight and the selection
highlight are the same colour.** Toolbar items shift horizontally when refresh
spins or Reset Mix appears — fix with a fixed-width slot and monospaced digits.

### D4 — Steady-state cost

**`visibleApps` is re-derived about 11× per body pass**, each time filtering,
mapping and sorting. `invalidateVisibleAppsCache()` is still an explicit no-op.
A real cache is now warranted, with a precisely enumerated invalidation set — a
wrong cache is worse than none, which is why this was left alone before.

**`displayNameSortKey` re-runs ICU folding for every app on every read.** Fold
once and store the key on the app.

**The accessibility rotor derives the whole sorted list once per app** — N nested
derivations per body pass.

**The 8 s maintenance tick writes four `@Observable` properties unconditionally**,
invalidating SwiftUI for no visual change, and **rewrites `session.json`
atomically every 8 seconds** whether anything changed or not. Both should be
change-gated.

**The capture-authorization probe still creates and destroys a system-wide process
tap twice every 8 s when nothing is routed.** 1.3.1's early-out requires an active
controller, so the idle case — the common one — is unprotected.

### D5 — Memory

**`AppIconCache` has no `countLimit`, no `totalCostLimit`, no cost function, and
never evicts icons for apps that have quit.** **`iconTIFFData` is part of
`AudioApp`'s `Codable` surface**, kept off disk only by one hand-written mapping —
one careless change would start persisting icon blobs into `session.json`.

### D6 — Carried forward from 1.3.1

1. **Prune dead Core Audio object IDs** from `targetProcessObjectIDs`, reworking
   `matches` and `covers` together so pruning cannot cause spurious rebuilds.
2. **Unify persistence store names** and dedupe at the reporting boundary, so one
   failed store stops being counted twice.
3. **Bound the synchronous shutdown-report write** with a deadline. It stays
   synchronous — async races process teardown, which is how the original detail
   was lost.
4. **Tear down stores in test fixtures**, which leak level-poll loops.
5. **Cover `LevelMeterModel`'s ballistics.**

## Implementation order

Four tracks is too much for one plan. They decompose cleanly, and the ordering is
forced by real dependencies rather than preference:

1. **Track D (polish) first.** It touches the code the other tracks build on, and
   it is the only track with no new surface area. Landing it first means the new
   features are written against the cleaned-up code rather than merged into it,
   and any regression it causes is isolated from the feature work.
2. **Track A (control surface) second.** Everything external depends on it.
3. **Track B (hotkeys) third.** Independent of A in mechanism, but it shares the
   "address one specific app durably" model, so it benefits from A's identifier
   decisions being settled.
4. **Track C (plugin) last.** It is the only track that cannot be fully verified
   on this machine, so it should sit on top of a foundation already proven by
   `wavesctl` and the test suite.

Each track gets its own implementation plan and its own commit series. A track is
done when the suite is green, the feature inventory is unchanged, and — for A and
B — the behaviour is demonstrable from Terminal without a Stream Deck.

## Error handling

- **Protocol**: every failure is a structured `{ok:false,error,message}` with a
  stable machine-readable `error` code. Malformed input is refused without
  disturbing the connection; oversized input closes it.
- **Hotkeys**: registration failure is surfaced on the binding row, never silent.
- **Plugin**: every command has a timeout; a timeout shows an alert on the key
  rather than leaving it stale.
- **Audio**: no control-surface command may bypass the existing intent/generation
  machinery. Commands go through the same `AppStore` entry points the UI uses, so
  optimistic projection, persistence, and route recovery behave identically
  whether a change came from a dial or a mouse.

## Testing

Because the hardware is on another machine, the plan is built so Waves' side is
provable without it.

- **`wavesctl`** — a small CLI that speaks the protocol, shipped in the repo. It
  makes the whole surface exercisable from Terminal, and is the first thing to run
  tomorrow: it isolates "Waves works" from "the plugin works".
- **Protocol tests** — encode/decode, unknown commands, oversized lines, rate
  limiting, version mismatch, uid rejection, stale socket recovery. No sockets
  needed for most: the codec and command handler are pure.
- **Hotkey tests** — binding model, conflict detection, persistence round trip,
  migration of the three legacy shortcuts.
- **Plugin tests** — the socket client's framing, reconnect and backoff, against a
  fake server. Node's test runner; no Stream Deck required.
- **Regression guard** — [the feature inventory](2026-07-28-feature-inventory.md)
  lists all 43 user-facing capabilities with, for each, what a user loses if it
  silently breaks and a concrete way to prove it still works. Nothing in it may
  change behaviour. Track D in particular must be checked against it, because
  that track edits working code for no functional reason.
- **Mutation testing** for the load-bearing new tests, as used at 1.3.1:
  reintroduce the bug, confirm the test fails.

## Release

Version `1.4.0`, build `8`. New user-facing capability, so a minor bump rather
than a patch. Build number bumped in both `script/build_and_run.sh` and
`.github/workflows/release.yml`, which the release workflow now cross-checks.

The plugin versions independently (`1.0.0.0`) and ships as a
`.streamDeckPlugin` produced by `streamdeck pack`.

## Risks

- **Untestable against hardware until the owner's other machine is available.**
  Mitigated by `wavesctl`, by fake-server tests for the plugin client, and by
  keeping every Waves-side behaviour provable in the suite.
- **Carbon hotkey migration changes existing behaviour.** Mitigated by migrating
  the three current shortcuts rather than dropping them, and by testing the
  migration explicitly.
- **A control socket is new attack surface.** Mitigated by default-off, `0600`,
  uid verification, a nine-command surface with no file or shell input, size
  caps, and rate limiting.
- **Polish work touches code that just stabilised.** Mitigated by requiring a
  mechanism and magnitude per change, the feature-inventory checklist, and the
  existing 272-test suite as the floor.

## References

- Dials & Touch Strip — https://docs.elgato.com/streamdeck/sdk/guides/dials/
- Manifest reference — https://docs.elgato.com/streamdeck/sdk/references/manifest/
- Plugin events/commands — https://docs.elgato.com/streamdeck/sdk/references/websocket/plugin/
- Distribution — https://docs.elgato.com/streamdeck/sdk/introduction/distribution/
- SDK repository — https://github.com/elgatosf/streamdeck
- sdpi-components data source — https://sdpi-components.dev/docs/helpers/data-source
