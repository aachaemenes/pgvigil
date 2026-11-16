package repo

import (
	"strings"
	"testing"
	"time"
)

// 0275 re-creates 0267's import_schema whole with ONE arm and one payload column (task A26-PG): with both taken back
// out, 0275's function is 0267's, character for character - an edit of either that the other does not carry fails here.
func TestImportSchema0275Is0267PlusTheBaselineArm(t *testing.T) {
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
	const column = `, r->>'hash_prev' AS hash_prev`
	const arm = `      -- A26-PG (0275): a PostgreSQL 14+ SQL-standard body read for the first time (the code before it hashed the
      -- function's empty prosrc): a present stored row whose hash is the read's hash_prev, and not the read's hash,
      -- takes the read's definition, hash and def_hash here, so the diff below records no change for it and the
      -- upsert keeps its last_changed - the upgrade's first read is the body's baseline. Any other difference of the
      -- row (owner, ACL, settings) leaves hash_prev unequal: its change rows are recorded as before.
      UPDATE pgvigil.schema_objects o SET definition = i.definition, hash = i.hash, def_hash = i.def_hash
        FROM pgv_schema_in i
       WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
         AND i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity
         AND i.hash_prev IS NOT NULL AND o.hash = i.hash_prev AND o.hash <> i.hash;
`
	got := body("0275_schema_sqlbody.sql")
	if strings.Count(got, arm) != 1 || strings.Count(got, column) != 1 {
		t.Fatalf("0275's import_schema holds the arm %d times and the column %d times, want once each", strings.Count(got, arm), strings.Count(got, column))
	}
	got = strings.Replace(strings.Replace(got, arm, "", 1), column, "", 1)
	if want := body("0267_mssql_schema.sql"); got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("0275's import_schema differs from 0267's beyond the arm at its line %d:\n0275: %s\n0267: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("0275's import_schema has %d lines, 0267's %d", len(gl), len(wl))
	}
}

// sqlBodyFn is one function row of the schema payload with its own hash (and hash_prev when given).
func sqlBodyFn(identity, def, owner, hash, hashPrev string) map[string]any {
	r := map[string]any{"kind": "obj", "dbid": 1, "datname": "a", "object_kind": "function", "identity": identity,
		"schema_name": "public", "object_name": identity, "definition": def, "owner": owner, "hash": hash, "def_hash": "d:" + def}
	if hashPrev != "" {
		r["hash_prev"] = hashPrev
	}
	return r
}

// A26-PG on a store (red on a store at 0267: the upgrade's first read records one false 'changed' row per SQL-standard
// function): f's first read by the new code carries hash_prev = the stored hash - no change row, the stored definition
// and hash are the new ones, last_changed kept; f's next body change IS a change; g's owner changed in the same interval
// as its body was first read (hash_prev unequal) - its change rows are recorded; h, stored as dropped, comes back with a
// matching hash_prev - an 'added' row, never a baseline.
func TestSchemaSQLBodyBaselineOnAStore(t *testing.T) {
	s := newSchemaStore(t, "postgres")
	t0 := time.Now().UTC().Truncate(time.Second).Add(-3 * time.Hour)
	db := func(at time.Time) map[string]any {
		return map[string]any{"kind": "db", "dbid": 1, "datname": "a", "objects": 3, "read_at": at}
	}
	end := map[string]any{"kind": "end"}
	const old = "function () returns integer language sql volatile cost 100 body sha256:e3b0c44298fc1c14"
	const v1 = "function () returns integer language sql volatile cost 100 body sha256:1111111111111111\nBEGIN ATOMIC\n SELECT 1;\nEND"
	const v2 = "function () returns integer language sql volatile cost 100 body sha256:2222222222222222\nBEGIN ATOMIC\n SELECT 2;\nEND"
	// t0: the old code's read (no hash_prev); t1: h is gone; t2: the new code's first read; t3: f's body changes
	s.importWith("import_schema", t0, db(t0), sqlBodyFn("public.f()", old, "app", "F0", ""), sqlBodyFn("public.g()", old, "app", "G0", ""),
		sqlBodyFn("public.h()", old, "app", "H0", ""), end)
	t1 := t0.Add(time.Hour)
	s.importWith("import_schema", t1, db(t1), sqlBodyFn("public.f()", old, "app", "F0", ""), sqlBodyFn("public.g()", old, "app", "G0", ""), end)
	t2 := t1.Add(time.Hour)
	s.importWith("import_schema", t2, db(t2), sqlBodyFn("public.f()", v1, "app", "F1", "F0"), sqlBodyFn("public.g()", v1, "dba", "G1", "G0-as-dba"),
		sqlBodyFn("public.h()", v1, "app", "H1", "H0"), end)
	if got, want := strings.Join(s.changes(1, t2), "|"), "added public.h()|changed public.g()|changed public.g()"; got != want {
		t.Errorf("the new code's first read recorded %q, want %q (f's body read is a baseline, not a change)", got, want)
	}
	var def, hash string
	var lastChanged *time.Time
	if err := s.pool.QueryRow(s.ctx, `SELECT definition, hash, last_changed FROM pgvigil.schema_objects
	                                    WHERE instance_id = $1 AND dbid = 1 AND identity = 'public.f()'`, s.id).Scan(&def, &hash, &lastChanged); err != nil {
		t.Fatal(err)
	}
	if def != v1 || hash != "F1" || lastChanged != nil {
		t.Errorf("f after its baseline: definition %q, hash %q, last_changed %v; want the new read's, F1, kept (NULL)", def, hash, lastChanged)
	}
	t3 := t2.Add(time.Hour)
	s.importWith("import_schema", t3, db(t3), sqlBodyFn("public.f()", v2, "app", "F2", "F0"), sqlBodyFn("public.g()", v1, "dba", "G1", "G0-as-dba"),
		sqlBodyFn("public.h()", v1, "app", "H1", "H0"), end)
	if got, want := strings.Join(s.changes(1, t3), "|"), "changed public.f()"; got != want {
		t.Errorf("f's body change after the baseline recorded %q, want %q", got, want)
	}
}
