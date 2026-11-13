package discover

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// fakeRDS answers one region: its clusters, its instances in pages (a Marker per page), the partition's regions
// (DescribeSourceRegions; srcErr refuses it), or err.
type fakeRDS struct {
	clusters []rdstypes.DBCluster
	pages    [][]rdstypes.DBInstance
	sources  []string
	srcErr   error
	err      error
}

func (f fakeRDS) DescribeSourceRegions(context.Context, *rds.DescribeSourceRegionsInput, ...func(*rds.Options)) (*rds.DescribeSourceRegionsOutput, error) {
	if f.srcErr != nil {
		return nil, f.srcErr
	}
	out := &rds.DescribeSourceRegionsOutput{}
	for _, r := range f.sources {
		out.SourceRegions = append(out.SourceRegions, rdstypes.SourceRegion{RegionName: aws.String(r), Status: aws.String("available")})
	}
	return out, nil
}

// pagedSources answers DescribeSourceRegions in pages (a Marker per page) and records the region asked
type pagedSources struct {
	fakeRDS
	region string
	pages  [][]string
	calls  *[]string
	mu     *sync.Mutex
}

func (f pagedSources) DescribeSourceRegions(_ context.Context, in *rds.DescribeSourceRegionsInput, _ ...func(*rds.Options)) (*rds.DescribeSourceRegionsOutput, error) {
	f.mu.Lock()
	*f.calls = append(*f.calls, f.region)
	f.mu.Unlock()
	if f.srcErr != nil {
		return nil, f.srcErr
	}
	i := 0
	if in.Marker != nil {
		_, _ = fmt.Sscan(*in.Marker, &i)
	}
	out := &rds.DescribeSourceRegionsOutput{}
	for _, r := range f.pages[i] {
		out.SourceRegions = append(out.SourceRegions, rdstypes.SourceRegion{RegionName: aws.String(r)})
	}
	if i+1 < len(f.pages) {
		out.Marker = aws.String(fmt.Sprint(i + 1))
	}
	return out, nil
}

// lab is the stand-in identity: an account of the commercial partition
func lab(context.Context) (string, string, error) { return "111122223333", "aws", nil }

func (f fakeRDS) DescribeDBClusters(context.Context, *rds.DescribeDBClustersInput, ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	if f.err != nil {
		return nil, f.err
	}
	return &rds.DescribeDBClustersOutput{DBClusters: f.clusters}, nil
}

func (f fakeRDS) DescribeDBInstances(_ context.Context, in *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	if len(f.pages) == 0 {
		return &rds.DescribeDBInstancesOutput{}, nil
	}
	i := 0
	if in.Marker != nil {
		_, _ = fmt.Sscan(*in.Marker, &i)
	}
	out := &rds.DescribeDBInstancesOutput{DBInstances: f.pages[i]}
	if i+1 < len(f.pages) {
		out.Marker = aws.String(fmt.Sprint(i + 1))
	}
	return out, nil
}

// silentRDS stands in for a region whose endpoint never answers: each call waits for its context
type silentRDS struct{}

func (silentRDS) DescribeDBClusters(ctx context.Context, _ *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	<-ctx.Done()
	return nil, fmt.Errorf("operation error RDS: DescribeDBClusters, https response error: dial tcp 99.82.136.55:443: %w", ctx.Err())
}

func (silentRDS) DescribeDBInstances(ctx context.Context, _ *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func (silentRDS) DescribeSourceRegions(ctx context.Context, _ *rds.DescribeSourceRegionsInput, _ ...func(*rds.Options)) (*rds.DescribeSourceRegionsOutput, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func member(id string, w bool) rdstypes.DBClusterMember {
	return rdstypes.DBClusterMember{DBInstanceIdentifier: aws.String(id), IsClusterWriter: aws.Bool(w)}
}

func inst(id, engine, cluster, addr string, port int32) rdstypes.DBInstance {
	in := rdstypes.DBInstance{DBInstanceIdentifier: aws.String(id), Engine: aws.String(engine), DbiResourceId: aws.String("db-" + strings.ToUpper(id)),
		DBInstanceClass: aws.String("db.r6g.large"), DBInstanceStatus: aws.String("available")}
	if cluster != "" {
		in.DBClusterIdentifier = aws.String(cluster)
	}
	if addr != "" {
		in.Endpoint = &rdstypes.Endpoint{Address: aws.String(addr), Port: aws.Int32(port)}
	}
	return in
}

func TestAWSProposesEachInstanceByItsOwnEndpoint(t *testing.T) {
	pgA1 := inst("pg-a-1", "aurora-postgresql", "pg-a", "pg-a-1.x", 5432)
	pgA1.DBInstanceClass = aws.String("db.serverless")
	sql1 := inst("sql1", "sqlserver-se", "", "sql1.x", 1433)
	sql1.MasterUsername = aws.String("admin")
	pgi := inst("pgi", "postgres", "", "pgi.x", 5433)
	pgi.DBName, pgi.MasterUsername = aws.String("app"), aws.String("pgadmin")
	pgi.TagList = []rdstypes.Tag{{Key: aws.String("Env"), Value: aws.String("prod, eu")}, {Key: aws.String("tag"), Value: aws.String("x")}, {Key: aws.String("Region"), Value: aws.String("evil")}}
	rr := inst("pgi-rr", "postgres", "", "pgi-rr.x", 5432)
	rr.ReadReplicaSourceDBInstanceIdentifier = aws.String("arn:aws:rds:us-east-2:111122223333:db:pgi")
	crr := inst("maz-rr", "postgres", "", "maz-rr.x", 5432) // a replica of a Multi-AZ DB cluster
	crr.ReadReplicaSourceDBClusterIdentifier = aws.String("arn:aws:rds:us-east-2:111122223333:cluster:maz")
	pending := inst("pending", "postgres", "", "", 0)
	pending.DBInstanceStatus = aws.String("creating")
	east := fakeRDS{
		clusters: []rdstypes.DBCluster{
			{DBClusterIdentifier: aws.String("pg-a"), Engine: aws.String("aurora-postgresql"), Endpoint: aws.String("pg-a.cluster-x"), ReaderEndpoint: aws.String("pg-a.cluster-ro-x"),
				MasterUsername: aws.String("postgres"), DatabaseName: aws.String("appdb"), DBClusterMembers: []rdstypes.DBClusterMember{member("pg-a-1", true), member("pg-a-2", false)},
				ServerlessV2ScalingConfiguration: &rdstypes.ServerlessV2ScalingConfigurationInfo{MinCapacity: aws.Float64(0), MaxCapacity: aws.Float64(4), SecondsUntilAutoPause: aws.Int32(300)},
				TagList:                          []rdstypes.Tag{{Key: aws.String("Team"), Value: aws.String("dba")}}},
			// a Multi-AZ DB cluster (engine postgres): each member by its own endpoint, never the cluster's reader endpoint
			{DBClusterIdentifier: aws.String("maz"), Engine: aws.String("postgres"), Endpoint: aws.String("maz.cluster-x"), ReaderEndpoint: aws.String("maz.cluster-ro-x"),
				DBClusterMembers: []rdstypes.DBClusterMember{member("maz-1", true), member("maz-2", false), member("maz-3", false)}},
			{DBClusterIdentifier: aws.String("my-a"), Engine: aws.String("aurora-mysql"), DBClusterMembers: []rdstypes.DBClusterMember{member("my-a-1", true)}},
			{DBClusterIdentifier: aws.String("empty"), Engine: aws.String("aurora-postgresql")},
		},
		pages: [][]rdstypes.DBInstance{
			{pgA1, inst("pg-a-2", "aurora-postgresql", "pg-a", "pg-a-2.x", 5432), sql1},
			{ // the second page: a paging fault would drop it
				pgi, rr, crr, inst("maz-1", "postgres", "maz", "maz-1.x", 5432), inst("maz-2", "postgres", "maz", "maz-2.x", 5432), inst("maz-3", "postgres", "maz", "maz-3.x", 5432),
				inst("my-a-1", "aurora-mysql", "my-a", "my-a-1.x", 3306), inst("ora1", "oracle-ee", "", "ora1.x", 1521), pending,
			},
		},
	}
	o := AWSOptions{Regions: []string{"us-east-2", "ap-east-2", "us-east-1", "me-south-1", "us-gov-west-1"}, identity: lab, callWait: 100 * time.Millisecond,
		client: func(_ context.Context, r string) (rdsAPI, error) {
			switch r {
			case "us-east-2":
				return east, nil
			case "ap-east-2", "us-gov-west-1": // not enabled, or of another partition: a token error either way
				return fakeRDS{err: errors.New("operation error RDS: DescribeDBClusters, https response error StatusCode: 403, api error InvalidClientTokenId: The security token included in the request is invalid")}, nil
			case "us-east-1":
				return fakeRDS{err: errors.New("operation error RDS: DescribeDBClusters, https response error StatusCode: 403, api error AccessDenied: User is not authorized to perform: rds:DescribeDBClusters with an explicit deny in a service control policy")}, nil
			case "me-south-1":
				return silentRDS{}, nil
			}
			return fakeRDS{}, nil
		}}
	rd, err := AWS(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	pre := "aws:111122223333:us-east-2:instance:"
	var keys []string
	byKey := map[string]config.Proposal{}
	for _, p := range rd.Proposals {
		keys = append(keys, strings.TrimPrefix(p.Server, pre)+"|"+p.Host+"|"+strings.Join(p.Tags, ","))
		byKey[strings.TrimPrefix(p.Server, pre)] = p
	}
	// the platform the approve gives the instance (the join's review 3e): Aurora's engines aurora, RDS's rds (a Multi-AZ
	// DB cluster's members too, and SQL Server)
	for id, want := range map[string]string{"pg-a-1": "aurora", "pg-a-2": "aurora", "maz-1": "rds", "sql1": "rds"} {
		if got := byKey[id].Platform; got != want {
			t.Errorf("%s: platform %q, want %q", id, got, want)
		}
	}
	base := "account:111122223333,cloud:aws,"
	want := []string{
		"maz-1|maz-1.x|" + base + "cluster:maz,region:us-east-2,role:writer",
		"maz-2|maz-2.x|" + base + "cluster:maz,region:us-east-2,role:reader",
		"maz-3|maz-3.x|" + base + "cluster:maz,region:us-east-2,role:reader",
		"maz-rr|maz-rr.x|" + base + "region:us-east-2,role:replica,source-cluster:maz",
		"pg-a-1|pg-a-1.x|" + base + "cluster:pg-a,region:us-east-2,role:writer",
		"pg-a-2|pg-a-2.x|" + base + "cluster:pg-a,region:us-east-2,role:reader",
		"pgi|pgi.x|" + base + "region:us-east-2",
		"pgi-rr|pgi-rr.x|" + base + "region:us-east-2,role:replica,source-instance:pgi",
		"sql1|sql1.x|" + base + "region:us-east-2",
	}
	if strings.Join(keys, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(keys, "\n"), strings.Join(want, "\n"))
	}
	for k, w := range map[string]string{ // engine|port|database|master user|auto-pause
		"pg-a-1": "postgres|5432|appdb|postgres|true", "pg-a-2": "postgres|5432|appdb|postgres|false", "sql1": "sqlserver|1433||admin|false",
		"pgi": "postgres|5433|app|pgadmin|false", "maz-1": "postgres|5432|||false",
	} {
		p := byKey[k]
		if got := fmt.Sprintf("%s|%d|%s|%s|%v", p.Engine, p.Port, p.DBName, p.MasterUser, p.AutoPause); got != w {
			t.Fatalf("%s: %s, want %s", k, got, w)
		}
	}
	a1 := byKey["pg-a-1"]
	// no login is proposed: the master user is information only; the database and the master user from the cluster
	if a1.Login != "" || a1.MasterUser != "postgres" || a1.DBName != "appdb" || a1.ResourceID != "db-PG-A-1" || a1.Port != 5432 || a1.DisplayName != "pg-a-1 (writer)" {
		t.Fatalf("pg-a-1: %+v", a1)
	}
	if !a1.AutoPause || a1.Serverless != "Aurora Serverless v2, 0 to 4 ACU, pauses after 300 s idle" || byKey["pg-a-2"].Serverless != "" {
		t.Fatalf("serverless: %+v / %+v", a1, byKey["pg-a-2"])
	}
	if p := byKey["sql1"]; p.Engine != config.EngineSQLServer || p.MasterUser != "admin" || p.Login != "" {
		t.Fatalf("sql1: %+v", p)
	}
	// the resource's tags: none without the allow-list; an allowed key comes in, a reserved one never
	pg := byKey["pgi"]
	if got := strings.Join(TagsWith(pg, nil), " "); strings.Contains(got, "env:") {
		t.Fatalf("a tag came in with no allow-list: %s", got)
	}
	got := strings.Join(TagsWith(pg, []string{"Env", "region", "tag"}), " ")
	if !strings.Contains(got, "env:prod  eu") || strings.Contains(got, "region:evil") || strings.Contains(got, "tag:x") || strings.Count(got, "region:") != 1 {
		t.Fatalf("the allowed tags: %s", got)
	}
	for _, tg := range TagsWith(pg, []string{"env"}) {
		if _, err := config.ParseTag(tg); err != nil {
			t.Fatalf("a tag config refuses: %v", err)
		}
	}
	if strings.Join(rd.TagKeys, " ") != "env team" {
		t.Fatalf("tag keys seen %v (want env team: 'tag' and the reserved 'region' left out)", rd.TagKeys)
	}
	wantNotes := []string{
		"ap-east-2: not enabled for these credentials, or not a region of their partition (aws)",
		"me-south-1: not reachable (no answer within 100ms)",
		"us-east-1: not allowed for these credentials (AccessDenied)",
		"us-east-2 cluster empty: no instance (nothing to propose)",
		"us-east-2 instance pending: no endpoint yet (creating)",
		"us-gov-west-1: not enabled for these credentials, or not a region of their partition (aws)",
	}
	if strings.Join(rd.Notes, "\n") != strings.Join(wantNotes, "\n") {
		t.Fatalf("notes\n%s\nwant\n%s", strings.Join(rd.Notes, "\n"), strings.Join(wantNotes, "\n"))
	}
	u := "aws:111122223333:"
	if got := strings.Join(rd.Unseen, " "); got != u+"ap-east-2: "+u+"me-south-1: "+u+"us-east-1: "+u+"us-gov-west-1:" {
		t.Fatalf("unseen %q", got)
	}
	// kept: the regions that answered and the silent one (its servers unseen); never one that refused
	if strings.Join(rd.Regions, " ") != "me-south-1 us-east-2" || rd.Partition != "aws" {
		t.Fatalf("regions kept %v, partition %q", rd.Regions, rd.Partition)
	}
}

func TestAWSPartitionComesFromTheIdentityARN(t *testing.T) {
	for arn, want := range map[string]string{
		"arn:aws:sts::111122223333:assumed-role/r/s": "aws", "arn:aws-us-gov:sts::123:assumed-role/r/s": "aws-us-gov",
		"arn:aws-cn:iam::123:user/u": "aws-cn", "not-an-arn": "",
	} {
		got, err := partitionOf(arn)
		if got != want || (want == "") != (err != nil) {
			t.Fatalf("%s: %q %v, want %q", arn, got, err, want)
		}
	}
}

func TestAWSSweepsFromTheConfiguredRegion(t *testing.T) {
	calls := map[string]int{}
	var mu sync.Mutex
	var srcCalls []string
	mk := func(srcErr error) func(context.Context, string) (rdsAPI, error) {
		return func(_ context.Context, r string) (rdsAPI, error) {
			mu.Lock()
			calls[r]++
			mu.Unlock()
			if r == "ap-east-2" {
				return fakeRDS{err: errors.New("api error InvalidClientTokenId: invalid"), srcErr: srcErr}, nil
			}
			return pagedSources{fakeRDS: fakeRDS{srcErr: srcErr}, region: r, calls: &srcCalls, mu: &mu,
				pages: [][]string{{"eu-west-1"}, {"ap-east-2"}}}, nil // the seed itself not in the answer; two pages
		}
	}
	// the partition's regions from the seed (the seed added); the ones that answered come back for the source to keep
	rd, err := AWS(context.Background(), AWSOptions{seed: "us-east-2", identity: lab, client: mk(nil)})
	if err != nil || !rd.Swept || strings.Join(rd.Regions, " ") != "eu-west-1 us-east-2" ||
		!strings.Contains(strings.Join(rd.Notes, " "), "rds:DescribeSourceRegions in us-east-2: 3 regions (us-east-2 and those RDS there lists as its replication sources), each read") {
		t.Fatalf("a sweep: %v regions %v notes %v", err, rd.Regions, rd.Notes)
	}
	// DescribeSourceRegions asked in the seed only (both pages); each region read once, the seed's client made for both
	if strings.Join(srcCalls, " ") != "us-east-2 us-east-2" || calls["eu-west-1"] != 1 || calls["ap-east-2"] != 1 || calls["us-east-2"] != 2 {
		t.Fatalf("the calls: sources %v, clients %v", srcCalls, calls)
	}
	// DescribeSourceRegions refused: the seed and the kept regions read, nothing new swept (the source keeps its list)
	rd, err = AWS(context.Background(), AWSOptions{seed: "us-east-2", Keep: []string{"eu-west-1"}, identity: lab, client: mk(errors.New("api error AccessDenied: no"))})
	if err != nil || rd.Swept || strings.Join(rd.Regions, " ") != "eu-west-1 us-east-2" ||
		!strings.Contains(strings.Join(rd.Notes, " "), "us-east-2 and 1 region(s) the source kept read, nothing new swept") {
		t.Fatalf("a sweep without DescribeSourceRegions: %v swept %v regions %v notes %v", err, rd.Swept, rd.Regions, rd.Notes)
	}
	// no configured region: the sweep starts from the source's first kept region
	srcCalls = nil
	if rd, err = AWS(context.Background(), AWSOptions{Start: "eu-west-1", identity: lab, client: mk(nil)}); err != nil || !rd.Swept || len(srcCalls) == 0 || srcCalls[0] != "eu-west-1" {
		t.Fatalf("a sweep from Start: %v swept %v asked in %v", err, rd.Swept, srcCalls)
	}
	// no seed and no region named: nothing to start from
	if _, err := AWS(context.Background(), AWSOptions{identity: lab, client: mk(nil)}); err == nil || !strings.Contains(err.Error(), "no AWS region") {
		t.Fatalf("no region at all: %v", err)
	}
	// the identity refused: the read fails before any region
	if _, err := AWS(context.Background(), AWSOptions{seed: "us-east-2", client: mk(nil), identity: func(context.Context) (string, string, error) {
		return "", "", errors.New("api error InvalidClientTokenId: the security token is invalid")
	}}); err == nil || !strings.Contains(err.Error(), "sts:GetCallerIdentity") {
		t.Fatalf("the identity refused: %v", err)
	}
	// a GovCloud identity names its own partition in the region notes (NOT PROVEN live: no GovCloud account)
	rd, err = AWS(context.Background(), AWSOptions{Regions: []string{"us-gov-west-1", "ap-east-2"}, client: mk(nil),
		identity: func(context.Context) (string, string, error) { return "123", "aws-us-gov", nil }})
	if err != nil || !strings.Contains(strings.Join(rd.Notes, " "), "ap-east-2: not enabled for these credentials, or not a region of their partition (aws-us-gov)") ||
		len(rd.Proposals) > 0 || strings.Join(rd.Unseen, " ") != "aws:123:ap-east-2:" {
		t.Fatalf("a GovCloud identity: %v notes %v unseen %v", err, rd.Notes, rd.Unseen)
	}
}

func TestAWSFailsWhenNothingIsRead(t *testing.T) {
	one := func(err error) func(context.Context, string) (rdsAPI, error) {
		return func(context.Context, string) (rdsAPI, error) { return fakeRDS{err: err}, nil }
	}
	// every region refused by policy
	if _, err := AWS(context.Background(), AWSOptions{Regions: []string{"ap-east-2"}, identity: lab, client: one(errors.New("api error AccessDenied: no"))}); err == nil {
		t.Fatal("every region refused was not an error")
	}
	// a credential fault in every region: said once, never as region refusals
	assume := errors.New("operation error RDS: DescribeDBClusters, get identity: get credentials: failed to refresh cached credentials, operation error STS: AssumeRole, https response error StatusCode: 403, api error AccessDenied: User: arn:aws:iam::1:user/u is not authorized to perform: sts:AssumeRole")
	_, err := AWS(context.Background(), AWSOptions{Regions: []string{"us-east-1", "ap-east-2", "eu-west-1"}, identity: lab, client: one(assume)})
	if err == nil || strings.Count(err.Error(), "sts:AssumeRole") != 1 || strings.Contains(err.Error(), "not allowed") {
		t.Fatalf("a refused AssumeRole: %v", err)
	}
	// every region answering a token error after the identity answered: not enabled (or another partition), said per
	// region, and the read fails as nothing was read (a bad key fails earlier, at sts:GetCallerIdentity)
	bad := errors.New("operation error RDS: DescribeDBClusters, https response error StatusCode: 403, api error InvalidClientTokenId: The security token included in the request is invalid")
	_, err = AWS(context.Background(), AWSOptions{Regions: []string{"us-east-2", "ap-east-2"}, identity: lab, client: one(bad)})
	if err == nil || err.Error() != "no region could be read: each of the 2 regions: not enabled for these credentials, or not a region of their partition (aws)" {
		t.Fatalf("every region a token error: %v", err)
	}
	// every region silent
	_, err = AWS(context.Background(), AWSOptions{Regions: []string{"us-east-2", "eu-west-1"}, identity: lab, callWait: 50 * time.Millisecond,
		client: func(context.Context, string) (rdsAPI, error) { return silentRDS{}, nil }})
	if err == nil || !strings.Contains(err.Error(), "not reachable") {
		t.Fatalf("every region silent: %v", err)
	}
	// the read cut by its caller after one region answered: an error, never a partial list
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	_, err = AWS(ctx, AWSOptions{Regions: []string{"us-east-2", "eu-west-1"}, identity: lab, callWait: 5 * time.Second, client: func(_ context.Context, r string) (rdsAPI, error) {
		if r == "us-east-2" {
			return fakeRDS{}, nil
		}
		return silentRDS{}, nil
	}})
	if err == nil || !strings.Contains(err.Error(), "the AWS read was cut") {
		t.Fatalf("a cut read: %v", err)
	}
}

func TestCloudTagCutsAtACharacter(t *testing.T) {
	tg := cloudTag("Owner", strings.Repeat("a", 99)+"é")
	if !utf8.ValidString(tg) {
		t.Fatalf("the cut left a broken character: %q", tg)
	}
	if _, err := config.ParseTag(tg); err != nil {
		t.Fatalf("config refuses %q: %v", tg, err)
	}
}

const (
	subA = "0b0b0b0b-1111-2222-3333-444444444444"
	subB = "0c0c0c0c-1111-2222-3333-444444444444"
)

func TestAzureReadsResourceGraphPagesAndMapsTypes(t *testing.T) {
	var mainCalls, wantSubs atomic.Int32
	var limitHit atomic.Bool
	var lastScope, lastResource atomic.Value
	lastScope.Store("")
	lastResource.Store("")
	wantSubs.Store(1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/t/oauth2/v2.0/token":
			_ = r.ParseForm()
			f := r.Form
			lastScope.Store(f.Get("scope"))
			if f.Get("grant_type") != "client_credentials" || f.Get("client_id") != "c" || (f.Get("scope") != "https://management.azure.com/.default" && f.Get("scope") != "https://management.usgovcloudapi.net/.default") {
				w.WriteHeader(400)
				_, _ = io.WriteString(w, `{"error":"invalid_request","error_description":"AADSTS900144: the request was not the client credentials grant"}`)
				return
			}
			if f.Get("client_secret") != "s3cret" {
				w.WriteHeader(401)
				_, _ = io.WriteString(w, `{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided.\r\nTrace ID: x"}`)
				return
			}
			_, _ = io.WriteString(w, `{"access_token":"tok-1"}`)
		case "/metadata/identity/oauth2/token":
			q := r.URL.Query()
			lastResource.Store(q.Get("resource"))
			if r.Header.Get("Metadata") != "true" || q.Get("api-version") != "2018-02-01" || q.Get("resource") != "https://management.chinacloudapi.cn/" && q.Get("resource") != "https://management.azure.com/" || q.Get("client_id") != "uai" {
				w.WriteHeader(400)
				return
			}
			_, _ = io.WriteString(w, `{"access_token":"tok-1"}`)
		case "/providers/Microsoft.ResourceGraph/resources":
			if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer tok-1" {
				w.WriteHeader(401)
				return
			}
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			if q, _ := body["query"].(string); strings.HasPrefix(q, "resources\n") { // the servers' query, not resourcecontainers
				for _, path := range []string{"properties.administrators.azureADOnlyAuthentication", "properties.authConfig.passwordAuth", "properties.autoPauseDelay", "properties.databaseId", "properties.dnsZone"} {
					if !strings.Contains(q, path) {
						t.Errorf("the query does not read %s", path)
					}
				}
			}
			if strings.HasPrefix(body["query"].(string), "resourcecontainers") { // only subA is readable
				if limitHit.Load() {
					w.Header().Set("x-ms-tenant-subscription-limit-hit", "true")
				}
				_, _ = io.WriteString(w, `{"data":[{"subscriptionId":"`+subA+`","state":"Enabled"}]}`)
				return
			}
			switch mainCalls.Add(1) {
			case 1: // the per-user quota: asked again once after the reset
				w.Header().Set("x-ms-user-quota-resets-after", "00:00:00.2")
				w.WriteHeader(429)
				_, _ = io.WriteString(w, `{"error":{"code":"RateLimiting","message":"Please provide below info when asking for support","details":[{"code":"RateLimiting","message":"Client application has been throttled"}]}}`)
			case 2:
				if subs, _ := body["subscriptions"].([]any); len(subs) != int(wantSubs.Load()) {
					t.Errorf("the subscriptions were not sent: %v", body["subscriptions"])
				}
				_, _ = io.WriteString(w, `{"data":[
 {"id":"/subscriptions/`+subA+`/resourceGroups/rg1/providers/Microsoft.Sql/servers/sqlsrv/databases/appdb","name":"appdb","type":"microsoft.sql/servers/databases","kind":"v12.0,user","aadOnly":true,"location":"westus3","subscriptionId":"`+subA+`","resourceGroup":"rg1","tags":{"Team":"billing","Pool":"fake"},"elasticPoolId":"/subscriptions/`+subA+`/resourceGroups/rg1/providers/Microsoft.Sql/servers/sqlsrv/elasticPools/Pool-A","fqdn":"sqlsrv.database.windows.net"},
 {"id":"/subscriptions/`+subA+`/resourceGroups/rg1/providers/Microsoft.Sql/servers/sqlsrv/databases/otherdb","name":"otherdb","type":"microsoft.sql/servers/databases","kind":"v12.0,user,vcore,serverless","autoPauseDelay":60,"skuName":"GP_S_Gen5_1","location":"westus3","subscriptionId":"`+subA+`","resourceGroup":"rg1","fqdn":"sqlsrv.database.windows.net"},
 {"id":"/subscriptions/`+subA+`/resourceGroups/rg1/providers/Microsoft.Sql/servers/sqlsrv/databases/dw1","name":"dw1","type":"microsoft.sql/servers/databases","kind":"v12.0,user,datawarehouse,gen2","location":"westus3","subscriptionId":"`+subA+`","resourceGroup":"rg1","fqdn":"sqlsrv.database.windows.net"},
 {"id":"/subscriptions/`+subA+`/resourceGroups/rg1/providers/Microsoft.DBforPostgreSQL/flexibleServers/pgf","name":"pgf","type":"microsoft.dbforpostgresql/flexibleservers","passwordAuth":"Disabled","location":"westus3","subscriptionId":"`+subA+`","resourceGroup":"rg1","tags":null,"fqdn":"pgf.postgres.database.azure.com"}],
 "$skipToken":"next"}`)
			default:
				if body["options"].(map[string]any)["$skipToken"] != "next" {
					t.Errorf("the second page was not asked with the skip token")
				}
				_, _ = io.WriteString(w, `{"data":[
 {"id":"/subscriptions/`+subA+`/resourceGroups/rg2/providers/Microsoft.Sql/managedInstances/mi1","name":"mi1","type":"microsoft.sql/managedinstances","location":"eastus","subscriptionId":"`+subA+`","resourceGroup":"rg2","fqdn":"mi1.abc.database.windows.net"},
 {"id":"/subscriptions/`+subA+`/resourceGroups/rg2/providers/Microsoft.Sql/managedInstances/mi2","name":"mi2","type":"microsoft.sql/managedinstances","location":"eastus","subscriptionId":"`+subA+`","resourceGroup":"rg2","fqdn":""}]}`)
			}
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	o := AzureOptions{Subscriptions: []string{subA}, TenantID: "t", ClientID: "c", ClientSecret: "s3cret", ARM: srv.URL, Login: srv.URL}
	rd, err := Azure(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	var keys []string
	byKey := map[string]config.Proposal{}
	for _, p := range rd.Proposals {
		keys = append(keys, p.Server)
		byKey[p.Server] = p
	}
	// the key carries the subscription (a subscription not seen holds its servers); two databases of one server stay two
	pre := "azure:" + subA + ":"
	if got := strings.Join(keys, " "); got != pre+"mi:mi1 "+pre+"pg:pgf "+pre+"sql:sqlsrv/appdb "+pre+"sql:sqlsrv/otherdb" {
		t.Fatalf("keys %s", got)
	}
	if len(rd.Notes) != 2 || !strings.Contains(rd.Notes[0], "dw1: a dedicated SQL pool") || !strings.Contains(rd.Notes[1], "mi2") {
		t.Fatalf("notes %v", rd.Notes)
	}
	db := byKey[pre+"sql:sqlsrv/appdb"]
	tags := strings.Join(db.Tags, " ")
	// the resource's own tags only through an allow-list: not in Tags, kept aside
	if db.Engine != config.EngineSQLServer || db.Host != "sqlsrv.database.windows.net" || db.DBName != "appdb" || db.Port != 1433 || strings.Contains(tags, "team:") ||
		db.CloudTags["Team"] != "billing" || !strings.Contains(tags, "subscription:"+subA) || !strings.Contains(tags, "resource-group:rg1") ||
		!strings.HasPrefix(db.ResourceID, "/subscriptions/"+subA) {
		t.Fatalf("the SQL database %+v", db)
	}
	if got := strings.Join(TagsWith(db, []string{"team"}), " "); !strings.Contains(got, "team:billing") {
		t.Fatalf("an allowed key: %s", got)
	}
	// a pooled database: pgvigil's own tag pool:<the pool's name> from its elasticPoolId (CLOUDSQL C4); a resource tag
	// 'Pool' never adds a second one (pool is reserved); a database in no pool has none
	if got := strings.Join(TagsWith(db, []string{"team", "pool"}), " "); strings.Count(got, "pool:") != 1 || !strings.Contains(got, "pool:pool-a") {
		t.Fatalf("the pooled database's tags: %s", got)
	}
	if got := strings.Join(byKey[pre+"sql:sqlsrv/otherdb"].Tags, " "); strings.Contains(got, "pool:") {
		t.Fatalf("a database in no pool: %s", got)
	}
	// a pool name the approve's tag rule would refuse (a comma) writes no tag: the read names the pool by the
	// database's own answer (the wire review's finding 8)
	if p, _ := azureProposal(azureRow{ID: "/subscriptions/" + subA + "/resourceGroups/rg1/providers/Microsoft.Sql/servers/s2/databases/d2", Name: "d2",
		Type: "microsoft.sql/servers/databases", Location: "westus3", SubscriptionID: subA, FQDN: "s2.database.windows.net",
		ElasticPoolID: "/subscriptions/" + subA + "/resourceGroups/rg1/providers/Microsoft.Sql/servers/s2/elasticPools/a,b"}); strings.Contains(strings.Join(p.Tags, " "), "pool:") {
		t.Fatalf("a pool name with a comma: %v", p.Tags)
	}
	// the Entra-only flags and a serverless database's auto-pause
	if !db.EntraOnly || !strings.Contains(db.Note, "Entra-only") {
		t.Fatalf("an Entra-only server's database: %+v", db)
	}
	if o2 := byKey[pre+"sql:sqlsrv/otherdb"]; o2.EntraOnly || !o2.AutoPause || !strings.Contains(o2.Serverless, "pauses after 60 min") {
		t.Fatalf("a serverless database: %+v", o2)
	}
	// the platform the approve gives the instance (the join's review 3e)
	for k, want := range map[string]string{"sql:sqlsrv/appdb": "azuresqldb", "sql:sqlsrv/otherdb": "azuresqldb", "mi:mi1": "azuresqlmi", "pg:pgf": "azure"} {
		if got := byKey[pre+k].Platform; got != want {
			t.Errorf("%s: platform %q, want %q", k, got, want)
		}
	}
	if pg := byKey[pre+"pg:pgf"]; pg.Engine != config.EnginePostgres || pg.Port != 5432 || pg.DBName != "postgres" || !pg.EntraOnly {
		t.Fatalf("the flexible server %+v", pg)
	}
	if strings.Join(rd.Scopes, " ") != subA || strings.Join(rd.TagKeys, " ") != "team" {
		t.Fatalf("scopes %v, tag keys %v", rd.Scopes, rd.TagKeys)
	}
	if mainCalls.Load() != 3 {
		t.Fatalf("the 429 was not asked again once: %d calls", mainCalls.Load())
	}
	// the managed identity: the metadata header, its api-version, resource and client id
	mainCalls.Store(1)
	if _, err := Azure(context.Background(), AzureOptions{Subscriptions: []string{subA}, ManagedIdentity: true, ClientID: "uai", ARM: srv.URL, IMDS: srv.URL}); err != nil {
		t.Fatalf("the managed identity: %v", err)
	}
	// another cloud: its audience in the sign-in's scope and the managed identity's resource (the hosts are the test's)
	mainCalls.Store(1)
	if _, err := Azure(context.Background(), AzureOptions{Subscriptions: []string{subA}, Cloud: "usgov", TenantID: "t", ClientID: "c", ClientSecret: "s3cret", ARM: srv.URL, Login: srv.URL}); err != nil ||
		lastScope.Load() != "https://management.usgovcloudapi.net/.default" {
		t.Fatalf("Azure Government's scope: %v (%v)", err, lastScope.Load())
	}
	mainCalls.Store(1)
	if _, err := Azure(context.Background(), AzureOptions{Subscriptions: []string{subA}, Cloud: "china", ManagedIdentity: true, ClientID: "uai", ARM: srv.URL, IMDS: srv.URL}); err != nil ||
		lastResource.Load() != "https://management.chinacloudapi.cn/" {
		t.Fatalf("Azure China's resource: %v (%v)", err, lastResource.Load())
	}
	for c, want := range map[string][2]string{"": {"https://management.azure.com", "https://login.microsoftonline.com"},
		"usgov": {"https://management.usgovcloudapi.net", "https://login.microsoftonline.us"}, "china": {"https://management.chinacloudapi.cn", "https://login.chinacloudapi.cn"}} {
		if arm, login, aud, err := azureCloud(c); err != nil || arm != want[0] || login != want[1] || aud != want[0]+"/" {
			t.Fatalf("cloud %q: %s %s %s %v", c, arm, login, aud, err)
		}
	}
	if _, err := Azure(context.Background(), AzureOptions{Cloud: "germany", Token: "x", ARM: srv.URL}); err == nil || !strings.Contains(err.Error(), "public, usgov or china") {
		t.Fatalf("an unknown cloud: %v", err)
	}
	// none named: a subscription of the last complete read missing now is unseen (its servers kept), and the
	// subscriptions kept are not replaced by this partial read
	mainCalls.Store(1)
	wantSubs.Store(0)
	rd2, err := Azure(context.Background(), AzureOptions{PrevScopes: []string{subA, subB}, TenantID: "t", ClientID: "c", ClientSecret: "s3cret", ARM: srv.URL, Login: srv.URL})
	if err != nil || strings.Join(rd2.Unseen, " ") != "azure:"+subB+":" || strings.Join(rd2.Scopes, " ") != subA+" "+subB || !strings.Contains(strings.Join(rd2.Notes, " "), subB+": seen at the last complete read") {
		t.Fatalf("a subscription no longer seen: %v unseen %v scopes %v notes %v", err, rd2.Unseen, rd2.Scopes, rd2.Notes)
	}
	// the tenant's subscription limit: the read fails
	limitHit.Store(true)
	mainCalls.Store(1)
	if _, err := Azure(context.Background(), AzureOptions{TenantID: "t", ClientID: "c", ClientSecret: "s3cret", ARM: srv.URL, Login: srv.URL}); err == nil || !strings.Contains(err.Error(), "limit-hit") {
		t.Fatalf("the subscription limit: %v", err)
	}
	limitHit.Store(false)
	wantSubs.Store(1)
	// a refused secret: its words, never the secret or the trace line
	o.ClientSecret = "wrong"
	_, err = Azure(context.Background(), o)
	if err == nil || strings.Contains(err.Error(), "wrong") || !strings.Contains(err.Error(), "AADSTS7000215") || strings.Contains(err.Error(), "Trace") {
		t.Fatalf("a refused sign-in: %v", err)
	}
	// a named subscription the identity cannot read fails the read (its servers would look gone)
	o.ClientSecret = "s3cret"
	o.Subscriptions = []string{subA, subB}
	mainCalls.Store(1)
	wantSubs.Store(2)
	if rd3, err := Azure(context.Background(), o); err != nil || strings.Join(rd3.Unseen, " ") != "azure:"+subB+":" || !strings.Contains(strings.Join(rd3.Notes, " "), subB+": named, not readable") {
		t.Fatalf("one named subscription unreadable: %v unseen %v notes %v", err, rd3.Unseen, rd3.Notes)
	}
	wantSubs.Store(1)
	o.Subscriptions = []string{subB}
	if _, err := Azure(context.Background(), o); err == nil || !strings.Contains(err.Error(), subB) {
		t.Fatalf("no named subscription readable: %v", err)
	}
	// a subscription that is not an id is refused before any call
	o.Subscriptions = []string{"Pay-As-You-Go"}
	if _, err := Azure(context.Background(), o); err == nil || !strings.Contains(err.Error(), "not a subscription id") {
		t.Fatalf("a subscription name: %v", err)
	}
}

func TestAzureErrorWordsComeFromTheDetails(t *testing.T) {
	m := apiMessage([]byte(`{"error":{"code":"BadRequest","message":"Please provide below info when asking for support: timestamp = x","details":[{"code":"InvalidQuery","message":"Query is invalid. Please refer to the documentation"}]}}`))
	if !strings.Contains(m, "InvalidQuery Query is invalid") {
		t.Fatalf("the detail was lost: %s", m)
	}
}

func TestGCPSignsAKeyListsBothAPIsAndNotesWhatItCannotSee(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	var srvURL string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			_ = r.ParseForm()
			if why := checkJWT(r.Form.Get("assertion"), &key.PublicKey, srvURL+"/token"); why != "" || r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
				w.WriteHeader(400)
				_, _ = io.WriteString(w, `{"error":"invalid_grant","error_description":"`+why+`"}`)
				return
			}
			_, _ = io.WriteString(w, `{"access_token":"gtok"}`)
		case r.Header.Get("Authorization") != "Bearer gtok":
			w.WriteHeader(401)
		case r.URL.Path == "/v1/projects/p1/instances" && r.URL.Query().Get("pageToken") == "":
			_, _ = io.WriteString(w, `{"items":[{"name":"pg16","databaseVersion":"POSTGRES_16","region":"us-west1","ipAddresses":[{"type":"PRIVATE","ipAddress":"10.0.0.5"},{"type":"PRIMARY","ipAddress":"34.1.2.3"}],"settings":{"userLabels":{"env":"dev"}}},
 {"name":"my8","databaseVersion":"MYSQL_8_0","ipAddresses":[{"type":"PRIMARY","ipAddress":"34.9.9.9"}]},
 {"name":"ext1","databaseVersion":"POSTGRES_15","instanceType":"ON_PREMISES_INSTANCE","ipAddresses":[{"type":"PRIMARY","ipAddress":"34.8.8.8"}]},
 {"name":"psc1","databaseVersion":"POSTGRES_16","region":"us-west1","dnsName":"psc1.abc.us-west1.sql.goog."},
 {"name":"rp1","databaseVersion":"POSTGRES_16","region":"us-west1","instanceType":"READ_POOL_INSTANCE","ipAddresses":[{"type":"PRIVATE","ipAddress":"10.0.0.9"}]},
 {"name":"pg16-rr","databaseVersion":"POSTGRES_16","region":"us-west1","instanceType":"READ_REPLICA_INSTANCE","masterInstanceName":"p1:pg16","selfLink":"https://x/projects/p1/instances/pg16-rr","createTime":"2026-11-01T00:00:00Z","ipAddresses":[{"type":"PRIVATE","ipAddress":"10.0.0.7"}]}],"nextPageToken":"p2"}`)
		case r.URL.Path == "/v1/projects/p1/instances":
			_, _ = io.WriteString(w, `{"items":[{"name":"ms22","databaseVersion":"SQLSERVER_2022_STANDARD","region":"us-west1","ipAddresses":[{"type":"PRIVATE","ipAddress":"10.0.0.6"}]}]}`)
		case r.URL.Path == "/v1/projects/p1/locations/-/clusters/-/instances":
			// the name carries the project's number; one location did not answer
			_, _ = io.WriteString(w, `{"instances":[{"name":"projects/123456/locations/us-central1/clusters/c1/instances/i1","uid":"u-1","ipAddress":"10.1.0.2","publicIpAddress":"35.1.1.1","instanceType":"PRIMARY"},
 {"name":"projects/123456/locations/us-central1/clusters/c1/instances/rp","ipAddress":"10.1.0.3","instanceType":"READ_POOL"}],"unreachable":["projects/p1/locations/asia-east1"]}`)
		case r.URL.Path == "/v1/projects/p7": // Cloud Resource Manager refuses: the project's number unknown
			w.WriteHeader(403)
			_, _ = io.WriteString(w, `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"no resourcemanager.projects.get"}}`)
		case strings.HasPrefix(r.URL.Path, "/v1/projects/p7/"):
			w.WriteHeader(403)
			_, _ = io.WriteString(w, `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Cloud SQL Admin API has not been used in project 777 before or it is disabled.","details":[{"reason":"SERVICE_DISABLED"}]}}`)
		case r.URL.Path == "/v1/projects/p5" || r.URL.Path == "/v1/projects/p6": // Cloud Resource Manager: the numbers
			_, _ = io.WriteString(w, map[string]string{"/v1/projects/p5": `{"projectNumber":"555"}`, "/v1/projects/p6": `{"projectNumber":"666"}`}[r.URL.Path])
		case strings.HasPrefix(r.URL.Path, "/v1/projects/p5/"): // the error names the caller's own project, not p5
			w.WriteHeader(403)
			_, _ = io.WriteString(w, `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Cloud SQL Admin API has not been used in project 999 before or it is disabled.","details":[{"reason":"SERVICE_DISABLED"}]}}`)
		case strings.HasPrefix(r.URL.Path, "/v1/projects/p6/"): // the error names p6 by its number
			w.WriteHeader(403)
			_, _ = io.WriteString(w, `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"AlloyDB API has not been used in project 666 before or it is disabled.","details":[{"reason":"SERVICE_DISABLED"}]}}`)
		case strings.HasPrefix(r.URL.Path, "/v1/projects/p2/"):
			w.WriteHeader(403)
			_, _ = io.WriteString(w, `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Cloud SQL Admin API has not been used in project p2 before or it is disabled.","details":[{"reason":"SERVICE_DISABLED"}]}}`)
		case r.URL.Path == "/v1/projects/p3/instances":
			w.WriteHeader(403)
			_, _ = io.WriteString(w, `{"error":{"code":403,"status":"PERMISSION_DENIED","message":"Request had insufficient authentication scopes.","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}`)
		case r.URL.Path == "/v1/projects/p3/locations/-/clusters/-/instances":
			<-r.Context().Done() // an API that never answers
		case r.URL.Path == "/v1/projects/p4/instances":
			_, _ = io.WriteString(w, `{}`)
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	srvURL = srv.URL
	keyJSON, _ := json.Marshal(map[string]string{"client_email": "sa@p1.iam.gserviceaccount.com", "token_uri": srv.URL + "/token",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	o := GCPOptions{Projects: []string{"p1", "p2", "p5", "p6", "p7", "p3", "p4"}, KeyJSON: string(keyJSON), SQLAdmin: srv.URL, AlloyDB: srv.URL, CRM: srv.URL, callWait: 100 * time.Millisecond}
	rd, err := GCP(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	var keys []string
	byKey := map[string]config.Proposal{}
	for _, p := range rd.Proposals {
		keys = append(keys, fmt.Sprintf("%s|%s|%s|%s|%d", p.Server, p.Engine, p.Host, p.AltHost, p.Port))
		byKey[p.Server] = p
	}
	// the private address first, the other beside it; a read pool is never proposed
	want := "gcp:p1:alloydb:us-central1/c1/i1|postgres|10.1.0.2|35.1.1.1|5432\ngcp:p1:sql:ms22|sqlserver|10.0.0.6||1433\ngcp:p1:sql:pg16|postgres|10.0.0.5|34.1.2.3|5432\n" +
		"gcp:p1:sql:pg16-rr|postgres|10.0.0.7||5432\ngcp:p1:sql:psc1|postgres|psc1.abc.us-west1.sql.goog||5432"
	if strings.Join(keys, "\n") != want {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(keys, "\n"), want)
	}
	notes := strings.Join(rd.Notes, "\n")
	for _, w := range []string{
		"p1 AlloyDB: asia-east1 not reachable",
		"p2 Cloud SQL: 403 PERMISSION_DENIED: SERVICE_DISABLED",
		"p2 AlloyDB: 403 PERMISSION_DENIED: SERVICE_DISABLED",
		"p3 Cloud SQL: 403 PERMISSION_DENIED: ACCESS_TOKEN_SCOPE_INSUFFICIENT",
		"p3 AlloyDB: not reachable (no answer within 100ms)",
		"p4 AlloyDB: not read (the API did not answer for an earlier project)",
		"p1 Cloud SQL rp1: a read pool (one address balanced over its nodes): not proposed",
		"p1 AlloyDB c1/rp: a read pool (one address balanced over its nodes): not proposed",
		"p5 Cloud SQL: SERVICE_DISABLED, but it names project 999, not p5 (555): not seen",
		"p5 AlloyDB: SERVICE_DISABLED, but it names project 999, not p5 (555): not seen",
		"p6 Cloud SQL: 403 PERMISSION_DENIED: SERVICE_DISABLED",
		"p6 AlloyDB: 403 PERMISSION_DENIED: SERVICE_DISABLED",
		"p7 Cloud SQL: SERVICE_DISABLED, but its project 777 not matched to p7 (resourcemanager.projects.get not answered): not seen",
	} {
		if !strings.Contains(notes, w) {
			t.Fatalf("no note %q in\n%s", w, notes)
		}
	}
	if len(rd.Notes) != 14 {
		t.Fatalf("notes\n%s", notes)
	}
	// a disabled API of the target project holds nothing: not unseen; one naming another project, a refused, silent
	// or partial one is
	if got := strings.Join(rd.Unseen, " "); got != "gcp:p1:alloydb: gcp:p3:alloydb: gcp:p3:sql: gcp:p4:alloydb: gcp:p5:alloydb: gcp:p5:sql: gcp:p7:alloydb: gcp:p7:sql:" {
		t.Fatalf("unseen %q", got)
	}
	// the platform the approve gives the instance (the join's review 3e): Cloud SQL's both engines cloudsql, AlloyDB alloydb
	for k, want := range map[string]string{"gcp:p1:sql:ms22": "cloudsql", "gcp:p1:sql:pg16": "cloudsql", "gcp:p1:alloydb:us-central1/c1/i1": "alloydb"} {
		if got := byKey[k].Platform; got != want {
			t.Errorf("%s: platform %q, want %q", k, got, want)
		}
	}
	rr, a1 := byKey["gcp:p1:sql:pg16-rr"], byKey["gcp:p1:alloydb:us-central1/c1/i1"]
	if strings.Join(rr.Tags, " ") != "cloud:gcp project:p1 region:us-west1 role:replica source-instance:pg16" || rr.ResourceID != "https://x/projects/p1/instances/pg16-rr@2026-11-01T00:00:00Z" {
		t.Fatalf("the replica: %+v", rr)
	}
	if a1.ResourceID != "u-1" || !strings.Contains(strings.Join(a1.Tags, " "), "cluster:c1") || !strings.Contains(strings.Join(a1.Tags, " "), "role:writer") ||
		byKey["gcp:p1:sql:pg16"].CloudTags["env"] != "dev" || strings.Contains(strings.Join(byKey["gcp:p1:sql:pg16"].Tags, " "), "env:") {
		t.Fatalf("AlloyDB i1 %+v / pg16 %+v", a1, byKey["gcp:p1:sql:pg16"])
	}
	// nothing read at all: an error, the notes kept
	o.Projects = []string{"p3"}
	rd, err = GCP(context.Background(), o)
	if err == nil || !strings.Contains(err.Error(), "no project could be read") || len(rd.Notes) != 2 {
		t.Fatalf("nothing read: %v (notes %v)", err, rd.Notes)
	}
	if _, err := GCP(context.Background(), GCPOptions{Projects: []string{"p1"}}); err == nil {
		t.Fatal("no credential was not an error")
	}
}

// checkJWT checks the service account's assertion as Google's token endpoint would: the header, each claim, the
// signature. "" = good.
func checkJWT(a string, pub *rsa.PublicKey, aud string) string {
	parts := strings.Split(a, ".")
	if len(parts) != 3 {
		return "not three parts"
	}
	var hdr map[string]string
	var cl map[string]any
	hb, _ := base64.RawURLEncoding.DecodeString(parts[0])
	cb, _ := base64.RawURLEncoding.DecodeString(parts[1])
	if json.Unmarshal(hb, &hdr) != nil || json.Unmarshal(cb, &cl) != nil {
		return "not JSON"
	}
	if hdr["alg"] != "RS256" || hdr["typ"] != "JWT" {
		return "header"
	}
	iat, _ := cl["iat"].(float64)
	exp, _ := cl["exp"].(float64)
	switch {
	case cl["iss"] != "sa@p1.iam.gserviceaccount.com":
		return "iss"
	case cl["aud"] != aud:
		return "aud"
	case cl["scope"] != "https://www.googleapis.com/auth/cloud-platform":
		return "scope"
	case exp-iat != 3600:
		return "exp"
	case time.Since(time.Unix(int64(iat), 0)).Abs() > time.Minute:
		return "iat"
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return "signature encoding"
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(pub, crypto.SHA256, sum[:], sig) != nil {
		return "signature"
	}
	return ""
}

// fakeEC2 answers ec2:DescribeRegions: each region with its opt-in status, or err
type fakeEC2 struct {
	regions map[string]string
	err     error
}

func (f fakeEC2) DescribeRegions(_ context.Context, in *ec2.DescribeRegionsInput, _ ...func(*ec2.Options)) (*ec2.DescribeRegionsOutput, error) {
	if f.err != nil {
		return nil, f.err
	}
	if !aws.ToBool(in.AllRegions) {
		return nil, errors.New("AllRegions not asked: the regions not enabled would be left out")
	}
	out := &ec2.DescribeRegionsOutput{}
	for n, st := range f.regions {
		out.Regions = append(out.Regions, ec2types.Region{RegionName: aws.String(n), OptInStatus: aws.String(st)})
	}
	return out, nil
}

// Task 205 (the lead's 12:23 item 1 and 12:28): the account's region list (ec2:DescribeRegions, optional) beside RDS's
// replication list - an enabled region outside RDS's list is swept, a region not enabled is noted and never read nor
// kept, a region of another partition is said so, a token error in an enabled region is the token's; without the
// list a standing note on every read.
func TestAWSRegionList(t *testing.T) {
	m, err := ec2Regions(context.Background(), fakeEC2{regions: map[string]string{"us-east-2": "opt-in-not-required", "af-south-1": "not-opted-in", "eu-south-2": "opted-in"}})
	if err != nil || len(m) != 3 || !m["us-east-2"] || m["af-south-1"] || !m["eu-south-2"] {
		t.Fatalf("ec2Regions: %v %v", m, err)
	}
	if _, err := ec2Regions(context.Background(), fakeEC2{regions: map[string]string{}}); err == nil {
		t.Fatal("an empty region list must not stand for the account's list")
	}
	calls := map[string]int{}
	var mu sync.Mutex
	mk := func(_ context.Context, r string) (rdsAPI, error) {
		mu.Lock()
		calls[r]++
		mu.Unlock()
		if r == "eu-south-2" || r == "af-south-1" { // a token error: eu-south-2's token, af-south-1 not enabled
			return fakeRDS{err: errors.New("operation error RDS: DescribeDBClusters, https response error StatusCode: 403, api error InvalidClientTokenId: The security token included in the request is invalid")}, nil
		}
		// RDS's replication list holds a region the account has not enabled (as the lab's does), not eu-south-2
		return fakeRDS{sources: []string{"af-south-1", "eu-west-1"}}, nil
	}
	account := map[string]string{"us-east-2": "opt-in-not-required", "eu-west-1": "opt-in-not-required", "af-south-1": "not-opted-in", "eu-south-2": "opted-in"}
	listed := func(err error) func(context.Context, string) (map[string]bool, error) {
		return func(ctx context.Context, r string) (map[string]bool, error) {
			if r != "us-east-2" {
				return nil, errors.New("the list asked in " + r + ", not the configuration's region")
			}
			if err != nil {
				return nil, err
			}
			return ec2Regions(ctx, fakeEC2{regions: account})
		}
	}
	rd, err := AWS(context.Background(), AWSOptions{seed: "us-east-2", identity: lab, client: mk, regionList: listed(nil), callWait: 100 * time.Millisecond})
	notes := strings.Join(rd.Notes, "; ")
	if err != nil || !rd.Swept || strings.Join(rd.Regions, " ") != "eu-south-2 eu-west-1 us-east-2" || calls["af-south-1"] != 0 ||
		!strings.Contains(notes, "af-south-1: not enabled for this account") || !strings.Contains(notes, "1 enabled region(s) ec2:DescribeRegions adds") ||
		!strings.Contains(notes, "eu-south-2: the token is not valid there") || strings.Contains(notes, "not checked") ||
		strings.Join(rd.Unseen, " ") != "aws:111122223333:af-south-1: aws:111122223333:eu-south-2:" {
		t.Fatalf("a sweep with the list: %v regions %v calls %v notes %v unseen %v", err, rd.Regions, calls, rd.Notes, rd.Unseen)
	}
	// a region typed from another partition: said so with the credentials' partition, never read
	rd, err = AWS(context.Background(), AWSOptions{Regions: []string{"us-east-2", "us-gov-west-1", "eusc-de-east-1"}, seed: "us-east-2", identity: lab, client: mk, regionList: listed(nil)})
	notes = strings.Join(rd.Notes, "; ")
	if err != nil || calls["us-gov-west-1"] != 0 || calls["eusc-de-east-1"] != 0 ||
		!strings.Contains(notes, "us-gov-west-1: not a region of these credentials' partition (aws)") || !strings.Contains(notes, "eusc-de-east-1: not a region of these credentials' partition (aws)") ||
		strings.Join(rd.Regions, " ") != "us-east-2" || strings.Join(rd.Unseen, " ") != "aws:111122223333:eusc-de-east-1: aws:111122223333:us-gov-west-1:" {
		t.Fatalf("regions of another partition: %v calls %v notes %v regions %v unseen %v", err, calls, rd.Notes, rd.Regions, rd.Unseen)
	}
	// the list refused, or silent: the standing note, and the sweep as without it (RDS's list and the seed)
	for _, c := range []struct {
		err  error
		want string
	}{
		{errors.New("operation error EC2: DescribeRegions, https response error StatusCode: 403, api error UnauthorizedOperation: You are not authorized to perform this operation"), "ec2:DescribeRegions not granted (UnauthorizedOperation): the account's enabled regions were not checked: a region outside RDS's replication list is not read"},
		{errors.New("operation error EC2: DescribeRegions, dial tcp 127.0.0.1:1: connect: connection refused"), "ec2:DescribeRegions not answered (operation error EC2: DescribeRegions, dial tcp 127.0.0.1:1: connect: connection refused): the account's enabled regions were not checked"},
	} {
		rd, err = AWS(context.Background(), AWSOptions{seed: "us-east-2", identity: lab, client: mk, regionList: listed(c.err)})
		notes = strings.Join(rd.Notes, "; ")
		if err != nil || !rd.Swept || !strings.Contains(notes, c.want) || !strings.Contains(notes, "af-south-1: not enabled for these credentials, or not a region of their partition (aws)") ||
			strings.Contains(strings.Join(rd.Regions, " "), "eu-south-2") {
			t.Fatalf("the list %v: %v regions %v notes %v", c.err, err, rd.Regions, rd.Notes)
		}
	}
	silent := func(ctx context.Context, _ string) (map[string]bool, error) { <-ctx.Done(); return nil, ctx.Err() }
	rd, err = AWS(context.Background(), AWSOptions{Regions: []string{"us-east-2"}, seed: "us-east-2", identity: lab, client: mk, regionList: silent, callWait: 50 * time.Millisecond})
	if err != nil || !strings.Contains(strings.Join(rd.Notes, "; "), "ec2:DescribeRegions not answered within 50ms: the account's enabled regions were not checked") {
		t.Fatalf("the list silent: %v notes %v", err, rd.Notes)
	}
}

// TestAWSSkipSilent (task 205 D5): a kept region silent at an earlier read is not asked by a read that is not a
// sweep: no call, its servers unseen (never gone), kept, not among Asked; a read whose every region is skipped fails
// and says how to ask them again.
func TestAWSSkipSilent(t *testing.T) {
	calls := map[string]int{}
	var mu sync.Mutex
	mk := func(_ context.Context, r string) (rdsAPI, error) {
		mu.Lock()
		calls[r]++
		mu.Unlock()
		return fakeRDS{}, nil
	}
	rd, err := AWS(context.Background(), AWSOptions{Regions: []string{"me-south-1", "us-east-2"}, Skip: []string{"me-south-1"}, seed: "us-east-2", identity: lab, client: mk})
	if err != nil || calls["me-south-1"] != 0 || calls["us-east-2"] == 0 || strings.Join(rd.Asked, " ") != "us-east-2" ||
		strings.Join(rd.Regions, " ") != "me-south-1 us-east-2" || strings.Join(rd.Unseen, " ") != "aws:111122223333:me-south-1:" {
		t.Fatalf("a silent region skipped: %v calls %v asked %v regions %v unseen %v", err, calls, rd.Asked, rd.Regions, rd.Unseen)
	}
	rd, err = AWS(context.Background(), AWSOptions{Regions: []string{"me-south-1"}, Skip: []string{"me-south-1"}, seed: "us-east-2", identity: lab, client: mk})
	if err == nil || !strings.Contains(err.Error(), "Read the regions again") || calls["me-south-1"] != 0 || strings.Join(rd.Unseen, " ") != "aws:111122223333:me-south-1:" {
		t.Fatalf("every region skipped: %v calls %v unseen %v", err, calls, rd.Unseen)
	}
}

// signalSources answers DescribeSourceRegions after closing asked (a region list waiting on asked answers only when
// the two are asked at once)
type signalSources struct {
	fakeRDS
	asked chan struct{}
	once  *sync.Once
}

func (f signalSources) DescribeSourceRegions(ctx context.Context, in *rds.DescribeSourceRegionsInput, opts ...func(*rds.Options)) (*rds.DescribeSourceRegionsOutput, error) {
	f.once.Do(func() { close(f.asked) })
	return f.fakeRDS.DescribeSourceRegions(ctx, in, opts...)
}

// TestAWSRegionListFold (task 205's review, part a): the account's list is asked beside RDS's replication list, within
// its own shorter wait; its answer comes before Skip; the region it (and STS) is sent to is never a skipped one; a read
// that reads no region keeps Asked (a lone silent region starts D5) and says the regions it skipped; RDS's list
// refused with the account's list answered still sweeps.
func TestAWSRegionListFold(t *testing.T) {
	ctx := context.Background()
	account := map[string]string{"us-east-2": "opt-in-not-required", "eu-west-1": "opt-in-not-required", "me-south-1": "not-opted-in"}
	var mu sync.Mutex
	calls := map[string]int{}
	var listAt []string
	list := func(wait chan struct{}) func(context.Context, string) (map[string]bool, error) {
		return func(ctx context.Context, r string) (map[string]bool, error) {
			mu.Lock()
			listAt = append(listAt, r)
			mu.Unlock()
			if wait != nil {
				select {
				case <-wait:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
			}
			return ec2Regions(ctx, fakeEC2{regions: account})
		}
	}
	count := func(r string) {
		mu.Lock()
		calls[r]++
		mu.Unlock()
	}
	// the list answers only once DescribeSourceRegions was asked: asked one after the other it would time out
	asked, once := make(chan struct{}), &sync.Once{}
	mk := func(_ context.Context, r string) (rdsAPI, error) {
		count(r)
		return signalSources{fakeRDS: fakeRDS{sources: []string{"eu-west-1"}}, asked: asked, once: once}, nil
	}
	rd, err := AWS(ctx, AWSOptions{seed: "us-east-2", identity: lab, client: mk, regionList: list(asked), callWait: 2 * time.Second})
	notes := strings.Join(rd.Notes, "; ")
	if err != nil || !rd.Swept || strings.Contains(notes, "ec2:DescribeRegions not answered") || strings.Join(rd.Regions, " ") != "eu-west-1 us-east-2" {
		t.Fatalf("the two lists at once: %v swept %v regions %v notes %v", err, rd.Swept, rd.Regions, rd.Notes)
	}
	// the list's wait is the shorter of the call's and awsListWait
	silentList := func(ctx context.Context, _ string) (map[string]bool, error) { <-ctx.Done(); return nil, ctx.Err() }
	start := time.Now()
	rd, err = AWS(ctx, AWSOptions{Regions: []string{"us-east-2"}, seed: "us-east-2", identity: lab, client: mk, regionList: silentList, callWait: time.Hour})
	if took := time.Since(start); err != nil || took > awsListWait+2*time.Second || !strings.Contains(strings.Join(rd.Notes, "; "), "ec2:DescribeRegions not answered within "+awsListWait.String()) {
		t.Fatalf("the list's wait: %v took %v notes %v", err, took, rd.Notes)
	}
	// RDS's list refused, the account's answered: the enabled regions swept; a kept region not enabled and one of
	// another partition noted, unseen, not read, not kept
	refused := func(_ context.Context, r string) (rdsAPI, error) {
		count(r)
		return fakeRDS{srcErr: errors.New("api error AccessDenied: no")}, nil
	}
	rd, err = AWS(ctx, AWSOptions{seed: "us-east-2", Keep: []string{"me-south-1", "us-gov-west-1"}, identity: lab, client: refused, regionList: list(nil)})
	notes = strings.Join(rd.Notes, "; ")
	if err != nil || !rd.Swept || strings.Join(rd.Regions, " ") != "eu-west-1 us-east-2" || calls["me-south-1"] != 0 || calls["us-gov-west-1"] != 0 ||
		!strings.Contains(notes, "the account's enabled regions (ec2:DescribeRegions) swept instead") ||
		!strings.Contains(notes, "me-south-1: not enabled for this account") || !strings.Contains(notes, "us-gov-west-1: not a region of these credentials' partition (aws)") ||
		strings.Join(rd.Unseen, " ") != "aws:111122223333:me-south-1: aws:111122223333:us-gov-west-1:" {
		t.Fatalf("RDS's list refused, the account's answered: %v swept %v regions %v calls %v notes %v unseen %v", err, rd.Swept, rd.Regions, calls, rd.Notes, rd.Unseen)
	}
	// a skipped region the account's list now says is not enabled: noted so (its silent note replaced), asked, not
	// kept; the list goes to the first region not skipped (no configured region)
	listAt = nil
	rd, err = AWS(ctx, AWSOptions{Regions: []string{"me-south-1", "us-east-2"}, Skip: []string{"me-south-1"}, identity: lab, client: mk, regionList: list(nil)})
	if err != nil || calls["me-south-1"] != 0 || strings.Join(listAt, " ") != "us-east-2" || strings.Join(rd.Asked, " ") != "me-south-1 us-east-2" ||
		strings.Join(rd.Regions, " ") != "us-east-2" || !strings.Contains(strings.Join(rd.Notes, "; "), "me-south-1: not enabled for this account") ||
		strings.Join(rd.Unseen, " ") != "aws:111122223333:me-south-1:" {
		t.Fatalf("the list before Skip: %v list asked in %v asked %v regions %v notes %v unseen %v", err, listAt, rd.Asked, rd.Regions, rd.Notes, rd.Unseen)
	}
	if got := firstAsked([]string{"me-south-1", "us-east-2"}, map[string]bool{"me-south-1": true}); got != "us-east-2" {
		t.Fatalf("firstAsked: %q", got)
	}
	if got := firstAsked([]string{"me-south-1"}, map[string]bool{"me-south-1": true}); got != "me-south-1" {
		t.Fatalf("firstAsked, every region skipped: %q", got)
	}
	// a lone region silent at a read that is not a sweep: the read fails, Asked kept (its note keyed by the region)
	silent := func(_ context.Context, r string) (rdsAPI, error) { count(r); return silentRDS{}, nil }
	rd, err = AWS(ctx, AWSOptions{Regions: []string{"eu-west-1"}, seed: "us-east-2", identity: lab, client: silent, callWait: 50 * time.Millisecond})
	if err == nil || strings.Join(rd.Asked, " ") != "eu-west-1" || !strings.Contains(strings.Join(rd.Notes, "; "), "eu-west-1: not reachable") {
		t.Fatalf("a lone silent region: %v asked %v notes %v", err, rd.Asked, rd.Notes)
	}
	// a skipped region beside a refused one: the error says the skipped one too, Asked holds the refused one
	deny := func(_ context.Context, r string) (rdsAPI, error) {
		count(r)
		return fakeRDS{err: errors.New("operation error RDS: DescribeDBClusters, api error AccessDenied: denied by policy")}, nil
	}
	rd, err = AWS(ctx, AWSOptions{Regions: []string{"me-south-1", "us-east-2"}, Skip: []string{"me-south-1"}, seed: "us-east-2", identity: lab, client: deny})
	if err == nil || !strings.Contains(err.Error(), "1 region(s) not asked: silent since the last sweep") || strings.Join(rd.Asked, " ") != "us-east-2" {
		t.Fatalf("a skipped region beside a refused one: %v asked %v", err, rd.Asked)
	}
	// the list answered and a region a policy refuses (AccessDenied): noted, not kept - only a token error in an
	// enabled region is kept (the review's part c)
	policy := func(_ context.Context, r string) (rdsAPI, error) {
		count(r)
		if r == "eu-west-1" {
			return fakeRDS{err: errors.New("operation error RDS: DescribeDBClusters, https response error StatusCode: 403, api error AccessDenied: denied by an SCP")}, nil
		}
		return fakeRDS{sources: []string{"eu-west-1"}}, nil
	}
	rd, err = AWS(ctx, AWSOptions{seed: "us-east-2", identity: lab, client: policy, regionList: list(nil)})
	if err != nil || !rd.Swept || strings.Join(rd.Regions, " ") != "us-east-2" || !strings.Contains(strings.Join(rd.Notes, "; "), "eu-west-1: not allowed for these credentials (AccessDenied)") {
		t.Fatalf("a region a policy refuses, the list answered: %v regions %v notes %v", err, rd.Regions, rd.Notes)
	}
	// a read cut by its context keeps Asked too
	cut, stop := context.WithCancel(ctx)
	stop()
	if rd, err = AWS(cut, AWSOptions{Regions: []string{"us-east-2"}, seed: "us-east-2", identity: lab, client: mk}); err == nil || strings.Join(rd.Asked, " ") != "us-east-2" {
		t.Fatalf("a cut read: %v asked %v", err, rd.Asked)
	}
}
