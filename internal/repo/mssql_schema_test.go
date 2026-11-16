package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// 0267 re-creates 0058's import_schema whole with ONE arm (A26 S10): with that arm taken back out,
// 0267's function is 0058's, character for character - an edit of either that the other does not carry fails here.
func TestImportSchema0267Is0058PlusTheGoneArm(t *testing.T) {
	body := func(file string) string {
		t.Helper()
		b, err := migrations.ReadFile("sql/" + file)
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		i := strings.Index(s, "CREATE OR REPLACE FUNCTION pgvigil.import_schema(")
		if i < 0 {
			t.Fatalf("%s: no import_schema", file)
		}
		j := strings.Index(s[i:], "END $$;")
		if j < 0 {
			t.Fatalf("%s: import_schema has no end", file)
		}
		return s[i : i+j]
	}
	const arm = `  -- A26 (0267): the objects of a database gone from the read go with it (0058 marked the database row only, so its
  -- objects stayed present on the page and purge's NOT is_present line never took them)
  UPDATE pgvigil.schema_objects o SET is_present = false, snapshot_at = p_snapshot_at
    FROM pgvigil.schema_databases sd
   WHERE sd.instance_id = p_instance_id AND NOT sd.is_present
     AND o.instance_id = sd.instance_id AND o.dbid = sd.dbid AND o.is_present;
`
	got := body("0267_mssql_schema.sql")
	if strings.Count(got, arm) != 1 {
		t.Fatalf("0267's import_schema holds the gone arm %d times, want once", strings.Count(got, arm))
	}
	if got, want := strings.Replace(got, arm, "", 1), body("0058_schema.sql"); got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("0267's import_schema differs from 0058's beyond the arm at its line %d:\n0267: %s\n0058: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("0267's import_schema has %d lines, 0058's %d", len(gl), len(wl))
	}
}

type schemaStore struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	id   int
}

func newSchemaStore(t *testing.T, engine string) *schemaStore {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	name := fmt.Sprintf("a26-%s-%d", engine, time.Now().UnixNano()%1000000000)
	platform, ver, num := "onprem", "17.0", 170000
	if engine == "sqlserver" {
		platform, ver, num = "sqlserver", "16.0", 160000
	}
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, $3, $4, false, '{}'::text[], $5)`, name, platform, ver, num, engine).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, q := range []string{`DELETE FROM pgvigil.schema_changes WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_trace_events WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	})
	return &schemaStore{t: t, ctx: ctx, pool: pool, id: id}
}

// obj is one 'obj' row of the schema payload; its hash is its definition's text (the import compares hashes only).
func obj(dbid int, datname, kind, identity, parent, def string) map[string]any {
	name := identity
	if i := strings.LastIndex(identity, "."); i >= 0 {
		name = identity[i+1:]
	}
	return map[string]any{"kind": "obj", "dbid": dbid, "datname": datname, "object_kind": kind, "identity": identity,
		"schema_name": "dbo", "object_name": name, "parent": nilIfBlank(parent), "definition": def, "owner": "dbo", "hash": "h:" + def}
}

func nilIfBlank(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (s *schemaStore) importWith(fn string, at time.Time, rows ...map[string]any) {
	s.t.Helper()
	b, err := json.Marshal(rows)
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.pool.Exec(s.ctx, fmt.Sprintf(`SELECT pgvigil.%s($1, $2, $3::jsonb)`, fn), s.id, at, string(b)); err != nil {
		s.t.Fatalf("%s at %s: %v", fn, at.Format(time.RFC3339), err)
	}
}

func (s *schemaStore) present(dbid int) map[string]bool {
	s.t.Helper()
	rows, err := s.pool.Query(s.ctx, `SELECT identity, is_present FROM pgvigil.schema_objects WHERE instance_id = $1 AND dbid = $2`, s.id, dbid)
	if err != nil {
		s.t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var k string
		var p bool
		if err := rows.Scan(&k, &p); err != nil {
			s.t.Fatal(err)
		}
		out[k] = p
	}
	return out
}

func (s *schemaStore) changes(dbid int, at time.Time) []string {
	s.t.Helper()
	rows, err := s.pool.Query(s.ctx, `SELECT change || ' ' || identity FROM pgvigil.schema_changes
	                                    WHERE instance_id = $1 AND dbid = $2 AND snapshot_at = $3 ORDER BY 1`, s.id, dbid, at)
	if err != nil {
		s.t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			s.t.Fatal(err)
		}
		out = append(out, c)
	}
	return out
}

// S10 (both engines; red on a store without 0267): a database gone from the read takes its objects with it - 0058
// marked only the database row, so its objects stayed present and purge's NOT is_present line never took them.
func TestSchemaGoneDatabaseObjectsOnAStore(t *testing.T) {
	s := newSchemaStore(t, "postgres")
	t0 := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)
	db := func(dbid int, name string) map[string]any {
		return map[string]any{"kind": "db", "dbid": dbid, "datname": name, "objects": 1, "read_at": t0}
	}
	s.importWith("import_schema", t0, db(1, "a"), obj(1, "a", "table", "public.t", "", "create table t"), db(2, "b"),
		obj(2, "b", "table", "public.u", "", "create table u"), map[string]any{"kind": "end"})
	t1 := t0.Add(time.Hour)
	s.importWith("import_schema", t1, db(2, "b"), obj(2, "b", "table", "public.u", "", "create table u"), map[string]any{"kind": "end"})
	var dbPresent bool
	if err := s.pool.QueryRow(s.ctx, `SELECT is_present FROM pgvigil.schema_databases WHERE instance_id = $1 AND dbid = 1`, s.id).Scan(&dbPresent); err != nil {
		t.Fatal(err)
	}
	if dbPresent {
		t.Fatal("database a, gone from the read, is still present")
	}
	if p := s.present(1); p["public.t"] {
		t.Errorf("the gone database's object public.t is still present: %v (want it marked gone, so purge takes it)", p)
	}
	if p := s.present(2); !p["public.u"] {
		t.Errorf("the read database's object public.u is not present: %v", p)
	}
}

// localOf is a create date as the collector sends it for the identity: sys.databases.create_date in the server's own
// clock, as text (these tests take UTC for the server's clock).
func localOf(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000") }

func mdb(dbid int, name string, created time.Time, restored *time.Time, state string, readAt *time.Time) map[string]any {
	m := map[string]any{"kind": "mssql_db", "database_id": dbid, "name": name, "create_date": created, "create_local": localOf(created),
		"state": state}
	if restored != nil {
		m["restored_at"] = *restored
	}
	if readAt != nil {
		m["read_at"] = *readAt
	}
	return m
}

// B1 and its kin on SQL Server: another database on a reused database_id is a new baseline (no false 'dropped'); a
// restore over the database is diffed against the stored snapshot; a rename keeps it; a database named by no row is
// 'gone' with its objects.
func TestMssqlSchemaIdentityOnAStore(t *testing.T) {
	s := newSchemaStore(t, "sqlserver")
	t0 := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Hour)
	c1, c2 := t0.Add(-48*time.Hour), t0.Add(30*time.Minute)
	db := func(name string, at time.Time) map[string]any {
		return map[string]any{"kind": "db", "dbid": 7, "datname": name, "objects": 2, "read_at": at}
	}
	r0 := t0
	s.importWith("import_mssql_schema", t0, mdb(7, "A", c1, nil, "read", &r0), db("A", t0),
		obj(7, "A", "table", "dbo.a1", "", "a1"), obj(7, "A", "table", "dbo.a2", "", "a2"), map[string]any{"kind": "end"})

	// DROP DATABASE A; CREATE DATABASE B - id 7 again, a new create_date, no restore
	t1 := t0.Add(time.Hour)
	r1 := t1
	s.importWith("import_mssql_schema", t1, mdb(7, "B", c2, nil, "read", &r1), db("B", t1),
		obj(7, "B", "table", "dbo.b1", "", "b1"), map[string]any{"kind": "end"})
	if ch := s.changes(7, t1); len(ch) != 0 {
		t.Errorf("another database on id 7 recorded %v, want no change (a new baseline, never A's objects 'dropped')", ch)
	}
	if p := s.present(7); p["dbo.a1"] || p["dbo.a2"] || !p["dbo.b1"] {
		t.Errorf("objects after the reuse: %v, want only dbo.b1 present", p)
	}

	// a rename (same create_date): the snapshot is kept, nothing recorded
	t2 := t1.Add(time.Hour)
	r2 := t2
	s.importWith("import_mssql_schema", t2, mdb(7, "B2", c2, nil, "read", &r2), db("B2", t2),
		obj(7, "B2", "table", "dbo.b1", "", "b1"), map[string]any{"kind": "end"})
	if ch := s.changes(7, t2); len(ch) != 0 {
		t.Errorf("a rename recorded %v, want none", ch)
	}

	// a restore over it (a newer create_date, a restore since the last read): diffed, not a baseline
	t3 := t2.Add(time.Hour)
	r3, restored := t3, t2.Add(10*time.Minute)
	s.importWith("import_mssql_schema", t3, mdb(7, "B2", t2.Add(10*time.Minute), &restored, "read", &r3), db("B2", t3),
		obj(7, "B2", "table", "dbo.b0", "", "b0"), map[string]any{"kind": "end"})
	if ch := strings.Join(s.changes(7, t3), ", "); ch != "added dbo.b0, dropped dbo.b1" {
		t.Errorf("a restore recorded [%s], want [added dbo.b0, dropped dbo.b1]", ch)
	}

	// gone: no row names it
	t4 := t3.Add(time.Hour)
	s.importWith("import_mssql_schema", t4, map[string]any{"kind": "end"})
	var state string
	if err := s.pool.QueryRow(s.ctx, `SELECT state FROM pgvigil.mssql_schema_dbs WHERE instance_id = $1 AND database_id = 7`, s.id).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if p := s.present(7); state != "gone" || p["dbo.b0"] {
		t.Errorf("a database named by no row: state %q, objects %v, want gone and none present", state, p)
	}
}

func (s *schemaStore) traceDDL(at time.Time, db, sub, object, typ, login string) {
	s.t.Helper()
	if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.mssql_event_partition('mssql_trace_events', $1)`, at); err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.pool.Exec(s.ctx, `INSERT INTO pgvigil.mssql_trace_events (instance_id, event_at, event_key, snapshot_at, logged_local,
	    event_class, kind, sub, database_name, login_name, host_name, program_name, object_name, object_type)
	  VALUES ($1, $2, $3, $2, $2::timestamptz AT TIME ZONE 'UTC', 164, 'ddl', $4, $5, $6, $6 || '-host', $6 || '-app', $7, $8)`,
		s.id, at, fmt.Sprintf("%s-%s-%d", object, login, at.UnixNano()), sub, db, login, object, typ); err != nil {
		s.t.Fatal(err)
	}
}

func (s *schemaStore) reader(state string, at time.Time, note string) {
	s.t.Helper()
	if _, err := s.pool.Exec(s.ctx, `INSERT INTO pgvigil.mssql_reader_state (instance_id, reader, snapshot_at, state, state_since, note)
	  VALUES ($1, 'defaulttrace', $2, $3, $2, nullif($4, ''))
	  ON CONFLICT (instance_id, reader) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, state = EXCLUDED.state, note = EXCLUDED.note`,
		s.id, at, state, note); err != nil {
		s.t.Fatal(err)
	}
}

type dueReply struct {
	TraceOK  bool    `json:"trace_ok"`
	TraceWhy *string `json:"trace_why"`
	Due      []struct {
		ID     int    `json:"database_id"`
		Reason string `json:"reason"`
	} `json:"due"`
}

func (s *schemaStore) due(at time.Time, dbs ...map[string]any) dueReply {
	s.t.Helper()
	b, _ := json.Marshal(map[string]any{"now": at, "dbs": dbs})
	var raw string
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.import_mssql_schema_due($1, $2, $3::jsonb)::text`, s.id, at, string(b)).Scan(&raw); err != nil {
		s.t.Fatal(err)
	}
	var r dueReply
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		s.t.Fatal(err)
	}
	return r
}

func reasons(r dueReply) string {
	var out []string
	for _, d := range r.Due {
		out = append(out, fmt.Sprintf("%d:%s", d.ID, d.Reason))
	}
	return strings.Join(out, " ")
}

// A2 / S3: which databases a pass reads whole, and the trace's state in words.
func TestMssqlSchemaDueOnAStore(t *testing.T) {
	s := newSchemaStore(t, "sqlserver")
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-100 * 24 * time.Hour)
	fresh, old := now.Add(-20*time.Minute), now.Add(-30*time.Hour)
	end := map[string]any{"kind": "end"}
	snap := func(dbid int, name string, at time.Time) map[string]any {
		return map[string]any{"kind": "db", "dbid": dbid, "datname": name, "objects": 0, "read_at": at}
	}
	s.importWith("import_mssql_schema", now.Add(-time.Hour), mdb(1, "quiet", created, nil, "read", &fresh), snap(1, "quiet", fresh),
		mdb(2, "busy", created, nil, "read", &fresh), snap(2, "busy", fresh), mdb(3, "stale", created, nil, "read", &old), snap(3, "stale", old), end)
	list := func(extra ...map[string]any) []map[string]any {
		out := []map[string]any{{"database_id": 1, "name": "quiet", "create_date": created, "create_local": localOf(created)},
			{"database_id": 2, "name": "busy", "create_date": created, "create_local": localOf(created)},
			{"database_id": 3, "name": "stale", "create_date": created, "create_local": localOf(created)}}
		return append(out, extra...)
	}
	s.traceDDL(now.Add(-5*time.Minute), "busy", "alter", "Orders", "U", "dev")

	// no reader row: the trace is not trusted, so 'busy' waits for its reconcile; the words say why
	r := s.due(now, list(map[string]any{"database_id": 4, "name": "newdb", "create_date": now, "create_local": localOf(now)})...)
	if r.TraceOK || r.TraceWhy == nil || !strings.Contains(*r.TraceWhy, "has not been read") {
		t.Errorf("no reader row: trace_ok %v, why %v", r.TraceOK, r.TraceWhy)
	}
	if got := reasons(r); got != "4:new 3:reconcile" {
		t.Errorf("without the trace: due [%s], want [4:new 3:reconcile]", got)
	}

	// the reader read the trace 2 minutes ago: 'busy' is due by its DDL
	s.reader("read", now.Add(-2*time.Minute), "")
	if got := reasons(s.due(now, list()...)); got != "2:ddl 3:reconcile" {
		t.Errorf("with the trace: due [%s], want [2:ddl 3:reconcile]", got)
	}
	// a stale reader row is not trusted, and says when it was read
	s.reader("read", now.Add(-40*time.Minute), "")
	if r := s.due(now, list()...); r.TraceOK || r.TraceWhy == nil || !strings.Contains(*r.TraceWhy, "was last read") {
		t.Errorf("a stale reader: trace_ok %v, why %v", r.TraceOK, r.TraceWhy)
	}
	// the collector's own reason (Azure SQL Database) wins
	s.reader("read", now.Add(-2*time.Minute), "")
	b, _ := json.Marshal(map[string]any{"now": now, "no_trace": "Azure SQL Database has no default trace", "dbs": list()})
	var raw string
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.import_mssql_schema_due($1, $2, $3::jsonb)::text`, s.id, now, string(b)).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(raw, `"trace_ok": false`) || !strings.Contains(raw, "Azure SQL Database has no default trace") {
		t.Errorf("no_trace from the collector: %s", raw)
	}
	// a reader gap since the databases' reads makes them due once
	s.reader("read", now.Add(-time.Minute), "events between 10:00 and 10:05 were not read: the file rolled away")
	// (a gap ranks before a reconcile, oldest read first: 'stale' is due by the gap too)
	if got := reasons(s.due(now, list()...)); got != "2:ddl 3:gap 1:gap" {
		t.Errorf("a reader gap: due [%s], want [2:ddl 3:gap 1:gap]", got)
	}
	// S-1 of the build review: the reader's next read (every 5 minutes) replaces its note; the gap stays until each
	// database is read after it (red on bce3a4d3: the gap was read from the note alone)
	s.reader("read", now, "")
	if got := reasons(s.due(now, list()...)); got != "2:ddl 3:gap 1:gap" {
		t.Errorf("a reader gap after the reader's next clean read: due [%s], want [2:ddl 3:gap 1:gap]", got)
	}
}

type whoRow struct {
	identity string
	login    *string
	n        int
	note     *string
}

// A3 / B3: the default trace's candidates for each change, by database, name, type and action between the two reads.
func TestMssqlSchemaWhoOnAStore(t *testing.T) {
	s := newSchemaStore(t, "sqlserver")
	t0 := time.Now().UTC().Truncate(time.Second).Add(-3 * time.Hour)
	created := t0.Add(-100 * 24 * time.Hour)
	db := func(at time.Time) map[string]any {
		return map[string]any{"kind": "db", "dbid": 5, "datname": "shop", "objects": 3, "read_at": at}
	}
	end := map[string]any{"kind": "end"}
	r0 := t0
	s.importWith("import_mssql_schema", t0, mdb(5, "shop", created, nil, "read", &r0), db(t0),
		obj(5, "shop", "table", "dbo.Orders", "", "orders v1"), obj(5, "shop", "table", "dbo.Items", "", "items v1"),
		obj(5, "shop", "table", "dbo.Gone", "", "gone"), end)
	// between the reads: dev alters dbo.Orders; an ETL job creates staging.Items (same name, another schema) and dba
	// alters dbo.Items; dba drops dbo.Gone; a CREATE on another database's Orders must not count
	s.traceDDL(t0.Add(10*time.Minute), "shop", "alter", "Orders", "U", "dev")
	s.traceDDL(t0.Add(20*time.Minute), "shop", "create", "Items", "U", "etl")
	s.traceDDL(t0.Add(25*time.Minute), "shop", "alter", "Items", "U", "dba")
	s.traceDDL(t0.Add(30*time.Minute), "shop", "drop", "Gone", "U", "dba")
	s.traceDDL(t0.Add(30*time.Minute), "other", "alter", "Orders", "U", "intruder")
	t1 := t0.Add(time.Hour)
	r1 := t1
	s.importWith("import_mssql_schema", t1, mdb(5, "shop", created, nil, "read", &r1), db(t1),
		obj(5, "shop", "table", "dbo.Orders", "", "orders v2"), obj(5, "shop", "table", "dbo.Items", "", "items v2"),
		obj(5, "shop", "table", "dbo.New", "", "new"), end)

	rows, err := s.pool.Query(s.ctx, `SELECT identity, who_login, who_n, who_note FROM pgvigil.mssql_schema_changes_window($1, $2, $3, 5)`,
		s.id, t0, t1.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	got := map[string]whoRow{}
	for rows.Next() {
		var w whoRow
		if err := rows.Scan(&w.identity, &w.login, &w.n, &w.note); err != nil {
			t.Fatal(err)
		}
		got[w.identity] = w
	}
	str := func(p *string) string {
		if p == nil {
			return "<nil>"
		}
		return *p
	}
	if w := got["dbo.Orders"]; w.n != 1 || str(w.login) != "dev" {
		t.Errorf("dbo.Orders: %d candidate(s), who %s (want dev alone: the other database's intruder never counts)", w.n, str(w.login))
	}
	if w := got["dbo.Items"]; w.n != 2 || w.login != nil || !strings.Contains(str(w.note), "matched by name") {
		t.Errorf("dbo.Items: %d candidate(s), who %s, note %s (want both etl and dba listed, no single who, 'matched by name')", w.n, str(w.login), str(w.note))
	}
	if w := got["dbo.Gone"]; w.n != 1 || str(w.login) != "dba" {
		t.Errorf("dbo.Gone (dropped): %d candidate(s), who %s (want dba: a drop matches only a drop)", w.n, str(w.login))
	}
	if w := got["dbo.New"]; w.n != 0 || !strings.Contains(str(w.note), "not in the default trace") {
		t.Errorf("dbo.New (added, no trace row): %d candidate(s), note %s", w.n, str(w.note))
	}
}

// B-2 of the build review: Sales (id 8) is dropped and Reports is RESTORED onto id 8 (a routine dev refresh, inside
// one pass): another database, a new baseline - never Sales' objects 'dropped' and Reports' 'added' (red on bce3a4d3:
// the restore under another name was diffed against Sales, and the due answered 'restore').
func TestMssqlSchemaRestoreOtherNameOnAStore(t *testing.T) {
	s := newSchemaStore(t, "sqlserver")
	t0 := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Hour)
	c1, c2 := t0.Add(-48*time.Hour), t0.Add(30*time.Minute)
	r0 := t0
	s.importWith("import_mssql_schema", t0, mdb(8, "Sales", c1, nil, "read", &r0),
		map[string]any{"kind": "db", "dbid": 8, "datname": "Sales", "objects": 1, "read_at": t0},
		obj(8, "Sales", "table", "dbo.s1", "", "s1"), map[string]any{"kind": "end"})
	t1 := t0.Add(time.Hour)
	restored := t0.Add(30 * time.Minute)
	if got := reasons(s.due(t1, map[string]any{"database_id": 8, "name": "Reports", "create_date": c2, "create_local": localOf(c2),
		"restored_at": restored})); got != "8:new" {
		t.Errorf("another database restored onto id 8: due [%s], want [8:new]", got)
	}
	r1 := t1
	s.importWith("import_mssql_schema", t1, mdb(8, "Reports", c2, &restored, "read", &r1),
		map[string]any{"kind": "db", "dbid": 8, "datname": "Reports", "objects": 1, "read_at": t1},
		obj(8, "Reports", "table", "dbo.r1", "", "r1"), map[string]any{"kind": "end"})
	if ch := s.changes(8, t1); len(ch) != 0 {
		t.Errorf("Reports restored onto Sales' id recorded %v, want no change (a new baseline)", ch)
	}
	if p := s.present(8); p["dbo.s1"] || !p["dbo.r1"] {
		t.Errorf("objects after the restore under another name: %v, want only dbo.r1 present", p)
	}
}

// B-3 of the build review: on a server not set to UTC, a daylight-saving change moves the UTC create_date an hour;
// the server-clock create date is the identity, so the database is the same one, diffed, never a new baseline (red
// on bce3a4d3: every database 'new' and re-baselined twice a year, its changes in between never recorded).
func TestMssqlSchemaDaylightSavingOnAStore(t *testing.T) {
	s := newSchemaStore(t, "sqlserver")
	t0 := time.Now().UTC().Truncate(time.Second).Add(-2 * time.Hour)
	created := t0.Add(-100 * 24 * time.Hour)
	r0 := t0
	s.importWith("import_mssql_schema", t0, mdb(9, "hr", created, nil, "read", &r0),
		map[string]any{"kind": "db", "dbid": 9, "datname": "hr", "objects": 1, "read_at": t0},
		obj(9, "hr", "table", "dbo.h1", "", "h1 v1"), map[string]any{"kind": "end"})
	moved := created.Add(time.Hour) // the same create date, moved to UTC by the offset after the change
	t1 := t0.Add(time.Hour)
	if got := reasons(s.due(t1, map[string]any{"database_id": 9, "name": "hr", "create_date": moved, "create_local": localOf(created)})); got != "" {
		t.Errorf("after a daylight-saving change: due [%s], want nothing due", got)
	}
	r1 := t1
	m := mdb(9, "hr", created, nil, "read", &r1)
	m["create_date"] = moved
	s.importWith("import_mssql_schema", t1, m, map[string]any{"kind": "db", "dbid": 9, "datname": "hr", "objects": 1, "read_at": t1},
		obj(9, "hr", "table", "dbo.h1", "", "h1 v2"), map[string]any{"kind": "end"})
	if ch := strings.Join(s.changes(9, t1), ", "); ch != "changed dbo.h1" {
		t.Errorf("a change read after a daylight-saving change recorded [%s], want [changed dbo.h1]", ch)
	}
}

// S-2 and S-3 of the build review: a database too large to store ('partial') is tried again at the reconcile, never
// on every pass (a 'seen' row keeps its 'partial'); a read-only or standby database is read when new and at the
// reconcile only, never on each log restore (red on bce3a4d3: 'new' or 'reconcile' every pass for the large one,
// 'restore' every pass for the standby).
func TestMssqlSchemaDuePartialAndStandbyOnAStore(t *testing.T) {
	s := newSchemaStore(t, "sqlserver")
	now := time.Now().UTC().Truncate(time.Second)
	created := now.Add(-100 * 24 * time.Hour)
	tried, fresh, old := now.Add(-time.Hour), now.Add(-20*time.Minute), now.Add(-30*time.Hour)
	big := mdb(11, "big", created, nil, "partial", nil)
	big["partial_at"], big["note"] = tried, "not snapshotted: over 160 MB"
	grown := mdb(12, "grown", created, nil, "partial", nil)
	grown["partial_at"] = tried
	s.importWith("import_mssql_schema", old, mdb(12, "grown", created, nil, "read", &old),
		map[string]any{"kind": "db", "dbid": 12, "datname": "grown", "objects": 0, "read_at": old}, map[string]any{"kind": "end"})
	s.importWith("import_mssql_schema", tried, big, grown, mdb(13, "standby", created, nil, "read", &fresh),
		map[string]any{"kind": "db", "dbid": 13, "datname": "standby", "objects": 0, "read_at": fresh}, map[string]any{"kind": "seen", "dbid": 12},
		map[string]any{"kind": "end"})
	// a later pass that does not read them: 'seen' keeps the 'partial'
	s.importWith("import_mssql_schema", now.Add(-10*time.Minute), mdb(11, "big", created, nil, "seen", nil), mdb(12, "grown", created, nil, "seen", nil),
		mdb(13, "standby", created, nil, "seen", nil), map[string]any{"kind": "seen", "dbid": 11}, map[string]any{"kind": "seen", "dbid": 12},
		map[string]any{"kind": "seen", "dbid": 13}, map[string]any{"kind": "end"})
	var st string
	if err := s.pool.QueryRow(s.ctx, `SELECT state FROM pgvigil.mssql_schema_dbs WHERE instance_id = $1 AND database_id = 11`, s.id).Scan(&st); err != nil {
		t.Fatal(err)
	}
	if st != "partial" {
		t.Errorf("a 'seen' pass over a 'partial' database left state %q, want partial", st)
	}
	restored := now.Add(-2 * time.Minute)
	list := func() []map[string]any {
		return []map[string]any{{"database_id": 11, "name": "big", "create_local": localOf(created)},
			{"database_id": 12, "name": "grown", "create_local": localOf(created)},
			{"database_id": 13, "name": "standby", "create_local": localOf(created), "restored_at": restored, "read_only": true}}
	}
	if got := reasons(s.due(now, list()...)); got != "" {
		t.Errorf("an hour after the partial attempts, a log restore on the standby: due [%s], want nothing due", got)
	}
	if got := reasons(s.due(now.Add(25*time.Hour), list()...)); got != "11:reconcile 12:reconcile 13:reconcile" {
		t.Errorf("a day later: due [%s], want [11:reconcile 12:reconcile 13:reconcile]", got)
	}
}
