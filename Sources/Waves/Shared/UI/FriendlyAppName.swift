import AppKit
import WavesAudioCore

/// The best display name Waves can produce for a logical app ID.
///
/// Anywhere Waves persists a reference to an app — a profile member, a mute
/// shortcut — that reference outlives the app running. Showing the raw bundle
/// ID at that point is a visible seam, so this resolves a real name in three
/// steps, cheapest first:
///
/// 1. The session, if the app has run at some point since launch.
/// 2. Launch Services, for an installed app that has not run.
/// 3. The last dot-component of the bundle ID, for an app that isn't installed.
///
/// Step 2 is cached. It is called from view bodies that re-evaluate on every
/// keystroke, and an uncached lookup would re-hit `NSWorkspace` and open a
/// bundle for every unresolved row, every time.
@MainActor
enum FriendlyAppName {
  static func resolve(_ id: String, in apps: [AudioApp]) -> String {
    if let app = apps.first(where: { $0.logicalID == id }) {
      return app.displayName
    }
    if let installed = installedName(forBundleID: id) {
      return installed
    }
    // Imperfect — "com.tinyspeck.slackmacgap" becomes "slackmacgap" — but the
    // naive alternative of showing the whole bundle ID is worse, and this only
    // happens for an app that is neither running nor installed.
    return id.split(separator: ".").last.map(String.init) ?? id
  }

  /// Match `AudioApp`'s bound for display metadata before caching or rendering
  /// names supplied by an installed app's Info.plist.
  private static let maxNameLength = 256

  /// The value is itself optional so a miss (uninstalled bundle ID, or a bundle
  /// with no usable name) is cached too — otherwise an unresolvable row would
  /// re-hit Launch Services on every body re-evaluation.
  private static var storage: [String: String?] = [:]

  static func installedName(forBundleID id: String) -> String? {
    if let cached = storage[id] {
      return cached
    }
    let resolved = lookup(id)
    storage[id] = resolved
    return resolved
  }

  private static func lookup(_ id: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
          let bundle = Bundle(url: url)
    else { return nil }

    return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      .flatMap { $0.isEmpty ? nil : String($0.prefix(maxNameLength)) }
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      .flatMap { $0.isEmpty ? nil : String($0.prefix(maxNameLength)) }
  }
}
