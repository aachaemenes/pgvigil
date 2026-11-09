#!/usr/bin/env bash
# Proof of the IO work (task 43) on a throwaway repository database. Four parts:
#   recorded (always): the io collector and the DMS replication instance IO from the responses in
#                      internal/collect/testdata/io (the lab Aurora cluster's answer, recorded paused; a
#                      synthetic IO-bound DMS instance: the lab's plan has none) fill the repository
#                      (go test TestIO* TestDms*).
#   rules (always):    seeded rows through import_io, import_dms and import_dbstats raise exactly the expected
#                      io_findings rows, and a datapoint read twice is stored once.
#   server (always):   the sandbox itself is collected (instance, dbstats, iostats, statements) twice; the IO
#                      endpoint (when the build serves /api/io) answers every part, pg_stat_io rates included.
#   live (LIVE=1):     the lab's Aurora cluster is woken through its IAM door and `collect -once io` reads its
#                      CloudWatch rows; WAIT seconds later (default 420: the instance metrics need a 5-minute
#                      period awake) a second read; read only on the cluster.
#   PGVIGIL_ADMIN_DSN  keyword-form connection without dbname, a login that may create a database (the proof
#                      makes pgvigil_proof_io_<n> and drops it at the end)
#   SANDBOX_DSN        the monitored sandbox (default: PGVIGIL_ADMIN_DSN dbname=sandbox)
#   AWS_PROFILE default dba-lab; AWS_REGION default us-east-2; CLUSTER default dba-lab-pg; WAIT default 420
# Expected:
#   recorded  TestIORowsAuroraRecorded, TestIOTargets, TestIOGateAndApplies, TestDmsIOMetrics, TestIOFixtureImport
#             and the TestDms* tests PASS
#   rules     io_findings rows (instance|setting|severity), exactly:
#               proof-rds|BurstBalance|warning  proof-rds|EBSIOBalance%|critical  proof-rds|DiskQueueDepth|warning
#               proof-rds|ReadLatency|warning   proof-rds|DMS DiskQueueDepth|warning  proof-rds|DMS WriteLatency|warning
#               proof-onprem|checkpoints requested|warning
#             none for proof-aurora (calm metrics, and its forced checkpoints are not judged on Aurora);
#             EBSByteBalance% at 50 % and the DMS read latency at 4.1 ms raise nothing; the two datapoints
#             imported twice are 2 rows, the revised one holds the second value
#   server    collection_dates ok for iostats and dbstats on the sandbox (PostgreSQL 16+); /api/io answers
#             state, pgio (>= 1 rate row), pgio_by (>= 1 row), dbtime, checkpoints, statements, findings,
#             platform_latest and platform (0 rows: an on-premises sandbox has no CloudWatch side);
#             /api/dmsio answers instances and series
#   live      collection_dates io ok; cloud_io_sample holds VolumeReadIOPs and VolumeWriteIOPs rows for the
#             cluster; AuroraVolumeBytesLeftTotal has none (read, NULL: AWS documents it for Aurora MySQL); after
#             WAIT, ReadIOPS, ReadLatency and DiskQueueDepth rows too (the instance was awake a full period)
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
SANDBOX_DSN=${SANDBOX_DSN:-"$PGVIGIL_ADMIN_DSN dbname=sandbox"}
PROFILE=${AWS_PROFILE:-dba-lab}; REGION=${AWS_REGION:-us-east-2}; CLUSTER=${CLUSTER:-dba-lab-pg}; WAIT=${WAIT:-420}
DB=pgvigil_proof_io_$RANDOM
CFG=$(mktemp); LOG=$(mktemp); SRVPID=
cleanup() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  rm -f "$CFG" "$LOG"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
export SANDBOX_DSN
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

echo "--- recorded responses -> repository"
out=$(go test ./internal/collect -run 'TestIO|TestDms' -count=1 -v 2>&1) || { echo "$out" | tail -30; fail "recorded-response tests"; }
echo "$out" | grep -E '^--- ' || true
for t in TestIORowsAuroraRecorded TestIOTargets TestIOGateAndApplies TestDmsIOMetrics TestIOFixtureImport TestDmsFixtureImport; do
  echo "$out" | grep -q -- "--- PASS: $t " || fail "$t did not pass"
done
echo "recorded: OK"

echo "--- rules: seeded rows through the import functions"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
RDS=$(q "select pgvigil.ensure_instance('proof-rds', 'rds', '16.4', 160004, false, '{proof}')")
AUR=$(q "select pgvigil.ensure_instance('proof-aurora', 'aurora', '17.4', 170004, false, '{proof}')")
ONP=$(q "select pgvigil.ensure_instance('proof-onprem', 'onprem', '18.0', 180000, false, '{proof}')")
metric() { # instance source metric unit value minutes-ago
  printf '{"kind":"metric","source":"%s","dim":"proof","metric":"%s","stat":"Average","unit":"%s","value":%s,"at":"%s"}' \
    "$1" "$2" "$3" "$4" "$(date -u -d "-$5 minutes" +%Y-%m-%dT%H:%M:00Z)"
}
q "select pgvigil.import_io($RDS, now(), '[
 $(metric rds BurstBalance percent 12 10), $(metric rds EBSIOBalance% percent 3 10), $(metric rds EBSByteBalance% percent 50 10),
 $(metric rds DiskQueueDepth count 15 10), $(metric rds DiskQueueDepth count 13 5),
 $(metric rds ReadLatency s 0.025 10), $(metric rds ReadIOPS count/s 900 10)]'::jsonb)" >/dev/null
q "select pgvigil.import_io($AUR, now(), '[$(metric aurora DiskQueueDepth count 2 10), $(metric aurora ReadLatency s 0.001 10)]'::jsonb)" >/dev/null
# the same two datapoints again, one revised: two rows stay, the revised value wins
q "select pgvigil.import_io($AUR, now(), '[$(metric aurora DiskQueueDepth count 2.5 10), $(metric aurora ReadLatency s 0.001 10)]'::jsonb)" >/dev/null
[ "$(q "select count(*) || '|' || max(value) filter (where metric = 'DiskQueueDepth') from pgvigil.cloud_io_sample where instance_id = $AUR")" = "2|2.5" ] \
  || fail "a re-read window: $(q "select metric || '=' || value from pgvigil.cloud_io_sample where instance_id = $AUR")"
RI='arn:aws:dms:us-east-2:123456789012:rep:PROOFIO'
q "select pgvigil.import_dms($RDS, now(), '[{\"kind\":\"ri\",\"ri_arn\":\"$RI\",\"ri_id\":\"proof-ri\",\"status\":\"available\",\"allocated_gb\":100,
  \"free_storage_bytes\":53687091200,\"freeable_bytes\":2000000000,\"swap_bytes\":0,\"read_iops\":95,\"write_iops\":2900,
  \"read_latency_ms\":4.1,\"write_latency_ms\":38.5,\"queue_depth\":31,\"metrics_at\":\"$(date -u +%Y-%m-%dT%H:%M:00Z)\"}]'::jsonb)" >/dev/null
for i in 0 1 2; do   # three checkpointer reads, an hour apart: 0 timed and 3 requested per hour
  for id in $ONP $AUR; do
    q "select pgvigil.import_dbstats($id, now() - interval '$((3 - i)) hours', '[{\"kind\":\"server\",\"checkpoints_timed\":5,\"checkpoints_req\":$((10 + 3 * i))}]'::jsonb)" >/dev/null
  done
done
GOT=$(q "select i.name || '|' || f.setting || '|' || f.severity from pgvigil.io_findings f join pgvigil.instances i using (instance_id) where i.instance_id in ($RDS, $AUR, $ONP)" | sort)
WANT=$(printf '%s\n' 'proof-rds|BurstBalance|warning' 'proof-rds|EBSIOBalance%|critical' 'proof-rds|DiskQueueDepth|warning' \
  'proof-rds|ReadLatency|warning' 'proof-rds|DMS DiskQueueDepth|warning' 'proof-rds|DMS WriteLatency|warning' \
  'proof-onprem|checkpoints requested|warning' | sort)
if [[ "$GOT" != "$WANT" ]]; then echo "got:"; echo "$GOT"; echo "want:"; echo "$WANT"; fail "io_findings rows differ"; fi
q "select i.name || ': ' || f.setting || ' = ' || f.value from pgvigil.io_findings f join pgvigil.instances i using (instance_id) where i.instance_id in ($RDS, $AUR, $ONP) order by 1"
echo "rules: OK (7 findings; the calm Aurora instance, the 50 % byte balance, the 4.1 ms DMS read and Aurora's checkpoints raise none)"

echo "--- server: the sandbox's own pg_stat_io and pg_stat_database"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-io-sandbox
    dsn: env:SANDBOX_DSN
    tags: [proof]
EOF
for round in 1 2; do
  for c in instance dbstats iostats statements; do "$BIN" collect -config "$CFG" -once "$c" >/dev/null || true; done
  [ "$round" = 1 ] && { psql "$SANDBOX_DSN" -XAtq -c "select count(*) from pg_class c cross join pg_attribute a" >/dev/null; sleep 2; }
done
SID=$(q "select instance_id from pgvigil.instances where name = 'proof-io-sandbox'")
[ -n "$SID" ] || fail "no sandbox instance row"
q "select collection || ': ' || status || coalesce(' (' || note || ')', '') from pgvigil.collection_dates where instance_id = $SID order by 1"
for c in dbstats iostats; do
  [ "$(q "select status from pgvigil.collection_dates where instance_id = $SID and collection = '$c'")" = ok ] || fail "$c not ok on the sandbox"
done
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
FROM=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
code=$(curl -s -o /dev/null -w '%{http_code}' "$U/api/io?instance=$SID&from=$FROM")
if [ "$code" = 404 ]; then
  echo "server: the IO endpoints are not routed in this build (the wave's join wires /api/io and /api/dmsio): skipped"
else
  body=$(curl -s "$U/api/io?instance=$SID&from=$FROM")
  [ "$code" = 200 ] || fail "/api/io answered $code: $body"
  echo "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
n = {k: len((d.get(k) or {}).get("rows") or []) for k in ("state", "platform_latest", "platform", "pgio", "pgio_by", "dbtime", "checkpoints", "statements", "findings")}
print("api/io rows:", n)
missing = [k for k in n if k not in d]
assert not missing, "parts missing: %s" % missing
assert n["pgio"] >= 1 and n["pgio_by"] >= 1, "no pg_stat_io rates"
assert n["platform"] == 0 and n["platform_latest"] == 0, "CloudWatch rows on an on-premises sandbox"
' || fail "/api/io parts"
  body=$(curl -s "$U/api/dmsio?from=$FROM")
  echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "instances" in d and "series" in d, d; print("api/dmsio rows:", {k: len(d[k]["rows"]) for k in d})' \
    || fail "/api/dmsio: $body"
  echo "server: OK"
fi
kill "$SRVPID" 2>/dev/null || true; SRVPID=

[[ "${LIVE:-0}" == 1 ]] || { echo "proof-io: OK (recorded, rules, server; LIVE=1 for the lab cluster's CloudWatch rows)"; exit 0; }

echo "--- live: $CLUSTER ($PROFILE, $REGION)"
H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE" --region "$REGION")
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
  "$BIN" collect -config "$CFG" -once io
  LID=$(q "select instance_id from pgvigil.instances where name = 'lab-aurora-writer'")
  q "select collection || ': ' || status || coalesce(' (' || note || ')', '') from pgvigil.collection_dates where instance_id = $LID and collection = 'io'"
  q "select metric || ': ' || count(*) || ' datapoint(s), newest ' || max(snapshot_at) from pgvigil.cloud_io_sample where instance_id = $LID group by metric order by 1"
}
live_read
[ "$(q "select status from pgvigil.collection_dates where instance_id = $LID and collection = 'io'")" = ok ] || fail "io not ok on the lab cluster"
for m in VolumeReadIOPs VolumeWriteIOPs; do
  [ "$(q "select count(*) from pgvigil.cloud_io_sample where instance_id = $LID and metric = '$m'")" -ge 1 ] || fail "no $m rows"
done
[ "$(q "select count(*) from pgvigil.cloud_io_sample where instance_id = $LID and metric = 'AuroraVolumeBytesLeftTotal'")" = 0 ] \
  || fail "AuroraVolumeBytesLeftTotal rows on Aurora PostgreSQL"
echo "live: waiting $WAIT s with the cluster awake (one read a minute keeps it from pausing)"
end=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$end" ]; do
  psql "$AURORA_DSN" -XAtq -c "select count(*) from pg_class" >/dev/null 2>&1 || true
  sleep 60
done
TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE" --region "$REGION")
export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=60 password=$TOKEN"
live_read
for m in ReadIOPS ReadLatency DiskQueueDepth; do
  [ "$(q "select count(*) from pgvigil.cloud_io_sample where instance_id = $LID and metric = '$m'")" -ge 1 ] || fail "no $m rows after $WAIT s awake"
done
echo "proof-io: OK (recorded, rules, server, live)"
