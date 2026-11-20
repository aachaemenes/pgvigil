package collect

import (
	"context"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestConnectNeverShowsAnUnparsedDSN (rn-l9 B2): an admin who read "move it to env:NAME" as the password alone has a
// dsn that is a bare word; pgx's parse error carries the whole string (its redaction knows password= and URLs only),
// and a failed connect's error reaches the streak, the findings, the alerts and the log - it never holds the word.
func TestConnectNeverShowsAnUnparsedDSN(t *testing.T) {
	t.Setenv("PGV_RNL9_PW", "s3cret-bare-word")
	_, err := Connect(context.Background(), config.Instance{Name: "pg1", DSNRaw: "env:PGV_RNL9_PW"})
	if err == nil {
		t.Fatal("a bare word connected")
	}
	if strings.Contains(err.Error(), "s3cret-bare-word") {
		t.Errorf("the failed connect's error holds the dsn's own text: %q", err)
	}
	if !strings.Contains(err.Error(), "does not parse") {
		t.Errorf("the failed connect's error does not say the dsn does not parse: %q", err)
	}
}
