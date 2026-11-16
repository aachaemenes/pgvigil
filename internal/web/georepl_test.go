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

// TestGeoReplPageOnAStore (task 390a, the review's findings 7, 8 and 12): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) the Geo-replication block's reads:
//   - links: one link monitored twice on its primary side (the database itself and through the failover group's
//     listener) is ONE row on the page, its partner the secondary's read, never the other read of the same database;
//   - groups: a database monitored through the group's listener after a failover reads the partner server, and the
//     group stored under the server its azure: block names still shows, with its events;
//   - read: 'has' is true for a database with no link left while its server's group is read or an event stands
//     within 24 hours, and the platform says when the block is not an Azure SQL Database's.
func TestGeoReplPageOnAStore(t *testing.T) {
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
	var all []int
	for _, n := range []string{"p", "l", "s", "onprem"} {
		platform := "azuresqldb"
		if n == "onprem" {
			platform = "sqlserver"
		}
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("geopage-%s-%d", n, sfx), platform).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	srvA, srvB := fmt.Sprintf("pgva%d", sfx), fmt.Sprintf("pgvb%d", sfx)
	key := "s/g/" + srvA
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_failover_groups WHERE server_key = $1`, `DELETE FROM pgvigil.mssql_failover_group_events WHERE server_key = $1`,
			`DELETE FROM pgvigil.mssql_failover_group_reads WHERE server_key = $1`} {
			_, _ = pool.Exec(context.Background(), q, key)
		}
		for _, q := range []string{`DELETE FROM pgvigil.mssql_georepl_sample WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(context.Background(), q, all); err != nil {
				t.Error(err)
			}
		}
	}()
	guid := fmt.Sprintf("8d3c0000-0000-0000-0000-%012d", sfx)
	geo := func(id int, at time.Time, server string, role int, partner string, links bool) {
		t.Helper()
		rows := []map[string]any{{"kind": "read", "server_read": server, "database_name": "db1", "links": map[bool]int{true: 1, false: 0}[links]}}
		if links {
			rows = append(rows, map[string]any{"kind": "link", "link_guid": guid, "partner_server": partner, "partner_database": "db1", "role": role,
				"role_desc": map[int]string{0: "PRIMARY", 1: "SECONDARY"}[role], "replication_state": 2, "replication_state_desc": "CATCH_UP",
				"replication_lag_sec": 1, "unsent_s": 0, "ack_age_s": 1, "last_replication": at.Format(time.RFC3339), "last_commit": at.Format(time.RFC3339),
				"secondary_allow_connections": 2, "secondary_allow_connections_desc": "ALL"})
		}
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_georepl($1, $2, $3::jsonb)`, id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Truncate(time.Second)
	// p: the primary database itself; l: the same database through the listener; s: the secondary on B
	geo(ids["p"], now.Add(-4*time.Minute), srvA, 0, srvB, true)
	geo(ids["l"], now.Add(-4*time.Minute), srvA, 0, srvB, true)
	geo(ids["s"], now.Add(-4*time.Minute), srvB, 1, srvA, true)
	rows := func(q string, args ...any) []map[string]any {
		t.Helper()
		r, err := pool.Query(ctx, q, args...)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		var out []map[string]any
		for r.Next() {
			v, err := r.Values()
			if err != nil {
				t.Fatal(err)
			}
			m := map[string]any{}
			for i, f := range r.FieldDescriptions() {
				m[f.Name] = v[i]
			}
			out = append(out, m)
		}
		if err := r.Err(); err != nil {
			t.Fatal(err)
		}
		return out
	}
	links := rows(sqlGeoLinks, ids["p"])
	if len(links) != 1 || links[0]["partner_instance_id"] != int32(ids["s"]) {
		t.Errorf("p's links: %v, want one row whose partner is s (%d), not l's read of the same database", links, ids["s"])
	}

	// the group stored under A (l's azure: block names A), read before the failover; then a failover: l reads B
	group := func(at time.Time, role string) {
		t.Helper()
		other := map[string]string{"Primary": "Secondary", "Secondary": "Primary"}[role]
		p, _ := json.Marshal([]map[string]any{{"kind": "read", "server_key": key, "cloud": ""},
			{"kind": "group", "group_name": "fg1", "role": role, "replication_state": "CATCH_UP", "secondary_type": "Geo", "rw_policy": "Manual",
				"ro_policy": "Disabled", "ro_target": "", "partners": `[{"server":"` + srvB + `","location":"East US","role":"` + other + `"}]`, "databases": `["db1"]`}})
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_failover_groups($1, $2, $3::jsonb)`, ids["l"], at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	group(now.Add(-3*time.Minute), "Primary")
	geo(ids["l"], now.Add(-2*time.Minute), srvB, 0, srvA, true) // the listener now reaches B, the new primary
	group(now.Add(-time.Minute), "Secondary")
	if g := rows(sqlGeoGroups, ids["l"]); len(g) != 1 || g[0]["group_name"] != "fg1" {
		t.Errorf("l's groups after the failover (its read reaches %s, the group is stored under %s): %v, want fg1", srvB, srvA, g)
	}
	ev := rows(sqlGeoEvents, ids["l"], now.Add(-time.Hour), now.Add(time.Minute))
	role := 0
	for _, e := range ev {
		if e["what"] == "failover group" && e["kind"] == "role" {
			role++
		}
	}
	if role != 1 {
		t.Errorf("l's events after the failover: %d group role events, want 1 (%v)", role, ev)
	}

	// p loses its link (geo-unlink) while A's group is read: the tab stays ('has'), and an on-premises instance's
	// block knows it is not an Azure SQL Database's
	geo(ids["p"], now, srvA, 0, "", false)
	read := rows(sqlGeoRead, ids["p"])
	if len(read) != 1 || read[0]["has"] != true || read[0]["platform"] != "azuresqldb" {
		t.Errorf("p's read with no link left: %v, want has true and platform azuresqldb", read)
	}
	read = rows(sqlGeoRead, ids["onprem"])
	if len(read) != 1 || read[0]["has"] != false || read[0]["platform"] != "sqlserver" {
		t.Errorf("an on-premises instance's read: %v, want has false and platform sqlserver", read)
	}
}
