import Foundation
import SwiftUI
import WavesAudioCore

struct EqualizerInspectorView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  let app: AudioApp
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Text("App Equalizer")
                .font(.headline)
              Spacer()
              Toggle(
                "Equalizer",
                isOn: Binding(
                  get: { settings.isEnabled },
                  set: { store.setEqualizerEnabled($0, for: app) }
                )
              )
              .labelsHidden()
            }

            Text(
              "This curve affects only \(app.displayName). The Managed Audio EQ in Sound is applied afterward."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker(
              "Bands",
              selection: Binding(
                get: { settings.mode },
                set: { store.setEqualizerMode($0, for: app) }
              )
            ) {
              ForEach(EqualizerMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .pickerStyle(.segmented)

            Picker(
              "Preset",
              selection: Binding(
                get: { settings.selectedPreset },
                set: { preset in
                  guard preset != .custom else { return }
                  store.applyEqualizerPreset(preset, for: app)
                }
              )
            ) {
              ForEach(EqualizerPreset.selectablePresets, id: \.self) { preset in
                Text(preset.displayName).tag(preset)
              }
              if settings.selectedPreset == .custom {
                Text(EqualizerPreset.custom.displayName).tag(EqualizerPreset.custom)
              }
            }

            Divider()

            ForEach(Array(activeBands.enumerated()), id: \.element.id) { index, band in
              EqualizerBandRow(
                band: band,
                gainDB: activeGain(at: index),
                onChange: { store.setEqualizerGain($0, at: index, for: app) }
              )
            }

            HStack {
              Button("Reset to Flat") {
                store.resetEqualizer(for: app)
              }
              .disabled(settings.selectedPreset == .flat)

              Spacer()

              if settings.headroomCompensationDB < 0 {
                Label(
                  "\(formatGain(-settings.headroomCompensationDB)) headroom",
                  systemImage: "shield.lefthalf.filled"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
          .padding(14)
          .wavesCard(cornerRadius: 12)

          VStack(alignment: .leading, spacing: 12) {
            Text("Adaptive Mix")
              .font(.headline)

            Picker(
              "Content type",
              selection: Binding(
                get: { adaptivePolicy.contentType },
                set: { store.setAdaptiveContentType($0, for: app) }
              )
            ) {
              ForEach(AdaptiveContentType.allCases, id: \.self) { type in
                Text(type.displayName).tag(type)
              }
            }

            Picker(
              "Priority",
              selection: Binding(
                get: { adaptivePolicy.priority },
                set: { store.setAdaptivePriority($0, for: app) }
              )
            ) {
              ForEach(AdaptivePriority.allCases, id: \.self) { priority in
                Text(priority.displayName).tag(priority)
              }
            }

            Text(adaptivePolicyDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(14)
          .wavesCard(cornerRadius: 12)

          if let routeMessage {
            Label(routeMessage.text, systemImage: routeMessage.symbol)
              .font(.caption)
              .foregroundStyle(routeMessage.isWarning ? theme.warning : Color.secondary)
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
        }
        .padding(14)
      }
      .disabled(store.isExcluded(app))
    }
    .background(WavesBackground())
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
    .background(theme.subtleFill)
  }

  private var settings: EqualizerSettings {
    store.equalizerSettings(for: app)
  }

  private var adaptivePolicy: AdaptiveAppPolicy {
    store.adaptivePolicy(for: app)
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
    if settings.isEnabled && app.routingState != .managed {
      return "EQ saved, waiting for audio route"
    }
    return settings.isEnabled ? "EQ active" : "EQ off"
  }

  private var adaptivePolicyDescription: String {
    if adaptivePolicy.priority == .neverAdjust {
      return
        "Adaptive Mix leaves this app unchanged. Manual volume and both equalizers still apply."
    }
    switch adaptivePolicy.contentType {
    case .lectureOrVoice:
      return "Speech activity can establish focus while this app is audible."
    case .meeting:
      return
        "Meeting speech follows the selected priority and cannot duck a higher-priority media app."
    case .music:
      return "Music stays audible while higher-priority speech or media moves forward."
    case .videoOrMedia:
      return "Video and media use audible activity to establish their focus tier."
    case .game:
      return "Game audio uses audible activity and the selected priority."
    case .other:
      return "Waves uses audible activity and the selected priority for this app."
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
  @Environment(\.wavesTheme) private var theme
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
      .tint(theme.accent)
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
