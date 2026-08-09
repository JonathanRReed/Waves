# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

class RunPhaseTest < Minitest::Test
  def test_timeout_terminates_the_entire_phase_process_group
    Dir.mktmpdir("waves-phase-timeout") do |directory|
      child_path = File.join(directory, "child.pid")
      program = <<~RUBY
        child = spawn("ruby", "-e", "Signal.trap('TERM') {}; sleep 30")
        File.write(ARGV.fetch(0), child.to_s)
        Signal.trap("TERM") {}
        sleep 30
      RUBY
      stdout, stderr, status = Open3.capture3(
        "ruby",
        File.expand_path("../run_phase.rb", __dir__),
        "1",
        "timeout fixture",
        "ruby",
        "-e",
        program,
        child_path
      )

      refute status.success?, "phase unexpectedly passed: #{stdout} #{stderr}"
      assert_match(/timed out/, stderr)
      child_pid = Integer(File.read(child_path))
      _stdout, _stderr, probe = Open3.capture3("kill", "-0", child_pid.to_s)
      refute probe.success?, "timed-out child #{child_pid} survived process-group cleanup"
    end
  end

  def test_successful_phase_returns_the_child_status
    _stdout, stderr, status = Open3.capture3(
      "ruby",
      File.expand_path("../run_phase.rb", __dir__),
      "5",
      "success fixture",
      "ruby",
      "-e",
      "exit 0"
    )
    assert status.success?, stderr
  end
end
