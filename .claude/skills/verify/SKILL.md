---
name: verify
summary: Runtime verification recipe for the packaged Waves macOS app
---

# Verify Waves at the GUI surface

1. Build a fresh package with `./script/build_and_run.sh --release-check`, then run `--verify` and `--package-smoke` for package-level checks.
2. Never activate Waves by name: `/Applications/Waves.app` may also be installed. Launch the exact candidate executable with isolated persistence:
   ```bash
   ROOT=$(mktemp -d /tmp/waves-verify.XXXXXX)
   mkdir -p "$ROOT/home"
   HOME="$ROOT/home" CFFIXED_USER_HOME="$ROOT/home" \
     "$PWD/dist/Waves.app/Contents/MacOS/Waves" >"$ROOT/app.log" 2>&1 &
   PID=$!
   ```
3. Activate only that PID with `NSRunningApplication(processIdentifier:)`. Find its window through `CGWindowListCopyWindowInfo` using the owner PID, then capture it with `screencapture -l <window-id>`.
4. Fresh-home verification must remain pre-consent: do not click **Continue and Start Waves** unless real TCC behavior is explicitly in scope. Observe:
   - Privacy explanation is visible and the app remains alive.
   - `hasCompletedPrivacySetup` remains false.
   - `session.json` is absent before consent.
   - Repeated Cmd-R cannot start capture or create a session.
   - Settings > Setup shows local processing as the prerequisite; Audio actions are disabled/no-device while gated.
5. Quit the exact PID with Cmd-Q through System Events. Verify exit completes within the five-second termination budget, no process remains at the candidate executable path, consent stays false, and generated store files are mode `0600` under a `0700` directory.
6. Use deterministic Swift tests for post-consent routing/profile/automation paths unless a real Core Audio/TCC run is explicitly authorized.

Gotchas:
- A name-based AppleScript `activate` or URL-scheme invocation can launch the installed `/Applications` copy and trigger its TCC prompt.
- `System Events` may not frontmost a directly launched executable reliably; use `NSRunningApplication.activate(options: [.activateAllWindows])` by PID.
- Capture the Waves window by CGWindow ID so unrelated desktop content is excluded.
