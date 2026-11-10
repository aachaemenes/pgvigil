package platform

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
)

// The AWS side of a DB instance the Performance Insights and Serverless collections need, read once an hour per
// identifier (DescribeDBInstances and DescribeDBClusters answers change rarely; the collections run hourly and every
// five minutes): whether Performance Insights is on, the DbiResourceId the PI API takes as its Identifier, the
// instance's class and cluster, and the cluster's Serverless v2 range (the floor and the ceiling in ACU).

// AWSInstance is one DB instance's answer.
type AWSInstance struct {
	ID            string  // the DB instance identifier
	ResourceID    string  // DbiResourceId (db-...)
	PIEnabled     bool    // PerformanceInsightsEnabled
	PIRetention   int     // PerformanceInsightsRetentionPeriod, days
	Class         string  // DBInstanceClass: db.serverless for a Serverless v2 instance
	Cluster       string  // DBClusterIdentifier (Aurora), empty on RDS
	MinACU        float64 // the cluster's ServerlessV2ScalingConfiguration MinCapacity; 0 with HasScaling false = none
	MaxACU        float64
	HasScaling    bool   // the cluster has a Serverless v2 range
	ScalingNote   string // why the range is unknown (DescribeDBClusters failed or the cluster is not Serverless v2)
	DescribedAt   time.Time
	ClusterReadAt time.Time
	clusterFailed bool // the last DescribeDBClusters failed: the next call reads the cluster again
}

// AWSDescriber is the slice of the RDS client the lookup calls; a recorded set in a test.
type AWSDescriber interface {
	rds.DescribeDBInstancesAPIClient
	DescribeDBClusters(context.Context, *rds.DescribeDBClustersInput, ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error)
}

// AWSDescribeTTL is how long one answer is kept.
const AWSDescribeTTL = time.Hour

var (
	awsInstMu    sync.Mutex
	awsInstCache = map[string]AWSInstance{}
)

// DescribeAWSInstance returns the instance's answer, read again when the cached one is older than AWSDescribeTTL.
// The cache is keyed by awsKey (the client's profile and region: an identifier is unique only in its account and
// region) and the identifier. A cluster read that fails leaves HasScaling false with the reason and is tried again
// on the next call (a throttled describe must not hide the range for an hour); the instance read failing is the error.
func DescribeAWSInstance(ctx context.Context, api AWSDescriber, awsKey, id string, now time.Time) (AWSInstance, error) {
	key := awsKey + "|" + id
	awsInstMu.Lock()
	c, ok := awsInstCache[key]
	awsInstMu.Unlock()
	if ok && now.Sub(c.DescribedAt) < AWSDescribeTTL {
		if !c.clusterFailed {
			return c, nil
		}
		c.describeCluster(ctx, api, now)
		awsInstMu.Lock()
		awsInstCache[key] = c
		awsInstMu.Unlock()
		return c, nil
	}
	di, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: aws.String(id)})
	if err != nil {
		return AWSInstance{}, fmt.Errorf("DescribeDBInstances %s: %w", id, err)
	}
	if len(di.DBInstances) == 0 {
		return AWSInstance{}, fmt.Errorf("DescribeDBInstances %s: no such DB instance", id)
	}
	d := di.DBInstances[0]
	out := AWSInstance{ID: id, ResourceID: aws.ToString(d.DbiResourceId), PIEnabled: aws.ToBool(d.PerformanceInsightsEnabled),
		Class: aws.ToString(d.DBInstanceClass), Cluster: aws.ToString(d.DBClusterIdentifier), DescribedAt: now}
	if d.PerformanceInsightsRetentionPeriod != nil {
		out.PIRetention = int(*d.PerformanceInsightsRetentionPeriod)
	}
	out.describeCluster(ctx, api, now)
	awsInstMu.Lock()
	awsInstCache[key] = out
	awsInstMu.Unlock()
	return out, nil
}

// describeCluster reads the cluster's Serverless v2 range into the answer (no cluster: nothing to read).
func (out *AWSInstance) describeCluster(ctx context.Context, api AWSDescriber, now time.Time) {
	if out.Cluster == "" {
		return
	}
	out.MinACU, out.MaxACU, out.HasScaling, out.ScalingNote, out.clusterFailed = 0, 0, false, "", false
	dc, err := api.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{DBClusterIdentifier: aws.String(out.Cluster)})
	switch {
	case err != nil:
		out.ScalingNote, out.clusterFailed = fmt.Sprintf("DescribeDBClusters %s: %v", out.Cluster, err), true
	case len(dc.DBClusters) == 0:
		out.ScalingNote = fmt.Sprintf("DescribeDBClusters %s: no such cluster", out.Cluster)
	case dc.DBClusters[0].ServerlessV2ScalingConfiguration == nil:
		out.ScalingNote = "the cluster has no Serverless v2 range (provisioned instances only)"
	default:
		sc := dc.DBClusters[0].ServerlessV2ScalingConfiguration
		out.MinACU, out.MaxACU, out.HasScaling = aws.ToFloat64(sc.MinCapacity), aws.ToFloat64(sc.MaxCapacity), true
	}
	out.ClusterReadAt = now
}

// ForgetAWSInstances empties the cache (tests).
func ForgetAWSInstances() {
	awsInstMu.Lock()
	awsInstCache = map[string]AWSInstance{}
	awsInstMu.Unlock()
}
