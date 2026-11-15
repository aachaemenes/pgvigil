package mssql

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// A run whose collection does not apply to the instance opens no connection to it (task B2a-N1): an Azure SQL
// Database skips 7 of the 12 minute collections, and each skip used to connect and detect first. Counted by the
// server itself: SQL Server's 'Logins/sec' counter is the cumulative count of logins since the server started, read
// on the test's own connection (opened before the runs) around three runs of a collection this server is not
// (mssql_azuredb_resources is Azure SQL Database's). The run before them connects and detects as always. Needs a
// SQL Server (PGVIGIL_MSSQL_TEST_DSN, a login that may read sys.dm_os_performance_counters) that nothing else logs
// in to meanwhile, and a repository (PGVIGIL_REPO_TEST_DSN, migrated by the test).
func TestRunOnceSkipOpensNoConnectionLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_MSSQL_TEST_DSN")
	rdsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" || rdsn == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_DSN and PGVIGIL_REPO_TEST_DSN are both needed")
	}
	t.Setenv("PGVIGIL_MSSQL_TEST_DSN_RESOLVED", dsn)
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	r, err := repo.Open(ctx, rdsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	in := config.Instance{Name: "runonce-skip-" + time.Now().UTC().Format("150405.000"), Engine: config.EngineSQLServer,
		DSNRaw: "env:PGVIGIL_MSSQL_TEST_DSN_RESOLVED"}
	db, conn, err := Connect(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	logins := func() int64 {
		t.Helper()
		var v int64
		if err := conn.QueryRowContext(ctx, `SELECT cntr_value FROM sys.dm_os_performance_counters
			WHERE counter_name = N'Logins/sec' AND object_name LIKE N'%General Statistics%'`).Scan(&v); err != nil {
			t.Fatal(err)
		}
		return v
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	first := logins()
	if res := RunOnce(ctx, log, r, in, Prefix+"waits"); res.Err != nil || strings.Contains(res.Note, "skipped") {
		t.Fatalf("the applicable run: %+v", res)
	}
	if n := logins() - first; n != 1 {
		t.Fatalf("the applicable run logged in %d time(s), want 1 (another client is logging in to this server?)", n)
	}
	before := logins()
	const skips = 3
	for i := 0; i < skips; i++ {
		res := RunOnce(ctx, log, r, in, Prefix+"azuredb_resources")
		if res.Err != nil || !strings.Contains(res.Note, "skipped: the database's resource use") {
			t.Fatalf("skipped run %d: %+v", i+1, res)
		}
	}
	if n := logins() - before; n != 0 {
		t.Errorf("%d skipped runs logged in %d time(s), want 0: a run whose collection does not apply connected", skips, n)
	}

	// the skip is recorded as before: the collection's current row says skipped and why
	pc, err := pgx.Connect(ctx, rdsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = pc.Close(ctx) }()
	var status, note string
	if err := pc.QueryRow(ctx, `SELECT d.status, coalesce(d.note, '') FROM pgvigil.collection_dates d
		JOIN pgvigil.instances i USING (instance_id) WHERE i.name = $1 AND d.collection = $2`,
		in.Name, Prefix+"azuredb_resources").Scan(&status, &note); err != nil {
		t.Fatal(err)
	}
	if status != "skipped" || !strings.HasPrefix(note, "the database's resource use") {
		t.Errorf("the recorded skip = %q %q, want skipped with Applies' reason", status, note)
	}
}
