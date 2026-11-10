package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// fakeAPI answers the API paths the tools read with fixed tables; every request is recorded.
func fakeAPI(t *testing.T, seen *[]string) http.Handler {
	t.Helper()
	tbl := func(cols []string, rows ...[]any) map[string]any {
		if rows == nil {
			rows = [][]any{}
		}
		return map[string]any{"columns": cols, "rows": rows}
	}
	answers := map[string]any{
		"/api/instances": tbl([]string{"instance_id", "name"}, []any{1, "Alpha"}, []any{2, "beta"}),
		"/api/overview": tbl([]string{"severity", "instance", "instance_id", "check_name", "object", "at", "detail", "check_group"},
			[]any{"critical", "Alpha", 1, "stale", "x", "t", "d", "g"}, []any{"warning", "beta", 2, "bloat", "y", "t", "d", "g"}),
		"/api/findings": tbl([]string{"setting", "value"}, []any{"work_mem", "4MB"}),
		"/api/activity": map[string]any{"snapshot_at": "2026-11-09T10:00:00Z",
			"summary": tbl([]string{"instance_id", "total"}, []any{1, 5}),
			"chains":  tbl([]string{"pid", "head_pid", "depth"}, []any{11, 10, 1}, []any{12, 10, 2})},
		"/api/statements": tbl([]string{"queryid", "query"}, []any{"9007199254740993", "select 1"},
			[]any{"1", "UPDATE users SET password = $1 WHERE id = $2"}, []any{"2", "ALTER ROLE x PASSWORD 'p\"a<s>s'"},
			[]any{"3", `select 'pa"ss<w>rd\x' as leaked`}),
		"/api/tables": map[string]any{
			"databases": tbl([]string{"datname", "user_tables"}, []any{"app", 3}, []any{"hr", 2}),
			"tables": tbl([]string{"datname", "schema_name", "table_name"},
				[]any{"app", "public", "orders"}, []any{"hr", "public", "orders"}, []any{"app", "public", "items"})},
		"/api/storage/fleet": map[string]any{"volumes": tbl([]string{"volume"}, []any{"/data"}), "repository": tbl([]string{"bytes"}, []any{1})},
		"/api/storage": map[string]any{"volumes": tbl([]string{"volume"}), "databases": tbl([]string{"d"}), "tables": tbl([]string{"t"}),
			"checks": tbl([]string{"c"}), "series": tbl([]string{"s"})},
		"/api/plan":  map[string]any{"plan": tbl([]string{"plan_id", "plan_text"}, []any{7, "Seq Scan"}), "hits": tbl([]string{"rule"}, []any{"seq scan"}), "buttons": map[string]any{"explain": false}},
		"/api/plans": map[string]any{"plans": tbl([]string{"plan_id"}, []any{7}), "buttons": map[string]any{}},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*seen = append(*seen, r.Method+" "+r.URL.String())
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			_, _ = w.Write([]byte(`{"error":"method"}`))
			return
		}
		if r.URL.Path == "/api/findings" && r.URL.Query().Get("instance") == "2" {
			w.WriteHeader(http.StatusInternalServerError) // an error that carries the password
			_, _ = w.Write([]byte(`{"error":"connect failed: password=s3cret-pw host=x postgres://u:s3cret-pw@h/db"}`))
			return
		}
		v, ok := answers[r.URL.Path]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"no such endpoint"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(v)
	})
}

// exchange runs the lines through Serve and returns the replies by id (and how many there were).
func exchange(t *testing.T, s *Server, lines ...string) (map[string]map[string]any, int, string) {
	t.Helper()
	var out bytes.Buffer
	if err := s.Serve(context.Background(), strings.NewReader(strings.Join(lines, "\n")+"\n"), &out); err != nil {
		t.Fatalf("serve: %v", err)
	}
	got := map[string]map[string]any{}
	n := 0
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if l == "" {
			continue
		}
		n++
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("reply is not JSON: %q", l)
		}
		got[string(mustJSON(m["id"]))] = m
	}
	return got, n, out.String()
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func text(t *testing.T, m map[string]any) (string, bool) {
	t.Helper()
	r, ok := m["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result: %v", m)
	}
	c := r["content"].([]any)[0].(map[string]any)
	return c["text"].(string), r["isError"].(bool)
}

func call(id int, name, args string) string {
	return `{"jsonrpc":"2.0","id":` + string(mustJSON(id)) + `,"method":"tools/call","params":{"name":"` + name + `","arguments":` + args + `}}`
}

func TestProtocol(t *testing.T) {
	var seen []string
	s := New(fakeAPI(t, &seen), "test", "s3cret-pw")
	got, n, _ := exchange(t, s,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":"p","method":"ping"}`,
		`{"jsonrpc":"2.0","id":4,"method":"resources/write"}`,
		`not json`,
		`[{"jsonrpc":"2.0","id":5,"method":"ping"}]`,
		call(6, "run_sql", `{"sql":"drop table x"}`),
		``)
	if n != 8 { // the notification and the blank line get no reply
		t.Fatalf("replies = %d, want 8: %v", n, got)
	}
	if v := got["1"]["result"].(map[string]any)["protocolVersion"]; v != "2025-03-26" {
		t.Errorf("a supported version is echoed: got %v", v)
	}
	if v := got["2"]["result"].(map[string]any)["protocolVersion"]; v != ProtocolVersions[0] {
		t.Errorf("an unknown version gets the newest: got %v", v)
	}
	list := got["3"]["result"].(map[string]any)["tools"].([]any)
	if len(list) != 7 {
		t.Errorf("tools = %d, want 7", len(list))
	}
	for _, x := range list {
		a := x.(map[string]any)["annotations"].(map[string]any)
		if a["readOnlyHint"] != true || a["destructiveHint"] != false {
			t.Errorf("%v: not marked read-only", x.(map[string]any)["name"])
		}
	}
	if got[`"p"`]["result"] == nil {
		t.Errorf("ping: %v", got[`"p"`])
	}
	if e := got["4"]["error"].(map[string]any); e["code"].(float64) != codeMethodNotFound {
		t.Errorf("unknown method: %v", e)
	}
	if e := got["6"]["error"].(map[string]any); e["code"].(float64) != codeInvalidParams || !strings.Contains(e["message"].(string), "read-only") {
		t.Errorf("unknown tool: %v", e)
	}
	nulls := got["null"]
	if nulls == nil {
		t.Errorf("parse error and batch replies carry id null")
	}
	for _, r := range seen {
		if !strings.HasPrefix(r, "GET ") {
			t.Errorf("a tool sent %s: only GET is allowed", r)
		}
	}
}

func TestTools(t *testing.T) {
	var seen []string
	s := New(fakeAPI(t, &seen), "test", "s3cret-pw", `pa"ss<w>rd\x`)
	got, _, raw := exchange(t, s,
		call(1, "fleet_summary", `{"severity":"critical"}`),
		call(2, "instance_findings", `{"instance":"alpha"}`),
		call(3, "blocking_chain", `{"instance":1,"at":"2026-11-09T10:00:00Z"}`),
		call(4, "top_statements", `{"instance":"beta","hours":6,"limit":5,"order":"io"}`),
		call(5, "plan_findings", `{"plan_id":7}`),
		call(6, "plan_findings", `{"instance":"Alpha"}`),
		call(7, "table_state", `{"instance":"Alpha","table":"orders"}`),
		call(8, "table_state", `{"instance":"Alpha","table":"public.orders","database":"hr"}`),
		call(9, "storage_forecast", `{}`),
		call(10, "storage_forecast", `{"instance":"beta"}`),
		call(11, "instance_findings", `{"instance":"beta"}`),
		call(12, "top_statements", `{"instance":"nope"}`),
		call(13, "top_statements", `{"instance":"Alpha","limit":1000}`),
		call(14, "fleet_summary", `{"sql":"x"}`),
		call(15, "blocking_chain", `{"instance":"Alpha","at":"yesterday"}`),
	)
	want := map[string]struct {
		err  bool
		has  []string
		hasn []string
	}{
		"1":  {has: []string{`"critical": 1`, `"stale"`}, hasn: []string{`"bloat"`}},
		"2":  {has: []string{`"work_mem"`, `"stale"`, `"name": "Alpha"`}},
		"3":  {has: []string{`"heads": 1`, `"head_pid": 10`, `"total": 5`}},
		"4":  {has: []string{`"order": "io"`, `"9007199254740993"`, `password = $1 WHERE`, `select '[redacted]' as leaked`}},
		"5":  {has: []string{`"Seq Scan"`, `"seq scan"`}, hasn: []string{"buttons"}},
		"6":  {has: []string{`"plan_id": 7`}},
		"7":  {has: []string{"more than one table matched", "app.public.orders", "hr.public.orders"}},
		"8":  {has: []string{`"datname": "hr"`}, hasn: []string{"more than one", `"datname": "app"`}},
		"9":  {has: []string{`"/data"`, `"repository"`}},
		"10": {has: []string{`"checks"`}, hasn: []string{"series"}},
		"11": {err: true, has: []string{"[redacted]"}},
		"12": {err: true, has: []string{"no active instance", "Alpha, beta"}},
		"13": {err: true, has: []string{"limit must be"}},
		"14": {err: true, has: []string{"takes no argument"}},
		"15": {err: true, has: []string{"RFC 3339"}},
	}
	for id, w := range want {
		m, ok := got[id]
		if !ok {
			t.Errorf("%s: no reply", id)
			continue
		}
		txt, isErr := text(t, m)
		if isErr != w.err {
			t.Errorf("%s: isError = %v, want %v: %s", id, isErr, w.err, txt)
		}
		for _, h := range w.has {
			if !strings.Contains(txt, h) {
				t.Errorf("%s: missing %q in %s", id, h, txt)
			}
		}
		for _, h := range w.hasn {
			if strings.Contains(txt, h) {
				t.Errorf("%s: unexpected %q in %s", id, h, txt)
			}
		}
	}
	// every line parses, and no form of either password is in it (raw, escaped once, escaped twice)
	for _, l := range strings.Split(strings.TrimSpace(raw), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Errorf("a reply line does not parse: %v: %s", err, l)
		}
	}
	for _, pw := range []string{"s3cret-pw", `pa"ss<w>rd\x`} {
		once := string(mustJSON(pw))
		twice := string(mustJSON(once))
		for _, form := range []string{pw, once[1 : len(once)-1], twice[1 : len(twice)-1], "pa\\\"ss", "ss\\u003cw"} {
			if strings.Contains(raw, form) {
				t.Errorf("a form of the password reached the client: %q", form)
			}
		}
	}
	var stmts string
	for _, r := range seen {
		if strings.Contains(r, "/api/statements") {
			stmts = r
		}
	}
	if !strings.Contains(stmts, "instance=2") || !strings.Contains(stmts, "limit=5") || !strings.Contains(stmts, "order=io") {
		t.Errorf("statements request: %s", stmts)
	}
}

func TestLimitAndScrub(t *testing.T) {
	s := New(http.NotFoundHandler(), "test", "pw12345", "ab") // "ab" is too short to scrub
	s.MaxRows, s.MaxText = 2, 5
	rows := []map[string]any{{"q": "abcdefgh"}, {"q": "x"}, {"q": "y"}}
	v := s.limit(map[string]any{"rows": rows}).(map[string]any)
	if len(v["rows"].([]map[string]any)) != 2 || v["rows_cut"] != "2 of 3 rows shown" {
		t.Errorf("cut: %v", v)
	}
	if q := v["rows"].([]map[string]any)[0]["q"]; q != "abcde ... [cut at 5 of 8 characters]" {
		t.Errorf("text cut: %v", q)
	}
	for in, want := range map[string]string{
		"dsn host=h password=pw12345 user=u": "dsn host=h password=[redacted] user=u",
		"SET password = $1, x = 2":           "SET password = $1, x = 2",
		"password=abc\nnext line":            "password=[redacted]\nnext line",
		"x pw12345 y ab":                     "x [redacted] y ab",
		"postgresql://u:other@h/db":          "postgresql://u:[redacted]@h/db",
		"PASSWORD = 'a b' end":               "PASSWORD = [redacted] end",
	} {
		if got := s.scrub(in); got != want {
			t.Errorf("scrub(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLongLine(t *testing.T) {
	s := New(http.NotFoundHandler(), "test")
	var out bytes.Buffer
	in := strings.Repeat("x", MaxLine+10) + "\n" + `{"jsonrpc":"2.0","id":9,"method":"ping"}` // the last line has no newline
	err := s.Serve(context.Background(), strings.NewReader(in), &out)
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if err != nil || len(lines) != 2 || !strings.Contains(lines[0], "request line over") || !strings.Contains(lines[1], `"id":9`) {
		t.Errorf("a long line is refused and the session goes on: err %v, out %q", err, out.String())
	}
}
