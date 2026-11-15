-- 0258 the Daily checks mail: one switch that keeps exactly one report mail schedule of the Daily checks page
-- (#/checks?w=24h, named 'Daily checks', daily at an hour in a time zone). Report mail (0107) already mails any page on
-- a schedule; this adds the schedule a setting keeps, so a site turns the daily mail on in one place.
--
--   kept_as   on report_mail_schedules: NULL for a schedule a person makes; 'daily_checks' for the kept one. A partial
--             unique index holds it to ONE live row (ended rows stay, as every ended schedule does).
--   kept_by   who keeps it: 'file' (pgvigil.yaml reports.daily_checks, applied by serve at its start) or 'page' (an
--             admin's Mail daily on the Daily checks page). created_by cannot say: it is the user the page is drawn as.
--
-- import_report_mail_kept is the kept row's ONLY writer (ops keep and drop), through the actions door's audit login
-- like every import_* (apply_roles makes it SECURITY DEFINER and grants it to pgvigil_collector):
--   - it takes an advisory lock first, so two servers applying the setting at once answer in turn (the second
--     'unchanged'); the index is the backstop;
--   - keep compares what is asked with the live row on the values as they are stored (addresses and the user in lower
--     case, the cron line): equal is 'unchanged' - nothing written, nothing logged, the next send and a server's claim
--     untouched; different updates the SAME schedule_id (the owner too: the next turn is drawn as the new user) and
--     drops the claim, so a turn drawn from the old values is refused and drawn again from the new ones;
--   - the page's op on a row the file keeps is refused; the file's op takes over or ends a row the page made (the
--     file wins);
--   - a done or refused attempt is a report_mail_log row; 'unchanged' is not.
-- import_report_mail (0107's, re-created whole with one refusal more) no longer edits, ends or turns off a kept row:
-- the Report mail page shows it with a note in place of those buttons, and its Send test stays.

ALTER TABLE pgvigil.report_mail_schedules
  ADD COLUMN IF NOT EXISTS kept_as text CHECK (kept_as IS NULL OR kept_as IN ('daily_checks')),
  ADD COLUMN IF NOT EXISTS kept_by text CHECK (kept_by IS NULL OR kept_by IN ('file', 'page'));
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'report_mail_schedules_kept_pair'
                    AND conrelid = 'pgvigil.report_mail_schedules'::regclass) THEN
    ALTER TABLE pgvigil.report_mail_schedules
      ADD CONSTRAINT report_mail_schedules_kept_pair CHECK ((kept_as IS NULL) = (kept_by IS NULL));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS report_mail_schedules_kept_idx ON pgvigil.report_mail_schedules (kept_as)
  WHERE kept_as IS NOT NULL AND ended_at IS NULL;

-- the kept schedule's fixed fields, in one place for the function, the server and the page
CREATE OR REPLACE FUNCTION pgvigil.report_mail_kept_route(p_kept_as text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT CASE p_kept_as WHEN 'daily_checks' THEN '#/checks?w=24h' END $$;
CREATE OR REPLACE FUNCTION pgvigil.report_mail_kept_name(p_kept_as text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT CASE p_kept_as WHEN 'daily_checks' THEN 'Daily checks' END $$;

-- import_report_mail_kept: one attempt on the kept schedule. p_payload: {op, by, ui_user, client, kept_as} and
--   keep:  as (the UI user the page is drawn as), recipients, channel, cron (a daily line, 'M H * * *': a minute
--          0-59 and an hour 0-23 without a leading zero, as internal/reportmail CronFor writes it), timezone,
--          attach_xlsx, next_at (the server's: the cron line's next time in the zone; checked only to be in the future,
--          and used only when the row is made or its hour or zone changes)
--   drop:  nothing more (the live row is ended; no live row is 'unchanged')
-- by is 'file' or 'page'; ui_user is who asks, for the log ('pgvigil.yaml', or the admin's name). Returns {outcome,
-- detail, schedule_id}, outcome done / unchanged / refused.
CREATE OR REPLACE FUNCTION pgvigil.import_report_mail_kept(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_by      text := p_payload->>'by';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_kept    text := coalesce(nullif(p_payload->>'kept_as', ''), 'daily_checks');
  v_as      text := lower(nullif(btrim(coalesce(p_payload->>'as', '')), ''));
  v_chan    text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_cron    text := btrim(coalesce(p_payload->>'cron', ''));
  v_tz      text := nullif(btrim(coalesce(p_payload->>'timezone', '')), '');
  v_xlsx    boolean := coalesce((p_payload->>'attach_xlsx')::boolean, true);
  v_name    text;
  v_route   text;
  v_rcpt    text[];
  v_next    timestamptz;
  v_id      bigint;
  v_old     pgvigil.report_mail_schedules;
  v_why     text;
  v_done    text;
  v_moved   boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_report_mail_kept: no ui_user' USING ERRCODE = '22023';
  END IF;
  v_name := pgvigil.report_mail_kept_name(v_kept);
  v_route := pgvigil.report_mail_kept_route(v_kept);
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

  IF v_why IS NOT NULL THEN
    NULL;
  ELSIF v_name IS NULL THEN
    v_why := format('%s is not a kept schedule (daily_checks)', v_kept);
  ELSIF v_op NOT IN ('keep', 'drop') OR v_op IS NULL THEN
    v_why := format('op %s is not keep or drop', coalesce(v_op, '(none)'));
  ELSIF v_by NOT IN ('file', 'page') OR v_by IS NULL THEN
    v_why := format('by %s is not file or page', coalesce(v_by, '(none)'));
  END IF;

  IF v_why IS NULL THEN
    -- one writer at a time per kept schedule: the second waits and then reads what the first wrote
    PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.report_mail_kept:' || v_kept, 0));
    SELECT * INTO v_old FROM pgvigil.report_mail_schedules WHERE kept_as = v_kept AND ended_at IS NULL FOR UPDATE;
    v_id := v_old.schedule_id;
    IF v_by = 'page' AND v_old.kept_by = 'file' THEN
      v_why := 'the Daily checks mail is kept by pgvigil.yaml (reports.daily_checks): change it there';
    ELSIF v_op = 'drop' THEN
      IF v_old.schedule_id IS NULL THEN
        RETURN jsonb_build_object('outcome', 'unchanged', 'detail', 'no Daily checks mail is kept', 'schedule_id', NULL);
      END IF;
      UPDATE pgvigil.report_mail_schedules
         SET enabled = false, claimed_until = NULL, claim_token = NULL, ended_by = left(v_user, 200), ended_at = p_at
       WHERE schedule_id = v_id;
      v_done := format('schedule %s ended: the Daily checks mail is off', v_id);
    ELSE
      IF v_as IS NULL THEN
        v_why := 'the Daily checks mail needs the UI user its page is drawn as';
      ELSE
        v_why := pgvigil.report_mail_why(v_name, v_route, v_rcpt, v_chan, v_tz);
      END IF;
      IF v_why IS NULL AND v_tz IS NULL THEN
        v_why := 'the Daily checks mail needs its time zone';
      ELSIF v_why IS NULL AND v_cron !~ '^([0-9]|[1-5][0-9]) ([0-9]|1[0-9]|2[0-3]) [*] [*] [*]$' THEN
        -- a minute 0-59 and an hour 0-23 as the server writes them (no leading zero): equal settings compare equal
        v_why := 'the Daily checks mail is sent once a day: its cron line is M H * * * (a minute 0-59, an hour 0-23)';
      END IF;
      IF v_why IS NULL AND v_old.schedule_id IS NOT NULL
         AND v_old.recipients = v_rcpt AND v_old.channel = v_chan AND v_old.cron = v_cron AND v_old.timezone = v_tz
         AND v_old.created_by = v_as AND v_old.kept_by = v_by AND v_old.attach_xlsx = v_xlsx AND v_old.enabled
         AND v_old.route = v_route AND v_old.name = v_name THEN
        RETURN jsonb_build_object('outcome', 'unchanged',
                                  'detail', format('schedule %s is as asked, next send %s', v_id, v_old.next_at), 'schedule_id', v_id);
      END IF;
      -- the next send moves only with the hour or the zone (or on a row that has none): other changes keep the turn
      v_moved := v_old.schedule_id IS NULL OR v_old.next_at IS NULL OR NOT v_old.enabled
                 OR v_old.cron IS DISTINCT FROM v_cron OR v_old.timezone IS DISTINCT FROM v_tz;
      IF v_why IS NULL AND v_moved AND (v_next IS NULL OR v_next <= p_at) THEN
        v_why := 'the next send must be in the future';
      END IF;
      IF v_why IS NULL AND v_old.schedule_id IS NULL THEN
        BEGIN
          INSERT INTO pgvigil.report_mail_schedules (name, route, page, recipients, channel, cadence, cron, timezone, attach_xlsx,
                                                     enabled, next_at, created_by, created_at, client, kept_as, kept_by)
          VALUES (v_name, v_route, v_name, v_rcpt, v_chan, 'daily', v_cron, v_tz, v_xlsx, true, v_next,
                  left(v_as, 200), p_at, left(v_client, 100), v_kept, v_by)
          RETURNING schedule_id INTO v_id;
          v_done := format('schedule %s kept: %s, drawn as %s, next send %s', v_id, v_name, v_as, v_next);
        EXCEPTION WHEN unique_violation THEN
          v_why := 'another live Daily checks mail exists: nothing was written';
        END;
      ELSIF v_why IS NULL THEN
        UPDATE pgvigil.report_mail_schedules
           SET name = v_name, route = v_route, page = v_name, recipients = v_rcpt, channel = v_chan, cadence = 'daily', cron = v_cron,
               timezone = v_tz, attach_xlsx = v_xlsx, enabled = true, next_at = CASE WHEN v_moved THEN v_next ELSE next_at END,
               created_by = left(v_as, 200), kept_by = v_by, claimed_until = NULL, claim_token = NULL,
               changed_by = left(v_user, 200), changed_at = p_at
         WHERE schedule_id = v_id;
        v_done := format('schedule %s changed: drawn as %s, next send %s', v_id, v_as,
                         CASE WHEN v_moved THEN v_next ELSE v_old.next_at END);
      END IF;
    END IF;
  END IF;
  INSERT INTO pgvigil.report_mail_log (at, ui_user, client, op, schedule_id, outcome, detail, payload)
  VALUES (p_at, left(v_user, 200), left(v_client, 100), left(coalesce(v_op, ''), 20), v_id,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, left(coalesce(v_why, v_done), 2000),
          p_payload - 'ui_user' - 'client');
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'schedule_id', v_id);
END $$;

-- import_report_mail: 0107's, whole, with one refusal more - a kept schedule is changed only by its setting
-- (import_report_mail_kept). p_payload and the answer are 0107's.
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
  ELSIF v_op <> 'add' AND v_old.kept_as IS NOT NULL THEN
    v_why := format('schedule %s is kept by the Daily checks mail setting: change it there (reports.daily_checks in pgvigil.yaml, or Mail daily on the Daily checks page)', v_id);
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
