package export

import (
	"encoding/csv"
	"errors"
	"os"
	"path/filepath"
	"regexp"
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
		if x.AuditRows != "" && x.Class != Window {
			t.Errorf("%s: audit rows are of a window table", x.Name)
		}
		if x.Carry == CarryAudit && (len(x.Audit) > 0 || x.AuditRows != "") {
			t.Errorf("%s: a table that leaves only with the audit carry names no audit column or row of its own", x.Name)
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
	defer func() { _ = f.Close() }()
	r := csv.NewReader(f)
	r.Comma, r.LazyQuotes = '\t', true
	lines, err := r.ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{}
	strs := map[string]map[string]bool{} // every text, JSON and bytes column the census pins for an exported table
	for _, l := range lines[1:] {
		want[l[0]] = l[1:8]
		strs[l[0]] = map[string]bool{}
		for _, c := range strings.Split(l[8], ",") {
			strs[l[0]][c] = true
		}
	}
	// a column the map names is one the census pins: a text or audit list cannot name a column that is not there
	for _, x := range Catalog() {
		named := append(append([]string{}, x.Text...), x.Audit...)
		for _, c := range named {
			if x.Class != LeftOut && !strs[x.Name][c] {
				t.Errorf("%s.%s is on a list of the map and is no text, JSON or bytes column of the census", x.Name, c)
			}
		}
	}
	got := map[string][]string{}
	for _, x := range Catalog() {
		var drop []string
		for _, d := range x.Drop {
			drop = append(drop, d.Column)
		}
		got[x.Name] = []string{string(x.Class), x.Time, x.Carry, strings.Join(x.Text, ","), strings.Join(drop, ","), strings.Join(x.Audit, ","), x.AuditRows}
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

// Every table the migrations create (the migrator's own in internal/repo/repo.go, then internal/repo/sql in file
// order: a later DROP TABLE takes it out, a RENAME TO follows it; a partition is never a table of its own) has its
// line in the map, and every line of the map is such a table. A slice that adds a table without classing it fails
// here, in its own unit run, before a repository with that table refuses every export.
func TestEveryMigrationTableIsClassed(t *testing.T) {
	files, err := filepath.Glob("../repo/sql/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(files)
	if len(files) < 100 {
		t.Fatalf("%d migrations read from ../repo/sql: the path is wrong", len(files))
	}
	files = append([]string{"../repo/repo.go"}, files...) // the migrator makes schema_version before the first migration
	var (
		comment = regexp.MustCompile(`--[^\n]*`)
		// a literal name only: pgvigil.%I or pgvigil.name_' || ... is a partition made at run time
		create = regexp.MustCompile(`(?i)\bcreate\s+(?:unlogged\s+)?table\s+(?:if\s+not\s+exists\s+)?pgvigil\.([a-z0-9_]+)(\s+partition\s+of)?[\s(]`)
		drop   = regexp.MustCompile(`(?i)\bdrop\s+table\s+(?:if\s+exists\s+)?(pgvigil\.[a-z0-9_]+(?:\s*,\s*pgvigil\.[a-z0-9_]+)*)[\s;]`)
		rename = regexp.MustCompile(`(?i)\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?pgvigil\.([a-z0-9_]+)\s+rename\s+to\s+(?:pgvigil\.)?([a-z0-9_]+)[\s;]`)
		named  = regexp.MustCompile(`(?i)pgvigil\.([a-z0-9_]+)`)
	)
	type event struct {
		at       int
		op, a, b string
	}
	made := map[string]string{} // table -> the migration that made it
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		s := comment.ReplaceAllString(string(b), "")
		var evs []event
		for _, m := range create.FindAllStringSubmatchIndex(s, -1) {
			if m[4] < 0 {
				evs = append(evs, event{m[0], "create", strings.ToLower(s[m[2]:m[3]]), ""})
			}
		}
		for _, m := range drop.FindAllStringSubmatchIndex(s, -1) {
			for _, n := range named.FindAllStringSubmatch(s[m[2]:m[3]], -1) {
				evs = append(evs, event{m[0], "drop", strings.ToLower(n[1]), ""})
			}
		}
		for _, m := range rename.FindAllStringSubmatchIndex(s, -1) {
			evs = append(evs, event{m[0], "rename", strings.ToLower(s[m[2]:m[3]]), strings.ToLower(s[m[4]:m[5]])})
		}
		sort.SliceStable(evs, func(i, j int) bool { return evs[i].at < evs[j].at })
		for _, e := range evs {
			switch e.op {
			case "create":
				made[e.a] = filepath.Base(f)
			case "drop":
				delete(made, e.a)
			case "rename":
				if from, ok := made[e.a]; ok {
					delete(made, e.a)
					made[e.b] = from
				}
			}
		}
	}
	if len(made) < 300 {
		t.Fatalf("%d tables read from the migrations: the reading is wrong", len(made))
	}
	inMap := map[string]bool{}
	for _, x := range Catalog() {
		inMap[x.Name] = true
	}
	var unclassed []string
	for name, from := range made {
		if !inMap[name] {
			unclassed = append(unclassed, name+" ("+from+")")
		}
	}
	sort.Strings(unclassed)
	for _, u := range unclassed {
		t.Errorf("%s is made by the migrations and has no class in the map (internal/export/catalog.go): class it from how its import writes it", u)
	}
	var stale []string
	for name := range inMap {
		if _, ok := made[name]; !ok {
			stale = append(stale, name)
		}
	}
	sort.Strings(stale)
	for _, s := range stale {
		t.Errorf("%s is in the map and no migration makes it (or one drops it): its line goes", s)
	}
}

// lay over a small store: what stops a run, what is dropped under each carry, what is skipped and why.
func TestLay(t *testing.T) {
	m := []Table{
		state("instances"), window("samples", "at"), window("runs", "started").audit("by"), state("hosts").text("cmd").drop("token", dropToken),
		dimension("texts", "seen").carry(CarryText), window("trail", "at").carry(CarryAudit).text("statement"), out("ui_users", whyUI),
		window("log", "at").text("line").auditRows("kind = 'auth'"),
	}
	ts := func(name string, notNull bool) Column {
		return Column{Name: name, Type: "timestamp with time zone", NotNull: notNull}
	}
	tx := func(name string) Column { return Column{Name: name, Type: "text"} }
	id := Column{Name: "instance_id", Type: "integer", NotNull: true}
	cols := map[string][]Column{
		"instances": {id, tx("name")}, "samples": {id, ts("at", true), tx("v")}, "runs": {{Name: "instance_id", Type: "integer"}, ts("started", false), tx("by")},
		"hosts": {id, tx("cmd"), tx("token"), tx("os")}, "texts": {tx("hash"), ts("seen", true), tx("body")},
		"trail": {id, ts("at", true), tx("statement"), tx("who")}, "ui_users": {tx("username")}, "log": {id, ts("at", true), tx("kind"), tx("line")},
	}
	var store []storeTable
	for _, x := range m {
		size := int64(1000)
		if x.Name == "hosts" || x.Name == "texts" || x.Name == "instances" {
			size = 5000
		}
		store = append(store, storeTable{Name: x.Name, Bytes: size})
	}
	get := func(rs []Resolved, name string) Resolved {
		for _, r := range rs {
			if r.Name == name {
				return r
			}
		}
		t.Fatalf("no %s", name)
		return Resolved{}
	}
	names := func(cs []Column) string {
		var s []string
		for _, c := range cs {
			s = append(s, c.Name)
		}
		return strings.Join(s, ",")
	}
	rs, err := lay(m, store, cols, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if r := get(rs, "samples"); !r.HasInstance || r.TimeNullable || r.Skip != "" || names(r.Columns) != "instance_id,at,v" {
		t.Errorf("a plain window table: %+v", r)
	}
	if r := get(rs, "runs"); r.HasInstance || !r.TimeNullable || names(r.Columns) != "instance_id,started" || len(r.Dropped) != 1 || r.Dropped[0].Reason != dropAudit {
		t.Errorf("a nullable instance_id and time, an audit column dropped without the carry: %+v", r)
	}
	if r := get(rs, "hosts"); names(r.Columns) != "instance_id,os" || len(r.Dropped) != 2 {
		t.Errorf("a text column and a never-exported column dropped: %+v", r)
	}
	if r := get(rs, "log"); r.Filter != "kind = 'auth'" || names(r.Columns) != "instance_id,at,kind" {
		t.Errorf("audit rows left behind and text dropped without the carries: %+v", r)
	}
	for _, n := range []string{"texts", "trail", "ui_users"} {
		if r := get(rs, n); r.Skip == "" || r.Columns != nil {
			t.Errorf("%s is skipped without its carry (or left out): %+v", n, r)
		}
	}
	rs, err = lay(m, store, cols, Options{Carry: []string{CarryText, CarryAudit}, StateMaxBytes: 2000})
	if err != nil {
		t.Fatal(err)
	}
	if r := get(rs, "runs"); names(r.Columns) != "instance_id,started,by" {
		t.Errorf("with audit the column is carried: %+v", r)
	}
	if r := get(rs, "hosts"); !strings.Contains(r.Skip, "snapshot_max_bytes") {
		t.Errorf("a state table over the line is skipped: %+v", r)
	}
	if r := get(rs, "instances"); r.Skip != "" {
		t.Errorf("instances is carried whatever its size: %+v", r)
	}
	if r := get(rs, "texts"); r.Skip != "" || !r.NoWhole || !strings.Contains(r.Note, "snapshot_max_bytes") {
		t.Errorf("a dimension over the line keeps its hourly read: %+v", r)
	}
	if r := get(rs, "log"); r.Filter != "" || names(r.Columns) != "instance_id,at,kind,line" {
		t.Errorf("with both carries nothing of the log is left behind: %+v", r)
	}
	if r := get(rs, "trail"); names(r.Columns) != "instance_id,at,statement,who" {
		t.Errorf("an audit table with both carries: %+v", r)
	}
	rs, _ = lay(m, store, cols, Options{Carry: []string{CarryAudit}})
	if r := get(rs, "trail"); names(r.Columns) != "instance_id,at,who" || len(r.Dropped) != 1 || r.Dropped[0].Reason != dropText {
		t.Errorf("an audit table under the audit carry alone leaves without its statement: %+v", r)
	}
	for what, c := range map[string]struct {
		store []storeTable
		cols  map[string][]Column
		opt   Options
		word  string
		code  int
	}{
		"a table the map does not name":         {append(append([]storeTable{}, store...), storeTable{Name: "newcomer"}), cols, Options{}, "newcomer is not classed", 0},
		"an excluded name that is no table":     {store, cols, Options{Exclude: []string{"no_such_table"}}, "no_such_table", 3},
		"instances excluded":                    {store, cols, Options{Exclude: []string{"instances"}}, "instances", 3},
		"a text column the table does not have": {store, map[string][]Column{"instances": cols["instances"], "samples": cols["samples"], "runs": cols["runs"], "hosts": {id, tx("os"), tx("token")}, "texts": cols["texts"], "trail": cols["trail"], "ui_users": cols["ui_users"], "log": cols["log"]}, Options{}, "hosts has no column cmd", 0},
		"a time column that is not a time":      {store, map[string][]Column{"instances": cols["instances"], "samples": {id, tx("at")}, "runs": cols["runs"], "hosts": cols["hosts"], "texts": cols["texts"], "trail": cols["trail"], "ui_users": cols["ui_users"], "log": cols["log"]}, Options{}, "samples.at is text", 0},
	} {
		_, err := lay(m, c.store, c.cols, c.opt)
		if err == nil || !strings.Contains(err.Error(), c.word) {
			t.Errorf("%s: %v (want an error naming %q)", what, err, c.word)
			continue
		}
		var r *RefusedError
		if got := errors.As(err, &r); got != (c.code == 3) {
			t.Errorf("%s: a configuration refusal (exit 3) is %v, want %v", what, got, c.code == 3)
		}
	}
	if rs, err := lay(m, store[:2], cols, Options{}); err != nil || len(rs) != 2 {
		t.Errorf("a table of the map the repository lacks is left out: %d, %v", len(rs), err)
	}
}
