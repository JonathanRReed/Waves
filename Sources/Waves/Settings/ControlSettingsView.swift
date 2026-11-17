import AppKit
import SwiftUI
import WavesAudioCore

struct ControlSettingsView: View {
  @Environment(AppStore.self) private var store
  let draft: ControlSettingsDraft

  var body: some View {
    SettingsForm {
      Section {
        Toggle(
          isOn: Binding(
            get: { store.preferences.enableKeyboardShortcuts },
            set: { store.setKeyboardShortcutsEnabled($0) }
          )
        ) {
          Text("Enable keyboard shortcuts")
          Text("Control the app in front from anywhere, no need to open Waves first.")
        }
        .disabled(!store.isAudioRunning)
        if store.preferences.enableKeyboardShortcuts {
          ForEach(Self.frontmostActions, id: \.action) { entry in
            shortcutRow(entry.title, action: entry.action)
          }
        }
      } header: {
        Text("Global Shortcuts")
      } footer: {
        SettingsFooter(
          "The first three act on whichever app is in front. Click a shortcut to change it, or press Delete while recording to remove it. Waves registers only these combinations and never watches your other keystrokes."
        )
      }

      Section {
        if store.preferences.enableKeyboardShortcuts {
          if appShortcutRows.isEmpty {
            Text("No app shortcuts yet.")
              .foregroundStyle(.secondary)
          }
          ForEach(appShortcutRows, id: \.self) { appID in
            appShortcutRow(appID)
          }
          addAppShortcutMenu
        } else {
          Text("Turn on keyboard shortcuts above to control a specific app.")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("App Shortcuts")
      } footer: {
        SettingsFooter(
          "Mute or adjust one specific app from anywhere, whatever is in front. Nothing is assigned by default. You can also assign one from an app's row in the mixer."
        )
      }

      Section {
        Toggle(
          isOn: Binding(
            get: { store.preferences.enableURLScheme },
            set: {
              store.preferences.enableURLScheme = $0
              store.preferences.urlSchemeAutomationAcknowledged = true
              store.persistPreferences()
            }
          )
        ) {
          Text("URL scheme automation")
          Text("Lets other apps and links send waves:// commands, like setting a volume or applying a profile.")
        }
        .disabled(!store.isAudioRunning)

        Toggle(
          isOn: Binding(
            get: { store.preferences.enableExternalControl },
            set: {
              store.preferences.enableExternalControl = $0
              store.persistPreferences()
              // Start or stop the socket right now. Without this the toggle
              // would only take effect on the next launch, and a plugin sitting
              // on "turn this on in Waves" would keep saying so.
              store.externalControlPreferenceChanged()
            }
          )
        ) {
          Text("Allow external control")
          Text("Lets a Stream Deck plugin, or the wavesctl tool, read your apps and change their volume and mute.")
        }
        .disabled(!store.isAudioRunning)
      } header: {
        Text("Automation")
      } footer: {
        SettingsFooter(
          "Both are off by default. Turn them on only for automation you trust. External control listens on a private socket that only your user account can reach, never the network."
        )
      }
    }
    .onAppear { draft.finishPaneReplacement() }
  }

  private static let frontmostActions: [(title: String, action: HotkeyAction)] = [
    ("Increase volume", .frontmostVolumeUp),
    ("Decrease volume", .frontmostVolumeDown),
    ("Toggle mute", .frontmostMute),
    // Not a frontmost action, but it belongs with the global keys: it is the one
    // shortcut that works from inside a full-screen app, where the menu bar is
    // hidden and Waves is otherwise unreachable.
    ("Show Waves", .showMixer),
  ]

  /// Bound apps first, sorted by name, then the rows still waiting for a chord.
  ///
  /// Sorting by name keeps the list from reshuffling as apps launch and quit;
  /// pending rows stay at the end so the one just added doesn't jump away from
  /// the pointer that added it.
  private var appShortcutRows: [String] {
    let bound = store.preferences.hotkeys.boundAppIDs
      .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    return bound + draft.pendingAppIDs.filter { !bound.contains($0) }
  }

  /// Only apps with no shortcut and no pending row, so the menu can't offer a
  /// duplicate that would silently replace what is already there.
  private var assignableApps: [AudioApp] {
    let taken = takenAppIDs
    return store.visibleApps.filter { !taken.contains($0.logicalID) && !store.isExcluded($0) }
  }

  private var takenAppIDs: Set<String> {
    var taken = Set(store.preferences.hotkeys.boundAppIDs)
    taken.formUnion(draft.pendingAppIDs)
    return taken
  }

  @ViewBuilder
  private var addAppShortcutMenu: some View {
    Menu {
      ForEach(assignableApps) { app in
        Button(app.displayName) {
          draft.addPendingApp(app.logicalID)
        }
      }
      if assignableApps.isEmpty {
        // Name the actual reason. "Every running app already has a shortcut" was
        // shown even when the real cause was that every app is excluded, or that
        // nothing is running yet. Three different situations, one wrong answer.
        Text(emptyAppMenuReason)
      }
      Divider()
      // Running apps only would be the wrong roster: a shortcut is stored
      // against a bundle ID and works the moment that app launches, so binding
      // one for an app you have quit, the common case for "mute Spotify",
      // should not require launching it first.
      Button("Choose App…") { chooseAppForShortcut() }
    } label: {
      Label("Add App Shortcut", systemImage: "plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var emptyAppMenuReason: String {
    if store.visibleApps.isEmpty { return "No apps are running yet" }
    if store.visibleApps.allSatisfy(store.isExcluded) { return "Every running app is excluded" }
    return "Every running app already has a shortcut"
  }

  private func chooseAppForShortcut() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Choose"
    panel.message = "Pick an app to give a keyboard shortcut."
    guard panel.runModal() == .OK,
      let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else { return }
    guard !takenAppIDs.contains(bundleID) else { return }
    draft.addPendingApp(bundleID)
  }

  private func appName(_ appID: String) -> String {
    FriendlyAppName.resolve(appID, in: store.session.apps)
  }

  /// One app's three shortcuts, grouped under its name.
  ///
  /// Mute first because it is what people come for, but volume belongs here too:
  /// the release's whole premise is that the app you want a shortcut for is
  /// rarely the one in front, and leaving per-app volume out would have left
  /// exactly that gap open.
  @ViewBuilder
  private func appShortcutRow(_ appID: String) -> some View {
    let name = appName(appID)
    // The ✕ on the mute row removes the whole app group, so a row added by
    // mistake can be taken back before any chord is recorded into it.
    shortcutRow(
      name,
      action: .muteApp(appID),
      canRemoveWhenUnset: true,
      clearRemovesAppGroup: appID
    )
    shortcutRow("\(name) volume up", action: .volumeUpApp(appID))
    shortcutRow("\(name) volume down", action: .volumeDownApp(appID))
  }

  private func shortcutRow(
    _ title: String,
    action: HotkeyAction,
    canRemoveWhenUnset: Bool = false,
    clearRemovesAppGroup appID: String? = nil
  ) -> some View {
    let binding = store.preferences.hotkeys.bindings.first { $0.action == action }
    let handlers = Self.shortcutRowHandlers(
      action: action,
      binding: binding,
      clearRemovesAppGroup: appID,
      store: store,
      draft: draft
    )
    return LabeledContent(title) {
      ShortcutRecorder(
        action: action,
        draft: draft,
        binding: binding,
        canRemoveWhenUnset: canRemoveWhenUnset,
        isUnavailable: binding.map(store.isHotkeyRejected) ?? false,
        onRecord: handlers.onRecord,
        onClear: handlers.onClear
      )
    }
  }

  /// The record and clear handlers for one shortcut row.
  ///
  /// The two do different things to an app's group. Recording releases only the
  /// pending placeholder, because the new binding is now what keeps the group
  /// listed. Clearing the mute row removes the whole group. They are built in
  /// one place so a test can drive the same closures the row uses: when a single
  /// callback served both, recording a mute shortcut deleted it, along with the
  /// app's volume shortcuts.
  static func shortcutRowHandlers(
    action: HotkeyAction,
    binding: HotkeyBinding?,
    clearRemovesAppGroup appID: String?,
    store: AppStore,
    draft: ControlSettingsDraft
  ) -> (onRecord: (HotkeyChord) -> String?, onClear: () -> Void) {
    (
      onRecord: { chord in
        switch store.assignHotkey(chord, to: action, replacing: binding?.id) {
        case .success:
          if let appID { draft.removePendingApp(appID) }
          return nil
        case .failure(let error):
          return store.hotkeyMessage(for: error)
        }
      },
      onClear: {
        if let binding { store.removeHotkey(id: binding.id) }
        guard let appID else { return }
        draft.removePendingApp(appID)
        for binding in store.preferences.hotkeys.bindings where binding.action.appID == appID {
          store.removeHotkey(id: binding.id)
        }
      }
    )
  }
}
