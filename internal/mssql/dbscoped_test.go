package mssql

import (
	"fmt"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestScopedRows (P25 row 2a): one database's sys.database_scoped_configurations rows become the payload's
// 'scoped_config' rows (name, value and value for secondaries as the view gives them as text, the default flag) for
// 0391's import, and the MAXDOP among them stays the number the configuration checks read (nil: no MAXDOP row; a
// value that is not a number: nil and said).
func TestScopedRows(t *testing.T) {
	read := []collect.Row{
		{"name": "MAXDOP", "value": "4", "value_for_secondary": nil, "is_value_default": int64(0)},
		{"name": "LEGACY_CARDINALITY_ESTIMATION", "value": "0", "value_for_secondary": "1", "is_value_default": int64(1)},
		{"name": "OPTIMIZE_FOR_AD_HOC_WORKLOADS", "value": "0", "value_for_secondary": nil, "is_value_default": nil},
	}
	rows, maxdop, note := scopedRows("sales", read)
	if fmt.Sprint(maxdop) != "4" || note != "" {
		t.Errorf("maxdop %v note %q, want 4 and no note", maxdop, note)
	}
	if len(rows) != 3 {
		t.Fatalf("%d rows, want 3", len(rows))
	}
	want := []string{
		"scoped_config sales MAXDOP 4 <nil> false",
		"scoped_config sales LEGACY_CARDINALITY_ESTIMATION 0 1 true",
		"scoped_config sales OPTIMIZE_FOR_AD_HOC_WORKLOADS 0 <nil> <nil>",
	}
	for i, r := range rows {
		if got := fmt.Sprint(r["kind"], " ", r["database_name"], " ", r["name"], " ", r["value"], " ", r["value_for_secondary"], " ", r["is_value_default"]); got != want[i] {
			t.Errorf("row %d: %s, want %s", i, got, want[i])
		}
	}
	if _, maxdop, note := scopedRows("hr", read[1:]); maxdop != nil || note != "not read: the database lists no MAXDOP configuration" {
		t.Errorf("no MAXDOP row: %v %q", maxdop, note)
	}
	if _, maxdop, note := scopedRows("x", []collect.Row{{"name": "MAXDOP", "value": "many"}}); maxdop != nil || note == "" {
		t.Errorf("a MAXDOP that is no number: %v %q, want nil and a note", maxdop, note)
	}
}
