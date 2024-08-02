# frozen_string_literal: true

require "fugit"

module SolidQueue
  class RecurringTask < Record
    serialize :arguments, coder: Arguments, default: []

    validate :supported_schedule
    validate :existing_job_class

    scope :static, -> { where(static: true) }

    class << self
      def wrap(args)
        args.is_a?(self) ? args : from_configuration(args.first, **args.second)
      end

      def from_configuration(key, **options)
        new(key: key, class_name: options[:class], schedule: options[:schedule], arguments: options[:args])
      end

      def create_or_update_all(tasks)
        if connection.supports_insert_conflict_target?
          # PostgreSQL fails and aborts the current transaction when it hits a duplicate key conflict
          # during two concurrent INSERTs for the same value of an unique index. We need to explicitly
          # indicate unique_by to ignore duplicate rows by this value when inserting
          upsert_all tasks.map(&:attributes_for_upsert), unique_by: :key
        else
          upsert_all tasks.map(&:attributes_for_upsert)
        end
      end
    end

    def delay_from_now
      [ (next_time - Time.current).to_f, 0 ].max
    end

    def next_time
      parsed_schedule.next_time.utc
    end

    def enqueue(at:)
      SolidQueue.instrument(:enqueue_recurring_task, task: key, at: at) do |payload|
        active_job = if using_solid_queue_adapter?
          perform_later_and_record(run_at: at)
        else
          payload[:other_adapter] = true

          perform_later do |job|
            unless job.successfully_enqueued?
              payload[:enqueue_error] = job.enqueue_error&.message
            end
          end
        end

        payload[:active_job_id] = active_job.job_id if active_job
      rescue RecurringExecution::AlreadyRecorded
        payload[:skipped] = true
      rescue Job::EnqueueError => error
        payload[:enqueue_error] = error.message
      end
    end

    def to_s
      "#{class_name}.perform_later(#{arguments.map(&:inspect).join(",")}) [ #{parsed_schedule.original} ]"
    end

    def attributes_for_upsert
      attributes.without("id", "created_at", "updated_at")
    end

    private
      def supported_schedule
        unless parsed_schedule.instance_of?(Fugit::Cron)
          errors.add :schedule, :unsupported, message: "is not a supported recurring schedule"
        end
      end

      def existing_job_class
        unless job_class.present?
          errors.add :class_name, :undefined, message: "doesn't correspond to an existing class"
        end
      end

      def using_solid_queue_adapter?
        job_class.queue_adapter_name.inquiry.solid_queue?
      end

      def perform_later_and_record(run_at:)
        RecurringExecution.record(key, run_at) { perform_later }
      end

      def perform_later(&block)
        job_class.perform_later(*arguments_with_kwargs, &block)
      end

      def arguments_with_kwargs
        if arguments.last.is_a?(Hash)
          arguments[0...-1] + [ Hash.ruby2_keywords_hash(arguments.last) ]
        else
          arguments
        end
      end


      def parsed_schedule
        @parsed_schedule ||= Fugit.parse(schedule)
      end

      def job_class
        @job_class ||= class_name&.safe_constantize
      end
  end
end
