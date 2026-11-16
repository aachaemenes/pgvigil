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
	// Window covers the rows whose own time column is inside the hour. That column is the table's partition key, part of
	// its primary key, or the time of an append-only line - never a column an import rewrites at every read.
	Window Class = "window"
	// State covers the whole table, in the day's first window. What an import upserts or rebuilds at every read.
	State Class = "state"
	// Dimension covers text keyed by a hash: the rows seen in or after the window's start, and the whole table in the
	// day's first window.
	Dimension Class = "dimension"
	// LeftOut is never exported; Why says why.
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
	Time  string   // Window: the time column. Dimension: the column that says when a row was last seen.
	Carry string   // "", CarryText or CarryAudit: the whole table leaves only with that carry
	Text  []string // columns of statement, plan, definition or log text: dropped unless the carry holds text
	Audit []string // columns that say who did what, or hold grants: dropped unless the carry holds audit
	// AuditRows is a predicate over the table's own columns: the rows it names leave only with the audit carry
	AuditRows string
	Drop      []Dropped // columns that never leave
	Why       string    // LeftOut: the reason
}

// Dropped is a column left behind and why.
type Dropped struct{ Column, Reason string }

const (
	whyUI        = "the logins of the web UI: the reader role cannot read it"
	whyCursor    = "a read cursor of the collector"
	whyBaseline  = "the last cumulative counters a delta is computed from"
	whyMark      = "a queue, a mark or a cache of the service"
	whyInventory = "the service's own inventory: connection references, hosts and logins"
	whyGuard     = "a duplicate guard of an import: what it has already counted"
	whyOwnerOnly = "owner only: neither the reader nor the exporter role may read it"

	dropMail    = "a mail's subject, body or attachment"
	dropAddress = "an address a message is sent to"
	dropToken   = "a claim token"
	dropURL     = "an address that can carry credentials"
	dropSetting = "settings' old and new values, unmasked: a connection setting can carry a password"
	dropReply   = "a mail server's reply: it can quote the address it refused"
	dropText    = "statement, plan or log text: carried only with export.carry: [text]"
	dropAudit   = "who did what, or a grant: carried only with export.carry: [audit]"
	rowsAudit   = "carried only with export.carry: [audit]"
)

func window(name, time string) Table    { return Table{Name: name, Class: Window, Time: time} }
func dimension(name, seen string) Table { return Table{Name: name, Class: Dimension, Time: seen} }
func state(name string) Table           { return Table{Name: name, Class: State} }
func out(name, why string) Table        { return Table{Name: name, Class: LeftOut, Why: why} }

func (t Table) carry(c string) Table       { t.Carry = c; return t }
func (t Table) text(cols ...string) Table  { t.Text = cols; return t }
func (t Table) audit(cols ...string) Table { t.Audit = cols; return t }
func (t Table) auditRows(p string) Table   { t.AuditRows = p; return t }
func (t Table) drop(col, why string) Table { t.Drop = append(t.Drop, Dropped{col, why}); return t }

// tables is the map, in name order. A table of the schema it does not name stops every run (Resolve): a new
// migration's table is classed here from a read of how it is written.
var tables = []Table{
	window("ack_log", "at").carry(CarryAudit),
	state("ack_suppressed"),
	state("acks").audit("created_by", "client", "ended_by", "paused_by"),
	state("acl_databases").carry(CarryAudit),
	state("acl_default_privileges").carry(CarryAudit),
	state("acl_schemas").carry(CarryAudit),
	state("action_doors"),
	state("action_kinds"),
	window("action_requests", "asked_at").carry(CarryAudit).text("outcome"),
	window("actions_log", "at").carry(CarryAudit).text("statement", "server_message"),
	window("activity_sample", "snapshot_at").audit("usename", "client"),
	window("activity_summary", "snapshot_at"),
	window("admin_audit", "at").carry(CarryAudit),
	out("admin_file_tests", whyInventory),
	out("admin_instance_cloud", whyInventory),
	out("admin_instances", whyInventory),
	out("admin_inventory_state", whyMark),
	out("admin_page_holder", whyMark),
	out("admin_proposals", whyInventory),
	out("admin_removed", whyInventory),
	out("admin_sources", whyInventory),
	state("alert_anchor_checks"),
	out("alert_channel_quota", whyMark),
	state("alert_channels").drop("destination", dropAddress),
	state("alert_dismissals").audit("created_by", "client", "ended_by"),
	state("alert_held").text("detail"),
	window("alert_log", "snapshot_at").drop("destination", dropAddress).drop("error", dropReply),
	state("alert_rule_baseline"),
	state("alert_rule_fired"),
	window("alert_rule_log", "at").carry(CarryAudit),
	state("alert_rule_state"),
	state("alert_rules").audit("created_by", "client", "ended_by"),
	state("alert_state"),
	out("alert_tests", whyMark),
	out("alert_threads", whyMark),
	window("alert_window_log", "at").carry(CarryAudit),
	state("alert_windows").audit("created_by", "client", "ended_by"),
	window("amcheck_runs", "snapshot_at"),
	state("app_applications").audit("created_by"),
	state("app_assignments").audit("set_by"),
	state("app_field_source").audit("set_by"),
	state("app_not_application").audit("set_by"),
	window("backup_sample", "snapshot_at"),
	state("backup_state"),
	window("buffercache_sample", "snapshot_at"),
	window("cloud_failover_events", "first_read_at"),
	window("cloud_io_sample", "snapshot_at"),
	window("cloud_replica_events", "at"),
	window("cloud_replica_hour", "snapshot_at"),
	out("cloud_replica_hour_dirty", whyMark),
	state("cloud_replica_reads").text("door_error"),
	window("cloud_replica_sample", "snapshot_at"),
	state("cloud_replicas").text("repl_note"),
	state("collection_dates").text("note"),
	window("collection_health_hour", "hour"),
	state("collection_health_threshold").audit("created_by", "client", "ended_by"),
	window("collection_log", "snapshot_at").text("note"),
	state("collection_run_status"),
	out("collection_runs_long_since", whyMark),
	window("collector_beats", "at"),
	state("collector_heartbeat"),
	state("collector_instances"),
	window("collector_load", "minute"),
	window("collector_probe", "minute"),
	state("collector_probe_host"),
	window("collector_runs", "minute"),
	state("collector_spells"),
	state("collector_streaks").text("last_error"),
	out("collector_trim_mark", whyMark),
	out("compare_findings_cache", whyMark),
	state("compare_state"),
	window("conn_sources", "snapshot_at").audit("usename", "client"),
	state("cq_tools"),
	state("cq_workers"),
	state("custom_checks").text("sql"),
	state("custom_report_folders").audit("created_by"),
	window("custom_report_log", "at").carry(CarryAudit).text("statement", "payload"),
	state("custom_reports").text("body").audit("created_by", "updated_by", "deleted_by"),
	window("custom_results", "snapshot_at").text("columns", "rows"),
	state("custom_status_rows").text("info"),
	state("darling_benign_waits"),
	state("database_collations"),
	state("database_extensions"),
	window("database_sizes", "snapshot_at"),
	state("databases").audit("owner"),
	state("db_checks").text("fix_sql"),
	state("dbadash_instances"),
	out("dbadash_move_ids", whyInventory),
	out("dbadash_moves", whyInventory),
	state("dbadash_repositories"),
	state("dbadash_summary"),
	window("dbadash_summary_history", "snapshot_at"),
	window("dbstats", "snapshot_at"),
	out("dbstats_last", whyBaseline),
	state("depth_databases"),
	window("digest_log", "at").drop("error", dropReply),
	state("dms_instances"),
	window("dms_ri_sample", "snapshot_at"),
	state("dms_table_stats"),
	window("dms_task_sample", "snapshot_at"),
	state("dms_tasks"),
	state("drive_thresholds").audit("created_by", "client", "ended_by"),
	window("export_runs", "started_at").audit("login"),
	out("export_state", whyMark),
	window("extension_history", "changed_at"),
	window("findings_history", "snapshot_at"),
	state("findings_history_last"),
	window("function_stats", "snapshot_at"),
	state("hba_rules").carry(CarryAudit),
	window("host_disk_history", "snapshot_at"),
	state("host_disks"),
	window("host_io", "snapshot_at"),
	window("host_sample", "snapshot_at"),
	state("host_state"),
	state("hours_retention"),
	state("index_bloat").text("reindex_sql"),
	state("index_databases"),
	state("index_inventory").text("columns", "index_def"),
	state("index_state").text("covered_by_def", "index_def", "drop_sql", "undo_sql"),
	window("index_usage_daily", "snapshot_at"),
	state("instance_events"),
	state("instance_extension_settings"),
	state("instance_extensions"),
	window("instance_setting_history", "changed_at"),
	state("instance_state").audit("connected_user"),
	state("instance_tag_overrides").audit("set_by"),
	state("instance_versions"),
	state("instances"),
	window("investigation_journal", "at").carry(CarryAudit),
	state("investigations").carry(CarryAudit).drop("claim_hash", dropToken),
	window("iostats", "snapshot_at"),
	state("job_exclusions").audit("created_by", "client", "ended_by"),
	window("job_runs", "start_time").text("command", "return_message"),
	out("job_stats_defer", whyMark),
	out("job_stats_dirty", whyMark),
	out("job_stats_first_build", whyMark),
	window("job_stats_hourly", "snapshot_at"),
	window("job_step_runs", "start_time").text("output"),
	state("job_thresholds").audit("created_by", "client", "ended_by"),
	state("job_versions").text("definition", "changes", "script"),
	state("jobs").text("command"),
	out("log_cursor", whyCursor),
	window("log_events", "snapshot_at").text("statement", "detail", "message").auditRows("kind = 'auth_fail'").audit("client", "usename"),
	window("mssql_activity_read", "snapshot_at"),
	state("mssql_ag_database_cluster"),
	state("mssql_ag_database_state"),
	window("mssql_ag_dbcounter_sample", "snapshot_at"),
	window("mssql_ag_events", "event_at").text("statement", "message"),
	window("mssql_ag_failovers", "at"),
	window("mssql_ag_replica_sample", "snapshot_at"),
	window("mssql_ag_sample", "snapshot_at"),
	state("mssql_ag_seeding"),
	state("mssql_ag_state"),
	state("mssql_agent_alert"),
	state("mssql_agent_alerting"),
	state("mssql_agent_operator"),
	window("mssql_attention_reads", "snapshot_at"),
	window("mssql_attentions", "event_at").text("statement").audit("login_name", "host_name"),
	state("mssql_audit"),
	window("mssql_audit_counts", "hour_at").carry(CarryAudit),
	window("mssql_audit_events", "event_at").carry(CarryAudit).text("statement"),
	state("mssql_audit_read"),
	state("mssql_audit_spec"),
	window("mssql_azuredb_gap", "noted_at"),
	state("mssql_azuredb_governance"),
	state("mssql_azuredb_governance_history"),
	window("mssql_azuredb_hour", "snapshot_at"),
	out("mssql_azuredb_hour_dirty", whyMark),
	out("mssql_azuredb_hour_first_build", whyMark),
	window("mssql_azuredb_minute", "snapshot_at"),
	state("mssql_azuredb_read"),
	state("mssql_backup_db_checks"),
	state("mssql_backup_dbfiles"),
	state("mssql_backup_file_checks"),
	state("mssql_backup_files"),
	out("mssql_backup_files_cursor", whyCursor),
	state("mssql_backup_history").audit("user_name"),
	out("mssql_backup_history_cursor", whyCursor),
	state("mssql_backup_history_dbs"),
	state("mssql_backup_path_check"),
	state("mssql_backup_roots_seen"),
	state("mssql_backup_sets").audit("user_name"),
	state("mssql_backup_state"),
	state("mssql_backup_writers").audit("users"),
	window("mssql_block_hourly", "hour"),
	window("mssql_blocked_reports", "event_at").text("blocked_statement", "blocking_statement", "report").audit("blocked_login", "blocked_host", "blocking_login", "blocking_host"),
	window("mssql_blocking", "snapshot_at").audit("head_login", "head_host"),
	state("mssql_build"),
	state("mssql_check_area"),
	state("mssql_check_finding"),
	state("mssql_clerk_names"),
	state("mssql_confcheck_fact"),
	state("mssql_confcheck_part").text("note"),
	state("mssql_config"),
	state("mssql_config_expect").audit("created_by", "client", "ended_by", "value"),
	state("mssql_config_history"),
	state("mssql_constraint_db").text("note"),
	state("mssql_counter_catalog"),
	state("mssql_counter_config").audit("created_by", "client", "ended_by"),
	window("mssql_counter_config_log", "at").carry(CarryAudit),
	state("mssql_counter_defaults"),
	out("mssql_counter_last", whyBaseline),
	window("mssql_counter_read", "snapshot_at"),
	window("mssql_counter_sample", "snapshot_at"),
	state("mssql_counter_series"),
	state("mssql_counter_yaml"),
	state("mssql_cpu_info"),
	window("mssql_cpu_sample", "snapshot_at"),
	out("mssql_cursor", whyCursor),
	state("mssql_database_option"),
	window("mssql_database_size", "snapshot_at"),
	window("mssql_database_space", "snapshot_at"),
	state("mssql_db_confcheck").text("scoped_note"),
	window("mssql_deadlocks", "event_at").text("victim_statement", "processes", "resources", "graph").audit("victim_login"),
	window("mssql_errorlog", "log_at").text("message"),
	window("mssql_failed_logins", "logged_at").carry(CarryAudit).text("message"),
	state("mssql_failover_group_events"),
	state("mssql_failover_group_reads"),
	state("mssql_failover_groups"),
	state("mssql_fci_nodes"),
	window("mssql_fci_owner_changes", "at"),
	out("mssql_fileio_last", whyBaseline),
	window("mssql_fileio_read", "snapshot_at"),
	window("mssql_fileio_sample", "snapshot_at"),
	state("mssql_files"),
	state("mssql_fixed_drives"),
	state("mssql_fk_columns"),
	state("mssql_fragmentation_read").text("note").audit("ui_user", "client"),
	state("mssql_fragmentation_row"),
	window("mssql_georepl_events", "at"),
	window("mssql_georepl_hour", "snapshot_at"),
	out("mssql_georepl_hour_dirty", whyMark),
	state("mssql_georepl_read"),
	window("mssql_georepl_sample", "snapshot_at"),
	state("mssql_georepl_state"),
	state("mssql_hadr_reads"),
	state("mssql_hadr_thresholds"),
	state("mssql_health"),
	window("mssql_health_components", "event_at"),
	state("mssql_heap"),
	state("mssql_identity_column"),
	state("mssql_identity_scan"),
	state("mssql_index").text("filter_definition"),
	state("mssql_index_db"),
	state("mssql_index_parts").text("note"),
	window("mssql_index_usage_read", "snapshot_at"),
	out("mssql_indexlock_last", whyBaseline),
	window("mssql_indexlock_read", "snapshot_at"),
	window("mssql_indexlock_sample", "snapshot_at"),
	state("mssql_indexlock_state"),
	state("mssql_instance"),
	window("mssql_job_runs", "snapshot_at").text("message", "failed_message"),
	state("mssql_jobs").text("last_message").audit("owner"),
	out("mssql_jobs_cursor", whyCursor),
	state("mssql_kit_versions"),
	state("mssql_linked_server").audit("logins").drop("data_source", dropURL),
	state("mssql_linked_server_test").text("error_message", "note"),
	window("mssql_live_plan", "captured_at").text("live_xml"),
	state("mssql_live_read"),
	window("mssql_logrestore_sample", "snapshot_at"),
	state("mssql_logrestore_state"),
	state("mssql_logship_config"),
	state("mssql_logship_errors").text("message"),
	state("mssql_logship_foreign_logs"),
	state("mssql_logship_idle"),
	state("mssql_logshipping_state"),
	state("mssql_maint_database").text("note", "purity_note"),
	state("mssql_maint_last"),
	state("mssql_maint_part").text("note"),
	window("mssql_memory_cache", "snapshot_at"),
	window("mssql_memory_clerk", "snapshot_at"),
	window("mssql_memory_grant_query", "snapshot_at").text("statement"),
	state("mssql_memory_numa"),
	window("mssql_memory_pool", "snapshot_at"),
	state("mssql_memory_reads"),
	window("mssql_memory_rmon", "snapshot_at"),
	window("mssql_memory_sample", "snapshot_at"),
	window("mssql_mirroring_role_changes", "at"),
	window("mssql_mirroring_sample", "snapshot_at"),
	state("mssql_mirroring_state"),
	state("mssql_missing_index"),
	window("mssql_missing_index_read", "snapshot_at"),
	state("mssql_monitor_app"),
	state("mssql_ola_commandlog").text("command", "error_message"),
	state("mssql_orphan_files"),
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
	state("mssql_plan_stat"),
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
	window("mssql_protection_override_log", "at").carry(CarryAudit),
	state("mssql_protection_overrides").audit("created_by", "client", "ended_by"),
	state("mssql_pvs"),
	window("mssql_qs_force_fail", "seen_at"),
	window("mssql_qs_interval", "snapshot_at"),
	dimension("mssql_qs_plan", "snapshot_at").text("plan_xml"),
	dimension("mssql_qs_query", "snapshot_at").text("query_text"),
	window("mssql_qs_runtime", "snapshot_at"),
	state("mssql_qs_store"),
	state("mssql_qs_tuning").text("script", "rec_details"),
	state("mssql_qs_tuning_option"),
	state("mssql_reader_state"),
	window("mssql_repl_hourly", "hour"),
	window("mssql_repl_sample", "snapshot_at"),
	state("mssql_replication_state").text("status_text", "error_text"),
	window("mssql_requests", "snapshot_at").audit("login_name", "host_name"),
	window("mssql_requests_summary", "snapshot_at"),
	state("mssql_restore_files"),
	state("mssql_restore_history").audit("user_name"),
	state("mssql_restore_reads"),
	state("mssql_restore_sets").audit("user_name"),
	state("mssql_restore_steps").audit("user_name"),
	state("mssql_restore_verdicts"),
	state("mssql_rg_group"),
	state("mssql_rg_pool"),
	state("mssql_running_plan").text("plan_xml", "plan_note"),
	window("mssql_sched_sample", "snapshot_at"),
	state("mssql_schema_dbs").text("note"),
	state("mssql_schema_trace_gaps").text("note"),
	state("mssql_security_auth").audit("client_address"),
	state("mssql_security_auth_counts"),
	state("mssql_security_config").audit("created_by", "client", "ended_by", "value"),
	window("mssql_security_config_log", "at").carry(CarryAudit),
	state("mssql_security_context").carry(CarryAudit),
	state("mssql_security_db"),
	state("mssql_security_db_objects").carry(CarryAudit),
	state("mssql_security_logins").carry(CarryAudit),
	state("mssql_security_proxies").carry(CarryAudit),
	state("mssql_security_read").text("note"),
	state("mssql_security_registry"),
	state("mssql_security_rule_defs"),
	state("mssql_security_server_perms").carry(CarryAudit),
	state("mssql_security_setting_keys"),
	state("mssql_server_option"),
	state("mssql_server_role_members").carry(CarryAudit),
	state("mssql_service").audit("service_account"),
	state("mssql_service_ext"),
	window("mssql_session_by", "snapshot_at").auditRows("dimension IN ('login', 'address')"),
	window("mssql_session_count", "snapshot_at"),
	window("mssql_session_group", "snapshot_at"),
	window("mssql_session_summary", "snapshot_at"),
	window("mssql_session_tempdb", "snapshot_at").audit("login_name", "host_name"),
	window("mssql_slow_events", "event_at").text("statement", "shape").audit("login_name", "host_name"),
	state("mssql_sql_logins").carry(CarryAudit),
	state("mssql_stat").text("filter_definition"),
	dimension("mssql_statement_text", "last_seen").carry(CarryText),
	state("mssql_stats_db"),
	state("mssql_storage_paths").text("drives_note", "orphans_note"),
	state("mssql_suspect_page"),
	window("mssql_table_sample", "snapshot_at"),
	state("mssql_table_shape"),
	window("mssql_table_size", "snapshot_at"),
	state("mssql_tables"),
	state("mssql_tables_db_read").text("note"),
	state("mssql_tempdb"),
	state("mssql_tempdb_files"),
	window("mssql_trace_events", "event_at").text("statement").audit("login_name", "host_name"),
	window("mssql_trace_flag_history", "changed_at"),
	state("mssql_trace_flags"),
	state("mssql_trace_flags_read"),
	state("mssql_untrusted_constraint"),
	state("mssql_versionstore_db"),
	window("mssql_versionstore_sample", "snapshot_at").text("holder_statement").audit("holder_login", "holder_host"),
	state("mssql_volume_key"),
	window("mssql_volume_sample", "snapshot_at"),
	state("mssql_volumes"),
	out("mssql_wait_last", whyBaseline),
	window("mssql_wait_sample", "snapshot_at"),
	state("mssql_wait_state"),
	window("mssql_waiting_summary", "snapshot_at"),
	window("mssql_waiting_tasks", "snapshot_at").text("statement"),
	state("mssql_xe_capture_config").audit("created_by", "client", "ended_by"),
	window("mssql_xe_capture_config_log", "at").carry(CarryAudit),
	state("mssql_xe_capture_keys"),
	state("mssql_xe_capture_state").text("note"),
	state("mssql_xe_foreign"),
	state("mssql_xe_foreign_read"),
	window("mssql_xe_modules", "event_at").audit("login_name", "host_name"),
	state("mssql_xe_session_state"),
	state("mssql_xe_state"),
	window("mssql_xe_waits", "event_at").text("statement").audit("login_name", "host_name"),
	window("mssql_xe_warning_counts", "snapshot_at"),
	window("mssql_xe_warning_hours", "hour_at"),
	out("mssql_xe_warning_keys", whyGuard),
	window("mssql_xe_warning_samples", "hour_at").text("detail", "statement").audit("login_name", "host_name"),
	state("pg_backup_dest"),
	state("pg_backup_dest_entered").audit("entered_by", "ended_by"),
	state("pg_backup_dest_reads").text("message"),
	state("pg_backup_dest_settings"),
	state("pg_backup_detect"),
	state("pg_backup_tools"),
	state("pg_base_backups"),
	state("pg_db_role_settings").audit("rolname"),
	state("pg_db_role_settings_read"),
	state("pg_logical_pubs"),
	state("pg_logical_rels"),
	state("pg_logical_subs"),
	state("pg_patroni_members").drop("api_url", dropURL).drop("api_message", dropURL).drop("pending_restart_reason", dropSetting),
	state("pg_patroni_read").drop("url", dropURL),
	state("pg_repl_link_seen").audit("client_addr"),
	state("pg_repl_slot_state"),
	state("pg_repl_standby_state"),
	window("pg_role_changes", "changed_at"),
	state("pg_role_passwords").carry(CarryAudit),
	state("pg_role_state"),
	state("pg_threshold_keys"),
	state("pg_thresholds").audit("created_by", "client", "ended_by"),
	state("pg_wal_replay"),
	out("pgaudit_count_secs", whyGuard),
	window("pgaudit_counts", "snapshot_at").carry(CarryAudit),
	window("pgaudit_events", "snapshot_at").carry(CarryAudit).text("statement", "parameters"),
	state("pgaudit_rules"),
	state("pgaudit_settings").carry(CarryAudit),
	state("pgaudit_state").audit("forged_by"),
	window("pi_load", "snapshot_at"),
	dimension("pi_sql", "last_seen").carry(CarryText),
	state("pi_state"),
	dimension("plans", "captured_at").carry(CarryText),
	window("pooler_conn_sample", "snapshot_at").audit("addr"),
	window("pooler_sample", "snapshot_at"),
	state("pooler_state"),
	window("purge_runs", "started_at"),
	dimension("query_text", "last_seen").carry(CarryText),
	window("replication_hourly", "snapshot_at"),
	out("replication_hourly_dirty", whyMark),
	out("replication_hourly_first_build", whyMark),
	window("replication_sample", "snapshot_at"),
	state("report_db_properties"),
	window("report_mail_log", "at").carry(CarryAudit).drop("payload", dropAddress),
	state("report_mail_schedules").audit("created_by", "client", "changed_by", "ended_by").drop("claim_token", dropToken).drop("recipients", dropAddress),
	window("report_mail_sends", "requested_at").audit("requested_by", "client").drop("html", dropMail).drop("xlsx", dropMail).drop("recipients", dropAddress).drop("subject", dropMail).drop("error", dropReply),
	state("report_read_state"),
	state("role_attributes").carry(CarryAudit),
	state("role_databases"),
	window("role_history", "changed_at").carry(CarryAudit),
	state("role_member_closure").carry(CarryAudit),
	state("role_members").carry(CarryAudit),
	state("role_state").audit("login_name"),
	window("schema_changes", "snapshot_at").text("before", "after"),
	state("schema_databases"),
	window("schema_ddl_log", "snapshot_at").text("statement").audit("role_name"),
	state("schema_objects").text("definition").audit("owner", "acl"),
	state("schema_version"),
	state("sequence_state"),
	window("serverless_sample", "snapshot_at"),
	state("serverless_scaling"),
	window("serverstats", "snapshot_at"),
	dimension("session_sets", "last_seen").text("value", "query").audit("rolname"),
	window("session_sets_sample", "snapshot_at"),
	state("session_sets_state"),
	window("slru_sample", "snapshot_at"),
	dimension("statement_text", "last_seen").carry(CarryText),
	out("statements_current", whyBaseline),
	window("statements_delta", "snapshot_at").audit("usename"),
	window("statements_info", "snapshot_at"),
	out("statements_monitor_seen", whyBaseline),
	out("statements_monitor_total", whyBaseline),
	window("storage_sample", "snapshot_at"),
	state("storage_state"),
	window("table_activity", "snapshot_at"),
	state("table_databases"),
	window("table_sizes", "snapshot_at"),
	state("tables"),
	window("temp_sample", "snapshot_at").audit("usename"),
	out("ui_action_data", whyOwnerOnly),
	out("ui_app_contact_routes", whyUI),
	out("ui_app_contacts", whyUI),
	out("ui_investigation_data", whyOwnerOnly),
	out("ui_investigation_journal_text", whyOwnerOnly),
	out("ui_users", whyUI),
	out("ui_view_log", whyOwnerOnly),
	out("ui_views", whyOwnerOnly),
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
	Key          []string  // the primary key
	Columns      []Column  // the columns exported, in the table's own order
	Dropped      []Dropped // the columns left behind under this configuration
	HasInstance  bool      // it has a NOT NULL instance_id: read one instance at a time
	TimeNullable bool      // a window table whose time column may be NULL: such rows are read in the day's first window
	NoWhole      bool      // a dimension over the size line: its whole copy in the day's first window is left out
	Filter       string    // a predicate naming the rows left behind under this configuration ("" = none)
	Note         string    // said in the manifest's entry
	Bytes        int64     // its size on disk with its indexes (a partitioned table: its partitions')
	Skip         string    // why it is not exported under this configuration ("" = exported)
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

// storeTable is a table as the repository's catalogs give it.
type storeTable struct {
	Name  string
	Key   []string
	Bytes int64
}

// Resolve reads the repository's tables (a partition is never a table of its own) and lays the map over them.
func Resolve(ctx context.Context, q Querier, opt Options) ([]Resolved, error) {
	var store []storeTable
	rows, err := q.Query(ctx, storeTablesSQL)
	if err != nil {
		return nil, fmt.Errorf("the repository's tables: %w", err)
	}
	for rows.Next() {
		var t storeTable
		if err := rows.Scan(&t.Name, &t.Key, &t.Bytes); err != nil {
			rows.Close()
			return nil, fmt.Errorf("the repository's tables: %w", err)
		}
		store = append(store, t)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("the repository's tables: %w", err)
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
	return lay(tables, store, all, opt)
}

// lay puts the map over the repository's tables. It stops, before anything is read, on a table of the schema the
// map does not name (its class cannot be guessed), on a column the map names that the table does not have (a
// rename would otherwise let it leave), and on a name in export.tables.exclude that is no table (a mistyped name
// would otherwise let the table leave). A table of the map this repository does not have yet (an older schema) is
// left out of the result.
func lay(m []Table, store []storeTable, all map[string][]Column, opt Options) ([]Resolved, error) {
	byName := make(map[string]Table, len(m))
	for _, t := range m {
		byName[t.Name] = t
	}
	var out []Resolved
	var unclassed []string
	have := map[string]bool{}
	for _, st := range store {
		t, ok := byName[st.Name]
		if !ok {
			unclassed = append(unclassed, st.Name)
			continue
		}
		have[st.Name] = true
		out = append(out, Resolved{Table: t, Key: st.Key, Bytes: st.Bytes})
	}
	if len(unclassed) > 0 {
		sort.Strings(unclassed)
		return nil, fmt.Errorf("table %s is not classed: class it in internal/export/catalog.go from how its import writes it (nothing was read or written)", strings.Join(unclassed, ", "))
	}
	excluded := map[string]bool{}
	for _, x := range opt.Exclude {
		switch x = strings.TrimSpace(x); {
		case x == "":
		case x == "instances":
			return nil, refused("export.tables.exclude names instances: it gives every instance_id its name and is in every window (nothing was read or written)")
		case !have[x]:
			return nil, refused("export.tables.exclude names %s, which is no table of the repository: a mistyped name would let the table leave (nothing was read or written)", x)
		default:
			excluded[x] = true
		}
	}
	for i := range out {
		r := &out[i]
		cols := map[string]Column{}
		for _, c := range all[r.Name] {
			cols[c.Name] = c
		}
		named := append(append([]string{}, r.Text...), r.Audit...)
		for _, d := range r.Drop {
			named = append(named, d.Column)
		}
		if r.Time != "" {
			named = append(named, r.Time)
		}
		for _, c := range named {
			if _, ok := cols[c]; !ok {
				return nil, fmt.Errorf("catalog: %s has no column %s, which the map names: read the table again in internal/export/catalog.go (nothing was read or written)", r.Name, c)
			}
		}
		if r.Time != "" {
			tc := cols[r.Time]
			if !strings.HasPrefix(tc.Type, "timestamp") {
				return nil, fmt.Errorf("catalog: %s.%s is %s, not a time", r.Name, tc.Name, tc.Type)
			}
			r.TimeNullable = r.Class == Window && !tc.NotNull
		}
		r.HasInstance = cols["instance_id"].NotNull // a nullable instance_id (a line of the service itself) is read without the join
		left := map[string]string{}
		if !opt.carries(CarryText) {
			for _, c := range r.Text {
				left[c] = dropText
			}
		}
		if !opt.carries(CarryAudit) {
			for _, c := range r.Audit {
				left[c] = dropAudit
			}
			r.Filter = r.AuditRows
		}
		for _, d := range r.Drop {
			left[d.Column] = d.Reason
		}
		for _, c := range all[r.Name] {
			if why, gone := left[c.Name]; gone {
				r.Dropped = append(r.Dropped, Dropped{c.Name, why})
				continue
			}
			r.Columns = append(r.Columns, c)
		}
		over := opt.StateMaxBytes > 0 && r.Bytes > opt.StateMaxBytes
		switch {
		case r.Class == LeftOut:
			r.Skip = r.Why
		case excluded[r.Name]:
			r.Skip = "left out by the configuration (export.tables.exclude)"
		case r.Carry != "" && !opt.carries(r.Carry):
			r.Skip = fmt.Sprintf("carried only with export.carry: [%s]", r.Carry)
		case r.Class == State && r.Name != "instances" && over: // instances names every id: always carried
			r.Skip = fmt.Sprintf("%d bytes on disk with its indexes, over export.snapshot_max_bytes (%d): a whole-table export of it is left out", r.Bytes, opt.StateMaxBytes)
		case r.Class == Dimension && over:
			r.NoWhole = true
			r.Note = fmt.Sprintf("%d bytes on disk with its indexes, over export.snapshot_max_bytes (%d): its whole copy in the day's first window is left out; the rows seen since a window's start are carried", r.Bytes, opt.StateMaxBytes)
		}
		if r.Skip != "" {
			r.Columns, r.Dropped, r.Filter = nil, nil, ""
		}
	}
	return out, nil
}
