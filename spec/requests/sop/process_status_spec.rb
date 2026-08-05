require "rails_helper"

RSpec.describe "Sop::ProcessStatus", type: :request do
  # Reset the class-var warning flag so auth tests don't share state.
  before { Sop::ApplicationController.class_variable_set(:@@unauth_warned, false) }

  around do |ex|
    original = ENV["OPENSOP_API_TOKEN"]
    ex.run
  ensure
    if original.nil?
      ENV.delete("OPENSOP_API_TOKEN")
    else
      ENV["OPENSOP_API_TOKEN"] = original
    end
  end

  before { ENV.delete("OPENSOP_API_TOKEN") }

  describe "GET /sop/processes/status" do
    context "with no processes" do
      it "returns 200 with an empty processes array" do
        get "/sop/processes/status"

        expect(response).to have_http_status(:ok)
        expect(json).to include(:processes)
        expect(json[:processes]).to eq([])
      end
    end

    context "with an open process (no instances, no schedule)" do
      let!(:process) { create(:sop_process, name: "invoice-review", version: "1.0") }

      it "returns 200 and the correct status shape" do
        get "/sop/processes/status"

        expect(response).to have_http_status(:ok)
        expect(json[:processes].size).to eq(1)

        entry = json[:processes].first
        expect(entry[:name]).to eq("invoice-review")
        expect(entry[:version]).to eq("1.0")
        expect(entry[:status]).to eq("open")
        expect(entry[:last_status]).to eq("never")
        expect(entry[:last_run_at]).to be_nil
        expect(entry[:next_run_at]).to be_nil
        expect(entry[:active_instances]).to eq(0)
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

      it "returns status=scheduled and a next_run_at timestamp" do
        get "/sop/processes/status"

        entry = json[:processes].first
        expect(entry[:status]).to eq("scheduled")
        expect(entry[:next_run_at]).to be_present
        # ISO-8601 string expected
        expect { Time.iso8601(entry[:next_run_at]) }.not_to raise_error
      end
    end

    context "with a running process" do
      let!(:process) { create(:sop_process, name: "onboarding", version: "1.0") }

      before do
        create(:sop_instance, :running,
               process: process, process_name: "onboarding", process_version: "1.0")
        create(:sop_instance, :running,
               process: process, process_name: "onboarding", process_version: "1.0")
      end

      it "returns status=running and active_instances=2" do
        get "/sop/processes/status"

        entry = json[:processes].first
        expect(entry[:status]).to eq("running")
        expect(entry[:active_instances]).to eq(2)
      end
    end

    context "with a process that last ran with an error" do
      let!(:process) { create(:sop_process, name: "worker", version: "1.0") }

      before do
        create(:sop_instance, :failed,
               process: process, process_name: "worker", process_version: "1.0")
      end

      it "returns last_status=error" do
        get "/sop/processes/status"

        entry = json[:processes].first
        expect(entry[:last_status]).to eq("error")
        expect(entry[:last_run_at]).to be_present
      end
    end

    context "with a process that last ran successfully" do
      let!(:process) { create(:sop_process, name: "worker", version: "1.0") }

      before do
        create(:sop_instance, :completed,
               process: process, process_name: "worker", process_version: "1.0")
      end

      it "returns last_status=ok and a last_run_at timestamp" do
        get "/sop/processes/status"

        entry = json[:processes].first
        expect(entry[:last_status]).to eq("ok")
        expect(entry[:last_run_at]).to be_present
      end
    end

    context "with multiple processes" do
      before do
        create(:sop_process, name: "alpha", version: "1.0")
        create(:sop_process, name: "beta",  version: "2.0")
      end

      it "returns all processes sorted alphabetically by name" do
        get "/sop/processes/status"

        names = json[:processes].map { |p| p[:name] }
        expect(names).to eq(%w[alpha beta])
      end
    end

    context "auth gate" do
      it "returns 401 when OPENSOP_API_TOKEN is set and no header is provided" do
        ENV["OPENSOP_API_TOKEN"] = "secret-status"

        get "/sop/processes/status"

        expect(response).to have_http_status(:unauthorized)
        expect(json[:error]).to eq("unauthorized")
      end

      it "returns 200 when the correct token header is provided" do
        ENV["OPENSOP_API_TOKEN"] = "secret-status"

        get "/sop/processes/status", headers: { "X-SOP-Token" => "secret-status" }

        expect(response).to have_http_status(:ok)
      end

      it "returns 401 when the token does not match" do
        ENV["OPENSOP_API_TOKEN"] = "secret-status"

        get "/sop/processes/status", headers: { "X-SOP-Token" => "wrong" }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
