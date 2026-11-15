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
#   K3  two sessions: the first holds its keep (another hour) open for 4 s, the second asks the same keep 1 s later: it
#       WAITS (2 s or more), answers 'unchanged', one live row, one log row more (the first's).
#   K4  the ordinary door on the kept row: import_report_mail end / disable / enable refused with 'kept by the Daily
#       checks mail setting'; the page's keep and drop on the file-kept row refused ('kept by pgvigil.yaml'); a second
#       live kept row inserted by hand is refused by the unique index; drop ends it, again is 'unchanged'.
#   K5  the page's state (GET /api/reportmail?part=daily): on the signed-in serve owner page, off, writable; on the
#       -no-login serve writable false with the reason naming -no-login, and its POST 403.
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
#   K10 the same block again (the serve restarted): nothing written (the log's count and changed_at unmoved).
#   K11 enabled: false: the serve ends the row (ended_by pgvigil.yaml); its page says 'turned off in pgvigil.yaml'; a
#       page-made row is ended by it too.
#   K12 the block removed: a row the file made is ended at the start of a serve whose file has no block.
#   K13 an `as` user who cannot sign in: nothing kept, nothing written, the page's reason says so.
#   K14 a block that is not whole stops serve at start by the key's name: 'enable:' (a typo), no channel.
#   G1  a repository migrated and never seeded, the sender never run: the page-owner serve says the mail needs an smtp
#       channel (writable false).
#   G2  the block on there: for 130 s (three tries) nothing is kept, NOTHING is written to report_mail_log, the serve's
#       log holds the reason once, the page says the channel is not recorded.
#   G3  the sender's first pass records the channel: the row is kept within 75 s, one log row.
#   G4  THE GREEN DAY: no check fails there. The turn brought due is SENT (before the fix: failed, 'the page drew no
#       grid') and its body holds the checks grid's header row, no data row and the sentence 'All checks pass'.
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

# ---- K3: two sessions ------------------------------------------------------------------------------------------------
B8=$(kbody keep file pgvigil.yaml "$UIUSER" '0 8 * * *' '["daily@pgvigil.test"]')
psql "$(dsn "$COL")" -XAtq -c "begin" -c "select pgvigil.import_report_mail_kept(clock_timestamp(), '$B8'::jsonb)" -c "select pg_sleep(4)" -c "commit" > "$WORK/k3a.out" 2>&1 &
K3A=$!
sleep 1
T0=$(date +%s); r=$(kept "$B8"); T1=$(date +%s)
wait "$K3A" || fail "K3: the first session: $(cat "$WORK/k3a.out")"
[[ $(kj "$r" outcome) == unchanged && $((T1 - T0)) -ge 2 && $(nlive) == 1 && $(klive cron) == "0 8 * * *" && $(klive schedule_id) == "$KID" && $(nlog) == 2 ]] \
  || fail "K3: the second session: $r after $((T1 - T0)) s; live $(nlive), cron $(klive cron), log $(nlog); the first: $(cat "$WORK/k3a.out")"
ok "K3: two sessions keeping at once: the second waited $((T1 - T0)) s for the first and answered 'unchanged'; one live row, the same schedule, one log row more"

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
kstop "$SK"; kserve "$WORK/cfg-kon.yaml" "$PK" servek.log; SK=$KPID
sleep 8
[[ $(nlog) == "$L1" && $(klive changed_at) == "$C1" && $(klive next_at) == "$N1" && $(nlive) == 1 ]] || fail "K10: the same block again wrote: log $(nlog) (was $L1), changed_at $(klive changed_at) (was $C1)"
ok "K10: the serve restarted with the same block: nothing written (the log, changed_at and the next send unmoved)"

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
kstop "$SK"
ok "K13: as: $U2USER (disabled): nothing kept, nothing written, the page says the user cannot sign in"
kcfg "$WORK/cfg-kbad1.yaml" "    enable: true\n    at: 06:30\n    tz: UTC\n    to: [a@pgvigil.test]\n    as: $UIUSER\n    channel: mail\n"
kcfg "$WORK/cfg-kbad2.yaml" "    enabled: true\n    at: 06:30\n    tz: UTC\n    to: [a@pgvigil.test]\n    as: $UIUSER\n"
for pair in "cfg-kbad1.yaml|enable" "cfg-kbad2.yaml|channel is required"; do
  out=$(timeout 20 "$BIN" serve -config "$WORK/${pair%%|*}" -listen "127.0.0.1:$(freeport)" 2>&1) && fail "K14: serve started with ${pair%%|*}"
  [[ $out == *"${pair##*|}"* ]] || fail "K14: ${pair%%|*}: serve's words do not name '${pair##*|}': $(tail -2 <<<"$out")"
done
ok "K14: a block with 'enable:' for enabled, and one without its channel, each stop serve at start by the key's name"

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
