module Spagmon
  module Server
    module Responders
      class Job < Responder

        attr_accessor :id, :instruction

        def run
          Jobs.beat!
          raise Exceptions::Fatal, 'Unknown job ID' unless Spagmon::Job === job
          case instruction
            when /^\d+$/ then set instruction.to_i
            when /^(\d+ )?(more|less)$/ then __send__ $2, ($1 || 1).to_i
            else __send__ instruction
          end
        end

        private

        def job
          @job ||= Jobs[id]
        end

        def set(count)
          # TODO: validate count
          original = job.expected_count
          # TODO: ensure difference
          job.expected_count = count
          job.sync!
          # TODO: update expected count in data file
          "#{count < original ? 'De' : 'In'}creasing '#{job.name}' processes by #{(original - count).abs} (from #{original} to #{count})"
        end

        def more(increase)
          set job.expected_count + increase
        end

        def less(decrease)
          set job.expected_count - decrease
        end

        def max
          set job.allowed_processes.max
        end

        def min
          set job.allowed_processes.min
        end

        def pause

        end

        def resume

        end

        def restart

        end

      end
    end
  end
end
