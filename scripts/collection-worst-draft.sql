-- B6G-N's DRAFT (never a migration; scripts/ is not embedded): 0085's alert_rule_findings with the worst-collection
-- line 1 in it - the green run of TestCollectionWorstOnAStore (PGVIGIL_COLLECTION_WORST_DRAFT=scripts/collection-worst-draft.sql).
-- The release migration (0300) re-creates the view whole with the line; this file is what that view reads like until
-- then.
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
         -- B6G-N: a Collection-family rule naming no collection names the worst
         -- collection of its newest hour (the detail is outside alert_finding_key: one alert as the worst passes)
         || CASE WHEN c.family = 'collection' AND s.database = '' AND s.sample_at IS NOT NULL
                 THEN coalesce('; the worst collection of its newest hour: ' || pgvigil.collection_worst(s.instance_id, c.metric, s.sample_at), '')
                 ELSE '' END
         || CASE WHEN s.held THEN '; no fresh sample since ' || to_char(s.sample_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: the alert is held' ELSE '' END AS detail,
       'alert rule'::text AS source, coalesce(s.sample_at, s.evaluated_at) AS at
  FROM pgvigil.alert_rule_state s
  JOIN pgvigil.alert_rules r ON r.rule_id = s.rule_id
  JOIN pgvigil.metric_catalog c ON c.key = s.metric
 WHERE s.state IN ('warning', 'critical');
