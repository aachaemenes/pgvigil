package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAdminInstanceCloudOnAStore (B24p, 0193): a page instance's aws: and azure: blocks - set, edited and cleared
// through import_admin_instance_cloud, each audited with the old and the new block and moving the generation; the
// store's rules (= Go's PageCloudShape: aws on PostgreSQL, azure on an azuresqldb SQL Server, the keys and their
// shapes, 0157's file_names refusal, no page row); the round trip through Repo.Inventory (every field, the host); the
// row lock against a concurrent remove (an answer, never a foreign-key error); the cascade on remove. Needs a
// migrated repository and its owner: PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestAdminInstanceCloudOnAStore(t *testing.T) {
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
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	suf := time.Now().UnixNano() % 1000000000
	pg, ms, msAuto := fmt.Sprintf("cl-pg-%d", suf), fmt.Sprintf("cl-ms-%d", suf), fmt.Sprintf("cl-ma-%d", suf)
	defer func() {
		for _, n := range []string{pg, ms, msAuto} {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, n)
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_removed WHERE name = $1`, n)
		}
	}()
	call := func(fn, payload string) (string, string) {
		t.Helper()
		var out, detail string
		if err := pool.QueryRow(ctx, fmt.Sprintf(`SELECT a->>'outcome', coalesce(a->>'detail', '') FROM pgvigil.%s(now(), $1::jsonb) a`, fn), payload).Scan(&out, &detail); err != nil {
			t.Fatalf("%s %s: %v", fn, payload, err)
		}
		return out, detail
	}
	for _, a := range []string{
		fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":"postgres","platform":"rds","dsn_ref":"file:/x/%s.dsn","host":"db1.c9akciq32.us-east-2.rds.amazonaws.com","auth":"password"}`, pg, pg),
		fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":"sqlserver","platform":"azuresqldb","dsn_ref":"file:/x/%s.dsn","host":"srv1.database.windows.net","auth":"sql"}`, ms, ms),
		fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"engine":"sqlserver","platform":"auto","dsn_ref":"file:/x/%s.dsn","host":"h","auth":"sql"}`, msAuto, msAuto),
	} {
		if out, d := call("import_admin_instance", a); out != "done" {
			t.Fatalf("add: %s %s", out, d)
		}
	}
	gen := func() int64 {
		g, err := r.InventoryGeneration(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return g
	}
	set := func(name, aws, azure string) (string, string) {
		return call("import_admin_instance_cloud", fmt.Sprintf(`{"op":"set","ui_user":"test","client":"t","name":%q,"aws":%s,"azure":%s,"file_names":["in-the-file"]}`, name, aws, azure))
	}
	g0 := gen()
	awsBlock := `{"region":"us-east-2","db_instance":"db1","cluster":"dba-lab-pg","profile":"prod-read"}`
	if out, d := set(pg, awsBlock, "null"); out != "done" {
		t.Fatalf("set aws: %s %s", out, d)
	}
	azBlock := `{"subscription":"0b1f6471-1bf0-4dda-aec3-111122223333","resource_group":"rg-1","server":"srv1","cloud":"public"}`
	if out, d := set(ms, "null", azBlock); out != "done" {
		t.Fatalf("set azure: %s %s", out, d)
	}
	if gen() == g0 {
		t.Error("a block set did not move the inventory generation")
	}
	page, _, err := r.Inventory(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, p := range page {
		switch p.Name {
		case pg:
			found++
			if a := p.AWS; a == nil || a.Region != "us-east-2" || a.DBInstance != "db1" || a.Cluster != "dba-lab-pg" || a.Profile != "prod-read" || p.Azure != nil || p.Host != "db1.c9akciq32.us-east-2.rds.amazonaws.com" {
				t.Errorf("the round trip of %s: %+v %+v host %q", pg, p.AWS, p.Azure, p.Host)
			}
		case ms:
			found++
			if a := p.Azure; a == nil || a.Subscription != "0b1f6471-1bf0-4dda-aec3-111122223333" || a.ResourceGroup != "rg-1" || a.Server != "srv1" || a.Cloud != "public" || p.AWS != nil {
				t.Errorf("the round trip of %s: %+v %+v", ms, p.AWS, p.Azure)
			}
		}
	}
	if found != 2 {
		t.Fatalf("Inventory listed %d of the two instances", found)
	}
	// an edit is audited with the old block and the new
	if out, d := set(pg, `{"region":"us-east-2","db_instance":"db2"}`, "null"); out != "done" {
		t.Fatalf("edit aws: %s %s", out, d)
	}
	var detail string
	if err := pool.QueryRow(ctx, `SELECT detail FROM pgvigil.admin_audit WHERE target = $1 AND op = 'instance cloud' ORDER BY at DESC, audit_id DESC LIMIT 1`, pg).Scan(&detail); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail, `"db1"`) || !strings.Contains(detail, `"db2"`) {
		t.Errorf("the edit's audit: %q, want the old (db1) and the new (db2) block", detail)
	}
	// the store's rules
	for _, c := range []struct{ what, name, aws, azure, want string }{
		{"a key the page block does not take", pg, `{"region":"us-east-2","db_instance":"db1","log_group":"/x"}`, "null", "log_group"},
		{"dms stays pgvigil.yaml's", pg, `{"region":"us-east-2","db_instance":"db1","dms":{"tasks":["t"]}}`, "null", "dms"},
		{"a bad region", pg, `{"region":"east","db_instance":"db1"}`, "null", "region"},
		{"no identifier", pg, `{"region":"us-east-2"}`, "null", "db_instance or cluster"},
		{"a bad identifier", pg, `{"region":"us-east-2","db_instance":"db--1"}`, "null", "identifier"},
		{"aws on SQL Server", msAuto, `{"region":"us-east-2","db_instance":"db1"}`, "null", "PostgreSQL"},
		{"azure on PostgreSQL", pg, "null", azBlock, "azuresqldb"},
		{"azure on a SQL Server that is not azuresqldb", msAuto, "null", azBlock, "azuresqldb"},
		{"azure without its server", ms, "null", `{"subscription":"0b1f6471-1bf0-4dda-aec3-111122223333","resource_group":"rg-1"}`, "server"},
		{"an upper-case server", ms, "null", `{"subscription":"0b1f6471-1bf0-4dda-aec3-111122223333","resource_group":"rg-1","server":"Srv1"}`, "server"},
		{"a bad subscription", ms, "null", `{"subscription":"x","resource_group":"rg-1","server":"srv1"}`, "subscription"},
		{"neither block (a clear is its own op)", pg, "null", "null", "clear"},
		{"no such instance", "no-such-" + pg, `{"region":"us-east-2","db_instance":"db1"}`, "null", "no instance"},
		{"a name of pgvigil.yaml", "in-the-file", `{"region":"us-east-2","db_instance":"db1"}`, "null", "pgvigil.yaml"},
	} {
		out, d := set(c.name, c.aws, c.azure)
		if out != "refused" || !strings.Contains(d, c.want) {
			t.Errorf("%s: %s %q, want refused naming %q", c.what, out, d, c.want)
		}
	}
	// clear
	if out, d := call("import_admin_instance_cloud", fmt.Sprintf(`{"op":"clear","ui_user":"test","name":%q}`, pg)); out != "done" {
		t.Fatalf("clear: %s %s", out, d)
	}
	page, _, _ = r.Inventory(ctx)
	for _, p := range page {
		if p.Name == pg && (p.AWS != nil || p.Azure != nil) {
			t.Errorf("after the clear: %+v %+v", p.AWS, p.Azure)
		}
	}
	// the row lock: a remove open in another transaction; the set waits for it and then answers, never an FK error
	if out, d := set(pg, `{"region":"us-east-2","db_instance":"db1"}`, "null"); out != "done" {
		t.Fatalf("set again: %s %s", out, d)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	var rm string
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_admin_instance(now(), $1::jsonb)->>'outcome'`, fmt.Sprintf(`{"op":"remove","ui_user":"test","name":%q}`, pg)).Scan(&rm); err != nil || rm != "done" {
		t.Fatalf("remove: %s %v", rm, err)
	}
	type answer struct{ out, detail string }
	done := make(chan answer, 1)
	go func() {
		var a answer
		err := pool.QueryRow(ctx, `SELECT a->>'outcome', coalesce(a->>'detail', '') FROM pgvigil.import_admin_instance_cloud(now(), $1::jsonb) a`,
			fmt.Sprintf(`{"op":"set","ui_user":"test","name":%q,"aws":{"region":"us-east-2","db_instance":"db3"},"azure":null}`, pg)).Scan(&a.out, &a.detail)
		if err != nil {
			a.out, a.detail = "error", err.Error()
		}
		done <- a
	}()
	select {
	case a := <-done:
		t.Fatalf("the set did not wait for the open remove: %+v", a)
	case <-time.After(700 * time.Millisecond):
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if a := <-done; a.out != "refused" || !strings.Contains(a.detail, "no instance") {
		t.Errorf("a set behind a remove: %+v, want refused 'no instance'", a)
	}
	// the cascade: the removed instance's blocks are gone
	var left int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instance_cloud WHERE name = $1`, pg).Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Errorf("a removed instance kept %d cloud row(s)", left)
	}
}
