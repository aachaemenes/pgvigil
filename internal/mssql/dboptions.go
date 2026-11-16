package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
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
  CAST(DB_NAME(d.source_database_id) AS nvarchar(128)) AS snapshot_of,
  CAST(d.is_published AS int) AS published, CAST(d.is_merge_published AS int) AS merge_published,
  CAST(d.is_subscribed AS int) AS subscribed, CAST(d.is_distributor AS int) AS distributor,
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

// user: a database someone made, online, not a snapshot and not the platform's own (RDS's rdsadmin, Cloud SQL's
// gcloud_cloudsqladmin: platformOwnDatabase, here by name alone): the option rules judge these.
func (d dbFacts) user() bool {
	return d.id() > 4 && d.online() && !d.snapshot() && !strings.EqualFold(d.name(), "rdsadmin") && !strings.EqualFold(d.name(), "gcloud_cloudsqladmin")
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
	// BLITZ-GAP (the lead 05:2x): sp_Blitz 19, 21 and 77, judged by pgvigil over its own read of sys.databases
	{"replication", AreaDBOptions, "replication in use", func(d dbFacts, _ serverFacts) (string, string, string) {
		var on []string
		for _, f := range []struct{ key, words string }{
			{"published", "published for transactional or snapshot replication"}, {"merge_published", "published for merge replication"},
			{"subscribed", "subscribed to a publication"}, {"distributor", "the distribution database"},
		} {
			if d.on(f.key) {
				on = append(on, f.words)
			}
		}
		if len(on) == 0 || !d.online() {
			return "", "", ""
		}
		return sevInfo, "sp_Blitz 19", strings.Join(on, "; ")
	}},
	{"encrypted", AreaDBOptions, "database encrypted", func(d dbFacts, _ serverFacts) (string, string, string) {
		if d.user() && d.on("encrypted") { // tempdb is encrypted whenever a database uses TDE: not a finding of its own
			return sevInfo, "sp_Blitz 21", "TDE is on: a restore on another server needs the certificate that protects its key, " +
				"with its private key (the Security tab lists master's certificates and their use)"
		}
		return "", "", ""
	}},
	{"snapshot", AreaDBOptions, "database snapshot", func(d dbFacts, _ serverFacts) (string, string, string) {
		if !d.snapshot() {
			return "", "", ""
		}
		src := d.text("snapshot_of")
		if src == "" {
			src = "its source database"
		}
		return sevInfo, "sp_Blitz 77", "a database snapshot of " + src + ": each page changed in " + src + " after it was taken is first copied into it"
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
		detail := fmt.Sprintf("%.1f %% of the %.0f MB log is in use (warning at %d, critical at %d; read by DBCC SQLPERF(LOGSPACE)); log reuse wait: %s", pct, size, logWarnPct, logCritPct, wait)
		// task 407 (SQLMonitor's LogSaver, never its KILL): the transaction that keeps the log from clearing
		if wait == "ACTIVE_TRANSACTION" {
			holder := d.text("log_holder")
			if holder == "" {
				holder = "holder unknown (no open transaction wrote to this log at the read)"
			}
			detail += "; " + holder
		}
		return sev, "dbachecks LogfilePercentUsed", detail
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
		ageMin, _ := d.num("checkdb_age_min")
		days := ageMin / 1440
		// a grace of half a day past each threshold: a weekly CHECKDB is 7 days old when the next one starts
		switch {
		case ageMin >= checkdbCritDays*1440+checkdbGraceMin:
			return sevCritical, "sp_Blitz 68", fmt.Sprintf("the last good DBCC CHECKDB is %d days old (critical past %d)", days, checkdbCritDays)
		case ageMin >= checkdbWarnDays*1440+checkdbGraceMin:
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
		applyLogHolders(ctx, conn, raw, c)
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

// IdentityFloorPct is the share of its type's range under which a column is not stored.
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

// The identity rule's lines, per cent of the type's range used (pgvigil's own defaults). An instance's
// mssql_thresholds may set its own: identity_warn_pct and identity_crit_pct (IdentityLimits).
const (
	identityWarnPct = 75
	identityCritPct = 90
)

// IdentityThresholds are the names under an instance's mssql_thresholds that are the identity rule's, with their
// defaults. They are not written to the repository's threshold store (its names are the HA/DR, jobs and backups
// ones): the runner hands the two numbers to the collection on Info.
var IdentityThresholds = map[string]float64{"identity_warn_pct": identityWarnPct, "identity_crit_pct": identityCritPct}

// IdentityLimits gives the identity rule's two lines for an instance's mssql_thresholds block, the default where a
// name is not set. A line is a number from the floor (IdentityFloorPct: a column under it is not read, so a line
// under it could never be crossed) to 100, and the warning line is under the critical one. On an error the defaults
// come back with it.
func IdentityLimits(t map[string]any) (warn, crit float64, err error) {
	lines := [2]float64{identityWarnPct, identityCritPct}
	for i, k := range [2]string{"identity_warn_pct", "identity_crit_pct"} {
		v, set := t[k]
		if !set {
			continue
		}
		n, ok := number(v)
		if !ok || n < IdentityFloorPct || n > 100 {
			return identityWarnPct, identityCritPct, fmt.Errorf("mssql threshold %s: %v is not a number from %d to 100 (a column under %d %% of its range is not read)", k, v, IdentityFloorPct, IdentityFloorPct)
		}
		lines[i] = n
	}
	warn, crit = lines[0], lines[1]
	if warn >= crit {
		return identityWarnPct, identityCritPct, fmt.Errorf("mssql threshold identity_warn_pct %s is not under identity_crit_pct %s (the default lines are %d and %d)", pctLine(warn), pctLine(crit), identityWarnPct, identityCritPct)
	}
	return warn, crit, nil
}

// identityLines: the lines the runner set on Info from the instance's mssql_thresholds; the defaults when it set
// none.
func identityLines(info Info) (warn, crit float64) {
	if info.IdentityWarnPct > 0 && info.IdentityCritPct > info.IdentityWarnPct {
		return info.IdentityWarnPct, info.IdentityCritPct
	}
	return identityWarnPct, identityCritPct
}

// pctLine writes a line as a person wrote it: 50, 62.5.
func pctLine(v float64) string { return strconv.FormatFloat(v, 'f', -1, 64) }

func (identityCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	dbs, err := QueryRows(ctx, conn, identityDatabasesSQL)
	if err != nil {
		return nil, err
	}
	c := &checksRun{}
	var failed []string
	cut, noRight, scanned := 0, 0, 0
	warn, crit := identityLines(info)
	stop, hasStop := ctx.Deadline()
	for _, db := range dbs {
		name, _ := db["database_name"].(string)
		if platformOwnDatabase(info.Kind, name) {
			continue
		}
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
		rows, fs := identityRowsAt(name, raw, warn, crit)
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

// identityRows judges one database's read with the default lines.
func identityRows(database string, raw []collect.Row) (rows []collect.Row, findings []checkFinding) {
	return identityRowsAt(database, raw, identityWarnPct, identityCritPct)
}

// identityRowsAt turns one database's read into the payload's column rows and the findings of the columns at or past
// a line: warn and crit are the lines in force for the instance, and each finding names them.
func identityRowsAt(database string, raw []collect.Row, warn, crit float64) (rows []collect.Row, findings []checkFinding) {
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
		case pct >= crit:
			sev = sevCritical
		case pct >= warn:
			sev = sevWarning
		}
		if sev != "" {
			row["status"] = statusOf(sev)
			schema, _ := r["schema_name"].(string)
			table, _ := r["table_name"].(string)
			typ, _ := r["type_name"].(string)
			last, _ := r["last_value"].(string)
			maxValue, _ := r["max_value"].(string)
			findings = append(findings, checkFinding{Area: AreaIdentity, Check: "identity column near its limit", Object: database + "." + schema + "." + table + "." + col,
				Severity: sev, Rule: "pgvigil identity", Value: pctText,
				Explain: fmt.Sprintf("%s.%s.%s.%s (%s) is at %s of %s: %s %% of the type's range used (warning at %s, critical at %s); at the limit every insert fails", database, schema, table, col, typ, last, maxValue, pctText, pctLine(warn), pctLine(crit))})
		}
		rows = append(rows, row)
	}
	return rows, findings
}

// logHolderSQL (task 407): per database, tempdb included, the oldest open transaction that wrote to its log
// (database_transaction_begin_time is set at its first log record), ranked on the transaction views alone; only the
// winner of each database is joined to its session and the session's most recent statement. A transaction no session
// holds is named by its unit of work (a distributed one in doubt or orphaned) or by its id. VIEW SERVER STATE.
const logHolderSQL = `SELECT x.database_id, x.transaction_id, st.session_id, s.login_name, s.host_name, s.program_name, x.uow, x.started_at_utc,
       LEFT(qt.text, 2000) AS statement
FROM (SELECT dt.database_id, CAST(dt.transaction_id AS bigint) AS transaction_id, CAST(at.transaction_uow AS nvarchar(40)) AS uow,
             CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), dt.database_transaction_begin_time), 126) + 'Z' AS started_at_utc,
             ROW_NUMBER() OVER (PARTITION BY dt.database_id ORDER BY dt.database_transaction_begin_time, dt.transaction_id) AS rn
        FROM sys.dm_tran_database_transactions dt
        JOIN sys.dm_tran_active_transactions at ON at.transaction_id = dt.transaction_id
       WHERE dt.database_transaction_begin_time IS NOT NULL) x
LEFT JOIN sys.dm_tran_session_transactions st ON st.transaction_id = x.transaction_id
LEFT JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
LEFT JOIN sys.dm_exec_connections c ON c.session_id = st.session_id AND c.parent_connection_id IS NULL
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) qt
WHERE x.rn = 1`

// needsLogHolder: a database whose log is past the warning line and waits on an active transaction.
func needsLogHolder(r collect.Row) bool {
	pct, ok := r["log_used_pct"].(float64)
	return ok && pct >= logWarnPct && dbFacts{r}.text("log_reuse_wait") == "ACTIVE_TRANSACTION"
}

// applyLogHolders reads the holders only when a database needs one (needsLogHolder) and writes each such database's
// holder as a sentence (log_holder) for the log rule.
func applyLogHolders(ctx context.Context, conn *sql.Conn, raw []collect.Row, c *checksRun) {
	need := false
	for _, r := range raw {
		if needsLogHolder(r) {
			need = true
			break
		}
	}
	if !need {
		return
	}
	rows, err := QueryRows(ctx, conn, logHolderSQL)
	if err != nil {
		c.add(collect.Row{"kind": "collector_error", "source": "sys.dm_tran_database_transactions", "message": "the log's holder was not read: " + err.Error()})
	}
	mapLogHolders(raw, rows, err)
}

// mapLogHolders writes log_holder on each database that needs one: the holder read for its database id; 'holder not
// read: <error>' when the read failed (never a denial that one exists); nothing when the read found none (the rule
// then says no open transaction wrote to the log).
func mapLogHolders(raw, holders []collect.Row, readErr error) {
	by := map[int64]collect.Row{}
	for _, h := range holders {
		if id, ok := asInt64(h["database_id"]); ok {
			by[id] = h
		}
	}
	for _, r := range raw {
		if !needsLogHolder(r) {
			continue
		}
		if readErr != nil {
			r["log_holder"] = "holder not read: " + readErr.Error()
			continue
		}
		if h, ok := by[dbFacts{r}.id()]; ok {
			r["log_holder"] = logHolderText(h)
		}
	}
}

// logHolderText: 'held by session 57 (login, host, program), open since ..., last statement: ...', or the unit of work of
// a transaction no session holds.
func logHolderText(h collect.Row) string {
	str := func(k, none string) string {
		if v, _ := h[k].(string); v != "" {
			return v
		}
		return none
	}
	sid, ok := asInt64(h["session_id"])
	if !ok || sid < 0 {
		// a transaction no session holds: distributed (in doubt or orphaned) when it has a unit of work; a local one
		// (a deferred transaction after recovery, a system transaction) has the all-zero uow
		if uow := str("uow", ""); uow != "" && strings.Trim(uow, "0-") != "" {
			return fmt.Sprintf("held by a distributed transaction, uow %s, open since %s (no session holds it: an in-doubt or orphaned transaction)",
				uow, str("started_at_utc", "not read"))
		}
		tid, _ := asInt64(h["transaction_id"])
		return fmt.Sprintf("holder unknown (no session holds transaction %d, open since %s)", tid, str("started_at_utc", "not read"))
	}
	return fmt.Sprintf("held by session %d (%s, %s, %s), open since %s; last statement: %s", sid, str("login_name", "login not read"),
		str("host_name", "host not read"), str("program_name", "program not read"), str("started_at_utc", "not read"), str("statement", "not read"))
}

// ---- mssql_confcheck and mssql_linkedserver_test (migration 0160) ---------------------------------------------------

// confcheckCollector is mssql_confcheck (hourly): the facts the configuration checks of 0160 judge that no other
// collection reads. Each part is read on its own and says 'not read' with the right or the platform when it cannot
// be; nothing is written on the server.
//
//   - names: @@SERVERNAME, SERVERPROPERTY('ServerName'), the machine and its physical NetBIOS name (any login).
//   - machine: the host's platform, the CPU count and dbatools' advised MAXDOP for it (VIEW SERVER STATE).
//   - xe: every server event session, whether it starts with the server and whether it runs (VIEW SERVER STATE: a
//     login without it gets an empty list and no error, so the part is not read without it).
//   - errorlog: the error log files kept (NumErrorLogs through xp_instance_regread, the return code captured; on
//     Windows no value = the default 6, on Linux no value = errorlog.numerrorlogs is not set) and the files present.
//   - startup: master's startup procedures (VIEW ANY DEFINITION).
//   - databases: per database its state, read-only, standby, recovery model, Query Store, a secondary's role (a
//     mirror, an availability group secondary, a log shipping secondary) and the database-scoped MAXDOP of each
//     database the login can enter.
//   - linked: the linked servers and the shape of their login mappings (who is mapped, with its own credential or a
//     remote login; never the remote login's name or password).
type confcheckCollector struct{}

func init() {
	Register(confcheckCollector{})
	Register(linkedServerTestCollector{})
}

func (confcheckCollector) Name() string                   { return Prefix + "confcheck" }
func (confcheckCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: one statement per database for the scoped MAXDOP.
func (confcheckCollector) Timeout() time.Duration { return 5 * time.Minute }

func (confcheckCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database: the server's configuration is the service's there"
	}
	return true, ""
}

const confNamesSQL = `SELECT CAST(@@SERVERNAME AS nvarchar(128)) AS server_name,
  CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS property_server_name,
  CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS machine_name,
  CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(128)) AS netbios`

// confHostSQL: sys.dm_os_host_info came with SQL Server 2017; an older server is a Windows one.
const confHostSQL = `SELECT CAST(host_platform AS nvarchar(60)) AS host_platform FROM sys.dm_os_host_info`

const confXESQL = `SELECT CAST(s.name AS nvarchar(256)) AS name, CAST(s.startup_state AS int) AS autostart,
  CAST(CASE WHEN x.name IS NULL THEN 0 ELSE 1 END AS int) AS running
FROM sys.server_event_sessions s
LEFT JOIN sys.dm_xe_sessions x ON x.name = s.name
ORDER BY s.name`

// confErrorLogSQL: the registry value SQL Server reads at its start; rc is xp_instance_regread's return code (an
// xp_ failure is a message, not an error a TRY block sees).
const confErrorLogSQL = `DECLARE @v int, @rc int;
EXEC @rc = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', @v OUTPUT;
SELECT CAST(@rc AS int) AS rc, CAST(@v AS int) AS num_errorlogs`

const confErrorLogFilesSQL = `CREATE TABLE #pgv_cc_el (archive int, log_date nvarchar(60), size_bytes bigint);
INSERT #pgv_cc_el EXEC sys.sp_enumerrorlogs;
SELECT CAST(COUNT(*) AS int) AS files FROM #pgv_cc_el;
DROP TABLE #pgv_cc_el`

const confStartupSQL = `SELECT CAST(name AS nvarchar(256)) AS name FROM master.sys.procedures
WHERE OBJECTPROPERTY(object_id, 'ExecIsStartup') = 1 ORDER BY name`

// confDatabasesSQL: every database but the snapshots. %s is the availability group expression (asked only where
// Always On is enabled and the server's state is readable).
const confDatabasesSQL = `SELECT CAST(d.name AS nvarchar(256)) AS database_name, QUOTENAME(d.name) AS quoted_name,
  CAST(d.state_desc AS nvarchar(60)) AS state, CAST(d.is_read_only AS int) AS read_only, CAST(d.is_in_standby AS int) AS in_standby,
  CAST(d.recovery_model_desc AS nvarchar(60)) AS recovery_model, CAST(d.is_query_store_on AS int) AS query_store,
  CAST(CASE WHEN d.state = 0 AND HAS_DBACCESS(d.name) = 1 THEN 1 ELSE 0 END AS int) AS can_enter,
  CAST(CASE WHEN m.mirroring_role = 2 THEN N'mirror' WHEN %s THEN N'availability group secondary' END AS nvarchar(60)) AS secondary_role
FROM sys.databases d
LEFT JOIN sys.database_mirroring m ON m.database_id = d.database_id
WHERE d.source_database_id IS NULL
ORDER BY d.name`

const confLogShippingSQL = `SELECT CAST(secondary_database AS nvarchar(256)) AS name FROM msdb.dbo.log_shipping_secondary_databases`

// confScopedSQL runs inside one database (SQL Server 2016 and later have the view).
const confScopedSQL = `EXEC %s.sys.sp_executesql N'SELECT CAST(value AS int) AS maxdop FROM sys.database_scoped_configurations WHERE name = N''MAXDOP'''`

var confLinkedSQL = `SELECT s.server_id, CAST(s.name AS nvarchar(256)) AS name, CAST(s.product AS nvarchar(256)) AS product,
  CAST(s.provider AS nvarchar(256)) AS provider, CAST(s.data_source AS nvarchar(1024)) AS data_source, CAST(s.catalog AS nvarchar(256)) AS catalog,
  CAST(s.is_rpc_out_enabled AS int) AS rpc_out, CAST(s.is_data_access_enabled AS int) AS data_access,
  CAST(s.connect_timeout AS int) AS connect_timeout, CAST(s.query_timeout AS int) AS query_timeout,
  ` + utcText("s.modify_date") + ` AS modified_utc
FROM sys.servers s
WHERE s.is_linked = 1
ORDER BY s.name`

// confLinkedLoginsSQL: who is mapped at each linked server - a local login or every login (local_principal_id 0),
// with its own credential or a remote login. The remote login's name is not read.
const confLinkedLoginsSQL = `SELECT l.server_id,
  CAST(CASE WHEN l.local_principal_id = 0 THEN N'every login' ELSE ISNULL(p.name, N'principal ' + CAST(l.local_principal_id AS nvarchar(20))) END AS nvarchar(256)) AS local_login,
  CAST(l.uses_self_credential AS int) AS uses_self, CAST(CASE WHEN l.remote_name IS NULL THEN 0 ELSE 1 END AS int) AS has_remote
FROM sys.linked_logins l
JOIN sys.servers s ON s.server_id = l.server_id AND s.is_linked = 1
LEFT JOIN sys.server_principals p ON p.principal_id = l.local_principal_id
ORDER BY l.server_id, l.local_principal_id`

// confPart is the payload's row for one part of the read.
func confPart(part string, read bool, note string) collect.Row {
	return collect.Row{"kind": "part", "part": part, "read": b2i(read), "note": nilIfEmpty(note)}
}

func confFact(key string, value any) collect.Row {
	return collect.Row{"kind": "fact", "key": key, "value": value}
}

// hostedBy names the service that runs the host of a managed instance, or "".
func hostedBy(kind Kind) string {
	switch kind {
	case KindRDS:
		return "Amazon RDS"
	case KindAzureMI:
		return "Azure SQL Managed Instance"
	case KindCloudSQL:
		return "Google Cloud SQL"
	}
	return ""
}

func (confcheckCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	// the names: a failure of this read is the run's failure (any login reads them)
	names, err := QueryRows(ctx, conn, confNamesSQL)
	if err != nil || len(names) != 1 {
		return nil, fmt.Errorf("the server's names: %v", err)
	}
	out := []collect.Row{confPart("names", true, "")}
	for _, k := range []string{"server_name", "property_server_name", "machine_name", "netbios"} {
		out = append(out, confFact(k, names[0][k]))
	}
	fail := func(part, source string, err error) {
		out = append(out, confPart(part, false, "not read: "+err.Error()),
			collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
	}
	perf := perfState(ctx, conn, info, "sys.dm_os_sys_info") == nil
	noState := "not read: the login lacks VIEW SERVER STATE"

	// the machine: the platform, the CPUs and the advised MAXDOP
	platform := ""
	switch {
	case !perf:
		out = append(out, confPart("machine", false, noState+": the host's platform and CPUs are not visible to it"))
	default:
		plat := "Windows"
		if info.Kind == KindAzureMI || info.Major == 0 || info.Major >= 14 {
			if h, herr := QueryRows(ctx, conn, confHostSQL); herr == nil && len(h) == 1 {
				plat, _ = h[0]["host_platform"].(string)
			} else {
				plat = ""
			}
		}
		si, serr := readSysInfo(ctx, conn)
		switch {
		case serr != nil:
			fail("machine", "sys.dm_os_sys_info", serr)
		case plat == "":
			fail("machine", "sys.dm_os_host_info", fmt.Errorf("the host's platform was not read"))
		default:
			platform = plat
			m := machineFacts{}
			m.CPUs, _ = si["cpu_count"].(int64)
			m.NUMANodes, _ = si["numa_nodes"].(int64)
			out = append(out, confPart("machine", true, ""), confFact("host_platform", plat))
			if m.CPUs > 0 {
				out = append(out, confFact("cpu_count", m.CPUs), confFact("advised_maxdop", advisedMaxDOP(m)))
			}
		}
	}

	// the event sessions
	if !perf {
		out = append(out, confPart("xe", false, noState+": the event sessions are not visible to it"))
	} else if xe, xerr := QueryRows(ctx, conn, confXESQL); xerr != nil {
		fail("xe", "sys.server_event_sessions", xerr)
	} else {
		out = append(out, confPart("xe", true, ""))
		for _, r := range xe {
			r["kind"] = "xe"
			out = append(out, r)
		}
	}

	// the error log files kept
	out = append(out, errorLogRows(ctx, conn, info, platform)...)

	// master's startup procedures
	if !info.ViewAnyDefinition {
		out = append(out, confPart("startup", false, "not read: the login lacks VIEW ANY DEFINITION: master's procedures are not visible to it"))
	} else if procs, perr := QueryRows(ctx, conn, confStartupSQL); perr != nil {
		fail("startup", "master.sys.procedures", perr)
	} else {
		list := []string{}
		for _, r := range procs {
			if n, _ := r["name"].(string); n != "" {
				list = append(list, n)
			}
		}
		out = append(out, confPart("startup", true, ""), confFact("startup_procs", list))
	}

	out = append(out, confDatabaseRows(ctx, conn, info)...)
	out = append(out, confLinkedRows(ctx, conn)...)
	return out, nil
}

// errorLogRows reads how many error log files the server keeps. A managed service keeps its own; a Linux server
// gives a value only once errorlog.numerrorlogs is set in mssql.conf.
func errorLogRows(ctx context.Context, conn *sql.Conn, info Info, platform string) []collect.Row {
	if by := hostedBy(info.Kind); by != "" {
		return []collect.Row{confPart("errorlog", false, "not read: "+by+" runs the host and keeps the error log files itself")}
	}
	var out []collect.Row
	files, filesRead := int64(-1), false
	if fr, err := QueryRows(ctx, conn, confErrorLogFilesSQL); err == nil && len(fr) == 1 {
		out = append(out, confFact("errorlog_files", fr[0]["files"]))
		files, filesRead = asInt64(fr[0]["files"])
	}
	rows, err := QueryRows(ctx, conn, confErrorLogSQL)
	switch {
	case err != nil:
		return append(out, confPart("errorlog", false, "not read: xp_instance_regread failed: "+err.Error()))
	case len(rows) != 1 || rows[0]["rc"] != int64(0):
		return append(out, confPart("errorlog", false, "not read: xp_instance_regread did not answer (its return code was not 0)"))
	}
	kept, set := rows[0]["num_errorlogs"].(int64)
	return append(out, numErrorLogsRows(platform, kept, set, files, filesRead)...)
}

// numErrorLogsRows turns the registry read of NumErrorLogs into the errorlog part and its count. A value read is the
// count. No value on Windows is SQL Server's default of 6 archived files only while the files present agree (the
// current log and at most 6 archives): the registry read returns 0 and no value both when the value is not set and
// when a login may not read it, so more files than the default keeps means the value is set and was not readable.
func numErrorLogsRows(platform string, kept int64, set bool, files int64, filesRead bool) []collect.Row {
	switch {
	case set:
		return []collect.Row{confPart("errorlog", true, ""), confFact("num_errorlogs", kept)}
	case platform == "Windows" && filesRead && files <= 7:
		return []collect.Row{confPart("errorlog", true, "NumErrorLogs is not set: the default of 6 applies"), confFact("num_errorlogs", int64(6))}
	case platform == "Windows" && filesRead:
		return []collect.Row{confPart("errorlog", false, fmt.Sprintf("not read: NumErrorLogs gave no value while the server keeps %d error log files (more than the default keeps): the value is set and the login may not read it", files))}
	case platform == "Windows":
		return []collect.Row{confPart("errorlog", false, "not read: NumErrorLogs gave no value and the error log files were not listed: whether the default of 6 applies is not known")}
	case platform == "":
		return []collect.Row{confPart("errorlog", false, "not read: NumErrorLogs is not set and the host's platform is not known (on Windows the default of 6 applies)")}
	}
	return []collect.Row{confPart("errorlog", false, "not read: errorlog.numerrorlogs is not set in mssql.conf, and SQL Server on "+platform+" shows no count without it")}
}

// confDatabaseRows reads every database's row and, where the login can enter, its database-scoped MAXDOP.
func confDatabaseRows(ctx context.Context, conn *sql.Conn, info Info) []collect.Row {
	ag := "1 = 0"
	// sys.fn_hadr_is_primary_replica asks VIEW SERVER STATE (2022's performance right alone is not enough)
	if info.HADREnabled && info.ViewServerState {
		ag = "d.replica_id IS NOT NULL AND ISNULL(sys.fn_hadr_is_primary_replica(d.name), 0) = 0"
	}
	dbs, err := QueryRows(ctx, conn, fmt.Sprintf(confDatabasesSQL, ag))
	if err != nil {
		return []collect.Row{confPart("databases", false, "not read: "+err.Error()),
			{"kind": "collector_error", "source": "sys.databases", "message": err.Error()}}
	}
	// log shipping secondaries: msdb's own table, read where the login may
	shipped := map[string]bool{}
	var notes, roles []string // roles: the secondaries not told apart (the state rule reads them 'not read', never a warning)
	if !info.MsdbAccess {
		roles = append(roles, "log shipping secondaries are not told apart: the login has no access to msdb")
	} else if ls, lerr := QueryRows(ctx, conn, confLogShippingSQL); lerr != nil {
		roles = append(roles, "log shipping secondaries are not told apart: "+lerr.Error())
	} else {
		for _, r := range ls {
			if n, _ := r["name"].(string); n != "" {
				shipped[strings.ToLower(n)] = true
			}
		}
	}
	if info.HADREnabled && !info.ViewServerState {
		roles = append(roles, "availability group secondaries are not told apart: the login lacks VIEW SERVER STATE")
	}
	notes = append(notes, roles...)
	var out []collect.Row
	stop, hasStop := ctx.Deadline()
	cut := 0
	for _, db := range dbs {
		name, _ := db["database_name"].(string)
		if platformOwnDatabase(info.Kind, name) {
			continue
		}
		row := collect.Row{"kind": "database", "database_name": name, "state": db["state"], "read_only": db["read_only"],
			"in_standby": db["in_standby"], "recovery_model": db["recovery_model"], "query_store": db["query_store"],
			"secondary_role": db["secondary_role"], "scoped_maxdop": nil, "scoped_note": nil}
		if row["secondary_role"] == nil && shipped[strings.ToLower(name)] {
			row["secondary_role"] = "log shipping secondary"
		}
		quoted, _ := db["quoted_name"].(string)
		switch {
		case info.Major > 0 && info.Major < 13 && info.Kind != KindAzureMI:
			row["scoped_note"] = "not read: SQL Server 2016 and later have database-scoped configurations"
		case db["can_enter"] != int64(1) || quoted == "":
			if st, _ := db["state"].(string); st != "ONLINE" {
				row["scoped_note"] = "not read: the database is " + strings.ToLower(st)
			} else {
				row["scoped_note"] = "not read: the login cannot enter the database"
			}
		case cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second):
			cut++
			row["scoped_note"] = "not read: the run's deadline came before this database's turn"
		default:
			if sc, serr := QueryRows(ctx, conn, fmt.Sprintf(confScopedSQL, quoted)); serr != nil {
				row["scoped_note"] = "not read: " + serr.Error()
			} else if len(sc) == 1 {
				row["scoped_maxdop"] = sc[0]["maxdop"]
			} else {
				row["scoped_note"] = "not read: the database lists no MAXDOP configuration"
			}
		}
		out = append(out, row)
	}
	if cut > 0 {
		notes = append(notes, fmt.Sprintf("the run's deadline came before %d database(s) gave their scoped MAXDOP", cut))
	}
	head := []collect.Row{confPart("databases", true, strings.Join(notes, "; "))}
	if len(roles) > 0 {
		head = append(head, confFact("secondary_roles_unread", strings.Join(roles, "; ")))
	}
	return append(head, out...)
}

// confLinkedSeesAllSQL: whether the login sees every linked server in sys.servers (Microsoft's sys.servers page names
// ALTER ANY LINKED SERVER, ALTER ANY LOGIN, setupadmin and sysadmin; VIEW ANY DEFINITION shows every server's
// metadata).
const confLinkedSeesAllSQL = `SELECT CAST(CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LINKED SERVER') = 1
  OR HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LOGIN') = 1 OR HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION') = 1
  OR IS_SRVROLEMEMBER('setupadmin') = 1 OR IS_SRVROLEMEMBER('sysadmin') = 1 THEN 1 ELSE 0 END AS int) AS sees_all`

// linkedListShortNote is the linked part's note when the login may not see every linked server.
const linkedListShortNote = "only the linked servers that keep their default login mapping or map the collector's login are visible: " +
	"ALTER ANY LINKED SERVER, ALTER ANY LOGIN, VIEW ANY DEFINITION, setupadmin or sysadmin shows them all"

// confLinkedRows reads the linked servers and who is mapped at each.
func confLinkedRows(ctx context.Context, conn *sql.Conn) []collect.Row {
	servers, err := QueryRows(ctx, conn, confLinkedSQL)
	if err != nil {
		return []collect.Row{confPart("linked", false, "not read: "+err.Error()),
			{"kind": "collector_error", "source": "sys.servers", "message": err.Error()}}
	}
	// sys.servers shows a login the linked servers that keep their default login mapping or map that login; every
	// one only with one of these rights. Without them the list may be short: nothing missing from it is taken as gone.
	complete := int64(0)
	if r, rerr := QueryRows(ctx, conn, confLinkedSeesAllSQL); rerr == nil && len(r) == 1 {
		complete, _ = asInt64(r[0]["sees_all"])
	}
	note := ""
	if complete != 1 {
		note = linkedListShortNote
	}
	out := []collect.Row{confPart("linked", true, note), confFact("linked_list_complete", complete)}
	if len(servers) == 0 {
		return out
	}
	logins, lerr := QueryRows(ctx, conn, confLinkedLoginsSQL)
	byServer := map[int64][]map[string]any{}
	for _, l := range logins {
		id, _ := l["server_id"].(int64)
		byServer[id] = append(byServer[id], map[string]any{"local": l["local_login"], "self": l["uses_self"] == int64(1), "remote": l["has_remote"] == int64(1)})
	}
	for _, s := range servers {
		id, _ := s["server_id"].(int64)
		delete(s, "server_id")
		s["kind"] = "linked"
		// a server with no mapping row visible: the mappings were not read (a login without the right gets none, and no error)
		s["logins_read"] = b2i(lerr == nil && len(byServer[id]) > 0)
		if m := byServer[id]; m != nil {
			s["logins"] = m
		} else {
			s["logins"] = []map[string]any{}
		}
		out = append(out, s)
	}
	return out
}

// LinkedServerTestTag is the tag that switches mssql_linkedserver_test on for an instance.
const LinkedServerTestTag = "pgvigil:linkedserver-test"

// linkedServerTestCollector is mssql_linkedserver_test (hourly, only on an instance that carries the tag
// pgvigil:linkedserver-test): sys.sp_testlinkedserver for each linked server, FROM the monitored server, as the
// collector's own login maps there. At most linkedTestsPerRun servers a run, in name order from where the last run
// stopped (a cursor), each
// under its own deadline; a server of another provider than SQL Server's own (SQLNCLI*, MSOLEDBSQL*) is left out.
// Error 7416 (no login mapping) and 18456 (the mapped login failed) are 'unmapped': the collector's login, not the
// link. The test opens a connection and closes it: nothing is read or written on either server.
type linkedServerTestCollector struct{}

const (
	linkedTestsPerRun  = 2
	linkedTestDeadline = 30 * time.Second
)

func (linkedServerTestCollector) Name() string                   { return Prefix + "linkedserver_test" }
func (linkedServerTestCollector) DefaultInterval() time.Duration { return time.Hour }
func (linkedServerTestCollector) Timeout() time.Duration {
	return linkedTestsPerRun*linkedTestDeadline + 20*time.Second
}

func (linkedServerTestCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not on Azure SQL Database: it has no linked servers"
	case !info.LinkedServerTest:
		return false, "off: the instance does not carry the tag " + LinkedServerTestTag
	}
	return true, ""
}

const linkedTestListSQL = `SELECT CAST(s.name AS nvarchar(256)) AS name, CAST(s.provider AS nvarchar(256)) AS provider
FROM sys.servers s WHERE s.is_linked = 1 ORDER BY s.name`

// linkedTestSQL: one test; a failure is caught and returned as a row. @p1 the linked server's name.
const linkedTestSQL = `DECLARE @t0 datetime2 = SYSDATETIME();
BEGIN TRY
  EXEC sys.sp_testlinkedserver @servername = @p1;
  SELECT CAST(0 AS int) AS error_number, CAST(NULL AS nvarchar(1000)) AS error_message, DATEDIFF(millisecond, @t0, SYSDATETIME()) AS ms;
END TRY
BEGIN CATCH
  SELECT CAST(ERROR_NUMBER() AS int) AS error_number, CAST(LEFT(ERROR_MESSAGE(), 1000) AS nvarchar(1000)) AS error_message, DATEDIFF(millisecond, @t0, SYSDATETIME()) AS ms;
END CATCH`

// sqlServerProvider says whether a linked server's provider is one of SQL Server's own.
func sqlServerProvider(provider string) bool {
	p := strings.ToUpper(strings.TrimSpace(provider))
	return strings.HasPrefix(p, "SQLNCLI") || strings.HasPrefix(p, "MSOLEDBSQL") || p == "SQLOLEDB"
}

// linkedTestOutcome names a test's outcome from its error number.
func linkedTestOutcome(errorNumber int64) string {
	switch errorNumber {
	case 0:
		return "ok"
	case 7416, 18456:
		return "unmapped"
	}
	return "failed"
}

// linkedLoginRefused are the errors of a mapped login the remote server refused (the login failed, is disabled,
// locked out, or its password expired or must change): the server's text for them names that login.
var linkedLoginRefused = map[int64]bool{18452: true, 18456: true, 18470: true, 18486: true, 18487: true, 18488: true}

// linkedLoginRefusedText is what is kept in place of such an error's own text.
const linkedLoginRefusedText = "the login mapped for the collector's login was refused at the remote server"

// reQuotedPrincipal finds a login, user or principal named in quotes in a server's error text, through the text's
// last quote (a name may hold a quote of its own: nothing after its first quote is trusted to be outside it).
var reQuotedPrincipal = regexp.MustCompile(`(?is)\b(user|login|principal)\s+['"].*['"]`)

// linkedTestMessage is the error text kept for a connection test, never a remote login's name: a refused login's
// errors keep one fixed sentence, and any other text is cut from a login, user or principal named in quotes through
// its last quote.
func linkedTestMessage(errorNumber int64, message string) string {
	if linkedLoginRefused[errorNumber] {
		return linkedLoginRefusedText
	}
	return reQuotedPrincipal.ReplaceAllString(message, "$1 '<not stored>'")
}

func (linkedServerTestCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, fmt.Errorf("mssql_linkedserver_test runs with its cursor (RunBatches)")
}

// linkedTestCursor is the mssql_cursor source that keeps where the next run starts (last_seq: its index in the list
// of testable linked servers in name order, taken modulo their count), so every server gets its turn.
const linkedTestCursor = "mssql_linkedserver_test"

func (linkedServerTestCollector) RunBatches(ctx context.Context, conn *sql.Conn, _ Info, _ BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	servers, err := QueryRows(ctx, conn, linkedTestListSQL)
	if err != nil {
		return err
	}
	var out []collect.Row
	var testable []string
	for _, s := range servers {
		name, _ := s["name"].(string)
		prov, _ := s["provider"].(string)
		if !sqlServerProvider(prov) {
			out = append(out, collect.Row{"kind": "test", "name": name, "outcome": "not tested",
				"note": "the provider " + prov + " is not one of SQL Server's own: left out"})
			continue
		}
		testable = append(testable, name)
	}
	cur, err := cursor(ctx, linkedTestCursor)
	if err != nil {
		return err
	}
	start, tested := tablesStart(cur, len(testable)), 0
	for i := 0; i < len(testable); i++ {
		name := testable[(start+i)%len(testable)]
		if i >= linkedTestsPerRun || ctx.Err() != nil {
			out = append(out, collect.Row{"kind": "test", "name": name, "outcome": "not tested",
				"note": fmt.Sprintf("at most %d linked servers are tested a run: this one waits for its turn", linkedTestsPerRun)})
			continue
		}
		tctx, cancel := context.WithTimeout(ctx, linkedTestDeadline)
		rows, terr := QueryRows(tctx, conn, linkedTestSQL, name)
		cancel()
		tested++
		switch {
		case terr != nil:
			out = append(out, collect.Row{"kind": "test", "name": name, "outcome": "failed", "error_number": nil,
				"error_message": "the test did not answer in " + linkedTestDeadline.String() + ": " + linkedTestMessage(0, terr.Error()), "seconds": linkedTestDeadline.Seconds()})
		case len(rows) != 1:
			out = append(out, collect.Row{"kind": "test", "name": name, "outcome": "not tested", "note": "the test returned no row"})
		default:
			n, _ := rows[0]["error_number"].(int64)
			ms, _ := rows[0]["ms"].(int64)
			row := collect.Row{"kind": "test", "name": name, "outcome": linkedTestOutcome(n), "seconds": float64(ms) / 1000}
			if n != 0 {
				msg, _ := rows[0]["error_message"].(string)
				row["error_number"], row["error_message"] = n, linkedTestMessage(n, msg)
			}
			out = append(out, row)
		}
	}
	next := int64(0)
	if len(testable) > 0 {
		next = int64((start + tested) % len(testable))
	}
	return emit(append(out, Cursor{LastSeq: next}.Row(linkedTestCursor)))
}
