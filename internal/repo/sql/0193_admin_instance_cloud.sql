-- 0193_admin_instance_cloud: the aws: and azure: blocks of an instance added in Admin > Instances or approved from
-- discovery (task B24p). A page instance carried no cloud block,
-- so none of its cloud reads ran: CloudWatch IO / logs / Performance Insights / serverless (aws:), and 390a's
-- failover groups (azure:).
--
-- The blocks sit in a table of their own beside the page's row: import_admin_instance is not
-- redefined again; a remove deletes the row and the blocks go with it (ON DELETE CASCADE). Their shape is the
-- configuration file's minus log_group and dms (those stay pgvigil.yaml's): aws {region, profile, cluster,
-- db_instance} on a PostgreSQL row only (on SQL Server an aws: block is pgvigil.yaml's provider replica door
-- only, 390b, and a page block never carries replicas), azure {subscription, resource_group, server, cloud} on a SQL
-- Server row of platform azuresqldb only. Nothing secret in either: the
-- credentials are the collector host's own SDK chains. These rules are Go's own (config.PageCloudShape), so every
-- block the store takes passes the merge's shape check.
--
-- The doors: pgvigil.yaml's doors.page_cloud_blocks (OFF by default) lets the
-- collector use a page block at all, and the block's target must be the instance's own host by name; a profile only
-- when doors.page_aws_profiles lists it. Those are the configuration file's, checked by serve before it calls
-- here and by the collector at each merge (config.MergeNotes): a block the store holds may still be dropped there,
-- with its reason logged; the instance keeps collecting.
--
-- import_admin_instance_cloud(p_at, payload {op set | clear, ui_user, client, name, aws, azure, file_names}): set
-- replaces both blocks with the payload's (null = none; both null is refused: a clear is its own op); clear removes
-- them. The page row is locked first (a concurrent remove answers 'no instance', never a foreign-key error); 0157's
-- file_names refusal; one admin_audit row with the old and the new blocks; the inventory generation moves. Its answer
-- is import_admin_instance's ({outcome, detail, generation}).
--
-- import_admin_cloud_refused(p_at, payload {ui_user, client, name, detail}): the refusal's audit row when serve rolled
-- the add, edit or approve back for its block (the transaction's own row went with it); serve's audit login is the
-- collector's role, so it is an import_ function (SECURITY DEFINER through apply_roles). A set on the page keeps the
-- stored aws profile while the region stays (the page's fieldset carries none).
--
-- admin_inventory() gains the row's host (the name match) and both blocks: DROP and CREATE, SECURITY DEFINER and both
-- GRANTs, as 0157 did.
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.admin_instance_cloud (
  name        text PRIMARY KEY REFERENCES pgvigil.admin_instances (name) ON DELETE CASCADE ON UPDATE CASCADE,
  aws         jsonb CHECK (aws IS NULL OR jsonb_typeof(aws) = 'object'),
  azure       jsonb CHECK (azure IS NULL OR jsonb_typeof(azure) = 'object'),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text NOT NULL,
  CHECK (aws IS NOT NULL OR azure IS NOT NULL)
);
COMMENT ON TABLE pgvigil.admin_instance_cloud IS 'The aws: and azure: blocks of a page instance (task B24p): the configuration file''s shape minus log_group and dms; no secret.';

-- the shape of one block (the reason, or NULL when it holds): Go's config.PageCloudShape, rule for rule
CREATE OR REPLACE FUNCTION pgvigil.admin_cloud_shape(p_engine text, p_platform text, p_aws jsonb, p_azure jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_k   text;
  v_id  text;
BEGIN
  IF p_aws IS NOT NULL THEN
    IF jsonb_typeof(p_aws) <> 'object' THEN
      RETURN 'aws is an object {region, profile, cluster, db_instance}';
    END IF;
    IF p_engine <> 'postgres' THEN
      RETURN 'the aws: block is PostgreSQL''s (on SQL Server it waits for its own reads)';
    END IF;
    FOR v_k IN SELECT jsonb_object_keys(p_aws) LOOP
      IF v_k NOT IN ('region', 'profile', 'cluster', 'db_instance') THEN
        RETURN format('aws.%s is not a key of a page block (region, profile, cluster, db_instance; log_group and dms stay pgvigil.yaml''s)', v_k);
      END IF;
      IF jsonb_typeof(p_aws->v_k) <> 'string' THEN
        RETURN format('aws.%s is a string', v_k);
      END IF;
    END LOOP;
    IF coalesce(p_aws->>'region', '') !~ '^[a-z]{2}(-gov|-iso[a-z]?)?-[a-z]+-[0-9]{1,2}$' THEN
      RETURN format('aws.region %s is not an AWS region code', coalesce(p_aws->>'region', '(none)'));
    END IF;
    IF coalesce(p_aws->>'db_instance', '') = '' AND coalesce(p_aws->>'cluster', '') = '' THEN
      RETURN 'the aws: block names its db_instance or cluster';
    END IF;
    FOREACH v_id IN ARRAY ARRAY[p_aws->>'db_instance', p_aws->>'cluster'] LOOP
      IF coalesce(v_id, '') <> '' AND (v_id !~ '^[A-Za-z][A-Za-z0-9-]{0,62}$' OR v_id ~ '--' OR v_id ~ '-$') THEN
        RETURN format('%s is not an RDS identifier (a letter, then letters, digits and single hyphens, 63 at most, no trailing hyphen)', v_id);
      END IF;
    END LOOP;
    IF coalesce(p_aws->>'profile', '') <> '' AND p_aws->>'profile' !~ '^[A-Za-z0-9_.+@-]{1,64}$' THEN
      RETURN format('aws.profile %s is not a profile name', p_aws->>'profile');
    END IF;
  END IF;
  IF p_azure IS NOT NULL THEN
    IF jsonb_typeof(p_azure) <> 'object' THEN
      RETURN 'azure is an object {subscription, resource_group, server, cloud}';
    END IF;
    IF p_engine <> 'sqlserver' OR p_platform <> 'azuresqldb' THEN
      RETURN 'the azure: block is an Azure SQL Database''s (a SQL Server instance of platform azuresqldb)';
    END IF;
    FOR v_k IN SELECT jsonb_object_keys(p_azure) LOOP
      IF v_k NOT IN ('subscription', 'resource_group', 'server', 'cloud') THEN
        RETURN format('azure.%s is not a key of a page block (subscription, resource_group, server, cloud)', v_k);
      END IF;
      IF jsonb_typeof(p_azure->v_k) <> 'string' THEN
        RETURN format('azure.%s is a string', v_k);
      END IF;
    END LOOP;
    IF coalesce(p_azure->>'subscription', '') !~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' THEN
      RETURN format('azure.subscription %s is not a subscription id', coalesce(p_azure->>'subscription', '(none)'));
    END IF;
    -- ASCII, as Go's class: \w would follow the repository's collation
    IF coalesce(p_azure->>'resource_group', '') !~ '^[-A-Za-z0-9_.()]{1,90}$' OR p_azure->>'resource_group' ~ '\.$' THEN
      RETURN format('azure.resource_group %s is not a resource group name (1-90 letters, digits, . ( ) _ -, no trailing dot)', coalesce(p_azure->>'resource_group', '(none)'));
    END IF;
    IF coalesce(p_azure->>'server', '') !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' THEN
      RETURN format('azure.server %s is not a logical server''s name (1-63 lower-case letters, digits and hyphens)', coalesce(p_azure->>'server', '(none)'));
    END IF;
    IF coalesce(p_azure->>'cloud', '') NOT IN ('', 'public', 'usgov', 'china') THEN
      RETURN format('azure.cloud is public, usgov or china, not %s', p_azure->>'cloud');
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance_cloud(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_name  text := btrim(coalesce(p_payload->>'name', ''));
  v_op    text := p_payload->>'op';
  v_aws   jsonb := CASE WHEN jsonb_typeof(p_payload->'aws') IN ('object', 'array', 'string', 'number', 'boolean') THEN p_payload->'aws' END;
  v_azure jsonb := CASE WHEN jsonb_typeof(p_payload->'azure') IN ('object', 'array', 'string', 'number', 'boolean') THEN p_payload->'azure' END;
  v_have  pgvigil.admin_instances%ROWTYPE;
  v_old   pgvigil.admin_instance_cloud%ROWTYPE;
  v_why   text;
  v_gen   bigint;
  v_was   text;
  v_now   text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_instance_cloud: no ui_user' USING ERRCODE = '22023';
  END IF;
  -- the page row first, locked: a remove open in another transaction is waited for, then its answer is 'no instance'
  SELECT * INTO v_have FROM pgvigil.admin_instances WHERE name = v_name FOR UPDATE;
  SELECT * INTO v_old FROM pgvigil.admin_instance_cloud WHERE name = v_name;
  IF v_op IS NULL OR v_op NOT IN ('set', 'clear') THEN
    v_why := 'op must be set or clear';
  ELSIF jsonb_typeof(p_payload->'file_names') = 'array' AND p_payload->'file_names' ? v_name THEN
    v_why := format('%s is an instance of pgvigil.yaml: its aws: and azure: blocks are written there', v_name);
  ELSIF v_have.name IS NULL THEN
    v_why := format('no instance %s was added here', v_name);
  ELSIF v_op = 'set' AND v_aws IS NULL AND v_azure IS NULL THEN
    v_why := 'a set names its aws or azure block (removing both is the clear)';
  ELSIF v_op = 'set' THEN
    v_why := pgvigil.admin_cloud_shape(v_have.engine, v_have.platform, v_aws, v_azure);
  END IF;
  -- an edit from the page carries no profile (its Cloud fieldset has none): a stored profile (a discovered instance's
  -- source profile) is kept while the region stays; a region change drops it
  IF v_why IS NULL AND v_op = 'set' AND jsonb_typeof(v_aws) = 'object' AND NOT v_aws ? 'profile'
     AND coalesce(v_old.aws->>'profile', '') <> '' AND v_old.aws->>'region' = v_aws->>'region' THEN
    v_aws := v_aws || jsonb_build_object('profile', v_old.aws->>'profile');
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance cloud', v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  v_was := format('aws %s, azure %s', coalesce(v_old.aws::text, 'none'), coalesce(v_old.azure::text, 'none'));
  IF v_op = 'clear' THEN
    DELETE FROM pgvigil.admin_instance_cloud WHERE name = v_name;
    v_now := 'aws none, azure none';
  ELSE
    INSERT INTO pgvigil.admin_instance_cloud (name, aws, azure, updated_at, updated_by)
    VALUES (v_name, v_aws, v_azure, p_at, v_user)
    ON CONFLICT (name) DO UPDATE SET aws = EXCLUDED.aws, azure = EXCLUDED.azure, updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
    v_now := format('aws %s, azure %s', coalesce(v_aws::text, 'none'), coalesce(v_azure::text, 'none'));
  END IF;
  v_gen := pgvigil.admin_bump();
  PERFORM pgvigil.admin_log(v_user, v_cli, 'instance cloud', v_name, 'done', format('was: %s; now: %s', v_was, v_now));
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('the cloud blocks of %s: %s', v_name, v_now), 'generation', v_gen);
END $$;

-- a refusal's audit row after its transaction was rolled back: serve's audit login is IN ROLE
-- pgvigil_collector, which may neither run admin_log nor insert into admin_audit; an import_ function is SECURITY
-- DEFINER with the collector's EXECUTE (apply_roles). It writes the one row its payload names and nothing else.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_cloud_refused(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
BEGIN
  IF v_user IS NULL OR coalesce(p_payload->>'detail', '') = '' THEN
    RAISE EXCEPTION 'import_admin_cloud_refused: no ui_user or no detail' USING ERRCODE = '22023';
  END IF;
  INSERT INTO pgvigil.admin_audit (at, ui_user, client, op, target, outcome, detail)
  VALUES (coalesce(p_at, now()), v_user, left(p_payload->>'client', 100), 'instance cloud', left(p_payload->>'name', 200), 'refused', left(p_payload->>'detail', 2000));
END $$;

DROP FUNCTION IF EXISTS pgvigil.admin_inventory();
CREATE FUNCTION pgvigil.admin_inventory()
RETURNS TABLE (name text, engine text, platform text, dsn_ref text, tags text[], disabled boolean, auth text, options text, generation bigint,
               running_plans boolean, host text, aws jsonb, azure jsonb)
LANGUAGE sql STABLE AS $$
  SELECT a.name, a.engine, a.platform, a.dsn_ref, a.tags, a.disabled, a.auth, a.options, s.generation, a.running_plans,
         a.host, c.aws, c.azure
    FROM pgvigil.admin_inventory_state s
    LEFT JOIN pgvigil.admin_instances a ON true
    LEFT JOIN pgvigil.admin_instance_cloud c ON c.name = a.name
   WHERE s.one
   ORDER BY a.name
$$;
ALTER FUNCTION pgvigil.admin_inventory() SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_collector;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_reader') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_reader;
  END IF;
END $$;
