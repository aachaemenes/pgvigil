package web

// review-31 part B S8, the route's gates past the instance's read (written 11-17 07:2x; a box row:
// PGVIGIL_REPO_TEST_DSN, a migrated store): the body naming another instance (400), a page instance (403: actions run
// only on an instance of pgvigil.yaml) and the actions door's audit login unreachable (503) - each answered with its
// words and NO actions_log row. NOT a row here: the upload's 408 (saveTableBudget is a 120 s constant: a test of it
// waits two minutes; proof-savetable.sh's F row holds the body's other limit) and the audit login without EXECUTE on
// import_save_table_log (a second login on the store; TestSaveTableAuditOnAStore holds the grant itself).

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestSaveTableGatesPastTheInstanceOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close) // registered first, so it runs after every cleanup below that uses it
	name := fmt.Sprintf("st-gates-%d", time.Now().UnixNano()%1000000000)
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], 'postgres')`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.actions_log WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(c, q, id); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	})
	logRows := func() int {
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.actions_log WHERE instance_id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	body := func(inst int) string {
		return fmt.Sprintf(`{"instance_id": %d, "database": "app", "table": "t", "from": "grid", "confirm": "%s/app", "cols": [{"name": "a", "type": "int"}], "rows": [[1]]}`, inst, name)
	}
	// the actions door's audit pool at a port nothing listens on: its Ping fails at once
	down, err := pgxpool.New(ctx, "host=127.0.0.1 port=1 user=nobody dbname=nothing connect_timeout=2")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(down.Close)
	// a serve whose door set holds this one door for the instance (doorsNow: the set stored for the server)
	serve := func(door actions.Door) *Server {
		s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil)), actions: &Actions{audit: down}}
		s.EnableSaveTable(true)
		p := &atomic.Pointer[doorSet]{}
		p.Store(&doorSet{PG: map[string]actions.Door{name: door}})
		doorSets.Store(s.self(), p)
		t.Cleanup(func() { saveTables.Delete(s.self()); doorSets.Delete(s.self()) })
		return s
	}
	post := func(s *Server, b string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, fmt.Sprintf("/api/actions/save_table?instance_id=%d", id), strings.NewReader(b))
		w := httptest.NewRecorder()
		s.SaveTable(w, withWho(r, who{user: "admin1", role: "admin"}))
		return w
	}
	check := func(what string, w *httptest.ResponseRecorder, code int, words string) {
		t.Helper()
		if w.Code != code || !strings.Contains(w.Body.String(), words) {
			t.Errorf("%s: %d %s, want %d holding %q", what, w.Code, w.Body.String(), code, words)
		}
		if n := logRows(); n != 0 {
			t.Errorf("%s: %d actions_log row(s) for the instance, want none", what, n)
		}
	}
	on := actions.Door{Actions: "host=127.0.0.1 port=1", Configured: true, Allow: []string{"save_table"}}
	check("the body names another instance", post(serve(on), body(id+1)), http.StatusBadRequest, "the body names instance")
	check("a page instance", post(serve(actions.Door{Page: true, Allow: []string{"save_table"}}), body(id)), http.StatusForbidden, "was added in Admin > Instances")
	check("the audit door down", post(serve(on), body(id)), http.StatusServiceUnavailable, "the actions log cannot be written")
}
