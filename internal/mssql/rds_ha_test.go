package mssql

import (
	"errors"
	"strings"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The answers R1 recorded on a real Amazon RDS for SQL Server 2019 Standard instance, single AZ (2026-11-14, part S
// of scripts/proof-mssql-rds.sh): S1 the master user's EXEC msdb.dbo.rds_get_high_availability_option answered one
// column high_availability = 'Single-AZ', and msdb.dbo.rds_failover_time refused the instance with Msg 50000; S2 the
// collector's login was refused EXECUTE on both (Msg 229); S3 the master user may grant it. The Multi-AZ cases follow
// AWS's page (Appendix.SQLServer.CommonDBATasks.LastFailover): errorlog_available_from and recent_failover_time, null
// when no failover is in the error logs - NOT PROVEN on a live instance (R2, Multi-AZ, not approved).

var (
	r1Denied229 = mssqldb.Error{Number: 229, Class: 14, Message: "The EXECUTE permission was denied on the object 'rds_get_high_availability_option', database 'msdb', schema 'dbo'."}
	r1FoDenied  = mssqldb.Error{Number: 229, Class: 14, Message: "The EXECUTE permission was denied on the object 'rds_failover_time', database 'msdb', schema 'dbo'."}
	r1SingleAZ  = []collect.Row{{"high_availability": "Single-AZ"}}
)

func rdsHAByName(t *testing.T, rows []collect.Row) map[string]collect.Row {
	t.Helper()
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

func TestRDSHASingleAZ(t *testing.T) {
	p := &propList{}
	partial := rdsHAProps(p, rdsHAAnswer{ha: r1SingleAZ})
	if len(partial) != 0 {
		t.Fatalf("a Single-AZ answer is a full read, got %v", partial)
	}
	by := rdsHAByName(t, p.rows)
	ha, fo := by["rds_high_availability"], by["rds_last_failover"]
	if ha == nil || fo == nil {
		t.Fatalf("want the two rows, got %v", p.rows)
	}
	if ha["value"] != "Single-AZ" || ha["grp"] != "Server" || ha["track"] != true {
		t.Errorf("the mode row: %v", ha)
	}
	if fo["value"] != nil || !strings.Contains(noteOf(fo), "a Single-AZ instance has no failover") || fo["track"] != false {
		t.Errorf("the failover row on Single-AZ: %v", fo)
	}
}

// R1 S2: the documented login without the grant: no value, the GRANT line in words, and the run NOT partial (the
// right is optional; R1's login lacked it and mssql_properties ended ok).
func TestRDSHANotGranted(t *testing.T) {
	p := &propList{}
	partial := rdsHAProps(p, rdsHAAnswer{haErr: r1Denied229, login: "pgv]monitor"})
	if len(partial) != 0 {
		t.Fatalf("a refused grant is not a partial run, got %v", partial)
	}
	by := rdsHAByName(t, p.rows)
	ha, fo := by["rds_high_availability"], by["rds_last_failover"]
	if ha["value"] != nil || noteOf(ha) != "not granted: GRANT EXECUTE ON msdb.dbo.rds_get_high_availability_option TO [pgv]]monitor]; (the master user may grant it)" {
		t.Errorf("the refused mode row: %v", ha)
	}
	if fo["value"] != nil || !strings.Contains(noteOf(fo), "the high availability mode was not read") {
		t.Errorf("the failover row without the mode: %v", fo)
	}
	// no login name read: the line still says what to grant
	p = &propList{}
	rdsHAProps(p, rdsHAAnswer{haErr: r1Denied229})
	if n := noteOf(rdsHAByName(t, p.rows)["rds_high_availability"]); !strings.Contains(n, "TO [<the monitoring login>];") {
		t.Errorf("without the login's name: %q", n)
	}
}

func TestRDSHAOtherError(t *testing.T) {
	p := &propList{}
	partial := rdsHAProps(p, rdsHAAnswer{haErr: errors.New("could not find stored procedure")})
	if len(partial) != 1 || partial[0]["kind"] != "collector_error" || partial[0]["source"] != "msdb.dbo.rds_get_high_availability_option" {
		t.Fatalf("an unexpected error is a partial run: %v", partial)
	}
	if n := noteOf(rdsHAByName(t, p.rows)["rds_high_availability"]); n != "not read: could not find stored procedure" {
		t.Errorf("the note: %q", n)
	}
	// no row at all is not a mode either
	p = &propList{}
	if partial := rdsHAProps(p, rdsHAAnswer{}); len(partial) != 1 {
		t.Errorf("an empty answer: %v", partial)
	}
}

// AWS's documented shapes (NOT PROVEN live: R2 not approved).
func TestRDSHAMultiAZ(t *testing.T) {
	from := time.Date(2020, 4, 29, 23, 59, 0, 10_000_000, time.UTC)
	at := time.Date(2020, 5, 5, 18, 57, 51, 890_000_000, time.UTC)
	p := &propList{}
	partial := rdsHAProps(p, rdsHAAnswer{ha: []collect.Row{{"high_availability": "Multi-AZ (AlwaysOn)"}}, foAsked: true,
		fo: []collect.Row{{"errorlog_available_from": from, "recent_failover_time": at}}})
	by := rdsHAByName(t, p.rows)
	if len(partial) != 0 || by["rds_high_availability"]["value"] != "Multi-AZ (AlwaysOn)" || by["rds_last_failover"]["value"] != "2020-05-05 18:57:51" {
		t.Errorf("a recent failover: %v %v", by, partial)
	}
	p = &propList{}
	rdsHAProps(p, rdsHAAnswer{ha: []collect.Row{{"high_availability": "Multi-AZ (Mirroring)"}}, foAsked: true,
		fo: []collect.Row{{"errorlog_available_from": from, "recent_failover_time": nil}}})
	fo := rdsHAByName(t, p.rows)["rds_last_failover"]
	if fo["value"] != nil || noteOf(fo) != "none in the error logs since 2020-04-29 23:59:00 (the server's clock)" {
		t.Errorf("no failover in the logs: %v", fo)
	}
	p = &propList{}
	partial = rdsHAProps(p, rdsHAAnswer{ha: []collect.Row{{"high_availability": "Multi-AZ (AlwaysOn)"}}, foAsked: true, foErr: r1FoDenied, login: "pgv"})
	if n := noteOf(rdsHAByName(t, p.rows)["rds_last_failover"]); len(partial) != 0 || n != "not granted: GRANT EXECUTE ON msdb.dbo.rds_failover_time TO [pgv]; (the master user may grant it)" {
		t.Errorf("the failover refused: %q %v", n, partial)
	}
}

// rdsHAAsksFailover: the failover procedure is asked only when the mode was read and is not Single-AZ (R1: Msg 50000
// 'This procedure can only be used on Multi-AZ RDS Instance.' on a single-AZ instance).
func TestRDSHAAsksFailover(t *testing.T) {
	for _, c := range []struct {
		rows []collect.Row
		err  error
		want bool
	}{
		{r1SingleAZ, nil, false},
		{[]collect.Row{{"high_availability": "single-az"}}, nil, false},
		{[]collect.Row{{"high_availability": "Multi-AZ (Block level replication)"}}, nil, true},
		{nil, r1Denied229, false},
		{nil, nil, false},
	} {
		if got := rdsHAAsksFailover(c.rows, c.err); got != c.want {
			t.Errorf("%v %v: %v, want %v", c.rows, c.err, got, c.want)
		}
	}
}
