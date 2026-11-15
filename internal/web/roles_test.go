package web

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// B24f's role gate: every POST of the web server is registered through s.post with its need (anyone, viewer,
// operator, admin), and docs/roles.md's table is the same list. Both checks read the source, so a route added
// without a need fails here, not on a box.

// needNames are the need constants an s.post call may name (roles.go)
var needNames = map[string]string{"needAnyone": "anyone", "needViewer": "viewer", "needOperator": "operator", "needAdmin": "admin"}

// postNeeds reads web.go: each s.post(mux, "POST <path>", <need>, h) registration's pattern and need, and every
// other registration (HandleFunc / Handle) that a role cannot reach: a POST, PUT, PATCH or DELETE pattern, or a
// method-less pattern other than "/" and the "/api/" gate
func postNeeds(t *testing.T) (needs map[string]string, outside []string) {
	t.Helper()
	fset := token.NewFileSet()
	af, err := parser.ParseFile(fset, "web.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	needs = map[string]string{}
	ast.Inspect(af, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		se, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}
		recv, _ := se.X.(*ast.Ident)
		isPost := se.Sel.Name == "post" && recv != nil && recv.Name == "s"
		at := fset.Position(call.Pos()).String()
		if isPost && len(call.Args) != 4 {
			outside = append(outside, at+": s.post with "+strconv.Itoa(len(call.Args))+" arguments")
			return true
		}
		arg := call.Args[0]
		if isPost {
			arg = call.Args[1]
		}
		lit, ok := arg.(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			if isPost {
				outside = append(outside, at+": s.post's pattern is not a string literal")
			}
			return true
		}
		pat, err := strconv.Unquote(lit.Value)
		if err != nil {
			t.Fatalf("%s: %v", fset.Position(lit.Pos()), err)
		}
		switch {
		case isPost:
			id, ok := call.Args[2].(*ast.Ident)
			need := ""
			if ok {
				need = needNames[id.Name]
			}
			switch {
			case !strings.HasPrefix(pat, "POST /"):
				outside = append(outside, at+": s.post of a pattern that is not a POST: "+pat)
			case need == "":
				outside = append(outside, at+": "+pat+" has no need of the four (needAnyone, needViewer, needOperator, needAdmin)")
			case needs[pat] != "":
				outside = append(outside, at+": "+pat+" registered twice")
			default:
				needs[pat] = need
			}
		case se.Sel.Name == "HandleFunc", se.Sel.Name == "Handle":
			method, _, hasMethod := strings.Cut(pat, " ")
			switch {
			case !hasMethod && pat != "/" && pat != "/api/":
				outside = append(outside, at+": a method-less pattern "+pat)
			case hasMethod && method != "GET" && method != "HEAD":
				outside = append(outside, at+": "+pat+" is registered outside s.post")
			}
		}
		return true
	})
	return needs, outside
}

// TestEveryPostHasANeed: no write route escapes the role check
func TestEveryPostHasANeed(t *testing.T) {
	needs, outside := postNeeds(t)
	for _, o := range outside {
		t.Error(o)
	}
	if len(needs) == 0 {
		t.Error("no POST is registered through s.post")
	}
}

// docRow is a line of docs/roles.md's table: | `POST /api/...` | <need> | <what> |
var docRow = regexp.MustCompile("^\\|\\s*`(POST /[^`]+)`\\s*\\|\\s*(anyone|viewer|operator|admin)\\s*\\|")

// TestRolesDocMatches: docs/roles.md's table names every s.post route with its need, and nothing else
func TestRolesDocMatches(t *testing.T) {
	needs, _ := postNeeds(t)
	b, err := os.ReadFile("../../docs/roles.md")
	if err != nil {
		t.Fatalf("docs/roles.md: %v", err)
	}
	doc := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if m := docRow.FindStringSubmatch(strings.TrimSpace(l)); m != nil {
			if doc[m[1]] != "" {
				t.Errorf("docs/roles.md names %s twice", m[1])
			}
			doc[m[1]] = m[2]
		}
	}
	var keys []string
	for k := range needs {
		keys = append(keys, k)
	}
	for k := range doc {
		if _, ok := needs[k]; !ok {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		switch code, docs := needs[k], doc[k]; {
		case code == "":
			t.Errorf("docs/roles.md names %s (%s), which web.go does not register through s.post", k, docs)
		case docs == "":
			t.Errorf("%s (%s in web.go) is not in docs/roles.md's table", k, code)
		case code != docs:
			t.Errorf("%s: web.go says %s, docs/roles.md says %s", k, code, docs)
		}
	}
}
