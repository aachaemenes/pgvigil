package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// databasesCollector is the hourly inventory of databases: size, owner,
// encoding and collation, connection limit, tablespace, transaction-id age
// (the wraparound headroom check), whether the monitoring login may connect, and the database's comment
// (pg_shdescription, readable by every role). The Database info tab (0046) joins these facts with the
// locale and collation versions (the versions collection), the tablespace sizes (storage) and the
// installed extensions (extensions) rather than reading them a second time here.
// pg_database_size walks every relation file, which is why it is hourly here and
// not in the per-minute counters.
type databasesCollector struct{}

func init() { Register(databasesCollector{}) }

func (databasesCollector) Name() string                   { return "databases" }
func (databasesCollector) DefaultInterval() time.Duration { return time.Hour }
func (databasesCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// size is read only where CONNECT is granted: pg_database_size raises for a
// database the role cannot connect to unless it holds pg_read_all_stats.
const databasesSQL = `
SELECT d.oid::bigint                                   AS dbid,
       d.datname::text                                 AS datname,
       pg_get_userbyid(d.datdba)::text                 AS owner,
       pg_encoding_to_char(d.encoding)                 AS encoding,
       d.datcollate                                    AS lc_collate,
       d.datctype                                      AS lc_ctype,
       d.datistemplate                                 AS is_template,
       d.datallowconn                                  AS allow_conn,
       d.datconnlimit                                  AS conn_limit,
       t.spcname::text                                 AS tablespace,
       age(d.datfrozenxid)                             AS xid_age,
       mxid_age(d.datminmxid)                          AS mxid_age,
       has_database_privilege(d.datname, 'CONNECT')    AS can_connect,
       left(shobj_description(d.oid, 'pg_database'), 1000) AS comment,
       CASE WHEN d.datallowconn AND (has_database_privilege(d.datname, 'CONNECT')
                                     OR pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER'))
            THEN pg_database_size(d.oid) END           AS size_bytes
  FROM pg_database d
  LEFT JOIN pg_tablespace t ON t.oid = d.dattablespace
 ORDER BY d.datname`

func (databasesCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	rows, err := conn.Query(ctx, databasesSQL)
	if err != nil {
		return nil, err
	}
	return rowsToMaps(rows)
}

// connectionsCollector counts every client connection once a minute per source: application, user, database and
// client (pghero's connection sources), with the states. The activity collection stores only active and
// idle-in-transaction sessions, so the idle connections a pool holds, the bulk of most servers' connections, are
// counted here. A login without pg_read_all_stats (pg_monitor) sees other users' sessions without their state or
// client: they count under 'other' with an empty client. Over connSourcesMax sources a read folds the smallest
// into one row named '(other sources)' in all four dimensions, so a grouping by any of them shows it apart.
type connectionsCollector struct{}

func init() { Register(connectionsCollector{}) }

const connSourcesMax = 500

func (connectionsCollector) Name() string                   { return "connections" }
func (connectionsCollector) DefaultInterval() time.Duration { return time.Minute }
func (connectionsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// connectionsSQL: %[1]d = the most sources kept apart.
const connectionsSQL = `
WITH g AS (
  SELECT coalesce(a.application_name, '') AS application_name, coalesce(a.usename::text, '') AS usename,
         coalesce(a.datname::text, '') AS datname,
         coalesce(a.client_hostname, host(a.client_addr), CASE WHEN a.client_port = -1 THEN 'local socket' END, '') AS client,
         count(*) AS total,
         count(*) FILTER (WHERE a.state = 'active') AS active,
         count(*) FILTER (WHERE a.state = 'idle') AS idle,
         count(*) FILTER (WHERE a.state LIKE 'idle in transaction%%') AS idle_in_txn,
         count(*) FILTER (WHERE a.wait_event_type = 'Lock') AS waiting_lock,
         count(*) FILTER (WHERE a.state IS NULL OR a.state NOT IN ('active', 'idle') AND a.state NOT LIKE 'idle in transaction%%') AS other
    FROM pg_stat_activity a
   WHERE a.backend_type = 'client backend' AND a.pid <> pg_backend_pid()
   GROUP BY 1, 2, 3, 4
), r AS (
  SELECT g.*, row_number() OVER (ORDER BY g.total DESC, g.application_name, g.usename, g.datname, g.client) AS rn FROM g
)
SELECT 'source' AS kind,
       CASE WHEN rn <= %[1]d THEN application_name ELSE '(other sources)' END AS application_name,
       CASE WHEN rn <= %[1]d THEN usename ELSE '(other sources)' END AS usename,
       CASE WHEN rn <= %[1]d THEN datname ELSE '(other sources)' END AS datname,
       CASE WHEN rn <= %[1]d THEN client ELSE '(other sources)' END AS client,
       sum(total)::int AS total, sum(active)::int AS active, sum(idle)::int AS idle, sum(idle_in_txn)::int AS idle_in_txn,
       sum(waiting_lock)::int AS waiting_lock, sum(other)::int AS other
  FROM r
 GROUP BY 2, 3, 4, 5`

func (connectionsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	rows, err := conn.Query(ctx, fmt.Sprintf(connectionsSQL, connSourcesMax))
	if err != nil {
		return nil, err
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, err
	}
	return append(out, Row{"kind": "read"}), nil
}
