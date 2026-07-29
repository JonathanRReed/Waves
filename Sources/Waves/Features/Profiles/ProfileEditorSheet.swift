import AppKit
import SwiftUI
import WavesAudioCore

/// Identifies an editor session: a new profile (`profile == nil`) or an edit of
/// an existing one. `preselectedAppIDs` seeds the initial app selection.
struct ProfileEditorContext: Identifiable {
  let id = UUID()
  let profile: Profile?
  let preselectedAppIDs: [String]
}

/// Create or edit a profile: name it, choose which apps belong, and decide
/// whether to capture the current volume/mute/boost levels or keep it a pure
/// grouping.
struct ProfileEditorSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorSchemeContrast) private var contrast

  let context: ProfileEditorContext

  static let maxNameLength = 100

  @State private var name: String
  @State private var selectedIDs: Set<String>
  /// The offline roster, snapshotted once when the sheet opens.
  ///
  /// Deriving it from `selectedIDs` instead made every offline row impossible to
  /// untick and then re-tick: unticking removed the id from the selection, which
  /// removed the row from the derived list, which erased it from the sheet with
  /// no way back short of cancelling — and Save then wrote the membership out
  /// without it.
  @State private var offlineMemberIDs: [String]
  @State private var didResolveOfflineMembers = false
  @State private var captureLevels: Bool

  init(context: ProfileEditorContext) {
    self.context = context
    _name = State(initialValue: context.profile?.name ?? "")
    _selectedIDs = State(initialValue: Set(context.preselectedAppIDs))
    _offlineMemberIDs = State(initialValue: [])
    // Default off so editing membership never clobbers a saved mix — an existing
    // profile keeps its stored levels unless the user explicitly re-captures.
    // Capturing is the deliberate opt-in to bake in the *current* mix.
    _captureLevels = State(initialValue: false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          nameField
          captureToggle
          appPicker
        }
        .padding(20)
      }

      Divider()

      footer
    }
    .frame(width: 460, height: 560)
    .background(WavesBackground())
    .onAppear { resolveOfflineMembersIfNeeded() }
    // A member's app can quit while the sheet is open. The roster only ever
    // grows, so unticking stays reversible (the reason it is snapshotted at
    // all) while an app that goes offline mid-edit keeps its row instead of
    // vanishing from the sheet and being dropped by Save.
    .onChange(of: store.visibleApps.map(\.logicalID)) { _, ids in
      absorbNewlyOfflineMembers(visibleIDs: Set(ids))
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "rectangle.stack.badge.plus")
        .font(.title2)
        .foregroundStyle(theme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.profile == nil ? "New Profile" : "Edit Profile")
          .font(.title3.weight(.semibold))
        Text("Group apps you use together. Optionally capture their current mix.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  private var nameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Name")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      // A tonal field that matches the app-picker card below, instead of the
      // light AppKit rounded-border bezel that fights the near-black palette.
      TextField("e.g. Work, Gaming, Focus", text: $name)
        .textFieldStyle(.plain)
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(theme.hairline(increasedContrast: contrast == .increased))
        )
      if isTooLong {
        Text("Name too long (max \(Self.maxNameLength) characters)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var captureToggle: some View {
    Toggle(isOn: $captureLevels) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Capture current levels")
          .font(.callout.weight(.medium))
        Text(captureDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.switch)
  }

  private var captureDescription: String {
    if captureLevels {
      return "Saves each app's current volume, mute, and boost so applying this profile restores the mix."
    }
    if context.profile?.carriesLevels == true {
      return "Keeps this profile's saved levels. New apps are added as members only."
    }
    return "Membership only. This profile just groups the apps and won't change their audio."
  }

  private var appPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Apps")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(savableSelectedIDs.count) selected")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if runningApps.isEmpty && offlineMembers.isEmpty {
        Text("No apps available. Launch the apps you want to group, then reopen this editor.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 12)
      } else {
        VStack(spacing: 0) {
          ForEach(runningApps) { app in
            AppCheckRow(
              title: app.displayName,
              subtitle: app.category == .unknown ? nil : app.category.displayName,
              iconApp: app,
              isOn: selectedIDs.contains(app.logicalID),
              isExcluded: excludedIDs.contains(app.logicalID)
            ) { toggle(app.logicalID) }
            if app.id != runningApps.last?.id || !offlineMembers.isEmpty {
              Divider().padding(.leading, 44)
            }
          }

          if !offlineMembers.isEmpty {
            ForEach(offlineMembers, id: \.self) { id in
              AppCheckRow(
                title: friendlyName(for: id),
                subtitle: subtitle(for: id),
                iconApp: nil,
                isOn: selectedIDs.contains(id),
                isExcluded: excludedIDs.contains(id)
              ) { toggle(id) }
              if id != offlineMembers.last {
                Divider().padding(.leading, 44)
              }
            }
          }
        }
        .wavesCard(cornerRadius: 12)
      }
    }
  }

  private var footer: some View {
    HStack {
      if context.profile != nil {
        Text("Saved profiles live in the sidebar and the menu bar.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") { save() }
        .keyboardShortcut(.defaultAction)
        .wavesGlassProminentButton()
        .disabled(!canSave)
        .help(saveDisabledReason)
    }
    .padding(20)
  }

  /// Tells the user why Save is disabled instead of leaving a silent dead button.
  private var saveDisabledReason: String {
    if canSave { return "Save profile" }
    if trimmedName.isEmpty { return "Enter a profile name" }
    if isTooLong { return "Name too long (max \(Self.maxNameLength) characters)" }
    if !selectedIDs.isEmpty { return "Every selected app is excluded from Waves" }
    return "Select at least one app"
  }

  // MARK: - Data

  /// Currently visible apps in a stable alphabetical order. Order intentionally
  /// does NOT depend on selection, so ticking a checkbox never makes rows jump
  /// under the cursor; the checkmark alone conveys membership.
  private var runningApps: [AudioApp] {
    store.visibleApps.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  /// The profile's existing members that aren't in the visible list, shown so
  /// editing a profile never silently drops an app just because it's closed (or
  /// hidden by the "show system processes" preference) right now. Listed
  /// regardless of whether they are currently ticked, so unticking one is
  /// reversible.
  private var offlineMembers: [String] { offlineMemberIDs }

  /// The roster is fixed for the life of the sheet: which members are offline
  /// depends on what is running, not on what is currently ticked.
  /// Adds any still-selected member that has just left the visible list.
  /// Additive only — nothing is ever removed, so a row the user unticked stays
  /// on screen and can be re-ticked.
  private func absorbNewlyOfflineMembers(visibleIDs: Set<String>) {
    guard didResolveOfflineMembers else { return }
    let known = Set(offlineMemberIDs)
    let newlyOffline = selectedIDs.subtracting(visibleIDs).subtracting(known)
    guard !newlyOffline.isEmpty else { return }
    offlineMemberIDs = (offlineMemberIDs + newlyOffline).sorted()
  }

  private func resolveOfflineMembersIfNeeded() {
    guard !didResolveOfflineMembers else { return }
    didResolveOfflineMembers = true
    let visibleIDs = Set(store.visibleApps.map(\.logicalID))
    offlineMemberIDs = Set(context.preselectedAppIDs).subtracting(visibleIDs).sorted()
  }

  /// Subtitle for a member not in the visible list: distinguish a genuinely
  /// closed app from one that's running but hidden by a preference, instead of
  /// labeling every such row "Not running".
  private func subtitle(for id: String) -> String {
    store.session.apps.contains { $0.logicalID == id } ? "Running (hidden)" : "Not running"
  }

  /// Apps the user has told Waves to leave alone. Saving strips these from the
  /// profile (AppStore.saveProfile), so the sheet must count, tag, and gate on
  /// the same rule — otherwise "3 selected" could save a 2-member profile.
  private var excludedIDs: Set<String> {
    Set(store.preferences.excludedAppIDs)
  }

  /// The selection Save will actually write: selected members minus excluded.
  private var savableSelectedIDs: Set<String> {
    selectedIDs.subtracting(excludedIDs)
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isTooLong: Bool { trimmedName.count > Self.maxNameLength }

  private var canSave: Bool {
    !trimmedName.isEmpty && !isTooLong && !savableSelectedIDs.isEmpty
  }

  private func toggle(_ id: String) {
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
  }

  private func friendlyName(for id: String) -> String {
    // Prefer a remembered display name from the session (the app has run at
    // some point this session, so Waves already knows its real name).
    if let app = store.session.apps.first(where: { $0.logicalID == id }) {
      return app.displayName
    }
    // Otherwise ask Launch Services for the real name of the installed app —
    // this is the case for the seeded default profiles' members before their
    // first launch (e.g. "Focus" includes "us.zoom.xos" and
    // "com.spotify.client"). Far more reliable than guessing from the bundle
    // ID's shape: the naive "last dot-component, capitalized" fallback below
    // turns those into "XOS" and "Client" — wrong on the very first profile a
    // new user sees. Cached (FriendlyNameCache) because this view's body
    // re-evaluates on every keystroke in the name field, and an uncached
    // lookup would re-hit Launch Services for every offline member on every
    // keystroke.
    if let cached = FriendlyNameCache.name(forBundleID: id) {
      return cached
    }
    // Last resort, for an app that isn't installed at all: the last
    // dot-component of the bundle id (e.g. "com.tinyspeck.slackmacgap" →
    // "slackmacgap") — imperfect, but better than showing the raw bundle id.
    return id.split(separator: ".").last.map(String.init) ?? id
  }

  private func save() {
    guard canSave else { return }
    // Keep the editor's display order: running (selected-first) then offline.
    // Offline members are filtered by the selection the same way running ones
    // are, so unticking one actually removes it — and leaving it ticked keeps it.
    let orderedIDs = runningApps.map(\.logicalID).filter { selectedIDs.contains($0) }
      + offlineMemberIDs.filter { selectedIDs.contains($0) }
    store.saveProfile(
      id: context.profile?.id,
      named: trimmedName,
      appIDs: orderedIDs,
      captureLevels: captureLevels
    )
    dismiss()
  }
}

/// Caches Launch Services name lookups so `friendlyName(for:)` doesn't re-hit
/// `NSWorkspace`/`Bundle` on every SwiftUI body re-evaluation — which happens
/// on every keystroke in the profile name field, since `name` and `appPicker`
/// live in the same view body. Mirrors `AppIconCache` in MixerRowView.swift.
@MainActor
private enum FriendlyNameCache {
  /// Match `AudioApp`'s bound for display metadata before caching or rendering
  /// names supplied by an installed app's Info.plist.
  private static let maxNameLength = 256

  /// The value is itself optional so a miss (uninstalled bundle id, or a bundle
  /// with no usable name) is cached as `nil` too — otherwise every keystroke in
  /// the name field would re-hit Launch Services for each unresolvable member.
  private static var storage: [String: String?] = [:]

  static func name(forBundleID id: String) -> String? {
    if let cached = storage[id] {
      return cached
    }

    let resolved = lookup(id)
    storage[id] = resolved
    return resolved
  }

  private static func lookup(_ id: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
          let bundle = Bundle(url: url)
    else { return nil }

    return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      .flatMap { $0.isEmpty ? nil : String($0.prefix(maxNameLength)) }
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      .flatMap { $0.isEmpty ? nil : String($0.prefix(maxNameLength)) }
  }
}

private struct AppCheckRow: View {
  @Environment(\.wavesTheme) private var theme
  let title: String
  let subtitle: String?
  let iconApp: AudioApp?
  let isOn: Bool
  /// Excluded apps are stripped by AppStore.saveProfile no matter what's ticked
  /// here, so the row carries the same quiet "Excluded" tag as the mixer row —
  /// the checkbox alone would promise a membership Save won't keep.
  var isExcluded: Bool = false
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 10) {
        if let iconApp {
          AppIconView(app: iconApp)
            .frame(width: 24, height: 24)
        } else {
          Image(systemName: "app.dashed")
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
        }

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(title)
              .lineLimit(1)
            if isExcluded {
              Text("Excluded")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.secondary.opacity(0.15), in: Capsule())
            }
          }
          if let subtitle {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(theme.accentOrTertiary(isOn))
          .font(.title3)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isExcluded ? "\(title), excluded from Waves" : title)
    .accessibilityValue(isOn ? "Selected" : "Not selected")
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint("Toggles membership in this profile.")
  }
}
