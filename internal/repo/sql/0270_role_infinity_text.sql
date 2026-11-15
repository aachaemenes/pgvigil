-- 0270_role_infinity_text.sql - a role's VALID UNTIL of 'infinity' or '-infinity' in the two texts built from it.
--
-- Since collect.JSONValue (rel-pginf) such a role reaches the repository (before, the whole roles collection failed on it:
-- pgx's InfinityModifier went out as JSON 1). to_char of a non-finite timestamp is NULL, so role_flags dropped
-- 'valid until' (an always-expired '-infinity' password read like none) and the 'login without a way in' finding's
-- detail was NULL. Both now write the value itself when it is not finite: 'valid until -infinity', 'its password
-- expired -infinity'. role_flags and role_findings are defined only in 0020 on every branch; both are re-created here
-- WHOLE, as 0020 has them, with only those two expressions changed (same signature, same columns).
--
-- role_history compares role_flags texts: no stored value carries a non-finite VALID UNTIL (none could be imported
-- before rel-pginf), so the new text starts no history row of its own.

CREATE OR REPLACE FUNCTION pgvigil.role_flags(p_super boolean, p_inherit boolean, p_createrole boolean, p_createdb boolean,
                                              p_canlogin boolean, p_replication boolean, p_bypassrls boolean,
                                              p_connlimit int, p_valid_until timestamptz)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT concat_ws(',', CASE WHEN p_super THEN 'superuser' END, CASE WHEN p_canlogin THEN 'login' END,
                   CASE WHEN p_createrole THEN 'createrole' END, CASE WHEN p_createdb THEN 'createdb' END,
                   CASE WHEN p_replication THEN 'replication' END, CASE WHEN p_bypassrls THEN 'bypassrls' END,
                   CASE WHEN NOT p_inherit THEN 'noinherit' END,
                   CASE WHEN p_connlimit IS NOT NULL AND p_connlimit <> -1 THEN 'connection limit ' || p_connlimit END,
                   CASE WHEN p_valid_until IS NOT NULL THEN 'valid until ' || CASE WHEN isfinite(p_valid_until)
                        THEN to_char(p_valid_until AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' ELSE p_valid_until::text END END)
$$;

CREATE OR REPLACE VIEW pgvigil.role_findings AS
WITH st AS (
  SELECT s.*, i.platform FROM pgvigil.role_state s JOIN pgvigil.instances i USING (instance_id)
), a AS (
  SELECT a.*, st.platform, pgvigil.role_is_platform(st.platform, a.rolname, a.role_oid) AS is_platform
    FROM pgvigil.role_attributes a JOIN st USING (instance_id)
   WHERE a.is_present
), m AS (
  SELECT * FROM pgvigil.role_members WHERE is_present
), admins AS (   -- the platform's administrator logins: members of its admin role (the RDS master user and the like)
  SELECT DISTINCT m.instance_id, m.member_name AS rolname
    FROM m WHERE m.role_name IN ('rds_superuser', 'azure_pg_admin', 'cloudsqlsuperuser', 'alloydbsuperuser')
), app AS (      -- application roles: not a superuser, not the server's or the platform's own, not a platform admin
  SELECT a.* FROM a
   WHERE NOT a.super AND NOT a.is_platform
     AND NOT EXISTS (SELECT 1 FROM admins x WHERE x.instance_id = a.instance_id AND x.rolname = a.rolname)
), dbs AS (
  SELECT instance_id, count(DISTINCT datname) AS n FROM pgvigil.acl_databases WHERE is_present GROUP BY instance_id
), hst AS (      -- the instances whose stored hba rules can be judged: read at least once, and no line in error (with a
                 -- syntax error the server keeps the rules it loaded before, so the file shown is not the one in effect)
  SELECT st.instance_id FROM st
   WHERE st.hba_rules IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.hba_rules e WHERE e.instance_id = st.instance_id AND e.is_present AND e.error IS NOT NULL)
), hu AS (       -- each user entry of each rule that admits a normal connection (replication-only rules left out)
  SELECT h.instance_id, h.auth_method, u
    FROM pgvigil.hba_rules h JOIN hst USING (instance_id) CROSS JOIN LATERAL unnest(h.users) u
   WHERE h.is_present AND h.error IS NULL
     AND EXISTS (SELECT 1 FROM unnest(h.databases) d WHERE d <> 'replication')
), lg AS (
  SELECT a.instance_id, a.rolname, a.valid_until, a.snapshot_at FROM a JOIN hst USING (instance_id) WHERE a.canlogin
), hit AS (      -- (login role, method) for every entry that names it: all or an @file, itself or +itself, a +group it
                 -- is a member of at any depth, a /regex that matches it
  SELECT lg.instance_id, lg.rolname, hu.auth_method FROM lg JOIN hu ON hu.instance_id = lg.instance_id AND (hu.u = 'all' OR hu.u LIKE '@%')
  UNION
  SELECT lg.instance_id, lg.rolname, hu.auth_method FROM lg JOIN hu ON hu.instance_id = lg.instance_id AND hu.u IN (lg.rolname, '+' || lg.rolname)
  UNION
  SELECT lg.instance_id, lg.rolname, hu.auth_method
    FROM lg JOIN pgvigil.role_member_closure c ON c.instance_id = lg.instance_id AND c.member_name = lg.rolname
    JOIN hu ON hu.instance_id = lg.instance_id AND hu.u = '+' || c.role_name
  UNION
  SELECT lg.instance_id, lg.rolname, hu.auth_method
    FROM lg JOIN hu ON hu.instance_id = lg.instance_id AND hu.u LIKE '/%' AND pgvigil.role_regex_match(lg.rolname, substr(hu.u, 2))
), way AS (      -- per login role: the auth methods that let it in (reject aside)
  SELECT lg.instance_id, lg.rolname, lg.valid_until, lg.snapshot_at,
         array_agg(DISTINCT hit.auth_method) FILTER (WHERE hit.auth_method IS NOT NULL AND hit.auth_method <> 'reject') AS methods
    FROM lg LEFT JOIN hit ON hit.instance_id = lg.instance_id AND hit.rolname = lg.rolname
   GROUP BY lg.instance_id, lg.rolname, lg.valid_until, lg.snapshot_at
)
-- a superuser beyond the server's bootstrap role and the platform's own
SELECT a.instance_id, 'warning' AS severity, 'superuser' AS setting, a.rolname AS value, true AS is_set,
       'ALTER ROLE ' || quote_ident(a.rolname) || ' NOSUPERUSER (or keep it for a named DBA and say so)' AS suggested, 'all' AS platforms,
       a.rolname || ' is a superuser' || CASE WHEN a.canlogin THEN ' and can log in' ELSE ' (NOLOGIN, reachable by SET ROLE from its members)' END
       || ': it bypasses every privilege check, reads every file the server can and can run programs as the server''s OS user; '
       || 'on a managed platform only the platform''s own role is superuser' AS detail,
       'pgvigil' AS source, a.snapshot_at AS at
  FROM a WHERE a.super AND NOT a.is_platform
UNION ALL
-- CREATEROLE or BYPASSRLS on an application role
SELECT app.instance_id, 'warning', x.attr, app.rolname, true,
       'ALTER ROLE ' || quote_ident(app.rolname) || ' NO' || x.attr, 'all',
       CASE x.attr
         WHEN 'CREATEROLE' THEN app.rolname || ' has CREATEROLE: it can create roles and grant itself any role it administers (before PostgreSQL 16 any non-superuser role); an application seldom needs it'
         ELSE app.rolname || ' has BYPASSRLS: every row-level security policy is skipped for it' END,
       'pgvigil', app.snapshot_at
  FROM app CROSS JOIN LATERAL (VALUES ('CREATEROLE', app.createrole), ('BYPASSRLS', app.bypassrls)) x(attr, hit)
 WHERE x.hit
UNION ALL
-- the monitoring login without pg_monitor
SELECT st.instance_id, 'warning', 'pg_monitor', st.login_name, true,
       'GRANT pg_monitor TO ' || quote_ident(st.login_name), 'all',
       'the monitoring login ' || st.login_name || ' is not a member of pg_monitor: other sessions'' queries, the statement history, '
       || 'the preload lists and several settings read empty or fail',
       'pgvigil', st.snapshot_at
  FROM st WHERE st.login_has_pg_monitor IS FALSE
UNION ALL
-- a role (not PUBLIC, not the owner, not a superuser or the platform's own) granted on every database
SELECT g.instance_id, 'info', 'granted on every database', g.grantee, true,
       'grant per database, where the role is needed', 'all',
       g.grantee || ' holds ' || g.privs || ' on every one of the ' || g.n || ' databases: a grant made everywhere by habit, or a role that needs no per-database limit',
       'pgvigil', g.at
  FROM (SELECT d.instance_id, d.grantee, dbs.n, string_agg(DISTINCT d.privileges, ' / ') AS privs, max(d.snapshot_at) AS at
          FROM pgvigil.acl_databases d JOIN dbs USING (instance_id)
          LEFT JOIN a ON a.instance_id = d.instance_id AND a.rolname = d.grantee
         WHERE d.is_present AND d.grantee <> 'PUBLIC' AND d.grantee IS DISTINCT FROM d.owner
           AND NOT coalesce(a.super OR a.is_platform, false)
         GROUP BY d.instance_id, d.grantee, dbs.n
        HAVING count(DISTINCT d.datname) = dbs.n AND dbs.n >= 2) g
UNION ALL
-- a login role with no way in: no hba rule names it (reject aside), or only password rules do and its password has
-- expired (VALID UNTIL). Whether a role has a password at all is not visible: pg_roles masks it and pg_authid is
-- never read; the rule needs the hba rules read (a superuser login, or SELECT granted on pg_hba_file_rules) and none
-- of them in error.
SELECT w.instance_id, 'info', 'login without a way in', w.rolname, true,
       'ALTER ROLE ' || quote_ident(w.rolname) || ' NOLOGIN if it is unused, or a pg_hba.conf line for it', 'all',
       CASE WHEN w.methods IS NULL
            THEN w.rolname || ' can log in (LOGIN) but no pg_hba.conf rule admits it: every connection is refused'
            ELSE w.rolname || ' is admitted only by password (' || array_to_string(w.methods, ', ') || ') and its password expired '
                 || CASE WHEN isfinite(w.valid_until) THEN to_char(w.valid_until AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
                         ELSE w.valid_until::text END || ': no other method lets it in' END,
       'pgvigil', w.snapshot_at
  FROM way w
 WHERE w.methods IS NULL
    OR (w.valid_until < now() AND w.methods <@ ARRAY['md5', 'scram-sha-256', 'password']);
