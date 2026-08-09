# Waves 1.5 candidate capability inventory

Updated: 2026-08-09

Status: regression inventory for the in-development Waves 1.5.0 build 13
candidate. Version 1.4.4 remains the latest published release.

This inventory names stable source symbols and focused test files instead of
line numbers. It describes behavior that the 1.5 candidate must preserve. A
green source test is evidence for one boundary, not publication approval.

## Audio and routing

| Capability | Source authority | Behavior that must remain true | Focused evidence |
| --- | --- | --- | --- |
| Privacy-gated startup | `AppStore.acceptPrivacySetupAndStart`, `PrivacySetupSurface` | Waves persists the user's local privacy acknowledgement before starting the capture-capable backend. A failed durable write does not start audio. | `PrivacyStartupTests` |
| App discovery and stable identity | `WorkspaceAudioControlBackend`, `AppRuntimeDiscovery`, `TargetProcessFamily` | Core Audio process objects are attributed to stable logical apps, helper processes remain covered, and dead process IDs can retire without rebuilding a healthy route. | `AppRuntimeDiscoveryTests`, `AppDiscoveryPolicyTests`, `AudioLifecycleTask4Tests` |
| Per-app volume, mute, and boost | `AppStore.setDesiredVolume`, `commitDesiredVolume`, `setMuted`, `setVolumeBoost` | User intent reaches the backend, updates optimistic UI safely, and persists only at the accepted transaction boundary. A manual mute is never mistaken for an automatic conferencing mute. | `AppStoreTransactionTests`, `GenerationAwareBackendTests` |
| Per-app and shared EQ | `AppStore` equalizer mutators, `ManagedAudioEqualizerDSP`, `EqualizerDSP` | Simple and advanced curves, presets, headroom, per-app settings, and All Managed Audio settings survive relaunch and reach the render path. | `EqualizerSettingsTests`, `GlobalEqualizerSettingsTests`, `ManagedAudioEqualizerDSPTests`, `TapDSPTests` |
| Per-app output routing | `AppStore.setOutputDevice`, `WorkspaceAudioControlBackend` route lifecycle | An app can follow the system default or target another output. Durable intent and optional device presets restore without claiming a route Waves does not own. | `AppStoreTransactionTests`, `AudioLifecycleTask4Tests`, `P1CharacterizationTests` |
| Transactional teardown | `PerAppTapController`, `WorkspaceAudioControlBackend` teardown lifecycle | Tap, renderer, callback, and native resources remain owned until Core Audio confirms release. If renderer stop fails after path release, muting is restored so duplicate audio is not exposed. | `AudioCorrectnessTask2Tests`, `AudioHardeningTests` |
| Geometry recovery | `GeometryRecoveryCoordinator`, `WorkspaceAudioControlBackend` maintenance | Realtime callbacks only signal a mismatch. Bounded asynchronous rebuilds report progress, exhaustion, and a usable recovery action without allocating or performing UI work in the callback. | `AudioCorrectnessTask2Tests`, `AudioHardeningTests`, `UIAccessibilityTask9Tests` |
| Wave Link coexistence | `VerifiedRouterConflictService`, `CompetingRouterPolicy`, `RouterObservationListenerLifecycle` | Public Core Audio has no supported tap-creator association. Verified active Wave Link Core Audio output triggers the explicit unattributable fallback for affected ordinary routes; unrelated system taps are never attributed to Wave Link. Wave Link's own and mixed-output targets are unconditionally excluded. | `VerifiedRouterConflictServiceTests`, `P1CharacterizationTests`, `AudioCorrectnessTask2Tests` |
| Route-health controls | `MixerRouteControlPolicy`, `RouteHealthPresentation`, `RouteHealthBadgeSemantics` | Ordinary monitor-only rows may become manageable. Wave Link claimed, unattributable, and mixed-output rows do not offer Waves controls. Recovery progress disables control; exhaustion exposes global Recover Routes with explicit scope. | `UIAccessibilityTask9Tests`, `HostedUIInteractionTask9Tests`, `RenderedUISmokeTests` |
| Device changes | `DeviceChangeSuppressionCoordinator`, `AppStore.performSilentSessionRefresh` | Self-initiated suppression expires after five seconds, genuine later changes remain visible, managed routes reattach, and optional volume memories are applied separately from route recovery. | `AudioLifecycleTask4Tests`, `AppStoreTransactionTests`, `PersistenceStoreTests` |
| Adaptive Mix | `AdaptivePolicyEngine`, `AdaptiveMixCoordinator`, `AppStore.setAdaptiveMixMode` | Content type, assigned priority, strategy, and focus mode drive temporary gain only. Manual levels remain intact and coordinator work can cancel, drain, and shut down. | `AdaptiveMixingTests`, `AdaptivePolicyEngineTests`, `AdaptiveFocusModeTests`, `AppStoreCoordinatorTests` |
| Live metering | `LevelMeterModel`, `RenderActivityMonitor`, `MixedWaveformView` | Attack, release, silence, and visibility cadences remain bounded. Reduce Motion holds a still pose and hidden windows do not keep high-frequency rendering alive. | `MeterBallisticsTests`, `RenderActivityTests`, `RenderedUISmokeTests` |

## State, profiles, and automation

| Capability | Source authority | Behavior that must remain true | Focused evidence |
| --- | --- | --- | --- |
| Additive schema-1 persistence | `JSONPersistenceEngine`, `PersistedSchema`, payload decoders | Profiles, preferences, sessions, pins, hotkeys, EQ, device presets, and automation settings decode legacy schema-1 data with additive defaults. Writes remain atomic, private, capped at 10 MiB, coalesced, and flushable. Corrupt files are preserved. | `PersistedSchemaTests`, `PersistenceStoreTests`, `CoalescingPersistenceWriterTests`, `AppStoreUpgradeTests` |
| Explicit migrations | `UserPreferences`, `ProfilePayloadDecoder` migration markers | A migration marker, not an empty collection, decides whether legacy state was processed. An intentionally empty current store is not migrated again. | `AppStoreUpgradeTests`, `UserPreferencesTests` |
| Profiles and mix reset | `AppStore.saveProfile`, `applyProfile`, `resetMix`, `ProfileEditorSheet` | Membership-only profiles do not overwrite levels. Captured levels apply as an ordered batch, a later user change wins, invalid names announce a reason, and reset restores the pre-apply mix. | `AppStoreTransactionTests`, `HostedUIInteractionTask9Tests`, `UIAccessibilityTask9Tests` |
| Session-only conferencing mute | `AppStore.applyAutomaticConferencingTransition`, startup restoration | Automatic conferencing mute never becomes durable user intent. Upgrade, relaunch, disable, and app-exit paths resume only apps muted by that session behavior. | `AppStoreUpgradeTests`, `AppStoreTransactionTests` |
| URL automation | `AppStore.handleURLScheme`, `AutomationCommandParser`, `UserPreferences.enableURLScheme` | The feature is off by default. A disabled external URL is inert before app activation or setup UI. Enabled commands validate names, IDs, booleans, and volume bounds. | `AppStoreTransactionTests`, `PrivacyStartupTests` |
| External control protocol v1 | `ControlProtocol`, `ControlCommandHandler`, `ControlServer`, `ControlConnection` | The same-user Unix socket is opt-in and local only. Handshake, framing, complete replies, queued partial writes, 2 MiB backpressure cap, connection cap, five-second handshake, and 30-second idle policy remain enforced without changing protocol version 1 shapes. | `ControlProtocolTests`, `ControlCommandHandlerTests`, `ControlServerIntegrationTests` |
| `wavesctl` | `WavesCTLCommand`, `WavesControlSocketClient`, `Sources/wavesctl/main.swift` | Commands validate before connecting, writes complete without SIGPIPE, read and write deadlines are five seconds, and EOF, parse, and transport failures remain distinct. | `WavesControlClientTests`, `ControlServerIntegrationTests` |
| Keyboard control | `HotkeyCenter`, `MixerKeyboardCommandsModifier`, `ShortcutRecorder` | User-assigned global and app shortcuts are off by default and need no Accessibility permission. Focused mixer keys operate the selected row; E and O obey route capability, and plain R recovers globally only from an exhausted selected route. Recording refuses unsafe or already-owned chords with clear feedback. | `HotkeyTests`, `HotkeyCenterTests`, `HostedUIInteractionTask9Tests`, `UIAccessibilityTask9Tests` |
| App icons | `AppIconCache`, `AudioApp` coding | Decoded icons use bounded count and decoded-byte cost, prune only from the authoritative session roster, and are never persisted in new state while legacy icon data remains decodable. | `AppIconCacheTests`, `WavesCoreTests`, `PersistenceStoreTests` |

## Interface, lifecycle, and release boundaries

| Capability | Source authority | Behavior that must remain true | Focused evidence |
| --- | --- | --- | --- |
| Mixer and menu bar | `MainWindowView`, `MixerRowView`, `MenuBarMixerView` | Running, live, pinned, recent, and profile scopes expose the same truthful route capability. Search and visibility filters never become ownership authority. Pending controls survive settings navigation. | `RenderedUISmokeTests`, `HostedUIInteractionTask9Tests`, `SettingsWorkspaceTests` |
| Accessibility | `MixerRowAccessibility`, `RouteHealthBadgeSemantics`, production announcement callers | Full and compact rows expose labels, values, hints, adjustable actions, mute/EQ/recovery actions, focus order, and rendered-row rotors. Status, profile-validation, and recovery changes announce through production paths. | `UIAccessibilityTask9Tests`, `HostedUIInteractionTask9Tests`, `RenderedUISmokeTests` |
| Settings and setup | `SettingsPane`, `SettingsWorkspace`, `ReadinessChecklistRow` | General, Mixer, Profiles, Shortcuts & Automation, Setup, Diagnostics, and Help use one stable workspace. Setup and repair share readiness semantics and preserve in-flight operations. | `SettingsWorkspaceTests`, `PrivacyStartupTests`, `RenderedUISmokeTests` |
| Diagnostics | `DiagnosticsExportFormatter`, `AppStore.refreshDiagnostics`, `DiagnosticsSettingsView` | Reports are bounded, exclude audio samples, refresh current backend truth, include route and previous-shutdown evidence, and keep unsupported capture-permission preflight as an honest runtime state. | `AudioHardeningTests`, `ShutdownReportTests`, `RenderedUISmokeTests` |
| Shutdown | `AppStore.shutdown`, `AppStorePersistenceCoordinator`, shutdown report store | Tasks cancel and drain, store identifiers are canonical, duplicate failures collapse at the reporting boundary, and synchronous report completion is bounded to 250 ms. | `ShutdownTests`, `ShutdownReportTests`, `AppStoreCoordinatorTests` |
| Updates | `UpdaterService`, Sparkle configuration | Checks remain consent-aware and user-triggerable. Package, appcast, signature, and publication truth are verified separately. | `UpdaterServiceTests` |
| Platform and artifact | `Package.swift`, release scripts | Waves remains SwiftPM-based, macOS 14.2+, universal arm64 and x86_64, with no new production dependency for 1.5. Version 1.5.0 build 13 is not published until every release and external Elgato gate passes. | `PhaseOneContractTests`, local package and release evidence |
| Stream Deck companion | Waves protocol v1 plus `/Users/jonathanreed/Downloads/waves-streamdeck` | The companion is a separately versioned Bun project and is not bundled in Waves. It can control only routes Waves truthfully reports as managed. Live Wave Link and physical Stream Deck validation is a hard publication gate and is not yet complete. | Companion typecheck, unit, validator, package, live packaged-socket, and remote hardware evidence |

## Deferred boundary

App Intents are intentionally deferred until after 1.5. A future adapter must
call the same AppStore intent boundary rather than create a second automation
implementation.
