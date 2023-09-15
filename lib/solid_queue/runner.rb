# frozen_string_literal: true

module SolidQueue
  module Runner
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks
      define_callbacks :start, :run, :shutdown

      include AppExecutor, Procline
      include ProcessRegistration, Interruptible

      attr_accessor :supervisor_pid
    end

    def start(mode: :supervised)
      boot_in mode

      run_callbacks(:start) do
        if mode == :async
          @thread = Thread.new { start_loop }
        else
          start_loop
        end
      end
    end

    def stop
      @stopping = true
      @thread&.join
    end

    def running?
      !stopping?
    end

    private
      attr_reader :mode

      def boot_in(mode)
        @mode = mode.to_s.inquiry
        @stopping = false

        procline "starting in mode #{mode}"

        register_signal_handlers

        SolidQueue.logger.info("[SolidQueue] Starting #{self}")
      end

      def register_signal_handlers
        %w[ INT TERM ].each do |signal|
          trap(signal) do
            stop
            interrupt
          end
        end

        trap(:QUIT) do
          exit!
        end
      end

      def start_loop
        procline "started"

        loop do
          break if shutting_down?

          run_callbacks(:run) { run }
        end
      ensure
        run_callbacks(:shutdown) { shutdown }
      end

      def shutting_down?
        stopping? || supervisor_went_away? || finished?
      end

      def run
        raise NotImplementedError
      end

      def shutdown
        procline "shutting down"
      end

      def stopping?
        @stopping
      end

      def finished?
        running_inline? && all_work_completed?
      end

      def supervisor_went_away?
        supervised? && supervisor_pid != ::Process.ppid
      end

      def supervised?
        mode.supervised?
      end

      def all_work_completed?
        false
      end

      def running_inline?
        mode.inline?
      end

      def hostname
        @hostname ||= Socket.gethostname
      end

      def process_pid
        @pid ||= ::Process.pid
      end
  end
end
