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

def process_group_alive?(pid)
  Process.kill(0, -pid)
  true
rescue Errno::ESRCH
  false
end

def terminate_group(pid, status = nil)
  begin
    Process.kill("TERM", -pid)
  rescue Errno::ESRCH
    nil
  end
  reaped = !status.nil?
  group_alive = true
  grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
  loop do
    unless reaped
      begin
        waited = Process.waitpid2(pid, Process::WNOHANG)
        if waited
          status = waited[1]
          reaped = true
        end
      rescue Errno::ECHILD
        reaped = true
      end
    end
    group_alive = process_group_alive?(pid)
    break unless group_alive
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

    sleep 0.05
  end

  begin
    Process.kill("KILL", -pid) if group_alive
  rescue Errno::ESRCH
    nil
  end
  return status if reaped

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
  if waited && !interrupted_signal
    status = waited[1]
    exit(status.exitstatus || 128 + (status.termsig || 0))
  end

  if interrupted_signal
    terminate_group(pid, waited && waited[1])
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
