package collect

import (
	"context"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestConnectSaysWhyL145: an instance whose dsn reference resolves to nothing fails its connect naming why.
func TestConnectSaysWhyL145(t *testing.T) {
	_, err := Connect(context.Background(), config.Instance{Name: "a", DSNRaw: "file:/nonexistent/pgv-l145.dsn"})
	if err == nil || !strings.Contains(err.Error(), "/nonexistent/pgv-l145.dsn") || !strings.Contains(err.Error(), "no such file") || !strings.Contains(err.Error(), "resolved to an empty string") {
		t.Errorf("connect over a missing file: %v", err)
	}
}
