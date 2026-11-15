// Package export writes the repository to Parquet files, one set per clock hour, for a consumer outside pgvigil
// (docs/parquet-export.md). It only reads the repository.
package export

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Class says how a table is exported.
type Class string

const (
	// Window: the rows whose own time column is inside the hour. That column is the table's partition key, part of
	// its primary key, or the time of an append-only line - never a column an import rewrites at every read.
	Window Class = "window"
	// State: the whole table, in the day's first window. What an import upserts or rebuilds at every read.
	State Class = "state"
	// Dimension: text keyed by a hash: the rows seen in or after the window's start, and the whole table in the
	// day's first window.
	Dimension Class = "dimension"
	// LeftOut: never exported; Why says why.
	LeftOut Class = "left-out"
)

// The two carries of the configuration (export.carry). Each is off unless named.
const (
	CarryText  = "text"  // statement, plan and log text
	CarryAudit = "audit" // who did what: pgvigil's own action logs, the servers' audit trails, logins, roles and grants
)

// Table is one line of the map: a table of the repository and how it leaves it. A table is classed by how its
// import WRITES it (appended under its own time, upserted, rebuilt), never by a column's name: snapshot_at is on
// more than a hundred tables that hold only the current state.
type Table struct {
	Name  string
	Class Class
	Time  string    // Window: the time column. Dimension: the column that says when a row was last seen.
	Carry string    // "", CarryText or CarryAudit: the whole table leaves only with that carry
	Text  []string  // columns of statement, plan or log text: dropped unless the carry holds text
	Drop  []Dropped // columns that never leave
	Why   string    // LeftOut: the reason
}

// Dropped is a column left behind and why.
type Dropped struct{ Column, Reason string }

const (
	whyUI        = "the logins of the web UI: the reader role cannot read it"
	whyCursor    = "a read cursor of the collector"
	whyBaseline  = "the last cumulative counters a delta is computed from"
	whyMark      = "a queue, a mark or a cache of the service"
	whyInventory = "the service's own inventory: connection references, hosts and logins"

	dropMail    = "a mail's subject, body or attachment"
	dropAddress = "an address a message is sent to"
	dropToken   = "a claim token"
	dropURL     = "an address that can carry credentials"
	dropText    = "statement, plan or log text: carried only with export.carry: [text]"
)

func window(name, time string) Table    { return Table{Name: name, Class: Window, Time: time} }
func dimension(name, seen string) Table { return Table{Name: name, Class: Dimension, Time: seen} }
func state(name string) Table           { return Table{Name: name, Class: State} }
func out(name, why string) Table        { return Table{Name: name, Class: LeftOut, Why: why} }

func (t Table) carry(c string) Table       { t.Carry = c; return t }
func (t Table) text(cols ...string) Table  { t.Text = cols; return t }
func (t Table) drop(col, why string) Table { t.Drop = append(t.Drop, Dropped{col, why}); return t }

// tables is the map, in name order. A table of the schema it does not name stops every run (Resolve): a new
// migration's table is classed here from a read of how it is written.
var tables = []Table{
	window("ack_log", "at").carry(CarryAudit),
	state("ack_suppressed"),
	state("acks"),
	state("acl_databases").carry(CarryAudit),
	state("acl_default_privileges").carry(CarryAudit),
	state("acl_schemas").carry(CarryAudit),
	window("actions_log", "at").carry(CarryAudit),
	window("activity_sample", "snapshot_at"),
	window("activity_summary", "snapshot_at"),
	window("admin_audit", "at").carry(CarryAudit),
	out("admin_instances", whyInventory),
	out("admin_inventory_state", whyMark),
	out("admin_page_holder", whyMark),
	out("admin_proposals", whyInventory),
	out("admin_removed", whyInventory),
	out("admin_sources", whyInventory),
	state("alert_channels").drop("destination", dropAddress),
	state("alert_dismissals"),
	window("alert_log", "snapshot_at").drop("destination", dropAddress),
	state("alert_rule_fired"),
	window("alert_rule_log", "at").carry(CarryAudit),
	state("alert_rule_state"),
	state("alert_rules"),
	state("alert_state"),
	out("alert_tests", whyMark),
	window("amcheck_runs", "snapshot_at"),
	state("app_applications"),
	state("app_assignments"),
	state("app_field_source"),
	state("app_not_application"),
	window("backup_sample", "snapshot_at"),
	state("backup_state"),
	window("buffercache_sample", "snapshot_at"),
	window("cloud_io_sample", "snapshot_at"),
	state("collection_dates"),
	window("collection_log", "snapshot_at"),
	window("collector_beats", "at"),
	state("collector_heartbeat"),
	state("collector_instances"),
	window("collector_load", "minute"),
	window("collector_runs", "minute"),
	state("collector_spells"),
	state("collector_streaks"),
	out("compare_findings_cache", whyMark),
	state("compare_state"),
	window("conn_sources", "snapshot_at"),
	state("custom_checks").text("sql"),
	state("custom_report_folders"),
	window("custom_report_log", "at").carry(CarryAudit),
	state("custom_reports").text("body"),
	window("custom_results", "snapshot_at").text("columns", "rows"),
	state("darling_benign_waits"),
	state("database_collations"),
	state("database_extensions"),
	window("database_sizes", "snapshot_at"),
	state("databases"),
	state("db_checks"),
	state("dbadash_instances"),
	out("dbadash_move_ids", whyInventory),
	out("dbadash_moves", whyInventory),
	state("dbadash_repositories"),
	state("dbadash_summary"),
	window("dbadash_summary_history", "snapshot_at"),
	window("dbstats", "snapshot_at"),
	out("dbstats_last", whyBaseline),
	state("depth_databases"),
	state("dms_instances"),
	window("dms_ri_sample", "snapshot_at"),
	state("dms_table_stats"),
	window("dms_task_sample", "snapshot_at"),
	state("dms_tasks"),
	state("drive_thresholds"),
	window("export_runs", "started_at"),
	out("export_state", whyMark),
	window("extension_history", "changed_at"),
	window("function_stats", "snapshot_at"),
	state("hba_rules").carry(CarryAudit),
	window("host_disk_history", "snapshot_at"),
	state("host_disks"),
	window("host_io", "snapshot_at"),
	window("host_sample", "snapshot_at"),
	state("host_state"),
	state("hours_retention"),
	state("index_bloat"),
	state("index_databases"),
	state("index_inventory"),
	state("index_state"),
	window("index_usage_daily", "snapshot_at"),
	state("instance_extension_settings"),
	state("instance_extensions"),
	window("instance_setting_history", "changed_at"),
	state("instance_state"),
	state("instance_tag_overrides"),
	state("instance_versions"),
	state("instances"),
	window("iostats", "snapshot_at"),
	state("job_exclusions"),
	window("job_runs", "start_time").text("command", "return_message"),
	out("job_stats_defer", whyMark),
	out("job_stats_dirty", whyMark),
	out("job_stats_first_build", whyMark),
	window("job_stats_hourly", "snapshot_at"),
	window("job_step_runs", "start_time").text("output"),
	state("job_thresholds"),
	state("job_versions").text("definition", "changes", "script"),
	state("jobs").text("command"),
	out("log_cursor", whyCursor),
	window("log_events", "snapshot_at").text("statement", "detail", "message"),
	window("mssql_activity_read", "snapshot_at"),
	state("mssql_ag_database_state"),
	window("mssql_ag_events", "event_at").text("statement", "message"),
	window("mssql_ag_failovers", "at"),
	window("mssql_ag_sample", "snapshot_at"),
	state("mssql_ag_state"),
	state("mssql_agent_alert"),
	state("mssql_agent_alerting"),
	state("mssql_agent_operator"),
	window("mssql_attentions", "event_at").text("statement"),
	state("mssql_audit"),
	window("mssql_audit_counts", "hour_at").carry(CarryAudit),
	window("mssql_audit_events", "event_at").carry(CarryAudit),
	state("mssql_audit_read"),
	state("mssql_audit_spec"),
	state("mssql_backup_state"),
	window("mssql_blocked_reports", "event_at").text("blocked_statement", "blocking_statement", "report"),
	window("mssql_blocking", "snapshot_at"),
	state("mssql_build"),
	state("mssql_check_area"),
	state("mssql_check_finding"),
	state("mssql_config"),
	state("mssql_config_history"),
	out("mssql_counter_last", whyBaseline),
	window("mssql_counter_read", "snapshot_at"),
	window("mssql_counter_sample", "snapshot_at"),
	state("mssql_counter_series"),
	state("mssql_cpu_info"),
	window("mssql_cpu_sample", "snapshot_at"),
	out("mssql_cursor", whyCursor),
	state("mssql_database_option"),
	window("mssql_database_size", "snapshot_at"),
	window("mssql_deadlocks", "event_at").text("victim_statement", "processes", "resources", "graph"),
	window("mssql_errorlog", "log_at").text("message"),
	window("mssql_failed_logins", "logged_at").carry(CarryAudit),
	out("mssql_fileio_last", whyBaseline),
	window("mssql_fileio_read", "snapshot_at"),
	window("mssql_fileio_sample", "snapshot_at"),
	state("mssql_files"),
	state("mssql_hadr_reads"),
	state("mssql_hadr_thresholds"),
	state("mssql_health"),
	window("mssql_health_components", "event_at"),
	state("mssql_identity_column"),
	state("mssql_identity_scan"),
	state("mssql_index"),
	state("mssql_index_db"),
	out("mssql_indexlock_last", whyBaseline),
	window("mssql_indexlock_read", "snapshot_at"),
	window("mssql_indexlock_sample", "snapshot_at"),
	state("mssql_indexlock_state"),
	state("mssql_instance"),
	window("mssql_job_runs", "snapshot_at").text("message", "failed_message"),
	state("mssql_jobs").text("last_message"),
	out("mssql_jobs_cursor", whyCursor),
	state("mssql_logshipping_state"),
	window("mssql_memory_cache", "snapshot_at"),
	window("mssql_memory_clerk", "snapshot_at"),
	window("mssql_memory_grant_query", "snapshot_at").text("statement"),
	state("mssql_memory_numa"),
	window("mssql_memory_pool", "snapshot_at"),
	state("mssql_memory_reads"),
	window("mssql_memory_rmon", "snapshot_at"),
	window("mssql_memory_sample", "snapshot_at"),
	state("mssql_mirroring_state"),
	state("mssql_missing_index"),
	state("mssql_pc_database"),
	out("mssql_pc_handles", whyBaseline),
	state("mssql_pc_health"),
	state("mssql_pc_health_state"),
	out("mssql_pc_last", whyBaseline),
	state("mssql_pc_list").text("query"),
	window("mssql_pc_read", "snapshot_at"),
	window("mssql_pc_sample", "snapshot_at"),
	state("mssql_pc_state"),
	dimension("mssql_pc_text", "seen_at").carry(CarryText),
	out("mssql_perf_counter_last", whyBaseline),
	window("mssql_plancache_type", "snapshot_at"),
	state("mssql_pool_member"),
	window("mssql_pool_minute", "snapshot_at"),
	state("mssql_pool_thresholds"),
	out("mssql_proc_last", whyBaseline),
	window("mssql_proc_read", "snapshot_at"),
	window("mssql_proc_sample", "snapshot_at"),
	state("mssql_proc_state"),
	state("mssql_property"),
	window("mssql_property_change", "changed_at"),
	state("mssql_pvs"),
	window("mssql_qs_interval", "snapshot_at"),
	dimension("mssql_qs_plan", "snapshot_at").text("plan_xml"),
	dimension("mssql_qs_query", "snapshot_at").text("query_text"),
	window("mssql_qs_runtime", "snapshot_at"),
	state("mssql_qs_store"),
	state("mssql_qs_tuning").text("script"),
	state("mssql_qs_tuning_option"),
	state("mssql_reader_state"),
	state("mssql_replication_state"),
	window("mssql_requests", "snapshot_at"),
	window("mssql_requests_summary", "snapshot_at"),
	state("mssql_rg_group"),
	state("mssql_rg_pool"),
	window("mssql_sched_sample", "snapshot_at"),
	state("mssql_server_option"),
	state("mssql_server_role_members").carry(CarryAudit),
	state("mssql_service"),
	state("mssql_service_ext"),
	window("mssql_session_group", "snapshot_at"),
	window("mssql_session_summary", "snapshot_at"),
	window("mssql_session_tempdb", "snapshot_at"),
	window("mssql_slow_events", "event_at").text("statement", "shape"),
	state("mssql_sql_logins").carry(CarryAudit),
	state("mssql_stat"),
	dimension("mssql_statement_text", "last_seen").carry(CarryText),
	state("mssql_stats_db"),
	state("mssql_suspect_page"),
	window("mssql_table_size", "snapshot_at"),
	state("mssql_tempdb"),
	state("mssql_tempdb_files"),
	window("mssql_trace_events", "event_at").text("statement"),
	window("mssql_trace_flag_history", "changed_at"),
	state("mssql_trace_flags"),
	state("mssql_trace_flags_read"),
	state("mssql_versionstore_db"),
	window("mssql_versionstore_sample", "snapshot_at").text("holder_statement"),
	window("mssql_volume_sample", "snapshot_at"),
	state("mssql_volumes"),
	out("mssql_wait_last", whyBaseline),
	window("mssql_wait_sample", "snapshot_at"),
	state("mssql_wait_state"),
	window("mssql_waiting_summary", "snapshot_at"),
	window("mssql_waiting_tasks", "snapshot_at").text("statement"),
	state("mssql_xe_foreign"),
	state("mssql_xe_foreign_read"),
	state("mssql_xe_state"),
	state("pg_backup_detect"),
	state("pg_backup_tools"),
	state("pg_base_backups"),
	state("pg_db_role_settings"),
	state("pg_db_role_settings_read"),
	state("pg_patroni_members").drop("api_url", dropURL),
	state("pg_patroni_read").drop("url", dropURL),
	window("pg_role_changes", "changed_at").carry(CarryAudit),
	state("pg_role_passwords").carry(CarryAudit),
	state("pg_role_state"),
	state("pg_threshold_keys"),
	state("pg_thresholds"),
	state("pg_wal_replay"),
	window("pgaudit_count_secs", "sec").carry(CarryAudit),
	window("pgaudit_counts", "snapshot_at").carry(CarryAudit),
	window("pgaudit_events", "snapshot_at").carry(CarryAudit),
	state("pgaudit_rules"),
	state("pgaudit_settings"),
	state("pgaudit_state"),
	window("pi_load", "snapshot_at"),
	dimension("pi_sql", "last_seen").carry(CarryText),
	state("pi_state"),
	dimension("plans", "captured_at").carry(CarryText),
	window("pooler_conn_sample", "snapshot_at"),
	window("pooler_sample", "snapshot_at"),
	state("pooler_state"),
	window("purge_runs", "started_at"),
	dimension("query_text", "last_seen").carry(CarryText),
	window("replication_sample", "snapshot_at"),
	state("report_db_properties"),
	window("report_mail_log", "at").carry(CarryAudit),
	state("report_mail_schedules").drop("claim_token", dropToken).drop("recipients", dropAddress),
	window("report_mail_sends", "requested_at").drop("html", dropMail).drop("xlsx", dropMail).drop("recipients", dropAddress).drop("subject", dropMail),
	state("report_read_state"),
	state("role_attributes").carry(CarryAudit),
	state("role_databases"),
	window("role_history", "changed_at").carry(CarryAudit),
	state("role_member_closure").carry(CarryAudit),
	state("role_members").carry(CarryAudit),
	state("role_state"),
	window("schema_changes", "snapshot_at").text("before", "after"),
	state("schema_databases"),
	window("schema_ddl_log", "snapshot_at").text("statement"),
	state("schema_objects").text("definition"),
	state("schema_version"),
	state("sequence_state"),
	window("serverless_sample", "snapshot_at"),
	state("serverless_scaling"),
	window("serverstats", "snapshot_at"),
	dimension("session_sets", "last_seen").text("value", "query"),
	window("session_sets_sample", "snapshot_at"),
	state("session_sets_state"),
	window("slru_sample", "snapshot_at"),
	dimension("statement_text", "last_seen").carry(CarryText),
	out("statements_current", whyBaseline),
	window("statements_delta", "snapshot_at"),
	window("statements_info", "snapshot_at"),
	out("statements_monitor_seen", whyBaseline),
	out("statements_monitor_total", whyBaseline),
	window("storage_sample", "snapshot_at"),
	state("storage_state"),
	window("table_activity", "snapshot_at"),
	state("table_databases"),
	window("table_sizes", "snapshot_at"),
	state("tables"),
	window("temp_sample", "snapshot_at"),
	out("ui_app_contact_routes", whyUI),
	out("ui_app_contacts", whyUI),
	out("ui_users", whyUI),
	state("vacuum_databases"),
	state("vacuum_holders"),
	window("vacuum_runs", "started_at"),
	window("vacuum_sample", "snapshot_at").text("query"),
	state("vacuum_state"),
	state("vacuum_tables"),
	window("version_history", "changed_at"),
	state("version_pending"),
	state("version_upgrade_targets"),
	out("wait_profile_current", whyBaseline),
	window("wait_sample", "snapshot_at"),
	window("wal_state_sample", "snapshot_at"),
}

// Catalog returns the map, in name order.
func Catalog() []Table { return append([]Table(nil), tables...) }

// Options is what the configuration says about what is carried.
type Options struct {
	Carry         []string // CarryText, CarryAudit
	Exclude       []string // more tables left out by name
	StateMaxBytes int64    // a state or dimension table over it is left out and named (0 = no line)
}

func (o Options) carries(c string) bool {
	for _, x := range o.Carry {
		if x == c {
			return true
		}
	}
	return false
}

// Column is a column as the repository's catalogs give it.
type Column struct {
	Name string
	Type string // format_type(): 'timestamp with time zone', 'numeric(5,2)', 'text[]'
	OID  uint32
	Mod  int32
	// NotNull: the column is NOT NULL
	NotNull bool
}

// Resolved is a table of the map as this repository holds it and this configuration carries it.
type Resolved struct {
	Table
	Key         []string  // the primary key
	Columns     []Column  // the columns exported, in the table's own order
	Dropped     []Dropped // the columns left behind under this configuration
	HasInstance bool      // it has a NOT NULL instance_id: read one instance at a time
	Bytes       int64     // its size with its indexes (a partitioned table: its partitions')
	Skip        string    // why it is not exported under this configuration ("" = exported)
}

// Querier is the part of a connection or a transaction Resolve needs.
type Querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

const (
	storeTablesSQL = `/* pgvigil-export:catalog */
SELECT c.relname::text,
       coalesce((SELECT array_agg(a.attname::text ORDER BY k.ord)
                   FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord)
                   JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
                  WHERE i.indrelid = c.oid AND i.indisprimary), '{}'),
       CASE WHEN c.relkind = 'p'
            THEN (SELECT coalesce(sum(pg_total_relation_size(p.relid)), 0)::bigint FROM pg_partition_tree(c.oid) p WHERE p.isleaf)
            ELSE pg_total_relation_size(c.oid) END
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
 ORDER BY c.relname`
	storeColumnsSQL = `/* pgvigil-export:catalog */
SELECT c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod), a.atttypid::oid, a.atttypmod, a.attnotnull
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY c.relname, a.attnum`
)

// Resolve reads the repository's tables (a partition is never a table of its own) and lays the map over them. A
// table of the schema the map does not name is an error before anything is read: its class cannot be guessed.
// A table of the map this repository does not have yet (an older schema) is left out of the result.
func Resolve(ctx context.Context, q Querier, opt Options) ([]Resolved, error) {
	byName := make(map[string]Table, len(tables))
	for _, t := range tables {
		byName[t.Name] = t
	}
	excluded := map[string]bool{}
	for _, x := range opt.Exclude {
		excluded[strings.TrimSpace(x)] = true
	}
	var out []Resolved
	at := map[string]int{}
	var unclassed []string
	rows, err := q.Query(ctx, storeTablesSQL)
	if err != nil {
		return nil, fmt.Errorf("the repository's tables: %w", err)
	}
	for rows.Next() {
		var name string
		var key []string
		var size int64
		if err := rows.Scan(&name, &key, &size); err != nil {
			rows.Close()
			return nil, fmt.Errorf("the repository's tables: %w", err)
		}
		t, ok := byName[name]
		if !ok {
			unclassed = append(unclassed, name)
			continue
		}
		at[name] = len(out)
		out = append(out, Resolved{Table: t, Key: key, Bytes: size})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("the repository's tables: %w", err)
	}
	if len(unclassed) > 0 {
		sort.Strings(unclassed)
		return nil, fmt.Errorf("table %s is not classed: class it in internal/export/catalog.go from how its import writes it (nothing was read or written)", strings.Join(unclassed, ", "))
	}
	all := map[string][]Column{}
	rows, err = q.Query(ctx, storeColumnsSQL)
	if err != nil {
		return nil, fmt.Errorf("the repository's columns: %w", err)
	}
	for rows.Next() {
		var table string
		var c Column
		if err := rows.Scan(&table, &c.Name, &c.Type, &c.OID, &c.Mod, &c.NotNull); err != nil {
			rows.Close()
			return nil, fmt.Errorf("the repository's columns: %w", err)
		}
		all[table] = append(all[table], c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("the repository's columns: %w", err)
	}
	for i := range out {
		r := &out[i]
		left := map[string]string{}
		for _, d := range r.Drop {
			left[d.Column] = d.Reason
		}
		if !opt.carries(CarryText) {
			for _, c := range r.Text {
				left[c] = dropText
			}
		}
		timeSeen := r.Time == ""
		for _, c := range all[r.Name] {
			if c.Name == "instance_id" && c.NotNull {
				r.HasInstance = true // a nullable instance_id (a line of the service itself) is read without the join
			}
			if c.Name == r.Time {
				timeSeen = true
				if !strings.HasPrefix(c.Type, "timestamp") {
					return nil, fmt.Errorf("catalog: %s.%s is %s, not a time", r.Name, c.Name, c.Type)
				}
			}
			if why, gone := left[c.Name]; gone {
				r.Dropped = append(r.Dropped, Dropped{c.Name, why})
				continue
			}
			r.Columns = append(r.Columns, c)
		}
		switch {
		case r.Class == LeftOut:
			r.Skip = r.Why
		case !timeSeen:
			return nil, fmt.Errorf("catalog: %s has no column %s", r.Name, r.Time)
		case excluded[r.Name]:
			r.Skip = "left out by the configuration (export.tables.exclude)"
		case r.Carry != "" && !opt.carries(r.Carry):
			r.Skip = fmt.Sprintf("carried only with export.carry: [%s]", r.Carry)
		case r.Class != Window && opt.StateMaxBytes > 0 && r.Bytes > opt.StateMaxBytes:
			r.Skip = fmt.Sprintf("%d bytes, over export.snapshot_max_bytes (%d): a whole-table export of it is left out", r.Bytes, opt.StateMaxBytes)
		}
		if r.Skip != "" {
			r.Columns, r.Dropped = nil, nil
		}
	}
	return out, nil
}
