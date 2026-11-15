package repo

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// 0192 (task B24e, the lead's Q7): an instance whose newest runs could not read their password from AWS Secrets
// Manager has its own critical finding naming the refusal (never 'server unreachable'); a good run after it clears it.
func TestSecretFindingsOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', NULL::text, NULL::int, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("sec-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id) }()
	logc := func(coll, status, note string, at time.Time) {
		t.Helper()
		if _, err := pool.Exec(ctx, `SELECT pgvigil.log_collection($1, $2, $3, 10, $4, $5)`, id, coll, at, status, note); err != nil {
			t.Fatal(err)
		}
	}
	finding := func() (string, string) {
		var sev, detail string
		_ = pool.QueryRow(ctx, `SELECT severity, detail FROM pgvigil.secret_findings WHERE instance_id = $1`, id).Scan(&sev, &detail)
		return sev, detail
	}
	now := time.Now().UTC()
	logc("activity", "ok", "", now.Add(-3*time.Minute))
	logc("activity", "error", "secret: the password could not be read from AWS Secrets Manager: AccessDeniedException, pgvigil/read (not allowed)", now.Add(-time.Minute))
	if sev, detail := finding(); sev != "critical" || detail == "" {
		t.Fatalf("an unreadable secret: %q %q, want critical with the refusal's words", sev, detail)
	}
	var unreachable int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.findings WHERE instance_id = $1 AND check_name ILIKE '%unreachable%'`, id).Scan(&unreachable)
	if unreachable != 0 {
		t.Error("an unreadable secret raised 'server unreachable'")
	}
	logc("statements", "ok", "", now)
	if sev, _ := finding(); sev != "" {
		t.Errorf("a good run after the refusal: still %q", sev)
	}
}
