import AppIntents
import Foundation

// MARK: - App entity

/// A controllable app surfaced to Shortcuts/Spotlight, backed by the live mixer.
struct WavesAppEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation { "App" }
  static let defaultQuery = WavesAppQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WavesAppQuery: EntityQuery {
  @MainActor
  func entities(for identifiers: [String]) async throws -> [WavesAppEntity] {
    let apps = AppStore.shared?.automationApps ?? []
    return apps
      .filter { identifiers.contains($0.logicalID) }
      .map { WavesAppEntity(id: $0.logicalID, name: $0.name) }
  }

  @MainActor
  func suggestedEntities() async throws -> [WavesAppEntity] {
    (AppStore.shared?.automationApps ?? []).map { WavesAppEntity(id: $0.logicalID, name: $0.name) }
  }
}

// MARK: - Intents

struct SetAppVolumeIntent: AppIntent {
  static var title: LocalizedStringResource { "Set App Volume" }
  static var description: IntentDescription { "Sets a specific app's volume in Waves." }

  @Parameter(title: "App") var app: WavesAppEntity
  @Parameter(title: "Volume (0–100)", controlStyle: .field, inclusiveRange: (0, 100))
  var volume: Int

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let store = AppStore.shared else {
      throw WavesIntentError.appNotReady
    }
    let clamped = Float(max(0, min(100, volume))) / 100
    guard store.automationSetVolume(clamped, logicalID: app.id) else {
      throw WavesIntentError.appNotFound(app.name)
    }
    return .result()
  }
}

struct SetAppMuteIntent: AppIntent {
  static var title: LocalizedStringResource { "Set App Mute" }
  static var description: IntentDescription { "Mutes or unmutes a specific app in Waves." }

  @Parameter(title: "App") var app: WavesAppEntity
  @Parameter(title: "Muted") var muted: Bool

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let store = AppStore.shared else {
      throw WavesIntentError.appNotReady
    }
    guard store.automationSetMuted(muted, logicalID: app.id) else {
      throw WavesIntentError.appNotFound(app.name)
    }
    return .result()
  }
}

struct ApplyWavesPresetIntent: AppIntent {
  static var title: LocalizedStringResource { "Apply Preset" }
  static var description: IntentDescription { "Applies a saved Waves preset." }

  @Parameter(title: "Preset Name") var presetName: String

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let store = AppStore.shared else {
      throw WavesIntentError.appNotReady
    }
    guard store.automationApplyPreset(named: presetName) else {
      throw WavesIntentError.presetNotFound(presetName)
    }
    return .result()
  }
}

enum WavesIntentError: Error, CustomLocalizedStringResourceConvertible {
  case appNotReady
  case appNotFound(String)
  case presetNotFound(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .appNotReady:
      return "Waves isn't ready yet. Open Waves and try again."
    case .appNotFound(let name):
      return "Waves couldn't find \(name) in the mixer."
    case .presetNotFound(let name):
      return "Waves couldn't find a preset named \(name)."
    }
  }
}

// MARK: - Shortcuts surface

struct WavesShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: SetAppVolumeIntent(),
      phrases: ["Set app volume in \(.applicationName)"],
      shortTitle: "Set App Volume",
      systemImageName: "slider.horizontal.3"
    )
    AppShortcut(
      intent: SetAppMuteIntent(),
      phrases: ["Mute an app in \(.applicationName)"],
      shortTitle: "Set App Mute",
      systemImageName: "speaker.slash"
    )
    AppShortcut(
      intent: ApplyWavesPresetIntent(),
      phrases: ["Apply a \(.applicationName) preset"],
      shortTitle: "Apply Preset",
      systemImageName: "slider.horizontal.below.rectangle"
    )
  }
}
