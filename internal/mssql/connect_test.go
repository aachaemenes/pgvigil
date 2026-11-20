package mssql

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestConnectSaysWhyL145: a SQL Server instance whose dsn reference resolves to nothing fails its connect naming why.
func TestConnectSaysWhyL145(t *testing.T) {
	t.Setenv("PGV_L145_MSSQL_UNSET", "")
	if err := os.Unsetenv("PGV_L145_MSSQL_UNSET"); err != nil {
		t.Fatal(err)
	}
	_, _, err := Connect(context.Background(), config.Instance{Name: "m", Engine: config.EngineSQLServer, DSNRaw: "env:PGV_L145_MSSQL_UNSET"})
	if err == nil || !strings.Contains(err.Error(), "PGV_L145_MSSQL_UNSET") || !strings.Contains(err.Error(), "not set") {
		t.Errorf("connect over an unset variable: %v", err)
	}
}
