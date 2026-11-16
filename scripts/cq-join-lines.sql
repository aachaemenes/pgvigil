-- CQ slice A (migration 0200, above 0190): the lines for the next join's own file 0300_join_release3.sql (the
-- join-file rule: 0190 applies before 0200, so these lines can never go into 0190). Not a migration of
-- its own; the record of what the join places when it re-creates each joined function whole.
--
-- purge(): beside the other per-table deletes, before the hours tables (0139's block). In 0300 action_requests and
-- cq_workers always exist (0200 sorts before it): no to_regclass guard there.
--   (scripts/cq-wiring-a.patch carries the same lines, guarded, as a hunk on 0190: the box job r01 applies it to its
--   job copy ONLY, to test the lines in purge() before the join; it is never placed in 0190.)
  -- 0200 (CQ): the request queue's read kinds after 7 days (a read's result is cleared within the hour by the sweep;
  -- the row's ask and end go with it), and a refused ask of any kind after 7 days (nothing ran: a requester must not
  -- grow the table without bound); the action kinds that ran are an audit, kept whole as actions_log is; a worker
  -- stopped or silent for 8 days goes with its doors and tool lists
  DELETE FROM pgvigil.action_requests WHERE (class <> 'action' OR state = 'refused') AND state NOT IN ('waiting', 'running')
     AND asked_at < now() - interval '7 days';
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.cq_workers WHERE coalesce(beat_at, stopped_at, started_at) < now() - interval '8 days';
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
--
-- actions_log's CHECKs (BOTH): CQ-A adds no action to actions_log - its audit rows are the queue's
-- own (action_requests) - so it widens no CHECK and lists none here; a later CQ slice that writes actions_log rows of a
-- new kind widens the CHECKs in its own migration and names its kinds here.
-- No other joined object: 0200 creates its own tables and functions only; apply_roles' general rules (import_*, ui_*)
-- grant them, no line of their own.
