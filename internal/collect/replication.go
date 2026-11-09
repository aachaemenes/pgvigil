package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// replicationCollector is the HADR page: streaming senders (pg_stat_replication),
// the receiver on a standby (pg_stat_wal_receiver, replay timestamp), replication
// slots with the WAL they retain (a DMS or Debezium consumer is a slot), logical
// subscriptions and publications, recovery conflicts per database, and on Aurora
// the replica status function. Every minute; rows are stored as read, each with a
// kind, and the repository keeps a current view plus a history.
type replicationCollector struct{}

func init() { Register(replicationCollector{}) }

func (replicationCollector) Name() string                   { return "replication" }
func (replicationCollector) DefaultInterval() time.Duration { return time.Minute }
func (replicationCollector) Applies(info platform.Info) (bool, string) {
	if info.ServerVersionNum < 130000 {
		return false, "needs PostgreSQL 13 or later"
	}
	return true, ""
}

const sendersSQL = `
SELECT 'sender' AS kind, r.pid, r.usename::text AS usename, r.application_name, host(r.client_addr) AS client_addr,
       r.backend_start, r.state, r.sync_state, r.sync_priority,
       r.sent_lsn::text, r.write_lsn::text, r.flush_lsn::text, r.replay_lsn::text,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.sent_lsn)   AS sent_lag_bytes,
       pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn) AS replay_lag_bytes,
       extract(epoch FROM r.write_lag)  AS write_lag_secs,
       extract(epoch FROM r.flush_lag)  AS flush_lag_secs,
       extract(epoch FROM r.replay_lag) AS replay_lag_secs,
       r.reply_time
  FROM pg_stat_replication r`

// the standby side: one row when this server is in recovery
const receiverSQL = `
SELECT 'receiver' AS kind, w.pid, w.status, w.sender_host, w.sender_port, w.slot_name,
       w.received_lsn::text, w.latest_end_lsn::text, w.latest_end_time, w.last_msg_receipt_time,
       pg_last_wal_replay_lsn()::text AS replay_lsn,
       extract(epoch FROM clock_timestamp() - pg_last_xact_replay_timestamp()) AS replay_delay_secs,
       pg_is_wal_replay_paused() AS replay_paused,
       regexp_replace(w.conninfo, '(password|passfile|sslkey|sslpassword)=\S+', '\1=<masked>', 'gi') AS conninfo
  FROM pg_stat_wal_receiver w`

// slots: wal_status and safe_wal_size exist from PG13
const slotsSQL = `
SELECT 'slot' AS kind, s.slot_name, s.plugin, s.slot_type, s.database::text AS datname, s.temporary, s.active, s.active_pid,
       s.xmin::text AS xmin, s.catalog_xmin::text AS catalog_xmin,
       s.restart_lsn::text, s.confirmed_flush_lsn::text, s.wal_status, s.safe_wal_size,
       CASE WHEN pg_is_in_recovery() THEN pg_wal_lsn_diff(pg_last_wal_replay_lsn(), s.restart_lsn)
            ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) END AS retained_bytes,
       %s AS two_phase, %s AS conflicting, %s AS inactive_since
  FROM pg_replication_slots s`

const subscriptionsSQL = `
SELECT 'subscription' AS kind, s.subid::bigint AS subid, s.subname::text AS subname, s.pid, s.received_lsn::text,
       s.last_msg_send_time, s.last_msg_receipt_time, s.latest_end_lsn::text, s.latest_end_time,
       sub.subenabled AS enabled, array_to_string(sub.subpublications, ',') AS publications
  FROM pg_stat_subscription s
  JOIN pg_subscription sub ON sub.oid = s.subid
 WHERE s.relid IS NULL`

const publicationsSQL = `
SELECT 'publication' AS kind, p.pubname::text AS pubname, p.puballtables, p.pubinsert, p.pubupdate, p.pubdelete, p.pubtruncate,
       (SELECT count(*) FROM pg_publication_rel r WHERE r.prpubid = p.oid) AS table_count
  FROM pg_publication p`

const conflictsSQL = `
SELECT 'conflict' AS kind, c.datid::bigint AS dbid, c.datname::text AS datname, c.confl_tablespace, c.confl_lock,
       c.confl_snapshot, c.confl_bufferpin, c.confl_deadlock, %s AS confl_active_logicalslot
  FROM pg_stat_database_conflicts c
  JOIN pg_database d ON d.oid = c.datid
 WHERE NOT d.datistemplate`

const auroraSQL = `
SELECT 'aurora_replica' AS kind, server_id, session_id, durable_lsn::text AS durable_lsn, highest_lsn_rcvd::text AS highest_lsn_rcvd,
       current_read_lsn::text AS current_read_lsn, cpu, iops, replica_lag_in_msec, log_stream_speed_in_kib_per_second,
       log_buffer_sequence_number, oldest_read_view_lsn::text AS oldest_read_view_lsn, last_update_timestamp
  FROM aurora_replica_status()`

func (replicationCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	out := []Row{}
	run := func(label, sql string) error {
		rows, err := conn.Query(ctx, sql)
		if err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		r, err := rowsToMaps(rows)
		if err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		out = append(out, r...)
		return nil
	}
	if err := run("senders", sendersSQL); err != nil {
		return nil, err
	}
	if info.IsReplica {
		if err := run("receiver", receiverSQL); err != nil {
			return nil, err
		}
	}
	slotCols, err := viewColumns(ctx, conn, "pg_catalog.pg_replication_slots")
	if err != nil {
		return nil, err
	}
	if err := run("slots", fmt.Sprintf(slotsSQL, col(slotCols, "s", "two_phase", "boolean"), col(slotCols, "s", "conflicting", "boolean"), col(slotCols, "s", "inactive_since", "timestamptz"))); err != nil {
		return nil, err
	}
	if err := run("subscriptions", subscriptionsSQL); err != nil {
		return nil, err
	}
	if err := run("publications", publicationsSQL); err != nil {
		return nil, err
	}
	conflCols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_database_conflicts")
	if err != nil {
		return nil, err
	}
	if err := run("conflicts", fmt.Sprintf(conflictsSQL, col(conflCols, "c", "confl_active_logicalslot", "bigint"))); err != nil {
		return nil, err
	}
	if info.Kind == platform.Aurora {
		if err := run("aurora_replica_status", auroraSQL); err != nil {
			return nil, err
		}
	}
	return out, nil
}
