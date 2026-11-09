package collect

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// ioCollector reads the storage IO metrics CloudWatch (AWS/RDS) publishes for an RDS instance or an Aurora
// cluster named in the instance's aws: block: the volume's IOPS, latency, throughput and queue depth, the
// EBS and burst balances on RDS, the cluster volume's billed IOs and the storage network on Aurora. Every
// datapoint of the read window is returned; the import keeps one row per metric and datapoint time, so a
// window read twice adds nothing and a missed run leaves no gap. Read only: two GetMetricData calls per run (the
// prompt series over 20 minutes, the late Aurora volume series over 2 hours).
type ioCollector struct{}

func init() { Register(ioCollector{}) }

const (
	ioPeriod     = 300              // seconds per datapoint: Aurora's volume IOs are 5-minute counts, the rest are averaged to match
	ioWindow     = 20 * time.Minute // read this far back each run: four periods, so one late or missed run loses nothing
	ioLateWindow = 2 * time.Hour    // the late series' window: Aurora's cluster volume counters arrive about 30 minutes behind
)

// ioMetric is one CloudWatch series: its name, the statistic read over the period, and the unit CloudWatch
// documents for it (stored with the row so the page never guesses: RDS latency is in seconds).
type ioMetric struct {
	name, stat, unit string
	late             bool // published well behind real time: read over ioLateWindow (the import keeps one row per datapoint)
}

var (
	// ioCommon is published for an RDS instance and, aggregated, for an Aurora cluster (list-metrics on the lab's
	// cluster, 2026-11-09); units from the RDS metrics reference.
	ioCommon = []ioMetric{
		{"ReadIOPS", "Average", "count/s", false}, {"WriteIOPS", "Average", "count/s", false},
		{"ReadLatency", "Average", "s", false}, {"WriteLatency", "Average", "s", false},
		{"ReadThroughput", "Average", "bytes/s", false}, {"WriteThroughput", "Average", "bytes/s", false},
		{"DiskQueueDepth", "Average", "count", false},
	}
	// ioRDS adds the gp2 / gp3 burst and the instance's EBS balances (percent left; Minimum: the low point counts).
	ioRDS = []ioMetric{
		{"EBSIOBalance%", "Minimum", "percent", false}, {"EBSByteBalance%", "Minimum", "percent", false}, {"BurstBalance", "Minimum", "percent", false},
	}
	// ioAurora adds the cluster volume: billed read and write IOs per 5 minutes, the storage network, and the
	// bytes left (AWS documents AuroraVolumeBytesLeftTotal for Aurora MySQL; on Aurora PostgreSQL no datapoint
	// comes back and no row is stored). The volume counters are published about 30 minutes late (the lab cluster,
	// 2026-11-09: the newest at 10:54 when read at 11:24): a 20-minute window never holds one.
	ioAurora = []ioMetric{
		{"VolumeReadIOPs", "Average", "count/5min", true}, {"VolumeWriteIOPs", "Average", "count/5min", true},
		{"StorageNetworkThroughput", "Average", "bytes/s", false}, {"AuroraVolumeBytesLeftTotal", "Minimum", "bytes", true},
	}
)

func (ioCollector) Name() string                   { return "io" }
func (ioCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (ioCollector) Applies(info platform.Info) (bool, string) {
	if info.Kind != platform.RDS && info.Kind != platform.Aurora {
		return false, "CloudWatch IO metrics are read for RDS and Aurora only"
	}
	return true, ""
}

// Configured: the collection runs only on an instance whose aws: block names its cluster or DB instance.
func (ioCollector) Configured(in config.Instance) (bool, string) {
	if in.AWS == nil || (in.AWS.Cluster == "" && in.AWS.DBInstance == "") {
		return false, "no aws.cluster or aws.db_instance in the config"
	}
	return true, ""
}

func (ioCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("io needs the instance config: %w", ErrSkip)
}

// ioClients keeps one CloudWatch client per profile and region across runs.
var (
	ioClientsMu sync.Mutex
	ioClients   = map[string]cloudwatch.GetMetricDataAPIClient{}
)

var newIOAPI = func(ctx context.Context, a config.AWS) (cloudwatch.GetMetricDataAPIClient, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return cloudwatch.NewFromConfig(cfg), nil
}

func ioClientFor(ctx context.Context, a config.AWS) (cloudwatch.GetMetricDataAPIClient, error) {
	k := a.Profile + "|" + a.Region
	ioClientsMu.Lock()
	defer ioClientsMu.Unlock()
	if c, ok := ioClients[k]; ok {
		return c, nil
	}
	c, err := newIOAPI(ctx, a)
	if err == nil {
		ioClients[k] = c
	}
	return c, err
}

func (c ioCollector) RunInstance(ctx context.Context, _ *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	if ok, why := c.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	if ok, why := c.Applies(info); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	api, err := ioClientFor(ctx, *in.AWS)
	if err != nil {
		return nil, err
	}
	return ioRows(ctx, api, info.Kind, *in.AWS, time.Now())
}

// ioTarget picks the series to read: an Aurora instance configured with its cluster reads the cluster
// dimension (the cluster volume and the members' aggregate), anything else the DB instance dimension.
func ioTarget(kind platform.Kind, a config.AWS) (dimName, dimValue, source string, metrics []ioMetric) {
	if kind == platform.Aurora {
		if a.Cluster != "" {
			return "DBClusterIdentifier", a.Cluster, "aurora", append(append([]ioMetric{}, ioCommon...), ioAurora...)
		}
		return "DBInstanceIdentifier", a.DBInstance, "aurora", append(append([]ioMetric{}, ioCommon...), ioAurora...)
	}
	return "DBInstanceIdentifier", a.DBInstance, "rds", append(append([]ioMetric{}, ioCommon...), ioRDS...)
}

// ioRows reads every metric of the target over the window and returns one row per datapoint:
// {kind:'metric', source, dim, metric, stat, unit, at, value}.
func ioRows(ctx context.Context, api cloudwatch.GetMetricDataAPIClient, kind platform.Kind, a config.AWS, now time.Time) ([]Row, error) {
	dimName, dimValue, source, metrics := ioTarget(kind, a)
	if dimValue == "" {
		return nil, fmt.Errorf("aws.db_instance is needed for %s IO metrics: %w", kind, ErrSkip)
	}
	var rows []Row
	// one call per window: the prompt series over ioWindow, the late ones over ioLateWindow
	for _, late := range []bool{false, true} {
		window := ioWindow
		if late {
			window = ioLateWindow
		}
		var queries []cwtypes.MetricDataQuery
		for i, m := range metrics {
			if m.late != late {
				continue
			}
			queries = append(queries, cwtypes.MetricDataQuery{
				Id: aws.String(fmt.Sprintf("m%d", i)),
				MetricStat: &cwtypes.MetricStat{
					Metric: &cwtypes.Metric{Namespace: aws.String("AWS/RDS"), MetricName: aws.String(m.name),
						Dimensions: []cwtypes.Dimension{{Name: aws.String(dimName), Value: aws.String(dimValue)}}},
					Period: aws.Int32(ioPeriod), Stat: aws.String(m.stat),
				},
			})
		}
		if len(queries) == 0 {
			continue
		}
		// the start on a period boundary: CloudWatch lays the periods from it, so every run returns a span under
		// the same timestamp and the import's (metric, datapoint time) key matches across runs
		in := &cloudwatch.GetMetricDataInput{
			StartTime: aws.Time(now.Add(-window).Truncate(ioPeriod * time.Second)), EndTime: aws.Time(now),
			MetricDataQueries: queries, ScanBy: cwtypes.ScanByTimestampAscending,
		}
		for {
			res, err := api.GetMetricData(ctx, in)
			if err != nil {
				return nil, fmt.Errorf("GetMetricData AWS/RDS %s=%s: %w", dimName, dimValue, err)
			}
			for _, r := range res.MetricDataResults {
				var i int
				if _, err := fmt.Sscanf(aws.ToString(r.Id), "m%d", &i); err != nil || i < 0 || i >= len(metrics) {
					continue
				}
				m := metrics[i]
				for j := range r.Values {
					if j >= len(r.Timestamps) {
						break
					}
					rows = append(rows, Row{"kind": "metric", "source": source, "dim": dimValue, "metric": m.name, "stat": m.stat,
						"unit": m.unit, "at": r.Timestamps[j].UTC(), "value": r.Values[j]})
				}
			}
			if aws.ToString(res.NextToken) == "" {
				break
			}
			in.NextToken = res.NextToken
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i]["metric"] != rows[j]["metric"] {
			return rows[i]["metric"].(string) < rows[j]["metric"].(string)
		}
		return rows[i]["at"].(time.Time).Before(rows[j]["at"].(time.Time))
	})
	return rows, nil
}
