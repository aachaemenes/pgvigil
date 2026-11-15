-- 0257_ui_roles: the web UI's per-user roles (task B24f): viewer, operator, admin.
--   viewer changes nothing; operator acts on a monitored server (cancel, kill, job start / stop, EXPLAIN) and
--   acknowledges; admin changes configuration others live with (instances, sources, applications, thresholds,
--   alert rules, custom reports, report mail schedules). The need of each POST route is web.go's s.post table
--   (docs/roles.md says the same).
--   Every user that exists when this file runs becomes admin, so nobody loses what they could do; a user added
--   after it starts as viewer (`pgvigil user add -role ...`; the first enabled admin of a repository is made by
--   the CLI, not here).
--   pgvigil serve reads the role with the hash at every check through ui_login_of (one row: the hash and the role
--   of an enabled user, NULLs for an unknown or a disabled one), so a demoted user loses the right at the next
--   request. ui_password_hash stays for a serve older than this file and answers admins only: such a serve, which
--   knows no role, admits only the users that could do everything before.
--   Re-runnable over a ui_users without the column (the proof applies it again over a user from before it).

ALTER TABLE pgvigil.ui_users ADD COLUMN role text NOT NULL DEFAULT 'admin'
  CONSTRAINT ui_users_role_check CHECK (role IN ('viewer', 'operator', 'admin'));
ALTER TABLE pgvigil.ui_users ALTER COLUMN role SET DEFAULT 'viewer';
COMMENT ON COLUMN pgvigil.ui_users.role IS 'viewer (reads), operator (acts on a monitored server, acknowledges), admin (shared configuration); read at every request through ui_login_of()';

-- One row always: the hash and the role of an enabled user, or NULLs (an unknown or a disabled user). The caller
-- verifies against a fixed hash when NULL, so an unknown name costs the same time as a wrong password.
CREATE OR REPLACE FUNCTION pgvigil.ui_login_of(p_username text)
RETURNS TABLE (password_hash text, role text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  SELECT u.password_hash, u.role
    FROM (SELECT 1) AS one
    LEFT JOIN pgvigil.ui_users u ON u.username = lower(p_username) AND NOT u.is_disabled
$$;

-- A serve older than this file: admins only (it applies no role, so it may admit only who could do everything).
CREATE OR REPLACE FUNCTION pgvigil.ui_password_hash(p_username text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  SELECT password_hash FROM pgvigil.ui_users WHERE username = lower(p_username) AND NOT is_disabled AND role = 'admin'
$$;

SELECT pgvigil.apply_roles();
