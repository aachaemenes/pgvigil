package mssql

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// Fixtures: four sp_server_diagnostics_component_result events as SQL Server 2022 CU27 wrote them into its
// system_health file (a container sandbox, 2026-10-18 to 2026-11-11): a RESOURCE and a QUERY_PROCESSING result in
// WARNING (the container ran out of memory), a SYSTEM and an IO_SUBSYSTEM result CLEAN. fixtureIOLong is the IO
// result with one pending request and two counters put in by hand (the server had none), in the shape sp_HealthParser
// reads (ioSubsystem/longestPendingRequests/pendingRequest, @duration, @filePath).
const (
	fixtureResourceWarning = `<event name="sp_server_diagnostics_component_result" package="sqlserver" timestamp="2026-11-10T00:55:51.346Z"><data name="component"><value>1</value><text><![CDATA[RESOURCE]]></text></data><data name="state"><value>2</value><text><![CDATA[WARNING]]></text></data><data name="data"><value><resource lastNotification="RESOURCE_MEMPHYSICAL_LOW" outOfMemoryExceptions="0" isAnyPoolOutOfMemory="0" processOutOfMemoryPeriod="0"><memoryReport name="Process/System Counts" unit="Value"><entry description="Available Physical Memory" value="0"/><entry description="Available Virtual Memory" value="70364449144833"/><entry description="Available Paging File" value="0"/><entry description="Working Set" value="4294967296"/><entry description="Percent of Committed Memory in WS" value="100"/><entry description="Page Faults" value="0"/><entry description="System physical memory high" value="0"/><entry description="System physical memory low" value="1"/><entry description="Process physical memory low" value="1"/><entry description="Process virtual memory low" value="0"/></memoryReport><memoryReport name="Memory Manager" unit="KB"><entry description="VM Reserved" value="5590816"/><entry description="VM Committed" value="577736"/><entry description="Locked Pages Allocated" value="0"/><entry description="Large Pages Allocated" value="0"/><entry description="Emergency Memory" value="1024"/><entry description="Emergency Memory In Use" value="32"/><entry description="Target Committed" value="576712"/><entry description="Current Committed" value="577736"/><entry description="Pages Allocated" value="318752"/><entry description="Pages Reserved" value="0"/><entry description="Pages Free" value="36360"/><entry description="Pages In Use" value="540112"/><entry description="Page Alloc Potential" value="8744"/><entry description="NUMA Growth Phase" value="2"/><entry description="Last OOM Factor" value="0"/><entry description="Last OS Error" value="0"/></memoryReport></resource></value></data></event>`
	fixtureQPWarning       = `<event name="sp_server_diagnostics_component_result" package="sqlserver" timestamp="2026-11-10T00:55:51.360Z"><data name="component"><value>2</value><text><![CDATA[QUERY_PROCESSING]]></text></data><data name="state"><value>2</value><text><![CDATA[WARNING]]></text></data><data name="data"><value><queryProcessing maxWorkers="832" workersCreated="176" workersIdle="43" tasksCompletedWithinInterval="1167030" pendingTasks="2" oldestPendingTaskWaitingTime="0" hasUnresolvableDeadlockOccurred="0" hasDeadlockedSchedulersOccurred="0" trackingNonYieldingScheduler="0x0"><topWaits><nonPreemptive><byCount><wait waitType="MEMORY_ALLOCATION_EXT" waits="81159854" averageWaitTime="0" maxWaitTime="64246"/><wait waitType="HADR_WORK_QUEUE" waits="2112392" averageWaitTime="630" maxWaitTime="10007"/><wait waitType="SLEEP_BUFFERPOOL_HELPLW" waits="1504081" averageWaitTime="1" maxWaitTime="32"/><wait waitType="RESERVED_MEMORY_ALLOCATION_EXT" waits="1382755" averageWaitTime="0" maxWaitTime="0"/><wait waitType="HADR_TIMER_TASK" waits="520861" averageWaitTime="499" maxWaitTime="15000"/><wait waitType="HADR_FILESTREAM_IOMGR_IOCOMPLETION" waits="520613" averageWaitTime="500" maxWaitTime="505"/><wait waitType="PAGEIOLATCH_EX" waits="515257" averageWaitTime="0" maxWaitTime="45"/><wait waitType="WRITELOG" waits="277377" averageWaitTime="0" maxWaitTime="323"/><wait waitType="CXPACKET" waits="268501" averageWaitTime="0" maxWaitTime="268"/><wait waitType="OLEDB" waits="227826" averageWaitTime="0" maxWaitTime="75"/></byCount><byDuration><wait waitType="VDI_CLIENT_OTHER" waits="83817" averageWaitTime="57691" maxWaitTime="60007"/><wait waitType="HADR_WORK_QUEUE" waits="2112392" averageWaitTime="630" maxWaitTime="10007"/><wait waitType="DISPATCHER_QUEUE_SEMAPHORE" waits="87207" averageWaitTime="12424" maxWaitTime="58703549"/><wait waitType="CLR_AUTO_EVENT" waits="157" averageWaitTime="3317218" maxWaitTime="44455450"/><wait waitType="HADR_FILESTREAM_IOMGR_IOCOMPLETION" waits="520613" averageWaitTime="500" maxWaitTime="505"/><wait waitType="HADR_TIMER_TASK" waits="520861" averageWaitTime="499" maxWaitTime="15000"/><wait waitType="PWAIT_EXTENSIBILITY_CLEANUP_TASK" waits="869" averageWaitTime="299379" maxWaitTime="300038"/><wait waitType="HADR_LOGCAPTURE_WAIT" waits="1486" averageWaitTime="4215" maxWaitTime="5004"/><wait waitType="SLEEP_BUFFERPOOL_HELPLW" waits="1504081" averageWaitTime="1" maxWaitTime="32"/><wait waitType="MEMORY_ALLOCATION_EXT" waits="81159854" averageWaitTime="0" maxWaitTime="64246"/></byDuration></nonPreemptive><preemptive><byCount><wait waitType="PREEMPTIVE_XE_CALLBACKEXECUTE" waits="1383056" averageWaitTime="0" maxWaitTime="4"/><wait waitType="PREEMPTIVE_OS_FLUSHFILEBUFFERS" waits="530415" averageWaitTime="0" maxWaitTime="520"/><wait waitType="PREEMPTIVE_OS_QUERYREGISTRY" waits="171725" averageWaitTime="0" maxWaitTime="25"/><wait waitType="PREEMPTIVE_XE_GETTARGETSTATE" waits="91883" averageWaitTime="0" maxWaitTime="163"/><wait waitType="PREEMPTIVE_OS_AUTHENTICATIONOPS" waits="41743" averageWaitTime="0" maxWaitTime="46"/><wait waitType="PREEMPTIVE_XE_SESSIONCOMMIT" waits="13367" averageWaitTime="0" maxWaitTime="4"/><wait waitType="PREEMPTIVE_OS_WRITEFILE" waits="11952" averageWaitTime="2" maxWaitTime="261"/><wait waitType="PREEMPTIVE_OS_QUERYCONTEXTATTRIBUTES" waits="11754" averageWaitTime="0" maxWaitTime="0"/><wait waitType="PREEMPTIVE_OS_FILEOPS" waits="11689" averageWaitTime="0" maxWaitTime="54"/><wait waitType="PREEMPTIVE_OS_GETPROCADDRESS" waits="10713" averageWaitTime="0" maxWaitTime="10"/></byCount><byDuration><wait waitType="PREEMPTIVE_OS_FLUSHFILEBUFFERS" waits="530415" averageWaitTime="0" maxWaitTime="520"/><wait waitType="PREEMPTIVE_XE_GETTARGETSTATE" waits="91883" averageWaitTime="0" maxWaitTime="163"/><wait waitType="PREEMPTIVE_OS_WRITEFILE" waits="11952" averageWaitTime="2" maxWaitTime="261"/><wait waitType="PREEMPTIVE_OS_QUERYREGISTRY" waits="171725" averageWaitTime="0" maxWaitTime="25"/><wait waitType="PREEMPTIVE_OS_AUTHENTICATIONOPS" waits="41743" averageWaitTime="0" maxWaitTime="46"/><wait waitType="PREEMPTIVE_HTTP_EVENT_WAIT" waits="201" averageWaitTime="102" maxWaitTime="766"/><wait waitType="PREEMPTIVE_OS_WRITEFILEGATHER" waits="354" averageWaitTime="33" maxWaitTime="1095"/><wait waitType="PREEMPTIVE_OS_FILEOPS" waits="11689" averageWaitTime="0" maxWaitTime="54"/><wait waitType="PREEMPTIVE_XE_CALLBACKEXECUTE" waits="1383056" averageWaitTime="0" maxWaitTime="4"/><wait waitType="PREEMPTIVE_HTTP_REQUEST" waits="1413" averageWaitTime="1" maxWaitTime="10"/></byDuration></preemptive></topWaits><cpuIntensiveRequests><request sessionId="58" requestId="0" command="SELECT" taskAddress="0xf99f4b088" cpuUtilization="0" cpuTimeMs="402"/><request sessionId="59" requestId="0" command="EXECUTE" taskAddress="0xf8040b848" cpuUtilization="0" cpuTimeMs="240"/><request sessionId="82" requestId="0" command="EXECUTE" taskAddress="0xf8040b088" cpuUtilization="0" cpuTimeMs="236"/><request sessionId="57" requestId="0" command="EXECUTE" taskAddress="0xfcbb308c8" cpuUtilization="0" cpuTimeMs="65"/></cpuIntensiveRequests><pendingTasks><entryPoint moduleName="sqlmin.dll" imageBase="0x802260000" size="0x3255000" address="0x8029d2ea0" count="1"/><entryPoint moduleName="sqlmin.dll" imageBase="0x802260000" size="0x3255000" address="0x8022e9000" count="1"/></pendingTasks><blockingTasks></blockingTasks></queryProcessing></value></data></event>`
	fixtureSystemClean     = `<event name="sp_server_diagnostics_component_result" package="sqlserver" timestamp="2026-10-18T12:07:58.292Z"><data name="component"><value>0</value><text><![CDATA[SYSTEM]]></text></data><data name="state"><value>1</value><text><![CDATA[CLEAN]]></text></data><data name="data"><value><system spinlockBackoffs="0" sickSpinlockType="none" sickSpinlockTypeAfterAv="none" latchWarnings="0" isAccessViolationOccurred="0" writeAccessViolationCount="0" totalDumpRequests="0" intervalDumpRequests="0" nonYieldingTasksReported="0" pageFaults="0" systemCpuUtilization="0" sqlCpuUtilization="0" BadPagesDetected="0" BadPagesFixed="0" LastBadPageAddress="0x0"/></value></data></event>`
	fixtureIOClean         = `<event name="sp_server_diagnostics_component_result" package="sqlserver" timestamp="2026-11-11T21:46:05.389Z"><data name="component"><value>3</value><text><![CDATA[IO_SUBSYSTEM]]></text></data><data name="state"><value>1</value><text><![CDATA[CLEAN]]></text></data><data name="data"><value><ioSubsystem ioLatchTimeouts="0" intervalLongIos="0" totalLongIos="0"><longestPendingRequests></longestPendingRequests></ioSubsystem></value></data></event>`
	fixtureIOLong          = `<event name="sp_server_diagnostics_component_result" package="sqlserver" timestamp="2026-11-11T21:46:05.389Z"><data name="component"><value>3</value><text><![CDATA[IO_SUBSYSTEM]]></text></data><data name="state"><value>1</value><text><![CDATA[CLEAN]]></text></data><data name="data"><value><ioSubsystem ioLatchTimeouts="1" intervalLongIos="3" totalLongIos="0"><longestPendingRequests><pendingRequest duration="15100" filePath="/var/opt/mssql/data/x.mdf" offset="65536" handle="0x1"/></longestPendingRequests></ioSubsystem></value></data></event>`
)

func lines(at string, process string, texts ...string) []errorLogLine {
	t, err := time.Parse("2006-01-02T15:04:05.999", at)
	if err != nil {
		panic(err)
	}
	out := make([]errorLogLine, len(texts))
	for i, s := range texts {
		out[i] = errorLogLine{at: t, process: process, text: s}
	}
	return out
}

func shredAll(sh *errorLogShred, ls ...[]errorLogLine) []collect.Row {
	var out []collect.Row
	for _, group := range ls {
		for _, l := range group {
			out = append(out, sh.add(l)...)
		}
	}
	return append(out, sh.flush()...)
}

// An error is two lines of the log; they are one row, with the message's text and the header's numbers, dated by
// the server's offset; a line the noise list names is not kept even when it matched; a line nothing matched is not
// kept; an error of severity 17 or higher is kept whatever its message says.
func TestErrorLogShred(t *testing.T) {
	sh := &errorLogShred{offset: -8 * time.Hour}
	rows := shredAll(sh,
		lines("2026-11-10T12:00:00.41", "spid59", "Error: 50010, Severity: 16, State: 1.",
			"DatabaseBackupJob: DatabaseBackup returned 50000 with no failed backup (a refused parameter)"),
		lines("2026-11-10T12:00:01", "Logon", "Login failed for user 'app'. Reason: Password did not match. [CLIENT: 10.0.0.1]"),
		lines("2026-11-10T12:00:02", "spid12s", "Starting up database 'tempdb'."),
		lines("2026-11-10T12:00:03", "spid60", "Error: 50000, Severity: 17, State: 1.", "pgvigil proof marker"),
		lines("2026-11-10T12:00:04", "spid61", "SQL Server has encountered 2 occurrence(s) of I/O requests taking longer than 15 seconds to complete on file [x.mdf]"),
	)
	if len(rows) != 3 {
		t.Fatalf("rows %d, want 3: %v", len(rows), rows)
	}
	first := rows[0]
	if first["error_number"] != int64(50010) || first["severity"] != 16 || first["error_state"] != 1 {
		t.Errorf("the error's numbers: %v %v %v", first["error_number"], first["severity"], first["error_state"])
	}
	if !strings.HasPrefix(first["message"].(string), "DatabaseBackupJob") {
		t.Errorf("the message: %v", first["message"])
	}
	if first["log_at"] != "2026-11-10T20:00:00.41Z" || first["logged_local"] != "2026-11-10T12:00:00.410" {
		t.Errorf("dated %v (local %v), want 2026-11-10T20:00:00.41Z (local 2026-11-10T12:00:00.410)", first["log_at"], first["logged_local"])
	}
	if rows[1]["severity"] != 17 || rows[1]["message"] != "pgvigil proof marker" {
		t.Errorf("the severity 17 error: %v", rows[1])
	}
	if rows[2]["class"] != "io" {
		t.Errorf("the slow IO line's class %v, want io", rows[2]["class"])
	}
	if sh.scanned != 7 || sh.kept != 3 { // seven lines are fed: 2 + 1 + 1 + 2 + 1
		t.Errorf("scanned %d kept %d, want 7 and 3", sh.scanned, sh.kept)
	}
	if want := time.Date(2026, 11, 10, 20, 0, 4, 0, time.UTC); !sh.newest.Equal(want) {
		t.Errorf("newest %v, want %v", sh.newest, want)
	}
}

// A line read twice is the same row: the key is the local time, the process and the text, with a counter for the
// same line written twice in one instant; another offset changes the instant and never the key.
func TestErrorLogKeyStable(t *testing.T) {
	read := func(off time.Duration) []collect.Row {
		sh := &errorLogShred{offset: off}
		return shredAll(sh, lines("2026-11-10T12:00:00", "spid9", "Autogrow of file 'x' in database 'y' was cancelled by user or timed out",
			"Autogrow of file 'x' in database 'y' was cancelled by user or timed out"))
	}
	a, b := read(0), read(-7*time.Hour)
	if len(a) != 2 || len(b) != 2 {
		t.Fatalf("rows %d and %d, want 2 and 2", len(a), len(b))
	}
	if a[0]["line_key"] == a[1]["line_key"] {
		t.Errorf("two lines of one instant share a key: %v", a[0]["line_key"])
	}
	for i := range a {
		if a[i]["line_key"] != b[i]["line_key"] {
			t.Errorf("line %d: key %v under one offset and %v under another", i, a[i]["line_key"], b[i]["line_key"])
		}
	}
	if a[0]["log_at"] == b[0]["log_at"] {
		t.Errorf("the offset did not move the instant")
	}
}

// An error header whose message never comes (the next line is another process's) is a row of its own, and the next
// line is judged by itself.
func TestErrorLogLoneHeader(t *testing.T) {
	sh := &errorLogShred{}
	rows := shredAll(sh, lines("2026-11-10T12:00:00", "spid9", "Error: 823, Severity: 24, State: 2."),
		lines("2026-11-10T12:00:00", "spid10", "Recovery for availability database 'db' is complete."))
	if len(rows) != 2 || rows[0]["severity"] != 24 || rows[1]["class"] != "availability" {
		t.Fatalf("rows %v", rows)
	}
}

// The instance's own strings: matched without regard to case and marked custom; with 'only these', the shipped list
// is not searched, and an error of severity 17 or higher is still kept.
func TestErrorLogCustomSearch(t *testing.T) {
	s := parseErrorLogSearch(Cursor{Found: true, FileName: `["PGVPROOF", " ", "payroll"]`, FileOffset: 1})
	if !reflect.DeepEqual(s.shown, []string{"PGVPROOF", "payroll"}) || !s.only {
		t.Fatalf("search %+v", s)
	}
	if v := judgeErrorLogLine("pgvproof marker", 0, s); !v.keep || !v.custom || !reflect.DeepEqual(v.matched, []string{"PGVPROOF"}) {
		t.Errorf("own string: %+v", v)
	}
	if v := judgeErrorLogLine("I/O requests taking longer than 15 seconds", 0, s); v.keep {
		t.Errorf("only these: a shipped string was searched: %+v", v)
	}
	if v := judgeErrorLogLine("anything", 17, s); !v.keep {
		t.Errorf("only these: a severity 17 error was dropped")
	}
	none := parseErrorLogSearch(Cursor{Found: true, FileName: "not json", FileOffset: 1})
	if len(none.shown) != 0 || none.only {
		t.Errorf("a broken list gives strings: %+v", none)
	}
	if v := judgeErrorLogLine("Login failed for user 'payroll'.", 0, s); !v.keep || !v.custom {
		t.Errorf("an own string must be kept even on a noise line: %+v", v)
	}
	shipped := errorLogSearch{}
	if v := judgeErrorLogLine("Login failed for user 'payroll'.", 0, shipped); v.keep {
		t.Errorf("a noise line was kept by the shipped list: %+v", v)
	}
	if v := judgeErrorLogLine("DBCC CHECKDB (master) WITH no_infomsgs executed by sa found 0 errors and repaired 0 errors.", 0, shipped); !v.keep || v.class != "general" {
		t.Errorf("a clean CHECKDB: %+v", v)
	}
	if v := judgeErrorLogLine("Database 'x' is marked SUSPECT.", 0, shipped); !v.keep || v.class != "corruption" {
		t.Errorf("a suspect database: %+v", v)
	}
}

// The archives a read needs: the current log always, an archive unless it ended (a minute of grace) before the start;
// oldest first.
func TestErrorLogArchivesFor(t *testing.T) {
	all := []errorLogArchive{{6, parseArchiveDate("11/10/2026  01:22")}, {5, parseArchiveDate("11/10/2026  01:23")},
		{1, parseArchiveDate("11/10/2026  01:25")}, {0, parseArchiveDate("11/11/2026  21:30")}, {3, time.Time{}}}
	start := time.Date(2026, 11, 10, 1, 24, 0, 0, time.UTC)
	if got := errorLogArchivesFor(all, start); !reflect.DeepEqual(got, []int{5, 3, 1, 0}) {
		t.Errorf("archives %v, want [5 3 1 0] (6 ended 01:22, before 01:24 less a minute; 5 at 01:23 is inside the grace)", got)
	}
	if got := errorLogArchivesFor(nil, start); !reflect.DeepEqual(got, []int{0}) {
		t.Errorf("no listing: %v, want [0]", got)
	}
}

// A refusal for lack of a right is told from any other error by the server's number.
func TestNoRightError(t *testing.T) {
	for _, n := range []int32{229, 15003, 27219, 8189, 297, 300, 15247} {
		if !noRightError(mssqldb.Error{Number: n}) {
			t.Errorf("%d is a refusal for lack of a right", n)
		}
	}
	for _, err := range []error{mssqldb.Error{Number: 22004}, mssqldb.Error{Number: 0}, errors.New("i/o timeout")} {
		if noRightError(err) {
			t.Errorf("%v is not a refusal for lack of a right", err)
		}
	}
}

// The server's times come as ISO 8601 with or without milliseconds.
func TestServerTimeText(t *testing.T) {
	for _, s := range []string{"2026-11-11T20:35:24", "2026-11-11T20:35:24.15", "2026-11-11T20:35:24.150"} {
		if _, err := time.Parse("2006-01-02T15:04:05.999", s); err != nil {
			t.Errorf("%s: %v", s, err)
		}
	}
}

func TestDBCCCommand(t *testing.T) {
	for in, want := range map[string]string{
		"DBCC SHRINKFILE (N'pv_log', 1)":              "DBCC SHRINKFILE",
		"dbcc shrinkdatabase(x)":                      "DBCC SHRINKDATABASE",
		"DBCC FREEPROCCACHE WITH NO_INFOMSGS":         "DBCC FREEPROCCACHE",
		"dbcc freeproccache (0x06000500A1B2C3)":       "DBCC FREEPROCCACHE (plan handle)",
		"DBCC FREEPROCCACHE(@h)":                      "DBCC FREEPROCCACHE (plan handle)",
		"DBCC FREEPROCCACHE ('default')":              "DBCC FREEPROCCACHE",
		"DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR)": "DBCC SQLPERF (CLEAR)",
		"DBCC SQLPERF(LOGSPACE)":                      "DBCC SQLPERF",
		"DBCC TRACESTATUS(-1)":                        "DBCC TRACESTATUS",
		"DBCC\tDROPCLEANBUFFERS":                      "DBCC DROPCLEANBUFFERS",
		"  DBCC WRITEPAGE (x, 1, 100, 0, 1, 0x00, 1)": "DBCC WRITEPAGE",
		"": "DBCC",
	} {
		if got := dbccCommand(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

func TestTraceBasePath(t *testing.T) {
	for in, want := range map[string]string{
		"/var/opt/mssql/log/log_12.trc": "/var/opt/mssql/log/log.trc",
		`C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\log_301.trc`: `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\log.trc`,
		"log_1.trc": "",
	} {
		if got := traceBasePath(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

// A growth row as the read returns it (the sandbox's tempdb growth of 2026-11-11, 12,800 pages) dated by the offset;
// a DBCC row named by its command; a class the reader does not store is no row.
func TestTraceRow(t *testing.T) {
	row, at, seq, ok := traceRow(collect.Row{"event_class": int64(92), "local_at": "2026-11-11T20:35:24.15", "seq": int64(116715),
		"duration_us": int64(0), "pages": int64(12800), "database_name": "tempdb", "file_name": "tempdev4", "session_id": int64(58)}, -8*time.Hour)
	if !ok || row["trace_kind"] != "data growth" || row["event_at"] != "2026-11-12T04:35:24.15Z" || row["pages"] != int64(12800) || seq != 116715 {
		t.Fatalf("growth row %v", row)
	}
	if at.Format("15:04:05.000") != "20:35:24.150" || row["logged_local"] != "2026-11-11T20:35:24.150" {
		t.Errorf("local time %v / %v", at, row["logged_local"])
	}
	again, _, _, _ := traceRow(collect.Row{"event_class": int64(92), "local_at": "2026-11-11T20:35:24.15", "seq": int64(116715),
		"session_id": int64(58)}, 0)
	if again["event_key"] != row["event_key"] {
		t.Errorf("the key moved with the offset")
	}
	d, _, _, ok := traceRow(collect.Row{"event_class": int64(116), "local_at": "2026-11-11T20:14:56.613", "seq": int64(1),
		"text_data": "DBCC SHRINKFILE (N'x', 1)", "login_name": "sa"}, 0)
	if !ok || d["sub"] != "DBCC SHRINKFILE" || d["statement"] != "DBCC SHRINKFILE (N'x', 1)" || d["trace_kind"] != "dbcc" {
		t.Errorf("dbcc row %v", d)
	}
	ddl, _, _, ok := traceRow(collect.Row{"event_class": int64(47), "local_at": "2026-11-11T21:17:14.96", "seq": int64(2),
		"object_name": "pgv_exp_t", "object_type": "U"}, 0)
	if !ok || ddl["sub"] != "drop" || ddl["object_name"] != "pgv_exp_t" {
		t.Errorf("ddl row %v", ddl)
	}
	if _, _, _, ok := traceRow(collect.Row{"event_class": int64(22), "local_at": "2026-11-11T21:17:14.96"}, 0); ok {
		t.Errorf("an ErrorLog event (22) is not the reader's")
	}
}

func component(t *testing.T, doc string) collect.Row {
	t.Helper()
	e, err := parseEvent(doc)
	if err != nil {
		t.Fatal(err)
	}
	row := parseComponentResult(&e, xeContext{})
	if row == nil {
		t.Fatal("no row")
	}
	return row
}

// The four components as the server wrote them: the state, the root's figures as numbers, the memory report by its
// descriptions, the long lists left out.
func TestComponentResults(t *testing.T) {
	r := component(t, fixtureResourceWarning)
	d := r["detail"].(map[string]any)
	if r["component"] != "RESOURCE" || r["state"] != "WARNING" || r["event_at"] != "2026-11-10T00:55:51.346Z" {
		t.Errorf("resource row %v", r)
	}
	if d["lastNotification"] != "RESOURCE_MEMPHYSICAL_LOW" || d["outOfMemoryExceptions"] != int64(0) {
		t.Errorf("resource detail %v", d)
	}
	mem := d["memory"].(map[string]any)
	if mem["Available Physical Memory"] != int64(0) || mem["Working Set"] != int64(4294967296) || mem["Last OS Error"] != int64(0) {
		t.Errorf("memory report %v", mem)
	}
	q := component(t, fixtureQPWarning)
	qd := q["detail"].(map[string]any)
	if q["state"] != "WARNING" || qd["pendingTasks"] != int64(2) || qd["maxWorkers"] != int64(832) || qd["trackingNonYieldingScheduler"] != "0x0" {
		t.Errorf("query processing %v", qd)
	}
	if _, has := qd["memory"]; has {
		t.Errorf("query processing carries a memory report")
	}
	s := component(t, fixtureSystemClean)
	sd := s["detail"].(map[string]any)
	if s["state"] != "CLEAN" || sd["sickSpinlockType"] != "none" || sd["BadPagesDetected"] != int64(0) || sd["LastBadPageAddress"] != "0x0" {
		t.Errorf("system %v", sd)
	}
	io := component(t, fixtureIOClean)
	if io["component"] != "IO_SUBSYSTEM" || io["detail"].(map[string]any)["totalLongIos"] != int64(0) {
		t.Errorf("io %v", io)
	}
	if _, has := io["detail"].(map[string]any)["longest"]; has {
		t.Errorf("an empty request list gave requests")
	}
	long := component(t, fixtureIOLong)["detail"].(map[string]any)
	reqs := long["longest"].([]map[string]any)
	if long["intervalLongIos"] != int64(3) || len(reqs) != 1 || reqs[0]["duration"] != int64(15100) || reqs[0]["filePath"] != "/var/opt/mssql/data/x.mdf" {
		t.Errorf("io with a request %v", long)
	}
	if got := componentDetail(`<system a="1"><broken`); got["a"] != int64(1) {
		t.Errorf("a document cut short keeps what was read: %v", got)
	}
}

// The reader finds the event's parser where the Extended Events file loop looks for it, and the deadlock capture's
// script still adds only events it has parsers for (the registration adds one name, never a session event).
func TestSysHealthParserRegistered(t *testing.T) {
	if _, ok := xeParsers[sysHealthEvent]; !ok {
		t.Fatal("no parser registered for " + sysHealthEvent)
	}
	for _, c := range []Collector{errorLogCollector{}, defaultTraceCollector{}, sysHealthCollector{}} {
		if _, ok := c.(BatchCollector); !ok {
			t.Errorf("%s is not a batch collector", c.Name())
		}
		if ok, _ := c.Applies(Info{Kind: KindAzureDB}); ok {
			t.Errorf("%s applies on Azure SQL Database", c.Name())
		}
		if ok, why := c.Applies(Info{Kind: KindServer}); !ok {
			t.Errorf("%s does not apply on a server: %s", c.Name(), why)
		}
	}
}

// The terse form (one line, the error and its text; the review's sample from a sandbox archive) is a whole error: at
// severity 17 it is kept with its numbers, under 17 it is noise; a severity of -1 is read; an error line whose
// message never came is dropped at the end of the current log and kept at the end of an archive only when it is 17+.
func TestErrorLogTerse(t *testing.T) {
	sh := &errorLogShred{}
	rows := shredAll(sh,
		lines("2026-11-10T01:17:13.67", "spid30s", "Error: 802, Severity: 17, State: 2. (Params:). The error is printed in terse mode because there was error during formatting. Tracing, ETW, notifications etc are skipped."),
		lines("2026-11-10T01:17:13.67", "spid31s", "Error: 17300, Severity: 16, State: 1. (Params:). The error is printed in terse mode because there was error during formatting. Tracing, ETW, notifications etc are skipped."),
		lines("2026-11-10T01:17:14", "spid32s", "Error: 18052, Severity: -1, State: 0."),
		lines("2026-11-10T01:17:15", "spid33s", "Error: 18052, Severity: -1, State: 0. (Params:). The error is printed in terse mode"))
	if len(rows) != 1 || rows[0]["error_number"] != int64(802) || rows[0]["severity"] != 17 {
		t.Fatalf("rows %v, want the one severity 17 terse error", rows)
	}
	sh = &errorLogShred{}
	sh.add(lines("2026-11-10T01:00:00", "spid9", "Error: 823, Severity: 24, State: 2.")[0])
	sh.drop()
	if got := sh.flush(); len(got) != 0 {
		t.Errorf("a dropped error line came back: %v", got)
	}
}

// Lines out of time order (the log under memory pressure): the same line at one instant before and after a line of
// another instant gets two keys, never the same one twice.
func TestErrorLogKeyOutOfOrder(t *testing.T) {
	sh := &errorLogShred{}
	x := "Autogrow of file 'x' in database 'y' was cancelled by user or timed out"
	rows := shredAll(sh, lines("2026-11-10T12:00:00", "spid9", x), lines("2026-11-10T11:58:00", "spid9", x), lines("2026-11-10T12:00:00", "spid9", x))
	seen := map[any]bool{}
	for _, r := range rows {
		if seen[r["line_key"]] {
			t.Fatalf("a key twice: %v", r["line_key"])
		}
		seen[r["line_key"]] = true
	}
	if len(rows) != 3 {
		t.Fatalf("rows %d, want 3", len(rows))
	}
}

// Where a read starts: the first read a week back; after it half an hour before the cursor on the server's clock,
// by the earlier of the stored and today's offset (a clock set forward and a clock set back both lose nothing).
func TestErrorLogStart(t *testing.T) {
	now := time.Date(2027, 3, 14, 3, 3, 0, 0, time.UTC)
	if s, after := errorLogStart(Cursor{}, now, -7*time.Hour); !s.Equal(now.Add(-errorLogFirstRead)) || !after.IsZero() {
		t.Errorf("first read: %v %v", s, after)
	}
	// spring: the last line 01:55 PST (09:55Z) read at -480; today -420
	spring := Cursor{Found: true, FileName: errorLogOffsetMark, FileOffset: -480, LastEventAt: time.Date(2027, 3, 14, 9, 55, 0, 0, time.UTC)}
	if s, _ := errorLogStart(spring, now, -7*time.Hour); s.Format("15:04") != "01:25" {
		t.Errorf("spring: start %s, want 01:25 (01:55 PST less the overlap)", s.Format("15:04"))
	}
	// fall: the last line 01:59 PDT (08:59Z) read at -420; today -480
	fall := Cursor{Found: true, FileName: errorLogOffsetMark, FileOffset: -420, LastEventAt: time.Date(2027, 11, 7, 8, 59, 0, 0, time.UTC)}
	if s, _ := errorLogStart(fall, now, -8*time.Hour); s.Format("15:04") != "00:29" {
		t.Errorf("fall: start %s, want 00:29 (00:59 PST less the overlap)", s.Format("15:04"))
	}
	// a cursor without the stored offset: today's
	old := Cursor{Found: true, LastEventAt: time.Date(2027, 3, 14, 9, 55, 0, 0, time.UTC)}
	if s, _ := errorLogStart(old, now, -7*time.Hour); s.Format("15:04") != "02:25" {
		t.Errorf("no stored offset: start %s, want 02:25", s.Format("15:04"))
	}
}

// A keyword in the arguments names nothing; the first word does.
func TestDBCCCommandFirstWord(t *testing.T) {
	for in, want := range map[string]string{
		"DBCC CHECKDB(N'WritePageAudit')":                  "DBCC CHECKDB",
		"DBCC SHOW_STATISTICS('dbo.FreeProcCacheLog', ix)": "DBCC SHOW_STATISTICS",
		"DBCC INPUTBUFFER(@session_id) WITH NO_INFOMSGS":   "DBCC INPUTBUFFER",
	} {
		if got := dbccCommand(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

// A growth's cursor time is when it was written (its end), not its stamp.
func TestTraceRowWriteTime(t *testing.T) {
	_, wrote, _, ok := traceRow(collect.Row{"event_class": int64(93), "local_at": "2026-11-11T17:09:01.66", "wrote_local": "2026-11-11T17:10:01.697",
		"seq": int64(106301)}, 0)
	if !ok || wrote.Format("15:04:05.000") != "17:10:01.697" {
		t.Errorf("wrote %v, want 17:10:01.697", wrote)
	}
}
