# frozen_string_literal: true

# Backs the per-process last_run_at probe in
# Opensop::ProcessStatusRollup#safe_load_last_run_at_by_process.
#
# The query is:
#   WHERE process_name = ? AND started_at IS NOT NULL
#   ORDER BY started_at DESC LIMIT 1
#
# Without this index Postgres falls back to the global single-column
# index_sop_instances_on_started_at, which cannot constrain by process_name
# and forces a per-process sort of the full history.
#
# With this index the planner performs a bounded index scan: it seeks to the
# (process_name, started_at DESC) boundary and reads exactly one row —
# O(1) probes regardless of total historical row count.
#
# The WHERE started_at IS NOT NULL partial predicate matches the query's
# .where.not(started_at: nil) filter, keeps the index smaller, and lets
# Postgres prove the IS NOT NULL constraint is satisfied at scan time.
class AddLastRunAtLookupIndexToSopInstances < ActiveRecord::Migration[8.1]
  def change
    add_index :sop_instances,
              [ :process_name, :started_at ],
              where: "started_at IS NOT NULL",
              name: "index_sop_instances_last_run_at_by_process",
              order: { started_at: :desc }
  end
end
