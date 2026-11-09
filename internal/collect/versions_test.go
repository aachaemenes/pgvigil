package collect

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// recordedRDS answers the four RDS calls from testdata/versions (the AWS CLI's JSON, which unmarshals into the
// SDK output types by field name). Recorded from the lab's Aurora cluster (account id replaced, only the fields
// the collector reads kept): clusters.json, instances-cluster.json, pending-cluster.json, pending-instance.json,
// and engine-versions-<engine>-<version>.json (aurora-postgresql 17.9 and the deprecated 15.2, postgres 16.4:
// DescribeDBEngineVersions needs no resource, so these three are real responses). The RDS-instance branch has no
// lab resource: instance-rds-constructed.json and pending-rds-constructed.json are built by hand from the
// documented fields of DescribeDBInstances and DescribePendingMaintenanceActions, not recorded.
type recordedRDS struct {
	t             *testing.T
	dir           string
	calls         map[string]int
	failOn        string // the call that returns an error
	engineVersion string // replaces the recorded cluster's EngineVersion (the deprecated case)
}

func newRecordedRDS(t *testing.T) *recordedRDS {
	return &recordedRDS{t: t, dir: filepath.Join("testdata", "versions"), calls: map[string]int{}}
}

func (r *recordedRDS) load(call, name string, into any) error {
	r.calls[call]++
	if r.failOn == call {
		return errors.New("recorded: " + call + " refused")
	}
	raw, err := os.ReadFile(filepath.Join(r.dir, name))
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, into)
}

func filterValues(fs []rdstypes.Filter, name string) []string {
	for _, f := range fs {
		if aws.ToString(f.Name) == name {
			return f.Values
		}
	}
	return nil
}

func (r *recordedRDS) DescribeDBClusters(_ context.Context, in *rds.DescribeDBClustersInput, _ ...func(*rds.Options)) (*rds.DescribeDBClustersOutput, error) {
	var out rds.DescribeDBClustersOutput
	if err := r.load("DescribeDBClusters", "clusters.json", &out); err != nil {
		return nil, err
	}
	var keep []rdstypes.DBCluster
	for _, c := range out.DBClusters {
		if aws.ToString(c.DBClusterIdentifier) == aws.ToString(in.DBClusterIdentifier) {
			if r.engineVersion != "" {
				c.EngineVersion = aws.String(r.engineVersion)
			}
			keep = append(keep, c)
		}
	}
	if len(keep) == 0 {
		return nil, &rdstypes.DBClusterNotFoundFault{Message: aws.String("no cluster " + aws.ToString(in.DBClusterIdentifier))}
	}
	out.DBClusters = keep
	return &out, nil
}

func (r *recordedRDS) DescribeDBInstances(_ context.Context, in *rds.DescribeDBInstancesInput, _ ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	var out rds.DescribeDBInstancesOutput
	if ids := filterValues(in.Filters, "db-cluster-id"); len(ids) > 0 {
		if err := r.load("DescribeDBInstances", "instances-cluster.json", &out); err != nil {
			return nil, err
		}
		return &out, nil
	}
	if err := r.load("DescribeDBInstances", "instance-rds-constructed.json", &out); err != nil {
		return nil, err
	}
	var keep []rdstypes.DBInstance
	for _, i := range out.DBInstances {
		if aws.ToString(i.DBInstanceIdentifier) == aws.ToString(in.DBInstanceIdentifier) {
			keep = append(keep, i)
		}
	}
	if len(keep) == 0 {
		return nil, &rdstypes.DBInstanceNotFoundFault{Message: aws.String("no instance")}
	}
	out.DBInstances = keep
	return &out, nil
}

func (r *recordedRDS) DescribeDBEngineVersions(_ context.Context, in *rds.DescribeDBEngineVersionsInput, _ ...func(*rds.Options)) (*rds.DescribeDBEngineVersionsOutput, error) {
	var out rds.DescribeDBEngineVersionsOutput
	name := "engine-versions-" + aws.ToString(in.Engine) + "-" + aws.ToString(in.EngineVersion) + ".json"
	if err := r.load("DescribeDBEngineVersions", name, &out); err != nil {
		return nil, err
	}
	// the API leaves a deprecated version out unless IncludeAll is set
	if !aws.ToBool(in.IncludeAll) {
		var keep []rdstypes.DBEngineVersion
		for _, v := range out.DBEngineVersions {
			if aws.ToString(v.Status) != "deprecated" {
				keep = append(keep, v)
			}
		}
		out.DBEngineVersions = keep
	}
	return &out, nil
}

func (r *recordedRDS) DescribePendingMaintenanceActions(_ context.Context, in *rds.DescribePendingMaintenanceActionsInput, _ ...func(*rds.Options)) (*rds.DescribePendingMaintenanceActionsOutput, error) {
	var out rds.DescribePendingMaintenanceActionsOutput
	name := ""
	switch {
	case len(filterValues(in.Filters, "db-cluster-id")) > 0:
		name = "pending-cluster.json"
	case reflect.DeepEqual(filterValues(in.Filters, "db-instance-id"), []string{"orders-db"}):
		name = "pending-rds-constructed.json"
	case len(filterValues(in.Filters, "db-instance-id")) > 0:
		name = "pending-instance.json"
	default:
		r.t.Fatalf("DescribePendingMaintenanceActions without a filter: %+v", in.Filters)
	}
	if err := r.load("DescribePendingMaintenanceActions", name, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// rowsByKind groups rows by kind.
func rowsByKind(rows []Row) map[string][]Row {
	m := map[string][]Row{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		m[k] = append(m[k], r)
	}
	return m
}

func targetVersions(rows []Row, major bool) []string {
	var out []string
	for _, r := range rows {
		if r["is_major"] == major {
			out = append(out, r["engine_version"].(string))
		}
	}
	sort.Strings(out)
	return out
}

func TestVersionsAWSCluster(t *testing.T) {
	api := newRecordedRDS(t)
	rows, err := versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	k := rowsByKind(rows)
	if len(k["aws_engine"]) != 1 || rows[0]["kind"] != "aws_engine" {
		t.Fatalf("the aws_engine row must lead: %v", rows[0])
	}
	e := k["aws_engine"][0]
	if e["resource"] != "cluster:dba-lab-pg" || e["engine"] != "aurora-postgresql" || e["engine_version"] != "17.9" ||
		e["engine_status"] != "available" || aws.ToBool(e["auto_minor_version_upgrade"].(*bool)) != true ||
		e["maintenance_window"] != "fri:03:28-fri:03:58" || !reflect.DeepEqual(e["members"], []string{"dba-lab-pg-instance-1"}) {
		t.Errorf("aws_engine: %v", e)
	}
	if len(k["aws_instance"]) != 1 || k["aws_instance"][0]["id"] != "dba-lab-pg-instance-1" || k["aws_instance"][0]["is_writer"] != true ||
		k["aws_instance"][0]["class"] != "db.serverless" {
		t.Errorf("aws_instance: %v", k["aws_instance"])
	}
	if got := targetVersions(k["aws_target"], false); !reflect.DeepEqual(got, []string{"17.10", "17.11"}) {
		t.Errorf("minor targets %v", got)
	}
	if got := targetVersions(k["aws_target"], true); !reflect.DeepEqual(got, []string{"18.3", "18.4", "18.6"}) {
		t.Errorf("major targets %v", got)
	}
	// the cluster's own action and its instance's: both filters were asked
	if len(k["aws_pending"]) != 2 || api.calls["DescribePendingMaintenanceActions"] != 2 {
		t.Fatalf("pending rows %v after %d calls", k["aws_pending"], api.calls["DescribePendingMaintenanceActions"])
	}
	got := map[string]string{}
	for _, p := range k["aws_pending"] {
		got[p["action"].(string)] = p["resource"].(string)
		if p["forced_apply"].(*time.Time) != nil || p["auto_applied_after"].(*time.Time) != nil {
			t.Errorf("the lab's actions are undated: %v", p)
		}
	}
	if got["os-upgrade"] != "arn:aws:rds:us-east-2:123456789012:cluster:dba-lab-pg" ||
		got["system-update"] != "arn:aws:rds:us-east-2:123456789012:db:dba-lab-pg-instance-1" {
		t.Errorf("pending resources %v", got)
	}
	if rows[len(rows)-1]["kind"] != "aws_read" {
		t.Errorf("a complete read ends with aws_read: %v", rows[len(rows)-1])
	}
}

func TestVersionsAWSDeprecatedCluster(t *testing.T) {
	api := newRecordedRDS(t)
	api.engineVersion = "15.2"
	rows, err := versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	k := rowsByKind(rows)
	if k["aws_engine"][0]["engine_status"] != "deprecated" {
		t.Errorf("engine_status %v", k["aws_engine"][0]["engine_status"])
	}
	// the recorded 15.2 lists 25 targets (IncludeAll); without it the API lists none
	if len(k["aws_target"]) != 25 {
		t.Errorf("targets of a deprecated version: %d, want 25", len(k["aws_target"]))
	}
}

// The RDS-instance branch, against the constructed instance (no RDS instance in the lab) and the recorded
// postgres 16.4 engine versions.
func TestVersionsAWSInstanceConstructed(t *testing.T) {
	api := newRecordedRDS(t)
	rows, err := versionsAWSRows(context.Background(), api, config.AWS{DBInstance: "orders-db"})
	if err != nil {
		t.Fatal(err)
	}
	k := rowsByKind(rows)
	e := k["aws_engine"][0]
	if e["resource"] != "instance:orders-db" || e["engine"] != "postgres" || e["engine_version"] != "16.4" ||
		e["engine_status"] != "deprecated" || aws.ToBool(e["auto_minor_version_upgrade"].(*bool)) != false {
		t.Errorf("aws_engine: %v", e)
	}
	if len(k["aws_instance"]) != 0 || api.calls["DescribeDBClusters"] != 0 {
		t.Errorf("an RDS instance has no cluster members: %v, %d cluster calls", k["aws_instance"], api.calls["DescribeDBClusters"])
	}
	if n := len(k["aws_target"]); n != 19 {
		t.Errorf("postgres 16.4 targets: %d, want 19", n)
	}
	if len(k["aws_pending"]) != 1 || api.calls["DescribePendingMaintenanceActions"] != 1 {
		t.Fatalf("pending %v after %d calls", k["aws_pending"], api.calls["DescribePendingMaintenanceActions"])
	}
	p := k["aws_pending"][0]
	if p["action"] != "db-upgrade" || p["opt_in_status"] != "next-maintenance" ||
		!p["forced_apply"].(*time.Time).Equal(time.Date(2027, 1, 15, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("pending: %v", p)
	}
}

// An error part-way gives no rows at all (RunInstance turns it into a collector_error row, and the import then
// keeps the last AWS read: no aws_read row).
func TestVersionsAWSErrorMidway(t *testing.T) {
	for _, call := range []string{"DescribeDBClusters", "DescribeDBInstances", "DescribeDBEngineVersions", "DescribePendingMaintenanceActions"} {
		api := newRecordedRDS(t)
		api.failOn = call
		rows, err := versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
		if err == nil || rows != nil {
			t.Errorf("%s refused: rows %v, err %v", call, rows, err)
		}
	}
	if _, err := versionsAWSRows(context.Background(), newRecordedRDS(t), config.AWS{Cluster: "no-such-cluster"}); err == nil {
		t.Error("an unknown cluster must fail")
	}
}

// The recorded cluster read imported into a repository (PGVIGIL_REPO_DSN): the AWS side lands, a second read with
// only the server row keeps it.
func TestVersionsFixtureImport(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx := context.Background()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	aw, err := versionsAWSRows(ctx, newRecordedRDS(t), config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	server := Row{"kind": "server", "server_version_num": 170009, "server_version": "17.9", "version_string": "PostgreSQL 17.9",
		"aurora_version": "17.9.5", "postmaster_start": time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}
	name := "versions-fixture-" + time.Now().UTC().Format("150405.000")
	id, err := r.EnsureInstance(ctx, name, "aurora", "17.9", 170009, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC()
	if err := r.Import(ctx, id, "versions", at, append([]Row{server}, aw...)); err != nil {
		t.Fatal(err)
	}
	if err := r.Import(ctx, id, "versions", at.Add(time.Minute), []Row{server}); err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	var got string
	if err := conn.QueryRow(ctx, `SELECT engine || '|' || engine_version || '|' || engine_status || '|' || pending_actions || '|' || upgrade_targets
	                                FROM pgvigil.versions_fleet WHERE instance_id = $1`, id).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if want := "aurora-postgresql|17.9|available|2|17.10, 17.11, 18.3, 18.4, 18.6"; got != want {
		t.Errorf("fleet row %q, want %q", got, want)
	}
	var findings int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM pgvigil.version_findings WHERE instance_id = $1 AND setting = 'pending maintenance' AND severity = 'info'`, id).Scan(&findings); err != nil {
		t.Fatal(err)
	}
	if findings != 2 {
		t.Errorf("undated pending actions: %d info findings, want 2", findings)
	}
	if _, err := conn.Exec(ctx, `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
		t.Logf("cleanup: %v", err)
	}
}
