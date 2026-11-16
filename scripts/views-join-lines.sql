-- views-join-lines.sql: the lines VIEWS slice C needs in an object another migration owns, for the lead to place at
-- the join (rel-views-a; the panel compiler internal/web/compose.go reads metric_catalog.grain).
--   metric_catalog (0085's view): re-created whole with one column appended, grain (rate | ratio | interval_count |
--   gauge); CREATE OR REPLACE VIEW keeps every existing column, name and order, so 0085's readers are unchanged.
-- The proofs of the branch apply this file after migrate.
CREATE OR REPLACE VIEW pgvigil.metric_catalog AS
SELECT v.family || '.' || v.metric AS key, v.engine, v.family, v.family_label, v.family_sort, v.metric, v.label, v.unit,
       v.per_database, v.fresh_secs, v.sort,
       -- grain (views slice C): how a panel rolls a metric up within a time bucket before its aggregate across
       -- instances: a rate or a gauge is averaged, a count per collection interval summed, a ratio averaged and
       -- never summed; a new metric names its grain here (gauge is the default)
       CASE WHEN v.unit IN ('per_s', 'bytes_per_s') THEN 'rate'
            WHEN v.unit = 'pct' THEN 'ratio'
            WHEN v.family || '.' || v.metric IN ('database.deadlocks', 'server.checkpoints', 'server.checkpoints_req') THEN 'interval_count'
            ELSE 'gauge' END AS grain
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
