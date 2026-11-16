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
//  2. A threshold key is taken at the instance and database level by an instance of the key's engines (0142's
//     pg_threshold_keys.engines): a SQL Server key (0142's repl_latency, 0143's ag_data_loss and logship_restore_age)
//     by a SQL Server instance and not by a PostgreSQL one, a PostgreSQL key the other way round, and uptime and the
//     slow-connect tier's connect_time by both. 0142 and 0190 each re-create import_pg_threshold whole and 0190 runs
//     last: its function reads the engines too, and its connect_time row names both.
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

	// 2. the engines rule of import_pg_threshold, as the store ends with it
	sfx := time.Now().UnixNano() % 1_000_000
	var ms, pg int
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("hajoin-ms-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("hajoin-pg-%d", sfx)).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	set := func(key, level string, inst int, db, warn, crit string) string {
		t.Helper()
		return str(`SELECT x->>'outcome' || ': ' || (x->>'detail')
		              FROM pgvigil.import_pg_threshold(now(), jsonb_strip_nulls(jsonb_build_object('op', 'set', 'ui_user', 'ha-join-test',
		                     'key', $1::text, 'level', $2::text, 'instance_id', $3::text, 'datname', nullif($4::text, ''),
		                     'warn', $5::text, 'crit', $6::text))) x`, key, level, fmt.Sprint(inst), db, warn, crit)
	}
	want("the engines of the two keys both engines take",
		str(`SELECT string_agg(key || '=' || array_to_string(engines, '+'), ' ' ORDER BY key) FROM pgvigil.pg_threshold_keys
		      WHERE key IN ('uptime', 'connect_time')`), "connect_time=postgres+sqlserver uptime=postgres+sqlserver")
	want("0142's repl_latency at a SQL Server instance", set("repl_latency", "instance", ms, "", "5", "30"), "done: set")
	want("0142's repl_latency at a PostgreSQL instance", set("repl_latency", "instance", pg, "", "5", "30"),
		fmt.Sprintf("refused: no SQL Server instance %d", pg))
	want("0143's ag_data_loss at a SQL Server instance", set("ag_data_loss", "instance", ms, "", "1", "5"), "done: set")
	want("0143's logship_restore_age at a SQL Server instance's database", set("logship_restore_age", "database", ms, "db1", "60", "120"), "done: set")
	want("0141's standby_replay_lag at a SQL Server instance", set("standby_replay_lag", "instance", ms, "", "30", "300"),
		fmt.Sprintf("refused: no PostgreSQL instance %d", ms))
	want("0141's standby_replay_lag at a PostgreSQL instance", set("standby_replay_lag", "instance", pg, "", "30", "300"), "done: set")
	want("connect_time at a SQL Server instance", set("connect_time", "instance", ms, "", "1", "2"), "done: set")
	want("connect_time at a PostgreSQL instance", set("connect_time", "instance", pg, "", "1", "2"), "done: set")
	want("uptime at a SQL Server instance", set("uptime", "instance", ms, "", "48", "12"), "done: set")
}
