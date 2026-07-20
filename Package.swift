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
    // Pinned to the swift-6.0.3-RELEASE tag deliberately: that commit's own
    // manifest declares swift-tools-version 6.0 (matching this package's),
    // so it resolves on any Swift 6.0+ toolchain. A bleeding-edge revision
    // off swift-testing's main branch has repeatedly declared a newer tools
    // version than CI's Xcode ships (6.1, then 6.2), breaking `swift test`
    // before it ever reaches this project's own code — only the basic
    // `#expect` API is used here, which this tag has supported for years.
    .package(
      url: "https://github.com/swiftlang/swift-testing.git",
      revision: "18c42c19cac3fafd61cab1156d4088664b7424ae" // swift-6.0.3-RELEASE
    ),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
  ],
  targets: [
    .executableTarget(
      name: "Waves",
      dependencies: [
        "WavesAudioCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
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
