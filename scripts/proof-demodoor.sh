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
#  B. the page, by clicks (scripts/demodoor-check.mjs): 'ok door', 'ok seat' (the footer says whose door this is),
#     'ok R1' (the Summary's strip: Acknowledge, Save - the line leaves the strip, its cells read acknowledged, the list
#     says 'acknowledged by demo', the log's newest row demo / demo door / add / done), 'ok R1b' (the same click on a
#     demo instance's own page), 'ok R3' (Unacknowledge - one cell
#     back, the log's row end by demo), 'ok R2' (Options > Memory Dumps > Acknowledge Dumps: 'Memory dumps acknowledged
#     on N instance(s)'), 'ok R7' (prod-db1's Silence is aria-disabled, never the disabled attribute, its reason visible
#     text naming it as not one of this demo's instances; a demo instance's Silence is on), 'ok R6' (Silence a demo
#     instance, then Unsilence), 'ok R4' (a note on a ticked alert), 'ok R9a' (Send test and Mute similar off with
#     their reasons in words), 'demodoor-check: every row ok'. The shots of each step are kept (DOOR_SHOTS, default
#     .vis/door-shots).
# Last line: 'proof-demodoor: OK'.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_door_$RANDOM"; PORT=""; CDP=""; SRV=""; CHR=""; FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
die() { echo "FAIL $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl python3 go ss; do command -v $t >/dev/null || die "$t is not on this machine"; done
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || die "no free port pair"; CDP=$((PORT + 1))

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
D2=$(q "select s.instance_id from pgvigil.alert_state s join pgvigil.instances i using (instance_id) where 'demo' = any (i.tags) and s.instance_id <> $D1 order by s.last_sent_at desc limit 1")
KEY=$(q "select finding_key from pgvigil.alert_state where instance_id = $D2 order by last_sent_at desc limit 1")
REAL=$(q "select pgvigil.ensure_instance('prod-db1', 'onprem', 'real', 160004, false, '{prod}')")
TAGGED=$(q "select pgvigil.ensure_instance('prod-db2', 'onprem', 'real', 160004, false, '{demo}')")
[[ -n "$D1" && -n "$D2" && -n "$KEY" && -n "$REAL" && -n "$TAGGED" ]] || die "the rig: demo instances $D1 / $D2, key '$KEY', prod-db1 $REAL, prod-db2 $TAGGED"

echo "== A. the API"
H=(-H 'X-Pgvigil: 1' -H 'Content-Type: application/json')
post() { local path=$1 body=$2; shift 2; CODE=$(curl -s -o "$WORK/ans" -w '%{http_code}' -X POST "$@" -d "$body" "$U/api/$path"); ANS=$(head -c 600 "$WORK/ans"); }
want() { # want <label> <code> <words the answer must hold>
  if [[ "$CODE" == "$2" && "$ANS" == *"$3"* ]]; then ok "A $1: $CODE $(echo "$ANS" | head -c 170)"; else fail "A $1: $CODE $ANS (want $2 with '$3')"; fi; }
G=$(curl -s "$U/api/ack?part=acks" | python3 -c 'import json,sys; d=json.load(sys.stdin); x=d.get("door") or {}; print(d.get("writable"), "|", x.get("user"), "|", len(x.get("instances") or []), "|", d.get("reason"))')
if [[ "$G" == "False | demo | $N | "*"pgvigil demo -serve"* && "$G" != *"-no-login"* ]]; then ok "A the door as the page is told: writable False, user demo, $N instances; '${G##*| }'"; else fail "A GET /api/ack: $G (want False | demo | $N | ... pgvigil demo -serve ...)"; fi
post ack "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"x\"}" -H 'Content-Type: application/json'; want "no header" 403 "the X-Pgvigil header is required"
post ack "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"door proof\"}" "${H[@]}"; want "a silence on a demo instance" 200 '"outcome":"done"'
AID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ack_id") or 0)' "$WORK/ans")
L=$(q "select ui_user || ' / ' || client || ' / ' || op || ' / ' || outcome from pgvigil.ack_log order by log_id desc limit 1")
[[ "$L" == "demo / demo door / add / done" ]] && ok "A its log row: $L" || fail "A its log row: $L"
post ack/end "{\"ack_id\":$AID}" "${H[@]}"; want "its end" 200 '"outcome":"done"'
for pair in "$REAL:prod-db1" "$TAGGED:prod-db2"; do
  post ack "{\"kind\":\"silence\",\"instance_id\":${pair%%:*},\"note\":\"x\"}" "${H[@]}"; want "${pair##*:} (not the demo's)" 403 "${pair##*:} is not one of this demo's instances: changing it needs pgvigil serve with a signed-in user"
done
[[ $(q "select count(*) from pgvigil.acks where instance_id in ($REAL, $TAGGED)") == 0 ]] && ok "A nothing written for prod-db1 or prod-db2" || fail "A a row was written for a real instance"
post drives/thresholds '{"op":"set","level":"root","warn":20,"crit":10}' "${H[@]}"; want "a root drive threshold" 403 "a root change would reach past the demo's instances"
post jobs/exclusions '{"op":"add","level":"root","pattern":"x"}' "${H[@]}"; want "a root job exclusion" 403 "a root change would reach past the demo's instances"
post ack '{"kind":"mute","match_text":"jit","note":"x"}' "${H[@]}"; want "a mute on every instance" 403 "an every-instance change would reach past the demo's instances"
post drives/thresholds "{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$D1,\"warn\":20,\"crit\":10}" "${H[@]}"; want "an instance's drive threshold" 200 '"outcome":"done"'
[[ $(q "select created_by from pgvigil.drive_thresholds where instance_id = $D1 order by threshold_id desc limit 1") == demo ]] && ok "A its row is demo's" || fail "A the threshold's created_by"
post drives/thresholds "{\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":$D1}" "${H[@]}"; want "inherit" 200 '"outcome":"done"'
post ack "{\"kind\":\"alert_ack\",\"finding_key\":\"$KEY\",\"instance_id\":$D1}" "${H[@]}"; want "an alert's key with another instance's id" 403 "the alert belongs to another instance"
post alerts/test '{"channel":"ops"}' "${H[@]}"; want "Send test" 403 "pgvigil demo -serve runs no sender"
post alertrules '{"name":"x"}' "${H[@]}"; want "an alert rule" 403 "judged by the alert sender, which pgvigil demo -serve does not run"
post actions/cancel "{\"instance_id\":$D1,\"pid\":1,\"reason\":\"x\"}" "${H[@]}"; want "cancel" 403 "actions are off on this server (no actions configuration)"
post admin/instances '{"op":"add","name":"x"}' "${H[@]}"; want "Admin > Instances" 403 "writes connection secrets and connects to servers"
[[ $(q "select count(*) from pgvigil.ack_log where client = 'demo door' and ui_user <> 'demo'") == 0 ]] && ok "A every row through the door names demo" || fail "A a door row names another user"

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
node scripts/demodoor-check.mjs "$CDP" "$U" prod-db1 "$SHOTS" || FAILS=$((FAILS + 1))
echo "shots: $(ls "$SHOTS" 2>/dev/null | wc -l) in $SHOTS"

if (( FAILS )); then echo "FAIL: $FAILS"; exit 1; fi
echo "proof-demodoor: OK"
