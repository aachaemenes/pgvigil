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
// and alert_log_partition (it checks session_user and writes, so a read-only report gets nothing from it: 0059), and
// mssql_hadr_cursor (the collector's door in apply_roles, 0110; the reader holds EXECUTE too - apply_roles' collector
// branch takes no reader grant back - and it answers one bigint position, STABLE, no write, from mssql_jobs_cursor,
// mssql_qs_store and mssql_qs_plan, tables the reader SELECTs anyway: 0083; found by reportrole-g1). A new one fails
// here until it is read and listed with its reason; the list holds signatures, so a new overload of a listed name
// (admin_inventory(text)) fails too (the code review of REPORT ROLE, part B). Needs a migrated repository:
// PGVIGIL_REPO_TEST_DSN.
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
	// read and listed at the join of REPORT ROLE with 206 and 310 (j14, 11-14): alert_contact_routes (0136) checks
	// session_user - a member of pgvigil_alerter or the schema's owner, else 'is not the alert sender' - and the report
	// login is refused when it is a member of any role but pgvigil_reader (reportrole.go storeCheckSQL), so a report
	// gets an error, never a contact's address; dbadash_import_stored and dbadash_import_target (0134) are STABLE
	// reads of counts and of instances, dbadash_moves, dbadash_move_ids and dbadash_import_wait, tables the reader
	// SELECTs anyway (apply_roles grants SELECT on every table but ui_*), made SECURITY DEFINER for the collector's
	// login, which has no SELECT
	allowed := map[string]bool{"admin_inventory()": true, "admin_inventory_generation()": true,
		"alert_log_partition(timestamp with time zone)": true, "mssql_hadr_cursor(integer, text)": true,
		"alert_contact_routes()": true,
		"dbadash_import_stored(integer, text, timestamp with time zone, timestamp with time zone)": true,
		"dbadash_import_target(jsonb)": true,
		// ST5a, 0263: a page instance's name and its own schedules and query_text, STABLE, no secret, from admin_instances,
		// which the reader SELECTs anyway; SECURITY DEFINER for the collector's login, which has no SELECT
		"admin_instance_settings()": true,
		// the Parquet export's door (0256): each raises unless session_user is a member of pgvigil_exporter, which the
		// report login is not (a member of any role but pgvigil_reader is refused: reportrole.go), so a report gets an
		// error and writes nothing
		"export_run_record(text, text, timestamp with time zone, timestamp with time zone, text, timestamp with time zone, text, integer, integer, bigint, bigint, text)": true,
		"export_off(text)": true,
		// the agent door (0268): each checks inside that the SESSION user is a member of pgvigil_agent
		// (agent_login_check: 'is not a member of pgvigil_agent'), so a report login or Grafana gets an error and nothing
		// else; apply_roles grants them to the reader until the next join file's agent branch takes that back
		// (scripts/agent-join-lines.sql), then the seven leave this list
		"agent_investigation_list(text, text, integer)": true, "agent_investigation_claim(bigint, text)": true,
		"agent_investigation_renew(bigint, text)": true, "agent_investigation_release(bigint, text, text)": true,
		"agent_investigation_report(bigint, text, text, text, text, jsonb, jsonb, text)": true,
		"agent_investigation_journal_select(bigint, text, text)":                         true,
		"agent_investigation_journal_done(bigint, bigint, integer, text)":                true}
	// the signature without the schema (oidvectortypes: argument types as format_type writes them), whatever the
	// connection's search_path
	rows, err := conn.Query(ctx, `SELECT p.proname || '(' || oidvectortypes(p.proargtypes) || ')' FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	  WHERE n.nspname = 'pgvigil' AND p.prosecdef AND has_function_privilege('pgvigil_reader', p.oid, 'EXECUTE') ORDER BY 1`)
	if err != nil {
		t.Fatal(err)
	}
	var bad, seen []string
	for rows.Next() {
		var sig string
		if err := rows.Scan(&sig); err != nil {
			t.Fatal(err)
		}
		seen = append(seen, sig)
		if !allowed[sig] {
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
