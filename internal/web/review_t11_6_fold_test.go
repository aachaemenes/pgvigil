package web

import (
	"os"
	"strings"
	"testing"
)

// TestReviewPart6Fold (review t11-6, 11-17 15:49 at 2afd33ee: 4 BLOCKER, 5 SHOULD, 5 NIT - folded at the tip): each
// finding's fix by its file's words; item 9 (no test imports the demo's batches) is taken by running proof-demo.sh in
// the next box job (item 2 makes it green), item 8 for the strip's page (the two database pages: named, not taken).
func TestReviewPart6Fold(t *testing.T) {
	read := func(f string) string {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	has := func(f, want, why string) {
		t.Helper()
		if !strings.Contains(read(f), want) {
			t.Errorf("%s (%s lacks %q)", why, f, want)
		}
	}
	lacks := func(f, gone, why string) {
		t.Helper()
		if strings.Contains(read(f), gone) {
			t.Errorf("%s (%s still has %q)", why, f, gone)
		}
	}
	// BLOCKER 1: the walker builds the bundle on a patched tree, and a page the router did not open fails
	has("../../scripts/parity-s3-pages.sh", "npm run build", "BLOCKER 1: no web build before go build")
	has("../../scripts/parity-s3-pages.sh", "PARITY-S3-wiring.patch", "BLOCKER 1: the patch is not applied when missing")
	has("../../scripts/parity-s3-pages.mjs", "NOT LANDED", "BLOCKER 1: a page the router sent to the Summary is not caught")
	// BLOCKERs 2-4: the 17-instance demo in the three proofs
	has("../../scripts/proof-demo.sh", "aurora 3, azure 2, azuresqldb 2, azuresqlmi 1, cloudsql 2, onprem 3, rds 2, sqlserver 2", "BLOCKER 2: proof-demo's platforms")
	has("../../scripts/proof-demo.sh", `[[ "$got" == 17 ]] || fail "api instances: $got"`, "BLOCKER 2: proof-demo's api count")
	has("../../scripts/proof-demo.sh", `grep -q "(17 replaced)"`, "BLOCKER 2: proof-demo's rerun count")
	has("../../scripts/proof-perfsummary.sh", `== 5 ]] || fail "A: mssql rows"`, "BLOCKER 3: proof-perfsummary's mssql rows")
	has("../../scripts/proof-perfsummary.sh", "azure-sqldb", "BLOCKER 3: the Azure SQL Databases' own expectations")
	has("../../scripts/proof-running-fleet.sh", "len(truth) == 17", "BLOCKER 4: proof-running-fleet's count")
	// SHOULD 5: -sql01's collection log names the collections its parity batches fill (their own names)
	has("../demo/mssql_demo.go", `"mssql_procstats", "mssql_funcstats", "mssql_plancache", "mssql_schema", "mssql_db_scoped_config", "mssql_service_broker"`, "SHOULD 5: -sql01's collection log")
	// SHOULD 6: a DML trigger's scope is empty, as the collector sends it
	lacks("../demo/mssql_parity_demo.go", `"OBJECT_OR_COLUMN"`, "SHOULD 6: the DML trigger's scope")
	// SHOULD 7: -sql01's own database (Orders, 7 as the storage demo numbers it), never -sql03's Ledger
	lacks("../demo/mssql_parity_demo.go", `"Ledger"`, "SHOULD 7: -sql01 names a database it does not have")
	// SHOULD 8 (the strip's page): its part must have drawn
	has("../../scripts/parity-s3-pages.mjs", "#perf-es-measure", "SHOULD 8: the strip's page has no marker of its own")
	// NIT 10: the duplicate page is gone
	lacks("../../scripts/parity-s3-pages.mjs", "['azuresummary-pool',", "NIT 10: azuresummary opened twice")
	// NIT 12: a free port and a bounded browser run
	has("../../scripts/parity-s3-pages.sh", "timeout ", "NIT 12: the node run has no timeout")
	has("../../scripts/parity-s3-pages.sh", "ss -ltn", "NIT 12: the port is not checked free")
	// NIT 13: the Azure SQL Databases keep the SQL-Server-only checks
	has("../demo/demo_test.go", "range specs[15:]", "NIT 13: the Azure SQL Databases lost the collection checks")
	// NIT 14: the 17-instance fleet in the texts
	lacks("../../README.md", "without a login: 15 instances", "NIT 14: README")
	lacks("../demo/seed.go", "default 15", "NIT 14: seed.go")
	lacks("../demo/mssql_demo.go", "The demo's three SQL Server instances", "NIT 14: mssql_demo.go")
}
