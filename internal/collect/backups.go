package collect

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// backupsCollector reads whether the server's backups keep up, every 5 minutes. On every platform the WAL
// archiver (pg_stat_archiver, readable by any login): the archived and failed counts, the last archived and
// last failed WAL file and their times, and the archive lag, the WAL written since the end of the last
// archived segment (pg_current_wal_lsn; on a standby the WAL received, else replayed). Through the AWS door on RDS and Aurora: the
// backup retention days, the LatestRestorableTime (DescribeDBInstances on RDS, DescribeDBClusters on Aurora)
// and the newest automated and manual snapshots (DescribeDBSnapshots / DescribeDBClusterSnapshots). Read
// only. pgBackRest and barman are not read: their repositories live outside the server.
type backupsCollector struct{}

func init() { Register(backupsCollector{}) }

const (
	// backupSnapshotsKept is how many snapshots per type the collection keeps (the newest first).
	backupSnapshotsKept = 20
)

// archiveWarnMinutes is the instance's threshold for the archive-age finding; the config value
// (backups.archive_warn_minutes) is read here once the config carries it, else the default.
var archiveWarnMinutes = func(in config.Instance) int { return in.Backups.ArchiveWarn() }

func (backupsCollector) Name() string                         { return "backups" }
func (backupsCollector) DefaultInterval() time.Duration       { return 5 * time.Minute }
func (backupsCollector) Applies(platform.Info) (bool, string) { return true, "" }

func (b backupsCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return b.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

// backupsArchiverSQL reads the archiver. The lag: the current WAL position less the end of the last archived
// segment (its name is the timeline, then the segment number in two 8-hex halves; a .history, .partial or
// .backup name keeps the segment's 24 characters or none). The position: pg_current_wal_lsn on a primary; on a standby
// (where it fails) the last WAL received, else the last replayed, so a standby with archive_mode = always is measured.
const backupsArchiverSQL = `
WITH a AS (
  SELECT s.*, pg_size_bytes(current_setting('wal_segment_size')) AS seg, r.rec,
         CASE WHEN r.rec THEN coalesce(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) ELSE pg_current_wal_lsn() END AS lsn
    FROM pg_stat_archiver s CROSS JOIN (SELECT pg_is_in_recovery() AS rec) r
)
SELECT 'archiver' AS kind, 'pg_stat_archiver' AS name, current_setting('archive_mode') AS archive_mode,
       current_setting('archive_timeout') AS archive_timeout,
       (current_setting('archive_command') NOT IN ('', '(disabled)') OR coalesce(current_setting('archive_library', true), '') <> '') AS archive_set,
       a.archived_count, a.last_archived_wal, a.last_archived_time, a.failed_count, a.last_failed_wal, a.last_failed_time,
       a.stats_reset, a.rec AS is_replica, a.seg AS wal_segment_bytes,
       a.lsn::text AS current_lsn,
       CASE WHEN a.lsn IS NOT NULL AND a.last_archived_wal ~ '^[0-9A-F]{24}'
            THEN greatest(0, (a.lsn - '0/0'::pg_lsn)
                 - (('x' || substr(a.last_archived_wal, 9, 8))::bit(32)::bigint * 4294967296
                    + ('x' || substr(a.last_archived_wal, 17, 8))::bit(32)::bigint * a.seg + a.seg))::bigint
       END AS archive_lag_bytes
  FROM a`

// RunInstance reads the archiver, then the AWS side when the instance is RDS or Aurora and has an aws: block;
// an AWS failure is a collector_error row, the archiver row still lands.
func (backupsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	rows, err := conn.Query(ctx, backupsArchiverSQL)
	if err != nil {
		return nil, fmt.Errorf("backups: pg_stat_archiver: %w", err)
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, fmt.Errorf("backups: pg_stat_archiver: %w", err)
	}
	for _, r := range out {
		r["archive_warn_minutes"] = archiveWarnMinutes(in)
	}
	if (info.Kind != platform.RDS && info.Kind != platform.Aurora) || in.AWS == nil {
		return out, nil
	}
	id, err := hostAWSInstanceID(ctx, conn, info, *in.AWS)
	if err != nil && (info.Kind != platform.Aurora || in.AWS.Cluster == "") {
		if errors.Is(err, ErrSkip) {
			return out, nil // the aws: block names no DB instance (logs or DMS only): no backups to read
		}
		return append(out, Row{"kind": "collector_error", "source": "backups:aws", "message": err.Error()}), nil
	}
	api, err := backupsClientFor(ctx, *in.AWS)
	if err != nil {
		return append(out, Row{"kind": "collector_error", "source": "backups:aws", "message": err.Error()}), nil
	}
	return append(out, backupsCloudRows(ctx, api, info.Kind, id, in.AWS.Cluster)...), nil
}

// ---- the AWS door ------------------------------------------------------------------------------------

// backupsAPI is the slice of the RDS client the collection calls; a recorded set in a test.
type backupsAPI interface {
	rds.DescribeDBInstancesAPIClient
	rds.DescribeDBClustersAPIClient
	rds.DescribeDBSnapshotsAPIClient
	rds.DescribeDBClusterSnapshotsAPIClient
}

var (
	backupsClientsMu sync.Mutex
	backupsClients   = map[string]backupsAPI{}
)

var newBackupsAPI = func(ctx context.Context, a config.AWS) (backupsAPI, error) {
	cfg, err := loadAWS(ctx, a)
	if err != nil {
		return nil, err
	}
	return rds.NewFromConfig(cfg), nil
}

func backupsClientFor(ctx context.Context, a config.AWS) (backupsAPI, error) {
	k := a.Profile + "|" + a.Region
	backupsClientsMu.Lock()
	defer backupsClientsMu.Unlock()
	if c, ok := backupsClients[k]; ok {
		return c, nil
	}
	c, err := newBackupsAPI(ctx, a)
	if err == nil {
		backupsClients[k] = c
	}
	return c, err
}

// backupSnap is one snapshot as both describe calls return it.
type backupSnap struct {
	id, typ, status string
	created         *time.Time
	allocatedGiB    *int32
	encrypted       *bool
}

// backupsCloudRows reads the platform's backups: on RDS the instance's retention and restorable time and its
// snapshots; on Aurora the cluster's (the cluster from the config, else from the instance). Rows:
// {kind:'cloud', name:<resource id>, resource_kind:'instance'|'cluster', retention_days, latest_restorable_time,
// earliest_restorable_time, backup_window} and {kind:'snapshot', name:<snapshot id>, snapshot_type, status,
// created_at, allocated_gib, encrypted}, the newest backupSnapshotsKept per type; a failed call is a
// collector_error row and the parts that answered still land.
func backupsCloudRows(ctx context.Context, api backupsAPI, kind platform.Kind, id, cluster string) []Row {
	var out []Row
	errRow := func(src string, err error) Row {
		return Row{"kind": "collector_error", "source": "backups:" + src, "message": err.Error()}
	}
	var snaps []backupSnap
	if kind == platform.Aurora {
		if cluster == "" {
			di, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: aws.String(id)})
			if err != nil {
				return append(out, errRow("rds", fmt.Errorf("DescribeDBInstances %s: %w", id, err)))
			}
			if len(di.DBInstances) > 0 {
				cluster = aws.ToString(di.DBInstances[0].DBClusterIdentifier)
			}
			if cluster == "" {
				return append(out, errRow("rds", fmt.Errorf("DB instance %s names no cluster (set aws.cluster in the config)", id)))
			}
		}
		dc, err := api.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{DBClusterIdentifier: aws.String(cluster)})
		switch {
		case err != nil:
			out = append(out, errRow("rds", fmt.Errorf("DescribeDBClusters %s: %w", cluster, err)))
		case len(dc.DBClusters) == 0:
			out = append(out, errRow("rds", fmt.Errorf("DescribeDBClusters %s: no cluster returned", cluster)))
		default:
			c := dc.DBClusters[0]
			out = append(out, Row{"kind": "cloud", "name": cluster, "resource_kind": "cluster", "retention_days": c.BackupRetentionPeriod,
				"latest_restorable_time": utcPtr(c.LatestRestorableTime), "earliest_restorable_time": utcPtr(c.EarliestRestorableTime),
				"backup_window": nilIfEmpty(aws.ToString(c.PreferredBackupWindow))})
		}
		p := rds.NewDescribeDBClusterSnapshotsPaginator(api, &rds.DescribeDBClusterSnapshotsInput{DBClusterIdentifier: aws.String(cluster)})
		for p.HasMorePages() {
			page, err := p.NextPage(ctx)
			if err != nil {
				return append(out, errRow("snapshots", fmt.Errorf("DescribeDBClusterSnapshots %s: %w", cluster, err)))
			}
			for _, s := range page.DBClusterSnapshots {
				snaps = append(snaps, backupSnap{aws.ToString(s.DBClusterSnapshotIdentifier), aws.ToString(s.SnapshotType), aws.ToString(s.Status),
					s.SnapshotCreateTime, s.AllocatedStorage, s.StorageEncrypted})
			}
		}
		return append(out, snapshotRows(snaps)...)
	}
	di, err := api.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: aws.String(id)})
	switch {
	case err != nil:
		out = append(out, errRow("rds", fmt.Errorf("DescribeDBInstances %s: %w", id, err)))
	case len(di.DBInstances) == 0:
		out = append(out, errRow("rds", fmt.Errorf("DescribeDBInstances %s: no instance returned", id)))
	default:
		d := di.DBInstances[0]
		out = append(out, Row{"kind": "cloud", "name": id, "resource_kind": "instance", "retention_days": d.BackupRetentionPeriod,
			"latest_restorable_time": utcPtr(d.LatestRestorableTime), "backup_window": nilIfEmpty(aws.ToString(d.PreferredBackupWindow))})
	}
	p := rds.NewDescribeDBSnapshotsPaginator(api, &rds.DescribeDBSnapshotsInput{DBInstanceIdentifier: aws.String(id)})
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return append(out, errRow("snapshots", fmt.Errorf("DescribeDBSnapshots %s: %w", id, err)))
		}
		for _, s := range page.DBSnapshots {
			snaps = append(snaps, backupSnap{aws.ToString(s.DBSnapshotIdentifier), aws.ToString(s.SnapshotType), aws.ToString(s.Status),
				s.SnapshotCreateTime, s.AllocatedStorage, s.Encrypted})
		}
	}
	return append(out, snapshotRows(snaps)...)
}

// snapshotRows keeps the newest backupSnapshotsKept snapshots of each type, the newest first, and always
// returns a 'snapshots_read' row so the import knows the list was read (an empty list marks every stored
// snapshot absent; a failed read leaves them).
func snapshotRows(snaps []backupSnap) []Row {
	sort.SliceStable(snaps, func(i, j int) bool {
		a, b := snaps[i].created, snaps[j].created
		if a == nil || b == nil {
			return b == nil && a != nil
		}
		return a.After(*b)
	})
	per := map[string]int{}
	out := []Row{}
	for _, s := range snaps {
		if s.id == "" || per[s.typ] >= backupSnapshotsKept {
			continue
		}
		per[s.typ]++
		out = append(out, Row{"kind": "snapshot", "name": s.id, "snapshot_type": nilIfEmpty(s.typ), "status": nilIfEmpty(s.status),
			"created_at": utcPtr(s.created), "allocated_gib": s.allocatedGiB, "encrypted": s.encrypted})
	}
	return append(out, Row{"kind": "snapshots_read", "name": "snapshots", "count": len(snaps)})
}

func utcPtr(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UTC()
}
