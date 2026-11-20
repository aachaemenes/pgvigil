package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// The agent door's tools appear only with the door: the reader's server lists its nine, the agent's sixteen, and the
// four that write their investigation record say so in their annotations.
func TestAgentToolsOnlyWithTheDoor(t *testing.T) {
	r := New(nil, "test")
	if n := len(listOf(r.served())); n != len(tools()) {
		t.Fatalf("the reader's server lists %d tools, want %d", n, len(tools()))
	}
	if _, ok := findTool(r.served(), "claim_investigation"); ok {
		t.Fatal("the reader's server serves claim_investigation")
	}
	a := New(nil, "test").WithAgent(&AgentDoor{})
	var names, writes []string
	for _, x := range listOf(a.served()) {
		m := x.(map[string]any)
		names = append(names, m["name"].(string))
		if !m["annotations"].(map[string]any)["readOnlyHint"].(bool) {
			writes = append(writes, m["name"].(string))
		}
	}
	if len(names) != len(tools())+7 {
		t.Fatalf("the agent's server lists %d tools: %v", len(names), names)
	}
	sort.Strings(writes)
	if got := strings.Join(writes, ","); got != "claim_investigation,release_investigation,renew_investigation,report_investigation" {
		t.Fatalf("the tools marked as writing: %s", got)
	}
}

// next_calls: instance_findings first for a finding; the area's tools by the setting's name; a fleet question starts
// at fleet_summary.
func TestNextCalls(t *testing.T) {
	tools := func(l []any) string {
		var n []string
		for _, x := range l {
			n = append(n, x.(map[string]any)["tool"].(string))
		}
		return strings.Join(n, ",")
	}
	for _, c := range []struct {
		req  map[string]any
		want string
	}{
		{map[string]any{"kind": "finding", "instance": "db1", "setting": "blocking_sessions"}, "instance_findings,blocking_chain"},
		{map[string]any{"kind": "finding", "instance": "db1", "setting": "work_mem"}, "instance_findings,top_statements,plan_findings"},
		{map[string]any{"kind": "finding", "instance": "db1", "setting": "autovacuum_dead_tuples"}, "instance_findings,storage_forecast"},
		{map[string]any{"kind": "finding", "instance": "db1", "setting": "amcheck"}, "instance_findings"},
		{map[string]any{"kind": "ask", "instance": nil}, "fleet_summary,run_select"},
		{map[string]any{"kind": "ask", "instance": "db1", "setting": nil}, "instance_findings,run_select"},
	} {
		if got := tools(nextCalls(c.req)); got != c.want {
			t.Errorf("%v: %s, want %s", c.req, got, c.want)
		}
	}
}

// The wait's keys: '<id>:<claims>' for each open request; a request whose claim count grew (it opened again after a
// lapsed or released claim) is new; a bare id in known matches its request at any count.
func TestOpenKeys(t *testing.T) {
	open := []any{map[string]any{"id": json.Number("7"), "claims": json.Number("0")}, map[string]any{"id": json.Number("9"), "claims": json.Number("1")}}
	keys, fresh := openKeys(open, map[string]bool{})
	if got, _ := json.Marshal(keys); string(got) != `["7:0","9:1"]` || !fresh {
		t.Fatalf("nothing known: %s, fresh %v", got, fresh)
	}
	if _, fresh := openKeys(open, map[string]bool{"7:0": true, "9:1": true}); fresh {
		t.Fatal("both known: fresh")
	}
	if _, fresh := openKeys(open, map[string]bool{"7:0": true, "9:0": true}); !fresh {
		t.Fatal("9 opened again (claims 0 -> 1): not fresh")
	}
	if _, fresh := openKeys(open, map[string]bool{"7": true, "9": true}); fresh {
		t.Fatal("bare ids: fresh")
	}
	if keys, fresh := openKeys(nil, map[string]bool{"7:0": true}); fresh || len(keys) != 0 {
		t.Fatalf("no open request: %v, fresh %v", keys, fresh)
	}
}

type sentNothing struct{}

func (sentNothing) Error() string     { return "dial: nothing sent" }
func (sentNothing) SafeToRetry() bool { return true }

// The retry rule: a write is sent again only when it never ran (nothing sent, or the server's own error ended the
// session); a connection that closed after the send leaves a write's outcome unknown.
func TestUnsent(t *testing.T) {
	for _, c := range []struct {
		err  error
		want bool
	}{
		{sentNothing{}, true},
		{&pgconn.PgError{Code: "57P01", Message: "terminating connection due to administrator command"}, true},
		{&pgconn.PgError{Code: "08006", Message: "connection failure"}, true},
		{&pgconn.PgError{Code: "40001", Message: "could not serialize"}, false},
		{errors.New("unexpected EOF"), false},
		{context.DeadlineExceeded, false},
	} {
		if got := unsent(c.err); got != c.want {
			t.Errorf("unsent(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

// An unknown tool on the agent's door is not told the server has no tool that writes or runs SQL.
func TestUnknownToolWithTheDoor(t *testing.T) {
	a := New(nil, "test").WithAgent(&AgentDoor{})
	_, e := a.call(context.Background(), json.RawMessage(`{"name":"drop_everything","arguments":{}}`))
	if e == nil || strings.Contains(e.Message, "pgvigil mcp is read-only") || !strings.Contains(e.Message, "run_select runs one read-only SELECT") {
		t.Fatalf("the agent door's unknown tool: %+v", e)
	}
}
