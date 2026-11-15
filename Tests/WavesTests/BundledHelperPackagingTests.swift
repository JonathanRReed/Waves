import Foundation
import Testing
import WavesControlClient

// wavesctl ships inside Waves.app. Packaging can only be exercised end to end
// with the release signing identity, so these tests pin the contract in the
// packaging script itself: built universal, placed in Contents/Helpers, signed
// before the bundle so the bundle seals it, and asserted by every check that
// validates a package. The paths users are told to link must match.

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func packagingScript() throws -> String {
  try String(contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
}

private func function(_ name: String, in script: String) throws -> String {
  let start = try #require(script.range(of: "\n\(name)() {\n"))
  let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
  return String(script[start.lowerBound..<end.upperBound])
}

@Test func packagingPlacesAUniversalWavesctlInContentsHelpers() throws {
  let script = try packagingScript()
  #expect(script.contains(#"APP_HELPERS="$APP_CONTENTS/Helpers""#))
  #expect(script.contains(#"APP_CLI="$APP_HELPERS/$CLI_NAME""#))
  #expect(script.contains(#"CLI_NAME="wavesctl""#))

  let build = try function("build_app_bundle", in: script)
  #expect(
    build.contains(
      #"lipo -create "$arm64_bin_dir/$CLI_NAME" "$x86_64_bin_dir/$CLI_NAME" -output "$build_output_dir/$CLI_NAME""#))
  #expect(build.contains(#"cp "$build_output_dir/$CLI_NAME" "$APP_CLI""#))
}

@Test func packagingSignsTheHelperBeforeSealingTheBundle() throws {
  let build = try function("build_app_bundle", in: try packagingScript())
  let helper = try #require(build.range(of: #"sign_runtime_item "$APP_CLI" "" "$CLI_IDENTIFIER""#))
  let bundle = try #require(build.range(of: #"sign_runtime_item "$APP_BUNDLE" "$entitlements""#))
  #expect(helper.lowerBound < bundle.lowerBound, "the bundle must be signed after, and so seal, its helper")
}

@Test func everyPackageCheckAssertsTheHelper() throws {
  let script = try packagingScript()

  let validate = try function("validate_app_bundle", in: script)
  #expect(validate.contains(#"require_universal_binary "$cli""#))
  #expect(validate.contains(#"validate_minimum_os "$cli""#))
  #expect(validate.contains(#"/usr/bin/codesign --verify --strict "$cli""#))
  #expect(validate.contains(#"Identifier=$CLI_IDENTIFIER"#))
  #expect(validate.contains("must not carry entitlements"))

  let publication = try function("publication_check", in: script)
  #expect(publication.contains(#"/usr/bin/codesign -dvvv "$APP_CLI""#))
  #expect(publication.contains(#"Authority=$CANONICAL_SIGN_IDENTITY"#))
  #expect(publication.contains("is not signed with the hardened runtime"))

  let smoke = try function("package_smoke", in: script)
  #expect(smoke.contains(#""$mounted_app/Contents/Helpers/$CLI_NAME" --help"#))
}

@Test func theDocumentedLinkPointsAtThePackagedHelper() throws {
  let packaged = "/Applications/Waves.app/Contents/Helpers/wavesctl"
  #expect(WavesCTLUsage.text.contains(packaged))
  let readme = try String(contentsOf: repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
  #expect(readme.contains(packaged))
}
