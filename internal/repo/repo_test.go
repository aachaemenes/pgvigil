package repo

import (
	"context"
	"errors"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestSchemaStateSkipsALowerNumber: a store that applied 0110 before a lower-numbered file (0095) arrived is behind,
// and the name is that file; the rule it replaces (the newest applied name against the newest embedded one) read it
// current.
func TestSchemaStateSkipsALowerNumber(t *testing.T) {
	names := []string{"0094_job_scripts_config_history.sql", "0095_pg_depth.sql", "0099_pg_setting_rules.sql", "0102_pg_jobs_deadlocks.sql", "0110_join_release.sql"}
	applied := map[string]bool{"0094_job_scripts_config_history.sql": true, "0099_pg_setting_rules.sql": true, "0110_join_release.sql": true}
	// the store's answer, as pgvigil.schema_missing gives it: the names it lacks, in name order
	var missing []string
	newest := ""
	for _, n := range names {
		if !applied[n] {
			missing = append(missing, n)
		} else if n > newest {
			newest = n
		}
	}
	if newest < names[len(names)-1] {
		t.Fatalf("the case is wrong: the old rule must read it current (newest applied %s)", newest)
	}
	if ok, name := schemaState(names, missing); ok || name != "0095_pg_depth.sql" {
		t.Fatalf("schemaState = %v, %q; want false, 0095_pg_depth.sql", ok, name)
	}
	// the store's order is not trusted: the first in name order still wins
	if ok, name := schemaState(names, []string{"0102_pg_jobs_deadlocks.sql", "0095_pg_depth.sql"}); ok || name != "0095_pg_depth.sql" {
		t.Fatalf("reversed: schemaState = %v, %q; want false, 0095_pg_depth.sql", ok, name)
	}
	// none missing: current, named by the newest; a name the binary does not carry is not counted
	for _, m := range [][]string{nil, {}, {"0200_not_in_this_binary.sql"}} {
		if ok, name := schemaState(names, m); !ok || name != "0110_join_release.sql" {
			t.Fatalf("missing %q: schemaState = %v, %q; want true, 0110_join_release.sql", m, ok, name)
		}
	}
	if ok, name := schemaState(nil, nil); !ok || name != "" {
		t.Fatalf("no names: schemaState = %v, %q", ok, name)
	}
}

// TestSchemaMissingIsTheCollectorsDoor: the newest apply_roles() puts schema_missing on the collector's list (SECURITY
// DEFINER, the collector's EXECUTE) and not on the owner-only one; SchemaCurrent runs under the collector login.
func TestSchemaMissingIsTheCollectorsDoor(t *testing.T) {
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	body, defines := "", ""
	for _, n := range names {
		b, err := migrations.ReadFile("sql/" + n)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "FUNCTION pgvigil.apply_roles()") {
			body = string(b)
		}
		if strings.Contains(string(b), "FUNCTION pgvigil.schema_missing(") {
			defines = n
		}
	}
	if defines == "" {
		t.Fatal("no embedded migration defines pgvigil.schema_missing")
	}
	collector := regexp.MustCompile(`IF f\.proname LIKE 'import\\_%' OR f\.proname IN \(([^)]*)\) THEN`).FindStringSubmatch(body)
	owner := regexp.MustCompile(`ELSIF f\.proname IN \(([^)]*)\) THEN`).FindStringSubmatch(body)
	if collector == nil || owner == nil {
		t.Fatal("the newest apply_roles() no longer has the collector's and the owner-only lists in the shape this test reads")
	}
	if !strings.Contains(collector[1], "'schema_missing'") {
		t.Errorf("schema_missing is not on the collector's list: %s", collector[1])
	}
	if strings.Contains(owner[1], "'schema_missing'") {
		t.Errorf("schema_missing is on the owner-only list: %s", owner[1])
	}
}

// TestSchemaReadIsTheReadersDoor (B6.2 part c #1): serve's check (SchemaCurrentRead) calls no pgvigil function - the
// reader has EXECUTE on none of the collector's - and reads schema_version, which the newest apply_roles() lets the
// reader SELECT (every table of the schema but ui_*)
func TestSchemaReadIsTheReadersDoor(t *testing.T) {
	if f := regexp.MustCompile(`pgvigil\.\w+\s*\(`).FindString(sqlSchemaMissingRead); f != "" {
		t.Errorf("serve's schema read calls %s): the reader's login may not", f)
	}
	if !strings.Contains(sqlSchemaMissingRead, "pgvigil.schema_version") {
		t.Errorf("serve's schema read does not read pgvigil.schema_version")
	}
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	body := ""
	for _, n := range names {
		if b, err := migrations.ReadFile("sql/" + n); err == nil && strings.Contains(string(b), "FUNCTION pgvigil.apply_roles()") {
			body = string(b)
		}
	}
	if !regexp.MustCompile(`(?s)IF t\.relname LIKE 'ui\\_%' THEN\s*EXECUTE format\('REVOKE ALL ON %s FROM pgvigil_reader', t\.rel\);\s*ELSE\s*EXECUTE format\('GRANT SELECT ON %s TO pgvigil_reader', t\.rel\);`).MatchString(body) {
		t.Errorf("the newest apply_roles() no longer gives the reader SELECT on every table but ui_* in the shape this test reads")
	}
}

// TestSchemaCurrentReadAsTheReader (B6.2 part c #1, a box row): on a migrated store, as pgvigil_reader (SET LOCAL ROLE
// in a transaction rolled back), SchemaCurrentWith fails 42501 (the collector's schema_missing) and SchemaCurrentRead
// reads current, named by the newest file. Needs an owner's DSN of a scratch repository that may SET ROLE
// pgvigil_reader: PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestSchemaCurrentReadAsTheReader(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	latest := names[len(names)-1]
	as := func(f func(q RowQuerier) (bool, string, error)) (bool, string, error) {
		tx, err := r.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		if _, err := tx.Exec(ctx, `SET LOCAL ROLE pgvigil_reader`); err != nil {
			t.Fatalf("SET LOCAL ROLE pgvigil_reader (the DSN's login must be able to): %v", err)
		}
		return f(tx)
	}
	_, _, err = as(func(q RowQuerier) (bool, string, error) { return SchemaCurrentWith(ctx, q) })
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "42501" {
		t.Errorf("as the reader, SchemaCurrentWith: err %v, want 42501 (the collector's door: the case the reader's read is for)", err)
	}
	if ok, name, err := as(func(q RowQuerier) (bool, string, error) { return SchemaCurrentRead(ctx, q) }); err != nil || !ok || name != latest {
		t.Errorf("as the reader, SchemaCurrentRead = %v, %q, %v; want true, %s", ok, name, err, latest)
	}
}

// TestSchemaCurrentReadsALowerMissingFile: on a migrated store, SchemaCurrent reads current; with the 0095 row taken
// out of schema_version it reads behind and names 0095, while schema_latest() still gives the newest. Needs an owner's
// DSN of a scratch repository: PGVIGIL_REPO_TEST_DSN (skipped without it); the row is put back after.
func TestSchemaCurrentReadsALowerMissingFile(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close) // registered first, so it runs after the put-back below (a defer would close the pool before it)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	latest := names[len(names)-1]
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || !ok || name != latest {
		t.Fatalf("migrated: SchemaCurrent = %v, %q, %v; want true, %s", ok, name, err, latest)
	}
	const lower = "0095_pg_depth.sql"
	var at time.Time
	if err := r.pool.QueryRow(ctx, `DELETE FROM pgvigil.schema_version WHERE version = $1 RETURNING applied_at`, lower).Scan(&at); err != nil {
		t.Fatalf("take out %s: %v", lower, err)
	}
	t.Cleanup(func() {
		if _, err := r.pool.Exec(context.Background(), `INSERT INTO pgvigil.schema_version (version, applied_at) VALUES ($1, $2) ON CONFLICT DO NOTHING`, lower, at); err != nil {
			t.Errorf("put back %s: %v", lower, err)
		}
	})
	var have string
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.schema_latest()`).Scan(&have); err != nil || have != latest {
		t.Fatalf("schema_latest() = %q, %v; want %s (the old rule's current)", have, err, latest)
	}
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || ok || name != lower {
		t.Fatalf("without %s: SchemaCurrent = %v, %q, %v; want false, %s", lower, ok, name, err, lower)
	}
}

// schemaDef is one function or view of the pgvigil schema as the store holds it: its name, its definition as the
// catalog prints it, and the statement that puts it back.
type schemaDef struct{ kind, name, def, stmt string }

// schemaDefinitions reads every function, procedure and view of the pgvigil schema; the list in name order, the map
// by name to the definition, for the comparison.
func schemaDefinitions(ctx context.Context, r *Repo) (map[string]string, error) {
	list, err := schemaDefinitionList(ctx, r)
	if err != nil {
		return nil, err
	}
	m := make(map[string]string, len(list))
	for _, d := range list {
		m[d.name] = d.def
	}
	return m, nil
}

func schemaDefinitionList(ctx context.Context, r *Repo) ([]schemaDef, error) {
	rows, err := r.pool.Query(ctx, `
SELECT 'function', p.oid::regprocedure::text, pg_get_functiondef(p.oid), pg_get_functiondef(p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'pgvigil' AND p.prokind IN ('f', 'p')
UNION ALL
SELECT 'view', c.oid::regclass::text, pg_get_viewdef(c.oid), 'CREATE OR REPLACE VIEW ' || c.oid::regclass::text || ' AS ' || pg_get_viewdef(c.oid)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pgvigil' AND c.relkind = 'v'
 ORDER BY 1, 2`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []schemaDef
	for rows.Next() {
		var d schemaDef
		if err := rows.Scan(&d.kind, &d.name, &d.def, &d.stmt); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// TestSchemaCurrentBeforeSchemaMissing: a store from before the file that creates schema_missing() (the function and
// that file's row taken out) reads behind and names the newest embedded migration, the old contract (docs/upgrade.md,
// scripts/proof-upgrade.sh); Migrate runs that file again and the store reads current. A store that records the file
// without the function is an error naming the repair, and the repair (delete the row, migrate) works. Needs an owner's
// DSN of a scratch repository: PGVIGIL_REPO_TEST_DSN (skipped without it); the store is left migrated.
func TestSchemaCurrentBeforeSchemaMissing(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	// Migrate below runs the file that creates schema_missing() a second time, and that file also replaces functions and
	// views later files replaced again (purge(), the findings view, apply_roles()): the store would keep that file's old
	// bodies, and a later test on the same store reads them (TestPoolMinutePurgedOnAStore failed after this one). Every
	// function and view of the schema is read now and put back as it was when the test ends; a definition that cannot be
	// put back fails the test by name.
	defs, err := schemaDefinitionList(ctx, r)
	if err != nil {
		t.Fatal(err)
	}
	// a view rebuilt from the catalog's own text prints differently from one made from its migration's text (a later
	// UNION arm's literal gains 'AS text': the same view, another print), so each view is rebuilt once from its own
	// text first and read again: the definition kept is the one a put-back reproduces
	for _, d := range defs {
		if d.kind == "view" {
			if _, err := r.pool.Exec(ctx, d.stmt); err != nil {
				t.Fatalf("rebuilding %s from its own text: %v", d.name, err)
			}
		}
	}
	if defs, err = schemaDefinitionList(ctx, r); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { // registered before the cleanup below, so it runs after it (the store migrated again first)
		c := context.Background()
		now, err := schemaDefinitions(c, r)
		if err != nil {
			t.Errorf("the definitions after the test: %v", err)
			return
		}
		for _, d := range defs {
			if now[d.name] == d.def {
				continue
			}
			if _, err := r.pool.Exec(c, d.stmt); err != nil {
				t.Errorf("putting back %s %s: %v", d.kind, d.name, err)
			}
		}
		if after, err := schemaDefinitions(c, r); err == nil {
			for _, d := range defs {
				if a := after[d.name]; a != d.def {
					i := 0
					for i < len(a) && i < len(d.def) && a[i] == d.def[i] {
						i++
					}
					lo := max(0, i-60)
					t.Errorf("%s %s differs from its definition before the test (%d bytes before, %d after, the test's change %v): at byte %d before %q, after %q",
						d.kind, d.name, len(d.def), len(a), now[d.name] != d.def, i, d.def[lo:min(len(d.def), i+120)], a[lo:min(len(a), i+120)])
				}
			}
		}
	})
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	latest, defines := names[len(names)-1], schemaMissingFile(names)
	if defines == "" {
		t.Fatal("no embedded migration creates pgvigil.schema_missing")
	}
	// the rows of the files after the one that creates schema_missing: taken out to make a store from before it (its
	// newest row below that file, as schema_latest() reads it), put back as they were - never run a second time
	type versionRow struct {
		version string
		at      time.Time
	}
	var later []versionRow
	putBack := func(c context.Context) {
		for _, v := range later {
			_, _ = r.pool.Exec(c, `INSERT INTO pgvigil.schema_version (version, applied_at) VALUES ($1, $2) ON CONFLICT (version) DO NOTHING`, v.version, v.at)
		}
	}
	t.Cleanup(func() { // whatever failed above, the store ends with every later row, the function and the file's row
		c := context.Background()
		putBack(c)
		var gone bool
		if err := r.pool.QueryRow(c, `SELECT to_regprocedure('pgvigil.schema_missing(text[])') IS NULL`).Scan(&gone); err == nil && gone {
			_, _ = r.pool.Exec(c, `DELETE FROM pgvigil.schema_version WHERE version = $1`, defines)
			_, _ = r.Migrate(c)
		}
	})
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := r.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	// a store from before the file: no schema_version row at or above it. Taking out the file's row alone left the
	// later files' rows, so schema_latest() read the newest of them and the check took the 'recorded without the
	// function' path (red once any file after it existed).
	rows, err := r.pool.Query(ctx, `SELECT version, applied_at FROM pgvigil.schema_version WHERE version > $1 ORDER BY version`, defines)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var v versionRow
		if err := rows.Scan(&v.version, &v.at); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		later = append(later, v)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	exec(`DROP FUNCTION pgvigil.schema_missing(text[])`)
	exec(`DELETE FROM pgvigil.schema_version WHERE version >= $1`, defines)
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || ok || name != latest {
		t.Fatalf("before %s (%d later rows out): SchemaCurrent = %v, %q, %v; want false, %s (the newest)", defines, len(later), ok, name, err, latest)
	}
	putBack(ctx) // the later files stay applied: only the file that creates schema_missing runs again
	if n, err := r.Migrate(ctx); err != nil || n < 1 {
		t.Fatalf("migrate after taking %s out: %d applied, %v", defines, n, err)
	}
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || !ok || name != latest {
		t.Fatalf("migrated again: SchemaCurrent = %v, %q, %v; want true, %s", ok, name, err, latest)
	}
	// the file recorded, the function gone: the error names the repair, and the repair works
	exec(`DROP FUNCTION pgvigil.schema_missing(text[])`)
	repair := "DELETE FROM pgvigil.schema_version WHERE version = '" + defines + "'"
	if ok, _, err := r.SchemaCurrent(ctx); err == nil || ok || !strings.Contains(err.Error(), repair) {
		t.Fatalf("recorded without the function: SchemaCurrent = %v, %v; want an error naming %q", ok, err, repair)
	}
	exec(repair)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatalf("migrate after the repair: %v", err)
	}
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || !ok || name != latest {
		t.Fatalf("after the repair: SchemaCurrent = %v, %q, %v; want true, %s", ok, name, err, latest)
	}
}
