# Wave Link Single-Owner Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent duplicate audio for every app in Wave Link compatibility mode while allowing Waves volume and mute controls to operate through Wave Link without creating a second process tap.

**Architecture:** Verified Wave Link output establishes global single-owner mode before any ordinary app starts playing. A native Swift JSON-RPC bridge controls uniquely assigned Wave Link software channels. Every bridge failure is fail-closed and never falls back to a Waves tap.

**Tech Stack:** Swift 6, SwiftPM, Foundation `URLSessionWebSocketTask`, Core Audio, Swift Testing

**Spec:** `docs/superpowers/specs/2026-08-25-wave-link-controller-design.md`

## Global Constraints

- macOS minimum is 14.2.
- Add no production dependency.
- Accept only verified Wave Link activity and `appID = EWL` with interface revision 2 or newer.
- Connect only to loopback with the `streamdeck://` origin.
- Never create or recover a Waves tap while verified Wave Link output is active and compatibility is enabled.
- Never treat a shared Wave Link channel as a per-app channel.
- Never fall back to a Waves tap after a bridge failure.

---

### Task 1: Global Single-Owner Arbitration

**Files:**
- Modify: `Sources/Waves/Services/Audio/VerifiedRouterConflictService.swift`
- Modify: `Tests/WavesTests/VerifiedRouterConflictServiceTests.swift`
- Modify: `Tests/WavesTests/GenerationAwareBackendTests.swift`

**Interfaces:**
- Consumes: verified router process identity and current Core Audio output state.
- Produces: `VerifiedRouterActivitySnapshot.conflict(for:)` that conservatively claims every ordinary app while verified Wave Link output is active.

- [ ] **Step 1: Write the failing service tests**

Add tests proving an idle app and an app whose audio is emitted by another helper PID both receive `.unattributableTapFallback` while a verified Wave Link process owns output.

- [ ] **Step 2: Run the service tests and verify RED**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test --filter VerifiedRouterConflictServiceTests`

Expected: the idle and helper-root tests fail because the current service requires the row PID itself to own running output.

- [ ] **Step 3: Implement the global ownership rule**

Remove row-output gating from the ordinary-app branch. Preserve the verified-router mixed-output exclusion and return no conflict when no verified router is active.

- [ ] **Step 4: Add the backend no-controller regression**

Add a test whose app is idle and whose controller factory records calls. Verify an intent is refused and the factory is never called while verified Wave Link activity exists.

- [ ] **Step 5: Run targeted tests and verify GREEN**

Run the two test files with `swift test --filter` and confirm zero failures.

### Task 2: Wave Link JSON-RPC Bridge

**Files:**
- Create: `Sources/Waves/Services/Audio/WaveLinkControlBridge.swift`
- Create: `Tests/WavesTests/WaveLinkControlBridgeTests.swift`

**Interfaces:**
- Produces: `protocol WaveLinkControlling` with `apply(bundleID:volume:muted:) async throws -> WaveLinkBridgeApplyResult`.
- Produces: `WaveLinkControlBridge`, a loopback JSON-RPC implementation.
- Consumes later: `WorkspaceAudioControlBackend` dependency injection.

- [ ] **Step 1: Write failing codec and policy tests**

Use an injected transport closure that receives a method and JSON object and returns decoded JSON data. Test handshake rejection, exact app matching, unique-channel updates, empty-channel assignment, shared-channel refusal, and post-write confirmation failure.

- [ ] **Step 2: Run bridge tests and verify RED**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test --filter WaveLinkControlBridgeTests`

Expected: compile failure because the bridge types do not exist.

- [ ] **Step 3: Implement minimal bridge models and policy**

Decode only the fields required by the contract: application identity, interface revision, channel ID, type, apps, level, mute, and mixes. Reject missing, malformed, ambiguous, and non-finite values.

- [ ] **Step 4: Implement the native loopback transport**

Build a `URLRequest` for `ws://127.0.0.1:1884`, set `Origin: streamdeck://`, send one JSON-RPC request at a time, enforce a bounded timeout, validate response IDs, and close the task after each operation sequence.

- [ ] **Step 5: Verify bridge GREEN**

Run the bridge tests and confirm zero failures.

### Task 3: Backend Bridge Integration

**Files:**
- Modify: `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`
- Modify: `Sources/WavesAudioCore/Models/AudioApp.swift`
- Modify: `Tests/WavesTests/GenerationAwareBackendTests.swift`

**Interfaces:**
- Consumes: `WaveLinkControlling.apply(bundleID:volume:muted:)`.
- Produces: `RouteHealthContext.waveLinkBridge` for confirmed bridge-managed routes.

- [ ] **Step 1: Write failing backend bridge tests**

Test confirmed bridge application, missing bundle identifier, shared-channel refusal, bridge timeout, Wave Link controller selection, boost/EQ/output-device rejection, and the invariant that no controller factory runs in any bridge branch.

- [ ] **Step 2: Verify RED**

Run: `swift test --filter GenerationAwareBackendTests` and confirm failures are caused by missing bridge behavior.

- [ ] **Step 3: Route compatible intents through the bridge**

When verified Wave Link ownership exists, compatibility is enabled, and the selected controller is Waves, send volume and mute to the bridge. Commit state only after confirmation. Reject unsupported DSP or output changes. On failure, keep monitoring-only and preserve the safe ownership context.

- [ ] **Step 4: Preserve Wave Link-owned behavior**

When the selected controller is Wave Link, do not call the bridge and retain monitoring-only behavior.

- [ ] **Step 5: Verify backend GREEN**

Run all Wave Link and generation-aware tests and confirm zero failures.

### Task 4: Truthful Mixer Presentation

**Files:**
- Modify: `Sources/Waves/Features/Mixer/RouteHealthPresentation.swift`
- Modify: `Sources/Waves/Features/Mixer/MixerRowView.swift`
- Modify: `Tests/WavesTests/RouteHealthPresentationTests.swift`
- Modify: the existing mixer route-policy test file discovered by `rg`.

**Interfaces:**
- Consumes: `RouteHealthContext.waveLinkBridge`.
- Produces: enabled volume and mute controls for bridge-managed apps, disabled boost, EQ, and output routing, plus clear status text.

- [ ] **Step 1: Write failing presentation and control-policy tests**

Assert the status title is `Managed through Wave Link`, volume and mute remain enabled, and Waves-only DSP controls are disabled.

- [ ] **Step 2: Verify RED**

Run the presentation and mixer policy tests and confirm the new case fails.

- [ ] **Step 3: Implement the presentation**

Add the bridge status and split the mixer control policy so volume and mute can be enabled independently of boost and EQ.

- [ ] **Step 4: Verify GREEN**

Run the presentation and mixer tests and confirm zero failures.

### Task 5: Full Verification, Packaging, and Installation

**Files:**
- Modify if required: `README.md`
- Modify if required: `Sources/Waves/Features/Help/HelpView.swift`
- Produce: `dist/Waves.app`
- Produce: `/Users/jonathan/Documents/Codex/2026-08-25/wa/outputs/Waves.dmg`

**Interfaces:**
- Consumes: the complete implementation.
- Produces: verified installed Waves build and release artifacts.

- [ ] **Step 1: Run formatting and lint checks**

Run the repository lint command discovered from scripts and package documentation. Run `swift format lint --recursive Sources Tests` when no project wrapper exists.

- [ ] **Step 2: Run the complete test suite**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test`

- [ ] **Step 3: Build and package the universal app**

Use the repository release script with the configured SDK and separate architecture scratch paths. Verify both `arm64` and `x86_64` slices.

- [ ] **Step 4: Verify signing and install**

Run `codesign --verify --deep --strict`, replace `/Applications/Waves.app`, launch it, and verify the installed binary identity and process state.

- [ ] **Step 5: Dogfood the original failure and a second app family**

With Wave Link running, verify Helium and another browser or conferencing app never create a Waves process tap. Set a uniquely assigned Wave Link app to 0 percent through Waves and confirm the Wave Link channel reaches 0 without a second playback copy.

- [ ] **Step 6: Review and commit**

Inspect the final diff, rerun the required verification commands, and commit with `fix: enforce single-owner Wave Link routing`.
