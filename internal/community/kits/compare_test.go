package kits

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func col(name, typ, sqlType string, null bool) Column {
	return Column{Name: name, Type: typ, SQLType: sqlType, Nullable: &null}
}

func run(sets ...Set) Run {
	return Run{Tool: "sp_Test", Kit: "FRK", Version: "8.34", Outcome: "done", Sets: sets}
}

// lines picks the lines of one kind
func linesOf(ls []Line, kind string) []Line {
	var out []Line
	for _, l := range ls {
		if l.Kind == kind {
			out = append(out, l)
		}
	}
	return out
}

// KITWATCH F4: two classes - BREAK (exit 1) for what pgvigil's code or page depends on, DRIFT (exit 0 and a warning)
// for what it does not; columns matched by NAME first, their order a line of its own.
func TestCompareClasses(t *testing.T) {
	base := Set{Columns: []Column{col("session_id", "number", "SMALLINT", false), col("status", "text", "VARCHAR", true), col("cpu", "number", "INT", true)}}
	for _, c := range []struct {
		what  string
		got   Set
		class Class
		kind  string
		words []string
	}{
		{"a column removed", Set{Columns: []Column{base.Columns[0], base.Columns[2]}}, Break, "column removed", []string{"status"}},
		{"a column added", Set{Columns: append(append([]Column{}, base.Columns...), col("wait_info", "text", "NVARCHAR", true))}, Drift, "column added", []string{"wait_info"}},
		{"int to bigint (one coarse type)", Set{Columns: []Column{base.Columns[0], base.Columns[1], col("cpu", "number", "BIGINT", true)}}, Drift, "type", []string{"cpu", "INT", "BIGINT"}},
		{"number to text (the page's coarse type)", Set{Columns: []Column{base.Columns[0], base.Columns[1], col("cpu", "text", "VARCHAR", true)}}, Break, "type", []string{"cpu", "number", "text"}},
		{"nullability", Set{Columns: []Column{col("session_id", "number", "SMALLINT", true), base.Columns[1], base.Columns[2]}}, Drift, "nullability", []string{"session_id"}},
		{"two columns swapped", Set{Columns: []Column{base.Columns[1], base.Columns[0], base.Columns[2]}}, Drift, "reordered", []string{"status", "session_id"}},
	} {
		ls := Compare(run(base), run(c.got))
		got := linesOf(ls, c.kind)
		if len(got) != 1 {
			t.Errorf("%s: %d '%s' line(s) in %+v, want 1", c.what, len(got), c.kind, ls)
			continue
		}
		if got[0].Class != c.class {
			t.Errorf("%s: class %s, want %s", c.what, got[0].Class, c.class)
		}
		for _, w := range c.words {
			if !strings.Contains(got[0].What, w) {
				t.Errorf("%s: %q does not name %q", c.what, got[0].What, w)
			}
		}
		if c.kind == "reordered" && (len(linesOf(ls, "column removed")) > 0 || len(linesOf(ls, "column added")) > 0) {
			t.Errorf("a swap read as renames: %+v", ls)
		}
	}
	if ls := Compare(run(base), run(base)); len(ls) != 0 {
		t.Errorf("the same shape: %+v, want no line", ls)
	}
	if Verdict(Compare(run(base), run(Set{Columns: base.Columns[:2]}))) != 1 {
		t.Error("a BREAK line: the verdict is not 1")
	}
	if Verdict(Compare(run(base), run(Set{Columns: append(append([]Column{}, base.Columns...), col("x", "text", "INT", true))}))) != 0 {
		t.Error("a DRIFT line alone: the verdict is not 0")
	}
}

// Sets carry no names: a set inserted before the others is one 'set added' (DRIFT), never every later set changed;
// a set gone is BREAK; a set after a truncated one is 'unread', never removed (F3).
func TestCompareSets(t *testing.T) {
	a := Set{Columns: []Column{col("check_id", "number", "INT", false), col("finding", "text", "NVARCHAR", true)}}
	b := Set{Columns: []Column{col("database_name", "text", "NVARCHAR", true), col("size_mb", "number", "DECIMAL", true)}}
	c := Set{Columns: []Column{col("wait_type", "text", "NVARCHAR", false), col("hours", "number", "DECIMAL", true)}}
	newSet := Set{Columns: []Column{col("warning", "text", "NVARCHAR", true)}}
	ls := Compare(run(a, b, c), run(newSet, a, b, c))
	if len(ls) != 1 || ls[0].Kind != "set added" || ls[0].Class != Drift {
		t.Errorf("a set inserted first: %+v, want one DRIFT 'set added'", ls)
	}
	ls = Compare(run(a, b, c), run(a, c))
	if len(ls) != 1 || ls[0].Kind != "set removed" || ls[0].Class != Break || !strings.Contains(ls[0].What, "database_name") {
		t.Errorf("the middle set gone: %+v, want one BREAK 'set removed' naming its columns", ls)
	}
	cut := a
	cut.Truncated = true
	ls = Compare(run(a, b, c), run(cut))
	if len(linesOf(ls, "set removed")) != 0 || len(linesOf(ls, "unread")) != 1 || Verdict(ls) != 0 {
		t.Errorf("sets after a truncated one: %+v, want one 'unread' line, nothing removed, verdict 0", ls)
	}
	full := run(a)
	full.AtSetCap = true
	if ls := Compare(run(a), full); len(linesOf(ls, "set cap")) != 1 {
		t.Errorf("a run at pgvigil's 50-set cap: %+v, want its line", ls)
	}
}

// The outcome, the form and the help (F3): a run that stops being 'done' is BREAK, a timeout its own line; a new
// parameter the page's write filter does not take out is BREAK; a parameter the filter takes out is DRIFT; a drop
// in the count of described form parameters is BREAK.
func TestCompareRunAndForm(t *testing.T) {
	want := run()
	want.FormParams = []string{"@help", "@database_name"}
	want.AllParams = []Param{{Name: "@help", Type: "bit"}, {Name: "@database_name", Type: "sysname"}, {Name: "@output_table_name", Type: "nvarchar"}}
	want.Described = 2
	for _, c := range []struct {
		what  string
		edit  func(r *Run)
		class Class
		kind  string
	}{
		{"failed now", func(r *Run) { r.Outcome, r.Message = "failed", "Invalid column name 'x'" }, Break, "outcome"},
		{"slower than the limit", func(r *Run) { r.Outcome = "timeout" }, Info, "timeout"},
		{"a new parameter on the form", func(r *Run) {
			r.FormParams = append(r.FormParams, "@target_table")
			r.AllParams = append(r.AllParams, Param{Name: "@target_table", Type: "nvarchar"})
		}, Break, "new form parameter"},
		{"a new parameter the write filter takes out", func(r *Run) {
			r.AllParams = append(r.AllParams, Param{Name: "@output_schema_name", Type: "nvarchar"})
		}, Drift, "parameter added"},
		{"a parameter gone", func(r *Run) { r.FormParams, r.AllParams = r.FormParams[:1], r.AllParams[:1] }, Drift, "parameter removed"},
		{"the help's descriptions gone", func(r *Run) { r.Described = 0 }, Break, "help"},
	} {
		got := want
		got.FormParams = append([]string{}, want.FormParams...)
		got.AllParams = append([]Param{}, want.AllParams...)
		c.edit(&got)
		ls := linesOf(Compare(want, got), c.kind)
		if len(ls) != 1 || ls[0].Class != c.class {
			t.Errorf("%s: %+v, want one %s '%s' line", c.what, Compare(want, got), c.class, c.kind)
		}
	}
	presetGone := want
	presetGone.Presets = []string{"@database_name"}
	got := presetGone
	got.AllParams = want.AllParams[:1]
	got.FormParams = want.FormParams[:1]
	if ls := linesOf(Compare(presetGone, got), "preset parameter removed"); len(ls) != 1 || ls[0].Class != Break {
		t.Errorf("a preset's parameter gone: %+v, want one BREAK line", Compare(presetGone, got))
	}
}

// F3: a procedure the tool now fails without (revoke-and-run) is BREAK; one it no longer needs is DRIFT.
func TestCompareSiblings(t *testing.T) {
	want, got := run(), run()
	want.HardSiblings = []string{"sp_BlitzCache", "sp_ineachdb"}
	got.HardSiblings = []string{"sp_ineachdb", "sp_BlitzWho"}
	ls := Compare(want, got)
	if n := linesOf(ls, "new hard sibling"); len(n) != 1 || n[0].Class != Break || !strings.Contains(n[0].What, "sp_BlitzWho") {
		t.Errorf("a new hard sibling: %+v", ls)
	}
	if g := linesOf(ls, "sibling no longer needed"); len(g) != 1 || g[0].Class != Drift || !strings.Contains(g[0].What, "sp_BlitzCache") {
		t.Errorf("a sibling gone: %+v", ls)
	}
}

// F2: the collector entry - a column pgvigil reads BY NAME missing from the newest shape is BREAK, whatever else.
func TestCompareReadByName(t *testing.T) {
	want := run(Set{Columns: []Column{col("session_id", "number", "SMALLINT", false), col("tempdb_current", "number", "BIGINT", true)}})
	want.ReadByName = []string{"session_id", "tempdb_current"}
	got := run(Set{Columns: []Column{col("session_id", "number", "SMALLINT", false), col("tempdb_current_kb", "number", "BIGINT", true)}})
	ls := linesOf(Compare(want, got), "read by name")
	if len(ls) != 1 || ls[0].Class != Break || !strings.Contains(ls[0].What, "tempdb_current") {
		t.Errorf("a by-name column gone: %+v", Compare(want, got))
	}
}

// F4 / F6: a port's block between its anchors - same = no line; changed = DRIFT 're-read'; a data list's items added
// and removed named; an anchor gone = DRIFT 'anchor gone'. Never BREAK (a stale copy does not stop pgvigil).
func TestComparePort(t *testing.T) {
	file := "-- head\nINSERT INTO #IgnorableWaits VALUES ('BROKER_TASK_STOP'),\n('CHECKPOINT_QUEUE'),\n('CLR_AUTO_EVENT');\n-- tail\n"
	block := "INSERT INTO #IgnorableWaits VALUES ('BROKER_TASK_STOP'),\n('CHECKPOINT_QUEUE'),\n('CLR_AUTO_EVENT');"
	sum := sha256.Sum256([]byte(block))
	p := Port{Name: "benignWaits", GoFile: "internal/mssql/waits.go", Begin: "INSERT INTO #IgnorableWaits", End: ");",
		SHA256: hex.EncodeToString(sum[:]), ItemRE: `'([A-Z_]+)'`, Items: []string{"BROKER_TASK_STOP", "CHECKPOINT_QUEUE", "CLR_AUTO_EVENT"}}
	if ls := ComparePort(p, []byte(file)); len(ls) != 0 {
		t.Errorf("the same block: %+v", ls)
	}
	changed := strings.Replace(file, "('CHECKPOINT_QUEUE'),\n", "('DIRTY_PAGE_POLL'),\n", 1)
	ls := ComparePort(p, []byte(changed))
	if len(ls) != 1 || ls[0].Class != Drift || !strings.Contains(ls[0].What, "+DIRTY_PAGE_POLL") || !strings.Contains(ls[0].What, "-CHECKPOINT_QUEUE") {
		t.Errorf("a list item swapped: %+v, want one DRIFT naming +DIRTY_PAGE_POLL and -CHECKPOINT_QUEUE", ls)
	}
	if ls := ComparePort(p, []byte("-- the block moved away\n")); len(ls) != 1 || ls[0].Kind != "anchor gone" || ls[0].Class != Drift {
		t.Errorf("the anchor gone: %+v", ls)
	}
}

// F14 / F6: a kit's version from a procedure's own definition - FRK's @Version / @VersionDate, DarlingData's @version /
// @version_date, sp_WhoIsActive's header; compared by DATE.
func TestParseVersion(t *testing.T) {
	for _, c := range []struct{ def, version, date string }{
		{"ALTER PROCEDURE dbo.sp_Blitz AS\nSET NOCOUNT ON;\nSELECT @Version = '8.34', @VersionDate = '20260702';", "8.34", "20260702"},
		{"ALTER PROCEDURE dbo.sp_PressureDetector AS BEGIN\nSELECT\n    @version = '6.11',\n    @version_date = '20261101';", "6.11", "20261101"},
		{"/*********************************************************************************************\nWho Is Active? v2200.20260409 (2026-04-09)", "v2200.20260409", "20260409"},
	} {
		v, d, ok := ParseVersion(c.def)
		if !ok || v != c.version || d != c.date {
			t.Errorf("%q: %q %q %v, want %q %q", c.def[:30], v, d, ok, c.version, c.date)
		}
	}
	if _, _, ok := ParseVersion("CREATE PROCEDURE dbo.x AS SELECT 1"); ok {
		t.Error("a definition without a version parsed")
	}
	if Newer("20261101", "20260702") != true || Newer("20260702", "20260702") != false {
		t.Error("Newer compares by date")
	}
}

// F4: each line says whether the previous run's report had it.
func TestMarkNew(t *testing.T) {
	prev := []Line{{Class: Drift, Tool: "sp_Blitz", Kind: "column added", What: "column x added"}}
	now := []Line{prev[0], {Class: Break, Tool: "sp_Blitz", Kind: "column removed", What: "column y removed"}}
	MarkNew(now, prev)
	if now[0].New || !now[1].New {
		t.Errorf("new marks: %+v", now)
	}
}
