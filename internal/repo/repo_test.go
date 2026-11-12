package repo

import (
	"context"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
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
