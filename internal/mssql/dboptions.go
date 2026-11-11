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

// The database side of mssql_checks (the areas dboptions, dbstate, logspace, checkdb and corruption) and the
// collection mssql_identity.
//
// One read of sys.databases gives every database's options, state, owner and last good DBCC CHECKDB; DBCC
// SQLPERF(LOGSPACE) and sys.dm_db_log_info give the log's size, the share in use and the count of virtual log
// files. Each database is judged by databaseRules and stored with every value and with the options that deviate,
// so the page shows a grid of every option of every database, the deviating cells coloured.

// DatabaseOption is one column of the database-option grid: the key the payload carries the value under, the
// column's heading and the value a rule holds it to ("" = shown, not judged).
type DatabaseOption struct {
	Key   string `json:"key"`
	Label string `json:"label"`
	Best  string `json:"best"`
}

// DatabaseOptions lists the grid's columns in their order.
func DatabaseOptions() []DatabaseOption { return databaseOptions }

var databaseOptions = []DatabaseOption{
	{"state", "state", "ONLINE"},
	{"user_access", "user access", "MULTI_USER"},
	{"read_only", "read only", ""},
	{"recovery_model", "recovery model", ""},
	{"compatibility_level", "compatibility level", "the server's own"},
	{"page_verify", "page verify", "CHECKSUM"},
	{"auto_close", "auto close", "off"},
	{"auto_shrink", "auto shrink", "off"},
	{"auto_create_stats", "auto create statistics", "on"},
	{"auto_update_stats", "auto update statistics", "on"},
	{"auto_update_stats_async", "statistics updated asynchronously", "off"},
	{"trustworthy", "trustworthy", "off"},
	{"db_chaining", "ownership chaining", "off"},
	{"delayed_durability", "delayed durability", "DISABLED"},
	{"target_recovery_secs", "target recovery time (s)", "60"},
	{"snapshot_isolation", "snapshot isolation", "OFF"},
	{"rcsi", "read committed snapshot", "off"},
	{"adr", "accelerated database recovery", "off"},
	{"optimized_locking", "optimized locking", ""},
	{"query_store", "Query Store", ""},
	{"encrypted", "encrypted (TDE)", ""},
	{"containment", "containment", "NONE"},
	{"cdc", "change data capture", "off"},
	{"broker", "Service Broker", "off"},
	{"forced_parameterization", "forced parameterization", "off"},
	{"supplemental_logging", "supplemental logging", "off"},
	{"recursive_triggers", "recursive triggers", "off"},
	{"ansi_null_default", "ANSI NULL default", "off"},
	{"auto_create_stats_incremental", "incremental statistics", "off"},
	{"honor_broker_priority", "honor broker priority", "off"},
	{"memory_optimized_elevate", "memory-optimized elevate to snapshot", "off"},
	{"date_correlation", "date correlation", "off"},
	{"ledger", "ledger", ""},
	{"owner", "owner", "a login that exists"},
	{"collation", "collation", "the server's own"},
	{"log_size_mb", "log size (MB)", ""},
	{"log_used_pct", "log used %", "under 75"},
	{"log_reuse_wait", "log reuse wait", ""},
	{"vlf_count", "virtual log files", "under 200"},
	{"last_good_checkdb", "last good CHECKDB", "within 7 days"},
}

// bitOptions are read as 0 / 1 and stored as off / on.
var bitOptions = []string{"read_only", "auto_close", "auto_shrink", "auto_create_stats", "auto_update_stats",
	"auto_update_stats_async", "trustworthy", "db_chaining", "rcsi", "adr", "optimized_locking", "query_store", "encrypted",
	"cdc", "broker", "forced_parameterization", "supplemental_logging", "recursive_triggers", "ansi_null_default",
	"auto_create_stats_incremental", "honor_broker_priority", "memory_optimized_elevate", "date_correlation", "ledger"}

// databasesColsSQL: the columns this server's sys.databases has (accelerated database recovery came with SQL Server
// 2019, ledger with 2022, optimized locking with 2025).
const databasesColsSQL = `SELECT CAST(name AS nvarchar(128)) AS name FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.databases')`

// databasesSQL: one row per database. The three %s are the columns newer servers have, or NULL. The last good
// CHECKDB is the server's local time in the database's boot page: its age is taken on the server, its instant moved
// to UTC by the server's own offset (utcText); 1900-01-01 = never. A database that is not started gives NULL (not read).
var databasesSQL = `SELECT d.database_id, d.name AS database_name, CAST(d.state_desc AS nvarchar(60)) AS state,
  CAST(d.user_access_desc AS nvarchar(60)) AS user_access, CAST(d.is_read_only AS int) AS read_only, CAST(d.is_in_standby AS int) AS in_standby,
  CAST(d.recovery_model_desc AS nvarchar(60)) AS recovery_model, CAST(d.compatibility_level AS int) AS compatibility_level,
  CAST(d.collation_name AS nvarchar(128)) AS collation, CAST(SUSER_SNAME(d.owner_sid) AS nvarchar(128)) AS owner,
  CAST(d.page_verify_option_desc AS nvarchar(60)) AS page_verify,
  CAST(d.is_auto_close_on AS int) AS auto_close, CAST(d.is_auto_shrink_on AS int) AS auto_shrink,
  CAST(d.is_auto_create_stats_on AS int) AS auto_create_stats, CAST(d.is_auto_update_stats_on AS int) AS auto_update_stats,
  CAST(d.is_auto_update_stats_async_on AS int) AS auto_update_stats_async,
  CAST(d.is_trustworthy_on AS int) AS trustworthy, CAST(d.is_db_chaining_on AS int) AS db_chaining,
  CAST(d.snapshot_isolation_state_desc AS nvarchar(60)) AS snapshot_isolation, CAST(d.is_read_committed_snapshot_on AS int) AS rcsi,
  CAST(d.delayed_durability_desc AS nvarchar(60)) AS delayed_durability, CAST(d.target_recovery_time_in_seconds AS int) AS target_recovery_secs,
  CAST(d.containment_desc AS nvarchar(60)) AS containment, CAST(d.is_cdc_enabled AS int) AS cdc, CAST(d.is_broker_enabled AS int) AS broker,
  CAST(d.is_parameterization_forced AS int) AS forced_parameterization, CAST(d.is_encrypted AS int) AS encrypted,
  CAST(d.is_query_store_on AS int) AS query_store, CAST(d.is_date_correlation_on AS int) AS date_correlation,
  CAST(d.is_supplemental_logging_enabled AS int) AS supplemental_logging, CAST(d.is_recursive_triggers_on AS int) AS recursive_triggers,
  CAST(d.is_ansi_null_default_on AS int) AS ansi_null_default, CAST(d.is_auto_create_stats_incremental_on AS int) AS auto_create_stats_incremental,
  CAST(d.is_honor_broker_priority_on AS int) AS honor_broker_priority,
  CAST(d.is_memory_optimized_elevate_to_snapshot_on AS int) AS memory_optimized_elevate,
  %s AS adr, %s AS optimized_locking, %s AS ledger,
  CAST(CASE WHEN d.source_database_id IS NULL THEN 0 ELSE 1 END AS int) AS is_snapshot,
  CAST(d.log_reuse_wait_desc AS nvarchar(60)) AS log_reuse_wait,
  CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS server_collation,
  DATEDIFF(day, d.create_date, GETDATE()) AS age_days,
  CAST(CASE WHEN x.good IS NULL THEN NULL WHEN x.good < '19010101' THEN 1 ELSE 0 END AS int) AS checkdb_never,
  CASE WHEN x.good >= '19010101' THEN DATEDIFF(minute, x.good, GETDATE()) END AS checkdb_age_min,
  CASE WHEN x.good >= '19010101' THEN ` + utcText("x.good") + ` END AS checkdb_at_utc
FROM sys.databases d
OUTER APPLY (SELECT CAST(DATABASEPROPERTYEX(d.name, 'LastGoodCheckDbTime') AS datetime) AS good) x
ORDER BY d.name`

// logSpaceSQL: every database's log size and the share of it in use, in one call. VIEW SERVER STATE.
const logSpaceSQL = `DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS`

// vlfSQL: the virtual log files of every ONLINE database the login can enter (one it cannot would fail the whole
// statement). SQL Server 2016 SP2 and later.
const vlfSQL = `SELECT d.database_id, CAST(COUNT(*) AS bigint) AS vlf_count
FROM sys.databases d CROSS APPLY sys.dm_db_log_info(d.database_id) li
WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 1
GROUP BY d.database_id`

// suspectPagesSQL: the pages SQL Server could not read, as msdb keeps them (1,000 rows at most). The time is the
// server's local clock, moved to UTC by its offset. Event types: 1 an 823 or 824 error, 2 a bad checksum, 3 a torn
// page, 4 restored, 5 repaired, 7 deallocated by DBCC.
var suspectPagesSQL = `SELECT sp.database_id, CAST(ISNULL(DB_NAME(sp.database_id), CAST(sp.database_id AS nvarchar(20))) AS nvarchar(128)) AS database_name,
  CAST(sp.file_id AS int) AS file_id, CAST(sp.page_id AS bigint) AS page_id, CAST(sp.event_type AS int) AS event_type,
  CAST(sp.error_count AS int) AS error_count, DATEDIFF(day, sp.last_update_date, GETDATE()) AS age_days,
  ` + utcText("sp.last_update_date") + ` AS last_update_utc
FROM msdb.dbo.suspect_pages sp
ORDER BY sp.last_update_date DESC`

// dbFacts is one database as the rules read it.
type dbFacts struct{ r collect.Row }

func (d dbFacts) text(k string) string { s, _ := d.r[k].(string); return s }
func (d dbFacts) num(k string) (int64, bool) {
	n, ok := d.r[k].(int64)
	return n, ok
}
func (d dbFacts) on(k string) bool { n, _ := d.r[k].(int64); return n == 1 }
func (d dbFacts) id() int64        { n, _ := d.r["database_id"].(int64); return n }
func (d dbFacts) name() string     { return d.text("database_name") }
func (d dbFacts) online() bool     { return d.text("state") == "ONLINE" }
func (d dbFacts) snapshot() bool   { return d.on("is_snapshot") }

// user: a database someone made, online, not a snapshot and not the platform's own: the option rules judge these.
func (d dbFacts) user() bool {
	return d.id() > 4 && d.online() && !d.snapshot() && !strings.EqualFold(d.name(), "rdsadmin")
}

// serverFacts is what a database is weighed against.
type serverFacts struct {
	Level     int64  // the compatibility level of the server's own version; 0 = not known
	Collation string // the server's collation
	Major     int
}

func serverFactsOf(info Info, collation string) serverFacts {
	s := serverFacts{Collation: collation, Major: info.Major}
	// Azure SQL Managed Instance answers 12 as its major and runs the current engine: no level to hold a database to
	if info.Kind != KindAzureMI && info.Major >= 13 && info.Major <= 17 {
		s.Level = int64(info.Major) * 10
	}
	return s
}

// dbRule judges one option of one database: severity "" = in order (or not this rule's to judge).
type dbRule struct {
	key, area, check string
	judge            func(d dbFacts, s serverFacts) (severity, rule, explain string)
}

// offByDefault is a rule for an option sp_Blitz's #DatabaseDefaults table holds off in a user database: on is
// advice (sp_Blitz's 'Non-Default Database Config', priority 210).
func offByDefault(key, label string, checkID int) dbRule {
	return dbRule{key, AreaDBOptions, "non-default database option", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && d.on(key) {
			return sevInfo, fmt.Sprintf("sp_Blitz %d", checkID), label + " is on; the default is off"
		}
		return "", "", ""
	}}
}

// databaseRules: the rules of the database-option grid, the state and the log. The thresholds are the named tools'
// own; where a tool gives a priority and no severity, the choice of warning or advice is pgvigil's.
var databaseRules = []dbRule{
	{"state", AreaDBState, "database state", func(d dbFacts, _ serverFacts) (string, string, string) {
		switch st := d.text("state"); st {
		case "SUSPECT", "RECOVERY_PENDING", "EMERGENCY":
			return sevCritical, "sp_Blitz 102", "the database is " + strings.ToLower(strings.ReplaceAll(st, "_", " ")) + ": it cannot be used"
		case "OFFLINE", "RECOVERING":
			return sevWarning, "sp_Blitz 102", "the database is " + strings.ToLower(st)
		}
		return "", "", ""
	}},
	{"user_access", AreaDBState, "database access", func(d dbFacts, _ serverFacts) (string, string, string) {
		if ua := d.text("user_access"); d.online() && ua != "" && ua != "MULTI_USER" {
			return sevWarning, "sp_PerfCheck 7003", "the database is in " + ua + " mode: the application's sessions cannot connect"
		}
		return "", "", ""
	}},
	{"page_verify", AreaDBOptions, "page verify", func(d dbFacts, _ serverFacts) (string, string, string) {
		pv := d.text("page_verify")
		switch {
		case d.id() == 2 || !d.online() || d.snapshot() || pv == "" || pv == "CHECKSUM":
			return "", "", ""
		case pv == "NONE":
			return sevCritical, "sp_Blitz 14", "page verify is NONE: a page damaged on disk is read back without any check"
		}
		return sevWarning, "sp_Blitz 14", "page verify is " + pv + ": only CHECKSUM finds every damaged page"
	}},
	{"auto_close", AreaDBOptions, "auto close", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.online() && !d.snapshot() && d.on("auto_close") {
			return sevWarning, "sp_Blitz 12", "AUTO_CLOSE is on: the database shuts down when its last session leaves and the next one pays for its start"
		}
		return "", "", ""
	}},
	{"auto_shrink", AreaDBOptions, "auto shrink", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.online() && !d.snapshot() && d.on("auto_shrink") {
			return sevWarning, "sp_Blitz 13", "AUTO_SHRINK is on: the files shrink and grow again, the indexes fragment"
		}
		return "", "", ""
	}},
	{"auto_create_stats", AreaDBOptions, "auto create statistics", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && !d.on("auto_create_stats") {
			return sevWarning, "sp_Blitz 15", "auto create statistics is off: the optimizer guesses where no statistic exists"
		}
		return "", "", ""
	}},
	{"auto_update_stats", AreaDBOptions, "auto update statistics", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && !d.on("auto_update_stats") {
			return sevWarning, "sp_Blitz 16", "auto update statistics is off: plans are built on statistics nothing refreshes"
		}
		return "", "", ""
	}},
	{"auto_update_stats_async", AreaDBOptions, "statistics updated asynchronously", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && d.on("auto_update_stats_async") {
			return sevInfo, "sp_Blitz 17", "statistics are updated asynchronously: a query runs on the old statistics while the new ones are built"
		}
		return "", "", ""
	}},
	{"trustworthy", AreaDBOptions, "trustworthy", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && d.on("trustworthy") {
			return sevWarning, "dbachecks Trustworthy", "TRUSTWORTHY is on: code in this database can act with its owner's server rights"
		}
		return "", "", ""
	}},
	{"compatibility_level", AreaDBOptions, "old compatibility level", func(d dbFacts, s serverFacts) (string, string, string) {
		if lvl, ok := d.num("compatibility_level"); ok && d.user() && s.Level > 0 && lvl < s.Level {
			return sevInfo, "dbachecks CompatibilityLevel", fmt.Sprintf("compatibility level %d on SQL Server %s (%d): the database keeps the older optimizer behaviour", lvl, majorName(s.Major), s.Level)
		}
		return "", "", ""
	}},
	{"delayed_durability", AreaDBOptions, "delayed durability", func(d dbFacts, _ serverFacts) (string, string, string) {
		if dd := d.text("delayed_durability"); d.user() && dd != "" && dd != "DISABLED" {
			return sevWarning, "sp_PerfCheck 7008", "delayed durability is " + dd + ": the last committed transactions can be lost in a crash"
		}
		return "", "", ""
	}},
	{"target_recovery_secs", AreaDBOptions, "target recovery time", func(d dbFacts, _ serverFacts) (string, string, string) {
		secs, ok := d.num("target_recovery_secs")
		switch {
		case !ok || !d.user() || d.on("read_only") || d.on("in_standby") || secs == 60:
			return "", "", ""
		case secs == 0:
			return sevInfo, "sp_Blitz 257", "target recovery time is 0: the database does not use indirect checkpoints"
		}
		return sevInfo, "sp_Blitz 257", fmt.Sprintf("target recovery time is %d s; the default since SQL Server 2016 is 60", secs)
	}},
	{"optimized_locking", AreaDBOptions, "optimized locking", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && d.on("optimized_locking") && !d.on("rcsi") {
			return sevInfo, "sp_Blitz 272", "optimized locking is on while read committed snapshot is off: lock after qualification does not apply"
		}
		return "", "", ""
	}},
	{"owner", AreaDBOptions, "database owner unknown", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.online() && !d.snapshot() && d.r["owner"] == nil {
			return sevInfo, "sp_Blitz 213", "the owner's SID maps to no login on this server"
		}
		return "", "", ""
	}},
	{"collation", AreaDBOptions, "collation differs from the server's", func(d dbFacts, s serverFacts) (string, string, string) {
		if c := d.text("collation"); d.user() && c != "" && s.Collation != "" && c != s.Collation {
			return sevInfo, "dbatools Test-DbaDbCollation", "collation " + c + "; the server's (and tempdb's) is " + s.Collation + ": a join on a temp table's text column fails or converts"
		}
		return "", "", ""
	}},
	{"snapshot_isolation", AreaDBOptions, "non-default database option", func(d dbFacts, _ serverFacts) (string, string, string) {
		if si := d.text("snapshot_isolation"); d.user() && si != "" && si != "OFF" {
			return sevInfo, "sp_Blitz 132", "snapshot isolation is " + si + "; the default is OFF"
		}
		return "", "", ""
	}},
	{"containment", AreaDBOptions, "non-default database option", func(d dbFacts, _ serverFacts) (string, string, string) {
		if c := d.text("containment"); d.user() && c != "" && c != "NONE" {
			return sevInfo, "sp_Blitz 141", "containment is " + c + "; the default is NONE"
		}
		return "", "", ""
	}},
	offByDefault("rcsi", "read committed snapshot", 133),
	offByDefault("adr", "accelerated database recovery", 275),
	offByDefault("cdc", "change data capture", 140),
	offByDefault("broker", "Service Broker", 230),
	offByDefault("forced_parameterization", "forced parameterization", 138),
	offByDefault("supplemental_logging", "supplemental logging", 131),
	offByDefault("recursive_triggers", "recursive triggers", 136),
	offByDefault("ansi_null_default", "ANSI NULL default", 135),
	offByDefault("auto_create_stats_incremental", "incremental statistics", 134),
	offByDefault("honor_broker_priority", "honor broker priority", 231),
	offByDefault("memory_optimized_elevate", "memory-optimized elevate to snapshot", 144),
	offByDefault("date_correlation", "date correlation", 20),
	{"db_chaining", AreaDBOptions, "non-default database option", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && d.on("db_chaining") {
			return sevInfo, "dbachecks CrossDBOwnershipChaining", "ownership chaining is on for this database; the default is off"
		}
		return "", "", ""
	}},
	{"log_used_pct", AreaLog, "log space used", func(d dbFacts, _ serverFacts) (string, string, string) {
		pct, ok := d.r["log_used_pct"].(float64)
		if !ok || !d.online() || pct < logWarnPct {
			return "", "", ""
		}
		sev := sevWarning
		if pct >= logCritPct {
			sev = sevCritical
		}
		wait := d.text("log_reuse_wait")
		if wait == "" || wait == "NOTHING" {
			wait = "nothing holds it now"
		}
		size, _ := d.r["log_size_mb"].(float64)
		return sev, "dbachecks LogfilePercentUsed", fmt.Sprintf("%.1f %% of the %.0f MB log is in use (warning at %d, critical at %d); log reuse wait: %s", pct, size, logWarnPct, logCritPct, wait)
	}},
	{"vlf_count", AreaLog, "virtual log files", func(d dbFacts, _ serverFacts) (string, string, string) {
		n, ok := d.num("vlf_count")
		switch {
		case !ok || n < 200:
			return "", "", ""
		case n >= 1000:
			return sevWarning, "sp_Blitz 69", fmt.Sprintf("%d virtual log files (1,000 or more): recovery, restores and log backups slow down", n)
		case n >= 512:
			return sevWarning, "dbachecks VirtualLogFile", fmt.Sprintf("%d virtual log files (512 or more): the log grew in many small steps", n)
		}
		return sevInfo, "Glenn Berry Q36", fmt.Sprintf("%d virtual log files (200 or more): the log grew in many small steps", n)
	}},
	{"last_good_checkdb", AreaCheckDB, "last good CHECKDB", func(d dbFacts, _ serverFacts) (string, string, string) {
		never, read := d.num("checkdb_never")
		if !read || d.id() == 2 || !d.online() || d.snapshot() || d.on("read_only") {
			return "", "", ""
		}
		if never == 1 {
			if age, ok := d.num("age_days"); ok && age < checkdbNewDays {
				return "", "", "" // dbatools: a new database, not checked yet
			}
			return sevCritical, "sp_Blitz 68", "DBCC CHECKDB has never completed without error on this database"
		}
		min, _ := d.num("checkdb_age_min")
		days := min / 1440
		// a grace of half a day past each threshold: a weekly CHECKDB is 7 days old when the next one starts
		switch {
		case min >= checkdbCritDays*1440+checkdbGraceMin:
			return sevCritical, "sp_Blitz 68", fmt.Sprintf("the last good DBCC CHECKDB is %d days old (critical past %d)", days, checkdbCritDays)
		case min >= checkdbWarnDays*1440+checkdbGraceMin:
			return sevWarning, "dbachecks LastGoodCheckDb", fmt.Sprintf("the last good DBCC CHECKDB is %d days old (warning past %d)", days, checkdbWarnDays)
		}
		return "", "", ""
	}},
}

// The thresholds of the log and CHECKDB rules: log used per cent (dbachecks' 75; 90 is pgvigil's own), the age of
// the last good CHECKDB in days (dbachecks' 7, sp_Blitz's 14) with half a day's grace (pgvigil's own) and the days a
// new database may go unchecked (dbatools).
const (
	logWarnPct      = 75
	logCritPct      = 90
	checkdbWarnDays = 7
	checkdbCritDays = 14
	checkdbGraceMin = 12 * 60
	checkdbNewDays  = 7
)

// judgeDatabase runs the rules over one database: the cells that deviate (option key to status, severity, rule
// and sentence) and the findings. An option with two broken rules keeps the worse one in its cell.
func judgeDatabase(d dbFacts, s serverFacts) (map[string]map[string]string, []checkFinding) {
	dev := map[string]map[string]string{}
	var fs []checkFinding
	for _, rule := range databaseRules {
		sev, src, explain := rule.judge(d, s)
		if sev == "" {
			continue
		}
		if old, ok := dev[rule.key]; !ok || sevRank(sev) < sevRank(old["severity"]) {
			dev[rule.key] = map[string]string{"status": statusOf(sev), "severity": sev, "rule": src, "explain": explain}
		}
		fs = append(fs, checkFinding{Area: rule.area, Check: rule.check, Object: d.name(), Severity: sev, Rule: src,
			Value: optionText(d, rule.key), Explain: d.name() + ": " + explain})
	}
	return dev, fs
}

func sevRank(sev string) int {
	switch sev {
	case sevCritical:
		return 0
	case sevWarning:
		return 1
	}
	return 2
}

// optionText is an option's value as the grid shows it.
func optionText(d dbFacts, key string) string {
	v := databaseValues(d)[key]
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}

// databaseValues is the database's value of every grid column: a bit as on / off, a text as read, a number as a
// number; an option the server does not have, or a value not read, is absent.
func databaseValues(d dbFacts) map[string]any {
	out := map[string]any{}
	bit := map[string]bool{}
	for _, k := range bitOptions {
		bit[k] = true
	}
	for _, o := range databaseOptions {
		v := d.r[o.Key]
		switch {
		case o.Key == "last_good_checkdb":
			if never, read := d.num("checkdb_never"); read && never == 1 {
				out[o.Key] = "never"
			} else if at := d.text("checkdb_at_utc"); at != "" {
				out[o.Key] = at
			}
		case v == nil:
		case bit[o.Key]:
			if n, _ := v.(int64); n == 1 {
				out[o.Key] = "on"
			} else {
				out[o.Key] = "off"
			}
		default:
			if f, ok := v.(float64); ok {
				v = float64(int64(f*10+0.5)) / 10 // one decimal: the log's size and share in use
			}
			out[o.Key] = v
		}
	}
	return out
}

// hasVLFView says whether the server has sys.dm_db_log_info: SQL Server 2016 SP2 (13.0.5026) and later.
func hasVLFView(info Info) bool {
	return info.Kind == KindAzureMI || info.Major > 13 || (info.Major == 13 && info.Build >= 5026)
}

// runDatabases reads the databases, their logs and their last good CHECKDB into the run.
func runDatabases(ctx context.Context, conn *sql.Conn, info Info, perf bool, c *checksRun) {
	fail := func(source string, err error) {
		c.add(collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
		for _, a := range []string{AreaDBOptions, AreaDBState, AreaCheckDB, AreaLog} {
			c.add(areaRow(a, false, "sys.databases was not read: "+err.Error()))
		}
	}
	cols, err := QueryRows(ctx, conn, databasesColsSQL)
	if err != nil {
		fail("sys.all_columns", err)
		return
	}
	have := map[string]bool{}
	for _, r := range cols {
		if n, ok := r["name"].(string); ok {
			have[n] = true
		}
	}
	raw, err := QueryRows(ctx, conn, databasesQuery(have))
	if err != nil {
		fail("sys.databases", err)
		return
	}

	// the logs: size and share in use by name, virtual log files by id
	logNote, logRead := "", false
	if !perf {
		logNote = "the login lacks VIEW SERVER STATE: the logs' size, share in use and virtual log files were not read"
		c.add(collect.Row{"kind": "collector_error", "source": "DBCC SQLPERF(LOGSPACE)", "message": logNote})
	} else if space, lerr := QueryRows(ctx, conn, logSpaceSQL); lerr != nil {
		logNote = "DBCC SQLPERF(LOGSPACE) failed: " + lerr.Error()
		c.add(collect.Row{"kind": "collector_error", "source": "DBCC SQLPERF(LOGSPACE)", "message": lerr.Error()})
	} else {
		logRead = true
		by := map[string]collect.Row{}
		for _, r := range space {
			if n, ok := r["Database Name"].(string); ok {
				by[n] = r
			}
		}
		for _, r := range raw {
			if l, ok := by[dbFacts{r}.name()]; ok {
				r["log_size_mb"], r["log_used_pct"] = l["Log Size (MB)"], l["Log Space Used (%)"]
			}
		}
		switch {
		case !hasVLFView(info):
			logNote = "the virtual log files were not counted: sys.dm_db_log_info is SQL Server 2016 SP2 and later"
		default:
			vlfs, verr := QueryRows(ctx, conn, vlfSQL)
			if verr != nil {
				logNote = "the virtual log files were not counted: " + verr.Error()
				c.add(collect.Row{"kind": "collector_error", "source": "sys.dm_db_log_info", "message": verr.Error()})
				break
			}
			byID := map[int64]any{}
			for _, v := range vlfs {
				if id, ok := v["database_id"].(int64); ok {
					byID[id] = v["vlf_count"]
				}
			}
			for _, r := range raw {
				if n, ok := byID[dbFacts{r}.id()]; ok {
					r["vlf_count"] = n
				}
			}
		}
	}

	checked := 0
	for _, r := range raw {
		d := dbFacts{r}
		s := serverFactsOf(info, d.text("server_collation"))
		if _, read := d.num("checkdb_never"); read {
			checked++
		}
		dev, fs := judgeDatabase(d, s)
		c.add(collect.Row{"kind": "database", "database_id": d.id(), "database_name": d.name(), "state": d.text("state"),
			"is_system": b2i(d.id() <= 4), "is_snapshot": b2i(d.snapshot()), "options": databaseValues(d), "deviations": dev})
		c.find(fs...)
	}
	c.add(areaRow(AreaDBOptions, true, ""), areaRow(AreaDBState, true, ""), areaRow(AreaLog, logRead, logNote))
	if checked == 0 && len(raw) > 0 {
		c.add(areaRow(AreaCheckDB, false, "no database gave a last good CHECKDB time: DATABASEPROPERTYEX has LastGoodCheckDbTime from SQL Server 2016 SP2"))
	} else {
		c.add(areaRow(AreaCheckDB, true, ""))
	}
}

// databasesQuery fills databasesSQL with the optional columns the server has (have: sys.all_columns' names).
func databasesQuery(have map[string]bool) string {
	col := func(name string) string {
		if have[name] {
			return "CAST(d." + name + " AS int)"
		}
		return "CAST(NULL AS int)"
	}
	return fmt.Sprintf(databasesSQL, col("is_accelerated_database_recovery_on"), col("is_optimized_locking_on"), col("is_ledger_on"))
}

// suspectCap is the number of rows msdb.dbo.suspect_pages holds before SQL Server stops recording; a table this
// full is raised (dbachecks' SuspectPageLimit, 90 %).
const (
	suspectCap     = 1000
	suspectNearCap = 900
	suspectDays    = 30
)

// runSuspectPages reads msdb.dbo.suspect_pages into the run (the area corruption).
func runSuspectPages(ctx context.Context, conn *sql.Conn, info Info, c *checksRun) {
	if !info.MsdbAccess {
		c.unread(AreaCorruption, "msdb.dbo.suspect_pages", "the login has no access to msdb: the suspect pages were not read")
		return
	}
	raw, err := QueryRows(ctx, conn, suspectPagesSQL)
	if err != nil {
		c.unread(AreaCorruption, "msdb.dbo.suspect_pages", "msdb.dbo.suspect_pages was not read: "+err.Error())
		return
	}
	rows, fs := suspectPageRows(raw)
	c.add(rows...)
	c.find(fs...)
	c.add(areaRow(AreaCorruption, true, ""))
}

// suspectEvents names suspect_pages' event types.
var suspectEvents = map[int64]string{1: "823 or 824 error", 2: "bad checksum", 3: "torn page", 4: "restored", 5: "repaired", 7: "deallocated by DBCC"}

// suspectPageRows turns the table's rows into the payload's rows and the findings: a database with a damaged page
// (event types 1 to 3) is critical when the newest is under 30 days old (sp_Blitz 90), a warning when older and
// still listed; the table near its 1,000-row cap is a warning (SQL Server stops recording there).
func suspectPageRows(raw []collect.Row) (rows []collect.Row, findings []checkFinding) {
	type agg struct {
		pages, errors int64
		youngest      int64
		last          string
	}
	by := map[string]*agg{}
	var order []string
	for _, r := range raw {
		et, _ := r["event_type"].(int64)
		r["kind"], r["event"] = "suspect_page", suspectEvents[et]
		rows = append(rows, r)
		if et < 1 || et > 3 {
			continue
		}
		name, _ := r["database_name"].(string)
		a, ok := by[name]
		age, _ := r["age_days"].(int64)
		if !ok {
			a = &agg{youngest: age}
			a.last, _ = r["last_update_utc"].(string)
			by[name] = a
			order = append(order, name)
		}
		n, _ := r["error_count"].(int64)
		a.pages++
		a.errors += n
		if age < a.youngest {
			a.youngest = age
			a.last, _ = r["last_update_utc"].(string)
		}
	}
	for _, name := range order {
		a := by[name]
		sev, when := sevCritical, fmt.Sprintf("the newest %d day(s) ago", a.youngest)
		if a.youngest >= suspectDays {
			sev = sevWarning
		}
		findings = append(findings, checkFinding{Area: AreaCorruption, Check: "suspect pages", Object: name, Severity: sev, Rule: "sp_Blitz 90",
			Value: strconv.FormatInt(a.pages, 10), Explain: fmt.Sprintf("%s: %d damaged page(s) in msdb.dbo.suspect_pages, %d read error(s), %s (%s): run DBCC CHECKDB and restore the pages", name, a.pages, a.errors, when, a.last)})
	}
	if n := len(raw); n >= suspectNearCap {
		findings = append(findings, checkFinding{Area: AreaCorruption, Check: "suspect pages table nearly full", Object: "msdb.dbo.suspect_pages", Severity: sevWarning,
			Rule: "dbachecks SuspectPageLimit", Value: strconv.Itoa(n), Explain: fmt.Sprintf("msdb.dbo.suspect_pages holds %d of its %d rows: at the cap SQL Server records no further page; delete the restored and repaired rows", n, suspectCap)})
	}
	return rows, findings
}

// identityCollector is mssql_identity: the identity columns nearest their type's limit, every six hours. It
// enters every ONLINE user database the login can enter (one SELECT through that database's sys.sp_executesql,
// which changes no session setting) and keeps the columns at 10 per cent of their type's range or more, the 50
// fullest per database. A database it could not enter is stored as not scanned, with the reason.
//
// Rights: the login must be able to enter the database (CONNECT ANY DATABASE, or a user there) and see its
// tables' definitions (VIEW ANY DEFINITION). Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL
// Managed Instance; not on Azure SQL Database. The share used is of the range the column can count through: from 0,
// or from its seed when the seed is negative (IDENTITY(-2147483648, 1) doubles an int's range). A column that counts
// down (a negative increment) is not weighed. A login that can enter none of the user databases leaves the area
// not read, with the reason.
type identityCollector struct{}

func init() { Register(identityCollector{}) }

func (identityCollector) Name() string                   { return Prefix + "identity" }
func (identityCollector) DefaultInterval() time.Duration { return 6 * time.Hour }

// Timeout: one short read per database.
func (identityCollector) Timeout() time.Duration { return 5 * time.Minute }

func (identityCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not yet on Azure SQL Database (one database is the instance there; a later wave)"
	case !info.ViewAnyDefinition:
		return false, "the login lacks VIEW ANY DEFINITION: the tables' identity columns are not visible to it"
	}
	return true, ""
}

// identityDatabasesSQL: the user databases with whether the login can enter them.
const identityDatabasesSQL = `SELECT d.database_id, d.name AS database_name, CAST(d.state_desc AS nvarchar(60)) AS state,
  CAST(CASE WHEN d.state = 0 AND HAS_DBACCESS(d.name) = 1 THEN 1 ELSE 0 END AS int) AS can_enter, QUOTENAME(d.name) AS quoted_name
FROM sys.databases d
WHERE d.database_id > 4 AND d.source_database_id IS NULL
ORDER BY d.name`

// IdentityFloorPct: a column under this share of its type's range is not stored.
const IdentityFloorPct = 10

// identitySQL runs inside one database: the count of identity columns of its user tables and the fullest of them.
// The type's largest value (tinyint 255, smallint 32767, int 2147483647, bigint 9223372036854775807, decimal and
// numeric 10^precision - 1) is returned exactly, as text; the share is taken in float: (last - base) / (largest -
// base), base the seed when it is negative, else 0. One row always comes back: the count, and NULLs when no column
// is at the floor. %s is the database's name from QUOTENAME on the server; %d the floor.
const identitySQL = `EXEC %s.sys.sp_executesql N'SELECT t.columns_total, q.schema_name, q.table_name, q.column_name, q.type_name, q.last_value, q.max_value, q.pct_used
FROM (SELECT COUNT(*) AS columns_total FROM sys.identity_columns c JOIN sys.objects o ON o.object_id = c.object_id AND o.type = ''U'') t
LEFT JOIN (
  SELECT TOP (50) s.name AS schema_name, o.name AS table_name, c.name AS column_name, ty.name AS type_name,
    CAST(CAST(c.last_value AS decimal(38, 0)) AS varchar(40)) AS last_value, m.max_text AS max_value,
    CAST((CAST(CAST(c.last_value AS decimal(38, 0)) AS float) - b.base) * 100 / (m.max_value - b.base) AS decimal(9, 2)) AS pct_used
  FROM sys.identity_columns c
  JOIN sys.objects o ON o.object_id = c.object_id AND o.type = ''U''
  JOIN sys.schemas s ON s.schema_id = o.schema_id
  JOIN sys.types ty ON ty.user_type_id = c.system_type_id
  CROSS APPLY (SELECT CASE ty.name WHEN ''tinyint'' THEN CAST(255 AS float) WHEN ''smallint'' THEN CAST(32767 AS float)
      WHEN ''int'' THEN CAST(2147483647 AS float) WHEN ''bigint'' THEN CAST(9223372036854775807 AS float)
      ELSE POWER(CAST(10 AS float), c.precision) - 1 END AS max_value,
    CAST(CASE ty.name WHEN ''tinyint'' THEN ''255'' WHEN ''smallint'' THEN ''32767'' WHEN ''int'' THEN ''2147483647''
      WHEN ''bigint'' THEN ''9223372036854775807'' ELSE REPLICATE(''9'', c.precision) END AS varchar(40)) AS max_text) m
  CROSS APPLY (SELECT CASE WHEN CAST(c.seed_value AS decimal(38, 0)) < 0 THEN CAST(CAST(c.seed_value AS decimal(38, 0)) AS float)
      ELSE CAST(0 AS float) END AS base) b
  WHERE c.last_value IS NOT NULL AND CAST(c.increment_value AS decimal(38, 0)) > 0
    AND (CAST(CAST(c.last_value AS decimal(38, 0)) AS float) - b.base) * 100 / (m.max_value - b.base) >= %d
  ORDER BY pct_used DESC, s.name, o.name
) q ON 1 = 1'`

// The identity thresholds, per cent of the type's range used (pgvigil's own).
const (
	identityWarnPct = 75
	identityCritPct = 90
)

func (identityCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	dbs, err := QueryRows(ctx, conn, identityDatabasesSQL)
	if err != nil {
		return nil, err
	}
	c := &checksRun{}
	var failed []string
	cut, noRight, scanned := 0, 0, 0
	stop, hasStop := ctx.Deadline()
	for _, db := range dbs {
		name, _ := db["database_name"].(string)
		scan := collect.Row{"kind": "identity_scan", "database_name": name, "scanned": 0, "columns_total": nil, "listed": 0, "note": nil}
		quoted, _ := db["quoted_name"].(string)
		switch {
		case db["can_enter"] != int64(1) || quoted == "":
			if st, _ := db["state"].(string); st != "ONLINE" {
				scan["note"] = "not scanned: the database is " + strings.ToLower(st)
			} else {
				noRight++
				scan["note"] = "not scanned: the login cannot enter the database"
			}
			c.add(scan)
			continue
		case cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second):
			cut++
			scan["note"] = "not scanned: the run's deadline came before this database's turn"
			c.add(scan)
			continue
		}
		raw, qerr := QueryRows(ctx, conn, fmt.Sprintf(identitySQL, quoted, IdentityFloorPct))
		if qerr != nil {
			if ctx.Err() != nil {
				cut++
				scan["note"] = "not scanned: the run's deadline came during this database's read"
			} else {
				failed = append(failed, name)
				scan["note"] = "not scanned: " + qerr.Error()
			}
			c.add(scan)
			continue
		}
		rows, fs := identityRows(name, raw)
		scanned++
		scan["scanned"], scan["listed"] = 1, len(rows)
		if len(raw) > 0 {
			scan["columns_total"] = raw[0]["columns_total"]
		}
		c.add(scan)
		c.add(rows...)
		c.find(fs...)
	}
	// a login that could enter none of the online user databases has read nothing: the area is not read, with the right
	// it lacks (green '0 of 0 columns' would say every column is fine)
	if scanned == 0 && noRight > 0 && cut == 0 && len(failed) == 0 {
		why := fmt.Sprintf("the login can enter none of the %d online user database(s): CONNECT ANY DATABASE (or a user in each) is needed", noRight)
		c.unread(AreaIdentity, "sys.identity_columns", why)
		return c.rows, nil
	}
	var notes []string
	if cut > 0 {
		notes = append(notes, fmt.Sprintf("the run's deadline came before %d database(s) were scanned", cut))
	}
	if len(failed) > 0 {
		notes = append(notes, fmt.Sprintf("%d database(s) were not scanned (%s)", len(failed), firstFew(failed, 5)))
	}
	if noRight > 0 {
		notes = append(notes, fmt.Sprintf("%d database(s) were not scanned: the login cannot enter them", noRight))
	}
	note := strings.Join(notes, "; ")
	if note != "" {
		c.add(collect.Row{"kind": "collector_error", "source": "sys.identity_columns", "message": note})
	}
	c.add(areaRow(AreaIdentity, true, note))
	return c.rows, nil
}

// identityRows turns one database's read into the payload's column rows and the findings of the columns past a
// threshold.
func identityRows(database string, raw []collect.Row) (rows []collect.Row, findings []checkFinding) {
	for _, r := range raw {
		col, _ := r["column_name"].(string)
		if col == "" {
			continue // the row that only carries the count
		}
		pctText, _ := r["pct_used"].(string)
		pct, _ := strconv.ParseFloat(pctText, 64)
		row := collect.Row{"kind": "identity", "database_name": database, "schema_name": r["schema_name"], "table_name": r["table_name"],
			"column_name": col, "type_name": r["type_name"], "last_value": r["last_value"], "max_value": r["max_value"], "pct_used": pct,
			"status": "ok"}
		sev := ""
		switch {
		case pct >= identityCritPct:
			sev = sevCritical
		case pct >= identityWarnPct:
			sev = sevWarning
		}
		if sev != "" {
			row["status"] = statusOf(sev)
			schema, _ := r["schema_name"].(string)
			table, _ := r["table_name"].(string)
			typ, _ := r["type_name"].(string)
			last, _ := r["last_value"].(string)
			max, _ := r["max_value"].(string)
			findings = append(findings, checkFinding{Area: AreaIdentity, Check: "identity column near its limit", Object: database + "." + schema + "." + table + "." + col,
				Severity: sev, Rule: "pgvigil identity", Value: pctText,
				Explain: fmt.Sprintf("%s.%s.%s.%s (%s) is at %s of %s: %s %% of the type's range used (warning at %d, critical at %d); at the limit every insert fails", database, schema, table, col, typ, last, max, pctText, identityWarnPct, identityCritPct)})
		}
		rows = append(rows, row)
	}
	return rows, findings
}
