package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// serviceBrokerCollector is mssql_service_broker (P25 row 73; DBA Dash's database Service Broker tab, whose collection
// DBADash/SQL/SQLServiceBroker.sql 4.24.1 gives the shape: queues, transmission groups, conversations by state, the
// endpoint, the cumulative Broker counters). Every 5 minutes it visits each user database with the broker on that the
// login may enter - never an availability group secondary (its queues are the primary's), at most brokerMaxDatabases a
// run, the rest named with why - and reads there, from Microsoft's views (Microsoft Learn, read 2026-11-17):
// sys.service_queues (the user queues: is_ms_shipped = 0), each queue's depth as its internal table's rows
// (sys.internal_tables internal_type 201 QUEUE_MESSAGES, joined on parent_id as Microsoft's example H does, and
// sys.partitions; never a COUNT of the queue), sys.dm_broker_activated_tasks and sys.dm_broker_queue_monitors (VIEW
// SERVER STATE; VIEW SERVER PERFORMANCE STATE from 2022), the oldest message ready to receive (status 1) read from the
// queue itself only up to brokerQueueScanRows a queue and brokerTotalScanRows a run, sys.transmission_queue grouped
// (its enqueue_time is UTC), and sys.conversation_endpoints by state (a database over brokerConversationScanRows: one
// '??' total from sys.partitions, as DBA Dash). Once a run: sys.service_broker_endpoints with sys.tcp_endpoints and
// sys.dm_broker_connections, and the Broker Statistics / Broker Activation counters of sys.dm_os_performance_counters.
// A part the login may not read is left out with its words; the run fails only when it cannot list the databases.
// Not DBA Dash: DBA Dash's collection is off by default; pgvigil's is on (the lead's Q1, 11-17 10:4x) - the database cap
// and the scan caps bound its cost - and it reads user databases only (database_id over 4).
type serviceBrokerCollector struct{}

func init() { Register(serviceBrokerCollector{}) }

func (serviceBrokerCollector) Name() string                   { return Prefix + "service_broker" }
func (serviceBrokerCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (serviceBrokerCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "Azure SQL Database has no Service Broker between its databases (sys.service_queues is SQL Server's and Managed Instance's)"
	}
	return true, ""
}

const (
	brokerMaxDatabases         = 200
	brokerQueueScanRows        = 100000
	brokerTotalScanRows        = 1000000
	brokerConversationScanRows = 1000000
)

// brokerReady is a queue's own read: the messages ready to receive and the oldest of them
type brokerReady struct {
	count  int64
	oldest time.Time
}

const brokerDatabasesSQL = `SELECT d.name AS database_name FROM sys.databases d WHERE d.database_id > 4 AND d.state = 0 AND d.is_broker_enabled = 1`

// brokerQueuesFor: the queue statement a run's right allows (review t11-8 item 3) - with VIEW SERVER STATE (VIEW SERVER
// PERFORMANCE STATE from 2022, Microsoft Learn) the readers from sys.dm_broker_activated_tasks and
// sys.dm_broker_queue_monitors, without it the catalog alone (the settings and the depth), the readers' columns NULL
func brokerQueuesFor(info Info) string {
	if info.ViewServerState {
		return brokerQueuesSQL
	}
	return brokerQueuesCatalogSQL
}

// brokerReaders: the readers' columns of the full statement. The queue monitors' times are datetimes Microsoft Learn
// names no zone for; DBA Dash's SQLServiceBroker.sql L46 reads them as UTC already (review t11-8 item 9: a server not
// set to UTC is NOT PROVEN)
const brokerReaders = `(SELECT COUNT(*) FROM sys.dm_broker_activated_tasks a WHERE a.database_id = DB_ID() AND a.queue_id = q.object_id) AS activated_tasks,
  m.state AS monitor_state, m.tasks_waiting AS monitor_tasks_waiting,
  TODATETIMEOFFSET(NULLIF(m.last_activated_time, '19000101'), 0) AS monitor_last_activated_time,
  TODATETIMEOFFSET(NULLIF(m.last_empty_rowset_time, '19000101'), 0) AS monitor_last_empty_rowset_time`

// brokerQueuesSQL runs inside a database: its user queues, their settings, depth and readers
var brokerQueuesSQL = `SELECT SCHEMA_NAME(q.schema_id) AS schema_name, q.name AS queue_name, CAST(q.object_id AS bigint) AS object_id,
  CAST(q.is_receive_enabled AS int) AS is_receive_enabled, CAST(q.is_enqueue_enabled AS int) AS is_enqueue_enabled,
  CAST(q.is_retention_enabled AS int) AS is_retention_enabled, CAST(q.is_activation_enabled AS int) AS is_activation_enabled,
  CAST(q.is_poison_message_handling_enabled AS int) AS is_poison_message_handling_enabled, q.activation_procedure,
  CASE WHEN q.activation_procedure IS NULL THEN NULL WHEN OBJECT_ID(q.activation_procedure) IS NULL THEN 0 ELSE 1 END AS activation_procedure_exists,
  CAST(q.max_readers AS int) AS max_readers,
  (SELECT CAST(SUM(p.rows) AS bigint) FROM sys.internal_tables it
     JOIN sys.partitions p ON p.object_id = it.object_id AND p.index_id IN (0, 1)
    WHERE it.parent_id = q.object_id AND it.internal_type = 201) AS internal_rows,
  ` + brokerReaders + `
FROM sys.service_queues q
LEFT JOIN sys.dm_broker_queue_monitors m ON m.database_id = DB_ID() AND m.queue_id = q.object_id
WHERE q.is_ms_shipped = 0`

// brokerQueuesCatalogSQL: the same without the two server-state views (no VIEW SERVER STATE)
var brokerQueuesCatalogSQL = strings.NewReplacer(brokerReaders, `CAST(NULL AS int) AS activated_tasks, CAST(NULL AS nvarchar(60)) AS monitor_state,
  CAST(NULL AS int) AS monitor_tasks_waiting, CAST(NULL AS datetimeoffset) AS monitor_last_activated_time,
  CAST(NULL AS datetimeoffset) AS monitor_last_empty_rowset_time`,
	"\nLEFT JOIN sys.dm_broker_queue_monitors m ON m.database_id = DB_ID() AND m.queue_id = q.object_id", "").Replace(brokerQueuesSQL)

// brokerNoReaders: the 'database' row's words when the readers were not read
const brokerNoReaders = "the queues' readers (activated tasks, the queue monitor) were not read: VIEW SERVER STATE (VIEW SERVER PERFORMANCE STATE from SQL Server 2022) is not held"

// brokerReadySQL: a queue's own read - its messages ready to receive and the oldest of them, a datetime Microsoft Learn
// names no zone for and DBA Dash's L46 reads as UTC (review t11-8 item 1)
func brokerReadySQL(schema, queue string) string {
	return "SELECT COUNT_BIG(*) AS ready, TODATETIMEOFFSET(MIN(message_enqueue_time), 0) AS oldest FROM " + quoteName(schema) + "." +
		quoteName(queue) + " WITH (NOLOCK) WHERE status = 1"
}

// brokerTransmissionSQL runs inside a database: the transmission queue's 50 largest target service and status groups,
// the rest folded into one (review t11-8 items 2, 11, 18): its enqueue_time is UTC (Microsoft Learn: 'uses UTC
// regardless of the local time zone'), sent with its offset; to_service_name and transmission_status are NULLABLE, a
// blank status 'not sent yet': grouped on their ISNULL, so a NULL and a blank are one group
const brokerTransmissionSQL = `WITH g AS (
  SELECT ISNULL(to_service_name, N'') AS to_service_name, ISNULL(transmission_status, N'') AS transmission_status, COUNT_BIG(*) AS message_count,
         TODATETIMEOFFSET(MIN(enqueue_time), 0) AS oldest_enqueue_time
    FROM sys.transmission_queue GROUP BY ISNULL(to_service_name, N''), ISNULL(transmission_status, N'')
), r AS (SELECT g.*, ROW_NUMBER() OVER (ORDER BY g.message_count DESC) AS rn FROM g)
SELECT to_service_name, transmission_status, message_count, oldest_enqueue_time FROM r WHERE rn <= 50
UNION ALL
SELECT N'(the other groups)', CAST(COUNT(*) AS nvarchar(20)) + N' groups', SUM(message_count), MIN(oldest_enqueue_time) FROM r WHERE rn > 50 HAVING COUNT(*) > 0`

// brokerConversationsSQL runs inside a database: the conversation endpoints by state, or one '??' total over the cap
var brokerConversationsSQL = fmt.Sprintf(`DECLARE @n bigint = (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'sys.sysdercv') AND p.index_id IN (0, 1));
IF @n > %d SELECT CAST('??' AS nvarchar(2)) AS state, @n AS conversation_count
ELSE SELECT state, COUNT_BIG(*) AS conversation_count FROM sys.conversation_endpoints GROUP BY state`, brokerConversationScanRows)

var brokerEndpointSQL = `SELECT e.name AS endpoint_name, e.state_desc, t.port, c.connection_count, c.connected_count, c.login_failed_count,
  ` + utcOf("c.last_activity_time") + ` AS last_activity_time
FROM sys.service_broker_endpoints e
LEFT JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id
OUTER APPLY (SELECT COUNT(*) AS connection_count,
                    ISNULL(SUM(CASE WHEN bc.state_desc IN ('CONNECTED', 'LOGGED_IN') THEN 1 ELSE 0 END), 0) AS connected_count,
                    ISNULL(SUM(CASE WHEN bc.login_state = 13 THEN 1 ELSE 0 END), 0) AS login_failed_count,
                    MAX(bc.last_activity_time) AS last_activity_time
               FROM sys.dm_broker_connections bc) c`

// brokerCountersSQL: DBA Dash's counters, cumulative since the instance started (the page charts their differences)
const brokerCountersSQL = `SELECT CASE WHEN object_name LIKE N'%:Broker Statistics%' THEN 'Broker Statistics' ELSE 'Broker Activation' END AS object,
  RTRIM(instance_name) AS instance_name, RTRIM(counter_name) AS counter_name, cntr_value
FROM sys.dm_os_performance_counters
WHERE (object_name LIKE N'%:Broker Statistics%' AND counter_name IN (N'Enqueued Messages Total', N'SQL SEND Total', N'SQL RECEIVE Total',
        N'Activation Errors Total', N'Corrupted Messages Total', N'Dropped Messages Total', N'Broker Transaction Rollbacks',
        N'Dequeued TransmissionQ Msgs/sec'))
   OR (object_name LIKE N'%:Broker Activation%' AND RTRIM(instance_name) <> N'_Total'
       AND counter_name IN (N'Stored Procedures Invoked/sec', N'Task Limit Reached/sec', N'Tasks Aborted/sec'))`

// brokerPlan: the databases a run visits (the broker on, enterable, not an availability group secondary), at most
// limit, in the server's order; EVERY other user database gets an 'unread' row with why (review t11-8 item 7: the
// store's rows of a database never keep reading as current with no words)
func brokerPlan(dbs []userDB, broker map[string]bool, limit int) (visit []userDB, unread []collect.Row) {
	why := func(d userDB, note string) {
		unread = append(unread, collect.Row{"kind": "unread", "database_name": d.name, "note": note})
	}
	for _, d := range dbs {
		switch {
		case !d.canEnter && d.state != "" && d.state != "ONLINE":
			why(d, d.name+" is "+strings.ToLower(d.state))
		case !d.canEnter:
			why(d, "the login cannot enter "+d.name)
		case d.secondary:
			why(d, d.name+" is a secondary replica of an availability group: its queues are the primary's")
		case !broker[d.name]:
			why(d, "the broker is off in "+d.name)
		case len(visit) >= limit:
			why(d, fmt.Sprintf("over the cap of %d databases a run", limit))
		default:
			visit = append(visit, d)
		}
	}
	return visit, unread
}

// brokerQueueRows: a database's queue rows - the depth as the internal table's rows (a RETENTION queue's only from its
// own read, else NULL), the oldest ready message from the read; SqlDependency's SqlQueryNotificationService-<guid>
// queues one row per schema (their depth and readers summed, object_id -1)
func brokerQueueRows(db string, raw []collect.Row, ready map[int64]brokerReady) []collect.Row {
	return brokerQueueRowsNoted(db, raw, ready, nil)
}

// brokerQueueRowsNoted: brokerQueueRows with each queue's refused own read said (refused: object_id -> why; review
// t11-8 item 12), an empty RETENTION queue's depth 0 (item 5) and the SqlDependency rollup's worst receive state (item 17)
func brokerQueueRowsNoted(db string, raw []collect.Row, ready map[int64]brokerReady, refused map[int64]string) []collect.Row {
	var out []collect.Row
	dep := map[string]collect.Row{}
	var depOrder []string
	for _, r := range raw {
		id, _ := asInt(r["object_id"])
		retention, _ := asInt(r["is_retention_enabled"])
		row := collect.Row{"kind": "queue", "database_name": db}
		for k, v := range r {
			if k != "internal_rows" {
				row[k] = v
			}
		}
		for _, k := range []string{"is_receive_enabled", "is_enqueue_enabled", "is_retention_enabled", "is_activation_enabled", "is_poison_message_handling_enabled", "activation_procedure_exists"} {
			if n, ok := asInt(r[k]); ok {
				row[k] = n == 1
			}
		}
		rd, read := ready[id]
		internal, _ := asInt(r["internal_rows"])
		switch {
		case retention == 1 && read:
			row["message_count"] = rd.count
		case retention == 1 && internal == 0:
			row["message_count"] = int64(0)
		case retention == 1:
			row["message_count"] = nil
		default:
			row["message_count"] = r["internal_rows"]
		}
		if read && !rd.oldest.IsZero() {
			row["oldest_message_time"] = rd.oldest
		}
		if why, ok := refused[id]; ok {
			row["oldest_note"] = why
		}
		name := rowText(r, "queue_name")
		if strings.HasPrefix(name, "SqlQueryNotificationService-") {
			schema := rowText(r, "schema_name")
			g, ok := dep[schema]
			if !ok {
				g = collect.Row{"kind": "queue", "database_name": db, "schema_name": schema, "queue_name": "SqlQueryNotificationService-*",
					"object_id": int64(-1), "message_count": int64(0), "activated_tasks": int64(0), "is_receive_enabled": true}
				dep[schema] = g
				depOrder = append(depOrder, schema)
			}
			if n, ok := asInt(row["message_count"]); ok {
				c, _ := asInt(g["message_count"])
				g["message_count"] = c + n
			}
			if n, ok := asInt(r["activated_tasks"]); ok {
				c, _ := asInt(g["activated_tasks"])
				g["activated_tasks"] = c + n
			}
			if row["is_receive_enabled"] == false {
				g["is_receive_enabled"] = false // DBA Dash's MIN(is_receive_enabled): a disabled listener queue marks the row
			}
			continue
		}
		out = append(out, row)
	}
	for _, s := range depOrder {
		out = append(out, dep[s])
	}
	return out
}

func (c serviceBrokerCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	dbs, _, err := userDatabases(ctx, conn, info)
	if err != nil {
		return nil, fmt.Errorf("the databases: %w", err)
	}
	brokerRows, err := QueryRows(ctx, conn, brokerDatabasesSQL)
	if err != nil {
		return nil, fmt.Errorf("the broker's databases: %w", err)
	}
	broker := map[string]bool{}
	for _, r := range brokerRows {
		broker[rowText(r, "database_name")] = true
	}
	visit, out := brokerPlan(dbs, broker, brokerMaxDatabases)
	queuesSQL := brokerQueuesFor(info)
	scanned := int64(0)
	cut := false
	for vi, d := range visit {
		// the run's deadline: what was read is kept, each database left says why (review t11-8 item 8)
		if ctx.Err() != nil {
			for _, rest := range visit[vi:] {
				out = append(out, collect.Row{"kind": "unread", "database_name": rest.name, "note": "the run's deadline came first: " + rest.name + " is read by a later run"})
			}
			cut = true
			break
		}
		raw, err := qsRead(ctx, conn, d.quoted, queuesSQL, "")
		if err != nil {
			out = append(out, collect.Row{"kind": "unread", "database_name": d.name, "note": "the queues of " + d.name + " were not read: " + errText(err, "")})
			continue
		}
		dbRow := collect.Row{"kind": "database", "database_name": d.name}
		if !info.ViewServerState {
			dbRow["note"] = brokerNoReaders
		}
		out = append(out, dbRow)
		// the oldest ready message: the smallest queues first, within the scan caps
		sort.SliceStable(raw, func(i, j int) bool {
			a, _ := asInt(raw[i]["internal_rows"])
			b, _ := asInt(raw[j]["internal_rows"])
			return a < b
		})
		ready, refused := map[int64]brokerReady{}, map[int64]string{}
		for _, q := range raw {
			n, _ := asInt(q["internal_rows"])
			// SqlDependency's listener queues come and go: never scanned (DBA Dash's L240), their rollup has no oldest
			if n < 1 || n > brokerQueueScanRows || scanned+n > brokerTotalScanRows || strings.HasPrefix(rowText(q, "queue_name"), "SqlQueryNotificationService-") {
				continue
			}
			id, _ := asInt(q["object_id"])
			got, err := qsRead(ctx, conn, d.quoted, brokerReadySQL(rowText(q, "schema_name"), rowText(q, "queue_name")), "")
			scanned += n
			if err != nil {
				// no SELECT on the queue (the documented login holds none): its depth stays the internal table's, the
				// cell says why its oldest message is not read (review t11-8 item 12)
				refused[id] = "its oldest message was not read: " + errText(err, "")
				continue
			}
			if len(got) == 0 {
				continue
			}
			rd := brokerReady{}
			rd.count, _ = asInt(got[0]["ready"])
			if t, ok := got[0]["oldest"].(time.Time); ok {
				rd.oldest = t
			}
			ready[id] = rd
		}
		out = append(out, brokerQueueRowsNoted(d.name, raw, ready, refused)...)
		// a part not taken keeps the store's rows of it and says why (review t11-8 item 4), never 'nothing'
		if tq, err := qsRead(ctx, conn, d.quoted, brokerTransmissionSQL, ""); err == nil {
			for _, r := range tq {
				r["kind"], r["database_name"] = "transmission", d.name
				out = append(out, r)
			}
		} else {
			out = append(out, collect.Row{"kind": "transmission_unread", "database_name": d.name, "note": "the transmission queue was not read: " + errText(err, "")})
		}
		if cv, err := qsRead(ctx, conn, d.quoted, brokerConversationsSQL, ""); err == nil {
			for _, r := range cv {
				r["kind"], r["database_name"] = "conversation", d.name
				out = append(out, r)
			}
		} else {
			out = append(out, collect.Row{"kind": "conversation_unread", "database_name": d.name, "note": "the conversations were not read: " + errText(err, "")})
		}
	}
	if cut {
		return out, nil
	}
	// every user database is named by a 'database' or an 'unread' row: the store marks the queues of one it holds and
	// this list lacks (dropped, renamed) not present (review t11-8 item 7)
	out = append(out, collect.Row{"kind": "all_listed"})
	// the endpoint and the counters, once a run; a refused read leaves the stored endpoint as it was
	if eps, err := QueryRows(ctx, conn, brokerEndpointSQL); err == nil {
		out = append(out, collect.Row{"kind": "endpoints_read"})
		for _, r := range eps {
			r["kind"] = "endpoint"
			out = append(out, r)
		}
	}
	if cs, err := QueryRows(ctx, conn, brokerCountersSQL); err == nil {
		for _, r := range cs {
			r["kind"] = "counter"
			out = append(out, r)
		}
	}
	return out, nil
}
