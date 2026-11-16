package web

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestRoundedRatesOnEveryVersionOnAStore (rel-pg13-round): PostgreSQL 13's extract() returns double precision (14
// made it numeric) and 13 has no round(double precision, integer), so a two-argument round over an uncast extract
// fails there when the statement is parsed, with or without rows. Each read that rounds such a figure answers 200 on
// a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it; the box runs it on a 13 store and an 18 one):
//
//	/api/mssql/jobs, the part running: pct_of_avg (the run so far as a percentage of the average)
//	/api/mssql/backup_files for a database, the part history: mb_s and write_mb_s (a backup's size over its duration)
//
// An empty instance is enough: the function is resolved at parse.
func TestRoundedRatesOnEveryVersionOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("round13-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	for _, c := range []struct {
		h    http.HandlerFunc
		path string
	}{
		{s.MSSQLJobs, fmt.Sprintf("/api/mssql/jobs?instance=%d&part=running", id)},
		{s.MSSQLBackupFiles, fmt.Sprintf("/api/mssql/backup_files?instance=%d&db=master&part=history", id)},
	} {
		rec := httptest.NewRecorder()
		c.h(rec, httptest.NewRequest(http.MethodGet, c.path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s: %d %s", c.path, rec.Code, strings.TrimSpace(rec.Body.String()))
		}
	}
}
