package dbadash

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

func loadYAML(t *testing.T, body string) (*config.Config, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	if err := os.WriteFile(p, []byte("repository:\n  dsn: postgres://x@localhost/pgvigil\n"+body), 0o600); err != nil {
		t.Fatal(err)
	}
	return config.Load(p)
}

func TestConfigDBADash(t *testing.T) {
	c, err := loadYAML(t, `dbadash:
  - name: corp
    dsn: env:DBADASH_DSN
  - name: lab
    dsn: "sqlserver://reader@sql1:1433?database=DBADashDB&fedauth=ActiveDirectoryDefault"
    interval: 2m
`)
	if err != nil {
		t.Fatalf("valid config refused: %v", err)
	}
	if len(c.DBADash) != 2 || c.DBADash[0].Every() != 5*time.Minute || c.DBADash[1].Every() != 2*time.Minute {
		t.Fatalf("got %+v", c.DBADash)
	}
	t.Setenv("DBADASH_DSN", "server=sql1;user id=r;password=p")
	if c.DBADash[0].DSN() != "server=sql1;user id=r;password=p" {
		t.Fatalf("env: not resolved: %q", c.DBADash[0].DSN())
	}

	none, err := loadYAML(t, "")
	if err != nil || len(none.DBADash) != 0 {
		t.Fatalf("no dbadash: list must be valid and off: %v %v", none, err)
	}

	bad := map[string]string{
		"inline ADO password": "dbadash:\n  - name: a\n    dsn: \"server=s;user id=u;Password=p\"\n",
		"inline pwd":          "dbadash:\n  - name: a\n    dsn: \"server=s;uid=u;PWD=p\"\n",
		"inline URL password": "dbadash:\n  - name: a\n    dsn: \"sqlserver://u:p@s:1433?database=D\"\n",
		"twice":               "dbadash:\n  - name: a\n    dsn: env:X\n  - name: A\n    dsn: env:Y\n",
		"no name":             "dbadash:\n  - dsn: env:X\n",
		"no dsn":              "dbadash:\n  - name: a\n",
		"slash in name":       "dbadash:\n  - name: a/b\n    dsn: env:X\n",
		"interval too short":  "dbadash:\n  - name: a\n    dsn: env:X\n    interval: 30s\n",
	}
	for name, body := range bad {
		if _, err := loadYAML(t, body); err == nil {
			t.Errorf("%s: accepted, want refused", name)
		}
	}
}

func TestWithAppName(t *testing.T) {
	cases := map[string]string{
		"sqlserver://r@h:1433?database=D":     "sqlserver://r@h:1433?database=D&app+name=pgvigil-dbadash",
		"sqlserver://r@h:1433":                "sqlserver://r@h:1433?app+name=pgvigil-dbadash",
		"server=h;database=D;":                "server=h;database=D;app name=pgvigil-dbadash",
		"server=h;app name=mine":              "server=h;app name=mine",
		"sqlserver://h?database=D&app+name=x": "sqlserver://h?database=D&app+name=x",
	}
	for in, want := range cases {
		if got := withAppName(in); got != want {
			t.Errorf("withAppName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDetailValue(t *testing.T) {
	at := time.Date(2026, 11, 9, 5, 41, 13, 0, time.UTC)
	if got := detailValue(at); got != "2026-11-09 05:41:13" {
		t.Errorf("time: %v", got)
	}
	// a datetimeoffset in another zone is converted to UTC
	if got := detailValue(at.In(time.FixedZone("x", -8*3600))); got != "2026-11-09 05:41:13" {
		t.Errorf("offset time: %v", got)
	}
	if got := detailValue([]byte("97.123456")); got != 97.12 {
		t.Errorf("decimal: %v", got)
	}
	if got := detailValue(int64(42)); got != 42 {
		t.Errorf("int: %v", got)
	}
	if got := detailValue(nil); got != nil {
		t.Errorf("nil: %v", got)
	}
	if n, ok := asInt(uint8(4)); !ok || n != 4 {
		t.Errorf("tinyint status: %v %v", n, ok)
	}
}

func TestStatusKeysUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, k := range append(append([]string{}, StatusKeys...), DetailKeys...) {
		if seen[k] {
			t.Errorf("%s listed twice", k)
		}
		seen[k] = true
	}
	if len(StatusKeys) != 26 {
		t.Errorf("StatusKeys: %d, want the 26 of 0052's dbadash_checks()", len(StatusKeys))
	}
}

// TestReadNotAnswering: an empty dsn and a server that does not answer give an error, which ReadOne stores as the reason.
func TestReadNotAnswering(t *testing.T) {
	if _, err := Read(context.Background(), " "); err == nil || !strings.Contains(err.Error(), "resolved to nothing") {
		t.Errorf("empty dsn: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := Read(ctx, "sqlserver://r@127.0.0.1:1?database=D&dial+timeout=2"); err == nil {
		t.Error("a closed port answered")
	}
	p := NotRead("x")
	if p.Status != "not read" || p.Instances == nil {
		t.Errorf("NotRead: %+v", p)
	}
}
