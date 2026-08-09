#!/usr/bin/env ruby
# frozen_string_literal: true

unless ARGV.length >= 3
  warn "usage: run_phase.rb TIMEOUT_SECONDS LABEL COMMAND [ARG ...]"
  exit 2
end

timeout_text = ARGV.shift
label = ARGV.shift
command = ARGV

unless timeout_text.match?(/\A[1-9]\d*\z/)
  warn "Error: phase timeout must be a positive integer number of seconds."
  exit 2
end

timeout = Integer(timeout_text)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
pid = nil
interrupted_signal = nil

forward_signal = lambda do |signal|
  interrupted_signal ||= signal
  begin
    Process.kill(signal, -pid) if pid
  rescue Errno::ESRCH
    nil
  end
end

%w[INT TERM HUP].each do |signal|
  Signal.trap(signal) { forward_signal.call(signal) }
end

def terminate_group(pid)
  Process.kill("TERM", -pid)
rescue Errno::ESRCH
  nil
ensure
  grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
  loop do
    waited = Process.waitpid2(pid, Process::WNOHANG)
    return waited[1] if waited
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

    sleep 0.05
  end

  begin
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end
  begin
    Process.waitpid2(pid)[1]
  rescue Errno::ECHILD
    nil
  end
end

puts "==> #{label} (deadline: #{timeout}s)"
$stdout.flush

begin
  pid = Process.spawn(*command, pgroup: true)
rescue SystemCallError => error
  warn "Error: could not start phase #{label.inspect}: #{error.message}"
  exit 1
end

loop do
  waited = Process.waitpid2(pid, Process::WNOHANG)
  if waited
    status = waited[1]
    exit(status.exitstatus || 128 + (status.termsig || 0))
  end

  if interrupted_signal
    terminate_group(pid)
    warn "Error: phase #{label.inspect} was interrupted by #{interrupted_signal}."
    exit 128 + Signal.list.fetch(interrupted_signal)
  end

  if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    terminate_group(pid)
    warn "Error: phase #{label.inspect} timed out after #{timeout} seconds; its process group was terminated."
    exit 124
  end

  sleep 0.05
end
