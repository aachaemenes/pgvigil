package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// remoteFixture: until migration 0329 is on this branch's tree, a store row seeds tables NAMED AS 0329's views, with
// their columns (docs/remote-bundle-format.md's last section: remote_instance_state, remote_collection_interval,
// remote_collector_state). With 0329's own views present it answers false: the row then seeds through 0329's
// ledgers (a later row, the slice lead's proof meanwhile).
func remoteFixture(ctx context.Context, t *testing.T, pool *pgxpool.Pool) bool {
	t.Helper()
	var kind *string
	if err := pool.QueryRow(ctx, `SELECT c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	                              WHERE n.nspname = 'pgvigil' AND c.relname = 'remote_instance_state'`).Scan(&kind); err != nil && err != pgx.ErrNoRows {
		t.Fatal(err)
	}
	if kind != nil && *kind == "v" {
		return false
	}
	for _, q := range []string{
		`CREATE TABLE IF NOT EXISTS pgvigil.remote_instance_state (instance_id int PRIMARY KEY, name text, engine text, site text,
		   collector text, as_of timestamptz, interval_secs int, expected_every_secs int, loaded_at timestamptz)`,
		`CREATE TABLE IF NOT EXISTS pgvigil.remote_collection_interval (instance_id int, collection text, interval_secs int,
		   PRIMARY KEY (instance_id, collection))`,
		`CREATE TABLE IF NOT EXISTS pgvigil.remote_collector_state (site text, collector text, pgvigil_version text, host text,
		   heartbeat_at timestamptz, instances int, fail_streak int, newest_bundle_at timestamptz, gaps int, set_aside int,
		   newest_set_aside_reason text, late int, conflicts int, PRIMARY KEY (site, collector))`,
	} {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	return true
}

// TestRemoteStaleOnAsOf (E3): a remote instance's collections are judged against its as_of (the newest loaded
// bundle's window end) with the intervals its collector reported (remote_collection_interval), never against the
// repository's clock - in the live read (the Summary and the header), Collection dates and the footer's counts; the
// live read carries as_of, site, collector, interval_secs and expected_every_secs for the page; an instance the hub
// reads itself is judged as before.
func TestRemoteStaleOnAsOf(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if !remoteFixture(ctx, t, pool) {
		t.Skip("0329's views are on this store: this row seeds through its ledgers (not written yet)")
	}
	sfx := time.Now().UnixNano() % 1000000000
	ensure := func(name string) int {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, name).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	rem, own := ensure(fmt.Sprintf("site1/rs-%d", sfx)), ensure(fmt.Sprintf("rs-own-%d", sfx))
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.collection_dates WHERE instance_id = ANY ($1)`, `DELETE FROM pgvigil.remote_instance_state WHERE instance_id = ANY ($1)`,
			`DELETE FROM pgvigil.remote_collection_interval WHERE instance_id = ANY ($1)`, `UPDATE pgvigil.instances SET is_active = false WHERE instance_id = ANY ($1)`} {
			if _, err := pool.Exec(context.Background(), q, []int{rem, own}); err != nil {
				t.Log(err)
			}
		}
	}()
	asOf := time.Now().Add(-2 * time.Hour).Truncate(time.Second)
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO pgvigil.remote_instance_state VALUES ($1, $2, 'sqlserver', 'site1', 'c1', $3, 300, 3600, now())`, []any{rem, fmt.Sprintf("site1/rs-%d", sfx), asOf}},
		// the collector's own schedule: storage every 5 minutes, CPU every minute
		{`INSERT INTO pgvigil.remote_collection_interval VALUES ($1, 'mssql_storage', 300), ($1, 'mssql_cpu', 60)`, []any{rem}},
		// storage read a minute before the bundle closed (healthy against as_of); CPU 20 minutes before (stale: past 5 min)
		{`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_storage', $2::timestamptz - interval '1 minute', 'ok'),
		   ($1, 'mssql_cpu', $2::timestamptz - interval '20 minutes', 'ok')`, []any{rem, asOf}},
		{`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_storage', now() - interval '1 minute', 'ok')`, []any{own}},
	} {
		if _, err := pool.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatal(err)
		}
	}
	exp, _ := json.Marshal(map[string]any{"defaults": map[string]int{"mssql_storage": 900, "mssql_cpu": 900}, "instances": map[string]any{}})
	read := func(what, q string, args ...any) []map[string]any {
		rows, err := pool.Query(ctx, q, args...)
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		out, err := pgx.CollectRows(rows, pgx.RowToMap)
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		return out
	}
	num := func(v any) int64 { n, _ := v.(int64); return n }
	for _, c := range []struct {
		id             int
		healthy, stale int64
		remote         bool
	}{{rem, 1, 1, true}, {own, 1, 0, false}} {
		live := read("the live read", sqlAckLive, time.Now(), string(exp), DefaultStaleSecs, noPermission, c.id)
		if len(live) != 1 {
			t.Fatalf("the live read of %d: %d rows", c.id, len(live))
		}
		r := live[0]
		if num(r["coll_healthy"]) != c.healthy || num(r["coll_stale"]) != c.stale {
			t.Errorf("the live read of %v: healthy %v stale %v, want %d / %d", r["instance"], r["coll_healthy"], r["coll_stale"], c.healthy, c.stale)
		}
		if _, has := r["as_of"]; !has {
			t.Errorf("the live read carries no as_of")
			continue
		}
		if c.remote {
			if at, _ := r["as_of"].(time.Time); !at.Equal(asOf) || r["site"] != "site1" || r["collector"] != "c1" || r["interval_secs"] != int32(300) || r["expected_every_secs"] != int32(3600) {
				t.Errorf("the live read's remote fields: as_of %v site %v collector %v interval %v expected %v", r["as_of"], r["site"], r["collector"], r["interval_secs"], r["expected_every_secs"])
			}
		} else if r["as_of"] != nil || r["site"] != nil {
			t.Errorf("an instance the hub reads itself has remote fields: %v %v", r["as_of"], r["site"])
		}
	}
	got := map[string]any{}
	for _, r := range read("collection dates", sqlCollectionDates, string(exp), DefaultStaleSecs, 0, []int{rem, own}) {
		got[fmt.Sprintf("%v/%v", r["instance_id"], r["collection"])] = r["status"]
	}
	for k, want := range map[string]string{fmt.Sprintf("%d/mssql_storage", rem): "ok", fmt.Sprintf("%d/mssql_cpu", rem): "warning", fmt.Sprintf("%d/mssql_storage", own): "ok"} {
		if got[k] != want {
			t.Errorf("collection dates %s: %v, want %s", k, got[k], want)
		}
	}
}

// TestRemoteCollectorPart (E6): the Collector page's remote part names each remote collector with its site's silence -
// sending inside 2 x expected_every, a warning past it, critical past 6 x, 'no bundle yet' before the first - and the
// ledgers' counts as 0329's view gives them. No red of its own: the part is new (its red is its absence).
func TestRemoteCollectorPart(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if !remoteFixture(ctx, t, pool) {
		t.Skip("0329's views are on this store: this row seeds through its ledgers (not written yet)")
	}
	site := fmt.Sprintf("rcp%d", time.Now().UnixNano()%1000000000)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.remote_collector_state WHERE site = $1`, site)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.remote_instance_state WHERE site = $1`, site)
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.remote_collector_state VALUES
	    ($1, 'ok', 'v0.4.0', 'h1', now(), 2, 0, now() - interval '10 minutes', 0, 0, NULL, 0, 0),
	    ($1, 'warn', 'v0.4.0', 'h2', now(), 1, 0, now() - interval '3 hours', 1, 1, 'checksum', 2, 0),
	    ($1, 'crit', 'v0.4.0', 'h3', now(), 1, 4, now() - interval '7 hours', 0, 0, NULL, 0, 1),
	    ($1, 'none', 'v0.4.0', 'h4', now(), 0, 0, NULL, 0, 0, NULL, 0, 0)`, site); err != nil {
		t.Fatal(err)
	}
	// the site's expected_every comes from its instances' rows: an hour for each collector's instance
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.remote_instance_state VALUES (-1001, $1 || '/a', 'postgres', $1, 'ok', now(), 300, 3600, now()),
	    (-1002, $1 || '/b', 'postgres', $1, 'warn', now(), 300, 3600, now()), (-1003, $1 || '/c', 'postgres', $1, 'crit', now(), 300, 3600, now())`, site); err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(ctx, sqlCollectorRemote)
	if err != nil {
		t.Fatal(err)
	}
	all, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]map[string]any{}
	for _, r := range all {
		if r["site"] == site {
			got[fmt.Sprint(r["collector"])] = r
		}
	}
	for c, want := range map[string]string{"ok": "ok", "warn": "warning", "crit": "critical", "none": "no bundle yet"} {
		if got[c] == nil || got[c]["silence"] != want {
			t.Errorf("collector %s: silence %v, want %s", c, got[c]["silence"], want)
		}
	}
	if r := got["warn"]; r == nil || r["newest_set_aside_reason"] != "checksum" || r["late"] != int32(2) || r["expected_every_secs"] != int32(3600) {
		t.Errorf("collector warn's counts: %v", r)
	}
	if r := got["none"]; r == nil || r["expected_every_secs"] != int32(300) {
		t.Errorf("a collector with no instance takes 300 s: %v", r)
	}
}
