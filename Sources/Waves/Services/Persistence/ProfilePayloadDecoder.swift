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
        profiles.append(try container.decode(AdditiveProfilePayload.self).profile)
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

  /// Profiles predate the schema envelope. Their identity, name, and entries
  /// are foundational, while timestamps were additive metadata and therefore
  /// default to a stable historical value when an older file omits them.
  private struct AdditiveProfilePayload: Decodable {
    private enum CodingKeys: String, CodingKey {
      case id
      case name
      case entries
      case createdAt
      case updatedAt
    }

    let profile: Profile

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let name = try container.decode(String.self, forKey: .name)
      guard name.count <= Profile.maxNameLength else {
        throw DecodingError.dataCorruptedError(
          forKey: .name,
          in: container,
          debugDescription: "Profile name exceeds \(Profile.maxNameLength) characters."
        )
      }

      var entries: [ProfileEntry] = []
      if container.contains(.entries) {
        var entriesContainer = try container.nestedUnkeyedContainer(forKey: .entries)
        if let count = entriesContainer.count, count > Profile.maxEntries {
          throw DecodingError.dataCorruptedError(
            forKey: .entries,
            in: container,
            debugDescription: "Profile exceeds \(Profile.maxEntries) entries."
          )
        }
        entries.reserveCapacity(min(entriesContainer.count ?? 0, Profile.maxEntries))
        while !entriesContainer.isAtEnd {
          guard entries.count < Profile.maxEntries else {
            throw DecodingError.dataCorruptedError(
              forKey: .entries,
              in: container,
              debugDescription: "Profile exceeds \(Profile.maxEntries) entries."
            )
          }
          entries.append(try entriesContainer.decode(ProfileEntry.self))
        }
      }

      let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
      profile = Profile(
        id: try container.decode(UUID.self, forKey: .id),
        name: name,
        entries: entries,
        createdAt: createdAt,
        updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
      )
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
