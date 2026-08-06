# frozen_string_literal: true

# SPEC v0.7 §9.3: last_status is derived ONLY from completed/failed runs.
# cancelled/interrupted runs are skipped for last_status but DO count for
# last_run_at (which uses the existing started_at index directly).
#
# This migration:
#   1. Drops the old terminal index that included cancelled in its predicate
#      (index_sop_instances_terminal_by_process_updated).
#   2. Adds a status-qualifying index on (process_name, started_at DESC)
#      restricted to completed/failed — supports the bounded per-process
#      lateral lookup in ProcessStatusRollup#safe_load_last_status_by_process.
class FixTerminalLookupIndexExcludeCancelled < ActiveRecord::Migration[8.1]
  def change
    remove_index :sop_instances,
                 name: "index_sop_instances_terminal_by_process_updated",
                 if_exists: true

    add_index :sop_instances,
              [ :process_name, :started_at ],
              where: "state IN ('completed', 'failed')",
              name: "index_sop_instances_status_by_process_started",
              order: { started_at: :desc }
  end
end
