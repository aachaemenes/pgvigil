#!/usr/bin/env bash
# Lab: one Google Cloud SQL for SQL Server instance (SQL Server 2022 Express, 1 vCPU / 3.75 GB, zonal, no backups)
# for the live proof scripts/proof-mssql-cloudsql.sh, made and removed from the machine that holds the gcloud
# sign-in.
#
#   scripts/lab/gcp-cloudsql.sh up                  enable the Cloud SQL Admin API if off, make the instance and the state file
#   scripts/lab/gcp-cloudsql.sh allow <ip>          the instance's authorized networks admit this address only
#   scripts/lab/gcp-cloudsql.sh status              what this lab holds now, read from Google
#   scripts/lab/gcp-cloudsql.sh down                delete the instance, read the listing back, disable the API if up enabled it
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF        the proof's label value: the instance carries pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_GCP_PROJECT  the project id (required)
#   PGVIGIL_LAB_GCP_REGION   the region (required for up)
#   PGVIGIL_LAB_DIR          the state folder, default .lab (up writes a .gitignore of '*' into it)
#   GCLOUD                   the gcloud CLI, default gcloud on the PATH
#
# What up makes: one instance labelled pgvigil-proof=<value>, public IPv4 with NO authorized network until 'allow'
# (nothing reaches it), automated backups and point-in-time recovery off, storage 10 GB SSD without auto-resize,
# deletion protection off. Google's 'sqlserver' user is the instance's highest login; its password is made here
# from /dev/urandom and written only to the mode-600 state file <dir>/gcp-cloudsql.env, and reaches Google in a
# mode-600 request body (the access token in a mode-600 header file), each removed right after the call - never on
# a command line, in the output or a log. Express carries no SQL Server licence charge; the instance bills its vCPU,
# memory and disk by the hour while it exists (Google's price for 1 vCPU / 3.75 GB about USD 0.07 / h).
# down deletes the instance, reads the project's instances back (by name and by the label) and removes the state
# file only when none is left; the API is disabled again only if up was the one that enabled it.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/gcp-cloudsql.env
GCLOUD=${GCLOUD:-gcloud}
API=sqladmin.googleapis.com
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
GCS_INSTANCE=pgv-proof-$SUF
GCS_PORT=1433
ROOT_USER=sqlserver
ROOT_PW=$(pw)
MON_USER=pgv_monitor
MON_PW=$(pw)
EOF
  )
  load
  BODY=$(umask 077; mktemp "$DIR/gcp-b.XXXXXX")
  trap 'rm -f "$BODY"' EXIT
  # the password reaches jq through its environment, never its command line (ps shows argv)
  ROOT_PW="$ROOT_PW" jq -n --arg n "$GCS_INSTANCE" --arg r "$LAB_REGION" --arg l "$PGVIGIL_LAB_PROOF" '{
    name: $n, region: $r, databaseVersion: "SQLSERVER_2022_EXPRESS", rootPassword: env.ROOT_PW,
    settings: {tier: "db-custom-1-3840", edition: "ENTERPRISE", availabilityType: "ZONAL", dataDiskType: "PD_SSD",
               dataDiskSizeGb: "10", storageAutoResize: false, deletionProtectionEnabled: false,
               backupConfiguration: {enabled: false, pointInTimeRecoveryEnabled: false},
               ipConfiguration: {ipv4Enabled: true, authorizedNetworks: []},
               userLabels: {"pgvigil-proof": $l}}}' > "$BODY"
  OP=$(api POST instances "$BODY" | jq -r .name); rm -f "$BODY"
  [ -n "$OP" ] && [ "$OP" != null ] || fail "the create returned no operation (down removes what was made)"
  echo "accepted: instance $GCS_INSTANCE ($LAB_REGION, SQL Server 2022 Express, db-custom-1-3840), operation $OP - waiting (Google: several minutes)"
  wait_op "$OP"
  GCS_IP=$(g sql instances describe "$GCS_INSTANCE" --format='value(ipAddresses[0].ipAddress)')
  [ -n "$GCS_IP" ] || fail "the instance's address was not read back"
  ( umask 077; printf 'GCS_IP=%s\n' "$GCS_IP" >> "$STATE" )
  echo "made: Cloud SQL instance $GCS_INSTANCE in $LAB_REGION at $GCS_IP, label pgvigil-proof=$PGVIGIL_LAB_PROOF, no authorized network (undo: down)"
  echo "up: $GCS_IP,1433 (the sqlserver user's password in $STATE, mode 600); no address admitted yet: allow <ip>"
  ;;
allow)
  need; load; shift
  [ $# -eq 1 ] && ip_ok "$1" || fail "allow <ip>: one IPv4 address (a range or 0.0.0.0 is never admitted)"
  BODY=$(umask 077; mktemp "$DIR/gcp-b.XXXXXX"); trap 'rm -f "$BODY"' EXIT
  jq -n --arg a "$1/32" '{settings: {ipConfiguration: {authorizedNetworks: [{value: $a, name: "pgv-reader"}]}}}' > "$BODY"
  OP=$(api PATCH "instances/$GCS_INSTANCE" "$BODY" | jq -r .name); rm -f "$BODY"; wait_op "$OP"
  GOT=$(g sql instances describe "$GCS_INSTANCE" --format='value(settings.ipConfiguration.authorizedNetworks[].value)')
  [ "$GOT" = "$1/32" ] || fail "the authorized networks read '$GOT', not $1/32 alone: run allow again or down"
  echo "allowed: $GCS_INSTANCE admits $1/32 only"
  ;;
status)
  need
  echo "label pgvigil-proof=$PGVIGIL_LAB_PROOF (the project's Cloud SQL instances):"
  # a failed read is said as failed; only the API's own 'not enabled' answer means none
  if L=$(g sql instances list --filter="settings.userLabels.pgvigil-proof=$PGVIGIL_LAB_PROOF" --format='value(name,databaseVersion,state,ipAddresses[0].ipAddress)' 2>&1); then
    [ -z "$L" ] || sed 's/^/  /' <<<"$L"
  elif grep -qiE 'SERVICE_DISABLED|not (been )?enabled|has not been used' <<<"$L"; then echo "  (the API is not enabled: none)"
  else fail "the read failed: $L"; fi
  ;;
down)
  need; load
  # only Google's not-found answer means 'absent': any other failed read (a lapsed sign-in, the network) stops here
  # with nothing deleted and the state file kept, never a silent '0 left'
  if D=$(g sql instances describe "$GCS_INSTANCE" --format='value(name)' 2>&1); then
    g sql instances delete "$GCS_INSTANCE"; echo "deleted: Cloud SQL instance $GCS_INSTANCE"
  elif ! grep -qiE 'HTTPError 404|does not exist|not found' <<<"$D"; then
    fail "the instance $GCS_INSTANCE was not read ($D): nothing deleted, the state file $STATE stays"
  fi
  LEFT=
  for _ in $(seq 1 12); do
    L=$(g sql instances list --filter="name=$GCS_INSTANCE OR settings.userLabels.pgvigil-proof=$PGVIGIL_LAB_PROOF" --format='value(name)') || fail "the read-back failed (gcloud above): the state file $STATE stays"
    LEFT=$(grep -c . <<<"$L" || true)
    [ "$LEFT" = 0 ] && break; sleep 10
  done
  echo "read back: instances named $GCS_INSTANCE or labelled pgvigil-proof=$PGVIGIL_LAB_PROOF $LEFT"
  [ "$LEFT" = 0 ] || fail "an instance is left (above): the state file $STATE stays"
  # gcloud refuses to disable a service enabled in the last 3 days or used in the last 30 unless told to bypass
  # that check (services disable --bypass-api-usage-check); a refusal keeps the state file, so down runs again
  if [ "${API_ENABLED_HERE:-0}" = 1 ]; then
    g services disable "$API" --bypass-api-usage-check || fail "the project's $API stays enabled (undo: gcloud services disable $API --bypass-api-usage-check --project $PGVIGIL_LAB_GCP_PROJECT): the state file $STATE stays"
    echo "undone: the project's $API disabled again"
  fi
  rm -f "$STATE"
  echo "down: 0 left"
  ;;
*) sed -n '2,10p' "$0"; exit 2 ;;
esac
