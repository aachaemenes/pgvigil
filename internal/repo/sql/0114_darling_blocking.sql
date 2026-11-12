-- 0114: who blocks whom now (task 177, darling-open D02): each head's share of the blocked wait over a range and the
-- findings on implicit transactions and lead blockers, over the Running queries snapshots of 0064 (no new table).
--
--   mssql_head_share(instance, from, to)  every head statement of the range (the head's sql_handle and offsets, 0064's
--                                         text_id; a head with no statement read is keyed by its session, login and
--                                         program), the 50 with the most blocked wait, and how many there were:
--                                         the blocked requests behind it, the time they waited, its share of all the
--                                         blocked wait of the range, 'lead' at 10 % or more, the snapshots it was seen in,
--                                         its sessions, and whether it held an implicit transaction
--   mssql_blocking_findings               the newest snapshot of the last 5 minutes (0064's rule):
--       'an implicit transaction blocking'   a head whose open transaction is an implicit one and whose victims wait
--                                            over 30 s, 0064's chain rule (warning)
--       'sessions in implicit transactions'  the sessions holding an open implicit transaction that head no chain
--                                            (info)
--     and the last hour:
--       'a lead blocker'                     a head statement with 10 % or more of the hour's blocked wait, when the
--                                            hour's blocked wait is a minute or more (warning)
--
-- The blocked wait: a blocked request (its session and its request's start) counts once per head statement it waited
-- behind, at the longest wait it was seen with there, so a request seen in five snapshots is not counted five times;
-- every blocked request of a chain counts toward the chain's head, at any depth. A request whose head moved on to
-- another statement of the same transaction counts under both (as check 9 groups by lead statement), so the range's
-- total can hold one request twice.
--
-- The rules are read from these tools; none of their code is copied:
--   sp_HumanEventsBlockViewer (DarlingData, darlingdata-20261101; MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC)
--     check 7 'Implicit Transaction Blocking' (implicit_transaction in the blocking) and check 9 'Top Lead Blocker'
--     (a lead blocker's statement whose victims' wait is 10 % or more of all the blocked wait);
--   SQL Server First Responder Kit (frk-20260708; MIT, Copyright (c) Brent Ozar Unlimited) sp_BlitzFirst check 37 and
--     sp_Blitz check 215 (a session whose sys.dm_tran_active_transactions name is 'implicit_transaction').
-- The minute's floor under 'a lead blocker' is pgvigil's: with no floor, any single short block would make its head a
-- lead blocker with 100 % of the hour's blocked wait.
--
-- For the join (the lead's 0110): the arm in pgvigil.findings
--     SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_blocking', at
--       FROM pgvigil.mssql_blocking_findings
--   No table is added, so purge() needs no line.

CREATE OR REPLACE FUNCTION pgvigil.mssql_head_share(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (head_key text, head_text_id bigint, statement text, full_chars int, head_sessions int[], victims bigint,
               blocked_wait_ms bigint, range_blocked_wait_ms bigint, heads bigint, share_pct numeric, lead boolean, snapshots bigint,
               first_seen timestamptz, last_seen timestamptz, head_login text, head_program text, head_host text,
               head_database text, implicit boolean)
LANGUAGE sql STABLE AS $$
  WITH v AS (
    -- every blocked request of the range with its chain's head as that snapshot read it
    SELECT q.snapshot_at, q.session_id, q.start_time, q.wait_ms, q.head_session_id, b.head_text_id, b.head_login,
           b.head_program, b.head_host, b.head_database,
           coalesce('text ' || b.head_text_id, 'session ' || b.head_session_id || ', login ' || coalesce(b.head_login, '(unknown)')
                    || ', program ' || coalesce(nullif(b.head_program, ''), '(none)')) AS head_key
      FROM pgvigil.mssql_requests q
      JOIN pgvigil.mssql_blocking b
        ON b.instance_id = q.instance_id AND b.snapshot_at = q.snapshot_at AND b.head_session_id = q.head_session_id
     WHERE q.instance_id = p_instance_id AND q.snapshot_at > p_from AND q.snapshot_at <= p_to
       AND q.chain_depth > 0 AND q.wait_ms IS NOT NULL
  ), ep AS (
    -- one blocked request once per head statement, at the longest wait it was seen with behind it
    SELECT v.head_key, v.session_id, v.start_time, max(v.wait_ms) AS wait_ms
      FROM v
     GROUP BY v.head_key, v.session_id, v.start_time
  ), h AS (
    SELECT ep.head_key, count(*) AS victims, sum(ep.wait_ms)::bigint AS blocked_wait_ms
      FROM ep
     GROUP BY ep.head_key
  ), seen AS (
    SELECT v.head_key, count(DISTINCT v.snapshot_at) AS snapshots, min(v.snapshot_at) AS first_seen,
           max(v.snapshot_at) AS last_seen, array_agg(DISTINCT v.head_session_id ORDER BY v.head_session_id) AS head_sessions,
           (array_agg(v.head_text_id ORDER BY v.snapshot_at DESC))[1] AS head_text_id,
           (array_agg(v.head_login ORDER BY v.snapshot_at DESC))[1] AS head_login,
           (array_agg(v.head_program ORDER BY v.snapshot_at DESC))[1] AS head_program,
           (array_agg(v.head_host ORDER BY v.snapshot_at DESC))[1] AS head_host,
           (array_agg(v.head_database ORDER BY v.snapshot_at DESC))[1] AS head_database,
           bool_or(EXISTS (SELECT 1 FROM pgvigil.mssql_requests hq
                            WHERE hq.instance_id = p_instance_id AND hq.snapshot_at = v.snapshot_at
                              AND hq.session_id = v.head_session_id AND hq.chain_depth = 0
                              AND hq.is_implicit_tran AND hq.open_tran > 0)) AS implicit
      FROM v
     GROUP BY v.head_key
  )
  SELECT h.head_key, s.head_text_id, left(t.statement, 4000), t.full_chars, s.head_sessions, h.victims, h.blocked_wait_ms,
         (sum(h.blocked_wait_ms) OVER ())::bigint, count(*) OVER (),
         round(100.0 * h.blocked_wait_ms / nullif(sum(h.blocked_wait_ms) OVER (), 0), 1),
         coalesce(100.0 * h.blocked_wait_ms / nullif(sum(h.blocked_wait_ms) OVER (), 0) >= 10, false),
         s.snapshots, s.first_seen, s.last_seen, s.head_login, s.head_program, s.head_host, s.head_database, s.implicit
    FROM h
    JOIN seen s ON s.head_key = h.head_key
    LEFT JOIN pgvigil.mssql_statement_text t ON t.text_id = s.head_text_id
   ORDER BY h.blocked_wait_ms DESC, h.head_key
   LIMIT 50
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_blocking_findings AS
WITH latest AS (
  SELECT s.instance_id, max(s.snapshot_at) AS snapshot_at
    FROM pgvigil.mssql_requests_summary s
   WHERE s.snapshot_at > now() - interval '5 minutes'
   GROUP BY s.instance_id
), sess AS (
  -- one row per session of the newest snapshot (a MARS session has several request rows: the head's flags are the session's)
  SELECT DISTINCT ON (q.instance_id, q.session_id) q.*
    FROM pgvigil.mssql_requests_v q
    JOIN latest l ON l.instance_id = q.instance_id AND l.snapshot_at = q.snapshot_at
   WHERE q.is_implicit_tran AND q.open_tran > 0
   ORDER BY q.instance_id, q.session_id, q.chain_depth NULLS LAST, q.request_id NULLS FIRST
), hour AS (
  SELECT DISTINCT b.instance_id FROM pgvigil.mssql_blocking b WHERE b.snapshot_at > now() - interval '1 hour'
)
SELECT r.instance_id, 'warning'::text AS severity, 'an implicit transaction blocking'::text AS check_name,
       'session ' || r.session_id AS object, r.snapshot_at AS at,
       format('Session %s (login %s, program %s, host %s) heads a blocking chain from an implicit transaction: %s session(s) wait '
              || 'behind it, the longest for %s s, its transaction open for %s s. With SET IMPLICIT_TRANSACTIONS ON each statement opens '
              || 'a transaction that stays open, its locks held, until the application sends COMMIT or ROLLBACK '
              || '(sp_HumanEventsBlockViewer check 7, sp_BlitzFirst check 37). Its %s: %s',
              r.session_id, coalesce(r.login_name, '(unknown)'), coalesce(nullif(r.program_name, ''), '(none)'),
              coalesce(nullif(r.host_name, ''), '(none)'), r.victims, coalesce(r.longest_victim_wait_ms, 0) / 1000,
              coalesce(r.tran_age_ms, 0) / 1000, CASE WHEN r.request_id IS NULL THEN 'last batch' ELSE 'statement' END,
              coalesce(left(r.statement, 500), '(text not stored)')) AS detail
  FROM sess r
 WHERE r.chain_depth = 0 AND r.victims > 0 AND coalesce(r.longest_victim_wait_ms, 0) > 30000
UNION ALL
SELECT r.instance_id, 'info', 'sessions in implicit transactions', 'server', max(r.snapshot_at),
       format('%s session(s) hold an open implicit transaction (SET IMPLICIT_TRANSACTIONS ON: each statement opens a transaction '
              || 'that stays open until COMMIT or ROLLBACK; sp_BlitzFirst check 37, sp_Blitz check 215), none of them the head of a '
              || 'blocking chain now: %s',
              count(*), string_agg(format('session %s (login %s, program %s, open for %s s)', r.session_id,
                                          coalesce(r.login_name, '(unknown)'), coalesce(nullif(r.program_name, ''), '(none)'),
                                          coalesce(r.tran_age_ms, 0) / 1000), '; ' ORDER BY r.tran_age_ms DESC NULLS LAST))
  FROM sess r
 WHERE r.chain_depth IS DISTINCT FROM 0 OR coalesce(r.victims, 0) = 0   -- in no chain, chain_depth and victims are NULL
 GROUP BY r.instance_id
UNION ALL
SELECT hr.instance_id, 'warning', 'a lead blocker', coalesce('statement ' || hs.head_text_id, hs.head_key), hs.last_seen,
       format('In the last hour %s%% of the time sessions waited behind a head (%s s of %s s) was behind one head statement: '
              || '%s blocked request(s), seen in %s snapshot(s), sessions %s, login %s, program %s, database %s%s '
              || '(sp_HumanEventsBlockViewer check 9 Top Lead Blocker, at 10 %%). The statement: %s',
              hs.share_pct, hs.blocked_wait_ms / 1000, hs.range_blocked_wait_ms / 1000, hs.victims, hs.snapshots,
              array_to_string(hs.head_sessions, ', '), coalesce(hs.head_login, '(unknown)'),
              coalesce(nullif(hs.head_program, ''), '(none)'), coalesce(hs.head_database, '(unknown)'),
              CASE WHEN hs.implicit THEN ', from an implicit transaction' ELSE '' END,
              coalesce(left(hs.statement, 500), '(text not stored)'))
  FROM hour hr
 CROSS JOIN LATERAL pgvigil.mssql_head_share(hr.instance_id, now() - interval '1 hour', now()) hs
 WHERE hs.lead AND hs.range_blocked_wait_ms >= 60000;
