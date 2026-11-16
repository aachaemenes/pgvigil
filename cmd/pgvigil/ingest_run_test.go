package main

// task 15's WIRING rows (OUTBOX H at the merge): `pgvigil ingest` dispatched, 'pgvigil roles' printing ingest's login,
// and run's startIngest - nothing started without ingest_dsn:, a login that is not ingest's own refused in words as a
// configuration error, the loop started on one that is and stopped with run.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestIngestWired(t *testing.T) {
	// dispatched: a missing config is a configuration error (3), never the unknown command's usage (2)
	if code := run([]string{"ingest", "-config", filepath.Join(t.TempDir(), "none.yaml")}); code != 3 {
		t.Errorf("pgvigil ingest with a missing config exited %d, want 3 (runIngest's configuration error)", code)
	}
	out, err := captureStdout(t, func() error { return runRoles(nil) })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_ingest;") {
		t.Errorf("'pgvigil roles' prints no login IN ROLE pgvigil_ingest alone")
	}
}

func TestStartIngestOnAStore(t *testing.T) {
	ctx := context.Background()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	stop, err := startIngest(ctx, log, &config.Config{RemoteSites: []config.RemoteSite{{Name: "s1"}}})
	if err != nil || stop == nil {
		t.Fatalf("remote_sites: without ingest_dsn: %v (want nothing started, no error)", err)
	}
	stop()

	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set: the store half of the row is skipped")
	}
	if os.Getenv("PGVIGIL_REMOTE_DRAFT") != "1" {
		t.Skip("PGVIGIL_REMOTE_DRAFT=1 is not set: the store half runs where the box job applied scripts/remote-join-draft.sql (the ingest door)")
	}
	pc, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	role := fmt.Sprintf("w15ing_%d", time.Now().UnixNano()%1000000000)
	if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN IN ROLE pgvigil_ingest`, role)); err != nil {
		t.Fatalf("an ingest login: %v", err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(context.Background(), fmt.Sprintf(`DROP ROLE IF EXISTS %s`, role)) })
	t.Setenv("W15_REPO_DSN", dsn)
	t.Setenv("W15_INGEST_DSN", fmt.Sprintf("host=%s port=%d user=%s dbname=%s", pc.Host, pc.Port, role, pc.Database))
	dir := t.TempDir()
	drop := filepath.Join(dir, "drop")
	if err := os.MkdirAll(drop, 0o700); err != nil {
		t.Fatal(err)
	}
	load := func(ingestDSN string) *config.Config {
		t.Helper()
		p := filepath.Join(dir, "hub.yaml")
		body := fmt.Sprintf("repository:\n  dsn: env:W15_REPO_DSN\ninstances: []\ningest_dsn: %s\nremote_sites:\n"+
			"  - name: w15site\n    drop: {type: folder, path: '%s'}\n    collectors: [{name: c1}]\n", ingestDSN, drop)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		c, err := config.Load(p)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	// the repository's own login (the owner or a superuser on the box's store): refused in words, a configuration error
	_, err = startIngest(ctx, log, load("env:W15_REPO_DSN"))
	var ce *configError
	if err == nil || !errors.As(err, &ce) || !strings.Contains(err.Error(), "pgvigil_ingest only") {
		t.Errorf("startIngest on the repository's own login: %v, want a configuration error saying ingest runs on a login in pgvigil_ingest only", err)
	}
	// ingest's own login: the loop starts, and stop ends it and returns
	stop, err = startIngest(ctx, log, load("env:W15_INGEST_DSN"))
	if err != nil {
		t.Fatalf("startIngest on a login in pgvigil_ingest: %v", err)
	}
	done := make(chan struct{})
	go func() { stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("stop did not return within 30 s")
	}
}
