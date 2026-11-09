#!/usr/bin/env bash
# Proof of the storage collection and the forecasts (migration 0033). Four parts:
#   A. the storage collection on the sandbox as a pg_monitor-only login (the WAL directory, the tablespaces).
#   B. a mount's free % through the host collection where system_stats exists (the throwaway PG18 container
#      proof-host.sh builds from EDB's source; "NOT PROVEN" when docker or the build is not available here).
#   C. the forecasts and checks on seeded growth rows (scratch instances in the proof's own repository).
#   D. the lab's Aurora cluster: VolumeBytesUsed through CloudWatch (AURORA=1; an active `aws login --profile dba-lab`).
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database, a login
#                      and (B) a container, and drops them at the end; nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A. collect -once storage twice: storage_state has wal|pg_wal with size_bytes > 0 and files > 0, and tablespace rows
#     pg_default and pg_global with size_bytes > 0 (no rds or aurora_volume row on the sandbox); storage_sample 2 rows per
#     object; collection status ok.
#  B. after collect -once host on the container: volume_forecast(<it>) lists the data volume with free_pct between 0 and
#     100, capacity = total, growth NULL (one point: too little history), days_until_full NULL.
#  C. seeded (history every 6 hours over 30 days, linear):
#     inst 1 (onprem): /data 100 GiB, 80 used, +1 GiB/day -> growth_7d about 1 GiB/day, days_until_full about 20 -> warning;
#                      /wal 100 GiB, 90 used, +2 GiB/day -> about 5 days -> critical;
#                      /flat 100 GiB, 50 used, no growth -> days NULL, no check;
#                      /young 100 GiB, 95 used, +5 GiB/day but only 6 hours of history -> growth NULL, days NULL;
#                      5 % free (not under 5) -> 'volume under 10 % free|warning'.
#     inst 2 (rds, no autoscaling): rds:storage 100 GiB, 4 GiB free, flat -> 'volume under 10 % free|critical' only.
#     inst 3 (rds, autoscaling to 1000 GiB): rds:storage 100 GiB, 5 GiB free, +1 GiB/day -> capacity 1000 GiB,
#                      days about 905, no check.
#     inst 4 (aurora): aurora_volume 10 GiB, +1 GiB/day -> capacity 128 TiB, no check.
#     storage_checks exactly: inst 1 'volume full within 30 days|critical|/wal', 'volume full within 30 days|warning|/data',
#     'volume under 10 % free|warning|/young'; inst 2 'volume under 10 % free|critical|rds:storage'; nothing for 3 and 4.
#     database_growth(inst 1): db 'grow' 10 GiB, +1 GiB/day over 10 days -> growth_7d about 1 GiB, days_to_double about 10;
#     db 'new' with 2 hours of history -> growth NULL. storage_findings rows = storage_checks rows.
#     A second import_storage without one tablespace marks it absent; one with only a collector_error keeps the rest.
#  D. storage_state aurora_volume|dba-lab-pg with size_bytes > 0 and limit_bytes 140737488355328; wal files 0 (Aurora
#     keeps no local WAL); the tablespaces read.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_storproof_$SUF; MON=pgvigil_stmon_$SUF; MONPW=p$RANDOM$RANDOM
IMAGE=${SYSSTATS_IMAGE:-pgvigil-sysstats:18}; CTR=pgvigil-storproof-$SUF
CFG=$(mktemp)
cleanup() {
  rm -f "$CFG"
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
export MON_DSN="$ADMIN_DSN user=$MON password=$MONPW"

echo "--- A. the storage collection on the sandbox (pg_monitor login)"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-storage-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once storage || fail "A: collect 1"
sleep 1
"$BIN" collect -config "$CFG" -once storage >/dev/null || fail "A: collect 2"
sid=$(q "select instance_id from pgvigil.instances where name='proof-storage-$SUF'")
q "select '  ' || kind || '|' || name || '|' || pg_size_pretty(size_bytes) || coalesce('|' || files || ' files', '') from pgvigil.storage_state where instance_id=$sid order by 1"
[ "$(q "select count(*) from pgvigil.storage_state where instance_id=$sid and kind='wal' and name='pg_wal' and size_bytes > 0 and files > 0")" = 1 ] || fail "A: wal row"
[ "$(q "select string_agg(name, ',' order by name) from pgvigil.storage_state where instance_id=$sid and kind='tablespace' and size_bytes > 0")" = "pg_default,pg_global" ] || fail "A: tablespace rows"
[ "$(q "select count(*) from pgvigil.storage_state where instance_id=$sid and kind in ('rds','aurora_volume')")" = 0 ] || fail "A: a cloud row on the sandbox"
[ "$(q "select count(*) = 2 * (select count(*) from pgvigil.storage_state where instance_id=$sid) from pgvigil.storage_sample where instance_id=$sid")" = t ] || fail "A: storage_sample rows"
[ "$(q "select status from pgvigil.collection_dates where instance_id=$sid and collection='storage'")" = ok ] || fail "A: status"
echo "A: OK"

echo "--- B. a mount's free % through system_stats (container $IMAGE)"
B_DONE=0
if command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
  PW=p$RANDOM$RANDOM; SSPW=m$RANDOM$RANDOM
  docker run -d --name "$CTR" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1::5432 "$IMAGE" >/dev/null
  PORT=$(docker port "$CTR" 5432/tcp | head -1 | sed 's/.*://')
  for _ in $(seq 60); do psql "host=127.0.0.1 port=$PORT user=postgres password=$PW dbname=postgres" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 1; done
  C="host=127.0.0.1 port=$PORT user=postgres password=$PW sslmode=disable dbname=postgres"
  psql "$C" -XAtq -v ON_ERROR_STOP=1 -c "create extension system_stats" -c "create role mon login password '$SSPW' in role pg_monitor, monitor_system_stats" >/dev/null
  export SS_DSN="host=127.0.0.1 port=$PORT user=mon password=$SSPW dbname=postgres sslmode=disable"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-storage-ss-$SUF
    dsn: env:SS_DSN
EOF
  "$BIN" collect -config "$CFG" -once host >/dev/null || fail "B: collect host"
  bid=$(q "select instance_id from pgvigil.instances where name='proof-storage-ss-$SUF'")
  q "select '  ' || volume || ' free ' || free_pct || ' % of ' || pg_size_pretty(total_bytes) || ' growth ' || coalesce(growth_7d_per_day::text, 'NULL')
       || ' days ' || coalesce(days_until_full::text, 'NULL') from pgvigil.volume_forecast($bid) where holds_data"
  [ "$(q "select count(*) from pgvigil.volume_forecast($bid) where holds_data and free_pct between 0 and 100 and capacity_bytes = total_bytes
            and growth_7d_per_day is null and days_until_full is null")" = 1 ] || fail "B: the data volume's free %"
  B_DONE=1
  echo "B: OK"
else
  echo "NOT PROVEN (B): no docker or no $IMAGE image here (scripts/proof-host.sh builds it)"
fi

echo "--- C. forecasts on seeded growth"
G=1073741824
i1=$(q "select pgvigil.ensure_instance('storage-rules-onprem-$SUF', 'onprem', 'proof', 180000, false, '{proof}')")
i2=$(q "select pgvigil.ensure_instance('storage-rules-rds-$SUF', 'rds', 'proof', 170009, false, '{proof}')")
i3=$(q "select pgvigil.ensure_instance('storage-rules-rdsauto-$SUF', 'rds', 'proof', 170009, false, '{proof}')")
i4=$(q "select pgvigil.ensure_instance('storage-rules-aurora-$SUF', 'aurora', 'proof', 170009, false, '{proof}')")
disk() { echo "{\"kind\":\"disk\",\"source\":\"$5\",\"mount_point\":\"$1\",\"total_bytes\":$(($2*G)),\"used_bytes\":$(($3*G)),\"free_bytes\":$((($2-$3)*G)),\"holds_data\":$4}"; }
host() { echo "{\"kind\":\"host\",\"source\":\"$1\"}"; }
q "select pgvigil.import_host($i1, now(), '[$(host system_stats), $(disk /data 100 80 true system_stats), $(disk /wal 100 90 false system_stats), $(disk /flat 100 50 false system_stats), $(disk /young 100 95 false system_stats)]'::jsonb)" >/dev/null
q "select pgvigil.import_host($i2, now(), '[$(host cloudwatch), $(disk rds:storage 100 96 false cloudwatch)]'::jsonb)" >/dev/null
q "select pgvigil.import_host($i3, now(), '[$(host cloudwatch), $(disk rds:storage 100 95 false cloudwatch)]'::jsonb)" >/dev/null
q "select pgvigil.import_storage($i2, now(), '[{\"kind\":\"rds\",\"name\":\"rds-a\",\"allocated_bytes\":$((100*G)),\"autoscaling\":false}]'::jsonb)" >/dev/null
q "select pgvigil.import_storage($i3, now(), '[{\"kind\":\"rds\",\"name\":\"rds-b\",\"allocated_bytes\":$((100*G)),\"max_allocated_bytes\":$((1000*G)),\"autoscaling\":true}]'::jsonb)" >/dev/null
# history every 6 hours back to 30 days (the import above wrote the row at now()); /young only 6 hours back
q "DO \$\$
DECLARE h int; t timestamptz;
BEGIN
  FOR h IN 1..120 LOOP
    t := now() - make_interval(hours => 6 * h);
    PERFORM pgvigil.ensure_month_partition('host_disk_history', t);
    PERFORM pgvigil.ensure_month_partition('storage_sample', t);
    INSERT INTO pgvigil.host_disk_history (instance_id, snapshot_at, mount_point, total_bytes, used_bytes, free_bytes) VALUES
      ($i1, t, '/data', 100::bigint*$G, (80::bigint*$G - h * 0.25 * $G)::bigint, (20::bigint*$G + h * 0.25 * $G)::bigint),
      ($i1, t, '/wal',  100::bigint*$G, (90::bigint*$G - h * 0.5 * $G)::bigint, (10::bigint*$G + h * 0.5 * $G)::bigint),
      ($i1, t, '/flat', 100::bigint*$G, 50::bigint*$G, 50::bigint*$G),
      ($i2, t, 'rds:storage', 100::bigint*$G, 96::bigint*$G, 4::bigint*$G),
      ($i3, t, 'rds:storage', 100::bigint*$G, (95::bigint*$G - h * 0.25 * $G)::bigint, (5::bigint*$G + h * 0.25 * $G)::bigint);
    IF h = 1 THEN
      INSERT INTO pgvigil.host_disk_history VALUES ($i1, t, '/young', 100::bigint*$G, (95::bigint*$G - 1.25 * $G)::bigint, (5::bigint*$G + 1.25 * $G)::bigint);
    END IF;
    INSERT INTO pgvigil.storage_sample (instance_id, snapshot_at, kind, name, size_bytes) VALUES ($i4, t, 'aurora_volume', 'lab', (10::bigint*$G - h * 0.25 * $G)::bigint);
  END LOOP;
END \$\$" >/dev/null
# the Aurora volume's current row, and the newest point of its history
q "select pgvigil.import_storage($i4, now(), '[{\"kind\":\"aurora_volume\",\"name\":\"lab\",\"size_bytes\":$((10*G)),\"limit_bytes\":140737488355328}]'::jsonb)" >/dev/null
q "select '  ' || instance || ' ' || volume || ' free ' || free_pct || ' % g7 ' || coalesce(pg_size_pretty(growth_7d_per_day::bigint), 'NULL') || ' g30 '
     || coalesce(pg_size_pretty(growth_30d_per_day::bigint), 'NULL') || ' capacity ' || pg_size_pretty(capacity_bytes) || ' days ' || coalesce(days_until_full::text, 'NULL')
     from pgvigil.volume_forecast(NULL) where instance_id in ($i1,$i2,$i3,$i4) order by instance, volume"
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; }
d_data=$(q "select days_until_full from pgvigil.volume_forecast($i1) where volume='/data'"); near "$d_data" 20 0.5 || fail "C: /data days $d_data"
d_wal=$(q "select days_until_full from pgvigil.volume_forecast($i1) where volume='/wal'"); near "$d_wal" 5 0.2 || fail "C: /wal days $d_wal"
g_data=$(q "select growth_7d_per_day from pgvigil.volume_forecast($i1) where volume='/data'"); near "$g_data" $G $((G / 100)) || fail "C: /data growth $g_data"
[ "$(q "select days_until_full is null from pgvigil.volume_forecast($i1) where volume='/flat'")" = t ] || fail "C: /flat should not forecast"
[ "$(q "select growth_7d_per_day is null and days_until_full is null from pgvigil.volume_forecast($i1) where volume='/young'")" = t ] || fail "C: /young has too little history"
[ "$(q "select capacity_bytes = 1000::bigint * $G and autoscaling from pgvigil.volume_forecast($i3)")" = t ] || fail "C: autoscaling capacity"
d3=$(q "select days_until_full from pgvigil.volume_forecast($i3)"); near "$d3" 905 2 || fail "C: rds autoscaling days $d3"
[ "$(q "select capacity_bytes = 140737488355328 and kind = 'aurora_volume' from pgvigil.volume_forecast($i4)")" = t ] || fail "C: aurora capacity"
got=$(q "select string_agg(i.name || '|' || c.check_name || '|' || c.severity || '|' || c.object, E'\n' order by i.name, c.check_name, c.object)
           from pgvigil.storage_checks c join pgvigil.instances i using (instance_id) where c.instance_id in ($i1,$i2,$i3,$i4)")
echo "$got"
want="storage-rules-onprem-$SUF|volume full within 30 days|warning|/data
storage-rules-onprem-$SUF|volume full within 30 days|critical|/wal
storage-rules-onprem-$SUF|volume under 10 % free|warning|/young
storage-rules-rds-$SUF|volume under 10 % free|critical|rds:storage"
[ "$got" = "$want" ] || fail "C: storage_checks"
[ "$(q "select count(*) from pgvigil.storage_findings where instance_id in ($i1,$i2,$i3,$i4)")" = 4 ] || fail "C: findings vs checks"
# database growth: 'grow' +1 GiB/day over 10 days, 'new' two hours of history
q "insert into pgvigil.databases (instance_id, dbid, datname, snapshot_at, size_bytes, first_seen, is_present, is_template)
   values ($i1, 1, 'grow', now(), 10::bigint*$G, now(), true, false), ($i1, 2, 'new', now(), $G, now(), true, false)" >/dev/null
q "DO \$\$ DECLARE h int; t timestamptz; BEGIN
     FOR h IN 0..40 LOOP
       t := now() - make_interval(hours => 6 * h);
       PERFORM pgvigil.ensure_month_partition('database_sizes', t);
       INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes) VALUES ($i1, t, 1, 'grow', (10::bigint*$G - h * 0.25 * $G)::bigint);
       IF h <= 2 THEN INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes) VALUES ($i1, t, 2, 'new', $G); END IF;
     END LOOP; END \$\$" >/dev/null
q "select '  db ' || datname || ' ' || pg_size_pretty(size_bytes) || ' g7 ' || coalesce(pg_size_pretty(growth_7d_per_day::bigint), 'NULL') || ' doubles in ' || coalesce(days_to_double::text, 'NULL')
     from pgvigil.database_growth($i1)"
dd=$(q "select days_to_double from pgvigil.database_growth($i1) where datname='grow'"); near "$dd" 10 0.2 || fail "C: days to double $dd"
[ "$(q "select growth_7d_per_day is null and days_to_double is null from pgvigil.database_growth($i1) where datname='new'")" = t ] || fail "C: new db has too little history"
q "select pgvigil.import_storage($i1, now(), '[{\"kind\":\"tablespace\",\"name\":\"ts1\",\"size_bytes\":1},{\"kind\":\"tablespace\",\"name\":\"ts2\",\"size_bytes\":1},{\"kind\":\"wal\",\"name\":\"pg_wal\",\"size_bytes\":1}]'::jsonb)" >/dev/null
q "select pgvigil.import_storage($i1, now(), '[{\"kind\":\"tablespace\",\"name\":\"ts1\",\"size_bytes\":1},{\"kind\":\"collector_error\",\"source\":\"storage:wal\",\"message\":\"x\"}]'::jsonb)" >/dev/null
[ "$(q "select string_agg(name || '=' || is_present, ',' order by name) from pgvigil.storage_state where instance_id=$i1")" = "pg_wal=true,ts1=true,ts2=false" ] || fail "C: absence"
echo "C: OK"

if [ "${AURORA:-0}" = 1 ]; then
  echo "--- D. VolumeBytesUsed on the lab's Aurora cluster"
  PROFILE=${AWS_PROFILE:-dba-lab}; CLUSTER=${CLUSTER:-dba-lab-pg}; REGION=${AWS_REGION:-us-east-2}
  H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE")
  [ -n "$H" ] && [ "$H" != "None" ] || fail "D: no writer endpoint for $CLUSTER"
  TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE")
  export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require password=$TOKEN"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-storage-aurora-$SUF
    dsn: env:AURORA_DSN
    aws:
      region: $REGION
      profile: $PROFILE
      cluster: $CLUSTER
EOF
  "$BIN" collect -config "$CFG" -once storage || fail "D: collect"
  aid=$(q "select instance_id from pgvigil.instances where name='proof-storage-aurora-$SUF'")
  q "select '  ' || kind || '|' || name || '|' || coalesce(pg_size_pretty(size_bytes), '-') || coalesce('|' || files || ' files', '') || coalesce('|limit ' || pg_size_pretty(limit_bytes), '')
       || coalesce('|at ' || metrics_at, '') from pgvigil.storage_state where instance_id=$aid order by 1"
  q "select '  ' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$aid and collection='storage'"
  [ "$(q "select count(*) from pgvigil.storage_state where instance_id=$aid and kind='aurora_volume' and name='$CLUSTER' and size_bytes > 0 and limit_bytes = 140737488355328")" = 1 ] || fail "D: VolumeBytesUsed"
  [ "$(q "select files from pgvigil.storage_state where instance_id=$aid and kind='wal'")" = 0 ] || fail "D: Aurora WAL files"
  echo "D: OK"
else
  echo "D: not run (AURORA=1 runs it)"
fi
[ "$B_DONE" = 1 ] && echo "proof-storage: OK" || echo "proof-storage: OK except B (NOT PROVEN: system_stats not available here)"
