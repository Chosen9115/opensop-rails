# frozen_string_literal: true

module Opensop
  # Builds the per-process status rollup consumed by:
  #   GET /sop/processes/status   — JSON API (S0a status model)
  #   GET /observability          — UI terminal view
  #
  # Status model (SPEC v0.7 S0a):
  #   status    ∈ { "open", "scheduled", "running" }
  #   last_status ∈ { "ok", "error", "never" }
  #   last_run_at  ISO-8601 or null
  #   next_run_at  ISO-8601 or null (only for scheduled)
  #   active_instances  integer count of pending/running instances
  #
  # Status derivation rules:
  #   running   — at least one instance in pending/running state
  #   scheduled — has an enabled Sop::Schedule row (regardless of active instances)
  #   open      — neither of the above
  #
  # The whole call is defensively wrapped: if any table is missing (unmigrated
  # environment) we substitute safe zero/nil values rather than raising, matching
  # the posture of MetricsRollup and ScheduleDispatcher.
  class ProcessStatusRollup
    Result = Struct.new(:processes, keyword_init: true)

    ProcessStatus = Struct.new(
      :name,
      :version,
      :description,
      :status,       # "open" | "scheduled" | "running"
      :last_status,  # "ok" | "error" | "never"
      :last_run_at,  # Time or nil
      :next_run_at,  # Time or nil
      :active_instances,
      :cron_expression,
      :schedule_enabled,
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      processes = safe_load_processes
      return Result.new(processes: []) if processes.empty?

      schedules_by_process = safe_load_schedules_by_process
      in_flight_by_process = safe_load_in_flight_by_process
      last_instance_by_process = safe_load_last_instance_by_process

      statuses = processes.map do |process|
        schedule = schedules_by_process[process.name]
        in_flight = in_flight_by_process[process.name].to_i
        last_instance = last_instance_by_process[process.name]

        status = derive_status(in_flight, schedule)
        last_status = derive_last_status(last_instance)

        ProcessStatus.new(
          name: process.name,
          version: process.version,
          description: process.description,
          status: status,
          last_status: last_status,
          last_run_at: last_instance&.dig(:completed_at) || last_instance&.dig(:updated_at),
          next_run_at: schedule&.next_run_at,
          active_instances: in_flight,
          cron_expression: schedule&.cron_expression,
          schedule_enabled: schedule&.enabled?
        )
      end

      Result.new(processes: statuses)
    end

    private

    # "running" if any active instances; "scheduled" if has an enabled
    # schedule; "open" otherwise.
    def derive_status(in_flight, schedule)
      return "running" if in_flight > 0
      return "scheduled" if schedule&.enabled?
      "open"
    end

    # "ok" if last terminal instance was completed; "error" if failed or
    # cancelled; "never" if no terminal instances exist.
    def derive_last_status(last_instance)
      return "never" if last_instance.nil?

      case last_instance[:state]
      when "completed" then "ok"
      when "failed", "cancelled" then "error"
      else "never"
      end
    end

    # Returns the latest published Sop::Process per name (highest version).
    def safe_load_processes
      Sop::Process.published.order(:name, :version).to_a
        .group_by(&:name)
        .map { |_, versions| versions.max_by { |p| version_key(p.version) } }
        .sort_by(&:name)
    rescue ActiveRecord::StatementInvalid
      []
    end

    # Returns a Hash { process_name => Sop::Schedule } — the first enabled
    # schedule per process, falling back to any schedule.
    def safe_load_schedules_by_process
      Sop::Schedule
        .order(enabled: :desc, next_run_at: :asc)
        .to_a
        .each_with_object({}) do |sched, h|
          h[sched.process_name] ||= sched
        end
    rescue ActiveRecord::StatementInvalid
      {}
    end

    # Returns a Hash { process_name => count } of active (pending/running)
    # instances per process.
    def safe_load_in_flight_by_process
      Sop::Instance
        .where(state: %w[pending running])
        .group(:process_name)
        .count
    rescue ActiveRecord::StatementInvalid
      {}
    end

    # Returns a Hash { process_name => {state:, completed_at:, updated_at:} }
    # using the most recently updated terminal (completed/failed/cancelled)
    # instance per process.
    def safe_load_last_instance_by_process
      Sop::Instance
        .where(state: %w[completed failed cancelled])
        .order(updated_at: :desc)
        .pluck(:process_name, :state, :completed_at, :updated_at)
        .each_with_object({}) do |(name, state, completed_at, updated_at), h|
          h[name] ||= { state: state, completed_at: completed_at, updated_at: updated_at }
        end
    rescue ActiveRecord::StatementInvalid
      {}
    end

    def version_key(version)
      Gem::Version.new(version.to_s)
    rescue ArgumentError
      Gem::Version.new("0")
    end
  end
end
