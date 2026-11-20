package collect

// The provider's check of a page instance's aws: block. A page block names an RDS DB instance or cluster that the
// COLLECTOR HOST's identity reads (CloudWatch, the logs, Performance Insights, the host and storage reads), while its
// host was typed by a page user. An RDS identifier is unique only inside one account and region, so a name match
// alone let a user's own payroll-prod (their account, their login) open the host's reads of the collector account's
// payroll-prod. Before a block's first read the
// collector asks RDS, in the account and region the block reads with, for that instance's Endpoint.Address (or that
// cluster's writer and reader endpoints) and keeps the block only when the instance's host is one of them; a block
// naming both must name an instance of that cluster. No new right: rds:DescribeDBInstances and rds:DescribeDBClusters
// are the host, storage and backups reads' own.
//
// A verdict (kept or refused) is kept for the process per (block, host): a change of either asks again. An AWS error
// is no verdict: the block is refused meanwhile (it fails closed) and asked again after pageAWSRetry.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// pageAWSAPI is the slice of the RDS client the check calls; a recorded set in a test.
type pageAWSAPI interface {
	rds.DescribeDBInstancesAPIClient
	rds.DescribeDBClustersAPIClient
}

var newPageAWSAPI = func(ctx context.Context, a config.AWS) (pageAWSAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return rds.NewFromConfig(cfg), nil
}

// pageAWSRetry: how long a block whose check met an AWS error stays refused before it is asked again
const pageAWSRetry = 5 * time.Minute

type pageAWSKept struct {
	why    string    // "" = the block holds
	failed bool      // an AWS error, not a verdict: asked again after pageAWSRetry
	at     time.Time // when it was asked
}

var (
	pageAWSMu       sync.Mutex
	pageAWSVerdicts = map[string]pageAWSKept{}
)

func resetPageAWSVerdicts() {
	pageAWSMu.Lock()
	pageAWSVerdicts = map[string]pageAWSKept{}
	pageAWSMu.Unlock()
}

// pageAWSVerdict is why the instance's page aws: block is not used ("" = it is): the cached verdict for (block,
// host), else the provider's answer now. A new verdict is logged once.
func pageAWSVerdict(ctx context.Context, log *slog.Logger, in config.Instance, now time.Time) string {
	a := in.AWS
	if a == nil || in.PageAWSHost == "" {
		return ""
	}
	key := strings.Join([]string{a.Region, a.Profile, a.DBInstance, a.Cluster, in.PageAWSHost}, "|")
	pageAWSMu.Lock()
	k, ok := pageAWSVerdicts[key]
	pageAWSMu.Unlock()
	if ok && (!k.failed || now.Sub(k.at) < pageAWSRetry) {
		return k.why
	}
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var why string
	var err error
	api, err := newPageAWSAPI(cctx, *a)
	if err == nil {
		why, err = checkPageAWS(cctx, api, *a, in.PageAWSHost)
	}
	if err != nil {
		if ctx.Err() != nil {
			return "the check was cut by the collector's own stop"
		}
		why = fmt.Sprintf("its target could not be checked against AWS (asked again in %s): %v", pageAWSRetry, err)
	}
	k = pageAWSKept{why: why, failed: err != nil, at: now}
	pageAWSMu.Lock()
	// two checks of one block can run at once (a new instance's first collections): an AWS error is no verdict, so
	// a failed check never replaces a verdict a parallel check stored meanwhile
	if had, ok := pageAWSVerdicts[key]; ok && !had.failed && k.failed {
		pageAWSMu.Unlock()
		return had.why
	}
	pageAWSVerdicts[key] = k
	pageAWSMu.Unlock()
	if why != "" {
		log.Warn("instances: a page instance's aws: block is not used", "instance", in.Name, "why", why)
	} else {
		log.Info("instances: a page instance's aws: block matches its host", "instance", in.Name, "host", in.PageAWSHost)
	}
	return why
}

// checkPageAWS asks RDS, with the block's own region and profile, whether host is the endpoint of the block's DB
// instance or cluster: the reason it is not, "" when it is; err = no answer (AccessDenied, no credentials, a timeout).
func checkPageAWS(ctx context.Context, api pageAWSAPI, a config.AWS, host string) (string, error) {
	host = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	var have []string // the endpoints the provider names for the block
	var inCluster string
	if a.DBInstance != "" {
		out, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: aws.String(a.DBInstance)})
		var nf *rdstypes.DBInstanceNotFoundFault
		switch {
		case errors.As(err, &nf):
			return fmt.Sprintf("this host's AWS identity has no DB instance %s in %s (the block names a resource of the account the collector reads with)", a.DBInstance, a.Region), nil
		case err != nil:
			return "", fmt.Errorf("DescribeDBInstances %s: %w", a.DBInstance, err)
		case len(out.DBInstances) == 0:
			return fmt.Sprintf("this host's AWS identity has no DB instance %s in %s", a.DBInstance, a.Region), nil
		}
		db := out.DBInstances[0]
		inCluster = aws.ToString(db.DBClusterIdentifier)
		if db.Endpoint != nil {
			have = append(have, aws.ToString(db.Endpoint.Address))
		}
		if a.Cluster != "" && !strings.EqualFold(inCluster, a.Cluster) {
			return fmt.Sprintf("the aws: block names the cluster %s, but its DB instance %s is in %s in this host's account", a.Cluster, a.DBInstance, orNone(inCluster)), nil
		}
	}
	if a.Cluster != "" {
		out, err := api.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{DBClusterIdentifier: aws.String(a.Cluster)})
		var nf *rdstypes.DBClusterNotFoundFault
		switch {
		case errors.As(err, &nf):
			return fmt.Sprintf("this host's AWS identity has no DB cluster %s in %s (the block names a resource of the account the collector reads with)", a.Cluster, a.Region), nil
		case err != nil:
			return "", fmt.Errorf("DescribeDBClusters %s: %w", a.Cluster, err)
		case len(out.DBClusters) == 0:
			return fmt.Sprintf("this host's AWS identity has no DB cluster %s in %s", a.Cluster, a.Region), nil
		}
		c := out.DBClusters[0]
		have = append(have, aws.ToString(c.Endpoint), aws.ToString(c.ReaderEndpoint))
	}
	for _, h := range have {
		if h != "" && strings.EqualFold(strings.TrimSuffix(h, "."), host) {
			return "", nil
		}
	}
	named := []string{}
	for _, h := range have {
		if h != "" {
			named = append(named, strings.ToLower(h))
		}
	}
	return fmt.Sprintf("the instance's host %s is not the endpoint AWS gives for the block's %s in %s in this host's account (%s): the same name in another account is another server",
		host, strings.Trim(a.DBInstance+" / "+a.Cluster, " /"), a.Region, orNone(strings.Join(named, ", "))), nil
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}
