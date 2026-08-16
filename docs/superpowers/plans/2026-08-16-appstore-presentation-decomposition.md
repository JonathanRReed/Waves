# AppStore Presentation Decomposition Implementation Plan

> **For agentic workers:** Use test-driven development and execute each task in order.

**Goal:** Extract transient presentation state and support models from the 5,700-line `AppStore.swift` while preserving the existing AppStore API and behavior.

**Architecture:** Add a pure `AppStorePresentationCoordinator` value type. `AppStore` owns it and forwards existing properties and methods. Move presentation projections to an extension and move top-level support models into focused files. No audio, persistence, profile, or schema changes.

**Tech Stack:** Swift 6, Swift Observation, SwiftUI, Swift Testing.

### Task 1: Characterize presentation request semantics

**Files:**
- Create: `Tests/WavesTests/AppStorePresentationCoordinatorTests.swift`

- [ ] Add tests for repeated token increments, latest request wins, one-shot consumption, setup/What's New flags, and profile focus token increments.
- [ ] Run the focused tests and confirm they fail because the coordinator does not exist.

### Task 2: Implement the coordinator

**Files:**
- Create: `Sources/Waves/Stores/Coordinators/AppStorePresentationCoordinator.swift`

- [ ] Implement the minimum value-type coordinator required by the tests.
- [ ] Run focused tests and confirm they pass.

### Task 3: Preserve the AppStore API through forwarding

**Files:**
- Create: `Sources/Waves/Stores/AppStore+Presentation.swift`
- Modify: `Sources/Waves/Stores/AppStore.swift`
- Modify: `Tests/WavesTests/AppStorePresentationCoordinatorTests.swift`

- [ ] Add AppStore characterization tests for source, equalizer, settings, mute-shortcut, replay, and What's New request behavior.
- [ ] Replace presentation stored properties with one coordinator.
- [ ] Move presentation projections and forwarding methods to the extension.
- [ ] Keep tour orchestration and durable preference mutations in `AppStore.swift`.
- [ ] Run focused AppStore and hosted interaction tests.

### Task 4: Move support models into focused files

**Files:**
- Create: `Sources/Waves/Stores/Models/AppStoreFeedbackModels.swift`
- Create: `Sources/Waves/Stores/Models/AppStoreIntentModels.swift`
- Create: `Sources/Waves/Stores/Models/AppStoreLifecycleModels.swift`
- Create: `Sources/Waves/Stores/Models/AppStorePresentationModels.swift`
- Modify: `Sources/Waves/Stores/AppStore.swift`

- [ ] Move types without changing declarations or visibility.
- [ ] Leave private implementation helpers in `AppStore.swift`.
- [ ] Run formatting and compile tests after every move.

### Task 5: Verify the refactor

- [ ] `swift-format lint --recursive Sources Tests`
- [ ] `swift test --filter 'AppStorePresentationCoordinatorTests|AppStoreTransactionTests|HostedUIInteractionTask9Tests|OnboardingExperienceTests'`
- [ ] `./script/quality-gate.sh full`
- [ ] `git diff --check`
- [ ] Record the line-count reduction and exact verification in the PR.
