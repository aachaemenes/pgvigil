-- DRAFT of the join's re-created objects with BLITZ-GAP's lines 2 and 3 (scripts/blitzgap-join-lines.sql) in them, built
-- from 0161 L202-242 and 0160 L489-912 at 46a9c3c8 - a proof of the lines only, never a migration (scripts/ is not
-- embedded): proof-mssql-config-checks.sh (C7) applies it to its own throwaway repository when the keys lack line 2.

CREATE OR REPLACE FUNCTION pgvigil.mssql_config_expect_keys()
RETURNS TABLE (kind text, key text, vtype text, choices text[], takes_exclusions boolean, default_exclusions jsonb,
               default_on boolean, source text, rule text, label text, vmin bigint, vmax bigint)
LANGUAGE sql IMMUTABLE AS $$
  SELECT v.*, r.vmin, r.vmax FROM (VALUES
    ('database', 'recovery_model', 'choice', ARRAY['FULL', 'SIMPLE', 'BULK_LOGGED'], true, '["master", "tempdb", "model", "msdb"]'::jsonb, false, 'dbachecks policy', 'Database#13', 'recovery model'),
    ('database', 'scoped_maxdop', 'number', NULL, true, '[]'::jsonb, false, 'dbachecks policy', 'Database#43', 'database-scoped MAXDOP'),
    ('database', 'state', 'choice', ARRAY['on'], true, '[]'::jsonb, false, 'dbachecks policy', 'Database#44', 'databases restoring, read-only or in standby'),
    ('database', 'expected', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Database#45', 'expected databases'),
    ('database', 'query_store', 'choice', ARRAY['on', 'off'], true, '["master", "tempdb", "model"]'::jsonb, false, 'dbachecks policy', 'Database#52', 'Query Store'),
    ('service', 'engine_start_mode', 'choice', ARRAY['Automatic', 'Manual', 'Disabled', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#6', 'engine start mode'),
    ('service', 'agent_start_mode', 'choice', ARRAY['Automatic', 'Manual', 'Disabled', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#6', 'SQL Server Agent start mode'),
    ('instance', 'server_name', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#22', 'server name'),
    ('instance', 'max_memory', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'dbatools formula', 'Instance#20', 'max server memory'),
    ('instance', 'maxdop', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'dbatools formula', 'Instance#47', 'max degree of parallelism'),
    ('instance', 'startup_procs', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#55', 'scan for startup procs'),
    ('instance', 'errorlog_files', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#46', 'error log files kept'),
    ('xe', 'stopped', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#31', 'event sessions expected stopped'),
    ('xe', 'running', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#32', 'event sessions expected running'),
    ('xe', 'allowed', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#33', 'event sessions allowed to run'),
    ('xe', 'exists', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instancev5#46', 'event sessions expected to exist'),
    ('traceflag', 'expected', 'numlist', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#49', 'trace flags expected'),
    ('traceflag', 'not_expected', 'numlist', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#50', 'trace flags not expected'),
    ('network', 'tcp_port', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#8', 'TCP port'),
    ('network', 'protocols', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#9', 'network protocols enabled'),
    ('network', 'cpu_priority', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#6', 'Windows processor scheduling (Win32PrioritySeparation)'),
    ('agent', 'operators', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'Agent operators expected'),
    ('agent', 'failsafe_operator', 'text', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'Agent fail-safe operator'),
    ('agent', 'job_owner_allow', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'job owners allowed'),
    ('agent', 'job_owner_deny', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'job owners not allowed'),
    -- task 410 (0161): the maintenance jobs a site expects, or does not, by the role's name (Ola's job name). A list of
    -- its own type, 'joblist': 0160's grid leaves it to 0161's rules
    ('job', 'expected', 'joblist', ARRAY['DatabaseBackup - SYSTEM_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - DIFF', 'DatabaseBackup - USER_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - LOG', 'DatabaseIntegrityCheck - SYSTEM_DATABASES', 'DatabaseIntegrityCheck - USER_DATABASES', 'IndexOptimize - USER_DATABASES', 'CommandLog Cleanup', 'sp_delete_backuphistory', 'sp_purge_jobhistory', 'Output File Cleanup'], false, '[]'::jsonb, false, 'dbachecks policy', 'MaintenanceSolution', 'maintenance jobs expected'),
    ('job', 'not_expected', 'joblist', ARRAY['DatabaseBackup - SYSTEM_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - DIFF', 'DatabaseBackup - USER_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - LOG', 'DatabaseIntegrityCheck - SYSTEM_DATABASES', 'DatabaseIntegrityCheck - USER_DATABASES', 'IndexOptimize - USER_DATABASES', 'CommandLog Cleanup', 'sp_delete_backuphistory', 'sp_purge_jobhistory', 'Output File Cleanup'], false, '[]'::jsonb, false, 'dbachecks policy', 'MaintenanceSolution', 'maintenance jobs not expected'),
    -- line 2 of scripts/blitzgap-join-lines.sql: sp_Blitz 55, the database owner (BLITZ-GAP; sa unless a scope names another)
    ('database', 'owner', 'text', NULL, true, '[]'::jsonb, true, 'sp_Blitz', 'sp_Blitz 55', 'database owner')
  ) v (kind, key, vtype, choices, takes_exclusions, default_exclusions, default_on, source, rule, label)
  -- a number key's range: what the server itself takes for the setting (MAXDOP 0 to 32767, 6 to 99 error log files, a
  -- TCP port, the six bits of Win32PrioritySeparation)
  LEFT JOIN (VALUES ('database', 'scoped_maxdop', 0::bigint, 32767::bigint), ('instance', 'errorlog_files', 6, 99),
                    ('network', 'tcp_port', 1, 65535), ('network', 'cpu_priority', 0, 63)) r (kind, key, vmin, vmax)
    ON r.kind = v.kind AND r.key = v.key
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_config_checks_of(p_instance_id integer)
RETURNS TABLE (rule text, check_name text, object text, value text, expected text, set_at text, source text, status text, detail text, at timestamptz)
LANGUAGE sql STABLE AS $$
WITH x AS (
  SELECT i.instance_id,
         CASE i.platform WHEN 'rdssqlserver' THEN 'Amazon RDS' WHEN 'azuresqlmi' THEN 'Azure SQL Managed Instance'
                         WHEN 'cloudsqlsqlserver' THEN 'Google Cloud SQL' END AS hosted,
         i.platform,
         (SELECT f.value #>> '{}' FROM pgvigil.mssql_confcheck_fact f WHERE f.instance_id = i.instance_id AND f.key = 'host_platform') AS host_platform,
         (SELECT max(p.snapshot_at) FROM pgvigil.mssql_confcheck_part p WHERE p.instance_id = i.instance_id) AS cc_at,
         mi.is_clustered, mi.engine_edition, mi.physical_memory_mb,
         -- the linked servers' test is on where the instance's configuration carries the tag: the runner reads that,
         -- not a tag set over it with 'pgvigil tag'
         EXISTS (SELECT 1 FROM unnest(i.tags) u(t) CROSS JOIN LATERAL pgvigil.tag_split(u.t) s
                  WHERE s.key = 'pgvigil' AND s.value = 'linkedserver-test') AS linked_test_on
    FROM pgvigil.instances i
    LEFT JOIN pgvigil.mssql_instance mi ON mi.instance_id = i.instance_id
   -- Azure SQL Database: one database is the instance and mssql_confcheck does not run there; no grid of rows that
   -- would never be read
   WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver' AND i.platform IS DISTINCT FROM 'azuresqldb'
), e AS (
  SELECT * FROM pgvigil.mssql_config_expect_in_force(p_instance_id)
), f AS (
  SELECT c.key, c.value FROM pgvigil.mssql_confcheck_fact c WHERE c.instance_id = p_instance_id
), p AS (
  SELECT c.part, c.is_read, c.note FROM pgvigil.mssql_confcheck_part c WHERE c.instance_id = p_instance_id
), cfg AS (
  SELECT c.name, c.value_in_use, c.snapshot_at FROM pgvigil.mssql_config c WHERE c.instance_id = p_instance_id AND c.is_present
), d AS (
  SELECT * FROM pgvigil.mssql_db_confcheck c WHERE c.instance_id = p_instance_id
), xe AS (
  SELECT * FROM pgvigil.mssql_xe_session_state c WHERE c.instance_id = p_instance_id
), tf AS (
  SELECT t.trace_flag FROM pgvigil.mssql_trace_flags t WHERE t.instance_id = p_instance_id AND t.is_global
), jobs AS (
  SELECT j.name, j.owner FROM pgvigil.mssql_jobs j WHERE j.instance_id = p_instance_id
), ops AS (
  SELECT o.name FROM pgvigil.mssql_agent_operator o WHERE o.instance_id = p_instance_id
), k AS (
  SELECT * FROM pgvigil.mssql_config_expect_keys()
),
-- the deviations of the rules over a list
devs AS (
  SELECT 'database'::text AS kind, 'recovery_model'::text AS key, d.database_name AS object, d.recovery_model AS value, 'warning'::text AS status,
         format('recovery model %s; %s is expected', d.recovery_model, ex.value #>> '{}') AS detail
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'recovery_model'
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND lower(d.database_name) <> 'tempdb'
     AND d.recovery_model IS NOT NULL AND d.recovery_model <> (ex.value #>> '{}')
  UNION ALL
  SELECT 'database', 'scoped_maxdop', d.database_name, d.scoped_maxdop::text, 'warning',
         format('database-scoped MAXDOP %s; %s is expected', d.scoped_maxdop, ex.value #>> '{}')
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'scoped_maxdop'
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND d.scoped_maxdop IS NOT NULL AND d.scoped_maxdop <> (ex.value #>> '{}')::bigint
  UNION ALL
  SELECT 'database', 'state', d.database_name,
         concat_ws(', ', CASE WHEN d.state = 'RESTORING' THEN 'RESTORING' END, CASE WHEN d.read_only THEN 'read-only' END, CASE WHEN d.in_standby THEN 'standby' END),
         CASE WHEN rn.note IS NOT NULL THEN 'not read' ELSE 'warning' END,
         CASE WHEN rn.note IS NOT NULL
              THEN format('the database is %s; whether it is a secondary was not read (%s)',
                          concat_ws(', ', CASE WHEN d.state = 'RESTORING' THEN 'RESTORING' END, CASE WHEN d.read_only THEN 'read-only' END, CASE WHEN d.in_standby THEN 'in standby' END), rn.note)
              ELSE format('the database is %s and is not a mirror, an availability group secondary or a log shipping secondary',
                          concat_ws(', ', CASE WHEN d.state = 'RESTORING' THEN 'RESTORING' END, CASE WHEN d.read_only THEN 'read-only' END, CASE WHEN d.in_standby THEN 'in standby' END)) END
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'state'
    -- the collector's note when the mirrors, the availability group or the log shipping secondaries were not told apart
    CROSS JOIN (SELECT (SELECT f.value #>> '{}' FROM f WHERE f.key = 'secondary_roles_unread') AS note) rn
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND d.secondary_role IS NULL
     AND (d.state = 'RESTORING' OR coalesce(d.read_only, false) OR coalesce(d.in_standby, false))
  UNION ALL
  SELECT 'database', 'expected', n.name, 'missing', 'critical', 'the database is expected on this instance and the server lists none of that name'
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
   WHERE ex.kind = 'database' AND ex.key = 'expected' AND EXISTS (SELECT 1 FROM p WHERE p.part = 'databases' AND p.is_read)
     AND NOT EXISTS (SELECT 1 FROM d WHERE lower(d.database_name) = lower(n.name))
  UNION ALL
  SELECT 'database', 'query_store', d.database_name, CASE WHEN d.query_store THEN 'on' ELSE 'off' END, 'warning',
         format('Query Store is %s; %s is expected', CASE WHEN d.query_store THEN 'on' ELSE 'off' END, ex.value #>> '{}')
    FROM d JOIN e ex ON ex.kind = 'database' AND ex.key = 'query_store'
   WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND d.state = 'ONLINE' AND d.secondary_role IS NULL AND NOT coalesce(d.in_standby, false)
     AND d.query_store IS NOT NULL AND d.query_store <> ((ex.value #>> '{}') = 'on')
  UNION ALL
  SELECT 'xe', 'stopped', xe.session_name, 'running', 'warning', 'the event session runs; it is expected stopped'
    FROM xe JOIN e ex ON ex.kind = 'xe' AND ex.key = 'stopped' AND pgvigil.mssql_cc_in(ex.value, xe.session_name) WHERE xe.running
  UNION ALL
  SELECT 'xe', 'running', n.name, CASE WHEN xe.session_name IS NULL THEN 'missing' ELSE 'stopped' END, 'warning',
         CASE WHEN xe.session_name IS NULL THEN 'the event session is expected running and the server has none of that name'
              ELSE 'the event session is stopped; it is expected running' END
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
    LEFT JOIN xe ON lower(xe.session_name) = lower(n.name)
   WHERE ex.kind = 'xe' AND ex.key = 'running' AND EXISTS (SELECT 1 FROM p WHERE p.part = 'xe' AND p.is_read) AND NOT coalesce(xe.running, false)
  UNION ALL
  SELECT 'xe', 'allowed', xe.session_name, 'running', 'warning', 'the event session runs and is not on the list of sessions allowed to run'
    FROM xe JOIN e ex ON ex.kind = 'xe' AND ex.key = 'allowed' WHERE xe.running AND NOT pgvigil.mssql_cc_in(ex.value, xe.session_name)
  UNION ALL
  SELECT 'xe', 'exists', n.name, 'missing', 'warning', 'the event session is expected to exist and the server has none of that name'
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
   WHERE ex.kind = 'xe' AND ex.key = 'exists' AND EXISTS (SELECT 1 FROM p WHERE p.part = 'xe' AND p.is_read)
     AND NOT EXISTS (SELECT 1 FROM xe WHERE lower(xe.session_name) = lower(n.name))
  UNION ALL
  SELECT 'traceflag', 'expected', n.flag, 'off', 'warning', format('trace flag %s is expected on for the whole server and is not', n.flag)
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(flag)
   WHERE ex.kind = 'traceflag' AND ex.key = 'expected' AND NOT EXISTS (SELECT 1 FROM tf WHERE tf.trace_flag::text = n.flag)
     AND EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_traceflags' AND c.status = 'ok')
  UNION ALL
  SELECT 'traceflag', 'not_expected', tf.trace_flag::text, 'on', 'warning', format('trace flag %s is on for the whole server and is expected off', tf.trace_flag)
    FROM tf JOIN e ex ON ex.kind = 'traceflag' AND ex.key = 'not_expected' AND ex.value @> to_jsonb(tf.trace_flag)
  UNION ALL
  SELECT 'agent', 'operators', n.name, 'missing', 'warning', format('the operator %s is expected and the Agent has none of that name', n.name)
    FROM e ex CROSS JOIN LATERAL pgvigil.mssql_cc_list(ex.value) n(name)
   WHERE ex.kind = 'agent' AND ex.key = 'operators' AND NOT EXISTS (SELECT 1 FROM ops WHERE lower(ops.name) = lower(n.name))
     AND coalesce((SELECT a.is_read FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts'), false)
  UNION ALL
  SELECT 'agent', 'job_owner_deny', j.name, j.owner, 'warning', format('the job is owned by %s, a login on the list of owners not allowed', j.owner)
    FROM jobs j JOIN e ex ON ex.kind = 'agent' AND ex.key = 'job_owner_deny'
   WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(ex.value) n(name) WHERE lower(n.name) = lower(j.owner))
  UNION ALL
  SELECT 'agent', 'job_owner_allow', j.name, coalesce(j.owner, 'no owner read'), 'warning',
         format('the job is owned by %s, a login not on the list of owners allowed', coalesce(j.owner, 'a login that was not read'))
    FROM jobs j JOIN e ex ON ex.kind = 'agent' AND ex.key = 'job_owner_allow'
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(ex.value) n(name) WHERE lower(n.name) = lower(j.owner))
),
-- whether each list rule's source was read, and why not
src AS (
  SELECT k.kind, k.key,
         CASE k.kind
           WHEN 'database' THEN coalesce((SELECT p.is_read FROM p WHERE p.part = 'databases'), false)
           WHEN 'xe' THEN coalesce((SELECT p.is_read FROM p WHERE p.part = 'xe'), false)
           WHEN 'traceflag' THEN EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_traceflags' AND c.status = 'ok')
           WHEN 'agent' THEN CASE WHEN k.key = 'operators'
                                  THEN coalesce((SELECT a.is_read FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts'), false)
                                  ELSE EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_jobs' AND c.status = 'ok') END
         END AS is_read,
         CASE k.kind
           WHEN 'database' THEN coalesce((SELECT p.note FROM p WHERE p.part = 'databases'), 'the databases were not read yet (mssql_confcheck)')
           WHEN 'xe' THEN coalesce((SELECT p.note FROM p WHERE p.part = 'xe'), 'the event sessions were not read yet (mssql_confcheck)')
           WHEN 'traceflag' THEN 'the trace flags were not read yet (mssql_traceflags)'
           WHEN 'agent' THEN CASE WHEN k.key = 'operators'
                                  THEN coalesce((SELECT a.note FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts'), 'the Agent''s operators were not read yet (mssql_checks)')
                                  ELSE 'the jobs were not read yet (mssql_jobs)' END
         END AS why,
         -- the time of the read the rule rests on: the trace flags and the job owners from their own collections, the
         -- operators from mssql_checks' alerts area, the rest from mssql_confcheck
         CASE k.kind
           WHEN 'traceflag' THEN (SELECT c.snapshot_at FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_traceflags')
           WHEN 'agent' THEN CASE WHEN k.key = 'operators'
                                  THEN (SELECT a.snapshot_at FROM pgvigil.mssql_check_area a WHERE a.instance_id = p_instance_id AND a.area = 'alerts')
                                  ELSE (SELECT c.snapshot_at FROM pgvigil.collection_dates c WHERE c.instance_id = p_instance_id AND c.collection = 'mssql_jobs') END
           ELSE (SELECT max(c.snapshot_at) FROM pgvigil.mssql_confcheck_part c WHERE c.instance_id = p_instance_id)
         END AS at
    FROM k
   WHERE k.vtype IN ('list', 'numlist') AND k.kind <> 'network' OR (k.kind = 'database' AND k.key <> 'owner')   -- line 3a: 55 has its own part
)
-- 1. the rules over a list: the deviations
SELECT k.rule, k.label, v.object, v.value,
       CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END,
       ex.set_at, k.source, v.status, v.detail || format(' (set at %s)', ex.set_at), s.at
  FROM devs v
  JOIN k ON k.kind = v.kind AND k.key = v.key
  JOIN e ex ON ex.kind = v.kind AND ex.key = v.key
  JOIN src s ON s.kind = v.kind AND s.key = v.key
  CROSS JOIN x
UNION ALL
-- 2. the rules over a list: the rule's own row when nothing deviates
SELECT k.rule, k.label, '', NULL,
       CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END,
       ex.set_at, k.source,
       -- a database the rule did not read (outside the databases left out) is never 'met': the rule is not read
       CASE WHEN ex.key IS NULL THEN 'off' WHEN NOT coalesce(s.is_read, false) THEN 'not read'
            WHEN k.kind = 'database' AND EXISTS (SELECT 1 FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby))
              THEN 'not read'
            ELSE 'ok' END,
       CASE WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN NOT coalesce(s.is_read, false) THEN s.why
            WHEN k.kind = 'database' AND k.key = 'scoped_maxdop' AND EXISTS (SELECT 1 FROM d WHERE d.scoped_maxdop IS NULL AND NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name))
              THEN format('met where read; not read in %s database(s): %s',
                          (SELECT count(*) FROM d WHERE d.scoped_maxdop IS NULL AND NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name)),
                          (SELECT string_agg(DISTINCT d.scoped_note, '; ') FROM d WHERE d.scoped_maxdop IS NULL AND NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name)))
            WHEN k.kind = 'database' AND EXISTS (SELECT 1 FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby))
              THEN format('met where read; not read in %s database(s): %s',
                          (SELECT count(*) FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby)),
                          (SELECT string_agg(d.database_name, ', ' ORDER BY d.database_name) FROM d WHERE NOT pgvigil.mssql_cc_in(ex.exclusions, d.database_name) AND pgvigil.mssql_cc_unread(k.key, d.database_name, d.state, d.scoped_maxdop, d.recovery_model, d.query_store, d.secondary_role, d.in_standby)))
            ELSE 'met' || CASE WHEN jsonb_array_length(ex.exclusions) > 0
                               THEN '; left out: ' || (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.exclusions) n) ELSE '' END END,
       s.at
  FROM x
  CROSS JOIN k
  JOIN src s ON s.kind = k.kind AND s.key = k.key
  LEFT JOIN e ex ON ex.kind = k.kind AND ex.key = k.key
 WHERE NOT EXISTS (SELECT 1 FROM devs v WHERE v.kind = k.kind AND v.key = k.key)
UNION ALL
-- 3. a server option's expected value (dbachecks' Agent#1 Database Mail XPs and Instance#58 remote access are shown
--    whether set or not; any other option once a scope sets it)
SELECT CASE o.name WHEN 'database mail xps' THEN 'Agent#1' WHEN 'remote access' THEN 'Instance#58' ELSE 'option' END,
       'server option', coalesce(c.name, CASE o.name WHEN 'database mail xps' THEN 'Database Mail XPs' ELSE o.name END), c.value_in_use::text, ex.value #>> '{}', ex.set_at, 'dbachecks policy',
       CASE WHEN ex.key IS NULL THEN 'off' WHEN c.name IS NULL THEN 'not read' WHEN c.value_in_use = (ex.value #>> '{}')::bigint THEN 'ok' ELSE 'warning' END,
       CASE WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN c.name IS NULL THEN 'the server lists no option of that name (mssql_config)'
            WHEN c.value_in_use = (ex.value #>> '{}')::bigint THEN format('in use %s, as expected (set at %s)', c.value_in_use, ex.set_at)
            ELSE format('in use %s; %s is expected (set at %s)', c.value_in_use, ex.value #>> '{}', ex.set_at) END,
       coalesce(c.snapshot_at, x.cc_at)
  FROM x
  CROSS JOIN (SELECT e.key AS name FROM e WHERE e.kind = 'config' UNION SELECT 'database mail xps' UNION SELECT 'remote access') o
  LEFT JOIN e ex ON ex.kind = 'config' AND ex.key = o.name
  LEFT JOIN cfg c ON lower(c.name) = o.name
UNION ALL
-- 4. the engine's and the Agent's start mode: Automatic on a standalone instance, Manual on a failover cluster
--    instance (the cluster starts it), unless a scope names another
SELECT 'Instance#6', sm.label, '', s.startup_type, want.v, coalesce(ex.set_at, 'default'), 'Microsoft',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN sm.key = 'agent_start_mode' AND x.engine_edition = 4 THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN s.service_name IS NULL THEN 'not read'
            WHEN s.startup_type = want.v THEN 'ok' ELSE 'warning' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN sm.key = 'agent_start_mode' AND x.engine_edition = 4 THEN 'SQL Server Express has no SQL Server Agent'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN s.service_name IS NULL AND x.host_platform = 'Linux' AND sm.key = 'engine_start_mode' THEN 'sys.dm_server_services lists no engine row on Linux'
            WHEN s.service_name IS NULL THEN 'the services were not read (mssql_services)'
            WHEN s.startup_type = want.v THEN format('%s starts %s', s.service_name, s.startup_type)
            ELSE format('%s starts %s; %s is expected%s', s.service_name, coalesce(s.startup_type, 'in a mode that was not read'), want.v,
                        CASE WHEN ex.key IS NOT NULL THEN format(' (set at %s)', ex.set_at)
                             WHEN coalesce(s.is_clustered, x.is_clustered, false) THEN ' on a failover cluster instance (the cluster starts it)'
                             ELSE ' on a standalone instance (it must come back after a restart of the machine)' END) END,
       coalesce(s.snapshot_at, x.cc_at)
  FROM x
  CROSS JOIN (VALUES ('engine_start_mode', 'engine start mode', 'SQL Server (%'), ('agent_start_mode', 'SQL Server Agent start mode', 'SQL Server Agent (%')) sm(key, label, pat)
  LEFT JOIN e ex ON ex.kind = 'service' AND ex.key = sm.key
  LEFT JOIN LATERAL (SELECT sv.service_name, sv.startup_type, sv.is_clustered, sv.snapshot_at FROM pgvigil.mssql_service sv
                      WHERE sv.instance_id = x.instance_id AND sv.is_present AND sv.service_name LIKE sm.pat
                      ORDER BY sv.service_name LIMIT 1) s ON true
  CROSS JOIN LATERAL (SELECT CASE WHEN ex.key IS NOT NULL AND ex.value #>> '{}' <> 'off' THEN ex.value #>> '{}'
                                  WHEN coalesce(s.is_clustered, x.is_clustered, false) THEN 'Manual' ELSE 'Automatic' END AS v) want
UNION ALL
-- 5. @@SERVERNAME against the server's own name (a rename finishes with sp_dropserver, sp_addserver and a restart)
SELECT 'Instance#22', 'server name', '', sn.at_name, sn.prop_name, coalesce(ex.set_at, 'default'), 'Microsoft',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN NOT coalesce(pt.is_read, false) THEN 'not read'
            WHEN sn.at_name IS NULL OR lower(sn.at_name) <> lower(sn.prop_name) THEN 'warning' ELSE 'ok' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN NOT coalesce(pt.is_read, false) THEN coalesce(pt.note, 'the names were not read yet (mssql_confcheck)')
            WHEN sn.at_name IS NULL THEN format('a rename not finished: @@SERVERNAME is NULL (no local server in sys.servers) and the server''s name is %s', sn.prop_name)
            WHEN lower(sn.at_name) <> lower(sn.prop_name) THEN format('a rename not finished: @@SERVERNAME is %s and the server''s name is %s (sp_dropserver, sp_addserver ''local'', then a restart)', sn.at_name, sn.prop_name)
            ELSE '@@SERVERNAME is the server''s name' END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'server_name'
  LEFT JOIN p pt ON pt.part = 'names'
  CROSS JOIN LATERAL (SELECT (SELECT f.value #>> '{}' FROM f WHERE f.key = 'server_name') AS at_name,
                             (SELECT f.value #>> '{}' FROM f WHERE f.key = 'property_server_name') AS prop_name) sn
UNION ALL
-- 6. max server memory against dbatools' recommendation for the machine, shared by the monitored instances of it; on
--    Linux only 'under the machine's memory' is judged (the formula's reserve is Windows')
SELECT 'Instance#20', 'max server memory', '', mm.max_mb::text, CASE WHEN x.host_platform = 'Linux' THEN 'under ' || x.physical_memory_mb ELSE mm.rec_mb::text END,
       coalesce(ex.set_at, 'default'), 'dbatools formula',
       CASE WHEN x.platform = 'azuresqlmi' THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN mm.max_mb IS NULL OR x.physical_memory_mb IS NULL OR x.host_platform IS NULL THEN 'not read'
            WHEN x.host_platform = 'Linux' AND mm.max_mb >= x.physical_memory_mb THEN 'info'
            WHEN x.host_platform <> 'Linux' AND mm.max_mb > mm.rec_mb THEN 'info' ELSE 'ok' END,
       CASE WHEN x.platform = 'azuresqlmi' THEN 'Azure SQL Managed Instance runs the host'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN mm.max_mb IS NULL THEN 'max server memory was not read (mssql_config)'
            WHEN x.physical_memory_mb IS NULL THEN 'the machine''s memory was not read (the login lacks VIEW SERVER STATE, or mssql_instance has not run)'
            WHEN x.host_platform IS NULL THEN 'the host''s platform was not read yet (mssql_confcheck)'
            WHEN x.host_platform = 'Linux'
              THEN format('max server memory %s MB; the machine has %s MB: %s. Linux is judged only on being under the machine''s memory',
                          mm.max_mb, x.physical_memory_mb, CASE WHEN mm.max_mb >= x.physical_memory_mb THEN 'the server may take all of it' ELSE 'under it' END)
            ELSE format('max server memory %s MB; dbatools'' Test-DbaMaxMemory recommends %s MB of the machine''s %s MB for each of the %s monitored instance(s) on it. Analysis, Reporting and Integration Services are not counted: pgvigil has no Windows host door yet',
                        mm.max_mb, mm.rec_mb, x.physical_memory_mb, mm.n) END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'max_memory'
  CROSS JOIN LATERAL (SELECT (SELECT c.value_in_use FROM cfg c WHERE lower(c.name) = 'max server memory (mb)') AS max_mb, n.n,
                             round(pgvigil.mssql_recommended_max_memory_mb(x.physical_memory_mb)::numeric / n.n)::bigint AS rec_mb
                        FROM (SELECT greatest(1, (SELECT count(*) FROM pgvigil.mssql_confcheck_fact o
                                                    JOIN pgvigil.instances oi ON oi.instance_id = o.instance_id AND oi.is_active AND oi.engine = 'sqlserver'
                                                   WHERE o.key = 'netbios' AND o.value IS NOT NULL
                                                     AND lower(o.value #>> '{}') = lower((SELECT f.value #>> '{}' FROM f WHERE f.key = 'netbios')))) AS n) n) mm
UNION ALL
-- 7. MAXDOP against dbatools' advised value: 1 up to it is in order, only above it (or 0 on a machine with more CPUs
--    than it) is a deviation
SELECT 'Instance#47', 'max degree of parallelism', '', md.maxdop::text, 'up to ' || md.advised, coalesce(ex.set_at, 'default'), 'dbatools formula',
       CASE WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN md.maxdop IS NULL OR md.advised IS NULL THEN 'not read'
            WHEN md.maxdop = 0 AND coalesce(md.cpus, 0) > md.advised THEN 'info'
            WHEN md.maxdop > md.advised THEN 'info' ELSE 'ok' END,
       CASE WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN md.maxdop IS NULL THEN 'max degree of parallelism was not read (mssql_config)'
            WHEN md.advised IS NULL THEN coalesce((SELECT p.note FROM p WHERE p.part = 'machine'), 'the machine''s CPUs were not read yet (mssql_confcheck)')
            WHEN md.maxdop = 0 AND coalesce(md.cpus, 0) > md.advised THEN format('MAXDOP 0 lets one query use all %s CPUs; dbatools'' Test-DbaMaxDop advises %s', md.cpus, md.advised)
            WHEN md.maxdop > md.advised THEN format('MAXDOP %s is above the %s dbatools'' Test-DbaMaxDop advises for this machine', md.maxdop, md.advised)
            ELSE format('MAXDOP %s; dbatools'' Test-DbaMaxDop advises up to %s', md.maxdop, md.advised) END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'maxdop'
  CROSS JOIN LATERAL (SELECT (SELECT c.value_in_use FROM cfg c WHERE lower(c.name) = 'max degree of parallelism') AS maxdop,
                             (SELECT (f.value #>> '{}')::bigint FROM f WHERE f.key = 'advised_maxdop') AS advised,
                             (SELECT (f.value #>> '{}')::bigint FROM f WHERE f.key = 'cpu_count') AS cpus) md
UNION ALL
-- 8. 'scan for startup procs' on with no startup procedure (replication's own sp_MSrepl_startup is not one)
SELECT 'Instance#55', 'scan for startup procs', '', sp.scan::text, NULL, coalesce(ex.set_at, 'default'), 'Microsoft',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN ex.value #>> '{}' = 'off' THEN 'off'
            WHEN sp.scan IS NULL THEN 'not read'
            WHEN sp.scan = 0 THEN 'ok'
            WHEN NOT coalesce(pt.is_read, false) THEN 'not read'
            WHEN sp.procs IS NULL THEN 'warning' ELSE 'ok' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN ex.value #>> '{}' = 'off' THEN format('switched off (set at %s)', ex.set_at)
            WHEN sp.scan IS NULL THEN 'scan for startup procs was not read (mssql_config)'
            WHEN sp.scan = 0 THEN 'the server does not scan for startup procedures'
            WHEN NOT coalesce(pt.is_read, false) THEN coalesce(pt.note, 'the startup procedures were not read yet (mssql_confcheck)')
            WHEN sp.procs IS NULL THEN 'scan for startup procs is on and master holds no startup procedure: the option does nothing but scan at every start'
            ELSE 'the server runs at its start: ' || sp.procs END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'startup_procs'
  LEFT JOIN p pt ON pt.part = 'startup'
  CROSS JOIN LATERAL (SELECT (SELECT c.value_in_use FROM cfg c WHERE lower(c.name) = 'scan for startup procs') AS scan,
                             (SELECT string_agg(n, ', ' ORDER BY n) FROM f CROSS JOIN LATERAL pgvigil.mssql_cc_list(f.value) n
                               WHERE f.key = 'startup_procs' AND lower(n) <> 'sp_msrepl_startup') AS procs) sp
UNION ALL
-- 9. the error log files kept, at least the number a scope names
SELECT 'Instance#46', 'error log files kept', '', el.kept::text, 'at least ' || (ex.value #>> '{}'), ex.set_at, 'dbachecks policy',
       CASE WHEN x.hosted IS NOT NULL THEN 'not applicable'
            WHEN ex.key IS NULL THEN 'off'
            WHEN NOT coalesce(pt.is_read, false) OR el.kept IS NULL THEN 'not read'
            WHEN el.kept < (ex.value #>> '{}')::bigint THEN 'info' ELSE 'ok' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN NOT coalesce(pt.is_read, false) OR el.kept IS NULL THEN coalesce(pt.note, 'the error log files kept were not read yet (mssql_confcheck)')
            WHEN el.kept < (ex.value #>> '{}')::bigint THEN format('the server keeps %s error log files; at least %s are expected (set at %s)', el.kept, ex.value #>> '{}', ex.set_at)
            ELSE format('the server keeps %s error log files (set at %s)', el.kept, ex.set_at) END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'instance' AND ex.key = 'errorlog_files'
  LEFT JOIN p pt ON pt.part = 'errorlog'
  CROSS JOIN LATERAL (SELECT (SELECT (f.value #>> '{}')::bigint FROM f WHERE f.key = 'num_errorlogs') AS kept) el
UNION ALL
-- 10. the Agent's fail-safe operator
SELECT 'Agent', 'Agent fail-safe operator', '', al.failsafe_operator, ex.value #>> '{}', ex.set_at, 'dbachecks policy',
       CASE WHEN ex.key IS NULL THEN 'off'
            WHEN al.instance_id IS NULL OR NOT al.failsafe_read THEN 'not read'
            WHEN lower(coalesce(al.failsafe_operator, '')) = lower(ex.value #>> '{}') THEN 'ok' ELSE 'warning' END,
       CASE WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN al.instance_id IS NULL THEN 'the Agent''s alert settings were not read yet (mssql_checks)'
            WHEN NOT al.failsafe_read THEN 'the fail-safe operator was not read: the login may not run master.dbo.sp_MSgetalertinfo'
            WHEN lower(coalesce(al.failsafe_operator, '')) = lower(ex.value #>> '{}') THEN format('the fail-safe operator is %s (set at %s)', al.failsafe_operator, ex.set_at)
            ELSE format('the fail-safe operator is %s; %s is expected (set at %s)', coalesce(al.failsafe_operator, 'not set'), ex.value #>> '{}', ex.set_at) END,
       coalesce(al.snapshot_at, x.cc_at)
  FROM x
  LEFT JOIN e ex ON ex.kind = 'agent' AND ex.key = 'failsafe_operator'
  LEFT JOIN pgvigil.mssql_agent_alerting al ON al.instance_id = x.instance_id
UNION ALL
-- 11. what the properties collection reads of the network and the host: the TCP port, the enabled protocols, the
--     Windows processor scheduling. Until it stores them the rule says so.
SELECT nk.rule, nk.label, '', pr.value,
       CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END,
       ex.set_at, 'dbachecks policy',
       CASE WHEN x.hosted IS NOT NULL AND (nk.key <> 'tcp_port' OR x.platform = 'azuresqlmi') THEN 'not applicable'
            WHEN x.host_platform = 'Linux' AND nk.key = 'cpu_priority' THEN 'not applicable'
            WHEN ex.key IS NULL THEN 'off'
            WHEN x.host_platform = 'Linux' AND nk.key = 'protocols' THEN CASE WHEN pgvigil.mssql_cc_in(ex.value, 'Tcp') THEN 'ok' ELSE 'info' END
            WHEN pr.name IS NULL OR pr.value IS NULL THEN 'not read'
            WHEN nk.key = 'protocols' AND NOT EXISTS (SELECT 1 FROM unnest(string_to_array(pr.value, ',')) u(n)
                                                       WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cc_list(ex.value) w(n) WHERE lower(btrim(w.n)) = lower(btrim(u.n)))) THEN 'ok'
            WHEN nk.key <> 'protocols' AND btrim(pr.value) = (ex.value #>> '{}') THEN 'ok'
            ELSE 'info' END,
       CASE WHEN x.hosted IS NOT NULL AND (nk.key <> 'tcp_port' OR x.platform = 'azuresqlmi') THEN x.hosted || ' runs the host'
            WHEN x.host_platform = 'Linux' AND nk.key = 'cpu_priority' THEN 'SQL Server on Linux has no Windows processor scheduling'
            WHEN ex.key IS NULL THEN 'set an expectation'
            WHEN x.host_platform = 'Linux' AND nk.key = 'protocols' AND pgvigil.mssql_cc_in(ex.value, 'Tcp') THEN 'met: Linux serves TCP only'
            WHEN x.host_platform = 'Linux' AND nk.key = 'protocols' THEN format('Linux serves TCP only; %s is expected (set at %s)', (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n), ex.set_at)
            WHEN pr.name IS NULL OR pr.value IS NULL THEN coalesce(pr.note, 'waits on the properties collection: it does not read this value yet')
            ELSE format('%s; %s is expected (set at %s)', pr.value,
                        CASE WHEN jsonb_typeof(ex.value) = 'array' THEN (SELECT string_agg(n, ', ') FROM pgvigil.mssql_cc_list(ex.value) n) ELSE ex.value #>> '{}' END, ex.set_at) END,
       coalesce(pr.snapshot_at, x.cc_at)
  FROM x
  CROSS JOIN (VALUES ('tcp_port', 'Server#8', 'TCP port', 'tcp_port'), ('protocols', 'Server#9', 'network protocols enabled', 'protocols_enabled'),
                     ('cpu_priority', 'Server#6', 'Windows processor scheduling (Win32PrioritySeparation)', 'win32_priority_separation')) nk(key, rule, label, prop)
  LEFT JOIN e ex ON ex.kind = 'network' AND ex.key = nk.key
  LEFT JOIN pgvigil.mssql_property pr ON pr.instance_id = x.instance_id AND pr.name = nk.prop
UNION ALL
-- 12. the linked servers' connection test (Instance#19), on only where the instance carries the tag
SELECT 'Instance#19', 'linked server connection test', l.name, t.outcome, 'ok', NULL, 'dbachecks policy',
       CASE WHEN NOT x.linked_test_on THEN 'off'
            WHEN t.name IS NULL OR t.outcome IN ('unmapped', 'not tested') THEN 'not read'
            WHEN t.outcome = 'ok' THEN 'ok' ELSE 'warning' END,
       CASE WHEN NOT x.linked_test_on THEN 'not tested: set the tag pgvigil:linkedserver-test on the instance to have its linked servers tested'
            WHEN t.name IS NULL THEN 'not tested yet (mssql_linkedserver_test)'
            WHEN t.outcome = 'unmapped' AND t.error_number = 7416 THEN format('not tested: the collector''s login has no mapping there (error %s)', t.error_number)
            WHEN t.outcome = 'unmapped' THEN format('not tested: the login mapped for the collector''s login was refused at the remote server (error %s)', t.error_number)
            WHEN t.outcome = 'not tested' THEN 'not tested: ' || coalesce(t.note, 'left for a later run')
            WHEN t.outcome = 'ok' THEN format('the connection from the monitored server answered in %s s', t.seconds)
            ELSE format('the connection from the monitored server failed after %s s, failing since %s: error %s: %s. The test connects as the collector''s own login maps there: a failure can be that mapping, not the link',
                        t.seconds, to_char(t.first_failed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', t.error_number, t.error_message) END,
       -- a failure stands until its next test: two servers are tested a run, so its own time can be hours old while
       -- the hourly list read still shows the server
       CASE WHEN t.outcome = 'failed' THEN greatest(t.tested_at, l.snapshot_at) ELSE coalesce(t.tested_at, l.snapshot_at) END
  FROM x
  JOIN pgvigil.mssql_linked_server l ON l.instance_id = x.instance_id
  LEFT JOIN pgvigil.mssql_linked_server_test t ON t.instance_id = l.instance_id AND t.name = l.name
UNION ALL
SELECT 'Instance#19', 'linked server connection test', '', NULL, 'ok', NULL, 'dbachecks policy',
       CASE WHEN NOT coalesce(pt.is_read, false) THEN 'not read'
            WHEN (SELECT f.value #>> '{}' FROM f WHERE f.key = 'linked_list_complete') = '0' THEN 'not read'
            ELSE 'ok' END,
       CASE WHEN NOT coalesce(pt.is_read, false) THEN coalesce(pt.note, 'the linked servers were not read yet (mssql_confcheck)')
            WHEN (SELECT f.value #>> '{}' FROM f WHERE f.key = 'linked_list_complete') = '0'
              THEN 'no linked server is visible to the collector''s login: ' || coalesce(pt.note, 'it may not see them all')
            ELSE 'the instance has no linked server' END,
       x.cc_at
  FROM x LEFT JOIN p pt ON pt.part = 'linked'
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_linked_server l WHERE l.instance_id = x.instance_id)
UNION ALL
-- 13. the SQL Server Browser (Instance#75, #76): a Windows service SQL Server itself does not show
SELECT b.rule, b.label, '', NULL, NULL, NULL, 'dbachecks policy',
       CASE WHEN x.hosted IS NOT NULL OR x.host_platform = 'Linux' THEN 'not applicable' ELSE 'not read' END,
       CASE WHEN x.hosted IS NOT NULL THEN x.hosted || ' runs the host'
            WHEN x.host_platform = 'Linux' THEN 'SQL Server on Linux has no Browser service'
            ELSE 'pgvigil has no Windows host door yet' END,
       x.cc_at
  FROM x CROSS JOIN (VALUES ('Instance#75', 'SQL Server Browser state'), ('Instance#76', 'SQL Server Browser start mode')) b(rule, label)
UNION ALL
-- line 3b of scripts/blitzgap-join-lines.sql: sp_Blitz 55 (BLITZ-GAP) - each user database's owner (0090's options, the
-- mssql_checks collection) against the expected owner: the original sa (sid 0x01, 0159's logins: a renamed sa keeps its
-- place) unless a scope names another, 'sa' while the logins are not read; 'off' (any case) turns it off; info, so no
-- finding row; an owner whose SID maps to no login is sp_Blitz 213's (the Checks tab); rdsadmin and gcloud_cloudsqladmin
-- are the cloud's (as dboptions.go's user()); no database read yet = one 'not read' row (review-24 S3, N1-N3)
SELECT 'sp_Blitz 55', 'database owner', o.database_name, o.options ->> 'owner', CASE WHEN want.off THEN NULL ELSE want.v END,
       coalesce(ex.set_at, 'default'), 'sp_Blitz',
       CASE WHEN want.off THEN 'off'
            WHEN o.options ->> 'owner' IS NULL THEN 'not applicable'
            WHEN lower(o.options ->> 'owner') = lower(want.v) THEN 'ok' ELSE 'info' END,
       CASE WHEN want.off THEN format('turned off (set at %s)', ex.set_at)
            WHEN o.options ->> 'owner' IS NULL THEN 'the owner''s SID maps to no login on this server (sp_Blitz 213 on the Checks tab)'
            WHEN lower(o.options ->> 'owner') = lower(want.v) THEN format('owned by %s, as expected (%s)', want.v, coalesce('set at ' || ex.set_at, 'the default'))
            ELSE format('the owner is %s; the expected owner is %s (%s)', o.options ->> 'owner', want.v, coalesce('set at ' || ex.set_at, 'the default')) END,
       o.snapshot_at
  FROM x
  JOIN pgvigil.mssql_database_option o ON o.instance_id = x.instance_id AND o.is_present AND NOT o.is_system AND NOT o.is_snapshot
                                      AND lower(o.database_name) NOT IN ('rdsadmin', 'gcloud_cloudsqladmin')
  LEFT JOIN e ex ON ex.kind = 'database' AND ex.key = 'owner'
  CROSS JOIN LATERAL (SELECT lower(ex.value #>> '{}') = 'off' AS off,
                             coalesce(CASE WHEN lower(ex.value #>> '{}') = 'off' THEN NULL ELSE ex.value #>> '{}' END,
                                      (SELECT l.login_name FROM pgvigil.mssql_security_logins l
                                        WHERE l.instance_id = x.instance_id AND l.is_original_sa AND l.is_present LIMIT 1), 'sa') AS v) want0
  CROSS JOIN LATERAL (SELECT coalesce(want0.off, false) AS off, want0.v) want
 WHERE NOT pgvigil.mssql_cc_in(coalesce(ex.exclusions, '[]'::jsonb), o.database_name)
UNION ALL
SELECT 'sp_Blitz 55', 'database owner', '', NULL, NULL, coalesce(ex.set_at, 'default'), 'sp_Blitz',
       CASE WHEN lower(ex.value #>> '{}') = 'off' THEN 'off' ELSE 'not read' END,
       CASE WHEN lower(ex.value #>> '{}') = 'off' THEN format('turned off (set at %s)', ex.set_at) ELSE 'the databases were not read yet (mssql_checks)' END,
       x.cc_at
  FROM x
  LEFT JOIN e ex ON ex.kind = 'database' AND ex.key = 'owner'
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_database_option o WHERE o.instance_id = x.instance_id AND o.is_present)
$$;
