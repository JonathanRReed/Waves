import SwiftUI
import WavesAudioCore

extension Profile {
  /// What applying this profile restores, as a short phrase for lists:
  /// "levels", "levels and EQ", "levels, EQ, and outputs". Nil for a pure
  /// grouping, which restores nothing.
  var savedContentsPhrase: String? {
    var parts: [String] = []
    if entries.contains(where: \.setsVolumeLevels) { parts.append("levels") }
    if carriesEqualizer { parts.append("EQ") }
    if carriesOutput { parts.append("outputs") }
    guard !parts.isEmpty else { return nil }
    return AppStore.listPhrase(parts)
  }
}

/// The two opt-in choices for a captured mix: whether applying the profile
/// later also restores each app's EQ and its output device.
struct ProfileSoundCaptureOptions: View {
  @Binding var includeEqualizer: Bool
  @Binding var includeOutput: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      option(
        "Include EQ",
        detail: "Applying the profile also sets each app's EQ.",
        isOn: $includeEqualizer
      )
      option(
        "Include output devices",
        detail: "Applying the profile also moves each app to its saved output. Devices that aren't connected are skipped.",
        isOn: $includeOutput
      )
    }
  }

  private func option(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.switch)
    .controlSize(.small)
    .accessibilityHint(detail)
  }
}

/// The profile name field shared by the profile editor and Save Current Mix:
/// a tonal field that matches the app's cards, with inline validation.
struct ProfileNameField: View {
  @Environment(\.wavesTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.wavesAccessibilityOverrides) private var accessibilityOverrides

  @Binding var name: String
  let validationResult: ProfileSaveResult?

  var body: some View {
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
            reduceTransparency: accessibilityOverrides?.reduceTransparency ?? reduceTransparency,
            increasedContrast: accessibilityOverrides?.increasedContrast ?? (contrast == .increased)
          ),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(stroke)
        )
        .accessibilityLabel("Profile name")
        .accessibilityValue(name)
        .accessibilityHint(validationResult?.message ?? "Enter a unique profile name.")
      if let validationResult {
        ProfileValidationFeedback(scope: .name, result: validationResult)
      }
    }
  }

  private var stroke: Color {
    validationResult?.message == nil
      ? theme.hairline(
        increasedContrast: accessibilityOverrides?.increasedContrast ?? (contrast == .increased)
      )
      : WavesDesign.error
  }
}
