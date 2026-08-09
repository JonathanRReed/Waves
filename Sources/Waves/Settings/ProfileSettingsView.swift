import SwiftUI
import WavesAudioCore

struct ProfileSettingsView: View {
  @Environment(AppStore.self) private var store
  // Presenting the same ProfileEditorSheet MainWindowView's sidebar "+"/"Edit
  // Profile…" use. This pane used to only hint at using that sidebar instead
  // of offering the action itself.
  @State private var editorContext: ProfileEditorContext?

  var body: some View {
    SettingsForm {
      Section {
        Picker(
          "Apply at startup",
          selection: Binding(
            get: { store.preferences.defaultProfileID },
            set: { id in
              store.setDefaultProfile(id.flatMap { id in store.profiles.first { $0.id == id } })
            }
          )
        ) {
          Text("None").tag(UUID?.none)
          ForEach(store.profiles.filter(\.carriesLevels)) { profile in
            Text(profile.name).tag(UUID?.some(profile.id))
          }
        }
        .disabled(!store.profiles.contains(where: \.carriesLevels))
      } header: {
        Text("Startup")
      } footer: {
        Text(
          store.profiles.contains(where: \.carriesLevels)
            ? "Waves applies this profile's saved levels every time it starts, so your baseline mix is always in place."
            : "Save a profile with captured levels first, then pick it here to have Waves apply it at startup."
        )
      }

      Section {
        if store.profiles.isEmpty {
          Text("No profiles yet. Create one here, or import one.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.profiles) { profile in
            ProfileRow(profile: profile, onEdit: { presentEditProfile(profile) })
          }
        }
      } header: {
        HStack {
          Text("Profiles")
          Spacer()
          Button {
            presentNewProfile()
          } label: {
            Label("New Profile", systemImage: "plus")
          }
          .buttonStyle(.borderless)
          .textCase(nil)

          Button {
            store.importProfiles()
          } label: {
            Label("Import", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(.borderless)
          .textCase(nil)
        }
      } footer: {
        Text(
          "A profile is a group of apps, optionally with saved levels. Apply one before a meeting or a game, then use Reset Mix in the main window to put everything back."
        )
      }
    }
    .sheet(item: $editorContext) { context in
      ProfileEditorSheet(context: context)
        .environment(store)
    }
  }

  private func presentNewProfile() {
    // Mirrors MainWindowView.presentNewProfile: seed with whatever is
    // currently playing, the most common starting set.
    editorContext = ProfileEditorContext(
      profile: nil, preselectedAppIDs: store.liveApps.map(\.logicalID))
  }

  private func presentEditProfile(_ profile: Profile) {
    editorContext = ProfileEditorContext(profile: profile, preselectedAppIDs: profile.appIDs)
  }
}

private struct ProfileRow: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  let profile: Profile
  let onEdit: () -> Void
  // Deleting a profile discards a hand-tuned captured mix with no undo, so the
  // one-click borderless button (right beside Export) asks first.
  @State private var confirmingDelete = false

  var body: some View {
    HStack(spacing: 10) {
      Image(
        systemName: profile.carriesLevels
          ? "slider.horizontal.below.square.filled.and.square" : "square.grid.2x2"
      )
      .foregroundStyle(theme.accent)
      .frame(width: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Edit…") { onEdit() }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Edit profile \(profile.name)")

      Button("Export") { store.exportProfile(profile) }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Export profile \(profile.name)")

      Button("Delete…", role: .destructive) {
        confirmingDelete = true
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .accessibilityLabel("Delete profile \(profile.name)")
      .confirmationDialog(
        "Delete “\(profile.name)”?",
        isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button("Delete Profile", role: .destructive) {
          if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.deleteProfiles(at: IndexSet(integer: index))
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This removes \(profile.name)\(profile.carriesLevels ? " and its saved levels" : "") from your profiles. This can't be undone."
        )
      }
    }
  }

  private var detail: String {
    let count = profile.entries.count
    let noun = count == 1 ? "app" : "apps"
    var text = profile.carriesLevels ? "\(count) \(noun) · saved levels" : "\(count) \(noun) · group"
    if store.preferences.defaultProfileID == profile.id {
      text += " · applied at startup"
    }
    return text
  }
}
