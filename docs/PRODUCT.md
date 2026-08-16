# Product

Waves is a native macOS per-app audio mixer that gives every running app its own
volume, mute, boost, and equalizer, plus optional adaptive mixing across sources.

## Users

Waves is for Mac users who keep several sound-producing apps open at once and need fast control without breaking focus. The primary user is a remote worker, student, gamer, or everyday power user who moves between calls, browsers, music, games, and system sounds on the same machine.

Their context is immediate and interruption-sensitive: a browser tab starts playing audio, music is too loud under a meeting, a game overpowers Discord, or a focus profile needs to restore a known mix. The app should make the right action available from the menu bar in seconds.

## Product Purpose

Waves gives macOS the per-app mixer it should already have: native menu-bar access to app discovery, per-app mute, gain, EQ, route health, profiles, output-device awareness, and optional speech-aware or loudness-aware mixing. Success means the user can trust the list, shape a source, hear the result, and understand when an app is monitored versus fully managed.

The product must be honest about macOS audio constraints. If Waves can see an app but cannot fully control it yet, the interface should say that clearly instead of pretending every row has identical capability.

The menu bar is a quick mixer, not a miniature copy of the main window. It
keeps volume and mute immediately available for at most seven pinned, playing,
or recent apps, omits excluded apps, and moves less-frequent routing and shaping
actions into a row menu. Output and profile switching remain one click away.

That honesty includes coexistence with other routers. Public Core Audio APIs do
not expose a supported tap-creator association. When verified Wave Link has
active Core Audio output, Waves conservatively yields affected ordinary routes
and explains the unattributable handoff. An unrelated system tap is never
attributed to Wave Link, and Waves unconditionally excludes Wave Link's own and
mixed-output targets. Geometry recovery happens outside realtime callbacks,
with bounded retries and a visible global recovery path when automatic repair
is exhausted.

Automation is local and opt-in. URL commands and the same-user protocol-v1 Unix
socket are separate settings and both default to off. The `wavesctl` client is
part of this repository. The Stream Deck companion is separately versioned and
not bundled with Waves. It may control only routes Waves truthfully reports as
managed. App Intents remain deferred until they can reuse the same AppStore
intent boundary.

Temporary call behavior remains temporary. An automatic conferencing mute is
session-only and must never become durable user intent. Durable state stays
schema 1 with additive decoding so existing profiles, preferences, sessions,
pins, hotkeys, EQ, device presets, and automation settings survive an upgrade.

## Release boundary

A Waves version is published only after the exact source revision passes the
package, signing, notarization, upgrade, local QA, and required hardware-evidence
gates. Source-level completion alone is not publication approval. Canonical
version and build intent live in `release/metadata.json`; published availability
is determined by the signed Git tag, GitHub Release, and Sparkle appcast.

## Brand Personality

Native, quiet, precise.

Waves should feel like a built-in macOS utility with the confidence of a best-in-class audio tool. It should borrow the immediacy of Control Center, the density discipline of Raycast, and the trust posture of a professional system utility without becoming a DAW, plugin suite, or decorative dashboard.

## Anti-references

Do not make Waves feel like a simulated mixer surface over weak system hooks. Avoid loud gamer audio styling, generic neon dashboards, overbuilt analytics panels, plugin-suite complexity, heavy custom chrome, and decorative glass that fights macOS system materials.

The reference set is Background Music, FineTune, eqMac, and BetterAudio. Waves should learn from their scope and pain points, then stay more native, more direct, and more transparent about control state.

## Design Principles

1. Control before explanation. The mixer is the product, not a launch page or tutorial surface.
2. Native trust. Use standard macOS controls, materials, menus, keyboard paths, and window behavior unless a custom surface materially improves the task.
3. Honest routing. Separate visible, monitored, and fully managed states so the app never overpromises per-app control.
4. Stable identity. Preserve user preferences by logical app identity, while route control revalidates the current runtime process family.
5. Quiet confidence. Keep copy terse, interactions calm, and visual emphasis reserved for status, risk, and the current control path.
6. Capability before affordance. Do not show an enabled control for a route Waves has yielded or cannot safely manage.

## Accessibility & Inclusion

Target a practical WCAG AA posture for contrast, focus visibility, keyboard operation, and reduced-motion comfort. All icon-only actions need accessible labels and help text. Sliders, toggles, menus, route-status indicators, and empty states must remain understandable without color alone.

The focused mixer must remain keyboard-operable, including selection, mute,
volume, boost, pin, EQ, output, and exhausted-route recovery. Full and compact
rows share accessible labels, values, hints, order, and actions. VoiceOver
rotors stay scoped to rendered rows, and profile validation plus route recovery
changes produce announcements through the real product paths.
