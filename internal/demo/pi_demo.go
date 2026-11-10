package demo

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
)

// piDemoOn: the two Aurora instances with Performance Insights on.
func (g *Gen) piDemoOn() bool {
	return g.Spec.Platform == "aurora" && (strings.HasSuffix(g.Spec.Name, "aurora-crm01") || strings.HasSuffix(g.Spec.Name, "aurora-reporting01"))
}

// serverlessDemoOn: the one Serverless v2 instance.
func (g *Gen) serverlessDemoOn() bool {
	return g.Spec.Platform == "aurora" && strings.HasSuffix(g.Spec.Name, "aurora-reporting01")
}

// serverlessFloorFrom is the start of the floor window (the last 6 hours of the history).
func (g *Gen) serverlessFloorFrom() time.Time { return g.end.Add(-6 * time.Hour) }

// piDemoCollections names the two collections for the collection log (the caller already knows the platform is RDS
// or Aurora).
func (g *Gen) piDemoCollections() []string {
	c := []string{"pi"}
	if g.serverlessDemoOn() {
		c = append(c, "serverless")
	}
	return c
}

// piDemoRows is one hourly pi read (on the hour, and the first snapshot): the state row and, with PI on, the
// previous complete hour's load.
func (g *Gen) piDemoRows(t time.Time, first bool) []Row {
	s := g.Spec
	if (s.Platform != "rds" && s.Platform != "aurora") || (!first && t.Minute() != 0) {
		return nil
	}
	if !g.piDemoOn() {
		return []Row{{"kind": "state", "db_instance": s.Name, "resource_id": "db-DEMO" + strconv.FormatInt(hash64(s.Name)%1e12, 10),
			"enabled": false, "note": "Performance Insights is off on " + s.Name + " (DescribeDBInstances PerformanceInsightsEnabled false): no DB load is read"}}
	}
	hour := t.Truncate(time.Hour).Add(-time.Hour)
	c := curve(hour.Add(30 * time.Minute))
	starved := g.serverlessDemoOn() && !hour.Before(g.serverlessFloorFrom().Truncate(time.Hour))
	total := s.Load * (0.3 + 2.2*c) * (0.9 + 0.2*noise(s.Name+"piload", hour))
	// the wait mix: a CPU-heavy OLTP shape; the starved hours read from storage
	waits := []struct {
		name, typ string
		share     float64
	}{
		{"CPU", "CPU", 0.46}, {"DataFileRead", "IO", 0.22}, {"ClientRead", "Client", 0.12},
		{"WALWrite", "IO", 0.08}, {"BufferMapping", "LWLock", 0.07}, {"transactionid", "Lock", 0.05},
	}
	if starved {
		total *= 2.4
		waits = []struct {
			name, typ string
			share     float64
		}{
			{"DataFileRead", "IO", 0.71}, {"CPU", "CPU", 0.12}, {"BufferMapping", "LWLock", 0.08},
			{"ClientRead", "Client", 0.06}, {"WALWrite", "IO", 0.03},
		}
	}
	r2 := func(v float64) float64 { return math.Round(v*1000) / 1000 }
	out := []Row{
		{"kind": "state", "db_instance": s.Name, "resource_id": "db-DEMO" + strconv.FormatInt(hash64(s.Name)%1e12, 10),
			"enabled": true, "retention_days": 7, "hours_read": 3},
		{"kind": "load", "at": hour, "group": "total", "key": "", "value": r2(total)},
	}
	for _, w := range waits {
		out = append(out, Row{"kind": "load", "at": hour, "group": "wait", "key": w.name, "wait_type": w.typ, "value": r2(total * w.share)})
	}
	// the digests: the instance's statements weighted by their time (rate x mean); the starved hours lift the reads
	// that miss the cache (the report and the join)
	type dw struct {
		i int
		w float64
	}
	var ws []dw
	var sum float64
	for i, st := range g.stmts {
		w := st.rate * st.meanMS
		if starved && (st.report || i == 1) {
			w *= 12
		}
		ws = append(ws, dw{i, w})
		sum += w
	}
	sort.Slice(ws, func(a, b int) bool { return ws[a].w > ws[b].w })
	for n, x := range ws {
		if n == 8 || sum == 0 {
			break
		}
		st := g.stmts[x.i]
		tok := "demo-" + strconv.FormatInt(hash64(s.Name+"|tok|"+st.text)%1e15, 16)
		out = append(out,
			Row{"kind": "load", "at": hour, "group": "sql", "key": tok, "value": r2(total * 0.9 * x.w / sum)},
			Row{"kind": "sql", "tokenized_id": tok, "db_id": strconv.FormatInt(hash64(s.Name+"|"+st.text), 10),
				"query": st.text, "text_status": "whole"})
	}
	return out
}

// serverlessDemoRows is one 5-minute serverless read of the Serverless v2 instance (the datapoint of the period that
// just ended) and, every hour and on the first snapshot, its scaling row.
func (g *Gen) serverlessDemoRows(t time.Time, first bool) []Row {
	if !g.serverlessDemoOn() || t.Minute()%5 != 0 {
		return nil
	}
	s := g.Spec
	at := t.Add(-5 * time.Minute)
	c := curve(at)
	acu := math.Min(8, math.Max(1, math.Round((1+5.5*c*s.Load/0.7)*2)/2))
	hit := 99.1 + 0.6*noise(s.Name+"hit", at)
	reads := 40 + 160*c*(0.8+0.4*noise(s.Name+"srd", at))
	cpu := 18 + 45*c + 6*noise(s.Name+"scpu", at)
	if !at.Before(g.serverlessFloorFrom()) {
		acu, hit, reads, cpu = 1, 87.5+1.0*noise(s.Name+"hit", at), 880+40*noise(s.Name+"srd", at), 8.5+1.0*noise(s.Name+"scpu", at)
	}
	m := func(name, stat, unit string, v float64) Row {
		return Row{"kind": "metric", "dim": s.Name, "metric": name, "stat": stat, "unit": unit, "at": at, "value": math.Round(v*100) / 100}
	}
	out := []Row{
		m("ServerlessDatabaseCapacity", "Maximum", "ACU", acu),
		m("ACUUtilization", "Average", "percent", math.Min(100, 100*(0.55+0.4*c))),
		m("BufferCacheHitRatio", "Average", "percent", hit),
		m("ReadIOPS", "Average", "count/s", reads),
		m("CPUUtilization", "Average", "percent", cpu),
	}
	if first || t.Minute() == 0 {
		out = append(out, Row{"kind": "scaling", "db_instance": s.Name, "cluster": strings.TrimSuffix(s.Name, "01") + "-cluster",
			"class": "db.serverless", "min_acu": 1.0, "max_acu": 8.0})
	}
	return out
}
