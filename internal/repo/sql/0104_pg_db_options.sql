-- 0104: PostgreSQL database options and setting overrides in DBA Dash's colours (task 163, the rest of task 159).
--
--   pg_db_role_settings       every override of pg_db_role_setting (the dbsettings collection, hourly): ALTER DATABASE
--                             ... SET (scope database), ALTER ROLE ... SET (role), ALTER ROLE ... IN DATABASE ... SET
--                             (role in database), ALTER ROLE ALL SET (all roles); ALTER ROLE ALL IN DATABASE ... SET is
--                             stored by PostgreSQL as ALTER DATABASE's is and reads as scope database. raw_value as
--                             written (masked as the server's values are), value as pg_settings.setting would show it
--                             (base unit, on / off, an enum's name; the collector's dbSettingBase), value_read false
--                             where the text is no such value or a string. known false: pg_settings does not list the
--                             name to the collector (a placeholder, or a setting hidden from it). Replaced by each read;
--                             first_seen kept while the text stays the same.
--   pg_db_role_settings_read  the last read of each instance (an instance without any override has a read and no row).
--   setting_values            the values the rules judge: the server's (instance_settings, scope server) and every
--                             override whose value was read, with the instance's platform, version and replica flag.
--   setting_rules_scoped      0099's rules, word for word, over setting_values: one row per rule and value, server or
--                             override. Only the source and a scope key (k) are new: every rule row and the
--                             synchronous_commit pairing stay inside one scope. pgvigil.setting_rules is re-created
--                             as its server scope, with 0099's columns and rows (scripts/proof-pg-dboptions.sh compares
--                             the two on the same store), so pg_setting_rules and pgvigil.findings read what they read.
--   override_rules            one row per override with its status by the SAME rule as the server's value: crit (a
--                             critical rule broken), warn (a warning or advice rule broken), ok (every rule that
--                             applies here met), none (no rule of the setting applies here, the setting has no rule,
--                             or its value could not be read). severity, suggested and detail are the worst broken
--                             rule's; for a met one those of a rule that applies (0099's order).
--   pg_override_rules(i)      override_rules of one instance with the server's value and status beside each override.
--   pg_override_findings      a finding per override that breaks a rule, in pgvigil.findings' columns.
--   pg_db_options             one row per database, each cell with its status (ok / warn / crit / none = grey: not
--                             judged, or the version lacks it), severity and words: the connection limit against the
--                             sessions of the newest connections read (reached red, near - 80 % - yellow; an invalid
--                             database, datconnlimit -2, red; a limit of 0 yellow; below the limit on a read that folded
--                             its smallest sources grey: the count is a floor), allow
--                             connections off on a database that is not a template, an encoding other than UTF8
--                             (advice), the collation version recorded against the library's now (PostgreSQL 15+,
--                             the versions collection), data checksums (the cluster's, on each row: corruption
--                             findings' severity by platform), age(datfrozenxid) against autovacuum_freeze_max_age
--                             (at or past it yellow, past 1 billion red).
--   pg_dboption_findings      a finding for the cells no other finding covers (the connection limit, allow connections,
--                             the encoding). The collation and checksums cells have theirs (version_findings,
--                             corruption_findings); the xid age cell's is 'database xid age', which starts at 300
--                             million and leaves the templates out, so a yellow xid cell under it has no finding.
--   pg_dboption_risks         the fleet's risk counts per active PostgreSQL instance (the twin of 0090's
--                             mssql_option_risks): databases at their connection limit and near it, connections not
--                             allowed, not UTF8, collation mismatch, checksums off, xid age past the freeze age, and
--                             the overrides that break a rule.
-- Nothing here grows by the month: purge() has nothing to do. The findings arms are the join's (0110).

CREATE TABLE IF NOT EXISTS pgvigil.pg_db_role_settings (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  scope        text NOT NULL CHECK (scope IN ('database', 'role', 'role in database', 'all roles')),
  dbid         bigint NOT NULL DEFAULT 0,       -- pg_database's oid, 0 = every database
  datname      text NOT NULL DEFAULT '',
  roleid       bigint NOT NULL DEFAULT 0,       -- pg_roles' oid, 0 = every role
  rolname      text NOT NULL DEFAULT '',
  name         text NOT NULL,
  raw_value    text,                            -- as ALTER ... SET wrote it
  value        text,                            -- as pg_settings.setting would show it; raw_value when value_read is false
  value_read   boolean NOT NULL DEFAULT false,
  vartype      text,                            -- pg_settings' vartype, unit, context, boot_val; NULL for a placeholder
  unit         text,
  context      text,
  boot_val     text,
  known        boolean,                         -- pg_settings lists it to the collector (false: a placeholder or hidden)
  first_seen   timestamptz NOT NULL,            -- the first read that found this text
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, scope, dbid, roleid, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_db_role_settings_read (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at  timestamptz NOT NULL,
  overrides    int NOT NULL
);

-- payload: {kind:'setting', scope, dbid, datname, roleid, rolname, name, raw_value, value, value_read, vartype, unit,
-- context, boot_val, known} per override and one {kind:'read'} at the end. A payload without the read row (cut short)
-- and a read older than the stored one change nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_dbsettings(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'array'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'read')
     OR EXISTS (SELECT 1 FROM pgvigil.pg_db_role_settings_read x WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_snapshot_at) THEN
    RETURN;
  END IF;

  DELETE FROM pgvigil.pg_db_role_settings o
   WHERE o.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'setting' AND r->>'scope' = o.scope AND (r->>'dbid')::bigint = o.dbid
                        AND (r->>'roleid')::bigint = o.roleid AND r->>'name' = o.name);

  INSERT INTO pgvigil.pg_db_role_settings AS o (instance_id, scope, dbid, datname, roleid, rolname, name, raw_value, value,
                                                value_read, vartype, unit, context, boot_val, known, first_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'scope', (r->>'dbid')::bigint, (r->>'roleid')::bigint, r->>'name')
         p_instance_id, r->>'scope', coalesce((r->>'dbid')::bigint, 0), coalesce(r->>'datname', ''),
         coalesce((r->>'roleid')::bigint, 0), coalesce(r->>'rolname', ''), r->>'name', r->>'raw_value', r->>'value',
         coalesce((r->>'value_read')::boolean, false), r->>'vartype', r->>'unit', r->>'context', r->>'boot_val',
         (r->>'known')::boolean, p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'setting' AND r->>'name' IS NOT NULL AND r->>'scope' IN ('database', 'role', 'role in database', 'all roles')
  ON CONFLICT (instance_id, scope, dbid, roleid, name) DO UPDATE SET
    datname = EXCLUDED.datname, rolname = EXCLUDED.rolname, raw_value = EXCLUDED.raw_value, value = EXCLUDED.value,
    value_read = EXCLUDED.value_read, vartype = EXCLUDED.vartype, unit = EXCLUDED.unit, context = EXCLUDED.context,
    boot_val = EXCLUDED.boot_val, known = EXCLUDED.known,
    first_seen = CASE WHEN o.raw_value IS NOT DISTINCT FROM EXCLUDED.raw_value THEN o.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.pg_db_role_settings_read (instance_id, snapshot_at, overrides)
  SELECT p_instance_id, p_snapshot_at, count(*)::int FROM pgvigil.pg_db_role_settings WHERE instance_id = p_instance_id
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, overrides = EXCLUDED.overrides;
END $$;

-- the values the rules judge; k keeps each scope's rows together (server:0:0, database:<dbid>:0, ...)
CREATE OR REPLACE VIEW pgvigil.setting_values AS
SELECT s.instance_id, 'server:0:0'::text AS k, 'server'::text AS scope, 0::bigint AS dbid, ''::text AS datname,
       0::bigint AS roleid, ''::text AS rolname, s.snapshot_at, s.platform, s.server_version_num, s.is_replica,
       s.name, s.value, s.is_set
  FROM pgvigil.instance_settings s
UNION ALL
SELECT o.instance_id, o.scope || ':' || o.dbid::text || ':' || o.roleid::text, o.scope, o.dbid, o.datname, o.roleid, o.rolname,
       o.snapshot_at, st.platform, st.server_version_num, st.is_replica, o.name, o.value, true
  FROM pgvigil.pg_db_role_settings o
  JOIN pgvigil.instance_state st ON st.instance_id = o.instance_id
 WHERE o.value_read;

-- 0099's rules over setting_values (the rule lines are 0099's with k beside instance_id; nothing else changed)
CREATE OR REPLACE VIEW pgvigil.setting_rules_scoped AS
WITH v AS (
  SELECT instance_id, k, scope, dbid, datname, roleid, rolname, snapshot_at, platform, server_version_num, is_replica, name, value, is_set,
         CASE WHEN value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN value::numeric END AS num
    FROM pgvigil.setting_values
), r(instance_id, k, name, severity, suggested, platforms, detail, hit) AS (
  SELECT instance_id, k, name, 'critical', 'on', 'all', 'autovacuum is off: no dead-row cleanup and no anti-wraparound vacuum beyond the forced one',
         value <> 'on' FROM v WHERE name = 'autovacuum'
  UNION ALL SELECT instance_id, k, name, 'warning', '2', 'all', 'autovacuum_vacuum_cost_delay outside 2-20 ms: 0 (or -1, which takes vacuum_cost_delay, 0 by default) lets autovacuum saturate I/O, above 20 it crawls',
         num > 20 OR num = 0 OR num = -1 FROM v WHERE name = 'autovacuum_vacuum_cost_delay'
  UNION ALL SELECT instance_id, k, name, 'info', '3', 'self-managed', 'more autovacuum workers share one cost limit, so each runs slower',
         num > 3 AND platform = 'onprem' FROM v WHERE name = 'autovacuum_max_workers'
  UNION ALL SELECT instance_id, k, name, 'warning', '200000000', 'all', 'autovacuum_freeze_max_age above 800 million leaves little room before wraparound',
         num > 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
  UNION ALL SELECT instance_id, k, name, 'warning', '0.9', 'not aurora', 'a low checkpoint_completion_target writes each checkpoint in a burst (I/O spikes)',
         num < 0.7 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_completion_target'
  UNION ALL SELECT instance_id, k, name, 'info', '1800', 'not aurora', 'checkpoints closer than 20 minutes apart: more full-page writes and WAL',
         num < 1200 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_timeout'
  UNION ALL SELECT instance_id, k, name, 'info', 'lz4', 'all', 'lz4 compresses TOAST faster than pglz',
         value <> 'lz4' AND server_version_num >= 140000 FROM v WHERE name = 'default_toast_compression'
  UNION ALL SELECT instance_id, k, name, 'info', 'on', 'self-managed', 'huge pages are not required: a large shared_buffers pays for its page tables in memory and TLB misses',
         value <> 'on' AND platform = 'onprem' FROM v WHERE name = 'huge_pages'
  UNION ALL SELECT instance_id, k, name, 'warning', '0', 'all', 'idle_session_timeout ends idle pooled connections the application still holds',
         num > 0 FROM v WHERE name = 'idle_session_timeout'
  UNION ALL SELECT instance_id, k, name, 'info', '5min', 'all', 'no limit on idle-in-transaction sessions: one forgotten transaction holds its locks and pins vacuum',
         num = 0 FROM v WHERE name = 'idle_in_transaction_session_timeout'
  UNION ALL SELECT instance_id, k, name, 'info', 'off', 'all', 'JIT on globally: short OLTP statements pay compile time; enable it per session for analytics',
         value = 'on' FROM v WHERE name = 'jit'
  UNION ALL SELECT instance_id, k, name, 'info', 'off', 'all', 'log_hostname makes a DNS lookup per connection',
         value = 'on' FROM v WHERE name = 'log_hostname'
  UNION ALL SELECT instance_id, k, name, 'info', 'on', 'all', 'lock waits past deadlock_timeout are not logged: blocking leaves no trace in the log',
         value = 'off' FROM v WHERE name = 'log_lock_waits'
  UNION ALL SELECT instance_id, k, name, 'info', '500', 'self-managed', 'more than 500 connections: use a pooler; every backend costs memory and snapshot work',
         num > 500 AND platform = 'onprem' FROM v WHERE name = 'max_connections'
  UNION ALL SELECT instance_id, k, name, 'warning', '30000', 'replica', 'under 30 s: queries on the standby are cancelled by replay conflicts',
         num >= 0 AND num < 30000 AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, k, name, 'info', '30000', 'replica', 'over 5 min (or -1, unlimited): a long standby query holds replay back and the standby lags',
         (num > 300000 OR num = -1) AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, k, name, 'info', '8192', 'not aurora', 'max_wal_size under 8 GB: checkpoints forced by WAL volume under load',
         num < 8192 AND platform <> 'aurora' FROM v WHERE name = 'max_wal_size'
  UNION ALL SELECT instance_id, k, name, 'info', '2048', 'not aurora', 'min_wal_size under 2 GB: WAL segments removed and re-created between bursts',
         num < 2048 AND platform <> 'aurora' FROM v WHERE name = 'min_wal_size'
  UNION ALL SELECT instance_id, k, name, 'info', '1.1', 'managed', 'managed storage is SSD-backed: random reads cost about what sequential ones do',
         num > 1.2 AND platform <> 'onprem' FROM v WHERE name = 'random_page_cost'
  UNION ALL SELECT instance_id, k, name, 'warning', '1', 'all', 'seq_page_cost is the unit every other cost is relative to; change random_page_cost instead',
         num <> 1 FROM v WHERE name = 'seq_page_cost'
  UNION ALL SELECT v.instance_id, v.k, v.name, 'warning', 'local', 'all', 'synchronous_standby_names is set with synchronous_commit on / remote_write / remote_apply: every commit waits for a standby (hangs when it is gone)',
         v.value <> '' AND c.value IN ('on', 'remote_write', 'remote_apply') FROM v JOIN v c ON c.instance_id = v.instance_id AND c.k = v.k AND c.name = 'synchronous_commit'
   WHERE v.name = 'synchronous_standby_names'
  UNION ALL SELECT instance_id, k, name, 'info', 'on', 'all', 'without I/O timing, statement and database read times are not measured',
         value = 'off' FROM v WHERE name = 'track_io_timing'
  UNION ALL SELECT instance_id, k, name, 'info', CASE WHEN server_version_num >= 150000 THEN 'lz4' ELSE 'on' END, 'not aurora',
         'full-page images go to WAL uncompressed', value = 'off' AND platform <> 'aurora' FROM v WHERE name = 'wal_compression'
  UNION ALL SELECT instance_id, k, name, 'info', 'fdatasync', 'self-managed', 'fdatasync or open_datasync is the safe and fast choice on Linux',
         value NOT IN ('fdatasync', 'open_datasync') AND platform = 'onprem' FROM v WHERE name = 'wal_sync_method'
  UNION ALL SELECT instance_id, k, name, 'warning', '60000', 'all', 'wal_sender_timeout 0: a dead standby connection is never noticed',
         num = 0 FROM v WHERE name = 'wal_sender_timeout'
  UNION ALL SELECT instance_id, k, name, 'warning', '65536', 'all', 'a global work_mem above 96 MB is multiplied by every sort and hash of every session',
         num > 98304 FROM v WHERE name = 'work_mem'
  UNION ALL SELECT instance_id, k, name, 'critical', 'off', 'all', 'zero_damaged_pages hides corruption by zeroing the damaged page (silent data loss)',
         value = 'on' FROM v WHERE name = 'zero_damaged_pages'
), c(instance_id, k, name, severity, suggested, platforms, detail, hit) AS (
  -- pg-collector's observations on settings (its autovacuum-off one is pg_gather's above)
  SELECT instance_id, k, name, 'critical', 'on', 'all', 'track_counts is off: autovacuum cannot see which tables need it and pg_stat_* stay empty',
         value <> 'on' FROM v WHERE name = 'track_counts'
  UNION ALL SELECT instance_id, k, name, 'warning', 'on', 'all', 'a planner method is switched off for every session: plans that need it degrade',
         value <> 'on' FROM v WHERE name IN ('enable_indexscan', 'enable_indexonlyscan')
  UNION ALL SELECT instance_id, k, name, 'warning', 'on', 'all', 'synchronous_commit off: the last commits are lost on a crash',
         value = 'off' FROM v WHERE name = 'synchronous_commit'
  UNION ALL SELECT instance_id, k, name, 'warning', 'none', 'all', 'log_statement all / mod logs every statement or every write: log volume and I/O',
         value IN ('all', 'mod') FROM v WHERE name = 'log_statement'
  UNION ALL SELECT instance_id, k, name, 'warning', '-1', 'all', 'log_min_duration_statement 0 logs every statement with its duration',
         num = 0 FROM v WHERE name = 'log_min_duration_statement'
  UNION ALL SELECT instance_id, k, name, 'warning', 'warning', 'all', 'a debug log level writes internal detail for every operation',
         value LIKE 'debug%' FROM v WHERE name = 'log_min_messages'
  UNION ALL SELECT instance_id, k, name, 'warning', 'off', 'all', 'per-statement parser / planner / executor statistics or parse-tree dumps go to the log',
         value = 'on' FROM v WHERE name IN ('log_parser_stats', 'log_planner_stats', 'log_executor_stats', 'log_statement_stats',
                                            'debug_print_parse', 'debug_print_rewritten', 'debug_print_plan')
  UNION ALL SELECT instance_id, k, name, 'info', '200000000', 'all', 'autovacuum_freeze_max_age above the 200 million default: anti-wraparound vacuums start later and do more at once',
         num > 200000000 AND num <= 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
)
SELECT v.instance_id, v.scope, v.dbid, v.datname, v.roleid, v.rolname, r.severity, r.name AS setting, v.value, v.is_set, r.suggested, r.platforms, r.detail,
       'pg_gather'::text AS source, v.snapshot_at AS at, coalesce(r.hit, false) AS hit,
       (CASE r.platforms WHEN 'self-managed' THEN v.platform = 'onprem' WHEN 'managed' THEN v.platform <> 'onprem'
                        WHEN 'not aurora' THEN v.platform <> 'aurora' WHEN 'replica' THEN coalesce(v.is_replica, false)
                        ELSE true END) AND NOT (v.server_version_num < 140000 AND r.name IN ('default_toast_compression', 'idle_session_timeout')) AS applies
  FROM r JOIN v ON v.instance_id = r.instance_id AND v.k = r.k AND v.name = r.name
UNION ALL
SELECT v.instance_id, v.scope, v.dbid, v.datname, v.roleid, v.rolname, c.severity, c.name, v.value, v.is_set, c.suggested, c.platforms, c.detail,
       'pg-collector', v.snapshot_at, coalesce(c.hit, false),
       (CASE c.platforms WHEN 'self-managed' THEN v.platform = 'onprem' WHEN 'managed' THEN v.platform <> 'onprem'
                        WHEN 'not aurora' THEN v.platform <> 'aurora' WHEN 'replica' THEN coalesce(v.is_replica, false)
                        ELSE true END) AND NOT (v.server_version_num < 140000 AND c.name IN ('default_toast_compression', 'idle_session_timeout'))
  FROM c JOIN v ON v.instance_id = c.instance_id AND v.k = c.k AND v.name = c.name;

-- the server's rows: 0099's view, its columns and rows unchanged
CREATE OR REPLACE VIEW pgvigil.setting_rules AS
SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at, hit, applies
  FROM pgvigil.setting_rules_scoped
 WHERE scope = 'server';

-- one row per override, graded as pg_setting_rules grades the server's setting
CREATE OR REPLACE VIEW pgvigil.override_rules AS
SELECT DISTINCT ON (o.instance_id, o.scope, o.dbid, o.roleid, o.name)
       o.instance_id, o.scope, o.dbid, o.datname, o.roleid, o.rolname, o.name AS setting, o.raw_value, o.value, o.value_read,
       o.vartype, o.unit, o.context, o.known, o.boot_val,
       CASE WHEN s.setting IS NULL OR NOT bool_or(s.applies) OVER w THEN 'none'
            WHEN s.hit AND s.applies AND s.severity = 'critical' THEN 'crit'
            WHEN s.hit AND s.applies THEN 'warn' ELSE 'ok' END AS status,
       CASE WHEN s.hit AND s.applies THEN s.severity END AS severity,
       s.suggested, s.platforms, s.detail, (count(s.setting) OVER w)::int AS rules, o.first_seen, o.snapshot_at
  FROM pgvigil.pg_db_role_settings o
  LEFT JOIN pgvigil.setting_rules_scoped s
    ON s.instance_id = o.instance_id AND s.scope = o.scope AND s.dbid = o.dbid AND s.roleid = o.roleid AND s.setting = o.name
WINDOW w AS (PARTITION BY o.instance_id, o.scope, o.dbid, o.roleid, o.name)
 ORDER BY o.instance_id, o.scope, o.dbid, o.roleid, o.name, (s.hit AND s.applies) DESC NULLS LAST, s.applies DESC NULLS LAST,
          CASE s.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, s.detail;

-- the statement that set an override, as words: ALTER DATABASE d SET / ALTER ROLE r SET / ALTER ROLE r IN DATABASE d SET /
-- ALTER ROLE ALL SET
CREATE OR REPLACE FUNCTION pgvigil.override_statement(p_scope text, p_datname text, p_rolname text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_scope WHEN 'database' THEN 'ALTER DATABASE ' || quote_ident(p_datname) || ' SET'
                      WHEN 'role' THEN 'ALTER ROLE ' || quote_ident(p_rolname) || ' SET'
                      WHEN 'role in database' THEN 'ALTER ROLE ' || quote_ident(p_rolname) || ' IN DATABASE ' || quote_ident(p_datname) || ' SET'
                      WHEN 'all roles' THEN 'ALTER ROLE ALL SET' END
$$;

-- one instance's overrides, the worst first, each with the server's value (the value pg_setting_rules judges; for a
-- setting without a rule the instance read's server-level value, else the compiled-in default; none for a setting the
-- collector does not see) and the server's status and severity
CREATE OR REPLACE FUNCTION pgvigil.pg_override_rules(p_instance_id int)
RETURNS TABLE (scope text, dbid bigint, datname text, roleid bigint, rolname text, setting text, statement text, raw_value text,
               value text, value_read boolean, vartype text, unit text, context text, known boolean, status text, severity text,
               suggested text, platforms text, detail text, rules int, server_value text, server_is_set boolean,
               server_status text, server_severity text, server_rules int, server_from_override boolean,
               first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT o.scope, o.dbid, o.datname, o.roleid, o.rolname, o.setting, pgvigil.override_statement(o.scope, o.datname, o.rolname),
         o.raw_value, o.value, o.value_read, o.vartype, o.unit, o.context, o.known, o.status, o.severity, o.suggested,
         o.platforms, o.detail, o.rules,
         CASE WHEN coalesce(o.known, false) OR g.setting IS NOT NULL THEN coalesce(g.value, nd.value, o.boot_val) END,
         coalesce(g.is_set, nd.value IS NOT NULL), g.status, g.severity, g.rules,
         -- the instance read takes ALTER ROLE ALL SET (source global) and an override of the database the collector
         -- connects to (source database) as server-level values: there the server's value may be this override's own
         o.scope = 'all roles' OR (o.scope = 'database' AND o.datname = st.connected_database),
         o.first_seen, o.snapshot_at
    FROM pgvigil.override_rules o
    LEFT JOIN pgvigil.pg_setting_rules(p_instance_id) g ON g.setting = o.setting
    LEFT JOIN pgvigil.instance_state st ON st.instance_id = o.instance_id
    LEFT JOIN LATERAL (SELECT x->>'value' AS value FROM jsonb_array_elements(coalesce(st.non_default_settings, '[]'::jsonb)) x
                        WHERE x->>'name' = o.setting LIMIT 1) nd ON true
   WHERE o.instance_id = p_instance_id
   ORDER BY CASE o.status WHEN 'crit' THEN 0 WHEN 'warn' THEN 1 WHEN 'ok' THEN 2 ELSE 3 END, o.setting, o.scope, o.datname, o.rolname
$$;

CREATE OR REPLACE VIEW pgvigil.pg_override_findings AS
SELECT o.instance_id, o.severity, o.setting,
       substr(pgvigil.override_statement(o.scope, o.datname, o.rolname), 7) || ' ' || o.setting || ' = ' || coalesce(o.raw_value, '') AS value,
       true AS is_set, o.suggested, o.platforms,
       'override of the server''s value: ' || o.detail AS detail,
       'pgvigil'::text AS source, o.snapshot_at AS at
  FROM pgvigil.override_rules o
 WHERE o.status IN ('crit', 'warn');

-- one row per database; per cell <cell>_status (ok / warn / crit / none), <cell>_severity (of a deviation) and
-- <cell>_note (the cell's words)
CREATE OR REPLACE VIEW pgvigil.pg_db_options AS
WITH n0 AS (    -- the newest connections read of each instance in the last 10 minutes (the collection runs every minute)
  SELECT c.instance_id, max(c.snapshot_at) AS at
    FROM pgvigil.conn_sources c
   WHERE c.snapshot_at > now() - interval '10 minutes'
   GROUP BY 1
), n AS (       -- folded: the read put its smallest sources under '(other sources)', so a database's count is a floor
  SELECT n0.instance_id, n0.at,
         EXISTS (SELECT 1 FROM pgvigil.conn_sources c WHERE c.instance_id = n0.instance_id AND c.snapshot_at = n0.at
                    AND c.datname = '(other sources)') AS folded
    FROM n0
), cs AS (
  SELECT c.instance_id, c.datname, sum(c.total)::int AS sessions
    FROM pgvigil.conn_sources c JOIN n ON n.instance_id = c.instance_id AND n.at = c.snapshot_at
   GROUP BY 1, 2
), b AS (
  SELECT d.instance_id, d.dbid, d.datname, d.is_template, d.allow_conn, d.conn_limit, d.encoding, d.xid_age, d.snapshot_at,
         st.platform, st.server_version_num, st.data_checksums, n.at AS sessions_at, coalesce(n.folded, false) AS folded,
         CASE WHEN n.at IS NOT NULL THEN coalesce(cs.sessions, 0) END AS sessions,
         fm.v AS freeze_max_age,
         co.dbid IS NOT NULL AS collation_read, co.provider, co.locale, co.recorded_version, co.actual_version
    FROM pgvigil.databases d
    JOIN pgvigil.instance_state st ON st.instance_id = d.instance_id
    LEFT JOIN n ON n.instance_id = d.instance_id
    LEFT JOIN cs ON cs.instance_id = d.instance_id AND cs.datname = d.datname
    LEFT JOIN LATERAL (SELECT CASE WHEN x->>'value' ~ '^[0-9]+$' THEN (x->>'value')::bigint END AS v
                         FROM jsonb_array_elements(coalesce(st.non_default_settings, '[]'::jsonb)) x
                        WHERE x->>'name' = 'autovacuum_freeze_max_age' LIMIT 1) fx ON true
    CROSS JOIN LATERAL (SELECT coalesce(fx.v, 200000000) AS v) fm
    LEFT JOIN pgvigil.database_collations co ON co.instance_id = d.instance_id AND co.dbid = d.dbid AND co.is_present
   WHERE d.is_present
), j AS (
  SELECT b.*,
    -- the connection limit against the sessions now (a superuser is not held to it; the count is every client session
    -- of the newest read but the collector's own)
    -- datconnlimit -2 (PostgreSQL 13.12, 14.9, 15.4, 16 and later): an interrupted DROP DATABASE left it invalid
    CASE WHEN b.conn_limit = -2 THEN 'crit' WHEN NOT coalesce(b.allow_conn, true) OR b.conn_limit IS NULL THEN 'none'
         WHEN b.conn_limit < 0 THEN 'ok' WHEN b.conn_limit = 0 THEN 'warn'
         WHEN b.sessions IS NULL THEN 'none' WHEN b.sessions >= b.conn_limit THEN 'crit'
         WHEN b.folded THEN 'none' WHEN b.sessions >= 0.8 * b.conn_limit THEN 'warn' ELSE 'ok' END AS conn_status,
    CASE WHEN b.conn_limit = -2 THEN 'invalid: an interrupted DROP DATABASE left it; no session can connect and only DROP DATABASE removes it'
         WHEN NOT coalesce(b.allow_conn, true) THEN 'not judged: connections are not allowed'
         WHEN b.conn_limit IS NULL THEN 'not read' WHEN b.conn_limit < 0 THEN 'no limit'
         WHEN b.conn_limit = 0 THEN 'closed: CONNECTION LIMIT 0 lets only a superuser in'
         WHEN b.sessions IS NULL THEN 'sessions not read in the last 10 minutes (the connections collection)'
         WHEN b.sessions >= b.conn_limit THEN 'reached: a new session of a login that is not a superuser is refused'
         WHEN b.folded THEN 'not judged: the read folded its smallest connection sources into (other sources), so the count is a floor'
         WHEN b.sessions >= 0.8 * b.conn_limit THEN 'near: 80 % or more of the limit in use' ELSE 'room' END AS conn_note,
    -- allow connections
    CASE WHEN b.allow_conn IS NULL OR b.conn_limit = -2 THEN 'none' WHEN coalesce(b.is_template, false) THEN 'none' WHEN b.allow_conn THEN 'ok' ELSE 'warn' END AS allow_status,
    CASE WHEN b.allow_conn IS NULL THEN 'not read' WHEN b.conn_limit = -2 THEN 'an invalid database: not judged'
         WHEN coalesce(b.is_template, false) THEN 'a template: not judged'
         WHEN b.allow_conn THEN 'allowed' ELSE 'not allowed: no session can use the database (ALTER DATABASE ... ALLOW_CONNECTIONS true opens it)' END AS allow_note,
    -- encoding
    -- template0's encoding binds nothing: CREATE DATABASE ... TEMPLATE template0 takes any encoding
    CASE WHEN b.encoding IS NULL OR b.datname = 'template0' THEN 'none' WHEN b.encoding = 'UTF8' THEN 'ok' ELSE 'warn' END AS encoding_status,
    CASE WHEN b.encoding IS NULL THEN 'not read' WHEN b.datname = 'template0' THEN b.encoding || ' (template0: CREATE DATABASE ... TEMPLATE template0 takes any encoding)'
         WHEN b.encoding = 'UTF8' THEN 'UTF8'
         WHEN b.encoding = 'SQL_ASCII' THEN 'SQL_ASCII stores bytes unchecked: no character is validated or converted'
         ELSE 'not UTF8: characters outside ' || b.encoding || ' cannot be stored' END AS encoding_note,
    -- the collation version (PostgreSQL 15+)
    CASE WHEN b.server_version_num < 150000 THEN 'none' WHEN NOT b.collation_read THEN 'none'
         WHEN b.recorded_version IS NULL OR b.actual_version IS NULL THEN 'none'
         WHEN b.recorded_version <> b.actual_version THEN 'warn' ELSE 'ok' END AS collation_status,
    CASE WHEN b.server_version_num < 150000 THEN 'PostgreSQL 15+ records it'
         WHEN NOT b.collation_read THEN 'not read (the versions collection reads the databases the login may connect to)'
         WHEN b.recorded_version IS NULL OR b.actual_version IS NULL THEN 'the locale has no version (C, POSIX or the builtin provider)'
         WHEN b.recorded_version <> b.actual_version THEN 'recorded ' || b.recorded_version || ', the library now ' || b.actual_version
              || ': text indexes may be out of order; REINDEX them, then ALTER DATABASE ... REFRESH COLLATION VERSION'
         ELSE 'recorded ' || b.recorded_version || ' = the library''s' END AS collation_note,
    -- data checksums (the cluster's): the severity is corruption_findings'
    CASE WHEN b.data_checksums IS NULL OR b.platform = 'aurora' THEN 'none' WHEN b.data_checksums = 'on' THEN 'ok' ELSE 'warn' END AS checksums_status,
    CASE WHEN b.data_checksums IS NULL THEN 'not read' WHEN b.platform = 'aurora' THEN 'Aurora''s storage checks its own pages: not judged'
         WHEN b.data_checksums = 'on' THEN 'on'
         WHEN b.platform = 'onprem' THEN 'off: a damaged page is read as good data (pg_checksums --enable on the stopped cluster)'
         ELSE 'off: a damaged page is read as good data; the platform cannot turn them on in place' END AS checksums_note,
    -- age(datfrozenxid) against autovacuum_freeze_max_age
    CASE WHEN b.xid_age IS NULL THEN 'none' WHEN b.xid_age >= 1000000000 THEN 'crit' WHEN b.xid_age >= b.freeze_max_age THEN 'warn' ELSE 'ok' END AS xid_status,
    CASE WHEN b.xid_age IS NULL THEN 'not read' WHEN b.xid_age >= 1000000000 THEN 'past 1 billion: find what holds vacuum back before the 2 billion stop'
         WHEN b.xid_age >= b.freeze_max_age THEN 'past autovacuum_freeze_max_age (' || b.freeze_max_age || '): the anti-wraparound vacuum is due; staying here means it is held back'
         ELSE 'under autovacuum_freeze_max_age (' || b.freeze_max_age || ')' END AS xid_note
    FROM b
)
SELECT j.instance_id, j.dbid, j.datname, j.is_template, j.snapshot_at, j.platform, j.server_version_num,
       j.conn_limit, j.sessions, j.sessions_at, j.conn_status, CASE j.conn_status WHEN 'crit' THEN 'critical' WHEN 'warn' THEN 'warning' END AS conn_severity, j.conn_note,
       j.allow_conn, j.allow_status, CASE WHEN j.allow_status = 'warn' THEN 'warning' END AS allow_severity, j.allow_note,
       j.encoding, j.encoding_status, CASE WHEN j.encoding_status = 'warn' THEN 'info' END AS encoding_severity, j.encoding_note,
       j.provider AS collation_provider, j.locale AS collation_locale, j.recorded_version, j.actual_version,
       j.collation_status, CASE WHEN j.collation_status = 'warn' THEN 'warning' END AS collation_severity, j.collation_note,
       j.data_checksums, j.checksums_status,
       CASE WHEN j.checksums_status = 'warn' THEN CASE WHEN j.platform = 'onprem' THEN 'warning' ELSE 'info' END END AS checksums_severity, j.checksums_note,
       j.xid_age, j.freeze_max_age, j.xid_status,
       CASE j.xid_status WHEN 'crit' THEN 'critical' WHEN 'warn' THEN 'warning' END AS xid_severity, j.xid_note,
       (j.conn_status IN ('warn', 'crit'))::int + (j.allow_status = 'warn')::int + (j.encoding_status = 'warn')::int
         + (j.collation_status = 'warn')::int + (j.checksums_status = 'warn')::int + (j.xid_status IN ('warn', 'crit'))::int AS deviations,
       CASE WHEN 'crit' IN (j.conn_status, j.xid_status) THEN 'crit'
            WHEN 'warn' IN (j.conn_status, j.allow_status, j.encoding_status, j.collation_status, j.checksums_status, j.xid_status) THEN 'warn'
            ELSE 'ok' END AS worst
  FROM j;

CREATE OR REPLACE VIEW pgvigil.pg_dboption_findings AS
SELECT o.instance_id, o.conn_severity AS severity, 'database connection limit' AS setting,
       o.datname || ': limit ' || o.conn_limit::text AS value, true AS is_set,
       CASE WHEN o.conn_limit = -2 THEN 'DROP DATABASE' ELSE 'a higher CONNECTION LIMIT, or fewer sessions' END AS suggested, 'all' AS platforms,
       CASE WHEN o.conn_limit = -2 THEN 'the database is invalid (datconnlimit -2): an interrupted DROP DATABASE left it; no session can connect and only DROP DATABASE removes it'
            WHEN o.conn_limit = 0 THEN 'the database''s CONNECTION LIMIT is 0: only a superuser can connect'
            WHEN o.conn_status = 'crit' THEN 'the database''s CONNECTION LIMIT is reached: a new session of a login that is not a superuser is refused (too many connections for database)'
            ELSE 'the database''s sessions are at 80 % or more of its CONNECTION LIMIT: past it a new session is refused' END AS detail,
       'pgvigil'::text AS source, coalesce(o.sessions_at, o.snapshot_at) AS at
  FROM pgvigil.pg_db_options o
 WHERE o.conn_status IN ('warn', 'crit')
UNION ALL
SELECT o.instance_id, 'warning', 'database allow connections', o.datname, true, 'true, if the database is not meant to be closed', 'all',
       'the database does not allow connections (datallowconn false) and is not a template: no session can use it',
       'pgvigil', o.snapshot_at
  FROM pgvigil.pg_db_options o
 WHERE o.allow_status = 'warn'
UNION ALL
SELECT o.instance_id, 'info', 'database encoding', o.datname || ': ' || o.encoding, true, 'UTF8', 'all',
       'the database''s encoding is not UTF8: ' || o.encoding_note || ' (a new UTF8 database and a dump and restore change it)',
       'pgvigil', o.snapshot_at
  FROM pgvigil.pg_db_options o
 WHERE o.encoding_status = 'warn';

-- the fleet's risk counts: per active PostgreSQL instance the databases behind each risk (each count opens them)
CREATE OR REPLACE VIEW pgvigil.pg_dboption_risks AS
SELECT i.instance_id, i.name AS instance_name,
       x.read_at AS databases_read_at, coalesce(x.databases, 0) AS databases, coalesce(x.user_databases, 0) AS user_databases,
       coalesce(x.at_limit, 0) AS at_limit, coalesce(x.near_limit, 0) AS near_limit, coalesce(x.no_connections, 0) AS no_connections,
       coalesce(x.not_utf8, 0) AS not_utf8, coalesce(x.collation_mismatch, 0) AS collation_mismatch,
       coalesce(x.checksums_off, 0) AS checksums_off, coalesce(x.xid_past_freeze, 0) AS xid_past_freeze,
       coalesce(x.xid_critical, 0) AS xid_critical,
       r.snapshot_at AS overrides_read_at, coalesce(r.overrides, 0) AS overrides,
       coalesce(v.broken, 0) AS overrides_broken, coalesce(v.critical, 0) AS overrides_critical
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (
    SELECT max(o.snapshot_at) AS read_at, count(*)::int AS databases,
           count(*) FILTER (WHERE NOT coalesce(o.is_template, false))::int AS user_databases,
           count(*) FILTER (WHERE o.conn_status = 'crit')::int AS at_limit,
           count(*) FILTER (WHERE o.conn_status = 'warn')::int AS near_limit,
           count(*) FILTER (WHERE o.allow_status = 'warn')::int AS no_connections,
           count(*) FILTER (WHERE o.encoding_status = 'warn')::int AS not_utf8,
           count(*) FILTER (WHERE o.collation_status = 'warn')::int AS collation_mismatch,
           count(*) FILTER (WHERE o.checksums_status = 'warn')::int AS checksums_off,
           count(*) FILTER (WHERE o.xid_status IN ('warn', 'crit'))::int AS xid_past_freeze,
           count(*) FILTER (WHERE o.xid_status = 'crit')::int AS xid_critical
      FROM pgvigil.pg_db_options o
     WHERE o.instance_id = i.instance_id) x ON true
  LEFT JOIN pgvigil.pg_db_role_settings_read r ON r.instance_id = i.instance_id
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE o.status IN ('warn', 'crit'))::int AS broken, count(*) FILTER (WHERE o.status = 'crit')::int AS critical
      FROM pgvigil.override_rules o
     WHERE o.instance_id = i.instance_id) v ON true
 WHERE i.engine = 'postgres' AND i.is_active;
