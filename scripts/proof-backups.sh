#!/usr/bin/env bash
# Proof of the backups collection and its rules (migration 0022). Four parts:
#   A. the archiver on a throwaway cluster (initdb on a free port, archive_mode on, an archive_command that fails
#      while a flag file exists), read by a pg_monitor-only login through `pgvigil collect -once backups`.
#   B. the archive-age rule on seeded archiver rows (scratch instances in the proof's own repository).
#   C. the cloud rules on seeded RDS / Aurora rows, and the snapshot absence handling.
#   D. the AWS side: the Go tests on the constructed DescribeDBClusters / DescribeDBInstances / snapshot answers
#      (internal/collect/testdata/backups); with LAB=1 and an active `aws login --profile dba-lab`, a live read of
#      the lab's Aurora cluster (read only).
#
#   PGVIGIL_ADMIN_DSN  a superuser connection to the sandbox (no dbname); the proof makes its own repository
#                      database and drops it at the end; the throwaway cluster lives in a temp directory and is
#                      stopped and removed at the end; nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A1. after a write and pg_switch_wal, collect -once backups: backup_state archiver|pg_stat_archiver with archive_mode on,
#      archive_set true, archived_count >= 1, failed_count 0, last_archived_wal 24 hex characters, archive_lag_bytes
#      >= 0 and under one segment (16 MB), is_replica false; backup_status archiving true, archiver_failing false; no
#      backup_rule_hits; collection status ok; backup_sample 1 row.
#  A2. with the flag file, a write and pg_switch_wal: failed_count >= 1 and last_failed_time > last_archived_time;
#      backup_rule_hits exactly 'archiver failing|critical' (object = last_failed_wal); backup_checks the same row;
#      backup_findings one row, setting 'archiver failing', platforms 'not aurora'; archive_lag_bytes > one segment.
#  A3. flag removed, pg_switch_wal: archived catches up (last_archived_time > last_failed_time), no rule hit;
#      backup_sample 3 rows.
#  A4. [added after the first render, expected before its run: the tab's series query failed in the browser with
#      "operator does not exist: timestamp with time zone > interval" (an untyped window parameter)] the handlers as
#      the API serves them on the A instance (go test -run TestBackupsProof ./internal/web): status 1 row,
#      archiver_failing false, no findings, the series sums archived >= 2 and failed >= 1, the fleet rows, the
#      overview check runs: PASS.
#  B.  seeded archiver rows (wal_segment 16 MB):
#      b1 onprem, on, last archive 90 min before the read, lag 48 MB       -> 'last archive older than 60 min|warning'
#      b2 onprem, on, last archive 90 min before the read, lag 1 MB (idle) -> nothing (no WAL waiting)
#      b3 onprem, on, 90 min, lag 48 MB, archive_warn_minutes 120          -> nothing
#      b4 onprem standby, archive_mode on, 90 min, lag NULL                 -> nothing (a standby with 'on' does not archive)
#      b5 aurora, on, failed after the last success                        -> nothing (not aurora)
#      b6 onprem, on, never archived (last_archived_time NULL), lag 48 MB  -> 'last archive older than 60 min|warning'
#                                                                             detail 'nothing archived since the stats reset'
#      b7 onprem, archive_mode off, 90 min, lag 48 MB                      -> nothing
#      [review fold, expected before the rerun:]
#      b8 onprem standby, archive_mode always, 90 min, lag 48 MB           -> 'last archive older than 60 min|warning'
#      b9 onprem, archive_mode off, failed after the last success          -> nothing (a server that stopped archiving
#                                                                             keeps its old failure; not failing)
#  C.  seeded cloud rows:
#      c1 rds    retention 3, automated available 2 h old                  -> 'retention under 7 days|warning' only
#      c2 rds    retention 0, no snapshot (snapshots_read, count 0)        -> 'retention under 7 days|critical' and
#                                                                             'no snapshot in 24 h|warning'
#      c3 aurora retention 7, automated 30 h old, a manual 'creating' 1 h  -> 'no snapshot in 24 h|warning' only
#      c4 aurora retention 14, automated 3 h old                           -> nothing
#      [review fold] c5 rds read replica (archiver is_replica) retention 0, no snapshot -> nothing
#      (a replica with retention > 0 keeps the rules: not seeded)
#      [review fold] c6 rds retention 3 read 2 hours ago (a stale read)    -> no rule hit in backup_checks or
#                                                                             backup_findings (backup_rule_hits keeps it)
#      backup_findings for c1-c4 = their rule hits (4 rows), platforms 'managed'.
#      c3 re-imported with snapshots_read and only the manual one: the automated row is_present false; then a payload
#      with only a collector_error: the manual row stays present and the cloud row stays.
#      backup_status c1 restorable_age_s = 600 (latest restorable 10 min before the read).
#  D.  go test -run Backups ./internal/collect: PASS. LAB=1: backup_state cloud|dba-lab-pg (resource_kind cluster,
#      retention_days >= 1, latest_restorable_time within a day) and at least one automated snapshot row; not run
#      without LAB=1 (the lab's session is its owner's `aws login`).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
TMP=$(mktemp -d)
SUF=$(basename "$TMP" | tr -dc 'A-Za-z0-9' | tr 'A-Z' 'a-z')   # unique while the temp directory exists
REPO_DB=pgvigil_bkproof_$SUF
CREATED=0
PGDATA_T=$TMP/data; ARCH=$TMP/arch; FLAG=$TMP/fail
PORT=$((20000 + RANDOM % 20000))
CFG=$TMP/pgvigil.yaml
cleanup() {
  pg_ctl -D "$PGDATA_T" -m immediate stop >/dev/null 2>&1 || true
  [ "$CREATED" = 1 ] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO_DB" >/dev/null
CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. the archiver on a throwaway cluster (port $PORT)"
mkdir -p "$ARCH"
initdb -D "$PGDATA_T" -U pgvproof -A trust >/dev/null
cat >> "$PGDATA_T/postgresql.conf" <<EOF
port = $PORT
listen_addresses = ''
unix_socket_directories = '$TMP'
archive_mode = on
archive_command = 'test ! -f $FLAG && cp %p $ARCH/%f'
wal_level = replica
EOF
pg_ctl -D "$PGDATA_T" -l "$TMP/server.log" -w start >/dev/null
T="host=$TMP port=$PORT dbname=postgres"
t() { psql "$T user=pgvproof" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t "create role bkmon login in role pg_monitor" >/dev/null
export MON_DSN="$T user=bkmon"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-backups-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
# wait until the archiver's counter passes a value (the archiver works asynchronously)
wait_count() { # column, at least
  for _ in $(seq 1 30); do
    [ "$(t "select $1 >= $2 from pg_stat_archiver")" = t ] && return 0
    sleep 1
  done
  fail "pg_stat_archiver.$1 did not reach $2"
}
show() {
  q "select '  ' || archive_mode || '|set ' || archive_set || '|archived ' || archived_count || '|failed ' || failed_count
       || '|last ' || coalesce(last_archived_wal, '-') || '|failed wal ' || coalesce(last_failed_wal, '-')
       || '|lag ' || coalesce(archive_lag_bytes::text, '-') from pgvigil.backup_state where instance_id=$aid and kind='archiver'"
}

t "create table w(i int); insert into w select generate_series(1, 1000)" >/dev/null
t "select pg_switch_wal()" >/dev/null
wait_count archived_count 1
"$BIN" collect -config "$CFG" -once backups || fail "A1: collect"
aid=$(q "select instance_id from pgvigil.instances where name='proof-backups-$SUF'")
show
[ "$(q "select count(*) from pgvigil.backup_state where instance_id=$aid and kind='archiver' and archive_mode='on' and archive_set
        and archived_count >= 1 and failed_count = 0 and last_archived_wal ~ '^[0-9A-F]{24}\$' and archive_lag_bytes >= 0
        and archive_lag_bytes < 16777216 and not is_replica")" = 1 ] || fail "A1: archiver row"
[ "$(q "select archiving::text || '|' || archiver_failing::text from pgvigil.backup_status where instance_id=$aid")" = "true|false" ] || fail "A1: status"
[ "$(q "select count(*) from pgvigil.backup_rule_hits where instance_id=$aid")" = 0 ] || fail "A1: a rule hit"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$aid and collection='backups'")" = ok ] || fail "A1: collection status"
echo "A1: OK"

touch "$FLAG"
t "insert into w select generate_series(1, 1000)" >/dev/null
t "select pg_switch_wal()" >/dev/null
t "insert into w values (0)" >/dev/null   # WAL past the switch: the lag is over one segment, not exactly one
wait_count failed_count 1
"$BIN" collect -config "$CFG" -once backups >/dev/null || fail "A2: collect"
show
[ "$(q "select count(*) from pgvigil.backup_state where instance_id=$aid and kind='archiver' and failed_count >= 1 and last_failed_time > last_archived_time")" = 1 ] || fail "A2: failed counts"
hits=$(q "select string_agg(h.check_name || '|' || h.severity || '|' || (h.object = b.last_failed_wal)::text, ',')
            from pgvigil.backup_rule_hits h join pgvigil.backup_state b on b.instance_id = h.instance_id and b.kind = 'archiver' where h.instance_id=$aid")
echo "  hits: $hits"
[ "$hits" = "archiver failing|critical|true" ] || fail "A2: rule hits"
[ "$(q "select count(*) from pgvigil.backup_checks where instance_id=$aid and check_name='archiver failing' and severity='critical'")" = 1 ] || fail "A2: checks"
[ "$(q "select string_agg(setting || '|' || platforms, ',') from pgvigil.backup_findings where instance_id=$aid")" = "archiver failing|not aurora" ] || fail "A2: findings"
[ "$(q "select archive_lag_bytes > wal_segment_bytes from pgvigil.backup_state where instance_id=$aid and kind='archiver'")" = t ] || fail "A2: lag over a segment"
echo "A2: OK"

rm -f "$FLAG"
before=$(t "select archived_count from pg_stat_archiver")
t "select pg_switch_wal()" >/dev/null
wait_count archived_count $((before + 2))
"$BIN" collect -config "$CFG" -once backups >/dev/null || fail "A3: collect"
show
[ "$(q "select count(*) from pgvigil.backup_state where instance_id=$aid and kind='archiver' and last_archived_time > last_failed_time")" = 1 ] || fail "A3: caught up"
[ "$(q "select count(*) from pgvigil.backup_rule_hits where instance_id=$aid")" = 0 ] || fail "A3: a rule hit after the catch-up"
[ "$(q "select count(*) from pgvigil.backup_sample where instance_id=$aid")" = 3 ] || fail "A3: samples"
echo "A3: OK"
a4=$(cd "$(dirname "$0")/.." && PGVIGIL_BACKUPS_PROOF_DSN="$PGVIGIL_REPO_DSN" PGVIGIL_BACKUPS_PROOF_INSTANCE=$aid \
    go test -count=1 -v -run TestBackupsProof ./internal/web 2>&1) || { echo "$a4"; fail "A4: the handlers"; }
grep -q -- '--- PASS: TestBackupsProof' <<<"$a4" || { echo "$a4"; fail "A4: the test did not run (skipped?)"; }
echo "A4: OK"

echo "--- B. the archive-age rule on seeded archiver rows"
# arch <instance> <archive_mode> <minutes since the last archive, or null> <lag bytes or null> <warn minutes> <is_replica> [failed after]
arch() {
  local la=null lf=null
  [ "$3" != null ] && la="\"$(q "select to_json(now() - interval '$3 minutes')#>>'{}'")\""
  [ "${7:-}" = failed ] && lf="\"$(q "select to_json(now() - interval '1 minute')#>>'{}'")\""
  q "select pgvigil.import_backups($1, now(), '[{\"kind\":\"archiver\",\"name\":\"pg_stat_archiver\",\"archive_mode\":\"$2\",\"archive_set\":true,
       \"archived_count\":10,\"failed_count\":$([ "${7:-}" = failed ] && echo 3 || echo 0),\"last_archived_wal\":\"000000010000000000000009\",
       \"last_archived_time\":$la,\"last_failed_time\":$lf,\"last_failed_wal\":$([ "${7:-}" = failed ] && echo '"00000001000000000000000A"' || echo null),
       \"is_replica\":$6,\"wal_segment_bytes\":16777216,\"archive_lag_bytes\":$4,\"archive_warn_minutes\":$5}]')" >/dev/null
}
inst() { q "select pgvigil.ensure_instance('backups-$1-$SUF', '$2', 'proof', 180000, false, '{proof}')"; }
b1=$(inst b1 onprem); b2=$(inst b2 onprem); b3=$(inst b3 onprem); b4=$(inst b4 onprem); b5=$(inst b5 aurora); b6=$(inst b6 onprem); b7=$(inst b7 onprem)
b8=$(inst b8 onprem); b9=$(inst b9 onprem)
arch "$b1" on 90 50331648 60 false
arch "$b2" on 90 1048576 60 false
arch "$b3" on 90 50331648 120 false
arch "$b4" on 90 null 60 true
arch "$b5" on 2 50331648 60 false failed
arch "$b6" on null 50331648 60 false
arch "$b7" off 90 50331648 60 false
arch "$b8" always 90 50331648 60 true
arch "$b9" off 2 1048576 60 false failed
got=$(q "select string_agg(replace(i.name, '-$SUF', '') || '|' || h.check_name || '|' || h.severity, ',' order by i.name)
           from pgvigil.backup_rule_hits h join pgvigil.instances i using (instance_id) where h.instance_id in ($b1,$b2,$b3,$b4,$b5,$b6,$b7,$b8,$b9)")
echo "  $got"
[ "$got" = "backups-b1|last archive older than 60 min|warning,backups-b6|last archive older than 60 min|warning,backups-b8|last archive older than 60 min|warning" ] || fail "B: rule hits"
[ "$(q "select detail from pgvigil.backup_rule_hits where instance_id=$b6")" = "nothing archived since the stats reset; 48 MB of WAL waiting" ] || fail "B: b6 detail"
echo "B: OK"

echo "--- C. the cloud rules on seeded RDS / Aurora rows"
ago() { q "select to_json(now() - interval '$1')#>>'{}'"; }
c1=$(inst c1 rds); c2=$(inst c2 rds); c3=$(inst c3 aurora); c4=$(inst c4 aurora)
q "select pgvigil.import_backups($c1, now(), '[{\"kind\":\"cloud\",\"name\":\"c1-db\",\"resource_kind\":\"instance\",\"retention_days\":3,\"latest_restorable_time\":\"$(ago '10 minutes')\"},
     {\"kind\":\"snapshot\",\"name\":\"rds:c1-a\",\"snapshot_type\":\"automated\",\"status\":\"available\",\"created_at\":\"$(ago '2 hours')\"},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":1}]')" >/dev/null
q "select pgvigil.import_backups($c2, now(), '[{\"kind\":\"cloud\",\"name\":\"c2-db\",\"resource_kind\":\"instance\",\"retention_days\":0},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":0}]')" >/dev/null
q "select pgvigil.import_backups($c3, now(), '[{\"kind\":\"cloud\",\"name\":\"c3-cl\",\"resource_kind\":\"cluster\",\"retention_days\":7,\"latest_restorable_time\":\"$(ago '5 minutes')\"},
     {\"kind\":\"snapshot\",\"name\":\"rds:c3-a\",\"snapshot_type\":\"automated\",\"status\":\"available\",\"created_at\":\"$(ago '30 hours')\"},
     {\"kind\":\"snapshot\",\"name\":\"c3-manual\",\"snapshot_type\":\"manual\",\"status\":\"creating\",\"created_at\":\"$(ago '1 hour')\"},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":2}]')" >/dev/null
q "select pgvigil.import_backups($c4, now(), '[{\"kind\":\"cloud\",\"name\":\"c4-cl\",\"resource_kind\":\"cluster\",\"retention_days\":14,\"latest_restorable_time\":\"$(ago '5 minutes')\"},
     {\"kind\":\"snapshot\",\"name\":\"rds:c4-a\",\"snapshot_type\":\"automated\",\"status\":\"available\",\"created_at\":\"$(ago '3 hours')\"},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":1}]')" >/dev/null
c5=$(inst c5 rds); c6=$(inst c6 rds)
q "select pgvigil.import_backups($c5, now(), '[{\"kind\":\"archiver\",\"name\":\"pg_stat_archiver\",\"archive_mode\":\"on\",\"archive_set\":true,\"is_replica\":true,\"archived_count\":0,\"failed_count\":0},
     {\"kind\":\"cloud\",\"name\":\"c5-replica\",\"resource_kind\":\"instance\",\"retention_days\":0},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":0}]')" >/dev/null
q "select pgvigil.import_backups($c6, now() - interval '2 hours', '[{\"kind\":\"cloud\",\"name\":\"c6-db\",\"resource_kind\":\"instance\",\"retention_days\":3},
     {\"kind\":\"snapshot\",\"name\":\"rds:c6-a\",\"snapshot_type\":\"automated\",\"status\":\"available\",\"created_at\":\"$(ago '3 hours')\"},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":1}]')" >/dev/null
got=$(q "select string_agg(replace(i.name, '-$SUF', '') || '|' || h.check_name || '|' || h.severity, ',' order by i.name, h.check_name)
           from pgvigil.backup_checks h join pgvigil.instances i using (instance_id) where h.instance_id in ($c1,$c2,$c3,$c4,$c5,$c6)")
echo "  $got"
[ "$got" = "backups-c1|retention under 7 days|warning,backups-c2|no snapshot in 24 h|warning,backups-c2|retention under 7 days|critical,backups-c3|no snapshot in 24 h|warning" ] || fail "C: rule hits"
[ "$(q "select count(*) || '|' || string_agg(distinct platforms, ',') from pgvigil.backup_findings where instance_id in ($c1,$c2,$c3,$c4,$c5,$c6)")" = "4|managed" ] || fail "C: findings"
[ "$(q "select count(*) from pgvigil.backup_rule_hits where instance_id = $c6 and check_name = 'retention under 7 days'")" = 1 ] || fail "C: c6 stale hit kept in backup_rule_hits"
[ "$(q "select restorable_age_s from pgvigil.backup_status where instance_id=$c1")" = 600 ] || fail "C: restorable age"
q "select pgvigil.import_backups($c3, now(), '[{\"kind\":\"cloud\",\"name\":\"c3-cl\",\"resource_kind\":\"cluster\",\"retention_days\":7},
     {\"kind\":\"snapshot\",\"name\":\"c3-manual\",\"snapshot_type\":\"manual\",\"status\":\"available\",\"created_at\":\"$(ago '1 hour')\"},
     {\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":1}]')" >/dev/null
[ "$(q "select string_agg(name || '|' || is_present, ',' order by name) from pgvigil.backup_state where instance_id=$c3 and kind='snapshot'")" = "c3-manual|true,rds:c3-a|false" ] || fail "C: snapshot absence"
q "select pgvigil.import_backups($c3, now(), '[{\"kind\":\"collector_error\",\"source\":\"backups:snapshots\",\"message\":\"refused\"}]')" >/dev/null
[ "$(q "select string_agg(kind || '|' || name || '|' || is_present, ',' order by kind, name) from pgvigil.backup_state where instance_id=$c3")" = "cloud|c3-cl|true,snapshot|c3-manual|true,snapshot|rds:c3-a|false" ] || fail "C: an error-only payload changed the rows"
echo "C: OK"

echo "--- D. the AWS side"
( cd "$(dirname "$0")/.." && go test -count=1 -run Backups ./internal/collect ) || fail "D: go test"
if [ "${LAB:-0}" = 1 ]; then
  PROFILE=${AWS_PROFILE:-dba-lab}; CLUSTER=${CLUSTER:-dba-lab-pg}; REGION=${AWS_REGION:-us-east-2}
  H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE")
  [ -n "$H" ] && [ "$H" != "None" ] || fail "D: no writer endpoint for $CLUSTER"
  TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE")
  export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require password=$TOKEN"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-backups-aurora-$SUF
    dsn: env:AURORA_DSN
    aws:
      region: $REGION
      profile: $PROFILE
      cluster: $CLUSTER
EOF
  "$BIN" collect -config "$CFG" -once backups || fail "D: collect"
  lid=$(q "select instance_id from pgvigil.instances where name='proof-backups-aurora-$SUF'")
  q "select '  ' || kind || '|' || name || coalesce('|' || resource_kind, '') || coalesce('|retention ' || retention_days, '')
       || coalesce('|' || snapshot_type || '|' || status || '|' || created_at, '') from pgvigil.backup_state where instance_id=$lid order by 1"
  [ "$(q "select count(*) from pgvigil.backup_state where instance_id=$lid and kind='cloud' and name='$CLUSTER' and resource_kind='cluster'
          and retention_days >= 1 and latest_restorable_time > now() - interval '1 day'")" = 1 ] || fail "D: cloud row"
  [ "$(q "select count(*) >= 1 from pgvigil.backup_state where instance_id=$lid and kind='snapshot' and snapshot_type='automated'")" = t ] || fail "D: automated snapshot"
  echo "D: OK (constructed answers and the lab live)"
else
  echo "D: OK on the constructed answers; the lab live read not run (LAB=1 runs it)"
fi
echo "proof-backups: OK"
