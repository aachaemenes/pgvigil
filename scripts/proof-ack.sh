#!/usr/bin/env bash
# Proof of acknowledge, mute and notes (migration 0073, internal/web/q_ack.go, web/src/ack.ts, the Summary in pages.ts
# and the Alerts page in alerts.ts; task 118) on the sandbox. A demo fleet is seeded into a throwaway database, served
# on loopback with the UI login on, a headless Chromium reads the Summary, and `pgvigil alerts` sends to file drops in
# the proof's own folder. Nothing leaves the machine.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a superuser (the proof makes its database and logins with
#                      a random suffix and drops them at the end)
#   PGVIGIL_BIN        a build with the routes GET /api/ack, POST /api/ack, POST /api/ack/end (the lead's wiring in
#                      web.go) and the bundle rebuilt; default bin/pgvigil
#   chromium, node     the Summary read (Chrome DevTools Protocol over node's WebSocket)
#
# Expected (written before the first run):
#  R. the role contract: a collector login (IN ROLE pgvigil_collector, the actions door's audit login) may EXECUTE
#     import_ack and may not INSERT into acks nor UPDATE ack_log (permission denied); an alerter login (IN ROLE
#     pgvigil_alerter) may INSERT into ack_suppressed and may not INSERT into acks.
#  B. the write door: POST /api/ack without a session 401, with a session but without the X-Pgvigil header 403, an
#     unknown kind 400; none of the three leaves an ack_log row. [First run: the header check was sent without a
#     session and got 401: the login gate wraps every /api route and answers before the handler; the 403 is graded
#     with a session.] Logged in: GET /api/ack says writable true and the user.
#  C. an ack hides a cell's colour and counts it: instance P (the demo instance with the most warning / critical cells
#     on the Summary) acknowledged for every check (until +2 h): its row then holds no td.status.warn / crit, as many
#     td.status.ack cells as it had warning and critical cells before, the test grid's 'acknowledged' column
#     sums to that count, the header line says '<that count> check(s) acknowledged', and P is not in Needs attention.
#  U. until the check changes: instance U acknowledged for every check with until_change and a seen_state no cell
#     reads: U's row keeps every warning / critical cell coloured, no td.status.ack.
#  X. expiry: instance Q acknowledged for every check until +25 s: at once Q's row holds td.status.ack cells; after
#     the expiry the API row is live false and the reloaded Summary colours Q's cells again (no td.status.ack in Q).
#  S. a restart: serve stopped and started (a new login: sessions live in serve's memory); P's row still holds the same
#     count of td.status.ack cells.
#  M. a mute suppresses a send and logs it: M's autovacuum (critical, set by the proof as proof-alerts does) muted by a
#     rule (instance M, text 'autovacuum'); a pass to the channel drop (file, critical): no file of M's autovacuum,
#     ack_suppressed holds the rule's row for drop with passes 1; a second pass: passes 2, still no file. The rule ended
#     (POST /api/ack/end 200): a pass writes a firing file of M's autovacuum.
#  L. a silence covers one server: L (the demo instance with the most critical findings, not M) silenced; a pass to a
#     fresh channel drop2: no file of L, at least one file of another instance; every ack_suppressed row of the
#     silence is L's and there is at least one; a second silence of L refused 409 ('already silenced').
#  [Added at the review fold, before their first run:]
#  H. holds and acknowledgements on OPEN alerts: a channel rep (file, critical, repeat 5m) opens its alerts in a pass;
#     A1 muted by 'Mute this alert' (its finding key), A2 acknowledged, A3's setting labelled by a known pattern, K
#     (an instance with open rep alerts) in a blackout from a minute ago to an hour on, K2 in a blackout that starts
#     in an hour. GET /api/ack part alerts: A2 acked (its ack id), A3's known_noise the label and held by nothing, K's
#     rows is_blackout true, K2's false. rep's rows moved 6 minutes back, a pass: no repeat file of A1, A2 or K, a
#     repeat file of A3 and of K2; A1's rep row still open; ack_suppressed holds A1's mute on rep and the blackout's
#     rows, all K's; the future blackout none.
#  O. an acknowledgement is this occurrence's: A2's open rows cleared by hand (the alert gone and back; run 8 cleared
#     only rep's row, and drop's still-open row of the old occurrence kept the grid's acknowledgement: right), a pass: a new
#     firing file of A2; GET: A2 not acknowledged; rep's rows moved back, a pass: a repeat file of A2.
#  Z. close: A4's open rows marked resolved (missing_since), POST close: GET shows A4 closed; missing_since back to
#     NULL (the finding back): GET shows A4 not closed.
#  P. the count click: in the test grid a critical count clicked: the instance grid's column after 'instance' is that
#     test's; clicked again to clear it [run 9: the pick, kept in sessionStorage, filtered D's page].
#  D. until the check changes, through the page: Needs attention's first line V, its Acknowledge dialog saved with its
#     defaults (1 day, or until the check changes): V's row then holds as many td.status.ack cells as it had warning
#     and critical cells, and none coloured.
#  A. the audit: ack_log's rows read add:done=<the rows of acks> add:refused=1 end:done=1, at least as many done adds
#     as the proof made through the API [run 6: 71 against a count of 69: the counter was a variable that
#     MUTE=$(add ...) incremented in a subshell; then a file; at the fold the acks rows, which the page's adds join],
#     every row with ui_user the proof user and client 127.0.0.1; every acks row has created_by the proof user.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
SUF=$RANDOM
DB=pgvigil_ackproof_$SUF; COL=pgvigil_ackproof_col_$SUF; ALR=pgvigil_ackproof_alr_$SUF; PW=p$RANDOM$RANDOM
UIUSER=proofuser; UIPW=ui$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" \
    -c "drop role if exists $COL" -c "drop role if exists $ALR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() {   # free on 127.0.0.1 and [::1] both
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/none.yaml"
"$BIN" migrate -config "$WORK/none.yaml" >/dev/null 2>&1 || fail "migrate"
[[ $(q "select count(*) from pgvigil.schema_version where version = '0073_ack.sql'") == 1 ]] || fail "0073 not applied"
"$BIN" demo -config "$WORK/none.yaml" -days 1 > "$WORK/seed.log" 2>&1 || fail "the demo seed: $(tail -3 "$WORK/seed.log")"
q "delete from pgvigil.alert_state" >/dev/null   # the demo's own spool record: the proof counts its own sends
ok "migrate applied 0073; the demo seeded"

# ---- R: the role contract ------------------------------------------------------------------------------------------
HOST=$(q "select coalesce(host(inet_server_addr()),'localhost')"); DBPORT=$(q "select current_setting('port')")
dsn() { echo "host=$HOST port=$DBPORT user=$1 password=$PW dbname=$DB sslmode=disable"; }
psql "$PGVIGIL_REPO_DSN" -XAtq -c "create role $COL login password '$PW' in role pgvigil_collector" \
  -c "create role $ALR login password '$PW' in role pgvigil_alerter" >/dev/null
[[ $(psql "$(dsn $COL)" -XAt -c "select has_function_privilege('pgvigil.import_ack(timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "R: the collector may not call import_ack"
out=$(psql "$(dsn $COL)" -XAt -c "insert into pgvigil.acks (kind, created_by, created_at, instance_name) values ('silence', 'x', now(), 'x')" 2>&1 || true)
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into acks: $out"
out=$(psql "$(dsn $COL)" -XAt -c "update pgvigil.ack_log set detail = 'x'" 2>&1 || true)
[[ $out == *"permission denied"* ]] || fail "R: the collector updated ack_log: $out"
[[ $(psql "$(dsn $ALR)" -XAt -c "select has_table_privilege('pgvigil.ack_suppressed', 'INSERT'), has_table_privilege('pgvigil.acks', 'INSERT')") == "t|f" ]] || fail "R: the alerter's rights on ack_suppressed / acks"
ok "R: the collector writes only through import_ack; the alerter writes ack_suppressed, not acks"

# ---- serve with the login --------------------------------------------------------------------------------------------
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$WORK/none.yaml" $UIUSER >/dev/null 2>&1 || fail "user add"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
start_serve() {
  "$BIN" serve -config "$WORK/none.yaml" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 &
  SRV=$!
  for _ in $(seq 1 60); do curl -sf -o /dev/null "$U/" && return; kill -0 $SRV 2>/dev/null || fail "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done
  fail "serve did not answer"
}
start_serve
JAR=$WORK/jar
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
# the demo seeds its own acks (SeedAcks, as the UI would): B counts the log rows its refused requests add, not the total
LOG0=$(q "select count(*) from pgvigil.ack_log")
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"kind":"silence","instance_id":1}' "$U/api/ack") == 401 ]] || fail "B: no session: $(cat "$WORK/body")"
login() {
  curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
  COOKIE=$(awk '$6 == "pgvigil_session" {print $6 "=" $7}' "$JAR"); [[ -n $COOKIE ]] || fail "no session cookie in the jar"
}
login
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d '{"kind":"silence","instance_id":1}' "$U/api/ack") == 403 ]] || fail "B: no header: $(cat "$WORK/body")"
[[ $(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"kind":"nonsense"}' "$U/api/ack") == 400 ]] || fail "B: unknown kind: $(cat "$WORK/body")"
[[ $(q "select count(*) from pgvigil.ack_log") == "$LOG0" ]] || fail "B: a refused request left an ack_log row"
[[ $(curl -s -b "$JAR" "$U/api/ack?part=acks" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["writable"], d["user"])') == "True $UIUSER" ]] || fail "B: GET /api/ack does not say writable and the user"
ok "B: 403 without the header, 401 without a session, 400 for an unknown kind, none logged; writable for $UIUSER"

add() {   # add <json>: expects 200 done
  local c; c=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$1" "$U/api/ack")
  [[ $c == 200 ]] || fail "add $1: $c $(cat "$WORK/body")"
  echo >> "$WORK/adds"   # a file, not a variable: MUTE=$(add ...) runs add in a subshell
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ack_id"])' "$WORK/body"
}
KEYS=$(grep -oE "\{ key: '[a-z]+', label:" web/src/fleet.ts | sed -E "s/\{ key: '([a-z]+)'.*/\1/")
[[ $(wc -w <<<"$KEYS") -ge 20 ]] || fail "the group keys of fleet.ts: $KEYS"
ack_all() {   # ack_all <instance id> <extra json fields>
  local k; for k in $KEYS; do add "{\"kind\":\"ack\",\"instance_id\":$1,\"check_key\":\"$k\"$2}" >/dev/null; done
}

# ---- the Summary in a headless Chromium ------------------------------------------------------------------------------
CDP=$(freeport)
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$CDP/json/list" >/dev/null && break; sleep 0.25; done
cat > "$WORK/summary.mjs" <<'JS'
// prints one JSON line: per instance row of the Summary, its warning / critical / ack cell counts; the test grid's
// acknowledged sum; the header counts line; the Needs-attention instance names
const [cdp, base, cookieLine, mode = ''] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const [name, value] = cookieLine.split('=');
await cmd('Network.enable');
await cmd('Network.setCookie', { name, value, url: base });
// a fresh load every read: a navigation to the same URL and hash would not reload the page
await cmd('Page.navigate', { url: 'about:blank' });
await new Promise(r => setTimeout(r, 200));
await cmd('Page.navigate', { url: base + '#/summary' });
const t0 = Date.now();
while (Date.now() - t0 < 20000) {
  if (await ev(`!!document.querySelector('.attention h3') && document.querySelectorAll('main table').length >= 2`)) break;
  await new Promise(r => setTimeout(r, 200));
}
await new Promise(r => setTimeout(r, 400));
const out = await ev(`(() => {
  const tables = [...document.querySelectorAll('main table')];
  const inst = tables[tables.length - 1], tests = tables[0];
  const rows = {};
  for (const tr of inst.querySelectorAll('tbody tr')) {
    const a = tr.querySelector('a[href*="i="]'); if (!a) continue;
    rows[a.textContent] = { warn: tr.querySelectorAll('td.status.warn').length, crit: tr.querySelectorAll('td.status.crit').length, ack: tr.querySelectorAll('td.status.ack').length };
  }
  const hdr = [...tests.querySelectorAll('thead th')].map(t => t.textContent);
  const ai = hdr.findIndex(h => /acknowledged/.test(h));
  let ackSum = 0;
  for (const tr of tests.querySelectorAll('tbody tr')) ackSum += Number(tr.children[ai]?.textContent || 0);
  const attention = [...document.querySelectorAll('.attention-row strong')].map(s => s.textContent);
  return { rows, ackSum, ackCol: ai >= 0, counts: document.querySelector('.counts')?.textContent ?? '', attention };
})()`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
if (mode === 'pick') {
  // click the first non-zero 'instances critical' count; read the instance grid's column after 'instance'
  Object.assign(out, await ev(`(async () => {
    const tests = document.querySelectorAll('main table')[0];
    const hdr = [...tests.querySelectorAll('thead th')].map(t => t.textContent);
    const ci = hdr.findIndex(h => h === 'instances critical');
    const tr = [...tests.querySelectorAll('tbody tr')].find(r => Number(r.children[ci].textContent) > 0);
    const test = tr.children[0].textContent.trim();
    tr.children[ci].querySelector('button').click();
    await new Promise(r => setTimeout(r, 400));
    const tables = [...document.querySelectorAll('main table')];
    const h2 = [...tables[tables.length - 1].querySelectorAll('thead th')].map(t => t.textContent);
    const after = h2[h2.indexOf('instance') + 1];
    tr.children[ci].querySelector('button').click();   // the same count again clears the pick (it is kept per tab)
    await new Promise(r => setTimeout(r, 300));
    return { pickTest: test, afterInstance: after };
  })()`));
} else if (mode === 'dialog') {
  // Needs attention's first line: Acknowledge, Save with the defaults, read the dialog's answer
  out.dlgName = await ev(`(() => { const r = document.querySelector('.attention-row'); r.querySelector('button').click(); return r.querySelector('strong').textContent; })()`);
  await sleep(300);
  await ev(`document.querySelector('dialog.act-dialog button[type=submit]').click()`);
  const t1 = Date.now();
  while (Date.now() - t1 < 10000) {
    out.dlgSaid = await ev(`document.querySelector('dialog.act-dialog [role=status]')?.textContent ?? ''`);
    if (out.dlgSaid && !/^Saving/.test(out.dlgSaid)) break;
    await sleep(200);
  }
}
console.log(JSON.stringify(out));
ws.close();
JS
summary() { node "$WORK/summary.mjs" "$CDP" "$U/" "$COOKIE" "${1:-}" > "$WORK/sum.json" || fail "the Summary read"; }
get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$WORK/sum.json" "$1"; }
summary
[[ $(get 'd["ackCol"]') == True ]] || fail "C: the test grid has no acknowledged column"
read -r P PBAD < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["rows"]; n=sorted(d, key=lambda k: -(d[k]["warn"]+d[k]["crit"])); print(n[0], d[n[0]]["warn"]+d[n[0]]["crit"])' "$WORK/sum.json")
read -r UN Q < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["rows"]; n=[k for k in sorted(d, key=lambda k: -(d[k]["warn"]+d[k]["crit"])) if d[k]["warn"]+d[k]["crit"]>0]; print(n[1], n[2])' "$WORK/sum.json")
(( PBAD > 0 )) || fail "C: no instance has a warning or critical cell"
UBAD=$(get "d['rows']['$UN']['warn'] + d['rows']['$UN']['crit']")
id_of() { q "select instance_id from pgvigil.instances where name = '$1'"; }
PID=$(id_of "$P"); UID_=$(id_of "$UN"); QID=$(id_of "$Q")
UNTIL=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
ack_all "$PID" ",\"until\":\"$UNTIL\""
ack_all "$UID_" ",\"until_change\":true,\"seen_state\":\"no cell reads this\""
QEXP=$(date -u -d '+25 seconds' +%Y-%m-%dT%H:%M:%SZ)
ack_all "$QID" ",\"until\":\"$QEXP\""
summary
[[ $(get "d['rows']['$P']['warn'] + d['rows']['$P']['crit']") == 0 ]] || fail "C: $P still has coloured cells: $(cat "$WORK/sum.json")"
[[ $(get "d['rows']['$P']['ack']") == "$PBAD" ]] || fail "C: $P has $(get "d['rows']['$P']['ack']") ack cells, expected $PBAD"
QACK=$(get "d['rows']['$Q']['ack']")
(( QACK > 0 )) || fail "X: $Q holds no ack cell at once"
[[ $(get 'd["ackSum"]') == $((PBAD + QACK)) ]] || fail "C: the acknowledged column sums to $(get 'd["ackSum"]'), expected $((PBAD + QACK))"
[[ $(get 'd["counts"]') == *"$((PBAD + QACK)) check(s) acknowledged"* ]] || fail "C: the header line: $(get 'd["counts"]')"
[[ $(get "'$P' in d['attention']") == False ]] || fail "C: $P is still in Needs attention"
ok "C: $P's $PBAD warning / critical cells shown as acknowledged, counted ($((PBAD + QACK)) with $Q's), out of Needs attention"
[[ $(get "d['rows']['$UN']['ack']") == 0 && $(get "d['rows']['$UN']['warn'] + d['rows']['$UN']['crit']") == "$UBAD" ]] || fail "U: $UN: $(cat "$WORK/sum.json")"
ok "U: $UN's until-change acknowledgements for another reading leave its $UBAD cells coloured"

# ---- X: expiry --------------------------------------------------------------------------------------------------------
sleep $(( $(date -d "$QEXP" +%s) - $(date +%s) + 2 ))
[[ $(curl -s -b "$JAR" "$U/api/ack?part=acks" | python3 -c "import json,sys; d=json.load(sys.stdin)['acks']; c=d['columns']; print(sum(1 for r in d['rows'] if r[c.index('instance')]=='$Q' and r[c.index('live')]))") == 0 ]] || fail "X: $Q's acks still live"
summary
[[ $(get "d['rows']['$Q']['ack']") == 0 && $(get "d['rows']['$Q']['warn'] + d['rows']['$Q']['crit']") -ge "$QACK" ]] || fail "X: $Q after expiry: $(cat "$WORK/sum.json")"
ok "X: $Q's acknowledgements expired: live false, its cells coloured again"

# ---- S: a restart -------------------------------------------------------------------------------------------------------
kill "$SRV"; wait "$SRV" 2>/dev/null || true; SRV=""
start_serve
# a UI session lives in serve's memory: the restart ends it, the store's rows stay
login
summary
[[ $(get "d['rows']['$P']['ack']") == "$PBAD" ]] || fail "S: after the restart $P has $(get "d['rows']['$P']['ack']") ack cells"
ok "S: after a restart $P still shows $PBAD acknowledged cells"

# ---- M and L: the sender -----------------------------------------------------------------------------------------------
M=$(q "select i.name from pgvigil.instances i join pgvigil.instance_state s using (instance_id) where i.is_active and i.engine = 'postgres' and i.name not in ('$P','$UN','$Q') order by i.name limit 1")
MID=$(id_of "$M")
q "update pgvigil.instance_state set non_default_settings = coalesce(non_default_settings, '[]'::jsonb) || '[{\"name\": \"autovacuum\", \"value\": \"off\"}]' where instance_id = $MID" >/dev/null
[[ $(q "select count(*) from pgvigil.alert_findings where instance_id = $MID and setting = 'autovacuum' and severity = 'critical'") == 1 ]] || fail "M: $M's autovacuum finding is not in the view"
L=$(q "select instance from pgvigil.alert_findings where severity = 'critical' and instance <> '$M' group by instance order by count(*) desc, instance limit 1")
LID=$(id_of "$L")
MUTE=$(add "{\"kind\":\"mute\",\"instance_id\":$MID,\"match_text\":\"autovacuum\"}")
SIL=$(add "{\"kind\":\"silence\",\"instance_id\":$LID}")
[[ $(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"kind\":\"silence\",\"instance_id\":$LID}" "$U/api/ack") == 409 ]] || fail "L: a second silence of $L: $(cat "$WORK/body")"
grep -q 'already silenced' "$WORK/body" || fail "L: the refusal does not say why: $(cat "$WORK/body")"
export PGV_PROOF_ALERTS_DSN="$(dsn $ALR)"
mkdir -p "$WORK/drop" "$WORK/drop2"
cat > "$WORK/alerts.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: drop, kind: file, min_severity: critical, clear_after: 0, file: {dir: $WORK/drop}}
EOF
pass() { "$BIN" alerts -config "$1" > "$WORK/pass.out" 2> "$WORK/pass.err" || fail "the pass: $(tail -3 "$WORK/pass.err")"; }
files_of() { python3 - "$1" "$2" "${3:-}" <<'PY'
import json, os, sys
d, inst, setting = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
for f in os.listdir(d):
    if not f.endswith('.json'): continue
    a = json.load(open(os.path.join(d, f)))
    if a['instance'] == inst and (not setting or a['setting'] == setting) and a['event'] == 'firing': n += 1
print(n)
PY
}
pass "$WORK/alerts.yaml"
[[ $(files_of "$WORK/drop" "$M" autovacuum) == 0 ]] || fail "M: the muted autovacuum of $M was sent"
[[ $(q "select passes from pgvigil.ack_suppressed where ack_id = $MUTE and channel = 'drop' and instance_name = '$M' and setting = 'autovacuum'") == 1 ]] || fail "M: no held row of the mute after a pass"
pass "$WORK/alerts.yaml"
[[ $(q "select passes from pgvigil.ack_suppressed where ack_id = $MUTE and channel = 'drop' and setting = 'autovacuum'") == 2 ]] || fail "M: the held row's passes after the second pass"
[[ $(files_of "$WORK/drop" "$M" autovacuum) == 0 ]] || fail "M: sent on the second pass"
[[ $(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"ack_id\":$MUTE}" "$U/api/ack/end") == 200 ]] || fail "M: ending the mute: $(cat "$WORK/body")"
pass "$WORK/alerts.yaml"
[[ $(files_of "$WORK/drop" "$M" autovacuum) == 1 ]] || fail "M: no firing file of $M's autovacuum once the mute ended"
ok "M: the mute held $M's autovacuum over two passes (ack_suppressed passes 2), its end let it fire"
cat > "$WORK/alerts2.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: drop2, kind: file, min_severity: critical, clear_after: 0, file: {dir: $WORK/drop2}}
EOF
pass "$WORK/alerts2.yaml"
[[ $(files_of "$WORK/drop2" "$L") == 0 ]] || fail "L: the silenced $L was sent"
OTHER=$(python3 -c "import json,os,sys; print(sum(1 for f in os.listdir(sys.argv[1]) if f.endswith('.json') and json.load(open(os.path.join(sys.argv[1],f)))['instance'] != '$L'))" "$WORK/drop2")
(( OTHER >= 1 )) || fail "L: no other instance was sent to drop2"
[[ $(q "select count(*) || ':' || count(*) filter (where instance_name <> '$L') from pgvigil.ack_suppressed where ack_id = $SIL") =~ ^[1-9][0-9]*:0$ ]] || fail "L: the silence's held rows: $(q "select count(*), count(*) filter (where instance_name <> '$L') from pgvigil.ack_suppressed where ack_id = $SIL")"
ok "L: the silence held $L's alerts only ($(q "select count(*) from pgvigil.ack_suppressed where ack_id = $SIL") logged), $OTHER other alert(s) sent"

# ---- H, O, Z: open alerts -------------------------------------------------------------------------------------------
mkdir -p "$WORK/rep"
cat > "$WORK/rep.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: rep, kind: file, min_severity: critical, repeat: 5m, clear_after: 0, file: {dir: $WORK/rep}}
EOF
pass "$WORK/rep.yaml"
fk_files() { python3 - "$WORK/rep" "$1" "$2" <<'PY'
import json, os, sys
d, key, ev = sys.argv[1:4]
print(sum(1 for f in os.listdir(d) if f.endswith('.json') and (lambda a: a['finding_key'] == key and a['event'] == ev)(json.load(open(os.path.join(d, f))))))
PY
}
inst_files() { python3 - "$WORK/rep" "$1" "$2" <<'PY'
import json, os, sys
d, inst, ev = sys.argv[1:4]
print(sum(1 for f in os.listdir(d) if f.endswith('.json') and (lambda a: a['instance'] == inst and a['event'] == ev)(json.load(open(os.path.join(d, f))))))
PY
}
back6() { q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = 'rep' and cleared_at is null" >/dev/null; }
mapfile -t INSTS < <(q "select instance_name from pgvigil.alert_state where channel = 'rep' and cleared_at is null group by 1 order by count(*) desc, 1")
(( ${#INSTS[@]} >= 3 )) || fail "H: rep opened alerts on ${#INSTS[@]} instance(s)"
K=${INSTS[0]}; K2=${INSTS[1]}
mapfile -t KEYS4 < <(q "select finding_key from pgvigil.alert_state where channel = 'rep' and cleared_at is null and instance_name not in ('$K', '$K2') order by finding_key")
(( ${#KEYS4[@]} >= 4 )) || fail "H: ${#KEYS4[@]} open rep alert(s) outside K and K2"
A1=${KEYS4[0]}; A2=${KEYS4[1]}; A3=${KEYS4[2]}; A4=${KEYS4[3]}
iid_of_key() { q "select instance_id from pgvigil.alert_state where channel = 'rep' and finding_key = '$1' and cleared_at is null"; }
A3SET=$(q "select setting from pgvigil.alert_state where channel = 'rep' and finding_key = '$A3' and cleared_at is null")
MUTE1=$(add "{\"kind\":\"mute\",\"instance_id\":$(iid_of_key "$A1"),\"finding_key\":\"$A1\"}")
ACK2=$(add "{\"kind\":\"alert_ack\",\"instance_id\":$(iid_of_key "$A2"),\"finding_key\":\"$A2\"}")
add "{\"kind\":\"noise\",\"instance_id\":$(iid_of_key "$A3"),\"check_key\":\"$A3SET\",\"note\":\"proof label\"}" >/dev/null
BK=$(add "{\"kind\":\"blackout\",\"instance_id\":$(id_of "$K"),\"starts_at\":\"$(date -u -d '-1 minute' +%FT%TZ)\",\"until\":\"$(date -u -d '+1 hour' +%FT%TZ)\"}")
BK2=$(add "{\"kind\":\"blackout\",\"instance_id\":$(id_of "$K2"),\"starts_at\":\"$(date -u -d '+1 hour' +%FT%TZ)\",\"until\":\"$(date -u -d '+2 hours' +%FT%TZ)\"}")
alerts_get() { curl -s -b "$JAR" "$U/api/ack?part=alerts" > "$WORK/alerts.json"; }
col() {   # col <finding_key | instance=NAME> <column>: the values, space-joined
  python3 - "$WORK/alerts.json" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))['alerts']; c = d['columns']; who, k = sys.argv[2], sys.argv[3]
rows = [dict(zip(c, r)) for r in d['rows']]
rows = [r for r in rows if (r['instance'] == who[9:] if who.startswith('instance=') else r['finding_key'] == who)]
print(' '.join(sorted(set(str(r[k]) for r in rows))))
PY
}
alerts_get
[[ $(col "$A2" ack_id) == "$ACK2" ]] || fail "H: A2's ack_id: $(col "$A2" ack_id)"
[[ $(col "$A3" known_noise) == "proof label" && $(col "$A3" held_by) == None ]] || fail "H: A3: noise '$(col "$A3" known_noise)', held '$(col "$A3" held_by)'"
[[ $(col "instance=$K" is_blackout) == True && $(col "instance=$K2" is_blackout) == False ]] || fail "H: blackout flags: K $(col "instance=$K" is_blackout), K2 $(col "instance=$K2" is_blackout)"
back6; pass "$WORK/rep.yaml"
[[ $(fk_files "$A1" repeat) == 0 && $(fk_files "$A2" repeat) == 0 && $(inst_files "$K" repeat) == 0 ]] || fail "H: a held or acknowledged alert repeated: A1 $(fk_files "$A1" repeat), A2 $(fk_files "$A2" repeat), K $(inst_files "$K" repeat)"
(( $(fk_files "$A3" repeat) >= 1 && $(inst_files "$K2" repeat) >= 1 )) || fail "H: no repeat of A3 ($(fk_files "$A3" repeat)) or K2 ($(inst_files "$K2" repeat))"
[[ $(q "select count(*) from pgvigil.alert_state where channel = 'rep' and finding_key = '$A1' and cleared_at is null") == 1 ]] || fail "H: A1's held row was closed"
[[ $(q "select count(*) from pgvigil.ack_suppressed where ack_id = $MUTE1 and channel = 'rep' and finding_key = '$A1'") == 1 ]] || fail "H: no held row of A1's mute"
[[ $(q "select count(*) || ':' || count(*) filter (where instance_name <> '$K') from pgvigil.ack_suppressed where ack_id = $BK") =~ ^[1-9][0-9]*:0$ ]] || fail "H: the blackout's held rows"
[[ $(q "select count(*) from pgvigil.ack_suppressed where ack_id = $BK2") == 0 ]] || fail "H: the future blackout held a send"
ok "H: on open alerts the mute and the blackout held their repeats (logged, the rows open), the acknowledgement stopped A2's, the known pattern labelled A3 and held nothing, the future blackout nothing"
# the alert gone and back: its open rows on every channel cleared (the grid's occurrence starts at the earliest open send)
q "update pgvigil.alert_state set cleared_at = now() where finding_key = '$A2' and cleared_at is null" >/dev/null
pass "$WORK/rep.yaml"
[[ $(fk_files "$A2" firing) == 2 ]] || fail "O: A2 did not fire again ($(fk_files "$A2" firing) firing files)"
alerts_get
[[ $(col "$A2" ack_id) == None ]] || fail "O: the new occurrence of A2 reads acknowledged ($(col "$A2" ack_id))"
back6; pass "$WORK/rep.yaml"
(( $(fk_files "$A2" repeat) >= 1 )) || fail "O: the new occurrence of A2 did not repeat"
ok "O: the acknowledgement stayed with A2's earlier occurrence: the new one fired, read unacknowledged, repeated"
q "update pgvigil.alert_state set missing_since = now() where finding_key = '$A4' and cleared_at is null" >/dev/null
add "{\"kind\":\"close\",\"instance_id\":$(iid_of_key "$A4"),\"finding_key\":\"$A4\"}" >/dev/null
alerts_get
[[ $(col "$A4" close_id) =~ ^[0-9]+$ ]] || fail "Z: A4 not closed: $(col "$A4" close_id)"
q "update pgvigil.alert_state set missing_since = null where finding_key = '$A4' and cleared_at is null" >/dev/null
alerts_get
[[ $(col "$A4" close_id) == None ]] || fail "Z: A4 back still reads closed"
ok "Z: a close shows while the alert is resolved, not once its finding is back"

# ---- P, D: the page ----------------------------------------------------------------------------------------------------
summary pick
[[ -n $(get 'd["pickTest"]') && $(get 'd["pickTest"]') == $(get 'd["afterInstance"]') ]] || fail "P: picked '$(get 'd["pickTest"]')', the column after instance '$(get 'd["afterInstance"]')'"
ok "P: a critical count of $(get 'd["pickTest"]') clicked: its column first"
summary dialog
V=$(get 'd["dlgName"]'); VB=$(get "d['rows']['$V']['warn'] + d['rows']['$V']['crit']")
[[ $(get 'd["dlgSaid"]') == *"saved"* ]] || fail "D: the dialog said '$(get 'd["dlgSaid"]')'"
summary
[[ $(get "d['rows']['$V']['ack']") == "$VB" && $(get "d['rows']['$V']['warn'] + d['rows']['$V']['crit']") == 0 ]] || fail "D: $V after the dialog: $(get "d['rows']['$V']") (had $VB)"
ok "D: the dialog's until-change acknowledgement of $V holds its $VB cells"

# ---- A: the audit -------------------------------------------------------------------------------------------------------
ADDS=$(q "select count(*) from pgvigil.acks")
(( ADDS >= $(wc -l < "$WORK/adds") )) || fail "A: fewer acks rows ($ADDS) than adds made"
GOT=$(q "select string_agg(op || ':' || outcome || '=' || c, ' ' order by op, outcome) from (select op, outcome, count(*) c from pgvigil.ack_log group by 1, 2) x")
[[ $GOT == "add:done=$ADDS add:refused=1 end:done=1" ]] || fail "A: ack_log holds '$GOT', expected 'add:done=$ADDS add:refused=1 end:done=1'"
# every row names who and from where: the proof's own requests (its user, 127.0.0.1) and the demo seed's (demo, 'demo seed')
[[ $(q "select count(*) from pgvigil.ack_log where not ((ui_user = '$UIUSER' and client = '127.0.0.1') or (ui_user = 'demo' and client = 'demo seed'))") == 0 ]] || fail "A: an ack_log row without the user or the client"
[[ $(q "select count(*) from pgvigil.acks where created_by not in ('$UIUSER', 'demo')") == 0 ]] || fail "A: an acks row without its maker"
ok "A: ack_log $GOT, every row $UIUSER from 127.0.0.1"
echo "PASS: proof-ack"
