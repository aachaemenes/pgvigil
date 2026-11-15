package cloudrepl

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/smithy-go"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// 390b ID (a), the lead's 07:1x (the review's part a finding 2 and part b finding 1): an AWS resource's key is its
// lower-cased DBInstanceArn - unique across regions, accounts and partitions, where the bare identifier is unique only
// inside one account and region. From the recorded answers' shape (each DescribeDBInstances row carries its ARN):
//   - a cross-region replica named as its source ('orders' in two regions) is two resources, not one flipping role;
//   - two accounts' default 'database-1' (two profiles of one collector) are two resources;
//   - a same-region replica named by its bare identifier takes its source's partition and account (GovCloud here);
//   - a refused listing names the instance's own lag and read row by the credential's partition and account
//     (sts:GetCallerIdentity, no IAM right needed), the same key a listed read gives; with neither, the read is
//     refused in words, never stored under another key;
//   - an ARN in the answer is lower-cased.
func TestAWSResourceIDIsTheARN(t *testing.T) {
	now := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	ctx := context.Background()
	reader := func(lists map[string]*fakeRDS, lag map[string]*fakeCW, part, acct string) *AWSReader {
		return &AWSReader{
			RDS:    func(_ context.Context, region string) (RDSAPI, error) { return lists[region], nil },
			CW:     func(_ context.Context, region string) (CWAPI, error) { return lag[region], nil },
			Caller: func(context.Context, string) (string, string, error) { return part, acct, nil },
			Now:    func() time.Time { return now },
		}
	}
	ids := func(res []Resource) map[string]Resource {
		m := map[string]Resource{}
		for _, x := range res {
			m[x.ID] = x
		}
		return m
	}

	// a cross-region replica with its source's name
	src, rep := east1+"orders", west2+"orders"
	r := reader(map[string]*fakeRDS{
		"us-east-2": {list: []rdstypes.DBInstance{dbAt("ARN:AWS:RDS:US-EAST-2:123456789012:DB:ORDERS", "orders", "available", "", []string{"arn:aws:rds:us-west-2:123456789012:db:orders"})}},
		"us-west-2": {list: []rdstypes.DBInstance{dbAt(rep, "orders", "available", src, nil, replicating("replicating"))}},
	}, map[string]*fakeCW{"us-east-2": {}, "us-west-2": {lag: map[string][]float64{"orders": {5}}}}, "aws", "123456789012")
	res, pts, notes, err := r.Read(ctx, "us-east-2", "orders")
	if err != nil || len(notes) != 0 {
		t.Fatalf("the source's read: %v %v", err, notes)
	}
	m := ids(res)
	if len(m) != 2 || m[src].Role != "source" || strings.Join(m[src].ReplicaIDs, ",") != rep || m[rep].Role != "replica" || m[rep].SourceID != src || m[rep].Region != "us-west-2" {
		t.Errorf("a cross-region replica of the same name: %+v - want two resources, the source %s and the replica %s", res, src, rep)
	}
	if len(pts) != 1 || pts[0].ResourceID != rep {
		t.Errorf("the replica's lag %+v, want one point of %s (the dimension is its identifier, the key its ARN)", pts, rep)
	}

	// two accounts' database-1, each read by its own profile's reader
	one := reader(map[string]*fakeRDS{"us-east-2": {list: []rdstypes.DBInstance{dbAt("arn:aws:rds:us-east-2:111111111111:db:database-1", "database-1", "available", "", nil)}}},
		map[string]*fakeCW{"us-east-2": {}}, "aws", "111111111111")
	two := reader(map[string]*fakeRDS{"us-east-2": {list: []rdstypes.DBInstance{dbAt("arn:aws:rds:us-east-2:222222222222:db:database-1", "database-1", "available", "", nil)}}},
		map[string]*fakeCW{"us-east-2": {}}, "aws", "222222222222")
	a, _, _, errA := one.Read(ctx, "us-east-2", "database-1")
	b, _, _, errB := two.Read(ctx, "us-east-2", "database-1")
	if errA != nil || errB != nil || len(a) != 1 || len(b) != 1 || a[0].ID == b[0].ID {
		t.Errorf("two accounts' database-1: %+v and %+v (%v %v), want two keys", a, b, errA, errB)
	}

	// a same-region replica by its bare identifier, in GovCloud: the source's partition and account
	gov := "arn:aws-us-gov:rds:us-gov-west-1:333333333333:db:"
	g := reader(map[string]*fakeRDS{"us-gov-west-1": {list: []rdstypes.DBInstance{
		dbAt(gov+"g1", "g1", "available", "", []string{"g1-r1"}),
		dbAt(gov+"g1-r1", "g1-r1", "available", "g1", nil, replicating("replicating")),
	}}}, map[string]*fakeCW{"us-gov-west-1": {lag: map[string][]float64{"g1-r1": {2}}}}, "aws-us-gov", "333333333333")
	res, pts, _, err = g.Read(ctx, "us-gov-west-1", "g1")
	m = ids(res)
	if err != nil || strings.Join(m[gov+"g1"].ReplicaIDs, ",") != gov+"g1-r1" || m[gov+"g1-r1"].SourceID != gov+"g1" || len(pts) != 1 || pts[0].ResourceID != gov+"g1-r1" {
		t.Errorf("GovCloud by bare identifiers: %+v %+v (%v), want %s and %s", res, pts, err, gov+"g1", gov+"g1-r1")
	}

	// a refused listing: the caller identity names the instance; the Door's read row says the same key
	denied := func(caller func(context.Context, string) (string, string, error)) *AWSReader {
		return &AWSReader{
			RDS: func(context.Context, string) (RDSAPI, error) {
				return &fakeRDS{err: &smithy.GenericAPIError{Code: "AccessDenied", Message: "not authorized to perform: rds:DescribeDBInstances"}}, nil
			},
			CW: func(context.Context, string) (CWAPI, error) {
				return &fakeCW{lag: map[string][]float64{"g1-r1": {4}}}, nil
			},
			Caller: caller,
			Now:    func() time.Time { return now },
		}
	}
	d := &Door{Now: func() time.Time { return now }, NewAWS: func(string) *AWSReader {
		return denied(func(context.Context, string) (string, string, error) { return "aws-us-gov", "333333333333", nil })
	}}
	rows, err := d.Rows(ctx, config.Instance{Name: "pg1", AWS: &config.AWS{Region: "us-gov-west-1", DBInstance: "G1-R1", Replicas: true}})
	if err != nil || len(rows) == 0 || rows[0]["resource_id"] != gov+"g1-r1" {
		t.Fatalf("a refused listing's read row: %v %v, want %s (the caller identity's partition and account)", rows, err, gov+"g1-r1")
	}
	for _, x := range rows {
		if x["kind"] == "point" && x["resource_id"] != gov+"g1-r1" {
			t.Errorf("a refused listing's point under %v, want %s", x["resource_id"], gov+"g1-r1")
		}
	}
	// neither the listing nor the caller identity: refused in words, nothing stored under another key
	d = &Door{Now: func() time.Time { return now }, NewAWS: func(string) *AWSReader {
		return denied(func(context.Context, string) (string, string, error) { return "", "", errors.New("no credentials") })
	}}
	if rows, err = d.Rows(ctx, config.Instance{Name: "pg1", AWS: &config.AWS{Region: "us-gov-west-1", DBInstance: "g1-r1", Replicas: true}}); err == nil || !strings.Contains(err.Error(), "GetCallerIdentity") {
		t.Errorf("no listing and no caller identity: %v %v, want the read refused naming sts:GetCallerIdentity", rows, err)
	}
}
