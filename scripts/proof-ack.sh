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
#  A. the audit: ack_log's rows of the proof user read add:done=<the acks made> [run 6: 71 against a count of 69: the
#     counter was a variable that MUTE=$(add ...) incremented in a subshell; now a file], add:refused=1, end:done=1, every row
#     with ui_user the proof user and client 127.0.0.1; every acks row has created_by the proof user.
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
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"kind":"silence","instance_id":1}' "$U/api/ack") == 401 ]] || fail "B: no session: $(cat "$WORK/body")"
login() {
  curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
  COOKIE=$(awk '$6 == "pgvigil_session" {print $6 "=" $7}' "$JAR"); [[ -n $COOKIE ]] || fail "no session cookie in the jar"
}
login
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d '{"kind":"silence","instance_id":1}' "$U/api/ack") == 403 ]] || fail "B: no header: $(cat "$WORK/body")"
[[ $(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"kind":"nonsense"}' "$U/api/ack") == 400 ]] || fail "B: unknown kind: $(cat "$WORK/body")"
[[ $(q "select count(*) from pgvigil.ack_log") == 0 ]] || fail "B: a refused request left an ack_log row"
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
const [cdp, base, cookieLine] = process.argv.slice(2);
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
console.log(JSON.stringify(out));
ws.close();
JS
summary() { node "$WORK/summary.mjs" "$CDP" "$U/" "$COOKIE" > "$WORK/sum.json" || fail "the Summary read"; }
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

# ---- A: the audit -------------------------------------------------------------------------------------------------------
ADDS=$(wc -l < "$WORK/adds")
GOT=$(q "select string_agg(op || ':' || outcome || '=' || c, ' ' order by op, outcome) from (select op, outcome, count(*) c from pgvigil.ack_log group by 1, 2) x")
[[ $GOT == "add:done=$ADDS add:refused=1 end:done=1" ]] || fail "A: ack_log holds '$GOT', expected 'add:done=$ADDS add:refused=1 end:done=1'"
[[ $(q "select count(*) from pgvigil.ack_log where ui_user <> '$UIUSER' or client <> '127.0.0.1'") == 0 ]] || fail "A: an ack_log row without the user or the client"
[[ $(q "select count(*) from pgvigil.acks where created_by <> '$UIUSER'") == 0 ]] || fail "A: an acks row without its maker"
ok "A: ack_log $GOT, every row $UIUSER from 127.0.0.1"
echo "PASS: proof-ack"
