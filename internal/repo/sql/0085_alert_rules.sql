-- 0085_alert_rules: Counters as Metrics, and alert rules on any charted metric (task 131; DBA Dash's Metrics grid,
-- Darling's Alert Rules and Threshold Overrides). No new collection: every figure is read from a series the
-- repository already holds.
--
--   metric_catalog        every metric a grid row or a rule may name: 'family.metric', its engine, label and unit,
--                         whether it has a per-database series, and how old its newest sample may be before a rule
--                         calls it 'no data'.
--   metric_points(i, family, from, to, lookback, database)
--                         the family's samples in (from, to] as (at, metric, value): the one read behind the grid, a
--                         row's chart and a rule's evaluation, so the three agree. A counter is a rate over its own
--                         interval (the *_rate functions of 0004: a reset gives no point, never a dip).
--   metric_grid(i, from, to, lookback, database)
--                         one row per metric of the instance's engine: max, min, avg and the newest value of the
--                         window, the sample count, and the thresholds in force for it (the most specific live rule).
--   alert_rules           a rule: a metric above or below a warning and / or a critical value for n minutes, on the
--                         fleet, a tag or one instance, optionally for one database's series. Never updated in place
--                         by the UI but for its on / off switch: an edit ends the row and writes its successor
--                         (replaces), so the table is its own history.
--   alert_rule_log        every attempt from the UI (done or refused): who, from where, what.
--   alert_rule_scope      every live, enabled rule on every active instance it covers.
--   alert_rules_effective the rule in force per instance, metric and series: an instance's own rule wins over a tag's,
--                         a tag's over the fleet's (two tags of one instance: the newer rule). A rule that names a
--                         database is that database's series and overrides nothing at the instance level.
--   alert_rule_eval(at)   the state of every rule in force, read only: critical or warning once every sample of the
--                         last n minutes is beyond the value (measured sample to sample, never by the clock alone),
--                         pending while it is beyond for less, ok, or nodata (no sample newer than the family's limit).
--   alert_rule_state      the alert sender's last evaluation (alert_rules_run, called at the start of every pass). A
--                         firing rule whose series stops keeps its state (held): no data is not a recovery.
--   alert_rule_fired      per rule: when it last began to fire and how often.
--   alert_rule_findings   the firing rows as findings (source 'alert rule'); alert_findings (0059) gains them, so the
--                         channels, repeats, recoveries, mutes, silences and acknowledgements of 0059 and 0073 apply
--                         unchanged. pgvigil.findings is not touched (the Findings tab lists rule alerts on the Alerts
--                         and Alert rules pages, not there).
--
-- Writes: pgvigil.import_alert_rule(at, payload) through the actions door's audit login (pgvigil_collector:
-- apply_roles makes every import_* SECURITY DEFINER and grants it there), behind the UI login. The sender
-- (pgvigil_alerter) writes alert_rule_state and alert_rule_fired only. Neither alert_rules nor alert_rule_log is
-- purged: like acks and ack_log, an audit.

CREATE OR REPLACE VIEW pgvigil.metric_catalog AS
SELECT v.family || '.' || v.metric AS key, v.engine, v.family, v.family_label, v.family_sort, v.metric, v.label, v.unit,
       v.per_database, v.fresh_secs, v.sort
  FROM (VALUES
    ('postgres',  'sessions',  'Sessions',          10, 'total',                 'sessions',                          'count',       false,  600,  1),
    ('postgres',  'sessions',  'Sessions',          10, 'active',                'active sessions',                   'count',       false,  600,  2),
    ('postgres',  'sessions',  'Sessions',          10, 'idle_in_txn',           'idle in transaction',               'count',       false,  600,  3),
    ('postgres',  'sessions',  'Sessions',          10, 'waiting_lock',          'waiting on a lock',                 'count',       false,  600,  4),
    ('postgres',  'sessions',  'Sessions',          10, 'connections_pct',       'connections used',                  'pct',         false,  600,  5),
    ('postgres',  'sessions',  'Sessions',          10, 'longest_active_secs',   'longest active statement',          'secs',        false,  600,  6),
    ('postgres',  'sessions',  'Sessions',          10, 'longest_idle_txn_secs', 'longest idle in transaction',       'secs',        false,  600,  7),
    ('postgres',  'sessions',  'Sessions',          10, 'oldest_xmin_age',       'oldest xmin age',                   'xids',        false,  600,  8),
    ('postgres',  'database',  'Database',          20, 'commits_s',             'commits',                           'per_s',       true,   600,  1),
    ('postgres',  'database',  'Database',          20, 'rollbacks_s',           'rollbacks',                         'per_s',       true,   600,  2),
    ('postgres',  'database',  'Database',          20, 'blks_read_s',           'blocks read',                       'per_s',       true,   600,  3),
    ('postgres',  'database',  'Database',          20, 'blks_hit_s',            'blocks hit',                        'per_s',       true,   600,  4),
    ('postgres',  'database',  'Database',          20, 'cache_hit_pct',         'buffer cache hit ratio',            'pct',         true,   600,  5),
    ('postgres',  'database',  'Database',          20, 'tup_read_s',            'tuples read',                       'per_s',       true,   600,  6),
    ('postgres',  'database',  'Database',          20, 'tup_written_s',         'tuples written',                    'per_s',       true,   600,  7),
    ('postgres',  'database',  'Database',          20, 'temp_bytes_s',          'temp bytes',                        'bytes_per_s', true,   600,  8),
    ('postgres',  'database',  'Database',          20, 'deadlocks',             'deadlocks per interval',            'count',       true,   600,  9),
    ('postgres',  'database',  'Database',          20, 'backends',              'backends',                          'count',       true,   600, 10),
    ('postgres',  'server',    'Server',            30, 'checkpoints',           'checkpoints per interval',          'count',       false,  600,  1),
    ('postgres',  'server',    'Server',            30, 'checkpoints_req',       'requested checkpoints per interval', 'count',      false,  600,  2),
    ('postgres',  'server',    'Server',            30, 'buffers_written_s',     'buffers written',                   'per_s',       false,  600,  3),
    ('postgres',  'server',    'Server',            30, 'buffers_alloc_s',       'buffers allocated',                 'per_s',       false,  600,  4),
    ('postgres',  'server',    'Server',            30, 'wal_bytes_s',           'WAL bytes',                         'bytes_per_s', false,  600,  5),
    ('postgres',  'server',    'Server',            30, 'wal_records_s',         'WAL records',                       'per_s',       false,  600,  6),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'read_bytes_s',          'read bytes',                        'bytes_per_s', false, 1800,  1),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'write_bytes_s',         'write bytes',                       'bytes_per_s', false, 1800,  2),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'extend_bytes_s',        'extend bytes',                      'bytes_per_s', false, 1800,  3),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'hits_s',                'buffer hits',                       'per_s',       false, 1800,  4),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'fsyncs_s',              'fsyncs',                            'per_s',       false, 1800,  5),
    ('sqlserver', 'requests',  'Requests',          10, 'sessions',              'sessions',                          'count',       false,  600,  1),
    ('sqlserver', 'requests',  'Requests',          10, 'requests',              'requests running',                  'count',       false,  600,  2),
    ('sqlserver', 'requests',  'Requests',          10, 'blocked',               'processes blocked',                 'count',       false,  600,  3),
    ('sqlserver', 'requests',  'Requests',          10, 'heads',                 'blocking chain heads',              'count',       false,  600,  4),
    ('sqlserver', 'requests',  'Requests',          10, 'longest_wait_ms',       'longest wait',                      'ms',          false,  600,  5),
    ('sqlserver', 'cpu',       'CPU',               20, 'sql_pct',               'SQL Server CPU',                    'pct',         false,  600,  1),
    ('sqlserver', 'cpu',       'CPU',               20, 'other_pct',             'other processes CPU',               'pct',         false,  600,  2),
    ('sqlserver', 'cpu',       'CPU',               20, 'total_pct',             'machine CPU',                       'pct',         false,  600,  3),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'batch_s',               'batch requests',                    'per_s',       false,  600,  1),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'transactions_s',        'transactions',                      'per_s',       false,  600,  2),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'compiles_s',            'SQL compilations',                  'per_s',       false,  600,  3),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'recompiles_s',          'SQL re-compilations',               'per_s',       false,  600,  4),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'runnable_tasks',        'runnable tasks',                    'count',       false,  600,  5),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'work_queue',            'work queue',                        'count',       false,  600,  6),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'pending_io',            'pending disk IO',                   'count',       false,  600,  7),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'active_workers',        'active workers',                    'count',       false,  600,  8),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'current_workers',       'current workers',                   'count',       false,  600,  9),
    ('sqlserver', 'memory',    'Memory',            40, 'ple',                   'page life expectancy',              'secs',        false,  600,  1),
    ('sqlserver', 'memory',    'Memory',            40, 'grants_pending',        'memory grants pending',             'count',       false,  600,  2),
    ('sqlserver', 'memory',    'Memory',            40, 'grants_outstanding',    'memory grants outstanding',         'count',       false,  600,  3),
    ('sqlserver', 'memory',    'Memory',            40, 'total_mb',              'total server memory',               'mb',          false,  600,  4),
    ('sqlserver', 'memory',    'Memory',            40, 'target_mb',             'target server memory',              'mb',          false,  600,  5),
    ('sqlserver', 'memory',    'Memory',            40, 'buffer_pool_mb',        'database cache memory',             'mb',          false,  600,  6),
    ('sqlserver', 'memory',    'Memory',            40, 'plan_cache_mb',         'plan cache memory',                 'mb',          false,  600,  7),
    ('sqlserver', 'memory',    'Memory',            40, 'stolen_mb',             'stolen server memory',              'mb',          false,  600,  8),
    ('sqlserver', 'memory',    'Memory',            40, 'available_mb',          'available physical memory',         'mb',          false,  600,  9),
    ('sqlserver', 'memory',    'Memory',            40, 'os_used_pct',           'physical memory used',              'pct',         false,  600, 10),
    ('any',       'host',      'Host',              90, 'cpu_pct',               'host CPU',                          'pct',         false,  900,  1),
    ('any',       'host',      'Host',              90, 'cpu_iowait_pct',        'host CPU in IO wait',               'pct',         false,  900,  2),
    ('any',       'host',      'Host',              90, 'mem_used_pct',          'host memory used',                  'pct',         false,  900,  3),
    ('any',       'host',      'Host',              90, 'mem_free',              'host memory free',                  'bytes',       false,  900,  4),
    ('any',       'host',      'Host',              90, 'swap_used',             'host swap used',                    'bytes',       false,  900,  5),
    ('any',       'host',      'Host',              90, 'load1',                 'load average (1 min)',              'count',       false,  900,  6)
  ) AS v(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort);
COMMENT ON VIEW pgvigil.metric_catalog IS 'Every metric the Metrics grid shows and an alert rule may name (key = family.metric).';

-- metric_points: one family's samples in (p_from, p_to]. p_lookback reaches before the window for a rate's first
-- baseline (as the *_rate functions take it). p_database: one database's series of the 'database' family; NULL = the
-- instance's (the databases summed, as the Counters charts drew them).
CREATE OR REPLACE FUNCTION pgvigil.metric_points(p_instance_id int, p_family text, p_from timestamptz, p_to timestamptz,
                                                 p_lookback interval DEFAULT interval '15 minutes', p_database text DEFAULT NULL)
RETURNS TABLE (at timestamptz, metric text, value double precision)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
BEGIN
  IF p_family = 'sessions' THEN
    RETURN QUERY
    SELECT s.snapshot_at, v.metric, v.value
      FROM pgvigil.activity_summary s
      CROSS JOIN LATERAL (VALUES
        ('total', s.total::double precision), ('active', s.active::double precision),
        ('idle_in_txn', s.idle_in_txn::double precision), ('waiting_lock', s.waiting_lock::double precision),
        ('connections_pct', (100.0 * s.total / nullif(s.max_connections, 0))::double precision),
        ('longest_active_secs', s.longest_active_secs::double precision),
        ('longest_idle_txn_secs', s.longest_idle_txn_secs::double precision),
        ('oldest_xmin_age', s.oldest_xmin_age::double precision)) AS v(metric, value)
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND v.value IS NOT NULL;
  ELSIF p_family = 'database' THEN
    RETURN QUERY
    WITH r AS (
      SELECT d.snapshot_at, max(d.interval_secs) AS secs,
             sum(d.xact_commit) AS c, sum(d.xact_rollback) AS rb, sum(d.blks_read) AS br, sum(d.blks_hit) AS bh,
             sum(d.tup_returned + d.tup_fetched) AS tr, sum(d.tup_inserted + d.tup_updated + d.tup_deleted) AS tw,
             sum(d.temp_bytes) AS tb, sum(d.deadlocks) AS dl, sum(d.numbackends) AS nb
        FROM pgvigil.dbstats_rate(p_instance_id, p_from, p_to, p_lookback) d
       WHERE d.interval_secs > 0 AND (p_database IS NULL OR d.datname = p_database)
       GROUP BY d.snapshot_at
      HAVING NOT bool_or(d.reset)              -- a database reset in this interval: no point, not a dip
    )
    SELECT r.snapshot_at, v.metric, v.value
      FROM r
      CROSS JOIN LATERAL (VALUES
        ('commits_s', (r.c / r.secs)::double precision), ('rollbacks_s', (r.rb / r.secs)::double precision),
        ('blks_read_s', (r.br / r.secs)::double precision), ('blks_hit_s', (r.bh / r.secs)::double precision),
        ('cache_hit_pct', (100.0 * r.bh / nullif(r.bh + r.br, 0))::double precision),
        ('tup_read_s', (r.tr / r.secs)::double precision), ('tup_written_s', (r.tw / r.secs)::double precision),
        ('temp_bytes_s', (r.tb / r.secs)::double precision), ('deadlocks', r.dl::double precision),
        ('backends', r.nb::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'server' THEN
    RETURN QUERY
    SELECT s.snapshot_at, v.metric, v.value
      FROM pgvigil.serverstats_rate(p_instance_id, p_from, p_to, p_lookback) s
      CROSS JOIN LATERAL (VALUES
        ('checkpoints', (s.checkpoints_timed + s.checkpoints_req)::double precision),
        ('checkpoints_req', s.checkpoints_req::double precision),
        -- a version without one of the three counters stores it NULL; all three NULL = no figure, not 0
        ('buffers_written_s', (CASE WHEN num_nonnulls(s.buffers_checkpoint, s.buffers_clean, s.buffers_backend) > 0 THEN
            (coalesce(s.buffers_checkpoint, 0) + coalesce(s.buffers_clean, 0) + coalesce(s.buffers_backend, 0))::numeric / s.interval_secs END)::double precision),
        ('buffers_alloc_s', (s.buffers_alloc::numeric / s.interval_secs)::double precision),
        ('wal_bytes_s', (s.wal_bytes / s.interval_secs)::double precision),
        ('wal_records_s', (s.wal_records::numeric / s.interval_secs)::double precision)) AS v(metric, value)
     WHERE s.interval_secs > 0 AND s.reset IS NOT TRUE AND v.value IS NOT NULL;
  ELSIF p_family = 'io' THEN
    RETURN QUERY
    WITH r AS (
      SELECT o.snapshot_at, max(o.interval_secs) AS secs, sum(o.read_bytes) AS rb, sum(o.write_bytes) AS wb,
             sum(o.extend_bytes) AS eb, sum(o.hits) AS h, sum(o.fsyncs) AS f
        FROM pgvigil.iostats_rate(p_instance_id, p_from, p_to, p_lookback) o
       WHERE o.interval_secs > 0
       GROUP BY o.snapshot_at
      HAVING NOT bool_or(o.reset)              -- an IO row reset in this interval: no point, not a dip
    )
    SELECT r.snapshot_at, v.metric, v.value
      FROM r
      CROSS JOIN LATERAL (VALUES
        ('read_bytes_s', (r.rb / r.secs)::double precision), ('write_bytes_s', (r.wb / r.secs)::double precision),
        ('extend_bytes_s', (r.eb / r.secs)::double precision), ('hits_s', (r.h / r.secs)::double precision),
        ('fsyncs_s', (r.f / r.secs)::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'host' THEN
    RETURN QUERY
    WITH h AS (                                 -- one row per read (two sources of one instance: the higher figure)
      SELECT x.snapshot_at, max(x.cpu_pct) AS cpu_pct, max(x.cpu_iowait_pct) AS cpu_iowait_pct,
             max(100.0 * x.mem_used / nullif(x.mem_total, 0)) AS mem_used_pct, min(x.mem_free) AS mem_free,
             max(x.swap_used) AS swap_used, max(x.load1) AS load1
        FROM pgvigil.host_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT h.snapshot_at, v.metric, v.value
      FROM h
      CROSS JOIN LATERAL (VALUES
        ('cpu_pct', h.cpu_pct::double precision), ('cpu_iowait_pct', h.cpu_iowait_pct::double precision),
        ('mem_used_pct', h.mem_used_pct::double precision), ('mem_free', h.mem_free::double precision),
        ('swap_used', h.swap_used::double precision), ('load1', h.load1::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'requests' THEN
    RETURN QUERY
    SELECT s.snapshot_at, v.metric, v.value
      FROM pgvigil.mssql_requests_summary s
      CROSS JOIN LATERAL (VALUES
        ('sessions', s.sessions::double precision), ('requests', s.requests::double precision),
        ('blocked', s.blocked::double precision), ('heads', s.heads::double precision),
        ('longest_wait_ms', s.longest_wait_ms::double precision)) AS v(metric, value)
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND v.value IS NOT NULL;
  ELSIF p_family = 'cpu' THEN
    RETURN QUERY
    WITH c AS (                                 -- one row per record time
      SELECT x.snapshot_at, max(x.sql_pct) AS sql_pct, max(x.other_pct) AS other_pct, max(100 - x.idle_pct) AS total_pct
        FROM pgvigil.mssql_cpu_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT c.snapshot_at, v.metric, v.value
      FROM c
      CROSS JOIN LATERAL (VALUES
        ('sql_pct', c.sql_pct::double precision), ('other_pct', c.other_pct::double precision),
        ('total_pct', c.total_pct::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'scheduler' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.snapshot_at, max(x.batch_s) AS batch_s, max(x.transactions_s) AS transactions_s, max(x.compiles_s) AS compiles_s,
             max(x.recompiles_s) AS recompiles_s, max(x.runnable_tasks) AS runnable_tasks, max(x.work_queue) AS work_queue,
             max(x.pending_io) AS pending_io, max(x.active_workers) AS active_workers, max(x.current_workers) AS current_workers
        FROM pgvigil.mssql_sched_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT c.snapshot_at, v.metric, v.value
      FROM c
      CROSS JOIN LATERAL (VALUES
        ('batch_s', c.batch_s::double precision), ('transactions_s', c.transactions_s::double precision),
        ('compiles_s', c.compiles_s::double precision), ('recompiles_s', c.recompiles_s::double precision),
        ('runnable_tasks', c.runnable_tasks::double precision), ('work_queue', c.work_queue::double precision),
        ('pending_io', c.pending_io::double precision), ('active_workers', c.active_workers::double precision),
        ('current_workers', c.current_workers::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'memory' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.snapshot_at, max(x.ple) AS ple, max(x.grants_pending) AS grants_pending, max(x.grants_outstanding) AS grants_outstanding,
             max(x.total_kb) AS total_kb, max(x.target_kb) AS target_kb, max(x.buffer_pool_kb) AS buffer_pool_kb,
             max(x.plan_cache_kb) AS plan_cache_kb, max(x.stolen_kb) AS stolen_kb, min(x.available_kb) AS available_kb,
             max(x.physical_kb) AS physical_kb
        FROM pgvigil.mssql_memory_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT c.snapshot_at, v.metric, v.value
      FROM c
      CROSS JOIN LATERAL (VALUES
        ('ple', c.ple::double precision), ('grants_pending', c.grants_pending::double precision),
        ('grants_outstanding', c.grants_outstanding::double precision),
        ('total_mb', (c.total_kb / 1024.0)::double precision), ('target_mb', (c.target_kb / 1024.0)::double precision),
        ('buffer_pool_mb', (c.buffer_pool_kb / 1024.0)::double precision),
        ('plan_cache_mb', (c.plan_cache_kb / 1024.0)::double precision), ('stolen_mb', (c.stolen_kb / 1024.0)::double precision),
        ('available_mb', (c.available_kb / 1024.0)::double precision),
        ('os_used_pct', (100.0 * (c.physical_kb - c.available_kb) / nullif(c.physical_kb, 0))::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSE
    RAISE EXCEPTION 'metric_points: no metric family %', p_family USING ERRCODE = '22023';
  END IF;
END $$;

-- ---- the rules ---------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.alert_rules (
  rule_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name           text CHECK (length(name) BETWEEN 1 AND 100),
  metric         text NOT NULL CHECK (length(metric) BETWEEN 3 AND 100),   -- metric_catalog.key
  op             text NOT NULL CHECK (op IN ('above', 'below')),
  warning        double precision,
  critical       double precision,
  for_minutes    int NOT NULL DEFAULT 5 CHECK (for_minutes BETWEEN 0 AND 1440),
  scope          text NOT NULL CHECK (scope IN ('fleet', 'tag', 'instance')),
  tag            text CHECK (length(tag) BETWEEN 1 AND 200),
  instance_id    int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  instance_name  text,            -- the match: a removed instance's rule covers nothing, never every server
  database       text CHECK (length(database) BETWEEN 1 AND 200),
  note           text CHECK (length(note) BETWEEN 1 AND 500),
  enabled        boolean NOT NULL DEFAULT true,
  replaces       bigint,          -- the rule this one is the edit of
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  ended_by       text,
  ended_at       timestamptz,
  CONSTRAINT "a rule has a warning or a critical value" CHECK (num_nonnulls(warning, critical) > 0),
  CONSTRAINT "a threshold is a finite number" CHECK (
    coalesce(warning, 0) NOT IN ('NaN', 'Infinity', '-Infinity') AND coalesce(critical, 0) NOT IN ('NaN', 'Infinity', '-Infinity')),
  CONSTRAINT "critical is at or beyond warning" CHECK (
    warning IS NULL OR critical IS NULL OR (op = 'above' AND critical >= warning) OR (op = 'below' AND critical <= warning)),
  CONSTRAINT "a tag rule names its tag, an instance rule its instance, a fleet rule neither" CHECK (
    (scope = 'fleet' AND tag IS NULL AND instance_name IS NULL) OR (scope = 'tag' AND tag IS NOT NULL AND instance_name IS NULL)
    OR (scope = 'instance' AND tag IS NULL AND instance_name IS NOT NULL))
);
-- one live rule per metric, scope and series: a second one is an edit of the first
CREATE UNIQUE INDEX IF NOT EXISTS alert_rules_live_uq ON pgvigil.alert_rules
  (metric, scope, coalesce(tag, ''), coalesce(instance_name, ''), coalesce(database, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.alert_rules IS 'Alert rules and thresholds on the metrics of metric_catalog; written through import_alert_rule only.';

CREATE TABLE IF NOT EXISTS pgvigil.alert_rule_log (
  log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL,
  ui_user    text NOT NULL,
  client     text,
  op         text,
  rule_id    bigint,
  metric     text,
  outcome    text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail     text,
  payload    jsonb
);
CREATE INDEX IF NOT EXISTS alert_rule_log_at_idx ON pgvigil.alert_rule_log (at DESC);

CREATE TABLE IF NOT EXISTS pgvigil.alert_rule_state (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  metric        text NOT NULL,
  database      text NOT NULL DEFAULT '',     -- '' = the instance's series
  rule_id       bigint NOT NULL,
  state         text NOT NULL CHECK (state IN ('ok', 'pending', 'warning', 'critical', 'nodata')),
  held          boolean NOT NULL DEFAULT false,   -- firing, and no fresh sample since: kept, not recovered
  value         double precision,             -- the newest sample
  threshold     double precision,             -- the value the state was judged against
  sample_at     timestamptz,
  beyond_since  timestamptz,                  -- the first sample of the unbroken run beyond the threshold
  since         timestamptz NOT NULL,         -- when the row entered its state
  evaluated_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, metric, database)
);

CREATE TABLE IF NOT EXISTS pgvigil.alert_rule_fired (
  rule_id        bigint PRIMARY KEY,
  last_fired_at  timestamptz NOT NULL,
  last_instance  text,
  fired          bigint NOT NULL DEFAULT 1
);

GRANT SELECT, INSERT, UPDATE, DELETE ON pgvigil.alert_rule_state TO pgvigil_alerter;
GRANT SELECT, INSERT, UPDATE ON pgvigil.alert_rule_fired TO pgvigil_alerter;

CREATE OR REPLACE VIEW pgvigil.alert_rule_scope AS
SELECT r.rule_id, r.name, r.metric, r.op, r.warning, r.critical, r.for_minutes, r.scope, r.tag, r.instance_name, r.database,
       i.instance_id, i.name AS instance,
       CASE r.scope WHEN 'instance' THEN 3 WHEN 'tag' THEN 2 ELSE 1 END AS level
  FROM pgvigil.alert_rules r
  JOIN pgvigil.metric_catalog c ON c.key = r.metric
  JOIN pgvigil.instances i ON i.is_active AND c.engine IN (i.engine, 'any')
  LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
 WHERE r.ended_at IS NULL AND r.enabled
   AND (c.per_database OR r.database IS NULL)
   AND (r.scope = 'fleet' OR (r.scope = 'instance' AND r.instance_name = i.name)
        OR (r.scope = 'tag' AND r.tag = ANY (coalesce(t.tags, '{}'::text[]))));

CREATE OR REPLACE VIEW pgvigil.alert_rules_effective AS
SELECT DISTINCT ON (s.instance_id, s.metric, coalesce(s.database, '')) s.*
  FROM pgvigil.alert_rule_scope s
 ORDER BY s.instance_id, s.metric, coalesce(s.database, ''), s.level DESC, s.rule_id DESC;

-- metric_grid: the Metrics page's rows. The thresholds of a row are the most specific rule covering the instance: for
-- one database's series a rule naming that database first, then the instance's, a tag's, the fleet's.
CREATE OR REPLACE FUNCTION pgvigil.metric_grid(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                               p_lookback interval DEFAULT interval '15 minutes', p_database text DEFAULT NULL)
RETURNS TABLE (key text, family text, family_label text, metric text, label text, unit text, per_database boolean,
               database text, max_value double precision, min_value double precision, avg_value double precision,
               current_value double precision, current_at timestamptz, samples bigint,
               rule_id bigint, rule_name text, op text, warning double precision, critical double precision, for_minutes int,
               rule_scope text, rule_target text, rule_database text, family_sort int, sort int)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
DECLARE
  v_engine text;
  f record;
BEGIN
  SELECT i.engine INTO v_engine FROM pgvigil.instances i WHERE i.instance_id = p_instance_id;
  IF v_engine IS NULL THEN
    RETURN;
  END IF;
  FOR f IN SELECT c.family, bool_or(c.per_database) AS per_database
             FROM pgvigil.metric_catalog c WHERE c.engine IN (v_engine, 'any') GROUP BY c.family
  LOOP
    RETURN QUERY
    WITH p AS MATERIALIZED (
      SELECT x.at, x.metric, x.value
        FROM pgvigil.metric_points(p_instance_id, f.family, p_from, p_to, p_lookback,
                                   CASE WHEN f.per_database THEN p_database END) x
    ), a AS (
      SELECT p.metric, max(p.value) AS mx, min(p.value) AS mn, avg(p.value) AS av, count(*) AS n,
             (array_agg(p.value ORDER BY p.at DESC))[1] AS cur, max(p.at) AS cur_at
        FROM p GROUP BY p.metric
    )
    SELECT c.key, c.family, c.family_label, c.metric, c.label, c.unit, c.per_database,
           CASE WHEN c.per_database THEN p_database END,
           a.mx, a.mn, a.av, a.cur, a.cur_at, coalesce(a.n, 0),
           t.rule_id, t.name, t.op, t.warning, t.critical, t.for_minutes, t.scope, coalesce(t.tag, t.instance_name), t.database,
           c.family_sort, c.sort
      FROM pgvigil.metric_catalog c
      LEFT JOIN a ON a.metric = c.metric
      LEFT JOIN LATERAL (
        SELECT s.rule_id, s.name, s.op, s.warning, s.critical, s.for_minutes, s.scope, s.tag, s.instance_name, s.database
          FROM pgvigil.alert_rule_scope s
         WHERE s.instance_id = p_instance_id AND s.metric = c.key
           AND (s.database IS NULL OR (c.per_database AND s.database = p_database))
         ORDER BY (s.database IS NOT NULL) DESC, s.level DESC, s.rule_id DESC
         LIMIT 1) t ON true
     WHERE c.family = f.family AND c.engine IN (v_engine, 'any');
  END LOOP;
END $$;

-- alert_beyond: a value on the alerting side of a threshold
CREATE OR REPLACE FUNCTION pgvigil.alert_beyond(p_op text, p_value double precision, p_threshold double precision)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_op WHEN 'above' THEN p_value > p_threshold WHEN 'below' THEN p_value < p_threshold END
$$;

-- metric_num: a figure as a rule's finding writes it (at most 3 decimals, no exponent, no trailing zeros)
CREATE OR REPLACE FUNCTION pgvigil.metric_num(p double precision)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p IS NULL THEN NULL ELSE trim_scale(round(p::numeric, 3))::text END
$$;

-- alert_rule_eval: every rule in force, judged at p_at. One read of a family's points per instance and series; the
-- window reaches the longest rule's minutes plus an hour back, so a run that began before it still counts as long
-- enough. A level holds when the newest sample is fresh and beyond its value and the unbroken run of samples beyond
-- it spans the rule's minutes (first to newest sample: a single late sample never fires a rule by the clock alone).
CREATE OR REPLACE FUNCTION pgvigil.alert_rule_eval(p_at timestamptz)
RETURNS TABLE (rule_id bigint, instance_id int, metric text, database text, state text, value double precision,
               threshold double precision, sample_at timestamptz, beyond_since timestamptz)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
DECLARE
  g record;
BEGIN
  FOR g IN
    SELECT e.instance_id, c.family, e.database, max(e.for_minutes) AS max_for
      FROM pgvigil.alert_rules_effective e JOIN pgvigil.metric_catalog c ON c.key = e.metric
     GROUP BY e.instance_id, c.family, e.database
  LOOP
    RETURN QUERY
    WITH p AS MATERIALIZED (
      SELECT x.at, x.metric, x.value
        FROM pgvigil.metric_points(g.instance_id, g.family, p_at - make_interval(mins => g.max_for + 60), p_at,
                                   interval '1 hour', g.database) x
    ), lv AS (          -- each rule of this instance, family and series at each level it sets
      SELECT e.rule_id, e.metric AS key, c.metric AS m, e.op, e.for_minutes, c.fresh_secs, l.sev, l.thr
        FROM pgvigil.alert_rules_effective e
        JOIN pgvigil.metric_catalog c ON c.key = e.metric
        CROSS JOIN LATERAL (VALUES ('critical', e.critical), ('warning', e.warning)) AS l(sev, thr)
       WHERE e.instance_id = g.instance_id AND c.family = g.family AND e.database IS NOT DISTINCT FROM g.database
         AND l.thr IS NOT NULL
    ), j AS (
      SELECT lv.*, z.last_at, z.last_value,
             (SELECT min(p2.at) FROM p p2
               WHERE p2.metric = lv.m AND (z.last_within IS NULL OR p2.at > z.last_within)) AS run_from
        FROM lv
        LEFT JOIN LATERAL (
          SELECT max(p1.at) AS last_at, (array_agg(p1.value ORDER BY p1.at DESC))[1] AS last_value,
                 max(p1.at) FILTER (WHERE NOT pgvigil.alert_beyond(lv.op, p1.value, lv.thr)) AS last_within
            FROM p p1 WHERE p1.metric = lv.m) z ON true
    ), k AS (
      SELECT j.*,
             (j.last_at IS NOT NULL AND p_at - j.last_at <= make_interval(secs => j.fresh_secs)) AS fresh,
             (j.run_from IS NOT NULL AND j.last_at - j.run_from >= make_interval(mins => j.for_minutes)) AS long_enough
        FROM j
    )
    SELECT k.rule_id, g.instance_id, k.key, g.database,
           CASE WHEN NOT bool_or(k.fresh) THEN 'nodata'
                WHEN bool_or(k.fresh AND k.long_enough) FILTER (WHERE k.sev = 'critical') THEN 'critical'
                WHEN bool_or(k.fresh AND k.long_enough) FILTER (WHERE k.sev = 'warning') THEN 'warning'
                WHEN bool_or(k.run_from IS NOT NULL) THEN 'pending'
                ELSE 'ok' END,
           max(k.last_value),
           coalesce(max(k.thr) FILTER (WHERE k.sev = 'critical' AND k.fresh AND k.long_enough),
                    max(k.thr) FILTER (WHERE k.sev = 'warning'), max(k.thr)),
           max(k.last_at),
           coalesce(min(k.run_from) FILTER (WHERE k.sev = 'critical' AND k.fresh AND k.long_enough),
                    min(k.run_from) FILTER (WHERE k.sev = 'warning'), min(k.run_from))
      FROM k
     GROUP BY k.rule_id, k.key;
  END LOOP;
END $$;

-- alert_rules_run: the sender's evaluation, stored (one row per rule in force, instance and series); rows of a rule
-- no longer in force are removed. Returns the rows firing. Called at the start of every alert pass.
CREATE OR REPLACE FUNCTION pgvigil.alert_rules_run(p_at timestamptz)
RETURNS int LANGUAGE plpgsql SET jit = off AS $$
DECLARE
  v_firing int;
BEGIN
  WITH e AS MATERIALIZED (
    SELECT * FROM pgvigil.alert_rule_eval(p_at)
  ), old AS MATERIALIZED (
    SELECT s.instance_id, s.metric, s.database, s.rule_id, s.state FROM pgvigil.alert_rule_state s
  ), up AS (
    INSERT INTO pgvigil.alert_rule_state AS s (instance_id, metric, database, rule_id, state, held, value, threshold,
                                               sample_at, beyond_since, since, evaluated_at)
    SELECT e.instance_id, e.metric, coalesce(e.database, ''), e.rule_id, e.state, false, e.value, e.threshold,
           e.sample_at, e.beyond_since, p_at, p_at
      FROM e
    ON CONFLICT (instance_id, metric, database) DO UPDATE SET
      -- a firing rule whose series went quiet keeps its state: no data is not a recovery
      held = (EXCLUDED.state = 'nodata' AND s.state IN ('warning', 'critical') AND s.rule_id = EXCLUDED.rule_id),
      state = CASE WHEN EXCLUDED.state = 'nodata' AND s.state IN ('warning', 'critical') AND s.rule_id = EXCLUDED.rule_id
                   THEN s.state ELSE EXCLUDED.state END,
      since = CASE WHEN s.rule_id = EXCLUDED.rule_id
                        AND (s.state = EXCLUDED.state OR (EXCLUDED.state = 'nodata' AND s.state IN ('warning', 'critical')))
                   THEN s.since ELSE EXCLUDED.since END,
      value = coalesce(EXCLUDED.value, s.value), threshold = coalesce(EXCLUDED.threshold, s.threshold),
      sample_at = coalesce(EXCLUDED.sample_at, s.sample_at), beyond_since = coalesce(EXCLUDED.beyond_since, s.beyond_since),
      rule_id = EXCLUDED.rule_id, evaluated_at = EXCLUDED.evaluated_at
    RETURNING s.instance_id, s.metric, s.database, s.rule_id, s.state
  ), began AS (         -- the rows that began to fire in this run
    SELECT up.rule_id, max(i.name) AS instance, count(*) AS n
      FROM up
      JOIN pgvigil.instances i ON i.instance_id = up.instance_id
      LEFT JOIN old ON old.instance_id = up.instance_id AND old.metric = up.metric AND old.database = up.database
                   AND old.rule_id = up.rule_id
     WHERE up.state IN ('warning', 'critical') AND coalesce(old.state, 'ok') NOT IN ('warning', 'critical')
     GROUP BY up.rule_id
  )
  INSERT INTO pgvigil.alert_rule_fired AS f (rule_id, last_fired_at, last_instance, fired)
  SELECT b.rule_id, p_at, b.instance, b.n FROM began b
  ON CONFLICT (rule_id) DO UPDATE SET last_fired_at = EXCLUDED.last_fired_at, last_instance = EXCLUDED.last_instance,
    fired = f.fired + EXCLUDED.fired;
  DELETE FROM pgvigil.alert_rule_state s WHERE s.evaluated_at IS DISTINCT FROM p_at;
  SELECT count(*) INTO v_firing FROM pgvigil.alert_rule_state s WHERE s.state IN ('warning', 'critical');
  RETURN v_firing;
END $$;
GRANT EXECUTE ON FUNCTION pgvigil.alert_rules_run(timestamptz) TO pgvigil_alerter;

-- the firing rows as findings. The key of a finding is its instance, source, setting and value with the numbers
-- taken out (alert_finding_key, 0059): a threshold edit or a rise from warning to critical keeps one alert open (the
-- rise is sent as 'escalated'); the rule's id and scope ride in the detail, outside the key.
CREATE OR REPLACE VIEW pgvigil.alert_rule_findings AS
SELECT s.instance_id, s.state AS severity,
       c.family_label || ': ' || c.label || CASE WHEN s.database <> '' THEN ' [' || s.database || ']' ELSE '' END AS setting,
       r.op || ' ' || pgvigil.metric_num(s.threshold) || ' for ' || r.for_minutes || ' min; last sample '
         || coalesce(pgvigil.metric_num(s.value), 'none') AS value,
       NULL::boolean AS is_set, NULL::text AS suggested, NULL::text AS platforms,
       'alert rule ' || r.rule_id || coalesce(' "' || r.name || '"', '') || ' ('
         || CASE r.scope WHEN 'fleet' THEN 'every instance' WHEN 'tag' THEN 'tag ' || r.tag ELSE 'instance ' || r.instance_name END
         || '): ' || r.metric || ' ' || r.op || ' ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || ') since '
         || to_char(s.beyond_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
         || CASE WHEN s.held THEN '; no fresh sample since ' || to_char(s.sample_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: the alert is held' ELSE '' END AS detail,
       'alert rule'::text AS source, coalesce(s.sample_at, s.evaluated_at) AS at
  FROM pgvigil.alert_rule_state s
  JOIN pgvigil.alert_rules r ON r.rule_id = s.rule_id
  JOIN pgvigil.metric_catalog c ON c.key = s.metric
 WHERE s.state IN ('warning', 'critical');

-- alert_findings (0059): the findings and the firing rules, with the key, the instance's name and its tags
CREATE OR REPLACE VIEW pgvigil.alert_findings AS
SELECT pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value) AS finding_key,
       f.instance_id, i.name AS instance, coalesce(t.tags, '{}'::text[]) AS tags,
       f.severity, f.setting, f.value, f.suggested, f.detail, f.source, f.at
  FROM (SELECT x.instance_id, x.severity, x.setting, x.value, x.suggested, x.detail, x.source, x.at FROM pgvigil.findings x
        UNION ALL
        SELECT y.instance_id, y.severity, y.setting, y.value, y.suggested, y.detail, y.source, y.at FROM pgvigil.alert_rule_findings y) f
  JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
 WHERE i.is_active;

-- import_alert_rule: one attempt from the UI (the actions door's audit login). p_payload: {op, ui_user, client} and
--   add:     metric, op_dir (above | below), warning, critical, for_minutes, scope (fleet | tag | instance), tag,
--            instance_name, database, name, note
--   edit:    rule_id and the fields of add: the rule is ended and its successor written (replaces = rule_id)
--   end:     rule_id
--   enable / disable: rule_id (the on / off switch; the row stays, a disabled rule is in force nowhere)
-- Every attempt leaves an alert_rule_log row; a refused one changes nothing else. Returns {outcome, detail, rule_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_rule(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_metric  text := nullif(p_payload->>'metric', '');
  v_dir     text := p_payload->>'op_dir';
  v_scope   text := p_payload->>'scope';
  v_tag     text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_inst    text := nullif(p_payload->>'instance_name', '');
  v_db      text := nullif(btrim(coalesce(p_payload->>'database', '')), '');
  v_name    text := nullif(btrim(coalesce(p_payload->>'name', '')), '');
  v_note    text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_warn    double precision;
  v_crit    double precision;
  v_for     int := 5;
  v_id      bigint;
  v_new     bigint;
  v_why     text;
  v_done    text;
  v_old     pgvigil.alert_rules;
  v_cat     record;
  v_engine  text;
  v_iid     int;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_alert_rule: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'edit', 'end', 'enable', 'disable') THEN
    v_why := 'op must be add, edit, end, enable or disable';
  END IF;
  IF v_why IS NULL AND v_op <> 'add' THEN
    IF coalesce(p_payload->>'rule_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'rule_id')::bigint;
      SELECT * INTO v_old FROM pgvigil.alert_rules WHERE rule_id = v_id FOR UPDATE;
    END IF;
    IF v_id IS NULL THEN
      v_why := format('rule_id %L is not a rule id', p_payload->>'rule_id');
    ELSIF v_old.rule_id IS NULL THEN
      v_why := format('no rule %s', v_id);
    ELSIF v_old.ended_at IS NOT NULL THEN
      v_why := format('rule %s was ended by %s at %s', v_id, v_old.ended_by, v_old.ended_at);
    ELSIF v_op = 'enable' AND v_old.enabled THEN
      v_why := format('rule %s is already on', v_id);
    ELSIF v_op = 'disable' AND NOT v_old.enabled THEN
      v_why := format('rule %s is already off', v_id);
    END IF;
  END IF;
  IF v_why IS NULL AND v_op IN ('add', 'edit') THEN
    SELECT c.key, c.engine, c.per_database INTO v_cat FROM pgvigil.metric_catalog c WHERE c.key = v_metric;
    IF v_cat.key IS NULL THEN
      v_why := format('no metric %L', v_metric);
    ELSIF v_dir IS NULL OR v_dir NOT IN ('above', 'below') THEN
      v_why := 'op_dir must be above or below';
    ELSIF coalesce(jsonb_typeof(p_payload->'warning'), 'null') NOT IN ('number', 'null')
          OR coalesce(jsonb_typeof(p_payload->'critical'), 'null') NOT IN ('number', 'null') THEN
      v_why := 'warning and critical are numbers';
    ELSIF coalesce(jsonb_typeof(p_payload->'for_minutes'), 'null') NOT IN ('number', 'null')
          OR coalesce(p_payload->>'for_minutes', '5') !~ '^[0-9]{1,4}$' THEN
      v_why := 'for_minutes is a whole number of minutes, 0 to 1440';
    ELSIF v_scope IS NULL OR v_scope NOT IN ('fleet', 'tag', 'instance') THEN
      v_why := 'scope must be fleet, tag or instance';
    ELSIF v_scope = 'tag' AND v_tag IS NULL THEN
      v_why := 'a tag rule names its tag';
    ELSIF v_scope = 'instance' AND v_inst IS NULL THEN
      v_why := 'an instance rule names its instance';
    ELSIF v_db IS NOT NULL AND NOT v_cat.per_database THEN
      v_why := format('%s has no per-database series: leave the database empty', v_metric);
    ELSE
      v_warn := (p_payload->>'warning')::double precision;
      v_crit := (p_payload->>'critical')::double precision;
      v_for := coalesce(p_payload->>'for_minutes', '5')::int;
      IF v_scope = 'instance' THEN
        SELECT i.instance_id, i.engine INTO v_iid, v_engine FROM pgvigil.instances i WHERE i.name = v_inst AND i.is_active;
        IF v_iid IS NULL THEN
          v_why := format('no active instance %L', v_inst);
        ELSIF v_cat.engine NOT IN (v_engine, 'any') THEN
          v_why := format('%s is a %s metric and %s is a %s instance', v_metric, v_cat.engine, v_inst, v_engine);
        END IF;
      END IF;
      IF v_scope <> 'tag' THEN v_tag := NULL; END IF;
      IF v_scope <> 'instance' THEN v_inst := NULL; v_iid := NULL; END IF;
    END IF;
  END IF;
  IF v_why IS NULL THEN
    BEGIN
      IF v_op IN ('edit', 'end') THEN
        UPDATE pgvigil.alert_rules SET ended_by = v_user, ended_at = p_at WHERE rule_id = v_id;
        v_done := 'ended';
      ELSIF v_op IN ('enable', 'disable') THEN
        UPDATE pgvigil.alert_rules SET enabled = (v_op = 'enable') WHERE rule_id = v_id;
        v_done := CASE v_op WHEN 'enable' THEN 'switched on' ELSE 'switched off' END;
      END IF;
      IF v_op IN ('add', 'edit') THEN
        INSERT INTO pgvigil.alert_rules (name, metric, op, warning, critical, for_minutes, scope, tag, instance_id, instance_name,
                                         database, note, enabled, replaces, created_by, created_at, client)
        VALUES (v_name, v_metric, v_dir, v_warn, v_crit, v_for, v_scope, v_tag, v_iid, v_inst, v_db, v_note,
                CASE WHEN v_op = 'edit' THEN v_old.enabled ELSE true END,
                CASE WHEN v_op = 'edit' THEN v_id END, v_user, p_at, v_client)
        RETURNING rule_id INTO v_new;
        v_done := CASE v_op WHEN 'edit' THEN format('rule %s replaced by rule %s', v_id, v_new) ELSE 'added' END;
      END IF;
    EXCEPTION
      WHEN unique_violation THEN
        v_why := 'a live rule already holds this metric, scope and database: edit that rule';
        v_new := NULL;
      WHEN check_violation OR foreign_key_violation OR invalid_text_representation OR numeric_value_out_of_range
           OR string_data_right_truncation THEN
        v_why := 'refused by the store: ' || SQLERRM;
        v_new := NULL;
    END;
  END IF;
  INSERT INTO pgvigil.alert_rule_log (at, ui_user, client, op, rule_id, metric, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, v_op, coalesce(v_new, v_id), coalesce(v_metric, v_old.metric),
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, v_done), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'rule_id', coalesce(v_new, v_id));
END $$;
