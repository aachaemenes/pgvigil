package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode"

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
//   - Memory: the machine's memory, max and min server memory, max server memory as a per cent of the machine (a
//     figure derived from two others: shown, never logged as a change of its own), the memory model.
//   - TempDB: the data and log files, their sizes, whether the data files are one size (tempdb.sys.database_files:
//     any login). The sizes move by themselves, so they are shown and never logged as a change.
//   - Host: the platform, the distribution and the release (sys.dm_os_host_info, SQL Server 2017 and later;
//     sys.dm_os_windows_info before).
//
// sys.dm_os_sys_info gained socket_count, cores_per_socket and numa_node_count with SQL Server 2016 SP2 and 2017,
// softnuma_configuration_desc with 2016 and sql_memory_model_desc with 2016 SP1: the collector asks sys.all_columns
// which the server has and reads those.
//
// The power plan is the one value SQL Server does not hold: on a Windows server someone runs it is read from the
// registry with xp_regread, a read: first the plan a Group Policy enforces (HKLM\SOFTWARE\Policies\Microsoft\Power\
// PowerSettings, ActivePowerScheme), which the local key does not follow, then the machine's own
// (HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes, ActivePowerScheme). On Linux, Amazon RDS and Azure
// SQL Managed Instance the row says 'not read' and why. The server's start time is not a property: the DMV writes
// it in the local clock and a daylight-saving shift would log a change.
//
// Rights: the Server and TempDB groups and max and min server memory need only the public role. The processor
// rows, the machine's memory and the memory model need VIEW SERVER STATE (on SQL Server 2022 VIEW SERVER PERFORMANCE
// STATE is enough). The host rows are public's before SQL Server 2022 and need VIEW SERVER PERFORMANCE STATE from
// it. A row the login may not read says so and the run is partial. Runs on SQL Server 2016 SP1 and later, Amazon
// RDS and Azure SQL Managed Instance; not on Azure SQL Database.
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

// propsPowerSQL reads the active power scheme's GUID from the registry: the one a Group Policy enforces, then the
// machine's own. A key or a value that is not there comes back as no value (xp_regread answers with a message and
// return code 0, read on SQL Server 2022); a login that may not execute the procedure gets an error, which the
// driver returns.
const propsPowerSQL = `DECLARE @policy nvarchar(128), @scheme nvarchar(128);
EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE',
  @key = N'SOFTWARE\Policies\Microsoft\Power\PowerSettings', @value_name = N'ActivePowerScheme', @value = @policy OUTPUT;
EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE',
  @key = N'SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes', @value_name = N'ActivePowerScheme', @value = @scheme OUTPUT;
SELECT @policy AS policy_scheme, @scheme AS scheme;`

// powerPlans names the power schemes Windows ships, by their GUID (Ultimate Performance ships hidden).
var powerPlans = map[string]string{
	"381b4222-f694-41f0-9685-ff5bb260df2e": "Balanced",
	"8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c": "High performance",
	"a1841308-3541-4fab-bc81-f71556f20b4a": "Power saver",
	"e9a42b02-d5df-448d-aa00-03f14749eb61": "Ultimate Performance",
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
	switch {
	case perfErr == nil:
		si, err = readSysInfo(ctx, conn)
		if err != nil {
			why = "not read: " + err.Error()
			partial = append(partial, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info", "message": err.Error()})
		}
	case errors.Is(perfErr, collect.ErrSkip):
		partial = append(partial, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info",
			"message": "the login lacks VIEW SERVER STATE: the processor rows, the machine's memory and the memory model were not read"})
	default: // the question itself failed (the run's deadline, a lost connection): not a missing right
		why = "not read: " + perfErr.Error()
		partial = append(partial, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info", "message": perfErr.Error()})
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

	// the host (its views have their own rights: asked whatever sys.dm_os_sys_info answered), then the power plan
	// (the registry of a Windows server someone runs)
	host, hostWhy := readHost(ctx, conn, info)
	if host == nil {
		partial = append(partial, collect.Row{"kind": "collector_error", "source": "the host views", "message": strings.TrimPrefix(hostWhy, "not read: ")})
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
	// the rights of the registry reads (task 301c), asked once; a managed service runs the host: nothing to ask
	var gate propGate
	managed := info.Kind == KindRDS || info.Kind == KindAzureMI || info.Kind == KindCloudSQL
	if !managed && host != nil {
		gate = readPropGate(ctx, conn)
	}
	plan, planNote := powerPlan(ctx, conn, info, platform, host != nil, hostWhy, gate)
	p.add("power_plan", "Processor", "Power plan", 310, plan, planNote)
	net, netPartial := readNetwork(ctx, conn, info, platform, gate)
	if host == nil {
		net.hostWhy = hostWhy
	}
	netRows(p, net)
	partial = append(partial, netPartial...)

	// the default backup path (task 301b, Instance#14): the path as the server names it, a change of it logged as any
	// property's. Whether the service account sees it is mssql_backup_checks' read (its own cap: a share that does not
	// answer never holds this collection up); the tab shows that beside it, from mssql_backup_path_cells.
	bp, bpWhy := defaultBackupPath(ctx, conn, info, func() propGate {
		if !gate.read && !managed {
			gate = readPropGate(ctx, conn)
		}
		return gate
	})
	// a managed platform is never read: defaultBackupPath says so before any read (F11)
	if bpWhy == "" {
		p.add("default_backup_path", "Backups", "Default backup path", 800, bp, "")
	} else {
		p.add("default_backup_path", "Backups", "Default backup path", 800, nil, "not read: "+bpWhy)
	}

	maxMB, _ := s["max_memory_mb"].(int64)
	physMB, _ := val("physical_memory_mb").(int64)
	p.add("physical_memory_mb", "Memory", "Physical memory (MB)", 400, val("physical_memory_mb"), note())
	maxNote := ""
	if maxMB == unlimitedMemoryMB {
		maxNote = "the default: no limit is set"
	}
	p.add("max_memory_mb", "Memory", "Max server memory (MB)", 410, s["max_memory_mb"], maxNote)
	// derived from the two rows above: shown, and a change of either is logged once, on its own row
	const pctLabel = "Max server memory, % of the machine"
	switch {
	case si == nil:
		p.addUntracked("max_memory_pct", "Memory", pctLabel, 420, nil, why)
	case maxMB == unlimitedMemoryMB || maxMB <= 0:
		p.addUntracked("max_memory_pct", "Memory", pctLabel, 420, "no limit", "max server memory is at its default: SQL Server sets itself no limit (on Linux the memory.memorylimitmb setting still caps it)")
	case physMB > 0 && maxMB > physMB:
		p.addUntracked("max_memory_pct", "Memory", pctLabel, 420, pctText(maxMB, physMB), "more than the machine has: the setting does not limit SQL Server")
	case physMB > 0:
		p.addUntracked("max_memory_pct", "Memory", pctLabel, 420, pctText(maxMB, physMB), "")
	default:
		p.addUntracked("max_memory_pct", "Memory", pctLabel, 420, nil, "not read: the machine's memory read as 0")
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
// view and runs on Windows only) sys.dm_os_windows_info. The view is chosen by the version, never by an error: on a
// Linux server sys.dm_os_windows_info answers too, with an empty release. nil and the reason when the view does
// not answer.
func readHost(ctx context.Context, conn *sql.Conn, info Info) (collect.Row, string) {
	q := propsHostSQL
	if info.Major > 0 && info.Major < 14 && info.Kind != KindAzureMI { // Managed Instance answers 12.0 and runs the current engine
		q = propsWindowsSQL
	}
	rows, err := QueryRows(ctx, conn, q)
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
// gates: the rights Run asked once (task 301c); none given, they are asked here when the registry is to be read.
func powerPlan(ctx context.Context, conn *sql.Conn, info Info, platform string, hostRead bool, hostWhy string, gates ...propGate) (any, string) {
	switch {
	case info.Kind == KindRDS:
		return nil, "not read: Amazon RDS runs the host; its power plan is not the customer's to read"
	case info.Kind == KindAzureMI:
		return nil, "not read: Azure SQL Managed Instance runs the host; it has no power plan to read"
	case info.Kind == KindCloudSQL:
		return nil, "not read: Google Cloud SQL runs the host (SQL Server on Linux there); it has no power plan to read"
	case !hostRead:
		return nil, "not read: the host's platform is not known (" + strings.TrimPrefix(hostWhy, "not read: ") + ")"
	case platform != "Windows":
		return nil, "not read: SQL Server on " + platform + " has no Windows power plan; the CPU governor is the host's"
	}
	var gate propGate
	if len(gates) > 0 {
		gate = gates[0]
	} else {
		gate = readPropGate(ctx, conn)
	}
	switch {
	case !gate.read:
		return nil, "not read: " + gate.why
	case !gate.regread:
		// a refused procedure is never asked for every hour (task 301c, as 408's review asked)
		return nil, gate.noRight("xp_regread")
	}
	rows, err := QueryRows(ctx, conn, propsPowerSQL)
	if err != nil {
		return nil, "not read: xp_regread failed: " + err.Error()
	}
	return powerPlanOf(rows)
}

// powerPlanOf turns xp_regread's answer (the scheme a Group Policy enforces, and the machine's own) into the plan's
// name and note. The policy's scheme wins: it is the one in force.
func powerPlanOf(rows []collect.Row) (any, string) {
	if len(rows) != 1 {
		return nil, "not read: xp_regread returned no row"
	}
	clean := func(v any) string {
		g, _ := v.(string)
		return strings.ToLower(strings.Trim(strings.TrimSpace(g), "{}"))
	}
	guid, by := clean(rows[0]["policy_scheme"]), " (enforced by Group Policy)"
	if guid == "" {
		guid, by = clean(rows[0]["scheme"]), ""
	}
	if guid == "" {
		return nil, "not read: the registry holds no active power scheme where xp_regread looked"
	}
	name, known := powerPlans[guid]
	switch {
	case !known:
		return guid, "a power scheme of the machine's own, not one Windows ships" + by
	case name != "High performance" && name != "Ultimate Performance":
		return name, "Windows may slow or park cores under this plan; a database server is normally set to High performance" + by
	}
	return name, strings.TrimSpace(strings.Trim(by, " ()"))
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

// ---- the network rows and the processor scheduling (task 301c) -------------------------------------------------
//
// The TCP port, ForceEncryption, ForceStrictEncryption and the enabled protocols are SQL Server's own registry
// values (SuperSocketNetLib); Win32PrioritySeparation is the machine's (HKLM\SYSTEM\CurrentControlSet\Control\
// PriorityControl). Their keys are fixed: the checks (task 409) judge the stored rows by them.
//
//   - Windows: sys.dm_server_registry (VIEW SERVER STATE; VIEW SERVER PERFORMANCE STATE from SQL Server 2022), the
//     SuperSocketNetLib rows with the IPn entries; where the view is refused or empty, xp_instance_regread for the
//     instance's values - without the view the IPn entries cannot be listed. Win32PrioritySeparation, never in the
//     view, through xp_regread.
//   - Linux: the view is empty there; xp_instance_regread answers from SQL Server on Linux's own registry, which
//     follows mssql-conf (network.tcpport, network.forceencryption: read back on 2022 after a restart). The
//     protocols are TCP only; ListenOnAllIPs and Win32PrioritySeparation are Windows settings ('not on Linux').
//   - Amazon RDS, Azure SQL Managed Instance and Google Cloud SQL run the host: 'not applicable'.
//
// The two procedures are undocumented and a site may take EXECUTE away from public: each is called only after
// HAS_PERMS_BY_NAME says the login may execute it (a refused object is never asked for every hour); without the
// right the rows say how to give it (a GRANT on an object names a database user: the login's user in master).
// On Linux the protocols ('met: Linux serves TCP only') and ListenOnAllIPs ('not on Linux') need no registry read and
// keep their words whatever the read gave.

// netKeys are the seven rows' keys, fixed for the checks that judge them.
const (
	keyTCPPort        = "tcp_port"
	keyTCPDynamic     = "tcp_port_dynamic"
	keyListenAll      = "tcp_listen_all_ips"
	keyForceEnc       = "force_encryption"
	keyForceStrictEnc = "force_strict_encryption"
	keyProtocols      = "protocols_enabled"
	keyPrioritySep    = "win32_priority_separation"
)

// propsGateSQL: the rights the registry reads need, asked once a run; HAS_PERMS_BY_NAME answers NULL for a
// permission the version does not have (VIEW SERVER PERFORMANCE STATE before 2022), counted as not held.
const propsGateSQL = `SELECT
  CAST(CASE WHEN ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0) = 1
              OR ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE'), 0) = 1 THEN 1 ELSE 0 END AS int) AS can_registry_view,
  CAST(ISNULL(HAS_PERMS_BY_NAME(N'master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE'), 0) AS int) AS can_instance_regread,
  CAST(ISNULL(HAS_PERMS_BY_NAME(N'master.dbo.xp_regread', 'OBJECT', 'EXECUTE'), 0) AS int) AS can_regread,
  CAST(SUSER_SNAME() AS nvarchar(128)) AS login_name`

// propsNetViewSQL: the instance's network configuration as sys.dm_server_registry holds it.
const propsNetViewSQL = `SELECT CAST(registry_key AS nvarchar(256)) AS registry_key, CAST(value_name AS nvarchar(256)) AS value_name,
  CAST(value_data AS nvarchar(512)) AS value_data
FROM sys.dm_server_registry WHERE registry_key LIKE N'%SuperSocketNetLib%'`

// propsNetRegSQL: the same values, but the IPn entries, through xp_instance_regread (a value that is not there
// comes back NULL).
const propsNetRegSQL = `DECLARE @fe int, @fse int, @all int, @tcp int, @np int, @sm int, @port nvarchar(256), @dyn nvarchar(256);
DECLARE @k nvarchar(200) = N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib';
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', @k, N'ForceEncryption', @fe OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', @k, N'ForceStrictEncryption', @fse OUTPUT;
SET @k = N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp';
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', @k, N'ListenOnAllIPs', @all OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', @k, N'Enabled', @tcp OUTPUT;
SET @k = N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Tcp\IPAll';
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', @k, N'TcpPort', @port OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', @k, N'TcpDynamicPorts', @dyn OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Np', N'Enabled', @np OUTPUT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib\Sm', N'Enabled', @sm OUTPUT;
SELECT @fe AS force_encryption, @fse AS force_strict_encryption, @all AS listen_all, @tcp AS tcp_enabled, @np AS np_enabled,
  @sm AS sm_enabled, @port AS ipall_port, @dyn AS ipall_dynamic;`

// propsPrioritySQL: Win32PrioritySeparation through xp_regread (the machine's key, not the instance's).
const propsPrioritySQL = `DECLARE @ps int;
EXEC master.dbo.xp_regread N'HKEY_LOCAL_MACHINE', N'SYSTEM\CurrentControlSet\Control\PriorityControl', N'Win32PrioritySeparation', @ps OUTPUT;
SELECT @ps AS priority_separation;`

// propGate is what propsGateSQL answered; read is false when the question itself failed.
type propGate struct {
	read                                   bool
	why                                    string
	registryView, instanceRegread, regread bool
	login                                  string
}

func readPropGate(ctx context.Context, conn *sql.Conn) propGate {
	rows, err := QueryRows(ctx, conn, propsGateSQL)
	if err != nil || len(rows) != 1 {
		why := "the rights could not be asked"
		if err != nil {
			why = err.Error()
		}
		return propGate{why: why}
	}
	one := func(k string) bool { n, ok := rows[0][k].(int64); return ok && n == 1 }
	login, _ := rows[0]["login_name"].(string)
	return propGate{read: true, registryView: one("can_registry_view"), instanceRegread: one("can_instance_regread"), regread: one("can_regread"), login: login}
}

// noRight is the words of a refused procedure: how the right is given, the login quoted as QUOTENAME does. A GRANT on
// an object names a database principal, so the login's user in master (made first when it has none: a GRANT to a
// login's name alone fails with Msg 15151).
func (g propGate) noRight(proc string) string {
	l := "[" + strings.ReplaceAll(g.login, "]", "]]") + "]"
	return "no right: EXECUTE on master.dbo." + proc + " - in master, CREATE USER " + l + " FOR LOGIN " + l +
		" when it has none, then GRANT EXECUTE ON dbo." + proc + " TO " + l
}

// ipEntry is one Tcp\IPn key of the registry view.
type ipEntry struct {
	name, address, port, dynamic string
	enabled                      bool
}

// netFacts is what one read found of the network configuration; nil = not there.
type netFacts struct {
	source                                              string // "view" or "xp_instance_regread"
	forceEnc, forceStrict, listenAll, tcpOn, npOn, smOn *int64
	ipAllPort, ipAllDynamic                             string
	ips                                                 []ipEntry
	ipsRead                                             bool // the IPn entries were listed (the view only)
	// encSource names the read the two encryption values came from when it is not source (the view holds no row of the
	// bare SuperSocketNetLib key: xp_instance_regread then); encWhy is why that read was not made or failed
	encSource, encWhy string
}

// encNote is the note of an encryption value the reads did not find.
func (f netFacts) encNote(p *int64, name string) string {
	switch {
	case p != nil:
		return ""
	case f.encWhy != "":
		return f.encWhy
	case f.encSource != "":
		return missing(p, name, f.encSource)
	}
	return missing(p, name, f.source)
}

// regValue is a registry value as sys.dm_server_registry gives it, without the spaces and the terminating NUL a REG_SZ
// value keeps there (301c N5: the lab's Windows VM, SQL Server 2022 - '1433' + NUL, a lone NUL for a blank value).
func regValue(v string) string {
	return strings.TrimFunc(v, func(r rune) bool { return r == 0 || unicode.IsSpace(r) })
}

// netFactsFromView turns sys.dm_server_registry's SuperSocketNetLib rows into the facts.
func netFactsFromView(rows []collect.Row) netFacts {
	f := netFacts{source: "sys.dm_server_registry", ipsRead: true}
	ips := map[string]*ipEntry{}
	var order []string
	num := func(v string) *int64 {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil
		}
		return &n
	}
	for _, r := range rows {
		key, _ := r["registry_key"].(string)
		name, _ := r["value_name"].(string)
		raw, _ := r["value_data"].(string)
		val := regValue(raw)
		i := strings.Index(strings.ToLower(key), `supersocketnetlib`)
		if i < 0 {
			continue
		}
		sub := strings.ToLower(strings.Trim(key[i+len("supersocketnetlib"):], `\`))
		nm := strings.ToLower(name)
		switch {
		case sub == "" && nm == "forceencryption":
			f.forceEnc = num(val)
		case sub == "" && nm == "forcestrictencryption":
			f.forceStrict = num(val)
		case sub == "tcp" && nm == "listenonallips":
			f.listenAll = num(val)
		case sub == "tcp" && nm == "enabled":
			f.tcpOn = num(val)
		case sub == "np" && nm == "enabled":
			f.npOn = num(val)
		case sub == "sm" && nm == "enabled":
			f.smOn = num(val)
		case sub == `tcp\ipall` && nm == "tcpport":
			f.ipAllPort = val
		case sub == `tcp\ipall` && nm == "tcpdynamicports":
			f.ipAllDynamic = val
		case strings.HasPrefix(sub, `tcp\ip`):
			n := key[strings.LastIndex(key, `\`)+1:]
			e, ok := ips[n]
			if !ok {
				e = &ipEntry{name: n}
				ips[n] = e
				order = append(order, n)
			}
			switch nm {
			case "enabled":
				if p := num(val); p != nil && *p == 1 {
					e.enabled = true
				}
			case "ipaddress":
				e.address = val
			case "tcpport":
				e.port = val
			case "tcpdynamicports":
				e.dynamic = val
			}
		}
	}
	for _, n := range order {
		f.ips = append(f.ips, *ips[n])
	}
	return f
}

// netFactsFromRegread turns propsNetRegSQL's one row into the facts (no IPn entries).
func netFactsFromRegread(r collect.Row) netFacts {
	f := netFacts{source: "xp_instance_regread"}
	n := func(k string) *int64 {
		if v, ok := r[k].(int64); ok {
			return &v
		}
		return nil
	}
	f.forceEnc, f.forceStrict, f.listenAll = n("force_encryption"), n("force_strict_encryption"), n("listen_all")
	f.tcpOn, f.npOn, f.smOn = n("tcp_enabled"), n("np_enabled"), n("sm_enabled")
	f.ipAllPort, _ = r["ipall_port"].(string)
	f.ipAllDynamic, _ = r["ipall_dynamic"].(string)
	f.ipAllPort, f.ipAllDynamic = strings.TrimSpace(f.ipAllPort), strings.TrimSpace(f.ipAllDynamic)
	return f
}

// portsOf splits a registry port value ("1433", "1433,1533") into port numbers; anything else is left out.
func portsOf(v string) []int {
	var out []int
	for _, p := range strings.Split(v, ",") {
		if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil && n > 0 && n < 65536 {
			out = append(out, n)
		}
	}
	return out
}

// tcpPorts is the tcp_port row: the ports the instance listens on, ascending, whether any is dynamic, and the note.
// A static port and a dynamic one both listen: TcpDynamicPorts is blank only while dynamic ports are off (Learn, the
// IP Addresses tab), and '0' means they are on with the port chosen at the next start. With ListenOnAllIPs (the
// default) IPAll's ports; with it off, the enabled IPn entries' ports, each named in the note. With TCP/IP disabled
// the instance listens on no TCP port, whatever the ports configured. On Linux ListenOnAllIPs is not read (mssql-conf
// network.ipaddress chooses the address; the view of the IPn entries is empty there): IPAll's ports.
func tcpPorts(f netFacts, linux bool) (value any, dynamic any, note string) {
	if !linux && f.tcpOn != nil && *f.tcpOn == 0 {
		return nil, nil, "not listening: TCP/IP is disabled, so the instance listens on no TCP port"
	}
	seen := map[int]bool{}
	var ports []int
	dyn, dynPending, both := false, false, false
	add := func(ps []int) {
		for _, p := range ps {
			if !seen[p] {
				seen[p] = true
				ports = append(ports, p)
			}
		}
	}
	addAll := func(static, dynv string) bool {
		got := false
		if ps := portsOf(static); len(ps) > 0 {
			add(ps)
			got = true
		}
		if strings.TrimSpace(dynv) != "" {
			both = both || got
			dyn, got = true, true
			if ps := portsOf(dynv); len(ps) > 0 {
				add(ps)
			} else {
				dynPending = true
			}
		}
		return got
	}
	portText := func(static, dynv string) string {
		if strings.TrimSpace(static) != "" && strings.TrimSpace(dynv) != "" {
			return strings.TrimSpace(static) + " and dynamic " + strings.TrimSpace(dynv)
		}
		return firstNonEmpty(static, dynv)
	}
	if !linux && f.listenAll != nil && *f.listenAll == 0 {
		if !f.ipsRead {
			return nil, nil, "not read: ListenOnAllIPs is off and the IPn entries need sys.dm_server_registry (VIEW SERVER STATE)"
		}
		var named []string
		for _, e := range f.ips {
			if !e.enabled {
				continue
			}
			if addAll(e.port, e.dynamic) {
				named = append(named, strings.TrimSpace(e.name+" "+e.address)+": "+portText(e.port, e.dynamic))
			}
		}
		if len(named) == 0 {
			return nil, nil, "not read: ListenOnAllIPs is off and no enabled IPn entry names a port"
		}
		note = "ListenOnAllIPs is off: " + strings.Join(named, "; ")
	} else if !addAll(f.ipAllPort, f.ipAllDynamic) {
		return nil, nil, "not read: IPAll names no static or dynamic TCP port"
	}
	if len(ports) == 0 {
		return nil, true, "dynamic ports are on and none is chosen yet (TcpDynamicPorts 0: SQL Server chooses it at its next start)"
	}
	sortInts(ports)
	text := make([]string, len(ports))
	for i, p := range ports {
		text[i] = strconv.Itoa(p)
	}
	switch {
	case note != "":
	case both && dynPending:
		note = "dynamic ports are on as well (TcpDynamicPorts 0): SQL Server chooses one at its next start besides the static port"
	case both:
		note = "a static port and a dynamic one: TcpDynamicPorts is set, so the instance listens on both; the dynamic one may change at the next start"
	case dyn:
		note = "a dynamic port: SQL Server chose it at its start and may choose another at the next"
	}
	return strings.Join(text, ", "), dyn, note
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func sortInts(a []int) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j] < a[j-1]; j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

// onOff is a registry flag as the repository stores a yes / no; nil stays nil.
func onOff(p *int64) any {
	if p == nil {
		return nil
	}
	return *p == 1
}

// netRowsInput is everything the seven rows are built from (a pure function of it: the unit tests stub it).
type netRowsInput struct {
	kind     Kind
	major    int
	platform string // the host's platform; "" = not known
	hostWhy  string // why the host is not known
	gate     propGate
	facts    *netFacts // nil = not read
	factsWhy string    // why not
	priority any       // Win32PrioritySeparation; nil = not read
	prioWhy  string
}

// netRows adds the seven rows to p.
func netRows(p *propList, in netRowsInput) {
	add := func(key, grp, label string, ord int, v any, note string) { p.add(key, grp, label, ord, v, note) }
	labels := []struct {
		key, grp, label string
		ord             int
	}{
		{keyTCPPort, "Network", "TCP port", 700}, {keyTCPDynamic, "Network", "TCP port is dynamic", 710},
		{keyListenAll, "Network", "Listen on all IP addresses", 720}, {keyForceEnc, "Network", "Force encryption", 730},
		{keyForceStrictEnc, "Network", "Force strict encryption", 740}, {keyProtocols, "Network", "Protocols enabled", 750},
		{keyPrioritySep, "Processor", "Win32PrioritySeparation", 320},
	}
	all := func(note string) {
		for _, l := range labels {
			add(l.key, l.grp, l.label, l.ord, nil, note)
		}
	}
	switch in.kind {
	case KindRDS:
		all("not applicable: Amazon RDS runs the host")
		return
	case KindAzureMI:
		all("not applicable: Azure SQL Managed Instance runs the host")
		return
	case KindCloudSQL:
		all("not applicable: Google Cloud SQL runs the host")
		return
	}
	if in.platform == "" {
		all("not read: the host's platform is not known (" + strings.TrimPrefix(in.hostWhy, "not read: ") + ")")
		return
	}
	linux := in.platform == "Linux"
	if in.facts == nil {
		for _, l := range labels[:6] {
			switch {
			case linux && l.key == keyListenAll:
				add(l.key, l.grp, l.label, l.ord, nil, "not on Linux: mssql-conf network.ipaddress chooses the address")
			case linux && l.key == keyProtocols:
				add(l.key, l.grp, l.label, l.ord, "TCP/IP", "met: Linux serves TCP only")
			default:
				add(l.key, l.grp, l.label, l.ord, nil, in.factsWhy)
			}
		}
	} else {
		f := *in.facts
		port, dyn, portNote := tcpPorts(f, linux)
		if linux && portNote == "" {
			portNote = "SQL Server on Linux: mssql-conf network.tcpport, read through its registry"
		}
		add(keyTCPPort, "Network", "TCP port", 700, port, portNote)
		dynNote := ""
		if dyn == nil {
			dynNote = portNote
		}
		add(keyTCPDynamic, "Network", "TCP port is dynamic", 710, dyn, dynNote)
		if linux {
			add(keyListenAll, "Network", "Listen on all IP addresses", 720, nil, "not on Linux: mssql-conf network.ipaddress chooses the address")
		} else {
			add(keyListenAll, "Network", "Listen on all IP addresses", 720, onOff(f.listenAll), missing(f.listenAll, "ListenOnAllIPs", f.source))
		}
		encNote := f.encNote(f.forceEnc, "ForceEncryption")
		if linux && f.forceEnc != nil {
			encNote = "SQL Server on Linux: mssql-conf network.forceencryption, read through its registry"
		}
		add(keyForceEnc, "Network", "Force encryption", 730, onOff(f.forceEnc), encNote)
		switch {
		case in.major > 0 && in.major < 16:
			add(keyForceStrictEnc, "Network", "Force strict encryption", 740, nil, "not on this version: ForceStrictEncryption came with SQL Server 2022")
		default:
			add(keyForceStrictEnc, "Network", "Force strict encryption", 740, onOff(f.forceStrict), f.encNote(f.forceStrict, "ForceStrictEncryption"))
		}
		if linux {
			add(keyProtocols, "Network", "Protocols enabled", 750, "TCP/IP", "met: Linux serves TCP only")
		} else {
			var on []string
			for _, pr := range []struct {
				v    *int64
				name string
			}{{f.smOn, "Shared Memory"}, {f.npOn, "Named Pipes"}, {f.tcpOn, "TCP/IP"}} {
				if pr.v != nil && *pr.v == 1 {
					on = append(on, pr.name)
				}
			}
			switch {
			case f.smOn == nil && f.npOn == nil && f.tcpOn == nil:
				add(keyProtocols, "Network", "Protocols enabled", 750, nil, "not read: "+f.source+" holds no protocol's Enabled value")
			case len(on) == 0:
				add(keyProtocols, "Network", "Protocols enabled", 750, "none", "")
			default:
				add(keyProtocols, "Network", "Protocols enabled", 750, strings.Join(on, ", "), "")
			}
		}
	}
	switch {
	case linux:
		add(keyPrioritySep, "Processor", "Win32PrioritySeparation", 320, nil, "not on Linux: a Windows scheduler setting")
	case in.platform != "Windows":
		add(keyPrioritySep, "Processor", "Win32PrioritySeparation", 320, nil, "not on "+in.platform+": a Windows scheduler setting")
	default:
		add(keyPrioritySep, "Processor", "Win32PrioritySeparation", 320, in.priority, in.prioWhy)
	}
}

// missing is the note of a registry value the read did not find.
func missing(p *int64, name, source string) string {
	if p != nil {
		return ""
	}
	return "not read: " + source + " holds no " + name + " value"
}

// netQuery is the query readNetwork sends its three statements through: QueryRows (a test of a server's recorded
// answers stands in for it: properties_winfixture_test.go).
var netQuery = QueryRows

// readNetwork reads the facts netRows needs; partial gets a row for each read that failed.
func readNetwork(ctx context.Context, conn *sql.Conn, info Info, platform string, gate propGate) (in netRowsInput, partial []collect.Row) {
	in = netRowsInput{kind: info.Kind, major: info.Major, platform: platform, gate: gate}
	if info.Kind == KindRDS || info.Kind == KindAzureMI || info.Kind == KindCloudSQL || platform == "" {
		return in, nil
	}
	if !gate.read {
		in.factsWhy, in.prioWhy = "not read: "+gate.why, "not read: "+gate.why
		return in, []collect.Row{{"kind": "collector_error", "source": "HAS_PERMS_BY_NAME", "message": gate.why}}
	}
	fail := func(source string, err error) string {
		partial = append(partial, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
		return "not read: " + err.Error()
	}
	// the view first (Windows; empty on Linux), then xp_instance_regread; the view's error is a partial run only when
	// the procedure read nothing either
	var viewErr error
	if platform == "Windows" && gate.registryView {
		rows, err := netQuery(ctx, conn, propsNetViewSQL)
		switch {
		case err != nil:
			viewErr = err
			in.factsWhy = "not read: " + err.Error()
		case len(rows) > 0:
			f := netFactsFromView(rows)
			in.facts = &f
		}
	}
	if in.facts == nil {
		switch {
		case !gate.instanceRegread && platform == "Windows" && !gate.registryView:
			in.factsWhy = gate.noRight("xp_instance_regread") + " (or GRANT VIEW SERVER STATE TO [" + strings.ReplaceAll(gate.login, "]", "]]") + "], which reads sys.dm_server_registry)"
		case !gate.instanceRegread:
			in.factsWhy = gate.noRight("xp_instance_regread")
		default:
			rows, err := netQuery(ctx, conn, propsNetRegSQL)
			switch {
			case err != nil:
				in.factsWhy = fail("xp_instance_regread", err)
			case len(rows) != 1:
				in.factsWhy = "not read: xp_instance_regread returned no row"
			default:
				f := netFactsFromRegread(rows[0])
				in.facts = &f
				in.factsWhy = ""
			}
		}
	}
	if viewErr != nil && in.facts == nil {
		fail("sys.dm_server_registry", viewErr)
	}
	// the view holds no row of the bare SuperSocketNetLib key on some servers (the lab's Windows VM, SQL Server 2022:
	// 301c N5): the two encryption values are then read through xp_instance_regread, where the gate allows it
	strictToo := info.Major <= 0 || info.Major >= 16 // ForceStrictEncryption came with SQL Server 2022 (0 = not known)
	if f := in.facts; f != nil && f.source == "sys.dm_server_registry" && (f.forceEnc == nil || (strictToo && f.forceStrict == nil)) {
		switch {
		case !gate.instanceRegread:
			f.encWhy = "not read: sys.dm_server_registry holds no SuperSocketNetLib encryption value here; " + gate.noRight("xp_instance_regread")
		default:
			rows, err := netQuery(ctx, conn, propsNetRegSQL)
			switch {
			case err != nil:
				f.encWhy = fail("xp_instance_regread", err)
			case len(rows) != 1:
				f.encWhy = "not read: xp_instance_regread returned no row"
			default:
				r := netFactsFromRegread(rows[0])
				if f.forceEnc == nil {
					f.forceEnc = r.forceEnc
				}
				if f.forceStrict == nil {
					f.forceStrict = r.forceStrict
				}
				f.encSource = r.source
			}
		}
	}
	if platform == "Windows" {
		switch {
		case !gate.regread:
			in.prioWhy = gate.noRight("xp_regread")
		default:
			rows, err := netQuery(ctx, conn, propsPrioritySQL)
			switch {
			case err != nil:
				in.prioWhy = fail("xp_regread", err)
			case len(rows) != 1 || rows[0]["priority_separation"] == nil:
				in.prioWhy = "not read: the registry holds no Win32PrioritySeparation value where xp_regread looked"
			default:
				in.priority = rows[0]["priority_separation"]
			}
		}
	}
	return in, partial
}
