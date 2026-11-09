package collect

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	dms "github.com/aws/aws-sdk-go-v2/service/databasemigrationservice"
	dmstypes "github.com/aws/aws-sdk-go-v2/service/databasemigrationservice/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// recordedDMS answers the four calls from the responses recorded in testdata/dms (the AWS CLI's JSON,
// which unmarshals into the SDK output types by field name): tasks.json, instances.json,
// tables-<task resource id>.json, and metrics.json as [{metric, dims{name: value}, value, at}].
type recordedDMS struct {
	dir     string
	t       *testing.T
	metrics []recordedMetric
	calls   map[string]int
}

type recordedMetric struct {
	Metric string            `json:"metric"`
	Dims   map[string]string `json:"dims"`
	Value  float64           `json:"value"`
	At     time.Time         `json:"at"`
}

func newRecordedDMS(t *testing.T) *recordedDMS {
	t.Helper()
	r := &recordedDMS{dir: filepath.Join("testdata", "dms"), t: t, calls: map[string]int{}}
	raw, err := os.ReadFile(filepath.Join(r.dir, "metrics.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &r.metrics); err != nil {
		t.Fatal(err)
	}
	return r
}

func (r *recordedDMS) load(name string, into any) error {
	r.calls[name]++
	raw, err := os.ReadFile(filepath.Join(r.dir, name))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &dmstypes.ResourceNotFoundFault{Message: aws.String("recorded: no " + name)}
		}
		return err
	}
	return json.Unmarshal(raw, into)
}

func (r *recordedDMS) DescribeReplicationTasks(_ context.Context, in *dms.DescribeReplicationTasksInput, _ ...func(*dms.Options)) (*dms.DescribeReplicationTasksOutput, error) {
	var out dms.DescribeReplicationTasksOutput
	if err := r.load("tasks.json", &out); err != nil {
		return nil, err
	}
	if len(in.Filters) == 0 {
		return &out, nil
	}
	// the recorded set filtered the way the API would: by identifier or by ARN
	var keep []dmstypes.ReplicationTask
	for _, t := range out.ReplicationTasks {
		for _, f := range in.Filters {
			for _, v := range f.Values {
				if (aws.ToString(f.Name) == "replication-task-id" && v == aws.ToString(t.ReplicationTaskIdentifier)) ||
					(aws.ToString(f.Name) == "replication-task-arn" && v == aws.ToString(t.ReplicationTaskArn)) {
					keep = append(keep, t)
				}
			}
		}
	}
	if len(keep) == 0 {
		return nil, &dmstypes.ResourceNotFoundFault{Message: aws.String("no task matches")}
	}
	out.ReplicationTasks = keep
	return &out, nil
}

func (r *recordedDMS) DescribeTableStatistics(_ context.Context, in *dms.DescribeTableStatisticsInput, _ ...func(*dms.Options)) (*dms.DescribeTableStatisticsOutput, error) {
	var out dms.DescribeTableStatisticsOutput
	if err := r.load("tables-"+dmsResourceID(aws.ToString(in.ReplicationTaskArn))+".json", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (r *recordedDMS) DescribeReplicationInstances(_ context.Context, _ *dms.DescribeReplicationInstancesInput, _ ...func(*dms.Options)) (*dms.DescribeReplicationInstancesOutput, error) {
	var out dms.DescribeReplicationInstancesOutput
	if err := r.load("instances.json", &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (r *recordedDMS) GetMetricData(_ context.Context, in *cloudwatch.GetMetricDataInput, _ ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricDataOutput, error) {
	r.calls["metrics"]++
	out := &cloudwatch.GetMetricDataOutput{}
	for _, q := range in.MetricDataQueries {
		res := cwtypes.MetricDataResult{Id: q.Id, StatusCode: cwtypes.StatusCodeComplete}
		for _, m := range r.metrics {
			if m.Metric != aws.ToString(q.MetricStat.Metric.MetricName) || len(m.Dims) != len(q.MetricStat.Metric.Dimensions) {
				continue
			}
			match := true
			for _, d := range q.MetricStat.Metric.Dimensions {
				if m.Dims[aws.ToString(d.Name)] != aws.ToString(d.Value) {
					match = false
				}
			}
			if match {
				res.Values = append(res.Values, m.Value)
				res.Timestamps = append(res.Timestamps, m.At)
			}
		}
		out.MetricDataResults = append(out.MetricDataResults, res)
	}
	return out, nil
}

func byKind(rows []Row) map[string][]Row {
	out := map[string][]Row{}
	for _, r := range rows {
		out[r["kind"].(string)] = append(out[r["kind"].(string)], r)
	}
	return out
}

func TestDmsRowsFromRecordedResponses(t *testing.T) {
	api := newRecordedDMS(t)
	rows, err := dmsRows(context.Background(), api, config.DMS{Tasks: []string{"dmslab-task"}, LatencyWarnSecs: 120}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	k := byKind(rows)
	if len(k["task"]) != 1 || len(k["ri"]) != 1 || len(k["table"]) == 0 || len(k["collector_error"]) != 0 {
		t.Fatalf("rows: tasks %d, instances %d, tables %d, errors %d", len(k["task"]), len(k["ri"]), len(k["table"]), len(k["collector_error"]))
	}
	task := k["task"][0]
	if task["task_id"] != "dmslab-task" || task["status"] != "running" || task["migration_type"] != "full-load-and-cdc" {
		t.Errorf("task: %v %v %v", task["task_id"], task["status"], task["migration_type"])
	}
	if task["latency_warn_secs"] != 120 {
		t.Errorf("threshold %v, want 120", task["latency_warn_secs"])
	}
	if _, ok := task["latency_source_s"].(float64); !ok {
		t.Errorf("latency source missing: %v (metric dimensions did not match the recorded set)", task["latency_source_s"])
	}
	if _, ok := task["progress_pct"].(int32); !ok {
		t.Errorf("progress missing: %v", task["progress_pct"])
	}
	ri := k["ri"][0]
	if ri["ri_id"] != "dmslab-ri" || ri["status"] != "available" {
		t.Errorf("replication instance: %v %v", ri["ri_id"], ri["status"])
	}
	if _, ok := ri["cpu_pct"].(float64); !ok {
		t.Errorf("host CPU missing: %v", ri["cpu_pct"])
	}
	var orders Row
	for _, r := range k["table"] {
		if r["schema_name"] == "dbo" && r["table_name"] == "orders" {
			orders = r
		}
	}
	if orders == nil {
		t.Fatalf("no dbo.orders table row in %d rows", len(k["table"]))
	}
	if n, _ := orders["full_load_rows"].(int64); n < 1000 {
		t.Errorf("dbo.orders full_load_rows %v, want >= 1000", orders["full_load_rows"])
	}
	// every row serialises (the import takes JSON) and carries the task ARN
	b, err := json.Marshal(rows)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), aws.ToString(aws.String(task["task_arn"].(string)))) {
		t.Error("task ARN missing from the payload")
	}
}

func TestDmsRowsUnknownTaskIsEmpty(t *testing.T) {
	api := newRecordedDMS(t)
	rows, err := dmsRows(context.Background(), api, config.DMS{Tasks: []string{"no-such-task"}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("%d rows for a task the API does not know, want 0 (ResourceNotFoundFault = empty)", len(rows))
	}
}

func TestDmsConfigGate(t *testing.T) {
	c := dmsCollector{}
	if ok, _ := c.Configured(config.Instance{}); ok {
		t.Error("no aws block should gate the collection off")
	}
	if ok, _ := c.Configured(config.Instance{AWS: &config.AWS{DMS: &config.DMS{}}}); ok {
		t.Error("an empty task list should gate the collection off")
	}
	if ok, _ := c.Configured(config.Instance{AWS: &config.AWS{DMS: &config.DMS{Tasks: []string{"*"}}}}); !ok {
		t.Error("tasks: ['*'] should run")
	}
	if skip, _ := Gated(logsCollector{}, config.Instance{}); !skip {
		t.Error("the log reader without an aws block should be gated off too")
	}
}

// TestDmsFixtureImport fills the repository from the recorded responses (PGVIGIL_REPO_DSN names a
// throwaway repository; skipped without it): the task, its tables and its replication instance land,
// a second import keeps one row per object and adds one more sample, and the checks view reads them.
func TestDmsFixtureImport(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx := context.Background()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	api := newRecordedDMS(t)
	rows, err := dmsRows(ctx, api, config.DMS{Tasks: []string{"dmslab-task"}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	name := "dms-fixture-" + time.Now().UTC().Format("150405.000")
	id, err := r.EnsureInstance(ctx, name, "aurora", "fixture", 170009, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC()
	if err := r.Import(ctx, id, "dms", at, rows); err != nil {
		t.Fatal(err)
	}
	if err := r.Import(ctx, id, "dms", at.Add(time.Minute), rows); err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	count := func(sql string) int64 {
		var n int64
		if err := conn.QueryRow(ctx, sql, id).Scan(&n); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return n
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_tasks WHERE instance_id = $1 AND is_present`); n != 1 {
		t.Errorf("dms_tasks rows %d, want 1 after two imports", n)
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_instances WHERE instance_id = $1 AND is_present`); n != 1 {
		t.Errorf("dms_instances rows %d, want 1", n)
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_table_stats WHERE instance_id = $1 AND schema_name = 'dbo' AND table_name = 'orders' AND full_load_rows >= 1000`); n != 1 {
		t.Errorf("dbo.orders rows %d, want 1 with full_load_rows >= 1000", n)
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_task_sample WHERE instance_id = $1`); n != 2 {
		t.Errorf("dms_task_sample rows %d, want 2 (one per import)", n)
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_checks WHERE instance_id = $1`); n != 0 {
		var detail string
		_ = conn.QueryRow(ctx, `SELECT string_agg(check_name || ': ' || detail, '; ') FROM pgvigil.dms_checks WHERE instance_id = $1`, id).Scan(&detail)
		t.Errorf("a healthy running task raised %d check(s): %s", n, detail)
	}
	// the task gone from the API: its row stays, marked absent, and the tables with it
	if err := r.Import(ctx, id, "dms", at.Add(2*time.Minute), []Row{}); err != nil {
		t.Fatal(err)
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_tasks WHERE instance_id = $1 AND NOT is_present`); n != 1 {
		t.Errorf("after an empty import: absent tasks %d, want 1", n)
	}
	if _, err := conn.Exec(ctx, `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
		t.Logf("cleanup: %v", err)
	}
}
