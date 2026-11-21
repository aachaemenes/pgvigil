package main

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestConnFromDSNL170: the dsn on stdin is read back into the page's own
// fields, so the page's BuildDSN and its checks apply unchanged; a sign-in the page does not take is refused in words.
func TestConnFromDSNL170(t *testing.T) {
	for _, c := range []struct {
		engine, dsn string
		want        config.Conn
		refuse      string
	}{
		{config.EnginePostgres, "host=pg7 port=5433 dbname=app user=mon password='s3 cret' sslmode=verify-full", config.Conn{Engine: config.EnginePostgres, Auth: "password", Host: "pg7", Port: 5433, DBName: "app", Login: "mon", Password: "s3 cret", Extra: "sslmode=verify-full"}, ""},
		{config.EnginePostgres, "postgres://mon@pg7/app", config.Conn{Engine: config.EnginePostgres, Auth: "pgpass", Host: "pg7", Port: 5432, DBName: "app", Login: "mon"}, ""},
		{config.EnginePostgres, "dbname=app", config.Conn{}, "host"},
		{config.EngineSQLServer, "sqlserver://mon:pw@sql07:1433?database=d&encrypt=true", config.Conn{Engine: config.EngineSQLServer, Auth: "sql", Host: "sql07", Port: 1433, DBName: "d", Login: "mon", Password: "pw", Extra: "encrypt=true"}, ""},
		{config.EngineSQLServer, "sqlserver://sql07?database=d", config.Conn{Engine: config.EngineSQLServer, Auth: "windows", Host: "sql07", DBName: "d"}, ""},
		{config.EngineSQLServer, "sqlserver://app@srv.database.windows.net?database=d&fedauth=ActiveDirectoryServicePrincipal&password=sec", config.Conn{Engine: config.EngineSQLServer, Auth: "entra", Host: "srv.database.windows.net", DBName: "d", Login: "app", Password: "sec"}, ""},
		{config.EngineSQLServer, "sqlserver://srv.database.windows.net?database=d&fedauth=ActiveDirectoryManagedIdentity", config.Conn{Engine: config.EngineSQLServer, Auth: "entra-identity", Host: "srv.database.windows.net", DBName: "d"}, ""},
		{config.EngineSQLServer, "sqlserver://srv.database.windows.net?database=d&fedauth=ActiveDirectoryAzCli", config.Conn{}, "page"},
		{"oracle", "x", config.Conn{}, "postgres or sqlserver"},
	} {
		got, err := connFromDSN(c.engine, c.dsn)
		switch {
		case c.refuse == "" && (err != nil || got != c.want):
			t.Errorf("%s: %+v, %v; want %+v", c.dsn, got, err, c.want)
		case c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)):
			t.Errorf("%s: %v, want a refusal naming %q", c.dsn, err, c.refuse)
		case c.refuse == "":
			if _, err := config.BuildDSN(got); err != nil {
				t.Errorf("%s: the page's BuildDSN refuses the fields: %v", c.dsn, err)
			}
		}
		if err != nil && (strings.Contains(err.Error(), "s3 cret") || strings.Contains(err.Error(), "sec")) {
			t.Errorf("%s: the refusal repeats a secret", c.dsn)
		}
	}
}

// TestInstanceAddPayloadL170: the payload is the page's own for import_admin_instance, audited as 'cli:<account>'.
func TestInstanceAddPayloadL170(t *testing.T) {
	c := config.Conn{Engine: config.EnginePostgres, Auth: "password", Host: "pg7", Port: 5433, DBName: "app", Login: "mon", Password: "never-in-it"}
	pay := addPayload("pg7", "auto", []string{"prod"}, c, "file:/etc/pgvigil/instances/pg7-ab.dsn", "admin1", []string{"pg1"})
	for k, want := range map[string]any{"op": "add", "ui_user": "cli:admin1", "client": "cli", "name": "pg7", "engine": "postgres", "auth": "password", "host": "pg7", "port": "5433", "dbname": "app", "login": "mon", "dsn_ref": "file:/etc/pgvigil/instances/pg7-ab.dsn", "platform": "auto"} {
		if pay[k] != want {
			t.Errorf("%s = %v, want %v", k, pay[k], want)
		}
	}
	for k, v := range pay {
		if s, ok := v.(string); ok && strings.Contains(s, "never-in-it") {
			t.Errorf("the payload carries the password in %s", k)
		}
	}
}

// TestInstanceNeedsServiceL170: on a host with no installed pgvigil service the account that owns the page's
// credentials is unknown, so add is refused before anything is read or written.
func TestInstanceNeedsServiceL170(t *testing.T) {
	if acct := serviceAccountForSecrets(); acct != "" {
		t.Skip("a pgvigil service is installed here")
	}
	_, cfg := exportFolder(t)
	code, out := runWith(t, "host=pg9 user=mon password=x\n", "instance", "add", "-config", cfg, "-name", "pg9", "-engine", "postgres", "-dsn-stdin", "-no-test")
	if code == 0 || !strings.Contains(out, "no installed pgvigil service") {
		t.Errorf("add without a service: exit %d, %q", code, out)
	}
}

// TestInstanceStoreL170: add, list (with each instance's last collection age) and disable through the page's own
// function on a migrated store (PGVIGIL_REPO_TEST_DSN).
func TestInstanceStoreL170(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	c := config.Conn{Engine: config.EnginePostgres, Auth: "password", Host: "pg-l170", Port: 5432, DBName: "app", Login: "mon"}
	name := "l170-store"
	if err := instanceWrite(ctx, pool, addPayload(name, "auto", nil, c, "file:/nonexistent/l170.dsn", "tester", nil)); err != nil {
		t.Fatalf("add: %v", err)
	}
	rows, err := instanceRows(ctx, pool, &config.Config{Instances: []config.Instance{{Name: "file-one", Engine: config.EnginePostgres}}})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range rows {
		got = append(got, r.Name+" "+r.Source+" "+r.State+" "+r.LastAge)
	}
	all := strings.Join(got, "\n")
	if !strings.Contains(all, name+" page enabled no successful run now") || !strings.Contains(all, "file-one file") {
		t.Errorf("list:\n%s", all)
	}
	if err := instanceWrite(ctx, pool, map[string]any{"op": "disable", "ui_user": "cli:tester", "client": "cli", "name": name, "file_names": []string{}}); err != nil {
		t.Fatalf("disable: %v", err)
	}
	rows, _ = instanceRows(ctx, pool, &config.Config{})
	for _, r := range rows {
		if r.Name == name && r.State != "disabled" {
			t.Errorf("after disable: %+v", r)
		}
	}
	_ = instanceWrite(ctx, pool, map[string]any{"op": "remove", "ui_user": "cli:tester", "client": "cli", "name": name, "file_names": []string{}})
}
