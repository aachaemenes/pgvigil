package web

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// The instance diff (task 132; DBA Dash's Diff menu: Database Schema Diff and Agent Job Diff). Route, wired in
// Handler:
//
//	GET /api/diff?a=<id>&b=<id>[&at_a=&at_b=][&db_a=&db_b=][&all=1] -> s.Diff
//
// Three modes, by what the two sides are:
//
//	instances  a <> b: two instances as last read (at_a and at_b are refused: the stores hold one instance's past,
//	           not two instances at one past moment worth comparing). Settings, jobs and, on PostgreSQL, schema
//	           objects; db_a with db_b picks one pair of databases instead of pairing them by name.
//	snapshots  a = b with at_a (at_b: default the newest read; at_a before at_b): one instance at two times, from
//	           the change histories. db_a narrows the schema part to one database.
//	databases  a = b without at_a, db_a and db_b two different databases: their schema objects as last read.
//
// Both sides are one engine (400 otherwise). The reply: sides (pgvigil.diff_sides: each side's instance, as-of time
// and how far back each store reaches), meta (mode, engine, all, the schema cap), databases (each side's databases
// with a schema snapshot, for the page's pickers), coverage (per section: compared or not, and why), and per
// compared section its rows and a count per status: settings, jobs, schema. Differences only unless all=1. The
// schema rows stop at diffSchemaCap; schema_counts covers every row. part=databases answers with the databases part
// alone, whatever the mode (the page fills its pickers from it before anything is compared).

// diffSchemaCap is the most schema rows one reply lists.
const diffSchemaCap = 1000

const sqlDiffDatabases = `
SELECT d.instance_id, d.dbid, d.datname, d.objects, d.snapshot_at, d.first_read
  FROM pgvigil.schema_databases d
 WHERE d.instance_id IN ($1, $2) AND d.is_present
 ORDER BY d.instance_id, d.datname`

// the schema rows of either source (%s), differences first, in the catalog's order of kinds
const sqlDiffSchemaRows = `
SELECT x.* FROM (%s) x
 WHERE $5::boolean OR x.status <> 'same'
 ORDER BY (x.status = 'same'), coalesce(x.datname_a, x.datname_b),
          array_position(ARRAY['database', 'schema', 'table', 'column', 'index', 'constraint', 'trigger', 'sequence', 'view',
                               'materialized view', 'function', 'procedure'], x.kind) NULLS LAST, x.identity
 LIMIT ` + "%d"

const sqlDiffSchemaCounts = `
SELECT x.status, x.kind, count(*) AS n FROM (%s) x
 WHERE $5::boolean OR x.status <> 'same'
 GROUP BY x.status, x.kind
 ORDER BY x.status, x.kind`

// both schema sources take the same five parameters ($1 a, $2 b, $3 and $4 their own, $5 all), so the two wrappers
// above fit either
const (
	sqlDiffSchemaNow  = `SELECT * FROM pgvigil.diff_schema($1::int, $2::int, $3::text, $4::text)`
	sqlDiffSchemaPast = `SELECT * FROM pgvigil.diff_schema_snapshots($1::int, $3::timestamptz, $4::timestamptz, $2::text, $5::boolean)`
)

// diffTime reads an optional RFC 3339 time.
func diffTime(name, v string) (*time.Time, error) {
	if v == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return &t, nil
}

// Diff serves the diff of two instances, of one instance at two times, or of two databases of one instance.
func (s *Server) Diff(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	bad := func(msg string) { writeErr(w, http.StatusBadRequest, errors.New(msg)) }
	a, errA := strconv.Atoi(q.Get("a"))
	b, errB := strconv.Atoi(q.Get("b"))
	if errA != nil || errB != nil || a <= 0 || b <= 0 {
		bad("a and b must be instance ids")
		return
	}
	// the page's database pickers: each side's databases with a schema snapshot, nothing compared
	if q.Get("part") == "databases" {
		s.multi(w, r, []part{{"databases", sqlDiffDatabases, []any{a, b}}})
		return
	}
	atA, err := diffTime("at_a", q.Get("at_a"))
	if err != nil {
		bad(err.Error())
		return
	}
	atB, err := diffTime("at_b", q.Get("at_b"))
	if err != nil {
		bad(err.Error())
		return
	}
	dbA, dbB := q.Get("db_a"), q.Get("db_b")
	if len(dbA) > 128 || len(dbB) > 128 {
		bad("db_a and db_b are database names")
		return
	}
	all := q.Get("all") == "1"

	var mode string
	switch {
	case a != b:
		mode = "instances"
		if atA != nil || atB != nil {
			bad("two instances are compared as last read; at_a and at_b go with one instance on both sides")
			return
		}
		if (dbA == "") != (dbB == "") {
			bad("db_a and db_b go together: one pair of databases, or none to pair them by name")
			return
		}
	case atA != nil:
		mode = "snapshots"
		end := time.Now()
		if atB != nil {
			end = *atB
		}
		if !atA.Before(end) {
			bad("at_a must be before at_b")
			return
		}
		if dbB != "" && dbB != dbA {
			bad("one instance at two times takes one database: db_a (db_b the same or left out)")
			return
		}
	case atB != nil:
		bad("at_b needs at_a")
		return
	case dbA != "" && dbB != "" && dbA != dbB:
		mode = "databases"
	default:
		bad("the same instance on both sides needs at_a (two snapshots) or two different databases (db_a, db_b)")
		return
	}

	// the engine of each side: one engine per diff
	et, err := s.query(r.Context(), `SELECT instance_id, coalesce(engine, 'postgres') FROM pgvigil.instances WHERE instance_id IN ($1, $2)`, a, b)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("instances: %w", err))
		return
	}
	engines := map[int]string{}
	for _, row := range et.Rows {
		if id, ok := row[0].(int32); ok {
			engines[int(id)], _ = row[1].(string)
		}
	}
	if engines[a] == "" || engines[b] == "" {
		writeErr(w, http.StatusNotFound, errors.New("no such instance"))
		return
	}
	if engines[a] != engines[b] {
		bad("the two sides are different engines: a diff compares PostgreSQL with PostgreSQL or SQL Server with SQL Server")
		return
	}
	engine := engines[a]
	pg := engine == "postgres"

	parts := []part{
		{"sides", `SELECT * FROM pgvigil.diff_sides($1, $2, $3, $4)`, []any{a, atA, b, atB}},
		{"meta", `SELECT $1::text AS mode, $2::text AS engine, $3::boolean AS "all", $4::int AS schema_cap`, []any{mode, engine, all, diffSchemaCap}},
		{"databases", sqlDiffDatabases, []any{a, b}},
	}
	if mode != "databases" {
		parts = append(parts,
			part{"settings", `SELECT * FROM pgvigil.diff_settings($1, $2, $3, $4) WHERE $5::boolean OR status <> 'same'`, []any{a, atA, b, atB, all}},
			part{"settings_counts", `SELECT status, count(*) AS n FROM pgvigil.diff_settings($1, $2, $3, $4) GROUP BY status ORDER BY status`, []any{a, atA, b, atB}},
			part{"jobs", `SELECT * FROM pgvigil.diff_jobs($1, $2, $3, $4) WHERE $5::boolean OR status <> 'same'`, []any{a, atA, b, atB, all}},
			part{"jobs_counts", `SELECT status, count(*) AS n FROM pgvigil.diff_jobs($1, $2, $3, $4) GROUP BY status ORDER BY status`, []any{a, atA, b, atB}})
	}
	if pg {
		src, args := sqlDiffSchemaNow, []any{a, b, nullIfEmpty(dbA), nullIfEmpty(dbB), all}
		if mode == "snapshots" {
			end := time.Now()
			if atB != nil {
				end = *atB
			}
			src, args = sqlDiffSchemaPast, []any{a, nullIfEmpty(dbA), *atA, end, all}
		}
		parts = append(parts,
			part{"schema", fmt.Sprintf(sqlDiffSchemaRows, src, diffSchemaCap), args},
			part{"schema_counts", fmt.Sprintf(sqlDiffSchemaCounts, src), args})
	}

	out := map[string]*table{}
	for _, p := range parts {
		t, err := s.query(r.Context(), p.sql, p.args...)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.name, err))
			return
		}
		out[p.name] = t
	}
	out["coverage"] = diffCoverage(mode, engine)
	s.reply(w, r, out, nil)
}

// nullIfEmpty passes an empty text parameter as NULL.
func nullIfEmpty(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

// diffCoverage says, per section, whether this diff compares it and what the store behind it holds: the page prints
// it, so a section that is absent is never read as 'no difference'.
func diffCoverage(mode, engine string) *table {
	t := &table{Columns: []string{"section", "compared", "note"}, Rows: [][]any{}}
	add := func(section string, compared bool, note string) {
		t.Rows = append(t.Rows, []any{section, compared, note})
	}
	pg := engine == "postgres"
	if mode == "databases" {
		add("settings", false, "one instance: its settings are the same on both sides")
		add("jobs", false, "one instance: its jobs are the same on both sides")
	} else {
		switch {
		case pg && mode == "snapshots":
			add("settings", true, "the server-level non-default settings, rolled back through the change history (one read an hour; it starts at the instance's first read)")
		case pg:
			add("settings", true, "the server-level non-default settings of each instance's newest read; a setting only one side lists is at its default on the other")
		case mode == "snapshots":
			add("settings", true, "sys.configurations' values in use; the repository keeps ONE earlier value per setting, so a time before the change before last shows the value of that change")
		default:
			add("settings", true, "sys.configurations' values in use at each instance's newest read")
		}
		if mode == "snapshots" {
			add("jobs", true, "each job's definition as it was at each time (every version is kept); matched by scheduler and job id")
		} else {
			add("jobs", true, "each job's newest definition; matched by scheduler and name, the ids of a schedule or step left out of the comparison")
		}
	}
	switch {
	case !pg:
		add("schema", false, "the repository holds no schema objects of a SQL Server instance: nothing to compare")
	case mode == "snapshots":
		add("schema", true, "the schema collection's change history between the two times (hourly reads; it starts at each database's first read and ends at the repository's retention)")
	default:
		add("schema", true, "the schema collection's newest snapshot of each side; an object is matched by kind and identity")
	}
	return t
}
