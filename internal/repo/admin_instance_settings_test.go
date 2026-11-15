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

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): import_admin_instance_settings (migration 0263, the
// ServiceConfig takes' ST5a) keeps a page instance's own schedules and query_text in admin_instances.settings, audits
// every outcome as 'instance settings', moves the inventory's generation on a change and only then, refuses serve's
// verdict, an instance of pgvigil.yaml, an unknown instance and every shape that is not whole seconds from 0 to 30 days
// or one of query_text's three words; admin_instance_settings() answers it beside admin_inventory() in one statement.
func TestAdminInstanceSettingsOnAStore(t *testing.T) {
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
	name := fmt.Sprintf("iset-pg-%d", tag)
	user := fmt.Sprintf("iset-user-%d", tag)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.admin_instances WHERE name = $1`, `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`} {
			arg := name
			if q != `DELETE FROM pgvigil.admin_instances WHERE name = $1` {
				arg = user
			}
			if _, err := pool.Exec(context.Background(), q, arg); err != nil {
				t.Error(err)
			}
		}
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by)
	                             VALUES ($1, 'postgres', 'file:/nonexistent/iset', 'password', '192.0.2.8', $2, $2)`, name, user); err != nil {
		t.Fatal(err)
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
	gen := func() string { t.Helper(); return one(`SELECT pgvigil.admin_inventory_generation()::text`) }
	// call sends one write; settings is the raw JSON text of the payload's settings (empty = left out)
	call := func(target, settings string, extra map[string]any) string {
		t.Helper()
		pay := map[string]any{"op": "settings", "ui_user": user, "client": "192.0.2.7", "name": target, "file_names": []string{"iset-file-a"}}
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

	// a change: stored, audited with its words, the generation moved
	g0 := gen()
	set := `{"schedules": {"statements": 60, "activity": 0}, "query_text": "none"}`
	if got := call(name, set, nil); got != "done|settings of "+name+" saved: activity off, statements every 60 s; query_text none" {
		t.Errorf("a change: %s", got)
	}
	g1 := gen()
	if g1 == g0 {
		t.Errorf("the generation did not move on a change (%s)", g0)
	}
	if got := one(`SELECT settings::text FROM pgvigil.admin_instances WHERE name = $1`, name); got != `{"schedules": {"activity": 0, "statements": 60}, "query_text": "none"}` {
		t.Errorf("stored: %s", got)
	}
	// the same again: unchanged, audited, the generation kept
	if got := call(name, set, nil); got != "done|the settings of "+name+" are unchanged" {
		t.Errorf("the same again: %s", got)
	}
	if g := gen(); g != g1 {
		t.Errorf("the generation moved on an unchanged write: %s -> %s", g1, g)
	}
	// the read beside the inventory, in one statement
	if got := one(`SELECT s.settings->'schedules'->>'statements' FROM pgvigil.admin_inventory() i LEFT JOIN pgvigil.admin_instance_settings() s USING (name) WHERE i.name = $1`, name); got != "60" {
		t.Errorf("the read: %s", got)
	}

	// refusals, each audited; the stored settings untouched
	for _, c := range []struct {
		target, settings string
		extra            map[string]any
		want             string
	}{
		{name, `{"schedules": {"statements": 60}}`, map[string]any{"verdict": "statements2 is not a collection of postgres"}, "statements2 is not a collection of postgres"},
		{"iset-file-a", `{}`, nil, "iset-file-a is an instance of pgvigil.yaml: its schedules:, disabled: and query_text: in the file are its settings"},
		{fmt.Sprintf("iset-none-%d", tag), `{}`, nil, fmt.Sprintf("no instance iset-none-%d was added here", tag)},
		{name, ``, nil, "settings must be an object"},
		{name, `[]`, nil, "settings must be an object"},
		{name, `{"schedules": {}, "disabled": ["x"]}`, nil, "settings hold schedules and query_text only"},
		{name, `{"schedules": ["statements"]}`, nil, "schedules must be an object of a collection and its seconds"},
		{name, `{"schedules": {"statements": -5}}`, nil, "each schedule must be whole seconds from 0 (off) to 2592000 (30 days)"},
		{name, `{"schedules": {"statements": 1.5}}`, nil, "each schedule must be whole seconds from 0 (off) to 2592000 (30 days)"},
		{name, `{"schedules": {"statements": "60"}}`, nil, "each schedule must be whole seconds from 0 (off) to 2592000 (30 days)"},
		{name, `{"schedules": {"statements": 2592001}}`, nil, "each schedule must be whole seconds from 0 (off) to 2592000 (30 days)"},
		{name, `{"query_text": "raw"}`, nil, "query_text must be full, normalized or none"},
		{name, `{"query_text": null}`, nil, "query_text must be full, normalized or none"},
		{name, `{}`, map[string]any{"op": "edit"}, "op must be settings"},
	} {
		if got := call(c.target, c.settings, c.extra); got != "refused|"+c.want {
			t.Errorf("%s %s %v: %s, want refused|%s", c.target, c.settings, c.extra, got, c.want)
		}
	}
	if got := one(`SELECT count(*)::text FROM pgvigil.admin_audit WHERE ui_user = $1 AND op = 'instance settings' AND outcome = 'refused'`, user); got != "14" {
		t.Errorf("refused audit rows: %s, want 14", got)
	}
	if g := gen(); g != g1 {
		t.Errorf("the generation moved on a refusal: %s -> %s", g1, g)
	}
	if got := one(`SELECT settings->'schedules'->>'statements' FROM pgvigil.admin_instances WHERE name = $1`, name); got != "60" {
		t.Errorf("a refusal changed the settings: statements %s", got)
	}

	// back to the defaults
	if got := call(name, `{}`, nil); got != "done|settings of "+name+" saved: every setting at its default" {
		t.Errorf("the defaults: %s", got)
	}
	if got := one(`SELECT string_agg(outcome || '|' || detail, ' ;; ' ORDER BY audit_id) FROM pgvigil.admin_audit WHERE ui_user = $1 AND outcome = 'done'`, user); got !=
		"done|activity off, statements every 60 s; query_text none ;; done|unchanged: activity off, statements every 60 s; query_text none ;; done|every setting at its default" {
		t.Errorf("the done audit rows: %s", got)
	}
}
