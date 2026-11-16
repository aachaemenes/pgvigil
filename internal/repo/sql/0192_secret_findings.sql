-- 0192_secret_findings: an instance whose login's password could not be read from AWS Secrets Manager, or whose
-- secret the connect refused (task B24e, decision Q7: its own critical finding, never 'server unreachable' - the
-- person fixes the secret, its right, its key or the login, not the server). The collector records such a run as the
-- collection's error with a note that starts 'secret: ' followed by the reader's own words (Repo.LogSecretFailure:
-- 'the password could not be read from AWS Secrets Manager: <code>, <secret> (<message>)', never the value). The
-- finding's object is '<code>, <secret>'; its detail says what to fix for the code. It stands while the instance's
-- newest run is such a refusal within the last 15 minutes and no run of the instance has succeeded since. Its arm in
-- pgvigil.findings (and so in alerting and the Summary) is in scripts/b24e-join-lines.sql for the next join (0300: the
-- join-file rule: a migration above 0190 creates only its own objects).
CREATE OR REPLACE VIEW pgvigil.secret_findings AS
SELECT d.instance_id, 'critical'::text AS severity, 'password secret unreadable'::text AS check_name,
       d.object,
       d.snapshot_at AS at,
       substr(d.note, length('secret: ') + 1) || '. ' ||
       CASE split_part(d.object, ', ', 1)
         WHEN 'LoginRefused' THEN 'The server refused the secret''s current password (a rotation not finished, or the login''s password changed outside the secret): pgvigil tries that version once a minute and takes a new version at once.'
         WHEN 'LoginMismatch' THEN 'The connection string names another login than the secret''s username: make them the same, or remove the user from the connection string.'
         WHEN 'NoLogin' THEN 'Neither the connection string nor the secret names the login: add user= (or the URL''s user) to the connection string.'
         WHEN 'WindowsLogin' THEN 'A DOMAIN\user login signs in through Windows: a password from AWS Secrets Manager is a SQL login''s.'
         WHEN 'BadReference' THEN 'Fix password_secret in pgvigil.yaml.'
         ELSE 'The server was not asked: fix the secret, the reader''s right to it (secretsmanager:GetSecretValue), its key or the AWS sign-in of the collector''s host.'
       END AS detail
  FROM (SELECT DISTINCT ON (c.instance_id) c.instance_id, c.snapshot_at, c.note,
               split_part(substr(c.note, length('secret: the password could not be read from AWS Secrets Manager: ') + 1), ' (', 1) AS object
          FROM pgvigil.collection_dates c
         WHERE c.status = 'error' AND c.note LIKE 'secret: %' AND c.snapshot_at > now() - interval '15 minutes'
         ORDER BY c.instance_id, c.snapshot_at DESC) d
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates ok
                    WHERE ok.instance_id = d.instance_id AND ok.status IN ('ok', 'partial') AND ok.snapshot_at > d.snapshot_at);
