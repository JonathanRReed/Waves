import Foundation

/// Selects which mixer owns ordinary per-app audio routes while Wave Link runs.
public enum PerAppAudioController: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
  case waves
  case waveLink = "wave_link"

  public var id: Self { self }

  public var displayName: String {
    switch self {
    case .waves: "Waves"
    case .waveLink: "Elgato Wave Link"
    }
  }
}
