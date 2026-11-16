package mssql

import (
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestMaintenanceCollector: mssql_maintenance is registered hourly, batched (its CommandLog cursors), and not on
// Azure SQL Database.
func TestMaintenanceCollector(t *testing.T) {
	c, ok := Get(Prefix + "maintenance")
	if !ok {
		t.Fatal("mssql_maintenance is not registered")
	}
	if c.DefaultInterval() != time.Hour {
		t.Errorf("interval %v", c.DefaultInterval())
	}
	if _, batched := c.(BatchCollector); !batched {
		t.Error("mssql_maintenance reads its CommandLogs from cursors: a BatchCollector")
	}
	if ok, why := c.Applies(Info{Kind: KindAzureDB}); ok || why == "" {
		t.Error("not on Azure SQL Database, saying why")
	}
	if ok, _ := c.Applies(Info{Kind: KindServer}); !ok {
		t.Error("on a server")
	}
}

// TestPurityOn: dbatools' rule - off only for a database made before SQL Server 2005 (create version under 611)
// whose DBCC flags are 0.
func TestPurityOn(t *testing.T) {
	for _, c := range []struct {
		cv, flags int64
		want      bool
	}{{957, 2, true}, {957, 0, true}, {611, 0, true}, {539, 0, false}, {539, 2, true}, {610, 0, false}} {
		if got := purityOn(c.cv, c.flags); got != c.want {
			t.Errorf("create version %d, flags %d: %v, want %v", c.cv, c.flags, got, c.want)
		}
	}
}

// TestCommandLogRows: a row's status, and the two cursors a batch moves - one past the highest ID read (the next
// forward read), and the lowest row still running (the next run re-reads the open rows from it); a row never closed
// holds neither, and a batch with nothing in it moves neither.
func TestCommandLogRows(t *testing.T) {
	for _, c := range []struct {
		end       any
		age, errn int64
		want      string
	}{{"2026-11-15T20:00:00Z", 0, 0, "ok"}, {"2026-11-15T20:00:00Z", 0, 3013, "failed"}, {nil, 0, 0, "running"}, {nil, 6, 0, "running"}, {nil, 7, 0, "never closed"}, {nil, 30, 1205, "never closed"}} {
		if got := commandLogStatus(c.end, c.age, c.errn); got != c.want {
			t.Errorf("end %v age %d error %d: %s, want %s", c.end, c.age, c.errn, got, c.want)
		}
	}
	rows := []collect.Row{{"id": int64(10), "status": "ok"}, {"id": int64(11), "status": "running"}, {"id": int64(12), "status": "ok"}, {"id": int64(13), "status": "running"}}
	if hw, open := commandLogCursors(rows, 10, 0); hw != 14 || open != 11 {
		t.Errorf("past the highest read, the lowest running row open: %d %d", hw, open)
	}
	if hw, open := commandLogCursors(rows[:1], 10, 0); hw != 11 || open != 0 {
		t.Errorf("one past the highest read, none open: %d %d", hw, open)
	}
	if hw, open := commandLogCursors(nil, 42, 7); hw != 42 || open != 7 {
		t.Errorf("nothing read: both where they were: %d %d", hw, open)
	}
	// an open row 8 days old before a running one (the review's case): it holds neither cursor
	if hw, open := commandLogCursors([]collect.Row{{"id": int64(5), "status": "never closed"}, {"id": int64(6), "status": "running"}, {"id": int64(7), "status": "ok"}}, 5, 0); hw != 8 || open != 6 {
		t.Errorf("a row never closed holds neither cursor: %d %d", hw, open)
	}
	// a later batch keeps the open row an earlier batch found
	if hw, open := commandLogCursors([]collect.Row{{"id": int64(2001), "status": "ok"}}, 2001, 6); hw != 2002 || open != 6 {
		t.Errorf("the open row of an earlier batch kept: %d %d", hw, open)
	}
	// the command masked whole, then cut: a password past the cut is never left half
	long := []collect.Row{{"id": int64(1), "end_utc": "2026-11-15T20:00:00Z", "age_days": int64(0), "error_number": int64(0),
		"command": strings.Repeat("x", 3975) + ", PASSWORD = N'cutsecret1'"}}
	commandLogPrepare(long, "dba")
	if c := long[0]["command"].(string); strings.Contains(c, "cutsec") || len([]rune(c)) > maintCommandMax || long[0]["status"] != "ok" || long[0]["kind"] != "commandlog" {
		t.Errorf("masked, then cut: %q", c[len(c)-40:])
	}
}

// TestMaintenanceStatementsReadOnly: every statement reads. DBCC DBINFO is the one that is not a SELECT: it goes into
// a #table of the collection's own, dropped in the same batch; the per-database reads go through each database's
// sys.sp_executesql (DBCC DBINFO too: inside the database, as the login's own user). A word inside a quoted text is
// no statement.
func TestMaintenanceStatementsReadOnly(t *testing.T) {
	literal := regexp.MustCompile(`N?'[^']*'`)
	for _, q := range []string{maintDatabasesSQL} {
		u := strings.ToUpper(literal.ReplaceAllString(q, "''"))
		if !strings.HasPrefix(strings.TrimSpace(u), "SELECT") {
			t.Errorf("not a SELECT: %s", q)
		}
		for _, bad := range []string{"EXEC", "INSERT ", "UPDATE ", "DELETE ", "MERGE ", "DBCC", " INTO ", "ALTER ", "DROP "} {
			if strings.Contains(u, bad) {
				t.Errorf("%q in %s", bad, q)
			}
		}
	}
	for name, q := range map[string]string{"objects": maintObjectsSQL, "max": maintCommandLogMaxSQL, "from": maintCommandLogFromSQL,
		"first": maintCommandLogFirstSQL, "open": maintCommandLogOpenSQL} {
		head, inner, found := strings.Cut(q, "N'SELECT")
		if !found || head != "EXEC %s.sys.sp_executesql " {
			t.Errorf("%s is one SELECT through the database's sys.sp_executesql: %s", name, q)
			continue
		}
		inner = strings.ToUpper(inner)
		for _, bad := range []string{"INSERT ", "UPDATE ", "DELETE ", "MERGE ", "DBCC", "ALTER ", "DROP "} {
			if strings.Contains(inner, bad) {
				t.Errorf("%s holds %q", name, bad)
			}
		}
	}
	if !strings.Contains(maintDBInfoSQL, "INSERT #pgv_mt_dbinfo EXEC %s.sys.sp_executesql N'DBCC DBINFO WITH TABLERESULTS, NO_INFOMSGS';") ||
		!strings.Contains(maintDBInfoSQL, "DROP TABLE #pgv_mt_dbinfo;") || strings.Contains(strings.ToUpper(maintDBInfoSQL), "CHECKDB") {
		t.Error("the purity read is DBCC DBINFO into the collection's own #table, dropped in the batch, and no CHECKDB")
	}
	for _, q := range []string{maintCommandLogFromSQL, maintCommandLogFirstSQL, maintCommandLogOpenSQL} {
		if !strings.Contains(q, "TOP (@n)") || !strings.Contains(q, "ORDER BY c.ID") || strings.Contains(q, " OR (@from") {
			t.Errorf("each CommandLog read is its own statement, at most @n rows a batch, in ID order: %s", q[len(q)-200:])
		}
	}
	if !strings.Contains(maintCommandLogFromSQL, "WHERE c.ID >= @from") || !strings.Contains(maintCommandLogOpenSQL, "c.ID >= @open AND c.ID < @to AND (c.EndTime IS NULL OR c.EndTime >=") {
		t.Error("the forward read seeks from its cursor; the open read takes the rows still open or closed since, up to where the last read ended")
	}
	if maintCommandLogMax != 50000 || maintCommandLogBatch > maintCommandLogMax || maintOpenDays != 7 || maintPurityEvery != 24*time.Hour {
		t.Error("50,000 rows a database a run, batches no larger, 7 days for a row still running, purity once a day")
	}
}
