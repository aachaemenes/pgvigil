package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// azureDBResourcesCollector is mssql_azuredb_resources: an Azure SQL Database's resource use, a row a minute (B2;
// DBA Dash's AzureDBResourceStats collection reads the same 13 columns of the same view, SQLAzureDBResourceStats.sql,
// and its AzureDBResourceStats_Raw view the per-sample DTU % and the ten buckets each of DTU, CPU, data IO and log
// write that its Azure Summary sums).
//
// sys.dm_db_resource_stats (Microsoft Learn): 'a row for every 15 seconds', kept 'for approximately one hour',
// VIEW DATABASE STATE on every tier; in an elastic pool the percentages are 'of the max limit for the databases as
// set in the elastic pool configuration'; after a failover it returns 'data for the time since that failover'.
//
// The read asks the server for the rows ending after the newest stored minute (the cursor 'azdb_since', moved by
// the import in the transaction that stores the minutes). A minute holds the averages of its 15-second rows, the
// per-sample maxima of CPU, data IO, log write and memory, DBA Dash's DTU % per sample (the greatest of CPU, data IO
// and log write when dtu_limit > 0) with the DTUs that makes, the sample count and the 4 x 10 bucket counts; the
// 15-second rows are not kept. The current minute waits for the next read. A first read, or a read after a gap (the
// view's oldest row starts after the newest stored minute: the collector down over the view's hour, a failover, a
// serverless resume), drops its oldest minute (the view trims its oldest rows one by one, so it may be short), and a
// gap row names the minutes the store will not have.
type azureDBResourcesCollector struct{}

func init() { Register(azureDBResourcesCollector{}) }

func (azureDBResourcesCollector) Name() string                   { return Prefix + "azuredb_resources" }
func (azureDBResourcesCollector) DefaultInterval() time.Duration { return time.Minute }

func (azureDBResourcesCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind != KindAzureDB:
		return false, "the database's resource use (sys.dm_db_resource_stats) is Azure SQL Database's"
	case !info.ViewDatabaseState:
		return false, "the login lacks VIEW DATABASE STATE: the database's resource use is not readable"
	}
	return true, ""
}

// AzureDBCursorSource names the cursor: the newest stored minute's start, as epoch seconds.
const AzureDBCursorSource = "azdb_since"

// azdbStatsSQL: DBA Dash's 13 columns, the server's own UTC time and the view's oldest row's end, from the rows
// ending after @p1 (every row when it is NULL). end_time is datetime, UTC by Microsoft's page.
const azdbStatsSQL = `SELECT CONVERT(varchar(27), end_time, 126) AS end_time,
  avg_cpu_percent, avg_data_io_percent, avg_log_write_percent, avg_memory_usage_percent, xtp_storage_percent,
  max_worker_percent, max_session_percent, dtu_limit, avg_instance_cpu_percent, avg_instance_memory_percent,
  cpu_limit, replica_role,
  CONVERT(varchar(27), SYSUTCDATETIME(), 126) AS server_utc,
  CONVERT(varchar(27), (SELECT MIN(o.end_time) FROM sys.dm_db_resource_stats o), 126) AS oldest_end
FROM sys.dm_db_resource_stats
WHERE @p1 IS NULL OR end_time > CONVERT(datetime2(3), @p1, 126)`

// azdbGrace is how long after a minute's end its last row may still arrive: the cursor moves past a stored minute
// for good, so a minute is stored only once this has passed.
const azdbGrace = 30 * time.Second

// azdbRowLength is one row's interval (Microsoft: a row for every 15 seconds) and the slack a gap allows past it.
const (
	azdbRowLength = 15 * time.Second
	azdbGapSlack  = 5 * time.Second
)

func (c azureDBResourcesCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	return c.RunFrom(ctx, conn, info, nil)
}

func (azureDBResourcesCollector) RunFrom(ctx context.Context, conn *sql.Conn, _ Info, cursor SeqCursorFunc) ([]collect.Row, error) {
	var last int64
	var have bool
	if cursor != nil {
		var err error
		if last, have, err = cursor(ctx, AzureDBCursorSource); err != nil {
			return nil, fmt.Errorf("the stored minutes' cursor: %w", err)
		}
	}
	since, arg := azdbSince(last, have)
	raw, err := QueryRows(ctx, conn, azdbStatsSQL, arg)
	if err != nil {
		return nil, fmt.Errorf("sys.dm_db_resource_stats: %w", err)
	}
	return azdbRead(raw, since, have)
}

// azdbSince turns the cursor (the newest stored minute's start) into that minute's end and the read's argument in
// the view's own form; no cursor reads every row.
func azdbSince(last int64, have bool) (time.Time, any) {
	if !have {
		return time.Time{}, nil
	}
	since := time.Unix(last, 0).UTC().Add(time.Minute)
	return since, since.Format("2006-01-02T15:04:05.000")
}

// the view's figures: averaged (avg), averaged with the per-sample maximum kept (avgmax), the largest (max), or the
// minute's last (last); the store's names
var azdbFigures = []struct{ col, store, agg string }{
	{"avg_cpu_percent", "cpu_percent", "avgmax"},
	{"avg_data_io_percent", "data_io_percent", "avgmax"},
	{"avg_log_write_percent", "log_write_percent", "avgmax"},
	{"avg_memory_usage_percent", "memory_usage_percent", "avgmax"},
	{"xtp_storage_percent", "xtp_storage_percent", "avg"},
	{"max_worker_percent", "max_worker_percent", "max"},
	{"max_session_percent", "max_session_percent", "max"},
	{"avg_instance_cpu_percent", "instance_cpu_percent", "avg"},
	{"avg_instance_memory_percent", "instance_memory_percent", "avg"},
	{"dtu_limit", "dtu_limit", "last"},
	{"cpu_limit", "cpu_limit", "last"},
	{"replica_role", "replica_role", "last"},
}

type azdbSample struct {
	end time.Time
	f   map[string]*float64
}

// dtuPercent is DBA Dash's per-sample DTU %: the greatest of CPU, data IO and log write (NULLs ignored) when
// dtu_limit > 0, else none (a vCore database).
func (s azdbSample) dtuPercent() *float64 {
	if l := s.f["dtu_limit"]; l == nil || *l <= 0 {
		return nil
	}
	var top *float64
	for _, c := range []string{"avg_cpu_percent", "avg_data_io_percent", "avg_log_write_percent"} {
		if v := s.f[c]; v != nil && (top == nil || *v > *top) {
			top = v
		}
	}
	return top
}

// azdbBucket is DBA Dash's bucket of a percentage: < 10, [10, 20), ... [80, 90), >= 90.
func azdbBucket(v float64) int {
	b := int(v / 10)
	switch {
	case v < 10:
		return 0
	case b > 9:
		return 9
	}
	return b
}

// azdbRead turns the read's rows into minute rows and, after a gap, the gap row.
func azdbRead(raw []collect.Row, since time.Time, haveCursor bool) ([]collect.Row, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	now, err := poolTime(raw[0]["server_utc"])
	if err != nil {
		return nil, fmt.Errorf("SYSUTCDATETIME: %w", err)
	}
	oldestEnd, err := poolTime(raw[0]["oldest_end"])
	if err != nil {
		return nil, fmt.Errorf("sys.dm_db_resource_stats oldest end_time: %w", err)
	}
	cur := now.Add(-azdbGrace).Truncate(time.Minute)
	by := map[time.Time][]azdbSample{}
	var oldest time.Time
	for _, r := range raw {
		end, err := poolTime(r["end_time"])
		if err != nil {
			return nil, fmt.Errorf("sys.dm_db_resource_stats end_time: %w", err)
		}
		s := azdbSample{end: end, f: map[string]*float64{}}
		for _, fg := range azdbFigures {
			v, ok, err := poolNumber(r[fg.col])
			if err != nil {
				return nil, fmt.Errorf("sys.dm_db_resource_stats %s: %w", fg.col, err)
			}
			if ok {
				s.f[fg.col] = &v
			}
		}
		m := end.Add(-time.Nanosecond).Truncate(time.Minute) // a row ending at 12:01:00.000 belongs to 12:00
		if oldest.IsZero() || m.Before(oldest) {
			oldest = m
		}
		if m.Before(cur) {
			by[m] = append(by[m], s)
		}
	}
	var out []collect.Row
	gap := haveCursor && oldestEnd.Sub(since) > azdbRowLength+azdbGapSlack
	if !haveCursor || gap {
		delete(by, oldest)
	}
	if gap {
		out = append(out, collect.Row{"kind": "gap", "gap_from": since.UTC().Format(time.RFC3339),
			"gap_to": oldest.Add(time.Minute).UTC().Format(time.RFC3339), "oldest_end": oldestEnd.UTC().Format(time.RFC3339Nano)})
	}
	minutes := make([]time.Time, 0, len(by))
	for m := range by {
		minutes = append(minutes, m)
	}
	sort.Slice(minutes, func(i, j int) bool { return minutes[i].Before(minutes[j]) })
	for _, m := range minutes {
		out = append(out, azdbMinute(m, by[m]))
	}
	return out, nil
}

// azdbMinute is one stored minute of its samples.
func azdbMinute(m time.Time, ss []azdbSample) collect.Row {
	sort.Slice(ss, func(i, j int) bool { return ss[i].end.Before(ss[j].end) })
	r := collect.Row{"kind": "minute", "minute": m.UTC().Format(time.RFC3339), "samples": len(ss)}
	for _, fg := range azdbFigures {
		var sum, top float64
		var last *float64
		n := 0
		for _, s := range ss {
			v := s.f[fg.col]
			if v == nil {
				continue
			}
			sum += *v
			if n == 0 || *v > top {
				top = *v
			}
			n++
			last = v
		}
		switch fg.agg {
		case "avg", "avgmax":
			r["avg_"+fg.store] = avgOrNil(sum, n)
			if fg.agg == "avgmax" {
				r["max_"+fg.store] = topOrNil(top, n)
			}
		case "max":
			r[fg.store] = topOrNil(top, n)
		default:
			if last != nil {
				r[fg.store] = *last
			} else {
				r[fg.store] = nil
			}
		}
	}
	// DTU % and DTUs per sample, then their average and largest
	var pSum, pTop, dSum, dTop float64
	n := 0
	buckets := map[string][]int{"dtu": make([]int, 10), "cpu": make([]int, 10), "data": make([]int, 10), "log": make([]int, 10)}
	for _, s := range ss {
		for k, c := range map[string]string{"cpu": "avg_cpu_percent", "data": "avg_data_io_percent", "log": "avg_log_write_percent"} {
			if v := s.f[c]; v != nil {
				buckets[k][azdbBucket(*v)]++
			}
		}
		p := s.dtuPercent()
		if p == nil {
			continue
		}
		buckets["dtu"][azdbBucket(*p)]++
		d := *s.f["dtu_limit"] * *p / 100
		pSum, dSum = pSum+*p, dSum+d
		if n == 0 || *p > pTop {
			pTop = *p
		}
		if n == 0 || d > dTop {
			dTop = d
		}
		n++
	}
	r["avg_dtu_percent"], r["max_dtu_percent"] = avgOrNil(pSum, n), topOrNil(pTop, n)
	r["avg_dtu"], r["max_dtu"] = avgOrNil(dSum, n), topOrNil(dTop, n)
	for k, b := range buckets {
		r[k+"_buckets"] = b
	}
	return r
}

func avgOrNil(sum float64, n int) any {
	if n == 0 {
		return nil
	}
	return sum / float64(n)
}

func topOrNil(top float64, n int) any {
	if n == 0 {
		return nil
	}
	return top
}
