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
#
# Robustness: if a previous CREATE INDEX CONCURRENTLY was interrupted,
# Postgres leaves a same-named index in an INVALID state. if_not_exists
# would silently skip it, leaving the endpoint with a broken index.
# index_invalid? detects that case and drops it first so the build can
# proceed cleanly on retry.
class AddObservabilityIndexesToSopInstances < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_SPECS = [
    {
      name: "index_sop_instances_status_by_process_started",
      columns: [ :process_name, :started_at ],
      where: "state IN ('completed', 'failed')"
    },
    {
      name: "index_sop_instances_last_run_at_by_process",
      columns: [ :process_name, :started_at ],
      where: "started_at IS NOT NULL"
    }
  ].freeze

  def up
    INDEX_SPECS.each do |spec|
      # Drop a leftover INVALID index of this name (from an interrupted
      # concurrent build). if_not_exists would silently keep it, leaving
      # the endpoint with a non-functional index.
      if index_invalid?(spec[:name])
        execute "DROP INDEX CONCURRENTLY IF EXISTS #{spec[:name]}"
      end

      add_index :sop_instances,
                spec[:columns],
                name: spec[:name],
                where: spec[:where],
                order: { started_at: :desc },
                algorithm: :concurrently,
                if_not_exists: true
    end
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

  private

  # Returns true when an index named +name+ exists in the catalog but is
  # marked invalid — the fingerprint left by an interrupted concurrent build.
  def index_invalid?(name)
    select_value(<<~SQL).present?
      SELECT 1
      FROM   pg_class c
      JOIN   pg_index i ON i.indexrelid = c.oid
      WHERE  c.relname = '#{name}'
      AND    i.indisvalid = false
    SQL
  end
end
