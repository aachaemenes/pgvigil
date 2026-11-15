package mssqlread

import (
	"math"
	"strings"
	"testing"
	"time"
)

func TestQuoteAndName(t *testing.T) {
	if got := QuoteProc("Utility.dbo.check_jobs"); got != "[Utility].[dbo].[check_jobs]" {
		t.Errorf("QuoteProc: %s", got)
	}
	if got := QuoteName("a]b"); got != "[a]]b]" {
		t.Errorf("QuoteName doubles a bracket: %s", got)
	}
	for name, ok := range map[string]bool{"p": true, "dbo.p": true, "db.dbo.p$1#": true, "_x": true, "1p": false, "a.b.c.d": false, "[dbo].p": false, "a b": false, "a;b": false, "a'b": false, "": false} {
		if ProcName.MatchString(name) != ok {
			t.Errorf("ProcName %q: %v", name, !ok)
		}
	}
}

func TestCellAndNumber(t *testing.T) {
	ts := time.Date(2026, 11, 15, 12, 30, 1, 500000000, time.FixedZone("x", -8*3600))
	for _, c := range []struct {
		v    any
		typ  string
		want any
	}{
		{int64(5), "INT", int64(5)},
		{int64(1 << 60), "BIGINT", "1152921504606846976"},
		{[]byte("12.345"), "DECIMAL", 12.345},
		{[]byte("1234567890123456.78"), "DECIMAL", "1234567890123456.78"},
		{math.NaN(), "FLOAT", "NaN"},
		{ts, "DATETIMEOFFSET", "2026-11-15T20:30:01.5Z"},
		{ts, "DATETIME2", "2026-11-15 12:30:01.5"},
		{ts, "DATE", "2026-11-15"},
		{[]byte{0xde, 0xad}, "VARBINARY", "0xDEAD"},
		{nil, "INT", nil},
		{"text", "NVARCHAR", "text"},
	} {
		if got := Cell(c.v, c.typ); got != c.want {
			t.Errorf("Cell(%v, %s) = %#v, want %#v", c.v, c.typ, got, c.want)
		}
	}
	for _, c := range []struct {
		v    any
		typ  string
		want float64
		ok   bool
		err  bool
	}{
		{int64(7), "INT", 7, true, false},
		{float64(1.5), "FLOAT", 1.5, true, false},
		{float32(2.5), "REAL", 2.5, true, false},
		{true, "BIT", 1, true, false},
		{false, "BIT", 0, true, false},
		{[]byte(" 12.50 "), "MONEY", 12.5, true, false},
		{"3.25", "NUMERIC", 3.25, true, false},
		{nil, "INT", 0, false, false},
		{"abc", "NVARCHAR", 0, false, true},
		{[]byte{1}, "VARBINARY", 0, false, true},
		{math.Inf(1), "FLOAT", 0, false, true},
		{time.Now(), "DATETIME", 0, false, true},
	} {
		f, ok, err := Number(c.v, c.typ)
		if f != c.want || ok != c.ok || (err != nil) != c.err {
			t.Errorf("Number(%v, %s) = %v %v %v", c.v, c.typ, f, ok, err)
		}
	}
	if _, _, err := Number("abc", "NVARCHAR"); err == nil || !strings.Contains(err.Error(), "nvarchar column is not a number") {
		t.Errorf("the words of a text value column: %v", err)
	}
}

// the allowlists: exactly the documented login's rows (read on 2022 16.0.4295.3); a write or an admin right never
func TestAllowlists(t *testing.T) {
	want := []string{"ALTER TRACE", "CONNECT ANY DATABASE", "CONNECT SQL", "VIEW ANY DATABASE", "VIEW ANY DEFINITION", "VIEW ANY PERFORMANCE DEFINITION",
		"VIEW ANY SECURITY DEFINITION", "VIEW SERVER PERFORMANCE STATE", "VIEW SERVER SECURITY STATE", "VIEW SERVER STATE"}
	if len(ServerAllowed) != len(want) {
		t.Errorf("ServerAllowed holds %d rows, want %d", len(ServerAllowed), len(want))
	}
	for _, p := range want {
		if !ServerAllowed[p] {
			t.Errorf("ServerAllowed lacks %s", p)
		}
	}
	for _, p := range []string{"CONTROL SERVER", "ALTER ANY CONNECTION", "ALTER ANY AVAILABILITY GROUP", "ALTER ANY SERVER AUDIT", "ADMINISTER BULK OPERATIONS", "ALTER SERVER STATE", "IMPERSONATE ANY LOGIN", "role sysadmin", "IMPERSONATE on login sa"} {
		if ServerAllowed[p] {
			t.Errorf("ServerAllowed takes %s", p)
		}
	}
	for p, ok := range map[string]bool{"CONNECT": true, "SELECT": true, "EXECUTE": true, "SHOWPLAN": true, "REFERENCES": true, "VIEW DATABASE STATE": true, "VIEW DEFINITION": true,
		"INSERT": false, "UPDATE": false, "DELETE": false, "ALTER": false, "CONTROL": false, "CREATE TABLE": false, "BACKUP DATABASE": false, "TAKE OWNERSHIP": false,
		"KILL DATABASE CONNECTION": false, "IMPERSONATE on user dbo": false, "ALTER ANY SCHEMA": false, "VIEWER": false} {
		if DatabaseAllowed(p) != ok {
			t.Errorf("DatabaseAllowed(%q) = %v", p, !ok)
		}
	}
}
