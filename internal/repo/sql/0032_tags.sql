-- 0032_tags: tags as key:value pairs, and a repository-side override per instance and key.
--   instances.tags keeps the config's list as written (ensure_instance writes it on every collection): plain
--   words (prod) and key:value pairs (env:prod). A plain word is the key 'tag'; the first ':' splits a pair;
--   the key is lower-cased and both parts trimmed (config.ParseTag splits the same way).
--   instance_tag_overrides is written by 'pgvigil tag' as the repository owner: a row replaces every value the
--   config gives its key (vals), or hides the key (vals NULL); deleting the row brings the config's values back.
--   A config deploy never touches it.
--   instance_tag_pairs is the merged list (instance_id, key, value, source config | override);
--   instance_tags_merged the same as one text[] per instance in the written form (the value alone for the key
--   'tag', else key:value), sorted: the instances view the UI reads takes its tags column from here, so the tree's
--   folders and the pages' tag scope (tag=prod, tag=env:prod) keep their shape.

CREATE TABLE pgvigil.instance_tag_overrides (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  key          text NOT NULL CHECK (key ~ '^[a-z0-9_.-]{1,40}$'),
  vals         text[] CHECK (vals IS NULL OR (cardinality(vals) BETWEEN 1 AND 20 AND array_position(vals, NULL) IS NULL AND '' <> ALL (vals))),
  set_at       timestamptz NOT NULL DEFAULT now(),
  set_by       text NOT NULL DEFAULT current_user,
  PRIMARY KEY (instance_id, key)
);
COMMENT ON TABLE pgvigil.instance_tag_overrides IS 'pgvigil tag: a key''s values replaced (vals) or the key hidden (vals NULL) over the config''s tags.';

-- one written tag as (key, value); NULL key for an empty or malformed one
CREATE FUNCTION pgvigil.tag_split(p_tag text)
RETURNS TABLE (key text, value text) LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN strpos(t, ':') > 0 THEN lower(btrim(left(t, strpos(t, ':') - 1), E' \t\r\n')) ELSE 'tag' END,
         CASE WHEN strpos(t, ':') > 0 THEN btrim(substr(t, strpos(t, ':') + 1), E' \t\r\n') ELSE t END
    FROM (SELECT btrim(p_tag, E' \t\r\n') AS t) x
   WHERE btrim(coalesce(p_tag, ''), E' \t\r\n') <> ''
$$;

CREATE VIEW pgvigil.instance_tag_pairs AS
SELECT i.instance_id, p.key, p.value, 'config'::text AS source
  FROM pgvigil.instances i
  CROSS JOIN LATERAL unnest(i.tags) AS u(t)
  CROSS JOIN LATERAL pgvigil.tag_split(u.t) AS p
 WHERE p.key <> '' AND p.value <> ''
   AND NOT EXISTS (SELECT 1 FROM pgvigil.instance_tag_overrides o WHERE o.instance_id = i.instance_id AND o.key = p.key)
UNION ALL
SELECT o.instance_id, o.key, v.value, 'override'
  FROM pgvigil.instance_tag_overrides o
  CROSS JOIN LATERAL unnest(o.vals) AS v(value)
 WHERE o.vals IS NOT NULL AND v.value <> '';

CREATE VIEW pgvigil.instance_tags_merged AS
SELECT i.instance_id,
       coalesce((SELECT array_agg(DISTINCT CASE WHEN p.key = 'tag' THEN p.value ELSE p.key || ':' || p.value END
                                  ORDER BY CASE WHEN p.key = 'tag' THEN p.value ELSE p.key || ':' || p.value END)
                   FROM pgvigil.instance_tag_pairs p WHERE p.instance_id = i.instance_id), '{}'::text[]) AS tags,
       EXISTS (SELECT 1 FROM pgvigil.instance_tag_overrides o WHERE o.instance_id = i.instance_id) AS has_override
  FROM pgvigil.instances i;
