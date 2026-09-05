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

def signal_process_group(signal, pid)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
rescue Errno::EPERM
  warn "Warning: permission denied sending #{signal} to phase process group #{pid}."
end

forward_signal = lambda do |signal|
  interrupted_signal ||= signal
  signal_process_group(signal, pid) if pid
end

%w[INT TERM HUP].each do |signal|
  Signal.trap(signal) { forward_signal.call(signal) }
end

def process_group_alive?(pid)
  Process.kill(0, -pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  # Permission denial cannot prove that the group has gone away.
  true
end

def terminate_group(pid, status = nil)
  reaped = !status.nil?
  %w[TERM KILL].each do |signal|
    signal_process_group(signal, pid)
    grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    loop do
      unless reaped
        begin
          reaped = true if Process.waitpid2(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          reaped = true
        end
      end
      return true unless process_group_alive?(pid)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

      sleep 0.05
    end
  end
  # Never block in waitpid after a denied signal or claim the group is gone
  # merely because its leader exited. The caller must report incomplete cleanup.
  false
end

def cleanup_description(terminated, pid)
  return "its process group was terminated." if terminated

  "cleanup is incomplete for process group #{pid}; manual inspection is required."
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
  if waited && !interrupted_signal
    status = waited[1]
    exit(status.exitstatus || 128 + (status.termsig || 0))
  end

  if interrupted_signal
    terminated = terminate_group(pid, waited && waited[1])
    warn "Error: phase #{label.inspect} was interrupted by #{interrupted_signal}; #{cleanup_description(terminated, pid)}"
    exit 128 + Signal.list.fetch(interrupted_signal)
  end

  if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    terminated = terminate_group(pid)
    warn "Error: phase #{label.inspect} timed out after #{timeout} seconds; #{cleanup_description(terminated, pid)}"
    exit 124
  end

  sleep 0.05
end
