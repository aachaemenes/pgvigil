package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// haJoinFreshStore is a database made for one test on the server PGVIGIL_REPO_TEST_DSN names (skipped without it; that
// login must be able to create a database), migrated from nothing by this binary's embedded files in name order and
// dropped when the test ends. A fresh database, not the scratch store the other store tests share: the HA join's
// faults are faults of the ORDER the files run in (0141-0144 and 0150 arrive below the join's own 0190, which is
// edited in place), and a store that applied an older 0190 never runs the new one.
func haJoinFreshStore(t *testing.T, ctx context.Context) *Repo {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("pgvha_%d", time.Now().UnixNano()%1_000_000_000)
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+pgx.Identifier{name}.Sanitize()); err != nil {
		_ = admin.Close(ctx)
		t.Fatalf("a fresh database for the HA join's test: %v", err)
	}
	t.Cleanup(func() { // registered first: it runs last, after the store's pool below is closed
		bg := context.Background()
		if _, err := admin.Exec(bg, `DROP DATABASE IF EXISTS `+pgx.Identifier{name}.Sanitize()+` WITH (FORCE)`); err != nil {
			t.Errorf("drop %s: %v", name, err)
		}
		_ = admin.Close(bg)
	})
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Database = name
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-repo"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	r := &Repo{pool: pool}
	if n, err := r.Migrate(ctx); err != nil {
		t.Fatalf("a fresh migrate of the joined tree stopped after %d file(s): %v", n, err)
	}
	return r
}

// TestHAJoinOnAFreshStore: what the HA join (task 389) must hold on a store migrated from nothing.
//
//  1. The migrate itself ends, and the store reads current. 0141 stores threshold keys in megabytes (standby_lag_bytes,
//     slot_safe_wal, slot_growth) and 0150 one as a count (standby_conflicts); the join's 0190 runs after both and sets
//     the keys' unit check again for the slow-connect tier's 'seconds': its list holds every unit a stored key has
//     (a list of seconds, minutes, hours and days alone fails on the stored rows and ends the migrate at 0190).
func TestHAJoinOnAFreshStore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	r := haJoinFreshStore(t, ctx)
	str := func(sql string, args ...any) string {
		t.Helper()
		var s string
		if err := r.pool.QueryRow(ctx, sql, args...).Scan(&s); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		return s
	}
	want := func(what, got, exp string) {
		t.Helper()
		if got != exp {
			t.Errorf("%s:\n got  %s\n want %s", what, got, exp)
		}
	}

	// 1. the migrate ended (haJoinFreshStore), the store is current, the unit check takes every stored unit
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || !ok || name != names[len(names)-1] {
		t.Fatalf("the fresh store: SchemaCurrent = %v, %q, %v; want true, %s", ok, name, err, names[len(names)-1])
	}
	check := str(`SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
	               WHERE c.conrelid = 'pgvigil.pg_threshold_keys'::regclass AND c.conname = 'pg_threshold_keys_unit_check'`)
	for _, u := range []string{"seconds", "minutes", "hours", "days", "MB", "count"} {
		if !strings.Contains(check, "'"+u+"'") {
			t.Errorf("pg_threshold_keys' unit check lacks %q: %s", u, check)
		}
	}
	want("the keys in megabytes and counts (0141, 0150) and the slow-connect key (0190)",
		str(`SELECT string_agg(key || '=' || unit, ' ' ORDER BY key) FROM pgvigil.pg_threshold_keys
		      WHERE unit IN ('MB', 'count') OR key = 'connect_time'`),
		"connect_time=seconds slot_growth=MB slot_safe_wal=MB standby_conflicts=count standby_lag_bytes=MB")
}
