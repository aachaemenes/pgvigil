package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// The rights pgvigil's monitoring login needs on a SQL Server instance (the ServiceConfig takes, ST2; DBA Dash's
// Permissions Helper): each right with the collectors' own check, what needs it and the statement that gives it.
// ReadRights asks the server, as that login, which it holds; the statements of the missing ones are PRINTED for an
// administrator to run - pgvigil never grants anything.
//
// The list is held in step with the collectors by TestRightsCatalogueNamesEveryCheck: a HAS_PERMS_BY_NAME,
// HAS_DBACCESS or IS_SRVROLEMEMBER the package's statements ask about is named here (checks) or among the listed
// exceptions (an alternative to a right named here, or a check of the actions login, which has its own page:
// docs/sqlserver-actions.md).

// Right is one right of the catalogue.
type Right struct {
	Key  string
	Name string
	// Core: without it a whole family of collections is skipped; else it is one feature's own.
	Core bool
	// For says what needs it, in the page's words.
	For string
	// Check is a T-SQL expression: 1 held, 0 missing, NULL = the thing it is about is not on this server (State says
	// what a NULL means for the right).
	Check string
	// Null is the state a NULL answer means ("" = missing).
	Null string
	// Grant is the statement that gives it; {login} is the login as QUOTENAME writes it, {login_text} the same name as
	// a string literal.
	Grant string
	// Checks are the collectors' literals this right covers (TestRightsCatalogueNamesEveryCheck).
	Checks []string
	// On says whether the right applies to this server: "" yes; "hide" = not listed at all there; any other text =
	// listed as 'not on this server' with that reason.
	On func(Info) string
}

const rightsUser = "IF DATABASE_PRINCIPAL_ID({login_text}) IS NULL CREATE USER {login} FOR LOGIN {login};\n"

// notAzureDB: Azure SQL Database has no server-level rights of this kind (one database is the instance).
func notAzureDB(i Info) string {
	if i.Kind == KindAzureDB {
		return "hide"
	}
	return ""
}

// hostOnly: a right about the host's registry; a managed platform runs the host.
func hostOnly(i Info) string {
	switch i.Kind {
	case KindAzureDB:
		return "hide"
	case KindAzureMI:
		return "Azure SQL Managed Instance runs the host: the registry is not read there"
	case KindRDS:
		return "Amazon RDS runs the host: the registry is not read there"
	case KindCloudSQL:
		return "Google Cloud SQL runs the host: the registry is not read there"
	}
	return ""
}

// Rights is the catalogue, in the page's order: the core rights first.
var Rights = []Right{
	{Key: "view_server_state", Name: "VIEW SERVER STATE", Core: true,
		For:    "the live reads: running queries and blocking, waits, CPU and memory, the performance counters, which audit is started, the registry view (from SQL Server 2022 VIEW SERVER PERFORMANCE STATE alone serves the performance reads)",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')",
		Grant:  "USE master;\nGRANT VIEW SERVER STATE TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')"}, On: notAzureDB},
	{Key: "view_database_state", Name: "VIEW DATABASE STATE", Core: true,
		For:    "the live reads of the database (Azure SQL Database: one database is the instance)",
		Check:  "HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE')",
		Grant:  "-- in the database itself\nGRANT VIEW DATABASE STATE TO {user};",
		Checks: []string{"HAS_PERMS_BY_NAME(DB_NAME()"},
		On: func(i Info) string {
			if i.Kind != KindAzureDB {
				return "hide"
			}
			return ""
		}},
	{Key: "view_any_definition", Name: "VIEW ANY DEFINITION", Core: true,
		For:    "every database's metadata: the audits and their specifications, the definitions of objects and jobs",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION')",
		Grant:  "USE master;\nGRANT VIEW ANY DEFINITION TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION')"}, On: notAzureDB},
	{Key: "msdb_reader", Name: "msdb: a user with db_datareader", Core: true,
		For: "msdb: the Agent jobs and their history, the backup history",
		Check: "CASE WHEN ISNULL(HAS_DBACCESS('msdb'), 0) = 1 AND ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo.backupset', 'OBJECT', 'SELECT'), 0) = 1" +
			" AND ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobs', 'OBJECT', 'SELECT'), 0) = 1" +
			" AND ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo.sysjobhistory', 'OBJECT', 'SELECT'), 0) = 1 THEN 1 ELSE 0 END",
		Grant:  "USE msdb;\n" + rightsUser + "ALTER ROLE db_datareader ADD MEMBER {login};",
		Checks: []string{"HAS_DBACCESS('msdb')", `HAS_PERMS_BY_NAME(N'msdb.dbo."+table+"', 'OBJECT', 'SELECT')`},
		On:     notAzureDB},
	{Key: "database_access", Name: "CONNECT ANY DATABASE", Core: true,
		For:    "each database's own reads: indexes, storage and files, Query Store, the database options, the database audit specifications, replication",
		Check:  "CASE WHEN EXISTS (SELECT 1 FROM sys.databases d WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 0) THEN 0 ELSE 1 END",
		Grant:  "USE master;\nGRANT CONNECT ANY DATABASE TO {login};",
		Checks: []string{"HAS_DBACCESS(d.name)", "HAS_DBACCESS(name)"}, On: notAzureDB},
	{Key: "restore_history", Name: "SELECT on msdb.dbo.restorehistory",
		For:    "a restored database's restore date (the index usage window starts there); db_datareader in msdb gives it",
		Check:  "HAS_PERMS_BY_NAME(N'msdb.dbo.restorehistory', 'OBJECT', 'SELECT')",
		Grant:  "USE msdb;\n" + rightsUser + "GRANT SELECT ON dbo.restorehistory TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(N'msdb.dbo.restorehistory', 'OBJECT', 'SELECT')"}, On: notAzureDB},
	{Key: "registry_instance", Name: "EXECUTE on master.dbo.xp_instance_regread",
		For:    "Properties: the TCP port, the protocols and the encryption settings where the registry view does not hold them",
		Check:  "HAS_PERMS_BY_NAME(N'master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE')",
		Grant:  "USE master;\n" + rightsUser + "GRANT EXECUTE ON dbo.xp_instance_regread TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(N'master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE')"}, On: hostOnly},
	{Key: "registry_machine", Name: "EXECUTE on master.dbo.xp_regread",
		For:    "Properties: Win32PrioritySeparation and the power plan (a Windows host)",
		Check:  "HAS_PERMS_BY_NAME(N'master.dbo.xp_regread', 'OBJECT', 'EXECUTE')",
		Grant:  "USE master;\n" + rightsUser + "GRANT EXECUTE ON dbo.xp_regread TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(N'master.dbo.xp_regread', 'OBJECT', 'EXECUTE')"}, On: hostOnly},
	{Key: "default_trace", Name: "ALTER TRACE",
		For:    "the default trace's events (mssql_defaulttrace). It also lets the login start and stop server traces: give it only where that is accepted",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE')",
		Grant:  "USE master;\nGRANT ALTER TRACE TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE')"}, On: notAzureDB},
	{Key: "audit_events", Name: "VIEW SERVER SECURITY AUDIT",
		For:    "the audit's events from its files (mssql_audit; SQL Server 2022 and later)",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY AUDIT')",
		Grant:  "USE master;\nGRANT VIEW SERVER SECURITY AUDIT TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY AUDIT')"},
		On: func(i Info) string {
			switch {
			case i.Kind == KindAzureDB, i.Kind == KindRDS:
				return "hide"
			case !atLeast(i, 16):
				return "before SQL Server 2022 the audit's events are read only by a login that holds CONTROL SERVER, which pgvigil does not ask for: the audits and their state are still read"
			}
			return ""
		}},
	{Key: "audit_events_rds", Name: "SELECT on msdb.dbo.rds_fn_get_audit_file",
		For:    "the audit's events on Amazon RDS (its own reader function)",
		Check:  "HAS_PERMS_BY_NAME(N'msdb.dbo.rds_fn_get_audit_file', 'OBJECT', 'SELECT')",
		Null:   "not there: the instance has no audit option group (msdb.dbo.rds_fn_get_audit_file is absent)",
		Grant:  "USE msdb;\n" + rightsUser + "GRANT SELECT ON dbo.rds_fn_get_audit_file TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(N'msdb.dbo.rds_fn_get_audit_file', 'OBJECT', 'SELECT')"},
		On: func(i Info) string {
			if i.Kind != KindRDS {
				return "hide"
			}
			return ""
		}},
	{Key: "sp_whoisactive", Name: "EXECUTE on master.dbo.sp_WhoIsActive",
		For:    "Running queries through sp_WhoIsActive, where it is installed in master",
		Check:  "CASE WHEN OBJECT_ID(N'master.dbo.sp_WhoIsActive', 'P') IS NULL THEN NULL ELSE HAS_PERMS_BY_NAME(N'master.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE') END",
		Null:   "not installed: master holds no sp_WhoIsActive (pgvigil reads the DMVs itself)",
		Grant:  "USE master;\n" + rightsUser + "GRANT EXECUTE ON dbo.sp_WhoIsActive TO {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(N'master.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE')", "HAS_PERMS_BY_NAME(QUOTENAME(DB_NAME()", "HAS_PERMS_BY_NAME(N'dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE')"},
		On:     notAzureDB},
}

// RightsExceptions are the checks the package's statements make that no right of the catalogue stands for, each with
// why (TestRightsCatalogueNamesEveryCheck).
var RightsExceptions = map[string]string{
	"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE')":             "an alternative to VIEW SERVER STATE from SQL Server 2022 (said in its row)",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY STATE')":                "an alternative to VIEW SERVER STATE for the audit's state",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY SECURITY DEFINITION')":              "an alternative to VIEW ANY DEFINITION for the audits",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY SERVER AUDIT')":                    "an alternative to VIEW ANY DEFINITION for the server audits",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'CONTROL SERVER')":                            "never asked for: it holds every right (the actions door refuses a login that has it)",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER SERVER STATE')":                        "the actions login's (docs/sqlserver-actions.md)",
	"HAS_PERMS_BY_NAME(N'master.dbo.pgvigil_evict_plan', N'OBJECT', N'EXECUTE')": "the actions login's (docs/sqlserver-actions.md)",
	"IS_SRVROLEMEMBER('sysadmin')":                                               "the actions door's refusal of a sysadmin login",
	"HAS_PERMS_BY_NAME(NULL, NULL, ...)":                                         "a comment's ellipsis, not a statement",
}

// RightState is one right as the server answered it for the login.
type RightState struct {
	Key, Name, For string
	Core           bool
	// State: held, missing, or the words of a right that does not apply here ('not on this server: ...', 'not
	// installed: ...').
	State string
	// Grant is the statement for this login; "" unless the right is missing.
	Grant string
	// Databases names the databases the login cannot enter (database_access; the first 20).
	Databases []string
}

// RightsRead is what ReadRights answers.
type RightsRead struct {
	Login, Server, Platform string
	Rights                  []RightState
	// Missing counts every missing right; MissingCore the needed ones among them.
	Missing, MissingCore int
}

// rightsIdentitySQL: the login as the server names it, quoted both ways by the server itself, the server's name, and
// on Azure SQL Database the database user.
const rightsIdentitySQL = `SELECT CAST(SUSER_SNAME() AS nvarchar(128)), CAST(QUOTENAME(SUSER_SNAME()) AS nvarchar(258)),
  CAST(N'N' + QUOTENAME(SUSER_SNAME(), '''') AS nvarchar(260)), CAST(ISNULL(@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128))) AS nvarchar(128)),
  CAST(QUOTENAME(USER_NAME()) AS nvarchar(258))`

// rightsNoAccessSQL: the online databases the login cannot enter.
const rightsNoAccessSQL = `SELECT TOP (21) CAST(d.name AS nvarchar(128)) FROM sys.databases d WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 0 ORDER BY d.name`

// rightsSQL is the one statement that asks every right that applies to the server: a column per right, by its key.
func rightsSQL(apply []Right) string {
	cols := make([]string, 0, len(apply))
	for _, r := range apply {
		cols = append(cols, "CAST("+r.Check+" AS int) AS "+r.Key)
	}
	return "SELECT " + strings.Join(cols, ",\n  ")
}

// ReadRights asks the server, as the connection's login, which rights of the catalogue it holds. It reads only.
func ReadRights(ctx context.Context, conn *sql.Conn, platform string) (RightsRead, error) {
	info, err := Detect(ctx, conn, platform)
	if err != nil {
		return RightsRead{}, err
	}
	var out RightsRead
	var quoted, literal, user string
	if err := conn.QueryRowContext(ctx, rightsIdentitySQL).Scan(&out.Login, &quoted, &literal, &out.Server, &user); err != nil {
		return RightsRead{}, err
	}
	out.Platform = string(info.Kind)
	var apply []Right
	states := map[string]string{}
	for _, r := range Rights {
		switch on := r.On(info); on {
		case "":
			apply = append(apply, r)
		case "hide":
		default:
			states[r.Key] = "not on this server: " + on
		}
	}
	answers := map[string]sql.NullInt64{}
	if len(apply) > 0 {
		vals := make([]sql.NullInt64, len(apply))
		ptrs := make([]any, len(apply))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := conn.QueryRowContext(ctx, rightsSQL(apply)).Scan(ptrs...); err != nil {
			return RightsRead{}, fmt.Errorf("the rights: %w", err)
		}
		for i, r := range apply {
			answers[r.Key] = vals[i]
		}
	}
	fill := strings.NewReplacer("{login}", quoted, "{login_text}", literal, "{user}", user)
	for _, r := range Rights {
		st := RightState{Key: r.Key, Name: r.Name, For: r.For, Core: r.Core}
		if why, off := states[r.Key]; off {
			st.State = why
			out.Rights = append(out.Rights, st)
			continue
		}
		a, asked := answers[r.Key]
		if !asked {
			continue // hidden on this server
		}
		switch {
		case a.Valid && a.Int64 == 1:
			st.State = "held"
		case !a.Valid && r.Null != "":
			st.State = r.Null
		default:
			st.State = "missing"
			st.Grant = fill.Replace(r.Grant)
			out.Missing++
			if r.Core {
				out.MissingCore++
			}
			if r.Key == "database_access" {
				st.Databases = rightsNoAccess(ctx, conn)
			}
		}
		out.Rights = append(out.Rights, st)
	}
	return out, nil
}

// rightsNoAccess names the online databases the login cannot enter (nil when the read fails: the row still says missing).
func rightsNoAccess(ctx context.Context, conn *sql.Conn) []string {
	rows, err := conn.QueryContext(ctx, rightsNoAccessSQL)
	if err != nil {
		return nil
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var n string
		if rows.Scan(&n) == nil {
			out = append(out, n)
		}
	}
	return out
}

// Script is the printed script of the missing rights: a comment head that says whose it is and that pgvigil ran
// nothing, then each missing right's statement under a comment naming it. "" when nothing is missing.
func (r RightsRead) Script(at string) string {
	if r.Missing == 0 {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "-- pgvigil: the rights its monitoring login %s lacks on %s (read %s).\n", r.Login, r.Server, at)
	b.WriteString("-- Run it as an administrator of that server. pgvigil did not run it and never does.\n")
	for _, s := range r.Rights {
		if s.Grant == "" {
			continue
		}
		kind := "optional"
		if s.Core {
			kind = "needed"
		}
		fmt.Fprintf(&b, "\n-- %s (%s): %s\n", s.Name, kind, s.For)
		if len(s.Databases) > 0 {
			more := ""
			if len(s.Databases) > 20 {
				s.Databases, more = s.Databases[:20], " and more"
			}
			fmt.Fprintf(&b, "-- the login cannot enter: %s%s\n", strings.Join(s.Databases, ", "), more)
		}
		b.WriteString(s.Grant + "\n")
	}
	return b.String()
}
