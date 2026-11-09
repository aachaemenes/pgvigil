package collect

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// databasesCollector is the hourly inventory of databases: size, owner,
// encoding and collation, connection limit, tablespace, transaction-id age
// (the wraparound headroom check), and whether the monitoring login may connect.
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
