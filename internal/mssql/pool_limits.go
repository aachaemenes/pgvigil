package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// poolLimitsCollector is mssql_pool_limits: an Azure SQL Database elastic pool's limits over time, read hourly from the
// logical server's master (P25 task 9b; DBA Dash's Pool history). sys.elastic_pool_resource_stats (Microsoft Learn,
// read 2026-11-17): it 'exists in the master database of the logical server', 'Requires membership in the dbmanager
// role', one row per pool every 15 seconds, 'retained for 14 days'; elastic_pool_dtu_limit and
// elastic_pool_storage_limit_mb are the pool's settings during each interval, elastic_pool_cpu_limit is 'Identified for
// informational purposes only. Not supported.' (stored, never shown as a supported figure).
//
// dbmanager lets a login create and drop databases on the logical server, which can cost money: pgvigil's documented
// login does not hold it, and the grant is an opt-in (the rights page's commented-out block, docs/sqlserver-cloud.md).
// So the collection reads on a connection of its own to master - the instance's connection settings with the database
// master, connected within masterConnectCap - only on a database in a pool, and reads the right first, by query, before
// the view. Without the right, or without a way into master (a contained database user has none), the run is skipped
// with its words; neither touches the instance's own connection or its other collections.
//
// The read sends the pool's rows collapsed into periods of equal limits, oldest first, and the window the view held
// (its oldest row's start, its newest row's end); 0395's import merges the overlapping hourly reads.
type poolLimitsCollector struct{}

func init() { Register(poolLimitsCollector{}) }

func (poolLimitsCollector) Name() string                   { return Prefix + "pool_limits" }
func (poolLimitsCollector) DefaultInterval() time.Duration { return time.Hour }

func (poolLimitsCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind != KindAzureDB:
		return false, "elastic pools are Azure SQL Database's"
	case !strings.EqualFold(info.ServiceObjective, "ElasticPool"):
		return false, "not in an elastic pool (service objective " + orNone(info.ServiceObjective) + ")"
	}
	return true, ""
}

// masterConnectCap bounds the connect to master: a login master refuses, or a server that does not answer, ends the
// run within it.
const masterConnectCap = 15 * time.Second

// poolLimitsRightSQL: whether the login may read the view, asked in master - a member of dbmanager there, the server
// admin (dbo in master: IS_ROLEMEMBER answers 0 for dbo, Microsoft's page), or a member of the server role
// ##MS_DatabaseManager## (the Pool lab's L4, 2026-11-17: a login holding it alone read the view, its 37 rows the
// admin's; Microsoft's view page names dbmanager only). The server role is read as the login's own membership in
// sys.server_role_members, which a login may see for itself: IS_SRVROLEMEMBER 'isn't supported in the master
// database' of Azure SQL Database, and a SQL login is in sys.sql_logins there, not sys.server_principals (an Entra
// login is in sys.server_principals) - Microsoft Learn, Azure SQL Database's server roles and sys.server_role_members.
const poolLimitsRightSQL = `SELECT CAST(CASE WHEN IS_ROLEMEMBER('dbmanager') = 1 OR USER_NAME() = 'dbo'
  OR EXISTS (SELECT 1 FROM sys.server_role_members m
               JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
              WHERE r.name = N'##MS_DatabaseManager##'
                AND m.member_principal_id IN (SELECT l.principal_id FROM sys.sql_logins l WHERE l.sid = SUSER_SID()
                                              UNION ALL
                                              SELECT p.principal_id FROM sys.server_principals p WHERE p.sid = SUSER_SID()))
  THEN 1 ELSE 0 END AS int) AS has_right`

// poolLimitsSQL: the pool's rows (@p1 its name) as periods of equal limits - a period starts at the first row and
// wherever a limit differs from the row before (NULLs compared as values: INTERSECT), its limits its rows' - each with
// its first row's start and its last row's end (UTC, the view's own).
const poolLimitsSQL = `WITH s AS (
  SELECT start_time, end_time, elastic_pool_dtu_limit AS dtu, elastic_pool_storage_limit_mb AS storage_mb, elastic_pool_cpu_limit AS cpu,
         LAG(elastic_pool_dtu_limit) OVER (ORDER BY start_time) AS p_dtu,
         LAG(elastic_pool_storage_limit_mb) OVER (ORDER BY start_time) AS p_storage_mb,
         LAG(elastic_pool_cpu_limit) OVER (ORDER BY start_time) AS p_cpu,
         ROW_NUMBER() OVER (ORDER BY start_time) AS rn
    FROM sys.elastic_pool_resource_stats
   WHERE elastic_pool_name = @p1
), f AS (
  SELECT start_time, end_time, dtu, storage_mb, cpu,
         CASE WHEN rn = 1 OR NOT EXISTS (SELECT dtu, storage_mb, cpu INTERSECT SELECT p_dtu, p_storage_mb, p_cpu) THEN 1 ELSE 0 END AS starts
    FROM s
), g AS (
  SELECT start_time, end_time, dtu, storage_mb, cpu, SUM(starts) OVER (ORDER BY start_time ROWS UNBOUNDED PRECEDING) AS period
    FROM f
)
SELECT CONVERT(varchar(27), MIN(start_time), 126) AS valid_from, CONVERT(varchar(27), MAX(end_time), 126) AS valid_to,
       MIN(dtu) AS dtu_limit, MIN(storage_mb) AS storage_limit_mb, MIN(cpu) AS cpu_limit
  FROM g
 GROUP BY period
 ORDER BY MIN(start_time)`

// noRightWords: the skip's words when the login is in neither dbmanager nor ##MS_DatabaseManager## (the opt-in not taken)
const noRightWords = "Pool history is not read: the login is not a member of dbmanager in the logical server's master, nor of the " +
	"server role ##MS_DatabaseManager## - an opt-in, since either lets the login create and drop databases on this logical server, " +
	"which can cost money (the rights page's commented-out block gives it); a membership through an Entra group is not seen (only the " +
	"login's own, until the Azure lab proves sys.login_token there)"

// noMasterWords: the skip's words when the login could not sign in to master
func noMasterWords(err error) string {
	// cut on a character, never inside one (a cut UTF-8 sequence makes PostgreSQL refuse the skip's note)
	msg := err.Error()
	if r := []rune(msg); len(r) > 200 {
		msg = string(r[:200]) + "..."
	}
	return "Pool history is not read: the login could not sign in to the logical server's master (a contained database user " +
		"has no way in; a login in master with ##MS_DatabaseConnector## has): " + msg
}

// Run is never called alone: RunInstance takes its place (an InstanceRunner: RunOnce calls it with the instance's
// configuration, to open master from).
func (poolLimitsCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_pool_limits reads the logical server's master: it runs through RunInstance")
}

func (poolLimitsCollector) RunInstance(ctx context.Context, conn *sql.Conn, info Info, in config.Instance) ([]collect.Row, error) {
	// the pool's name as mssql_pool takes it (the database's own answer, else the instance's tag pool:<name>)
	var objectives string
	if rows, err := QueryRows(ctx, conn, poolNameSQL); err == nil && len(rows) == 1 {
		objectives, _ = rows[0]["pool"].(string)
	}
	pool, _, _, err := poolName(info.PoolTag, objectives)
	if err != nil {
		return nil, err
	}
	mdb, mconn, err := openMaster(ctx, in)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", noMasterWords(err), collect.ErrSkip)
	}
	defer func() { _ = mconn.Close(); _ = mdb.Close() }()
	right, err := QueryRows(ctx, mconn, poolLimitsRightSQL)
	if err != nil {
		return nil, fmt.Errorf("the right's read in master: %w", err)
	}
	if v, ok := asInt(firstValue(right, "has_right")); !ok || v != 1 {
		return nil, fmt.Errorf("%s: %w", noRightWords, collect.ErrSkip)
	}
	raw, err := QueryRows(ctx, mconn, poolLimitsSQL, pool)
	if err != nil {
		return nil, fmt.Errorf("sys.elastic_pool_resource_stats: %w", err)
	}
	return poolLimitRows(info.ServerName, pool, raw)
}

// firstValue: the first row's column (nil when there is no row)
func firstValue(rows []collect.Row, col string) any {
	if len(rows) == 0 {
		return nil
	}
	return rows[0][col]
}

// poolLimitRows: 0395's payload - one 'limit_period' row per period (its times RFC 3339 UTC) and the 'limit_read' row
// with the window the view held (none when the view had no row of the pool: nothing to merge).
func poolLimitRows(server, pool string, raw []collect.Row) ([]collect.Row, error) {
	read := collect.Row{"kind": "limit_read", "server": server, "pool": pool, "state": "read"}
	out := make([]collect.Row, 0, len(raw)+1)
	for i, r := range raw {
		from, err := poolTime(r["valid_from"])
		if err != nil {
			return nil, fmt.Errorf("sys.elastic_pool_resource_stats: a period's start: %w", err)
		}
		to, err := poolTime(r["valid_to"])
		if err != nil {
			return nil, fmt.Errorf("sys.elastic_pool_resource_stats: a period's end: %w", err)
		}
		if i == 0 {
			read["window_from"] = from.UTC().Format(time.RFC3339Nano)
		}
		read["window_to"] = to.UTC().Format(time.RFC3339Nano)
		out = append(out, collect.Row{"kind": "limit_period", "server": server, "pool": pool,
			"valid_from": from.UTC().Format(time.RFC3339Nano), "valid_to": to.UTC().Format(time.RFC3339Nano),
			"dtu_limit": r["dtu_limit"], "storage_limit_mb": r["storage_limit_mb"], "cpu_limit": r["cpu_limit"]})
	}
	return append(out, read), nil
}

// openMaster opens one connection to the logical server's master with the instance's connection settings and its
// secret (the password from AWS Secrets Manager, the Entra token: the same open as the instance's), within
// masterConnectCap. It records nothing against the instance: a login master refuses is this collection's skip, never
// the instance's failed connect.
func openMaster(ctx context.Context, in config.Instance) (*sql.DB, *sql.Conn, error) {
	dsn, err := masterDSN(in.DSN())
	if err != nil {
		return nil, nil, err
	}
	sec, err := readSecret(ctx, in)
	if err != nil {
		return nil, nil, err
	}
	dl := &deadlineDialer{keepAlive: 30 * time.Second, until: time.Now().Add(masterConnectCap)}
	db, err := sec.open(withAppName(dsn), dl)
	if err != nil {
		return nil, nil, err
	}
	db.SetMaxOpenConns(1)
	cctx, cancel := context.WithTimeout(ctx, masterConnectCap)
	defer cancel()
	conn, err := db.Conn(cctx)
	if err != nil {
		_ = db.Close()
		return nil, nil, dl.withNetwork(cctx, err)
	}
	dl.done()
	if _, err := conn.ExecContext(ctx, sessionSetup); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, err
	}
	return db, conn, nil
}

// masterDSN is the connection string with the database master in place of the one it names (or none): a sqlserver://
// URL's 'database' parameter, an ADO string's 'database' or 'initial catalog' (go-mssqldb's synonym), the string's
// other parts as they were; go-mssqldb's ADO splitting kept (a ';' inside double quotes is a value's). An odbc: string
// is not rewritten: refused.
func masterDSN(dsn string) (string, error) {
	l := strings.ToLower(strings.TrimSpace(dsn))
	switch {
	case l == "":
		return "", errors.New("the dsn resolved to an empty string")
	case strings.HasPrefix(l, "odbc:"):
		return "", errors.New("an odbc: connection string: master is not opened from it (use the ADO or sqlserver:// form)")
	case strings.HasPrefix(l, "sqlserver://"):
		u, err := url.Parse(strings.TrimSpace(dsn))
		if err != nil {
			return "", errors.New("the connection string is not a valid sqlserver:// URL")
		}
		q := u.Query()
		for k := range q {
			if strings.EqualFold(k, "database") {
				q.Del(k)
			}
		}
		q.Set("database", "master")
		u.RawQuery = q.Encode()
		return u.String(), nil
	}
	var kept []string
	for _, part := range adoParts(dsn) {
		key := strings.ToLower(strings.TrimSpace(strings.SplitN(part, "=", 2)[0]))
		if key == "database" || key == "initial catalog" || strings.TrimSpace(part) == "" {
			continue
		}
		kept = append(kept, part)
	}
	return strings.Join(append(kept, "database=master"), ";"), nil
}

// adoParts splits an ADO connection string at the semicolons outside double quotes ("" inside quotes is a quote),
// go-mssqldb's own rule (msdsn splitAdoConnectionStringParts).
func adoParts(dsn string) []string {
	var parts []string
	var cur strings.Builder
	in := false
	rs := []rune(dsn)
	for i := 0; i < len(rs); i++ {
		c := rs[i]
		switch {
		case c == '"' && in && i+1 < len(rs) && rs[i+1] == '"':
			cur.WriteRune(c)
			cur.WriteRune(rs[i+1])
			i++
		case c == '"':
			in = !in
			cur.WriteRune(c)
		case c == ';' && !in:
			parts = append(parts, cur.String())
			cur.Reset()
		default:
			cur.WriteRune(c)
		}
	}
	if cur.Len() > 0 {
		parts = append(parts, cur.String())
	}
	return parts
}
