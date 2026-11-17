package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/jackc/pgx/v5"
)

// The day-one checks of a SQL Server instance (task 148; migration 0090, collections mssql_checks and
// mssql_identity; the trace flags' area from mssql_traceflags, migration 0094) and their fleet view.
//
//	GET /api/mssql/checks?instance=N[&part=...]   state (the two collections' last runs), areas (per area: read or
//	        not, why, the Summary cell), findings, options (every server option with its default, advised value and
//	        verdict), flags (trace flags), build, databases (every database's options and the cells that deviate),
//	        columns (the database grid's columns in order, with the value each is held to), suspect, alerts,
//	        operators, alerting (the fail-safe operator), identity (the columns), identity_scan (per database).
//	GET /api/mssql/checks/fleet[?part=...]        risks (per instance the databases with each risky option, the
//	        largest VLF count, the server options that deviate: DBA Dash's DB Options summary), cells (every
//	        instance's area cells), options (the fleet pivot of the server options: one row per instance and
//	        option, the verdict beside the value).

const sqlMSSQLChecksAreas = `
SELECT s.key AS area, s.is_read, s.note, s.sampled, s.critical, s.warning, s.value, s.detail, s.snapshot_at, s.read_at
  FROM pgvigil.mssql_checks_status s
 WHERE s.instance_id = $1
 ORDER BY s.key`

const sqlMSSQLChecksFindings = `
SELECT f.area, f.severity, f.check_name, f.object, f.rule, f.value, f.detail, f.first_seen, f.at
  FROM pgvigil.mssql_checks_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.area, f.check_name, f.object`

// the worst first, then by name; an option no longer listed last
const sqlMSSQLChecksOptions = `
SELECT o.name, o.value_in_use, o.value_set, o.default_value, o.advised, o.status, o.severity, o.rule, o.detail,
       o.value_set IS DISTINCT FROM o.value_in_use
       -- the engine resolves a 0 in 'min server memory (MB)' to its own floor (16): not pending (q_mssql_config.go)
       AND NOT (o.name = 'min server memory (MB)' AND o.value_set = 0 AND o.value_in_use <= 16) AS pending, o.is_present, o.snapshot_at
  FROM pgvigil.mssql_server_option o
 WHERE o.instance_id = $1
 ORDER BY o.is_present DESC, CASE o.status WHEN 'crit' THEN 0 WHEN 'warn' THEN 1 WHEN 'ok' THEN 2 ELSE 3 END,
          CASE o.severity WHEN 'warning' THEN 0 ELSE 1 END, lower(o.name)`

const sqlMSSQLChecksFlags = `
SELECT t.flag, t.is_on, t.status, t.severity, t.rule, t.detail, t.first_seen, t.is_present, t.snapshot_at
  FROM pgvigil.mssql_trace_flag_checks t
 WHERE t.instance_id = $1
 ORDER BY t.is_present DESC, t.is_on DESC, t.flag`

const sqlMSSQLChecksBuild = `
SELECT b.*, i.server_version AS product_version
  FROM pgvigil.mssql_build b JOIN pgvigil.instances i USING (instance_id)
 WHERE b.instance_id = $1`

const sqlMSSQLChecksDatabases = `
SELECT d.database_name, d.database_id, d.state, d.is_system, d.is_snapshot, d.options, d.deviations, d.is_present, d.snapshot_at
  FROM pgvigil.mssql_database_option d
 WHERE d.instance_id = $1 AND ($2::text = '' OR d.database_name = $2::text)
 ORDER BY d.is_present DESC, d.is_system DESC, lower(d.database_name)`

// sqlMSSQLChecksScopedConfig / Changes: one database's scoped configuration (0391, P25 row 2a: DBA Dash's database
// DB Configuration) - each row as last read, and the changes the reads saw, the newest first. $2 the database's name.
const sqlMSSQLChecksScopedConfig = `
SELECT c.name, c.value, c.value_for_secondary, c.is_default, c.is_present, c.note, c.first_seen, c.snapshot_at
  FROM pgvigil.mssql_db_scoped_config c
 WHERE c.instance_id = $1 AND c.database_name = $2::text
 ORDER BY c.is_present DESC, c.name`

// the database's Service Broker (0392, P25 row 73: DBA Dash's database Service Broker tab). $2 the database's name;
// the depth and the counters over the window ($3 / $4).
var sqlMSSQLChecksBrokerQueues = `
SELECT q.schema_name, q.queue_name, q.is_receive_enabled, q.is_enqueue_enabled, q.is_retention_enabled, q.is_activation_enabled,
       q.is_poison_handling, q.activation_procedure, q.activation_procedure_exists, q.max_readers, q.message_count, q.activated_tasks,
       q.monitor_state, q.monitor_tasks_waiting, q.monitor_last_activated, q.monitor_last_empty, q.oldest_message_at, q.oldest_note,
       q.note, q.is_present, q.first_seen, q.snapshot_at,
       ` + brokerQueueStatusCols + `
  FROM pgvigil.mssql_broker_queue q
  ` + brokerQueueStatusJoins + `
 WHERE q.instance_id = $1 AND q.database_name = $2::text
 ORDER BY q.is_present DESC, q.schema_name, q.queue_name`

// the database and transmission / conversation thresholds at DBA Dash's root defaults (control audit D4 a; D4 b's table
// replaces them): the oldest message waiting to be sent 15 minutes a warning and 60 critical, 100,000 open
// conversations a warning (no critical)
const brokerTQAgeWarningMins, brokerTQAgeCriticalMins, brokerConversationWarning = 15, 60, 100000

// sqlBrokerDatabases (control audit D4 a; DBA Dash's ServiceBrokerDatabaseInfo L109-120): each database of instance $1
// the broker store knows - its transmission queue (the messages, those with a status, the oldest and its age in
// minutes as DATEDIFF(mi) counts them), its conversations by state ('??' a total over the scan cap: its states then
// unknown), the activation tasks aborted in the newest hour of the Broker Activation samples (the cumulative counter's
// growth) - and database_status: the worst of the transmission age, the conversation count, conversations in error and
// aborted activations, 4 when none, with its issues.
var sqlBrokerDatabases = fmt.Sprintf(`
WITH dbs AS (
  SELECT database_name FROM pgvigil.mssql_broker_read WHERE instance_id = $1
  UNION SELECT database_name FROM pgvigil.mssql_broker_transmission WHERE instance_id = $1
  UNION SELECT database_name FROM pgvigil.mssql_broker_conversation WHERE instance_id = $1
  UNION SELECT database_name FROM pgvigil.mssql_broker_queue WHERE instance_id = $1 AND is_present
), tq AS (
  SELECT t.database_name, sum(t.message_count) AS transmission_queue_count,
         coalesce(sum(t.message_count) FILTER (WHERE t.transmission_status <> ''), 0) AS transmission_queue_error_count,
         min(t.oldest_enqueue_at) AS oldest_enqueue_at, max(t.snapshot_at) AS snapshot_at
    FROM pgvigil.mssql_broker_transmission t WHERE t.instance_id = $1 GROUP BY 1
), cv AS (
  SELECT c.database_name, sum(c.conversation_count) AS conversation_count,
         CASE WHEN bool_or(c.state = '??') THEN NULL ELSE coalesce(sum(c.conversation_count) FILTER (WHERE c.state = 'CO'), 0) END AS conversing_count,
         CASE WHEN bool_or(c.state = '??') THEN NULL ELSE coalesce(sum(c.conversation_count) FILTER (WHERE c.state = 'DI'), 0) END AS disconnected_inbound_count,
         CASE WHEN bool_or(c.state = '??') THEN NULL ELSE coalesce(sum(c.conversation_count) FILTER (WHERE c.state = 'DO'), 0) END AS disconnected_outbound_count,
         CASE WHEN bool_or(c.state = '??') THEN NULL ELSE coalesce(sum(c.conversation_count) FILTER (WHERE c.state = 'ER'), 0) END AS error_count,
         CASE WHEN bool_or(c.state = '??') THEN NULL ELSE coalesce(sum(c.conversation_count) FILTER (WHERE c.state = 'CD'), 0) END AS closed_count
    FROM pgvigil.mssql_broker_conversation c WHERE c.instance_id = $1 GROUP BY 1
), act AS (
  SELECT s.instance_name AS database_name, greatest(max(s.cntr_value) - min(s.cntr_value), 0) AS tasks_aborted_1hr
    FROM pgvigil.mssql_broker_counter_sample s
   WHERE s.instance_id = $1 AND s.object = 'Broker Activation' AND s.counter_name = 'Tasks Aborted/sec'
     AND s.snapshot_at > (SELECT max(x.snapshot_at) FROM pgvigil.mssql_broker_counter_sample x WHERE x.instance_id = $1) - interval '1 hour'
   GROUP BY 1
)
SELECT d.database_name, tq.transmission_queue_count, tq.transmission_queue_error_count, tq.oldest_enqueue_at, ag.tq_age_mins,
       cv.conversation_count, cv.conversing_count, cv.disconnected_inbound_count, cv.disconnected_outbound_count, cv.error_count, cv.closed_count,
       act.tasks_aborted_1hr, st.transmission_status, st.conversation_status, st.error_conversation_status, st.activation_status,
       (SELECT min(x) FROM (VALUES (st.transmission_status), (st.conversation_status), (st.error_conversation_status), (st.activation_status), (4)) v(x)
         WHERE x <> 3) AS database_status,
       nullif(concat_ws('; ',
         CASE WHEN st.transmission_status IN (1, 2) THEN 'a message has waited ' || ag.tq_age_mins || ' minutes to be sent' END,
         CASE WHEN st.conversation_status IN (1, 2) THEN cv.conversation_count || ' open conversations: usually conversations not ended' END,
         CASE WHEN st.error_conversation_status = 2 THEN cv.error_count || ' conversations in error' END,
         CASE WHEN st.activation_status = 2 THEN act.tasks_aborted_1hr || ' activation tasks aborted in the last hour' END), '') AS issues
  FROM dbs d
  LEFT JOIN tq USING (database_name) LEFT JOIN cv USING (database_name) LEFT JOIN act USING (database_name)
  CROSS JOIN LATERAL (SELECT (extract(epoch FROM date_trunc('minute', tq.snapshot_at) - date_trunc('minute', tq.oldest_enqueue_at)) / 60)::int AS tq_age_mins) ag
  CROSS JOIN LATERAL (SELECT CASE WHEN ag.tq_age_mins >= %[2]d THEN 1 WHEN ag.tq_age_mins >= %[1]d THEN 2 ELSE 4 END AS transmission_status,
                             CASE WHEN cv.conversation_count >= %[3]d THEN 2 ELSE 4 END AS conversation_status,
                             CASE WHEN cv.error_count > 0 THEN 2 ELSE 4 END AS error_conversation_status,
                             CASE WHEN act.tasks_aborted_1hr > 0 THEN 2 ELSE 4 END AS activation_status) st
 ORDER BY database_status, d.database_name`, brokerTQAgeWarningMins, brokerTQAgeCriticalMins, brokerConversationWarning)

// sqlBrokerInstance (control audit D4 a; DBA Dash's ServiceBrokerInstanceInfo L65-103): instance $1's Service Broker in
// one row - its endpoint, the Broker Statistics' growth in the newest hour of samples, its queues' and databases' worst
// status and their critical / warning counts, endpoint_status (3 no endpoint; 2 not STARTED or failed logins),
// error_status (2 corrupted messages in the hour; 4 traffic; else 3) and service_broker_status - the worst of the
// four, 3 (N/A) with nothing to report - with its issues (the counts first, then the instance's own).
var sqlBrokerInstance = `
WITH ep AS (
  SELECT e.* FROM pgvigil.mssql_broker_endpoint e WHERE e.instance_id = $1 ORDER BY e.snapshot_at DESC LIMIT 1
), win AS (
  SELECT max(x.snapshot_at) - interval '1 hour' AS since FROM pgvigil.mssql_broker_counter_sample x WHERE x.instance_id = $1
), st AS (
  SELECT ` + brokerGrowth("SQL SEND Total", "sends_1hr") + `, ` + brokerGrowth("SQL RECEIVE Total", "receives_1hr") + `,
         ` + brokerGrowth("Enqueued Messages Total", "enqueued_messages_1hr") + `, ` + brokerGrowth("Activation Errors Total", "activation_errors_1hr") + `,
         ` + brokerGrowth("Dropped Messages Total", "dropped_messages_1hr") + `, ` + brokerGrowth("Corrupted Messages Total", "corrupted_messages_1hr") + `,
         ` + brokerGrowth("Broker Transaction Rollbacks", "transaction_rollbacks_1hr") + `
    FROM pgvigil.mssql_broker_counter_sample s, win
   WHERE s.instance_id = $1 AND s.object = 'Broker Statistics' AND s.snapshot_at > win.since
), q AS (
  SELECT count(*) AS queue_count, sum(qs.message_count) AS queue_message_count, min(qs.queue_status) AS queue_status,
         count(*) FILTER (WHERE qs.queue_status = 1) AS critical_count, count(*) FILTER (WHERE qs.queue_status = 2) AS warning_count
    FROM (SELECT q.message_count, ` + brokerQueueStatusCols + `
            FROM pgvigil.mssql_broker_queue q
            ` + brokerQueueStatusJoins + `
           WHERE q.instance_id = $1 AND q.is_present) qs
), d AS (
  SELECT sum(db.transmission_queue_count) AS transmission_queue_count, sum(db.conversation_count) AS conversation_count,
         min(db.database_status) AS database_status,
         count(*) FILTER (WHERE db.database_status = 1) AS critical_count, count(*) FILTER (WHERE db.database_status = 2) AS warning_count,
         count(*) FILTER (WHERE db.transmission_queue_count > 0 OR db.conversation_count > 0) AS active_count
    FROM (` + sqlBrokerDatabases + `) db
)
SELECT ep.endpoint_name, ep.state_desc AS endpoint_state, ep.port AS endpoint_port, ep.connection_count, ep.connected_count, ep.login_failed_count,
       ep.last_activity_at, st.*, q.queue_count, q.queue_message_count, d.transmission_queue_count, d.conversation_count,
       q.queue_status, d.database_status, c.endpoint_status, c.error_status,
       coalesce((SELECT min(x) FROM (VALUES (CASE WHEN q.queue_count > 0 THEN q.queue_status END),
                                            (CASE WHEN d.active_count > 0 OR d.database_status < 4 THEN d.database_status END),
                                            (c.endpoint_status), (c.error_status)) v(x) WHERE x <> 3), 3) AS service_broker_status,
       nullif(concat_ws('; ',
         CASE WHEN q.critical_count > 0 OR q.warning_count > 0 THEN 'Queues: ' || concat_ws(', ', CASE WHEN q.critical_count > 0 THEN q.critical_count || ' critical' END,
                                                                               CASE WHEN q.warning_count > 0 THEN q.warning_count || ' warning' END) END,
         CASE WHEN d.critical_count > 0 OR d.warning_count > 0 THEN 'Databases: ' || concat_ws(', ', CASE WHEN d.critical_count > 0 THEN d.critical_count || ' critical' END,
                                                                                  CASE WHEN d.warning_count > 0 THEN d.warning_count || ' warning' END) END,
         CASE WHEN ep.endpoint_name IS NOT NULL AND ep.state_desc <> 'STARTED' THEN 'the Service Broker endpoint is ' || ep.state_desc END,
         CASE WHEN ep.login_failed_count > 0 THEN 'Service Broker endpoint connections have failed to log in' END,
         CASE WHEN st.corrupted_messages_1hr > 0 THEN st.corrupted_messages_1hr || ' corrupted messages in the last hour' END), '') AS issues
  FROM st CROSS JOIN q CROSS JOIN d LEFT JOIN ep ON true
  CROSS JOIN LATERAL (SELECT CASE WHEN ep.endpoint_name IS NULL THEN 3 WHEN ep.state_desc <> 'STARTED' OR ep.login_failed_count > 0 THEN 2 ELSE 4 END AS endpoint_status,
                             CASE WHEN st.corrupted_messages_1hr > 0 THEN 2
                                  WHEN st.sends_1hr > 0 OR st.receives_1hr > 0 OR st.enqueued_messages_1hr > 0 THEN 4 ELSE 3 END AS error_status) c`

// brokerGrowth: one cumulative Broker Statistics counter's growth over the hour's samples (alias s), never below 0 (a
// restart resets it)
func brokerGrowth(counter, as string) string {
	return "greatest(max(s.cntr_value) FILTER (WHERE s.counter_name = '" + counter + "') - min(s.cntr_value) FILTER (WHERE s.counter_name = '" + counter + "'), 0) AS " + as
}

// DBA Dash's Service Broker thresholds at its ROOT DEFAULTS (Script.PostDeployment1.sql L2188-2210; control audit D4 a):
// a queue 10,000 messages deep is a warning (no critical), its oldest message waiting 15 minutes a warning and 60
// critical. D4 b's thresholds table (Root / Instance / Database / Queue) replaces them.
const brokerDepthWarning, brokerAgeWarningMins, brokerAgeCriticalMins = 10000, 15, 60

// brokerQueueStatusJoins / brokerQueueStatusCols (control audit D4 a; DBA Dash's ServiceBrokerQueueInfo L71-145): a
// queue's minutes (DATEDIFF(mi) as DBA Dash counts them: minute boundaries crossed) and its checks - disabled (receive
// or enqueue off: a poison message, or ALTER QUEUE), the activation procedure missing, activation off with messages,
// activation notified 10 minutes or more with messages and nothing received, the depth and the oldest message's age
// against the thresholds (an unread RETENTION depth or an unread age is N/A, 3) - and queue_status: 1 Critical, 2
// Warning, 4 OK (DBA Dash's numbers); readers_status 2 when every activated reader is busy with messages waiting (not in
// the status, as DBA Dash); issues the checks' words, NULL when none.
var brokerQueueStatusJoins = fmt.Sprintf(`CROSS JOIN LATERAL (SELECT
         CASE WHEN q.message_count > 0 THEN (extract(epoch FROM date_trunc('minute', q.snapshot_at) - date_trunc('minute', q.oldest_message_at)) / 60)::int END AS age_mins,
         CASE WHEN q.monitor_state = 'NOTIFIED' THEN (extract(epoch FROM date_trunc('minute', q.snapshot_at) - date_trunc('minute', q.monitor_last_activated)) / 60)::int END AS notified_mins) bm
  CROSS JOIN LATERAL (SELECT
         coalesce(NOT q.is_receive_enabled OR NOT q.is_enqueue_enabled, false) AS disabled,
         coalesce(q.is_activation_enabled AND q.activation_procedure_exists = false, false) AS proc_missing,
         coalesce(NOT q.is_activation_enabled AND q.activation_procedure IS NOT NULL AND q.message_count > 0, false) AS act_off_msgs,
         coalesce(bm.notified_mins >= 10 AND q.message_count > 0 AND q.is_receive_enabled, false) AS not_receiving,
         CASE WHEN q.message_count IS NULL THEN 3 WHEN q.message_count >= %[1]d THEN 2 ELSE 4 END AS depth_status,
         CASE WHEN bm.age_mins >= %[3]d THEN 1 WHEN bm.age_mins >= %[2]d THEN 2 WHEN bm.age_mins IS NULL AND q.message_count > 0 THEN 3 ELSE 4 END AS age_status) bk
  CROSS JOIN LATERAL (SELECT CASE WHEN bk.proc_missing AND q.message_count > 0 THEN 1
                                  WHEN bk.proc_missing OR bk.act_off_msgs OR bk.not_receiving THEN 2 ELSE 4 END AS activation_status) ba`,
	brokerDepthWarning, brokerAgeWarningMins, brokerAgeCriticalMins)

const brokerQueueStatusCols = `bm.age_mins AS oldest_age_mins, bm.notified_mins, bk.depth_status, bk.age_status, ba.activation_status,
       CASE WHEN bk.disabled OR ba.activation_status = 1 OR bk.depth_status = 1 OR bk.age_status = 1 THEN 1
            WHEN ba.activation_status = 2 OR bk.depth_status = 2 OR bk.age_status = 2 THEN 2 ELSE 4 END AS queue_status,
       CASE WHEN q.is_activation_enabled AND q.max_readers > 0 AND q.activated_tasks >= q.max_readers AND q.message_count > 0 THEN 2 ELSE 4 END AS readers_status,
       nullif(concat_ws('; ',
         CASE WHEN bk.disabled THEN CASE WHEN coalesce(q.is_poison_handling, true)
           THEN 'The queue is disabled - messages can be neither added nor received; usually a poison message (a RECEIVE rolled back 5 times in a row): deal with the message, then ALTER QUEUE ' || q.schema_name || '.' || q.queue_name || ' WITH STATUS = ON'
           ELSE 'The queue is disabled (STATUS = OFF) and poison message handling is off, so ALTER QUEUE disabled it: ALTER QUEUE ' || q.schema_name || '.' || q.queue_name || ' WITH STATUS = ON' END END,
         CASE WHEN bk.proc_missing THEN 'the activation procedure does not exist' END,
         CASE WHEN bk.act_off_msgs THEN 'activation is disabled with messages waiting' END,
         CASE WHEN bk.not_receiving THEN 'activation was notified ' || bm.notified_mins || ' minutes ago but nothing has received from the queue: check that the activation procedure RECEIVEs from it' END,
         CASE WHEN bk.age_status IN (1, 2) THEN 'the oldest message has waited ' || bm.age_mins || ' minutes' END,
         CASE WHEN bk.depth_status IN (1, 2) THEN 'the queue depth ' || q.message_count || ' is over the warning threshold' END), '') AS issues`

// the depth samples of the window, oldest first - the NEWEST 20,000 when the window holds more (review t11-8 item 6:
// the page says so when the reply is that long)
const sqlMSSQLChecksBrokerDepth = `
SELECT x.* FROM (
  SELECT s.snapshot_at, s.schema_name, s.queue_name, s.message_count, s.activated_tasks
    FROM pgvigil.mssql_broker_queue_sample s
   WHERE s.instance_id = $1 AND s.database_name = $2::text AND s.snapshot_at > $3 AND s.snapshot_at <= $4
   ORDER BY s.snapshot_at DESC, s.schema_name, s.queue_name
   LIMIT 20000) x
 ORDER BY x.snapshot_at, x.schema_name, x.queue_name`

// the database's read state (review t11-8 item 3): when it was last read, and why not or what the read left out
const sqlMSSQLChecksBrokerRead = `
SELECT r.read_at, r.note, r.snapshot_at
  FROM pgvigil.mssql_broker_read r
 WHERE r.instance_id = $1 AND r.database_name = $2::text`

const sqlMSSQLChecksBrokerTransmission = `
SELECT t.to_service_name, t.transmission_status, t.message_count, t.oldest_enqueue_at, t.snapshot_at
  FROM pgvigil.mssql_broker_transmission t
 WHERE t.instance_id = $1 AND t.database_name = $2::text
 ORDER BY t.message_count DESC NULLS LAST, t.to_service_name`

const sqlMSSQLChecksBrokerConversations = `
SELECT c.state, c.conversation_count, c.snapshot_at
  FROM pgvigil.mssql_broker_conversation c
 WHERE c.instance_id = $1 AND c.database_name = $2::text
 ORDER BY c.conversation_count DESC NULLS LAST, c.state`

const sqlMSSQLChecksBrokerEndpoint = `
SELECT e.endpoint_name, e.state_desc, e.port, e.connection_count, e.connected_count, e.login_failed_count, e.last_activity_at, e.snapshot_at
  FROM pgvigil.mssql_broker_endpoint e
 WHERE e.instance_id = $1
 ORDER BY e.endpoint_name`

// the counters as rates: each sample's difference from the sample before, over the seconds between them; none where
// the value fell (the instance restarted: the counters start again) or for the window's first sample; oldest first,
// the NEWEST 20,000 when the window holds more (review t11-8 item 6); none without a database (item 15: the Checks
// page asks with an empty db= and draws none of them)
const sqlMSSQLChecksBrokerCounters = `
SELECT y.* FROM (
  SELECT x.snapshot_at, x.object, x.instance_name, x.counter_name,
         round(((x.cntr_value - x.prev_value) / nullif(extract(epoch FROM x.snapshot_at - x.prev_at), 0))::numeric, 2)::float8 AS per_sec
    FROM (SELECT c.snapshot_at, c.object, c.instance_name, c.counter_name, c.cntr_value,
                 lag(c.cntr_value) OVER w AS prev_value, lag(c.snapshot_at) OVER w AS prev_at
            FROM pgvigil.mssql_broker_counter_sample c
           WHERE c.instance_id = $1 AND c.snapshot_at > $3 AND c.snapshot_at <= $4 AND $2::text <> ''
          WINDOW w AS (PARTITION BY c.object, c.instance_name, c.counter_name ORDER BY c.snapshot_at)) x
   WHERE x.prev_value IS NOT NULL AND x.cntr_value >= x.prev_value AND (x.object = 'Broker Statistics' OR x.instance_name = $2::text)
   ORDER BY x.snapshot_at DESC, x.object, x.counter_name, x.instance_name
   LIMIT 20000) y
 ORDER BY y.snapshot_at, y.object, y.counter_name, y.instance_name`

const sqlMSSQLChecksScopedChanges = `
SELECT x.name, x.changed_at, x.old_value, x.new_value
  FROM pgvigil.mssql_db_scoped_config_change x
 WHERE x.instance_id = $1 AND x.database_name = $2::text
 ORDER BY x.changed_at DESC, x.name
 LIMIT 500`

const sqlMSSQLChecksColumns = `
SELECT c.ord, c.value->>'key' AS key, c.value->>'label' AS label, c.value->>'best' AS best
  FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY c(value, ord)
 ORDER BY c.ord`

const sqlMSSQLChecksSuspect = `
SELECT s.database_name, s.file_id, s.page_id, s.event_type, s.event, s.error_count, s.last_update_at
  FROM pgvigil.mssql_suspect_page s
 WHERE s.instance_id = $1
 ORDER BY s.last_update_at DESC NULLS LAST
 LIMIT 1000`

const sqlMSSQLChecksAlerts = `
SELECT a.name, a.severity, a.message_id, a.enabled, a.notifies, a.has_job, a.include_event_description, a.delay_s,
       a.occurrence_count, a.last_occurrence_at
  FROM pgvigil.mssql_agent_alert a
 WHERE a.instance_id = $1
 ORDER BY coalesce(a.severity, 0) = 0, a.severity, a.message_id, a.name`

const sqlMSSQLChecksOperators = `
SELECT o.name, o.enabled, o.has_email, o.last_email_at
  FROM pgvigil.mssql_agent_operator o
 WHERE o.instance_id = $1
 ORDER BY o.name`

const sqlMSSQLChecksAlerting = `
SELECT g.failsafe_read, g.failsafe_operator, g.snapshot_at
  FROM pgvigil.mssql_agent_alerting g
 WHERE g.instance_id = $1`

const sqlMSSQLChecksIdentity = `
SELECT c.database_name, c.schema_name, c.table_name, c.column_name, c.type_name, c.last_value, c.max_value, c.pct_used,
       c.status, c.per_day, c.days_left, c.snapshot_at
  FROM pgvigil.mssql_identity_column c
 WHERE c.instance_id = $1
 ORDER BY c.pct_used DESC, c.database_name, c.schema_name, c.table_name
 LIMIT 500`

const sqlMSSQLChecksIdentityScan = `
SELECT s.database_name, s.scanned, s.columns_total, s.listed, s.note, s.scanned_at, s.snapshot_at
  FROM pgvigil.mssql_identity_scan s
 WHERE s.instance_id = $1
 ORDER BY s.scanned, s.database_name`

// databaseColumnsJSON is the collector package's grid columns as the one jsonb argument of sqlMSSQLChecksColumns.
func databaseColumnsJSON() (string, error) {
	b, err := json.Marshal(mssql.DatabaseOptions())
	return string(b), err
}

// sqlMSSQLChecksBuildDocs: the build's documentation links (task 412), made in Go from the binary's catalogue at serve
// time and handed in as one jsonb argument (as the columns part); one row, nulls when the catalogue cannot place it
const sqlMSSQLChecksBuildDocs = `
SELECT d.build_url, d.build_url_words, d.newest_build, d.newest_url, d.newest_url_words
  FROM jsonb_to_record($1::jsonb) AS d(build_url text, build_url_words text, newest_build text, newest_url text, newest_url_words text)`

// MSSQLChecks is GET /api/mssql/checks?instance=N[&part=...]: the state as last read; no window.
func (s *Server) MSSQLChecks(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// task 412: the version the instance last reported (the first line of @@VERSION), for its build's links (no row: no links)
	var ver string
	if err := s.pool.QueryRow(r.Context(), `SELECT coalesce(server_version, '') FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&ver); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	docs, err := json.Marshal(mssql.BuildDocsOf(ver))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	cols, err := databaseColumnsJSON()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_checks", "mssql_identity", "mssql_traceflags"}}},
		{"areas", sqlMSSQLChecksAreas, []any{id}},
		{"findings", sqlMSSQLChecksFindings, []any{id}},
		{"options", sqlMSSQLChecksOptions, []any{id}},
		{"flags", sqlMSSQLChecksFlags, []any{id}},
		{"build", sqlMSSQLChecksBuild, []any{id}},
		{"build_docs", sqlMSSQLChecksBuildDocs, []any{string(docs)}},
		{"databases", sqlMSSQLChecksDatabases, []any{id, r.URL.Query().Get("db")}}, // db=: one database's row (P25 DB Options)
		{"columns", sqlMSSQLChecksColumns, []any{cols}},
		{"suspect", sqlMSSQLChecksSuspect, []any{id}},
		{"alerts", sqlMSSQLChecksAlerts, []any{id}},
		{"operators", sqlMSSQLChecksOperators, []any{id}},
		{"alerting", sqlMSSQLChecksAlerting, []any{id}},
		{"identity", sqlMSSQLChecksIdentity, []any{id}},
		{"identity_scan", sqlMSSQLChecksIdentityScan, []any{id}},
		// db=: one database's scoped configuration and its changes (P25 row 2a; none without db=)
		{"scoped_config", sqlMSSQLChecksScopedConfig, []any{id, r.URL.Query().Get("db")}},
		{"scoped_changes", sqlMSSQLChecksScopedChanges, []any{id, r.URL.Query().Get("db")}},
		// db=: one database's Service Broker (P25 row 73); the depth and the counters over the window
		{"broker_state", sqlMssqlRunningState, []any{id, []string{"mssql_service_broker"}}},
		{"broker_queues", sqlMSSQLChecksBrokerQueues, []any{id, r.URL.Query().Get("db")}},
		// control audit D4 a: DBA Dash's database and instance statuses (the report's Databases and Instances grids, the
		// Summary's cell)
		{"broker_databases", sqlBrokerDatabases, []any{id}},
		{"broker_instance", sqlBrokerInstance, []any{id}},
		{"broker_depth", sqlMSSQLChecksBrokerDepth, []any{id, r.URL.Query().Get("db"), from, to}},
		{"broker_transmission", sqlMSSQLChecksBrokerTransmission, []any{id, r.URL.Query().Get("db")}},
		{"broker_conversations", sqlMSSQLChecksBrokerConversations, []any{id, r.URL.Query().Get("db")}},
		{"broker_endpoint", sqlMSSQLChecksBrokerEndpoint, []any{id}},
		{"broker_counters", sqlMSSQLChecksBrokerCounters, []any{id, r.URL.Query().Get("db"), from, to}},
		{"broker_read", sqlMSSQLChecksBrokerRead, []any{id, r.URL.Query().Get("db")}},
	})
}

const sqlMSSQLChecksFleetRisks = `
SELECT r.* FROM pgvigil.mssql_option_risks r ORDER BY lower(r.instance_name)`

const sqlMSSQLChecksFleetCells = `
SELECT s.instance_id, s.key AS area, s.sampled, s.critical, s.warning, s.value, s.detail, s.read_at
  FROM pgvigil.mssql_checks_status s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.engine = 'sqlserver' AND i.is_active
 ORDER BY s.instance_id, s.key`

// the pivot's rows: every present option of every active instance (a few hundred rows per instance at most)
const sqlMSSQLChecksFleetOptions = `
SELECT o.instance_id, o.name, o.value_in_use, o.default_value, o.status, o.severity, o.rule, o.detail
  FROM pgvigil.mssql_server_option o
  JOIN pgvigil.instances i ON i.instance_id = o.instance_id AND i.engine = 'sqlserver' AND i.is_active
 WHERE o.is_present
 ORDER BY lower(o.name), o.instance_id`

// MSSQLChecksFleet is GET /api/mssql/checks/fleet[?part=...].
func (s *Server) MSSQLChecksFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{
		{"risks", sqlMSSQLChecksFleetRisks, nil},
		{"cells", sqlMSSQLChecksFleetCells, nil},
		{"options", sqlMSSQLChecksFleetOptions, nil},
	})
}
