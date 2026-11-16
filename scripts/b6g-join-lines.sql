-- B6G-N's lines for the joined objects (join-file rule B6G-N): 0166 creates B6g's own
-- objects (collection_metric_values, collection_worst); the next join (0300_join_release3.sql) re-creates each object
-- below WHOLE with these lines in it. Not a migration: never applied by `pgvigil migrate` (scripts/ is not embedded).

-- 1. pgvigil.alert_rule_findings (0085's view; no later file redefines it): its detail, after the 'since ... UTC' part and
--    before the held part, names the worst collection of the newest hour for a Collection-family rule that names no
--    collection - proven on scripts/b6g-join-draft-arf.sql (that view with this line) by TestCollectionWorstOnAStore;
--    scripts/b6g-join-draft-arf-base.sql is 0085's view as it is (the red run):
--         || CASE WHEN c.family = 'collection' AND s.database = '' AND s.sample_at IS NOT NULL
--                 THEN coalesce('; the worst collection of its newest hour: ' || pgvigil.collection_worst(s.instance_id, c.metric, s.sample_at), '')
--                 ELSE '' END
--    Its words land with it: docs/alerts.md ('One collection') and the rule dialog's help (web/src/alert_rules.ts) say
--    the detail names the worst collection of the newest hour - rel-b6gn joins in the same join that writes the line.

-- AT THE JOIN: TestCollectionWorstOnAStore reads a store holding a schema_version row of '0300' or later as migrated (no
-- draft) - so the join file is 0300_..., or the test's '0300' (internal/web/collection_worst_store_test.go) changes with it;
-- after the join the test runs in the store suite with PGVIGIL_B6G_DRAFT unset and goes red if this line is left out.
