package ingest

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

// H review part 1's rows (OUTBOX H FOLD 1): each on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it);
// the grant and alert rows need scripts/remote-join-draft.sql applied (the join's stand-in), as TestRemoteJoinDraftOnAStore.

type fold1 struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	site string
}

func newFold1(t *testing.T, prefix string) *fold1 {
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
	return &fold1{t: t, ctx: ctx, pool: pool, site: fmt.Sprintf("%s%d", prefix, time.Now().UnixNano()%1000000000)}
}

func (f *fold1) exec(q string, args ...any) error {
	_, err := f.pool.Exec(f.ctx, q, args...)
	return err
}

func (f *fold1) must(q string, args ...any) {
	f.t.Helper()
	if err := f.exec(q, args...); err != nil {
		f.t.Fatalf("%.60s: %v", q, err)
	}
}

func (f *fold1) one(q string, args ...any) (any, error) {
	var v any
	err := f.pool.QueryRow(f.ctx, q, args...).Scan(&v)
	return v, err
}

func (f *fold1) drafted() bool {
	f.t.Helper()
	v, err := f.one(`SELECT pg_get_viewdef('pgvigil.findings'::regclass) LIKE '%remote_silence_findings%'`)
	if err != nil {
		f.t.Fatal(err)
	}
	return v == true
}

// ensure: the site's instance through the remote ensure under the name this tree has (remote_ensure_instance since
// FOLD 1, import_remote_ensure before), so a row is red for its own reason on the tree before the fold
func (f *fold1) ensure(name string) int {
	f.t.Helper()
	fn := "pgvigil.import_remote_ensure"
	if v, _ := f.one(`SELECT to_regproc('pgvigil.remote_ensure_instance') IS NOT NULL`); v == true {
		fn = "pgvigil.remote_ensure_instance"
	}
	var id int
	if err := f.pool.QueryRow(f.ctx, `SELECT `+fn+`($1, 'sqlserver', $2, 'onprem', '16.0', 160000, false, '{}'::text[])`, f.site, name).Scan(&id); err != nil {
		f.t.Fatalf("%s: %v", fn, err)
	}
	return id
}

// bundle: one loaded bundle of key (stream st1) ending at 'to', with these collection intervals
func (f *fold1) bundle(key string, id int, seq int64, to time.Time, intervals string) {
	f.t.Helper()
	var b int64
	if err := f.pool.QueryRow(f.ctx, `SELECT pgvigil.remote_bundle_begin($1, 'c1', $2, 'aaaaaaaaaaaaaaaa', $3, $4, $5, $6, $7)`,
		f.site, key, seq, to.Add(-5*time.Minute), to, fmt.Sprintf("d%d", seq), id).Scan(&b); err != nil {
		f.t.Fatalf("remote_bundle_begin: %v", err)
	}
	f.must(`SELECT pgvigil.remote_bundle_done($1, '{"host":"h","started":"2026-11-16T17:00:00Z","at":"2026-11-16T17:55:00Z","instances":1,"fail_streak":0}'::jsonb, $2::jsonb, 'v0.4.0')`, b, intervals)
}

func (f *fold1) cleanup() {
	c := context.Background()
	for _, q := range []string{`DELETE FROM pgvigil.instances WHERE owner = $1`, `DELETE FROM pgvigil.remote_marks WHERE site = $1`,
		`DELETE FROM pgvigil.remote_bundles WHERE site = $1`, `DELETE FROM pgvigil.remote_streams WHERE site = $1`,
		`DELETE FROM pgvigil.remote_collectors WHERE site = $1`, `DELETE FROM pgvigil.remote_sites WHERE name LIKE $1 || '%'`} {
		_, _ = f.pool.Exec(c, q, f.site)
	}
}

// B3: a mark -retry cleared does not hide the same failure again: the bundle failing the same way is marked anew
func TestRemoteMarkAgainAfterRetryOnAStore(t *testing.T) {
	f := newFold1(t, "f1b3")
	t.Cleanup(f.cleanup)
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f.site)
	mark := func() {
		f.must(`SELECT pgvigil.remote_mark($1, 'c1', 'K1', 'aaaaaaaaaaaaaaaa', 5, now(), 'checksum', 'the sum differs', 'dg5')`, f.site)
	}
	mark()
	f.must(`UPDATE pgvigil.remote_marks SET cleared_at = now(), cleared_by = 'pgvigil ingest -retry' WHERE site = $1`, f.site)
	mark()
	if v, err := f.one(`SELECT count(*) FROM pgvigil.remote_marks WHERE site = $1 AND cleared_at IS NULL`, f.site); err != nil || fmt.Sprint(v) != "1" {
		t.Errorf("the open marks after a -retry and the same failure again: %v %v, want 1", v, err)
	}
}

// S1: a site that never sent goes quiet from its FIRST sync - a later sync (every ingest, every restart) does not move
// it; a site whose bundles the purge removed is still judged by its newest load (remote_streams, which the purge keeps),
// never 'last bundle never'
func TestRemoteSilenceSurvivesSyncAndPurgeOnAStore(t *testing.T) {
	f := newFold1(t, "f1s1")
	t.Cleanup(f.cleanup)
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f.site)
	f.must(`UPDATE pgvigil.remote_sites SET synced_at = now() - interval '1 hour' WHERE name = $1`, f.site)
	if err := f.exec(`UPDATE pgvigil.remote_sites SET first_synced_at = now() - interval '1 hour' WHERE name = $1`, f.site); err != nil {
		t.Errorf("remote_sites.first_synced_at: %v", err)
	}
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f.site) // the next ingest's sync
	if v, err := f.one(`SELECT severity || '|' || detail FROM pgvigil.remote_silence_findings WHERE value = $1 AND instance_id IS NULL`, f.site); err != nil ||
		!strings.HasPrefix(fmt.Sprint(v), "critical|") || !strings.Contains(fmt.Sprint(v), "never") {
		t.Errorf("a never-sent site an hour after its first sync, synced again now: %v %v, want critical ... never", v, err)
	}
	// a sent site whose bundles the purge removed
	f2 := &fold1{t: t, ctx: f.ctx, pool: f.pool, site: f.site + "p"}
	t.Cleanup(f2.cleanup)
	f2.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f2.site)
	id := f2.ensure("SQL01")
	f2.bundle("SQL01", id, 1, time.Now().Add(-2*time.Hour), `[]`)
	if err := f2.exec(`UPDATE pgvigil.remote_streams SET high_loaded_at = now() - interval '2 hours' WHERE site = $1`, f2.site); err != nil {
		t.Errorf("remote_streams.high_loaded_at: %v", err)
	}
	f2.must(`DELETE FROM pgvigil.remote_bundles WHERE site = $1`, f2.site) // remote_purge's part
	if v, err := f2.one(`SELECT detail FROM pgvigil.remote_silence_findings WHERE value = $1 AND instance_id IS NULL`, f2.site); err != nil || strings.Contains(fmt.Sprint(v), "never") {
		t.Errorf("a sent site after the purge: %v %v, want its newest load, never 'last bundle never'", v, err)
	}
}

// S2: a site no longer in remote_sites: is retired - no silence finding, no Collector row - and comes back when listed
func TestRemoteSiteRetiredOnAStore(t *testing.T) {
	f := newFold1(t, "f1s2")
	t.Cleanup(f.cleanup)
	a, b := f.site+"a", f.site+"b"
	for _, s := range []string{a, b} {
		f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, s)
		f.must(`UPDATE pgvigil.remote_sites SET synced_at = now() - interval '1 hour' WHERE name = $1`, s)
		_ = f.exec(`UPDATE pgvigil.remote_sites SET first_synced_at = now() - interval '1 hour' WHERE name = $1`, s)
	}
	if err := f.exec(`SELECT pgvigil.remote_sites_retire($1::text[])`, []string{a}); err != nil {
		t.Errorf("remote_sites_retire: %v", err)
	}
	if v, err := f.one(`SELECT count(*) FROM pgvigil.remote_silence_findings WHERE value = $1`, b); err != nil || fmt.Sprint(v) != "0" {
		t.Errorf("a site no longer listed still raises its silence: %v %v", v, err)
	}
	if v, err := f.one(`SELECT count(*) FROM pgvigil.remote_silence_findings WHERE value = $1`, a); err != nil || fmt.Sprint(v) != "1" {
		t.Errorf("the listed site's silence: %v %v, want 1", v, err)
	}
}

// S3: a bundle once marked missing / short / newer format that loads later has those marks cleared
func TestRemoteLoadClearsRetryMarksOnAStore(t *testing.T) {
	f := newFold1(t, "f1s3")
	t.Cleanup(f.cleanup)
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f.site)
	id := f.ensure("SQL01")
	f.must(`SELECT pgvigil.remote_mark($1, 'c1', 'SQL01', 'aaaaaaaaaaaaaaaa', 1, now(), 'missing', 'manifest.json is not in the drop', '')`, f.site)
	f.bundle("SQL01", id, 1, time.Now().Add(-10*time.Minute), `[]`)
	if v, err := f.one(`SELECT count(*) FROM pgvigil.remote_marks WHERE site = $1 AND seq = 1 AND cleared_at IS NULL`, f.site); err != nil || fmt.Sprint(v) != "0" {
		t.Errorf("a loaded bundle's open 'missing' mark: %v %v, want 0", v, err)
	}
	if v, err := f.one(`SELECT set_aside FROM pgvigil.remote_collector_state WHERE site = $1`, f.site); err != nil || fmt.Sprint(v) != "0" {
		t.Errorf("the Collector page's set-aside count: %v %v, want 0", v, err)
	}
}

// S6: an older bundle loaded late never overwrites the newer intervals; a collection the newest bundle no longer
// reports loses its interval
func TestRemoteIntervalsFromTheNewestOnAStore(t *testing.T) {
	f := newFold1(t, "f1s6")
	t.Cleanup(f.cleanup)
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f.site)
	id := f.ensure("SQL01")
	now := time.Now().UTC().Truncate(time.Second)
	f.bundle("SQL01", id, 2, now.Add(-10*time.Minute), `[{"collection":"x","interval_secs":60},{"collection":"y","interval_secs":120}]`)
	f.bundle("SQL01", id, 1, now.Add(-20*time.Minute), `[{"collection":"x","interval_secs":999}]`) // older, loaded late
	if v, _ := f.one(`SELECT interval_secs FROM pgvigil.remote_collection_interval WHERE instance_id = $1 AND collection = 'x'`, id); fmt.Sprint(v) != "60" {
		t.Errorf("x after an older bundle loaded late: %v, want 60 (the newest's)", v)
	}
	f.bundle("SQL01", id, 3, now.Add(-5*time.Minute), `[{"collection":"x","interval_secs":30}]`)
	if v, _ := f.one(`SELECT count(*) FROM pgvigil.remote_collection_interval WHERE instance_id = $1 AND collection = 'y'`, id); fmt.Sprint(v) != "0" {
		t.Errorf("y, which the newest bundle no longer reports: %v rows, want 0", v)
	}
}

// remoteWriters: every function the ingest door holds (FOLD 1, B5 as answered: an ingest login's alone)
var remoteWriters = []string{"remote_site_sync", "remote_sites_retire", "remote_ensure_instance", "remote_bundle_begin", "remote_batch",
	"remote_bundle_done", "remote_mark", "remote_retry", "remote_purge"}

// B5: after migrate (the join draft applied, as the join will be) every remote writer is the ingest door's -
// SECURITY DEFINER, EXECUTE for pgvigil_ingest, none for pgvigil_collector or pgvigil_reader; a collector login calling
// remote_batch is refused
func TestRemoteIngestDoorOnAStore(t *testing.T) {
	f := newFold1(t, "f1b5")
	if !f.drafted() {
		t.Skip("scripts/remote-join-draft.sql is not applied on this store")
	}
	for _, n := range remoteWriters {
		rows, err := f.pool.Query(f.ctx, `SELECT p.prosecdef, has_function_privilege('pgvigil_collector', p.oid, 'EXECUTE'),
		       has_function_privilege('pgvigil_reader', p.oid, 'EXECUTE'), has_function_privilege('pgvigil_ingest', p.oid, 'EXECUTE')
		  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'pgvigil' AND p.proname = $1`, n)
		if err != nil {
			t.Errorf("%s: %v", n, err)
			continue
		}
		got, err := pgx.CollectRows(rows, pgx.RowTo[[]any])
		if err != nil || len(got) != 1 {
			t.Errorf("%s: %d functions (%v), want 1", n, len(got), err)
			continue
		}
		if r := fmt.Sprint(got[0]); r != "[true false false true]" {
			t.Errorf("%s: security definer, collector, reader, ingest = %s, want [true false false true]", n, r)
		}
	}
	for _, n := range []string{"import_remote_ensure", "import_remote_batch"} {
		if v, _ := f.one(`SELECT count(*) FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'pgvigil' AND p.proname = $1`, n); fmt.Sprint(v) != "0" {
			t.Errorf("%s still exists (the collector's import_ door would take it)", n)
		}
	}
	// a collector login calling remote_batch
	pc, err := pgx.ParseConfig(os.Getenv("PGVIGIL_REPO_TEST_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	role := fmt.Sprintf("f1col_%d", time.Now().UnixNano()%1000000000)
	if err := f.exec(fmt.Sprintf(`CREATE ROLE %s LOGIN IN ROLE pgvigil_collector`, role)); err != nil {
		t.Skipf("this store's login may not make a login role: %v", err)
	}
	t.Cleanup(func() { _ = f.exec(fmt.Sprintf(`DROP ROLE IF EXISTS %s`, role)) })
	c, err := pgx.Connect(f.ctx, fmt.Sprintf("host=%s port=%d user=%s dbname=%s", pc.Host, pc.Port, role, pc.Database))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(context.Background())
	_, err = c.Exec(f.ctx, `SELECT pgvigil.remote_batch(1, 'mssql_ag', 1, 1, now(), '[]'::jsonb, false)`)
	if err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Errorf("a collector login calling remote_batch: %v, want permission denied", err)
	}
}

// B2: a quiet site's finding reaches alert_due: an alert says the site has gone quiet (the join draft applied)
func TestRemoteQuietSiteAlertsOnAStore(t *testing.T) {
	f := newFold1(t, "f1b2")
	if !f.drafted() {
		t.Skip("scripts/remote-join-draft.sql is not applied on this store")
	}
	t.Cleanup(f.cleanup)
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 60, 180)`, f.site)
	f.must(`UPDATE pgvigil.remote_sites SET synced_at = now() - interval '1 hour' WHERE name = $1`, f.site)
	_ = f.exec(`UPDATE pgvigil.remote_sites SET first_synced_at = now() - interval '1 hour' WHERE name = $1`, f.site)
	if v, err := f.one(`SELECT string_agg(event, ',') FROM pgvigil.alert_due(now(), '[{"name":"c"}]') WHERE setting = 'remote site quiet' AND value = $1`, f.site); err != nil || v != "firing" {
		t.Errorf("alert_due for a site quiet an hour: %v %v, want firing", v, err)
	}
}

// S7: an open alert on an instance a site owns is not resolved before its bundle interval + its site's expected_every
// (300 + 3600 s here), whatever the channel's clear_after (600 s by default), and is closed after - 'resolved' or
// 'cleared' by the channel's recovery setting (the join draft applied; its line 2)
func TestRemoteClearFloorOnAStore(t *testing.T) {
	f := newFold1(t, "f1s7")
	if !f.drafted() {
		t.Skip("scripts/remote-join-draft.sql is not applied on this store")
	}
	t.Cleanup(f.cleanup)
	f.must(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], 3600, 10800)`, f.site)
	id := f.ensure("SQL01")
	f.bundle("SQL01", id, 1, time.Now().Add(-time.Minute), `[]`)
	t.Cleanup(func() { _ = f.exec(`DELETE FROM pgvigil.alert_state WHERE instance_id = $1`, id) })
	resolved := func(missing time.Duration) bool {
		t.Helper()
		f.must(`DELETE FROM pgvigil.alert_state WHERE instance_id = $1`, id)
		f.must(`DELETE FROM pgvigil.collection_dates WHERE instance_id = $1`, id)
		f.must(`INSERT INTO pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity, first_sent_at, last_sent_at, send_count, missing_since)
		    VALUES ('c', pgvigil.alert_key($1, 'mssql config', 'f1s7 check', 'x'), $1, $2, 'mssql config', 'f1s7 check', 'x', 'warning', now() - interval '3 hours', now() - interval '2 hours', 1, now() - $3::interval)`,
			id, f.site+"/SQL01", fmt.Sprintf("%d seconds", int(missing.Seconds())))
		f.must(`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_config', now() - interval '30 seconds', 'ok')`, id)
		v, err := f.one(`SELECT count(*) FROM pgvigil.alert_due(now(), '[{"name":"c"}]') WHERE instance_id = $1 AND event IN ('resolved', 'cleared')`, id)
		if err != nil {
			t.Fatalf("alert_due: %v", err)
		}
		return fmt.Sprint(v) == "1"
	}
	if resolved(11 * time.Minute) {
		t.Errorf("an owned instance's alert missing 11 minutes was resolved (the floor is 300 + 3600 s)")
	}
	if !resolved(70 * time.Minute) {
		t.Errorf("an owned instance's alert missing 70 minutes was not resolved (past the floor of 300 + 3600 s)")
	}
}
