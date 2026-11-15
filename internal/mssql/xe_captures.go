package mssql

import (
	"context"
	"database/sql"
	"encoding/xml"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_xe_captures (task 411, B18; migration 0162): the optional Extended Events captures SQLWATCH and SQLMonitor have
// and pgvigil's four sessions (xe.go) do not. Each is a session of its own, pgvigil_<install id>_<capture>, made only by
// the DBA running the printed script (Allen Q5: the sessions stay a script the DBA runs; a site profile that lets
// pgvigil make them is task 330's), off until then:
//
//	waits       sqlos.wait_info and wait_info_external that END after a threshold (default 1,000 ms; wait_info's
//	            duration is in milliseconds), of a user session in a database; WAITFOR and BROKER_RECEIVE_WAITFOR left
//	            out by their map keys, read on the server by the script (sys.dm_xe_map_values)
//	warnings    eleven query warnings: additional_memory_grant, exchange_spill, execution_warning, hash_warning,
//	            long_io_detected, missing_column_statistics, missing_join_predicate, optimizer_timeout,
//	            plan_affecting_convert, sort_warning, unmatched_filtered_indexes (an event the version lacks is left out
//	            by the script, with a line saying so)
//	warncounts  page_split (user databases) and sp_cache_miss: counted only, in an event_counter target (their volume
//	            would fill any buffer)
//	modules     sqlserver.module_end over a threshold (default 5 s; module_end's duration is in MICROseconds), with the
//	            procedure exclusion list (database + object name, LIKE)
//
// Every predicate leaves out the app names of the exclusion list (an entry with % or _ is a LIKE pattern, else an exact
// name) and pgvigil's own sessions; the order is the duration, is_system, database_id, the exact names, the LIKEs last.
// The session options as xe.go's: MAX_MEMORY 4 MB, ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY 5 s, STARTUP_STATE ON;
// an event file on the server, RDS and Cloud SQL forms (in the folders xe.go names), a ring buffer on Managed Instance
// and Azure SQL Database. The statement text action (sql_text) is left out of the script when the instance keeps no text
// (query_text none). The source of the event lists and predicates: SQLWATCH 4.11's SQLWATCH_waits.sql and
// SQLWATCH_query_problems.sql (MIT, Copyright (c) 2018 Marcin Gminski); pgvigil's own text.
const (
	xcWaits     = "waits"
	xcWarnings  = "warnings"
	xcCounts    = "warncounts"
	xcModules   = "modules"
	xcCollector = Prefix + "xe_captures"
)

// XECaptureNames are the optional captures in the order the page shows them.
var XECaptureNames = []string{xcWaits, xcWarnings, xcCounts, xcModules}

// xcEvents are each capture's events, with their package.
var xcEvents = map[string][]string{
	xcWaits: {"sqlos.wait_info", "sqlos.wait_info_external"},
	xcWarnings: {"sqlserver.additional_memory_grant", "sqlserver.exchange_spill", "sqlserver.execution_warning",
		"sqlserver.hash_warning", "sqlserver.long_io_detected", "sqlserver.missing_column_statistics",
		"sqlserver.missing_join_predicate", "sqlserver.optimizer_timeout", "sqlserver.plan_affecting_convert",
		"sqlserver.sort_warning", "sqlserver.unmatched_filtered_indexes"},
	xcCounts:  {"sqlserver.page_split", "sqlserver.sp_cache_miss"},
	xcModules: {"sqlserver.module_end"},
}

// xcEventNames are a capture's event names without the package (what the reader is told to keep).
func xcEventNames(capture string) []string {
	var out []string
	for _, e := range xcEvents[capture] {
		out = append(out, e[strings.IndexByte(e, '.')+1:])
	}
	return out
}

func init() {
	for _, e := range xcEventNames(xcWaits) {
		xeParsers[e] = parseXWait
	}
	for _, e := range xcEventNames(xcWarnings) {
		xeParsers[e] = parseXWarning
	}
	xeParsers["module_end"] = parseXModule
	Register(xeCapturesCollector{})
}

// XECaptureSettings are what the script and the read take from the repository (0162's settings; the defaults below).
type XECaptureSettings struct {
	WaitMS      int      // a wait shorter than this is not captured (ms)
	ModuleMS    int      // a module shorter than this is not captured (ms; the script turns it into microseconds)
	AppExclude  []string // client_app_name: an exact name, or a LIKE pattern when it holds % or _
	ProcExclude []string // database.object_name LIKE pattern: master.sp[_]%
}

// DefaultXECaptureSettings: SQLWATCH's thresholds and exclusions (its waits and long-query sessions, its default
// exclusions EXC#9 and EXC#12-13), pgvigil's own program name.
func DefaultXECaptureSettings() XECaptureSettings {
	return XECaptureSettings{WaitMS: 1000, ModuleMS: 5000,
		AppExclude: []string{"pgvigil", "Microsoft SQL Server Management Studio", "Microsoft SQL Server Management Studio - Transact-SQL IntelliSense",
			"SQLAgent - Job Manager", "SQLAgent - Job invocation engine", "SQLAgent - Schedule Saver", "SQLServerCEIP", "DacFx Deploy",
			"DatabaseMail%", "SQLAgent - TSQL JobStep%"},
		ProcExclude: []string{"master.sp[_]%", "msdb.sp[_]%"}}
}

var xcEntryRE = regexp.MustCompile(`^[^\x00-\x1f]{1,200}$`)

// CheckXECaptureSettings refuses what the script could not carry.
func CheckXECaptureSettings(s XECaptureSettings) error {
	if s.WaitMS < 100 || s.WaitMS > 600000 {
		return errors.New("the wait threshold is 100 to 600000 ms")
	}
	if s.ModuleMS < 100 || s.ModuleMS > 3600000 {
		return errors.New("the module threshold is 100 to 3600000 ms")
	}
	for _, a := range s.AppExclude {
		if !xcEntryRE.MatchString(a) {
			return fmt.Errorf("an app name of 1 to 200 printable characters: %q", a)
		}
	}
	for _, p := range s.ProcExclude {
		if !xcEntryRE.MatchString(p) || !strings.Contains(p, ".") {
			return fmt.Errorf("a procedure exclusion is database.name_pattern: %q", p)
		}
	}
	return nil
}

// tq doubles a single quote twice over: the text sits in a literal of the dynamic SQL inside the script's literal.
func tq(s string) string { return strings.ReplaceAll(s, "'", "''''") }

func isLikePattern(s string) bool { return strings.ContainsAny(s, "%_[") }

// xcAppPred is the app-name exclusions: the exact names first, the LIKE patterns last.
func xcAppPred(apps []string) string {
	var exact, like strings.Builder
	for _, a := range apps {
		if isLikePattern(a) {
			fmt.Fprintf(&like, " AND NOT [sqlserver].[like_i_sql_unicode_string]([sqlserver].[client_app_name],N''%s'')", tq(a))
		} else {
			fmt.Fprintf(&exact, " AND [sqlserver].[client_app_name]<>N''%s''", tq(a))
		}
	}
	return exact.String() + like.String()
}

// xcProcPred leaves out a module of a listed database whose object name matches the pattern.
func xcProcPred(procs []string) string {
	var b strings.Builder
	for _, p := range procs {
		db, name, _ := strings.Cut(p, ".")
		fmt.Fprintf(&b, " AND NOT ([sqlserver].[database_name]=N''%s'' AND [sqlserver].[like_i_sql_unicode_string]([object_name],N''%s''))", tq(db), tq(name))
	}
	return b.String()
}

// XECapturesScript writes the T-SQL that creates and starts the optional sessions named in captures (empty: all four)
// for one install id: text for the server's DBA, never run by pgvigil. A session that exists is left as it is, one that
// is stopped is started, nothing else on the server changes. textPolicy is the instance's query_text: under none the
// statement text action is not captured at all.
func XECapturesScript(installID, form, textPolicy string, captures []string, s XECaptureSettings) (string, error) {
	if err := xeCheckArgs(installID, form); err != nil {
		return "", err
	}
	if err := CheckXECaptureSettings(s); err != nil {
		return "", err
	}
	if len(captures) == 0 {
		captures = XECaptureNames
	}
	for _, c := range captures {
		if _, ok := xcEvents[c]; !ok {
			return "", fmt.Errorf("the capture %q is one of %s", c, strings.Join(XECaptureNames, ", "))
		}
	}
	sc := xeScopeOf(form)
	var b strings.Builder
	w := func(format string, a ...any) { fmt.Fprintf(&b, format, a...) }
	w("/*\n  pgvigil - the optional Extended Events captures, install id %s, form: %s.\n", installID, form)
	w("  Run it as a login that may create event sessions (ALTER ANY EVENT SESSION, or CONTROL SERVER)%s.\n",
		map[bool]string{true: ", IN THE DATABASE pgvigil connects to (database-scoped sessions)", false: ", in master"}[form == XEFormAzureDB])
	if form == XEFormRDS {
		w("  Amazon RDS: Standard or Enterprise only (RDS refuses event sessions on Express and Web); as the master user.\n")
	}
	if form == XEFormAzureMI || form == XEFormAzureDB {
		w("  NOT PROVEN on this form: written from the documentation, not run against a real %s.\n", form)
	}
	w("  pgvigil's monitoring login cannot run it and is never asked to: it only reads what these sessions capture.\n")
	w("  Each capture is a session of its own; a session that already exists is left exactly as it is, one that is stopped\n"+
		"  is started, nothing else on the server changes. To change one, drop it (pgvigil mssql-xe -print -drop -captures ...)\n"+
		"  and run this again. Made with: waits over %d ms; modules over %d ms; the app names left out: %s; the\n"+
		"  procedures left out: %s.%s\n*/\nSET NOCOUNT ON;\n\n",
		s.WaitMS, s.ModuleMS, strings.Join(s.AppExclude, ", "), strings.Join(s.ProcExclude, ", "),
		map[bool]string{true: "\n  Statement text is not captured: the instance keeps none (query_text none).", false: ""}[textPolicy == "none"])
	if form == XEFormAzureDB {
		w("IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5\nBEGIN\n  RAISERROR('This is the Azure SQL Database form; print the script again with the right -form.', 16, 1);\n  RETURN;\nEND;\n")
	} else {
		w("IF CAST(SERVERPROPERTY('EngineEdition') AS int) = 5\nBEGIN\n  RAISERROR('This server is Azure SQL Database: print the script again with -form azuresqldb.', 16, 1);\n  RETURN;\nEND;\n")
	}
	w("DECLARE @sql nvarchar(max), @body nvarchar(max);\n")
	// a map key the version does not have leaves -1, never NULL (a NULL would empty the whole session's text)
	w("DECLARE @k_waitfor nvarchar(20) = ISNULL((SELECT CAST(MIN(map_key) AS nvarchar(20)) FROM sys.dm_xe_map_values WHERE name = N'wait_types' AND map_value = N'WAITFOR'), N'-1');\n")
	w("DECLARE @k_broker nvarchar(20) = ISNULL((SELECT CAST(MIN(map_key) AS nvarchar(20)) FROM sys.dm_xe_map_values WHERE name = N'wait_types' AND map_value = N'BROKER_RECEIVE_WAITFOR'), N'-1');\n\n")

	who := "sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.server_principal_name,sqlserver.session_id"
	if form == XEFormAzureDB {
		who = strings.Replace(who, "sqlserver.server_principal_name", "sqlserver.username", 1)
	}
	text := ",sqlserver.sql_text"
	if textPolicy == "none" {
		text = ""
	}
	apps := xcAppPred(s.AppExclude)
	opts := "WITH (MAX_MEMORY=4096 KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY=5 SECONDS, MEMORY_PARTITION_MODE=NONE, TRACK_CAUSALITY=OFF, STARTUP_STATE=ON)"
	target := func(capture string) string {
		if capture == xcCounts {
			return "ADD TARGET package0.event_counter"
		}
		if !xeFileForm(form) {
			return "ADD TARGET package0.ring_buffer(SET max_memory=(4096))"
		}
		dir := ""
		switch form {
		case XEFormCloudSQL:
			dir = xeCloudSQLDir
		case XEFormRDS:
			dir = xeRDSDir
		}
		return "ADD TARGET package0.event_file(SET filename=N''" + dir + XESessionName(installID, capture) + ".xel'', max_file_size=(20), max_rollover_files=(4))"
	}
	predOf := func(capture, event string) string {
		switch {
		case capture == xcWaits && event == "wait_info":
			return "([opcode]=(1) AND [duration]>=(" + fmt.Sprint(s.WaitMS) + ") AND [sqlserver].[is_system]=(0) AND [sqlserver].[database_id]>(0)" +
				" AND [wait_type]<>(' + @k_waitfor + N') AND [wait_type]<>(' + @k_broker + N')" + apps + ")"
		case capture == xcWaits:
			return "([opcode]=(1) AND [duration]>=(" + fmt.Sprint(s.WaitMS) + ") AND [sqlserver].[is_system]=(0) AND [sqlserver].[database_id]>(0)" + apps + ")"
		case capture == xcModules:
			return "([duration]>=(" + fmt.Sprint(int64(s.ModuleMS)*1000) + ") AND [sqlserver].[is_system]=(0)" + apps + xcProcPred(s.ProcExclude) + ")"
		case event == "page_split":
			return "([sqlserver].[is_system]=(0) AND [sqlserver].[database_id]>(4))"
		}
		return "([sqlserver].[is_system]=(0)" + apps + ")"
	}
	actsOf := func(capture string) string {
		switch capture {
		case xcWaits:
			return "package0.event_sequence," + who + ",sqlserver.plan_handle,sqlserver.query_plan_hash" + text
		case xcWarnings:
			return "package0.event_sequence," + who + ",sqlserver.query_plan_hash" + text
		case xcModules:
			return "package0.event_sequence," + who
		}
		return "package0.event_sequence,sqlserver.database_name"
	}
	for _, c := range captures {
		n := XESessionName(installID, c)
		w("-- %s\nIF NOT EXISTS (SELECT 1 FROM %s WHERE name = N'%s')\nBEGIN\n  SET @body = N'';\n", n, sc.defs, n)
		for _, e := range xcEvents[c] {
			name := e[strings.IndexByte(e, '.')+1:]
			pkg := e[:strings.IndexByte(e, '.')]
			w("  IF EXISTS (SELECT 1 FROM sys.dm_xe_objects o JOIN sys.dm_xe_packages p ON p.guid = o.package_guid WHERE o.name = N'%s' AND p.name = N'%s' AND o.object_type = N'event')\n"+
				"    SET @body = @body + CASE WHEN @body = N'' THEN N'' ELSE N',' + NCHAR(10) END + N'ADD EVENT %s(ACTION(%s) WHERE %s)';\n"+
				"  ELSE PRINT 'left out (this version has no such event): %s';\n", name, pkg, e, actsOf(c), predOf(c, name), e)
		}
		w("  IF @body <> N''\n  BEGIN\n    SET @sql = N'CREATE EVENT SESSION [%[1]s] ON %[2]s' + NCHAR(10) + @body + NCHAR(10) + N'%[3]s' + NCHAR(10) + N'%[4]s';\n"+
			"    EXEC sys.sp_executesql @sql;\n  END;\n"+
			"  IF EXISTS (SELECT 1 FROM %[5]s WHERE name = N'%[1]s') PRINT 'created: %[1]s'; ELSE PRINT 'NOT created: %[1]s';\nEND\nELSE PRINT 'exists, left as it is: %[1]s';\n",
			n, sc.on, target(c), opts, sc.defs)
		w("IF EXISTS (SELECT 1 FROM %[2]s WHERE name = N'%[1]s') AND NOT EXISTS (SELECT 1 FROM %[3]s WHERE name = N'%[1]s')\nBEGIN\n  ALTER EVENT SESSION [%[1]s] ON %[4]s STATE = START;\n"+
			"  IF EXISTS (SELECT 1 FROM %[3]s WHERE name = N'%[1]s') PRINT 'started: %[1]s'; ELSE PRINT 'NOT started: %[1]s';\nEND;\n\n", n, sc.defs, sc.running, sc.on)
	}
	w("SELECT d.name AS session, CASE WHEN r.name IS NULL THEN 'stopped' ELSE 'running' END AS state\n  FROM %s d LEFT JOIN %s r ON r.name = d.name\n WHERE d.name IN (%s) ORDER BY d.name;\n",
		sc.defs, sc.running, xcNameList(installID, captures))
	return b.String(), nil
}

func xcNameList(installID string, captures []string) string {
	var q []string
	for _, c := range captures {
		q = append(q, "N'"+XESessionName(installID, c)+"'")
	}
	return strings.Join(q, ", ")
}

// XECapturesDropScript drops the optional sessions of one install id by name and nothing else: a session pgvigil did not
// make is never dropped. The event files a session wrote stay (pass F17): its header says where and how they go.
func XECapturesDropScript(installID, form string, captures []string) (string, error) {
	if err := xeCheckArgs(installID, form); err != nil {
		return "", err
	}
	if len(captures) == 0 {
		captures = XECaptureNames
	}
	sc := xeScopeOf(form)
	var b strings.Builder
	files := map[string]string{
		XEFormServer:   "in the server's log folder (the folder of SERVERPROPERTY('ErrorLogFileName')): delete pgvigil_" + installID + "_<capture>*.xel there by hand once the sessions are gone",
		XEFormRDS:      "in " + xeRDSDir + ": RDS deletes them by its own retention (rdsadmin.dbo.rds_set_configuration 'xe_file_retention', in hours)",
		XEFormCloudSQL: "in " + xeCloudSQLDir + ": Google's documentation names no removal; they stay until the instance is rebuilt",
		XEFormAzureMI:  "none: this form keeps ring buffers only",
		XEFormAzureDB:  "none: this form keeps ring buffers only",
	}
	fmt.Fprintf(&b, "/* pgvigil - drops the optional Extended Events sessions of install id %s (form: %s) and nothing else.\n"+
		"   The event files they wrote stay: %s. */\nSET NOCOUNT ON;\n", installID, form, files[form])
	for _, c := range captures {
		if _, ok := xcEvents[c]; !ok {
			return "", fmt.Errorf("the capture %q is one of %s", c, strings.Join(XECaptureNames, ", "))
		}
		n := XESessionName(installID, c)
		fmt.Fprintf(&b, "IF EXISTS (SELECT 1 FROM %s WHERE name = N'%s')\nBEGIN\n  DROP EVENT SESSION [%s] ON %s;\n  PRINT 'dropped: %s';\nEND\nELSE PRINT 'not there: %s';\n", sc.defs, n, n, sc.on, n, n)
	}
	return b.String(), nil
}

// ---- the parsers (registered in xeParsers by init: the shred of xe.go's reader turns each event into its row)

func xcWho(e *xeEvent, row collect.Row) {
	row["login_name"] = e.act("server_principal_name")
	if row["login_name"] == nil {
		row["login_name"] = e.act("username")
	}
	row["host_name"], row["program_name"], row["database_name"] = e.act("client_hostname"), e.act("client_app_name"), e.act("database_name")
	row["session_id"] = e.actNum("session_id")
}

// parseXWait: one wait that ended over the threshold; duration and signal in milliseconds; the statement under the
// instance's text policy (the emit rewrites the 'statement' key)
func parseXWait(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("xwait", e, c)
	if !ok {
		return nil
	}
	wt, _ := e.mapped("wait_type").(string)
	row["wait_type"], row["category"] = strOrNil(wt), strOrNil(waitCategory(wt))
	row["duration_ms"], row["signal_ms"] = e.num("duration"), e.num("signal_duration")
	xcWho(e, row)
	row["plan_handle"] = e.act("plan_handle")
	row["query_plan_hash_hex"] = hashHex(e.act("query_plan_hash"))
	if st, _ := e.act("sql_text").(string); st != "" {
		row["statement"] = st
	}
	return row
}

// parseXWarning: one query warning with its detail (the event's own fields that say what it was)
func parseXWarning(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("xwarn", e, c)
	if !ok {
		return nil
	}
	xcWho(e, row)
	row["query_plan_hash_hex"] = hashHex(e.act("query_plan_hash"))
	var parts []string
	for _, f := range e.Data {
		if f.Name == "" {
			continue
		}
		v := fieldStr(&f)
		if s, ok := v.(string); ok && s != "" && len(s) < 200 {
			parts = append(parts, f.Name+"="+s)
		}
	}
	row["detail"] = strOrNil(strings.Join(parts, "; "))
	if st, _ := e.act("sql_text").(string); st != "" {
		row["statement"] = st
	}
	return row
}

// parseXModule: a module's whole run; duration in microseconds as module_end gives it
func parseXModule(e *xeEvent, c xeContext) collect.Row {
	row, ok := xeBase("xmodule", e, c)
	if !ok {
		return nil
	}
	xcWho(e, row)
	row["object_name"], row["object_type"] = e.str("object_name"), e.mapped("object_type")
	row["duration_us"], row["row_count"] = e.num("duration"), e.num("row_count")
	row["source_database_id"] = e.num("source_database_id")
	return row
}

// ---- the reader

type xeCapturesCollector struct{}

func (xeCapturesCollector) Name() string                   { return xcCollector }
func (xeCapturesCollector) DefaultInterval() time.Duration { return time.Minute }
func (xeCapturesCollector) Timeout() time.Duration         { return 50 * time.Second }

func (xeCapturesCollector) Applies(info Info) (bool, string) {
	if !info.ViewServerState {
		return false, "the login lacks VIEW SERVER STATE: the Extended Events sessions and their targets cannot be read"
	}
	return true, ""
}

func (xeCapturesCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_xe_captures reads from a cursor: it runs through the batch path (RunBatches)")
}

// RunBatches reads each optional capture's session past its cursor (xe.go's readSession) and the counts session's
// event_counter; one state row per capture says not installed, stopped or running and what the last read found.
func (xeCapturesCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	targets, err := xeListTargets(ctx, conn, info)
	if err != nil {
		return err
	}
	sessions := xeGroup(targets)
	r := &xeRun{ctx: ctx, conn: conn, info: info, opt: opt, cursor: cursor, emit: emit, now: time.Now()}
	var tail []collect.Row
	for _, capture := range XECaptureNames {
		s := xePick(sessions, capture)
		state := collect.Row{"kind": "xstate", "capture": capture, "state": xeStateOf(s)}
		if s != nil {
			state["session_name"] = s.name
		}
		switch {
		case s == nil || !s.running:
		case capture == xcCounts:
			tail = append(tail, xcCounterRows(s, state)...)
		default:
			if err := r.readSession(s, "product", xcEventNames(capture), state); err != nil {
				tail = append(tail, collect.Row{"kind": "collector_error", "source": s.name, "message": err.Error()})
			}
		}
		tail = append(tail, state)
	}
	return emit(tail)
}

// xcCounterRows reads the counts session's event_counter: the count of each event since the session started (the
// import turns two reads into a difference; a restart starts again from zero, and the import says so).
func xcCounterRows(s *xeSession, state collect.Row) []collect.Row {
	t, ok := s.targets["event_counter"]
	if !ok || t.targetData == "" {
		state["note"] = "the session has no event_counter target"
		return nil
	}
	var ct xeCounterTarget
	if err := xml.Unmarshal([]byte(t.targetData), &ct); err != nil {
		state["note"] = "the event_counter's data could not be read: " + err.Error()
		return nil
	}
	var out []collect.Row
	for _, p := range ct.Packages {
		for _, e := range p.Events {
			out = append(out, collect.Row{"kind": "xcount", "event_name": e.Name, "count": e.Count, "session_name": s.name})
		}
	}
	state["target"] = "event_counter"
	return out
}
