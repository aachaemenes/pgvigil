package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// TestIngestCommand (task 5's own row): `pgvigil ingest` refuses in words a configuration with no remote_sites:, a
// -retry that names no bundle and a stray argument; on a migrated repository (PGVIGIL_REPO_TEST_DSN; that half is
// skipped without it) -once loads a folder drop's bundle and finds it already in on the next run, a bundle set aside
// for a bad checksum stays set aside (and is said so, not 'already in') after its file is put right, and
// -retry <its folder> clears its mark and loads it.
func TestIngestCommand(t *testing.T) {
	ctx := context.Background()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	dir := t.TempDir()
	drop := filepath.Join(dir, "drop")
	if err := os.MkdirAll(drop, 0o700); err != nil {
		t.Fatal(err)
	}
	file := func(name, body string) string {
		t.Helper()
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	t.Setenv("PGVIGIL_INGEST_ROW_DSN", "host=127.0.0.1 dbname=pgvigil_no_store")
	none := file("none.yaml", "repository:\n  dsn: env:PGVIGIL_INGEST_ROW_DSN\ninstances: []\n")
	if err := runIngest(ctx, log, []string{"-config", none}); err == nil || !strings.Contains(err.Error(), "has no remote_sites") {
		t.Errorf("no remote_sites: %v, want 'the configuration has no remote_sites:'", err)
	}
	site := fmt.Sprintf("h5c%d", time.Now().UnixNano()%1000000000)
	sites := file("sites.yaml", fmt.Sprintf("repository:\n  dsn: env:PGVIGIL_INGEST_ROW_DSN\ninstances: []\nremote_sites:\n"+
		"  - name: %s\n    drop: {type: folder, path: '%s'}\n    collectors: [{name: c1}]\n", site, drop))
	if err := runIngest(ctx, log, []string{"-config", sites, "-retry", "not/a/bundle"}); err == nil || !strings.Contains(err.Error(), "ingest -retry") {
		t.Errorf("-retry naming no bundle: %v, want 'ingest -retry: ...'", err)
	}
	if err := runIngest(ctx, log, []string{"-config", sites, "now"}); err == nil || !strings.Contains(err.Error(), `unexpected argument "now"`) {
		t.Errorf("a stray argument: %v, want 'unexpected argument'", err)
	}
	// FOLD 2 N4: -retry of a site the configuration does not list is refused before anything is cleared; -once=false is
	// refused (there is no other mode)
	if err := runIngest(ctx, log, []string{"-config", sites, "-retry", "nosite/c1/SQL06/2026-11-16/0000000002-20261116T174800Z"}); err == nil || !strings.Contains(err.Error(), "nosite") || !strings.Contains(err.Error(), "remote_sites") {
		t.Errorf("-retry of a site not in remote_sites: %v, want it named as not in remote_sites:", err)
	}
	if err := runIngest(ctx, log, []string{"-config", sites, "-once=false"}); err == nil || !strings.Contains(err.Error(), "-once") {
		t.Errorf("-once=false: %v, want a refusal naming -once", err)
	}

	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set: the store half of the row is skipped")
	}
	t.Setenv("PGVIGIL_INGEST_ROW_DSN", dsn)
	to := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Minute)
	write := func(seq uint64) format.Ref {
		t.Helper()
		end := to.Add(time.Duration(seq) * 5 * time.Minute)
		b, err := remote.OpenBundle(remote.BundleOptions{Outbox: drop, Site: site, Collector: "c1", Stream: "dddddddddddddddd", Seq: seq,
			From: end.Add(-5 * time.Minute), To: end, QueryText: "hash", PgvigilVersion: "v0.4.0", SchemaLevel: "0329_remote",
			Instance: format.Instance{Engine: "sqlserver", Name: "SQL06", Platform: "onprem", ServerVersion: "16.0.4295.3", VersionNum: 160000}})
		if err != nil {
			t.Fatal(err)
		}
		if err := b.AddBatch("mssql_ag", end.Add(-4*time.Minute), []map[string]any{{"group_name": "ag1", "role": "PRIMARY", "synchronization_health": "HEALTHY"}}); err != nil {
			t.Fatal(err)
		}
		ref, err := b.Close(end, []format.Read{{Collection: "mssql_ag", Status: "ran", Runs: 1, IntervalSecs: 300}}, nil,
			format.Heartbeat{Host: "jump06", Started: to, At: end, Instances: 1})
		if err != nil {
			t.Fatal(err)
		}
		return ref
	}
	run := func(what string, args ...string) string {
		t.Helper()
		out, err := captureStdout(t, func() error { return runIngest(ctx, log, append([]string{"-config", sites}, args...)) })
		if err != nil {
			t.Errorf("%s: %v (printed %q)", what, err, out)
		}
		return out
	}
	want := func(what, out, line string) {
		t.Helper()
		if !strings.Contains(out, line) {
			t.Errorf("%s printed %q, want the line %q", what, out, line)
		}
	}
	tail := ", 0 late, 0 in conflict, 0 gaps gone past, 0 waiting"
	write(1)
	want("-once", run("-once", "-once"), "site "+site+": 1 loaded, 0 already in, 0 set aside, 0 still set aside"+tail)
	want("-once again", run("-once again"), "site "+site+": 0 loaded, 1 already in, 0 set aside, 0 still set aside"+tail)
	// bundle 2 with a byte changed in its view file: set aside for its checksum
	r2 := write(2)
	view := filepath.Join(drop, filepath.FromSlash(r2.Dir()), "mssql_ag"+format.ViewExt)
	good, err := os.ReadFile(view)
	if err != nil {
		t.Fatal(err)
	}
	bad := append([]byte(nil), good...)
	bad[len(bad)-9] ^= 0xff
	if err := os.WriteFile(view, bad, 0o600); err != nil {
		t.Fatal(err)
	}
	want("a bad checksum", run("a bad checksum"), "site "+site+": 0 loaded, 1 already in, 1 set aside, 0 still set aside"+tail)
	// the file put right: the mark holds until -retry, and the line says the bundle is still set aside
	if err := os.WriteFile(view, good, 0o600); err != nil {
		t.Fatal(err)
	}
	want("the file put right", run("the file put right"), "site "+site+": 0 loaded, 1 already in, 0 set aside, 1 still set aside"+tail)
	out := run("-retry", "-retry", r2.Dir())
	want("-retry", out, "ingest -retry "+r2.Dir()+": 1 mark(s) cleared; reading the site again")
	want("-retry", out, "site "+site+": 1 loaded, 1 already in, 0 set aside, 0 still set aside"+tail)
}
