package ingest

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestRemoteObjectsOnAStore (H1): migration 0329's objects on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it) - the instance a site owns, each batch loaded once, the never-reachable imports refused, a bundle's
// end (as_of, the stream's high-water, the heartbeat, the collector's intervals), the marks, the audit re-anchor,
// the three views of contract 2 and the silence findings.
func TestRemoteObjectsOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	site := fmt.Sprintf("h1s%d", time.Now().UnixNano()%1000000000)
	one := func(what, q string, args ...any) any {
		t.Helper()
		var v any
		if err := pool.QueryRow(ctx, q, args...).Scan(&v); err != nil {
			t.Errorf("%s: %v", what, err)
			return nil
		}
		return v
	}
	// the site, as ingest syncs remote_sites: (expected every minute)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.remote_site_sync($1, '{site:h1}'::text[], 60, 180)`, site); err != nil {
		t.Fatalf("remote_site_sync: %v", err)
	}
	ensure := func(name string) (int, error) {
		var id int
		err := pool.QueryRow(ctx, `SELECT pgvigil.import_remote_ensure($1, 'sqlserver', $2, 'onprem', '16.0.4295.3', 160000, false, '{env:prod}'::text[])`, site, name).Scan(&id)
		return id, err
	}
	// (a) the instance: '<site>/<name>', owned by the site, the manifest's and the site's tags; once
	id, err := ensure("SQL01")
	if err != nil {
		t.Fatalf("import_remote_ensure: %v", err)
	}
	if again, err := ensure("SQL01"); err != nil || again != id {
		t.Errorf("a second ensure: %d %v, want %d", again, err, id)
	}
	if v := one("the instance's row", `SELECT name || '|' || coalesce(owner, '') || '|' || array_to_string(tags, ',') FROM pgvigil.instances WHERE instance_id = $1`, id); v != nil {
		if s := fmt.Sprint(v); !strings.HasPrefix(s, site+"/SQL01|"+site+"|") || !strings.Contains(s, "env:prod") || !strings.Contains(s, "site:h1") {
			t.Errorf("the instance: %s", s)
		}
	}
	// a name the hub's own file holds is not the site's
	if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, site+"/YAML1"); err != nil {
		t.Fatal(err)
	}
	if _, err := ensure("YAML1"); err == nil || !strings.Contains(err.Error(), "owned elsewhere") {
		t.Errorf("a name the yaml owns: %v, want 'owned elsewhere'", err)
	}
	// an instance an admin disabled stays disabled
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := ensure("SQL01"); err != nil {
		t.Errorf("ensure of a disabled instance: %v", err)
	}
	if v := one("is_active", `SELECT is_active FROM pgvigil.instances WHERE instance_id = $1`, id); v != false {
		t.Errorf("a disabled instance re-activated: %v", v)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET is_active = true WHERE instance_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	// (b) a bundle: begun once per digest, each batch loaded once, the never-reachable imports refused
	end := time.Now().Add(-3 * time.Minute).UTC().Truncate(time.Second)
	begin := func(seq int, digest string) (int64, error) {
		var b int64
		err := pool.QueryRow(ctx, `SELECT pgvigil.remote_bundle_begin($1, 'c1', 'SQL01', 'st1', $2, $3, $4, $5, $6)`,
			site, seq, end.Add(-5*time.Minute), end, digest, id).Scan(&b)
		return b, err
	}
	b1, err := begin(1, "d1")
	if err != nil {
		t.Fatalf("remote_bundle_begin: %v", err)
	}
	if again, err := begin(1, "d1"); err != nil || again != b1 {
		t.Errorf("the same bundle begun again: %d %v, want %d (a stopped bundle resumes)", again, err, b1)
	}
	batch := func(b int64, view string, n int, gap bool, rows string) (bool, error) {
		var loaded bool
		err := pool.QueryRow(ctx, `SELECT pgvigil.import_remote_batch($1, $2, $3, $4, $5, $6::jsonb, $7)`, b, view, n, id, end.Add(-time.Minute), rows, gap).Scan(&loaded)
		return loaded, err
	}
	agRows := `[{"group_name":"ag1","role":"PRIMARY","synchronization_health":"HEALTHY"}]`
	if l, err := batch(b1, "mssql_ag", 1, false, agRows); err != nil || !l {
		t.Errorf("the first load of a batch: %v %v, want true", l, err)
	}
	if l, err := batch(b1, "mssql_ag", 1, false, agRows); err != nil || l {
		t.Errorf("the same batch again: %v %v, want false (loaded once)", l, err)
	}
	for _, v := range []string{"mssql_cursor", "collector_beat", "alert_mark", "actions_log", "dbadash_instances", "remote_ensure", "no_such_view"} {
		if _, err := batch(b1, v, 9, false, `[]`); err == nil || !strings.Contains(err.Error(), "not a view a bundle may carry") {
			t.Errorf("view %s: %v, want 'not a view a bundle may carry'", v, err)
		}
	}
	// (c) the audit re-anchor: after a gap, the cursor moves to the batch's start and the move is recorded
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_cursor (instance_id, source, file_name, file_offset) VALUES ($1, 'audit:spec1', 'old.sqlaudit', 100)`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := batch(b1, "mssql_audit", 2, true, `[{"kind":"cursor","source":"audit:spec1","from_file":"new.sqlaudit","from_offset":5000,"file_name":"new.sqlaudit","file_offset":6000}]`); err != nil {
		t.Errorf("an audit batch after a gap: %v (the re-anchor lets the import's own check pass)", err)
	}
	if v := one("the audit gap's mark", `SELECT reason FROM pgvigil.remote_marks WHERE site = $1 AND kind = 'audit gap'`, site); v == nil || !strings.Contains(fmt.Sprint(v), "old.sqlaudit") || !strings.Contains(fmt.Sprint(v), "new.sqlaudit") {
		t.Errorf("the audit gap's mark names both ends: %v", v)
	}
	// (d) the bundle's end: the stream's high-water, as_of, the heartbeat, the collector's intervals
	if _, err := pool.Exec(ctx, `SELECT pgvigil.remote_bundle_done($1, '{"host":"jump01","started":"2026-11-16T17:00:00Z","at":"2026-11-16T17:55:00Z","instances":1,"fail_streak":2}'::jsonb,
	    '[{"collection":"mssql_ag","interval_secs":120},{"collection":"mssql_jobs","interval_secs":0}]'::jsonb, 'v0.4.0')`, b1); err != nil {
		t.Fatalf("remote_bundle_done: %v", err)
	}
	if v := one("remote_instance_state", `SELECT site || '|' || collector || '|' || (as_of = $2)::text || '|' || interval_secs || '|' || expected_every_secs FROM pgvigil.remote_instance_state WHERE instance_id = $1`, id, end); fmt.Sprint(v) != site+"|c1|true|300|60" {
		t.Errorf("remote_instance_state: %v, want %s|c1|true|300|60", v, site)
	}
	if v := one("remote_collection_interval", `SELECT interval_secs FROM pgvigil.remote_collection_interval WHERE instance_id = $1 AND collection = 'mssql_ag'`, id); fmt.Sprint(v) != "120" {
		t.Errorf("remote_collection_interval: %v, want 120", v)
	}
	if v := one("remote_collector_state", `SELECT host || '|' || fail_streak || '|' || pgvigil_version FROM pgvigil.remote_collector_state WHERE site = $1 AND collector = 'c1'`, site); fmt.Sprint(v) != "jump01|2|v0.4.0" {
		t.Errorf("remote_collector_state: %v", v)
	}
	if v := one("the stream's high-water", `SELECT high_seq FROM pgvigil.remote_streams WHERE site = $1 AND collector = 'c1' AND instance_key = 'SQL01' AND stream = 'st1'`, site); fmt.Sprint(v) != "1" {
		t.Errorf("remote_streams: %v, want 1", v)
	}
	if v := one("collector_hosts", `SELECT count(*) FROM pgvigil.collector_hosts WHERE host = 'jump01'`); fmt.Sprint(v) != "0" {
		t.Errorf("a remote collector's heartbeat reached collector_hosts: %v", v)
	}
	// (e) the marks: late and set aside counted with the newest reason
	for _, m := range [][2]string{{"late", "seq 1 after seq 2"}, {"checksum", "mssql_ag.ndjson.gz: sha256 differs"}} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.remote_mark($1, 'c1', 'SQL01', 'st1', 7, $2, $3, $4, 'dx')`, site, end, m[0], m[1]); err != nil {
			t.Errorf("remote_mark %s: %v", m[0], err)
		}
	}
	if v := one("the marks' counts", `SELECT late || '|' || set_aside || '|' || newest_set_aside_reason FROM pgvigil.remote_collector_state WHERE site = $1 AND collector = 'c1'`, site); !strings.HasPrefix(fmt.Sprint(v), "1|1|checksum") {
		t.Errorf("remote_collector_state's marks: %v, want 1|1|checksum...", v)
	}
	// (f) the silence: the site's newest bundle ended 3 minutes ago, expected every minute: past 2 x, a warning
	if v := one("the site's silence", `SELECT severity || '|' || setting FROM pgvigil.remote_silence_findings WHERE value = $1 AND instance_id IS NULL`, site); fmt.Sprint(v) != "warning|remote site quiet" {
		t.Errorf("the site's silence finding: %v, want warning|remote site quiet", v)
	}
	if v := one("the instance's silence", `SELECT severity FROM pgvigil.remote_silence_findings WHERE instance_id = $1`, id); fmt.Sprint(v) != "warning" {
		t.Errorf("the instance's silence finding: %v, want warning", v)
	}
	if v := one("the reader's grant", `SELECT has_table_privilege('pgvigil_reader', 'pgvigil.remote_instance_state', 'SELECT')
	    AND has_table_privilege('pgvigil_reader', 'pgvigil.remote_collector_state', 'SELECT') AND has_table_privilege('pgvigil_reader', 'pgvigil.remote_collection_interval', 'SELECT')`); v != true {
		t.Errorf("SELECT on the three views for pgvigil_reader: %v", v)
	}
}
