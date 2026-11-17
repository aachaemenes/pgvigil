package web

import (
	"errors"
	"net/url"
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
