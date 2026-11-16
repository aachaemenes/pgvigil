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
#   K15 THE ORDER: two proof instances of known bands, k15-aaa (1 critical, 3 warnings) and k15-zzz (2 critical), named
#       so the reader's order (critical rows first, by name) puts k15-aaa first: the Daily checks page draws the rows
#       naming no instance first, then each instance's rows together, the instances by critical count, warning count,
#       name - k15-zzz before k15-aaa - judged on the screen's own rows (their counts, their order); the section carries
#       the post's numbers (data-daily-post) equal to its tiles.
#   K16 a failed mail posts nothing: the kept row with post [hook] through the door (post_channels {hook}) and the
#       channel badmail; its turn is answered failed; no post reaches the sink, the send's post_taken_at and posted_at
#       stay NULL.
#   K17 THE POST: the channel mail again (the same schedule): its turn is answered sent; the mail's checks grid is worst
#       first by its own rows; ONE post reaches the sink, its body (format json) kind 'daily checks' with the counts of
#       that same mail (critical = its critical rows, warnings = the rest), instances = the page's Instances tile, the
#       worst three = the first three instances of the mail's grid in order, the link http://pgvigil.test/#/checks?w=24h;
#       the send's posted_at set, post_error NULL; GET part=daily lists post_choices [deadhook, hook] (the repository's
#       configured webhook channels) and post [hook].
#   K18 a second turn the same day is mailed (sent) and posts nothing: the sink unchanged, its post_taken_at NULL.
#   K19 a failed post is alerted: the row dropped and kept anew (a new schedule) with post [deadhook]; its turn is sent,
#       the post fails - post_error names 127.0.0.1, posted_at NULL - and a 'daily checks post failed' notice naming the
#       mail reaches the file drop.
#   K20 the block's post: list: a serve whose block says post: [hook] keeps post_channels {hook} (kept_by file); a block
#       with post: [mail] (an smtp channel) stops serve at start with 'reports.daily_checks: post: mail is not a webhook
#       channel of alerts:'.
#   K21 THE ROLE (the lead 11-15 12:0x, DAILYMAIL's line): a viewer's GET part=daily answers writable false with the
#       role's words ('changing the Daily checks mail needs the admin role: proofview is a viewer'); its daily_keep 403
#       with the role's words; nothing kept.
#   G1  a repository migrated and never seeded, the sender never run: the page-owner serve says the mail needs an smtp
#       channel (writable false).
#   G2  the block on there: for 130 s (three tries) nothing is kept, NOTHING is written to report_mail_log, the serve's
#       log holds the reason once, the page says the channel is not recorded.
#   G3  the sender's first pass records the channel: the row is kept within 75 s, one log row.
#   G4  THE GREEN DAY: no check fails there. The turn brought due is SENT (before the fix: failed, 'the page drew no
#       grid') and its body holds the checks grid's header row, no data row and the sentence 'All checks pass'.
#   NOT PROVEN here (B20-4): Slack, Teams, Discord and Google Chat bodies against a real workspace (their shapes are
#       internal/alerts post_test.go's rows); the Mail daily... dialog's post field by a click (K17 reads the part's
#       choices); two senders racing one post for real (the unique index on the schedule and the day stands for it).
#   NOT PROVEN here: a send at the real hour (next_at is brought due by hand); two serves racing a keep for real (K3's
#       two sessions stand for it); the note on a server without a browser.

echo "== K: the Daily checks mail"
KPIDS=""; KPID=""; REPO2="${REPO}_g"
kcleanup() {
  for p in $KPIDS; do kill "$p" 2>/dev/null || true; done
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO2 with (force)" >/dev/null 2>&1 || true
}
trap 'kcleanup; cleanup' EXIT
# kserve <cfg> <port> <log>: a serve with the login on that port; its pid in KPID
kserve() {
  TZ=UTC "$BIN" serve -config "$1" -listen "127.0.0.1:$2" >> "$WORK/$3" 2>&1 &
  KPID=$!; KPIDS="$KPIDS $KPID"
  for _ in $(seq 1 120); do
    curl -sf -o /dev/null "http://127.0.0.1:$2/" && return 0
    kill -0 "$KPID" 2>/dev/null || fail "K: serve died: $(tail -3 "$WORK/$3")"
    sleep 0.5
  done
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
if (mode === 'off' || mode === 'keep') {
  const label = mode === 'off' ? 'Turn off' : 'Mail daily...';
  const hit = await ev(`(() => { const b = [...document.querySelectorAll('main p.daily-mail button')].find(x => x.textContent === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  if (!hit) { console.log(JSON.stringify({ ...res, error: 'no button ' + label })); process.exit(1); }
  for (let n = 0; n < 50 && !await ev(`!!document.querySelector('dialog[open] form')`); n++) await sleep(100);
  res.title = await ev(`document.querySelector('dialog[open] h3')?.textContent ?? ''`);
  if (mode === 'keep') {
    res.unlabelled = await ev(`[...document.querySelectorAll('dialog[open] input, dialog[open] select, dialog[open] textarea')].filter(x => !x.closest('label')).length`);
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
# kturn <schedule> <query function> <sender function>: the schedule brought due; its one scheduled mail's id once a serve queued it
kturn() {
  local sid=$1 qf=$2 n before
  before=$($qf "select coalesce(max(send_id), 0) from pgvigil.report_mail_sends")   # an earlier turn's mail is not this one
  $qf "update pgvigil.report_mail_schedules set next_at = now() - interval '1 second' where schedule_id = $sid" >/dev/null
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
kwaitsent() {   # kwaitsent <id>: this part's sender until the mail is answered (3 minutes)
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
[[ $(q "select count(*) from pgvigil.alert_channels where is_configured and kind = 'webhook' and name in ('hook', 'deadhook')") == 2 ]] || fail "K15: the sender did not record the webhook channels: $(tail -3 "$WORK/ksender.log")"

# ---- K15: the order on the screen ----------------------------------------------------------------------------------------
KA=$(as "$COL" -c "select pgvigil.ensure_instance('k15-aaa', 'onprem', '16.0', 160000, false, '{}'::text[])")
KZ=$(as "$COL" -c "select pgvigil.ensure_instance('k15-zzz', 'onprem', '16.0', 160000, false, '{}'::text[])")
[[ $KA =~ ^[0-9]+$ && $KZ =~ ^[0-9]+$ ]] || fail "K15: the two proof instances: $KA / $KZ"
for x in "$KA k15_fail1 error 0" "$KZ k15_fail1 error 0" "$KZ k15_fail2 error 0" "$KA k15_old1 ok 3" "$KA k15_old2 ok 3" "$KA k15_old3 ok 3"; do
  read -r i c st d <<<"$x"
  out=$(as "$COL" -c "select pgvigil.log_collection($i, '$c', now() - interval '$d days', 1, '$st', 'seeded by the proof (K15)')")
  [[ $out != *ERROR* ]] || fail "K15: the seed $x: $out"
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
const res = await ev(`(() => {
  const tiles = {}; for (const t of document.querySelectorAll('main .tiles .tile')) tiles[t.querySelector('.tile-l')?.textContent ?? ''] = t.querySelector('.tile-v')?.textContent ?? '';
  const g = [...document.querySelectorAll('main table')].find(t => [...t.querySelectorAll('thead th')].map(h => h.textContent.trim().toLowerCase()).slice(0, 3).join(',') === 'severity,instance,check');
  const rows = g ? [...g.querySelectorAll('tbody tr')].map(tr => [...tr.querySelectorAll('td')].slice(0, 2).map(td => td.textContent.replace(/\\s+/g, ' ').trim())) : null;
  const sec = document.querySelector('main [data-daily-post]');
  return { tiles, rows, post: sec ? sec.getAttribute('data-daily-post') : null };
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
node "$WORK/kord.mjs" "$CDP" "$U" "$TOKEN" '#/checks?w=24h' > "$WORK/kord.json" || fail "K15: the driver: $(cat "$WORK/kord.json")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump(d["rows"], open(sys.argv[2], "w"))' "$WORK/kord.json" "$WORK/kord-rows.json" || fail "K15: no checks grid on the page: $(head -c 400 "$WORK/kord.json")"
KSEEN=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(" ".join(sorted({i for _, i in r if i.startswith("k15-")})))' "$WORK/kord-rows.json")
[[ $KSEEN == "k15-aaa k15-zzz" ]] || fail "K15: the seeded instances on the page: '$KSEEN' (the seed did not reach the page: the row would test nothing)"
why=$(kwf "$WORK/kord-rows.json" 2>&1) || fail "K15: the Daily checks page is not worst first: $why"
python3 - "$WORK/kord.json" <<'PY' || fail "K15: the section's post numbers: $(head -c 600 "$WORK/kord.json")"
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
ok "K15: the Daily checks page draws worst first (k15-zzz's two critical before k15-aaa's one, each instance's rows together, by the screen's own rows); its section carries the post's numbers equal to its tiles"

# ---- K16: a failed mail posts nothing -----------------------------------------------------------------------------------
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"badmail","post":["hook"]}')
[[ $c == 200 && $(jget "d['outcome']") == done && $(klive "post_channels") == "{hook}" && $(klive channel) == badmail ]] || fail "K16: the keep with post [hook]: $c $(cat "$WORK/body"); post_channels $(klive "post_channels")"
KID=$(klive schedule_id); P0=$(nposts)
SEND=$(kturn "$KID" q) || fail "K16: no serve queued the turn in 3 minutes"
kwaitsent "$SEND" || fail "K16: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND") == failed && $(nposts) == "$P0" \
   && $(q "select (post_taken_at is null and posted_at is null)::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] \
  || fail "K16: the failed mail $SEND: $(q "select outcome, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND"); posts $(nposts) (before $P0)"
ok "K16: the kept row with post [hook] and the channel badmail: its turn (mail $SEND) failed and posted nothing"

# ---- K17: the post --------------------------------------------------------------------------------------------------------
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"mail","post":["hook"]}')
[[ $c == 200 && $(klive schedule_id) == "$KID" && $(klive channel) == mail && $(klive "post_channels") == "{hook}" ]] || fail "K17: the keep with the channel mail: $c $(cat "$WORK/body")"
[[ $(kget "$U") == 200 && $(jget "sorted(d['daily']['post_choices'])") == "['deadhook', 'hook']" && $(jget "d['daily']['post']") == "['hook']" ]] || fail "K17: the page's state: $(cat "$WORK/body")"
P0=$(nposts)
SEND=$(kturn "$KID" q) || fail "K17: no serve queued the turn in 3 minutes"
kwaitsent "$SEND" || fail "K17: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND") == sent ]] || fail "K17: mail $SEND: $(q "select outcome, coalesce(error, render_error) from pgvigil.report_mail_sends where send_id = $SEND")"
python3 - "$WORK/sink" post@pgvigil.test "$WORK/kmail-rows.json" <<'PY' || fail "K17: the mail's checks grid: $(cat "$WORK/kmail-rows.json" 2>/dev/null | head -c 300)"
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
why=$(kwf "$WORK/kmail-rows.json" 2>&1) || fail "K17: the mail's checks grid is not worst first: $why"
[[ $(nposts) == $((P0 + 1)) ]] || fail "K17: the sink holds $(($(nposts) - P0)) post(s) of this turn, want 1: $(tail -3 "$WORK/ksender.log")"
python3 - "$WORK/hook" "$WORK/kmail-rows.json" "$WORK/kord.json" <<'PY' || fail "K17: the post's body"
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
[[ $(q "select (posted_at is not null and post_error is null)::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] || fail "K17: the send's post state: $(q "select post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND")"
ok "K17: the turn (mail $SEND, sent): the mail's checks grid worst first; one post to hook with that mail's counts, the page's instance count, the worst three in order and the link; posted_at set"

# ---- K18: a second turn the same day posts nothing ------------------------------------------------------------------------
P0=$(nposts)
SEND2=$(kturn "$KID" q) || fail "K18: no serve queued the second turn in 3 minutes"
kwaitsent "$SEND2" || fail "K18: mail $SEND2 not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND2") == sent && $(nposts) == "$P0" \
   && $(q "select (post_taken_at is null and posted_at is null)::text from pgvigil.report_mail_sends where send_id = $SEND2") == true ]] \
  || fail "K18: the second turn $SEND2: $(q "select outcome, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND2"); posts $(nposts) (before $P0)"
ok "K18: a second turn the same day (mail $SEND2) was mailed and posted nothing"

# ---- K19: a failed post is alerted ------------------------------------------------------------------------------------------
c=$(postj reportmail '{"op":"daily_drop"}'); [[ $c == 200 && $(nlive) == 0 ]] || fail "K19: the drop: $c $(cat "$WORK/body")"
c=$(postj reportmail '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["post@pgvigil.test"],"channel":"mail","post":["deadhook"]}')
[[ $c == 200 && $(klive "post_channels") == "{deadhook}" && $(klive schedule_id) != "$KID" ]] || fail "K19: the keep with post [deadhook]: $c $(cat "$WORK/body")"
KID=$(klive schedule_id); D0=$(grep -rl 'daily checks post failed' "$WORK/drop" 2>/dev/null | wc -l)
SEND=$(kturn "$KID" q) || fail "K19: no serve queued the turn in 3 minutes"
kwaitsent "$SEND" || fail "K19: mail $SEND not answered in 3 minutes"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $SEND") == sent \
   && $(q "select (posted_at is null and post_error like '%127.0.0.1%')::text from pgvigil.report_mail_sends where send_id = $SEND") == true ]] \
  || fail "K19: mail $SEND's post: $(q "select outcome, post_taken_at, posted_at, post_error from pgvigil.report_mail_sends where send_id = $SEND")"
[[ $(grep -rl 'daily checks post failed' "$WORK/drop" 2>/dev/null | wc -l) -gt $D0 && $(grep -rh 'daily checks post failed' "$WORK/drop" | tail -1) == *"$SEND"* ]] || fail "K19: no 'daily checks post failed' notice naming mail $SEND in the file drop"
ok "K19: a post to deadhook failed (mail $SEND sent; post_error names 127.0.0.1) and a 'daily checks post failed' notice reached the file drop"

# ---- K20: the block's post: list ----------------------------------------------------------------------------------------------
kpcfg() { { cat "$WORK/cfg-kpost.yaml"; printf 'reports:\n  daily_checks:\n%b' "$2"; } > "$1"; }
kpcfg "$WORK/cfg-kpon.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [post@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n    post: [hook]\n"
kpcfg "$WORK/cfg-kpbad.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [post@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n    post: [mail]\n"
PK=$(freeport); UK="http://127.0.0.1:$PK"
kserve "$WORK/cfg-kpon.yaml" "$PK" servekpost.log; SK=$KPID
kwait 30 filekept || fail "K20: the serve did not keep the row in 30 s: $(klive "kept_by || ' ' || coalesce(post_channels::text, '-')"); $(grep -i 'daily checks' "$WORK/servekpost.log" | tail -2)"
[[ $(klive "post_channels") == "{hook}" ]] || fail "K20: the block's post: $(klive "post_channels")"
kstop "$SK"
rc=0; out=$(timeout 20 "$BIN" serve -config "$WORK/cfg-kpbad.yaml" -listen "127.0.0.1:$(freeport)" 2>&1) || rc=$?
[[ $rc != 0 && $rc != 124 && $out == *"reports.daily_checks: post: mail is not a webhook channel of alerts:"* ]] || fail "K20: post: [mail] (exit $rc): $(tail -2 <<<"$out")"
ok "K20: the block's post: [hook] kept post_channels {hook} (kept_by file); post: [mail] stopped serve at start in words"

# ---- K21: the role ------------------------------------------------------------------------------------------------------------
KVUSER=proofview; KVPW=$(openssl rand -hex 12)
PGVIGIL_PASSWORD=$KVPW "$BIN" user add -config "$CFG" -role viewer $KVUSER >/dev/null 2>&1 || fail "K21: user add -role viewer"
login "$WORK/jarv" "$KVUSER" "$KVPW"
L4=$(nlog); N4=$(nlive)
[[ $(kget "$U" "$WORK/jarv") == 200 && $(jget "d['daily']['writable']") == False && $(jget "d['daily']['reason']") == *"changing the Daily checks mail needs the admin role: $KVUSER is a viewer"* ]] || fail "K21: a viewer's part=daily: $(cat "$WORK/body")"
c=$(code -b "$WORK/jarv" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary '{"op":"daily_keep","at":"07:00","timezone":"UTC","recipients":["v@pgvigil.test"],"channel":"mail"}' "$U/api/reportmail")
[[ $c == 403 && $(jget "d['error']") == *"needs the admin role: $KVUSER is a viewer"* && $(nlog) == "$L4" && $(nlive) == "$N4" ]] || fail "K21: a viewer's daily_keep: $c $(cat "$WORK/body")"
ok "K21: a viewer's Daily checks mail is read only with the role's words (part=daily writable false; daily_keep 403); nothing kept"

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
ok "K: the Daily checks mail (K1-K14, G1-G4)"
