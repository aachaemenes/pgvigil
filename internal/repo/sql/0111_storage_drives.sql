-- 0111 the Storage folder's Drives on both engines (task 176; DBA Dash's Storage > Drives, Drives/DrivesView.cs): one
-- row per drive of every instance, judged by a free-space threshold that a DBA sets at the root, a tag, an instance or
-- one drive, as DBA Dash's Configure does.
--   drive_thresholds      the thresholds (per cent free: warning and critical); a change ends the live row and writes
--                         its successor, so the history of who set what stays (import_drive_threshold only).
--   drives_now            every present drive of every active instance: a PostgreSQL host's volumes (host_disks: the
--                         system_stats or CloudWatch read) and a SQL Server's volumes (mssql_volumes), with the threshold
--                         in force (the drive's own, else the instance's, a tag's, the root's, else the default:
--                         warning under 10 % free, critical under 5 %, the rule both engines judged by before 0111) and
--                         the status that threshold gives.
--   host_checks           its disk branch reads drives_now: the Summary's Disk column and the Drives page judge alike.
--   mssql_storage_findings  its volume branch reads drives_now the same way.
-- The check names stay ('disk free under 10 %', 'a volume under 10 % free': alert rules, acknowledgements and the
-- proofs key on them); the detail names the threshold in force and where it was set.

CREATE TABLE IF NOT EXISTS pgvigil.drive_thresholds (
  threshold_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  level         text NOT NULL CHECK (level IN ('root', 'tag', 'instance', 'drive')),
  instance_id   int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tag           text CHECK (length(tag) BETWEEN 1 AND 200),
  drive         text CHECK (length(drive) BETWEEN 1 AND 400),
  warn_pct      numeric NOT NULL CHECK (warn_pct BETWEEN 0 AND 100),
  crit_pct      numeric NOT NULL CHECK (crit_pct BETWEEN 0 AND 100),
  created_by    text NOT NULL,
  created_at    timestamptz NOT NULL,
  client        text,
  replaces      bigint,
  ended_by      text,
  ended_at      timestamptz,
  CONSTRAINT "critical at or under warning" CHECK (crit_pct <= warn_pct),
  CONSTRAINT "the root level names nothing" CHECK (level <> 'root' OR (instance_id IS NULL AND tag IS NULL AND drive IS NULL)),
  CONSTRAINT "a tag level names its tag only" CHECK (level <> 'tag' OR (tag IS NOT NULL AND instance_id IS NULL AND drive IS NULL)),
  CONSTRAINT "an instance level names its instance only" CHECK (level <> 'instance' OR (instance_id IS NOT NULL AND tag IS NULL AND drive IS NULL)),
  CONSTRAINT "a drive level names its instance and drive" CHECK (level <> 'drive' OR (instance_id IS NOT NULL AND drive IS NOT NULL AND tag IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS drive_thresholds_live_idx
  ON pgvigil.drive_thresholds (level, coalesce(instance_id, 0), coalesce(tag, ''), coalesce(drive, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.drive_thresholds IS 'Drive free-space thresholds (per cent free) at the root, tag, instance and drive level; written through import_drive_threshold only, a change ends the row and writes its successor.';

-- import_drive_threshold: one attempt from the UI's Configure. p_payload: {op: set | inherit, level, instance_id, tag,
-- drive, warn, crit, ui_user, client}; set takes both numbers (per cent free, 0-100, critical at or under warning).
-- Answers {outcome: done | refused, detail, threshold_id}; a refusal writes nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_drive_threshold(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_level text := p_payload->>'level';
  v_inst  int;
  v_tag   text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_drive text := nullif(p_payload->>'drive', '');
  v_ws    text := p_payload->>'warn';
  v_cs    text := p_payload->>'crit';
  v_warn  numeric;
  v_crit  numeric;
  v_why   text;
  v_old   bigint;
  v_new   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_drive_threshold: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_level IS NULL OR v_level NOT IN ('root', 'tag', 'instance', 'drive') THEN
    v_why := 'level must be root, tag, instance or drive';
  ELSIF v_level IN ('instance', 'drive') AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst)) THEN
    v_why := 'an instance or drive level names an instance that exists';
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_level = 'drive' AND (v_drive IS NULL OR length(v_drive) > 400) THEN
    v_why := 'a drive level names its drive (400 characters at most)';
  ELSIF v_op = 'set' THEN
    IF v_ws IS NULL OR v_cs IS NULL OR v_ws !~ '^[0-9]{1,3}(\.[0-9]{1,2})?$' OR v_cs !~ '^[0-9]{1,3}(\.[0-9]{1,2})?$' THEN
      v_why := 'warn and crit must both be a per cent free from 0 to 100';
    ELSE
      v_warn := v_ws::numeric; v_crit := v_cs::numeric;
      IF v_warn > 100 OR v_crit > 100 THEN
        v_why := 'warn and crit must both be a per cent free from 0 to 100';
      ELSIF v_crit > v_warn THEN
        v_why := format('critical (%s %%) must be at or under warning (%s %%): free space falls toward it', v_crit, v_warn);
      END IF;
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_tag := NULL; v_drive := NULL;
  ELSIF v_level = 'tag' THEN v_inst := NULL; v_drive := NULL;
  ELSIF v_level = 'instance' THEN v_tag := NULL; v_drive := NULL;
  ELSE v_tag := NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.drive_thresholds'), hashtext(v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_tag, '') || '|' || coalesce(v_drive, '')));
  SELECT t.threshold_id INTO v_old FROM pgvigil.drive_thresholds t
   WHERE t.ended_at IS NULL AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0)
     AND coalesce(t.tag, '') = coalesce(v_tag, '') AND coalesce(t.drive, '') = coalesce(v_drive, '');
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no threshold of its own: it inherits already');
  END IF;
  UPDATE pgvigil.drive_thresholds SET ended_by = v_user, ended_at = p_at WHERE threshold_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'threshold_id', v_old);
  END IF;
  INSERT INTO pgvigil.drive_thresholds (level, instance_id, tag, drive, warn_pct, crit_pct, created_by, created_at, client, replaces)
  VALUES (v_level, v_inst, v_tag, v_drive, v_warn, v_crit, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING threshold_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'threshold_id', v_new);
END $$;

-- drives_now: every present drive of every active instance with the threshold in force and its status, judged as each
-- engine's rule judged before 0111: a PostgreSQL drive on its per cent free rounded to 0.1 (disk_report's free_pct), a
-- SQL Server volume on the exact ratio (0067). The threshold:
-- the drive's own, else the instance's, else a tag's (the first tag by name when two of the instance's tags set one),
-- else the root's, else the default (10 / 5). status: critical under crit_pct % free, warning under warn_pct, ok, or
-- unknown where the size is not read (Aurora's local storage: no total).
CREATE OR REPLACE VIEW pgvigil.drives_now AS
WITH d AS (
  SELECT h.instance_id, h.mount_point AS drive, nullif(concat_ws(' ', h.device, h.fs_type), '') AS label, h.source,
         h.total_bytes, h.used_bytes, h.free_bytes, h.holds_data, NULL::int AS files, h.snapshot_at
    FROM pgvigil.host_disks h
   WHERE h.is_present
  UNION ALL
  SELECT v.instance_id, v.volume, nullif(concat_ws(' ', v.logical_name, v.file_system), ''), 'dm_os_volume_stats',
         v.total_bytes, v.total_bytes - v.free_bytes, v.free_bytes, NULL::boolean, v.files, v.snapshot_at
    FROM pgvigil.mssql_volumes v
   WHERE v.is_present
)
SELECT d.instance_id, i.name AS instance, i.engine, i.platform, d.drive, d.label, d.source, d.total_bytes, d.used_bytes, d.free_bytes,
       round(100.0 * d.free_bytes / nullif(d.total_bytes, 0), 1) AS free_pct, d.holds_data, d.files, d.snapshot_at,
       t.warn_pct, t.crit_pct, t.level AS threshold_level, t.tag AS threshold_tag, t.threshold_id,
       CASE WHEN d.total_bytes IS NULL OR d.total_bytes <= 0 OR d.free_bytes IS NULL THEN 'unknown'
            WHEN CASE WHEN i.engine = 'sqlserver' THEN 100.0 * d.free_bytes / d.total_bytes ELSE round(100.0 * d.free_bytes / d.total_bytes, 1) END < t.crit_pct THEN 'critical'
            WHEN CASE WHEN i.engine = 'sqlserver' THEN 100.0 * d.free_bytes / d.total_bytes ELSE round(100.0 * d.free_bytes / d.total_bytes, 1) END < t.warn_pct THEN 'warning'
            ELSE 'ok' END AS status
  FROM d
  JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
  CROSS JOIN LATERAL (
    SELECT x.warn_pct, x.crit_pct, x.level, x.tag, x.threshold_id
      FROM (SELECT th.warn_pct, th.crit_pct, th.level, th.tag, th.threshold_id,
                   CASE th.level WHEN 'drive' THEN 1 WHEN 'instance' THEN 2 WHEN 'tag' THEN 3 ELSE 4 END AS rank
              FROM pgvigil.drive_thresholds th
             WHERE th.ended_at IS NULL
               AND (th.level = 'root'
                    OR (th.level = 'instance' AND th.instance_id = d.instance_id)
                    OR (th.level = 'drive' AND th.instance_id = d.instance_id AND th.drive = d.drive)
                    OR (th.level = 'tag' AND th.tag = ANY (coalesce((SELECT m.tags FROM pgvigil.instance_tags_merged m WHERE m.instance_id = d.instance_id), '{}'::text[]))))
            UNION ALL
            SELECT 10::numeric, 5::numeric, 'default', NULL, NULL, 9) x
     ORDER BY x.rank, x.tag NULLS LAST
     LIMIT 1) t;

-- host_checks: the disk branch from drives_now (PostgreSQL instances; read in the last hour as before); the swap and
-- CPU branches as 0021 wrote them.
CREATE OR REPLACE VIEW pgvigil.host_checks AS
SELECT d.instance_id, d.status AS severity, 'disk free under 10 %' AS check_name,
       d.drive AS object, d.snapshot_at AS at,
       d.free_pct::text || ' % free: ' || pg_size_pretty(d.free_bytes) || ' of ' || pg_size_pretty(d.total_bytes)
       || CASE WHEN d.holds_data THEN ' (holds the data directory)' ELSE '' END
       || format('; warning under %s %%, critical under %s %% (%s)', d.warn_pct, d.crit_pct,
                 CASE d.threshold_level WHEN 'default' THEN 'the default' WHEN 'tag' THEN 'set on the tag ' || d.threshold_tag ELSE 'set on the ' || d.threshold_level END) AS detail,
       'disk' AS check_group
  FROM pgvigil.drives_now d
 WHERE d.engine = 'postgres' AND d.status IN ('warning', 'critical') AND d.snapshot_at > now() - interval '1 hour'
UNION ALL
SELECT l.instance_id, 'warning', 'swap used', coalesce(l.host_name, l.aws_resource, l.source), l.snapshot_at,
       pg_size_pretty(l.swap_used) || ' of swap in use' || coalesce(' (of ' || pg_size_pretty(nullif(l.swap_total, 0)) || ')', ''),
       'host'
  FROM pgvigil.host_latest l
 WHERE l.snapshot_at > now() - interval '15 minutes'
   AND CASE WHEN l.source = 'cloudwatch' THEN l.swap_used > 1024 * 1024 * 1024
            ELSE l.swap_used > 0.05 * nullif(l.swap_total, 0) AND l.swap_used > 256 * 1024 * 1024 END
UNION ALL
SELECT s.instance_id, CASE WHEN c.min_cpu >= 98 THEN 'critical' ELSE 'warning' END, 'CPU over 90 % for 10 minutes',
       coalesce(s.host_name, s.aws_resource, s.source), c.last_at,
       'lowest ' || round(c.min_cpu::numeric, 1)::text || ' %, average ' || round(c.avg_cpu::numeric, 1)::text || ' % over '
       || c.n::text || ' samples',
       'host'
  FROM pgvigil.host_state s
  CROSS JOIN LATERAL (
        -- per instance, so the partitions' (instance_id, snapshot_at) index drives it
        SELECT s.instance_id, min(h.cpu_pct) AS min_cpu, avg(h.cpu_pct) AS avg_cpu,
               count(DISTINCT coalesce(h.metrics_at, h.snapshot_at)) AS n,
               max(coalesce(h.metrics_at, h.snapshot_at)) AS last_at, min(coalesce(h.metrics_at, h.snapshot_at)) AS first_at
          FROM pgvigil.host_sample h
         WHERE h.instance_id = s.instance_id AND h.snapshot_at > now() - interval '10 minutes' AND h.cpu_pct IS NOT NULL) c
 WHERE c.min_cpu > 90 AND c.n >= 5 AND c.last_at - c.first_at >= interval '8 minutes';

-- mssql_storage_findings: the volume branch from drives_now (SQL Server instances; read in the last three hours as
-- before); every other branch as 0067 wrote it.
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
   AND f.size_bytes + CASE WHEN f.growth_pct > 0 THEN f.size_bytes * f.growth_pct / 100 ELSE f.growth_bytes END >= f.max_size_bytes
   AND f.snapshot_at > now() - interval '3 hours'
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
                    WHERE f.instance_id = p.instance_id AND f.database_name = p.database_name AND f.is_present AND f.type_desc = 'ROWS'), 0));
