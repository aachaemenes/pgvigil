package mssql

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_audit: SQL Server Audit, read and never changed.
//
// pgvigil's login never creates, alters, starts, stops or drops an audit or an audit specification. The collection
// reads two things:
//
//   - the audit health: every server audit with its state, target, on-failure action, queue delay, file and size,
//     and the server and database audit specifications with their actions (sys.server_audits, sys.server_file_audits,
//     sys.dm_server_audit_status, sys.server_audit_specifications and each database's
//     sys.database_audit_specifications);
//   - the audit events of every audit that writes to a FILE, forward from a cursor (sys.fn_get_audit_file; on Amazon
//     RDS msdb.dbo.rds_fn_get_audit_file). An audit that writes to the Windows Application or Security log is named
//     as not readable through T-SQL; a URL or external-monitor target is named as not read.
//
// The rights, from Microsoft's pages (read 2026-11-11) and measured on SQL Server 2022:
//
//   - the audits and their specifications: VIEW ANY DEFINITION (or ALTER ANY SERVER AUDIT; on SQL Server 2022 the
//     narrower VIEW ANY SECURITY DEFINITION is enough). Without it the catalog views list nothing and raise no error.
//   - which audit is started: VIEW SERVER STATE (on SQL Server 2022 the narrower VIEW SERVER SECURITY STATE).
//   - the events: sys.fn_get_audit_file asks for CONTROL SERVER up to SQL Server 2019 and for VIEW SERVER SECURITY
//     AUDIT from SQL Server 2022. A login without it reads the health only: that is said in every audit's row
//     (read_state 'no right'), it is not an error and the run is not partial.
//
// What is kept: failed sign-ins and the changes an auditor asks about (role membership, permissions, logins and
// passwords, DDL, the audit itself) are rows; everything else (reads, writes, executions, sign-ins, batches) is
// counted per hour, login, database, object and action. Statement text is stored for the rows only on the
// instance's opt-in (audit_text: true) and then under its query_text policy; a failed sign-in's reason is the
// server's own message and is always kept.
type auditCollector struct{}

func init() { Register(auditCollector{}) }

func (auditCollector) Name() string                   { return Prefix + "audit" }
func (auditCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

// Timeout: a pass over every database's specifications and the audit files past their cursors; a backlog the run's
// time does not finish goes on from the cursor at the next run.
func (auditCollector) Timeout() time.Duration { return 2 * time.Minute }

func (auditCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "Azure SQL Database keeps its audit in a storage container, a Log Analytics workspace or an event hub, and T-SQL names none of them: not read (docs/sqlserver-audit.md)"
	case !info.ViewAnyDefinition && !info.ViewServerState:
		return false, "the login has neither VIEW ANY DEFINITION (the audits and their specifications) nor VIEW SERVER STATE (which audit is started)"
	}
	return true, ""
}

// Run is not the collection's path: RunOnce sends a BatchCollector to RunBatches.
func (auditCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_audit reads from a cursor: it runs through the batch path (RunBatches)")
}

// auditBatchRows is the most audit records one batch reads past the cursor; PGVIGIL_MSSQL_AUDIT_BATCH lowers it for
// the proof.
var auditBatchRows = envInt("PGVIGIL_MSSQL_AUDIT_BATCH", 5000)

// auditRowCap is the most events of one audit one run stores as rows; the rest of that run's are counted per hour
// like the routine ones (a sign-in storm must not fill the repository). PGVIGIL_MSSQL_AUDIT_ROWCAP for the proof.
var auditRowCap = envInt("PGVIGIL_MSSQL_AUDIT_ROWCAP", 20000)

// auditBufferCap is the most records the reader takes to finish one buffer of an audit file.
const auditBufferCap = 256000

// auditMaxDatabases is the most databases one run asks for their audit specification.
const auditMaxDatabases = 1000

// auditStatementMax is the most characters of one statement the reader keeps (a record over 4,000 characters is
// written as several rows; they are joined up to this length).
const auditStatementMax = 16000

// ---- the rights

// auditRightsSQL asks what the login may read. An unknown permission name (VIEW SERVER SECURITY AUDIT before SQL
// Server 2022) and an object that is not there (the RDS reader off RDS) answer NULL, read as 0.
const auditRightsSQL = `SELECT
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'CONTROL SERVER'), 0) AS int) AS control_server,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY AUDIT'), 0) AS int) AS view_security_audit,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION'), 0) AS int) AS view_any_definition,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY SECURITY DEFINITION'), 0) AS int) AS view_any_security_definition,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY SERVER AUDIT'), 0) AS int) AS alter_any_server_audit,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0) AS int) AS view_server_state,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY STATE'), 0) AS int) AS view_server_security_state,
  CAST(ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo.rds_fn_get_audit_file', 'OBJECT', 'SELECT'), 0) AS int) AS rds_reader`

// auditRights is what the login may read of the audit.
type auditRights struct {
	defs        bool   // the audits and their specifications are listed
	dbDefs      bool   // every database's specification is listed (a server-level right, not a database's own)
	state       bool   // sys.dm_server_audit_status answers
	events      bool   // the audit files may be read
	eventsRight string // the right the server asks for the events
}

// auditRightsOf judges the rights row for this server's kind and version.
func auditRightsOf(info Info, row collect.Row) auditRights {
	has := func(k string) bool { n, _ := asInt(row[k]); return n == 1 }
	r := auditRights{
		defs:   has("control_server") || has("view_any_definition") || has("view_any_security_definition") || has("alter_any_server_audit"),
		dbDefs: has("control_server") || has("view_any_definition") || has("view_any_security_definition"),
		state:  has("control_server") || has("view_server_state") || has("view_server_security_state"),
	}
	switch {
	case info.Kind == KindRDS:
		r.eventsRight, r.events = "SELECT on msdb.dbo.rds_fn_get_audit_file", has("rds_reader")
	case atLeast(info, 16):
		r.eventsRight, r.events = "VIEW SERVER SECURITY AUDIT", has("view_security_audit") || has("control_server")
	default:
		r.eventsRight, r.events = "CONTROL SERVER", has("control_server")
	}
	return r
}

// ---- the health

// auditDefsSQL: every server audit; the file columns are NULL for an audit that does not write to a file. The two
// dates are UTC (Microsoft's page of sys.server_audits).
const auditDefsSQL = `SELECT CAST(a.audit_id AS int) AS audit_id, CAST(a.name AS nvarchar(128)) AS name,
  CAST(a.audit_guid AS nvarchar(36)) AS audit_guid, CAST(a.type AS nvarchar(2)) AS type,
  CAST(a.type_desc AS nvarchar(60)) AS type_desc, CAST(a.on_failure_desc AS nvarchar(60)) AS on_failure,
  CAST(a.queue_delay AS bigint) AS queue_delay_ms, CAST(a.is_state_enabled AS int) AS is_enabled,
  CAST(a.predicate AS nvarchar(3000)) AS predicate,
  CONVERT(varchar(33), a.create_date, 126) + 'Z' AS created_at, CONVERT(varchar(33), a.modify_date, 126) + 'Z' AS modified_at,
  CAST(f.max_file_size AS bigint) AS max_file_size_mb, CAST(f.max_rollover_files AS bigint) AS max_rollover_files,
  CAST(f.max_files AS bigint) AS max_files, CAST(f.reserve_disk_space AS int) AS reserve_disk_space,
  CAST(f.log_file_path AS nvarchar(260)) AS log_file_path, CAST(f.log_file_name AS nvarchar(260)) AS log_file_name
FROM sys.server_audits a
LEFT JOIN sys.server_file_audits f ON f.audit_id = a.audit_id
ORDER BY a.name`

// auditStatusSQL: the audits the server runs. Measured on SQL Server 2022: an audit that is switched off has no row
// here at all; sys.server_audits' is_state_enabled is what says so.
const auditStatusSQL = `SELECT CAST(s.audit_id AS int) AS audit_id, CAST(s.name AS nvarchar(128)) AS name,
  CAST(s.status_desc AS nvarchar(256)) AS status, CONVERT(varchar(33), s.status_time, 126) + 'Z' AS status_at,
  CAST(s.audit_file_path AS nvarchar(260)) AS current_file, CAST(s.audit_file_size AS bigint) AS file_size_bytes
FROM sys.dm_server_audit_status s`

// auditServerSpecsSQL: the server audit specifications, one row per action (a specification without one: one row).
const auditServerSpecsSQL = `SELECT CAST(s.name AS nvarchar(128)) AS name, CAST(s.audit_guid AS nvarchar(36)) AS audit_guid,
  CAST(s.is_state_enabled AS int) AS is_enabled,
  CONVERT(varchar(33), s.create_date, 126) AS created_local, CONVERT(varchar(33), s.modify_date, 126) AS modified_local,
  CAST(d.audit_action_name AS nvarchar(128)) AS action_name, CAST(d.class_desc AS nvarchar(60)) AS class_desc,
  CAST(NULL AS nvarchar(300)) AS object_name, CAST(NULL AS nvarchar(128)) AS principal_name,
  CAST(d.audited_result AS nvarchar(60)) AS audited_result, CAST(d.is_group AS int) AS is_group
FROM sys.server_audit_specifications s
LEFT JOIN sys.server_audit_specification_details d ON d.server_specification_id = s.server_specification_id
ORDER BY s.name, d.audit_action_name`

// auditDatabaseSpecsSQL runs inside one database: its audit specification(s), one row per action, with the audited
// object (a schema, or schema.object) and principal by name.
const auditDatabaseSpecsSQL = `SELECT CAST(s.name AS nvarchar(128)) AS name, CAST(s.audit_guid AS nvarchar(36)) AS audit_guid,
  CAST(s.is_state_enabled AS int) AS is_enabled,
  CONVERT(varchar(33), s.create_date, 126) AS created_local, CONVERT(varchar(33), s.modify_date, 126) AS modified_local,
  CAST(d.audit_action_name AS nvarchar(128)) AS action_name, CAST(d.class_desc AS nvarchar(60)) AS class_desc,
  CAST(CASE WHEN d.class_desc = N'SCHEMA' THEN SCHEMA_NAME(d.major_id)
            WHEN d.major_id > 0 THEN OBJECT_SCHEMA_NAME(d.major_id) + N'.' + OBJECT_NAME(d.major_id) END AS nvarchar(300)) AS object_name,
  CAST(p.name AS nvarchar(128)) AS principal_name,
  CAST(d.audited_result AS nvarchar(60)) AS audited_result, CAST(d.is_group AS int) AS is_group
FROM sys.database_audit_specifications s
LEFT JOIN sys.database_audit_specification_details d ON d.database_specification_id = s.database_specification_id
LEFT JOIN sys.database_principals p ON p.principal_id = d.audited_principal_id
ORDER BY s.name, d.audit_action_name`

// auditDatabasesSQL: the online databases but tempdb, with the name quoted by the server and whether the login can
// enter.
const auditDatabasesSQL = `SELECT CAST(d.name AS nvarchar(128)) AS database_name, QUOTENAME(d.name) AS quoted_name,
  CAST(ISNULL(HAS_DBACCESS(d.name), 0) AS int) AS can_enter
FROM sys.databases d
WHERE d.state = 0 AND d.database_id <> 2
ORDER BY d.database_id`

// auditDef is one server audit as the catalog and the state view describe it.
type auditDef struct {
	id        int64
	name      string
	guid      string
	typ       string // FL | AL | SL | UL | EM, empty when the catalog was not readable
	enabled   *bool  // is_state_enabled; nil when the catalog was not readable
	status    string // sys.dm_server_audit_status' status_desc; empty when the audit has no row there
	logPath   string
	logName   string
	current   string // the file the audit writes now
	row       collect.Row
	readState string
	readNote  string
}

// auditTarget names an audit's target in words.
func auditTarget(typ, typeDesc string) string {
	switch strings.ToUpper(strings.TrimSpace(typ)) {
	case "FL":
		return "file"
	case "AL":
		return "application log"
	case "SL":
		return "security log"
	case "UL":
		return "url"
	case "EM":
		return "external monitor"
	case "":
		return ""
	}
	return strings.ToLower(strings.TrimSpace(typeDesc))
}

// auditState is an audit's state in one word. enabled is the catalog's is_state_enabled (nil: not readable), status
// the state view's status_desc (empty: no row), stateRead whether the state view was readable.
func auditState(enabled *bool, status string, stateRead bool) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case "STARTED":
		return "started"
	case "RUNTIME_FAIL", "TARGET_CREATION_FAILED":
		return "failed"
	case "SHUTTING_DOWN":
		return "shutting down"
	case "NOT_STARTED":
		return "stopped"
	}
	switch {
	case enabled == nil:
		return "unknown"
	case !*enabled:
		return "stopped"
	case stateRead:
		// switched on in the catalog and not among the audits the server runs
		return "failed"
	}
	return "enabled"
}

// auditPattern is the file pattern of an audit's whole file set: its folder, its base name (name_GUID) and one
// wildcard. SQL Server names each file <base>_<n>_<time>.sqlaudit.
func auditPattern(logPath, logName string) string {
	logPath, logName = strings.TrimSpace(logPath), strings.TrimSpace(logName)
	if logPath == "" || logName == "" {
		return ""
	}
	if !strings.HasSuffix(logPath, "/") && !strings.HasSuffix(logPath, `\`) {
		if strings.Contains(logPath, `\`) {
			logPath += `\`
		} else {
			logPath += "/"
		}
	}
	base := logName
	if i := strings.LastIndex(strings.ToLower(base), ".sqlaudit"); i >= 0 {
		base = base[:i]
	}
	return logPath + base + "*.sqlaudit"
}

// ---- the events' classification

// The categories of the events kept as rows, and of the ones counted.
const (
	auditFailedLogin = "failed sign-in"
	auditRole        = "role"
	auditPermission  = "permission"
	auditPrincipal   = "principal"
	auditDDL         = "ddl"
	auditChange      = "audit"
)

// auditKeptActions are the action ids whose events are rows, with their category. CR, AL, DR and TRO are a DDL
// change, or a change of the audit itself when their class is an audit or an audit specification (auditCategory).
var auditKeptActions = map[string]string{
	"LGIF": auditFailedLogin, "DBAF": auditFailedLogin,
	"APRL": auditRole, "DPRL": auditRole,
	"G": auditPermission, "GWG": auditPermission, "D": auditPermission, "DWC": auditPermission, "R": auditPermission,
	"RWG": auditPermission, "RWC": auditPermission, "TO": auditPermission,
	"PWC": auditPrincipal, "PWCS": auditPrincipal, "PWR": auditPrincipal, "PWRS": auditPrincipal, "PWU": auditPrincipal,
	"PWMC": auditPrincipal, "PWPL": auditPrincipal, "PWEX": auditPrincipal, "CSPP": auditPrincipal, "LGDA": auditPrincipal,
	"LGEA": auditPrincipal, "LGDB": auditPrincipal, "LGLG": auditPrincipal, "LGNM": auditPrincipal, "CCLG": auditPrincipal,
	"CMLG": auditPrincipal, "NMLG": auditPrincipal, "USAF": auditPrincipal, "USLG": auditPrincipal, "USTC": auditPrincipal,
	"CR": auditDDL, "AL": auditDDL, "DR": auditDDL, "TRO": auditDDL,
	"AUSC": auditChange, "AUSF": auditChange, "C2ON": auditChange, "C2OF": auditChange, "TASA": auditChange, "TASP": auditChange,
}

// auditCountedActions name the category of the routine actions; any other action is counted as 'other'.
var auditCountedActions = map[string]string{
	"SL": "read", "RC": "read", "RF": "read",
	"IN": "write", "UP": "write", "DL": "write",
	"EX":   "execute",
	"LGIS": "sign-in", "DBAS": "sign-in", "AUTH": "sign-in",
	"LGO": "sign-out", "DBL": "sign-out",
	"BCM": "batch", "BST": "batch", "RCM": "batch", "RST": "batch", "SBC": "batch", "SRC": "batch",
	"TXBG": "transaction", "TXCM": "transaction", "TXRB": "transaction", "UNDO": "transaction",
}

// auditCategory classifies one record by its action id and class type (both as the server wrote them, padded or
// not): the category, and whether the event is kept as a row. DDL inside tempdb and on statistics is routine (a
// temporary table, an automatic statistic) and is counted.
func auditCategory(actionID, classType, database string) (category string, keep bool) {
	a, c := strings.ToUpper(strings.TrimSpace(actionID)), strings.ToUpper(strings.TrimSpace(classType))
	if cat, ok := auditKeptActions[a]; ok {
		if cat == auditDDL {
			switch c {
			case "A", "SA", "DA", "DU":
				return auditChange, true
			case "ST":
				return auditDDL, false
			}
			if strings.EqualFold(strings.TrimSpace(database), "tempdb") {
				return auditDDL, false
			}
		}
		return cat, true
	}
	if cat, ok := auditCountedActions[a]; ok {
		return cat, false
	}
	if strings.HasPrefix(a, "TR") && len(a) == 4 && (strings.HasSuffix(a, "C") || strings.HasSuffix(a, "S")) {
		return "transaction", false // the TRANSACTION ... STARTING / COMPLETED pairs
	}
	return "other", false
}

// auditTextActions is the SQL list of the kept action ids, as the reader's statement names them: the text of a
// counted record is never taken off the server.
var auditTextActions = func() string {
	ids := make([]string, 0, len(auditKeptActions))
	for a := range auditKeptActions {
		ids = append(ids, a)
	}
	sort.Strings(ids)
	return sqlNameList(ids)
}()

// auditActionNames are the server's own names of the actions (sys.dm_audit_actions on SQL Server 2022); an id that
// is not here is shown as it is.
var auditActionNames = map[string]string{
	"LGIF": "LOGIN FAILED", "DBAF": "DATABASE AUTHENTICATION FAILED", "LGIS": "LOGIN SUCCEEDED", "DBAS": "DATABASE AUTHENTICATION SUCCEEDED",
	"LGO": "LOGOUT", "DBL": "DATABASE LOGOUT", "AUTH": "AUTHENTICATE",
	"APRL": "ADD MEMBER", "DPRL": "DROP MEMBER",
	"G": "GRANT", "GWG": "GRANT WITH GRANT", "D": "DENY", "DWC": "DENY WITH CASCADE", "R": "REVOKE", "RWG": "REVOKE WITH GRANT",
	"RWC": "REVOKE WITH CASCADE", "TO": "TAKE OWNERSHIP", "TRO": "TRANSFER",
	"PWC": "CHANGE PASSWORD", "PWCS": "CHANGE OWN PASSWORD", "PWR": "RESET PASSWORD", "PWRS": "RESET OWN PASSWORD",
	"PWU": "UNLOCK ACCOUNT", "PWMC": "MUST CHANGE PASSWORD", "PWPL": "PASSWORD POLICY", "PWEX": "PASSWORD EXPIRATION",
	"CSPP": "CHANGE SERVER PASSWORD POLICY", "LGDA": "DISABLE", "LGEA": "ENABLE", "LGDB": "CHANGE DEFAULT DATABASE",
	"LGLG": "CHANGE DEFAULT LANGUAGE", "LGNM": "NAME CHANGE", "CCLG": "CHANGE LOGIN CREDENTIAL", "CMLG": "CREDENTIAL MAP TO LOGIN",
	"NMLG": "NO CREDENTIAL MAP TO LOGIN", "USAF": "CHANGE USERS LOGIN AUTO", "USLG": "CHANGE USERS LOGIN", "USTC": "COPY PASSWORD",
	"CR": "CREATE", "AL": "ALTER", "DR": "DROP",
	"AUSC": "AUDIT SESSION CHANGED", "AUSF": "AUDIT SHUTDOWN ON FAILURE", "C2ON": "TRACE AUDIT C2ON", "C2OF": "TRACE AUDIT C2OFF",
	"TASA": "TRACE AUDIT START", "TASP": "TRACE AUDIT STOP",
	"SL": "SELECT", "IN": "INSERT", "UP": "UPDATE", "DL": "DELETE", "EX": "EXECUTE", "RC": "RECEIVE", "RF": "REFERENCES",
	"BCM": "BATCH COMPLETED", "BST": "BATCH STARTED", "RCM": "RPC COMPLETED", "RST": "RPC STARTED",
	"SBC": "SENSITIVE BATCH COMPLETED", "SRC": "SENSITIVE RPC COMPLETED",
	"TXBG": "TRANSACTION BEGIN", "TXCM": "TRANSACTION COMMIT", "TXRB": "TRANSACTION ROLLBACK", "UNDO": "STATEMENT ROLLBACK",
	"BA": "BACKUP", "BAL": "BACKUP LOG", "RS": "RESTORE", "DBCC": "DBCC", "IMP": "IMPERSONATE", "VSST": "VIEW SERVER STATE",
	"VDST": "VIEW DATABASE STATE", "ALSS": "ALTER SERVER STATE", "ALST": "ALTER SETTINGS", "ALRS": "ALTER RESOURCES",
	"ALCN": "ALTER CONNECTION", "ALTR": "ALTER TRACE", "SVSR": "SERVER STARTED", "SVSD": "SERVER SHUTDOWN", "SVPD": "SERVER PAUSED",
	"SVCN": "SERVER CONTINUE", "UDAU": "USER DEFINED AUDIT", "OP": "OPEN", "AS": "ACCESS", "CP": "CHECKPOINT", "SPLN": "SHOW PLAN",
	"ADBO": "BULK ADMIN", "DABO": "DATABASE BULK ADMIN", "XA": "EXTERNAL ACCESS ASSEMBLY", "XU": "UNSAFE ASSEMBLY",
}

// auditClassNames are the server's names of the class types the kept events carry most (sys.dm_audit_class_type_map);
// a type that is not here is shown as it is.
var auditClassNames = map[string]string{
	"A": "SERVER AUDIT", "SA": "SERVER AUDIT SPECIFICATION", "DA": "DATABASE AUDIT SPECIFICATION", "DU": "AUDIT",
	"SR": "SERVER", "DB": "DATABASE", "SC": "SCHEMA", "LX": "LOGIN", "SL": "SQL LOGIN", "WL": "WINDOWS LOGIN", "WG": "WINDOWS GROUP",
	"AL": "ASYMMETRIC KEY LOGIN", "CL": "CERTIFICATE LOGIN", "XL": "EXTERNAL LOGIN", "PL": "EXTERNAL GROUP LOGIN",
	"SG": "SERVER ROLE", "RL": "ROLE", "AR": "APPLICATION ROLE", "US": "USER", "SU": "SQL USER", "WU": "WINDOWS USER",
	"GU": "GROUP USER", "XU": "EXTERNAL USER", "PU": "EXTERNAL GROUP USER", "CU": "CERTIFICATE USER", "AU": "ASYMMETRIC KEY USER",
	"U": "TABLE", "V": "VIEW", "P": "STORED PROCEDURE", "FN": "FUNCTION", "TF": "FUNCTION", "IF": "FUNCTION", "IS": "FUNCTION",
	"TR": "TRIGGER", "DT": "DATABASE TRIGGER", "T": "SERVER TRIGGER", "SN": "SYNONYM", "SO": "SEQUENCE", "TY": "TYPE",
	"IX": "INDEX", "ST": "STATISTICS", "EP": "ENDPOINT", "CD": "CREDENTIAL", "CR": "CERTIFICATE", "AK": "ASYMMETRIC KEY",
	"SK": "SYMMETRIC KEY", "MK": "MASTER KEY", "AG": "AVAILABILITY GROUP", "SE": "EVENT SESSION", "AS": "ASSEMBLY",
	"CO": "SERVER CONFIG", "OB": "OBJECT", "X": "EXTENDED PROCEDURE", "SP": "SECURITY POLICY",
}

func auditName(names map[string]string, code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if n, ok := names[code]; ok {
		return n
	}
	return code
}

// ---- the reader

// auditBaseColumns are the reader's columns every supported version has; the others (client_ip, application_name:
// SQL Server 2017; host_name later) are asked of the catalog and left out where they are not there.
var auditBaseColumns = []string{"event_time", "sequence_number", "action_id", "succeeded", "class_type", "session_id",
	"session_server_principal_name", "server_principal_name", "database_principal_name", "target_server_principal_name",
	"target_database_principal_name", "database_name", "schema_name", "object_name", "statement", "additional_information",
	"file_name", "audit_file_offset"}

// auditColumnsSQL lists the reader function's columns (%[1]s the catalog's database prefix, %[2]s the function).
const auditColumnsSQL = `SELECT CAST(c.name AS nvarchar(128)) AS name FROM %[1]ssys.all_columns c WHERE c.object_id = OBJECT_ID(N'%[2]s')`

// auditFileFmt reads at most @p2 records of an audit's file set, in the function's own order (file by file, buffer
// by buffer). %[1]s the reader function, %[2]s the optional columns, %[3]s the starting point (default, default or
// @p4, @p5: the function then starts at the first record of the buffer after that offset), %[4]s the action ids
// whose statement is taken when @p3 = 1. A failed sign-in's "statement" is the server's message, always taken.
const auditFileFmt = `SELECT TOP (@p2) CONVERT(varchar(33), event_time, 126) + 'Z' AS event_at,
  CAST(sequence_number AS int) AS seq, CAST(action_id AS varchar(4)) AS action_id, CAST(succeeded AS int) AS succeeded,
  CAST(class_type AS varchar(2)) AS class_type, CAST(session_id AS int) AS session_id,
  CAST(session_server_principal_name AS nvarchar(128)) AS session_login,
  CAST(server_principal_name AS nvarchar(128)) AS login_name, CAST(database_principal_name AS nvarchar(128)) AS database_user,
  CAST(target_server_principal_name AS nvarchar(128)) AS target_login,
  CAST(target_database_principal_name AS nvarchar(128)) AS target_user,
  CAST(database_name AS nvarchar(128)) AS database_name, CAST(schema_name AS nvarchar(128)) AS schema_name,
  CAST(object_name AS nvarchar(128)) AS object_name,
  CASE WHEN action_id IN ('LGIF', 'DBAF') OR (@p3 = 1 AND action_id IN (%[4]s)) THEN CAST(statement AS nvarchar(4000)) END AS statement,
  CASE WHEN action_id IN ('LGIF', 'DBAF', 'AUSC', 'AUSF') THEN CAST(additional_information AS nvarchar(4000)) END AS additional_information,
  CAST(file_name AS nvarchar(260)) AS file_name, CAST(audit_file_offset AS bigint) AS file_offset,
  %[2]s
FROM %[1]s(@p1, %[3]s)`

// auditReader is what reads one audit's files; the query is a field so that a test drives the loop with canned rows.
type auditReader struct {
	text     bool // the instance opted in to statement text
	deadline time.Time
	cursor   CursorFunc
	emit     EmitFunc
	// query returns at most top records of pattern past cur (cur.FileName empty: from the pattern's first record)
	query func(pattern string, top int, cur Cursor) ([]collect.Row, error)
	now   func() time.Time
}

// auditRead is what one audit's read found.
type auditRead struct {
	listed    int64 // events stored as rows
	counted   int64 // events counted per hour
	overCap   int64 // kept events counted because the run's row cap was reached
	lastEvent time.Time
	notes     []string
}

// auditSource is the cursor's name for one audit: its GUID outlives a rename, and a dropped and re-created audit is
// a new source.
func auditSource(guid string) string { return "audit:" + strings.ToUpper(strings.TrimSpace(guid)) }

// auditCursorGone says whether an error is the reader refusing the cursor's file and offset (33225: the file was
// rolled away or moved).
func auditCursorGone(err error) bool {
	var me mssqldb.Error
	if errors.As(err, &me) {
		return me.Number == 33225
	}
	return err != nil && strings.Contains(err.Error(), "do not represent a valid location within the audit file set")
}

// auditCut finds where a batch read with one record more than top ends: on the edge of the last whole buffer. more
// says records are left; grow says the first buffer alone is larger than the batch (read again with a larger top).
func auditCut(rows []collect.Row, top int) (cut int, more, grow bool) {
	if len(rows) <= top {
		return len(rows), false, false // everything past the cursor: every buffer is whole
	}
	last := rows[len(rows)-1]
	cut = len(rows) - 1
	for cut > 0 && sameBuffer(rows[cut-1], last) {
		cut--
	}
	if cut == 0 {
		return 0, true, true
	}
	return cut, true, false
}

func sameBuffer(a, b collect.Row) bool {
	ao, _ := asInt(a["file_offset"])
	bo, _ := asInt(b["file_offset"])
	return ao == bo && rowText(a, "file_name") == rowText(b, "file_name")
}

func rowText(r collect.Row, k string) string {
	s, _ := r[k].(string)
	return s
}

// baseName is a path's last element, for a Windows or a Linux path.
func baseName(p string) string {
	if i := strings.LastIndexAny(p, `/\`); i >= 0 {
		return p[i+1:]
	}
	return p
}

// auditKey is an event's key: the file's own name (not its folder: RDS moves a finished file), the buffer's offset
// and the record's place in the buffer. The same record read twice has the same key.
func auditKey(file string, offset int64, ordinal int) string {
	sum := sha256.Sum256([]byte(strings.ToLower(baseName(file)) + "|" + strconv.FormatInt(offset, 10) + "|" + strconv.Itoa(ordinal)))
	return hex.EncodeToString(sum[:16])
}

var (
	auditInfoError  = regexp.MustCompile(`<error>0x([0-9A-Fa-f]{1,8})</error>`)
	auditInfoState  = regexp.MustCompile(`<state>(-?[0-9]{1,9})</state>`)
	auditInfoAction = regexp.MustCompile(`<action>([^<]{1,200})</action>`)
)

// auditInfo takes what the reader stores out of a record's additional_information: a sign-in failure's error number
// and state, an audit session change's action. Nothing else of it is kept (a failed sign-in's carries a fragment of
// the password's hash).
func auditInfo(xml string) (errNumber, errState any, action string) {
	if m := auditInfoError.FindStringSubmatch(xml); m != nil {
		if n, err := strconv.ParseInt(m[1], 16, 64); err == nil {
			errNumber = n
		}
	}
	if m := auditInfoState.FindStringSubmatch(xml); m != nil {
		if n, err := strconv.ParseInt(m[1], 10, 64); err == nil {
			errState = n
		}
	}
	if m := auditInfoAction.FindStringSubmatch(xml); m != nil {
		action = strings.TrimSpace(m[1])
	}
	return errNumber, errState, action
}

func nilIfBlank(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

func cutRunes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// auditCountKey is one hourly count's key.
type auditCountKey struct {
	hour                                              time.Time
	category, action, login, database, schema, object string
	ok                                                bool
}

// auditBatch turns the records of whole buffers into a batch: the kept events as rows, the others as hourly counts.
// floor: records at or before it were read before (the cursor's file was gone) and are passed over. res carries the
// run's totals for this audit (the row cap counts across its batches).
func (rd *auditReader) auditBatch(a *auditDef, rows []collect.Row, floor time.Time, res *auditRead) []collect.Row {
	batch := make([]collect.Row, 0, 64)
	counts := map[auditCountKey]int64{}
	var prev collect.Row // the last kept event of this buffer, for a record written as several rows
	bufFile, bufOff, ordinal := "", int64(-1), 0
	for _, x := range rows {
		file := rowText(x, "file_name")
		off, _ := asInt(x["file_offset"])
		if file != bufFile || off != bufOff {
			bufFile, bufOff, ordinal, prev = file, off, 0, nil
		}
		if seq, _ := asInt(x["seq"]); seq > 1 {
			// the rest of a long record: its text joins the event it belongs to, and it is no event of its own
			if prev != nil && rd.text {
				if s, ok := prev["statement"].(string); ok && len(s) < auditStatementMax {
					prev["statement"] = cutRunes(s+collect.MaskJobText(rowText(x, "statement")), auditStatementMax)
				}
			}
			continue
		}
		ordinal++
		prev = nil
		at, err := time.Parse(time.RFC3339Nano, rowText(x, "event_at"))
		if err != nil {
			continue
		}
		if !floor.IsZero() && !at.After(floor) {
			continue
		}
		if at.After(res.lastEvent) {
			res.lastEvent = at
		}
		action := strings.ToUpper(strings.TrimSpace(rowText(x, "action_id")))
		class := strings.ToUpper(strings.TrimSpace(rowText(x, "class_type")))
		database := rowText(x, "database_name")
		category, keep := auditCategory(action, class, database)
		okN, _ := asInt(x["succeeded"])
		if keep && res.listed >= int64(auditRowCap) {
			keep = false
			res.overCap++
		}
		if !keep {
			counts[auditCountKey{hour: at.UTC().Truncate(time.Hour), category: category, action: action, login: rowText(x, "login_name"),
				database: database, schema: rowText(x, "schema_name"), object: rowText(x, "object_name"), ok: okN == 1}]++
			res.counted++
			continue
		}
		res.listed++
		ev := collect.Row{"kind": "audit_event", "event_at": at.UTC().Format(time.RFC3339Nano), "event_key": auditKey(file, off, ordinal),
			"audit_name": a.name, "audit_guid": a.guid, "category": category, "action_id": action,
			"action": auditName(auditActionNames, action), "class_type": class, "class_name": auditName(auditClassNames, class),
			"succeeded": okN == 1, "login_name": nilIfBlank(rowText(x, "login_name")),
			"database_user": nilIfBlank(rowText(x, "database_user")), "target_login": nilIfBlank(rowText(x, "target_login")),
			"target_user": nilIfBlank(rowText(x, "target_user")), "database_name": nilIfBlank(database),
			"schema_name": nilIfBlank(rowText(x, "schema_name")), "object_name": nilIfBlank(rowText(x, "object_name")),
			"client_ip": nilIfBlank(rowText(x, "client_ip")), "application": nilIfBlank(rowText(x, "application_name")),
			"host": nilIfBlank(rowText(x, "host_name")), "session_id": x["session_id"]}
		if sl := rowText(x, "session_login"); sl != "" && !strings.EqualFold(sl, rowText(x, "login_name")) {
			ev["session_login"] = sl
		}
		errNumber, errState, act := auditInfo(rowText(x, "additional_information"))
		switch {
		case category == auditFailedLogin:
			// the "statement" of a failed sign-in is the server's message: its reason, never statement text
			ev["reason"], ev["error_number"], ev["error_state"] = nilIfBlank(cutRunes(strings.TrimSpace(rowText(x, "statement")), 500)), errNumber, errState
		case action == "AUSC" || action == "AUSF":
			ev["reason"] = nilIfBlank(act)
		}
		if rd.text && category != auditFailedLogin {
			if s := rowText(x, "statement"); strings.TrimSpace(s) != "" {
				// SQL Server writes a password as '******' in the record; any other credential form is masked here,
				// before the text leaves the collector
				ev["statement"] = collect.MaskJobText(cutRunes(s, auditStatementMax))
				prev = ev
			}
		}
		batch = append(batch, ev)
	}
	keys := make([]auditCountKey, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		x, y := keys[i], keys[j]
		if !x.hour.Equal(y.hour) {
			return x.hour.Before(y.hour)
		}
		xs := strings.Join([]string{x.category, x.action, x.login, x.database, x.schema, x.object, strconv.FormatBool(x.ok)}, "\x00")
		ys := strings.Join([]string{y.category, y.action, y.login, y.database, y.schema, y.object, strconv.FormatBool(y.ok)}, "\x00")
		return xs < ys
	})
	for _, k := range keys {
		batch = append(batch, collect.Row{"kind": "audit_count", "hour_at": k.hour.Format(time.RFC3339), "audit_name": a.name,
			"audit_guid": a.guid, "category": k.category, "action_id": k.action, "action": auditName(auditActionNames, k.action),
			"login_name": k.login, "database_name": k.database, "schema_name": k.schema, "object_name": k.object,
			"succeeded": k.ok, "n": counts[k]})
	}
	return batch
}

// read reads one FILE audit past its cursor in batches of whole buffers. The reader's starting point is a buffer
// (every record of a buffer has the same offset), so a batch that ended inside a buffer would lose the buffer's
// rest: a batch ends on a buffer's edge and the cursor is the last whole buffer read. Each batch is one import with
// its cursor: stored once or not at all.
func (rd *auditReader) read(ctx context.Context, a *auditDef) (auditRead, error) {
	var res auditRead
	source := auditSource(a.guid)
	cur, err := rd.cursor(ctx, source)
	if err != nil {
		return res, err
	}
	res.lastEvent = cur.LastEventAt
	wide := auditPattern(a.logPath, a.logName)
	if wide == "" {
		return res, fmt.Errorf("the audit %s names no file path", a.name)
	}
	pattern := wide
	if !cur.Found || cur.FileName == "" {
		// never read: the first read starts at the file the audit writes now. What older files hold is not loaded
		// (an audit of every SELECT can keep gigabytes of them). (file, NULL) is refused by the reader, so the
		// file's own path is the pattern of this one read.
		if a.current == "" {
			res.notes = append(res.notes, "never read, and no file of this audit is known to be open (it is not started, or the state view is not readable): its events are read from the first file it is seen writing")
			return res, nil
		}
		pattern, cur = a.current, Cursor{}
		res.notes = append(res.notes, "first read: from the file the audit writes now ("+baseName(a.current)+"); older files are not loaded")
	}
	var floor time.Time
	for {
		top := auditBatchRows
		var rows []collect.Row
		more := false
		for {
			rows, err = rd.query(pattern, top+1, cur)
			if err != nil && cur.FileName != "" && auditCursorGone(err) && ctx.Err() == nil {
				// the file the cursor names was rolled away: the set is read again from its oldest file and the
				// records at or before the newest event already read are passed over by their time
				res.notes = append(res.notes, fmt.Sprintf("the cursor's file %s is gone: the files were read again from the oldest, by event time", baseName(cur.FileName)))
				floor = cur.LastEventAt
				pattern, cur = wide, Cursor{LastEventAt: cur.LastEventAt}
				continue
			}
			if err != nil {
				return res, fmt.Errorf("the audit file of %s: %w", a.name, err)
			}
			cut, m, grow := auditCut(rows, top)
			if !grow {
				rows, more = rows[:cut], m
				break
			}
			if top >= auditBufferCap {
				return res, fmt.Errorf("the audit file of %s: one buffer holds more than %d records", a.name, auditBufferCap)
			}
			top *= 4 // one buffer larger than the batch: read on until it is whole
		}
		if len(rows) == 0 {
			break
		}
		batch := rd.auditBatch(a, rows, floor, &res)
		last := rows[len(rows)-1]
		off, _ := asInt(last["file_offset"])
		cur = Cursor{Found: true, FileName: rowText(last, "file_name"), FileOffset: off, LastEventAt: res.lastEvent}
		batch = append(batch, cur.Row(source))
		if err := rd.emit(batch); err != nil {
			return res, fmt.Errorf("import a batch of %s: %w", a.name, err)
		}
		pattern = wide // the first read's one file is behind the cursor now: the next batch reads the whole set past it
		if !more {
			break
		}
		if rd.now().After(rd.deadline) {
			res.notes = append(res.notes, "the run's time was up before the files were read to their end: the next run goes on from the cursor")
			break
		}
	}
	if res.overCap > 0 {
		res.notes = append(res.notes, fmt.Sprintf("%d event(s) were counted and not listed: one read lists at most %d", res.overCap, auditRowCap))
	}
	return res, nil
}

// auditReaderFunc is the reader function of a server's kind, and the catalog prefix that lists its columns.
func auditReaderFunc(k Kind) (fn, catalog string) {
	if k == KindRDS {
		return "msdb.dbo.rds_fn_get_audit_file", "msdb."
	}
	return "sys.fn_get_audit_file", ""
}

// auditOptionalColumns writes the reader's optional columns, each a typed NULL where the function has none.
func auditOptionalColumns(have map[string]bool) string {
	return colOr(have["client_ip"], "CAST(client_ip AS nvarchar(128))", "nvarchar(128)", "client_ip") + ",\n  " +
		colOr(have["application_name"], "CAST(application_name AS nvarchar(128))", "nvarchar(128)", "application_name") + ",\n  " +
		colOr(have["host_name"], "CAST(host_name AS nvarchar(128))", "nvarchar(128)", "host_name")
}

// auditFileQuery is the reader's statement for one starting point.
func auditFileQuery(fn string, have map[string]bool, fromCursor bool) string {
	start := "default, default"
	if fromCursor {
		start = "@p4, @p5"
	}
	return fmt.Sprintf(auditFileFmt, fn, auditOptionalColumns(have), start, auditTextActions)
}

// auditSpecRows folds the per-action rows of a specifications read into one row per specification.
func auditSpecRows(scope, database string, rows []collect.Row) []collect.Row {
	var out []collect.Row
	byName := map[string]collect.Row{}
	for _, x := range rows {
		name := rowText(x, "name")
		spec := byName[name]
		if spec == nil {
			en, _ := asInt(x["is_enabled"])
			spec = collect.Row{"kind": "spec", "scope": scope, "database_name": nilIfBlank(database), "name": name,
				"audit_guid": strings.ToUpper(rowText(x, "audit_guid")), "is_enabled": en == 1,
				"created": x["created_local"], "modified": x["modified_local"], "actions": []collect.Row{}}
			byName[name] = spec
			out = append(out, spec)
		}
		if act := rowText(x, "action_name"); act != "" {
			g, _ := asInt(x["is_group"])
			spec["actions"] = append(spec["actions"].([]collect.Row), collect.Row{"action": act, "class": x["class_desc"],
				"object": x["object_name"], "principal": x["principal_name"], "result": x["audited_result"], "is_group": g == 1})
		}
	}
	return out
}

// RunBatches reads the health, then every FILE audit's events past its cursor, then stores the health rows with
// what each read found. A source that fails is a collector_error row (the run is partial) and the rest is stored.
func (auditCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	rr, err := QueryRows(ctx, conn, auditRightsSQL)
	if err != nil {
		return fmt.Errorf("the login's rights on the audit: %w", err)
	}
	if len(rr) != 1 {
		return fmt.Errorf("the login's rights on the audit: %d rows, want 1", len(rr))
	}
	rights := auditRightsOf(info, rr[0])
	var tail []collect.Row
	fail := func(source string, err error) {
		tail = append(tail, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
	}

	// the audits: the catalog's rows, with the state view's on top
	audits := map[int64]*auditDef{}
	var order []int64
	if rights.defs {
		rows, err := QueryRows(ctx, conn, auditDefsSQL)
		if err != nil {
			return fmt.Errorf("sys.server_audits: %w", err)
		}
		for _, x := range rows {
			id, _ := asInt(x["audit_id"])
			en, _ := asInt(x["is_enabled"])
			on := en == 1
			a := &auditDef{id: id, name: rowText(x, "name"), guid: strings.ToUpper(rowText(x, "audit_guid")), typ: strings.ToUpper(strings.TrimSpace(rowText(x, "type"))),
				enabled: &on, logPath: rowText(x, "log_file_path"), logName: rowText(x, "log_file_name"), row: x}
			audits[id] = a
			order = append(order, id)
		}
	}
	stateRead := false
	if rights.state {
		rows, err := QueryRows(ctx, conn, auditStatusSQL)
		if err != nil {
			fail("sys.dm_server_audit_status", err)
		} else {
			stateRead = true
			for _, x := range rows {
				id, _ := asInt(x["audit_id"])
				a := audits[id]
				if a == nil {
					// the catalog is not readable (or lists less): what the state view alone tells
					a = &auditDef{id: id, name: rowText(x, "name"), row: collect.Row{}}
					audits[id] = a
					order = append(order, id)
				}
				a.status, a.current = rowText(x, "status"), rowText(x, "current_file")
				a.row["status"], a.row["status_at"], a.row["current_file"], a.row["file_size_bytes"] = x["status"], x["status_at"], x["current_file"], x["file_size_bytes"]
			}
		}
	}

	// the events of every audit that writes to a file
	fn, catalog := auditReaderFunc(info.Kind)
	var have map[string]bool
	rd := &auditReader{text: opt.AuditText, deadline: opt.Deadline, cursor: cursor, emit: emit, now: time.Now}
	rd.query = func(pattern string, top int, cur Cursor) ([]collect.Row, error) {
		text := 0
		if rd.text {
			text = 1
		}
		args := []any{pattern, top, text}
		if cur.FileName != "" {
			args = append(args, cur.FileName, cur.FileOffset)
		}
		return QueryRows(ctx, conn, auditFileQuery(fn, have, cur.FileName != ""), args...)
	}
	for _, id := range order {
		a := audits[id]
		target := auditTarget(a.typ, rowText(a.row, "type_desc"))
		switch {
		case a.typ == "":
			a.readState, a.readNote = "not read", "the login cannot list the audits (VIEW ANY DEFINITION): the target of this audit is not known"
		case a.typ == "AL" || a.typ == "SL":
			a.readState, a.readNote = "not readable", "the Windows "+target+" is not readable through T-SQL: its events are in the Event Viewer of the server"
		case a.typ != "FL":
			a.readState, a.readNote = "not read", "a "+target+" target is not read by pgvigil"
		case !rights.events:
			a.readState, a.readNote = "no right", "the login lacks "+rights.eventsRight+": the audit's health is read, its events are not"
		case time.Now().After(opt.Deadline):
			a.readState, a.readNote = "read", "the run's time was up before this audit was read: the next run reads it"
		default:
			if have == nil {
				have = map[string]bool{}
				cols, err := QueryRows(ctx, conn, fmt.Sprintf(auditColumnsSQL, catalog, fn))
				if err != nil || len(cols) == 0 {
					for _, c := range auditBaseColumns { // the catalog does not list the function: the columns every version has
						have[c] = true
					}
				}
				for _, c := range cols {
					have[strings.ToLower(rowText(c, "name"))] = true
				}
			}
			res, err := rd.read(ctx, a)
			a.readState = "read"
			if err != nil {
				a.readState = "error"
				res.notes = append(res.notes, err.Error())
				fail(a.name, err)
			}
			a.readNote = strings.Join(res.notes, "; ")
			a.row["new_events"], a.row["counted_events"] = res.listed, res.counted
			if !res.lastEvent.IsZero() {
				a.row["last_event_at"] = res.lastEvent.UTC().Format(time.RFC3339Nano)
			}
		}
	}

	// the specifications: the server's, then each database's
	specsRead, dbRead, dbSkipped := false, []string{}, []string{}
	if rights.defs {
		rows, err := QueryRows(ctx, conn, auditServerSpecsSQL)
		if err != nil {
			fail("sys.server_audit_specifications", err)
		} else {
			specsRead = true
			tail = append(tail, auditSpecRows("server", "", rows)...)
		}
	}
	dbNote, dbListed := "", false
	if rights.dbDefs {
		dbs, err := QueryRows(ctx, conn, auditDatabasesSQL)
		if err != nil {
			fail("sys.databases", err)
		} else {
			dbListed = true
		}
		for i, d := range dbs {
			name := rowText(d, "database_name")
			if can, _ := asInt(d["can_enter"]); can != 1 {
				dbSkipped = append(dbSkipped, name)
				continue
			}
			if i >= auditMaxDatabases || time.Now().After(opt.Deadline) {
				dbSkipped = append(dbSkipped, name)
				dbNote = "not every database was asked for its audit specification in this run"
				continue
			}
			rows, err := qsRead(ctx, conn, rowText(d, "quoted_name"), auditDatabaseSpecsSQL, "")
			if err != nil {
				if ctx.Err() != nil {
					return fmt.Errorf("the audit specification of %s: %w", name, err)
				}
				dbSkipped = append(dbSkipped, name) // a database that cannot be read keeps what an earlier read stored
				continue
			}
			dbRead = append(dbRead, name)
			tail = append(tail, auditSpecRows("database", name, rows)...)
		}
	}

	for _, id := range order {
		a := audits[id]
		row := collect.Row{"kind": "audit", "audit_id": a.id, "name": a.name, "audit_guid": nilIfBlank(a.guid),
			"state": auditState(a.enabled, a.status, stateRead), "target": nilIfBlank(auditTarget(a.typ, rowText(a.row, "type_desc"))),
			"read_state": a.readState, "read_note": nilIfBlank(a.readNote)}
		if a.enabled != nil {
			row["is_enabled"] = *a.enabled
		}
		for _, k := range []string{"type", "on_failure", "queue_delay_ms", "predicate", "created_at", "modified_at", "max_file_size_mb",
			"max_rollover_files", "max_files", "reserve_disk_space", "log_file_path", "log_file_name", "status", "status_at",
			"current_file", "file_size_bytes", "new_events", "counted_events", "last_event_at"} {
			if v, ok := a.row[k]; ok {
				row[k] = v
			}
		}
		tail = append(tail, row)
	}
	tail = append(tail, collect.Row{"kind": "read", "defs_read": rights.defs, "state_read": stateRead, "specs_read": specsRead,
		"db_specs_right": rights.dbDefs, "events_right": rights.eventsRight, "events_readable": rights.events,
		"text_stored": opt.AuditText && opt.QueryText != "none", "databases_listed": dbListed, "databases_read": dbRead,
		"databases_skipped": dbSkipped, "note": nilIfBlank(dbNote)})
	return emit(tail)
}
