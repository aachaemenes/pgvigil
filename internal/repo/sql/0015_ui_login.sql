-- 0015_ui_login: the web UI's own login.
--   pgvigil.ui_users holds a user name and an argon2id password hash (a PHC string). Nobody but the
--   repository owner reads the table: `pgvigil serve` verifies a password through
--   pgvigil.ui_password_hash(username), a SECURITY DEFINER function granted to the pgvigil_auth role
--   alone, so a pgvigil_reader login (Grafana, a script) never sees a hash. `pgvigil user` writes the
--   table as the owner. The serve login holds pgvigil_reader and pgvigil_auth.
--   Sessions live in the serve process (a random token in an HttpOnly cookie), never in the repository:
--   the UI's repository session stays read-only.

CREATE TABLE pgvigil.ui_users (
  user_id          int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  username         text NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9][a-z0-9._@-]{0,63}$'),
  password_hash    text NOT NULL CHECK (password_hash LIKE '$argon2id$%'),
  is_disabled      boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  password_set_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pgvigil.ui_users IS 'Logins of the web UI; password_hash is an argon2id PHC string. Owner only: the UI reads through ui_password_hash().';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_auth') THEN
    CREATE ROLE pgvigil_auth NOLOGIN;
  END IF;
END $$;

-- The hash of an enabled user, NULL when there is none. The caller verifies against a fixed hash
-- when NULL, so an unknown name costs the same time as a wrong password.
CREATE FUNCTION pgvigil.ui_password_hash(p_username text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  SELECT password_hash FROM pgvigil.ui_users WHERE username = lower(p_username) AND NOT is_disabled
$$;

-- How many enabled users exist: serve warns at start when none can log in.
CREATE FUNCTION pgvigil.ui_user_count()
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  SELECT count(*) FROM pgvigil.ui_users WHERE NOT is_disabled
$$;

-- The access contract with the third role: ui_* functions run as the owner and only pgvigil_auth may
-- call them; ui_users is readable by nobody but the owner.
CREATE OR REPLACE FUNCTION pgvigil.apply_roles()
RETURNS void LANGUAGE plpgsql AS $$
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
    IF f.proname LIKE 'import\_%' OR f.proname IN ('ensure_instance', 'log_collection', 'schema_latest', 'log_cursor') THEN
      -- the collector's door: runs as the owner, sees only its arguments
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_collector', f.sig);
    ELSIF f.proname LIKE 'ui\_%' THEN
      -- the UI login's door: one named user's hash and the user count, never the table
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_auth', f.sig);
    ELSIF f.proname IN ('apply_roles', 'purge', 'ensure_month_partition') THEN
      NULL;  -- owner only
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
    IF t.relname = 'ui_users' THEN
      EXECUTE format('REVOKE ALL ON %s FROM pgvigil_reader', t.rel);
    ELSE
      EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t.rel);
    END IF;
  END LOOP;
END $$;

SELECT pgvigil.apply_roles();
