# frozen_string_literal: true

# Supports the DISTINCT ON (process_name) ORDER BY process_name, updated_at DESC
# query in Opensop::ProcessStatusRollup#safe_load_last_instance_by_process.
# Without this index Postgres falls back to a sequential scan over all terminal
# instances — every 30 s on the observability page.
class AddTerminalLookupIndexToSopInstances < ActiveRecord::Migration[8.1]
  def change
    add_index :sop_instances,
              [ :process_name, :updated_at ],
              where: "state IN ('completed', 'failed', 'cancelled')",
              name: "index_sop_instances_terminal_by_process_updated",
              order: { updated_at: :desc }
  end
end
