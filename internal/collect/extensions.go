package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// extensionsCollector is the hourly extension read: what the server could install (pg_available_extensions,
// read once on the connected database: the list is the server's), what each connectable database has
// installed (pg_extension, read per database on the per-database connections the tables collection makes,
// under the same cap), the libraries the server loads at start or per session (shared_preload_libraries,
// session_preload_libraries, local_preload_libraries, parsed into names) and the libraries' own settings
// that decide whether a loaded library does anything (pg_hint_plan.enable_hint, auto_explain.log_min_duration,
// pg_stat_statements.track). Everything it reads is visible to pg_monitor (pg_read_all_settings shows the
// preload lists); nothing is installed or changed.
//
// Rows by kind:
//
//	available  name, default_version, comment                    (once)
//	library    name, via (shared | session | local | db_role)     (once)
//	setting    name, setting, unit                               (once; a library's setting exists only while it is loaded)
//	databases  names: every connectable database                 (once; a database not listed is gone)
//	db         dbid, datname                                     (per database read: its installed set is complete)
//	installed  dbid, datname, name, version, schema_name         (per database read)
//
// A database that cannot be read gives a collector_error row and no db row, so the import keeps its last
// installed rows as they were (not read is not "removed").
type extensionsCollector struct{}

func init() { Register(extensionsCollector{}) }

func (extensionsCollector) Name() string                   { return "extensions" }
func (extensionsCollector) DefaultInterval() time.Duration { return time.Hour }
func (extensionsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (extensionsCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("extensions needs the instance config: %w", ErrSkip)
}

// extensionLibrarySettings are the settings of a loaded library that decide whether it works; pg_settings
// lists a custom setting only once its library is loaded in this backend (a preloaded one always is).
// The three preload lists ride along as settings: a list present in the read is one the login could see,
// which tells the import which lists' libraries it can mark gone.
var extensionLibrarySettings = []string{
	"shared_preload_libraries", "session_preload_libraries", "local_preload_libraries",
	"pg_hint_plan.enable_hint", "pg_hint_plan.debug_print",
	"auto_explain.log_min_duration", "auto_explain.log_analyze", "auto_explain.sample_rate",
	"pg_stat_statements.track", "pg_stat_statements.max", "pg_stat_statements.track_utility",
}

const extensionsAvailableSQL = `
SELECT 'available' AS kind, name::text AS name, default_version::text AS default_version, comment::text AS comment
  FROM pg_available_extensions
 ORDER BY name`

// extensionsLibrariesSQL parses the preload lists: comma separated, each entry optionally quoted and optionally a
// path ($libdir/pg_stat_statements, /usr/lib/postgresql/16/lib/auto_explain.so); the name is the file name
// without its directory and suffix, which is what an extension's library is called. The three server lists come
// from pg_settings, which leaves out a list the login may not read (no pg_read_all_settings) instead of raising
// an error, as current_setting would. The fourth source, via db_role, is every ALTER DATABASE / ALTER ROLE ... SET
// session_preload_libraries or local_preload_libraries in pg_db_role_setting (readable by any login): a library
// loaded that way works in that database or for that role though the server's lists do not name it.
const extensionsLibrariesSQL = `
WITH lists AS (
  SELECT CASE s.name WHEN 'shared_preload_libraries' THEN 'shared' WHEN 'session_preload_libraries' THEN 'session' ELSE 'local' END AS via,
         s.setting AS list
    FROM pg_settings s
   WHERE s.name IN ('shared_preload_libraries', 'session_preload_libraries', 'local_preload_libraries')
  UNION ALL
  SELECT 'db_role', substr(c.cfg, strpos(c.cfg, '=') + 1)
    FROM pg_db_role_setting r CROSS JOIN LATERAL unnest(r.setconfig) c(cfg)
   WHERE c.cfg LIKE 'session\_preload\_libraries=%' OR c.cfg LIKE 'local\_preload\_libraries=%'
)
SELECT DISTINCT 'library' AS kind, regexp_replace(regexp_replace(btrim(e.lib, ' "'), '^.*[/\\]', ''), '\.(so|dll|dylib)$', '') AS name,
       l.via
  FROM lists l CROSS JOIN LATERAL regexp_split_to_table(coalesce(l.list, ''), ',') e(lib)
 WHERE btrim(e.lib, ' "') <> ''`

// extensionsDBRoleSQL is the ALTER DATABASE / ROLE preload settings as one setting row (empty when there are
// none): the import tracks its changes, and its presence says the db_role source was read.
const extensionsDBRoleSQL = `
SELECT 'setting' AS kind, 'db_role_preload_libraries' AS name,
       coalesce((SELECT string_agg(coalesce(d.datname, '*') || '/' || coalesce(a.rolname, '*') || ': ' || c.cfg, '; '
                                   ORDER BY d.datname NULLS FIRST, a.rolname NULLS FIRST, c.cfg)
                   FROM pg_db_role_setting r CROSS JOIN LATERAL unnest(r.setconfig) c(cfg)
                   LEFT JOIN pg_database d ON d.oid = r.setdatabase
                   LEFT JOIN pg_roles a ON a.oid = r.setrole
                  WHERE c.cfg LIKE 'session\_preload\_libraries=%' OR c.cfg LIKE 'local\_preload\_libraries=%'), '') AS setting,
       NULL::text AS unit`

const extensionsSettingsSQL = `
SELECT 'setting' AS kind, name::text AS name, setting::text AS setting, unit::text AS unit
  FROM pg_settings
 WHERE name = ANY($1)
 ORDER BY name`

const extensionsInstalledSQL = `
SELECT 'installed' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, e.extname::text AS name, e.extversion::text AS version,
       n.nspname::text AS schema_name
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
 ORDER BY e.extname`

// RunInstance reads the server-wide lists on conn, then pg_extension on conn's database and on every other
// connectable database (its own short connection), up to tablesMaxDatabases.
func (extensionsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	out := []Row{}
	for _, q := range []struct {
		sql  string
		args []any
	}{{extensionsAvailableSQL, nil}, {extensionsLibrariesSQL, nil}, {extensionsDBRoleSQL, nil},
		{extensionsSettingsSQL, []any{extensionLibrarySettings}}} {
		r, err := conn.Query(ctx, q.sql, q.args...)
		if err != nil {
			return nil, err
		}
		rows, err := rowsToMaps(r)
		if err != nil {
			return nil, err
		}
		out = append(out, rows...)
	}

	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return nil, err
	}
	names := make([]string, len(dbs))
	copy(names, dbs)
	out = append(out, Row{"kind": "databases", "names": names})
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	if len(dbs) > tablesMaxDatabases {
		out = append(out, Row{"kind": "collector_error", "source": "extensions",
			"message": fmt.Sprintf("%d databases: the first %d by name are read (tablesMaxDatabases)", len(dbs), tablesMaxDatabases)})
		dbs = dbs[:tablesMaxDatabases]
	}
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = extensionsRead(ctx, conn)
		} else {
			rows, err = extensionsReadOther(ctx, in, db)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": "extensions:" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

// extensionsRead lists one database's installed extensions, led by its db row (the read is complete).
func extensionsRead(ctx context.Context, conn *pgx.Conn) ([]Row, error) {
	var dbid int64
	var datname string
	if err := conn.QueryRow(ctx, `SELECT oid::bigint, datname::text FROM pg_database WHERE datname = current_database()`).Scan(&dbid, &datname); err != nil {
		return nil, fmt.Errorf("database: %w", err)
	}
	r, err := conn.Query(ctx, extensionsInstalledSQL)
	if err != nil {
		return nil, fmt.Errorf("pg_extension: %w", err)
	}
	rows, err := rowsToMaps(r)
	if err != nil {
		return nil, fmt.Errorf("pg_extension: %w", err)
	}
	return append([]Row{{"kind": "db", "dbid": dbid, "datname": datname}}, rows...), nil
}

// extensionsReadOther connects to another database with the instance's DSN and the collector's session
// settings, reads it, and closes the connection.
func extensionsReadOther(ctx context.Context, in config.Instance, db string) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return extensionsRead(ctx, conn)
}
