package demo

// IO rows for the demo fleet (the io collection) and the replication instance's IO: the shapes import_io and
// import_dms take.

import (
	"math"
	"strings"
	"time"
)

// ---------------------------------------------------------------- io (task 43)

// ioRows is the platform's storage metrics (CloudWatch AWS/RDS) of an RDS or Aurora instance, one datapoint per
// 5-minute snapshot dated at its period's start. rds-orders01 is the IO-bound one: its gp2 burst balance drains
// over the last 6 hours to 12 % at the anchor, and in the last 2 hours its queue depth is 14 and its read
// latency 26 ms (three IO findings).
func (g *Gen) ioRows(t time.Time) []Row {
	s := g.Spec
	if (s.Platform != "rds" && s.Platform != "aurora") || t.Minute()%5 != 0 {
		return nil
	}
	c := curve(t)
	at := t.Add(-5 * time.Minute)
	m := func(name, stat, unit string, v float64) Row {
		return Row{"kind": "metric", "source": s.Platform, "dim": s.Name, "metric": name, "stat": stat, "unit": unit, "at": at, "value": v}
	}
	r := 400 * s.Load * (0.2 + c) * (1 + 0.2*noise(s.Name+"rio", t))
	w := 250 * s.Load * (0.2 + c) * (1 + 0.2*noise(s.Name+"wio", t))
	q, rl := 0.5+3*c, 0.0012+0.0008*c
	hot := strings.HasSuffix(s.Name, "rds-orders01") && !t.Before(g.end.Add(-2*time.Hour))
	if hot {
		q, rl = 14, 0.026
	}
	out := []Row{m("ReadIOPS", "Average", "count/s", r), m("WriteIOPS", "Average", "count/s", w),
		m("ReadLatency", "Average", "s", rl), m("WriteLatency", "Average", "s", 0.0018+0.001*c),
		m("ReadThroughput", "Average", "bytes/s", r*16384), m("WriteThroughput", "Average", "bytes/s", w*24576),
		m("DiskQueueDepth", "Average", "count", q)}
	if s.Platform == "rds" {
		bal := 100.0
		if strings.HasSuffix(s.Name, "rds-orders01") {
			bal -= math.Min(88, math.Max(0, t.Sub(g.end.Add(-6*time.Hour)).Hours())*88/6)
		}
		out = append(out, m("BurstBalance", "Minimum", "percent", bal), m("EBSIOBalance%", "Minimum", "percent", 99),
			m("EBSByteBalance%", "Minimum", "percent", 99))
	} else {
		out = append(out, m("VolumeReadIOPs", "Average", "count/5min", r*300*0.3), m("VolumeWriteIOPs", "Average", "count/5min", w*300*0.4),
			m("StorageNetworkThroughput", "Average", "bytes/s", (r+w)*20000))
	}
	return out
}

// dmsIO is the replication instance's storage IO: while the CDC latency climbs (3 h to 45 min before the anchor)
// its write latency is 28 ms and its queue 16 - the IO that did not scale - then 6 ms and 2.
func (g *Gen) dmsIO(t time.Time) Row {
	c := curve(t)
	wl, q := 4+3*c, 1+c
	if !t.Before(g.end.Add(-3*time.Hour)) && t.Before(g.end.Add(-45*time.Minute)) {
		wl, q = 28, 16
	}
	return Row{"read_iops": 60 + 40*c, "write_iops": 900 + 1500*c, "read_latency_ms": 2 + c, "write_latency_ms": wl,
		"read_bytes_s": 1.5e6 * (0.5 + c), "write_bytes_s": 2.4e7 * (0.5 + c), "queue_depth": q,
		"net_tx_bytes_s": 6e6 * (0.5 + c), "net_rx_bytes_s": 9e6 * (0.5 + c), "metrics_at": t}
}
