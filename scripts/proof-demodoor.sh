#!/usr/bin/env bash
# Proof of the demo's write door (task B7): on `pgvigil demo -serve` the writes that touch only pgvigil's repository
# work on the demo's own instances as the built-in user 'demo', and nothing else is written.
#   PROOF_DOOR_ONLY=A  the API part alone (no browser)
#   PGVIGIL_ADMIN_DSN  a superuser connection to a sandbox server, without dbname. The proof makes its own repository
#                      database (random suffix) and drops it at the end; nothing that exists before the run is touched.
# Needs chromium, node, psql, curl, python3, go, ss.
# Expected (written before the first run):
#  A. the API beside the page, on a demo serve with one real instance (prod-db1) and one real instance tagged 'demo' by
#     hand (prod-db2) added to the same repository:
#     - GET /api/ack: writable false, the reason names pgvigil demo -serve, door user 'demo', as many door instances as
#       the demo seeded
#     - a write without the X-Pgvigil header: 403 'the X-Pgvigil header is required'
#     - a silence on a demo instance: 200 done; the acknowledge log's row: demo / demo door / add / done; its end: 200
#     - prod-db1 and prod-db2: 403 '<name> is not one of this demo's instances: changing it needs pgvigil serve with a
#       signed-in user'; nothing written for them
#     - a root drive threshold and a root job exclusion: 403 'a root change would reach past the demo's instances';
#       a mute on every instance: 403 'an every-instance change would reach past ...'
#     - an instance-level drive threshold on a demo instance: 200 done, its row created_by demo; inherit: 200
#     - an alert's key of one demo instance with another demo instance's id: 403 'the alert belongs to another instance'
#     - Send test: 403 '... pgvigil demo -serve runs no sender ...'; an alert rule: 403 '... judged by the alert sender,
#       which pgvigil demo -serve does not run ...'; cancel: 403 'actions are off on this server (no actions
#       configuration)'; Admin > Instances: 403 '... writes connection secrets and connects to servers ...'
#     - every row the door wrote names demo: no ack_log row with client 'demo door' and another user
#     - nothing else was written: over the tables the page's write functions touch (acks, ack_log, the three threshold
#       tables, job_exclusions, alert_dismissals, alert_rules, alert_tests, instances), counted before part A's first
#       request and after its last, the whole change is 'acks +1 ack_log +2 drive_thresholds +1', no threshold of demo
#       is live and no door row is without an instance [added at the review's fold]
#     [Added at the review's fold, red on the tree before it:]
#     - the seed's own silence (stored by its instance's NAME, without an id) is listed by GET /api/ack under that
#       instance's id, so the page can offer its Unsilence
#     - GET /api/jobs/thresholds and GET /api/jobs/exclusions (pages whose controls stay off on a demo serve until
#       they are taught the door): writable false, 'this page's ... are off on pgvigil demo -serve', never 'saved as
#       user demo' beside a control that is off
#  B. the page, by clicks (scripts/demodoor-check.mjs): 'ok door', 'ok seat' (the footer says whose door this is),
#     [every click that writes is judged on the log row IT wrote: a row newer than the newest one read before the
#     click, of the kind, the operation and the instance the click names; a dialog's answer is 'done N of N saved' or
#     'done ended', word for word]
#     'ok R1' (the Summary's strip, where the page said 'Acknowledge is off' before the door - that sentence is gone;
#     Acknowledge, Save - the line leaves the strip, its cells read acknowledged, the list
#     says 'acknowledged by demo', the log's new row demo / demo door / ack / add / done / <its name>), 'ok R1b-a' and
#     'ok R1b-b' (a demo instance's OWN pages - one with a failed job run, another than R1's and than the one the seed
#     silenced where there is one (were it the seed's, the row would unsilence first, then silence): (a) the header's
#     Silence on its Summary page - 'done ... saved', the silenced mark and Unsilence drawn, the log demo / demo door /
#     silence / add / done / <its name> - then Unsilence - 'done ended', the mark gone, Silence back, the log's row end;
#     (b) the Acknowledge of its failed job on its Jobs page - 'done ... saved', the cell then reads 'acknowledged
#     <time>' with Clear on, the log demo / demo door / job / add / done / <its name>. [First box run, vis-b7a: the
#     row looked for an Acknowledge on the instance's own Summary page and that page draws none - the strip with it
#     is the fleet Summary's; the row was rewritten for the controls an instance's pages do offer.]), 'ok R3'
#     (Unacknowledge - one cell back, the log's row end by demo), 'ok R2' (Options > Memory Dumps > Acknowledge Dumps: 'Memory dumps acknowledged
#     on N instance(s)', the log's new row an acknowledgement of a demo instance), 'ok R7' (prod-db1's Silence AND
#     prod-db2's - a real instance tagged demo by hand - are aria-disabled, never the disabled attribute, each with its
#     reason as visible text naming it as not one of this demo's instances; a Silence that is on stands in the row of
#     an instance the door names), 'ok R6' (Silence a demo instance from its row, then the Unsilence of that same
#     instance), 'ok R4' (a note on a ticked alert of a demo instance), 'ok R9a' (Send test and Mute similar are there
#     and off, each with its reason in words), 'ok R6b' (the demo's own seeded silence - stored by its instance's name - has its
#     Unsilence in the Alerts page's list of silenced servers: clicked, 'done ended', the log's row end by demo),
#     'ok R10' (a pgvigil serve -no-login started by the proof on the same repository, a server that writes nothing:
#     on the Summary, the Alerts page and a Jobs page with a failed job every off control has a description, no two
#     of a page's reason sentences say the same words, the sentence's words stand once in the page's text and in no
#     grid cell - the reason is said once per page; an instance's header is its own and read apart) [both added at the
#     review's fold], 'demodoor-check: every row ok', then 'ok B the seed's own silence ... is ended in the store, by
#     demo' (read from the repository). Shots are kept of R1, R1b, R7, R4, R6b and R10's Summary (14: DOOR_SHOTS,
#     default .vis/door-shots, emptied of earlier pictures first; one that could not be taken is a FAIL line).
# Last line: 'proof-demodoor: OK'.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_door_$RANDOM"; PORT=""; CDP=""; SRV=""; SRV2=""; CHR=""; FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
die() { echo "FAIL $*" >&2; exit 1; }
cleanup() {
  # nothing in here may fail the run (a failing command in an EXIT trap turns exit 0 into 1): the three processes are
  # ended and waited for before their files go (Chromium writes its profile while it shuts down), and a database
  # that could not be dropped is SAID, never swallowed
  set +e
  local p
  for p in "$SRV" "$SRV2" "$CHR"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  for p in "$SRV" "$SRV2" "$CHR"; do [[ -n "$p" ]] && wait "$p" 2>/dev/null; done
  local out
  out=$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" 2>&1) || echo "FAIL the scratch database $DB was not dropped: $out"
  rm -rf "$WORK" || true
}
trap cleanup EXIT
for t in chromium node psql curl python3 go ss timeout; do command -v $t >/dev/null || die "$t is not on this machine"; done
node -e 'process.exit(typeof WebSocket === "function" && typeof fetch === "function" ? 0 : 1)' || die "node $(node --version) has no global WebSocket: the click script needs node 22 or later"
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) or sport = :$((p + 2)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || die "no three free ports"; CDP=$((PORT + 1)); PORT2=$((PORT + 2))

echo "== build, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN="$WORK/pgvigil"; fi
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$BIN" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; die "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; die "the demo did not come up"; }
U="http://127.0.0.1:$PORT"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
N=$(q "select count(*) from pgvigil.instances where 'demo' = any (tags)")
D1=$(q "select instance_id from pgvigil.instances where 'demo' = any (tags) order by instance_id limit 1")
[[ -n "$D1" ]] || die "the rig: the demo seeded no instance tagged demo"
D1N=$(q "select name from pgvigil.instances where instance_id = $D1")
D2=$(q "select s.instance_id from pgvigil.alert_state s join pgvigil.instances i using (instance_id) where 'demo' = any (i.tags) and s.instance_id <> $D1 order by s.last_sent_at desc limit 1")
KEY=$(q "select finding_key from pgvigil.alert_state where instance_id = $D2 order by last_sent_at desc limit 1")
REAL=$(q "select pgvigil.ensure_instance('prod-db1', 'onprem', 'real', 160004, false, '{prod}')")
TAGGED=$(q "select pgvigil.ensure_instance('prod-db2', 'onprem', 'real', 160004, false, '{demo}')")
[[ -n "$D1" && -n "$D2" && -n "$KEY" && -n "$REAL" && -n "$TAGGED" ]] || die "the rig: demo instances $D1 / $D2, key '$KEY', prod-db1 $REAL, prod-db2 $TAGGED"
# R1b's ground: the demo instances with a failed job run (pg_cron / pgAgent, or SQL Server Agent's job outcome row),
# PostgreSQL's first, as [{id, name, tab}] - tab is that engine's Jobs page
JOBS=$(q "select coalesce(json_agg(json_build_object('id', x.instance_id, 'name', x.name, 'tab', x.tab) order by x.ord, x.instance_id), '[]')
  from (select i.instance_id, i.name, case when i.engine = 'postgres' then 'jobs' else 'mssqljobs' end as tab, case when i.engine = 'postgres' then 0 else 1 end as ord
          from pgvigil.instances i
         where 'demo' = any (i.tags)
           and (exists (select 1 from pgvigil.job_runs r where r.instance_id = i.instance_id and r.status in ('failed', 'internal error'))
             or exists (select 1 from pgvigil.mssql_job_runs r where r.instance_id = i.instance_id and r.step_id = 0 and r.run_status = 0))) x")
echo "the demo instances with a failed job run: $JOBS"
# what part A may change, counted before its first request and after its last: only the tables the page's write
# functions touch (the live fleet goes on writing its own snapshots beside them)
counts() { q "select concat_ws(' ', 'acks', (select count(*) from pgvigil.acks), 'ack_log', (select count(*) from pgvigil.ack_log),
  'drive_thresholds', (select count(*) from pgvigil.drive_thresholds), 'pg_thresholds', (select count(*) from pgvigil.pg_thresholds),
  'job_thresholds', (select count(*) from pgvigil.job_thresholds), 'job_exclusions', (select count(*) from pgvigil.job_exclusions),
  'alert_dismissals', (select count(*) from pgvigil.alert_dismissals), 'alert_rules', (select count(*) from pgvigil.alert_rules),
  'alert_tests', (select count(*) from pgvigil.alert_tests), 'instances', (select count(*) from pgvigil.instances))"; }
C0=$(counts)

echo "== A. the API"
H=(-H 'X-Pgvigil: 1' -H 'Content-Type: application/json')
post() { local path=$1 body=$2; shift 2; CODE=$(curl -s -o "$WORK/ans" -w '%{http_code}' -X POST "$@" -d "$body" "$U/api/$path"); ANS=$(head -c 600 "$WORK/ans"); }
want() { # want <label> <code> <words the answer must hold>
  if [[ "$CODE" == "$2" && "$ANS" == *"$3"* ]]; then ok "A $1: $CODE $(echo "$ANS" | head -c 170)"; else fail "A $1: $CODE $ANS (want $2 with '$3')"; fi; }
G=$(curl -s "$U/api/ack?part=acks" | python3 -c 'import json,sys; d=json.load(sys.stdin); x=d.get("door") or {}; print(d.get("writable"), "|", x.get("user"), "|", len(x.get("instances") or []), "|", d.get("reason"))')
if [[ "$G" == "False | demo | $N | "*"pgvigil demo -serve"* && "$G" != *"-no-login"* ]]; then ok "A the door as the page is told: writable False, user demo, $N instances; '${G##*| }'"; else fail "A GET /api/ack: $G (want False | demo | $N | ... pgvigil demo -serve ...)"; fi
# the seed's silence: one live silence before the proof writes any, listed under its instance's own id
SS=$(curl -s "$U/api/ack?part=acks" | python3 -c 'import json,sys
t=json.load(sys.stdin)["acks"]; r=[dict(zip(t["columns"],x)) for x in t["rows"]]; s=[x for x in r if x["kind"]=="silence" and x["live"]]
print(len(s), "|", ",".join(str(x["instance_id"]) for x in s), "|", ",".join(str(x["instance"]) for x in s))')
SSID=$(q "select coalesce((select instance_id::text from pgvigil.instances where name = '${SS##*| }'), 'no such instance')")
if [[ "$SS" == "1 | $SSID | "* ]]; then ok "A the seed's silence is listed under its instance's id: $SS"; else fail "A the seed's silence: '$SS' (want one live silence, its instance_id $SSID)"; fi
for pair in "thresholds:jobs/thresholds?instance=$D1" "job exclusions:jobs/exclusions?instance=$D1"; do
  G=$(curl -s "$U/api/${pair#*:}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("writable"), "|", d.get("reason"))')
  if [[ "$G" == "False | this page's ${pair%%:*} are off on pgvigil demo -serve"* && "$G" != *"saved as user demo"* ]]; then ok "A GET /api/${pair#*:}: $G"; else fail "A GET /api/${pair#*:}: $G (want False | this page's ${pair%%:*} are off on pgvigil demo -serve ...)"; fi
done
post ack "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"x\"}" -H 'Content-Type: application/json'; want "no header" 403 "the X-Pgvigil header is required"
post ack "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"door proof\"}" "${H[@]}"; want "a silence on a demo instance" 200 '"outcome":"done"'
AID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ack_id") or 0)' "$WORK/ans")
L=$(q "select concat_ws(' / ', ui_user, client, kind, op, outcome, instance_name) from pgvigil.ack_log order by log_id desc limit 1")
if [[ "$L" == "demo / demo door / silence / add / done / $D1N" ]]; then ok "A its log row: $L"; else fail "A its log row: $L (want demo / demo door / silence / add / done / $D1N)"; fi
post ack/end "{\"ack_id\":$AID}" "${H[@]}"; want "its end" 200 '"outcome":"done"'
for pair in "$REAL:prod-db1" "$TAGGED:prod-db2"; do
  post ack "{\"kind\":\"silence\",\"instance_id\":${pair%%:*},\"note\":\"x\"}" "${H[@]}"; want "${pair##*:} (not the demo's)" 403 "${pair##*:} is not one of this demo's instances: changing it needs pgvigil serve with a signed-in user"
done
if [[ $(q "select (select count(*) from pgvigil.acks where instance_id in ($REAL, $TAGGED) or instance_name in ('prod-db1', 'prod-db2')) + (select count(*) from pgvigil.ack_log where instance_name in ('prod-db1', 'prod-db2'))") == 0 ]]; then ok "A nothing written for prod-db1 or prod-db2 (by id or by name, the log too)"; else fail "A a row was written for a real instance"; fi
post drives/thresholds '{"op":"set","level":"root","warn":20,"crit":10}' "${H[@]}"; want "a root drive threshold" 403 "a root change would reach past the demo's instances"
post jobs/exclusions '{"op":"add","level":"root","pattern":"x"}' "${H[@]}"; want "a job exclusion (its page is not taught the door: the route is not the door's)" 403 "this change is not made through the demo"
post ack '{"kind":"mute","match_text":"jit","note":"x"}' "${H[@]}"; want "a mute on every instance" 403 "an every-instance change would reach past the demo's instances"
post drives/thresholds "{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$D1,\"warn\":20,\"crit\":10}" "${H[@]}"; want "an instance's drive threshold" 200 '"outcome":"done"'
[[ $(q "select created_by from pgvigil.drive_thresholds where instance_id = $D1 order by threshold_id desc limit 1") == demo ]] && ok "A its row is demo's" || fail "A the threshold's created_by"
post drives/thresholds "{\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":$D1}" "${H[@]}"; want "inherit" 200 '"outcome":"done"'
post ack "{\"kind\":\"alert_ack\",\"finding_key\":\"$KEY\",\"instance_id\":$D1}" "${H[@]}"; want "an alert's key with another instance's id" 403 "the alert belongs to another instance"
post alerts/test '{"channel":"ops"}' "${H[@]}"; want "Send test" 403 "pgvigil demo -serve runs no sender"
post alertrules '{"name":"x"}' "${H[@]}"; want "an alert rule" 403 "judged by the alert sender, which pgvigil demo -serve does not run"
post actions/cancel "{\"instance_id\":$D1,\"pid\":1,\"reason\":\"x\"}" "${H[@]}"; want "cancel" 403 "actions are off on this server (no actions configuration)"
post admin/instances '{"op":"add","name":"x"}' "${H[@]}"; want "Admin > Instances" 403 "writes connection secrets and connects to servers"
if [[ $(q "select count(*) from pgvigil.ack_log where client = 'demo door' and ui_user is distinct from 'demo'") == 0 ]]; then ok "A every row through the door names demo"; else fail "A a door row names another user"; fi
# nothing else was written: over the tables the page's write functions touch, part A's whole change is one silence
# (made and ended: one acks row, two log rows) and one drive threshold (set, then ended by inherit: one row, none live)
C1=$(counts)
DELTA=$(python3 -c 'import sys
a, b = sys.argv[1].split(), sys.argv[2].split()
d = {a[i]: int(b[i + 1]) - int(a[i + 1]) for i in range(0, len(a), 2)}
print(" ".join(f"{k} {v:+d}" for k, v in d.items() if v) or "nothing")' "$C0" "$C1")
LIVE=$(q "select (select count(*) from pgvigil.drive_thresholds where ended_at is null and created_by = 'demo') || ' live threshold(s) of demo, ' || (select count(*) from pgvigil.acks where client = 'demo door' and instance_id is null) || ' door row(s) without an instance'")
if [[ "$DELTA" == "acks +1 ack_log +2 drive_thresholds +1" && "$LIVE" == "0 live threshold(s) of demo, 0 door row(s) without an instance" ]]; then ok "A nothing else was written: $DELTA; $LIVE"; else fail "A what part A changed: $DELTA; $LIVE (want acks +1 ack_log +2 drive_thresholds +1; 0 live threshold(s) of demo, 0 door row(s) without an instance)"; fi

if [[ "${PROOF_DOOR_ONLY:-}" == A ]]; then
  if (( FAILS )); then echo "FAIL: $FAILS"; exit 1; fi
  echo "proof-demodoor: part A OK (part B, the page by clicks, not run: PROOF_DOOR_ONLY=A)"; exit 0
fi
echo "== B. the page, by clicks"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || die "chromium's CDP port never answered"
SHOTS=${DOOR_SHOTS:-$PWD/.vis/door-shots}
mkdir -p "$SHOTS"; rm -f "$SHOTS"/*.png   # this run's shots alone: an earlier run's picture never stands in for a missing one
# R10's ground: a pgvigil serve -no-login on the same repository (a server that writes nothing at all), read only
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/none.yaml"
PGVIGIL_REPO_DSN="$DSN" "$BIN" serve -no-login -config "$WORK/none.yaml" -listen "127.0.0.1:$PORT2" > "$WORK/serve.log" 2>&1 &
SRV2=$!
U2="http://127.0.0.1:$PORT2"
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U2/" && break; kill -0 $SRV2 2>/dev/null || break; sleep 0.5; done
if ! curl -sf -o /dev/null "$U2/"; then fail "R10 the serve -no-login did not answer: $(tail -2 "$WORK/serve.log" | tr '\n' ' ')"; U2=""; fi
# the rig as the click script reads it: the instances with a failed job, the instance of the seed's own silence, the
# real instance tagged demo by hand, the serve -no-login
RIG=$(python3 -c 'import json,sys; print(json.dumps({"jobs": json.loads(sys.argv[1]), "seed": sys.argv[2], "tagged": sys.argv[3], "nologin": sys.argv[4]}))' "$JOBS" "${SS##*| }" prod-db2 "${U2:+$U2/}")
timeout 900 node scripts/demodoor-check.mjs "$CDP" "$U" prod-db1 "$SHOTS" "$RIG" || { echo "FAIL the click script ended with exit $? (124 = cut at 900 s)"; FAILS=$((FAILS + 1)); }
echo "shots: $(ls "$SHOTS" 2>/dev/null | wc -l) in $SHOTS"
# R6b's other half, read from the store: the seed's own silence (client 'demo seed') was ended, by demo
SE=$(q "select coalesce(string_agg(coalesce(ended_by, 'not ended'), ','), 'no such row') from pgvigil.acks where kind = 'silence' and client = 'demo seed'")
if [[ "$SE" == demo ]]; then ok "B the seed's own silence (${SS##*| }) is ended in the store, by demo"; else fail "B the seed's own silence: $SE (want ended by demo)"; fi

if (( FAILS )); then echo "FAIL: $FAILS"; exit 1; fi
echo "proof-demodoor: OK"
