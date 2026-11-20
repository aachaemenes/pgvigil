package alerts

import (
	"strings"
	"testing"
)

// TestRulePayloadCollectionWindow (B6g-4, N31; design L56): a rule on the Collection family takes a window of 60
// minutes or more - its points are hourly, so a shorter window judges one point or none; refused in words, with no
// window given (the table's default is 5) too; any other family keeps its own floor.
func TestRulePayloadCollectionWindow(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	n := func(v int) *int { return &v }
	none := func(int) string { return "" }
	for name, c := range map[string]struct {
		metric string
		mins   *int
		ok     bool
	}{
		"collection, 59 minutes":    {"collection.failed_pct", n(59), false},
		"collection, no window":     {"collection.duration_ms", nil, false},
		"collection, 60 minutes":    {"collection.failed_pct", n(60), true},
		"another family, 5 minutes": {"sessions.active", n(5), true},
		"another family, no window": {"cpu.sql_pct", nil, true},
	} {
		_, err := RulePayload(RuleRequest{Metric: c.metric, Dir: "above", Warning: f(10), ForMinutes: c.mins, Scope: "fleet"}, "", none)
		if c.ok && err != nil {
			t.Errorf("%s: refused (%v), want taken", name, err)
		}
		if !c.ok && (err == nil || !strings.Contains(err.Error(), "60 minutes or more")) {
			t.Errorf("%s: %v, want refused with '60 minutes or more'", name, err)
		}
	}
}

// TestRulePayloadCollectionBelow: a 'below' rule on the Collection family names its
// collection - with none the series is the worst (highest) collection, and 'below' would mean every one below; 'above'
// with none, and any other family's 'below', are taken
func TestRulePayloadCollectionBelow(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	n := func(v int) *int { return &v }
	none := func(int) string { return "" }
	for name, c := range map[string]struct {
		metric, dir, db string
		ok              bool
	}{
		"collection, below, no collection": {"collection.duration_ms", "below", "", false},
		"collection, below, a collection":  {"collection.duration_ms", "below", "activity", true},
		"collection, above, no collection": {"collection.failed_pct", "above", "", true},
		"another family, below":            {"sessions.active", "below", "", true},
	} {
		_, err := RulePayload(RuleRequest{Metric: c.metric, Dir: c.dir, Warning: f(10), ForMinutes: n(60), Scope: "fleet", Database: c.db}, "", none)
		if c.ok && err != nil {
			t.Errorf("%s: refused (%v), want taken", name, err)
		}
		if !c.ok && (err == nil || !strings.Contains(err.Error(), "names a collection")) {
			t.Errorf("%s: %v, want refused with 'names a collection'", name, err)
		}
	}
}
