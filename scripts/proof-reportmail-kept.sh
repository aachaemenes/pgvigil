# Part K of scripts/proof-reportmail.sh (sourced by it after part P; never run alone): the Daily checks mail (migration
# 0258, internal/reportmail/kept.go, internal/web/q_reportmail_kept.go, web/src/reportmail.ts dailyMailControl and the
# green-day fix). It uses the proof's repository, sink, sender, serves, browser and helpers (BIN WORK CFG q as dsn COL ALR
# RDR PW UIUSER UIPW U2USER U U2 JAR TOKEN CDP SINKP sender waitsent code postj jget freeport fail ok) and adds serves of
# its own and one more repository (migrated, never seeded: the green day), all removed at the end.
#
# Expected (written before the first run):
#   K1  the role contract: the collector's login may EXECUTE import_report_mail_kept; the alerter's and the reader's
#       calls are refused (permission denied); the reader reads kept_as.
#   K2  keep twice: the first (the user and an address in capitals) makes ONE live row stored in lower case; the second
#       (lower case) is 'unchanged': changed_at NULL, next_at unmoved, one log row in all.
#   K3  two sessions and NO live row (K2's row dropped first): the first holds its keep open for 6 s; the second asks
#       the same keep only once pg_locks shows the first's advisory lock granted: it WAITS (2 s or more) and answers
#       'unchanged'; one live row (a new schedule), ONE keep logged (the first's, done), none refused. With a live row
#       the row's own lock would give the same answer, lock or no lock; with none, only the advisory lock makes the
#       second wait before it looks - without it the index would refuse it ('another live Daily checks mail exists').
#   K4  the ordinary door on the kept row: import_report_mail end / disable / enable refused with 'kept by the Daily
#       checks mail setting'; the page's keep and drop on the file-kept row refused ('kept by pgvigil.yaml'); a second
#       live kept row inserted by hand is refused by the unique index; drop ends it, again is 'unchanged'.
#   K5  the page's state (GET /api/reportmail?part=daily): on the signed-in serve owner page, off, writable; on the
#       -no-login serve writable false with the reason naming -no-login, and its POST 403. (A -no-login serve answers
#       the part to any caller, with a kept row's addresses, channel and user: the exposure its schedules part has
#       there already, not a new one; this row checks writable and the reason only.)
#   K6  the page's keep through the door (op daily_keep as the signed-in user): a row kept_by page, drawn as that user,
#       next send the next 07:00 UTC; the Report mail door's end of it 409 with the setting's words.
#   K7  the control on the Daily checks page (a headless Chromium): the line says 'Mail daily: on, next send ...,
#       drawn as <user>' with Change... and Turn off live; no line at #/checks?tag=<x>; Turn off's dialog ends the row
#       and the line says off; Mail daily...'s dialog (an address, the channel) keeps a new one.
#   K8  the turn: the page-made row brought due is drawn by a serve as its owner and mailed once: subject 'Daily checks
#       - ', the checks grid's header row, as many data rows as the send's count (the cells of a mailed page against
#       its screen are part C's, on the other pages).
#   K9  the file takes over: a serve started with the block on (another hour and zone, two addresses one in capitals,
#       as another user in capitals) updates the SAME schedule_id: kept_by file, drawn as that user, the cron and the
#       zone the file's; its page state is owner file, read only with 'kept by pgvigil.yaml'; its POST daily_drop 409;
#       the plain serve's daily_keep 409 too; the turn brought due is drawn as the NEW user (requested_by).
#   K10 the same block again (the serve restarted): its log says once more 'the setting is as kept: nothing written'
#       (the try ran), and nothing is written (the log's count, changed_at and the next send unmoved).
#   K11 enabled: false: the serve ends the row (ended_by pgvigil.yaml); its page says 'turned off in pgvigil.yaml'; a
#       page-made row is ended by it too.
#   K12 the block removed: a row the file made is ended at the start of a serve whose file has no block.
#   K13 an `as` user who cannot sign in: nothing kept, nothing written, the page's reason says so ('It is not kept
#       yet'). Then, with a schedule kept before (made by the page on the plain serve) while the file's setting still
#       cannot be applied: the row is untouched and that serve's page says 'on' with 'The file's change is not applied:
#       the schedule still runs as before (<why>)'.
#   K14 a block that is not whole stops serve at start (an exit code that is neither 0 nor timeout's 124) with words
#       only the refusal has: 'reports.daily_checks: enable is not a key of the block (line <n> of the file)', <n> the
#       line of the typo in that file; 'reports.daily_checks: channel is required'.
#   B20-4, the daily fleet health (the lead 11-15 16:3x D5 (a); written 11-16 15:1x before the first run; K15-K21 run after
#   K14, on the plain serves, with a sender of their own whose configuration adds two webhook channels - hook, a loopback
#   sink that keeps every POST's body, and deadhook, a port nothing listens on - and alerts_base_url http://pgvigil.test):
#   K15u checksorder.ts's unit rows (web/src/checksorder.test.mjs, bundled by web's esbuild) all ok: the worst-first
#       order and the post's numbers (review-26 go2 S3; written 11-16 16:4x before its first run).
#   K15 THE ORDER: two proof instances of known bands, k15-aaa (1 critical, 3 warnings) and k15-zzz (2 critical), named
#       so the reader's order (critical rows first, by name) puts k15-aaa first: the Daily checks page draws the rows
#       naming no instance first, then each instance's rows together, the instances by critical count, warning count,
#       name - k15-zzz before k15-aaa - judged on the screen's own rows (their counts, their order); the section carries
#       the post's numbers (data-daily-post) equal to its tiles. (review-26 proof 4, 7; written 11-16 16:5x before its
#       first run:) every row is on the screen for the read - a grid over 200 rows has its 'Show all' clicked, and the
#       rows read equal the grid's own count; the screen holds k15-aaa with exactly 1 critical and 3 warnings and
#       k15-zzz with exactly 2 critical and none, k15-zzz's first row above k15-aaa's.
#   K16 a failed mail posts nothing: the kept row with post [hook] through the door (post_channels {hook}) and the
#       channel badmail; its turn is answered failed; no post reaches the sink, the send's post_taken_at and posted_at
#       stay NULL - on a turn that carried its post (post, post_channels {hook} and post_day set: review-26 proof 6).
#       From K16 on the rows judge one UTC day: within 30 minutes of 00:00 UTC the block waits for it first (proof 11;
#       review-27 N2: 30, not 20 - K16, K17, K18 and K18b each allow 3 + 3 minutes).
#   K17 THE POST: the channel mail again (the same schedule): its turn is answered sent; the mail's checks grid is worst
#       first by its own rows; ONE post reaches the sink, its body (format json) kind 'daily checks' with the counts of
#       that same mail (critical = its critical rows, warnings = the rest), instances = the page's Instances tile, the
#       worst three = the first three instances of the mail's grid in order, the link http://pgvigil.test/#/checks?w=24h;
#       the send's posted_at set, post_error NULL; GET part=daily lists post_choices [deadhook, hook] (the repository's
#       configured webhook channels) and post [hook].
#   K17c THE DIALOG'S POST BOXES (review-26 go2 S4; written 11-16 16:4x before its first run): Change... on the page -
#       the line says 'Its counts are posted to hook.', every field labelled, the hook box checked and the deadhook box
#       not; Save with nothing changed answers done and writes nothing (post_channels still {hook}, no log row) -
#       'done ... as asked', the unchanged keep's own words: a refused Save says 'not done' (review-27 S1).
#   K18 a second turn the same day is mailed (sent) and posts nothing: the sink unchanged, its post_taken_at NULL, its
#       post_error 'the schedule's post of <day> was taken already' (review-26 N5; written 15:5x before its first run).
#   K18b a turn due yesterday and mailed today posts ONCE under its due day: post_day and the post's day / summary are
#       yesterday's (review-26 S2: the day of the turn, never the day it was queued; written 15:5x before its first run).
#   K19 a failed post is alerted: the row dropped and kept anew (a new schedule) with post [deadhook]; its turn is sent,
#       the post fails - post_error names 127.0.0.1, posted_at NULL - and a 'daily checks post failed' notice naming the
#       mail reaches the file drop. K17 also: the reader's and the collector's calls of report_mail_post_take /
#       report_mail_post_record are refused (permission denied).
#   K19b a sent mail whose page sent no counts is alerted, BY A REAL TURN (review-26 sql S3; proof 5, written 11-16 16:5x
#       before its first run): the kept row's route set by hand to the Summary (a page that draws no counts), its turn
#       mailed; the send row AS THE SERVER WROTE IT holds post NULL and post_error 'the drawn page sent no counts:
#       nothing posted', and a 'daily checks post failed' notice naming the mail and 'sent no counts' reaches the file
#       drop; the route is put back (read back on the kept row: review-27 N4).
#   K19c THE KEEP'S POST LIST (review-26 go2 S5, S6, N3; written 11-16 16:4x before its first run): a daily_keep with no
#       post field (a page loaded before the upgrade) leaves post_channels {deadhook} and writes nothing; post [hook]
#       then post [hook, deadhook] is a change ('changed', one log row, post_channels {deadhook,hook}); with deadhook
#       no longer recorded by the sender the dialog says 'deadhook is no longer a recorded webhook channel: Save drops
#       it', offers hook alone and its Save answers 'done ... changed' and keeps {hook}; post [] clears the list.
#   K20 the block's post: list: a serve whose block says post: [hook] keeps post_channels {hook} (kept_by file); a block
#       with post: [mail] (an smtp channel) stops serve at start with 'reports.daily_checks: post: mail is not a webhook
#       channel of the alerts: block'; a block with a webhook's URL for a name stops it with 'reports.daily_checks: post: entry 1
#       of the list is not a webhook channel of the alerts: block' and the URL nowhere in serve's words (review-26 go2 S2).
#   K20b a block whose post: names a webhook channel the sender has not recorded yet keeps nothing at first (serve's log
#       says 'post: newhook is not a webhook channel the sender ...'; nothing written to report_mail_log while it
#       waits - review-26 go2 S1) and keeps {newhook} within 75 s of a sender pass
#       that records it, with no restart (review-26 B1: tried again each minute, as channel: is; written 15:5x).
#   K21 THE ROLE (the lead 11-15 12:0x, DAILYMAIL's line): a viewer's GET part=daily answers writable false with the
#       role's words, the route's own ('changing a report mail schedule needs the admin role: proofview is a viewer' -
#       review-26 go2 N4: one wording for the part and the POST); its daily_keep 403 with the same words; nothing kept.
#   K22 DAILY-SQL (the lead 11-16 16:55 / 18:47; written 18:5x before its first run): every SQL Server cell at warning or
#       critical on the fleet Summary is a row of the Daily checks page - its level, its words (the cell's reading, e.g.
#       '1 critical'), its column's name as the check - and no SQL Server cell row without its cell; seeded first on
#       demo-onprem-sql02 through the product's own imports: its full and differential backups late (thresholds 0.01 h)
#       and one CHECKDB warning; blocking (the Activity cell) has no row (Q4), Snapshot Age none (its rows are the
#       overview's 'collection stale'); Collection Errors (24hrs) a row at warning only (K27); a row's check is its
#       column's own label (review-28 rows S2: equal, not a prefix); no floor on the count of cells (S3).
#   K23 each SQL Server row's instance link is its cell's own landing: the Summary cell's link where it has one, the
#       Needs attention strip's link for the same cell.
#   K24 THE ACKNOWLEDGEMENT IS THE CELL'S, BOTH ENGINES (Q1): Acknowledge on the Summary's strip (until the check changes)
#       for demo-onprem-sql02 and k15-zzz - their rows leave the open grid for an acknowledged grid ('acknowledged by
#       ...'), out of the tiles, the section's post numbers and the worst three; A SCHEDULED TURN's mail (rendered by the
#       serve, no viewer's browser) draws the same open and acknowledged rows and its send's post the same counts;
#       the send row's rows = the page's open rows (the acknowledged grid not counted - review-28 code S1) and the post's
#       'acknowledged' = the acknowledged rows; the acknowledgements ended, sql02's and k15-zzz's rows are as before them
#       (review-28 rows S1: compared on those two alone, the mail against the page read before OR after its turn, each
#       compare read again once on a difference - a cell's words move with the clock: ', stale', uptime's hours).
#   K25 the scheduled mail's grid carries demo-onprem-sql01's cell rows as the page draws them; the turn's post ranks
#       by the same rows (its worst three = the page's first three instances, EACH one's counts its rows' on the page -
#       review-28 rows S4: sql01 named in the ok line when it is among them, never a silent skip).
#   K26 GET /api/mssql/summary failing (a function its cells read renamed for the row): one critical 'check could not
#       run' row naming the SQL Server status cells, no cell row; the function put back.
#   K27 THE RECOVERED COLLECTION, BOTH ENGINES (the lead 11-16 20:01, review-28 code S6): one SQL Server and one
#       PostgreSQL instance with no collection failing get a collection run that failed an hour ago and ran well now
#       (log_collection, the collector's own function): the Summary's Collection Errors (24hrs) cell of each turns
#       warning, and each is ONE warning row of the Daily checks page - the cell's words, its column's label, its link -;
#       every instance whose cell is at warning has that row, none whose cell is critical or whose collection is failing
#       now (its 'collection failing' row is the overview's); acknowledged on the cell (POST /api/ack, check_key errors,
#       2 h), the PostgreSQL one's row moves to the acknowledged grid, out of the tiles and the post's counts, the post's
#       'acknowledged' counting it; the acknowledgement ended.
#       RED on d1ed4a6f (the page before DAILY-SQL): K22 FAIL (the Summary's cells, 0 of them rows), K23 FAIL (no row to
#       compare), K24 FAIL (no acknowledged grid; k15-zzz's rows still open), K25 FAIL (no sql01 cell row), K26 FAIL
#       (no such row), K27 FAIL (no Collection Errors row: the old page has no cell rows) - each with its words,
#       PGVIGIL_KROWS_GO=1 going on to the tally. (Folded 11-16 20:2x before any run: review-28 rows B1 - K22's thresholds
#       seed in the function's own order with an array -, B2 - the strip's 'Show all N' opened before its lines are read.)
#   G1  a repository migrated and never seeded, the sender never run: the page-owner serve says the mail needs an smtp
#       channel (writable false).
#   G2  the block on there: for 130 s (three tries) nothing is kept, NOTHING is written to report_mail_log, the serve's
#       log holds the reason once, the page says the channel is not recorded.
#   G3  the sender's first pass records the channel: the row is kept within 75 s, one log row.
#   G4  THE GREEN DAY: no check fails there. The turn brought due is SENT (before the fix: failed, 'the page drew no
#       grid') and its body holds the checks grid's header row, no data row and the sentence 'All checks pass'.
#   NOT PROVEN here (B20-4): Slack, Teams, Discord and Google Chat bodies against a real workspace (their shapes are
#       internal/alerts post_test.go's rows); two senders racing one post for real (the unique index on the schedule
#       and the day stands for it); a page whose counts are over 4 KB and a render whose post fails its checks, each by
#       a real turn (the 4 KB words are 0273's, the dropped post is internal/web TestRenderPostDropped's rows); a Daily
#       checks page of over 200 rows (K15 clicks 'Show all' when there is one: the demo draws about 190).
#   NOT PROVEN here: a send at the real hour (next_at is brought due by hand); two serves racing a keep for real (K3's
#       two sessions stand for it); the note on a server without a browser.

echo "== K: the Daily checks mail"
KPIDS=""; KPID=""; REPO2="${REPO}_g"
kcleanup() {
  for p in $KPIDS; do kill "$p" 2>/dev/null || true; done
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO2 with (force)" >/dev/null 2>&1 || true
}
trap 'kcleanup; cleanup' EXIT
# kserve <cfg> <port> <log>: a serve with the login on that port; its pid in KPID. KSERVE_SOFT=1: a serve that dies or
# never answers returns 1 for the caller's own words (K20, K20b: a red run goes on to the block's tally)
kserve() {
  TZ=UTC "$BIN" serve -config "$1" -listen "127.0.0.1:$2" >> "$WORK/$3" 2>&1 &
  KPID=$!; KPIDS="$KPIDS $KPID"
  for _ in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$2/" && return 0
    if ! kill -0 "$KPID" 2>/dev/null; then
      [[ ${KSERVE_SOFT:-0} == 1 ]] && return 1
      fail "K: serve died: $(tail -3 "$WORK/$3")"
    fi
    sleep 0.5
  done
  [[ ${KSERVE_SOFT:-0} == 1 ]] && return 1
  fail "K: serve did not answer on port $2"
}
kstop() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
# kwait <seconds> <command...>: until the command prints 'y' (every 2 s)
kwait() { local n=$1; shift; for _ in $(seq 1 $((n / 2 + 1))); do [[ $("$@") == y ]] && return 0; sleep 2; done; return 1; }
kj() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))' "$1" "$2"; }
# kbody <op> <by> <who> <as> <cron> <recipients json>: one attempt's payload (no single quote in it)
kbody() { echo "{\"op\":\"$1\",\"by\":\"$2\",\"ui_user\":\"$3\",\"as\":\"$4\",\"recipients\":$6,\"channel\":\"mail\",\"cron\":\"$5\",\"timezone\":\"UTC\",\"next_at\":\"$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)\"}"; }
kept() { as "$COL" -c "select pgvigil.import_report_mail_kept(clock_timestamp(), '$1'::jsonb)"; }
klive() { q "select coalesce((select ($1)::text from pgvigil.report_mail_schedules where kept_as = 'daily_checks' and ended_at is null), '-')"; }
nlive() { q "select count(*) from pgvigil.report_mail_schedules where kept_as is not null and ended_at is null"; }
nlog() { q "select count(*) from pgvigil.report_mail_log where op in ('keep', 'drop')"; }
[[ $(q "select count(*) from pgvigil.schema_version where version = '0258_daily_checks_mail.sql'") == 1 ]] || fail "K: 0258 is not applied"
grep -q 'LoadDailyChecks' cmd/pgvigil/serve.go || fail "K: serve is not wired for the block (git apply scripts/proof-dailymail-wiring.patch)"
grep -q 'daily-mail' internal/web/dist/app.js || fail "K: the web bundle has no Mail daily control: run 'npm run build' in web/"
[[ $(nlive) == 0 && $(nlog) == 0 ]] || fail "K: a kept schedule or its log before part K"

# ---- K1: the role contract --------------------------------------------------------------------------------------------
[[ $(as "$COL" -c "select has_function_privilege('pgvigil.import_report_mail_kept(timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "K1: the collector may not call import_report_mail_kept"
for who in "$ALR" "$RDR"; do
  out=$(as "$who" -c "select pgvigil.import_report_mail_kept(now(), '{\"op\":\"drop\",\"by\":\"file\",\"ui_user\":\"x\"}')")
  [[ $out == *"permission denied"* ]] || fail "K1: $who called import_report_mail_kept: $out"
done
[[ $(as "$RDR" -c "select count(*) from pgvigil.report_mail_schedules where kept_as is not null") == 0 ]] || fail "K1: the reader cannot read kept_as"
ok "K1: the collector's login may keep and drop; the alerter and the reader may not; the reader reads kept_as"

# ---- K2: keep twice --------------------------------------------------------------------------------------------------
UP=$(tr '[:lower:]' '[:upper:]' <<<"$UIUSER")
r=$(kept "$(kbody keep file pgvigil.yaml "$UP" '5 7 * * *' '["Daily@PGVIGIL.test"]')")
[[ $(kj "$r" outcome) == done && $(nlive) == 1 && $(klive created_by) == "$UIUSER" && $(klive "recipients[1]") == daily@pgvigil.test && $(klive kept_by) == file && $(klive name) == "Daily checks" && $(klive route) == "#/checks?w=24h" ]] \
  || fail "K2: the first keep: $r / $(klive "created_by || ' ' || recipients::text || ' ' || kept_by")"
KID=$(klive schedule_id); KNEXT=$(klive next_at)
r=$(kept "$(kbody keep file pgvigil.yaml "$UIUSER" '5 7 * * *' '["daily@pgvigil.test"]')")
[[ $(kj "$r" outcome) == unchanged && $(klive "changed_at is null") == true && $(klive next_at) == "$KNEXT" && $(nlog) == 1 && $(nlive) == 1 ]] || fail "K2: the same again: $r, log $(nlog), next $(klive next_at) (was $KNEXT)"
ok "K2: keep makes one live row (schedule $KID, the user and the address stored in lower case); the same again is 'unchanged': nothing written, nothing logged"

# ---- K3: two sessions and no live row: the advisory lock ----------------------------------------------------------------
r=$(kept '{"op":"drop","by":"file","ui_user":"pgvigil.yaml"}')
[[ $(kj "$r" outcome) == done && $(nlive) == 0 ]] || fail "K3: the drop before the two sessions: $r, live $(nlive)"
nkeep() { q "select count(*) from pgvigil.report_mail_log where op = 'keep'"; }
# klock: the granted advisory locks on the kept schedule's key (a bigint key is classid, its high half, and objid)
klock() { q "select count(*) from pg_locks l where l.locktype = 'advisory' and l.granted and l.database = (select d.oid from pg_database d where d.datname = current_database()) and ((l.classid::bigint << 32) | l.objid::bigint) = hashtextextended('pgvigil.report_mail_kept:daily_checks', 0)"; }
[[ $(klock) == 0 ]] || fail "K3: the kept schedule's advisory lock is held before the two sessions"
K3KEEP=$(nkeep); K3LOG=$(nlog)
B8=$(kbody keep file pgvigil.yaml "$UIUSER" '0 8 * * *' '["daily@pgvigil.test"]')
psql "$(dsn "$COL")" -XAtq -c "begin" -c "select pgvigil.import_report_mail_kept(clock_timestamp(), '$B8'::jsonb)" -c "select pg_sleep(6)" -c "commit" > "$WORK/k3a.out" 2>&1 &
K3A=$!
held=n
for _ in $(seq 1 100); do [[ $(klock) == 1 ]] && { held=y; break; }; sleep 0.1; done
[[ $held == y ]] || fail "K3: the first session's advisory lock was never seen granted: $(cat "$WORK/k3a.out")"
T0=$(date +%s); r=$(kept "$B8"); T1=$(date +%s)
wait "$K3A" || fail "K3: the first session: $(cat "$WORK/k3a.out")"
[[ $(kj "$(sed -n 1p "$WORK/k3a.out")" outcome) == done ]] || fail "K3: the first session's keep: $(cat "$WORK/k3a.out")"
[[ $(kj "$r" outcome) == unchanged && $((T1 - T0)) -ge 2 && $(nlive) == 1 && $(klive cron) == "0 8 * * *" && $(klive schedule_id) != "$KID" && $(nkeep) == $((K3KEEP + 1)) && $(nlog) == $((K3LOG + 1)) ]] \
  || fail "K3: the second session: $r after $((T1 - T0)) s; live $(nlive), cron $(klive cron), schedule $(klive schedule_id) (K2's was $KID), keeps logged $(nkeep) (were $K3KEEP), log $(nlog) (was $K3LOG); the first: $(cat "$WORK/k3a.out")"
[[ $(q "select count(*) from pgvigil.report_mail_log where op = 'keep' and outcome = 'refused'") == 0 ]] || fail "K3: a keep was refused: $(q "select detail from pgvigil.report_mail_log where op = 'keep' and outcome = 'refused'")"
KID=$(klive schedule_id)
ok "K3: two sessions keeping at once with no live row: the second started once the first held the advisory lock, waited $((T1 - T0)) s and answered 'unchanged'; one live row (schedule $KID), one keep logged, none refused"

# ---- K4: the refusals ------------------------------------------------------------------------------------------------
for op in end disable enable; do
  r=$(as "$COL" -c "select pgvigil.import_report_mail(clock_timestamp(), '{\"op\":\"$op\",\"ui_user\":\"x\",\"schedule_id\":$KID,\"next_at\":\"$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)\"}'::jsonb)")
  [[ $(kj "$r" outcome) == refused && $(kj "$r" detail) == *"kept by the Daily checks mail setting"* ]] || fail "K4: import_report_mail $op of the kept row: $r"
done
r=$(kept "$(kbody keep page "$UIUSER" "$UIUSER" '0 9 * * *' '["page@pgvigil.test"]')"); r2=$(kept '{"op":"drop","by":"page","ui_user":"x"}')
[[ $(kj "$r" outcome) == refused && $(kj "$r" detail) == *"kept by pgvigil.yaml"* && $(kj "$r2" outcome) == refused ]] || fail "K4: the page on a file-kept row: $r / $r2"
out=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "insert into pgvigil.report_mail_schedules (name, route, recipients, channel, cadence, cron, timezone, created_by, created_at, kept_as, kept_by) values ('x','#/checks','{a@b.org}','mail','daily','0 9 * * *','UTC','x',now(),'daily_checks','page')" 2>&1 || true)
[[ $out == *report_mail_schedules_kept_idx* ]] || fail "K4: a second live kept row by hand: $out"
[[ $(klive "enabled and cron = '0 8 * * *' and kept_by = 'file'") == true ]] || fail "K4: the kept row changed under the refusals"
r=$(kept '{"op":"drop","by":"file","ui_user":"pgvigil.yaml"}'); r2=$(kept '{"op":"drop","by":"file","ui_user":"pgvigil.yaml"}')
[[ $(kj "$r" outcome) == done && $(kj "$r2" outcome) == unchanged && $(nlive) == 0 && $(q "select ended_by from pgvigil.report_mail_schedules where schedule_id = $KID") == pgvigil.yaml ]] || fail "K4: the drop: $r / $r2"
ok "K4: the ordinary door refuses to end or switch the kept row, the page's op is refused on a row the file keeps, the index refuses a second live row; drop ends it (the row stays), again 'unchanged'"

# ---- K5, K6: the page's state and its keep through the door ------------------------------------------------------------
kget() { code -b "${2:-$JAR}" "$1/api/reportmail?part=daily"; }
[[ $(kget "$U") == 200 && $(jget "d['daily']['owner']") == page && $(jget "d['daily']['kept']") == False && $(jget "d['daily']['writable']") == True ]] || fail "K5: the signed-in serve's state: $(cat "$WORK/body")"
[[ $(code "$U2/api/reportmail?part=daily") == 200 && $(jget "d['daily']['writable']") == False && $(jget "d['daily']['reason']") == *"-no-login"* ]] || fail "K5: the -no-login serve's state: $(cat "$WORK/body")"
c=$(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["page@pgvigil.test"],"channel":"mail"}' "$U2/api/reportmail")
[[ $c == 403 && $(nlive) == 0 ]] || fail "K5: the -no-login serve's daily_keep answered $c"
ok "K5: the page's state: owner page, off and writable when signed in; read only with its reason on a serve with -no-login (its POST 403)"
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["page@pgvigil.test"],"channel":"mail"}')
[[ $c == 200 && $(jget "d['outcome']") == done && $(klive kept_by) == page && $(klive created_by) == "$UIUSER" && $(klive cron) == "0 7 * * *" ]] || fail "K6: daily_keep: $c $(cat "$WORK/body")"
[[ $(klive "next_at = (date_trunc('day', now() at time zone 'UTC') + interval '7 hours' + case when (now() at time zone 'UTC')::time >= time '07:00' then interval '1 day' else interval '0' end) at time zone 'UTC'") == true ]] || fail "K6: next_at $(klive next_at) is not the next 07:00 UTC"
KID=$(klive schedule_id)
[[ $(kget "$U") == 200 && $(jget "d['daily']['kept']") == True && $(jget "d['daily']['as']") == "$UIUSER" && $(jget "d['daily']['at']") == 07:00 && $(jget "d['daily']['kept_by']") == page ]] || fail "K6: the state after the keep: $(cat "$WORK/body")"
c=$(postj reportmail "{\"op\":\"end\",\"schedule_id\":$KID}")
[[ $c == 409 && $(jget "d['error']") == *"kept by the Daily checks mail setting"* && $(nlive) == 1 ]] || fail "K6: the Report mail door's end of the kept row: $c $(cat "$WORK/body")"
ok "K6: Mail daily through the door kept schedule $KID as $UIUSER (kept_by page, next send the next 07:00 UTC); the Report mail door refuses to end it (409, the setting's words)"

# ---- K7: the control on the Daily checks page ---------------------------------------------------------------------------
cat > "$WORK/kdrive.mjs" <<'JS'
const [port, U, token, mode, route, arg] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Network.enable');
await cmd('Network.setCookie', { name: 'pgvigil_session', value: token, url: U, httpOnly: true });
await cmd('Page.navigate', { url: U + '/?k=' + Date.now() + route });
// drawn: the page's heading is there and main has not changed for 1.2 s
let last = '', since = Date.now(), drawn = false;
for (const t = Date.now(); Date.now() - t < 30000; await sleep(200)) {
  const s = await ev(`(() => { const m = document.querySelector('main'); return m && m.querySelector('h2') ? m.textContent.length + ':' + m.querySelectorAll('*').length : 'busy'; })()`);
  if (s === 'busy' || s !== last) { last = s; since = Date.now(); continue; }
  if (Date.now() - since > 1200) { drawn = true; break; }
}
if (!drawn) { console.log(JSON.stringify({ error: 'the page did not settle: ' + route })); process.exit(1); }
const LINE = `(() => { const p = document.querySelector('main p.daily-mail'); return p ? { line: p.textContent.replace(/\\s+/g, ' ').trim(), buttons: [...p.querySelectorAll('button')].map(b => ({ t: b.textContent, off: b.getAttribute('aria-disabled') === 'true' })) } : { line: null, buttons: [] }; })()`;
const res = await ev(LINE);
res.h2 = await ev(`document.querySelector('main h2')?.textContent ?? ''`);
const said = async () => { let s = ''; for (let n = 0; n < 100; n++) { await sleep(200); s = await ev(`document.querySelector('dialog[open] [role=status]')?.textContent ?? ''`); if (/done|not done/.test(s)) break; } return s; };
if (mode === 'off' || mode === 'keep' || mode === 'change') {
  const label = mode === 'off' ? 'Turn off' : mode === 'change' ? 'Change...' : 'Mail daily...';
  const hit = await ev(`(() => { const b = [...document.querySelectorAll('main p.daily-mail button')].find(x => x.textContent === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  if (!hit) { console.log(JSON.stringify({ ...res, error: 'no button ' + label })); process.exit(1); }
  for (let n = 0; n < 50 && !await ev(`!!document.querySelector('dialog[open] form')`); n++) await sleep(100);
  res.title = await ev(`document.querySelector('dialog[open] h3')?.textContent ?? ''`);
  if (mode === 'keep' || mode === 'change') {
    res.unlabelled = await ev(`[...document.querySelectorAll('dialog[open] input, dialog[open] select, dialog[open] textarea')].filter(x => !x.closest('label')).length`);
    // the post boxes as the dialog drew them (each a webhook channel's name; left as found) and its word on a kept channel that is gone
    res.posts = await ev(`[...document.querySelectorAll('dialog[open] input[type=checkbox][value]')].map(b => [b.value, b.checked])`);
    res.note = await ev(`document.querySelector('dialog[open] .post-gone')?.textContent ?? ''`);
    await ev(`(() => { const d = document.querySelector('dialog[open]'); const t = d.querySelector('textarea'); t.value = ${JSON.stringify(arg)}; t.dispatchEvent(new Event('input', { bubbles: true }));
      const tz = d.querySelectorAll('select')[0]; tz.value = 'UTC'; tz.dispatchEvent(new Event('change', { bubbles: true }));
      const ch = d.querySelectorAll('select')[1]; ch.value = 'mail'; ch.dispatchEvent(new Event('change', { bubbles: true })); })()`);
  }
  await ev(`document.querySelector('dialog[open] button[type=submit]').click()`);
  res.said = await said();
}
console.log(JSON.stringify(res));
process.exit(0);
JS
kdrive() { node "$WORK/kdrive.mjs" "$CDP" "$U" "$TOKEN" "$@"; }
kd() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$WORK/kd.json" "$1"; }
kdrive line '#/checks?w=24h' > "$WORK/kd.json" || fail "K7: the driver: $(cat "$WORK/kd.json")"
[[ $(kd "d['line']") == *"Mail daily: on, next send"*"to 1 address, drawn as $UIUSER."* && $(kd "sorted((b['t'], b['off']) for b in d['buttons'])") == "[('Change...', False), ('Turn off', False)]" ]] || fail "K7: the line when on: $(cat "$WORK/kd.json")"
KLINE=$(kd "d['line']")
kdrive line '#/checks?w=24h&tag=proofnone' > "$WORK/kd.json" || fail "K7: the driver (a tag): $(cat "$WORK/kd.json")"
[[ $(kd "d['line']") == None && $(kd "d['h2']") == "Daily checks"* ]] || fail "K7: a tag's Daily checks page has the control: $(cat "$WORK/kd.json")"
kdrive off '#/checks?w=24h' > "$WORK/kd.json" || fail "K7: Turn off: $(cat "$WORK/kd.json")"
[[ $(kd "d['said']") == *done*ended* && $(nlive) == 0 ]] || fail "K7: Turn off's dialog: $(cat "$WORK/kd.json"); live $(nlive)"
kdrive keep '#/checks?w=24h' 'dialog@pgvigil.test' > "$WORK/kd.json" || fail "K7: Mail daily...: $(cat "$WORK/kd.json")"
[[ $(kd "d['line']") == *"Mail daily: off."* && $(kd "d['unlabelled']") == 0 && $(kd "d['said']") == *done*kept* && $(nlive) == 1 && $(klive kept_by) == page && $(klive "recipients[1]") == dialog@pgvigil.test && $(klive created_by) == "$UIUSER" ]] \
  || fail "K7: Mail daily...'s dialog: $(cat "$WORK/kd.json"); live $(nlive) $(klive "kept_by || ' ' || recipients::text")"
KID=$(klive schedule_id)
ok "K7: the Daily checks page's control: '$KLINE' with Change... and Turn off; none under a tag; Turn off's dialog ended it and the line said off; Mail daily...'s dialog (every field labelled) kept schedule $KID"

# ---- K8: the turn ------------------------------------------------------------------------------------------------------
# kturn <schedule> <query function> [<how long ago it was due>]: the schedule brought due (a second ago by default); its
# one scheduled mail's id once a serve queued it
kturn() {
  local sid=$1 qf=$2 ago=${3:-1 second} n before
  before=$($qf "select coalesce(max(send_id), 0) from pgvigil.report_mail_sends")   # an earlier turn's mail is not this one
  $qf "update pgvigil.report_mail_schedules set next_at = now() - interval '$ago' where schedule_id = $sid" >/dev/null
  for _ in $(seq 1 90); do
    n=$($qf "select coalesce(max(send_id), 0) from pgvigil.report_mail_sends where schedule_id = $sid and kind = 'scheduled' and outcome is distinct from 'refused' and send_id > $before")
    [[ $n != 0 ]] && { echo "$n"; return 0; }
    sleep 2
  done
  return 1
}
# kmail <to> <want rows or -> <sentence or ->: the newest mail to that address in the sink: its subject, the checks grid's header, its data rows
kmail() {
  python3 - "$WORK/sink" "$1" "$2" "$3" <<'PY'
import email, glob, re, sys
from email import policy
from html.parser import HTMLParser
sink, to, want, sentence = sys.argv[1:5]
ms = [m for m in (email.message_from_binary_file(open(f, 'rb'), policy=policy.default) for f in sorted(glob.glob(sink + '/*.eml'))) if m['X-Pgvigil-Report'] and to in str(m['To'])]
if not ms: sys.exit(f'no mail to {to} in the sink')
m = ms[-1]
if not str(m['Subject']).startswith('Daily checks - '): sys.exit(f'subject {m["Subject"]!r}')
body = [p for p in m.walk() if p.get_content_type() == 'text/html'][0].get_content()
class P(HTMLParser):
    def __init__(s): super().__init__(convert_charrefs=True); s.grids = []; s.cur = None; s.row = None; s.cell = None; s.ps = []; s.p = None
    def handle_starttag(s, t, a):
        a = dict(a)
        if t == 'table' and a.get('role') != 'presentation': s.cur = {'head': [], 'rows': 0}
        if t == 'tr' and s.cur is not None: s.row = []
        if t in ('th', 'td') and s.row is not None: s.cell = ['', t]
        if t == 'p': s.p = ''
    def handle_endtag(s, t):
        if t in ('th', 'td') and s.cell is not None and s.row is not None: s.row.append((re.sub(r'\s+', ' ', s.cell[0]).strip(), s.cell[1])); s.cell = None
        if t == 'tr' and s.cur is not None and s.row is not None:
            if s.row and all(k == 'th' for _, k in s.row) and not s.cur['head']: s.cur['head'] = [x for x, _ in s.row]
            else: s.cur['rows'] += 1
            s.row = None
        if t == 'table' and s.cur is not None: s.grids.append(s.cur); s.cur = None
        if t == 'p' and s.p is not None: s.ps.append(re.sub(r'\s+', ' ', s.p).strip()); s.p = None
    def handle_data(s, d):
        if s.cell is not None: s.cell[0] += d
        if s.p is not None: s.p += d
p = P(); p.feed(body)
g = next((g for g in p.grids if g['head'] == ['severity', 'instance', 'check', 'object', 'when', 'detail']), None)
if g is None: sys.exit(f'no checks grid in the body: {[g["head"] for g in p.grids]}')
if want != '-' and g['rows'] != int(want): sys.exit(f'the checks grid holds {g["rows"]} rows, the send counted {want}')
if sentence != '-' and not any(x.startswith(sentence) for x in p.ps): sys.exit(f'no sentence {sentence!r} in the body: {[x for x in p.ps if x][:5]}')
if sentence != '-' and 'No rows.' in p.ps: sys.exit("'No rows.' stands beside the grid's own sentence")
print(f'{g["rows"]} rows')
PY
}
SEND=$(kturn "$KID" q) || fail "K8: no serve queued the turn in 3 minutes: $(q "select send_id, kind, coalesce(outcome, 'queued'), coalesce(error, render_error) from pgvigil.report_mail_sends where schedule_id = $KID")"
waitsent "$SEND" || fail "K8: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome || ' ' || requested_by from pgvigil.report_mail_sends where send_id = $SEND") == "sent $UIUSER" ]] || fail "K8: mail $SEND: $(q "select outcome, requested_by, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND")"
KROWS=$(q "select rows from pgvigil.report_mail_sends where send_id = $SEND")
got=$(kmail dialog@pgvigil.test "$KROWS" "$([[ $KROWS == 0 ]] && echo 'All checks pass' || echo -)") || fail "K8: the mail: $got"
[[ $(klive "next_at > now() and claim_token is null") == true ]] || fail "K8: the kept row after its turn: $(klive "next_at::text || ' ' || coalesce(claim_token, '-')")"
ok "K8: schedule $KID brought due: drawn by a serve as $UIUSER and mailed once (mail $SEND, sent): subject 'Daily checks - ', the checks grid's header row and $got as the send counted; next send moved on"

# ---- K9, K10: the file takes over; the same block again writes nothing ---------------------------------------------------
K3USER=proofdaily; K3PW=$(openssl rand -hex 12)
PGVIGIL_PASSWORD=$K3PW "$BIN" user add -config "$CFG" $K3USER >/dev/null 2>&1 || fail "K9: user add"
# kcfg <file> <the block's lines, \n between them>: the proof's configuration with a reports.daily_checks block
kcfg() { { cat "$CFG"; printf 'reports:\n  daily_checks:\n%b' "$2"; } > "$1"; }
kcfg "$WORK/cfg-kon.yaml" "    enabled: true\n    at: 06:30\n    tz: America/Los_Angeles\n    to: [Daily@PGVIGIL.test, second@pgvigil.test]\n    as: ProofDaily\n    channel: mail\n"
kcfg "$WORK/cfg-koff.yaml" "    enabled: false\n"
kcfg "$WORK/cfg-kgone.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [gone@pgvigil.test]\n    as: $U2USER\n    channel: mail\n"
PK=$(freeport); UK="http://127.0.0.1:$PK"; L0=$(nlog)
kserve "$WORK/cfg-kon.yaml" "$PK" servek.log; SK=$KPID
filekept() { [[ $(klive kept_by) == file ]] && echo y || echo n; }
kwait 30 filekept || fail "K9: the serve did not take the row over in 30 s: $(klive "kept_by || ' ' || created_by"); $(grep -i 'daily checks' "$WORK/servek.log" | tail -2)"
[[ $(klive schedule_id) == "$KID" && $(klive created_by) == $K3USER && $(klive cron) == "30 6 * * *" && $(klive timezone) == America/Los_Angeles && $(klive "recipients::text") == "{daily@pgvigil.test,second@pgvigil.test}" \
   && $(klive changed_by) == pgvigil.yaml && $(nlive) == 1 && $(nlog) == $((L0 + 1)) ]] || fail "K9: the row after the take-over: $(klive "schedule_id::text || ' ' || created_by || ' ' || cron || ' ' || timezone || ' ' || recipients::text || ' ' || changed_by"), log $(nlog) (was $L0)"
curl -s -c "$WORK/jark" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$UK/api/login" >/dev/null
[[ $(kget "$UK" "$WORK/jark") == 200 && $(jget "d['daily']['owner']") == file && $(jget "d['daily']['writable']") == False && $(jget "d['daily']['reason']") == *"kept by pgvigil.yaml"* && $(jget "d['daily']['as']") == $K3USER ]] \
  || fail "K9: the file's serve's state: $(cat "$WORK/body")"
c=$(code -b "$WORK/jark" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary '{"op":"daily_drop"}' "$UK/api/reportmail")
[[ $c == 409 && $(jget "d['error']") == *"kept by pgvigil.yaml"* ]] || fail "K9: the file's serve's daily_drop: $c $(cat "$WORK/body")"
c=$(postj reportmail '{"op":"daily_keep","at":"09:00","timezone":"UTC","recipients":["page@pgvigil.test"],"channel":"mail"}')
[[ $c == 409 && $(jget "d['error']") == *"kept by pgvigil.yaml"* && $(klive cron) == "30 6 * * *" ]] || fail "K9: the plain serve's daily_keep over a file-kept row: $c $(cat "$WORK/body")"
SEND=$(kturn "$KID" q) || fail "K9: no serve queued the file-kept turn in 3 minutes"
waitsent "$SEND" || fail "K9: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome || ' ' || requested_by from pgvigil.report_mail_sends where send_id = $SEND") == "sent $K3USER" ]] || fail "K9: the turn after the take-over: $(q "select outcome, requested_by, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND")"
ok "K9: a serve with the block on took schedule $KID over in place (kept_by file, drawn as $K3USER, 06:30 America/Los_Angeles, two addresses in lower case); its page is read only ('kept by pgvigil.yaml'), its daily_drop and the plain serve's daily_keep 409; the next turn was drawn as $K3USER (mail $SEND)"
L1=$(nlog); C1=$(klive changed_at); N1=$(klive next_at)
naskept() { grep -c 'the setting is as kept' "$WORK/servek.log" || true; }
A1=$(naskept)
kstop "$SK"; kserve "$WORK/cfg-kon.yaml" "$PK" servek.log; SK=$KPID
askept() { [[ $(naskept) -gt $A1 ]] && echo y || echo n; }
kwait 30 askept || fail "K10: the restarted serve did not say its setting is as kept within 30 s (said $(naskept) time(s), $A1 before): $(grep -i 'daily checks' "$WORK/servek.log" | tail -2)"
[[ $(nlog) == "$L1" && $(klive changed_at) == "$C1" && $(klive next_at) == "$N1" && $(nlive) == 1 ]] || fail "K10: the same block again wrote: log $(nlog) (was $L1), changed_at $(klive changed_at) (was $C1)"
ok "K10: the serve restarted with the same block: it said 'the setting is as kept: nothing written', and nothing was written (the log, changed_at and the next send unmoved)"

# ---- K11, K12: enabled: false ends it, a page-made one too; the block removed ends a file-made one ----------------------
kstop "$SK"; kserve "$WORK/cfg-koff.yaml" "$PK" servekoff.log; SK=$KPID
nonelive() { [[ $(nlive) == 0 ]] && echo y || echo n; }
kwait 30 nonelive || fail "K11: enabled: false did not end the row in 30 s: $(grep -i 'daily checks' "$WORK/servekoff.log" | tail -2)"
[[ $(q "select ended_by from pgvigil.report_mail_schedules where schedule_id = $KID") == pgvigil.yaml ]] || fail "K11: ended_by $(q "select ended_by from pgvigil.report_mail_schedules where schedule_id = $KID")"
curl -s -c "$WORK/jark" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$UK/api/login" >/dev/null
[[ $(kget "$UK" "$WORK/jark") == 200 && $(jget "d['daily']['owner']") == file-off && $(jget "d['daily']['writable']") == False && $(jget "d['daily']['reason']") == *"turned off in pgvigil.yaml"* ]] || fail "K11: the off serve's state: $(cat "$WORK/body")"
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["page@pgvigil.test"],"channel":"mail"}')
[[ $c == 200 && $(klive kept_by) == page ]] || fail "K11: the plain serve's keep: $c $(cat "$WORK/body")"
kstop "$SK"; kserve "$WORK/cfg-koff.yaml" "$PK" servekoff.log; SK=$KPID
kwait 30 nonelive || fail "K11: enabled: false did not end the page-made row in 30 s"
ok "K11: enabled: false ended the file-kept row (ended_by pgvigil.yaml) and its page said 'turned off in pgvigil.yaml'; started again over a page-made row, it ended that one too"
kstop "$SK"; kserve "$WORK/cfg-kon.yaml" "$PK" servek.log; SK=$KPID
kwait 30 filekept || fail "K12: the block on did not keep a row"
kstop "$SK"; kserve "$CFG" "$PK" servekplain.log; SK=$KPID
kwait 30 nonelive || fail "K12: a serve with no block did not end the file-made row in 30 s"
ok "K12: a row the file made is ended at the start of a serve whose file no longer has the block"

# ---- K13, K14: a user who cannot sign in; a block that is not whole ----------------------------------------------------
kstop "$SK"; L2=$(nlog); kserve "$WORK/cfg-kgone.yaml" "$PK" servekgone.log; SK=$KPID
sleep 8
curl -s -c "$WORK/jark" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$UK/api/login" >/dev/null
[[ $(nlive) == 0 && $(nlog) == "$L2" && $(kget "$UK" "$WORK/jark") == 200 && $(jget "d['daily']['reason']") == *"$U2USER is not a UI user who can sign in"* ]] || fail "K13: as a disabled user: live $(nlive), log $(nlog) (was $L2), $(cat "$WORK/body")"
# a schedule kept before (here made by the page, on the plain serve) while the file's setting still cannot be applied
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["page@pgvigil.test"],"channel":"mail"}')
[[ $c == 200 && $(klive kept_by) == page ]] || fail "K13: the plain serve's keep: $c $(cat "$WORK/body")"
L3=$(nlog); KID=$(klive schedule_id)
sleep 8
[[ $(kget "$UK" "$WORK/jark") == 200 && $(jget "d['daily']['kept']") == True && $(jget "d['daily']['kept_by']") == page \
   && $(jget "d['daily']['reason']") == *"The file's change is not applied: the schedule still runs as before (as: $U2USER is not a UI user who can sign in"* ]] \
  || fail "K13: the file's serve's state over a schedule kept before: $(cat "$WORK/body")"
[[ $(nlive) == 1 && $(klive schedule_id) == "$KID" && $(klive kept_by) == page && $(klive "recipients[1]") == page@pgvigil.test && $(nlog) == "$L3" ]] || fail "K13: the schedule kept before changed: $(klive "schedule_id::text || ' ' || kept_by || ' ' || recipients::text"), log $(nlog) (was $L3)"
kstop "$SK"
c=$(postj reportmail '{"op":"daily_drop"}')
[[ $c == 200 && $(nlive) == 0 ]] || fail "K13: the plain serve's Turn off of the page-made row: $c $(cat "$WORK/body")"
ok "K13: as: $U2USER (disabled): nothing kept, nothing written, the page says the user cannot sign in; over a schedule kept before, that schedule is untouched and the page says the file's change is not applied and the schedule still runs as before"
kcfg "$WORK/cfg-kbad1.yaml" "    enable: true\n    at: 06:30\n    tz: UTC\n    to: [a@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n"
kcfg "$WORK/cfg-kbad2.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [a@pgvigil.test]\n    as: $UIUSER\n"
KBADLINE=$(( $(wc -l < "$CFG") + 3 ))   # kcfg: the file, then 'reports:', '  daily_checks:', and the block's first line
for pair in "cfg-kbad1.yaml|reports.daily_checks: enable is not a key of the block (line $KBADLINE of the file)" "cfg-kbad2.yaml|reports.daily_checks: channel is required"; do
  rc=0; out=$(timeout 20 "$BIN" serve -config "$WORK/${pair%%|*}" -listen "127.0.0.1:$(freeport)" 2>&1) || rc=$?
  # 0: it ran and ended by itself; 124: it started and ran until timeout ended it - neither is a refusal at start
  [[ $rc != 0 && $rc != 124 ]] || fail "K14: serve with ${pair%%|*} was not stopped at its start (exit $rc; 124 = it ran its 20 s): $(tail -2 <<<"$out")"
  [[ $out == *"${pair##*|}"* ]] || fail "K14: ${pair%%|*} (exit $rc): serve's words are not '${pair##*|}': $(tail -2 <<<"$out")"
done
ok "K14: a block with 'enable:' for enabled (named with line $KBADLINE of its file), and one without its channel, each stop serve at start (a refusal's exit code, the refusal's own words)"

# ---- K15-K21: B20-4, the daily fleet health (worst first, the post through the alert channels, the role) ---------------
# PGVIGIL_KROWS_GO=1 (a red run): a failed row of K15-K21 prints FAIL and the next row runs; the block fails at its end.
# Under set -euo pipefail a bare assignment from a command that can fail ends the script without a word. Guarded here
# (|| kfail, || true): a grep that may find nothing, a query on a column the tree lacks, and every curl on a serve -
# c=$(postj ...), c=$(code ...) and login (review-27 S2: a dead serve is curl's exit 7; c is then 000 and the next
# line's kfail says it). Left bare: reads that fail only when the store itself is gone (klive schedule_id, nposts,
# nlog, nlive, ensure_instance) and freeport, openssl, date.
KBAD=0
kfail() { if [[ ${PGVIGIL_KROWS_GO:-0} == 1 ]]; then echo "FAIL $*"; KBAD=$((KBAD + 1)); else fail "$@"; fi; }
KROW=0
kok() { if (( KBAD == KROW )); then ok "$@"; else echo "FAIL ${1%%:*}: the row ended with $((KBAD - KROW)) failed check(s) above"; fi; }
# ---- K15u: checksorder.ts's unit rows, as the other web/src/*.test.mjs are run by their proofs (review-26 go2 S3) ----------
if [[ ! -x web/node_modules/.bin/esbuild ]]; then
  kfail "K15u: web/node_modules has no esbuild: run 'npm ci' in web/"
elif ! web/node_modules/.bin/esbuild web/src/checksorder.ts --bundle --format=esm --platform=neutral --log-level=warning --outfile="$WORK/checksorder.mjs" > "$WORK/checksorder-unit.out" 2>&1; then
  kfail "K15u: esbuild could not bundle web/src/checksorder.ts: $(head -c 300 "$WORK/checksorder-unit.out" | tr '\n' ' ')"
elif ! node web/src/checksorder.test.mjs "$WORK/checksorder.mjs" > "$WORK/checksorder-unit.out" 2>&1; then
  kfail "K15u: web/src/checksorder.test.mjs: $(grep -E '^FAIL|rror' "$WORK/checksorder-unit.out" | head -3 | tr '\n' ' ' | cut -c1-400)"
fi
kok "K15u: checksorder.ts's unit rows (web/src/checksorder.test.mjs): $(grep -c '^ok' "$WORK/checksorder-unit.out" 2>/dev/null || true) ok, none failed"
# the webhook sink: every POST's body one file in $WORK/hook
HOOKP=$(freeport); DEADHOOKP=$(freeport); mkdir -p "$WORK/hook"
cat > "$WORK/hook.py" <<'PY'
import http.server, os, sys, time
d = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        b = s.rfile.read(int(s.headers.get('Content-Length') or 0))
        with open(os.path.join(d, f'{time.time_ns()}.json'), 'wb') as f: f.write(b)
        s.send_response(200); s.send_header('Content-Length', '2'); s.end_headers(); s.wfile.write(b'ok')
    def log_message(s, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/hook.py" "$HOOKP" "$WORK/hook" > "$WORK/hook.log" 2>&1 &
KPIDS="$KPIDS $!"
export PGV_HOOK_URL="http://127.0.0.1:$HOOKP/post" PGV_DEADHOOK_URL="http://127.0.0.1:$DEADHOOKP/post"
# the proof's configuration with the two webhook channels and alerts_base_url
python3 - "$CFG" "$WORK/cfg-kpost.yaml" <<'PY'
import sys
src, out = sys.argv[1:3]
res = ['alerts_base_url: http://pgvigil.test']
for l in open(src).read().splitlines():
    res.append(l)
    if l.startswith('alerts:'):
        res.append('  - {name: hook, kind: webhook, min_severity: critical, instances: [proof-none], webhook: {url: env:PGV_HOOK_URL, format: json}}')
        res.append('  - {name: deadhook, kind: webhook, min_severity: critical, instances: [proof-none], webhook: {url: env:PGV_DEADHOOK_URL, format: json}}')
open(out, 'w').write('\n'.join(res) + '\n')
PY
ksender() { "$BIN" alerts -config "$WORK/cfg-kpost.yaml" >> "$WORK/ksender.log" 2>&1 || true; }
kwaitsent() {   # kwaitsent <id>: this part's sender until the mail is answered (3 minutes); no id (a failed kturn) = 1 at once
  [[ -n ${1:-} ]] || return 1
  for _ in $(seq 1 36); do
    ksender
    [[ $(q "select count(*) from pgvigil.report_mail_sends where send_id = $1 and done_at is not null") == 1 ]] && return 0
    sleep 5
  done
  return 1
}
nposts() { python3 - "$WORK/hook" <<'PY'
import glob, json, sys
n = 0
for f in glob.glob(sys.argv[1] + '/*.json'):
    try: n += json.load(open(f)).get('kind') == 'daily checks'
    except Exception: pass
print(n)
PY
}
ksender   # records hook and deadhook (alert_channels)

# ---- K15: the order on the screen ----------------------------------------------------------------------------------------
KROW=$KBAD
[[ $(q "select count(*) from pgvigil.alert_channels where is_configured and kind = 'webhook' and name in ('hook', 'deadhook')") == 2 ]] || kfail "K15: the sender did not record the webhook channels: $(tail -3 "$WORK/ksender.log")"
KA=$(as "$COL" -c "select pgvigil.ensure_instance('k15-aaa', 'onprem', '16.0', 160000, false, '{}'::text[])")
KZ=$(as "$COL" -c "select pgvigil.ensure_instance('k15-zzz', 'onprem', '16.0', 160000, false, '{}'::text[])")
[[ $KA =~ ^[0-9]+$ && $KZ =~ ^[0-9]+$ ]] || kfail "K15: the two proof instances: $KA / $KZ"
for x in "$KA k15_fail1 error 0" "$KZ k15_fail1 error 0" "$KZ k15_fail2 error 0" "$KA k15_old1 ok 3" "$KA k15_old2 ok 3" "$KA k15_old3 ok 3"; do
  read -r i c st d <<<"$x"
  out=$(as "$COL" -c "select pgvigil.log_collection($i, '$c', now() - interval '$d days', 1, '$st', 'seeded by the proof (K15)')")
  [[ $out != *ERROR* ]] || kfail "K15: the seed $x: $out"
done
cat > "$WORK/kord.mjs" <<'JS'
// the Daily checks page as drawn: its tiles, the checks grid's (severity, instance) cells in order, the section's data-daily-post
const [port, U, token, route] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Network.enable');
await cmd('Network.setCookie', { name: 'pgvigil_session', value: token, url: U, httpOnly: true });
await cmd('Page.navigate', { url: U + '/?k=' + Date.now() + route });
let last = '', since = Date.now(), drawn = false;
for (const t = Date.now(); Date.now() - t < 30000; await sleep(200)) {
  const s = await ev(`(() => { const m = document.querySelector('main'); return m && m.querySelector('h2') ? m.textContent.length + ':' + m.querySelectorAll('*').length : 'busy'; })()`);
  if (s === 'busy' || s !== last) { last = s; since = Date.now(); continue; }
  if (Date.now() - since > 1200) { drawn = true; break; }
}
if (!drawn) { console.log(JSON.stringify({ error: 'the page did not settle: ' + route })); process.exit(1); }
// a grid over 200 rows draws its first 200 and a 'show more' line, while the tiles and the post count every row: its
// 'Show all' is clicked until no such line is left, so the read is of every row
for (let n = 0; n < 20; n++) {
  const left = await ev(`(() => { const b = [...document.querySelectorAll('main p.grid-more:not([hidden]) button')].filter(x => /^Show all /.test(x.textContent)); if (b.length) b[0].click(); return b.length; })()`);
  if (!left) break;
  await sleep(300);
}
const res = await ev(`(() => {
  const tiles = {}; for (const t of document.querySelectorAll('main .tiles .tile')) tiles[t.querySelector('.tile-l')?.textContent ?? ''] = t.querySelector('.tile-v')?.textContent ?? '';
  const g = [...document.querySelectorAll('main table')].find(t => [...t.querySelectorAll('thead th')].map(h => h.textContent.trim().toLowerCase()).slice(0, 3).join(',') === 'severity,instance,check');
  const rows = g ? [...g.querySelectorAll('tbody tr')].map(tr => [...tr.querySelectorAll('td')].slice(0, 2).map(td => td.textContent.replace(/\\s+/g, ' ').trim())) : null;
  const sec = document.querySelector('main [data-daily-post]');
  return { tiles, rows, total: g ? Number(g.dataset.rows ?? -1) : null, post: sec ? sec.getAttribute('data-daily-post') : null };
})()`);
console.log(JSON.stringify(res));
process.exit(0);
JS
# kwf <file of a JSON list of [severity, instance]>: '' when the rows are worst first by their own counts, else why
kwf() { python3 - "$1" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
none = [r for r in rows if r[1] == '']
if rows[:len(none)] != none: sys.exit('a row naming no instance after an instance row')
cnt, seq = {}, []
for s, i in rows[len(none):]:
    c = cnt.setdefault(i, [0, 0]); c[0 if s == 'critical' else 1] += 1
    if not seq or seq[-1] != i: seq.append(i)
if len(seq) != len(set(seq)): sys.exit(f"an instance's rows apart: {seq[:8]}")
want = sorted(cnt, key=lambda i: (-cnt[i][0], -cnt[i][1], i))
if seq != want: sys.exit(f'instances in the order {seq[:6]}, worst first is {want[:6]}')
PY
}
node "$WORK/kord.mjs" "$CDP" "$U" "$TOKEN" '#/checks?w=24h' > "$WORK/kord.json" || kfail "K15: the driver: $(cat "$WORK/kord.json")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["rows"] is None and sys.exit(1); json.dump(d["rows"], open(sys.argv[2], "w"))' "$WORK/kord.json" "$WORK/kord-rows.json" || kfail "K15: no checks grid on the page: $(head -c 400 "$WORK/kord.json")"
KSEEN=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(" ".join(sorted({i for _, i in r if i.startswith("k15-")})))' "$WORK/kord-rows.json" 2>/dev/null || true)
[[ $KSEEN == "k15-aaa k15-zzz" ]] || kfail "K15: the seeded instances on the page: '$KSEEN' (the seed did not reach the page: the row would test nothing)"
why=$(kwf "$WORK/kord-rows.json" 2>&1) || kfail "K15: the Daily checks page is not worst first: $why"
# every row was on the screen, and the two seeded instances hold their known bands in the worst-first order
why=$(python3 - "$WORK/kord.json" 2>&1 <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rows = d['rows']
if d.get('total') != len(rows): sys.exit(f"the read holds {len(rows)} of the grid's {d.get('total')} rows")
cnt = {}
for s, i in rows:
    c = cnt.setdefault(i, [0, 0]); c[0 if s == 'critical' else 1] += 1
if cnt.get('k15-aaa') != [1, 3] or cnt.get('k15-zzz') != [2, 0]: sys.exit(f"k15-aaa [critical, warnings] {cnt.get('k15-aaa')}, want [1, 3]; k15-zzz {cnt.get('k15-zzz')}, want [2, 0]")
first = {i: n for n, (s, i) in reversed(list(enumerate(rows)))}
if first['k15-zzz'] > first['k15-aaa']: sys.exit(f"k15-zzz's first row {first['k15-zzz']} is below k15-aaa's {first['k15-aaa']}")
PY
) || kfail "K15: the seeded bands on the screen: $why"
python3 - "$WORK/kord.json" <<'PY' || kfail "K15: the section's post numbers: $(head -c 600 "$WORK/kord.json")"
import json, sys
d = json.load(open(sys.argv[1])); p = json.loads(d['post'] or 'null')
if p is None: sys.exit('no data-daily-post on the section')
t, rows = d['tiles'], d['rows']
crit = sum(1 for s, _ in rows if s == 'critical')
seq = []
for _, i in rows:
    if i and i not in seq: seq.append(i)
want = {'instances': int(t['Instances']), 'critical': crit, 'warnings': len(rows) - crit}
got = {k: p.get(k) for k in want}
if got != want or int(t['Critical']) != crit: sys.exit(f'the post {got}, the page {want}, the Critical tile {t["Critical"]}')
if [w['name'] for w in p.get('worst', [])] != seq[:3]: sys.exit(f"the worst three {[w['name'] for w in p.get('worst', [])]}, the page's {seq[:3]}")
PY
kok "K15: the Daily checks page draws worst first (k15-zzz's two critical before k15-aaa's one, each instance's rows together, by the screen's own rows); its section carries the post's numbers equal to its tiles"

# ---- K16: a failed mail posts nothing -----------------------------------------------------------------------------------
# K16-K19b judge one UTC day (a second turn the same day, yesterday's turn): within 30 minutes of 00:00 UTC, wait for it
# (K16, K17, K18 and K18b each allow 3 + 3 minutes: 20 was under the rows' own worst case). The wait is 1805 s at most;
# a box job has no time limit of its own (its box stops after 4 h of run), and a T4 job runs about 19 minutes.
if (( 10#$(date -u +%H%M) >= 2330 )); then
  echo "K16: waits $(( 86400 - $(date -u +%s) % 86400 + 5 )) s for 00:00 UTC: the rows from here judge one UTC day"
  sleep $(( 86400 - $(date -u +%s) % 86400 + 5 ))
fi
KROW=$KBAD
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"badmail","post":["hook"]}') || true
[[ $c == 200 && $(jget "d['outcome']") == done && $(klive "post_channels") == "{hook}" && $(klive channel) == badmail ]] || kfail "K16: the keep with post [hook]: $c $(cat "$WORK/body"); post_channels $(klive "post_channels")"
KID=$(klive schedule_id); P0=$(nposts)
SEND=$(kturn "$KID" q) || kfail "K16: no serve queued the turn in 3 minutes"
kwaitsent "$SEND" || kfail "K16: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND") == failed && $(nposts) == "$P0" \
   && $(q "select (post_taken_at is null and posted_at is null)::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] \
  || kfail "K16: the failed mail $SEND: $(q "select outcome, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND"); posts $(nposts) (before $P0)"
# the turn carried its post (a turn with none would pass the line above for another reason)
[[ $(q "select (post is not null and post_channels = '{hook}' and post_day is not null)::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] \
  || kfail "K16: the failed turn $SEND carried no post: $(q "select post is not null, post_channels, post_day, post_error from pgvigil.report_mail_sends where send_id = $SEND")"
kok "K16: the kept row with post [hook] and the channel badmail: its turn (mail $SEND) carried its post, failed and posted nothing"

# ---- K17: the post --------------------------------------------------------------------------------------------------------
KROW=$KBAD
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"mail","post":["hook"]}') || true
[[ $c == 200 && $(klive schedule_id) == "$KID" && $(klive channel) == mail && $(klive "post_channels") == "{hook}" ]] || kfail "K17: the keep with the channel mail: $c $(cat "$WORK/body")"
[[ $(kget "$U") == 200 && $(jget "sorted(d['daily']['post_choices'])") == "['deadhook', 'hook']" && $(jget "d['daily']['post']") == "['hook']" ]] || kfail "K17: the page's state: $(cat "$WORK/body")"
P0=$(nposts)
SEND=$(kturn "$KID" q) || kfail "K17: no serve queued the turn in 3 minutes"
kwaitsent "$SEND" || kfail "K17: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND") == sent ]] || kfail "K17: mail $SEND: $(q "select outcome, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND")"
python3 - "$WORK/sink" post@pgvigil.test "$WORK/kmail-rows.json" <<'PY' || kfail "K17: the mail's checks grid: $(cat "$WORK/kmail-rows.json" 2>/dev/null | head -c 300)"
import email, glob, json, re, sys
from email import policy
from html.parser import HTMLParser
sink, to, out = sys.argv[1:4]
ms = [m for m in (email.message_from_binary_file(open(f, 'rb'), policy=policy.default) for f in sorted(glob.glob(sink + '/*.eml'))) if m['X-Pgvigil-Report'] and to in str(m['To'])]
if not ms: sys.exit(f'no mail to {to} in the sink')
body = [p for p in ms[-1].walk() if p.get_content_type() == 'text/html'][0].get_content()
class P(HTMLParser):
    def __init__(s): super().__init__(convert_charrefs=True); s.grids = []; s.cur = None; s.row = None; s.cell = None
    def handle_starttag(s, t, a):
        if t == 'table' and dict(a).get('role') != 'presentation': s.cur = {'head': [], 'rows': []}
        if t == 'tr' and s.cur is not None: s.row = []
        if t in ('th', 'td') and s.row is not None: s.cell = ['', t]
    def handle_endtag(s, t):
        if t in ('th', 'td') and s.cell is not None and s.row is not None: s.row.append((re.sub(r'\s+', ' ', s.cell[0]).strip(), s.cell[1])); s.cell = None
        if t == 'tr' and s.cur is not None and s.row is not None:
            if s.row and all(k == 'th' for _, k in s.row) and not s.cur['head']: s.cur['head'] = [x for x, _ in s.row]
            else: s.cur['rows'].append([x for x, _ in s.row])
            s.row = None
        if t == 'table' and s.cur is not None: s.grids.append(s.cur); s.cur = None
    def handle_data(s, d):
        if s.cell is not None: s.cell[0] += d
p = P(); p.feed(body)
g = next((g for g in p.grids if g['head'][:3] == ['severity', 'instance', 'check']), None)
if g is None: sys.exit('no checks grid in the mail')
json.dump([r[:2] for r in g['rows']], open(out, 'w'))
PY
why=$(kwf "$WORK/kmail-rows.json" 2>&1) || kfail "K17: the mail's checks grid is not worst first: $why"
[[ $(nposts) == $((P0 + 1)) ]] || kfail "K17: the sink holds $(($(nposts) - P0)) post(s) of this turn, want 1: $(tail -3 "$WORK/ksender.log")"
python3 - "$WORK/hook" "$WORK/kmail-rows.json" "$WORK/kord.json" <<'PY' || kfail "K17: the post's body"
import glob, json, os, sys
posts = []
for f in sorted(glob.glob(sys.argv[1] + '/*.json'), key=os.path.getmtime):
    try: b = json.load(open(f))
    except Exception: continue
    if b.get('kind') == 'daily checks': posts.append(b)
b, rows, page = posts[-1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3]))
crit = sum(1 for s, _ in rows if s == 'critical')
seq = []
for _, i in rows:
    if i and i not in seq: seq.append(i)
want = {'critical': crit, 'warnings': len(rows) - crit, 'instances': int(page['tiles']['Instances']), 'link': 'http://pgvigil.test/#/checks?w=24h'}
got = {k: b.get(k) for k in want}
if got != want: sys.exit(f'the post {got}, the mail {want}')
if [w.get('name') for w in b.get('worst', [])] != seq[:3]: sys.exit(f"the worst three {b.get('worst')}, the mail's {seq[:3]}")
for w in [str(crit) + ' critical', 'http://pgvigil.test/#/checks?w=24h'] + seq[:3]:
    if w not in b.get('text', ''): sys.exit(f'the text has no {w!r}: {b.get("text")!r}')
print(b.get('text', '').splitlines()[0])
PY
[[ $(q "select (posted_at is not null and post_error is null)::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] || kfail "K17: the send's post state: $(q "select post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND")"
for who in "$RDR" "$COL"; do
  for f in "report_mail_post_take(now(), $SEND)" "report_mail_post_record(now(), $SEND, '')"; do
    out=$(as "$who" -c "select * from pgvigil.$f")
    [[ $out == *"permission denied"* ]] || kfail "K17: $who called $f: $out"
  done
done
kok "K17: the turn (mail $SEND, sent): the mail's checks grid worst first; one post to hook with that mail's counts, the page's instance count, the worst three in order and the link; posted_at set; the reader and the collector may not take or record a post"

# ---- K17c: the dialog's post boxes (review-26 go2 S4) -------------------------------------------------------------------
KROW=$KBAD
L5=$(nlog)
kdrive change '#/checks?w=24h' 'post@pgvigil.test' > "$WORK/kd.json" || kfail "K17c: Change...: $(cat "$WORK/kd.json")"
[[ $(kd "d['line']") == *"Its counts are posted to hook."* && $(kd "d['title']") == "Change the daily mail" && $(kd "d['unlabelled']") == 0 \
   && $(kd "sorted(map(tuple, d['posts']))") == "[('deadhook', False), ('hook', True)]" && $(kd "d['said']") == "done "*"as asked"* ]] \
  || kfail "K17c: Change...'s dialog (the line, every field labelled, hook checked and deadhook not, Save 'done ... as asked'): $(cat "$WORK/kd.json")"
[[ $(klive schedule_id) == "$KID" && $(klive "post_channels") == "{hook}" && $(klive channel) == mail && $(klive "recipients[1]") == post@pgvigil.test && $(nlog) == "$L5" ]] \
  || kfail "K17c: a Save with nothing changed: schedule $(klive schedule_id) (was $KID), post_channels $(klive "post_channels"), $(( $(nlog) - L5 )) log row(s) written"
kok "K17c: Change...'s dialog on the kept mail: the line names the post, every field labelled, the hook box checked and deadhook's not; its Save with nothing changed answered done and wrote nothing"

# ---- K18: a second turn the same day posts nothing ------------------------------------------------------------------------
KROW=$KBAD
P0=$(nposts)
SEND2=$(kturn "$KID" q) || kfail "K18: no serve queued the second turn in 3 minutes"
kwaitsent "$SEND2" || kfail "K18: mail $SEND2 not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND2") == sent && $(nposts) == "$P0" \
   && $(q "select (post_taken_at is null and posted_at is null and post_error like '%post of % was taken already%')::text from pgvigil.report_mail_sends where send_id = $SEND2") == true ]] \
  || kfail "K18: the second turn $SEND2: $(q "select outcome, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND2"); posts $(nposts) (before $P0)"
kok "K18: a second turn the same day (mail $SEND2) was mailed and posted nothing; its post_error says the day's post was taken already"

# ---- K18b: a late turn posts under its due day (review-26 sql S2) ------------------------------------------------------------
KROW=$KBAD
P0=$(nposts); KYDAY=$(date -u -d '-1 day' +%Y-%m-%d)
SEND3=$(kturn "$KID" q '1 day') || kfail "K18b: no serve queued yesterday's turn in 3 minutes"
kwaitsent "$SEND3" || kfail "K18b: mail $SEND3 not answered in 3 minutes"
[[ $(q "select outcome || ' ' || post_day::text from pgvigil.report_mail_sends where send_id = $SEND3") == "sent $KYDAY" && $(nposts) == $((P0 + 1)) \
   && $(q "select (posted_at is not null)::text from pgvigil.report_mail_sends where send_id = $SEND3") == true ]] \
  || kfail "K18b: yesterday's turn (mail $SEND3): $(q "select outcome, post_day, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND3"); posts $(nposts) (before $P0)"
python3 - "$WORK/hook" "$KYDAY" <<'PY' || kfail "K18b: the late post's day"
import glob, json, os, sys
posts = [json.load(open(f)) for f in sorted(glob.glob(sys.argv[1] + '/*.json'), key=os.path.getmtime)]
posts = [b for b in posts if isinstance(b, dict) and b.get('kind') == 'daily checks']
if posts[-1].get('day') != sys.argv[2] or sys.argv[2] not in posts[-1].get('summary', ''): sys.exit(f"the post says {posts[-1].get('day')!r} / {posts[-1].get('summary')!r}, its turn was due {sys.argv[2]}")
PY
kok "K18b: a turn due yesterday and mailed today (mail $SEND3) posted once under its due day $KYDAY"

# ---- K19: a failed post is alerted ------------------------------------------------------------------------------------------
KROW=$KBAD
c=$(postj reportmail '{"op":"daily_drop"}') || true; [[ $c == 200 && $(nlive) == 0 ]] || kfail "K19: the drop: $c $(cat "$WORK/body")"
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"mail","post":["deadhook"]}') || true
[[ $c == 200 && $(klive "post_channels") == "{deadhook}" && $(klive schedule_id) != "$KID" ]] || kfail "K19: the keep with post [deadhook]: $c $(cat "$WORK/body")"
KID=$(klive schedule_id)
SEND=$(kturn "$KID" q) || kfail "K19: no serve queued the turn in 3 minutes"
kwaitsent "$SEND" || kfail "K19: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND") == sent \
   && $(q "select (posted_at is null and post_error like '%127.0.0.1%')::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] \
  || kfail "K19: mail $SEND's post: $(q "select outcome, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND")"
# the file drop writes each alert as indented JSON (one key a line): the notice's file by its setting, the mail by its value
grep -rl '"setting": "daily checks post failed"' "$WORK/drop" 2>/dev/null | xargs -r grep -l "mail $SEND," | grep -q . || kfail "K19: no 'daily checks post failed' notice naming mail $SEND in the file drop"
kok "K19: a post to deadhook failed (mail $SEND sent; post_error names 127.0.0.1) and a 'daily checks post failed' notice reached the file drop"

# ---- K19b: a sent mail whose page sent no counts is alerted (review-26 sql S3), by a real turn (proof 5) ---------------------
KROW=$KBAD
# the kept row's route set by hand to a page that draws no counts (the Summary): the turn is real, the words the server's
q "update pgvigil.report_mail_schedules set route = '#/summary' where schedule_id = $KID" >/dev/null 2>&1 || kfail "K19b: the kept row's route could not be set to the Summary"
SEND4=$(kturn "$KID" q '2 days') || kfail "K19b: no serve queued the turn in 3 minutes"
kwaitsent "$SEND4" || kfail "K19b: mail $SEND4 not answered in 3 minutes"
q "update pgvigil.report_mail_schedules set route = '#/checks?w=24h' where schedule_id = $KID" >/dev/null 2>&1 || kfail "K19b: the kept row's route could not be put back"
[[ $(klive route) == '#/checks?w=24h' ]] || kfail "K19b: the kept row's route after the put-back is '$(klive route)', not '#/checks?w=24h'"
[[ $(q "select outcome || ' ' || route from pgvigil.report_mail_sends where send_id = $SEND4") == "sent #/summary" \
   && $(q "select (post is null and post_taken_at is null and post_error like 'the drawn page sent no counts%')::text from pgvigil.report_mail_sends where send_id = $SEND4") == true ]] \
  || kfail "K19b: mail $SEND4 as the server wrote it: $(q "select outcome, route, post is null, post_error, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND4")"
grep -rl '"setting": "daily checks post failed"' "$WORK/drop" 2>/dev/null | xargs -r grep -l "mail $SEND4, sent): the drawn page sent no counts" | grep -q . || kfail "K19b: no 'daily checks post failed' notice naming mail $SEND4 and 'sent no counts' in the file drop"
kok "K19b: a turn whose page drew no counts (the kept row's route set to the Summary by hand; mail $SEND4, sent): the server recorded 'the drawn page sent no counts' on its send and the sender alerted it ('daily checks post failed')"

# ---- K19c: the keep's post list through the door (review-26 go2 S5, S6) and a kept channel that is gone (N3) -----------------
KROW=$KBAD
KKEEP='"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"mail"'
L6=$(nlog)
c=$(postj reportmail "{$KKEEP}") || true
[[ $c == 200 && $(jget "d['outcome']") == done && $(klive schedule_id) == "$KID" && $(klive "post_channels") == "{deadhook}" && $(nlog) == "$L6" ]] \
  || kfail "K19c: a keep with no post field (a page loaded before the upgrade): $c $(cat "$WORK/body"); post_channels $(klive "post_channels"), $(( $(nlog) - L6 )) log row(s) written"
c=$(postj reportmail "{$KKEEP,\"post\":[\"hook\"]}") || true
[[ $c == 200 && $(klive "post_channels") == "{hook}" ]] || kfail "K19c: the keep with post [hook]: $c $(cat "$WORK/body"); post_channels $(klive "post_channels")"
L7=$(nlog)
c=$(postj reportmail "{$KKEEP,\"post\":[\"hook\",\"deadhook\"]}") || true
[[ $c == 200 && $(jget "d['detail']") == *changed* && $(klive "post_channels") == "{deadhook,hook}" && $(nlog) == $((L7 + 1)) ]] \
  || kfail "K19c: one more post channel is a change: $c $(cat "$WORK/body"); post_channels $(klive "post_channels"), $(( $(nlog) - L7 )) log row(s) written"
# deadhook as a channel the sender no longer records (no sender runs inside this row); put back after
q "update pgvigil.alert_channels set is_configured = false where name = 'deadhook'" >/dev/null || kfail "K19c: deadhook could not be marked as no longer recorded"
kdrive change '#/checks?w=24h' 'post@pgvigil.test' > "$WORK/kd.json" || kfail "K19c: Change...: $(cat "$WORK/kd.json")"
[[ $(kd "d['note']") == *"deadhook is no longer a recorded webhook channel: Save drops it"* && $(kd "sorted(map(tuple, d['posts']))") == "[('hook', True)]" && $(kd "d['said']") == "done "*changed* \
   && $(klive "post_channels") == "{hook}" ]] || kfail "K19c: the dialog with a kept channel that is gone: $(cat "$WORK/kd.json"); post_channels $(klive "post_channels")"
q "update pgvigil.alert_channels set is_configured = true where name = 'deadhook'" >/dev/null || kfail "K19c: deadhook could not be put back"
c=$(postj reportmail "{$KKEEP,\"post\":[]}") || true
[[ $c == 200 && $(klive schedule_id) == "$KID" && $(klive "post_channels") == "-" ]] || kfail "K19c: the keep with post []: $c $(cat "$WORK/body"); post_channels $(klive "post_channels")"
kok "K19c: a keep with no post field left {deadhook} and wrote nothing; post [hook] then [hook, deadhook] was a change; the dialog named the kept channel that is gone and its Save dropped it; post [] cleared the list"

# ---- K21: the role ------------------------------------------------------------------------------------------------------------
KROW=$KBAD
KVUSER=proofview; KVPW=$(openssl rand -hex 12)
PGVIGIL_PASSWORD=$KVPW "$BIN" user add -config "$CFG" -role viewer $KVUSER >/dev/null 2>&1 || kfail "K21: user add -role viewer"
login "$WORK/jarv" "$KVUSER" "$KVPW" || kfail "K21: the viewer's login"
L4=$(nlog); N4=$(nlive)
[[ $(kget "$U" "$WORK/jarv") == 200 && $(jget "d['daily']['writable']") == False && $(jget "d['daily']['reason']") == *"changing a report mail schedule needs the admin role: $KVUSER is a viewer"* ]] || kfail "K21: a viewer's part=daily: $(cat "$WORK/body")"
c=$(code -b "$WORK/jarv" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["v@pgvigil.test"],"channel":"mail"}' "$U/api/reportmail") || true
[[ $c == 403 && $(jget "d['error']") == *"changing a report mail schedule needs the admin role: $KVUSER is a viewer"* && $(nlog) == "$L4" && $(nlive) == "$N4" ]] || kfail "K21: a viewer's daily_keep: $c $(cat "$WORK/body")"
kok "K21: a viewer's Daily checks mail is read only with the role's words (part=daily writable false; daily_keep 403); nothing kept"

# ---- K20: the block's post: list ----------------------------------------------------------------------------------------------
KROW=$KBAD
kpcfg() { { cat "$WORK/cfg-kpost.yaml"; printf 'reports:\n  daily_checks:\n%b' "$2"; } > "$1"; }
kpcfg "$WORK/cfg-kpon.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [post@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n    post: [hook]\n"
kpcfg "$WORK/cfg-kpbad.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [post@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n    post: [mail]\n"
PK=$(freeport); UK="http://127.0.0.1:$PK"
KSERVE_SOFT=1 kserve "$WORK/cfg-kpon.yaml" "$PK" servekpost.log || kfail "K20: the serve with post: [hook] did not start: $(tail -2 "$WORK/servekpost.log" | cut -c1-300)"
SK=$KPID
kwait 30 filekept || kfail "K20: the serve did not keep the row in 30 s: $(klive "kept_by || ' ' || coalesce(post_channels::text, '-')"); $(grep -i 'daily checks' "$WORK/servekpost.log" | tail -2)"
[[ $(klive "post_channels") == "{hook}" ]] || kfail "K20: the block's post: $(klive "post_channels")"
kstop "$SK"
rc=0; out=$(timeout 20 "$BIN" serve -config "$WORK/cfg-kpbad.yaml" -listen "127.0.0.1:$(freeport)" 2>&1) || rc=$?
[[ $rc != 0 && $rc != 124 && $out == *"reports.daily_checks: post: mail is not a webhook channel of the alerts: block"* ]] || kfail "K20: post: [mail] (exit $rc): $(tail -2 <<<"$out")"
kpcfg "$WORK/cfg-kpurl.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [post@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n    post: [https://hooks.example/T0/kproofsecret]\n"
rc=0; out=$(timeout 20 "$BIN" serve -config "$WORK/cfg-kpurl.yaml" -listen "127.0.0.1:$(freeport)" 2>&1) || rc=$?
[[ $rc != 0 && $rc != 124 && $out == *"reports.daily_checks: post: entry 1 of the list is not a webhook channel of the alerts: block"* && $out != *kproofsecret* ]] \
  || kfail "K20: post: [a webhook's URL] (exit $rc; the URL in serve's words: $([[ $out == *kproofsecret* ]] && echo yes || echo no)): $(tail -2 <<<"$out" | sed 's#https://[^ ]*#<the URL>#g')"
kok "K20: the block's post: [hook] kept post_channels {hook} (kept_by file); post: [mail] stopped serve at start in words; a webhook's URL for a name stopped it by its place, the URL never printed"

# ---- K20b: a post: channel the sender has not recorded yet is waited for, never refused for good (review-26 sql B1) ----------
KROW=$KBAD
python3 - "$WORK/cfg-kpost.yaml" "$WORK/cfg-kpost2.yaml" <<'PY'
import sys
out = []
for l in open(sys.argv[1]).read().splitlines():
    out.append(l)
    if l.startswith('alerts:'):
        out.append('  - {name: newhook, kind: webhook, min_severity: critical, instances: [proof-none], webhook: {url: env:PGV_HOOK_URL, format: json}}')
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
PY
{ cat "$WORK/cfg-kpost2.yaml"; printf 'reports:\n  daily_checks:\n    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [post@pgvigil.test]\n    as: %s\n    channel: mail\n    post: [newhook]\n' "$UIUSER"; } > "$WORK/cfg-kpnew.yaml"
[[ $(q "select count(*) from pgvigil.alert_channels where name = 'newhook'") == 0 ]] || kfail "K20b: newhook was recorded before the row"
PK=$(freeport); UK="http://127.0.0.1:$PK"; L8=$(nlog)
KSERVE_SOFT=1 kserve "$WORK/cfg-kpnew.yaml" "$PK" servekpnew.log || kfail "K20b: the serve with post: [newhook] did not start: $(tail -2 "$WORK/servekpnew.log" | cut -c1-300)"
SK=$KPID
sleep 10
[[ $(nlog) == "$L8" ]] || kfail "K20b: $(( $(nlog) - L8 )) row(s) written to report_mail_log while the setting could not be kept yet: $(q "select outcome || ': ' || left(detail, 120) from pgvigil.report_mail_log order by log_id desc limit 1")"
[[ $(klive "post_channels") != "{newhook}" ]] && grep -q 'post: newhook is not a webhook channel the sender' "$WORK/servekpnew.log" || kfail "K20b: before the sender recorded newhook: $(klive "post_channels"); $(grep -i 'daily checks' "$WORK/servekpnew.log" | tail -2)"
"$BIN" alerts -config "$WORK/cfg-kpost2.yaml" >> "$WORK/ksender.log" 2>&1 || true   # a sender that names newhook records it
newkept() { [[ $(klive "post_channels") == "{newhook}" ]] && echo y || echo n; }
kwait 75 newkept || kfail "K20b: the row after the sender recorded newhook: $(klive "post_channels"); $(grep -i 'daily checks' "$WORK/servekpnew.log" | tail -3)"
kstop "$SK"
kok "K20b: post: [newhook] before the sender recorded it: nothing kept and nothing logged, the serve's log says why; kept with {newhook} within 75 s of the sender's pass, no restart"
# ---- K22-K26: DAILY-SQL - a SQL Server instance's Daily checks rows are its Summary's own cells -----------------------------
# ksql.mjs <port> <U> <token> sum|checks|ack <instance id>: one browser reads the fleet Summary (every cell's group,
# instance, level, words and link; the Needs attention strip's links) or the Daily checks page (its open grid, its
# acknowledged grid, the tiles, the section's post), or acknowledges one instance's open cells through the strip's
# Acknowledge (its dialog's 'until the check changes', as a viewer's browser does)
cat > "$WORK/ksql.mjs" <<'JS'
const [port, U, token, mode, arg] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const open = async (route) => {
  await cmd('Page.navigate', { url: U + '/?k=' + Date.now() + route });
  let last = '', since = Date.now();
  for (const t = Date.now(); Date.now() - t < 40000; await sleep(200)) {
    const s = await ev(`(() => { const m = document.querySelector('main'); return m && m.querySelector('h2') ? m.textContent.length + ':' + m.querySelectorAll('*').length : 'busy'; })()`);
    if (s === 'busy' || s !== last) { last = s; since = Date.now(); continue; }
    if (Date.now() - since > 1500) return true;
  }
  return false;
};
await cmd('Network.enable');
await cmd('Network.setCookie', { name: 'pgvigil_session', value: token, url: U, httpOnly: true });
const out = {};
if (mode === 'sum' || mode === 'ack') {
  if (!await open('#/summary?w=24h')) { console.log(JSON.stringify({ error: 'the Summary did not settle' })); process.exit(1); }
  // the strip's 'Show all N' first (it draws 8 lines until then - review-28 rows B2), then every '+n more' opened, so each
  // instance's every reason link is there
  for (let n = 0; n < 3; n++) { const c = await ev(`(() => { const b = [...document.querySelectorAll('main button.link[aria-expanded="false"]')].find(x => /^Show all \\d+$/.test(x.textContent)); if (b) b.click(); return !!b; })()`); if (!c) break; await sleep(300); }
  for (let n = 0; n < 40; n++) { const c = await ev(`(() => { const b = [...document.querySelectorAll('main .attention-row button.link')].find(x => /^\\+\\d+ more$/.test(x.textContent)); if (b) b.click(); return !!b; })()`); if (!c) break; await sleep(100); }
}
if (mode === 'sum') {
  out.instances = await ev(`fetch('/api/instances', { headers: { 'X-Pgvigil': '1' } }).then(r => r.json()).then(t => t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])))).then(rs => rs.map(r => ({ id: Number(r.instance_id), name: String(r.name), engine: String(r.engine ?? 'postgres') })))`);
  out.cells = await ev(`[...document.querySelectorAll('main td.status [data-group][data-inst]')].map(e => { const td = e.closest('td'); const th = td.closest('table').tHead?.rows[0]?.cells[td.cellIndex];
    return { inst: Number(e.dataset.inst), group: e.dataset.group, cls: td.className, text: e.dataset.text ?? '', href: e.getAttribute('href'), head: ((th?.querySelector('.th-label') ?? th)?.textContent ?? '').trim() }; })`);
  out.strip = await ev(`[...document.querySelectorAll('main .attention-row[data-inst] a[data-group]')].map(a => ({ inst: Number(a.closest('.attention-row').dataset.inst), group: a.dataset.group, href: a.getAttribute('href') }))`);
}
if (mode === 'ack') {
  const hit = await ev(`(() => { const b = [...document.querySelectorAll('main .attention-row[data-inst="${Number(arg)}"] button')].find(x => x.textContent === 'Acknowledge'); if (!b || b.getAttribute('aria-disabled') === 'true') return false; b.click(); return true; })()`);
  if (!hit) { console.log(JSON.stringify({ error: 'no Acknowledge on the strip for instance ' + arg })); process.exit(1); }
  for (let n = 0; n < 50 && !await ev(`!!document.querySelector('dialog[open] form')`); n++) await sleep(100);
  out.change = await ev(`[...document.querySelectorAll('dialog[open] label')].some(l => /until the check changes/.test(l.textContent) && l.querySelector('input[type=checkbox]')?.checked)`);
  await ev(`document.querySelector('dialog[open] button[type=submit]').click()`);
  let s = ''; for (let n = 0; n < 100; n++) { await sleep(200); s = await ev(`document.querySelector('dialog[open] [role=status]')?.textContent ?? ''`); if (/done|not saved/.test(s)) break; }
  out.said = s;
}
if (mode === 'checks') {
  if (!await open('#/checks?w=24h')) { console.log(JSON.stringify({ error: 'the Daily checks page did not settle' })); process.exit(1); }
  for (let n = 0; n < 20; n++) { const c = await ev(`(() => { const b = [...document.querySelectorAll('main p.grid-more:not([hidden]) button')].filter(x => /^Show all /.test(x.textContent)); if (b.length) b[0].click(); return b.length; })()`); if (!c) break; await sleep(300); }
  Object.assign(out, await ev(`(() => {
    const heads = t => [...t.querySelectorAll('thead th')].map(h => h.textContent.trim().toLowerCase());
    const read = t => { if (!t) return null; const h = heads(t); return [...t.querySelectorAll('tbody tr')].map(tr => { const td = [...tr.querySelectorAll('td')]; const o = {};
      h.forEach((k, i) => { o[k] = (td[i]?.textContent ?? '').replace(/\\s+/g, ' ').trim(); });
      const a = td[h.indexOf('instance')]?.querySelector('a'); o.href = a?.getAttribute('href') ?? null; o.group = a?.dataset.group ?? null; o.inst = a?.dataset.inst ? Number(a.dataset.inst) : null; o.text = a?.dataset.text ?? null; return o; }); };
    const ts = [...document.querySelectorAll('main table')];
    const tiles = {}; for (const t of document.querySelectorAll('main .tiles .tile')) tiles[t.querySelector('.tile-l')?.textContent ?? ''] = t.querySelector('.tile-v')?.textContent ?? '';
    return { tiles, post: document.querySelector('main [data-daily-post]')?.getAttribute('data-daily-post') ?? null,
      open: read(ts.find(t => heads(t).slice(0, 3).join(',') === 'severity,instance,check')),
      acked: read(ts.find(t => heads(t)[0] === 'acknowledged')) };
  })()`));
}
console.log(JSON.stringify(out));
process.exit(0);
JS
ksql() { node "$WORK/ksql.mjs" "$CDP" "$U" "$TOKEN" "$@"; }
# kgrade <<'PY' ... PY: a Python body over the reads in $WORK (ksum.json as S, kchk.json as C; the later reads by ld()), MS the
# SQL Server instances' ids, NAME the instances' names; the body exits 1 with its words on a miss
cat > "$WORK/kprelude.py" <<'PY'
import json, os, sys
w = sys.argv[1]
ld = lambda n: json.load(open(os.path.join(w, n))) if os.path.exists(os.path.join(w, n)) else None
S, C = ld('ksum.json'), ld('kchk.json')
# a read that is missing or failed ends the row in words, never a traceback (review-28 rows S5)
usable = lambda x, k: isinstance(x, dict) and isinstance(x.get(k), list)
def need(x, k, what):
    if not usable(x, k): sys.exit(f'{what} is missing or failed: {str(x)[:200]}')
    return x
need(S, 'instances', 'the Summary read'); need(S, 'cells', 'the Summary read'); need(C, 'open', 'the Daily checks read')
MS = {i['id'] for i in S['instances'] if i['engine'] == 'sqlserver'}
NAME = {i['id']: i['name'] for i in S['instances']}
LEFT = {'activity', 'snapshot'}   # blocking (Q4), and Snapshot Age whose rows ('collection stale') the overview holds already
KS1, KS2, KZZ = (int(os.environ.get(k) or 0) for k in ('KS1', 'KS2', 'KZZ'))
def lvl(cls):
    c = ' ' + cls + ' '
    return 'critical' if ' crit ' in c else 'warning' if ' warn ' in c else None
def want_of(S):   # (instance, group) -> (severity, words, column) of every SQL Server cell at warning or critical
    # (Collection Errors at warning only: at critical its collection is failing now, the overview's row - K27)
    return {(c['inst'], c['group']): (lvl(c['cls']), c['text'], c['head']) for c in S['cells']
            if c['inst'] in MS and lvl(c['cls']) and c['group'] not in LEFT and not (c['group'] == 'errors' and lvl(c['cls']) == 'critical')}
def rows_of(rows):  # the SQL Server cell rows of a grid: (instance, group) -> the row
    return {(r['inst'], r['group']): r for r in (rows or []) if r.get('group') and r.get('inst') in MS}
key = lambda r: (r['severity'], r['instance'], r['check'], r['object'])
PY
kgrade() { cat "$WORK/kprelude.py" - > "$WORK/kgrade.py"; python3 "$WORK/kgrade.py" "$WORK"; }
KROW=$KBAD
KS1=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'"); KS2=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql02'")
KZZ=$(q "select instance_id from pgvigil.instances where name = 'k15-zzz'"); export KS1 KS2 KZZ
[[ -n $KS1 && -n $KS2 && -n $KZZ ]] || kfail "K22: the demo's demo-onprem-sql01 / sql02 or K15's k15-zzz not in the store ('$KS1' '$KS2' '$KZZ')"
# the seeds, as the repository's owner through the product's own import functions: sql02's full and differential
# backups judged late (its thresholds: 0.01 h), and one CHECKDB finding (a read of the checkdb area and its run)
q "select pgvigil.import_mssql_hadr_thresholds($KS2, now(), '[{\"full_backup_hours\": 0.01, \"diff_backup_hours\": 0.01}]'::jsonb)" > "$WORK/kseed.log" 2>&1 \
  || kfail "K22: the seed of sql02's backup thresholds: $(tail -1 "$WORK/kseed.log")"
q "select pgvigil.log_collection($KS2, 'mssql_checks', now(), 5, 'ok', NULL); select pgvigil.import_mssql_checks($KS2, now(), '[{\"kind\":\"area\",\"area\":\"checkdb\",\"read\":1},{\"kind\":\"finding\",\"area\":\"checkdb\",\"check_name\":\"last good CHECKDB older than 7 days\",\"object\":\"Sales\",\"rule\":\"k22 seed\",\"severity\":\"warning\",\"value\":\"9 days\",\"explain\":\"database Sales: the last good CHECKDB is 9 days old\"}]'::jsonb)" > "$WORK/kseed.log" 2>&1 \
  || kfail "K22: the seed of sql02's CHECKDB finding: $(tail -1 "$WORK/kseed.log")"
ksread() { ksql sum > "$WORK/ksum.json" || kfail "$1: the Summary: $(head -c 300 "$WORK/ksum.json")"
  ksql checks > "$WORK/kchk.json" || kfail "$1: the Daily checks page: $(head -c 300 "$WORK/kchk.json")"; }
ksread K22
k22() { kgrade 2>&1 <<'PY'
want, got = want_of(S), rows_of(C['open'])
miss = [k for k in [(KS2, 'full'), (KS2, 'diff'), (KS2, 'checkdb')] if k not in want]
if miss: sys.exit(f'the seeds did not reach the Summary: {miss} (the row would test less)')
blk = [r for r in C['open'] if r.get('group') == 'activity']
if blk: sys.exit(f'blocking has rows (left out, Q4): {len(blk)}')
lost = sorted(f'{NAME[i]} {g}' for i, g in set(want) - set(got)); extra = sorted(f'{NAME[i]} {g}' for i, g in set(got) - set(want))
if lost or extra: sys.exit(f'the Summary holds {len(want)} SQL Server cells at warning or critical, the Daily checks page {len(set(got) & set(want))} of them; missing {lost[:8]}; rows without a cell {extra[:8]}')
bad = [f"{NAME[i]} {g}: row {r['severity']} / {r['check']} / {r['object']!r}, cell {want[(i, g)]}" for (i, g), r in got.items()
       if (r['severity'], r['object'], r['check']) != want[(i, g)]]
if bad: sys.exit(f"rows not in their cell's words and column label: {bad[:4]}")
print(len(want))
PY
}
# a cell's words move with the clock (', stale', uptime's hours): one difference reads both pages again once (review-28 rows S1)
n22=$(k22) || { ksread K22; n22=$(k22) && echo "K22: equal on the second read (the first differed)"; } || kfail "K22: $n22"
kok "K22: every SQL Server cell at warning or critical on the Summary ($n22 of them, the seeded FULL, DIFF and CHECKDB among them; blocking left out) is a row of the Daily checks page with the cell's level, words and column label, and no row without its cell"

# ---- K23: each SQL Server row's link is its cell's own landing ------------------------------------------------------------
KROW=$KBAD
why=$(kgrade 2>&1 <<'PY'
strip = {(s['inst'], s['group']): s['href'] for s in S['strip']}
cellh = {(c['inst'], c['group']): c['href'] for c in S['cells'] if c['href']}
got = rows_of(C['open'])
if not got: sys.exit('no SQL Server cell row to compare')
bad = [f"{NAME[i]} {g}: row {r['href']}, the strip {strip.get((i, g))}, the cell {cellh.get((i, g))}" for (i, g), r in got.items()
       if not r['href'] or r['href'] != strip.get((i, g)) or ((i, g) in cellh and cellh[(i, g)] != r['href'])]
if bad: sys.exit(f'{len(bad)} of {len(got)} links differ: {bad[:4]}')
PY
) || kfail "K23: $why"
kok "K23: each SQL Server row's instance link is its cell's own (the Summary cell's link where it has one, the Needs attention strip's for the same cell)"

# ---- K24: the acknowledgement is the cell's, for both engines, and the scheduled mail draws it (the lead 18:47) ----------
KROW=$KBAD
for who in "$KS2" "$KZZ"; do
  ksql ack "$who" > "$WORK/kack.json" || kfail "K24: Acknowledge on the strip for instance $who: $(head -c 300 "$WORK/kack.json")"
  [[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(bool(d.get("change")) and d.get("said","").startswith("done "))' "$WORK/kack.json" 2>/dev/null) == True ]] \
    || kfail "K24: the strip's Acknowledge for instance $who (until the check changes, done): $(cat "$WORK/kack.json")"
done
[[ $(q "select count(distinct instance_id) from pgvigil.acks where kind = 'ack' and instance_id in ($KS2, $KZZ) and until_change and seen_state is not null and ended_at is null") == 2 ]] \
  || kfail "K24: the acknowledgements stored: $(q "select string_agg(instance_id || ' ' || check_key || ' ' || until_change, ', ') from pgvigil.acks where kind = 'ack' and ended_at is null")"
ksql checks > "$WORK/kchk2.json" || kfail "K24: the Daily checks page after the acknowledgements: $(head -c 300 "$WORK/kchk2.json")"
why=$(kgrade 2>&1 <<'PY'
C2 = ld('kchk2.json')
if C2['acked'] is None: sys.exit('no acknowledged grid on the page')
gone = ('demo-onprem-sql02', 'k15-zzz')
still = [r for r in C2['open'] if r.get('instance') in gone]
if still: sys.exit(f"{len(still)} row(s) of the acknowledged instances still open: {[(r.get('instance'), r.get('check')) for r in still][:4]}")
before = sorted(key(r) for r in C['open'] if r.get('instance') in gone)
acked = sorted(key(r) for r in C2['acked'] if r.get('instance') in gone)
if not before or acked != before: sys.exit(f'{len(before)} row(s) of sql02 / k15-zzz open before, {len(acked)} acknowledged; first difference {next((x for x in zip(acked, before) if x[0] != x[1]), None)}')
if not all('acknowledged by' in r.get('acknowledged', '') for r in C2['acked']): sys.exit(f'an acknowledged row without its words: {C2["acked"][:1]}')
crit = sum(1 for r in C2['open'] if r['severity'] == 'critical')
p = json.loads(C2['post'])
if (int(C2['tiles']['Critical']), int(C2['tiles']['Warnings'])) != (crit, len(C2['open']) - crit) or (p['critical'], p['warnings']) != (crit, len(C2['open']) - crit):
    sys.exit(f"tiles {C2['tiles']}, post {p['critical']}/{p['warnings']}, open rows {crit}/{len(C2['open']) - crit}")
if any(x['name'] in gone for x in p.get('worst', [])): sys.exit(f"an acknowledged instance in the worst three: {p['worst']}")
if p.get('acknowledged') != len(C2['acked']): sys.exit(f"the section's post says {p.get('acknowledged')} acknowledged, the grid holds {len(C2['acked'])}")
PY
) || kfail "K24: the page: $why"
# the scheduled mail: rendered by the serve with no viewer's browser, from the acknowledgements the server holds
KID=$(klive schedule_id)
[[ $KID != - && $(klive route) == '#/checks?w=24h' ]] || kfail "K24: no live Daily checks schedule on its route to turn (schedule '$KID', route '$(klive route)')"
SEND5=$(kturn "$KID" q) || kfail "K24: no serve queued the turn in 3 minutes"
kwaitsent "$SEND5" || kfail "K24: mail $SEND5 not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND5") == sent ]] || kfail "K24: mail $SEND5: $(q "select outcome, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND5")"
q "select post from pgvigil.report_mail_sends where send_id = $SEND5" > "$WORK/kpost5.json" 2>/dev/null || true
q "select rows from pgvigil.report_mail_sends where send_id = $SEND5" > "$WORK/krows5.txt" 2>/dev/null || true
ksql checks > "$WORK/kchk2b.json" || kfail "K24: the Daily checks page after the turn: $(head -c 300 "$WORK/kchk2b.json")"
KTO=$(klive "recipients[1]")
python3 - "$WORK/sink" "$KTO" "$WORK/kmail2.json" <<'PY' || kfail "K24: the mail's grids: $(head -c 300 "$WORK/kmail2.json" 2>/dev/null)"
import email, glob, json, re, sys
from email import policy
from html.parser import HTMLParser
sink, to, out = sys.argv[1:4]
ms = [m for m in (email.message_from_binary_file(open(f, 'rb'), policy=policy.default) for f in sorted(glob.glob(sink + '/*.eml'))) if m['X-Pgvigil-Report'] and to in str(m['To'])]
if not ms: sys.exit(f'no mail to {to} in the sink')
body = [p for p in ms[-1].walk() if p.get_content_type() == 'text/html'][0].get_content()
class P(HTMLParser):
    def __init__(s): super().__init__(convert_charrefs=True); s.grids = []; s.cur = None; s.row = None; s.cell = None
    def handle_starttag(s, t, a):
        if t == 'table' and dict(a).get('role') != 'presentation': s.cur = {'head': [], 'rows': []}
        if t == 'tr' and s.cur is not None: s.row = []
        if t in ('th', 'td') and s.row is not None: s.cell = ['', t]
    def handle_endtag(s, t):
        if t in ('th', 'td') and s.cell is not None and s.row is not None: s.row.append((re.sub(r'\s+', ' ', s.cell[0]).strip(), s.cell[1])); s.cell = None
        if t == 'tr' and s.cur is not None and s.row is not None:
            if s.row and all(k == 'th' for _, k in s.row) and not s.cur['head']: s.cur['head'] = [x.lower() for x, _ in s.row]
            else: s.cur['rows'].append([x for x, _ in s.row])
            s.row = None
        if t == 'table' and s.cur is not None: s.grids.append(s.cur); s.cur = None
    def handle_data(s, d):
        if s.cell is not None: s.cell[0] += d
p = P(); p.feed(body)
g = next((g for g in p.grids if g['head'][:3] == ['severity', 'instance', 'check']), None)
a = next((g for g in p.grids if g['head'][:1] == ['acknowledged']), None)
json.dump({'open': [dict(zip(g['head'], r)) for r in g['rows']] if g else None, 'acked': [dict(zip(a['head'], r)) for r in a['rows']] if a else None}, open(out, 'w'))
PY
why=$(kgrade 2>&1 <<'PY'
M, C2, C2b = ld('kmail2.json'), ld('kchk2.json'), ld('kchk2b.json')
if not usable(M, 'open'): sys.exit(f'no checks grid in the mail: {str(M)[:200]}')
if M.get('acked') is None: sys.exit('no acknowledged grid in the scheduled mail (its render drew none)')
need(C2, 'open', 'the page read before the turn'); need(C2b, 'open', 'the page read after the turn')
mo, ma = sorted(map(key, M['open'])), sorted(map(key, M['acked']))
# the mail was drawn between the two page reads: it equals one of them (a cell's words may move between - review-28 rows S1)
pages = [x for x in (C2, C2b) if sorted(map(key, x['open'])) == mo and sorted(map(key, x['acked'] or [])) == ma]
if not pages:
    po = sorted(map(key, C2b['open']))
    sys.exit(f"the mail's open rows {len(mo)} / acknowledged {len(ma)}, the page's {len(C2['open'])} / {len(C2['acked'] or [])} before the turn and {len(po)} / {len(C2b['acked'] or [])} after; first difference {next((x for x in zip(mo, po) if x[0] != x[1]), None)}")
P = pages[0]
raw = open(os.path.join(w, 'kpost5.json')).read().strip()
if not raw: sys.exit("the turn's send carries no post")
p = json.loads(raw); crit = sum(1 for r in P['open'] if r['severity'] == 'critical')
if (p['critical'], p['warnings']) != (crit, len(P['open']) - crit): sys.exit(f"the send's post {p['critical']}/{p['warnings']}, the page's open rows {crit}/{len(P['open']) - crit}")
if p.get('acknowledged') != len(P['acked'] or []): sys.exit(f"the send's post says {p.get('acknowledged')} acknowledged, the mail's grid {len(P['acked'] or [])}")
rows = open(os.path.join(w, 'krows5.txt')).read().strip()
if rows != str(len(P['open'])): sys.exit(f"the send row's rows {rows!r}, the open rows {len(P['open'])} (the acknowledged grid is not counted - review-28 code S1)")
PY
) || kfail "K24: the scheduled mail $SEND5: $why"
# ended, they count again
for a in $(q "select ack_id from pgvigil.acks where kind = 'ack' and instance_id in ($KS2, $KZZ) and ended_at is null"); do
  c=$(postj ack/end "{\"ack_id\":$a}") || true; [[ $c == 200 ]] || kfail "K24: ending ack $a: $c $(cat "$WORK/body")"
done
k24end() { ksql checks > "$WORK/kchk3.json" || { echo "the page after the ends: $(head -c 300 "$WORK/kchk3.json")"; return 1; }
  kgrade 2>&1 <<'PY'
C3 = need(ld('kchk3.json'), 'open', 'the page read after the ends')
two = ('demo-onprem-sql02', 'k15-zzz')
now, then = sorted(key(r) for r in C3['open'] if r.get('instance') in two), sorted(key(r) for r in C['open'] if r.get('instance') in two)
if now != then or C3['acked']: sys.exit(f"sql02's and k15-zzz's open rows {len(now)} (before the acknowledgements {len(then)}), an acknowledged grid {bool(C3['acked'])}; first difference {next((x for x in zip(now, then) if x[0] != x[1]), None)}")
PY
}
why=$(k24end) || why=$(k24end) || kfail "K24: after the ends (read twice): $why"
kok "K24: Acknowledge (until the check changes) on the Summary's strip for demo-onprem-sql02 and k15-zzz: their rows moved to the page's acknowledged grid with the words, out of the tiles, the post's numbers and the worst three; the scheduled mail $SEND5 - rendered by the serve, no viewer's browser - drew the same open and acknowledged rows, its post the same counts and acknowledged count, its send row the open rows alone; ended, they count again"

# ---- K25: the mail and the post carry the SQL Server rows -----------------------------------------------------------------
KROW=$KBAD
why=$(kgrade 2>&1 <<'PY'
M, C2 = ld('kmail2.json'), ld('kchk2.json')
need(M, 'open', 'the scheduled mail read'); need(C2, 'open', 'the page read after the acknowledgements')
raw = open(os.path.join(w, 'kpost5.json')).read().strip() if os.path.exists(os.path.join(w, 'kpost5.json')) else ''
if not raw: sys.exit("the turn's send carries no post")
c1 = [r for r in C2['open'] if r['instance'] == 'demo-onprem-sql01']
cells1 = [r for r in c1 if r.get('inst') == KS1]
if not cells1: sys.exit('no demo-onprem-sql01 cell row on the page')
mail1 = [(r['severity'], r['check'], r['object']) for r in M['open'] if r['instance'] == 'demo-onprem-sql01']
if mail1 != [(r['severity'], r['check'], r['object']) for r in c1]: sys.exit(f'demo-onprem-sql01 in the mail {mail1[:4]}, on the page {[(r["severity"], r["check"], r["object"]) for r in c1][:4]}')
p = json.loads(raw)
seq = []
for r in C2['open']:
    if r['instance'] and r['instance'] not in seq: seq.append(r['instance'])
if [x['name'] for x in p.get('worst', [])] != seq[:3]: sys.exit(f"the post's worst three {[x['name'] for x in p.get('worst', [])]}, the page's first three {seq[:3]}")
# each of the worst three counts its own rows on the page (review-28 rows S4: never a silent skip)
for x in p.get('worst', []):
    mine = [r for r in C2['open'] if r['instance'] == x['name']]
    if (x['critical'], x['warnings']) != (sum(r['severity'] == 'critical' for r in mine), sum(r['severity'] != 'critical' for r in mine)):
        sys.exit(f"{x['name']} in the worst three {x}, its page rows {len(mine)}")
print(', '.join(f"{x['name']}{' (SQL Server)' if x['name'] in {NAME[i] for i in MS} else ''}" for x in p.get('worst', [])))
PY
) || kfail "K25: $why"
kok "K25: the scheduled mail's checks grid carries demo-onprem-sql01's cell rows as the page draws them, and the turn's post ranks by the same rows (its worst three the page's first three, each one's counts its rows': $why)"

# ---- K26: a failed read of the cells is said, never silent ------------------------------------------------------------------
KROW=$KBAD
q "alter function pgvigil.mssql_pool_storage_status(int, timestamptz) rename to mssql_pool_storage_status_k26" >/dev/null || kfail "K26: the cells' read could not be broken"
ksql checks > "$WORK/kchk4.json" || kfail "K26: the page with the cells' read failing: $(head -c 300 "$WORK/kchk4.json")"
q "alter function pgvigil.mssql_pool_storage_status_k26(int, timestamptz) rename to mssql_pool_storage_status" >/dev/null || kfail "K26: the function could not be put back"
why=$(kgrade 2>&1 <<'PY'
C4 = need(ld('kchk4.json'), 'open', 'the page read with the cells failing')
one = [r for r in C4['open'] if r['severity'] == 'critical' and r['instance'] == '' and r['check'] == 'check could not run' and 'SQL Server status cells' in r['object']]
if len(one) != 1: sys.exit(f"{len(one)} check-could-not-run row(s) for the SQL Server status cells; rows naming no instance: {[(r['check'], r['object']) for r in C4['open'] if not r['instance']][:3]}")
if rows_of(C4['open']): sys.exit('SQL Server cell rows drawn from a failed read')
PY
) || kfail "K26: $why"
kok "K26: with GET /api/mssql/summary failing, the Daily checks page draws one critical 'check could not run' row for the SQL Server status cells and no cell row"
# ---- K27: the recovered collection is a row on both engines (the lead 11-16 20:01; review-28 code S6) ----------------------
KROW=$KBAD
# one instance of each engine with no collection failing and no error in the last 24 hours, so the seed alone turns its cell
pick() { q "select i.instance_id from pgvigil.instances i where i.is_active and i.engine = '$1'
  and not exists (select 1 from pgvigil.collection_dates c where c.instance_id = i.instance_id and c.status = 'error')
  and not exists (select 1 from pgvigil.collection_log l where l.instance_id = i.instance_id and l.status = 'error' and l.snapshot_at > now() - interval '24 hours')
  order by i.name limit 1"; }
KEM=$(pick sqlserver); KEP=$(pick postgres); export KEM KEP
[[ -n $KEM && -n $KEP ]] || kfail "K27: no SQL Server ('$KEM') or PostgreSQL ('$KEP') instance without a collection error to seed"
for i in $KEM $KEP; do   # the collector's own function: a run that failed an hour ago, the same collection run well now
  out=$(as "$COL" -c "select pgvigil.log_collection($i, 'k27_once', now() - interval '1 hour', 1, 'error', 'seeded by the proof (K27)'); select pgvigil.log_collection($i, 'k27_once', now(), 1, 'ok', NULL)")
  [[ $out != *ERROR* ]] || kfail "K27: the seed on instance $i: $out"
done
ksread K27
k27() { kgrade 2>&1 <<'PY'
KEM, KEP = int(os.environ['KEM']), int(os.environ['KEP'])
cell = {c['inst']: c for c in S['cells'] if c['group'] == 'errors'}
for i in (KEM, KEP):
    if i not in cell or lvl(cell[i]['cls']) != 'warning': sys.exit(f"the seed did not turn {NAME.get(i, i)}'s Collection Errors cell warning: {cell.get(i)}")
failing = {r['instance'] for r in C['open'] if r.get('check') == 'collection failing'}
got = {}
for r in C['open']:
    if r.get('group') == 'errors': got.setdefault(r['inst'], []).append(r)
want = {i: c for i, c in cell.items() if lvl(c['cls']) == 'warning' and NAME.get(i) not in failing}
strip = {(x['inst'], x['group']): x['href'] for x in S['strip']}
bad = [f"{NAME.get(i, i)}: {len(got.get(i, []))} row(s)" for i in want if len(got.get(i, [])) != 1]
bad += [f"{NAME.get(i, i)}: a row beside a critical cell or a collection failing now" for i in got if i not in want]
if bad: sys.exit(f"Collection Errors rows against the cells at warning: {bad[:6]}")
for i, c in want.items():
    r = got[i][0]
    if (r['severity'], r['object'], r['check']) != ('warning', c['text'], c['head']): sys.exit(f"{NAME[i]}: row {r['severity']} / {r['check']} / {r['object']!r}, cell {c['text']!r} / {c['head']!r}")
    if not r['href'] or r['href'] != strip.get((i, 'errors')) or (c['href'] and c['href'] != r['href']): sys.exit(f"{NAME[i]}: the row's link {r['href']}, the strip's {strip.get((i, 'errors'))}, the cell's {c['href']}")
print(f"{len(want)} instance(s) - {sorted(NAME.get(i, str(i)) for i in want)[:6]}")
PY
}
n27=$(k27) || { ksread K27; n27=$(k27) && echo "K27: equal on the second read (the first differed)"; } || kfail "K27: $n27"
# acknowledged on its cell (the Summary's own write: POST /api/ack, check_key errors, for 2 hours): out of the counts
c=$(postj ack "{\"kind\":\"ack\",\"instance_id\":$KEP,\"check_key\":\"errors\",\"until\":\"$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)\",\"note\":\"K27\"}") || true
[[ $c == 200 ]] || kfail "K27: the acknowledgement of instance $KEP's Collection Errors: $c $(cat "$WORK/body")"
ksql checks > "$WORK/kchk5.json" || kfail "K27: the page after the acknowledgement: $(head -c 300 "$WORK/kchk5.json")"
why=$(kgrade 2>&1 <<'PY'
C5 = need(ld('kchk5.json'), 'open', 'the page read after the acknowledgement')
KEP = int(os.environ['KEP'])
if any(r.get('group') == 'errors' and r.get('inst') == KEP for r in C5['open']): sys.exit(f"{NAME.get(KEP)}'s Collection Errors row still open")
ak = [r for r in (C5['acked'] or []) if r.get('group') == 'errors' and r.get('inst') == KEP]
if len(ak) != 1 or 'acknowledged by' not in ak[0].get('acknowledged', ''): sys.exit(f"{NAME.get(KEP)}'s Collection Errors row in the acknowledged grid: {ak[:2]}")
crit = sum(1 for r in C5['open'] if r['severity'] == 'critical'); p = json.loads(C5['post'] or '{}')
if (int(C5['tiles']['Critical']), int(C5['tiles']['Warnings'])) != (crit, len(C5['open']) - crit) or (p.get('critical'), p.get('warnings')) != (crit, len(C5['open']) - crit):
    sys.exit(f"tiles {C5['tiles']}, post {p.get('critical')}/{p.get('warnings')}, open rows {crit}/{len(C5['open']) - crit}")
if p.get('acknowledged') != len(C5['acked']): sys.exit(f"the post says {p.get('acknowledged')} acknowledged, the grid {len(C5['acked'])}")
PY
) || kfail "K27: acknowledged: $why"
for a in $(q "select ack_id from pgvigil.acks where kind = 'ack' and instance_id = $KEP and check_key = 'errors' and ended_at is null"); do
  c=$(postj ack/end "{\"ack_id\":$a}") || true; [[ $c == 200 ]] || kfail "K27: ending ack $a: $c $(cat "$WORK/body")"
done
kok "K27: a collection that failed an hour ago and runs well now turns the Collection Errors (24hrs) cell warning on $n27, the seeded SQL Server and PostgreSQL ones among them: each is one warning row of the Daily checks page with the cell's words, column label and link, none beside a critical cell or a collection failing now; acknowledged on its cell, the PostgreSQL one's row moved to the acknowledged grid, out of the tiles and the post's counts, the post's acknowledged counting it"
(( KBAD == 0 )) || fail "K15-K27: $KBAD row check(s) failed (PGVIGIL_KROWS_GO=1)"

# ---- G: the green day, on a repository migrated and never seeded ------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO2" >/dev/null
export PGVIGIL_REPO2_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO2"
export PGV_ALERTS2_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO2 user=$ALR password=$PW"
q2() { psql "$PGVIGIL_REPO2_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$WORK/cfg-g.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO2_DSN
alerts_dsn: env:PGV_ALERTS2_DSN
alerts:
  - {name: mail, kind: smtp, min_severity: critical, instances: [proof-none], smtp: {host: 127.0.0.1, port: $SINKP, tls: none, from: "pgvigil <alerts@pgvigil.test>", to: [admin@pgvigil.test]}}
instances: []
EOF
"$BIN" migrate -config "$WORK/cfg-g.yaml" > "$WORK/migrate-g.log" 2>&1 || fail "G: migrate: $(tail -3 "$WORK/migrate-g.log")"
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$WORK/cfg-g.yaml" $UIUSER >/dev/null 2>&1 || fail "G: user add"
{ cat "$WORK/cfg-g.yaml"; printf 'reports:\n  daily_checks:\n    enabled: true\n    at: "07:00"\n    tz: UTC\n    to: [green@pgvigil.test]\n    as: %s\n    channel: mail\n' "$UIUSER"; } > "$WORK/cfg-gon.yaml"
PG=$(freeport); UG="http://127.0.0.1:$PG"
glogin() { curl -s -c "$WORK/jarg" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$UG/api/login" >/dev/null; }
kserve "$WORK/cfg-g.yaml" "$PG" serveg0.log; SG=$KPID; glogin
[[ $(kget "$UG" "$WORK/jarg") == 200 && $(jget "d['daily']['owner']") == page && $(jget "d['daily']['writable']") == False && $(jget "d['daily']['reason']") == *"needs an smtp channel"* ]] || fail "G1: no smtp channel recorded: $(cat "$WORK/body")"
ok "G1: a repository whose sender has recorded no smtp channel: the page's control is off with 'needs an smtp channel'"
kstop "$SG"; kserve "$WORK/cfg-gon.yaml" "$PG" serveg.log; SG=$KPID; glogin
sleep 130
[[ $(q2 "select count(*) from pgvigil.report_mail_log") == 0 && $(q2 "select count(*) from pgvigil.report_mail_schedules") == 0 && $(grep -c 'the setting is not applied' "$WORK/serveg.log") == 1 ]] \
  || fail "G2: 130 s of a setting that cannot be kept yet: log rows $(q2 "select count(*) from pgvigil.report_mail_log"), schedules $(q2 "select count(*) from pgvigil.report_mail_schedules"), the reason logged $(grep -c 'the setting is not applied' "$WORK/serveg.log") time(s)"
[[ $(kget "$UG" "$WORK/jarg") == 200 && $(jget "d['daily']['reason']") == *"not an smtp channel the sender has recorded"* ]] || fail "G2: the page's reason: $(cat "$WORK/body")"
ok "G2: the block on before the sender ever ran: after 130 s nothing kept, nothing written to the log, the reason logged once, the page says the channel is not recorded"
sender2() { "$BIN" alerts -config "$WORK/cfg-gon.yaml" >> "$WORK/sender2.log" 2>&1 || true; }
sender2
gkept() { [[ $(q2 "select count(*) from pgvigil.report_mail_schedules where kept_as = 'daily_checks' and kept_by = 'file' and ended_at is null") == 1 ]] && echo y || echo n; }
kwait 76 gkept || fail "G3: not kept within 75 s of the sender's first pass: $(q2 "select count(*) from pgvigil.alert_channels where kind = 'smtp'") smtp channel(s) recorded; $(grep -i 'daily checks' "$WORK/serveg.log" | tail -2)"
[[ $(q2 "select count(*) from pgvigil.report_mail_log") == 1 ]] || fail "G3: $(q2 "select count(*) from pgvigil.report_mail_log") log rows"
ok "G3: the sender's first pass recorded the channel; the serve kept the schedule within its next try, one log row"
GID=$(q2 "select schedule_id from pgvigil.report_mail_schedules where kept_as = 'daily_checks' and ended_at is null")
SEND=$(kturn "$GID" q2) || fail "G4: the serve did not queue the green day's turn in 3 minutes: $(q2 "select send_id, coalesce(outcome, 'queued'), coalesce(error, render_error) from pgvigil.report_mail_sends")"
for _ in $(seq 1 36); do sender2; [[ $(q2 "select count(*) from pgvigil.report_mail_sends where send_id = $SEND and done_at is not null") == 1 ]] && break; sleep 5; done
[[ $(q2 "select outcome || ' ' || rows from pgvigil.report_mail_sends where send_id = $SEND") == "sent 0" ]] || fail "G4: the green day's turn: $(q2 "select coalesce(outcome, 'queued'), rows, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND")"
got=$(kmail green@pgvigil.test 0 'All checks pass') || fail "G4: the green day's mail: $got"
ok "G4: THE GREEN DAY: no check fails; the turn was SENT (mail $SEND) and its body holds the checks grid's header row, no data row and 'All checks pass' in place of 'No rows.'"
kstop "$SG"
ok "K: the Daily checks mail (K1-K27, G1-G4)"
