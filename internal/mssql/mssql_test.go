package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

func TestParseVersion(t *testing.T) {
	for _, c := range []struct {
		in                  string
		major, minor, build int
	}{
		{"16.0.4135.4", 16, 0, 4135},
		{"15.0.2000.5", 15, 0, 2000},
		{"12.0.2000.8", 12, 0, 2000},
		{"10.50.6000.34", 10, 50, 6000},
		{"", 0, 0, 0},
		{"abc", 0, 0, 0},
		{"17", 17, 0, 0},
		{" 16.0.x ", 16, 0, 0},
	} {
		a, b, d := parseVersion(c.in)
		if a != c.major || b != c.minor || d != c.build {
			t.Errorf("parseVersion(%q) = %d, %d, %d; want %d, %d, %d", c.in, a, b, d, c.major, c.minor, c.build)
		}
	}
}

func TestKindOf(t *testing.T) {
	for _, c := range []struct {
		ee       int
		rds, gcs bool
		forced   string
		want     Kind
	}{
		{3, false, false, "", KindServer},
		{3, false, false, "auto", KindServer},
		{2, true, false, "auto", KindRDS},
		{5, false, false, "auto", KindAzureDB},
		{8, false, false, "", KindAzureMI},
		{5, true, false, "", KindAzureDB},
		{3, true, false, "onprem", KindServer},
		{3, false, false, "rds", KindRDS},
		{3, false, false, "azuresqlmi", KindAzureMI},
		{3, false, false, "azuresqldb", KindAzureDB},
		// Cloud SQL (CLOUDSQL C2): its role or procedures, after RDS's database; the configuration's word over both
		{4, false, true, "", KindCloudSQL},
		{2, false, true, "auto", KindCloudSQL},
		{3, true, true, "", KindRDS},
		{3, false, false, "cloudsql", KindCloudSQL},
		{4, false, true, "onprem", KindServer},
	} {
		if got := kindOf(c.ee, c.rds, c.gcs, c.forced); got != c.want {
			t.Errorf("kindOf(%d, rds %v, cloudsql %v, %q) = %s; want %s", c.ee, c.rds, c.gcs, c.forced, got, c.want)
		}
	}
}

func TestWithAppName(t *testing.T) {
	for in, want := range map[string]string{
		"sqlserver://u@h:1433?database=master":            "sqlserver://u@h:1433?database=master&app+name=pgvigil",
		"sqlserver://u@h:1433":                            "sqlserver://u@h:1433?app+name=pgvigil",
		"server=h;user id=u;database=master;":             "server=h;user id=u;database=master;app name=pgvigil",
		"server=h;user id=u;app name=mine":                "server=h;user id=u;app name=mine",
		"sqlserver://u@h?database=master&app+name=theirs": "sqlserver://u@h?database=master&app+name=theirs",
		"odbc:server=h;user id=u":                         "odbc:server=h;user id=u",
	} {
		if got := withAppName(in); got != want {
			t.Errorf("withAppName(%q) = %q; want %q", in, got, want)
		}
	}
}

func TestEveryCollectionIsPrefixed(t *testing.T) {
	if len(Names()) == 0 {
		t.Fatal("no SQL Server collection is registered")
	}
	for _, n := range Names() {
		if !strings.HasPrefix(n, Prefix) {
			t.Errorf("collection %q does not start with %q", n, Prefix)
		}
	}
}

// the settings every collector session starts with; proof-mssql-base.sh's part F names this test
func TestSessionSetup(t *testing.T) {
	for _, want := range []string{"SET LOCK_TIMEOUT 2000", "SET DEADLOCK_PRIORITY LOW", "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED"} {
		if !strings.Contains(sessionSetup, want) {
			t.Errorf("the session setup lacks %q", want)
		}
	}
}

// The contract of QueryRows, value by value: what the driver hands over for a column type and what a collector
// gets. A handle or a GUID that went through string() is not valid UTF-8 and is destroyed by the JSON payload.
func TestRowValue(t *testing.T) {
	guid := []byte{0xFF, 0x19, 0x96, 0x6F, 0x86, 0x8B, 0x11, 0xD0, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF}
	local := time.Date(2026, 11, 10, 7, 0, 0, 123456700, time.UTC) // the driver marks a zone-less time UTC
	offset := time.Date(2026, 11, 10, 7, 0, 0, 0, time.FixedZone("", -8*3600))
	for _, c := range []struct {
		dbType string
		in     any
		want   any
	}{
		{"DECIMAL", []byte("12.345"), "12.345"},
		{"NUMERIC", []byte("-0.5"), "-0.5"},
		{"MONEY", []byte("1.5000"), "1.5000"},
		{"SMALLMONEY", []byte("2.2500"), "2.2500"},
		{"UNIQUEIDENTIFIER", guid, "6F9619FF-8B86-D011-B42D-00C04FC964FF"},
		{"UNIQUEIDENTIFIER", []byte{1, 2}, "0x0102"},
		{"VARBINARY", []byte{0x02, 0x00, 0x00, 0x00, 0x46, 0xF2, 0xC1, 0xA3, 0xFF, 0x00}, "0x0200000046F2C1A3FF00"},
		{"BINARY", []byte{0xAB, 0xCD}, "0xABCD"},
		{"IMAGE", []byte{0x00}, "0x00"},
		{"TIMESTAMP", []byte{0, 0, 0, 0, 0, 0, 0x07, 0xD1}, "0x00000000000007D1"},
		{"VARBINARY", []byte{}, "0x"},
		{"UDT", []byte("abc"), "0x616263"},
		{"DATETIME", local, "2026-11-10T07:00:00.1234567"},
		{"DATETIME2", time.Date(2026, 11, 10, 7, 0, 0, 0, time.UTC), "2026-11-10T07:00:00"},
		{"SMALLDATETIME", time.Date(2026, 11, 10, 7, 1, 0, 0, time.UTC), "2026-11-10T07:01:00"},
		{"DATE", time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC), "2026-11-10"},
		{"TIME", time.Date(1, 1, 1, 7, 0, 0, 500000000, time.UTC), "07:00:00.5"},
		{"DATETIMEOFFSET", offset, time.Date(2026, 11, 10, 15, 0, 0, 0, time.UTC)},
		{"NVARCHAR", "text", "text"},
		{"BIGINT", int64(7), int64(7)},
		{"BIT", true, true},
		{"INT", nil, nil},
	} {
		got := rowValue(c.dbType, c.in)
		if wt, ok := c.want.(time.Time); ok {
			gt, isTime := got.(time.Time)
			if !isTime || !gt.Equal(wt) || gt.Location() != time.UTC {
				t.Errorf("rowValue(%s, %v) = %v; want %v in UTC", c.dbType, c.in, got, wt)
			}
			continue
		}
		if got != c.want {
			t.Errorf("rowValue(%s, %v) = %#v; want %#v", c.dbType, c.in, got, c.want)
		}
		if _, err := json.Marshal(got); err != nil {
			t.Errorf("rowValue(%s): the value does not marshal: %v", c.dbType, err)
		}
	}
}

func TestSupported(t *testing.T) {
	for ee, want := range map[int]bool{2: true, 3: true, 4: true, 5: true, 8: true, 9: true, 6: false, 11: false} {
		err := supported(ee)
		if (err == nil) != want {
			t.Errorf("supported(%d) = %v; want supported = %v", ee, err, want)
		}
		if err != nil && !strings.Contains(err.Error(), "Synapse") {
			t.Errorf("supported(%d): the refusal does not name Synapse: %v", ee, err)
		}
	}
}

// The same contract against a real server: set PGVIGIL_MSSQL_TEST_DSN (a go-mssqldb connection string for any
// login; nothing is written). proof-mssql-base.sh runs it as the monitoring login.
func TestQueryRowsLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_MSSQL_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_DSN is not set")
	}
	t.Setenv("PGVIGIL_MSSQL_TEST_DSN_RESOLVED", dsn)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, conn, err := Connect(ctx, config.Instance{Name: "live", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_MSSQL_TEST_DSN_RESOLVED"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	rows, err := QueryRows(ctx, conn, `SELECT
  CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS g,
  CAST(0x0200000046F2C1A3FF00 AS varbinary(64)) AS vb,
  CAST(0xABCD AS binary(2)) AS b,
  CAST(0x00000000000007D1 AS rowversion) AS rv,
  CAST(12.345 AS decimal(9,3)) AS d,
  CAST(1.5 AS money) AS m,
  CAST('2026-11-10 07:00:00' AS datetime) AS dt,
  CAST('2026-11-10 07:00:00.1234567' AS datetime2) AS dt2,
  CAST('2026-11-10 07:01:00' AS smalldatetime) AS sdt,
  CAST('2026-11-10' AS date) AS da,
  CAST('07:00:00.5' AS time) AS ti,
  CAST('2026-11-10 07:00:00 -08:00' AS datetimeoffset) AS dto,
  CAST(N'text' AS nvarchar(10)) AS s,
  CAST('<a/>' AS xml) AS x,
  CAST(7 AS bigint) AS n,
  CAST(1 AS bit) AS bt,
  CAST(NULL AS varbinary(8)) AS nul,
  (SELECT TOP (1) sql_handle FROM sys.dm_exec_requests WHERE session_id = @@SPID) AS h`)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("%d rows", len(rows))
	}
	r := rows[0]
	for col, want := range map[string]any{
		"g": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "vb": "0x0200000046F2C1A3FF00", "b": "0xABCD", "rv": "0x00000000000007D1",
		"d": "12.345", "m": "1.5000", "dt": "2026-11-10T07:00:00", "dt2": "2026-11-10T07:00:00.1234567",
		"sdt": "2026-11-10T07:01:00", "da": "2026-11-10", "ti": "07:00:00.5", "s": "text", "x": "<a/>", "n": int64(7), "bt": true, "nul": nil,
	} {
		if r[col] != want {
			t.Errorf("%s = %#v; want %#v", col, r[col], want)
		}
	}
	if dto, ok := r["dto"].(time.Time); !ok || !dto.Equal(time.Date(2026, 11, 10, 15, 0, 0, 0, time.UTC)) || dto.Location() != time.UTC {
		t.Errorf("dto = %#v; want 2026-11-10 15:00 UTC", r["dto"])
	}
	// a handle is NULL for a login without VIEW SERVER STATE; when it is there it is 0x and hex
	if h, ok := r["h"].(string); r["h"] != nil && (!ok || !strings.HasPrefix(h, "0x") || len(h) < 10) {
		t.Errorf("h = %#v; want a 0x handle", r["h"])
	}
	if _, err := json.Marshal(rows); err != nil {
		t.Fatal(err)
	}
	var one sql.NullString
	if err := conn.QueryRowContext(ctx, "SELECT CAST(1 AS varchar(1))").Scan(&one); err != nil || one.String != "1" {
		t.Errorf("the connection after the read: %v %q", err, one.String)
	}
}

type slowCollector struct{ instanceCollector }

func (slowCollector) Timeout() time.Duration { return 5 * time.Minute }

func TestRunTimeout(t *testing.T) {
	if got := runTimeout(instanceCollector{}); got != RunTimeout {
		t.Errorf("a collector without a timeout of its own: %v", got)
	}
	if got := runTimeout(slowCollector{}); got != 5*time.Minute {
		t.Errorf("a Timeouter: %v", got)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	<-ctx.Done()
	if err := timeoutNote(ctx, time.Minute, context.DeadlineExceeded); !strings.Contains(err.Error(), "hit its 60 s timeout") {
		t.Errorf("the deadline's note: %v", err)
	}
	if err := timeoutNote(context.Background(), time.Minute, sql.ErrNoRows); err != sql.ErrNoRows {
		t.Errorf("another error was rewritten: %v", err)
	}
}
