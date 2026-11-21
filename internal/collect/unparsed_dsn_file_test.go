package collect

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// A dsn that pgx refuses while parsing because a file it names cannot be read (a client key, a certificate, a root
// certificate: pgx reads them as it parses) keeps the fixed words and adds only the file error's own words - the
// operation, the path and the system's reason - so the person sees which file; the dsn's text, its password among it,
// is never in the answer. What the scheduler, 'pgvigil check' and the Collector page log or store for such a run is
// this answer (wrapped), so the answer's check is the log's. A URL that does not parse at all stays hidden whole.
func TestConnectNamesAFileItCannotRead(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "no-such.key")
	cert := filepath.Join(dir, "no-such.pem")
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
			if strings.Contains(e, c.secret) {
				t.Errorf("the dsn's password is in the answer: %q", e)
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

// pgx's keyword=value parser lets an empty value take the next token, so a 'file name' can be a piece of the dsn
// itself - its password among it: 'sslrootcert= password=x' makes the root certificate's path "password=x", and a
// misplaced quote puts a password inside a path. Such a path (it holds a keyword=value) is never shown: the answer
// names the operation and the system's reason alone.
func TestConnectHidesAPathThatHoldsDSNText(t *testing.T) {
	cert := filepath.Join(t.TempDir(), "c.pem")
	for _, c := range []struct{ name, dsn, secret string }{
		{"an empty sslrootcert takes the password", "host=127.0.0.1 port=1 user=u sslmode=verify-full sslrootcert= password=s3cret-a", "s3cret-a"},
		{"an empty sslkey takes the key's passphrase", "host=127.0.0.1 port=1 user=u sslmode=require sslcert=" + cert + " sslkey= sslpassword=s3cret-b", "s3cret-b"},
		{"a misplaced quote puts the password in a path", "sslrootcert='/etc/pgv/ca.pem password=s3cret-c' host=127.0.0.1 port=1 user=u sslmode=verify-full", "s3cret-c"},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Setenv("PGV_FILE_DSN", c.dsn)
			_, err := Connect(context.Background(), config.Instance{Name: "pg1", DSNRaw: "env:PGV_FILE_DSN"})
			if err == nil {
				t.Fatal("connected")
			}
			e := err.Error()
			if strings.Contains(e, c.secret) || strings.Contains(e, "password=") || strings.Contains(e, "sslpassword") {
				t.Errorf("the answer holds the dsn's text: %q", e)
			}
			if !strings.Contains(e, "does not parse") || !strings.Contains(e, "its path is not shown") {
				t.Errorf("the answer does not say a file could not be read with its path hidden: %q", e)
			}
		})
	}
}
