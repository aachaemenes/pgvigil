package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// backupsRDS answers the four describe calls from testdata/backups. Every file there is constructed by hand
// from the documented fields of the calls (named *-constructed), not recorded: the lab's session had expired.
// clusters-constructed.json (DescribeDBClusters), cluster-snapshots-constructed.json (DescribeDBClusterSnapshots),
// instances-aurora-constructed.json / instances-rds-constructed.json (DescribeDBInstances, by the asked id) and
// snapshots-rds-constructed.json (DescribeDBSnapshots).
type backupsRDS struct {
	t        *testing.T
	calls    map[string]int
	failOn   string
	pageSize int                   // > 0: the snapshot lists are served this many per page (Marker = the offset)
	extra    []rdstypes.DBSnapshot // appended to the RDS snapshot list
}

func newBackupsRDS(t *testing.T) *backupsRDS { return &backupsRDS{t: t, calls: map[string]int{}} }

func (r *backupsRDS) load(call, name string, into any) error {
	r.calls[call]++
	if r.failOn == call {
		return errors.New("recorded: " + call + " refused")
	}
	raw, err := os.ReadFile(filepath.Join("testdata", "backups", name))
	if err != nil {
		r.t.Fatal(err)
	}
	return json.Unmarshal(raw, into)
}

func (r *backupsRDS) page(n int, marker *string) (from, to int, next *string) {
	if r.pageSize <= 0 {
		return 0, n, nil
	}
	from, _ = strconv.Atoi(aws.ToString(marker))
	to = min(from+r.pageSize, n)
	if to < n {
		next = aws.String(strconv.Itoa(to))
	}
	return from, to, next
}

func (r *backupsRDS) DescribeDBInstances(_ context.Context, in *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	var out rds.DescribeDBInstancesOutput
	name := "instances-rds-constructed.json"
	if aws.ToString(in.DBInstanceIdentifier) == "dba-lab-pg-instance-1" {
		name = "instances-aurora-constructed.json"
	}
	if err := r.load("DescribeDBInstances", name, &out); err != nil {
		return nil, err
	}
	if aws.ToString(out.DBInstances[0].DBInstanceIdentifier) != aws.ToString(in.DBInstanceIdentifier) {
		return nil, &rdstypes.DBInstanceNotFoundFault{Message: aws.String("no instance " + aws.ToString(in.DBInstanceIdentifier))}
	}
	return &out, nil
}

func (r *backupsRDS) DescribeDBClusters(_ context.Context, in *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	var out rds.DescribeDBClustersOutput
	if err := r.load("DescribeDBClusters", "clusters-constructed.json", &out); err != nil {
		return nil, err
	}
	if aws.ToString(out.DBClusters[0].DBClusterIdentifier) != aws.ToString(in.DBClusterIdentifier) {
		return nil, &rdstypes.DBClusterNotFoundFault{Message: aws.String("no cluster " + aws.ToString(in.DBClusterIdentifier))}
	}
	return &out, nil
}

func (r *backupsRDS) DescribeDBClusterSnapshots(_ context.Context, in *rds.DescribeDBClusterSnapshotsInput, _ ...func(*rds.Options)) (*rds.DescribeDBClusterSnapshotsOutput, error) {
	var out rds.DescribeDBClusterSnapshotsOutput
	if err := r.load("DescribeDBClusterSnapshots", "cluster-snapshots-constructed.json", &out); err != nil {
		return nil, err
	}
	if aws.ToString(in.DBClusterIdentifier) != "dba-lab-pg" {
		return &rds.DescribeDBClusterSnapshotsOutput{}, nil
	}
	from, to, next := r.page(len(out.DBClusterSnapshots), in.Marker)
	return &rds.DescribeDBClusterSnapshotsOutput{DBClusterSnapshots: out.DBClusterSnapshots[from:to], Marker: next}, nil
}

func (r *backupsRDS) DescribeDBSnapshots(_ context.Context, in *rds.DescribeDBSnapshotsInput, _ ...func(*rds.Options)) (*rds.DescribeDBSnapshotsOutput, error) {
	var out rds.DescribeDBSnapshotsOutput
	if err := r.load("DescribeDBSnapshots", "snapshots-rds-constructed.json", &out); err != nil {
		return nil, err
	}
	all := append(append([]rdstypes.DBSnapshot{}, out.DBSnapshots...), r.extra...)
	from, to, next := r.page(len(all), in.Marker)
	return &rds.DescribeDBSnapshotsOutput{DBSnapshots: all[from:to], Marker: next}, nil
}

// backupsByKind splits the rows: the kinds in order of appearance, and the rows of each kind.
func backupsByKind(rows []Row) map[string][]Row {
	out := map[string][]Row{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		out[k] = append(out[k], r)
	}
	return out
}

func snapNames(rows []Row) []string {
	var out []string
	for _, r := range rows {
		out = append(out, r["name"].(string))
	}
	return out
}

func TestBackupsAuroraCluster(t *testing.T) {
	for _, tc := range []struct {
		name, cluster string
		pageSize      int
		wantDescInst  int
	}{
		{"cluster from the config", "dba-lab-pg", 0, 0},
		{"cluster from the instance", "", 0, 1},
		{"snapshots paged one at a time", "dba-lab-pg", 1, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := newBackupsRDS(t)
			api.pageSize = tc.pageSize
			k := backupsByKind(backupsCloudRows(context.Background(), api, platform.Aurora, "dba-lab-pg-instance-1", tc.cluster))
			if len(k["collector_error"]) > 0 {
				t.Fatalf("unexpected error rows: %v", k["collector_error"])
			}
			if got := api.calls["DescribeDBInstances"]; got != tc.wantDescInst {
				t.Errorf("DescribeDBInstances calls = %d, want %d", got, tc.wantDescInst)
			}
			if len(k["cloud"]) != 1 {
				t.Fatalf("cloud rows = %d, want 1", len(k["cloud"]))
			}
			c := k["cloud"][0]
			if c["name"] != "dba-lab-pg" || c["resource_kind"] != "cluster" || aws.ToInt32(c["retention_days"].(*int32)) != 1 {
				t.Errorf("cloud row = %v", c)
			}
			if lr, _ := c["latest_restorable_time"].(time.Time); !lr.Equal(time.Date(2026, 11, 9, 22, 55, 41, 0, time.UTC)) {
				t.Errorf("latest_restorable_time = %v", c["latest_restorable_time"])
			}
			if c["backup_window"] != "07:22-07:52" {
				t.Errorf("backup_window = %v", c["backup_window"])
			}
			want := []string{"before-upgrade", "rds:dba-lab-pg-2026-11-09-07-30", "rds:dba-lab-pg-2026-11-08-07-31"}
			if got := snapNames(k["snapshot"]); fmt.Sprint(got) != fmt.Sprint(want) {
				t.Errorf("snapshots = %v, want %v (the newest first)", got, want)
			}
			if s := k["snapshot"][0]; s["snapshot_type"] != "manual" || s["status"] != "creating" {
				t.Errorf("manual snapshot row = %v", s)
			}
			if len(k["snapshots_read"]) != 1 || k["snapshots_read"][0]["count"] != 3 {
				t.Errorf("snapshots_read = %v, want one row with count 3", k["snapshots_read"])
			}
		})
	}
}

func TestBackupsRDSInstance(t *testing.T) {
	api := newBackupsRDS(t)
	k := backupsByKind(backupsCloudRows(context.Background(), api, platform.RDS, "orders-rds", ""))
	if len(k["collector_error"]) > 0 {
		t.Fatalf("unexpected error rows: %v", k["collector_error"])
	}
	if api.calls["DescribeDBClusters"]+api.calls["DescribeDBClusterSnapshots"] != 0 {
		t.Errorf("an RDS instance read cluster calls: %v", api.calls)
	}
	c := k["cloud"][0]
	if c["name"] != "orders-rds" || c["resource_kind"] != "instance" || aws.ToInt32(c["retention_days"].(*int32)) != 3 {
		t.Errorf("cloud row = %v", c)
	}
	if c["earliest_restorable_time"] != nil {
		t.Errorf("an RDS instance has no earliest_restorable_time in the row: %v", c["earliest_restorable_time"])
	}
	if got := snapNames(k["snapshot"]); fmt.Sprint(got) != "[rds:orders-rds-2026-11-09-03-05 orders-before-migration]" {
		t.Errorf("snapshots = %v", got)
	}
	if e := k["snapshot"][1]["encrypted"].(*bool); e == nil || *e {
		t.Errorf("manual snapshot encrypted = %v, want false", e)
	}
}

func TestBackupsSnapshotCap(t *testing.T) {
	api := newBackupsRDS(t)
	api.pageSize = 7
	base := time.Date(2026, 10, 1, 3, 0, 0, 0, time.UTC)
	for i := 0; i < 25; i++ {
		at := base.Add(time.Duration(i) * 24 * time.Hour)
		api.extra = append(api.extra, rdstypes.DBSnapshot{DBSnapshotIdentifier: aws.String(fmt.Sprintf("rds:orders-rds-old-%02d", i)),
			SnapshotType: aws.String("automated"), Status: aws.String("available"), SnapshotCreateTime: &at})
	}
	k := backupsByKind(backupsCloudRows(context.Background(), api, platform.RDS, "orders-rds", ""))
	per := map[any]int{}
	for _, s := range k["snapshot"] {
		per[s["snapshot_type"]]++
	}
	if per["automated"] != backupSnapshotsKept || per["manual"] != 1 {
		t.Errorf("kept per type = %v, want %d automated and 1 manual", per, backupSnapshotsKept)
	}
	if k["snapshot"][0]["name"] != "rds:orders-rds-2026-11-09-03-05" {
		t.Errorf("newest = %v", k["snapshot"][0]["name"])
	}
	if k["snapshots_read"][0]["count"] != 27 {
		t.Errorf("snapshots_read count = %v, want 27 (every listed snapshot, kept or not)", k["snapshots_read"][0]["count"])
	}
}

func TestBackupsPartialFailure(t *testing.T) {
	api := newBackupsRDS(t)
	api.failOn = "DescribeDBClusterSnapshots"
	k := backupsByKind(backupsCloudRows(context.Background(), api, platform.Aurora, "dba-lab-pg-instance-1", "dba-lab-pg"))
	if len(k["cloud"]) != 1 {
		t.Errorf("the cluster row must still land: %v", k)
	}
	if len(k["snapshots_read"]) != 0 || len(k["snapshot"]) != 0 {
		t.Errorf("a failed snapshot list must not say it was read (the import would mark every snapshot absent): %v", k)
	}
	if len(k["collector_error"]) != 1 || k["collector_error"][0]["source"] != "backups:snapshots" {
		t.Errorf("error rows = %v", k["collector_error"])
	}

	api = newBackupsRDS(t)
	api.failOn = "DescribeDBClusters"
	k = backupsByKind(backupsCloudRows(context.Background(), api, platform.Aurora, "dba-lab-pg-instance-1", "dba-lab-pg"))
	if len(k["cloud"]) != 0 || len(k["snapshot"]) != 3 || len(k["collector_error"]) != 1 || k["collector_error"][0]["source"] != "backups:rds" {
		t.Errorf("a failed DescribeDBClusters keeps the snapshots and reports backups:rds: %v", k)
	}

	api = newBackupsRDS(t)
	api.failOn = "DescribeDBInstances"
	k = backupsByKind(backupsCloudRows(context.Background(), api, platform.Aurora, "dba-lab-pg-instance-1", ""))
	if len(k) != 1 || len(k["collector_error"]) != 1 {
		t.Errorf("no cluster found = one error row, nothing else: %v", k)
	}
}
