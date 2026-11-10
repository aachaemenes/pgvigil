#!/usr/bin/env bash
# Proof of Performance Insights and the Serverless cache rule (task 56) on a throwaway repository database. Four parts:
#   recorded (always): the pi collector from the GetResourceMetrics / GetDimensionKeyDetails responses in
#                      internal/collect/testdata/pi (the wire shape of the AWS PI API reference, read 2026-11-09;
#                      synthetic values: the lab cluster's Performance Insights is off, so the PI side is NOT proven
#                      live) and the serverless collector from a synthetic CloudWatch floor shape, imported twice into
#                      the repository (go test TestPI* TestServerless*).
#   rules (always):    seeded serverless windows through import_serverless raise exactly the expected pi_findings row,
#                      its three figures in the value.
#   server (always):   seeded PI hours through import_pi; /api/pi and /api/capacity answer every part (a build without
#                      the routes - the wave's join wires them - is re-built in a scratch copy with the two route
#                      lines of the slice's wiring block, so the endpoints' SQL is proven either way).
#   live (LIVE=1):     the lab's Aurora cluster is woken through its IAM door; `collect -once pi` stores the PI-off
#                      state from DescribeDBInstances, `collect -once serverless` the CloudWatch series; WAIT seconds
#                      later (default 420: a 5-minute period awake) a second serverless read. Read only on the cluster.
#   PGVIGIL_ADMIN_DSN  keyword-form connection without dbname, a login that may create a database (the proof makes
#                      pgvigil_proof_pi_<n> and drops it at the end)
#   AWS_PROFILE default dba-lab; AWS_REGION default us-east-2; CLUSTER default dba-lab-pg; WAIT default 420
# Expected:
#   recorded  TestPIRecordedShape, TestPIOff, TestPITextPolicy, TestPIGateAndApplies, TestServerlessRows,
#             TestServerlessDescribeFails, TestDescribeClusterRetry, TestPITextPaths and
#             TestPIFixtureImport PASS (the last one runs: PGVIGIL_REPO_DSN is the proof's repository)
#   rules     pi_findings rows (instance|setting), exactly: proof-floor and proof-zero|cache starved by the ACU floor,
#             proof-floor's value '0.5 ACU (floor 0.5), hit ratio 91.0 %, 850 reads/s at 12.0 % CPU', proof-zero's
#             '0.5 ACU (floor 0.0, running 0.5), ...' (a 0 minimum: an awake instance runs at 0.5 at least); none for
#             proof-scaled (one period at 2 ACU), proof-hit (98 % hits), proof-cpu (70 % CPU), proof-quiet (40 reads
#             a second), proof-few (4 capacity datapoints), proof-prov (no Serverless v2 range), proof-old (the floor
#             shape 2 hours ago), proof-raised (the floor raised to 2 ACU half an hour ago: 6 periods at 0.5, then 6 at 2)
#   server    /api/pi for proof-pi: state enabled, total 3 hours, waits 9 rows (3 waits x 3 hours), sql 2 rows, the
#             first tok-orders at 70.0 % of the load with its 694-byte whole text; /api/pi for proof-pioff: state
#             enabled false, total 0; /api/capacity for proof-floor: scaling 0.5 / 16, series >= 1, latest 5 metrics,
#             findings 1; /api/capacity for proof-pioff: scaling 0 rows, series 0
#   live      collection_dates pi ok and pi_state enabled false with the 'off' note (the express shape has PI off);
#             serverless ok with a serverless_scaling row (cluster dba-lab-pg, min 0, max 4); after WAIT awake,
#             ServerlessDatabaseCapacity, ACUUtilization and BufferCacheHitRatio rows (awake), or the paused note with
#             capacity 0 (a paused instance publishes 0 for capacity, ACU and CPU only: the Aurora User Guide): either
#             way stated in the output
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
PROFILE=${AWS_PROFILE:-dba-lab}; REGION=${AWS_REGION:-us-east-2}; CLUSTER=${CLUSTER:-dba-lab-pg}; WAIT=${WAIT:-420}
DB=pgvigil_proof_pi_$RANDOM
CFG=$(mktemp); LOG=$(mktemp); SCRATCH=$(mktemp -d); SRVPID=; CREATED=
cleanup() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  rm -rf "$CFG" "$LOG" "$LOG.body" "$SCRATCH"
  [ -n "$CREATED" ] || return 0   # the drop only for the database this run created (a name taken by another run is not ours)
  local err
  err=$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" 2>&1) \
    || { echo "cleanup: database $DB not dropped: $err" >&2; exit 1; }
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- recorded responses -> repository"
out=$(go test ./internal/collect -run 'TestPI|TestServerless|TestDescribeClusterRetry' -count=1 -v 2>&1) || { echo "$out" | tail -30; fail "recorded-response tests"; }
echo "$out" | grep -E '^--- ' || true
for t in TestPIRecordedShape TestPIOff TestPITextPolicy TestPIGateAndApplies TestServerlessRows TestServerlessDescribeFails TestDescribeClusterRetry TestPITextPaths TestPIFixtureImport; do
  echo "$out" | grep -q -- "--- PASS: $t " || fail "$t did not pass"
done
echo "recorded: OK (the PI side from the API reference's shape: not proven live, the lab's PI is off)"

echo "--- rules: seeded serverless windows through import_serverless"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
inst() { q "select pgvigil.ensure_instance('$1', 'aurora', '17.4', 170004, false, '{proof}')"; }
# window <id> <minutes-ago of the newest point> <points> <acu> <hit> <reads> <cpu> [<acu of the newest point>]:
# one datapoint per 5 minutes of each metric
window() {
  local id=$1 ago=$2 n=$3 acu=$4 hit=$5 rd=$6 cpu=$7 last=${8:-$4} rows="" i at a
  for ((i = 0; i < n; i++)); do
    at=$(date -u -d "-$((ago + 5 * i)) minutes" +%Y-%m-%dT%H:%M:00Z)
    a=$acu; [ "$i" = 0 ] && a=$last
    rows+="${rows:+,}{\"kind\":\"metric\",\"dim\":\"proof\",\"metric\":\"ServerlessDatabaseCapacity\",\"stat\":\"Maximum\",\"unit\":\"ACU\",\"at\":\"$at\",\"value\":$a}"
    rows+=",{\"kind\":\"metric\",\"dim\":\"proof\",\"metric\":\"BufferCacheHitRatio\",\"stat\":\"Average\",\"unit\":\"percent\",\"at\":\"$at\",\"value\":$hit}"
    rows+=",{\"kind\":\"metric\",\"dim\":\"proof\",\"metric\":\"ReadIOPS\",\"stat\":\"Average\",\"unit\":\"count/s\",\"at\":\"$at\",\"value\":$rd}"
    rows+=",{\"kind\":\"metric\",\"dim\":\"proof\",\"metric\":\"CPUUtilization\",\"stat\":\"Average\",\"unit\":\"percent\",\"at\":\"$at\",\"value\":$cpu}"
    rows+=",{\"kind\":\"metric\",\"dim\":\"proof\",\"metric\":\"ACUUtilization\",\"stat\":\"Average\",\"unit\":\"percent\",\"at\":\"$at\",\"value\":99}"
  done
  q "select pgvigil.import_serverless($id, now(), '[$rows]'::jsonb)" >/dev/null
}
scaling() { # <id> <min or null> <max or null>
  q "select pgvigil.import_serverless($1, now(), '[{\"kind\":\"scaling\",\"db_instance\":\"proof\",\"cluster\":\"proof-cluster\",\"class\":\"db.serverless\",\"min_acu\":$2,\"max_acu\":$3}]'::jsonb)" >/dev/null
}
FLO=$(inst proof-floor); SCA=$(inst proof-scaled); HIT=$(inst proof-hit); CPU=$(inst proof-cpu)
QUI=$(inst proof-quiet); FEW=$(inst proof-few); PRO=$(inst proof-prov); OLD=$(inst proof-old)
ZER=$(inst proof-zero); RAI=$(inst proof-raised)
for id in $FLO $SCA $HIT $CPU $QUI $FEW $OLD; do scaling "$id" 0.5 16; done
scaling "$PRO" null null
scaling "$ZER" 0 4
scaling "$RAI" 2 16
window "$FLO" 2 8 0.5 91 850 12
window "$SCA" 2 8 0.5 91 850 12 2
window "$HIT" 2 8 0.5 98 850 12
window "$CPU" 2 8 0.5 91 850 70
window "$QUI" 2 8 0.5 91 40 12
window "$FEW" 2 4 0.5 91 850 12
window "$PRO" 2 8 0.5 91 850 12
window "$OLD" 120 8 0.5 91 850 12
window "$ZER" 2 8 0.5 91 850 12
window "$RAI" 32 6 0.5 91 850 12   # 0.5 ACU from 57 to 32 minutes ago, then the raise:
window "$RAI" 2 6 2 91 850 12      # 2 ACU from 27 to 2 minutes ago
IDS="$FLO, $SCA, $HIT, $CPU, $QUI, $FEW, $PRO, $OLD, $ZER, $RAI"
GOT=$(q "select i.name || '|' || f.setting from pgvigil.pi_findings f join pgvigil.instances i using (instance_id) where i.instance_id in ($IDS)" | sort)
WANT=$(printf '%s\n' 'proof-floor|cache starved by the ACU floor' 'proof-zero|cache starved by the ACU floor' | sort)
if [[ "$GOT" != "$WANT" ]]; then echo "got:"; echo "$GOT"; echo "want:"; echo "$WANT"; fail "pi_findings rows differ"; fi
VAL=$(q "select value from pgvigil.pi_findings where instance_id = $FLO")
[ "$VAL" = '0.5 ACU (floor 0.5), hit ratio 91.0 %, 850 reads/s at 12.0 % CPU' ] || fail "the finding's value: $VAL"
VAL=$(q "select value from pgvigil.pi_findings where instance_id = $ZER")
[ "$VAL" = '0.5 ACU (floor 0.0, running 0.5), hit ratio 91.0 %, 850 reads/s at 12.0 % CPU' ] || fail "the 0-floor finding's value: $VAL"
q "select i.name || ': ' || f.value || ' -> ' || f.suggested from pgvigil.pi_findings f join pgvigil.instances i using (instance_id) where i.instance_id in ($IDS)"
q "select detail from pgvigil.pi_findings where instance_id = $FLO"
echo "rules: OK (2 findings, one on a 0 minimum; one period at 2 ACU, 98 % hits, 70 % CPU, 40 reads a second, 4 datapoints, no range, a window 2 hours old and a floor raised mid-window raise none)"

echo "--- server: /api/pi and /api/capacity"
PI=$(inst proof-pi); OFF=$(inst proof-pioff)
H0=$(date -u -d '-4 hours' +%Y-%m-%dT%H:00:00Z)
hr() { date -u -d "$H0 + $1 hours" +%Y-%m-%dT%H:00:00Z; }
WHOLE=$(python3 -I -c 'import json; print(json.load(open("internal/collect/testdata/pi/get-dimension-key-details.json"))["Dimensions"][0]["Value"])')
DIGEST=${WHOLE:0:120}
LOAD=""
for h in 0 1 2; do
  at=$(hr $h)
  LOAD+="${LOAD:+,}{\"kind\":\"load\",\"at\":\"$at\",\"group\":\"total\",\"key\":\"\",\"value\":2}"
  LOAD+=",{\"kind\":\"load\",\"at\":\"$at\",\"group\":\"wait\",\"key\":\"CPU\",\"wait_type\":\"CPU\",\"value\":0.8}"
  LOAD+=",{\"kind\":\"load\",\"at\":\"$at\",\"group\":\"wait\",\"key\":\"DataFileRead\",\"wait_type\":\"IO\",\"value\":1.0}"
  LOAD+=",{\"kind\":\"load\",\"at\":\"$at\",\"group\":\"wait\",\"key\":\"transactionid\",\"wait_type\":\"Lock\",\"value\":0.2}"
  LOAD+=",{\"kind\":\"load\",\"at\":\"$at\",\"group\":\"sql\",\"key\":\"tok-orders\",\"value\":1.4}"
  LOAD+=",{\"kind\":\"load\",\"at\":\"$at\",\"group\":\"sql\",\"key\":\"tok-accounts\",\"value\":0.4}"
done
PAY=$(python3 -I -c '
import json, sys
load = json.loads("[" + sys.argv[1] + "]")
rows = [{"kind": "state", "db_instance": "proof-pi-1", "resource_id": "db-PROOFRESOURCE0000000001", "enabled": True, "retention_days": 7, "hours_read": 3}] + load + [
  {"kind": "sql", "tokenized_id": "tok-orders", "db_id": "-7311894518563218402", "query": sys.argv[3], "statement": sys.argv[2], "text_status": "AVAILABLE", "sql_id": "sql-orders-a"},
  {"kind": "sql", "tokenized_id": "tok-accounts", "db_id": "pi-2372568224", "query": "UPDATE accounts SET balance = balance + $1 WHERE id = $2", "text_status": "whole"}]
print(json.dumps(rows).replace("\x27", "\x27\x27"))' "$LOAD" "$WHOLE" "$DIGEST")
q "select pgvigil.import_pi($PI, now(), '$PAY'::jsonb)" >/dev/null
q "select pgvigil.import_pi($OFF, now(), '[{\"kind\":\"state\",\"db_instance\":\"proof-off\",\"enabled\":false,\"note\":\"Performance Insights is off on proof-off\"}]'::jsonb)" >/dev/null

SRV=$BIN
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
start_serve() {
  "$SRV" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
  for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
  kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
}
start_serve
FROM=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)
SERVER="routed in this build"
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/pi?instance=$PI&from=$FROM")" = 404 ]; then
  # the routes are the join's: prove the endpoints in a scratch copy with the wiring block's two lines applied
  kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=
  tar --exclude=./web/node_modules --exclude=./bin --exclude=./.git -cf - . | tar -C "$SCRATCH" -xf -
  grep -q 'api.HandleFunc("GET /api/io", s.IO)' "$SCRATCH/internal/web/web.go" || fail "the anchor line of the wiring is gone from web.go"
  sed -i 's|^\(\t*\)api.HandleFunc("GET /api/io", s.IO)$|&\n\1api.HandleFunc("GET /api/pi", s.PILoad)\n\1api.HandleFunc("GET /api/capacity", s.Capacity)|' "$SCRATCH/internal/web/web.go"
  (cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$SCRATCH/pgvigil-wired" ./cmd/pgvigil) || fail "the scratch build with the routes"
  SRV="$SCRATCH/pgvigil-wired"; SERVER="routed in a scratch build (the join wires them)"
  start_serve
fi
api() { local code; code=$(curl -s -o "$LOG.body" -w '%{http_code}' "$U/api/$1"); [ "$code" = 200 ] || fail "/api/$1 answered $code: $(cat "$LOG.body")"; cat "$LOG.body"; }
api "pi?instance=$PI&from=$FROM" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
n = {k: len((d.get(k) or {}).get("rows") or []) for k in ("state", "total", "waits", "sql", "findings")}
print("api/pi proof-pi rows:", n)
assert all(k in d for k in n), "parts missing"
row = lambda k, i=0: dict(zip(d[k]["columns"], d[k]["rows"][i]))
assert row("state")["enabled"] is True, row("state")
assert n["total"] == 3 and n["waits"] == 9 and n["sql"] == 2, n
s = row("sql")
assert s["tokenized_id"] == "tok-orders" and s["share_pct"] == 70.0 and len(s["full_text"]) == 694 and s["text_status"] == "AVAILABLE", s
print("top SQL:", s["tokenized_id"], s["share_pct"], "% of the load,", s["avg_sessions"], "sessions,", len(s["full_text"]), "bytes of whole text")
' || fail "/api/pi proof-pi"
api "pi?instance=$OFF&from=$FROM" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
st = dict(zip(d["state"]["columns"], d["state"]["rows"][0]))
assert st["enabled"] is False and "off" in st["note"], st
assert not d["total"]["rows"], d["total"]
print("api/pi proof-pioff: enabled false, no hour:", st["note"])
' || fail "/api/pi proof-pioff"
api "capacity?instance=$FLO&from=$FROM" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
n = {k: len((d.get(k) or {}).get("rows") or []) for k in ("scaling", "series", "latest", "findings")}
print("api/capacity proof-floor rows:", n)
sc = dict(zip(d["scaling"]["columns"], d["scaling"]["rows"][0]))
assert sc["min_acu"] == 0.5 and sc["max_acu"] == 16, sc
assert n["series"] >= 1 and n["latest"] == 5 and n["findings"] == 1, n
' || fail "/api/capacity proof-floor"
api "capacity?instance=$OFF&from=$FROM" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert not d["scaling"]["rows"] and not d["series"]["rows"], d
print("api/capacity proof-pioff: no range, no series")
' || fail "/api/capacity proof-pioff"
kill "$SRVPID" 2>/dev/null || true; SRVPID=
echo "server: OK ($SERVER)"

[[ "${LIVE:-0}" == 1 ]] || { echo "proof-pi: OK (recorded, rules, server; LIVE=1 for the lab cluster's CloudWatch side)"; exit 0; }

echo "--- live: $CLUSTER ($PROFILE, $REGION)"
H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE" --region "$REGION") \
  || fail "the lab's AWS login (aws login --profile $PROFILE is Allen's): live not proven"
[ -n "$H" ] && [ "$H" != None ] || fail "no writer endpoint for $CLUSTER"
TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE" --region "$REGION")
export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=60 password=$TOKEN"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: lab-aurora-writer
    dsn: env:AURORA_DSN
    aws: {region: $REGION, profile: $PROFILE, cluster: $CLUSTER}
EOF
live_read() {
  "$BIN" collect -config "$CFG" -once instance >/dev/null   # wakes a paused Serverless v2 cluster (about 15 s)
  "$BIN" collect -config "$CFG" -once serverless
  LID=$(q "select instance_id from pgvigil.instances where name = 'lab-aurora-writer'")
  q "select collection || ': ' || status || coalesce(' (' || note || ')', '') from pgvigil.collection_dates where instance_id = $LID and collection in ('pi', 'serverless') order by 1"
  q "select metric || ': ' || count(*) || ' datapoint(s), newest ' || max(snapshot_at) || ', last ' || (array_agg(value order by snapshot_at desc))[1] from pgvigil.serverless_sample where instance_id = $LID group by metric order by 1"
  q "select 'range: ' || coalesce(cluster, '?') || ' ' || coalesce(class, '?') || ' min ' || coalesce(min_acu::text, '?') || ' max ' || coalesce(max_acu::text, '?') || coalesce(' (' || note || ')', '') from pgvigil.serverless_scaling where instance_id = $LID"
}
"$BIN" collect -config "$CFG" -once instance >/dev/null
"$BIN" collect -config "$CFG" -once pi
live_read
[ "$(q "select status from pgvigil.collection_dates where instance_id = $LID and collection = 'pi'")" = ok ] || fail "pi not ok on the lab cluster"
q "select 'pi_state: enabled ' || enabled || coalesce(', ' || note, '') from pgvigil.pi_state where instance_id = $LID"
[ "$(q "select enabled from pgvigil.pi_state where instance_id = $LID")" = f ] || echo "NOTE: PI is ON on the lab now: pi_load rows $(q "select count(*) from pgvigil.pi_load where instance_id = $LID")"
[ "$(q "select status from pgvigil.collection_dates where instance_id = $LID and collection = 'serverless'")" = ok ] || fail "serverless not ok on the lab cluster"
[ "$(q "select cluster || '|' || min_acu || '|' || max_acu from pgvigil.serverless_scaling where instance_id = $LID")" = "$CLUSTER|0|4" ] \
  || echo "NOTE: the range differs from the lab's documented 0..4 ACU: $(q "select min_acu || '..' || max_acu from pgvigil.serverless_scaling where instance_id = $LID")"
echo "live: waiting $WAIT s with the cluster awake (one read a minute keeps it from pausing)"
end=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$end" ]; do
  psql "$AURORA_DSN" -XAtq -c "select count(*) from pg_class" >/dev/null 2>&1 || true
  sleep 60
done
TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE" --region "$REGION")
export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=60 password=$TOKEN"
live_read
have() { [ "$(q "select count(*) from pgvigil.serverless_sample where instance_id = $LID and metric = '$1'")" -ge 1 ]; }
if have ServerlessDatabaseCapacity && have ACUUtilization && have BufferCacheHitRatio; then
  echo "live: the three Serverless metrics answer"
elif q "select note from pgvigil.serverless_scaling where instance_id = $LID" | grep -q '^paused'; then
  echo "live: ServerlessDatabaseCapacity 0 over the window: the instance was paused (stated)"
else
  fail "neither the three Serverless metrics nor the paused shape (capacity 0)"
fi
echo "proof-pi: OK (recorded, rules, server, live)"
