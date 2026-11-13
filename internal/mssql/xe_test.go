package mssql

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log/slog"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// a deadlock as SQL Server 2022 wrote it (two sessions, two key locks), the stack frames left out
const fixDeadlock = `<event name="xml_deadlock_report" package="sqlserver" timestamp="2026-10-20T10:51:44.433Z"><data name="xml_report"><value><deadlock>
 <victim-list>
  <victimProcess id="process100215e8c8"/>
 </victim-list>
 <process-list>
  <process id="process100215e8c8" taskpriority="0" logused="368" waitresource="KEY: 5:72057594049593344 (8194443284a0)" waittime="2567" transactionname="user_transaction" lockMode="X" status="suspended" spid="62" trancount="2" lastbatchstarted="2026-10-20T10:51:38.857" clientapp="SQLCMD" hostname="box-a" loginname="app_login" isolationlevel="read committed (2)" currentdb="5" currentdbname="sandbox">
   <executionStack>
    <frame procname="adhoc" line="1" stmtstart="38" stmtend="136" sqlhandle="0x02">
unknown    </frame>
   </executionStack>
   <inputbuf>
BEGIN TRAN; UPDATE dbo.kp_dl_a SET v = 1 WHERE id = 1; WAITFOR DELAY &apos;00:00:03&apos;; UPDATE dbo.kp_dl_b SET v = 1 WHERE id = 1; COMMIT;   </inputbuf>
  </process>
  <process id="process1000453088" taskpriority="0" logused="368" waitresource="KEY: 5:72057594049527808 (8194443284a0)" waittime="2569" transactionname="user_transaction" lockMode="X" status="suspended" spid="61" trancount="2" clientapp="SQLCMD" hostname="box-b" loginname="other_login" isolationlevel="read committed (2)" currentdb="5" currentdbname="sandbox">
   <executionStack>
    <frame procname="sandbox.dbo.p_move" line="4" stmtstart="38" sqlhandle="0x03">
UPDATE dbo.kp_dl_a SET v = 2 WHERE id = 1    </frame>
   </executionStack>
   <inputbuf>
Proc [Database Id = 5 Object Id = 100]   </inputbuf>
  </process>
 </process-list>
 <resource-list>
  <keylock hobtid="72057594049593344" dbid="5" objectname="sandbox.dbo.kp_dl_b" indexname="PK_b" id="lock1" mode="X" associatedObjectId="72057594049593344">
   <owner-list>
    <owner id="process1000453088" mode="X"/>
   </owner-list>
   <waiter-list>
    <waiter id="process100215e8c8" mode="X" requestType="wait"/>
   </waiter-list>
  </keylock>
  <keylock hobtid="72057594049527808" dbid="5" objectname="sandbox.dbo.kp_dl_a" indexname="PK_a" id="lock2" mode="X" associatedObjectId="72057594049527808">
   <owner-list>
    <owner id="process100215e8c8" mode="X"/>
   </owner-list>
   <waiter-list>
    <waiter id="process1000453088" mode="U" requestType="wait"/>
   </waiter-list>
  </keylock>
 </resource-list>
</deadlock>
</value></data><action name="event_sequence" package="package0"><value>7</value></action></event>`

const fixBlocked = `<event name="blocked_process_report" package="sqlserver" timestamp="2026-11-10T17:00:05.120Z"><data name="blocked_process"><type name="xml" package="package0"></type><value><blocked-process-report monitorLoop="1234">
 <blocked-process>
  <process id="process1" taskpriority="0" logused="0" waitresource="KEY: 5:72057594049593344 (8194443284a0)" waittime="5012" lockMode="U" status="suspended" spid="71" trancount="1" clientapp="app-one" hostname="web01" loginname="web_login" currentdb="5" currentdbname="sandbox">
   <executionStack><frame line="1" stmtstart="2" sqlhandle="0x02"/></executionStack>
   <inputbuf>
UPDATE dbo.orders SET state = 2 WHERE id = 41   </inputbuf>
  </process>
 </blocked-process>
 <blocking-process>
  <process status="sleeping" spid="66" sbid="0" ecid="0" priority="0" trancount="1" lastbatchstarted="2026-11-10T09:00:00.100" lastbatchcompleted="2026-11-10T09:00:00.103" clientapp="batch-job" hostname="job01" loginname="job_login" currentdb="5" currentdbname="sandbox">
   <executionStack/>
   <inputbuf>
BEGIN TRAN; UPDATE dbo.orders SET state = 1 WHERE id = 41   </inputbuf>
  </process>
 </blocking-process>
</blocked-process-report></value></data><data name="database_id"><value>5</value></data><data name="database_name"><value><![CDATA[sandbox]]></value></data><data name="duration"><value>5012000</value></data><data name="lock_mode"><value>4</value><text><![CDATA[U]]></text></data><action name="event_sequence" package="package0"><value>3</value></action></event>`

const fixBatch = `<event name="sql_batch_completed" package="sqlserver" timestamp="2026-11-10T16:52:43.086Z"><data name="cpu_time"><value>29000</value></data><data name="duration"><value>1530241</value></data><data name="physical_reads"><value>3</value></data><data name="logical_reads"><value>746</value></data><data name="writes"><value>1</value></data><data name="row_count"><value>2</value></data><data name="result"><value>0</value><text><![CDATA[OK]]></text></data><data name="batch_text"><value><![CDATA[SELECT COUNT(*) FROM dbo.orders WHERE customer = N'O''Brien' AND total > 12.50 -- the report]]></value></data><action name="query_plan_hash" package="sqlserver"><value>0</value></action><action name="query_hash" package="sqlserver"><value>0</value></action><action name="session_id" package="sqlserver"><value>57</value></action><action name="server_principal_name" package="sqlserver"><value><![CDATA[report_login]]></value></action><action name="database_name" package="sqlserver"><value><![CDATA[sales]]></value></action><action name="client_hostname" package="sqlserver"><value><![CDATA[rpt01]]></value></action><action name="client_app_name" package="sqlserver"><value><![CDATA[reports]]></value></action><action name="event_sequence" package="package0"><value>2</value></action></event>`

const fixStatement = `<event name="sql_statement_completed" package="sqlserver" timestamp="2026-11-10T16:52:43.080Z"><data name="duration"><value>1520000</value></data><data name="cpu_time"><value>28000</value></data><data name="statement"><value><![CDATA[SELECT COUNT(*) FROM dbo.orders WHERE customer = N'O''Brien' AND total > 12.50]]></value></data><action name="query_plan_hash" package="sqlserver"><value>1311768467463790320</value></action><action name="query_hash" package="sqlserver"><value>18446744073709551615</value></action><action name="session_id" package="sqlserver"><value>57</value></action></event>`

const fixRPC = `<event name="rpc_completed" package="sqlserver" timestamp="2026-11-10T16:53:00.000Z"><data name="duration"><value>2000000</value></data><data name="result"><value>2</value><text>Abort</text></data><data name="object_name"><value><![CDATA[usp_MonthEnd]]></value></data><data name="statement"><value><![CDATA[exec dbo.usp_MonthEnd @month=11]]></value></data><action name="session_id" package="sqlserver"><value>80</value></action></event>`

const fixAttention = `<RingBufferTarget truncated="0" processingTime="0" totalEventsProcessed="9" eventCount="1" droppedCount="2" memoryUsed="2048"><event name="attention" package="sqlserver" timestamp="2026-11-10T16:53:38.447Z"><data name="duration"><type name="uint64" package="package0"></type><value>349</value></data><data name="request_id"><type name="int32" package="package0"></type><value>0</value></data><action name="sql_text" package="sqlserver"><type name="unicode_string" package="package0"></type><value><![CDATA[WAITFOR DELAY '00:00:09']]></value></action><action name="session_id" package="sqlserver"><type name="uint16" package="package0"></type><value>57</value></action><action name="server_principal_name" package="sqlserver"><value><![CDATA[sa]]></value></action><action name="database_name" package="sqlserver"><value><![CDATA[master]]></value></action><action name="client_hostname" package="sqlserver"><value><![CDATA[box]]></value></action><action name="client_app_name" package="sqlserver"><value><![CDATA[SQLCMD]]></value></action><action name="event_sequence" package="package0"><type name="uint64" package="package0"></type><value>9</value></action></event></RingBufferTarget>`

func mustEvent(t *testing.T, doc string) *xeEvent {
	t.Helper()
	e, err := parseEvent(doc)
	if err != nil {
		t.Fatal(err)
	}
	return &e
}

var fullCtx = xeContext{source: "product", session: "pgvigil_t_x", queryText: "full"}

// Every event the printed script adds has a parser, in all four forms: a misspelt event name fails here instead of
// dropping every event of that kind at the read.
func TestXEScriptEventsHaveParsers(t *testing.T) {
	added := regexp.MustCompile(`ADD EVENT sqlserver\.([a-z_]+)`)
	for _, form := range []string{XEFormServer, XEFormAzureMI, XEFormAzureDB, XEFormCloudSQL} {
		script, err := XEScript("t1", form)
		if err != nil {
			t.Fatal(err)
		}
		got := map[string]bool{}
		for _, m := range added.FindAllStringSubmatch(script, -1) {
			got[m[1]] = true
			if _, ok := xeParsers[m[1]]; !ok {
				t.Errorf("%s: the script adds %s and the reader has no parser for it", form, m[1])
			}
		}
		for capture, events := range xeCaptureEvents {
			for _, ev := range events {
				if form == XEFormAzureDB && ev == "xml_deadlock_report" {
					ev = "database_xml_deadlock_report"
				}
				if !got[ev] {
					t.Errorf("%s: capture %s reads %s and the script does not add it", form, capture, ev)
				}
			}
			if !strings.Contains(script, "CREATE EVENT SESSION ["+XESessionName("t1", capture)+"]") {
				t.Errorf("%s: no session for %s", form, capture)
			}
		}
		// the script changes no server setting and drops nothing
		for _, bad := range []string{"RECONFIGURE", "DROP EVENT SESSION", "sp_configure"} {
			for _, line := range strings.Split(script, "\n") {
				if strings.Contains(line, bad) && !strings.Contains(line, "the DBA''s step") && !strings.HasPrefix(strings.TrimSpace(line), "--") && !strings.Contains(line, "pgvigil mssql-xe -print -drop") {
					t.Errorf("%s: the script runs %q: %s", form, bad, line)
				}
			}
		}
		scope := "ON SERVER"
		if form == XEFormAzureDB {
			scope = "ON DATABASE"
		}
		if strings.Count(script, "] "+scope+"\n") != 4 {
			t.Errorf("%s: want four sessions created %s", form, scope)
		}
		if (form == XEFormServer || form == XEFormCloudSQL) != strings.Contains(script, "package0.event_file") {
			t.Errorf("%s: only the server and Cloud SQL forms write an event file", form)
		}
		// Cloud SQL's file goes to the folder Google names; the server form's has no path (the server's log directory)
		if (form == XEFormCloudSQL) != strings.Contains(script, "filename=N''/var/opt/mssql/xevents/pgvigil_t1_slow.xel''") {
			t.Errorf("%s: the event file's path", form)
		}
		// Cloud SQL has no sp_configure and no database flag for the threshold: its advice says the session stays empty
		if (form == XEFormCloudSQL) != strings.Contains(script, "offer no blocked process threshold, so this session stays empty there") ||
			(form == XEFormServer || form == XEFormAzureMI) != strings.Contains(script, "EXEC sys.sp_configure") {
			t.Errorf("%s: the blocked process threshold's advice", form)
		}
		// the Managed Instance form is written from the documentation; the Azure SQL Database form is proven
		// (scripts/proof-mssql-azuresqldb.sh) and the Cloud SQL form too (a real instance, 2026-11-13)
		if (form == XEFormAzureMI) != strings.Contains(script, "NOT PROVEN") {
			t.Errorf("%s: only the Managed Instance form is marked not proven", form)
		}
		// Azure SQL Database has no server_principal_name action (Msg 25744): its form names the login by username
		if (form == XEFormAzureDB) == strings.Contains(script, "server_principal_name") || (form == XEFormAzureDB) != strings.Contains(script, "sqlserver.username") {
			t.Errorf("%s: the login's action is server_principal_name everywhere but Azure SQL Database, username there", form)
		}
	}
	for _, ev := range xeAGEvents {
		if _, ok := xeParsers[ev]; !ok {
			t.Errorf("AlwaysOn_health: no parser for %s", ev)
		}
	}
}

func TestXEScriptArgs(t *testing.T) {
	for _, id := range []string{"", "A1", "a-b", "a b", "x'; DROP", strings.Repeat("a", 21)} {
		if _, err := XEScript(id, XEFormServer); err == nil {
			t.Errorf("install id %q was accepted", id)
		}
		if _, err := XEDropScript(id, XEFormServer); err == nil {
			t.Errorf("install id %q was accepted by the drop script", id)
		}
	}
	if _, err := XEScript("ok1", "oracle"); err == nil {
		t.Error("an unknown form was accepted")
	}
	drop, err := XEDropScript("ab12", XEFormServer)
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(drop, "DROP EVENT SESSION [pgvigil_ab12_"); n != 4 {
		t.Errorf("the drop script drops %d sessions of the install id, want 4", n)
	}
	if n := strings.Count(drop, "DROP EVENT SESSION"); n != 4 {
		t.Errorf("the drop script has %d DROP statements, want 4", n)
	}
}

func TestParseDeadlock(t *testing.T) {
	row := parseDeadlock(mustEvent(t, fixDeadlock), fullCtx)
	if row == nil {
		t.Fatal("no row")
	}
	want := map[string]any{"kind": "deadlock", "event_at": "2026-10-20T10:51:44.433Z", "source": "product", "process_count": 2, "victim_count": 1,
		"victim_spid": int64(62), "victim_login": "app_login", "victim_program": "SQLCMD", "database_names": "sandbox",
		"object_names": "sandbox.dbo.kp_dl_a, sandbox.dbo.kp_dl_b"}
	for k, v := range want {
		if row[k] != v {
			t.Errorf("%s = %#v, want %#v", k, row[k], v)
		}
	}
	if s, _ := row["statement"].(string); !strings.HasPrefix(s, "BEGIN TRAN; UPDATE dbo.kp_dl_a") || !strings.Contains(s, "WAITFOR DELAY '00:00:03'") {
		t.Errorf("the victim's statement: %q", s)
	}
	if g, _ := row["graph"].(string); !strings.HasPrefix(g, "<deadlock>") || !strings.HasSuffix(g, "</deadlock>") {
		t.Errorf("the graph is not kept whole: %.40q ... %d bytes", g, len(g))
	}
	ps := row["processes"].([]map[string]any)
	if len(ps) != 2 {
		t.Fatalf("%d processes", len(ps))
	}
	if ps[0]["victim"] != true || ps[0]["waits_on"] != "sandbox.dbo.kp_dl_b" || ps[0]["waits_mode"] != "X" || ps[0]["spid"] != int64(62) || ps[0]["host"] != "box-a" || ps[0]["wait_ms"] != int64(2567) {
		t.Errorf("the victim's process: %#v", ps[0])
	}
	// the second process ran a procedure: its input buffer is the call, kept as the statement; the frame names the procedure
	if ps[1]["victim"] != false || ps[1]["waits_on"] != "sandbox.dbo.kp_dl_a" || ps[1]["waits_mode"] != "U" || ps[1]["login"] != "other_login" || ps[1]["proc"] != "sandbox.dbo.p_move" {
		t.Errorf("the other process: %#v", ps[1])
	}
	rs := row["resources"].([]map[string]any)
	if len(rs) != 2 || rs[0]["type"] != "keylock" || rs[0]["object"] != "sandbox.dbo.kp_dl_b" || rs[0]["index"] != "PK_b" {
		t.Errorf("the resources: %#v", rs)
	}
	if o := rs[0]["owners"].([]map[string]any); len(o) != 1 || o[0]["spid"] != int64(61) || o[0]["mode"] != "X" {
		t.Errorf("the first resource's owner: %#v", rs[0]["owners"])
	}
	if w := rs[0]["waiters"].([]map[string]any); len(w) != 1 || w[0]["spid"] != int64(62) {
		t.Errorf("the first resource's waiter: %#v", rs[0]["waiters"])
	}
}

// Under the none policy no statement text leaves the collector: not in the row, not nested, not inside the graph.
func TestParseDeadlockTextPolicy(t *testing.T) {
	row := parseDeadlock(mustEvent(t, fixDeadlock), xeContext{source: "system_health", session: "system_health", queryText: "none"})
	rows := []collect.Row{row}
	collect.ApplyTextPolicy(rows, "none")
	if row["graph"] != nil || row["statement"] != nil {
		t.Errorf("graph or statement kept under none: %v / %v", row["graph"] != nil, row["statement"])
	}
	for _, p := range row["processes"].([]map[string]any) {
		if p["statement"] != nil {
			t.Errorf("a process's statement kept under none: %v", p["statement"])
		}
	}
	if row["source"] != "system_health" || row["victim_spid"] != int64(62) {
		t.Errorf("the rest of the row: %#v", row)
	}
	norm := parseDeadlock(mustEvent(t, fixDeadlock), xeContext{source: "product", queryText: "normalized"})
	if norm["graph"] != nil {
		t.Error("the graph (raw statement text) kept under normalized")
	}
	if s, _ := norm["processes"].([]map[string]any)[0]["statement"].(string); s == "" || strings.Contains(s, "00:00:03") {
		t.Errorf("a nested statement under normalized: %q", s)
	}
}

func TestParseBlocked(t *testing.T) {
	row := parseBlocked(mustEvent(t, fixBlocked), fullCtx)
	want := map[string]any{"kind": "blocked", "event_at": "2026-11-10T17:00:05.12Z", "database_name": "sandbox", "lock_mode": "U",
		"wait_ms": int64(5012), "wait_resource": "KEY: 5:72057594049593344 (8194443284a0)", "blocked_spid": int64(71),
		"blocked_login": "web_login", "blocked_host": "web01", "blocked_program": "app-one",
		"blocked_statement": "UPDATE dbo.orders SET state = 2 WHERE id = 41", "blocking_spid": int64(66), "blocking_status": "sleeping",
		"blocking_trancount": int64(1), "blocking_login": "job_login", "blocking_host": "job01", "blocking_program": "batch-job",
		"blocking_last_batch": "2026-11-10T09:00:00.100", "statement": "BEGIN TRAN; UPDATE dbo.orders SET state = 1 WHERE id = 41"}
	for k, v := range want {
		if row[k] != v {
			t.Errorf("%s = %#v, want %#v", k, row[k], v)
		}
	}
	if r, _ := row["report"].(string); !strings.HasPrefix(r, "<blocked-process-report") {
		t.Errorf("the report: %.40q", r)
	}
	// the same head statement with another literal is the same head
	other := parseBlocked(mustEvent(t, strings.ReplaceAll(fixBlocked, "state = 1 WHERE id = 41", "state = 7   WHERE id = 99")), fullCtx)
	if row["head_key"] == nil || row["head_key"] != other["head_key"] {
		t.Errorf("head keys: %v / %v", row["head_key"], other["head_key"])
	}
	none := parseBlocked(mustEvent(t, fixBlocked), xeContext{queryText: "none"})
	if none["head_key"] != nil || none["report"] != nil || none["blocked_statement"] != nil {
		t.Errorf("under none: head_key %v, report %v, blocked_statement %v", none["head_key"], none["report"] != nil, none["blocked_statement"])
	}
}

func TestParseSlow(t *testing.T) {
	row := parseSlow(mustEvent(t, fixBatch), fullCtx)
	want := map[string]any{"kind": "slow", "event_name": "sql_batch_completed", "event_at": "2026-11-10T16:52:43.086Z",
		"duration_us": int64(1530241), "cpu_us": int64(29000), "logical_reads": int64(746), "physical_reads": int64(3),
		"writes": int64(1), "row_count": int64(2), "result": "OK", "login_name": "report_login", "host_name": "rpt01",
		"program_name": "reports", "database_name": "sales", "session_id": int64(57), "query_hash_hex": nil, "query_plan_hash_hex": nil,
		"shape": "SELECT COUNT(*) FROM dbo.orders WHERE customer = ? AND total > ?"}
	for k, v := range want {
		if row[k] != v {
			t.Errorf("%s = %#v, want %#v", k, row[k], v)
		}
	}
	// a statement's event carries the hashes, printed as Query Store prints them
	st := parseSlow(mustEvent(t, fixStatement), fullCtx)
	if st["query_hash_hex"] != "0xFFFFFFFFFFFFFFFF" || st["query_plan_hash_hex"] != "0x123456789ABCDEF0" {
		t.Errorf("hashes: %v / %v", st["query_hash_hex"], st["query_plan_hash_hex"])
	}
	// the statement inside the batch has the batch's shape (the trailing comment is not part of a shape)
	if st["shape_key"] == nil || st["shape_key"] != row["shape_key"] {
		t.Errorf("shape keys: %v / %v", st["shape_key"], row["shape_key"])
	}
	// a procedure call's shape is the procedure, with or without statement text
	rpc := parseSlow(mustEvent(t, fixRPC), xeContext{queryText: "none"})
	if rpc["shape"] != "usp_MonthEnd" || rpc["shape_key"] == nil || rpc["result"] != "Abort" || rpc["object_name"] != "usp_MonthEnd" {
		t.Errorf("the rpc row: %#v", rpc)
	}
	// under none an ad hoc batch has no shape: its text is not stored and neither is a hash of it
	none := parseSlow(mustEvent(t, fixBatch), xeContext{queryText: "none"})
	if none["shape"] != nil || none["shape_key"] != nil {
		t.Errorf("under none: shape %v, key %v", none["shape"], none["shape_key"])
	}
	// a driver's wrapper procedure is not the shape: the statement it carries is, whatever the parameter's value
	wrap := func(object, call string) collect.Row {
		return parseSlow(mustEvent(t, strings.ReplaceAll(strings.ReplaceAll(fixRPC, "usp_MonthEnd]]", object+"]]"), "exec dbo.usp_MonthEnd @month=11", call)), fullCtx)
	}
	w1 := wrap("sp_executesql", "exec sp_executesql N'SELECT a FROM t WHERE id = @p AND n = ''x''',N'@p int',@p=5")
	w2 := wrap("sp_executesql", "exec sp_executesql N'SELECT a FROM t WHERE id = @p AND n = ''yy''',N'@p int',@p=77")
	w3 := wrap("sp_executesql", "exec sp_executesql N'DELETE FROM u WHERE k = @p',N'@p int',@p=5")
	if w1["shape"] != "SELECT a FROM t WHERE id = @p AND n = ?" || w1["shape_key"] != w2["shape_key"] || w1["shape_key"] == w3["shape_key"] || w3["shape"] != "DELETE FROM u WHERE k = @p" {
		t.Errorf("wrapped statements: %q / %q / %q", w1["shape"], w2["shape"], w3["shape"])
	}
	// sp_prepexec carries the parameter declaration before the statement
	if w := wrap("sp_prepexec", "declare @p1 int set @p1=NULL exec sp_prepexec @p1 output,N'@P0 int',N'SELECT b FROM v WHERE id = @P0',5"); w["shape"] != "SELECT b FROM v WHERE id = @P0" {
		t.Errorf("sp_prepexec's shape: %q", w["shape"])
	}
	// a call by handle carries no statement: no shape, the query hash is what names it
	if w := wrap("sp_execute", "exec sp_execute 7,5"); w["shape"] != nil || w["shape_key"] != nil {
		t.Errorf("sp_execute's shape: %v", w["shape"])
	}
}

func TestParseRingAndAttention(t *testing.T) {
	ring, err := parseRing(fixAttention)
	if err != nil {
		t.Fatal(err)
	}
	if ring.TotalProcessed != 9 || ring.EventCount != 1 || ring.DroppedCount != 2 || ring.MemoryUsed != 2048 || ring.Truncated != 0 || len(ring.Events) != 1 {
		t.Fatalf("the ring: %+v", ring)
	}
	e := &ring.Events[0]
	if e.seq() != 9 {
		t.Errorf("event_sequence = %d", e.seq())
	}
	row := parseAttention(e, fullCtx)
	want := map[string]any{"kind": "attention", "session_id": int64(57), "request_id": int64(0), "interrupt_us": int64(349),
		"statement": "WAITFOR DELAY '00:00:09'", "login_name": "sa", "host_name": "box", "program_name": "SQLCMD", "database_name": "master"}
	for k, v := range want {
		if row[k] != v {
			t.Errorf("%s = %#v, want %#v", k, row[k], v)
		}
	}
	if empty, err := parseRing(""); err != nil || len(empty.Events) != 0 {
		t.Errorf("an empty ring: %v", err)
	}
	if _, err := parseRing("<RingBufferTarget><event"); err == nil {
		t.Error("a cut ring buffer parsed without an error")
	}
}

func agEvent(name, body string) string {
	return `<event name="` + name + `" package="sqlserver" timestamp="2026-11-10T01:26:04.175Z">` + body + `<data name="availability_group_name"><value><![CDATA[ag1]]></value></data><data name="availability_replica_name"><value><![CDATA[node1]]></value></data></event>`
}

func agState(prev, cur string) string {
	return agEvent("availability_replica_state_change", `<data name="previous_state"><value>5</value><text><![CDATA[`+prev+`]]></text></data><data name="current_state"><value>0</value><text><![CDATA[`+cur+`]]></text></data>`)
}

func TestParseAG(t *testing.T) {
	for _, c := range []struct {
		prev, cur string
		failover  bool
	}{
		{"NOT_AVAILABLE", "RESOLVING_NORMAL", false},              // the instance starts
		{"RESOLVING_NORMAL", "RESOLVING_PENDING_FAILOVER", false}, // a clusterless group's start goes through this too
		{"RESOLVING_NORMAL", "PRIMARY_PENDING", false},
		{"PRIMARY_PENDING", "PRIMARY_NORMAL", false},
		{"SECONDARY_NORMAL", "RESOLVING_PENDING_FAILOVER", true}, // a secondary told to take over
		{"PRIMARY_NORMAL", "RESOLVING_NORMAL", true},             // a primary that lost its role
		{"SECONDARY_NORMAL", "RESOLVING_NORMAL", false},
	} {
		row := parseAG(mustEvent(t, agState(c.prev, c.cur)), fullCtx)
		if row["is_failover"] != c.failover || row["previous_state"] != c.prev || row["current_state"] != c.cur || row["ag_name"] != "ag1" || row["replica_name"] != "node1" {
			t.Errorf("%s to %s: %#v", c.prev, c.cur, row)
		}
	}
	ddl := func(stmt, phase string) collect.Row {
		return parseAG(mustEvent(t, agEvent("alwayson_ddl_executed", `<data name="ddl_action"><value>2</value><text>alter</text></data><data name="ddl_phase"><value>1</value><text>`+phase+`</text></data><data name="statement"><value><![CDATA[`+stmt+`]]></value></data>`)), fullCtx)
	}
	if r := ddl("ALTER AVAILABILITY GROUP [ag1] FAILOVER;", "commit"); r["is_failover"] != true || r["ddl_action"] != "alter" || r["ddl_phase"] != "commit" {
		t.Errorf("a committed failover: %#v", r)
	}
	if r := ddl("ALTER AVAILABILITY GROUP [ag1] FORCE_FAILOVER_ALLOW_DATA_LOSS;", "begin"); r["is_failover"] != false {
		t.Errorf("a failover only begun counts as one: %#v", r)
	}
	if r := ddl("ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'n2' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);", "commit"); r["is_failover"] != false {
		t.Errorf("another DDL counts as a failover: %#v", r)
	}
	errEv := func(n, sev string) collect.Row {
		return parseAG(mustEvent(t, agEvent("error_reported", `<data name="error_number"><value>`+n+`</value></data><data name="severity"><value>`+sev+`</value></data><data name="message"><value><![CDATA[the text]]></value></data>`)), fullCtx)
	}
	for n, fam := range map[string]string{"19407": "lease", "19419": "lease", "19421": "lease", "35206": "connection", "35201": "connection", "1480": "role", "19406": "role", "35264": "data movement"} {
		if r := errEv(n, "10"); r == nil || r["family"] != fam || r["message"] != "the text" {
			t.Errorf("error %s: %#v, want family %s", n, r, fam)
		}
	}
	if r := errEv("26022", "10"); r != nil {
		t.Errorf("an informational message of no family is stored: %#v", r)
	}
	if r := errEv("41131", "16"); r == nil || r["family"] != "other" || r["severity"] != int64(16) {
		t.Errorf("an error of severity 16: %#v", r)
	}
	if r := parseAG(mustEvent(t, agEvent("availability_group_lease_expired", "")), fullCtx); r == nil || r["family"] != "lease" {
		t.Errorf("a lease expiry: %#v", r)
	}
}

// A shape keeps the statement's own spacing, folded to one space: only literals and comments go.
func TestSQLShape(t *testing.T) {
	for in, want := range map[string]string{
		"SELECT  a,\n\tb FROM t WHERE x = 5 AND y = 'it''s' AND z = N'q' AND h = 0x1F": "SELECT a, b FROM t WHERE x = ? AND y = ? AND z = ? AND h = ?",
		"select [a b], \"c d\" from [my db].dbo.t1 where id=@p1 -- 42":                 "select [a b], \"c d\" from [my db].dbo.t1 where id=@p1",
		"/* 1 */ EXEC dbo.p1 @a = 1.5e3, @b = -2":                                      "EXEC dbo.p1 @a = ?, @b = -?",
		"UPDATE #t5 SET c = 'unterminated":                                             "UPDATE #t5 SET c = ?",
		"SELECT 1 /* a /* b */ secret */ FROM t":                                       "SELECT ? FROM t",
		"SELECT $12.50, $x FROM t":                                                     "SELECT ?, $x FROM t",
		"":                                                                             "",
	} {
		if got := sqlShape(in); got != want {
			t.Errorf("sqlShape(%q) = %q, want %q", in, got, want)
		}
	}
	if n := len(sqlShape(strings.Repeat("SELECT a FROM t; ", 500))); n > 2000 {
		t.Errorf("a long shape is %d characters", n)
	}
}

func TestXEKeyer(t *testing.T) {
	a, b := mustEvent(t, fixBatch), mustEvent(t, fixBatch)
	c := mustEvent(t, fixRPC)
	var k xeKeyer
	k1, k2, k3 := k.key(a), k.key(b), k.key(c)
	if k1 == k2 || !strings.HasSuffix(k1, "-0") || !strings.HasSuffix(k2, "-1") || strings.TrimSuffix(k1, "-0") != strings.TrimSuffix(k2, "-1") {
		t.Errorf("two identical events of one block: %s / %s", k1, k2)
	}
	if !strings.HasSuffix(k3, "-0") || strings.HasPrefix(k3, strings.TrimSuffix(k1, "-0")) {
		t.Errorf("a different event: %s", k3)
	}
	// the same block read again gives the same keys
	k.reset()
	if again := k.key(a); again != k1 {
		t.Errorf("a second read of the block: %s, was %s", again, k1)
	}
}

func TestDecodeUTF16LE(t *testing.T) {
	// "a", U+1F600 (a surrogate pair), "é": the pair split between two pieces must come back whole
	raw := []byte{0x61, 0x00, 0x3D, 0xD8, 0x00, 0xDE, 0xE9, 0x00}
	joined := append(append([]byte{}, raw[:4]...), raw[4:]...)
	if got := decodeUTF16LE(joined); got != "a\U0001F600é" {
		t.Errorf("decodeUTF16LE = %q", got)
	}
}

func TestHashHex(t *testing.T) {
	for in, want := range map[any]any{"0": nil, "": nil, "abc": nil, "1": "0x0000000000000001", "18446744073709551615": "0xFFFFFFFFFFFFFFFF"} {
		if got := hashHex(in); got != want {
			t.Errorf("hashHex(%v) = %v, want %v", in, got, want)
		}
	}
	if hashHex(nil) != nil {
		t.Error("hashHex(nil)")
	}
}

func TestXEPickAndState(t *testing.T) {
	sessions := xeGroup([]xeTarget{
		{session: "pgvigil_a1_slow", running: false, target: "event_file"},
		{session: "pgvigil_b2_slow", running: true, target: "event_file"},
		{session: "pgvigil_a1_attention", running: true, target: "ring_buffer"},
		{session: "pgvigil_a1_attention", running: true, target: "event_counter"},
		{session: "pgvigil_a1_blocked", running: false, target: "ring_buffer"},
		{session: "pgvigil__slow", running: true, target: "event_file"}, // no install id: not the product's name
		{session: "system_health", running: true, target: "event_file"},
		{session: "other_deadlocks", running: true, target: "ring_buffer"},
	})
	if s := xePick(sessions, xeSlow); s == nil || s.name != "pgvigil_b2_slow" || xeStateOf(s) != "running" {
		t.Errorf("slow: %+v", s)
	}
	if s := xePick(sessions, xeAttention); s == nil || len(s.targets) != 2 {
		t.Errorf("attention: %+v", s)
	}
	if s := xePick(sessions, xeBlocked); xeStateOf(s) != "stopped" {
		t.Errorf("blocked: a defined session that is not started is %q, want stopped", xeStateOf(s))
	}
	if s := xePick(sessions, xeDeadlocks); xeStateOf(s) != "not installed" {
		t.Errorf("deadlocks: %q, want not installed", xeStateOf(s))
	}
}

func TestXEFilePattern(t *testing.T) {
	for in, want := range map[string]string{
		"/var/opt/mssql/log/pgvigil_a1_slow_0_134388031629870000.xel": "/var/opt/mssql/log/pgvigil_a1_slow*.xel",
		`D:\Log\system_health_0_134387475640440000.xel`:               `D:\Log\system_health*.xel`,
		"/var/opt/mssql/log/odd.xel":                                  "",
		"":                                                            "",
	} {
		if got := xeFilePattern(in); got != want {
			t.Errorf("xeFilePattern(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCursorRow(t *testing.T) {
	at := time.Date(2026, 11, 10, 17, 0, 0, 123000000, time.UTC)
	file := Cursor{Found: true, FileName: "/log/a_0_1.xel", FileOffset: 20480, LastEventAt: at}.Row("s1")
	if file["kind"] != "cursor" || file["source"] != "s1" || file["file_name"] != "/log/a_0_1.xel" || file["file_offset"] != int64(20480) || file["last_event_at"] != "2026-11-10T17:00:00.123Z" {
		t.Errorf("a file cursor's row: %#v", file)
	}
	ring := Cursor{LastEventAt: at, LastSeq: 9}.Row("s2")
	if ring["file_name"] != nil || ring["file_offset"] != nil || ring["last_seq"] != int64(9) {
		t.Errorf("a ring cursor's row: %#v", ring)
	}
}

// fakeStore is the repository of the batch path's test: an import fails when told to, and a failed import stores
// nothing, the cursor included.
type fakeStore struct {
	cursors  map[string]Cursor
	imported [][]map[string]any
	failAt   int // the import call (1-based) that fails; 0: none
	calls    int
	status   string
	note     string
}

func (f *fakeStore) MSSQLCursor(_ context.Context, _ int, source string) (string, int64, time.Time, int64, bool, error) {
	c, ok := f.cursors[source]
	return c.FileName, c.FileOffset, c.LastEventAt, c.LastSeq, ok, nil
}

func (f *fakeStore) Import(_ context.Context, _ int, _ string, _ time.Time, rows []map[string]any) error {
	f.calls++
	if f.calls == f.failAt {
		return errors.New("the repository is away")
	}
	f.imported = append(f.imported, rows)
	for _, r := range rows {
		if r["kind"] == CursorKind {
			f.cursors[r["source"].(string)] = Cursor{Found: true, LastSeq: r["last_seq"].(int64)}
		}
	}
	return nil
}

func (f *fakeStore) LogCollection(_ context.Context, _ int, _ string, _ time.Time, _ time.Duration, status, note string) error {
	f.status, f.note = status, note
	return nil
}

// fakeBatches emits events 1..total in batches of size from the stored cursor on, as the reader does.
type fakeBatches struct {
	total, size int
	tail        []collect.Row
}

func (fakeBatches) Name() string                   { return Prefix + "fake" }
func (fakeBatches) DefaultInterval() time.Duration { return time.Minute }
func (fakeBatches) Applies(Info) (bool, string)    { return true, "" }
func (fakeBatches) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("not the path")
}

func (b fakeBatches) RunBatches(ctx context.Context, _ *sql.Conn, _ Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	cur, err := cursor(ctx, "src")
	if err != nil {
		return err
	}
	if opt.QueryText != "normalized" || opt.Deadline.IsZero() {
		return errors.New("the options did not arrive")
	}
	for at := int(cur.LastSeq); at < b.total; {
		end := min(at+b.size, b.total)
		var rows []collect.Row
		for i := at + 1; i <= end; i++ {
			rows = append(rows, collect.Row{"kind": "slow", "n": i, "statement": "SELECT 5"})
		}
		rows = append(rows, Cursor{LastSeq: int64(end)}.Row("src"))
		if err := emit(rows); err != nil {
			return err
		}
		at = end
	}
	return emit(b.tail)
}

func TestRunBatched(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	in := config.Instance{Name: "i1", QueryText: "normalized"}
	run := func(st *fakeStore, b fakeBatches) collect.Result {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		return runBatched(context.Background(), ctx, log, st, in, b.Name(), b, nil, Info{}, 1, time.Now(), time.Minute)
	}
	// 25 events in batches of 10: three imports, each with its cursor, then the tail
	st := &fakeStore{cursors: map[string]Cursor{}}
	tail := []collect.Row{{"kind": "state", "capture": "slow", "state": "running"}}
	res := run(st, fakeBatches{total: 25, size: 10, tail: tail})
	if res.Err != nil || res.Rows != 25 || len(st.imported) != 4 || st.cursors["src"].LastSeq != 25 || st.status != "ok" {
		t.Fatalf("a full run: %+v, %d imports, cursor %d, status %s", res, len(st.imported), st.cursors["src"].LastSeq, st.status)
	}
	// the text policy reached the rows before the import
	if s := st.imported[0][0]["statement"]; s != "SELECT ?" {
		t.Errorf("the statement as imported: %v", s)
	}
	// a second run reads nothing twice
	res = run(st, fakeBatches{total: 25, size: 10, tail: tail})
	if res.Err != nil || res.Rows != 0 {
		t.Errorf("a second run: %+v", res)
	}
	// the second batch's import fails: the run is an error, the first batch and ITS cursor are stored, nothing of the second
	st = &fakeStore{cursors: map[string]Cursor{}, failAt: 2}
	res = run(st, fakeBatches{total: 25, size: 10})
	if res.Err == nil || res.Rows != 10 || st.cursors["src"].LastSeq != 10 || st.status != "error" || !strings.Contains(st.note, "the repository is away") {
		t.Fatalf("a failed batch: %+v, cursor %d, status %s (%s)", res, st.cursors["src"].LastSeq, st.status, st.note)
	}
	// the next run goes on from the stored cursor: events 11 to 25, none twice
	st.failAt = 0
	res = run(st, fakeBatches{total: 25, size: 10})
	seen := map[int]int{}
	for _, batch := range st.imported {
		for _, r := range batch {
			if n, ok := r["n"].(int); ok {
				seen[n]++
			}
		}
	}
	if res.Err != nil || res.Rows != 15 || len(seen) != 25 {
		t.Fatalf("the run after the failure: %+v, %d distinct events", res, len(seen))
	}
	for n, c := range seen {
		if c != 1 {
			t.Errorf("event %d stored %d times", n, c)
		}
	}
	// a source's error row makes the run partial with its note
	st = &fakeStore{cursors: map[string]Cursor{}}
	res = run(st, fakeBatches{total: 3, size: 10, tail: []collect.Row{{"kind": "collector_error", "source": "pgvigil_x_slow", "message": "the file is gone"}}})
	if res.Err != nil || st.status != "partial" || st.note != "pgvigil_x_slow: the file is gone" || !strings.Contains(res.Note, "partial") {
		t.Errorf("a partial run: %+v, status %s (%s)", res, st.status, st.note)
	}
}

// The reader's statements carry no XQuery: the XML is taken apart on the collector's side.
func TestXEStatementsShredNothingOnTheServer(t *testing.T) {
	for name, q := range map[string]string{"sessions": xeSessionsSQL, "ring": xeRingSQL, "file": xeFileSQL, "threshold": xeThresholdSQL} {
		l := strings.ToLower(q)
		for _, bad := range []string{".nodes(", ".value(", ".query(", " as xml", "insert ", "update ", "delete ", "create ", "alter ", "drop ", "exec "} {
			if strings.Contains(l, bad) {
				t.Errorf("%s: the statement has %q", name, bad)
			}
		}
	}
	if (xeCollector{}).Timeout() >= time.Minute || (xeCollector{}).DefaultInterval() != time.Minute {
		t.Error("the reader must end before its next run")
	}
	if ok, why := (xeCollector{}).Applies(Info{}); ok || !strings.Contains(why, "VIEW SERVER STATE") {
		t.Errorf("without VIEW SERVER STATE: %v %q", ok, why)
	}
	if _, isBatch := any(xeCollector{}).(BatchCollector); !isBatch {
		t.Error("mssql_xe is not a BatchCollector")
	}
}

// a parallel deadlock: an exchangeEvent beside an object lock, two victims, a process without an input buffer
const fixParallelDeadlock = `<event name="xml_deadlock_report" package="sqlserver" timestamp="2026-11-01T08:00:00.001Z"><data name="xml_report"><value><deadlock><victim-list><victimProcess id="p1"/><victimProcess id="p2"/></victim-list><process-list><process id="p1" spid="70" ecid="0" loginname="l1" currentdbname="db1"><executionStack><frame procname="db1.dbo.p_big" line="9">SELECT x FROM dbo.big</frame></executionStack><inputbuf></inputbuf></process><process id="p2" spid="70" ecid="3" loginname="l1" currentdbname="db1"><executionStack/><inputbuf>EXEC dbo.p_big</inputbuf></process><process id="p3" spid="81" loginname="l2" currentdbname="db2"><executionStack/></process></process-list><resource-list><exchangeEvent id="Pipe1" WaitType="e_waitPipeGetRow" nodeId="4"><owner-list><owner id="p2"/></owner-list><waiter-list><waiter id="p1"/></waiter-list></exchangeEvent><objectlock lockPartition="0" objid="5" subresource="FULL" dbid="7" objectname="db1.dbo.big" id="lock9" mode="IX" associatedObjectId="5"><owner-list><owner id="p3" mode="IX"/></owner-list><waiter-list><waiter id="p2" mode="S" requestType="wait"/></waiter-list></objectlock></resource-list></deadlock></value></data></event>`

func TestParseDeadlockShapes(t *testing.T) {
	row := parseDeadlock(mustEvent(t, fixParallelDeadlock), fullCtx)
	if row["victim_count"] != 2 || row["process_count"] != 3 || row["victim_spid"] != int64(70) || row["database_names"] != "db1, db2" || row["object_names"] != "db1.dbo.big" {
		t.Fatalf("the row: %#v", row)
	}
	// the first victim has no input buffer: its statement is its stack's frame
	if row["statement"] != "SELECT x FROM dbo.big" {
		t.Errorf("the victim's statement: %v", row["statement"])
	}
	ps := row["processes"].([]map[string]any)
	if ps[0]["victim"] != true || ps[1]["victim"] != true || ps[2]["victim"] != false || ps[2]["statement"] != nil || ps[0]["proc"] != "db1.dbo.p_big" || ps[1]["waits_on"] != "db1.dbo.big" || ps[1]["waits_mode"] != "S" {
		t.Errorf("the processes: %#v", ps)
	}
	rs := row["resources"].([]map[string]any)
	if len(rs) != 2 || rs[0]["type"] != "exchangeEvent" || rs[0]["object"] != nil || rs[1]["type"] != "objectlock" || rs[1]["mode"] != "IX" {
		t.Errorf("the resources: %#v", rs)
	}
}

// The same deadlock read from pgvigil's ring buffer and from system_health's file has one key: the actions, the
// <type> children and the white space differ, the graph does not.
func TestDeadlockKeyAcrossSessions(t *testing.T) {
	product := mustEvent(t, fixDeadlock)
	other := strings.Replace(fixDeadlock, `<action name="event_sequence" package="package0"><value>7</value></action>`, "", 1)
	other = strings.Replace(other, `<data name="xml_report"><value>`, `<data name="xml_report"><type name="xml" package="package0"></type><value>`, 1)
	other = strings.ReplaceAll(other, "\n  <process ", "\n\t<process ")
	if other == fixDeadlock || !strings.Contains(other, "\n\t<process ") {
		t.Fatal("the second copy is not different")
	}
	a := parseDeadlock(product, fullCtx)
	b := parseDeadlock(mustEvent(t, other), xeContext{source: "system_health", session: "system_health", queryText: "full"})
	if a["event_key"] == nil || a["event_key"] != b["event_key"] {
		t.Errorf("keys: %v / %v", a["event_key"], b["event_key"])
	}
	later := parseDeadlock(mustEvent(t, strings.Replace(fixDeadlock, "10:51:44.433Z", "10:51:44.434Z", 1)), fullCtx)
	if later["event_key"] == a["event_key"] {
		t.Error("another deadlock a millisecond later has the same key")
	}
	changed := parseDeadlock(mustEvent(t, strings.Replace(fixDeadlock, `spid="61"`, `spid="99"`, 1)), fullCtx)
	if changed["event_key"] == a["event_key"] {
		t.Error("another graph at the same time has the same key")
	}
}

// A control character inside a statement's text does not fail the read: not for the one event, not for the ring
// buffer that holds it.
func TestXMLCleanKeepsTheRead(t *testing.T) {
	for _, bad := range []string{"&#x1;", "&#1;", "&#x0;", "\x01", "&#xFFFE;", "\x0b"} {
		ring := strings.Replace(fixAttention, "WAITFOR DELAY '00:00:09'", "SELECT 'a"+bad+"b' -- held", 1)
		r, err := parseRing(ring)
		if err != nil || len(r.Events) != 1 {
			t.Fatalf("%q: %v, %d events", bad, err, len(r.Events))
		}
		row := parseAttention(&r.Events[0], fullCtx)
		if s, _ := row["statement"].(string); s != "SELECT 'a�b' -- held" {
			t.Errorf("%q: the statement %q", bad, s)
		}
	}
	// what XML allows stays as it is: a tab, a line feed, an emoji, each raw or as a reference
	keep := "a&#x9;b&#10;c&#x1F600;d\te"
	if got := xmlClean(keep); got != keep {
		t.Errorf("xmlClean changed legal text: %q", got)
	}
	if _, err := parseEvent(strings.Replace(fixBatch, "the report", "the &#x2; report", 1)); err != nil {
		t.Errorf("a file event with a control character: %v", err)
	}
}

// Cloud SQL's trigger TRG_EnforceXEventSessionParams4 refuses a CREATE EVENT SESSION that holds "max_memory=" more than
// once (G1 on a real instance, 2026-11-13: Msg 50000 'The command must not contain more than one occurrence of
// "max_memory="') and fails (Msg 537) when the one it finds is a ring buffer's: each of the cloudsql form's CREATEs
// holds it once, as the session's MAX_MEMORY=<the capture's size within 4-8 MB> KB (the trigger: 'max_memory value must
// be between 4MB and 8MB'); the other forms keep the session's MAX_MEMORY beside a ring buffer's max_memory.
func TestXECloudSQLOneMaxMemory(t *testing.T) {
	re := regexp.MustCompile(`(?i)max_memory=`)
	for form, want := range map[string]int{XEFormCloudSQL: 1, "server": 2} {
		s, err := XEScript("g1", form)
		if err != nil {
			t.Fatal(err)
		}
		parts := strings.Split(s, "CREATE EVENT SESSION")[1:]
		if len(parts) != 4 {
			t.Fatalf("%s: %d CREATE EVENT SESSION, want 4", form, len(parts))
		}
		for i, p := range parts {
			end := strings.Index(p, "EXEC sys.sp_executesql")
			if end < 0 {
				t.Fatalf("%s: session %d has no EXEC sys.sp_executesql after its CREATE EVENT SESSION", form, i+1)
			}
			p = p[:end]
			got := len(re.FindAllString(p, -1))
			if form == "server" && strings.Contains(p, "event_file") {
				continue // the slow session's file target has no max_memory of its own
			}
			if got != want {
				t.Errorf("%s: CREATE %d holds max_memory= %d times, want %d", form, i+1, got, want)
			}
			// the trigger parses the one it finds as the session's 'MAX_MEMORY=<n> KB' (Msg 537 on the ring buffer's)
			if form == XEFormCloudSQL && (strings.Contains(p, "ring_buffer(SET") || !regexp.MustCompile(`MAX_MEMORY=' \+ CAST\(CASE WHEN (@[a-z_]+) < 4096 THEN 4096 WHEN @[a-z_]+ > 8192 THEN 8192 ELSE @[a-z_]+ END AS nvarchar\(20\)\) \+ N' KB`).MatchString(p)) {
				t.Errorf("%s: CREATE %d: the one max_memory= is not the session's MAX_MEMORY=<the capture's size> KB", form, i+1)
			}
		}
	}
}
