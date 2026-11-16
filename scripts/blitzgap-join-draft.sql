-- DRAFT of the join's re-created objects with BLITZ-GAP's lines (scripts/blitzgap-join-lines.sql) in them, built from
-- 0145 L318-407 at 46a9c3c8 - a proof of the lines only, never a migration (scripts/ is not embedded): proof-mssql-storage.sh
-- applies it to its own throwaway repository when the joined view does not hold line 1 yet.

-- line 1
CREATE OR REPLACE VIEW pgvigil.mssql_storage_findings AS
SELECT d.instance_id, d.status AS severity,
       'a volume under 10 % free'::text AS check_name, d.drive AS object, d.snapshot_at AS at,
       format('%s free of %s (%s %%); %s database file(s) sit on it; warning under %s %%, critical under %s %% (%s)',
              pg_size_pretty(d.free_bytes), pg_size_pretty(d.total_bytes), d.free_pct, d.files, d.warn_pct, d.crit_pct,
              CASE d.threshold_level WHEN 'default' THEN 'the default' WHEN 'tag' THEN 'set on the tag ' || d.threshold_tag ELSE 'set on the ' || d.threshold_level END) AS detail
  FROM pgvigil.drives_now d
 WHERE d.engine = 'sqlserver' AND d.status IN ('warning', 'critical') AND d.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT f.instance_id, CASE WHEN f.size_bytes >= f.max_size_bytes THEN 'critical' ELSE 'warning' END,
       CASE WHEN f.size_bytes >= f.max_size_bytes THEN 'a file at its max size' ELSE 'a file within one growth of its max size' END,
       f.database_name || ': ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s (%s) is %s of a maximum of %s; its growth step is %s%s', coalesce(f.physical_name, f.file_name), lower(coalesce(f.type_desc, 'file')),
              pg_size_pretty(f.size_bytes), pg_size_pretty(f.max_size_bytes),
              CASE WHEN f.growth_pct > 0 THEN f.growth_pct || ' %' ELSE pg_size_pretty(f.growth_bytes) END,
              CASE WHEN f.used_read THEN format('; %s used inside it', pg_size_pretty(f.used_bytes)) ELSE '; the space used inside it was not read' END)
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.max_size_bytes IS NOT NULL AND f.size_bytes IS NOT NULL
   AND (coalesce(f.growth_bytes, 0) > 0 OR coalesce(f.growth_pct, 0) > 0)       -- a file set not to grow has no maximum to reach
   AND NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = f.instance_id AND i.platform = 'azuresqldb')  -- B2a: the arm below
   AND f.size_bytes + CASE WHEN f.growth_pct > 0 THEN f.size_bytes * f.growth_pct / 100 ELSE f.growth_bytes END >= f.max_size_bytes
   AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
-- B2a: on Azure SQL Database, DBA Dash's '% Max Size' (AzureDBInfo L19, L27-31): the PRIMARY filegroup's data files'
-- allocated size against their summed max size, no status when a file is unlimited; over 0.9 critical, over 0.8
-- warning (a strict 'over'; DBA Dash's root DBFileThresholds, PctMaxSize 0.8 / 0.9); the used share beside it
SELECT a.instance_id, CASE WHEN a.pct > 90 THEN 'critical' ELSE 'warning' END,
       'the database allocated over 80 % of its max size', a.database_name, a.at,
       format('the data files hold %s allocated of a max size of %s (%s %%), %s used inside them (%s %%); warning over 80 %%, critical over 90 %% (DBA Dash''s %% Max Size)',
              pg_size_pretty(a.alloc), pg_size_pretty(a.maxsize), round(a.pct, 1),
              CASE WHEN a.used IS NULL THEN 'the space' ELSE pg_size_pretty(a.used) END,
              CASE WHEN a.used IS NULL THEN 'not read' ELSE round(100.0 * a.used / a.maxsize, 1)::text END)
  FROM (SELECT f.instance_id, f.database_name, max(f.snapshot_at) AS at, sum(f.size_bytes) AS alloc, sum(f.max_size_bytes) AS maxsize,
               CASE WHEN bool_and(f.used_read) THEN sum(f.used_bytes) END AS used,
               100.0 * sum(f.size_bytes) / nullif(sum(f.max_size_bytes), 0) AS pct
          FROM pgvigil.mssql_files f JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.platform = 'azuresqldb'
         WHERE f.is_present AND f.type_desc = 'ROWS' AND f.filegroup = 'PRIMARY' AND f.snapshot_at > now() - interval '3 hours'
         GROUP BY f.instance_id, f.database_name
        HAVING bool_and(f.max_size_bytes IS NOT NULL)) a
 WHERE a.pct > 80
UNION ALL
SELECT f.instance_id, 'info', 'a percentage growth on a file over 10 GB', f.database_name || ': ' || coalesce(f.file_name, f.file_id::text), f.snapshot_at,
       format('%s (%s) is %s and grows by %s %%: its next growth is %s in one step', coalesce(f.physical_name, f.file_name),
              lower(coalesce(f.type_desc, 'file')), pg_size_pretty(f.size_bytes), f.growth_pct, pg_size_pretty(f.size_bytes * f.growth_pct / 100))
  FROM pgvigil.mssql_files f
 WHERE f.is_present AND f.growth_pct > 0 AND f.size_bytes > 10 * 1024::bigint * 1024 * 1024
   AND f.snapshot_at > now() - interval '3 hours'
UNION ALL
SELECT d.instance_id, 'info', 'a log file larger than its data files', d.database_name, d.at,
       format('the log files hold %s, the data files %s', pg_size_pretty(d.log_bytes), pg_size_pretty(d.data_bytes))
  FROM (SELECT f.instance_id, f.database_name, max(f.snapshot_at) AS at,
               coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'), 0) AS log_bytes,
               coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'ROWS'), 0) AS data_bytes
          FROM pgvigil.mssql_files f
         WHERE f.is_present AND f.snapshot_at > now() - interval '3 hours'
         GROUP BY f.instance_id, f.database_name) d
 WHERE d.log_bytes > d.data_bytes AND d.log_bytes >= 1024::bigint * 1024 * 1024
UNION ALL
SELECT l.instance_id, 'warning', 'the version store grows while cleanup is at zero', 'tempdb', l.snapshot_at,
       format('the version store grew from %s to %s in the ten minutes to this read and cleanup removed nothing in %s reads; ',
              pg_size_pretty(l.first_reserved_bytes), pg_size_pretty(l.reserved_bytes), l.reads_10m)
       || CASE WHEN l.holder_session_id IS NULL THEN 'no active snapshot transaction was found at the read (holder unknown: the oldest open transaction of any kind is the next read)'
               ELSE format('held by session %s (%s, %s), its transaction open for %s s since %s; last statement: %s', l.holder_session_id,
                           coalesce(l.holder_login, 'login not read'), coalesce(l.holder_program, 'program not read'), l.holder_elapsed_s,
                           to_char(l.holder_started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'), coalesce(left(l.holder_statement, 2000), 'not read')) END
  FROM pgvigil.mssql_versionstore_latest l
 WHERE l.snapshot_at > now() - interval '15 minutes'
   AND l.reads_10m >= 8 AND l.cleanup_zero_10m AND l.generated_10m
   AND l.first_at <= l.snapshot_at - interval '9 minutes 30 seconds' AND l.reserved_bytes > l.first_reserved_bytes
UNION ALL
SELECT l.instance_id, 'warning', 'the version store over a third of tempdb', 'tempdb', l.snapshot_at,
       format('the version store holds %s of tempdb''s %s of data files (%s %%)', pg_size_pretty(l.reserved_bytes), pg_size_pretty(l.tempdb_data_bytes),
              round(100.0 * l.reserved_bytes / l.tempdb_data_bytes, 1))
       || CASE WHEN l.holder_session_id IS NULL THEN ''
               ELSE format('; the oldest snapshot transaction is session %s (%s, %s), open for %s s; last statement: %s', l.holder_session_id,
                           coalesce(l.holder_login, 'login not read'), coalesce(l.holder_program, 'program not read'), l.holder_elapsed_s,
                           coalesce(left(l.holder_statement, 2000), 'not read')) END
  FROM pgvigil.mssql_versionstore_latest l
 WHERE l.snapshot_at > now() - interval '15 minutes' AND l.tempdb_data_bytes > 0 AND l.reserved_bytes * 3 > l.tempdb_data_bytes
UNION ALL
SELECT p.instance_id, 'warning', 'the persistent version store over its threshold with aborted transactions', p.database_name, p.snapshot_at,
       format('the persistent version store holds %s with %s aborted transaction(s) not yet cleaned', pg_size_pretty(p.pvs_bytes), p.aborted_tx_count)
       || CASE WHEN p.oldest_tx_session_id IS NULL THEN ''
               ELSE format('; the oldest active transaction is session %s, open since %s', p.oldest_tx_session_id,
                           to_char(p.oldest_tx_started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"')) END
  FROM pgvigil.mssql_pvs p
 WHERE p.snapshot_at > now() - interval '15 minutes' AND p.aborted_tx_count > 0
   AND p.pvs_bytes > greatest(1024::bigint * 1024 * 1024,
         coalesce((SELECT sum(f.size_bytes) / 10 FROM pgvigil.mssql_files f
                    WHERE f.instance_id = p.instance_id AND f.database_name = p.database_name AND f.is_present AND f.type_desc = 'ROWS'), 0))
UNION ALL   -- line 1 of scripts/blitzgap-join-lines.sql
SELECT instance_id, severity, check_name, object, at, detail FROM pgvigil.mssql_file_place_findings;
