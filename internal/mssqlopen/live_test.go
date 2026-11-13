package mssqlopen

import (
	"context"
	"database/sql"
	"os"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// auth windows off Windows against a real SQL Server (scripts/proof-signin.sh: a SQL Server 2022 container; skipped
// without PGVIGIL_SIGNIN_HOST, host:port, and PGVIGIL_SIGNIN_SA_DSN, its sa). Before this package the string
// BuildDSN wrote for auth windows had no login and no authenticator, so go-mssqldb's NTLM default, given no
// DOMAIN\user, fell back to a SQL login with an EMPTY user name (the server logs Login failed for user, the name
// empty). Now the string asks Kerberos (authenticator=krb5), which fails on the collector with a krb5 error, and the
// server logs no login attempt at all.
func TestWindowsOffWindowsLive(t *testing.T) {
	hostPort, saDSN := os.Getenv("PGVIGIL_SIGNIN_HOST"), os.Getenv("PGVIGIL_SIGNIN_SA_DSN")
	if hostPort == "" || saDSN == "" {
		t.Skip("PGVIGIL_SIGNIN_HOST / PGVIGIL_SIGNIN_SA_DSN not set")
	}
	host, p, ok := strings.Cut(hostPort, ":")
	port, err := strconv.Atoi(p)
	if !ok || err != nil {
		t.Fatalf("PGVIGIL_SIGNIN_HOST %q is not host:port", hostPort)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	sa, err := sql.Open("sqlserver", saDSN)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sa.Close() }()
	failed := func() int {
		t.Helper()
		var n int
		// the current error log's lines of a failed login with an empty user name
		err := sa.QueryRowContext(ctx, `SET NOCOUNT ON;
DECLARE @l TABLE (logdate datetime, process nvarchar(100), txt nvarchar(max));
INSERT @l EXEC master.dbo.xp_readerrorlog 0, 1, N'Login failed for user ''''.';
SELECT count(*) FROM @l;`).Scan(&n)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	ping := func(open func(string) (*sql.DB, error), dsn string) error {
		t.Helper()
		db, err := open(dsn)
		if err != nil {
			return err
		}
		defer func() { _ = db.Close() }()
		return db.PingContext(ctx)
	}
	settle := func() { time.Sleep(2 * time.Second) } // the error log line is written after the refusal reaches the client

	n0 := failed()
	before := "sqlserver://" + hostPort + "?encrypt=true&TrustServerCertificate=true" // BuildDSN's auth windows before C1
	err = ping(func(d string) (*sql.DB, error) { return sql.Open("sqlserver", d) }, before)
	t.Logf("before: %v", err)
	if err == nil || !strings.Contains(err.Error(), "Login failed for user ''") {
		t.Fatalf("before: want \"Login failed for user ''\", got %v", err)
	}
	settle()
	n1 := failed()
	if n1 != n0+1 {
		t.Fatalf("before: the server logged %d failed empty-user login(s), want 1", n1-n0)
	}

	if runtime.GOOS == "windows" {
		t.Skip("the after half is the form off Windows (on Windows auth windows is SSPI)")
	}
	after, err := config.BuildDSN(config.Conn{Engine: config.EngineSQLServer, Auth: "windows", Host: host, Port: port, Extra: "TrustServerCertificate=true"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(after, "authenticator=krb5") {
		t.Fatalf("after: BuildDSN wrote %s, want authenticator=krb5", after)
	}
	err = ping(Open, after)
	t.Logf("after: %s -> %v", after, err)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "krb5") || strings.Contains(err.Error(), "Login failed") {
		t.Fatalf("after: want a krb5 error and no login refusal, got %v", err)
	}
	settle()
	if n2 := failed(); n2 != n1 {
		t.Fatalf("after: the server logged %d more failed login(s), want 0 (no SQL login attempted)", n2-n1)
	}
}
