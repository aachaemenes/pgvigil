package collect

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// Two per-database collections of task 155 (K11.04, K11.06, K11.14):
//
//   functions  every 5 minutes: pg_stat_user_functions (calls, total and self time; track_functions must be pl or all,
//              the server's default none leaves the view empty and each database's row says so), the busiest
//              functionsTopN of each database by total time. Stored as read (cumulative); the repository takes the
//              difference per function over a window (pgvigil.function_top).
//   dbchecks   every hour: the catalog reads behind the cheap findings - every sequence with its last value against the
//              smaller of its own maximum and the maximum of the column it feeds (a bigint sequence behind an integer
//              column runs out at the column's limit) and its block reads, a SECURITY DEFINER function without a
//              search_path, a NOT VALID constraint with its VALIDATE line, a DEFAULT partition that holds rows, CREATE
//              on schema public for PUBLIC, and (from the connected database only, a superuser's read) the login roles
//              whose password is an MD5 hash.
//
// Both read the connected database on its connection and every other connectable database on its own (eachDatabase),
// up to tablesMaxDatabases; a database that cannot be read sends a collector_error row 'functions:<db>' or
// 'dbchecks:<db>' and the import keeps its stored rows.

type functionsCollector struct{}
type dbchecksCollector struct{}

func init() {
	Register(functionsCollector{})
	Register(dbchecksCollector{})
}

// functionsTopN bounds one database's function rows per read.
const functionsTopN = 500

// sequencesMax bounds one database's sequence rows per read (the fullest first).
const sequencesMax = 2000

func (functionsCollector) Name() string                   { return "functions" }
func (functionsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (functionsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}
func (functionsCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("functions runs per instance (RunInstance)")
}

func (dbchecksCollector) Name() string                   { return "dbchecks" }
func (dbchecksCollector) DefaultInterval() time.Duration { return time.Hour }
func (dbchecksCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}
func (dbchecksCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("dbchecks runs per instance (RunInstance)")
}

// functionsDBSQL: the database read and the track_functions in force there (a per-database ALTER DATABASE ... SET can
// differ from the server's).
const functionsDBSQL = `
SELECT 'db' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, current_setting('track_functions') AS track_functions`

// functionsSQL: one row per function with statistics, the busiest by total time first. $1 = the row bound.
const functionsSQL = `
SELECT 'func' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, f.funcid::bigint AS funcid, f.schemaname::text AS schema_name,
       f.funcname::text AS func_name, pg_get_function_identity_arguments(f.funcid) AS args,
       f.calls, f.total_time AS total_ms, f.self_time AS self_ms
  FROM pg_stat_user_functions f
 ORDER BY f.total_time DESC, f.funcid
 LIMIT $1`

func (functionsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	return eachDatabase(ctx, conn, in, "functions", func(ctx context.Context, c *pgx.Conn, _ bool) ([]Row, error) {
		return readAll(ctx, c, []namedRead{{"database", functionsDBSQL, nil}, {"functions", functionsSQL, []any{functionsTopN}}})
	})
}

// dbchecksSequencesSQL: every sequence (pg_sequences: last_value is NULL when the login may not read the sequence, or it
// was never used) with the column it is the default of, or owned by, and that column's type maximum; pct_used against the
// smaller of the two maximums (an ascending sequence; a descending one against its minimum). Block reads and hits from
// pg_statio_user_sequences. $1 = the row bound. A sequence the login may not read comes back with readable false and no
// last value (pg_read_all_data, 14+, or SELECT on it makes it readable).
const dbchecksSequencesSQL = `
WITH s AS (
  SELECT c.oid, n.nspname::text AS schema_name, c.relname::text AS seq_name, q.seqtypid::regtype::text AS data_type,
         q.seqincrement AS increment_by, q.seqmax AS max_value, q.seqmin AS min_value, q.seqcycle AS cycles, c.relpersistence,
         has_sequence_privilege(c.oid, 'SELECT') OR has_sequence_privilege(c.oid, 'USAGE') AS readable
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_sequence q ON q.seqrelid = c.oid
   WHERE c.relkind = 'S' AND c.relpersistence <> 't' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
), col AS (
  -- the column the sequence feeds: an identity or serial column depends on it (pg_depend 'i' / 'a' to the column); a
  -- hand-made DEFAULT nextval() through the default's own dependency
  SELECT s.oid, tn.nspname::text AS col_schema, t.relname::text AS col_table, a.attname::text AS col_name,
         a.atttypid::regtype::text AS col_type
    FROM s
    JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = s.oid AND d.refclassid = 'pg_class'::regclass
                    AND d.deptype IN ('a', 'i') AND d.refobjsubid > 0
    JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
    JOIN pg_class t ON t.oid = a.attrelid
    JOIN pg_namespace tn ON tn.oid = t.relnamespace
  UNION ALL
  SELECT s.oid, tn.nspname::text, t.relname::text, a.attname::text, a.atttypid::regtype::text
    FROM s
    JOIN pg_depend d ON d.classid = 'pg_attrdef'::regclass AND d.refclassid = 'pg_class'::regclass AND d.refobjid = s.oid
    JOIN pg_attrdef ad ON ad.oid = d.objid
    JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
    JOIN pg_class t ON t.oid = a.attrelid
    JOIN pg_namespace tn ON tn.oid = t.relnamespace
), c1 AS (
  -- one column per sequence; of several, the smallest type (the first to run out)
  SELECT DISTINCT ON (oid) * FROM col
   ORDER BY oid, CASE col_type WHEN 'smallint' THEN 1 WHEN 'integer' THEN 2 WHEN 'bigint' THEN 3 ELSE 4 END, col_table, col_name
), v AS (
  SELECT s.*, c1.col_schema, c1.col_table, c1.col_name, c1.col_type,
         CASE c1.col_type WHEN 'smallint' THEN 32767::numeric WHEN 'integer' THEN 2147483647::numeric
                          WHEN 'bigint' THEN 9223372036854775807::numeric END AS col_max,
         CASE c1.col_type WHEN 'smallint' THEN -32768::numeric WHEN 'integer' THEN -2147483648::numeric
                          WHEN 'bigint' THEN -9223372036854775808::numeric END AS col_min,
         -- an unlogged sequence cannot be read on a standby
         CASE WHEN s.readable AND NOT (s.relpersistence = 'u' AND pg_is_in_recovery()) THEN pg_sequence_last_value(s.oid::regclass) END AS last_value
    FROM s LEFT JOIN c1 ON c1.oid = s.oid
)
SELECT 'seq' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, v.oid::bigint AS seqrelid, v.schema_name, v.seq_name, v.data_type, v.increment_by,
       v.min_value, v.max_value, v.cycles, v.readable, v.last_value, v.col_schema, v.col_table, v.col_name, v.col_type, v.col_max,
       -- an ascending sequence against the smaller maximum, a descending one against the larger minimum; a limit of 0 (a
       -- countdown to 0) has no share
       CASE WHEN v.last_value IS NULL THEN NULL
            WHEN v.increment_by > 0 THEN round(100 * v.last_value::numeric / nullif(least(v.max_value::numeric, coalesce(v.col_max, v.max_value::numeric)), 0), 2)
            ELSE round(100 * v.last_value::numeric / nullif(greatest(v.min_value::numeric, coalesce(v.col_min, v.min_value::numeric)), 0), 2) END AS pct_used,
       io.blks_read, io.blks_hit
  FROM v
  LEFT JOIN pg_statio_user_sequences io ON io.relid = v.oid
 ORDER BY pct_used DESC NULLS LAST, v.schema_name, v.seq_name
 LIMIT $1`

// dbchecksObjectsSQL: the catalog findings of one database, one row each - kind, the object, a figure where there is one,
// the detail and the line that fixes it (text only: pgvigil never runs it).
const dbchecksObjectsSQL = `
SELECT 'check' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, x.check_kind, x.object, x.figure, x.detail, x.fix_sql
  FROM (
    -- a SECURITY DEFINER function runs as its owner: without its own search_path a caller's objects can stand in for
    -- the ones it names
    SELECT 'secdef' AS check_kind, p.oid::regprocedure::text AS object, NULL::numeric AS figure,
           'owner ' || pg_get_userbyid(p.proowner) AS detail,
           format('ALTER ROUTINE %s SET search_path = pg_catalog, pg_temp;', p.oid::regprocedure::text) AS fix_sql
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}'::text[])) c WHERE c LIKE 'search_path=%')
       AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    UNION ALL
    -- a check or foreign key added NOT VALID and never validated: the planner cannot rely on it, old rows may break it (a
    -- domain's check: ALTER DOMAIN)
    SELECT 'notvalid',
           CASE WHEN k.contypid <> 0 THEN format('domain %s.%s', k.contypid::regtype::text, quote_ident(k.conname))
                ELSE format('%s.%s', k.conrelid::regclass::text, quote_ident(k.conname)) END, NULL::numeric,
           CASE k.contype WHEN 'f' THEN 'foreign key' WHEN 'c' THEN 'check' ELSE k.contype::text END || ': ' || pg_get_constraintdef(k.oid),
           CASE WHEN k.contypid <> 0 THEN format('ALTER DOMAIN %s VALIDATE CONSTRAINT %I;', k.contypid::regtype::text, k.conname)
                ELSE format('ALTER TABLE %s VALIDATE CONSTRAINT %I;', k.conrelid::regclass::text, k.conname) END
      FROM pg_constraint k JOIN pg_namespace n ON n.oid = k.connamespace
     WHERE NOT k.convalidated AND k.contype IN ('c', 'f') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    UNION ALL
    -- a DEFAULT partition holding rows: a partition added later for those values must scan it, and its rows are where no
    -- partition was planned for them
    SELECT 'defpart', p.partdefid::regclass::text, s.n_live_tup::numeric,
           'default partition of ' || p.partrelid::regclass::text || ': ' || s.n_live_tup || ' live rows',
           format('SELECT count(*) FROM %s;  -- then a partition for those values, or a CHECK on the parent', p.partdefid::regclass::text)
      FROM pg_partitioned_table p JOIN pg_stat_user_tables s ON s.relid = p.partdefid
     WHERE p.partdefid <> 0 AND s.n_live_tup > 0
    UNION ALL
    -- every role may create objects in schema public (the default before 15): a CVE-2018-1058 path
    SELECT 'public_create', 'schema public', NULL::numeric, 'PUBLIC holds CREATE on schema public',
           'REVOKE CREATE ON SCHEMA public FROM PUBLIC;'
     WHERE to_regnamespace('public') IS NOT NULL AND has_schema_privilege('public', 'public', 'CREATE')
  ) x`

// dbchecksMD5SQL: the login roles whose password is an MD5 hash. pg_authid is a superuser's read: any other login is
// refused, and the database row says the check was not read.
const dbchecksMD5SQL = `
SELECT 'check' AS kind, 0::bigint AS dbid, NULL::text AS datname, 'md5' AS check_kind, a.rolname::text AS object,
       NULL::numeric AS figure, 'an MD5 password hash (deprecated since 18; SCRAM is the default since 14)' AS detail,
       format('ALTER ROLE %I PASSWORD ''...'';  -- with password_encryption = scram-sha-256', a.rolname) AS fix_sql
  FROM pg_authid a
 WHERE a.rolcanlogin AND a.rolpassword LIKE 'md5%'`

// dbchecksDBSQL: the database read.
const dbchecksDBSQL = `
SELECT 'db' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname`

func (dbchecksCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	return eachDatabase(ctx, conn, in, "dbchecks", func(ctx context.Context, c *pgx.Conn, connected bool) ([]Row, error) {
		out, err := readAll(ctx, c, []namedRead{{"database", dbchecksDBSQL, nil}, {"sequences", dbchecksSequencesSQL, []any{sequencesMax}},
			{"objects", dbchecksObjectsSQL, nil}})
		if err != nil || !connected {
			return out, err
		}
		// the instance's own read, once: refused for a login that is not a superuser
		md5, err := readAll(ctx, c, []namedRead{{"md5", dbchecksMD5SQL, nil}})
		if err != nil {
			var pe *pgconn.PgError
			if !errors.As(err, &pe) || pe.Code != "42501" {
				return nil, err
			}
			out = append(out, Row{"kind": "md5_unread", "message": "pg_authid is a superuser's read: the MD5 check was not made"})
			return out, nil
		}
		out = append(out, Row{"kind": "md5_read"})
		return append(out, md5...), nil
	})
}

// namedRead is one statement of a database's read, named for its error.
type namedRead struct {
	name, sql string
	args      []any
}

// readAll runs the reads on one connection, in order; the first failure fails them all.
func readAll(ctx context.Context, conn *pgx.Conn, reads []namedRead) ([]Row, error) {
	out := []Row{}
	for _, q := range reads {
		r, err := conn.Query(ctx, q.sql, q.args...)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", q.name, err)
		}
		rows, err := rowsToMaps(r)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", q.name, err)
		}
		out = append(out, rows...)
	}
	return out, nil
}

// eachDatabase runs read on the connected database (connected true) and on every other connectable database, each on
// its own connection with the collector's session settings and search_path pg_catalog, up to tablesMaxDatabases (the
// tables collection's bound). A database that cannot be read, and each one past the bound, sends a collector_error row
// '<source>:<db>' so the import keeps that database's rows as they were.
func eachDatabase(ctx context.Context, conn *pgx.Conn, in config.Instance, source string,
	read func(ctx context.Context, c *pgx.Conn, connected bool) ([]Row, error)) ([]Row, error) {
	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return nil, err
	}
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	out := []Row{}
	if len(dbs) > tablesMaxDatabases {
		for _, db := range dbs[tablesMaxDatabases:] {
			out = append(out, Row{"kind": "collector_error", "source": source + ":" + db,
				"message": fmt.Sprintf("%d databases: the first %d by name are read", len(dbs), tablesMaxDatabases)})
		}
		dbs = dbs[:tablesMaxDatabases]
	}
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = readOn(ctx, conn, true, read)
		} else {
			rows, err = readOther(ctx, in, db, read)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": source + ":" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

// readOn sets the read's search_path on a connection this collection owns (RunOnce opens one per run; the others are
// opened in readOther), so it is not put back.
func readOn(ctx context.Context, conn *pgx.Conn, connected bool, read func(ctx context.Context, c *pgx.Conn, connected bool) ([]Row, error)) ([]Row, error) {
	if _, err := conn.Exec(ctx, `SET search_path = pg_catalog`); err != nil {
		return nil, fmt.Errorf("search_path: %w", err)
	}
	return read(ctx, conn, connected)
}

// readOther connects to another database with the instance's DSN and the collector's session settings.
func readOther(ctx context.Context, in config.Instance, db string, read func(ctx context.Context, c *pgx.Conn, connected bool) ([]Row, error)) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := connectCounted(ctx, in.Name, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return readOn(ctx, conn, false, read)
}
