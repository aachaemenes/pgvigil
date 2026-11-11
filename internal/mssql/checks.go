package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// checksCollector is mssql_checks: the day-one checks of a SQL Server instance, hourly. One read covers nine
// areas, each judged here and stored with its verdict, so a page can show every value a rule covers, met or not:
//
//   - config: every sys.configurations option against its default (sp_Blitz's defaults table, as data) and
//     against the best-practice rules of serverOptionRules; a value at its default or its best practice is 'ok',
//     a deviation 'warn' (a warning or an advice rule) or 'crit' (a critical rule).
//   - traceflags: every global trace flag (DBCC TRACESTATUS(-1)) with what it does and whether it belongs on.
//   - build: the build against the catalogue of builds (builds.go's list): updates behind, support ended or ending.
//   - dboptions and dbstate: every database's options (sys.databases) against databaseRules; its state and access.
//   - logspace: log used per database (DBCC SQLPERF(LOGSPACE)), why the log cannot clear, virtual log files.
//   - checkdb: the last good DBCC CHECKDB per database (DATABASEPROPERTYEX LastGoodCheckDbTime).
//   - corruption: msdb.dbo.suspect_pages.
//   - alerts: SQL Server Agent's alerts and operators (agentalerts.go).
//
// An area the login may not read is stored as not read with the reason; the others are stored and the run is
// partial. Nothing is written on the server: every statement is one SELECT from a catalog view, a DMV or an msdb
// table, one of two DBCC status commands (TRACESTATUS, SQLPERF(LOGSPACE)) or the Agent's own read of its alert
// settings (sp_MSgetalertinfo); none enters a user database (the identity scan, which does, is mssql_identity).
//
// Rights: config, traceflags, build, dboptions, dbstate and checkdb need only the public role. logspace needs
// VIEW SERVER STATE (on SQL Server 2022 VIEW SERVER PERFORMANCE STATE is enough); the rules that weigh a value
// against the machine (max server memory against physical memory, MAXDOP against the CPU count) need it too and
// say 'not weighed' without it. alerts needs SELECT on msdb's Agent tables (db_datareader there); msdb.dbo.suspect_pages
// is readable through msdb's guest user by the public role (read so on SQL Server 2022).
// Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; not on Azure SQL Database.
type checksCollector struct{}

func init() { Register(checksCollector{}) }

func (checksCollector) Name() string                   { return Prefix + "checks" }
func (checksCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: nine short reads; the log read touches every database's log header.
func (checksCollector) Timeout() time.Duration { return 3 * time.Minute }

func (checksCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (the server options, msdb and the other databases are the service's there)"
	}
	return true, ""
}

// The areas of the checks read: the key of a Summary cell, of a finding and of the 'area' row that says whether
// the area was read.
const (
	AreaConfig     = "config"
	AreaTraceFlags = "traceflags"
	AreaBuild      = "build"
	AreaDBOptions  = "dboptions"
	AreaDBState    = "dbstate"
	AreaLog        = "logspace"
	AreaCheckDB    = "checkdb"
	AreaCorruption = "corruption"
	AreaAlerts     = "alerts"
	AreaIdentity   = "identity"
)

// The severities of a finding, and the status of a grid cell: 'ok' the value meets its rule or is at its default,
// 'warn' a warning or an advice (info) rule is broken, 'crit' a critical rule is broken, 'none' no rule or no
// default covers the value.
const (
	sevCritical = "critical"
	sevWarning  = "warning"
	sevInfo     = "info"
)

func statusOf(severity string) string {
	switch severity {
	case sevCritical:
		return "crit"
	case sevWarning, sevInfo:
		return "warn"
	}
	return "ok"
}

// checkFinding is one judged fact: the check's name, the object it is about, the rule that raised it (the source
// tool and its check number) and the number that broke it.
type checkFinding struct {
	Area, Check, Object, Severity, Rule, Value, Explain string
}

// row is the payload's row. The sentence rides as 'explain': 'detail' is a column the text policy rewrites.
func (f checkFinding) row() collect.Row {
	return collect.Row{"kind": "finding", "area": f.Area, "check_name": f.Check, "object": f.Object,
		"severity": f.Severity, "rule": f.Rule, "value": f.Value, "explain": f.Explain}
}

// areaRow says whether an area was read; note is why not, or what was left out.
func areaRow(area string, read bool, note string) collect.Row {
	r := collect.Row{"kind": "area", "area": area, "read": b2i(read), "note": nil}
	if note != "" {
		r["note"] = note
	}
	return r
}

// checksRun gathers one run's rows.
type checksRun struct {
	rows []collect.Row
}

func (c *checksRun) add(rows ...collect.Row) { c.rows = append(c.rows, rows...) }
func (c *checksRun) find(fs ...checkFinding) {
	for _, f := range fs {
		c.rows = append(c.rows, f.row())
	}
}

// unread stores an area as not read and the run as partial.
func (c *checksRun) unread(area, source, why string) {
	c.add(areaRow(area, false, why), collect.Row{"kind": "collector_error", "source": source, "message": why})
}

func (checksCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	c := &checksRun{}
	perf := perfState(ctx, conn, info, "sys.dm_os_sys_info") == nil
	now := time.Now().UTC()

	// config: a failure of this read is the run's failure (any login reads sys.configurations)
	cfg, err := QueryRows(ctx, conn, checksConfigSQL)
	if err != nil {
		return nil, err
	}
	m := machineFacts{EngineEdition: info.EngineEdition, Kind: info.Kind, Major: info.Major}
	cfgNote := ""
	if perf {
		if si, serr := readSysInfo(ctx, conn); serr == nil {
			m.CPUs, _ = si["cpu_count"].(int64)
			m.NUMANodes, _ = si["numa_nodes"].(int64)
			m.PhysMB, _ = si["physical_memory_mb"].(int64)
		} else {
			cfgNote = "the machine's CPUs and memory were not read (" + serr.Error() + "): max server memory and MAXDOP are not weighed against them"
		}
	} else {
		cfgNote = "the login lacks VIEW SERVER STATE: max server memory and MAXDOP are not weighed against the machine"
	}
	opts, fs := serverOptionRows(cfg, m)
	c.add(opts...)
	c.find(fs...)
	c.add(areaRow(AreaConfig, true, cfgNote))

	// trace flags
	if flags, ferr := QueryRows(ctx, conn, traceFlagsSQL); ferr != nil {
		c.unread(AreaTraceFlags, "DBCC TRACESTATUS", ferr.Error())
	} else {
		rows, fs := traceFlagRows(flags, info)
		c.add(rows...)
		c.find(fs...)
		c.add(areaRow(AreaTraceFlags, true, ""))
	}

	// the build against the catalogue
	b := judgeBuild(info, now)
	c.add(b.row())
	c.find(b.findings(info)...)
	c.add(areaRow(AreaBuild, b.Known, b.Note))

	// the databases: options, state, last good CHECKDB (one read of sys.databases), then the logs
	runDatabases(ctx, conn, info, perf, c)

	// msdb: suspect pages, Agent alerts and operators
	runSuspectPages(ctx, conn, info, c)
	runAgentAlerts(ctx, conn, info, c)
	return c.rows, nil
}

// checksConfigSQL: every option as set and as in use. Readable by any login.
const checksConfigSQL = `SELECT CAST(name AS nvarchar(128)) AS name, CAST(value AS bigint) AS value_set,
  CAST(value_in_use AS bigint) AS value_in_use
FROM sys.configurations ORDER BY name`

// machineFacts is what the rules weigh a value against. A zero CPU count or memory = not read.
type machineFacts struct {
	CPUs, NUMANodes, PhysMB int64
	EngineEdition           int
	Kind                    Kind
	Major                   int
	MaxMemMB                int64 // 'max server memory (MB)' in use, for the rule on min server memory
}

// optionVerdict is one option judged.
type optionVerdict struct {
	Default  *int64 // sp_Blitz's default; nil = none known
	Advised  string // the value a broken rule asks for
	Status   string // ok | warn | crit | none; "" from a rule = no opinion, the default decides
	Severity string // of the broken rule
	Rule     string // the source tool and its check
	Explain  string
}

func met(explain string) optionVerdict { return optionVerdict{Status: "ok", Explain: explain} }
func broken(severity, advised, rule, explain string) optionVerdict {
	return optionVerdict{Status: statusOf(severity), Severity: severity, Advised: advised, Rule: rule, Explain: explain}
}

// serverOptionRules are the best-practice rules that say more than "differs from its default", by the option's
// name in lower case. A rule that returns no status has no opinion on the value and the default decides. The
// thresholds are the named tools' own (sp_Blitz, sp_PerfCheck, dbachecks, Glenn Berry's diagnostic queries, as
// THIRD-PARTY-NOTICES lists them); where a tool gives a priority and no severity, High and sp_Blitz priorities
// under 50 are a warning here, priority boost alone is critical (sp_Blitz priority 5), the rest is advice.
var serverOptionRules = map[string]func(v int64, m machineFacts) optionVerdict{
	"priority boost": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevCritical, "0", "sp_Blitz 126", "priority boost is on: SQL Server runs above the operating system's own threads and the server can stop answering")
		}
		return met("")
	},
	"lightweight pooling": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevWarning, "0", "sp_PerfCheck 1006", "lightweight pooling (fiber mode) is on: CLR, linked servers and other features do not run under it")
		}
		return met("")
	},
	"max server memory (mb)": func(v int64, m machineFacts) optionVerdict {
		switch {
		case m.Kind == KindAzureMI:
			return optionVerdict{Status: "none", Explain: "Azure SQL Managed Instance sets its own memory limit"}
		case v == unlimitedMemoryMB:
			return broken(sevWarning, "a limit under the machine's memory", "dbachecks MaxMemory",
				"max server memory is at its default (2147483647 MB): SQL Server sets itself no limit and can take the memory the operating system needs")
		case m.PhysMB > 0 && v > m.PhysMB:
			return broken(sevWarning, "a limit under the machine's memory", "sp_Blitz 50",
				fmt.Sprintf("max server memory is %d MB, more than the machine's %d MB: the setting limits nothing", v, m.PhysMB))
		case m.PhysMB > 0 && v*100 >= m.PhysMB*95:
			return broken(sevWarning, "under 95 % of the machine's memory", "sp_PerfCheck 1002",
				fmt.Sprintf("max server memory is %d MB, %s %% of the machine's %d MB: 95 %% or more leaves the operating system too little", v, pctText(v, m.PhysMB), m.PhysMB))
		case m.PhysMB == 0:
			return met("a limit is set; not weighed against the machine's memory, which was not read")
		}
		return met("")
	},
	"min server memory (mb)": func(v int64, m machineFacts) optionVerdict {
		switch {
		case m.MaxMemMB <= 0 || m.MaxMemMB == unlimitedMemoryMB || v <= 16:
			return optionVerdict{}
		case v >= m.MaxMemMB:
			return broken(sevInfo, "under max server memory", "sp_Blitz 190",
				fmt.Sprintf("min server memory (%d MB) equals max server memory (%d MB): SQL Server never gives memory back", v, m.MaxMemMB))
		case v*100 >= m.MaxMemMB*90:
			return broken(sevInfo, "under 90 % of max server memory", "sp_PerfCheck 1001",
				fmt.Sprintf("min server memory is %d MB, %s %% of max server memory (%d MB): 90 %% or more leaves almost nothing to give back", v, pctText(v, m.MaxMemMB), m.MaxMemMB))
		}
		return optionVerdict{}
	},
	"cost threshold for parallelism": func(v int64, _ machineFacts) optionVerdict {
		switch {
		case v <= 5:
			return broken(sevWarning, "50", "sp_Blitz 188", fmt.Sprintf("cost threshold for parallelism is %d (the default is 5): almost every query may go parallel", v))
		case v < 50:
			return broken(sevInfo, "50", "sp_PerfCheck 1004", fmt.Sprintf("cost threshold for parallelism is %d: under 50 small queries still go parallel", v))
		}
		return met("")
	},
	"max degree of parallelism": func(v int64, m machineFacts) optionVerdict {
		switch {
		case v != 0:
			return met("")
		case m.CPUs == 0:
			return met("at its default 0; not weighed against the CPU count, which was not read")
		case m.CPUs > 8 || m.NUMANodes > 1:
			return broken(sevInfo, strconv.FormatInt(advisedMaxDOP(m), 10), "sp_Blitz 188",
				fmt.Sprintf("max degree of parallelism is 0 on %d logical CPUs in %d NUMA node(s): one query may take every core", m.CPUs, max64(m.NUMANodes, 1)))
		}
		return met("")
	},
	"remote admin connections": func(v int64, _ machineFacts) optionVerdict {
		if v == 0 {
			return broken(sevInfo, "1", "sp_Blitz 100", "remote admin connections is 0: the dedicated admin connection answers only on the server itself, so a server that no longer takes logins cannot be reached from another machine")
		}
		return met("")
	},
	"backup compression default": func(v int64, m machineFacts) optionVerdict {
		if v == 0 && m.EngineEdition != 4 {
			return broken(sevInfo, "1", "sp_Blitz 116", "backup compression default is 0: a backup that does not ask for compression is written whole")
		}
		return met("")
	},
	"backup checksum default": func(v int64, _ machineFacts) optionVerdict {
		if v == 0 {
			return broken(sevInfo, "1", "Glenn Berry Q4", "backup checksum default is 0: a backup that does not ask for CHECKSUM is written without one and a damaged page goes into it unseen")
		}
		return met("")
	},
	"optimize for ad hoc workloads": func(v int64, _ machineFacts) optionVerdict {
		if v == 0 {
			return broken(sevInfo, "1", "dbachecks AdHocWorkload", "optimize for ad hoc workloads is 0: every single-use statement keeps its whole plan in the cache")
		}
		return met("")
	},
	"xp_cmdshell": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevWarning, "0", "dbachecks XpCmdShellDisabled", "xp_cmdshell is on: T-SQL can run operating system commands as the service account or the proxy")
		}
		return met("")
	},
	"ole automation procedures": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevWarning, "0", "dbachecks OLEAutomation", "Ole Automation Procedures is on: T-SQL can create COM objects inside the SQL Server process")
		}
		return met("")
	},
	"ad hoc distributed queries": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevWarning, "0", "dbachecks AdHocDistributedQueriesEnabled", "Ad Hoc Distributed Queries is on: OPENROWSET and OPENDATASOURCE reach any source the service account can")
		}
		return met("")
	},
	"cross db ownership chaining": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevWarning, "0", "dbachecks CrossDBOwnershipChaining", "cross db ownership chaining is on for every database: an owner in one database reaches objects in another without a permission check")
		}
		return met("")
	},
	"clr enabled": func(v int64, _ machineFacts) optionVerdict {
		if v == 1 {
			return broken(sevInfo, "0 unless an assembly needs it", "dbachecks CLREnabled", "clr enabled is 1: user assemblies run inside SQL Server")
		}
		return met("")
	},
	"default trace enabled": func(v int64, _ machineFacts) optionVerdict {
		if v == 0 {
			return broken(sevWarning, "1", "dbachecks DefaultTrace", "the default trace is off: file growths, shrinks, DBCC commands and schema changes leave no trace")
		}
		return met("")
	},
	"blocked process threshold (s)": blockedProcessRule,
	"blocked process threshold":     blockedProcessRule,
	"fill factor (%)": func(v int64, _ machineFacts) optionVerdict {
		if v == 0 || v == 100 {
			return met("")
		}
		return broken(sevWarning, "0", "sp_Blitz 1020", fmt.Sprintf("the server-wide fill factor is %d %%: every index built without its own leaves %d %% of each page empty", v, 100-v))
	},
	// a value SQL Server or its Agent sets by itself, or a choice with no better side: either value is in order
	"agent xps":             either("SQL Server Agent sets it when it starts and clears it when it stops"),
	"show advanced options": either("it only decides whether sp_configure lists the advanced options"),
	"database mail xps":     either("Database Mail on or off is a choice; the Summary's DB Mail cell says whether it is started"),
}

func either(why string) func(int64, machineFacts) optionVerdict {
	return func(int64, machineFacts) optionVerdict { return met(why) }
}

// blockedProcessRule: 0 (off, the default) and 5 seconds or more are in order; 1 to 4 make the deadlock monitor
// run all the time.
func blockedProcessRule(v int64, _ machineFacts) optionVerdict {
	if v >= 1 && v <= 4 {
		return broken(sevWarning, "0, or 5 and more", "Microsoft: blocked process threshold", fmt.Sprintf("blocked process threshold is %d s: under 5 the deadlock monitor runs constantly", v))
	}
	return met("")
}

// advisedMaxDOP is dbatools' Test-DbaMaxDop rule for SQL Server 2016 and later: one NUMA node, the CPU count up
// to 8; several, the CPUs per node up to 16.
func advisedMaxDOP(m machineFacts) int64 {
	if m.NUMANodes <= 1 {
		return min64(m.CPUs, 8)
	}
	return min64(max64(m.CPUs/m.NUMANodes, 1), 16)
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// judgeServerOption judges one option's value in use: its own rule first, else its default.
func judgeServerOption(name string, inUse int64, m machineFacts) optionVerdict {
	key := strings.ToLower(name)
	def, hasDef := configDefaults[key]
	var out optionVerdict
	if rule, ok := serverOptionRules[key]; ok {
		out = rule(inUse, m)
	}
	if hasDef {
		d := def.value
		out.Default = &d
	}
	if out.Status != "" {
		return out
	}
	switch {
	case !hasDef:
		out.Status, out.Explain = "none", "no default is known for this option"
	case inUse == def.value, key == "min server memory (mb)" && (inUse == 0 || inUse == 16):
		out.Status = "ok" // min server memory: the engine resolves the default 0 to its own floor, 16 on a current build
	default:
		out.Status, out.Severity = "warn", sevInfo
		out.Advised = strconv.FormatInt(def.value, 10)
		out.Rule = fmt.Sprintf("sp_Blitz %d", def.checkID)
		out.Explain = fmt.Sprintf("%s is %d in use; the default is %d", name, inUse, def.value)
	}
	return out
}

// serverOptionRows turns the rows of checksConfigSQL into the payload's option rows and the findings of the
// options that deviate.
func serverOptionRows(cfg []collect.Row, m machineFacts) (rows []collect.Row, findings []checkFinding) {
	for _, r := range cfg {
		if n, _ := r["name"].(string); strings.EqualFold(n, "max server memory (MB)") {
			m.MaxMemMB, _ = r["value_in_use"].(int64)
		}
	}
	for _, r := range cfg {
		name, _ := r["name"].(string)
		inUse, ok := r["value_in_use"].(int64)
		if name == "" || !ok {
			continue
		}
		v := judgeServerOption(name, inUse, m)
		row := collect.Row{"kind": "server_option", "name": name, "value_in_use": inUse, "value_set": r["value_set"],
			"default_value": nil, "advised": nil, "status": v.Status, "severity": nil, "rule": nil, "explain": nil}
		if v.Default != nil {
			row["default_value"] = *v.Default
		}
		for k, s := range map[string]string{"advised": v.Advised, "severity": v.Severity, "rule": v.Rule, "explain": v.Explain} {
			if s != "" {
				row[k] = s
			}
		}
		rows = append(rows, row)
		if v.Severity != "" {
			findings = append(findings, checkFinding{Area: AreaConfig, Check: "server option", Object: name, Severity: v.Severity,
				Rule: v.Rule, Value: strconv.FormatInt(inUse, 10), Explain: v.Explain})
		}
	}
	return rows, findings
}

// traceFlagsSQL lists every trace flag that is on, globally or for this session. With none on it returns no rows.
const traceFlagsSQL = `DBCC TRACESTATUS(-1) WITH NO_INFOMSGS`

// flagNote is what a global trace flag does and whether it belongs on: severity "" = in order.
type flagNote struct {
	severity string
	note     string
	// since is the first major version on which the note holds (the flag became redundant there); before it the
	// flag is in order
	since int
}

// traceFlagNotes: the flags sp_Blitz (CheckID 74) and sp_PerfCheck (check 1012) name, as data, in this file's own
// words. A flag not listed is raised as advice: it is on, and nothing here knows what for.
var traceFlagNotes = map[int64]flagNote{
	652:  {sevWarning, "disables read-ahead during index scans", 0},
	661:  {sevWarning, "disables ghost record removal: deleted rows are never cleaned up and the databases grow", 0},
	834:  {sevWarning, "large-page allocations for the buffer pool: a slow start, and not advised with columnstore indexes", 0},
	1117: {sevInfo, "redundant on SQL Server 2016 and later: tempdb grows its files together by itself, a user filegroup takes AUTOGROW_ALL_FILES", 13},
	1118: {sevInfo, "redundant on SQL Server 2016 and later: tempdb allocates full extents by itself, a user database takes MIXED_PAGE_ALLOCATION OFF", 13},
	1204: {sevInfo, "writes every deadlock to the error log; the system_health session keeps the graphs already", 0},
	1211: {sevWarning, "disables lock escalation entirely: lock memory grows and other sessions wait", 0},
	1222: {sevInfo, "writes every deadlock to the error log; the system_health session keeps the graphs already", 0},
	1224: {sevWarning, "disables lock escalation by the number of locks: it happens only under memory pressure", 0},
	1806: {sevWarning, "disables instant file initialization: restores and data file growths take longer", 0},
	2330: {sevWarning, "stops the collection of missing-index requests", 0},
	2371: {sevInfo, "redundant on SQL Server 2016 and later at compatibility level 130 and up: the lower auto-update statistics threshold is the default", 13},
	3023: {"", "backups are written with CHECKSUM by default", 0},
	3226: {"", "successful backups are not written to the error log", 0},
	3505: {sevWarning, "disables automatic checkpoints", 0},
	3608: {sevWarning, "a startup-only flag (recover master only) is on while the server runs", 0},
	3609: {sevWarning, "a startup-only flag (tempdb is not created at startup) is on while the server runs", 0},
	4199: {sevInfo, "every query optimizer fix for every database; from SQL Server 2016 the database option QUERY_OPTIMIZER_HOTFIXES does it per database", 0},
	7745: {"", "Query Store is not flushed at shutdown: a faster failover, the last interval not yet written is lost", 0},
	7752: {sevInfo, "has no effect on SQL Server 2019 and later: Query Store loads asynchronously by itself", 15},
	8017: {sevInfo, "no schedulers are created for offline CPUs (the default on Express)", 0},
	8048: {sevInfo, "memory objects partitioned per CPU: SQL Server 2016 and later do it by themselves under contention", 0},
	8649: {sevWarning, "forces a parallel plan whatever the cost threshold", 0},
}

// advisedFlags are the flags Glenn Berry's diagnostic queries ask for on a server someone runs.
var advisedFlags = []int64{3226, 7745}

// traceFlagRows turns DBCC TRACESTATUS's rows into the payload's flag rows (the global flags, and the advised
// ones that are off) and their findings. A flag on for the collector's own session only is not the server's.
func traceFlagRows(raw []collect.Row, info Info) (rows []collect.Row, findings []checkFinding) {
	on := map[int64]bool{}
	for _, r := range raw {
		f, ok := r["TraceFlag"].(int64)
		if !ok || r["Global"] != int64(1) {
			continue
		}
		on[f] = true
	}
	flags := make([]int64, 0, len(on))
	for f := range on {
		flags = append(flags, f)
	}
	sort.Slice(flags, func(i, j int) bool { return flags[i] < flags[j] })
	// Azure SQL Managed Instance answers 12 as its major and runs the current engine
	current := info.Kind == KindAzureMI
	for _, f := range flags {
		n, known := traceFlagNotes[f]
		sev, note := n.severity, n.note
		switch {
		case !known:
			sev, note = sevInfo, "on globally; what it is for is not in pgvigil's list"
		case n.since > 0 && !current && info.Major < n.since:
			sev, note = "", "in order before SQL Server "+majorName(n.since)
		}
		rows = append(rows, flagRow(f, true, sev, "sp_Blitz 74", note))
		if sev != "" {
			findings = append(findings, checkFinding{Area: AreaTraceFlags, Check: "trace flag on", Object: strconv.FormatInt(f, 10),
				Severity: sev, Rule: "sp_Blitz 74", Value: strconv.FormatInt(f, 10), Explain: fmt.Sprintf("trace flag %d is on globally: %s", f, note)})
		}
	}
	if info.Kind == KindServer {
		for _, f := range advisedFlags {
			if on[f] {
				continue
			}
			note := traceFlagNotes[f].note
			rows = append(rows, flagRow(f, false, sevInfo, "Glenn Berry Q5", "off; advised on: "+note))
			findings = append(findings, checkFinding{Area: AreaTraceFlags, Check: "trace flag off", Object: strconv.FormatInt(f, 10),
				Severity: sevInfo, Rule: "Glenn Berry Q5", Value: strconv.FormatInt(f, 10), Explain: fmt.Sprintf("trace flag %d is off; with it on, %s", f, note)})
		}
	}
	return rows, findings
}

func flagRow(flag int64, on bool, severity, rule, note string) collect.Row {
	r := collect.Row{"kind": "trace_flag", "flag": flag, "is_on": b2i(on), "status": statusOf(severity), "severity": nil, "rule": rule, "explain": note}
	if severity != "" {
		r["severity"] = severity
	}
	return r
}

// majorName names a major version: 16 = 2022.
func majorName(major int) string {
	switch major {
	case 13:
		return "2016"
	case 14:
		return "2017"
	case 15:
		return "2019"
	case 16:
		return "2022"
	case 17:
		return "2025"
	}
	return strconv.Itoa(major)
}

// buildRow is one build of the catalogue.
type buildRow struct {
	Major, Build int
	Branch       string // CU6, CU4 GDR, RTM, SP3
	Name         string // Cumulative Update 6
	Release      time.Time
	Mainstream   time.Time // the end of mainstream support of this build's branch
	Extended     time.Time // the end of extended support
}

// BuildsAsOf is the version and date of the catalogue's source.
const BuildsAsOf = "SQL Server First Responder Kit 8.34 (2026-07-02)"

// builds is the catalogue, newest first within a major. Where the source lists one build twice (a re-release
// under the same number) the first, newer row is kept.
var builds = parseBuilds(buildCatalogue)

func parseBuilds(text string) map[int][]buildRow {
	out := map[int][]buildRow{}
	day := func(s string) time.Time {
		t, err := time.Parse("2006-01-02", s)
		if err != nil {
			panic("build catalogue: " + s + ": " + err.Error())
		}
		return t
	}
	for _, line := range strings.Split(strings.TrimSpace(text), "\n") {
		f := strings.Split(line, "|")
		if len(f) != 7 {
			panic("build catalogue: " + line)
		}
		major, err1 := strconv.Atoi(f[0])
		build, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			panic("build catalogue: " + line)
		}
		rows := out[major]
		if n := len(rows); n > 0 && rows[n-1].Build == build {
			continue
		}
		out[major] = append(rows, buildRow{Major: major, Build: build, Branch: f[2], Name: f[6], Release: day(f[3]), Mainstream: day(f[4]), Extended: day(f[5])})
	}
	for _, rows := range out {
		sort.SliceStable(rows, func(i, j int) bool { return rows[i].Build > rows[j].Build })
	}
	return out
}

// buildVerdict is an instance's build against the catalogue.
type buildVerdict struct {
	Known  bool   // the catalogue has the major and the platform's builds are the customer's to choose
	Note   string // why not judged, or what the judgement leaves out
	Own    *buildRow
	Exact  bool      // the catalogue lists this very build; else Own is the newest build under it
	Newest *buildRow // the newest build of the major in the catalogue
	Behind int       // builds of the catalogue newer than the instance's
	CUs    int       // of them, cumulative updates (a GDR, a security release on top of one, is not counted)
	Newer  bool      // the instance runs a build newer than the catalogue's newest
	Status string
	now    time.Time
}

// supportWarnDays: a support end this near is raised (dbachecks' warning window of six months).
const supportWarnDays = 180

// behindWarnDays: a build released this long before the newest one is a warning; nearer, advice (pgvigil's own
// threshold: the source tools raise any newer cumulative update at one level).
const behindWarnDays = 365

// judgeBuild places the instance's build in the catalogue.
func judgeBuild(info Info, now time.Time) buildVerdict {
	v := buildVerdict{now: now, Status: "none"}
	switch info.Kind {
	case KindAzureMI, KindAzureDB:
		v.Note = "the service patches itself: its build is not weighed against the catalogue"
		return v
	}
	rows := builds[info.Major]
	if len(rows) == 0 {
		v.Note = fmt.Sprintf("the catalogue (%s) has no build of major version %d", BuildsAsOf, info.Major)
		return v
	}
	v.Known, v.Newest = true, &rows[0]
	if info.Build > rows[0].Build {
		v.Newer, v.Status = true, "ok"
		v.Note = fmt.Sprintf("build %d is newer than the catalogue's newest (%s): updates behind are not counted, the support dates are those of %s", info.Build, BuildsAsOf, rows[0].Branch)
		v.Own = &rows[0]
		return v.support()
	}
	for i := range rows {
		if rows[i].Build > info.Build {
			v.Behind++
			if isCU(rows[i].Branch) {
				v.CUs++
			}
			continue
		}
		v.Own, v.Exact = &rows[i], rows[i].Build == info.Build
		break
	}
	if v.Own == nil { // older than the catalogue's oldest build of the major
		v.Own = &rows[len(rows)-1]
		v.Note = fmt.Sprintf("build %d is older than the catalogue's oldest build of the major: the support dates are those of %s", info.Build, v.Own.Branch)
	}
	v.Status = "ok"
	if v.Behind > 0 {
		v.Status = "warn"
	}
	return v.support()
}

// support adds the support dates' weight to the status.
func (v buildVerdict) support() buildVerdict {
	if v.Own != nil && (v.now.After(v.Own.Extended) || v.Own.Extended.Sub(v.now) < supportWarnDays*24*time.Hour || v.now.After(v.Own.Mainstream)) {
		v.Status = "warn"
	}
	return v
}

// isCU says whether a branch is a cumulative update or a service pack: 'CU4 GDR', 'GDR' and 'RTM GDR' are
// security releases.
func isCU(branch string) bool {
	return !strings.Contains(branch, "GDR") && !strings.HasPrefix(branch, "CTP") && !strings.HasPrefix(branch, "RC")
}

func (v buildVerdict) row() collect.Row {
	r := collect.Row{"kind": "build", "known": b2i(v.Known), "exact": b2i(v.Exact), "newer": b2i(v.Newer), "status": v.Status,
		"behind": v.Behind, "cus_behind": v.CUs, "catalogue": BuildsAsOf, "note": nil, "branch": nil, "update_name": nil,
		"release_date": nil, "mainstream_end": nil, "extended_end": nil, "newest_build": nil, "newest_branch": nil, "newest_release_date": nil}
	if v.Note != "" {
		r["note"] = v.Note
	}
	const day = "2006-01-02"
	if v.Own != nil {
		r["branch"], r["update_name"] = v.Own.Branch, v.Own.Name
		r["release_date"], r["mainstream_end"], r["extended_end"] = v.Own.Release.Format(day), v.Own.Mainstream.Format(day), v.Own.Extended.Format(day)
	}
	if v.Newest != nil {
		r["newest_build"], r["newest_branch"], r["newest_release_date"] = v.Newest.Build, v.Newest.Branch, v.Newest.Release.Format(day)
	}
	return r
}

// findings: updates behind (sp_Blitz 217), support ended (sp_Blitz 128, dbachecks SupportedBuild) or ending.
func (v buildVerdict) findings(info Info) []checkFinding {
	if !v.Known || v.Own == nil {
		return nil
	}
	const day = "2006-01-02"
	var out []checkFinding
	obj := info.ProductVersion
	if v.Behind > 0 {
		sev := sevInfo
		if v.Newest.Release.Sub(v.Own.Release) > behindWarnDays*24*time.Hour {
			sev = sevWarning
		}
		out = append(out, checkFinding{Area: AreaBuild, Check: "updates behind", Object: obj, Severity: sev, Rule: "sp_Blitz 217",
			Value: strconv.Itoa(v.Behind), Explain: fmt.Sprintf("SQL Server %s is on %s (released %s): %d newer build(s), %d of them cumulative updates; the newest is %s, build %d, released %s (catalogue: %s)",
				majorName(info.Major), v.Own.Branch, v.Own.Release.Format(day), v.Behind, v.CUs, v.Newest.Branch, v.Newest.Build, v.Newest.Release.Format(day), BuildsAsOf)})
	}
	left := int(v.Own.Extended.Sub(v.now).Hours() / 24)
	switch {
	case v.now.After(v.Own.Extended):
		out = append(out, checkFinding{Area: AreaBuild, Check: "support ended", Object: obj, Severity: sevWarning, Rule: "sp_Blitz 128",
			Value: v.Own.Extended.Format(day), Explain: fmt.Sprintf("extended support of SQL Server %s %s ended %s: no security fix is made for this build", majorName(info.Major), v.Own.Branch, v.Own.Extended.Format(day))})
	case left < supportWarnDays:
		out = append(out, checkFinding{Area: AreaBuild, Check: "support ending", Object: obj, Severity: sevWarning, Rule: "dbachecks SupportedBuild",
			Value: strconv.Itoa(left), Explain: fmt.Sprintf("extended support of SQL Server %s %s ends %s, in %d day(s)", majorName(info.Major), v.Own.Branch, v.Own.Extended.Format(day), left)})
	case v.now.After(v.Own.Mainstream):
		out = append(out, checkFinding{Area: AreaBuild, Check: "mainstream support ended", Object: obj, Severity: sevInfo, Rule: "dbachecks SupportedBuild",
			Value: v.Own.Mainstream.Format(day), Explain: fmt.Sprintf("mainstream support of SQL Server %s %s ended %s: security fixes only, until %s", majorName(info.Major), v.Own.Branch, v.Own.Mainstream.Format(day), v.Own.Extended.Format(day))})
	}
	return out
}

// configDefault is one row of sp_Blitz's #ConfigurationDefaults: the option's default and the CheckID sp_Blitz
// raises a non-default value under.
type configDefault struct {
	value   int64
	checkID int
}

// configDefaults: the default of every sys.configurations option, by the option's name in lower case. The list is
// sp_Blitz's #ConfigurationDefaults table (SQL Server First Responder Kit 8.34, MIT, Copyright (c) Brent Ozar
// Unlimited; THIRD-PARTY-NOTICES), ported as data; 'min server memory (MB)' is 0 there and 16 in use is taken as
// the default too, as sp_Blitz does.
var configDefaults = func() map[string]configDefault {
	out := make(map[string]configDefault, len(configDefaultList)+1)
	for _, d := range configDefaultList {
		out[strings.ToLower(d.name)] = configDefault{d.value, d.checkID}
	}
	out["min server memory (mb)"] = configDefault{0, 1036}
	return out
}()

var configDefaultList = []struct {
	name    string
	value   int64
	checkID int
}{
	{"access check cache bucket count", 0, 1001},
	{"access check cache quota", 0, 1002},
	{"Ad Hoc Distributed Queries", 0, 1003},
	{"affinity I/O mask", 0, 1004},
	{"affinity mask", 0, 1005},
	{"affinity64 mask", 0, 1066},
	{"affinity64 I/O mask", 0, 1067},
	{"Agent XPs", 0, 1071},
	{"allow updates", 0, 1007},
	{"awe enabled", 0, 1008},
	{"backup checksum default", 0, 1070},
	{"backup compression default", 0, 1073},
	{"blocked process threshold", 0, 1009},
	{"blocked process threshold (s)", 0, 1009},
	{"c2 audit mode", 0, 1010},
	{"clr enabled", 0, 1011},
	{"common criteria compliance enabled", 0, 1074},
	{"contained database authentication", 0, 1068},
	{"cost threshold for parallelism", 5, 1012},
	{"cross db ownership chaining", 0, 1013},
	{"cursor threshold", -1, 1014},
	{"Database Mail XPs", 0, 1072},
	{"default full-text language", 1033, 1016},
	{"default language", 0, 1017},
	{"default trace enabled", 1, 1018},
	{"disallow results from triggers", 0, 1019},
	{"EKM provider enabled", 0, 1075},
	{"filestream access level", 0, 1076},
	{"fill factor (%)", 0, 1020},
	{"ft crawl bandwidth (max)", 100, 1021},
	{"ft crawl bandwidth (min)", 0, 1022},
	{"ft notify bandwidth (max)", 100, 1023},
	{"ft notify bandwidth (min)", 0, 1024},
	{"index create memory (KB)", 0, 1025},
	{"in-doubt xact resolution", 0, 1026},
	{"lightweight pooling", 0, 1027},
	{"locks", 0, 1028},
	{"max degree of parallelism", 0, 1029},
	{"max full-text crawl range", 4, 1030},
	{"max server memory (MB)", 2147483647, 1031},
	{"max text repl size (B)", 65536, 1032},
	{"max worker threads", 0, 1033},
	{"media retention", 0, 1034},
	{"min memory per query (KB)", 1024, 1035},
	{"nested triggers", 1, 1037},
	{"network packet size (B)", 4096, 1038},
	{"Ole Automation Procedures", 0, 1039},
	{"open objects", 0, 1040},
	{"optimize for ad hoc workloads", 0, 1041},
	{"PH timeout (s)", 60, 1042},
	{"precompute rank", 0, 1043},
	{"priority boost", 0, 1044},
	{"query governor cost limit", 0, 1045},
	{"query wait (s)", -1, 1046},
	{"recovery interval (min)", 0, 1047},
	{"remote access", 1, 1048},
	{"remote admin connections", 0, 1049},
	{"remote login timeout (s)", 10, 1069},
	{"remote proc trans", 0, 1050},
	{"remote query timeout (s)", 600, 1051},
	{"Replication XPs", 0, 1052},
	{"RPC parameter data validation", 0, 1053},
	{"scan for startup procs", 0, 1054},
	{"server trigger recursion", 1, 1055},
	{"set working set size", 0, 1056},
	{"show advanced options", 0, 1057},
	{"SMO and DMO XPs", 1, 1058},
	{"SQL Mail XPs", 0, 1059},
	{"transform noise words", 0, 1060},
	{"two digit year cutoff", 2049, 1061},
	{"user connections", 0, 1062},
	{"user options", 0, 1063},
	{"Web Assistant Procedures", 0, 1064},
	{"xp_cmdshell", 0, 1065},
	{"automatic soft-NUMA disabled", 0, 269},
	{"external scripts enabled", 0, 269},
	{"clr strict security", 1, 269},
	{"column encryption enclave type", 0, 269},
	{"tempdb metadata memory-optimized", 0, 269},
	{"ADR cleaner retry timeout (min)", 15, 269},
	{"ADR Preallocation Factor", 4, 269},
	{"Data processed daily limit in TB", 2147483647, 269},
	{"Data processed weekly limit in TB", 2147483647, 269},
	{"Data processed monthly limit in TB", 2147483647, 269},
	{"ADR Cleaner Thread Count", 1, 269},
	{"hardware offload enabled", 0, 269},
	{"hardware offload config", 0, 269},
	{"hardware offload mode", 0, 269},
	{"backup compression algorithm", 0, 269},
	{"ADR cleaner lock timeout (s)", 5, 269},
	{"SLOG memory quota (%)", 75, 269},
	{"max RPC request params (KB)", 0, 269},
	{"max UCS send boxcars", 256, 269},
	{"availability group commit time (ms)", 0, 269},
	{"tiered memory enabled", 0, 269},
	{"max server tiered memory (MB)", 2147483647, 269},
	{"hadoop connectivity", 0, 269},
	{"polybase network encryption", 1, 269},
	{"remote data archive", 0, 269},
	{"allow polybase export", 0, 269},
	{"allow filesystem enumeration", 1, 269},
	{"polybase enabled", 0, 269},
	{"suppress recovery model errors", 0, 269},
	{"openrowset auto_create_statistics", 1, 269},
	{"external rest endpoint enabled", 0, 269},
	{"external xtp dll gen util enabled", 0, 269},
	{"external AI runtimes enabled", 0, 269},
	{"allow server scoped db credentials", 0, 269},
}

// buildCatalogue: every build of SQL Server 2016 to 2025 with its release date and the support ends of its branch,
// one build a line: major|build|branch|released|mainstream support ends|extended support ends|name. The rows are
// SqlServerVersions.sql's (SQL Server First Responder Kit 8.34, MIT; the script by Josh Darnell, MIT;
// THIRD-PARTY-NOTICES), ported as data.
const buildCatalogue = `
17|4055|CU6|2026-06-17|2031-01-06|2036-01-06|Cumulative Update 6
17|4045|CU5|2026-05-20|2031-01-06|2036-01-06|Cumulative Update 5
17|4040|CU4 GDR|2026-05-12|2031-01-06|2036-01-06|Cumulative Update 4 GDR
17|4035|CU4|2026-04-16|2031-01-06|2036-01-06|Cumulative Update 4
17|4030|CU3 GDR|2026-04-14|2031-01-06|2036-01-06|Cumulative Update 3 GDR
17|4025|CU3|2026-03-12|2031-01-06|2036-01-06|Cumulative Update 3
17|4020|CU2 GDR|2026-03-10|2031-01-06|2036-01-06|Cumulative Update 2 GDR
17|4015|CU2|2026-02-12|2031-01-06|2036-01-06|Cumulative Update 2
17|4006|CU1 v2|2026-01-29|2031-01-06|2036-01-06|Cumulative Update 1 v2
17|4005|CU1|2026-01-15|2031-01-06|2036-01-06|Cumulative Update 1 (Removed)
17|1000|RTM|2025-11-18|2031-01-06|2036-01-06|RTM
17|925|RC1|2025-09-17|2025-11-18|2025-11-18|Preview RC1
17|900|RC0|2025-08-20|2025-11-18|2025-11-18|Preview RC0
17|800|CTP 2.1|2025-06-16|2025-11-18|2025-11-18|Preview CTP 2.1
17|700|CTP 2.0|2025-05-19|2025-11-18|2025-11-18|Preview CTP 2.0
16|4255|CU25|2026-05-20|2028-01-11|2033-01-11|Cumulative Update 25
16|4250|CU24 GDR|2026-04-14|2028-01-11|2033-01-11|Cumulative Update 24 GDR
16|4245|CU24|2026-03-12|2028-01-11|2033-01-11|Cumulative Update 24
16|4236|CU23 GDR|2026-03-10|2028-01-11|2033-01-11|Cumulative Update 23 GDR
16|4236|CU23 v2|2026-01-29|2028-01-11|2033-01-11|Cumulative Update 23 v2
16|4235|CU23|2026-01-15|2028-01-11|2033-01-11|Cumulative Update 23 (Removed)
16|4225|CU22|2025-11-13|2028-01-11|2033-01-11|Cumulative Update 22
16|4215|CU21|2025-09-11|2028-01-11|2033-01-11|Cumulative Update 21
16|4205|CU20|2025-07-10|2028-01-11|2033-01-11|Cumulative Update 20
16|4200|CU19 GDR|2025-07-08|2028-01-11|2033-01-11|Cumulative Update 19 GDR
16|4195|CU19|2025-05-19|2028-01-11|2033-01-11|Cumulative Update 19
16|4185|CU18|2025-03-13|2028-01-11|2033-01-11|Cumulative Update 18
16|4175|CU17|2025-01-16|2028-01-11|2033-01-11|Cumulative Update 17
16|4165|CU16|2024-11-14|2028-01-11|2033-01-11|Cumulative Update 16
16|4150|CU15 GDR|2024-10-08|2028-01-11|2033-01-11|Cumulative Update 15 GDR
16|4145|CU15|2024-09-25|2028-01-11|2033-01-11|Cumulative Update 15
16|4140|CU14 GDR|2024-09-10|2028-01-11|2033-01-11|Cumulative Update 14 GDR
16|4135|CU14|2024-07-23|2028-01-11|2033-01-11|Cumulative Update 14
16|4125|CU13|2024-05-16|2028-01-11|2033-01-11|Cumulative Update 13
16|4115|CU12|2024-03-14|2028-01-11|2033-01-11|Cumulative Update 12
16|4105|CU11|2024-01-11|2028-01-11|2033-01-11|Cumulative Update 11
16|4100|CU10 GDR|2024-01-09|2028-01-11|2033-01-11|Cumulative Update 10 GDR
16|4095|CU10|2023-11-16|2028-01-11|2033-01-11|Cumulative Update 10
16|4085|CU9|2023-10-12|2028-01-11|2033-01-11|Cumulative Update 9
16|4075|CU8|2023-09-14|2028-01-11|2033-01-11|Cumulative Update 8
16|4065|CU7|2023-08-10|2028-01-11|2033-01-11|Cumulative Update 7
16|4055|CU6|2023-07-13|2028-01-11|2033-01-11|Cumulative Update 6
16|4045|CU5|2023-06-15|2028-01-11|2033-01-11|Cumulative Update 5
16|4035|CU4|2023-05-11|2028-01-11|2033-01-11|Cumulative Update 4
16|4025|CU3|2023-04-13|2028-01-11|2033-01-11|Cumulative Update 3
16|4015|CU2|2023-03-15|2028-01-11|2033-01-11|Cumulative Update 2
16|4003|CU1|2023-02-16|2028-01-11|2033-01-11|Cumulative Update 1
16|1050|RTM GDR|2023-02-14|2028-01-11|2033-01-11|RTM
16|1000|RTM|2022-11-15|2028-01-11|2033-01-11|RTM
15|4470|CU32 GDR|2026-05-12|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4465|CU32 GDR|2026-04-14|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4460|CU32 GDR|2026-03-10|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4455|CU32 GDR|2025-11-11|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4445|CU32 GDR|2025-09-09|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4440|CU32 GDR|2025-08-12|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4435|CU32 GDR|2025-07-08|2025-01-07|2030-01-08|Cumulative Update 32 GDR
15|4430|CU32|2025-02-27|2025-01-07|2030-01-08|Cumulative Update 32
15|4420|CU31|2025-02-13|2025-01-07|2030-01-08|Cumulative Update 31
15|4415|CU30|2024-12-13|2025-01-07|2030-01-08|Cumulative Update 30
15|4405|CU29|2024-10-31|2025-01-07|2030-01-08|Cumulative Update 29
15|4395|CU28 GDR|2024-10-08|2025-01-07|2030-01-08|Cumulative Update 28 GDR
15|4390|CU28 GDR|2024-09-10|2025-01-07|2030-01-08|Cumulative Update 28 GDR
15|4385|CU28|2024-08-01|2025-01-07|2030-01-08|Cumulative Update 28
15|4375|CU27|2024-06-14|2025-01-07|2030-01-08|Cumulative Update 27
15|4365|CU26|2024-04-11|2025-01-07|2030-01-08|Cumulative Update 26
15|4355|CU25|2024-02-15|2025-01-07|2030-01-08|Cumulative Update 25
15|4345|CU24|2023-12-14|2025-01-07|2030-01-08|Cumulative Update 24
15|4335|CU23|2023-10-12|2025-01-07|2030-01-08|Cumulative Update 23
15|4322|CU22|2023-08-14|2025-01-07|2030-01-08|Cumulative Update 22
15|4316|CU21|2023-06-15|2025-01-07|2030-01-08|Cumulative Update 21
15|4312|CU20|2023-04-13|2025-01-07|2030-01-08|Cumulative Update 20
15|4298|CU19|2023-02-16|2025-01-07|2030-01-08|Cumulative Update 19
15|4280|CU18 GDR|2023-02-14|2025-01-07|2030-01-08|Cumulative Update 18 GDR
15|4261|CU18|2022-09-28|2025-01-07|2030-01-08|Cumulative Update 18
15|4249|CU17|2022-08-11|2025-01-07|2030-01-08|Cumulative Update 17
15|4236|CU16 GDR|2022-06-14|2025-01-07|2030-01-08|Cumulative Update 16 GDR
15|4223|CU16|2022-04-18|2025-01-07|2030-01-08|Cumulative Update 16
15|4198|CU15|2022-01-07|2025-01-07|2030-01-08|Cumulative Update 15
15|4188|CU14|2021-11-22|2025-01-07|2030-01-08|Cumulative Update 14
15|4178|CU13|2021-10-05|2025-01-07|2030-01-08|Cumulative Update 13
15|4153|CU12|2021-08-04|2025-01-07|2030-01-08|Cumulative Update 12
15|4138|CU11|2021-06-10|2025-01-07|2030-01-08|Cumulative Update 11
15|4123|CU10|2021-04-06|2025-01-07|2030-01-08|Cumulative Update 10
15|4102|CU9|2021-02-11|2025-01-07|2030-01-08|Cumulative Update 9
15|4073|CU8 GDR|2021-01-12|2025-01-07|2030-01-08|Cumulative Update 8 GDR
15|4073|CU8|2020-10-01|2025-01-07|2030-01-08|Cumulative Update 8
15|4063|CU7|2020-09-02|2025-01-07|2030-01-08|Cumulative Update 7
15|4053|CU6|2020-08-04|2025-01-07|2030-01-08|Cumulative Update 6
15|4043|CU5|2020-06-22|2025-01-07|2030-01-08|Cumulative Update 5
15|4033|CU4|2020-03-31|2025-01-07|2030-01-08|Cumulative Update 4
15|4023|CU3|2020-03-12|2025-01-07|2030-01-08|Cumulative Update 3
15|4013|CU2|2020-02-13|2025-01-07|2030-01-08|Cumulative Update 2
15|4003|CU1|2020-01-07|2025-01-07|2030-01-08|Cumulative Update 1
15|2070|GDR|2019-11-04|2025-01-07|2030-01-08|RTM GDR
15|2000|RTM|2019-11-04|2025-01-07|2030-01-08|RTM
14|3530|RTM CU31 GDR|2026-05-12|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3525|RTM CU31 GDR|2026-04-14|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3520|RTM CU31 GDR|2026-03-10|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3515|RTM CU31 GDR|2025-11-11|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3505|RTM CU31 GDR|2025-09-09|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3500|RTM CU31 GDR|2025-08-12|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3495|RTM CU31 GDR|2025-07-08|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3485|RTM CU31 GDR|2024-11-12|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3480|RTM CU31 GDR|2024-10-08|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3475|RTM CU31 GDR|2024-09-10|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3471|RTM CU31 GDR|2024-07-09|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3465|RTM CU31 GDR|2023-10-10|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3460|RTM CU31 GDR|2023-02-14|2022-10-11|2027-10-12|RTM Cumulative Update 31 GDR
14|3456|RTM CU31|2022-09-20|2022-10-11|2027-10-12|RTM Cumulative Update 31
14|3451|RTM CU30|2022-07-13|2022-10-11|2027-10-12|RTM Cumulative Update 30
14|3445|RTM CU29 GDR|2022-06-14|2022-10-11|2027-10-12|RTM Cumulative Update 29 GDR
14|3436|RTM CU29|2022-03-31|2022-10-11|2027-10-12|RTM Cumulative Update 29
14|3430|RTM CU28|2022-01-13|2022-10-11|2027-10-12|RTM Cumulative Update 28
14|3421|RTM CU27|2021-10-27|2022-10-11|2027-10-12|RTM Cumulative Update 27
14|3411|RTM CU26|2021-09-14|2022-10-11|2027-10-12|RTM Cumulative Update 26
14|3401|RTM CU25|2021-07-12|2022-10-11|2027-10-12|RTM Cumulative Update 25
14|3391|RTM CU24|2021-05-10|2022-10-11|2027-10-12|RTM Cumulative Update 24
14|3381|RTM CU23|2021-02-25|2022-10-11|2027-10-12|RTM Cumulative Update 23
14|3370|RTM CU22 GDR|2021-01-12|2022-10-11|2027-10-12|RTM Cumulative Update 22 GDR
14|3356|RTM CU22|2020-09-10|2022-10-11|2027-10-12|RTM Cumulative Update 22
14|3335|RTM CU21|2020-07-01|2022-10-11|2027-10-12|RTM Cumulative Update 21
14|3294|RTM CU20|2020-04-07|2022-10-11|2027-10-12|RTM Cumulative Update 20
14|3257|RTM CU19|2020-02-05|2022-10-11|2027-10-12|RTM Cumulative Update 19
14|3257|RTM CU18|2019-12-09|2022-10-11|2027-10-12|RTM Cumulative Update 18
14|3238|RTM CU17|2019-10-08|2022-10-11|2027-10-12|RTM Cumulative Update 17
14|3223|RTM CU16|2019-08-01|2022-10-11|2027-10-12|RTM Cumulative Update 16
14|3162|RTM CU15|2019-05-24|2022-10-11|2027-10-12|RTM Cumulative Update 15
14|3076|RTM CU14|2019-03-25|2022-10-11|2027-10-12|RTM Cumulative Update 14
14|3048|RTM CU13|2018-12-18|2022-10-11|2027-10-12|RTM Cumulative Update 13
14|3045|RTM CU12|2018-10-24|2022-10-11|2027-10-12|RTM Cumulative Update 12
14|3038|RTM CU11|2018-09-20|2022-10-11|2027-10-12|RTM Cumulative Update 11
14|3037|RTM CU10|2018-08-27|2022-10-11|2027-10-12|RTM Cumulative Update 10
14|3030|RTM CU9|2018-07-18|2022-10-11|2027-10-12|RTM Cumulative Update 9
14|3029|RTM CU8|2018-06-21|2022-10-11|2027-10-12|RTM Cumulative Update 8
14|3026|RTM CU7|2018-05-23|2022-10-11|2027-10-12|RTM Cumulative Update 7
14|3025|RTM CU6|2018-04-17|2022-10-11|2027-10-12|RTM Cumulative Update 6
14|3023|RTM CU5|2018-03-20|2022-10-11|2027-10-12|RTM Cumulative Update 5
14|3022|RTM CU4|2018-02-20|2022-10-11|2027-10-12|RTM Cumulative Update 4
14|3015|RTM CU3|2018-01-04|2022-10-11|2027-10-12|RTM Cumulative Update 3
14|3008|RTM CU2|2017-11-28|2022-10-11|2027-10-12|RTM Cumulative Update 2
14|3006|RTM CU1|2017-10-24|2022-10-11|2027-10-12|RTM Cumulative Update 1
14|1000|RTM|2017-10-02|2022-10-11|2027-10-12|RTM
13|7055|SP3 Azure Feature Pack GDR|2025-07-08|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7045|SP3 Azure Feature Pack GDR|2024-10-08|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7040|SP3 Azure Feature Pack GDR|2024-09-10|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7037|SP3 Azure Feature Pack GDR|2024-07-09|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7029|SP3 Azure Feature Pack GDR|2023-10-10|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7024|SP3 Azure Feature Pack GDR|2023-02-14|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7016|SP3 Azure Feature Pack GDR|2022-06-14|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack GDR
13|7000|SP3 Azure Feature Pack|2022-05-19|2021-07-13|2026-07-14|Service Pack 3 Azure Feature Pack
13|6490|SP3 GDR|2026-05-12|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6485|SP3 GDR|2026-04-14|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6480|SP3 GDR|2026-03-10|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6475|SP3 GDR|2025-11-11|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6470|SP3 GDR|2025-09-09|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6465|SP3 GDR|2025-08-12|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6460|SP3 GDR|2025-07-08|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6455|SP3 GDR|2024-11-12|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6450|SP3 GDR|2024-10-08|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6445|SP3 GDR|2024-09-10|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6441|SP3 GDR|2024-07-09|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6435|SP3 GDR|2023-10-10|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6430|SP3 GDR|2023-02-14|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6419|SP3 GDR|2022-06-14|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6404|SP3 GDR|2021-10-27|2021-07-13|2026-07-14|Service Pack 3 GDR
13|6300|SP3|2021-09-15|2021-07-13|2026-07-14|Service Pack 3
13|5888|SP2 CU17|2021-03-29|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 17
13|5882|SP2 CU16|2021-02-11|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 16
13|5865|SP2 CU15 GDR|2021-01-12|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 15 GDR
13|5850|SP2 CU15|2020-09-28|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 15
13|5830|SP2 CU14|2020-08-06|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 14
13|5820|SP2 CU13|2020-05-28|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 13
13|5698|SP2 CU12|2020-02-25|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 12
13|5598|SP2 CU11|2019-12-09|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 11
13|5492|SP2 CU10|2019-10-08|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 10
13|5479|SP2 CU9|2019-09-30|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 9
13|5426|SP2 CU8|2019-07-31|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 8
13|5337|SP2 CU7|2019-05-23|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 7
13|5292|SP2 CU6|2019-03-19|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 6
13|5264|SP2 CU5|2019-01-23|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 5
13|5233|SP2 CU4|2018-11-13|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 4
13|5216|SP2 CU3|2018-09-20|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 3
13|5201|SP2 CU2 + Security Update|2018-08-21|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 2 + Security Update
13|5153|SP2 CU2|2018-07-16|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 2
13|5149|SP2 CU1|2018-05-30|2021-07-13|2026-07-14|Service Pack 2 Cumulative Update 1
13|5103|SP2 GDR|2021-01-12|2021-07-13|2026-07-14|Service Pack 2 GDR
13|5026|SP2|2018-04-24|2021-07-13|2026-07-14|Service Pack 2
13|4574|SP1 CU15|2019-05-16|2021-07-13|2026-07-14|Service Pack 1 Cumulative Update 15
13|4560|SP1 CU14|2019-03-19|2021-07-13|2026-07-14|Service Pack 1 Cumulative Update 14
13|4550|SP1 CU13|2019-01-23|2021-07-13|2026-07-14|Service Pack 1 Cumulative Update 13
13|4541|SP1 CU12|2018-11-13|2021-07-13|2026-07-14|Service Pack 1 Cumulative Update 12
13|4528|SP1 CU11|2018-09-17|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 11
13|4514|SP1 CU10|2018-07-16|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 10
13|4502|SP1 CU9|2018-05-30|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 9
13|4474|SP1 CU8|2018-03-19|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 8
13|4466|SP1 CU7|2018-01-04|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 7
13|4457|SP1 CU6|2017-11-20|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 6
13|4451|SP1 CU5|2017-09-18|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 5
13|4446|SP1 CU4|2017-08-08|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 4
13|4435|SP1 CU3|2017-05-15|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 3
13|4422|SP1 CU2|2017-03-20|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 2
13|4411|SP1 CU1|2017-01-17|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 1
13|4224|SP1 CU10 + Security Update|2018-08-22|2019-07-09|2019-07-09|Service Pack 1 Cumulative Update 10 + Security Update
13|4001|SP1|2016-11-16|2019-07-09|2019-07-09|Service Pack 1
13|2216|RTM CU9|2017-11-20|2018-01-09|2018-01-09|RTM Cumulative Update 9
13|2213|RTM CU8|2017-09-18|2018-01-09|2018-01-09|RTM Cumulative Update 8
13|2210|RTM CU7|2017-08-08|2018-01-09|2018-01-09|RTM Cumulative Update 7
13|2204|RTM CU6|2017-05-15|2018-01-09|2018-01-09|RTM Cumulative Update 6
13|2197|RTM CU5|2017-03-20|2018-01-09|2018-01-09|RTM Cumulative Update 5
13|2193|RTM CU4|2017-01-17|2018-01-09|2018-01-09|RTM Cumulative Update 4
13|2186|RTM CU3|2016-11-16|2018-01-09|2018-01-09|RTM Cumulative Update 3
13|2164|RTM CU2|2016-09-22|2018-01-09|2018-01-09|RTM Cumulative Update 2
13|2149|RTM CU1|2016-07-25|2018-01-09|2018-01-09|RTM Cumulative Update 1
13|1601|RTM|2016-06-01|2019-01-09|2019-01-09|RTM
`
