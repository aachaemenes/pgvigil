package collect

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// replicationCollector is the HADR page: streaming senders (pg_stat_replication,
// each with the slot it holds), the receiver on a standby (pg_stat_wal_receiver,
// replay delay), the standby's recovery state (a 'standby' row) and
// synchronous_standby_names (a 'sync' row), replication
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

// db_sender: a database (logical) walsender - a table copy's, or a client's between its slot and START_REPLICATION -
// holds no active slot, so slot_type alone would read it as a physical link (0141's pg_link_sender leaves it out)
const sendersSQL = `
SELECT 'sender' AS kind, r.pid, r.usename::text AS usename, r.application_name, host(r.client_addr) AS client_addr,
       r.backend_start, r.state, r.sync_state, r.sync_priority,
       r.sent_lsn::text, r.write_lsn::text, r.flush_lsn::text, r.replay_lsn::text,
       pg_wal_lsn_diff(` + currentLSN + `, r.sent_lsn)   AS sent_lag_bytes,
       pg_wal_lsn_diff(` + currentLSN + `, r.replay_lsn) AS replay_lag_bytes,
       pg_wal_lsn_diff(` + currentLSN + `, r.flush_lsn)  AS flush_lag_bytes,
       extract(epoch FROM r.write_lag)  AS write_lag_secs,
       extract(epoch FROM r.flush_lag)  AS flush_lag_secs,
       extract(epoch FROM r.replay_lag) AS replay_lag_secs,
       r.reply_time, sl.slot_name::text AS slot_name, sl.slot_type, sl.temporary AS slot_temporary,
       (SELECT a.datname IS NOT NULL FROM pg_stat_activity a WHERE a.pid = r.pid) AS db_sender
  FROM pg_stat_replication r
  LEFT JOIN pg_replication_slots sl ON sl.active_pid = r.pid`

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

// the server's recovery state, one row while it is in recovery (none on a primary): whether a WAL receiver runs, whether
// primary_conninfo and restore_command are set (true / false only: the values can hold a password; read through
// pg_settings, whose superuser-only rows a login without pg_read_all_settings does not see, so NULL is 'unknown'), the
// receive and replay positions and the replay pause. The repository's 'receiver down' rule reads it (migration 0141).
const standbySQL = `
SELECT 'standby' AS kind,
       EXISTS (SELECT 1 FROM pg_stat_wal_receiver w WHERE w.pid IS NOT NULL) AS has_receiver,
       (SELECT s.setting <> '' FROM pg_settings s WHERE s.name = 'primary_conninfo') AS conninfo_set,
       (SELECT s.setting <> '' FROM pg_settings s WHERE s.name = 'restore_command') AS restore_set,
       (SELECT s.setting FROM pg_settings s WHERE s.name = 'primary_slot_name') AS primary_slot_name,
       (SELECT s.setting::bigint FROM pg_settings s WHERE s.name = 'recovery_min_apply_delay') AS min_apply_delay_ms,
       pg_last_wal_receive_lsn()::text AS receive_lsn,
       pg_last_wal_replay_lsn()::text  AS replay_lsn,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS replay_lag_bytes,
       pg_last_xact_replay_timestamp() AS last_replay_at,
       CASE WHEN pg_is_in_recovery() THEN pg_is_wal_replay_paused() END AS replay_paused
 WHERE pg_is_in_recovery()`

// the synchronous standbys a primary waits for, one row always (on a standby the setting is inert: in_recovery says so).
// commit_level is the server-wide synchronous_commit only: a value set for this login, its database or this session
// (source user, database, client, session) is not what the applications run with, so it is sent as NULL (unknown).
const syncSQL = `
SELECT 'sync' AS kind, current_setting('synchronous_standby_names') AS names,
       (SELECT CASE WHEN s.source IN ('default', 'configuration file', 'command line', 'environment variable', 'global', 'override')
                    THEN s.setting END
          FROM pg_settings s WHERE s.name = 'synchronous_commit') AS commit_level,
       pg_is_in_recovery() AS in_recovery`

// one row per subscription: the apply worker only (a parallel apply worker on
// PG16+ has a leader_pid); the key is the database plus the name, since
// pg_subscription is cluster-wide and names repeat across databases
const subscriptionsSQL = `
SELECT 'subscription' AS kind, s.subid::bigint AS subid, s.subname::text AS subname, d.datname::text AS datname,
       s.pid, s.received_lsn::text, CASE WHEN isfinite(s.last_msg_send_time) THEN s.last_msg_send_time END AS last_msg_send_time,
       CASE WHEN isfinite(s.last_msg_receipt_time) THEN s.last_msg_receipt_time END AS last_msg_receipt_time, s.latest_end_lsn::text,
       CASE WHEN isfinite(s.latest_end_time) THEN s.latest_end_time END AS latest_end_time,
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

// auroraStandbySQL is the 'standby' row of an Aurora reader. An Aurora reader applies the writer's log stream to its
// cache from the shared storage, not through a WAL receiver, and its standbySQL read raised on a real reader
// (proof-pg-aurora.sh's lab run: no standby state stored, so 0141's reader exclusion never applied). A real Aurora
// PostgreSQL 17.9 reader rejects every call standbySQL and receiverSQL make beyond pg_is_in_recovery() - SQLSTATE
// 0A000, "currently not supported for Aurora": pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
// pg_last_xact_replay_timestamp(), pg_is_wal_replay_paused() and pg_stat_wal_receiver (pg_stat_get_wal_receiver())
// (proof-pg-aurora.sh's Q7a-probe, 2026-11-15; AWS's documentation does not list them). The row says only that the
// server is in recovery - no receiver, positions, conninfo or restore_command (NULL: no 'receiver down', no 'replay
// paused').
const auroraStandbySQL = `
SELECT 'standby' AS kind, false AS has_receiver, NULL::boolean AS conninfo_set, NULL::boolean AS restore_set,
       NULL::text AS primary_slot_name, NULL::bigint AS min_apply_delay_ms, NULL::text AS receive_lsn, NULL::text AS replay_lsn,
       NULL::numeric AS replay_lag_bytes, NULL::timestamptz AS last_replay_at, NULL::boolean AS replay_paused
 WHERE pg_is_in_recovery()`

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
	if info.Kind == platform.Aurora {
		read("standby", auroraStandbySQL) // an Aurora reader has no WAL receiver: aurora_replica_status judges it
	} else {
		if info.IsReplica {
			read("receiver", receiverSQL)
		}
		read("standby", standbySQL)
	}
	read("sync", syncSQL)
	// the slots and their decoding statistics (slots.go)
	for _, q := range slotQueries(ctx, conn, info) {
		if q.err != nil {
			failed = append(failed, q.label)
			out = append(out, Row{"kind": "collector_error", "source": q.label, "message": q.err.Error()})
			continue
		}
		read(q.label, q.sql)
	}
	if subCols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_subscription"); err != nil {
		failed = append(failed, "subscriptions")
		out = append(out, Row{"kind": "collector_error", "source": "subscriptions", "message": err.Error()})
	} else {
		leader := ""
		if subCols["leader_pid"] {
			leader = "AND s.leader_pid IS NULL"
		}
		if subCols["worker_type"] {
			leader += " AND s.worker_type = 'apply'"
		}
		var oidOK bool
		if err := conn.QueryRow(ctx, logicalSubOidSQL).Scan(&oidOK); err != nil || oidOK {
			read("subscriptions", fmt.Sprintf(subscriptionsSQL, leader))
		} // else PostgreSQL 13 without pg_subscription.oid: the logical collection's error row says so (not one per minute here)
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
