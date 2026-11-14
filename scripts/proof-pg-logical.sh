#!/usr/bin/env bash
# proof-pg-logical.sh - PostgreSQL logical replication on a real publisher / subscriber pair (task 373; migration 0141,
# internal/collect/logical.go). Needs: docker, psql, python3, go (unless PGVIGIL_BIN names a built binary).
#
# The rig: a docker network with a repository (PostgreSQL 18), a publisher (PostgreSQL 18, wal_level logical) and a
# subscriber (PostgreSQL 18). Both have a database app1 (pgvigil connects to postgres: app1 is read through the
# collection's own per-database connection); the publisher's app1 publishes table t as pub1, the subscriber's app1 holds
# subscription sub1 to it. pgvigil collects both through logins holding pg_monitor only (instances lpub, lsub); a 'read'
# is one `pgvigil collect -once logical` of one instance.
#
# Expected (written before the first run, 2026-11-14 11:1x PST; on a tree without task 373 (486015e) the 'logical'
# collection does not exist: every row fails at its first read [red FAIL], but K, which reads the replication
# collection, fails on its key alone):
#   B    the healthy pair: lsub's pg_logical_subs row app1.sub1 enabled, an apply worker, tables ready 1/1, its
#        publications pub1; lpub's pg_logical_pubs row app1.pub1 with 1 table (app1 is not the connected database: it is
#        read because a logical slot decodes it); pg_logical_status's row for sub1 names lpub as its publisher; no
#        logical finding on either
#   K    lpub's replication read: the subscription's walsender stored with the key slot:sub1 (not its pid)
#   D    ALTER SUBSCRIPTION sub1 DISABLE, one read of lsub: 'subscription disabled' warning (object app1.sub1);
#        ENABLE, the worker back, one read: gone
#   S    table t2 (3 rows) added to pub1, the subscriber's own t2 already holding row 1, REFRESH PUBLICATION: the initial
#        copy fails on the duplicate (sync_error_count rises), two reads of lsub 8 s apart: 'subscription sync errors'
#        warning; pg_logical_rels holds app1.public.t2 not ready; the status row's tables ready 1/2. Fixed: the
#        subscriber's row 1 deleted, t2 ready (polled), one read: tables ready 2/2, no pg_logical_rels row
#   C    a conflict: row 100 inserted on the subscriber, then row 100 on the publisher - the apply worker fails on it and
#        retries (apply_error_count rises; PostgreSQL 18 counts confl_insert_exists): two reads 8 s apart:
#        'subscription apply errors' critical, its detail naming the insert_exists conflicts; fixed: the subscriber's row
#        100 deleted, the change applied (row 100 arrives, polled)
#   X    130 s after the fixes (the 2-minute windows of the error counters), one read: no logical finding
#   W    the publisher stopped: three reads of lsub 4 s apart: 'subscription worker down' critical; the publisher
#        started, the worker back (polled), one read: gone
# Not proven here: 'table sync not finished' without errors (a copy that hangs), 'subscription silent' (a publisher that
# answers and sends nothing), a subscription on a standby (no worker: judged 'disabled' only).
# Prints 'ok' / 'FAIL' per assertion and 'proof-pg-logical: OK' or 'proof-pg-logical: <n> FAIL'; exit 0 only when every
# row passed.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
MPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
RP=$(fp); PP=$(fp); SP=$(fp)
NET=pgvlog-$$; REPO=pgvlog-repo-$$; PUB=pgvlog-pub-$$; SUB=pgvlog-sub-$$
cleanup() {
  docker rm -f -v "$SUB" "$PUB" "$REPO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$SUB" "$PUB" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$PGVIGIL_BIN; else
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || { echo "FAIL the binary did not build"; exit 1; }
  BIN=$WORK/pgvigil
fi

# ---- the rig -------------------------------------------------------------------------------------------------------
docker network create "$NET" >/dev/null
docker run -d --name "$REPO" --network "$NET" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 >/dev/null
docker run -d --name "$PUB" --network "$NET" --network-alias pub -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$PP:5432" \
  postgres:18 -c wal_level=logical >/dev/null
docker run -d --name "$SUB" --network "$NET" --network-alias sub -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$SP:5432" \
  postgres:18 -c wal_retrieve_retry_interval=2s >/dev/null
RDSN="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
PDSN="host=127.0.0.1 port=$PP user=postgres password=$PW sslmode=disable"
SDSN="host=127.0.0.1 port=$SP user=postgres password=$PW sslmode=disable"
up() { local _; for _ in $(seq 1 60); do psql "$1 dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
for d in "$RDSN" "$PDSN" "$SDSN"; do up "$d" || { echo "FAIL the rig: $d does not answer"; exit 1; }; done; sleep 3
for d in "$RDSN" "$PDSN" "$SDSN"; do up "$d" || { echo "FAIL the rig: $d does not answer"; exit 1; }; done
q() { psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
pa() { psql "$PDSN dbname=app1" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
sa() { psql "$SDSN dbname=app1" -XAtq -c "$1" 2>/dev/null; }
psql "$RDSN dbname=postgres" -XAtqc "create database pgvigil" >/dev/null
for d in "$PDSN" "$SDSN"; do
  psql "$d dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create role pgv login password '$MPW' in role pg_monitor" -c "create database app1" >/dev/null
  psql "$d dbname=app1" -XAtq -v ON_ERROR_STOP=1 -c "create table t (id int primary key, v text)" -c "create table t2 (id int primary key, v text)" >/dev/null
done
pa "insert into t select g, 'x' from generate_series(1, 10) g" >/dev/null
pa "create publication pub1 for table t" >/dev/null
psql "$SDSN dbname=app1" -XAtq -v ON_ERROR_STOP=1 -c "create subscription sub1 connection 'host=pub port=5432 dbname=app1 user=postgres password=$PW' publication pub1" >/dev/null \
  || { echo "FAIL the rig: the subscription was not made"; exit 1; }
worker() { [[ -n "$(sa "select pid from pg_stat_subscription where subname = 'sub1' and relid is null")" ]]; }
for _ in $(seq 1 60); do [[ "$(sa "select count(*) from t")" == "10" ]] && worker && break; sleep 1; done
[[ "$(sa "select count(*) from t")" == "10" ]] || { echo "FAIL the rig: the initial copy did not arrive"; exit 1; }

cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: "$RDSN dbname=pgvigil"
instances:
  - name: lpub
    dsn: "host=127.0.0.1 port=$PP user=pgv password=$MPW dbname=postgres sslmode=disable"
  - name: lsub
    dsn: "host=127.0.0.1 port=$SP user=pgv password=$MPW dbname=postgres sslmode=disable"
EOF
"$BIN" migrate -config "$WORK/pgvigil.yaml" >"$WORK/migrate.out" 2>&1 || { cat "$WORK/migrate.out"; exit 1; }
"$BIN" collect -config "$WORK/pgvigil.yaml" -once instance >"$WORK/instance.out" 2>&1 || { cat "$WORK/instance.out"; exit 1; }
PUBID=$(q "select instance_id from pgvigil.instances where name = 'lpub'")
SUBID=$(q "select instance_id from pgvigil.instances where name = 'lsub'")
read_() { # read_ <instance> [n] [gap] [collection]
  local n=${2:-1} gap=${3:-3} coll=${4:-logical} i
  for ((i = 0; i < n; i++)); do
    (( i > 0 )) && sleep "$gap"
    "$BIN" collect -config "$WORK/pgvigil.yaml" -once "$coll" -instance "$1" >>"$WORK/collect.out" 2>&1 || echo "  (read of $1 failed: $(tail -1 "$WORK/collect.out"))"
  done
}
finding() { q "select severity || '|' || setting || '|' || value from pgvigil.findings where instance_id = $1 and setting like 'subscription%' or (instance_id = $1 and setting = 'table sync not finished') order by 1" 2>/dev/null; }
sub() { q "select $1 from pgvigil.pg_logical_subs where instance_id = $SUBID and datname = 'app1' and subname = 'sub1'" 2>/dev/null; }

# ---- B ---------------------------------------------------------------------------------------------------------------
read_ lpub 1; read_ lpub 1 3 replication; read_ lsub 1
r=$(sub "enabled || '|' || (worker_pid is not null) || '|' || coalesce(rels_ready, '') || '|' || coalesce(publications, '')")
[[ "$r" == "true|true|1/1|pub1" ]] && ok "B lsub's app1.sub1: enabled, a worker, tables 1/1, pub1" || fail "B lsub's sub1: '$r', expected true|true|1/1|pub1"
r=$(q "select coalesce(table_count::text, '') || '|' || is_present from pgvigil.pg_logical_pubs where instance_id = $PUBID and datname = 'app1' and pubname = 'pub1'" 2>/dev/null)
[[ "$r" == "1|true" ]] && ok "B lpub's app1.pub1: 1 table (app1 read through its logical slot)" || fail "B lpub's pub1: '$r'"
r=$(q "select coalesce(publisher, '') from pgvigil.pg_logical_status where subname = 'sub1'" 2>/dev/null)
[[ "$r" == "lpub" ]] && ok "B the status row names lpub as the publisher" || fail "B status publisher: '$r'"
r=$(finding "$SUBID"); r2=$(finding "$PUBID")
[[ -z "$r$r2" ]] && ok "B no logical finding" || fail "B findings: '$r' / '$r2'"

# ---- K ---------------------------------------------------------------------------------------------------------------
r=$(q "select string_agg(distinct key, ',') from pgvigil.replication_sample where instance_id = $PUBID and kind = 'sender'")
[[ "$r" == "slot:sub1" ]] && ok "K the subscription's walsender keyed slot:sub1" || fail "K lpub's sender keys: '$r'"

# ---- D ---------------------------------------------------------------------------------------------------------------
sa "alter subscription sub1 disable" >/dev/null; sleep 2
read_ lsub 1
r=$(finding "$SUBID")
[[ "$r" == "warning|subscription disabled|app1.sub1:"* ]] && ok "D 'subscription disabled' warning: $r" || fail "D: '$r'"
sa "alter subscription sub1 enable" >/dev/null
for _ in $(seq 1 30); do worker && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID")
[[ -z "$r" ]] && ok "D enabled again: gone" || fail "D still raised: '$r'"

# ---- S ---------------------------------------------------------------------------------------------------------------
pa "insert into t2 select g, 'y' from generate_series(1, 3) g" >/dev/null
sa "insert into t2 values (1, 'mine')" >/dev/null
pa "alter publication pub1 add table t2" >/dev/null
sa "alter subscription sub1 refresh publication" >/dev/null
for _ in $(seq 1 30); do [[ "$(sa "select coalesce(sync_error_count, 0) from pg_stat_subscription_stats where subname = 'sub1'")" -ge 1 ]] && break; sleep 1; done
echo "  sync_error_count $(sa "select sync_error_count from pg_stat_subscription_stats where subname = 'sub1'"), t2 state $(sa "select srsubstate from pg_subscription_rel r join pg_class c on c.oid = r.srrelid where c.relname = 't2'")"
read_ lsub 2 8
r=$(finding "$SUBID")
[[ "$r" == "warning|subscription sync errors|"* ]] && ok "S 'subscription sync errors' warning: $r" || fail "S: '$r'"
r=$(q "select rel || ' ' || state from pgvigil.pg_logical_rels where instance_id = $SUBID and subname = 'sub1'" 2>/dev/null)
[[ "$r" == "public.t2 "* ]] && ok "S pg_logical_rels: $r" || fail "S pg_logical_rels: '$r'"
r=$(sub "coalesce(rels_ready, '')")
[[ "$r" == "1/2" ]] && ok "S tables ready 1/2" || fail "S tables ready: '$r'"
sa "delete from t2 where id = 1" >/dev/null
for _ in $(seq 1 60); do [[ "$(sa "select srsubstate from pg_subscription_rel r join pg_class c on c.oid = r.srrelid where c.relname = 't2'")" == "r" ]] && break; sleep 1; done
read_ lsub 1
r=$(sub "coalesce(rels_ready, '')"); r2=$(q "select count(*) from pgvigil.pg_logical_rels where instance_id = $SUBID" 2>/dev/null)
[[ "$r" == "2/2" && "$r2" == "0" ]] && ok "S fixed: tables ready 2/2, no unfinished table" || fail "S fixed: ready '$r', unfinished rows '$r2'"

# ---- C ---------------------------------------------------------------------------------------------------------------
sa "insert into t values (100, 'mine')" >/dev/null
pa "insert into t values (100, 'theirs')" >/dev/null
for _ in $(seq 1 30); do [[ "$(sa "select coalesce(apply_error_count, 0) from pg_stat_subscription_stats where subname = 'sub1'")" -ge 1 ]] && break; sleep 1; done
echo "  apply_error_count $(sa "select apply_error_count from pg_stat_subscription_stats where subname = 'sub1'"), confl_insert_exists $(sa "select confl_insert_exists from pg_stat_subscription_stats where subname = 'sub1'")"
read_ lsub 2 8
r=$(finding "$SUBID"); r2=$(q "select coalesce(detail, '') from pgvigil.pg_logical_checks where instance_id = $SUBID" 2>/dev/null)
[[ "$r" == "critical|subscription apply errors|"* ]] && ok "C 'subscription apply errors' critical: $r" || fail "C: '$r'"
[[ "$r2" == *"insert_exists"* ]] && ok "C its detail names the conflict: $r2" || fail "C detail: '$r2'"
sa "delete from t where id = 100" >/dev/null
for _ in $(seq 1 60); do [[ "$(sa "select v from t where id = 100")" == "theirs" ]] && break; sleep 1; done
[[ "$(sa "select v from t where id = 100")" == "theirs" ]] && ok "C fixed: the publisher's row 100 applied" || fail "C the change was not applied after the fix"

# ---- X ---------------------------------------------------------------------------------------------------------------
sleep 130
read_ lsub 1
r=$(finding "$SUBID")
[[ -z "$r" ]] && ok "X no logical finding 130 s after the fixes" || fail "X still raised: '$r'"

# ---- W ---------------------------------------------------------------------------------------------------------------
docker stop -t 10 "$PUB" >/dev/null
sleep 3
read_ lsub 3 4
r=$(finding "$SUBID")
[[ "$r" == "critical|subscription worker down|"* ]] && ok "W 'subscription worker down' critical: $r" || fail "W: '$r' (worker_down_reads $(sub worker_down_reads))"
docker start "$PUB" >/dev/null
up "$PDSN" || fail "W the publisher did not come back"
for _ in $(seq 1 60); do worker && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID")
[[ -z "$r" ]] && ok "W the publisher back: gone" || fail "W still raised: '$r'"

if (( FAILS == 0 )); then echo "proof-pg-logical: OK"; exit 0; fi
echo "proof-pg-logical: $FAILS FAIL"; exit 1
