package mssql

import (
	"fmt"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestServiceBrokerReview8 (review t11-8's fold, P25 row 73): the collector's statements and shaping after the review.
//   - 1 / 9: a queue's oldest ready message and the queue monitors' times are datetimes with no zone (Microsoft Learn,
//     read 2026-11-17: CREATE QUEUE's message_enqueue_time, sys.dm_broker_queue_monitors) that DBA Dash's
//     SQLServiceBroker.sql L46 reads as UTC already: sent as TODATETIMEOFFSET(..., 0), never through utcOf (a server not
//     set to UTC: NOT PROVEN);
//   - 2 / 11: sys.transmission_queue's enqueue_time is UTC (Learn: 'uses UTC regardless of the local time zone'):
//     TODATETIMEOFFSET; to_service_name and transmission_status are NULLABLE: grouped on their ISNULL, so a NULL and a
//     blank status are one group; the 50 largest groups and the rest folded into one;
//   - 3: without VIEW SERVER STATE (VIEW SERVER PERFORMANCE STATE from 2022, Learn) the queue statement reads the
//     catalog alone - its readers' columns NULL - so the settings and depth are kept;
//   - 10: the conversation total counts sysdercv's heap or clustered index only (index_id 0 / 1, DBA Dash L194);
//   - 5: an empty RETENTION queue's depth is 0, not 'not read';
//   - 12: a queue whose own read was refused carries why (oldest_note);
//   - 17: SqlDependency's rollup keeps the worst receive state (a disabled listener queue marks the row);
//   - 7: every user database the run does not visit says why - the broker off, a secondary replica, not enterable, over
//     the cap - so a database whose queues the store holds never keeps them as current with no words;
//   - 18: the endpoint's connected and failed counts are 0 over no connection, not NULL.
func TestServiceBrokerReview8(t *testing.T) {
	if s := brokerReadySQL("dbo", "Odd]Q"); !strings.Contains(s, "TODATETIMEOFFSET(MIN(message_enqueue_time), 0) AS oldest") || !strings.Contains(s, "[dbo].[Odd]]Q]") {
		t.Errorf("brokerReadySQL: %s", s)
	}
	for _, want := range []string{"TODATETIMEOFFSET(MIN(enqueue_time), 0) AS oldest_enqueue_time", "ISNULL(to_service_name, N'')", "ISNULL(transmission_status, N'')", "'(the other groups)'"} {
		if !strings.Contains(brokerTransmissionSQL, want) {
			t.Errorf("brokerTransmissionSQL lacks %q", want)
		}
	}
	full, catalog := brokerQueuesFor(Info{ViewServerState: true}), brokerQueuesFor(Info{})
	for _, dmv := range []string{"sys.dm_broker_activated_tasks", "sys.dm_broker_queue_monitors"} {
		if !strings.Contains(full, dmv) {
			t.Errorf("the queue statement with VIEW SERVER STATE lacks %s", dmv)
		}
		if strings.Contains(catalog, dmv) {
			t.Errorf("the queue statement without VIEW SERVER STATE still reads %s", dmv)
		}
	}
	if !strings.Contains(catalog, "CAST(NULL AS int) AS activated_tasks") || !strings.Contains(catalog, "AS internal_rows") {
		t.Errorf("the catalog-only queue statement: %s", catalog)
	}
	if !strings.Contains(full, "TODATETIMEOFFSET(NULLIF(m.last_activated_time, '19000101'), 0)") || strings.Contains(full, "DATEPART(TZOFFSET") {
		t.Errorf("the queue monitors' times are not sent as UTC with TODATETIMEOFFSET: %s", full)
	}
	if !strings.Contains(brokerConversationsSQL, "p.index_id IN (0, 1)") {
		t.Error("brokerConversationsSQL's sysdercv total counts every index")
	}
	if !strings.Contains(brokerEndpointSQL, "ISNULL(SUM(CASE WHEN bc.state_desc") || !strings.Contains(brokerEndpointSQL, "ISNULL(SUM(CASE WHEN bc.login_state") {
		t.Error("brokerEndpointSQL's counts are NULL over no connection")
	}

	dbs := []userDB{{name: "Sales", quoted: "[Sales]", canEnter: true}, {name: "Ledger", quoted: "[Ledger]", canEnter: false},
		{name: "Replica", quoted: "[Replica]", canEnter: true, secondary: true}, {name: "Off", quoted: "[Off]", canEnter: true}}
	broker := map[string]bool{"Sales": true, "Ledger": true, "Replica": true}
	visit, unread := brokerPlan(dbs, broker, 5)
	why := map[string]string{}
	for _, r := range unread {
		why[fmt.Sprint(r["database_name"])] = fmt.Sprint(r["note"])
	}
	if len(visit) != 1 || len(unread) != 3 || !strings.Contains(why["Off"], "the broker is off") || !strings.Contains(why["Replica"], "secondary replica") ||
		!strings.Contains(why["Ledger"], "Ledger") {
		t.Errorf("brokerPlan: visit %d, unread %v - want Sales visited and Ledger, Replica and Off each with why", len(visit), why)
	}

	raw := []collect.Row{
		{"schema_name": "dbo", "queue_name": "EmptyKeep", "object_id": int64(21), "is_retention_enabled": int64(1), "internal_rows": int64(0)},
		{"schema_name": "dbo", "queue_name": "Locked", "object_id": int64(22), "is_retention_enabled": int64(0), "internal_rows": int64(4)},
		{"schema_name": "app", "queue_name": "SqlQueryNotificationService-a", "object_id": int64(23), "is_retention_enabled": int64(0), "internal_rows": int64(1), "is_receive_enabled": int64(1)},
		{"schema_name": "app", "queue_name": "SqlQueryNotificationService-b", "object_id": int64(24), "is_retention_enabled": int64(0), "internal_rows": int64(1), "is_receive_enabled": int64(0)},
	}
	refused := map[int64]string{22: "the read of its oldest message was refused: SELECT on the queue"}
	got := map[string]collect.Row{}
	for _, r := range brokerQueueRowsNoted("Sales", raw, map[int64]brokerReady{}, refused) {
		got[fmt.Sprint(r["queue_name"])] = r
	}
	if fmt.Sprint(got["EmptyKeep"]["message_count"]) != "0" {
		t.Errorf("an empty RETENTION queue's depth %v, want 0", got["EmptyKeep"]["message_count"])
	}
	if got["Locked"]["oldest_note"] != refused[22] {
		t.Errorf("Locked's oldest_note %v, want the refusal's words", got["Locked"]["oldest_note"])
	}
	if got["SqlQueryNotificationService-*"]["is_receive_enabled"] != false {
		t.Errorf("the SqlDependency rollup's is_receive_enabled %v, want false (one of its queues is disabled)", got["SqlQueryNotificationService-*"]["is_receive_enabled"])
	}
}
