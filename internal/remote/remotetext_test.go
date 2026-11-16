package remote

import (
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

var (
	keyTextRE   = regexp.MustCompile(`->>'([A-Za-z0-9_]+)'(\s*\)\s*::\s*(timestamptz|timestamp|integer|int|bigint|smallint|boolean|bool|numeric|float8|real|double precision|uuid|date|interval|inet|jsonb))?`)
	keyJSONRE   = regexp.MustCompile(`->'([A-Za-z0-9_]+)'`)
	keyHasRE    = regexp.MustCompile(`\?\s*'([A-Za-z0-9_]+)'`)
	recordsetRE = regexp.MustCompile(`(?s)jsonb_to_recordset\([^)]*\)\s+AS\s+\w+\s*\(([^)]*)\)`)
	callRE      = regexp.MustCompile(`(?s)pgvigil\.([a-z0-9_]+)\(([^;]*?)\)`)
	payloadArg  = regexp.MustCompile(`p_payload|v_rows|v_db\b|\br\b`)
)

// importKeys is every payload key a function reads (and the functions it calls with the payload or a row of it), each
// with how: a non-text cast's type, "text", "json" (->) or "has" (?).
func importKeys(bodies map[string]string, fn string, seen map[string]bool, out map[string]map[string]bool) {
	if seen[fn] {
		return
	}
	seen[fn] = true
	b, ok := bodies[fn]
	if !ok {
		return
	}
	add := func(k, how string) {
		if out[k] == nil {
			out[k] = map[string]bool{}
		}
		out[k][how] = true
	}
	for _, m := range keyTextRE.FindAllStringSubmatch(b, -1) {
		how := "text"
		if m[3] != "" {
			how = m[3]
		}
		add(m[1], how)
	}
	for _, m := range keyJSONRE.FindAllStringSubmatch(b, -1) {
		add(m[1], "json")
	}
	for _, m := range keyHasRE.FindAllStringSubmatch(b, -1) {
		add(m[1], "has")
	}
	for _, m := range recordsetRE.FindAllStringSubmatch(b, -1) {
		for _, col := range strings.Split(m[1], ",") {
			if f := strings.Fields(col); len(f) >= 2 {
				how := f[1]
				add(f[0], how)
			}
		}
	}
	for _, m := range callRE.FindAllStringSubmatch(b, -1) {
		if payloadArg.MatchString(m[2]) && m[1] != "mssql_rows" && m[1] != "ensure_month_partition" && m[1] != "mssql_event_partition" {
			importKeys(bodies, m[1], seen, out)
		}
	}
}

// remoteViews are the registries' collections: every one a remote collector can run.
func remoteViews() []string {
	seen := map[string]bool{}
	var out []string
	for _, c := range collect.All() {
		seen[c.Name()] = true
	}
	for _, c := range mssql.All() {
		seen[c.Name()] = true
	}
	for v := range seen {
		out = append(out, v)
	}
	sort.Strings(out)
	return out
}

// The deny-by-default lists against the hub's import functions (task 10's row): every view a collector can run has its
// list; each key its import reads with a non-text cast passes (hashing it would break the import); each key read as text
// or JSON is either listed to pass or a reviewed text key, never both; a listed key the import never reads is stale.
func TestRemoteTextCoversTheImports(t *testing.T) {
	bodies := currentBodies(t, "../repo/sql")
	views := remoteViews()
	if len(views) < 100 {
		t.Fatalf("only %d views in the registries", len(views))
	}
	for _, v := range views {
		pass, ok := collect.RemotePassList(v)
		if !ok {
			t.Errorf("%s: no remote text list (collect/remotetext_pass.go)", v)
			continue
		}
		keys := map[string]map[string]bool{}
		importKeys(bodies, "import_"+v, map[string]bool{}, keys)
		if _, exists := bodies["import_"+v]; !exists {
			t.Errorf("%s: no pgvigil.import_%s", v, v)
			continue
		}
		if len(keys) == 0 && len(pass) > 0 {
			t.Errorf("%s: pgvigil.import_%s reads no payload key, so its list passes nothing: it lists %v", v, v, pass)
		}
		listed := map[string]bool{}
		for _, k := range pass {
			listed[k] = true
			if collect.RemoteTextKey(v, k) {
				t.Errorf("%s: %s is both listed to pass and a text key", v, k)
			}
			if keys[k] == nil {
				t.Errorf("%s: lists %s, which pgvigil.import_%s never reads", v, k, v)
			}
		}
		for k, hows := range keys {
			typed := false
			for h := range hows {
				if h != "text" && h != "json" && h != "has" {
					typed = true
				}
			}
			switch {
			case typed && !listed[k]:
				t.Errorf("%s: pgvigil.import_%s casts %s (%v): it must pass", v, v, k, hows)
			case !listed[k] && !collect.RemoteTextKey(v, k):
				t.Errorf("%s: pgvigil.import_%s reads %s as %v: list it to pass or class it as text", v, v, k, hows)
			}
		}
	}
}
