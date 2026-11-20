package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestInstanceListAsCollectorL170 (RELNOTES L170, the finding of l241-1b's grade): 'pgvigil instance add | list |
// disable' run with the configuration's repository login, which a site sets up as the collector's (pgvigil_agent IN
// ROLE pgvigil_collector: README's PGVIGIL_REPO_DSN, the Windows template's repo.dsn). apply_roles leaves that role no
// SELECT on any pgvigil table or view, so list must read through functions granted to it. As a role that is a member
// of pgvigil_collector alone: the add, one collection logged through the collector's own functions, the list with the
// instance's last collection age (not 'never'), the disable, the list again. Needs a migrated repository and a login
// that may make roles: PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestInstanceListAsCollectorL170(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	owner, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	sfx := time.Now().UnixNano() % 1000000000
	role := fmt.Sprintf("t_l170_c_%d", sfx)
	if _, err := owner.Exec(ctx, `CREATE ROLE `+role+` NOLOGIN IN ROLE pgvigil_collector`); err != nil {
		t.Skipf("this store's login may not make roles (it needs CREATE ROLE and SET ROLE): %v", err)
	}
	defer func() { _, _ = owner.Exec(context.Background(), `DROP ROLE IF EXISTS `+role) }()
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	pc.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		_, err := c.Exec(ctx, `SET ROLE `+role)
		return err
	}
	agent, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		t.Fatal(err)
	}
	defer agent.Close()

	name := fmt.Sprintf("l170-coll-%d", sfx)
	c := config.Conn{Engine: config.EnginePostgres, Auth: "password", Host: "pg-l170c", Port: 5432, DBName: "app", Login: "mon"}
	if err := instanceWrite(ctx, agent, addPayload(name, "auto", nil, c, "file:/nonexistent/l170c.dsn", "tester", nil)); err != nil {
		t.Fatalf("add as the collector's login: %v", err)
	}
	defer func() {
		_ = instanceWrite(context.Background(), owner, map[string]any{"op": "remove", "ui_user": "cli:tester", "client": "cli", "name": name, "file_names": []string{}})
		_, _ = owner.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name = $1`, name)
	}()
	var id int
	if err := agent.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.2', 170002, false, '{}'::text[], 'postgres')`, name).Scan(&id); err != nil {
		t.Fatalf("ensure_instance as the collector's login: %v", err)
	}
	if _, err := agent.Exec(ctx, `SELECT pgvigil.log_collection($1, 'activity', now() - interval '30 seconds', 12, 'ok', NULL)`, id); err != nil {
		t.Fatalf("log_collection as the collector's login: %v", err)
	}
	// a second page instance whose only collection failed: its age is 'no successful run now', as the page's last_collected counts
	// status 'ok' only (q_instances_admin.go)
	failed := fmt.Sprintf("l170-fail-%d", sfx)
	if err := instanceWrite(ctx, agent, addPayload(failed, "auto", nil, c, "file:/nonexistent/l170f.dsn", "tester", nil)); err != nil {
		t.Fatalf("add %s: %v", failed, err)
	}
	defer func() {
		_ = instanceWrite(context.Background(), owner, map[string]any{"op": "remove", "ui_user": "cli:tester", "client": "cli", "name": failed, "file_names": []string{}})
		_, _ = owner.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name = $1`, failed)
	}()
	var fid int
	if err := agent.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.2', 170002, false, '{}'::text[], 'postgres')`, failed).Scan(&fid); err != nil {
		t.Fatal(err)
	}
	if _, err := agent.Exec(ctx, `SELECT pgvigil.log_collection($1, 'activity', now() - interval '5 seconds', 3, 'error', 'refused')`, fid); err != nil {
		t.Fatal(err)
	}

	find := func(rows []instanceRow) *instanceRow {
		for i := range rows {
			if rows[i].Name == name {
				return &rows[i]
			}
		}
		return nil
	}
	rows, err := instanceRows(ctx, agent, &config.Config{})
	if err != nil {
		t.Fatalf("list as the collector's login (the configuration's repository login on a site set up as documented): %v", err)
	}
	r := find(rows)
	if r == nil || r.Source != "page" || r.State != "enabled" || !strings.HasSuffix(r.LastAge, " ago") {
		t.Fatalf("list as the collector's login: want %s page enabled '<age> ago', got %+v", name, r)
	}
	for i := range rows {
		if rows[i].Name == failed && rows[i].LastAge != "no successful run now" {
			t.Errorf("an instance whose only collection failed: want 'no successful run now' (the page's last_collected counts ok rows only), got %+v", rows[i])
		}
	}
	// a page row whose name pgvigil.yaml took later: left out (the collector reads the file's), no age of the file's
	both, err := instanceRows(ctx, agent, &config.Config{Instances: []config.Instance{{Name: failed, Engine: config.EnginePostgres}}})
	if err != nil {
		t.Fatal(err)
	}
	var fileRow, pageRow *instanceRow
	for i := range both {
		if both[i].Name == failed && both[i].Source == "file" {
			fileRow = &both[i]
		}
		if both[i].Name == failed && both[i].Source == "page" {
			pageRow = &both[i]
		}
	}
	if fileRow == nil || pageRow == nil || pageRow.State != "left out (pgvigil.yaml holds "+failed+")" || pageRow.LastAge != "-" {
		t.Errorf("a page row the file also names: file %+v, page %+v - want the page row left out, no age", fileRow, pageRow)
	}
	if err := instanceWrite(ctx, agent, map[string]any{"op": "disable", "ui_user": "cli:tester", "client": "cli", "name": name, "file_names": []string{}}); err != nil {
		t.Fatalf("disable as the collector's login: %v", err)
	}
	rows, err = instanceRows(ctx, agent, &config.Config{})
	if err != nil {
		t.Fatalf("list after the disable: %v", err)
	}
	if r := find(rows); r == nil || r.State != "disabled" {
		t.Errorf("after the disable: %+v", r)
	}
}

// TestInstanceListAgesReadErrorL170 (RELNOTES L170, l237-1c's red): a list whose ages cannot be read is an error, never
// every instance 'never' - instanceRows read the ages through a query whose server error pgx hands to rows.Err(), and
// did not check it. As a role that may run admin_inventory() and nothing else of the store.
func TestInstanceListAgesReadErrorL170(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	owner, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer owner.Close()
	role := fmt.Sprintf("t_l170_r_%d", time.Now().UnixNano()%1000000000)
	if _, err := owner.Exec(ctx, `CREATE ROLE `+role+` NOLOGIN`); err != nil {
		t.Skipf("this store's login may not make roles: %v", err)
	}
	defer func() {
		_, _ = owner.Exec(context.Background(), `DROP OWNED BY `+role)
		_, _ = owner.Exec(context.Background(), `DROP ROLE IF EXISTS `+role)
	}()
	if _, err := owner.Exec(ctx, `GRANT USAGE ON SCHEMA pgvigil TO `+role+`; GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO `+role); err != nil {
		t.Fatal(err)
	}
	// one page instance, so admin_inventory() answers a real row (an empty inventory is its own row below): the
	// refusal of the ages read alone is what this row judges (l170-2's red met the empty inventory's NULL row first)
	page := "l170-rpage-" + strings.TrimPrefix(role, "t_l170_r_")
	c := config.Conn{Engine: config.EnginePostgres, Auth: "password", Host: "pg-l170r", Port: 5432, DBName: "app", Login: "mon"}
	if err := instanceWrite(ctx, owner, addPayload(page, "auto", nil, c, "file:/nonexistent/l170r.dsn", "tester", nil)); err != nil {
		t.Fatalf("add %s: %v", page, err)
	}
	defer func() {
		_ = instanceWrite(context.Background(), owner, map[string]any{"op": "remove", "ui_user": "cli:tester", "client": "cli", "name": page, "file_names": []string{}})
	}()
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	pc.AfterConnect = func(ctx context.Context, c *pgx.Conn) error {
		_, err := c.Exec(ctx, `SET ROLE `+role)
		return err
	}
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	rows, err := instanceRows(ctx, pool, &config.Config{})
	if err == nil {
		t.Fatalf("a login that may not read the ages: no error and %d row(s) - an unread age must be an error, never 'never'", len(rows))
	}
	t.Logf("the refusal: %v", err)
}

// TestInstanceListEmptyInventoryL170 (RELNOTES L170, l170-2's red): on a store with no page instance, admin_inventory()
// answers its state row with every instance column NULL (0193: admin_inventory_state LEFT JOIN admin_instances), and
// 'pgvigil instance list' must answer the file's instances, never 'cannot scan NULL'. A fresh migrated store of its own.
func TestInstanceListEmptyInventoryL170(t *testing.T) {
	dsn := checkStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	rows, err := instanceRows(ctx, pool, &config.Config{Instances: []config.Instance{{Name: "file-one", Engine: config.EnginePostgres}}})
	if err != nil {
		t.Fatalf("list on a store with no page instance: %v", err)
	}
	if len(rows) != 1 || rows[0].Name != "file-one" || rows[0].Source != "file" || rows[0].LastAge != "no successful run now" {
		t.Errorf("list on a store with no page instance: want the file's one instance, never collected; got %+v", rows)
	}
}
