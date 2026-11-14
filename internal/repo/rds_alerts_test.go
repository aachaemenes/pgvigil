package repo

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): 0130 removes the alerts area's findings and the
// alert, operator and fail-safe rows of an RDS instance, and leaves a server someone runs as it was. The rows are
// planted after the migration, then 0130's own text is run again (it is idempotent), as a store that read RDS before
// this release would meet it.
func TestRDSAlertsCleanupOnAStore(t *testing.T) {
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
	tag := time.Now().UnixNano() % 1000000000
	rds, onprem := fmt.Sprintf("rds-al-%d", tag), fmt.Sprintf("srv-al-%d", tag)
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name IN ($1, $2)`, rds, onprem); err != nil {
			t.Error(err)
		}
	}()
	ids := map[string]int{}
	for name, platform := range map[string]string{rds: "rdssqlserver", onprem: "sqlserver"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, '16.0', 160000, false, '{}', 'sqlserver')`, name, platform).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[platform] = id
		for _, q := range []string{
			`INSERT INTO pgvigil.mssql_check_finding (instance_id, area, check_name, object, rule, severity, first_seen, snapshot_at)
			 VALUES ($1, 'alerts', 'no operator', 'SQL Server Agent', 'sp_Blitz 31', 'warning', now(), now()),
			        ($1, 'config', 'an option', 'x', 'sp_Blitz 1', 'info', now(), now())`,
			`INSERT INTO pgvigil.mssql_agent_alert (instance_id, name, snapshot_at) VALUES ($1, 'sev 19', now())`,
			`INSERT INTO pgvigil.mssql_agent_operator (instance_id, name, snapshot_at) VALUES ($1, 'dba', now())`,
			`INSERT INTO pgvigil.mssql_agent_alerting (instance_id, snapshot_at) VALUES ($1, now())`,
		} {
			if _, err := pool.Exec(ctx, q, id); err != nil {
				t.Fatalf("%s: %v", platform, err)
			}
		}
	}
	b, err := migrations.ReadFile("sql/0130_mssql_rds_alerts.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, string(b)); err != nil {
		t.Fatalf("0130 again: %v", err)
	}
	count := func(id int) string {
		var f, c, a, o, g int
		if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.mssql_check_finding WHERE instance_id = $1 AND area = 'alerts'),
		    (SELECT count(*) FROM pgvigil.mssql_check_finding WHERE instance_id = $1 AND area = 'config'),
		    (SELECT count(*) FROM pgvigil.mssql_agent_alert WHERE instance_id = $1), (SELECT count(*) FROM pgvigil.mssql_agent_operator WHERE instance_id = $1),
		    (SELECT count(*) FROM pgvigil.mssql_agent_alerting WHERE instance_id = $1)`, id).Scan(&f, &c, &a, &o, &g); err != nil {
			t.Fatal(err)
		}
		return fmt.Sprintf("alerts findings %d, config findings %d, alerts %d, operators %d, fail-safe %d", f, c, a, o, g)
	}
	if got := count(ids["rdssqlserver"]); got != "alerts findings 0, config findings 1, alerts 0, operators 0, fail-safe 0" {
		t.Errorf("RDS after 0130: %s", got)
	}
	if got := count(ids["sqlserver"]); got != "alerts findings 1, config findings 1, alerts 1, operators 1, fail-safe 1" {
		t.Errorf("a server someone runs after 0130: %s", got)
	}
}
