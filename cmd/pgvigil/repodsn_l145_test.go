package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRunRepositoryDSNSaysWhyL145: the service's run over a repository dsn that resolves to nothing stays a
// configuration error (exit 3) and says why - here the file it names is missing.
func TestRunRepositoryDSNSaysWhyL145(t *testing.T) {
	dir := t.TempDir()
	p, missing := filepath.Join(dir, "pgvigil.yaml"), filepath.Join(dir, "repo.dsn")
	if err := os.WriteFile(p, []byte(configTemplate("file:"+missing)), 0o600); err != nil {
		t.Fatal(err)
	}
	err := runScheduler(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)), []string{"-config", p})
	var ec interface{ ExitCode() int }
	if !errors.As(err, &ec) || ec.ExitCode() != 3 || !strings.Contains(err.Error(), "resolves to nothing") || !strings.Contains(err.Error(), "no such file") {
		t.Fatalf("run over a missing repository dsn file: %v (want exit 3 naming the missing file)", err)
	}
}
