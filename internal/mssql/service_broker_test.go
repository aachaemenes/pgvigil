package mssql

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestServiceBrokerShapes (P25 row 73): the run's two shaping steps without a server. brokerPlan visits each database
// with the broker on that the login may enter (an availability group secondary never: its queues are the primary's),
// at most the cap a run, and says why for each one it does not enter; brokerQueueRows sends a queue's depth as its
// internal table's rows, a RETENTION queue's only from its own read (its internal table also holds received
// messages), and rolls SqlDependency's SqlQueryNotificationService-<guid> queues up into one row per schema (DBA
// Dash's SQLServiceBroker.sql: they come and go with each listener).
func TestServiceBrokerShapes(t *testing.T) {
	dbs := []userDB{{name: "Sales", quoted: "[Sales]", canEnter: true}, {name: "Ledger", quoted: "[Ledger]", canEnter: false},
		{name: "Replica", quoted: "[Replica]", canEnter: true, secondary: true}, {name: "Off", quoted: "[Off]", canEnter: true},
		{name: "Hr", quoted: "[Hr]", canEnter: true}, {name: "Ops", quoted: "[Ops]", canEnter: true}}
	broker := map[string]bool{"Sales": true, "Ledger": true, "Replica": true, "Hr": true, "Ops": true}
	visit, unread := brokerPlan(dbs, broker, 2)
	var names []string
	for _, d := range visit {
		names = append(names, d.name)
	}
	if got := strings.Join(names, " "); got != "Sales Hr" {
		t.Errorf("visited %q, want Sales Hr (Ledger cannot be entered, Replica is a secondary, Off has no broker, Ops is over the cap of 2)", got)
	}
	var why []string
	for _, r := range unread {
		why = append(why, fmt.Sprint(r["database_name"], ": ", r["note"]))
	}
	// review t11-8 item 7: every database not visited says why - Replica and Off too
	if got := strings.Join(why, " | "); !strings.Contains(got, "Ledger: ") || !strings.Contains(got, "Ops: over the cap of 2 databases a run") ||
		!strings.Contains(got, "Replica: ") || !strings.Contains(got, "Off: the broker is off") || len(unread) != 4 {
		t.Errorf("unread rows %q, want Ledger's, Replica's, Off's and Ops's with their words", got)
	}

	raw := []collect.Row{
		{"schema_name": "dbo", "queue_name": "OrderQueue", "object_id": int64(11), "is_retention_enabled": int64(0), "internal_rows": int64(3)},
		{"schema_name": "dbo", "queue_name": "AuditQueue", "object_id": int64(12), "is_retention_enabled": int64(1), "internal_rows": int64(40)},
		{"schema_name": "dbo", "queue_name": "KeptQueue", "object_id": int64(13), "is_retention_enabled": int64(1), "internal_rows": int64(9)},
		{"schema_name": "app", "queue_name": "SqlQueryNotificationService-1a2b", "object_id": int64(14), "is_retention_enabled": int64(0), "internal_rows": int64(2), "activated_tasks": int64(1)},
		{"schema_name": "app", "queue_name": "SqlQueryNotificationService-3c4d", "object_id": int64(15), "is_retention_enabled": int64(0), "internal_rows": int64(5), "activated_tasks": int64(0)},
	}
	// review t11-8 NIT 14: OrderQueue's ready count (2) differs from its internal rows (3), so the depth shown is the
	// internal table's
	ready := map[int64]brokerReady{11: {count: 2, oldest: time.Date(2026, 11, 17, 18, 0, 0, 0, time.UTC)}, 13: {count: 4}}
	var got []string
	for _, r := range brokerQueueRows("Sales", raw, ready) {
		got = append(got, fmt.Sprint(r["schema_name"], ".", r["queue_name"], " ", r["object_id"], " ", r["message_count"], " ", r["activated_tasks"]))
	}
	want := "dbo.OrderQueue 11 3 <nil> | dbo.AuditQueue 12 <nil> <nil> | dbo.KeptQueue 13 4 <nil> | app.SqlQueryNotificationService-* -1 7 1"
	if g := strings.Join(got, " | "); g != want {
		t.Errorf("queue rows:\n got %s\nwant %s", g, want)
	}
}

// TestServiceBrokerLive (P25 row 73): against a server (PGVIGIL_MSSQL_TEST_DSN, a login that may create a database):
// a database with the broker on, a target and an initiator queue, three messages sent on one dialog, and a queue made
// with STATUS = OFF (receive disabled, as a poison message leaves it) - the run visits the database and sends its
// queues (the target's depth 3, the off queue's receive disabled), its conversations by state, the Broker counters,
// and whether it read the endpoints.
func TestServiceBrokerLive(t *testing.T) {
	ctx, conn, info := liveConn(t)
	db := fmt.Sprintf("pgv_sb_%d", time.Now().UnixNano()%1000000)
	exec := func(q string) {
		t.Helper()
		if _, err := conn.ExecContext(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	// review t11-8 item 13: the drop is registered before the database is made (a failed ALTER no longer leaks it), its
	// error logged
	t.Cleanup(func() {
		if _, err := conn.ExecContext(context.Background(), fmt.Sprintf("USE master; IF DB_ID(N'%s') IS NOT NULL BEGIN ALTER DATABASE [%s] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [%s]; END", db, db, db)); err != nil {
			t.Logf("dropping %s: %v", db, err)
		}
	})
	exec(fmt.Sprintf("CREATE DATABASE [%s]; ALTER DATABASE [%s] SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;", db, db))
	exec(fmt.Sprintf(`EXEC [%s].sys.sp_executesql N'CREATE QUEUE dbo.TargetQ; CREATE SERVICE [//pgv/target] ON QUEUE dbo.TargetQ ([DEFAULT]);
		CREATE QUEUE dbo.InitQ; CREATE SERVICE [//pgv/init] ON QUEUE dbo.InitQ; CREATE QUEUE dbo.OffQ WITH STATUS = OFF;'`, db))
	exec(fmt.Sprintf(`EXEC [%s].sys.sp_executesql N'DECLARE @h uniqueidentifier;
		BEGIN DIALOG @h FROM SERVICE [//pgv/init] TO SERVICE ''//pgv/target'' ON CONTRACT [DEFAULT] WITH ENCRYPTION = OFF;
		SEND ON CONVERSATION @h MESSAGE TYPE [DEFAULT] (N''one''); SEND ON CONVERSATION @h MESSAGE TYPE [DEFAULT] (N''two'');
		SEND ON CONVERSATION @h MESSAGE TYPE [DEFAULT] (N''three'');'`, db))
	var rows []collect.Row
	var err error
	// local delivery is asynchronous: up to 20 s for the three messages to reach the target queue
	for i := 0; i < 20; i++ {
		rows, err = serviceBrokerCollector{}.Run(ctx, conn, info)
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
		if brokerDepth(rows, db, "TargetQ") == "3" {
			break
		}
		time.Sleep(time.Second)
	}
	kinds := map[string]int{}
	visited := false
	for _, r := range rows {
		kinds[fmt.Sprint(r["kind"])]++
		if r["kind"] == "database" && r["database_name"] == db {
			visited = true
		}
	}
	if !visited {
		t.Errorf("no 'database' row for %s (the broker on, a user queue)", db)
	}
	if got := brokerDepth(rows, db, "TargetQ"); got != "3" {
		t.Errorf("TargetQ's depth %s, want 3 (three messages on one dialog)", got)
	}
	// review t11-8 item 13: OffQ's row must be there (a missing row no longer passes), and TargetQ's oldest ready message
	// is read, as UTC (items 1 / 9: the container runs in UTC, so the zone itself is NOT PROVEN here)
	off := false
	for _, r := range rows {
		if r["kind"] != "queue" || r["database_name"] != db {
			continue
		}
		if r["queue_name"] == "OffQ" {
			off = true
			if r["is_receive_enabled"] != false {
				t.Errorf("OffQ's is_receive_enabled %v, want false (STATUS = OFF)", r["is_receive_enabled"])
			}
		}
		if r["queue_name"] == "TargetQ" {
			ts, ok := r["oldest_message_time"].(time.Time)
			if !ok || time.Since(ts) > 10*time.Minute || time.Until(ts) > time.Minute {
				t.Errorf("TargetQ's oldest_message_time %v (%T), want a time within minutes of now", r["oldest_message_time"], r["oldest_message_time"])
			}
		}
	}
	if !off {
		t.Errorf("no queue row for OffQ in %s", db)
	}
	conv := false
	for _, r := range rows {
		if r["kind"] == "conversation" && r["database_name"] == db && r["state"] == "CO" {
			conv = true
		}
	}
	if !conv {
		t.Errorf("no CO conversation row for %s (the dialog conversing)", db)
	}
	if kinds["counter"] == 0 {
		t.Error("no Broker counter rows (sys.dm_os_performance_counters' Broker Statistics)")
	}
	if kinds["endpoint"] == 0 && kinds["endpoints_read"] == 0 {
		t.Error("neither an endpoint row nor 'endpoints_read' (the endpoint's read)")
	}
}

// brokerDepth: a queue's message_count in a run's rows, as text ("" when the row is not there)
func brokerDepth(rows []collect.Row, db, queue string) string {
	for _, r := range rows {
		if r["kind"] == "queue" && r["database_name"] == db && r["queue_name"] == queue {
			return fmt.Sprint(r["message_count"])
		}
	}
	return ""
}
