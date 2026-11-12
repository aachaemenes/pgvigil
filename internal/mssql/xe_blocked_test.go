package mssql

import (
	"strings"
	"testing"
	"time"
)

// The blocked-process report columns of sp_HumanEventsBlockViewer (darling-open D04) and system_health's blockingTasks.

// fixBlockedFull: a report with every attribute the proc reads, on both sides, and the event's own fields.
const fixBlockedFull = `<event name="blocked_process_report" package="sqlserver" timestamp="2026-11-10T17:00:05.120Z"><data name="duration"><value>6013000</value></data><data name="database_id"><value>7</value></data><data name="object_id"><value>0</value></data><data name="transaction_id"><value>90211</value></data><data name="resource_owner_type"><value>1</value><text><![CDATA[LOCK]]></text></data><data name="lock_mode"><value>3</value><text><![CDATA[S]]></text></data><data name="database_name"><value><![CDATA[pgvblock]]></value></data><data name="blocked_process"><type name="xml" package="package0"></type><value><blocked-process-report monitorLoop="88">
 <blocked-process>
  <process id="p1" taskpriority="0" logused="0" waitresource="KEY: 7:72057594043170816 (8194443284a0)" waittime="6013" ownerId="90211" transactionname="SELECT" lasttranstarted="2026-11-10T09:00:00.200" XDES="0x1" lockMode="S" schedulerid="1" kpid="1" status="suspended" spid="72" sbid="0" ecid="0" priority="0" trancount="0" lastbatchstarted="2026-11-10T09:00:00.200" lastbatchcompleted="2026-11-10T09:00:00.150" lastattention="1900-01-01T00:00:00.150" clientapp="reader-app" hostname="pgvb_r" hostpid="1" loginname="sa" isolationlevel="read committed (2)" xactid="90211" currentdb="7" currentdbname="pgvblock" lockTimeout="4294967295" clientoption1="671088672" clientoption2="128056">
   <executionStack><frame line="1" stmtstart="0" sqlhandle="0x0200000000000000000000000000000000000000"/></executionStack>
   <inputbuf>SELECT pad FROM dbo.t WHERE id = 1</inputbuf>
  </process>
 </blocked-process>
 <blocking-process>
  <process status="sleeping" spid="66" sbid="0" ecid="0" priority="0" trancount="1" lastbatchstarted="2026-11-10T08:59:58.100" lastbatchcompleted="2026-11-10T08:59:58.103" lastattention="1900-01-01T00:00:00.103" clientapp="writer-app" hostname="pgvb_h" hostpid="2" loginname="sa" isolationlevel="serializable (4)" xactid="90100" currentdb="7" currentdbname="pgvblock" lockTimeout="4294967295" clientoption1="671088672" clientoption2="128056" logused="1024" transactionname="user_transaction" lasttranstarted="2026-11-10T08:59:58.100">
   <executionStack><frame line="1" stmtstart="26" stmtend="120" sqlhandle="0x0000000000000000000000000000000000000000"/><frame line="1" stmtstart="4" stmtend="-1" sqlhandle="0x02000000ABCDEF"/></executionStack>
   <inputbuf>
BEGIN TRAN; UPDATE dbo.t SET pad = 'h' WHERE id = 1   </inputbuf>
  </process>
 </blocking-process>
</blocked-process-report></value></data></event>`

func TestParseBlockedViewerColumns(t *testing.T) {
	row := parseBlocked(mustEvent(t, fixBlockedFull), fullCtx)
	want := map[string]any{
		"source": "product", "transaction_id": int64(90211), "object_id": int64(0), "database_id": int64(7),
		"resource_owner_type": "LOCK", "monitor_loop": int64(88), "wait_ms": int64(6013), "blocked_wait_ms": int64(6013),
		"blocked_ecid": int64(0), "blocked_status": "suspended", "blocked_isolation": "read committed (2)", "blocked_lock_mode": "S",
		"blocked_trancount": int64(0), "blocked_transaction_name": "SELECT", "blocked_last_batch": "2026-11-10T09:00:00.200",
		"blocked_last_batch_completed": "2026-11-10T09:00:00.150", "blocked_last_tran_started": "2026-11-10T09:00:00.200",
		"blocked_log_used": int64(0), "blocked_priority": int64(0), "blocked_clientoption1": int64(671088672),
		"blocked_clientoption2": int64(128056), "blocked_xactid": int64(90211), "blocked_currentdb": "pgvblock",
		"blocking_ecid": int64(0), "blocking_status": "sleeping", "blocking_isolation": "serializable (4)", "blocking_lock_mode": nil,
		"blocking_trancount": int64(1), "blocking_transaction_name": "user_transaction", "blocking_last_batch": "2026-11-10T08:59:58.100",
		"blocking_last_batch_completed": "2026-11-10T08:59:58.103", "blocking_last_tran_started": "2026-11-10T08:59:58.100",
		"blocking_log_used": int64(1024), "blocking_priority": int64(0), "blocking_xactid": int64(90100), "blocking_currentdb": "pgvblock",
		"blocking_wait_resource": nil, "blocking_wait_ms": nil,
		// the first frame whose handle is not all zeros: the lead blocker's identity
		"blocking_sql_handle": "0x02000000abcdef", "blocking_stmtstart": int64(4), "blocking_stmtend": int64(-1),
		"statement": "BEGIN TRAN; UPDATE dbo.t SET pad = 'h' WHERE id = 1",
	}
	for k, v := range want {
		if row[k] != v {
			t.Errorf("%s = %#v, want %#v", k, row[k], v)
		}
	}
}

// a QUERY_PROCESSING result as sp_server_diagnostics writes it, with two blocked-process reports under blockingTasks
const fixQueryProcessing = `<queryProcessing maxWorkers="512" workersCreated="40" workersIdle="20" tasksCompletedWithinInterval="100" pendingTasks="0" oldestPendingTaskWaitingTime="0" hasUnresolvableDeadlockOccurred="0" hasDeadlockedSchedulersOccurred="0" trackingNonYieldingScheduler="0x0"><topWaits/><cpuIntensiveRequests/><pendingTasks/><blockingTasks><blocked-process-report monitorLoop="0"><blocked-process><process id="p1" waitresource="KEY: 7:72057594043170816 (8194443284a0)" waittime="35020" transactionname="UPDATE" lockMode="X" status="suspended" spid="73" ecid="0" trancount="2" isolationlevel="read committed (2)" xactid="5001" currentdb="7" currentdbname="pgvblock" loginname="sa" hostname="pgvb_w" clientapp="w-app" logused="0"><executionStack/><inputbuf>UPDATE dbo.t SET pad = 'w' WHERE id = 1</inputbuf></process></blocked-process><blocking-process><process status="sleeping" spid="66" ecid="0" trancount="1" isolationlevel="read committed (2)" xactid="5000" currentdb="7" currentdbname="pgvblock" loginname="sa" hostname="pgvb_h" clientapp="h-app" transactionname="user_transaction" lastbatchstarted="2026-11-10T08:59:58.100" lastbatchcompleted="2026-11-10T08:59:58.103"><executionStack/><inputbuf>BEGIN TRAN; UPDATE dbo.t SET pad = 'h' WHERE id = 1</inputbuf></process></blocking-process></blocked-process-report><blocked-process-report monitorLoop="0"><blocked-process><process id="p2" waitresource="KEY: 7:72057594043170816 (8194443284a0)" waittime="31000" lockMode="S" status="suspended" spid="72" ecid="0" xactid="5002" currentdb="7" currentdbname="pgvblock" loginname="sa"><executionStack/><inputbuf>SELECT 1</inputbuf></process></blocked-process><blocking-process><process status="suspended" spid="73" ecid="0" xactid="5001" currentdbname="pgvblock" waitresource="KEY: 7:72057594043170816 (8194443284a0)" waittime="35020"><executionStack/><inputbuf>UPDATE dbo.t SET pad = 'w' WHERE id = 1</inputbuf></process></blocking-process></blocked-process-report></blockingTasks></queryProcessing>`

func TestBlockingTasks(t *testing.T) {
	at := time.Date(2026, 11, 10, 17, 5, 0, 0, time.UTC)
	rows := blockingTasks(at, fixQueryProcessing, fullCtx)
	if len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
	r := rows[0]
	want := map[string]any{"kind": "blocked", "source": "system_health", "session_name": "system_health", "event_name": "blockingTasks",
		"event_at": "2026-11-10T17:05:00Z", "database_name": "pgvblock", "lock_mode": "X", "wait_ms": int64(35020),
		"transaction_id": int64(5001), "database_id": int64(7), "monitor_loop": int64(0), "blocked_spid": int64(73),
		"blocked_transaction_name": "UPDATE", "blocking_spid": int64(66), "blocking_status": "sleeping",
		"blocking_transaction_name": "user_transaction", "blocking_last_batch_completed": "2026-11-10T08:59:58.103"}
	for k, v := range want {
		if r[k] != v {
			t.Errorf("row 0 %s = %#v, want %#v", k, r[k], v)
		}
	}
	if rows[1]["blocking_spid"] != int64(73) || rows[1]["blocking_wait_ms"] != int64(35020) {
		t.Errorf("row 1: blocking %v waiting %v, want 73 waiting 35020 (a chain's middle)", rows[1]["blocking_spid"], rows[1]["blocking_wait_ms"])
	}
	if rows[0]["event_key"] == rows[1]["event_key"] {
		t.Errorf("two reports of one result share the key %v", rows[0]["event_key"])
	}
	rep, _ := r["report"].(string)
	if !strings.HasPrefix(rep, `<blocked-process-report monitorLoop="0">`) || !strings.HasSuffix(rep, "</blocked-process-report>") {
		t.Errorf("report kept as %q", rep[:min(len(rep), 80)])
	}
	if blockingTasks(at, `<queryProcessing maxWorkers="1"><blockingTasks/></queryProcessing>`, fullCtx) != nil {
		t.Error("a result without a report gives rows")
	}
	if got := blockingTasks(at, fixQueryProcessing, xeContext{queryText: "none"}); got[0]["head_key"] != nil || got[0]["report"] != nil ||
		got[0]["statement"] != nil || got[0]["blocked_statement"] != nil {
		t.Errorf("under none: head_key %v, report kept %v, statement %v, blocked statement %v", got[0]["head_key"], got[0]["report"] != nil,
			got[0]["statement"], got[0]["blocked_statement"])
	}
	// a victim behind two holders: the first holder's attributes, never a mix
	two := strings.Replace(fixQueryProcessing, `</blocking-process></blocked-process-report><blocked-process-report`,
		`</blocking-process><blocking-process><process status="running" spid="99" ecid="0" transactionname="other"><executionStack/><inputbuf>SELECT 2</inputbuf></process></blocking-process></blocked-process-report><blocked-process-report`, 1)
	if got := blockingTasks(at, two, fullCtx); got[0]["blocking_spid"] != int64(66) || got[0]["blocking_transaction_name"] != "user_transaction" ||
		got[0]["statement"] != "BEGIN TRAN; UPDATE dbo.t SET pad = 'h' WHERE id = 1" {
		t.Errorf("two holders: spid %v, transaction %v, statement %v (want the first holder's)", got[0]["blocking_spid"],
			got[0]["blocking_transaction_name"], got[0]["statement"])
	}
}
