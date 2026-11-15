import AppKit
import SwiftUI

/// The menu-bar glyph, drawn on one fixed-size canvas for every state.
///
/// The four symbols are 14 to 22 points wide, and a status item resizes to its
/// image, so every change of state used to shift the menu-bar items to Waves's
/// left. Drawing each symbol into the widest symbol's canvas keeps the item's
/// width constant. Speaker glyphs are leading-aligned so the speaker body stays
/// put and only the waves change, like the system volume item.
@MainActor
enum MenuBarStatusIcon {
  static func symbolName(for status: AppStore.MenuBarStatus) -> String {
    switch status {
    case .setup: "lock.shield.fill"
    case .playing: "speaker.wave.3.fill"
    case .muted: "speaker.slash.fill"
    case .idle: "speaker.wave.2.fill"
    }
  }

  static let canvasSize: NSSize = {
    let sizes = allStatuses.compactMap { symbol(for: $0)?.size }
    return NSSize(
      width: ceil(sizes.map(\.width).max() ?? 22),
      height: ceil(sizes.map(\.height).max() ?? 16)
    )
  }()

  static func image(for status: AppStore.MenuBarStatus) -> NSImage {
    if let cached = cache[status] { return cached }
    let symbol = symbol(for: status)
    let canvas = canvasSize
    let image = NSImage(size: canvas, flipped: false) { bounds in
      guard let symbol else { return false }
      let x = status == .setup ? (bounds.width - symbol.size.width) / 2 : 0
      let y = (bounds.height - symbol.size.height) / 2
      symbol.draw(in: NSRect(origin: NSPoint(x: x, y: y), size: symbol.size))
      return true
    }
    image.isTemplate = true
    cache[status] = image
    return image
  }

  private static let allStatuses: [AppStore.MenuBarStatus] = [.setup, .playing, .muted, .idle]
  private static var cache: [AppStore.MenuBarStatus: NSImage] = [:]

  private static func symbol(for status: AppStore.MenuBarStatus) -> NSImage? {
    NSImage(systemSymbolName: symbolName(for: status), accessibilityDescription: nil)
  }
}

/// The status item's label. A view of its own so that the menu-bar status it
/// reads invalidates this label, not the whole app scene.
struct MenuBarStatusLabel: View {
  let store: AppStore

  var body: some View {
    let status = store.menuBarStatus
    Image(nsImage: MenuBarStatusIcon.image(for: status))
      // The accessibility label must live on the status-item label itself —
      // VoiceOver reads this view for the menu-bar item, not the popover
      // content.
      .accessibilityLabel(Text(Self.accessibilityLabel(for: status)))
  }

  /// Mirrors the states that drive the glyph so the icon-only status is
  /// perceivable without sight. Shares `store.menuBarStatus` with the icon and
  /// the panel header, so the spoken label can never contradict the screen.
  static func accessibilityLabel(for status: AppStore.MenuBarStatus) -> String {
    switch status {
    case .setup: "Waves, finish setup"
    case .playing: "Waves, playing"
    case .muted: "Waves, muted"
    case .idle: "Waves, idle"
    }
  }
}
