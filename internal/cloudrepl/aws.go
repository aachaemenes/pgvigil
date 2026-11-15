// Package cloudrepl reads the provider replica metrics of Amazon RDS and Google Cloud SQL (task 390b): a resource's
// replication topology and status, and each replica's lag, through the providers' own APIs - no SQL connection, and a
// replica pgvigil does not connect to still has its lag. Every call is a read; nothing is written in any cloud.
package cloudrepl

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
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/smithy-go"
)

// Resource is one provider database resource as read: its role in a replication chain, its source and replicas (each
// lag is to the DIRECT upstream; a replica that is also a source is Cascaded), its own status and its replication
// status (RDS StatusInfos' 'read replication' row; Cloud SQL's replication state).
type Resource struct {
	Provider   string   // aws | gcp
	ID         string   // the RDS DB instance identifier, or project:instance (lower case)
	Engine     string   // the provider's engine name (postgres, sqlserver-se, POSTGRES_16)
	Region     string   //
	Role       string   // source | replica | standalone
	SourceID   string   // a replica's direct upstream
	ReplicaIDs []string // a source's direct replicas
	Cascaded   bool     // a replica that is also a source
	Status     string   // DBInstanceStatus (available, rebooting ...) or the Cloud SQL state (RUNNABLE ...)
	ReplStatus string   // replicating | error | stopped | terminated (RDS); Running | Stopped | Error (Cloud SQL); "" = not reported yet
	ReplNote   string   // the provider's words when the replication status is not normal
}

// Point is one datapoint of a replica's series: replica_lag (s) or replica_byte_lag (bytes).
type Point struct {
	ResourceID string
	Metric     string
	Unit       string
	At         time.Time
	Value      float64
}

// Throttled is a provider's throttle answer: the read is skipped until the next interval (the design fold 15).
type Throttled struct{ Door, Code, Message string }

func (t *Throttled) Error() string {
	return fmt.Sprintf("%s throttled the read (%s: %s): the next read at the next interval", t.Door, t.Code, t.Message)
}

// RDSAPI is the one RDS call P1 makes.
type RDSAPI interface {
	DescribeDBInstances(ctx context.Context, in *rds.DescribeDBInstancesInput, opt ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error)
}

// CWAPI is the one CloudWatch call P1 makes.
type CWAPI = cloudwatch.GetMetricDataAPIClient

const (
	// awsListAge: a region's listing serves every instance of one run (the collection runs every 5 minutes): one paged
	// DescribeDBInstances a region and run (the design fold 15)
	awsListAge = 4 * time.Minute
	// lagWindow: ReplicaLag's window each run (four of the collection's intervals: one missed run loses nothing; the
	// import keeps one row per datapoint)
	lagWindow = 20 * time.Minute
)

// AWSReader is P1: a region's RDS and CloudWatch clients (one credential chain, the instance's aws: block) and the
// run's listings.
type AWSReader struct {
	RDS func(ctx context.Context, region string) (RDSAPI, error)
	CW  func(ctx context.Context, region string) (CWAPI, error)
	Now func() time.Time

	mu    sync.Mutex
	lists map[string]awsList
}

type awsList struct {
	at  time.Time
	dbs map[string]rdstypes.DBInstance
}

// list: every DB instance of the region by its lower-case identifier, read once a run (every page); a refusal or a
// throttle is never kept
func (r *AWSReader) list(ctx context.Context, region string) (map[string]rdstypes.DBInstance, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.Now()
	if l, ok := r.lists[region]; ok && now.Sub(l.at) < awsListAge && !now.Before(l.at) {
		return l.dbs, nil
	}
	api, err := r.RDS(ctx, region)
	if err != nil {
		return nil, err
	}
	dbs := map[string]rdstypes.DBInstance{}
	var marker *string
	for page := 0; page < 100; page++ {
		out, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{Marker: marker, MaxRecords: aws.Int32(100)})
		if err != nil {
			return nil, awsErr("rds:DescribeDBInstances", region, err)
		}
		for _, d := range out.DBInstances {
			dbs[strings.ToLower(aws.ToString(d.DBInstanceIdentifier))] = d
		}
		if aws.ToString(out.Marker) == "" {
			break
		}
		marker = out.Marker
	}
	if r.lists == nil {
		r.lists = map[string]awsList{}
	}
	r.lists[region] = awsList{at: now, dbs: dbs}
	return dbs, nil
}

// Read is one instance's read: its own resource, its direct source and replicas (each in its own region: a
// cross-region replica is named by its ARN), and each replica's ReplicaLag. A refused listing still reads the
// instance's own lag (it may be a replica) and returns the refusal's sentence as a note; a throttle is *Throttled.
func (r *AWSReader) Read(ctx context.Context, region, dbInstance string) ([]Resource, []Point, []string, error) {
	id := strings.ToLower(strings.TrimSpace(dbInstance))
	var notes []string
	dbs, err := r.list(ctx, region)
	if err != nil {
		var th *Throttled
		if errors.As(err, &th) {
			return nil, nil, nil, err
		}
		notes = append(notes, err.Error())
		pts, lerr := r.lag(ctx, region, []string{id})
		if lerr != nil {
			if errors.As(lerr, &th) {
				return nil, nil, nil, lerr
			}
			notes = append(notes, lerr.Error())
		}
		return nil, pts, notes, nil
	}
	self, ok := dbs[id]
	if !ok {
		return nil, nil, nil, fmt.Errorf("the DB instance %q is not in %s's DescribeDBInstances answer (the aws: block's db_instance or region)", id, region)
	}
	res := []Resource{awsResource(self, region)}
	lagOf := map[string][]string{} // region: the replicas whose lag is read there
	if src := aws.ToString(self.ReadReplicaSourceDBInstanceIdentifier); src != "" {
		lagOf[region] = append(lagOf[region], id)
		sid, sregion := awsRef(src, region)
		if s, err := r.find(ctx, sregion, sid); err == nil {
			res = append(res, awsResource(s, sregion))
		} else {
			notes = append(notes, err.Error())
		}
	}
	for _, ref := range self.ReadReplicaDBInstanceIdentifiers {
		rid, rregion := awsRef(ref, region)
		lagOf[rregion] = append(lagOf[rregion], rid)
		if x, err := r.find(ctx, rregion, rid); err == nil {
			res = append(res, awsResource(x, rregion))
		} else {
			notes = append(notes, err.Error())
		}
	}
	regions := make([]string, 0, len(lagOf))
	for k := range lagOf {
		regions = append(regions, k)
	}
	sort.Strings(regions)
	var pts []Point
	for _, rg := range regions {
		p, err := r.lag(ctx, rg, lagOf[rg])
		if err != nil {
			var th *Throttled
			if errors.As(err, &th) {
				return nil, nil, nil, err
			}
			notes = append(notes, err.Error())
			continue
		}
		pts = append(pts, p...)
	}
	return res, pts, notes, nil
}

// find: one DB instance of a region's listing
func (r *AWSReader) find(ctx context.Context, region, id string) (rdstypes.DBInstance, error) {
	dbs, err := r.list(ctx, region)
	if err != nil {
		return rdstypes.DBInstance{}, err
	}
	d, ok := dbs[id]
	if !ok {
		return rdstypes.DBInstance{}, fmt.Errorf("the DB instance %q is not in %s's DescribeDBInstances answer", id, region)
	}
	return d, nil
}

// lag: ReplicaLag (AWS/RDS, seconds, Maximum over 60 s) of the replicas over the window, every datapoint
func (r *AWSReader) lag(ctx context.Context, region string, ids []string) ([]Point, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	api, err := r.CW(ctx, region)
	if err != nil {
		return nil, err
	}
	now := r.Now().UTC().Truncate(time.Minute)
	in := &cloudwatch.GetMetricDataInput{StartTime: aws.Time(now.Add(-lagWindow)), EndTime: aws.Time(now), ScanBy: cwtypes.ScanByTimestampAscending}
	for i, id := range ids {
		in.MetricDataQueries = append(in.MetricDataQueries, cwtypes.MetricDataQuery{Id: aws.String(fmt.Sprintf("q%d", i)), ReturnData: aws.Bool(true),
			MetricStat: &cwtypes.MetricStat{Period: aws.Int32(60), Stat: aws.String("Maximum"), Unit: cwtypes.StandardUnitSeconds,
				Metric: &cwtypes.Metric{Namespace: aws.String("AWS/RDS"), MetricName: aws.String("ReplicaLag"),
					Dimensions: []cwtypes.Dimension{{Name: aws.String("DBInstanceIdentifier"), Value: aws.String(id)}}}}})
	}
	var out []Point
	for page := 0; page < 50; page++ {
		res, err := api.GetMetricData(ctx, in)
		if err != nil {
			return nil, awsErr("cloudwatch:GetMetricData", region, err)
		}
		for _, m := range res.MetricDataResults {
			var k int
			if _, err := fmt.Sscanf(aws.ToString(m.Id), "q%d", &k); err != nil || k < 0 || k >= len(ids) {
				continue
			}
			for j := range m.Timestamps {
				if j < len(m.Values) {
					out = append(out, Point{ResourceID: ids[k], Metric: "replica_lag", Unit: "s", At: m.Timestamps[j].UTC(), Value: m.Values[j]})
				}
			}
		}
		if aws.ToString(res.NextToken) == "" {
			break
		}
		in.NextToken = res.NextToken
	}
	return out, nil
}

// awsResource: one DB instance's topology and status
func awsResource(d rdstypes.DBInstance, region string) Resource {
	x := Resource{Provider: "aws", ID: strings.ToLower(aws.ToString(d.DBInstanceIdentifier)), Engine: aws.ToString(d.Engine), Region: region,
		Status: aws.ToString(d.DBInstanceStatus)}
	if src := aws.ToString(d.ReadReplicaSourceDBInstanceIdentifier); src != "" {
		x.SourceID, _ = awsRef(src, region)
	}
	for _, ref := range d.ReadReplicaDBInstanceIdentifiers {
		id, _ := awsRef(ref, region)
		x.ReplicaIDs = append(x.ReplicaIDs, id)
	}
	switch {
	case x.SourceID != "":
		x.Role, x.Cascaded = "replica", len(x.ReplicaIDs) > 0
	case len(x.ReplicaIDs) > 0:
		x.Role = "source"
	default:
		x.Role = "standalone"
	}
	for _, s := range d.StatusInfos {
		if strings.EqualFold(aws.ToString(s.StatusType), "read replication") {
			x.ReplStatus = aws.ToString(s.Status)
			if !aws.ToBool(s.Normal) {
				x.ReplNote = aws.ToString(s.Message)
			}
		}
	}
	return x
}

// awsRef: a replica or source as RDS names it - an identifier in the same region, or an ARN in another
// (arn:<partition>:rds:<region>:<account>:db:<identifier>)
func awsRef(ref, region string) (id, inRegion string) {
	if strings.HasPrefix(ref, "arn:") {
		p := strings.Split(ref, ":")
		if len(p) >= 7 && p[2] == "rds" && p[5] == "db" {
			return strings.ToLower(p[6]), p[3]
		}
	}
	return strings.ToLower(ref), region
}

// awsErr: an AWS refusal in words (the call, the region, the code and message, the right) or *Throttled
func awsErr(call, region string, err error) error {
	var ae smithy.APIError
	if errors.As(err, &ae) {
		switch ae.ErrorCode() {
		case "Throttling", "ThrottlingException", "RequestLimitExceeded", "TooManyRequestsException", "RequestThrottled":
			return &Throttled{Door: call + " in " + region, Code: ae.ErrorCode(), Message: ae.ErrorMessage()}
		}
		return fmt.Errorf("%s in %s refused (%s: %s): the identity needs %s", call, region, ae.ErrorCode(), ae.ErrorMessage(), call)
	}
	return fmt.Errorf("%s in %s: %w", call, region, err)
}
