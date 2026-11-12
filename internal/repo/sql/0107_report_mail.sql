-- 0107 reports by e-mail (task 171): any page of the UI mailed now or on a schedule, the mail body the page's own grids
-- as HTML in the screen's colours (the grid tools' HTML copy, gridtools.ts toHtml) and the page's workbook attached
-- (export.ts), through an smtp channel of the alerts: block.
--
--   report_mail_schedules  a page mailed on a schedule: its address in the UI (the route, '#/backups?w=24h'), the
--                          addresses, the smtp channel, the cadence (daily / weekly / a cron line, always stored as
--                          the cron line it is) in a time zone, the workbook on or off, and the next send (next_at,
--                          computed by the server from the cron line: internal/reportmail), the grid choices of the
--                          page as its owner keeps them (grid_prefs: the grid tools' hidden, frozen and barred columns,
--                          so the scheduled mail leaves out what the owner's window leaves out). Edited in place; every
--                          attempt is a report_mail_log row with what it wrote. An ended schedule keeps its row.
--   report_mail_sends      every mail asked: a Send now from the page (kind now), a schedule's turn (scheduled) or a
--                          schedule's Send test (test). The page's HTML and workbook wait here until the alert sender
--                          (pgvigil run) mails them; its answer (sent / failed / refused, the relay's error, the size
--                          of the message) clears the payload and keeps the log line: who, when, to whom, the rows,
--                          the sizes. A scheduled page that could not be rendered is a row with render_error and no
--                          payload: the sender records it failed and alerts, as any failed send.
--   report_mail_log        every attempt from the UI on a schedule or a Send now (done or refused): who, from where,
--                          what. Not purged (an audit, like alert_rule_log).
--
-- Writes from the UI: import_report_mail (a schedule's add / edit / end / enable / disable) and import_report_mail_send
-- (a mail queued), both through the actions door's audit login (pgvigil_collector: apply_roles makes every import_*
-- SECURITY DEFINER and grants it there), behind the UI login. The server's scheduler claims one due schedule at a time
-- with import_report_mail_claim (a lease and a claim token) and queues its rendered page with import_report_mail_send,
-- which takes the turn only with the claim's token: a schedule changed, turned off or claimed again by another server
-- while its page was drawn refuses the stale turn, so two servers on one repository never mail one turn twice. The
-- sender (pgvigil_alerter) reads what is owed (report_mail_due), takes each row before it mails it (report_mail_take: a
-- record that fails after the mail never mails it again) and answers (report_mail_record); report_mail_expire answers
-- what no sender took within the window, or took and never answered, as failed, so the sender alerts it. The serve
-- process never holds a channel's secret: the sender, which already holds it, does the send, as it does a Send test
-- (0093). report_mail_sends is purged after the purge window (a purge() line of the release's join, 0110, named in the
-- slice's report).

CREATE TABLE IF NOT EXISTS pgvigil.report_mail_schedules (
  schedule_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name           text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  route          text NOT NULL CHECK (length(route) <= 500 AND route ~ '^#/[A-Za-z0-9_]+(\?[A-Za-z0-9_.~%=&:+,-]*)?$'),
  page           text CHECK (length(page) <= 200),
  recipients     text[] NOT NULL CHECK (cardinality(recipients) BETWEEN 1 AND 50),
  channel        text NOT NULL CHECK (length(channel) BETWEEN 1 AND 63),
  cadence        text NOT NULL CHECK (cadence IN ('daily', 'weekly', 'cron')),
  cron           text NOT NULL CHECK (length(cron) BETWEEN 9 AND 100),
  timezone       text NOT NULL CHECK (length(timezone) BETWEEN 1 AND 64),
  attach_xlsx    boolean NOT NULL DEFAULT true,
  enabled        boolean NOT NULL DEFAULT true,
  next_at        timestamptz,
  claimed_until  timestamptz,
  claim_token    text,
  grid_prefs     jsonb CHECK (grid_prefs IS NULL OR (jsonb_typeof(grid_prefs) = 'object' AND octet_length(grid_prefs::text) <= 16384)),
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  changed_by     text,
  changed_at     timestamptz,
  ended_by       text,
  ended_at       timestamptz
);
CREATE INDEX IF NOT EXISTS report_mail_schedules_due_idx ON pgvigil.report_mail_schedules (next_at)
  WHERE enabled AND ended_at IS NULL;
COMMENT ON TABLE pgvigil.report_mail_schedules IS 'Pages mailed on a schedule; written through import_report_mail and import_report_mail_claim only; not purged.';

CREATE TABLE IF NOT EXISTS pgvigil.report_mail_sends (
  send_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  schedule_id    bigint REFERENCES pgvigil.report_mail_schedules (schedule_id) ON DELETE SET NULL,
  kind           text NOT NULL CHECK (kind IN ('now', 'scheduled', 'test')),
  name           text NOT NULL,
  route          text NOT NULL,
  requested_by   text NOT NULL,
  requested_at   timestamptz NOT NULL,
  client         text,
  channel        text NOT NULL,
  recipients     text[] NOT NULL,
  subject        text NOT NULL,
  html           text CHECK (octet_length(html) <= 4194304),
  xlsx           bytea CHECK (octet_length(xlsx) <= 8388608),
  xlsx_name      text,
  grids          int,
  rows           int,
  html_bytes     int,
  xlsx_bytes     int,
  render_error   text,
  taken_at       timestamptz,
  done_at        timestamptz,
  outcome        text CHECK (outcome IN ('sent', 'failed', 'refused')),
  error          text,
  mail_bytes     int
);
CREATE INDEX IF NOT EXISTS report_mail_sends_due_idx ON pgvigil.report_mail_sends (requested_at) WHERE done_at IS NULL;
CREATE INDEX IF NOT EXISTS report_mail_sends_at_idx ON pgvigil.report_mail_sends (requested_at DESC);
CREATE INDEX IF NOT EXISTS report_mail_sends_schedule_idx ON pgvigil.report_mail_sends (schedule_id, requested_at DESC);
COMMENT ON TABLE pgvigil.report_mail_sends IS 'Every report mail asked and the sender''s answer; written through import_report_mail_send and report_mail_record only; the payload is cleared once answered.';
GRANT SELECT, UPDATE (taken_at, done_at, outcome, error, mail_bytes, html, xlsx) ON pgvigil.report_mail_sends TO pgvigil_alerter;

CREATE TABLE IF NOT EXISTS pgvigil.report_mail_log (
  log_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at           timestamptz NOT NULL,
  ui_user      text NOT NULL,
  client       text,
  op           text NOT NULL,
  schedule_id  bigint,
  send_id      bigint,
  outcome      text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail       text,
  payload      jsonb
);
CREATE INDEX IF NOT EXISTS report_mail_log_at_idx ON pgvigil.report_mail_log (at DESC);
COMMENT ON TABLE pgvigil.report_mail_log IS 'Every report mail attempt from the UI, done or refused; not purged (an audit).';

-- the window a queued mail waits for a sender: past it the page says no sender answered
CREATE OR REPLACE FUNCTION pgvigil.report_mail_window()
RETURNS interval LANGUAGE sql IMMUTABLE AS $$ SELECT interval '1 hour' $$;

-- the Send now and Send test mails one UI user may ask in an hour (each reaches real addresses)
CREATE OR REPLACE FUNCTION pgvigil.report_mail_hourly_cap()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 30 $$;

-- report_mail_why: why a schedule's or a mail's fields are refused, NULL when they are good. p_need_route: a schedule
-- or a mail names the page it is; p_tz: a schedule's zone (NULL for a mail).
CREATE OR REPLACE FUNCTION pgvigil.report_mail_why(p_name text, p_route text, p_recipients text[], p_channel text, p_tz text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_bad text;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 THEN
    RETURN 'a name of 1 to 120 characters is required';
  END IF;
  IF p_route IS NULL OR length(p_route) > 500 OR p_route !~ '^#/[A-Za-z0-9_]+(\?[A-Za-z0-9_.~%=&:+,-]*)?$' THEN
    RETURN 'the page is the address of a page of this UI (#/<tab>?...)';
  END IF;
  IF p_recipients IS NULL OR cardinality(p_recipients) NOT BETWEEN 1 AND 50 THEN
    RETURN 'one to 50 addresses are required';
  END IF;
  SELECT r INTO v_bad FROM unnest(p_recipients) r
   WHERE r IS NULL OR length(r) > 254 OR r !~ '^[^@\s<>,;"()\[\]\\]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
   LIMIT 1;
  IF FOUND THEN
    RETURN format('%s is not a mail address', coalesce(v_bad, 'an empty entry'));
  END IF;
  IF p_channel IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = p_channel AND c.kind = 'smtp' AND c.is_configured) THEN
    RETURN format('%s is not an smtp channel of the alerts: block (the sender''s last record of its channels)', coalesce(p_channel, 'no channel'));
  END IF;
  IF p_tz IS NOT NULL THEN
    BEGIN
      PERFORM now() AT TIME ZONE p_tz;
    EXCEPTION WHEN invalid_parameter_value THEN
      RETURN format('%s is not a time zone', p_tz);
    END;
    IF p_tz !~ '^[A-Za-z][A-Za-z0-9_+/-]{0,63}$' THEN
      RETURN format('%s is not a time zone name (an IANA name, America/Los_Angeles, or UTC)', p_tz);
    END IF;
  END IF;
  RETURN NULL;
END $$;

-- import_report_mail: one attempt on a schedule from the UI. p_payload: {op, ui_user, client} and
--   add:     name, route, page, recipients, channel, cadence, cron, timezone, attach_xlsx, enabled, next_at
--   edit:    schedule_id and the fields of add (a live schedule only; its claim is dropped)
--   end:     schedule_id (the row stays, ended)
--   enable / disable: schedule_id; enable takes next_at
-- next_at is the server's (internal/reportmail: the cron line's next time in the zone); this function checks only
-- that it is in the future. Every attempt leaves a report_mail_log row; a refused one changes nothing else. Returns
-- {outcome, detail, schedule_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_report_mail(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_name    text := btrim(coalesce(p_payload->>'name', ''));
  v_route   text := p_payload->>'route';
  v_page    text := left(nullif(btrim(coalesce(p_payload->>'page', '')), ''), 200);
  v_chan    text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_cadence text := p_payload->>'cadence';
  v_cron    text := btrim(coalesce(p_payload->>'cron', ''));
  v_tz      text := nullif(btrim(coalesce(p_payload->>'timezone', '')), '');
  v_xlsx    boolean := coalesce((p_payload->>'attach_xlsx')::boolean, true);
  v_enabled boolean := coalesce((p_payload->>'enabled')::boolean, true);
  v_prefs   jsonb := CASE WHEN jsonb_typeof(p_payload->'grid_prefs') = 'object' THEN p_payload->'grid_prefs' END;
  v_rcpt    text[];
  v_next    timestamptz;
  v_id      bigint;
  v_old     pgvigil.report_mail_schedules;
  v_why     text;
  v_done    text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_report_mail: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload->'recipients') = 'array' THEN
    SELECT array_agg(lower(btrim(r)) ORDER BY o) INTO v_rcpt FROM jsonb_array_elements_text(p_payload->'recipients') WITH ORDINALITY AS a(r, o);
  END IF;
  IF coalesce(p_payload->>'next_at', '') <> '' THEN
    BEGIN
      v_next := (p_payload->>'next_at')::timestamptz;
    EXCEPTION WHEN others THEN
      v_why := 'next_at is not a time';
    END;
  END IF;
  IF coalesce(p_payload->>'schedule_id', '') ~ '^[0-9]{1,18}$' THEN
    v_id := (p_payload->>'schedule_id')::bigint;
    SELECT * INTO v_old FROM pgvigil.report_mail_schedules WHERE schedule_id = v_id FOR UPDATE;
  END IF;

  IF v_why IS NOT NULL THEN
    NULL;
  ELSIF v_op NOT IN ('add', 'edit', 'end', 'enable', 'disable') OR v_op IS NULL THEN
    v_why := format('op %s is not add, edit, end, enable or disable', coalesce(v_op, '(none)'));
  ELSIF v_op <> 'add' AND v_old.schedule_id IS NULL THEN
    v_why := format('no schedule %s', coalesce(p_payload->>'schedule_id', '(none)'));
  ELSIF v_op <> 'add' AND v_old.ended_at IS NOT NULL THEN
    v_why := format('schedule %s was ended by %s at %s', v_id, v_old.ended_by, v_old.ended_at);
  ELSIF v_op IN ('add', 'edit') THEN
    v_why := pgvigil.report_mail_why(v_name, v_route, v_rcpt, v_chan, v_tz);
    IF v_why IS NULL AND (v_cadence IS NULL OR v_cadence NOT IN ('daily', 'weekly', 'cron')) THEN
      v_why := 'the cadence is daily, weekly or cron';
    ELSIF v_why IS NULL AND length(v_cron) NOT BETWEEN 9 AND 100 THEN
      v_why := 'the schedule needs its cron line (five fields)';
    ELSIF v_why IS NULL AND v_tz IS NULL THEN
      v_why := 'the schedule needs its time zone';
    ELSIF v_why IS NULL AND (v_next IS NULL OR v_next <= p_at) THEN
      v_why := 'the next send must be in the future';
    ELSIF v_why IS NULL AND v_prefs IS NOT NULL AND (octet_length(v_prefs::text) > 16384
          OR EXISTS (SELECT 1 FROM jsonb_each(v_prefs) e WHERE e.key NOT LIKE 'pgvigil.grid.%' OR length(e.key) > 200 OR jsonb_typeof(e.value) <> 'string')) THEN
      v_why := 'the grid choices are the grid tools'' own (pgvigil.grid.* keys with text values, at most 16 KB)';
    END IF;
  ELSIF v_op = 'enable' AND (v_next IS NULL OR v_next <= p_at) THEN
    v_why := 'the next send must be in the future';
  END IF;

  IF v_why IS NULL THEN
    CASE v_op
    WHEN 'add' THEN
      INSERT INTO pgvigil.report_mail_schedules (name, route, page, recipients, channel, cadence, cron, timezone, attach_xlsx,
                                                 enabled, next_at, grid_prefs, created_by, created_at, client)
      VALUES (v_name, v_route, v_page, v_rcpt, v_chan, v_cadence, v_cron, v_tz, v_xlsx, v_enabled, v_next, v_prefs,
              left(v_user, 200), p_at, left(v_client, 100))
      RETURNING schedule_id INTO v_id;
      v_done := format('schedule %s added: %s, next send %s', v_id, v_name, v_next);
    WHEN 'edit' THEN
      UPDATE pgvigil.report_mail_schedules
         SET name = v_name, route = v_route, page = v_page, recipients = v_rcpt, channel = v_chan, cadence = v_cadence,
             cron = v_cron, timezone = v_tz, attach_xlsx = v_xlsx, enabled = v_enabled, next_at = v_next,
             grid_prefs = CASE WHEN p_payload ? 'grid_prefs' THEN v_prefs ELSE grid_prefs END,
             claimed_until = NULL, claim_token = NULL, changed_by = left(v_user, 200), changed_at = p_at
       WHERE schedule_id = v_id;
      v_done := format('schedule %s changed, next send %s', v_id, v_next);
    WHEN 'end' THEN
      UPDATE pgvigil.report_mail_schedules SET enabled = false, claimed_until = NULL, claim_token = NULL, ended_by = left(v_user, 200), ended_at = p_at
       WHERE schedule_id = v_id;
      v_done := format('schedule %s ended', v_id);
    WHEN 'enable' THEN
      UPDATE pgvigil.report_mail_schedules SET enabled = true, next_at = v_next, claimed_until = NULL, claim_token = NULL, changed_by = left(v_user, 200), changed_at = p_at
       WHERE schedule_id = v_id;
      v_done := format('schedule %s on, next send %s', v_id, v_next);
    ELSE
      UPDATE pgvigil.report_mail_schedules SET enabled = false, claimed_until = NULL, claim_token = NULL, changed_by = left(v_user, 200), changed_at = p_at
       WHERE schedule_id = v_id;
      v_done := format('schedule %s off', v_id);
    END CASE;
  END IF;
  INSERT INTO pgvigil.report_mail_log (at, ui_user, client, op, schedule_id, outcome, detail, payload)
  VALUES (p_at, left(v_user, 200), left(v_client, 100), left(coalesce(v_op, ''), 20), v_id,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, left(coalesce(v_why, v_done), 2000),
          p_payload - 'ui_user' - 'client' - 'grid_prefs');
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'schedule_id', v_id);
END $$;

-- import_report_mail_claim: at most p_limit of the schedules due at p_at that no server holds (enabled, live, next_at
-- reached, no lease or an expired one), each leased for p_lease_secs with a new claim token. The claimer renders the
-- page and queues it with that token (import_report_mail_send kind scheduled), which moves next_at on and drops the
-- lease; a server claims one at a time, just before its render, so a lease is never spent on a queue of renders.
CREATE OR REPLACE FUNCTION pgvigil.import_report_mail_claim(p_at timestamptz, p_lease_secs int, p_limit int)
RETURNS TABLE (schedule_id bigint, name text, route text, recipients text[], channel text, cron text, timezone text,
               attach_xlsx boolean, created_by text, next_at timestamptz, claim_token text, grid_prefs jsonb)
LANGUAGE sql AS $$
  WITH due AS (
    SELECT s.schedule_id FROM pgvigil.report_mail_schedules s
     WHERE s.enabled AND s.ended_at IS NULL AND s.next_at <= p_at
       AND (s.claimed_until IS NULL OR s.claimed_until < p_at)
     ORDER BY s.next_at
     LIMIT greatest(1, least(coalesce(p_limit, 1), 20))
       FOR UPDATE SKIP LOCKED
  )
  UPDATE pgvigil.report_mail_schedules s
     SET claimed_until = p_at + make_interval(secs => greatest(60, least(coalesce(p_lease_secs, 600), 3600))),
         claim_token = md5(random()::text || clock_timestamp()::text || s.schedule_id::text)
    FROM due WHERE s.schedule_id = due.schedule_id
  RETURNING s.schedule_id, s.name, s.route, s.recipients, s.channel, s.cron, s.timezone, s.attach_xlsx, s.created_by, s.next_at,
            s.claim_token, s.grid_prefs
$$;

-- import_report_mail_send: one mail queued for the sender. p_payload: {ui_user, client, kind, name, route, channel,
-- recipients, subject, html, xlsx (base64), xlsx_name, grids, rows} and
--   now:        the page as the window shows it, asked by ui_user (at most report_mail_hourly_cap() an hour with test)
--   test:       a schedule's page rendered now (schedule_id), asked by ui_user, under the same cap
--   scheduled:  a claimed schedule's turn (schedule_id, claim: the claim's token, next_at: the turn after this one);
--               render_error instead of the payload when the page could not be rendered. ui_user is the schedule's
--               owner. A turn whose claim is no longer the schedule's (changed, turned off, ended or claimed again
--               while its page was drawn) is refused and moves nothing. Otherwise the lease is dropped and next_at moved
--               on whether the mail is queued or failed, so a broken page never mails in a loop.
-- Every attempt leaves a report_mail_sends row (a refused one with outcome refused) and a report_mail_log row.
-- Returns {outcome, detail, send_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_report_mail_send(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_kind    text := p_payload->>'kind';
  v_name    text := btrim(coalesce(p_payload->>'name', ''));
  v_route   text := p_payload->>'route';
  v_chan    text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_subject text := btrim(coalesce(p_payload->>'subject', ''));
  v_html    text := p_payload->>'html';
  v_b64     text := nullif(p_payload->>'xlsx', '');
  v_xname   text := left(nullif(btrim(coalesce(p_payload->>'xlsx_name', '')), ''), 200);
  v_rerr    text := left(nullif(btrim(coalesce(p_payload->>'render_error', '')), ''), 2000);
  v_grids   int;
  v_rows    int;
  v_xlsx    bytea;
  v_rcpt    text[];
  v_next    timestamptz;
  v_sid     bigint;
  v_sched   pgvigil.report_mail_schedules;
  v_why     text;
  v_id      bigint;
  v_n       int;
  v_moved   boolean := false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_report_mail_send: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload->'recipients') = 'array' THEN
    SELECT array_agg(lower(btrim(r)) ORDER BY o) INTO v_rcpt FROM jsonb_array_elements_text(p_payload->'recipients') WITH ORDINALITY AS a(r, o);
  END IF;
  IF coalesce(p_payload->>'grids', '') ~ '^[0-9]{1,6}$' THEN v_grids := (p_payload->>'grids')::int; END IF;
  IF coalesce(p_payload->>'rows', '') ~ '^[0-9]{1,9}$' THEN v_rows := (p_payload->>'rows')::int; END IF;
  IF coalesce(p_payload->>'schedule_id', '') ~ '^[0-9]{1,18}$' THEN
    v_sid := (p_payload->>'schedule_id')::bigint;
    SELECT * INTO v_sched FROM pgvigil.report_mail_schedules WHERE schedule_id = v_sid FOR UPDATE;
  END IF;
  IF coalesce(p_payload->>'next_at', '') <> '' THEN
    BEGIN
      v_next := (p_payload->>'next_at')::timestamptz;
    EXCEPTION WHEN others THEN
      v_why := 'next_at is not a time';
    END;
  END IF;
  IF v_b64 IS NOT NULL THEN
    BEGIN
      v_xlsx := decode(v_b64, 'base64');
    EXCEPTION WHEN others THEN
      v_why := coalesce(v_why, 'the workbook is not base64');
    END;
  END IF;

  IF v_why IS NOT NULL THEN
    NULL;
  ELSIF v_kind IS NULL OR v_kind NOT IN ('now', 'scheduled', 'test') THEN
    v_why := format('kind %s is not now, scheduled or test', coalesce(v_kind, '(none)'));
  ELSIF v_kind <> 'now' AND v_sched.schedule_id IS NULL THEN
    v_why := format('no schedule %s', coalesce(p_payload->>'schedule_id', '(none)'));
  ELSIF v_kind <> 'now' AND v_sched.ended_at IS NOT NULL THEN
    v_why := format('schedule %s was ended by %s at %s', v_sid, v_sched.ended_by, v_sched.ended_at);
  ELSIF v_kind = 'scheduled' AND (v_sched.claim_token IS NULL OR v_sched.claim_token IS DISTINCT FROM nullif(p_payload->>'claim', '') OR NOT v_sched.enabled) THEN
    v_why := format('schedule %s''s turn was no longer this server''s (changed, turned off or claimed again while its page was drawn): not mailed', v_sid);
  ELSIF v_kind = 'scheduled' AND (v_next IS NULL OR v_next <= p_at) THEN
    v_why := 'a scheduled send names the turn after it (next_at, in the future)';
  END IF;
  IF v_why IS NULL AND v_kind = 'scheduled' THEN
    -- a turn is mailed or refused once: the schedule moves on either way
    UPDATE pgvigil.report_mail_schedules SET next_at = v_next, claimed_until = NULL, claim_token = NULL WHERE schedule_id = v_sid;
    v_moved := true;
  END IF;
  IF v_why IS NULL THEN
    v_why := pgvigil.report_mail_why(v_name, v_route, v_rcpt, v_chan, NULL);
  END IF;
  IF v_why IS NULL AND v_rerr IS NULL THEN
    IF length(v_subject) NOT BETWEEN 1 AND 200 OR v_subject ~ '[\r\n]' THEN
      v_why := 'a subject of 1 to 200 characters on one line is required';
    ELSIF v_html IS NULL OR length(v_html) < 20 THEN
      v_why := 'the mail has no body: the page drew no grid';
    ELSIF octet_length(v_html) > 4194304 THEN
      v_why := format('the page''s grids make a mail body of %s MB, over the 4 MB a mail carries: narrow the window or filter the grid', round(octet_length(v_html) / 1048576.0, 1));
    ELSIF v_html ~* '<\s*(script|iframe|object|embed|form|link|style|base|svg|math|img|a|meta\s+http-equiv)\M' OR v_html ~* '<[^>]*[\s/"'']on[a-z]+\s*=' OR v_html ~* '<[^>]*(java|vb)\s*script' OR v_html ~* '<[^>]*&#' THEN
      v_why := 'the mail body holds active content (a script, a frame, a form or an event attribute): refused';
    ELSIF v_xlsx IS NOT NULL AND octet_length(v_xlsx) > 8388608 THEN
      v_why := format('the workbook is %s MB, over the 8 MB a mail carries', round(octet_length(v_xlsx) / 1048576.0, 1));
    ELSIF v_xlsx IS NOT NULL AND substr(v_xlsx, 1, 4) <> '\x504b0304'::bytea THEN
      v_why := 'the workbook is not a zip (.xlsx)';
    END IF;
  END IF;
  -- a scheduled turn the checks refuse is queued as a failed render: the sender records it failed and alerts
  IF v_moved AND v_why IS NOT NULL THEN
    v_rerr := left(coalesce(v_rerr || '; ', '') || v_why, 2000);
    v_why := NULL;
  END IF;
  IF v_why IS NULL AND v_kind IN ('now', 'test') THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.report_mail_sends:' || v_user, 0));
    SELECT count(*) INTO v_n FROM pgvigil.report_mail_sends s
     WHERE s.requested_by = v_user AND s.kind IN ('now', 'test') AND s.outcome IS DISTINCT FROM 'refused'
       AND s.requested_at > p_at - interval '1 hour';
    IF v_n >= pgvigil.report_mail_hourly_cap() THEN
      v_why := format('%s asked %s mails in the last hour: at most %s an hour', v_user, v_n, pgvigil.report_mail_hourly_cap());
    END IF;
  END IF;

  INSERT INTO pgvigil.report_mail_sends (schedule_id, kind, name, route, requested_by, requested_at, client, channel,
                                         recipients, subject, html, xlsx, xlsx_name, grids, rows, html_bytes, xlsx_bytes,
                                         render_error, done_at, outcome, error)
  VALUES (v_sid, coalesce(v_kind, 'now'), left(coalesce(nullif(v_name, ''), '(no name)'), 120), left(coalesce(v_route, ''), 500),
          left(v_user, 200), p_at, left(v_client, 100), left(coalesce(v_chan, ''), 63), coalesce(v_rcpt, '{}'),
          left(coalesce(nullif(v_subject, ''), v_name, ''), 200),
          CASE WHEN v_why IS NULL AND v_rerr IS NULL THEN v_html END, CASE WHEN v_why IS NULL AND v_rerr IS NULL THEN v_xlsx END,
          v_xname, v_grids, v_rows, octet_length(v_html), octet_length(v_xlsx), v_rerr,
          CASE WHEN v_why IS NOT NULL THEN p_at END, CASE WHEN v_why IS NOT NULL THEN 'refused' END, v_why)
  RETURNING send_id INTO v_id;
  INSERT INTO pgvigil.report_mail_log (at, ui_user, client, op, schedule_id, send_id, outcome, detail, payload)
  VALUES (p_at, left(v_user, 200), left(v_client, 100), 'send ' || left(coalesce(v_kind, ''), 12), v_sid, v_id,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          left(coalesce(v_why, format('mail %s queued for %s: the sender''s next pass mails it', v_id, array_to_string(v_rcpt, ', '))), 2000),
          p_payload - 'ui_user' - 'client' - 'html' - 'xlsx');
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, format('mail %s queued: the sender''s next pass mails it (within a minute while pgvigil run is up)', v_id)),
                            'send_id', v_id);
END $$;

-- report_mail_due: the mails a sender owes at p_at (queued within the window, not taken, unanswered), oldest first;
-- their payload is read one mail at a time (report_mail_payload), never twenty at once
CREATE OR REPLACE FUNCTION pgvigil.report_mail_due(p_at timestamptz)
RETURNS TABLE (send_id bigint, kind text, name text, channel text, recipients text[], subject text, xlsx_name text,
               render_error text, requested_by text, requested_at timestamptz, schedule_id bigint, route text)
LANGUAGE sql STABLE AS $$
  SELECT s.send_id, s.kind, s.name, s.channel, s.recipients, s.subject, s.xlsx_name, s.render_error,
         s.requested_by, s.requested_at, s.schedule_id, s.route
    FROM pgvigil.report_mail_sends s
   WHERE s.done_at IS NULL AND s.taken_at IS NULL
     AND s.requested_at > p_at - pgvigil.report_mail_window() AND s.requested_at <= p_at
   ORDER BY s.requested_at
   LIMIT 20
$$;

-- report_mail_payload: one owed mail's HTML and workbook
CREATE OR REPLACE FUNCTION pgvigil.report_mail_payload(p_send_id bigint)
RETURNS TABLE (html text, xlsx bytea)
LANGUAGE sql STABLE AS $$
  SELECT s.html, s.xlsx FROM pgvigil.report_mail_sends s WHERE s.send_id = p_send_id AND s.done_at IS NULL
$$;

-- report_mail_take: the sender takes one owed mail before it mails it (true = taken here); a taken row is never owed
-- again, so a record that fails after the mail never mails it twice (report_mail_expire answers it)
CREATE OR REPLACE FUNCTION pgvigil.report_mail_take(p_at timestamptz, p_send_id bigint)
RETURNS boolean LANGUAGE sql AS $$
  WITH t AS (
    UPDATE pgvigil.report_mail_sends SET taken_at = p_at
     WHERE send_id = p_send_id AND taken_at IS NULL AND done_at IS NULL
    RETURNING true AS taken
  )
  SELECT coalesce((SELECT taken FROM t), false)
$$;

-- report_mail_expire: the mails no sender took within the window, and the ones taken and not answered within 15
-- minutes, answered failed (the payload goes); the sender alerts each one it returns
CREATE OR REPLACE FUNCTION pgvigil.report_mail_expire(p_at timestamptz)
RETURNS TABLE (send_id bigint, kind text, name text, channel text, recipients text[], requested_by text, requested_at timestamptz,
               route text, error text)
LANGUAGE sql AS $$
  UPDATE pgvigil.report_mail_sends s
     SET done_at = p_at, outcome = 'failed', html = NULL, xlsx = NULL,
         error = CASE WHEN s.taken_at IS NOT NULL
                      THEN format('the sender took the mail at %s and recorded no answer: it may or may not have reached the relay', s.taken_at)
                      ELSE format('no sender answered within %s (is pgvigil run up with the channel %s?)', pgvigil.report_mail_window(), s.channel) END
   WHERE s.done_at IS NULL
     AND ((s.taken_at IS NULL AND s.requested_at <= p_at - pgvigil.report_mail_window())
          OR (s.taken_at IS NOT NULL AND s.taken_at <= p_at - interval '15 minutes'))
  RETURNING s.send_id, s.kind, s.name, s.channel, s.recipients, s.requested_by, s.requested_at, s.route, s.error
$$;

-- report_mail_record: the sender's answer to one mail (an answered one is left as it is); the payload goes
CREATE OR REPLACE FUNCTION pgvigil.report_mail_record(p_at timestamptz, p_send_id bigint, p_outcome text, p_error text, p_mail_bytes int)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.report_mail_sends
     SET done_at = p_at, outcome = p_outcome, error = left(nullif(p_error, ''), 2000), mail_bytes = p_mail_bytes, html = NULL, xlsx = NULL
   WHERE send_id = p_send_id AND done_at IS NULL
$$;
GRANT EXECUTE ON FUNCTION pgvigil.report_mail_due(timestamptz), pgvigil.report_mail_payload(bigint),
  pgvigil.report_mail_take(timestamptz, bigint), pgvigil.report_mail_expire(timestamptz),
  pgvigil.report_mail_record(timestamptz, bigint, text, text, int), pgvigil.report_mail_window() TO pgvigil_alerter;
