-- 0047_drill: the read functions of the drill-down pages (task 48; DBADash's per-object drill-down): a database
-- page, a table page, a job page and an index page, each scoped to one object of one instance. No table and no
-- collection: every function reads what the collections already store.
--
--   drill_db_series(i, db, f, t, b)      its size per bucket (database_sizes).
--   drill_db_tables(i, db)               the database's tables as the tables collection read them, with their checks.
--   drill_db_extensions(i, db)           the extensions installed in it.
--   drill_db_acl(i, db)                  who may CONNECT / CREATE / TEMPORARY on it, and the schema grants inside it.
--   drill_db_jobs(i, db)                 the scheduled jobs that run in it (job_report).
--   drill_db_slow(i, db, f, t, n)        the slow statement shapes of the window that ran in it (log_events 'slow').
--   drill_db_statements(i, db, f, t, n)  its top statements by total time over the window (statements_delta).
--   drill_table(i, db, rel)              the table's row with its vacuum settings and thresholds.
--   drill_table_series(i, db, rel, f, t, b)  size, live and dead rows, bloat per b-second bucket.
--   drill_table_vacuum(i, db, rel, f, t) its vacuum and analyze runs of the window (sampled runs, autovacuum log events).
--   drill_table_checks(i, db, rel)       the table and vacuum checks on it.
--   drill_table_indexes(i, db, rel)      the indexes on it the indexes collection holds (the problem ones: unused,
--                                        redundant, duplicate, invalid; the collection keeps no other index).
--   drill_table_statements(i, db, rel, f, t, n)  the window's top statements whose text names the table.
--   drill_job(i, scheduler, job)         the job's report row; drill_job_runs(i, scheduler, job, f, t) its runs.
--   drill_index(i, db, idx)              the index's rows (one per problem) with the finding's text and the DROP / undo lines.
-- A database is named by its oid (dbid), a table by (dbid, relid), an index by (dbid, indexrelid): a rename keeps the link.

-- the regular expression that matches a name as a whole word (its own special characters escaped)
CREATE OR REPLACE FUNCTION pgvigil.word_re(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '\m' || regexp_replace(p_name, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g') || '\M'
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_db_tables(p_instance_id int, p_dbid bigint)
RETURNS TABLE (relid bigint, schema_name text, table_name text, total_bytes bigint, heap_bytes bigint, toast_bytes bigint, index_bytes bigint,
               n_live_tup bigint, n_dead_tup bigint, dead_pct numeric, bloat_pct numeric, bloat_bytes bigint, last_vacuum timestamptz,
               last_analyze timestamptz, seq_scan bigint, idx_scan bigint, xid_age bigint, checks text, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.relid, t.schema_name, t.table_name, t.total_bytes, t.heap_bytes, t.toast_bytes, t.index_bytes, t.n_live_tup, t.n_dead_tup,
         round(100.0 * t.n_dead_tup / nullif(t.n_live_tup + t.n_dead_tup, 0), 1), t.bloat_pct, t.bloat_bytes, t.last_vacuum, t.last_analyze,
         t.seq_scan, t.idx_scan, t.xid_age, c.checks, t.snapshot_at
    FROM pgvigil.tables t
    LEFT JOIN (SELECT x.object, string_agg(DISTINCT x.check_name, ', ') AS checks
                 FROM (SELECT object, check_name FROM pgvigil.table_checks WHERE instance_id = p_instance_id
                       UNION ALL
                       SELECT object, check_name FROM pgvigil.vacuum_checks WHERE instance_id = p_instance_id) x
                GROUP BY x.object) c ON c.object = t.datname || '.' || t.schema_name || '.' || t.table_name
   WHERE t.instance_id = p_instance_id AND t.dbid = p_dbid AND t.is_present
   ORDER BY t.total_bytes DESC NULLS LAST, t.schema_name, t.table_name
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_db_extensions(p_instance_id int, p_dbid bigint)
RETURNS TABLE (name text, version text, schema_name text, default_version text, outdated boolean, comment text, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT x.name, x.version, x.schema_name, a.default_version,
         coalesce(pgvigil.ext_version_lt(x.version, a.default_version), x.version IS DISTINCT FROM a.default_version AND a.default_version IS NOT NULL),
         a.comment, x.snapshot_at
    FROM pgvigil.database_extensions x
    LEFT JOIN pgvigil.instance_extensions a ON a.instance_id = x.instance_id AND a.name = x.name
   WHERE x.instance_id = p_instance_id AND x.dbid = p_dbid AND x.is_present
   ORDER BY x.name
$$;

-- level 'database': the database's own ACL; 'schema': each schema's inside it (the roles collection reads them)
CREATE OR REPLACE FUNCTION pgvigil.drill_db_acl(p_instance_id int, p_dbid bigint)
RETURNS TABLE (level text, object text, grantee text, privileges text, grantable text, grantor text, owner text, is_default boolean, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH d AS (SELECT datname FROM pgvigil.databases WHERE instance_id = p_instance_id AND dbid = p_dbid)
  SELECT 'database', a.datname, a.grantee, a.privileges, nullif(a.grantable, ''), a.grantor, a.owner, a.is_default, a.snapshot_at
    FROM pgvigil.acl_databases a JOIN d USING (datname)
   WHERE a.instance_id = p_instance_id AND a.is_present
  UNION ALL
  SELECT 'schema', s.schema_name, s.grantee, s.privileges, nullif(s.grantable, ''), s.grantor, s.owner, s.is_default, s.snapshot_at
    FROM pgvigil.acl_schemas s JOIN d USING (datname)
   WHERE s.instance_id = p_instance_id AND s.is_present
   ORDER BY 1, 2, 3
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_db_jobs(p_instance_id int, p_dbid bigint)
RETURNS SETOF pgvigil.job_report
LANGUAGE sql STABLE AS $$
  SELECT r.* FROM pgvigil.job_report r
   WHERE r.instance_id = p_instance_id AND r.is_present
     AND r.datname = (SELECT datname FROM pgvigil.databases WHERE instance_id = p_instance_id AND dbid = p_dbid)
   ORDER BY r.job_name, r.job_id
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_db_slow(p_instance_id int, p_dbid bigint, p_from timestamptz, p_to timestamptz, p_limit int DEFAULT 20)
RETURNS TABLE (shape_key text, statements bigint, total_ms float8, mean_ms float8, max_ms float8, last_at timestamptz, users text, example text)
LANGUAGE sql STABLE AS $$
  WITH g AS (
    SELECT e.shape_key, count(*) AS n, sum(e.duration_ms) AS total, avg(e.duration_ms) AS mean, max(e.duration_ms) AS mx,
           max(e.snapshot_at) AS last_at, string_agg(DISTINCT e.usename, ', ') AS users
      FROM pgvigil.log_events e
     WHERE e.instance_id = p_instance_id AND e.kind = 'slow' AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
       AND e.datname = (SELECT datname FROM pgvigil.databases WHERE instance_id = p_instance_id AND dbid = p_dbid)
     GROUP BY e.shape_key
     ORDER BY count(*) DESC, sum(e.duration_ms) DESC
     LIMIT greatest(1, least(coalesce(p_limit, 20), 500)))
  SELECT g.shape_key, g.n, g.total, g.mean, g.mx, g.last_at, g.users,
         (SELECT left(e.statement, 4000) FROM pgvigil.log_events e
           WHERE e.instance_id = p_instance_id AND e.kind = 'slow' AND e.shape_key IS NOT DISTINCT FROM g.shape_key
             AND e.snapshot_at > p_from AND e.snapshot_at <= p_to
           ORDER BY e.duration_ms DESC LIMIT 1)
    FROM g
   ORDER BY g.n DESC, g.total DESC
$$;

-- the window's statements of one database ($2 NULL: every database), or naming a regular expression ($6), by total time;
-- the window share of each delta row as top_statements_by (0016) counts it
CREATE OR REPLACE FUNCTION pgvigil.drill_statements(p_instance_id int, p_dbid bigint, p_from timestamptz, p_to timestamptz,
                                                    p_limit int DEFAULT 20, p_text_re text DEFAULT NULL)
RETURNS TABLE (queryid bigint, datname text, usename text, calls double precision, total_exec_ms double precision,
               mean_exec_ms double precision, rows double precision, shared_blks_read double precision, hit_pct numeric, query text)
LANGUAGE sql STABLE AS $$
  WITH q AS (
    SELECT t.queryid FROM pgvigil.statement_text t
     WHERE t.instance_id = p_instance_id AND p_text_re IS NOT NULL AND t.query ~* p_text_re
  ), d AS (
    SELECT d.*,
           greatest(0, extract(epoch FROM least(d.snapshot_at, p_to) - greatest(d.snapshot_at - make_interval(secs => d.interval_secs), p_from)))
             / d.interval_secs AS share
      FROM pgvigil.statements_delta d
     WHERE d.instance_id = p_instance_id
       AND (p_dbid IS NULL OR d.dbid = p_dbid)
       AND (p_text_re IS NULL OR d.queryid IN (SELECT queryid FROM q))
       AND d.snapshot_at > p_from
       AND d.snapshot_at - make_interval(secs => d.interval_secs) < p_to
  ), a AS (
    SELECT d.queryid, min(d.datname) AS datname, min(d.usename) AS usename, sum(d.calls * d.share) AS calls,
           sum(d.total_exec_ms * d.share) AS total_exec_ms, sum(d.rows * d.share) AS rows,
           sum(d.shared_blks_read * d.share) AS shared_blks_read, sum(d.shared_blks_hit * d.share) AS shared_blks_hit
      FROM d WHERE d.share > 0
     GROUP BY d.queryid
  )
  SELECT a.queryid, a.datname, a.usename, a.calls, a.total_exec_ms, a.total_exec_ms / nullif(a.calls, 0), a.rows, a.shared_blks_read,
         round((100 * a.shared_blks_hit / nullif(a.shared_blks_hit + a.shared_blks_read, 0))::numeric, 1),
         (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p_instance_id AND t.queryid = a.queryid)
    FROM a
   ORDER BY a.total_exec_ms DESC NULLS LAST, a.queryid
   LIMIT greatest(1, least(coalesce(p_limit, 20), 500))
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_table(p_instance_id int, p_dbid bigint, p_relid bigint)
RETURNS TABLE (dbid bigint, relid bigint, datname text, schema_name text, table_name text, relkind text, is_present boolean,
               total_bytes bigint, heap_bytes bigint, toast_bytes bigint, index_bytes bigint, reltuples double precision,
               n_live_tup bigint, n_dead_tup bigint, dead_pct numeric, all_visible_pct numeric, n_mod_since_analyze bigint,
               n_ins_since_vacuum bigint, last_vacuum timestamptz, last_autovacuum timestamptz, last_analyze timestamptz,
               last_autoanalyze timestamptz, vacuums bigint, analyzes bigint, seq_scan bigint, idx_scan bigint, xid_age bigint,
               mxid_age bigint, autovacuum_off boolean, bloat_bytes bigint, bloat_pct numeric, stats_readable boolean,
               vac_threshold double precision, ins_threshold double precision, anl_threshold double precision,
               has_own_settings boolean, freeze_max_age bigint, first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.dbid, t.relid, t.datname, t.schema_name, t.table_name, t.relkind, t.is_present, t.total_bytes, t.heap_bytes, t.toast_bytes,
         t.index_bytes, t.reltuples, t.n_live_tup, t.n_dead_tup, round(100.0 * t.n_dead_tup / nullif(t.n_live_tup + t.n_dead_tup, 0), 1),
         round(100.0 * t.relallvisible / nullif(t.relpages, 0), 1), t.n_mod_since_analyze, t.n_ins_since_vacuum, t.last_vacuum,
         t.last_autovacuum, t.last_analyze, t.last_autoanalyze, t.vacuums, t.analyzes, t.seq_scan, t.idx_scan, t.xid_age, t.mxid_age,
         t.autovacuum_off, t.bloat_bytes, t.bloat_pct, t.stats_readable, v.vac_threshold, v.ins_threshold, v.anl_threshold,
         v.has_own_settings, v.freeze_max_age, t.first_seen, t.snapshot_at
    FROM pgvigil.tables t
    LEFT JOIN pgvigil.vacuum_tables v ON v.instance_id = t.instance_id AND v.dbid = t.dbid AND v.relid = t.relid AND v.is_present
   WHERE t.instance_id = p_instance_id AND t.dbid = p_dbid AND t.relid = p_relid
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_table_series(p_instance_id int, p_dbid bigint, p_relid bigint, p_from timestamptz, p_to timestamptz, p_bucket int)
RETURNS TABLE (snapshot_at timestamptz, total_bytes bigint, n_live_tup bigint, n_dead_tup bigint, bloat_bytes bigint, xid_age bigint)
LANGUAGE sql STABLE AS $$
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / greatest(p_bucket, 60)) * greatest(p_bucket, 60)),
         max(s.total_bytes), max(s.n_live_tup), max(s.n_dead_tup), max(s.bloat_bytes), max(s.xid_age)
    FROM pgvigil.table_sizes s
   WHERE s.instance_id = p_instance_id AND s.dbid = p_dbid AND s.relid = p_relid AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   GROUP BY 1 ORDER BY 1
$$;

-- the sampled runs carry the relid; a log event names the table in its text as "db.schema.table" (an autovacuum's
-- line, a cancel's CONTEXT), matched whole and quoted
CREATE OR REPLACE FUNCTION pgvigil.drill_table_vacuum(p_instance_id int, p_dbid bigint, p_relid bigint, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (source text, started_at timestamptz, ended_at timestamptz, kind text, is_auto boolean, is_wraparound boolean,
               elapsed_secs int, last_phase text, heap_blks_total bigint, heap_blks_scanned bigint, dead_tuples bigint,
               index_vacuum_count bigint, waited_lock boolean, detail text)
LANGUAGE sql STABLE AS $$
  WITH t AS (SELECT datname || '.' || schema_name || '.' || table_name AS obj FROM pgvigil.tables
              WHERE instance_id = p_instance_id AND dbid = p_dbid AND relid = p_relid)
  SELECT 'sample', r.started_at, r.last_seen, r.kind, r.is_auto, r.is_wraparound, r.elapsed_secs, r.last_phase, r.heap_blks_total,
         r.heap_blks_scanned, r.dead_tuples, r.index_vacuum_count, r.waited_lock, NULL::text
    FROM pgvigil.vacuum_runs r
   WHERE r.instance_id = p_instance_id AND r.dbid = p_dbid AND r.relid = p_relid AND r.last_seen >= p_from AND r.started_at <= p_to
  UNION ALL
  SELECT 'log', e.snapshot_at - make_interval(secs => coalesce(e.duration_ms, 0) / 1000), e.snapshot_at, e.kind,
         true, coalesce(e.detail ~* 'to prevent wraparound', false), (e.duration_ms / 1000)::int, NULL, NULL, NULL, NULL, NULL, false,
         left(coalesce(e.detail, e.statement), 2000)
    FROM pgvigil.log_events e CROSS JOIN t
   WHERE e.instance_id = p_instance_id AND e.kind IN ('autovacuum', 'autovacuum_cancel') AND e.snapshot_at >= p_from AND e.snapshot_at <= p_to
     AND (e.statement = t.obj OR strpos(coalesce(e.detail, ''), '"' || t.obj || '"') > 0 OR strpos(coalesce(e.statement, ''), '"' || t.obj || '"') > 0)
   ORDER BY 2 DESC
   LIMIT 2000
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_table_checks(p_instance_id int, p_dbid bigint, p_relid bigint)
RETURNS TABLE (severity text, check_name text, at timestamptz, detail text)
LANGUAGE sql STABLE AS $$
  WITH t AS (SELECT datname || '.' || schema_name || '.' || table_name AS obj FROM pgvigil.tables
              WHERE instance_id = p_instance_id AND dbid = p_dbid AND relid = p_relid)
  SELECT c.severity, c.check_name, c.at, c.detail FROM pgvigil.table_checks c JOIN t ON c.object = t.obj WHERE c.instance_id = p_instance_id
  UNION ALL
  SELECT c.severity, c.check_name, c.at, c.detail FROM pgvigil.vacuum_checks c JOIN t ON c.object = t.obj WHERE c.instance_id = p_instance_id
   ORDER BY 1, 2
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_table_indexes(p_instance_id int, p_dbid bigint, p_relid bigint)
RETURNS TABLE (indexrelid bigint, index_name text, problems text, access_method text, index_bytes bigint, idx_scan bigint,
               covered_by text, index_def text, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT s.indexrelid, min(s.index_name), string_agg(s.problem, ', ' ORDER BY s.problem), min(s.access_method), max(s.index_bytes),
         max(s.idx_scan), string_agg(DISTINCT s.covered_by, ', '), min(s.index_def), max(s.snapshot_at)
    FROM pgvigil.index_state s
    JOIN pgvigil.tables t ON t.instance_id = s.instance_id AND t.dbid = s.dbid AND t.relid = p_relid
                         AND t.schema_name = s.schema_name AND t.table_name = s.table_name
   WHERE s.instance_id = p_instance_id AND s.dbid = p_dbid AND s.is_present
   GROUP BY s.indexrelid
   ORDER BY max(s.index_bytes) DESC NULLS LAST, 2
$$;

-- a statement names the table when its text holds the table's name as a whole word (qualified or not): a heuristic,
-- so a same-named table in another schema, or a column of that name, matches too; the page says so
CREATE OR REPLACE FUNCTION pgvigil.drill_table_statements(p_instance_id int, p_dbid bigint, p_relid bigint, p_from timestamptz, p_to timestamptz,
                                                          p_limit int DEFAULT 20)
RETURNS TABLE (queryid bigint, datname text, usename text, calls double precision, total_exec_ms double precision,
               mean_exec_ms double precision, rows double precision, shared_blks_read double precision, hit_pct numeric, query text)
LANGUAGE sql STABLE AS $$
  SELECT s.* FROM pgvigil.tables t
   CROSS JOIN LATERAL pgvigil.drill_statements(p_instance_id, p_dbid, p_from, p_to, p_limit, pgvigil.word_re(t.table_name)) s
   WHERE t.instance_id = p_instance_id AND t.dbid = p_dbid AND t.relid = p_relid
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_job(p_instance_id int, p_scheduler text, p_job_id bigint)
RETURNS SETOF pgvigil.job_report
LANGUAGE sql STABLE AS $$
  SELECT r.* FROM pgvigil.job_report r WHERE r.instance_id = p_instance_id AND r.scheduler = p_scheduler AND r.job_id = p_job_id
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_job_runs(p_instance_id int, p_scheduler text, p_job_id bigint, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (run_id bigint, status text, start_time timestamptz, end_time timestamptz, duration_secs numeric, running boolean,
               failed boolean, datname text, run_as text, job_pid int, return_message text, command text)
LANGUAGE sql STABLE AS $$
  SELECT r.run_id, r.status, r.start_time, r.end_time,
         round(CASE WHEN r.end_time IS NULL AND r.status NOT IN ('succeeded', 'failed', 'internal error', 'aborted')
                    THEN extract(epoch FROM now() - r.start_time) ELSE r.duration_secs END::numeric, 1),
         r.end_time IS NULL AND r.status NOT IN ('succeeded', 'failed', 'internal error', 'aborted'),
         r.status IN ('failed', 'internal error', 'aborted'), r.datname, r.run_as, r.job_pid, left(r.return_message, 2000), left(r.command, 4000)
    FROM pgvigil.job_runs r
   WHERE r.instance_id = p_instance_id AND r.scheduler = p_scheduler AND r.job_id = p_job_id
     AND r.start_time > p_from AND r.start_time <= p_to
   ORDER BY r.start_time DESC
   LIMIT 2000
$$;

CREATE OR REPLACE FUNCTION pgvigil.drill_index(p_instance_id int, p_dbid bigint, p_indexrelid bigint)
RETURNS TABLE (dbid bigint, indexrelid bigint, datname text, schema_name text, table_name text, relid bigint, index_name text,
               problem text, access_method text, index_bytes bigint, table_bytes bigint, idx_scan bigint, stats_since timestamptz,
               is_replica boolean, covered_by text, covered_by_def text, index_def text, supports_fk boolean, drop_sql text, undo_sql text,
               severity text, suggested text, finding text, is_present boolean, first_seen timestamptz, snapshot_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT s.dbid, s.indexrelid, s.datname, s.schema_name, s.table_name,
         (SELECT t.relid FROM pgvigil.tables t WHERE t.instance_id = s.instance_id AND t.dbid = s.dbid
             AND t.schema_name = s.schema_name AND t.table_name = s.table_name AND t.is_present LIMIT 1),
         s.index_name, s.problem, s.access_method, s.index_bytes, s.table_bytes, s.idx_scan, d.stats_since, d.is_replica,
         s.covered_by, s.covered_by_def, s.index_def, s.supports_fk, s.drop_sql, s.undo_sql,
         f.severity, f.suggested, f.detail, s.is_present, s.first_seen, s.snapshot_at
    FROM pgvigil.index_state s
    LEFT JOIN pgvigil.index_databases d ON d.instance_id = s.instance_id AND d.dbid = s.dbid
    LEFT JOIN pgvigil.index_findings f ON f.instance_id = s.instance_id AND f.setting = s.problem || ' index'
                                      AND f.value = s.datname || ': ' || coalesce(s.schema_name || '.', '') || coalesce(s.index_name, s.indexrelid::text)
   WHERE s.instance_id = p_instance_id AND s.dbid = p_dbid AND s.indexrelid = p_indexrelid
   ORDER BY s.is_present DESC, CASE s.problem WHEN 'invalid' THEN 0 WHEN 'duplicate' THEN 1 WHEN 'redundant' THEN 2 ELSE 3 END
$$;

-- one database's size per b-second bucket (the database page's chart)
CREATE OR REPLACE FUNCTION pgvigil.drill_db_series(p_instance_id int, p_dbid bigint, p_from timestamptz, p_to timestamptz, p_bucket int)
RETURNS TABLE (snapshot_at timestamptz, size_bytes bigint, xid_age bigint)
LANGUAGE sql STABLE AS $$
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / greatest(p_bucket, 60)) * greatest(p_bucket, 60)), max(s.size_bytes), max(s.xid_age)
    FROM pgvigil.database_sizes s
   WHERE s.instance_id = p_instance_id AND s.dbid = p_dbid AND s.snapshot_at > p_from AND s.snapshot_at <= p_to
   GROUP BY 1 ORDER BY 1
$$;
