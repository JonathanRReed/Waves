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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
  @State private var validationResult: ProfileSaveResult?

  init(context: ProfileEditorContext) {
    self.context = context
    _name = State(initialValue: context.profile?.name ?? "")
    _selectedIDs = State(initialValue: Set(context.preselectedAppIDs))
    _offlineMemberIDs = State(initialValue: [])
    // Default off so editing membership never clobbers a saved mix — an existing
    // profile keeps its stored levels unless the user explicitly re-captures.
    // Capturing is the deliberate opt-in to bake in the *current* mix.
    _captureLevels = State(initialValue: false)
    _validationResult = State(initialValue: nil)
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
        .background(
          theme.fieldFill(
            reduceTransparency: reduceTransparency,
            increasedContrast: contrast == .increased
          ),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(nameFieldStroke)
        )
        .accessibilityLabel("Profile name")
        .accessibilityValue(name)
        .accessibilityHint(nameValidationMessage ?? "Enter a unique profile name.")
        .onChange(of: name) { _, _ in clearNameValidation() }
      if let nameValidationMessage {
        Text(nameValidationMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityLabel("Profile name error: \(nameValidationMessage)")
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

      if case .noEligibleApps = validationResult {
        Text(ProfileSaveResult.noEligibleApps.message ?? "Select an eligible app.")
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityLabel(
            "App selection error: \(ProfileSaveResult.noEligibleApps.message ?? "Select an eligible app.")"
          )
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
        .help(saveHelp)
    }
    .padding(20)
  }

  private var saveHelp: String {
    if let message = validationResult?.message { return message }
    if trimmedName.isEmpty { return "Enter a profile name" }
    if isTooLong { return "Name too long (max \(Self.maxNameLength) characters)" }
    if !selectedIDs.isEmpty { return "Every selected app is excluded from Waves" }
    if selectedIDs.isEmpty { return "Select at least one app" }
    return "Save profile"
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

  private func toggle(_ id: String) {
    if case .noEligibleApps = validationResult { validationResult = nil }
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
  }

  /// Names a member that may not be running — the seeded default profiles
  /// include apps ("us.zoom.xos", "com.spotify.client") that a new user has not
  /// launched yet, and the raw bundle ID on the very first profile they open
  /// would look broken.
  private func friendlyName(for id: String) -> String {
    FriendlyAppName.resolve(id, in: store.session.apps)
  }

  private func save() {
    // Keep the editor's display order: running (selected-first) then offline.
    // Offline members are filtered by the selection the same way running ones
    // are, so unticking one actually removes it — and leaving it ticked keeps it.
    let orderedIDs =
      runningApps.map(\.logicalID).filter { selectedIDs.contains($0) }
      + offlineMemberIDs.filter { selectedIDs.contains($0) }
    let result = store.saveProfile(
      id: context.profile?.id,
      named: trimmedName,
      appIDs: orderedIDs,
      captureLevels: captureLevels
    )
    validationResult = result
    switch result {
    case .saved:
      dismiss()
    default:
      if let message = result.message {
        AccessibilityNotification.Announcement(message).post()
      }
    }
  }

  private var nameValidationMessage: String? {
    if isTooLong {
      return ProfileSaveResult.nameTooLong(maximum: Self.maxNameLength).message
    }
    switch validationResult {
    case .blankName, .nameTooLong, .duplicateName:
      return validationResult?.message
    default:
      return nil
    }
  }

  private var nameFieldStroke: Color {
    nameValidationMessage == nil
      ? theme.hairline(increasedContrast: contrast == .increased)
      : WavesDesign.error
  }

  private func clearNameValidation() {
    switch validationResult {
    case .blankName, .nameTooLong, .duplicateName:
      validationResult = nil
    default:
      break
    }
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
