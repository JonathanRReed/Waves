# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "timeout"
require "rbconfig"

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

  def test_timeout_cleans_up_when_the_group_leader_exits_first
    assert_resistant_descendant_is_stopped(interrupt: false)
  end

  def test_interruption_cleans_up_when_the_group_leader_exits_first
    assert_resistant_descendant_is_stopped(interrupt: true)
  end

  def test_nonzero_child_status_is_preserved
    _stdout, _stderr, status = Open3.capture3(
      RbConfig.ruby, File.expand_path("../run_phase.rb", __dir__),
      "5", "exit status fixture", RbConfig.ruby, "-e", "exit 23"
    )
    assert_equal 23, status.exitstatus
  end

  private

  def assert_resistant_descendant_is_stopped(interrupt:)
    Dir.mktmpdir("waves-phase-leader-exit") do |directory|
      child_path = File.join(directory, "child.pid")
      arm_path = File.join(directory, "arm-child")
      ready_path = File.join(directory, "child-ready")
      child_pid = nil
      program = <<~RUBY
        Signal.trap("TERM") { exit 0 }
        fork do
          STDOUT.reopen(File::NULL, "w")
          STDERR.reopen(File::NULL, "w")
          File.write(ARGV.fetch(0) + ".tmp", Process.pid.to_s)
          File.rename(ARGV.fetch(0) + ".tmp", ARGV.fetch(0))
          sleep 0.01 until File.file?(ARGV.fetch(1))
          Signal.trap("TERM", "IGNORE")
          File.write(ARGV.fetch(2), "ready")
          sleep 30
        end
        sleep 30
      RUBY
      begin
        Open3.popen3(
          RbConfig.ruby, File.expand_path("../run_phase.rb", __dir__),
          interrupt ? "5" : "1", "leader exit fixture",
          RbConfig.ruby, "-e", program, child_path, arm_path, ready_path
        ) do |stdin, stdout, stderr, waiter|
          stdin.close
          Timeout.timeout(8) do
            sleep 0.01 until File.file?(child_path)
            child_pid = Integer(File.read(child_path))
            File.write(arm_path, "arm")
            sleep 0.01 until File.file?(ready_path)
            Process.kill("TERM", waiter.pid) if interrupt
            output = stdout.read
            errors = stderr.read
            status = waiter.value
            assert_equal(interrupt ? 143 : 124, status.exitstatus, "#{output} #{errors}")
            assert_match(interrupt ? /interrupted by TERM/ : /timed out/, errors)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
            while process_alive?(child_pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              sleep 0.01
            end
            refute process_alive?(child_pid), "resistant fixture child #{child_pid} survived"
          end
        ensure
          if waiter.alive?
            begin
              Process.kill("TERM", waiter.pid)
              waiter.join(3)
              Process.kill("KILL", waiter.pid) if waiter.alive?
            rescue Errno::ESRCH
              nil
            end
          end
        end
      ensure
        begin
          Process.kill("KILL", child_pid) if child_pid
        rescue Errno::ESRCH
          nil
        end
      end
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
