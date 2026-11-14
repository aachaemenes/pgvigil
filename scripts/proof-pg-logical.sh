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
# Expected (written before the first run, 2026-11-14 10:5x PST; the rows the review fold added or changed 12:5x PST,
# before their runs). On a tree without task 373 (486015e) the 'logical' collection does not exist: every positive
# assertion fails at its first read [red FAIL] - B x3, K x2 (K's key, read through the replication collection, and the
# status row), D x2 (D's 'gone' also asks for the stored worker), S x4, C x2, C2's second read, W, WP - and the negative
# and data assertions pass [red ok]: B no finding, C the row applied, C2's first read and its fix, X, W's restart and
# 'gone', WP's 'gone':
#   B    the healthy pair: lsub's pg_logical_subs row app1.sub1 enabled, an apply worker, tables ready 1/1, its
#        publications pub1; lpub's pg_logical_pubs row app1.pub1 with 1 table (app1 is not the connected database: it is
#        read because a logical slot decodes it); pg_logical_status's row for sub1 names lpub as its publisher; no
#        logical finding on either
#   K    lpub's replication read: the subscription's walsender stored with the key slot:sub1 (not its pid); the status
#        row carries that walsender's bytes not applied and its state streaming (the apply lag the page shows)
#   D    ALTER SUBSCRIPTION sub1 DISABLE, one read of lsub: 'subscription disabled' warning (object app1.sub1);
#        ENABLE, the worker back and receiving (polled), one read: gone, the worker stored
#   S    table t2 (3 rows) added to pub1, the subscriber's own t2 already holding row 1, REFRESH PUBLICATION: the initial
#        copy fails on the duplicate (sync_error_count rises), two reads of lsub 8 s apart: 'subscription sync errors'
#        warning; pg_logical_rels holds app1.public.t2 not ready; the status row's tables ready 1/2. Fixed: the
#        subscriber's row 1 deleted, t2 ready (polled), one read: tables ready 2/2, no pg_logical_rels row
#   C    a conflict: row 100 inserted on the subscriber, then row 100 on the publisher - the apply worker fails on it and
#        retries (apply_error_count rises; PostgreSQL 18 counts confl_insert_exists): two reads 8 s apart:
#        'subscription apply errors' critical, its detail counting the insert_exists conflicts (over 0); fixed: the
#        subscriber's row 100 deleted, the change applied (row 100 arrives, polled), one read (it dates the retries made
#        before the fix: a rise is dated by the read that sees it)
#   C2   the loop rule's second arm: wal_retrieve_retry_interval 25 s, a conflict on row 101, one read after its first
#        error: no 'apply errors' (one rise of one) [red ok]; one read after its second error: 'apply errors' critical
#        (a rise on 2 reads in a row) [red FAIL]; fixed and 2 s again, one read (on 6b75eb0, before the loop rule, the
#        first read would raise: reasoned from W's run there, not run)
#   X    130 s after the last read past the fixes (the 2-minute windows of the error counters), one read: no logical
#        finding
#   W    the publisher stopped: reads of lsub 4 s apart until two in a row saw no worker (at most 6): 'subscription
#        worker down' critical - PostgreSQL 18 counts the streaming worker's disconnect as ONE apply error and the rule
#        calls only a loop 'apply errors' (2+ since the read before, or a rise on 2 reads in a row); the run prints the
#        count across the stop; the publisher started ([red ok]), the worker back and receiving (polled), one read: gone
#   WP   the publisher frozen (docker pause: it neither answers nor refuses) with the subscriber's wal_receiver_timeout
#        10 s: reads of lsub 5 s apart until two in a row saw no worker receiving (at most 12): 'subscription worker down'
#        critical - the relaunched worker waits in its connect with a pid and no message [red FAIL; on dd05ea2, before
#        the review fold counted such a worker as down, too: run red in pdfp-hadr-s1-redfoldwp]; unpaused, the
#        worker receiving (polled), one read: gone [red ok]
#   read a failed read is a FAIL, and a failed repository query answers 'QUERY FAILED' (a negative row cannot pass on an
#        empty answer); the repository is read with jit off, and B prints one findings read timed with jit on and off
# Not proven here: a disconnect during a running table sync (PostgreSQL may count it as one sync error: 'subscription
# sync errors' would then show for 2 minutes; the apply side's one-rise rule is not applied to sync errors),
# 'subscription conflicts' alone (a conflict counter rising with no error), 'subscription disabled' critical through
# disable_on_error, a dropped subscription or publication, PostgreSQL 13-17 (no conflict counters; before 15 no error
# counters; 13 without pg_subscription.oid for pg_monitor),
# 'table sync not finished' without errors (a copy that hangs), 'subscription silent' (a publisher that
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
NET=pgvlog-$$; REPO=pgvlog-repo-$$; PUB=pgvlog-pub-$$; SUB=pgvlog-sub-$$
cleanup() {
  docker rm -f -v "$SUB" "$PUB" "$REPO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$SUB" "$PUB" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
  docker network inspect "$NET" >/dev/null 2>&1 && echo "network $NET LEFT"
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$PGVIGIL_BIN; else
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || { echo "FAIL the binary did not build"; exit 1; }
  BIN=$WORK/pgvigil
fi

# ---- the rig -------------------------------------------------------------------------------------------------------
RP=$(fp); PP=$(fp); SP=$(fp)   # picked just before the containers bind them
docker network create "$NET" >/dev/null
docker run -d --name "$REPO" --network "$NET" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 >/dev/null
docker run -d --name "$PUB" --network "$NET" --network-alias pub -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$PP:5432" \
  postgres:18 -c wal_level=logical >/dev/null
docker run -d --name "$SUB" --network "$NET" --network-alias sub -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$SP:5432" \
  postgres:18 >/dev/null
RDSN="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
PDSN="host=127.0.0.1 port=$PP user=postgres password=$PW sslmode=disable"
SDSN="host=127.0.0.1 port=$SP user=postgres password=$PW sslmode=disable"
up() { local _; for _ in $(seq 1 60); do psql "$1 dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
for d in "$RDSN" "$PDSN" "$SDSN"; do up "$d" || { echo "FAIL the rig: $d does not answer"; exit 1; }; done; sleep 3
for d in "$RDSN" "$PDSN" "$SDSN"; do up "$d" || { echo "FAIL the rig: $d does not answer"; exit 1; }; done
# the workers' relaunch interval: 2 s through ALTER SYSTEM (a command-line -c would override C2's change)
psql "$SDSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "alter system set wal_retrieve_retry_interval = '2s'" -c "select pg_reload_conf()" >/dev/null \
  || { echo "FAIL the rig: wal_retrieve_retry_interval"; exit 1; }
num() { [[ "$1" =~ ^-?[0-9]+$ ]] && echo "$1" || echo -1; }   # a failed read is -1, never an empty $(( ))
q() { # a failed query answers 'QUERY FAILED: <error>' (exit 1), never an empty answer a negative row would pass on
  local o; if o=$(PGOPTIONS="-c jit=${QJIT:-off}" psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "$1" 2>"$WORK/q.err"); then
    [[ -n "$o" ]] && printf '%s\n' "$o"; return 0; fi
  echo "QUERY FAILED: $(tail -1 "$WORK/q.err")"; return 1; }
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
# a worker that has received from the publisher (a new one shows '-infinity' until its first message)
worker_live() { [[ -n "$(sa "select pid from pg_stat_subscription where subname = 'sub1' and relid is null and isfinite(last_msg_receipt_time)")" ]]; }
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
    "$BIN" collect -config "$WORK/pgvigil.yaml" -once "$coll" -instance "$1" >>"$WORK/collect.out" 2>&1 || fail "read of $1 failed: $(tail -1 "$WORK/collect.out")"
  done
}
finding() { q "select severity || '|' || setting || '|' || value from pgvigil.findings where instance_id = $1 and (setting like 'subscription%' or setting = 'table sync not finished') order by 1"; }
sub() { q "select $1 from pgvigil.pg_logical_subs where instance_id = $SUBID and datname = 'app1' and subname = 'sub1'"; }

# ---- B ---------------------------------------------------------------------------------------------------------------
read_ lpub 1; read_ lpub 1 3 replication; read_ lsub 1
r=$(sub "enabled || '|' || (worker_pid is not null) || '|' || coalesce(rels_ready, '') || '|' || coalesce(publications, '')")
[[ "$r" == "true|true|1/1|pub1" ]] && ok "B lsub's app1.sub1: enabled, a worker, tables 1/1, pub1" || fail "B lsub's sub1: '$r', expected true|true|1/1|pub1"
r=$(q "select coalesce(table_count::text, '') || '|' || is_present from pgvigil.pg_logical_pubs where instance_id = $PUBID and datname = 'app1' and pubname = 'pub1'")
[[ "$r" == "1|true" ]] && ok "B lpub's app1.pub1: 1 table (app1 read through its logical slot)" || fail "B lpub's pub1: '$r'"
r=$(q "select coalesce(publisher, '') from pgvigil.pg_logical_status where subname = 'sub1'")
[[ "$r" == "lpub" ]] && ok "B the status row names lpub as the publisher" || fail "B status publisher: '$r'"
r=$(finding "$SUBID"); r2=$(finding "$PUBID")
[[ -z "$r$r2" ]] && ok "B no logical finding" || fail "B findings: '$r' / '$r2'"
t0=$(date +%s.%N); QJIT=on finding "$SUBID" >/dev/null; t1=$(date +%s.%N); QJIT=off finding "$SUBID" >/dev/null; t2=$(date +%s.%N)
echo "  (info) one instance's pgvigil.findings read: jit on $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') s, jit off $(awk -v a="$t1" -v b="$t2" 'BEGIN { printf "%.1f", b - a }') s"

# ---- K ---------------------------------------------------------------------------------------------------------------
r=$(q "select string_agg(distinct key, ',') from pgvigil.replication_sample where instance_id = $PUBID and kind = 'sender'")
[[ "$r" == "slot:sub1" ]] && ok "K the subscription's walsender keyed slot:sub1" || fail "K lpub's sender keys: '$r'"
r=$(q "select coalesce(sender_lag_bytes::text, 'null') || '|' || coalesce(sender_state, 'null') from pgvigil.pg_logical_status where subname = 'sub1'")
[[ "$r" =~ ^[0-9]+\|streaming$ ]] && ok "K the status row carries the publisher's walsender: $r (bytes not applied | state)" || fail "K the status row's sender lag: '$r'"

# ---- D ---------------------------------------------------------------------------------------------------------------
sa "alter subscription sub1 disable" >/dev/null; sleep 2
read_ lsub 1
r=$(finding "$SUBID")
[[ "$r" == "warning|subscription disabled|app1.sub1:"* ]] && ok "D 'subscription disabled' warning: $r" || fail "D: '$r'"
sa "alter subscription sub1 enable" >/dev/null
for _ in $(seq 1 30); do worker_live && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID"); r2=$(sub "(worker_pid is not null)::text")
[[ -z "$r" && "$r2" == "true" ]] && ok "D enabled again: gone, the worker back" || fail "D enabled again: finding '$r', worker stored '$r2'"

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
r=$(q "select rel || ' ' || state from pgvigil.pg_logical_rels where instance_id = $SUBID and subname = 'sub1'")
[[ "$r" == "public.t2 "* ]] && ok "S pg_logical_rels: $r" || fail "S pg_logical_rels: '$r'"
r=$(sub "coalesce(rels_ready, '')")
[[ "$r" == "1/2" ]] && ok "S tables ready 1/2" || fail "S tables ready: '$r'"
sa "delete from t2 where id = 1" >/dev/null
for _ in $(seq 1 60); do [[ "$(sa "select srsubstate from pg_subscription_rel r join pg_class c on c.oid = r.srrelid where c.relname = 't2'")" == "r" ]] && break; sleep 1; done
read_ lsub 1
r=$(sub "coalesce(rels_ready, '')"); r2=$(q "select count(*) from pgvigil.pg_logical_rels where instance_id = $SUBID")
[[ "$r" == "2/2" && "$r2" == "0" ]] && ok "S fixed: tables ready 2/2, no unfinished table" || fail "S fixed: ready '$r', unfinished rows '$r2'"

# ---- C ---------------------------------------------------------------------------------------------------------------
sa "insert into t values (100, 'mine')" >/dev/null
pa "insert into t values (100, 'theirs')" >/dev/null
for _ in $(seq 1 30); do [[ "$(sa "select coalesce(apply_error_count, 0) from pg_stat_subscription_stats where subname = 'sub1'")" -ge 1 ]] && break; sleep 1; done
echo "  apply_error_count $(sa "select apply_error_count from pg_stat_subscription_stats where subname = 'sub1'"), confl_insert_exists $(sa "select confl_insert_exists from pg_stat_subscription_stats where subname = 'sub1'")"
read_ lsub 2 8
r=$(finding "$SUBID"); r2=$(q "select coalesce(detail, '') from pgvigil.pg_logical_checks where instance_id = $SUBID")
[[ "$r" == "critical|subscription apply errors|"* ]] && ok "C 'subscription apply errors' critical: $r" || fail "C: '$r'"
[[ "$r2" =~ confl_insert_exists:\ [1-9] ]] && ok "C its detail counts the conflict: $r2" || fail "C detail: '$r2'"
sa "delete from t where id = 100" >/dev/null
for _ in $(seq 1 60); do [[ "$(sa "select v from t where id = 100")" == "theirs" ]] && break; sleep 1; done
[[ "$(sa "select v from t where id = 100")" == "theirs" ]] && ok "C fixed: the publisher's row 100 applied" || fail "C the change was not applied after the fix"
# a counter's rise is dated by the read that sees it (as the collector's schedule would): this read takes the retries made
# between C's reads and the fix, so X's window starts here
echo "  apply_error_count after the fix $(sa "select apply_error_count from pg_stat_subscription_stats where subname = 'sub1'")"
read_ lsub 1

# ---- C2: the loop rule's second arm - a rise of one on each of 2 reads in a row ---------------------------------------
aec() { sa "select apply_error_count from pg_stat_subscription_stats where subname = 'sub1'"; }
psql "$SDSN dbname=postgres" -XAtq -c "alter system set wal_retrieve_retry_interval = '25s'" -c "select pg_reload_conf()" >/dev/null
sa "insert into t values (101, 'mine')" >/dev/null
a0=$(aec); pa "insert into t values (101, 'theirs')" >/dev/null
for _ in $(seq 1 30); do (( $(num "$(aec)") > $(num "$a0") )) && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID")
[[ "$r" != *"subscription apply errors"* ]] && ok "C2 one rise of one ($a0 -> $(aec)): no 'apply errors' (${r:-no finding})" || fail "C2 one rise of one raised: '$r'"
a1=$(aec); for _ in $(seq 1 45); do (( $(num "$(aec)") > $(num "$a1") )) && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID")
[[ "$r" == "critical|subscription apply errors|"* ]] && ok "C2 a second rise in a row ($a1 -> $(aec)): 'apply errors' critical" || fail "C2 the second rise: '$r'"
psql "$SDSN dbname=postgres" -XAtq -c "alter system set wal_retrieve_retry_interval = '2s'" -c "select pg_reload_conf()" >/dev/null
sa "delete from t where id = 101" >/dev/null
for _ in $(seq 1 60); do [[ "$(sa "select v from t where id = 101")" == "theirs" ]] && break; sleep 1; done
[[ "$(sa "select v from t where id = 101")" == "theirs" ]] && ok "C2 fixed: row 101 applied" || fail "C2 the change was not applied after the fix"
read_ lsub 1

# ---- X ---------------------------------------------------------------------------------------------------------------
sleep 130
read_ lsub 1
r=$(finding "$SUBID")
[[ -z "$r" ]] && ok "X no logical finding 130 s after the fixes" || fail "X still raised: '$r'"

# ---- W ---------------------------------------------------------------------------------------------------------------
AEC0=$(sa "select apply_error_count from pg_stat_subscription_stats where subname = 'sub1'")
docker stop -t 10 "$PUB" >/dev/null
sleep 3
for _ in $(seq 1 6); do read_ lsub 1; (( $(num "$(sub worker_down_reads)") >= 2 )) && break; sleep 4; done   # a relaunched worker may be alive at a read
AEC1=$(sa "select apply_error_count from pg_stat_subscription_stats where subname = 'sub1'")
echo "  apply_error_count before the stop $AEC0, after the reads $AEC1 ($(( $(num "$AEC1") - $(num "$AEC0") )) counted at the stop: a rise of one is the disconnect, judged no apply loop)"
r=$(finding "$SUBID")
[[ "$r" == "critical|subscription worker down|"* ]] && ok "W 'subscription worker down' critical: $r" || fail "W: '$r' (worker_down_reads $(sub worker_down_reads))"
docker start "$PUB" >/dev/null || fail "W docker start of the publisher failed"
up "$PDSN" || fail "W the publisher did not come back"
for _ in $(seq 1 60); do worker_live && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID")
[[ -z "$r" ]] && ok "W the publisher back: gone" || fail "W still raised: '$r'"

# ---- WP: the publisher frozen (docker pause): it neither answers nor refuses ------------------------------------------
psql "$SDSN dbname=postgres" -XAtq -c "alter system set wal_receiver_timeout = '10s'" -c "select pg_reload_conf()" >/dev/null
docker pause "$PUB" >/dev/null || fail "WP docker pause failed"
sleep 15
for _ in $(seq 1 12); do read_ lsub 1; (( $(num "$(sub worker_down_reads)") >= 2 )) && break; sleep 5; done
echo "  the subscriber's apply worker while the publisher is frozen: $(sa "select coalesce(pid::text, 'none') || ', last message ' || coalesce(last_msg_receipt_time::text, 'null') from pg_stat_subscription where subname = 'sub1' and relid is null")"
r=$(finding "$SUBID")
[[ "$r" == "critical|subscription worker down|"* ]] && ok "WP 'subscription worker down' critical: $r" || fail "WP: '$r' (worker_down_reads $(sub worker_down_reads))"
docker unpause "$PUB" >/dev/null || fail "WP docker unpause failed"
psql "$SDSN dbname=postgres" -XAtq -c "alter system reset wal_receiver_timeout" -c "select pg_reload_conf()" >/dev/null
for _ in $(seq 1 90); do worker_live && break; sleep 1; done
read_ lsub 1
r=$(finding "$SUBID")
[[ -z "$r" ]] && ok "WP the publisher back: gone" || fail "WP still raised: '$r'"

if (( FAILS == 0 )); then echo "proof-pg-logical: OK"; exit 0; fi
echo "proof-pg-logical: $FAILS FAIL"; exit 1
