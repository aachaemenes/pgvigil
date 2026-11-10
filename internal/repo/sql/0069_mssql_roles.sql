-- 0069: the roles of wave G's functions. apply_roles() re-created from 0015's with two lists longer:
-- the collector's door gains mssql_hadr_cursor (the Agent job history reads on from it: as an invoker function it
-- was granted to the reader and denied to the collector, so every mssql_jobs run failed under the collector
-- login), and the owner-only list gains mssql_running_purge, mssql_ensure_day_partition, mssql_event_partition and
-- mssql_hadr_read (called only from inside the import functions and purge(), never by a reader). Nothing else of
-- the function changes, except that the owner-only branch now takes back a reader grant an earlier run gave;
-- migrate calls apply_roles() after the last file as before.
CREATE OR REPLACE FUNCTION pgvigil.apply_roles()
 RETURNS void
 LANGUAGE plpgsql
AS $$
DECLARE
  f record;
  t record;
BEGIN
  REVOKE ALL ON SCHEMA pgvigil FROM PUBLIC;
  GRANT USAGE ON SCHEMA pgvigil TO pgvigil_collector, pgvigil_reader, pgvigil_auth;

  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgvigil'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF f.proname LIKE 'import\_%' OR f.proname IN ('ensure_instance', 'log_collection', 'schema_latest', 'log_cursor', 'mssql_hadr_cursor') THEN
      -- the collector's door: runs as the owner, sees only its arguments
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_collector', f.sig);
    ELSIF f.proname LIKE 'ui\_%' THEN
      -- the UI login's door: one named user's hash and the user count, never the table
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_auth', f.sig);
    ELSIF f.proname IN ('apply_roles', 'purge', 'ensure_month_partition', 'mssql_running_purge', 'mssql_ensure_day_partition',
                        'mssql_event_partition', 'mssql_hadr_read') THEN
      -- owner only; a grant an earlier run of this function gave the reader (the name was not on the list then) is taken back
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader', f.sig);
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_reader', f.sig);
    END IF;
  END LOOP;

  FOR t IN
    SELECT c.oid::regclass AS rel, c.relname
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p', 'v')
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, pgvigil_collector, pgvigil_auth', t.rel);
    IF t.relname LIKE 'ui\_%' THEN
      EXECUTE format('REVOKE ALL ON %s FROM pgvigil_reader', t.rel);
    ELSE
      EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t.rel);
    END IF;
  END LOOP;
END $$;
