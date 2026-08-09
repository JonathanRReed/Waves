// swift-tools-version: 6.0
import PackageDescription

// This package is copied beside the real Sources directory by
// script/run-tsan-harness.sh. Keeping Swift Testing out of this graph matters:
// SwiftPM's global sanitizer flag also instruments source-built macro tools,
// and an instrumented compiler plugin cannot complete the macro handshake.
let package = Package(
  name: "WavesTSanHarness",
  platforms: [
    .macOS("14.2")
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
  ],
  targets: [
    .target(
      name: "Waves",
      dependencies: [
        "WavesAudioCore",
        "WavesRealtimeSupport",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      path: "Sources/Waves",
      exclude: ["App/WavesApp.swift"],
      resources: [
        .process("Resources")
      ],
      swiftSettings: [.unsafeFlags(["-enable-testing"])]
    ),
    .target(
      name: "WavesAudioCore",
      path: "Sources/WavesAudioCore"
    ),
    .target(
      name: "WavesRealtimeSupport",
      path: "Sources/WavesRealtimeSupport",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "WavesTSanHarness",
      dependencies: ["Waves", "WavesAudioCore"],
      path: "Sources/WavesTSanHarness"
    ),
  ]
)
