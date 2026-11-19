package main

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/web"
)

// TestCheckSignInWarnPGAUTH (PGAUTH M1, decision 2 = WARN): an instance whose connection test answered with the
// sign-in guard's words is its OK line and a WARN line with those words - so 'pgvigil check' exits 3 - and nothing
// is refused.
func TestCheckSignInWarnPGAUTH(t *testing.T) {
	warn := "the server signs this login in by ldap, which has pgvigil send the password in clear inside the session, and sslmode=prefer checks no server certificate"
	rows := instanceCheckRows("dir1", web.CheckResult{OK: true, Detail: "connected: PostgreSQL 16.4, as pgvigil", Warn: warn}, "")
	if !rowWith(rows, "OK", "instance dir1", "connected: PostgreSQL 16.4") || !rowWith(rows, "WARN", "instance dir1", "by ldap") {
		t.Errorf("rows:\n%s", rowsText(rows))
	}
	if rows := instanceCheckRows("db2", web.CheckResult{OK: true, Detail: "connected"}, ""); len(rows) != 1 || rows[0].Level != "OK" {
		t.Errorf("no sign-in warning: rows\n%s", rowsText(rows))
	}
	if rows := instanceCheckRows("db3", web.CheckResult{Detail: "connection refused"}, ""); len(rows) != 1 || rows[0].Level != "FAIL" {
		t.Errorf("a failed test: rows\n%s", rowsText(rows))
	}
}
