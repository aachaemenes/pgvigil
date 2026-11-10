package collect

import (
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// TestSchemaFinish: a function's body becomes its hash at the end of the definition and leaves the row; the hash covers
// kind, definition, owner and ACL (a change of any of them changes it, the same row twice gives the same hash); a long
// definition is cut after hashing, so a change past the cut still changes the hash.
func TestSchemaFinish(t *testing.T) {
	mk := func(def, owner, acl string, body any) Row {
		r := Row{"kind": "obj", "object_kind": "function", "identity": "public.f(integer)", "definition": def, "owner": owner, "acl": acl}
		if body != nil {
			r["body"] = body
		}
		return r
	}
	a, b := mk("function returns integer language sql", "app", "", "select 1"), mk("function returns integer language sql", "app", "", "select 1")
	schemaFinish([]Row{a, b})
	if _, ok := a["body"]; ok {
		t.Fatal("the body stayed in the row")
	}
	if !strings.HasPrefix(a["definition"].(string), "function returns integer language sql body sha256:") || len(a["definition"].(string)) != len("function returns integer language sql body sha256:")+16 {
		t.Fatalf("definition %q", a["definition"])
	}
	if a["hash"] != b["hash"] || len(a["hash"].(string)) != 64 {
		t.Fatalf("the same row twice: %v and %v", a["hash"], b["hash"])
	}
	for name, r := range map[string]Row{
		"body":  mk("function returns integer language sql", "app", "", "select 2"),
		"owner": mk("function returns integer language sql", "dba", "", "select 1"),
		"acl":   mk("function returns integer language sql", "app", "{app=X/app}", "select 1"),
		"def":   mk("function returns bigint language sql", "app", "", "select 1"),
	} {
		schemaFinish([]Row{r})
		if r["hash"] == a["hash"] {
			t.Errorf("a %s change kept the hash", name)
		}
	}
	// the kind is in the hash: a view and a table with the same text are not the same object
	v, w := Row{"object_kind": "view", "definition": "x"}, Row{"object_kind": "table", "definition": "x"}
	schemaFinish([]Row{v, w})
	if v["hash"] == w["hash"] {
		t.Error("the kind is not in the hash")
	}
	// fields joined with a separator: ("ab", "") and ("a", "b") differ
	p, q := Row{"object_kind": "column", "definition": "ab", "owner": ""}, Row{"object_kind": "column", "definition": "a", "owner": "b"}
	schemaFinish([]Row{p, q})
	if p["hash"] == q["hash"] {
		t.Error("the fields run together in the hash")
	}
	// a cut definition: the change past the cut still shows in the hash
	long1, long2 := strings.Repeat("x", schemaMaxDef+10)+"1", strings.Repeat("x", schemaMaxDef+10)+"2"
	l1, l2 := Row{"object_kind": "view", "definition": long1}, Row{"object_kind": "view", "definition": long2}
	schemaFinish([]Row{l1, l2})
	if l1["definition"] != l2["definition"] || !strings.HasSuffix(l1["definition"].(string), fmt.Sprintf("(cut at %d characters)", schemaMaxDef)) {
		t.Fatalf("the cut: %q", l1["definition"].(string)[schemaMaxDef-5:])
	}
	if l1["hash"] == l2["hash"] {
		t.Error("a change past the cut kept the hash")
	}
}

// TestSchemaCut: a cut never splits a character; a text at the limit stays whole.
func TestSchemaCut(t *testing.T) {
	if got := schemaCut("abc", 3); got != "abc" {
		t.Fatalf("at the limit: %q", got)
	}
	got := schemaCut("ééééé", 3)
	if !utf8.ValidString(got) || !strings.HasPrefix(got, "ééé ...") {
		t.Fatalf("cut: %q", got)
	}
}

// TestSchemaDDLLogSQL: the opt-in block names both events, never fails the DDL it records, grants the login a read
// and nothing more, and carries its undo.
func TestSchemaDDLLogSQL(t *testing.T) {
	for _, want := range []string{
		"CREATE TABLE public.pgvigil_ddl_log", "ON ddl_command_end", "ON sql_drop",
		"pg_event_trigger_ddl_commands()", "pg_event_trigger_dropped_objects()",
		"EXCEPTION WHEN OTHERS THEN", "RAISE WARNING", "SECURITY DEFINER", "SET search_path = pg_catalog, pg_temp",
		"GRANT SELECT ON public.pgvigil_ddl_log TO <login>;", "REVOKE ALL ON public.pgvigil_ddl_log FROM PUBLIC;",
		"-- DROP EVENT TRIGGER pgvigil_ddl_end; DROP EVENT TRIGGER pgvigil_ddl_drop;",
		"CREATE EVENT TRIGGER pgvigil_ddl_end", "CREATE EVENT TRIGGER pgvigil_ddl_drop",
		// temporary objects and extension scripts are not logged (the review fold: a temp table per request filled it)
		"WHERE NOT in_extension AND schema_name IS DISTINCT FROM 'pg_temp'", "WHERE original AND NOT is_temporary",
		"DELETE only",
		// the join review's fold: one transaction behind the publication guard, a one-second lock wait at most, no
		// password kept
		"BEGIN;   -- pgvigil_ddl_log", "COMMIT;  -- pgvigil_ddl_log", "DO $guard$", "WHERE puballtables",
		"pg_publication_namespace", "set_config('pgvigil.publication_ok', 'on', true)", "SET lock_timeout = '1s'",
		"'CREATE USER MAPPING'", "'ALTER USER MAPPING'", "'CREATE SERVER'", "'ALTER SERVER'", "'CREATE SUBSCRIPTION'",
		"'ALTER SUBSCRIPTION'", "current_query() ~* '(password|secret)'", "(statement not kept: it may carry a password)",
	} {
		if !strings.Contains(SchemaDDLLogSQL, want) {
			t.Errorf("SchemaDDLLogSQL lacks %q", want)
		}
	}
	for _, bad := range []string{"GRANT INSERT", "GRANT ALL", "TO PUBLIC"} {
		if strings.Contains(SchemaDDLLogSQL, bad) {
			t.Errorf("SchemaDDLLogSQL holds %q", bad)
		}
	}
	// the names the collector looks for are the names the block creates
	for _, name := range []string{"pgvigil_ddl_log", "pgvigil_ddl_end", "pgvigil_ddl_drop"} {
		if !strings.Contains(schemaDDLStateSQL, "'"+name+"'") {
			t.Errorf("schemaDDLStateSQL does not look for %s", name)
		}
	}
}

// TestSchemaObjectsSQL: the read leaves out the catalogs, temporary relations and extension members, and the NOT NULL
// constraints of PostgreSQL 18; identities are pg_identify_object's (the event trigger's text).
func TestSchemaObjectsSQL(t *testing.T) {
	for _, want := range []string{
		"nspname NOT IN ('pg_catalog', 'information_schema')", "'^pg_(toast|temp_|toast_temp_)'", "deptype = 'e'",
		"relpersistence <> 't'", "k.contype <> 'n'", "NOT g.tgisinternal", "pg_identify_object('pg_class'::regclass, c.oid, a.attnum)",
		"LIMIT $1",
		// the review fold: PostgreSQL 18's virtual columns, and the function attributes a CREATE OR REPLACE can change
		"attgenerated = 'v'", "pg_get_function_arguments(p.oid)", "p.proparallel", "p.proleakproof", "p.procost",
	} {
		if !strings.Contains(schemaObjectsSQL, want) {
			t.Errorf("schemaObjectsSQL lacks %q", want)
		}
	}
	if strings.Contains(schemaObjectsSQL, "md5(") {
		t.Error("md5() fails on a FIPS server: the body is hashed in Go")
	}
}

// TestSchemaDDLCursor: a capped read hands the import a cursor one hour less a microsecond past its last row, so the
// next read (cursor less one hour, exclusive) starts at that row and goes on instead of re-reading the same window.
func TestSchemaDDLCursor(t *testing.T) {
	last := time.Date(2026, 11, 10, 1, 25, 1, 242300000, time.UTC)
	r := schemaDDLCursor("erp", last)
	if r["kind"] != "ddl_cursor" || r["datname"] != "erp" {
		t.Fatalf("row %v", r)
	}
	next := r["read_to"].(time.Time).Add(-time.Hour)
	if !next.Before(last) || last.Sub(next) != time.Microsecond {
		t.Fatalf("the next read starts after %v, the last row is %v", next, last)
	}
	// the page read goes on from the last row by (logged_at, log_id), not by the overlap
	for _, want := range []string{"(logged_at, log_id) > ($2::timestamptz, $3::bigint)", "ORDER BY logged_at, log_id"} {
		if !strings.Contains(schemaDDLReadSQL, want) {
			t.Errorf("schemaDDLReadSQL lacks %q", want)
		}
	}
	if schemaDDLMax < schemaDDLPage {
		t.Errorf("the run cap %d is under one page %d", schemaDDLMax, schemaDDLPage)
	}
}

// TestSchemaDefHash: the definition's own hash is kept beside the whole hash, so a change past the cut is seen when the
// owner changes in the same read (the join review: the fourth diff INSERT needed owner and ACL equal).
func TestSchemaDefHash(t *testing.T) {
	long1, long2 := strings.Repeat("x", schemaMaxDef+10)+"1", strings.Repeat("x", schemaMaxDef+10)+"2"
	a := Row{"object_kind": "view", "definition": long1, "owner": "app"}
	b := Row{"object_kind": "view", "definition": long2, "owner": "dba"}
	c := Row{"object_kind": "view", "definition": long1, "owner": "dba"}
	schemaFinish([]Row{a, b, c})
	if a["definition"] != b["definition"] || a["def_hash"] == b["def_hash"] || len(a["def_hash"].(string)) != 64 {
		t.Fatalf("def_hash: %v, %v", a["def_hash"], b["def_hash"])
	}
	if a["def_hash"] != c["def_hash"] || a["hash"] == c["hash"] {
		t.Fatal("an owner change alone moved def_hash, or kept the whole hash")
	}
}

// TestSchemaSplit: the event trigger's rows go in parts under the cap, in order, every row once, a row over the cap a
// part of its own; the estimate grows with the text.
func TestSchemaSplit(t *testing.T) {
	var rows []Row
	for i := 0; i < 100; i++ {
		rows = append(rows, Row{"kind": "ddl", "log_id": int64(i), "statement": strings.Repeat("s", 100)})
	}
	rows = append(rows, Row{"kind": "ddl", "log_id": int64(100), "statement": strings.Repeat("s", 5000)})
	one := schemaPayloadSize(rows[:1])
	if one < 100 || schemaPayloadSize(rows[:2]) != 2*one {
		t.Fatalf("estimate %d", one)
	}
	parts := schemaSplit(rows, 10*one)
	n := 0
	for i, p := range parts {
		if len(p) > 1 && schemaPayloadSize(p) > 10*one {
			t.Errorf("part %d is %d over %d", i, schemaPayloadSize(p), 10*one)
		}
		for _, r := range p {
			if r["log_id"] != int64(n) {
				t.Fatalf("part %d: log_id %v, want %d", i, r["log_id"], n)
			}
			n++
		}
	}
	if n != len(rows) || len(parts) != 11 || len(parts[10]) != 1 {
		t.Fatalf("%d rows in %d parts (last %d)", n, len(parts), len(parts[len(parts)-1]))
	}
	if len(schemaSplit(nil, 10)) != 0 {
		t.Error("no rows, a part")
	}
}

// TestSchemaPayloadCap: the default cap stays well under PostgreSQL's 256 MB jsonb array limit, and an object row at
// the definition cut is counted at its size (50,000 such rows pass the cap: such a database is an error, not a failed
// instance).
func TestSchemaPayloadCap(t *testing.T) {
	if schemaMaxPayload >= 268435455*3/4 {
		t.Fatalf("cap %d is near the jsonb limit", schemaMaxPayload)
	}
	r := Row{"kind": "obj", "object_kind": "view", "definition": strings.Repeat("x", schemaMaxDef)}
	if n := schemaPayloadSize([]Row{r}); n < schemaMaxDef || 50000*n <= schemaMaxPayload {
		t.Fatalf("a cut row is %d bytes; 50,000 of them %d against the cap %d", n, 50000*n, schemaMaxPayload)
	}
	t.Setenv("PGVIGIL_SCHEMA_MAX_PAYLOAD", "4096")
	if schemaEnvInt("PGVIGIL_SCHEMA_MAX_PAYLOAD", schemaMaxPayload) != 4096 {
		t.Error("the proof's override is not read")
	}
	t.Setenv("PGVIGIL_SCHEMA_MAX_PAYLOAD", "-1")
	if schemaEnvInt("PGVIGIL_SCHEMA_MAX_PAYLOAD", schemaMaxPayload) != schemaMaxPayload {
		t.Error("a bad override replaced the cap")
	}
}

// runBatched is RunOnce's batch path, wired in collect.go by the wave's join (the slice does not own collect.go); the
// proof's section G runs it end to end.
var _ = runBatched
