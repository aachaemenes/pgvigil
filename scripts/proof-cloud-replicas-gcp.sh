#!/usr/bin/env bash
# Proof of task 390b on real Cloud SQL replicas (part C of the provider replica proof; part R, Amazon RDS, is
# scripts/proof-cloud-replicas.sh): the provider replica read (cloud_replicas: Cloud SQL Admin instances.get and Cloud
# Monitoring's replica_lag / replica_byte_lag) as pgvigil reads, stores, judges and shows it, each fault made, its
# finding read, cleared and the clear read. Drives lab CP (scripts/lab/gcp-cloudsql-pg-replica.sh: up, allow and
# logins done before; replica, repl-off, repl-on and promote here). Allen's word for CP: his Q37, YES (2026-11-15 04:43).
#
# Runs on the machine that holds the gcloud sign-in AND Application Default Credentials (the collector's gcp: door reads
# with them: `gcloud auth application-default login`, Allen's own step): no credential or token goes to a cloud box (the
# lab rule of 2026-11-14). Needs psql, jq, python3, gcloud, PGVIGIL_BIN (a built pgvigil) or a go toolchain, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the repository is made there)
#   PGVIGIL_LAB_GCP_PROJECT, PGVIGIL_LAB_PROOF   as the lab script (its state file .lab/gcp-cloudsql-pg-replica.env)
# Every run makes its own repository database and drops it (0151 is edited in place before the tag: a store that once
# applied 390a's 0151 would skip 390b's Part P, so no run reuses one).
#
# Expected (written before the first run):
#  C-A the primary alone: cloud_replicas ok; one cloud_replicas row, 'standalone', no replica, no finding.
#  C-B the replica made (masterInstanceName / replicaNames: the first live read of them; it takes the primary's
#      authorized networks at its create, so both are reached from here): while it is made, no 'provider replica
#      stopped'; within 15 minutes of it being RUNNABLE: the primary 'source' with replica_ids = [the replica], the
#      replica 'replica' with source_id = the primary and replication status Running, at least one replica_lag
#      datapoint (the replica's cloudsql_database) - replica_byte_lag datapoints printed (the primary's replay_location
#      series: whether Google gives them is printed, not graded); the primary's 'added' event; both instances' pages
#      list both resources.
#  C-C replay held by a long REPEATABLE READ on the replica (the lab's max_standby_streaming_delay -1) with an INSTANCE
#      tier of warn 1 minute on both instances, 16 minutes of reads: 'provider replica lag' warning on both (the rule
#      fires when every datapoint of the 10 minutes to the newest is over the tier: at the default 10 minutes a hold
#      would run past 21 minutes before that, review 055507 finding 4, so the default's number is not held here);
#      released: cleared on both within 10 minutes, the replica's row read after the release and Running; the tiers
#      taken back (inherit).
#  C-D 15 idle minutes (the design's fold 6; 15, not 45, for the lab's length): the idle lag's maximum PRINTED (whether
#      replica_lag grows on an idle primary); no lag finding at the defaults.
#  C-E the replica's replication disabled (`gcloud sql instances patch <replica> --no-enable-database-replication`;
#      Google's manage-replicas page: it restarts the replica): after the FIRST read that stores a status other than
#      Running, no finding yet (the store's two-read rule: repl_since is that read's time); 'provider replica stopped'
#      critical by a later read within 15 minutes; enabled again: cleared within 15 minutes, the replica's row read
#      after it and Running. A status Google does not report while replication is off = a FAIL with what was read.
#  C-F promote-replica: the replica 'standalone' with a 'promoted' event, the primary's 'removed' event, the 'replica
#      promoted or detached' finding (warning) on both instances.
# A refused lab call in C-E or C-F is a FAIL row and the run goes on; a stop anywhere leaves both instances billed
# until `scripts/lab/gcp-cloudsql-pg-replica.sh down` (the cleanup says so). A run is not resumable: a second attempt
# is down, then up, allow, logins and the proof again (the proof makes the replica).
# Length (review 055507 finding 5; an ESTIMATE): up, allow and logins about 10-15 minutes before the proof; the proof
# about 75-145 minutes (C-B's create 10-20 and up to 15 more; C-C 17-19 and up to 10; C-D 16; C-E two restarts and up
# to 30; C-F up to 15); down about 5-10 - the primary stands about 1.6-2.7 h, the replica about 1.3-2.2 h, about USD
# 0.15-0.40 at about USD 0.07 an hour each plus the disks: longer than the 'about 1 h' of Allen's Q37, under the
# USD 5 stop.
set -Eeuo pipefail
# the line only at the top level: inside $(...) errexit is off and the run goes on, so a line there would be false
# (review 055507 finding 10)
trap 'erc=$?; [ "$BASH_SUBSHELL" -eq 0 ] && echo "STOPPED: line $LINENO: $BASH_COMMAND (exit $erc)" >&2' ERR
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
: "${PGVIGIL_LAB_GCP_PROJECT:?the project id}" "${PGVIGIL_LAB_PROOF:?the label value of the lab}"
LAB=scripts/lab/gcp-cloudsql-pg-replica.sh
STATE=${PGVIGIL_LAB_DIR:-.lab}/gcp-cloudsql-pg-replica.env
for t in psql jq python3 gcloud; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
[ -r "$STATE" ] || { echo "FAIL: no lab state file $STATE (gcp-cloudsql-pg-replica.sh up, allow, logins)" >&2; exit 1; }
gcloud auth application-default print-access-token >/dev/null 2>&1 || { echo "FAIL: no Application Default Credentials on this machine (gcloud auth application-default login: Allen's step)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
: "${PRI_INSTANCE:?} ${REP_INSTANCE:?} ${PRI_IP:?} ${ADMIN_USER:?} ${ADMIN_PW:?} ${MON_USER:?} ${MON_PW:?}"
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_crgproof_$SUF; N=proof-crg-$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
MADE_DB=; MADE_T=; HOLD_PID=; WRITE_PID=; LP=
FAILS=(); NOTPROVEN=()
SRC_ID=$(tr '[:upper:]' '[:lower:]' <<<"$PGVIGIL_LAB_GCP_PROJECT:$PRI_INSTANCE"); REP_ID=$(tr '[:upper:]' '[:lower:]' <<<"$PGVIGIL_LAB_GCP_PROJECT:$REP_INSTANCE")
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
src() { PGPASSWORD="$ADMIN_PW" psql "host=$PRI_IP port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
rep() { PGPASSWORD="$ADMIN_PW" psql "host=$REP_IP port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
stopbg() { for p in $HOLD_PID $WRITE_PID; do kill "$p" 2>/dev/null || true; done; HOLD_PID=; WRITE_PID=; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  stopbg
  if [ -n "$MADE_T" ]; then src "DROP TABLE IF EXISTS public.pgvproof_crg_$SUF" >/dev/null 2>&1 || echo "CLEANUP: public.pgvproof_crg_$SUF not dropped (down removes the instance)" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  # a background job ignores Ctrl-C here: the lab's replica step may still wait on Google's create (finding 10)
  if [ -n "$LP" ] && kill -0 "$LP" 2>/dev/null; then echo "CLEANUP: the lab's replica step (pid $LP) still waits on Google's create: let it end, then $LAB down" >&2; fi
  [ ! -r "$STATE" ] || echo "the lab is still up (both instances billed until down): $LAB down" >&2
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
export CR_SRC_DSN; CR_SRC_DSN=$(pgdsn "$PRI_IP")
export CR_REP_DSN=
writecfg() {   # the primary, and the replica once it is up; each with its gcp: block (the door), credentials by ADC
  { echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
    for x in "src|CR_SRC_DSN|$PRI_INSTANCE" ${REP_IP:+"rep|CR_REP_DSN|$REP_INSTANCE"}; do
      IFS='|' read -r k v inst <<<"$x"
      printf '  - name: %s-%s\n    dsn: env:%s\n    platform: cloudsql\n    gcp:\n      project: %s\n      instance: %s\n' "$N" "$k" "$v" "$PGVIGIL_LAB_GCP_PROJECT" "$inst"
    done; } > "$CFG"; }
run() { "$BIN" collect -config "$CFG" -once cloud_replicas -instance "$N-$1" > "$WORK/cr.$1.out" 2>&1 || true; }
status() { q "SELECT d.status || '|' || coalesce(d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$N-$1' AND d.collection = 'cloud_replicas'"; }
iid() { q "SELECT instance_id FROM pgvigil.instances WHERE name = '$N-$1'"; }
finding() { q "SELECT coalesce(max(f.severity), '') FROM pgvigil.cloud_replica_findings f WHERE f.instance_id = $(iid "$1") AND f.check_name = '$2' AND f.object = '$3'"; }
# tier <src|rep> <set|inherit> [warn [crit]]: an instance-level provider_replica_lag tier; a refusal is a FAIL row
tier() { local o; o=$(q "SELECT pgvigil.import_pg_threshold(now(), jsonb_build_object('op', '$2', 'ui_user', 'proof', 'key', 'provider_replica_lag', 'level', 'instance', 'instance_id', $(iid "$1"), 'warn', ${3:-null}, 'crit', ${4:-null}))::text")
  case $o in *'"refused"'*) bad "the tier $2 ${3:-} ${4:-} on $1 was refused: $o" ;; esac; }
rstat() { q "SELECT repl_status FROM pgvigil.cloud_replicas WHERE provider = 'gcp' AND resource_id = '$REP_ID'"; }
# fresh <time>: the replica's row as 'status|read after <time>' (a clear counts only on a read after the change, finding 7)
fresh() { q "SELECT repl_status || '|' || (snapshot_at > '$1'::timestamptz) FROM pgvigil.cloud_replicas WHERE provider = 'gcp' AND resource_id = '$REP_ID'"; }
REP_IP=; writecfg; "$BIN" migrate -config "$CFG" >/dev/null

echo "--- C-A the primary alone"
run src
S=$(status src); R=$(q "SELECT role || '|' || cardinality(replica_ids) FROM pgvigil.cloud_replicas WHERE provider = 'gcp' AND resource_id = '$SRC_ID'")
F=$(q "SELECT count(*) FROM pgvigil.cloud_replica_findings WHERE instance_id = $(iid src)")
echo "  cloud_replicas: $S; the primary: $R; findings: $F"
[[ $S == ok* ]] && [ "$R" = "standalone|0" ] && [ "$F" = 0 ] && echo "C-A: OK" || bad "C-A: '$S' '$R' findings $F (want ok, standalone|0, 0)"

echo "--- C-B the replica made"
"$LAB" replica | sed 's/^/  lab: /' &
LP=$!
STOPPED_SEEN=
while kill -0 "$LP" 2>/dev/null; do run src; [ -n "$(finding src 'provider replica stopped' "$REP_ID")" ] && STOPPED_SEEN=1; sleep 60; done
wait "$LP" || die "C-B: the replica was not made (the lab's output above)"
# shellcheck disable=SC1090
. "$STATE"
CR_REP_DSN=$(pgdsn "$REP_IP"); writecfg
for i in $(seq 1 15); do
  run src; run rep
  T=$(q "SELECT string_agg(resource_id || ':' || role || ':' || coalesce(source_id, '') || ':' || array_to_string(replica_ids, ','), ' ' ORDER BY resource_id) FROM pgvigil.cloud_replicas WHERE provider = 'gcp' AND resource_id IN ('$SRC_ID', '$REP_ID')")
  RS=$(q "SELECT repl_status FROM pgvigil.cloud_replicas WHERE provider = 'gcp' AND resource_id = '$REP_ID'")
  P=$(q "SELECT count(*) FROM pgvigil.cloud_replica_sample WHERE provider = 'gcp' AND resource_id = '$REP_ID' AND metric = 'replica_lag'")
  [ "$T" = "$SRC_ID:source::$REP_ID $REP_ID:replica:$SRC_ID:" ] && [ "$RS" = Running ] && [ "$P" -gt 0 ] && break; sleep 60
done
BL=$(q "SELECT count(*) FROM pgvigil.cloud_replica_sample WHERE provider = 'gcp' AND resource_id = '$REP_ID' AND metric = 'replica_byte_lag'")
AD=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'gcp' AND resource_id = '$SRC_ID' AND kind = 'added' AND subject = '$REP_ID'")
PAGES=$(q "SELECT count(*) FROM pgvigil.cloud_replica_readers WHERE instance_id IN ($(iid src), $(iid rep)) AND resource_id IN ('$SRC_ID', '$REP_ID')")
echo "  after $i minute(s): $T; replication '$RS'; lag datapoints $P; byte-lag datapoints $BL (printed); 'added' $AD; page rows $PAGES${STOPPED_SEEN:+; a 'stopped' finding while it was made}"
[ "$T" = "$SRC_ID:source::$REP_ID $REP_ID:replica:$SRC_ID:" ] && [ "$RS" = Running ] && [ "$P" -gt 0 ] && [ "$AD" = 1 ] && [ "$PAGES" = 4 ] && [ -z "$STOPPED_SEEN" ] \
  && echo "C-B: OK" || bad "C-B: topology '$T', replication '$RS', datapoints $P, added $AD, page rows $PAGES, stopped while made '${STOPPED_SEEN:-no}'"

hold() {
  src "CREATE TABLE IF NOT EXISTS public.pgvproof_crg_$SUF (id int PRIMARY KEY, v int); INSERT INTO public.pgvproof_crg_$SUF SELECT g, 0 FROM generate_series(1, 1000) g ON CONFLICT DO NOTHING" >/dev/null; MADE_T=1
  sleep 20
  PGPASSWORD="$ADMIN_PW" psql "host=$REP_IP port=5432 user=$ADMIN_USER dbname=postgres sslmode=require" -XAtq \
    -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT count(*) FROM public.pgvproof_crg_$SUF; SELECT pg_sleep($1 * 60); COMMIT" >/dev/null 2>&1 &
  HOLD_PID=$!
  sleep 10
  # two calls: VACUUM refuses a transaction block, and one -c string of two statements is one (review 055507 finding 2)
  src "DELETE FROM public.pgvproof_crg_$SUF WHERE id % 2 = 0" >/dev/null
  src "VACUUM public.pgvproof_crg_$SUF" >/dev/null
  ( while :; do src "INSERT INTO public.pgvproof_crg_$SUF VALUES ((random() * 1e9)::int, 1) ON CONFLICT DO NOTHING" >/dev/null 2>&1; sleep 20; done ) &
  WRITE_PID=$!
}
release() { stopbg; rep "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true; }

echo "--- C-C replay held, an instance tier of warn 1 minute on both instances"
tier src set 1; tier rep set 1
hold 30   # pg_sleep's ceiling: release ends the hold after the 16 reads, so replay is held through the last of them
for i in $(seq 1 16); do sleep 60; run src; run rep; done
W1=$(finding src 'provider replica lag' "$REP_ID"); W2=$(finding rep 'provider replica lag' "$REP_ID")
L=$(q "SELECT round(max(value)) FROM pgvigil.cloud_replica_sample WHERE provider = 'gcp' AND resource_id = '$REP_ID' AND metric = 'replica_lag' AND snapshot_at > now() - interval '20 minutes'")
release; RA=$(q "SELECT now()")
C1=x; C2=x; FR=
for i in $(seq 1 10); do sleep 60; run src; run rep
  C1=$(finding src 'provider replica lag' "$REP_ID"); C2=$(finding rep 'provider replica lag' "$REP_ID"); FR=$(fresh "$RA")
  [ -z "$C1$C2" ] && [ "$FR" = "Running|true" ] && break; done
tier src inherit; tier rep inherit
echo "  held at warn 1 minute: the primary's '$W1', the replica's '$W2' (lag up to $L s); released: '$C1' '$C2' after $i minute(s), the replica's row '$FR'"
[ "$W1" = warning ] && [ "$W2" = warning ] && [ -z "$C1$C2" ] && [ "$FR" = "Running|true" ] && echo "C-C: OK" \
  || bad "C-C: '$W1' '$W2' then '$C1' '$C2' ('$FR') (want warning, warning, both cleared, Running|true)"

echo "--- C-D 15 idle minutes"
for i in $(seq 1 15); do sleep 60; run src; done
IL=$(q "SELECT round(max(value)) FROM pgvigil.cloud_replica_sample WHERE provider = 'gcp' AND resource_id = '$REP_ID' AND metric = 'replica_lag' AND snapshot_at > now() - interval '15 minutes'")
D=$(finding src 'provider replica lag' "$REP_ID")
echo "  the idle lag's maximum over 15 minutes: ${IL:-none} s (printed: fold 6); the finding: '${D}'"
[ -z "$D" ] && echo "C-D: OK" || bad "C-D: '$D' on an idle primary at the defaults"

echo "--- C-E replication disabled, then enabled"
ST=; SEEN=; ONE=; FIRST=; OFF=1
"$LAB" repl-off | sed 's/^/  lab: /' || { OFF=; bad "C-E: repl-off refused (the lab's output above): its waits skipped"; }
# offread <src|rep>: one read, the status it stored; the finding read right after the FIRST read that stored a status
# other than Running (the two-read rule: none yet), finding 7
offread() { local s; run "$1"; s=$(rstat); SEEN="$SEEN $1:${s:-blank}"
  if [ -z "$FIRST" ] && [ -n "$s" ] && [ "$s" != Running ]; then FIRST=$s; ONE=$(finding src 'provider replica stopped' "$REP_ID"); fi; }
if [ -n "$OFF" ]; then
  for i in $(seq 1 15); do sleep 60; offread src; offread rep
    ST=$(finding src 'provider replica stopped' "$REP_ID"); [ "$ST" = critical ] && break; done
fi
"$LAB" repl-on | sed 's/^/  lab: /' || bad "C-E: repl-on refused (the lab's output above)"
OA=$(q "SELECT now()"); CL=x; FR=
for i in $(seq 1 15); do sleep 60; run src; run rep
  CL=$(finding src 'provider replica stopped' "$REP_ID"); FR=$(fresh "$OA"); [ -z "$CL" ] && [ "$FR" = "Running|true" ] && break; done
echo "  statuses stored while off (reader:status):$SEEN; right after the first read that stored '${FIRST:-none}': '$ONE'; then 'stopped': '$ST'; after enabling: '$CL', the replica's row '$FR'"
[ -n "$OFF" ] && [ -n "$FIRST" ] && [ -z "$ONE" ] && [ "$ST" = critical ] && [ -z "$CL" ] && [ "$FR" = "Running|true" ] && echo "C-E: OK" \
  || bad "C-E: off '${OFF:-refused}', the first status '${FIRST:-none}' then '$ONE', stopped '$ST', after enabling '$CL' ('$FR') (want a status, '', critical, '', Running|true)"

echo "--- C-F promote"
PROM=1
"$LAB" promote | sed 's/^/  lab: /' || { PROM=; bad "C-F: promote refused (the lab's output above): its waits skipped"; }
if [ -n "$PROM" ]; then
  for i in $(seq 1 10); do run src; run rep; [ "$(q "SELECT role FROM pgvigil.cloud_replicas WHERE provider = 'gcp' AND resource_id = '$REP_ID'")" = standalone ] && break; sleep 60; done
fi
PR=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'gcp' AND resource_id = '$REP_ID' AND kind = 'promoted'")
RM=$(q "SELECT count(*) FROM pgvigil.cloud_replica_events WHERE provider = 'gcp' AND resource_id = '$SRC_ID' AND kind = 'removed' AND subject = '$REP_ID'")
F1=$(finding rep 'replica promoted or detached' "$REP_ID"); F2=$(finding src 'replica promoted or detached' "$REP_ID")
echo "  promoted $PR, removed $RM; findings: the replica's '$F1', the primary's '$F2'"
[ "$PR" = 1 ] && [ "$RM" = 1 ] && [ "$F1" = warning ] && [ "$F2" = warning ] && echo "C-F: OK" || bad "C-F: promoted $PR, removed $RM, '$F1', '$F2' (want 1, 1, warning, warning)"

echo
for n in "${NOTPROVEN[@]}"; do echo "NOT PROVEN: $n"; done
if [ ${#FAILS[@]} -gt 0 ]; then echo "cloud replicas (Cloud SQL): ${#FAILS[@]} FAIL"; for f in "${FAILS[@]}"; do echo "  $f"; done; exit 1; fi
echo "cloud replicas (Cloud SQL): every C row OK"
