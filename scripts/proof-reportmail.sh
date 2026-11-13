#!/usr/bin/env bash
# Proof of task 171 (migration 0107, internal/reportmail, internal/web/q_reportmail.go, web/src/reportmail.ts): reports
# by e-mail. A demo fleet is seeded into a throwaway repository and served with the UI login; a loopback SMTP sink (in
# this script) saves every message it is given; the alert sender's one-off pass (`pgvigil alerts`) is run in a loop as
# the sender. A headless Chromium mails three pages with the bar's Mail... (Send now) and reads each page's grids as
# the screen draws them; three schedules of the same pages are made through the API and brought due; the serve
# process renders each in its own headless browser as the schedule's owner. Each of the six mails is read back from
# the sink and graded cell by cell against the screen. Nothing leaves the machine.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 14+ cluster as a superuser. The proof makes a repository
#                      database and three logins named pgvigil_s171_*_<random> and drops them at the end (a kill drops
#                      them too: the trap). Not dropped: the cluster-wide group roles pgvigil_collector,
#                      pgvigil_reader, pgvigil_alerter and pgvigil_auth (`pgvigil migrate` makes them when missing).
#   PGVIGIL_PYLIB      a folder holding the openpyxl package, when python3 has none of its own
#   PGVIGIL_MAIL_OUT   a folder to keep the sink's messages and the screens in (default: removed with the temp folder)
#   PGVIGIL_DEMO_WAIT_S the seconds the demo's seed may take (default 600)
#   Needs: go, psql, chromium, node, python3, curl, openssl; the web bundle built with the wiring (internal/web/dist/app.js
#   carries 'mailrender': `cd web && npm run build` after the join's main.ts / router.ts lines).
#
# Expected (written before the first run):
#   R  the role contract: a login IN ROLE pgvigil_collector may EXECUTE import_report_mail, import_report_mail_send and
#      import_report_mail_claim and may not INSERT into report_mail_schedules or report_mail_sends; a login IN ROLE
#      pgvigil_alerter may call report_mail_due, report_mail_take, report_mail_expire and report_mail_record, may not
#      call import_report_mail (permission denied for function); a login IN ROLE pgvigil_reader reads
#      report_mail_sends and its report_mail_record and report_mail_take calls are refused (permission denied for table
#      report_mail_sends).
#   B  the door: GET /api/reportmail without a session 401; with one: writable true, user = the UI user, browser true,
#      channels = the two smtp channels (mail, badmail), not the file drop. POST /api/reportmail/send without the
#      X-Pgvigil header 403; a body holding <script> 400, one with an attribute 'onclick=' 400, a bad address 400, a
#      schedule whose cron line sends every 5 minutes 400 - none written (report_mail_sends and report_mail_schedules
#      unchanged). A second serve with -no-login: writable false with a reason naming -no-login; its POST 403.
#   N  Send now: on the fleet Summary, Backups and Storage pages (a fixed window, the demo's last 23 hours) the bar's
#      Mail... dialog takes an address and the channel 'mail', Send now says 'mail <n> queued'; within 3 minutes of
#      sender passes each send is answered 'sent' and the sink holds its message (X-Pgvigil-Report: <n>), To = the
#      address, Subject 'pgvigil: <page> - fleet - <window>'. P03: then a page whose grids are all empty (the first of
#      seven report pages over the window that holds no table and at least one empty grid's note) is mailed the same
#      way and answered sent (Mail refused it before: 'nothing to mail').
#   N2 [B3 DONE-2] Send now of a demo SQL Server instance's Community tools page with tool=sp_Blitz (its stored sample
#      open as the page loads): answered sent; the mail's HTML carries the sample's mark (GET /api/community's
#      sample.mark) above its grid and the workbook's Summary sheet carries it too.
#   S  schedules: on the Jobs page a column hidden with the grid's menu holds over a reload, and Mail... > Schedule this
#      page... adds a schedule that keeps that grid's choice (grid_prefs, one grid); three more added through POST
#      /api/reportmail (daily at 07:00, the same three routes, the third in America/Los_Angeles), next_at = the next
#      07:00 in each zone. Brought due by the proof (next_at a second into the past) with two serves with the login on
#      the repository: one claimed turn is taken over by the proof while its page is drawn (a new claim token, a 60 s
#      lease) - that render's turn is refused ('no longer this server's') and the turn mailed after the lease; every
#      schedule has exactly one scheduled mail sent (none twice), rendered headless as the owner; next_at back at the
#      next 07:00 of its zone, no lease, no token; the subject starts with the schedule's name and carries the window.
#   T  Send test on a schedule: queued as kind test by the asking user, mailed with '[test] <name> - ' as its subject; a
#      second test at once is refused (one at a time).
#   C  every one of the nine mails (four now, four scheduled, the test) against the page's screen (the driver's read of the same route): the same grids in
#      order under the same headings, the same header cells, the same row count, and for every drawn row every cell's
#      text equal; every cell the screen colours carries that status's fill and text colour (ok #006638 / #ffffff, warn
#      #e49325 / #1d1300, crit #ab1f26 / #ffffff, none #e0e1e9 / #004f83, ack #1b6aa3 / #ffffff); a link cell #f1f1f6
#      / #004f83; any other cell no fill, or a colour its row's judging cell shows on the screen (the export's carry
#      rule) with words in it; the header cells #0063a3 with white bold text. Counted per mail (cells, coloured cells).
#      The Jobs schedule's mail has no column the owner hid; the Los Angeles schedule's mail says America/Los_Angeles in
#      its time zone line and its times equal the screen read in that zone.
#   H  every mail's HTML passes a mail client: tags only of html, head, meta, title, body, h2, h3, p, table, thead,
#      tbody, tr, th, td; no script, style element, class attribute, event attribute or javascript: URL; every th and
#      td carries its own style; one HTML part (text/html, base64) and one plain part (text/plain) in a
#      multipart/alternative.
#   X  every mail's .xlsx attachment opens with openpyxl and is the page's Export .xlsx (P03): a Summary sheet first,
#      then one sheet per grid of the page in order, each with the mail's grid's rows under its header row, an empty
#      grid's sheet its header row alone (the screen's columns, no data row).
#   F  failures: a Send now through 'badmail' (an smtp relay on a port nothing listens on) is answered 'failed' with
#      the connection's error, and a 'report mail failed' notice naming the mail reaches the file drop and the sink (the
#      notice is sent on every channel); a schedule whose owner is disabled before its turn is answered 'failed' with
#      'can no longer sign in' and alerted the same way; the scheduled turn moved on all the same.
#   P  the Report mail page (#/reportmail): the Schedules grid lists the five schedules, the Sends grid the mails with
#      their outcomes; the New schedule dialog has every field labelled and closes on Escape.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); R=$RANDOM
REPO="pgvigil_s171_repo_$R"; COL="pgvigil_s171_col_$R"; ALR="pgvigil_s171_alr_$R"; RDR="pgvigil_s171_rdr_$R"
PW=$(openssl rand -hex 16); UIUSER=proofmail; UIPW=$(openssl rand -hex 12); U2USER=proofgone; U2PW=$(openssl rand -hex 12)
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PORT=$(freeport); PORT2=$(freeport); PORT3=$(freeport); SINKP=$(freeport); DEAD=$(freeport); CDP=$(freeport)
SRV=""; SRV2=""; SRV3=""; SINK=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  for p in "$SRV" "$SRV2" "$SRV3" "$SINK" "$CHR"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  pkill -f "pgvigil-render-" 2>/dev/null || true   # a render's browser left by a killed serve
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || true
  for r in "$COL" "$ALR" "$RDR"; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $r" >/dev/null 2>&1 || true; done
  if [[ -n "${PGVIGIL_MAIL_OUT:-}" ]]; then mkdir -p "$PGVIGIL_MAIL_OUT"; cp -r "$WORK/sink" "$WORK"/screen-*.json "$PGVIGIL_MAIL_OUT/" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql chromium node python3 curl openssl; do command -v $t >/dev/null || fail "$t is not on this machine"; done
grep -q 'mailrender' internal/web/dist/app.js || fail "the web bundle has no report mail: wire reportmail.ts (main.ts, router.ts) and run 'npm run build' in web/"
export PYTHONPATH="${PGVIGIL_PYLIB:-}${PYTHONPATH:+:$PYTHONPATH}"
python3 -c 'import openpyxl' 2>/dev/null || fail "python3 has no openpyxl (PGVIGIL_PYLIB names a folder that holds it)"
LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)
echo "== the machine's load at the start: $LOAD"

echo "== build, seed the demo into $REPO"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
BIN=$WORK/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
timeout "${PGVIGIL_DEMO_WAIT_S:-600}" "$BIN" demo -dsn "$PGVIGIL_REPO_DSN" -days 1 > "$WORK/demo.log" 2>&1 || { tail -5 "$WORK/demo.log"; fail "the demo seed failed or passed ${PGVIGIL_DEMO_WAIT_S:-600} s"; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(q "select count(*) from pgvigil.schema_version where version = '0107_report_mail.sql'") == 1 ]] || fail "0107 is not applied"
ANCHOR=$(sed -n 's/.*anchor \([0-9TZ:-]*\).*/\1/p' "$WORK/demo.log" | head -1)
[[ -n $ANCHOR ]] || fail "the demo did not say its anchor: $(tail -2 "$WORK/demo.log")"
# the window of every page: the demo's last 23 hours, fixed (the pages are history: nothing redraws them)
TO=$(date -u -d "$ANCHOR" +%Y-%m-%dT%H:%M:00.000Z); FROM=$(date -u -d "$ANCHOR - 23 hours" +%Y-%m-%dT%H:%M:00.000Z)
ok "the demo seeded (anchor $ANCHOR); the window $FROM to $TO"

psql "$PGVIGIL_REPO_DSN" -XAtq -c "create role $COL login password '$PW' in role pgvigil_collector" \
  -c "create role $ALR login password '$PW' in role pgvigil_alerter" -c "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null
dsn() { echo "$PGVIGIL_ADMIN_DSN dbname=$REPO user=$1 password=$PW"; }
export PGV_ALERTS_DSN; PGV_ALERTS_DSN=$(dsn "$ALR")
as() { local who=$1; shift; psql "$(dsn "$who")" -XAt "$@" 2>&1 || true; }
mkdir -p "$WORK/sink" "$WORK/drop"
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_ALERTS_DSN
alerts:
  - {name: mail, kind: smtp, min_severity: critical, instances: [proof-none], smtp: {host: 127.0.0.1, port: $SINKP, tls: none, from: "pgvigil <alerts@pgvigil.test>", to: [admin@pgvigil.test]}}
  - {name: badmail, kind: smtp, min_severity: critical, instances: [proof-none], smtp: {host: 127.0.0.1, port: $DEAD, tls: none, from: alerts@pgvigil.test, to: [admin@pgvigil.test]}}
  - {name: drop, kind: file, min_severity: critical, instances: [proof-none], file: {dir: $WORK/drop}}
instances: []
EOF
CFG=$WORK/cfg.yaml

# ---- R: the role contract -------------------------------------------------------------------------------------------
for f in "import_report_mail(timestamptz, jsonb)" "import_report_mail_send(timestamptz, jsonb)" "import_report_mail_claim(timestamptz, integer, integer)"; do
  [[ $(as "$COL" -c "select has_function_privilege('pgvigil.$f', 'EXECUTE')") == t ]] || fail "R: the collector may not call $f"
done
out=$(as "$COL" -c "insert into pgvigil.report_mail_sends (kind, name, route, requested_by, requested_at, channel, recipients, subject) values ('now','x','#/summary','x',now(),'mail','{a@b.org}','x')")
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into report_mail_sends: $out"
out=$(as "$COL" -c "insert into pgvigil.report_mail_schedules (name, route, recipients, channel, cadence, cron, timezone, created_by, created_at) values ('x','#/summary','{a@b.org}','mail','daily','0 7 * * *','UTC','x',now())")
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into report_mail_schedules: $out"
[[ $(as "$ALR" -c "select count(*) from pgvigil.report_mail_due(now())") == 0 ]] || fail "R: the alerter's report_mail_due: $(as "$ALR" -c "select count(*) from pgvigil.report_mail_due(now())")"
out=$(as "$ALR" -c "select pgvigil.report_mail_record(now(), -1, 'sent', null, 0)")
[[ $out != *ERROR* ]] || fail "R: the alerter's report_mail_record: $out"
[[ $(as "$ALR" -c "select pgvigil.report_mail_take(now(), -1)") == f ]] || fail "R: the alerter's report_mail_take: $(as "$ALR" -c "select pgvigil.report_mail_take(now(), -1)")"
[[ $(as "$ALR" -c "select count(*) from pgvigil.report_mail_expire(now())") == 0 ]] || fail "R: the alerter's report_mail_expire: $(as "$ALR" -c "select count(*) from pgvigil.report_mail_expire(now())")"
out=$(as "$ALR" -c "select pgvigil.import_report_mail(now(), '{\"op\":\"end\",\"ui_user\":\"x\",\"schedule_id\":1}')")
[[ $out == *"permission denied for function"* ]] || fail "R: the alerter called import_report_mail: $out"
[[ $(as "$RDR" -c "select count(*) from pgvigil.report_mail_sends") == 0 ]] || fail "R: the reader cannot read report_mail_sends"
out=$(as "$RDR" -c "select pgvigil.report_mail_record(now(), -1, 'sent', null, 0)")
[[ $out == *"permission denied for table report_mail_sends"* ]] || fail "R: the reader's report_mail_record: $out"
out=$(as "$RDR" -c "select pgvigil.report_mail_take(now(), -1)")
[[ $out == *"permission denied for table report_mail_sends"* ]] || fail "R: the reader's report_mail_take: $out"
ok "R: the collector writes only through the import functions, the alerter answers and writes no schedule, the reader reads"

# ---- the sink, the sender's loop, two serves --------------------------------------------------------------------------
cat > "$WORK/sink.py" <<'PY'
import itertools, os, socketserver, sys
port, out = int(sys.argv[1]), sys.argv[2]
seq = itertools.count(1)
class H(socketserver.StreamRequestHandler):
    def handle(self):
        def w(s):
            self.wfile.write((s + '\r\n').encode()); self.wfile.flush()
        w('220 sink ESMTP'); frm, rcpt = '', []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            cmd = line.decode('latin-1').rstrip('\r\n'); u = cmd.upper()
            if u.startswith('EHLO'):
                w('250-sink'); w('250-8BITMIME'); w('250 SIZE 52428800')
            elif u.startswith('HELO'):
                w('250 sink')
            elif u.startswith('MAIL FROM:'):
                frm, rcpt = cmd[10:].strip(), []; w('250 ok')
            elif u.startswith('RCPT TO:'):
                rcpt.append(cmd[8:].strip()); w('250 ok')
            elif u == 'DATA':
                w('354 go'); data = []
                while True:
                    l = self.rfile.readline()
                    if not l:
                        return
                    if l in (b'.\r\n', b'.\n'):
                        break
                    data.append(l[1:] if l.startswith(b'..') else l)
                n = next(seq)
                with open(os.path.join(out, '%03d.eml' % n), 'wb') as f:
                    f.write(b''.join(data))
                with open(os.path.join(out, '%03d.env' % n), 'w') as f:
                    f.write(frm + '\n' + '\n'.join(rcpt) + '\n')
                w('250 queued as %d' % n)
            elif u in ('RSET', 'NOOP'):
                w('250 ok')
            elif u == 'QUIT':
                w('221 bye'); return
            else:
                w('502 not here')
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True; daemon_threads = True
S(('127.0.0.1', port), H).serve_forever()
PY
python3 "$WORK/sink.py" "$SINKP" "$WORK/sink" > "$WORK/sink.log" 2>&1 &
SINK=$!
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" $UIUSER >/dev/null 2>&1 || fail "user add"
PGVIGIL_PASSWORD=$U2PW "$BIN" user add -config "$CFG" $U2USER >/dev/null 2>&1 || fail "user add (the second)"
U="http://127.0.0.1:$PORT"; U2="http://127.0.0.1:$PORT2"
TZ=UTC "$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 &
SRV=$!
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT2" -no-login >> "$WORK/serve2.log" 2>&1 &
SRV2=$!
# a second serve with the login on the same repository: two schedulers claim the same turns
U3="http://127.0.0.1:$PORT3"
TZ=UTC "$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT3" >> "$WORK/serve3.log" 2>&1 &
SRV3=$!
for pair in "$SRV $U serve.log" "$SRV2 $U2 serve2.log" "$SRV3 $U3 serve3.log"; do
  read -r pid url log <<<"$pair"
  for n in $(seq 1 120); do
    curl -sf -o /dev/null "$url/" && break
    kill -0 "$pid" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/$log")"
    [[ $n == 120 ]] && fail "serve did not answer on $url"
    sleep 0.5
  done
done
sender() { "$BIN" alerts -config "$CFG" >> "$WORK/sender.log" 2>&1 || true; }
sender   # the first pass records the channels (alert_channels)
[[ $(q "select count(*) from pgvigil.alert_channels where is_configured and name in ('mail', 'badmail', 'drop')") == 3 ]] || fail "the sender did not record its channels: $(tail -3 "$WORK/sender.log")"

JAR=$WORK/jar; JAR2=$WORK/jar2
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
login() { curl -s -c "$1" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$2\",\"password\":\"$3\"}" "$U/api/login" >/dev/null; }
postj() { code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary "$2" "$U/api/$1"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$WORK/body" "$1"; }
nsends() { q "select count(*) from pgvigil.report_mail_sends"; }
nscheds() { q "select count(*) from pgvigil.report_mail_schedules"; }

# ---- B: the door ----------------------------------------------------------------------------------------------------
[[ $(code "$U/api/reportmail") == 401 ]] || fail "B: no session: $(cat "$WORK/body")"
login "$JAR" "$UIUSER" "$UIPW"; login "$JAR2" "$U2USER" "$U2PW"
TOKEN=$(awk '$6 == "pgvigil_session" {print $7}' "$JAR"); [[ -n $TOKEN ]] || fail "B: no session cookie"
[[ $(code -b "$JAR" "$U/api/reportmail") == 200 ]] || fail "B: GET: $(cat "$WORK/body")"
[[ $(jget "d['door']['writable'], d['door']['user'], d['door']['browser']") == "(True, '$UIUSER', True)" ]] || fail "B: the door: $(jget "d['door']")"
[[ $(jget "sorted(r[0] for r in d['channels']['rows'])") == "['badmail', 'mail']" ]] || fail "B: the smtp channels: $(jget "d['channels']")"
S0=$(nsends); C0=$(nscheds)
GOODHTML='<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>t</title></head><body><table><tr><td style=\"x\">x one=1</td></tr></table></body></html>'
SCRIPTHTML='<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>t</title></head><body><table><tr><td style=\"x\">x</td></tr></table><script>alert(1)</script></body></html>'
EVENTHTML='<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>t</title></head><body><table><tr><td style=\"x\" onclick=\"x()\">x</td></tr></table></body></html>'
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d "{\"route\":\"#/summary\",\"recipients\":[\"a@pgvigil.test\"],\"channel\":\"mail\",\"subject\":\"x\",\"html\":\"$GOODHTML\"}" "$U/api/reportmail/send") == 403 ]] || fail "B: no header: $(cat "$WORK/body")"
[[ $(postj reportmail/send "{\"name\":\"x\",\"route\":\"#/summary\",\"recipients\":[\"a@pgvigil.test\"],\"channel\":\"mail\",\"subject\":\"x\",\"html\":\"$SCRIPTHTML\"}") == 400 ]] || fail "B: a script body: $(cat "$WORK/body")"
[[ $(postj reportmail/send "{\"name\":\"x\",\"route\":\"#/summary\",\"recipients\":[\"a@pgvigil.test\"],\"channel\":\"mail\",\"subject\":\"x\",\"html\":\"$EVENTHTML\"}") == 400 ]] || fail "B: an event attribute: $(cat "$WORK/body")"
[[ $(postj reportmail/send "{\"name\":\"x\",\"route\":\"#/summary\",\"recipients\":[\"not an address\"],\"channel\":\"mail\",\"subject\":\"x\",\"html\":\"$GOODHTML\"}") == 400 ]] || fail "B: a bad address: $(cat "$WORK/body")"
[[ $(postj reportmail "{\"op\":\"add\",\"name\":\"x\",\"route\":\"#/summary\",\"recipients\":[\"a@pgvigil.test\"],\"channel\":\"mail\",\"cadence\":\"cron\",\"cron\":\"*/5 * * * *\",\"timezone\":\"UTC\"}") == 400 ]] || fail "B: a 5-minute schedule: $(cat "$WORK/body")"
grep -q 'at most every 15m' "$WORK/body" || fail "B: the 5-minute refusal's words: $(cat "$WORK/body")"
[[ $(postj reportmail/rendered "{\"key\":\"$(openssl rand -hex 24)\",\"html\":\"$GOODHTML\"}") == 404 ]] || fail "B: a render post-back with a key of no render: $(cat "$WORK/body")"
[[ $(nsends) == "$S0" && $(nscheds) == "$C0" ]] || fail "B: a refused request wrote"
[[ $(code "$U2/api/reportmail") == 200 && $(jget "d['door']['writable'], '-no-login' in d['door']['reason']") == "(False, True)" ]] || fail "B: the -no-login serve: $(cat "$WORK/body")"
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"end","schedule_id":1}' "$U2/api/reportmail") == 403 ]] || fail "B: the -no-login serve took a write"
ok "B: 401 without a session, 403 without the header, 400 for a script, an event attribute, a bad address and a 5-minute cron, none written; a post-back without a render 404; no login = read only"

# ---- the browser and its driver ---------------------------------------------------------------------------------------
TZ=UTC LANGUAGE=en_US chromium --headless=new --lang=en-US --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --window-size=1600,1200 about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/version" >/dev/null && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/version" >/dev/null || fail "chromium's CDP port never answered"
cat > "$WORK/drive.mjs" <<'JS'
const [port, U, token, mode, out, tag, ...routes] = process.argv.slice(2);
const fs = await import('node:fs');
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
const settled = async () => {
  let last = '', since = Date.now();
  for (const t = Date.now(); Date.now() - t < 30000; await sleep(200)) {
    const s = await ev(`(() => { const m = document.querySelector('main'); if (!m || !m.children.length || !document.querySelector('#bar .mail')) return 'busy'; if ([...m.querySelectorAll('p.empty')].some(p => /^Loading/.test(p.textContent))) return 'busy'; return m.innerHTML.length + ':' + m.querySelectorAll('table.grid > tbody > tr').length; })()`);
    if (s === 'busy' || s !== last) { last = s; since = Date.now(); continue; }
    if (Date.now() - since > 1200) return true;
  }
  return false;
};
// the screen's grids as the export reads them (proof-export.sh's reader): each cell's words, its status, a link
const SCREEN = `(() => {
  const words = e => { const f = e.querySelector('[data-full]'); if (f) return f.getAttribute('data-full'); const t = (e.textContent || '').replace(/\\s+/g, ' ').trim(); return t || (e.querySelector('[data-text]')?.getAttribute('data-text') ?? ''); };
  const pick = x => ['crit', 'warn', 'ok', 'none'].find(k => x.classList.contains(k)) ?? null;
  // the screen's colour of a cell, read on its own terms (proof-export.sh's reader; not export.ts's rule): a status cell; else the worst of the
  // marks drawn in it (a badge, a dot, a data bar's fill, a span marked warn / crit: those with a size on the screen)
  // and of its texts painted in the critical or the warning colour (computed); else a bare class on the cell
  const probe = c => { const s = document.createElement('span'); s.style.color = 'var(--' + c + ')'; document.body.append(s); const v = getComputedStyle(s).color; s.remove(); return v; };
  const CRIT = probe('crit'), WARN = probe('warn');
  const KNOWN = '.badge, .dot, .bar-fill, .crit, .warn';
  const drawn = m => { const r = m.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const own = m => [...m.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  const st = td => { if (td.classList.contains('status')) return td.classList.contains('ack') ? 'ack' : pick(td);
    const got = new Set([...td.querySelectorAll('*')].filter(drawn).map(m => m.matches(KNOWN) ? pick(m) : own(m) ? (getComputedStyle(m).color === CRIT ? 'crit' : getComputedStyle(m).color === WARN ? 'warn' : null) : null).filter(Boolean));
    const w = ['crit', 'warn', 'ok', 'none'].find(k => got.has(k)); if (w) return w;
    return ['crit', 'warn', 'ok'].find(k => td.classList.contains(k)) ?? null; };
  const head = c => { const x = c.cloneNode(true); x.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove()); return words(x); };
  const cell = td => ({ t: words(td), s: st(td), l: !td.classList.contains('status') && !!td.querySelector('a[href]') });
  let outer = '', inner = null;
  return [...document.querySelectorAll('main h2, main h3, main h4, main table.grid, main table.props, main p.empty[data-cols]')].flatMap(e => {
    if (e.tagName !== 'TABLE' && e.tagName !== 'P') { const within = e.closest('[role=region]'); if (within) inner = { text: head(e), within }; else { outer = head(e); inner = null; } return []; }
    const named = inner && inner.within.contains(e) ? inner.text : outer;
    // a grid with no row (ui.ts grid: its note carries the columns): no table in the mail's body, a sheet of its header
    // row in its workbook (P03: the mail's workbook is Export .xlsx's)
    if (e.tagName === 'P') { let cols = []; try { cols = JSON.parse(e.dataset.cols || '[]'); } catch { cols = []; } return Array.isArray(cols) && cols.length ? [{ named, grid: true, empty: true, rows: 0, head: cols.map(String), cells: [] }] : []; }
    const grid = e.classList.contains('grid');
    const ths = grid ? [...e.querySelectorAll(':scope > thead > tr:first-child > th')] : [];
    const keep = ths.map(h => !h.hasAttribute('data-gt-hidden'));   // a column hidden with the grid tools is left out, as the export leaves it
    const cells = grid ? [...e.querySelectorAll(':scope > tbody > tr')].filter(tr => !tr.classList.contains('trend-row')).map(tr => [...tr.children].filter((_, j) => keep[j] ?? true).map(cell))
      : [...e.querySelectorAll('tr')].map(tr => { const th = tr.querySelector('th'), td = tr.querySelector('td'); return [{ t: th ? words(th) : '', s: null, l: false }, { t: td ? words(td) : '', s: td ? st(td) : null, l: false }]; });
    return [{ named, grid, rows: e.dataset.rows ? Number(e.dataset.rows) : cells.length, head: grid ? ths.filter((_, j) => keep[j]).map(head) : ['item', 'value'], cells }];
  });
})()`;
let navs = 0;
await cmd('Page.navigate', { url: U + '/?n=0#/about' }); await sleep(600);
const open = async (route, zone = '') => {
  await ev(zone ? `localStorage.setItem('pgvigil.tz', ${JSON.stringify(zone)})` : `localStorage.removeItem('pgvigil.tz')`);
  await cmd('Page.navigate', { url: U + '/?n=' + (++navs) + route }); await sleep(400);   // a new query: a full load (the zone is read at load)
  if (!await settled()) throw new Error('the page did not settle: ' + route);
};
const split = a => a.includes('^') ? [a.slice(a.indexOf('^') + 1), a.slice(0, a.indexOf('^'))] : [a, ''];
const res = {};
if (mode === 'now' || mode === 'screen') {
  const base = mode === 'now' && /^\d+$/.test(tag) ? Number(tag) : 0;   // a later Send now numbers its screens on from the first's
  for (const [k, arg] of routes.entries()) {
    const i = base + k;
    const [route, zone] = split(arg);
    await open(route, zone);
    const screen = await ev(SCREEN);
    fs.writeFileSync(`${out}/screen-${mode === 'now' ? 'now' : tag}-${i}.json`, JSON.stringify({ route, screen }));
    if (mode === 'now') {
      await ev(`document.querySelector('#bar .mail button').click()`);
      for (let n = 0; n < 50 && !await ev(`!!document.querySelector('dialog[open] textarea')`); n++) await sleep(100);
      await ev(`(() => { const d = document.querySelector('dialog[open]'); const t = d.querySelector('textarea'); t.value = 'now-${i}@pgvigil.test'; t.dispatchEvent(new Event('input', { bubbles: true }));
        const s = d.querySelector('select'); s.value = 'mail'; s.dispatchEvent(new Event('change', { bubbles: true })); d.querySelector('button[type=submit]').click(); })()`);
      let said = '';
      for (let n = 0; n < 150; n++) { await sleep(200); said = await ev(`document.querySelector('dialog[open] [role=status]')?.textContent ?? ''`); if (/queued|not done/.test(said)) break; }
      const m = /mail (\d+) queued/.exec(said);
      if (!m) throw new Error('Send now said: ' + said);
      res[route] = Number(m[1]);
      await ev(`(() => { const d = document.querySelector('dialog[open]'); [...d.querySelectorAll('button')].find(b => b.textContent === 'Close' || b.textContent === 'Back').click(); })()`);
      await sleep(300);
      fs.writeFileSync(`${out}/screen-nowb-${i}.json`, JSON.stringify({ route, screen: await ev(SCREEN) }));
    }
  }
} else if (mode === 'pickempty') {
  // the first of the routes whose page holds grids and every one of them empty (no table.grid, no property card, at
  // least one empty grid's note with its columns): the page Mail refused before P03
  res.seen = [];
  for (const route of routes) {
    await open(route);
    const k = await ev(`[document.querySelectorAll('main table.grid, main table.props').length, [...document.querySelectorAll('main p.empty[data-cols]')].filter(p => { try { return JSON.parse(p.dataset.cols).length > 0; } catch { return false; } }).length]`);
    res.seen.push(`${route}: ${k[0]} tables, ${k[1]} empty grids`);
    if (k[0] === 0 && k[1] > 0) { res.route = route; res.empties = k[1]; break; }
  }
} else if (mode === 'prefs') {
  // a column hidden with the grid tools (the grid's menu), kept over a reload; then Mail... > Schedule this page... > Add
  const route = routes[0];
  await open(route);
  const T = `document.querySelector('main table.grid')`;
  const heads = await ev(`[...${T}.querySelectorAll(':scope > thead > tr:first-child > th')].map(h => { const c = h.cloneNode(true); c.querySelectorAll('.filter-btn, .whatis').forEach(b => b.remove()); return c.textContent.trim(); })`);
  const col = heads[1];
  await ev(`${T}.querySelector(':scope > tbody > tr').children[1].dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 320, clientY: 320 }))`);
  await sleep(200);
  const hit = await ev(`(() => { const b = [...document.querySelectorAll('.menu button')].find(x => x.textContent === ${JSON.stringify('Hide column ' + col)}); if (!b) return [...document.querySelectorAll('.menu button')].map(x => x.textContent).join(' | '); b.click(); return 'ok'; })()`);
  if (hit !== 'ok') throw new Error(`no 'Hide column ${col}' in the grid's menu: ${hit}`);
  await sleep(300);
  await open(route);
  const hiddenNow = await ev(`${T}.querySelectorAll(':scope > thead > tr:first-child > th[data-gt-hidden]').length`);
  if (hiddenNow !== 1) throw new Error('the hidden column did not hold over a reload: ' + hiddenNow);
  await ev(`document.querySelector('#bar .mail button').click()`);
  for (let n = 0; n < 50 && !await ev(`!!document.querySelector('dialog[open] textarea')`); n++) await sleep(100);
  await ev(`[...document.querySelectorAll('dialog[open] button')].find(b => b.textContent === 'Schedule this page...').click()`);
  for (let n = 0; n < 80 && await ev(`document.querySelector('dialog[open] h3')?.textContent ?? ''`) !== 'New report mail schedule'; n++) await sleep(100);
  res.note = await ev(`(() => { const d = document.querySelector('dialog[open]'); const name = d.querySelector('input[type=text]'); name.value = 'Proof hidden column'; name.dispatchEvent(new Event('input', { bubbles: true }));
    const t = d.querySelector('textarea'); t.value = 'sched-3@pgvigil.test'; t.dispatchEvent(new Event('input', { bubbles: true }));
    const ss = d.querySelectorAll('select'); ss[0].value = 'mail'; ss[0].dispatchEvent(new Event('change', { bubbles: true })); ss[2].value = 'UTC'; ss[2].dispatchEvent(new Event('change', { bubbles: true }));
    const note = [...d.querySelectorAll('p.meta')].map(p => p.textContent).find(x => /grid choices/.test(x)) ?? '';
    d.querySelector('button[type=submit]').click(); return note; })()`);
  let said = '';
  for (let n = 0; n < 100; n++) { await sleep(200); said = await ev(`document.querySelector('dialog[open] [role=status]')?.textContent ?? ''`); if (/added|not done/.test(said)) break; }
  const m = /schedule (\d+) added/.exec(said);
  if (!m) throw new Error('the schedule dialog said: ' + said);
  res.schedule_id = Number(m[1]); res.hidden = col;
} else if (mode === 'page') {
  await open('#/reportmail?w=24h');
  res.screen = await ev(SCREEN);
  await ev(`[...document.querySelectorAll('main button')].find(b => b.textContent === 'New schedule...').click()`);
  for (let n = 0; n < 50 && !await ev(`!!document.querySelector('dialog[open] form')`); n++) await sleep(100);
  res.unlabelled = await ev(`[...document.querySelectorAll('dialog[open] input, dialog[open] select, dialog[open] textarea')].filter(x => !x.closest('label') && !x.getAttribute('aria-label') && !x.closest('fieldset')?.querySelector('legend')).map(x => x.outerHTML.slice(0, 80))`);
  res.fields = await ev(`document.querySelectorAll('dialog[open] input, dialog[open] select, dialog[open] textarea').length`);
  await cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await sleep(300);
  res.closed = await ev(`!document.querySelector('dialog')`);
}
console.log(JSON.stringify(res));
process.exit(0);
JS
ROUTES=("#/summary?from=$FROM&to=$TO" "#/backups?from=$FROM&to=$TO" "#/storage?from=$FROM&to=$TO")
drive() { node "$WORK/drive.mjs" "$CDP" "$U" "$TOKEN" "$@"; }

# ---- N: Send now from the window ----------------------------------------------------------------------------------------
drive now "$WORK" - "${ROUTES[@]}" > "$WORK/now.json" || fail "N: the driver: $(tail -3 "$WORK/now.json")"
NOWIDS=$(python3 -c 'import json,sys; print(" ".join(str(v) for v in json.load(open(sys.argv[1])).values()))' "$WORK/now.json")
[[ $(wc -w <<<"$NOWIDS") == 3 ]] || fail "N: three sends asked, got: $(cat "$WORK/now.json")"
waitsent() {   # waitsent <ids...>: the sender's passes until every id is answered (3 minutes)
  local ids; ids=$(tr ' ' ',' <<<"$*")
  for _ in $(seq 1 36); do
    sender
    [[ $(q "select count(*) from pgvigil.report_mail_sends where send_id in ($ids) and done_at is not null") == $# ]] && return 0
    sleep 5
  done
  return 1
}
waitsent $NOWIDS || fail "N: not answered in 3 minutes: $(q "select send_id, coalesce(outcome, 'queued'), error from pgvigil.report_mail_sends where send_id in ($(tr ' ' ',' <<<"$NOWIDS"))")"
[[ $(q "select count(*) from pgvigil.report_mail_sends where send_id in ($(tr ' ' ',' <<<"$NOWIDS")) and outcome = 'sent' and kind = 'now' and requested_by = '$UIUSER' and html is null") == 3 ]] || fail "N: $(q "select send_id, outcome, error from pgvigil.report_mail_sends where send_id in ($(tr ' ' ',' <<<"$NOWIDS"))")"
ok "N: three pages mailed with Send now (mails $NOWIDS), each answered sent, the payload cleared"
# P03: a page whose grids are all empty (Mail refused it before: 'nothing to mail'): mailed, its workbook a sheet of the
# header row per grid (graded in X with the others)
drive pickempty "$WORK" - "#/rp_killed?from=$FROM&to=$TO" "#/rp_flushed?from=$FROM&to=$TO" "#/rp_failed?from=$FROM&to=$TO" "#/rp_dbdeleted?from=$FROM&to=$TO" "#/rp_dbnew?from=$FROM&to=$TO" "#/rp_actions?from=$FROM&to=$TO" "#/corruption?from=$FROM&to=$TO" > "$WORK/pick.json" || fail "N: the empty page's pick: $(tail -3 "$WORK/pick.json")"
EMPTYR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("route") or "")' "$WORK/pick.json")
[[ -n $EMPTYR ]] || fail "N: no page of the candidates holds only empty grids: $(cat "$WORK/pick.json")"
drive now "$WORK" 3 "$EMPTYR" > "$WORK/now2.json" || fail "N: Send now of $EMPTYR: $(tail -3 "$WORK/now2.json")"
EMPTYID=$(python3 -c 'import json,sys; print(" ".join(str(v) for v in json.load(open(sys.argv[1])).values()))' "$WORK/now2.json")
[[ $(wc -w <<<"$EMPTYID") == 1 ]] || fail "N: the empty page's send: $(cat "$WORK/now2.json")"
waitsent $EMPTYID || fail "N: the empty page's mail not answered in 3 minutes"
[[ $(q "select count(*) from pgvigil.report_mail_sends where send_id = $EMPTYID and outcome = 'sent' and kind = 'now'") == 1 ]] || fail "N: the empty page's mail: $(q "select send_id, outcome, error from pgvigil.report_mail_sends where send_id = $EMPTYID")"
ok "N: $EMPTYR, every grid on it empty ($(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["empties"])' "$WORK/pick.json") grids), mailed with Send now (mail $EMPTYID), answered sent"
NOWIDS="$NOWIDS $EMPTYID"
# ---- N2 (B3 DONE-2): a demo instance's stored sample mailed: its grid carries its mark into the body and the workbook ----
DSID=$(q "select instance_id from pgvigil.instances where 'demo' = any (tags) and engine = 'sqlserver' order by name limit 1")
[[ -n $DSID ]] || fail "N2: the demo seeded no SQL Server instance"
[[ $(code -b "$JAR" "$U/api/community?instance=$DSID") == 200 ]] || fail "N2: GET /api/community: $(head -c 300 "$WORK/body")"
SMARK=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next(t["sample"]["mark"] for t in d["tools"] if t["id"] == "sp_Blitz"))' "$WORK/body") || fail "N2: no sample mark for sp_Blitz: $(head -c 300 "$WORK/body")"
drive now "$WORK" 4 "#/community?i=$DSID&tool=sp_Blitz" > "$WORK/now3.json" || fail "N2: Send now of the sample: $(tail -3 "$WORK/now3.json")"
SAMPID=$(python3 -c 'import json,sys; print(" ".join(str(v) for v in json.load(open(sys.argv[1])).values()))' "$WORK/now3.json")
[[ $(wc -w <<<"$SAMPID") == 1 ]] || fail "N2: the sample's send: $(cat "$WORK/now3.json")"
waitsent $SAMPID || fail "N2: the sample's mail not answered in 3 minutes"
python3 - "$WORK/sink" "$SAMPID" "$SMARK" <<'PY' || fail "N2: see above"
import email, glob, html, io, os, re, sys, zipfile
from email import policy
sink, sid, mark = sys.argv[1], int(sys.argv[2]), sys.argv[3]
m = next((email.message_from_binary_file(open(f, 'rb'), policy=policy.default) for f in sorted(glob.glob(os.path.join(sink, '*.eml')))
          if email.message_from_binary_file(open(f, 'rb'), policy=policy.default)['X-Pgvigil-Report'] == str(sid)), None)
assert m is not None, f"N2: mail {sid} is not in the sink"
body = html.unescape(m.get_body(('html',)).get_content())
# the mark on exactly the panel's two grids (its parameters and its sample), each line right above its table
assert body.count(mark) == 2 and all(body.find('<table', i) - i < 400 for i in [k.start() for k in re.finditer(re.escape(mark), body)]), f"N2: the mail's body carries the mark {body.count(mark)} times (2 wanted, each above its grid)"
xl = next(p for p in m.iter_attachments() if (p.get_filename() or '').endswith('.xlsx'))
z = zipfile.ZipFile(io.BytesIO(xl.get_content()))
xml = z.read('xl/worksheets/sheet1.xml').decode()   # the Summary sheet writes its text inline
rows = {}
for r, b in re.findall(r'<row r="(\d+)"[^>]*>(.*?)</row>', xml):
    cells = {c: html.unescape(re.sub(r'<[^>]+>', '', t)) for c, t in re.findall(r'<c r="([A-Z]+)\d+"[^>]*>(.*?)</c>', b)}
    if int(r) >= 12 and cells.get('A'): rows[cells['A']] = cells.get('C', '')
bad = [n for n, note in rows.items() if (mark in note) != n.startswith('sp_Blitz')]
assert rows and not bad and sum(1 for n in rows if n.startswith('sp_Blitz')) == 2, f"N2: the mail's workbook's Summary: {rows} (wrong: {bad})"
print(f"ok   N2: mail {sid}: the sample of sp_Blitz on a demo instance mailed with Send now; the mark above exactly the panel's 2 grids in the body and on exactly their 2 sheets in the workbook's Summary ({mark[:60]}...)")
PY
NOWIDS="$NOWIDS $SAMPID"   # graded by C, H and X with the others (the one mail that carries a kit's stored words)

# ---- S: schedules, brought due, rendered by two serves -------------------------------------------------------------------
JOBS="#/jobs?from=$FROM&to=$TO"
drive prefs "$WORK" - "$JOBS" > "$WORK/prefs.json" || fail "S: the schedule dialog: $(tail -3 "$WORK/prefs.json")"
SJOB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schedule_id"])' "$WORK/prefs.json")
HIDDEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hidden"])' "$WORK/prefs.json")
[[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["note"])' "$WORK/prefs.json") == *"grid choices in this browser (1 grid"* ]] || fail "S: the dialog's note: $(cat "$WORK/prefs.json")"
[[ $(q "select count(*) from pgvigil.report_mail_schedules where schedule_id = $SJOB and route = '$JOBS' and grid_prefs is not null and (select count(*) from jsonb_object_keys(grid_prefs)) = 1") == 1 ]] || fail "S: the dialog's schedule: $(q "select route, grid_prefs from pgvigil.report_mail_schedules where schedule_id = $SJOB")"
ok "S: column '$HIDDEN' hidden on the Jobs page with the grid's menu; Mail... > Schedule this page... added schedule $SJOB with that grid's choice"
SIDS=""
for i in 0 1 2; do
  r=${ROUTES[$i]}; tz=UTC; [[ $i == 2 ]] && tz=America/Los_Angeles
  [[ $(postj reportmail "{\"op\":\"add\",\"name\":\"Proof schedule $i\",\"route\":\"$r\",\"page\":\"page $i\",\"recipients\":[\"sched-$i@pgvigil.test\"],\"channel\":\"mail\",\"cadence\":\"daily\",\"at\":\"07:00\",\"timezone\":\"$tz\"}") == 200 ]] || fail "S: add $i: $(cat "$WORK/body")"
  SIDS="$SIDS $(jget "d['schedule_id']")"
done
read -r S0 S1 SLA <<<"${SIDS# }"
NEXT7=$(python3 -c 'import datetime as d; n=d.datetime.now(d.timezone.utc); t=n.replace(hour=7,minute=0,second=0,microsecond=0); t = t if t > n else t + d.timedelta(days=1); print(t.strftime("%Y-%m-%d %H:%M:%S+00"))')
NEXT7LA=$(python3 -c 'import datetime as d, zoneinfo as z; la=z.ZoneInfo("America/Los_Angeles"); n=d.datetime.now(la); t=n.replace(hour=7,minute=0,second=0,microsecond=0); t = t if t > n else (n + d.timedelta(days=1)).replace(hour=7,minute=0,second=0,microsecond=0); print(t.astimezone(d.timezone.utc).strftime("%Y-%m-%d %H:%M:%S+00"))')
SL="$S0,$S1,$SLA,$SJOB"
nextok() { [[ $(q "select count(*) from pgvigil.report_mail_schedules where schedule_id in ($S0, $S1, $SJOB) and next_at = '$NEXT7' and cron = '0 7 * * *'$1") == 3 && $(q "select count(*) from pgvigil.report_mail_schedules where schedule_id = $SLA and next_at = '$NEXT7LA' and cron = '0 7 * * *'$1") == 1 ]]; }
nextok "" || fail "S: next_at $(q "select schedule_id, timezone, next_at, cron from pgvigil.report_mail_schedules where schedule_id in ($SL)") (want $NEXT7 UTC, $NEXT7LA for Los Angeles)"
# the fifth: the second user's schedule, the user disabled before its turn
[[ $(code -b "$JAR2" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"op\":\"add\",\"name\":\"Proof gone owner\",\"route\":\"${ROUTES[0]}\",\"recipients\":[\"gone@pgvigil.test\"],\"channel\":\"mail\",\"cadence\":\"weekly\",\"at\":\"06:30\",\"days\":[1,3],\"timezone\":\"America/Los_Angeles\"}" "$U/api/reportmail") == 200 ]] || fail "S: the second user's schedule: $(cat "$WORK/body")"
GONE=$(jget "d['schedule_id']")
[[ $(q "select cron from pgvigil.report_mail_schedules where schedule_id = $GONE") == "30 6 * * 1,3" ]] || fail "S: the weekly line: $(q "select cron from pgvigil.report_mail_schedules where schedule_id = $GONE")"
"$BIN" user disable -config "$CFG" $U2USER >/dev/null 2>&1 || fail "user disable"
DUE=$(q "update pgvigil.report_mail_schedules set next_at = now() - interval '1 second' where schedule_id in ($SL, $GONE) returning to_char(now() at time zone 'UTC', 'HH24:MI:SS')" | head -1)
echo "     the five schedules brought due at $DUE UTC (the proof's hand on next_at); two serves with the login claim them"
# another server's claim, taken over while the first claim's page is drawn: that render's turn must be refused (it is
# no longer the claim's) and the turn mailed once, by the claim's holder after its lease (60 s)
STOLEN=""
for _ in $(seq 1 600); do
  STOLEN=$(psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "update pgvigil.report_mail_schedules s set claim_token = 'proof-stolen', claimed_until = now() + interval '60 seconds'
               where s.schedule_id = (select x.schedule_id from pgvigil.report_mail_schedules x where x.schedule_id in ($SL) and x.claimed_until is not null
                                         and x.claim_token <> 'proof-stolen' and not exists (select 1 from pgvigil.report_mail_sends m where m.schedule_id = x.schedule_id and m.kind = 'scheduled') limit 1)
              returning s.schedule_id" | head -1)   # -q: no 'UPDATE n' tag, only the id
  [[ $STOLEN =~ ^[0-9]+$ ]] && break
  STOLEN=""
  sleep 0.2
done
[[ -n $STOLEN ]] || fail "S: no serve claimed a turn in 2 minutes: $(grep -i 'report mail' "$WORK/serve.log" "$WORK/serve3.log" | tail -4)"
# the screens each scheduled mail is graded against: read while the turns are drawn and again after: a cell is the
# window's when it equals either read (a time counted from now may move one minute between)
SCREENS=("${ROUTES[0]}" "${ROUTES[1]}" "America/Los_Angeles^${ROUTES[2]}" "$JOBS")
drive screen "$WORK" sa "${SCREENS[@]}" > /dev/null || fail "S: the driver's read before the renders"
live() { q "select count(*) from pgvigil.report_mail_sends where schedule_id in ($SL, $GONE) and kind = 'scheduled' and outcome is distinct from 'refused'"; }
got=0
for _ in $(seq 1 120); do
  got=$(live); [[ $got == 5 ]] && break
  sleep 2
done
drive screen "$WORK" sb "${SCREENS[@]}" > /dev/null || fail "S: the driver's read after the renders"
[[ $got == 5 ]] || fail "S: $got of 5 turns queued in 4 minutes; serve said: $(grep -i 'report mail' "$WORK/serve.log" "$WORK/serve3.log" | tail -6)"
SCHIDS=$(q "select string_agg(send_id::text, ' ' order by schedule_id) from pgvigil.report_mail_sends where schedule_id in ($SL) and kind = 'scheduled' and outcome is distinct from 'refused'")
GONEID=$(q "select send_id from pgvigil.report_mail_sends where schedule_id = $GONE and kind = 'scheduled'")
waitsent $SCHIDS $GONEID || fail "S: the turns not answered: $(q "select send_id, coalesce(outcome, 'queued'), error from pgvigil.report_mail_sends where schedule_id in ($SL, $GONE)")"
[[ $(q "select count(*) from pgvigil.report_mail_sends where send_id in ($(tr ' ' ',' <<<"$SCHIDS")) and outcome = 'sent' and requested_by = '$UIUSER'") == 4 ]] || fail "S: $(q "select send_id, outcome, error from pgvigil.report_mail_sends where send_id in ($(tr ' ' ',' <<<"$SCHIDS"))")"
[[ $(q "select count(*) from pgvigil.report_mail_sends where schedule_id = $STOLEN and kind = 'scheduled' and outcome = 'refused' and error like '%no longer this server%'") == 1 ]] || fail "S: the taken-over turn of schedule $STOLEN: $(q "select send_id, outcome, error from pgvigil.report_mail_sends where schedule_id = $STOLEN")"
[[ $(q "select max(n) from (select count(*) n from pgvigil.report_mail_sends where schedule_id in ($SL, $GONE) and kind = 'scheduled' and outcome is distinct from 'refused' group by schedule_id) x") == 1 ]] || fail "S: a turn mailed twice: $(q "select schedule_id, count(*) from pgvigil.report_mail_sends where kind = 'scheduled' group by 1")"
nextok " and claimed_until is null and claim_token is null" || fail "S: the turns did not move on: $(q "select schedule_id, next_at, claimed_until, claim_token from pgvigil.report_mail_schedules where schedule_id in ($SL)")"
Q1=$(grep -c "report mail: queued" "$WORK/serve.log" || true); Q3=$(grep -c "report mail: queued" "$WORK/serve3.log" || true)
ok "S: four schedules rendered headless as $UIUSER by the two serves ($Q1 and $Q3 turns) and mailed once each (mails $SCHIDS); schedule $STOLEN's stale turn refused and mailed after the lease; next_at back at $NEXT7 (UTC) and $NEXT7LA (Los Angeles), no lease left"

# ---- T: Send test ----------------------------------------------------------------------------------------------------------
[[ $(postj reportmail/test "{\"schedule_id\":$S1}") == 200 ]] || fail "T: $(cat "$WORK/body")"
[[ $(postj reportmail/test "{\"schedule_id\":$S1}") == 409 ]] && grep -q 'one at a time' "$WORK/body" || fail "T: a second test at once: $(cat "$WORK/body")"
TESTID=""
for _ in $(seq 1 60); do TESTID=$(q "select send_id from pgvigil.report_mail_sends where schedule_id = $S1 and kind = 'test'"); [[ -n $TESTID ]] && break; sleep 2; done
[[ -n $TESTID ]] || fail "T: the test was not queued: $(grep -i 'report mail' "$WORK/serve.log" | tail -3)"
waitsent "$TESTID" || fail "T: the test not answered"
[[ $(q "select outcome = 'sent' and subject like '[test] Proof schedule 1 - %' and requested_by = '$UIUSER' from pgvigil.report_mail_sends where send_id = $TESTID") == t ]] || fail "T: $(q "select outcome, subject, error from pgvigil.report_mail_sends where send_id = $TESTID")"
ok "T: Send test drew schedule $S1's page as $UIUSER and mailed it (mail $TESTID, [test] in its subject); a second test at once refused (one at a time)"

# ---- F: failures alerted ------------------------------------------------------------------------------------------------
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $GONEID") == failed ]] || fail "F: the disabled owner's turn: $(q "select outcome, error from pgvigil.report_mail_sends where send_id = $GONEID")"
[[ $(q "select error from pgvigil.report_mail_sends where send_id = $GONEID") == *"can no longer sign in"* ]] || fail "F: its error: $(q "select error from pgvigil.report_mail_sends where send_id = $GONEID")"
[[ $(q "select next_at > now() from pgvigil.report_mail_schedules where schedule_id = $GONE") == t ]] || fail "F: the failed turn did not move on"
FIRST=$(ls "$WORK/sink"/*.eml | head -1)
python3 - "$FIRST" "$WORK/bad.json" <<'PY'
import base64, email, json, sys
from email import policy
m = email.message_from_binary_file(open(sys.argv[1], 'rb'), policy=policy.default)
html = next(p for p in m.walk() if p.get_content_type() == 'text/html').get_content()
x = next(p for p in m.walk() if p.get_content_type().endswith('spreadsheetml.sheet')).get_payload(decode=True)
json.dump({'name': 'Proof bad relay', 'route': '#/summary', 'recipients': ['bad@pgvigil.test'], 'channel': 'badmail', 'subject': 'pgvigil: bad relay',
           'html': html, 'xlsx': base64.b64encode(x).decode(), 'xlsx_name': 'bad.xlsx', 'grids': 1, 'rows': 1}, open(sys.argv[2], 'w'))
PY
[[ $(postj reportmail/send "@$WORK/bad.json") == 200 ]] || fail "F: the bad relay's send was not queued: $(cat "$WORK/body")"
BADID=$(jget "d['send_id']")
waitsent "$BADID" || fail "F: the bad relay's send not answered"
[[ $(q "select outcome from pgvigil.report_mail_sends where send_id = $BADID") == failed ]] || fail "F: the bad relay: $(q "select outcome, error from pgvigil.report_mail_sends where send_id = $BADID")"
BADERR=$(q "select error from pgvigil.report_mail_sends where send_id = $BADID")
[[ $BADERR == *"connection refused"* || $BADERR == *"connect"* ]] || fail "F: the bad relay's error: $BADERR"
for id in "$BADID" "$GONEID"; do
  grep -l '"setting": "report mail failed"' "$WORK/drop"/*.json 2>/dev/null | xargs -r grep -l "mail $id to" | grep -q . || fail "F: no 'report mail failed' notice for mail $id in the file drop: $(ls "$WORK/drop" | tail -3)"
  grep -l "report mail failed" "$WORK/sink"/*.eml 2>/dev/null | xargs -r grep -l "mail $id to" | grep -q . || fail "F: no notice for mail $id in the sink (the mail channel)"
done
ok "F: the bad relay answered failed ($BADERR); the disabled owner's turn failed (can no longer sign in) and moved on; each alerted to the file drop and the mail channel"

# ---- C, H, X: every mail against its screen -----------------------------------------------------------------------------
q "select json_agg(json_build_object('id', send_id, 'kind', kind, 'route', route, 'subject', subject, 'name', name, 'to', recipients, 'schedule', schedule_id)) from pgvigil.report_mail_sends where send_id in ($(tr ' ' ',' <<<"$NOWIDS $SCHIDS $TESTID"))" > "$WORK/sends.json"
python3 - "$WORK" "$SJOB" "$HIDDEN" "$SLA" <<'PY' || fail "C/H/X: the mails differ from the window (above)"
import email, glob, html as H, io, json, os, re, sys
from email import policy
from html.parser import HTMLParser
import openpyxl
W, SJOB, HIDDEN, SLA = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
FILL = {'ok': ('#006638', '#ffffff'), 'warn': ('#e49325', '#1d1300'), 'crit': ('#ab1f26', '#ffffff'), 'none': ('#e0e1e9', '#004f83'), 'ack': ('#1b6aa3', '#ffffff')}
LINK = ('#f1f1f6', '#004f83')
ALLOWED = {'html', 'head', 'meta', 'title', 'body', 'h2', 'h3', 'p', 'table', 'thead', 'tbody', 'tr', 'th', 'td'}
sends = {s['id']: s for s in json.load(open(os.path.join(W, 'sends.json')))}
from urllib.parse import parse_qsl
def norm(route):
    path, _, qs = route.partition('?')
    return path + '?' + '&'.join(f'{k}={v}' for k, v in sorted(parse_qsl(qs)))
screens = {}
for f in glob.glob(os.path.join(W, 'screen-*.json')):
    d = json.load(open(f)); screens.setdefault(norm(d['route']), {})[os.path.basename(f).split('-')[1]] = d['screen']
mails = {}
for f in sorted(glob.glob(os.path.join(W, 'sink', '*.eml'))):
    m = email.message_from_binary_file(open(f, 'rb'), policy=policy.default)
    if m['X-Pgvigil-Report']:
        mails[int(m['X-Pgvigil-Report'])] = m
class P(HTMLParser):
    def __init__(s):
        super().__init__(convert_charrefs=True); s.tags = set(); s.bad = []; s.grids = []; s.h3 = None; s.cur = None; s.cell = None; s.unstyled = 0; s.inh3 = False; s.skip = False
    def handle_starttag(s, t, a):
        a = dict(a); s.tags.add(t)
        if 'class' in a: s.bad.append('class=' + a['class'])
        for k, v in a.items():
            if k.startswith('on'): s.bad.append(k)
            if v and 'javascript:' in v.lower(): s.bad.append('javascript:')
        if t == 'h3': s.inh3 = True; s.h3 = ''
        if t == 'table':
            s.skip = a.get('role') == 'presentation'
            if not s.skip: s.cur = {'name': s.h3, 'head': [], 'rows': []}
        if t == 'tr' and s.cur is not None and not s.skip: s.row = []
        if t in ('th', 'td'):
            if 'style' not in a: s.unstyled += 1
            st = a.get('style', '')
            bg = re.search(r'background:(#[0-9a-f]{6})', st); fg = re.search(r'(?<![-\w])color:(#[0-9a-f]{6})', st)
            s.cell = {'t': '', 'bg': bg and bg.group(1), 'fg': fg and fg.group(1), 'th': t == 'th', 'bold': 'font-weight:bold' in st}
    def handle_endtag(s, t):
        if t == 'h3': s.inh3 = False
        if t in ('th', 'td') and s.cell is not None and s.cur is not None and not s.skip:
            s.cell['t'] = re.sub(r'\s+', ' ', s.cell['t']).strip(); s.row.append(s.cell)
        if t in ('th', 'td'): s.cell = None
        if t == 'tr' and s.cur is not None and not s.skip:
            if s.row and all(c['th'] for c in s.row) and not s.cur['head']: s.cur['head'] = s.row
            else: s.cur['rows'].append(s.row)
        if t == 'table':
            if s.cur is not None and not s.skip: s.grids.append(s.cur)
            s.cur = None; s.skip = False
    def handle_data(s, d):
        if s.inh3: s.h3 += d
        if s.cell is not None: s.cell['t'] += d
problems = []; total = 0
for sid, s in sorted(sends.items()):
    m = mails.get(sid)
    if m is None: problems.append(f'mail {sid}: not in the sink'); continue
    pair = ('now', 'nowb') if s['kind'] == 'now' else ('sa', 'sb')
    reads = [screens.get(norm(s['route']), {}).get(k) for k in pair]
    if None in reads: problems.append(f'mail {sid}: no screens of {s["route"]} ({sorted(screens.get(norm(s["route"]), {}))})'); continue
    scr, alt_scr = reads
    to = m['To']
    if to != ', '.join(s['to']): problems.append(f'mail {sid}: To {to!r}')
    subj = str(m['Subject'])
    if s['kind'] == 'scheduled' and not subj.startswith(s['name'] + ' - '): problems.append(f'mail {sid}: subject {subj!r}')
    if s['kind'] == 'test' and not subj.startswith('[test] ' + s['name'] + ' - '): problems.append(f'mail {sid}: subject {subj!r}')
    if s['kind'] == 'now' and not subj.startswith('pgvigil: '): problems.append(f'mail {sid}: subject {subj!r}')
    alt = [p for p in m.walk() if p.get_content_type() == 'multipart/alternative']
    htmls = [p for p in m.walk() if p.get_content_type() == 'text/html']; plains = [p for p in m.walk() if p.get_content_type() == 'text/plain']
    if len(alt) != 1 or len(htmls) != 1 or len(plains) != 1 or htmls[0]['Content-Transfer-Encoding'] != 'base64':
        problems.append(f'mail {sid}: the parts ({[p.get_content_type() for p in m.walk()]})'); continue
    body = htmls[0].get_content()
    p = P(); p.feed(body)
    if p.tags - ALLOWED: problems.append(f'mail {sid}: tags {sorted(p.tags - ALLOWED)}')
    if p.bad: problems.append(f'mail {sid}: {p.bad[:3]}')
    if p.unstyled: problems.append(f'mail {sid}: {p.unstyled} cells without a style')
    if re.search(r'<\s*(script|style)\b', body, re.I): problems.append(f'mail {sid}: a script or style element')
    book = [g for g in scr]   # every grid of the page in order, the empty ones too: the workbook's sheets
    grids = [g for g in scr if not g.get('empty')]   # the grids with rows: the mail's body
    zone = re.search(r'>Time zone</th><td[^>]*>([^<]*)<', body)
    if s['schedule'] == SLA and s['kind'] == 'scheduled' and not (zone and zone.group(1).startswith('America/Los_Angeles')): problems.append(f'mail {sid}: the Los Angeles schedule\'s time zone line {zone and zone.group(1)!r}')
    if s['schedule'] == SJOB and (not p.grids or HIDDEN in [c['t'] for c in p.grids[0]['head']]): problems.append(f'mail {sid}: the column {HIDDEN!r} the owner hid is in the mail')
    if [g['name'] for g in p.grids] != [g['named'] for g in grids]:
        problems.append(f'mail {sid}: grids {[g["name"] for g in p.grids]} vs the screen {[g["named"] for g in grids]}'); continue
    cells = coloured = moved = 0
    alts = [g for g in alt_scr if not g.get('empty')]
    for g, sg, ag in zip(p.grids, grids, alts if len(alts) == len(grids) else grids):
        if [c['t'] for c in g['head']] != sg['head']: problems.append(f'mail {sid} {sg["named"]}: head {[c["t"] for c in g["head"]]} vs {sg["head"]}')
        for c in g['head']:
            if (c['bg'], c['fg'], c['bold']) != ('#0063a3', '#ffffff', True): problems.append(f'mail {sid} {sg["named"]}: a header cell {c}'); break
        if len(g['rows']) not in (sg['rows'], ag['rows']): problems.append(f'mail {sid} {sg["named"]}: {len(g["rows"])} rows vs {sg["rows"]} on the screen')
        for i, (mr, sr, ar) in enumerate(zip(g['rows'], sg['cells'], ag['cells'] + [None] * max(0, len(sg['cells']) - len(ag['cells'])))):
            if ar is not None and len(ar) == len(sr) and any(mc['t'] != sc['t'] and mc['t'] == ac['t'] for mc, sc, ac in zip(mr, sr, ar)):
                sr = [ac if mc['t'] == ac['t'] and mc['t'] != sc['t'] else sc for mc, sc, ac in zip(mr, sr, ar)]
                moved += 1
            if len(mr) != len(sr): problems.append(f'mail {sid} {sg["named"]} row {i}: {len(mr)} cells vs {len(sr)}'); continue
            row_st = {c['s'] for c in sr if c['s']}
            for j, (mc, sc) in enumerate(zip(mr, sr)):
                cells += 1
                if mc['t'] != sc['t']: problems.append(f'mail {sid} {sg["named"]} [{i},{j}]: {mc["t"]!r} vs {sc["t"]!r}')
                got = (mc['bg'], mc['fg'])
                if sc['s']:
                    coloured += 1
                    if got != FILL[sc['s']]: problems.append(f'mail {sid} {sg["named"]} [{i},{j}] {sc["t"]!r}: {got} vs {sc["s"]} {FILL[sc["s"]]}')
                elif sc['l']:
                    if got != LINK: problems.append(f'mail {sid} {sg["named"]} [{i},{j}] {sc["t"]!r}: {got} vs a link {LINK}')
                elif got != (None, None):
                    carried = [k for k in row_st if FILL[k] == got]
                    if not carried or not mc['t']: problems.append(f'mail {sid} {sg["named"]} [{i},{j}] {sc["t"]!r}: {got} on a plain cell')
                    else: coloured += 1
    x = [p for p in m.walk() if p.get_content_type().endswith('spreadsheetml.sheet')]
    if len(x) != 1: problems.append(f'mail {sid}: {len(x)} workbooks'); continue
    wb = openpyxl.load_workbook(io.BytesIO(x[0].get_payload(decode=True)))
    # P03: the workbook is Export .xlsx's: the Summary sheet, then a sheet per grid of the page in order, an empty grid's
    # its header row alone (its columns, no data row)
    if wb.sheetnames[0] != 'Summary' or len(wb.sheetnames) != 1 + len(book): problems.append(f'mail {sid}: sheets {wb.sheetnames} vs 1 + {len(book)} grids of the page ({sum(1 for g in book if g.get("empty"))} empty)')
    else:
        body = iter(p.grids)
        for ws, g in zip(wb.worksheets[1:], book):
            n = sum(1 for r in ws.iter_rows(min_row=2) if any(c.value is not None for c in r))
            if g.get('empty'):
                hd = [c.value for c in next(ws.iter_rows(min_row=1, max_row=1))] if ws.max_row >= 1 else []
                if n or [str(v) for v in hd if v is not None] != g['head']: problems.append(f'mail {sid} {g["named"]}: the empty grid\'s sheet {ws.title}: {n} rows, header {hd} vs {g["head"]}')
                continue
            mg = next(body, None)
            if mg is not None and n != len(mg['rows']) and len(mg['rows']): problems.append(f'mail {sid} {mg["name"]}: the sheet {ws.title} has {n} rows, the mail {len(mg["rows"])}')
    total += cells
    print(f'ok   C: mail {sid} ({s["kind"]}, {s["route"].split("?")[0]}): {len(p.grids)} grids, {cells} cells equal to the screen ({moved} rows matched the second read), {coloured} of them coloured; the workbook opens ({len(wb.sheetnames)} sheets, {sum(1 for g in book if g.get("empty"))} of an empty grid)')
for x in problems[:40]: print('     ' + x)
if problems: print(f'{len(problems)} problems'); sys.exit(1)
print(f'ok   H: every mail tables and inline styles only, no script, style, class or event attribute; X: every workbook opens with openpyxl; {total} cells in all')
PY

# ---- P: the Report mail page ------------------------------------------------------------------------------------------
drive page "$WORK" - > "$WORK/page.json" || fail "P: the driver: $(cat "$WORK/page.json")"
python3 - "$WORK/page.json" <<'PY' || fail "P: the Report mail page (above)"
import json, sys
d = json.load(open(sys.argv[1]))
g = {x['named']: x for x in d['screen'] if not x.get('empty')}   # an empty grid's note is no table of the page
sch, snd = g.get('Schedules'), next((v for k, v in g.items() if k.startswith('Sends')), None)
bad = []
if not sch or sch['rows'] != 5: bad.append(f'Schedules: {sch and sch["rows"]} rows, want 5')
if not snd or not any(c['t'] == 'sent' for r in snd['cells'] for c in r) or not any(c['t'] == 'failed' and c['s'] == 'crit' for r in snd['cells'] for c in r): bad.append('Sends: no sent and failed (crit) outcome')
if d['unlabelled'] or d['fields'] < 10: bad.append(f'the New schedule dialog: {d["fields"]} fields, unlabelled {d["unlabelled"]}')
if not d['closed']: bad.append('the dialog did not close on Escape')
print('\n'.join('     ' + b for b in bad)) if bad else print(f'ok   P: Schedules 5 rows, Sends with sent and failed, the New schedule dialog {d["fields"]} fields all labelled, Escape closes it')
sys.exit(1 if bad else 0)
PY
echo "== the machine's load at the end: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown) (at the start: $LOAD)"
echo "PROOF OK"
