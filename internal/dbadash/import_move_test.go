package dbadash

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestImportBound: a moved server's history goes up to pgvigil's first read of it when that is before the caller's To;
// a From at or after that read takes nothing, and says so; an unmoved one keeps the caller's To.
func TestImportBound(t *testing.T) {
	from := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	to := time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC)
	at := func(s string) *time.Time { v, _ := time.Parse(time.RFC3339, s); return &v }
	for _, c := range []struct {
		name    string
		tgt     importTargetRow
		from    time.Time
		want    time.Time
		nothing bool
	}{
		{"not moved", importTargetRow{CollectFrom: at("2026-06-01T00:00:00Z")}, from, to, false},
		{"moved, no first read", importTargetRow{Moved: true}, from, to, false},
		{"moved, read before To", importTargetRow{Moved: true, CollectFrom: at("2026-06-01T00:00:00Z")}, from, *at("2026-06-01T00:00:00Z"), false},
		{"moved, read after To", importTargetRow{Moved: true, CollectFrom: at("2026-12-01T00:00:00Z")}, from, to, false},
		{"moved, From after the read", importTargetRow{Moved: true, CollectFrom: at("2026-06-01T00:00:00Z")}, *at("2026-07-01T00:00:00Z"), *at("2026-06-01T00:00:00Z"), true},
		{"moved, From at the read", importTargetRow{Moved: true, CollectFrom: at("2026-06-01T00:00:00Z")}, *at("2026-06-01T00:00:00Z"), *at("2026-06-01T00:00:00Z"), true},
	} {
		got, none := importBound(c.from, to, c.tgt)
		if !got.Equal(c.want) || (none != "") != c.nothing {
			t.Errorf("%s: to %v nothing %q; want %v nothing %v", c.name, got, none, c.want, c.nothing)
		}
		if c.nothing && !strings.Contains(none, "-from is at or after pgvigil's first read") {
			t.Errorf("%s: the reason %q does not say why", c.name, none)
		}
	}
}

// TestImportTargetMoved runs the import's target and run marks against a migrated pgvigil repository (skipped without
// PGVIGIL_IMPORT_TEST_REPO): a moved server's InstanceID goes to its move under any other name, dry run or not, with all
// four mappings held before pgvigil's first read of it, cpu and jobruns after it until the collector's own first CPU and
// job reads, none after those; the CLI's run marks are the move's (a second run refused while one is marked).
func TestImportTargetMoved(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_IMPORT_TEST_REPO")
	if dsn == "" {
		t.Skip("PGVIGIL_IMPORT_TEST_REPO not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	repo, srv, name := fmt.Sprintf("r206t-%d", sfx), fmt.Sprintf("SRVQ%d", sfx), fmt.Sprintf("mvq-%d", sfx)
	defer func() {
		bg := context.Background()
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.dbadash_repositories WHERE repository = $1`, repo)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.instances WHERE name = $1`, name)
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_repositories (repository, status, read_at) VALUES ($1, 'ok', now())`, repo); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_instances (repository, instance_id, instance, connection_id, display_name, first_seen, snapshot_at)
	    VALUES ($1, 61, $2, 'srvq,1433', $2, now(), now())`, repo, srv); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{"op": "add", "ui_user": "t206", "repository": repo, "server": srv, "dbadash_ids": []int{61},
		"name": name, "dsn_ref": "file:/nonexistent/t206t", "auth": "sql", "host": "srvq", "port": "1433"})
	var outcome string
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_move(now() - interval '1 day', $1::jsonb)->>'outcome'`, string(b)).Scan(&outcome); err != nil || outcome != "done" {
		t.Fatalf("the move: %s (%v)", outcome, err)
	}
	var id int
	if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	src := srcInstance{ID: 61, Instance: srv, Display: srv, Version: "16.0.4295.3"}
	target := func(dry bool, waits ...string) importTargetRow {
		t.Helper()
		tgt, err := importTarget(ctx, log, pool, repo, "another-name", src, dry)
		if err != nil {
			t.Fatal(err)
		}
		if !tgt.Moved || tgt.ID != id || tgt.Name != name || tgt.Skipped != "" {
			t.Fatalf("dry %v: %+v, want the move %d (%s)", dry, tgt, id, name)
		}
		for _, k := range []string{"cpu", "volumes", "dbsize", "jobruns"} {
			if (tgt.Wait[k] != "") != strings.Contains(" "+strings.Join(waits, " ")+" ", " "+k+" ") {
				t.Errorf("dry %v: %s waits %q; want held: %v", dry, k, tgt.Wait[k], waits)
			}
		}
		return tgt
	}
	for _, dry := range []bool{true, false} {
		target(dry, "cpu", "volumes", "dbsize", "jobruns")
	}
	if _, why, err := moveMark(ctx, pool, "run", name, "cli:t206", 0, nil, ""); err != nil || !strings.Contains(why, "collect it first") {
		t.Fatalf("a run mark before pgvigil's first read: %q (%v), want refused 'collect it first'", why, err)
	}
	read := time.Now().UTC().Truncate(time.Millisecond)
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, server_name) VALUES ($1, $2, $3)`, id, read, srv); err != nil {
		t.Fatal(err)
	}
	if tgt := target(false, "cpu", "jobruns"); tgt.CollectFrom == nil || !tgt.CollectFrom.Equal(read) {
		t.Fatalf("collect_from %v, want %v", tgt.CollectFrom, read)
	}
	for _, c := range []string{"mssql_cpu", "mssql_jobs"} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, $2, $3, 'ok')`, id, c, read.Add(time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	target(false)
	runID, why, err := moveMark(ctx, pool, "run", name, "cli:t206", 0, nil, "")
	if err != nil || why != "" || runID != 1 {
		t.Fatalf("the CLI's run mark: run %d %q (%v), want run 1", runID, why, err)
	}
	if _, why, err := moveMark(ctx, pool, "run", name, "cli:t206", 0, nil, ""); err != nil || !strings.Contains(why, "runs already: started by cli:t206") {
		t.Fatalf("a second run while one is marked: %q (%v), want refused", why, err)
	}
	if _, why, err := moveMark(ctx, pool, "ended", name, "cli:t206", runID, map[string]any{"cpu": map[string]any{"inserted": 1}}, "ok"); err != nil || why != "" {
		t.Fatalf("the CLI's ended mark: %q (%v)", why, err)
	}
	var outcomeAt *time.Time
	if err := pool.QueryRow(ctx, `SELECT imported_at FROM pgvigil.dbadash_moves WHERE instance_id = $1 AND run_outcome = 'ok'`, id).Scan(&outcomeAt); err != nil || outcomeAt == nil {
		t.Fatalf("the move after the CLI's run: imported_at %v (%v)", outcomeAt, err)
	}
}
