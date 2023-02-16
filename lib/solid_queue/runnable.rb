# frozen_string_literal: true

module SolidQueue::Runnable
  def start
    @stopping = false
    @thread = Thread.new { run }

    log "Started #{self}"
  end

  def stop
    @stopping = true
    wait
  end

  private
    def trap_signals
      %w[ INT TERM ].each do |signal|
        trap(signal) { stop }
      end
    end

    def run
    end

    def stopping?
      @stopping
    end

    def wait
      @thread&.join
    end

    def interruptable_sleep(seconds)
      while !stopping? && seconds > 0
        Kernel.sleep 0.1
        seconds -= 0.1
      end
    end

    def log(message)
      SolidQueue.logger.info("[SolidQueue] #{message}")
    end
end
