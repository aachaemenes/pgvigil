package collect

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/pi"
	pitypes "github.com/aws/aws-sdk-go-v2/service/pi/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// The PI side is proven from recorded shapes (testdata/pi): the GetResourceMetrics and GetDimensionKeyDetails
// responses in the wire form of the AWS Performance Insights API reference (read 2026-11-09), with synthetic values;
// the lab cluster's Performance Insights is off, so nothing here is proven live.

// wireResourceMetrics is the API reference's GetResourceMetrics response.
type wireResourceMetrics struct {
	Identifier string `json:"Identifier"`
	MetricList []struct {
		Key struct {
			Metric     string            `json:"Metric"`
			Dimensions map[string]string `json:"Dimensions"`
		} `json:"Key"`
		DataPoints []struct {
			Timestamp float64  `json:"Timestamp"`
			Value     *float64 `json:"Value"`
		} `json:"DataPoints"`
	} `json:"MetricList"`
}

// wireKeyDetails is the API reference's GetDimensionKeyDetails response.
type wireKeyDetails struct {
	Dimensions []struct {
		Dimension string `json:"Dimension"`
		Status    string `json:"Status"`
		Value     string `json:"Value"`
	} `json:"Dimensions"`
}

func loadPIFixture(t *testing.T, name string, into any) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "pi", name))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, into); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
}

// recordedPI answers GetResourceMetrics from the recorded MetricList (the series whose dimensions belong to a group
// the call asked for, plus the total, the datapoints inside the call's window), GetDimensionKeyDetails from the
// recorded details, and the RDS describes from fixed answers.
type recordedPI struct {
	metrics    wireResourceMetrics
	details    wireKeyDetails
	db         rdstypes.DBInstance
	cluster    *rdstypes.DBCluster
	rmCalls    []*pi.GetResourceMetricsInput
	keyCalls   []*pi.GetDimensionKeyDetailsInput
	describeDB int
}

func (r *recordedPI) GetResourceMetrics(_ context.Context, in *pi.GetResourceMetricsInput, _ ...func(*pi.Options)) (*pi.GetResourceMetricsOutput, error) {
	r.rmCalls = append(r.rmCalls, in)
	groups := map[string]bool{}
	for _, q := range in.MetricQueries {
		if q.GroupBy != nil {
			groups[aws.ToString(q.GroupBy.Group)] = true
		}
	}
	out := &pi.GetResourceMetricsOutput{Identifier: in.Identifier}
	for _, m := range r.metrics.MetricList {
		keep := len(m.Key.Dimensions) == 0
		for k := range m.Key.Dimensions {
			if g := k[:strings.LastIndex(k, ".")]; groups[g] {
				keep = true
			}
		}
		if !keep {
			continue
		}
		kd := pitypes.MetricKeyDataPoints{Key: &pitypes.ResponseResourceMetricKey{Metric: aws.String(m.Key.Metric), Dimensions: m.Key.Dimensions}}
		for _, p := range m.DataPoints {
			at := time.Unix(int64(p.Timestamp), 0).UTC()
			if at.Before(aws.ToTime(in.StartTime)) || !at.Before(aws.ToTime(in.EndTime)) {
				continue
			}
			kd.DataPoints = append(kd.DataPoints, pitypes.DataPoint{Timestamp: aws.Time(at), Value: p.Value})
		}
		out.MetricList = append(out.MetricList, kd)
	}
	return out, nil
}

func (r *recordedPI) GetDimensionKeyDetails(_ context.Context, in *pi.GetDimensionKeyDetailsInput, _ ...func(*pi.Options)) (*pi.GetDimensionKeyDetailsOutput, error) {
	r.keyCalls = append(r.keyCalls, in)
	out := &pi.GetDimensionKeyDetailsOutput{}
	for _, d := range r.details.Dimensions {
		out.Dimensions = append(out.Dimensions, pitypes.DimensionKeyDetail{Dimension: aws.String(d.Dimension),
			Status: pitypes.DetailStatus(d.Status), Value: aws.String(d.Value)})
	}
	return out, nil
}

func (r *recordedPI) DescribeDBInstances(_ context.Context, _ *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	r.describeDB++
	return &rds.DescribeDBInstancesOutput{DBInstances: []rdstypes.DBInstance{r.db}}, nil
}

func (r *recordedPI) DescribeDBClusters(_ context.Context, _ *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	if r.cluster == nil {
		return &rds.DescribeDBClustersOutput{}, nil
	}
	return &rds.DescribeDBClustersOutput{DBClusters: []rdstypes.DBCluster{*r.cluster}}, nil
}

func newRecordedPI(t *testing.T, enabled bool) *recordedPI {
	t.Helper()
	platform.ForgetAWSInstances()
	piTextMu.Lock()
	piText = map[string]piWhole{}
	piTextMu.Unlock()
	r := &recordedPI{db: rdstypes.DBInstance{DBInstanceIdentifier: aws.String("proof-pi-1"), DbiResourceId: aws.String("db-PROOFRESOURCE0000000001"),
		PerformanceInsightsEnabled: aws.Bool(enabled), PerformanceInsightsRetentionPeriod: aws.Int32(7),
		DBInstanceClass: aws.String("db.serverless"), DBClusterIdentifier: aws.String("proof-cluster")},
		cluster: &rdstypes.DBCluster{ServerlessV2ScalingConfiguration: &rdstypes.ServerlessV2ScalingConfigurationInfo{
			MinCapacity: aws.Float64(0.5), MaxCapacity: aws.Float64(16)}}}
	loadPIFixture(t, "get-resource-metrics.json", &r.metrics)
	loadPIFixture(t, "get-dimension-key-details.json", &r.details)
	return r
}

// piRecordedNow: five minutes past the hour after the recorded three, so the window of complete hours is exactly them.
func piRecordedNow(t *testing.T, r *recordedPI) time.Time {
	t.Helper()
	var newest float64
	for _, m := range r.metrics.MetricList {
		for _, p := range m.DataPoints {
			if p.Timestamp > newest {
				newest = p.Timestamp
			}
		}
	}
	return time.Unix(int64(newest), 0).UTC().Add(65 * time.Minute)
}

func rowsOfKind(rows []Row, kind string) []Row {
	var out []Row
	for _, r := range rows {
		if r["kind"] == kind {
			out = append(out, r)
		}
	}
	return out
}

func TestPIRecordedShape(t *testing.T) {
	api := newRecordedPI(t, true)
	now := piRecordedNow(t, api)
	rows, err := piRows(context.Background(), api, "proof-pi-1", now)
	if err != nil {
		t.Fatal(err)
	}
	// the request: the resource id, hourly START_TIME periods over the last three complete hours, the three groups at 25
	in := api.rmCalls[0]
	if aws.ToString(in.Identifier) != "db-PROOFRESOURCE0000000001" || aws.ToInt32(in.PeriodInSeconds) != 3600 ||
		in.PeriodAlignment != pitypes.PeriodAlignmentStartTime || string(in.ServiceType) != "RDS" {
		t.Errorf("request %+v", in)
	}
	if got := aws.ToTime(in.EndTime).Sub(aws.ToTime(in.StartTime)); got != piHours*time.Hour || aws.ToTime(in.EndTime).Minute() != 0 {
		t.Errorf("window %s ending %s, want %d complete hours", got, aws.ToTime(in.EndTime), piHours)
	}
	var groups []string
	for _, q := range in.MetricQueries {
		if aws.ToString(q.Metric) != "db.load.avg" || aws.ToInt32(q.GroupBy.Limit) != piTop {
			t.Errorf("query %+v", q)
		}
		groups = append(groups, aws.ToString(q.GroupBy.Group))
	}
	if strings.Join(groups, ",") != "db.wait_event,db.sql_tokenized,db.sql" {
		t.Errorf("groups %v", groups)
	}

	st := rowsOfKind(rows, "state")
	if len(st) != 1 || st[0]["enabled"] != true || st[0]["hours_read"] != 3 || st[0]["retention_days"] != 7 {
		t.Fatalf("state %v", st)
	}
	n := map[string]int{}
	for _, r := range rowsOfKind(rows, "load") {
		n[r["group"].(string)]++
	}
	// the total once per hour though three queries returned it; 3 waits and 2 digests a hour; db.sql is not load
	if n["total"] != 3 || n["wait"] != 9 || n["sql"] != 6 || len(n) != 3 {
		t.Errorf("load rows by group %v, want total 3, wait 9, sql 6", n)
	}
	for _, r := range rowsOfKind(rows, "load") {
		if r["group"] == "wait" && r["key"] == "DataFileRead" && r["wait_type"] != "IO" {
			t.Errorf("wait type %v", r)
		}
	}

	sql := map[string]Row{}
	for _, r := range rowsOfKind(rows, "sql") {
		sql[r["tokenized_id"].(string)] = r
	}
	long, short := sql["tok-orders"], sql["tok-accounts"]
	if long == nil || short == nil {
		t.Fatalf("sql rows %v", sql)
	}
	if len(long["query"].(string)) != piTextCut || long["text_status"] != "AVAILABLE" || long["sql_id"] != "sql-orders-a" {
		t.Errorf("cut digest: %d bytes, status %v, sql_id %v (want the heavier db.sql.id sql-orders-a)", len(long["query"].(string)), long["text_status"], long["sql_id"])
	}
	if s, _ := long["statement"].(string); !strings.HasSuffix(s, "LIMIT 50") || len(s) <= piTextCut {
		t.Errorf("whole text %q", s)
	}
	if short["text_status"] != "whole" || short["statement"] != nil || short["db_id"] != "pi-2372568224" {
		t.Errorf("short digest %v", short)
	}
	if len(api.keyCalls) != 1 || aws.ToString(api.keyCalls[0].Group) != "db.sql" || aws.ToString(api.keyCalls[0].GroupIdentifier) != "sql-orders-a" ||
		strings.Join(api.keyCalls[0].RequestedDimensions, ",") != "statement" {
		t.Errorf("GetDimensionKeyDetails calls %+v", api.keyCalls)
	}

	// the next hour: the whole text comes from the process's cache, DescribeDBInstances from its hour's cache
	if _, err := piRows(context.Background(), api, "proof-pi-1", now.Add(30*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if len(api.keyCalls) != 1 || api.describeDB != 1 {
		t.Errorf("second run: %d key-detail calls, %d describes; want 1 and 1 (both cached)", len(api.keyCalls), api.describeDB)
	}
}

func TestPIOff(t *testing.T) {
	api := newRecordedPI(t, false)
	rows, err := piRows(context.Background(), api, "proof-pi-1", piRecordedNow(t, api))
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0]["kind"] != "state" || rows[0]["enabled"] != false || !strings.Contains(rows[0]["note"].(string), "off") {
		t.Fatalf("PI off rows %v", rows)
	}
	if len(api.rmCalls) != 0 {
		t.Errorf("PI off called GetResourceMetrics %d times", len(api.rmCalls))
	}
}

// TestPITextPolicy: the digest and the whole text ride query and statement, so the instance's policy reaches both.
func TestPITextPolicy(t *testing.T) {
	for _, mode := range []string{"full", "normalized", "none"} {
		api := newRecordedPI(t, true)
		rows, err := piRows(context.Background(), api, "proof-pi-1", piRecordedNow(t, api))
		if err != nil {
			t.Fatal(err)
		}
		applyTextPolicy(rows, mode)
		for _, r := range rowsOfKind(rows, "sql") {
			if r["tokenized_id"] != "tok-orders" {
				continue
			}
			s, _ := r["statement"].(string)
			switch mode {
			case "full":
				if !strings.Contains(s, "4711") {
					t.Errorf("full: %q", s)
				}
			case "normalized":
				if s == "" || strings.Contains(s, "4711") || strings.Contains(s, "2025-11-01") || !strings.Contains(s, "LIMIT ?") {
					t.Errorf("normalized: %q", s)
				}
			case "none":
				if r["statement"] != nil || r["query"] != nil {
					t.Errorf("none: %v", r)
				}
			}
		}
	}
}

func TestPIGateAndApplies(t *testing.T) {
	for _, c := range []Collector{piCollector{}, serverlessCollector{}} {
		if ok, _ := c.(ConfigGate).Configured(config.Instance{Name: "no-aws"}); ok {
			t.Errorf("%s runs without an aws: block", c.Name())
		}
		if ok, _ := c.Applies(platform.Info{Kind: platform.OnPrem}); ok {
			t.Errorf("%s applies on-prem", c.Name())
		}
		if ok, _ := c.Applies(platform.Info{Kind: platform.Aurora}); !ok {
			t.Errorf("%s does not apply on Aurora", c.Name())
		}
	}
	if ok, _ := (piCollector{}).Applies(platform.Info{Kind: platform.RDS}); !ok {
		t.Error("pi does not apply on RDS")
	}
	if ok, _ := (serverlessCollector{}).Applies(platform.Info{Kind: platform.RDS}); ok {
		t.Error("serverless applies on RDS (Serverless v2 is Aurora's)")
	}
}

// recordedServerless is the CloudWatch fake of the IO tests with the RDS describes of the PI fake.
type recordedServerless struct {
	*recordedCW
	*recordedPI
}

// serverlessFloor makes the floor shape for one instance: four 5-minute periods (the window's) at 0.5 ACU (the floor), a 91 %
// hit ratio, 850 reads a second at 12 % CPU; paused leaves only CPUUtilization.
func serverlessFloor(id string, now time.Time, paused bool) []recordedMetric {
	var out []recordedMetric
	start := now.Add(-serverlessWindow).Truncate(serverlessPeriod * time.Second)
	for at := start; at.Before(now.Add(-serverlessPeriod * time.Second)); at = at.Add(serverlessPeriod * time.Second) {
		vals := map[string]float64{"ServerlessDatabaseCapacity": 0.5, "ACUUtilization": 99, "BufferCacheHitRatio": 91, "ReadIOPS": 850, "CPUUtilization": 12}
		for m, v := range vals {
			if paused && m != "CPUUtilization" {
				continue
			}
			out = append(out, recordedMetric{Metric: m, Dims: map[string]string{"DBInstanceIdentifier": id}, Value: v, At: at})
		}
	}
	return out
}

func TestServerlessRows(t *testing.T) {
	now := time.Date(2026, 11, 9, 20, 7, 0, 0, time.UTC)
	for _, paused := range []bool{false, true} {
		p := newRecordedPI(t, false)
		api := recordedServerless{&recordedCW{metrics: serverlessFloor("proof-pi-1", now, paused)}, p}
		rows, err := serverlessRows(context.Background(), api, "proof-pi-1", now)
		if err != nil {
			t.Fatal(err)
		}
		per := map[string]int{}
		for _, r := range rowsOfKind(rows, "metric") {
			per[r["metric"].(string)]++
		}
		sc := rowsOfKind(rows, "scaling")
		if len(sc) != 1 || sc[0]["min_acu"] != 0.5 || sc[0]["max_acu"] != 16.0 || sc[0]["cluster"] != "proof-cluster" || sc[0]["class"] != "db.serverless" {
			t.Fatalf("scaling %v", sc)
		}
		note, _ := sc[0]["note"].(string)
		if paused {
			if len(per) != 1 || per["CPUUtilization"] != 4 || !strings.Contains(note, "paused") {
				t.Errorf("paused: metrics %v, note %q", per, note)
			}
			continue
		}
		if len(per) != 5 || per["ServerlessDatabaseCapacity"] != 4 || note != "" {
			t.Errorf("awake: metrics %v (want 5 series of 4 datapoints), note %q", per, note)
		}
		for _, q := range api.queries {
			if aws.ToString(q.MetricStat.Metric.MetricName) == "ServerlessDatabaseCapacity" && aws.ToString(q.MetricStat.Stat) != "Maximum" {
				t.Errorf("capacity read as %s, want Maximum", aws.ToString(q.MetricStat.Stat))
			}
		}
	}
}

// TestPIFixtureImport (PGVIGIL_REPO_DSN): the recorded rows through import_pi and import_serverless twice store
// each hour, key and datapoint once; the whole text survives a run that could not fetch it; a PI-off run leaves
// the state row only.
func TestPIFixtureImport(t *testing.T) {
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
	id, err := r.EnsureInstance(ctx, "pi-fixture-"+time.Now().UTC().Format("150405.000"), "aurora", "fixture", 170009, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	defer func() { _, _ = conn.Exec(ctx, `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id) }()
	val := func(sql string) string {
		var s *string
		if err := conn.QueryRow(ctx, sql, id).Scan(&s); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		if s == nil {
			return "<null>"
		}
		return *s
	}

	api := newRecordedPI(t, true)
	now := piRecordedNow(t, api)
	rows, err := piRows(ctx, api, "proof-pi-1", now)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := r.Import(ctx, id, "pi", now.Add(time.Duration(i)*time.Hour), rows); err != nil {
			t.Fatal(err)
		}
	}
	if got := val(`SELECT string_agg(dim_group || '=' || n, ',' ORDER BY dim_group) FROM (SELECT dim_group, count(*) n FROM pgvigil.pi_load WHERE instance_id = $1 GROUP BY 1) x`); got != "sql=6,total=3,wait=9" {
		t.Errorf("pi_load after two imports of one window: %s", got)
	}
	if got := val(`SELECT count(*)::text || '|' || max(length(full_text))::text FROM pgvigil.pi_sql WHERE instance_id = $1`); got != "2|694" {
		t.Errorf("pi_sql: %s, want 2 digests and the 694-byte whole text", got)
	}
	// a later run that could not fetch the whole text (an error, the call cap) keeps the one stored
	var again []Row
	for _, x := range rowsOfKind(rows, "sql") {
		c := Row{}
		for k, v := range x {
			c[k] = v
		}
		delete(c, "statement")
		c["text_status"] = "not asked (call cap)"
		again = append(again, c)
	}
	if err := r.Import(ctx, id, "pi", now.Add(2*time.Hour), again); err != nil {
		t.Fatal(err)
	}
	if got := val(`SELECT text_status || '|' || length(full_text)::text FROM pgvigil.pi_sql WHERE instance_id = $1 AND tokenized_id = 'tok-orders'`); got != "AVAILABLE|694" {
		t.Errorf("whole text after a run without it: %s", got)
	}
	// PI turned off: the state row says so; the hours already kept stay (they age out with the retention)
	off := newRecordedPI(t, false)
	offRows, err := piRows(ctx, off, "proof-pi-1", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Import(ctx, id, "pi", now.Add(3*time.Hour), offRows); err != nil {
		t.Fatal(err)
	}
	if got := val(`SELECT enabled::text || '|' || (note LIKE '%off%')::text FROM pgvigil.pi_state WHERE instance_id = $1`); got != "false|true" {
		t.Errorf("pi_state after PI off: %s", got)
	}

	sapi := recordedServerless{&recordedCW{metrics: serverlessFloor("proof-pi-1", now, false)}, newRecordedPI(t, true)}
	srows, err := serverlessRows(ctx, sapi, "proof-pi-1", now)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := r.Import(ctx, id, "serverless", now.Add(time.Duration(i)*5*time.Minute), srows); err != nil {
			t.Fatal(err)
		}
	}
	if got, want := val(`SELECT count(*)::text FROM pgvigil.serverless_sample WHERE instance_id = $1`), len(rowsOfKind(srows, "metric")); got != strconv.Itoa(want) || want < 10 {
		t.Errorf("serverless_sample rows %s after two imports of one window, want %d (one per metric and datapoint, 5 series)", got, want)
	}
	if got := val(`SELECT min_acu::text || '|' || max_acu::text || '|' || cluster FROM pgvigil.serverless_scaling WHERE instance_id = $1`); got != "0.5|16|proof-cluster" {
		t.Errorf("serverless_scaling %s", got)
	}
}
