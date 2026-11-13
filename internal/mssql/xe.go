package mssql

import (
	"context"
	"database/sql"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_xe: Extended Events, read where a DBA installed the sessions and reported as "not installed" where not.
//
// pgvigil's read login never creates, alters, starts, stops or drops an event session. XEScript writes the DDL of
// the four sessions (one small session per capture, named pgvigil_<install id>_<capture>) for the server's DBA to
// run; the collector finds them by that name pattern and reads their targets from a cursor. It also reads, and never
// touches, system_health (its deadlock reports, on a server without the product's deadlock session) and
// AlwaysOn_health (where Always On is enabled).
//
// The session definitions are pgvigil's own text; their shape follows two MIT-licensed sources, named here and in
// THIRD-PARTY-NOTICES.md:
//   - DBA Dash 4.24.1 (Copyright 2022 Trimble, Inc.; MIT), DBADash/SQL/SQLDeadlockSession.sql,
//     SQLSlowQueriesEventFileSession.sql, SQLSlowQueries.sql and SQLDeadlockSessionAzure.sql: a dedicated deadlock
//     session instead of reading system_health every time, the slow-query session's events, actions and duration
//     predicate, its event_file target read from a resume cursor, the ring-buffer form for Managed Instance and the
//     database-scoped form for Azure SQL Database.
//   - PerformanceMonitor at commit 65bdb5f (Erik Darling, Darling Data LLC; MIT), DarlingXeSessions.cs and
//     AlwaysOnXeSessions.cs: one session per capture, the blocked-process and attention sessions (a ring buffer, and
//     an event_counter beside it for attention), the five-second dispatch latency.

// The captures, in the order the pages show them.
const (
	xeDeadlocks = "deadlocks"
	xeBlocked   = "blocked"
	xeSlow      = "slow"
	xeAttention = "attention"
	xeAG        = "ag"
)

// xeCaptures are the four captures a DBA installs from the script.
var xeCaptures = []string{xeDeadlocks, xeBlocked, xeSlow, xeAttention}

// xeCaptureEvents names the events of each capture's session. The script adds exactly these and the reader parses
// exactly these (xeParsers); a test holds the two together.
var xeCaptureEvents = map[string][]string{
	xeDeadlocks: {"xml_deadlock_report"},
	xeBlocked:   {"blocked_process_report"},
	xeSlow:      {"rpc_completed", "sql_batch_completed", "sql_statement_completed", "sp_statement_completed"},
	xeAttention: {"attention"},
}

// xeAGEvents are the AlwaysOn_health events the reader stores; the session's other events only move the cursor.
var xeAGEvents = []string{"availability_replica_state_change", "availability_replica_manager_state_change",
	"availability_group_lease_expired", "alwayson_ddl_executed", "error_reported", "lock_redo_blocked"}

// The forms of the session script.
const (
	XEFormServer  = "server"     // SQL Server on a machine, a VM or a container, and Amazon RDS for SQL Server
	XEFormAzureMI = "azuresqlmi" // Azure SQL Managed Instance: no local event file, a ring buffer for every capture
	XEFormAzureDB = "azuresqldb" // Azure SQL Database: database-scoped sessions, a ring buffer for every capture
	// Google Cloud SQL for SQL Server: the server form, its event file in the folder Google names
	// (/var/opt/mssql/xevents/) and the blocked process threshold a database flag (no sp_configure there)
	XEFormCloudSQL = "cloudsql"
)

// xeCloudSQLDir is where Cloud SQL for SQL Server keeps Extended Events files (Google's Cloud SQL for SQL Server
// pages; a bare file name, the server form's, is not proven there).
const xeCloudSQLDir = "/var/opt/mssql/xevents/"

// xeFileForm says whether the form writes the slow capture to an event file (the others keep a ring buffer).
func xeFileForm(form string) bool { return form == XEFormServer || form == XEFormCloudSQL }

var xeInstallID = regexp.MustCompile(`^[a-z0-9]{1,20}$`)

// XESessionName is the name of one capture's session for an install id.
func XESessionName(installID, capture string) string { return "pgvigil_" + installID + "_" + capture }

func xeCheckArgs(installID, form string) error {
	if !xeInstallID.MatchString(installID) {
		return fmt.Errorf("the install id %q must be 1 to 20 lower-case letters and digits (it is part of the session names)", installID)
	}
	switch form {
	case XEFormServer, XEFormAzureMI, XEFormAzureDB, XEFormCloudSQL:
		return nil
	}
	return fmt.Errorf("the form %q must be %s, %s, %s or %s", form, XEFormServer, XEFormAzureMI, XEFormAzureDB, XEFormCloudSQL)
}

// xeScope is what differs between a server-scoped and a database-scoped session script.
type xeScope struct{ on, defs, running, deadlock string }

func xeScopeOf(form string) xeScope {
	if form == XEFormAzureDB {
		return xeScope{"DATABASE", "sys.database_event_sessions", "sys.dm_xe_database_sessions", "database_xml_deadlock_report"}
	}
	return xeScope{"SERVER", "sys.server_event_sessions", "sys.dm_xe_sessions", "xml_deadlock_report"}
}

// XEScript writes the T-SQL that creates and starts the four sessions for one install id. It is text for the
// server's DBA: pgvigil prints it and never runs it. The script creates a session only when no session of that name
// exists, starts one that is stopped, changes no server setting, and shows the blocked process threshold it found.
func XEScript(installID, form string) (string, error) {
	if err := xeCheckArgs(installID, form); err != nil {
		return "", err
	}
	sc := xeScopeOf(form)
	name := func(c string) string { return XESessionName(installID, c) }
	var b strings.Builder
	w := func(format string, a ...any) { fmt.Fprintf(&b, format, a...) }
	w("/*\n  pgvigil - Extended Events sessions, install id %s, form: %s.\n", installID, form)
	switch form {
	case XEFormAzureDB:
		w("  Azure SQL Database: run it IN THE DATABASE pgvigil connects to. The sessions are database-scoped and every\n" +
			"  target is a ring buffer (an event file there needs a storage container and a credential).\n" +
			"  Proven against Azure SQL Database (General Purpose serverless) by scripts/proof-mssql-azuresqldb.sh.\n")
	case XEFormAzureMI:
		w("  Azure SQL Managed Instance: run it in master. Every target is a ring buffer (an event file there must be a\n" +
			"  blob URL with a credential).\n" +
			"  NOT PROVEN: this form was written from the documentation and has not been run against a Managed Instance.\n")
	case XEFormCloudSQL:
		w("  Google Cloud SQL for SQL Server: run it in master as the sqlserver user. The slow capture's event file goes\n" +
			"  to " + xeCloudSQLDir + ", the folder Google names for Extended Events files.\n" +
			"  NOT PROVEN: this form was written from Google's pages and has not been run against Cloud SQL.\n")
	default:
		w("  Run it in master as a login that may create event sessions (ALTER ANY EVENT SESSION, or CONTROL SERVER).\n")
	}
	w("  pgvigil's own monitoring login cannot run it and is never asked to: it only reads what these sessions capture.\n\n"+
		"  What it makes, one small session per capture:\n"+
		"    %-34s %s to a ring buffer\n"+
		"    %-34s blocked_process_report to a ring buffer\n"+
		"    %-34s rpc_completed and sql_batch_completed over @slow_ms (and, with\n"+strings.Repeat(" ", 39)+"@slow_statements = 1, sql_statement_completed and sp_statement_completed\n"+strings.Repeat(" ", 39)+"over it)%s\n"+
		"    %-34s attention to a ring buffer, and an event counter\n\n"+
		"  A session that already exists under its name is left exactly as it is; one that is stopped is started.\n"+
		"  Nothing else on the server is changed. To change a session's settings, drop it (the drop script:\n"+
		"  pgvigil mssql-xe -print -drop -install-id %s) and run this script again.\n*/\n",
		name(xeDeadlocks), sc.deadlock, name(xeBlocked), name(xeSlow),
		map[bool]string{true: ", to an event file\n" + strings.Repeat(" ", 39) + "with a size cap and rollover (the one high-volume capture)", false: ", to a ring buffer"}[xeFileForm(form)],
		name(xeAttention), installID)
	w("SET NOCOUNT ON;\n\n-- ---- settings: the DBA's to change before the first run ----\n")
	w("DECLARE @slow_ms          int = 1000;   -- a completion slower than this is captured (milliseconds)\n")
	w("DECLARE @slow_statements  bit = 1;      -- 1: also the single statements over @slow_ms. SQL Server gives a batch or RPC\n" +
		"                                        -- completion no query hash; the statement's event carries it. 0: no hashes.\n")
	if xeFileForm(form) {
		w("DECLARE @slow_file_mb     int = 50;     -- the size of one event file\n")
		w("DECLARE @slow_files       int = 4;      -- files kept; the oldest is deleted at rollover (the cap: size x files)\n")
		w("DECLARE @slow_memory_kb   int = 4096;   -- the session's buffer memory; one event file must hold a third of it\n")
	} else {
		w("DECLARE @slow_kb          int = 4096;   -- the slow session's ring buffer (KB): a full buffer loses its oldest events\n")
	}
	w("DECLARE @deadlock_kb      int = 4096;   -- ring buffer sizes (KB)\n")
	w("DECLARE @blocked_kb       int = 4096;\n")
	w("DECLARE @attention_kb     int = 1024;\n")
	w("-- ---- end of settings ----\n\nDECLARE @sql nvarchar(max), @us nvarchar(30) = CAST(CAST(@slow_ms AS bigint) * 1000 AS nvarchar(30));\n\n")
	if form == XEFormAzureDB {
		w("IF CAST(SERVERPROPERTY('EngineEdition') AS int) <> 5\nBEGIN\n  RAISERROR('This is the Azure SQL Database form; this server is not Azure SQL Database. Print the script again with the right -form.', 16, 1);\n  RETURN;\nEND;\n\n")
	} else {
		w("IF CAST(SERVERPROPERTY('EngineEdition') AS int) = 5\nBEGIN\n  RAISERROR('This server is Azure SQL Database: print the script again with -form azuresqldb.', 16, 1);\n  RETURN;\nEND;\n\n")
	}
	session := func(capture, body string) {
		n := name(capture)
		// a failed CREATE (a login without the right) does not end the batch: each line says what is true afterwards
		w("-- %[1]s\nIF NOT EXISTS (SELECT 1 FROM %[2]s WHERE name = N'%[1]s')\nBEGIN\n  SET @sql = N'CREATE EVENT SESSION [%[1]s] ON %[3]s\n%[4]s';\n  EXEC sys.sp_executesql @sql;\n"+
			"  IF EXISTS (SELECT 1 FROM %[2]s WHERE name = N'%[1]s') PRINT 'created: %[1]s'; ELSE PRINT 'NOT created: %[1]s';\nEND\nELSE PRINT 'exists, left as it is: %[1]s';\n",
			n, sc.defs, sc.on, body)
		w("IF EXISTS (SELECT 1 FROM %[2]s WHERE name = N'%[1]s') AND NOT EXISTS (SELECT 1 FROM %[3]s WHERE name = N'%[1]s')\nBEGIN\n  ALTER EVENT SESSION [%[1]s] ON %[4]s STATE = START;\n"+
			"  IF EXISTS (SELECT 1 FROM %[3]s WHERE name = N'%[1]s') PRINT 'started: %[1]s'; ELSE PRINT 'NOT started: %[1]s';\nEND;\n\n", n, sc.defs, sc.running, sc.on)
	}
	const opts = "WITH (MAX_MEMORY=4096 KB, EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY=5 SECONDS, MEMORY_PARTITION_MODE=NONE, TRACK_CAUSALITY=OFF, STARTUP_STATE=ON)"
	ring := func(kbVar string) string {
		return "ADD TARGET package0.ring_buffer(SET max_memory=(' + CAST(" + kbVar + " AS nvarchar(20)) + N'))"
	}
	session(xeDeadlocks, "ADD EVENT sqlserver."+sc.deadlock+"(ACTION(package0.event_sequence))\n"+ring("@deadlock_kb")+"\n"+opts)
	session(xeBlocked, "ADD EVENT sqlserver.blocked_process_report(ACTION(package0.event_sequence))\n"+ring("@blocked_kb")+"\n"+opts)

	// the slow session: the completions with who ran them; pgvigil's own sessions are left out by their program name
	who := "sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.database_name,sqlserver.server_principal_name,sqlserver.session_id"
	if form == XEFormAzureDB {
		// Azure SQL Database has no server_principal_name action (Msg 25744); username is the login there, and xe_shred.go reads it
		who = strings.Replace(who, "sqlserver.server_principal_name", "sqlserver.username", 1)
	}
	const pred = "WHERE ([duration]>=(' + @us + N') AND [sqlserver].[client_app_name]<>N''pgvigil'')"
	slow := "ADD EVENT sqlserver.rpc_completed(ACTION(package0.event_sequence," + who + ") " + pred + "),\n" +
		"ADD EVENT sqlserver.sql_batch_completed(ACTION(package0.event_sequence," + who + ") " + pred + ")' + CASE WHEN @slow_statements = 1 THEN N',\n" +
		"ADD EVENT sqlserver.sql_statement_completed(ACTION(package0.event_sequence,sqlserver.session_id,sqlserver.database_name,sqlserver.query_hash,sqlserver.query_plan_hash) " + pred + "),\n" +
		"ADD EVENT sqlserver.sp_statement_completed(ACTION(package0.event_sequence,sqlserver.session_id,sqlserver.database_name,sqlserver.query_hash,sqlserver.query_plan_hash) " + pred + ")' ELSE N'' END + N'\n"
	if xeFileForm(form) {
		// the server form's file name has no path: SQL Server writes it to its own log directory, beside system_health's;
		// Cloud SQL's goes to the folder Google names
		dir := ""
		if form == XEFormCloudSQL {
			dir = xeCloudSQLDir
		}
		slow += "ADD TARGET package0.event_file(SET filename=N''" + dir + name(xeSlow) + ".xel'', max_file_size=(' + CAST(@slow_file_mb AS nvarchar(20)) + N'), max_rollover_files=(' + CAST(@slow_files AS nvarchar(20)) + N'))\n" +
			strings.Replace(opts, "MAX_MEMORY=4096 KB", "MAX_MEMORY=' + CAST(@slow_memory_kb AS nvarchar(20)) + N' KB", 1)
	} else {
		slow += ring("@slow_kb") + "\n" + opts
	}
	session(xeSlow, slow)
	session(xeAttention, "ADD EVENT sqlserver.attention(ACTION(package0.event_sequence,"+who+",sqlserver.sql_text))\n"+
		ring("@attention_kb")+",\nADD TARGET package0.event_counter\n"+opts)

	if form != XEFormAzureDB {
		step := "EXEC sys.sp_configure ''blocked process threshold (s)'', 15; RECONFIGURE; (it is an advanced option; 5 is the lowest value SQL Server honours)"
		if form == XEFormCloudSQL {
			step = "the instance''s database flag ''blocked process threshold (s)'' set to 15, where Google''s flag list offers it (Cloud SQL has no sp_configure)"
		}
		b.WriteString("-- The blocked-process capture needs the server's 'blocked process threshold (s)' above 0: at 0 SQL Server raises no\n" +
			"-- blocked-process report and the session stays empty. This script does not change it. The value now:\n" +
			"SELECT name, CAST(value_in_use AS int) AS value_in_use,\n" +
			"       CASE WHEN CAST(value_in_use AS int) = 0 THEN 'no blocked-process report is raised: the DBA''s step is " + step + "'\n" +
			"            ELSE 'a report is raised for a task blocked this many seconds, and again each time that many more pass' END AS meaning\n" +
			"  FROM sys.configurations WHERE name = N'blocked process threshold (s)';\n\n")
	}
	w("SELECT d.name AS session, CASE WHEN r.name IS NULL THEN 'stopped' ELSE 'running' END AS state\n  FROM %s d LEFT JOIN %s r ON r.name = d.name\n WHERE d.name LIKE N'pgvigil[_]%s[_]%%' ORDER BY d.name;\n", sc.defs, sc.running, installID)
	return b.String(), nil
}

// XEDropScript writes the T-SQL that drops the four sessions of one install id, and nothing else. For the DBA, as
// XEScript's text is; the event files a slow session wrote stay in the server's log directory.
func XEDropScript(installID, form string) (string, error) {
	if err := xeCheckArgs(installID, form); err != nil {
		return "", err
	}
	sc := xeScopeOf(form)
	var b strings.Builder
	fmt.Fprintf(&b, "/* pgvigil - drops the Extended Events sessions of install id %s (form: %s) and nothing else. */\nSET NOCOUNT ON;\n", installID, form)
	for _, c := range xeCaptures {
		n := XESessionName(installID, c)
		fmt.Fprintf(&b, "IF EXISTS (SELECT 1 FROM %s WHERE name = N'%s')\nBEGIN\n  DROP EVENT SESSION [%s] ON %s;\n  PRINT 'dropped: %s';\nEND\nELSE PRINT 'not there: %s';\n", sc.defs, n, n, sc.on, n, n)
	}
	return b.String(), nil
}

// ---- the reader

type xeCollector struct{}

func init() { Register(xeCollector{}) }

func (xeCollector) Name() string                   { return Prefix + "xe" }
func (xeCollector) DefaultInterval() time.Duration { return time.Minute }

// Timeout: the reader runs every minute and must be gone before the next run.
func (xeCollector) Timeout() time.Duration { return 50 * time.Second }

func (xeCollector) Applies(info Info) (bool, string) {
	if !info.ViewServerState {
		return false, "the login lacks VIEW SERVER STATE: the Extended Events sessions and their targets cannot be read"
	}
	return true, ""
}

// Run is not the collection's path: RunOnce sends a BatchCollector to RunBatches.
func (xeCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_xe reads from a cursor: it runs through the batch path (RunBatches)")
}

// xeBatchEvents is the most events one batch reads past the cursor; PGVIGIL_MSSQL_XE_BATCH lowers it for the proof.
var xeBatchEvents = envInt("PGVIGIL_MSSQL_XE_BATCH", 1000)

// xeBlockCap is the most events the reader takes to finish one block of an event file (a block is one buffer of the
// session: its size divided by an event's).
const xeBlockCap = 256000

// xeMaxAge: an event older than this is not stored (the first read of system_health on an old server).
const xeMaxAge = 45 * 24 * time.Hour

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return def
}

// xeTarget is one target of one defined session, as the catalog and the DMVs describe it.
type xeTarget struct {
	session    string
	running    bool
	target     string // ring_buffer | event_file | event_counter | ...
	maxMemory  int64  // a ring buffer's max_memory (KB)
	fileSizeMB int64
	dropEvents int64
	dropBufs   int64
	targetData string // the running target's target_data, for every target but a ring buffer
}

// xeSessionsSQL lists the sessions the reader cares about, one row per session and target (a session without a
// target: one row). %[1]s is the scope word in the catalog and DMV names (server | database). All of it is as old as
// SQL Server 2012; sys.server_event_sessions and the DMVs need VIEW SERVER STATE.
const xeSessionsSQL = `SELECT CAST(d.name AS nvarchar(128)) AS name,
  CAST(CASE WHEN r.address IS NULL THEN 0 ELSE 1 END AS int) AS running,
  CAST(dt.name AS nvarchar(128)) AS target,
  (SELECT TOP (1) TRY_CAST(CAST(f.value AS nvarchar(100)) AS bigint) FROM sys.%[1]s_event_session_fields f
    WHERE f.event_session_id = dt.event_session_id AND f.object_id = dt.target_id AND f.name = N'max_memory') AS max_memory_kb,
  (SELECT TOP (1) TRY_CAST(CAST(f.value AS nvarchar(100)) AS bigint) FROM sys.%[1]s_event_session_fields f
    WHERE f.event_session_id = dt.event_session_id AND f.object_id = dt.target_id AND f.name = N'max_file_size') AS max_file_size_mb,
  CAST(r.dropped_event_count AS bigint) AS dropped_events,
  CAST(r.dropped_buffer_count AS bigint) AS dropped_buffers,
  CASE WHEN dt.name <> N'ring_buffer' THEN CAST(rt.target_data AS nvarchar(max)) END AS target_data
FROM sys.%[1]s_event_sessions d
LEFT JOIN sys.%[1]s_event_session_targets dt ON dt.event_session_id = d.event_session_id
LEFT JOIN sys.dm_xe_%[2]ssessions r ON r.name = d.name
LEFT JOIN sys.dm_xe_%[2]ssession_targets rt ON rt.event_session_address = r.address AND rt.target_name = dt.name
WHERE d.name LIKE N'pgvigil[_]%%' OR d.name IN (N'system_health', N'AlwaysOn_health')
ORDER BY d.name, dt.name`

// xeRingSQL reads one ring buffer whole, once, into a variable and hands it over in pieces of 16,000 characters as
// binary: one consistent copy of the buffer (a second read of target_data would be another buffer), no XQuery on the
// server, and no value larger than a piece on the wire. %[1]s as in xeSessionsSQL.
const xeRingSQL = `DECLARE @x nvarchar(max) = (SELECT TOP (1) CAST(t.target_data AS nvarchar(max))
  FROM sys.dm_xe_%[1]ssessions s JOIN sys.dm_xe_%[1]ssession_targets t ON t.event_session_address = s.address
 WHERE s.name = @p1 AND t.target_name = N'ring_buffer');
DECLARE @n bigint = ISNULL(DATALENGTH(@x) / 2, 0);
SELECT CAST(SUBSTRING(@x, p.i * 16000 + 1, 16000) AS varbinary(max)) AS piece
  FROM (SELECT TOP (CAST((@n + 15999) / 16000 AS int)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
          FROM sys.all_columns a CROSS JOIN sys.all_columns b) p
 ORDER BY p.i`

// xeFileSQL reads at most @p2 events of an event file set past a block: %[1]s is the list of event names whose XML
// is wanted (the others come back without it and only move the cursor), %[2]s the starting point (NULL, NULL or
// @p3, @p4). sys.fn_xe_file_target_read_file skips every event up to and including the block at the offset given.
const xeFileSQL = `SELECT TOP (@p2) CAST(object_name AS nvarchar(128)) AS object_name, CAST(file_name AS nvarchar(4000)) AS file_name,
  CAST(file_offset AS bigint) AS file_offset,
  CASE WHEN object_name IN (%[1]s) THEN CAST(event_data AS nvarchar(max)) END AS event_data
FROM sys.fn_xe_file_target_read_file(@p1, NULL, %[2]s)`

const xeThresholdSQL = `SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'blocked process threshold (s)'`

// xeScopeWords are the scope words of the catalog views and the DMVs for an instance's kind.
func xeScopeWords(k Kind) (catalog, dmv string) {
	if k == KindAzureDB {
		return "database", "database_"
	}
	return "server", ""
}

func xeListTargets(ctx context.Context, conn *sql.Conn, info Info) ([]xeTarget, error) {
	cat, dmv := xeScopeWords(info.Kind)
	rs, err := conn.QueryContext(ctx, fmt.Sprintf(xeSessionsSQL, cat, dmv))
	if err != nil {
		return nil, fmt.Errorf("the event sessions: %w", err)
	}
	defer func() { _ = rs.Close() }()
	var out []xeTarget
	for rs.Next() {
		var name string
		var running int
		var target, data sql.NullString
		var mem, fsize, de, db sql.NullInt64
		if err := rs.Scan(&name, &running, &target, &mem, &fsize, &de, &db, &data); err != nil {
			return nil, fmt.Errorf("the event sessions: %w", err)
		}
		out = append(out, xeTarget{session: name, running: running == 1, target: target.String, maxMemory: mem.Int64,
			fileSizeMB: fsize.Int64, dropEvents: de.Int64, dropBufs: db.Int64, targetData: data.String})
	}
	return out, rs.Err()
}

// xeSession is one defined session with its targets.
type xeSession struct {
	name    string
	running bool
	targets map[string]xeTarget
}

func xeGroup(targets []xeTarget) map[string]*xeSession {
	out := map[string]*xeSession{}
	for _, t := range targets {
		s := out[t.session]
		if s == nil {
			s = &xeSession{name: t.session, running: t.running, targets: map[string]xeTarget{}}
			out[t.session] = s
		}
		if t.target != "" {
			s.targets[t.target] = t
		}
	}
	return out
}

// xePick chooses the session of one capture among the defined ones: a name pgvigil_<install id>_<capture>; a running
// one before a stopped one, then by name (two installs watching one server each read the first).
func xePick(sessions map[string]*xeSession, capture string) *xeSession {
	var names []string
	for n := range sessions {
		if strings.HasPrefix(n, "pgvigil_") && strings.HasSuffix(n, "_"+capture) && len(n) > len("pgvigil_")+len(capture)+1 {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	var pick *xeSession
	for _, n := range names {
		if s := sessions[n]; pick == nil || (s.running && !pick.running) {
			pick = s
		}
	}
	return pick
}

// xeStateOf is the three states of a capture: a session defined but not started is its own state, not "missing".
func xeStateOf(s *xeSession) string {
	switch {
	case s == nil:
		return "not installed"
	case s.running:
		return "running"
	}
	return "stopped"
}

// xeFilePattern turns the file an event_file target writes now (.../name_0_133...xel) into the pattern of its whole
// set (.../name*.xel).
func xeFilePattern(current string) string {
	i := strings.LastIndex(current, "_0_")
	if i < 0 || !strings.HasSuffix(strings.ToLower(current), ".xel") {
		return ""
	}
	return current[:i] + "*.xel"
}

func sqlNameList(names []string) string {
	q := make([]string, len(names))
	for i, n := range names {
		q[i] = "N'" + strings.ReplaceAll(n, "'", "''") + "'"
	}
	return strings.Join(q, ", ")
}

// xeRun is one run's state.
type xeRun struct {
	ctx    context.Context
	conn   *sql.Conn
	info   Info
	opt    BatchOptions
	cursor CursorFunc
	emit   EmitFunc
	now    time.Time
}

// RunBatches reads every capture that is there and says "not installed" or "stopped" for the rest. A source that
// fails is a collector_error row (the run is partial) and the other sources are still read.
func (xeCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	targets, err := xeListTargets(ctx, conn, info)
	if err != nil {
		return err
	}
	sessions := xeGroup(targets)
	r := &xeRun{ctx: ctx, conn: conn, info: info, opt: opt, cursor: cursor, emit: emit, now: time.Now()}
	var tail []collect.Row // state rows and source errors: one last import
	fail := func(source string, err error) {
		tail = append(tail, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
	}
	for _, capture := range xeCaptures {
		s := xePick(sessions, capture)
		state := collect.Row{"kind": "state", "capture": capture, "state": xeStateOf(s), "source": "product"}
		if capture == xeBlocked && info.Kind != KindAzureDB {
			var th sql.NullInt64
			if err := conn.QueryRowContext(ctx, xeThresholdSQL).Scan(&th); err == nil && th.Valid {
				state["threshold_s"] = th.Int64
			}
		}
		if s != nil {
			state["session_name"] = s.name
		}
		if s != nil && s.running {
			if err := r.readSession(s, "product", xeCaptureEvents[capture], state); err != nil {
				fail(s.name, err)
			}
		} else if capture == xeDeadlocks {
			// no deadlock session of the product: system_health's own deadlock reports, read and never touched
			if sh := sessions["system_health"]; sh != nil && sh.running {
				state["source"], state["note"] = "system_health", "no running deadlock session of pgvigil: the deadlock reports are system_health's"
				side := collect.Row{}
				if err := r.readSession(sh, "system_health", []string{"xml_deadlock_report"}, side); err != nil {
					fail("system_health", err)
				}
				state["new_events"] = side["new_events"]
				if n, ok := side["note"].(string); ok && n != "" {
					state["note"] = fmt.Sprintf("%v; %s", state["note"], n)
				}
			}
		}
		tail = append(tail, state)
	}
	if info.HADREnabled && info.Kind != KindAzureDB {
		s := sessions["AlwaysOn_health"]
		state := collect.Row{"kind": "state", "capture": xeAG, "state": xeStateOf(s), "source": "AlwaysOn_health", "session_name": "AlwaysOn_health"}
		if s != nil && s.running {
			if err := r.readSession(s, "AlwaysOn_health", xeAGEvents, state); err != nil {
				fail("AlwaysOn_health", err)
			}
		}
		tail = append(tail, state)
	}
	return emit(tail)
}

// readSession reads one running session's target past its cursor and fills the capture's state row.
func (r *xeRun) readSession(s *xeSession, source string, events []string, state collect.Row) error {
	if time.Now().After(r.opt.Deadline) {
		// nothing new is started this late: the cursor waits for the next run
		state["note"] = "the run's time was up before " + s.name + " was read: the next run reads it"
		return nil
	}
	c := xeContext{source: source, session: s.name, queryText: r.opt.QueryText}
	if t, ok := s.targets["event_counter"]; ok && t.targetData != "" {
		var ct xeCounterTarget
		if err := xml.Unmarshal([]byte(t.targetData), &ct); err == nil {
			var n int64
			for _, p := range ct.Packages {
				for _, e := range p.Events {
					n += e.Count
				}
			}
			state["counter"] = n
		}
	}
	if t, ok := s.targets["event_file"]; ok {
		state["target"], state["buffer_kb"] = "event_file", nilIfZero(t.fileSizeMB*1024)
		state["dropped_events"] = t.dropEvents
		var ft xeFileTarget
		if err := xml.Unmarshal([]byte(t.targetData), &ft); err != nil || ft.File.Name == "" {
			return fmt.Errorf("the event file target of %s names no file", s.name)
		}
		state["dropped_buffers"] = t.dropBufs + ft.Buffers.Dropped
		pattern := xeFilePattern(ft.File.Name)
		if pattern == "" {
			return fmt.Errorf("the event file of %s has an unexpected name: %s", s.name, ft.File.Name)
		}
		// a session of the server's own writes mostly events the reader does not store: they come back without their
		// XML and only move the cursor, so a batch of them may be larger
		top := xeBatchEvents
		if source != "product" {
			top *= 20
		}
		return r.readFile(s.name, pattern, events, top, c, state)
	}
	if t, ok := s.targets["ring_buffer"]; ok {
		state["target"], state["buffer_kb"] = "ring_buffer", nilIfZero(t.maxMemory)
		state["dropped_buffers"] = t.dropBufs
		return r.readRing(s.name, t, events, c, state)
	}
	return fmt.Errorf("%s has neither a ring_buffer nor an event_file target", s.name)
}

func nilIfZero(n int64) any {
	if n == 0 {
		return nil
	}
	return n
}

// shred parses one event into its row, or counts it: unknown (no parser for its name) or old.
func (r *xeRun) shred(e *xeEvent, wanted map[string]bool, c xeContext, keys *xeKeyer, unknown, old *int64) collect.Row {
	key := keys.key(e) // every event takes its place in the block's count, stored or not
	p, ok := xeParsers[e.Name]
	if !ok || !wanted[e.Name] {
		*unknown++
		return nil
	}
	if t, ok := e.at(); ok && r.now.Sub(t) > xeMaxAge {
		*old++
		return nil
	}
	row := p(e, c)
	if row == nil {
		return nil
	}
	if _, own := row["event_key"]; !own { // a deadlock is keyed by its graph alone (deadlockKey)
		row["event_key"] = key
	}
	return row
}

func nameSet(names []string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

// readRing reads one ring buffer whole and emits the events past the cursor in batches, each with its cursor.
func (r *xeRun) readRing(source string, t xeTarget, events []string, c xeContext, state collect.Row) error {
	cur, err := r.cursor(r.ctx, source)
	if err != nil {
		return err
	}
	_, dmv := xeScopeWords(r.info.Kind)
	rs, err := r.conn.QueryContext(r.ctx, fmt.Sprintf(xeRingSQL, dmv), source)
	if err != nil {
		return fmt.Errorf("the ring buffer of %s: %w", source, err)
	}
	var raw []byte
	for rs.Next() {
		var piece []byte
		if err := rs.Scan(&piece); err != nil {
			_ = rs.Close()
			return fmt.Errorf("the ring buffer of %s: %w", source, err)
		}
		raw = append(raw, piece...)
	}
	if err := rs.Err(); err != nil {
		_ = rs.Close()
		return fmt.Errorf("the ring buffer of %s: %w", source, err)
	}
	_ = rs.Close()
	ring, err := parseRing(decodeUTF16LE(raw))
	if err != nil {
		return fmt.Errorf("%s: %w", source, err)
	}
	state["buffer_used_kb"], state["event_count"], state["total_processed"] = ring.MemoryUsed/1024, ring.EventCount, ring.TotalProcessed
	state["dropped_events"], state["truncated"] = t.dropEvents+ring.DroppedCount, ring.Truncated != 0

	// the events past the cursor, oldest first. An event's place is its time and its sequence; a session that does
	// not collect the sequence (not the product's) gets the event's count among those of the same time.
	type item struct {
		e   *xeEvent
		at  time.Time
		seq int64
	}
	var items []item
	sameAt := map[string]int64{}
	for i := range ring.Events {
		e := &ring.Events[i]
		at, ok := e.at()
		if !ok {
			continue
		}
		seq := e.seq()
		if seq == 0 {
			sameAt[e.Timestamp]++
			seq = sameAt[e.Timestamp]
		}
		if cur.Found && (at.Before(cur.LastEventAt) || (at.Equal(cur.LastEventAt) && seq <= cur.LastSeq)) {
			continue
		}
		items = append(items, item{e, at, seq})
	}
	sort.SliceStable(items, func(i, j int) bool {
		if !items[i].at.Equal(items[j].at) {
			return items[i].at.Before(items[j].at)
		}
		return items[i].seq < items[j].seq
	})
	state["new_events"] = len(items)
	wanted := nameSet(events)
	var keys xeKeyer
	keys.reset()
	var unknown, old int64
	for start := 0; start < len(items); start += xeBatchEvents {
		end := min(start+xeBatchEvents, len(items))
		batch := make([]collect.Row, 0, end-start+1)
		for _, it := range items[start:end] {
			if row := r.shred(it.e, wanted, c, &keys, &unknown, &old); row != nil {
				batch = append(batch, row)
			}
		}
		last := items[end-1]
		batch = append(batch, Cursor{LastEventAt: last.at, LastSeq: last.seq}.Row(source))
		if err := r.emit(batch); err != nil {
			return fmt.Errorf("import a batch of %s: %w", source, err)
		}
	}
	state["unknown_events"] = unknown
	return nil
}

// xeFileRow is one row of sys.fn_xe_file_target_read_file.
type xeFileRow struct {
	name, file string
	offset     int64
	data       sql.NullString
}

func (r *xeRun) queryFile(pattern string, events []string, top int, cur Cursor) ([]xeFileRow, error) {
	start, args := "NULL, NULL", []any{pattern, top}
	if cur.Found && cur.FileName != "" {
		start, args = "@p3, @p4", append(args, cur.FileName, cur.FileOffset)
	}
	rs, err := r.conn.QueryContext(r.ctx, fmt.Sprintf(xeFileSQL, sqlNameList(events), start), args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rs.Close() }()
	var out []xeFileRow
	for rs.Next() {
		var x xeFileRow
		if err := rs.Scan(&x.name, &x.file, &x.offset, &x.data); err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rs.Err()
}

// readFile reads an event file set past its cursor in batches of whole blocks. A block is one buffer the session
// wrote at once and the function's starting point is a block, so a batch that ended inside a block would lose the
// block's rest: a batch ends on a block's edge, and the cursor is the last whole block read.
func (r *xeRun) readFile(source, pattern string, events []string, batchTop int, c xeContext, state collect.Row) error {
	cur, err := r.cursor(r.ctx, source)
	if err != nil {
		return err
	}
	wanted := nameSet(events)
	var total, taken, unknown, old int64
	var notes []string
	// floor: after the cursor's file is gone the set is read from its oldest file, and events at or before the
	// newest event already stored are passed over by their time (the event's key keeps an equal time from doubling)
	var floor time.Time
	for {
		top := batchTop
		var rows []xeFileRow
		more := false
		for {
			rows, err = r.queryFile(pattern, events, top+1, cur)
			if err != nil && cur.Found && cur.FileName != "" && r.ctx.Err() == nil {
				// the file the cursor names was rolled away (or the session was made again elsewhere)
				notes = append(notes, fmt.Sprintf("the cursor's file %s could not be read (%v): the files were read again from the oldest, by event time", cur.FileName, err))
				floor = cur.LastEventAt
				cur = Cursor{LastEventAt: cur.LastEventAt}
				continue
			}
			if err != nil {
				return fmt.Errorf("the event file of %s: %w", source, err)
			}
			if len(rows) <= top {
				break // everything past the cursor: every block is whole
			}
			// more is waiting: cut back to the last whole block
			last := rows[len(rows)-1]
			cut := len(rows) - 1
			for cut > 0 && rows[cut-1].file == last.file && rows[cut-1].offset == last.offset {
				cut--
			}
			if cut > 0 {
				rows, more = rows[:cut], true
				break
			}
			if top >= xeBlockCap {
				return fmt.Errorf("the event file of %s: one block holds more than %d events", source, xeBlockCap)
			}
			top *= 4 // one block larger than the batch: read on until it is whole
		}
		if len(rows) == 0 {
			break
		}
		batch := make([]collect.Row, 0, len(rows)+1)
		var keys xeKeyer
		blockFile, blockOff := "", int64(-1)
		newest := cur.LastEventAt
		for i := range rows {
			x := &rows[i]
			if x.file != blockFile || x.offset != blockOff {
				blockFile, blockOff = x.file, x.offset
				keys.reset()
			}
			total++
			if !x.data.Valid {
				unknown++ // an event the reader does not store: it only moves the cursor
				continue
			}
			taken++
			e, err := parseEvent(x.data.String)
			if err != nil {
				unknown++
				continue
			}
			at, ok := e.at()
			if ok && at.After(newest) {
				newest = at
			}
			row := r.shred(&e, wanted, c, &keys, &unknown, &old)
			if row == nil || (ok && !floor.IsZero() && at.Before(floor)) {
				continue
			}
			batch = append(batch, row)
		}
		last := rows[len(rows)-1]
		cur = Cursor{Found: true, FileName: last.file, FileOffset: last.offset, LastEventAt: newest}
		batch = append(batch, cur.Row(source))
		if err := r.emit(batch); err != nil {
			return fmt.Errorf("import a batch of %s: %w", source, err)
		}
		if !more {
			break
		}
		if time.Now().After(r.opt.Deadline) {
			notes = append(notes, "the run's time was up before the file was read to its end: the next run goes on from the cursor")
			break
		}
	}
	// a session of the server's own carries mostly events the reader does not want: its count is the wanted ones
	state["new_events"] = taken
	if c.source == "product" {
		state["new_events"], state["unknown_events"] = total, unknown
	}
	if old > 0 {
		notes = append(notes, fmt.Sprintf("%d event(s) older than %d days were not stored", old, int(xeMaxAge.Hours()/24)))
	}
	if len(notes) > 0 {
		if prev, ok := state["note"].(string); ok && prev != "" {
			notes = append([]string{prev}, notes...)
		}
		state["note"] = strings.Join(notes, "; ")
	}
	return nil
}
