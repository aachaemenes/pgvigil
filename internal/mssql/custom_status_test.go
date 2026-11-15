package mssql

import (
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
