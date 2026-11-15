-- 0196: B24d - the newest figures of every instance for the Prometheus endpoint (GET /metrics on pgvigil serve, off
-- unless doors.prometheus_metrics is on in pgvigil.yaml; internal/web/metrics_prom.go renders them).
--
-- metrics_newest(p_ids, p_lookback, p_databases, p_max_databases, p_include)
--   every metric_catalog key's NEWEST point within its fresh_secs of now, for every instance of p_ids (NULL = every
--   active one), computed SET-BASED in one statement - the samples of the freshness window (and the lookback before it,
--   so its first rate has its previous read) of all instances read once per source table, never metric_points or a
--   *_rate function per instance (3,000 calls at 1,000 instances). The arithmetic is metric_points' (0085) and the
--   *_rate functions' (0004), so a value equals the Metrics grid's 'current' (metric_grid: the newest non-NULL point
--   per metric) whenever that point is fresh: the same units (count, pct, secs, ms, per_s, bytes_per_s, bytes, mb,
--   xids); the exporter converts to base units. secs = the interval of a rate's point (NULL for a gauge), so the
--   per-interval counts (database.deadlocks, server.checkpoints, server.checkpoints_req) can be given per second.
--   database NULL = the instance's figure (the database family: its databases summed per read, as metric_points with
--   no database); with p_databases, each database's own series as well, the set chosen by size (the newest
--   database_sizes row of the last 2 days, largest first) or, when p_include is not NULL, the databases named there
--   (never by backends: the set must not churn), cut at p_max_databases; cut = the databases left out (on the
--   instance's rows only, NULL elsewhere: a key 'database.cut' with value = the count).
--   A stale point (older than its fresh_secs) is left out; a reset interval gives no point (metric_points' rule).
-- metrics_sample_times(p_ids)
--   the newest sample of each family of each instance within the last day, stale or not (one index probe of the
--   (instance_id, snapshot_at) index per partition per instance), for pgvigil_sample_timestamp_seconds.
--
-- Rights: STABLE readers of the stored samples, owned by the migration's owner like metric_points; serve's reader login
-- (pgvigil_reader) gets EXECUTE from apply_roles' general rule (every pgvigil function not on its owner-only, collector
-- or ui_ lists), PUBLIC none; no line of its own.

CREATE OR REPLACE FUNCTION pgvigil.metrics_newest(p_ids int[] DEFAULT NULL, p_lookback interval DEFAULT interval '15 minutes',
                                                  p_databases boolean DEFAULT false, p_max_databases int DEFAULT 50,
                                                  p_include text[] DEFAULT NULL)
RETURNS TABLE (instance_id int, family text, metric text, database text, value double precision, at timestamptz, secs int)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH ids AS (SELECT coalesce(p_ids, ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active)) AS a),
  fr AS (SELECT c.family, make_interval(secs => max(c.fresh_secs)) AS keep FROM pgvigil.metric_catalog c GROUP BY c.family),
  -- the gauges: every read of the window unpivoted, the newest non-NULL per metric
  sess AS (
    SELECT x.instance_id, x.snapshot_at AS at, v.metric, v.value
      FROM pgvigil.activity_summary x
      CROSS JOIN LATERAL (VALUES
        ('total', x.total::double precision), ('active', x.active::double precision),
        ('idle_in_txn', x.idle_in_txn::double precision), ('waiting_lock', x.waiting_lock::double precision),
        ('connections_pct', (100.0 * x.total / nullif(x.max_connections, 0))::double precision),
        ('longest_active_secs', x.longest_active_secs::double precision),
        ('longest_idle_txn_secs', x.longest_idle_txn_secs::double precision),
        ('oldest_xmin_age', x.oldest_xmin_age::double precision)) AS v(metric, value)
     WHERE x.instance_id = ANY ((SELECT a FROM ids)) AND x.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'sessions')
       AND x.snapshot_at <= now() AND v.value IS NOT NULL),
  req AS (
    SELECT x.instance_id, x.snapshot_at AS at, v.metric, v.value
      FROM pgvigil.mssql_requests_summary x
      CROSS JOIN LATERAL (VALUES
        ('sessions', x.sessions::double precision), ('requests', x.requests::double precision),
        ('blocked', x.blocked::double precision), ('heads', x.heads::double precision),
        ('longest_wait_ms', x.longest_wait_ms::double precision)) AS v(metric, value)
     WHERE x.instance_id = ANY ((SELECT a FROM ids)) AND x.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'requests')
       AND x.snapshot_at <= now() AND v.value IS NOT NULL),
  hst AS (                                   -- one row per read (two sources of one instance: the higher figure)
    SELECT h.instance_id, h.snapshot_at AS at, v.metric, v.value
      FROM (SELECT x.instance_id, x.snapshot_at, max(x.cpu_pct) AS cpu_pct, max(x.cpu_iowait_pct) AS cpu_iowait_pct,
                   max(100.0 * x.mem_used / nullif(x.mem_total, 0)) AS mem_used_pct, min(x.mem_free) AS mem_free,
                   max(x.swap_used) AS swap_used, max(x.load1) AS load1
              FROM pgvigil.host_sample x
             WHERE x.instance_id = ANY ((SELECT a FROM ids)) AND x.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'host')
               AND x.snapshot_at <= now()
             GROUP BY x.instance_id, x.snapshot_at) h
      CROSS JOIN LATERAL (VALUES
        ('cpu_pct', h.cpu_pct::double precision), ('cpu_iowait_pct', h.cpu_iowait_pct::double precision),
        ('mem_used_pct', h.mem_used_pct::double precision), ('mem_free', h.mem_free::double precision),
        ('swap_used', h.swap_used::double precision), ('load1', h.load1::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  cpu AS (                                   -- one row per record time
    SELECT c.instance_id, c.snapshot_at AS at, v.metric, v.value
      FROM (SELECT x.instance_id, x.snapshot_at, max(x.sql_pct) AS sql_pct, max(x.other_pct) AS other_pct, max(100 - x.idle_pct) AS total_pct
              FROM pgvigil.mssql_cpu_sample x
             WHERE x.instance_id = ANY ((SELECT a FROM ids)) AND x.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'cpu')
               AND x.snapshot_at <= now()
             GROUP BY x.instance_id, x.snapshot_at) c
      CROSS JOIN LATERAL (VALUES
        ('sql_pct', c.sql_pct::double precision), ('other_pct', c.other_pct::double precision),
        ('total_pct', c.total_pct::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  sch AS (
    SELECT c.instance_id, c.snapshot_at AS at, v.metric, v.value
      FROM (SELECT x.instance_id, x.snapshot_at, max(x.batch_s) AS batch_s, max(x.transactions_s) AS transactions_s,
                   max(x.compiles_s) AS compiles_s, max(x.recompiles_s) AS recompiles_s, max(x.runnable_tasks) AS runnable_tasks,
                   max(x.work_queue) AS work_queue, max(x.pending_io) AS pending_io, max(x.active_workers) AS active_workers,
                   max(x.current_workers) AS current_workers
              FROM pgvigil.mssql_sched_sample x
             WHERE x.instance_id = ANY ((SELECT a FROM ids)) AND x.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'scheduler')
               AND x.snapshot_at <= now()
             GROUP BY x.instance_id, x.snapshot_at) c
      CROSS JOIN LATERAL (VALUES
        ('batch_s', c.batch_s::double precision), ('transactions_s', c.transactions_s::double precision),
        ('compiles_s', c.compiles_s::double precision), ('recompiles_s', c.recompiles_s::double precision),
        ('runnable_tasks', c.runnable_tasks::double precision), ('work_queue', c.work_queue::double precision),
        ('pending_io', c.pending_io::double precision), ('active_workers', c.active_workers::double precision),
        ('current_workers', c.current_workers::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  mem AS (
    SELECT c.instance_id, c.snapshot_at AS at, v.metric, v.value
      FROM (SELECT x.instance_id, x.snapshot_at, max(x.ple) AS ple, max(x.grants_pending) AS grants_pending,
                   max(x.grants_outstanding) AS grants_outstanding, max(x.total_kb) AS total_kb, max(x.target_kb) AS target_kb,
                   max(x.buffer_pool_kb) AS buffer_pool_kb, max(x.plan_cache_kb) AS plan_cache_kb, max(x.stolen_kb) AS stolen_kb,
                   min(x.available_kb) AS available_kb, max(x.physical_kb) AS physical_kb
              FROM pgvigil.mssql_memory_sample x
             WHERE x.instance_id = ANY ((SELECT a FROM ids)) AND x.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'memory')
               AND x.snapshot_at <= now()
             GROUP BY x.instance_id, x.snapshot_at) c
      CROSS JOIN LATERAL (VALUES
        ('ple', c.ple::double precision), ('grants_pending', c.grants_pending::double precision),
        ('grants_outstanding', c.grants_outstanding::double precision),
        ('total_mb', (c.total_kb / 1024.0)::double precision), ('target_mb', (c.target_kb / 1024.0)::double precision),
        ('buffer_pool_mb', (c.buffer_pool_kb / 1024.0)::double precision),
        ('plan_cache_mb', (c.plan_cache_kb / 1024.0)::double precision), ('stolen_mb', (c.stolen_kb / 1024.0)::double precision),
        ('available_mb', (c.available_kb / 1024.0)::double precision),
        ('os_used_pct', (100.0 * (c.physical_kb - c.available_kb) / nullif(c.physical_kb, 0))::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  -- the rates: dbstats_rate / serverstats_rate / iostats_rate's lag and delta, partitioned by instance as well
  dw AS (
    SELECT d.instance_id, d.snapshot_at, d.dbid, d.datname, d.numbackends,
           extract(epoch FROM d.snapshot_at - lag(d.snapshot_at) OVER k)::int AS isecs,
           (d.stats_reset IS DISTINCT FROM lag(d.stats_reset) OVER k) AS rs,
           d.xact_commit, lag(d.xact_commit) OVER k AS p1, d.xact_rollback, lag(d.xact_rollback) OVER k AS p2,
           d.blks_read, lag(d.blks_read) OVER k AS p3, d.blks_hit, lag(d.blks_hit) OVER k AS p4,
           d.tup_returned, lag(d.tup_returned) OVER k AS p5, d.tup_fetched, lag(d.tup_fetched) OVER k AS p6,
           d.tup_inserted, lag(d.tup_inserted) OVER k AS p7, d.tup_updated, lag(d.tup_updated) OVER k AS p8,
           d.tup_deleted, lag(d.tup_deleted) OVER k AS p9, d.temp_bytes, lag(d.temp_bytes) OVER k AS p12,
           d.deadlocks, lag(d.deadlocks) OVER k AS p13
      FROM pgvigil.dbstats d
     WHERE d.instance_id = ANY ((SELECT a FROM ids))
       AND d.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'database') - p_lookback AND d.snapshot_at <= now()
    WINDOW k AS (PARTITION BY d.instance_id, d.dbid ORDER BY d.snapshot_at)),
  dd AS (
    SELECT w.instance_id, w.snapshot_at, w.datname, w.isecs, w.rs, w.numbackends,
           pgvigil.delta(w.xact_commit, w.p1, w.rs) AS c, pgvigil.delta(w.xact_rollback, w.p2, w.rs) AS rb,
           pgvigil.delta(w.blks_read, w.p3, w.rs) AS br, pgvigil.delta(w.blks_hit, w.p4, w.rs) AS bh,
           pgvigil.delta(w.tup_returned, w.p5, w.rs) + pgvigil.delta(w.tup_fetched, w.p6, w.rs) AS tr,
           pgvigil.delta(w.tup_inserted, w.p7, w.rs) + pgvigil.delta(w.tup_updated, w.p8, w.rs) + pgvigil.delta(w.tup_deleted, w.p9, w.rs) AS tw,
           pgvigil.delta(w.temp_bytes, w.p12, w.rs) AS tb, pgvigil.delta(w.deadlocks, w.p13, w.rs) AS dl
      FROM dw w
     WHERE w.isecs > 0 AND w.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'database')),
  -- the instance's figure: its databases summed per read; a database reset in the interval gives no point
  dbi AS (
    SELECT r.instance_id, r.snapshot_at AS at, r.secs, v.metric, v.value
      FROM (SELECT x.instance_id, x.snapshot_at, max(x.isecs) AS secs, sum(x.c) AS c, sum(x.rb) AS rb, sum(x.br) AS br, sum(x.bh) AS bh,
                   sum(x.tr) AS tr, sum(x.tw) AS tw, sum(x.tb) AS tb, sum(x.dl) AS dl, sum(x.numbackends) AS nb
              FROM dd x GROUP BY x.instance_id, x.snapshot_at HAVING NOT bool_or(x.rs)) r
      CROSS JOIN LATERAL (VALUES
        ('commits_s', (r.c / r.secs)::double precision), ('rollbacks_s', (r.rb / r.secs)::double precision),
        ('blks_read_s', (r.br / r.secs)::double precision), ('blks_hit_s', (r.bh / r.secs)::double precision),
        ('cache_hit_pct', (100.0 * r.bh / nullif(r.bh + r.br, 0))::double precision),
        ('tup_read_s', (r.tr / r.secs)::double precision), ('tup_written_s', (r.tw / r.secs)::double precision),
        ('temp_bytes_s', (r.tb / r.secs)::double precision), ('deadlocks', r.dl::double precision),
        ('backends', r.nb::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  -- one database's own series (p_databases): the same sums over that name's rows, its set chosen and cut
  pick AS (
    SELECT q.instance_id, q.datname, q.rn, q.n
      FROM (SELECT c.instance_id, c.datname,
                   row_number() OVER (PARTITION BY c.instance_id ORDER BY c.size DESC NULLS LAST, c.datname) AS rn,
                   count(*) OVER (PARTITION BY c.instance_id) AS n
              FROM (SELECT DISTINCT ON (z.instance_id, z.datname) z.instance_id, z.datname, s.size_bytes AS size
                      FROM (SELECT DISTINCT y.instance_id, y.datname FROM dd y WHERE p_databases AND y.datname IS NOT NULL) z
                      LEFT JOIN LATERAL (SELECT s.size_bytes FROM pgvigil.database_sizes s
                                          WHERE s.instance_id = z.instance_id AND s.datname = z.datname
                                            AND s.snapshot_at > now() - interval '2 days' AND s.snapshot_at <= now()
                                          ORDER BY s.snapshot_at DESC LIMIT 1) s ON true
                     WHERE p_include IS NULL OR z.datname = ANY (p_include)) c) q),
  dbd AS (
    SELECT r.instance_id, r.datname, r.snapshot_at AS at, r.secs, v.metric, v.value
      FROM (SELECT x.instance_id, x.datname, x.snapshot_at, max(x.isecs) AS secs, sum(x.c) AS c, sum(x.rb) AS rb, sum(x.br) AS br,
                   sum(x.bh) AS bh, sum(x.tr) AS tr, sum(x.tw) AS tw, sum(x.tb) AS tb, sum(x.dl) AS dl, sum(x.numbackends) AS nb
              FROM dd x JOIN pick p ON p.instance_id = x.instance_id AND p.datname = x.datname AND p.rn <= p_max_databases
             GROUP BY x.instance_id, x.datname, x.snapshot_at HAVING NOT bool_or(x.rs)) r
      CROSS JOIN LATERAL (VALUES
        ('commits_s', (r.c / r.secs)::double precision), ('rollbacks_s', (r.rb / r.secs)::double precision),
        ('blks_read_s', (r.br / r.secs)::double precision), ('blks_hit_s', (r.bh / r.secs)::double precision),
        ('cache_hit_pct', (100.0 * r.bh / nullif(r.bh + r.br, 0))::double precision),
        ('tup_read_s', (r.tr / r.secs)::double precision), ('tup_written_s', (r.tw / r.secs)::double precision),
        ('temp_bytes_s', (r.tb / r.secs)::double precision), ('deadlocks', r.dl::double precision),
        ('backends', r.nb::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  sw AS (
    SELECT s.instance_id, s.snapshot_at,
           extract(epoch FROM s.snapshot_at - lag(s.snapshot_at) OVER k)::int AS isecs,
           (s.bgwriter_stats_reset IS DISTINCT FROM lag(s.bgwriter_stats_reset) OVER k
            OR s.checkpointer_stats_reset IS DISTINCT FROM lag(s.checkpointer_stats_reset) OVER k) AS rs,
           s.checkpoints_timed, lag(s.checkpoints_timed) OVER k AS p1, s.checkpoints_req, lag(s.checkpoints_req) OVER k AS p2,
           s.buffers_checkpoint, lag(s.buffers_checkpoint) OVER k AS p5, s.buffers_clean, lag(s.buffers_clean) OVER k AS p6,
           s.buffers_backend, lag(s.buffers_backend) OVER k AS p8, s.buffers_alloc, lag(s.buffers_alloc) OVER k AS p10,
           s.wal_records, lag(s.wal_records) OVER k AS p11, s.wal_bytes, lag(s.wal_bytes) OVER k AS p13
      FROM pgvigil.serverstats s
     WHERE s.instance_id = ANY ((SELECT a FROM ids))
       AND s.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'server') - p_lookback AND s.snapshot_at <= now()
    WINDOW k AS (PARTITION BY s.instance_id ORDER BY s.snapshot_at)),
  srv AS (
    SELECT s.instance_id, s.snapshot_at AS at, s.isecs AS secs, v.metric, v.value
      FROM (SELECT w.instance_id, w.snapshot_at, w.isecs, w.rs,
                   pgvigil.delta(w.checkpoints_timed, w.p1, w.rs) AS checkpoints_timed, pgvigil.delta(w.checkpoints_req, w.p2, w.rs) AS checkpoints_req,
                   pgvigil.delta(w.buffers_checkpoint, w.p5, w.rs) AS buffers_checkpoint, pgvigil.delta(w.buffers_clean, w.p6, w.rs) AS buffers_clean,
                   pgvigil.delta(w.buffers_backend, w.p8, w.rs) AS buffers_backend, pgvigil.delta(w.buffers_alloc, w.p10, w.rs) AS buffers_alloc,
                   pgvigil.delta(w.wal_records, w.p11, w.rs) AS wal_records, pgvigil.delta(w.wal_bytes, w.p13, w.rs) AS wal_bytes
              FROM sw w
             WHERE w.isecs > 0 AND w.rs IS NOT TRUE AND w.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'server')) s
      CROSS JOIN LATERAL (VALUES
        ('checkpoints', (s.checkpoints_timed + s.checkpoints_req)::double precision),
        ('checkpoints_req', s.checkpoints_req::double precision),
        ('buffers_written_s', (CASE WHEN num_nonnulls(s.buffers_checkpoint, s.buffers_clean, s.buffers_backend) > 0 THEN
            (coalesce(s.buffers_checkpoint, 0) + coalesce(s.buffers_clean, 0) + coalesce(s.buffers_backend, 0))::numeric / s.isecs END)::double precision),
        ('buffers_alloc_s', (s.buffers_alloc::numeric / s.isecs)::double precision),
        ('wal_bytes_s', (s.wal_bytes / s.isecs)::double precision),
        ('wal_records_s', (s.wal_records::numeric / s.isecs)::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  iw AS (
    SELECT i.instance_id, i.snapshot_at, i.op_bytes,
           extract(epoch FROM i.snapshot_at - lag(i.snapshot_at) OVER k)::int AS isecs,
           (i.stats_reset IS DISTINCT FROM lag(i.stats_reset) OVER k) AS rs,
           i.reads, lag(i.reads) OVER k AS p1, i.read_bytes, lag(i.read_bytes) OVER k AS p2,
           i.writes, lag(i.writes) OVER k AS p4, i.write_bytes, lag(i.write_bytes) OVER k AS p5,
           i.extends, lag(i.extends) OVER k AS p9, i.extend_bytes, lag(i.extend_bytes) OVER k AS p10,
           i.hits, lag(i.hits) OVER k AS p12, i.fsyncs, lag(i.fsyncs) OVER k AS p15
      FROM pgvigil.iostats i
     WHERE i.instance_id = ANY ((SELECT a FROM ids))
       AND i.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'io') - p_lookback AND i.snapshot_at <= now()
    WINDOW k AS (PARTITION BY i.instance_id, i.backend_type, i.object, i.context ORDER BY i.snapshot_at)),
  io AS (
    SELECT r.instance_id, r.snapshot_at AS at, r.secs, v.metric, v.value
      FROM (SELECT w.instance_id, w.snapshot_at, max(w.isecs) AS secs,
                   sum(coalesce(pgvigil.delta(w.read_bytes, w.p2, w.rs), pgvigil.delta(w.reads, w.p1, w.rs) * w.op_bytes)) AS rb,
                   sum(coalesce(pgvigil.delta(w.write_bytes, w.p5, w.rs), pgvigil.delta(w.writes, w.p4, w.rs) * w.op_bytes)) AS wb,
                   sum(coalesce(pgvigil.delta(w.extend_bytes, w.p10, w.rs), pgvigil.delta(w.extends, w.p9, w.rs) * w.op_bytes)) AS eb,
                   sum(pgvigil.delta(w.hits, w.p12, w.rs)) AS h, sum(pgvigil.delta(w.fsyncs, w.p15, w.rs)) AS f
              FROM iw w
             WHERE w.isecs > 0 AND w.snapshot_at > now() - (SELECT keep FROM fr WHERE fr.family = 'io')
             GROUP BY w.instance_id, w.snapshot_at HAVING NOT bool_or(w.rs)) r
      CROSS JOIN LATERAL (VALUES
        ('read_bytes_s', (r.rb / r.secs)::double precision), ('write_bytes_s', (r.wb / r.secs)::double precision),
        ('extend_bytes_s', (r.eb / r.secs)::double precision), ('hits_s', (r.h / r.secs)::double precision),
        ('fsyncs_s', (r.f / r.secs)::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL),
  pts AS (
    SELECT 'sessions'::text AS family, NULL::text AS database, s.instance_id, s.at, NULL::int AS secs, s.metric, s.value FROM sess s
    UNION ALL SELECT 'requests', NULL, s.instance_id, s.at, NULL, s.metric, s.value FROM req s
    UNION ALL SELECT 'host', NULL, s.instance_id, s.at, NULL, s.metric, s.value FROM hst s
    UNION ALL SELECT 'cpu', NULL, s.instance_id, s.at, NULL, s.metric, s.value FROM cpu s
    UNION ALL SELECT 'scheduler', NULL, s.instance_id, s.at, NULL, s.metric, s.value FROM sch s
    UNION ALL SELECT 'memory', NULL, s.instance_id, s.at, NULL, s.metric, s.value FROM mem s
    UNION ALL SELECT 'database', NULL, s.instance_id, s.at, s.secs, s.metric, s.value FROM dbi s
    UNION ALL SELECT 'database', s.datname, s.instance_id, s.at, s.secs, s.metric, s.value FROM dbd s
    UNION ALL SELECT 'server', NULL, s.instance_id, s.at, s.secs, s.metric, s.value FROM srv s
    UNION ALL SELECT 'io', NULL, s.instance_id, s.at, s.secs, s.metric, s.value FROM io s)
  SELECT n.instance_id, n.family, n.metric, n.database, n.value, n.at, n.secs
    FROM (SELECT DISTINCT ON (p.instance_id, p.family, p.database, p.metric) p.*
            FROM pts p ORDER BY p.instance_id, p.family, p.database, p.metric, p.at DESC) n
  UNION ALL
  SELECT k.instance_id, 'database', 'cut', NULL, (max(k.n) - p_max_databases)::double precision, NULL, NULL
    FROM pick k GROUP BY k.instance_id HAVING max(k.n) > p_max_databases
$$;
COMMENT ON FUNCTION pgvigil.metrics_newest(int[], interval, boolean, int, text[]) IS
  'The newest fresh point of every metric_catalog key of every instance in one set-based statement (the Prometheus endpoint); metric_points'' arithmetic and units; database.cut = the databases left out of the per-database series.';

CREATE OR REPLACE FUNCTION pgvigil.metrics_sample_times(p_ids int[] DEFAULT NULL)
RETURNS TABLE (instance_id int, family text, at timestamptz)
LANGUAGE sql STABLE SET jit = off AS $$
  SELECT i.instance_id, f.family, t.at
    FROM pgvigil.instances i
    CROSS JOIN LATERAL (SELECT DISTINCT c.family FROM pgvigil.metric_catalog c WHERE c.engine IN (i.engine, 'any')) f
    CROSS JOIN LATERAL (SELECT CASE f.family
             WHEN 'sessions'  THEN (SELECT max(x.snapshot_at) FROM pgvigil.activity_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'database'  THEN (SELECT max(x.snapshot_at) FROM pgvigil.dbstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'server'    THEN (SELECT max(x.snapshot_at) FROM pgvigil.serverstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'io'        THEN (SELECT max(x.snapshot_at) FROM pgvigil.iostats x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'host'      THEN (SELECT max(x.snapshot_at) FROM pgvigil.host_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'requests'  THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_requests_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'cpu'       THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_cpu_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'scheduler' THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_sched_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
             WHEN 'memory'    THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_memory_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.snapshot_at <= now())
           END AS at) t
   WHERE i.instance_id = ANY (coalesce(p_ids, ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active)))
     AND t.at IS NOT NULL
$$;
COMMENT ON FUNCTION pgvigil.metrics_sample_times(int[]) IS
  'The newest sample of each metric family of each instance within the last day, stale or not (pgvigil_sample_timestamp_seconds).';
