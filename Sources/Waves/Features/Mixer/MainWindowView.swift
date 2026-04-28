import SwiftUI
import WavesAudioCore

struct MainWindowView: View {
  @Environment(AppStore.self) private var store
  @State private var searchText = ""
  @State private var selection: SourceFilter = .running
  @State private var isPresentingSavePreset = false
  @State private var presetName = ""

  var body: some View {
    ZStack(alignment: .top) {
      WavesDesign.windowGradient
        .ignoresSafeArea()

      NavigationSplitView {
        SidebarView(selection: $selection)
          .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
      } detail: {
        SourceListView(
          filter: selection,
          apps: filteredApps,
          searchText: searchText
        )
      }
      .navigationSplitViewStyle(.balanced)
      .searchable(text: $searchText, placement: .sidebar, prompt: "Filter apps")
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack(spacing: 10) {
            WavesBrandLogo(size: 18)
            Text("Waves")
              .font(.headline)
          }
        }

        ToolbarItemGroup {
          Button {
            isPresentingSavePreset = true
          } label: {
            Image(systemName: "plus")
          }
          .help("Save preset")

          Button {
            store.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("Refresh app list")

          Button {
            store.recoverRoutes()
          } label: {
            Image(systemName: "waveform.path")
          }
          .help("Recover managed routes")
        }
      }

      AppToastStack()
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topTrailing)

      if store.isLoading {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Refreshing audio sessions")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(WavesDesign.accent.opacity(0.22))
        )
        .padding(.top, 12)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .sheet(isPresented: $isPresentingSavePreset) {
      SavePresetSheet(
        presetName: $presetName,
        onCancel: dismissPresetSheet,
        onSave: savePreset
      )
    }
    .task {
      store.start()
    }
  }

  private var scopedApps: [AudioApp] {
    switch selection {
    case .running:
      store.visibleApps
    case .pinned:
      store.pinnedApps
    case .frontmost:
      store.activeApps
    case .recent:
      store.recentApps
    }
  }

  private var filteredApps: [AudioApp] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return scopedApps }

    return scopedApps.filter { app in
      app.displayName.localizedCaseInsensitiveContains(query)
        || app.category.displayName.localizedCaseInsensitiveContains(query)
    }
  }

  private func dismissPresetSheet() {
    presetName = ""
    isPresentingSavePreset = false
  }

  private func savePreset() {
    let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.savePreset(named: trimmed)
    dismissPresetSheet()
  }
}

private enum SourceFilter: String, CaseIterable, Identifiable {
  case running
  case pinned
  case frontmost
  case recent

  var id: Self { self }

  var title: String {
    switch self {
    case .running:
      "Running"
    case .pinned:
      "Pinned"
    case .frontmost:
      "Frontmost"
    case .recent:
      "Recent"
    }
  }

  @MainActor
  func count(in store: AppStore) -> Int {
    switch self {
    case .running:
      store.visibleApps.count
    case .pinned:
      store.pinnedApps.count
    case .frontmost:
      store.activeApps.count
    case .recent:
      store.recentApps.count
    }
  }

  func detail(count: Int) -> String {
    let label: String
    switch self {
    case .running:
      label = count == 1 ? "running app" : "running apps"
    case .pinned:
      label = count == 1 ? "pinned app" : "pinned apps"
    case .frontmost:
      label = count == 1 ? "frontmost app" : "frontmost apps"
    case .recent:
      label = count == 1 ? "background app" : "background apps"
    }

    return "\(count) \(label)"
  }

  var emptyTitle: String {
    switch self {
    case .running:
      "No Running Apps"
    case .pinned:
      "No Pinned Apps"
    case .frontmost:
      "No Frontmost App"
    case .recent:
      "No Recent Apps"
    }
  }

  func emptyMessage(searchText: String) -> String {
    if !searchText.isEmpty {
      return "Try a different search term."
    }

    switch self {
    case .running:
      return "Waves has not found any user-facing running apps."
    case .pinned:
      return "Pin apps from the source list to keep them here."
    case .frontmost:
      return "This filter only shows the current frontmost app, not confirmed audio output."
    case .recent:
      return "Background apps will appear here when they are not frontmost."
    }
  }
}

private struct SidebarView: View {
  @Environment(AppStore.self) private var store
  @Binding var selection: SourceFilter

  var body: some View {
    List(selection: $selection) {
      Section("Sources") {
        ForEach(SourceFilter.allCases) { filter in
          SourceFilterRow(
            filter: filter,
            countText: filter.detail(count: filter.count(in: store))
          )
          .tag(filter)
        }
      }

      if !store.presets.isEmpty {
        Section("Presets") {
          ForEach(store.presets) { preset in
            Button {
              store.applyPreset(preset)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                  .lineLimit(1)
                Text("\(preset.entries.count) apps")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Delete Preset", role: .destructive) {
                if let index = store.presets.firstIndex(where: { $0.id == preset.id }) {
                  store.deletePresets(at: IndexSet(integer: index))
                }
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Waves")
  }
}

private struct SourceFilterRow: View {
  let filter: SourceFilter
  let countText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(filter.title)
        .lineLimit(1)
      Text(countText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

private struct SourceListView: View {
  let filter: SourceFilter
  let apps: [AudioApp]
  let searchText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      OutputSummaryView(filter: filter, visibleCount: apps.count)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)

      if apps.isEmpty {
        ContentUnavailableView(
          filter.emptyTitle,
          systemImage: "speaker.slash",
          description: Text(filter.emptyMessage(searchText: searchText))
        )
        Spacer(minLength: 0)
      } else {
        List {
          ForEach(apps) { app in
            MixerRowView(app: app)
              .listRowInsets(EdgeInsets(top: 7, leading: 24, bottom: 7, trailing: 24))
          }
        }
        .listStyle(.inset)
      }

      DiagnosticsPanel()
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
  }
}

private struct OutputSummaryView: View {
  @Environment(AppStore.self) private var store
  let filter: SourceFilter
  let visibleCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(store.currentDeviceName)
          .font(.title2.weight(.semibold))

        if store.isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }
      Text(filter.detail(count: visibleCount))
        .foregroundStyle(.secondary)
      Text("Showing user-facing running apps and their managed route state.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct DiagnosticsPanel: View {
  @Environment(AppStore.self) private var store
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()

      DisclosureGroup(isExpanded: $expanded) {
        if let diagnostics = store.diagnostics {
          VStack(alignment: .leading, spacing: 10) {
            Text(diagnostics.summary)
              .font(.caption)
              .foregroundStyle(.secondary)

            ForEach(diagnostics.checks) { check in
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                  Circle()
                    .fill(color(for: check.status))
                    .frame(width: 7, height: 7)
                  Text(check.title)
                }

                Text(check.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.leading, 15)
              }
            }
          }
          .padding(.top, 10)
        }
      } label: {
        Text("Diagnostics")
          .font(.headline)
      }
    }
  }

  private func color(for status: DiagnosticsStatus) -> Color {
    switch status {
    case .passed:
      .green
    case .warning:
      .orange
    case .failed:
      .red
    case .informational:
      .secondary
    }
  }
}

private struct SavePresetSheet: View {
  @Binding var presetName: String
  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Save Preset")
        .font(.title3.weight(.semibold))

      TextField("Preset name", text: $presetName)
        .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()

        Button("Cancel", action: onCancel)

        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
          .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 320)
  }
}
