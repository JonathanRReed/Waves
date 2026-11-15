import Foundation
import Testing

@testable import Waves

@Test func volumeTaperMapsEndpointsExactly() {
  #expect(VolumeTaper.position(forVolume: 0) == 0)
  #expect(VolumeTaper.position(forVolume: 1) == 1)
  #expect(VolumeTaper.volume(forPosition: 0) == 0)
  #expect(VolumeTaper.volume(forPosition: 1) == 1)
}

@Test func volumeTaperPutsHalfwayAtAQuarterOfTheAmplitude() {
  // Half-way on the thumb is about 12 dB down, not the 6 dB of a linear slider.
  #expect(VolumeTaper.volume(forPosition: 0.5) == 0.25)
  #expect(VolumeTaper.position(forVolume: 0.25) == 0.5)
}

@Test func volumeTaperRoundTripsEveryWholePercent() {
  for percent in 0...100 {
    let volume = Float(percent) / 100
    let position = VolumeTaper.position(forVolume: volume)
    #expect(VolumeTaper.volume(forPosition: position) == volume, "\(percent)%")
  }
}

@Test func volumeTaperIsMonotonic() {
  var previous: Float = -1
  for step in 0...1_000 {
    let volume = VolumeTaper.volume(forPosition: Double(step) / 1_000) ?? -1
    #expect(volume >= previous)
    previous = volume
  }
  var previousPosition = -1.0
  for step in 0...1_000 {
    let position = VolumeTaper.position(forVolume: Float(step) / 1_000)
    #expect(position >= previousPosition)
    previousPosition = position
  }
}

@Test func volumeTaperClampsAndRejectsNonFiniteInput() {
  #expect(VolumeTaper.position(forVolume: .nan) == 0)
  #expect(VolumeTaper.position(forVolume: .infinity) == 1)
  #expect(VolumeTaper.position(forVolume: -.infinity) == 0)
  #expect(VolumeTaper.position(forVolume: 2) == 1)
  #expect(VolumeTaper.position(forVolume: -1) == 0)
  #expect(VolumeTaper.volume(forPosition: .nan) == nil)
  #expect(VolumeTaper.volume(forPosition: .infinity) == 1)
  #expect(VolumeTaper.volume(forPosition: -.infinity) == 0)
  #expect(VolumeTaper.volume(forPosition: 1.5) == 1)
}

@Test func volumeTaperStepsAreAudibleAtBothEnds() {
  // One step up from silence lands on a whole, non-zero percent.
  #expect(VolumeTaper.steppedVolume(from: 0, increasing: true) == 0.01)
  // Near the top a step is about 0.9 dB, not the inaudible 0.45 dB of a 5%
  // value-space step.
  let nearTop = VolumeTaper.steppedVolume(from: 0.9, increasing: true)
  #expect(nearTop == 1)
  #expect(VolumeTaper.steppedVolume(from: 1, increasing: false) == 0.9)

  // Every step changes loudness by roughly the same audible amount.
  var volume: Float = 0.01
  while volume < 1 {
    let next = VolumeTaper.steppedVolume(from: volume, increasing: true)
    let decibels = 20 * log10(Double(next) / Double(volume))
    #expect(decibels >= 0.8, "step from \(volume) to \(next) is \(decibels) dB")
    volume = next
  }
}

@Test func volumeTaperStepsStopAtTheEndsAndLandOnWholePercents() {
  #expect(VolumeTaper.steppedVolume(from: 1, increasing: true) == 1)
  #expect(VolumeTaper.steppedVolume(from: 0, increasing: false) == 0)
  #expect(VolumeTaper.steppedVolume(from: 0.004, increasing: false) == 0)
  #expect(VolumeTaper.steppedVolume(from: 0.62, increasing: true) == 0.7)
  #expect(VolumeTaper.steppedVolume(from: 0.62, increasing: false) == 0.54)
  #expect(VolumeTaper.steppedVolume(from: .nan, increasing: true) == 0.01)

  var volume: Float = 0
  var presses = 0
  while volume < 1, presses < 100 {
    volume = VolumeTaper.steppedVolume(from: volume, increasing: true)
    presses += 1
    #expect((volume * 100).rounded() / 100 == volume)
  }
  #expect(volume == 1)
  #expect(presses <= 25)
}
