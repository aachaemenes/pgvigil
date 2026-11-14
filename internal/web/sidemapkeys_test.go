package web

import (
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// emptyImporter hands every import back as an empty package: the side-map check types this package's own files
// alone, so a name from another package has no type (an error the check ignores) and is never a *Server.
type emptyImporter struct{}

var importVersion = regexp.MustCompile(`^v[0-9]+$|\.v[0-9]+$`)

func (emptyImporter) Import(p string) (*types.Package, error) {
	name := path.Base(p)
	if importVersion.MatchString(name) && strings.HasPrefix(name, "v") {
		name = path.Base(path.Dir(p))
	}
	name = importVersion.ReplaceAllString(name, "")
	pkg := types.NewPackage(p, strings.ReplaceAll(name, "-", "_"))
	pkg.MarkComplete()
	return pkg, nil
}

// sideMapKeyMethods take a key as their first argument.
var sideMapKeyMethods = map[string]bool{"Load": true, "Store": true, "LoadOrStore": true, "LoadAndDelete": true, "Delete": true,
	"Swap": true, "CompareAndSwap": true, "CompareAndDelete": true}

// sideMapKeyFindings: every call on a package-level sync.Map of these files whose key is a *Server expression other
// than <x>.self() - Load, Store, LoadOrStore, LoadAndDelete, Delete, Swap, CompareAndSwap and CompareAndDelete by their
// first argument, Range by a key its callback compares (== or !=) with one. It also counts the package-level sync.Maps
// and the calls on them it read, so a walk that finds nothing to read is told apart from a clean one.
func sideMapKeyFindings(fset *token.FileSet, files []*ast.File) (found []string, maps, calls int) {
	info := &types.Info{Types: map[ast.Expr]types.TypeAndValue{}, Defs: map[*ast.Ident]types.Object{}, Uses: map[*ast.Ident]types.Object{}}
	conf := types.Config{Importer: emptyImporter{}, Error: func(error) {}}
	pkg, _ := conf.Check("web", fset, files, info)
	tn, ok := pkg.Scope().Lookup("Server").(*types.TypeName)
	if !ok {
		return []string{"no type Server in the files read"}, 0, 0
	}
	serverPtr := types.NewPointer(tn.Type())
	isServer := func(e ast.Expr) bool { t := info.TypeOf(e); return t != nil && types.Identical(t, serverPtr) }
	isSelf := func(e ast.Expr) bool {
		c, ok := ast.Unparen(e).(*ast.CallExpr)
		if !ok || len(c.Args) != 0 {
			return false
		}
		s, ok := c.Fun.(*ast.SelectorExpr)
		return ok && s.Sel.Name == "self"
	}
	// the package-level vars declared as sync.Map
	syncMaps := map[types.Object]bool{}
	for _, f := range files {
		for _, d := range f.Decls {
			g, ok := d.(*ast.GenDecl)
			if !ok || g.Tok != token.VAR {
				continue
			}
			for _, sp := range g.Specs {
				vs := sp.(*ast.ValueSpec)
				if sel, ok := vs.Type.(*ast.SelectorExpr); ok && sel.Sel.Name == "Map" {
					if x, ok := sel.X.(*ast.Ident); ok && x.Name == "sync" {
						for _, n := range vs.Names {
							if o := info.Defs[n]; o != nil {
								syncMaps[o] = true
							}
						}
					}
				}
			}
		}
	}
	maps = len(syncMaps)
	at := func(n ast.Node, what string) string {
		p := fset.Position(n.Pos())
		return filepath.Base(p.Filename) + ":" + strconv.Itoa(p.Line) + " " + what
	}
	for _, f := range files {
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			m, ok := sel.X.(*ast.Ident)
			if !ok || !syncMaps[info.Uses[m]] {
				return true
			}
			switch {
			case sideMapKeyMethods[sel.Sel.Name] && len(call.Args) > 0:
				calls++
				if k := call.Args[0]; isServer(k) && !isSelf(k) {
					found = append(found, at(call, m.Name+"."+sel.Sel.Name+"("+types.ExprString(k)+")"))
				}
			case sel.Sel.Name == "Range" && len(call.Args) == 1:
				calls++
				fl, ok := call.Args[0].(*ast.FuncLit)
				if !ok || len(fl.Type.Params.List) == 0 || len(fl.Type.Params.List[0].Names) == 0 {
					return true
				}
				key := info.Defs[fl.Type.Params.List[0].Names[0]]
				ast.Inspect(fl.Body, func(b ast.Node) bool {
					be, ok := b.(*ast.BinaryExpr)
					if !ok || (be.Op != token.EQL && be.Op != token.NEQ) {
						return true
					}
					for _, side := range [][2]ast.Expr{{be.X, be.Y}, {be.Y, be.X}} {
						if id, ok := ast.Unparen(side[0]).(*ast.Ident); ok && key != nil && info.Uses[id] == key && isServer(side[1]) && !isSelf(side[1]) {
							found = append(found, at(be, m.Name+".Range: the key compared with "+types.ExprString(side[1])))
						}
					}
					return true
				})
			}
			return true
		})
	}
	return found, maps, calls
}

// TestSideMapsKeyedBySelf (the lead 11:5x; uidoor's least-sure (2) made a check): report mail renders a page through a
// copy of the Server (renderCopy), so every setting serve keeps in a package-level sync.Map keyed by *Server is read and
// written through <x>.self() - the server itself, or the origin of a render's copy. The walk reads the package's own
// source (not its tests) and fails on any other *Server key: a map keyed by s misses on every mailed page, as the six did
// before 4b4b7e4 (uidoor-u7's N6, a product fault of task 171's render). The checker itself first, on the old line
// (doorSets.Load(s)) and its variants: a field, a parameter, Delete, a Range callback's comparison.
// Its limit: it reads a key by its type, so a key that only carries a *Server (inside an interface value or a struct) is not seen.
func TestSideMapsKeyedBySelf(t *testing.T) {
	const old = `package web

import "sync"

type Server struct{ origin *Server }
type holder struct{ s *Server }

func (s *Server) self() *Server { if s.origin != nil { return s.origin }; return s }

var doorSets sync.Map // *Server -> x
var named sync.Map    // string -> x

func (s *Server) oldLoad() { if _, ok := doorSets.Load(s); ok {} }
func (h *holder) field()   { doorSets.Store(h.s, 1) }
func param(srv *Server)    { doorSets.LoadOrStore(srv, 1); doorSets.Delete(srv) }
func (s *Server) rng()     { doorSets.Range(func(k, v any) bool { return k != s }) }
func (s *Server) good(h *holder) {
	doorSets.Load(s.self()); doorSets.Store(h.s.self(), 1); named.Load("x")
	doorSets.Range(func(k, v any) bool { return k == s.self() })
}
`
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "old.go", old, 0)
	if err != nil {
		t.Fatal(err)
	}
	got, maps, calls := sideMapKeyFindings(fset, []*ast.File{f})
	want := []string{"old.go:13 doorSets.Load(s)", "old.go:14 doorSets.Store(h.s)", "old.go:15 doorSets.LoadOrStore(srv)", "old.go:15 doorSets.Delete(srv)",
		"old.go:16 doorSets.Range: the key compared with s"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") || maps != 2 || calls != 9 {
		t.Fatalf("the checker on the old line and its variants: %d maps, %d calls, found\n%s\nwant 2 maps, 9 calls,\n%s", maps, calls, strings.Join(got, "\n"), strings.Join(want, "\n"))
	}

	// the package's own source
	ents, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	fset = token.NewFileSet()
	var files []*ast.File
	for _, e := range ents {
		if n := e.Name(); strings.HasSuffix(n, ".go") && !strings.HasSuffix(n, "_test.go") {
			f, err := parser.ParseFile(fset, n, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			files = append(files, f)
		}
	}
	found, maps, calls := sideMapKeyFindings(fset, files)
	t.Logf("read %d files: %d package-level sync.Maps, %d calls on them", len(files), maps, calls)
	if maps < 6 || calls < 14 {
		t.Errorf("the walk read %d sync.Maps and %d calls on them, want at least the six side maps and their 14 calls: the check reads nothing", maps, calls)
	}
	if len(found) > 0 {
		t.Errorf("a package-level sync.Map keyed by a *Server other than <x>.self() (a render's copy would miss it: key by s.self()):\n%s", strings.Join(found, "\n"))
	}
}
