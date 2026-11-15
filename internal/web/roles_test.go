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

// ---- the pages (review-16 S6 / S8): a write control carries its route's need and is off below it with the server's
// words. The pages' table of needs (web/src/needs.ts routeNeeds) is the server's, and every page file that posts to a
// route above viewer names that route's need. Both checks read the source.

// pageNeedRow is a line of web/src/needs.ts's routeNeeds table:   'ack/end': ['operator', 'ending an acknowledgement'],
var pageNeedRow = regexp.MustCompile(`^\s*'([a-z_/]+)':\s*\['(operator|admin)',\s*(?:'([^']*)'|"([^"]*)")\],\s*$`)

// pageNeeds reads the table: route (as api.post names it) -> need, what
func pageNeeds(t *testing.T) map[string][2]string {
	t.Helper()
	b, err := os.ReadFile("../../web/src/needs.ts")
	if err != nil {
		t.Fatalf("web/src/needs.ts: %v", err)
	}
	out := map[string][2]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if m := pageNeedRow.FindStringSubmatch(l); m != nil {
			if _, twice := out[m[1]]; twice {
				t.Errorf("web/src/needs.ts names %s twice", m[1])
			}
			out[m[1]] = [2]string{m[2], m[3] + m[4]}
		}
	}
	return out
}

// TestPageNeedsMatch: the pages' table names every s.post route above viewer with its need and the refusal's own
// words (routeWhat), and nothing else
func TestPageNeedsMatch(t *testing.T) {
	needs, _ := postNeeds(t)
	page := pageNeeds(t)
	if len(page) == 0 {
		t.Fatal("web/src/needs.ts: no route in routeNeeds")
	}
	var pats []string
	for p := range needs {
		pats = append(pats, p)
	}
	sort.Strings(pats)
	for _, p := range pats {
		need, route := needs[p], strings.TrimPrefix(p, "POST /api/")
		row, ok := page[route]
		switch {
		case need != "operator" && need != "admin":
			if ok {
				t.Errorf("web/src/needs.ts names %s (%s), which needs only %s in web.go", route, row[0], need)
			}
		case !ok:
			t.Errorf("%s (%s in web.go) is not in web/src/needs.ts's routeNeeds", p, need)
		case row[0] != need:
			t.Errorf("%s: web.go says %s, web/src/needs.ts says %s", p, need, row[0])
		case row[1] != routeWhat[p]:
			t.Errorf("%s: roles.go says %q, web/src/needs.ts says %q", p, routeWhat[p], row[1])
		}
	}
	for route, row := range page {
		if needs["POST /api/"+route] == "" {
			t.Errorf("web/src/needs.ts names %s (%s), which web.go does not register through s.post", route, row[0])
		}
	}
}

// the routes a page file posts to that its source does not spell as post('<route>', ...): a route built at run time,
// a POST through the file's own fetch, a write through ack.ts's addAck / endAck
var (
	pagePostLit  = regexp.MustCompile(`\bpost(?:<.*?>)?\(\s*'([a-z_/]+)'\s*[,)]`)
	pagePostAny  = regexp.MustCompile(`\bpost(?:<.*?>)?\(`)
	pageRawPost  = regexp.MustCompile(`method:\s*'POST'`)
	pageOtherRts = map[string][]string{
		"actions.ts":         {"actions/cancel", "actions/terminate"},
		"jobs_running.ts":    {"jobs/actions/stop", "jobs/actions/start"},
		"plan.ts":            {"plans/explain", "plans/analyze"},
		"admin_instances.ts": {"admin/instances", "admin/sources", "admin/proposals"},
		"migrate.ts":         {"admin/dbadash_moves"},
		"applications.ts":    {"admin/applications", "admin/applications/contacts", "admin/applications/assign", "admin/applications/routes"},
		"app_import.ts":      {"admin/applications/import"},
		"uptimedialog.ts":    {"pg/thresholds"},
		"pg_backups.ts":      {"pg/thresholds"},
	}
)

// TestPagesNameTheirNeeds: every page file that writes names the need of each route it posts to - through
// needControl, markNeed or routeWhy with the route, a route: option of a helper that does, the route handed to such a
// helper as an argument (the file spells it once more than it posts to it), or (a page that is read only as a whole
// below its need) data-need set to that need. A POST the file builds another way is listed above, and a file with one
// that is not listed fails here.
func TestPagesNameTheirNeeds(t *testing.T) {
	needs, _ := postNeeds(t)
	files, err := os.ReadDir("../../web/src")
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, f := range files {
		name := f.Name()
		if !strings.HasSuffix(name, ".ts") || name == "api.ts" || name == "needs.ts" || name == "main.ts" {
			continue // api.ts is post itself; main.ts posts login and logout (anyone)
		}
		b, err := os.ReadFile("../../web/src/" + name)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		routes := map[string]bool{}
		for _, m := range pagePostLit.FindAllStringSubmatch(src, -1) {
			routes[m[1]] = true
		}
		other := len(pagePostAny.FindAllString(src, -1))-len(pagePostLit.FindAllString(src, -1)) > 0 || pageRawPost.MatchString(src)
		if name == "migrate.ts" {
			other = true // its own post() wraps a fetch of one route
		}
		if other && pageOtherRts[name] == nil {
			t.Errorf("web/src/%s posts to a route its source does not spell as post('<route>'): list its routes in pageOtherRts", name)
		}
		for _, r := range pageOtherRts[name] {
			routes[r] = true
		}
		if name != "ack.ts" {
			if strings.Contains(src, "addAck(") {
				routes["ack"] = true
			}
			if strings.Contains(src, "endAck(") {
				routes["ack/end"] = true
			}
		}
		for r := range routes {
			need, ok := needs["POST /api/"+r]
			if !ok {
				t.Errorf("web/src/%s posts to %s, which web.go does not register", name, r)
				continue
			}
			if need != "operator" && need != "admin" {
				continue
			}
			seen++
			q := regexp.QuoteMeta("'" + r + "'")
			marked := regexp.MustCompile(`(needControl|markNeed|routeWhy)\([^\n]*`+q).MatchString(src) ||
				regexp.MustCompile(`\broute: [^\n]*`+q).MatchString(src) ||
				strings.Contains(src, "dataset.need = '"+need+"'")
			// a route the file posts to by its literal and hands to a helper as an argument: spelled once more than
			// posted. Never for a route built at run time or written through addAck / endAck (no post literal): 'ack'
			// and a route's parts are words a file may hold for other reasons (roles-red2 counted them as named).
			if posted := len(regexp.MustCompile(`\bpost(?:<.*?>)?\(\s*`+q).FindAllString(src, -1)); !marked && posted > 0 {
				marked = strings.Count(src, "'"+r+"'") > posted
			}
			if !marked {
				t.Errorf("web/src/%s posts to %s (%s) and names its need nowhere: needControl / markNeed / routeWhy with '%s'", name, r, need, r)
			}
		}
	}
	if seen == 0 {
		t.Error("no page file posts to a route above viewer: the check read nothing")
	}
}
