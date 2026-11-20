package mssql

import (
	"context"
	"errors"
	"sort"
	"strings"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

func TestCustomBatch(t *testing.T) {
	for _, c := range []struct {
		c    collect.CustomCheck
		want string
	}{
		{collect.CustomCheck{SQL: "SELECT 1 AS value"}, "SELECT 1 AS value"},
		{collect.CustomCheck{SQL: "SELECT 1 AS value", Database: "Sales DB"}, "USE [Sales DB];\nSELECT 1 AS value"},
		{collect.CustomCheck{Procedure: "Utility.dbo.check_jobs"}, "EXEC [Utility].[dbo].[check_jobs];"},
		{collect.CustomCheck{Procedure: "check_jobs"}, "EXEC [check_jobs];"},
	} {
		if got := customBatch(c.c); got != c.want {
			t.Errorf("customBatch(%+v) = %q, want %q", c.c, got, c.want)
		}
	}
	if !strings.Contains(customRun, "SET XACT_ABORT ON;") || !strings.Contains(customRun, "BEGIN TRANSACTION;") ||
		!strings.Contains(customRun, "EXEC sys.sp_executesql @pgvigil_check;") || !strings.Contains(customRun, "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;") ||
		!strings.Contains(customRun, "CURRENT_TRANSACTION_ID() <> @pgvigil_tx") || !strings.Contains(customRun, "THROW 50266") {
		t.Errorf("the batch that holds a check: %s", customRun)
	}
}

func TestTraceChanges(t *testing.T) {
	before := map[int]string{1: "1\x00/var/opt/mssql/log/log_1.trc\x002026-11-15T10:00:00", 3: "1\x00/tmp/x.trc\x002026-11-15T11:00:00", 4: "0\x00/tmp/y.trc\x00"}
	if got := traceChanges(before, before); got != "" {
		t.Errorf("no change: %q", got)
	}
	after := map[int]string{1: before[1], 3: "0\x00/tmp/x.trc\x002026-11-15T11:00:00", 4: "1\x00/tmp/y.trc\x002026-11-15T12:00:00", 5: "0\x00/tmp/new.trc\x00"}
	if got := traceChanges(before, after); got != "stopped trace 3 (/tmp/x.trc), started trace 4 (/tmp/y.trc), made trace 5 (/tmp/new.trc)" {
		t.Errorf("changes: %q", got)
	}
	if got := traceChanges(before, map[int]string{1: before[1], 4: before[4]}); got != "closed trace 3 (/tmp/x.trc)" {
		t.Errorf("a closed trace: %q", got)
	}
}

func TestCustomErrText(t *testing.T) {
	proc := collect.CustomCheck{Procedure: "dbo.check"}
	plain := collect.CustomCheck{SQL: "SELECT 1"}
	for _, c := range []struct {
		err  error
		c    collect.CustomCheck
		want string
	}{
		{mssqldb.Error{Number: 266, Message: "Transaction count after EXECUTE ..."}, plain, "the check ended the transaction it ran in"},
		// 'COMMIT; BEGIN TRAN' raises pgvigil's own 50266; a bare COMMIT 266 and then 50266 (the last on top)
		{mssqldb.Error{Number: 50266, Message: "the check ended the transaction it ran in and went on in another"}, plain, "what it changed was not rolled back"},
		{mssqldb.Error{Number: 50266, All: []mssqldb.Error{{Number: 266}, {Number: 50266}}}, plain, "a COMMIT or a ROLLBACK inside it"},
		{mssqldb.Error{Number: 2812, Message: "Could not find stored procedure"}, proc, "procedure dbo.check does not exist, or the read login may not see it (Msg 2812)"},
		{mssqldb.Error{Number: 229, Message: "The EXECUTE permission was denied"}, proc, "GRANT EXECUTE on it to the read login"},
		{context.DeadlineExceeded, plain, "did not finish within 30 s"},
		{errors.New("Invalid object name 'x'."), plain, "Invalid object name 'x'."}, //nolint:revive // SQL Server's own message, as the driver hands it back
	} {
		if got := customErrText(c.err, c.c); !strings.Contains(got, c.want) {
			t.Errorf("customErrText(%v) = %q, want %q", c.err, got, c.want)
		}
	}
}

// the collection's gate: off with its reason while the file has no SQL Server check (and no connection made for it),
// on while one exists; its timeout grows with the list and is capped
func TestCustomGateAndTimeout(t *testing.T) {
	cc := &customCollector{last: map[string]time.Time{}}
	defer collect.SetCustomChecks(nil, false)
	collect.SetCustomChecks(nil, false)
	if ok, why := cc.Wants(config.Instance{Name: "sql01", Engine: config.EngineSQLServer}); ok || why != "no custom: list in the configuration" {
		t.Errorf("no key: %v %q", ok, why)
	}
	pgOnly, _, err := collect.ParseCustomChecks([]byte("custom: [{name: a, sql: SELECT 1}]"), nil)
	if err != nil {
		t.Fatal(err)
	}
	collect.SetCustomChecks(pgOnly, true)
	if ok, why := cc.Applies(Info{}); ok || why != "no custom: check with engine: sqlserver" {
		t.Errorf("PostgreSQL checks only: %v %q", ok, why)
	}
	both, _, err := collect.ParseCustomChecks([]byte(`custom:
  - {name: a, sql: SELECT 1}
  - {name: b, engine: sqlserver, sql: SELECT 1 AS value}
  - {name: c, procedure: dbo.check_jobs, tags: [env:prod]}
`), nil)
	if err != nil {
		t.Fatal(err)
	}
	collect.SetCustomChecks(both, true)
	if ok, why := cc.Wants(config.Instance{Name: "sql01", Engine: config.EngineSQLServer}); !ok || why != "" {
		t.Errorf("a SQL Server check: %v %q", ok, why)
	}
	if got := cc.Timeout(); got != 90*time.Second {
		t.Errorf("Timeout with two SQL Server checks: %s, want 90s", got)
	}
	var names []string
	for _, c := range collect.CustomFor(config.Instance{Name: "sql01", Engine: config.EngineSQLServer, Tags: []string{"env:prod"}}) {
		names = append(names, c.Name)
	}
	sort.Strings(names)
	if strings.Join(names, ",") != "b,c" {
		t.Errorf("the checks of a SQL Server instance: %v", names)
	}
	many := make([]collect.CustomCheck, 30)
	for i := range many {
		many[i] = collect.CustomCheck{Name: "m", Engine: config.EngineSQLServer, SQL: "SELECT 1"}
	}
	collect.SetCustomChecks(many, true)
	if got := cc.Timeout(); got != customMaxTimeout {
		t.Errorf("Timeout with 30 checks: %s, want the cap %s", got, customMaxTimeout)
	}
	if _, err := cc.Run(context.Background(), nil, Info{}); err == nil || !strings.Contains(err.Error(), "runs per instance") {
		t.Errorf("Run without the frame's InstanceCollector: %v", err)
	}
}

// a result row carries the keys import_custom reads (the PostgreSQL collection's)
func TestCustomResultRow(t *testing.T) {
	v := 3.0
	r := customResult{Status: "warning", Value: &v, RowCount: 2, Columns: []string{"value"}, Cells: [][]any{{int64(3)}}, Kept: true, Note: "n", Took: 1500 * time.Millisecond}
	row := r.row("a")
	for _, k := range []string{"kind", "check_name", "status", "row_count", "columns", "rows_kept", "note", "error", "duration_ms", "value", "rows"} {
		if _, ok := row[k]; !ok {
			t.Errorf("the result row lacks %s: %v", k, row)
		}
	}
	if row["kind"] != "result" || row["duration_ms"] != int64(1500) || row["value"] != 3.0 {
		t.Errorf("the result row: %v", row)
	}
	if _, ok := (customResult{Status: "error", Err: "x"}).row("a")["rows"]; ok {
		t.Error("a run whose rows are not kept carries rows")
	}
}

// due only asks; mark records a run when it starts, so a check the fence or the run's
// deadline kept from running is due again at the next run
func TestCustomDueMark(t *testing.T) {
	cc := &customCollector{last: map[string]time.Time{}}
	c := collect.CustomCheck{Name: "a", Engine: config.EngineSQLServer, SQL: "SELECT 1", Every: config.Duration{Duration: 5 * time.Minute}}
	now := time.Now()
	if !cc.due("sql01", c, now) || !cc.due("sql01", c, now.Add(time.Minute)) {
		t.Fatal("a check never run is due, and asking records nothing")
	}
	cc.mark("sql01", c, now)
	if cc.due("sql01", c, now.Add(time.Minute)) {
		t.Error("a check run a minute ago with a 5 minute cadence is due")
	}
	if !cc.due("sql01", c, now.Add(5*time.Minute)) || !cc.due("sql02", c, now.Add(time.Minute)) {
		t.Error("a check is due after its cadence, and on another instance")
	}
}
