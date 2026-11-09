package collect

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// replicationCollector is the HADR page: streaming senders (pg_stat_replication),
// the receiver on a standby (pg_stat_wal_receiver, replay delay), replication
// slots with the WAL they retain (a DMS or Debezium consumer is a slot), logical
// subscriptions and publications, recovery conflicts per database, and on Aurora
// the replica status function. Every minute; rows are stored as read, each with a
// kind, and the repository keeps a current view plus a history.
//
// Each kind is read on its own: a failing read (a grant missing for
// aurora_replica_status, a column a version lacks) is recorded as a
// collector_error row for the collection log and the other kinds are still
// stored. The collection fails only when nothing could be read.
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

// the server's own write position: on a standby pg_current_wal_lsn() raises, so
// the last received position stands in
const currentLSN = `CASE WHEN pg_is_in_recovery() THEN pg_last_wal_receive_lsn() ELSE pg_current_wal_lsn() END`

const sendersSQL = `
SELECT 'sender' AS kind, r.pid, r.usename::text AS usename, r.application_name, host(r.client_addr) AS client_addr,
       r.backend_start, r.state, r.sync_state, r.sync_priority,
       r.sent_lsn::text, r.write_lsn::text, r.flush_lsn::text, r.replay_lsn::text,
       pg_wal_lsn_diff(` + currentLSN + `, r.sent_lsn)   AS sent_lag_bytes,
       pg_wal_lsn_diff(` + currentLSN + `, r.replay_lsn) AS replay_lag_bytes,
       extract(epoch FROM r.write_lag)  AS write_lag_secs,
       extract(epoch FROM r.flush_lag)  AS flush_lag_secs,
       extract(epoch FROM r.replay_lag) AS replay_lag_secs,
       r.reply_time
  FROM pg_stat_replication r`

// the standby side: one row when this server is in recovery. The replay delay
// is 0 when everything received has been replayed: behind an idle primary the
// last replayed commit's timestamp never moves, which is not lag.
const receiverSQL = `
SELECT 'receiver' AS kind, w.pid, w.status, w.sender_host, w.sender_port, w.slot_name,
       w.written_lsn::text, w.flushed_lsn::text, w.latest_end_lsn::text, w.latest_end_time, w.last_msg_receipt_time,
       pg_last_wal_receive_lsn()::text AS receive_lsn,
       pg_last_wal_replay_lsn()::text  AS replay_lsn,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS replay_lag_bytes,
       CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
            ELSE extract(epoch FROM clock_timestamp() - pg_last_xact_replay_timestamp()) END AS replay_delay_secs,
       pg_is_wal_replay_paused() AS replay_paused,
       regexp_replace(w.conninfo, '(password|passfile|sslkey|sslpassword)=\S+', '\1=<masked>', 'gi') AS conninfo
  FROM pg_stat_wal_receiver w`

// slots: wal_status and safe_wal_size exist from PG13; two_phase 14, conflicting 16, synced and inactive_since 17
const slotsSQL = `
SELECT 'slot' AS kind, s.slot_name, s.plugin, s.slot_type, s.database::text AS datname, s.temporary, s.active, s.active_pid,
       s.xmin::text AS xmin, s.catalog_xmin::text AS catalog_xmin,
       s.restart_lsn::text, s.confirmed_flush_lsn::text, s.wal_status, s.safe_wal_size,
       CASE WHEN pg_is_in_recovery() THEN pg_wal_lsn_diff(pg_last_wal_replay_lsn(), s.restart_lsn)
            ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) END AS retained_bytes,
       %s AS two_phase, %s AS conflicting, %s AS inactive_since, %s AS synced
  FROM pg_replication_slots s`

// one row per subscription: the apply worker only (a parallel apply worker on
// PG16+ has a leader_pid); the key is the database plus the name, since
// pg_subscription is cluster-wide and names repeat across databases
const subscriptionsSQL = `
SELECT 'subscription' AS kind, s.subid::bigint AS subid, s.subname::text AS subname, d.datname::text AS datname,
       s.pid, s.received_lsn::text, s.last_msg_send_time, s.last_msg_receipt_time, s.latest_end_lsn::text, s.latest_end_time,
       sub.subenabled AS enabled, array_to_string(sub.subpublications, ',') AS publications
  FROM pg_stat_subscription s
  JOIN pg_subscription sub ON sub.oid = s.subid
  LEFT JOIN pg_database d ON d.oid = sub.subdbid
 WHERE s.relid IS NULL %s`

const publicationsSQL = `
SELECT 'publication' AS kind, p.pubname::text AS pubname, p.puballtables, p.pubinsert, p.pubupdate, p.pubdelete, p.pubtruncate,
       (SELECT count(*) FROM pg_publication_tables t WHERE t.pubname = p.pubname) AS table_count
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
	var failed []string
	okKinds := 0
	read := func(label, sql string) {
		rows, err := conn.Query(ctx, sql)
		if err == nil {
			var r []Row
			r, err = rowsToMaps(rows)
			if err == nil {
				out = append(out, r...)
				okKinds++
				return
			}
		}
		failed = append(failed, label)
		out = append(out, Row{"kind": "collector_error", "source": label, "message": err.Error()})
	}

	read("senders", sendersSQL)
	if info.IsReplica {
		read("receiver", receiverSQL)
	}
	if slotCols, err := viewColumns(ctx, conn, "pg_catalog.pg_replication_slots"); err != nil {
		failed = append(failed, "slots")
		out = append(out, Row{"kind": "collector_error", "source": "slots", "message": err.Error()})
	} else {
		read("slots", fmt.Sprintf(slotsSQL, col(slotCols, "s", "two_phase", "boolean"), col(slotCols, "s", "conflicting", "boolean"),
			col(slotCols, "s", "inactive_since", "timestamptz"), col(slotCols, "s", "synced", "boolean")))
	}
	if subCols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_subscription"); err != nil {
		failed = append(failed, "subscriptions")
		out = append(out, Row{"kind": "collector_error", "source": "subscriptions", "message": err.Error()})
	} else {
		leader := ""
		if subCols["leader_pid"] {
			leader = "AND s.leader_pid IS NULL"
		}
		read("subscriptions", fmt.Sprintf(subscriptionsSQL, leader))
	}
	read("publications", publicationsSQL)
	if conflCols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_database_conflicts"); err != nil {
		failed = append(failed, "conflicts")
		out = append(out, Row{"kind": "collector_error", "source": "conflicts", "message": err.Error()})
	} else {
		read("conflicts", fmt.Sprintf(conflictsSQL, col(conflCols, "c", "confl_active_logicalslot", "bigint")))
	}
	if info.Kind == platform.Aurora {
		read("aurora_replica_status", auroraSQL)
	}
	if okKinds == 0 {
		return nil, fmt.Errorf("every read failed: %s", strings.Join(failed, ", "))
	}
	return out, nil
}
