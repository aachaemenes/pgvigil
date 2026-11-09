package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch"
	cwtypes "github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// storageCollector reads what fills a server's storage, every 15 minutes: the WAL directory
// (pg_ls_waldir(), granted to pg_monitor), every tablespace's size (pg_tablespace_size, which
// pg_read_all_stats - in pg_monitor - may read) and, through the AWS door, the platform's volume: on RDS
// the allocated storage, the storage autoscaling maximum and type (DescribeDBInstances); on Aurora the
// cluster volume's VolumeBytesUsed against its 128 TiB limit (CloudWatch). The volumes on-prem, their
// free space and its history are the host collection's (host_disks); the database and table sizes are
// the databases and tables collections'; migration 0033 forecasts over all of them.
type storageCollector struct{}

func init() { Register(storageCollector{}) }

// auroraVolumeLimit is an Aurora PostgreSQL cluster volume's maximum size (128 TiB).
const auroraVolumeLimit = int64(128) << 40

func (storageCollector) Name() string                         { return "storage" }
func (storageCollector) DefaultInterval() time.Duration       { return 15 * time.Minute }
func (storageCollector) Applies(platform.Info) (bool, string) { return true, "" }

func (s storageCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return s.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

// storageSQL: each read on its own, so a missing grant on one keeps the other (Aurora keeps no WAL in
// pg_wal: its count is 0 there).
var storageSQL = []struct{ name, sql string }{
	{"wal", `SELECT 'wal' AS kind, 'pg_wal' AS name, NULL::text AS location, coalesce(sum(w.size), 0)::bigint AS size_bytes,
       count(*)::bigint AS files
  FROM pg_ls_waldir() w`},
	{"tablespace", `SELECT 'tablespace' AS kind, t.spcname::text AS name, nullif(pg_tablespace_location(t.oid), '') AS location,
       pg_tablespace_size(t.oid) AS size_bytes, NULL::bigint AS files
  FROM pg_tablespace t`},
}

// RunInstance reads the SQL side, then the AWS side when the instance is RDS or Aurora and has an aws:
// block; an AWS failure is a collector_error row, the SQL rows still land.
func (storageCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	out := []Row{}
	failed := 0
	for _, q := range storageSQL {
		rows, err := conn.Query(ctx, q.sql)
		if err == nil {
			var got []Row
			if got, err = rowsToMaps(rows); err == nil {
				out = append(out, got...)
				continue
			}
		}
		failed++
		out = append(out, Row{"kind": "collector_error", "source": "storage:" + q.name, "message": err.Error()})
	}
	if failed == len(storageSQL) {
		return nil, fmt.Errorf("storage: %v", out[0]["message"])
	}
	if (info.Kind != platform.RDS && info.Kind != platform.Aurora) || in.AWS == nil {
		return out, nil
	}
	id, err := hostAWSInstanceID(ctx, conn, info, *in.AWS)
	if err != nil && (info.Kind != platform.Aurora || in.AWS.Cluster == "") {
		return append(out, Row{"kind": "collector_error", "source": "storage:aws", "message": err.Error()}), nil
	}
	api, err := hostClientFor(ctx, *in.AWS)
	if err != nil {
		return append(out, Row{"kind": "collector_error", "source": "storage:aws", "message": err.Error()}), nil
	}
	return append(out, storageCloudRows(ctx, api, info.Kind, id, in.AWS.Cluster, time.Now())...), nil
}

// storageCloudRows reads the platform's volume: RDS DescribeDBInstances (allocated, the autoscaling maximum),
// and on Aurora the cluster's VolumeBytesUsed (the cluster from the config, else from the instance).
func storageCloudRows(ctx context.Context, api hostAPI, kind platform.Kind, id, cluster string, now time.Time) []Row {
	var out []Row
	errRow := func(src string, err error) Row {
		return Row{"kind": "collector_error", "source": "storage:" + src, "message": err.Error()}
	}
	if id != "" {
		d, err := describeDBInstance(ctx, api, id, now)
		switch {
		case err != nil:
			out = append(out, errRow("rds", err))
		case d != nil:
			if cluster == "" {
				cluster = aws.ToString(d.DBClusterIdentifier)
			}
			if kind == platform.RDS {
				row := Row{"kind": "rds", "name": id, "storage_type": nilIfEmpty(aws.ToString(d.StorageType)),
					"iops": d.Iops, "throughput": d.StorageThroughput, "class": nilIfEmpty(aws.ToString(d.DBInstanceClass))}
				if d.AllocatedStorage != nil {
					row["allocated_bytes"] = int64(*d.AllocatedStorage) << 30
				}
				// storage autoscaling is on when a maximum above the allocated size is set
				if d.MaxAllocatedStorage != nil {
					row["max_allocated_bytes"] = int64(*d.MaxAllocatedStorage) << 30
					row["autoscaling"] = d.AllocatedStorage != nil && *d.MaxAllocatedStorage > *d.AllocatedStorage
				} else {
					row["autoscaling"] = false
				}
				out = append(out, row)
			}
		}
	}
	if kind != platform.Aurora || cluster == "" {
		return out
	}
	res, err := api.GetMetricData(ctx, &cloudwatch.GetMetricDataInput{
		StartTime: aws.Time(now.Add(-6 * time.Hour)), EndTime: aws.Time(now), ScanBy: cwtypes.ScanByTimestampDescending,
		MetricDataQueries: []cwtypes.MetricDataQuery{{
			Id: aws.String("v"),
			MetricStat: &cwtypes.MetricStat{
				Metric: &cwtypes.Metric{Namespace: aws.String("AWS/RDS"), MetricName: aws.String("VolumeBytesUsed"),
					Dimensions: []cwtypes.Dimension{{Name: aws.String("DBClusterIdentifier"), Value: aws.String(cluster)}}},
				Period: aws.Int32(300), Stat: aws.String("Maximum"),
			},
		}},
	})
	if err != nil {
		return append(out, errRow("cloudwatch", fmt.Errorf("GetMetricData VolumeBytesUsed %s: %w", cluster, err)))
	}
	for _, r := range res.MetricDataResults {
		if len(r.Values) > 0 && len(r.Timestamps) > 0 {
			return append(out, Row{"kind": "aurora_volume", "name": cluster, "size_bytes": int64(r.Values[0]),
				"limit_bytes": auroraVolumeLimit, "metrics_at": r.Timestamps[0].UTC()})
		}
	}
	return append(out, errRow("cloudwatch", fmt.Errorf("no VolumeBytesUsed datapoint for cluster %s in the last 6 hours", cluster)))
}
