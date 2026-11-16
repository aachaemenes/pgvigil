package web

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The storage depth API's parameters (task 407): each bad one is a 400 naming it, before any database read. The
// handlers are called directly: their routes are the join's wiring in web.go.
func TestStorageDepthBadParameters(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	for _, c := range []struct {
		h    func(http.ResponseWriter, *http.Request)
		path string
		want string
	}{
		{s.MSSQLStorageDepth, "/api/mssql/storage_depth", "instance must be"},
		{s.MSSQLStorageDepth, "/api/mssql/storage_depth?instance=1&days=8", "days must be one of"},
		{s.MSSQLStorageDepth, "/api/mssql/storage_depth?instance=1&parts=space,nope", "parts must name some of"},
		{s.MSSQLStorageDepth, "/api/mssql/storage_depth?instance=1&parts=tables", "parts must name some of"}, // tables needs db=
		{s.MSSQLStorageDepth, "/api/mssql/storage_depth?instance=1&part=nope", "part must be one of"},
		{s.MSSQLDBIO, "/api/mssql/dbio", "instance must be"},
		{s.MSSQLDBIO, "/api/mssql/dbio?instance=1&by=x", "by must be database or volume"},
		{s.MSSQLDBIO, "/api/mssql/dbio?instance=1&compare=2d", "compare must be 1d or 7d"},
		{s.MSSQLDBIO, "/api/mssql/dbio?instance=1&top=0", "top must be 1 to 50"},
		{s.MSSQLDBIO, "/api/mssql/dbio?instance=1&top=51", "top must be 1 to 50"},
	} {
		w := httptest.NewRecorder()
		c.h(w, httptest.NewRequest(http.MethodGet, c.path, nil))
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), c.want) {
			t.Errorf("%s: %d %q, want 400 with %q", c.path, w.Code, w.Body.String(), c.want)
		}
	}
}

// compareIO keeps now's order, joins the window before by name, and appends the names only before had, by name;
// firstNames takes the grid's first n names.
func TestCompareIOAndFirstNames(t *testing.T) {
	now := &table{Columns: []string{"name", "mb_s", "reads"}, Rows: [][]any{{"b", 2.0, int64(20)}, {"a", 1.0, int64(10)}}}
	before := &table{Columns: []string{"name", "mb_s", "reads"}, Rows: [][]any{{"a", 0.5, int64(5)}, {"z", 0.1, int64(1)}, {"c", 0.2, int64(2)}}}
	got := compareIO(now, before)
	if len(got.Rows) != 4 {
		t.Fatalf("rows: %v", got.Rows)
	}
	name, mb, mbBefore, reads, readsBefore := tableColIndex(got, "name"), tableColIndex(got, "mb_s"), tableColIndex(got, "mb_s_before"), tableColIndex(got, "reads"), tableColIndex(got, "reads_before")
	order := []string{}
	for _, r := range got.Rows {
		order = append(order, r[name].(string))
	}
	if strings.Join(order, ",") != "b,a,c,z" {
		t.Errorf("order: %v", order)
	}
	if got.Rows[0][mbBefore] != nil || got.Rows[1][mb] != 1.0 || got.Rows[1][mbBefore] != 0.5 || got.Rows[1][readsBefore] != int64(5) {
		t.Errorf("joined: %v", got.Rows[:2])
	}
	if got.Rows[2][mb] != nil || got.Rows[2][reads] != nil || got.Rows[2][readsBefore] != int64(2) {
		t.Errorf("a name only before: %v", got.Rows[2])
	}
	if n := firstNames(now, 1); len(n) != 1 || n[0] != "b" {
		t.Errorf("firstNames: %v", n)
	}
	if n := firstNames(&table{Columns: []string{"x"}}, 3); len(n) != 0 {
		t.Errorf("no name column: %v", n)
	}
}
