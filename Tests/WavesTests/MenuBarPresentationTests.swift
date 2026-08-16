import Testing

@testable import Waves

@Test func idleQuickMixerDoesNotReserveWaveformSpace() {
  let state = MenuBarPresentationState(hasLiveAudio: false, isSettling: false)

  #expect(!state.showsWaveform)
}

@Test func liveOrSettlingQuickMixerShowsCompactWaveform() {
  #expect(MenuBarPresentationState(hasLiveAudio: true, isSettling: false).showsWaveform)
  #expect(MenuBarPresentationState(hasLiveAudio: false, isSettling: true).showsWaveform)
  #expect(MenuBarLayout.liveWaveformHeight == 28)
}
