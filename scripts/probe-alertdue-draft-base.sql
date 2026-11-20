-- DRAFT of the release migration's re-created objects with B24h's lines 1, 2 and 7 (scripts/probe-joined-objects.sql) in
-- them, built from 0121 L657-664 / L702-707 and 0190 L456-465 when drafted - a proof of the lines only, never a migration
-- (scripts/ is not embedded): TestProbeAlertDueDraftOnAStore applies it inside its own transaction, rolled back. With it
-- alone alert_due is 0190's (the red run); scripts/probe-alertdue-draft.sql adds line 3 (the green run).

-- line 2: the probe's three per-instance settings are held under 'collector or network' as the collector's own kinds
CREATE OR REPLACE FUNCTION pgvigil.collector_shared_cause(p_source text, p_setting text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce((p_source = 'pgvigil collector' AND p_setting IN ('authentication failing', 'collection failing', 'server unreachable', 'slow connect',
                                                                    'query round trip slow', 'ping slow', 'host not answering ping'))
      OR (p_source = 'collector' AND p_setting = 'server unreachable')   -- 0118's (task 177 D30), where no heartbeat covers the instance
      OR (p_source = 'pgvigil' AND p_setting IN ('job run over twice its average', 'job schedule missed'))
      OR (p_source = 'mssql_jobs' AND p_setting = 'a job runs far longer than its average')
      OR (p_source = 'pg-backups' AND p_setting LIKE 'amcheck older than %')
      OR (p_source = 'pgvigil indexes' AND p_setting = 'unused index'), false)
$$;

-- line 7: the host-valued probe rows keep their host whole in the key
CREATE OR REPLACE FUNCTION pgvigil.alert_key(p_instance_id int, p_source text, p_setting text, p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_instance_id IS NULL AND p_source = 'pgvigil repository'
                   AND p_setting IN ('collector or network', 'slow connects', 'collections run long', 'ping slow', 'host not answering ping',
                                     'network slow from this collector')
              THEN md5('0' || E'\x1f' || p_source || E'\x1f' || p_setting || E'\x1f' || coalesce(p_value, ''))
              ELSE pgvigil.alert_finding_key(coalesce(p_instance_id, 0), p_source, p_setting, p_value) END
$$;

-- line 1's effect on alert_due: the probe findings reach alert_findings (0300 puts the arm in pgvigil.findings, which
-- alert_findings reads; findings' DISTINCT ON over its arms leaves a probe row, unique by its setting, as it is)
CREATE OR REPLACE VIEW pgvigil.alert_findings AS
SELECT pgvigil.alert_key(f.instance_id, f.source, f.setting, f.value) AS finding_key,
       f.instance_id, coalesce(i.name, 'pgvigil') AS instance, coalesce(t.tags, '{}'::text[]) AS tags,
       f.severity, f.setting, f.value, f.suggested, f.detail, f.source, f.at
  FROM (SELECT x.instance_id, x.severity, x.setting, x.value, x.suggested, x.detail, x.source, x.at FROM pgvigil.findings x
        UNION ALL
        SELECT y.instance_id, y.severity, y.setting, y.value, y.suggested, y.detail, y.source, y.at FROM pgvigil.alert_rule_findings y
        UNION ALL
        SELECT z.instance_id, z.severity, z.setting, z.value, z.suggested, z.detail, z.source, z.at FROM pgvigil.collector_probe_findings z) f
  LEFT JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
 WHERE i.is_active OR f.source = 'pgvigil repository';
