-- 0467_pg_signin: PGAUTH M1 (Allen's Q249; decision 2 = a WARN, never a refusal; migration number the lead's 23:49) -
-- how the server signed pgvigil's read login in, from the pg_signin collection (hourly, PostgreSQL 16+): SYSTEM_USER's
-- method word (never the identity: under ldap it is the bind DN), whether that method has the client send the
-- password in clear (ldap, radius, pam, bsd, password), the session's TLS, and the dsn's sslmode (the collector's own
-- configuration). A password-shaped method short of sslmode=verify-full is a warning on the instance.
--
-- Above 0300, so this file makes only its own objects (the join-file rule): the arm that puts pg_signin_findings into
-- pgvigil.findings is line 1 of scripts/PGAUTH-join-lines.sql.
CREATE TABLE IF NOT EXISTS pgvigil.pg_signin (
  instance_id     int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  method          text NOT NULL,      -- SYSTEM_USER's method word; '' = NULL (trust)
  sends_password  boolean NOT NULL,   -- the method has the client send the password in clear
  ssl             boolean NOT NULL,   -- the session's pg_stat_ssl.ssl
  sslmode         text NOT NULL,      -- the dsn's sslmode; '' = not read
  read_at         timestamptz NOT NULL
);
CREATE OR REPLACE FUNCTION pgvigil.import_pg_signin(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r jsonb;
BEGIN
  SELECT x INTO r FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'signin' LIMIT 1;
  IF r IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO pgvigil.pg_signin AS s (instance_id, method, sends_password, ssl, sslmode, read_at)
  VALUES (p_instance_id, coalesce(r->>'method', ''), coalesce((r->>'clear')::boolean, false), coalesce((r->>'ssl')::boolean, false),
          coalesce(r->>'sslmode', ''), p_snapshot_at)
  ON CONFLICT (instance_id) DO UPDATE SET method = EXCLUDED.method, sends_password = EXCLUDED.sends_password, ssl = EXCLUDED.ssl,
    sslmode = EXCLUDED.sslmode, read_at = EXCLUDED.read_at;
END $$;
CREATE OR REPLACE VIEW pgvigil.pg_signin_findings AS
SELECT s.instance_id, 'warning'::text AS severity, 'a directory password without a certificate check'::text AS setting,
       i.name AS value, true AS is_set,
       'sslmode=verify-full with sslrootcert (the server''s CA file, or system for a public CA)'::text AS suggested,
       'all'::text AS platforms,
       format('the server signs the read login in by %s, which has pgvigil send the password in clear inside the session%s, and the dsn''s %s checks no server certificate: set sslmode=verify-full with sslrootcert (docs/postgres-signin.md)',
              s.method, CASE WHEN s.ssl THEN '' ELSE ' (this session runs without TLS)' END,
              CASE WHEN s.sslmode = '' THEN 'sslmode (not read)' ELSE 'sslmode=' || s.sslmode END)::text AS detail,
       'pg_signin'::text AS source, s.read_at AS at
  FROM pgvigil.pg_signin s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
 WHERE s.sends_password AND s.sslmode <> 'verify-full' AND s.read_at > now() - interval '3 hours';
COMMENT ON TABLE pgvigil.pg_signin IS 'PGAUTH M1: how the server signed the read login in (pg_signin): the method word, never the identity; the session''s TLS and the dsn''s sslmode.';
COMMENT ON VIEW pgvigil.pg_signin_findings IS 'PGAUTH M1: a password-shaped sign-in short of sslmode=verify-full, a warning on the instance; joined into pgvigil.findings by PGAUTH-join-lines.sql line 1.';
