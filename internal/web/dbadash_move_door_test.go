package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestMoveDoorMatchOnAStore (task 206, P1 / P1b in the store): on a migrated repository (PGVIGIL_REPO_TEST_DSN,
// skipped without it) a DBA Dash server whose display name is HOSTX\PROD, imported earlier under the name-safe
// HOSTX-PROD (pgvigil import dbadash -name) and then moved under that name, is that pgvigil instance on the DBA Dash
// door - not collected yet, its imported database sizes shown - through its move alone: with the move rows deleted
// neither query finds it (the display name is not the instance's name). A run of the import for that InstanceID goes
// to the moved instance, and no instance named HOSTX\PROD is made.
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
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_repositories (repository, status, read_at) VALUES ($1, 'ok', now())`, repo); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_instances (repository, instance_id, instance, connection_id, display_name, first_seen, snapshot_at)
	                             VALUES ($1, 21, $2, 'hostx,1433', $2, now(), now())`, repo, disp); err != nil {
		t.Fatal(err)
	}
	defer func() {
		bg := context.Background()
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.dbadash_repositories WHERE repository = $1`, repo)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.instances WHERE name IN ($1, $2)`, name, disp)
	}()
	// the earlier import under -name: the instance and one database size
	var id int
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_instance($1::jsonb)::text`,
		fmt.Sprintf(`{"repository": %q, "dbadash_id": 21, "name": %q, "platform": "sqlserver", "version": "16.0.4295.3", "version_num": 160000}`, repo, name)).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var tgt struct {
		ID    int  `json:"instance_id"`
		Moved bool `json:"moved"`
	}
	if err := json.Unmarshal(raw, &tgt); err != nil || tgt.ID == 0 || tgt.Moved {
		t.Fatalf("the earlier import's instance: %s", raw)
	}
	id = tgt.ID
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_dbadash_dbsize($1, '[{"at": "2026-11-01T00:00:00Z", "database_name": "sales", "data_bytes": 8192, "log_bytes": 8192, "files": 2}]'::jsonb, '{}'::jsonb)`, id); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(map[string]any{"op": "add", "ui_user": "t206", "repository": repo, "server": disp, "dbadash_ids": []int{21},
		"connection_ids": []string{"hostx,1433"}, "name": name, "dsn_ref": "file:/nonexistent/t206door", "auth": "sql", "host": "hostx", "port": "1433"})
	var ans string
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_move(now(), $1::jsonb)->>'outcome'`, string(b)).Scan(&ans); err != nil || ans != "done" {
		t.Fatalf("the move: %s (%v)", ans, err)
	}
	read := func() (imported, sizes int, collected bool) {
		t.Helper()
		var iid int
		err := pool.QueryRow(ctx, `SELECT instance_id, collected FROM (`+sqlDBADashImported+`) x WHERE source_id = 21`, repo).Scan(&iid, &collected)
		switch {
		case err == nil && iid != id:
			t.Fatalf("the door matched instance %d, want %d", iid, id)
		case err == nil:
			imported = 1
		case !errors.Is(err, pgx.ErrNoRows):
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM (`+sqlDBADashSizes+`) x`, repo, 21).Scan(&sizes); err != nil {
			t.Fatal(err)
		}
		return imported, sizes, collected
	}
	if imp, sz, col := read(); imp != 1 || sz != 1 || col {
		t.Fatalf("with the move: imported %d, sizes %d, collected %v; want 1, 1, false", imp, sz, col)
	}
	// an import of that InstanceID goes to the move, whatever name it is given
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_dbadash_instance($1::jsonb)::text`,
		fmt.Sprintf(`{"repository": %q, "dbadash_id": 21, "name": %q, "platform": "sqlserver"}`, repo, disp)).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &tgt); err != nil || tgt.ID != id || !tgt.Moved {
		t.Fatalf("the import's instance for InstanceID 21 after the move: %s, want instance %d, moved", raw, id)
	}
	var made int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.instances WHERE name = $1`, disp).Scan(&made); err != nil || made != 0 {
		t.Fatalf("instances named %s: %d (%v), want 0", disp, made, err)
	}
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.dbadash_moves WHERE instance_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	if imp, sz, _ := read(); imp != 0 || sz != 0 {
		t.Fatalf("without the move: imported %d, sizes %d; want 0 and 0 (the move was the path)", imp, sz)
	}
}
