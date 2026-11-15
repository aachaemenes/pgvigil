package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), which also stands in for a monitored PostgreSQL
// server: op 'rights' (ST2) as the store's own login - nothing needed is missing - and as a role without pg_monitor
// whose name needs quoting: pg_monitor missing, its GRANT printed with the name as quote_ident writes it; that line,
// run as it is printed, makes the next read hold it. The clicks are audited; an unknown instance and an unreachable
// one say why; no answer holds a connection string.
func TestInstanceRightsOnAStore(t *testing.T) {
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
	user := fmt.Sprintf("rights-user-%d", tag)
	role := fmt.Sprintf("Chk Mon %d", tag) // a capital and a space: quote_ident must quote it
	quoted := `"` + role + `"`
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	roleDSN := fmt.Sprintf("host=%s port=%d user='%s' dbname=%s sslmode=disable", cfg.Host, cfg.Port, role, cfg.Database)
	if _, err := pool.Exec(ctx, `CREATE ROLE `+quoted+` LOGIN`); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DROP OWNED BY ` + quoted, `DROP ROLE ` + quoted} {
			if _, err := pool.Exec(context.Background(), q); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user); err != nil {
			t.Error(err)
		}
	}()
	if c, err := pgx.Connect(ctx, roleDSN); err != nil {
		t.Skipf("the store does not let a role without a password connect (trust authentication is needed for this test): %v", err)
	} else {
		_ = c.Close(ctx)
	}
	full, nomon, dead := fmt.Sprintf("rights-full-%d", tag), fmt.Sprintf("rights-nomon-%d", tag), fmt.Sprintf("rights-dead-%d", tag)
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	s.SetInstancesAdmin(InstancesAdmin{File: []config.Instance{{Name: full, DSNRaw: dsn}, {Name: nomon, DSNRaw: roleDSN},
		{Name: dead, DSNRaw: "host=127.0.0.1 port=1 user=nobody dbname=postgres connect_timeout=2 sslmode=disable"}}})
	read := func(name string) (map[string]any, map[string]string) {
		t.Helper()
		rec := httptest.NewRecorder()
		s.instanceRights(rec, httptest.NewRequest(http.MethodPost, "/api/admin/instances", nil), user, map[string]any{"op": "rights", "name": name})
		raw := rec.Body.String()
		if strings.Contains(raw, "host=") || strings.Contains(raw, "sslmode") || strings.Contains(raw, "DSNRaw") {
			t.Errorf("%s: the answer holds a connection string: %s", name, raw)
		}
		var body map[string]any
		if err := json.Unmarshal([]byte(raw), &body); err != nil {
			t.Fatalf("%s: %v: %s", name, err, raw)
		}
		states := map[string]string{}
		if tb, ok := body["rights"].(map[string]any); ok {
			cols, _ := tb["columns"].([]any)
			at := map[string]int{}
			for i, c := range cols {
				at[fmt.Sprint(c)] = i
			}
			rows, _ := tb["rows"].([]any)
			for _, r := range rows {
				row := r.([]any)
				states[fmt.Sprint(row[at["key"]])] = fmt.Sprint(row[at["state"]])
			}
		}
		return body, states
	}

	// the store's own login (a superuser here): nothing needed is missing
	b, st := read(full)
	if b["ok"] != true || st["pg_monitor"] != "held" || st["connect"] != "held" || fmt.Sprint(b["missing_needed"]) != "0" {
		t.Errorf("the store's own login: %v, states %v", b, st)
	}
	if !strings.HasPrefix(fmt.Sprint(b["platform"]), "PostgreSQL, ") {
		t.Errorf("the platform: %v", b["platform"])
	}

	// a role without pg_monitor: missing, with its GRANT as quote_ident writes the name
	b, st = read(nomon)
	wantLine := "GRANT pg_monitor TO " + quoted + ";"
	if b["ok"] != true || b["login"] != role || st["pg_monitor"] != "missing" || st["connect"] != "held" || fmt.Sprint(b["missing_needed"]) != "1" {
		t.Errorf("the role without pg_monitor: %v, states %v", b, st)
	}
	script := fmt.Sprint(b["script"])
	if !strings.Contains(script, "\n"+wantLine+"\n") || !strings.HasPrefix(script, "-- pgvigil: the rights its monitoring login "+role+" lacks on ") ||
		!strings.Contains(script, "pgvigil did not run it and never does.") {
		t.Errorf("the script lacks %q or its head:\n%s", wantLine, script)
	}
	// the read wrote nothing on the server: the role is in no other role yet
	var member bool
	if err := pool.QueryRow(ctx, `SELECT pg_has_role($1, 'pg_monitor', 'USAGE')`, role).Scan(&member); err != nil || member {
		t.Errorf("after the read the role holds pg_monitor: %v (%v)", member, err)
	}
	// the printed line, run as it is printed by an administrator: the next read holds it
	if _, err := pool.Exec(ctx, wantLine); err != nil {
		t.Fatalf("the printed line did not run: %v", err)
	}
	b, st = read(nomon)
	if st["pg_monitor"] != "held" || fmt.Sprint(b["missing_needed"]) != "0" || strings.Contains(fmt.Sprint(b["script"]), "GRANT pg_monitor") {
		t.Errorf("after the printed GRANT: %v, states %v", b, st)
	}

	// not read: an unreachable server and an unknown name say why
	if b, _ = read(dead); b["ok"] != false || fmt.Sprint(b["detail"]) == "" {
		t.Errorf("an unreachable instance: %v", b)
	}
	if b, _ = read("rights-nobody"); b["ok"] != false || !strings.Contains(fmt.Sprint(b["detail"]), `no instance "rights-nobody"`) {
		t.Errorf("an unknown instance: %v", b)
	}
	// every click audited: three reads that worked, two that did not
	var done, notRead int
	if err := pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE detail LIKE 'read: %'), count(*) FILTER (WHERE detail LIKE 'not read: %')
	                                FROM pgvigil.admin_audit WHERE ui_user = $1 AND op = 'instance rights' AND outcome = 'done'`, user).Scan(&done, &notRead); err != nil || done != 3 || notRead != 2 {
		t.Errorf("the audit: %d read, %d not read (%v), want 3 and 2", done, notRead, err)
	}
}
