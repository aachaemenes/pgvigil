#!/usr/bin/env bash
# Lab CP (task 390b): a Google Cloud SQL for PostgreSQL primary and one read replica for the provider replica proof
# scripts/proof-cloud-replicas.sh (its C rows), made and removed from the machine that holds the gcloud sign-in.
#
#   scripts/lab/gcp-cloudsql-pg-replica.sh up            enable the Cloud SQL Admin API if off, make the primary and the state file
#   scripts/lab/gcp-cloudsql-pg-replica.sh replica       the primary's read replica (the standby flags below; the primary's authorized networks)
#   scripts/lab/gcp-cloudsql-pg-replica.sh allow <ip>    both instances' authorized networks admit this address only
#   scripts/lab/gcp-cloudsql-pg-replica.sh logins        (where 5432 reaches) the collector's login on the primary (pg_monitor; the API's cloudsqlsuperuser revoked)
#   scripts/lab/gcp-cloudsql-pg-replica.sh repl-off      the replica's replication disabled (C-E; Google's manage-replicas page: it restarts the replica)
#   scripts/lab/gcp-cloudsql-pg-replica.sh repl-on       the replica's replication enabled again
#   scripts/lab/gcp-cloudsql-pg-replica.sh promote       promote the replica to a standalone instance (C-F)
#   scripts/lab/gcp-cloudsql-pg-replica.sh status        what this lab holds now, read from Google
#   scripts/lab/gcp-cloudsql-pg-replica.sh down          delete both instances, read the instances and backups back, disable the API if up enabled it
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF        the proof's label value: both instances carry pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_GCP_PROJECT  the project id (required)
#   PGVIGIL_LAB_GCP_REGION   the region (required for up)
#   PGVIGIL_LAB_DIR          the state folder, default .lab (up writes a .gitignore of '*' into it)
#   GCLOUD                   the gcloud CLI, default gcloud on the PATH
#
# What it makes, each labelled pgvigil-proof=<value>: the primary - PostgreSQL 16, db-custom-1-3840 (1 vCPU / 3.75 GB),
# Enterprise edition, zonal, 10 GB SSD without auto-resize, automated backups and point-in-time recovery off (Google's
# create-replica page: 'Cloud SQL creates a backup, if needed, and creates the replica'), deletion protection off,
# public IPv4 with NO authorized network until 'allow'; the replica - the same region, version, tier and edition
# (Enterprise: a PostgreSQL 16 replica defaults to Enterprise Plus), the primary's authorized networks as they stand at
# its create (each instance has its own; read back), the flags max_standby_streaming_delay = -1 and hot_standby_feedback =
# off (the design's fold 10: a long read on the replica holds replay for as long as it runs, so the proof's lag fault is
# deterministic). About USD 0.07 an hour each (Google's price for 1 vCPU / 3.75 GB) plus the disks; with the proof the
# lab stands about 1.6-2.7 h (the proof's Length line: about USD 0.15-0.40, an estimate); the lab rules: one lab at a time, every resource named to the harness before it is
# made, down the same day and read back, stop and ask over USD 5.
# The postgres user's and the collector's passwords are made here from /dev/urandom, written only to the mode-600 state
# file <dir>/gcp-cloudsql-pg-replica.env, handed to Google in a mode-600 request body (the access token in a mode-600
# header file), each removed right after the call, and to psql in PGPASSWORD: never on a command line, in the output
# or a log.
# down deletes the replica, then the primary (a promoted replica is a standalone instance: deleted the same), reads
# the project's instances back by name and by the label and the project's backups back by the two names (a retained
# backup is billed), and removes the state file only when none is left; the API is disabled again only if up was the
# one that enabled it.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/gcp-cloudsql-pg-replica.env
GCLOUD=${GCLOUD:-gcloud}
API=sqladmin.googleapis.com
TIER=db-custom-1-3840
VERSION=POSTGRES_16
CMD=${1:-}
fail() { echo "FAIL: $*" >&2; exit 1; }
need() {
  : "${PGVIGIL_LAB_PROOF:?the label value (pgvigil-proof=<value>)}" "${PGVIGIL_LAB_GCP_PROJECT:?the project id}"
  [[ $PGVIGIL_LAB_PROOF =~ ^[a-z0-9-]{1,40}$ ]] || fail "PGVIGIL_LAB_PROOF is lower-case letters, digits and dashes (a Google label value)"
  command -v "$GCLOUD" >/dev/null || fail "gcloud ($GCLOUD) is not on this machine"
  command -v curl >/dev/null && command -v jq >/dev/null || fail "curl and jq are needed"
}
g() { "$GCLOUD" "$@" --project "$PGVIGIL_LAB_GCP_PROJECT" --quiet; }
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
load() { [ -r "$STATE" ] || fail "no state file $STATE (run up first)"; # shellcheck disable=SC1090
  . "$STATE"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git check-ignore -q "$STATE" || fail "$STATE is not git-ignored (it holds a password)"; fi
  [ "$PGVIGIL_LAB_GCP_PROJECT" = "${LAB_PROJECT:-}" ] || fail "the state file was made in project '${LAB_PROJECT:-}', not '$PGVIGIL_LAB_GCP_PROJECT'"
  [ "$PGVIGIL_LAB_PROOF" = "${LAB_PROOF:-}" ] || fail "the state file was made with label '${LAB_PROOF:-}', not '$PGVIGIL_LAB_PROOF'"; }
ip_ok() { local oct='(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
  [[ $1 =~ ^$oct\.$oct\.$oct\.$oct$ ]] && [ "$1" != 0.0.0.0 ]; }
# api: one Cloud SQL Admin REST call with the token in a mode-600 header file and the body (if any) in a mode-600 file
api() { local method=$1 path=$2 body=${3:-} hdr out
  hdr=$(umask 077; mktemp "$DIR/gcp-h.XXXXXX"); out=$(umask 077; mktemp "$DIR/gcp-o.XXXXXX")
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$("$GCLOUD" auth print-access-token --quiet)" > "$hdr"
  local code
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" -H @"$hdr" ${body:+--data-binary @"$body"} "https://sqladmin.googleapis.com/v1/projects/$PGVIGIL_LAB_GCP_PROJECT/$path") || { rm -f "$hdr" "$out"; fail "the call $method $path did not complete"; }
  rm -f "$hdr"
  if [ "${code:0:1}" != 2 ]; then jq -r '.error.message // .' "$out" >&2 || true; rm -f "$out"; fail "$method $path answered $code"; fi
  cat "$out"; rm -f "$out"; }
wait_op() { local op=$1 st
  for _ in $(seq 1 120); do
    st=$(api GET "operations/$op" | jq -r '.status + " " + ((.error.errors // []) | map(.message) | join("; "))')
    case $st in "DONE ") return 0 ;; DONE*) fail "operation $op: ${st#DONE }" ;; esac
    sleep 10
  done
  fail "operation $op is not done after 20 min"; }
body() { BODY=$(umask 077; mktemp "$DIR/gcp-b.XXXXXX"); trap 'rm -f "$BODY"' EXIT; }
ipof() { g sql instances describe "$1" --format='value(ipAddresses[0].ipAddress)'; }
# absent <instance>: 0 when Google answers not found, 1 when it exists; any other failed read stops here
absent() { local d
  if d=$(g sql instances describe "$1" --format='value(name)' 2>&1); then return 1; fi
  grep -qiE 'HTTPError 404|does not exist|not found' <<<"$d" && return 0
  fail "the instance $1 was not read ($d): nothing changed, the state file $STATE stays"; }

case $CMD in
up)
  need; : "${PGVIGIL_LAB_GCP_REGION:?the region}"
  [ ! -e "$STATE" ] || fail "$STATE exists: this lab is up (status) or was not taken down (down)"
  mkdir -p "$DIR"; chmod 700 "$DIR"; printf '*\n' > "$DIR/.gitignore"
  ENABLED_HERE=0
  # a failed listing is never read as 'off': up would record an API it did not enable, and down would turn it off
  ON=$(g services list --enabled --filter="config.name:$API" --format='value(config.name)') || fail "the project's enabled services were not read (gcloud above): nothing made"
  if [ -z "$ON" ]; then
    g services enable "$API"; ENABLED_HERE=1
    echo "made: the project's $API enabled (undo: down disables it)"
  fi
  SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ( umask 077; cat > "$STATE" <<EOF
LAB_PROJECT=$PGVIGIL_LAB_GCP_PROJECT
LAB_PROOF=$PGVIGIL_LAB_PROOF
LAB_REGION=$PGVIGIL_LAB_GCP_REGION
API_ENABLED_HERE=$ENABLED_HERE
PRI_INSTANCE=pgv-cr-$SUF
REP_INSTANCE=pgv-cr-$SUF-r1
ADMIN_USER=postgres
ADMIN_PW=$(pw)
MON_USER=pgv_monitor
MON_PW=$(pw)
EOF
  )
  load; body
  # the password reaches jq through its environment, never its command line (ps shows argv)
  ADMIN_PW="$ADMIN_PW" jq -n --arg n "$PRI_INSTANCE" --arg r "$LAB_REGION" --arg v "$VERSION" --arg t "$TIER" --arg l "$PGVIGIL_LAB_PROOF" '{
    name: $n, region: $r, databaseVersion: $v, rootPassword: env.ADMIN_PW,
    settings: {tier: $t, edition: "ENTERPRISE", availabilityType: "ZONAL", dataDiskType: "PD_SSD",
               dataDiskSizeGb: "10", storageAutoResize: false, deletionProtectionEnabled: false,
               backupConfiguration: {enabled: false, pointInTimeRecoveryEnabled: false},
               ipConfiguration: {ipv4Enabled: true, authorizedNetworks: []},
               userLabels: {"pgvigil-proof": $l}}}' > "$BODY"
  OP=$(api POST instances "$BODY" | jq -r .name); rm -f "$BODY"
  [ -n "$OP" ] && [ "$OP" != null ] || fail "the create returned no operation (down removes what was made)"
  echo "accepted: instance $PRI_INSTANCE ($LAB_REGION, $VERSION, $TIER), operation $OP - waiting (Google: several minutes)"
  wait_op "$OP"
  PRI_IP=$(ipof "$PRI_INSTANCE"); [ -n "$PRI_IP" ] || fail "the primary's address was not read back"
  ( umask 077; printf 'PRI_IP=%s\n' "$PRI_IP" >> "$STATE" )
  echo "made: Cloud SQL instance $PRI_INSTANCE in $LAB_REGION at $PRI_IP, label pgvigil-proof=$PGVIGIL_LAB_PROOF, no authorized network (undo: down)"
  ;;
replica)
  need; load; body
  absent "$REP_INSTANCE" || fail "the replica $REP_INSTANCE exists already"
  # each Cloud SQL instance has its own authorized networks (RDS's two share one security group): the replica takes
  # the primary's as they stand (allow ran before), read back after the create (review 055507 finding 1)
  NETS=$(api GET "instances/$PRI_INSTANCE" | jq -c '.settings.ipConfiguration.authorizedNetworks // []')
  WANT=$(jq -r 'map(.value) | join(";")' <<<"$NETS")
  # edition ENTERPRISE as the primary's: a PostgreSQL 16 replica defaults to Enterprise Plus, which refuses the
  # db-custom tier (Google's create-replica page; finding 3)
  jq -n --arg n "$REP_INSTANCE" --arg m "$PRI_INSTANCE" --arg r "$LAB_REGION" --arg v "$VERSION" --arg t "$TIER" --arg l "$PGVIGIL_LAB_PROOF" --argjson nets "$NETS" '{
    name: $n, masterInstanceName: $m, region: $r, databaseVersion: $v,
    settings: {tier: $t, edition: "ENTERPRISE", availabilityType: "ZONAL", deletionProtectionEnabled: false,
               databaseFlags: [{name: "max_standby_streaming_delay", value: "-1"}, {name: "hot_standby_feedback", value: "off"}],
               ipConfiguration: {ipv4Enabled: true, authorizedNetworks: $nets},
               userLabels: {"pgvigil-proof": $l}}}' > "$BODY"
  OP=$(api POST instances "$BODY" | jq -r .name); rm -f "$BODY"
  [ -n "$OP" ] && [ "$OP" != null ] || fail "the replica's create returned no operation (down removes what was made)"
  echo "accepted: read replica $REP_INSTANCE of $PRI_INSTANCE, operation $OP - waiting"
  wait_op "$OP"
  REP_IP=$(ipof "$REP_INSTANCE"); [ -n "$REP_IP" ] || fail "the replica's address was not read back"
  # the address is recorded before any further read (finding 10): a failed read below leaves a replica repl-off,
  # promote and allow can still name
  ( umask 077; printf 'REP_IP=%s\n' "$REP_IP" >> "$STATE" )
  F=$(g sql instances describe "$REP_INSTANCE" --format='value(settings.databaseFlags[].name,settings.databaseFlags[].value)')
  GOT=$(g sql instances describe "$REP_INSTANCE" --format='value(settings.ipConfiguration.authorizedNetworks[].value)')
  [ "$GOT" = "$WANT" ] || fail "the replica's authorized networks read '$GOT', not the primary's '$WANT': run allow <ip> again (it patches both) or down"
  echo "made: read replica $REP_INSTANCE at $REP_IP (flags read back: $F; authorized networks read back: ${GOT:-none}), label pgvigil-proof=$PGVIGIL_LAB_PROOF (undo: down)"
  ;;
allow)
  need; load; shift
  [ $# -eq 1 ] && ip_ok "$1" || fail "allow <ip>: one IPv4 address (a range or 0.0.0.0 is never admitted)"
  body
  jq -n --arg a "$1/32" '{settings: {ipConfiguration: {authorizedNetworks: [{value: $a, name: "pgv-reader"}]}}}' > "$BODY"
  for i in "$PRI_INSTANCE" ${REP_IP:+"$REP_INSTANCE"}; do
    OP=$(api PATCH "instances/$i" "$BODY" | jq -r .name); wait_op "$OP"
    GOT=$(g sql instances describe "$i" --format='value(settings.ipConfiguration.authorizedNetworks[].value)')
    [ "$GOT" = "$1/32" ] || fail "$i's authorized networks read '$GOT', not $1/32 alone: run allow again or down"
    echo "allowed: $i admits $1/32 only"
  done
  rm -f "$BODY"
  ;;
logins)
  need; load; body
  command -v psql >/dev/null || fail "psql is not on this machine"
  MON_PW="$MON_PW" jq -n --arg u "$MON_USER" '{name: $u, password: env.MON_PW}' > "$BODY"
  OP=$(api POST "instances/$PRI_INSTANCE/users" "$BODY" | jq -r .name); rm -f "$BODY"; wait_op "$OP"
  PGPASSWORD="$ADMIN_PW" psql "host=$PRI_IP port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 \
    -c "GRANT pg_monitor TO $MON_USER" >/dev/null || fail "GRANT pg_monitor TO $MON_USER was refused (above): the login stays, without the role"
  # a user made through the API is put in cloudsqlsuperuser by Google (its users page), so pg_has_role would read
  # true through that path whatever the GRANT did: the DIRECT grant is read from pg_auth_members (finding 8)
  dm() { PGPASSWORD="$ADMIN_PW" psql "host=$PRI_IP port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM pg_auth_members m WHERE m.member = '$MON_USER'::regrole AND m.roleid = '$1'::regrole"; }
  G=$(dm pg_monitor); [ "$G" = 1 ] || fail "$MON_USER holds no direct grant of pg_monitor (pg_auth_members read back '$G')"
  # then the API's cloudsqlsuperuser taken away, so the collector's login is a pg_monitor login; a refusal (the
  # postgres user may hold no ADMIN OPTION on it) is printed and kept: the C rows run no SQL on this login
  PGPASSWORD="$ADMIN_PW" psql "host=$PRI_IP port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 \
    -c "REVOKE cloudsqlsuperuser FROM $MON_USER" >/dev/null || true
  SU=$(dm cloudsqlsuperuser)
  case $SU in
    0) SUW="not in cloudsqlsuperuser (read back)" ;;
    1) SUW="STILL in cloudsqlsuperuser (the REVOKE above was refused: this lab's collector login holds more than pg_monitor)" ;;
    *) fail "$MON_USER's cloudsqlsuperuser membership was not read ('$SU')" ;;
  esac
  echo "made: login $MON_USER on $PRI_INSTANCE with pg_monitor (direct grant read back), $SUW, its password in $STATE only (undo: down)"
  ;;
repl-off|repl-on)
  need; load
  [ -n "${REP_IP:-}" ] || fail "no replica in this lab (replica first)"
  if [ "$CMD" = repl-off ]; then FLAG=--no-enable-database-replication; else FLAG=--enable-database-replication; fi
  g sql instances patch "$REP_INSTANCE" "$FLAG"
  R=$(g sql instances describe "$REP_INSTANCE" --format='value(replicaConfiguration,settings.databaseReplicationEnabled)')
  echo "patched: $REP_INSTANCE $FLAG (read back: $R)"
  ;;
promote)
  need; load
  [ -n "${REP_IP:-}" ] || fail "no replica in this lab (replica first)"
  g sql instances promote-replica "$REP_INSTANCE"
  M=$(g sql instances describe "$REP_INSTANCE" --format='value(instanceType,masterInstanceName)')
  echo "promoted: $REP_INSTANCE (read back: $M); down deletes it as a standalone instance"
  ;;
status)
  need
  echo "label pgvigil-proof=$PGVIGIL_LAB_PROOF (the project's Cloud SQL instances):"
  # a failed read is said as failed; only the API's own 'not enabled' answer means none
  if L=$(g sql instances list --filter="settings.userLabels.pgvigil-proof=$PGVIGIL_LAB_PROOF" --format='value(name,databaseVersion,state,instanceType,ipAddresses[0].ipAddress)' 2>&1); then
    [ -z "$L" ] || sed 's/^/  /' <<<"$L"
  elif grep -qiE 'SERVICE_DISABLED|not (been )?enabled|has not been used' <<<"$L"; then echo "  (the API is not enabled: none)"
  else fail "the read failed: $L"; fi
  ;;
down)
  need; load
  # the replica first (Google refuses to delete a primary that has replicas); only a not-found answer means absent
  for i in "$REP_INSTANCE" "$PRI_INSTANCE"; do
    if ! absent "$i"; then g sql instances delete "$i"; echo "deleted: Cloud SQL instance $i"; fi
  done
  LEFT=
  for _ in $(seq 1 12); do
    L=$(g sql instances list --filter="name=$PRI_INSTANCE OR name=$REP_INSTANCE OR settings.userLabels.pgvigil-proof=$PGVIGIL_LAB_PROOF" --format='value(name)') || fail "the read-back failed (gcloud above): the state file $STATE stays"
    LEFT=$(grep -c . <<<"$L" || true)
    [ "$LEFT" = 0 ] && break; sleep 10
  done
  echo "read back: instances named $PRI_INSTANCE / $REP_INSTANCE or labelled pgvigil-proof=$PGVIGIL_LAB_PROOF $LEFT"
  [ "$LEFT" = 0 ] || fail "an instance is left (above): the state file $STATE stays"
  # a backup the replica's create took (Google: 'creates a backup, if needed') outlives its instance only when it is
  # retained, and a retained backup is billed: the project's backups are read back too, every field of each searched
  # for the two names (no field name assumed; finding 9)
  B=$(g sql backups list --instance=- --format=json) || fail "the backups read-back failed (gcloud above): the state file $STATE stays"
  BL=$(jq -r --arg p "$PRI_INSTANCE" '.[] | select(tostring | contains($p)) | (.name // .id // "?") + " " + (.instance // "?")' <<<"$B")
  echo "read back: backups naming $PRI_INSTANCE / $REP_INSTANCE $(grep -c . <<<"$BL" || true)"
  [ -z "$BL" ] || fail "a backup of this lab is left (billed while retained): $(tr '\n' ';' <<<"$BL") - delete it in the console's Backups page or with gcloud sql backups delete; the state file $STATE stays"
  if [ "${API_ENABLED_HERE:-0}" = 1 ]; then
    g services disable "$API" || fail "the project's $API stays enabled (undo: gcloud services disable $API --project $PGVIGIL_LAB_GCP_PROJECT, with --force if gcloud refuses it for recent use; --force also disables services that depend on it): the state file $STATE stays"
    echo "undone: the project's $API disabled again"
  fi
  rm -f "$STATE"
  echo "down: 0 left"
  ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
