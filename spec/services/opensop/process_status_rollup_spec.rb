require "rails_helper"

RSpec.describe Opensop::ProcessStatusRollup do
  subject(:result) { described_class.call }

  describe "#call" do
    context "with no processes" do
      it "returns an empty processes array" do
        expect(result.processes).to eq([])
      end
    end

    context "with a single open process (no instances, no schedule)" do
      let!(:process) { create(:sop_process, name: "invoice-review", version: "1.0") }

      it "returns one entry with status=open" do
        expect(result.processes.size).to eq(1)
        ps = result.processes.first
        expect(ps.name).to eq("invoice-review")
        expect(ps.version).to eq("1.0")
        expect(ps.status).to eq("open")
      end

      it "returns last_status=never when no instances have completed" do
        ps = result.processes.first
        expect(ps.last_status).to eq("never")
      end

      it "returns nil for last_run_at and next_run_at" do
        ps = result.processes.first
        expect(ps.last_run_at).to be_nil
        expect(ps.next_run_at).to be_nil
      end

      it "returns active_instances=0" do
        ps = result.processes.first
        expect(ps.active_instances).to eq(0)
      end
    end

    context "with a scheduled process (enabled schedule, no running instances)" do
      let!(:process) { create(:sop_process, name: "daily-report", version: "2.0") }
      let!(:schedule) do
        create(:sop_schedule,
               process_name: "daily-report",
               cron_expression: "0 9 * * 1-5",
               enabled: true,
               next_run_at: 2.hours.from_now)
      end

      it "returns status=scheduled" do
        ps = result.processes.first
        expect(ps.status).to eq("scheduled")
      end

      it "returns the schedule's next_run_at" do
        ps = result.processes.first
        expect(ps.next_run_at).to be_within(2.seconds).of(schedule.next_run_at)
      end

      it "exposes the cron_expression" do
        ps = result.processes.first
        expect(ps.cron_expression).to eq("0 9 * * 1-5")
      end

      it "marks schedule_enabled=true" do
        ps = result.processes.first
        expect(ps.schedule_enabled).to be true
      end
    end

    context "with a scheduled process where the schedule is disabled" do
      let!(:process) { create(:sop_process, name: "quarterly-close", version: "1.0") }
      let!(:schedule) do
        create(:sop_schedule,
               process_name: "quarterly-close",
               cron_expression: "0 0 1 1,4,7,10 *",
               enabled: false,
               next_run_at: 30.days.from_now)
      end

      it "returns status=open (disabled schedule does not promote to scheduled)" do
        ps = result.processes.first
        expect(ps.status).to eq("open")
      end

      it "marks schedule_enabled=false" do
        ps = result.processes.first
        expect(ps.schedule_enabled).to be false
      end
    end

    context "with a running process (active instances)" do
      let!(:process) { create(:sop_process, name: "onboarding", version: "1.0") }

      before do
        create(:sop_instance, :running, process: process, process_name: "onboarding", process_version: "1.0")
      end

      it "returns status=running" do
        ps = result.processes.first
        expect(ps.status).to eq("running")
      end

      it "returns active_instances=1" do
        ps = result.processes.first
        expect(ps.active_instances).to eq(1)
      end
    end

    context "with a running process that also has a schedule" do
      let!(:process) { create(:sop_process, name: "sync", version: "1.0") }
      let!(:schedule) do
        create(:sop_schedule,
               process_name: "sync",
               enabled: true,
               next_run_at: 1.hour.from_now)
      end

      before do
        create(:sop_instance, :running, process: process, process_name: "sync", process_version: "1.0")
      end

      it "returns status=running (running takes precedence over scheduled)" do
        ps = result.processes.first
        expect(ps.status).to eq("running")
      end
    end

    context "last_status derivation" do
      let!(:process) { create(:sop_process, name: "worker", version: "1.0") }

      context "when last terminal instance completed successfully" do
        before do
          create(:sop_instance, :completed, process: process, process_name: "worker", process_version: "1.0",
                 updated_at: 1.hour.ago)
        end

        it "returns last_status=ok" do
          ps = result.processes.first
          expect(ps.last_status).to eq("ok")
        end
      end

      context "when last terminal instance failed" do
        before do
          create(:sop_instance, :failed, process: process, process_name: "worker", process_version: "1.0",
                 updated_at: 30.minutes.ago)
        end

        it "returns last_status=error" do
          ps = result.processes.first
          expect(ps.last_status).to eq("error")
        end
      end

      context "when there are both completed and failed instances" do
        before do
          # Failed more recently than completed.
          create(:sop_instance, :completed, process: process, process_name: "worker", process_version: "1.0",
                 updated_at: 2.hours.ago)
          create(:sop_instance, :failed, process: process, process_name: "worker", process_version: "1.0",
                 updated_at: 30.minutes.ago)
        end

        it "reports the most recent terminal state (error)" do
          ps = result.processes.first
          expect(ps.last_status).to eq("error")
        end
      end
    end

    context "with multiple processes" do
      before do
        create(:sop_process, name: "alpha", version: "1.0")
        create(:sop_process, name: "beta",  version: "1.0")
        create(:sop_schedule, process_name: "beta", enabled: true, next_run_at: 1.hour.from_now)
      end

      it "returns all processes sorted by name" do
        names = result.processes.map(&:name)
        expect(names).to eq(%w[alpha beta])
      end

      it "correctly identifies each process status" do
        alpha_ps = result.processes.find { |p| p.name == "alpha" }
        beta_ps  = result.processes.find { |p| p.name == "beta" }

        expect(alpha_ps.status).to eq("open")
        expect(beta_ps.status).to eq("scheduled")
      end
    end

    context "with multiple versions of the same process" do
      before do
        create(:sop_process, name: "multi-ver", version: "1.0")
        create(:sop_process, name: "multi-ver", version: "2.0")
      end

      it "surfaces only the latest version" do
        expect(result.processes.size).to eq(1)
        expect(result.processes.first.version).to eq("2.0")
      end
    end

    context "when the sop_instances table is unavailable" do
      let!(:process) { create(:sop_process, name: "resilience-check", version: "1.0") }

      before do
        allow(Sop::Instance).to receive(:where).and_raise(ActiveRecord::StatementInvalid.new("table not found"))
      end

      it "still returns the process with safe defaults" do
        ps = result.processes.first
        expect(ps.name).to eq("resilience-check")
        expect(ps.status).to eq("open")
        expect(ps.active_instances).to eq(0)
        expect(ps.last_status).to eq("never")
      end
    end

    context "when the sop_processes table is unavailable" do
      before do
        allow(Sop::Process).to receive(:published).and_raise(ActiveRecord::StatementInvalid.new("table not found"))
      end

      it "returns an empty result without raising" do
        expect(result.processes).to eq([])
      end
    end
  end
end
