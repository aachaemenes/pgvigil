package web

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// remoteSet: a door set holding two remote instances of site site1 (collector c1) - one PostgreSQL, one SQL Server -
// beside one pgvigil.yaml instance 'f'; every switch a live door asks is on for them, so only the remote words can
// stop it.
func remoteSet() (*doorSet, remoteDoor) {
	r := remoteDoor{Site: "site1", Collector: "c1", AsOf: time.Date(2026, 11, 16, 17, 55, 0, 0, time.UTC), Every: 5 * time.Minute, ExpectedEvery: time.Hour}
	ds := &doorSet{
		PG:     map[string]actions.Door{"site1/pg01": {Remote: r.from()}, "f": {Monitor: "host=f", Actions: "host=fa"}},
		MS:     map[string]mssql.Door{"site1/sql01": {Remote: r.from(), Allow: []string{"kill"}}},
		Remote: map[string]remoteDoor{"site1/pg01": r, "site1/sql01": r},
		Gates:  map[string]actions.ExplainGate{"site1/pg01": {Enabled: true, DSN: "host=e"}, "f": {Enabled: true, DSN: "host=e"}},
		Hypo:   map[string]bool{"site1/pg01": true, "f": true}, QueryText: map[string]string{}, DefaultQT: "full",
		PgJobs: map[string]map[string]bool{"site1/pg01": {collect.JobStart: true}}, NoDoor: map[string]noDoor{},
	}
	return ds, r
}

// R13's words, one sentence on both engines
func TestRemoteWordsOnBothEngines(t *testing.T) {
	const want = "instance site1/sql01 is read from remote collector c1 of site site1: no live connection reaches it"
	if a, m := actions.RemoteOff("site1/sql01", "remote collector c1 of site site1"), mssql.RemoteOff("site1/sql01", "remote collector c1 of site site1"); a != want || m != want {
		t.Errorf("PostgreSQL %q, SQL Server %q, want %q", a, m, want)
	}
}

// every live door, and every GET that says whether its button is on, refuses a remote instance in R13's words; a
// pgvigil.yaml instance keeps its doors
func TestRemoteDoorWords(t *testing.T) {
	s := &Server{log: discardLog()}
	s.actions = &Actions{s: s}
	ds, r := remoteSet()
	const pg, ms = "site1/pg01", "site1/sql01"
	want := func(n string) string { return actions.RemoteOff(n, r.from()) }
	for _, n := range []string{pg, ms} {
		if got := ds.remoteWhy(n); got != want(n) {
			t.Errorf("remoteWhy(%s): %q, want %q", n, got, want(n))
		}
	}
	if got := ds.remoteWhy("f"); got != "" {
		t.Errorf("remoteWhy of a pgvigil.yaml instance: %q", got)
	}
	// the read login: Community tools (GET, params, run), a custom report run on the instance, a plan by its handle
	for _, c := range []struct{ engine, name string }{{"postgres", pg}, {config.EngineSQLServer, ms}} {
		if dsn, _, no := ds.readLogin(c.engine, c.name); dsn != "" || no.Why != want(c.name) {
			t.Errorf("readLogin(%s): dsn %q, why %q, want %q", c.name, dsn, no.Why, want(c.name))
		}
	}
	// cancel / terminate and the actions log (actions.go), every SQL Server action and its state (actions_mssql.go,
	// actions_verify.go)
	if off := ds.PG[pg].Off(pg); off != want(pg) {
		t.Errorf("PostgreSQL actions: %q", off)
	}
	if off := ds.MS[ms].Off(ms, mssql.ActionKind("kill")); off != want(ms) {
		t.Errorf("SQL Server actions: %q", off)
	}
	// EXPLAIN, EXPLAIN ANALYZE, the planner check, the index advisor, a job action
	if b := s.planButtonsOn(ds, pg); b.Explain || b.Analyze || b.ExplainReason != want(pg) || b.AnalyzeReason != want(pg) {
		t.Errorf("EXPLAIN's buttons: %+v", b)
	}
	if on, why := s.hypoButtonOn(ds, pg); on || why != want(pg) {
		t.Errorf("the planner check: %v %q", on, why)
	}
	if why := s.adviseOff(ds, pg); why != want(pg) {
		t.Errorf("the index advisor: %q", why)
	}
	if why := s.pgJobOff(ds, pg, collect.JobStart, ""); why != want(pg) {
		t.Errorf("a job action: %q", why)
	}
	// a histogram, a fragmentation read, a plan read by its handle (SQL Server)
	if why := s.histogramOff(context.Background(), ds, ms); why != "off: "+want(ms) {
		t.Errorf("the histogram: %q", why)
	}
	if why := s.fragOff(ds, ms); why != "off: "+want(ms) {
		t.Errorf("the fragmentation read: %q", why)
	}
	if why := ds.planFetchOff(ms); why != "not read: "+want(ms) {
		t.Errorf("a plan by its handle: %q", why)
	}
	// the pgvigil.yaml instance: EXPLAIN and the advisor stay on
	if b := s.planButtonsOn(ds, "f"); !b.Explain {
		t.Errorf("a pgvigil.yaml instance's EXPLAIN: %+v", b)
	}
	if why := s.adviseOff(ds, "f"); why != "" {
		t.Errorf("a pgvigil.yaml instance's advisor: %q", why)
	}
}

// remoteBesidePageExempt: the functions that read a door's Page and need no Remote of their own, each with its reason
var remoteBesidePageExempt = map[string]string{
	"isPage":    "its callers (histogramOff, fragOff) ask remoteWhy before it",
	"emptyPage": "it counts page doors with no login; a remote door is never a page door",
}

// Every function of the package that reads a door's Page (a page instance's refusal: ds.PG[n].Page, ds.MS[n].Page, or
// d.Page / door.Page on a door it took from them) also reads the door's Remote or asks remoteWhy, so a remote
// instance never meets a page instance's words, a 'no login' sentence, or a door that would dial it.
func TestRemoteBesidePage(t *testing.T) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("the package's files: %v", err)
	}
	door := func(e ast.Expr) bool {
		switch x := e.(type) {
		case *ast.IndexExpr:
			if se, ok := x.X.(*ast.SelectorExpr); ok {
				return se.Sel.Name == "PG" || se.Sel.Name == "MS"
			}
		case *ast.Ident:
			return x.Name == "d" || x.Name == "door"
		}
		return false
	}
	readsPage := map[string]bool{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range af.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			var page token.Pos
			remote := false
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if se, ok := n.(*ast.SelectorExpr); ok {
					switch {
					case se.Sel.Name == "Page" && door(se.X) && page == token.NoPos:
						page = se.Pos()
					case se.Sel.Name == "Remote", se.Sel.Name == "remoteWhy":
						remote = true
					}
				}
				return true
			})
			if page == token.NoPos {
				continue
			}
			readsPage[fd.Name.Name] = true
			if !remote && remoteBesidePageExempt[fd.Name.Name] == "" {
				t.Errorf("%s: %s reads a door's Page and never its Remote (nor remoteWhy)", fset.Position(page), fd.Name.Name)
			}
		}
	}
	for f := range remoteBesidePageExempt {
		if !readsPage[f] {
			t.Errorf("remoteBesidePageExempt names %s, which reads no door's Page", f)
		}
	}
}
