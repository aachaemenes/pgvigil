-- 0008_roles: the repository's access contract.
--   pgvigil_collector  may EXECUTE the import functions, ensure_instance and log_collection and
--                      nothing else: it cannot read what other instances sent, cannot migrate.
--   pgvigil_reader     may SELECT every table and view and EXECUTE the read functions (the UI,
--                      Grafana, an MCP server).
-- The import functions run as their owner (SECURITY DEFINER) with a fixed search_path, so the
-- collector role needs no table privilege. pgvigil.apply_roles() (re)applies the contract to
-- every function and table in the schema; `pgvigil migrate` calls it after each run, so a
-- collection added by a later migration is covered without a new grant.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN
    CREATE ROLE pgvigil_collector NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_reader') THEN
    CREATE ROLE pgvigil_reader NOLOGIN;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.apply_roles()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  f record;
  t record;
BEGIN
  REVOKE ALL ON SCHEMA pgvigil FROM PUBLIC;
  GRANT USAGE ON SCHEMA pgvigil TO pgvigil_collector, pgvigil_reader;

  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgvigil'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF f.proname LIKE 'import\_%' OR f.proname IN ('ensure_instance', 'log_collection') THEN
      -- the collector's door: runs as the owner, sees only its arguments
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_collector', f.sig);
    ELSIF f.proname IN ('apply_roles', 'purge', 'ensure_month_partition') THEN
      NULL;  -- owner only
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_reader', f.sig);
    END IF;
  END LOOP;

  FOR t IN
    SELECT c.oid::regclass AS rel
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p', 'v')
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, pgvigil_collector', t.rel);
    EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t.rel);
  END LOOP;
END $$;

SELECT pgvigil.apply_roles();
