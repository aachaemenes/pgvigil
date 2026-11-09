package collect

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// recordedCW answers GetMetricData from a list of datapoints in the recordedMetric shape (testdata/io):
// aurora-lab.json is the lab cluster's answer, recorded 2026-11-09 while it was paused (only the cluster
// volume's IO counters publish then); dms-ri-synthetic.json is a made-up IO-bound replication instance (the
// lab's plan has no DMS instance to record from).
type recordedCW struct {
	metrics []recordedMetric
	queries []cwtypes.MetricDataQuery
	windows map[string]time.Duration
	onCall  func(*cloudwatch.GetMetricDataInput)
}

// auroraRecordedNow is the read time the recorded Aurora answer is replayed at: 31 minutes after its newest
// datapoint, the lag the lab cluster's volume counters showed (newest 10:54 at 11:24 PST, 2026-11-09).
func auroraRecordedNow(t *testing.T, ms []recordedMetric) time.Time {
	t.Helper()
	var newest time.Time
	for _, m := range ms {
		if m.At.After(newest) {
			newest = m.At
		}
	}
	if newest.IsZero() {
		t.Fatal("no recorded datapoint")
	}
	return newest.Add(31 * time.Minute)
}

func loadRecordedMetrics(t *testing.T, name string) []recordedMetric {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "io", name))
	if err != nil {
		t.Fatal(err)
	}
	var out []recordedMetric
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// GetMetricData answers each query with the recorded datapoints of its metric and dimensions INSIDE the call's
// time window, as CloudWatch does; windows records each call's span per metric.
func (r *recordedCW) GetMetricData(_ context.Context, in *cloudwatch.GetMetricDataInput, _ ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricDataOutput, error) {
	r.queries = append(r.queries, in.MetricDataQueries...)
	if r.onCall != nil {
		r.onCall(in)
	}
	if r.windows == nil {
		r.windows = map[string]time.Duration{}
	}
	for _, q := range in.MetricDataQueries {
		r.windows[aws.ToString(q.MetricStat.Metric.MetricName)] = aws.ToTime(in.EndTime).Sub(aws.ToTime(in.StartTime))
	}
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
			if match && !m.At.Before(aws.ToTime(in.StartTime)) && m.At.Before(aws.ToTime(in.EndTime)) {
				res.Values = append(res.Values, m.Value)
				res.Timestamps = append(res.Timestamps, m.At)
			}
		}
		out.MetricDataResults = append(out.MetricDataResults, res)
	}
	return out, nil
}

func TestIORowsAuroraRecorded(t *testing.T) {
	api := &recordedCW{metrics: loadRecordedMetrics(t, "aurora-lab.json")}
	now := auroraRecordedNow(t, api.metrics)
	rows, err := ioRows(context.Background(), api, platform.Aurora, config.AWS{Cluster: "dba-lab-pg"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(api.queries) != len(ioCommon)+len(ioAurora) {
		t.Errorf("queries %d, want %d", len(api.queries), len(ioCommon)+len(ioAurora))
	}
	for _, q := range api.queries {
		d := q.MetricStat.Metric.Dimensions
		if len(d) != 1 || aws.ToString(d[0].Name) != "DBClusterIdentifier" || aws.ToString(d[0].Value) != "dba-lab-pg" {
			t.Fatalf("query %s dimensions %v, want DBClusterIdentifier=dba-lab-pg", aws.ToString(q.MetricStat.Metric.MetricName), d)
		}
		if aws.ToInt32(q.MetricStat.Period) != ioPeriod || aws.ToString(q.MetricStat.Metric.Namespace) != "AWS/RDS" {
			t.Errorf("query %s period %d namespace %s", aws.ToString(q.MetricStat.Metric.MetricName), aws.ToInt32(q.MetricStat.Period), aws.ToString(q.MetricStat.Metric.Namespace))
		}
	}
	n := map[string]int{}
	for _, r := range rows {
		n[r["metric"].(string)]++
		if r["kind"] != "metric" || r["source"] != "aurora" || r["dim"] != "dba-lab-pg" {
			t.Fatalf("row %v", r)
		}
		if r["metric"] == "VolumeReadIOPs" && r["unit"] != "count/5min" {
			t.Errorf("VolumeReadIOPs unit %v", r["unit"])
		}
	}
	// the volume counters arrive about 30 minutes late: a read window that does not reach back past that lag
	// never stores one (the live proof's first failure, 2026-11-09)
	if n["VolumeReadIOPs"] < 1 || n["VolumeWriteIOPs"] < 1 {
		t.Errorf("volume datapoints %v: none inside the read window (window %v)", n, api.windows["VolumeReadIOPs"])
	}
	if n["AuroraVolumeBytesLeftTotal"] != 0 {
		t.Errorf("AuroraVolumeBytesLeftTotal rows %d: no datapoint was recorded, none may be invented", n["AuroraVolumeBytesLeftTotal"])
	}
	// datapoints come out ordered by metric then time, ready for the import
	for i := 1; i < len(rows); i++ {
		a, b := rows[i-1], rows[i]
		if a["metric"] == b["metric"] && !a["at"].(time.Time).Before(b["at"].(time.Time)) {
			t.Fatalf("rows not in time order at %d", i)
		}
	}
	if _, err := json.Marshal(rows); err != nil {
		t.Fatal(err)
	}
}

func TestIOTargets(t *testing.T) {
	for _, c := range []struct {
		kind             platform.Kind
		aws              config.AWS
		dim, val, source string
		has              string
		n                int
	}{
		{platform.RDS, config.AWS{DBInstance: "db1"}, "DBInstanceIdentifier", "db1", "rds", "EBSIOBalance%", len(ioCommon) + len(ioRDS)},
		{platform.Aurora, config.AWS{Cluster: "c1", DBInstance: "c1-i1"}, "DBClusterIdentifier", "c1", "aurora", "VolumeReadIOPs", len(ioCommon) + len(ioAurora)},
		{platform.Aurora, config.AWS{DBInstance: "c1-i1"}, "DBInstanceIdentifier", "c1-i1", "aurora", "StorageNetworkThroughput", len(ioCommon) + len(ioAurora)},
	} {
		dim, val, src, ms := ioTarget(c.kind, c.aws)
		found := false
		for _, m := range ms {
			found = found || m.name == c.has
		}
		if dim != c.dim || val != c.val || src != c.source || len(ms) != c.n || !found {
			t.Errorf("%s %+v: %s=%s %s, %d metrics (has %s: %v)", c.kind, c.aws, dim, val, src, len(ms), c.has, found)
		}
	}
	// an RDS instance with only a cluster named (a Multi-AZ DB cluster) has no instance to read: a skip, not an error
	if _, err := ioRows(context.Background(), &recordedCW{}, platform.RDS, config.AWS{Cluster: "x"}, time.Now()); !errors.Is(err, ErrSkip) {
		t.Errorf("rds without db_instance: %v, want a skip", err)
	}
}

func TestIOGateAndApplies(t *testing.T) {
	c := ioCollector{}
	if ok, _ := c.Configured(config.Instance{}); ok {
		t.Error("no aws block: configured")
	}
	if ok, _ := c.Configured(config.Instance{AWS: &config.AWS{DMS: &config.DMS{Tasks: []string{"t"}}}}); ok {
		t.Error("aws block without cluster or db_instance: configured")
	}
	if ok, _ := c.Configured(config.Instance{AWS: &config.AWS{Cluster: "c"}}); !ok {
		t.Error("cluster named: not configured")
	}
	if ok, _ := c.Applies(platform.Info{Kind: platform.OnPrem}); ok {
		t.Error("onprem: applies")
	}
	if ok, _ := c.Applies(platform.Info{Kind: platform.RDS}); !ok {
		t.Error("rds: does not apply")
	}
}

// TestDmsIOMetrics: the replication instance row carries the IO and network metrics read under the host
// metrics' dimension, in the AWS/DMS units (latency in milliseconds), and dates them.
func TestDmsIOMetrics(t *testing.T) {
	api := newRecordedDMS(t)
	api.metrics = append(api.metrics, loadRecordedMetrics(t, "dms-ri-synthetic.json")...)
	rows, err := dmsRows(context.Background(), api, config.DMS{Tasks: []string{"dmslab-task"}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	ri := byKind(rows)["ri"]
	if len(ri) != 1 {
		t.Fatalf("ri rows %d", len(ri))
	}
	want := map[string]float64{"read_iops": 95, "write_iops": 2900, "read_latency_ms": 4.1, "write_latency_ms": 38.5,
		"read_bytes_s": 1258291.2, "write_bytes_s": 48234496, "queue_depth": 31, "net_tx_bytes_s": 5242880,
		"net_rx_bytes_s": 23068672, "free_storage_bytes": 6442450944}
	for k, v := range want {
		if got, _ := ri[0][k].(float64); got != v {
			t.Errorf("%s = %v, want %v", k, ri[0][k], v)
		}
	}
	if _, ok := ri[0]["metrics_at"].(time.Time); !ok {
		t.Errorf("metrics_at missing: %v", ri[0]["metrics_at"])
	}
}

// TestIOFixtureImport fills a repository (PGVIGIL_REPO_DSN; skipped without it): the recorded Aurora datapoints
// land once however often the window is read, a revised value replaces the stored one, and the DMS instance's
// IO lands on dms_instances with one dms_ri_sample row per import.
func TestIOFixtureImport(t *testing.T) {
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
	name := "io-fixture-" + time.Now().UTC().Format("150405.000")
	id, err := r.EnsureInstance(ctx, name, "aurora", "fixture", 170009, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	defer func() { _, _ = conn.Exec(ctx, `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id) }()
	count := func(sql string) int64 {
		var n int64
		if err := conn.QueryRow(ctx, sql, id).Scan(&n); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return n
	}

	rec := loadRecordedMetrics(t, "aurora-lab.json")
	io, err := ioRows(ctx, &recordedCW{metrics: rec}, platform.Aurora, config.AWS{Cluster: "dba-lab-pg"}, auroraRecordedNow(t, rec))
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC()
	for i := 0; i < 2; i++ {
		if err := r.Import(ctx, id, "io", at.Add(time.Duration(i)*5*time.Minute), io); err != nil {
			t.Fatal(err)
		}
	}
	if n := count(`SELECT count(*) FROM pgvigil.cloud_io_sample WHERE instance_id = $1`); n != int64(len(io)) {
		t.Errorf("cloud_io_sample rows %d after two reads of one window, want %d (one per metric and datapoint)", n, len(io))
	}
	// CloudWatch revises the newest period as late samples arrive: a re-read replaces the value
	last := Row{}
	for k, v := range io[len(io)-1] {
		last[k] = v
	}
	last["value"] = 42.0
	if err := r.Import(ctx, id, "io", at.Add(10*time.Minute), []Row{last}); err != nil {
		t.Fatal(err)
	}
	if n := count(`SELECT count(*) FROM pgvigil.cloud_io_sample WHERE instance_id = $1 AND value = 42`); n != 1 {
		t.Errorf("revised datapoint rows %d, want 1", n)
	}

	api := newRecordedDMS(t)
	api.metrics = append(api.metrics, loadRecordedMetrics(t, "dms-ri-synthetic.json")...)
	dmsRowsIO, err := dmsRows(ctx, api, config.DMS{Tasks: []string{"dmslab-task"}}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := r.Import(ctx, id, "dms", at.Add(time.Duration(i)*time.Minute), dmsRowsIO); err != nil {
			t.Fatal(err)
		}
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_instances WHERE instance_id = $1 AND queue_depth = 31 AND write_latency_ms = 38.5`); n != 1 {
		t.Errorf("dms_instances IO row %d, want 1", n)
	}
	if n := count(`SELECT count(*) FROM pgvigil.dms_ri_sample WHERE instance_id = $1`); n != 2 {
		t.Errorf("dms_ri_sample rows %d, want 2 (one per import)", n)
	}
}

// TestIOWindowAlignedToPeriod: CloudWatch lays a request's periods from its StartTime (to the minute), so two
// reads started at different minutes return one 5-minute span under different timestamps and the import's key
// (metric, datapoint time) never matches: every run would add overlapping rows (the live proof, 2026-11-09:
// 19 then 36 VolumeReadIOPs rows with the same newest point). Every request starts on a period boundary.
func TestIOWindowAlignedToPeriod(t *testing.T) {
	for _, now := range []time.Time{
		time.Date(2026, 11, 9, 19, 32, 13, 0, time.UTC), time.Date(2026, 11, 9, 19, 34, 59, 0, time.UTC),
	} {
		api := &recordedCW{}
		starts := map[time.Time]bool{}
		api.onCall = func(in *cloudwatch.GetMetricDataInput) { starts[aws.ToTime(in.StartTime)] = true }
		if _, err := ioRows(context.Background(), api, platform.Aurora, config.AWS{Cluster: "c"}, now); err != nil {
			t.Fatal(err)
		}
		if len(starts) == 0 {
			t.Fatal("no request")
		}
		for s := range starts {
			if s.Unix()%ioPeriod != 0 {
				t.Errorf("now %s: StartTime %s is not on a %d-second boundary", now.Format(time.TimeOnly), s.Format(time.TimeOnly), ioPeriod)
			}
		}
	}
}
