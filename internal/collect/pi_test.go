package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
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
	pageSize   int       // > 0: an unfiltered answer comes in pages of this many series (NextToken the next index)
	floor      time.Time // set: a StartTime before it is refused, as PI refuses one before its retention
	dbErr      int       // the first dbErr DescribeDBInstances calls fail
	keyStatus  string    // set: every GetDimensionKeyDetails answer carries this status (PROCESSING: a cut text)
	clusterErr int       // the first clusterErr DescribeDBClusters calls fail
	clusters   int       // DescribeDBClusters calls
}

func (r *recordedPI) GetResourceMetrics(_ context.Context, in *pi.GetResourceMetricsInput, _ ...func(*pi.Options)) (*pi.GetResourceMetricsOutput, error) {
	r.rmCalls = append(r.rmCalls, in)
	if !r.floor.IsZero() && aws.ToTime(in.StartTime).Before(r.floor) {
		return nil, errors.New("InvalidArgumentException: You can't specify a StartTime that is earlier than 7 days ago")
	}
	groups := map[string]bool{}
	for _, q := range in.MetricQueries {
		if q.GroupBy != nil {
			groups[aws.ToString(q.GroupBy.Group)] = true
		}
	}
	filter := map[string]string{}
	limit := 0
	for _, q := range in.MetricQueries {
		for k, v := range q.Filter {
			filter[k] = v
		}
		if q.GroupBy != nil && len(q.Filter) > 0 {
			limit = int(aws.ToInt32(q.GroupBy.Limit))
		}
	}
	out := &pi.GetResourceMetricsOutput{Identifier: in.Identifier}
	for _, m := range r.metrics.MetricList {
		keep := len(m.Key.Dimensions) == 0 && len(filter) == 0
		for k := range m.Key.Dimensions {
			if g := k[:strings.LastIndex(k, ".")]; groups[g] {
				keep = true
			}
		}
		for k, v := range filter { // a filtered query: only the series of that dimension value
			if m.Key.Dimensions[k] != v {
				keep = false
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
	if limit > 0 { // the heaviest first, as PI ranks a grouped answer, cut at the limit
		load := func(k pitypes.MetricKeyDataPoints) (s float64) {
			for _, p := range k.DataPoints {
				s += aws.ToFloat64(p.Value)
			}
			return s
		}
		sort.SliceStable(out.MetricList, func(i, j int) bool { return load(out.MetricList[i]) > load(out.MetricList[j]) })
		if len(out.MetricList) > limit {
			out.MetricList = out.MetricList[:limit]
		}
	}
	if r.pageSize > 0 && len(filter) == 0 {
		from, _ := strconv.Atoi(aws.ToString(in.NextToken))
		to := min(from+r.pageSize, len(out.MetricList))
		if to < len(out.MetricList) {
			out.NextToken = aws.String(strconv.Itoa(to))
		}
		out.MetricList = out.MetricList[from:to]
	}
	return out, nil
}

func (r *recordedPI) GetDimensionKeyDetails(_ context.Context, in *pi.GetDimensionKeyDetailsInput, _ ...func(*pi.Options)) (*pi.GetDimensionKeyDetailsOutput, error) {
	r.keyCalls = append(r.keyCalls, in)
	out := &pi.GetDimensionKeyDetailsOutput{}
	for _, d := range r.details.Dimensions {
		st, v := d.Status, d.Value
		if r.keyStatus != "" {
			st = r.keyStatus
			if st == "PROCESSING" { // PI returns the cut text while it processes the whole one
				v = v[:piTextCut]
			}
		}
		out.Dimensions = append(out.Dimensions, pitypes.DimensionKeyDetail{Dimension: aws.String(d.Dimension),
			Status: pitypes.DetailStatus(st), Value: aws.String(v)})
	}
	return out, nil
}

func (r *recordedPI) DescribeDBInstances(_ context.Context, _ *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	r.describeDB++
	if r.describeDB <= r.dbErr {
		return nil, errors.New("Throttling: Rate exceeded")
	}
	return &rds.DescribeDBInstancesOutput{DBInstances: []rdstypes.DBInstance{r.db}}, nil
}

func (r *recordedPI) DescribeDBClusters(_ context.Context, _ *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	r.clusters++
	if r.clusters <= r.clusterErr {
		return nil, errors.New("Throttling: Rate exceeded")
	}
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
	now := piRecordedNow(t, api) // five minutes past the hour: a window of exactly 7 days from the hour would start before PI's floor
	api.floor = now.Add(-7 * 24 * time.Hour)
	rows, err := piRows(context.Background(), api, "k", "proof-pi-1", now, piOpts{wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	// the request: the resource id, hourly START_TIME periods over the last three complete hours, the three groups at 25
	in := api.rmCalls[0]
	if aws.ToString(in.Identifier) != "db-PROOFRESOURCE0000000001" || aws.ToInt32(in.PeriodInSeconds) != 3600 ||
		in.PeriodAlignment != pitypes.PeriodAlignmentStartTime || string(in.ServiceType) != "RDS" {
		t.Errorf("request %+v", in)
	}
	// no cursor: PI's whole retention (7 days) from the first whole hour inside it, up to the last complete hour
	if got := aws.ToTime(in.EndTime).Sub(aws.ToTime(in.StartTime)); got != 7*24*time.Hour-time.Hour || aws.ToTime(in.EndTime).Minute() != 0 {
		t.Errorf("window %s ending %s, want 7 days less one hour of complete hours", got, aws.ToTime(in.EndTime))
	}
	if aws.ToTime(in.StartTime).Before(api.floor) {
		t.Errorf("StartTime %s before PI's floor %s", aws.ToTime(in.StartTime), api.floor)
	}
	if cur := rowsOfKind(rows, "cursor"); len(cur) != 1 || cur[0]["source"] != "pi" || cur[0]["read_to"] != aws.ToTime(in.EndTime) {
		t.Errorf("cursor row %v, want read_to %s", cur, aws.ToTime(in.EndTime))
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

	// the next hour with the cursor stored at the end of the first read: one overlap behind it, so only the newest hour
	// is read again; the whole text comes from the process's cache, DescribeDBInstances from its hour's cache
	end := aws.ToTime(in.EndTime)
	rows, err = piRows(context.Background(), api, "k", "proof-pi-1", now.Add(30*time.Minute), piOpts{since: end, wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	in = api.rmCalls[len(api.rmCalls)-1]
	if aws.ToTime(in.StartTime) != end.Add(-piOverlap) || rowsOfKind(rows, "state")[0]["hours_read"] != 1 {
		t.Errorf("cursor read: window from %s (want %s), hours_read %v (want 1)", aws.ToTime(in.StartTime), end.Add(-piOverlap), rowsOfKind(rows, "state")[0]["hours_read"])
	}
	if len(api.keyCalls) != 1 || api.describeDB != 1 {
		t.Errorf("second run: %d key-detail calls, %d describes; want 1 and 1 (both cached)", len(api.keyCalls), api.describeDB)
	}
	// a cursor already at the last complete hour: nothing to read, the state row alone
	calls := len(api.rmCalls)
	rows, err = piRows(context.Background(), api, "k", "proof-pi-1", now.Add(40*time.Minute), piOpts{since: end.Add(time.Hour), wantText: true})
	if err != nil || len(rows) != 1 || rows[0]["hours_read"] != 0 || len(api.rmCalls) != calls {
		t.Errorf("nothing new: rows %v, %d more calls", rows, len(api.rmCalls)-calls)
	}
}

func TestPIOff(t *testing.T) {
	api := newRecordedPI(t, false)
	rows, err := piRows(context.Background(), api, "k", "proof-pi-1", piRecordedNow(t, api), piOpts{wantText: true})
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

// TestPITextPolicy: the digest and the whole text ride query and statement, so the instance's policy reaches both;
// under none the collector makes no text call at all.
func TestPITextPolicy(t *testing.T) {
	for _, mode := range []string{"full", "normalized", "none"} {
		api := newRecordedPI(t, true)
		rows, err := piRows(context.Background(), api, "k", "proof-pi-1", piRecordedNow(t, api), piOpts{wantText: mode != "none"})
		if err != nil {
			t.Fatal(err)
		}
		if mode == "none" && len(api.keyCalls) != 0 {
			t.Errorf("none: %d whole-text calls, want 0", len(api.keyCalls))
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
// hit ratio, 850 reads a second at 12 % CPU; paused is what AWS documents for a paused instance (the Aurora User
// Guide, automatic pause): 0 for ServerlessDatabaseCapacity, ACUUtilization and CPUUtilization, nothing else.
func serverlessFloor(id string, now time.Time, paused bool) []recordedMetric {
	var out []recordedMetric
	start := now.Add(-serverlessWindow).Truncate(serverlessPeriod * time.Second)
	for at := start; at.Before(now.Add(-serverlessPeriod * time.Second)); at = at.Add(serverlessPeriod * time.Second) {
		vals := map[string]float64{"ServerlessDatabaseCapacity": 0.5, "ACUUtilization": 99, "BufferCacheHitRatio": 91, "ReadIOPS": 850, "CPUUtilization": 12}
		if paused {
			vals = map[string]float64{"ServerlessDatabaseCapacity": 0, "ACUUtilization": 0, "CPUUtilization": 0}
		}
		for m, v := range vals {
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
		rows, err := serverlessRows(context.Background(), api, "k", "proof-pi-1", now)
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
			if len(per) != 3 || per["ServerlessDatabaseCapacity"] != 4 || !strings.HasPrefix(note, "paused") {
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

	// a provisioned instance in a cluster that carries a range (a mixed cluster): skipped after the describe
	p := newRecordedPI(t, false)
	p.db.DBInstanceClass = aws.String("db.r6g.large")
	var prov []recordedMetric
	for _, m := range serverlessFloor("proof-pi-1", now, false) {
		if m.Metric != "ServerlessDatabaseCapacity" && m.Metric != "ACUUtilization" {
			prov = append(prov, m)
		}
	}
	rows, err := serverlessRows(context.Background(), recordedServerless{&recordedCW{metrics: prov}, p}, "k", "proof-pi-1", now)
	if !errors.Is(err, ErrSkip) || !strings.Contains(err.Error(), "provisioned") || len(rows) != 0 {
		t.Errorf("provisioned instance: rows %v, err %v (want a skip with the reason)", rows, err)
	}
}

// TestServerlessDescribeFails: a failed DescribeDBInstances still stores the metrics with the error row, never a skip.
func TestServerlessDescribeFails(t *testing.T) {
	now := time.Date(2026, 11, 9, 20, 7, 0, 0, time.UTC)
	p := newRecordedPI(t, false)
	p.dbErr = 1
	rows, err := serverlessRows(context.Background(), recordedServerless{&recordedCW{metrics: serverlessFloor("proof-pi-1", now, false)}, p}, "k", "proof-pi-1", now)
	if err != nil {
		t.Fatalf("a failed describe became an error or a skip: %v", err)
	}
	if n := len(rowsOfKind(rows, "metric")); n != 20 {
		t.Errorf("metric rows %d, want 20", n)
	}
	if e := rowsOfKind(rows, "collector_error"); len(e) != 1 || !strings.Contains(e[0]["message"].(string), "DescribeDBInstances") || len(rowsOfKind(rows, "scaling")) != 0 {
		t.Errorf("error row %v, scaling rows %d", e, len(rowsOfKind(rows, "scaling")))
	}
}

// TestDescribeClusterRetry: a failed DescribeDBClusters is read again on the next call, the instance answer stays
// cached; the same identifier under another profile or region is its own entry.
func TestDescribeClusterRetry(t *testing.T) {
	now := time.Date(2026, 11, 9, 20, 7, 0, 0, time.UTC)
	p := newRecordedPI(t, false)
	p.clusterErr = 1
	d, err := platform.DescribeAWSInstance(context.Background(), p, "k", "proof-pi-1", now)
	if err != nil || d.HasScaling || !strings.Contains(d.ScalingNote, "Throttling") {
		t.Fatalf("first read: %+v %v", d, err)
	}
	d, err = platform.DescribeAWSInstance(context.Background(), p, "k", "proof-pi-1", now.Add(5*time.Minute))
	if err != nil || !d.HasScaling || d.MinACU != 0.5 || p.describeDB != 1 || p.clusters != 2 {
		t.Fatalf("second read: %+v %v (describes %d, cluster reads %d)", d, err, p.describeDB, p.clusters)
	}
	if _, err = platform.DescribeAWSInstance(context.Background(), p, "k", "proof-pi-1", now.Add(10*time.Minute)); err != nil || p.clusters != 2 {
		t.Errorf("third read re-read the cluster: %d reads", p.clusters)
	}
	if _, err = platform.DescribeAWSInstance(context.Background(), p, "other|eu-west-1", "proof-pi-1", now.Add(10*time.Minute)); err != nil || p.describeDB != 2 {
		t.Errorf("another profile shared the cache: %d describes", p.describeDB)
	}
}

// TestPITextPaths: a PROCESSING answer is not kept (asked again next run); a cut digest none of whose statements is
// in the top 25 finds its heaviest statement by a filtered call, and one with none at all says so; past the call cap
// a digest is "not asked"; a paged answer keeps the total once.
func TestPITextPaths(t *testing.T) {
	ctx := context.Background()
	api := newRecordedPI(t, true)
	api.keyStatus = "PROCESSING"
	now := piRecordedNow(t, api)
	rows, err := piRows(ctx, api, "k", "proof-pi-1", now, piOpts{wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rowsOfKind(rows, "sql") {
		if r["tokenized_id"] == "tok-orders" && (r["text_status"] != "PROCESSING" || len(r["statement"].(string)) != piTextCut) {
			t.Errorf("PROCESSING row %v", r["text_status"])
		}
	}
	if _, err := piRows(ctx, api, "k", "proof-pi-1", now.Add(time.Hour), piOpts{wantText: true}); err != nil || len(api.keyCalls) != 2 {
		t.Errorf("a PROCESSING text was kept: %d detail calls over two runs, want 2", len(api.keyCalls))
	}

	// the bridge series of tok-orders left out of the top statements: the filtered call finds sql-orders-a
	var kept []string
	hidden := &hiddenPI{recordedPI: newRecordedPI(t, true)}
	rows, err = piRows(ctx, hidden, "k", "proof-pi-1", now, piOpts{wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rowsOfKind(rows, "sql") {
		if r["tokenized_id"] == "tok-orders" {
			kept = append(kept, r["text_status"].(string), r["sql_id"].(string))
		}
	}
	if strings.Join(kept, ",") != "AVAILABLE,sql-orders-a" || hidden.filtered != 1 {
		t.Errorf("filtered lookup: %v, %d filtered calls", kept, hidden.filtered)
	}
	hidden2 := &hiddenPI{recordedPI: newRecordedPI(t, true), dropAll: true}
	rows, err = piRows(ctx, hidden2, "k", "proof-pi-1", now, piOpts{wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rowsOfKind(rows, "sql") {
		if r["tokenized_id"] == "tok-orders" && r["text_status"] != "no statement id" {
			t.Errorf("no statement at all: %v", r["text_status"])
		}
	}

	// 30 cut digests: the cap stops the calls, the rest are "not asked"
	api = newRecordedPI(t, true)
	var base struct {
		Key struct {
			Metric     string            `json:"Metric"`
			Dimensions map[string]string `json:"Dimensions"`
		} `json:"Key"`
		DataPoints []struct {
			Timestamp float64  `json:"Timestamp"`
			Value     *float64 `json:"Value"`
		} `json:"DataPoints"`
	}
	for _, m := range api.metrics.MetricList {
		if m.Key.Dimensions["db.sql_tokenized.id"] == "tok-orders" {
			base = m
		}
	}
	for i := 0; i < 30; i++ {
		d := base
		d.Key.Dimensions = map[string]string{"db.sql_tokenized.id": fmt.Sprintf("tok-%02d", i), "db.sql_tokenized.statement": base.Key.Dimensions["db.sql_tokenized.statement"]}
		b := base
		b.Key.Dimensions = map[string]string{"db.sql.id": fmt.Sprintf("sql-%02d", i), "db.sql.tokenized_id": fmt.Sprintf("tok-%02d", i)}
		api.metrics.MetricList = append(api.metrics.MetricList, d, b)
	}
	rows, err = piRows(ctx, api, "k", "proof-pi-1", now, piOpts{wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	notAsked := 0
	for _, r := range rowsOfKind(rows, "sql") {
		if r["text_status"] == "not asked (call cap)" {
			notAsked++
		}
	}
	if len(api.keyCalls) != piMaxCalls || notAsked != 31-piMaxCalls {
		t.Errorf("call cap: %d detail calls (want %d), %d not asked (want %d)", len(api.keyCalls), piMaxCalls, notAsked, 31-piMaxCalls)
	}

	// paged: the same rows as one page
	api = newRecordedPI(t, true)
	api.pageSize = 2
	rows, err = piRows(ctx, api, "k", "proof-pi-1", now, piOpts{wantText: true})
	if err != nil {
		t.Fatal(err)
	}
	n := map[string]int{}
	for _, r := range rowsOfKind(rows, "load") {
		n[r["group"].(string)]++
	}
	if n["total"] != 3 || n["wait"] != 9 || n["sql"] != 6 || len(api.rmCalls) < 3 {
		t.Errorf("paged: %v over %d calls", n, len(api.rmCalls))
	}
}

// hiddenPI keeps the db.sql series of tok-orders out of the unfiltered answer (they are not in the top statements)
// and serves them to the filtered call only; dropAll serves them to neither.
type hiddenPI struct {
	*recordedPI
	dropAll  bool
	filtered int
}

func (h *hiddenPI) GetResourceMetrics(ctx context.Context, in *pi.GetResourceMetricsInput, o ...func(*pi.Options)) (*pi.GetResourceMetricsOutput, error) {
	isFiltered := len(in.MetricQueries) == 1 && len(in.MetricQueries[0].Filter) > 0
	if isFiltered {
		h.filtered++
	}
	out, err := h.recordedPI.GetResourceMetrics(ctx, in, o...)
	if err != nil {
		return nil, err
	}
	keep := out.MetricList[:0]
	for _, m := range out.MetricList {
		if m.Key.Dimensions["db.sql.tokenized_id"] == "tok-orders" && (h.dropAll || !isFiltered) {
			continue
		}
		keep = append(keep, m)
	}
	out.MetricList = keep
	return out, nil
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
	rows, err := piRows(ctx, api, "k", "proof-pi-1", now, piOpts{wantText: true})
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
	if got := val(`SELECT to_char(read_to AT TIME ZONE 'UTC', 'MI:SS') FROM pgvigil.log_cursor WHERE instance_id = $1 AND source = 'pi'`); got != "00:00" {
		t.Errorf("pi cursor after the import: %s, want an hour boundary", got)
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
	// the policy turned to none: the text, its status and its statement id go together
	none := []Row{{"kind": "sql", "tokenized_id": "tok-orders", "query": nil, "statement": nil, "text_status": "AVAILABLE", "sql_id": "sql-orders-a"}}
	if err := r.Import(ctx, id, "pi", now.Add(150*time.Minute), none); err != nil {
		t.Fatal(err)
	}
	if got := val(`SELECT coalesce(full_text, '-') || '|' || coalesce(text_status, '-') || '|' || coalesce(sql_id, '-') FROM pgvigil.pi_sql WHERE instance_id = $1 AND tokenized_id = 'tok-orders'`); got != "-|-|-" {
		t.Errorf("after a run under none: %s, want no text, no status, no statement id", got)
	}
	// PI turned off: the state row says so; the hours already kept stay (they age out with the retention)
	off := newRecordedPI(t, false)
	offRows, err := piRows(ctx, off, "k", "proof-pi-1", now, piOpts{wantText: true})
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
	srows, err := serverlessRows(ctx, sapi, "k", "proof-pi-1", now)
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
