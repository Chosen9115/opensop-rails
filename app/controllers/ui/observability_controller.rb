module Ui
  # GET /observability — Observability Terminal view.
  #
  # A live-refresh table of every registered process showing:
  #   Process · Schedule · Last run · Next run · Status · Active instances
  #
  # Also provides run-now (POST /observability/:name/run) and enable/disable
  # schedule toggles (PATCH /observability/:name/schedule/toggle) for
  # scheduled processes.
  #
  # Auto-refreshes via <meta http-equiv="refresh"> every 30 seconds —
  # keeps it simple, zero new JS deps, Hotwire-compatible.
  #
  # Gracefully degrades when any underlying table is not yet migrated,
  # matching the posture of Ui::SchedulesController.
  class ObservabilityController < ApplicationController
    REFRESH_SECONDS = 30

    def index
      rollup = Opensop::ProcessStatusRollup.call
      @process_statuses = rollup.processes
      @table_unavailable = false
      @refresh_seconds = REFRESH_SECONDS
      @totals = compute_totals(@process_statuses)
    rescue ActiveRecord::StatementInvalid
      @process_statuses = []
      @table_unavailable = true
      @totals = { running: 0, scheduled: 0, open: 0, errors_24h: 0 }
    end

    # POST /observability/:name/run
    # Triggers a run-now for the named process (same logic as
    # Ui::ProcessesController#start_run).
    def run_now
      process = find_latest_process!(params[:name])
      instance = Opensop::InstanceExecutor.start(
        process: process,
        inputs: {},
        metadata: { actor: "ui", source: "observability_terminal" }
      )
      redirect_to ui_instance_path(instance),
                  notice: t("opensop.flash.run_started")
    rescue ActiveRecord::RecordNotFound
      redirect_to ui_observability_path,
                  alert: t("opensop.flash.process_not_found")
    rescue Opensop::InstanceExecutor::InvalidInputs => e
      redirect_to ui_observability_path,
                  alert: t("opensop.errors.invalid_inputs", message: e.message)
    end

    # PATCH /observability/:name/schedule/toggle
    # Enables or disables the schedule for the named process.
    def toggle_schedule
      schedule = Sop::Schedule.find_by!(process_name: params[:name])
      schedule.update!(enabled: !schedule.enabled?)
      flash_key = schedule.enabled? ? "opensop.observability.schedule_enabled" : "opensop.observability.schedule_disabled"
      redirect_to ui_observability_path, notice: t(flash_key, default: "Schedule updated.")
    rescue ActiveRecord::RecordNotFound
      redirect_to ui_observability_path,
                  alert: t("opensop.observability.schedule_not_found", default: "No schedule found for that process.")
    end

    private

    def find_latest_process!(name)
      scope = Sop::Process.published.where(name: name)
      process = scope.to_a.max_by { |p| version_key(p.version) }
      raise ActiveRecord::RecordNotFound, "process #{name.inspect} not found" unless process
      process
    end

    def version_key(version)
      Gem::Version.new(version.to_s)
    rescue ArgumentError
      Gem::Version.new("0")
    end

    def compute_totals(statuses)
      {
        running:      statuses.count { |s| s.status == "running" },
        scheduled:    statuses.count { |s| s.status == "scheduled" },
        open:         statuses.count { |s| s.status == "open" },
        errors_24h:   statuses.count { |s| s.last_status == "error" &&
                                           s.last_run_at.present? &&
                                           s.last_run_at >= 24.hours.ago }
      }
    end
  end
end
