package mssql

import (
	"strings"
	"testing"
)

// task 411: the optional captures' script - its sessions, predicates, exclusions, the text policy and the targets
func TestXECapturesScript(t *testing.T) {
	set := DefaultXECaptureSettings()
	set.AppExclude = append(set.AppExclude, "O'Brien App")
	sc, err := XECapturesScript("cap", XEFormServer, "full", nil, set)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"[pgvigil_cap_waits]", "[pgvigil_cap_warnings]", "[pgvigil_cap_warncounts]", "[pgvigil_cap_modules]",
		"ADD EVENT sqlos.wait_info(", "[opcode]=(1) AND [duration]>=(1000) AND [sqlserver].[is_system]=(0) AND [sqlserver].[database_id]>(0)",
		"[wait_type]<>(' + @k_waitfor + N')", "[wait_type]<>(' + @k_broker + N')",
		"[duration]>=(5000000)", // module_end in microseconds
		"[sqlserver].[client_app_name]<>N''pgvigil''", "N''O''''Brien App''",
		"NOT [sqlserver].[like_i_sql_unicode_string]([sqlserver].[client_app_name],N''DatabaseMail%'')",
		"NOT ([sqlserver].[database_name]=N''master'' AND [sqlserver].[like_i_sql_unicode_string]([object_name],N''sp[_]%''))",
		"ADD TARGET package0.event_counter", "pgvigil_cap_waits.xel", "sqlserver.sql_text",
		"MAX_DISPATCH_LATENCY=5 SECONDS", "ALLOW_SINGLE_EVENT_LOSS", "ISNULL((SELECT CAST(MIN(map_key)",
	} {
		if !strings.Contains(sc, want) {
			t.Errorf("the script lacks %q", want)
		}
	}
	// the exact names come before the LIKE patterns in a predicate
	wait := sc[strings.Index(sc, "ADD EVENT sqlos.wait_info("):]
	wait = wait[:strings.Index(wait, "';")]
	if strings.Index(wait, "like_i_sql_unicode_string") < strings.LastIndex(wait, "<>N''") {
		t.Errorf("a LIKE comes before an exact name: %s", wait)
	}
	// the counts session has no ring buffer or file: only its event_counter
	cs := sc[strings.Index(sc, "-- pgvigil_cap_warncounts"):strings.Index(sc, "-- pgvigil_cap_modules")]
	if strings.Contains(cs, "event_file") || strings.Contains(cs, "ring_buffer") {
		t.Errorf("the counts session keeps events: %s", cs)
	}
	none, err := XECapturesScript("cap", XEFormServer, "none", nil, set)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(none, "sqlserver.sql_text") {
		t.Error("under query_text none the script still captures the statement text")
	}
	mi, _ := XECapturesScript("cap", XEFormAzureMI, "full", []string{"waits"}, set)
	if !strings.Contains(mi, "ring_buffer") || strings.Contains(mi, ".xel") || strings.Contains(mi, "pgvigil_cap_modules") {
		t.Errorf("the Managed Instance form, waits only: %s", mi)
	}
	rds, _ := XECapturesScript("cap", XEFormRDS, "full", []string{"modules"}, set)
	if !strings.Contains(rds, `D:\rdsdbdata\log\pgvigil_cap_modules.xel`) || !strings.Contains(rds, "Express and Web") {
		t.Errorf("the RDS form: %s", rds)
	}
}

func TestXECapturesDropScript(t *testing.T) {
	d, err := XECapturesDropScript("cap", XEFormServer, nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(d, "DROP EVENT SESSION") != 4 || !strings.Contains(d, "The event files they wrote stay") || strings.Contains(d, "pgvigil_cap_slow") {
		t.Errorf("the drop script: %s", d)
	}
	if _, err := XECapturesDropScript("cap", XEFormServer, []string{"slow"}); err == nil {
		t.Error("the drop script took a capture that is not optional")
	}
}

func TestXECaptureSettingsRefused(t *testing.T) {
	for _, s := range []XECaptureSettings{
		{WaitMS: 50, ModuleMS: 5000}, {WaitMS: 1000, ModuleMS: 50},
		{WaitMS: 1000, ModuleMS: 5000, AppExclude: []string{"bad\x01name"}},
		{WaitMS: 1000, ModuleMS: 5000, ProcExclude: []string{"nodot"}},
	} {
		if CheckXECaptureSettings(s) == nil {
			t.Errorf("accepted %+v", s)
		}
	}
}

// every event a capture's session adds has a parser, but the counted ones (an event_counter keeps no events)
func TestXECapturesEventsHaveParsers(t *testing.T) {
	for _, c := range XECaptureNames {
		if c == xcCounts {
			continue
		}
		for _, e := range xcEventNames(c) {
			if _, ok := xeParsers[e]; !ok {
				t.Errorf("%s's event %s has no parser", c, e)
			}
		}
	}
}

const fixWait = `<event name="wait_info" package="sqlos" timestamp="2026-11-14T18:00:03.500Z"><data name="wait_type"><value>4</value><text>LCK_M_X</text></data><data name="opcode"><value>1</value><text>End</text></data><data name="duration"><value>3012</value></data><data name="signal_duration"><value>1</value></data><action name="sql_text" package="sqlserver"><value><![CDATA[UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1)]]></value></action><action name="query_plan_hash" package="sqlserver"><value>1311768467463790320</value></action><action name="session_id" package="sqlserver"><value>61</value></action><action name="server_principal_name" package="sqlserver"><value><![CDATA[app]]></value></action><action name="database_name" package="sqlserver"><value><![CDATA[xcdb]]></value></action><action name="client_app_name" package="sqlserver"><value><![CDATA[SQLCMD]]></value></action><action name="event_sequence" package="package0"><value>3</value></action></event>`

const fixModule = `<event name="module_end" package="sqlserver" timestamp="2026-11-14T18:00:09.000Z"><data name="source_database_id"><value>5</value></data><data name="object_type"><value>8272</value><text>P</text></data><data name="duration"><value>6004321</value></data><data name="row_count"><value>0</value></data><data name="object_name"><value><![CDATA[p_slow]]></value></data><action name="session_id" package="sqlserver"><value>62</value></action><action name="database_name" package="sqlserver"><value><![CDATA[xcdb]]></value></action><action name="event_sequence" package="package0"><value>4</value></action></event>`

func TestXECapturesParsers(t *testing.T) {
	w := parseXWait(mustEvent(t, fixWait), xeContext{session: "pgvigil_cap_waits", queryText: "full"})
	if w["kind"] != "xwait" || w["wait_type"] != "LCK_M_X" || w["category"] != "Locking" || w["session_id"] == nil ||
		w["statement"] != "UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1)" || w["query_plan_hash_hex"] != "0x123456789ABCDEF0" {
		t.Errorf("the wait: %v", w)
	}
	m := parseXModule(mustEvent(t, fixModule), xeContext{session: "pgvigil_cap_modules"})
	if m["kind"] != "xmodule" || m["object_name"] != "p_slow" || m["database_name"] != "xcdb" {
		t.Errorf("the module: %v", m)
	}
	if d, ok := asInt(m["duration_us"]); !ok || d != 6004321 {
		t.Errorf("the module's duration (microseconds): %v", m["duration_us"])
	}
}
