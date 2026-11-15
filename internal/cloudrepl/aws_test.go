package cloudrepl

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/smithy-go"
)

// fakeRDS answers DescribeDBInstances from a list, two instances a page (the Marker), or with an error
type fakeRDS struct {
	mu    sync.Mutex
	list  []rdstypes.DBInstance
	err   error
	calls int
}

func (f *fakeRDS) DescribeDBInstances(_ context.Context, in *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	start := 0
	if in.Marker != nil {
		for i, d := range f.list {
			if aws.ToString(d.DBInstanceIdentifier) == *in.Marker {
				start = i
			}
		}
	}
	end := min(start+2, len(f.list))
	out := &rds.DescribeDBInstancesOutput{DBInstances: f.list[start:end]}
	if end < len(f.list) {
		out.Marker = f.list[end].DBInstanceIdentifier
	}
	return out, nil
}

// fakeCW answers ReplicaLag per DBInstanceIdentifier from a map (no entry: an empty answer), or with an error
type fakeCW struct {
	mu    sync.Mutex
	lag   map[string][]float64
	err   error
	asked []string
}

func (f *fakeCW) GetMetricData(_ context.Context, in *cloudwatch.GetMetricDataInput, _ ...func(*cloudwatch.Options)) (*cloudwatch.GetMetricDataOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	out := &cloudwatch.GetMetricDataOutput{}
	for _, q := range in.MetricDataQueries {
		m := q.MetricStat.Metric
		if aws.ToString(m.Namespace) != "AWS/RDS" || aws.ToString(m.MetricName) != "ReplicaLag" || aws.ToString(q.MetricStat.Stat) != "Maximum" ||
			aws.ToInt32(q.MetricStat.Period) != 60 || len(m.Dimensions) != 1 || aws.ToString(m.Dimensions[0].Name) != "DBInstanceIdentifier" {
			return nil, errors.New("an unexpected query")
		}
		id := aws.ToString(m.Dimensions[0].Value)
		f.asked = append(f.asked, id)
		r := cwtypes.MetricDataResult{Id: q.Id}
		for i, v := range f.lag[id] {
			r.Timestamps = append(r.Timestamps, in.EndTime.Add(-time.Duration(i+1)*time.Minute))
			r.Values = append(r.Values, v)
		}
		out.MetricDataResults = append(out.MetricDataResults, r)
	}
	return out, nil
}

func db(id, status, source string, replicas []string, infos ...rdstypes.DBInstanceStatusInfo) rdstypes.DBInstance {
	d := rdstypes.DBInstance{DBInstanceIdentifier: aws.String(id), DBInstanceStatus: aws.String(status), Engine: aws.String("postgres"),
		ReadReplicaDBInstanceIdentifiers: replicas, StatusInfos: infos}
	if source != "" {
		d.ReadReplicaSourceDBInstanceIdentifier = aws.String(source)
	}
	return d
}

func replicating(status string) rdstypes.DBInstanceStatusInfo {
	return rdstypes.DBInstanceStatusInfo{StatusType: aws.String("read replication"), Status: aws.String(status), Normal: aws.Bool(status == "replicating"),
		Message: aws.String("the replica's own words")}
}

// P1 (task 390b): the topology of an RDS instance and its replicas from one paged DescribeDBInstances per region and
// run, shared by the run's instances (the design fold 15); a cascaded replica marked (fold 12); a replica in another
// region (an ARN) read in its own region; StatusInfos' read replication status; ReplicaLag (Maximum over 60 s, 20
// minutes) per replica; an empty answer for an available replica stores no point (R-E's Go case); a refused
// DescribeDBInstances (AccessDenied) still reads the instance's own lag with the sentence; a throttle is its own error.
func TestAWSReplicas(t *testing.T) {
	east := &fakeRDS{list: []rdstypes.DBInstance{
		db("db1", "available", "", []string{"db1-r1", "arn:aws:rds:us-west-2:123456789012:db:db1-r2"}),
		db("other", "available", "", nil),
		db("db1-r1", "available", "db1", []string{"db1-r1a"}, replicating("replicating")),
		db("db1-r1a", "available", "db1-r1", nil),
	}}
	west := &fakeRDS{list: []rdstypes.DBInstance{db("db1-r2", "available", "arn:aws:rds:us-east-2:123456789012:db:db1", nil, replicating("error"))}}
	cwEast := &fakeCW{lag: map[string][]float64{"db1-r1": {3, 4}, "db1-r1a": {9}}}
	cwWest := &fakeCW{lag: map[string][]float64{"db1-r2": {120}}}
	now := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)
	r := &AWSReader{
		RDS: func(_ context.Context, region string) (RDSAPI, error) {
			return map[string]*fakeRDS{"us-east-2": east, "us-west-2": west}[region], nil
		},
		CW: func(_ context.Context, region string) (CWAPI, error) {
			return map[string]*fakeCW{"us-east-2": cwEast, "us-west-2": cwWest}[region], nil
		},
		Now: func() time.Time { return now },
	}
	res, pts, notes, err := r.Read(context.Background(), "us-east-2", "db1")
	if err != nil || len(notes) != 0 {
		t.Fatalf("Read db1: %v %v", err, notes)
	}
	byID := map[string]Resource{}
	for _, x := range res {
		byID[x.ID] = x
	}
	if s := byID["db1"]; s.Role != "source" || strings.Join(s.ReplicaIDs, ",") != "db1-r1,db1-r2" || s.Region != "us-east-2" || s.Provider != "aws" {
		t.Errorf("db1: %+v", s)
	}
	if r1 := byID["db1-r1"]; r1.Role != "replica" || r1.SourceID != "db1" || !r1.Cascaded || r1.ReplStatus != "replicating" {
		t.Errorf("db1-r1 (a replica that is a source too): %+v", r1)
	}
	if r2 := byID["db1-r2"]; r2.Role != "replica" || r2.Region != "us-west-2" || r2.SourceID != "db1" || r2.ReplStatus != "error" || r2.ReplNote != "the replica's own words" {
		t.Errorf("db1-r2 (another region's): %+v", r2)
	}
	if _, ok := byID["other"]; ok || len(res) != 3 {
		t.Errorf("resources %v: want db1 and its two replicas only", res)
	}
	got := map[string]int{}
	for _, p := range pts {
		if p.Metric != "replica_lag" || p.Unit != "s" {
			t.Errorf("a point %+v", p)
		}
		got[p.ResourceID]++
	}
	if got["db1-r1"] != 2 || got["db1-r2"] != 1 || len(got) != 2 {
		t.Errorf("points per replica %v, want db1-r1 2 and db1-r2 1 (each replica's own lag, read in its region)", got)
	}
	if east.calls != 2 || west.calls != 1 {
		t.Errorf("DescribeDBInstances calls: us-east-2 %d (want 2: two pages), us-west-2 %d (want 1)", east.calls, west.calls)
	}
	// another instance of the same run (db1-r1, a replica that is a source): no second DescribeDBInstances
	res, pts, _, err = r.Read(context.Background(), "us-east-2", "db1-r1")
	if err != nil || east.calls != 2 {
		t.Fatalf("Read db1-r1 in the same run: %v, us-east-2 calls %d (want 2: one listing a region and run)", err, east.calls)
	}
	if len(res) != 3 || len(pts) != 3 { // db1-r1 itself, its source, its replica; db1-r1's 2 points and db1-r1a's 1
		t.Errorf("db1-r1's read: %d resources, %d points, want 3 and 3", len(res), len(pts))
	}
	// an available replica whose lag comes back empty: the resource, no point
	cwEast.lag = map[string][]float64{}
	if _, pts, _, err = r.Read(context.Background(), "us-east-2", "db1-r1a"); err != nil || len(pts) != 0 {
		t.Errorf("an empty ReplicaLag answer: %v, %d points, want none", err, len(pts))
	}
	// a refused listing: the instance's own lag is still read, the sentence kept
	denied := &AWSReader{
		RDS: func(context.Context, string) (RDSAPI, error) {
			return &fakeRDS{err: &smithy.GenericAPIError{Code: "AccessDenied", Message: "not authorized to perform: rds:DescribeDBInstances"}}, nil
		},
		CW: func(context.Context, string) (CWAPI, error) {
			return &fakeCW{lag: map[string][]float64{"dbx": {7}}}, nil
		},
		Now: func() time.Time { return now },
	}
	res, pts, notes, err = denied.Read(context.Background(), "us-east-2", "dbx")
	if err != nil || len(pts) != 1 || len(notes) != 1 || !strings.Contains(notes[0], "AccessDenied") || !strings.Contains(notes[0], "rds:DescribeDBInstances") {
		t.Errorf("AccessDenied: err %v, %d points, notes %q; want the lag read and one note naming the right", err, len(pts), notes)
	}
	if len(res) != 0 {
		t.Errorf("AccessDenied: %d resources, want none (the topology is not known)", len(res))
	}
	// a throttle: its own error, nothing stored
	throttled := &AWSReader{
		RDS: func(context.Context, string) (RDSAPI, error) {
			return &fakeRDS{err: &smithy.GenericAPIError{Code: "Throttling", Message: "Rate exceeded"}}, nil
		},
		CW:  func(context.Context, string) (CWAPI, error) { return &fakeCW{}, nil },
		Now: func() time.Time { return now },
	}
	if _, _, _, err = throttled.Read(context.Background(), "us-east-2", "dbx"); !errors.As(err, new(*Throttled)) {
		t.Errorf("a throttle: %v, want *Throttled", err)
	}
	// a new run (the cache past its age): listed again
	now = now.Add(5 * time.Minute)
	if _, _, _, err = r.Read(context.Background(), "us-east-2", "db1"); err != nil || east.calls != 4 {
		t.Errorf("the next run: %v, us-east-2 calls %d (want 4)", err, east.calls)
	}
}
