require "rails_helper"

# Request spec for the Observability Terminal admin page.
#
# Covers:
#   * page renders with hero tiles when processes exist
#   * correct status rollup for open / scheduled / running / errored cases
#   * run-now action redirects to the new instance
#   * schedule toggle flips enabled state
#   * graceful degradation when underlying tables are unavailable
RSpec.describe "Ui::Observability", type: :request do
  before do
    sign_in_via_magic_link(create(:user))
  end

  describe "GET /observability" do
    context "with no processes" do
      it "responds 200 and renders the page title" do
        get "/observability"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Observability")
      end

      it "renders the empty state when there are no processes" do
        get "/observability"

        expect(response.body).to include("No processes registered")
      end

      it "renders zero-valued hero tiles" do
        get "/observability"

        expect(response.body).to include("Running now")
        expect(response.body).to include("Scheduled")
        expect(response.body).to include("Open")
        expect(response.body).to include("Errors (24h)")
      end

      it "includes a meta refresh tag" do
        get "/observability"

        expect(response.body).to match(/http-equiv="refresh"/)
      end
    end

    context "with an open process" do
      let!(:process) { create(:sop_process, name: "invoice-review", version: "1.0") }

      it "renders the process name" do
        get "/observability"

        expect(response.body).to include("invoice-review")
      end

      it "renders the open status pill" do
        get "/observability"

        expect(response.body).to include("open")
      end

      it "renders the never last_status pill" do
        get "/observability"

        expect(response.body).to include("never")
      end

      it "renders the Run now button" do
        get "/observability"

        expect(response.body).to include("Run now")
      end
    end

    context "with a scheduled process" do
      let!(:process) { create(:sop_process, name: "daily-report", version: "1.0") }
      let!(:schedule) do
        create(:sop_schedule,
               process_name: "daily-report",
               cron_expression: "0 9 * * 1-5",
               enabled: true,
               next_run_at: 2.hours.from_now)
      end

      it "renders the cron expression" do
        get "/observability"

        expect(response.body).to include("0 9 * * 1-5")
      end

      it "renders the scheduled status pill" do
        get "/observability"

        expect(response.body).to include("scheduled")
      end

      it "renders the Enable/Disable toggle button" do
        get "/observability"

        # Enabled schedule shows Disable button.
        expect(response.body).to include("Disable")
      end
    end

    context "with a running process" do
      let!(:process) { create(:sop_process, name: "onboarding", version: "1.0") }

      before do
        create(:sop_instance, :running,
               process: process, process_name: "onboarding", process_version: "1.0")
      end

      it "renders the running status pill" do
        get "/observability"

        expect(response.body).to include("running")
      end
    end

    context "with an errored process" do
      let!(:process) { create(:sop_process, name: "worker", version: "1.0") }

      before do
        create(:sop_instance, :failed,
               process: process, process_name: "worker", process_version: "1.0")
      end

      it "renders the error last_status pill" do
        get "/observability"

        expect(response.body).to include("error")
      end
    end

    context "with hero tile counts" do
      before do
        # open process
        create(:sop_process, name: "alpha", version: "1.0")

        # scheduled process
        beta = create(:sop_process, name: "beta", version: "1.0")
        create(:sop_schedule, process_name: "beta", enabled: true, next_run_at: 1.hour.from_now)

        # running process
        gamma = create(:sop_process, name: "gamma", version: "1.0")
        create(:sop_instance, :running,
               process: gamma, process_name: "gamma", process_version: "1.0")
      end

      it "renders 1 running process tile" do
        get "/observability"

        expect(response.body).to match(/Running now.*?text-\[28px\][^>]*>\s*1\s*</m)
      end

      it "renders 1 scheduled process tile" do
        get "/observability"

        expect(response.body).to match(/Scheduled.*?text-\[28px\][^>]*>\s*1\s*</m)
      end
    end

    context "when tables are unavailable" do
      it "renders the unavailable empty state without erroring" do
        allow(Opensop::ProcessStatusRollup).to receive(:call)
          .and_raise(ActiveRecord::StatementInvalid.new("relation does not exist"))

        get "/observability"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Observability unavailable")
      end
    end
  end

  describe "POST /observability/:name/run" do
    let!(:process) { create(:sop_process, name: "invoice-review", version: "1.0") }

    it "starts an instance and redirects to the instance page" do
      post "/observability/invoice-review/run"

      expect(response).to have_http_status(:found)
      follow_redirect!
      expect(response.body).to include("invoice-review")
    end

    it "redirects back to observability if the process is not found" do
      post "/observability/no-such-process/run"

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/observability")
    end
  end

  describe "PATCH /observability/:name/schedule/:schedule_id/toggle" do
    let!(:process) { create(:sop_process, name: "daily-report", version: "1.0") }
    let!(:schedule) do
      create(:sop_schedule,
             process_name: "daily-report",
             cron_expression: "0 9 * * 1-5",
             enabled: true,
             next_run_at: 2.hours.from_now)
    end

    it "disables an enabled schedule and redirects to observability" do
      expect {
        patch "/observability/daily-report/schedule/#{schedule.id}/toggle"
      }.to change { schedule.reload.enabled? }.from(true).to(false)

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/observability")
    end

    it "enables a disabled schedule" do
      schedule.update!(enabled: false)

      expect {
        patch "/observability/daily-report/schedule/#{schedule.id}/toggle"
      }.to change { schedule.reload.enabled? }.from(false).to(true)
    end

    it "redirects back with an error message when no schedule exists" do
      bogus_id = SecureRandom.uuid
      patch "/observability/no-schedule/schedule/#{bogus_id}/toggle"

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/observability")
    end

    context "with a dotted process name (fix #2 regression guard)" do
      let!(:dotted_process) { create(:sop_process, name: "finance.invoice", version: "1.0") }
      let!(:dotted_schedule) do
        create(:sop_schedule,
               process_name: "finance.invoice",
               cron_expression: "0 6 * * *",
               enabled: true,
               next_run_at: 1.hour.from_now)
      end

      it "routes and toggles a dotted process name" do
        expect {
          patch "/observability/finance.invoice/schedule/#{dotted_schedule.id}/toggle"
        }.to change { dotted_schedule.reload.enabled? }.from(true).to(false)

        expect(response).to have_http_status(:found)
        expect(response.location).to include("/observability")
      end

      it "run-now route accepts a dotted process name" do
        post "/observability/finance.invoice/run"

        # The process has no inputs required, so it should start and redirect to
        # the new instance page (or back to observability if the process isn't
        # fully configured) — either way, not a 404.
        expect(response).not_to have_http_status(:not_found)
      end
    end

    context "with multiple schedules on one process (fix #4 — toggle targets the right one)" do
      let!(:schedule_a) do
        create(:sop_schedule,
               process_name: "daily-report",
               cron_expression: "0 8 * * *",
               enabled: true,
               next_run_at: 2.hours.from_now)
      end
      let!(:schedule_b) do
        create(:sop_schedule,
               process_name: "daily-report",
               cron_expression: "0 20 * * *",
               enabled: true,
               next_run_at: 3.hours.from_now)
      end

      it "toggles only the targeted schedule, leaving the other untouched" do
        patch "/observability/daily-report/schedule/#{schedule_a.id}/toggle"

        expect(schedule_a.reload.enabled?).to be false
        expect(schedule_b.reload.enabled?).to be true
      end

      it "can independently toggle the second schedule without touching the first" do
        schedule_a.update!(enabled: false)

        patch "/observability/daily-report/schedule/#{schedule_b.id}/toggle"

        expect(schedule_b.reload.enabled?).to be false
        expect(schedule_a.reload.enabled?).to be false # was already false — untouched
      end
    end
  end
end
