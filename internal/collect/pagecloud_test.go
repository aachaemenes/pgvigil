package collect

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// fakePageRDS answers the check's two RDS reads from recorded instances and clusters (an unknown name = RDS's own
// not-found fault, as the service answers); err, when set, is every call's answer.
type fakePageRDS struct {
	inst  map[string]rdstypes.DBInstance
	cl    map[string]rdstypes.DBCluster
	err   error
	calls int
}

func (f *fakePageRDS) DescribeDBInstances(_ context.Context, in *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	d, ok := f.inst[aws.ToString(in.DBInstanceIdentifier)]
	if !ok {
		return nil, &rdstypes.DBInstanceNotFoundFault{Message: aws.String("DBInstance " + aws.ToString(in.DBInstanceIdentifier) + " not found.")}
	}
	return &rds.DescribeDBInstancesOutput{DBInstances: []rdstypes.DBInstance{d}}, nil
}

func (f *fakePageRDS) DescribeDBClusters(_ context.Context, in *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	c, ok := f.cl[aws.ToString(in.DBClusterIdentifier)]
	if !ok {
		return nil, &rdstypes.DBClusterNotFoundFault{Message: aws.String("DBCluster " + aws.ToString(in.DBClusterIdentifier) + " not found.")}
	}
	return &rds.DescribeDBClustersOutput{DBClusters: []rdstypes.DBCluster{c}}, nil
}

// B24p's fold 1-2 (review 20261115-023158 findings 1 and 2): a page block's target is checked against the provider's
// own answer, in the account the block reads with, before its first read - the host must be the DB instance's
// Endpoint.Address or the cluster's writer / reader endpoint, and a block naming both must name an instance of that
// cluster. A name match alone let a user's own payroll-prod (their account) open the host's reads of the collector
// account's payroll-prod.
func TestPageAWSCheck(t *testing.T) {
	ctx := context.Background()
	own := "db1.c9akciq32.us-east-2.rds.amazonaws.com"
	api := &fakePageRDS{
		inst: map[string]rdstypes.DBInstance{
			"db1":   {DBInstanceIdentifier: aws.String("db1"), Endpoint: &rdstypes.Endpoint{Address: aws.String(own)}},
			"mine":  {DBInstanceIdentifier: aws.String("mine"), DBClusterIdentifier: aws.String("mine-cluster"), Endpoint: &rdstypes.Endpoint{Address: aws.String("mine.c9akciq32.us-east-2.rds.amazonaws.com")}},
			"app-1": {DBInstanceIdentifier: aws.String("app-1"), DBClusterIdentifier: aws.String("app"), Endpoint: &rdstypes.Endpoint{Address: aws.String("app-1.c9akciq32.us-east-2.rds.amazonaws.com")}},
		},
		cl: map[string]rdstypes.DBCluster{
			"app": {DBClusterIdentifier: aws.String("app"), Endpoint: aws.String("app.cluster-c9akciq32.us-east-2.rds.amazonaws.com"),
				ReaderEndpoint: aws.String("app.cluster-ro-c9akciq32.us-east-2.rds.amazonaws.com")},
			"victim": {DBClusterIdentifier: aws.String("victim"), Endpoint: aws.String("victim.cluster-c9akciq32.us-east-2.rds.amazonaws.com")},
		},
	}
	for _, c := range []struct {
		what  string
		a     config.AWS
		host  string
		words []string // "" = the block holds
	}{
		{"the instance's own endpoint", config.AWS{Region: "us-east-2", DBInstance: "db1"}, own, nil},
		{"case folded", config.AWS{Region: "us-east-2", DBInstance: "db1"}, strings.ToUpper(own[:3]) + own[3:], nil},
		{"another account's payroll-prod (the same name, another hash)", config.AWS{Region: "us-east-2", DBInstance: "db1"}, "db1.zz9theirs1.us-east-2.rds.amazonaws.com", []string{"db1.zz9theirs1", own}},
		{"a name this identity does not hold", config.AWS{Region: "us-east-2", DBInstance: "nobody"}, "nobody.c9akciq32.us-east-2.rds.amazonaws.com", []string{"nobody", "us-east-2"}},
		{"a foreign cluster beside the instance's own name", config.AWS{Region: "us-east-2", DBInstance: "mine", Cluster: "victim"}, "mine.c9akciq32.us-east-2.rds.amazonaws.com", []string{"victim", "mine-cluster"}},
		{"a foreign instance beside the cluster's own endpoint", config.AWS{Region: "us-east-2", DBInstance: "db1", Cluster: "app"}, "app.cluster-c9akciq32.us-east-2.rds.amazonaws.com", []string{"db1", "app"}},
		{"the cluster's writer endpoint", config.AWS{Region: "us-east-2", Cluster: "app"}, "app.cluster-c9akciq32.us-east-2.rds.amazonaws.com", nil},
		{"the cluster's reader endpoint", config.AWS{Region: "us-east-2", Cluster: "app"}, "app.cluster-ro-c9akciq32.us-east-2.rds.amazonaws.com", nil},
		{"a member's own endpoint, both names", config.AWS{Region: "us-east-2", DBInstance: "app-1", Cluster: "app"}, "app-1.c9akciq32.us-east-2.rds.amazonaws.com", nil},
		{"the cluster's endpoint, both names", config.AWS{Region: "us-east-2", DBInstance: "app-1", Cluster: "app"}, "app.cluster-c9akciq32.us-east-2.rds.amazonaws.com", nil},
		{"another cluster's endpoint", config.AWS{Region: "us-east-2", Cluster: "app"}, "victim.cluster-c9akciq32.us-east-2.rds.amazonaws.com", []string{"victim.cluster", "app"}},
	} {
		why, err := checkPageAWS(ctx, api, c.a, c.host)
		if err != nil {
			t.Errorf("%s: %v", c.what, err)
			continue
		}
		if (why == "") != (c.words == nil) {
			t.Errorf("%s: %q, want the block %s", c.what, why, map[bool]string{true: "kept", false: "refused"}[c.words == nil])
		}
		for _, w := range c.words {
			if !strings.Contains(why, w) {
				t.Errorf("%s: %q does not name %q", c.what, why, w)
			}
		}
	}
	// an AWS error is no verdict: checkPageAWS says so, pageAWSVerdict refuses the block (fail closed) and asks again
	// only after the back-off; a verdict is asked once per (block, host)
	if _, err := checkPageAWS(ctx, &fakePageRDS{err: errors.New("AccessDenied: not authorized")}, config.AWS{Region: "us-east-2", DBInstance: "db1"}, own); err == nil {
		t.Error("an AWS error came back as a verdict")
	}
	fake := &fakePageRDS{err: errors.New("operation error RDS: DescribeDBInstances, get identity: get credentials: failed to refresh cached credentials")}
	was := newPageAWSAPI
	defer func() { newPageAWSAPI = was; resetPageAWSVerdicts() }()
	newPageAWSAPI = func(context.Context, config.AWS) (pageAWSAPI, error) { return fake, nil }
	resetPageAWSVerdicts()
	in := config.Instance{Name: "pg-cloud", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1"}, PageAWSHost: own}
	t0 := time.Date(2026, 11, 15, 3, 0, 0, 0, time.UTC)
	if why := pageAWSVerdict(ctx, slog.New(slog.DiscardHandler), in, t0); !strings.Contains(why, "could not be checked") || !strings.Contains(why, "get credentials") {
		t.Errorf("an AWS error: %q, want the block refused in the SDK's words", why)
	}
	n := fake.calls
	if why := pageAWSVerdict(ctx, slog.New(slog.DiscardHandler), in, t0.Add(pageAWSRetry/2)); why == "" || fake.calls != n {
		t.Errorf("inside the back-off: %q after %d more call(s), want the refusal kept and no call", why, fake.calls-n)
	}
	fake.err, fake.inst = nil, api.inst
	if why := pageAWSVerdict(ctx, slog.New(slog.DiscardHandler), in, t0.Add(pageAWSRetry+time.Second)); why != "" || fake.calls == n {
		t.Errorf("after the back-off: %q, want the block kept on the provider's answer", why)
	}
	n = fake.calls
	if why := pageAWSVerdict(ctx, slog.New(slog.DiscardHandler), in, t0.Add(48*time.Hour)); why != "" || fake.calls != n {
		t.Errorf("a cached verdict: %q after %d more call(s), want no call", why, fake.calls-n)
	}
	moved := in
	moved.PageAWSHost = "db1.zz9theirs1.us-east-2.rds.amazonaws.com"
	if why := pageAWSVerdict(ctx, slog.New(slog.DiscardHandler), moved, t0.Add(48*time.Hour)); why == "" || fake.calls == n {
		t.Errorf("a new host: %q, want a new check and the block refused", why)
	}
}

// nestedPageRDS is two checks of one block at once, in one goroutine: its first DescribeDBInstances runs a second
// pageAWSVerdict (the parallel check, which reads the empty cache too and gets the provider's answer), then fails
// (a throttle or a credential refresh) - the order a collector's first runs of a new instance can meet.
type nestedPageRDS struct {
	*fakePageRDS
	inner func()
	err   error
	n     int
}

func (f *nestedPageRDS) DescribeDBInstances(ctx context.Context, in *rds.DescribeDBInstancesInput, o ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	f.n++
	if f.n == 1 {
		f.inner()
		return nil, f.err
	}
	return f.fakePageRDS.DescribeDBInstances(ctx, in, o...)
}

// B24p review 20261115-094955 finding 6: a check that fails while a parallel check of the same block and host keeps
// it never replaces the kept verdict with a 5-minute refusal - an AWS error is no verdict, a verdict stands.
func TestPageAWSVerdictParallel(t *testing.T) {
	ctx := context.Background()
	own := "db1.c9akciq32.us-east-2.rds.amazonaws.com"
	base := &fakePageRDS{inst: map[string]rdstypes.DBInstance{"db1": {DBInstanceIdentifier: aws.String("db1"), Endpoint: &rdstypes.Endpoint{Address: aws.String(own)}}}}
	in := config.Instance{Name: "pg-cloud", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1"}, PageAWSHost: own}
	t0 := time.Date(2026, 11, 15, 3, 0, 0, 0, time.UTC)
	log := slog.New(slog.DiscardHandler)
	var innerWhy string
	api := &nestedPageRDS{fakePageRDS: base, err: errors.New("operation error RDS: DescribeDBInstances, https response error StatusCode: 400, api error Throttling: Rate exceeded")}
	api.inner = func() { innerWhy = pageAWSVerdict(ctx, log, in, t0) }
	was := newPageAWSAPI
	defer func() { newPageAWSAPI = was; resetPageAWSVerdicts() }()
	newPageAWSAPI = func(context.Context, config.AWS) (pageAWSAPI, error) { return api, nil }
	resetPageAWSVerdicts()
	outerWhy := pageAWSVerdict(ctx, log, in, t0)
	if innerWhy != "" {
		t.Fatalf("the parallel check: %q, want the block kept on the provider's answer", innerWhy)
	}
	if outerWhy != "" {
		t.Errorf("the check that met the throttle after the parallel one kept the block: %q, want the kept verdict", outerWhy)
	}
	n := api.n
	if why := pageAWSVerdict(ctx, log, in, t0.Add(time.Minute)); why != "" || api.n != n {
		t.Errorf("the next run a minute later: %q after %d call(s), want the kept verdict from the cache and no call (a failed check stored over it)", why, api.n-n)
	}
}
