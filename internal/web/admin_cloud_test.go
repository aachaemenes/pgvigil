package web

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestInstanceCloudWriteOnAStore (B24p task 5): the Cloud fieldset through serve's handler - an add with its block in
// one call (done: the row and the block; the view's page row carries it, no 'not used' note); a block whose target
// is not the instance's own host, a typed profile, an empty fieldset and the switch off are refused BEFORE anything is
// written (no row, no credential file); the explicit clear removes the block. Needs a migrated repository and its
// owner: PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestInstanceCloudWriteOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	ok, bad, off := fmt.Sprintf("b24p-ok-%d", sfx), fmt.Sprintf("b24p-bad-%d", sfx), fmt.Sprintf("b24p-off-%d", sfx)
	defer func() {
		for _, n := range []string{ok, bad, off} {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, n)
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name = $1`, n)
		}
	}()
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "pgvigil.yaml")
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	s.SetInstancesAdmin(InstancesAdmin{ConfigPath: cfgPath})
	defer instancesAdmins.Delete(s)
	config.SetPageCloud(config.Doors{PageCloudBlocks: true})
	defer config.SetPageCloud(config.Doors{})
	write := func(body map[string]any) *httptest.ResponseRecorder {
		b, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		var in map[string]any
		_ = json.Unmarshal(b, &in)
		s.instancesWrite(w, httptest.NewRequest(http.MethodPost, "/api/admin/instances", bytes.NewReader(b)), "b24p", in)
		return w
	}
	host := "db1.c9akciq32.us-east-2.rds.amazonaws.com"
	add := func(name, h string, cloud any) map[string]any {
		return map[string]any{"op": "add", "name": name, "engine": "postgres", "platform": "rds", "host": h, "port": "5432", "dbname": "postgres",
			"auth": "password", "login": "pgv", "password": "pw b24p", "cloud": cloud}
	}
	rows := func(name string) (int, int) {
		var a, c int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1`, name).Scan(&a)
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instance_cloud WHERE name = $1`, name).Scan(&c)
		return a, c
	}
	files := func() int {
		es, _ := os.ReadDir(config.SecretDir(cfgPath))
		return len(es)
	}
	if w := write(add(ok, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}, "azure": nil})); w.Code != http.StatusOK {
		t.Fatalf("an add with its block: %d %s", w.Code, w.Body.String())
	}
	if a, c := rows(ok); a != 1 || c != 1 {
		t.Fatalf("after the add: %d row(s), %d block(s); want 1 and 1", a, c)
	}
	before := files()
	for _, c := range []struct {
		what  string
		body  map[string]any
		code  int
		words string
	}{
		{"another instance's host", add(bad, "db2.c9akciq32.us-east-2.rds.amazonaws.com", map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}}), http.StatusConflict, "db2.c9akciq32"},
		{"a CNAME", add(bad, "billing.corp.example", map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}}), http.StatusConflict, "not an RDS endpoint"},
		{"a typed profile", add(bad, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1", "profile": "prod"}}), http.StatusBadRequest, "no AWS profile"},
		{"a page key it does not take", add(bad, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1", "log_group": "/x"}}), http.StatusBadRequest, "log_group"},
		{"an empty fieldset", add(bad, host, map[string]any{"aws": nil, "azure": nil}), http.StatusBadRequest, "Clear"},
	} {
		w := write(c.body)
		if w.Code != c.code || !strings.Contains(w.Body.String(), c.words) {
			t.Errorf("%s: %d %s, want %d naming %q", c.what, w.Code, w.Body.String(), c.code, c.words)
		}
		if a, _ := rows(bad); a != 0 || files() != before {
			t.Errorf("%s: the refused add wrote %d row(s) and %d credential file(s)", c.what, a, files()-before)
		}
	}
	// the switch off: refused in its words, nothing written
	config.SetPageCloud(config.Doors{})
	if w := write(add(off, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}})); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "page_cloud_blocks") {
		t.Errorf("the switch off: %d %s", w.Code, w.Body.String())
	}
	if a, _ := rows(off); a != 0 {
		t.Error("the switch off: the add was written")
	}
	// the view: the block on its row, and the note while the switch is off (the collector will not use it)
	vw := httptest.NewRecorder()
	s.InstancesAdminView(vw, httptest.NewRequest(http.MethodGet, "/api/admin/instances", nil))
	var view struct {
		CloudBlocks struct {
			On    bool              `json:"on"`
			Notes map[string]string `json:"notes"`
		} `json:"cloud_blocks"`
	}
	if err := json.Unmarshal(vw.Body.Bytes(), &view); err != nil {
		t.Fatalf("the view: %d %s", vw.Code, vw.Body.String())
	}
	if view.CloudBlocks.On || !strings.Contains(view.CloudBlocks.Notes[ok], "page_cloud_blocks") || !strings.Contains(vw.Body.String(), `"db_instance"`) {
		t.Errorf("the view with the switch off: on %v, note %q (want the off words), the block on the row: %v", view.CloudBlocks.On, view.CloudBlocks.Notes[ok], strings.Contains(vw.Body.String(), `"db_instance"`))
	}
	// the explicit clear (allowed with the switch off)
	if w := write(map[string]any{"op": "cloud_clear", "name": ok}); w.Code != http.StatusOK {
		t.Fatalf("the clear: %d %s", w.Code, w.Body.String())
	}
	if _, c := rows(ok); c != 0 {
		t.Error("the clear left the block")
	}
}

// B24p task 6 (fold 8): an approved proposal's block from its own identity - aws for a PostgreSQL proposal of an AWS
// source (region and DB instance from its key, the cluster from its tag), none for SQL Server; azure for an azuresqldb
// proposal (subscription and resource group from its tags, the server from its key, the source's cloud); the source's
// profile copied only while the switch is on AND doors.page_aws_profiles lists it (Q5). Recorded proposals' shapes
// (discover/aws.go, discover/azure.go). The blocks pass the store's shape (config.PageCloudShape).
func TestProposalCloud(t *testing.T) {
	dir := t.TempDir()
	awsSet, azSet := filepath.Join(dir, "aws.json"), filepath.Join(dir, "az.json")
	_ = os.WriteFile(awsSet, []byte(`{"kind":"aws","profile":"prod-read","regions":["us-east-2"]}`), 0o600)
	_ = os.WriteFile(azSet, []byte(`{"kind":"azure","cloud":"usgov"}`), 0o600)
	awsSrc, azSrc := &sourceRow{Kind: "aws", Ref: "file:" + awsSet}, &sourceRow{Kind: "azure", Ref: "file:" + azSet}
	tags := []string{"account:123456789012", "cloud:aws", "cluster:dba-lab-pg", "region:us-east-2", "role:writer"}
	defer config.SetPageCloud(config.Doors{})
	config.SetPageCloud(config.Doors{})
	a, z, note := proposalCloud(awsSrc, "aws:123456789012:us-east-2:instance:dba-lab-pg-1", config.EnginePostgres, "aurora", tags)
	if a == nil || z != nil || a.Region != "us-east-2" || a.DBInstance != "dba-lab-pg-1" || a.Cluster != "dba-lab-pg" || a.Profile != "" || !strings.Contains(note, "page_cloud_blocks") {
		t.Fatalf("an Aurora member, the switch off: %+v %+v %q", a, z, note)
	}
	if why := config.PageCloudShape(config.PageInstance{Engine: config.EnginePostgres, AWS: a}); why != "" {
		t.Errorf("the approve's aws block fails the store's shape: %s", why)
	}
	config.SetPageCloud(config.Doors{PageCloudBlocks: true})
	if a, _, note := proposalCloud(awsSrc, "aws:123456789012:us-east-2:instance:dba-lab-pg-1", config.EnginePostgres, "aurora", tags); a.Profile != "" || !strings.Contains(note, "page_aws_profiles") {
		t.Errorf("the switch on, the profile unlisted: %+v %q", a, note)
	}
	config.SetPageCloud(config.Doors{PageCloudBlocks: true, PageAWSProfiles: []string{"prod-read"}})
	if a, _, note := proposalCloud(awsSrc, "aws:123456789012:us-east-2:instance:dba-lab-pg-1", config.EnginePostgres, "aurora", tags); a.Profile != "prod-read" || note != "" {
		t.Errorf("the switch on, the profile listed: %+v %q", a, note)
	}
	if a, z, _ := proposalCloud(awsSrc, "aws:123456789012:us-east-2:instance:ms1", config.EngineSQLServer, "rds", tags); a != nil || z != nil {
		t.Errorf("an RDS SQL Server proposal got a block: %+v %+v (aws: on SQL Server is pgvigil.yaml's provider replica door only, 390b)", a, z)
	}
	ztags := []string{"cloud:azure", "region:usgovvirginia", "resource-group:rg-sql", "subscription:0b1f6471-1bf0-4dda-aec3-111122223333"}
	a, z, _ = proposalCloud(azSrc, "azure:0b1f6471-1bf0-4dda-aec3-111122223333:sql:srv1/app", config.EngineSQLServer, "azuresqldb", ztags)
	if a != nil || z == nil || z.Subscription != "0b1f6471-1bf0-4dda-aec3-111122223333" || z.ResourceGroup != "rg-sql" || z.Server != "srv1" || z.Cloud != "usgov" {
		t.Fatalf("an Azure SQL Database: %+v %+v", a, z)
	}
	if why := config.PageCloudShape(config.PageInstance{Engine: config.EngineSQLServer, Platform: "azuresqldb", Azure: z}); why != "" {
		t.Errorf("the approve's azure block fails the store's shape: %s", why)
	}
	if a, z, _ := proposalCloud(azSrc, "azure:0b1f6471-1bf0-4dda-aec3-111122223333:sql:srv1/app", config.EngineSQLServer, "azuresqlmi", ztags); a != nil || z != nil {
		t.Errorf("a proposal that is not azuresqldb got a block: %+v %+v", a, z)
	}
}

// collectorPool is a pool on a role IN ROLE pgvigil_collector, as a real install's audit login is (actions.go): every
// connection SET ROLE to it, so a write the collector's role may not make fails here as it does there.
func collectorPool(ctx context.Context, t *testing.T, owner *pgxpool.Pool, dsn string, sfx int64) *pgxpool.Pool {
	t.Helper()
	role := fmt.Sprintf("t_b24p_c_%d", sfx)
	if _, err := owner.Exec(ctx, `CREATE ROLE `+role+` NOLOGIN IN ROLE pgvigil_collector`); err != nil {
		t.Skipf("this store's login may not make roles (it needs CREATE ROLE and SET ROLE): %v", err)
	}
	t.Cleanup(func() { _, _ = owner.Exec(context.Background(), `DROP ROLE IF EXISTS `+role) })
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		_, err := c.Exec(ctx, `SET ROLE `+role)
		return err
	}
	p, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	return p
}

// B24p's fold 4 (review 20261115-023158 finding 4): a cloud block the STORE refuses (Go's pre-check passed) rolls the
// add back and still leaves its 'refused' audit row - on the audit login a real install has (IN ROLE
// pgvigil_collector, which may not run admin_log nor insert into admin_audit), through import_admin_cloud_refused.
// Needs a migrated repository and its owner (CREATE ROLE): PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestCloudRefusalAuditAsCollector(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close) // registered first, so it runs after every cleanup below that uses it
	sfx := time.Now().UnixNano() % 1000000000
	name := fmt.Sprintf("b24p-aud-%d", sfx)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
	})
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: collectorPool(ctx, t, pool, dsn, sfx)}}
	pay := map[string]any{"op": "add", "ui_user": "b24p", "client": "t", "name": name, "engine": "postgres", "platform": "rds",
		"dsn_ref": "file:/x/" + name + ".dsn", "host": "db1.c9akciq32.us-east-2.rds.amazonaws.com", "auth": "password"}
	// a region the store's shape refuses (Go's pre-check is the handler's, not this call's)
	cloud := map[string]any{"op": "set", "ui_user": "b24p", "client": "t", "name": name, "aws": map[string]any{"region": "nowhere", "db_instance": "db1"}, "azure": nil}
	ans, _, err := s.writeWithCloud(ctx, pay, cloud)
	if err != nil || ans.Outcome != "refused" || !strings.Contains(ans.Detail, "region") {
		t.Fatalf("an add whose block the store refuses: %+v %v, want refused naming the region", ans, err)
	}
	var rows, audits int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1`, name).Scan(&rows)
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance cloud' AND target = $1 AND outcome = 'refused' AND detail LIKE '%region%'`, name).Scan(&audits); err != nil {
		t.Fatal(err)
	}
	if rows != 0 || audits != 1 {
		t.Errorf("after the refusal: %d instance row(s), %d refusal audit row(s); want 0 and 1", rows, audits)
	}
}

// B24p's fold 10 (finding 10): an approve whose derived block the store refuses is approved WITHOUT the block (the
// design: 'a proposal without them gets none'), the refusal audited and said in the answer - never the whole approve
// refused. On the collector-role audit login, as a real install.
func TestApproveWithoutRefusedBlock(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close) // registered first, so it runs after every cleanup below that uses it
	sfx := time.Now().UnixNano() % 1000000000
	src, inst := fmt.Sprintf("b24p-src-%d", sfx), fmt.Sprintf("b24p-apr-%d", sfx)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, inst)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_proposals WHERE source = $1`, src)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_sources WHERE name = $1`, src)
	})
	var o, d string
	if err := pool.QueryRow(ctx, `SELECT r->>'outcome', coalesce(r->>'detail', '') FROM pgvigil.import_admin_source(now(), $1::jsonb) AS t(r)`,
		fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"kind":"sqlserver_list","ref":"/etc/pgvigil/servers.csv","auth":"entra-identity","every_s":"3600"}`, src)).Scan(&o, &d); err != nil || o != "done" {
		t.Fatalf("the source: %s %s %v", o, d, err)
	}
	var id int64
	if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, port, dbname, platform)
	                               VALUES ($1, 'srv-b24p/db1', 'sqlserver', 'srv-b24p.database.windows.net', 1433, 'db1', 'azuresqldb') RETURNING proposal_id`, src).Scan(&id); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: collectorPool(ctx, t, pool, dsn, sfx)}}
	pay := map[string]any{"op": "approve", "ui_user": "b24p", "client": "t", "proposal_id": fmt.Sprint(id), "name": inst, "dsn_ref": "file:/x/" + inst + ".dsn", "auth": "entra-identity"}
	// a resource group the store refuses (a '/'): the derived block's refusal
	cloud := map[string]any{"op": "set", "ui_user": "b24p", "client": "t", "name": inst, "aws": nil,
		"azure": map[string]any{"subscription": "0b1f6471-1bf0-4dda-aec3-111122223333", "resource_group": "rg/b24p", "server": "srv-b24p"}}
	ans, _, note, err := s.approveWrite(ctx, pay, cloud)
	if err != nil || ans.Outcome != "done" || !strings.Contains(note, "without its cloud block") || !strings.Contains(note, "resource_group") {
		t.Fatalf("the approve: %+v note %q %v, want done, the note naming the refused resource_group", ans, note, err)
	}
	var rows, blocks, audits int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1`, inst).Scan(&rows)
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instance_cloud WHERE name = $1`, inst).Scan(&blocks)
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance cloud' AND target = $1 AND outcome = 'refused'`, inst).Scan(&audits)
	if rows != 1 || blocks != 0 || audits != 1 {
		t.Errorf("after the approve: %d instance row(s), %d block(s), %d refusal audit row(s); want 1, 0 and 1", rows, blocks, audits)
	}
}
