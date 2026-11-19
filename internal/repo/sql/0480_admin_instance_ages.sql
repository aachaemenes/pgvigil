-- 0480_admin_instance_ages: RELNOTES L170 - 'pgvigil instance list' reads each instance's last collection under the
-- configuration's repository login, which a site sets up as the collector's (pgvigil_agent IN ROLE pgvigil_collector:
-- README's PGVIGIL_REPO_DSN, the Windows template's repo.dsn), and apply_roles leaves that role no SELECT on any
-- pgvigil table or view (0300's loop). One SECURITY DEFINER function answers the newest successful collection of each
-- instance (status 'ok', as the page's last_collected counts; NULL when none succeeded) and nothing else, granted to
-- pgvigil_collector as admin_inventory() is (0122): apply_roles revokes functions from PUBLIC only, and its last branch
-- grants the reader, so this grant stays. Above 0300: its own object only (the join-file rule); PARALLEL SAFE (it reads
-- two tables and reaches no scope policy: PARSAFE's schema-wide row at j17).
CREATE OR REPLACE FUNCTION pgvigil.admin_instance_ages()
RETURNS TABLE (name text, last_at timestamptz)
LANGUAGE sql STABLE PARALLEL SAFE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  SELECT i.name, max(c.snapshot_at) FILTER (WHERE c.status = 'ok')
    FROM pgvigil.instances i JOIN pgvigil.collection_dates c USING (instance_id)
   GROUP BY i.name
$$;
REVOKE ALL ON FUNCTION pgvigil.admin_instance_ages() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgvigil.admin_instance_ages() TO pgvigil_collector, pgvigil_reader;
