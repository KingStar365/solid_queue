module SolidQueue
  class ReadyExecution < Execution
    scope :ordered, -> { order(priority: :asc) }
    scope :not_paused, -> { where.not(queue_name: Pause.all_queue_names) }

    before_create :assume_attributes_from_job

    class << self
      def claim(queues, limit)
        return [] unless limit > 0

        candidate_job_ids = []

        transaction do
          candidate_job_ids = query_candidates(queues, limit)
          lock(candidate_job_ids)
        end

        claimed_executions_for(candidate_job_ids)
      end

      def queued_as(queues)
        QueueParser.new(queues, self).scoped_relation
      end

      private
        def query_candidates(queues, limit)
          queued_as(queues).not_paused.ordered.limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:job_id)
        end

        def lock(job_ids)
          return nil if job_ids.none?
          SolidQueue::ClaimedExecution.claim_batch(job_ids)
          where(job_id: job_ids).delete_all
        end

        def claimed_executions_for(job_ids)
          return [] if job_ids.none?

          SolidQueue::ClaimedExecution.where(job_id: job_ids)
        end
    end

    def claim
      transaction do
        SolidQueue::ClaimedExecution.claim_batch(job_id)
        delete
      end
    end
  end
end
