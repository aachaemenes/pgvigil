package mssql

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func TestAuditCollector(t *testing.T) {
	c, ok := Get("mssql_audit")
	if !ok {
		t.Fatal("mssql_audit is not registered")
	}
	if c.DefaultInterval() != 5*time.Minute {
		t.Errorf("default interval %v", c.DefaultInterval())
	}
	if _, ok := c.(BatchCollector); !ok {
		t.Error("mssql_audit must read from a cursor (a BatchCollector)")
	}
	if ok, why := c.Applies(Info{Kind: KindAzureDB, ViewServerState: true, ViewAnyDefinition: true}); ok || !strings.Contains(why, "Azure SQL Database") {
		t.Errorf("Azure SQL Database: %v %q", ok, why)
	}
	if ok, why := c.Applies(Info{Kind: KindServer}); ok || !strings.Contains(why, "VIEW ANY DEFINITION") || !strings.Contains(why, "VIEW SERVER STATE") {
		t.Errorf("a login with neither right: %v %q", ok, why)
	}
	// either right alone is enough for a part of the health
	for _, in := range []Info{{Kind: KindServer, ViewServerState: true}, {Kind: KindServer, ViewAnyDefinition: true},
		{Kind: KindRDS, ViewServerState: true, ViewAnyDefinition: true}, {Kind: KindAzureMI, ViewAnyDefinition: true}} {
		if ok, why := c.Applies(in); !ok {
			t.Errorf("%+v: skipped: %s", in, why)
		}
	}
	// nothing of the collection writes, changes an audit or runs a procedure of its own
	all := []string{auditRightsSQL, auditDefsSQL, auditStatusSQL, auditServerSpecsSQL, auditDatabaseSpecsSQL, auditDatabasesSQL,
		auditFileQuery("sys.fn_get_audit_file", map[string]bool{"client_ip": true}, true)}
	for _, q := range all {
		// a word inside a string literal (a permission's name, a command the maintenance answer names) is no
		// statement: the literals are taken out before the scan
		u := regexp.MustCompile(`'(?:[^']|'')*'`).ReplaceAllString(strings.ToUpper(q), "''")
		for _, bad := range []string{"EXEC ", "EXECUTE ", "INSERT ", "UPDATE ", "DELETE ", "ALTER ", "CREATE ", "DROP ", "XP_", " SP_", ".SP_"} {
			if strings.Contains(u, bad) {
				t.Errorf("a statement holds %q: %s", bad, q)
			}
		}
	}
}

func TestAuditRights(t *testing.T) {
	row := func(names ...string) collect.Row {
		r := collect.Row{}
		for _, n := range names {
			r[n] = int64(1)
		}
		return r
	}
	s2019, s2022 := Info{Kind: KindServer, Major: 15}, Info{Kind: KindServer, Major: 16}
	cases := []struct {
		name string
		info Info
		row  collect.Row
		want auditRights
	}{
		{"the monitoring login on 2022", s2022, row("view_any_definition", "view_any_security_definition", "view_server_state", "view_server_security_state"),
			auditRights{defs: true, dbDefs: true, state: true, events: false, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
		{"with the 2022 read right", s2022, row("view_any_definition", "view_server_state", "view_security_audit"),
			auditRights{defs: true, dbDefs: true, state: true, events: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
		{"the same grant means nothing on 2019", s2019, row("view_any_definition", "view_server_state", "view_security_audit"),
			auditRights{defs: true, dbDefs: true, state: true, events: false, eventsRight: "CONTROL SERVER"}},
		{"CONTROL SERVER on 2019", s2019, row("control_server"),
			auditRights{defs: true, dbDefs: true, state: true, events: true, eventsRight: "CONTROL SERVER"}},
		{"CONTROL SERVER on 2022", s2022, row("control_server"),
			auditRights{defs: true, dbDefs: true, state: true, events: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
		{"the state view alone", s2022, row("view_server_state"),
			auditRights{state: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
		{"the two narrow 2022 rights", s2022, row("view_any_security_definition", "view_server_security_state"),
			auditRights{defs: true, dbDefs: true, state: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
		{"ALTER ANY SERVER AUDIT lists the server's audits, not a database's", s2022, row("alter_any_server_audit"),
			auditRights{defs: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
		{"RDS reads through its own function", Info{Kind: KindRDS, Major: 16}, row("view_any_definition", "view_server_state", "rds_reader", "view_security_audit"),
			auditRights{defs: true, dbDefs: true, state: true, events: true, eventsRight: "SELECT on msdb.dbo.rds_fn_get_audit_file"}},
		{"RDS without the function's right", Info{Kind: KindRDS, Major: 16}, row("view_any_definition", "view_server_state", "view_security_audit"),
			auditRights{defs: true, dbDefs: true, state: true, events: false, eventsRight: "SELECT on msdb.dbo.rds_fn_get_audit_file"}},
		{"a managed instance has the current engine's rights", Info{Kind: KindAzureMI, Major: 12}, row("view_security_audit"),
			auditRights{events: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}},
	}
	for _, c := range cases {
		if got := auditRightsOf(c.info, c.row); got != c.want {
			t.Errorf("%s: %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestAuditStateAndTarget(t *testing.T) {
	on, off := true, false
	cases := []struct {
		enabled   *bool
		status    string
		stateRead bool
		want      string
	}{
		{&on, "STARTED", true, "started"},
		{nil, "STARTED", true, "started"}, // the state view alone
		{&off, "", true, "stopped"},       // measured: a stopped audit has no row in the state view
		{&off, "", false, "stopped"},      // the catalog alone says it is off
		{&on, "", true, "failed"},         // switched on and not among the audits the server runs
		{&on, "", false, "enabled"},       // switched on; the state view was not readable
		{&on, "RUNTIME_FAIL", true, "failed"},
		{&on, "TARGET_CREATION_FAILED", true, "failed"},
		{&on, "SHUTTING_DOWN", true, "shutting down"},
		{&off, "NOT_STARTED", true, "stopped"},
		{nil, "", false, "unknown"},
	}
	for _, c := range cases {
		if got := auditState(c.enabled, c.status, c.stateRead); got != c.want {
			t.Errorf("enabled %v status %q stateRead %v: %q, want %q", c.enabled, c.status, c.stateRead, got, c.want)
		}
	}
	for typ, want := range map[string]string{"FL": "file", "AL": "application log", "SL": "security log", "UL": "url", "EM": "external monitor", "": ""} {
		if got := auditTarget(typ, "WHATEVER"); got != want {
			t.Errorf("target of %q: %q, want %q", typ, got, want)
		}
	}
	if got := auditTarget("ZZ", "SOMETHING NEW"); got != "something new" {
		t.Errorf("an unknown target type is named by the server's own word: %q", got)
	}
}

func TestAuditPattern(t *testing.T) {
	cases := [][3]string{
		{"/var/opt/mssql/audit/", "sec_D900AFB9-F486-474D-949A-D9107D3D52CD.sqlaudit", "/var/opt/mssql/audit/sec_D900AFB9-F486-474D-949A-D9107D3D52CD*.sqlaudit"},
		{"/var/opt/mssql/audit", "sec_G.sqlaudit", "/var/opt/mssql/audit/sec_G*.sqlaudit"},
		{`D:\Audit\`, "sec_G.sqlaudit", `D:\Audit\sec_G*.sqlaudit`},
		{`D:\rdsdbdata\SQLAudit`, "sec_G.SQLAUDIT", `D:\rdsdbdata\SQLAudit\sec_G*.sqlaudit`},
		{"", "sec_G.sqlaudit", ""},
		{"/x/", "", ""},
	}
	for _, c := range cases {
		if got := auditPattern(c[0], c[1]); got != c[2] {
			t.Errorf("auditPattern(%q, %q) = %q, want %q", c[0], c[1], got, c[2])
		}
	}
}

func TestAuditCategory(t *testing.T) {
	cases := []struct {
		action, class, db string
		category          string
		keep              bool
		object, maint     string
		name              string
	}{
		{"LGIF", "LX", "", auditFailedLogin, true, "", "", ""},
		{"DBAF", "US", "appdb", auditFailedLogin, true, "", "", ""},
		{"APRL", "SG", "master", auditRole, true, "", "", ""},
		{"DPRL", "RL", "appdb", auditRole, true, "", "", ""},
		{"G   ", "SR", "master", auditPermission, true, "", "", ""}, // the server pads an action id to four characters
		{"RWC", "U ", "appdb", auditPermission, true, "", "", ""},
		{"TO", "U", "appdb", auditPermission, true, "", "", ""},
		{"PWR", "SL", "master", auditPrincipal, true, "", "", ""},
		{"LGDA", "SL", "master", auditPrincipal, true, "", "", ""},
		{"CR  ", "SL", "master", auditDDL, true, "", "", ""},
		{"DR", "U", "appdb", auditDDL, true, "", "", ""},
		{"AL", "A ", "master", auditChange, true, "", "", ""}, // ALTER SERVER AUDIT
		{"CR", "SA", "master", auditChange, true, "", "", ""}, // a server audit specification
		{"DR", "DA", "appdb", auditChange, true, "", "", ""},  // a database audit specification
		{"AUSC", "A", "", auditChange, true, "", "", ""},      // the audit started or stopped
		{"CR", "U", "tempdb", auditDDL, false, "", "", ""},    // a temporary table: counted
		{"CR", "ST", "appdb", auditDDL, false, "", "", ""},    // a statistics class: counted (the server writes ALTER on U for statistics commands: below)
		{"SL", "U", "appdb", "read", false, "", "", ""},
		{"IN", "U", "appdb", "write", false, "", "", ""},
		{"UP", "U", "appdb", "write", false, "", "", ""},
		{"DL", "U", "appdb", "write", false, "", "", ""},
		{"EX", "P", "appdb", "execute", false, "", "", ""},
		{"LGIS", "LX", "", "sign-in", false, "", "", ""},
		{"LGO", "LX", "", "sign-out", false, "", "", ""},
		{"BCM", "DB", "appdb", "batch", false, "", "", ""},
		{"TXCM", "DB", "appdb", "transaction", false, "", "", ""},
		{"TRBC", "DB", "appdb", "transaction", false, "", "", ""},
		{"TRO", "U", "appdb", auditDDL, true, "", "", ""}, // a transfer between schemas is a kept action, not a transaction pair
		{"DBCC", "DB", "appdb", "other", false, "", "", ""},
		{"ZZZZ", "", "", "other", false, "", "", ""},
		// measured on SQL Server 2022: index and statistics commands and TRUNCATE are ALTER on the table; the server names
		// the command (auditMaintSQL) and only those words leave it
		{"AL", "U", "appdb", "maintenance", false, "t", "CREATE INDEX", "CREATE INDEX"},
		{"AL", "U", "appdb", "maintenance", false, "t", "UPDATE STATISTICS", "UPDATE STATISTICS"},
		{"AL", "U", "appdb", "write", false, "t", "TRUNCATE TABLE", "TRUNCATE TABLE"},
		{"AL", "U", "appdb", auditDDL, true, "t", "", ""},                // ALTER TABLE ... ADD: listed
		{"AL", "SC", "appdb", auditDDL, true, "dbo", "CREATE INDEX", ""}, // a maint answer only counts on a table
		{"CR", "SE", "master", "maintenance", false, "telemetry_xevents", "", "telemetry session CREATE"},
		{"CR", "SE", "master", auditDDL, true, "capture_logins", "", ""}, // any other event session: listed
	}
	for _, c := range cases {
		cat, keep, name := auditCategory(c.action, c.class, c.db, c.object, c.maint)
		if cat != c.category || keep != c.keep || name != c.name {
			t.Errorf("auditCategory(%q, %q, %q, %q, %q) = %q, %v, %q; want %q, %v, %q", c.action, c.class, c.db, c.object, c.maint, cat, keep, name, c.category, c.keep, c.name)
		}
	}
	// every kept action has the server's name, and the reader's statement names every kept action
	for a := range auditKeptActions {
		if auditName(auditActionNames, a) == a {
			t.Errorf("the kept action %s has no name", a)
		}
		if !strings.Contains(auditTextActions, "N'"+a+"'") {
			t.Errorf("the reader's statement does not name the kept action %s", a)
		}
	}
	if auditName(auditActionNames, " g ") != "GRANT" || auditName(auditClassNames, "sa") != "SERVER AUDIT SPECIFICATION" || auditName(auditClassNames, "??") != "??" {
		t.Error("auditName: padded and lower-case codes are named, an unknown one is shown as it is")
	}
}

func TestAuditInfo(t *testing.T) {
	failed := `<action_info xmlns="http://schemas.microsoft.com/sqlserver/2008/sqlaudit_data"><pooled_connection>0</pooled_connection><error>0x00004818</error><state>8</state><address>172.18.0.2</address><PasswordFirstNibbleHash>6</PasswordFirstNibbleHash></action_info>`
	n, st, act := auditInfo(failed)
	if n != int64(18456) || st != int64(8) || act != "" {
		t.Errorf("a failed sign-in: error %v state %v action %q, want 18456, 8, none", n, st, act)
	}
	changed := `<action_info xmlns="http://schemas.microsoft.com/sqlserver/2008/sqlaudit_data"><session><![CDATA[sec$A]]></session><action>event disabled</action><object><![CDATA[audit_event]]></object></action_info>`
	if n, st, act := auditInfo(changed); n != nil || st != nil || act != "event disabled" {
		t.Errorf("an audit session change: %v %v %q", n, st, act)
	}
	if n, st, act := auditInfo(""); n != nil || st != nil || act != "" {
		t.Errorf("nothing: %v %v %q", n, st, act)
	}
}

func TestAuditCutAndKey(t *testing.T) {
	rec := func(file string, off int64) collect.Row { return collect.Row{"file_name": file, "file_offset": off} }
	rows := []collect.Row{rec("a", 16384), rec("a", 16384), rec("a", 28672), rec("a", 28672), rec("b", 16384)}
	cases := []struct {
		n, top int
		cut    int
		more   bool
		grow   bool
	}{
		{5, 5, 5, false, false}, // everything: every buffer is whole
		{5, 9, 5, false, false},
		{5, 4, 4, true, false}, // the extra record is the next buffer's first: the cut is its edge
		{4, 3, 2, true, false}, // the extra record is inside the second buffer: back to the first buffer's edge
		{2, 1, 0, true, true},  // one buffer larger than the batch: read on
		{0, 3, 0, false, false},
	}
	for _, c := range cases {
		cut, more, grow := auditCut(rows[:c.n], c.top)
		if cut != c.cut || more != c.more || grow != c.grow {
			t.Errorf("auditCut(%d rows, top %d) = %d, %v, %v; want %d, %v, %v", c.n, c.top, cut, more, grow, c.cut, c.more, c.grow)
		}
	}
	// the same file under two folders (RDS moves a finished file) is the same record; the same offset in another
	// file, or another place in the buffer, is not
	k := auditKey(`D:\rdsdbdata\SQLAudit\sec_G_0_1.sqlaudit`, 16384, 3)
	if k != auditKey(`D:\rdsdbdata\SQLAudit\transmitted\SEC_G_0_1.sqlaudit`, 16384, 3) {
		t.Error("the key must not hold the folder")
	}
	if k == auditKey("/x/sec_G_0_2.sqlaudit", 16384, 3) || k == auditKey("/x/sec_G_0_1.sqlaudit", 16384, 4) || k == auditKey("/x/sec_G_0_1.sqlaudit", 28672, 3) {
		t.Error("another file, place or buffer must be another key")
	}
	if len(k) != 32 {
		t.Errorf("key %q", k)
	}
}

// auditFake is an audit file set in memory and a repository's cursor table.
type auditFake struct {
	recs    []collect.Row
	gone    map[string]bool // files that are no longer there
	cursors map[string]Cursor
	batches [][]collect.Row
	calls   []string
}

func (f *auditFake) add(file string, off int64, at, action, class, login, db, object, statement string) {
	r := collect.Row{"event_at": at, "seq": int64(1), "action_id": action, "succeeded": int64(1), "class_type": class, "session_id": int64(55),
		"session_login": login, "login_name": login, "database_name": db, "schema_name": "", "object_name": object, "statement": nil,
		"additional_information": nil, "file_name": file, "file_offset": off, "client_ip": "10.0.0.9", "application_name": "app", "host_name": "h1"}
	if statement != "" {
		r["statement"] = statement
	}
	f.recs = append(f.recs, r)
}

// query answers as sys.fn_get_audit_file does: a pattern that is one file's path or ends in *.sqlaudit, the records
// after the cursor's buffer, 33225 for a cursor whose file is not in the set.
func (f *auditFake) query(pattern string, top int, cur Cursor) ([]collect.Row, error) {
	f.calls = append(f.calls, fmt.Sprintf("%s|%d|%s|%d", pattern, top, cur.FileName, cur.FileOffset))
	prefix, exact := strings.TrimSuffix(pattern, "*.sqlaudit"), !strings.Contains(pattern, "*")
	var set []collect.Row
	for _, r := range f.recs {
		file := rowText(r, "file_name")
		if f.gone[file] || (exact && file != pattern) || (!exact && !strings.HasPrefix(file, prefix)) {
			continue
		}
		set = append(set, r)
	}
	start := 0
	if cur.FileName != "" {
		found := false
		for i, r := range set {
			off, _ := asInt(r["file_offset"])
			if rowText(r, "file_name") == cur.FileName && off == cur.FileOffset {
				found, start = true, i+1
			}
		}
		if !found {
			return nil, mssqldb.Error{Number: 33225, Message: "The specified values for initial_file_name and audit_record_offset do not represent a valid location within the audit file set."}
		}
	}
	out := set[start:]
	if len(out) > top {
		out = out[:top]
	}
	return out, nil
}

func (f *auditFake) reader(text bool) *auditReader {
	if f.cursors == nil {
		f.cursors = map[string]Cursor{}
	}
	return &auditReader{text: text, deadline: time.Now().Add(time.Hour), now: time.Now, query: f.query,
		cursor: func(_ context.Context, source string) (Cursor, error) { return f.cursors[source], nil },
		emit: func(rows []collect.Row) error {
			f.batches = append(f.batches, rows)
			for _, r := range rows {
				if r["kind"] != CursorKind {
					continue
				}
				c := Cursor{Found: true, FileName: rowText(r, "file_name")}
				c.FileOffset, _ = asInt(r["file_offset"])
				c.LastEventAt, _ = time.Parse(time.RFC3339Nano, rowText(r, "last_event_at"))
				f.cursors[rowText(r, "source")] = c
			}
			return nil
		}}
}

func (f *auditFake) kinds(kind string) []collect.Row {
	var out []collect.Row
	for _, b := range f.batches {
		for _, r := range b {
			if r["kind"] == kind {
				out = append(out, r)
			}
		}
	}
	return out
}

func auditTestDef() *auditDef {
	return &auditDef{name: "sec", guid: "D900AFB9-F486-474D-949A-D9107D3D52CD", typ: "FL", logPath: "/a/", logName: "sec_G.sqlaudit",
		current: "/a/sec_G_0_2.sqlaudit", row: collect.Row{}}
}

func TestAuditReadBatches(t *testing.T) {
	defer func(b, c int) { auditBatchRows, auditRowCap = b, c }(auditBatchRows, auditRowCap)
	auditBatchRows, auditRowCap = 3, 1000
	f := &auditFake{}
	// an older file the first read must not load, then the file written now: a buffer of 2, one of 5 (larger than
	// the batch of 3) and one of 1
	f.add("/a/sec_G_0_1.sqlaudit", 16384, "2026-11-10T08:00:00.0000001Z", "CR", "SL", "sa", "master", "old_login", "CREATE LOGIN old_login")
	f.add("/a/sec_G_0_2.sqlaudit", 16384, "2026-11-11T10:00:00.1000000Z", "AUSC", "A", "sa", "", "", "")
	f.add("/a/sec_G_0_2.sqlaudit", 16384, "2026-11-11T10:00:01.0000000Z", "CR", "SL", "sa", "master", "app_login", "CREATE LOGIN app_login WITH PASSWORD = '******'")
	for i := 0; i < 3; i++ {
		f.add("/a/sec_G_0_2.sqlaudit", 28672, fmt.Sprintf("2026-11-11T10:05:0%d.0000000Z", i), "SL", "U", "app_login", "appdb", "orders", "SELECT * FROM orders WHERE id = 7")
	}
	f.add("/a/sec_G_0_2.sqlaudit", 28672, "2026-11-11T10:05:04.0000000Z", "IN", "U", "app_login", "appdb", "orders", "INSERT orders VALUES (1, 'secret')")
	f.add("/a/sec_G_0_2.sqlaudit", 28672, "2026-11-11T11:00:00.0000000Z", "SL", "U", "app_login", "appdb", "orders", "SELECT 1")
	f.add("/a/sec_G_0_2.sqlaudit", 32768, "2026-11-11T11:00:05.0000000Z", "G", "SR", "sa", "master", "", "GRANT VIEW SERVER STATE TO app_login")
	a := auditTestDef()
	res, err := f.reader(false).read(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	// expected: three kept events (the session change, the login, the grant), five counted (4 SELECT, 1 INSERT),
	// nothing of the older file, the cursor on the last buffer, and two batches that each end on a buffer's edge:
	// the first buffer alone (the batch of 3 would have cut the second buffer), then - after the read grew to take
	// the second buffer of 5 whole - the rest. Three reads of the server: 4, 4 and 13 records asked.
	if res.listed != 3 || res.counted != 5 {
		t.Errorf("listed %d counted %d, want 3 and 5", res.listed, res.counted)
	}
	if len(f.batches) != 2 || len(f.calls) != 3 {
		t.Fatalf("%d batches and %d reads, want 2 and 3: calls %v", len(f.batches), len(f.calls), f.calls)
	}
	if !strings.HasSuffix(f.calls[1], "|4|/a/sec_G_0_2.sqlaudit|16384") || !strings.HasSuffix(f.calls[2], "|13|/a/sec_G_0_2.sqlaudit|16384") {
		t.Errorf("the second batch must start after the first buffer and grow to take the next one whole: %v", f.calls[1:])
	}
	if n := len(f.batches[0]); n != 3 || f.batches[0][2]["kind"] != CursorKind {
		t.Errorf("the first batch: two events and its cursor, got %d rows", n)
	}
	// each batch names the cursor it started from: none for the first read, then the first batch's end
	if c := f.batches[0][2]; c["from_file"] != nil || c["from_offset"] != nil {
		t.Errorf("the first read's batch names a start: %v / %v", c["from_file"], c["from_offset"])
	}
	if c := f.batches[1][len(f.batches[1])-1]; c["kind"] != CursorKind || c["from_file"] != "/a/sec_G_0_2.sqlaudit" || c["from_offset"] != int64(16384) {
		t.Errorf("the second batch's start: %v", c)
	}
	if !strings.HasPrefix(f.calls[0], "/a/sec_G_0_2.sqlaudit|4||") {
		t.Errorf("the first read must name the file written now and no cursor: %s", f.calls[0])
	}
	for _, c := range f.calls[1:] {
		if !strings.HasPrefix(c, "/a/sec_G*.sqlaudit|") || strings.HasSuffix(c, "||0") {
			t.Errorf("a later read must name the whole set and the cursor: %s", c)
		}
	}
	evs := f.kinds("audit_event")
	if len(evs) != 3 {
		t.Fatalf("%d events, want 3", len(evs))
	}
	for _, e := range evs {
		if _, has := e["statement"]; has {
			t.Errorf("no statement text is stored without the opt-in: %v", e)
		}
		if e["object_name"] == "old_login" {
			t.Error("the first read loaded the older file")
		}
	}
	if evs[0]["category"] != auditChange || evs[1]["category"] != auditDDL || evs[1]["object_name"] != "app_login" || evs[1]["action"] != "CREATE" ||
		evs[1]["class_name"] != "SQL LOGIN" || evs[2]["category"] != auditPermission || evs[1]["client_ip"] != "10.0.0.9" {
		t.Errorf("the events: %v", evs)
	}
	if evs[0]["event_key"] == evs[1]["event_key"] {
		t.Error("two records of one buffer must have two keys")
	}
	var sel10, sel11, ins int64
	for _, c := range f.kinds("audit_count") {
		n := c["n"].(int64)
		switch {
		case c["action_id"] == "SL" && c["hour_at"] == "2026-11-11T10:00:00Z":
			sel10 += n
		case c["action_id"] == "SL" && c["hour_at"] == "2026-11-11T11:00:00Z":
			sel11 += n
		case c["action_id"] == "IN" && c["category"] == "write" && c["object_name"] == "orders" && c["login_name"] == "app_login":
			ins += n
		default:
			t.Errorf("an unexpected count: %v", c)
		}
		for _, v := range c {
			if s, ok := v.(string); ok && strings.Contains(s, "secret") {
				t.Errorf("a count carries statement text: %v", c)
			}
		}
	}
	if sel10 != 3 || sel11 != 1 || ins != 1 {
		t.Errorf("counts: SELECT 10h %d, 11h %d, INSERT %d; want 3, 1, 1", sel10, sel11, ins)
	}
	cur := f.cursors[auditSource(a.guid)]
	if cur.FileName != "/a/sec_G_0_2.sqlaudit" || cur.FileOffset != 32768 || !cur.LastEventAt.Equal(time.Date(2026, 11, 11, 11, 0, 5, 0, time.UTC)) {
		t.Errorf("the cursor: %+v", cur)
	}
	if len(res.notes) != 1 || !strings.Contains(res.notes[0], "first read") {
		t.Errorf("notes: %v", res.notes)
	}

	// a second read finds nothing new and stores nothing
	n := len(f.batches)
	res, err = f.reader(false).read(context.Background(), a)
	if err != nil || res.listed != 0 || res.counted != 0 || len(f.batches) != n || len(res.notes) != 0 {
		t.Errorf("the second read: %+v, %v, %d new batches", res, err, len(f.batches)-n)
	}

	// the cursor's file is rolled away: the set is read again from its oldest file and only what is newer than the
	// newest event already read is stored
	f.add("/a/sec_G_0_3.sqlaudit", 16384, "2026-11-11T10:30:00.0000000Z", "DR", "SL", "sa", "master", "late_but_old", "DROP LOGIN x")
	// at the very time of the newest event read before (the floor): an unread record of a newer file, kept
	f.add("/a/sec_G_0_3.sqlaudit", 16384, "2026-11-11T11:00:05.0000000Z", "DR", "SL", "sa", "master", "same_tick", "DROP LOGIN y")
	f.add("/a/sec_G_0_3.sqlaudit", 16384, "2026-11-11T12:00:00.0000000Z", "DR", "SL", "sa", "master", "app_login", "DROP LOGIN app_login")
	f.gone = map[string]bool{"/a/sec_G_0_1.sqlaudit": true, "/a/sec_G_0_2.sqlaudit": true}
	f.batches = nil
	res, err = f.reader(false).read(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	evs = f.kinds("audit_event")
	if len(evs) != 2 || evs[0]["object_name"] != "same_tick" || evs[1]["object_name"] != "app_login" || evs[1]["action"] != "DROP" || res.listed != 2 {
		t.Errorf("after the cursor's file was gone (want same_tick and app_login, not late_but_old): %v (listed %d)", evs, res.listed)
	}
	if len(res.notes) != 1 || !strings.Contains(res.notes[0], "is gone") || !strings.Contains(res.notes[0], "lost") {
		t.Errorf("notes: %v", res.notes)
	}
	// the re-read's batch names where the repository's cursor stood (the gone file), not where the read began
	for _, r := range f.kinds(CursorKind) {
		if r["from_file"] != "/a/sec_G_0_2.sqlaudit" || r["from_offset"] != int64(32768) {
			t.Errorf("the re-read's cursor row names its start as %v / %v, want the stored cursor", r["from_file"], r["from_offset"])
		}
	}
	if cur := f.cursors[auditSource(a.guid)]; cur.FileName != "/a/sec_G_0_3.sqlaudit" || !cur.LastEventAt.Equal(time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)) {
		t.Errorf("the cursor after the re-read: %+v", cur)
	}
}

func TestAuditReadTextCapAndNeverStarted(t *testing.T) {
	defer func(b, c int) { auditBatchRows, auditRowCap = b, c }(auditBatchRows, auditRowCap)
	auditBatchRows, auditRowCap = 100, 2
	f := &auditFake{}
	file := "/a/sec_G_0_2.sqlaudit"
	f.add(file, 16384, "2026-11-11T10:00:00.0000000Z", "LGIF", "LX", "ghost", "", "", "Login failed for user 'ghost'. Reason: Could not find a login matching the name provided. [CLIENT: 10.0.0.9]")
	f.recs[0]["succeeded"] = int64(0)
	f.recs[0]["additional_information"] = "<action_info><error>0x00004818</error><state>5</state><PasswordFirstNibbleHash>6</PasswordFirstNibbleHash></action_info>"
	// a secret cut between the two rows of one record (a statement over 4,000 characters is written as several rows):
	// neither piece alone holds both quotes, so the text is masked once it is whole
	f.add(file, 16384, "2026-11-11T10:00:01.0000000Z", "CR", "CD", "sa", "master", "cred", "CREATE CREDENTIAL cred WITH IDENTITY = 'u', SECRET = 'hun")
	f.add(file, 16384, "2026-11-11T10:00:01.0000000Z", "CR", "CD", "sa", "master", "cred", "ter2' /* the rest */")
	f.recs[2]["seq"] = int64(2)
	f.add(file, 16384, "2026-11-11T10:00:02.0000000Z", "APRL", "SG", "sa", "master", "sysadmin", "ALTER SERVER ROLE sysadmin ADD MEMBER app_login")
	f.recs[3]["target_login"] = "app_login"
	a := auditTestDef()
	res, err := f.reader(true).read(context.Background(), a)
	if err != nil {
		t.Fatal(err)
	}
	// expected: the continuation row is no event; two events listed (the cap), the third counted under its own
	// category with the cap's note
	if res.listed != 2 || res.counted != 1 || res.overCap != 1 {
		t.Errorf("listed %d counted %d over the cap %d; want 2, 1, 1", res.listed, res.counted, res.overCap)
	}
	evs := f.kinds("audit_event")
	if len(evs) != 2 {
		t.Fatalf("%d events, want 2", len(evs))
	}
	login := evs[0]
	if login["category"] != auditFailedLogin || login["succeeded"] != false || login["error_number"] != int64(18456) || login["error_state"] != int64(5) ||
		!strings.Contains(fmt.Sprint(login["reason"]), "Could not find a login") {
		t.Errorf("the failed sign-in: %v", login)
	}
	if _, has := login["statement"]; has {
		t.Error("a failed sign-in's message is its reason, never a statement")
	}
	for k, v := range login {
		if s, ok := v.(string); ok && strings.Contains(s, "NibbleHash") {
			t.Errorf("the password hash fragment was kept in %s", k)
		}
	}
	st := fmt.Sprint(evs[1]["statement"])
	if strings.Contains(st, "hun") || strings.Contains(st, "ter2") || !strings.Contains(st, "<masked>") || !strings.HasSuffix(st, "/* the rest */") {
		t.Errorf("the statement must be masked and joined with its second row: %q", st)
	}
	counts := f.kinds("audit_count")
	if len(counts) != 1 || counts[0]["category"] != auditRole || counts[0]["action_id"] != "APRL" || counts[0]["object_name"] != "sysadmin" || counts[0]["n"] != int64(1) {
		t.Errorf("the event over the cap: %v", counts)
	}
	found := false
	for _, n := range res.notes {
		found = found || strings.Contains(n, "counted and not listed")
	}
	if !found {
		t.Errorf("notes: %v", res.notes)
	}

	// an audit never read whose open file is not known: nothing is read, and it says so
	g := &auditFake{}
	g.add(file, 16384, "2026-11-11T10:00:00.0000000Z", "CR", "SL", "sa", "master", "x", "")
	b := auditTestDef()
	b.current = ""
	res, err = g.reader(false).read(context.Background(), b)
	if err != nil || !res.waiting || len(g.calls) != 0 || len(g.batches) != 0 || len(res.notes) != 1 || !strings.Contains(res.notes[0], "never read") {
		t.Errorf("a stopped audit never read: %+v %v, %d calls", res, err, len(g.calls))
	}
	// an audit without a file path cannot be read
	c := auditTestDef()
	c.logPath = ""
	if _, err := g.reader(false).read(context.Background(), c); err == nil {
		t.Error("an audit that names no path must be an error")
	}
}

func TestAuditSpecRowsAndQuery(t *testing.T) {
	rows := []collect.Row{
		{"name": "srv_spec", "audit_guid": "d900afb9", "is_enabled": int64(1), "created_local": "2026-11-11T10:00:00", "modified_local": "2026-11-11T10:00:01",
			"action_name": "AUDIT_CHANGE_GROUP", "class_desc": "SERVER", "audited_result": "SUCCESS AND FAILURE", "is_group": int64(1)},
		{"name": "srv_spec", "audit_guid": "d900afb9", "is_enabled": int64(1), "action_name": "FAILED_LOGIN_GROUP", "class_desc": "SERVER", "is_group": int64(1)},
		{"name": "empty_spec", "audit_guid": "d900afb9", "is_enabled": int64(0), "action_name": nil},
	}
	specs := auditSpecRows("server", "", rows)
	if len(specs) != 2 {
		t.Fatalf("%d specifications, want 2", len(specs))
	}
	if specs[0]["name"] != "srv_spec" || specs[0]["is_enabled"] != true || specs[0]["audit_guid"] != "D900AFB9" || specs[0]["database_name"] != nil ||
		len(specs[0]["actions"].([]collect.Row)) != 2 || specs[0]["actions"].([]collect.Row)[1]["action"] != "FAILED_LOGIN_GROUP" {
		t.Errorf("the first specification: %v", specs[0])
	}
	if specs[1]["is_enabled"] != false || len(specs[1]["actions"].([]collect.Row)) != 0 {
		t.Errorf("a specification without an action: %v", specs[1])
	}
	if d := auditSpecRows("database", "appdb", rows[:1]); d[0]["database_name"] != "appdb" || d[0]["scope"] != "database" {
		t.Errorf("a database's specification: %v", d[0])
	}

	// the reader's statement: its starting point, its optional columns, and whose text it takes
	first := auditFileQuery("sys.fn_get_audit_file", map[string]bool{}, false)
	next := auditFileQuery("msdb.dbo.rds_fn_get_audit_file", map[string]bool{"client_ip": true, "application_name": true, "host_name": true}, true)
	if !strings.Contains(first, "FROM sys.fn_get_audit_file(@p1, default, default)") || !strings.Contains(first, "CAST(NULL AS nvarchar(128)) AS client_ip") ||
		!strings.Contains(first, "CAST(NULL AS nvarchar(128)) AS host_name") {
		t.Errorf("the first read's statement: %s", first)
	}
	if !strings.Contains(next, "FROM msdb.dbo.rds_fn_get_audit_file(@p1, @p4, @p5)") || !strings.Contains(next, "CAST(client_ip AS nvarchar(128)) AS client_ip") ||
		!strings.Contains(next, "CAST(host_name AS nvarchar(128)) AS host_name") {
		t.Errorf("a later read's statement: %s", next)
	}
	if strings.Contains(first, "%!") || strings.Contains(next, "%!") || !strings.Contains(first, "LIKE 'CREATE%INDEX%' THEN 'CREATE INDEX'") ||
		!strings.Contains(first, "LIKE 'TRUNCATE TABLE%' THEN 'TRUNCATE TABLE'") || !strings.Contains(first, "AS maint,") {
		t.Errorf("the maintenance answer did not survive the statement's format: %s", first)
	}
	if !strings.Contains(first, "@p3 = 1 AND action_id IN (") || strings.Contains(first, "N'SL'") || strings.Contains(first, "N'IN'") {
		t.Error("the statement text of a counted action must never be taken off the server")
	}
	if fn, cat := auditReaderFunc(KindRDS); fn != "msdb.dbo.rds_fn_get_audit_file" || cat != "msdb." {
		t.Errorf("the RDS reader: %s %s", fn, cat)
	}
	if fn, cat := auditReaderFunc(KindServer); fn != "sys.fn_get_audit_file" || cat != "" {
		t.Errorf("the reader: %s %s", fn, cat)
	}
	if !auditCursorGone(mssqldb.Error{Number: 33225}) || auditCursorGone(mssqldb.Error{Number: 33224}) || auditCursorGone(nil) {
		t.Error("only 33225 says the cursor's file is gone")
	}
}

func TestAuditReadDeadlineAndKeys(t *testing.T) {
	defer func(b, c int) { auditBatchRows, auditRowCap = b, c }(auditBatchRows, auditRowCap)
	auditRowCap = 1000
	build := func() *auditFake {
		f := &auditFake{}
		for i, off := range []int64{16384, 20480, 24576, 28672} { // four buffers of three records
			for j := 0; j < 3; j++ {
				f.add("/a/sec_G_0_2.sqlaudit", off, fmt.Sprintf("2026-11-11T10:0%d:0%d.0000000Z", i, j), "CR", "SL", "sa", "master", fmt.Sprintf("l%d%d", i, j), "")
			}
		}
		return f
	}
	keys := func(f *auditFake) map[string]string {
		out := map[string]string{}
		for _, e := range f.kinds("audit_event") {
			out[fmt.Sprint(e["object_name"])] = fmt.Sprint(e["event_key"])
		}
		return out
	}
	// the same records read in batches of one buffer and in one batch: every event has the same key (a key counts
	// its place within its buffer, never within the batch)
	auditBatchRows = 3
	small := build()
	if _, err := small.reader(false).read(context.Background(), auditTestDef()); err != nil {
		t.Fatal(err)
	}
	auditBatchRows = 100
	whole := build()
	if _, err := whole.reader(false).read(context.Background(), auditTestDef()); err != nil {
		t.Fatal(err)
	}
	ks, kw := keys(small), keys(whole)
	if len(ks) != 12 || len(kw) != 12 || len(small.batches) != 4 || len(whole.batches) != 1 {
		t.Fatalf("keys %d / %d, batches %d / %d; want 12 / 12 and 4 / 1", len(ks), len(kw), len(small.batches), len(whole.batches))
	}
	for name, k := range ks {
		if kw[name] != k {
			t.Errorf("%s: key %s in batches of one buffer, %s in one batch", name, k, kw[name])
		}
	}
	// a run whose time is up after its first batch stops there: one batch stored with its cursor, the note says so
	auditBatchRows = 3
	late := build()
	rd := late.reader(false)
	rd.deadline = time.Now().Add(-time.Second)
	res, err := rd.read(context.Background(), auditTestDef())
	if err != nil {
		t.Fatal(err)
	}
	if len(late.batches) != 1 || res.listed != 3 {
		t.Errorf("a run out of time: %d batches, %d listed; want 1 and 3", len(late.batches), res.listed)
	}
	if c := late.cursors[auditSource(auditTestDef().guid)]; c.FileOffset != 16384 {
		t.Errorf("the cursor after the cut run: %+v", c)
	}
	found := false
	for _, n := range res.notes {
		found = found || strings.Contains(n, "time was up")
	}
	if !found {
		t.Errorf("notes: %v", res.notes)
	}
}

func TestAuditReadStateOf(t *testing.T) {
	all := auditRights{defs: true, state: true, events: true, eventsRight: "VIEW SERVER SECURITY AUDIT"}
	none := auditRights{defs: true, state: true, eventsRight: "CONTROL SERVER"}
	def := func(typ string) *auditDef { return &auditDef{typ: typ, row: collect.Row{}} }
	cases := []struct {
		a      *auditDef
		rights auditRights
		timeUp bool
		want   string
		note   string
	}{
		{def("FL"), all, false, "", ""},
		{def("FL"), all, true, "behind", "time was up"},
		{def("FL"), none, false, "no right", "lacks CONTROL SERVER"},
		{def("AL"), all, false, "not readable", "Event Viewer"},
		{def("SL"), none, false, "not readable", "Event Viewer"}, // a Windows log is never read, with the right or not
		{def("UL"), all, false, "not read", "url target"},
		{def("EM"), all, false, "not read", "external monitor target"},
		{def(""), all, false, "not read", "VIEW ANY DEFINITION"},
	}
	for _, c := range cases {
		state, note := auditReadNote(c.a, c.rights, c.timeUp)
		if state != c.want || !strings.Contains(note, c.note) || auditReadStateOf(c.a, c.rights, c.timeUp) != c.want {
			t.Errorf("type %q, events %v, time up %v: %q %q; want %q with %q", c.a.typ, c.rights.events, c.timeUp, state, note, c.want, c.note)
		}
	}
}
