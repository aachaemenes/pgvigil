package web

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

// ---- the composed panel: its spec and its compiler (the server half) ---------------------------------------------------
// A dashboard's composed panel (Erik Darling's custom views, K08.03 as the design reduces it) names one metric of
// pgvigil.metric_catalog and how to draw it; serve compiles it to ONE statement over pgvigil.metric_points - never free
// SQL: every word of the statement comes from the lists below or is a bound parameter.
//   level 1: each instance (and, grouped by database, each database) per time bucket, rolled up by the metric's grain
//            (metric_catalog.grain: a rate, a gauge or a ratio averaged, a count per collection interval summed), so an
//            instance read every 5 minutes weighs what one read every minute does;
//   level 2: the panel's aggregate across the group (sum, avg, min, max, count, p95; a ratio takes avg, min, max).
// Shapes: over_time (one series per group), top_over_time (the top N groups by their aggregate over the window, the
// rest folded into '(other)' computed from the same level-1 values, so it is right for every aggregate), ranked (one
// value per group over the window) and single (one value); ranked and single roll each instance up over the whole
// window (level 1 with the window as its one bucket). Group-by: none, instance, tag (the value of one tag key; an
// instance with two values of it counts in both, so a sum by tag is refused), database (the PostgreSQL database family
// on one instance). Buckets: minute, hour, day (UTC days, said so) or auto (about 600 points).

// PanelSpec is one composed panel as a dashboard's state holds it.
type PanelSpec struct {
	Metric    string        `json:"metric"`    // metric_catalog.key: 'family.metric'
	Aggregate string        `json:"aggregate"` // sum | avg | min | max | count | p95
	Shape     string        `json:"shape"`     // over_time | top_over_time | ranked | single
	Bucket    string        `json:"bucket"`    // auto | minute | hour | day
	GroupBy   string        `json:"group_by"`  // none | instance | tag | database
	TagKey    string        `json:"tag_key"`   // group_by tag: the key of the 'key:value' tags
	Top       int           `json:"top"`       // top_over_time: 1-8; ranked: 1-1000; 0 = 10 (8 over time)
	Other     bool          `json:"other"`     // fold the rest into '(other)'
	Filters   []PanelFilter `json:"filters"`
	Window    string        `json:"window"` // "" = the dashboard's range; else 1h | 6h | 24h | 7d | 30d | 90d, pinned
}

// PanelFilter keeps (is) or drops (is_not) instances or databases by name, or instances by tag ('key:value').
type PanelFilter struct {
	Dim    string   `json:"dim"` // instance | tag | engine | database
	Op     string   `json:"op"`  // is | is_not
	Values []string `json:"values"`
}

// ComposeScope is the dashboard's scope: the fleet, one tag, or a set of instances.
type ComposeScope struct {
	Kind      string `json:"kind"` // fleet | tag | instances
	Tag       string `json:"tag"`
	Instances []int  `json:"instances"`
}

// catalogMetric is the metric_catalog row a panel names.
type catalogMetric struct {
	Key, Engine, Family, Metric, Unit, Grain string
	PerDatabase                              bool
}

// composed is a compiled panel: its statement, its parameters, and what it read, said to the page.
type composed struct {
	SQL        string
	Args       []any
	BucketSecs int
	From, To   time.Time
	Cut        string // why the window was cut ("" = read as asked)
	Read       string // the read in words: the function, its family, the scope, the level-1 roll-up and the aggregate
	UTCDays    bool
	Instances  int  // the scope's instances read
	LastPart   bool // the last bucket ends after the window: it holds part of its time
}

var (
	composeAggregates = map[string]string{"sum": "sum(%s)", "avg": "avg(%s)", "min": "min(%s)", "max": "max(%s)",
		"count": "count(%s)", "p95": "percentile_cont(0.95) WITHIN GROUP (ORDER BY %s)"}
	composeWindows = map[string]time.Duration{"1h": time.Hour, "6h": 6 * time.Hour, "24h": 24 * time.Hour,
		"7d": 7 * 24 * time.Hour, "30d": 30 * 24 * time.Hour, "90d": 90 * 24 * time.Hour}
	composeBuckets = map[string]int{"minute": 60, "hour": 3600, "day": 86400}
	// the auto bucket's steps: the smallest that keeps a window at about 600 points or fewer
	composeAutoSteps = []int{60, 300, 900, 3600, 6 * 3600, 86400}
)

// composeMaxRange is the longest window a panel reads. composeFamilyRange is each family's longest window at
// composeMeasuredInstances instances, from the box measurement scripts/measure-compose.sh (2026-11-15, one LATERAL
// statement at fleet scope under serve's settings): the longest measured range whose warm run answered under 7.5 s, half
// serve's 15 s. A read grows with instances x days, so a panel scoped to fewer instances reads proportionally longer
// (up to composeMaxRange); a fleet or tag scope is taken as the measured fleet.
var (
	composeMaxRange          = 90 * 24 * time.Hour
	composeMeasuredInstances = 40
	composeFamilyRange       = map[string]time.Duration{
		"cpu":       31 * 24 * time.Hour, // 1.0 s at 7 days, 5.3 s at 31, past 15 s at 90
		"sessions":  7 * 24 * time.Hour,  // 2.5 s at 7 days, 14.9 s cold / past 15 s warm at 31
		"server":    7 * 24 * time.Hour,  // 5.1 s at 7 days, past 15 s at 31
		"host":      7 * 24 * time.Hour,  // 2.1 s at 7 days, 11.6 s at 31
		"requests":  7 * 24 * time.Hour,  // 1.9 s at 7 days, 11.5 s at 31
		"scheduler": 7 * 24 * time.Hour,  // 2.5 s at 7 days, 11.8 s at 31
		"memory":    7 * 24 * time.Hour,  // 4.7 s at 7 days, past 15 s at 31
		"io":        24 * time.Hour,      // 0.8 s at 6 hours, 3.1 s at 1 day, 11.3 s at 2, past 15 s at 7 (30 rows a read)
		"database":  24 * time.Hour,      // dbstats_rate over every database: 5.0 s at 1 day, 8.6 s at 2, past 15 s at 7
	}
	// composePerDatabaseRange: the database family read per database (grouped or filtered by database; one call a
	// database, each reading the instance's databases): 3.6 s at 6 hours, 14.2 s warm and past 15 s cold at 1 day, on an
	// instance of 150 databases
	composePerDatabaseRange = 6 * time.Hour
)

// composeFamilyEvery: each family's default read interval (the collections' DefaultInterval); a bucket that aggregates
// across instances is at least composeBucketFloor of it - an instance read every 5 minutes has no row in most minute
// buckets, so a minute sum across instances would saw between the instances present
var composeFamilyEvery = map[string]int{"io": 300}

const (
	composeBucketFloorOneMinute  = 300 // a 1-minute family's floor: also covers a 5-minute schedule an instance names
	composeBucketFloorFiveMinute = 600
	composeMaxPoints             = 2000 // buckets a series
	composeMaxSeries             = 24   // an over-time panel's groups past it fold into '(other)'
	composeMaxInstances          = 200  // a panel's instances (the measurement's fleet is 40 per engine)
	composeMaxTop                = 1000
	composeMaxTopSeries          = 8 // the most series a chart draws
	composeMaxFilters            = 10
	composeMaxValues             = 100
)

// checkPanel refuses, in words, a spec the compiler would not draw honestly.
func checkPanel(p *PanelSpec, m catalogMetric) error {
	if _, ok := composeAggregates[p.Aggregate]; !ok {
		return fmt.Errorf("aggregate %q: one of sum, avg, min, max, count, p95", p.Aggregate)
	}
	if m.Grain == "ratio" && (p.Aggregate == "sum" || p.Aggregate == "count") {
		return fmt.Errorf("%s is a ratio (%s): avg, min or max, never %s", m.Key, m.Unit, p.Aggregate)
	}
	switch p.Shape {
	case "over_time", "top_over_time", "ranked", "single":
	default:
		return fmt.Errorf("shape %q: one of over_time, top_over_time, ranked, single", p.Shape)
	}
	if _, ok := composeBuckets[p.Bucket]; !ok && p.Bucket != "auto" && p.Bucket != "" {
		return fmt.Errorf("bucket %q: one of auto, minute, hour, day", p.Bucket)
	}
	if p.Bucket == "minute" && (p.Shape != "over_time" || p.GroupBy != "instance") {
		return errors.New("a minute bucket only for an over-time panel by instance: across instances read at other times a minute sum saws (auto takes 5 minutes or more)")
	}
	switch p.GroupBy {
	case "", "none":
		p.GroupBy = "none"
		if p.Shape == "top_over_time" || p.Shape == "ranked" {
			return fmt.Errorf("a %s panel groups by instance, tag or database", p.Shape)
		}
	case "instance":
	case "tag":
		if strings.TrimSpace(p.TagKey) == "" || strings.Contains(p.TagKey, ":") {
			return errors.New("a panel grouped by tag names the tag's key (env of env:prod)")
		}
		if p.Aggregate == "sum" {
			return errors.New("a sum by tag is refused: an instance with two values of the key counts in both")
		}
	case "database":
		if !m.PerDatabase {
			return fmt.Errorf("%s has no per-database series: only the PostgreSQL database family groups by database", m.Key)
		}
	default:
		return fmt.Errorf("group_by %q: one of none, instance, tag, database", p.GroupBy)
	}
	if p.Shape == "single" && p.GroupBy != "none" {
		return errors.New("a single value has no group: group_by none")
	}
	switch {
	case p.Top == 0 && p.Shape == "top_over_time":
		p.Top = composeMaxTopSeries
	case p.Top == 0:
		p.Top = 10
	case p.Top < 0 || p.Top > composeMaxTop:
		return fmt.Errorf("top %d: 1 to %d", p.Top, composeMaxTop)
	case p.Shape == "top_over_time" && p.Top > composeMaxTopSeries:
		return fmt.Errorf("top %d over time: at most %d series, the most a chart draws", p.Top, composeMaxTopSeries)
	}
	if p.Window != "" {
		if _, ok := composeWindows[p.Window]; !ok {
			return fmt.Errorf("window %q: the dashboard's range, or 1h, 6h, 24h, 7d, 30d, 90d", p.Window)
		}
	}
	if len(p.Filters) > composeMaxFilters {
		return fmt.Errorf("%d filters: at most %d", len(p.Filters), composeMaxFilters)
	}
	for _, f := range p.Filters {
		if f.Op != "is" && f.Op != "is_not" {
			return fmt.Errorf("filter op %q: is or is_not", f.Op)
		}
		if len(f.Values) == 0 || len(f.Values) > composeMaxValues {
			return fmt.Errorf("a filter names 1 to %d values", composeMaxValues)
		}
		switch f.Dim {
		case "instance", "tag", "engine":
		case "database":
			if !m.PerDatabase {
				return fmt.Errorf("%s has no per-database series: a database filter cannot apply", m.Key)
			}
		default:
			return fmt.Errorf("filter on %q: instance, tag, engine or database", f.Dim)
		}
	}
	return nil
}

// composeWindow is the window a panel reads: its pinned window, else the dashboard's; cut to the family's longest
// range for the scope's instances (n, counted by serve; 0 = not counted, taken as the measured fleet), counted back from the end
// or now, whichever is earlier.
func composeWindow(p PanelSpec, family string, n int, from, to, now time.Time) (time.Time, time.Time, string) {
	if to.After(now) {
		to = now
	}
	if d, ok := composeWindows[p.Window]; ok {
		from = to.Add(-d)
	}
	limit := composeMaxRange
	if d, ok := composeFamilyRange[family]; ok {
		// a read grows with instances x days: scaled to the scope's instances both ways - but never up for the database
		// family, whose cost follows the databases (one instance of 150 held most of the measured rows)
		if n > composeMeasuredInstances || (n > 0 && family != "database") {
			d = time.Duration(float64(d) * float64(composeMeasuredInstances) / float64(n))
		}
		if d < limit {
			limit = d.Truncate(time.Hour)
		}
	}
	if to.Sub(from) > limit {
		return to.Add(-limit), to, fmt.Sprintf("the %s family is read at most %s at a time over this scope (a narrower scope reads longer)", family, fmtDays(limit))
	}
	return from, to, ""
}

func fmtDays(d time.Duration) string {
	switch {
	case d%(24*time.Hour) == 0:
		return fmt.Sprintf("%d days", int(d/(24*time.Hour)))
	case d >= 48*time.Hour:
		return fmt.Sprintf("%.1f days", d.Hours()/24)
	}
	return fmt.Sprintf("%d hours", int(d.Hours()))
}

// composeBucket is the bucket in seconds: the named one, or auto's step for about 600 points, at least floor.
func composeBucket(p PanelSpec, span time.Duration, floor int) int {
	if s, ok := composeBuckets[p.Bucket]; ok {
		return s
	}
	want := int(math.Ceil(span.Seconds() / 600))
	if want < floor {
		want = floor
	}
	for _, s := range composeAutoSteps {
		if s >= want {
			return s
		}
	}
	return composeAutoSteps[len(composeAutoSteps)-1]
}

// scopeWhere: the instances' conditions - active, of the metric's engine (args[0] the engine), in the scope, through the
// instance, tag and engine filters - each value a parameter arg returns.
func scopeWhere(sc ComposeScope, filters []PanelFilter, engineArg string, arg func(any) string) ([]string, error) {
	where := []string{"i.is_active", "(" + engineArg + " = 'any' OR i.engine = " + engineArg + ")"}
	switch sc.Kind {
	case "", "fleet":
	case "tag":
		if sc.Tag == "" {
			return nil, errors.New("a tag scope names its tag ('key:value')")
		}
		where = append(where, arg(sc.Tag)+" = ANY (i.tags)")
	case "instances":
		if len(sc.Instances) == 0 || len(sc.Instances) > composeMaxInstances {
			return nil, fmt.Errorf("an instances scope names 1 to %d instances", composeMaxInstances)
		}
		where = append(where, "i.instance_id = ANY ("+arg(sc.Instances)+"::int[])")
	default:
		return nil, fmt.Errorf("scope %q: fleet, tag or instances", sc.Kind)
	}
	for _, f := range filters {
		not := f.Op == "is_not"
		col := map[string]string{"instance": "i.name", "engine": "i.engine"}[f.Dim]
		switch {
		case col != "" && not:
			where = append(where, col+" <> ALL ("+arg(f.Values)+"::text[])")
		case col != "":
			where = append(where, col+" = ANY ("+arg(f.Values)+"::text[])")
		case f.Dim == "tag" && not:
			where = append(where, "NOT (i.tags && "+arg(f.Values)+"::text[])")
		case f.Dim == "tag":
			where = append(where, "i.tags && "+arg(f.Values)+"::text[]")
		}
	}
	return where, nil
}

// countScope is the statement serve runs first: the scope's instances (the cap's scale; past composeMaxInstances
// the panel is refused in words, never cut).
func countScope(p PanelSpec, m catalogMetric, sc ComposeScope) (string, []any, error) {
	args := []any{m.Engine}
	where, err := scopeWhere(sc, p.Filters, "$1", func(v any) string { args = append(args, v); return fmt.Sprintf("$%d", len(args)) })
	if err != nil {
		return "", nil, err
	}
	return "SELECT count(*) FROM pgvigil.instances i WHERE " + strings.Join(where, " AND "), args, nil
}

// compilePanel builds the panel's one statement for a scope of n instances (countScope's). Its parameters: $1 family,
// $2 metric, $3 from, $4 to, $5 the bucket in seconds, $6 the engine ('any' = both), $7.. the scope's and the
// filters' values.
func compilePanel(p PanelSpec, m catalogMetric, sc ComposeScope, from, to time.Time, database string, n int, now time.Time) (composed, error) {
	if err := checkPanel(&p, m); err != nil {
		return composed{}, err
	}
	perDB := p.GroupBy == "database"
	for _, f := range p.Filters {
		perDB = perDB || f.Dim == "database"
	}
	if perDB && (sc.Kind != "instances" || len(sc.Instances) != 1) {
		return composed{}, errors.New("a panel by database (grouped or filtered by database) reads one instance: an instances scope of one (the same database name on two instances is two databases)")
	}
	if n > composeMaxInstances {
		return composed{}, fmt.Errorf("the scope holds %d instances of this engine: a panel reads at most %d - narrow it by a tag or a set of instances", n, composeMaxInstances)
	}
	if n == 0 && sc.Kind == "instances" {
		n = len(sc.Instances)
	}
	from, to, cut := composeWindow(p, m.Family, n, from, to, now)
	if perDB && to.Sub(from) > composePerDatabaseRange {
		from = to.Add(-composePerDatabaseRange)
		cut = "the database family per database is read at most 6 hours at a time (one read a database)"
	}
	if !from.Before(to) {
		return composed{}, errors.New("the window is empty: from must be before to")
	}
	floor := composeBucketFloorOneMinute
	if composeFamilyEvery[m.Family] >= 300 {
		floor = composeBucketFloorFiveMinute
	}
	if p.Bucket == "minute" {
		floor = 60
	}
	window := p.Shape == "single" || p.Shape == "ranked"
	c := composed{To: to, Cut: cut, Instances: n}
	if window {
		c.From, c.BucketSecs = from, int(to.Sub(from).Seconds())
	} else {
		c.BucketSecs = composeBucket(p, to.Sub(from), floor)
		b := int64(c.BucketSecs)
		// the first bucket whole: the window starts on a bucket's edge (metric_points reads (from, to]: a read on the
		// edge itself belongs to the bucket it starts); the last says whether it is only partly in the window
		c.From = time.Unix(from.Unix()/b*b, 0).UTC()
		c.LastPart = to.Unix()%b != 0
		if pts := (to.Unix() - c.From.Unix() + b - 1) / b; pts > composeMaxPoints {
			return composed{}, fmt.Errorf("%d points a series at %s buckets: at most %d - a coarser bucket or a shorter window", pts, bucketWords(c.BucketSecs), composeMaxPoints)
		}
	}
	c.UTCDays = !window && c.BucketSecs == 86400
	readFrom := c.From
	if !window {
		readFrom = c.From.Add(-time.Microsecond)
	}
	args := []any{m.Family, m.Metric, readFrom, to, c.BucketSecs, m.Engine}
	arg := func(v any) string { args = append(args, v); return fmt.Sprintf("$%d", len(args)) }
	where, err := scopeWhere(sc, p.Filters, "$6", arg)
	if err != nil {
		return composed{}, err
	}
	var dbWhere []string
	for _, f := range p.Filters {
		if f.Dim != "database" {
			continue
		}
		if f.Op == "is_not" {
			dbWhere = append(dbWhere, "d.datname <> ALL ("+arg(f.Values)+"::text[])")
		} else {
			dbWhere = append(dbWhere, "d.datname = ANY ("+arg(f.Values)+"::text[])")
		}
	}
	// level 1: per instance (and database) per bucket - or over the whole window for single and ranked - by grain
	roll := "avg(p.value)"
	if m.Grain == "interval_count" {
		roll = "sum(p.value)"
	}
	bucket := "to_timestamp(floor(extract(epoch FROM p.at) / $5) * $5)"
	if window {
		// one roll-up per instance (and database) over the whole window - a gauge's window average, an interval count's
		// window total - before the aggregate across the group: per-bucket cells would weigh an instance by the buckets
		// it has rows in (a 5-minute instance misses a partial hour) and a sum would add a gauge's hours together
		bucket = "to_timestamp(floor(extract(epoch FROM $3::timestamptz) / $5) * $5)"
	}
	var src, key, dbWords string
	hasWhere := false
	switch {
	case perDB:
		// each database of the one instance: the database family's per-database read (its databases from dbstats in the window)
		dbs := "SELECT DISTINCT s.datname FROM pgvigil.dbstats s WHERE s.instance_id = inst.instance_id AND s.snapshot_at > $3 AND s.snapshot_at <= $4"
		src = "inst CROSS JOIN LATERAL (" + dbs + ") d CROSS JOIN LATERAL pgvigil.metric_points(inst.instance_id, $1, $3, $4, interval '15 minutes', d.datname) p"
		if len(dbWhere) > 0 {
			src += " WHERE " + strings.Join(dbWhere, " AND ")
			hasWhere = true
		}
		key, dbWords = "d.datname", " and each database"
	case database != "" && m.PerDatabase:
		// the $database variable: one database's series of each instance
		src = "inst CROSS JOIN LATERAL pgvigil.metric_points(inst.instance_id, $1, $3, $4, interval '15 minutes', " + arg(database) + ") p"
		key, dbWords = "NULL::text", ", database "+database
	default:
		src = "inst CROSS JOIN LATERAL pgvigil.metric_points(inst.instance_id, $1, $3, $4) p"
		key = "NULL::text"
		if database != "" {
			dbWords = " (the $database variable does not apply: " + m.Key + " has no per-database series)"
		}
	}
	metricWhere := " WHERE p.metric = $2"
	if hasWhere {
		metricWhere = " AND p.metric = $2"
	}
	l1 := "SELECT inst.instance_id, inst.name, inst.tags, " + key + " AS datname, " + bucket + " AS bucket, " + roll + " AS v FROM " +
		src + metricWhere + " GROUP BY 1, 2, 3, 4, 5"
	// the group of each level-1 value
	var g, kArg string
	if p.GroupBy == "tag" {
		kArg = arg(p.TagKey)
	}
	switch p.GroupBy {
	case "none":
		g = "'all'::text"
	case "instance":
		g = "l1.name"
	case "database":
		g = "l1.datname"
	case "tag":
		// an instance with no value of the key is its own group, said so
		g = "coalesce(t.v, '(no ' || " + kArg + " || ' tag)')"
	}
	from1 := "l1"
	if p.GroupBy == "tag" {
		from1 = "l1 LEFT JOIN LATERAL (SELECT substr(x, length(" + kArg + ") + 2) AS v FROM unnest(l1.tags) x WHERE x LIKE " +
			arg(likePrefix(p.TagKey)) + ") t ON true"
	}
	head := "WITH inst AS (SELECT i.instance_id, i.name, i.tags FROM pgvigil.instances i WHERE " + strings.Join(where, " AND ") +
		"),\nl1 AS (" + l1 + "),\ngl AS (SELECT " + g + " AS g, l1.bucket, l1.v FROM " + from1 + ")\n"
	aggG := fmt.Sprintf(composeAggregates[p.Aggregate], "gl.v")
	// the groups ranked by the panel's aggregate over the window; ng = how many groups there are
	rank := ", rk AS (SELECT gl.g, row_number() OVER (ORDER BY " + aggG + " DESC NULLS LAST, gl.g) AS r, count(*) OVER () AS ng FROM gl GROUP BY gl.g)\n"
	switch {
	case p.Shape == "over_time" && p.GroupBy == "none":
		c.SQL = head + "SELECT gl.bucket, gl.g AS series, " + aggG + " AS value FROM gl GROUP BY 1, 2 ORDER BY 1, 2"
	case p.Shape == "over_time":
		// every group up to composeMaxSeries, the rest folded into '(other)' (groups says how many there are)
		top := arg(composeMaxSeries)
		c.SQL = head + rank + "SELECT gl.bucket, CASE WHEN rk.r <= " + top + " THEN gl.g ELSE '(other)' END AS series, " + aggG +
			" AS value, max(rk.ng) AS groups FROM gl JOIN rk USING (g) GROUP BY 1, 2 ORDER BY 1, 2"
	case p.Shape == "single":
		c.SQL = head + "SELECT " + aggG + " AS value FROM gl"
	default: // top_over_time, ranked
		top := arg(p.Top)
		series := "CASE WHEN rk.r <= " + top + " THEN gl.g ELSE '(other)' END"
		keep := ""
		if !p.Other {
			keep = " WHERE rk.r <= " + top
		}
		if p.Shape == "top_over_time" {
			c.SQL = head + rank + "SELECT gl.bucket, " + series + " AS series, " + aggG + " AS value, max(rk.ng) AS groups FROM gl JOIN rk USING (g)" + keep +
				" GROUP BY 1, 2 ORDER BY 1, 2"
		} else {
			c.SQL = head + rank + "SELECT " + series + " AS series, " + aggG + " AS value, min(rk.r) AS rank, max(rk.ng) AS groups FROM gl JOIN rk USING (g)" + keep +
				" GROUP BY 1 ORDER BY 3, 1"
		}
	}
	c.Args = args
	per := bucketWords(c.BucketSecs)
	if window {
		per = "the window"
	}
	filters := ""
	if len(p.Filters) > 0 {
		filters = fmt.Sprintf(", %d filter(s)", len(p.Filters))
	}
	c.Read = fmt.Sprintf("pgvigil.metric_points(each of %d instances%s, '%s', %s, %s)%s: %s per instance%s per %s, then %s across the %s",
		n, dbWords, m.Family, c.From.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339), filters,
		map[bool]string{true: "summed", false: "averaged"}[roll == "sum(p.value)"],
		map[bool]string{true: " and database", false: ""}[key == "d.datname"], per, p.Aggregate,
		map[string]string{"none": "scope", "instance": "instances", "tag": p.TagKey + " values", "database": "databases"}[p.GroupBy])
	return c, nil
}

// likePrefix is 'key:%' with LIKE's own characters escaped.
func likePrefix(key string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(key) + ":%"
}

func bucketWords(s int) string {
	switch s {
	case 60:
		return "minute"
	case 300:
		return "5 minutes"
	case 900:
		return "15 minutes"
	case 3600:
		return "hour"
	case 6 * 3600:
		return "6 hours"
	case 86400:
		return "day (UTC)"
	}
	return fmt.Sprintf("%d s", s)
}
