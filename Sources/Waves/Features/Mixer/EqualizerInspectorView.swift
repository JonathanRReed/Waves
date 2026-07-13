import Foundation
import SwiftUI
import WavesAudioCore

struct EqualizerInspectorView: View {
  @Environment(AppStore.self) private var store
  let app: AudioApp
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      Form {
        Section {
          Toggle("Equalizer", isOn: Binding(
            get: { settings.isEnabled },
            set: { store.setEqualizerEnabled($0, for: app) }
          ))
          .help("Apply this curve only to \(app.displayName).")

          Picker("Bands", selection: Binding(
            get: { settings.mode },
            set: { store.setEqualizerMode($0, for: app) }
          )) {
            ForEach(EqualizerMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.segmented)

          Picker("Preset", selection: Binding(
            get: { settings.selectedPreset },
            set: { preset in
              guard preset != .custom else { return }
              store.applyEqualizerPreset(preset, for: app)
            }
          )) {
            ForEach(EqualizerPreset.selectablePresets, id: \.self) { preset in
              Text(preset.displayName).tag(preset)
            }
            if settings.selectedPreset == .custom {
              Text(EqualizerPreset.custom.displayName).tag(EqualizerPreset.custom)
            }
          }
        } footer: {
          Text("Voice Focus removes low rumble and softens distracting highs while preserving speech.")
        }

        Section {
          ForEach(Array(activeBands.enumerated()), id: \.element.id) { index, band in
            EqualizerBandRow(
              band: band,
              gainDB: activeGain(at: index),
              onChange: { store.setEqualizerGain($0, at: index, for: app) }
            )
          }

          Button("Reset to Flat") {
            store.resetEqualizer(for: app)
          }
          .disabled(settings.selectedPreset == .flat)
        } header: {
          Text(settings.mode == .simple ? "3-Band EQ" : "8-Band EQ")
        } footer: {
          if settings.headroomCompensationDB < 0 {
            Text("Waves reserves \(formatGain(-settings.headroomCompensationDB)) of headroom to prevent clipping.")
          }
        }

        Section("Adaptive Mix") {
          Picker("App role", selection: Binding(
            get: { settings.adaptiveRole },
            set: { store.setAdaptiveRole($0, for: app) }
          )) {
            ForEach(AdaptiveAppRole.allCases, id: \.self) { role in
              Text(role.displayName).tag(role)
            }
          }

          Text(adaptiveRoleDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let routeMessage {
          Section {
            Label(routeMessage.text, systemImage: routeMessage.symbol)
              .font(.caption)
              .foregroundStyle(routeMessage.isWarning ? WavesDesign.warning : Color.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .disabled(store.isExcluded(app))
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
  }

  private var header: some View {
    HStack(spacing: 10) {
      AppIconView(app: app)

      VStack(alignment: .leading, spacing: 2) {
        Text(app.displayName)
          .font(.headline)
          .lineLimit(1)
        Text(headerSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      Button(action: onClose) {
        Image(systemName: "xmark")
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .help("Close Equalizer")
      .accessibilityLabel("Close equalizer")
    }
    .padding(16)
  }

  private var settings: EqualizerSettings {
    store.equalizerSettings(for: app)
  }

  private var activeBands: [EqualizerBandDefinition] {
    EqualizerBandCatalog.bands(for: settings.mode)
  }

  private func activeGain(at index: Int) -> Float {
    let gains = settings.activeGainsDB
    return gains.indices.contains(index) ? gains[index] : 0
  }

  private var headerSubtitle: String {
    if store.isExcluded(app) { return "Excluded from Waves" }
    if settings.isEnabled && app.routingState != .managed { return "EQ saved, waiting for audio route" }
    return settings.isEnabled ? "EQ active" : "EQ off"
  }

  private var adaptiveRoleDescription: String {
    switch settings.adaptiveRole {
    case .auto:
      "Waves classifies conferencing apps as voice and music or video apps as media."
    case .voice:
      "Speech in this app can lower media apps when Speech Focus is active."
    case .media:
      "This app can be gently lowered while another app carries speech."
    case .ignore:
      "Adaptive Mix leaves this app unchanged. Its manual volume and EQ still apply."
    }
  }

  private var routeMessage: (text: String, symbol: String, isWarning: Bool)? {
    if store.isExcluded(app) {
      return ("Manage this app with Waves before using its EQ.", "nosign", true)
    }
    if settings.isEnabled && app.routingState != .managed {
      return (
        "Your EQ is saved. Waves will apply it when this app has a supported audio route.",
        "clock.arrow.circlepath",
        false
      )
    }
    return nil
  }

  private func formatGain(_ gainDB: Float) -> String {
    String(format: "%.1f dB", gainDB)
  }
}

private struct EqualizerBandRow: View {
  let band: EqualizerBandDefinition
  let gainDB: Float
  let onChange: (Float) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(band.label)
          .font(.caption.weight(.medium))
        Spacer()
        Text(formattedGain)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 54, alignment: .trailing)
      }

      Slider(
        value: Binding(
          get: { Double(gainDB) },
          set: { onChange(Float($0)) }
        ),
        in: Double(EqualizerSettings.minimumGainDB)...Double(EqualizerSettings.maximumGainDB),
        step: 0.5
      )
      .tint(WavesDesign.accent)
      .accessibilityLabel("\(band.label) gain")
      .accessibilityValue(formattedGain)
    }
    .padding(.vertical, 2)
  }

  private var formattedGain: String {
    let prefix = gainDB > 0 ? "+" : ""
    return "\(prefix)\(String(format: "%.1f", gainDB)) dB"
  }
}
