package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// poolCollector is mssql_pool: an Azure SQL Database elastic pool's figures, a row a minute (CLOUDSQL C4; DBA Dash's
// Elastic Pool Storage cell and its pool pages are the shape, its AzureDBElasticPoolResourceStats collection reads
// master's sys.elastic_pool_resource_stats - pgvigil reads the database's own view instead, so no master login).
//
// sys.dm_elastic_pool_resource_stats (Microsoft Learn): 'returns the same data in any database in the same elastic
// pool', a row 'every few seconds', kept 'approximately 40 minutes', VIEW SERVER STATE (##MS_ServerStateReader## in
// master on Azure SQL Database); no pool name and no DTU or vCore limit (storage_limit_mb is its one limit).
//
// Every pooled database reads the view; its complete minutes are stored once per pool (the store's key: logical
// server, pool, minute - the first reader's row stays). A minute is the average of the few-second averages, the
// largest of the maxima, and the largest average CPU as the minute's maximum CPU; the storage figures are the
// minute's last. The current minute waits for the next read. An outage over 40 minutes leaves a gap.
//
// The pool's name: the instance's tag pool:<name>, else sys.database_service_objectives where the login may read it
// (Microsoft: dbManager in master, or the database's creator or owner), else the run is skipped with the step.
type poolCollector struct{}

func init() { Register(poolCollector{}) }

func (poolCollector) Name() string                   { return Prefix + "pool" }
func (poolCollector) DefaultInterval() time.Duration { return time.Minute }

func (poolCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind != KindAzureDB:
		return false, "elastic pools are Azure SQL Database's"
	case !strings.EqualFold(info.ServiceObjective, "ElasticPool"):
		return false, "not in an elastic pool (service objective " + orNone(info.ServiceObjective) + ")"
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE (##MS_ServerStateReader## in master): the pool's figures are not readable"
	}
	return true, ""
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

// poolNameSQL: the pool's name as the database's service objectives give it (NULL when the login may not read it).
const poolNameSQL = `SELECT CAST(elastic_pool_name AS nvarchar(128)) AS pool FROM sys.database_service_objectives WHERE database_id = DB_ID()`

// poolStatsSQL: the view's rows with the server's own UTC minute (a minute is complete when it is before it).
const poolStatsSQL = `SELECT CONVERT(varchar(27), end_time, 126) AS end_time,
  avg_cpu_percent, avg_data_io_percent, avg_log_write_percent, max_worker_percent, max_session_percent,
  avg_instance_cpu_percent, avg_instance_memory_percent, avg_edtu_percent, instance_vcores,
  used_storage_mb, allocated_storage_mb, storage_limit_mb, used_storage_percent, allocated_storage_percent,
  CONVERT(varchar(27), SYSUTCDATETIME(), 126) AS server_utc
FROM sys.dm_elastic_pool_resource_stats`

func (poolCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	pool, from := strings.TrimSpace(info.PoolTag), "tag"
	if pool == "" {
		from = "service objectives"
		if rows, err := QueryRows(ctx, conn, poolNameSQL); err == nil && len(rows) == 1 {
			pool, _ = rows[0]["pool"].(string)
		}
		if pool == "" {
			return nil, fmt.Errorf("the pool's name is unknown to this login (sys.database_service_objectives answers the database's creator or owner, or dbManager): tag the instance pool:<name>: %w", collect.ErrSkip)
		}
	}
	raw, err := QueryRows(ctx, conn, poolStatsSQL)
	if err != nil {
		return nil, fmt.Errorf("sys.dm_elastic_pool_resource_stats: %w", err)
	}
	samples := make([]poolSample, 0, len(raw))
	var now time.Time
	for _, r := range raw {
		s, err := poolSampleOf(r)
		if err != nil {
			return nil, err
		}
		samples = append(samples, s)
		if now.IsZero() {
			now = s.serverUTC
		}
	}
	server := info.ServerName
	out := make([]collect.Row, 0, 45)
	for _, m := range poolMinutes(samples, now) {
		out = append(out, m.row(server, pool, from))
	}
	return out, nil
}

// poolSample is one row of the view; a NULL figure is nil.
type poolSample struct {
	end, serverUTC time.Time
	f              map[string]*float64
}

// the view's figures, by the name the store's row gives the minute's average (avg_) or largest (max_) of them
var poolFigures = []struct{ col, agg string }{
	{"avg_cpu_percent", "avg"}, {"avg_data_io_percent", "avg"}, {"avg_log_write_percent", "avg"},
	{"max_worker_percent", "max"}, {"max_session_percent", "max"},
	{"avg_instance_cpu_percent", "avg"}, {"avg_instance_memory_percent", "avg"}, {"avg_edtu_percent", "avg"},
	{"instance_vcores", "last"}, {"used_storage_mb", "last"}, {"allocated_storage_mb", "last"}, {"storage_limit_mb", "last"},
	{"used_storage_percent", "last"}, {"allocated_storage_percent", "last"},
}

func poolSampleOf(r collect.Row) (poolSample, error) {
	end, err := poolTime(r["end_time"])
	if err != nil {
		return poolSample{}, fmt.Errorf("sys.dm_elastic_pool_resource_stats end_time: %w", err)
	}
	now, err := poolTime(r["server_utc"])
	if err != nil {
		return poolSample{}, fmt.Errorf("SYSUTCDATETIME: %w", err)
	}
	s := poolSample{end: end, serverUTC: now, f: map[string]*float64{}}
	for _, fg := range poolFigures {
		v, ok, err := poolNumber(r[fg.col])
		if err != nil {
			return poolSample{}, fmt.Errorf("sys.dm_elastic_pool_resource_stats %s: %w", fg.col, err)
		}
		if ok {
			s.f[fg.col] = &v
		}
	}
	return s, nil
}

// poolTime reads the view's UTC datetime (QueryRows' zone-less text: the view's end_time is UTC by Microsoft's page).
func poolTime(v any) (time.Time, error) {
	s, ok := v.(string)
	if !ok || s == "" {
		return time.Time{}, fmt.Errorf("not a time: %v", v)
	}
	return time.Parse("2006-01-02T15:04:05.999999999", s)
}

// poolNumber reads a decimal (QueryRows' text), a bigint or a float; nil is not a number.
func poolNumber(v any) (float64, bool, error) {
	switch x := v.(type) {
	case nil:
		return 0, false, nil
	case string:
		f, err := strconv.ParseFloat(x, 64)
		return f, err == nil, err
	case int64:
		return float64(x), true, nil
	case float64:
		return x, true, nil
	}
	return 0, false, fmt.Errorf("not a number: %T", v)
}

// poolMinute is one stored minute.
type poolMinute struct {
	minute  time.Time
	samples int
	vals    map[string]*float64 // avg_x / max_x / the last-figure names
	maxCPU  *float64
}

// poolMinutes groups the samples by the minute their interval ends in and keeps the complete minutes: those before
// the server's current minute.
func poolMinutes(samples []poolSample, serverNow time.Time) []poolMinute {
	cur := serverNow.Truncate(time.Minute)
	by := map[time.Time][]poolSample{}
	for _, s := range samples {
		m := s.end.Add(-time.Nanosecond).Truncate(time.Minute) // an interval ending at 12:01:00.000 belongs to 12:00
		if !m.Before(cur) {
			continue
		}
		by[m] = append(by[m], s)
	}
	out := make([]poolMinute, 0, len(by))
	for m, ss := range by {
		sort.Slice(ss, func(i, j int) bool { return ss[i].end.Before(ss[j].end) })
		pm := poolMinute{minute: m, samples: len(ss), vals: map[string]*float64{}}
		for _, fg := range poolFigures {
			var sum, top float64
			n := 0
			var last *float64
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
			if n == 0 {
				continue
			}
			switch fg.agg {
			case "avg":
				a, t := sum/float64(n), top
				pm.vals[fg.col] = &a
				if fg.col == "avg_cpu_percent" {
					pm.maxCPU = &t
				}
			case "max":
				pm.vals[fg.col] = &top
			default:
				l := *last
				pm.vals[fg.col] = &l
			}
		}
		out = append(out, pm)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].minute.Before(out[j].minute) })
	return out
}

func (m poolMinute) row(server, pool, from string) collect.Row {
	r := collect.Row{"server": server, "pool": pool, "name_from": from, "minute": m.minute.UTC().Format(time.RFC3339), "samples": m.samples}
	for _, fg := range poolFigures {
		if v := m.vals[fg.col]; v != nil {
			r[fg.col] = *v
		} else {
			r[fg.col] = nil
		}
	}
	if m.maxCPU != nil {
		r["max_cpu_percent"] = *m.maxCPU
	} else {
		r["max_cpu_percent"] = nil
	}
	return r
}
