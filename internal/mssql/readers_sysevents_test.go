package mssql

import (
	"slices"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func sysEvent(t *testing.T, doc string, policy string) collect.Row {
	t.Helper()
	e, err := parseEvent(doc)
	if err != nil {
		t.Fatal(err)
	}
	row := parseSysEvent(&e, xeContext{queryText: policy})
	if row == nil {
		t.Fatal("no row")
	}
	return row
}

const fixtureBroker = `<event name="memory_broker_ring_buffer_recorded" package="sqlos" timestamp="2026-11-12T01:02:03.456Z">
<data name="id"><value>3</value></data><data name="timestamp"><value>123456</value></data>
<data name="pool_metadata_id"><value>2</value></data><data name="delta_time"><value>60012</value></data>
<data name="memory_ratio"><value>100</value></data><data name="new_target"><value>2611</value></data>
<data name="overall"><value>98304</value></data><data name="rate"><value>0</value></data>
<data name="currently_predicated"><value>2611</value></data><data name="currently_allocated"><value>2611</value></data>
<data name="previously_allocated"><value>2584</value></data>
<data name="broker"><value>MEMORYBROKER_FOR_CACHE</value></data><data name="notification"><value>GROW</value></data></event>`

const fixtureNodeOOM = `<event name="memory_node_oom_ring_buffer_recorded" package="sqlos" timestamp="2026-11-12T01:05:00.000Z">
<data name="id"><value>0</value></data><data name="memory_node_id"><value>0</value></data>
<data name="memory_utilization_pct"><value>97</value></data><data name="total_physical_memory_kb"><value>16777216</value></data>
<data name="available_physical_memory_kb"><value>102400</value></data><data name="target_kb"><value>131072</value></data>
<data name="committed_kb"><value>131000</value></data><data name="shared_committed_kb"><value>0</value></data>
<data name="failure"><value>2</value><text>FAIL_PAGE_ALLOCATION</text></data><data name="resources"><value>1</value></data>
<data name="factor"><value>11</value><text>MEMORY_NODE_OOM_FACTOR_PAGE_ALLOCATION</text></data><data name="last_error"><value>0</value></data>
<data name="is_process_in_job"><value>false</value></data><data name="is_process_virtual_memory_low"><value>true</value></data></event>`

const fixtureScheduler = `<event name="scheduler_monitor_system_health_ring_buffer_recorded" package="sqlos" timestamp="2026-11-12T01:06:00.000Z">
<data name="id"><value>1</value></data><data name="process_utilization"><value>12</value></data>
<data name="system_idle"><value>30</value></data><data name="user_mode_time"><value>1000</value></data>
<data name="memory_utilization"><value>45</value></data><data name="page_faults"><value>2048</value></data>
<data name="working_set_delta"><value>-1048576</value></data></event>`

const fixtureWait = `<event name="wait_info" package="sqlos" timestamp="2026-11-12T01:07:00.000Z">
<data name="wait_type"><value>4</value><text>LCK_M_X</text></data><data name="opcode"><value>1</value><text>End</text></data>
<data name="duration"><value>35012</value></data><data name="signal_duration"><value>3</value></data>
<data name="wait_resource"><value>0x000001F2A3B4C5D6</value></data>
<action name="session_id" package="sqlserver"><value>57</value></action>
<action name="sql_text" package="sqlserver"><value>UPDATE dbo.t SET c = 1 WHERE id = 1;</value></action></event>`

// Each event's fields under sp_HealthParser's names, read from <value>; a node OOM's failure and factor also by name.
func TestSysEvents(t *testing.T) {
	b := sysEvent(t, fixtureBroker, "full")
	bd := b["detail"].(map[string]any)
	if b["component"] != "MEMORY_BROKER" || b["state"] != "EVENT" || b["event_at"] != "2026-11-12T01:02:03.456Z" {
		t.Errorf("broker row %v", b)
	}
	if bd["broker_id"] != int64(3) || bd["broker"] != "MEMORYBROKER_FOR_CACHE" || bd["notification"] != "GROW" || bd["previously_allocated"] != int64(2584) {
		t.Errorf("broker detail %v", bd)
	}
	if _, has := bd["timestamp"]; has {
		t.Errorf("the broker detail keeps a field sp_HealthParser does not read")
	}
	o := sysEvent(t, fixtureNodeOOM, "full")["detail"].(map[string]any)
	if o["failure_type"] != "FAIL_PAGE_ALLOCATION" || o["failure_value"] != int64(2) || o["factor_value"] != int64(11) ||
		o["memory_utilization_pct"] != int64(97) || o["is_process_virtual_memory_low"] != "true" || o["node_id"] != int64(0) {
		t.Errorf("node oom detail %v", o)
	}
	if _, has := o["awe_kb"]; has {
		t.Errorf("a field the event did not carry is stored")
	}
	s := sysEvent(t, fixtureScheduler, "full")["detail"].(map[string]any)
	if s["process_utilization"] != int64(12) || s["system_idle"] != int64(30) || s["memory_utilization"] != int64(45) || s["working_set_delta"] != int64(-1048576) {
		t.Errorf("scheduler detail %v", s)
	}
	w := sysEvent(t, fixtureWait, "full")["detail"].(map[string]any)
	if w["wait_type"] != "LCK_M_X" || w["opcode"] != "End" || w["duration_ms"] != int64(35012) || w["signal_duration_ms"] != int64(3) ||
		w["session_id"] != int64(57) || w["wait_resource"] != "0x000001F2A3B4C5D6" || w["has_sql_text"] != true || w["is_backup"] != false ||
		w["statement"] != "UPDATE dbo.t SET c = 1 WHERE id = 1;" {
		t.Errorf("wait detail %v", w)
	}
}

// Under the text policy 'none' the statement is not kept, but the two facts sp_HealthParser filters on are.
func TestSysEventWaitTextPolicy(t *testing.T) {
	w := sysEvent(t, fixtureWait, "none")["detail"].(map[string]any)
	if _, has := w["statement"]; has {
		t.Errorf("the statement is kept under the policy none: %v", w["statement"])
	}
	if w["has_sql_text"] != true {
		t.Errorf("has_sql_text lost under the policy none")
	}
	bk := sysEvent(t, `<event name="wait_info" timestamp="2026-11-12T01:08:00Z"><data name="duration"><value>900</value></data>
<action name="sql_text"><value>backup database x to disk = 'nul'</value></action></event>`, "full")["detail"].(map[string]any)
	if bk["is_backup"] != true {
		t.Errorf("a BACKUP statement is not marked: %v", bk)
	}
}

// The reader's one read asks for the component results and the four events; each event has its parser.
func TestSysEventList(t *testing.T) {
	l := sysEventList()
	if l[0] != sysHealthEvent || len(l) != 5 {
		t.Fatalf("event list %v", l)
	}
	for name := range sysEventNames {
		if !slices.Contains(l, name) {
			t.Errorf("%s is not read", name)
		}
		if _, ok := xeParsers[name]; !ok {
			t.Errorf("no parser for %s", name)
		}
	}
}

// On a Linux host the scheduler monitor's idle figure (always 0 there) is dropped and marked; other components and
// the other figures stay as read.
func TestDropLinuxIdle(t *testing.T) {
	sch := sysEvent(t, fixtureScheduler, "full")
	wait := sysEvent(t, fixtureWait, "full")
	wait["detail"].(map[string]any)["system_idle"] = int64(7) // a field of that name on another component is left alone
	dropLinuxIdle([]collect.Row{sch, wait})
	d := sch["detail"].(map[string]any)
	if _, has := d["system_idle"]; has || d["system_idle_not_read"] != true {
		t.Errorf("the idle figure on a Linux host: %v", d)
	}
	if d["process_utilization"] != int64(12) || d["memory_utilization"] != int64(45) {
		t.Errorf("the other figures changed: %v", d)
	}
	if w := wait["detail"].(map[string]any); w["system_idle"] != int64(7) || w["system_idle_not_read"] != nil {
		t.Errorf("a wait_info row changed: %v", w)
	}
}
