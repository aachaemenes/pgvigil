package web

// GET /api/trend (task B20-1, the Trend report in the Reports tree): one metric over raw samples of both engines, a
// statistic inside each hour or day bucket, one series per instance (the top N by the statistic over every sample of
// the range) or per database of one instance. The reader is pgvigil.trend_series (0273); this handler picks the
// window each arm may read, ranks, and says in words what the chart cannot show.

import (
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"time"
)

// fleetFileIOWindow is the newest raw window the fleet's file-IO latency reads until B21's hourly fileio (slice 418)
// lands (the lead 11-15 18:1x: 3 days when proof-trend's fleet-scale row reads both under 10 s, else 1 day). Measured
// at 100 instances x 40 files in the collector's order on dba-lab-box: trend_series over 3 days 6.97 / 7.84 s
// (b20-t1g1, load 12), 7.18 / 7.64 s (b20-t1g3, load 11) and 10.22 / 10.00 s (b20-t1g4 on main d3ed48d9, load 20 - over
// the line), over 1 day 4.11-7.01 s at load 8-12 and 9.14 / 8.88 s at load 20; box jobs A2: a week read raw takes
// 10-12 s at serve's work_mem, against its 15 s limit. So 1 day: the rule's answer on the box's busier hours.
const fleetFileIOWindow = 24 * time.Hour

// instanceFileIOWindow: one instance's file-IO arms (by instance and by database) read at most a week (the lead 17:0x)
const instanceFileIOWindow = 7 * 24 * time.Hour

// hourlyUpTo: a range up to 31 days is drawn by the hour, a longer one by the day
const hourlyUpTo = 31 * 24 * time.Hour

var trendLabel = map[string]string{"os_cpu": "OS CPU %", "sql_cpu": "SQL CPU %", "latency": "disk latency (ms)",
	"active": "active sessions / requests", "free_memory": "free memory %", "connections": "connections"}

// the statistics each metric offers: a metric where higher is worse ranks highest first; free memory lowest first
var trendStatHigh = map[string]bool{"p50": true, "p95": true, "p98": true, "p99": true, "max": true}
var trendStatLow = map[string]bool{"p50": true, "p5": true, "p2": true, "p1": true, "min": true}

type trendPoint struct {
	At time.Time `json:"at"`
	V  float64   `json:"v"`
	N  int       `json:"n"`
}

type trendSeries struct {
	InstanceID int          `json:"instance_id"`
	Name       string       `json:"name"`
	Engine     string       `json:"engine"`
	Database   string       `json:"database,omitempty"`
	Rank       *float64     `json:"rank"`
	Reach      *time.Time   `json:"reach"`
	Points     []trendPoint `json:"points"`
}

type trendNone struct {
	InstanceID int    `json:"instance_id"`
	Name       string `json:"name"`
	Engine     string `json:"engine"`
	Why        string `json:"why"`
}

type trendAnswer struct {
	Metric string        `json:"metric"`
	Label  string        `json:"label"`
	Bucket string        `json:"bucket"`
	Stat   string        `json:"stat"`
	From   time.Time     `json:"from"`
	To     time.Time     `json:"to"`
	Top    int           `json:"top"`
	Shown  int           `json:"shown"`
	Of     int           `json:"of"`
	Words  []string      `json:"words"`
	Series []trendSeries `json:"series"`
	None   []trendNone   `json:"none"`
}

type trendInst struct {
	id           int
	name, engine string
}

// windowWords says a window in days ('1 day', '3 days')
func windowWords(d time.Duration) string {
	if n := int(d.Hours() / 24); n != 1 {
		return fmt.Sprintf("%d days", n)
	}
	return "1 day"
}

// trendWhy is the reason an instance draws no line for a metric
func trendWhy(metric, engine string) string {
	switch {
	case metric == "sql_cpu" && engine == "postgres":
		return "PostgreSQL has no engine share of the host CPU (SQL CPU is SQL Server's)"
	case engine == "postgres" && (metric == "os_cpu" || metric == "free_memory"):
		return "no host read in the range (system_stats in the database, or CloudWatch on AWS)"
	case engine == "postgres" && metric == "latency":
		return "no I/O latency read in the range: pg_stat_io needs track_io_timing on (PostgreSQL 16 and later), else CloudWatch's Read / WriteLatency on AWS"
	}
	return "no sample in the range"
}

// Trend serves GET /api/trend
func (s *Server) Trend(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	_, from, to, err := paramsReach(r, false, maxWindow)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	a := trendAnswer{Metric: q.Get("metric"), Bucket: q.Get("bucket"), Stat: q.Get("stat"), Top: 5,
		Words: []string{}, Series: []trendSeries{}, None: []trendNone{}}
	var ok bool
	if a.Label, ok = trendLabel[a.Metric]; !ok {
		writeErr(w, http.StatusBadRequest, errors.New("metric must be os_cpu, sql_cpu, latency, active, free_memory or connections"))
		return
	}
	low := a.Metric == "free_memory"
	if a.Stat == "" {
		a.Stat = map[bool]string{false: "p95", true: "p5"}[low]
	}
	if (low && !trendStatLow[a.Stat]) || (!low && !trendStatHigh[a.Stat]) {
		writeErr(w, http.StatusBadRequest, errors.New(map[bool]string{false: "stat must be p50, p95, p98, p99 or max",
			true: "stat must be p50, p5, p2, p1 or min (free memory ranks lowest first)"}[low]))
		return
	}
	if a.Bucket == "" {
		a.Bucket = "hour"
	}
	if a.Bucket != "hour" && a.Bucket != "day" {
		writeErr(w, http.StatusBadRequest, errors.New("bucket must be hour or day"))
		return
	}
	tz := "UTC"
	if v := q.Get("tz"); v != "" {
		if !tzName.MatchString(v) {
			writeErr(w, http.StatusBadRequest, errors.New("tz must be a time zone name such as Europe/Berlin"))
			return
		}
		tz = v
	}
	loc, lerr := time.LoadLocation(tz)
	if lerr != nil {
		loc = time.UTC
	}
	var hour any // NULL = every hour
	if v := q.Get("hour"); v != "" {
		h, err := strconv.Atoi(v)
		if err != nil || h < 0 || h > 23 {
			writeErr(w, http.StatusBadRequest, errors.New("hour must be 0..23"))
			return
		}
		hour = h
	}
	if v := q.Get("top"); v != "" {
		if a.Top, err = strconv.Atoi(v); err != nil || a.Top < 1 || a.Top > 20 {
			writeErr(w, http.StatusBadRequest, errors.New("top must be 1..20"))
			return
		}
	}
	engine := q.Get("engine")
	if engine == "both" {
		engine = ""
	}
	if engine != "" && engine != "postgres" && engine != "sqlserver" {
		writeErr(w, http.StatusBadRequest, errors.New("engine must be both, postgres or sqlserver"))
		return
	}
	inst := 0
	if v := q.Get("instance"); v != "" {
		if inst, err = strconv.Atoi(v); err != nil || inst <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
	}
	by := q.Get("by")
	if by != "" && (by != "database" || a.Metric != "latency") {
		writeErr(w, http.StatusBadRequest, errors.New("by=database is for the disk latency"))
		return
	}
	ctx := r.Context()
	rows, err := s.pool.Query(ctx, `SELECT instance_id, name, engine FROM pgvigil.instances
		WHERE is_active AND ($1 = '' OR engine = $1) AND ($2 = 0 OR instance_id = $2) ORDER BY name`, engine, inst)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	var insts []trendInst
	byID := map[int]trendInst{}
	for rows.Next() {
		var t trendInst
		if err := rows.Scan(&t.id, &t.name, &t.engine); err != nil {
			rows.Close()
			s.reply(w, r, nil, err)
			return
		}
		insts = append(insts, t)
		byID[t.id] = t
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if inst != 0 && len(insts) == 0 {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no active instance %d", inst))
		return
	}
	a.From, a.To, a.Of = from, to, len(insts)
	// by database: one SQL Server instance's files (the lead 18:1x: the fleet's waits for hourly history)
	if by == "database" && inst == 0 {
		a.Words = append(a.Words, "file I/O by database across the fleet waits for hourly history; one instance's page shows it")
		s.reply(w, r, a, nil)
		return
	}
	if by == "database" && insts[0].engine == "postgres" {
		a.Words = append(a.Words, "pg_stat_io has no database split: PostgreSQL's file I/O is the whole cluster's")
		s.reply(w, r, a, nil)
		return
	}
	// the file-IO windows (the lead 17:0x / 18:1x): raw file IO is a row per file per minute
	if a.Metric == "latency" {
		reach, words := instanceFileIOWindow, "file I/O on one instance reads the newest 7 days until hourly history lands"
		if inst == 0 {
			reach = fleetFileIOWindow
			words = "file I/O trends across the fleet read the newest " + windowWords(fleetFileIOWindow) + " until hourly history lands"
		}
		if to.Sub(from) > reach {
			from = to.Add(-reach)
			a.From = from
			a.Words = append(a.Words, words)
		}
		a.Words = append(a.Words, "PostgreSQL's latency is pg_stat_io's read and write call time (the OS cache included), SQL Server's the I/O stall: each engine ranks within its own")
	}
	if a.Bucket == "hour" && to.Sub(from) > hourlyUpTo {
		a.Bucket = "day"
		a.Words = append(a.Words, "hourly up to 31 days, daily beyond")
	}
	var ids any // NULL = every instance (the read is limited only when an engine or one instance is asked)
	if engine != "" || inst != 0 {
		l := make([]int32, 0, len(insts))
		for _, t := range insts {
			l = append(l, int32(t.id))
		}
		ids = l
	}
	var byArg any
	if by != "" {
		byArg = by
	}
	type key struct {
		id int
		db string
	}
	got := map[key]*trendSeries{}
	trows, err := s.pool.Query(ctx, `SELECT instance_id, coalesce(database_name, ''), at, v, n
		FROM pgvigil.trend_series($1, $2, $3, $4, $5, $6, $7, $8, $9)`, a.Metric, ids, from, to, a.Bucket, a.Stat, hour, tz, byArg)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	for trows.Next() {
		var (
			id, n int
			db    string
			at    *time.Time
			v     float64
		)
		if err := trows.Scan(&id, &db, &at, &v, &n); err != nil {
			trows.Close()
			s.reply(w, r, nil, err)
			return
		}
		t, ok := byID[id]
		if !ok {
			continue // an instance not asked for, or not active
		}
		k := key{id, db}
		sr := got[k]
		if sr == nil {
			sr = &trendSeries{InstanceID: id, Name: t.name, Engine: t.engine, Database: db, Points: []trendPoint{}}
			got[k] = sr
		}
		if at == nil {
			vv := v
			sr.Rank = &vv
			continue
		}
		sr.Points = append(sr.Points, trendPoint{At: at.UTC(), V: v, N: n})
	}
	trows.Close()
	if err := trows.Err(); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	// the instances that draw nothing, with the reason
	has := map[int]bool{}
	for k := range got {
		has[k.id] = true
	}
	for _, t := range insts {
		if !has[t.id] || (a.Metric == "sql_cpu" && t.engine == "postgres") {
			a.None = append(a.None, trendNone{InstanceID: t.id, Name: t.name, Engine: t.engine, Why: trendWhy(a.Metric, t.engine)})
		}
	}
	// the rank: the statistic over every sample of the range, highest first (free memory lowest first); disk
	// latency ranks within each engine (pg_stat_io's call time and SQL Server's stall are not one measure)
	all := make([]*trendSeries, 0, len(got))
	for _, sr := range got {
		sort.Slice(sr.Points, func(i, j int) bool { return sr.Points[i].At.Before(sr.Points[j].At) })
		if len(sr.Points) > 0 {
			rc := sr.Points[0].At
			sr.Reach = &rc
		}
		all = append(all, sr)
	}
	better := func(x, y *trendSeries) bool {
		switch {
		case x.Rank == nil || y.Rank == nil:
			if (x.Rank == nil) != (y.Rank == nil) {
				return x.Rank != nil
			}
		case *x.Rank != *y.Rank:
			return (*x.Rank > *y.Rank) != low
		}
		if x.Name != y.Name {
			return x.Name < y.Name
		}
		return x.Database < y.Database
	}
	sort.Slice(all, func(i, j int) bool { return better(all[i], all[j]) })
	taken := map[string]int{}
	for _, sr := range all {
		group := ""
		if a.Metric == "latency" {
			group = sr.Engine
		}
		if by == "" && taken[group] >= a.Top {
			continue
		}
		taken[group]++
		a.Series = append(a.Series, *sr)
	}
	a.Shown = len(a.Series)
	// the reach (review-19's fold: each metric's own, from its oldest sample, never a constant): the range starts
	// before the oldest sample drawn
	var oldest *time.Time
	for _, sr := range a.Series {
		if sr.Reach != nil && (oldest == nil || sr.Reach.Before(*oldest)) {
			oldest = sr.Reach
		}
	}
	step := time.Hour
	if a.Bucket == "day" {
		step = 24 * time.Hour
	}
	if oldest != nil && oldest.After(from.Add(step)) {
		a.Words = append(a.Words, "samples kept back to "+oldest.In(loc).Format("2006-01-02")+" (purge); a year needs the hours (B21)")
	}
	s.reply(w, r, a, nil)
}
