#!/usr/bin/env bash
# Proof of the logs collection on the AWS lab: seeds on the Aurora writer a slow statement (pg_sleep 0.7 s,
# over log_min_duration_statement 500 ms), a lock wait and a deadlock (two sessions on a scratch table,
# dropped after), and a failed login (a bad IAM token); then runs `collect -once logs` until CloudWatch
# has delivered them. Needs the lab's postgresql log export on (log_min_duration_statement=500,
# log_lock_waits=1) and an active `aws login --profile <profile>`.
#   PGVIGIL_REPO_DSN   repository;  AWS_PROFILE default dba-lab;  CLUSTER default dba-lab-pg
# Expected: log_events for the instance holds the marked slow statement (>= 700 ms), a lock_wait and a
# deadlock naming the scratch table (and, with AUTH_FAIL_EXPECTED=1, a failed login), all after the seed
# time; a second collect adds no row; the cursor is at or after the seed time.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
PROFILE=${AWS_PROFILE:-dba-lab}; CLUSTER=${CLUSTER:-dba-lab-pg}; DBUSER=postgres
TAG="pgvigil_proof_$RANDOM"; CFG=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE")
TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username "$DBUSER" --profile "$PROFILE")
LAB="host=$H port=5432 user=$DBUSER dbname=postgres sslmode=require connect_timeout=60"
L() { PGPASSWORD=$TOKEN psql "$LAB" -XAtq -v ON_ERROR_STOP=1 "$@"; }
cleanup() { rm -f "$CFG"; L -c "drop table if exists $TAG" >/dev/null 2>&1 || true; }
trap cleanup EXIT
export AURORA_DSN="$LAB password=$TOKEN"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: lab-aurora-writer
    dsn: env:AURORA_DSN
    aws: {region: us-east-2, profile: $PROFILE, cluster: $CLUSTER}
EOF
"$BIN" migrate -config "$CFG" >/dev/null
L -c "select 1" >/dev/null                                   # wakes a paused Serverless v2 writer
SEED=$(L -c "select to_char(now() at time zone 'UTC' - interval '2 seconds', 'YYYY-MM-DD HH24:MI:SS')")
L -c "/* $TAG */ select pg_sleep(0.7)" >/dev/null
L -c "create table $TAG (id int primary key, v int); insert into $TAG values (1, 0), (2, 0)"
( L -c "begin; update $TAG set v = 1 where id = 1; select pg_sleep(3); update $TAG set v = 1 where id = 2; commit" >/dev/null 2>&1 || true ) &
A=$!
sleep 0.2
( L -c "begin; update $TAG set v = 2 where id = 2; select pg_sleep(0.5); update $TAG set v = 2 where id = 1; commit" >/dev/null 2>&1 || true ) &
B=$!
wait $A $B
PGPASSWORD=not-a-token psql "$LAB" -XAtq -c "select 1" >/dev/null 2>&1 && fail "the bad token logged in" || true
echo "seeded at $SEED UTC as $TAG; waiting for CloudWatch"
"$BIN" collect -config "$CFG" -once instance >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='lab-aurora-writer'")
c() { q "select count(*) from pgvigil.log_events where instance_id=$iid and snapshot_at >= '$SEED+00' and $1"; }
for i in $(seq 1 18); do
  "$BIN" collect -config "$CFG" -once logs >/dev/null || fail "collect logs"
  [[ $(c "kind='slow' and statement like '%$TAG%'") -ge 1 && $(c "kind='deadlock'") -ge 1 ]] && break
  sleep 10
done
SLOW=$(c "kind='slow' and statement like '%$TAG%' and duration_ms >= 700"); LW=$(c "kind='lock_wait' and statement like '%$TAG%'")
DL=$(c "kind='deadlock' and (detail like '%$TAG%' or statement like '%$TAG%')"); AF=$(c "kind='auth_fail'")
echo "slow=$SLOW lock_wait=$LW deadlock=$DL auth_fail=$AF"
[[ $SLOW -ge 1 && $LW -ge 1 && $DL -ge 1 ]] || fail "missing events"
# an IAM-only cluster (the lab) logs no FATAL for a bad token: the failure stays in rdsauthproxy's lines,
# so auth_fail is graded only where password logins exist (AUTH_FAIL_EXPECTED=1)
if [[ "${AUTH_FAIL_EXPECTED:-0}" == 1 ]]; then [[ $AF -ge 1 ]] || fail "no auth_fail"; else echo "auth_fail not graded: IAM-only cluster"; fi
N1=$(c "true"); "$BIN" collect -config "$CFG" -once logs >/dev/null; N2=$(c "true")
[[ "$N1" == "$N2" ]] || fail "a re-read added rows: $N1 -> $N2"
CUR=$(q "select read_to >= '$SEED+00' from pgvigil.log_cursor where instance_id=$iid")
[[ "$CUR" == t ]] || fail "cursor behind the seed"
q "select kind, coalesce(round(duration_ms)::text, '-'), left(coalesce(statement, detail), 90) from pgvigil.log_events where instance_id=$iid and snapshot_at >= '$SEED+00' order by snapshot_at, kind"
echo "proof-logs: OK ($N2 events since the seed, re-read added none)"
