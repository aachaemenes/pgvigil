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
		{`{"query_text": "raw"}`, `its settings in Admin > Instances give query_text "raw": not full, normalized or none`},
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
