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
  @Environment(\.dismiss) private var dismiss

  let context: ProfileEditorContext

  static let maxNameLength = 100

  @State private var name: String
  @State private var selectedIDs: Set<String>
  @State private var captureLevels: Bool

  init(context: ProfileEditorContext) {
    self.context = context
    _name = State(initialValue: context.profile?.name ?? "")
    _selectedIDs = State(initialValue: Set(context.preselectedAppIDs))
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
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "rectangle.stack.badge.plus")
        .font(.title2)
        .foregroundStyle(WavesDesign.accent)
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
      TextField("e.g. Work, Gaming, Focus", text: $name)
        .textFieldStyle(.roundedBorder)
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
    return "Membership only — this profile just groups the apps and won't change their audio."
  }

  private var appPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Apps")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(selectedIDs.count) selected")
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
              isOn: selectedIDs.contains(app.logicalID)
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
                isOn: selectedIDs.contains(id)
              ) { toggle(id) }
              if id != offlineMembers.last {
                Divider().padding(.leading, 44)
              }
            }
          }
        }
        .wavesGlass(cornerRadius: 12)
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
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
    }
    .padding(20)
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

  /// Selected members not shown in the visible list, kept visible so editing a
  /// profile never silently drops an app just because it's closed (or hidden by
  /// the "show system processes" preference) right now.
  private var offlineMembers: [String] {
    let visibleIDs = Set(store.visibleApps.map(\.logicalID))
    return selectedIDs.subtracting(visibleIDs).sorted()
  }

  /// Subtitle for a member not in the visible list: distinguish a genuinely
  /// closed app from one that's running but hidden by a preference, instead of
  /// labeling every such row "Not running".
  private func subtitle(for id: String) -> String {
    store.session.apps.contains { $0.logicalID == id } ? "Running (hidden)" : "Not running"
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isTooLong: Bool { trimmedName.count > Self.maxNameLength }

  private var canSave: Bool {
    !trimmedName.isEmpty && !isTooLong && !selectedIDs.isEmpty
  }

  private func toggle(_ id: String) {
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
  }

  private func friendlyName(for id: String) -> String {
    // Prefer a remembered display name from the session; fall back to the last
    // dot-component of a bundle id (e.g. "com.tinyspeck.slackmacgap" → "slackmacgap").
    if let app = store.session.apps.first(where: { $0.logicalID == id }) {
      return app.displayName
    }
    return id.split(separator: ".").last.map(String.init) ?? id
  }

  private func save() {
    guard canSave else { return }
    // Keep the editor's display order: running (selected-first) then offline.
    let orderedIDs = runningApps.map(\.logicalID).filter { selectedIDs.contains($0) } + offlineMembers
    store.saveProfile(
      id: context.profile?.id,
      named: trimmedName,
      appIDs: orderedIDs,
      captureLevels: captureLevels
    )
    dismiss()
  }
}

private struct AppCheckRow: View {
  let title: String
  let subtitle: String?
  let iconApp: AudioApp?
  let isOn: Bool
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
          Text(title)
            .lineLimit(1)
          if let subtitle {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isOn ? AnyShapeStyle(WavesDesign.accent) : AnyShapeStyle(.tertiary))
          .font(.title3)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(isOn ? "Selected" : "Not selected")
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint("Toggles membership in this profile.")
  }
}
