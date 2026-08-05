module Sop
  # GET /sop/processes/status
  #
  # Returns a per-process status rollup conforming to SPEC v0.7 §9.4.
  # Auth is inherited from Sop::ApplicationController (X-SOP-Token header).
  #
  # Response shape:
  #   {
  #     processes: [
  #       {
  #         name:              "customer-onboarding",
  #         version:           "1.0",
  #         state:             "open" | "scheduled" | "running",
  #         last_status:       "ok" | "error" | "never",
  #         last_run_at:       "2026-08-01T12:00:00Z" | null,
  #         next_run_at:       "2026-08-02T09:00:00Z" | null,
  #         active_instances:  2
  #       },
  #       ...
  #     ]
  #   }
  class ProcessStatusController < ApplicationController
    def index
      rollup = Opensop::ProcessStatusRollup.call

      processes = rollup.processes.map do |ps|
        {
          name:             ps.name,
          version:          ps.version,
          state:            ps.state,
          last_status:      ps.last_status,
          last_run_at:      ps.last_run_at&.iso8601,
          next_run_at:      ps.next_run_at&.iso8601,
          active_instances: ps.active_instances
        }
      end

      render json: { processes: processes }
    end
  end
end
