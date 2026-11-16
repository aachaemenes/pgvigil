package remote

import (
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
)

type counterEntry struct {
	Object  string   `json:"object"`
	Counter string   `json:"counter"`
	Inst    string   `json:"inst"`
	Scope   string   `json:"scope"`
	Kind    string   `json:"kind"`
	Except  []string `json:"except,omitempty"`
}

// canonCounters reads a counter list as a set: sorted by object, counter and inst, each except list sorted (the SQL
// orders both by the store's collation; the collector reads them as sets).
func canonCounters(t *testing.T, b []byte) []counterEntry {
	t.Helper()
	var l []counterEntry
	if err := json.Unmarshal(b, &l); err != nil {
		t.Fatalf("a counter list that is no JSON list: %v: %s", err, b)
	}
	for i := range l {
		sort.Strings(l[i].Except)
	}
	sort.Slice(l, func(i, j int) bool {
		if l[i].Object != l[j].Object {
			return l[i].Object < l[j].Object
		}
		if l[i].Counter != l[j].Counter {
			return l[i].Counter < l[j].Counter
		}
		return l[i].Inst < l[j].Inst
	})
	return l
}

func findCounter(l []counterEntry, object, counter, inst string) (counterEntry, bool) {
	for _, e := range l {
		if e.Object == object && e.Counter == counter && e.Inst == inst {
			return e, true
		}
	}
	return counterEntry{}, false
}

// The settings answer with no Admin rows (import_mssql_security_parts over mssql_security_settings' defaults, 0159: the
// parts with a rule on by default, auth always)
// and the counter list with no Admin rows (mssql_counter_list over the defaults and the yaml's root and instance lines,
// 0152): the yaml's narrowest layer wins per object, counter and instance; a remove of a counter a page reads is
// blocked; a remove of one instance of an every-instance counter is its 'except'; an add without a kind takes the kind
// of the layer below.
func TestStoreAnswers(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestStore(t, t.TempDir(), t.TempDir(), &clock{t: t0})
	id, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)
	b, err := s.MSSQLSettings(ctx, id, "import_mssql_security_parts")
	var parts map[string]map[string]bool
	want := map[string]bool{"auth": true, "databases": true, "logins": true, "proxies": false, "registry": false, "server_perms": false}
	if err != nil || json.Unmarshal(b, &parts) != nil || !reflect.DeepEqual(parts["parts"], want) {
		t.Errorf("security parts: %s %v", b, err)
	}
	if _, err := s.MSSQLSettings(ctx, id, "import_mssql_other_parts"); err == nil || !strings.Contains(err.Error(), "no remote answer") {
		t.Errorf("an unknown settings function: %v", err)
	}
	b, err = s.MSSQLCounterList(ctx, id, nil)
	if err != nil {
		t.Fatal(err)
	}
	def := canonCounters(t, b)
	if len(def) != len(counterDefaults) {
		t.Errorf("the defaults alone: %d entries, %d defaults", len(def), len(counterDefaults))
	}
	if e, ok := findCounter(def, "Databases", "Log Bytes Flushed/sec", ""); !ok || e.Scope != "database" {
		t.Errorf("a Databases counter's scope: %+v %v", e, ok)
	}
	yaml := `[{"object": "Locks", "counter": "Lock Waits/sec", "action": "remove", "layer": "root"},
	          {"object": "Access Methods", "counter": "Forwarded Records/sec", "action": "remove", "layer": "root"},
	          {"object": "Access Methods", "counter": "Forwarded Records/sec", "action": "add", "layer": "instance"},
	          {"object": " Memory Manager ", "counter": "Free Memory (KB)", "action": "add", "kind": "gauge", "layer": "root"},
	          {"object": "Buffer Manager", "counter": "Page reads/sec", "inst": "x", "action": "remove", "layer": "root"},
	          {"object": "Buffer Manager", "counter": "Page reads/sec", "action": "remove", "layer": "root", "kind": "bogus"},
	          {"object": "", "counter": "y", "action": "add", "layer": "root"},
	          {"object": "z", "counter": "y", "action": "add", "layer": "fleet"}]`
	b, err = s.MSSQLCounterList(ctx, id, []byte(yaml))
	if err != nil {
		t.Fatal(err)
	}
	l := canonCounters(t, b)
	if _, ok := findCounter(l, "Locks", "Lock Waits/sec", ""); !ok {
		t.Errorf("a counter a page reads was removed (the remove is blocked)")
	}
	if _, ok := findCounter(l, "Access Methods", "Forwarded Records/sec", ""); !ok {
		t.Errorf("the instance layer's add over the root's remove")
	}
	if e, ok := findCounter(l, "Memory Manager", "Free Memory (KB)", ""); !ok || e.Kind != "gauge" {
		t.Errorf("a trimmed yaml add with its kind: %+v %v", e, ok)
	}
	if _, ok := findCounter(l, "z", "y", ""); ok {
		t.Errorf("a layer that is not root or instance was taken")
	}
	if len(l) != len(def) {
		t.Errorf("entries: %d, want the defaults' %d (Free Memory (KB) is a default: the yaml changes its kind)", len(l), len(def))
	}
	if pid, _ := s.EnsureInstanceEngine(ctx, "postgres", "pg1", "onprem", "18.1", 180001, false, nil); true {
		if _, err := s.MSSQLCounterList(ctx, pid, nil); err == nil {
			t.Errorf("a PostgreSQL instance's counter list: no error")
		}
	}
	b, _ = s.MSSQLCounterList(ctx, id, []byte(`[{"object": "Access Methods", "counter": "Table Lock Escalations/sec", "inst": "_Total", "action": "remove", "layer": "root"},
	   {"object": "Access Methods", "counter": "Full Scans/sec", "inst": "_Total", "action": "remove", "layer": "root"},
	   {"object": "SQLServer:Wait Statistics", "counter": "Lock waits", "inst": "Average wait time (ms)", "action": "add", "layer": "root"},
	   {"object": "Access Methods", "counter": "Forwarded Records/sec", "action": "add", "layer": "instance"}]`))
	l = canonCounters(t, b)
	if e, _ := findCounter(l, "Access Methods", "Table Lock Escalations/sec", ""); len(e.Except) != 1 || e.Except[0] != "_Total" {
		t.Errorf("an instance removed from an every-instance counter: %+v", e)
	}
	if e, _ := findCounter(l, "Access Methods", "Full Scans/sec", ""); len(e.Except) != 0 {
		t.Errorf("a blocked remove (a page reads the counter) made an except: %+v", e)
	}
	if e, _ := findCounter(l, "Access Methods", "Forwarded Records/sec", ""); e.Kind != "" {
		t.Errorf("an add without a kind over a default without one: %+v", e)
	}
	if e, ok := findCounter(l, "SQLServer:Wait Statistics", "Lock waits", "Average wait time (ms)"); !ok || e.Scope != "instance" {
		t.Errorf("an added instance of a counter: %+v %v", e, ok)
	}
}

// Every settings function a SQL Server collector names (SettingsFunc) has a remote answer: a new one without it is
// refused on a remote site in words, and this row turns red first.
func TestSettingsFuncsAnswered(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, "../mssql", func(fi os.FileInfo) bool { return !strings.HasSuffix(fi.Name(), "_test.go") }, 0)
	if err != nil {
		t.Fatal(err)
	}
	var fns []string
	for _, p := range pkgs {
		for _, f := range p.Files {
			for _, d := range f.Decls {
				fd, ok := d.(*ast.FuncDecl)
				if !ok || fd.Name.Name != "SettingsFunc" || fd.Body == nil || len(fd.Body.List) != 1 {
					continue
				}
				if ret, ok := fd.Body.List[0].(*ast.ReturnStmt); ok && len(ret.Results) == 1 {
					if lit, ok := ret.Results[0].(*ast.BasicLit); ok {
						v, _ := strconv.Unquote(lit.Value)
						fns = append(fns, v)
						continue
					}
				}
				t.Errorf("%s: a SettingsFunc that is not one string", fset.Position(fd.Pos()))
			}
		}
	}
	if len(fns) == 0 {
		t.Fatal("no SettingsFunc found: the scan reads nothing")
	}
	for _, fn := range fns {
		if _, ok := settingsAnswers[fn]; !ok {
			t.Errorf("settings function %s has no remote answer (answers.go settingsAnswers)", fn)
		}
	}
}
