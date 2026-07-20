import Foundation
import WavesAudioCore

/// Bounded decoder for user-controlled profile files. The generic persistence
/// decoder materializes an entire `[Profile]` before callers can validate its
/// structure. This wrapper stops decoding as soon as the collection limit is
/// crossed and applies the same rules to persisted files and manual imports.
enum ProfilePayloadDecoder {
  static let maxProfiles = 500

  static func decodePersistedProfiles(from data: Data, using decoder: JSONDecoder) throws -> [Profile] {
    let payload = try decoder.decode(ProfileFilePayload.self, from: data)
    guard !payload.isSingleProfile else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "Persisted profiles must be an array.")
      )
    }
    return payload.profiles
  }

  static func decodeImportedProfiles(from data: Data, using decoder: JSONDecoder) throws -> [Profile] {
    try decoder.decode(ProfileFilePayload.self, from: data).profiles
  }

  private struct BoundedProfileArray: Codable {
    let profiles: [Profile]

    init(from decoder: Decoder) throws {
      var container = try decoder.unkeyedContainer()
      if let count = container.count, count > maxProfiles {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Profile collection exceeds \(maxProfiles) profiles.")
        )
      }

      var profiles: [Profile] = []
      profiles.reserveCapacity(min(container.count ?? 0, maxProfiles))
      while !container.isAtEnd {
        guard profiles.count < maxProfiles else {
          throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Profile collection exceeds \(maxProfiles) profiles.")
          )
        }
        profiles.append(try container.decode(Profile.self))
      }
      self.profiles = profiles
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.unkeyedContainer()
      for profile in profiles {
        try container.encode(profile)
      }
    }
  }

  private struct ProfileFilePayload: Decodable {
    private enum EnvelopeKeys: String, CodingKey {
      case schemaVersion
      case payload
    }

    let profiles: [Profile]
    let isSingleProfile: Bool

    init(from decoder: Decoder) throws {
      if let array = try? BoundedProfileArray(from: decoder) {
        profiles = array.profiles
        isSingleProfile = false
        return
      }

      let container = try decoder.container(keyedBy: EnvelopeKeys.self)
      if container.contains(.schemaVersion) || container.contains(.payload) {
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version >= 1, version <= PersistedSchema.current else {
          throw DecodingError.dataCorruptedError(
            forKey: .schemaVersion,
            in: container,
            debugDescription: "Unsupported schema version \(version)."
          )
        }
        profiles = try container.decode(BoundedProfileArray.self, forKey: .payload).profiles
        isSingleProfile = false
      } else {
        profiles = [try Profile(from: decoder)]
        isSingleProfile = true
      }
    }
  }
}
