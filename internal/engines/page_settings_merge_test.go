package engines

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// TestMergedPageThresholdRows (ST5b, the design pass's F2): a stored settings row read by Merge reaches
// mssql.ThresholdRows whole - float64 numbers and backup_exclude as []string, json.Number refused there.
func TestMergedPageThresholdRows(t *testing.T) {
	all, skipped := config.Merge(nil, []config.PageInstance{{Name: "m1", Engine: config.EngineSQLServer, DSNRef: "file:/etc/pgvigil/m1",
		SettingsRaw: []byte(`{"thresholds": {"redo_queue_kb": 512000, "full_backup_hours": 0.5, "backup_exclude": ["Sales%"]}}`)}}, "full", config.CounterEdits{})
	if len(all) != 1 || len(skipped) != 0 {
		t.Fatalf("merged %d, skipped %v", len(all), skipped)
	}
	rows, err := mssql.ThresholdRows(all[0].MSSQLThresholds)
	if err != nil || len(rows) != 1 || rows[0]["redo_queue_kb"] != float64(512000) || rows[0]["full_backup_hours"] != 0.5 {
		t.Errorf("mssql.ThresholdRows of the merged instance: %v (%v)", rows, err)
	}
	if pats, ok := rows[0]["backup_exclude"].([]string); !ok || len(pats) != 1 || pats[0] != "Sales%" {
		t.Errorf("backup_exclude of the merged instance: %#v", rows[0]["backup_exclude"])
	}
}
