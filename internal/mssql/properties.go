package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// propertiesCollector is mssql_properties: what the instance is, hourly, one row per property (DBA Dash's Info
// page), and the repository keeps the history of each value's changes (0084).
//
//   - Server: edition, version and level, collation, clustered, Always On enabled, the machine's and the server's
//     name, max degree of parallelism and the cost threshold (SERVERPROPERTY and sys.configurations: any login).
//   - Processor: logical CPUs, sockets, cores per socket, the hyperthread ratio, NUMA nodes, soft NUMA, the affinity
//     type, the schedulers online and offline, max worker threads, the hypervisor (sys.dm_os_sys_info and
//     sys.dm_os_schedulers) and the Windows power plan.
//   - Memory: the machine's memory, max and min server memory, max server memory as a per cent of the machine, the
//     memory model.
//   - TempDB: the data and log files, their sizes, whether the data files are one size (tempdb.sys.database_files:
//     any login). The sizes move by themselves, so they are shown and never logged as a change.
//   - Host: the platform, the distribution and the release (sys.dm_os_host_info, SQL Server 2017 and later;
//     sys.dm_os_windows_info before).
//
// sys.dm_os_sys_info gained socket_count, cores_per_socket and numa_node_count with SQL Server 2016 SP2 and 2017,
// and softnuma_configuration_desc and sql_memory_model_desc with 2016: the collector asks sys.all_columns which the
// server has and reads those.
//
// The power plan is the one value SQL Server does not hold: on a Windows server someone runs it is read from the
// registry with xp_regread (HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes, ActivePowerScheme), a
// read. On Linux, Amazon RDS and Azure SQL Managed Instance the row says 'not read' and why. The server's start
// time is not a property: the DMV writes it in the local clock and a daylight-saving shift would log a change.
//
// Rights: the Server and TempDB groups need only the public role; the rest needs VIEW SERVER STATE (on SQL Server
// 2022 VIEW SERVER PERFORMANCE STATE is enough): without it those rows say so and the run is partial. Runs on SQL
// Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; not on Azure SQL Database.
type propertiesCollector struct{}

func init() { Register(propertiesCollector{}) }

func (propertiesCollector) Name() string                   { return Prefix + "properties" }
func (propertiesCollector) DefaultInterval() time.Duration { return time.Hour }
func (propertiesCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database: the processors, the memory and tempdb there are the service's, not the database's"
	}
	return true, ""
}

// propsServerSQL: readable by any login.
const propsServerSQL = `SELECT
  CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
  CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
  CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(128)) AS product_update,
  CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS collation,
  CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered,
  CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS hadr_enabled,
  CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS machine_name,
  CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS server_name,
  (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = N'max degree of parallelism') AS maxdop,
  (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = N'cost threshold for parallelism') AS cost_threshold,
  (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = N'max server memory (MB)') AS max_memory_mb,
  (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = N'min server memory (MB)') AS min_memory_mb`

// propsTempdbSQL: tempdb's files as they stand now (type 0 = data, 1 = log; size in 8 KB pages), whole megabytes.
const propsTempdbSQL = `SELECT
  CAST(SUM(CASE WHEN type = 0 THEN 1 ELSE 0 END) AS bigint) AS data_files,
  SUM(CASE WHEN type = 0 THEN CAST(size AS bigint) ELSE 0 END) * 8 / 1024 AS data_mb,
  CAST(CASE WHEN MIN(CASE WHEN type = 0 THEN size END) = MAX(CASE WHEN type = 0 THEN size END) THEN 1 ELSE 0 END AS int) AS even_size,
  CAST(SUM(CASE WHEN type = 1 THEN 1 ELSE 0 END) AS bigint) AS log_files,
  SUM(CASE WHEN type = 1 THEN CAST(size AS bigint) ELSE 0 END) * 8 / 1024 AS log_mb
FROM tempdb.sys.database_files`

// propsSysColsSQL: the columns this server's sys.dm_os_sys_info has.
const propsSysColsSQL = `SELECT CAST(name AS nvarchar(128)) AS name FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.dm_os_sys_info')`

// propsSysInfoSQL: the machine as SQL Server sees it. The five %s are the columns newer servers have, or NULL.
const propsSysInfoSQL = `SELECT CAST(si.cpu_count AS bigint) AS cpu_count, CAST(si.hyperthread_ratio AS bigint) AS hyperthread_ratio,
  CAST(si.physical_memory_kb / 1024 AS bigint) AS physical_memory_mb, CAST(si.max_workers_count AS bigint) AS max_workers,
  CAST(si.affinity_type_desc AS nvarchar(60)) AS affinity, CAST(si.virtual_machine_type_desc AS nvarchar(60)) AS virtual_machine,
  %s AS socket_count, %s AS cores_per_socket, %s AS numa_nodes, %s AS soft_numa, %s AS memory_model,
  (SELECT CAST(COUNT(*) AS bigint) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE') AS schedulers_online,
  (SELECT CAST(COUNT(*) AS bigint) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE OFFLINE') AS schedulers_offline
FROM sys.dm_os_sys_info si`

// propsHostSQL: SQL Server 2017 and later. propsWindowsSQL: before it, where the host is always Windows.
const (
	propsHostSQL = `SELECT CAST(host_platform AS nvarchar(256)) AS host_platform, CAST(host_distribution AS nvarchar(256)) AS host_distribution,
  CAST(host_release AS nvarchar(256)) AS host_release FROM sys.dm_os_host_info`
	propsWindowsSQL = `SELECT CAST(N'Windows' AS nvarchar(256)) AS host_platform, CAST(NULL AS nvarchar(256)) AS host_distribution,
  CAST(windows_release AS nvarchar(256)) AS host_release FROM sys.dm_os_windows_info`
)

// propsPowerSQL reads the active power scheme's GUID from the registry. An extended procedure reports a failure
// as a message and a return code, never as an error a TRY / CATCH sees: the code comes back with the value.
const propsPowerSQL = `DECLARE @scheme nvarchar(128), @rc int;
EXEC @rc = master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE',
  @key = N'SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes', @value_name = N'ActivePowerScheme', @value = @scheme OUTPUT;
SELECT @rc AS rc, @scheme AS scheme;`

// powerPlans names the three power schemes every Windows ships, by their GUID.
var powerPlans = map[string]string{
	"381b4222-f694-41f0-9685-ff5bb260df2e": "Balanced",
	"8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c": "High performance",
	"a1841308-3541-4fab-bc81-f71556f20b4a": "Power saver",
}

// unlimitedMemoryMB is max server memory's default: no limit.
const unlimitedMemoryMB = 2147483647

func (propertiesCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	srv, err := QueryRows(ctx, conn, propsServerSQL)
	if err != nil {
		return nil, err
	}
	if len(srv) != 1 {
		return nil, fmt.Errorf("SERVERPROPERTY returned %d rows", len(srv))
	}
	s := srv[0]
	p := &propList{}
	p.add("edition", "Server", "Edition", 100, s["edition"], "")
	p.add("product_version", "Server", "Version", 110, s["product_version"], "")
	p.add("product_level", "Server", "Level", 120, joinNonEmpty(s["product_level"], s["product_update"]), "")
	p.add("collation", "Server", "Collation", 130, s["collation"], "")
	p.add("is_clustered", "Server", "Clustered", 140, yesNo(s["is_clustered"]), "")
	p.add("hadr_enabled", "Server", "Always On availability groups enabled", 150, yesNo(s["hadr_enabled"]), "")
	p.add("machine_name", "Server", "Machine", 160, s["machine_name"], "")
	p.add("server_name", "Server", "Server name", 170, s["server_name"], "")
	p.add("maxdop", "Server", "Max degree of parallelism", 180, s["maxdop"], "")
	p.add("cost_threshold", "Server", "Cost threshold for parallelism", 190, s["cost_threshold"], "")

	var partial []collect.Row
	perfErr := perfState(ctx, conn, info, "sys.dm_os_sys_info")
	var si collect.Row
	why := "not read: the login lacks VIEW SERVER STATE"
	if perfErr == nil {
		si, err = readSysInfo(ctx, conn)
		if err != nil {
			why = "not read: " + err.Error()
			partial = append(partial, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info", "message": err.Error()})
		}
	} else {
		partial = append(partial, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info",
			"message": "the login lacks VIEW SERVER STATE: the processor, memory and host rows were not read"})
	}
	val := func(k string) any {
		if si == nil {
			return nil
		}
		return si[k]
	}
	// a column an older server does not have reads as NULL: the row says which version brought it
	older := func(k, since string) string {
		if si == nil {
			return why
		}
		if si[k] == nil {
			return "not read: sys.dm_os_sys_info has this column from " + since
		}
		return ""
	}
	note := func() string {
		if si == nil {
			return why
		}
		return ""
	}
	p.add("cpu_count", "Processor", "Logical CPUs", 200, val("cpu_count"), note())
	p.add("socket_count", "Processor", "Sockets", 210, val("socket_count"), older("socket_count", "SQL Server 2016 SP2"))
	p.add("cores_per_socket", "Processor", "Cores per socket", 220, val("cores_per_socket"), older("cores_per_socket", "SQL Server 2016 SP2"))
	p.add("hyperthread_ratio", "Processor", "Hyperthread ratio (logical CPUs per socket)", 230, val("hyperthread_ratio"), note())
	p.add("numa_nodes", "Processor", "NUMA nodes", 240, val("numa_nodes"), older("numa_nodes", "SQL Server 2016 SP2"))
	p.add("soft_numa", "Processor", "Soft NUMA", 250, val("soft_numa"), older("soft_numa", "SQL Server 2016"))
	p.add("affinity", "Processor", "Affinity", 260, val("affinity"), note())
	p.add("schedulers_online", "Processor", "Schedulers online", 270, val("schedulers_online"), note())
	offNote := note()
	if n, ok := val("schedulers_offline").(int64); ok && n > 0 {
		offNote = "CPUs SQL Server does not use: the edition's core limit, the licence or an affinity mask keeps them offline"
	}
	p.add("schedulers_offline", "Processor", "Schedulers offline", 280, val("schedulers_offline"), offNote)
	p.add("max_workers", "Processor", "Max worker threads", 290, val("max_workers"), note())
	p.add("virtual_machine", "Processor", "Virtual machine", 300, val("virtual_machine"), note())

	// the host, then the power plan (the registry of a Windows server someone runs)
	var host collect.Row
	hostWhy := why
	if si != nil {
		host, hostWhy = readHost(ctx, conn)
		if host == nil {
			partial = append(partial, collect.Row{"kind": "collector_error", "source": "sys.dm_os_host_info", "message": strings.TrimPrefix(hostWhy, "not read: ")})
		}
	}
	hval := func(k string) any {
		if host == nil {
			return nil
		}
		return host[k]
	}
	hnote := func() string {
		if host == nil {
			return hostWhy
		}
		return ""
	}
	platform, _ := hval("host_platform").(string)
	plan, planNote := powerPlan(ctx, conn, info, platform, host != nil, hostWhy)
	p.add("power_plan", "Processor", "Power plan", 310, plan, planNote)

	maxMB, _ := s["max_memory_mb"].(int64)
	physMB, _ := val("physical_memory_mb").(int64)
	p.add("physical_memory_mb", "Memory", "Physical memory (MB)", 400, val("physical_memory_mb"), note())
	maxNote := ""
	if maxMB == unlimitedMemoryMB {
		maxNote = "the default: no limit is set"
	}
	p.add("max_memory_mb", "Memory", "Max server memory (MB)", 410, s["max_memory_mb"], maxNote)
	switch {
	case si == nil:
		p.add("max_memory_pct", "Memory", "Max server memory, % of the machine", 420, nil, why)
	case maxMB == unlimitedMemoryMB || maxMB <= 0:
		p.add("max_memory_pct", "Memory", "Max server memory, % of the machine", 420, "no limit", "max server memory is at its default: SQL Server may take all of the machine's memory")
	case physMB > 0:
		p.add("max_memory_pct", "Memory", "Max server memory, % of the machine", 420, pctText(maxMB, physMB), "")
	default:
		p.add("max_memory_pct", "Memory", "Max server memory, % of the machine", 420, nil, "not read: the machine's memory read as 0")
	}
	p.add("min_memory_mb", "Memory", "Min server memory (MB)", 430, s["min_memory_mb"], "")
	p.add("memory_model", "Memory", "Memory model", 440, val("memory_model"), older("memory_model", "SQL Server 2016 SP1"))

	tdb, terr := QueryRows(ctx, conn, propsTempdbSQL)
	if terr != nil || len(tdb) != 1 {
		msg := "tempdb.sys.database_files returned no row"
		if terr != nil {
			msg = terr.Error()
		}
		partial = append(partial, collect.Row{"kind": "collector_error", "source": "tempdb.sys.database_files", "message": msg})
		for i, n := range []string{"tempdb_data_files", "tempdb_data_mb", "tempdb_even_size", "tempdb_log_files", "tempdb_log_mb"} {
			p.add(n, "TempDB", tempdbLabels[n], 500+10*i, nil, "not read: "+msg)
		}
	} else {
		t := tdb[0]
		p.add("tempdb_data_files", "TempDB", tempdbLabels["tempdb_data_files"], 500, t["data_files"], "")
		p.addUntracked("tempdb_data_mb", "TempDB", tempdbLabels["tempdb_data_mb"], 510, t["data_mb"], "the size now: it grows by itself and is not logged as a change")
		p.add("tempdb_even_size", "TempDB", tempdbLabels["tempdb_even_size"], 520, yesNo(t["even_size"]), "")
		p.add("tempdb_log_files", "TempDB", tempdbLabels["tempdb_log_files"], 530, t["log_files"], "")
		p.addUntracked("tempdb_log_mb", "TempDB", tempdbLabels["tempdb_log_mb"], 540, t["log_mb"], "the size now: it grows by itself and is not logged as a change")
	}

	p.add("host_platform", "Host", "Platform", 600, hval("host_platform"), hnote())
	distNote := hnote()
	if host != nil && host["host_distribution"] == nil {
		distNote = "not read: sys.dm_os_host_info names the distribution from SQL Server 2017"
	}
	p.add("host_distribution", "Host", "Distribution", 610, hval("host_distribution"), distNote)
	p.add("host_release", "Host", "Release", 620, hval("host_release"), hnote())
	return append(p.rows, partial...), nil
}

var tempdbLabels = map[string]string{
	"tempdb_data_files": "Data files", "tempdb_data_mb": "Data files' size (MB)", "tempdb_even_size": "Data files of one size",
	"tempdb_log_files": "Log files", "tempdb_log_mb": "Log size (MB)",
}

// readSysInfo reads sys.dm_os_sys_info with the columns this server has.
func readSysInfo(ctx context.Context, conn *sql.Conn) (collect.Row, error) {
	cols, err := QueryRows(ctx, conn, propsSysColsSQL)
	if err != nil {
		return nil, err
	}
	have := map[string]bool{}
	for _, c := range cols {
		if n, ok := c["name"].(string); ok {
			have[n] = true
		}
	}
	rows, err := QueryRows(ctx, conn, sysInfoSQL(have))
	if err != nil {
		return nil, err
	}
	if len(rows) != 1 {
		return nil, fmt.Errorf("sys.dm_os_sys_info returned %d rows", len(rows))
	}
	return rows[0], nil
}

// sysInfoSQL fills propsSysInfoSQL with the optional columns the server has (have: sys.all_columns' names).
func sysInfoSQL(have map[string]bool) string {
	col := func(name, typ string) string {
		if have[name] {
			return "CAST(si." + name + " AS " + typ + ")"
		}
		return "CAST(NULL AS " + typ + ")"
	}
	return fmt.Sprintf(propsSysInfoSQL, col("socket_count", "bigint"), col("cores_per_socket", "bigint"), col("numa_node_count", "bigint"),
		col("softnuma_configuration_desc", "nvarchar(60)"), col("sql_memory_model_desc", "nvarchar(60)"))
}

// readHost reads the host's platform and release: sys.dm_os_host_info, or before SQL Server 2017 (which has no such
// view) sys.dm_os_windows_info. nil and the reason when neither answers.
func readHost(ctx context.Context, conn *sql.Conn) (collect.Row, string) {
	rows, err := QueryRows(ctx, conn, propsHostSQL)
	if err != nil {
		rows, err = QueryRows(ctx, conn, propsWindowsSQL)
	}
	if err != nil {
		return nil, "not read: " + err.Error()
	}
	if len(rows) != 1 {
		return nil, "not read: the host view returned no row"
	}
	return rows[0], ""
}

// powerPlan is the Windows power plan and the row's note. The registry is read only on a Windows server someone
// runs: a managed service has no registry to offer and Linux has no power scheme.
func powerPlan(ctx context.Context, conn *sql.Conn, info Info, platform string, hostRead bool, hostWhy string) (any, string) {
	switch {
	case info.Kind == KindRDS:
		return nil, "not read: Amazon RDS runs the host; its power plan is not the customer's to read"
	case info.Kind == KindAzureMI:
		return nil, "not read: Azure SQL Managed Instance runs the host; it has no power plan to read"
	case !hostRead:
		return nil, "not read: the host's platform is not known (" + strings.TrimPrefix(hostWhy, "not read: ") + ")"
	case platform != "Windows":
		return nil, "not read: SQL Server on " + platform + " has no Windows power plan; the CPU governor is the host's"
	}
	rows, err := QueryRows(ctx, conn, propsPowerSQL)
	if err != nil {
		return nil, "not read: xp_regread failed: " + err.Error()
	}
	return powerPlanOf(rows)
}

// powerPlanOf turns xp_regread's answer (its return code and the scheme's GUID) into the plan's name and note.
func powerPlanOf(rows []collect.Row) (any, string) {
	if len(rows) != 1 {
		return nil, "not read: xp_regread returned no row"
	}
	guid, _ := rows[0]["scheme"].(string)
	guid = strings.ToLower(strings.Trim(strings.TrimSpace(guid), "{}"))
	if rc, ok := rows[0]["rc"].(int64); !ok || rc != 0 || guid == "" {
		return nil, "not read: xp_regread gave no active power scheme (the login may not execute it, or the key is not there)"
	}
	name, known := powerPlans[guid]
	switch {
	case !known:
		return guid, "a power scheme of the machine's own (not one of the three Windows ships)"
	case name != "High performance":
		return name, "Windows may slow or park cores under this plan; a database server is normally set to High performance"
	}
	return name, ""
}

// propList gathers the payload's property rows.
type propList struct{ rows []collect.Row }

// add appends one property; a nil or empty value is 'not read' and keeps what the repository holds.
func (p *propList) add(name, grp, label string, ord int, value any, note string) {
	p.rows = append(p.rows, propRow(name, grp, label, ord, value, note, true))
}

// addUntracked is add for a value that moves by itself: shown, never logged as a change.
func (p *propList) addUntracked(name, grp, label string, ord int, value any, note string) {
	p.rows = append(p.rows, propRow(name, grp, label, ord, value, note, false))
}

func propRow(name, grp, label string, ord int, value any, note string, track bool) collect.Row {
	r := collect.Row{"kind": "property", "name": name, "grp": grp, "label": label, "ord": ord, "value": nil, "note": nil, "track": track}
	if v := propText(value); v != "" {
		r["value"] = v
	}
	if note != "" {
		r["note"] = note
	}
	return r
}

// propText writes a value as the repository stores it: a number as plain digits, text trimmed, nil as "".
func propText(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case int:
		return strconv.Itoa(x)
	case bool:
		if x {
			return "yes"
		}
		return "no"
	}
	return strings.TrimSpace(fmt.Sprint(v))
}

// yesNo reads a 0 / 1 column; nil stays nil (not read).
func yesNo(v any) any {
	n, ok := v.(int64)
	if !ok {
		return nil
	}
	return n == 1
}

// joinNonEmpty joins the texts that are there with a blank: "RTM CU15".
func joinNonEmpty(vals ...any) any {
	var parts []string
	for _, v := range vals {
		if s, ok := v.(string); ok && strings.TrimSpace(s) != "" {
			parts = append(parts, strings.TrimSpace(s))
		}
	}
	if len(parts) == 0 {
		return nil
	}
	return strings.Join(parts, " ")
}

// pctText is part / whole as a per cent with one decimal ("36.5"), a half rounded up, in whole numbers (a float
// rounds 6.25 to 6.2).
func pctText(part, whole int64) string {
	tenths := (part*1000 + whole/2) / whole
	return strconv.FormatInt(tenths/10, 10) + "." + strconv.FormatInt(tenths%10, 10)
}
