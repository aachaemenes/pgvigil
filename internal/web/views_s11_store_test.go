package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestViewWritesLogEveryRefusalOnAStore: the store is the one judge of a shared write and the one
// writer of ui_view_log - every write attempt that reaches it leaves one row, a refusal too. Below admin, a save that
// makes a view shared, an edit of the shared view, an edit that un-shares it and its delete are answered 403 in the role's words (B24f's text)
// AND leave exactly one 'forbidden' row each; an admin's shared save is done; a personal view's refusals keep the
// store's own words (S2b). A migrated store (PGVIGIL_REPO_TEST_DSN); users of its own, removed after.
func TestViewWritesLogEveryRefusalOnAStore(t *testing.T) {
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
	defer pool.Close()
	suf := fmt.Sprintf("%06d", rand.IntN(1000000))
	u1, u2 := "s11a"+suf, "s11v"+suf
	for _, u := range [][2]string{{u1, "admin"}, {u2, "viewer"}} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.ui_users (username, password_hash, role) VALUES ($1, '$argon2id$v=19$m=65536,t=1,p=1$c2FsdA$aGFzaA', $2)`, u[0], u[1]); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		c := context.Background()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.ui_views WHERE name LIKE '%'||$1`, suf)
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.ui_view_log WHERE ui_user IN ($1, $2)`, u1, u2)
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.ui_users WHERE username IN ($1, $2)`, u1, u2)
	}()
	s := &Server{pool: pool, auth: &authState{}, log: slog.New(slog.NewTextHandler(io.Discard, nil)), actions: &Actions{audit: pool}}
	call := func(user, role, path, body string) (int, map[string]any) {
		r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		r.Header.Set(loginHeader, "1")
		r = withWho(r, who{user: user, role: role})
		rec := httptest.NewRecorder()
		if strings.HasSuffix(path, "/delete") {
			s.ViewDelete(rec, r)
		} else {
			s.ViewSave(rec, r)
		}
		var d map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &d)
		return rec.Code, d
	}
	rows := func(user, op, outcome string) int {
		var n int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.ui_view_log WHERE ui_user = $1 AND op = $2 AND outcome = $3`, user, op, outcome).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	// the admin's shared 'team' and personal 'mine'
	code, d := call(u1, "admin", "/api/views", `{"kind":"page","page":"root:fleet","name":"team`+suf+`","shared":true,"state":{"params":{}}}`)
	if code != http.StatusOK || rows(u1, "create", "done") != 1 {
		t.Fatalf("the admin's shared save: %d %v, its done rows %d", code, d, rows(u1, "create", "done"))
	}
	team := fmt.Sprint(d["view_id"])
	code, d = call(u1, "admin", "/api/views", `{"kind":"page","page":"root:fleet","name":"mine`+suf+`","state":{"params":{}}}`)
	if code != http.StatusOK {
		t.Fatalf("the admin's personal save: %d %v", code, d)
	}
	mine := fmt.Sprint(d["view_id"])
	roleWords := "changing a shared view needs the admin role: " + u2 + " is a viewer"
	for _, c := range []struct{ what, path, body, op string }{
		{"u2's shared save", "/api/views", `{"kind":"page","page":"root:fleet","name":"u2shared` + suf + `","shared":true,"state":{"params":{}}}`, "create"},
		{"u2's edit of the shared view", "/api/views", `{"view_id":` + team + `,"version":1,"kind":"page","page":"root:fleet","name":"team` + suf + `","shared":true,"state":{"params":{"focus":"1"}}}`, "save"},
		// an edit that un-shares it: the body says personal, the stored view is shared (0259 import_view_save reads both)
		{"u2's un-sharing edit of the shared view", "/api/views", `{"view_id":` + team + `,"version":1,"kind":"page","page":"root:fleet","name":"team` + suf + `","shared":false,"state":{"params":{}}}`, "save"},
		{"u2's delete of the shared view", "/api/views/delete", `{"view_id":` + team + `,"version":1}`, "delete"},
	} {
		before := rows(u2, c.op, "forbidden")
		code, d := call(u2, "viewer", c.path, c.body)
		if code != http.StatusForbidden || !strings.HasPrefix(fmt.Sprint(d["error"]), roleWords) {
			t.Errorf("%s: %d %v, want 403 in the role's words (%q ...)", c.what, code, d, roleWords)
		}
		if got := rows(u2, c.op, "forbidden") - before; got != 1 {
			t.Errorf("%s: %d new ui_view_log row(s) op %s outcome forbidden, want exactly 1 (every attempt that reaches the store)", c.what, got, c.op)
		}
	}
	// S2b: a personal view's refusals stay the store's, in its own words, each logged
	before := rows(u2, "delete", "forbidden")
	code, d = call(u2, "viewer", "/api/views/delete", `{"view_id":`+mine+`,"version":1}`)
	if code != http.StatusForbidden || !strings.Contains(fmt.Sprint(d["error"]), "only its owner") || rows(u2, "delete", "forbidden")-before != 1 {
		t.Errorf("u2's delete of the admin's personal view: %d %v, want 403 'only its owner ...' and one row", code, d)
	}
	var shared bool
	if err := pool.QueryRow(ctx, `SELECT shared FROM pgvigil.ui_views WHERE view_id::text = $1`, team).Scan(&shared); err != nil || !shared {
		t.Errorf("the shared view after the refusals: shared %v, %v (want it unchanged)", shared, err)
	}
}
