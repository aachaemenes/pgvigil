package collect

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	dms "github.com/aws/aws-sdk-go-v2/service/databasemigrationservice"
	dmstypes "github.com/aws/aws-sdk-go-v2/service/databasemigrationservice/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// dmsCollector reads the AWS DMS replication tasks an instance's aws.dms block names (the tasks
// that feed this instance or read from it): state and progress from DescribeReplicationTasks,
// per-table counts and validation from DescribeTableStatistics, the replication instances the
// tasks run on, and the CloudWatch latency and host metrics. Nothing is written to DMS: the
// start, stop and resume actions are a later, separately authorised feature.
type dmsCollector struct{}

func init() { Register(dmsCollector{}) }

const (
	dmsMetricWindow = 15 * time.Minute // CloudWatch is read this far back; the newest datapoint is kept
	dmsMaxTables    = 10000            // table statistics rows read per task
	dmsMetricBatch  = 100              // GetMetricData queries per call (the API takes up to 500)
	dmsTextMax      = 2000             // a failure message or a validation detail is cut here
)

func (dmsCollector) Name() string                         { return "dms" }
func (dmsCollector) DefaultInterval() time.Duration       { return time.Minute }
func (dmsCollector) Applies(platform.Info) (bool, string) { return true, "" }

// Configured: the collection runs only on an instance whose aws.dms.tasks names something.
func (dmsCollector) Configured(in config.Instance) (bool, string) {
	if in.AWS == nil || in.AWS.DMS == nil || len(in.AWS.DMS.Tasks) == 0 {
		return false, "no aws.dms.tasks in the config"
	}
	return true, ""
}

func (dmsCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("dms needs the instance config: %w", ErrSkip)
}

// dmsAPI is the slice of the DMS and CloudWatch clients the collector calls; a recorded set in tests.
type dmsAPI interface {
	dms.DescribeReplicationTasksAPIClient
	dms.DescribeTableStatisticsAPIClient
	dms.DescribeReplicationInstancesAPIClient
	cloudwatch.GetMetricDataAPIClient
}

// awsDMS joins the two SDK clients behind dmsAPI.
type awsDMS struct {
	*dms.Client
	cw *cloudwatch.Client
}

func (c awsDMS) GetMetricData(ctx context.Context, in *cloudwatch.GetMetricDataInput, opts ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricDataOutput, error) {
	return c.cw.GetMetricData(ctx, in, opts...)
}

// dmsClients keeps one client pair per profile and region across runs.
var (
	dmsClientsMu sync.Mutex
	dmsClients   = map[string]dmsAPI{}
)

var newDMSAPI = func(ctx context.Context, a config.AWS) (dmsAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return awsDMS{Client: dms.NewFromConfig(cfg), cw: cloudwatch.NewFromConfig(cfg)}, nil
}

func dmsClientFor(ctx context.Context, a config.AWS) (dmsAPI, error) {
	k := a.Profile + "|" + a.Region
	dmsClientsMu.Lock()
	defer dmsClientsMu.Unlock()
	if c, ok := dmsClients[k]; ok {
		return c, nil
	}
	c, err := newDMSAPI(ctx, a)
	if err == nil {
		dmsClients[k] = c
	}
	return c, err
}

func (d dmsCollector) RunInstance(ctx context.Context, _ *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	if ok, why := d.Configured(in); !ok {
		return nil, fmt.Errorf("%s: %w", why, ErrSkip)
	}
	api, err := dmsClientFor(ctx, *in.AWS)
	if err != nil {
		return nil, err
	}
	return dmsRows(ctx, api, *in.AWS.DMS, time.Now())
}

// dmsRows reads the tasks the config names, their table statistics and replication instances,
// then the CloudWatch metrics, and returns the rows the import function takes: kind 'task',
// 'table' and 'ri', plus a 'collector_error' row when only the metrics could not be read.
func dmsRows(ctx context.Context, api dmsAPI, cfg config.DMS, now time.Time) ([]Row, error) {
	tasks, err := dmsDescribeTasks(ctx, api, cfg.Tasks)
	if err != nil {
		return nil, err
	}
	sort.Slice(tasks, func(i, j int) bool {
		return aws.ToString(tasks[i].ReplicationTaskArn) < aws.ToString(tasks[j].ReplicationTaskArn)
	})

	riArns := map[string]bool{}
	for _, t := range tasks {
		if a := aws.ToString(t.ReplicationInstanceArn); a != "" {
			riArns[a] = true
		}
	}
	ris, err := dmsDescribeInstances(ctx, api, riArns)
	if err != nil {
		return nil, err
	}
	riByArn := map[string]dmstypes.ReplicationInstance{}
	for _, r := range ris {
		riByArn[aws.ToString(r.ReplicationInstanceArn)] = r
	}

	var rows []Row
	for _, t := range tasks {
		arn := aws.ToString(t.ReplicationTaskArn)
		stats, err := dmsDescribeTables(ctx, api, arn)
		if err != nil {
			return nil, err
		}
		for _, s := range stats {
			rows = append(rows, dmsTableRow(arn, s))
		}
	}

	metrics, merr := dmsMetrics(ctx, api, tasks, riByArn, now)
	for _, t := range tasks {
		rows = append(rows, dmsTaskRow(t, metrics, cfg.LatencyWarn()))
	}
	for _, r := range ris {
		rows = append(rows, dmsInstanceRow(r, metrics))
	}
	if merr != nil {
		rows = append(rows, Row{"kind": "collector_error", "source": "cloudwatch:AWS/DMS", "message": merr.Error()})
	}
	return rows, nil
}

// dmsNotFound is true for the fault DMS raises when a filtered describe matches nothing
// (tasks, instances and table statistics; subnet groups answer an empty list instead).
func dmsNotFound(err error) bool {
	var nf *dmstypes.ResourceNotFoundFault
	return errors.As(err, &nf)
}

// dmsDescribeTasks returns the tasks named by identifier or ARN, or every task for "*".
func dmsDescribeTasks(ctx context.Context, api dmsAPI, names []string) ([]dmstypes.ReplicationTask, error) {
	var ids, arns []string
	all := false
	for _, n := range names {
		switch {
		case n == "*":
			all = true
		case strings.HasPrefix(n, "arn:"):
			arns = append(arns, n)
		default:
			ids = append(ids, n)
		}
	}
	var filters [][]dmstypes.Filter
	switch {
	case all:
		filters = append(filters, nil)
	default:
		// one describe per filter kind: DMS ANDs the filters of a call
		if len(ids) > 0 {
			filters = append(filters, []dmstypes.Filter{{Name: aws.String("replication-task-id"), Values: ids}})
		}
		if len(arns) > 0 {
			filters = append(filters, []dmstypes.Filter{{Name: aws.String("replication-task-arn"), Values: arns}})
		}
	}
	seen := map[string]bool{}
	var out []dmstypes.ReplicationTask
	for _, f := range filters {
		p := dms.NewDescribeReplicationTasksPaginator(api, &dms.DescribeReplicationTasksInput{Filters: f, WithoutSettings: aws.Bool(true)})
		for p.HasMorePages() {
			page, err := p.NextPage(ctx)
			if err != nil {
				if dmsNotFound(err) {
					break
				}
				return nil, fmt.Errorf("DescribeReplicationTasks: %w", err)
			}
			for _, t := range page.ReplicationTasks {
				if a := aws.ToString(t.ReplicationTaskArn); !seen[a] {
					seen[a] = true
					out = append(out, t)
				}
			}
		}
	}
	return out, nil
}

func dmsDescribeInstances(ctx context.Context, api dmsAPI, arns map[string]bool) ([]dmstypes.ReplicationInstance, error) {
	if len(arns) == 0 {
		return nil, nil
	}
	list := make([]string, 0, len(arns))
	for a := range arns {
		list = append(list, a)
	}
	sort.Strings(list)
	var out []dmstypes.ReplicationInstance
	p := dms.NewDescribeReplicationInstancesPaginator(api, &dms.DescribeReplicationInstancesInput{
		Filters: []dmstypes.Filter{{Name: aws.String("replication-instance-arn"), Values: list}},
	})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			if dmsNotFound(err) {
				break
			}
			return nil, fmt.Errorf("DescribeReplicationInstances: %w", err)
		}
		out = append(out, page.ReplicationInstances...)
	}
	sort.Slice(out, func(i, j int) bool {
		return aws.ToString(out[i].ReplicationInstanceArn) < aws.ToString(out[j].ReplicationInstanceArn)
	})
	return out, nil
}

func dmsDescribeTables(ctx context.Context, api dmsAPI, taskArn string) ([]dmstypes.TableStatistics, error) {
	var out []dmstypes.TableStatistics
	p := dms.NewDescribeTableStatisticsPaginator(api, &dms.DescribeTableStatisticsInput{ReplicationTaskArn: aws.String(taskArn)})
	for p.HasMorePages() && len(out) < dmsMaxTables {
		page, err := p.NextPage(ctx)
		if err != nil {
			if dmsNotFound(err) {
				break // a task that never started has no statistics yet
			}
			return nil, fmt.Errorf("DescribeTableStatistics %s: %w", taskArn, err)
		}
		out = append(out, page.TableStatistics...)
	}
	return out, nil
}

// dmsMetric is one CloudWatch datapoint keyed by metric name and dimension values.
type dmsMetric struct {
	Value float64
	At    time.Time
}

// dmsMetricKey names a series: the metric and its dimensions, in the DMS namespace's order.
func dmsMetricKey(metric string, dims ...string) string {
	return metric + "|" + strings.Join(dims, "|")
}

// dmsResourceID is the identifier DMS uses as a CloudWatch dimension: the tail of the ARN.
func dmsResourceID(arn string) string {
	if i := strings.LastIndex(arn, ":"); i >= 0 {
		return arn[i+1:]
	}
	return arn
}

// task metrics (Maximum over the period) and host metrics (the stat named) read per run
var (
	dmsTaskMetrics = []string{"CDCLatencySource", "CDCLatencyTarget", "CDCIncomingChanges"}
	dmsHostMetrics = []struct{ name, stat string }{
		{"CPUUtilization", "Average"}, {"FreeableMemory", "Minimum"}, {"FreeStorageSpace", "Minimum"}, {"SwapUsage", "Maximum"},
	}
)

// dmsMetrics reads the newest datapoint of every task and host metric in one GetMetricData round
// (batched). DMS publishes a task metric under ReplicationInstanceIdentifier (the instance's name) plus
// ReplicationTaskIdentifier = the task's resource id (the tail of its ARN, not the user-assigned name), and
// a host metric under ReplicationInstanceExternalResourceId = the tail of the instance's ARN (list-metrics
// on a live instance, 2026-11-09).
func dmsMetrics(ctx context.Context, api dmsAPI, tasks []dmstypes.ReplicationTask, ris map[string]dmstypes.ReplicationInstance, now time.Time) (map[string]dmsMetric, error) {
	var queries []cwtypes.MetricDataQuery
	keys := map[string]string{} // query id -> metric key
	add := func(id, metric, stat string, dims map[string]string) {
		var dl []cwtypes.Dimension
		names := make([]string, 0, len(dims))
		for n := range dims {
			names = append(names, n)
		}
		sort.Strings(names)
		vals := make([]string, 0, len(names))
		for _, n := range names {
			dl = append(dl, cwtypes.Dimension{Name: aws.String(n), Value: aws.String(dims[n])})
			vals = append(vals, dims[n])
		}
		keys[id] = dmsMetricKey(metric, vals...)
		queries = append(queries, cwtypes.MetricDataQuery{
			Id: aws.String(id),
			MetricStat: &cwtypes.MetricStat{
				Metric: &cwtypes.Metric{Namespace: aws.String("AWS/DMS"), MetricName: aws.String(metric), Dimensions: dl},
				Period: aws.Int32(60), Stat: aws.String(stat),
			},
		})
	}
	for i, t := range tasks {
		ri, ok := ris[aws.ToString(t.ReplicationInstanceArn)]
		if !ok {
			continue
		}
		dims := map[string]string{
			"ReplicationInstanceIdentifier": aws.ToString(ri.ReplicationInstanceIdentifier),
			"ReplicationTaskIdentifier":     dmsResourceID(aws.ToString(t.ReplicationTaskArn)),
		}
		for j, m := range dmsTaskMetrics {
			add(fmt.Sprintf("t%d_%d", i, j), m, "Maximum", dims)
		}
	}
	i := 0
	for _, ri := range ris {
		dims := map[string]string{"ReplicationInstanceExternalResourceId": dmsResourceID(aws.ToString(ri.ReplicationInstanceArn))}
		for j, m := range dmsHostMetrics {
			add(fmt.Sprintf("r%d_%d", i, j), m.name, m.stat, dims)
		}
		i++
	}
	out := map[string]dmsMetric{}
	for start := 0; start < len(queries); start += dmsMetricBatch {
		end := min(start+dmsMetricBatch, len(queries))
		in := &cloudwatch.GetMetricDataInput{
			StartTime: aws.Time(now.Add(-dmsMetricWindow)), EndTime: aws.Time(now),
			MetricDataQueries: queries[start:end], ScanBy: cwtypes.ScanByTimestampDescending,
		}
		for {
			res, err := api.GetMetricData(ctx, in)
			if err != nil {
				return out, fmt.Errorf("GetMetricData: %w", err)
			}
			for _, r := range res.MetricDataResults {
				if len(r.Values) == 0 || len(r.Timestamps) == 0 {
					continue
				}
				k := keys[aws.ToString(r.Id)]
				if cur, ok := out[k]; !ok || r.Timestamps[0].After(cur.At) {
					out[k] = dmsMetric{Value: r.Values[0], At: r.Timestamps[0]}
				}
			}
			if aws.ToString(res.NextToken) == "" {
				break
			}
			in.NextToken = res.NextToken
		}
	}
	return out, nil
}

func dmsTaskRow(t dmstypes.ReplicationTask, m map[string]dmsMetric, latencyWarn int) Row {
	row := Row{
		"kind": "task", "task_arn": aws.ToString(t.ReplicationTaskArn), "task_id": aws.ToString(t.ReplicationTaskIdentifier),
		"ri_arn": nilIfEmpty(aws.ToString(t.ReplicationInstanceArn)), "migration_type": string(t.MigrationType),
		"status": strings.ToLower(aws.ToString(t.Status)), "stop_reason": nilIfEmpty(aws.ToString(t.StopReason)),
		"last_failure": nilIfEmpty(dmsText(aws.ToString(t.LastFailureMessage))),
		"created":      tsOrNil(t.ReplicationTaskCreationDate), "started": tsOrNil(t.ReplicationTaskStartDate),
		"cdc_start_position": nilIfEmpty(aws.ToString(t.CdcStartPosition)), "recovery_checkpoint": nilIfEmpty(aws.ToString(t.RecoveryCheckpoint)),
		"source_endpoint_arn": nilIfEmpty(aws.ToString(t.SourceEndpointArn)), "target_endpoint_arn": nilIfEmpty(aws.ToString(t.TargetEndpointArn)),
		"latency_warn_secs": latencyWarn,
	}
	if s := t.ReplicationTaskStats; s != nil {
		row["progress_pct"] = s.FullLoadProgressPercent
		row["tables_loaded"], row["tables_loading"], row["tables_queued"], row["tables_errored"] = s.TablesLoaded, s.TablesLoading, s.TablesQueued, s.TablesErrored
		row["elapsed_ms"] = s.ElapsedTimeMillis
		row["fresh_start"], row["start_date"], row["stop_date"] = tsOrNil(s.FreshStartDate), tsOrNil(s.StartDate), tsOrNil(s.StopDate)
		row["full_load_start"], row["full_load_finish"] = tsOrNil(s.FullLoadStartDate), tsOrNil(s.FullLoadFinishDate)
	}
	// the metric keys were built with sorted dimension names: instance identifier, then task id
	for _, mt := range []struct{ metric, col string }{{"CDCLatencySource", "latency_source_s"}, {"CDCLatencyTarget", "latency_target_s"}, {"CDCIncomingChanges", "incoming_changes"}} {
		for k, v := range m {
			if strings.HasPrefix(k, mt.metric+"|") && strings.HasSuffix(k, "|"+dmsResourceID(aws.ToString(t.ReplicationTaskArn))) {
				row[mt.col] = v.Value
				if at, ok := row["latency_at"].(time.Time); !ok || v.At.After(at) {
					row["latency_at"] = v.At.UTC()
				}
			}
		}
	}
	return row
}

func dmsTableRow(taskArn string, s dmstypes.TableStatistics) Row {
	return Row{
		"kind": "table", "task_arn": taskArn, "schema_name": aws.ToString(s.SchemaName), "table_name": aws.ToString(s.TableName),
		"table_state": nilIfEmpty(aws.ToString(s.TableState)),
		"inserts":     s.Inserts, "updates": s.Updates, "deletes": s.Deletes, "ddls": s.Ddls,
		"applied_inserts": s.AppliedInserts, "applied_updates": s.AppliedUpdates, "applied_deletes": s.AppliedDeletes, "applied_ddls": s.AppliedDdls,
		"full_load_rows": s.FullLoadRows, "full_load_error_rows": s.FullLoadErrorRows, "full_load_cond_failed_rows": s.FullLoadCondtnlChkFailedRows,
		"full_load_reloaded": s.FullLoadReloaded, "full_load_start": tsOrNil(s.FullLoadStartTime), "full_load_end": tsOrNil(s.FullLoadEndTime),
		"last_update":      tsOrNil(s.LastUpdateTime),
		"validation_state": nilIfEmpty(aws.ToString(s.ValidationState)), "validation_pending": s.ValidationPendingRecords,
		"validation_failed": s.ValidationFailedRecords, "validation_suspended": s.ValidationSuspendedRecords,
		"validation_detail": nilIfEmpty(dmsText(aws.ToString(s.ValidationStateDetails))),
	}
}

func dmsInstanceRow(r dmstypes.ReplicationInstance, m map[string]dmsMetric) Row {
	id := aws.ToString(r.ReplicationInstanceIdentifier)
	row := Row{
		"kind": "ri", "ri_arn": aws.ToString(r.ReplicationInstanceArn), "ri_id": id,
		"status": nilIfEmpty(aws.ToString(r.ReplicationInstanceStatus)), "class": nilIfEmpty(aws.ToString(r.ReplicationInstanceClass)),
		"engine_version": nilIfEmpty(aws.ToString(r.EngineVersion)), "allocated_gb": r.AllocatedStorage,
		"multi_az": r.MultiAZ, "public": r.PubliclyAccessible, "az": nilIfEmpty(aws.ToString(r.AvailabilityZone)),
		"created": tsOrNil(r.InstanceCreateTime), "free_until": tsOrNil(r.FreeUntil), "pending": dmsPending(r.PendingModifiedValues),
	}
	rid := dmsResourceID(aws.ToString(r.ReplicationInstanceArn))
	for _, mt := range []struct{ metric, col string }{{"CPUUtilization", "cpu_pct"}, {"FreeableMemory", "freeable_bytes"}, {"FreeStorageSpace", "free_storage_bytes"}, {"SwapUsage", "swap_bytes"}} {
		if v, ok := m[dmsMetricKey(mt.metric, rid)]; ok {
			row[mt.col] = v.Value
		}
	}
	return row
}

// dmsPending returns the pending modifications as a small map, or nil when there are none.
func dmsPending(p *dmstypes.ReplicationPendingModifiedValues) any {
	if p == nil {
		return nil
	}
	out := map[string]any{}
	if p.AllocatedStorage != nil {
		out["allocated_gb"] = *p.AllocatedStorage
	}
	if p.EngineVersion != nil {
		out["engine_version"] = *p.EngineVersion
	}
	if p.MultiAZ != nil {
		out["multi_az"] = *p.MultiAZ
	}
	if p.ReplicationInstanceClass != nil {
		out["class"] = *p.ReplicationInstanceClass
	}
	if p.NetworkType != nil {
		out["network_type"] = *p.NetworkType
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// dmsText masks credentials in text DMS reports (a failure message can quote a connection string) and caps it.
func dmsText(s string) string {
	s = maskText(s)
	if len(s) > dmsTextMax {
		s = strings.ToValidUTF8(s[:dmsTextMax], "")
	}
	return s
}

func tsOrNil(t *time.Time) any {
	if t == nil || t.IsZero() {
		return nil
	}
	return t.UTC()
}
