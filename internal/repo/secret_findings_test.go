package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/secrets"
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
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id)
	}()
	logc := func(coll, status, note string, at time.Time) {
		t.Helper()
		if _, err := pool.Exec(ctx, `SELECT pgvigil.log_collection($1, $2, $3, 10, $4, $5)`, id, coll, at, status, note); err != nil {
			t.Fatal(err)
		}
	}
	finding := func() (string, string, string) {
		var sev, object, detail string
		_ = pool.QueryRow(ctx, `SELECT severity, object, detail FROM pgvigil.secret_findings WHERE instance_id = $1`, id).Scan(&sev, &object, &detail)
		return sev, object, detail
	}
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	var name string
	if err := pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	logc("activity", "ok", "", now.Add(-3*time.Minute))
	// review 5: the row as the collector writes it - through LogSecretFailure, with the connect's own wrapping
	cause := fmt.Errorf("connect %s: %w", name, &secrets.ReadError{Secret: "pgvigil/read", Code: "AccessDeniedException", Message: "not allowed", Refused: true})
	if err := r.LogSecretFailure(ctx, name, "postgres", "rds", nil, "activity", now.Add(-time.Minute), 10*time.Millisecond, cause); err != nil {
		t.Fatal(err)
	}
	if sev, object, detail := finding(); sev != "critical" || object != "AccessDeniedException, pgvigil/read" || !strings.Contains(detail, "GetSecretValue") {
		t.Fatalf("an unreadable secret: %q %q %q, want critical, the object 'AccessDeniedException, pgvigil/read', the right named", sev, object, detail)
	}
	// pgvigil.findings names a check in its setting column (0190's union); the error is read, never dropped
	var unreachable int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.findings WHERE instance_id = $1 AND (setting ILIKE '%unreachable%' OR setting ILIKE '%collection failing%')`, id).Scan(&unreachable); err != nil {
		t.Fatal(err)
	}
	if unreachable != 0 {
		t.Error("an unreadable secret raised 'server unreachable' or 'collection failing'")
	}
	logc("statements", "ok", "", now)
	if sev, _, _ := finding(); sev != "" {
		t.Errorf("a good run after the refusal: still %q", sev)
	}
	// a version the server refused: its own words (not 'the server was not asked')
	held := &secrets.ReadError{Secret: "pgvigil/read", Code: "LoginRefused", Message: "the server refused the secret's version v1"}
	if err := r.LogSecretFailure(ctx, name, "postgres", "rds", nil, "activity", now.Add(time.Second), time.Millisecond, held); err != nil {
		t.Fatal(err)
	}
	if _, object, detail := finding(); object != "LoginRefused, pgvigil/read" || !strings.Contains(detail, "refused the secret's current password") {
		t.Errorf("a refused version: %q %q", object, detail)
	}
}
