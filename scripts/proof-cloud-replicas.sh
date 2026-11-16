#!/usr/bin/env bash
# Proof of task 390b on real replicas: the provider replica read (cloud_replicas: RDS DescribeDBInstances and CloudWatch
# ReplicaLag; Cloud SQL Admin and Cloud Monitoring) as pgvigil reads, stores, judges and shows it, each fault made, its
# finding read, cleared and the clear read. Part R drives lab RP (scripts/lab/aws-rds-replica.sh: up, allow, logins
# done before; replica, reboot, promote here); part C (lab CP, Cloud SQL) is scripts/proof-cloud-replicas-gcp.sh.
#
# Runs on the machine that holds the AWS CLI sign-in (and gcloud's application-default sign-in for part C): no
# credential or token goes to a cloud box (the lab rule of 2026-11-14); the repository is reached from here (the A1-E
# form: the box's PostgreSQL through a tunnel). Needs psql, jq, python3, aws, PGVIGIL_BIN (a built pgvigil) or a go
# toolchain, and
# Every run makes its own repository database and drops it (0151 is edited in place before the tag: a store that
# once applied 390a's 0151 would skip 390b's Part P, so no run reuses one).
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the repository is made there)
#   PGVIGIL_LAB_AWS_PROFILE, PGVIGIL_LAB_AWS_REGION, PGVIGIL_LAB_PROOF   as the lab script (its state file .lab/aws-rds-replica.env)
#   PGVIGIL_PROOF_DENY_PROFILE  (R-G, optional) an AWS profile whose identity may read CloudWatch but not
#                            rds:DescribeDBInstances; without it R-G is 'not proven: no such profile here'
#   PGVIGIL_PROOF_DOC_PROFILE   (R-H, optional) an AWS profile whose identity holds ONLY docs/cloud-replicas.md's policy,
#                            verbatim; without it R-H is 'not proven: no such profile here'
#   PGVIGIL_PROOF_ROWS       (optional) the rows to run after R-A and R-B, space-separated, default 'C D E H F G'; a
#                            row left out is a NOT PROVEN line of the pass (e.g. 'E' = a short pass: the reboot alone)
#
# Expected (written before the first run; red first: on a tree without 390b, cloud_replicas is an unknown collection
# and every R row FAILs):
#  R-A the source alone: cloud_replicas ok; one cloud_replicas row, the source 'standalone', no replica, no finding.
#  R-B replica: while it is made, no 'provider replica stopped' (fold 9: a blank status is 'not reported yet'); within
#      15 minutes of it being available: the source 'source' with replica_ids = [the replica], the replica 'replica'
#      with source_id = the source and repl_status 'replicating', at least one replica_lag datapoint; the source's
#      'added' event; both instances' pages (GET /api/cloud/replicas part=resources, from a pgvigil serve of the proof's
#      repository) list both resources; the replica's own read stores
#      no second row of either.
#  R-C replay held by a long REPEATABLE READ on the replica (max_standby_streaming_delay -1 in the lab's parameter
#      group; a delete and VACUUM of the proof's table on the source, a write every 20 s), 16 minutes of reads with
#      instance-level tiers (the source warn 1 / crit 2 minutes, the replica warn 1): the 'provider replica lag'
#      finding critical on the source, warning on the replica; released: both cleared within 10 minutes; the tiers
#      taken back (inherit). The default 10 minutes is the same rule with its own number: a hold would run past 21
#      minutes before every datapoint of a 10-minute window is over 600 s (review 055507 finding 4), so it is not held.
#  R-D 15 idle minutes: the idle lag's maximum printed (AWS: 'up to five minutes' on an idle source), no lag finding at
#      the defaults.
#  R-E the replica rebooted (CHANGED 2026-11-15 after lab RP's first whole pass: RDS's own events report 'Replication
#      has stopped.' for about 2.5 minutes after a reboot with the instance available, and the two-read rule of then
#      fired critical on it; the rule is by time now - a status that has stood 5 minutes): 20 reads 30 s apart, each
#      printing the stored status, replication status, its since, the read's time and the 'stopped' finding. Expected:
#      the stop met by a new read after the one that stored it (none = 'R-E: OK' with a NOT PROVEN line: the old
#      rule's case did not come), NO 'provider replica stopped' at any read, replicating again at the last read,
#      'available', a replica_lag datapoint dated after the first 'available' read by the end of the 20 reads or within
#      6 more; RDS's events of the replica printed. A stop RDS itself holds 5 minutes or longer fires the finding and
#      FAILs the row: graded from the printed rows and events. No 'provider lag missing' too, but WEAK: that rule needs
#      15 minutes without a datapoint, so it can fail here only in the last of the 6 trailing reads (part c finding 9).
#  R-F promote: the replica 'standalone' with a 'promoted' event, the source's 'removed' event, the 'replica promoted or
#      detached' finding (warning) on both instances.
#  R-G a profile without rds:DescribeDBInstances: the read row's note names AccessDenied and the right, the run
#      partial, the lag still read; after 3 such reads the 'cloud door failing' finding.
#  R-H (before R-F, while the replica stands) the documented policy verbatim: a run 'ok', no refused call (door_fails
#      0, no door error) - DescribeDBInstances, DescribeEvents and GetMetricData all allowed by it (part c finding 3).
#  P3 the provider's failover event: NOT PROVEN (an RDS Multi-AZ DB instance is billed and not approved); the Go cases
#      and the store row prove the hand-off.
#  C-A..C-F (Cloud SQL, the same as R-A..R-F): the source alone; the replica made (masterInstanceName / replicaNames:
#      one trial; replica_lag on the replica's cloudsql_database; replica_byte_lag from the primary, replay_location);
#      replay held 12 minutes (the Cloud SQL flag max_standby_streaming_delay -1); 45 idle minutes (fold 6: whether
#      replica_lag grows on an idle primary, printed); `gcloud sql instances patch <replica> --no-enable-database-
#      replication`: 'provider replica stopped' critical once the status has stood 5 minutes, re-enabled: cleared;
#      promote-replica: 'promoted'.
set -Eeuo pipefail
trap 'echo "STOPPED: line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
: "${PGVIGIL_LAB_AWS_PROFILE:?the AWS CLI profile}" "${PGVIGIL_LAB_AWS_REGION:?the region}" "${PGVIGIL_LAB_PROOF:?the tag value of the lab}"
LAB=scripts/lab/aws-rds-replica.sh
STATE=${PGVIGIL_LAB_DIR:-.lab}/aws-rds-replica.env
for t in psql jq python3 aws curl; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
[ -r "$STATE" ] || { echo "FAIL: no lab state file $STATE (aws-rds-replica.sh up, allow, logins)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
: "${SRC_ID:?} ${REP_ID:?} ${SRC_HOST:?} ${ADMIN_USER:?} ${ADMIN_PW:?} ${MON_USER:?} ${MON_PW:?}"
# the keys pgvigil stores (390b ID (a)): each DB instance's lower-cased DBInstanceArn, as AWS answers it for the source;
# the replica's built from the source's partition, region and account (its same-region form), checked against AWS's own
# answer once the replica stands (R-B)
SRC_KEY=$(aws --profile "$PGVIGIL_LAB_AWS_PROFILE" --region "$PGVIGIL_LAB_AWS_REGION" rds describe-db-instances --db-instance-identifier "$SRC_ID" \
  --query 'DBInstances[0].DBInstanceArn' --output text | tr '[:upper:]' '[:lower:]')
[[ $SRC_KEY == arn:*:rds:*:db:* ]] || { echo "FAIL: the source's DBInstanceArn was not read ('$SRC_KEY')" >&2; exit 1; }
REP_KEY="${SRC_KEY%:db:*}:db:$(tr '[:upper:]' '[:lower:]' <<<"$REP_ID")"
# the rows of this pass: R-A and R-B always (every other row needs the replica), then PGVIGIL_PROOF_ROWS (unset = all;
# set and empty = R-A and R-B only); checked before anything is made (review 112616 finding 7)
ROWS=${PGVIGIL_PROOF_ROWS-C D E H F G}
for r in $ROWS; do case $r in C|D|E|H|F|G) ;; *) echo "FAIL: PGVIGIL_PROOF_ROWS names '$r' (C D E H F G, space-separated)" >&2; exit 1 ;; esac; done
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_crproof_$SUF; N=proof-cr-$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
MADE_DB=; MADE_T=; HOLD_PID=; WRITE_PID=; SRV_PID=
FAILS=(); NOTPROVEN=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
want() { case " $ROWS " in *" $1 "*) return 0 ;; esac; NOTPROVEN+=("R-$1: not run in this pass (PGVIGIL_PROOF_ROWS='$ROWS')"); return 1; }
die() { echo "FAIL: $*" >&2; exit 1; }
# src / rep "<sql>": a statement as the master user on the source or the replica
src() { PGPASSWORD="$ADMIN_PW" psql "host=$SRC_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
rep() { PGPASSWORD="$ADMIN_PW" psql "host=$REP_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
stopbg() { for p in $HOLD_PID $WRITE_PID; do kill "$p" 2>/dev/null || true; done; HOLD_PID=; WRITE_PID=; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  stopbg
  [ -z "$SRV_PID" ] || kill "$SRV_PID" 2>/dev/null
  if [ -n "$MADE_T" ]; then src "DROP TABLE IF EXISTS public.pgvproof_cr_$SUF" >/dev/null 2>&1 || echo "CLEANUP: public.pgvproof_cr_$SUF not dropped (down removes the instance)" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  [ ! -r "$STATE" ] || echo "the lab is still up (billed until down): $LAB down" >&2   # part c finding 13
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
             ${PGVIGIL_PROOF_DENY_PROFILE:+"deny|CR_SRC_DSN|$SRC_ID|$PGVIGIL_PROOF_DENY_PROFILE"} \
             ${PGVIGIL_PROOF_DOC_PROFILE:+"doc|CR_SRC_DSN|$SRC_ID|$PGVIGIL_PROOF_DOC_PROFILE"}; do
      IFS='|' read -r k v id prof <<<"$x"
      printf '  - name: %s-%s\n    dsn: env:%s\n    platform: rds\n    aws:\n      region: %s\n      profile: %s\n      db_instance: %s\n      replicas: true\n' \
        "$N" "$k" "$v" "$PGVIGIL_LAB_AWS_REGION" "$prof" "$id"
    done; } > "$CFG"; }
run() { "$BIN" collect -config "$CFG" -once cloud_replicas -instance "$N-$1" > "$WORK/cr.$1.out" 2>&1 || true; }
status() { q "SELECT d.status || '|' || coalesce(d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$N-$1' AND d.collection = 'cloud_replicas'"; }
iid() { q "SELECT instance_id FROM pgvigil.instances WHERE name = '$N-$1'"; }
finding() { q "SELECT coalesce(max(f.severity), '') FROM pgvigil.cloud_replica_findings f WHERE f.instance_id = $(iid "$1") AND f.check_name = '$2' AND f.object = '$3'"; }
tier() { local o; o=$(q "SELECT pgvigil.import_pg_threshold(now(), jsonb_build_object('op', '$2', 'ui_user', 'proof', 'key', 'provider_replica_lag', 'level', 'instance', 'instance_id', $(iid "$1"), 'warn', ${3:-null}, 'crit', ${4:-null}))::text")
  case $o in *'"refused"'*) bad "the tier $2 ${3:-} ${4:-} on $1 was refused: $o" ;; esac; }
writecfg; "$BIN" migrate -config "$CFG" >/dev/null
# the page's own read (part c finding 9): a pgvigil serve of this repository on a free local port without a login
# (this proof's own process, stopped by the cleanup); page <src|rep> = the resource ids GET /api/cloud/replicas
# part=resources lists for that instance, sorted and joined by commas
PORTW=$((20000 + RANDOM % 20000)); while ss -ltnH "sport = :$PORTW" | grep -q .; do PORTW=$((20000 + RANDOM % 20000)); done
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/serve.yaml"
"$BIN" serve -config "$WORK/serve.yaml" -listen "127.0.0.1:$PORTW" -no-login > "$WORK/serve.out" 2>&1 & SRV_PID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORTW/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRV_PID" 2>/dev/null || die "pgvigil serve exited: $(cat "$WORK/serve.out")"
page() { curl -fs "http://127.0.0.1:$PORTW/api/cloud/replicas?instance=$(iid "$1")&part=resources" | python3 -c 'import json,sys; t=json.load(sys.stdin)["resources"]; i=t["columns"].index("resource_id"); print(",".join(sorted(r[i] for r in t["rows"])))'; }
WANT_PAGE=$(printf '%s\n' "$SRC_KEY" "$REP_KEY" | LC_ALL=C sort | paste -sd,)

echo "--- R-A the source alone"
run src
S=$(status src); R=$(q "SELECT role || '|' || cardinality(replica_ids) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = '$SRC_KEY'")
F=$(q "SELECT count(*) FROM pgvigil.cloud_replica_findings WHERE instance_id = $(iid src)")
echo "  cloud_replicas: $S; the source: $R; findings: $F"
[[ $S == ok* ]] && [ "$R" = "standalone|0" ] && [ "$F" = 0 ] && echo "R-A: OK" || bad "R-A: '$S' '$R' findings $F (want ok, standalone|0, 0)"

echo "--- R-B the replica made"
"$LAB" replica | sed 's/^/  lab: /' &
LP=$!
STOPPED_SEEN=
while kill -0 "$LP" 2>/dev/null; do run src; [ -n "$(finding src 'provider replica stopped' "$REP_KEY")" ] && STOPPED_SEEN=1; sleep 60; done
wait "$LP" || die "R-B: the replica was not made (the lab's output above)"
# shellcheck disable=SC1090
. "$STATE"
CR_REP_DSN=$(pgdsn "$REP_HOST"); writecfg
GOT_KEY=$(aws --profile "$PGVIGIL_LAB_AWS_PROFILE" --region "$PGVIGIL_LAB_AWS_REGION" rds describe-db-instances --db-instance-identifier "$REP_ID" \
  --query 'DBInstances[0].DBInstanceArn' --output text | tr '[:upper:]' '[:lower:]' || true)
[ "$GOT_KEY" = "$REP_KEY" ] || bad "R-B: the replica's DBInstanceArn '$GOT_KEY' is not the key built from the source's ('$REP_KEY')"
for i in $(seq 1 15); do
  run src; run rep
  T=$(q "SELECT string_agg(resource_id || ':' || role || ':' || coalesce(source_id, '') || ':' || array_to_string(replica_ids, ',') || ':' || repl_status, ' ' ORDER BY resource_id) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id IN ('$SRC_KEY', '$REP_KEY')")
  P=$(q "SELECT count(*) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_KEY' AND metric = 'replica_lag'")
  [ "$T" = "$SRC_KEY:source::$REP_KEY: $REP_KEY:replica:$SRC_KEY::replicating" ] && [ "$P" -gt 0 ] && break; sleep 60
done
AD=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = '$SRC_KEY' AND kind = 'added' AND subject = '$REP_KEY'")
NRES=$(q "SELECT count(*) FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id IN ('$SRC_KEY', '$REP_KEY')")
PAGES=$(q "SELECT count(*) FROM pgvigil.cloud_replica_readers WHERE instance_id IN ($(iid src), $(iid rep)) AND resource_id IN ('$SRC_KEY', '$REP_KEY')")
PG_SRC=$(page src || true); PG_REP=$(page rep || true)
echo "  the pages list: the source's '$PG_SRC', the replica's '$PG_REP' (want '$WANT_PAGE')"
echo "  after $i minute(s): $T; datapoints $P; 'added' $AD; rows $NRES; page rows $PAGES${STOPPED_SEEN:+; a 'stopped' finding while it was made}"
[ "$T" = "$SRC_KEY:source::$REP_KEY: $REP_KEY:replica:$SRC_KEY::replicating" ] && [ "$P" -gt 0 ] && [ "$AD" = 1 ] && [ "$NRES" = 2 ] && [ "$PAGES" = 4 ] && [ "$PG_SRC" = "$WANT_PAGE" ] && [ "$PG_REP" = "$WANT_PAGE" ] && [ -z "$STOPPED_SEEN" ] \
  && echo "R-B: OK" || bad "R-B: topology '$T', datapoints $P, added $AD, rows $NRES, page rows $PAGES, the pages '$PG_SRC' '$PG_REP', stopped while made '${STOPPED_SEEN:-no}'"

# hold <minutes>: replay held on the replica (a REPEATABLE READ snapshot that a VACUUM's cleanup on the source conflicts
# with; the lab's max_standby_streaming_delay -1 makes replay wait for it) and a write every 20 s on the source
hold() {
  src "CREATE TABLE IF NOT EXISTS public.pgvproof_cr_$SUF (id int PRIMARY KEY, v int); INSERT INTO public.pgvproof_cr_$SUF SELECT g, 0 FROM generate_series(1, 1000) g ON CONFLICT DO NOTHING" >/dev/null; MADE_T=1
  sleep 20
  PGPASSWORD="$ADMIN_PW" psql "host=$REP_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require" -XAtq \
    -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM public.pgvproof_cr_$SUF; SELECT pg_sleep($1 * 60); COMMIT" >/dev/null 2>&1 &
  HOLD_PID=$!
  sleep 10
  # two calls: VACUUM refuses a transaction block, and one -c string of two statements is one (review 055507 finding 2)
  src "DELETE FROM public.pgvproof_cr_$SUF WHERE id % 2 = 0" >/dev/null
  src "VACUUM public.pgvproof_cr_$SUF" >/dev/null
  ( while :; do src "INSERT INTO public.pgvproof_cr_$SUF VALUES ((random() * 1e9)::int, 1) ON CONFLICT DO NOTHING" >/dev/null 2>&1; sleep 20; done ) &
  WRITE_PID=$!
}
release() { stopbg; rep "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true; }

if want C; then
  echo "--- R-C replay held: the source's tier warn 1 / crit 2 minutes, the replica's warn 1"
  # the rule fires when every datapoint of the 10 minutes to the newest is over the tier: at the default 10 minutes a
  # hold would run past 21 minutes first (review 055507 finding 4), so one hold proves both severities at small tiers
  tier src set 1 2; tier rep set 1
  hold 30   # pg_sleep's ceiling: release ends the hold after the 16 reads, so replay is held through the last of them
  for i in $(seq 1 16); do sleep 60; run src; run rep; done
  K1=$(finding src 'provider replica lag' "$REP_KEY"); K2=$(finding rep 'provider replica lag' "$REP_KEY")
  L=$(q "SELECT round(max(value)) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_KEY' AND metric = 'replica_lag' AND snapshot_at > now() - interval '20 minutes'")
  release
  C1=x; C2=x
  for i in $(seq 1 10); do sleep 60; run src; run rep
    C1=$(finding src 'provider replica lag' "$REP_KEY"); C2=$(finding rep 'provider replica lag' "$REP_KEY"); [ -z "$C1$C2" ] && break; done
  tier src inherit; tier rep inherit
  echo "  held: the source's '$K1' (tier 1 / 2), the replica's '$K2' (tier 1) (lag up to $L s); released: '$C1' '$C2' after $i minute(s)"
  [ "$K1" = critical ] && [ "$K2" = warning ] && [ -z "$C1$C2" ] && echo "R-C: OK" \
    || bad "R-C: '$K1' '$K2' then '$C1' '$C2' (want critical on the source, warning on the replica, both cleared)"
fi

if want D; then
  echo "--- R-D 15 idle minutes"
  for i in $(seq 1 15); do sleep 60; run src; done
  IL=$(q "SELECT round(max(value)) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_KEY' AND metric = 'replica_lag' AND snapshot_at > now() - interval '15 minutes'")
  D=$(finding src 'provider replica lag' "$REP_KEY")
  echo "  the idle lag's maximum: ${IL:-none} s; the finding: '${D}'"
  [ -z "$D" ] && echo "R-D: OK" || bad "R-D: '$D' on an idle source at the defaults"
fi

if want E; then
  echo "--- R-E the replica rebooted"
  "$LAB" reboot | sed 's/^/  lab: /'
  # 20 reads 30 s apart (10 minutes), each printing the row the rule judges. RDS reports replication stopped for a few
  # minutes after a reboot: OLDRULE counts the NEW reads (a read time unlike the last loop's: a throttled read stores
  # nothing) of an available replica whose non-replicating status a read before stored (read time after its since) -
  # one = the old two-read rule would have fired, so the rule by time is exercised (review 112616 finding 3)
  SEEN=; MISS=; STOP=; AFTER=0; OLDRULE=0; AV_AT=; LAST=; PREV_AT=
  for i in $(seq 1 20); do
    sleep 30; run src
    ROW=$(q "SELECT status || '|' || repl_status || '|' || to_char(repl_since AT TIME ZONE 'UTC', 'HH24:MI:SS') || '|' || to_char(snapshot_at AT TIME ZONE 'UTC', 'HH24:MI:SS') FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = '$REP_KEY'")
    FS=$(finding src 'provider replica stopped' "$REP_KEY")
    echo "  read $i: status|replication|since|read at (UTC) = $ROW; 'provider replica stopped': '$FS'"
    IFS='|' read -r st rs since at <<<"$ROW"
    SEEN="$SEEN ${st:-none}"; LAST=$rs
    [ "$st" = available ] && [ -z "$AV_AT" ] && AV_AT=$(q "SELECT now()")
    if [ "$st" = available ] && [ -n "$rs" ] && [ "$rs" != replicating ] && [ "$at" != "$PREV_AT" ] && [ "$at" != "$since" ]; then OLDRULE=$((OLDRULE + 1)); fi
    PREV_AT=$at
    [ -n "$(finding src 'provider lag missing' "$REP_KEY")" ] && MISS=1
    [ -n "$FS" ] && STOP=1
  done
  # a replica_lag datapoint dated after the first read that saw 'available' (CloudWatch's delay: up to 6 more reads; part c finding 9)
  [ -n "$AV_AT" ] || AV_AT=$(q "SELECT now()")
  after() { q "SELECT count(*) FROM pgvigil.cloud_replica_sample WHERE provider = 'aws' AND resource_id = '$REP_KEY' AND metric = 'replica_lag' AND snapshot_at > '$AV_AT'::timestamptz"; }
  AFTER=$(after)
  for i in $(seq 1 6); do [ "$AFTER" -gt 0 ] && break; sleep 60; run src; AFTER=$(after)
    [ -n "$(finding src 'provider lag missing' "$REP_KEY")" ] && MISS=1; done
  echo "  RDS's own events of the replica, the last 30 minutes:"
  aws --profile "$PGVIGIL_LAB_AWS_PROFILE" --region "$PGVIGIL_LAB_AWS_REGION" rds describe-events --source-type db-instance --source-identifier "$REP_ID" \
    --duration 30 --query 'Events[].[Date,Message]' --output text 2>&1 | sed 's/^/    /' || true
  echo "  statuses read:$SEEN; new reads of an available replica's standing non-replicating status (the old rule fired on one): $OLDRULE; the last read's: '$LAST'; replica_lag datapoints after 'available': $AFTER${MISS:+; 'lag missing' fired}${STOP:+; 'stopped' fired}"
  if [[ $SEEN == *available ]] && [ "$LAST" = replicating ] && [ "$AFTER" -gt 0 ] && [ -z "$MISS$STOP" ]; then
    echo "R-E: OK"
    [ "$OLDRULE" -ge 1 ] || NOTPROVEN+=("R-E's rule by time: no read met RDS's stop after the reboot standing from an earlier read (the old two-read rule's case) - the store tests (TestCloudReplicasOnAStore, TestCloudReplicaFindingsFoldB) stand for it")
  else
    bad "R-E: statuses '$SEEN', the last replication status '$LAST', datapoints after available $AFTER, lag missing '${MISS:-no}', stopped '${STOP:-no}'"
  fi
fi

if want H; then
  echo "--- R-H the documented policy verbatim"
  if [ -n "${PGVIGIL_PROOF_DOC_PROFILE:-}" ]; then
    run doc; S=$(status doc); NT=$(q "SELECT coalesce(door_error, '') || '|' || door_fails FROM pgvigil.cloud_replica_reads WHERE instance_id = $(iid doc)")
    echo "  run: $S; read: '$NT'"
    [[ $S == ok* ]] && [ "$NT" = "|0" ] && echo "R-H: OK" || bad "R-H: '$S' '$NT' (want ok and no refused call)"
  else
    NOTPROVEN+=("R-H: no PGVIGIL_PROOF_DOC_PROFILE on this machine (an identity holding only the documented policy)")
  fi
fi

if want F; then
  echo "--- R-F promote"
  "$LAB" promote | sed 's/^/  lab: /'
  for i in $(seq 1 10); do run src; run rep; [ "$(q "SELECT role FROM pgvigil.cloud_replicas WHERE provider = 'aws' AND resource_id = '$REP_KEY'")" = standalone ] && break; sleep 60; done
  PR=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = '$REP_KEY' AND kind = 'promoted'")
  RM=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'aws' AND resource_id = '$SRC_KEY' AND kind = 'removed' AND subject = '$REP_KEY'")
  F1=$(finding rep 'replica promoted or detached' "$REP_KEY"); F2=$(finding src 'replica promoted or detached' "$REP_KEY")
  echo "  promoted $PR, removed $RM; findings: the replica's '$F1', the source's '$F2'"
  [ "$PR" = 1 ] && [ "$RM" = 1 ] && [ "$F1" = warning ] && [ "$F2" = warning ] && echo "R-F: OK" || bad "R-F: promoted $PR, removed $RM, '$F1', '$F2' (want 1, 1, warning, warning)"
fi

if want G; then
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
fi
NOTPROVEN+=("P3 (the provider's failover event): an RDS Multi-AZ DB instance is billed and not approved; the Go cases and the store row prove the hand-off")

echo "--- C-A..C-F (Cloud SQL)"
NOTPROVEN+=("C-A..C-F: run by scripts/proof-cloud-replicas-gcp.sh on lab CP (scripts/lab/gcp-cloudsql-pg-replica.sh; an approved lab), not here")

echo
for n in "${NOTPROVEN[@]}"; do echo "NOT PROVEN: $n"; done
if [ ${#FAILS[@]} -gt 0 ]; then echo "cloud replicas: ${#FAILS[@]} FAIL"; for f in "${FAILS[@]}"; do echo "  $f"; done; exit 1; fi
[ "$ROWS" = "C D E H F G" ] && echo "cloud replicas: every R row OK" || echo "cloud replicas: the rows run (A B $ROWS) OK"
