package web

import (
	"encoding/json"
	"testing"
)

// TestMarkCards: a result set of exactly InsightSeverity + Insight (any case, either order) carries its cards in row
// order - an unknown or NULL severity Info, a NULL or blank insight left out, the text as stored; a set with no rows
// carries [] and any other set no cards key (B20-3, proof-customreports part I on a real run)
func TestMarkCards(t *testing.T) {
	cases := []struct {
		name string
		set  resultSet
		want string
	}{
		{"unquoted aliases", resultSet{Columns: []string{"insightseverity", "insight"}, Rows: [][]any{
			{"Warning", "disk [D:](https://example.test/d) at 91%"}, {"critical", "a [bad](javascript:alert(1)) link"},
			{"Shouty", "unknown severity"}, {"Info", "  "}, {[]byte("INFO"), []byte("bytes")}, {nil, "no severity"}, {"Warning", nil}}},
			`[{"severity":"Warning","insight":"disk [D:](https://example.test/d) at 91%"},{"severity":"Critical","insight":"a [bad](javascript:alert(1)) link"},{"severity":"Info","insight":"unknown severity"},{"severity":"Info","insight":"bytes"},{"severity":"Info","insight":"no severity"}]`},
		{"quoted, the other order", resultSet{Columns: []string{"Insight", "InsightSeverity"}, Rows: [][]any{{"x", "WARNING"}}},
			`[{"severity":"Warning","insight":"x"}]`},
		{"no rows", resultSet{Columns: []string{"InsightSeverity", "Insight"}}, `[]`},
		{"a third column", resultSet{Columns: []string{"InsightSeverity", "Insight", "n"}, Rows: [][]any{{"Warning", "x", 1}}}, `none`},
		{"another pair", resultSet{Columns: []string{"severity", "insight"}, Rows: [][]any{{"Warning", "x"}}}, `none`},
	}
	for _, c := range cases {
		c.set.markCards()
		got := "none"
		if c.set.Cards != nil {
			b, _ := json.Marshal(*c.set.Cards)
			got = string(b)
		}
		if got != c.want {
			t.Errorf("%s: cards %s, want %s", c.name, got, c.want)
		}
	}
	// the key in the answer: absent for a grid, [] for an empty card set
	g := resultSet{Columns: []string{"a"}, Rows: [][]any{{1}}}
	g.markCards()
	e := resultSet{Columns: []string{"InsightSeverity", "Insight"}, Rows: [][]any{}}
	e.markCards()
	bg, _ := json.Marshal(g)
	be, _ := json.Marshal(e)
	if string(bg) != `{"columns":["a"],"types":null,"rows":[[1]]}` || string(be) != `{"columns":["InsightSeverity","Insight"],"types":null,"rows":[],"cards":[]}` {
		t.Errorf("the answer's key: a grid %s, an empty card set %s", bg, be)
	}
}
