package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// An Azure SQL Database elastic pool, live (scripts/proof-mssql-pool.sh against scripts/lab/azure-sqldb.sh's pool
// tier; skipped without PGVIGIL_POOL_DSN). The connection strings come from the lab's state file through the
// environment and are never printed:
//
//	PGVIGIL_POOL_DSN        pgv_pool on the first pooled database: a SQL login with ##MS_ServerStateReader## and a
//	                        user in that database, nothing else
//	PGVIGIL_POOL_ADMIN_DSN  the server admin on the same database (the reference read)
//	PGVIGIL_POOL_TAG        the pool's name, as the instance's tag pool:<name> gives it
//	PGVIGIL_POOL_USER_DSN   a contained user with VIEW DATABASE STATE only, on the same database (P0's second login)
//	PGVIGIL_POOL_CONN_DSN   pgv_conn on the SECOND pooled database: ##MS_ServerStateReader## and
//	                        ##MS_DatabaseConnector##, no user there (P3)
//
// P0 detection: a pooled database is Azure SQL Database with the service objective ElasticPool, and the pool's login
// holds VIEW SERVER STATE by its role; the contained user's detection runs (the batch C4 changed) and is recorded.
// P1 the minutes: the collector's rows equal internal/mssql's own arithmetic over the view's rows as the server
// admin reads them right after, minute for minute (the same complete minutes, the same samples, the same figures).
// P3 the role's reach into a database with no user: recorded as found (Microsoft's server roles page says
// ##MS_DatabaseConnector## connects there; whether ##MS_ServerStateReader## then reads the view is what this asks).
// P4 the name without a tag: as sys.database_service_objectives answers this login - a skip with the step, or the
// name - recorded.
func TestPoolLive(t *testing.T) {
	dsn, admin, tag := os.Getenv("PGVIGIL_POOL_DSN"), os.Getenv("PGVIGIL_POOL_ADMIN_DSN"), os.Getenv("PGVIGIL_POOL_TAG")
	if dsn == "" || admin == "" || tag == "" {
		t.Skip("PGVIGIL_POOL_DSN / PGVIGIL_POOL_ADMIN_DSN / PGVIGIL_POOL_TAG not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	open := func(name, d string) *sql.Conn {
		t.Helper()
		db, err := mssqlopen.Open(d)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		t.Cleanup(func() { _ = db.Close() })
		c, err := db.Conn(ctx)
		if err != nil {
			t.Fatalf("%s: connect: %v", name, err)
		}
		t.Cleanup(func() { _ = c.Close() })
		return c
	}
	conn, ref := open("pgv_pool", dsn), open("the server admin", admin)

	// P0
	info, err := Detect(ctx, conn, "auto")
	if err != nil {
		t.Fatalf("P0 detect as pgv_pool: %v", err)
	}
	if info.Kind != KindAzureDB || info.EngineEdition != 5 || !strings.EqualFold(info.ServiceObjective, "ElasticPool") || !info.ViewServerState {
		t.Fatalf("P0 detect as pgv_pool: kind %s, edition %d, service objective %q, VIEW SERVER STATE %v; want azuresqldb, 5, ElasticPool, true",
			info.Kind, info.EngineEdition, info.ServiceObjective, info.ViewServerState)
	}
	t.Logf("P0 pgv_pool: kind %s, edition %d, service objective %s, VIEW SERVER STATE %v, server %s", info.Kind, info.EngineEdition, info.ServiceObjective, info.ViewServerState, info.ServerName)
	if u := os.Getenv("PGVIGIL_POOL_USER_DSN"); u != "" {
		ui, err := Detect(ctx, open("the contained user", u), "auto")
		if err != nil {
			t.Fatalf("P0 detect as the contained user: %v", err)
		}
		ok, why := poolCollector{}.Applies(ui)
		t.Logf("P0 the contained user (VIEW DATABASE STATE only): kind %s, service objective %s, VIEW SERVER STATE %v; mssql_pool applies %v %q",
			ui.Kind, ui.ServiceObjective, ui.ViewServerState, ok, why)
		if ui.Kind != KindAzureDB {
			t.Errorf("P0 the contained user: kind %s, want azuresqldb", ui.Kind)
		}
	}
	if ok, why := (poolCollector{}).Applies(info); !ok {
		t.Fatalf("P1 mssql_pool does not apply to pgv_pool: %s", why)
	}

	// P1
	info.PoolTag = tag
	rows, err := poolCollector{}.Run(ctx, conn, info)
	if err != nil {
		t.Fatalf("P1 run: %v", err)
	}
	raw, err := QueryRows(ctx, ref, poolStatsSQL)
	if err != nil {
		t.Fatalf("P1 the admin's read: %v", err)
	}
	var samples []poolSample
	var now time.Time
	for _, r := range raw {
		s, err := poolSampleOf(r)
		if err != nil {
			t.Fatal(err)
		}
		if now.IsZero() {
			now = s.serverUTC
		}
		samples = append(samples, s)
	}
	want := map[string]collect.Row{}
	for _, m := range poolMinutes(samples, now) {
		r := m.row(info.ServerName, tag, "tag")
		want[r["minute"].(string)] = r
	}
	if len(rows) == 0 {
		t.Fatalf("P1 the collector stored no complete minute (the admin's read holds %d samples, %d complete minutes)", len(samples), len(want))
	}
	for _, r := range rows {
		m := r["minute"].(string)
		w, ok := want[m]
		if !ok {
			t.Errorf("P1 minute %s: the collector has it, the admin's read does not (the view keeps about 40 minutes)", m)
			continue
		}
		for k, v := range r {
			if fmt.Sprint(w[k]) != fmt.Sprint(v) {
				t.Errorf("P1 minute %s %s: collector %v, admin's read %v", m, k, v, w[k])
			}
		}
	}
	first, last := rows[0], rows[len(rows)-1]
	t.Logf("P1 %d complete minutes from %s to %s equal the admin's read (%d samples); the newest: allocated %v %%, storage limit %v MB, eDTU %v %%",
		len(rows), first["minute"], last["minute"], len(samples), last["allocated_storage_percent"], last["storage_limit_mb"], last["avg_edtu_percent"])

	// P4
	info.PoolTag = ""
	if _, err := (poolCollector{}).Run(ctx, conn, info); errors.Is(err, collect.ErrSkip) {
		t.Logf("P4 without a tag: skipped - %v", err)
	} else if err != nil {
		t.Errorf("P4 without a tag: an error that is not a skip: %v", err)
	} else {
		t.Logf("P4 without a tag: sys.database_service_objectives named the pool to pgv_pool")
	}

	// P3
	if c := os.Getenv("PGVIGIL_POOL_CONN_DSN"); c != "" {
		db, err := mssqlopen.Open(c)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = db.Close() }()
		var n int
		var user sql.NullString
		err = db.QueryRowContext(ctx, `SELECT COUNT(*), MAX(USER_NAME()) FROM sys.dm_elastic_pool_resource_stats`).Scan(&n, &user)
		t.Logf("P3 pgv_conn (##MS_ServerStateReader## + ##MS_DatabaseConnector##, no user) on the second database: rows %d, user %q, error %v", n, user.String, err)
	}
}
