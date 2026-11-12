package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// reportsCollector is mssql_reports: what the Reports tree (task 169) shows and no other collection reads - every
// server role's members, the SQL logins with their password age, the error log's failed logins, each database's
// extended properties, the two columns of the service list the services read does not keep, and the largest tables
// of each database. Hourly; nothing is written to, or created on, the monitored server.
//
// Rights, per part (a part the login may not read is named in a collector_error row and its rows stored earlier stay):
//
//	role_members         sys.server_role_members, sys.server_principals - VIEW ANY DEFINITION (without it a login
//	                     sees its own name, the fixed roles and the system logins only: the list would be short, so
//	                     it is not read)
//	sql_logins           sys.sql_logins with LOGINPROPERTY (PasswordLastSetTime, DaysUntilExpiration, IsExpired,
//	                     IsLocked, BadPasswordCount) - VIEW ANY DEFINITION, as above
//	failed_logins        the current error log's 'Login failed' lines of the last reportFailedLookback, through
//	                     master.dbo.xp_readerrorlog (EXECUTE on it: sysadmin or a grant), else sys.sp_readerrorlog
//	                     (securityadmin; SQL Server 2022 and later also VIEW SERVER STATE or VIEW ANY ERROR LOG). The
//	                     error log reader (mssql_errorlog) passes these lines over as noise, so this part reads them
//	services             sys.dm_server_services (filename, cluster_nodename) - VIEW SERVER STATE
//	extended_properties  sys.extended_properties class 0 in every ONLINE database the login can enter, through that
//	                     database's sys.sp_executesql - VIEW ANY DEFINITION
//	table_sizes          sys.dm_db_partition_stats with sys.objects in the same pass, the reportTopTables largest
//	                     tables of each database - VIEW SERVER STATE and VIEW ANY DEFINITION (without the second the
//	                     catalog lists only the tables the login has a right on)
//
// The pass over the databases starts at a different database each hour (the list rotated by the hour), so a server
// whose pass the deadline cuts reaches every database over a day; a local secondary replica of an availability group
// is not entered (its primary's tables are the same). Not on Azure SQL Database: it has no server roles of its own
// beyond the logical server's and no service list.
type reportsCollector struct{}

func init() { Register(reportsCollector{}) }

const (
	reportTopTables      = 50            // the tables kept per database and read (the largest by reserved space)
	reportFailedLookback = 3 * time.Hour // each hourly read looks back this far: two missed runs lose no line
	reportFailedMax      = 20000         // the lines one read hands over at most (the newest)
)

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

// the server's clock and its offset from UTC, for the error log's local times
const reportClockSQL = `SELECT CONVERT(varchar(23), GETDATE(), 126) AS now_local, DATEPART(TZOFFSET, SYSDATETIMEOFFSET()) AS offset_min`

// the 'Login failed' lines of the current log since @s (the server's local time), newest first; xp_readerrorlog
// searches the file itself, sp_readerrorlog hands over every matching line of the file (the time is judged here)
const (
	reportFailedXP = `DECLARE @s datetime = CONVERT(datetime, '%s', 126);
EXEC master.dbo.xp_readerrorlog 0, 1, N'Login failed', NULL, @s, NULL, N'desc';`
	reportFailedSP = `EXEC sys.sp_readerrorlog 0, 1, N'Login failed';`
)

// reportDatabasesSQL: every database the server lists (its name goes to the import, which marks the properties of a
// database no longer listed as gone) and whether the pass enters it: ONLINE, the login has access, not tempdb, not a
// database snapshot, not a local secondary replica. QUOTENAME on the server makes the name safe inside the EXEC below.
const reportDatabasesFmt = `SELECT CAST(d.name AS nvarchar(256)) AS name, QUOTENAME(d.name) AS quoted,
  CASE WHEN d.state = 0 AND d.database_id <> 2 AND d.source_database_id IS NULL AND HAS_DBACCESS(d.name) = 1 AND %s = 0 THEN 1 ELSE 0 END AS can_enter
FROM sys.databases d
ORDER BY d.name`

// the local secondary test of indexes.go (userDBLocalSecondary), only where Always On is enabled
func reportDatabasesSQL(hadr bool) string {
	if hadr {
		return fmt.Sprintf(reportDatabasesFmt, userDBLocalSecondary)
	}
	return fmt.Sprintf(reportDatabasesFmt, "0")
}

// a binary value is shown as its 0x text (CONVERT style 1): read as nvarchar its bytes would become characters, a
// zero byte a NUL that no JSON payload may carry
const reportPropsSQL = `EXEC %s.sys.sp_executesql N'SELECT CAST(name AS nvarchar(256)) AS property,
  CAST(CASE WHEN SQL_VARIANT_PROPERTY(value, ''BaseType'') IN (''binary'', ''varbinary'')
            THEN CONVERT(nvarchar(4000), CONVERT(varbinary(1998), value), 1)
            ELSE CONVERT(nvarchar(4000), value) END AS nvarchar(4000)) AS value
FROM sys.extended_properties WHERE class = 0'`

// reportTablesSQL: the largest tables of one database by reserved space; data = the heap or clustered index's
// in-row, LOB and row-overflow pages (index_id 0 and 1), index = the rest of the pages used (the other indexes, the
// clustered index's upper levels), as sp_spaceused counts them. Internal tables (XML, spatial, full-text) are not
// rolled up into their parent table.
const reportTablesSQL = `EXEC %s.sys.sp_executesql N'SELECT TOP (%d) CAST(s.name AS nvarchar(256)) AS schema_name, CAST(o.name AS nvarchar(256)) AS table_name,
  SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) AS row_count,
  SUM(ps.reserved_page_count) * 8 AS reserved_kb, SUM(ps.used_page_count) * 8 AS used_kb,
  SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.in_row_data_page_count + ps.lob_used_page_count + ps.row_overflow_used_page_count ELSE 0 END) * 8 AS data_kb,
  (SUM(ps.used_page_count) - SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.in_row_data_page_count + ps.lob_used_page_count + ps.row_overflow_used_page_count ELSE 0 END)) * 8 AS index_kb
FROM sys.dm_db_partition_stats ps
JOIN sys.objects o ON o.object_id = ps.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.type = ''U'' AND o.is_ms_shipped = 0
GROUP BY s.name, o.name
ORDER BY SUM(ps.reserved_page_count) DESC, s.name, o.name'`

func reportPart(name, status, note string) []collect.Row {
	out := []collect.Row{{"kind": "part", "part": name, "status": status, "note": note}}
	if status != "read" || note != "" {
		out = append(out, collect.Row{"kind": "collector_error", "source": name, "message": note})
	}
	return out
}

func (reportsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	var out []collect.Row
	read := func(name, query string) {
		rows, err := QueryRows(ctx, conn, query)
		if err != nil {
			out = append(out, reportPart(name, "failed", "the read failed: "+err.Error())...)
			return
		}
		out = append(out, rows...)
		out = append(out, reportPart(name, "read", "")...)
	}
	const noVAD = "the login lacks VIEW ANY DEFINITION: without it the server lists only the login's own name, the fixed roles and the system logins"
	if info.ViewAnyDefinition {
		read("role_members", fmt.Sprintf(reportRoleMembersSQL, utcText("m.create_date"), utcText("m.modify_date")))
		read("sql_logins", fmt.Sprintf(reportLoginsSQL, utcText("l.create_date"), utcText("l.modify_date"),
			utcText("CAST(LOGINPROPERTY(l.name, 'PasswordLastSetTime') AS datetime)")))
	} else {
		out = append(out, reportPart("role_members", "no right", noVAD)...)
		out = append(out, reportPart("sql_logins", "no right", noVAD)...)
	}
	out = append(out, reportFailedLogins(ctx, conn)...)
	if info.ViewServerState {
		read("services", reportServicesSQL)
	} else {
		out = append(out, reportPart("services", "no right", "the login lacks VIEW SERVER STATE: sys.dm_server_services was not read")...)
	}
	out = append(out, reportPerDatabase(ctx, conn, info, time.Now())...)
	return out, nil
}

// reportFailedLogins reads the 'Login failed' lines of the current error log back to reportFailedLookback, each with
// its local time, its time in UTC (the server's offset now) and its place among identical lines of the same time.
func reportFailedLogins(ctx context.Context, conn *sql.Conn) []collect.Row {
	clock, err := QueryRows(ctx, conn, reportClockSQL)
	if err != nil || len(clock) == 0 {
		why := "the server's clock was not read"
		if err != nil {
			why += ": " + err.Error()
		}
		return reportPart("failed_logins", "failed", why)
	}
	nowText, _ := clock[0]["now_local"].(string)
	off, _ := asInt(clock[0]["offset_min"])
	now, err := time.Parse("2006-01-02T15:04:05", nowText)
	if err != nil {
		return reportPart("failed_logins", "failed", "the server's clock could not be read: "+nowText)
	}
	since := now.Add(-reportFailedLookback)
	lines, err := QueryRows(ctx, conn, fmt.Sprintf(reportFailedXP, since.Format("2006-01-02T15:04:05.000")))
	if err != nil {
		var err2 error
		if lines, err2 = QueryRows(ctx, conn, reportFailedSP); err2 != nil {
			return reportPart("failed_logins", "no right", "the login may not read the error log: it needs EXECUTE on master.dbo.xp_readerrorlog, "+
				"or securityadmin (SQL Server 2022 and later: VIEW SERVER STATE or VIEW ANY ERROR LOG) for sys.sp_readerrorlog ("+err2.Error()+")")
		}
	}
	return append(reportFailedRows(lines, since, int(off)), reportPart("failed_logins", "read", "")...)
}

// reportFailedRows turns the reader's lines (LogDate, ProcessInfo, Text) into failed_login rows: the ones at or after
// since, the newest reportFailedMax, each line's place among identical lines of its time counted so a later read that
// sees the same lines gives the same keys. LogDate is the server's local clock as zone-less text (QueryRows'
// contract for datetime); since is on the same clock.
func reportFailedRows(lines []collect.Row, since time.Time, offsetMin int) []collect.Row {
	var out []collect.Row
	seen := map[string]int{}
	for _, l := range lines {
		lt, _ := l["LogDate"].(string)
		text, _ := l["Text"].(string)
		at, err := time.Parse("2006-01-02T15:04:05", lt)
		if err != nil || !strings.HasPrefix(text, "Login failed") || at.Before(since) {
			continue
		}
		local := at.Format("2006-01-02T15:04:05.000")
		k := local + "|" + text
		seen[k]++
		// the wall clock as written (parsed as UTC) less the server's offset
		utc := at.Add(-time.Duration(offsetMin) * time.Minute)
		out = append(out, collect.Row{"kind": "failed_login", "logged_local": local, "logged_utc": utc.Format(time.RFC3339Nano),
			"text": strings.ReplaceAll(text, "\x00", ""), "seq": seen[k]})
		if len(out) >= reportFailedMax {
			break
		}
	}
	return out
}

// reportPerDatabase is the one pass over the databases: each one's extended properties and largest tables. A database
// whose read fails keeps what an earlier read stored (no dbread row for it); the pass starts at the hour's place in the
// list and stops 10 seconds before the run's deadline, naming the databases it did not reach.
func reportPerDatabase(ctx context.Context, conn *sql.Conn, info Info, now time.Time) []collect.Row {
	var out []collect.Row
	props, tables := info.ViewAnyDefinition, info.ViewServerState && info.ViewAnyDefinition
	dbs, err := QueryRows(ctx, conn, reportDatabasesSQL(info.HADREnabled))
	if err != nil {
		note := "the database list failed: " + err.Error()
		for _, p := range []struct {
			name string
			on   bool
		}{{"extended_properties", props}, {"table_sizes", tables}} {
			if p.on {
				out = append(out, reportPart(p.name, "failed", note)...)
			}
		}
		if !props {
			out = append(out, reportPart("extended_properties", "no right", "the login lacks VIEW ANY DEFINITION: not read")...)
		}
		if !tables {
			out = append(out, reportPart("table_sizes", "no right", reportTablesRight(info))...)
		}
		return out
	}
	var enter []collect.Row
	for _, db := range dbs {
		name, _ := db["name"].(string)
		if name == "" {
			continue
		}
		out = append(out, collect.Row{"kind": "dbname", "database_name": name})
		if n, _ := asInt(db["can_enter"]); n == 1 {
			enter = append(enter, db)
		}
	}
	// the hour's start in the list: a pass the deadline cuts reaches the rest in the next hours
	if len(enter) > 1 {
		k := int(now.Unix()/3600) % len(enter)
		enter = append(enter[k:], enter[:k]...)
	}
	stop, hasStop := ctx.Deadline()
	var propFailed, tableFailed []string
	cut := 0
	for _, db := range enter {
		name, _ := db["name"].(string)
		quoted, _ := db["quoted"].(string)
		if cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second) {
			cut++
			continue
		}
		if props {
			rows, err := QueryRows(ctx, conn, fmt.Sprintf(reportPropsSQL, quoted))
			if err != nil {
				if ctx.Err() != nil {
					cut++
					continue
				}
				propFailed = append(propFailed, name)
			} else {
				out = append(out, collect.Row{"kind": "dbread", "database_name": name})
				for _, r := range rows {
					if v, ok := r["value"].(string); ok {
						r["value"] = strings.ReplaceAll(v, "\x00", "")
					}
					r["kind"], r["database_name"] = "db_property", name
					out = append(out, r)
				}
			}
		}
		if tables {
			rows, err := QueryRows(ctx, conn, fmt.Sprintf(reportTablesSQL, quoted, reportTopTables))
			if err != nil {
				if ctx.Err() != nil {
					cut++
					continue
				}
				tableFailed = append(tableFailed, name)
			} else {
				for _, r := range rows {
					r["kind"], r["database_name"] = "table_size", name
					out = append(out, r)
				}
			}
		}
	}
	state := func(part string, on bool, why string, failed []string) {
		if !on {
			out = append(out, reportPart(part, "no right", why)...)
			return
		}
		var parts []string
		if len(failed) > 0 {
			parts = append(parts, fmt.Sprintf("%d database(s) not read (%s)", len(failed), firstFew(failed, 5)))
		}
		if cut > 0 {
			parts = append(parts, fmt.Sprintf("the run's deadline came before %d database(s): the next hours start further on", cut))
		}
		// the databases that were read are applied; the others keep their rows
		out = append(out, reportPart(part, "read", strings.Join(parts, "; "))...)
	}
	state("extended_properties", props, "the login lacks VIEW ANY DEFINITION: not read", propFailed)
	state("table_sizes", tables, reportTablesRight(info), tableFailed)
	return out
}

func reportTablesRight(info Info) string {
	switch {
	case !info.ViewServerState && !info.ViewAnyDefinition:
		return "the login lacks VIEW SERVER STATE and VIEW ANY DEFINITION: not read"
	case !info.ViewServerState:
		return "the login lacks VIEW SERVER STATE: sys.dm_db_partition_stats was not read"
	default:
		return "the login lacks VIEW ANY DEFINITION: sys.objects would list only the tables the login has a right on, so the sizes were not read"
	}
}
