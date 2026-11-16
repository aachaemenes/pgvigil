package web

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// credFile writes a stored credential as Admin > Instances does (a file the reference names) and returns its reference
func credFile(t *testing.T, dsn string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cred")
	if err := os.WriteFile(p, []byte(dsn), 0o600); err != nil {
		t.Fatal(err)
	}
	return "file:" + p
}

// the file's set: one instance of each engine from pgvigil.yaml, and one whose dsn resolved to nothing
func fileSet() (*doorSet, pageDoorsConfig) {
	ds := &doorSet{PG: map[string]actions.Door{"pgfile": {Monitor: "host=a user=m"}, "pgempty": {}},
		MS: map[string]mssql.Door{"msfile": {Monitor: "sqlserver://m@a"}}, QueryText: map[string]string{"pgfile": "full"},
		DefaultQT: "normalized", NoDoor: map[string]noDoor{}}
	c := pageDoorsConfig{file: []config.Instance{{Name: "pgfile", Engine: config.EnginePostgres}, {Name: "pgempty", Engine: config.EnginePostgres},
		{Name: "msfile", Engine: config.EngineSQLServer}}, queryText: "normalized", reads: true}
	return ds, c
}

func build(file *doorSet, prev *doorSet, c pageDoorsConfig, page []config.PageInstance, gen int64) *doorSet {
	all, _ := config.Merge(c.file, page, c.queryText, config.CounterEdits{})
	return pageDoors(file, prev, c, all, page, gen)
}

func TestPageDoors(t *testing.T) {
	file, c := fileSet()
	pgDSN := "host=b port=5432 user=r password=x dbname=d"
	page := []config.PageInstance{
		{Name: "pgfile", Engine: config.EnginePostgres, DSNRef: credFile(t, "host=z user=page"), Auth: "password"},
		{Name: "pg-ok", Engine: config.EnginePostgres, DSNRef: credFile(t, pgDSN), Auth: "password", Options: "sslmode=require"},
		{Name: "ms-ok", Engine: config.EngineSQLServer, DSNRef: credFile(t, "sqlserver://r:x@b?database=d&encrypt=true"), Auth: "sql", Options: "encrypt=true"},
		{Name: "ms-entra", Engine: config.EngineSQLServer, DSNRef: credFile(t, "sqlserver://app:secret@b?database=d&fedauth=ActiveDirectoryServicePrincipal"), Auth: "entra"},
		{Name: "pg-off", Engine: config.EnginePostgres, DSNRef: credFile(t, pgDSN), Auth: "password", Disabled: true},
		{Name: "bad name!", Engine: config.EnginePostgres, DSNRef: credFile(t, pgDSN), Auth: "password"},
		{Name: "ms-win", Engine: config.EngineSQLServer, DSNRef: credFile(t, "sqlserver://b?database=d"), Auth: "windows"},
		{Name: "pg-pass", Engine: config.EnginePostgres, DSNRef: credFile(t, "host=b user=r"), Auth: "pgpass"},
		{Name: "pg-opt", Engine: config.EnginePostgres, DSNRef: credFile(t, pgDSN), Auth: "password", Options: "application_name=x"},
		{Name: "pg-cert", Engine: config.EnginePostgres, DSNRef: credFile(t, pgDSN+" sslcert=/etc/serve.crt"), Auth: "password"},
		{Name: "pg-gone", Engine: config.EnginePostgres, DSNRef: "file:" + filepath.Join(t.TempDir(), "not-here"), Auth: "password"},
	}
	ds := build(file, nil, c, page, 7)
	if ds.Gen != 7 || !ds.PageReads {
		t.Fatalf("gen %d, reads %v", ds.Gen, ds.PageReads)
	}
	// pgvigil.yaml's door stands over the page's row of the same name
	if d := ds.PG["pgfile"]; d.Page || d.Monitor != "host=a user=m" {
		t.Errorf("pgfile: %+v", d)
	}
	if d := ds.PG["pg-ok"]; !d.Page || d.Monitor != pgDSN || ds.QueryText["pg-ok"] != "normalized" {
		t.Errorf("pg-ok: %+v, query text %q", d, ds.QueryText["pg-ok"])
	}
	if d := ds.MS["ms-ok"]; !d.Page || !strings.HasPrefix(d.Monitor, "sqlserver://r:x@b") {
		t.Errorf("ms-ok: %+v", d)
	}
	// a service principal's typed secret is a typed credential: allowed
	if d := ds.MS["ms-entra"]; !d.Page || d.Monitor == "" {
		t.Errorf("ms-entra: %+v (%+v)", d, ds.NoDoor["ms-entra"])
	}
	// the file's set itself is never written
	if _, ok := file.PG["pg-ok"]; ok {
		t.Error("pageDoors wrote into the file's set")
	}
	for _, c := range []struct{ name, why, how string }{
		{"pg-off", "is disabled in Admin > Instances", howEnable},
		{"bad name!", "is left out of the list: not a valid name", howCorrect},
		{"ms-win", "signs in with this server's own identity", howInTheFile},
		{"pg-pass", "signs in with this server's own identity", howInTheFile},
		{"pg-opt", "application_name", howInTheFile},
		{"pg-cert", "sslcert", howInTheFile},
		{"pg-gone", "its credential is not readable on this host", howPageAgain},
		{"pgempty", "resolved to an empty string on this server", howFile},
		{"nobody", "it is in neither pgvigil.yaml nor Admin > Instances", howNeither},
	} {
		engine := config.EnginePostgres
		if strings.HasPrefix(c.name, "ms-") {
			engine = config.EngineSQLServer
		}
		dsn, kind, no := ds.readLogin(engine, c.name)
		if dsn != "" || kind != "" || !strings.Contains(no.Why, c.why) || no.How != c.how {
			t.Errorf("%s: dsn %q kind %q %+v; want %q / %q", c.name, dsn, kind, no, c.why, c.how)
		}
		// a page row with no read login is still a page instance: the actions, EXPLAIN and the advisor say so
		if wantPage := c.name != "pgempty" && c.name != "nobody"; ds.isPage(engine, c.name) != wantPage {
			t.Errorf("%s: isPage %v, want %v", c.name, !wantPage, wantPage)
		}
	}
	if off := ds.PG["pg-off"].Off("pg-off"); !strings.Contains(off, "actions run only on an instance of pgvigil.yaml") {
		t.Errorf("a disabled page row's actions: %q", off)
	}
	if off := ds.MS["ms-win"].Off("ms-win", mssql.ActionKind("kill")); !strings.Contains(off, "actions run only on an instance of pgvigil.yaml") {
		t.Errorf("a refused SQL Server page row's actions: %q", off)
	}
	for _, c := range []struct{ engine, name, kind string }{
		{config.EnginePostgres, "pgfile", "file"}, {config.EnginePostgres, "pg-ok", "page"}, {config.EngineSQLServer, "msfile", "file"}, {config.EngineSQLServer, "ms-ok", "page"},
	} {
		if dsn, kind, no := ds.readLogin(c.engine, c.name); dsn == "" || kind != c.kind || no.Why != "" {
			t.Errorf("%s: dsn %q kind %q %+v; want kind %s", c.name, dsn, kind, no, c.kind)
		}
		if ds.isPage(c.engine, c.name) != (c.kind == "page") {
			t.Errorf("%s: isPage", c.name)
		}
	}
	// a page door never acts
	if off := ds.PG["pg-ok"].Off("pg-ok"); !strings.Contains(off, "actions run only on an instance of pgvigil.yaml") {
		t.Errorf("pg-ok's actions: %q", off)
	}

	// the switch off: no page door opens, the words name it; the actions keep a page instance's words, not a
	// missing actions_dsn's
	off := c
	off.reads = false
	ds0 := build(file, nil, off, page, 7)
	if d := ds0.PG["pg-ok"]; d.Monitor != "" || !d.Page {
		t.Errorf("pg-ok with the switch off: %+v", d)
	}
	if _, _, no := ds0.readLogin(config.EnginePostgres, "pg-ok"); !strings.Contains(no.Why, config.PageReadsOff) || no.How != howSwitch {
		t.Errorf("switch off: %+v", no)
	}
	if off := ds0.PG["pg-ok"].Off("pg-ok"); !strings.Contains(off, "actions run only on an instance of pgvigil.yaml") {
		t.Errorf("switch off, the actions: %q", off)
	}
	if b := (&Server{log: discardLog(), actions: &Actions{}}).planButtonsOn(ds0, "pg-ok"); b.Explain || b.ExplainReason != fileOnly("pg-ok") {
		t.Errorf("switch off, EXPLAIN: %+v", b)
	}
	// a row the switch never opens says its own refusal first, not the switch
	if _, _, no := ds0.readLogin(config.EngineSQLServer, "ms-win"); !strings.Contains(no.Why, "signs in with this server's own identity") || no.How != howInTheFile {
		t.Errorf("switch off, a windows row: %+v", no)
	}
	if dsn, kind, _ := ds0.readLogin(config.EnginePostgres, "pgfile"); kind != "file" || dsn == "" {
		t.Error("the switch off closed a file door")
	}

	// the same generation lends the resolved string; a new one reads the credential again
	p := strings.TrimPrefix(page[1].DSNRef, "file:")
	if err := os.WriteFile(p, []byte("host=c user=r2 password=y"), 0o600); err != nil {
		t.Fatal(err)
	}
	if d := build(file, ds, c, page, 7).PG["pg-ok"]; d.Monitor != pgDSN {
		t.Errorf("same generation: %q", d.Monitor)
	}
	if d := build(file, ds, c, page, 8).PG["pg-ok"]; d.Monitor != "host=c user=r2 password=y" {
		t.Errorf("new generation: %q", d.Monitor)
	}
	// an empty one is read again on each tick: the credential readable now opens the door; a set with no empty page
	// door stands on a tick of the same generation (the watcher builds none)
	if !ds.emptyPage() {
		t.Error("pg-gone's empty door not seen")
	}
	gone := strings.TrimPrefix(page[10].DSNRef, "file:")
	if err := os.WriteFile(gone, []byte(pgDSN), 0o600); err != nil {
		t.Fatal(err)
	}
	again := build(file, ds, c, page, 7)
	if d := again.PG["pg-gone"]; d.Monitor != pgDSN {
		t.Errorf("an empty door read again: %q", d.Monitor)
	}
	if again.emptyPage() {
		t.Error("an empty page door left after every credential was read")
	}

	// the page's list not read yet (the watcher's first read failed): the file's doors stand, a page instance is
	// unknown here - never 'in neither list'
	un := build(file, nil, c, nil, -1)
	if !un.Unread {
		t.Error("generation -1 not marked unread")
	}
	if _, _, no := un.readLogin(config.EnginePostgres, "pg-ok"); !strings.Contains(no.Why, "has not read the list of Admin > Instances") || no.How != howUnread {
		t.Errorf("unread: %+v", no)
	}
	if dsn, kind, _ := un.readLogin(config.EnginePostgres, "pgfile"); kind != "file" || dsn == "" {
		t.Error("an unread list closed a file door")
	}
}

// the watcher's swap is race-free and a loaded set is never written after: a reader that loads the set once sees one
// generation whole (run under -race). That each request loads it once is TestDoorsReadOnce's.
func TestDoorSetSwap(t *testing.T) {
	s := &Server{log: discardLog()}
	t.Cleanup(func() { doorSets.Delete(s) })
	mk := func(g int64) *doorSet {
		v := strconv.FormatInt(g, 10)
		return &doorSet{Gen: g, PG: map[string]actions.Door{"a": {Monitor: v}}, MS: map[string]mssql.Door{"b": {Monitor: v}},
			QueryText: map[string]string{"a": v}, NoDoor: map[string]noDoor{}}
	}
	s.storeDoors(mk(1))
	var stop atomic.Bool
	var bad atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			last := int64(0)
			for !stop.Load() {
				ds := s.doorsNow()
				v := strconv.FormatInt(ds.Gen, 10)
				if dsn, _, _ := ds.readLogin(config.EnginePostgres, "a"); dsn != v || ds.MS["b"].Monitor != v || ds.QueryText["a"] != v || ds.Gen < last {
					bad.Add(1)
				}
				last = ds.Gen
			}
		}()
	}
	for g := int64(2); g <= 2000; g++ {
		s.storeDoors(mk(g))
	}
	stop.Store(true)
	wg.Wait()
	if n := bad.Load(); n != 0 {
		t.Errorf("%d read(s) mixed two generations or went back", n)
	}
	if g := s.doorsNow().Gen; g != 2000 {
		t.Errorf("last set %d", g)
	}
}

// the admin write's wait for the swap is bounded: a stuck watcher never hangs the page
func TestWakeDoorsBounded(t *testing.T) {
	s := &Server{log: discardLog()}
	if got := s.doorsAfterWrite(context.Background()); got != "" {
		t.Errorf("no watcher: %q", got)
	}
	s.storeDoors(&doorSet{Gen: 3})
	wake := make(chan struct{}, 1)
	doorWake.Store(s, wake)
	t.Cleanup(func() { doorWake.Delete(s); doorSets.Delete(s) })
	go func() { <-wake; s.storeDoors(&doorSet{Gen: 4}) }()
	if !s.wakeDoors(4, 2*time.Second) {
		t.Error("a watcher that answers: not in time")
	}
	// nothing reads the wake any more: the wait ends at its bound
	t0 := time.Now()
	if s.wakeDoors(5, 300*time.Millisecond) {
		t.Error("a stuck watcher: reported in time")
	}
	if d := time.Since(t0); d < 300*time.Millisecond || d > 2*time.Second {
		t.Errorf("a stuck watcher: waited %v", d)
	}
	// a wake already pending never blocks the next write
	t0 = time.Now()
	s.wakeDoors(6, 100*time.Millisecond)
	if d := time.Since(t0); d > time.Second {
		t.Errorf("a pending wake: waited %v", d)
	}
	if got := doorTakesEffect(false, DoorEvery); got != "this change reaches Community tools and custom reports within 15 s" {
		t.Errorf("late words: %q", got)
	}
	if got := doorTakesEffect(true, DoorEvery); !strings.HasPrefix(got, "this change reaches Community tools and custom reports at once on this server") {
		t.Errorf("at once words: %q", got)
	}
	// the write's own wait is doorWait: a stuck watcher answers the late words after it, never later
	t0 = time.Now()
	if got := s.doorsAfterGen(7, nil); got != doorTakesEffect(false, DoorEvery) {
		t.Errorf("a stuck watcher after a write: %q", got)
	}
	if d := time.Since(t0); d < doorWait || d > doorWait+2*time.Second {
		t.Errorf("a stuck watcher after a write: waited %v (doorWait %v)", d, doorWait)
	}
	// the generation not read after the write: said, never 'within 15 s'
	if got := s.doorsAfterGen(0, errors.New("no 0131")); got != doorUnreadAfterWrite {
		t.Errorf("generation unread: %q", got)
	}
	// an install whose page doors are off: the answer says nothing of them (no pool is asked)
	s.storeDoors(&doorSet{Gen: 8, PageReads: false})
	if got := s.doorsAfterWrite(context.Background()); got != "" {
		t.Errorf("page doors off: %q", got)
	}
}

// each request reads the door set once: no function outside doorset.go calls doorsNow twice (planButtons and
// hypoButton read it too, so each counts), and none reads the file's doors beside the set (an Actions' doors,
// plansConfig, the job allow lists) - a handler that did would mix two generations, which TestDoorSetSwap cannot see
func TestDoorsReadOnce(t *testing.T) {
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("the package's files: %v", err)
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") || f == "doorset.go" {
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
			written := map[ast.Expr]bool{}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if as, ok := n.(*ast.AssignStmt); ok {
					for _, l := range as.Lhs {
						written[l] = true
					}
				}
				return true
			})
			calls := 0
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				switch x := n.(type) {
				case *ast.CallExpr:
					if se, ok := x.Fun.(*ast.SelectorExpr); ok {
						switch {
						case se.Sel.Name == "doorsNow" && len(x.Args) == 0, se.Sel.Name == "planButtons", se.Sel.Name == "hypoButton":
							calls++
						case se.Sel.Name == "plansConfig":
							t.Errorf("%s: %s reads plansConfig() beside the door set", fset.Position(x.Pos()), fd.Name.Name)
						case se.Sel.Name == "Load":
							if id, ok := se.X.(*ast.Ident); ok && id.Name == "pgJobAllow" {
								t.Errorf("%s: %s reads pgJobAllow beside the door set", fset.Position(x.Pos()), fd.Name.Name)
							}
						}
					}
				case *ast.SelectorExpr:
					if x.Sel.Name == "doors" && !written[x] {
						t.Errorf("%s: %s reads .doors beside the door set", fset.Position(x.Pos()), fd.Name.Name)
					}
				}
				return true
			})
			if calls > 1 {
				t.Errorf("%s: %s reads the door set %d times (one request, one set)", fset.Position(fd.Pos()), fd.Name.Name, calls)
			}
		}
	}
}

// a page instance's actions say the same words on both engines
func TestPageOffWordsOnBothEngines(t *testing.T) {
	if a, m := actions.PageOff("x"), mssql.PageOff("x"); a != m {
		t.Errorf("PostgreSQL %q, SQL Server %q", a, m)
	}
	if off := (mssql.Door{Page: true, Monitor: "sqlserver://m@a", Actions: "sqlserver://a@a", Allow: []string{"kill"}}).Off("x", mssql.ActionKind("kill")); off != mssql.PageOff("x") {
		t.Errorf("a SQL Server page door with every login: %q", off)
	}
}

// the actions' superuser read never hands pgx an empty string (it would sign in from serve's own environment)
func TestSuperusersRefuseAnEmptyDSN(t *testing.T) {
	a := &Actions{suCache: map[string]suEntry{}}
	if su, err := a.superusers(context.Background(), "x", " ", nil); err == nil || su != nil || !strings.Contains(err.Error(), "empty string") {
		t.Errorf("an empty dsn: %v %v", su, err)
	}
}

// EXPLAIN, EXPLAIN ANALYZE and the index advisor stay on pgvigil.yaml's instances
func TestPlanButtonsPageDoor(t *testing.T) {
	s := &Server{log: discardLog()}
	s.actions = &Actions{s: s}
	ds := &doorSet{PG: map[string]actions.Door{"p": {Monitor: "host=p", Page: true}, "f": {Monitor: "host=f"}},
		Gates: map[string]actions.ExplainGate{"p": {Enabled: true, DSN: "host=e"}}, Hypo: map[string]bool{"p": true, "f": true}, NoDoor: map[string]noDoor{}}
	if b := s.planButtonsOn(ds, "p"); b.Explain || b.Analyze || b.ExplainReason != fileOnly("p") || b.AnalyzeReason != fileOnly("p") {
		t.Errorf("page door: %+v", b)
	}
	if on, why := s.hypoButtonOn(ds, "p"); on || why != fileOnly("p") {
		t.Errorf("page door's planner check: %v %q", on, why)
	}
	if b := s.planButtonsOn(ds, "f"); !b.Explain {
		t.Errorf("file door: %+v", b)
	}
	if qt := ds.queryText("p"); qt != "" {
		t.Errorf("no policy and no default: %q", qt)
	}
	ds.DefaultQT = "none"
	if qt := ds.queryText("p"); qt != "none" {
		t.Errorf("the default policy: %q", qt)
	}
}
