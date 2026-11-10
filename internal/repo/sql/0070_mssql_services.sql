-- 0070: the SQL Server services read (collection mssql_services, internal/mssql/services.go): three columns of the
-- Summary that DBA Dash shows and pgvigil did not - is SQL Server Agent running, is Database Mail started, has the
-- server written a memory dump.
--   mssql_service   the current row per service the server lists (sys.dm_server_services)
--   mssql_health    one row per instance: Agent, Database Mail and memory dumps as last read
--   mssql_health_status  the three Summary cells judged from it
-- A part the login could not read keeps what an earlier read stored and says so in its *_read flag.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_service (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  service_name     text NOT NULL,
  startup_type     text,
  status           text,
  process_id       int,
  last_startup_at  timestamptz,
  service_account  text,
  is_clustered     boolean,
  ifi_enabled      boolean,
  snapshot_at      timestamptz NOT NULL,
  is_present       boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, service_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_health (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,
  -- SQL Server Agent: expected on every edition but Express; running by the service's own status where the server
  -- lists the service, else by Agent's own sessions (agent_source says which)
  agent_expected     boolean,
  agent_running      boolean,
  agent_source       text,
  agent_startup      text,
  agent_sessions     int,
  -- Database Mail: on = the 'Database Mail XPs' value in use; status STARTED / STOPPED as
  -- msdb.dbo.sysmail_help_status_sp decides it (the mail queue receives or not), NULL when not readable
  dbmail_on          boolean,
  dbmail_status      text,
  -- memory dumps the server lists (sys.dm_server_memory_dumps); a file without a usable creation time is counted
  -- and never dated
  dumps_read         boolean NOT NULL DEFAULT false,
  dump_count         int,
  last_dump_at       timestamptz
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_services(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_a jsonb;
  v_m jsonb;
  v_d jsonb;
  v_svc boolean;
  v_running boolean;
  v_source text;
  v_startup text;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_services: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT r INTO v_a FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'agent' LIMIT 1;
  SELECT r INTO v_m FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dbmail' LIMIT 1;
  SELECT r INTO v_d FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dumps' LIMIT 1;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'import_mssql_services: the payload has no agent row';
  END IF;
  v_svc := EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'service');

  INSERT INTO pgvigil.mssql_service AS s (instance_id, service_name, startup_type, status, process_id, last_startup_at,
      service_account, is_clustered, ifi_enabled, snapshot_at)
  SELECT p_instance_id, r->>'service_name', r->>'startup_type', r->>'status', (r->>'process_id')::int,
         (r->>'last_startup_at_utc')::timestamptz, r->>'service_account', r->>'is_clustered' = 'Y',
         CASE r->>'ifi_enabled' WHEN 'Y' THEN true WHEN 'N' THEN false END, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'service' AND r->>'service_name' IS NOT NULL
  ON CONFLICT (instance_id, service_name) DO UPDATE SET
      startup_type = EXCLUDED.startup_type, status = EXCLUDED.status, process_id = EXCLUDED.process_id,
      last_startup_at = EXCLUDED.last_startup_at, service_account = EXCLUDED.service_account,
      is_clustered = EXCLUDED.is_clustered, ifi_enabled = EXCLUDED.ifi_enabled, snapshot_at = EXCLUDED.snapshot_at,
      is_present = true
  WHERE s.snapshot_at <= EXCLUDED.snapshot_at;
  -- a service the server no longer lists stays as last read, marked gone (only when this read listed services)
  IF v_svc THEN
    UPDATE pgvigil.mssql_service s SET is_present = false
     WHERE s.instance_id = p_instance_id AND s.is_present AND s.snapshot_at < p_snapshot_at;
  END IF;

  -- the Agent's state: the service's own status when the server lists the service, else its sessions
  SELECT r->>'status' = 'Running', r->>'startup_type' INTO v_running, v_startup
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'service' AND r->>'service_name' LIKE 'SQL Server Agent%' LIMIT 1;
  IF FOUND THEN
    v_source := 'service';
  ELSE
    v_running := (v_a->>'sessions')::int > 0;
    v_source := 'sessions';
  END IF;

  INSERT INTO pgvigil.mssql_health AS h (instance_id, snapshot_at, agent_expected, agent_running, agent_source, agent_startup,
      agent_sessions, dbmail_on, dbmail_status, dumps_read, dump_count, last_dump_at)
  VALUES (p_instance_id, p_snapshot_at, (v_a->>'engine_edition')::int IS DISTINCT FROM 4, v_running, v_source, v_startup,
      (v_a->>'sessions')::int, (v_m->>'xps_in_use')::int = 1,
      CASE WHEN v_m IS NULL OR (v_m->>'xps_in_use')::int IS DISTINCT FROM 1 THEN NULL
           WHEN (v_m->>'queues_seen')::int = 0 THEN NULL
           WHEN (v_m->>'receive_enabled')::int > 0 THEN 'STARTED' ELSE 'STOPPED' END,
      v_d IS NOT NULL, (v_d->>'dump_count')::int, (v_d->>'last_dump_at_utc')::timestamptz)
  ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, agent_expected = EXCLUDED.agent_expected, agent_running = EXCLUDED.agent_running,
      agent_source = EXCLUDED.agent_source, agent_startup = EXCLUDED.agent_startup, agent_sessions = EXCLUDED.agent_sessions,
      dbmail_on = EXCLUDED.dbmail_on, dbmail_status = EXCLUDED.dbmail_status, dumps_read = EXCLUDED.dumps_read,
      -- a read that could not list the dumps keeps what an earlier read stored
      dump_count = CASE WHEN EXCLUDED.dumps_read THEN EXCLUDED.dump_count ELSE h.dump_count END,
      last_dump_at = CASE WHEN EXCLUDED.dumps_read THEN EXCLUDED.last_dump_at ELSE h.last_dump_at END
  WHERE h.snapshot_at <= EXCLUDED.snapshot_at;
END $$;

-- The three Summary cells of the services read, one row per instance and key: sampled = the part was read,
-- critical / warning 0 or 1, value the cell's word, detail the sentence behind it. (internal/web reads it for
-- GET /api/mssql/summary; a NULL comparison counts as not flagged.)
CREATE OR REPLACE VIEW pgvigil.mssql_health_status AS
SELECT x.instance_id, x.key, x.sampled, coalesce(x.critical, 0) AS critical, coalesce(x.warning, 0) AS warning, x.value, x.detail
  FROM (
-- SQL Server Agent: stopped is critical, stopped with the service disabled a warning; Express has no Agent
SELECT h.instance_id, 'agent'::text AS key, true AS sampled,
       (h.agent_expected AND NOT h.agent_running AND h.agent_startup IS DISTINCT FROM 'Disabled')::int AS critical,
       (h.agent_expected AND NOT h.agent_running AND h.agent_startup IS NOT DISTINCT FROM 'Disabled')::int AS warning,
       CASE WHEN NOT h.agent_expected THEN 'none (Express)'
            WHEN h.agent_running THEN 'running' WHEN h.agent_startup = 'Disabled' THEN 'disabled' ELSE 'stopped' END AS value,
       CASE WHEN NOT h.agent_expected THEN ARRAY['SQL Server Express has no SQL Server Agent']
            ELSE ARRAY['SQL Server Agent is ' || CASE WHEN h.agent_running THEN 'running' ELSE 'NOT running: no job runs, no backup, no alert' END
                       || CASE WHEN h.agent_source = 'service' THEN ' (the service''s own state' || coalesce(', start mode ' || lower(h.agent_startup), '') || ')'
                               ELSE ' (judged by its sessions: ' || coalesce(h.agent_sessions, 0) || ' open; the server lists no Agent service)' END
                       || ', read ' || to_char(h.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'] END AS detail
  FROM pgvigil.mssql_health h
UNION ALL
-- Database Mail: switched on and stopped is a warning; switched off is a choice, not a fault
SELECT h.instance_id, 'dbmail', h.dbmail_on IS NOT NULL,
       0, (h.dbmail_on AND h.dbmail_status = 'STOPPED')::int,
       CASE WHEN h.dbmail_on IS NULL THEN NULL WHEN NOT h.dbmail_on THEN 'off'
            WHEN h.dbmail_status IS NULL THEN 'not readable' ELSE lower(h.dbmail_status) END,
       CASE WHEN h.dbmail_on IS NULL THEN '{}'::text[]
            WHEN NOT h.dbmail_on THEN ARRAY['Database Mail is switched off on this server (Database Mail XPs = 0)']
            WHEN h.dbmail_status IS NULL THEN ARRAY['Database Mail is switched on; the login cannot see the mail queue in msdb, so started or stopped is unknown']
            WHEN h.dbmail_status = 'STOPPED' THEN ARRAY['Database Mail is STOPPED: the mail queue does not receive, so nothing is sent (msdb.dbo.sysmail_start_sp starts it)']
            ELSE ARRAY['Database Mail is started'] END
  FROM pgvigil.mssql_health h
UNION ALL
-- memory dumps, DBA Dash's defaults: critical when the newest is under 48 hours old, warning under 7 days
SELECT h.instance_id, 'dumps', h.dumps_read,
       (h.dumps_read AND h.last_dump_at > now() - interval '48 hours')::int,
       (h.dumps_read AND h.last_dump_at <= now() - interval '48 hours' AND h.last_dump_at > now() - interval '7 days')::int,
       CASE WHEN NOT coalesce(h.dumps_read, false) THEN NULL WHEN coalesce(h.dump_count, 0) = 0 THEN 'none' ELSE h.dump_count || ' file' || CASE WHEN h.dump_count = 1 THEN '' ELSE 's' END END,
       CASE WHEN NOT coalesce(h.dumps_read, false) THEN '{}'::text[]
            WHEN coalesce(h.dump_count, 0) = 0 THEN ARRAY['the server lists no memory dump file']
            ELSE ARRAY[h.dump_count || ' memory dump file(s) on the server; the newest '
                       || coalesce('written ' || to_char(h.last_dump_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'has no creation time the server can tell')
                       || ' (critical under 48 hours, warning under 7 days)'] END
  FROM pgvigil.mssql_health h
  ) x;
