package repo

import (
	"encoding/json"
	"testing"
	"time"
)

// TestDBScopedConfigOnAStore (P25 row 2a, migration 0391: DBA Dash's database DB Configuration): on a store,
// pgvigil.import_mssql_db_scoped_config keeps each database's sys.database_scoped_configurations rows (name, value,
// value for secondaries, default or not; the values as text, the view's sql_variant), records a changed value with
// its old and new value and when the read saw it, marks a row a later read of that database no longer holds not
// present (a change with no new value), and leaves a database the read could not enter as it was - its rows kept
// present, its note stored.
func TestDBScopedConfigOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	t1, t2 := now.Add(-2*time.Hour), now.Add(-time.Hour)
	imp := func(at time.Time, rows ...map[string]any) {
		t.Helper()
		b, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.import_mssql_db_scoped_config($1, $2, $3::jsonb)`, s.id, at, string(b)); err != nil {
			t.Fatalf("import_mssql_db_scoped_config at %s: %v", at.Format(time.RFC3339), err)
		}
	}
	cfg := func(db, name string, value, secondary any, def bool) map[string]any {
		return map[string]any{"kind": "scoped_config", "database_name": db, "name": name, "value": value, "value_for_secondary": secondary, "is_value_default": def}
	}
	unread := func(db, note string) map[string]any {
		return map[string]any{"kind": "scoped_unread", "database_name": db, "note": note}
	}
	rows := func() string {
		t.Helper()
		return s.vals(`SELECT database_name, name, value, value_for_secondary, is_default, is_present, note
		                 FROM pgvigil.mssql_db_scoped_config WHERE instance_id = $1 ORDER BY database_name, name`, s.id)
	}
	imp(t1, cfg("sales", "MAXDOP", 0, nil, true), cfg("sales", "LEGACY_CARDINALITY_ESTIMATION", 0, nil, true), cfg("hr", "MAXDOP", 4, 2, false))
	if got, want := rows(), "hr MAXDOP 4 2 false true NULL | sales LEGACY_CARDINALITY_ESTIMATION 0 NULL true true NULL | sales MAXDOP 0 NULL true true NULL"; got != want {
		t.Errorf("after the first read:\n got %s\nwant %s", got, want)
	}
	if got := s.vals(`SELECT count(*) FROM pgvigil.mssql_db_scoped_config_change WHERE instance_id = $1`, s.id); got != "0" {
		t.Errorf("the first read wrote %s changes, want 0 (a first read is the baseline)", got)
	}
	// sales' MAXDOP set to 8 and its legacy CE gone from the view; hr not entered this time
	imp(t2, cfg("sales", "MAXDOP", 8, nil, false), unread("hr", "not read: the login cannot enter the database"))
	if got, want := rows(), "hr MAXDOP 4 2 false true not read: the login cannot enter the database | sales LEGACY_CARDINALITY_ESTIMATION 0 NULL true false NULL | sales MAXDOP 8 NULL false true NULL"; got != want {
		t.Errorf("after the second read:\n got %s\nwant %s", got, want)
	}
	if got, want := s.vals(`SELECT database_name, name, old_value, new_value, changed_at = $2 FROM pgvigil.mssql_db_scoped_config_change
	                         WHERE instance_id = $1 ORDER BY database_name, name`, s.id, t2),
		"sales LEGACY_CARDINALITY_ESTIMATION 0 NULL true | sales MAXDOP 0 8 true"; got != want {
		t.Errorf("the changes:\n got %s\nwant %s", got, want)
	}
}
