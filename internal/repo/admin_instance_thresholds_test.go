package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): 0266 (ST5b) widens import_admin_instance_settings -
// a SQL Server page instance's own thresholds (mssql_thresholds' 11 numbers and backup_exclude's patterns), a paused
// collection's own interval kept for its resume, and 'expect' (the settings as the editor read them: a write over a
// change made since is refused) - each refusal audited, every accepted object read back through
// admin_instance_settings(); the audit's words name thresholds, backup_exclude and paused.
func TestAdminInstanceThresholdsOnAStore(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	ms, pg := fmt.Sprintf("ithr-ms-%d", tag), fmt.Sprintf("ithr-pg-%d", tag)
	user := fmt.Sprintf("ithr-user-%d", tag)
	defer func() {
		for _, n := range []string{ms, pg} {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, n); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user); err != nil {
			t.Error(err)
		}
	}()
	for _, r := range []struct{ name, engine, auth string }{{ms, "sqlserver", "sql"}, {pg, "postgres", "password"}} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by)
		                             VALUES ($1, $2, 'file:/nonexistent/ithr', $3, '192.0.2.9', $4, $4)`, r.name, r.engine, r.auth, user); err != nil {
			t.Fatal(err)
		}
	}
	one := func(q string, args ...any) string {
		t.Helper()
		var s *string
		if err := pool.QueryRow(ctx, q, args...).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		if s == nil {
			return "<nil>"
		}
		return *s
	}
	call := func(target, settings string, extra map[string]any) string {
		t.Helper()
		pay := map[string]any{"op": "settings", "ui_user": user, "client": "192.0.2.7", "name": target, "file_names": []string{"ithr-file-a"}}
		for k, v := range extra {
			pay[k] = v
		}
		if settings != "" {
			pay["settings"] = json.RawMessage(settings)
		}
		b, err := json.Marshal(pay)
		if err != nil {
			t.Fatal(err)
		}
		return one(`SELECT (r->>'outcome') || '|' || (r->>'detail') FROM pgvigil.import_admin_instance_settings($1, $2::jsonb) r`, time.Now().UTC(), string(b))
	}
	stored := func(name string) string {
		t.Helper()
		return one(`SELECT s.settings::text FROM pgvigil.admin_instance_settings() s WHERE s.name = $1`, name)
	}

	// accepted: thresholds alone; with schedules and backup_exclude; a pause keeping the own interval
	th := `{"thresholds": {"redo_queue_kb": 512000, "full_backup_hours": 1}}`
	if got := call(ms, th, nil); got != "done|settings of "+ms+" saved: thresholds full_backup_hours 1, redo_queue_kb 512000" {
		t.Errorf("thresholds alone: %s", got)
	}
	if got := stored(ms); got != `{"thresholds": {"redo_queue_kb": 512000, "full_backup_hours": 1}}` {
		t.Errorf("stored: %s", got)
	}
	all := `{"schedules": {"mssql_jobs": 0}, "paused": {"mssql_jobs": 600}, "thresholds": {"job_long_factor": 2.5, "backup_exclude": ["Sales\\_%", "tmp%"]}}`
	if got := call(ms, all, map[string]any{"expect": json.RawMessage(th)}); got !=
		"done|settings of "+ms+" saved: mssql_jobs off; thresholds job_long_factor 2.5; backup_exclude Sales\\_%, tmp%; paused mssql_jobs (its own 600 s kept)" {
		t.Errorf("schedules, paused, thresholds and backup_exclude: %s", got)
	}
	// expect: a write over a change made since it was read is refused
	if got := call(ms, `{}`, map[string]any{"expect": json.RawMessage(th)}); got != "refused|the settings of "+ms+" changed since they were read: read them again" {
		t.Errorf("a stale expect: %s", got)
	}

	// refusals, each audited; the stored settings untouched
	before := stored(ms)
	known := "diff_backup_hours, full_backup_hours, job_failed_hours, job_long_factor, job_long_min_seconds, log_backup_minutes, log_send_queue_kb, new_database_hours, nul_backup_days, redo_queue_kb, repl_undistributed_commands, backup_exclude"
	for _, c := range []struct{ target, settings, want string }{
		{pg, `{"thresholds": {"redo_queue_kb": 1}}`, "thresholds are a SQL Server instance's (mssql_thresholds): " + pg + " is a PostgreSQL instance"},
		{ms, `{"thresholds": {"nope": 1}}`, "threshold nope is not known; known: " + known},
		{ms, `{"thresholds": {"redo_queue_kb": -1}}`, "each threshold must be a number of 0 or more (redo_queue_kb -1)"},
		{ms, `{"thresholds": {"redo_queue_kb": "5"}}`, "each threshold must be a number of 0 or more (redo_queue_kb \"5\")"},
		{ms, `{"thresholds": ["redo_queue_kb"]}`, "thresholds must be an object of a threshold and its number"},
		{ms, `{"thresholds": {"backup_exclude": "Sales"}}`, "backup_exclude must be a list of database name patterns, none blank"},
		{ms, `{"thresholds": {"backup_exclude": ["Sales", " "]}}`, "backup_exclude must be a list of database name patterns, none blank"},
		{ms, `{"thresholds": {"backup_exclude": ["Sales", "\t\u000b"]}}`, "backup_exclude must be a list of database name patterns, none blank"},
		{ms, `{"paused": {"mssql_jobs": 30}}`, "each paused interval must be whole seconds from 60 to 2592000 (30 days)"},
		{ms, `{"paused": ["mssql_jobs"]}`, "paused must be an object of a collection and its seconds"},
		{ms, `{"disabled": ["x"]}`, "settings hold schedules, query_text, thresholds and paused only"},
	} {
		if got := call(c.target, c.settings, nil); got != "refused|"+c.want {
			t.Errorf("%s %s: %s, want refused|%s", c.target, c.settings, got, c.want)
		}
	}
	if got := one(`SELECT count(*)::text FROM pgvigil.admin_audit WHERE ui_user = $1 AND op = 'instance settings' AND outcome = 'refused'`, user); got != "12" {
		t.Errorf("refused audit rows: %s, want 12", got)
	}
	if got := stored(ms); got != before {
		t.Errorf("a refusal changed the settings: %s, was %s", got, before)
	}
	// back to the defaults, the expect matching
	if got := call(ms, `{}`, map[string]any{"expect": json.RawMessage(before)}); got != "done|settings of "+ms+" saved: every setting at its default" {
		t.Errorf("the defaults: %s", got)
	}
}

// TestAdminInstanceSettingsExpectRace: two editors save with the same expect at once - A's write
// uncommitted in a transaction, B's on another connection. B waits for A's row and then sees A's settings: refused
// 'changed since they were read', never A's write overwritten unseen; and a no-break space is a pattern (m3).
func TestAdminInstanceSettingsExpectRace(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	ms, user := fmt.Sprintf("irace-ms-%d", tag), fmt.Sprintf("irace-user-%d", tag)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, ms)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user)
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by)
	                             VALUES ($1, 'sqlserver', 'file:/nonexistent/irace', 'sql', '192.0.2.9', $2, $2)`, ms, user); err != nil {
		t.Fatal(err)
	}
	pay := func(settings string) string {
		b, _ := json.Marshal(map[string]any{"op": "settings", "ui_user": user, "client": "192.0.2.7", "name": ms, "file_names": []string{},
			"settings": json.RawMessage(settings), "expect": json.RawMessage(`{}`)})
		return string(b)
	}
	const q = `SELECT (r->>'outcome') || '|' || (r->>'detail') FROM pgvigil.import_admin_instance_settings($1, $2::jsonb) r`
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	var a string
	if err := tx.QueryRow(ctx, q, time.Now().UTC(), pay(`{"thresholds": {"redo_queue_kb": 1}}`)).Scan(&a); err != nil || a[:5] != "done|" {
		t.Fatalf("A: %s (%v)", a, err)
	}
	bDone := make(chan string, 1)
	go func() {
		var b string
		if err := pool.QueryRow(ctx, q, time.Now().UTC(), pay(`{"thresholds": {"redo_queue_kb": 2}}`)).Scan(&b); err != nil {
			b = "error|" + err.Error()
		}
		bDone <- b
	}()
	select {
	case b := <-bDone:
		t.Fatalf("B ended while A's write was open: %s", b)
	case <-time.After(2 * time.Second):
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if b := <-bDone; b != "refused|the settings of "+ms+" changed since they were read: read them again" {
		t.Errorf("B after A's commit: %s (want refused: changed since they were read)", b)
	}
	var stored string
	if err := pool.QueryRow(ctx, `SELECT s.settings::text FROM pgvigil.admin_instance_settings() s WHERE s.name = $1`, ms).Scan(&stored); err != nil || stored != `{"thresholds": {"redo_queue_kb": 1}}` {
		t.Errorf("stored after both: %s (%v), want A's", stored, err)
	}
	b, _ := json.Marshal(map[string]any{"op": "settings", "ui_user": user, "client": "192.0.2.7", "name": ms, "file_names": []string{},
		"settings": json.RawMessage(`{"thresholds": {"backup_exclude": ["\u00a0"]}}`)})
	var nb string
	if err := pool.QueryRow(ctx, q, time.Now().UTC(), string(b)).Scan(&nb); err != nil || nb[:5] != "done|" {
		t.Errorf("a no-break space pattern: %s (%v), want done (not blank on either side)", nb, err)
	}
}
