//go:build !windows

package mssqlopen

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/microsoft/go-mssqldb/msdsn"
)

// azStandIn puts an az on PATH that logs each run's arguments to a file and prints a token expiring at 2100 - or, with
// AZ_FAIL set, az's own refusal naming a person - and returns the log's path; the process's az credential is dropped
// first, so no token another row cached answers.
func azStandIn(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "runs")
	script := "#!/bin/sh\necho \"$*\" >> " + log + "\n" +
		"if [ -n \"$AZ_FAIL\" ]; then echo \"ERROR: User 'someone@example.com' does not exist in MSAL token cache. Run 'az login'.\" >&2; exit 1; fi\n" +
		"echo '{\"accessToken\":\"tok-cached\",\"expires_on\":4102444800,\"tokenType\":\"Bearer\"}'\n"
	if err := os.WriteFile(filepath.Join(dir, "az"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	forget(identity{flow: AzCli})
	t.Cleanup(func() { forget(identity{flow: AzCli}); azNow = time.Now })
	return log
}

func azRuns(t *testing.T, log string) []string {
	t.Helper()
	b, err := os.ReadFile(log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func azProvider(t *testing.T) func(context.Context, string, string) (string, error) {
	t.Helper()
	cfg, err := msdsn.Parse("sqlserver://srv1.database.windows.net?database=d&fedauth=ActiveDirectoryAzCli")
	if err != nil {
		t.Fatal(err)
	}
	_, provide, err := tokenProvider(cfg, cfg.Parameters["fedauth"], nil)
	if err != nil {
		t.Fatal(err)
	}
	return provide
}

const azTenant = "11111111-2222-3333-4444-555555555555"

// TestAzCliTokenCached: five connects run az once - the token kept until five minutes before it expires - and one
// near its expiry runs az again; the server's tenant and the SQL resource reach az's command line, a tenant name that
// is not a tenant id's characters does not.
func TestAzCliTokenCached(t *testing.T) {
	log := azStandIn(t)
	provide := azProvider(t)
	for i := 0; i < 5; i++ {
		if tok, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/"+azTenant); err != nil || tok != "tok-cached" {
			t.Fatalf("connect %d: %q, %v", i, tok, err)
		}
	}
	runs := azRuns(t, log)
	if len(runs) != 1 {
		t.Fatalf("five connects ran az %d times, want 1: %q", len(runs), runs)
	}
	if !strings.Contains(runs[0], "--tenant "+azTenant) || !strings.Contains(runs[0], "--resource https://database.windows.net") {
		t.Errorf("az's arguments %q: want the server's tenant and the SQL resource", runs[0])
	}
	azNow = func() time.Time { return time.Unix(4102444800, 0).Add(-time.Minute) }
	if _, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/"+azTenant); err != nil {
		t.Fatal(err)
	}
	if runs := azRuns(t, log); len(runs) != 2 {
		t.Errorf("a token a minute from its expiry: az ran %d times in all, want 2", len(runs))
	}
	if _, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/bad;tenant"); err != nil {
		t.Fatal(err)
	}
	runs = azRuns(t, log)
	if last := runs[len(runs)-1]; strings.Contains(last, "--tenant") {
		t.Errorf("a malformed tenant reached az: %q", last)
	}
}

// TestAzCliSignInFailure: an az that gives no token is a sign-in failure (the heartbeat counts it as one, never as the
// server unreachable), naming the account that must run 'az login', a person az names masked; nothing is cached.
func TestAzCliSignInFailure(t *testing.T) {
	log := azStandIn(t)
	t.Setenv("AZ_FAIL", "1")
	provide := azProvider(t)
	_, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/"+azTenant)
	if err == nil || !IsSignInFailure(err) {
		t.Fatalf("an az that fails: %v, want a SignInError", err)
	}
	var mark interface{ SignInFailure() bool }
	if s, ok := err.(interface{ SignInFailure() bool }); ok {
		mark = s
	}
	if mark == nil {
		var si *SignInError
		if ok := asSignIn(err, &si); ok {
			mark = si
		}
	}
	if mark == nil || !mark.SignInFailure() {
		t.Errorf("the error carries no SignInFailure mark: %T", err)
	}
	words := err.Error()
	if !strings.Contains(words, "the az sign-in of "+azAccount()) || !strings.Contains(words, "run 'az login' as that account") || strings.Contains(words, "someone@example.com") || !strings.Contains(words, "<an account>") {
		t.Errorf("the words %q: want the account, the fix and the person masked", words)
	}
	t.Setenv("AZ_FAIL", "")
	if _, err := provide(context.Background(), "https://database.windows.net/", "https://login.microsoftonline.com/"+azTenant); err != nil {
		t.Errorf("after az signs in again: %v", err)
	}
	if runs := azRuns(t, log); len(runs) != 2 {
		t.Errorf("a failed fetch must keep nothing: az ran %d times, want 2", len(runs))
	}
}
