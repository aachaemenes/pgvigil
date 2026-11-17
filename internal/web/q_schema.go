package web

import (
	"errors"
	"net/http"
	"strconv"
	"time"
)

// The Schema tab (task 59): GET /api/schema?instance=<id>&[from=&to=]&[db=<dbid>] (Server.Schema): the schema
// collection's last run (collection_dates), the databases it snapshots (objects, the event trigger's state, the changes
// in the window), the changes of the window with the statement the event trigger captured
// (pgvigil.schema_changes_window, 0058), the event trigger's own log of the window, and the instance's schema
// findings (always the instance's); with db, the rest for that database alone plus its objects (the 5,000 first by
// schema, kind and identity, each row with the database's total). ?part= narrows the reply to one part (the objects
// picker reads part=objects). The changes list stops at 2,000 and the event trigger's log at 1,000; the databases'
// counts are whole; their 'dropped' counts each object once and leaves out a dropped partition, as the warning finding
// does (a retention job's routine). The database page's Schema section reads the same with db. No Summary column: the findings reach
// the Findings through schema_findings.
//
// A SQL Server instance (task A26, the collection mssql_schema, 0267) reads the same tables: its state is
// mssql_schema's collection row, its databases carry mssql_schema_dbs' state, note and read_at (part mssql_dbs: every
// database the collection has seen, the never-read and not-readable ones too), its changes come from
// mssql_schema_changes_window with the default trace's candidates (who_*), and part trace says whether the default
// trace is trusted (its reader's state, the instance's platform) and the oldest whole read; it has no event trigger log.
// Both engines: the lists carry their text cut (changes at 400 characters a side, objects at 1,000, with a cut flag),
// and ?change_at=<the change's snapshot_at>&db=&kind=&identity=[&attribute=] (part change) gives one change's whole
// before and after (the Schema tab's side-by-side view).

const sqlSchemaState = `
SELECT c.status, c.note, c.snapshot_at
  FROM pgvigil.collection_dates c
 WHERE c.instance_id = $1 AND c.collection = 'schema'`

const sqlSchemaDatabases = `
SELECT d.dbid, d.datname, d.objects, d.ddl_log, d.ddl_log_table, d.ddl_log_note, d.first_read, d.snapshot_at, d.is_present,
       (SELECT count(*) FROM pgvigil.schema_changes c
         WHERE c.instance_id = d.instance_id AND c.dbid = d.dbid AND c.snapshot_at > $2 AND c.snapshot_at <= $3) AS changes,
       (SELECT count(DISTINCT (c.kind, c.identity)) FROM pgvigil.schema_changes c
         WHERE c.instance_id = d.instance_id AND c.dbid = d.dbid AND c.change = 'dropped'
           AND NOT (c.kind = 'table' AND c.before LIKE '% partition of %')
           AND c.snapshot_at > $2 AND c.snapshot_at <= $3) AS dropped
  FROM pgvigil.schema_databases d
 WHERE d.instance_id = $1 AND ($4::bigint IS NULL AND d.is_present OR d.dbid = $4)
 ORDER BY d.datname`

// the cut columns of a change list (both engines): 400 characters a side, cut true when either side is longer
const schemaChangeCut = `left(w.before, 400) AS before, left(w.after, 400) AS after,
       coalesce(length(w.before) > 400 OR length(w.after) > 400, false) AS cut`

const sqlSchemaChanges = `
SELECT w.snapshot_at, w.prev_at, w.dbid, w.datname, w.kind, w.identity, w.schema_name, w.object_name, w.parent, w.change, w.attribute,
       ` + schemaChangeCut + `, w.statement, w.statement_role, w.statement_at, w.statement_tag, w.ddl_log
  FROM pgvigil.schema_changes_window($1, $2, $3, $4::bigint) w /* text: statement=stmt */`

const sqlMSSQLSchemaChanges = `
SELECT w.snapshot_at, w.prev_at, w.dbid, w.datname, w.kind, w.identity, w.schema_name, w.object_name, w.parent, w.change, w.attribute,
       ` + schemaChangeCut + `, w.who_login, w.who_host, w.who_program, w.who_at, w.who_n, w.who_list, w.who_note
  FROM pgvigil.mssql_schema_changes_window($1, $2, $3, $4::bigint) w`

const sqlMSSQLSchemaState = `
SELECT c.status, c.note, c.snapshot_at
  FROM pgvigil.collection_dates c
 WHERE c.instance_id = $1 AND c.collection = 'mssql_schema'`

const sqlMSSQLSchemaDBs = `
SELECT m.database_id AS dbid, m.name AS datname, m.state, m.note, m.read_at, m.snapshot_at
  FROM pgvigil.mssql_schema_dbs m
 WHERE m.instance_id = $1 AND ($2::bigint IS NULL OR m.database_id = $2) AND m.state <> 'gone'
 ORDER BY m.name`

// the default trace's state for the tab's words: trusted while its reader read it within 15 minutes (0267's rule)
const sqlMSSQLSchemaTrace = `
SELECT i.platform, r.state AS reader_state, r.snapshot_at AS reader_at, r.note AS reader_note,
       coalesce(r.state = 'read' AND r.snapshot_at > now() - interval '15 minutes', false) AS trusted,
       (SELECT min(m.read_at) FROM pgvigil.mssql_schema_dbs m WHERE m.instance_id = i.instance_id AND m.state <> 'gone') AS oldest_read_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.mssql_reader_state r ON r.instance_id = i.instance_id AND r.reader = 'defaulttrace'
 WHERE i.instance_id = $1`

// one change whole (both engines): the side-by-side view's two texts
const sqlSchemaChange = `
SELECT c.snapshot_at, c.prev_at, c.datname, c.kind, c.identity, c.change, c.attribute, c.before, c.after
  FROM pgvigil.schema_changes c
 WHERE c.instance_id = $1 AND c.snapshot_at = $2 AND c.dbid = $3 AND c.kind = $4 AND c.identity = $5
   AND ($6::text IS NULL OR c.attribute = $6)
 LIMIT 1`

const sqlSchemaDDL = `
SELECT l.snapshot_at AS logged_at, l.datname, l.event, l.command_tag, l.object_type, l.object_identity, l.role_name, l.statement AS "statement@stmt"
  FROM pgvigil.schema_ddl_log l
 WHERE l.instance_id = $1 AND l.snapshot_at > $2 AND l.snapshot_at <= $3 AND ($4::bigint IS NULL OR l.dbid = $4)
 ORDER BY l.snapshot_at DESC, l.log_id DESC
 LIMIT 1000`

const sqlSchemaObjects = `
SELECT o.kind, o.identity, o.schema_name, o.object_name, o.parent, left(o.definition, 1000) AS definition,
       coalesce(length(o.definition) > 1000, false) AS def_cut, o.owner, o.acl, o.first_seen, o.last_changed,
       count(*) OVER () AS total
  FROM pgvigil.schema_objects o
 WHERE o.instance_id = $1 AND o.dbid = $2 AND o.is_present
 ORDER BY o.schema_name, o.kind, o.identity
 LIMIT 5000`

const sqlSchemaFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.schema_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.value, f.setting`

// DBA Dash's Snapshot Summary (control audit D3 a; SchemaCompare/SchemaSnapshots.cs, DDLSnapshots_Get /
// DDLSnapshotDiff_Get) over pgvigil's change history. A snapshot is a read that found changes (schema_changes by
// snapshot_at) - or a database's BASELINE, its first read, which stores no change (0058 / 0267's import: its objects
// are its Created). An object is a standalone one (objectKindsSQL); a column's, an index's or a constraint's change
// counts as its parent modified (DBA Dash's whole-object DDL would show it so), never an object created or dropped by
// the same read. Validated is the read before the next snapshot (its prev_at), the newest's the database's last read;
// the day counts as DATEDIFF(d) counts them (UTC midnights crossed). $2 one database or NULL (the instance's), page $4
// of $3 rows, newest first.
const sqlDDLSnapshots = `
WITH d AS (
  SELECT sd.dbid, sd.datname, sd.first_read, sd.snapshot_at AS last_read
    FROM pgvigil.schema_databases sd
   WHERE sd.instance_id = $1 AND ($2::bigint IS NULL OR sd.dbid = $2)
), k AS (
  SELECT c.dbid, c.snapshot_at, min(c.prev_at) OVER (PARTITION BY c.dbid, c.snapshot_at) AS prev_at,
         CASE WHEN c.kind IN ` + objectKindsSQL + ` THEN c.identity ELSE c.parent END AS obj,
         c.kind IN ` + objectKindsSQL + ` AND c.change = 'added' AS is_created,
         c.kind IN ` + objectKindsSQL + ` AND c.change = 'dropped' AS is_dropped,
         (c.kind IN ` + objectKindsSQL + ` AND c.change = 'changed') OR c.kind NOT IN ` + objectKindsSQL + ` AS is_modified
    FROM pgvigil.schema_changes c JOIN d ON d.dbid = c.dbid
   WHERE c.instance_id = $1
), o AS (
  SELECT k.dbid, k.snapshot_at, k.prev_at, k.obj, bool_or(k.is_created) AS cr, bool_or(k.is_dropped) AS dr, bool_or(k.is_modified) AS md
    FROM k WHERE k.obj IS NOT NULL
   GROUP BY 1, 2, 3, 4
), s AS (
  SELECT o.dbid, o.snapshot_at, o.prev_at, count(*) FILTER (WHERE o.cr) AS created,
         count(*) FILTER (WHERE o.md AND NOT o.cr AND NOT o.dr) AS modified, count(*) FILTER (WHERE o.dr AND NOT o.cr) AS dropped
    FROM o GROUP BY 1, 2, 3
  UNION ALL
  SELECT d.dbid, d.first_read, NULL,
         (SELECT count(*) FROM pgvigil.schema_objects so
           WHERE so.instance_id = $1 AND so.dbid = d.dbid AND so.first_seen = d.first_read AND so.kind IN ` + objectKindsSQL + `), 0, 0
    FROM d
), v AS (
  SELECT s.*, d.datname, coalesce(lead(s.prev_at) OVER (PARTITION BY s.dbid ORDER BY s.snapshot_at), d.last_read) AS validated_at
    FROM s JOIN d USING (dbid)
)
SELECT v.dbid, v.datname AS database, v.snapshot_at, v.validated_at,
       (v.validated_at AT TIME ZONE 'UTC')::date - (v.snapshot_at AT TIME ZONE 'UTC')::date AS valid_for_days,
       (now() AT TIME ZONE 'UTC')::date - (v.validated_at AT TIME ZONE 'UTC')::date AS days_since_validation,
       v.created, v.modified, v.dropped, v.prev_at IS NULL AS baseline
  FROM v
 ORDER BY v.snapshot_at DESC, v.dbid
 LIMIT $3 OFFSET ($4::int - 1) * $3`

// sqlDDLSnapshotObjects: one snapshot's objects (DDLSnapshotDiff_Get; $2 the database, $3 the snapshot): its stored
// changes, or - at a database's baseline, which stores none - its standalone objects first seen by that read, each
// with its definition as of then (the 'before' of the first later change of its definition, or of its drop; else its
// definition now), the change 'added'; ordered by schema and identity (a table's columns follow it, an index sorts
// by its own name).
const sqlDDLSnapshotObjects = `
SELECT w.snapshot_at, w.dbid, w.kind, w.identity, w.schema_name, w.object_name, w.parent, w.change, w.attribute,
       ` + schemaChangeCut + `, false AS baseline
  FROM pgvigil.schema_changes w
 WHERE w.instance_id = $1 AND w.dbid = $2 AND w.snapshot_at = $3
UNION ALL
SELECT so.first_seen, so.dbid, so.kind, so.identity, so.schema_name, so.object_name, so.parent, 'added', NULL,
       NULL, left(x.def, 400), coalesce(length(x.def) > 400, false), true
  FROM pgvigil.schema_objects so
  JOIN pgvigil.schema_databases sd ON sd.instance_id = so.instance_id AND sd.dbid = so.dbid AND sd.first_read = $3
  CROSS JOIN LATERAL (SELECT coalesce((SELECT c.before FROM pgvigil.schema_changes c
                                        WHERE c.instance_id = so.instance_id AND c.dbid = so.dbid AND c.kind = so.kind AND c.identity = so.identity
                                          AND c.snapshot_at > $3 AND c.before IS NOT NULL
                                          AND (c.change = 'dropped' OR (c.change = 'changed' AND c.attribute = 'definition'))
                                        ORDER BY c.snapshot_at LIMIT 1), so.definition) AS def) x
 WHERE so.instance_id = $1 AND so.dbid = $2 AND so.first_seen = $3 AND so.kind IN ` + objectKindsSQL + `
   AND NOT EXISTS (SELECT 1 FROM pgvigil.schema_changes e WHERE e.instance_id = $1 AND e.dbid = $2 AND e.snapshot_at = $3)
 ORDER BY 5, 4, 3`

// sqlDDLAt: DBA Dash's Export (control audit D3 b; DBSchemaAtDate_Get): every standalone object of database $2 as it
// stood at $3 - first seen by then, and its last add or drop by then not a drop - with its definition as of then (the
// 'before' of its first later definition change or drop, else its definition now: a definition past 20,000
// characters is stored cut, a body under a masking policy as its hash - the files say so).
const sqlDDLAt = `
WITH ev AS (
  SELECT DISTINCT ON (c.kind, c.identity) c.kind, c.identity, c.change
    FROM pgvigil.schema_changes c
   WHERE c.instance_id = $1 AND c.dbid = $2 AND c.snapshot_at <= $3 AND c.change IN ('added', 'dropped')
   ORDER BY c.kind, c.identity, c.snapshot_at DESC
)
SELECT so.kind, so.identity, so.schema_name, so.object_name, x.def AS definition
  FROM pgvigil.schema_objects so
  LEFT JOIN ev ON ev.kind = so.kind AND ev.identity = so.identity
  CROSS JOIN LATERAL (SELECT coalesce((SELECT c.before FROM pgvigil.schema_changes c
                                        WHERE c.instance_id = so.instance_id AND c.dbid = so.dbid AND c.kind = so.kind AND c.identity = so.identity
                                          AND c.snapshot_at > $3 AND c.before IS NOT NULL
                                          AND (c.change = 'dropped' OR (c.change = 'changed' AND c.attribute = 'definition'))
                                        ORDER BY c.snapshot_at LIMIT 1), so.definition) AS def) x
 WHERE so.instance_id = $1 AND so.dbid = $2 AND so.kind IN ` + objectKindsSQL + `
   AND so.first_seen <= $3 AND coalesce(ev.change, 'added') <> 'dropped'
 ORDER BY so.kind, so.schema_name, so.object_name`

// ddlSnapshotSizes: DBA Dash's Snapshot Summary Page Size list (SchemaSnapshots.Designer.cs tsSummaryPageSize; 100 the default)
var ddlSnapshotSizes = map[int]bool{100: true, 200: true, 500: true, 1000: true, 5000: true}

// Schema serves the schema snapshots of one instance, or of one of its databases, over the window.
func (s *Server) Schema(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var db *int64
	if v := r.URL.Query().Get("db"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("db must be a database oid"))
			return
		}
		db = &n
	}
	var engine string
	if err := s.pool.QueryRow(r.Context(), `SELECT coalesce(engine, 'postgres') FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&engine); err != nil {
		writeErr(w, http.StatusNotFound, errors.New("no such instance"))
		return
	}
	q := r.URL.Query()
	if at := q.Get("change_at"); at != "" {
		t, err := time.Parse(time.RFC3339Nano, at)
		if err != nil || db == nil || q.Get("kind") == "" || q.Get("identity") == "" {
			writeErr(w, http.StatusBadRequest, errors.New("a change is named by change_at (its snapshot_at), db, kind and identity"))
			return
		}
		var attr *string
		if a := q.Get("attribute"); a != "" {
			attr = &a
		}
		s.multiPart(w, r, []part{{"change", sqlSchemaChange, []any{id, t, *db, q.Get("kind"), q.Get("identity"), attr}}})
		return
	}
	// DBA Dash's Snapshot Summary (control audit D3 a): read alone when asked, either engine (the store is shared)
	switch q.Get("part") {
	case "ddl_snapshots":
		size, page := 100, 1
		if v := q.Get("size"); v != "" {
			if size, err = strconv.Atoi(v); err != nil || !ddlSnapshotSizes[size] {
				writeErr(w, http.StatusBadRequest, errors.New("size must be one of 100, 200, 500, 1000, 5000"))
				return
			}
		}
		if v := q.Get("page"); v != "" {
			if page, err = strconv.Atoi(v); err != nil || page < 1 || page > 100000 {
				writeErr(w, http.StatusBadRequest, errors.New("page must be 1 or more"))
				return
			}
		}
		s.multiPart(w, r, []part{{"ddl_snapshots", sqlDDLSnapshots, []any{id, db, size, page}}})
		return
	case "ddl_snapshot_objects", "ddl_at":
		at, err := time.Parse(time.RFC3339Nano, q.Get("snap_at"))
		if err != nil || db == nil {
			writeErr(w, http.StatusBadRequest, errors.New("part="+q.Get("part")+" needs db= and snap_at= (the snapshot's time, RFC 3339)"))
			return
		}
		stmt := sqlDDLSnapshotObjects
		if q.Get("part") == "ddl_at" {
			stmt = sqlDDLAt // control audit D3 b: the Export
		}
		s.multiPart(w, r, []part{{q.Get("part"), stmt, []any{id, *db, at}}})
		return
	}
	var parts []part
	if engine == "sqlserver" {
		parts = []part{
			{"state", sqlMSSQLSchemaState, []any{id}},
			{"databases", sqlSchemaDatabases, []any{id, from, to, db}},
			{"mssql_dbs", sqlMSSQLSchemaDBs, []any{id, db}},
			{"changes", sqlMSSQLSchemaChanges, []any{id, from, to, db}},
			{"trace", sqlMSSQLSchemaTrace, []any{id}},
			{"findings", sqlSchemaFindings, []any{id}},
		}
	} else {
		parts = []part{
			{"state", sqlSchemaState, []any{id}},
			{"databases", sqlSchemaDatabases, []any{id, from, to, db}},
			{"changes", sqlSchemaChanges, []any{id, from, to, db}},
			{"ddl", sqlSchemaDDL, []any{id, from, to, db}},
			{"findings", sqlSchemaFindings, []any{id}},
		}
	}
	if db != nil {
		parts = append(parts, part{"objects", sqlSchemaObjects, []any{id, *db}})
	}
	s.multiPart(w, r, parts)
}
