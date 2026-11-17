-- 0392: SQL Server Service Broker (P25 row 73, DBA Dash's database Service Broker tab: Checks.ServiceBrokerView over
-- ServiceBrokerReport_Get, collected by DBADash/SQL/SQLServiceBroker.sql). The collection mssql_service_broker reads,
-- every 5 minutes, each online database it may enter that has the broker on and a user queue (never an availability
-- group secondary; at most the database cap, the words above it), and sends one row per:
--   'database'      a database the read visited (its queues, transmission groups and conversations are this read's)
--   'unread'        a database it did not enter, with why (its rows stay as they were)
--   'queue'         a user queue: its settings, depth (the internal table's rows, never a COUNT of the queue), the
--                   readers running, the queue monitor's state and the oldest message ready to receive
--   'transmission'  a transmission queue group of a database: target service and status, its count and oldest enqueue
--   'conversation'  a database's conversation endpoints counted by state
--   'endpoint'      the instance's Service Broker endpoint and its connections ('endpoints_read' with no row: none)
--   'counter'       a cumulative Broker Statistics / Broker Activation counter (the page charts its differences)
-- into:
--   mssql_broker_queue          per instance, database, schema and queue, as last read (a queue gone: not present)
--   mssql_broker_queue_sample   each queue's depth and readers per read (monthly partitions: the depth chart)
--   mssql_broker_transmission   per instance, database, target service and status, as last read
--   mssql_broker_conversation   per instance, database and state, as last read
--   mssql_broker_endpoint       per instance and endpoint, as last read
--   mssql_broker_counter_sample each counter's cumulative value per read (monthly partitions)
-- THE JOIN-FILE RULE: 0392 sorts after the join file and creates only its own objects. Its lines for the join are in
-- scripts/PARITY-S3-join-lines.sql (line 12): every table under the instance scope's policy; purge of the two sample
-- tables with the instance's retention (the lead's Q2); no grant line (apply_roles makes every import_ function the
-- collector's door).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_broker_queue (
  instance_id                 int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name               text NOT NULL,
  schema_name                 text NOT NULL,
  queue_name                  text NOT NULL,
  object_id                   int,
  is_receive_enabled          boolean,          -- false: receive disabled (a poison message, DBA Dash's red)
  is_enqueue_enabled          boolean,
  is_retention_enabled        boolean,
  is_activation_enabled       boolean,
  is_poison_handling          boolean,
  activation_procedure        text,
  activation_procedure_exists boolean,          -- NULL: no activation procedure
  max_readers                 int,
  message_count               bigint,           -- NULL: a RETENTION queue not read (its internal table also holds received messages)
  activated_tasks             int,
  monitor_state               text,             -- sys.dm_broker_queue_monitors: INACTIVE, NOTIFIED, RECEIVES_OCCURRING
  monitor_tasks_waiting       int,
  monitor_last_activated      timestamptz,
  monitor_last_empty          timestamptz,
  oldest_message_at           timestamptz,      -- the oldest message ready to receive (status 1), NULL: none or not read
  note                        text,             -- why the database's last read did not read it
  first_seen                  timestamptz NOT NULL,
  snapshot_at                 timestamptz NOT NULL,
  is_present                  boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_name, schema_name, queue_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_broker_queue_sample (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at      timestamptz NOT NULL,
  database_name    text NOT NULL,
  schema_name      text NOT NULL,
  queue_name       text NOT NULL,
  message_count    bigint,
  activated_tasks  int,
  PRIMARY KEY (instance_id, snapshot_at, database_name, schema_name, queue_name)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_broker_transmission (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name        text NOT NULL,
  to_service_name      text NOT NULL,
  transmission_status  text NOT NULL,         -- '' = not sent yet (Microsoft: blank)
  message_count        bigint,
  oldest_enqueue_at    timestamptz,
  snapshot_at          timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, to_service_name, transmission_status)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_broker_conversation (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name       text NOT NULL,
  state               text NOT NULL,          -- sys.conversation_endpoints.state (CO, DI, DO, ER, SI, SO, CD; '??' a total over the scan cap)
  conversation_count  bigint,
  snapshot_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, state)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_broker_endpoint (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  endpoint_name       text NOT NULL,
  state_desc          text,
  port                int,
  connection_count    int,
  connected_count     int,
  login_failed_count  int,
  last_activity_at    timestamptz,
  snapshot_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, endpoint_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_broker_counter_sample (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at    timestamptz NOT NULL,
  object         text NOT NULL,              -- Broker Statistics or Broker Activation
  instance_name  text NOT NULL,              -- Broker Activation's database; '' for Broker Statistics
  counter_name   text NOT NULL,
  cntr_value     bigint,                     -- cumulative since the instance started
  PRIMARY KEY (instance_id, snapshot_at, object, instance_name, counter_name)
) PARTITION BY RANGE (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_service_broker(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_dbs text[] := ARRAY(SELECT DISTINCT r->>'database_name' FROM jsonb_array_elements(p_payload) r
                         WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgvigil.instances WHERE instance_id = p_instance_id AND engine = 'sqlserver') THEN
    RAISE EXCEPTION 'import_mssql_service_broker: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pgvigil.ensure_month_partition('mssql_broker_queue_sample', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_broker_counter_sample', p_snapshot_at);

  -- the queues: a visited database's queues are this read's; one it no longer holds is not present
  UPDATE pgvigil.mssql_broker_queue q SET is_present = false, snapshot_at = p_snapshot_at
   WHERE q.instance_id = p_instance_id AND q.is_present AND q.database_name = ANY (v_dbs)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'queue' AND r->>'database_name' = q.database_name
                        AND r->>'schema_name' = q.schema_name AND r->>'queue_name' = q.queue_name);
  INSERT INTO pgvigil.mssql_broker_queue AS q (instance_id, database_name, schema_name, queue_name, object_id, is_receive_enabled,
         is_enqueue_enabled, is_retention_enabled, is_activation_enabled, is_poison_handling, activation_procedure,
         activation_procedure_exists, max_readers, message_count, activated_tasks, monitor_state, monitor_tasks_waiting,
         monitor_last_activated, monitor_last_empty, oldest_message_at, note, first_seen, snapshot_at, is_present)
  SELECT p_instance_id, r->>'database_name', r->>'schema_name', r->>'queue_name', (r->>'object_id')::int,
         (r->>'is_receive_enabled')::boolean, (r->>'is_enqueue_enabled')::boolean, (r->>'is_retention_enabled')::boolean,
         (r->>'is_activation_enabled')::boolean, (r->>'is_poison_message_handling_enabled')::boolean, r->>'activation_procedure',
         (r->>'activation_procedure_exists')::boolean, (r->>'max_readers')::int, (r->>'message_count')::bigint,
         (r->>'activated_tasks')::int, r->>'monitor_state', (r->>'monitor_tasks_waiting')::int,
         (r->>'monitor_last_activated_time')::timestamptz, (r->>'monitor_last_empty_rowset_time')::timestamptz,
         (r->>'oldest_message_time')::timestamptz, NULL, p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'queue' AND r->>'database_name' IS NOT NULL AND r->>'schema_name' IS NOT NULL AND r->>'queue_name' IS NOT NULL
  ON CONFLICT (instance_id, database_name, schema_name, queue_name) DO UPDATE
     SET object_id = EXCLUDED.object_id, is_receive_enabled = EXCLUDED.is_receive_enabled, is_enqueue_enabled = EXCLUDED.is_enqueue_enabled,
         is_retention_enabled = EXCLUDED.is_retention_enabled, is_activation_enabled = EXCLUDED.is_activation_enabled,
         is_poison_handling = EXCLUDED.is_poison_handling, activation_procedure = EXCLUDED.activation_procedure,
         activation_procedure_exists = EXCLUDED.activation_procedure_exists, max_readers = EXCLUDED.max_readers,
         message_count = EXCLUDED.message_count, activated_tasks = EXCLUDED.activated_tasks, monitor_state = EXCLUDED.monitor_state,
         monitor_tasks_waiting = EXCLUDED.monitor_tasks_waiting, monitor_last_activated = EXCLUDED.monitor_last_activated,
         monitor_last_empty = EXCLUDED.monitor_last_empty, oldest_message_at = EXCLUDED.oldest_message_at, note = NULL,
         snapshot_at = EXCLUDED.snapshot_at, is_present = true;
  INSERT INTO pgvigil.mssql_broker_queue_sample (instance_id, snapshot_at, database_name, schema_name, queue_name, message_count, activated_tasks)
  SELECT p_instance_id, p_snapshot_at, r->>'database_name', r->>'schema_name', r->>'queue_name', (r->>'message_count')::bigint, (r->>'activated_tasks')::int
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'queue' AND r->>'database_name' IS NOT NULL AND r->>'schema_name' IS NOT NULL AND r->>'queue_name' IS NOT NULL
  ON CONFLICT DO NOTHING;

  -- the transmission groups and the conversation counts of a visited database: this read's rows replace its own
  DELETE FROM pgvigil.mssql_broker_transmission WHERE instance_id = p_instance_id AND database_name = ANY (v_dbs);
  INSERT INTO pgvigil.mssql_broker_transmission (instance_id, database_name, to_service_name, transmission_status, message_count, oldest_enqueue_at, snapshot_at)
  SELECT p_instance_id, r->>'database_name', coalesce(r->>'to_service_name', ''), coalesce(r->>'transmission_status', ''),
         (r->>'message_count')::bigint, (r->>'oldest_enqueue_time')::timestamptz, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'transmission' AND r->>'database_name' = ANY (v_dbs)
  ON CONFLICT (instance_id, database_name, to_service_name, transmission_status) DO UPDATE
     SET message_count = EXCLUDED.message_count, oldest_enqueue_at = EXCLUDED.oldest_enqueue_at, snapshot_at = EXCLUDED.snapshot_at;
  DELETE FROM pgvigil.mssql_broker_conversation WHERE instance_id = p_instance_id AND database_name = ANY (v_dbs);
  INSERT INTO pgvigil.mssql_broker_conversation (instance_id, database_name, state, conversation_count, snapshot_at)
  SELECT p_instance_id, r->>'database_name', r->>'state', (r->>'conversation_count')::bigint, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'conversation' AND r->>'database_name' = ANY (v_dbs) AND r->>'state' IS NOT NULL
  ON CONFLICT (instance_id, database_name, state) DO UPDATE
     SET conversation_count = EXCLUDED.conversation_count, snapshot_at = EXCLUDED.snapshot_at;

  -- a database the read did not enter: its rows stay as they were, the note says why
  UPDATE pgvigil.mssql_broker_queue q SET note = r->>'note'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'unread' AND q.instance_id = p_instance_id AND q.database_name = r->>'database_name' AND q.is_present;

  -- the endpoint: the read's rows replace the instance's when it read them (an 'endpoint' row or 'endpoints_read')
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' IN ('endpoint', 'endpoints_read')) THEN
    DELETE FROM pgvigil.mssql_broker_endpoint e
     WHERE e.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'endpoint' AND r->>'endpoint_name' = e.endpoint_name);
    INSERT INTO pgvigil.mssql_broker_endpoint AS e (instance_id, endpoint_name, state_desc, port, connection_count, connected_count,
                                                    login_failed_count, last_activity_at, snapshot_at)
    SELECT p_instance_id, r->>'endpoint_name', r->>'state_desc', (r->>'port')::int, (r->>'connection_count')::int,
           (r->>'connected_count')::int, (r->>'login_failed_count')::int, (r->>'last_activity_time')::timestamptz, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'endpoint' AND r->>'endpoint_name' IS NOT NULL
    ON CONFLICT (instance_id, endpoint_name) DO UPDATE
       SET state_desc = EXCLUDED.state_desc, port = EXCLUDED.port, connection_count = EXCLUDED.connection_count,
           connected_count = EXCLUDED.connected_count, login_failed_count = EXCLUDED.login_failed_count,
           last_activity_at = EXCLUDED.last_activity_at, snapshot_at = EXCLUDED.snapshot_at;
  END IF;

  INSERT INTO pgvigil.mssql_broker_counter_sample (instance_id, snapshot_at, object, instance_name, counter_name, cntr_value)
  SELECT p_instance_id, p_snapshot_at, coalesce(r->>'object', ''), coalesce(r->>'instance_name', ''), r->>'counter_name', (r->>'cntr_value')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'counter' AND r->>'counter_name' IS NOT NULL
  ON CONFLICT DO NOTHING;
END $$;
