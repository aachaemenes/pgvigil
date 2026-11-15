package mcp

import (
	"sort"
	"strings"
	"testing"
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
