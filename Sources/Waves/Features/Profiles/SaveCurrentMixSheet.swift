import SwiftUI
import WavesAudioCore

/// One step from "this sounds right" to a saved profile: name it, choose
/// whether it also restores EQ and outputs, save. The apps and their levels
/// come from the current mix (`AppStore.currentMixAppIDs`).
struct SaveCurrentMixSheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  // EQ is part of what you hear, so it is saved by default. Outputs are not:
  // they depend on what is plugged in, and restoring one can move a call to
  // the wrong device.
  @State private var includeEqualizer = true
  @State private var includeOutput = false
  @State private var validationResult: ProfileSaveResult?

  static let title = "Save Current Mix"

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      VStack(alignment: .leading, spacing: 18) {
        ProfileNameField(name: $name, validationResult: nameValidationResult)
          .onChange(of: name) { _, _ in validationResult = nil }
        mixSummary
        ProfileSoundCaptureOptions(
          includeEqualizer: $includeEqualizer,
          includeOutput: $includeOutput
        )
      }
      .padding(20)

      Spacer(minLength: 0)

      Divider()

      footer
    }
    .frame(width: 420, height: 440)
    .background(WavesBackground())
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "square.and.arrow.down.on.square")
        .font(.title2)
        .foregroundStyle(theme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.title)
          .font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Text("Save what you hear now as a profile you can apply later.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  private var mixSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Apps")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Group {
        if mixAppNames.isEmpty {
          Text(ProfileSaveResult.noMixToSave.message ?? "")
            .foregroundStyle(validationResult == .noMixToSave ? WavesDesign.error : .secondary)
        } else {
          Text(
            "Saves the volume, mute, and boost of \(AppStore.listPhrase(mixAppNames))."
          )
        }
      }
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .wavesCard(cornerRadius: 12)
      .accessibilityElement(children: .combine)
    }
  }

  private var footer: some View {
    HStack {
      Text("You can change its apps later with Edit Profile.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") { save() }
        .keyboardShortcut(.defaultAction)
        .wavesGlassProminentButton()
        .help(mixAppNames.isEmpty ? "There is no mix to save yet" : "Save profile")
    }
    .padding(20)
  }

  private var mixAppNames: [String] {
    let ids = Set(store.currentMixAppIDs)
    return store.visibleApps.filter { ids.contains($0.logicalID) }.map(\.displayName)
  }

  private var nameValidationResult: ProfileSaveResult? {
    switch validationResult {
    case .blankName, .nameTooLong, .duplicateName:
      return validationResult
    default:
      return nil
    }
  }

  private func save() {
    let result = store.saveCurrentMix(
      named: name,
      includeEqualizer: includeEqualizer,
      includeOutput: includeOutput
    )
    validationResult = result
    switch result {
    case .saved:
      dismiss()
    default:
      if let message = result.message {
        store.postAccessibilityAnnouncement(message)
      }
    }
  }
}
