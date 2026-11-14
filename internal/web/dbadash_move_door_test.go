package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestMoveDoorMatchOnAStore (task 206, P1 / P1b in the store): on a migrated repository (PGVIGIL_REPO_TEST_DSN,
// skipped without it) a DBA Dash server whose display name is HOSTX\PROD, imported earlier under the name-safe
// HOSTX-PROD (pgvigil import dbadash -name) and then moved under that name, is that pgvigil instance on the DBA Dash
// door - not collected yet, its imported database sizes shown - through its move alone: with the move rows deleted
// neither query finds it (the display name is not the instance's name). A run of the import for that InstanceID goes
// to the moved instance, and no instance named HOSTX\PROD is made. Beside it a decoy (an active SQL Server instance
// never read, with a size) and a second repository whose InstanceID 21 is another server: neither is matched through
// the move (the match keeps both its repository and its instance), and that other 21 imports apart.
func TestMoveDoorMatchOnAStore(t *testing.T) {
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
	repo, disp, name := fmt.Sprintf("r206door-%d", sfx), fmt.Sprintf(`HOSTX%d\PROD`, sfx), fmt.Sprintf("HOSTX%d-PROD", sfx)
	repo2, other, decoy, host := fmt.Sprintf("r206door2-%d", sfx), fmt.Sprintf("OTHER%d", sfx), fmt.Sprintf("decoy-%d", sfx), fmt.Sprintf("hostx%d", sfx)
	for _, r := range [][2]string{{repo, disp}, {repo2, other}} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_repositories (repository, status, read_at) VALUES ($1, 'ok', now())`, r[0]); err != nil {
			t.Fatal(err)
		}
		// InstanceID 21 in both repositories: two servers
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_instances (repository, instance_id, instance, connection_id, display_name, first_seen, snapshot_at)
		                             VALUES ($1, 21, $2, lower($2) || ',1433', $2, now(), now())`, r[0], r[1]); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		bg := context.Background()
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.dbadash_repositories WHERE repository IN ($1, $2)`, repo, repo2)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
		for _, n := range []string{name, disp, decoy, other} {
			_, _ = pool.Exec(bg, `DELETE FROM pgvigil.mssql_database_size WHERE instance_id IN (SELECT instance_id FROM pgvigil.instances WHERE name = $1)`, n)
			_, _ = pool.Exec(bg, `DELETE FROM pgvigil.instances WHERE name = $1`, n)
		}
	}()
	size := `SELECT pgvigil.import_dbadash_dbsize($1, '[{"at": "2026-11-01T00:00:00Z", "database_name": "sales", "data_bytes": 8192, "log_bytes": 8192, "files": 2}]'::jsonb, '{}'::jsonb)`
	// a decoy: an active SQL Server instance never read, with a size of its own (a match that lost its instance
	// correlation would take it too)
	var did int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', NULL, NULL, false, '{}'::text[], 'sqlserver')`, decoy).Scan(&did); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, size, did); err != nil {
		t.Fatal(err)
	}
	// the earlier import under -name: the instance and one database size
	var raw []byte
	target := func(repository, n string) (id int, moved bool) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_instance($1::jsonb)::text`,
			fmt.Sprintf(`{"repository": %q, "dbadash_id": 21, "name": %q, "platform": "sqlserver", "version": "16.0.4295.3", "version_num": 160000}`, repository, n)).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var tgt struct {
			ID    int  `json:"instance_id"`
			Moved bool `json:"moved"`
		}
		if err := json.Unmarshal(raw, &tgt); err != nil || tgt.ID == 0 {
			t.Fatalf("import_dbadash_instance (%s, 21, %s): %s (%v)", repository, n, raw, err)
		}
		return tgt.ID, tgt.Moved
	}
	id, moved := target(repo, name)
	if moved {
		t.Fatalf("the earlier import's instance: %s, want not moved", raw)
	}
	if _, err := pool.Exec(ctx, size, id); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{"op": "add", "ui_user": "t206", "repository": repo, "server": disp, "dbadash_ids": []int{21},
		"name": name, "dsn_ref": "file:/nonexistent/t206door", "auth": "sql", "host": host, "port": "1433"})
	var ans string
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_move(now(), $1::jsonb)::text`, string(b)).Scan(&ans); err != nil || !strings.Contains(ans, `"outcome": "done"`) {
		t.Fatalf("the move: %s (%v)", ans, err)
	}
	// rows of the door's imported query for one repository's InstanceID 21 (repository NULL: the tree's own call, every
	// configured repository, narrowed here), each with its instance and candidates; and the sizes query's count
	rows := func(r *string, only string) (out [][3]any) {
		t.Helper()
		rs, err := pool.Query(ctx, `SELECT instance_id, collected, candidates FROM (`+sqlDBADashImported+`) x WHERE source_id = 21 AND repository = $2`, r, only)
		if err != nil {
			t.Fatal(err)
		}
		defer rs.Close()
		for rs.Next() {
			var iid int
			var col bool
			var cand int64
			if err := rs.Scan(&iid, &col, &cand); err != nil {
				t.Fatal(err)
			}
			out = append(out, [3]any{iid, col, cand})
		}
		return out
	}
	sizes := func(r string) (n int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM (`+sqlDBADashSizes+`) x`, r, 21).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if got := rows(&repo, repo); len(got) != 1 || got[0] != [3]any{id, false, int64(1)} || sizes(repo) != 1 {
		t.Fatalf("with the move: the door's rows %v and sizes %d; want one row [%d false 1] and 1 size", got, sizes(repo), id)
	}
	if got := rows(nil, repo2); len(got) != 0 || sizes(repo2) != 0 {
		t.Fatalf("the other repository's InstanceID 21: rows %v, sizes %d; want none (the move is repository %s's)", got, sizes(repo2), repo)
	}
	// an import of that InstanceID goes to the move, whatever name it is given; the other repository's 21 does not
	if iid, mv := target(repo, disp); iid != id || !mv {
		t.Fatalf("the import's instance for (%s, 21) after the move: %s, want instance %d, moved", repo, raw, id)
	}
	if iid, mv := target(repo2, other); iid == id || mv {
		t.Fatalf("the import's instance for (%s, 21): %s, want another instance, not moved", repo2, raw)
	}
	var made int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.instances WHERE name = $1`, disp).Scan(&made); err != nil || made != 0 {
		t.Fatalf("instances named %s: %d (%v), want 0", disp, made, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if got := rows(&repo, repo); len(got) != 0 || sizes(repo) != 0 {
		t.Fatalf("without the move: rows %v, sizes %d; want none (the move was the path)", got, sizes(repo))
	}
}
