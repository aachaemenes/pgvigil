-- 0142_hadr_mssql_repl: SQL Server replication depth (task 385; build list item 3 of the HA pass). The mssql_replication
-- collection (internal/mssql/replication.go) now reads the publisher side too, and each agent's job, failing time,
-- error text and the age of the oldest command waiting for a subscription; this file stores and judges them.
--
--   1. Thresholds: pg_threshold_keys gains 'engines' (the engines whose instances take a key at the instance level);
--      uptime is both engines' as before, every other key PostgreSQL's; three SQL Server keys: repl_latency (5 / 30
--      minutes, the HA design's H2), repl_agent_retrying (10 minutes, H2), repl_agent_silent (15 minutes, pgvigil's
--      own default: an idle agent rewrites its history row every 60 s, -MessageInterval's default). Each is set at the
--      root, a tag or an instance (the Thresholds page, import_pg_threshold; its instance check now reads 'engines').
--   2. mssql_replication_state gains the new columns and the kind 'published_db' (the publisher side: one row per
--      published database, distribution_db '').
--   3. mssql_repl_sample (monthly partitions): per read and series (a distribution agent, a log reader, snapshot or
--      merge agent: distribution database + agent name; a published database: 'published:' + its name) the judged
--      latency, the agent's own last latency, the commands waiting, the delivery rate, the publisher's pending
--      transactions and transactions read out per second, the state. mssql_repl_hourly: per hour and series the
--      min / avg / max of each, kept a year (the import trims it); mssql_repl_series() draws from the reads up to
--      two days and from the hours past that.
--   4. import_mssql_replication again (0066's, with the new kind and columns, the samples and the hours).
--   5. mssql_repl_findings: the replication findings (0066's two arms, moved here and widened, and five new ones);
--      mssql_hadr_findings again: 0066's text without its two replication arms, with one UNION ALL of this view.
--
-- The judged latency of a subscription is the age, at the read and on the distributor's own clock, of the oldest
-- transaction in the distribution database still waiting for it (0 when nothing waits): it grows while the agent
-- is stopped, blocked or retrying, where the agent's own last latency (its history row) stays as it was. Only a
-- subscription whose agent runs continuously is judged on it: a scheduled agent's commands wait for its next run. The time between the publisher's commit and
-- the transaction's entry into the distribution database is the log reader's; it is judged from the publisher side
-- ('replicated transactions wait in the log of a published database').
-- Not stored or judged here: tracer tokens (a write), merge agents' failing time and error text (merge replication
-- is not proven: SQL Server on Linux has none), peer-to-peer and Oracle publishing.
-- The join's parts: the purge of mssql_repl_sample's partitions (its name in the purge list), the page.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Thresholds

ALTER TABLE pgvigil.pg_threshold_keys ADD COLUMN IF NOT EXISTS engines text[] NOT NULL DEFAULT '{postgres}';
COMMENT ON COLUMN pgvigil.pg_threshold_keys.engines IS 'the engines whose instances take this key at the instance and database level (the root and a tag name no instance)';
UPDATE pgvigil.pg_threshold_keys SET engines = '{postgres,sqlserver}' WHERE key = 'uptime';
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value, engines) VALUES
  ('repl_latency',        'Replication (SQL Server): a subscription''s latency, the oldest command waiting for it', 'minutes', 'over', 5, 30, '{root,tag,instance}', 525600, '{sqlserver}'),
  ('repl_agent_retrying', 'Replication (SQL Server): an agent failing or retrying',                                  'minutes', 'over', 10, NULL, '{root,tag,instance}', 525600, '{sqlserver}'),
  ('repl_agent_silent',   'Replication (SQL Server): a running agent that writes no history, or a published database''s log not read', 'minutes', 'over', 15, NULL, '{root,tag,instance}', 525600, '{sqlserver}')
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value,
  engines = EXCLUDED.engines;

-- import_pg_threshold: 0117's, with one change - an instance or database level asks the key's engines
-- (pg_threshold_keys.engines) instead of PostgreSQL or the uptime key; the messages are 0117's for its keys.
CREATE OR REPLACE FUNCTION pgvigil.import_pg_threshold(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_key   text := p_payload->>'key';
  v_level text := p_payload->>'level';
  v_inst  int;
  v_tag   text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_db    text := nullif(p_payload->>'datname', '');
  v_k     pgvigil.pg_threshold_keys%ROWTYPE;
  v_warn  numeric;
  v_crit  numeric;
  v_why   text;
  v_old   bigint;
  v_new   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_pg_threshold: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  SELECT * INTO v_k FROM pgvigil.pg_threshold_keys WHERE key = v_key;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_k.key IS NULL THEN
    v_why := format('no threshold key %s (known: %s)', coalesce(v_key, '(none)'), (SELECT string_agg(key, ', ' ORDER BY key) FROM pgvigil.pg_threshold_keys));
  ELSIF v_level IS NULL OR NOT (v_level = ANY (v_k.levels)) THEN
    v_why := format('%s is set at the levels %s', v_key, array_to_string(v_k.levels, ', '));
  ELSIF v_level IN ('instance', 'database') AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst
                                                  AND i.engine = ANY (v_k.engines))) THEN
    -- the key's engines take it (0142): uptime both engines' (DBA Dash's Instance Uptime dialog, task 176b), the
    -- replication keys SQL Server's, every other key PostgreSQL's
    v_why := format(CASE WHEN v_k.engines = '{postgres}' THEN 'no PostgreSQL instance %s' WHEN v_k.engines = '{sqlserver}' THEN 'no SQL Server instance %s'
                         ELSE 'no instance %s' END, coalesce(p_payload->>'instance_id', '(none)'));
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_level = 'database' AND (v_db IS NULL OR length(v_db) > 63) THEN
    v_why := 'a database level names its database (63 characters at most)';
  ELSIF v_op = 'set' THEN
    FOR i IN 1..2 LOOP
      DECLARE v text := p_payload->>(CASE i WHEN 1 THEN 'warn' ELSE 'crit' END);
      BEGIN
        IF v IS NOT NULL AND v !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' THEN
          v_why := format('%s must be a number from 0 to %s (%s), or null', CASE i WHEN 1 THEN 'warn' ELSE 'crit' END, v_k.max_value, v_k.unit);
        ELSIF v IS NOT NULL AND v::numeric > v_k.max_value THEN
          v_why := format('%s must be a number from 0 to %s (%s), or null', CASE i WHEN 1 THEN 'warn' ELSE 'crit' END, v_k.max_value, v_k.unit);
        ELSIF v IS NOT NULL AND v_key = 'archive_age' AND (v !~ '^[0-9]+$' OR v::numeric < 1) THEN
          -- 0022's rule takes whole minutes (archive_warn_minutes is an int column there)
          v_why := format('archive_age takes whole minutes from 1 to %s, or null', v_k.max_value);
        END IF;
      END;
      EXIT WHEN v_why IS NOT NULL;
    END LOOP;
    IF v_why IS NULL THEN
      v_warn := (p_payload->>'warn')::numeric;
      v_crit := (p_payload->>'crit')::numeric;
      -- uptime and crash take a level with neither (DBA Dash's Enabled box off: not judged there, task P08)
      IF v_warn IS NULL AND v_crit IS NULL AND v_key NOT IN ('uptime', 'crash') THEN
        v_why := 'no threshold is set: to take the level above, inherit';
      ELSIF v_warn IS NOT NULL AND v_crit IS NOT NULL AND v_k.direction = 'over' AND v_crit < v_warn THEN
        v_why := format('%s: critical (%s) must be at or past warning (%s): the value grows toward it', v_key, v_crit, v_warn);
      ELSIF v_warn IS NOT NULL AND v_crit IS NOT NULL AND v_k.direction = 'under' AND v_crit > v_warn THEN
        v_why := format('%s: critical (%s) must be at or under warning (%s): the value falls toward it', v_key, v_crit, v_warn);
      END IF;
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_tag := NULL; v_db := NULL;
  ELSIF v_level = 'tag' THEN v_inst := NULL; v_db := NULL;
  ELSIF v_level = 'instance' THEN v_tag := NULL; v_db := NULL;
  ELSE v_tag := NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.pg_thresholds'), hashtext(v_key || '|' || v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_tag, '') || '|' || coalesce(v_db, '')));
  SELECT t.threshold_id INTO v_old FROM pgvigil.pg_thresholds t
   WHERE t.ended_at IS NULL AND t.key = v_key AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0)
     AND coalesce(t.tag, '') = coalesce(v_tag, '') AND coalesce(t.datname, '') = coalesce(v_db, '');
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no threshold of its own: it inherits already');
  END IF;
  UPDATE pgvigil.pg_thresholds SET ended_by = v_user, ended_at = p_at WHERE threshold_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'threshold_id', v_old);
  END IF;
  INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, tag, datname, warn, crit, created_by, created_at, client, replaces)
  VALUES (v_key, v_level, v_inst, v_tag, v_db, v_warn, v_crit, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING threshold_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'threshold_id', v_new);
END $$;


-- ---------------------------------------------------------------------------------------------------------------
-- 2. The current state: the new columns and the publisher side

ALTER TABLE pgvigil.mssql_replication_state
  ADD COLUMN IF NOT EXISTS agent_id             int,           -- the distribution database's id of the agent
  ADD COLUMN IF NOT EXISTS subscription_status  text,          -- subscription: active | subscribed | inactive (MSsubscriptions)
  ADD COLUMN IF NOT EXISTS session_start_at     timestamptz,   -- the start of the agent's run its last history row belongs to
  ADD COLUMN IF NOT EXISTS failing_since        timestamptz,   -- the first row after its last healthy one, while it fails or retries
  ADD COLUMN IF NOT EXISTS error_code           text,          -- MSrepl_errors of that failure
  ADD COLUMN IF NOT EXISTS error_text           text,
  ADD COLUMN IF NOT EXISTS oldest_pending_at    timestamptz,   -- subscription: the oldest transaction waiting for it (entry time)
  ADD COLUMN IF NOT EXISTS pending_age_s        int,           -- subscription: its age at the read, on the distributor's own clock
  ADD COLUMN IF NOT EXISTS job_state            text,          -- running | stopped | disabled | not here | Agent stopped; NULL: msdb not read
  ADD COLUMN IF NOT EXISTS continuous           boolean,       -- the job runs the agent with -Continuous
  ADD COLUMN IF NOT EXISTS job_stopped_at       timestamptz,   -- the job's last stop (sysjobactivity)
  ADD COLUMN IF NOT EXISTS database_name        text,          -- published_db: the published database
  ADD COLUMN IF NOT EXISTS distributor          text,          -- published_db: the distributor the publisher names
  ADD COLUMN IF NOT EXISTS distributor_local    boolean,       -- published_db: the distributor is this server
  ADD COLUMN IF NOT EXISTS log_reuse_wait       text,          -- published_db: sys.databases.log_reuse_wait_desc
  ADD COLUMN IF NOT EXISTS pending_xacts        bigint,        -- published_db: Repl. Pending Xacts (still in the log for the log reader)
  ADD COLUMN IF NOT EXISTS repl_trans_total     bigint;        -- published_db: Repl. Trans. Rate's raw (cumulative) value
ALTER TABLE pgvigil.mssql_replication_state DROP CONSTRAINT IF EXISTS mssql_replication_state_kind_check;
ALTER TABLE pgvigil.mssql_replication_state ADD CONSTRAINT mssql_replication_state_kind_check
  CHECK (kind IN ('publication', 'subscription', 'agent', 'published_db'));

-- ---------------------------------------------------------------------------------------------------------------
-- 3. History: a sample per read, an hour per series kept a year

CREATE TABLE IF NOT EXISTS pgvigil.mssql_repl_sample (
  instance_id       int NOT NULL,
  snapshot_at       timestamptz NOT NULL,
  series            text NOT NULL,      -- <distribution database>:<agent name>, or published:<database>
  kind              text NOT NULL,      -- subscription | agent | published_db
  agent_type        text,               -- distribution | logreader | snapshot | merge
  publisher         text,
  publisher_db      text,
  publication       text,
  subscriber        text,
  subscriber_db     text,
  runstatus         int,
  job_state         text,
  continuous        boolean,
  failing_since     timestamptz,
  last_run_at       timestamptz,
  latency_s         double precision,   -- subscription: the judged latency (the oldest waiting command's age; 0 when none waits)
  agent_latency_ms  bigint,             -- the agent's own last delivery latency (its history row)
  delivery_rate     double precision,
  undistributed     bigint,
  pending_xacts     bigint,
  repl_trans_total  bigint,
  trans_per_s       double precision    -- published_db: transactions read out per second since the series' previous read
) PARTITION BY RANGE (snapshot_at);
-- the findings, the import's previous read and the trend read one series of one instance over a window
CREATE INDEX IF NOT EXISTS mssql_repl_sample_series_idx ON pgvigil.mssql_repl_sample (instance_id, series, snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_repl_hourly (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  hour            timestamptz NOT NULL,
  series          text NOT NULL,
  kind            text NOT NULL,
  agent_type      text,
  publisher_db    text,
  publication     text,
  subscriber      text,
  subscriber_db   text,
  reads           int NOT NULL,
  latency_n       int NOT NULL DEFAULT 0, latency_min double precision, latency_sum double precision NOT NULL DEFAULT 0, latency_max double precision,
  und_n           int NOT NULL DEFAULT 0, und_min bigint, und_sum numeric NOT NULL DEFAULT 0, und_max bigint,
  rate_n          int NOT NULL DEFAULT 0, rate_min double precision, rate_sum double precision NOT NULL DEFAULT 0, rate_max double precision,
  pending_n       int NOT NULL DEFAULT 0, pending_min bigint, pending_sum numeric NOT NULL DEFAULT 0, pending_max bigint,
  trans_n         int NOT NULL DEFAULT 0, trans_min double precision, trans_sum double precision NOT NULL DEFAULT 0, trans_max double precision,
  failing_reads   int NOT NULL DEFAULT 0,
  stopped_reads   int NOT NULL DEFAULT 0,
  PRIMARY KEY (instance_id, hour, series)
);

-- the judged latency of a subscription: the age of the oldest command waiting for it (the distributor's own clock),
-- 0 when none waits, NULL when commands wait and their age was not read
CREATE OR REPLACE FUNCTION pgvigil.mssql_repl_latency(p_undistributed bigint, p_age_s int)
RETURNS double precision LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN coalesce(p_undistributed, 0) = 0 THEN 0 WHEN p_age_s IS NULL THEN NULL ELSE greatest(0, p_age_s) END
$$;

-- the state of an agent that counts as stopped (its job not running; SQL Server Agent itself not running)
CREATE OR REPLACE FUNCTION pgvigil.mssql_repl_stopped(p_job_state text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_job_state IN ('stopped', 'disabled', 'Agent stopped')
$$;

-- which kind of row a part of the collector's read feeds (a collector_error row names its source: <database>.dbo.<table>,
-- <database> alone when the login cannot enter it, 'published databases' for the publisher side)
CREATE OR REPLACE FUNCTION pgvigil.mssql_repl_kind(p_table text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_table WHEN 'MSpublications' THEN 'publication' WHEN 'MSdistribution_agents' THEN 'subscription'
                      WHEN 'MSlogreader_agents' THEN 'agent' END
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. The import

-- payload: 'publication', 'subscription' and 'agent' rows per distribution database; 'agent_job' rows (an agent's
-- job, merged into its row by distribution database, agent type and name); 'published_db' rows; collector_error rows.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_replication(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows  jsonb := pgvigil.mssql_rows(p_payload);
  v_again int;
BEGIN
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_replication', p_snapshot_at,
           (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' IN ('publication', 'subscription', 'agent', 'published_db'))) THEN
    RETURN;
  END IF;
  -- a read that failed keeps the last rows of ITS kind for that database (the publisher side: its rows); the kinds
  -- that were read are replaced. A failed read of the agents' jobs keeps nothing: their state is then unknown (NULL).
  DELETE FROM pgvigil.mssql_replication_state s
   WHERE s.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) e
                      WHERE e->>'kind' = 'collector_error'
                        AND CASE WHEN s.kind = 'published_db' THEN e->>'source' = 'published databases'
                                 ELSE split_part(e->>'source', '.dbo.', 1) = s.distribution_db
                                      AND coalesce(pgvigil.mssql_repl_kind(split_part(e->>'source', '.dbo.', 2)), s.kind) = s.kind END);
  INSERT INTO pgvigil.mssql_replication_state (instance_id, snapshot_at, kind, distribution_db, publisher, publisher_db, publication,
      publication_type, articles, subscriber, subscriber_db, subscription_type, agent_type, agent_name, runstatus, status_text,
      last_run_at, latency_ms, delivery_rate, undistributed, est_catchup_s,
      agent_id, subscription_status, session_start_at, failing_since, error_code, error_text, oldest_pending_at, pending_age_s,
      job_state, continuous, job_stopped_at, database_name, distributor, distributor_local, log_reuse_wait, pending_xacts, repl_trans_total)
  SELECT p_instance_id, p_snapshot_at, r->>'kind', coalesce(r->>'distribution_db', ''), r->>'publisher', r->>'publisher_db', r->>'publication',
         r->>'publication_type', (r->>'articles')::int, r->>'subscriber', r->>'subscriber_db', r->>'subscription_type',
         r->>'agent_type', r->>'agent_name', (r->>'runstatus')::int, r->>'status_text', (r->>'last_run_utc')::timestamptz,
         (r->>'latency_ms')::bigint, (r->>'delivery_rate')::float8, (r->>'undistributed')::bigint, (r->>'est_catchup_s')::float8,
         (r->>'agent_id')::int, r->>'subscription_status', (r->>'session_start_utc')::timestamptz, (r->>'failing_since_utc')::timestamptz,
         nullif(r->>'error_code', ''), nullif(r->>'error_text', ''), (r->>'oldest_pending_utc')::timestamptz, (r->>'oldest_pending_age_s')::int,
         j.job->>'job_state', (j.job->>'continuous')::int = 1, (j.job->>'job_stopped_utc')::timestamptz,
         r->>'database_name', r->>'distributor', (r->>'distributor_local')::int = 1, r->>'log_reuse_wait',
         (r->>'pending_xacts')::bigint, (r->>'repl_trans_total')::bigint
    FROM jsonb_array_elements(v_rows) r
    LEFT JOIN LATERAL (SELECT x AS job FROM jsonb_array_elements(v_rows) x
                        WHERE r->>'kind' IN ('subscription', 'agent') AND x->>'kind' = 'agent_job'
                          AND x->>'distribution_db' = r->>'distribution_db' AND x->>'agent_type' = r->>'agent_type'
                          AND x->>'agent_name' = r->>'agent_name'
                        LIMIT 1) j ON true
   WHERE (r->>'kind' IN ('publication', 'subscription', 'agent') AND r->>'distribution_db' IS NOT NULL)
      OR (r->>'kind' = 'published_db' AND r->>'database_name' IS NOT NULL);

  -- the samples of this read (a re-run of one read replaces its samples and adds nothing to the hours)
  PERFORM pgvigil.ensure_month_partition('mssql_repl_sample', p_snapshot_at);
  DELETE FROM pgvigil.mssql_repl_sample WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at;
  GET DIAGNOSTICS v_again = ROW_COUNT;
  INSERT INTO pgvigil.mssql_repl_sample (instance_id, snapshot_at, series, kind, agent_type, publisher, publisher_db, publication,
      subscriber, subscriber_db, runstatus, job_state, continuous, failing_since, last_run_at, latency_s, agent_latency_ms,
      delivery_rate, undistributed, pending_xacts, repl_trans_total, trans_per_s)
  SELECT s.instance_id, s.snapshot_at, x.series, s.kind, s.agent_type, s.publisher, s.publisher_db, s.publication,
         s.subscriber, s.subscriber_db, s.runstatus, s.job_state, s.continuous, s.failing_since, s.last_run_at,
         CASE WHEN s.kind = 'subscription' AND s.agent_type IS DISTINCT FROM 'merge' THEN pgvigil.mssql_repl_latency(s.undistributed, s.pending_age_s) END,
         s.latency_ms, s.delivery_rate, s.undistributed, s.pending_xacts, s.repl_trans_total,
         (SELECT CASE WHEN s.repl_trans_total >= p.repl_trans_total
                      THEN (s.repl_trans_total - p.repl_trans_total) / extract(epoch FROM s.snapshot_at - p.snapshot_at) END
            FROM pgvigil.mssql_repl_sample p
           WHERE s.kind = 'published_db' AND p.instance_id = s.instance_id AND p.series = x.series
             AND p.snapshot_at < s.snapshot_at AND p.snapshot_at > s.snapshot_at - interval '1 hour'
           ORDER BY p.snapshot_at DESC LIMIT 1)
    FROM pgvigil.mssql_replication_state s
    CROSS JOIN LATERAL (SELECT CASE WHEN s.kind = 'published_db' THEN 'published:' || s.database_name
                                    ELSE s.distribution_db || ':' || coalesce(s.agent_name, '?') END AS series) x
   WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.kind IN ('subscription', 'agent', 'published_db');

  IF v_again = 0 THEN
    INSERT INTO pgvigil.mssql_repl_hourly AS h (instance_id, hour, series, kind, agent_type, publisher_db, publication, subscriber, subscriber_db, reads,
        latency_n, latency_min, latency_sum, latency_max, und_n, und_min, und_sum, und_max, rate_n, rate_min, rate_sum, rate_max,
        pending_n, pending_min, pending_sum, pending_max, trans_n, trans_min, trans_sum, trans_max, failing_reads, stopped_reads)
    SELECT s.instance_id, date_trunc('hour', s.snapshot_at), s.series, s.kind, s.agent_type, s.publisher_db, s.publication, s.subscriber, s.subscriber_db, 1,
           (s.latency_s IS NOT NULL)::int, s.latency_s, coalesce(s.latency_s, 0), s.latency_s,
           (s.undistributed IS NOT NULL)::int, s.undistributed, coalesce(s.undistributed, 0), s.undistributed,
           (s.delivery_rate IS NOT NULL)::int, s.delivery_rate, coalesce(s.delivery_rate, 0), s.delivery_rate,
           (s.pending_xacts IS NOT NULL)::int, s.pending_xacts, coalesce(s.pending_xacts, 0), s.pending_xacts,
           (s.trans_per_s IS NOT NULL)::int, s.trans_per_s, coalesce(s.trans_per_s, 0), s.trans_per_s,
           (s.failing_since IS NOT NULL)::int, coalesce(s.continuous AND pgvigil.mssql_repl_stopped(s.job_state), false)::int
      FROM pgvigil.mssql_repl_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at
    ON CONFLICT (instance_id, hour, series) DO UPDATE SET
        reads = h.reads + 1,
        latency_n = h.latency_n + EXCLUDED.latency_n, latency_min = least(h.latency_min, EXCLUDED.latency_min),
        latency_sum = h.latency_sum + EXCLUDED.latency_sum, latency_max = greatest(h.latency_max, EXCLUDED.latency_max),
        und_n = h.und_n + EXCLUDED.und_n, und_min = least(h.und_min, EXCLUDED.und_min),
        und_sum = h.und_sum + EXCLUDED.und_sum, und_max = greatest(h.und_max, EXCLUDED.und_max),
        rate_n = h.rate_n + EXCLUDED.rate_n, rate_min = least(h.rate_min, EXCLUDED.rate_min),
        rate_sum = h.rate_sum + EXCLUDED.rate_sum, rate_max = greatest(h.rate_max, EXCLUDED.rate_max),
        pending_n = h.pending_n + EXCLUDED.pending_n, pending_min = least(h.pending_min, EXCLUDED.pending_min),
        pending_sum = h.pending_sum + EXCLUDED.pending_sum, pending_max = greatest(h.pending_max, EXCLUDED.pending_max),
        trans_n = h.trans_n + EXCLUDED.trans_n, trans_min = least(h.trans_min, EXCLUDED.trans_min),
        trans_sum = h.trans_sum + EXCLUDED.trans_sum, trans_max = greatest(h.trans_max, EXCLUDED.trans_max),
        failing_reads = h.failing_reads + EXCLUDED.failing_reads, stopped_reads = h.stopped_reads + EXCLUDED.stopped_reads,
        kind = EXCLUDED.kind, agent_type = EXCLUDED.agent_type, publisher_db = EXCLUDED.publisher_db, publication = EXCLUDED.publication,
        subscriber = EXCLUDED.subscriber, subscriber_db = EXCLUDED.subscriber_db;
    -- the hours are kept a year
    DELETE FROM pgvigil.mssql_repl_hourly WHERE instance_id = p_instance_id AND hour < p_snapshot_at - interval '1 year';
  END IF;
END $$;

-- mssql_repl_series: the replication trend of one instance in buckets of p_step seconds - the worst judged latency
-- (max, min and mean of the reads), the commands waiting and the transactions pending at the publisher (summed over
-- the series, each series' largest read of the bucket), the delivery rate and the transactions read out per second
-- (summed means), and how many series were failing or stopped in the bucket. Up to two days from the reads; past two
-- days from the hours (buckets of an hour at least).
CREATE OR REPLACE FUNCTION pgvigil.mssql_repl_series(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step int)
RETURNS TABLE (snapshot_at timestamptz, latency_s double precision, latency_s_min double precision, latency_s_avg double precision,
               undistributed numeric, delivery_rate double precision, pending_xacts numeric, trans_per_s double precision,
               failing int, stopped int, source text)
LANGUAGE sql STABLE AS $$
  WITH per AS (
    SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / greatest(p_step, 60)) * greatest(p_step, 60)) AS bucket, s.series,
           max(s.latency_s) AS lat_max, min(s.latency_s) AS lat_min, avg(s.latency_s) AS lat_avg,
           max(s.undistributed) AS und, avg(s.delivery_rate) AS rate, max(s.pending_xacts) AS pend, avg(s.trans_per_s) AS tps,
           bool_or(s.failing_since IS NOT NULL) AS failing, bool_or(s.continuous AND pgvigil.mssql_repl_stopped(s.job_state)) AS stopped
      FROM pgvigil.mssql_repl_sample s
     WHERE p_to - p_from <= interval '2 days' AND s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
     GROUP BY 1, 2
    UNION ALL
    SELECT to_timestamp(floor(extract(epoch FROM h.hour) / greatest(p_step, 3600)) * greatest(p_step, 3600)), h.series,
           max(h.latency_max), min(h.latency_min), sum(h.latency_sum) / nullif(sum(h.latency_n), 0),
           max(h.und_max), sum(h.rate_sum) / nullif(sum(h.rate_n), 0), max(h.pending_max), sum(h.trans_sum) / nullif(sum(h.trans_n), 0),
           sum(h.failing_reads) > 0, sum(h.stopped_reads) > 0
      FROM pgvigil.mssql_repl_hourly h
     WHERE p_to - p_from > interval '2 days' AND h.instance_id = p_instance_id AND h.hour > date_trunc('hour', p_from) - interval '1 hour' AND h.hour <= p_to
     GROUP BY 1, 2
  )
  SELECT p.bucket, max(p.lat_max), min(p.lat_min), max(p.lat_avg), sum(p.und), sum(p.rate), sum(p.pend), sum(p.tps),
         (count(*) FILTER (WHERE p.failing))::int, (count(*) FILTER (WHERE p.stopped))::int,
         CASE WHEN p_to - p_from <= interval '2 days' THEN 'reads' ELSE 'hours' END
    FROM per p
   GROUP BY p.bucket
   ORDER BY p.bucket
$$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Findings

-- mssql_repl_findings (instance_id, severity, check_name, object, at, detail): a state row older than 15 minutes
-- (the collection reads every 5) fires nothing. Each threshold is pg_threshold(instance, key): an instance's own row,
-- its tag's, the root's, the default.
CREATE OR REPLACE VIEW pgvigil.mssql_repl_findings AS
WITH fresh AS (
  SELECT s.* FROM pgvigil.mssql_replication_state s WHERE s.snapshot_at > now() - interval '15 minutes'
), thr AS (
  -- the thresholds in force, once per instance
  SELECT i.instance_id, rt.warn AS rt_warn, rt.crit AS rt_crit, coalesce(rt.warn, rt.crit) AS rt_min,
         sl.warn AS sl_warn, sl.crit AS sl_crit, coalesce(sl.warn, sl.crit) AS sl_min, la.warn AS lat_warn, la.crit AS lat_crit
    FROM (SELECT DISTINCT f.instance_id FROM fresh f) i
    CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'repl_agent_retrying') rt
    CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'repl_agent_silent') sl
    CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'repl_latency') la
), st AS (
  SELECT s.*,
         s.distribution_db || ':' || coalesce(s.agent_name, '?') AS series,
         coalesce(s.agent_type, s.kind) || ' / ' || coalesce(s.agent_name, '?') AS obj,
         t.rt_warn, t.rt_crit, t.rt_min, t.sl_warn, t.sl_crit, t.sl_min
    FROM fresh s JOIN thr t USING (instance_id)
   WHERE s.kind IN ('subscription', 'agent')
), ctx AS (
  -- the words that name an agent's publication or subscription in a finding
  SELECT st.*, format('the %s agent %s (publisher %s, database %s%s%s)', st.agent_type, coalesce(st.agent_name, '?'), coalesce(st.publisher, '?'),
                      coalesce(st.publisher_db, '?'), coalesce(', publication ' || st.publication, ''),
                      coalesce(', subscriber ' || st.subscriber || '.' || st.subscriber_db, '')) AS who,
         coalesce(' Error ' || st.error_code || ': ' || st.error_text, ' ' || st.error_text, '') AS err
    FROM st
), lat AS (
  -- a subscription whose agent runs continuously (or whose job was not read): a scheduled agent's commands wait for
  -- its next run by design and are not judged
  SELECT s.*, t.lat_warn, t.lat_crit, pgvigil.mssql_repl_latency(s.undistributed, s.pending_age_s) AS latency_s
    FROM fresh s JOIN thr t USING (instance_id)
   WHERE s.kind = 'subscription' AND s.continuous IS NOT FALSE AND s.agent_type IS DISTINCT FROM 'merge'
), pubdb AS (
  SELECT s.*, t.sl_warn, t.sl_crit, t.sl_min, w.ok_at, w.first_at, w.reads, w.cur_tps
    FROM fresh s JOIN thr t USING (instance_id)
    -- the publisher's reads of the last day: the newest one at which nothing waited or a transaction was read out;
    -- this read's rate (NULL after a gap of over an hour or a counter that went back: then nothing is judged)
    CROSS JOIN LATERAL (SELECT max(x.snapshot_at) FILTER (WHERE coalesce(x.pending_xacts, 0) = 0 OR x.trans_per_s > 0) AS ok_at,
                               min(x.snapshot_at) AS first_at, count(*) AS reads,
                               max(x.trans_per_s) FILTER (WHERE x.snapshot_at = s.snapshot_at) AS cur_tps
                          FROM pgvigil.mssql_repl_sample x
                         WHERE x.instance_id = s.instance_id AND x.series = 'published:' || s.database_name
                           AND x.snapshot_at > s.snapshot_at - interval '1 day' AND x.snapshot_at <= s.snapshot_at) w
   WHERE s.kind = 'published_db'
)
-- an agent failing or retrying (its newest history row a failure, or the collector's failing time: between a job's
-- retries a failing agent writes 'in progress' rows that deliver nothing), for less than its threshold (past it:
-- 'a replication agent keeps failing or retrying')
SELECT c.instance_id, 'warning'::text AS severity, 'a replication agent failed'::text AS check_name, c.obj AS object, c.snapshot_at AS at,
       format('%s %s %s. Its newest message (%s): %s%s', c.who,
              CASE WHEN c.runstatus = 5 THEN 'is retrying since' WHEN c.failing_since IS NOT NULL THEN 'has failed or retried since' ELSE 'failed at' END,
              coalesce(to_char(coalesce(c.failing_since, c.last_run_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), '?'),
              coalesce(to_char(c.last_run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), '?'), coalesce(c.status_text, 'none'), c.err) AS detail
  FROM ctx c
 WHERE (c.runstatus = 6 OR c.failing_since IS NOT NULL)
   AND NOT (c.failing_since IS NOT NULL AND c.rt_min IS NOT NULL AND c.failing_since <= c.snapshot_at - make_interval(secs => c.rt_min * 60))
UNION ALL
SELECT c.instance_id, CASE WHEN c.rt_crit IS NOT NULL AND c.failing_since <= c.snapshot_at - make_interval(secs => c.rt_crit * 60) THEN 'critical' ELSE 'warning' END,
       'a replication agent keeps failing or retrying', c.obj, c.snapshot_at,
       format('%s has failed or retried since %s (%s minutes before the read; threshold %s). Its last message: %s%s',
              c.who, to_char(c.failing_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
              round(extract(epoch FROM c.snapshot_at - c.failing_since) / 60), c.rt_min, coalesce(c.status_text, 'none'), c.err)
         || CASE WHEN coalesce(c.undistributed, 0) > 0 THEN format(' %s commands wait for it.', c.undistributed) ELSE '' END
  FROM ctx c
 WHERE c.failing_since IS NOT NULL AND c.rt_min IS NOT NULL AND c.failing_since <= c.snapshot_at - make_interval(secs => c.rt_min * 60)
UNION ALL
-- a continuous agent whose job is not running, at two reads in a row, while its publication has an active subscription
SELECT c.instance_id, 'warning', 'a replication agent is stopped', c.obj, c.snapshot_at,
       format('%s is meant to run all the time and its job is %s (%s)%s.', c.who,
              CASE c.job_state WHEN 'disabled' THEN 'disabled' WHEN 'Agent stopped' THEN 'not running: SQL Server Agent is stopped' ELSE 'not running' END,
              coalesce('stopped at ' || to_char(c.job_stopped_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'seen at two reads in a row'),
              CASE WHEN c.agent_type = 'logreader' THEN ': nothing new reaches the distribution database'
                   WHEN coalesce(c.undistributed, 0) > 0 THEN format(': %s commands wait for it', c.undistributed)
                   ELSE ': nothing is delivered to the subscriber' END)
  FROM ctx c
 WHERE c.continuous AND pgvigil.mssql_repl_stopped(c.job_state)
   AND EXISTS (SELECT 1 FROM pgvigil.mssql_replication_state a
                WHERE a.instance_id = c.instance_id AND a.kind = 'subscription' AND (a.subscription_status = 'active' OR a.agent_type = 'merge')
                  AND a.distribution_db = c.distribution_db AND a.publisher_db = c.publisher_db AND a.publisher IS NOT DISTINCT FROM c.publisher
                  AND (c.agent_type = 'logreader' OR a.agent_name = c.agent_name))
   AND (SELECT count(*) FILTER (WHERE q.stopped) = 2
          FROM (SELECT x.continuous AND pgvigil.mssql_repl_stopped(x.job_state) AS stopped
                  FROM pgvigil.mssql_repl_sample x
                 WHERE x.instance_id = c.instance_id AND x.series = c.series
                   AND x.snapshot_at > c.snapshot_at - interval '30 minutes' AND x.snapshot_at <= c.snapshot_at
                 ORDER BY x.snapshot_at DESC LIMIT 2) q)
UNION ALL
-- an agent whose job runs and whose history has not moved (an idle agent rewrites its row every minute)
SELECT c.instance_id, CASE WHEN c.sl_crit IS NOT NULL AND c.last_run_at <= c.snapshot_at - make_interval(secs => c.sl_crit * 60) THEN 'critical' ELSE 'warning' END,
       'a replication agent writes nothing', c.obj, c.snapshot_at,
       format('%s runs, and its newest history row is from %s, %s minutes before the read (threshold %s): it is blocked or hung%s.',
              c.who, to_char(c.last_run_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), round(extract(epoch FROM c.snapshot_at - c.last_run_at) / 60), c.sl_min,
              CASE WHEN coalesce(c.undistributed, 0) > 0 THEN format('; %s commands wait for it', c.undistributed) ELSE '' END)
  FROM ctx c
 WHERE c.job_state = 'running' AND c.sl_min IS NOT NULL AND c.last_run_at <= c.snapshot_at - make_interval(secs => c.sl_min * 60)
UNION ALL
SELECT l.instance_id, CASE WHEN l.lat_crit IS NOT NULL AND l.latency_s >= l.lat_crit * 60 THEN 'critical' ELSE 'warning' END,
       'replication latency over the threshold',
       coalesce(l.publication, '?') || ' -> ' || coalesce(l.subscriber, '?') || '.' || coalesce(l.subscriber_db, '?'), l.snapshot_at,
       format('subscription of %s.%s (publication %s) at %s.%s: the oldest of the %s commands waiting for it entered the distribution database at %s, %s minutes before the read by the distributor''s clock (thresholds %s / %s minutes).',
              coalesce(l.publisher, '?'), coalesce(l.publisher_db, '?'), coalesce(l.publication, '?'), coalesce(l.subscriber, '?'), coalesce(l.subscriber_db, '?'),
              l.undistributed, to_char(l.oldest_pending_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'), round((l.latency_s / 60.0)::numeric, 1),
              coalesce(l.lat_warn::text, '-'), coalesce(l.lat_crit::text, '-'))
  FROM lat l
 WHERE (l.lat_warn IS NOT NULL AND l.latency_s >= l.lat_warn * 60) OR (l.lat_crit IS NOT NULL AND l.latency_s >= l.lat_crit * 60)
UNION ALL
SELECT p.instance_id, 'warning', 'undistributed commands over the threshold',
       coalesce(p.publication, '?') || ' -> ' || coalesce(p.subscriber, '?') || '.' || coalesce(p.subscriber_db, '?'), p.snapshot_at,
       format('subscription of %s.%s (publication %s) at %s.%s: %s commands wait in the distribution database (threshold %s)%s.',
              coalesce(p.publisher, '?'), coalesce(p.publisher_db, '?'), coalesce(p.publication, '?'), coalesce(p.subscriber, '?'), coalesce(p.subscriber_db, '?'),
              p.undistributed, l.repl_undistributed_commands,
              coalesce(', about ' || round(p.est_catchup_s::numeric) || ' s at the agent''s last delivery rate', ''))
  FROM pgvigil.mssql_replication_state p JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = p.instance_id
 WHERE p.snapshot_at > now() - interval '15 minutes' AND p.kind = 'subscription'
   AND l.repl_undistributed_commands > 0 AND p.undistributed > l.repl_undistributed_commands
UNION ALL
-- the publisher side: transactions marked for replication wait in the log and none was read out for the threshold
SELECT d.instance_id, CASE WHEN d.sl_crit IS NOT NULL AND coalesce(d.ok_at, d.first_at) <= d.snapshot_at - make_interval(secs => d.sl_crit * 60) THEN 'critical' ELSE 'warning' END,
       'replicated transactions wait in the log of a published database', d.database_name, d.snapshot_at,
       format('published database %s: %s transactions marked for replication wait in its log for the log reader, and none was read out since %s (%s minutes before the read; threshold %s). The log cannot be reused past them (log reuse wait %s). Its distributor: %s.',
              d.database_name, d.pending_xacts, to_char(coalesce(d.ok_at, d.first_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
              round(extract(epoch FROM d.snapshot_at - coalesce(d.ok_at, d.first_at)) / 60), d.sl_min, coalesce(lower(d.log_reuse_wait), '?'),
              coalesce(d.distributor || CASE WHEN d.distributor_local THEN ' (this server)' ELSE ' (another server: its log reader runs there)' END, 'none named'))
  FROM pubdb d
 WHERE d.pending_xacts > 0 AND d.sl_min IS NOT NULL AND d.reads >= 2 AND d.cur_tps IS NOT NULL
   AND coalesce(d.ok_at, d.first_at) <= d.snapshot_at - make_interval(secs => d.sl_min * 60);

-- mssql_hadr_findings: 0066's text without its two replication arms (now in mssql_repl_findings), with one UNION ALL
-- of mssql_repl_findings in their place.
CREATE OR REPLACE VIEW pgvigil.mssql_hadr_findings AS
WITH rep AS (
  SELECT a.* FROM pgvigil.mssql_ag_state a WHERE a.snapshot_at > now() - interval '5 minutes'
), dbs AS (
  SELECT d.*, r.availability_mode
    FROM pgvigil.mssql_ag_database_state d
    LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = d.instance_id AND r.group_id = d.group_id AND r.replica_server = d.replica_server
   WHERE d.snapshot_at > now() - interval '5 minutes'
), q5 AS (
  SELECT s.instance_id, s.group_name, s.replica_server, s.database_name,
         min(coalesce(s.log_send_queue_kb, 0)) AS min_send, max(s.log_send_queue_kb) AS max_send,
         min(coalesce(s.redo_queue_kb, 0)) AS min_redo, max(s.redo_queue_kb) AS max_redo, max(s.snapshot_at) AS last_at
    FROM pgvigil.mssql_ag_sample s
   WHERE s.snapshot_at > now() - interval '5 minutes 30 seconds'
   GROUP BY 1, 2, 3, 4
  HAVING min(s.snapshot_at) <= now() - interval '4 minutes' AND max(s.snapshot_at) > now() - interval '2 minutes'
)
SELECT r.instance_id, 'critical'::text AS severity, 'a replica is not connected'::text AS check_name,
       r.group_name || ' / ' || r.replica_server AS object, r.snapshot_at AS at,
       format('replica %s of the availability group %s is %s%s. Its databases receive nothing until it connects again.',
              r.replica_server, r.group_name, lower(r.connected_state),
              coalesce(' (last connect error ' || r.last_connect_error || ': ' || r.last_connect_error_text || ')', '')) AS detail
  FROM rep r WHERE r.connected_state IS NOT NULL AND r.connected_state <> 'CONNECTED'
UNION ALL
SELECT r.instance_id, 'critical', 'a replica is not healthy', r.group_name || ' / ' || r.replica_server, r.snapshot_at,
       format('replica %s of the availability group %s: synchronization health %s, role %s, operational state %s.',
              r.replica_server, r.group_name, lower(replace(r.synchronization_health, '_', ' ')), coalesce(lower(r.role), 'unknown'),
              coalesce(lower(replace(r.operational_state, '_', ' ')), 'unknown'))
  FROM rep r WHERE r.synchronization_health IS NOT NULL AND r.synchronization_health <> 'HEALTHY'
               AND (r.connected_state IS NULL OR r.connected_state = 'CONNECTED')     -- a disconnected replica has its own finding
UNION ALL
SELECT d.instance_id, 'critical', 'a database is suspended', d.group_name || ' / ' || d.replica_server || ' / ' || d.database_name, d.snapshot_at,
       format('database %s on replica %s (group %s): data movement is suspended%s. The log of the primary grows until it is resumed (ALTER DATABASE ... SET HADR RESUME).',
              d.database_name, d.replica_server, d.group_name, coalesce(', reason ' || lower(replace(d.suspend_reason, '_', ' ')), ''))
  FROM dbs d WHERE d.is_suspended
UNION ALL
SELECT d.instance_id, 'critical', 'a database is not synchronizing', d.group_name || ' / ' || d.replica_server || ' / ' || d.database_name, d.snapshot_at,
       format('database %s on replica %s (group %s) is %s (database state %s).',
              d.database_name, d.replica_server, d.group_name, lower(replace(d.synchronization_state, '_', ' ')),
              coalesce(lower(replace(d.database_state, '_', ' ')), 'unknown'))
  FROM dbs d WHERE NOT coalesce(d.is_suspended, false) AND d.synchronization_state IS NOT NULL
               AND d.synchronization_state NOT IN ('SYNCHRONIZED', 'SYNCHRONIZING')
UNION ALL
SELECT d.instance_id, 'warning', 'a synchronous replica is not synchronized', d.group_name || ' / ' || d.replica_server || ' / ' || d.database_name, d.snapshot_at,
       format('database %s on the synchronous-commit replica %s (group %s) is synchronizing, not synchronized: a failover to it now would lose data.',
              d.database_name, d.replica_server, d.group_name)
  FROM dbs d WHERE NOT coalesce(d.is_suspended, false) AND d.availability_mode = 'SYNCHRONOUS_COMMIT' AND d.synchronization_state = 'SYNCHRONIZING'
UNION ALL
SELECT q.instance_id, 'warning', 'the log send queue is over its threshold', q.group_name || ' / ' || q.replica_server || ' / ' || q.database_name, q.last_at,
       format('database %s to replica %s (group %s): between %s and %s of log waited to be sent in every read of the last 5 minutes (threshold %s). That log is what a failover to this replica would lose.',
              q.database_name, q.replica_server, q.group_name, pg_size_pretty(q.min_send * 1024), pg_size_pretty(q.max_send * 1024),
              pg_size_pretty((l.log_send_queue_kb * 1024)::bigint))
  FROM q5 q JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = q.instance_id
 WHERE l.log_send_queue_kb > 0 AND q.min_send > l.log_send_queue_kb
UNION ALL
SELECT q.instance_id, 'warning', 'the redo queue is over its threshold', q.group_name || ' / ' || q.replica_server || ' / ' || q.database_name, q.last_at,
       format('database %s on replica %s (group %s): between %s and %s of log waited to be redone in every read of the last 5 minutes (threshold %s). A failover to this replica waits for that redo.',
              q.database_name, q.replica_server, q.group_name, pg_size_pretty(q.min_redo * 1024), pg_size_pretty(q.max_redo * 1024),
              pg_size_pretty((l.redo_queue_kb * 1024)::bigint))
  FROM q5 q JOIN pgvigil.mssql_hadr_limits l ON l.instance_id = q.instance_id
 WHERE l.redo_queue_kb > 0 AND q.min_redo > l.redo_queue_kb
UNION ALL
SELECT f.instance_id, 'critical', 'the primary of a group changed', f.group_name, f.at,
       format('availability group %s: the primary moved from %s to %s in the minute before %s (a failover). Shown for an hour.',
              f.group_name, f.old_primary, f.new_primary, to_char(f.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  FROM pgvigil.mssql_ag_failovers f WHERE f.at > now() - interval '1 hour'
UNION ALL
SELECT r.instance_id, 'info', 'a collection stores nothing where rows are expected', 'mssql_ag', r.snapshot_at,
       format('Always On is enabled on this server and mssql_ag has read no availability group in its last %s reads: no group exists yet, or the login does not see it.', r.empty_reads)
  FROM pgvigil.mssql_hadr_reads r WHERE r.collection = 'mssql_ag' AND r.empty_reads >= 60 AND r.snapshot_at > now() - interval '5 minutes'
UNION ALL
SELECT m.instance_id, 'critical', 'mirroring is disconnected or suspended', m.database_name, m.snapshot_at,
       format('database %s (%s, partner %s) is %s%s.', m.database_name, coalesce(lower(m.role), 'role unknown'), coalesce(m.partner_instance, m.partner, '?'),
              lower(m.state), coalesce('; witness ' || m.witness || ' ' || lower(m.witness_state), ''))
  FROM pgvigil.mssql_mirroring_state m
 WHERE m.snapshot_at > now() - interval '5 minutes' AND m.state IN ('DISCONNECTED', 'SUSPENDED')
UNION ALL
SELECT s.instance_id, 'warning', 'log shipping is behind its threshold',
       s.role || ' / ' || s.database_name || CASE WHEN s.secondary_server <> '' THEN ' on ' || s.secondary_server ELSE '' END, s.snapshot_at,
       CASE s.role WHEN 'primary' THEN
         format('primary database %s: the last log backup is from %s, %s minutes before the read; its threshold is %s minutes.', s.database_name,
                coalesce(to_char(s.last_backup_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'),
                coalesce(round(extract(epoch FROM s.snapshot_at - s.last_backup_at) / 60)::text, '?'), s.threshold_minutes)
       ELSE
         format('secondary database %s (from %s.%s): the last restore is from %s, %s minutes before the read; its threshold is %s minutes. The last file copied: %s.', s.database_name,
                coalesce(s.primary_server, '?'), coalesce(s.primary_database, '?'),
                coalesce(to_char(s.last_restored_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'),
                coalesce(round(extract(epoch FROM s.snapshot_at - s.last_restored_at) / 60)::text, '?'), s.threshold_minutes,
                coalesce(to_char(s.last_copied_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never'))
       END
  FROM pgvigil.mssql_logshipping_state s
 WHERE s.snapshot_at > now() - interval '15 minutes' AND s.threshold_minutes > 0
   AND coalesce(s.snapshot_at - CASE s.role WHEN 'primary' THEN s.last_backup_at ELSE s.last_restored_at END, interval '1000 years')
       > make_interval(mins => s.threshold_minutes)
UNION ALL
-- replication (0142): its own view
SELECT instance_id, severity, check_name, object, at, detail FROM pgvigil.mssql_repl_findings;
