package web

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/dbadash"
)

// TestJobOutcomeRetries (N4): a mapping whose batches were taken again after a deadlock is said in the job's notes -
// the Migrate page's import result - and the outcome stays ok; a mapping without retries adds no note.
func TestJobOutcomeRetries(t *testing.T) {
	got := []dbadash.ImportCount{
		{Instance: "SQL1", DBADashID: 31, Mapping: "cpu", Source: 10, Inserted: 10, Stored: 10, Retries: 2},
		{Instance: "SQL1", DBADashID: 31, Mapping: "volumes", Source: 4, Inserted: 4, Stored: 4},
	}
	outcome, notes := jobOutcome(got, nil)
	if outcome != "ok" || len(notes) != 1 || !strings.Contains(notes[0], "SQL1 cpu: retried 2 time(s) after a deadlock") {
		t.Errorf("outcome %q, notes %v; want ok and one note 'SQL1 cpu: retried 2 time(s) after a deadlock (stored once)'", outcome, notes)
	}
}
