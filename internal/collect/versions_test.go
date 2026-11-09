package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
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
	engineVersion string // replaces the recorded cluster's EngineVersion (the deprecated and unknown cases)
	clusterAMVU   *bool  // replaces the recorded cluster's AutoMinorVersionUpgrade
	dropAMVU      bool   // the cluster carries no AutoMinorVersionUpgrade (the import's bool_and fallback)
	extraMembers  int    // adds synthetic reader instances to the cluster, each with its own pending action
	pageSize      int    // > 0: the two paged calls answer this many items per page (Marker = the offset)
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

// page cuts n items at the marker's offset and returns the next marker (nil on the last page).
func (r *recordedRDS) page(n int, marker *string) (from, to int, next *string) {
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

func (r *recordedRDS) extraID(i int) string { return fmt.Sprintf("dba-lab-pg-instance-%d", i+2) }

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
		if aws.ToString(c.DBClusterIdentifier) != aws.ToString(in.DBClusterIdentifier) {
			continue
		}
		if r.engineVersion != "" {
			c.EngineVersion = aws.String(r.engineVersion)
		}
		if r.clusterAMVU != nil {
			c.AutoMinorVersionUpgrade = r.clusterAMVU
		}
		if r.dropAMVU {
			c.AutoMinorVersionUpgrade = nil
		}
		for i := 0; i < r.extraMembers; i++ {
			c.DBClusterMembers = append(c.DBClusterMembers, rdstypes.DBClusterMember{DBInstanceIdentifier: aws.String(r.extraID(i)), IsClusterWriter: aws.Bool(false)})
		}
		keep = append(keep, c)
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
		for i := 0; i < r.extraMembers; i++ {
			x := out.DBInstances[0]
			x.DBInstanceIdentifier = aws.String(r.extraID(i))
			out.DBInstances = append(out.DBInstances, x)
		}
		from, to, next := r.page(len(out.DBInstances), in.Marker)
		out.DBInstances, out.Marker = out.DBInstances[from:to], next
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
		if errors.Is(err, os.ErrNotExist) {
			return &out, nil // the API answers a version it does not know with an empty list, not an error
		}
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
	inst := filterValues(in.Filters, "db-instance-id")
	switch {
	case len(filterValues(in.Filters, "db-cluster-id")) > 0:
		name = "pending-cluster.json"
	case reflect.DeepEqual(inst, []string{"orders-db"}):
		name = "pending-rds-constructed.json"
	case len(inst) > 0:
		name = "pending-instance.json"
	default:
		r.t.Fatalf("DescribePendingMaintenanceActions without a filter: %+v", in.Filters)
	}
	if err := r.load("DescribePendingMaintenanceActions", name, &out); err != nil {
		return nil, err
	}
	if name == "pending-instance.json" {
		for i := 0; i < r.extraMembers; i++ {
			x := out.PendingMaintenanceActions[0]
			x.ResourceIdentifier = aws.String("arn:aws:rds:us-east-2:123456789012:db:" + r.extraID(i))
			out.PendingMaintenanceActions = append(out.PendingMaintenanceActions, x)
		}
	}
	from, to, next := r.page(len(out.PendingMaintenanceActions), in.Marker)
	out.PendingMaintenanceActions, out.Marker = out.PendingMaintenanceActions[from:to], next
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
		k["aws_instance"][0]["class"] != "db.serverless" || k["aws_instance"][0]["maintenance_window"] != "mon:04:04-mon:04:34" {
		t.Errorf("aws_instance: %v", k["aws_instance"])
	}
	if got := targetVersions(k["aws_target"], false); !reflect.DeepEqual(got, []string{"17.10", "17.11"}) {
		t.Errorf("minor targets %v", got)
	}
	if got := targetVersions(k["aws_target"], true); !reflect.DeepEqual(got, []string{"18.3", "18.4", "18.6"}) {
		t.Errorf("major targets %v", got)
	}
	for _, tg := range k["aws_target"] {
		if tg["engine_version"] == "17.10" && (tg["description"] != "Aurora PostgreSQL (Compatible with PostgreSQL 17.10)" || tg["auto_upgrade"] != false) {
			t.Errorf("target 17.10: %v", tg)
		}
	}
	// the cluster's own action and its instance's: both filters were asked
	if len(k["aws_pending"]) != 2 || api.calls["DescribePendingMaintenanceActions"] != 2 {
		t.Fatalf("pending rows %v after %d calls", k["aws_pending"], api.calls["DescribePendingMaintenanceActions"])
	}
	got := map[string]string{}
	for _, p := range k["aws_pending"] {
		got[p["action"].(string)] = p["resource"].(string)
		if p["forced_apply"].(*time.Time) != nil || p["auto_applied_after"].(*time.Time) != nil || p["current_apply"].(*time.Time) != nil {
			t.Errorf("the lab's actions are undated: %v", p)
		}
		if p["description"] != "New Operating System patch is available" {
			t.Errorf("pending description: %v", p)
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

// A cluster whose instances and pending actions span pages: every page is read.
func TestVersionsAWSClusterPaged(t *testing.T) {
	api := newRecordedRDS(t)
	api.extraMembers, api.pageSize = 2, 1
	rows, err := versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	k := rowsByKind(rows)
	if len(k["aws_instance"]) != 3 || api.calls["DescribeDBInstances"] != 3 {
		t.Errorf("instances %d over %d calls, want 3 over 3", len(k["aws_instance"]), api.calls["DescribeDBInstances"])
	}
	// the cluster's action (1 page) and the three instances' (3 pages)
	if len(k["aws_pending"]) != 4 || api.calls["DescribePendingMaintenanceActions"] != 4 {
		t.Errorf("pending %d over %d calls, want 4 over 4", len(k["aws_pending"]), api.calls["DescribePendingMaintenanceActions"])
	}
	if m := k["aws_engine"][0]["members"].([]string); len(m) != 3 {
		t.Errorf("members %v", m)
	}
}

// The cluster's own auto minor upgrade flag is the one recorded, not an instance's.
func TestVersionsAWSClusterFlag(t *testing.T) {
	api := newRecordedRDS(t)
	api.clusterAMVU = aws.Bool(false)
	rows, err := versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	k := rowsByKind(rows)
	if aws.ToBool(k["aws_engine"][0]["auto_minor_version_upgrade"].(*bool)) != false ||
		aws.ToBool(k["aws_instance"][0]["auto_minor_version_upgrade"].(*bool)) != true {
		t.Errorf("cluster flag %v, instance flag %v", k["aws_engine"][0]["auto_minor_version_upgrade"], k["aws_instance"][0]["auto_minor_version_upgrade"])
	}
	api = newRecordedRDS(t)
	api.dropAMVU = true
	rows, err = versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	if v := rowsByKind(rows)["aws_engine"][0]["auto_minor_version_upgrade"].(*bool); v != nil {
		t.Errorf("a cluster without the flag must pass nil, got %v", *v)
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

// An engine version the API does not know: an empty answer, no status and no targets, still a complete read.
func TestVersionsAWSUnknownEngineVersion(t *testing.T) {
	api := newRecordedRDS(t)
	api.engineVersion = "99.9"
	rows, err := versionsAWSRows(context.Background(), api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	k := rowsByKind(rows)
	if _, ok := k["aws_engine"][0]["engine_status"]; ok || len(k["aws_target"]) != 0 || len(k["aws_read"]) != 1 {
		t.Errorf("unknown version: engine %v, %d targets, %d aws_read", k["aws_engine"][0], len(k["aws_target"]), len(k["aws_read"]))
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
		e["engine_status"] != "deprecated" || aws.ToBool(e["auto_minor_version_upgrade"].(*bool)) != false ||
		e["maintenance_window"] != "sun:06:00-sun:06:30" {
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
	at := func(key string) time.Time { return *p[key].(*time.Time) }
	if p["action"] != "db-upgrade" || p["opt_in_status"] != "next-maintenance" || p["description"] != "Automatic minor version upgrade to 16.9" ||
		p["resource"] != "arn:aws:rds:us-east-2:123456789012:db:orders-db" ||
		!at("auto_applied_after").Equal(time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC)) ||
		!at("forced_apply").Equal(time.Date(2027, 1, 15, 0, 0, 0, 0, time.UTC)) ||
		!at("current_apply").Equal(time.Date(2026, 12, 6, 6, 0, 0, 0, time.UTC)) {
		t.Errorf("pending: %v", p)
	}
}

// An error part-way gives no rows at all (RunInstance turns it into a collector_error row, and the import then
// keeps the last AWS read: no aws_read row).
func TestVersionsAWSErrorMidway(t *testing.T) {
	for _, c := range []struct {
		call string
		aws  config.AWS
	}{
		{"DescribeDBClusters", config.AWS{Cluster: "dba-lab-pg"}},
		{"DescribeDBInstances", config.AWS{Cluster: "dba-lab-pg"}},
		{"DescribeDBEngineVersions", config.AWS{Cluster: "dba-lab-pg"}},
		{"DescribePendingMaintenanceActions", config.AWS{Cluster: "dba-lab-pg"}},
		{"DescribeDBInstances", config.AWS{DBInstance: "orders-db"}},
		{"DescribeDBEngineVersions", config.AWS{DBInstance: "orders-db"}},
		{"DescribePendingMaintenanceActions", config.AWS{DBInstance: "orders-db"}},
	} {
		api := newRecordedRDS(t)
		api.failOn = c.call
		rows, err := versionsAWSRows(context.Background(), api, c.aws)
		if err == nil || rows != nil {
			t.Errorf("%s refused (%+v): rows %v, err %v", c.call, c.aws, rows, err)
		}
	}
	for _, a := range []config.AWS{{Cluster: "no-such-cluster"}, {DBInstance: "no-such-instance"}} {
		if rows, err := versionsAWSRows(context.Background(), newRecordedRDS(t), a); err == nil || rows != nil {
			t.Errorf("%+v must fail: rows %v, err %v", a, rows, err)
		}
	}
}

// The recorded cluster read imported into a repository (PGVIGIL_REPO_DSN): the AWS side lands, a second read with
// only the server row keeps it; a cluster without its own auto minor upgrade flag takes its instances'.
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
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	// closed by a cleanup registered before the instances' deletes: cleanups run last-in first-out, after defers
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	server := Row{"kind": "server", "server_version_num": 170009, "server_version": "17.9", "version_string": "PostgreSQL 17.9",
		"aurora_version": "17.9.5", "postmaster_start": time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}
	instance := func(suffix string) int {
		name := "versions-fixture-" + suffix + "-" + time.Now().UTC().Format("150405.000")
		id, err := r.EnsureInstance(ctx, name, "aurora", "17.9", 170009, false, []string{"fixture"})
		if err != nil {
			t.Fatal(err)
		}
		// registered at once: a t.Fatal later in the test still removes the fixture instance and its rows
		t.Cleanup(func() {
			if _, err := conn.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
				t.Logf("cleanup: %v", err)
			}
		})
		return id
	}
	fleet := func(id int) string {
		var got string
		if err := conn.QueryRow(ctx, `SELECT engine || '|' || engine_version || '|' || engine_status || '|' || pending_actions || '|' || upgrade_targets
		                                     || '|' || coalesce(auto_minor_version_upgrade::text, 'null')
		                                FROM pgvigil.versions_fleet WHERE instance_id = $1`, id).Scan(&got); err != nil {
			t.Fatal(err)
		}
		return got
	}

	aw, err := versionsAWSRows(ctx, newRecordedRDS(t), config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	id := instance("a")
	at := time.Now().UTC()
	if err := r.Import(ctx, id, "versions", at, append([]Row{server}, aw...)); err != nil {
		t.Fatal(err)
	}
	if err := r.Import(ctx, id, "versions", at.Add(time.Minute), []Row{server}); err != nil {
		t.Fatal(err)
	}
	if got, want := fleet(id), "aurora-postgresql|17.9|available|2|17.10, 17.11, 18.3, 18.4, 18.6|true"; got != want {
		t.Errorf("fleet row %q, want %q", got, want)
	}
	var findings int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM pgvigil.version_findings WHERE instance_id = $1 AND setting = 'pending maintenance' AND severity = 'info'`, id).Scan(&findings); err != nil {
		t.Fatal(err)
	}
	if findings != 2 {
		t.Errorf("undated pending actions: %d info findings, want 2", findings)
	}

	// no cluster flag: the import takes bool_and of the instances' (true here), not NULL
	api := newRecordedRDS(t)
	api.dropAMVU = true
	aw, err = versionsAWSRows(ctx, api, config.AWS{Cluster: "dba-lab-pg"})
	if err != nil {
		t.Fatal(err)
	}
	id2 := instance("b")
	if err := r.Import(ctx, id2, "versions", at, append([]Row{server}, aw...)); err != nil {
		t.Fatal(err)
	}
	if got, want := fleet(id2), "aurora-postgresql|17.9|available|2|17.10, 17.11, 18.3, 18.4, 18.6|true"; got != want {
		t.Errorf("fleet row without the cluster flag %q, want %q", got, want)
	}
}
