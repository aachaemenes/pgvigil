package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// reportsCollector is mssql_reports: what the Reports tree (task 169) shows and no other collection reads - every
// server role's members, the SQL logins with their password age, each database's extended properties, the two
// columns of the service list the services read does not keep, and the largest tables of each database. Hourly;
// nothing is written to, or created on, the monitored server.
//
// Rights, per part (a part the login may not read is named in a collector_error row and its rows stored earlier stay):
//
//	role_members         sys.server_role_members, sys.server_principals - VIEW ANY DEFINITION (without it a login
//	                     sees its own name, the fixed roles and the system logins only: the list would be short, so
//	                     it is not read)
//	sql_logins           sys.sql_logins with LOGINPROPERTY (PasswordLastSetTime, DaysUntilExpiration, IsExpired,
//	                     IsLocked, BadPasswordCount) - VIEW ANY DEFINITION, as above
//	services             sys.dm_server_services (filename, cluster_nodename) - VIEW SERVER STATE
//	extended_properties  sys.extended_properties class 0 in every ONLINE database the login can enter, through that
//	                     database's sys.sp_executesql - VIEW ANY DEFINITION (or VIEW DEFINITION in the database)
//	table_sizes          sys.dm_db_partition_stats in the same pass, the reportTopTables largest tables of each
//	                     database - VIEW SERVER STATE (VIEW DATABASE STATE in each database)
//
// Not on Azure SQL Database: it has no server roles of its own beyond the logical server's and no service list.
type reportsCollector struct{}

func init() { Register(reportsCollector{}) }

// reportTopTables: the tables kept per database and read (the largest by reserved space)
const reportTopTables = 50

func (reportsCollector) Name() string                   { return Prefix + "reports" }
func (reportsCollector) DefaultInterval() time.Duration { return time.Hour }
func (reportsCollector) Timeout() time.Duration         { return 3 * time.Minute }

func (reportsCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not on Azure SQL Database (no server roles, SQL logins or service list of its own to read)"
	case !info.ViewAnyDefinition && !info.ViewServerState:
		return false, "the login lacks VIEW ANY DEFINITION and VIEW SERVER STATE: neither the role members, the logins, the properties nor the table sizes are readable"
	}
	return true, ""
}

const reportRoleMembersSQL = `SELECT 'role_member' AS kind, CAST(r.name AS nvarchar(256)) AS role_name, CAST(m.name AS nvarchar(256)) AS login_name,
  CAST(m.type AS nvarchar(2)) AS login_type, CAST(m.type_desc AS nvarchar(60)) AS type_desc, CAST(m.is_disabled AS int) AS is_disabled,
  ` + "%s AS created_utc, %s AS modified_utc" + `
FROM sys.server_role_members rm
JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id`

const reportLoginsSQL = `SELECT 'sql_login' AS kind, CAST(l.name AS nvarchar(256)) AS login_name, CAST(l.is_disabled AS int) AS is_disabled,
  %s AS created_utc, %s AS modified_utc,
  %s AS password_set_utc,
  CAST(l.is_policy_checked AS int) AS is_policy_checked, CAST(l.is_expiration_checked AS int) AS is_expiration_checked,
  CAST(LOGINPROPERTY(l.name, 'DaysUntilExpiration') AS int) AS days_until_expiration,
  CAST(LOGINPROPERTY(l.name, 'IsExpired') AS int) AS is_expired, CAST(LOGINPROPERTY(l.name, 'IsLocked') AS int) AS is_locked,
  CAST(LOGINPROPERTY(l.name, 'BadPasswordCount') AS int) AS bad_password_count
FROM sys.sql_logins l
WHERE l.name NOT LIKE '##%%##'`

const reportServicesSQL = `SELECT 'service_ext' AS kind, CAST(servicename AS nvarchar(256)) AS service_name,
  CAST(filename AS nvarchar(512)) AS filename, CAST(cluster_nodename AS nvarchar(256)) AS cluster_nodename
FROM sys.dm_server_services`

// reportDatabasesSQL: the databases a per-database read enters (ONLINE, the login has access, not tempdb, not a
// database snapshot); QUOTENAME on the server makes the name safe inside the EXEC below.
const reportDatabasesSQL = `SELECT CAST(name AS nvarchar(256)) AS name, QUOTENAME(name) AS quoted
FROM sys.databases
WHERE state = 0 AND database_id <> 2 AND source_database_id IS NULL AND HAS_DBACCESS(name) = 1
ORDER BY name`

const reportPropsSQL = `EXEC %s.sys.sp_executesql N'SELECT CAST(name AS nvarchar(256)) AS property,
  CAST(CONVERT(nvarchar(4000), value) AS nvarchar(4000)) AS value
FROM sys.extended_properties WHERE class = 0'`

// reportTablesSQL: the largest tables of one database by reserved space; data = the heap or clustered index's
// in-row, LOB and row-overflow pages (index_id 0 and 1), index = what the other indexes use.
const reportTablesSQL = `EXEC %s.sys.sp_executesql N'SELECT TOP (%d) CAST(s.name AS nvarchar(256)) AS schema_name, CAST(o.name AS nvarchar(256)) AS table_name,
  SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) AS row_count,
  SUM(ps.reserved_page_count) * 8 AS reserved_kb, SUM(ps.used_page_count) * 8 AS used_kb,
  SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.in_row_data_page_count + ps.lob_used_page_count + ps.row_overflow_used_page_count ELSE 0 END) * 8 AS data_kb,
  SUM(CASE WHEN ps.index_id > 1 THEN ps.used_page_count ELSE 0 END) * 8 AS index_kb
FROM sys.dm_db_partition_stats ps
JOIN sys.objects o ON o.object_id = ps.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type = ''U'' AND o.is_ms_shipped = 0
GROUP BY s.name, o.name
ORDER BY SUM(ps.reserved_page_count) DESC, s.name, o.name'`

func (reportsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	var out []collect.Row
	part := func(name, status, note string) {
		out = append(out, collect.Row{"kind": "part", "part": name, "status": status, "note": note})
		if status != "read" {
			out = append(out, collect.Row{"kind": "collector_error", "source": name, "message": note})
		}
	}
	read := func(name, query string) {
		rows, err := QueryRows(ctx, conn, query)
		if err != nil {
			part(name, "failed", "the read failed: "+err.Error())
			return
		}
		out = append(out, rows...)
		part(name, "read", "")
	}
	const noVAD = "the login lacks VIEW ANY DEFINITION: without it the server lists only the login's own name, the fixed roles and the system logins"
	if info.ViewAnyDefinition {
		read("role_members", fmt.Sprintf(reportRoleMembersSQL, utcText("m.create_date"), utcText("m.modify_date")))
		read("sql_logins", fmt.Sprintf(reportLoginsSQL, utcText("l.create_date"), utcText("l.modify_date"),
			utcText("CAST(LOGINPROPERTY(l.name, 'PasswordLastSetTime') AS datetime)")))
	} else {
		part("role_members", "no right", noVAD)
		part("sql_logins", "no right", noVAD)
	}
	if info.ViewServerState {
		read("services", reportServicesSQL)
	} else {
		part("services", "no right", "the login lacks VIEW SERVER STATE: sys.dm_server_services was not read")
	}
	out = append(out, reportPerDatabase(ctx, conn, info)...)
	return out, nil
}

// reportPerDatabase is the one pass over the databases: each one's extended properties and largest tables. A database
// whose read fails keeps what an earlier read stored (no dbread row for it); the pass stops 10 seconds before the
// run's deadline and says how many databases it did not reach.
func reportPerDatabase(ctx context.Context, conn *sql.Conn, info Info) []collect.Row {
	var out []collect.Row
	props, tables := info.ViewAnyDefinition, info.ViewServerState
	dbs, err := QueryRows(ctx, conn, reportDatabasesSQL)
	if err != nil {
		note := "the database list failed: " + err.Error()
		out = append(out, collect.Row{"kind": "part", "part": "extended_properties", "status": "failed", "note": note},
			collect.Row{"kind": "part", "part": "table_sizes", "status": "failed", "note": note},
			collect.Row{"kind": "collector_error", "source": "sys.databases", "message": note})
		return out
	}
	stop, hasStop := ctx.Deadline()
	var propFailed, tableFailed []string
	cut := 0
	for _, db := range dbs {
		name, _ := db["name"].(string)
		quoted, _ := db["quoted"].(string)
		if name == "" || quoted == "" {
			continue
		}
		if cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second) {
			cut++
			continue
		}
		if props {
			rows, err := QueryRows(ctx, conn, fmt.Sprintf(reportPropsSQL, quoted))
			if err != nil {
				propFailed = append(propFailed, name)
			} else {
				out = append(out, collect.Row{"kind": "dbread", "database_name": name})
				for _, r := range rows {
					r["kind"], r["database_name"] = "db_property", name
					out = append(out, r)
				}
			}
		}
		if tables {
			rows, err := QueryRows(ctx, conn, fmt.Sprintf(reportTablesSQL, quoted, reportTopTables))
			if err != nil {
				tableFailed = append(tableFailed, name)
			} else {
				for _, r := range rows {
					r["kind"], r["database_name"] = "table_size", name
					out = append(out, r)
				}
			}
		}
	}
	state := func(part string, on bool, right string, failed []string) {
		switch {
		case !on:
			msg := "the login lacks " + right + ": not read"
			out = append(out, collect.Row{"kind": "part", "part": part, "status": "no right", "note": msg},
				collect.Row{"kind": "collector_error", "source": part, "message": msg})
		case len(failed) > 0 || cut > 0:
			msg := fmt.Sprintf("%d database(s) not read (%s)", len(failed), firstFew(failed, 5))
			if cut > 0 {
				msg += fmt.Sprintf("; the run's deadline came before %d database(s)", cut)
			}
			// the databases that were read are applied; the others keep their rows
			out = append(out, collect.Row{"kind": "part", "part": part, "status": "read", "note": msg},
				collect.Row{"kind": "collector_error", "source": part, "message": msg})
		default:
			out = append(out, collect.Row{"kind": "part", "part": part, "status": "read", "note": ""})
		}
	}
	state("extended_properties", props, "VIEW ANY DEFINITION", propFailed)
	state("table_sizes", tables, "VIEW SERVER STATE", tableFailed)
	return out
}
