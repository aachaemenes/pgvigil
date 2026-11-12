-- 0113 (task 176b): DBA Dash's defaults and one uptime threshold for both engines.
--   drives_now   the default drive threshold is DBA Dash's: warning under 20 % free, critical under 10 % (0111 kept the
--                rule both engines had before it, 10 / 5); a drive, an instance, a tag or the root still overrides. The
--                check names stay ('disk free under 10 %', 'a volume under 10 % free': alert rules and acknowledgements
--                match them); each finding's detail names the threshold in force.
--   import_pg_threshold  the 'uptime' key is set at a SQL Server instance too (the Summary's Uptime dialog serves both
--                engines; the SQL Server summary reads pg_threshold(instance, 'uptime')); every other key stays
--                PostgreSQL's. The rest of the function is 0103's.

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
            SELECT 20::numeric, 10::numeric, 'default', NULL, NULL, 9) x
     ORDER BY x.rank, x.tag NULLS LAST
     LIMIT 1) t;


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
                                                  AND (i.engine = 'postgres' OR (v_key = 'uptime' AND v_level = 'instance')))) THEN
    -- the uptime key is both engines' (DBA Dash's Instance Uptime dialog, task 176b): a SQL Server instance takes it
    v_why := format(CASE WHEN v_key = 'uptime' THEN 'no instance %s' ELSE 'no PostgreSQL instance %s' END, coalesce(p_payload->>'instance_id', '(none)'));
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
      IF v_warn IS NULL AND v_crit IS NULL THEN
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
