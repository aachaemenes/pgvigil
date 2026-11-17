package mssql

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestMasterDSN (P25 task 9b): the logical server's master is opened with the instance's own connection string, its
// database master in place of the one it names - a sqlserver:// URL's database parameter (any case), an ADO string's
// database or initial catalog (a ';' inside double quotes is a value's, as go-mssqldb splits it), the other parts kept;
// an odbc: string and an empty one refused.
func TestMasterDSN(t *testing.T) {
	for _, c := range []struct{ in, want, err string }{
		{in: "sqlserver://u:p@srv.database.windows.net?database=sales&encrypt=true", want: "sqlserver://u:p@srv.database.windows.net?database=master&encrypt=true"},
		{in: "sqlserver://u:p@srv.database.windows.net?Database=sales", want: "sqlserver://u:p@srv.database.windows.net?database=master"},
		{in: "sqlserver://u:p@srv.database.windows.net", want: "sqlserver://u:p@srv.database.windows.net?database=master"},
		{in: "server=srv.database.windows.net;user id=u;password=p;database=sales;encrypt=true", want: "server=srv.database.windows.net;user id=u;password=p;encrypt=true;database=master"},
		{in: "Server=srv;Initial Catalog=sales;User ID=u;Password=\"a;database=x\"\"y\";", want: "Server=srv;User ID=u;Password=\"a;database=x\"\"y\";database=master"},
		{in: "server=srv;fedauth=ActiveDirectoryManagedIdentity", want: "server=srv;fedauth=ActiveDirectoryManagedIdentity;database=master"},
		{in: "odbc:server=srv;database=sales", err: "odbc"},
		{in: "  ", err: "empty"},
	} {
		got, err := masterDSN(c.in)
		switch {
		case c.err != "" && (err == nil || !strings.Contains(err.Error(), c.err)):
			t.Errorf("masterDSN(%q) = %q, %v; want an error naming %s", c.in, got, err, c.err)
		case c.err == "" && (err != nil || got != c.want):
			t.Errorf("masterDSN(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
}

// TestPoolLimitRows (P25 task 9b): 0395's payload from the read's periods - one 'limit_period' row each with its times
// in RFC 3339 UTC and its limits as read (the CPU limit too: stored as Microsoft's informational figure), and one
// 'limit_read' row (state read) with the window the view held: the first period's start, the last one's end; a view
// with no row of the pool sends the read row alone, with no window (nothing to merge).
func TestPoolLimitRows(t *testing.T) {
	raw := []collect.Row{
		{"valid_from": "2026-11-03T17:00:00", "valid_to": "2026-11-13T09:00:00", "dtu_limit": int64(50), "storage_limit_mb": int64(5120), "cpu_limit": nil},
		{"valid_from": "2026-11-13T09:00:00", "valid_to": "2026-11-17T17:00:15.1234567", "dtu_limit": int64(100), "storage_limit_mb": int64(10240), "cpu_limit": "2.00"},
	}
	rows, err := poolLimitRows("srv1", "pool1", raw)
	if err != nil {
		t.Fatal(err)
	}
	got := fmt.Sprint(rows)
	want := "[map[cpu_limit:<nil> dtu_limit:50 kind:limit_period pool:pool1 server:srv1 storage_limit_mb:5120 valid_from:2026-11-03T17:00:00Z valid_to:2026-11-13T09:00:00Z] " +
		"map[cpu_limit:2.00 dtu_limit:100 kind:limit_period pool:pool1 server:srv1 storage_limit_mb:10240 valid_from:2026-11-13T09:00:00Z valid_to:2026-11-17T17:00:15.1234567Z] " +
		"map[kind:limit_read pool:pool1 server:srv1 state:read window_from:2026-11-03T17:00:00Z window_to:2026-11-17T17:00:15.1234567Z]]"
	if got != want {
		t.Errorf("the payload:\n got %s\nwant %s", got, want)
	}
	rows, err = poolLimitRows("srv1", "pool1", nil)
	if err != nil || fmt.Sprint(rows) != "[map[kind:limit_read pool:pool1 server:srv1 state:read]]" {
		t.Errorf("an empty view: %v, %v; want the read row alone, no window", rows, err)
	}
	if _, err := poolLimitRows("srv1", "pool1", []collect.Row{{"valid_from": "", "valid_to": "2026-11-17T17:00:00"}}); err == nil {
		t.Error("a period with no start: no error")
	}
}

// TestPoolLimitsCollector (P25 task 9b): mssql_pool_limits runs hourly, only on an Azure SQL Database in an elastic
// pool, through RunInstance (it opens master from the instance's configuration; Run alone refuses); its two skips say
// why in words - without dbmanager the opt-in and what it opens (create and drop databases, money), without master
// the way in and the server's answer, cut.
func TestPoolLimitsCollector(t *testing.T) {
	c, ok := registry[Prefix+"pool_limits"]
	if !ok {
		t.Fatal("mssql_pool_limits is not registered")
	}
	if c.DefaultInterval() != time.Hour {
		t.Errorf("interval %v, want an hour", c.DefaultInterval())
	}
	for _, x := range []struct {
		info Info
		ok   bool
		why  string
	}{
		{Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool"}, true, ""},
		{Info{Kind: KindAzureDB, ServiceObjective: "elasticpool"}, true, ""},
		{Info{Kind: KindAzureDB, ServiceObjective: "S0"}, false, "not in an elastic pool"},
		{Info{Kind: KindAzureMI}, false, "Azure SQL Database's"},
		{Info{Kind: KindServer}, false, "Azure SQL Database's"},
	} {
		ok, why := c.Applies(x.info)
		if ok != x.ok || (x.why != "" && !strings.Contains(why, x.why)) {
			t.Errorf("Applies(%v %s) = %v %q, want %v naming %q", x.info.Kind, x.info.ServiceObjective, ok, why, x.ok, x.why)
		}
	}
	if _, ok := c.(InstanceRunner); !ok {
		t.Error("mssql_pool_limits is not an InstanceRunner: it could not open master")
	}
	if _, err := c.Run(context.Background(), nil, Info{}); err == nil {
		t.Error("Run alone: no error")
	}
	for _, w := range []string{"dbmanager", "opt-in", "create and drop databases", "cost money", "commented-out block"} {
		if !strings.Contains(noRightWords, w) {
			t.Errorf("the no-right words do not say %q: %s", w, noRightWords)
		}
	}
	long := noMasterWords(errors.New(strings.Repeat("x", 500)))
	if !strings.Contains(long, "master") || !strings.Contains(long, "contained database user") || len(long) > 450 {
		t.Errorf("the no-master words (%d bytes): %s", len(long), long)
	}
}

// TestPoolLimitsLive (P25 task 9b; PGVIGIL_MSSQL_TEST_DSN, a sqlserver:// string of a sysadmin login on SQL Server
// 2017 or later): the statements where SQL Server can run them - the periods statement on a seeded copy of the view's
// columns (a temporary table in its place: sys.elastic_pool_resource_stats is Azure's alone), the right as the server's
// admin (dbo in master: 1) and as a plain login (0: no dbmanager role on SQL Server, the login master's guest), and
// RunInstance's two skips end to end - a plain login (no dbmanager) and a contained database user (no way into master).
func TestPoolLimitsLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	base := os.Getenv("PGVIGIL_MSSQL_TEST_DSN")
	u, err := url.Parse(base)
	if err != nil || u.Scheme != "sqlserver" {
		t.Skip("PGVIGIL_MSSQL_TEST_DSN is not a sqlserver:// string: the logins' strings are made from it")
	}
	exec := func(q string) {
		t.Helper()
		if _, err := conn.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	// the periods: pool1's rows - 50 DTUs, then 100 with a CPU limit, then the CPU limit gone (NULL: another period);
	// pool2's row not read
	exec(`IF OBJECT_ID('tempdb..#pl_epr') IS NOT NULL DROP TABLE #pl_epr;
CREATE TABLE #pl_epr (start_time datetime2, end_time datetime2, elastic_pool_name nvarchar(128), elastic_pool_dtu_limit int,
  elastic_pool_storage_limit_mb bigint, elastic_pool_cpu_limit decimal(5,2));
INSERT INTO #pl_epr VALUES
 ('2026-11-17T10:00:00', '2026-11-17T10:00:15', N'pool1', 50, 5120, NULL),
 ('2026-11-17T10:00:15', '2026-11-17T10:00:30', N'pool1', 50, 5120, NULL),
 ('2026-11-17T10:00:30', '2026-11-17T10:00:45', N'pool1', 100, 10240, 2.00),
 ('2026-11-17T10:00:45', '2026-11-17T10:01:00', N'pool1', 100, 10240, 2.00),
 ('2026-11-17T10:01:00', '2026-11-17T10:01:15', N'pool1', 100, 10240, NULL),
 ('2026-11-17T10:00:00', '2026-11-17T10:00:15', N'pool2', 800, 9999, NULL);`)
	raw, err := QueryRows(ctx, conn, strings.Replace(poolLimitsSQL, "sys.elastic_pool_resource_stats", "#pl_epr", 1), "pool1")
	if err != nil {
		t.Fatalf("the periods statement: %v", err)
	}
	rows, err := poolLimitRows("srv1", "pool1", raw)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range rows {
		got = append(got, fmt.Sprint(r["valid_from"], " ", r["valid_to"], " ", r["dtu_limit"], " ", r["storage_limit_mb"], " ", r["cpu_limit"], " ", r["window_from"], " ", r["window_to"]))
	}
	want := "2026-11-17T10:00:00Z 2026-11-17T10:00:30Z 50 5120 <nil> <nil> <nil> | 2026-11-17T10:00:30Z 2026-11-17T10:01:00Z 100 10240 2.00 <nil> <nil> | " +
		"2026-11-17T10:01:00Z 2026-11-17T10:01:15Z 100 10240 <nil> <nil> <nil> | <nil> <nil> <nil> <nil> <nil> 2026-11-17T10:00:00Z 2026-11-17T10:01:15Z"
	if g := strings.Join(got, " | "); g != want {
		t.Errorf("the periods:\n got %s\nwant %s", g, want)
	}
	// the right in master as the admin (sysadmin: dbo there)
	adm, err := masterDSN(base)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGVIGIL_POOL_LIMITS_ADMIN_DSN", adm)
	db, mc, err := openMaster(ctx, config.Instance{Name: "pl-admin", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_POOL_LIMITS_ADMIN_DSN"})
	if err != nil {
		t.Fatalf("openMaster as the admin: %v", err)
	}
	r, err := QueryRows(ctx, mc, poolLimitsRightSQL)
	_ = mc.Close()
	_ = db.Close()
	if v, _ := asInt(firstValue(r, "has_right")); err != nil || v != 1 {
		t.Errorf("the right as the admin: %v %v, want 1 (dbo in master)", r, err)
	}
	// a plain login: no dbmanager - RunInstance skips with the opt-in's words, before any read of the view
	pw := func() string { b := make([]byte, 12); _, _ = rand.Read(b); return "Pv1!" + hex.EncodeToString(b) }
	plain, ppw := fmt.Sprintf("pgv_pl_%d", time.Now().UnixNano()%1000000), pw()
	exec(fmt.Sprintf("CREATE LOGIN [%s] WITH PASSWORD = N'%s', CHECK_POLICY = OFF;", plain, ppw))
	t.Cleanup(func() { _, _ = conn.ExecContext(context.Background(), fmt.Sprintf("DROP LOGIN [%s];", plain)) })
	pu := *u
	pu.User = url.UserPassword(plain, ppw)
	t.Setenv("PGVIGIL_POOL_LIMITS_PLAIN_DSN", pu.String())
	in := config.Instance{Name: "pl-plain", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_POOL_LIMITS_PLAIN_DSN"}
	_, err = poolLimitsCollector{}.RunInstance(ctx, conn, Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool", PoolTag: "pool1", ServerName: "srv1"}, in)
	if !errors.Is(err, collect.ErrSkip) || !strings.Contains(err.Error(), "not a member of dbmanager") {
		t.Errorf("a plain login: %v, want the skip without dbmanager", err)
	}
	// a contained database user: no way into master - RunInstance skips with the no-master words; the server's setting
	// is put back as it was (review t11-1 NIT 8)
	var oldCDA int
	if err := conn.QueryRowContext(ctx, "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'contained database authentication'").Scan(&oldCDA); err != nil {
		t.Logf("contained database authentication not read (%v): the no-master path not run", err)
		return
	}
	// a cleanup, not a defer: a test's defers run before its cleanups, and SQL Server refuses to turn the setting off
	// while a contained database exists (p11b-1: Msg 'existing contained databases'); registered before the database's
	// own cleanup, it runs after the drop (cleanups run last registered first)
	t.Cleanup(func() {
		if _, err := conn.ExecContext(context.Background(), fmt.Sprintf("EXEC sp_configure 'contained database authentication', %d; RECONFIGURE;", oldCDA)); err != nil {
			t.Errorf("contained database authentication not put back to %d: %v", oldCDA, err)
		}
	})
	if _, err := conn.ExecContext(ctx, "EXEC sp_configure 'contained database authentication', 1; RECONFIGURE;"); err != nil {
		t.Logf("contained database authentication not set (%v): the no-master path not run", err)
		return
	}
	cdb := fmt.Sprintf("pgv_pl_c%d", time.Now().UnixNano()%1000000)
	exec(fmt.Sprintf("CREATE DATABASE [%s] CONTAINMENT = PARTIAL;", cdb))
	t.Cleanup(func() {
		_, _ = conn.ExecContext(context.Background(), fmt.Sprintf("ALTER DATABASE [%s] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [%s];", cdb, cdb))
	})
	cpw := pw()
	exec(fmt.Sprintf("EXEC [%s].sys.sp_executesql N'CREATE USER pgv_pl_cu WITH PASSWORD = N''%s'';';", cdb, cpw))
	cu := *u
	cu.User = url.UserPassword("pgv_pl_cu", cpw)
	q := cu.Query()
	q.Set("database", cdb)
	cu.RawQuery = q.Encode()
	t.Setenv("PGVIGIL_POOL_LIMITS_CONTAINED_DSN", cu.String())
	cin := config.Instance{Name: "pl-contained", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_POOL_LIMITS_CONTAINED_DSN"}
	cdbh, cc, err := Connect(ctx, cin)
	if err != nil {
		t.Fatalf("the contained user into its own database: %v (the user's string is wrong, not the path under test)", err)
	}
	_ = cc.Close()
	_ = cdbh.Close()
	start := time.Now()
	_, err = poolLimitsCollector{}.RunInstance(ctx, conn, Info{Kind: KindAzureDB, ServiceObjective: "ElasticPool", PoolTag: "pool1", ServerName: "srv1"}, cin)
	if !errors.Is(err, collect.ErrSkip) || !strings.Contains(err.Error(), "could not sign in to the logical server's master") {
		t.Errorf("a contained database user: %v, want the skip without master", err)
	}
	if d := time.Since(start); d > masterConnectCap+5*time.Second {
		t.Errorf("the refused master took %v, over the %v cap", d, masterConnectCap)
	}
}

// TestNoMasterWordsCutOnARune (review t11-1 NIT 7): the driver's words are cut at 200 on a character, never inside one -
// a cut UTF-8 sequence makes PostgreSQL refuse the skip's note, and the skip is not written.
func TestNoMasterWordsCutOnARune(t *testing.T) {
	w := noMasterWords(errors.New(strings.Repeat("\u20ac", 100))) // 300 bytes of a 3-byte character
	if !utf8.ValidString(w) {
		t.Errorf("noMasterWords cut inside a character: %q", w[len(w)-12:])
	}
}
