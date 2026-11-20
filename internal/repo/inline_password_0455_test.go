package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// inlineStore opens a transaction on the test store with a live collector run of its own host; skips without a store.
func inlineStore(t *testing.T) (context.Context, pgx.Tx, string, int64) {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	sfx := time.Now().UnixNano() % 1000000000
	col := fmt.Sprintf("l9-%d", sfx)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '1 hour', now())`, col); err != nil {
		t.Fatal(err)
	}
	return ctx, tx, col, sfx
}

type inlineRow struct{ severity, setting, value, detail, source string }

func inlineFindings(ctx context.Context, t *testing.T, tx pgx.Tx, ids ...int) []inlineRow {
	t.Helper()
	rows, err := tx.Query(ctx, `SELECT severity, setting, value, detail, source FROM pgvigil.inline_password_findings
	                             WHERE instance_id = ANY($1) ORDER BY value`, ids)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []inlineRow
	for rows.Next() {
		var r inlineRow
		if err := rows.Scan(&r.severity, &r.setting, &r.value, &r.detail, &r.source); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// TestInlinePasswordFinding0455OnAStore (L9, migration 0455): a collector's start names the file instances whose dsn
// carries an inline PostgreSQL password (import_collector_inline_passwords, the run's whole list each time); the
// view pgvigil.inline_password_findings (its arm into the findings union is a join line) holds one 'inline password'
// warning per active instance so named on a host whose newest run is neither retired nor silent for a day, its detail
// naming the host and 'pgvigil secret seal'. A later start without the instance clears it; an inactive instance, a name
// with no instance and a retired host raise nothing.
func TestInlinePasswordFinding0455OnAStore(t *testing.T) {
	ctx, tx, col, sfx := inlineStore(t)
	ids := map[string]int{}
	for _, n := range []string{"a", "b", "off"} {
		name := fmt.Sprintf("l9-%s-%d", n, sfx)
		var id int
		if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform, is_active) VALUES ($1, 'self-managed', $2) RETURNING instance_id`,
			name, n != "off").Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	name := func(n string) string { return fmt.Sprintf("l9-%s-%d", n, sfx) }
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, col,
		[]string{name("a"), name("b"), name("off"), fmt.Sprintf("l9-none-%d", sfx)}); err != nil {
		t.Fatal(err)
	}
	got := inlineFindings(ctx, t, tx, ids["a"], ids["b"], ids["off"])
	if len(got) != 2 || got[0].value != name("a") || got[1].value != name("b") {
		t.Fatalf("findings %+v, want one for a and one for b (the inactive one and the unknown name none)", got)
	}
	for _, r := range got {
		if r.severity != "info" || r.setting != "inline password" || r.source != "pgvigil collector" ||
			!strings.Contains(r.detail, col) || !strings.Contains(r.detail, "pgvigil secret seal -name \""+r.value+"\"") ||
			!strings.Contains(r.detail, "the whole connection string") || !strings.Contains(r.detail, "the password alone") {
			t.Errorf("a finding's shape: %+v (want info (rn-l9 S3) / 'inline password' / 'pgvigil collector', the host, the quoted seal command and rn-l9 B2's words - the whole connection string to env:/file:, the password alone to a passfile or password_secret - in the detail)", r)
		}
		if strings.Contains(r.detail, "password=") {
			t.Errorf("the detail quotes a connection string: %q", r.detail)
		}
	}
	// the next start's list replaces the host's: b fixed, a still inline
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, col, []string{name("a")}); err != nil {
		t.Fatal(err)
	}
	if got := inlineFindings(ctx, t, tx, ids["a"], ids["b"]); len(got) != 1 || got[0].value != name("a") {
		t.Fatalf("after a start that lists a alone: %+v, want a alone", got)
	}
	// an empty list clears the host
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, col, []string{}); err != nil {
		t.Fatal(err)
	}
	if got := inlineFindings(ctx, t, tx, ids["a"], ids["b"]); len(got) != 0 {
		t.Fatalf("after a start that lists none: %+v, want none", got)
	}
	// a retired host's rows raise nothing
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, col, []string{name("a")}); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE pgvigil.collector_heartbeat SET retired_at = now() WHERE collector_id = $1`, col); err != nil {
		t.Fatal(err)
	}
	if got := inlineFindings(ctx, t, tx, ids["a"]); len(got) != 0 {
		t.Fatalf("a retired host's list: %+v, want none", got)
	}
	// an unknown collector id is refused in words, never a silent row
	if _, err := tx.Exec(ctx, `SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, "no-such-run", []string{name("a")}); err == nil {
		t.Error("an unknown collector run was accepted")
	}
	if _, err := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT s`); err != nil {
		t.Fatal(err)
	}
}

// TestInlinePasswordImportIsTheCollectorsDoor0455OnAStore (L9): the import is an import_ function - apply_roles makes
// it SECURITY DEFINER and grants it to pgvigil_collector; the table is no one's to write but through it.
func TestInlinePasswordImportIsTheCollectorsDoor0455OnAStore(t *testing.T) {
	ctx, tx, _, _ := inlineStore(t)
	var def, collector bool
	if err := tx.QueryRow(ctx, `SELECT p.prosecdef, has_function_privilege('pgvigil_collector', p.oid, 'EXECUTE')
	                              FROM pg_proc p WHERE p.oid = 'pgvigil.import_collector_inline_passwords(text, text[])'::regprocedure`).Scan(&def, &collector); err != nil {
		t.Fatal(err)
	}
	if !def || !collector {
		t.Errorf("import_collector_inline_passwords: SECURITY DEFINER %v, the collector's EXECUTE %v; want both", def, collector)
	}
	var write bool
	if err := tx.QueryRow(ctx, `SELECT has_table_privilege('pgvigil_collector', 'pgvigil.collector_inline_password', 'INSERT')`).Scan(&write); err != nil {
		t.Fatal(err)
	}
	if write {
		t.Error("pgvigil_collector may INSERT into collector_inline_password directly; the import is its only door")
	}
}

// TestInlinePasswordRunsOfOneHost0455OnAStore (rn-l9 S1 / S8): each run of a host keeps its own list - a console run
// started beside the service (0121's named case) neither replaces nor hides the service's list, a run that stopped
// cleanly lists nothing, and the day's window is each run's own newest beat, never the host's newest start.
func TestInlinePasswordRunsOfOneHost0455OnAStore(t *testing.T) {
	ctx, tx, svc, sfx := inlineStore(t)
	con := fmt.Sprintf("l9c-%d", sfx)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $2, 'linux', 'console', 'x', 2, now() - interval '10 minutes', now())`, con, svc); err != nil {
		t.Fatal(err)
	}
	ids := map[string]int{}
	name := func(n string) string { return fmt.Sprintf("l9r-%s-%d", n, sfx) }
	for _, n := range []string{"a", "b"} {
		var id int
		if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`, name(n)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	imp := func(run string, names ...string) {
		t.Helper()
		if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, run, append([]string{}, names...)); err != nil {
			t.Fatal(err)
		}
	}
	values := func() string {
		var vs []string
		for _, r := range inlineFindings(ctx, t, tx, ids["a"], ids["b"]) {
			vs = append(vs, strings.TrimSuffix(strings.TrimPrefix(r.value, "l9r-"), fmt.Sprintf("-%d", sfx)))
		}
		return strings.Join(vs, ",")
	}
	imp(svc, name("a")) // the service lists a
	imp(con, name("b")) // a console run on the same host lists b
	if got := values(); got != "a,b" {
		t.Fatalf("two live runs of one host listing a and b: findings %q, want a,b (one run's list never replaces another's)", got)
	}
	imp(con) // the console run's next list is empty: the service's a stands
	if got := values(); got != "a" {
		t.Fatalf("the console run listing none beside the service listing a: %q, want a", got)
	}
	imp(con, name("b"))
	if _, err := tx.Exec(ctx, `UPDATE pgvigil.collector_heartbeat SET stopped_at = now() WHERE collector_id = $1`, con); err != nil {
		t.Fatal(err)
	}
	if got := values(); got != "a" {
		t.Fatalf("the console run stopped (the host's newest start, but over): %q, want the service's a alone", got)
	}
	imp(svc, name("a")) // the service's next write drops the stopped run's rows
	var left int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collector_inline_password WHERE collector_id = $1`, con).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("a stopped run's %d row(s) stayed after another run of its host wrote", left)
	}
	if _, err := tx.Exec(ctx, `UPDATE pgvigil.collector_heartbeat SET beat_at = now() - interval '2 days' WHERE collector_id = $1`, svc); err != nil {
		t.Fatal(err)
	}
	if got := values(); got != "" {
		t.Fatalf("the service silent for two days: %q, want none (its list is not current)", got)
	}
	// N9: a run's rows go with its heartbeat row
	if _, err := tx.Exec(ctx, `DELETE FROM pgvigil.collector_heartbeat WHERE collector_id = $1`, svc); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collector_inline_password WHERE collector_id = $1`, svc).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("a deleted run's %d row(s) stayed", left)
	}
}
