#!/usr/bin/env bash
# Proof of the indexes collection, its findings and the index advisor (migration 0030, task 41). Four parts:
#   A. the sandbox: two proof databases seeded with an unused, a redundant, a duplicate pair and an invalid index (and
#      a second database with one invalid index), read by a pg_monitor-only login.
#   B. the same after dropping two of them and the second database.
#   C. the unused rule's window, replica and size marks, and a database in error keeping its rows, on seeded imports.
#   D. the index advisor on a throwaway PostgreSQL 18 container with pg_qualstats and HypoPG (the image pgvigil-gurus:18,
#      built here when absent); "NOT PROVEN (D): ..." when docker or the build is not available here.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database, two target
#                      databases and a pg_monitor login, all with a random suffix, and drops them (and its container)
#                      at the end; nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A. collect -once indexes: status ok. index_databases present for both proof databases. index_state, present rows of
#     the proof databases, exactly:
#       T1 invalid   ix_bad   (the failed CREATE UNIQUE INDEX CONCURRENTLY)
#       T1 redundant ix_a     covered_by ix_ab
#       T1 duplicate one of ix_c1 / ix_c2, covered_by the other
#       T1 unused    ix_unused, and no unused row for ix_a, ix_ab, t_pkey or ix_bad (ix_c1 / ix_c2 may read unused: the
#                    planner picks one of an equal pair; not asserted)
#       T2 invalid   ux_bad, and nothing else in T2
#     every row carries drop_sql 'DROP INDEX CONCURRENTLY ...' and undo_sql 'CREATE ... INDEX CONCURRENTLY ...'.
#     index_findings of the proof databases exactly:
#       duplicate index|warning, invalid index|warning (T1), invalid index|warning (T2), redundant index|info
#     (ix_unused is under 10 MB: no finding).
#  B. DROP INDEX ix_unused and ix_bad in T1, DROP DATABASE T2, collect again: the ix_unused and ix_bad rows is_present
#     false, T2's index_databases row and its ux_bad row is_present false, the T1 redundant and duplicate rows still
#     present with their first_seen unchanged; findings exactly duplicate|warning and redundant|info.
#  C. scratch instances through import_indexes: x (stats since 30 days, primary, unused 20 MB) -> exactly one finding
#     'unused index|info'; y (the same on a replica), z (stats since 2 days), w (30 days, 5 MB) -> no finding; x read
#     again with a collector_error 'indexes:<db>' and no row of that database -> its rows stay present.
#  D. the container, a table t of 200,000 rows and 30 reads 'where a = <n>' with pg_qualstats sampling every statement:
#     as a login IN ROLE pg_monitor, pg_read_all_data the advisor suggests 'CREATE INDEX ON public.t USING btree (a)' and
#     at least one statement uses the hypothetical index with a positive gain; afterwards t has no index at all; as a
#     pg_monitor-only login the same suggestion comes back with its statements noted 'permission denied' and untested.
#  [review C fold, expected before the rerun:]
#  A2. more seeds in T1, read in the same collect: t5 (a, b) with t5_a scanned and t5_ab never -> 'T1 redundant t5_a >
#      t5_ab' and NO unused row for t5_ab (an unused index that covers a listed one is left out); the duplicate pair ->
#      no unused row for the pair's cover; t6 with PRIMARY KEY (a, b) and a UNIQUE index t6_a_uq on (a) -> no row for
#      t6_a_uq at all (unique: never unused; covered only by a wider primary key: not redundant); t3_asc (a, b)
#      and t3_mix (a, b DESC) -> no redundant or duplicate row on t3; a partitioned table q (two partitions) with q_a (a)
#      and q_ab (a, b) -> no redundant row on q or its partitions; a partitioned index p_a built ON ONLY a partitioned
#      table p -> no invalid row for it. Every drop_sql names the schema ('DROP INDEX CONCURRENTLY public.').
#      (So A's findings carry a second 'redundant index|info' row, t5_a's, and B's too: the first fold run missed that.)
#  C2. the unused finding also needs pgvigil to have seen the index unused for 7 days: x is first imported 8 days
#      before its second import (one finding); v (the same as x, one import only) -> no finding.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_ixproof_$SUF; T1=pgvigil_ix1_$SUF; T2=pgvigil_ix2_$SUF; MON=pgvigil_ixmon_$SUF; MONPW=p$RANDOM$RANDOM
IMAGE=${GURUS_IMAGE:-pgvigil-gurus:18}; CTR=pgvigil-ixproof-$SUF
CFG=$(mktemp); BUILD=$(mktemp -d)
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }   # a later keyword wins, in libpq and in pgx
cleanup() {
  rm -rf "$CFG" "$BUILD"
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "create database $d" >/dev/null; done
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
export TGT_DSN; TGT_DSN="$(dsn_for "$T1") user=$MON password=$MONPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$(dsn_for "$T1")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
t2() { psql "$(dsn_for "$T2")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. first read"
t1 "create table t (id int primary key, a int, b int, c int)"
t1 "insert into t select g, g % 5000, g % 77, g % 3000 from generate_series(1, 100000) g"
t1 "create index ix_unused on t (b); create index ix_a on t (a); create index ix_ab on t (a, b); create index ix_c1 on t (c); create index ix_c2 on t (c)"
psql "$(dsn_for "$T1")" -XAtq -c "create unique index concurrently ix_bad on t (a)" >/dev/null 2>&1 && fail "ix_bad should have failed (a is not unique)"
t1 "create table t5 (a int, b int); insert into t5 select g % 3000, g % 7 from generate_series(1, 50000) g; create index t5_a on t5 (a); create index t5_ab on t5 (a, b)"
t1 "create table t6 (a int, b int, primary key (a, b)); insert into t6 select g, g % 7 from generate_series(1, 50000) g; create unique index t6_a_uq on t6 (a)"
t1 "create table t3 (a int, b int); insert into t3 select g % 3000, g % 7 from generate_series(1, 50000) g; create index t3_asc on t3 (a, b); create index t3_mix on t3 (a, b desc)"
t1 "create table q (a int, b int) partition by range (a); create table q1 partition of q for values from (0) to (5000); create table q2 partition of q for values from (5000) to (10000)"
t1 "insert into q select g % 10000, g % 7 from generate_series(1, 50000) g; create index q_a on q (a); create index q_ab on q (a, b)"
t1 "create table p (a int) partition by range (a); create table p1 partition of p for values from (0) to (100); create index p_a on only p (a)"
t1 "analyze t; analyze t5; analyze t6; analyze t3; analyze q"
t2 "create table u (id int, v int); insert into u select g, g % 10 from generate_series(1, 1000) g"
psql "$(dsn_for "$T2")" -XAtq -c "create unique index concurrently ux_bad on u (v)" >/dev/null 2>&1 && fail "ux_bad should have failed"
# use ix_a and ix_ab (each read in its own session: the counters are flushed when it ends)
psql "$(dsn_for "$T1")" -XAtq -c "set enable_seqscan = off; set enable_bitmapscan = off" -c "select count(*) from t where a = 5" >/dev/null
psql "$(dsn_for "$T1")" -XAtq -c "set enable_seqscan = off; set enable_bitmapscan = off" -c "select count(*) from t where a = 5 and b = 5" >/dev/null
psql "$(dsn_for "$T1")" -XAtq -c "set enable_seqscan = off; set enable_bitmapscan = off" -c "select count(*) from t5 where a = 5" >/dev/null
# the counters reach pg_stat_user_indexes shortly after each session ends: wait for them (10 s at most) on a busy sandbox
for _ in $(seq 20); do [[ $(t1 "select count(*) from pg_stat_user_indexes where (indexrelname in ('ix_a','ix_ab','t5_a') and idx_scan = 1)") == 3 ]] && break; sleep 0.5; done
[[ $(t1 "select string_agg(indexrelname || '=' || idx_scan, ',' order by indexrelname) from pg_stat_user_indexes where indexrelname in ('t5_a','t5_ab')") == "t5_a=1,t5_ab=0" ]] || fail "t5 seeding reads: $(t1 "select string_agg(indexrelname || '=' || idx_scan, ',' order by indexrelname) from pg_stat_user_indexes where indexrelname in ('t5_a','t5_ab')")"
[[ $(t1 "select indisvalid from pg_index where indexrelid = 'p_a'::regclass") == f ]] || fail "p_a should be invalid (ON ONLY)"
used=$(t1 "select string_agg(indexrelname || '=' || idx_scan, ',' order by indexrelname) from pg_stat_user_indexes where indexrelname in ('ix_a','ix_ab')")
[[ $used == "ix_a=1,ix_ab=1" ]] || fail "the seeding reads did not use ix_a and ix_ab once each: $used"

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-ix-$SUF
    dsn: env:TGT_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once indexes || fail "collect indexes (run 1)"
iid=$(q "select instance_id from pgvigil.instances where name='proof-ix-$SUF'")
st=$(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='indexes'")
[[ $st == "ok " ]] || fail "status: $st"
[[ $(q "select count(*) from pgvigil.index_databases where instance_id=$iid and is_present and datname in ('$T1','$T2')") == 2 ]] || fail "index_databases"
rows() { q "select string_agg(case when datname = '$T1' then 'T1' else 'T2' end || ' ' || problem || ' ' || index_name || coalesce(' > ' || covered_by, ''), E'\n' order by datname, problem, index_name) from pgvigil.index_state where instance_id=$iid and is_present and datname in ('$T1','$T2') $1"; }
echo "index_state (proof databases):"; rows ""
[[ $(rows "and problem <> 'unused' and problem <> 'duplicate'") == $'T1 invalid ix_bad\nT1 redundant ix_a > public.ix_ab\nT1 redundant t5_a > public.t5_ab\nT2 invalid ux_bad' ]] || fail "invalid / redundant rows"
dup=$(rows "and problem = 'duplicate'")
[[ $dup == "T1 duplicate ix_c1 > public.ix_c2" || $dup == "T1 duplicate ix_c2 > public.ix_c1" ]] || fail "duplicate row: $dup"
cover=${dup##*public.}
[[ $(rows "and problem = 'unused' and index_name in ('ix_unused','ix_a','ix_ab','t_pkey','ix_bad','t5_ab','t6_a_uq','t6_pkey','$cover')") == "T1 unused ix_unused" ]] || fail "unused rows (the cover $cover, t5_ab, t6 must not be unused)"
[[ $(rows "and table_name in ('t3','t6','q','q1','q2','p') and problem <> 'unused'") == "" ]] || fail "rows on t3 / t6 / q / p: $(rows "and table_name in ('t3','t6','q','q1','q2','p') and problem <> 'unused'")"
[[ $(q "select count(*) from pgvigil.index_state where instance_id=$iid and datname in ('$T1','$T2') and drop_sql not like 'DROP INDEX CONCURRENTLY public.%'") == 0 ]] || fail "drop lines without the schema"
[[ $(q "select count(*) from pgvigil.index_state where instance_id=$iid and datname in ('$T1','$T2') and (drop_sql not like 'DROP INDEX CONCURRENTLY %' or undo_sql not like 'CREATE %INDEX CONCURRENTLY %')") == 0 ]] || fail "drop / undo lines"
fnd() { q "select string_agg(setting || '|' || severity || '|' || case when value like '$T1:%' then 'T1' else 'T2' end, ',' order by setting, severity, value) from pgvigil.index_findings where instance_id=$iid and (value like '$T1:%' or value like '$T2:%')"; }
echo "findings: $(fnd)"
[[ $(fnd) == "duplicate index|warning|T1,invalid index|warning|T1,invalid index|warning|T2,redundant index|info|T1,redundant index|info|T1" ]] || fail "findings A"
first_red=$(q "select first_seen from pgvigil.index_state where instance_id=$iid and datname='$T1' and problem='redundant'")

echo "--- B. two indexes and a database dropped"
t1 "drop index ix_unused; drop index ix_bad"
psql "$ADMIN_DSN" -XAtq -c "drop database $T2 with (force)" >/dev/null
sleep 1
"$BIN" collect -config "$CFG" -once indexes || fail "collect indexes (run 2)"
[[ $(q "select count(*) from pgvigil.index_state where instance_id=$iid and datname='$T1' and index_name in ('ix_unused','ix_bad') and is_present") == 0 ]] || fail "dropped indexes still present"
[[ $(q "select is_present from pgvigil.index_databases where instance_id=$iid and datname='$T2'") == f ]] || fail "T2 still present"
[[ $(q "select count(*) from pgvigil.index_state where instance_id=$iid and datname='$T2' and is_present") == 0 ]] || fail "T2 rows still present"
[[ $(q "select first_seen from pgvigil.index_state where instance_id=$iid and datname='$T1' and problem='redundant' and is_present") == "$first_red" ]] || fail "redundant first_seen moved"
[[ $(q "select count(*) from pgvigil.index_state where instance_id=$iid and datname='$T1' and problem='duplicate' and is_present") == 1 ]] || fail "duplicate gone"
echo "findings: $(fnd)"
[[ $(fnd) == "duplicate index|warning|T1,redundant index|info|T1,redundant index|info|T1" ]] || fail "findings B"

echo "--- C. the unused rule on seeded imports"
seed() { # name, stats_since age, replica, unused bytes, [an earlier first import this long ago]
  local id at; id=$(q "insert into pgvigil.instances (name, platform) values ('proof-ix-$1-$SUF', 'onprem') returning instance_id" | head -1)
  for at in ${5:+"now() - interval '$5'"} "now()"; do
  q "select pgvigil.import_indexes($id, $at, jsonb_build_array(
       jsonb_build_object('kind','db','dbid',1,'datname','dbq','indexes',3,'index_bytes',$4,'stats_since',now() - interval '$2','is_replica',$3),
       jsonb_build_object('kind','index','dbid',1,'datname','dbq','indexrelid',100,'problem','unused','schema_name','public','table_name','big',
                          'index_name','big_x','index_bytes',$4,'drop_sql','DROP INDEX CONCURRENTLY big_x;','undo_sql','CREATE INDEX CONCURRENTLY big_x ON big (x);')))" >/dev/null
  done
  echo "$id"
}
x=$(seed x '30 days' false 20971520 '8 days'); y=$(seed y '30 days' true 20971520 '8 days'); z=$(seed z '2 days' false 20971520 '8 days')
w=$(seed w '30 days' false 5242880 '8 days'); v=$(seed v '30 days' false 20971520 '')
[[ $(q "select string_agg(setting || '|' || severity, ',') from pgvigil.index_findings where instance_id=$x") == "unused index|info" ]] || fail "x finding"
[[ $(q "select count(*) from pgvigil.index_findings where instance_id in ($y, $z, $w, $v)") == 0 ]] || fail "y / z / w / v findings: $(q "select instance_id, setting from pgvigil.index_findings where instance_id in ($y, $z, $w, $v)")"
q "select pgvigil.import_indexes($x, now(), '[{\"kind\":\"collector_error\",\"source\":\"indexes:dbq\",\"message\":\"proof\"}]')" >/dev/null
[[ $(q "select is_present from pgvigil.index_state where instance_id=$x") == t && $(q "select is_present from pgvigil.index_databases where instance_id=$x") == t ]] || fail "rows of a database in error not kept"
q "delete from pgvigil.instances where name like 'proof-ix-_-$SUF'" >/dev/null

echo "--- D. the index advisor (pg_qualstats + HypoPG)"
if ! command -v docker >/dev/null 2>&1; then
  echo "NOT PROVEN (D): no docker on this machine to run pg_qualstats and HypoPG"
else
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    cat > "$BUILD/Dockerfile" <<'EOF'
FROM postgres:18
RUN apt-get update -qq && apt-get install -y -qq postgresql-18-pg-wait-sampling postgresql-18-hypopg postgresql-18-pg-qualstats >/dev/null \
 && apt-get install -y -qq git make gcc libkrb5-dev postgresql-server-dev-18 >/dev/null \
 && git clone -q --depth 1 https://github.com/percona/pg_stat_monitor /tmp/pgsm && make -s -C /tmp/pgsm USE_PGXS=1 && make -s -C /tmp/pgsm USE_PGXS=1 install \
 && apt-get purge -y -qq git make gcc libkrb5-dev postgresql-server-dev-18 >/dev/null && rm -rf /tmp/pgsm /var/lib/apt/lists/*
EOF
    docker build -q -t "$IMAGE" "$BUILD" >/dev/null 2>&1 || echo "NOT PROVEN (D): the extension image did not build here"
  fi
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    PW=p$RANDOM$RANDOM
    docker run -d --name "$CTR" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1::5432 "$IMAGE" \
      -c shared_preload_libraries=pg_stat_statements,pg_qualstats -c pg_qualstats.sample_rate=1 >/dev/null
    PORT=$(docker port "$CTR" 5432/tcp | head -1 | sed 's/.*://')
    C="host=127.0.0.1 port=$PORT user=postgres password=$PW dbname=postgres"
    up=0
    for _ in $(seq 60); do psql "$C" -XAtqc "select 1" >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
    [[ $up == 1 ]] || fail "the container did not start"
    psql "$C" -XAq -v ON_ERROR_STOP=1 -c "create extension pg_stat_statements; create extension pg_qualstats; create extension hypopg" \
      -c "create role adv login password '$PW' in role pg_monitor, pg_read_all_data; create role mononly login password '$PW' in role pg_monitor" \
      -c "create table t (id int, a int, b text); insert into t select g, g % 1000, md5(g::text) from generate_series(1, 200000) g; analyze t" >/dev/null
    for n in $(seq 30); do psql "$C" -XAtqc "select count(*) from t where a = $n" >/dev/null; done
    export ADVISOR_EXPECT_DDL="CREATE INDEX ON public.t USING btree (a)"
    PGVIGIL_ADVISOR_DSN="host=127.0.0.1 port=$PORT user=adv password=$PW dbname=postgres" \
      go test ./internal/advisor -run TestRunLive -count=1 -v 2>&1 | grep -E 'ddl|cost_|gain|uses_index|PASS|FAIL|ok ' || true
    PGVIGIL_ADVISOR_DSN="host=127.0.0.1 port=$PORT user=adv password=$PW dbname=postgres" \
      go test ./internal/advisor -run TestRunLive -count=1 >/dev/null 2>&1 || fail "the advisor as pg_monitor + pg_read_all_data"
    [[ $(psql "$C" -XAtqc "select count(*) from pg_indexes where tablename = 't'") == 0 ]] || fail "an index exists on t after the advisor"
    PGVIGIL_ADVISOR_DSN="host=127.0.0.1 port=$PORT user=mononly password=$PW dbname=postgres" ADVISOR_EXPECT_NOTE="permission denied" \
      go test ./internal/advisor -run TestRunLive -count=1 >/dev/null 2>&1 || fail "the advisor as pg_monitor only: no 'permission denied' note"
    echo "advisor: suggestion tested with a hypothetical index, t still has no index; pg_monitor alone: statements noted 'permission denied'"
  fi
fi
echo "PROOF OK"
