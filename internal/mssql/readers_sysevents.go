package mssql

import (
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The events system_health records beside sp_server_diagnostics' component results that sp_HealthParser reads
// (Darling Data, LLC; MIT) and PerformanceMonitor's System Events page shows (the same author; MIT): the memory
// broker's notifications, a memory node's out-of-memory record, the scheduler monitor's utilization samples and the
// long waits (wait_info). The system_health reader (syshealth.go) takes them in its one read of the session's file and
// stores each as a row of mssql_health_components under a component name of its own, state EVENT, its fields under
// sp_HealthParser's column names (detail). Which fields, and the filter of the waits, follow sp_HealthParser 3.11:
//
//	MEMORY_BROKER     memory_broker_ring_buffer_recorded: broker_id (the event's id), pool_metadata_id, delta_time,
//	                  memory_ratio, new_target, overall, rate, currently_predicated, currently_allocated,
//	                  previously_allocated, broker, notification
//	MEMORY_NODE_OOM   memory_node_oom_ring_buffer_recorded: node_id (the event's id), memory_node_id,
//	                  memory_utilization_pct, the memory sizes (KB), the pool's figures (KB), failure_type / failure_value,
//	                  resources, factor_text / factor_value, last_error, pool_metadata_id and the five flags
//	SCHEDULER_MONITOR scheduler_monitor_system_health_ring_buffer_recorded: process_utilization (SQL Server's CPU %),
//	                  system_idle, memory_utilization (the working set's share of committed memory), page_faults,
//	                  working_set_delta (bytes)
//	WAIT_INFO         wait_info: wait_type, opcode, duration_ms, signal_duration_ms, wait_resource, session_id, the
//	                  statement (under the instance's text policy), and whether the event carried a statement and
//	                  whether it was a BACKUP (sp_HealthParser leaves both out; read before the policy hides the text)
//
// Every value is read from the field's <value>, as sp_HealthParser's value() calls read it; the failure and the
// factor of a node OOM also keep their <text>.

// The components the events are stored under, and their state.
const (
	sysEventBroker    = "MEMORY_BROKER"
	sysEventNodeOOM   = "MEMORY_NODE_OOM"
	sysEventScheduler = "SCHEDULER_MONITOR"
	sysEventWait      = "WAIT_INFO"
	sysEventState     = "EVENT"
)

// sysEventNames maps each event to its component.
var sysEventNames = map[string]string{
	"memory_broker_ring_buffer_recorded":                   sysEventBroker,
	"memory_node_oom_ring_buffer_recorded":                 sysEventNodeOOM,
	"scheduler_monitor_system_health_ring_buffer_recorded": sysEventScheduler,
	"wait_info": sysEventWait,
}

// sysEventFields are the fields kept as numbers (else text) per component, in sp_HealthParser's names; the event's own
// field name where it differs is after the colon.
var sysEventFields = map[string][]string{
	sysEventBroker: {"broker_id:id", "pool_metadata_id", "delta_time", "memory_ratio", "new_target", "overall", "rate",
		"currently_predicated", "currently_allocated", "previously_allocated", "broker", "notification"},
	sysEventNodeOOM: {"node_id:id", "memory_node_id", "memory_utilization_pct", "total_physical_memory_kb",
		"available_physical_memory_kb", "total_page_file_kb", "available_page_file_kb", "total_virtual_address_space_kb",
		"available_virtual_address_space_kb", "target_kb", "reserved_kb", "committed_kb", "shared_committed_kb", "awe_kb",
		"pages_kb", "failure_value:failure", "resources", "factor_value:factor", "last_error", "pool_metadata_id",
		"is_process_in_job", "is_system_physical_memory_high", "is_system_physical_memory_low",
		"is_process_physical_memory_low", "is_process_virtual_memory_low"},
	sysEventScheduler: {"process_utilization", "system_idle", "memory_utilization", "page_faults", "working_set_delta"},
	sysEventWait:      {"duration_ms:duration", "signal_duration_ms:signal_duration", "wait_resource"},
}

// fieldValue is a data field's <value> as a number where it is one, else its text; nil where the event has no such
// field or it is empty.
func fieldValue(e *xeEvent, name string) any {
	f := e.field(e.Data, name)
	if f == nil {
		return nil
	}
	s := strings.ReplaceAll(strings.TrimSpace(f.Value.Text), "\x00", "")
	if s == "" {
		return nil
	}
	return componentNumber(s)
}

// parseSysEvent turns one of the four events into its row.
func parseSysEvent(e *xeEvent, c xeContext) collect.Row {
	t, ok := e.at()
	if !ok {
		return nil
	}
	component, ok := sysEventNames[e.Name]
	if !ok {
		return nil
	}
	detail := map[string]any{}
	for _, f := range sysEventFields[component] {
		key, field := f, f
		if i := strings.IndexByte(f, ':'); i >= 0 {
			key, field = f[:i], f[i+1:]
		}
		if v := fieldValue(e, field); v != nil {
			detail[key] = v
		}
	}
	switch component {
	case sysEventNodeOOM:
		// the failure and the factor are mapped values: their names beside their numbers
		for key, field := range map[string]string{"failure_type": "failure", "factor_text": "factor"} {
			if f := e.field(e.Data, field); f != nil && strings.TrimSpace(f.Text) != "" {
				detail[key] = strings.TrimSpace(f.Text)
			}
		}
	case sysEventWait:
		if wt, ok := e.mapped("wait_type").(string); ok && wt != "" {
			detail["wait_type"] = wt
		}
		if op, ok := e.mapped("opcode").(string); ok && op != "" {
			detail["opcode"] = op
		}
		if sid, ok := e.actNum("session_id").(int64); ok {
			detail["session_id"] = sid
		}
		stmt, _ := e.act("sql_text").(string)
		detail["has_sql_text"] = strings.TrimSpace(stmt) != ""
		detail["is_backup"] = strings.Contains(strings.ToUpper(stmt), "BACKUP")
		if s := policyText(stmt, c.queryText); s != nil {
			detail["statement"] = s
		}
	}
	return collect.Row{"kind": "component", "event_at": t.Format(time.RFC3339Nano), "component": component,
		"state": sysEventState, "detail": detail}
}

// dropLinuxIdle is cpu.go's rule for the scheduler monitor's samples on a Linux host: SQL Server on Linux writes
// system_idle as 0 in every sample, so 100 - SQL Server - idle would charge the whole idle machine to other processes
// (sp_HealthParser's 'other processes' warning on every sample). The idle figure is dropped and marked as not read;
// other processes' share is then unknown and only SQL Server's share and memory utilization count.
func dropLinuxIdle(rows []collect.Row) []collect.Row {
	for _, r := range rows {
		if r["component"] != sysEventScheduler {
			continue
		}
		if d, ok := r["detail"].(map[string]any); ok {
			if _, had := d["system_idle"]; had {
				delete(d, "system_idle")
				d["system_idle_not_read"] = true
			}
		}
	}
	return rows
}

// sysEventList is the reader's list of events: the component results first, then the four.
func sysEventList() []string {
	return []string{sysHealthEvent, "memory_broker_ring_buffer_recorded", "memory_node_oom_ring_buffer_recorded",
		"scheduler_monitor_system_health_ring_buffer_recorded", "wait_info"}
}

func init() {
	for name := range sysEventNames {
		xeParsers[name] = parseSysEvent
	}
}
