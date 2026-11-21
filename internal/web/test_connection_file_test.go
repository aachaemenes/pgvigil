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

// The page's connection test and a pgvigil.yaml instance's Test (fileDSNError) answer as the collector's connect does:
// a key file named when its path is a path, and never a path that holds a keyword=value (an empty value in the dsn
// took the next token: 'sslrootcert= password=x').
func TestConnectionTestHidesAPathThatHoldsDSNText(t *testing.T) {
	key := filepath.Join(t.TempDir(), "no-such.key")
	if d := fileDSNError(config.EnginePostgres, "host=127.0.0.1 port=1 user=u password=s3cret-in-dsn sslmode=require sslcert="+key+".pem sslkey="+key); !strings.Contains(d, "no-such.key") || strings.Contains(d, "s3cret-in-dsn") {
		t.Errorf("a file instance's Test: %q; want the key file named and no password", d)
	}
	for _, dsn := range []string{
		"host=127.0.0.1 port=1 user=u sslmode=verify-full sslrootcert= password=s3cret-a",
		"sslrootcert='/etc/pgv/ca.pem password=s3cret-a' host=127.0.0.1 port=1 user=u sslmode=verify-full",
	} {
		_, detail := testConnection(context.Background(), config.EnginePostgres, dsn)
		file := fileDSNError(config.EnginePostgres, dsn)
		for _, d := range []string{detail, file} {
			if strings.Contains(d, "s3cret-a") || strings.Contains(d, "password=") || !strings.Contains(d, "its path is not shown") {
				t.Errorf("the words %q; want the path hidden, no dsn text", d)
			}
		}
	}
}
