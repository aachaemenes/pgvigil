package web

import (
	"context"
	"encoding/json"
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

// TestJobToggleAuditOnAStore (B9c, B9-13; migration 0194): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it):
//   - import_mssql_actions_log takes a job_enable and a job_disable row with no pid on a SQL Server instance, and a
//     plan_evict row too (0194's CHECK holds 0157's list: a later file that re-creates it must not drop task 406's kind),
//     and a verify_backup row with no pid (0191's kind, inv's 301b: 0194 sorts after 0191 and copies its list too);
//   - import_pg_job_actions_log takes a job_enable and a job_disable row with no pid on a PostgreSQL instance, and
//     still refuses an action outside its list ('kill');
//   - the table still refuses a sqlserver row with action 'terminate' and a kill without a pid;
//   - GET /api/jobs/running lists job_enable and job_disable beside job_stop and job_start (off: no door on this test
//     server), and its log part carries the PostgreSQL job_enable row.
//
// Red on a store without 0194: the CHECK refuses job_enable ('actions_log_action_check') and
// import_pg_job_actions_log raises 'an action other than job_stop and job_start'.
func TestJobToggleAuditOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	msName, pgName := fmt.Sprintf("b9c-sql-%d", sfx), fmt.Sprintf("b9c-pg-%d", sfx)
	var ms, pg int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, msName).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`, pgName).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	defer func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.actions_log WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, []int{ms, pg}); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	}()
	row := func(inst, action, extra string) string {
		return fmt.Sprintf(`[{"instance_name":%q,"ui_user":"dba","action":%q,"reason":"b9c store test","outcome":"done"%s}]`, inst, action, extra)
	}
	job := `,"target":"nightly","target_id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","statement":"EXEC msdb.dbo.sp_update_job"`
	for _, a := range []string{"job_enable", "job_disable"} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, now(), $2::jsonb)`, ms, row(msName, a, job)); err != nil {
			t.Fatalf("import_mssql_actions_log %s: %v", a, err)
		}
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_pg_job_actions_log($1, now(), $2::jsonb)`, pg, row(pgName, a, `,"target":"b9c-cron","target_id":"pg_cron:71"`)); err != nil {
			t.Fatalf("import_pg_job_actions_log %s: %v", a, err)
		}
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, now(), $2::jsonb)`, ms, row(msName, "plan_evict", `,"target_id":"0x06000500"`)); err != nil {
		t.Fatalf("plan_evict: a store at 0194 must still take task 406's kind: %v", err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, now(), $2::jsonb)`, ms, row(msName, "verify_backup", `,"target":"b9c-db"`)); err != nil {
		t.Fatalf("verify_backup: a store at 0194 must still take 0191's kind, with no pid: %v", err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.actions_log WHERE instance_id = ANY($1) AND pid IS NULL AND action IN ('job_enable', 'job_disable')`, []int{ms, pg}).Scan(&n); err != nil || n != 4 {
		t.Fatalf("job_enable / job_disable rows without a pid: %d (want 4), %v", n, err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_pg_job_actions_log($1, now(), $2::jsonb)`, pg, row(pgName, "kill", "")); err == nil || !strings.Contains(err.Error(), "an action other than") {
		t.Fatalf("import_pg_job_actions_log took a 'kill' row: %v", err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, now(), $2::jsonb)`, ms, row(msName, "terminate", `,"pid":60`)); err == nil {
		t.Fatal("a sqlserver row with action 'terminate' landed")
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_actions_log($1, now(), $2::jsonb)`, ms, row(msName, "kill", "")); err == nil {
		t.Fatal("a kill without a session id landed")
	}

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	s.JobsRunning(rec, httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/jobs/running?instance=%d", pg), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/api/jobs/running: %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Actions map[string]struct {
			On     bool   `json:"on"`
			Reason string `json:"reason"`
		} `json:"actions"`
		Log *table `json:"log"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"job_stop", "job_start", "job_enable", "job_disable"} {
		a, ok := out.Actions[k]
		if !ok || a.On || a.Reason == "" {
			t.Fatalf("/api/jobs/running actions[%s] = %+v, present %v (want present, off, with a reason)", k, a, ok)
		}
	}
	seen := map[string]bool{}
	if out.Log != nil {
		ai := -1
		for i, c := range out.Log.Columns {
			if c == "action" {
				ai = i
			}
		}
		for _, r := range out.Log.Rows {
			if ai >= 0 {
				seen[fmt.Sprint(r[ai])] = true
			}
		}
	}
	if !seen["job_enable"] || !seen["job_disable"] {
		t.Fatalf("/api/jobs/running's log: actions %v (want job_enable and job_disable among them)", seen)
	}
}

// TestJobToggleAuditGateOnAStore (B9c review fold, A2 / B1): the enable / disable gate reads the repository itself. On
// a migrated store it is open on both engines; inside a transaction that puts 0157's CHECK back (no job_enable /
// job_disable), it is closed with words on both engines - so serve on a repository not migrated
// to 0194 sends nothing. The transaction is rolled back.
func TestJobToggleAuditGateOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	for _, pg := range []bool{false, true} {
		if off := toggleAuditOff(ctx, pool, pg); off != "" {
			t.Errorf("a store at 0194 (pg %v): %s, want open", pg, off)
		}
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(ctx, `ALTER TABLE pgvigil.actions_log DROP CONSTRAINT actions_log_action_check;
		ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (action IN ('cancel', 'terminate', 'kill', 'job_start', 'job_stop', 'plan_evict')) NOT VALID`); err != nil {
		t.Fatal(err)
	}
	for _, pg := range []bool{false, true} {
		if off := toggleAuditOff(ctx, tx, pg); !strings.Contains(off, "0194") {
			t.Errorf("a store without 0194's CHECK (pg %v): %q, want closed naming 0194", pg, off)
		}
	}
}
