package repo

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPGSigninStoreOnAStore (PGAUTH M1, decision 2's finding): import_pg_signin keeps one row per instance - the
// method word, whether it sends the password in clear, the session's TLS and the dsn's sslmode, never the identity -
// and pgvigil.pg_signin_findings is a warning while a password-shaped method signs in short of sslmode=verify-full:
// its detail names the method, the sslmode and the fix, and says when the session ran without TLS; verify-full, a
// method that sends no password and a read older than three hours (the collection is hourly) give none.
func TestPGSigninStoreOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform, engine) VALUES ('pgauth-si-' || md5(random()::text), 'onprem', 'postgres') RETURNING instance_id`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	var cols string
	if err := tx.QueryRow(ctx, `SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = 'pgvigil' AND table_name = 'pg_signin'`).Scan(&cols); err != nil {
		t.Fatal(err)
	}
	if cols != "instance_id,method,sends_password,ssl,sslmode,read_at" {
		t.Errorf("pgvigil.pg_signin's columns %q: want instance_id,method,sends_password,ssl,sslmode,read_at (no identity)", cols)
	}
	imp := func(age time.Duration, method string, sends, ssl bool, sslmode string) {
		t.Helper()
		p := []map[string]any{{"kind": "signin", "method": method, "clear": sends, "ssl": ssl, "sslmode": sslmode}}
		if _, err := tx.Exec(ctx, `SELECT pgvigil.import_pg_signin($1, now() - make_interval(secs => $2), $3::jsonb)`, id, age.Seconds(), p); err != nil {
			t.Fatal(err)
		}
	}
	finding := func() (int, string) {
		t.Helper()
		var n int
		var detail string
		if err := tx.QueryRow(ctx, `SELECT count(*), coalesce(min(detail), '') FROM pgvigil.pg_signin_findings WHERE instance_id = $1 AND severity = 'warning' AND setting = 'a password sent in clear, the server not fully checked'`, id).Scan(&n, &detail); err != nil {
			t.Fatal(err)
		}
		return n, detail
	}
	imp(time.Minute, "ldap", true, true, "require")
	if n, d := finding(); n != 1 || !strings.Contains(d, "by ldap") || !strings.Contains(d, "sslmode=require checks no server certificate") || !strings.Contains(d, "verify-full") ||
		!strings.Contains(d, "docs/postgres-signin.md") || strings.Contains(d, "without TLS") {
		t.Errorf("ldap at sslmode=require: %d finding(s), %q", n, d)
	}
	imp(time.Minute, "radius", true, false, "disable")
	if n, d := finding(); n != 1 || !strings.Contains(d, "by radius") || !strings.Contains(d, "(this session runs without TLS)") {
		t.Errorf("radius without TLS: %d finding(s), %q", n, d)
	}
	var rows int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.pg_signin WHERE instance_id = $1`, id).Scan(&rows); err != nil || rows != 1 {
		t.Errorf("pg_signin rows for the instance: %d (%v), want 1 (the newest read)", rows, err)
	}
	// pgauth12 N4: a late or retried older read never replaces the newest
	imp(2*time.Minute, "scram-sha-256", false, true, "prefer")
	if n, d := finding(); n != 1 || !strings.Contains(d, "by radius") {
		t.Errorf("an older read imported after the newest: %d finding(s), %q; want the newest (radius) kept", n, d)
	}
	for _, c := range []struct {
		age            time.Duration
		method         string
		sends, ssl     bool
		sslmode, words string
	}{
		{time.Minute / 2, "ldap", true, true, "verify-full", "verify-full"},
		{time.Minute / 4, "scram-sha-256", false, true, "prefer", "a method that sends no password"},
	} {
		imp(c.age, c.method, c.sends, c.ssl, c.sslmode)
		if n, d := finding(); n != 0 {
			t.Errorf("%s: %d finding(s), %q; want none", c.words, n, d)
		}
	}
	// pgauth12 N3: verify-ca's words
	imp(time.Second, "ldap", true, true, "verify-ca")
	if n, d := finding(); n != 1 || !strings.Contains(d, "sslmode=verify-ca does not check the server's name") {
		t.Errorf("ldap at verify-ca: %d finding(s), %q", n, d)
	}
}

// TestPGSigninWindowFollowsTheCollectorOnAStore (pgauth12 S3): a read five hours old - pg_signin on a 6-hour schedule -
// still shows the warning while a collector that beats names the instance (it neither flaps nor clears between
// reads), and hides it with no such collector (the 3-hour window of a 'pgvigil collect' with no heartbeat).
func TestPGSigninWindowFollowsTheCollectorOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	var id int
	var name string
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform, engine) VALUES ('pgauth-si6-' || md5(random()::text), 'onprem', 'postgres') RETURNING instance_id, name`).Scan(&id, &name); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_pg_signin($1, now() - interval '5 hours', '[{"kind":"signin","method":"ldap","clear":true,"ssl":true,"sslmode":"require"}]'::jsonb)`, id); err != nil {
		t.Fatal(err)
	}
	count := func() int {
		t.Helper()
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.pg_signin_findings WHERE instance_id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := count(); n != 0 {
		t.Errorf("a five-hour-old read with no collector naming the instance: %d finding(s), want none (the 3-hour window)", n)
	}
	col := "pgauth-si6-run-" + name
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '6 hours', now())`, col); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_instances (collector_id, instance, seen_at) VALUES ($1, $2, now())`, col, name); err != nil {
		t.Fatal(err)
	}
	if n := count(); n != 1 {
		t.Errorf("the same read with a beating collector naming the instance: %d finding(s), want 1 (no flap between 6-hour reads)", n)
	}
}
