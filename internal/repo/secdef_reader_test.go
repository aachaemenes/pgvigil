package repo

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestReaderRunsNoOtherSecurityDefiner (REPORT ROLE, the design pass's S7): apply_roles grants every pgvigil function
// outside its lists to pgvigil_reader, and a custom report on the store runs as a login IN ROLE pgvigil_reader alone -
// so a SECURITY DEFINER function the reader may run reads as the owner on any report's behalf. Only these may be one:
// admin_inventory and admin_inventory_generation (the page instances' rows, dsn_ref paths and no secret: 0122, 0131)
// and alert_log_partition (it checks session_user and writes, so a read-only report gets nothing from it: 0059). A new
// one fails here until it is read and listed with its reason. Needs a migrated repository: PGVIGIL_REPO_TEST_DSN.
func TestReaderRunsNoOtherSecurityDefiner(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	allowed := map[string]bool{"admin_inventory": true, "admin_inventory_generation": true, "alert_log_partition": true}
	rows, err := conn.Query(ctx, `SELECT p.oid::regprocedure::text, p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	  WHERE n.nspname = 'pgvigil' AND p.prosecdef AND has_function_privilege('pgvigil_reader', p.oid, 'EXECUTE') ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	var bad, seen []string
	for rows.Next() {
		var sig, name string
		if err := rows.Scan(&sig, &name); err != nil {
			t.Fatal(err)
		}
		seen = append(seen, sig)
		if !allowed[name] {
			bad = append(bad, sig)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(bad) > 0 {
		t.Errorf("pgvigil_reader may run SECURITY DEFINER functions outside the list: %s (every one it may run: %s)", strings.Join(bad, ", "), strings.Join(seen, ", "))
	}
}
