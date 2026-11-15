-- 0192_secret_findings: an instance whose login's password could not be read from AWS Secrets Manager (task B24e, the
-- lead's Q7: its own critical finding, never 'server unreachable' - the person fixes the secret, its right or its key,
-- not the server). The collector records such a run as the collection's error with a note that starts 'secret: '
-- (Repo.LogSecretFailure: the secret's id, AWS's code and its message, never the value). The finding stands while the
-- instance's newest run is such a refusal within the last 15 minutes and no run of the instance has succeeded since.
-- Its arm in pgvigil.findings (and so in alerting and the Summary) is the join's WIRING line into 0190.
CREATE OR REPLACE VIEW pgvigil.secret_findings AS
SELECT d.instance_id, 'critical'::text AS severity, 'password secret unreadable'::text AS check_name,
       split_part(substr(d.note, length('secret: the password could not be read from AWS Secrets Manager: ') + 1), ' (', 1) AS object,
       d.snapshot_at AS at,
       substr(d.note, length('secret: ') + 1) || '. The server was not asked: fix the secret, the reader''s right to it (secretsmanager:GetSecretValue) or its key.' AS detail
  FROM (SELECT DISTINCT ON (c.instance_id) c.instance_id, c.snapshot_at, c.note
          FROM pgvigil.collection_dates c
         WHERE c.status = 'error' AND c.note LIKE 'secret: %' AND c.snapshot_at > now() - interval '15 minutes'
         ORDER BY c.instance_id, c.snapshot_at DESC) d
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates ok
                    WHERE ok.instance_id = d.instance_id AND ok.status IN ('ok', 'partial') AND ok.snapshot_at > d.snapshot_at);
