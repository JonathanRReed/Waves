# Waves — user-facing feature inventory

Generated 2026-07-28 against `95a43d8` (1.3.1). This is the **regression floor**
for the 1.4 work described in [the 1.4 design](2026-07-28-streamdeck-hotkeys-design.md).

Nothing here may change behaviour. Each entry names where the capability lives,
what a user loses if it silently breaks, and a concrete way to prove it still
works. A checklist, not prose.

**43 capabilities.**

## Menu-bar panel: status header, live waveform, output + profile pickers, Pinned/Live/Recent sections, footer

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Features/Mixer/MenuBarMixerView.swift:16`
- **What it does**: The primary surface for a menu-bar-first user. Contains: `MenuBarHeader` with the live-driven status line and a ⌘R refresh (:207), the `HeaderWaveform` band (:29), `OutputDevicePicker` (:266) and `ProfileQuickPicker` (:309, including Reset Mix at :328), a height-capped scroller (440 pt, :100/:131) so a long list never pushes the footer off screen, three de-duplicated sections (:103-118, Recent capped at 3 rows, others at 4, with a "N more in Waves" overflow link at :420 that calls `focusSource` before `openWindow`), an "All quiet" empty state (:136), and a footer with Open Waves / Settings / Launch at login (:160). The panel shows `PrivacySetupSurface(style: .compact)` before setup completes (:68). `CompactMixerRow` (MixerRowView.swift:329) gives full parity with the main row incl. context menu.
- **Breaks as**: Losing the height cap makes the footer (and Launch at login) unreachable on a busy Mac. Losing the `focusSource` handoff makes "N more in Waves" open the window on whatever scope it happened to be on — the link lies about where it goes. Losing panel/row parity means menu-bar users silently lose routing and exclusion.
- **Verify**: Manual: with 12+ audio apps, open the panel and confirm the footer is visible and the sections scroll; click "N more in Waves" from each section and confirm the main window opens on the matching scope, both when the window was already open and when it was closed.

## Privacy consent gate before any audio capture

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Features/Onboarding/PrivacySetupSurface.swift:8`
- **What it does**: `acceptPrivacySetupAndStart` (AppStore.swift:807) persists the consent DURABLY (`savePreferencesDurably`, :859) and only starts the capture-capable backend if that write succeeds — on failure it rolls the flag back, surfaces an actionable error, and returns to `.awaitingPrivacy` (:860-872). `start()` (:785) refuses to begin audio without `hasCompletedPrivacySetup`. The surface renders in two styles (full window and compact menu-bar, :20) driven by `privacySetupPresentationState` (:714), covering awaiting / saving / starting / failed with a retry action that does not re-ask for consent.
- **Breaks as**: If the durable save is made fire-and-forget, Waves can request audio capture from macOS while the user's recorded consent never hit disk — on the next launch it asks again, or worse, treats an unsaved consent as given. If `start()` stops checking the flag, capture begins before the explanation is shown.
- **Verify**: Manual: make Application Support read-only, click Continue, and confirm Waves does NOT request capture and shows the save-failure copy; restore permissions, retry, confirm audio starts and the choice persists across relaunch. Automated: PrivacyStartupTests — keep the "no backend start on persistence failure" assertion.

## Per-app volume (slider + optimistic projection + committed transaction)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:1746`
- **What it does**: `setDesiredVolume` stores a pending target and applies an optimistic UI projection; `commitDesiredVolume` (:1764) opens a generation-stamped app-intent transaction with `persistencePolicy: .acceptedUserIntent(updateDevicePreset: true)`, so the value is applied to the Core Audio route, persisted as a durable per-app intent, AND written into the current device's volume preset. Two UI surfaces drive it: the full mixer row slider (MixerRowView.swift:60, drag-then-commit on `onEditingChanged`) and the menu-bar compact row slider (MixerRowView.swift:389). Accessibility adjustable action at MixerRowView.swift:81 and :411 commits on every step. Keyboard nudge (±0.05) at MainWindowView.swift:803. Excluded apps are hard-gated out at :1748.
- **Breaks as**: A refactor that drops the `pendingVolumeTargets` handoff, or that lets the commit path skip `startAppIntentTransaction`, makes the slider move visually and snap back on the next backend snapshot — the app's audio never changes. A regression in `persistencePolicy` silently stops the value surviving relaunch or device switch, which users read as "Waves forgot my mix."
- **Verify**: Manual: drag Spotify to 30%, release, confirm audible change AND the "Managed route active" toast; quit and relaunch Waves and confirm 30% is restored; switch output device and back and confirm 30% returns. Automated: AppStoreTransactionTests already covers the transaction boundary — add/keep an assertion that `commitDesiredVolume` writes `preferences.appAudioIntents[id].desiredVolume` and `deviceVolumePresets.getVolumeSettings(for:deviceID:)`.

## Per-app mute (with mute-source provenance)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:1805`
- **What it does**: `setMuted` runs a full app-intent transaction tagged `muteSource: .user`, and clears the app from `pausedMusicApps` when unmuting so a manual unmute wins over auto-pause. UI entry points: full row speaker button (MixerRowView.swift:113), compact menu-bar row (MixerRowView.swift:446), list keys Space and M (MainWindowView.swift:683-684), global hotkey ⌘⌥M (WavesApp.swift:499 → AppStore.swift:4475), URL scheme `waves://mute` (AppStore.swift:1201). The `.user` vs `.autoConferencing` distinction is what keeps auto-pause from clobbering a deliberate mute.
- **Breaks as**: If `muteSource` stops being set to `.user`, the conferencing auto-resume sweep (:3156) will treat a user's deliberate mute as its own and unmute it when the call ends. If the transaction is bypassed, the speaker glyph flips but audio keeps playing.
- **Verify**: Manual: mute an app manually, join/focus a conferencing app, leave it — the manual mute must still be muted. Automated: drive `applyAutomaticConferencingTransition(isConferencingActive:)` directly (it is internal for exactly this) with one user-muted and one auto-muted app and assert only the auto-muted one resumes.

## Per-app output device routing (route one app to a different output)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:2368`
- **What it does**: `setOutputDevice(_:for:)` sends `AppIntentOverrides(targetDeviceUID:replacesTargetDevice: true)` — nil means "follow system default." This is the flagship differentiator (per-app routing). UI is context-menu only, shared by both row densities: `MixerRowContextMenuItems` → `Menu("Output Device")` at MixerRowView.swift:292, with a checkmark on the current target, a `System Default` entry, and an explicit "No output devices found" empty state (:304). The routed device is echoed in the row subtitle as `→ <device>` (MixerRowView.swift:205). `targetDevice(for:)` at :2361 resolves the UID against `availableDevices`. Restored at launch via the durable intent (:2638) with a dedicated failure toast (:2697).
- **Breaks as**: Silent breakage means an app keeps playing out of the system default while the UI shows a checkmark on the headphones — the single most confusing failure mode this app can have. If the startup restore drops `targetDeviceUID`, every per-app route silently resets to default on each launch.
- **Verify**: Manual: route Music to a second output device, confirm audio actually moves and the subtitle reads `→ <device>`; quit and relaunch Waves and confirm the route is re-established (and that the "Some pinned routes could not be restored" toast does NOT appear). Automated: assert `effectiveRestorationOverrides` returns the stored `targetDeviceUID` with `replacesTargetDevice == true`.

## Per-app equalizer: enable, Simple/Advanced bands, 5 presets, per-band gain, reset

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:1843`
- **What it does**: Per-app EQ state is read through a 4-level fallback chain (pending → optimistic projection → confirmed → durable intent → legacy `appEqualizerSettings` map → default) at :1843. Mutators: `setEqualizerEnabled` :1857, `setEqualizerMode` :1863 (simple/advanced band counts), `setEqualizerGain` :1869 (auto-enables), `applyEqualizerPreset` :1876 (flat / voiceFocus / warm / bassReduce / trebleSoften), `resetEqualizer` :1883. Writes are debounced through `scheduleEqualizerTransaction` (:2053). UI: the single Sound workspace card at SoundWorkspaceView.swift:107 with a band grid at :177. Entry points that jump here: full-row EQ button (MixerRowView.swift:99), compact row "EQ" (MixerRowView.swift:429, opens the main window), context menu (MixerRowView.swift:277) — all via `focusEqualizer` (:3988) + token consumption at SoundWorkspaceView.swift:72.
- **Breaks as**: Breaking the read fallback chain makes saved curves invisible (sliders snap to flat) while the DSP still applies the old curve — or vice versa. Breaking the focus-token handoff makes every EQ button in the app a no-op that just switches to the Sound pane with the wrong stream selected.
- **Verify**: Manual: from a mixer row's EQ button, confirm Sound opens with THAT app's chip selected; set a +6 dB band, confirm audible change, relaunch, confirm the curve is still there. Automated: EqualizerSettingsTests / ManagedAudioEqualizerDSPTests exist — keep them, and add a store-level test that `focusEqualizer` then `consumeEqualizerFocusRequest` returns the requested appID exactly once.

## Shared "All Managed Audio" equalizer (global EQ across every managed stream)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:1889`
- **What it does**: A second, independent EQ applied after each app's own curve: `setManagedAudioEqualizerEnabled` :1889, `...Mode` :1895, `...Gain` :1901, `applyManagedAudioEqualizerPreset` :1908, `resetManagedAudioEqualizer` :1915, all funnelled through `updateManagedAudioEqualizer` (:1921) which persists to `preferences.managedAudioEqualizer` and pushes to the backend. Re-pushed on every audio start (:917). UI is the same one card as per-app EQ, selected by the "All Managed Audio" chip (SoundWorkspaceView.swift:212). Combined headroom compensation across both layers is computed and explained to the user at SoundWorkspaceView.swift:503 / :513.
- **Breaks as**: If the backend push at :917 is lost during refactoring, the shared curve is shown as enabled in the UI but never reaches the DSP after a restart — silent, and only detectable by ear. If headroom compensation is dropped, boosted curves clip.
- **Verify**: Manual: enable the shared EQ with a large bass boost, restart Waves, confirm the shaping is still audible and the headroom line reads "Waves reserves N dB". Automated: GlobalEqualizerSettingsTests covers the model — add/keep a check that `performAudioStartup` calls `backend.setManagedAudioEqualizer` with the persisted value.

## Adaptive Mix engine: on/off plus four modes (Off / Speech Focus / Loudness Balance / Both)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:2005`
- **What it does**: `setAdaptiveMixMode` persists the mode, restarts the mixing loop (`restartAdaptiveMixing` :2081, 100 ms pass cadence at :356), and force-disables `autoPauseMusicForConferencing` when the mode uses speech focus (:2010) because full muting and ducking are mutually exclusive. `setAdaptiveMixEnabled` (:2001) restores `lastActiveAdaptiveMixMode` rather than defaulting to `.both`. Gains are published only on change plus a bounded republish every 20 passes (:2195). UI: toolbar menu with all four modes (MainWindowView.swift:149), Sound card master toggle (SoundWorkspaceView.swift:359), onboarding toggle (OnboardingView.swift:242).
- **Breaks as**: Losing the `lastActiveAdaptiveMixMode` memory silently upgrades a user who chose Speech Focus to Both every time they toggle off/on. Losing the republish countdown leaves a rebuilt route stuck at unity gain, so ducking silently stops working for that app until the gain value happens to change.
- **Verify**: Manual: select Speech Focus, toggle Adaptive Mix off then on, confirm it returns to Speech Focus (not Both); play music + a voice app and confirm the music ducks and recovers. Automated: AdaptiveMixingTests / AdaptivePolicyEngineTests / AdaptiveFocusModeTests exist — keep them green, and assert `setAdaptiveMixEnabled(false)` then `(true)` preserves the mode.

## Profile create / edit (name, membership, optional level capture)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:4032`
- **What it does**: `saveProfile(id:named:appIDs:captureLevels:)` trims and length-caps the name (100), edits in place when an `id` is given (so a rename keeps identity), otherwise replaces a same-named profile or appends, and strips excluded apps. The editor sheet (ProfileEditorSheet.swift:16) adds three non-obvious behaviors that are easy to lose: `captureLevels` defaults OFF so editing membership never clobbers a saved mix (:47); offline members are snapshotted once so unticking stays reversible (:35, :257); and members that go offline mid-edit are absorbed additively (:249). Presented from the sidebar "+" ⌘N (MainWindowView.swift:446), the sidebar context menu (:434), and Settings > Profiles (SettingsView.swift:492/:485).
- **Breaks as**: If the offline-member snapshot is refactored into a derived value, unticking an offline row deletes it from the sheet with no way to re-tick, and Save silently drops it from the profile. If `captureLevels` defaults to true, every membership edit overwrites the user's saved mix.
- **Verify**: Manual: edit a profile containing a quit app, untick then re-tick that row, Save, reopen — membership must be unchanged; edit a level-bearing profile without touching the capture switch and confirm its saved levels are preserved. Automated: assert `saveProfile(id:)` with `captureLevels: false` leaves existing `ProfileEntry` levels intact.

## Profile apply ("Apply Levels") — sets volume/mute/boost for every member

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:3226`
- **What it does**: `applyProfile` runs an ordered, generation-stamped batch (`ProfileApplyPurpose` :3220 distinguishes user apply vs mix reset vs startup default), captures a mix restore point first (:3236), reconciles the runtime (:3551), persists profile rows as durable intents (:3597), marks newer per-app transactions as superseded (:3749), and reports quiet partial failures (:3409). UI: the "Apply Levels" button in the profile header (MainWindowView.swift:897), sidebar context menu (:427), and the menu-bar `ProfileQuickPicker` (MenuBarMixerView.swift:314).
- **Breaks as**: A batch that loses generation stamping will race a user who moves a slider mid-apply, and the profile's stale value wins — the mix ends up somewhere the user never asked for. A lost partial-failure report means "Applied" is shown while three apps silently didn't move.
- **Verify**: Manual: apply a level-bearing profile and verify every member moves; move a slider while the apply is in flight and confirm the user's later value wins. Automated: AppStoreTransactionTests — keep the superseded-generation assertions.

## Exclusion escape hatch (never tap this app) + bulk exclude for unroutable apps

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:2401`
- **What it does**: `setExcluded` writes `preferences.excludedAppIDs`; every mutator in the store hard-gates on `isExcluded` (:2390) — volume :1748, mute :1807, boost :1825, routing :2370, URL scheme :1192/:1216, hotkeys :4446/:4464/:4481. `excludeUnroutableApps` (:2454) excludes every `hasNoAudioCapability` error row in the current scope in one action with a single combined toast. UI: context menu on both densities (MixerRowView.swift:323), VoiceOver action (:171/:481), the `UnroutableAppsBanner` "Exclude All" (MainWindowView.swift:580 / :820), and "Excluded" chips in the row (:32), compact row (:370), profile editor (ProfileEditorSheet.swift:408), and Sound workspace (SoundWorkspaceView.swift:653). Excluded apps are also stripped from profiles on save and dropped from the EQ scope picker (:247).
- **Breaks as**: Missing even one gate lets Waves tap a DAW, a VoIP app with echo cancellation, or a monitoring tool the user explicitly told it to leave alone — audible glitching or a broken call, and the user has no in-app way to tell why. There is no dedicated "excluded apps" list UI: un-excluding requires the row to be visible, so losing the row-level chip strands the setting.
- **Verify**: Manual: exclude an app, then attempt volume, mute, boost, routing, an EQ edit, a `waves://set-volume` call, and a ⌘⌥ hotkey against it — every one must be a no-op (URL calls should toast "App is excluded from Waves"). Automated: parameterize a test over all mutators asserting no session change for an excluded app.

## Per-output-device volume memory (remember levels per device) + Clear All Saved Levels

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:2724`
- **What it does**: Two independent preferences: `enablePerDeviceVolumePresets` (store the presets at all) and `autoRestoreDevice` (apply them on a device change) — deliberately separate from route recovery, which always runs (UserPreferences.swift:14-21). Presets are written on every accepted user intent with `updateDevicePreset: true` and restored by `restoreDeviceVolumePresets` (:2724) / `effectiveRestorationOverrides` (:2617, preset overrides the durable intent). `clearDeviceVolumePresets` (:3863) wipes the data without touching the toggle. Persisted separately in `deviceVolumePresets.json` (DeviceVolumePresetsStore.swift). UI: Settings > Mixer > Volume Memory (SettingsView.swift:352/:359), live counts of saved apps/devices (:368-371), and a confirmation-gated destructive Clear (:373).
- **Breaks as**: If the preset restore is folded into route recovery, disabling `autoRestoreDevice` would also disable route re-establishment and per-app control would silently die after every device switch. If the preset stops taking precedence over the durable intent at :2626, headphones/speakers levels collapse into one shared value.
- **Verify**: Manual: set Spotify to 40% on headphones and 80% on speakers, switch devices repeatedly, confirm each level returns; turn OFF "Restore levels when devices switch", switch devices, confirm levels do NOT change but volume/mute still WORK. Automated: PersistenceStoreTests for the file; assert `effectiveRestorationOverrides` prefers the preset when `includeDevicePreset` is true.

## Recover Routes (rebuild process taps and re-apply saved state)

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:4294`
- **What it does**: `recoverRoutes` guards against re-entrancy (`isRecovering`), rebuilds routes in the backend, then re-runs `restoreConfiguredApp` for every app (optionally including device presets), re-reads diagnostics and capture authorization, and — critically — branches the toast on the RESULTING `isRouteRecoveryHealthy` rather than on the absence of a throw (:4323-4350), with specific remedies for missing permission vs missing output device. UI reaches it from four places: the `RouteHealthBadge` in the main window header, which becomes a button when unhealthy (MainWindowView.swift:1019), Settings > Advanced (SettingsView.swift:693 and :794), Setup & Repair (SetupRepairView.swift:48), and Onboarding (OnboardingView.swift:164).
- **Breaks as**: This is the single user-facing remedy when per-app volume/mute stops working. If it silently stops re-applying saved state, routes come back but every app returns to 100%/unmuted. If the toast reverts to "success on no-throw", Waves claims "Routes recovered" while the Setup checklist still shows a failure — the user has no signal that anything is wrong.
- **Verify**: Manual: with capture permission revoked, click Recover Routes and confirm the toast says routes still need attention AND names the permission; re-grant, recover, confirm success and that previously-set per-app levels are re-applied rather than reset. Automated: GenerationAwareBackendTests / AudioHardeningTests — assert the unhealthy branch is taken when `isRouteRecoveryHealthy` is false.

## Durable per-app state restored at launch, on refresh, and for newly-appeared apps

- **Severity if broken**: P1
- **Where**: `Sources/Waves/Stores/AppStore.swift:2672`
- **What it does**: `reapplyRestoredAudioState` (:2672) runs during audio startup: it first downgrades any `.autoConferencing` mute back to `.user` (conferencing mutes are session-only), then replays every app's durable `PersistedAppAudioIntent` — volume, mute, boost, EQ settings, and target device — optionally overridden by the current device's preset. Failures for apps with a saved target device produce an explicit toast (:2697). `restoreNewlyAppearedConfiguredApps` (:2709) does the same for apps that appear during a refresh (called from `performRefresh` :1053 and the silent maintenance pass :1105), and `restoreDeviceVolumePresets` (:2724) on device change. `preferences.appAudioIntents` is the durable store (UserPreferences.swift:37) with a one-time migration from the legacy session/EQ maps (:40).
- **Breaks as**: This is what makes every per-app setting survive a relaunch. If it silently breaks, Waves comes up with everything at 100%/unmuted/default-routed and the user believes it forgot their entire configuration. If the `.autoConferencing` downgrade is lost, an app auto-muted for a call comes back muted after a restart with no visible cause.
- **Verify**: Manual: configure volume + mute + boost + EQ + a per-app route for three apps, quit Waves, relaunch, and confirm all five properties return for all three; separately, get an app auto-muted for a call, force-quit Waves during the call, relaunch, and confirm the app is NOT muted. Automated: PersistenceStoreTests / PersistedSchemaTests / GenerationAwareBackendTests — assert `reapplyRestoredAudioState` issues an intent per app with a stored durable intent.

## Global keyboard shortcuts ⌘⌥↑ / ⌘⌥↓ / ⌘⌥M on the frontmost app

- **Severity if broken**: P2
- **Where**: `Sources/Waves/App/WavesApp.swift:466`
- **What it does**: `handleGlobalKeyEvent` matches ⌘+⌥ (explicitly excluding ⌃ and ⇧ so third-party chords don't collide) plus keyCodes 126/125/46, ignores events while a text field is first responder, and returns `true` to consume the event so ⌘⌥M doesn't also fire Window > Minimize All. Both a global and a LOCAL monitor are installed (:436-451) so the keys work while Waves itself is frontmost. The monitors exist ONLY while `enableKeyboardShortcuts` is on (`updateGlobalHotkeysState` :341, driven by a NotificationCenter post from `setKeyboardShortcutsEnabled` :4719), and are torn down on terminate (:355/:402). Store handlers at :4440/:4458/:4475 re-check the preference, skip excluded apps, and use `frontmostManagedApp()` (:4400) which returns nil when Waves itself is frontmost. When audio isn't running the keypress surfaces the setup window instead (:487). UI: Settings > Shortcuts with the key legend (SettingsView.swift:613-627).
- **Breaks as**: Installing the monitor unconditionally means Waves observes every keystroke system-wide even for users who never enabled shortcuts — a privacy regression the current design explicitly avoids. Losing the text-field guard makes ⌘⌥M fire while typing. Losing the `true` return re-triggers Minimize All on every mute.
- **Verify**: Manual: with shortcuts off, confirm no key handling occurs; enable, confirm all three keys act on the frontmost app; press ⌘⌥M with a text field focused (must not fire) and with the Waves window frontmost (must not act on an arbitrary row). NOTE for the Stream Deck / per-app-mute-hotkey track: this is the only key-monitor install site and its enable-gate is the privacy contract — new hotkeys must extend `handleGlobalKeyEvent`, not add a second always-on monitor.

## Menu-bar extra: show/hide toggle and the four-state status glyph

- **Severity if broken**: P2
- **Where**: `Sources/Waves/App/WavesApp.swift:143`
- **What it does**: `MenuBarExtra(isInserted: $showMenuBarExtra)` with `.menuBarExtraStyle(.window)`. The glyph comes from `store.menuBarIconName` (:695) which is derived from the single `menuBarStatus` (:685) — setup / playing / muted / idle — with "playing wins over muted" ordering so the icon can never contradict the panel header. The VoiceOver label (WavesApp.swift:167) and the panel's status line (MenuBarMixerView.swift:249) read the same `menuBarStatus`. Status uses `isLive` (no linger) so the glyph drops back the moment audio stops. Toggle lives in Settings > General (SettingsView.swift:204) and in onboarding (OnboardingView.swift:222).
- **Breaks as**: Re-deriving the glyph independently reintroduces the shipped bug where the icon showed a slashed speaker and announced "muted" directly above a panel reading "1 app playing." Turning the extra off with no other entry point would strand a user with `LSUIElement`-style behavior and no window.
- **Verify**: Manual: mute one app while another plays — the glyph must show playing, not muted; stop all audio and confirm the glyph drops to idle within one poll interval; turn the extra off and confirm the main window is still reachable from the Dock.

## Source scopes: Running / Pinned / Live / Recent, plus the Sound workspace

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Features/Mixer/MainWindowView.swift:297`
- **What it does**: `SourceFilter` (:297) defines the four scopes with titles, counts, icons, and per-scope empty titles/messages. `scopedApps` (:226) maps each to a store property: `visibleApps` :489, `pinnedApps` :506, `liveApps` :543 (lingering), `recentApps` :617 (never-live, never-pinned, so no app appears in two sections). `SourceCounts` (:648) computes all four counts from ONE `visibleApps` evaluation — the sidebar previously cost roughly seven sorts per redraw. The Recent row is hidden when `showRecentApps` is off (:483), and the persisted scope is re-validated on launch (:202). Selected scope is restored across launches via `@SceneStorage("waves.selectedScope")` (:9, `MixerScope` RawRepresentable at :266).
- **Breaks as**: Reverting `sourceCounts` to per-scope computed properties reintroduces ~7 full sorts of the app list per sidebar body pass, at the level poll's cadence — directly against this release's goal. Losing the scope de-duplication makes the same app appear in Live and Recent simultaneously.
- **Verify**: Manual: confirm an app that just stopped playing appears in Live (lingering) and NOT in Recent, then moves to Recent; restart Waves and confirm the last-selected scope is restored. Automated: assert `sourceCounts` equals the individual scope array counts, and that `liveApps` and `recentApps` are disjoint.

## Search / filter apps (cross-scope, bounded, with scope-aware empty copy)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Features/Mixer/MainWindowView.swift:128`
- **What it does**: `.searchable(placement: .sidebar, prompt: "Filter apps")` at :128; `filteredApps` (:244) trims the query, caps it at 100 characters, and deliberately searches across ALL `visibleApps` rather than the selected scope, matching display name OR category display name. Because the result set is cross-scope, `isSearching` (:737) rewrites the header count noun to "result(s)" (:942, :922), the empty title to "No Results" (:750), and disables drag reorder (:782). The empty state offers a "Clear Search" button (:612).
- **Breaks as**: If `isSearching` and `filteredApps` drift apart on what counts as a query (e.g. one trims whitespace and the other doesn't), the header claims "3 running apps" over a list showing 0 rows, or the Clear Search button never appears. If reorder is not disabled during search, a drag maps subset indices onto the full list and scrambles the manual order.
- **Verify**: Manual: type a whitespace-only query (must not count as searching); type a query matching an app in another scope and confirm it appears; confirm no drag handles appear while searching. Automated: assert `reorderApps` is not invoked when the trimmed query is non-empty.

## In-window list keyboard control: Space/M mute, =/-/+ volume, B boost, P pin

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Features/Mixer/MainWindowView.swift:683`
- **What it does**: Six `.onKeyPress` handlers (:683-691) act on the List's selected row via `handleKey` (:795). These are deliberately NOT gated on `preferences.enableKeyboardShortcuts` — that toggle governs the global ⌘⌥ monitor only, and gating here would remove the only keyboard mute path whenever a user disables global hotkeys (documented at :788-794). Discoverability is provided by an `.accessibilityHint` (:695) and `.help` (:699), plus accessibility rotors for "Playing apps" and "Needs attention" (:703, :708) scoped to rendered rows only.
- **Breaks as**: Gating these on the global-shortcuts preference silently strips full keyboard operation of the mixer — an accessibility regression with no visible symptom. Rotors that enumerate cross-scope apps would move VoiceOver focus to nonexistent elements (silent no-op).
- **Verify**: Manual: with global shortcuts DISABLED, arrow to a row and press Space, =, -, B, P — all must work. VoiceOver: open the rotor and confirm every listed entry actually focuses a visible row.

## Guided onboarding: four-stage setup (Welcome / Audio / Personalize / Ready)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Features/Onboarding/OnboardingView.swift:4`
- **What it does**: Gated by `preferences.hasCompletedGuidedSetup` (MainWindowView.swift:99). Stages at :95 (privacy facts + consent surface), :130 (four live readiness checks; Continue is disabled until `readinessIsComplete` :431), :187 (appearance, palette, menu-bar, launch-at-login, show-recent, global shortcuts, Adaptive Mix enable/strategy/focus), :293 (summary of output, theme, adaptive, menu bar). `completeGuidedSetup` (AppStore.swift:838) flips the flag once. Existing installs decode `hasCompletedGuidedSetup` as `true` (UserPreferences.swift:130) so they never see it again; new installs decode `hasCompletedPrivacySetup` as `false`.
- **Breaks as**: Inverting either decode default forces every existing user back through onboarding on upgrade, or skips the privacy explanation for a new install before the first capture request — a privacy-contract violation.
- **Verify**: Manual: launch with an empty Application Support/Waves and confirm the full four-stage flow appears; launch with a preferences file that lacks both keys and confirm neither the privacy gate nor the walkthrough is shown. Automated: PrivacyStartupTests / UserPreferencesTests — keep the missing-key default assertions.

## Setup & Repair pane (five live checks with System Settings deep links)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Features/Onboarding/SetupRepairView.swift:4`
- **What it does**: Five repair rows, each bound to a real backend/OS signal with a matching remedy: managed-audio support (macOS 14.2 gate, :160), audio-capture permission (five-state `captureAuthorization` incl. `probeFailed(status)`, :174, deep-links to Privacy_AudioCapture), Accessibility (:29, deep-links to Privacy_Accessibility), output device (:37, deep-links to Sound-Settings), managed routes (:44, runs `recoverRoutes`), plus a conditional Launch-at-login approval row (:52). "Refresh All Checks" (:64) and "Redo Guided Setup…" (:72, presents `OnboardingView` in a sheet, explicitly non-destructive per the copy at :78). Auto-refreshes on appear and on scenePhase active (:89/:90). Deep-link URLs live in SystemSettingsService.swift:10.
- **Breaks as**: If a deep-link URL scheme breaks (macOS changes the pane identifier), the button becomes a silent no-op and the user is told to fix a permission with no way to get there. If "Redo Guided Setup" stops being non-destructive, it would wipe levels/profiles/EQ — the copy explicitly promises it won't.
- **Verify**: Manual: click each of the four "Open …" buttons and confirm the correct System Settings pane opens on the target macOS version; run Redo Guided Setup to completion and confirm profiles, per-app levels, EQ curves, palette, and preferences are all unchanged.

## Update checks (Sparkle): manual check from three places, automatic-check toggle, release notes link

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Services/UpdaterService.swift:7`
- **What it does**: `UpdaterService` starts the Sparkle updater ONLY when the bundle has a non-empty `SUFeedURL` (:35) — a bare `swift run` or the test host does not arm the scheduler, which otherwise puts up a modal NSAlert a headless test host can never dismiss and hangs the whole suite. Two KVO observations keep `canCheckForUpdates` and `automaticallyChecksForUpdates` in sync with Sparkle, with a re-entrancy flag (:11) to avoid a write loop. UI: the app menu "Check for Updates…" (WavesApp.swift:80), the About window button (AboutView.swift:26), and Settings > General > Updates (SettingsView.swift:251) with the automatic-check toggle and the explicit network-behavior footer (:284). Feed URL and EdDSA key are asserted at package time (script/build_and_run.sh:697).
- **Breaks as**: Changing the `hasUpdateFeed` guard to key on bundle identifier (or removing it) re-arms Sparkle in the test host and can hang `swift test` indefinitely — this is a documented, previously-hit failure. Losing the KVO sync makes the automatic-check toggle drift from Sparkle's real state.
- **Verify**: Automated: run the full suite (272 tests, ~4.4 s) and confirm no hang. Manual: in a packaged build, use all three Check-for-Updates entry points and toggle automatic checks, then reopen Settings and confirm the toggle reflects Sparkle's stored value.

## Per-app volume boost, 1x–4x

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:1823`
- **What it does**: `setVolumeBoost` clamps to 1...4 and applies through the same durable intent path as volume/mute (so boost is also stored per output device). UI: the `BoostMenu` at MixerRowView.swift:526, rendered in both row densities (:96 full, :426 compact) with a status treatment — accent+semibold once boost > 1. Keyboard: `B` cycles 1→2→3→4→1 on the selected row (MainWindowView.swift:690 / :809). Clamp is duplicated in `AppVolumeSettings.init` (UserPreferences.swift:180).
- **Breaks as**: Losing the clamp allows a persisted or URL-injected boost above 4x, which is a real speaker-damage / clipping risk. Losing the durable write means a boosted app reverts to 1x on relaunch and the user thinks the app got quieter.
- **Verify**: Manual: set boost to 3x, relaunch, confirm 3x persists; press B repeatedly on a selected row and confirm it wraps at 4x. Automated: assert `setVolumeBoost(9, for:)` results in 4 and `setVolumeBoost(0.1, for:)` results in 1.

## System-wide output device switching from the menu bar

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:2496`
- **What it does**: `selectOutputDevice` sets the macOS default output device, refreshes the device list, and marks the switch self-initiated (`pendingSelfInitiatedDeviceID`) so the device-change listener suppresses a duplicate toast. UI: `OutputDevicePicker` in the menu-bar panel (MenuBarMixerView.swift:266) with a checkmark on `store.currentDeviceID` and a `.onAppear { store.refreshOutputDevices() }` (:305). Device list is also refreshed by the per-app submenu (MixerRowView.swift:318) and on every device-change pass.
- **Breaks as**: A user loses the one-click headphones/speakers switch from the menu bar and has to go to System Settings. A regression in `pendingSelfInitiatedDeviceID` produces two contradictory toasts per switch.
- **Verify**: Manual: open the menu-bar panel, switch output, confirm audio moves, the checkmark follows, and exactly ONE toast appears ("Output switched", not also "Output device changed").

## Adaptive strategies (Lecture Focus / Media First / Balanced / Custom) with a confirmation dialog

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:1973`
- **What it does**: `applyAdaptiveStrategy` rewrites the adaptive policy for EVERY visible app from `AdaptiveMixing.policy(for:contentType:existingPolicy:)`, sets `preferences.adaptiveStrategy`, persists, and restarts mixing. Because it is destructive to hand-tuned per-app policies, the Sound workspace gates it behind a confirmation dialog whenever policies already exist (SoundWorkspaceView.swift:373-381 and the dialog at :49). Onboarding applies it without confirmation (OnboardingView.swift:251) — correct, since there is nothing to lose yet. Any per-app edit flips the strategy to `.custom` (:1991).
- **Breaks as**: Dropping the confirmation dialog turns a stray segmented-control click into silent destruction of every per-app content-type/priority assignment, with no undo.
- **Verify**: Manual: set a custom priority on one app, then pick a different strategy — the confirm dialog must appear and Cancel must leave the custom policy intact. Automated: assert `applyAdaptiveStrategy` mutates `preferences.adaptiveAppPolicies` for all visible apps and that `setAdaptivePriority` sets `adaptiveStrategy == .custom`.

## Sidechain Focus mode (Assigned Priorities / Follow Front App / Smart Hybrid)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:2027`
- **What it does**: `setAdaptiveFocusMode` decides how the frontmost app interacts with assigned priorities; the frontmost resolution for this path deliberately does NOT fall back to an arbitrary row (`frontmostManagedAppIDForAdaptiveMix` :4427 returns nil for unmanaged/Waves-itself), unlike the hotkey path. UI: Sound workspace picker (SoundWorkspaceView.swift:407) with per-mode explanatory copy (:534), and an onboarding picker (OnboardingView.swift:269).
- **Breaks as**: If `frontmostManagedAppIDForAdaptiveMix` gains the hotkey path's `activeApps.first` fallback, Waves will duck the wrong apps whenever the user focuses an unmanaged app or Waves itself — an intermittent, hard-to-report "my music randomly drops" bug.
- **Verify**: Manual: with Smart Hybrid, focus an unmanaged app (e.g. Finder) while music and a voice app play — no priority shift should occur. Automated: AdaptiveFocusModeTests; assert nil is returned when the frontmost pid equals the current process.

## Per-app adaptive content type and priority (App Priorities table)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:1961`
- **What it does**: `setAdaptiveContentType` (:1961) and `setAdaptivePriority` (:1967) write into `preferences.adaptiveAppPolicies` keyed by logical ID. `adaptivePolicy(for:)` (:1949) is deliberately pure — it derives a default from the legacy role + category + bundle ID without writing back (a prior version mutated observed state during view render). Six content types and four priorities (`Never Adjust` opts an app out entirely). UI: the App Priorities table at SoundWorkspaceView.swift:434 / row at :597, disabled for excluded apps (:645).
- **Breaks as**: Re-introducing the write-on-read side effect causes SwiftUI state mutation during view updates plus a preferences write on every render pass. Losing `Never Adjust` means Waves ducks a DAW or a game the user explicitly protected.
- **Verify**: Manual: set an app to Never Adjust, play it alongside a voice app, confirm its level never moves. Automated: assert `adaptivePolicy(for:)` does not mutate `preferences.adaptiveAppPolicies` when no policy is stored.

## Profile delete (both surfaces, both confirmation-gated)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:4099`
- **What it does**: `deleteProfiles(at:)` clears `activeProfileID` and `preferences.defaultProfileID` if the deleted profile held either, then persists. Both UI entry points intentionally confirm first because a captured mix has no undo: sidebar context menu → `confirmationDialog` (MainWindowView.swift:437 + :460) and Settings > Profiles row → its own dialog (SettingsView.swift:569 + :575). The main window also re-validates the selected scope when the profile list changes (MainWindowView.swift:66/:202).
- **Breaks as**: Losing either confirmation makes a hand-tuned mix destroyable with one misclick. Losing the `defaultProfileID` cleanup leaves a dangling startup default that silently does nothing every launch.
- **Verify**: Manual: mark a profile as the startup default, delete it, confirm the Settings > Profiles "Apply at startup" picker falls back to None and the sidebar selection falls back to Running.

## Profile export and import as JSON (versioned envelope, bounded, atomic batch)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:4122`
- **What it does**: `exportProfile` (:4122) writes a `VersionedPayload<[Profile]>` envelope via NSSavePanel anchored to `NSApp.keyWindow ?? mainWindow`. `importProfiles` (:4164) enforces a 10 MB cap both by pre-read stat and post-read length, accepts the versioned envelope, a bare `[Profile]`, a single exported profile, and legacy `presets.json` (`ProfilePayloadDecoder`), validates name/entry bounds for the WHOLE batch into a working copy before committing so one bad entry cannot leave a half-imported library (:4216-4267), and re-IDs imported profiles to avoid UUID collisions. UI: Settings > Profiles Import button (SettingsView.swift:500), Export in the profile row (:564) and the sidebar context menu (MainWindowView.swift:435).
- **Breaks as**: Losing the working-copy staging turns a multi-profile backup restore with one malformed entry into a partially-applied import. Losing the size caps makes a hostile/huge JSON an OOM. Losing the re-ID breaks SwiftUI list identity on collision.
- **Verify**: Manual: export a profile, import it back (should merge by name, not duplicate); import the app's own `profiles.json`; import a truncated JSON and confirm the library is unchanged. Automated: PersistedSchemaTests / PersistenceStoreTests — keep the `decodeImportedProfiles` shape coverage.

## Default profile applied at startup

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:3952`
- **What it does**: `setDefaultProfile` stores `preferences.defaultProfileID`; `applyDefaultProfileAtStartupIfNeeded` (:3968) applies it once audio reaches `.running` (called at :946) with `purpose: .defaultAtStartup`, so it deliberately does NOT create a restore point. Only level-bearing profiles qualify. UI: sidebar context menu toggle "Apply at Startup" / "Don't Apply at Startup" (MainWindowView.swift:428-431), Settings > Profiles picker (SettingsView.swift:453), and a "· startup" suffix in both subtitle strings (MainWindowView.swift:539, SettingsView.swift:598).
- **Breaks as**: If the startup apply is dropped or ordered before `startupState == .running`, the user's baseline mix silently stops coming up at launch and they re-tune it by hand every day without knowing why.
- **Verify**: Manual: set a startup default, quit, relaunch, confirm the levels are applied without a manual click and that Reset Mix does NOT appear in the toolbar afterwards (no restore point at launch).

## Reset Mix (one-click return to the pre-profile mix)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:3917`
- **What it does**: `captureMixRestorePoint` (:3882) snapshots volume/mute/boost for every visible app right before a level-bearing profile is applied, but deliberately gives untouched apps a membership-only entry (`isOwned` check at :3895) so restoring does not mass-enroll every running app into managed routes. Only the first apply in a chain captures (:3236), so Meeting→Focus still resets to the original. `resetMix` (:3917) re-applies with `purpose: .mixReset`, clears the restore point and active profile. `discardMixRestorePoint` :3937. UI: toolbar button, shown only while a restore point exists (MainWindowView.swift:138) and the menu-bar profile picker (MenuBarMixerView.swift:328).
- **Breaks as**: Reverting the `isOwned` guard turns Reset Mix into a mass-enrollment button — a process tap, private aggregate device, and live IOProc per running app, plus a durable intent replayed on every subsequent launch. That is exactly the class of CPU/route bloat this release is trying to eliminate.
- **Verify**: Manual: with 10 running apps but only 2 ever touched, apply a level-bearing profile then Reset Mix, and confirm in Diagnostics/Advanced that the managed-app count does not jump to 10. Automated: assert `captureMixRestorePoint` produces `hasLevels == false` entries for apps with `routingState != .managed` and no durable intent.

## Pinning apps to the top (persisted in preferences, survives app quit/relaunch)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:2204`
- **What it does**: `togglePinned` writes `preferences.pinnedAppIDs` as the authoritative source (so a pin outlives the app quitting and a Waves relaunch), optimistically mirrors onto the session row, and best-effort syncs the backend. `visibleApps` (:494-502) reconciles `isPinned` from preferences on every read, feeding `pinnedApps`, the Pinned scope, and the menu-bar Pinned section. UI: context menu (MixerRowView.swift:288), compact-row pin button (:340), `P` key on the selected row (MainWindowView.swift:691), VoiceOver action (:168/:478).
- **Breaks as**: If pin state moves back onto the session row only, every pin is lost when the app quits or Waves restarts — the menu-bar Pinned section empties itself and users lose their curated top-of-list.
- **Verify**: Manual: pin an app, quit that app, relaunch it, confirm it returns pinned; quit and relaunch Waves and confirm the same. Automated: UserPreferencesTests — assert `pinnedAppIDs` round-trips and `visibleApps` reconciles `isPinned` from it.

## Sort modes: Activity / Name / Category / Manual

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:4754`
- **What it does**: `sortedApps` runs on every `visibleApps` read (several times a second under the level poll). Name mode uses decorate-sort-undecorate with a case+diacritic-folded key (:4733/:4741) instead of paying ICU collation per comparison. Activity ranks live=0, recently-live=1 (via the shared `isRecentlyLive`, so the sort agrees with Live-list membership), frontmost=2, managed=3, else 4 (:4779). All modes tiebreak on `logicalID` because Swift's sort is unstable and rows would otherwise swap under the pointer (:4809). UI: Settings > Mixer picker (SettingsView.swift:338).
- **Breaks as**: Reverting to `sorted { $0.displayName.localizedCompare... }` puts a full ICU collation on every comparison of an O(n log n) sort that runs several times a second. Losing the `logicalID` tiebreak makes identically-named rows jump under the cursor mid-click.
- **Verify**: Manual: switch each sort mode and confirm order is sensible and stable while audio plays; check that Activity keeps a just-silenced app near the top for the linger window. Automated: assert two apps with identical `displayName` sort deterministically across repeated calls.

## Manual drag-to-reorder (with VoiceOver Move Up/Down equivalents)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:4829`
- **What it does**: `reorderApps(from:to:)` snapshots the displayed order BEFORE flipping `sortMode` to `.manual` (switching first would re-sort under the drag indices), bounds-checks both source and destination against that snapshot, uses `move(fromOffsets:toOffset:)` (the hand-rolled remove/insert was off by one on downward drags), and splices the reordered visible IDs back into `customAppOrder` so hidden apps keep their saved positions. UI: `.onMove` at MainWindowView.swift:667 gated by `isReorderable` (:782 — Running scope, no active search), `.moveDisabled(!isReorderable)` at :676, and accessibility Move Up / Move Down actions at :652 that call the same store method.
- **Breaks as**: Losing the pre-flip snapshot silently reorders the wrong rows. Losing the splice drops system processes (hidden by `showSystemProcesses`) from `customAppOrder` so they sink to the bottom once shown. Losing the accessibility actions makes reordering VoiceOver-inaccessible with no alternative.
- **Verify**: Manual: with system processes hidden, drag a row down 3 positions, then enable system processes and confirm the hidden apps kept their relative positions; repeat the same move via VoiceOver's Move Down action. Automated: assert `reorderApps(from: IndexSet(integer: 0), to: 3)` lands the row at index 2 (post-removal semantics) and that IDs absent from `visibleApps` survive in `customAppOrder`.

## Auto-pause (mute) media apps during video calls

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:3116`
- **What it does**: `performAutoPausePass` (:3086) reads the live `NSWorkspace.frontmostApplication` (not the periodically-refreshed snapshot), infers a category via `AppDiscoveryPolicy.inferCategory`, and short-circuits when frontmost is unchanged. `applyAutomaticConferencingTransition` (:3116) mutes `.media` apps tagged `muteSource: .autoConferencing` and resumes only apps in `pausedMusicApps` with that tag. Passes are coalesced with a pending-rerun flag (:3061), triggered by app activation (:2901) and by app termination when auto-paused mutes remain (:2993). Turning the preference off still runs a resume-only sweep (:3088) so nothing is stranded muted. Mutually exclusive with speech-focus Adaptive Mix (:2010, :3012). UI: Settings > Mixer > Calls (SettingsView.swift:400).
- **Breaks as**: Losing the resume-only sweep on disable strands media apps muted with no visible cause. Losing the termination hook leaves music muted forever if the conferencing app crashes and macOS doesn't promptly activate another app.
- **Verify**: Manual: start music, focus Zoom (music mutes with a toast), force-quit Zoom, confirm music resumes; separately, mute music via auto-pause then turn the preference off and confirm it resumes immediately. Automated: call `applyAutomaticConferencingTransition(isConferencingActive:)` true then false and assert mute/unmute plus `muteSource` transitions.

## URL scheme automation: set-volume, mute, apply-profile (alias apply-preset), refresh

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:1117`
- **What it does**: `handleURLScheme` gates on audio running, on `preferences.enableURLScheme` (default OFF), on an 8 KB payload cap (WavesApp.swift:7), and on a 10-requests-per-60-seconds rate limit (:1239) that is charged only against well-formed `waves://` commands so malformed floods can't exhaust the quota. Throttling surfaces a debounced toast (max one per 5 s). Handlers validate parameter lengths and ranges and refuse excluded apps (:1175, :1201, :1224). Delivery is via a manual `kAEGetURL` Apple Event handler (WavesApp.swift:407) that replaces AppKit's default dispatch — the SwiftUI `onOpenURL` at MainWindowView.swift:44 is a secondary path. Scheme registered in the packaged Info.plist (script/build_and_run.sh:542). UI: Settings > Shortcuts toggle (SettingsView.swift:637), documented in Help (HelpView.swift:153).
- **Breaks as**: If `enableURLScheme` stops being checked, any web page can silently mute or re-mix the user's audio. If the rate limiter is removed, a link loop can drive unbounded backend transactions. If the Apple Event handler is removed in favor of `application(_:open:)`, `waves://` invocations become unreachable entirely.
- **Verify**: Manual: with the toggle off, run `open 'waves://mute?app=com.spotify.client&muted=true'` — nothing should happen; enable it and confirm it works; fire 15 commands in a burst and confirm the throttle toast appears once. NOTE for the control-socket track: this is the existing automation contract (gate + rate limit + excluded-app refusal). A Unix socket should reuse the same gating and the same `applyAppIntent` boundary rather than calling setters directly, and must avoid `requireAudioRunning()`'s toast on every rejected call (:1002) — a polling client would spam the toast stack.

## Launch at login (with the macOS approval-pending path)

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:737`
- **What it does**: `launchAtLoginEnabled` is a get/set computed property backed by `SMAppService` through `LoginItemService` (LoginItem/LoginItemService.swift:44). `launchAtLoginRequiresApproval` (:773) and `launchAtLoginStatusDescription` (:777) expose the intermediate "registered but awaiting approval in System Settings" state, and `openLoginItemsSettings` (:781) deep-links there. `reconcileLoginItemStatus` (:4911) re-reads the OS status on every `applicationDidBecomeActive` (WavesApp.swift:335) so a change made in System Settings doesn't leave the in-app toggle stale. UI: menu-bar footer toggle (MenuBarMixerView.swift:178), Settings > General with the approval warning + button (SettingsView.swift:208/:217), onboarding (OnboardingView.swift:224), and a Setup & Repair row when approval is pending (SetupRepairView.swift:52).
- **Breaks as**: Losing the reconcile makes the toggle lie after the user changes it in System Settings. Losing the approval branch shows a toggle that appears off and does nothing, with no hint that macOS is waiting for the user.
- **Verify**: Manual: enable the toggle, open System Settings > General > Login Items, disable it there, return to Waves, and confirm the toggle updates without a relaunch.

## Diagnostics: live checks panel, Advanced pane checks, refresh, and Copy Diagnostics

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:2472`
- **What it does**: `diagnosticsExportText` (:2472) builds a bounded (`maximumReportCharacters` 65 536, 50 app rows, 20 checks) deterministic plain-text report via `DiagnosticsExportFormatter`, including app/build/source-revision metadata, capture authorization, session, device count, persistence failure count, the current shutdown result, AND the previous launch's shutdown report — deliberately excluding live levels/samples. `copyDiagnosticsToPasteboard` (:2517) is the only export path (clipboard, not file). `refreshDiagnostics` (:4364) rebuilds the backend snapshot FIRST so checks aren't computed from stale `backendStatus`. UI: the collapsible `DiagnosticsPanel` in the main window with an "N issues" pill and a 220 pt height cap (MainWindowView.swift:1062, cap rationale at :1066 — an uncapped DisclosureGroup blanked the entire window), and Settings > Advanced (SettingsView.swift:672) with device info, Recover Routes, Open Setup & Repair, Copy Diagnostics, the check list, and a `DiagnosticsUnavailableView` fallback (:770).
- **Breaks as**: Removing the 220 pt cap reproduces a confirmed AppKit/SwiftUI layout corruption that collapses the whole NavigationSplitView to nothing when the disclosure is expanded with several checks present. Reordering `refreshDiagnostics` back to computing diagnostics before the snapshot rebuild makes the Advanced checks show stale warnings. Losing the export means bug reports arrive with no state.
- **Verify**: Manual: with capture permission denied (several failing checks), expand the Diagnostics disclosure in the main window and confirm the window does not blank; click Copy Diagnostics and paste — confirm version, build, source revision, checks, and the previous-shutdown section are present and the text is under 64 KB.

## Live level meters, mixed-waveform visualizer, and the visibility-gated level poll

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:2266`
- **What it does**: `beginLiveLevels`/`endLiveLevels` (:2266/:2337) are reference-counted across the main window and menu-bar panel; `setUISurfaceVisible` (:2353) is driven by window occlusion via `RenderActivityMonitor` (WavesApp.swift:40). Cadence is 300 ms when a metering surface is genuinely visible and 1 s otherwise (:2245/:2254) — polling can never stop entirely because the menu-bar glyph is itself a surface and `isLive` treats the poll as authoritative for managed apps. Levels are deliberately NOT cleared when hidden (:2350). Consumers: per-row `RowLevelMeter` (RowLevelMeter.swift:75, drawn as an overlay so it never shifts layout), `HeaderWaveform` (MixedWaveformView.swift:520) fed by `waveComponents` (:590, capped at the 6 loudest) and `mixedAudioLevel` (:572, root-sum-of-squares with a perceptual curve and tanh clamp), plus EQ/Focus chips naming what is shaping the sound (MixedWaveformView.swift:530-538).
- **Breaks as**: Removing the idle heartbeat makes the menu-bar glyph and its VoiceOver label report "idle" for the entire time a managed app plays behind a hidden window. Clearing levels on hide does the same. Making the meter animate by resizing a frame again reintroduces the per-frame AppKit layout thrash this release already fixed.
- **Verify**: Manual: start playback, hide every Waves window (⌘H / another Space), and confirm the menu-bar glyph still shows playing; reopen the window and confirm meters resume smoothly. Automated: RenderActivityTests / MeterBallisticsTests; assert `levelPollInterval` is 1 s when `liveLevelsRefcount == 0` and 300 ms when a surface is visible.

## Corrupt-store recovery notice and previous-shutdown reporting

- **Severity if broken**: P2
- **Where**: `Sources/Waves/Stores/AppStore.swift:956`
- **What it does**: `presentRecoveredStoreWarningIfNeeded` shows ONE combined warning naming which of device presets / profiles / settings / session had to be reset, and states that the originals are preserved as `.corrupt` files — instead of a silent reset. Separately, `ShutdownReportStore` (Persistence/ShutdownReportStore.swift) is read once at launch into `store.previousShutdownReport` and then CLEARED (WavesApp.swift:311), so a force-quit or kernel kill leaves no file and the next launch honestly reports "nothing recorded" rather than replaying the last graceful quit's "clean" result. The report is written synchronously before the terminate reply (WavesApp.swift:368) and surfaces in the diagnostics export.
- **Breaks as**: Not clearing the report makes a crash display the previous graceful quit's "clean" status — precisely the failure that made a 1.3.0 degraded cleanup unexplainable. Losing the recovery toast means a user whose profiles.json was corrupted just finds their profiles gone with no explanation and no idea a backup exists.
- **Verify**: Manual: corrupt `~/Library/Application Support/Waves/profiles.json`, launch, confirm the "Saved data recovered" warning names profiles and that a `.corrupt` file exists beside it; then force-quit Waves (`kill -9`), relaunch, and confirm Copy Diagnostics reports no recorded shutdown rather than "clean". Automated: ShutdownReportTests / ShutdownTests / PersistenceStoreTests.

## Appearance and palette settings (System/Light/Dark × Waves/Graphite)

- **Severity if broken**: P3
- **Where**: `Sources/Waves/Settings/SettingsView.swift:188`
- **What it does**: Two independent preferences applied through `.wavesTheme(palette:appearance:)` on every scene — main window (WavesApp.swift:58), About (:117), Settings (:136), menu-bar panel (:150) — so all four surfaces change together. Enums at WavesTheme.swift:4 and :39 with concrete per-(palette, appearance) color tables (:139-199). The whole Settings window is `.tint(theme.accent)` (SettingsView.swift:85) and the Settings sidebar is a hand-built `List(selection:)` rather than a native icon TabView, precisely because the native selected-tab pill always renders in the SYSTEM accent color and ignores `.tint` (documented at :53-66). Also settable during onboarding (OnboardingView.swift:200/:209).
- **Breaks as**: Reverting the Settings sidebar to a native icon-style TabView reintroduces the accent bleed: on a Mac whose system accent is Red, the very first thing shown in Settings renders in a jarringly wrong color. Missing `.wavesTheme` on any new scene leaves that window in the default appearance while the rest of the app follows the preference.
- **Verify**: Manual: set the macOS system accent to Red, then open Settings, About, the menu-bar panel, and the main window in both palettes and both appearances — no red chrome should appear anywhere. Automated: WavesThemeTests / WavesBrandAssetTests.

## Live-list linger (how long a quiet app stays in Live: Brief / Standard / Relaxed)

- **Severity if broken**: P3
- **Where**: `Sources/Waves/Stores/AppStore.swift:3051`
- **What it does**: `setLiveListLinger` persists the choice and rebuilds all pending removal tasks so the change takes effect immediately. Durations 1 s / 2.5 s / 5 s (UserPreferences.swift:160). `refreshLiveLinger` (:2311) reconciles `recentlyLiveIDs` on every level poll and only mutates the observed set when membership actually changes, so a steady scene triggers no redraws. `isRecentlyLive` (:539) drives Live membership and the row subtitle; `isLive` (:525, no linger) drives the meters, waveform, menu-bar glyph, and "N playing" text — the two are deliberately different. UI: Settings > Mixer picker (SettingsView.swift:322) with a footer explaining when to change it (:345).
- **Breaks as**: Collapsing `isRecentlyLive` and `isLive` into one concept either makes rows blink out on every track gap (using the real signal for membership) or makes the menu-bar icon and header keep claiming "1 app playing" for seconds after silence (using linger for status).
- **Verify**: Manual: with Relaxed, pause playback and confirm the row stays in Live ~5 s while the meter and menu-bar glyph drop immediately; switch to Brief mid-linger and confirm the row leaves sooner. Automated: RenderActivityTests/MeterBallisticsTests cover the render side; assert `recentlyLiveIDs` is unchanged across polls with a steady live set.

## Toast notification system (feedback for every mutation, with hover-to-pause)

- **Severity if broken**: P3
- **Where**: `Sources/Waves/Stores/AppStore.swift:5089`
- **What it does**: `showToast` is the single feedback channel for essentially every user action in the app — success/failure of volume, mute, boost, routing, profile apply/import/export/delete, pin, exclude, device switch, route recovery, adaptive mode changes, URL-scheme rejections, throttling, corrupt-store recovery, and startup. Dismissal is scheduled per toast (:5136) with `dismissToast` (:5150) and `pauseToastDismissal` (:5162) for hover. Rendered by `AppToastStack` (AppToasts.swift:3) in both the main window (MainWindowView.swift:16) and the menu-bar panel (MenuBarMixerView.swift:77, width-constrained). Several sites deliberately suppress duplicate toasts (`showToast: false` in `excludeUnroutableApps`, the self-initiated device-switch flag, the debounced URL throttle notice, the single-toast-per-keypress comments at :4452).
- **Breaks as**: If the per-toast dismissal tasks leak or stop being cancelled, toasts stack indefinitely and cover the mixer. If the duplicate-suppression flags are lost, single actions produce two or three near-identical toasts — the exact noise this design removed.
- **Verify**: Manual: switch the output device from the menu bar and confirm exactly ONE toast; exclude 5 unroutable apps via the banner and confirm ONE combined toast; hover a toast and confirm it does not dismiss until the pointer leaves.
