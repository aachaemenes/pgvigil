package collect

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// logicalCollector is PostgreSQL's logical replication from both ends (the HA build's item 2, task 373; migration
// 0141): on a subscriber every subscription of the cluster (pg_subscription is shared) with its apply worker, its
// positions and the time since its last message, its error counters (pg_stat_subscription_stats, PostgreSQL 15 on) and
// its conflict counters (PostgreSQL 18 on), and per database that holds a subscription the tables whose initial sync is
// not finished (pg_subscription_rel, a per-database catalog: one connection to each such database); on a publisher the
// publications of every database that has a logical slot, and of the connected one. The publisher's walsender of each
// subscription, with its lag, is the replication collection's sender row of the slot.
//
// Every minute. A read that fails sends a collector_error row and the others are still stored; a database that cannot
// be read sends 'logical:<db>' so the import keeps that database's rows as they were.
type logicalCollector struct{}

func init() { Register(logicalCollector{}) }

func (logicalCollector) Name() string                   { return "logical" }
func (logicalCollector) DefaultInterval() time.Duration { return time.Minute }
func (logicalCollector) Applies(info platform.Info) (bool, string) {
	if info.ServerVersionNum < 130000 {
		return false, "needs PostgreSQL 13 or later"
	}
	return true, ""
}

func (c logicalCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return c.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

// logicalSubsSQL: one row per subscription with its apply worker (relid NULL; a parallel apply worker, PostgreSQL 16
// on, has a leader_pid). subconninfo is never read (it can hold a password; pg_monitor cannot read it anyway).
const logicalSubsSQL = `
SELECT 'subscription' AS kind, s.oid::bigint AS subid, s.subname::text AS subname, d.datname::text AS datname,
       s.subenabled AS enabled, s.subslotname::text AS slot_name, array_to_string(s.subpublications, ',') AS publications,
       %s AS disable_on_error, pg_is_in_recovery() AS in_recovery,
       w.pid AS worker_pid, w.received_lsn::text AS received_lsn, w.latest_end_lsn::text AS latest_end_lsn,
       w.last_msg_send_time, w.last_msg_receipt_time, w.latest_end_time,
       extract(epoch FROM clock_timestamp() - w.last_msg_receipt_time)::float8 AS silent_secs,
       (SELECT count(*) FROM pg_stat_subscription x WHERE x.subid = s.oid AND x.relid IS NOT NULL) AS sync_workers,
       %s
  FROM pg_subscription s
  LEFT JOIN pg_database d ON d.oid = s.subdbid
  LEFT JOIN pg_stat_subscription w ON w.subid = s.oid AND w.relid IS NULL %s
  %s`

// the counters of pg_stat_subscription_stats: the errors from PostgreSQL 15, the conflicts from 18
var logicalStatCols = []string{"apply_error_count", "sync_error_count", "confl_insert_exists", "confl_update_origin_differs",
	"confl_update_exists", "confl_update_missing", "confl_delete_origin_differs", "confl_delete_missing",
	"confl_multiple_unique_conflicts"}

// the databases to visit: those holding a subscription, those a logical slot decodes, and the connected one
const logicalDatabasesSQL = `
SELECT d.datname::text,
       d.oid IN (SELECT subdbid FROM pg_subscription) AS has_subs,
       d.datname IN (SELECT database FROM pg_replication_slots WHERE slot_type = 'logical') OR d.datname = current_database() AS has_pubs
  FROM pg_database d
 WHERE d.datallowconn AND NOT d.datistemplate
   AND (d.oid IN (SELECT subdbid FROM pg_subscription)
        OR d.datname IN (SELECT database FROM pg_replication_slots WHERE slot_type = 'logical')
        OR d.datname = current_database())
 ORDER BY d.datname`

// a database's tables not ready yet (i init, d copying, f copied, s synchronized), and per subscription how many
const logicalRelsSQL = `
SELECT 'sub_rel' AS kind, current_database()::text AS datname, s.subname::text AS subname,
       n.nspname::text || '.' || c.relname::text AS rel, r.srsubstate::text AS state, r.srsublsn::text AS lsn
  FROM pg_subscription_rel r
  JOIN pg_subscription s ON s.oid = r.srsubid
  JOIN pg_class c ON c.oid = r.srrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE r.srsubstate <> 'r'
UNION ALL
SELECT 'sub_rels', current_database()::text, s.subname::text, NULL, count(*) FILTER (WHERE r.srsubstate = 'r')::text || '/' || count(*)::text, NULL
  FROM pg_subscription s
  LEFT JOIN pg_subscription_rel r ON r.srsubid = s.oid
 WHERE s.subdbid = (SELECT oid FROM pg_database WHERE datname = current_database())
 GROUP BY s.subname`

const logicalPubsSQL = `
SELECT 'publication' AS kind, current_database()::text AS datname, p.pubname::text AS pubname, p.puballtables,
       p.pubinsert, p.pubupdate, p.pubdelete, p.pubtruncate,
       (SELECT count(*) FROM pg_publication_tables t WHERE t.pubname = p.pubname) AS table_count
  FROM pg_publication p`

func (logicalCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	out := []Row{}
	failed := 0
	fail := func(source string, err error) {
		failed++
		out = append(out, Row{"kind": "collector_error", "source": source, "message": err.Error()})
	}
	query := func(c *pgx.Conn, sql string) ([]Row, error) {
		rows, err := c.Query(ctx, sql)
		if err != nil {
			return nil, err
		}
		return rowsToMaps(rows)
	}

	subCols, err := viewColumns(ctx, conn, "pg_catalog.pg_subscription")
	if err != nil {
		return nil, err
	}
	wCols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_subscription")
	if err != nil {
		return nil, err
	}
	stCols, err := viewColumns(ctx, conn, "pg_catalog.pg_stat_subscription_stats")
	if err != nil {
		return nil, err
	}
	leader, statJoin := "", ""
	if wCols["leader_pid"] {
		leader = "AND w.leader_pid IS NULL"
	}
	stats := make([]string, 0, len(logicalStatCols)+1)
	if len(stCols) > 0 {
		statJoin = "LEFT JOIN pg_stat_subscription_stats st ON st.subid = s.oid"
	}
	for _, c := range logicalStatCols {
		stats = append(stats, col(stCols, "st", c, "bigint")+" AS "+c)
	}
	stats = append(stats, col(stCols, "st", "stats_reset", "timestamptz")+" AS stats_reset")
	subsSQL := fmt.Sprintf(logicalSubsSQL, col(subCols, "s", "subdisableonerr", "boolean"), strings.Join(stats, ", "), leader, statJoin)
	if r, err := query(conn, subsSQL); err != nil {
		fail("subscriptions", err)
	} else {
		out = append(out, r...)
	}

	dbs, err := query(conn, logicalDatabasesSQL)
	if err != nil {
		fail("databases", err)
		dbs = nil
	}
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	for _, d := range dbs {
		db, _ := d["datname"].(string)
		subs, _ := d["has_subs"].(bool)
		pubs, _ := d["has_pubs"].(bool)
		read := func(ctx context.Context, c *pgx.Conn) ([]Row, error) {
			var rs []Row
			if subs {
				r, err := query(c, logicalRelsSQL)
				if err != nil {
					return nil, fmt.Errorf("pg_subscription_rel: %w", err)
				}
				rs = append(rs, r...)
			}
			if pubs {
				r, err := query(c, logicalPubsSQL)
				if err != nil {
					return nil, fmt.Errorf("pg_publication: %w", err)
				}
				rs = append(rs, r...)
			}
			return rs, nil
		}
		var rs []Row
		if db == cur || in.DSN() == "" {
			if db != cur {
				continue // a run without the instance's config (Run) reads the connected database only
			}
			rs, err = read(ctx, conn)
		} else {
			rs, err = onDatabase(ctx, in, db, read)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			fail("logical:"+db, err)
			continue
		}
		out = append(out, rs...)
		out = append(out, Row{"kind": "db_read", "datname": db, "subs": subs, "pubs": pubs})
	}
	if failed > 0 && len(out) == failed {
		return nil, fmt.Errorf("every read failed: %s", out[0]["message"])
	}
	return out, nil
}
