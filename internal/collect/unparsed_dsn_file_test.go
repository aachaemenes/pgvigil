package collect

import (
	"bytes"
	"context"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// A dsn that pgx refuses while parsing because a file it names cannot be read (a client key, a certificate, a root
// certificate: pgx reads them as it parses) keeps the fixed words and adds only the file error's own words - the
// operation, the path and the system's reason - so the person sees which file; the dsn's text, its password among it,
// is never in the answer or in a log line. A URL that does not parse at all stays hidden whole.
func TestConnectNamesAFileItCannotRead(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "no-such.key")
	cert := filepath.Join(dir, "no-such.pem")
	var logged bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logged, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(old)
	for _, c := range []struct{ name, dsn, secret string }{
		{"key-value form", "host=127.0.0.1 port=1 user=u password=s3cret-in-dsn sslmode=require sslcert=" + cert + " sslkey=" + key, "s3cret-in-dsn"},
		{"URL form", "postgres://u:s3cret-in-url@127.0.0.1:1/db?sslmode=require&sslcert=" + cert + "&sslkey=" + key, "s3cret-in-url"},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("PGV_FILE_DSN", c.dsn)
			_, err := Connect(context.Background(), config.Instance{Name: "pg1", DSNRaw: "env:PGV_FILE_DSN"})
			if err == nil {
				t.Fatal("connected")
			}
			e := err.Error()
			if !strings.Contains(e, "does not parse") || !strings.Contains(e, "no-such.key") || !strings.Contains(e, "no such file or directory") {
				t.Errorf("the answer does not name the file it could not read: %q", e)
			}
			if strings.Contains(e, c.secret) || strings.Contains(logged.String(), c.secret) {
				t.Errorf("the dsn's password is in the answer or the log: %q", e)
			}
			if strings.Contains(e, "127.0.0.1") || strings.Contains(e, "user=") || strings.Contains(e, "postgres://") {
				t.Errorf("the answer holds the dsn's text: %q", e)
			}
		})
	}
	// a URL that does not parse: the fixed words alone (url.Error would carry the whole URL)
	t.Setenv("PGV_FILE_DSN", "postgres://u:s3cret-bad-url@[::1/db")
	_, err := Connect(context.Background(), config.Instance{Name: "pg1", DSNRaw: "env:PGV_FILE_DSN"})
	if err == nil || !strings.Contains(err.Error(), "does not parse") || strings.Contains(err.Error(), "could not read") ||
		strings.Contains(err.Error(), "s3cret-bad-url") || strings.Contains(err.Error(), "postgres://") {
		t.Errorf("a URL that does not parse: %v, want the fixed words alone", err)
	}
}
