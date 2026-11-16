package ingest

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/export"
	"github.com/aachaemenes/pgvigil/internal/remote"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// writeAGBundle puts bundle seq of one SQL Server instance (SQL05, collector c1) into a folder drop: one mssql_ag batch
// in the rows import_mssql_ag takes, its window ending at 'to'.
func writeAGBundle(t *testing.T, root, site string, seq uint64, to time.Time) format.Ref {
	t.Helper()
	b, err := remote.OpenBundle(remote.BundleOptions{Outbox: root, Site: site, Collector: "c1", Stream: "cccccccccccccccc", Seq: seq,
		From: to.Add(-5 * time.Minute), To: to, QueryText: "hash", PgvigilVersion: "v0.4.0", SchemaLevel: "0329_remote",
		Instance: format.Instance{Engine: "sqlserver", Name: "SQL05", Platform: "onprem", ServerVersion: "16.0.4295.3", VersionNum: 160000}})
	if err != nil {
		t.Fatal(err)
	}
	if err := b.AddBatch("mssql_ag", to.Add(-4*time.Minute), []map[string]any{{"group_name": "ag1", "role": "PRIMARY", "synchronization_health": "HEALTHY"}}); err != nil {
		t.Fatal(err)
	}
	b.AddRun(format.Run{Collection: "mssql_ag", At: to.Add(-4 * time.Minute), Ms: 40, Status: "ok"})
	ref, err := b.Close(to, []format.Read{{Collection: "mssql_ag", Status: "ran", Runs: 1, IntervalSecs: 300}}, nil,
		format.Heartbeat{Host: "jump05", Started: to.Add(-time.Hour), At: to, Instances: 1})
	if err != nil {
		t.Fatal(err)
	}
	return ref
}

// TestSiteRoundHeldOnAStore (task 5's own row): SiteRound on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it) - while another session holds the site's advisory lock the round reads nothing and says held; once the
// lock is free the round loads the drop's bundle through PoolHub on 0329 (the instance the site owns, the bundle's
// ledger and batch, as_of in remote_instance_state) and gives the lock back; the next round finds the bundle already in.
func TestSiteRoundHeldOnAStore(t *testing.T) {
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
	if !AllowList()["mssql_ag"] {
		t.Fatal("mssql_ag is not on the allow-list: the row's bundle must carry a view a bundle may carry")
	}
	site := fmt.Sprintf("h5s%d", time.Now().UnixNano()%1000000000)
	root := t.TempDir()
	to := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Minute)
	ref := writeAGBundle(t, root, site, 1, to)
	s := Site{Name: site, Drop: export.NewFolder(root), ExpectedEvery: 5 * time.Minute, GapWait: 15 * time.Minute, Collectors: map[string][][]byte{"c1": nil}}
	if err := (PoolHub{Pool: pool}).SyncSites(ctx, []Site{s}); err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	loaded := func() int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.remote_bundles WHERE site = $1 AND state = 'loaded'`, site).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	lock := func(conn *pgxpool.Conn) bool {
		t.Helper()
		var got bool
		if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtext('pgvigil remote ingest'), hashtext($1))`, site).Scan(&got); err != nil {
			t.Fatal(err)
		}
		return got
	}
	// (a) another loop holds the site: held, nothing read
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Release() // before pool.Close (deferred earlier, run later): Close waits for every acquired connection
	if !lock(conn) {
		t.Fatal("the row's own session could not take the site's lock")
	}
	res, held, err := SiteRound(ctx, pool, s, log)
	if err != nil || !held || res != (Result{}) {
		t.Errorf("a round while another session holds the site: held %v, %+v, err %v - want held and nothing read", held, res, err)
	}
	if n := loaded(); n != 0 {
		t.Errorf("bundles loaded while another session held the site: %d, want 0", n)
	}
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_unlock(hashtext('pgvigil remote ingest'), hashtext($1))`, site); err != nil {
		t.Fatal(err)
	}
	// (b) the lock free: the bundle loads through PoolHub
	res, held, err = SiteRound(ctx, pool, s, log)
	if err != nil || held || res.Loaded != 1 {
		t.Fatalf("the round once the site is free: held %v, %+v, err %v - want 1 loaded", held, res, err)
	}
	if n := loaded(); n != 1 {
		t.Errorf("bundles loaded: %d, want 1", n)
	}
	var batches int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.remote_batches x JOIN pgvigil.remote_bundles b USING (bundle_id)
	   WHERE b.site = $1 AND x.view = 'mssql_ag'`, site).Scan(&batches); err != nil || batches != 1 {
		t.Errorf("the bundle's batches in the ledger: %d %v, want 1 mssql_ag", batches, err)
	}
	var name string
	var asOf time.Time
	if err := pool.QueryRow(ctx, `SELECT name, as_of FROM pgvigil.remote_instance_state WHERE site = $1`, site).Scan(&name, &asOf); err != nil ||
		name != site+"/SQL05" || !asOf.Equal(ref.End) {
		t.Errorf("remote_instance_state: %q as of %v (%v), want %q as of %v", name, asOf, err, site+"/SQL05", ref.End)
	}
	// the round gave the lock back: this session takes it at once
	if !lock(conn) {
		t.Errorf("the site's lock is still held after the round")
	} else if _, err := conn.Exec(ctx, `SELECT pg_advisory_unlock(hashtext('pgvigil remote ingest'), hashtext($1))`, site); err != nil {
		t.Fatal(err)
	}
	// (c) the next round: already in, nothing loaded twice
	res, held, err = SiteRound(ctx, pool, s, log)
	if err != nil || held || res.Loaded != 0 || res.Skipped != 1 {
		t.Errorf("the next round: held %v, %+v, err %v - want 0 loaded, 1 already in", held, res, err)
	}
	if n := loaded(); n != 1 {
		t.Errorf("bundles loaded after the next round: %d, want 1", n)
	}
}
