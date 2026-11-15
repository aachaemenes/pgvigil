package export

import (
	"encoding/csv"
	"os"
	"sort"
	"strings"
	"testing"
)

// The map's own shape: name order, one line per table, every class with what it needs.
func TestCatalogShape(t *testing.T) {
	c := Catalog()
	if !sort.SliceIsSorted(c, func(i, j int) bool { return c[i].Name < c[j].Name }) {
		t.Error("the map is not in name order")
	}
	seen := map[string]bool{}
	for _, x := range c {
		if seen[x.Name] {
			t.Errorf("%s is named twice", x.Name)
		}
		seen[x.Name] = true
		switch x.Class {
		case Window, Dimension:
			if x.Time == "" {
				t.Errorf("%s: a %s table needs its time column", x.Name, x.Class)
			}
		case State:
			if x.Time != "" {
				t.Errorf("%s: a state table has no time column (%s)", x.Name, x.Time)
			}
		case LeftOut:
			if x.Why == "" || x.Carry != "" || len(x.Text) > 0 || len(x.Drop) > 0 {
				t.Errorf("%s: a left-out table has its reason and nothing else", x.Name)
			}
		default:
			t.Errorf("%s: class %q", x.Name, x.Class)
		}
		if x.Carry != "" && x.Carry != CarryText && x.Carry != CarryAudit {
			t.Errorf("%s: carry %q", x.Name, x.Carry)
		}
		if x.Carry == CarryText && len(x.Text) > 0 {
			t.Errorf("%s: a table that leaves only with the text carry names no text column of its own", x.Name)
		}
		cols := map[string]bool{}
		for _, col := range x.Text {
			cols[col] = true
		}
		for _, d := range x.Drop {
			if cols[d.Column] || d.Reason == "" {
				t.Errorf("%s.%s: dropped twice or without a reason", x.Name, d.Column)
			}
		}
		if strings.HasPrefix(x.Name, "ui_") && x.Class != LeftOut {
			t.Errorf("%s: a ui_ table is never exported", x.Name)
		}
	}
}

// The map against the census the proof holds it to (scripts/proof-parquet-census.tsv): the same tables, each with
// the same class, time column, carry, text columns and dropped columns. The census was read from how each import
// writes its table; a line changed here without it there, or there without it here, fails.
func TestCatalogEqualsTheCensus(t *testing.T) {
	f, err := os.Open("../../scripts/proof-parquet-census.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.Comma, r.LazyQuotes = '\t', true
	lines, err := r.ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{}
	for _, l := range lines[1:] {
		want[l[0]] = l[1:]
	}
	got := map[string][]string{}
	for _, x := range Catalog() {
		var drop []string
		for _, d := range x.Drop {
			drop = append(drop, d.Column)
		}
		got[x.Name] = []string{string(x.Class), x.Time, x.Carry, strings.Join(x.Text, ","), strings.Join(drop, ",")}
	}
	for name, w := range want {
		g, ok := got[name]
		if !ok {
			t.Errorf("%s: in the census, not in the map", name)
			continue
		}
		if strings.Join(g, "|") != strings.Join(w, "|") {
			t.Errorf("%s: the map %v, the census %v", name, g, w)
		}
	}
	for name := range got {
		if _, ok := want[name]; !ok {
			t.Errorf("%s: in the map, not in the census", name)
		}
	}
}
