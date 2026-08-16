# AppStore Presentation Decomposition Design

## Status

Approved under the Waves quality and cleanup program.

## Goal

Reduce the size and responsibility of `AppStore.swift` without changing the UI-facing `AppStore` API or any audio, persistence, profile, onboarding, or automation behavior.

This first AppStore decomposition isolates presentation requests and moves the store's supporting value types into focused files. It is intentionally narrower than a rewrite. Later AppStore extractions can build on this boundary.

## Boundaries

### Presentation coordinator

Create `AppStorePresentationCoordinator`, a small value-type state machine owned by `AppStore`. It is responsible only for transient UI requests and monotonically increasing observation tokens:

- profile focus token
- source focus request and token
- equalizer focus request and token
- settings-pane request and token
- mute-shortcut request and token
- installation-advisory acknowledgment
- requested setup replay
- requested What's New presentation

Requests retain the current one-shot consume behavior. Repeating the same request still increments its token so an already-open scene receives the request again.

`AppStore` remains the only API consumed by views. Existing property and method names stay unchanged through computed proxies and forwarding methods. Views do not receive the coordinator directly.

### Presentation extension

Move presentation-only computed properties and request methods into `AppStore+Presentation.swift`, including:

- menu-bar status and icon
- privacy setup presentation state
- onboarding launch decision
- guided-tour presentation projection
- source/equalizer/settings/mute request forwarding
- installation, setup replay, and What's New state transitions

Orchestration that changes durable preferences, controls a tour, persists state, or touches audio remains in `AppStore.swift`.

### Supporting models

Move top-level support types out of `AppStore.swift` into focused files:

- intent and profile models
- feedback models
- lifecycle and shutdown models
- onboarding and presentation models

Private transaction-result helpers stay with the implementation that uses them.

## Observation contract

`AppStore` owns the coordinator as an observed stored value. Computed token properties read through that value. Mutating coordinator methods replace or modify the stored value through `AppStore`, preserving Swift Observation invalidation for existing `.onChange` consumers.

Characterization tests cover token increments, latest-request semantics, one-shot consumption, and unchanged public AppStore behavior.

## Non-goals

This change does not:

- change AppStore construction or dependency injection
- modify audio routes or realtime code
- alter persistence schemas
- change profile behavior
- introduce a new state-management framework
- expose the coordinator as a public UI dependency
- combine lifecycle, session, profile, or device extraction into the same PR

## Verification

Run the new coordinator tests, existing AppStore transaction tests, hosted UI interaction tests, rendered UI tests, formatting, `git diff --check`, and the full quality gate before marking the PR ready.
