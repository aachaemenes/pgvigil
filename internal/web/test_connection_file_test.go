package web

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The page's connection test, like the collector's connect: a dsn pgx refuses while parsing because a file it names
// cannot be read keeps the fixed words and adds the file error's own words; its password never shows.
func TestConnectionTestNamesAFileItCannotRead(t *testing.T) {
	key := filepath.Join(t.TempDir(), "no-such.key")
	ok, detail := testConnection(context.Background(), config.EnginePostgres,
		"host=127.0.0.1 port=1 user=u password=s3cret-in-dsn sslmode=require sslcert="+key+".pem sslkey="+key)
	if ok {
		t.Fatal("the test connected")
	}
	if !strings.Contains(detail, "does not parse") || !strings.Contains(detail, "no-such.key") || strings.Contains(detail, "s3cret-in-dsn") || strings.Contains(detail, "user=") {
		t.Fatalf("the test's words: %q; want the fixed words, the key file named, no dsn text", detail)
	}
}
