# frozen_string_literal: true

# Two partial composite indexes backing the per-process O(1) probes in
# Opensop::ProcessStatusRollup:
#
#   1. last_status (completed/failed only, per SPEC §9.3):
#      Supports the bounded per-process lateral lookup in
#      #safe_load_last_status_by_process. Predicate excludes cancelled/
#      interrupted — those states do not contribute to last_status.
#
#   2. last_run_at (any run with a start timestamp):
#      Backs #safe_load_last_run_at_by_process. The IS NOT NULL predicate
#      matches the query filter and lets Postgres prove the constraint at
#      scan time, keeping the index smaller.
#
# Both indexes are created CONCURRENTLY so that deploys against a live
# sop_instances table do not take a SHARE lock that would block process
# starts, state transitions, or cancellations during the build.
# disable_ddl_transaction! is required: CREATE INDEX CONCURRENTLY cannot
# run inside a transaction.
class AddObservabilityIndexesToSopInstances < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :sop_instances,
              [ :process_name, :started_at ],
              where: "state IN ('completed', 'failed')",
              name: "index_sop_instances_status_by_process_started",
              order: { started_at: :desc },
              algorithm: :concurrently,
              if_not_exists: true

    add_index :sop_instances,
              [ :process_name, :started_at ],
              where: "started_at IS NOT NULL",
              name: "index_sop_instances_last_run_at_by_process",
              order: { started_at: :desc },
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :sop_instances,
                 name: "index_sop_instances_status_by_process_started",
                 algorithm: :concurrently,
                 if_exists: true

    remove_index :sop_instances,
                 name: "index_sop_instances_last_run_at_by_process",
                 algorithm: :concurrently,
                 if_exists: true
  end
end
