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
