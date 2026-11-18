package main

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestInlinePasswordWarnsAtLoadL9 (L9, the lead's 17:32 (1) a): a PostgreSQL instance whose dsn in pgvigil.yaml
// carries an inline password still loads, and the collector's load WARNS once for it, naming the instance and the fix
// forms; a dsn through env: or file:, one without a password, and a sqlserver instance (its inline password is
// refused at load already) raise nothing.
func TestInlinePasswordWarnsAtLoadL9(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))
	cfg := &config.Config{Instances: []config.Instance{
		{Name: "pg-inline", DSNRaw: "host=h user=u password=zz dbname=d"},
		{Name: "pg-url", DSNRaw: "postgres://u:pw@h/d"},
		{Name: "pg-env", DSNRaw: "env:PG_DSN"},
		{Name: "pg-file", DSNRaw: "file:/etc/pgvigil/pg.dsn"},
		{Name: "pg-plain", DSNRaw: "host=h user=u dbname=d"},
		{Name: "ms-one", Engine: config.EngineSQLServer, DSNRaw: "sqlserver://login@h:1433?database=master"},
	}}
	warnInlinePasswords(log, cfg)
	out := buf.String()
	if n := strings.Count(out, "level=WARN"); n != 2 {
		t.Errorf("%d WARN lines, want 2 (pg-inline, pg-url):\n%s", n, out)
	}
	for _, want := range []string{"pg-inline", "pg-url", "env:", "file:", "password_secret"} {
		if !strings.Contains(out, want) {
			t.Errorf("the warnings lack %q:\n%s", want, out)
		}
	}
	for _, never := range []string{"pg-env", "pg-file", "pg-plain", "ms-one", "zz", ":pw@"} {
		if strings.Contains(out, never) {
			t.Errorf("the warnings hold %q (an instance that must not warn, or the password itself):\n%s", never, out)
		}
	}
}
