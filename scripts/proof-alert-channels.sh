#!/usr/bin/env bash
# Proof of task 403b (internal/alerts webhook.go / alerts.go, migration 0154's alert_channel_failing, internal/web
# q_alert_scope.go's part alerts, internal/mcp tools_alerts.go): a 429's Retry-After, 'alert channel failing' and the
# MCP tool alert_history, on a throwaway repository. Nothing leaves the machine: the webhooks post to a sink on
# loopback, the file channel writes into the proof's own folder. Part L alone (PGVIGIL_PROOF_PART=L) posts to a real
# destination; see below.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 14+ cluster as a superuser. The proof makes one repository
#                      database and two logins, all named pgvigil_s2chan_*_<random>, and drops them at the end. Not
#                      dropped: the cluster-wide group roles `pgvigil migrate` makes.
#   The proof builds BIN from a copy of this tree (go build) with scripts/proof-alert-scope-wiring.patch applied (the
#   lead's lines in 0190, web.go, q_alert_rules.go, tools.go; skipped when the tree already holds them).
#   Needs: psql, curl, python3, ss, go, tar, git (git apply only).
#
# Expected (written before the first run; red first: on 5e53c86 the build has no alert_channel_failing, part M fails):
#  M. a fresh store migrated by BIN: alert_findings' definition reads alert_channel_findings (the wiring's third arm:
#     alert_channel_failing and B24k's alert_channel_quota_low);
#     the index alert_log_channel_at_idx stands; alert_channel_failing answers. The alerter login may read it through
#     alert_findings (a pass runs as that login below).
#  C. 'alert channel failing' (Fixed 21 / 27). Channels: hook2 (webhook to the sink's /c, floor warning), drop (file,
#     floor warning, clear_after 0), hook (webhook to /r, floor critical). The sink answers /c with 500. One Send test of
#     hook2 per pass (a test is an attempt like any send; the tests' 2-minute gap is met by asking each at its own past
#     minute):
#     - while alert_log holds fewer than 3 failed attempts in a row for hook2: drop holds no 'alert channel failing';
#     - the pass after the third: drop gets ONE firing file of it - value hook2, severity warning, source 'pgvigil
#       repository', detail 'alert channel failing: webhook to http://127.0.0.1:<port> (json), the last 3 sends failed,
#       ...; last error: ... 500 ...';
#     - hook2 never gets its own: no sink body on /c names 'alert channel failing', no alert_state row of hook2 for it;
#     - hook (floor critical) gets none either (K3 at warning: a critical-only channel is not told; the lead's 23:4x);
#     - a further pass: no second firing file on drop;
#     - the sink answers 200, one more test: its alert_log row is 'test'; the pass after it: drop gets ONE 'resolved'
#       file of it (the recovery), and alert_channel_failing holds no hook2 row.
#  R. Retry-After (Fixed 28), Send tests of hook through the changed sender; per row the sink's requests that carry the
#     test message, and hook's newest alert_log row:
#     - R1 429 'Retry-After: 2', then 200: 2 requests, the second at least 2 s after the first, the same body; 'test';
#     - R2 429 'Retry-After: 30': 1 request; 'failed', the error saying 'more than the 10s a send waits';
#     - R3 429 'Retry-After: 1' twice: 2 requests; 'failed', 'after waiting out a Retry-After of 1s';
#     - R4 429 with no Retry-After: 1 request; 'failed', 'no Retry-After';
#     - R5 500, then 200: 1 request (a 500 is not retried); 'failed'.
#     No error text names the URL's path (/r/token-...).
#  P. alert_history (Added 20). Seeded: instances A and B; B with 1,001 alerts fired in the last hour, A with 2 and one
#     more fired 100 days ago and cleared 99 days ago. Through serve (the UI login):
#     - GET /api/alertscope?part=alerts&instance_id=A over 90 days: 2 rows, cut false;
#     - the same for B: 1,000 rows, cut true (filtered by the instance before the limit);
#     - part=alerts without instance_id: 400 'part alerts needs instance_id'.
#     Through `pgvigil mcp` (the reader login): tools/list names alert_history; tools/call {instance A, hours 2160}: 2
#     alerts (not the 100-day-old one) and a findings_history list; {hours 2161}: an error result naming 1..2160;
#     {from, to 91 days apart}: an error naming 90 days.
#  L. (PGVIGIL_PROOF_PART=L only, on the laptop, the lead's 22:0x rules: F3 (a)) one Send test through the changed
#     webhook sender to the lab's real Slack incoming webhook. PGVIGIL_BIN is a binary cross-built on the lab box and
#     fetched (no build here), PGVIGIL_ADMIN_DSN the lab box's PostgreSQL through a tunnel, PGV_LIVE_SLACK the webhook
#     URL put in the environment by the runner, which reads it from its secrets file (never a command line, a file or
#     a log). MemAvailable at least 4 GB is read first. The channel's quiet hours cover the day (a test is sent inside
#     them, a finding is not) and its checks: list names no check, so nothing but the test reaches Slack. Expected:
#     slack-live's alert_log holds one row, outcome 'test'; no 'sent', 'failed' or 'refused' row. The message reads
#     'a test message on channel slack-live ... nothing is wrong'.
#  O. (B24k) Pushover through real passes against a loopback stub of api.pushover.net's documented answers (NOT PROVEN
#     LIVE: no Pushover account). A channel po (floor critical, the seeded instance) and a rule finding (critical) per row:
#     - O1 the stub answers 200, status 1, 500 of 10,000 messages left: po's attempt 'sent'; the post carries the
#       token, the user key, priority 1 and the alert's line; alert_channel_quota holds 500 / 10000; the next pass:
#       drop gets ONE firing file 'pushover quota low', value po;
#     - O2 the stub answers 429 with X-Limit-App-Reset an hour ahead: 'failed', the error opening 'held until <that
#       time>: '; the next pass posts nothing to the stub and its summary says 'held by the destination: po:'; a Send
#       test (the stub back at 200) goes through ('test'), which ends the hold, so the same pass sends the owed alert
#       ('sent': a pass answers its tests before it reads the holds);
#     - O3 the stub answers 400: 'failed', 'held until the configuration changes ('; the next pass posts nothing; the
#       configuration given a device: the next pass posts again, with device proof1 ('sent').
#  U. (B24k) Azure Monitor Logs through a real pass against loopback stubs of the token endpoint and the ingestion URL
#     (NOT PROVEN LIVE: no Log Analytics workspace). A channel az (floor critical): a rule finding: 'sent'; the stub saw
#     one token request (grant_type client_credentials, scope https://monitor.azure.com//.default, the secret) and one
#     upload to /dataCollectionRules/<dcr>/streams/Custom-PgvigilAlerts?api-version=2023-01-01 with 'Bearer <the token>'
#     and a row whose FindingKey is the finding's; the stub answering 400 '{"error":{"code":"InvalidStream",...}}' to the
#     next finding: 'failed', the error holding 'InvalidStream'.
#  Z. (B24k) Zabbix LIVE in containers on this machine (docker; the images zabbix/zabbix-server-pgsql and
#     zabbix-web-nginx-pgsql alpine-7.0-latest and postgres:16-alpine, free): a server with certificate TLS (a CA,
#     its certificate, made here by openssl), three hosts made through its API - pgvigil-proof (a trapper item
#     pgvigil.alert, text), pgvigil-proof-tls (the same item; the host accepts a certificate only, its subject
#     CN=pgvigil-proof), pgvigil-proof-deny (its item's Allowed hosts 192.0.2.1) - and an API token. One critical rule
#     finding, one pass, five channels:
#     - zbx (sender, plain, loopback, host pgvigil-proof): 'sent';
#     - zbxtls (sender, certificate TLS, host pgvigil-proof-tls, tls_server_subject the server's): 'sent';
#     - zbxapi (api, history.push with the token, host pgvigil-proof): 'sent';
#     - zbxclear (sender, plain, host pgvigil-proof-tls): 'failed', 'processed 0 of 1';
#     - zbxdeny (sender, plain, host pgvigil-proof-deny): 'failed', 'processed 0 of 1'.
#     history.get reads back two values on pgvigil-proof's item and one on pgvigil-proof-tls's, each a JSON object with
#     the finding's key. Not graded: whether TLS opens the connection before the ZBXD header (a TLS send to a server
#     that answers only TLS succeeding is what is read). The containers, their network and volumes are removed after
#     and read back gone.
# Parts S, A and B (K2 the Slack bot channel, K4 the attachment, K5 the buttons) are added after their design pass.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
: "${PGVIGIL_ADMIN_DSN:?}"
PART=${PGVIGIL_PROOF_PART:-MCRPOUZ}
SUF=$RANDOM
REPO=pgvigil_s2chan_$SUF
ALR=pgvigil_s2chan_alr_$SUF; RDR=pgvigil_s2chan_rdr_$SUF
PW=p$RANDOM$RANDOM$RANDOM; UIUSER=proofuser; UIPW=ui$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""; SINK=""; VEND=""; ZCLEAN=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SINK" ]] && kill "$SINK" 2>/dev/null || true
  [[ -n "$VEND" ]] && kill "$VEND" 2>/dev/null || true
  if [[ -n "$ZCLEAN" ]]; then
    docker rm -f -v "$ZCLEAN-web" "$ZCLEAN-srv" "$ZCLEAN-db" >/dev/null 2>&1 || true
    docker network rm "$ZCLEAN" >/dev/null 2>&1 || true
  fi
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" \
    -c "drop role if exists $ALR" -c "drop role if exists $RDR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
dsn() { echo "$PGVIGIL_ADMIN_DSN dbname=$REPO user=$1 password=$PW"; }
newrepo() {
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null
  export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
  "$BIN" migrate -config "$CFG" >"$WORK/m.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/m.log")"
  q "create role $ALR login password '$PW' in role pgvigil_alerter" >/dev/null
  q "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null
  export PGV_PROOF_ALERTS_DSN; PGV_PROOF_ALERTS_DSN=$(dsn "$ALR")
}
# pass <tag>: one `pgvigil alerts` pass; a failed send exits non-zero and is graded from alert_log, not from the exit
pass() {
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$CFG" >"$WORK/pass.$tag.out" 2>"$WORK/pass.$tag.err"; rc=$?; set -e
  if grep -qE 'not read|not judged|not written' "$WORK/pass.$tag.out" || grep -qiE 'panic|SQLSTATE|ERROR:' "$WORK/pass.$tag.err"; then
    fail "pass $tag: exit $rc: $(cat "$WORK/pass.$tag.out") $(tr '\n' ' ' < "$WORK/pass.$tag.err" | cut -c1-600)"
  fi
}
# testreq <channel> <minutes ago>: one Send test request through the store's door, asked at that past minute
testreq() {
  local out
  out=$(q "select pgvigil.import_alert_test(now() - interval '$2 minutes', '{\"ui_user\":\"proof\",\"channel\":\"$1\"}'::jsonb)->>'detail'")
  [[ $(q "select outcome is null from pgvigil.alert_tests order by test_id desc limit 1") == t ]] || fail "the test of $1 was refused: $out"
}
# newest <channel>: the outcome and error of its newest Send test. A test's row counts no alert (alert_record counts
# firing, repeat and resolved items only); every alert send counts one at least, so the pass's alert sends after the
# test are skipped.
newest() { q "select outcome || '|' || coalesce(error, '') from pgvigil.alert_log where channel = '$1' and n_firing + n_repeat + n_resolved = 0 order by snapshot_at desc limit 1"; }

# ---- L: the real Slack incoming webhook (laptop only) -----------------------------------------------------------------
if [[ $PART == L ]]; then
  : "${PGVIGIL_BIN:?a binary cross-built on the lab box and fetched}"
  [[ -n ${PGV_LIVE_SLACK:-} ]] || fail "PGV_LIVE_SLACK is not set (the runner reads it from its secrets file)"
  avail=$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo)
  (( avail >= 4 )) || fail "MemAvailable ${avail} GB: under the 4 GB the lead's rule needs"
  for t in psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done
  BIN=$PGVIGIL_BIN
  CFG=$WORK/cfg-live.yaml
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: slack-live, kind: webhook, min_severity: critical, quiet_hours: "00:00-23:59", timezone: UTC, checks: [proof-none-$SUF], webhook: {url: env:PGV_LIVE_SLACK, format: slack}}
EOF
  newrepo
  pass L0
  [[ $(q "select count(*) from pgvigil.alert_log where channel = 'slack-live'") == 0 ]] || fail "L: pass 0 posted to Slack"
  testreq slack-live 1
  pass L1
  got=$(q "select string_agg(outcome, ',' order by snapshot_at) from pgvigil.alert_log where channel = 'slack-live'")
  [[ $got == test ]] || fail "L: slack-live's attempts: '$got' (wanted one 'test'): $(newest slack-live | cut -d'|' -f2 | cut -c1-300)"
  ok "L: one Send test through the changed webhook sender, answered by Slack's incoming webhook; nothing else posted"
  exit 0
fi

for t in psql curl python3 ss go tar git; do command -v $t >/dev/null || fail "$t is not on this machine"; done
# ---- the binary -------------------------------------------------------------------------------------------------------
TREE=$WORK/tree; mkdir -p "$TREE"
tar --exclude=./.git --exclude=./web/node_modules --exclude=./bin -cf - . | tar -xf - -C "$TREE"
if (cd "$TREE" && git apply --check "$ROOT/scripts/proof-alert-scope-wiring.patch" 2>/dev/null); then
  (cd "$TREE" && git apply "$ROOT/scripts/proof-alert-scope-wiring.patch") || fail "the wiring patch"
  ok "wiring patch applied to the build's copy"
elif (cd "$TREE" && git apply -R --check "$ROOT/scripts/proof-alert-scope-wiring.patch" 2>/dev/null); then
  ok "the tree already holds the wiring"
else
  fail "the wiring patch neither applies nor is applied"
fi
BIN=$WORK/pgvigil
(cd "$TREE" && go build -o "$BIN" ./cmd/pgvigil) || fail "go build"

# ---- the sink: loopback HTTP, per path queue (/r, /c) of answers, every request logged ---------------------------------
cat > "$WORK/sink.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
        qn = self.path.strip('/').split('/')[0]
        with open(os.path.join(work, 'sink.%s.log' % qn), 'a') as f:
            f.write(json.dumps({'t': time.time(), 'path': self.path, 'body': body}) + '\n')
        ans = ''
        qf = os.path.join(work, 'answers.%s' % qn)
        if os.path.exists(qf):
            lines = open(qf).read().splitlines()
            if lines:
                ans, rest = lines[0], lines[1:]
                open(qf, 'w').write(''.join(l + '\n' for l in rest))
        if not ans:
            df = os.path.join(work, 'default.%s' % qn)
            ans = open(df).read().strip() if os.path.exists(df) else '200'
        if ans.startswith('429:'):
            self.send_response(429)
            if ans[4:]:
                self.send_header('Retry-After', ans[4:])
        elif ans == '500':
            self.send_response(500)
        else:
            self.send_response(200)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'ok')
ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
SPORT=$(freeport)
python3 "$WORK/sink.py" "$WORK" "$SPORT" & SINK=$!
for n in $(seq 1 40); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$SPORT/x/ping" && break
  [[ $n == 40 ]] && fail "the sink did not answer"
  sleep 0.25
done
export PGV_PROOF_HOOK_R="http://127.0.0.1:$SPORT/r/token-$SUF" PGV_PROOF_HOOK_C="http://127.0.0.1:$SPORT/c/token-$SUF"
mkdir -p "$WORK/drop"
CFG=$WORK/cfg.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: hook, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_HOOK_R, format: json}}
  - {name: hook2, kind: webhook, min_severity: warning, clear_after: 0, webhook: {url: env:PGV_PROOF_HOOK_C, format: json}}
  - {name: drop, kind: file, min_severity: warning, clear_after: 0, file: {dir: $WORK/drop}}
EOF

# ---- M: the store ------------------------------------------------------------------------------------------------------
newrepo
[[ $(q "select pg_get_viewdef('pgvigil.alert_findings'::regclass)") == *alert_channel_findings* ]] || fail "M: alert_findings does not read alert_channel_findings (the wiring's third arm)"
[[ $(q "select pg_get_viewdef('pgvigil.alert_channel_findings'::regclass)") == *alert_channel_failing*alert_channel_quota_low* ]] || fail "M: alert_channel_findings is not the failing and quota views"
[[ $(q "select to_regclass('pgvigil.alert_log_channel_at_idx') is not null") == t ]] || fail "M: no index alert_log_channel_at_idx"
q "select count(*) from pgvigil.alert_channel_failing" >/dev/null || fail "M: alert_channel_failing does not answer"
[[ $(psql "$PGV_PROOF_ALERTS_DSN" -XAt -c "select count(*) >= 0 from pgvigil.alert_findings" 2>&1) == t ]] || fail "M: the alerter cannot read alert_findings"
ok "M: alert_findings reads alert_channel_findings; the index stands; the alerter reads it"

pass sync0   # records the channels (the Send test door needs them), the sink answers 200

# ---- C: 'alert channel failing' -----------------------------------------------------------------------------------------
if [[ $PART == *C* ]]; then
echo 500 > "$WORK/default.c"
streak() {   # failed or refused attempts of hook2 in a row, newest first
  q "select count(*) from (select outcome, sum((outcome not in ('failed', 'refused'))::int) over (order by snapshot_at desc) as okseen
       from pgvigil.alert_log where channel = 'hook2' and outcome in ('sent', 'failed', 'refused', 'test')) x where okseen = 0"
}
dropfiles() { grep -l '"alert channel failing"' "$WORK/drop"/* 2>/dev/null | xargs -r grep -l "\"$1\"" 2>/dev/null | xargs -r grep -l '"hook2"' 2>/dev/null | wc -l; }
reached=""
for k in 1 2 3 4 5 6; do
  testreq hook2 $((55 - 3 * k))
  pass "C$k"
  if [[ -z $reached ]] && (( $(streak) >= 3 )); then reached=$k; break; fi
  (( $(dropfiles firing) == 0 )) || fail "C: drop got 'alert channel failing' with only $(streak) failure(s) in a row"
done
[[ -n $reached ]] || fail "C: hook2 never reached 3 failures in a row: $(streak)"
(( $(dropfiles firing) == 0 )) || fail "C: drop got it in the same pass as the third failure (it is owed by the next)"
pass C-next
[[ $(dropfiles firing) == 1 ]] || fail "C: the pass after the third failure: $(dropfiles firing) firing file(s) on drop"
f=$(grep -l '"alert channel failing"' "$WORK/drop"/* | xargs grep -l '"firing"' | head -1)
python3 - "$f" "$SPORT" <<'PY' || fail "C: the firing file's fields: $(head -c 800 "$f")"
import json, sys
d = json.load(open(sys.argv[1]))
a = d['alerts'][0] if 'alerts' in d else d
det = a.get('detail', '')
assert a['value'] == 'hook2' and a['severity'] == 'warning' and a['source'] == 'pgvigil repository', a
assert det.startswith('alert channel failing: webhook to http://127.0.0.1:%s (json), the last 3 sends failed, the newest at ' % sys.argv[2]), det
assert '500' in det and 'token-' not in det, det
PY
! grep -q 'alert channel failing' "$WORK/sink.c.log" || fail "C: hook2 was sent its own failing alert"
[[ $(q "select count(*) from pgvigil.alert_state where setting = 'alert channel failing' and channel in ('hook', 'hook2')") == 0 ]] || fail "C: hook or hook2 holds an alert_state row of it"
pass C-again
[[ $(dropfiles firing) == 1 ]] || fail "C: a second firing file on drop"
echo 200 > "$WORK/default.c"
testreq hook2 2
pass C-ok
[[ $(newest hook2 | cut -d'|' -f1) == test ]] || fail "C: the recovering test: $(newest hook2)"
pass C-recover
[[ $(dropfiles resolved) == 1 ]] || fail "C: drop's recovery files: $(dropfiles resolved)"
[[ $(q "select count(*) from pgvigil.alert_channel_failing where value = 'hook2'") == 0 ]] || fail "C: hook2 still failing"
ok "C: after 3 failed attempts in a row drop is told once, hook2 and hook (floor critical) are not; the recovery once"
fi

# ---- R: Retry-After -----------------------------------------------------------------------------------------------------
if [[ $PART == *R* ]]; then
rreqs() { python3 - "$WORK/sink.r.log" "$1" <<'PY'
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1])]
except FileNotFoundError:
    rows = []
rows = [r for r in rows if 'test message' in r['body']][int(sys.argv[2]):]
gap = rows[1]['t'] - rows[0]['t'] if len(rows) > 1 else 0
same = len(rows) < 2 or rows[0]['body'] == rows[1]['body']
print('%d %.1f %s' % (len(rows), gap, same))
PY
}
seen=0
rrow() {     # rrow <name> <answers> <minutes ago> <requests> <outcome> <error words or ''> [<least gap s>]
  local got n gap same
  printf '%b' "$2" > "$WORK/answers.r"
  testreq hook "$3"
  pass "$1"
  read -r n gap same <<<"$(rreqs $seen)"
  got=$(newest hook)
  [[ $n == "$4" && $same == True ]] || fail "$1: $n request(s) (same body $same), wanted $4"
  [[ ${got%%|*} == "$5" ]] || fail "$1: outcome '$got', wanted $5"
  [[ -z $6 || $got == *"$6"* ]] || fail "$1: error '$got' does not say '$6'"
  [[ $got != *token-* ]] || fail "$1: the error names the URL's path: $got"
  [[ -z ${7:-} ]] || python3 -c "import sys; sys.exit(0 if float('$gap') >= $7 else 1)" || fail "$1: the retry came $gap s after the first post (wanted >= $7)"
  seen=$((seen + n))
}
rrow R1 '429:2\n200\n' 40 2 test '' 1.9
rrow R2 '429:30\n' 37 1 failed 'more than the 10s a send waits'
rrow R3 '429:1\n429:1\n' 34 2 failed 'after waiting out a Retry-After of 1s'
rrow R4 '429:\n' 31 1 failed 'no Retry-After'
rrow R5 '500\n200\n' 28 1 failed '500'
ok "R: a short Retry-After waited out and posted once more; a long, missing or second one, and a 500, fail that send"
fi

# ---- P: alert_history -----------------------------------------------------------------------------------------------------
if [[ $PART == *P* ]]; then
IA=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
        values ('proof-chan-a-$SUF', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | head -1)
IB=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
        values ('proof-chan-b-$SUF', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | head -1)
st() {   # st <instance id> <key prefix> <n> <fired SQL> <cleared SQL or NULL>
  q "insert into pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity,
       first_sent_at, last_sent_at, cleared_at)
     select 'drop', '$2' || g, $1, (select name from pgvigil.instances where instance_id = $1), 'proof', 'check ' || g, 'v',
            'warning', $4 + g * interval '1 second', $4 + g * interval '1 second', $5
       from generate_series(1, $3) g" >/dev/null
}
st "$IB" pb 1001 "now() - interval '1 hour'" NULL
st "$IA" pa 2 "now() - interval '30 minutes'" NULL
st "$IA" pold 1 "now() - interval '100 days'" "now() - interval '99 days'"
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" $UIUSER >/dev/null 2>&1 || fail "user add"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 &
SRV=$!
for n in $(seq 1 60); do
  curl -sf -o /dev/null "$U/" && break
  kill -0 "$SRV" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/serve.log")"
  [[ $n == 60 ]] && fail "serve did not answer"
  sleep 0.5
done
JAR=$WORK/jar
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
FROM=$(date -u -d '-90 days' +%FT%TZ); TO=$(date -u +%FT%TZ)
alerts() {   # alerts <instance id or ''>: 'code rows cut'
  local c
  c=$(curl -s -b "$JAR" -o "$WORK/a.json" -w '%{http_code}' "$U/api/alertscope?part=alerts&from=$FROM&to=$TO${1:+&instance_id=$1}")
  if [[ $c != 200 ]]; then echo "$c 0 -"; return; fi
  python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["alerts"]; c=t["columns"]; r=t["rows"]; print(sys.argv[2], len(r), any(x[c.index("cut")] for x in r))' "$WORK/a.json" "$c"
}
[[ $(alerts "$IA") == "200 2 False" ]] || fail "P: instance A's alerts: $(alerts "$IA")"
[[ $(alerts "$IB") == "200 1000 True" ]] || fail "P: instance B's alerts: $(alerts "$IB")"
[[ $(alerts "") == 400* ]] && grep -qF 'part alerts needs instance_id' "$WORK/a.json" || fail "P: part alerts without an instance: $(cat "$WORK/a.json")"
kill "$SRV" 2>/dev/null || true; SRV=""
mcpcall() {  # mcpcall <arguments json>: the tool's reply (the result's text, or 'ERROR <text>')
  local in=$WORK/mcp.in
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"proof-chan","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    echo "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"alert_history\",\"arguments\":$1}}"
  } > "$in"
  PGVIGIL_MCP_DSN="$(dsn "$RDR")" timeout 60 "$BIN" mcp <"$in" >"$WORK/mcp.out" 2>"$WORK/mcp.err" || true
  python3 - "$WORK/mcp.out" <<'PY'
import json, sys
got = {}
for l in open(sys.argv[1]):
    l = l.strip()
    if l:
        m = json.loads(l)
        got[m.get('id')] = m
names = [t['name'] for t in got.get(2, {}).get('result', {}).get('tools', [])]
if 'alert_history' not in names:
    print('NOTLISTED ' + ','.join(names)); sys.exit()
r = got.get(3, {})
if 'error' in r:
    print('ERROR ' + json.dumps(r['error'])); sys.exit()
res = r.get('result', {})
text = ''.join(c.get('text', '') for c in res.get('content', []))
print(('ERROR ' if res.get('isError') else '') + text.replace('\n', ' '))
PY
}
out=$(mcpcall "{\"instance\":\"proof-chan-a-$SUF\",\"hours\":2160}")
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["alerts"]) == 2, d["alerts"]
assert all(not r["finding_key"].startswith("pold") for r in d["alerts"]), d["alerts"]
assert isinstance(d.get("findings_history"), list), d
' "$out" || fail "P: alert_history of A over 2160 hours: $(echo "$out" | cut -c1-600)"
out=$(mcpcall "{\"instance\":\"proof-chan-a-$SUF\",\"hours\":2161}")
[[ $out == ERROR* && $out == *2160* ]] || fail "P: 2161 hours: $(echo "$out" | cut -c1-300)"
out=$(mcpcall "{\"instance\":\"proof-chan-a-$SUF\",\"from\":\"$(date -u -d '-91 days' +%FT%TZ)\",\"to\":\"$TO\"}")
[[ $out == ERROR* && $out == *"90 days"* ]] || fail "P: 91 days: $(echo "$out" | cut -c1-300)"
ok "P: the instance's alerts filtered before the limit; the MCP tool over 90 days and its bounds"
fi
# ---- a seeded instance and its rule findings (O, U, Z) -------------------------------------------------------------------
if [[ $PART == *O* || $PART == *U* || $PART == *Z* ]]; then
INSTH=proof-chan-h-$SUF
HID=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         values ('$INSTH', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | head -1)
RID=""
# newfinding <critical threshold>: the previous rule ended, a new one (critical at the threshold) judged on a fresh sample
# of 50; prints the one rule finding of the seeded instance
newfinding() {
  local k
  if [[ -n $RID ]]; then
    q "select pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"rule_id\":$RID}'::jsonb)->>'outcome'" >/dev/null
  fi
  RID=$(q "select pgvigil.import_alert_rule(now(), '{\"op\":\"add\",\"ui_user\":\"proof\",\"metric\":\"sessions.idle_in_txn\",\"op_dir\":\"above\",\"warning\":$(( $1 - 1 )),\"critical\":$1,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}'::jsonb)->>'rule_id'")
  [[ $RID =~ ^[0-9]+$ ]] || fail "the rule above $1 was not made: $RID"
  q "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
       active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
     values ($HID, now() - interval '5 seconds', 60, 1, 5, 50, 0, 0, 0, 1, 1, 1, 100)" >/dev/null
  q "select pgvigil.alert_rules_run(now())" >/dev/null
  k=$(q "select string_agg(finding_key, ',') from pgvigil.alert_findings where instance_id = $HID and source = 'alert rule' and severity = 'critical'")
  [[ $k =~ ^[0-9a-f]+$ ]] || fail "the rule above $1: its finding is '$k' (wanted one critical key)"
  echo "$k"
}
newest_alert() { q "select outcome || '|' || coalesce(error, '') from pgvigil.alert_log where channel = '$1' and n_firing + n_repeat + n_resolved > 0 order by snapshot_at desc limit 1"; }
dropcount() { grep -l "\"$1\"" "$WORK/drop"/* 2>/dev/null | xargs -r grep -l "\"$2\"" 2>/dev/null | xargs -r grep -l "\"$3\"" 2>/dev/null | wc -l; }
# the vendors' stubs on loopback: Pushover's Messages API and Azure's token endpoint and Logs Ingestion upload
AZTEN=72f988bf-86f1-41af-91ab-2d7cd011db47; AZCID=00001111-aaaa-2222-bbbb-3333cccc4444; AZDCR=dcr-0123456789abcdef0123456789abcdef
export PGV_PROOF_PO_TOKEN=azGDORePK8gMaC0QOYAMyEE$SUF PGV_PROOF_PO_USER=uQiRzpo4DXghDmr9QzzfQu$SUF PGV_PROOF_AZ_SECRET=s3cr3t-$SUF-$RANDOM
cat > "$WORK/vendor.py" <<'PY'
import json, os, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, port, tenant, dcr = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
def mode(name, default):
    p = os.path.join(work, name)
    return open(p).read().strip() if os.path.exists(p) else default
def log(name, rec):
    with open(os.path.join(work, name), 'a') as f:
        f.write(json.dumps(rec) + '\n')
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body, hdr=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        for k, v in (hdr or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
        u = urllib.parse.urlparse(self.path)
        if u.path == '/1/messages.json':
            form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
            log('po.log', form)
            m = mode('po.mode', '200')
            if m == '429':
                return self.answer(429, '{"status":0,"errors":["application has exceeded its monthly limit"]}', {'X-Limit-App-Reset': str(int(time.time()) + 3600)})
            if m == '400':
                return self.answer(400, '{"user":"invalid","errors":["user identifier is not a valid user, group, or subscribed user key"],"status":0}')
            return self.answer(200, '{"status":1,"request":"5042853c-402d-4a18-abcb-168734a801de"}',
                               {'X-Limit-App-Limit': '10000', 'X-Limit-App-Remaining': mode('po.left', '9000'), 'X-Limit-App-Reset': str(int(time.time()) + 30 * 86400)})
        if u.path == '/%s/oauth2/v2.0/token' % tenant:
            form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
            n = sum(1 for _ in open(os.path.join(work, 'aztok.log'))) + 1 if os.path.exists(os.path.join(work, 'aztok.log')) else 1
            log('aztok.log', form)
            return self.answer(200, json.dumps({'token_type': 'Bearer', 'expires_in': 3599, 'access_token': 'proof-token-%d' % n}))
        if u.path == '/dataCollectionRules/%s/streams/Custom-PgvigilAlerts' % dcr:
            log('azup.log', {'query': u.query, 'auth': self.headers.get('Authorization'), 'type': self.headers.get('Content-Type'), 'body': raw})
            if mode('az.mode', '204') == '400':
                return self.answer(400, '{"error":{"code":"InvalidStream","message":"The stream Custom-PgvigilAlerts is not declared in the rule"}}')
            self.send_response(204)
            self.end_headers()
            return
        self.answer(404, '{}')
ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
VPORT=$(freeport)
python3 "$WORK/vendor.py" "$WORK" "$VPORT" "$AZTEN" "$AZDCR" & VEND=$!
for n in $(seq 1 40); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$VPORT/x" && break
  [[ $n == 40 ]] && fail "the vendors' stub did not answer"
  sleep 0.25
done
posts() { [[ -f "$WORK/po.log" ]] && wc -l < "$WORK/po.log" || echo 0; }
fi

# ---- O: Pushover (stub) ---------------------------------------------------------------------------------------------------
if [[ $PART == *O* ]]; then
POLINE="  - {name: po, kind: pushover, min_severity: critical, instances: [$INSTH], pushover: {token: env:PGV_PROOF_PO_TOKEN, user: env:PGV_PROOF_PO_USER, url: http://127.0.0.1:$VPORT}}"
cp "$CFG" "$WORK/cfg.base.yaml"; echo "$POLINE" >> "$CFG"
echo 200 > "$WORK/po.mode"; echo 500 > "$WORK/po.left"
K1=$(newfinding 5)
pass O1
[[ $(newest_alert po | cut -d'|' -f1) == sent ]] || fail "O1: po's attempt: $(newest_alert po)"
python3 - "$WORK/po.log" "$K1" "$INSTH" <<'PY' || fail "O1: the post's fields: $(tail -1 "$WORK/po.log" | cut -c1-500)"
import json, os, sys
f = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert f['token'] == os.environ['PGV_PROOF_PO_TOKEN'] and f['user'] == os.environ['PGV_PROOF_PO_USER'], f
assert f['priority'] == '1' and sys.argv[3] in f['message'] and f['title'], f
PY
[[ $(q "select remaining || '/' || quota from pgvigil.alert_channel_quota where channel = 'po'") == 500/10000 ]] || fail "O1: the quota row: $(q "select * from pgvigil.alert_channel_quota")"
pass O1b
[[ $(dropcount 'pushover quota low' firing po) == 1 ]] || fail "O1: drop's 'pushover quota low' files: $(dropcount 'pushover quota low' firing po)"
echo 429 > "$WORK/po.mode"; echo 9000 > "$WORK/po.left"
K2=$(newfinding 6)
pass O2
got=$(newest_alert po)
[[ ${got%%|*} == failed && ${got#*|} =~ ^held\ until\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z:\  ]] || fail "O2: the 429's attempt: $got"
n0=$(posts)
pass O2b
[[ $(posts) == "$n0" ]] || fail "O2: a post while held by the 429"
grep -q 'held by the destination: po:' "$WORK/pass.O2b.out" || fail "O2: the pass does not say po is held: $(cat "$WORK/pass.O2b.out")"
echo 200 > "$WORK/po.mode"
testreq po 20
pass O2c
[[ $(newest po | cut -d'|' -f1) == test ]] || fail "O2: the Send test: $(newest po)"
[[ $(newest_alert po | cut -d'|' -f1) == sent ]] || fail "O2: the owed alert after the test: $(newest_alert po)"
echo 400 > "$WORK/po.mode"
K3=$(newfinding 7)
pass O3
[[ $(newest_alert po) == "failed|held until the configuration changes ("* ]] || fail "O3: the 400's attempt: $(newest_alert po)"
n0=$(posts)
pass O3b
[[ $(posts) == "$n0" ]] || fail "O3: a post while held by the 400"
cp "$WORK/cfg.base.yaml" "$CFG"; echo "${POLINE%\}\}}, device: proof1}}" >> "$CFG"
echo 200 > "$WORK/po.mode"
pass O3c
[[ $(newest_alert po | cut -d'|' -f1) == sent ]] || fail "O3: after the configuration changed: $(newest_alert po)"
[[ $(tail -1 "$WORK/po.log" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("device",""))') == proof1 ]] || fail "O3: the post after the change has no device proof1"
cp "$WORK/cfg.base.yaml" "$CFG"
ok "O: Pushover sent with its fields and quota; quota low raised; a 429 held until its reset or a test; a 400 until the configuration changed"
fi

# ---- U: Azure Monitor Logs (stub) -----------------------------------------------------------------------------------------
if [[ $PART == *U* ]]; then
cp "$CFG" "$WORK/cfg.base.yaml"
echo "  - {name: az, kind: azuremonitor, min_severity: critical, instances: [$INSTH], azuremonitor: {endpoint: http://127.0.0.1:$VPORT, dcr_id: $AZDCR, stream: Custom-PgvigilAlerts, tenant: $AZTEN, client_id: $AZCID, client_secret: env:PGV_PROOF_AZ_SECRET, login_url: http://127.0.0.1:$VPORT}}" >> "$CFG"
echo 204 > "$WORK/az.mode"
K4=$(newfinding 8)
pass U1
[[ $(newest_alert az | cut -d'|' -f1) == sent ]] || fail "U1: az's attempt: $(newest_alert az)"
python3 - "$WORK" "$K4" "$AZCID" "$AZDCR" <<'PY' || fail "U1: the stub's requests: $(cat "$WORK/aztok.log" "$WORK/azup.log" 2>/dev/null | cut -c1-400)"
import json, os, sys
w, key, cid = sys.argv[1], sys.argv[2], sys.argv[3]
toks = [json.loads(l) for l in open(os.path.join(w, 'aztok.log'))]
ups = [json.loads(l) for l in open(os.path.join(w, 'azup.log'))]
assert len(toks) == 1, toks
t = toks[0]
assert t['grant_type'] == 'client_credentials' and t['scope'] == 'https://monitor.azure.com//.default' and t['client_id'] == cid, t
assert t['client_secret'] == os.environ['PGV_PROOF_AZ_SECRET'], 'the secret'
assert len(ups) == 1 and ups[0]['query'] == 'api-version=2023-01-01' and ups[0]['auth'] == 'Bearer proof-token-1', ups
rows = json.loads(ups[0]['body'])
assert any(r['FindingKey'] == key and r['Severity'] == 'critical' for r in rows), rows
PY
echo 400 > "$WORK/az.mode"
K5=$(newfinding 9)
pass U2
[[ $(newest_alert az) == failed*InvalidStream* ]] || fail "U2: the 400's attempt: $(newest_alert az)"
cp "$WORK/cfg.base.yaml" "$CFG"
ok "U: Azure Monitor Logs: one token, one upload with the row; a 400 with Azure's words"
fi

# ---- Z: Zabbix live in containers -----------------------------------------------------------------------------------------
if [[ $PART == *Z* ]]; then
for t in docker openssl; do command -v $t >/dev/null || fail "$t is not on this machine (part Z)"; done
ZN=pgv-zbx-$SUF; ZPW=z$RANDOM$RANDOM; ZENC=$WORK/zenc; mkdir -p "$ZENC"
ZCLEAN="$ZN"
# a CA, the server's certificate (127.0.0.1 and the container's name) and the sending host's (CN=pgvigil-proof)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=pgvigil proof CA" -keyout "$ZENC/ca.key" -out "$ZENC/ca.pem" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$ZN-srv" -keyout "$ZENC/server.key" -out "$ZENC/server.csr" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:%s-srv\nextendedKeyUsage=serverAuth\n' "$ZN" > "$ZENC/srv.ext"
openssl x509 -req -in "$ZENC/server.csr" -CA "$ZENC/ca.pem" -CAkey "$ZENC/ca.key" -CAcreateserial -days 1 -extfile "$ZENC/srv.ext" -out "$ZENC/server.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=pgvigil-proof" -keyout "$ZENC/client.key" -out "$ZENC/client.csr" 2>/dev/null
printf 'extendedKeyUsage=clientAuth\n' > "$ZENC/cli.ext"
openssl x509 -req -in "$ZENC/client.csr" -CA "$ZENC/ca.pem" -CAkey "$ZENC/ca.key" -CAcreateserial -days 1 -extfile "$ZENC/cli.ext" -out "$ZENC/client.crt" 2>/dev/null
chmod 644 "$ZENC"/*   # the container's zabbix user reads them (throwaway keys of this run)
ZP1=$(freeport); ZP2=$(freeport)
docker network create "$ZN" >/dev/null
docker run -d --name "$ZN-db" --network "$ZN" -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="$ZPW" -e POSTGRES_DB=zabbix postgres:16-alpine >/dev/null
docker run -d --name "$ZN-srv" --network "$ZN" -e DB_SERVER_HOST="$ZN-db" -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="$ZPW" -e POSTGRES_DB=zabbix \
  -e ZBX_TLSCAFILE=ca.pem -e ZBX_TLSCERTFILE=server.crt -e ZBX_TLSKEYFILE=server.key -e ZBX_CACHEUPDATEFREQUENCY=5 \
  -v "$ZENC:/var/lib/zabbix/enc:ro" -p "127.0.0.1:$ZP1:10051" zabbix/zabbix-server-pgsql:alpine-7.0-latest >/dev/null
docker run -d --name "$ZN-web" --network "$ZN" -e ZBX_SERVER_HOST="$ZN-srv" -e DB_SERVER_HOST="$ZN-db" -e POSTGRES_USER=zabbix \
  -e POSTGRES_PASSWORD="$ZPW" -e POSTGRES_DB=zabbix -e PHP_TZ=UTC -p "127.0.0.1:$ZP2:8080" zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest >/dev/null
cat > "$WORK/zapi.py" <<'PY'
import json, sys, urllib.request
url, auth, method, params = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
req = urllib.request.Request(url, data=json.dumps({'jsonrpc': '2.0', 'method': method, 'params': json.loads(params), 'id': 1}).encode(),
                             headers={'Content-Type': 'application/json-rpc', **({'Authorization': 'Bearer ' + auth} if auth else {})})
try:
    ans = json.loads(urllib.request.urlopen(req, timeout=20).read())
except Exception as e:
    print('ERROR %s' % e); sys.exit(1)
if 'error' in ans:
    print('ERROR %s' % json.dumps(ans['error'])); sys.exit(1)
print(json.dumps(ans['result']))
PY
ZURL="http://127.0.0.1:$ZP2/api_jsonrpc.php"
zapi() { python3 "$WORK/zapi.py" "$ZURL" "${ZAUTH:-}" "$1" "$2"; }
for n in $(seq 1 120); do
  zapi apiinfo.version '{}' >/dev/null 2>&1 && break
  [[ $n == 120 ]] && fail "Z: the Zabbix API did not answer in 6 minutes: $(docker logs --tail 5 "$ZN-srv" 2>&1)"
  sleep 3
done
ZAUTH=""; ZAUTH=$(zapi user.login '{"username":"Admin","password":"zabbix"}' | tr -d '"') || fail "Z: user.login: $ZAUTH"
GID=$(zapi hostgroup.create "{\"name\":\"pgvigil proof $SUF\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["groupids"][0])') || fail "Z: hostgroup.create"
mkhost() {   # mkhost <host> <tls_accept 1|4> <trapper_hosts>: the host and its two trapper items (pgvigil.alert text, pgvigil.probe); the alert item's id
  local hid extra=""
  [[ $2 == 4 ]] && extra=',"tls_accept":4,"tls_connect":1,"tls_subject":"CN=pgvigil-proof"'
  hid=$(zapi host.create "{\"host\":\"$1\",\"groups\":[{\"groupid\":\"$GID\"}]$extra}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hostids"][0])') || fail "Z: host.create $1"
  zapi item.create "{\"name\":\"probe\",\"key_\":\"pgvigil.probe\",\"hostid\":\"$hid\",\"type\":2,\"value_type\":4,\"trapper_hosts\":\"$3\"}" >/dev/null || fail "Z: the probe item of $1"
  zapi item.create "{\"name\":\"pgvigil alerts\",\"key_\":\"pgvigil.alert\",\"hostid\":\"$hid\",\"type\":2,\"value_type\":4,\"trapper_hosts\":\"$3\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["itemids"][0])' || fail "Z: the alert item of $1"
}
ZI1=$(mkhost pgvigil-proof 1 "")
ZI2=$(mkhost pgvigil-proof-tls 4 "")
ZI3=$(mkhost pgvigil-proof-deny 1 "192.0.2.1")
UID1=$(zapi user.get '{"filter":{"username":["Admin"]},"output":["userid"]}' | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["userid"])')
TID=$(zapi token.create "{\"name\":\"pgvigil proof $SUF\",\"userid\":\"$UID1\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tokenids"][0])') || fail "Z: token.create"
export PGV_PROOF_ZBX_TOKEN; PGV_PROOF_ZBX_TOKEN=$(zapi token.generate "[\"$TID\"]" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["token"])') || fail "Z: token.generate"
# the server takes the new hosts from its configuration cache: a probe value until it is processed (at most 2 minutes)
probe() { python3 - "$ZP1" <<'PY'
import json, socket, struct, sys
d = json.dumps({'request': 'sender data', 'data': [{'host': 'pgvigil-proof', 'key': 'pgvigil.probe', 'value': 'probe'}]}).encode()
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=10)
s.sendall(b'ZBXD\x01' + struct.pack('<II', len(d), 0) + d)
b = b''
while True:
    c = s.recv(65536)
    if not c: break
    b += c
print(json.loads(b[13:]).get('info', ''))
PY
}
for n in $(seq 1 40); do
  [[ $(probe 2>/dev/null) == "processed: 1;"* ]] && break
  [[ $n == 40 ]] && fail "Z: the server never took the proof's host: $(probe 2>&1 | tail -1)"
  sleep 3
done
cp "$CFG" "$WORK/cfg.base.yaml"
cat >> "$CFG" <<EOF
  - {name: zbx, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof}}
  - {name: zbxtls, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-tls, tls_ca: $ZENC/ca.pem, tls_cert: $ZENC/client.crt, tls_key: $ZENC/client.key, tls_server_subject: "CN=$ZN-srv"}}
  - {name: zbxapi, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {mode: api, url: "http://127.0.0.1:$ZP2", token: env:PGV_PROOF_ZBX_TOKEN, host: pgvigil-proof}}
  - {name: zbxclear, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-tls}}
  - {name: zbxdeny, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-deny}}
EOF
K6=$(newfinding 10)
pass Z1
for c in zbx zbxtls zbxapi; do
  [[ $(newest_alert $c | cut -d'|' -f1) == sent ]] || fail "Z: $c's attempt: $(newest_alert $c)"
done
for c in zbxclear zbxdeny; do
  [[ $(newest_alert $c) == failed*"processed 0 of 1"* ]] || fail "Z: $c's attempt: $(newest_alert $c)"
done
hist() { zapi history.get "{\"history\":4,\"itemids\":[\"$1\"],\"output\":\"extend\"}" | python3 -c 'import json,sys; v=[json.loads(r["value"]) for r in json.load(sys.stdin)]; print(sum(1 for x in v if x.get("finding_key") == sys.argv[1]))' "$K6"; }
for n in $(seq 1 20); do [[ $(hist "$ZI1") == 2 && $(hist "$ZI2") == 1 ]] && break; sleep 3; done
[[ $(hist "$ZI1") == 2 ]] || fail "Z: pgvigil-proof's item holds $(hist "$ZI1") value(s) of the finding (wanted 2: the sender's and history.push's)"
[[ $(hist "$ZI2") == 1 ]] || fail "Z: pgvigil-proof-tls's item holds $(hist "$ZI2") value(s) of the finding (wanted 1: the TLS sender's)"
[[ $(hist "$ZI3") == 0 ]] || fail "Z: the denied host's item took a value"
cp "$WORK/cfg.base.yaml" "$CFG"
ZVOLS=$(docker inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}} {{end}}{{end}}' "$ZN-web" "$ZN-srv" "$ZN-db" 2>/dev/null | tr -s ' \n' ' ')
docker rm -f -v "$ZN-web" "$ZN-srv" "$ZN-db" >/dev/null; docker network rm "$ZN" >/dev/null; ZCLEAN=""
[[ -z $(docker ps -a --filter "name=$ZN" -q) && -z $(docker network ls --filter "name=$ZN" -q) ]] || fail "Z: a container or the network is left"
for v in $ZVOLS; do ! docker volume inspect "$v" >/dev/null 2>&1 || fail "Z: the volume $v is left"; done
ok "Z: sender plain (loopback), sender with certificate TLS and history.push read back from Zabbix; a host's certificate-only rule and Allowed hosts refuse a plain value"
fi
echo "PROOF OK $PART"
