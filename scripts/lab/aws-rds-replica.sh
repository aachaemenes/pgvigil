#!/usr/bin/env bash
# Lab RP (task 390b): an Amazon RDS for PostgreSQL source and one read replica for the provider replica proof
# scripts/proof-cloud-replicas.sh, made and removed from the machine that holds the AWS CLI sign-in.
#
#   scripts/lab/aws-rds-replica.sh up                  the source (and its security group, the lab's parameter group, the state file)
#   scripts/lab/aws-rds-replica.sh replica             the read replica of the source (it takes the source's parameter group)
#   scripts/lab/aws-rds-replica.sh allow <ip> [<ip>]   the security group admits 5432 from these addresses only
#   scripts/lab/aws-rds-replica.sh logins              (where 5432 reaches) the collector's login on the source (pg_monitor)
#   scripts/lab/aws-rds-replica.sh reboot              reboot the replica (R-E)
#   scripts/lab/aws-rds-replica.sh promote             promote the replica to a standalone instance (R-F)
#   scripts/lab/aws-rds-replica.sh status              what this lab holds now, read from AWS
#   scripts/lab/aws-rds-replica.sh down                delete everything it made and read the listing back
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF        the proof's tag value: every resource carries the tag pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_AWS_PROFILE  the AWS CLI profile (required)
#   PGVIGIL_LAB_AWS_REGION   the region (required; the design's lab is us-east-2)
#   PGVIGIL_LAB_DIR          the state folder, default .lab (up writes a .gitignore of '*' into it)
#
# What it makes, each tagged: one security group in the default VPC (no ingress until 'allow'); one DB parameter group
# of the default engine version's family with max_standby_streaming_delay = -1 and hot_standby_feedback = 0 (the
# design fold 10: a long read on the replica holds replay for as long as it runs, so the proof's lag fault is
# deterministic); the source: db.t4g.micro, the default PostgreSQL version, 20 GB gp3, single AZ, publicly accessible
# through the group only, automated backups for 1 day (RDS makes no read replica of an instance without them), no
# Performance Insights, no enhanced monitoring, deletion protection off, the parameter group above (both settings act
# on a standby only); the replica: db.t4g.micro, the same security group, and the source's parameter group - RDS takes
# no parameter group at a PostgreSQL read replica's create ('A parameter group can't be specified during Read Replica
# creation for the following DB engine: postgres') and gives a same-Region replica its source's; 'replica' reads the
# group and the setting back. About USD 0.016 an hour each plus gp3 (the design's price line, USD 0.08 for the lab's hours);
# the AWS lab's rules: one lab at a time, down the same day, stop and ask over USD 5.
# The master and the collector's passwords are made here from /dev/urandom, written only to the mode-600 state file
# <dir>/aws-rds-replica.env and handed to the AWS CLI in a mode-600 request file removed right after the call, to psql
# in PGPASSWORD: never on a command line, in the output or in a log.
# down: both instances deleted with no final snapshot and their automated backups deleted, then the parameter group
# (the source's and the replica's: one group, named <id>-replica) and the security group; the listing read back (the
# instances, the groups, every resource carrying the tag, backups and snapshots of either instance - the snapshots for
# up to 5 minutes: an automated one goes a little after its instance) and the state file removed only when nothing is
# left; a snapshot still listed then is named with its kind and what removes it.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/aws-rds-replica.env
CMD=${1:-}
CLASS=db.t4g.micro
fail() { echo "FAIL: $*" >&2; exit 1; }
need_aws() {
  : "${PGVIGIL_LAB_PROOF:?the tag value (pgvigil-proof=<value>)}" "${PGVIGIL_LAB_AWS_PROFILE:?the AWS CLI profile}" "${PGVIGIL_LAB_AWS_REGION:?the region}"
  [[ $PGVIGIL_LAB_PROOF =~ ^[A-Za-z0-9-]{1,40}$ ]] || fail "PGVIGIL_LAB_PROOF is letters, digits and dashes"
  command -v aws >/dev/null || fail "the AWS CLI is not on this machine"
}
aw() { aws --profile "$PGVIGIL_LAB_AWS_PROFILE" --region "$PGVIGIL_LAB_AWS_REGION" "$@"; }
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
# load: the state file names the scope up used; a call under another profile, region or tag is refused (it would read
# the wrong place and could say 0 left while an instance runs)
load() { [ -r "$STATE" ] || fail "no state file $STATE (run up first)"; # shellcheck disable=SC1090
  . "$STATE"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git check-ignore -q "$STATE" || fail "$STATE is not git-ignored (it holds passwords)"; fi
  [ -z "${PGVIGIL_LAB_AWS_PROFILE:-}" ] || [ "$PGVIGIL_LAB_AWS_PROFILE" = "${LAB_PROFILE:-}" ] || fail "the state file was made with profile '${LAB_PROFILE:-}', not '$PGVIGIL_LAB_AWS_PROFILE'"
  [ -z "${PGVIGIL_LAB_AWS_REGION:-}" ] || [ "$PGVIGIL_LAB_AWS_REGION" = "${LAB_REGION:-}" ] || fail "the state file was made with region '${LAB_REGION:-}', not '$PGVIGIL_LAB_AWS_REGION'"
  [ -z "${PGVIGIL_LAB_PROOF:-}" ] || [ "$PGVIGIL_LAB_PROOF" = "${LAB_PROOF:-}" ] || fail "the state file was made with tag '${LAB_PROOF:-}', not '$PGVIGIL_LAB_PROOF'"; }
setstate() { sed -i "s|^$1=.*|$1=$2|" "$STATE"; }
ip_ok() { local oct='(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
  [[ $1 =~ ^$oct\.$oct\.$oct\.$oct$ ]] && [ "$1" != 0.0.0.0 ]; }
# create <request json file> <command>: one create call from a mode-600 request file, removed right after
create() { local req=$1; shift; local err rc=0; err=$(mktemp)
  aw rds "$@" --cli-input-json "file://$req" --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus,EngineVersion]' --output text 2>"$err" || rc=$?
  rm -f "$req"; [ $rc -eq 0 ] || { echo "REFUSED: AWS said:" >&2; cat "$err" >&2; }; rm -f "$err"; return $rc; }

case $CMD in
up)
  need_aws
  [ ! -e "$STATE" ] || fail "$STATE exists: this lab is up (status) or was not taken down (down)"
  mkdir -p "$DIR"; chmod 700 "$DIR"; printf '*\n' > "$DIR/.gitignore"
  SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ( umask 077; cat > "$STATE" <<EOF
LAB_PROFILE=$PGVIGIL_LAB_AWS_PROFILE
LAB_REGION=$PGVIGIL_LAB_AWS_REGION
LAB_PROOF=$PGVIGIL_LAB_PROOF
SRC_ID=pgv-proof-$SUF
REP_ID=pgv-proof-$SUF-r1
SG_NAME=pgv-proof-$SUF
SG=
PG_GROUP=pgv-proof-$SUF-replica
PG_FAMILY=
SRC_HOST=
REP_HOST=
PORT=5432
DB=postgres
ADMIN_USER=pgv_admin
ADMIN_PW=$(pw)
MON_USER=pgv_monitor
MON_PW=$(pw)
EOF
  )
  load
  VPC=$(aw ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ $VPC == vpc-* ]] || fail "no default VPC in this region (read: $VPC)"
  SGID=$(aw ec2 create-security-group --group-name "$SG_NAME" --description "pgvigil proof $PGVIGIL_LAB_PROOF: PostgreSQL 5432 from named addresses only" \
    --vpc-id "$VPC" --tag-specifications "ResourceType=security-group,Tags=[{Key=pgvigil-proof,Value=$PGVIGIL_LAB_PROOF}]" --query GroupId --output text)
  setstate SG "$SGID"
  echo "made: security group $SGID ($SG_NAME) in $VPC, tag pgvigil-proof=$PGVIGIL_LAB_PROOF, no ingress yet"
  FAM=$(aw rds describe-db-engine-versions --engine postgres --default-only --query 'DBEngineVersions[0].DBParameterGroupFamily' --output text)
  [[ $FAM == postgres* ]] || fail "the default PostgreSQL version's parameter group family was not read ($FAM)"
  setstate PG_FAMILY "$FAM"
  aw rds create-db-parameter-group --db-parameter-group-name "$PG_GROUP" --db-parameter-group-family "$FAM" \
    --description "pgvigil proof $PGVIGIL_LAB_PROOF: the source's group, taken by its replica - replay held by a long read (max_standby_streaming_delay -1)" \
    --tags "Key=pgvigil-proof,Value=$PGVIGIL_LAB_PROOF" --query 'DBParameterGroup.DBParameterGroupName' --output text | sed 's/^/made: parameter group /'
  aw rds modify-db-parameter-group --db-parameter-group-name "$PG_GROUP" --parameters \
    "ParameterName=max_standby_streaming_delay,ParameterValue=-1,ApplyMethod=immediate" \
    "ParameterName=hot_standby_feedback,ParameterValue=0,ApplyMethod=immediate" >/dev/null
  echo "  $PG_GROUP: max_standby_streaming_delay -1, hot_standby_feedback 0"
  REQ=$(umask 077; mktemp "$DIR/rds-create.XXXXXX.json")
  python3 - "$REQ" <<PY
import json, sys
json.dump({
  "DBInstanceIdentifier": "$SRC_ID", "DBInstanceClass": "$CLASS", "Engine": "postgres",
  "AllocatedStorage": 20, "StorageType": "gp3", "MasterUsername": "$ADMIN_USER", "MasterUserPassword": "$ADMIN_PW",
  "VpcSecurityGroupIds": ["$SGID"], "PubliclyAccessible": True, "MultiAZ": False, "DBParameterGroupName": "$PG_GROUP",
  "BackupRetentionPeriod": 1, "AutoMinorVersionUpgrade": False, "DeletionProtection": False,
  "CopyTagsToSnapshot": False, "EnablePerformanceInsights": False, "MonitoringInterval": 0,
  "Tags": [{"Key": "pgvigil-proof", "Value": "$PGVIGIL_LAB_PROOF"}],
}, open(sys.argv[1], "w"))
PY
  if ! create "$REQ" create-db-instance; then
    if aw rds describe-db-instances --db-instance-identifier "$SRC_ID" >/dev/null 2>&1; then echo "the instance $SRC_ID exists despite the error: run down" >&2; exit 3; fi
    echo "the create was refused: run down to remove the security group and the parameter group" >&2; exit 3
  fi
  echo "made: DB instance $SRC_ID (postgres, $CLASS, 20 GB gp3, backups 1 day, parameter group $PG_GROUP); waiting until it is available (10-20 min)"
  aw rds wait db-instance-available --db-instance-identifier "$SRC_ID" || aw rds wait db-instance-available --db-instance-identifier "$SRC_ID"
  setstate SRC_HOST "$(aw rds describe-db-instances --db-instance-identifier "$SRC_ID" --query 'DBInstances[0].Endpoint.Address' --output text)"
  load; echo "up: the source $SRC_HOST:5432; next: allow <the reading machine's address>, logins, then (R-B) replica"
  ;;
replica)
  need_aws; load
  [ -n "$SRC_HOST" ] || fail "the source is not up"
  REQ=$(umask 077; mktemp "$DIR/rds-replica.XXXXXX.json")
  python3 - "$REQ" <<PY
import json, sys
json.dump({
  "DBInstanceIdentifier": "$REP_ID", "SourceDBInstanceIdentifier": "$SRC_ID", "DBInstanceClass": "$CLASS",
  "StorageType": "gp3", "VpcSecurityGroupIds": ["$SG"], "PubliclyAccessible": True, "MultiAZ": False,
  "AutoMinorVersionUpgrade": False, "DeletionProtection": False,
  "EnablePerformanceInsights": False, "MonitoringInterval": 0,
  "Tags": [{"Key": "pgvigil-proof", "Value": "$PGVIGIL_LAB_PROOF"}],
}, open(sys.argv[1], "w"))
PY
  create "$REQ" create-db-instance-read-replica || exit 3
  echo "made: read replica $REP_ID of $SRC_ID ($CLASS; no parameter group named: RDS gives it the source's); waiting until it is available"
  aw rds wait db-instance-available --db-instance-identifier "$REP_ID" || aw rds wait db-instance-available --db-instance-identifier "$REP_ID"
  setstate REP_HOST "$(aw rds describe-db-instances --db-instance-identifier "$REP_ID" --query 'DBInstances[0].Endpoint.Address' --output text)"
  load
  # the replica's group as RDS reports it, and the setting the proof's hold rests on as the replica itself answers it
  # (where 5432 reaches from here: after 'allow'); a replica on another group could not hold replay
  G=$(aw rds describe-db-instances --db-instance-identifier "$REP_ID" --query 'DBInstances[0].DBParameterGroups[0].[DBParameterGroupName,ParameterApplyStatus]' --output text | tr '\t' ' ')
  [ "${G%% *}" = "$PG_GROUP" ] || fail "the replica's parameter group is '$G', not the source's $PG_GROUP: the proof's hold would not hold (down removes it)"
  V=$(PGPASSWORD="$ADMIN_PW" psql "host=$REP_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtqc 'show max_standby_streaming_delay' 2>/dev/null || echo 'not read')
  echo "replica: $REP_HOST:5432 (the source's logins replicate to it); parameter group $G; max_standby_streaming_delay on it: $V"
  # a replica that answers another value would hold no replay (AWS: 'wait at least 5 minutes' between a group's modify
  # and the first instance made with it): said here, before the proof's hold rests on it; 'not read' = 5432 does not
  # reach from this machine, the proof's own row is then the judge
  [ "$V" = 'not read' ] || [ "$V" = -1 ] || fail "the replica answers max_standby_streaming_delay $V, not -1 (parameter group $G): the proof's hold would not hold - reboot the replica if the group is pending-reboot, else down"
  ;;
allow)
  need_aws; load; shift
  [ $# -ge 1 ] || fail "allow <ip> [<ip> ...]: one address at least"
  for a in "$@"; do ip_ok "$a" || fail "not one IPv4 address: $a (a range or 0.0.0.0 is never admitted)"; done
  OLD=$(aw ec2 describe-security-groups --group-ids "$SG" --query 'SecurityGroups[0].IpPermissions' --output json)
  if [ "$OLD" != "[]" ]; then aw ec2 revoke-security-group-ingress --group-id "$SG" --ip-permissions "$OLD" >/dev/null; fi
  PERM=$(python3 -c 'import json,sys; print(json.dumps([{"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,"IpRanges":[{"CidrIp":a+"/32","Description":"pgvigil proof reader"} for a in sys.argv[1:]]}]))' "$@")
  aw ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions "$PERM" >/dev/null
  echo "allowed: $SG admits tcp 5432 from $(aw ec2 describe-security-groups --group-ids "$SG" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | tr '\t' ' ') only"
  ;;
logins)
  load
  [ -n "$SRC_HOST" ] || fail "the source is not up"
  command -v psql >/dev/null || fail "psql is not on this machine"
  # the collector's password reaches psql in its environment (\getenv, psql 15 or later), never its command line
  PGPASSWORD="$ADMIN_PW" PGV_MON_PW="$MON_PW" psql "host=$SRC_HOST port=5432 user=$ADMIN_USER dbname=postgres sslmode=require connect_timeout=20" -XAtq -v ON_ERROR_STOP=1 \
    -v mon="$MON_USER" <<'SQL'
\getenv monpw PGV_MON_PW
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'mon', :'monpw') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'mon') \gexec
SELECT format('GRANT pg_monitor TO %I', :'mon') \gexec
SELECT 'logins: ' || :'mon' || ' in ' || string_agg(b.rolname, ', ') FROM pg_auth_members m JOIN pg_roles b ON b.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = :'mon';
SQL
  ;;
reboot)
  need_aws; load
  aw rds reboot-db-instance --db-instance-identifier "$REP_ID" --query 'DBInstance.DBInstanceStatus' --output text | sed "s/^/rebooting: $REP_ID /"
  ;;
promote)
  need_aws; load
  aw rds promote-read-replica --db-instance-identifier "$REP_ID" --backup-retention-period 0 --query 'DBInstance.DBInstanceStatus' --output text | sed "s/^/promoting: $REP_ID /"
  # the waiter can return at once while the status is still 'available', before 'modifying': the
  # promotion is read as done only when the instance names no source
  S=
  for _ in $(seq 1 60); do
    S=$(aw rds describe-db-instances --db-instance-identifier "$REP_ID" --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text)
    { [ "$S" = None ] || [ -z "$S" ]; } && break; sleep 10
  done
  { [ "$S" = None ] || [ -z "$S" ]; } || fail "$REP_ID still names its source $S after 10 minutes: read status, then down"
  aw rds wait db-instance-available --db-instance-identifier "$REP_ID" || aw rds wait db-instance-available --db-instance-identifier "$REP_ID"
  echo "promoted: $REP_ID is a standalone instance (no source read back)"
  ;;
status)
  need_aws
  echo "tag pgvigil-proof=$PGVIGIL_LAB_PROOF:"
  aw rds describe-db-instances --query "DBInstances[?TagList[?Key=='pgvigil-proof' && Value=='$PGVIGIL_LAB_PROOF']].[DBInstanceIdentifier,DBInstanceStatus,DBInstanceClass,ReadReplicaSourceDBInstanceIdentifier,Endpoint.Address]" --output text | sed 's/^/  rds: /'
  aw rds describe-db-parameter-groups --query "DBParameterGroups[?starts_with(DBParameterGroupName,'pgv-proof-')].[DBParameterGroupName,DBParameterGroupFamily]" --output text | sed 's/^/  parameter group: /'
  aw ec2 describe-security-groups --filters "Name=tag:pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'SecurityGroups[].[GroupId,GroupName,join(`,`,IpPermissions[].IpRanges[].CidrIp)]' --output text | sed 's/^/  security group: /'
  aw rds describe-db-instance-automated-backups --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier,'pgv-proof-')].[DBInstanceIdentifier,Status]" --output text | sed 's/^/  automated backups: /'
  ;;
down)
  need_aws; load
  # the replica first (RDS refuses to delete a source that still has one), then the source
  for ID in "$REP_ID" "$SRC_ID"; do
    ST=$(aw rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)
    [ -n "$ST" ] || continue
    [ "$ST" = deleting ] || aw rds delete-db-instance --db-instance-identifier "$ID" --skip-final-snapshot --delete-automated-backups --query 'DBInstance.DBInstanceStatus' --output text | sed "s/^/deleting: $ID /"
    aw rds wait db-instance-deleted --db-instance-identifier "$ID" || aw rds wait db-instance-deleted --db-instance-identifier "$ID"
  done
  if aw rds describe-db-parameter-groups --db-parameter-group-name "$PG_GROUP" >/dev/null 2>&1; then aw rds delete-db-parameter-group --db-parameter-group-name "$PG_GROUP"; fi
  [ -n "$SG" ] || SG=$(aw ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=tag:pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'SecurityGroups[0].GroupId' --output text)
  [ "$SG" != None ] || SG=
  if [ -n "$SG" ] && aw ec2 describe-security-groups --group-ids "$SG" >/dev/null 2>&1; then
    for _ in $(seq 1 30); do aw ec2 delete-security-group --group-id "$SG" 2>/dev/null && break; sleep 10; done
  fi
  LEFT_DB=$(aw rds describe-db-instances --query "length(DBInstances[?DBInstanceIdentifier=='$SRC_ID' || DBInstanceIdentifier=='$REP_ID'])" --output text)
  LEFT_PG=$(aw rds describe-db-parameter-groups --query "length(DBParameterGroups[?DBParameterGroupName=='$PG_GROUP'])" --output text)
  LEFT_SG=$(aw ec2 describe-security-groups --filters "Name=tag:pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'length(SecurityGroups)' --output text)
  if [ -n "$SG" ]; then LEFT_SG=$((LEFT_SG + $(aw ec2 describe-security-groups --filters "Name=group-id,Values=$SG" --query 'length(SecurityGroups)' --output text))); fi
  LEFT_BK=$(aw rds describe-db-instance-automated-backups --query "length(DBInstanceAutomatedBackups[?DBInstanceIdentifier=='$SRC_ID' || DBInstanceIdentifier=='$REP_ID'])" --output text)
  # an automated snapshot goes with its instance's automated backups a little after the delete's waiter returns (seen
  # once: still listed 'available' 20 s after it): it is read for up to 5 minutes before it counts as left
  LEFT_SN=
  for _ in $(seq 1 30); do
    LEFT_SN=$(aw rds describe-db-snapshots --query "length(DBSnapshots[?DBInstanceIdentifier=='$SRC_ID' || DBInstanceIdentifier=='$REP_ID'])" --output text)
    [ "$LEFT_SN" = 0 ] && break
    sleep 10
  done
  LEFT_TAG=$(aw resourcegroupstaggingapi get-resources --tag-filters "Key=pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'ResourceTagMappingList[].ResourceARN' --output text)
  echo "read back: instances $LEFT_DB, parameter groups $LEFT_PG, security groups $LEFT_SG, automated backups $LEFT_BK, snapshots $LEFT_SN; tagged resources listed: ${LEFT_TAG:-none}"
  if [ "$LEFT_SN" != 0 ]; then
    aw rds describe-db-snapshots --query "DBSnapshots[?DBInstanceIdentifier=='$SRC_ID' || DBInstanceIdentifier=='$REP_ID'].[DBSnapshotIdentifier,SnapshotType,Status]" --output text | sed 's/^/  snapshot left: /' || true
    echo "  an automated snapshot goes by itself: run down again in a few minutes; a manual one: aws rds delete-db-snapshot --db-snapshot-identifier <id>"
  fi
  [ "$LEFT_DB|$LEFT_PG|$LEFT_SG|$LEFT_BK|$LEFT_SN" = "0|0|0|0|0" ] || fail "something is left (above): the state file $STATE stays"
  [ -z "$LEFT_TAG" ] || echo "note: the tagging index still lists the ARNs above; the services themselves read 0 (it catches up in minutes)"
  rm -f "$STATE"
  echo "down: 0 left"
  ;;
*) sed -n '2,16p' "$0"; exit 2 ;;
esac
