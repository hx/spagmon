require 'forwardable'

module Epi
  class Job
    extend Forwardable

    attr_reader :job_description
    attr_accessor :expected_count

    delegate [:name, :id, :allowed_processes] => :job_description

    def logger
      Epi.logger
    end

    def initialize(job_description, state)
      @job_description = job_description
      @triggers = job_description.triggers.map { |t| Trigger.make self, *t }
      @expected_count = state['expected_count'] || job_description.initial_processes
      @pids = state['pids']
      @dying_pids = state['dying_pids']
    end

    # noinspection RubyStringKeysInHashInspection
    def state
      {
          'expected_count' => expected_count,
          'pids' => pids,
          'dying_pids' => dying_pids
      }
    end

    # Get a hash of PIDs, with internal process IDs as keys and PIDs as values
    # @example `{'1a2v3c4d' => 4820}`
    # @return [Hash]
    def pids
      @pids ||= {}
    end

    # Get a hash of PIDs, with internal process IDs as keys and PIDs as values,
    # for process that are dying
    # @example `{'1a2v3c4d' => 4820}`
    # @return [Hash]
    def dying_pids
      @dying_pids ||= {}
    end

    # Stops processes that shouldn't run, starts process that should run, and
    # fires event handlers
    def sync!

      # Remove non-running PIDs from the list
      pids.reject { |_, pid| ProcessStatus.pids.include? pid }.each do |proc_id, pid|
        logger.debug "Lost process #{pid}"
        pids.delete proc_id
      end

      # Remove non-running PIDs from the dying list. This is just in case
      # the daemon crashed before it was able to clean up a dying worker
      # (i.e. it sent a TERM but didn't get around to sending a KILL)
      dying_pids.select! { |_, pid| ProcessStatus.pids.include? pid }

      # TODO: clean up processes that never died how they should have

      # Run new processes
      start_one while running_count < expected_count

      # Kill old processes
      stop_one while running_count > expected_count
    end

    def run_triggers!
      @triggers.each &:try
    end

    def shutdown!(&callback)
      count = running_count
      if count > 0
        count.times do
          stop_one do
            count -= 1
            callback.call if callback && count == 0
          end
        end
      else
        callback.call if callback
      end
    end

    def terminate!
      self.expected_count = 0
      sync!
    end

    def restart!
      count = expected_count
      if count > 0
        self.expected_count = 0
        sync!
        self.expected_count = count
        sync!
      end
      self
    end

    def running_processes
      pids.map { |proc_id, pid| [proc_id, ProcessStatus[pid] || RunningProcess.new(pid)] }.select { |_, v| v.was_alive? }.to_h
    end

    def running_count
      pids.count
    end

    def dying_count
      dying_pids.count
    end

    # Replace a running process with a new one
    # @param pid [Fixnum] PID of the process to replace
    def replace(pid, &callback)
      stop_one pid do
        start_one while running_count < expected_count
        callback.call if callback
      end
    end

    private

    def start_one
      proc_id, pid = job_description.launch
      pids[proc_id] = pid
      Jobs.by_pid[pid] = self
    end

    def stop_one(pid = nil, &callback)
      if pid
        proc_id = pids.key pid
        raise Exceptions::Fatal, "Process #{pid} isn't managed by job #{id}" unless proc_id
        pids.delete proc_id
      else
        proc_id, pid = pids.shift
      end
      dying_pids[proc_id] = pid
      work = proc do
        ProcessStatus[pid].kill job_description.kill_timeout
      end
      done = proc do
        dying_pids.delete proc_id
        Jobs.by_pid.delete pid
        callback.call if callback
      end
      EventMachine.defer work, done
    end

  end
end
