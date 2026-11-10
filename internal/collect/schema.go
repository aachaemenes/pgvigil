package collect

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// schemaCollector is the hourly schema snapshot (task 59, DBADash's DDL change tracking): per connectable database,
// one row per object of the database's own schemas (schemas, tables with each column as its own object, indexes,
// constraints, triggers, functions and procedures, views, materialized views and sequences), each with its definition
// as text, its owner and its ACL, and a hash of the three. The import (0058, import_schema) diffs the read against the
// stored one: an object added, dropped, or changed, with the before and after text of the changed attribute.
//
// The identity of an object is pg_identify_object()'s (public.t, public.t.col, t_pkey on public.t,
// public.f(integer)): the same text an event trigger's pg_event_trigger_ddl_commands() and
// pg_event_trigger_dropped_objects() give, so a captured statement matches its diff row.
//
// Left out: the catalog schemas (pg_catalog, information_schema, pg_toast*, pg_temp*), temporary relations, objects
// that belong to an extension (pg_depend deptype 'e': their DDL is the extension's, its version is the Extensions
// tab's), aggregates, and PostgreSQL 18's NOT NULL constraints (the column's own definition carries NOT NULL).
// A function's body is read as text and hashed here (SHA-256, Go's crypto: no md5() on a FIPS server): the
// definition holds the signature, language, volatility, security and settings, then "body sha256:<16 hex>".
//
// Every read is pg_monitor's: the catalogs and pg_get_*def are readable by every role.
//
// The opt-in exact statement: SchemaDDLLogSQL is the event trigger the server's DBA installs as a superuser (printed,
// commented out, by 'pgvigil roles'); where its table pgvigil_ddl_log is present and readable, the collector reads the
// rows logged since its cursor (one hour of overlap, the import keeps a row once), and the Schema tab shows the
// statement beside the diff. Where it is absent the database's row says 'not installed'.
type schemaCollector struct{}

func init() { Register(schemaCollector{}) }

func (schemaCollector) Name() string                   { return "schema" }
func (schemaCollector) DefaultInterval() time.Duration { return time.Hour }
func (schemaCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (schemaCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("schema runs per instance (RunInstance)")
}

// schemaMaxObjects caps the objects read per database: a database over it is reported as a collector error and its
// stored snapshot stays as it was (a partial read would show every object past the cap as dropped). A var: tests lower it.
var schemaMaxObjects = 50000

// schemaMaxDef cuts a stored definition (a long view or default); the hash is taken over the whole text first.
const schemaMaxDef = 20000

// schemaDDLPage is one page of the event-trigger read; schemaDDLMax caps the rows one run reads per database (vars:
// tests lower them; PGVIGIL_SCHEMA_DDL_MAX lowers the cap for the proof). A run that reaches the cap hands the import a cursor just before its last row, so the next run
// goes on from there (the one hour of overlap would otherwise re-read the same full window for ever).
var (
	schemaDDLPage = 5000
	schemaDDLMax  = 50000
)

// schemaDBSQL: the database read; read_at is the server's own clock just before the objects are read (the event
// trigger's logged_at is on the same clock, so a statement is matched to the read that found its change without a
// second clock's skew).
const schemaDBSQL = `
SELECT 'db' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, now() AS read_at`

// schemaObjectsSQL: every object of the database's own schemas, one row each; $1 is the cap plus one.
const schemaObjectsSQL = `
WITH ext AS (SELECT classid, objid FROM pg_depend WHERE deptype = 'e'),
ns AS (
  SELECT n.oid, n.nspname, n.nspowner, n.nspacl FROM pg_namespace n
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp_|toast_temp_)'
     AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_namespace'::regclass AND ext.objid = n.oid)),
rel AS (
  SELECT c.oid, c.relname, c.relkind, c.relpersistence, c.relowner, c.relacl, c.reloptions, c.relispartition,
         c.relrowsecurity, c.reltablespace, c.relpartbound, n.nspname,
         (pg_identify_object('pg_class'::regclass, c.oid, 0)).identity AS ident
    FROM pg_class c JOIN ns n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S', 'i', 'I') AND c.relpersistence <> 't'
     AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_class'::regclass AND ext.objid = c.oid)),
obj AS (
  SELECT 'schema' AS okind, (pg_identify_object('pg_namespace'::regclass, n.oid, 0)).identity AS identity,
         n.nspname::text AS schema_name, n.nspname::text AS object_name, NULL::text AS parent,
         'schema'::text AS definition, pg_get_userbyid(n.nspowner)::text AS owner, n.nspacl::text AS acl, NULL::text AS body
    FROM ns n
  UNION ALL
  SELECT 'table', c.ident, c.nspname, c.relname, NULL,
         concat_ws(' ',
           CASE c.relkind WHEN 'p' THEN 'partitioned table by ' || pg_get_partkeydef(c.oid) WHEN 'f' THEN 'foreign table'
                ELSE CASE c.relpersistence WHEN 'u' THEN 'unlogged table' ELSE 'table' END END,
           CASE WHEN c.relispartition THEN 'partition of ' ||
             (SELECT h.inhparent::regclass::text FROM pg_inherits h WHERE h.inhrelid = c.oid LIMIT 1) || ' ' || pg_get_expr(c.relpartbound, c.oid) END,
           CASE WHEN c.reloptions IS NOT NULL THEN 'with (' || array_to_string(c.reloptions, ', ') || ')' END,
           CASE WHEN c.reltablespace <> 0 THEN 'tablespace ' || (SELECT t.spcname FROM pg_tablespace t WHERE t.oid = c.reltablespace) END,
           CASE WHEN c.relrowsecurity THEN 'row level security' END),
         pg_get_userbyid(c.relowner), c.relacl::text, NULL
    FROM rel c WHERE c.relkind IN ('r', 'p', 'f')
  UNION ALL
  SELECT 'column', (pg_identify_object('pg_class'::regclass, c.oid, a.attnum)).identity, c.nspname, a.attname, c.ident,
         concat_ws(' ', format_type(a.atttypid, a.atttypmod),
           CASE WHEN a.attcollation <> 0 AND a.attcollation <> (SELECT t.typcollation FROM pg_type t WHERE t.oid = a.atttypid)
                THEN 'collate ' || (SELECT quote_ident(co.collname) FROM pg_collation co WHERE co.oid = a.attcollation) END,
           CASE WHEN a.attnotnull THEN 'not null' END,
           CASE a.attidentity WHEN 'a' THEN 'generated always as identity' WHEN 'd' THEN 'generated by default as identity' END,
           CASE WHEN a.attgenerated = 's' THEN 'generated always as (' || pg_get_expr(d.adbin, d.adrelid) || ') stored'
                WHEN a.attgenerated = 'v' THEN 'generated always as (' || pg_get_expr(d.adbin, d.adrelid) || ') virtual'
                WHEN d.adbin IS NOT NULL THEN 'default ' || pg_get_expr(d.adbin, d.adrelid) END),
         NULL, a.attacl::text, NULL
    FROM rel c
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE c.relkind IN ('r', 'p', 'f')
  UNION ALL
  SELECT 'index', c.ident, c.nspname, c.relname, t.ident,
         pg_get_indexdef(c.oid) || CASE WHEN NOT i.indisvalid THEN ' (INVALID)' ELSE '' END, NULL, NULL, NULL
    FROM rel c JOIN pg_index i ON i.indexrelid = c.oid JOIN rel t ON t.oid = i.indrelid
   WHERE c.relkind IN ('i', 'I')
  UNION ALL
  SELECT 'constraint', (pg_identify_object('pg_constraint'::regclass, k.oid, 0)).identity, c.nspname, k.conname, c.ident,
         pg_get_constraintdef(k.oid) || CASE WHEN NOT k.convalidated THEN ' NOT VALID' ELSE '' END, NULL, NULL, NULL
    FROM pg_constraint k JOIN rel c ON c.oid = k.conrelid
   WHERE k.contype <> 'n'
  UNION ALL
  SELECT 'trigger', (pg_identify_object('pg_trigger'::regclass, g.oid, 0)).identity, c.nspname, g.tgname, c.ident,
         pg_get_triggerdef(g.oid) || CASE g.tgenabled WHEN 'D' THEN ' (DISABLED)' WHEN 'R' THEN ' (REPLICA)' WHEN 'A' THEN ' (ALWAYS)' ELSE '' END,
         NULL, NULL, NULL
    FROM pg_trigger g JOIN rel c ON c.oid = g.tgrelid
   WHERE NOT g.tgisinternal
  UNION ALL
  SELECT CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END,
         (pg_identify_object('pg_proc'::regclass, p.oid, 0)).identity, n.nspname, p.proname, NULL,
         concat_ws(' ', CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'w' THEN 'window function' ELSE 'function' END,
           '(' || pg_get_function_arguments(p.oid) || ')',
           CASE WHEN p.prokind <> 'p' THEN 'returns ' || pg_get_function_result(p.oid) END,
           'language ' || l.lanname,
           CASE p.provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' ELSE 'volatile' END,
           CASE WHEN p.proisstrict THEN 'strict' END,
           CASE WHEN p.prosecdef THEN 'security definer' END,
           CASE WHEN p.proleakproof THEN 'leakproof' END,
           CASE p.proparallel WHEN 's' THEN 'parallel safe' WHEN 'r' THEN 'parallel restricted' END,
           CASE WHEN p.prokind <> 'p' THEN 'cost ' || p.procost END,
           CASE WHEN p.proretset THEN 'rows ' || p.prorows END,
           CASE WHEN p.proconfig IS NOT NULL THEN 'set ' || array_to_string(p.proconfig, ', ') END),
         pg_get_userbyid(p.proowner), p.proacl::text, coalesce(p.prosrc, '') || coalesce(' ' || p.probin, '')
    FROM pg_proc p JOIN ns n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
   WHERE p.prokind IN ('f', 'p', 'w')
     AND NOT EXISTS (SELECT 1 FROM ext WHERE ext.classid = 'pg_proc'::regclass AND ext.objid = p.oid)
  UNION ALL
  SELECT CASE c.relkind WHEN 'm' THEN 'materialized view' ELSE 'view' END, c.ident, c.nspname, c.relname, NULL,
         pg_get_viewdef(c.oid, true), pg_get_userbyid(c.relowner), c.relacl::text, NULL
    FROM rel c WHERE c.relkind IN ('v', 'm')
  UNION ALL
  SELECT 'sequence', c.ident, c.nspname, c.relname,
         (SELECT (pg_identify_object('pg_class'::regclass, dp.refobjid, 0)).identity
            FROM pg_depend dp
           WHERE dp.classid = 'pg_class'::regclass AND dp.objid = c.oid AND dp.refclassid = 'pg_class'::regclass
             AND dp.deptype IN ('a', 'i') AND dp.refobjsubid > 0 LIMIT 1),
         concat_ws(' ', 'sequence', format_type(s.seqtypid, NULL), 'start', s.seqstart, 'increment', s.seqincrement,
           'min', s.seqmin, 'max', s.seqmax, 'cache', s.seqcache, CASE WHEN s.seqcycle THEN 'cycle' END,
           (SELECT 'owned by ' || (pg_identify_object('pg_class'::regclass, dp.refobjid, dp.refobjsubid)).identity
              FROM pg_depend dp
             WHERE dp.classid = 'pg_class'::regclass AND dp.objid = c.oid AND dp.refclassid = 'pg_class'::regclass
               AND dp.deptype IN ('a', 'i') AND dp.refobjsubid > 0 LIMIT 1)),
         pg_get_userbyid(c.relowner), c.relacl::text, NULL
    FROM rel c JOIN pg_sequence s ON s.seqrelid = c.oid
)
SELECT 'obj' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, okind AS object_kind, identity, schema_name, object_name, parent,
       definition, owner, acl, body
  FROM obj
 ORDER BY okind, identity
 LIMIT $1`

// schemaDDLStateSQL finds the event trigger's table (any schema, public first) and its two event triggers.
const schemaDDLStateSQL = `
SELECT (SELECT c.oid::regclass::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relname = 'pgvigil_ddl_log' AND c.relkind IN ('r', 'p') ORDER BY n.nspname <> 'public', n.nspname LIMIT 1) AS tbl,
       (SELECT has_table_privilege(c.oid, 'SELECT') AND has_schema_privilege(n.oid, 'USAGE') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relname = 'pgvigil_ddl_log' AND c.relkind IN ('r', 'p') ORDER BY n.nspname <> 'public', n.nspname LIMIT 1) AS readable,
       (SELECT count(*) FROM pg_event_trigger e
         WHERE e.evtname IN ('pgvigil_ddl_end', 'pgvigil_ddl_drop') AND e.evtenabled <> 'D')::int AS triggers`

// schemaDDLReadSQL reads one page of the log: the first page from the cursor less one hour (a transaction that
// commits late keeps its earlier clock_timestamp; the import keeps a row once), or the last day on the first read;
// each next page after the last row read ($2, $3: logged_at, log_id). %s is the table as regclass prints it (quoted by
// the server), %d the page size.
const schemaDDLReadSQL = `
SELECT 'ddl' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, log_id::bigint AS log_id, logged_at, event::text AS event,
       command_tag::text AS command_tag, object_type::text AS object_type, schema_name::text AS schema_name,
       object_identity::text AS object_identity, role_name::text AS role_name, statement::text AS statement
  FROM %s
 WHERE ($2::timestamptz IS NULL AND logged_at > coalesce($1::timestamptz - interval '1 hour', now() - interval '1 day'))
    OR ($2::timestamptz IS NOT NULL AND (logged_at, log_id) > ($2::timestamptz, $3::bigint))
 ORDER BY logged_at, log_id
 LIMIT %d`

// SchemaDDLLogSQL is the opt-in event trigger, printed by 'pgvigil roles' for the server's DBA (commented out). It is
// installed per database, as a superuser (only a superuser creates an event trigger), in one transaction: the guard at
// its top stops the whole block in a database with a FOR ALL TABLES publication (or, PostgreSQL 15+, a publication of
// the schema public), which the new table would join, stopping every subscriber that lacks it. The capture never fails
// the DDL it records (any error inside it becomes a WARNING) and waits at most one second for its own table (its
// lock_timeout). The statement kept is the client's query text (every statement sent together, cut at 10,000
// characters), except where it may carry a password: CREATE and ALTER of a SERVER, USER MAPPING or SUBSCRIPTION, and
// any text that names a password or a secret, are kept as '(statement not kept: it may carry a password)'.
// Temporary objects and the commands an extension's script runs are not logged (the snapshot leaves both out, and a
// temp table per request would fill the table). <login> is the monitoring login's role.
const SchemaDDLLogSQL = `BEGIN;   -- pgvigil_ddl_log: one transaction (the guard's error stops the whole block)
-- SELECT set_config('pgvigil.publication_ok', 'on', true);   -- only after public.pgvigil_ddl_log exists on every subscriber
DO $guard$
DECLARE n bigint;
BEGIN
  IF coalesce(current_setting('pgvigil.publication_ok', true), '') = 'on' THEN RETURN; END IF;
  SELECT count(*) INTO n FROM pg_catalog.pg_publication WHERE puballtables;
  IF n = 0 AND to_regclass('pg_catalog.pg_publication_namespace') IS NOT NULL THEN   -- PostgreSQL 15+
    EXECUTE 'SELECT count(*) FROM pg_catalog.pg_publication_namespace p JOIN pg_catalog.pg_namespace s ON s.oid = p.pnnspid'
         || ' WHERE s.nspname = ''public''' INTO n;
  END IF;
  IF n > 0 THEN
    RAISE EXCEPTION 'pgvigil_ddl_log: a publication of all tables (or of the schema public) exists here; the new table would join it and stop every subscriber without it. Create public.pgvigil_ddl_log on each subscriber first and run the block with its set_config line uncommented, or do not install.';
  END IF;
END $guard$;
CREATE TABLE public.pgvigil_ddl_log (
  log_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  logged_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  event           text NOT NULL,                 -- ddl_command_end | sql_drop
  command_tag     text NOT NULL,
  object_type     text,
  schema_name     text,
  object_identity text,                          -- pg_identify_object's text (NULL for GRANT and REVOKE)
  role_name       text NOT NULL DEFAULT session_user,
  statement       text                           -- the client's query text (every statement sent together), cut at 10,000 characters
);
CREATE INDEX pgvigil_ddl_log_at ON public.pgvigil_ddl_log (logged_at);
REVOKE ALL ON public.pgvigil_ddl_log FROM PUBLIC;
GRANT SELECT ON public.pgvigil_ddl_log TO <login>;
CREATE FUNCTION public.pgvigil_ddl_capture() RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp SET lock_timeout = '1s' AS $f$
DECLARE r record; q text;
BEGIN
  q := left(current_query(), 10000);
  IF TG_TAG IN ('CREATE SERVER', 'ALTER SERVER', 'CREATE USER MAPPING', 'ALTER USER MAPPING', 'CREATE SUBSCRIPTION',
                'ALTER SUBSCRIPTION') OR current_query() ~* '(password|secret)' THEN
    q := '(statement not kept: it may carry a password)';
  END IF;
  IF TG_EVENT = 'ddl_command_end' THEN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
              WHERE NOT in_extension AND schema_name IS DISTINCT FROM 'pg_temp' LOOP
      INSERT INTO public.pgvigil_ddl_log (event, command_tag, object_type, schema_name, object_identity, statement)
      VALUES (TG_EVENT, r.command_tag, r.object_type, r.schema_name, r.object_identity, q);
    END LOOP;
  ELSE
    FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() WHERE original AND NOT is_temporary LOOP
      INSERT INTO public.pgvigil_ddl_log (event, command_tag, object_type, schema_name, object_identity, statement)
      VALUES (TG_EVENT, TG_TAG, r.object_type, r.schema_name, r.object_identity, q);
    END LOOP;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'pgvigil_ddl_capture: %', SQLERRM;
END $f$;
REVOKE ALL ON FUNCTION public.pgvigil_ddl_capture() FROM PUBLIC;
CREATE EVENT TRIGGER pgvigil_ddl_end ON ddl_command_end EXECUTE FUNCTION public.pgvigil_ddl_capture();
CREATE EVENT TRIGGER pgvigil_ddl_drop ON sql_drop EXECUTE FUNCTION public.pgvigil_ddl_capture();
COMMIT;  -- pgvigil_ddl_log
-- the undo:
-- DROP EVENT TRIGGER pgvigil_ddl_end; DROP EVENT TRIGGER pgvigil_ddl_drop;
-- DROP FUNCTION public.pgvigil_ddl_capture(); DROP TABLE public.pgvigil_ddl_log;
-- the table grows with every DDL statement: keep it in check with, say, a monthly
-- DELETE FROM public.pgvigil_ddl_log WHERE logged_at < now() - interval '90 days';
-- (DELETE only: a TRUNCATE, VACUUM FULL or ALTER of the table locks it, and every DDL statement waits up to a second
-- behind that, then runs without its log row)
-- a FOR ALL TABLES publication created later takes the table too: create it on every subscriber first`

// BatchRunner is an InstanceRunner whose rows go to the import in parts, one import call each, in order (RunOnce
// calls runBatched for it): a collection too large for one jsonb payload (PostgreSQL refuses an array over 256 MB; the
// schema collection reaches that near 800,000 objects) imports part by part and never holds the whole instance.
type BatchRunner interface {
	RunBatches(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, cursor CursorFunc, emit func([]Row) error) error
}

// runBatched is RunOnce's path for a BatchRunner: each part through the instance's text policy into the import, the
// collection's log line from the parts' collector_error rows. A part's failed import is the collector's to report (the
// next parts go on); an error returned by RunBatches fails the run.
func runBatched(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string, br BatchRunner,
	conn *pgx.Conn, info platform.Info, instanceID int, start time.Time) Result {
	n, parts := 0, 0
	status, note := "ok", ""
	err := br.RunBatches(ctx, conn, info, in, func(ctx context.Context, source string) (time.Time, bool, error) {
		return r.LogCursor(ctx, instanceID, source)
	}, func(rows []Row) error {
		applyTextPolicy(rows, in.QueryText)
		if err := r.Import(ctx, instanceID, name, start, rows); err != nil {
			return err
		}
		n += len(rows)
		parts++
		for _, row := range rows {
			if row["kind"] == "collector_error" && status == "ok" {
				status, note = "partial", fmt.Sprintf("%v: %v", row["source"], row["message"])
			}
		}
		return nil
	})
	if err != nil {
		_ = r.LogCollection(ctx, instanceID, name, start, time.Since(start), "error", err.Error())
		return Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	d := time.Since(start)
	_ = r.LogCollection(ctx, instanceID, name, start, d, status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", n, "imports", parts, "ms", d.Milliseconds())
	return Result{Rows: n, Duration: d}
}

// schemaMaxPayload caps one import call's payload, estimated (schemaPayloadSize), well under PostgreSQL's 256 MB jsonb
// array limit. A database whose objects pass it is a collector error (its stored snapshot stays); its event-trigger
// rows go in parts under it. PGVIGIL_SCHEMA_MAX_PAYLOAD (bytes) lowers it for the proof.
var schemaMaxPayload = 160 << 20

// schemaEnvInt reads a positive integer override from the environment (the proof's hidden caps).
func schemaEnvInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

// schemaPayloadSize estimates a part's size as jsonb holds it: each key and string value, plus a fixed cost per value
// and per row.
func schemaPayloadSize(rows []Row) int {
	n := 0
	for _, r := range rows {
		n += 16
		for k, v := range r {
			n += len(k) + 8
			if s, ok := v.(string); ok {
				n += len(s)
			} else {
				n += 16
			}
		}
	}
	return n
}

// schemaSplit cuts rows into parts of at most limit bytes each (a row over it is a part of its own).
func schemaSplit(rows []Row, limit int) [][]Row {
	var parts [][]Row
	start, size := 0, 0
	for i, r := range rows {
		rs := schemaPayloadSize([]Row{r})
		if i > start && size+rs > limit {
			parts = append(parts, rows[start:i])
			start, size = i, 0
		}
		size += rs
	}
	if start < len(rows) {
		parts = append(parts, rows[start:])
	}
	return parts
}

// RunBatches reads the connected database on conn and every other connectable database on its own connection, up to
// tablesMaxDatabases (the tables collection's bound), and hands the import each database on its own: its event-trigger
// rows (in parts under schemaMaxPayload, the cursor row in the last), then its database row and objects. The last call
// carries every database's collector_error row, a 'seen' row per database read and the 'end' row: only that call
// marks a database neither read nor in error as gone.
func (schemaCollector) RunBatches(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, cursor CursorFunc, emit func([]Row) error) error {
	maxPayload := schemaEnvInt("PGVIGIL_SCHEMA_MAX_PAYLOAD", schemaMaxPayload)
	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return err
	}
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return err
	}
	final := []Row{}
	dbErr := func(db, msg string) {
		final = append(final, Row{"kind": "collector_error", "source": "schema:" + db, "message": msg})
	}
	if len(dbs) > tablesMaxDatabases {
		// one error row per database left out, so the import keeps its snapshot as it was instead of marking it gone
		for _, db := range dbs[tablesMaxDatabases:] {
			dbErr(db, fmt.Sprintf("%d databases: the first %d by name are read", len(dbs), tablesMaxDatabases))
		}
		dbs = dbs[:tablesMaxDatabases]
	}
	for _, db := range dbs {
		var since *time.Time
		if cursor != nil {
			if t, ok, err := cursor(ctx, "schema_ddl:"+db); err == nil && ok {
				since = &t
			}
		}
		var rows []Row
		var readErr error
		if db == cur {
			rows, readErr = schemaRead(ctx, conn, since)
		} else {
			rows, readErr = schemaReadOther(ctx, in, db, since)
		}
		if readErr != nil && ctx.Err() != nil {
			return ctx.Err()
		}
		var objs, ddl []Row
		for _, r := range rows {
			switch r["kind"] {
			case "ddl", "ddl_cursor":
				ddl = append(ddl, r)
			default:
				objs = append(objs, r)
			}
		}
		// the event trigger's rows go in even beside a failed object read; a failed part stops the rest (the cursor
		// moves with what was imported, so a later part never skips an earlier one)
		for _, part := range schemaSplit(ddl, maxPayload) {
			if err := emit(part); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				dbErr(db, "import of the event trigger's rows: "+err.Error())
				break
			}
		}
		switch {
		case readErr != nil:
			dbErr(db, readErr.Error())
			continue
		case schemaPayloadSize(objs) > maxPayload:
			dbErr(db, fmt.Sprintf("about %d MB of definitions, over the %d MB one import takes: the database is not snapshotted",
				schemaPayloadSize(objs)>>20, maxPayload>>20))
			continue
		}
		if err := emit(objs); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			dbErr(db, "import: "+err.Error())
			continue
		}
		if len(objs) > 0 {
			final = append(final, Row{"kind": "seen", "dbid": objs[0]["dbid"], "datname": db})
		}
	}
	return emit(append(final, Row{"kind": "end"}))
}

// RunInstance is the one-payload form (RunOnce without the batch path, and the tests): every part in one slice. A
// whole over schemaMaxPayload fails, as PostgreSQL would refuse it.
func (c schemaCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, cursor CursorFunc) ([]Row, error) {
	var out []Row
	if err := c.RunBatches(ctx, conn, info, in, cursor, func(rows []Row) error {
		out = append(out, rows...)
		return nil
	}); err != nil {
		return nil, err
	}
	if n, limit := schemaPayloadSize(out), schemaEnvInt("PGVIGIL_SCHEMA_MAX_PAYLOAD", schemaMaxPayload); n > limit {
		return nil, fmt.Errorf("the instance's schema read is about %d MB in one payload, over the %d MB one import takes (RunOnce's batch path imports per database)", n>>20, limit>>20)
	}
	return out, nil
}

// schemaRead reads one database: the objects in one repeatable-read, read-only transaction (all or nothing: a failure
// or a database over the cap fails the database, so its stored snapshot stays; read_at is that transaction's now(),
// the moment its snapshot stands for), then the event trigger's state and rows. A failure of the trigger's read is
// noted on the database's row and the objects still count; a failure of the objects read still returns the trigger's
// rows, with the error.
func schemaRead(ctx context.Context, conn *pgx.Conn, since *time.Time) ([]Row, error) {
	if _, err := conn.Exec(ctx, `SET search_path = pg_catalog`); err != nil {
		return nil, fmt.Errorf("search_path: %w", err)
	}
	db, objs, objErr := schemaObjects(ctx, conn)
	ddl, status, table, note := schemaDDL(ctx, conn, since)
	if objErr != nil {
		return ddl, objErr
	}
	db["ddl_log"], db["ddl_log_table"] = status, table
	if note != "" {
		db["ddl_log_note"] = note
	}
	out := make([]Row, 0, len(objs)+len(ddl)+1)
	out = append(out, db)
	out = append(out, objs...)
	return append(out, ddl...), nil
}

// schemaObjects reads the database row and its objects in one snapshot.
func schemaObjects(ctx context.Context, conn *pgx.Conn) (Row, []Row, error) {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, nil, fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	r, err := tx.Query(ctx, schemaDBSQL)
	if err != nil {
		return nil, nil, fmt.Errorf("database: %w", err)
	}
	dbRows, err := rowsToMaps(r)
	if err != nil {
		return nil, nil, fmt.Errorf("database: %w", err)
	}
	if len(dbRows) != 1 {
		return nil, nil, fmt.Errorf("database: %d rows", len(dbRows))
	}
	r, err = tx.Query(ctx, schemaObjectsSQL, schemaMaxObjects+1)
	if err != nil {
		return nil, nil, fmt.Errorf("objects: %w", err)
	}
	objs, err := rowsToMaps(r)
	if err != nil {
		return nil, nil, fmt.Errorf("objects: %w", err)
	}
	if len(objs) > schemaMaxObjects {
		return nil, nil, fmt.Errorf("over %d objects: the database is not snapshotted (schemaMaxObjects)", schemaMaxObjects)
	}
	schemaFinish(objs)
	dbRows[0]["objects"] = len(objs)
	return dbRows[0], objs, nil
}

// schemaDDL reads the event trigger's state and its rows since the cursor, page by page up to schemaDDLMax. status:
// 'installed', 'not installed' (no pgvigil_ddl_log table), 'no event trigger' (the table without its two enabled event
// triggers: its rows are still read), 'not readable' (the login lacks SELECT on it or USAGE on its schema).
func schemaDDL(ctx context.Context, conn *pgx.Conn, since *time.Time) (rows []Row, status, table, note string) {
	var tbl *string
	var readable *bool
	var triggers int
	if err := conn.QueryRow(ctx, schemaDDLStateSQL).Scan(&tbl, &readable, &triggers); err != nil {
		return nil, "not installed", "", "the event trigger's state: " + err.Error()
	}
	if tbl == nil {
		return nil, "not installed", "", ""
	}
	if readable == nil || !*readable {
		return nil, "not readable", *tbl, "the monitoring login has no SELECT on " + *tbl + " or no USAGE on its schema"
	}
	status = "installed"
	if triggers < 2 {
		status = "no event trigger"
	}
	maxRows := schemaEnvInt("PGVIGIL_SCHEMA_DDL_MAX", schemaDDLMax)
	pageRows := min(schemaDDLPage, maxRows)
	q := fmt.Sprintf(schemaDDLReadSQL, *tbl, pageRows)
	var afterAt *time.Time
	var afterID *int64
	for {
		r, err := conn.Query(ctx, q, since, afterAt, afterID)
		if err != nil {
			return rows, status, *tbl, "read " + *tbl + ": " + err.Error()
		}
		page, err := rowsToMaps(r)
		if err != nil {
			return rows, status, *tbl, "read " + *tbl + ": " + err.Error()
		}
		rows = append(rows, page...)
		if len(page) < pageRows {
			return rows, status, *tbl, ""
		}
		last := page[len(page)-1]
		at, okAt := last["logged_at"].(time.Time)
		id, okID := last["log_id"].(int64)
		if !okAt || !okID {
			return rows, status, *tbl, "read " + *tbl + ": a row without logged_at or log_id"
		}
		afterAt, afterID = &at, &id
		if len(rows) >= maxRows {
			dat, _ := last["datname"].(string)
			rows = append(rows, schemaDDLCursor(dat, at))
			return rows, status, *tbl, fmt.Sprintf("over %d rows in one read: the rest comes with the next runs", maxRows)
		}
	}
}

// schemaDDLCursor is the cursor row a capped read hands the import: one hour (the next read's overlap) less a
// microsecond past the last row read, so the next run starts at that row (read again, kept once) and goes on.
func schemaDDLCursor(datname string, last time.Time) Row {
	return Row{"kind": "ddl_cursor", "datname": datname, "read_to": last.Add(time.Hour - time.Microsecond)}
}

// schemaFinish turns each object row into its stored shape: a function's body becomes its hash at the end of the
// definition, the hash of kind, definition, owner and ACL is added, and a definition over schemaMaxDef is cut (after
// hashing, so a change past the cut still shows as a change).
func schemaFinish(objs []Row) {
	for _, o := range objs {
		def, _ := o["definition"].(string)
		if body, ok := o["body"].(string); ok {
			sum := sha256.Sum256([]byte(body))
			def += " body sha256:" + hex.EncodeToString(sum[:])[:16]
		}
		delete(o, "body")
		owner, _ := o["owner"].(string)
		acl, _ := o["acl"].(string)
		kind, _ := o["object_kind"].(string)
		h := sha256.New()
		for _, s := range []string{kind, def, owner, acl} {
			h.Write([]byte(s))
			h.Write([]byte{0})
		}
		o["hash"] = hex.EncodeToString(h.Sum(nil))
		// the definition's own hash: a change past the cut is seen even when the owner or ACL changed with it
		dh := sha256.Sum256([]byte(def))
		o["def_hash"] = hex.EncodeToString(dh[:])
		o["definition"] = schemaCut(def, schemaMaxDef)
	}
}

// schemaCut keeps the first limit characters of s (never splitting a character) and says it was cut.
func schemaCut(s string, limit int) string {
	if utf8.RuneCountInString(s) <= limit {
		return s
	}
	var b strings.Builder
	n := 0
	for _, r := range s {
		if n == limit {
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String() + " ... (cut at " + fmt.Sprint(limit) + " characters)"
}

// schemaReadOther connects to another database with the instance's DSN and the collector's session settings.
func schemaReadOther(ctx context.Context, in config.Instance, db string, since *time.Time) ([]Row, error) {
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
	return schemaRead(ctx, conn, since)
}
