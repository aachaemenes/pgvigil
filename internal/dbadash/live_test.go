package dbadash

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestLive reads every repository of the configuration file PGVIGIL_DBADASH_CONFIG once into its pgvigil repository
// (scripts/proof-dbadash.sh drives it; skipped without the variable). It prints one line per repository:
//
//	dbadash <name> <status> instances=<n> statuses=<n> reason=<reason>
//
// and, with PGVIGIL_DBADASH_DUMP set to a path, writes the payloads there as JSON for the proof's comparison.
func TestLive(t *testing.T) {
	path := os.Getenv("PGVIGIL_DBADASH_CONFIG")
	if path == "" {
		t.Skip("PGVIGIL_DBADASH_CONFIG not set (scripts/proof-dbadash.sh sets it)")
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.DBADash) == 0 {
		t.Fatal("the configuration lists no dbadash: repository")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	got, err := Once(ctx, log, cfg.Repository.DSN(), cfg.DBADash)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range cfg.DBADash {
		p := got[r.Name]
		n := 0
		for _, in := range p.Instances {
			n += len(in.Statuses)
		}
		fmt.Printf("dbadash %s %s instances=%d statuses=%d reason=%s\n", r.Name, p.Status, len(p.Instances), n, p.Reason)
	}
	if dump := os.Getenv("PGVIGIL_DBADASH_DUMP"); dump != "" {
		b, err := json.MarshalIndent(got, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(dump, b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}
