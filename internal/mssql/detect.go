package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
)

// Kind is what runs the SQL Server; it is the instance's platform in the repository.
type Kind string

// The kinds of SQL Server instance.
const (
	KindServer  Kind = "sqlserver"    // a server someone runs: a machine, a VM, a container
	KindRDS     Kind = "rdssqlserver" // Amazon RDS for SQL Server
	KindAzureDB Kind = "azuresqldb"   // Azure SQL Database (one database is the instance)
	KindAzureMI Kind = "azuresqlmi"   // Azure SQL Managed Instance
	// Google Cloud SQL for SQL Server: its server role CustomerDbRootRole (the sqlserver user is its member) on a
	// Linux host, the role visible to a login only with VIEW ANY DEFINITION; without it the configuration's
	// platform: cloudsql names it
	KindCloudSQL Kind = "cloudsqlsqlserver"
)

// Info is what a connection told about the server and about the login's rights.
type Info struct {
	Kind           Kind
	Version        string // the first line of @@VERSION
	ProductVersion string // 16.0.4135.4
	Major          int    // 13 = SQL Server 2016, 14 = 2017, 15 = 2019, 16 = 2022, 17 = 2025; Azure SQL Managed Instance and Azure SQL Database answer 12 whatever engine they run (the collections ask Kind before Major)
	Minor          int
	Build          int
	VersionNum     int // Major * 10000 + Minor: 160000 on SQL Server 2022, 170000 on 2025
	Edition        string
	EngineEdition  int // SERVERPROPERTY('EngineEdition'): 2 Standard, 3 Enterprise, 4 Express, 5 SQL Database, 8 Managed Instance, 9 Azure SQL Edge (kept as a server); 6 and 11 (Synapse) are refused
	ServerName     string
	HADREnabled    bool
	// what the login may read: a collection says "skipped" with the missing right instead of failing
	ViewServerState   bool
	ViewAnyDefinition bool
	MsdbAccess        bool
}

// detectSQL: on Azure SQL Database (engine edition 5) the database is the instance and VIEW DATABASE STATE is the right
// Microsoft's DMV pages name, except on Basic, S0, S1 and in an elastic pool, where they ask for the server admin or
// ##MS_ServerStateReader##: there the server-level check stays.
const detectSQL = `SELECT
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
  CAST(SERVERPROPERTY('Edition') AS nvarchar(128)),
  CAST(SERVERPROPERTY('EngineEdition') AS int),
  CAST(ISNULL(@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128))) AS nvarchar(128)),
  CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int),
  CAST(ISNULL(CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5
         AND CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(128)) NOT IN (N'Basic', N'S0', N'S1', N'ElasticPool')
    THEN HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') ELSE HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') END, 0) AS int),
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION'), 0) AS int),
  CAST(ISNULL(HAS_DBACCESS('msdb'), 0) AS int),
  CAST(CASE WHEN DB_ID('rdsadmin') IS NOT NULL THEN 1 ELSE 0 END AS int),
  CAST(LEFT(@@VERSION, 400) AS nvarchar(400))`

// cloudSQLMarkSQL: Cloud SQL's own server role on a Linux host (a role of that name carried to a Windows server
// someone runs is not Cloud SQL). A statement of its own, asked only of a server that is neither Azure nor RDS: the
// batch above runs on every platform, Azure SQL Database's included, and stays as proven there; on a server older
// than SQL Server 2017 (no sys.dm_os_host_info) it fails and the server is not Cloud SQL. Google creates the msdb
// procedure gcloudsql_bulk_insert only once its bulk-insert flag is on, so it is not a mark.
const cloudSQLMarkSQL = `SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'CustomerDbRootRole' AND type = 'R')
  AND EXISTS (SELECT 1 FROM sys.dm_os_host_info WHERE host_platform = N'Linux') THEN 1 ELSE 0 END AS int)`

// Detect reads what the server is and what the login may read. forced is the config's platform: auto (or empty)
// keeps what the server says, anything else names the kind.
func Detect(ctx context.Context, conn *sql.Conn, forced string) (Info, error) {
	var in Info
	var pv, ed, name, ver sql.NullString
	var ee, hadr, vss, vad, msdb, rds sql.NullInt64
	if err := conn.QueryRowContext(ctx, detectSQL).Scan(&pv, &ed, &ee, &name, &hadr, &vss, &vad, &msdb, &rds, &ver); err != nil {
		return in, fmt.Errorf("sql server detect: %w", err)
	}
	in.ProductVersion, in.Edition, in.ServerName = pv.String, ed.String, name.String
	in.EngineEdition = int(ee.Int64)
	if err := supported(in.EngineEdition); err != nil {
		return in, err
	}
	in.HADREnabled = hadr.Int64 == 1
	in.ViewServerState, in.ViewAnyDefinition, in.MsdbAccess = vss.Int64 == 1, vad.Int64 == 1, msdb.Int64 == 1
	in.Version, _, _ = strings.Cut(ver.String, "\n")
	in.Version = strings.TrimSpace(in.Version)
	in.Major, in.Minor, in.Build = parseVersion(in.ProductVersion)
	in.VersionNum = in.Major*10000 + in.Minor
	gcs := false
	if askCloudSQL(in.EngineEdition, rds.Int64 == 1, forced) {
		var mark sql.NullInt64
		gcs = conn.QueryRowContext(ctx, cloudSQLMarkSQL).Scan(&mark) == nil && mark.Int64 == 1
	}
	in.Kind = kindOf(in.EngineEdition, rds.Int64 == 1, gcs, forced)
	return in, nil
}

// supported refuses the engine editions that answer on the SQL Server protocol and are not a SQL Server: Azure
// Synapse's dedicated (6) and serverless (11) pools have neither the DMVs nor msdb the collections read.
func supported(engineEdition int) error {
	switch engineEdition {
	case 6, 11:
		return fmt.Errorf("sql server detect: engine edition %d is Azure Synapse Analytics, which pgvigil's SQL Server engine does not monitor (no sys.dm_os_sys_info, no msdb); remove the instance or point it at a SQL Server", engineEdition)
	}
	return nil
}

// askCloudSQL says whether Cloud SQL's mark is asked: a SQL Server box edition (Standard, Enterprise, Express), no
// rdsadmin, and no platform named in the configuration.
func askCloudSQL(engineEdition int, hasRDSAdmin bool, forced string) bool {
	return (forced == "" || forced == "auto") && !hasRDSAdmin && engineEdition >= 2 && engineEdition <= 4
}

// kindOf names the platform: the config's word when it gives one, else the engine edition, RDS's own database and
// Cloud SQL's role or procedures (read after RDS's: a server cannot be both).
func kindOf(engineEdition int, hasRDSAdmin, hasCloudSQL bool, forced string) Kind {
	switch forced {
	case "onprem":
		return KindServer
	case "rds":
		return KindRDS
	case "azuresqldb":
		return KindAzureDB
	case "azuresqlmi":
		return KindAzureMI
	case "cloudsql":
		return KindCloudSQL
	}
	switch {
	case engineEdition == 5:
		return KindAzureDB
	case engineEdition == 8:
		return KindAzureMI
	case hasRDSAdmin:
		return KindRDS
	case hasCloudSQL:
		return KindCloudSQL
	}
	return KindServer
}

// parseVersion splits a product version (16.0.4135.4) into major, minor and build; a part it cannot read is 0.
func parseVersion(v string) (major, minor, build int) {
	p := strings.Split(strings.TrimSpace(v), ".")
	at := func(i int) int {
		if i >= len(p) {
			return 0
		}
		n, err := strconv.Atoi(p[i])
		if err != nil || n < 0 {
			return 0
		}
		return n
	}
	return at(0), at(1), at(2)
}
