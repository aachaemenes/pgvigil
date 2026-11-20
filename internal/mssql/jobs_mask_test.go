package mssql

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestMaskRunText: a run row's message and a job row's last outcome message are masked as a step's command is; a
// message msdb cut inside a key (it keeps 4,000 characters) is masked to its end; every other field and every other
// kind of row is left as read.
func TestMaskRunText(t *testing.T) {
	key := `@encryptionkey = N'rk1'`
	rows := maskRunText([]collect.Row{
		{"kind": "run", "message": "Executed as user: sa. " + key + " [SQLSTATE 01000]", "step_name": key},
		{"kind": "run", "message": "Executed as user: sa. Command: EXECUTE master.dbo.xp_backup_database @database = N'master', @encryptionkey = N'rk2cutzzzz"},
		{"kind": "job", "last_message": "The job failed. " + key, "description": key},
		{"kind": "step", "command": key, "message": key},
		{"kind": "read", "cursor": true, "message": key},
		{"kind": "cursor", "last_history_id": int64(7), "mark": int64(9), "message": key},
	})
	want := []collect.Row{
		{"kind": "run", "message": "Executed as user: sa. @encryptionkey = '<masked>' [SQLSTATE 01000]", "step_name": key},
		{"kind": "run", "message": "Executed as user: sa. Command: EXECUTE master.dbo.xp_backup_database @database = N'master', @encryptionkey = '<masked>"},
		{"kind": "job", "last_message": "The job failed. @encryptionkey = '<masked>'", "description": key},
		{"kind": "step", "command": key, "message": key},
		{"kind": "read", "cursor": true, "message": key},
		{"kind": "cursor", "last_history_id": int64(7), "mark": int64(9), "message": key},
	}
	for i := range want {
		for k, v := range want[i] {
			if rows[i][k] != v {
				t.Errorf("row %d (%v) %s: got %q, want %q", i, want[i]["kind"], k, rows[i][k], v)
			}
		}
		if len(rows[i]) != len(want[i]) {
			t.Errorf("row %d: %d fields, want %d", i, len(rows[i]), len(want[i]))
		}
	}
}
