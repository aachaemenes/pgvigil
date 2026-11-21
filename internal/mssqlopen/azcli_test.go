package mssqlopen

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	mssql "github.com/microsoft/go-mssqldb"
	"github.com/microsoft/go-mssqldb/msdsn"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestAzCliFlowL173 (PerformanceMonitor 3.7.0's Azure Existing Sign-In): a dsn with
// fedauth=ActiveDirectoryAzCli signs in with the az CLI sign-in of the account the process runs as - here a stand-in
// az on PATH printing a token - through one credential, the audience check kept; a login or a secret beside it is
// refused in words; the page's door refuses the form as it refuses the host's other own identities.
func TestAzCliFlowL173(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the stand-in az is a shell script")
	}
	dir := t.TempDir()
	script := "#!/bin/sh\necho '{\"accessToken\":\"tok-from-az-L173\",\"expires_on\":4102444800,\"tokenType\":\"Bearer\"}'\n"
	if err := os.WriteFile(filepath.Join(dir, "az"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	cfg, err := msdsn.Parse("sqlserver://srv1.database.windows.net?database=d&fedauth=ActiveDirectoryAzCli")
	if err != nil {
		t.Fatal(err)
	}
	workflow, provide, err := tokenProvider(cfg, cfg.Parameters["fedauth"], nil)
	if err != nil || workflow != mssql.FedAuthADALWorkflowPassword {
		t.Fatalf("the az flow: workflow %d, %v", workflow, err)
	}
	tok, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555")
	if err != nil || tok != "tok-from-az-L173" {
		t.Errorf("the token: %q, %v - want the stand-in az's", tok, err)
	}
	if _, err := provide(context.Background(), "https://vault.azure.net", "https://login.microsoftonline.com/x"); err == nil || !strings.Contains(err.Error(), "not an Azure SQL resource") {
		t.Errorf("another audience: %v, want refused", err)
	}
	for _, dsn := range []string{
		"sqlserver://srv1.database.windows.net?fedauth=ActiveDirectoryAzCli&password=x",
		"sqlserver://someone@srv1.database.windows.net?fedauth=ActiveDirectoryAzCli",
	} {
		c, err := msdsn.Parse(dsn)
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := tokenProvider(c, c.Parameters["fedauth"], nil); err == nil || !strings.Contains(err.Error(), "az") {
			t.Errorf("%s: %v, want a refusal naming the az sign-in", dsn, err)
		}
	}
	if why := config.PageDSNRefusal("p1", config.EngineSQLServer, "sqlserver://srv1.database.windows.net?fedauth=ActiveDirectoryAzCli"); !strings.Contains(why, "own identity") {
		t.Errorf("the page's door over an az sign-in: %q, want it refused as the server's own identity", why)
	}
	if _, err := armCredential("sqlserver://srv1.database.windows.net?fedauth=ActiveDirectoryAzCli"); err != nil {
		t.Errorf("the failover group read's credential for the az flow: %v", err)
	}
}
