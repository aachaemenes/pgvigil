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
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// serverlessCollector reads, per Aurora DB instance, the CloudWatch series the Serverless v2 cache rule needs, in
// the IO collection's cadence (every 5 minutes, 5-minute periods, a 20-minute window so a late or missed run loses
// nothing): the capacity in ACU, the ACU utilization, the buffer cache hit ratio, the storage reads and the CPU; and,
// once an hour, the instance's cluster and its Serverless v2 range (the floor and the ceiling). A provisioned Aurora
// instance answers BufferCacheHitRatio, ReadIOPS and CPUUtilization only (no capacity series, no range): the rows are
// kept and the range is stored for a db.serverless instance only (a mixed cluster's range is its Serverless v2
// readers'), so the rule never fires there. A paused Serverless v2 instance (a 0 ACU floor) publishes 0 for
// ServerlessDatabaseCapacity, ACUUtilization and CPUUtilization only (the Aurora User Guide, automatic pause): the
// scaling row's note says so. Read only: one GetMetricData call per run.
type serverlessCollector struct{}

func init() { Register(serverlessCollector{}) }

const (
	serverlessClass  = "db.serverless"  // DBInstanceClass of a Serverless v2 instance
	serverlessPeriod = 300              // seconds per datapoint, as the IO collection reads them
	serverlessWindow = 20 * time.Minute // four periods
)

// serverlessMetrics: the name, the statistic and the unit (the RDS / Aurora metrics reference). The capacity is the
// period's Maximum: "sitting on the floor" means it never rose within the period.
var serverlessMetrics = []struct{ name, stat, unit string }{
	{"ServerlessDatabaseCapacity", "Maximum", "ACU"},
	{"ACUUtilization", "Average", "percent"},
	{"BufferCacheHitRatio", "Average", "percent"},
	{"ReadIOPS", "Average", "count/s"},
	{"CPUUtilization", "Average", "percent"},
}

func (serverlessCollector) Name() string                   { return "serverless" }
func (serverlessCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (serverlessCollector) Applies(info platform.Info) (bool, string) {
	if info.Kind != platform.Aurora {
		return false, "Serverless v2 capacity and the buffer cache hit ratio are Aurora's"
	}
	return true, ""
}

// Configured: the collection runs only on an instance with an aws: block (the CloudWatch door).
func (serverlessCollector) Configured(in config.Instance) (bool, string) {
	if in.AWS == nil {
		return false, "no aws: block in the config"
	}
	return true, ""
}

func (serverlessCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("serverless needs the instance config: %w", ErrSkip)
}

// serverlessAPI is the slice of the CloudWatch and RDS clients the collector calls; a recorded set in a test.
type serverlessAPI interface {
	cloudwatch.GetMetricDataAPIClient
	platform.AWSDescriber
}

type awsServerless struct {
	*rds.Client
	cw *cloudwatch.Client
}

func (c awsServerless) GetMetricData(ctx context.Context, in *cloudwatch.GetMetricDataInput, opts ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricDataOutput, error) {
	return c.cw.GetMetricData(ctx, in, opts...)
}

var (
	serverlessClientsMu sync.Mutex
	serverlessClients   = map[string]serverlessAPI{}
)

var newServerlessAPI = func(ctx context.Context, a config.AWS) (serverlessAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return awsServerless{Client: rds.NewFromConfig(cfg), cw: cloudwatch.NewFromConfig(cfg)}, nil
}

func serverlessClientFor(ctx context.Context, a config.AWS) (serverlessAPI, error) {
	k := a.Profile + "|" + a.Region
	serverlessClientsMu.Lock()
	defer serverlessClientsMu.Unlock()
	if c, ok := serverlessClients[k]; ok {
		return c, nil
	}
	c, err := newServerlessAPI(ctx, a)
	if err == nil {
		serverlessClients[k] = c
	}
	return c, err
}

func (c serverlessCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	if ok, why := c.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	if ok, why := c.Applies(info); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	id, err := hostAWSInstanceID(ctx, conn, info, *in.AWS)
	if err != nil {
		return nil, err
	}
	api, err := serverlessClientFor(ctx, *in.AWS)
	if err != nil {
		return nil, err
	}
	return serverlessRows(ctx, api, in.AWS.Profile+"|"+in.AWS.Region, id, time.Now())
}

// serverlessRows reads the five series of one DB instance over the window (one row per datapoint:
// {kind:'metric', dim, metric, stat, unit, at, value}) and its scaling row {kind:'scaling', db_instance, cluster,
// class, min_acu, max_acu, note}. A failed describe becomes a collector_error row; the metrics still land.
func serverlessRows(ctx context.Context, api serverlessAPI, awsKey, id string, now time.Time) ([]Row, error) {
	var queries []cwtypes.MetricDataQuery
	for i, m := range serverlessMetrics {
		queries = append(queries, cwtypes.MetricDataQuery{
			Id: aws.String(fmt.Sprintf("m%d", i)),
			MetricStat: &cwtypes.MetricStat{
				Metric: &cwtypes.Metric{Namespace: aws.String("AWS/RDS"), MetricName: aws.String(m.name),
					Dimensions: []cwtypes.Dimension{{Name: aws.String("DBInstanceIdentifier"), Value: aws.String(id)}}},
				Period: aws.Int32(serverlessPeriod), Stat: aws.String(m.stat),
			},
		})
	}
	// the start on a period boundary, so every run lays the same periods and the (metric, time) key matches
	in := &cloudwatch.GetMetricDataInput{
		StartTime: aws.Time(now.Add(-serverlessWindow).Truncate(serverlessPeriod * time.Second)), EndTime: aws.Time(now),
		MetricDataQueries: queries, ScanBy: cwtypes.ScanByTimestampAscending,
	}
	var rows []Row
	answered := map[string]bool{}
	capPoints, capHigh := 0, 0.0
	for {
		res, err := api.GetMetricData(ctx, in)
		if err != nil {
			return nil, fmt.Errorf("GetMetricData AWS/RDS DBInstanceIdentifier=%s: %w", id, err)
		}
		for _, r := range res.MetricDataResults {
			var i int
			if _, err := fmt.Sscanf(aws.ToString(r.Id), "m%d", &i); err != nil || i < 0 || i >= len(serverlessMetrics) {
				continue
			}
			m := serverlessMetrics[i]
			for j := range r.Values {
				if j >= len(r.Timestamps) {
					break
				}
				answered[m.name] = true
				if m.name == "ServerlessDatabaseCapacity" {
					capPoints++
					capHigh = max(capHigh, r.Values[j])
				}
				rows = append(rows, Row{"kind": "metric", "dim": id, "metric": m.name, "stat": m.stat, "unit": m.unit,
					"at": r.Timestamps[j].UTC(), "value": r.Values[j]})
			}
		}
		if aws.ToString(res.NextToken) == "" {
			break
		}
		in.NextToken = res.NextToken
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i]["metric"] != rows[j]["metric"] {
			return rows[i]["metric"].(string) < rows[j]["metric"].(string)
		}
		return rows[i]["at"].(time.Time).Before(rows[j]["at"].(time.Time))
	})

	d, err := platform.DescribeAWSInstance(ctx, api, awsKey, id, now)
	if err != nil {
		return append(rows, Row{"kind": "collector_error", "source": "rds", "message": err.Error()}), nil
	}
	sc := Row{"kind": "scaling", "db_instance": id, "cluster": nilIfEmpty(d.Cluster), "class": nilIfEmpty(d.Class)}
	note := d.ScalingNote
	switch {
	case d.Class != serverlessClass:
		// a provisioned instance (a mixed cluster carries a range for its Serverless v2 readers): the range is not its
		note = fmt.Sprintf("a provisioned instance (%s): the cluster's Serverless v2 range does not apply to it", d.Class)
	case d.HasScaling:
		sc["min_acu"], sc["max_acu"] = d.MinACU, d.MaxACU
		// a paused instance publishes 0 for ServerlessDatabaseCapacity, ACUUtilization and CPUUtilization, and nothing else
		if capPoints > 0 && capHigh == 0 {
			note = fmt.Sprintf("paused: ServerlessDatabaseCapacity 0 over the last %s (a paused instance publishes 0 for capacity, ACU and CPU only)", serverlessWindow)
		}
	}
	if len(answered) == 0 {
		note = fmt.Sprintf("no AWS/RDS datapoint for %s over the last %s (stopped, or a wrong identifier)", id, serverlessWindow)
	}
	sc["note"] = nilIfEmpty(note)
	return append(rows, sc), nil
}
