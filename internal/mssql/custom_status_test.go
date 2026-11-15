package mssql

import (
	"strconv"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// ST6b: a status check's rows (DBA Dash's custom check) - the columns found by name without case, each row's Status
// 1 critical / 2 warning / 3 N/A / 4 OK, the run the worst row, its value the rows at warning or critical, the bad
// shapes in words. Red on the base: statusColumns / statusJudge do not exist.
func TestCustomStatusRows(t *testing.T) {
	cols := []string{"test", "CONTEXT", "Status", "info", "extra"}
	ix, note, err := statusColumns(cols)
	if err != nil || ix != [4]int{0, 1, 2, 3} || !strings.Contains(note, "1 other column not read (extra)") {
		t.Fatalf("statusColumns: %v %v %q", ix, err, note)
	}
	if _, _, err := statusColumns([]string{"Test", "Context", "Info"}); err == nil || !strings.Contains(err.Error(), "no column Status") {
		t.Errorf("no Status: %v", err)
	}
	if ix, _, err := statusColumns([]string{"Test", "Context", "Status"}); err != nil || ix[3] != -1 {
		t.Errorf("Info is optional: %v %v", ix, err)
	}
	info := "the last full backup is 9 days old"
	rows := []statusRow{
		{Test: "backup", Context: "db1", Status: 1, Info: &info},
		{Test: "backup", Context: "db2", Status: 2},
		{Test: "jobs", Context: "agent", Status: 4},
		{Test: "na", Context: "x", Status: 3},
	}
	st, v, n := statusJudge(rows)
	if st != "critical" || v != 2 || n != "" {
		t.Errorf("judge: %s %v %q", st, v, n)
	}
	if st, v, n := statusJudge(rows[2:]); st != "ok" || v != 0 || n != "" {
		t.Errorf("OK and N/A: %s %v %q", st, v, n)
	}
	if st, _, n := statusJudge(rows[3:]); st != "ok" || n != "every row N/A (DBA Dash's status 3): nothing to judge" {
		t.Errorf("N/A alone: %s %q", st, n)
	}
	if st, _, n := statusJudge(nil); st != "ok" || n != "no row: nothing to judge (DBA Dash's N/A)" {
		t.Errorf("no row: %s %q", st, n)
	}
	for _, bad := range []struct {
		vals []any
		want string
	}{
		{[]any{"t", "c", int64(7), nil}, "Status 7 is not 1 to 4"},
		{[]any{"t", "c", nil, nil}, "Status is NULL"},
		{[]any{nil, "c", int64(1), nil}, "Test is NULL"},
		{[]any{"t", nil, int64(1), nil}, "Context is NULL"},
		{[]any{strings.Repeat("x", 129), "c", int64(1), nil}, "Test is longer than 128 characters"},
		{[]any{"t", "c", "warn", nil}, "Status \"warn\" is not 1 to 4"},
	} {
		if _, err := statusRowOf(bad.vals, []string{"nvarchar", "nvarchar", "INT", "nvarchar"}, [4]int{0, 1, 2, 3}, true); err == nil || !strings.Contains(err.Error(), bad.want) {
			t.Errorf("%v: %v, want %q", bad.vals, err, bad.want)
		}
	}
	r, err := statusRowOf([]any{"t", "c", int64(2), strings.Repeat("y", 1500)}, []string{"nvarchar", "nvarchar", "TINYINT", "nvarchar"}, [4]int{0, 1, 2, 3}, true)
	if err != nil || r.Status != 2 || r.Info == nil || len([]rune(*r.Info)) != collect.CustomMaxCell {
		t.Errorf("a row kept: %+v %v", r, err)
	}
	if r, err := statusRowOf([]any{"t", "c", int64(2), "secret"}, []string{"nvarchar", "nvarchar", "INT", "nvarchar"}, [4]int{0, 1, 2, 3}, false); err != nil || r.Info != nil {
		t.Errorf("Info under query_text other than full: %+v %v", r, err)
	}
	if err := statusDuplicate(append(rows, statusRow{Test: "backup", Context: "db1", Status: 4})); err == nil || !strings.Contains(err.Error(), "Test \"backup\" and Context \"db1\" come twice") {
		t.Errorf("a pair twice: %v", err)
	}
	pr := statusPayload("dbadash_custom_check", rows[:2])
	if len(pr) != 2 || pr[0]["kind"] != "status_row" || pr[0]["check_name"] != "dbadash_custom_check" || pr[0]["status"] != 1 || pr[0]["info"] != info || pr[1]["info"] != nil {
		t.Errorf("payload: %v", pr)
	}
}

// the code review's B1: over 1,000 rows the worst are kept first - a critical row last of 1,001 is kept (and raises its
// finding); over 1,000 failing rows the critical come first and the note says the rest raise no finding
func TestCustomStatusKeeper(t *testing.T) {
	var k statusKeeper
	for i := 1; i <= 1001; i++ {
		st := 4
		if i == 1001 {
			st = 1
		}
		if err := k.add(statusRow{Test: "db" + strconv.Itoa(i), Context: "c", Status: st}); err != nil {
			t.Fatal(err)
		}
	}
	kept := k.kept()
	if len(kept) != statusMaxRows || kept[0].Test != "db1001" || kept[0].Status != 1 {
		t.Fatalf("kept %d rows, the first %+v", len(kept), kept[0])
	}
	if got := k.note(1001); got != "1000 of 1001 status rows kept: every row at critical or warning first" {
		t.Errorf("note: %q", got)
	}
	if err := k.add(statusRow{Test: "db7", Context: "c", Status: 2}); err == nil || !strings.Contains(err.Error(), `Test "db7" and Context "c" come twice`) {
		t.Errorf("a pair twice past the cap: %v", err)
	}
	var many statusKeeper
	for i := 1; i <= 1200; i++ {
		st := 2
		if i > 1100 {
			st = 1
		}
		_ = many.add(statusRow{Test: "t" + strconv.Itoa(i), Context: "c", Status: st})
	}
	kept = many.kept()
	if len(kept) != statusMaxRows || kept[0].Status != 1 || kept[99].Status != 1 || kept[100].Status != 2 {
		t.Errorf("1,200 failing rows: %d kept, statuses %d %d %d", len(kept), kept[0].Status, kept[99].Status, kept[100].Status)
	}
	if got := many.note(1200); !strings.Contains(got, "the first 1000 of the 1200 at critical or warning (critical first) - the rest raise no finding") {
		t.Errorf("note: %q", got)
	}
	var none statusKeeper
	if got := none.kept(); got == nil || len(got) != 0 || none.note(0) != "" {
		t.Errorf("no row: %v %q", got, none.note(0))
	}
}
