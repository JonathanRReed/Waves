import Foundation
import Testing

@testable import Waves
@testable import WavesAudioCore

@Test func previewBackendRetainsManagedAudioEqualizer() async {
  let backend = PreviewAudioControlBackend()
  var settings = GlobalEqualizerSettings(isEnabled: true, mode: .advanced)
  settings.applyPreset(.voiceFocus)

  await backend.setManagedAudioEqualizer(settings)

  #expect(await backend.managedAudioEqualizerSettingsForTesting() == settings)
}

@Test func workspaceBackendRetainsManagedAudioEqualizerWithoutLiveRoutes() async {
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: .empty,
    intentRouteApplyOverride: { _, _ in }
  )
  var settings = GlobalEqualizerSettings(isEnabled: true)
  settings.applyPreset(.warm)

  await backend.setManagedAudioEqualizer(settings)

  #expect(await backend.managedAudioEqualizerSettingsForTesting() == settings)
}
