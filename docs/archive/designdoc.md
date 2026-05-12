Yes. Rename it to **Waves** and tighten the doc around one clear idea: a native macOS menu bar mixer that feels built in, with a real path to per-app volume control instead of a fake UI over weak system hooks.

Confidence: 93/100

# Waves

**Design Doc**
**Product:** Native macOS menu bar app for per-app sound mixing
**Platform:** macOS
**Status:** Final draft

## 1. Overview

Waves is a native macOS menu bar app that lets users see, mute, and adjust the volume of individual apps from the top bar.

The goal is simple. Give macOS the per-app volume mixer it should already have. The product should feel instant, quiet, and obvious. Open it, drag a slider, move on.

---

## 2. Product vision

Waves should feel like a built-in utility, not a “power user audio suite.”

That means:

* native UI
* tiny footprint
* fast launch
* clear app list
* zero clutter
* no fake complexity

The user should be able to do things like:

* keep Zoom at 100% while lowering Spotify
* mute Chrome without muting the whole Mac
* save a “Focus” mix and restore it later
* pin favorite apps to the top of the mixer

---

## 3. Problem

macOS gives users a system-wide output volume and some app-level controls inside certain apps, but it does not give users a clean universal per-app mixer in the menu bar.

That creates a daily friction point:

* media is too loud during meetings
* browsers, music, and games compete for volume
* users bounce between app UIs just to mute one sound source
* there is no fast single place to manage all active audio

Waves solves that with a native top bar control surface for app audio.

---

## 4. Product statement

**Waves is a native menu bar mixer for macOS that gives users fast per-app sound control without leaving the top bar.**

---

## 5. Goals

### Primary goals

* Show all apps currently producing audio
* Provide per-app mute
* Provide per-app volume sliders
* Live in the menu bar
* Remember user preferences
* Restore known app levels when possible
* Launch at login

### Secondary goals

* Save and apply presets
* Pin favorite apps
* Show the current output device
* Distinguish active, recent, and silent apps
* Offer a compact, polished settings experience

### Non-goals for v1

* full DAW features
* EQ, compression, plugins, or mastering tools
* microphone processing
* multi-room audio
* cloud accounts
* collaboration
* audio recording as a product feature

---

## 6. Product principles

### Native first

Waves should be built with Apple-native frameworks and behave like a real macOS utility.

### One-click usefulness

The core action should be available immediately from the menu bar. No heavy dashboard. No forced onboarding.

### Clear over clever

The user should understand exactly what each row means. App icon, app name, level meter, mute, slider. Done.

### Honest capability

If an app is visible but not fully controllable yet, Waves should say so clearly. No pretending.

### Quiet software

No loud animations, noisy alerts, or over-designed chrome. This is infrastructure, not content.

---

## 7. Target users

### Primary user

A normal Mac user who constantly has multiple audio apps open and wants faster control.

### Secondary users

* students in lectures or calls
* remote workers using Zoom, Meet, Slack, music apps, and browsers at once
* gamers with Discord, game audio, and media running together
* productivity-focused users who want presets like Focus, Work, or Entertainment

---

## 8. Core user stories

1. As a user, I want to lower Spotify without lowering my call.
2. As a user, I want to mute Chrome fast when a tab starts making noise.
3. As a user, I want to open the mixer from the menu bar in one click.
4. As a user, I want my app volume preferences to persist.
5. As a user, I want to save presets for different situations.
6. As a user, I want to know which apps are actually making sound right now.

---

## 9. Constraints and technical reality

This is the most important part of the doc.

The UI is easy. Real per-app audio control is the hard part.

On macOS, Waves cannot be designed as a simple “read all apps and directly turn down their output with one universal knob” app. The durable design has to assume some apps may need to be observed, tapped, or routed through a managed audio path before Waves can reliably apply gain.

That means Waves should be built around two truths:

### Truth 1

Waves can identify and monitor audio-producing apps.

### Truth 2

True per-app output control works best when Waves owns enough of the audio path to apply gain safely and consistently.

So the architecture should support three states for each app:

* visible
* monitored
* fully managed

That gives the product room to ship a strong v1 without boxing itself into a dead-end implementation.

---

## 10. Product strategy

### Recommended strategy

Ship in layers.

### Phase 1

Build the native shell, app discovery, live levels, mute UI, saved preferences, presets, and routing-state awareness.

### Phase 2

Expand managed audio support so Waves can apply real per-app gain more broadly and reliably.

This is the correct product call because it lets Waves feel useful early while still building toward the real feature everyone cares about.

---

## 11. Core feature set

## v1 features

* menu bar app
* list of active audio apps
* app icons and names
* live audio level meters
* per-app mute control
* per-app desired volume control
* pinned apps
* recently active apps section
* presets
* current output device display
* launch at login
* settings window
* clear routing-state indicators

## v1.5 features

* app grouping like Browsers, Media, Calls
* keyboard shortcuts
* menu bar compact mode
* quick actions for presets
* better route recovery when devices change

## v2 features

* broader real per-app volume control coverage
* automatic app enrollment into managed routing where supported
* app-specific output-device rules
* automation support
* more advanced diagnostics

---

## 12. UX design

## 12.1 Menu bar interaction

Clicking the Waves icon opens a compact panel from the menu bar.

The panel should feel closer to Control Center than to a full preferences app.

### Top section

* output device name
* master output slider
* preset selector

### Middle section

A scrolling list of apps with:

* app icon
* app name
* status indicator
* live level meter
* mute button
* volume slider
* optional pin button

### Bottom section

* settings
* launch at login
* quit Waves

---

## 12.2 App row design

Each app row should show exactly what matters.

**App row fields**

* icon
* name
* activity state
* meter
* mute state
* volume slider
* routing badge

**Example row**
`Spotify   [meter]   [mute]   [slider]`

### Routing badges

* **Live**: app is actively producing audio
* **Recent**: app produced audio recently
* **Managed**: Waves can fully control this stream
* **Monitor only**: Waves can observe it but not fully control it yet
* **Error**: stream or route issue

These badges matter because they make the product honest.

---

## 12.3 Settings window

The settings window should be lightweight and broken into practical tabs.

### General

* launch at login
* show recent apps
* hide system processes
* sort behavior

### Audio

* selected output device
* managed routing mode
* route recovery behavior
* gain limit settings

### Presets

* save preset
* rename preset
* delete preset
* auto-apply rules later

### Advanced

* diagnostics
* permission status
* reset audio state
* clear saved app settings

---

## 13. Information architecture

### Main objects in the system

**Audio App**
Represents a sound-producing application.

**Device**
Represents the current physical or logical output device.

**Route**
Represents how an app’s audio is being observed or managed.

**Preset**
Represents a saved set of app volume and mute states.

**Session**
Represents the current live mixer state.

---

## 14. Data model

```swift
struct AudioApp: Identifiable, Codable, Hashable {
    let id: String
    let pid: Int32?
    let bundleID: String?
    let displayName: String
    let iconReference: String?

    var isActive: Bool
    var isAudible: Bool
    var peakLevel: Float
    var rmsLevel: Float

    var desiredVolume: Float
    var isMuted: Bool
    var isPinned: Bool

    var routingState: RoutingState
    var lastSeenAt: Date
}

enum RoutingState: String, Codable {
    case unmanaged
    case monitored
    case managed
    case error
}
```

### Notes

* Bundle ID should be the stable identity whenever possible.
* PID is useful for current session tracking but should not be treated as permanent identity.
* Desired volume and measured level should stay separate.

---

## 15. Technical architecture

## 15.1 High-level architecture

Waves should have six major layers.

### 1. App shell

* native macOS app
* menu bar entry point
* settings window
* onboarding and permission flows

### 2. UI layer

* mixer panel
* app rows
* sliders
* meters
* preset interactions

### 3. State layer

* live audio session state
* app list
* mute and gain state
* route state
* device state

### 4. Discovery layer

* identify audio-producing apps
* map process to bundle identity and icon
* track active vs recent apps

### 5. Audio engine

* metering
* gain management
* routing coordination
* output handoff
* route recovery

### 6. Persistence layer

* saved app preferences
* pinned apps
* presets
* general settings

---

## 15.2 Implementation stance

Waves should be built as a native Swift app with:

* SwiftUI for most UI
* AppKit where menu bar and window behavior need extra control
* a separate audio/core module that stays isolated from UI concerns

The audio engine should be treated as the product core, not as a helper utility.

---

## 16. Suggested module breakdown

```text
Waves/
├── App/
│   ├── WavesApp.swift
│   ├── MenuBar/
│   ├── Settings/
│   └── Onboarding/
├── Features/
│   ├── Mixer/
│   ├── Presets/
│   ├── Devices/
│   └── Diagnostics/
├── AudioCore/
│   ├── Discovery/
│   ├── Metering/
│   ├── Routing/
│   ├── Gain/
│   ├── Devices/
│   └── Models/
├── Services/
│   ├── Persistence/
│   ├── LoginItem/
│   └── Permissions/
├── Shared/
│   ├── UI/
│   ├── Utilities/
│   └── Extensions/
└── Tests/
    ├── Unit/
    ├── Integration/
    └── UI/
```

This keeps the audio engine clean and future-proof.

---

## 17. UI states

Waves should handle these cleanly:

### Empty state

No apps are currently producing audio.

### Active state

One or more apps are producing sound now.

### Silent but recent state

An app played sound recently and is still relevant.

### Permission-limited state

Waves can show only partial information until the user grants required permissions.

### Route failure state

A device or route changed and Waves temporarily lost control.

### Recovery state

Waves is reconnecting to the active output path.

---

## 18. Presets

Presets should be a major v1 differentiator because they make the product feel smarter without adding huge technical risk.

### Example presets

* **Focus**: mute media, keep productivity apps normal
* **Meeting**: calls at 100%, music at 20%, browser muted
* **Gaming**: Discord high, music low, browser muted
* **Night**: everything capped lower

### Preset behavior

* save current mix
* apply instantly
* optional future support for auto-apply rules

---

## 19. Success metrics

### Product metrics

* user can adjust an app’s volume in under 2 seconds
* user can mute a noisy app in one click
* launch and panel open feel instant
* app is understandable without a tutorial

### Technical metrics

* low idle CPU usage
* low memory footprint
* no audible pops during volume changes
* reliable recovery after device changes
* no orphaned audio state after crash or quit

### Quality metrics

* app list stays accurate
* sliders feel responsive
* route-state badges are accurate
* saved preferences restore correctly

---

## 20. Risks

### Risk 1: true per-app control is harder than the UI suggests

This is the main technical risk.

**Mitigation:**
Be explicit in the architecture that discovery, monitoring, and managed control are separate layers.

### Risk 2: output device changes break routes

AirPods, docks, HDMI monitors, and USB interfaces will create edge cases.

**Mitigation:**
Build route recovery early. Treat device changes as a first-class workflow.

### Risk 3: process churn

Browsers and Electron apps can spawn helpers and change process identity.

**Mitigation:**
Key by bundle ID when possible. Treat PID as temporary.

### Risk 4: trust

Users are sensitive about audio-routing tools.

**Mitigation:**
Make privacy dead simple. No audio leaves the machine. No recording by default. No accounts.

---

## 21. Privacy and trust

Waves should be privacy-first by design.

### Commitments

* all processing is local
* no audio is uploaded
* no recording is stored by default
* no account required
* no telemetry in early versions unless explicitly added later

This should be visible in onboarding and settings. Audio tools need trust.

---

## 22. Performance requirements

Waves should feel invisible until needed.

### Targets

* fast app launch
* fast menu bar panel open
* low idle resource usage
* smooth slider interaction
* stable meters without stutter
* no noticeable system drag

This is a utility. Anything that feels heavy kills the product.

---

## 23. Visual direction

Waves should look modern and native, with just enough identity to feel polished.

### Visual tone

* dark mode first, but support both
* clean translucent panel
* subtle meters
* minimal accent color
* rounded controls
* restrained typography
* no overdone gradients

### Brand feel

The name **Waves** gives room for a soft, fluid identity. The product should feel calm and precise, not flashy.

Possible icon direction:

* stacked wave lines
* a single waveform inside a circle
* simple equalizer bars with curved styling

---

## 24. Roadmap

## Milestone 1: Foundation

* menu bar app shell
* settings window
* persistence layer
* mock mixer UI
* login item support

## Milestone 2: Real discovery

* detect active audio apps
* map names, icons, identity
* show live list
* show recent apps

## Milestone 3: Metering and controls

* live meters
* mute state
* desired volume state
* persistence of app settings

## Milestone 4: Managed control path

* real gain application for supported streams
* output routing
* route recovery

## Milestone 5: Presets and polish

* save/apply presets
* pinned apps
* diagnostics
* edge-case cleanup

---

## 25. Final product stance

Waves should not try to be “the ultimate audio workstation for macOS.”

That is the wrong product.

Waves should be:

* native
* fast
* honest
* useful every day

The whole point is that it solves an obvious problem with almost no friction.

---

## 26. One-line pitch

**Waves is a native macOS menu bar mixer that gives you fast per-app sound control from the top bar.**

---

## 27. Final recommendation

Build Waves as a menu bar-first native utility with a serious audio core behind it.

Do not overbuild the surface first. The product lives or dies on three things:

* accurate app discovery
* stable route handling
* real per-app gain where supported

Everything else is polish.

If you want, I can turn this into a tighter **engineering spec** next with exact Swift frameworks, app architecture, and a phased implementation plan.
