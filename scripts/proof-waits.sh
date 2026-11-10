#!/usr/bin/env bash
# Proof of the waits collection, the Waits tab's statements, the lock tree and the pg_stat_monitor statements source
# (migration 0030, task 41). Four parts:
#   A. pg_wait_sampling: a throwaway PostgreSQL 18 container (the image pgvigil-gurus:18, built here when absent, with
#      pg_wait_sampling and pg_stat_monitor preloaded and no pg_stat_statements), read by a pg_monitor-only login.
#   B. the fallback on the sandbox (no pg_wait_sampling): the collection skipped with its reason, the Waits tab's
#      statements reading the activity samples, and the lock tree of a held lock.
#   C. pg_stat_monitor as the statements source, in A's container.
#   D. import_waits and its pgms_wait_sampling path on seeded imports (no Azure server here: the live pgms read is
#      NOT PROVEN, and the proof says so).
#   A and C print "NOT PROVEN (A/C): ..." when docker or the image build is not available here.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database, a table, a
#                      pg_monitor login and a container, all with a random suffix, and drops them at the end.
#
# Expected (written before the first run):
#  A. collect -once waits (1): status ok, wait_profile_current > 0 rows, no wait_sample row (the first read is the
#     baseline). A 2 s pg_sleep and a lock wait of about 2 s (a session holding ACCESS EXCLUSIVE for 3 s), then
#     collect -once waits (2): wait_sample rows all source pg_wait_sampling, interval_secs 3..60, every wait_secs =
#     samples x 0.01 (profile_period 10 ms); Timeout:PgSleep >= 150 samples, Lock:relation >= 100 samples. The Waits
#     statements (TestWaitsSQLLive) list 'pg_wait_sampling Timeout:PgSleep' and 'pg_wait_sampling Lock:relation'.
#  B. collect -once waits on the sandbox: status skipped, the note starts 'neither pg_wait_sampling nor
#     pgms_wait_sampling'. A session idle in a transaction holding a lock, a session waiting on it, and a pg_sleep(8);
#     two collect -once activity 2 s apart. The Waits statements read source 'activity' with Timeout:PgSleep >= 2 and
#     Lock:relation >= 2 samples; the lock tree of the holder and the waiter is exactly
#       1 <holder> 1 idle in transaction Client:ClientRead
#       2 <waiter> 0 waiting Lock:relation
#  C. in A's container: collect -once statements is skipped ('pg_stat_statements is not installed ...');
#     collect -once statements_monitor runs (status ok). 20 runs of a marked statement, a wait past the 2 s bucket,
#     collect: statements_delta for its queryid sums to 20 calls and statements_monitor_total to 20; 5 more, wait,
#     collect: the delta rows sum to 25, statements_current calls 25; one more collect with no new bucket adds no
#     delta row for it.
#  D. a scratch instance: baseline {Activity:X q1 100}, then at +60 s {X q1 150, Y q2 30} -> rows X 50 and Y 30 with
#     wait_secs 0.5 and 0.3; at +120 s {X q1 20} (a reset) -> X 20; the same import again at +120 s adds nothing; at
#     +180 s {X q1 25, Y q2 5} -> X 5 and Y 5 (Y left the profile at +120 s and starts again). Two pgms buckets ->
#     2 rows source pgms_wait_sampling, wait_secs NULL; imported twice -> still 2 rows.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_waitproof_$SUF; MON=pgvigil_waitmon_$SUF; MONPW=p$RANDOM$RANDOM; LK=pgvigil_waitlk_$SUF
IMAGE=${GURUS_IMAGE:-pgvigil-gurus:18}; CTR=pgvigil-waitproof-$SUF
CFG=$(mktemp); BUILD=$(mktemp -d)
cleanup() {
  rm -rf "$CFG" "$BUILD"
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop table if exists public.$LK" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
export SBX_DSN="$ADMIN_DSN user=$MON password=$MONPW"
CTR_UP=0

if command -v docker >/dev/null 2>&1; then
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    cat > "$BUILD/Dockerfile" <<'EOF'
FROM postgres:18
RUN apt-get update -qq && apt-get install -y -qq postgresql-18-pg-wait-sampling postgresql-18-hypopg postgresql-18-pg-qualstats >/dev/null \
 && apt-get install -y -qq git make gcc libkrb5-dev postgresql-server-dev-18 >/dev/null \
 && git clone -q --depth 1 https://github.com/percona/pg_stat_monitor /tmp/pgsm && make -s -C /tmp/pgsm USE_PGXS=1 && make -s -C /tmp/pgsm USE_PGXS=1 install \
 && apt-get purge -y -qq git make gcc libkrb5-dev postgresql-server-dev-18 >/dev/null && rm -rf /tmp/pgsm /var/lib/apt/lists/*
EOF
    docker build -q -t "$IMAGE" "$BUILD" >/dev/null 2>&1 || echo "NOT PROVEN (A/C): the extension image did not build here"
  fi
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    PW=p$RANDOM$RANDOM
    docker run -d --name "$CTR" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1::5432 "$IMAGE" \
      -c shared_preload_libraries=pg_wait_sampling,pg_stat_monitor -c pg_stat_monitor.pgsm_bucket_time=2 >/dev/null
    PORT=$(docker port "$CTR" 5432/tcp | head -1 | sed 's/.*://')
    C="host=127.0.0.1 port=$PORT user=postgres password=$PW dbname=postgres"
    for _ in $(seq 60); do psql "$C" -XAtqc "select 1" >/dev/null 2>&1 && { CTR_UP=1; break; }; sleep 1; done
    [[ $CTR_UP == 1 ]] || fail "the container did not start"
    psql "$C" -XAq -v ON_ERROR_STOP=1 -c "create extension pg_wait_sampling; create extension pg_stat_monitor" \
      -c "create role mon login password '$PW' in role pg_monitor; create table lk (id int)" >/dev/null
    export CTR_DSN="host=127.0.0.1 port=$PORT user=mon password=$PW dbname=postgres sslmode=disable"
  fi
else
  echo "NOT PROVEN (A/C): no docker on this machine"
fi

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-waits-sbx-$SUF
    dsn: env:SBX_DSN
EOF
if [[ $CTR_UP == 1 ]]; then cat >> "$CFG" <<EOF
  - name: proof-waits-ext-$SUF
    dsn: env:CTR_DSN
EOF
fi
"$BIN" migrate -config "$CFG" >/dev/null
once() { "$BIN" collect -config "$CFG" -once "$1" 2>&1 | grep -E "$2" || true; }

if [[ $CTR_UP == 1 ]]; then
  echo "--- A. pg_wait_sampling"
  once waits "proof-waits-ext"
  eid=$(q "select instance_id from pgvigil.instances where name='proof-waits-ext-$SUF'")
  [[ $(q "select status from pgvigil.collection_dates where instance_id=$eid and collection='waits'") == ok ]] || fail "waits status (1): $(q "select status, note from pgvigil.collection_dates where instance_id=$eid and collection='waits'")"
  [[ $(q "select count(*) > 0 from pgvigil.wait_profile_current where instance_id=$eid") == t ]] || fail "no profile baseline"
  [[ $(q "select count(*) from pgvigil.wait_sample where instance_id=$eid") == 0 ]] || fail "rows on the first read"
  (psql "$C" -XAq -c "begin; lock table lk in access exclusive mode; select pg_sleep(3); commit" >/dev/null 2>&1 &)
  sleep 0.5
  (psql "$C" -XAq -c "select count(*) from lk" >/dev/null 2>&1 &)
  psql "$C" -XAq -c "select pg_sleep(2)" >/dev/null
  sleep 2
  once waits "proof-waits-ext"
  echo "wait_sample:"; q "select event_type || ':' || event, sum(samples), round(sum(wait_secs)::numeric, 2) from pgvigil.wait_sample where instance_id=$eid group by 1 order by 2 desc limit 8"
  [[ $(q "select count(*) from pgvigil.wait_sample where instance_id=$eid and (source <> 'pg_wait_sampling' or interval_secs not between 3 and 60 or abs(wait_secs - samples * 0.01) > 1e-9)") == 0 ]] || fail "source / interval / wait_secs"
  [[ $(q "select coalesce(sum(samples), 0) >= 150 from pgvigil.wait_sample where instance_id=$eid and event_type='Timeout' and event='PgSleep'") == t ]] || fail "PgSleep samples"
  [[ $(q "select coalesce(sum(samples), 0) >= 100 from pgvigil.wait_sample where instance_id=$eid and event_type='Lock' and event='relation'") == t ]] || fail "Lock:relation samples"
  PGVIGIL_WAITS_REPO_DSN="$PGVIGIL_REPO_DSN" WAITS_INSTANCE=$eid WAITS_EXPECT=$'^pg_wait_sampling Timeout:PgSleep \\d+$\n^pg_wait_sampling Lock:relation \\d+$' \
    go test ./internal/web -run TestWaitsSQLLive -count=1 >/dev/null || fail "the Waits statements on the extension's rows"
fi

echo "--- B. the fallback on the sandbox"
once waits "proof-waits-sbx"
sid=$(q "select instance_id from pgvigil.instances where name='proof-waits-sbx-$SUF'")
st=$(q "select status || '|' || note from pgvigil.collection_dates where instance_id=$sid and collection='waits'")
[[ $st == "skipped|neither pg_wait_sampling nor pgms_wait_sampling"* ]] || fail "waits on the sandbox: $st"
psql "$ADMIN_DSN" -XAq -c "create table public.$LK (id int)"
( { echo "set application_name = 'pgvigil-proof-holder-$SUF'; begin; lock table public.$LK in access exclusive mode;"; sleep 8; echo "commit;"; } | psql "$ADMIN_DSN" -XAq >/dev/null 2>&1 & )
sleep 0.7
(psql "$ADMIN_DSN" -XAq -c "set application_name = 'pgvigil-proof-waiter-$SUF'" -c "select count(*) from public.$LK" >/dev/null 2>&1 &)
(psql "$ADMIN_DSN" -XAq -c "set application_name = 'pgvigil-proof-sleeper-$SUF'" -c "select pg_sleep(8)" >/dev/null 2>&1 &)
sleep 1
HOLDER=$(psql "$ADMIN_DSN" -XAtc "select pid from pg_stat_activity where application_name = 'pgvigil-proof-holder-$SUF'")
WAITER=$(psql "$ADMIN_DSN" -XAtc "select pid from pg_stat_activity where application_name = 'pgvigil-proof-waiter-$SUF'")
[[ -n $HOLDER && -n $WAITER ]] || fail "holder / waiter not seen"
once activity "proof-waits-sbx"; sleep 2; once activity "proof-waits-sbx"
PGVIGIL_WAITS_REPO_DSN="$PGVIGIL_REPO_DSN" WAITS_INSTANCE=$sid \
  WAITS_EXPECT=$'^activity Timeout:PgSleep ([2-9]|\\d\\d+)$\n^activity Lock:relation ([2-9]|\\d\\d+)$' \
  WAITS_TREE_PIDS="$HOLDER $WAITER" WAITS_TREE=$'1 '"$HOLDER"$' 1 idle in transaction Client:ClientRead\n2 '"$WAITER"$' 0 waiting Lock:relation' \
  go test ./internal/web -run TestWaitsSQLLive -count=1 -v 2>&1 | grep -E 'activity|^\s+[12] |FAIL|ok ' || true
PGVIGIL_WAITS_REPO_DSN="$PGVIGIL_REPO_DSN" WAITS_INSTANCE=$sid \
  WAITS_EXPECT=$'^activity Timeout:PgSleep ([2-9]|\\d\\d+)$\n^activity Lock:relation ([2-9]|\\d\\d+)$' \
  WAITS_TREE_PIDS="$HOLDER $WAITER" WAITS_TREE=$'1 '"$HOLDER"$' 1 idle in transaction Client:ClientRead\n2 '"$WAITER"$' 0 waiting Lock:relation' \
  go test ./internal/web -run TestWaitsSQLLive -count=1 >/dev/null || fail "the Waits statements on the activity samples / the lock tree"

if [[ $CTR_UP == 1 ]]; then
  echo "--- C. pg_stat_monitor as the statements source"
  once statements "proof-waits-ext"
  [[ $(q "select status || '|' || note from pgvigil.collection_dates where instance_id=$eid and collection='statements'") == "skipped|pg_stat_statements is not installed"* ]] || fail "statements not skipped"
  once statements_monitor "proof-waits-ext"
  [[ $(q "select status from pgvigil.collection_dates where instance_id=$eid and collection='statements_monitor'") == ok ]] || fail "statements_monitor status: $(q "select note from pgvigil.collection_dates where instance_id=$eid and collection='statements_monitor'")"
  for _ in $(seq 20); do psql "$C" -XAtqc "select 4141 + count(*) from pg_class where relname = 'pgvigil_marker'" >/dev/null; done
  sleep 4.5
  once statements_monitor "proof-waits-ext"
  QID=$(q "select queryid from pgvigil.statements_monitor_total where instance_id=$eid and query like '%4141%' limit 1")
  [[ -n $QID ]] || fail "the marked statement is not in statements_monitor_total"
  d() { q "select coalesce(sum(calls), 0) || '/' || count(*) from pgvigil.statements_delta where instance_id=$eid and queryid=$QID"; }
  echo "delta calls/rows: $(d); total: $(q "select calls from pgvigil.statements_monitor_total where instance_id=$eid and queryid=$QID")"
  [[ $(d) == 20/* && $(q "select calls from pgvigil.statements_monitor_total where instance_id=$eid and queryid=$QID") == 20 ]] || fail "after 20 runs: $(d)"
  for _ in $(seq 5); do psql "$C" -XAtqc "select 4141 + count(*) from pg_class where relname = 'pgvigil_marker'" >/dev/null; done
  sleep 4.5
  once statements_monitor "proof-waits-ext"
  rows_before=$(d)
  echo "delta calls/rows: $rows_before; current: $(q "select calls from pgvigil.statements_current where instance_id=$eid and queryid=$QID")"
  [[ $rows_before == 25/* && $(q "select calls from pgvigil.statements_current where instance_id=$eid and queryid=$QID") == 25 ]] || fail "after 25 runs: $rows_before"
  once statements_monitor "proof-waits-ext"
  [[ $(d) == "$rows_before" ]] || fail "a read with no new bucket added a delta: $(d)"
fi

echo "--- D. import_waits on seeded imports"
x=$(q "insert into pgvigil.instances (name, platform) values ('proof-waits-x-$SUF', 'onprem') returning instance_id" | head -1)
imp() { q "select pgvigil.import_waits($x, '2026-11-01 00:00:00+00'::timestamptz + interval '$1 seconds', '$2'::jsonb)" >/dev/null; }
P='{"kind":"period","ms":10}'
imp 0   "[$P,{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"X\",\"queryid\":1,\"count\":100}]"
imp 60  "[$P,{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"X\",\"queryid\":1,\"count\":150},{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"Y\",\"queryid\":2,\"count\":30}]"
imp 120 "[$P,{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"X\",\"queryid\":1,\"count\":20}]"
imp 120 "[$P,{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"X\",\"queryid\":1,\"count\":20}]"
imp 180 "[$P,{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"X\",\"queryid\":1,\"count\":25},{\"kind\":\"profile\",\"event_type\":\"Activity\",\"event\":\"Y\",\"queryid\":2,\"count\":5}]"
got=$(q "select string_agg(extract(epoch from snapshot_at - '2026-11-01 00:00:00+00')::int || ' ' || event || ' ' || samples || ' ' || wait_secs, ',' order by snapshot_at, event) from pgvigil.wait_sample where instance_id=$x")
echo "seeded: $got"
[[ $got == "60 X 50 0.5,60 Y 30 0.3,120 X 20 0.2,180 X 5 0.05,180 Y 5 0.05" ]] || fail "seeded profile rows"
G='[{"kind":"pgms","start_time":"2026-11-01 01:00:00+00","end_time":"2026-11-01 01:15:00+00","event_type":"IO","event":"DataFileRead","queryid":7,"calls":40},{"kind":"pgms","start_time":"2026-11-01 01:15:00+00","end_time":"2026-11-01 01:30:00+00","event_type":"IO","event":"DataFileRead","queryid":7,"calls":12}]'
q "select pgvigil.import_waits($x, now(), '$G')" >/dev/null; q "select pgvigil.import_waits($x, now(), '$G')" >/dev/null
[[ $(q "select count(*) || ' ' || sum(samples) || ' ' || count(wait_secs) from pgvigil.wait_sample where instance_id=$x and source='pgms_wait_sampling'") == "2 52 0" ]] || fail "pgms rows"
echo "NOT PROVEN (D, live): the pgms_wait_sampling read against an Azure flexible server (none here); its import is proven above"
q "delete from pgvigil.instances where instance_id=$x" >/dev/null
echo "PROOF OK"
