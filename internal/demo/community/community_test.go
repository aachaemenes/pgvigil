package community

import (
	"strings"
	"testing"
)

// The stored samples: each decodes, names its own tool, kit, version, capture date and test server, holds rows, and
// holds nothing the deny-list names (the generic words always; the environment's own words when DenyEnv is set, as
// the capture and the box runs set it); together they stay under MaxBytes.
func TestStoredSamples(t *testing.T) {
	tools := Tools()
	if len(tools) == 0 {
		t.Log("no stored sample in this tree")
	}
	extra := EnvDeny()
	if len(extra) == 0 {
		t.Logf("%s is not set: the generic deny-list only (the capture machine's own names are checked where it is set)", DenyEnv)
	}
	total := 0
	for _, tool := range tools {
		gz, text, err := Raw(tool)
		if err != nil {
			t.Fatalf("%s: %v", tool, err)
		}
		total += len(gz)
		s, err := Get(tool)
		if err != nil {
			t.Fatalf("%s: %v", tool, err)
		}
		switch {
		case s.Tool != tool:
			t.Errorf("%s: the file holds %q", tool, s.Tool)
		case s.Engine != "sqlserver" && s.Engine != "postgres":
			t.Errorf("%s: engine %q", tool, s.Engine)
		case s.Kit == "" || s.Version == "" || s.Server == "" || s.CapturedAt.IsZero():
			t.Errorf("%s: kit %q, version %q, server %q, captured %v: each is said in the sample's line", tool, s.Kit, s.Version, s.Server, s.CapturedAt)
		case s.Rows() == 0:
			t.Errorf("%s: no rows (a sample without rows is not a sample)", tool)
		}
		for i, set := range s.Sets {
			if len(set.Types) != len(set.Columns) {
				t.Errorf("%s set %d: %d types for %d columns", tool, i+1, len(set.Types), len(set.Columns))
			}
			for _, c := range set.Columns {
				if strings.Contains(strings.ToLower(c), "query_plan") {
					for _, row := range set.Rows {
						if v, ok := row[indexOf(set.Columns, c)].(string); ok && strings.Contains(v, "<ShowPlanXML") {
							t.Errorf("%s set %d: plan XML in %s", tool, i+1, c)
							break
						}
					}
				}
			}
		}
		if hits := Deny(text, extra); len(hits) > 0 {
			t.Errorf("%s holds what no sample may hold: %s", tool, strings.Join(hits, "; "))
		}
		if s.Kit == "sp_WhoIsActive" {
			for _, p := range s.ParamDoc {
				if p.Help != "" {
					t.Errorf("%s: help text of sp_WhoIsActive's %s stored (its own text is GPL: never stored)", tool, p.Name)
				}
			}
		}
	}
	if total > MaxBytes {
		t.Errorf("the stored samples are %d bytes, over the cap of %d", total, MaxBytes)
	}
	t.Logf("%d stored samples, %d bytes", len(tools), total)
}

func indexOf(xs []string, x string) int {
	for i, v := range xs {
		if v == x {
			return i
		}
	}
	return -1
}

// The deny-list itself: an address is found, a version number is not; the generic words; an extra word without
// case, masked in what it says.
func TestDeny(t *testing.T) {
	for _, c := range []struct {
		text string
		hit  bool
	}{
		{`{"client":"10.20.1.11"}`, true},
		{`host 172.17.0.2:1433`, true},
		{`Microsoft SQL Server 2022 (RTM-CU16) - 16.0.4165.4 (X64)`, false},
		{`version 8.34, 6.11`, false},
		{`1.2.3.4.5`, false},
		{`/home/someone/x`, true},
		{`a job under ~/cloudbox/x`, true},
		{`pgcr_seed`, true},
		{`capt-mssql-1`, true},
		{`b1-rig`, true},
		{`9c1fb1-4a2e`, false},
		{`dbo.Orders`, false},
	} {
		if got := len(Deny([]byte(c.text), nil)) > 0; got != c.hit {
			t.Errorf("Deny(%q) found %v, want %v", c.text, got, c.hit)
		}
	}
	h := Deny([]byte("Server: MyBoxName7"), []string{"myboxname7"})
	if len(h) != 1 || strings.Contains(strings.ToLower(h[0]), "myboxname7") {
		t.Errorf("an extra word: %v (found once, never said whole)", h)
	}
	if got := ScrubIPv4("from 10.0.0.1,10.0.0.2 and 192.168.1.20:5432; build 16.0.4295.3"); got != "from (address),(address) and (address):5432; build 16.0.4295.3" {
		t.Errorf("ScrubIPv4: %q", got)
	}
}

// A sample written by Encode reads back as it was.
func TestEncodeDecode(t *testing.T) {
	s := &Sample{Tool: "x", Engine: "postgres", Kit: "pgvigil", Version: "1", Server: "PostgreSQL 18", Params: map[string]string{"top": "5"},
		Sets: []Set{{Columns: []string{"a", "b"}, Types: []string{"number", "text"}, Rows: [][]any{{1, "one"}}}}}
	b, err := Encode(s)
	if err != nil {
		t.Fatal(err)
	}
	d, err := Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	if d.Tool != "x" || d.Rows() != 1 || d.Sets[0].Rows[0][1] != "one" || d.Params["top"] != "5" {
		t.Errorf("read back: %+v", d)
	}
	if _, err := Get("../x"); err != ErrNone {
		t.Errorf("Get of a path: %v", err)
	}
	if _, err := Get("no_such_tool"); err != ErrNone {
		t.Errorf("Get of a tool without a sample: %v", err)
	}
}
