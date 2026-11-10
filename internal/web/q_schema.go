package web

import (
	"errors"
	"net/http"
	"strconv"
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

const sqlSchemaChanges = `SELECT * FROM pgvigil.schema_changes_window($1, $2, $3, $4::bigint)`

const sqlSchemaDDL = `
SELECT l.snapshot_at AS logged_at, l.datname, l.event, l.command_tag, l.object_type, l.object_identity, l.role_name, l.statement
  FROM pgvigil.schema_ddl_log l
 WHERE l.instance_id = $1 AND l.snapshot_at > $2 AND l.snapshot_at <= $3 AND ($4::bigint IS NULL OR l.dbid = $4)
 ORDER BY l.snapshot_at DESC, l.log_id DESC
 LIMIT 1000`

const sqlSchemaObjects = `
SELECT o.kind, o.identity, o.schema_name, o.object_name, o.parent, o.definition, o.owner, o.acl, o.first_seen, o.last_changed,
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
	parts := []part{
		{"state", sqlSchemaState, []any{id}},
		{"databases", sqlSchemaDatabases, []any{id, from, to, db}},
		{"changes", sqlSchemaChanges, []any{id, from, to, db}},
		{"ddl", sqlSchemaDDL, []any{id, from, to, db}},
		{"findings", sqlSchemaFindings, []any{id}},
	}
	if db != nil {
		parts = append(parts, part{"objects", sqlSchemaObjects, []any{id, *db}})
	}
	s.multiPart(w, r, parts)
}
