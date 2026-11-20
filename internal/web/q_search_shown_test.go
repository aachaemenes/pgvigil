package web

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestSearchShown (TEXT-NOW-L row 3): the statement search matches the stored text (an ILIKE in the repository), but
// an instance read as normalized shows its statements normalized (TEXT-NOW's stmt rule at the reply): a row of such an
// instance whose shown text does not hold the searched text - a match on a literal of the stored full text - is
// dropped, so the search reveals nothing the page would not show; a match outside the literals stays (case-insensitive,
// as ILIKE); an instance read as full keeps every row; a row with no statement or no instance id is dropped under
// normalized only when its instance is one.
func TestSearchShown(t *testing.T) {
	const stmt = "SELECT COUNT(*) FROM dbo.t t1 WHERE t1.a > 4990 AND t1.pad <> 'pgvf_marker%_x';"
	if n := collect.NormalizeSQL(stmt); n == stmt || len(n) == 0 {
		t.Fatalf("the normalizer left the statement as it was: %q", n)
	}
	mk := func() *table {
		return &table{Columns: []string{"source", "instance_id", "instance", "statement"}, Rows: [][]any{
			{"plan cache", int32(1), "sqlnorm", stmt},
			{"Query Store", int64(1), "sqlnorm", stmt},
			{"plan cache", int32(2), "sqlfull", stmt},
		}}
	}
	norm := map[int]bool{1: true}
	for _, c := range []struct {
		name, text string
		keep       []string // the instances whose rows stay, in order
		dropped    int
	}{
		{"a literal of the stored text", "marker%_x", []string{"sqlfull"}, 2},
		{"outside the literals", "t1.pad", []string{"sqlnorm", "sqlnorm", "sqlfull"}, 0},
		{"outside the literals, another case", "T1.PAD <>", []string{"sqlnorm", "sqlnorm", "sqlfull"}, 0},
	} {
		tb := mk()
		got := searchShown(tb, c.text, norm)
		var keep []string
		for _, r := range tb.Rows {
			keep = append(keep, r[2].(string))
		}
		if got != c.dropped || len(keep) != len(c.keep) {
			t.Errorf("%s: dropped %d, kept %v; want dropped %d, kept %v", c.name, got, keep, c.dropped, c.keep)
			continue
		}
		for i := range keep {
			if keep[i] != c.keep[i] {
				t.Errorf("%s: kept %v, want %v", c.name, keep, c.keep)
				break
			}
		}
	}
	if tb := mk(); searchShown(tb, "marker%_x", nil) != 0 || len(tb.Rows) != 3 {
		t.Errorf("no instance read as normalized: a row was dropped")
	}
}
