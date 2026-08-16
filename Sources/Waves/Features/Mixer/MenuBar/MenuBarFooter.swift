import AppKit
import SwiftUI

struct MenuBarFooter: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    HStack(spacing: 8) {
      Button("Open Waves…") {
        openWindow(id: AppSceneID.mainWindow)
        NSApp.activate(ignoringOtherApps: true)
      }
      .accessibilityLabel("Open Waves main window")

      Spacer()

      Button {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        Image(systemName: "gearshape")
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Open Settings")
      .help("Settings")
    }
    .controlSize(.small)
  }
}
