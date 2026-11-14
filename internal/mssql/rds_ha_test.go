package mssql

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// The answers a real Amazon RDS for SQL Server 2019 Standard instance in a single AZ gave (scripts/proof-mssql-rds.sh,
// part S, 2026-11-14): the master user's EXEC msdb.dbo.rds_get_high_availability_option answered one column
// high_availability = 'Single-AZ', and msdb.dbo.rds_failover_time refused the instance with Msg 50000; the monitoring
// login was refused EXECUTE on both (Msg 229) and the master user may grant it. The Multi-AZ cases follow AWS's page
// (errorlog_available_from and recent_failover_time, null when no failover is in the error logs) and are not proven on
// a Multi-AZ instance. QueryRows hands datetime / datetime2 over as zone-less text: the cases feed that form.

var (
	haDenied = mssqldb.Error{Number: 229, Class: 14, Message: "The EXECUTE permission was denied on the object 'rds_get_high_availability_option', database 'msdb', schema 'dbo'."}
	foDenied = mssqldb.Error{Number: 229, Class: 14, Message: "The EXECUTE permission was denied on the object 'rds_failover_time', database 'msdb', schema 'dbo'."}
	// a permission error from inside the procedure (not its EXECUTE): shown, never 'not granted'
	innerDenied = mssqldb.Error{Number: 229, Class: 14, Message: "The SELECT permission was denied on the object 'some_table', database 'rdsadmin', schema 'dbo'."}
	singleAZ    = []collect.Row{{"high_availability": "Single-AZ"}}
	multiAZ     = []collect.Row{{"high_availability": "Multi-AZ (AlwaysOn)"}}
	foSingleAZ  = mssqldb.Error{Number: 50000, Class: 16, Message: "This procedure can only be used on Multi-AZ RDS Instance."}
)

func rdsHAByName(rows []collect.Row) map[string]collect.Row {
	out := map[string]collect.Row{}
	for _, r := range rows {
		if r["kind"] == "property" {
			out[r["name"].(string)] = r
		}
	}
	return out
}

func noteOf(r collect.Row) string {
	if s, ok := r["note"].(string); ok {
		return s
	}
	return ""
}

// run builds the rows of one answer: the mode row, the failover row and the partial rows.
func rdsRun(a rdsHAAnswer) (collect.Row, collect.Row, []collect.Row) {
	p := &propList{}
	partial := rdsHAProps(p, a)
	by := rdsHAByName(p.rows)
	return by["rds_high_availability"], by["rds_last_failover"], partial
}

func TestRDSHASingleAZ(t *testing.T) {
	ha, fo, partial := rdsRun(rdsHAAnswer{ha: singleAZ})
	if len(partial) != 0 {
		t.Fatalf("a Single-AZ answer is a full read, got %v", partial)
	}
	if ha["value"] != "Single-AZ" || ha["grp"] != "Server" || ha["track"] != true || ha["ord"] != 155 {
		t.Errorf("the mode row: %v", ha)
	}
	// a real answer of none carries the value 'none' (the page counts a missing value as not read; the store keeps the
	// last value read over a missing one)
	if fo["value"] != "none" || !strings.Contains(noteOf(fo), "a Single-AZ instance has no failover") || fo["track"] != false || fo["ord"] != 156 {
		t.Errorf("the failover row on Single-AZ: %v", fo)
	}
}

// Without the grant: no value, both GRANT lines in msdb to the login's user there, and the run NOT partial (the right
// is optional; the documented login lacks it and mssql_properties stays ok).
func TestRDSHANotGranted(t *testing.T) {
	ha, fo, partial := rdsRun(rdsHAAnswer{haErr: haDenied, user: "pgv]user"})
	if len(partial) != 0 {
		t.Fatalf("a refused grant is not a partial run, got %v", partial)
	}
	want := "not granted: USE msdb; GRANT EXECUTE ON dbo.rds_get_high_availability_option TO [pgv]]user]; GRANT EXECUTE ON dbo.rds_failover_time TO [pgv]]user]; (the master user may grant them; the second is for the last failover on a Multi-AZ instance)"
	if ha["value"] != nil || noteOf(ha) != want {
		t.Errorf("the refused mode row: %q", noteOf(ha))
	}
	if fo["value"] != nil || !strings.Contains(noteOf(fo), "the row above names the GRANT lines") {
		t.Errorf("the failover row without the mode: %v", fo)
	}
	// the user's name not read: the line still says what to grant
	ha, _, _ = rdsRun(rdsHAAnswer{haErr: haDenied})
	if !strings.Contains(noteOf(ha), "TO [<the monitoring login's user in msdb>];") {
		t.Errorf("without the user's name: %q", noteOf(ha))
	}
}

func TestRDSHAOtherErrors(t *testing.T) {
	for _, c := range []struct {
		name string
		a    rdsHAAnswer
		note string
	}{
		{"a driver error", rdsHAAnswer{haErr: errors.New("could not find stored procedure")}, "not read: could not find stored procedure"},
		{"a permission error inside the procedure", rdsHAAnswer{haErr: innerDenied}, "not read: The SELECT permission was denied on the object 'some_table', database 'rdsadmin', schema 'dbo'."},
		{"no row", rdsHAAnswer{}, "not read: the procedure returned no mode"},
		{"two columns, none named high_availability", rdsHAAnswer{ha: []collect.Row{{"a": "x", "b": "y"}}}, "not read: the procedure returned no mode"},
	} {
		ha, fo, partial := rdsRun(c.a)
		if len(partial) != 1 || partial[0]["kind"] != "collector_error" || partial[0]["source"] != "msdb.dbo.rds_get_high_availability_option" ||
			partial[0]["message"] != strings.TrimPrefix(c.note, "not read: ") {
			t.Errorf("%s: an unexpected answer is a partial run naming it: %v", c.name, partial)
		}
		if ha["value"] != nil || noteOf(ha) != c.note || fo["value"] != nil || noteOf(fo) != "not read: the high availability mode was not read" {
			t.Errorf("%s: %q / %q", c.name, noteOf(ha), noteOf(fo))
		}
	}
	// the mode under another column name, alone in its row
	if ha, _, partial := rdsRun(rdsHAAnswer{ha: []collect.Row{{"option": "Single-AZ"}}}); ha["value"] != "Single-AZ" || len(partial) != 0 {
		t.Errorf("one column under another name: %v %v", ha, partial)
	}
}

// AWS's documented Multi-AZ shapes (not proven on a Multi-AZ instance), times as QueryRows gives them.
func TestRDSHAMultiAZ(t *testing.T) {
	for _, c := range []struct {
		name    string
		a       rdsHAAnswer
		value   any
		note    string
		partial bool
	}{
		{"a recent failover", rdsHAAnswer{ha: multiAZ, foAsked: true, fo: []collect.Row{{"errorlog_available_from": "2020-04-29T23:59:00.01", "recent_failover_time": "2020-05-05T18:57:51.89"}}},
			"2020-05-05 18:57:51", "the most recent failover in the error logs (as the procedure returns it; AWS names no time zone)", false},
		{"none in the logs", rdsHAAnswer{ha: multiAZ, foAsked: true, fo: []collect.Row{{"errorlog_available_from": "2020-04-29T23:59:00.01", "recent_failover_time": nil}}},
			"none", "no failover in the error logs since 2020-04-29 23:59:00 (as the procedure returns it; AWS names no time zone)", false},
		{"a datetimeoffset", rdsHAAnswer{ha: multiAZ, foAsked: true, fo: []collect.Row{{"errorlog_available_from": nil, "recent_failover_time": time.Date(2020, 5, 5, 18, 57, 51, 0, time.UTC)}}},
			"2020-05-05 18:57:51 UTC", "the most recent failover in the error logs (as the procedure returns it; AWS names no time zone)", false},
		{"the failover refused", rdsHAAnswer{ha: multiAZ, foAsked: true, foErr: foDenied, user: "pgv"},
			nil, "not granted: USE msdb; GRANT EXECUTE ON dbo.rds_failover_time TO [pgv]; (the master user may grant it)", false},
		{"refused by the procedure (Msg 50000)", rdsHAAnswer{ha: []collect.Row{{"high_availability": "Multi-AZ (Block level replication)"}}, foAsked: true, foErr: foSingleAZ},
			nil, "refused by the procedure: This procedure can only be used on Multi-AZ RDS Instance.", false},
		{"another error", rdsHAAnswer{ha: multiAZ, foAsked: true, foErr: errors.New("timeout")},
			nil, "not read: timeout", true},
		{"no row", rdsHAAnswer{ha: multiAZ, foAsked: true},
			nil, "not read: the procedure returned no row", true},
		{"a column missing", rdsHAAnswer{ha: multiAZ, foAsked: true, fo: []collect.Row{{"last_failover": "2020-05-05T18:57:51.89"}}},
			nil, "not read: the answer lacks recent_failover_time or errorlog_available_from (columns: last_failover)", true},
		{"not asked", rdsHAAnswer{ha: multiAZ},
			nil, "not read: the failover time was not asked", false},
	} {
		ha, fo, partial := rdsRun(c.a)
		if fo["value"] != c.value || noteOf(fo) != c.note || fo["track"] != false {
			t.Errorf("%s: value %v note %q track %v", c.name, fo["value"], noteOf(fo), fo["track"])
		}
		if (len(partial) == 1) != c.partial || (c.partial && partial[0]["source"] != "msdb.dbo.rds_failover_time") || len(partial) > 1 {
			t.Errorf("%s: partial %v", c.name, partial)
		}
		if ha["value"] == nil {
			t.Errorf("%s: the mode row lost its value", c.name)
		}
	}
}

// rdsHAAsksFailover: the failover procedure is asked only when the mode was read and is not Single-AZ (a single-AZ
// instance refuses it with Msg 50000).
func TestRDSHAAsksFailover(t *testing.T) {
	for _, c := range []struct {
		rows []collect.Row
		err  error
		want bool
	}{
		{singleAZ, nil, false},
		{[]collect.Row{{"high_availability": "single-az"}}, nil, false},
		{[]collect.Row{{"high_availability": "Multi-AZ (Block level replication)"}}, nil, true},
		{nil, haDenied, false},
		{nil, nil, false},
	} {
		if got := rdsHAAsksFailover(c.rows, c.err); got != c.want {
			t.Errorf("%v %v: %v, want %v", c.rows, c.err, got, c.want)
		}
	}
}

// TestRDSHALive runs readRDSHA through a real connection against stubs of RDS's two procedures, so the driver's
// errors and QueryRows' types are the ones the collector sees. PGVIGIL_MSSQL_TEST_RDSHA_SA is a sysadmin connection
// string to a THROWAWAY SQL Server (a container): the test creates msdb.dbo.rds_get_high_availability_option and
// msdb.dbo.rds_failover_time, a login and its msdb user under another name, and drops them all. It refuses a server
// that has the database rdsadmin (a real RDS instance).
func TestRDSHALive(t *testing.T) {
	saDSN := os.Getenv("PGVIGIL_MSSQL_TEST_RDSHA_SA")
	if saDSN == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_RDSHA_SA is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	t.Setenv("PGVIGIL_RDSHA_SA", saDSN)
	sdb, sa, err := Connect(ctx, config.Instance{Name: "sa", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_RDSHA_SA"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sa.Close(); _ = sdb.Close() }()
	exec := func(q string) {
		t.Helper()
		if _, err := sa.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	var rds int
	if err := sa.QueryRowContext(ctx, "SELECT CASE WHEN DB_ID('rdsadmin') IS NULL THEN 0 ELSE 1 END").Scan(&rds); err != nil || rds != 0 {
		t.Fatalf("not a throwaway server (rdsadmin exists: %d, %v)", rds, err)
	}
	login, user, pw := fmt.Sprintf("pgv_rdsha_%d", time.Now().UnixNano()%1e6), "pgv_rdsha_user", fmt.Sprintf("Pv9%da!x", time.Now().UnixNano())
	proc := func(name, body string) {
		exec("USE msdb; EXEC (N'CREATE OR ALTER PROCEDURE dbo." + name + " AS " + strings.ReplaceAll(body, "'", "''") + "')")
	}
	exec("CREATE LOGIN [" + login + "] WITH PASSWORD = '" + pw + "', CHECK_POLICY = OFF")
	exec("USE msdb; CREATE USER [" + user + "] FOR LOGIN [" + login + "]")
	defer func() {
		c2, cancel2 := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel2()
		for _, q := range []string{"USE msdb; DROP PROCEDURE IF EXISTS dbo." + rdsHAName + "; DROP PROCEDURE IF EXISTS dbo." + rdsFailoverName + "; DROP USER IF EXISTS [" + user + "]",
			"DECLARE @k nvarchar(max) = N''; SELECT @k += N'KILL ' + CAST(session_id AS nvarchar(9)) + N';' FROM sys.dm_exec_sessions WHERE login_name = N'" + login + "'; EXEC (@k)",
			"IF SUSER_ID('" + login + "') IS NOT NULL DROP LOGIN [" + login + "]"} {
			if _, err := sa.ExecContext(c2, q); err != nil {
				t.Errorf("cleanup %q: %v", q, err)
			}
		}
	}()
	// the shapes: RDS's single-AZ answers, then AWS's Multi-AZ ones (datetime2, as an error log's time)
	proc(rdsHAName, "SELECT CAST(N'Single-AZ' AS nvarchar(64)) AS high_availability")
	proc(rdsFailoverName, "RAISERROR(N'This procedure can only be used on Multi-AZ RDS Instance.', 16, 1)")

	u, err := url.Parse(saDSN)
	if err != nil {
		t.Fatal(err)
	}
	u.User = url.UserPassword(login, pw)
	t.Setenv("PGVIGIL_RDSHA_MON", u.String())
	read := func() (collect.Row, collect.Row, []collect.Row, rdsHAAnswer) {
		t.Helper()
		db, conn, err := Connect(ctx, config.Instance{Name: "mon", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_RDSHA_MON"})
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = conn.Close(); _ = db.Close() }()
		a := readRDSHA(ctx, conn)
		ha, fo, partial := rdsRun(a)
		return ha, fo, partial, a
	}
	check := func(name string, ha, fo collect.Row, partial []collect.Row, haValue, foValue any, haNote, foNote string) {
		t.Helper()
		if ha["value"] != haValue || noteOf(ha) != haNote || fo["value"] != foValue || noteOf(fo) != foNote || len(partial) != 0 {
			t.Errorf("%s:\n  mode %v %q\n  failover %v %q\n  partial %v", name, ha["value"], noteOf(ha), fo["value"], noteOf(fo), partial)
		}
	}

	// 1. no grant: Msg 229 naming the procedure, the user's name read from msdb (not the login's)
	ha, fo, partial, _ := read()
	grantNote := "not granted: USE msdb; GRANT EXECUTE ON dbo.rds_get_high_availability_option TO [" + user + "]; GRANT EXECUTE ON dbo.rds_failover_time TO [" + user + "]; (the master user may grant them; the second is for the last failover on a Multi-AZ instance)"
	check("not granted", ha, fo, partial, nil, nil, grantNote, "not read: the high availability mode was not granted (the row above names the GRANT lines)")
	// the printed lines are the ones that work: run them as they stand, from master
	lines := strings.TrimPrefix(noteOf(ha), "not granted: ")
	lines = lines[:strings.Index(lines, " (the master user")]
	exec(lines)

	// 2. granted, Single-AZ
	ha, fo, partial, a := read()
	check("Single-AZ", ha, fo, partial, "Single-AZ", "none", "", "a Single-AZ instance has no failover (rds_failover_time answers on Multi-AZ only)")
	if a.foAsked {
		t.Error("Single-AZ: the failover procedure was asked")
	}

	// 3. Multi-AZ with a failover in the logs
	proc(rdsHAName, "SELECT CAST(N'Multi-AZ (AlwaysOn)' AS nvarchar(64)) AS high_availability")
	proc(rdsFailoverName, "SELECT CAST('2020-04-29 23:59:00.01' AS datetime2) AS errorlog_available_from, CAST('2020-05-05 18:57:51.89' AS datetime2) AS recent_failover_time")
	ha, fo, partial, _ = read()
	check("Multi-AZ, a failover", ha, fo, partial, "Multi-AZ (AlwaysOn)", "2020-05-05 18:57:51", "", "the most recent failover in the error logs (as the procedure returns it; AWS names no time zone)")

	// 4. none in the logs
	proc(rdsFailoverName, "SELECT CAST('2020-04-29 23:59:00.01' AS datetime2) AS errorlog_available_from, CAST(NULL AS datetime2) AS recent_failover_time")
	ha, fo, partial, _ = read()
	check("Multi-AZ, none", ha, fo, partial, "Multi-AZ (AlwaysOn)", "none", "", "no failover in the error logs since 2020-04-29 23:59:00 (as the procedure returns it; AWS names no time zone)")

	// 5. the procedure refuses (Msg 50000)
	proc(rdsFailoverName, "RAISERROR(N'This procedure can only be used on Multi-AZ RDS Instance.', 16, 1)")
	ha, fo, partial, _ = read()
	check("refused by the procedure", ha, fo, partial, "Multi-AZ (AlwaysOn)", nil, "", "refused by the procedure: This procedure can only be used on Multi-AZ RDS Instance.")

	// 6. the failover procedure's grant removed
	exec("USE msdb; REVOKE EXECUTE ON dbo." + rdsFailoverName + " FROM [" + user + "]")
	ha, fo, partial, _ = read()
	check("the failover not granted", ha, fo, partial, "Multi-AZ (AlwaysOn)", nil, "", "not granted: USE msdb; GRANT EXECUTE ON dbo.rds_failover_time TO ["+user+"]; (the master user may grant it)")
}
