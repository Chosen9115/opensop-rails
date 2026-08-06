# frozen_string_literal: true

module Opensop
  # Builds the per-process status rollup consumed by:
  #   GET /sop/processes/status   — JSON API (SPEC v0.7 §9.4)
  #
  # Entry shape (SPEC v0.7 §9.4):
  #   state       ∈ { "open", "scheduled", "running" }
  #   last_status ∈ { "ok", "error", "never" }
  #   last_run_at  ISO-8601 or null
  #   next_run_at  ISO-8601 or null (only for state="scheduled")
  #   active_instances  integer count of pending/running instances
  #
  # State derivation rules:
  #   running   — at least one instance in pending/running state
  #   scheduled — has an enabled Sop::Schedule row (regardless of active instances)
  #   open      — neither of the above
  #
  # SPEC v0.7 §9.3 — last_status vs last_run_at semantics:
  #   last_status  derived from the most recent run whose state is completed
  #                (→ ok) or failed (→ error); cancelled/interrupted runs are
  #                skipped entirely. If no completed/failed run exists → "never".
  #   last_run_at  most recent started_at across ALL runs regardless of outcome;
  #                a cancelled run CAN be the most recent last_run_at.
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
      :state,           # "open" | "scheduled" | "running"
      :last_status,     # "ok" | "error" | "never"
      :last_run_at,     # Time or nil
      :next_run_at,     # Time or nil (non-null only when state="scheduled")
      :active_instances,
      :cron_expression,
      :schedule_enabled,
      :schedule_id,     # UUID of the schedule row, or nil — included in API
                        # response for consumers that need to address a schedule
      keyword_init: true
    )

    def self.call
      new.call
    end

    def call
      processes = safe_load_processes
      return Result.new(processes: []) if processes.empty?

      process_names = processes.map(&:name)
      schedules_by_process  = safe_load_schedules_by_process
      in_flight_by_process  = safe_load_in_flight_by_process
      last_status_by_process = safe_load_last_status_by_process(process_names)
      last_run_at_by_process = safe_load_last_run_at_by_process(process_names)

      statuses = processes.map do |process|
        schedule      = schedules_by_process[process.name]
        in_flight     = in_flight_by_process[process.name].to_i
        last_instance = last_status_by_process[process.name]

        state       = derive_status(in_flight, schedule)
        last_status = derive_last_status(last_instance)

        ProcessStatus.new(
          name: process.name,
          version: process.version,
          description: process.description,
          state: state,
          last_status: last_status,
          last_run_at: last_run_at_by_process[process.name],
          next_run_at: schedule&.enabled? ? schedule.next_run_at : nil,
          active_instances: in_flight,
          cron_expression: schedule&.cron_expression,
          schedule_enabled: schedule&.enabled?,
          schedule_id: schedule&.id
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

    # "ok" if the most recent completed/failed run completed; "error" if it
    # failed. "never" if no completed/failed run exists (cancelled/interrupted
    # runs are skipped per SPEC v0.7 §9.3).
    def derive_last_status(last_instance)
      return "never" if last_instance.nil?

      case last_instance[:state]
      when "completed" then "ok"
      when "failed"    then "error"
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

    # Returns a Hash { process_name => {state:, started_at:} } for the most
    # recent completed/failed instance per process, bounded to the given set of
    # process_names. cancelled/interrupted runs are excluded per SPEC v0.7 §9.3.
    #
    # Bounded lookup: for each known process_name we issue a per-name subquery
    # (ORDER BY started_at DESC LIMIT 1). This is O(|process_names|) index
    # probes rather than a full scan of the terminal-history table, so work
    # does NOT grow with total historical rows for processes not being queried.
    # The index index_sop_instances_status_by_process_started covers
    # (process_name, started_at DESC) WHERE state IN ('completed','failed').
    def safe_load_last_status_by_process(process_names)
      return {} if process_names.empty?

      result = {}
      process_names.each do |name|
        row = Sop::Instance
          .where(process_name: name, state: %w[completed failed])
          .order(started_at: :desc)
          .select(:process_name, :state, :started_at)
          .first
        result[name] = { state: row.state, started_at: row.started_at } if row
      end
      result
    rescue ActiveRecord::StatementInvalid
      {}
    end

    # Returns a Hash { process_name => started_at } for the most recent run
    # across ALL states (including cancelled/interrupted) per SPEC v0.7 §9.3.
    # Uses the existing index_sop_instances_on_started_at and a per-name
    # bounded lookup.
    def safe_load_last_run_at_by_process(process_names)
      return {} if process_names.empty?

      result = {}
      process_names.each do |name|
        row = Sop::Instance
          .where(process_name: name)
          .where.not(started_at: nil)
          .order(started_at: :desc)
          .select(:process_name, :started_at)
          .first
        result[name] = row.started_at if row
      end
      result
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
