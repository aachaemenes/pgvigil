package collect

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// versionsCollector is the hourly version and patching read. From the server: server_version_num, the
// version strings (server_version, version(), on Aurora aurora_version()) and the postmaster start (a new
// minor runs from the restart that applied it), and the collation check per database (PostgreSQL 15+:
// pg_database.datcollversion, the version the database was created or last refreshed with, against
// pg_database_collation_actual_version, the operating system library's version now: an OS patch that
// changed glibc or ICU leaves the text indexes ordered by the old rules until a REINDEX). Through the AWS
// door, when the config names an RDS instance or an Aurora cluster: the engine version, the auto minor
// version upgrade flag and the maintenance window (DescribeDBClusters / DescribeDBInstances), the valid
// upgrade targets of that engine version (DescribeDBEngineVersions) and the pending maintenance actions of
// the cluster and its instances (DescribePendingMaintenanceActions: the patching tracker). Nothing is
// changed on the server or in AWS.
//
// Rows by kind:
//
//	server       server_version_num, server_version, version_string, aurora_version, postmaster_start
//	collation    dbid, datname, provider, locale, recorded_version, actual_version   (PostgreSQL 15+)
//	aws_engine   resource, engine, engine_version, auto_minor_version_upgrade, maintenance_window, members
//	aws_instance id, class, engine_version, auto_minor_version_upgrade, maintenance_window, is_writer
//	aws_target   engine_version, is_major, description, auto_upgrade
//	aws_pending  resource, action, description, auto_applied_after, forced_apply, current_apply, opt_in_status
//	aws_read     the AWS side was read completely (its absence keeps the last AWS rows)
//
// An AWS failure gives a collector_error row and the server rows still import.
type versionsCollector struct{}

func init() { Register(versionsCollector{}) }

func (versionsCollector) Name() string                   { return "versions" }
func (versionsCollector) DefaultInterval() time.Duration { return time.Hour }
func (versionsCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (versionsCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("versions needs the instance config: %w", ErrSkip)
}

const versionsServerSQL = `
SELECT 'server' AS kind, current_setting('server_version_num')::int AS server_version_num,
       current_setting('server_version') AS server_version, version() AS version_string,
       pg_postmaster_start_time() AS postmaster_start`

// versionsCollationSQL: the databases a login may connect to, with the collation version recorded at
// creation (or the last ALTER DATABASE ... REFRESH COLLATION VERSION) and the library's version now. A
// database on the C or POSIX locale has no version (NULL on both sides). PostgreSQL 15+.
const versionsCollationSQL = `
SELECT 'collation' AS kind, d.oid::bigint AS dbid, d.datname::text AS datname, d.datlocprovider::text AS provider,
       d.datcollate::text AS locale, d.datcollversion AS recorded_version,
       pg_database_collation_actual_version(d.oid) AS actual_version
  FROM pg_database d
 WHERE d.datallowconn
 ORDER BY d.datname`

func (versionsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	r, err := conn.Query(ctx, versionsServerSQL)
	if err != nil {
		return nil, err
	}
	out, err := rowsToMaps(r)
	if err != nil {
		return nil, err
	}
	if info.Kind == platform.Aurora && len(out) == 1 {
		// aurora_version() has no pg_proc row; a failure leaves it NULL and the read goes on
		var av string
		if err := conn.QueryRow(ctx, `SELECT aurora_version()::text`).Scan(&av); err == nil {
			out[0]["aurora_version"] = av
		}
	}
	if info.ServerVersionNum >= 150000 {
		r, err := conn.Query(ctx, versionsCollationSQL)
		if err != nil {
			return nil, err
		}
		c, err := rowsToMaps(r)
		if err != nil {
			return nil, err
		}
		out = append(out, c...)
	}
	if in.AWS == nil || (in.AWS.Cluster == "" && in.AWS.DBInstance == "") {
		return out, nil
	}
	api, err := rdsClientFor(ctx, *in.AWS)
	if err == nil {
		var aw []Row
		if aw, err = versionsAWSRows(ctx, api, *in.AWS); err == nil {
			return append(out, aw...), nil
		}
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return append(out, Row{"kind": "collector_error", "source": "versions:aws", "message": err.Error()}), nil
}

// rdsAPI is the slice of the RDS client the collector calls; a recorded set in tests.
type rdsAPI interface {
	rds.DescribeDBClustersAPIClient
	rds.DescribeDBInstancesAPIClient
	rds.DescribeDBEngineVersionsAPIClient
	rds.DescribePendingMaintenanceActionsAPIClient
}

var (
	rdsClientsMu sync.Mutex
	rdsClients   = map[string]rdsAPI{}
)

var newRDSAPI = func(ctx context.Context, a config.AWS) (rdsAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return rds.NewFromConfig(cfg), nil
}

func rdsClientFor(ctx context.Context, a config.AWS) (rdsAPI, error) {
	k := a.Profile + "|" + a.Region
	rdsClientsMu.Lock()
	defer rdsClientsMu.Unlock()
	if c, ok := rdsClients[k]; ok {
		return c, nil
	}
	c, err := newRDSAPI(ctx, a)
	if err == nil {
		rdsClients[k] = c
	}
	return c, err
}

// versionsAWSRows reads the engine side of an Aurora cluster (a.Cluster) or an RDS instance (a.DBInstance).
func versionsAWSRows(ctx context.Context, api rdsAPI, a config.AWS) ([]Row, error) {
	var out []Row
	var engine, engineVersion string
	var instances []rdstypes.DBInstance
	var pendingFilter rdstypes.Filter
	if a.Cluster != "" {
		cl, err := api.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{DBClusterIdentifier: aws.String(a.Cluster)})
		if err != nil {
			return nil, fmt.Errorf("DescribeDBClusters %s: %w", a.Cluster, err)
		}
		if len(cl.DBClusters) == 0 {
			return nil, fmt.Errorf("DescribeDBClusters %s: no cluster", a.Cluster)
		}
		c := cl.DBClusters[0]
		engine, engineVersion = aws.ToString(c.Engine), aws.ToString(c.EngineVersion)
		p := rds.NewDescribeDBInstancesPaginator(api, &rds.DescribeDBInstancesInput{
			Filters: []rdstypes.Filter{{Name: aws.String("db-cluster-id"), Values: []string{a.Cluster}}}})
		for p.HasMorePages() {
			pg, err := p.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("DescribeDBInstances (cluster %s): %w", a.Cluster, err)
			}
			instances = append(instances, pg.DBInstances...)
		}
		writer := map[string]bool{}
		members := []string{}
		for _, m := range c.DBClusterMembers {
			writer[aws.ToString(m.DBInstanceIdentifier)] = aws.ToBool(m.IsClusterWriter)
			members = append(members, aws.ToString(m.DBInstanceIdentifier))
		}
		sort.Strings(members)
		out = append(out, Row{"kind": "aws_engine", "resource": "cluster:" + a.Cluster, "engine": engine, "engine_version": engineVersion,
			"auto_minor_version_upgrade": c.AutoMinorVersionUpgrade, "maintenance_window": aws.ToString(c.PreferredMaintenanceWindow),
			"members": members})
		for _, i := range instances {
			out = append(out, Row{"kind": "aws_instance", "id": aws.ToString(i.DBInstanceIdentifier), "class": aws.ToString(i.DBInstanceClass),
				"engine_version": aws.ToString(i.EngineVersion), "auto_minor_version_upgrade": i.AutoMinorVersionUpgrade,
				"maintenance_window": aws.ToString(i.PreferredMaintenanceWindow), "is_writer": writer[aws.ToString(i.DBInstanceIdentifier)]})
		}
		pendingFilter = rdstypes.Filter{Name: aws.String("db-cluster-id"), Values: []string{a.Cluster}}
	} else {
		di, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: aws.String(a.DBInstance)})
		if err != nil {
			return nil, fmt.Errorf("DescribeDBInstances %s: %w", a.DBInstance, err)
		}
		if len(di.DBInstances) == 0 {
			return nil, fmt.Errorf("DescribeDBInstances %s: no instance", a.DBInstance)
		}
		i := di.DBInstances[0]
		instances = di.DBInstances[:1]
		engine, engineVersion = aws.ToString(i.Engine), aws.ToString(i.EngineVersion)
		out = append(out, Row{"kind": "aws_engine", "resource": "instance:" + a.DBInstance, "engine": engine, "engine_version": engineVersion,
			"auto_minor_version_upgrade": i.AutoMinorVersionUpgrade, "maintenance_window": aws.ToString(i.PreferredMaintenanceWindow),
			"members": []string{a.DBInstance}})
		pendingFilter = rdstypes.Filter{Name: aws.String("db-instance-id"), Values: []string{a.DBInstance}}
	}

	ev, err := api.DescribeDBEngineVersions(ctx, &rds.DescribeDBEngineVersionsInput{Engine: aws.String(engine), EngineVersion: aws.String(engineVersion)})
	if err != nil {
		return nil, fmt.Errorf("DescribeDBEngineVersions %s %s: %w", engine, engineVersion, err)
	}
	for _, v := range ev.DBEngineVersions {
		for _, t := range v.ValidUpgradeTarget {
			out = append(out, Row{"kind": "aws_target", "engine_version": aws.ToString(t.EngineVersion), "is_major": aws.ToBool(t.IsMajorVersionUpgrade),
				"description": aws.ToString(t.Description), "auto_upgrade": aws.ToBool(t.AutoUpgrade)})
		}
	}

	// the cluster's own actions, then each member instance's (the filter takes one kind of identifier)
	filters := []rdstypes.Filter{pendingFilter}
	if a.Cluster != "" && len(instances) > 0 {
		ids := make([]string, 0, len(instances))
		for _, i := range instances {
			ids = append(ids, aws.ToString(i.DBInstanceIdentifier))
		}
		filters = append(filters, rdstypes.Filter{Name: aws.String("db-instance-id"), Values: ids})
	}
	for _, f := range filters {
		p := rds.NewDescribePendingMaintenanceActionsPaginator(api, &rds.DescribePendingMaintenanceActionsInput{Filters: []rdstypes.Filter{f}})
		for p.HasMorePages() {
			pg, err := p.NextPage(ctx)
			if err != nil {
				return nil, fmt.Errorf("DescribePendingMaintenanceActions: %w", err)
			}
			for _, r := range pg.PendingMaintenanceActions {
				for _, d := range r.PendingMaintenanceActionDetails {
					out = append(out, Row{"kind": "aws_pending", "resource": aws.ToString(r.ResourceIdentifier), "action": aws.ToString(d.Action),
						"description": aws.ToString(d.Description), "auto_applied_after": d.AutoAppliedAfterDate, "forced_apply": d.ForcedApplyDate,
						"current_apply": d.CurrentApplyDate, "opt_in_status": aws.ToString(d.OptInStatus)})
				}
			}
		}
	}
	return append(out, Row{"kind": "aws_read"}), nil
}
