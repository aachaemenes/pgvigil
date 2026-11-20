package mssql

import (
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestWaitingTaskRowKeepsOwn: the payload row carries the read's is_own (a fixed key list dropped it, so no
// waiting task was ever stored own) and renames wait_duration_ms to wait_ms.
func TestWaitingTaskRowKeepsOwn(t *testing.T) {
	for _, own := range []any{true, false, nil} {
		r := waitingTaskRow(collect.Row{"session_id": 61, "wait_duration_ms": int64(12), "is_own": own})
		if r["is_own"] != own || r["wait_ms"] != int64(12) || r["kind"] != "task" || r["session_id"] != 61 {
			t.Errorf("is_own %v: row %v", own, r)
		}
	}
}
