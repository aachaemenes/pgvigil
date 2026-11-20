package config

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// A page instance's settings (0263, ST5a): ParsePageSettings reads the stored shape and refuses any other; apply puts
// them on an instance as pgvigil.yaml's schedules:, disabled: and query_text: would be, so Interval keeps the file's
// order (off, then the instance's own value, then the global schedules:, then the running plans box, then the
// default); Fingerprint moves with a change. Merge's reading of them is TestMergePageSettings (inventory_test.go).
func TestPageSettings(t *testing.T) {
	for _, c := range []struct{ raw, want string }{
		{``, ""},
		{`{}`, ""},
		{`{"schedules": {"statements": 60, "activity": 0}, "query_text": "none"}`, ""},
		{`{"schedules": {"statements": -1}}`, "its settings in Admin > Instances give statements -1: not whole seconds from 0 (off) to 30 days"},
		{`{"schedules": {"statements": 1.5}}`, "its settings in Admin > Instances give statements 1.5: not whole seconds from 0 (off) to 30 days"},
		{`{"schedules": {"statements": 2592001}}`, "its settings in Admin > Instances give statements 2592001: not whole seconds from 0 (off) to 30 days"},
		{`{"schedules": {"statements": 18446744134}}`, "its settings in Admin > Instances give statements 18446744134: not whole seconds from 0 (off) to 30 days"},
		{`{"query_text": "raw"}`, `its settings in Admin > Instances give query_text "raw": not full, normalized or none`},
		// ST5b (0266): thresholds and a paused collection's own interval
		{`{"thresholds": {"redo_queue_kb": 512000, "job_long_factor": 2.5, "backup_exclude": ["Sales%"]}, "paused": {"mssql_jobs": 600}}`, ""},
		{`{"thresholds": {"redo_queue_kb": -1}}`, "its settings in Admin > Instances give threshold redo_queue_kb -1: not a number of 0 or more"},
		{`{"thresholds": {"redo_queue_kb": "5"}}`, `its settings in Admin > Instances give threshold redo_queue_kb "5": not a number of 0 or more`},
		{`{"thresholds": {"backup_exclude": "Sales"}}`, "its settings in Admin > Instances give backup_exclude: not a list of database name patterns, none blank"},
		{`{"thresholds": {"backup_exclude": ["Sales", " "]}}`, "its settings in Admin > Instances give backup_exclude: not a list of database name patterns, none blank"},
		// blank is one explicit set on both sides (0266's btrim set): space, tab, newline, vertical tab,
		// form feed, carriage return - a no-break space is a pattern on both
		{`{"thresholds": {"backup_exclude": ["\t\u000b"]}}`, "its settings in Admin > Instances give backup_exclude: not a list of database name patterns, none blank"},
		{`{"thresholds": {"backup_exclude": ["\u00a0"]}}`, ""},
		{`{"paused": {"mssql_jobs": 30}}`, "its settings in Admin > Instances give paused mssql_jobs 30: not whole seconds from 60 to 30 days"},
		{`{"disabled": ["x"]}`, `its settings in Admin > Instances do not parse: json: unknown field "disabled"`},
		{`[]`, "its settings in Admin > Instances do not parse: json: cannot unmarshal array"},
	} {
		_, err := ParsePageSettings([]byte(c.raw))
		got := ""
		if err != nil {
			got = err.Error()
		}
		if c.want == "" && got != "" || c.want != "" && !strings.HasPrefix(got, c.want) {
			t.Errorf("%s: %q, want %q", c.raw, got, c.want)
		}
	}

	ps, err := ParsePageSettings([]byte(`{"schedules": {"statements": 60, "activity": 0, "dbstats": 7200}, "query_text": "none"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(ps.Stored())
	if string(b) != `{"query_text":"none","schedules":{"activity":0,"dbstats":7200,"statements":60}}` {
		t.Errorf("Stored: %s", b)
	}

	// apply puts them on an instance as the file's lines would be (Merge calls it: inventory_test.go)
	p1 := Instance{Name: "p1", Engine: EnginePostgres, QueryText: "full"}
	ps1, err := ParsePageSettings([]byte(`{"schedules": {"statements": 60, "activity": 0, "locks": 0}, "query_text": "none"}`))
	if err != nil {
		t.Fatal(err)
	}
	ps1.apply(&p1)
	p2 := Instance{Name: "p2", Engine: EnginePostgres, QueryText: "full"}
	if p1.QueryText != "none" || p2.QueryText != "full" {
		t.Errorf("query_text: p1 %q (want none), p2 %q (want the file's full)", p1.QueryText, p2.QueryText)
	}
	if strings.Join(p1.Disabled, ",") != "activity,locks" || p1.Schedules["statements"].Duration != time.Minute {
		t.Errorf("p1: disabled %v, statements %v", p1.Disabled, p1.Schedules["statements"])
	}
	// the order of Interval with the file's global schedules: beside the page's values
	cfg := &Config{Schedules: map[string]Duration{"statements": {Duration: 0}, "activity": {Duration: 30 * time.Second}, "dbstats": {Duration: 2 * time.Hour}}}
	for _, c := range []struct {
		in   Instance
		coll string
		def  time.Duration
		want time.Duration
	}{
		{p1, "statements", 5 * time.Minute, time.Minute}, // its own value before the global 0
		{p1, "activity", time.Minute, 0},                 // off before the global 30 s
		{p1, "dbstats", time.Hour, 2 * time.Hour},        // no value of its own: the global one
		{p2, "statements", 5 * time.Minute, 0},           // no value of its own: the global 0
		{p2, "locks", time.Minute, time.Minute},          // nothing anywhere: the default
	} {
		if got := cfg.Interval(c.in, c.coll, c.def); got != c.want {
			t.Errorf("%s %s: %v, want %v", c.in.Name, c.coll, got, c.want)
		}
	}
	// a change of a page instance's settings changes its fingerprint (its loops restart)
	again := Instance{Name: "p1", Engine: EnginePostgres, QueryText: "full"}
	ps2, _ := ParsePageSettings([]byte(`{"schedules": {"statements": 120}}`))
	ps2.apply(&again)
	if Fingerprint(again) == Fingerprint(p1) {
		t.Error("the fingerprint did not move with the settings")
	}
}

// TestPageSettingsThresholds (ST5b): a page instance's thresholds reach the instance as mssql_thresholds would from the
// file - numbers as float64 (never json.Number: mssql.ThresholdRows takes float64), backup_exclude as []string - and are
// stored back as read; paused is kept for the resume and is no schedule (the fingerprint: TestFingerprintThresholds,
// inventory_test.go).
func TestPageSettingsThresholds(t *testing.T) {
	ps, err := ParsePageSettings([]byte(`{"schedules": {"mssql_jobs": 0}, "paused": {"mssql_jobs": 600}, "thresholds": {"redo_queue_kb": 512000, "job_long_factor": 2.5, "backup_exclude": ["Sales%", "tmp_%"]}}`))
	if err != nil {
		t.Fatal(err)
	}
	in := Instance{Name: "m1", Engine: EngineSQLServer}
	ps.apply(&in)
	if v, ok := in.MSSQLThresholds["redo_queue_kb"].(float64); !ok || v != 512000 {
		t.Errorf("redo_queue_kb: %#v", in.MSSQLThresholds["redo_queue_kb"])
	}
	if v, ok := in.MSSQLThresholds["job_long_factor"].(float64); !ok || v != 2.5 {
		t.Errorf("job_long_factor: %#v", in.MSSQLThresholds["job_long_factor"])
	}
	if v, ok := in.MSSQLThresholds["backup_exclude"].([]string); !ok || strings.Join(v, ",") != "Sales%,tmp_%" {
		t.Errorf("backup_exclude: %#v", in.MSSQLThresholds["backup_exclude"])
	}
	if strings.Join(in.Disabled, ",") != "mssql_jobs" || len(in.Schedules) != 0 {
		t.Errorf("paused is no schedule: disabled %v, schedules %v", in.Disabled, in.Schedules)
	}
	b, _ := json.Marshal(ps.Stored())
	if string(b) != `{"paused":{"mssql_jobs":600},"schedules":{"mssql_jobs":0},"thresholds":{"backup_exclude":["Sales%","tmp_%"],"job_long_factor":2.5,"redo_queue_kb":512000}}` {
		t.Errorf("Stored: %s", b)
	}
}
