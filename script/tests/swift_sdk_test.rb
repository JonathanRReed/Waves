require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

class SwiftSDKTest < Minitest::Test
  HELPER = File.expand_path("../swift_sdk.sh", __dir__)

  def select_sdk(root, plugin: false, fallback: true, version: "27")
    sdk = File.join(root, "SDKs", "MacOSX#{version}.sdk")
    swift = File.join(root, "Toolchain", "usr", "bin", "swift")
    FileUtils.mkdir_p(sdk)
    FileUtils.mkdir_p(File.dirname(swift))
    if fallback
      FileUtils.mkdir_p(File.join(root, "SDKs", "MacOSX26.5.sdk"))
    end
    if plugin
      directory = File.join(root, "Toolchain", "usr", "lib", "swift", "host", "plugins")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "libSwiftUIMacros.dylib"), "fixture")
    end
    stdout, stderr, status = Open3.capture3(
      "/bin/bash", "-c", 'source "$1"; waves_compatible_swift_sdk "$2" "$3"',
      "sdk-test", HELPER, sdk, swift
    )
    assert status.success?, stderr
    stdout.strip
  end

  def test_missing_macro_uses_installed_compatible_sdk
    Dir.mktmpdir do |root|
      assert_equal File.join(root, "SDKs", "MacOSX26.5.sdk"), select_sdk(root)
    end
  end

  def test_complete_toolchain_preserves_default_sdk
    Dir.mktmpdir do |root|
      assert_equal File.join(root, "SDKs", "MacOSX27.sdk"), select_sdk(root, plugin: true)
    end
  end

  def test_no_fallback_preserves_default_instead_of_selecting_missing_sdk
    Dir.mktmpdir do |root|
      assert_equal File.join(root, "SDKs", "MacOSX27.sdk"), select_sdk(root, fallback: false)
    end
  end

  def test_older_sdk_does_not_need_the_new_state_macro_plugin
    Dir.mktmpdir do |root|
      assert_equal File.join(root, "SDKs", "MacOSX15.sdk"), select_sdk(root, version: "15")
    end
  end
end
