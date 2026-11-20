package collect

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// The replication collection's slot reads (the HA build's item 11, task 374; migration 0141): every slot with the WAL it
// retains, its wal_status and safe_wal_size against max_slot_wal_keep_size, why it was invalidated (PostgreSQL 17 on:
// wal_removed, rows_removed, wal_level_insufficient, idle_timeout), and a logical slot's decoding statistics
// (pg_stat_replication_slots, PostgreSQL 14 on: the transactions and bytes spilled to disk or streamed to the
// subscriber past logical_decoding_work_mem). A DMS or Debezium consumer is a slot.

// slots: wal_status and safe_wal_size exist from PG13; two_phase 14, conflicting 16, synced, inactive_since and
// invalidation_reason 17. max_slot_wal_keep_size is -1 (no limit: safe_wal_size NULL) or its size in bytes.
const slotsSQL = `
SELECT 'slot' AS kind, s.slot_name, s.plugin, s.slot_type, s.database::text AS datname, s.temporary, s.active, s.active_pid,
       s.xmin::text AS xmin, s.catalog_xmin::text AS catalog_xmin,
       s.restart_lsn::text, s.confirmed_flush_lsn::text, s.wal_status, s.safe_wal_size,
       CASE WHEN pg_is_in_recovery() THEN pg_wal_lsn_diff(pg_last_wal_replay_lsn(), s.restart_lsn)
            ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) END AS retained_bytes,
       CASE WHEN current_setting('max_slot_wal_keep_size') = '-1' THEN NULL
            ELSE pg_size_bytes(current_setting('max_slot_wal_keep_size')) END AS max_keep_bytes,
       %s AS two_phase, %s AS conflicting, %s AS inactive_since, %s AS synced, %s AS invalidation_reason
  FROM pg_replication_slots s`

// a logical slot's decoding statistics: cumulative since stats_reset
const slotStatsSQL = `
SELECT 'slot_stats' AS kind, st.slot_name::text AS slot_name, st.spill_txns, st.spill_count, st.spill_bytes,
       st.stream_txns, st.stream_count, st.stream_bytes, st.total_txns, st.total_bytes, st.stats_reset
  FROM pg_stat_replication_slots st`

type slotQuery struct {
	label, sql string
	err        error
}

// slotQueries are the slot reads this server takes, each a query or the error that kept it from being built.
func slotQueries(ctx context.Context, conn *pgx.Conn, info platform.Info) []slotQuery {
	cols, err := viewColumns(ctx, conn, "pg_catalog.pg_replication_slots")
	if err != nil {
		return []slotQuery{{label: "slots", err: err}}
	}
	out := []slotQuery{{label: "slots", sql: fmt.Sprintf(slotsSQL, col(cols, "s", "two_phase", "boolean"), col(cols, "s", "conflicting", "boolean"),
		col(cols, "s", "inactive_since", "timestamptz"), col(cols, "s", "synced", "boolean"), col(cols, "s", "invalidation_reason", "text"))}}
	if info.ServerVersionNum >= 140000 {
		out = append(out, slotQuery{label: "slot_stats", sql: slotStatsSQL})
	}
	return out
}
