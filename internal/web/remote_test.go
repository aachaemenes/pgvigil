package web

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
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

// TestWithRemote (review B S3): withRemote puts each remote instance in the door set by its engine (a SQL Server one
// in MS, any other in PG) with its words and in Remote; a name an instance of this server already holds keeps that
// instance's own door and gets no Remote entry; a remote door the newest read no longer names is gone; the set it was
// given is never changed (requests read it while the next one is built).
func TestWithRemote(t *testing.T) {
	r := remoteDoor{Site: "s", Collector: "c1", Every: 5 * time.Minute, ExpectedEvery: time.Hour}
	in := &doorSet{
		PG:     map[string]actions.Door{"a": {Monitor: "host=a"}, "s/gone": {Remote: r.from()}},
		MS:     map[string]mssql.Door{"m": {Allow: []string{"kill"}}, "s/msgone": {Remote: r.from()}},
		Remote: map[string]remoteDoor{"s/gone": r, "s/msgone": r},
	}
	rows := []remoteRow{{Name: "s/pg", Engine: "postgres", Door: r}, {Name: "s/ms", Engine: config.EngineSQLServer, Door: r}, {Name: "a", Engine: "postgres", Door: r}}
	out := withRemote(in, rows, discardLog())
	if d, ok := out.PG["s/pg"]; !ok || d.Remote != r.from() {
		t.Errorf("the PostgreSQL remote instance's door: %+v (found %v)", d, ok)
	}
	if d, ok := out.MS["s/ms"]; !ok || d.Remote != r.from() {
		t.Errorf("the SQL Server remote instance's door: %+v (found %v)", d, ok)
	}
	if _, ok := out.PG["s/ms"]; ok {
		t.Errorf("the SQL Server remote instance also has a PostgreSQL door")
	}
	if _, ok := out.MS["s/pg"]; ok {
		t.Errorf("the PostgreSQL remote instance also has a SQL Server door")
	}
	if d := out.PG["a"]; d.Monitor != "host=a" || d.Remote != "" {
		t.Errorf("a name this server holds lost its own door: %+v", d)
	}
	if _, ok := out.Remote["a"]; ok {
		t.Errorf("a name this server holds got a Remote entry")
	}
	for _, n := range []string{"s/gone", "s/msgone"} {
		_, inPG := out.PG[n]
		_, inMS := out.MS[n]
		_, inR := out.Remote[n]
		if inPG || inMS || inR {
			t.Errorf("a remote door the newest read no longer names is still in the set: %s (PG %v MS %v Remote %v)", n, inPG, inMS, inR)
		}
	}
	if d := out.MS["m"]; len(d.Allow) != 1 || d.Remote != "" {
		t.Errorf("this server's SQL Server door: %+v", d)
	}
	if len(in.PG) != 2 || len(in.MS) != 2 || len(in.Remote) != 2 || in.PG["s/gone"].Remote == "" {
		t.Errorf("the set withRemote was given changed: PG %v MS %v Remote %v", in.PG, in.MS, in.Remote)
	}
}

// TestRemoteCollisionWarnsOnce (review B N2): the watcher rebuilds the set at every change; a remote instance whose
// name an instance of this server holds is logged once, not at every rebuild
func TestRemoteCollisionWarnsOnce(t *testing.T) {
	var buf strings.Builder
	log := slog.New(slog.NewTextHandler(&buf, nil))
	name := fmt.Sprintf("dup-%d", time.Now().UnixNano())
	in := &doorSet{PG: map[string]actions.Door{name: {Monitor: "host=x"}}, MS: map[string]mssql.Door{}, Remote: map[string]remoteDoor{}}
	rows := []remoteRow{{Name: name, Engine: "postgres", Door: remoteDoor{Site: "s", Collector: "c1"}}}
	withRemote(withRemote(in, rows, log), rows, log)
	if n := strings.Count(buf.String(), "already an instance of this server"); n != 1 {
		t.Errorf("the collision logged %d times over two rebuilds, want once:\n%s", n, buf.String())
	}
}

// TestRemoteWordsFirst (review B N1): a remote instance meets R13's words before any other on every path that has
// other words of its own - EXPLAIN's buttons with actions off, the index advisor without the actions door, a plan by
// its handle under a query_text policy that is not full, Admin > Instances' test of the name
func TestRemoteWordsFirst(t *testing.T) {
	ds, r := remoteSet()
	const pg, ms = "site1/pg01", "site1/sql01"
	want := func(n string) string { return actions.RemoteOff(n, r.from()) }
	for _, s := range []*Server{{log: discardLog()}, func() *Server {
		s := &Server{log: discardLog()}
		s.actions = &Actions{s: s, off: "the actions door is off on this server"}
		return s
	}()} {
		if b := s.planButtonsOn(ds, pg); b.ExplainReason != want(pg) {
			t.Errorf("EXPLAIN's reason (actions %v): %q, want %q", s.actions != nil, b.ExplainReason, want(pg))
		}
		if why := s.adviseOff(ds, pg); why != want(pg) {
			t.Errorf("the index advisor (actions %v): %q, want %q", s.actions != nil, why, want(pg))
		}
	}
	hashed := *ds
	hashed.DefaultQT = "hash"
	if why := hashed.planFetchOff(ms); why != "not read: "+want(ms) {
		t.Errorf("a plan by its handle under query_text hash: %q, want %q", why, "not read: "+want(ms))
	}
}

// TestRemoteAdminTestFirst (review B N1, the fourth path): Admin > Instances' test of a remote instance's name answers
// R13's words before it builds a connection string or looks for a page instance (no pool: nothing is read)
func TestRemoteAdminTestFirst(t *testing.T) {
	s := &Server{log: discardLog()}
	ds, r := remoteSet()
	s.storeDoors(ds)
	w := httptest.NewRecorder()
	s.instanceTest(w, httptest.NewRequest(http.MethodPost, "/api/admin/instances", nil), "u", map[string]any{"name": "site1/pg01"})
	if body := w.Body.String(); !strings.Contains(body, actions.RemoteOff("site1/pg01", r.from())) || !strings.Contains(body, `"ok":false`) {
		t.Errorf("Admin's test of a remote instance: %d %s", w.Code, body)
	}
}

// TestRemoteBeforeTheQueue (review B S4): in queue mode a Community tools run, its @help and a form for a remote
// instance are refused with R13's words before any ask is made (no collector holds a door to it): CommunityRun and
// CommunityParams call queuedRemoteRefused inside their queue branch before the queued call
func TestRemoteBeforeTheQueue(t *testing.T) {
	src, err := os.ReadFile("q_community.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	af, err := parser.ParseFile(fset, "q_community.go", src, 0)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, d := range af.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Body == nil || (fd.Name.Name != "CommunityRun" && fd.Name.Name != "CommunityParams") {
			continue
		}
		seen[fd.Name.Name] = true
		body := string(src[fset.Position(fd.Body.Pos()).Offset:fset.Position(fd.Body.End()).Offset])
		q := strings.Index(body, "s.queue()")
		if q < 0 {
			t.Errorf("%s has no queue branch", fd.Name.Name)
			continue
		}
		rest := body[q:]
		refuse, queued := strings.Index(rest, "s.queuedRemoteRefused("), strings.Index(rest, "s.queuedCommunity")
		if refuse < 0 || queued < 0 || refuse > queued {
			t.Errorf("%s's queue branch makes its ask without refusing a remote instance first (queuedRemoteRefused at %d, the queued call at %d)", fd.Name.Name, refuse, queued)
		}
	}
	if !seen["CommunityRun"] || !seen["CommunityParams"] {
		t.Errorf("CommunityRun / CommunityParams not found: %v", seen)
	}
}

// review C B1 (contract 3): a remote instance's statement-text policy is its bundles' - 'hash' when none says - never
// the hub's default ('full' here); the set withRemote was given keeps its own policies
func TestRemotePolicyIsTheBundles(t *testing.T) {
	r := remoteDoor{Site: "s", Collector: "c1"}
	in := &doorSet{PG: map[string]actions.Door{}, MS: map[string]mssql.Door{}, Remote: map[string]remoteDoor{}, QueryText: map[string]string{"f": "normalized"}, DefaultQT: "full"}
	out := withRemote(in, []remoteRow{{Name: "s/pg", Engine: "postgres", Door: r}}, discardLog())
	if qt := out.planPolicy("s/pg"); qt != "hash" {
		t.Errorf("a remote instance's policy: %q, want hash (its bundles' fingerprints)", qt)
	}
	if _, ok := in.QueryText["s/pg"]; ok || in.QueryText["f"] != "normalized" {
		t.Errorf("the given set's policies changed: %v", in.QueryText)
	}
}

// review C B1: under 'hash' a stored statement is its fingerprint - shown as one, never as the statement's text
func TestTextHashIsAFingerprint(t *testing.T) {
	tr := &textRule{byID: map[int]string{7: "hash"}, def: "full"}
	hex := strings.Repeat("ab", 32)
	if got := tr.stmt(7, true, hex); got != "fingerprint "+hex {
		t.Errorf("a hash-policy statement: %v, want 'fingerprint <hex>'", got)
	}
	if got := tr.stmt(7, true, "select 1"); got != nil {
		t.Errorf("a hash-policy statement that is no fingerprint: %v, want none shown", got)
	}
}

// review C S2: the index advisor's button is off with the actions door's own words when actions are off
func TestAdviseOffReadsActionsOff(t *testing.T) {
	s := &Server{log: discardLog()}
	s.actions = &Actions{s: s, off: "the actions door is off on this server: no actions_dsn"}
	ds, _ := remoteSet()
	if why := s.adviseOff(ds, "f"); why != s.actions.off {
		t.Errorf("the advisor on a pgvigil.yaml instance with actions off: %q, want %q", why, s.actions.off)
	}
}

// review C S3: a job button of a remote instance says R13's words before the server's own (actions off here)
func TestPgJobRemoteFirst(t *testing.T) {
	s := &Server{log: discardLog()}
	ds, r := remoteSet()
	if why := s.pgJobOff(ds, "site1/pg01", collect.JobStart, ""); why != actions.RemoteOff("site1/pg01", r.from()) {
		t.Errorf("a remote instance's job action with actions off: %q", why)
	}
}
