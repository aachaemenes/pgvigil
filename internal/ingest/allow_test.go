package ingest

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// neverReachable: the import functions a bundle may never call (R9): the collector's own health, the alerts, the
// actions' log, the DBA Dash door, the remote ledgers, and the SQL Server cursor a hub keeps itself.
var neverReachable = []string{"mssql_cursor", "collector_", "alert_", "actions_log", "dbadash_", "remote_"}

// TestAllowListCoversEveryStoreCall (H3): every collection name a collector hands to its store's Import is a view a
// bundle may carry - the registries' names (collect.Names, mssql.Names: the variable 'name' at the call sites) and
// every constant name at a call site (resolved: mssql.Prefix + a literal) - and no never-reachable name is.
func TestAllowListCoversEveryStoreCall(t *testing.T) {
	allow := AllowList()
	for _, n := range append(collect.Names(), mssql.Names()...) {
		if !allow[n] {
			t.Errorf("registry collection %q is not on the allow-list", n)
		}
	}
	fset := token.NewFileSet()
	consts := 0
	for _, dir := range []string{"../collect", "../mssql", "../engines"} {
		files, _ := filepath.Glob(filepath.Join(dir, "*.go"))
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			af, err := parser.ParseFile(fset, f, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			ast.Inspect(af, func(n ast.Node) bool {
				ce, ok := n.(*ast.CallExpr)
				if !ok || len(ce.Args) < 3 {
					return true
				}
				se, ok := ce.Fun.(*ast.SelectorExpr)
				if !ok || se.Sel.Name != "Import" {
					return true
				}
				name, isConst := constName(ce.Args[2])
				switch {
				case isConst:
					consts++
					if !allow[name] {
						t.Errorf("%s: Import's collection %q is not on the allow-list", fset.Position(ce.Pos()), name)
					}
				case !isRegistryVar(ce.Args[2]):
					t.Errorf("%s: Import's collection is neither a constant nor a registry name: say where it comes from in this row", fset.Position(ce.Pos()))
				}
				return true
			})
		}
	}
	if consts == 0 {
		t.Errorf("no constant collection name found at a call site (ag.go's hadr thresholds is one): the scan reads nothing")
	}
	for n := range allow {
		for _, p := range neverReachable {
			if n == p || strings.HasPrefix(n, p) && strings.HasSuffix(p, "_") {
				t.Errorf("the allow-list holds %q, which a bundle may never reach", n)
			}
		}
	}
}

// constName resolves a string literal or mssql.Prefix (written Prefix inside the package) + a literal.
func constName(e ast.Expr) (string, bool) {
	switch x := e.(type) {
	case *ast.BasicLit:
		s, err := strconv.Unquote(x.Value)
		return s, err == nil
	case *ast.BinaryExpr:
		l, ok := x.X.(*ast.Ident)
		r, ok2 := x.Y.(*ast.BasicLit)
		if ok && ok2 && x.Op == token.ADD && l.Name == "Prefix" {
			s, err := strconv.Unquote(r.Value)
			return mssql.Prefix + s, err == nil
		}
	}
	return "", false
}

// isRegistryVar: the call sites that pass a registry collector's own name ('name', 'c.Name()')
func isRegistryVar(e ast.Expr) bool {
	switch x := e.(type) {
	case *ast.Ident:
		return x.Name == "name"
	case *ast.CallExpr:
		if se, ok := x.Fun.(*ast.SelectorExpr); ok {
			return se.Sel.Name == "Name"
		}
	}
	return false
}
