// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Waves",
  platforms: [
    .macOS("14.2")
  ],
  products: [
    .executable(name: "Waves", targets: ["Waves"]),
    .library(name: "WavesAudioCore", targets: ["WavesAudioCore"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/swiftlang/swift-testing.git",
      revision: "48a471ab313e858258ab0b9b0bf2cea55a50cefb"
    )
  ],
  targets: [
    .executableTarget(
      name: "Waves",
      dependencies: ["WavesAudioCore"],
      path: "Sources/Waves",
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "WavesAudioCore",
      path: "Sources/WavesAudioCore"
    ),
    .testTarget(
      name: "WavesTests",
      dependencies: [
        "Waves",
        "WavesAudioCore",
        .product(name: "Testing", package: "swift-testing"),
      ],
      path: "Tests/WavesTests"
    ),
  ]
)
