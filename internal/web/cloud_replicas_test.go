package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestCloudReplicasPageOnAStore (task 390b task 8): on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without
// it) the Replicas (provider) block's reads - a source and its replica both monitored, each read once:
//   - resources: the replica's page lists itself (self), its source (with the instance it is monitored as) and no
//     other resource; the source's page lists itself and its replica with the replica's newest lag;
//   - series: a window of a day reads the samples, a window of three days the hours (one row an hour), both of the
//     instance's resources only;
//   - events: a status change and the instance's own provider failover phases; findings: the view's rows;
//   - read: 'has' and the door's failed reads in a row.
func TestCloudReplicasPageOnAStore(t *testing.T) {
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
	ids := map[string]int{}
	for _, n := range []string{"src", "rep"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'rds', '16.4', 160004, false, '{}'::text[], 'postgres')`,
			fmt.Sprintf("crpage-%s-%d", n, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	db1, r1, other := fmt.Sprintf("pdb%d", sfx), fmt.Sprintf("pdb%d-r1", sfx), fmt.Sprintf("pother%d", sfx)
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.cloud_replica_sample WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replica_hour WHERE resource_id = ANY($1)`,
			`DELETE FROM pgvigil.cloud_replica_events WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_failover_events WHERE resource_id = ANY($1)`,
			`DELETE FROM pgvigil.cloud_replica_reads WHERE resource_id = ANY($1)`, `DELETE FROM pgvigil.cloud_replicas WHERE resource_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, []string{db1, r1, other}); err != nil {
				t.Error(err)
			}
		}
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`, []int{ids["src"], ids["rep"]})
	}()
	res := func(id, role, source string, replicas []string, repl string) map[string]any {
		if replicas == nil {
			replicas = []string{}
		}
		return map[string]any{"kind": "resource", "provider": "aws", "resource_id": id, "role": role, "source_id": source, "replica_ids": replicas,
			"status": "available", "repl_status": repl}
	}
	h0 := time.Now().UTC().Truncate(time.Hour).Add(-50 * time.Hour)
	imp := func(who, self string, at time.Time, rows ...map[string]any) {
		t.Helper()
		rows = append([]map[string]any{{"kind": "read", "provider": "aws", "resource_id": self, "notes": []string{"rds:DescribeEvents in us-east-2 refused (AccessDenied: x)"}}}, rows...)
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_cloud_replicas($1, $2, $3::jsonb)`, ids[who], at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	// 48 hours of r1's lag a minute apart (and another resource's, which neither page reads), read by the source
	for m := 0; m < 48*60; m += 60 {
		rows := []map[string]any{res(db1, "source", "", []string{r1}, ""), res(r1, "replica", db1, nil, "replicating")}
		for k := m; k < m+60; k++ {
			at := h0.Add(time.Duration(k) * time.Minute).Format(time.RFC3339)
			rows = append(rows, map[string]any{"kind": "point", "provider": "aws", "resource_id": r1, "metric": "replica_lag", "unit": "s", "at": at, "value": float64(k % 9)},
				map[string]any{"kind": "point", "provider": "aws", "resource_id": other, "metric": "replica_lag", "unit": "s", "at": at, "value": 1.0})
		}
		imp("src", db1, h0.Add(time.Duration(m+60)*time.Minute), rows...)
	}
	// the replica's own reads, the last minutes (the findings judge a read of the last 15 minutes)
	now, rn := h0.Add(48*time.Hour), time.Now().UTC().Truncate(time.Second)
	imp("rep", r1, rn.Add(-3*time.Minute), res(r1, "replica", db1, nil, "error"), res(db1, "source", "", []string{r1}, ""),
		map[string]any{"kind": "failover", "provider": "aws", "resource_id": r1, "at": now.Add(-time.Hour).Format(time.RFC3339), "phase": "started",
			"message": "Multi-AZ instance failover started.", "source": "rds events"})
	imp("rep", r1, rn.Add(-2*time.Minute), res(r1, "replica", db1, nil, "error"))
	imp("rep", r1, rn.Add(-time.Minute), res(r1, "replica", db1, nil, "error"))

	type row = map[string]any
	query := func(sql string, args ...any) []row {
		t.Helper()
		rs, err := pool.Query(ctx, sql, args...)
		if err != nil {
			t.Fatal(err)
		}
		defer rs.Close()
		var out []row
		for rs.Next() {
			v, err := rs.Values()
			if err != nil {
				t.Fatal(err)
			}
			r := row{}
			for i, f := range rs.FieldDescriptions() {
				r[f.Name] = v[i]
			}
			out = append(out, r)
		}
		return out
	}
	got := map[string]row{}
	for _, r := range query(sqlCloudReplicaResources, ids["rep"]) {
		got[r["resource_id"].(string)] = r
	}
	if len(got) != 2 || got[r1]["self"] != true || got[db1]["self"] != false || got[db1]["role"] != "source" {
		t.Errorf("the replica's resources %v: want itself and its source", got)
	}
	if mon, _ := got[db1]["monitored_as"].(int32); int(mon) != ids["src"] {
		t.Errorf("the source monitored as %v, want the source's instance %d", got[db1]["monitored_as"], ids["src"])
	}
	src := query(sqlCloudReplicaResources, ids["src"])
	if len(src) != 2 {
		t.Errorf("the source's resources: %d rows, want 2", len(src))
	}
	for _, r := range src {
		if r["resource_id"] == r1 && r["lag_s"] == nil {
			t.Error("the source's page: its replica's newest lag missing")
		}
	}
	day := query(sqlCloudReplicaSeries, ids["rep"], now.Add(-24*time.Hour), now)
	three := query(sqlCloudReplicaSeries, ids["rep"], now.Add(-72*time.Hour), now)
	for _, rs := range [][]row{day, three} {
		for _, r := range rs {
			if r["resource_id"] != r1 {
				t.Errorf("a series row of %v: only the instance's own resources", r["resource_id"])
				break
			}
		}
	}
	if len(day) != 24*60 || len(three) != 48 {
		t.Errorf("series rows: a day %d (want 1440 samples), three days %d (want 48 hours)", len(day), len(three))
	}
	ev := query(sqlCloudReplicaEvents, ids["rep"], now.Add(-2*time.Hour), rn.Add(time.Hour))
	kinds := map[string]int{}
	for _, r := range ev {
		kinds[r["kind"].(string)]++
	}
	if kinds["status"] != 1 || kinds["failover started"] != 1 {
		t.Errorf("events %v, want one status change and the failover's start", kinds)
	}
	rd := query(sqlCloudReplicaRead, ids["rep"])
	if len(rd) != 1 || rd[0]["has"] != true || rd[0]["door_fails"] != int32(3) {
		t.Errorf("the read %v: want has and 3 failed reads in a row", rd)
	}
	f := query(sqlCloudReplicaFindings, ids["rep"])
	checks := map[string]bool{}
	for _, r := range f {
		checks[r["check_name"].(string)] = true
	}
	if !checks["provider replica stopped"] || !checks["cloud door failing"] {
		t.Errorf("findings %v, want 'provider replica stopped' and 'cloud door failing'", checks)
	}
}
