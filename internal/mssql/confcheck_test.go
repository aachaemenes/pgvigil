package mssql

import (
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestConfcheckCollectorsRegistered: the two collections of migration 0160 are registered under their names, hourly,
// and the linked servers' connection test runs only on an instance that carries its tag.
func TestConfcheckCollectorsRegistered(t *testing.T) {
	for _, name := range []string{"mssql_confcheck", "mssql_linkedserver_test"} {
		c, ok := registry[name]
		if !ok {
			t.Fatalf("%s is not registered", name)
		}
		if c.DefaultInterval().Hours() != 1 {
			t.Errorf("%s: interval %s, want 1h", name, c.DefaultInterval())
		}
	}
	if _, ok := registry["mssql_linkedserver_test"].(BatchCollector); !ok {
		t.Error("mssql_linkedserver_test keeps where the next run starts: it is a BatchCollector")
	}
	server := Info{Kind: KindServer, Major: 16, ViewServerState: true, ViewAnyDefinition: true}
	if ok, why := (confcheckCollector{}).Applies(server); !ok {
		t.Errorf("mssql_confcheck on a server: %s", why)
	}
	if ok, why := (confcheckCollector{}).Applies(Info{Kind: KindAzureDB}); ok || !strings.Contains(why, "Azure SQL Database") {
		t.Errorf("mssql_confcheck on Azure SQL Database: %v %q", ok, why)
	}
	if ok, why := (linkedServerTestCollector{}).Applies(server); ok || !strings.Contains(why, LinkedServerTestTag) {
		t.Errorf("without the tag the test is off and names the tag: %v %q", ok, why)
	}
	server.LinkedServerTest = true
	if ok, why := (linkedServerTestCollector{}).Applies(server); !ok {
		t.Errorf("with the tag the test runs: %s", why)
	}
	if ok, _ := (linkedServerTestCollector{}).Applies(Info{Kind: KindAzureDB, LinkedServerTest: true}); ok {
		t.Error("Azure SQL Database has no linked servers")
	}
	// the run's deadline covers every test of a run at its own deadline
	if got := (linkedServerTestCollector{}).Timeout(); got < linkedTestsPerRun*linkedTestDeadline {
		t.Errorf("the run's deadline %s is under %d tests of %s", got, linkedTestsPerRun, linkedTestDeadline)
	}
}

// TestLinkedTestOutcome: 0 is ok; no mapping (7416) and a failed mapped login (18456) are the collector's login, not
// the link; anything else is a failure. Only SQL Server's own providers are tested.
func TestLinkedTestOutcome(t *testing.T) {
	for n, want := range map[int64]string{0: "ok", 7416: "unmapped", 18456: "unmapped", 2: "failed", 53: "failed", 7399: "failed"} {
		if got := linkedTestOutcome(n); got != want {
			t.Errorf("error %d: %s, want %s", n, got, want)
		}
	}
	for _, c := range []struct {
		provider string
		want     bool
	}{{"MSOLEDBSQL", true}, {"msoledbsql19", true}, {"SQLNCLI11", true}, {" SQLNCLI ", true}, {"SQLOLEDB", true},
		{"OraOLEDB.Oracle", false}, {"MSDASQL", false}, {"", false}, {"Microsoft.ACE.OLEDB.12.0", false}} {
		if got := sqlServerProvider(c.provider); got != c.want {
			t.Errorf("provider %q: %v, want %v", c.provider, got, c.want)
		}
	}
}

// TestConfcheckStatementsReadOnly: every statement of the two collections reads. The three that are not a plain
// SELECT are named: the registry read of NumErrorLogs, the list of error log files (into a #table of its own, dropped
// in the same batch), and the connection test.
func TestConfcheckStatementsReadOnly(t *testing.T) {
	// a word inside a quoted text is no statement (the rights read names 'ALTER ANY LINKED SERVER' as a permission)
	literal := regexp.MustCompile(`N?'[^']*'`)
	for _, q := range []string{confNamesSQL, confHostSQL, confXESQL, confStartupSQL, confDatabasesSQL, confLogShippingSQL, confLinkedSQL, confLinkedLoginsSQL, confLinkedSeesAllSQL, linkedTestListSQL} {
		u := strings.ToUpper(literal.ReplaceAllString(q, "''"))
		if !strings.HasPrefix(strings.TrimSpace(u), "SELECT") {
			t.Errorf("not a SELECT: %s", q)
		}
		for _, bad := range []string{"EXEC ", "EXECUTE", "INSERT ", "UPDATE ", "DELETE ", "MERGE ", "XP_", " SP_", ".SP_", "DBCC", " INTO ", "ALTER ", "DROP ", "REMOTE_NAME AS"} {
			if strings.Contains(u, bad) {
				t.Errorf("a statement holds %q: %s", bad, q)
			}
		}
	}
	scoped := strings.ToUpper(confScopedSQL)
	if !strings.HasPrefix(scoped, "EXEC %S.SYS.SP_EXECUTESQL N'SELECT ") {
		t.Errorf("the scoped MAXDOP read is one SELECT through the database's sys.sp_executesql: %s", confScopedSQL)
	}
	if !strings.Contains(confErrorLogSQL, "EXEC @rc = master.dbo.xp_instance_regread") || strings.Contains(strings.ToUpper(confErrorLogSQL), "REGWRITE") {
		t.Error("the error log count is one registry read with its return code captured")
	}
	if !strings.Contains(confErrorLogFilesSQL, "INSERT #pgv_cc_el EXEC sys.sp_enumerrorlogs") || !strings.Contains(confErrorLogFilesSQL, "DROP TABLE #pgv_cc_el") {
		t.Error("the error log files are listed into a #table of the collection's own and dropped in the batch")
	}
	test := strings.ToUpper(linkedTestSQL)
	if !strings.Contains(test, "EXEC SYS.SP_TESTLINKEDSERVER @SERVERNAME = @P1") || !strings.Contains(test, "BEGIN CATCH") {
		t.Error("the connection test is sys.sp_testlinkedserver by parameter, its failure caught as a row")
	}
	for _, bad := range []string{"OPENQUERY", "OPENROWSET", "INSERT ", "UPDATE ", "DELETE ", " AT ["} {
		if strings.Contains(test, bad) {
			t.Errorf("the connection test holds %q", bad)
		}
	}
	// the linked logins' read never selects the remote login's name
	if strings.Contains(confLinkedLoginsSQL, "remote_name AS") || !strings.Contains(confLinkedLoginsSQL, "CASE WHEN l.remote_name IS NULL THEN 0 ELSE 1 END") {
		t.Error("only whether a remote login is mapped is read, never its name")
	}
	// no payload row carries a column the text policy rewrites
	for _, r := range []collect.Row{confPart("xe", true, ""), confFact("server_name", "x")} {
		for _, k := range []string{"detail", "query", "statement"} {
			if _, has := r[k]; has {
				t.Errorf("a payload row carries %q, which the query-text policy rewrites: %v", k, r)
			}
		}
	}
}

// TestConfcheckRows: a part's row and the managed services' names.
func TestConfcheckRows(t *testing.T) {
	if r := confPart("startup", false, "not read: x"); r["kind"] != "part" || r["read"] != 0 || r["note"] != "not read: x" {
		t.Errorf("a part not read: %v", r)
	}
	if r := confPart("names", true, ""); r["read"] != 1 || r["note"] != nil {
		t.Errorf("a part read carries no note: %v", r)
	}
	for k, want := range map[Kind]string{KindRDS: "Amazon RDS", KindAzureMI: "Azure SQL Managed Instance", KindCloudSQL: "Google Cloud SQL", KindServer: "", KindAzureDB: ""} {
		if got := hostedBy(k); got != want {
			t.Errorf("hostedBy(%s) = %q, want %q", k, got, want)
		}
	}
}

// TestIdentityLimits: the identity rule's two lines from an instance's mssql_thresholds - the defaults where a name is
// not set, a line from the floor to 100, the warning under the critical; the threshold store's payload never carries
// them; the rule judges with the lines it is given and its finding names them.
func TestIdentityLimits(t *testing.T) {
	for _, c := range []struct {
		in         map[string]any
		warn, crit float64
	}{
		{nil, 75, 90},
		{map[string]any{"log_backup_minutes": 5}, 75, 90},
		{map[string]any{"identity_warn_pct": 50, "identity_crit_pct": 80}, 50, 80},
		{map[string]any{"identity_warn_pct": 62.5}, 62.5, 90},
		{map[string]any{"identity_crit_pct": uint64(100)}, 75, 100},
		{map[string]any{"identity_warn_pct": 10, "identity_crit_pct": 11}, 10, 11},
	} {
		if w, cr, err := IdentityLimits(c.in); err != nil || w != c.warn || cr != c.crit {
			t.Errorf("%v: %v / %v (%v), want %v / %v", c.in, w, cr, err, c.warn, c.crit)
		}
	}
	for _, c := range []struct {
		in   map[string]any
		says string
	}{
		{map[string]any{"identity_warn_pct": 80, "identity_crit_pct": 80}, "identity_warn_pct 80 is not under identity_crit_pct 80"},
		{map[string]any{"identity_crit_pct": 60}, "identity_warn_pct 75 is not under identity_crit_pct 60"},
		{map[string]any{"identity_warn_pct": 9}, "identity_warn_pct: 9 is not a number from 10 to 100"},
		{map[string]any{"identity_crit_pct": 100.5}, "identity_crit_pct: 100.5 is not a number from 10 to 100"},
		{map[string]any{"identity_warn_pct": "half"}, "identity_warn_pct: half is not a number"},
		{map[string]any{"identity_warn_pct": -1, "identity_crit_pct": "x"}, "identity_warn_pct: -1 is not a number"},
	} {
		w, cr, err := IdentityLimits(c.in)
		if err == nil || !strings.Contains(err.Error(), c.says) || w != 75 || cr != 90 {
			t.Errorf("%v: %v / %v, error %v, want the defaults and an error saying %q", c.in, w, cr, err, c.says)
		}
	}
	// the threshold store's one-row payload leaves the two names out and refuses a bad pair with the rest
	rows, err := ThresholdRows(map[string]any{"identity_warn_pct": 50, "identity_crit_pct": 80, "log_backup_minutes": 5})
	if err != nil || len(rows) != 1 || len(rows[0]) != 1 || rows[0]["log_backup_minutes"] != 5.0 {
		t.Errorf("the threshold payload with the identity lines set: %v %v", rows, err)
	}
	if _, err := ThresholdRows(map[string]any{"identity_warn_pct": 95}); err == nil || !strings.Contains(err.Error(), "identity_warn_pct 95 is not under identity_crit_pct 90") {
		t.Errorf("a warning line over the default critical one: %v", err)
	}
	// the lines on Info (the runner's hand-off), the defaults when none is set
	if w, cr := identityLines(Info{}); w != 75 || cr != 90 {
		t.Errorf("no line set: %v / %v", w, cr)
	}
	if w, cr := identityLines(Info{IdentityWarnPct: 50, IdentityCritPct: 55}); w != 50 || cr != 55 {
		t.Errorf("both set: %v / %v", w, cr)
	}
	// one column at 60 %: ok under the default lines, a warning at 50 / 80, critical at 50 / 55
	raw := []collect.Row{{"columns_total": int64(1), "schema_name": "dbo", "table_name": "t", "column_name": "id", "type_name": "tinyint", "last_value": "153", "max_value": "255", "pct_used": "60.00"}}
	if rows, fs := identityRows("shop", raw); len(rows) != 1 || rows[0]["status"] != "ok" || len(fs) != 0 {
		t.Errorf("the default lines: %v %+v", rows, fs)
	}
	rows, fs := identityRowsAt("shop", raw, 50, 80)
	if len(rows) != 1 || rows[0]["status"] != "warn" || len(fs) != 1 || fs[0].Severity != "warning" || !strings.Contains(fs[0].Explain, "(warning at 50, critical at 80)") {
		t.Errorf("50 / 80: %v %+v", rows, fs)
	}
	rows, fs = identityRowsAt("shop", raw, 50, 55)
	if len(rows) != 1 || rows[0]["status"] != "crit" || len(fs) != 1 || fs[0].Severity != "critical" || !strings.Contains(fs[0].Explain, "(warning at 50, critical at 55)") {
		t.Errorf("50 / 55: %v %+v", rows, fs)
	}
}

// TestLinkedTestMessage: the text kept for a connection test never names a remote login - a refused login's errors
// keep one fixed sentence, any other text is cut from a login, user or principal named in quotes through its last
// quote (a name may hold a quote), and a text that names none is kept as it is.
func TestLinkedTestMessage(t *testing.T) {
	for _, n := range []int64{18452, 18456, 18470, 18486, 18487, 18488} {
		if got := linkedTestMessage(n, "Login failed for user 'fin_link'. Reason: the account is disabled."); got != linkedLoginRefusedText || strings.Contains(got, "fin_link") {
			t.Errorf("error %d: %q", n, got)
		}
	}
	for _, c := range []struct{ in, want string }{
		{"Login failed for user 'fin_link'.", "Login failed for user '<not stored>'."},
		{`The server principal "CORP\\svc link" is not able to access the database "sales" under the current security context.`,
			`The server principal '<not stored>' under the current security context.`},
		{"Login failed for user 'O'Brien'. Try again.", "Login failed for user '<not stored>'. Try again."},
		{"Cannot open database requested by the login 'a'. The LOGIN 'x' failed.", "Cannot open database requested by the login '<not stored>' failed."},
		{"Named Pipes Provider: Could not open a connection to SQL Server [53].", "Named Pipes Provider: Could not open a connection to SQL Server [53]."},
		{"", ""},
	} {
		if got := linkedTestMessage(7399, c.in); got != c.want {
			t.Errorf("%q: %q, want %q", c.in, got, c.want)
		}
	}
	if got := linkedTestMessage(0, "context deadline exceeded: login 'fin_link'"); strings.Contains(got, "fin_link") {
		t.Errorf("a test cut at its deadline: %q", got)
	}
}

// TestNumErrorLogsRows: a NumErrorLogs value read is the count; no value on Windows is the default of 6 only while the
// files present agree (the registry read cannot tell 'not set' from 'not readable'); on Linux no value is not read.
func TestNumErrorLogsRows(t *testing.T) {
	for _, c := range []struct {
		platform  string
		kept      int64
		set       bool
		files     int64
		filesRead bool
		read      bool
		count     any
		noteHolds string
	}{
		{"Windows", 30, true, 31, true, true, int64(30), ""},
		{"Linux", 12, true, 13, true, true, int64(12), ""},
		{"Windows", 0, false, 7, true, true, int64(6), "the default of 6 applies"},
		{"Windows", 0, false, 3, true, true, int64(6), "the default of 6 applies"},
		{"Windows", 0, false, 31, true, false, nil, "the server keeps 31 error log files (more than the default keeps)"},
		{"Windows", 0, false, -1, false, false, nil, "the error log files were not listed"},
		{"Linux", 0, false, 7, true, false, nil, "errorlog.numerrorlogs is not set in mssql.conf"},
		{"", 0, false, 7, true, false, nil, "the host's platform is not known"},
	} {
		rows := numErrorLogsRows(c.platform, c.kept, c.set, c.files, c.filesRead)
		part := rows[0]
		var count any
		for _, r := range rows[1:] {
			if r["key"] == "num_errorlogs" {
				count = r["value"]
			}
		}
		note, _ := part["note"].(string)
		if (part["read"] == 1) != c.read || count != c.count || !strings.Contains(note, c.noteHolds) {
			t.Errorf("%+v: part %v, count %v", c, part, count)
		}
	}
}
