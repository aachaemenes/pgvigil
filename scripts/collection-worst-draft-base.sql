-- B6G-N's DRAFT, BASE (never a migration; scripts/ is not embedded): 0085's alert_rule_findings exactly as 0085 has it -
-- the red run of TestCollectionWorstOnAStore (PGVIGIL_COLLECTION_WORST_DRAFT=scripts/collection-worst-draft-base.sql). 0300
-- re-creates the view whole with the worst-collection line in it; scripts/collection-worst-draft.sql is that view.
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
