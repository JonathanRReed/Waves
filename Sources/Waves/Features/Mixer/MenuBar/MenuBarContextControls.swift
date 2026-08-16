import SwiftUI

struct MenuBarContextControls: View {
  var body: some View {
    HStack(spacing: 8) {
      OutputDevicePicker()
      ProfileQuickPicker()
    }
  }
}

private struct OutputDevicePicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.availableDevices) { device in
        Button {
          store.selectOutputDevice(device)
        } label: {
          if device.id == store.currentDeviceID {
            Label(device.name, systemImage: "checkmark")
          } else {
            Text(device.name)
          }
        }
      }
      if store.availableDevices.isEmpty {
        Text("No output devices found")
          .foregroundStyle(.secondary)
      }
    } label: {
      compactPickerLabel(
        title: store.currentDeviceName,
        systemImage: "hifispeaker.fill"
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(maxWidth: .infinity)
    .wavesCard(cornerRadius: 10)
    .accessibilityLabel("Output device")
    .accessibilityValue(store.currentDeviceName)
    .help("Switch the system output device")
    .onAppear { store.refreshOutputDevices() }
  }
}

private struct ProfileQuickPicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.profiles) { profile in
        Button {
          store.applyProfile(profile)
        } label: {
          if profile.id == store.activeProfileID {
            Label(profile.name, systemImage: "checkmark")
          } else {
            Text(profile.name)
          }
        }
      }
      if store.profiles.isEmpty {
        Text("No profiles yet")
          .foregroundStyle(.secondary)
      }
      if let restorePoint = store.mixRestorePoint {
        Divider()
        Button {
          store.resetMix()
        } label: {
          Label("Reset Mix", systemImage: "arrow.uturn.backward.circle")
        }
        .help("Put every app back to how it was before \(restorePoint.profileName).")
      }
    } label: {
      compactPickerLabel(
        title: activeProfileName,
        systemImage: "rectangle.stack"
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .frame(maxWidth: .infinity)
    .wavesCard(cornerRadius: 10)
    .accessibilityLabel("Profile")
    .accessibilityValue(activeProfileName)
    .help("Switch profile")
  }

  private var activeProfileName: String {
    guard let id = store.activeProfileID,
      let profile = store.profiles.first(where: { $0.id == id })
    else {
      return "Profiles"
    }
    return profile.name
  }
}

private func compactPickerLabel(
  title: String,
  systemImage: String
) -> some View {
  HStack(spacing: 6) {
    Image(systemName: systemImage)
      .foregroundStyle(.secondary)
    Text(title)
      .lineLimit(1)
      .truncationMode(.middle)
    Spacer(minLength: 2)
    Image(systemName: "chevron.down")
      .font(.caption2)
      .foregroundStyle(.tertiary)
  }
  .font(.caption)
  .padding(.horizontal, 8)
  .padding(.vertical, 6)
  .frame(maxWidth: .infinity, minHeight: 28)
  .contentShape(Rectangle())
}
