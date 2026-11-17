package web

import (
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// The object page (OBJ: DBA Dash's object window, DBADashGUI/Performance/ObjectDetailControl.cs in DetailForm) reads
// /api/mssql/procs: part=object_lookup&obj=<name>[&dbname=<database>] finds the object; its tabs' parts follow.

// objectNameMax: a three-part name of 128-character parts and its two dots
const objectNameMax = 3*128 + 2

// splitObjectName is DBA Dash's DetailForm.SplitName (DetailForm.cs L143-184): a one, two or three part name counted
// back from the object; a dot inside [brackets] or "quotes" is part of the name and ]] or "" inside them one ] or ";
// each part trimmed, an empty part no part ("").
func splitObjectName(name string) (db, schema, obj string) {
	if strings.TrimSpace(name) == "" {
		return "", "", ""
	}
	var parts []string
	var part strings.Builder
	var closing rune
	rs := []rune(name)
	for i := 0; i < len(rs); i++ {
		c := rs[i]
		switch {
		case closing != 0:
			if c != closing {
				part.WriteRune(c)
			} else if i+1 < len(rs) && rs[i+1] == closing {
				i++
				part.WriteRune(rs[i])
			} else {
				closing = 0
			}
		case c == '[':
			closing = ']'
		case c == '"':
			closing = '"'
		case c == '.':
			parts = append(parts, part.String())
			part.Reset()
		default:
			part.WriteRune(c)
		}
	}
	parts = append(parts, part.String())
	at := func(fromEnd int) string {
		if i := len(parts) - fromEnd; i >= 0 {
			return strings.TrimSpace(parts[i])
		}
		return ""
	}
	return at(3), at(2), at(1)
}

// sqlMSSQLObjectLookup: the procedures, functions and triggers named $6 (case-insensitive; $4 the database, $5 the
// schema, NULL = any) in the window's execution statistics (0084 mssql_proc_sample, 0343 mssql_func_sample: the
// newest row of each object) and in the schema snapshot's present objects (0058 / 0267 schema_objects), one row an
// object - a statistics row first, as it carries the object id (DBA Dash's GetDBObjectInfo over DBObjects) - ordered by
// database, schema and name.
const sqlMSSQLObjectLookup = `
WITH p AS (
  SELECT DISTINCT ON (s.database_id, s.object_id) s.database_id, s.object_id, s.database_name, s.schema_name, s.object_name,
         'procedure'::text AS kind, s.type_desc, 'statistics'::text AS source, 1 AS pref
    FROM pgvigil.mssql_proc_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at >= $2 AND s.snapshot_at < $3 AND lower(s.object_name) = lower($6)
     AND ($4::text IS NULL OR lower(s.database_name) = lower($4)) AND ($5::text IS NULL OR lower(s.schema_name) = lower($5))
   ORDER BY s.database_id, s.object_id, s.snapshot_at DESC
), f AS (
  SELECT DISTINCT ON (s.database_id, s.object_id) s.database_id, s.object_id, s.database_name, s.schema_name, s.object_name,
         s.kind, s.type_desc, 'statistics'::text AS source, 1 AS pref
    FROM pgvigil.mssql_func_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at >= $2 AND s.snapshot_at < $3 AND lower(s.object_name) = lower($6)
     AND ($4::text IS NULL OR lower(s.database_name) = lower($4)) AND ($5::text IS NULL OR lower(s.schema_name) = lower($5))
   ORDER BY s.database_id, s.object_id, s.snapshot_at DESC
), o AS (
  SELECT o.dbid::int AS database_id, NULL::bigint AS object_id, o.datname AS database_name, o.schema_name, o.object_name,
         o.kind, NULL::text AS type_desc, 'schema'::text AS source, 2 AS pref
    FROM pgvigil.schema_objects o
   WHERE o.instance_id = $1 AND o.is_present AND o.kind IN ('procedure', 'function', 'trigger') AND lower(o.object_name) = lower($6)
     AND ($4::text IS NULL OR lower(o.datname) = lower($4)) AND ($5::text IS NULL OR lower(o.schema_name) = lower($5))
)
SELECT DISTINCT ON (lower(a.database_name), lower(a.schema_name), lower(a.object_name))
       a.database_name, a.database_id, a.schema_name, a.object_name, a.object_id, a.kind, a.type_desc, a.source
  FROM (SELECT * FROM p UNION ALL SELECT * FROM f UNION ALL SELECT * FROM o) a
 ORDER BY lower(a.database_name), lower(a.schema_name), lower(a.object_name), a.pref
 LIMIT 50`

// objectLookupPart: part=object_lookup's part from obj= (DBA Dash's name rules) and dbname= (a three-part name's
// database wins); a missing or over-long name is an error.
func objectLookupPart(q url.Values, id int, from, to time.Time) (part, error) {
	raw := q.Get("obj")
	if len([]rune(raw)) > objectNameMax {
		return part{}, errors.New("obj is longer than a three-part name (386 characters)")
	}
	db, schema, name := splitObjectName(raw)
	if name == "" {
		return part{}, errors.New("part=object_lookup needs obj=, the object's name (one, two or three parts)")
	}
	if db == "" {
		db = q.Get("dbname")
	}
	return part{"object_lookup", sqlMSSQLObjectLookup, []any{id, from, to, nilIfEmpty(db), nilIfEmpty(schema), name}}, nil
}

// sqlMSSQLObjectStatements: the object page's Query Stats (DBA Dash's Query Stats report by @ObjectName): the Plan cache
// page's top read of the window (sqlMSSQLPCTop, its columns and order) cut to one database ($4) and to the keys whose
// text names the module ($5, 'schema.name' as 0092's mssql_pc_text.object_name holds it; case-insensitive) - in place
// of the page's own scope (pcScope: a database filter and the Query Store switch), the parameters kept in their places.
var sqlMSSQLObjectStatements = strings.Replace(sqlMSSQLPCTop, pcScope, `s.database_id = $4
   AND s.query_key IN (SELECT t2.query_key FROM pgvigil.mssql_pc_text t2 WHERE t2.instance_id = $1 AND lower(t2.object_name) = lower($5))`, 1)

// objectStatementsPart: part=object_statements from db_id= (the database id) and module= (schema.name)
func objectStatementsPart(q url.Values, id int, from, to time.Time) (part, error) {
	dbID, err := strconv.Atoi(q.Get("db_id"))
	module := q.Get("module")
	if err != nil || module == "" || len([]rune(module)) > 2*128+1 {
		return part{}, errors.New("part=object_statements needs db_id= (the database id) and module= (schema.name)")
	}
	return part{"object_statements", sqlMSSQLObjectStatements, []any{id, from, to, dbID, module}}, nil
}

// sqlMSSQLObjectSlow: the object page's Slow Queries (DBA Dash's Slow Queries fixed to the object, grouped by client app:
// SlowQueries.cs FixedObjectName / groupBy client_app_name; SlowQueriesSummary_Get's SQ.object_name = @ObjectName): the
// window's rpc_completed and sql_batch_completed rows of 0065's mssql_slow_events whose bare object name is $5
// (case-insensitive) in database $4 (empty = every database), one row per client app, the longest total first.
const sqlMSSQLObjectSlow = `
SELECT coalesce(e.program_name, '') AS client_app, count(*) AS events, round(sum(e.duration_ms), 1) AS total_ms,
       round(max(e.duration_ms), 1) AS worst_ms, round(avg(e.duration_ms), 1) AS mean_ms, round(sum(e.cpu_ms), 1) AS cpu_ms,
       sum(e.logical_reads) AS logical_reads, sum(e.writes) AS writes,
       count(*) FILTER (WHERE e.result IS DISTINCT FROM 'OK') AS not_ok, max(e.event_at) AS last_at
  FROM pgvigil.mssql_slow_events e
 WHERE e.instance_id = $1 AND e.event_at > $2 AND e.event_at <= $3 AND e.event_name IN ('rpc_completed', 'sql_batch_completed')
   AND lower(e.object_name) = lower($5::text) AND ($4::text = '' OR lower(e.database_name) = lower($4::text))
 GROUP BY 1
 ORDER BY sum(e.duration_ms) DESC NULLS LAST
 LIMIT 200`

// objectSlowPart: part=object_slow from name= (the bare object name) and dbname= (empty = every database)
func objectSlowPart(q url.Values, id int, from, to time.Time) (part, error) {
	name := q.Get("name")
	if name == "" || len([]rune(name)) > 128 {
		return part{}, errors.New("part=object_slow needs name= (the object's bare name)")
	}
	return part{"object_slow", sqlMSSQLObjectSlow, []any{id, from, to, q.Get("dbname"), name}}, nil
}
