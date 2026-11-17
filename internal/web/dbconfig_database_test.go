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
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestDBConfigurationByDatabaseOnAStore (P25 row 2a, DBA Dash's database DB Configuration): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/mssql/checks?instance=N&db=<name> gives that database's scoped
// configuration (part=scoped_config: name, value, value for secondaries, default, note) and its changes
// (part=scoped_changes, the newest first); another database's rows are not in either.
func TestDBConfigurationByDatabaseOnAStore(t *testing.T) {
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
		fmt.Sprintf("dbconfig-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	t1, t2 := time.Now().UTC().Add(-2*time.Hour), time.Now().UTC().Add(-time.Hour)
	for _, c := range []struct {
		at time.Time
		p  string
	}{
		{t1, `[{"kind": "scoped_config", "database_name": "sales", "name": "MAXDOP", "value": "0", "is_value_default": true},
		       {"kind": "scoped_config", "database_name": "hr", "name": "MAXDOP", "value": "4", "is_value_default": false}]`},
		{t2, `[{"kind": "scoped_config", "database_name": "sales", "name": "MAXDOP", "value": "8", "is_value_default": false},
		       {"kind": "scoped_config", "database_name": "hr", "name": "MAXDOP", "value": "2", "is_value_default": false}]`},
	} {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_db_scoped_config($1, $2, $3::jsonb)`, id, c.at, c.p); err != nil {
			t.Fatal(err)
		}
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	part := func(name, db string) []map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		s.MSSQLChecks(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/checks?instance="+fmt.Sprint(id)+"&part="+name+"&db="+db, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s %s: %d %s", name, db, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[name]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out = append(out, m)
			}
		}
		return out
	}
	cfg := part("scoped_config", "sales")
	if len(cfg) != 1 || cfg[0]["name"] != "MAXDOP" || cfg[0]["value"] != "8" || cfg[0]["is_default"] != false {
		t.Errorf("db=sales scoped_config %v, want MAXDOP 8, not the default (sales' alone)", cfg)
	}
	ch := part("scoped_changes", "sales")
	if len(ch) != 1 || ch[0]["old_value"] != "0" || ch[0]["new_value"] != "8" {
		t.Errorf("db=sales scoped_changes %v, want one change 0 -> 8 (hr's 4 -> 2 not here)", ch)
	}
}
