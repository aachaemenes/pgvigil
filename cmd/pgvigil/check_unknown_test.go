package main

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/web"
)

// TestInstanceRowsUnknownL217 (RELNOTES L217): an instance that answered is its OK row; when the server is one this
// build does not know (web.CheckResult.Unknown), a WARN row with those words follows it (so the exit is 3); a failed
// connect stays one FAIL row.
func TestInstanceRowsUnknownL217(t *testing.T) {
	rows := instanceCheckRows("pg1", web.CheckResult{OK: true, Detail: "connected: PostgreSQL 19.0, as mon", Unknown: "PostgreSQL 19 is newer than this build knows (13 to 18)"}, "")
	if len(rows) != 2 || rows[0].Level != "OK" || rows[1].Level != "WARN" || rows[1].What != "instance pg1" || rows[1].Words != "PostgreSQL 19 is newer than this build knows (13 to 18)" {
		t.Errorf("an unknown server: %+v", rows)
	}
	if rows := instanceCheckRows("pg2", web.CheckResult{OK: true, Detail: "connected: PostgreSQL 18.1, as mon"}, ""); len(rows) != 1 || rows[0].Level != "OK" {
		t.Errorf("a known server: %+v", rows)
	}
	if rows := instanceCheckRows("pg3", web.CheckResult{Detail: "connection refused", Unknown: "x"}, ""); len(rows) != 1 || rows[0].Level != "FAIL" || rows[0].Words != "connection refused" {
		t.Errorf("a failed connect: %+v", rows)
	}
	if rows := instanceCheckRows("pg4", web.CheckResult{}, "dsn resolved to an empty string"); len(rows) != 1 || rows[0].Level != "FAIL" {
		t.Errorf("an empty dsn: %+v", rows)
	}
}
