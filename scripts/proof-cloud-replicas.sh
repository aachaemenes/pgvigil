#!/usr/bin/env bash
# Proof of task 390b on real replicas: the provider replica read (cloud_replicas: RDS DescribeDBInstances and CloudWatch
# ReplicaLag; Cloud SQL Admin and Cloud Monitoring) as pgvigil reads, stores, judges and shows it, each fault made, its
# finding read, cleared and the clear read. Part R drives lab RP (scripts/lab/aws-rds-replica.sh: up, allow, logins
# done before; replica, reboot, promote here); part C drives lab CP (scripts/lab/gcp-cloudsql.sh) and runs only with
# PGVIGIL_PROOF_CP=1 - CP waits for Allen's own word (the lead's Q10): until then each C row is 'not proven: CP waits
# for Allen's word'.
#
# Runs on the machine that holds the AWS CLI sign-in (and gcloud's application-default sign-in for part C): no
# credential or token goes to a cloud box (the lab rule of 2026-11-14); the repository is reached from here (the A1-E
# form: the box's PostgreSQL through a tunnel). Needs psql, jq, python3, aws, PGVIGIL_BIN (a built pgvigil) or a go
# toolchain, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the repository is made there)
#   PGVIGIL_LAB_AWS_PROFILE, PGVIGIL_LAB_AWS_REGION, PGVIGIL_LAB_PROOF   as the lab script (its state file .lab/aws-rds-replica.env)
#   PGVIGIL_PROOF_DENY_PROFILE  (R-G, optional) an AWS profile whose identity may read CloudWatch but not
#                            rds:DescribeDBInstances; without it R-G is 'not proven: no such profile here'
#
# Expected (written before the first run; red first: on a tree without 390b, cloud_replicas is an unknown collection
# and every R row FAILs):
#  R-A the source alone: cloud_replicas ok; one cloud_replicas row, the source 'standalone', no replica, no finding.
#  R-B replica: while it is made, no 'provider replica stopped' (fold 9: a blank status is 'not reported yet'); within
#      15 minutes of it being available: the source 'source' with replica_ids = [the replica], the replica 'replica'
#      with source_id = the source and repl_status 'replicating', at least one replica_lag datapoint; the source's
#      'added' event; both instances' pages (GET /api/cloud/replicas) list both resources; the replica's own read stores
#      no second row of either.
#  R-C replay held by a long REPEATABLE READ on the replica (max_standby_streaming_delay -1 in the lab's parameter
#      group; a delete and VACUUM of the proof's table on the source, a write every 20 s) for 12 minutes: the
#      'provider replica lag' finding at the DEFAULT tiers (warning 600 s) on both instances; released: the clear read
#      within 10 minutes; then an instance-level tier on the source (warn 10, crit 15 minutes) and a 16-minute hold: the
#      finding critical on the source, warning on the replica (the default); the tier taken back (inherit).
#  R-D 15 idle minutes: the idle lag's maximum printed (AWS: 'up to five minutes' on an idle source), no lag finding at
#      the defaults.
#  R-E the replica rebooted: its status read 'rebooting' (or the read between), no 'provider lag missing' and no
#      'stopped' while it reboots, 'available' again with datapoints after it.
#  R-F promote: the replica 'standalone' with a 'promoted' event, the source's 'removed' event, the 'replica promoted or
#      detached' finding (warning) on both instances.
#  R-G a profile without rds:DescribeDBInstances: the read row's note names AccessDenied and the right, the run
#      partial, the lag still read; after 3 such reads the 'cloud door failing' finding.
#  P3 the provider's failover event: NOT PROVEN (an RDS Multi-AZ DB instance is billed and not approved); the Go cases
#      and the store row prove the hand-off.
#  C-A..C-F (Cloud SQL, the same as R-A..R-F): the source alone; the replica made (masterInstanceName / replicaNames:
#      one trial; replica_lag on the replica's cloudsql_database; replica_byte_lag from the primary, replay_location);
#      replay held 12 minutes (the Cloud SQL flag max_standby_streaming_delay -1); 45 idle minutes (fold 6: whether
#      replica_lag grows on an idle primary, printed); `gcloud sql instances patch <replica> --no-enable-database-
#      replication`: 'provider replica stopped' critical in two reads, re-enabled: cleared; promote-replica: 'promoted'.
set -Eeuo pipefail
trap 'echo "STOPPED: line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
: "${PGVIGIL_LAB_AWS_PROFILE:?the AWS CLI profile}" "${PGVIGIL_LAB_AWS_REGION:?the region}" "${PGVIGIL_LAB_PROOF:?the tag value of the lab}"
LAB=scripts/lab/aws-rds-replica.sh
STATE=${PGVIGIL_LAB_DIR:-.lab}/aws-rds-replica.env
for t in psql jq python3 aws; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
[ -r "$STATE" ] || { echo "FAIL: no lab state file $STATE (aws-rds-replica.sh up, allow, logins)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
: "${SRC_ID:?} ${REP_ID:?} ${SRC_HOST:?} ${ADMIN_USER:?} ${ADMIN_PW:?} ${MON_USER:?} ${MON_PW:?}"
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_crproof_$SUF; N=proof-cr-$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
MADE_DB=; MADE_T=; HOLD_PID=; WRITE_PID=
FAILS=(); NOTPROVEN=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
# src / rep "<sql>": a statement as the master user on the source or the replica
src() { PGPASSWORD="$ADMIN_PW" psql "host=$SRC_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
rep() { PGPASSWORD="$ADMIN_PW" psql "host=$REP_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
stopbg() { for p in $HOLD_PID $WRITE_PID; do kill "$p" 2>/dev/null || true; done; HOLD_PID=; WRITE_PID=; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  stopbg
  if [ -n "$MADE_T" ]; then src "DROP TABLE IF EXISTS public.pgvproof_cr_$SUF" >/dev/null 2>&1 || echo "CLEANUP: public.pgvproof_cr_$SUF not dropped (down removes the instance)" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else
  command -v go >/dev/null || die "go is not on this machine and PGVIGIL_BIN names no binary"
  CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
pgdsn() { printf 'host=%s port=5432 user=%s password=%s dbname=postgres sslmode=require' "$1" "$MON_USER" "$MON_PW"; }
export CR_SRC_DSN; CR_SRC_DSN=$(pgdsn "$SRC_HOST")
export CR_REP_DSN=
writecfg() {   # the source, and the replica once it is up; P1's door on (aws.replicas), the lab's profile and region
  { echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
    for x in "src|CR_SRC_DSN|$SRC_ID|$PGVIGIL_LAB_AWS_PROFILE" ${REP_HOST:+"rep|CR_REP_DSN|$REP_ID|$PGVIGIL_LAB_AWS_PROFILE"} \
             ${PGVIGIL_PROOF_DENY_PROFILE:+"deny|CR_SRC_DSN|$SRC_ID|$PGVIGIL_PROOF_DENY_PROFILE"}; do
      IFS='|' read -r k v id prof <<<"$x"
      printf '  - name: %s-%s\n    dsn: env:%s\n    platform: rds\n    aws:\n      region: %s\n      profile: %s\n      db_instance: %s\n      replicas: true\n' \
        "$N" "$k" "$v" "$PGVIGIL_LAB_AWS_REGION" "$prof" "$id"
    done; } > "$CFG"; }
run() { "$BIN" collect -config "$CFG" -once cloud_replicas -instance "$N-$1" > "$WORK/cr.$1.out" 2>&1 || true; }
status() { q "SELECT d.status || '|' || coalesce(d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$N-$1' AND d.collection = 'cloud_replicas'"; }
iid() { q "SELECT instance_id FROM pgvigil.instances WHERE name = '$N-$1'"; }
finding() { q "SELECT coalesce(max(f.severity), '') FROM pgvigil.cloud_replica_findings f WHERE f.instance_id = $(iid "$1") AND f.check_name = '$2' AND f.object = '$3'"; }
tier() { q "SELECT pgvigil.import_pg_threshold(now(), jsonb_build_object('op', '$2', 'ui_user', 'proof', 'key', 'provider_replica_lag', 'level', 'instance', 'instance_id', $(iid "$1"), 'warn', ${3:-null}, 'crit', ${4:-null}))" >/dev/null; }
writecfg; "$BIN" migrate -config "$CFG" >/dev/null

echo "--- R-A the source alone"
run src
S=$(status src); R=$(q "SELECT role || '|' || cardinality(replica_ids) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = '$SRC_ID'")
F=$(q "SELECT count(*) FROM pgvigil.cloud_replica_findings WHERE instance_id = $(iid src)")
echo "  cloud_replicas: $S; the source: $R; findings: $F"
[[ $S == ok* ]] && [ "$R" = "standalone|0" ] && [ "$F" = 0 ] && echo "R-A: OK" || bad "R-A: '$S' '$R' findings $F (want ok, standalone|0, 0)"

echo "--- R-B the replica made"
"$LAB" replica | sed 's/^/  lab: /' &
LP=$!
STOPPED_SEEN=
while kill -0 "$LP" 2>/dev/null; do run src; [ -n "$(finding src 'provider replica stopped' "$REP_ID")" ] && STOPPED_SEEN=1; sleep 60; done
wait "$LP" || die "R-B: the replica was not made (the lab's output above)"
# shellcheck disable=SC1090
. "$STATE"
CR_REP_DSN=$(pgdsn "$REP_HOST"); writecfg
for i in $(seq 1 15); do
  run src; run rep
  T=$(q "SELECT string_agg(resource_id || ':' || role || ':' || coalesce(source_id, '') || ':' || array_to_string(replica_ids, ',') || ':' || repl_status, ' ' ORDER BY resource_id) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id IN ('$SRC_ID', '$REP_ID')")
  P=$(q "SELECT count(*) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_ID' AND metric = 'replica_lag'")
  [ "$T" = "$SRC_ID:source::$REP_ID: $REP_ID:replica:$SRC_ID::replicating" ] && [ "$P" -gt 0 ] && break; sleep 60
done
AD=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = '$SRC_ID' AND kind = 'added' AND subject = '$REP_ID'")
ROWS=$(q "SELECT count(*) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id IN ('$SRC_ID', '$REP_ID')")
PAGES=$(q "SELECT count(*) FROM pgvigil.cloud_replica_readers WHERE instance_id IN ($(iid src), $(iid rep)) AND resource_id IN ('$SRC_ID', '$REP_ID')")
echo "  after $i minute(s): $T; datapoints $P; 'added' $AD; rows $ROWS; page rows $PAGES${STOPPED_SEEN:+; a 'stopped' finding while it was made}"
[ "$T" = "$SRC_ID:source::$REP_ID: $REP_ID:replica:$SRC_ID::replicating" ] && [ "$P" -gt 0 ] && [ "$AD" = 1 ] && [ "$ROWS" = 2 ] && [ "$PAGES" = 4 ] && [ -z "$STOPPED_SEEN" ] \
  && echo "R-B: OK" || bad "R-B: topology '$T', datapoints $P, added $AD, rows $ROWS, page rows $PAGES, stopped while made '${STOPPED_SEEN:-no}'"

# hold <minutes>: replay held on the replica (a REPEATABLE READ snapshot that a VACUUM's cleanup on the source conflicts
# with; the lab's max_standby_streaming_delay -1 makes replay wait for it) and a write every 20 s on the source
hold() {
  src "CREATE TABLE IF NOT EXISTS public.pgvproof_cr_$SUF (id int PRIMARY KEY, v int); INSERT INTO public.pgvproof_cr_$SUF SELECT g, 0 FROM generate_series(1, 1000) g ON CONFLICT DO NOTHING" >/dev/null; MADE_T=1
  sleep 20
  PGPASSWORD="$ADMIN_PW" psql "host=$REP_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require" -XAtq \
    -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM public.pgvproof_cr_$SUF; SELECT pg_sleep($1 * 60); COMMIT" >/dev/null 2>&1 &
  HOLD_PID=$!
  sleep 10
  src "DELETE FROM public.pgvproof_cr_$SUF WHERE id % 2 = 0; VACUUM public.pgvproof_cr_$SUF" >/dev/null
  ( while :; do src "INSERT INTO public.pgvproof_cr_$SUF VALUES ((random() * 1e9)::int, 1) ON CONFLICT DO NOTHING" >/dev/null 2>&1; sleep 20; done ) &
  WRITE_PID=$!
}
release() { stopbg; rep "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true; }

echo "--- R-C replay held 12 minutes at the default tiers"
hold 14
for i in $(seq 1 14); do sleep 60; run src; run rep; done
W1=$(finding src 'provider replica lag' "$REP_ID"); W2=$(finding rep 'provider replica lag' "$REP_ID")
L=$(q "SELECT round(max(value)) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_ID' AND metric = 'replica_lag' AND snapshot_at > now() - interval '15 minutes'")
release
for i in $(seq 1 10); do sleep 60; run src; run rep; [ -z "$(finding src 'provider replica lag' "$REP_ID")" ] && break; done
C1=$(finding src 'provider replica lag' "$REP_ID")
echo "  held: the source's '$W1', the replica's '$W2' (lag up to $L s); released: '$C1' after $i minute(s)"
[ "$W1" = warning ] && [ "$W2" = warning ] && [ -z "$C1" ] && echo "R-C (warning): OK" || bad "R-C: '$W1' '$W2' then '$C1' (want warning, warning, cleared)"
tier src set 10 15
hold 18
for i in $(seq 1 18); do sleep 60; run src; run rep; done
K1=$(finding src 'provider replica lag' "$REP_ID"); K2=$(finding rep 'provider replica lag' "$REP_ID")
release; tier src inherit
echo "  16 minutes held with the source's own tier 10 / 15: the source's '$K1', the replica's '$K2'"
[ "$K1" = critical ] && [ "$K2" = warning ] && echo "R-C (critical): OK" || bad "R-C critical: '$K1' '$K2' (want critical on the source, warning on the replica)"
for i in $(seq 1 10); do sleep 60; run src; run rep; [ -z "$(finding src 'provider replica lag' "$REP_ID")" ] && break; done

echo "--- R-D 15 idle minutes"
for i in $(seq 1 15); do sleep 60; run src; done
IL=$(q "SELECT round(max(value)) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_ID' AND metric = 'replica_lag' AND snapshot_at > now() - interval '15 minutes'")
D=$(finding src 'provider replica lag' "$REP_ID")
echo "  the idle lag's maximum: ${IL:-none} s; the finding: '${D}'"
[ -z "$D" ] && echo "R-D: OK" || bad "R-D: '$D' on an idle source at the defaults"

echo "--- R-E the replica rebooted"
"$LAB" reboot | sed 's/^/  lab: /'
SEEN=; MISS=; STOP=
for i in $(seq 1 12); do
  sleep 60; run src
  st=$(q "SELECT status FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = '$REP_ID'"); SEEN="$SEEN $st"
  [ -n "$(finding src 'provider lag missing' "$REP_ID")" ] && MISS=1
  [ -n "$(finding src 'provider replica stopped' "$REP_ID")" ] && STOP=1
  [ "$st" = available ] && [ $i -gt 2 ] && break
done
echo "  statuses read:$SEEN${MISS:+; 'lag missing' fired}${STOP:+; 'stopped' fired}"
[[ $SEEN == *available ]] && [ -z "$MISS$STOP" ] && echo "R-E: OK" || bad "R-E: statuses '$SEEN', lag missing '${MISS:-no}', stopped '${STOP:-no}'"

echo "--- R-F promote"
"$LAB" promote | sed 's/^/  lab: /'
for i in $(seq 1 10); do run src; run rep; [ "$(q "SELECT role FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = '$REP_ID'")" = standalone ] && break; sleep 60; done
PR=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = '$REP_ID' AND kind = 'promoted'")
RM=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = '$SRC_ID' AND kind = 'removed' AND subject = '$REP_ID'")
F1=$(finding rep 'replica promoted or detached' "$REP_ID"); F2=$(finding src 'replica promoted or detached' "$REP_ID")
echo "  promoted $PR, removed $RM; findings: the replica's '$F1', the source's '$F2'"
[ "$PR" = 1 ] && [ "$RM" = 1 ] && [ "$F1" = warning ] && [ "$F2" = warning ] && echo "R-F: OK" || bad "R-F: promoted $PR, removed $RM, '$F1', '$F2' (want 1, 1, warning, warning)"

echo "--- R-G a profile without rds:DescribeDBInstances"
if [ -n "${PGVIGIL_PROOF_DENY_PROFILE:-}" ]; then
  for i in 1 2 3; do run deny; sleep 5; done
  S=$(status deny); NT=$(q "SELECT coalesce(door_error, '') || '|' || door_fails FROM pgvigil.cloud_replica_reads WHERE instance_id = $(iid deny)")
  DF=$(q "SELECT count(*) FROM pgvigil.cloud_replica_findings WHERE instance_id = $(iid deny) AND check_name = 'cloud door failing'")
  echo "  run: $S; read: $NT; door failing findings: $DF"
  [[ $S == partial* ]] && [[ $NT == *AccessDenied*rds:DescribeDBInstances*\|3 ]] && [ "$DF" = 1 ] && echo "R-G: OK" || bad "R-G: '$S' '$NT' $DF"
else
  NOTPROVEN+=("R-G: no PGVIGIL_PROOF_DENY_PROFILE on this machine (an identity without rds:DescribeDBInstances); the Go case proves the sentence")
fi
NOTPROVEN+=("P3 (the provider's failover event): an RDS Multi-AZ DB instance is billed and not approved; the Go cases and the store row prove the hand-off")

echo "--- C-A..C-F (Cloud SQL)"
if [ "${PGVIGIL_PROOF_CP:-}" = 1 ]; then
  bad "C rows: PGVIGIL_PROOF_CP=1 but lab CP's steps are not written here yet: they follow Allen's word (the lead's Q10) with the lab's own commands"
else
  NOTPROVEN+=("C-A..C-F: CP waits for Allen's word (the lead's Q10)")
fi

echo
for n in "${NOTPROVEN[@]}"; do echo "NOT PROVEN: $n"; done
if [ ${#FAILS[@]} -gt 0 ]; then echo "cloud replicas: ${#FAILS[@]} FAIL"; for f in "${FAILS[@]}"; do echo "  $f"; done; exit 1; fi
echo "cloud replicas: every R row OK"
