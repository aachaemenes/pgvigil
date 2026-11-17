package repo

import (
	"encoding/json"
	"testing"
	"time"
)

// TestServiceBrokerReview8OnAStore (review t11-8's fold, migration 0392):
//   - 3: each database a read names gets a read state (pgvigil.mssql_broker_read: when it was last read, and why not or
//     what was left out) - a database never read has its words too, so the tab never says only 'none here';
//   - 4: a part the read could not take (a 'transmission_unread' / 'conversation_unread' row) keeps that database's
//     stored rows of that part and says why in its read state;
//   - 7: a run that lists every user database ('all_listed') marks not present the queues of a stored database it
//     does not name (dropped or renamed); a run without it marks none;
//   - 11: a NULL and a blank transmission status of one service are one group (Learn: both NULLABLE), never two rows
//     of one key in one insert;
//   - 12: a queue's oldest_note (why its own read was refused) is stored.
func TestServiceBrokerReview8OnAStore(t *testing.T) {
	s := newSpreadStore(t)
	base := time.Now().UTC().Truncate(time.Minute)
	at := func(m int) time.Time { return base.Add(time.Duration(m) * time.Minute) }
	imp := func(when int, rows ...map[string]any) {
		t.Helper()
		js, err := json.Marshal(rows)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.import_mssql_service_broker($1, $2, $3::jsonb)`, s.id, at(when), string(js)); err != nil {
			t.Fatalf("import_mssql_service_broker at %+d min: %v", when, err)
		}
	}
	queue := func(dbn, q string, note any) map[string]any {
		return map[string]any{"kind": "queue", "database_name": dbn, "schema_name": "dbo", "queue_name": q, "object_id": 1001,
			"is_receive_enabled": true, "message_count": 2, "oldest_note": note}
	}
	trans := func(dbn string, status any, n int) map[string]any {
		return map[string]any{"kind": "transmission", "database_name": dbn, "to_service_name": "//target", "transmission_status": status, "message_count": n}
	}
	// the first read: Sales read whole but its readers (no VIEW SERVER STATE), one queue refused its own read; Ledger
	// never entered; Archive read; a NULL and a blank status of one service
	imp(0, map[string]any{"kind": "database", "database_name": "Sales", "note": "the queues' readers were not read: VIEW SERVER STATE"},
		queue("Sales", "OrderQueue", "the read of its oldest message was refused: SELECT on the queue"),
		trans("Sales", nil, 3), trans("Sales", "", 2),
		map[string]any{"kind": "unread", "database_name": "Ledger", "note": "the login cannot enter Ledger"},
		map[string]any{"kind": "database", "database_name": "Archive"}, queue("Archive", "OldQueue", nil),
		map[string]any{"kind": "all_listed"})
	if got, want := s.vals(`SELECT database_name, read_at IS NOT NULL, coalesce(note, '-') FROM pgvigil.mssql_broker_read WHERE instance_id = $1 ORDER BY database_name`, s.id),
		"Archive true - | Ledger false the login cannot enter Ledger | Sales true the queues' readers were not read: VIEW SERVER STATE"; got != want {
		t.Errorf("read states after the first read:\n got %s\nwant %s", got, want)
	}
	if got, want := s.vals(`SELECT to_service_name, transmission_status, message_count FROM pgvigil.mssql_broker_transmission WHERE instance_id = $1`, s.id), "//target  5"; got != want {
		t.Errorf("transmission groups: got %q, want %q (a NULL and a blank status as one group)", got, want)
	}
	if got, want := s.vals(`SELECT coalesce(oldest_note, '-') FROM pgvigil.mssql_broker_queue WHERE instance_id = $1 AND queue_name = 'OrderQueue'`, s.id),
		"the read of its oldest message was refused: SELECT on the queue"; got != want {
		t.Errorf("OrderQueue's oldest_note: got %q, want %q", got, want)
	}
	// the second read: Sales's transmission queue not taken (its groups kept, the read state says why); Archive gone
	// (dropped): a run listing every database marks its queue not present
	imp(5, map[string]any{"kind": "database", "database_name": "Sales"}, queue("Sales", "OrderQueue", nil),
		map[string]any{"kind": "transmission_unread", "database_name": "Sales", "note": "the transmission queue was not read: lock request time out period exceeded"},
		map[string]any{"kind": "unread", "database_name": "Ledger", "note": "the login cannot enter Ledger"},
		map[string]any{"kind": "all_listed"})
	if got := s.vals(`SELECT message_count FROM pgvigil.mssql_broker_transmission WHERE instance_id = $1`, s.id); got != "5" {
		t.Errorf("Sales's transmission group after a read that could not take it: %q, want 5 (kept)", got)
	}
	if got, want := s.vals(`SELECT coalesce(note, '-') FROM pgvigil.mssql_broker_read WHERE instance_id = $1 AND database_name = 'Sales'`, s.id),
		"the transmission queue was not read: lock request time out period exceeded"; got != want {
		t.Errorf("Sales's read state: got %q, want %q", got, want)
	}
	if got, want := s.vals(`SELECT queue_name, is_present FROM pgvigil.mssql_broker_queue WHERE instance_id = $1 AND database_name = 'Archive'`, s.id), "OldQueue false"; got != want {
		t.Errorf("Archive's queue after a full list without it: got %q, want %q", got, want)
	}
	// a run that does not list every database (cut by its deadline) marks nothing gone
	imp(10, map[string]any{"kind": "database", "database_name": "Sales"}, queue("Sales", "OrderQueue", nil))
	if got := s.vals(`SELECT is_present FROM pgvigil.mssql_broker_queue WHERE instance_id = $1 AND database_name = 'Sales'`, s.id); got != "true" {
		t.Errorf("Sales's queue after a run without 'all_listed': %q, want true", got)
	}
}
