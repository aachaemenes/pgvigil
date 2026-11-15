package web

import (
	"strings"
	"testing"
	"time"
)

var (
	composeGauge = catalogMetric{Key: "sessions.total", Engine: "postgres", Family: "sessions", Metric: "total", Unit: "count", Grain: "gauge"}
	composeCount = catalogMetric{Key: "database.deadlocks", Engine: "postgres", Family: "database", Metric: "deadlocks", Unit: "count",
		Grain: "interval_count", PerDatabase: true}
	composeRatio = catalogMetric{Key: "database.cache_hit_pct", Engine: "postgres", Family: "database", Metric: "cache_hit_pct", Unit: "pct",
		Grain: "ratio", PerDatabase: true}
	composeHost = catalogMetric{Key: "host.load1", Engine: "any", Family: "host", Metric: "load1", Unit: "count", Grain: "gauge"}
)

// TestCheckPanel: the spec's refusals, each in words.
func TestCheckPanel(t *testing.T) {
	for _, c := range []struct {
		p    PanelSpec
		m    catalogMetric
		want string // "" = taken
	}{
		{PanelSpec{Aggregate: "sum", Shape: "over_time"}, composeGauge, ""},
		{PanelSpec{Aggregate: "median", Shape: "over_time"}, composeGauge, "aggregate"},
		{PanelSpec{Aggregate: "sum", Shape: "over_time"}, composeRatio, "ratio"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time"}, composeRatio, ""},
		{PanelSpec{Aggregate: "avg", Shape: "pie"}, composeGauge, "shape"},
		{PanelSpec{Aggregate: "avg", Shape: "ranked"}, composeGauge, "groups by"},
		{PanelSpec{Aggregate: "avg", Shape: "ranked", GroupBy: "instance"}, composeGauge, ""},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", GroupBy: "tag"}, composeGauge, "key"},
		{PanelSpec{Aggregate: "sum", Shape: "over_time", GroupBy: "tag", TagKey: "env"}, composeGauge, "counts in both"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", GroupBy: "database"}, composeGauge, "per-database"},
		{PanelSpec{Aggregate: "sum", Shape: "over_time", GroupBy: "database"}, composeCount, ""},
		{PanelSpec{Aggregate: "avg", Shape: "single", GroupBy: "instance"}, composeGauge, "no group"},
		{PanelSpec{Aggregate: "avg", Shape: "top_over_time", GroupBy: "instance", Top: 9}, composeGauge, "at most 8"},
		{PanelSpec{Aggregate: "avg", Shape: "ranked", GroupBy: "instance", Top: 1001}, composeGauge, "1 to 1000"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", Window: "2d"}, composeGauge, "window"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", Bucket: "week"}, composeGauge, "bucket"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", Filters: []PanelFilter{{Dim: "database", Op: "is", Values: []string{"a"}}}}, composeGauge, "per-database"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", Filters: []PanelFilter{{Dim: "instance", Op: "like", Values: []string{"a"}}}}, composeGauge, "is or is_not"},
		{PanelSpec{Aggregate: "avg", Shape: "over_time", Filters: []PanelFilter{{Dim: "instance", Op: "is"}}}, composeGauge, "1 to 100"},
	} {
		p := c.p
		err := checkPanel(&p, c.m)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%+v on %s: refused: %v", c.p, c.m.Key, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%+v on %s: %v, want a refusal saying %q", c.p, c.m.Key, err, c.want)
		}
	}
}

// TestComposeWindow: a pinned window, the family's range cut counted back from the end or now, the cut said.
func TestComposeWindow(t *testing.T) {
	now := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	day := 24 * time.Hour
	old := composeFamilyRange
	defer func() { composeFamilyRange = old }()
	composeFamilyRange = map[string]time.Duration{"database": 31 * day}
	f, to, cut := composeWindow(PanelSpec{}, "sessions", now.Add(-10*day), now.Add(-day), now)
	if !f.Equal(now.Add(-10*day)) || !to.Equal(now.Add(-day)) || cut != "" {
		t.Errorf("a window inside the range: %v .. %v %q", f, to, cut)
	}
	f, to, cut = composeWindow(PanelSpec{}, "database", now.Add(-90*day), now.Add(5*day), now)
	if !to.Equal(now) || !f.Equal(now.Add(-31*day)) || !strings.Contains(cut, "31 days") {
		t.Errorf("a 90-day database window from a future end: %v .. %v %q", f, to, cut)
	}
	f, _, _ = composeWindow(PanelSpec{Window: "6h"}, "sessions", now.Add(-30*day), now, now)
	if !f.Equal(now.Add(-6 * time.Hour)) {
		t.Errorf("a pinned 6h window starts %v", f)
	}
	f, _, cut = composeWindow(PanelSpec{}, "sessions", now.Add(-200*day), now, now)
	if !f.Equal(now.Add(-composeMaxRange)) || cut == "" {
		t.Errorf("past the longest range: %v %q", f, cut)
	}
}

// TestComposeBucket: auto keeps a window at about 600 points or fewer; a named bucket is kept.
func TestComposeBucket(t *testing.T) {
	for _, c := range []struct {
		b    string
		span time.Duration
		want int
	}{
		{"auto", time.Hour, 60}, {"auto", 24 * time.Hour, 300}, {"auto", 7 * 24 * time.Hour, 3600},
		{"auto", 31 * 24 * time.Hour, 6 * 3600}, {"auto", 90 * 24 * time.Hour, 6 * 3600}, {"auto", 400 * 24 * time.Hour, 86400}, {"minute", 90 * 24 * time.Hour, 60},
		{"day", time.Hour, 86400},
	} {
		if got := composeBucket(PanelSpec{Bucket: c.b}, c.span); got != c.want {
			t.Errorf("%s over %v: %d s, want %d", c.b, c.span, got, c.want)
		}
	}
}

// TestCompilePanel: the statement's shape: the roll-up by grain, the LATERAL instances, the aggregate, the fold, the
// scope and filters as parameters - a tag key's quote never in the SQL text.
func TestCompilePanel(t *testing.T) {
	now := time.Date(2026, 11, 15, 12, 0, 0, 0, time.UTC)
	from := now.Add(-7 * 24 * time.Hour)
	c, err := compilePanel(PanelSpec{Aggregate: "sum", Shape: "over_time"}, composeGauge, ComposeScope{}, from, now, "", now)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"CROSS JOIN LATERAL pgvigil.metric_points(inst.instance_id, $1, $3, $4) p WHERE p.metric = $2",
		"avg(p.value) AS v", "sum(gl.v) AS value", "($6 = 'any' OR i.engine = $6)", "GROUP BY 1, 2 ORDER BY 1, 2"} {
		if !strings.Contains(c.SQL, want) {
			t.Errorf("gauge over time: no %q in\n%s", want, c.SQL)
		}
	}
	if c.BucketSecs != 3600 || len(c.Args) != 6 {
		t.Errorf("gauge over time: bucket %d, %d args", c.BucketSecs, len(c.Args))
	}
	c, err = compilePanel(PanelSpec{Aggregate: "sum", Shape: "top_over_time", GroupBy: "database", Top: 5, Other: true,
		Filters: []PanelFilter{{Dim: "database", Op: "is_not", Values: []string{"template1"}}}}, composeCount,
		ComposeScope{Kind: "instances", Instances: []int{7}}, from, now, "", now)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"sum(p.value) AS v", "d.datname <> ALL ($8::text[])", "AND p.metric = $2", "THEN gl.g ELSE '(other)' END",
		"i.instance_id = ANY ($7::int[])", "rk AS (SELECT gl.g, row_number() OVER (ORDER BY sum(gl.v) DESC NULLS LAST, gl.g)"} {
		if !strings.Contains(c.SQL, want) {
			t.Errorf("deadlocks top 5 by database: no %q in\n%s", want, c.SQL)
		}
	}
	if strings.Contains(c.SQL, " WHERE rk.r <=") {
		t.Errorf("other: true still drops the rest:\n%s", c.SQL)
	}
	c, err = compilePanel(PanelSpec{Aggregate: "p95", Shape: "ranked", GroupBy: "tag", TagKey: "e'nv", Top: 3}, composeHost,
		ComposeScope{Kind: "tag", Tag: "region:west"}, from, now, "", now)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(c.SQL, "e'nv") || !strings.Contains(c.SQL, "percentile_cont(0.95) WITHIN GROUP (ORDER BY gl.v)") ||
		!strings.Contains(c.SQL, " WHERE rk.r <= ") {
		t.Errorf("p95 ranked by tag: the key in the text, no p95 or no cut:\n%s", c.SQL)
	}
	if c.Args[5] != "any" || c.Args[6] != "region:west" {
		t.Errorf("host's engine and the scope's tag as parameters: %v", c.Args)
	}
	if _, err := compilePanel(PanelSpec{Aggregate: "avg", Shape: "over_time"}, composeGauge, ComposeScope{Kind: "tag"}, from, now, "", now); err == nil {
		t.Error("a tag scope with no tag was compiled")
	}
	c, _ = compilePanel(PanelSpec{Aggregate: "avg", Shape: "single"}, composeRatio, ComposeScope{}, from, now, "app", now)
	if !strings.Contains(c.SQL, "interval '15 minutes', $7) p") || c.Args[6] != "app" {
		t.Errorf("the $database variable: %v\n%s", c.Args, c.SQL)
	}
}
