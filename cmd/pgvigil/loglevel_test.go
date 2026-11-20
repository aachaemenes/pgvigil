package main

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"
)

// TestLogLevelAppliedL172 (RELNOTES L172): the file's log_level sets the level every logger of the process shares;
// PGVIGIL_LOG_LEVEL wins over it (a one-off without editing the file); an unknown word in the variable is ignored.
func TestLogLevelAppliedL172(t *testing.T) {
	defer logLevel.Set(slog.LevelInfo)
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte("repository:\n  dsn: x\ninstances: []\nlog_level: warn\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		env  string
		want slog.Level
	}{{"", slog.LevelWarn}, {"debug", slog.LevelDebug}, {"ERROR", slog.LevelError}, {"loud", slog.LevelWarn}} {
		t.Setenv("PGVIGIL_LOG_LEVEL", c.env)
		logLevel.Set(slog.LevelInfo)
		if _, err := loadConfigAt(p, false); err != nil {
			t.Fatalf("load: %v", err)
		}
		if got := logLevel.Level(); got != c.want {
			t.Errorf("PGVIGIL_LOG_LEVEL %q over log_level warn: %v, want %v", c.env, got, c.want)
		}
	}
}
