-- 0268_investigations: the agent door and the ask box. A person asks for an investigation of a finding (the
-- Investigate button) or asks a question (the Ask box); the site's own agent claims the request through `pgvigil mcp`
-- on a login IN ROLE pgvigil_reader, pgvigil_agent, reads, and reports. pgvigil holds no agent, no model and no key:
-- these tables are the queue between the people and an agent the site runs itself.
--
--   investigations                 one row a request: who asked, what (a finding of one instance, or a question), its
--                                  state (open, claimed, reported, closed, expired), the claim (the agent's own name,
--                                  the login that claimed, a sha-256 of the claim id - the id itself goes once to the
--                                  claimer and is kept nowhere), the lease, the verdict. The reader reads it.
--   investigations_now             the same rows with their EFFECTIVE state on the repository's clock: an open or
--                                  claimed request past expires_at reads expired; a claim whose lease lapsed reads
--                                  open (expired after its third claim). serve's list, the badge, the caps and the agent
--                                  read it, so a dead claim never shows; the functions write the due state when they pass
--                                  (investigations_settle).
--   ui_investigation_data          (owner only: the ui_ rule) the finding's snapshot (serve's read of it at the request,
--                                  never a copy a browser sends), the person's note or question, and the report.
--   investigation_journal          append-only, the reader reads it: asked, claimed, renewed, released, lapsed, select,
--                                  reported, expired, closed, run - who, when, rows, ms, outcome; NO text. At most 200
--                                  rows a request ("the request's record is full" refuses the call that would add one).
--   ui_investigation_journal_text  (owner only) the statement of a select and of a run, the reason of a release or a
--                                  close: serve shows them to a signed-in user through ui_investigation_read.
--
-- Writes, each one function:
--   serve (the audit login, as acknowledgements: apply_roles makes import_* SECURITY DEFINER for pgvigil_collector):
--     import_investigation_request(at, payload)   a request; the snapshot read here from findings_alerts; the caps
--     import_investigation_event(at, payload)     op close (a person ends one) or run (the ask's Run, audited)
--   serve's UI login (pgvigil_auth, the ui_ rule): ui_investigation_read(id), one request with its texts
--   the agent (SECURITY DEFINER here, EXECUTE to pgvigil_agent; each checks inside that the SESSION user is a member of
--   pgvigil_agent, and the claim functions that it is the login that claimed, with the claim id's hash):
--     agent_investigation_list / _claim / _renew / _release / _report / _journal_select / _journal_done
--   apply_roles (0110) grants every function outside its lists to pgvigil_reader at each migrate, so until the next
--   join file adds the agent branch (scripts/agent-join-lines.sql) the reader holds EXECUTE too and the check inside
--   refuses it ('is not a member of pgvigil_agent'); secdef_reader_test.go lists the seven with that reason.
-- Limits (a request): 10 open or claimed per user; 20 an hour and 100 a day per repository, counted under one
-- transaction lock so concurrent asks cannot pass them. A request expires 4 hours after it was asked unless reported; a
-- lease is 15 minutes, renewed up to the expiry; a request is claimed 3 times at most. One that ended is
-- kept 90 days after it was asked (investigations_purge; open and claimed never), the journal and the texts with it.
-- A request's record holds 200 rows: the agent's calls and Run stop at 195, so its end (a lapse, the report, a
-- release, a close, the expiry) always has room.
-- Every time is the repository's clock (now()); NOTIFY pgvigil_investigation <id> on a new request and on a lapsed claim
-- reopened, so a waiting agent wakes.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_agent') THEN
    CREATE ROLE pgvigil_agent NOLOGIN;
  END IF;
END $$;
-- no GRANT pgvigil_reader TO pgvigil_agent: the agent's login is IN ROLE pgvigil_reader, pgvigil_agent, the two roles
-- the door's check admits ('pgvigil roles' prints it)

CREATE TABLE IF NOT EXISTS pgvigil.investigations (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind           text NOT NULL CHECK (kind IN ('finding', 'ask')),
  instance_id    int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  instance_name  text,
  setting        text CHECK (length(setting) <= 200),
  -- the finding's row the person pressed Investigate on: a setting can hold rows for several objects (one per database)
  finding_value  text CHECK (length(finding_value) <= 2000),
  finding_source text CHECK (length(finding_source) <= 200),
  finding_key    text,          -- pgvigil.alert_finding_key of that row (its numbers aside): earlier reports are keyed on it
  severity       text,
  asked_by       text NOT NULL,
  client         text CHECK (length(client) <= 200),
  asked_at       timestamptz NOT NULL,
  expires_at     timestamptz NOT NULL,
  state          text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'claimed', 'reported', 'closed', 'expired')),
  claimed_by     text CHECK (length(claimed_by) <= 100),
  claimed_login  text,
  claim_hash     bytea,
  claimed_at     timestamptz,
  lease_until    timestamptz,
  claims         int NOT NULL DEFAULT 0,
  reported_at    timestamptz,
  verdict        text CHECK (verdict IN ('real', 'false_positive', 'needs_person', 'answered')),
  closed_by      text,
  closed_at      timestamptz
);
CREATE INDEX IF NOT EXISTS investigations_live ON pgvigil.investigations (id) WHERE state IN ('open', 'claimed');
CREATE INDEX IF NOT EXISTS investigations_asked ON pgvigil.investigations (asked_at);
CREATE INDEX IF NOT EXISTS investigations_finding ON pgvigil.investigations (finding_key) WHERE kind = 'finding';

CREATE TABLE IF NOT EXISTS pgvigil.ui_investigation_data (
  investigation_id bigint PRIMARY KEY REFERENCES pgvigil.investigations(id) ON DELETE CASCADE,
  snapshot     jsonb CHECK (snapshot IS NULL OR octet_length(snapshot::text) <= 65536),
  note         text CHECK (length(note) <= 1000),
  question     text CHECK (length(question) BETWEEN 1 AND 2000),
  summary      text CHECK (length(summary) <= 4000),
  body         text CHECK (length(body) <= 8000),
  evidence     jsonb CHECK (evidence IS NULL OR (jsonb_typeof(evidence) = 'array' AND jsonb_array_length(evidence) <= 50
                                                 AND octet_length(evidence::text) <= 32768)),
  queries_run  jsonb CHECK (queries_run IS NULL OR (jsonb_typeof(queries_run) = 'array' AND jsonb_array_length(queries_run) <= 20
                                                    AND octet_length(queries_run::text) <= 65536)),
  sql          text CHECK (length(sql) <= 20000)
);

CREATE TABLE IF NOT EXISTS pgvigil.investigation_journal (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  investigation_id  bigint NOT NULL REFERENCES pgvigil.investigations(id) ON DELETE CASCADE,
  at                timestamptz NOT NULL,
  event             text NOT NULL CHECK (event IN ('asked', 'claimed', 'renewed', 'released', 'lapsed', 'select',
                                                   'reported', 'expired', 'closed', 'run')),
  login             text,
  rows              bigint,
  ms                int,
  outcome           text CHECK (length(outcome) <= 500)
);
CREATE INDEX IF NOT EXISTS investigation_journal_req ON pgvigil.investigation_journal (investigation_id, id);

CREATE TABLE IF NOT EXISTS pgvigil.ui_investigation_journal_text (
  journal_id  bigint PRIMARY KEY REFERENCES pgvigil.investigation_journal(id) ON DELETE CASCADE,
  text        text CHECK (length(text) <= 20000),
  -- a refused or failed run's server words: they can quote the statement (a literal, an identifier), so they are kept
  -- here with it, never in the journal's outcome every reader reads
  detail      text CHECK (length(detail) <= 2000)
);

-- the effective state, one expression for the view and the functions
CREATE OR REPLACE FUNCTION pgvigil.investigation_state_now(p_state text, p_expires timestamptz, p_lease timestamptz, p_claims int)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_state IN ('reported', 'closed', 'expired') THEN p_state
           WHEN now() >= p_expires THEN 'expired'
           WHEN p_state = 'claimed' AND (p_lease IS NULL OR p_lease <= now()) THEN CASE WHEN p_claims >= 3 THEN 'expired' ELSE 'open' END
           WHEN p_state = 'open' AND p_claims >= 3 THEN 'expired'

           ELSE p_state
         END
$$;

CREATE OR REPLACE VIEW pgvigil.investigations_now AS
SELECT i.id, i.kind, i.instance_id, i.instance_name, i.setting, i.severity, i.asked_by, i.asked_at, i.expires_at,
       pgvigil.investigation_state_now(i.state, i.expires_at, i.lease_until, i.claims) AS state, i.state AS stored_state,
       CASE WHEN pgvigil.investigation_state_now(i.state, i.expires_at, i.lease_until, i.claims) = 'claimed' THEN i.claimed_by END AS claimed_by,
       CASE WHEN pgvigil.investigation_state_now(i.state, i.expires_at, i.lease_until, i.claims) = 'claimed' THEN i.lease_until END AS lease_until,
       i.claims, i.reported_at, i.verdict, i.closed_by, i.closed_at, i.finding_value, i.finding_source, i.finding_key,
       i.claimed_by AS last_agent
  FROM pgvigil.investigations i;

-- investigation_outcome: an outcome 'refused: <words>' or 'failed: <words>' split into its word (the journal's, every
-- reader's) and the words (the ui_ text table's: a server's words can quote the statement)
CREATE OR REPLACE FUNCTION pgvigil.investigation_outcome(p_outcome text, OUT word text, OUT detail text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_outcome ~ '^(refused|failed): ' THEN split_part(p_outcome, ':', 1) ELSE left(p_outcome, 500) END,
         CASE WHEN p_outcome ~ '^(refused|failed): ' THEN left(substr(p_outcome, strpos(p_outcome, ':') + 2), 2000) END
$$;

-- investigation_journal_add: one journal row (and its text), or NULL when the request's record is full: 195 rows for
-- the calls (claimed, renewed, select, run), 200 for the rest, so a request can always end
CREATE OR REPLACE FUNCTION pgvigil.investigation_journal_add(p_id bigint, p_event text, p_login text, p_outcome text,
                                                             p_text text DEFAULT NULL, p_rows bigint DEFAULT NULL, p_ms int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_j bigint;
  o   record;
BEGIN
  IF (SELECT count(*) FROM pgvigil.investigation_journal WHERE investigation_id = p_id)
     >= (CASE WHEN p_event IN ('claimed', 'renewed', 'select', 'run') THEN 195 ELSE 200 END) THEN   -- in parentheses: an IF ends at its first THEN
    RETURN NULL;
  END IF;
  SELECT * INTO o FROM pgvigil.investigation_outcome(p_outcome);
  INSERT INTO pgvigil.investigation_journal (investigation_id, at, event, login, rows, ms, outcome)
  VALUES (p_id, now(), p_event, p_login, p_rows, p_ms, o.word)
  RETURNING id INTO v_j;
  IF p_text IS NOT NULL OR o.detail IS NOT NULL THEN
    INSERT INTO pgvigil.ui_investigation_journal_text (journal_id, text, detail) VALUES (v_j, left(p_text, 20000), o.detail);
  END IF;
  RETURN v_j;
END $$;

-- investigations_settle: writes the due state of the live rows (all, or one asker's, or one id): past the expiry ->
-- expired; a lapsed lease -> open (NOTIFY: a waiting agent wakes) or, after the third claim, expired. Returns the rows
-- it changed.
CREATE OR REPLACE FUNCTION pgvigil.investigations_settle(p_id bigint DEFAULT NULL, p_asker text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r record;
  v_n int := 0;
  v_new text;
BEGIN
  FOR r IN SELECT i.id, i.state, i.expires_at, i.lease_until, i.claims, i.claimed_login
             FROM pgvigil.investigations i
            WHERE i.state IN ('open', 'claimed')
              AND (p_id IS NULL OR i.id = p_id) AND (p_asker IS NULL OR i.asked_by = p_asker)
              AND pgvigil.investigation_state_now(i.state, i.expires_at, i.lease_until, i.claims) <> i.state
            FOR UPDATE SKIP LOCKED
  LOOP
    v_new := pgvigil.investigation_state_now(r.state, r.expires_at, r.lease_until, r.claims);
    UPDATE pgvigil.investigations SET state = v_new, lease_until = NULL WHERE id = r.id;
    IF v_new = 'open' THEN
      PERFORM pgvigil.investigation_journal_add(r.id, 'lapsed', r.claimed_login, 'the lease lapsed: open again');
      PERFORM pg_notify('pgvigil_investigation', r.id::text);
    ELSE
      PERFORM pgvigil.investigation_journal_add(r.id, 'expired', NULL,
        CASE WHEN now() >= r.expires_at THEN 'past its expiry' WHEN r.state = 'open' THEN 'the third claim ended' ELSE 'the third claim lapsed' END);
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- import_investigation_request: serve's write of a request (the audit login). payload: ui_user, client, kind
-- (finding | ask), instance_id and setting (a finding: the snapshot is read HERE from findings_alerts), question (an
-- ask; instance_id optional), note. Answers {outcome done | refused, detail, id}.
CREATE OR REPLACE FUNCTION pgvigil.import_investigation_request(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := left(nullif(p_payload->>'client', ''), 200);
  v_kind   text := p_payload->>'kind';
  v_set    text := nullif(btrim(coalesce(p_payload->>'setting', '')), '');
  v_note   text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_q      text := nullif(btrim(coalesce(p_payload->>'question', '')), '');
  v_val    text := nullif(left(coalesce(p_payload->>'value', ''), 2000), '');
  v_src    text := nullif(btrim(coalesce(p_payload->>'source', '')), '');
  v_key    text;
  v_inst   int;
  v_iname  text;
  v_snap   jsonb;
  v_sev    text;
  v_why    text;
  v_id     bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_investigation_request: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
    SELECT name INTO v_iname FROM pgvigil.instances WHERE instance_id = v_inst;
  END IF;
  -- the caps: one lock for every request, so two at once are counted one after the other
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.investigations'));
  PERFORM pgvigil.investigations_settle(NULL, v_user);
  IF v_kind IS NULL OR v_kind NOT IN ('finding', 'ask') THEN
    v_why := 'kind must be finding or ask';
  ELSIF v_kind = 'finding' AND (v_inst IS NULL OR v_iname IS NULL OR v_set IS NULL) THEN
    v_why := 'a finding is named by its instance_id and its setting';
  ELSIF v_kind = 'ask' AND (v_q IS NULL OR length(v_q) > 2000) THEN
    v_why := 'a question of 1 to 2,000 characters';
  ELSIF v_kind = 'ask' AND p_payload ? 'instance_id' AND v_iname IS NULL THEN
    v_why := 'no such instance';
  ELSIF length(coalesce(v_note, '')) > 1000 THEN
    v_why := 'the note is over 1,000 characters';
  ELSIF (SELECT count(*) FROM pgvigil.investigations_now WHERE asked_by = v_user AND state IN ('open', 'claimed')) >= 10 THEN
    v_why := format('%s already has 10 open investigations: close one, or wait for an agent to report', v_user);
  ELSIF (SELECT count(*) FROM pgvigil.investigations WHERE asked_at > now() - interval '1 hour') >= 20 THEN
    v_why := 'this repository took 20 investigations in the last hour: try again later';
  ELSIF (SELECT count(*) FROM pgvigil.investigations WHERE asked_at > now() - interval '1 day') >= 100 THEN
    v_why := 'this repository took 100 investigations in the last day: try again later';
  END IF;
  IF v_why IS NULL AND v_kind = 'finding' THEN
    -- the row the page showed: named by its value (its numbers aside, as an alert's key: an age that grew since the
    -- page drew still names it) and source; without them, the most severe row of the setting
    SELECT to_jsonb(f), f.severity, pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value)
      INTO v_snap, v_sev, v_key
      FROM pgvigil.findings_alerts f
     WHERE f.instance_id = v_inst AND f.setting = v_set
       AND (v_src IS NULL OR f.source = v_src)
       AND (v_val IS NULL OR pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value)
                             = pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, v_val))
     ORDER BY (f.value = v_val) DESC NULLS LAST, CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END
     LIMIT 1;
    IF v_snap IS NULL THEN
      v_why := format('no finding %L on %s now', v_set, v_iname);
    ELSIF octet_length(v_snap::text) > 65536 THEN
      v_snap := jsonb_build_object('setting', v_set, 'severity', v_sev, 'cut', 'the finding is over 64 KB: read it with instance_findings');
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  INSERT INTO pgvigil.investigations (kind, instance_id, instance_name, setting, finding_value, finding_source, finding_key, severity,
                                      asked_by, client, asked_at, expires_at)
  VALUES (v_kind, v_inst, v_iname, CASE WHEN v_kind = 'finding' THEN v_set END, v_snap->>'value', v_snap->>'source', v_key, v_sev,
          v_user, v_client, now(), now() + interval '4 hours')
  RETURNING id INTO v_id;
  INSERT INTO pgvigil.ui_investigation_data (investigation_id, snapshot, note, question)
  VALUES (v_id, v_snap, v_note, CASE WHEN v_kind = 'ask' THEN v_q END);
  PERFORM pgvigil.investigation_journal_add(v_id, 'asked', v_user, coalesce(v_client, ''));
  PERFORM pg_notify('pgvigil_investigation', v_id::text);
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'asked', 'id', v_id);
END $$;

-- import_investigation_event: serve's other writes (the audit login). op close {id, ui_user, reason}: a person ends a
-- request; op run {id, ui_user, rows, ms, outcome, sql}: the audit of an ask's Run, written before its rows are shown
-- (refused = the rows are withheld).
CREATE OR REPLACE FUNCTION pgvigil.import_investigation_event(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_op   text := p_payload->>'op';
  v_id   bigint;
  v_st   text;
  v_kind text;
  v_j    bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_investigation_event: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'id', '') !~ '^[0-9]{1,18}$' THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'id is not an investigation id');
  END IF;
  v_id := (p_payload->>'id')::bigint;
  -- the row locked first, then settled: a settle that skipped a row another session held would leave a stale state
  PERFORM 1 FROM pgvigil.investigations WHERE id = v_id FOR UPDATE;
  PERFORM pgvigil.investigations_settle(v_id);
  SELECT i.state, i.kind INTO v_st, v_kind FROM pgvigil.investigations i WHERE i.id = v_id;
  IF v_st IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no investigation %s', v_id));
  END IF;
  IF v_op = 'close' THEN
    IF v_st = 'closed' THEN
      RETURN jsonb_build_object('outcome', 'refused', 'detail', format('investigation %s is already closed', v_id));
    END IF;
    v_j := pgvigil.investigation_journal_add(v_id, 'closed', v_user, 'closed', nullif(left(btrim(coalesce(p_payload->>'reason', '')), 1000), ''));
    IF v_j IS NULL THEN
      RETURN jsonb_build_object('outcome', 'refused', 'detail', 'the request''s record is full (200 rows)');
    END IF;
    UPDATE pgvigil.investigations SET state = 'closed', closed_by = v_user, closed_at = now(), lease_until = NULL WHERE id = v_id;
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'closed', 'id', v_id);
  ELSIF v_op = 'run' THEN
    IF v_kind <> 'ask' THEN
      RETURN jsonb_build_object('outcome', 'refused', 'detail', 'only an ask has a SELECT to run');
    END IF;
    v_j := pgvigil.investigation_journal_add(v_id, 'run', v_user, coalesce(p_payload->>'outcome', 'done'), p_payload->>'sql',
             CASE WHEN coalesce(p_payload->>'rows', '') ~ '^[0-9]{1,18}$' THEN (p_payload->>'rows')::bigint END,
             CASE WHEN coalesce(p_payload->>'ms', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'ms')::int END);
    IF v_j IS NULL THEN
      RETURN jsonb_build_object('outcome', 'refused', 'detail', 'the request''s record is full (195 rows for calls and runs; the last 5 are kept for its end): the rows are withheld');
    END IF;
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'run', 'id', v_id);
  END IF;
  RETURN jsonb_build_object('outcome', 'refused', 'detail', 'op must be close or run');
END $$;

-- ui_investigation_read: one request with its texts, for serve's UI login (pgvigil_auth, the ui_ rule)
CREATE OR REPLACE FUNCTION pgvigil.ui_investigation_read(p_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
           'row', to_jsonb(n),
           'request', jsonb_build_object('snapshot', d.snapshot, 'note', d.note, 'question', d.question),
           'report', CASE WHEN n.reported_at IS NOT NULL THEN jsonb_build_object('verdict', n.verdict, 'reported_at', n.reported_at,
                       'summary', d.summary, 'body', d.body, 'evidence', d.evidence, 'queries_run', d.queries_run, 'sql', d.sql) END,
           'journal', coalesce((SELECT jsonb_agg(jsonb_build_object('id', j.id, 'at', j.at, 'event', j.event, 'login', j.login,
                                                                    'rows', j.rows, 'ms', j.ms, 'outcome', j.outcome, 'text', t.text,
                                                                    'detail', t.detail) ORDER BY j.id)
                                  FROM pgvigil.investigation_journal j
                                  LEFT JOIN pgvigil.ui_investigation_journal_text t ON t.journal_id = j.id
                                 WHERE j.investigation_id = n.id), '[]'::jsonb))
    FROM pgvigil.investigations_now n
    LEFT JOIN pgvigil.ui_investigation_data d ON d.investigation_id = n.id
   WHERE n.id = p_id
$$;

-- investigations_purge: requests that ended (reported, closed, expired) more than p_days ago after they were asked;
-- an open or claimed one is never purged. The journal and the texts go with them (ON DELETE CASCADE).
CREATE OR REPLACE FUNCTION pgvigil.investigations_purge(p_days int DEFAULT 90)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_n int;
BEGIN
  DELETE FROM pgvigil.investigations i
   WHERE i.asked_at < now() - make_interval(days => greatest(p_days, 1))
     AND pgvigil.investigation_state_now(i.state, i.expires_at, i.lease_until, i.claims) IN ('reported', 'closed', 'expired');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ---- the agent's door ----------------------------------------------------------------------------------------------
-- agent_login_check: the SESSION user (a role set at connect or in a run is undone by it) must be a member of
-- pgvigil_agent
CREATE OR REPLACE FUNCTION pgvigil.agent_login_check()
RETURNS void LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT pg_has_role(session_user, 'pgvigil_agent', 'MEMBER') THEN
    RAISE EXCEPTION 'the login % is not a member of pgvigil_agent', session_user USING ERRCODE = '42501';
  END IF;
END $$;

-- agent_claim_row: the claim the caller names, held by the caller; refuses with the words of the case
CREATE OR REPLACE FUNCTION pgvigil.agent_claim_row(p_id bigint, p_claim text)
RETURNS pgvigil.investigations LANGUAGE plpgsql AS $$
DECLARE
  r pgvigil.investigations;
BEGIN
  -- locked first, then settled: the settle skips a row another session holds, and a lapse read from the stored state
  -- would pass
  PERFORM 1 FROM pgvigil.investigations WHERE id = p_id FOR UPDATE;
  PERFORM pgvigil.investigations_settle(p_id);
  SELECT * INTO r FROM pgvigil.investigations WHERE id = p_id;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'no investigation %', p_id USING ERRCODE = '22023';
  END IF;
  IF r.claim_hash IS NULL OR r.claimed_login IS DISTINCT FROM session_user::text
     OR r.claim_hash <> sha256(convert_to(coalesce(p_claim, ''), 'UTF8')) THEN
    RAISE EXCEPTION 'not your claim: investigation % is %', p_id,
      CASE WHEN r.state = 'claimed' THEN format('claimed by %s', r.claimed_by) ELSE r.state END USING ERRCODE = '42501';
  END IF;
  IF r.state = 'expired' THEN
    RAISE EXCEPTION 'investigation % expired', p_id USING ERRCODE = '22023';
  END IF;
  IF r.state <> 'claimed' THEN
    RAISE EXCEPTION 'not your claim: investigation % is % (the lease lapsed or it was released)', p_id, r.state USING ERRCODE = '42501';
  END IF;
  RETURN r;
END $$;

-- the list an agent reads (state, kind optional; 1..100 rows, newest last)
CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_list(p_state text, p_kind text, p_limit int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
BEGIN
  PERFORM pgvigil.agent_login_check();
  PERFORM pgvigil.investigations_settle();
  RETURN jsonb_build_object('investigations', coalesce((
    SELECT jsonb_agg(x ORDER BY x.id) FROM (
      SELECT n.id, n.kind, n.instance_id, n.instance_name AS instance, n.setting, n.severity, n.state, n.asked_by, n.asked_at,
             n.expires_at, n.claimed_by, n.lease_until, n.claims, n.verdict
        FROM pgvigil.investigations_now n
       WHERE (p_state IS NULL OR n.state = p_state) AND (p_kind IS NULL OR n.kind = p_kind)
       ORDER BY n.id DESC
       LIMIT least(greatest(coalesce(p_limit, 20), 1), 100)) x), '[]'::jsonb));
END $$;

-- the claim: the first claim of an open request wins; answers the claim id (once), the lease and the brief's facts
CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_claim(p_id bigint, p_agent text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  r      pgvigil.investigations;
  d      pgvigil.ui_investigation_data;
  v_cid  text;
  v_name text := left(nullif(btrim(coalesce(p_agent, '')), ''), 100);
BEGIN
  PERFORM pgvigil.agent_login_check();
  PERFORM 1 FROM pgvigil.investigations WHERE id = p_id FOR UPDATE;   -- locked first, then settled (agent_claim_row)
  PERFORM pgvigil.investigations_settle(p_id);
  SELECT * INTO r FROM pgvigil.investigations WHERE id = p_id;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'no investigation %', p_id USING ERRCODE = '22023';
  ELSIF r.state = 'claimed' THEN
    RAISE EXCEPTION 'investigation % is claimed by % until %', p_id, r.claimed_by, r.lease_until USING ERRCODE = '55000';
  ELSIF r.state = 'expired' THEN
    RAISE EXCEPTION 'investigation % expired', p_id USING ERRCODE = '22023';
  ELSIF r.state <> 'open' THEN
    RAISE EXCEPTION 'investigation % is %', p_id, r.state USING ERRCODE = '22023';
  ELSIF r.claims >= 3 THEN
    RAISE EXCEPTION 'investigation % expired (claimed 3 times)', p_id USING ERRCODE = '22023';
  END IF;
  IF pgvigil.investigation_journal_add(p_id, 'claimed', session_user::text, coalesce(v_name, '')) IS NULL THEN
    RAISE EXCEPTION 'the request''s record is full (195 rows for calls; the last 5 are kept for its end): investigation % takes no more calls - report or release it', p_id USING ERRCODE = '54000';
  END IF;
  v_cid := replace(gen_random_uuid()::text, '-', '');
  UPDATE pgvigil.investigations
     SET state = 'claimed', claimed_by = coalesce(v_name, session_user::text), claimed_login = session_user::text,
         claim_hash = sha256(convert_to(v_cid, 'UTF8')), claimed_at = now(),
         lease_until = least(now() + interval '15 minutes', expires_at), claims = claims + 1
   WHERE id = p_id
  RETURNING * INTO r;
  SELECT * INTO d FROM pgvigil.ui_investigation_data WHERE investigation_id = p_id;
  RETURN jsonb_build_object(
    'claim_id', v_cid, 'lease_until', r.lease_until, 'expires_at', r.expires_at,
    'request', jsonb_build_object('id', r.id, 'kind', r.kind, 'instance_id', r.instance_id, 'instance', r.instance_name,
                                  'setting', r.setting, 'value', r.finding_value, 'severity', r.severity, 'asked_by', r.asked_by, 'asked_at', r.asked_at,
                                  'snapshot', d.snapshot, 'note', d.note, 'question', d.question),
    'earlier_reports', coalesce((
      SELECT jsonb_agg(x ORDER BY x.reported_at DESC) FROM (
        SELECT e.id, e.verdict, left(ed.summary, 500) AS summary, e.reported_at, true AS unreviewed
          FROM pgvigil.investigations e JOIN pgvigil.ui_investigation_data ed ON ed.investigation_id = e.id
         WHERE r.kind = 'finding' AND e.kind = 'finding' AND e.finding_key = r.finding_key
           AND e.id <> r.id AND e.reported_at IS NOT NULL
         ORDER BY e.reported_at DESC LIMIT 5) x), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_renew(p_id bigint, p_claim text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  r pgvigil.investigations;
BEGIN
  PERFORM pgvigil.agent_login_check();
  r := pgvigil.agent_claim_row(p_id, p_claim);
  IF now() >= r.expires_at THEN
    RAISE EXCEPTION 'investigation % expired', p_id USING ERRCODE = '22023';
  END IF;
  IF pgvigil.investigation_journal_add(p_id, 'renewed', session_user::text, 'renewed') IS NULL THEN
    RAISE EXCEPTION 'the request''s record is full (195 rows for calls; the last 5 are kept for its end): investigation % takes no more calls - report or release it', p_id USING ERRCODE = '54000';
  END IF;
  UPDATE pgvigil.investigations SET lease_until = least(now() + interval '15 minutes', expires_at) WHERE id = p_id RETURNING * INTO r;
  RETURN jsonb_build_object('id', p_id, 'lease_until', r.lease_until, 'expires_at', r.expires_at);
END $$;

CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_release(p_id bigint, p_claim text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  r pgvigil.investigations;
BEGIN
  PERFORM pgvigil.agent_login_check();
  r := pgvigil.agent_claim_row(p_id, p_claim);
  IF pgvigil.investigation_journal_add(p_id, 'released', session_user::text, 'released',
                                       nullif(left(btrim(coalesce(p_reason, '')), 1000), '')) IS NULL THEN
    RAISE EXCEPTION 'the request''s record is full (200 rows): investigation % takes no more calls', p_id USING ERRCODE = '54000';
  END IF;
  -- the third claim given back: the request expires (a fourth claim is refused), else it opens again and wakes a wait
  UPDATE pgvigil.investigations SET state = CASE WHEN claims >= 3 THEN 'expired' ELSE 'open' END, lease_until = NULL, claim_hash = NULL
   WHERE id = p_id RETURNING * INTO r;
  IF r.state = 'open' THEN
    PERFORM pg_notify('pgvigil_investigation', p_id::text);
  ELSE
    PERFORM pgvigil.investigation_journal_add(p_id, 'expired', NULL, 'the third claim ended');
  END IF;
  RETURN jsonb_build_object('id', p_id, 'state', r.state);
END $$;

-- the report: a finding's verdict real | false_positive | needs_person, an ask's answered (or needs_person: no answer);
-- sql an ask's alone; the sizes checked with words (the SELECT of an ask is checked to be one SELECT by the door before
-- it calls this)
CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_report(p_id bigint, p_claim text, p_verdict text, p_summary text,
                                                              p_body text, p_evidence jsonb, p_queries jsonb, p_sql text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  r pgvigil.investigations;
BEGIN
  PERFORM pgvigil.agent_login_check();
  r := pgvigil.agent_claim_row(p_id, p_claim);
  IF p_verdict IS NULL OR p_verdict NOT IN ('real', 'false_positive', 'needs_person', 'answered') THEN
    RAISE EXCEPTION 'verdict must be real, false_positive, needs_person or answered' USING ERRCODE = '22023';
  ELSIF nullif(btrim(coalesce(p_summary, '')), '') IS NULL THEN
    RAISE EXCEPTION 'a report has a summary' USING ERRCODE = '22023';
  ELSIF length(p_summary) > 4000 THEN
    RAISE EXCEPTION 'the summary is over 4,000 characters (%)', length(p_summary) USING ERRCODE = '22001';
  ELSIF length(coalesce(p_body, '')) > 8000 THEN
    RAISE EXCEPTION 'the body is over 8,000 characters (%)', length(p_body) USING ERRCODE = '22001';
  ELSIF p_evidence IS NOT NULL AND (jsonb_typeof(p_evidence) <> 'array' OR jsonb_array_length(p_evidence) > 50) THEN
    RAISE EXCEPTION 'evidence is a list of at most 50 entries' USING ERRCODE = '22023';
  ELSIF p_evidence IS NOT NULL AND octet_length(p_evidence::text) > 32768 THEN
    RAISE EXCEPTION 'the evidence is over 32 KB' USING ERRCODE = '22001';
  ELSIF p_queries IS NOT NULL AND (jsonb_typeof(p_queries) <> 'array' OR jsonb_array_length(p_queries) > 20 OR octet_length(p_queries::text) > 65536) THEN
    RAISE EXCEPTION 'queries_run is a list of at most 20 statements (64 KB)' USING ERRCODE = '22023';
  ELSIF length(coalesce(p_sql, '')) > 20000 THEN
    RAISE EXCEPTION 'the sql is over 20,000 characters' USING ERRCODE = '22001';
  ELSIF r.kind = 'finding' AND p_verdict = 'answered' THEN
    RAISE EXCEPTION 'a finding''s verdict is real, false_positive or needs_person' USING ERRCODE = '22023';
  ELSIF r.kind = 'ask' AND p_verdict <> 'answered' AND p_verdict <> 'needs_person' THEN
    RAISE EXCEPTION 'an ask''s verdict is answered (or needs_person)' USING ERRCODE = '22023';
  ELSIF r.kind = 'finding' AND nullif(btrim(coalesce(p_sql, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'only an ask''s answer carries sql: a finding''s suggested statement goes in the body' USING ERRCODE = '22023';
  ELSIF r.kind = 'ask' AND nullif(btrim(coalesce(p_sql, '')), '') IS NULL AND p_verdict = 'answered' THEN
    RAISE EXCEPTION 'an answered ask carries its one SELECT in sql' USING ERRCODE = '22023';
  END IF;
  IF pgvigil.investigation_journal_add(p_id, 'reported', session_user::text, p_verdict) IS NULL THEN
    RAISE EXCEPTION 'the request''s record is full (200 rows): investigation % takes no more calls', p_id USING ERRCODE = '54000';
  END IF;
  UPDATE pgvigil.ui_investigation_data
     SET summary = p_summary, body = nullif(p_body, ''), evidence = p_evidence, queries_run = p_queries,
         sql = nullif(btrim(coalesce(p_sql, '')), '')
   WHERE investigation_id = p_id;
  UPDATE pgvigil.investigations SET state = 'reported', reported_at = now(), verdict = p_verdict, lease_until = NULL WHERE id = p_id;
  RETURN jsonb_build_object('id', p_id, 'state', 'reported');
END $$;

-- the record of a run_select: written FIRST (the run is refused without it), its outcome after
CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_journal_select(p_id bigint, p_claim text, p_sql text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  r   pgvigil.investigations;
  v_j bigint;
BEGIN
  PERFORM pgvigil.agent_login_check();
  r := pgvigil.agent_claim_row(p_id, p_claim);
  v_j := pgvigil.investigation_journal_add(p_id, 'select', session_user::text, 'running', coalesce(p_sql, ''));
  IF v_j IS NULL THEN
    RAISE EXCEPTION 'the request''s record is full (195 rows for calls; the last 5 are kept for its end): investigation % takes no more calls - report or release it', p_id USING ERRCODE = '54000';
  END IF;
  RETURN v_j;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.agent_investigation_journal_done(p_journal bigint, p_rows bigint, p_ms int, p_outcome text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
BEGIN
  PERFORM pgvigil.agent_login_check();
  UPDATE pgvigil.investigation_journal
     SET rows = p_rows, ms = p_ms, outcome = (pgvigil.investigation_outcome(coalesce(p_outcome, 'done'))).word
   WHERE id = p_journal AND event = 'select' AND outcome = 'running' AND login = session_user::text;
  IF FOUND THEN
    UPDATE pgvigil.ui_investigation_journal_text SET detail = (pgvigil.investigation_outcome(p_outcome)).detail
     WHERE journal_id = p_journal;
  END IF;
END $$;

GRANT EXECUTE ON FUNCTION pgvigil.agent_investigation_list(text, text, int), pgvigil.agent_investigation_claim(bigint, text),
  pgvigil.agent_investigation_renew(bigint, text), pgvigil.agent_investigation_release(bigint, text, text),
  pgvigil.agent_investigation_report(bigint, text, text, text, text, jsonb, jsonb, text),
  pgvigil.agent_investigation_journal_select(bigint, text, text),
  pgvigil.agent_investigation_journal_done(bigint, bigint, int, text) TO pgvigil_agent;
