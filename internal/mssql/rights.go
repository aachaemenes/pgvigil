package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"unicode"
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
	// Grant is the statement that gives it. {login} is the login as QUOTENAME writes it; {p} is the principal the
	// statement names: the login itself for a server permission, the login's user in UserDB for a database's (resolved
	// by its SID at the read, so a user of another name is named as it is and one that is not there is created first).
	Grant string
	// UserDB is the database whose user {p} is ("" = {p} is the login: a server permission).
	UserDB string
	// Checks are the collectors' literals this right covers (TestRightsCatalogueNamesEveryCheck).
	Checks []string
	// On says whether the right applies to this server: "" yes; "hide" = not listed at all there; any other text =
	// listed as 'not on this server' with that reason.
	On func(Info) string
	// OptIn: a right pgvigil never asks for, only offers (P25 task 9b: Pool history's dbmanager) - its block, every line
	// a comment ({login} filled in), printed in the script in place of Grant whatever the read; its state is always
	// Null's words and it never counts as missing. "" = an ordinary right.
	OptIn string
}

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

// azureServerState: Azure SQL Database's tiers where Detect asks the server-level right (detectSQL's own list).
func azureServerState(i Info) bool {
	switch i.ServiceObjective {
	case "Basic", "S0", "S1", "ElasticPool":
		return true
	}
	return false
}

// rightsNoAccessWhere: the online databases the login cannot enter - the ones a grant could open: MULTI_USER, and not
// a platform's own (rdsadmin, gcloud_cloudsqladmin: platformOwnDatabase). A WHERE condition over sys.databases d.
const rightsNoAccessWhere = `d.state = 0 AND d.user_access = 0 AND d.name NOT IN (N'rdsadmin', N'gcloud_cloudsqladmin') AND HAS_DBACCESS(d.name) = 0`

// msdbReaderTables: the msdb tables the collectors ask msdbReadable about - backups.go's backupFileTables, jobs.go's
// jobTables (sysproxies among them), log shipping's two, its restores' restorehistory and the security read's
// sysproxylogin (TestRightsMsdbTables holds the list to every msdbReadable call);
// msdb_reader's check asks each.
var msdbReaderTables = append(append(append([]string{}, backupFileTables...), jobTables...), "log_shipping_monitor_primary", "log_shipping_monitor_secondary", "restorehistory", "sysproxylogin")

// msdbReaderCheck: msdb is entered and every table of msdbReaderTables is readable.
func msdbReaderCheck() string {
	var b strings.Builder
	b.WriteString("CASE WHEN ISNULL(HAS_DBACCESS('msdb'), 0) = 1")
	for _, t := range msdbReaderTables {
		b.WriteString(" AND ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo." + t + "', 'OBJECT', 'SELECT'), 0) = 1")
	}
	b.WriteString(" THEN 1 ELSE 0 END")
	return b.String()
}

// Rights is the catalogue, in the page's order: the core rights first.
var Rights = []Right{
	{Key: "view_server_state", Name: "VIEW SERVER STATE", Core: true,
		For:    "the live reads: running queries and blocking, waits, CPU and memory, the performance counters, which audit is started, the registry view (from SQL Server 2022 VIEW SERVER PERFORMANCE STATE alone serves the performance reads)",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')",
		Grant:  "USE master;\nGRANT VIEW SERVER STATE TO {p};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')"}, On: notAzureDB},
	{Key: "view_database_state", Name: "VIEW DATABASE STATE", Core: true,
		For:    "the live reads of the database (Azure SQL Database: one database is the instance)",
		Check:  "HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE')",
		Grant:  "-- in the database itself\nGRANT VIEW DATABASE STATE TO {user};",
		Checks: []string{"HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE')"},
		On: func(i Info) string {
			if i.Kind != KindAzureDB || azureServerState(i) {
				return "hide"
			}
			return ""
		}},
	// Azure SQL Database on Basic, S0, S1 or in an elastic pool: Detect asks the server-level right there (Microsoft's
	// DMV pages name the server admin or ##MS_ServerStateReader##), so that is the row
	{Key: "azure_server_state_reader", Name: "##MS_ServerStateReader## (the logical server's role)", Core: true,
		For:    "the live reads of the database on Basic, S0, S1 or in an elastic pool, where VIEW DATABASE STATE does not serve the DMVs",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')",
		Grant:  "-- in the logical server's master database, for the server's login (a contained database user cannot be a member)\nALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER {login};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')"},
		On: func(i Info) string {
			if i.Kind != KindAzureDB || !azureServerState(i) {
				return "hide"
			}
			return ""
		}},
	// Azure SQL Database in an elastic pool: Pool history (mssql_pool_limits) reads master's sys.elastic_pool_resource_stats,
	// which asks dbmanager there (Microsoft Learn) - a role that also creates and drops databases, so an opt-in (desk
	// Q176 = a): its block is printed commented out, and the read in master says whether it is held (this read runs in
	// the database, which cannot see master's roles)
	{Key: "azure_dbmanager_pool_history", Name: "dbmanager in the logical server's master (an opt-in: Pool history only)",
		For:   "Pool history: the elastic pool's DTU and storage limits over time, from master's sys.elastic_pool_resource_stats (14 days kept there)",
		Check: "CAST(NULL AS int)",
		// the statement as every row has one; the script prints the OptIn block, which carries it commented out
		Grant: "-- in the logical server's master database\nCREATE USER {login} FROM LOGIN {login};\nALTER ROLE dbmanager ADD MEMBER {login};",
		Null:  "an opt-in, not read here: mssql_pool_limits asks it in master every hour - its last run on Collection health says read (held) or skipped (not given)",
		OptIn: "-- OPT-IN, not needed: every line below is a comment; uncomment it only where the login may create and drop databases.\n" +
			"-- dbmanager lets the login create and drop databases on this logical server, which can cost money.\n" +
			"-- Only Pool history needs it (the elastic pool's limits over time); pgvigil reads every other figure without it.\n" +
			"-- It needs a LOGIN in master: a contained database user (CREATE USER ... WITH PASSWORD in the database) has none -\n" +
			"-- make a login, a user for it in master and in the database, and point the instance's connection string at it.\n" +
			"-- An Entra identity: CREATE USER [<the identity>] FROM EXTERNAL PROVIDER in master, then the role below.\n" +
			"-- In the logical server's master database, as the server admin or the Entra admin:\n" +
			"-- CREATE USER {login} FROM LOGIN {login};\n" +
			"-- ALTER ROLE dbmanager ADD MEMBER {login};\n" +
			"-- To take it back: ALTER ROLE dbmanager DROP MEMBER {login};",
		Checks: []string{"IS_ROLEMEMBER('dbmanager')"},
		On: func(i Info) string {
			if i.Kind != KindAzureDB || !strings.EqualFold(i.ServiceObjective, "ElasticPool") {
				return "hide"
			}
			return ""
		}},
	// Azure SQL Database: the schema read asks the database's own VIEW DEFINITION (VIEW ANY DEFINITION is a server right
	// the platform does not give a database user; the maintenance read does not run there: no SQL Server Agent)
	{Key: "view_definition_db", Name: "VIEW DEFINITION (the database)", Core: true,
		For:    "the database's metadata: the schema read's object definitions",
		Check:  "HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DEFINITION')",
		Grant:  "-- in the database itself\nGRANT VIEW DEFINITION TO {user};",
		Checks: []string{"HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DEFINITION')", "HAS_PERMS_BY_NAME(DB_NAME(), ''DATABASE'', ''VIEW DEFINITION'')"},
		On: func(i Info) string {
			if i.Kind != KindAzureDB {
				return "hide"
			}
			return ""
		}},
	{Key: "view_any_definition", Name: "VIEW ANY DEFINITION", Core: true,
		For:   "every database's metadata: the audits and their specifications, the definitions of objects and jobs",
		Check: "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION')",
		Grant: "USE master;\nGRANT VIEW ANY DEFINITION TO {p};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION')",
			// the schema and maintenance reads' per-database probe: VIEW ANY DEFINITION gives every database's VIEW DEFINITION
			"HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DEFINITION')", "HAS_PERMS_BY_NAME(DB_NAME(), ''DATABASE'', ''VIEW DEFINITION'')"}, On: notAzureDB},
	{Key: "msdb_reader", Name: "msdb: a user with db_datareader", Core: true,
		For:   "msdb: the Agent jobs and their history, the backup history",
		Check: msdbReaderCheck(),
		Grant: "ALTER ROLE db_datareader ADD MEMBER {p};", UserDB: "msdb",
		Checks: []string{"HAS_DBACCESS('msdb')", `HAS_PERMS_BY_NAME(N'msdb.dbo."+table+"', 'OBJECT', 'SELECT')`,
			// the security read's msdb tables (db_datareader in msdb reads them)
			"HAS_PERMS_BY_NAME('msdb.dbo.backupset', 'OBJECT', 'SELECT')", "HAS_PERMS_BY_NAME('msdb.dbo.sysproxies', 'OBJECT', 'SELECT')",
			"HAS_PERMS_BY_NAME('msdb.dbo.sysproxylogin', 'OBJECT', 'SELECT')"},
		On: notAzureDB},
	{Key: "database_access", Name: "CONNECT ANY DATABASE", Core: true,
		For:    "each database's own reads: indexes, storage and files, Query Store, the database options, the database audit specifications, replication",
		Check:  "CASE WHEN ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'CONNECT ANY DATABASE'), 0) = 1 THEN 1 WHEN EXISTS (SELECT 1 FROM sys.databases d WHERE " + rightsNoAccessWhere + ") THEN 0 ELSE 1 END",
		Grant:  "USE master;\nGRANT CONNECT ANY DATABASE TO {p};",
		Checks: []string{"HAS_DBACCESS(d.name)", "HAS_DBACCESS(name)"},
		On: func(i Info) string {
			switch i.Kind {
			case KindAzureDB:
				return "hide"
			case KindCloudSQL:
				return "Google Cloud SQL's administrator cannot grant CONNECT ANY DATABASE: the login is made a user of each database it must read"
			}
			return ""
		}},
	{Key: "restore_history", Name: "SELECT on msdb.dbo.restorehistory",
		For:   "a restored database's restore date (the index usage window starts there); db_datareader in msdb gives it",
		Check: "HAS_PERMS_BY_NAME(N'msdb.dbo.restorehistory', 'OBJECT', 'SELECT')",
		Grant: "GRANT SELECT ON dbo.restorehistory TO {p};", UserDB: "msdb",
		Checks: []string{"HAS_PERMS_BY_NAME(N'msdb.dbo.restorehistory', 'OBJECT', 'SELECT')"}, On: notAzureDB},
	{Key: "registry_instance", Name: "EXECUTE on master.dbo.xp_instance_regread",
		For:   "Properties: the TCP port, the protocols and the encryption settings where the registry view does not hold them; the security read's registry values (its notes name this grant)",
		Check: "HAS_PERMS_BY_NAME(N'master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE')",
		Grant: "GRANT EXECUTE ON dbo.xp_instance_regread TO {p};", UserDB: "master",
		Checks: []string{"HAS_PERMS_BY_NAME(N'master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE')",
			"HAS_PERMS_BY_NAME('master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE')"}, On: hostOnly},
	{Key: "registry_machine", Name: "EXECUTE on master.dbo.xp_regread",
		For:   "Properties: Win32PrioritySeparation and the power plan (a Windows host)",
		Check: "HAS_PERMS_BY_NAME(N'master.dbo.xp_regread', 'OBJECT', 'EXECUTE')",
		Grant: "GRANT EXECUTE ON dbo.xp_regread TO {p};", UserDB: "master",
		Checks: []string{"HAS_PERMS_BY_NAME(N'master.dbo.xp_regread', 'OBJECT', 'EXECUTE')"}, On: hostOnly},
	{Key: "default_trace", Name: "ALTER TRACE",
		For:    "the default trace's events (mssql_defaulttrace). It also lets the login start and stop server traces: give it only where that is accepted",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE')",
		Grant:  "USE master;\nGRANT ALTER TRACE TO {p};",
		Checks: []string{"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE')"}, On: notAzureDB},
	{Key: "audit_events", Name: "VIEW SERVER SECURITY AUDIT",
		For:    "the audit's events from its files (mssql_audit; SQL Server 2022 and later)",
		Check:  "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY AUDIT')",
		Grant:  "USE master;\nGRANT VIEW SERVER SECURITY AUDIT TO {p};",
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
		For:   "the audit's events on Amazon RDS (its own reader function)",
		Check: "HAS_PERMS_BY_NAME(N'msdb.dbo.rds_fn_get_audit_file', 'OBJECT', 'SELECT')",
		Null:  "not there: the instance has no audit option group (msdb.dbo.rds_fn_get_audit_file is absent)",
		Grant: "GRANT SELECT ON dbo.rds_fn_get_audit_file TO {p};", UserDB: "msdb",
		Checks: []string{"HAS_PERMS_BY_NAME(N'msdb.dbo.rds_fn_get_audit_file', 'OBJECT', 'SELECT')"},
		On: func(i Info) string {
			if i.Kind != KindRDS {
				return "hide"
			}
			return ""
		}},
	{Key: "sp_whoisactive", Name: "EXECUTE on master.dbo.sp_WhoIsActive",
		For:   "Running queries through sp_WhoIsActive, where it is installed in master",
		Check: "CASE WHEN OBJECT_ID(N'master.dbo.sp_WhoIsActive', 'P') IS NULL THEN NULL ELSE HAS_PERMS_BY_NAME(N'master.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE') END",
		Null:  "not installed, or not visible to this login: master shows it no sp_WhoIsActive (a procedure it may not run is hidden from a login without VIEW ANY DEFINITION; pgvigil reads the DMVs itself)",
		Grant: "GRANT EXECUTE ON dbo.sp_WhoIsActive TO {p};", UserDB: "master",
		Checks: []string{"HAS_PERMS_BY_NAME(N'master.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE')", "HAS_PERMS_BY_NAME(QUOTENAME(DB_NAME()) + N'.dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE')", "HAS_PERMS_BY_NAME(N'dbo.sp_WhoIsActive', 'OBJECT', 'EXECUTE')"},
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
	// the checks of the reads added after this catalogue, each read in its own code
	"IS_SRVROLEMEMBER(N'sysadmin')":                                 "the Agent alerts script's own check of the login that runs it (a DBA's: msdb.dbo.sp_add_alert needs sysadmin, error 15003); pgvigil prints the script and never runs it",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LINKED SERVER')":      "looked for, never asked for: whether the read login sees every linked server's login mappings (the linked-server checks say when it does not)",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LOGIN')":              "looked for, never asked for: the linked-server and security reads' alternative to VIEW ANY DEFINITION (it lets a login change logins)",
	"IS_SRVROLEMEMBER('setupadmin')":                                "looked for, never asked for: the linked-server checks' alternative to VIEW ANY DEFINITION",
	"HAS_PERMS_BY_NAME(''dbo.CommandLog'', ''OBJECT'', ''SELECT'')": "the maintenance read's probe of Ola Hallengren's dbo.CommandLog in the database it is installed in (its own words when it is not readable); that database differs per server, so no fixed grant row",
	"IS_SRVROLEMEMBER('dbcreator')":                                 "the actions login's (the verify door: RESTORE VERIFYONLY; docs/sqlserver-actions.md)",
	"HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE')":           "the actions login's (the verify door: RESTORE VERIFYONLY; docs/sqlserver-actions.md)",
	"HAS_PERMS_BY_NAME(N'master', 'DATABASE', 'CREATE DATABASE')":   "the actions login's (the verify door: RESTORE VERIFYONLY; docs/sqlserver-actions.md)",
}

// RightState is one right as the server answered it for the login.
type RightState struct {
	Key, Name, For string
	Core           bool
	// State: held, missing, or the words of a right that does not apply here ('not on this server: ...', 'not
	// installed: ...').
	State string
	// Grant is the statement for this login; "" unless the right is missing (and a script may be printed) or an opt-in
	// (Right.OptIn: its block, every line a comment).
	Grant string
	// Databases names the databases the login cannot enter, as QUOTENAME writes them (database_access; the first 20).
	Databases []string
}

// RightsRead is what ReadRights answers.
type RightsRead struct {
	Login, Server, Platform string
	Rights                  []RightState
	// Missing counts every missing right; MissingCore the needed ones among them.
	Missing, MissingCore int
	// OptIns counts the opt-in blocks the script carries (Right.OptIn): printed whatever is missing.
	OptIns int
	// NoScript says why no script is printed though rights are missing ("" = one is printed).
	NoScript string
}

// rightsIdentity is who the connection is, as the server answers it.
type rightsIdentity struct {
	login, quoted, literal, server, user string
	// ownLogin: a server principal has the connection's SID (false: the account signs in through a Windows group).
	ownLogin bool
	// users: the login's user in a database, as QUOTENAME writes it ("" = none mapped, or not readable).
	users map[string]string
}

// rightsIdentitySQL: the login as the server names it (a contained user has none: its user name), quoted both ways by
// the server itself, the server's name, the database user, and whether a login of its own carries the SID.
const rightsIdentitySQL = `SELECT CAST(ISNULL(SUSER_SNAME(), USER_NAME()) AS nvarchar(128)), CAST(QUOTENAME(ISNULL(SUSER_SNAME(), USER_NAME())) AS nvarchar(258)),
  CAST(N'N' + QUOTENAME(ISNULL(SUSER_SNAME(), USER_NAME()), '''') AS nvarchar(260)), CAST(ISNULL(@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128))) AS nvarchar(128)),
  CAST(QUOTENAME(USER_NAME()) AS nvarchar(258)),
  CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals p WHERE p.sid = SUSER_SID()) THEN 1 ELSE 0 END AS int)`

// rightsUserSQL: the login's own user in a database ({db}: master or msdb), found by its SID - whatever its name.
const rightsUserSQL = `SELECT TOP (1) CAST(QUOTENAME(dp.name) AS nvarchar(258)) FROM {db}.sys.database_principals dp
 WHERE dp.sid = SUSER_SID() AND dp.type IN ('S', 'U', 'E', 'X', 'G') AND dp.name NOT IN (N'dbo', N'guest')`

// rightsNoAccessSQL: the online databases the login cannot enter that a grant could open, as QUOTENAME writes them.
const rightsNoAccessSQL = `SELECT TOP (21) CAST(QUOTENAME(d.name) AS nvarchar(258)) FROM sys.databases d WHERE ` + rightsNoAccessWhere + ` ORDER BY d.name`

// rightsSQL is the one statement that asks every right that applies to the server: a column per right, by its key.
func rightsSQL(apply []Right) string {
	cols := make([]string, 0, len(apply))
	for _, r := range apply {
		cols = append(cols, "CAST("+r.Check+" AS int) AS "+r.Key)
	}
	return "SELECT " + strings.Join(cols, ",\n  ")
}

// unsafeName says whether a name the server answered may not be printed into a script: a line break or any other
// control character would end a comment line and start a statement of the name's own.
func unsafeName(s string) bool {
	for _, r := range s {
		if unicode.IsControl(r) || r == '\u0085' || r == '\u2028' || r == '\u2029' {
			return true
		}
	}
	return false
}

// grantFor is a right's statement for this identity. A server permission names the login. A database's names the
// login's user there: the one the read found mapped to its SID, under whatever name. Where the read found none (the
// login may not read that database), the block finds the user by the SID when it runs: none at all = it is created
// under the login's name; a user of that name that is NOT mapped to the login (an orphan left by a restore) raises an
// error instead of being granted to. Each block is a batch of its own (GO).
func grantFor(r Right, id rightsIdentity) string {
	fill := func(text, p string) string {
		return strings.NewReplacer("{p}", p, "{login}", id.quoted, "{login_text}", id.literal, "{user}", id.user).Replace(text)
	}
	if r.UserDB == "" {
		return fill(r.Grant, id.quoted)
	}
	if u := id.users[r.UserDB]; u != "" {
		return "USE " + r.UserDB + ";\n" + fill(r.Grant, u) + "\nGO"
	}
	// the statement as a string the block runs through sp_executesql, the user's name filled in when it runs (EXEC ()
	// takes no function call; the catalogue's statements hold no quote, one would be doubled)
	dyn := "N'" + strings.ReplaceAll(fill(r.Grant, "\x00"), "'", "''") + "'"
	dyn = strings.Replace(dyn, "\x00", "' + QUOTENAME(@pgv_user) + N'", 1)
	return fill("USE "+r.UserDB+";\n"+
		"DECLARE @pgv_user sysname = (SELECT name FROM sys.database_principals WHERE sid = SUSER_SID({login_text}));\n"+
		"IF @pgv_user IS NULL AND DATABASE_PRINCIPAL_ID({login_text}) IS NULL\nBEGIN\n    CREATE USER {login} FOR LOGIN {login};\n    SET @pgv_user = {login_text};\nEND\n"+
		"IF @pgv_user IS NULL\n    RAISERROR(N'pgvigil: a user named as the login is in this database but is not mapped to the login (left by a restore?): repair it with ALTER USER ... WITH LOGIN, then run this block again', 16, 1);\n"+
		"ELSE\nBEGIN\n    DECLARE @pgv_sql nvarchar(max) = "+dyn+";\n    EXEC sys.sp_executesql @pgv_sql;\nEND\nGO", id.quoted)
}

// ReadRights asks the server, as the connection's login, which rights of the catalogue it holds. It reads only.
func ReadRights(ctx context.Context, conn *sql.Conn, platform string) (RightsRead, error) {
	info, err := Detect(ctx, conn, platform)
	if err != nil {
		return RightsRead{}, err
	}
	var out RightsRead
	id := rightsIdentity{users: map[string]string{}}
	var own sql.NullInt64
	if err := conn.QueryRowContext(ctx, rightsIdentitySQL).Scan(&id.login, &id.quoted, &id.literal, &id.server, &id.user, &own); err != nil {
		return RightsRead{}, err
	}
	id.ownLogin = own.Int64 == 1
	out.Login, out.Server, out.Platform = id.login, id.server, string(info.Kind)
	if info.Kind != KindAzureDB {
		// the login's own user in master and in msdb, by its SID; a database it cannot read answers nothing, and the
		// block then creates the user under a guard
		for _, db := range []string{"master", "msdb"} {
			var u sql.NullString
			if err := conn.QueryRowContext(ctx, strings.Replace(rightsUserSQL, "{db}", db, 1)).Scan(&u); err == nil && u.Valid {
				id.users[db] = u.String
			}
		}
	}
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
		if r.OptIn != "" {
			out.Rights = append(out.Rights, optInState(r, id))
			out.OptIns++
			continue
		}
		switch {
		case a.Valid && a.Int64 == 1:
			st.State = "held"
		case !a.Valid && r.Null != "":
			st.State = r.Null
		default:
			st.State = "missing"
			st.Grant = grantFor(r, id)
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
	out.guard(id, info)
	return out, nil
}

// guard decides whether a script may be printed at all, and takes every statement out when it may not: a name the
// server answered that holds a line break or a control character (it could end a comment line and start a statement
// of its own), or an account with no login of its own to grant to.
func (r *RightsRead) guard(id rightsIdentity, info Info) {
	names := []string{id.login, id.server, id.user, id.users["master"], id.users["msdb"]}
	for _, s := range r.Rights {
		names = append(names, s.Databases...)
	}
	switch {
	case r.Missing == 0 && r.OptIns == 0:
		return
	case func() bool {
		for _, n := range names {
			if unsafeName(n) {
				return true
			}
		}
		return false
	}():
		r.NoScript = "no script is printed: a name this server answered (the login, the server, a user or a database) holds a line break or a control character, which could put a statement of its own into the script. Write the statements by hand from the list."
	case !id.ownLogin && info.Kind != KindAzureDB:
		r.NoScript = "no script is printed: this account has no login of its own on the server (it signs in through a Windows group's login). Grant the rights to that group's login, or create a login for the account."
	default:
		return
	}
	for i := range r.Rights {
		r.Rights[i].Grant = ""
		if unsafeName(strings.Join(r.Rights[i].Databases, "")) {
			r.Rights[i].Databases = nil
		}
	}
}

// optInState is an opt-in right's row: its Null words as the state, its block with the login filled in as the grant.
func optInState(r Right, id rightsIdentity) RightState {
	return RightState{Key: r.Key, Name: r.Name, For: r.For, Core: r.Core, State: r.Null,
		Grant: strings.NewReplacer("{login}", id.quoted).Replace(r.OptIn)}
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
// nothing, then each missing right's statement under a comment naming it. "" when nothing is missing or no script
// may be printed (NoScript says why). Every name in it is one guard let through: none holds a line break.
func (r RightsRead) Script(at string) string {
	if (r.Missing == 0 && r.OptIns == 0) || r.NoScript != "" {
		return ""
	}
	var b strings.Builder
	if r.Missing == 0 {
		fmt.Fprintf(&b, "-- pgvigil: nothing is missing for its monitoring login %s on %s (read %s); an opt-in block follows, every line a comment.\n", r.Login, r.Server, at)
	} else {
		fmt.Fprintf(&b, "-- pgvigil: the rights its monitoring login %s lacks on %s (read %s).\n", r.Login, r.Server, at)
	}
	b.WriteString("-- Run it as an administrator of that server. pgvigil did not run it and never does.\n")
	for _, s := range r.Rights {
		if s.Grant == "" {
			continue
		}
		kind := "optional"
		switch {
		case s.Core:
			kind = "needed"
		case s.State != "missing":
			kind = "an opt-in, every line a comment"
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
