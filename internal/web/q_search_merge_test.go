package web

import (
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestKeepShownLong: a normalized instance's statement is matched on its WHOLE stored text,
// normalized, and only then cut to the 400 characters the reply shows: a match outside the literals past character
// 400 is kept; a match only inside a literal is dropped wherever it stands.
func TestKeepShownLong(t *testing.T) {
	stmt := "SELECT " + strings.Repeat("t1.a AS c, ", 50) + "t1.id AS pgvf_tail_col FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a > 4995 AND t2.pad <> 'pgvf_long_x';"
	mk := func() *table {
		return &table{Columns: []string{"source", "instance_id", "instance", "statement"},
			Rows: [][]any{{"plan cache", int32(1), "sqlnorm", stmt}, {"plan cache", int32(2), "sqlfull", stmt}}}
	}
	norm := map[int]bool{1: true}
	tb := mk()
	if n := keepShown(tb, "pgvf_tail_col", norm, 400); n != 0 || len(tb.Rows) != 2 {
		t.Fatalf("a match past character 400, outside the literals: dropped %d, kept %d rows; want 0 / 2", n, len(tb.Rows))
	}
	for _, r := range tb.Rows {
		if s, _ := r[3].(string); s != string([]rune(stmt)[:400]) {
			t.Errorf("%v: the statement is not cut to its first 400 characters after the match: %d characters", r[2], len([]rune(s)))
		}
	}
	tb = mk()
	if n := keepShown(tb, "pgvf_long_x", norm, 400); n != 1 || len(tb.Rows) != 1 || tb.Rows[0][2] != "sqlfull" {
		t.Errorf("a match only inside a literal: dropped %d, kept %v; want sqlnorm's row dropped", n, tb.Rows)
	}
}

// TestMergeSearch: the full instances' rows (read by the function, its LIMIT over them alone)
// and the normalized instances' kept rows (read apart, filtered before any cut) merge, full rows first, cut at the
// page's 200 with a note that counts shown rows only; columns that differ are a fault, not a silent merge.
func TestMergeSearch(t *testing.T) {
	cols := []string{"instance_id", "instance", "statement"}
	rows := func(id int32, name string, n int) [][]any {
		out := [][]any{}
		for i := 0; i < n; i++ {
			out = append(out, []any{id, name, fmt.Sprintf("SELECT %d", i)})
		}
		return out
	}
	got, note, err := mergeSearch(&table{Columns: cols, Rows: rows(2, "f2", 150)}, &table{Columns: cols, Rows: rows(1, "sqlnorm", 100)}, 200)
	if err != nil || got == nil || len(got.Rows) != 200 || got.Rows[149][1] != "f2" || got.Rows[150][1] != "sqlnorm" || !strings.Contains(note, "200") {
		n := -1
		if got != nil {
			n = len(got.Rows)
		}
		t.Errorf("150 full + 100 normalized: %d rows, note %q, err %v; want 200 (f2's 150 first) and a note naming the cut", n, note, err)
	}
	got, note, err = mergeSearch(&table{Columns: cols, Rows: rows(2, "f2", 60)}, &table{Columns: cols, Rows: [][]any{}}, 200)
	if err != nil || len(got.Rows) != 60 || note != "" {
		t.Errorf("60 full + none kept: %d rows, note %q, err %v; want every f2 row, no note", len(got.Rows), note, err)
	}
	if _, _, err = mergeSearch(&table{Columns: cols, Rows: rows(2, "f2", 1)}, &table{Columns: []string{"instance_id", "statement"}, Rows: rows(1, "x", 1)}, 200); err == nil {
		t.Errorf("columns that differ merged without an error")
	}
}

// TestSearchShownMissingColumn: a search table without its statement or instance_id
// column while an instance is read as normalized cannot be judged row by row: every row is dropped (fails closed).
func TestSearchShownMissingColumn(t *testing.T) {
	for _, cols := range [][]string{{"instance_id", "text"}, {"inst", "statement"}} {
		tb := &table{Columns: cols, Rows: [][]any{{int32(1), "SELECT 1"}, {int32(2), "SELECT 2"}}}
		if n := searchShown(tb, "select", map[int]bool{1: true}); n != 2 || len(tb.Rows) != 0 {
			t.Errorf("columns %v: dropped %d, kept %v; want every row dropped", cols, n, tb.Rows)
		}
	}
}

// TestDoorsPinned: a handler's door set pinned on its request is the one the reply's rule reads.
func TestDoorsPinned(t *testing.T) {
	r := httptest.NewRequest("GET", "/api/mssql/search?q=x", nil)
	if doorsPinned(r) != nil {
		t.Fatalf("a request with no pin gave a door set")
	}
	ds := &doorSet{}
	if got := doorsPinned(pinDoors(r, ds)); got != ds {
		t.Errorf("the pinned door set is not the one read back: %p, want %p", got, ds)
	}
}
