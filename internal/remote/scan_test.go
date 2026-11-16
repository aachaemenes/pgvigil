package remote

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The scanning row (task 3 (g), the design's B1): sources.go's table against the code both ways. The Go side resolves
// the source of every cursor(ctx, <source>) call (a call of a function or field named cursor with two arguments) in
// internal/collect, internal/mssql and internal/engines: a string, a constant, a local assigned from those, a package
// function returning a constant prefix plus its argument, or a parameter followed to every call of its function. The
// SQL side reads every migration in order, follows ALTER FUNCTION ... RENAME TO (a wrapper's base keeps the old body),
// and lists each current function that writes a cursor table.

type srcShape struct {
	S      string
	Prefix bool
}

func (s srcShape) String() string {
	if s.Prefix {
		return s.S + "*"
	}
	return s.S
}

type goSite struct {
	Pos    string
	Shapes []srcShape
	Err    string
}

// dynamicSites are the call arguments no static reading resolves (a value read from the server), each with the
// shapes it takes and why. Key: the enclosing function's name and the argument as written.
var dynamicSites = map[string][]srcShape{
	// xe.go readSession passes a session's name as the server lists it (xeGroup over sys.dm_xe_sessions): the product's
	// own sessions (XESessionName: pgvigil_<install>_<capture>) and system_health (xe.go L577)
	"readSession s.name": {{S: "pgvigil_", Prefix: true}, {S: "system_health"}},
}

var cursorTables = `log_cursor|mssql_cursor|mssql_jobs_cursor|mssql_backup_files_cursor|mssql_backup_history_cursor|` +
	`mssql_backup_history_dbs|mssql_stats_db|mssql_constraint_db|mssql_index_db|mssql_qs_store|mssql_qs_plan|` +
	`mssql_azuredb_read|mssql_hadr_reads`

type goPkg struct {
	fset   *token.FileSet
	consts map[string]string
	funcs  map[string][]*ast.FuncDecl
	files  map[*ast.FuncDecl]string
}

func loadGoPkg(t *testing.T, dir string) *goPkg {
	t.Helper()
	p := &goPkg{fset: token.NewFileSet(), consts: map[string]string{}, funcs: map[string][]*ast.FuncDecl{}, files: map[*ast.FuncDecl]string{}}
	pkgs, err := parser.ParseDir(p.fset, dir, func(fi os.FileInfo) bool { return !strings.HasSuffix(fi.Name(), "_test.go") }, 0)
	if err != nil {
		t.Fatalf("parse %s: %v", dir, err)
	}
	var specs []*ast.ValueSpec
	for _, pkg := range pkgs {
		for name, f := range pkg.Files {
			for _, d := range f.Decls {
				switch d := d.(type) {
				case *ast.GenDecl:
					if d.Tok == token.CONST {
						for _, s := range d.Specs {
							specs = append(specs, s.(*ast.ValueSpec))
						}
					}
				case *ast.FuncDecl:
					p.funcs[d.Name.Name] = append(p.funcs[d.Name.Name], d)
					p.files[d] = filepath.Base(name)
				}
			}
		}
	}
	// constants built from strings and other constants, resolved until nothing changes
	for changed := true; changed; {
		changed = false
		for _, s := range specs {
			for i, n := range s.Names {
				if _, done := p.consts[n.Name]; done || i >= len(s.Values) {
					continue
				}
				if v, ok := p.constString(s.Values[i]); ok {
					p.consts[n.Name], changed = v, true
				}
			}
		}
	}
	return p
}

func (p *goPkg) constString(e ast.Expr) (string, bool) {
	switch e := e.(type) {
	case *ast.BasicLit:
		if e.Kind == token.STRING {
			s, err := strconv.Unquote(e.Value)
			return s, err == nil
		}
	case *ast.Ident:
		v, ok := p.consts[e.Name]
		return v, ok
	case *ast.ParenExpr:
		return p.constString(e.X)
	case *ast.BinaryExpr:
		if e.Op == token.ADD {
			l, okL := p.constString(e.X)
			r, okR := p.constString(e.Y)
			return l + r, okL && okR
		}
	}
	return "", false
}

func flattenAdd(e ast.Expr) []ast.Expr {
	if b, ok := e.(*ast.BinaryExpr); ok && b.Op == token.ADD {
		return append(flattenAdd(b.X), flattenAdd(b.Y)...)
	}
	if pe, ok := e.(*ast.ParenExpr); ok {
		return flattenAdd(pe.X)
	}
	return []ast.Expr{e}
}

func paramIndex(fn *ast.FuncDecl, name string) int {
	i := 0
	for _, f := range fn.Type.Params.List {
		if len(f.Names) == 0 {
			i++
			continue
		}
		for _, n := range f.Names {
			if n.Name == name {
				return i
			}
			i++
		}
	}
	return -1
}

func calleeName(c *ast.CallExpr) string {
	switch f := c.Fun.(type) {
	case *ast.Ident:
		return f.Name
	case *ast.SelectorExpr:
		return f.Sel.Name
	}
	return ""
}

func exprText(fset *token.FileSet, e ast.Expr) string {
	var b strings.Builder
	ast.Inspect(e, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.Ident:
			if b.Len() > 0 && !strings.HasSuffix(b.String(), ".") {
				b.WriteString(".")
			}
			b.WriteString(n.Name)
		case *ast.BasicLit:
			b.WriteString(n.Value)
		}
		return true
	})
	return b.String()
}

// shapes resolves a source expression inside fn; follow says whether a parameter is followed to fn's callers (false
// inside a helper: its parameter is the variable part).
func (p *goPkg) shapes(e ast.Expr, fn *ast.FuncDecl, follow bool, depth int) ([]srcShape, error) {
	if depth > 5 {
		return nil, fmt.Errorf("too deep")
	}
	if key := fn.Name.Name + " " + exprText(p.fset, e); dynamicSites[key] != nil {
		return dynamicSites[key], nil
	}
	if v, ok := p.constString(e); ok {
		return []srcShape{{S: v}}, nil
	}
	switch e := e.(type) {
	case *ast.ParenExpr:
		return p.shapes(e.X, fn, follow, depth)
	case *ast.Ident:
		if i := paramIndex(fn, e.Name); i >= 0 {
			if !follow {
				return nil, errOpaque
			}
			return p.callers(fn, i, depth+1)
		}
		var out []srcShape
		var firstErr error
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			as, ok := n.(*ast.AssignStmt)
			if !ok || len(as.Lhs) != len(as.Rhs) {
				return true
			}
			for i, l := range as.Lhs {
				if id, ok := l.(*ast.Ident); ok && id.Name == e.Name {
					s, err := p.shapes(as.Rhs[i], fn, follow, depth+1)
					if err != nil && firstErr == nil {
						firstErr = err
					}
					out = append(out, s...)
				}
			}
			return true
		})
		if firstErr != nil {
			return nil, firstErr
		}
		if len(out) == 0 {
			return nil, fmt.Errorf("%s: no constant, parameter or assignment", e.Name)
		}
		return out, nil
	case *ast.BinaryExpr:
		parts := flattenAdd(e)
		acc := ""
		for i, part := range parts {
			if v, ok := p.constString(part); ok {
				acc += v
				continue
			}
			if acc != "" {
				return []srcShape{{S: acc, Prefix: true}}, nil
			}
			if i > 0 {
				break
			}
			head, err := p.shapes(part, fn, follow, depth+1)
			if err != nil {
				return nil, err
			}
			for j := range head {
				head[j].Prefix = true
			}
			return head, nil
		}
		if acc != "" {
			return []srcShape{{S: acc}}, nil
		}
	case *ast.CallExpr:
		if id, ok := e.Fun.(*ast.Ident); ok {
			for _, h := range p.funcs[id.Name] {
				if h.Recv != nil || h.Body == nil || len(h.Body.List) != 1 {
					continue
				}
				if ret, ok := h.Body.List[0].(*ast.ReturnStmt); ok && len(ret.Results) == 1 {
					return p.shapes(ret.Results[0], h, false, depth+1)
				}
			}
		}
	}
	return nil, fmt.Errorf("%s: not resolved", exprText(p.fset, e))
}

var errOpaque = fmt.Errorf("a helper's parameter")

// callers resolves argument i of every call of fn in the package.
func (p *goPkg) callers(fn *ast.FuncDecl, i int, depth int) ([]srcShape, error) {
	var out []srcShape
	var firstErr error
	for _, fs := range p.funcs {
		for _, caller := range fs {
			if caller.Body == nil {
				continue
			}
			ast.Inspect(caller.Body, func(n ast.Node) bool {
				c, ok := n.(*ast.CallExpr)
				if !ok || calleeName(c) != fn.Name.Name || i >= len(c.Args) {
					return true
				}
				s, err := p.shapes(c.Args[i], caller, true, depth)
				if err != nil && firstErr == nil {
					firstErr = fmt.Errorf("%s: %w", caller.Name.Name, err)
				}
				out = append(out, s...)
				return true
			})
		}
	}
	if firstErr != nil {
		return nil, firstErr
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: no call passes its argument %d", fn.Name.Name, i)
	}
	return out, nil
}

// cursorSites lists every cursor(ctx, <source>) call of the packages in dirs with its resolved shapes.
func cursorSites(t *testing.T, dirs ...string) []goSite {
	t.Helper()
	var sites []goSite
	for _, dir := range dirs {
		p := loadGoPkg(t, dir)
		for _, fs := range p.funcs {
			for _, fn := range fs {
				if fn.Body == nil {
					continue
				}
				ast.Inspect(fn.Body, func(n ast.Node) bool {
					c, ok := n.(*ast.CallExpr)
					if !ok || calleeName(c) != "cursor" || len(c.Args) != 2 {
						return true
					}
					pos := p.fset.Position(c.Pos())
					site := goSite{Pos: fmt.Sprintf("%s/%s:%d (%s)", filepath.Base(dir), filepath.Base(pos.Filename), pos.Line, fn.Name.Name)}
					s, err := p.shapes(c.Args[1], fn, true, 0)
					if err != nil {
						site.Err = err.Error()
					}
					site.Shapes = s
					sites = append(sites, site)
					return true
				})
			}
		}
	}
	sort.Slice(sites, func(i, j int) bool { return sites[i].Pos < sites[j].Pos })
	return sites
}

// checkGoSources: every site resolved, every shape an entry of the table (an exact name to an exact entry, a prefix to
// a prefix entry of the same text), every entry reached by a site.
func checkGoSources(sites []goSite, table []cursorSource) []string {
	var problems []string
	used := map[srcShape]bool{}
	known := map[srcShape]bool{}
	for _, s := range table {
		known[srcShape{S: s.Name, Prefix: s.Prefix}] = true
	}
	for _, site := range sites {
		if site.Err != "" {
			problems = append(problems, fmt.Sprintf("%s: the source is not resolved (%s) - name it in dynamicSites", site.Pos, site.Err))
			continue
		}
		for _, sh := range site.Shapes {
			used[sh] = true
			if !known[sh] {
				problems = append(problems, fmt.Sprintf("%s asks %s: no entry in sources.go (a collector source with no rule)", site.Pos, sh))
			}
		}
	}
	for _, s := range table {
		if sh := (srcShape{S: s.Name, Prefix: s.Prefix}); !used[sh] {
			problems = append(problems, fmt.Sprintf("sources.go names %s: no collector asks it", sh))
		}
	}
	return problems
}

var (
	createRE  = regexp.MustCompile(`(?is)CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+pgvigil\.([a-z0-9_]+)\s*\(`)
	renameRE  = regexp.MustCompile(`(?is)ALTER\s+FUNCTION\s+pgvigil\.([a-z0-9_]+)\s*\([^)]*\)\s*RENAME\s+TO\s+([a-z0-9_]+)`)
	dollarRE  = regexp.MustCompile(`\$[A-Za-z_]*\$`)
	writeRE   = regexp.MustCompile(`(?i)(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:ONLY\s+)?pgvigil\.(` + cursorTables + `)\b`)
	commentRE = regexp.MustCompile(`--[^\n]*`)
)

// currentBodies reads the migrations of dir in name order: a CREATE sets a function's body, a RENAME moves it.
func currentBodies(t *testing.T, dir string) map[string]string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(dir, "*.sql"))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(files)
	bodies := map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := commentRE.ReplaceAllString(string(b), "")
		type ev struct {
			at       int
			name, to string
			body     string
		}
		var evs []ev
		for _, m := range createRE.FindAllStringSubmatchIndex(src, -1) {
			rest := src[m[1]:]
			open := dollarRE.FindStringIndex(rest)
			if open == nil {
				continue
			}
			tag := rest[open[0]:open[1]]
			end := strings.Index(rest[open[1]:], tag)
			if end < 0 {
				continue
			}
			evs = append(evs, ev{at: m[0], name: src[m[2]:m[3]], body: rest[open[1] : open[1]+end]})
		}
		for _, m := range renameRE.FindAllStringSubmatchIndex(src, -1) {
			evs = append(evs, ev{at: m[0], name: src[m[2]:m[3]], to: src[m[4]:m[5]]})
		}
		sort.Slice(evs, func(i, j int) bool { return evs[i].at < evs[j].at })
		for _, e := range evs {
			if e.to != "" {
				if body, ok := bodies[e.name]; ok {
					bodies[e.to] = body
					delete(bodies, e.name)
				}
				continue
			}
			bodies[e.name] = e.body
		}
	}
	return bodies
}

// cursorWriters lists, per current function, the cursor tables it writes.
func cursorWriters(bodies map[string]string) map[string][]string {
	out := map[string][]string{}
	for name, body := range bodies {
		seen := map[string]bool{}
		for _, m := range writeRE.FindAllStringSubmatch(body, -1) {
			tbl := strings.ToLower(m[1])
			if !seen[tbl] {
				seen[tbl] = true
				out[name] = append(out[name], tbl)
			}
		}
		sort.Strings(out[name])
	}
	return out
}

// checkSQLWriters: every function writing a cursor table is named (rowWriters, an entry's SQL, otherWriters); every
// name there writes one.
func checkSQLWriters(writers map[string][]string, table []cursorSource, rows []string, other map[string]string) []string {
	named := map[string]bool{}
	for _, r := range rows {
		named[r] = true
	}
	for _, s := range table {
		for _, f := range s.SQL {
			named[f] = true
		}
	}
	for f := range other {
		named[f] = true
	}
	var problems []string
	for f, tbls := range writers {
		if !named[f] {
			problems = append(problems, fmt.Sprintf("pgvigil.%s writes %s: no rule names it in sources.go", f, strings.Join(tbls, ", ")))
		}
	}
	for f := range named {
		if _, ok := writers[f]; !ok {
			problems = append(problems, fmt.Sprintf("sources.go names pgvigil.%s: no current function of that name writes a cursor table", f))
		}
	}
	sort.Strings(problems)
	return problems
}

func TestSourcesCoverTheCode(t *testing.T) {
	sites := cursorSites(t, "../collect", "../mssql", "../engines")
	if len(sites) < 20 {
		t.Fatalf("only %d cursor call sites found: the scan reads nothing", len(sites))
	}
	for _, p := range checkGoSources(sites, cursorSources) {
		t.Error(p)
	}
	writers := cursorWriters(currentBodies(t, "../repo/sql"))
	if len(writers) < 15 {
		t.Fatalf("only %d cursor-table writers found: the scan reads nothing", len(writers))
	}
	for _, p := range checkSQLWriters(writers, cursorSources, rowWriters, otherWriters) {
		t.Error(p)
	}
	if t.Failed() {
		for _, s := range sites {
			t.Logf("site %s -> %v %s", s.Pos, s.Shapes, s.Err)
		}
		names := make([]string, 0, len(writers))
		for f := range writers {
			names = append(names, f)
		}
		sort.Strings(names)
		for _, f := range names {
			t.Logf("writer %s -> %v", f, writers[f])
		}
	}
}

// The scan can fail: a planted collector source with no entry, an unresolved one, a planted writer with no rule, and a
// wrapper's base found under its renamed name.
func TestSourcesScanPlanted(t *testing.T) {
	dir := t.TempDir()
	goDir := filepath.Join(dir, "planted")
	if err := os.MkdirAll(goDir, 0o755); err != nil {
		t.Fatal(err)
	}
	src := `package planted

import "context"

const plantedPrefix = "planted:"

func helper(db string) string { return "helped:" + db }

func read(ctx context.Context, cursor func(context.Context, string) (int, error), db string, x []string) {
	cursor(ctx, plantedPrefix+db)
	cursor(ctx, helper(db))
	cursor(ctx, x[0])
	forward(ctx, cursor, "pi")
}

func forward(ctx context.Context, cursor func(context.Context, string) (int, error), source string) {
	cursor(ctx, source)
}
`
	if err := os.WriteFile(filepath.Join(goDir, "planted.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(checkGoSources(cursorSites(t, goDir), cursorSources), "\n")
	for _, want := range []string{"asks planted:*", "asks helped:*", "not resolved", "sources.go names amcheck: no collector asks it"} {
		if !strings.Contains(got, want) {
			t.Errorf("the Go scan missed %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "asks pi:") || strings.Contains(got, "asks pi ") {
		t.Errorf("a parameter followed to its caller ('pi') was not resolved to the table's entry:\n%s", got)
	}

	sqlDir := filepath.Join(dir, "sql")
	if err := os.MkdirAll(sqlDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sql1 := `CREATE OR REPLACE FUNCTION pgvigil.import_planted(p int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.mssql_cursor (instance_id, source) VALUES (p, 'planted');
END $$;
CREATE OR REPLACE FUNCTION pgvigil.import_wrapped(p int) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  -- INSERT INTO pgvigil.log_cursor is a comment here
  UPDATE pgvigil.log_cursor SET read_to = now() WHERE instance_id = p;
END $fn$;
`
	sql2 := `DO $$ BEGIN
  ALTER FUNCTION pgvigil.import_wrapped(int) RENAME TO import_wrapped_0001;
END $$;
CREATE OR REPLACE FUNCTION pgvigil.import_wrapped(p int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_wrapped_0001(p);
END $$;
`
	if err := os.WriteFile(filepath.Join(sqlDir, "0001_a.sql"), []byte(sql1), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sqlDir, "0002_b.sql"), []byte(sql2), 0o644); err != nil {
		t.Fatal(err)
	}
	w := cursorWriters(currentBodies(t, sqlDir))
	if len(w["import_wrapped_0001"]) != 1 || w["import_wrapped_0001"][0] != "log_cursor" || len(w["import_wrapped"]) != 0 {
		t.Errorf("the rename was not followed: %v", w)
	}
	probs := strings.Join(checkSQLWriters(w, nil, []string{"import_wrapped_0001", "import_gone"}, nil), "\n")
	for _, want := range []string{"pgvigil.import_planted writes mssql_cursor: no rule", "names pgvigil.import_gone: no current function"} {
		if !strings.Contains(probs, want) {
			t.Errorf("the SQL scan missed %q:\n%s", want, probs)
		}
	}
}
