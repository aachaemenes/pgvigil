#!/usr/bin/env bash
# Proof of the host collection (migration 0021). Four parts:
#   A. the system_stats door, on a throwaway PostgreSQL 18 container built with system_stats from EDB's source
#      (the extension is not in the PGDG repositories); skipped with "NOT PROVEN: ..." when docker or the build
#      is not available here.
#   B. no door: the sandbox itself (no system_stats, not RDS / Aurora) -> the collection is skipped with its reason.
#   C. the rules: seeded imports on scratch instances -> host_checks, host_findings, absence, the history's thinning.
#   D. the CloudWatch door on the AWS lab's Aurora cluster (AURORA=1; needs an active `aws login --profile dba-lab`).
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database and
#                      drops it (and its container) at the end; nothing that exists before the run is touched.
#   AURORA=1           run part D;  AWS_PROFILE default dba-lab;  CLUSTER default dba-lab-pg;  AWS_REGION default us-east-2
#
# Expected (written before the first run):
#  A. as a pg_monitor login without the grant: collect -once host is skipped, the note names
#     "GRANT monitor_system_stats"; after the grant: host_state 1 row, source system_stats, os_name not empty,
#     architecture x86_64 or aarch64, cpu_cores > 0, mem_total > 0, extension_version set; host_sample 1 row with
#     cpu_pct in 0..100 and mem_used > 0; host_disks >= 1 row, every one with total_bytes > 0 and free_bytes > 0, exactly
#     one holds_data (the data directory's volume), no tmpfs / overlay / proc rows, a device's bind mounts folded into one
#     row (rows = distinct devices); host_io >= 1 device. A second collect 2 s later: host_sample 2 rows, host_io 2
#     rows per device, host_disk_history still 1 row per volume (15-minute thinning), host_io_rate gives >= 1 row.
#  B. collection_dates for host: status 'skipped', note starting "no system_stats extension in database".
#  C. scratch instance 1 (system_stats): disks /data at 7 % free, /wal at 3 % free, /big at 60 % free; swap 2 GB used
#     of 8 GB; CPU 95 % on 6 samples over the last 10 minutes -> host_checks exactly:
#       CPU over 90 % for 10 minutes|warning|host, disk free under 10 %|critical|disk (/wal),
#       disk free under 10 %|warning|disk (/data), swap used|warning|host
#     scratch instance 2 (cloudwatch, Aurora shape): SwapUsage 10 MB, CPU 95 % on 3 samples only -> no check;
#     scratch instance 3 (cloudwatch, RDS shape): rds:storage 20 GiB with 1 GiB free (5 %, not under 5) ->
#       disk free under 10 %|warning; SwapUsage 100 MB -> swap used|warning
#       [review s2-32 fold, expected before the rerun: the cloud swap floor is now 1 GB (an idle Serverless instance
#        carries 325-384 MB), so instance 3 gives only 'disk free under 10 %|warning|rds:storage'; and two new scratch
#        instances raise nothing: instance 5 (cloudwatch) with 1 sample at 95 % and 4 samples without a CPU value;
#        instance 6 (cloudwatch) with 6 samples at 95 % over 10 minutes that all carry one metrics_at (one datapoint
#        repeated); instance 7 (system_stats) with the swap at 3 % of 8 GiB (under 5 %) raises nothing;
#        an import 5 minutes OLDER than instance 1's newest adds no history row]
#     host_findings rows = host_checks rows; a second import of instance 1 without /big marks it is_present false;
#     an import carrying a collector_error 'system_stats:disk' and no /data keeps /data present; disk_report lists
#     the present volumes only; host_disk_history keeps one row per volume across imports 1 minute apart.
#  D. host_state source cloudwatch, aws_resource the writer instance (dba-lab-pg-instance-1), os_name 'Amazon Aurora',
#     host_sample cpu_pct and mem_free not NULL within three collects 30 s apart (a paused Serverless instance publishes
#     after it resumes); no rds:storage row on Aurora.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_hostproof_$SUF
IMAGE=${SYSSTATS_IMAGE:-pgvigil-sysstats:18}; CTR=pgvigil-hostproof-$SUF
CFG=$(mktemp); BUILD=$(mktemp -d)
cleanup() {
  rm -rf "$CFG" "$BUILD"
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
export SANDBOX_DSN="$ADMIN_DSN"

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-host-none-$SUF
    dsn: env:SANDBOX_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null

echo "--- B. no door: the sandbox"
"$BIN" collect -config "$CFG" -once host
nid=$(q "select instance_id from pgvigil.instances where name='proof-host-none-$SUF'")
st=$(q "select status || '|' || note from pgvigil.collection_dates where instance_id=$nid and collection='host'")
echo "  $st"
[[ "$st" == "skipped|no system_stats extension in database"* ]] || fail "B: expected a skip naming the missing extension"
echo "B: OK"

echo "--- A. the system_stats door (container $IMAGE)"
A_DONE=0
if ! command -v docker >/dev/null 2>&1; then
  echo "NOT PROVEN (A): no docker on this machine to build system_stats"
else
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    cat > "$BUILD/Dockerfile" <<'EOF'
FROM postgres:18
RUN apt-get update -qq && apt-get install -y -qq git make gcc postgresql-server-dev-18 >/dev/null \
 && git clone -q --depth 1 https://github.com/EnterpriseDB/system_stats /tmp/ss \
 && cd /tmp/ss && make USE_PGXS=1 && make USE_PGXS=1 install \
 && apt-get purge -y -qq git make gcc postgresql-server-dev-18 >/dev/null && rm -rf /tmp/ss /var/lib/apt/lists/*
EOF
    docker build -q -t "$IMAGE" "$BUILD" >/dev/null 2>&1 || echo "NOT PROVEN (A): system_stats did not build here"
  fi
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    PW=p$RANDOM$RANDOM; MONPW=m$RANDOM$RANDOM
    docker run -d --name "$CTR" -e POSTGRES_PASSWORD="$PW" -p 127.0.0.1::5432 "$IMAGE" >/dev/null
    PORT=$(docker port "$CTR" 5432/tcp | head -1 | sed 's/.*://')
    [ -n "$PORT" ] || fail "A: the container published no port"
    up=0
    for _ in $(seq 60); do docker exec "$CTR" pg_isready -q -U postgres 2>/dev/null && psql "host=127.0.0.1 port=$PORT user=postgres password=$PW dbname=postgres" -XAtqc "select 1" >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
    [ "$up" = 1 ] || fail "A: the container never accepted a connection" 
    C="host=127.0.0.1 port=$PORT user=postgres password=$PW sslmode=disable"
    psql "$C dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database tgt" -c "create role mon login password '$MONPW' in role pg_monitor" >/dev/null
    psql "$C dbname=tgt" -XAtq -v ON_ERROR_STOP=1 -c "create extension system_stats" >/dev/null
    export SS_DSN="host=127.0.0.1 port=$PORT user=mon password=$MONPW dbname=tgt sslmode=disable"
    cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-host-ss-$SUF
    dsn: env:SS_DSN
EOF
    "$BIN" collect -config "$CFG" -once host
    sid=$(q "select instance_id from pgvigil.instances where name='proof-host-ss-$SUF'")
    st=$(q "select status || '|' || note from pgvigil.collection_dates where instance_id=$sid and collection='host'")
    echo "  without the grant: $st"
    [[ "$st" == skipped*"GRANT monitor_system_stats"* ]] || fail "A: expected a skip naming the grant"
    psql "$C dbname=tgt" -XAtq -c "grant monitor_system_stats to mon" >/dev/null
    "$BIN" collect -config "$CFG" -once host || fail "A: collect with the grant"
    q "select 'state: ' || source || ' | ' || os_name || ' | ' || coalesce(os_version, '') || ' | ' || architecture || ' | ' || cpu_cores || ' cores | '
              || pg_size_pretty(mem_total) || ' | system_stats ' || extension_version from pgvigil.host_state where instance_id=$sid"
    [ "$(q "select count(*) from pgvigil.host_state where instance_id=$sid and source='system_stats' and os_name <> ''
              and architecture in ('x86_64','aarch64') and cpu_cores > 0 and mem_total > 0 and extension_version is not null")" = 1 ] || fail "A: host_state"
    q "select 'sample: cpu ' || cpu_pct || ' % | mem used ' || pg_size_pretty(mem_used) || ' | load ' || load1 from pgvigil.host_sample where instance_id=$sid"
    [ "$(q "select count(*) from pgvigil.host_sample where instance_id=$sid and cpu_pct between 0 and 100 and mem_used > 0")" = 1 ] || fail "A: host_sample"
    q "select 'disk: ' || mount_point || ' ' || coalesce(device, '') || ' ' || coalesce(fs_type, '') || ' ' || pg_size_pretty(total_bytes) || ' free '
              || round(100.0 * free_bytes / total_bytes, 1) || ' % holds_data=' || holds_data || ' mounts=' || array_length(mounts, 1)
         from pgvigil.host_disks where instance_id=$sid order by 1"
    [ "$(q "select count(*) from pgvigil.host_disks where instance_id=$sid")" -ge 1 ] || fail "A: no disks"
    [ "$(q "select count(*) from pgvigil.host_disks where instance_id=$sid and (total_bytes <= 0 or free_bytes <= 0 or fs_type in ('tmpfs','overlay','proc'))")" = 0 ] || fail "A: a bad disk row"
    [ "$(q "select count(*) from pgvigil.host_disks where instance_id=$sid and holds_data")" = 1 ] || fail "A: exactly one volume holds the data directory"
    [ "$(q "select count(*) = count(distinct device) from pgvigil.host_disks where instance_id=$sid")" = t ] || fail "A: a device in two rows"
    ndev=$(q "select count(*) from pgvigil.host_io where instance_id=$sid"); echo "  io devices: $ndev"
    [ "$ndev" -ge 1 ] || fail "A: no io rows"
    sleep 2
    "$BIN" collect -config "$CFG" -once host >/dev/null || fail "A: second collect"
    [ "$(q "select count(*) from pgvigil.host_sample where instance_id=$sid")" = 2 ] || fail "A: host_sample after two collects"
    [ "$(q "select count(*) from pgvigil.host_io where instance_id=$sid")" = $((ndev * 2)) ] || fail "A: host_io after two collects"
    [ "$(q "select count(*) = (select count(*) from pgvigil.host_disks where instance_id=$sid) from pgvigil.host_disk_history where instance_id=$sid")" = t ] || fail "A: the history was not thinned"
    nr=$(q "select count(*) from pgvigil.host_io_rate($sid, now() - interval '1 hour', now())"); echo "  host_io_rate rows: $nr"
    [ "$nr" -ge 1 ] || fail "A: host_io_rate"
    A_DONE=1
    echo "A: OK"
  fi
fi

echo "--- C. the rules on seeded imports"
i1=$(q "select pgvigil.ensure_instance('host-rules-onprem-$SUF', 'onprem', 'proof', 180000, false, '{proof}')")
i2=$(q "select pgvigil.ensure_instance('host-rules-aurora-$SUF', 'aurora', 'proof', 170009, false, '{proof}')")
i3=$(q "select pgvigil.ensure_instance('host-rules-rds-$SUF', 'rds', 'proof', 170009, false, '{proof}')")
G=1073741824
host1() { echo "{\"kind\":\"host\",\"source\":\"system_stats\",\"os_name\":\"Red Hat Enterprise Linux 9.4 (Plow)\",\"architecture\":\"x86_64\",\"host_name\":\"db1\",\"cpu_cores\":8,\"mem_total\":$((32*G)),\"swap_total\":$((8*G)),\"swap_used\":$((2*G)),\"cpu_pct\":$1,\"mem_used\":$((20*G))}"; }
disk() { echo "{\"kind\":\"disk\",\"source\":\"system_stats\",\"mount_point\":\"$1\",\"device\":\"/dev/$2\",\"fs_type\":\"xfs\",\"total_bytes\":$((100*G)),\"free_bytes\":$(($3*G)),\"used_bytes\":$(((100-$3)*G)),\"mounts\":[\"$1\"],\"holds_data\":$4}"; }
for m in 9 8 6 4 2 0; do
  disks="$(disk /data sdb 7 true),$(disk /wal sdc 3 false),$(disk /big sdd 60 false)"
  q "select pgvigil.import_host($i1, now() - interval '$m minutes', '[$(host1 95), $disks]'::jsonb)" >/dev/null
done
cw2() { echo "{\"kind\":\"host\",\"source\":\"cloudwatch\",\"os_name\":\"Amazon Aurora\",\"aws_resource\":\"lab-1\",\"cpu_pct\":95,\"mem_free\":$G,\"swap_used\":10485760,\"connections\":5}"; }
for m in 4 2 0; do q "select pgvigil.import_host($i2, now() - interval '$m minutes', '[$(cw2)]'::jsonb)" >/dev/null; done
q "select pgvigil.import_host($i3, now(), '[{\"kind\":\"host\",\"source\":\"cloudwatch\",\"os_name\":\"Amazon RDS\",\"aws_resource\":\"rds-1\",\"cpu_pct\":20,\"swap_used\":104857600},
   {\"kind\":\"disk\",\"source\":\"cloudwatch\",\"mount_point\":\"rds:storage\",\"device\":\"rds-1\",\"total_bytes\":$((20*G)),\"free_bytes\":$G,\"used_bytes\":$((19*G))}]'::jsonb)" >/dev/null
got=$(q "select string_agg(check_name || '|' || severity || '|' || check_group || '|' || object, E'\n' order by check_name, severity, object)
           from pgvigil.host_checks where instance_id=$i1")
want=$'CPU over 90 % for 10 minutes|warning|host|db1\ndisk free under 10 %|critical|disk|/wal\ndisk free under 10 %|warning|disk|/data\nswap used|warning|host|db1'
echo "$got"
[ "$got" = "$want" ] || fail "C: instance 1 checks"
[ "$(q "select count(*) from pgvigil.host_checks where instance_id=$i2")" = 0 ] || fail "C: instance 2 should raise nothing"
got3=$(q "select string_agg(check_name || '|' || severity || '|' || object, ',' order by check_name) from pgvigil.host_checks where instance_id=$i3")
echo "$got3"
[ "$got3" = "disk free under 10 %|warning|rds:storage" ] || fail "C: instance 3 checks"
i5=$(q "select pgvigil.ensure_instance('host-rules-nullcpu-$SUF', 'rds', 'proof', 170009, false, '{proof}')")
i6=$(q "select pgvigil.ensure_instance('host-rules-repeat-$SUF', 'aurora', 'proof', 170009, false, '{proof}')")
i7=$(q "select pgvigil.ensure_instance('host-rules-swap-$SUF', 'onprem', 'proof', 180000, false, '{proof}')")
q "select pgvigil.import_host($i5, now() - interval '9 minutes', '[{\"kind\":\"host\",\"source\":\"cloudwatch\",\"cpu_pct\":95}]'::jsonb)" >/dev/null
for m in 7 5 3 1; do q "select pgvigil.import_host($i5, now() - interval '$m minutes', '[{\"kind\":\"host\",\"source\":\"cloudwatch\",\"mem_free\":$G}]'::jsonb)" >/dev/null; done
for m in 9 8 6 4 2 0; do q "select pgvigil.import_host($i6, now() - interval '$m minutes', '[{\"kind\":\"host\",\"source\":\"cloudwatch\",\"cpu_pct\":95,\"metrics_at\":\"$(date -u -d '-10 min' +%Y-%m-%dT%H:%M:00Z)\"}]'::jsonb)" >/dev/null; done
q "select pgvigil.import_host($i7, now(), '[{\"kind\":\"host\",\"source\":\"system_stats\",\"cpu_pct\":10,\"swap_total\":$((8*G)),\"swap_used\":$((G*3/100*8))}]'::jsonb)" >/dev/null
[ "$(q "select count(*) from pgvigil.host_checks where instance_id in ($i5,$i6,$i7)")" = 0 ] || fail "C: NULL CPU, a repeated datapoint or a small swap raised a check"
[ "$(q "select count(*) from pgvigil.host_findings where instance_id in ($i1,$i2,$i3)")" = "$(q "select count(*) from pgvigil.host_checks where instance_id in ($i1,$i2,$i3)")" ] || fail "C: findings vs checks"
[ "$(q "select count(*) from pgvigil.host_findings where instance_id=$i1 and source='pgvigil host' and is_set and platforms='all'")" = 4 ] || fail "C: findings columns"
[ "$(q "select count(*) from pgvigil.host_disk_history where instance_id=$i1")" = 3 ] || fail "C: history thinning (3 volumes, imports within 15 min)"
q "select pgvigil.import_host($i1, now() + interval '1 second', '[$(host1 50), $(disk /data sdb 7 true), $(disk /wal sdc 3 false)]'::jsonb)" >/dev/null
[ "$(q "select is_present from pgvigil.host_disks where instance_id=$i1 and mount_point='/big'")" = f ] || fail "C: /big should be absent"
q "select pgvigil.import_host($i1, now() + interval '2 seconds', '[$(host1 50), $(disk /wal sdc 3 false), {\"kind\":\"collector_error\",\"source\":\"system_stats:disk\",\"message\":\"x\"}]'::jsonb)" >/dev/null
[ "$(q "select is_present from pgvigil.host_disks where instance_id=$i1 and mount_point='/data'")" = t ] || fail "C: /data should be kept on a failed disk read"
[ "$(q "select count(*) from pgvigil.disk_report where instance_id=$i1")" = 2 ] || fail "C: disk_report present volumes"
[ "$(q "select string_agg(mount_point, ',' order by free_pct) from pgvigil.disk_report where instance_id in ($i1,$i3)")" = "/wal,rds:storage,/data" ] || fail "C: disk_report order"
nh=$(q "select count(*) from pgvigil.host_disk_history where instance_id=$i1")
q "select pgvigil.import_host($i1, now() - interval '5 minutes', '[$(host1 50), $(disk /data sdb 7 true)]'::jsonb)" >/dev/null
[ "$(q "select count(*) from pgvigil.host_disk_history where instance_id=$i1")" = "$nh" ] || fail "C: an older import added a history row"
echo "C: OK"

if [ "${AURORA:-0}" = 1 ]; then
  echo "--- D. the CloudWatch door on the lab's Aurora cluster"
  PROFILE=${AWS_PROFILE:-dba-lab}; CLUSTER=${CLUSTER:-dba-lab-pg}; REGION=${AWS_REGION:-us-east-2}
  H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE")
  [ -n "$H" ] && [ "$H" != "None" ] || fail "D: no writer endpoint for $CLUSTER"
  TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE")
  export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require password=$TOKEN"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-host-aurora-$SUF
    dsn: env:AURORA_DSN
    aws:
      region: $REGION
      profile: $PROFILE
      cluster: $CLUSTER
EOF
  aid=
  for n in 1 2 3; do
    AWS_PROFILE=$PROFILE "$BIN" collect -config "$CFG" -once host || fail "D: collect"
    aid=$(q "select instance_id from pgvigil.instances where name='proof-host-aurora-$SUF'")
    [ "$(q "select count(*) from pgvigil.host_latest where instance_id=$aid and cpu_pct is not null and mem_free is not null")" = 1 ] && break
    [ $n -lt 3 ] && { echo "  no datapoint yet (run $n); again in 30 s"; sleep 30; }
  done
  q "select 'aurora: ' || source || ' | ' || aws_resource || ' | ' || os_name || ' | cpu ' || coalesce(cpu_pct::text, '-') || ' % | freeable '
            || coalesce(pg_size_pretty(mem_free), '-') || ' | swap ' || coalesce(pg_size_pretty(swap_used), '-') || ' | conns '
            || coalesce(connections::text, '-') || ' | at ' || coalesce(metrics_at::text, '-') from pgvigil.host_latest where instance_id=$aid"
  [ "$(q "select count(*) from pgvigil.host_latest where instance_id=$aid and source='cloudwatch' and os_name='Amazon Aurora' and cpu_pct is not null and mem_free is not null")" = 1 ] || fail "D: CloudWatch rows"
  [ "$(q "select count(*) from pgvigil.host_disks where instance_id=$aid and mount_point='rds:storage'")" = 0 ] || fail "D: an rds:storage row on Aurora"
  echo "D: OK"
else
  echo "D: not run (AURORA=1 runs it)"
fi
[ "$A_DONE" = 1 ] && echo "proof-host: OK" || echo "proof-host: OK except A (NOT PROVEN: system_stats not available here)"
