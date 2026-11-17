package repo

import (
	"encoding/json"
	"testing"
	"time"
)

// TestServiceBrokerOnAStore (P25 row 73, migration 0392: DBA Dash's database Service Broker tab): on a store,
// pgvigil.import_mssql_service_broker keeps, for each database a read visited, its user queues as last read (their
// settings, depth, readers and oldest ready message; a queue the database no longer holds is not present) with one
// depth sample a queue a read, its transmission queue groups and its conversation counts by state as last read (the
// read's own rows replace a visited database's), the instance's broker endpoint as last read, and the cumulative
// Broker counters as samples; a database the read could not enter keeps its rows as they were and says why; the
// same read twice stores nothing twice.
func TestServiceBrokerOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	base := time.Now().UTC().Truncate(time.Minute)
	at := func(m int) time.Time { return base.Add(time.Duration(m) * time.Minute) }
	ts := func(m int) string { return at(m).Format(time.RFC3339) }
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
	db := func(name string) map[string]any { return map[string]any{"kind": "database", "database_name": name} }
	queue := func(dbn, q string, receive bool, depth int, oldest any) map[string]any {
		return map[string]any{"kind": "queue", "database_name": dbn, "schema_name": "dbo", "queue_name": q, "object_id": 1000 + depth,
			"is_receive_enabled": receive, "is_enqueue_enabled": true, "is_retention_enabled": false, "is_activation_enabled": true,
			"is_poison_message_handling_enabled": true, "activation_procedure": "[" + dbn + "].[dbo].[usp_" + q + "]", "activation_procedure_exists": true,
			"max_readers": 2, "message_count": depth, "activated_tasks": 1, "monitor_state": "RECEIVES_OCCURRING", "monitor_tasks_waiting": 0,
			"monitor_last_activated_time": ts(-2), "monitor_last_empty_rowset_time": nil, "oldest_message_time": oldest}
	}
	endpoint := map[string]any{"kind": "endpoint", "endpoint_name": "BrokerEndpoint", "state_desc": "STARTED", "port": 4022,
		"connection_count": 2, "connected_count": 1, "login_failed_count": 1, "last_activity_time": ts(-1)}
	counter := func(name string, v int) map[string]any {
		return map[string]any{"kind": "counter", "object": "Broker Statistics", "instance_name": "", "counter_name": name, "cntr_value": v}
	}
	// the first read: Sales with two queues (Poison receive-disabled: DBA Dash's poison mark), a transmission group
	// and conversations; Ledger with one queue; the endpoint; two counters
	imp(0, db("Sales"), db("Ledger"),
		queue("Sales", "OrderQueue", true, 3, ts(-10)), queue("Sales", "Poison", false, 7, ts(-30)), queue("Ledger", "PostQueue", true, 0, nil),
		map[string]any{"kind": "transmission", "database_name": "Sales", "to_service_name": "//target", "transmission_status": "Connection attempt failed",
			"message_count": 4, "oldest_enqueue_time": ts(-20)},
		map[string]any{"kind": "conversation", "database_name": "Sales", "state": "CO", "conversation_count": 5},
		map[string]any{"kind": "conversation", "database_name": "Sales", "state": "ER", "conversation_count": 1},
		endpoint, counter("SQL SEND Total", 100), counter("SQL RECEIVE Total", 90))
	queues := func() string {
		return s.vals(`SELECT database_name, queue_name, is_receive_enabled, message_count, is_present, coalesce(note, '-')
		                 FROM pgvigil.mssql_broker_queue WHERE instance_id = $1 ORDER BY database_name, queue_name`, s.id)
	}
	if got, want := queues(), "Ledger PostQueue true 0 true - | Sales OrderQueue true 3 true - | Sales Poison false 7 true -"; got != want {
		t.Errorf("queues after the first read:\n got %s\nwant %s", got, want)
	}
	if got, want := s.vals(`SELECT to_service_name, message_count FROM pgvigil.mssql_broker_transmission WHERE instance_id = $1`, s.id), "//target 4"; got != want {
		t.Errorf("transmission after the first read: got %s, want %s", got, want)
	}
	if got, want := s.vals(`SELECT state, conversation_count FROM pgvigil.mssql_broker_conversation WHERE instance_id = $1 ORDER BY state`, s.id), "CO 5 | ER 1"; got != want {
		t.Errorf("conversations after the first read: got %s, want %s", got, want)
	}
	if got, want := s.vals(`SELECT endpoint_name, state_desc, port, login_failed_count FROM pgvigil.mssql_broker_endpoint WHERE instance_id = $1`, s.id), "BrokerEndpoint STARTED 4022 1"; got != want {
		t.Errorf("the endpoint: got %s, want %s", got, want)
	}
	// five minutes later: Sales's Poison queue dropped, OrderQueue drained, nothing in transmission, the conversations
	// ended; Ledger not entered (its rows kept, the note says why); the counters grown
	imp(5, db("Sales"), queue("Sales", "OrderQueue", true, 0, nil),
		map[string]any{"kind": "conversation", "database_name": "Sales", "state": "CO", "conversation_count": 2},
		map[string]any{"kind": "unread", "database_name": "Ledger", "note": "the login cannot enter Ledger"},
		endpoint, counter("SQL SEND Total", 160), counter("SQL RECEIVE Total", 150))
	want2 := "Ledger PostQueue true 0 true the login cannot enter Ledger | Sales OrderQueue true 0 true - | Sales Poison false 7 false -"
	if got := queues(); got != want2 {
		t.Errorf("queues after the second read:\n got %s\nwant %s", got, want2)
	}
	if got := s.vals(`SELECT count(*) FROM pgvigil.mssql_broker_transmission WHERE instance_id = $1`, s.id); got != "0" {
		t.Errorf("transmission after the second read: %s rows, want 0 (the read's own rows replace Sales's)", got)
	}
	if got, want := s.vals(`SELECT state, conversation_count FROM pgvigil.mssql_broker_conversation WHERE instance_id = $1 ORDER BY state`, s.id), "CO 2"; got != want {
		t.Errorf("conversations after the second read: got %s, want %s", got, want)
	}
	// the same read again stores nothing twice
	imp(5, db("Sales"), queue("Sales", "OrderQueue", true, 0, nil), endpoint, counter("SQL SEND Total", 160), counter("SQL RECEIVE Total", 150))
	samples := s.vals(`SELECT database_name, queue_name, message_count FROM pgvigil.mssql_broker_queue_sample WHERE instance_id = $1
	                    ORDER BY snapshot_at, database_name, queue_name`, s.id)
	if want := "Ledger PostQueue 0 | Sales OrderQueue 3 | Sales Poison 7 | Sales OrderQueue 0"; samples != want {
		t.Errorf("depth samples:\n got %s\nwant %s (one a queue a read, the same read twice once)", samples, want)
	}
	if got, want := s.vals(`SELECT counter_name, cntr_value FROM pgvigil.mssql_broker_counter_sample WHERE instance_id = $1 ORDER BY snapshot_at, counter_name`, s.id),
		"SQL RECEIVE Total 90 | SQL SEND Total 100 | SQL RECEIVE Total 150 | SQL SEND Total 160"; got != want {
		t.Errorf("counter samples:\n got %s\nwant %s", got, want)
	}
}
