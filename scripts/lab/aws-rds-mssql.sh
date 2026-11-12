#!/usr/bin/env bash
# Lab: one Amazon RDS for SQL Server instance (Express edition, the smallest class) for the cloud proof
# scripts/proof-mssql-rds.sh, made and removed from the machine that holds the AWS CLI sign-in.
#
#   scripts/lab/aws-rds-mssql.sh up                  make the instance, its security group and the state file
#   scripts/lab/aws-rds-mssql.sh allow <ip> [<ip>]   the security group admits 1433 from these addresses only
#   scripts/lab/aws-rds-mssql.sh logins              (where 1433 reaches) the collector's login and its rights
#   scripts/lab/aws-rds-mssql.sh status              what this lab holds now, read from AWS
#   scripts/lab/aws-rds-mssql.sh down                delete everything it made and read the listing back
#
# Settings (environment):
#   PGVIGIL_LAB_PROOF        the proof's tag value: every resource carries the tag pgvigil-proof=<value> (required)
#   PGVIGIL_LAB_AWS_PROFILE  the AWS CLI profile (required for up, allow, status, down)
#   PGVIGIL_LAB_AWS_REGION   the region (required for up, allow, status, down)
#   PGVIGIL_LAB_DIR          the state folder, default .lab (up writes a .gitignore of '*' into it)
#   PGVIGIL_SQLCMD_IMAGE     the image whose sqlcmd 'logins' runs, default mcr.microsoft.com/mssql/server:2022-latest
#
# What up makes, each tagged: one security group in the default VPC (no ingress until 'allow'), one DB instance
# (engine sqlserver-ex, the default engine version, db.t3.micro, 20 GB gp3, single AZ, publicly accessible through
# that group only, automated backups off, no Performance Insights, no enhanced monitoring, deletion protection off).
# ONE create call decides: an account plan that refuses it ends 'up' with the refusal's text, and the security group
# it made first is deleted again. The master password and the collector's password are made here from
# /dev/urandom, written only to the mode-600 state file <dir>/aws-rds-mssql.env and handed to the AWS CLI in a
# mode-600 request file that is removed right after the call: never on a command line, in the output or in a log.
# down: the instance is deleted with no final snapshot and its automated backups deleted, then the group; the
# listing is read back (the instance, the group and every resource carrying the tag) and the state file is removed
# only when nothing is left.
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=${PGVIGIL_LAB_DIR:-.lab}
STATE=$DIR/aws-rds-mssql.env
SQLCMD_IMAGE=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
CMD=${1:-}
fail() { echo "FAIL: $*" >&2; exit 1; }
need_aws() {
  : "${PGVIGIL_LAB_PROOF:?the tag value (pgvigil-proof=<value>)}" "${PGVIGIL_LAB_AWS_PROFILE:?the AWS CLI profile}" "${PGVIGIL_LAB_AWS_REGION:?the region}"
  [[ $PGVIGIL_LAB_PROOF =~ ^[A-Za-z0-9-]{1,40}$ ]] || fail "PGVIGIL_LAB_PROOF is letters, digits and dashes"
  command -v aws >/dev/null || fail "the AWS CLI is not on this machine"
}
aw() { aws --profile "$PGVIGIL_LAB_AWS_PROFILE" --region "$PGVIGIL_LAB_AWS_REGION" "$@"; }
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
# load: the state file, which names the account scope up used; a call under another profile, region or tag would read
# the wrong place and could say 0 left while the instance runs, so it is refused
load() { [ -r "$STATE" ] || fail "no state file $STATE (run up first)"; # shellcheck disable=SC1090
  . "$STATE"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then git check-ignore -q "$STATE" || fail "$STATE is not git-ignored (it holds passwords)"; fi
  [ -z "${PGVIGIL_LAB_AWS_PROFILE:-}" ] || [ "$PGVIGIL_LAB_AWS_PROFILE" = "${LAB_PROFILE:-}" ] || fail "the state file was made with profile '${LAB_PROFILE:-}', not '$PGVIGIL_LAB_AWS_PROFILE'"
  [ -z "${PGVIGIL_LAB_AWS_REGION:-}" ] || [ "$PGVIGIL_LAB_AWS_REGION" = "${LAB_REGION:-}" ] || fail "the state file was made with region '${LAB_REGION:-}', not '$PGVIGIL_LAB_AWS_REGION'"
  [ -z "${PGVIGIL_LAB_PROOF:-}" ] || [ "$PGVIGIL_LAB_PROOF" = "${LAB_PROOF:-}" ] || fail "the state file was made with tag '${LAB_PROOF:-}', not '$PGVIGIL_LAB_PROOF'"; }
# one IPv4 address, no leading zeros (00.0.0.0 would slip past a text compare), never 0.0.0.0
ip_ok() { local oct='(0|[1-9][0-9]?|1[0-9]{2}|2[0-4][0-9]|25[0-5])'
  [[ $1 =~ ^$oct\.$oct\.$oct\.$oct$ ]] && [ "$1" != 0.0.0.0 ]; }

case $CMD in
up)
  need_aws
  [ ! -e "$STATE" ] || fail "$STATE exists: this lab is up (status) or was not taken down (down)"
  mkdir -p "$DIR"; chmod 700 "$DIR"; printf '*\n' > "$DIR/.gitignore"   # the folder ignores itself on any clone
  SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
  ID=pgv-proof-$SUF; SGN=pgv-proof-$SUF
  ( umask 077; cat > "$STATE" <<EOF
LAB_PROFILE=$PGVIGIL_LAB_AWS_PROFILE
LAB_REGION=$PGVIGIL_LAB_AWS_REGION
LAB_PROOF=$PGVIGIL_LAB_PROOF
RDS_ID=$ID
RDS_SG_NAME=$SGN
RDS_SG=
RDS_HOST=
RDS_PORT=1433
RDS_DB=master
ADMIN_USER=pgv_admin
ADMIN_PW=$(pw)
MON_USER=pgv_monitor
MON_PW=$(pw)
EOF
  )
  load
  VPC=$(aw ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ $VPC == vpc-* ]] || fail "no default VPC in this region (read: $VPC)"
  TAGSPEC="ResourceType=security-group,Tags=[{Key=pgvigil-proof,Value=$PGVIGIL_LAB_PROOF}]"
  SG=$(aw ec2 create-security-group --group-name "$SGN" --description "pgvigil proof $PGVIGIL_LAB_PROOF: SQL Server 1433 from named addresses only" \
    --vpc-id "$VPC" --tag-specifications "$TAGSPEC" --query GroupId --output text)
  sed -i "s/^RDS_SG=.*/RDS_SG=$SG/" "$STATE"
  echo "made: security group $SG ($SGN) in $VPC, tag pgvigil-proof=$PGVIGIL_LAB_PROOF, no ingress yet"
  REQ=$(umask 077; mktemp "$DIR/rds-create.XXXXXX.json")
  trap 'rm -f "$REQ"' EXIT
  python3 - "$REQ" <<PY
import json, sys
json.dump({
  "DBInstanceIdentifier": "$ID", "DBInstanceClass": "db.t3.micro", "Engine": "sqlserver-ex",
  "LicenseModel": "license-included", "AllocatedStorage": 20, "StorageType": "gp3",
  "MasterUsername": "$ADMIN_USER", "MasterUserPassword": "$ADMIN_PW",
  "VpcSecurityGroupIds": ["$SG"], "PubliclyAccessible": True, "MultiAZ": False,
  "BackupRetentionPeriod": 0, "AutoMinorVersionUpgrade": False, "DeletionProtection": False,
  "CopyTagsToSnapshot": False, "EnablePerformanceInsights": False, "MonitoringInterval": 0,
  "Tags": [{"Key": "pgvigil-proof", "Value": "$PGVIGIL_LAB_PROOF"}],
}, open(sys.argv[1], "w"))
PY
  ERR=$(mktemp)
  if ! aw rds create-db-instance --cli-input-json "file://$REQ" --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus,EngineVersion]' --output text 2>"$ERR"; then
    rm -f "$REQ"
    echo "REFUSED: the create call of $ID failed; AWS said:" >&2; cat "$ERR" >&2; rm -f "$ERR"
    # a create the client saw fail can still have been accepted (a retry after a timeout): then nothing is removed
    if aw rds describe-db-instances --db-instance-identifier "$ID" >/dev/null 2>&1; then
      echo "the instance $ID exists despite the error: run down" >&2; exit 3; fi
    aw ec2 delete-security-group --group-id "$SG" || { echo "the security group $SG is left: run down" >&2; exit 3; }
    echo "removed: security group $SG"
    rm -f "$STATE"
    exit 3
  fi
  rm -f "$REQ" "$ERR"
  echo "made: DB instance $ID (sqlserver-ex, db.t3.micro, 20 GB gp3), tag pgvigil-proof=$PGVIGIL_LAB_PROOF; waiting until it is available (15-30 min)"
  aw rds wait db-instance-available --db-instance-identifier "$ID" || aw rds wait db-instance-available --db-instance-identifier "$ID"
  HOST=$(aw rds describe-db-instances --db-instance-identifier "$ID" --query 'DBInstances[0].Endpoint.Address' --output text)
  sed -i "s/^RDS_HOST=.*/RDS_HOST=$HOST/" "$STATE"
  echo "up: $HOST,1433 (master user and passwords in $STATE, mode 600); next: allow <the reading machine's address>, then logins"
  ;;
allow)
  need_aws; load; shift
  [ $# -ge 1 ] || fail "allow <ip> [<ip> ...]: one address at least"
  for a in "$@"; do ip_ok "$a" || fail "not one IPv4 address: $a (a range or 0.0.0.0 is never admitted)"; done
  OLD=$(aw ec2 describe-security-groups --group-ids "$RDS_SG" --query 'SecurityGroups[0].IpPermissions' --output json)
  if [ "$OLD" != "[]" ]; then aw ec2 revoke-security-group-ingress --group-id "$RDS_SG" --ip-permissions "$OLD" >/dev/null; fi
  PERM=$(python3 -c 'import json,sys; print(json.dumps([{"IpProtocol":"tcp","FromPort":1433,"ToPort":1433,"IpRanges":[{"CidrIp":a+"/32","Description":"pgvigil proof reader"} for a in sys.argv[1:]]}]))' "$@")
  aw ec2 authorize-security-group-ingress --group-id "$RDS_SG" --ip-permissions "$PERM" >/dev/null
  echo "allowed: $RDS_SG admits tcp 1433 from $(aw ec2 describe-security-groups --group-ids "$RDS_SG" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | tr '\t' ' ') only"
  ;;
logins)
  # runs where 1433 reaches (the reading machine); the passwords go to sqlcmd on stdin, never on its command line
  load
  [ -n "$RDS_HOST" ] || fail "the state file has no endpoint yet (up has not finished)"
  command -v docker >/dev/null || fail "docker is not on this machine (sqlcmd runs from $SQLCMD_IMAGE)"
  export SQLCMDPASSWORD="$ADMIN_PW"
  docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$SQLCMD_IMAGE" -S "tcp:$RDS_HOST,$RDS_PORT" -U "$ADMIN_USER" -d master -C -b -l 60 -h -1 -W -i /dev/stdin <<SQL
SET NOCOUNT ON;
IF SUSER_ID(N'$MON_USER') IS NULL CREATE LOGIN [$MON_USER] WITH PASSWORD = N'$MON_PW', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO [$MON_USER];
GRANT VIEW ANY DEFINITION TO [$MON_USER];
-- the default trace reader (mssql_defaulttrace) needs ALTER TRACE, which the master user holds WITH GRANT OPTION
GRANT ALTER TRACE TO [$MON_USER];
GO
-- no CONNECT ANY DATABASE: the RDS master user does not hold it and cannot grant it (Msg 4613, Grantor does not
-- have GRANT permission); the login gets a user in msdb here and in each database it is to read (the proof makes one)
-- msdb: the master user is in no role there and may not add a member to db_datareader (Msg 15151); it may make a
-- user and grant SELECT on the three Agent tables it holds WITH GRANT OPTION (sysjobs, sysjobhistory, sysjobactivity)
USE msdb;
IF USER_ID(N'$MON_USER') IS NULL CREATE USER [$MON_USER] FOR LOGIN [$MON_USER];
GRANT SELECT ON dbo.sysjobs TO [$MON_USER];
GRANT SELECT ON dbo.sysjobhistory TO [$MON_USER];
GRANT SELECT ON dbo.sysjobactivity TO [$MON_USER];
GO
-- no user in model (which would carry it into every database made later): the master user cannot enter model (Msg 916)
SELECT 'logins: ' + N'$MON_USER' + ' holds ' + STRING_AGG(permission_name, ', ') WITHIN GROUP (ORDER BY permission_name)
FROM sys.server_permissions WHERE grantee_principal_id = SUSER_ID(N'$MON_USER') AND state = 'G';
SELECT 'logins: in msdb SELECT on ' + STRING_AGG(OBJECT_NAME(major_id), ', ') WITHIN GROUP (ORDER BY OBJECT_NAME(major_id))
FROM sys.database_permissions WHERE grantee_principal_id = USER_ID(N'$MON_USER') AND permission_name = 'SELECT' AND state = 'G';
SQL
  ;;
status)
  need_aws
  echo "tag pgvigil-proof=$PGVIGIL_LAB_PROOF:"
  aw rds describe-db-instances --query "DBInstances[?TagList[?Key=='pgvigil-proof' && Value=='$PGVIGIL_LAB_PROOF']].[DBInstanceIdentifier,DBInstanceStatus,DBInstanceClass,Engine,EngineVersion,Endpoint.Address]" --output text | sed 's/^/  rds: /'
  aw ec2 describe-security-groups --filters "Name=tag:pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'SecurityGroups[].[GroupId,GroupName,join(`,`,IpPermissions[].IpRanges[].CidrIp)]' --output text | sed 's/^/  security group: /'
  aw rds describe-db-snapshots --snapshot-type manual --query "DBSnapshots[?starts_with(DBInstanceIdentifier,'pgv-proof-')].[DBSnapshotIdentifier,Status]" --output text | sed 's/^/  manual snapshot: /'
  aw rds describe-db-instance-automated-backups --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier,'pgv-proof-')].[DBInstanceIdentifier,Status]" --output text | sed 's/^/  automated backups: /'
  ;;
down)
  need_aws; load
  ST=$(aw rds describe-db-instances --db-instance-identifier "$RDS_ID" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)
  if [ -n "$ST" ]; then
    # a down cut during its wait finds the instance deleting: it waits again instead of deleting twice
    [ "$ST" = deleting ] || aw rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot --delete-automated-backups --query 'DBInstance.DBInstanceStatus' --output text
    echo "deleting: $RDS_ID (no final snapshot, automated backups deleted); waiting"
    aw rds wait db-instance-deleted --db-instance-identifier "$RDS_ID" || aw rds wait db-instance-deleted --db-instance-identifier "$RDS_ID"
  fi
  # an up cut between the group's create and the state file's line leaves RDS_SG empty: found by its name and tag
  [ -n "$RDS_SG" ] || RDS_SG=$(aw ec2 describe-security-groups --filters "Name=group-name,Values=$RDS_SG_NAME" "Name=tag:pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'SecurityGroups[0].GroupId' --output text)
  [ "$RDS_SG" != None ] || RDS_SG=
  if [ -n "$RDS_SG" ] && aw ec2 describe-security-groups --group-ids "$RDS_SG" >/dev/null 2>&1; then
    # the instance's network interface lets go of the group a little after the instance is gone
    for _ in $(seq 1 30); do aw ec2 delete-security-group --group-id "$RDS_SG" 2>/dev/null && break; sleep 10; done
  fi
  # the listing read back: the instance, the group, anything else that carries the tag, and backups of the instance
  LEFT_DB=$(aw rds describe-db-instances --filters "Name=db-instance-id,Values=$RDS_ID" --query 'length(DBInstances)' --output text)
  LEFT_SG=$(aw ec2 describe-security-groups --filters "Name=tag:pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'length(SecurityGroups)' --output text)
  if [ -n "$RDS_SG" ]; then LEFT_SG=$((LEFT_SG + $(aw ec2 describe-security-groups --filters "Name=group-id,Values=$RDS_SG" --query 'length(SecurityGroups)' --output text))); fi
  # an instance with no automated backups answers DBInstanceAutomatedBackupNotFound: that is 0; any other error stops
  BKERR=$(mktemp)
  if BK=$(aw rds describe-db-instance-automated-backups --db-instance-identifier "$RDS_ID" --query 'length(DBInstanceAutomatedBackups)' --output text 2>"$BKERR"); then LEFT_BK=$BK
  elif grep -q DBInstanceAutomatedBackupNotFound "$BKERR"; then LEFT_BK=0; else fail "the automated backups could not be read: $(cat "$BKERR")"; fi
  rm -f "$BKERR"
  LEFT_SN=$(aw rds describe-db-snapshots --db-instance-identifier "$RDS_ID" --query 'length(DBSnapshots)' --output text)
  LEFT_TAG=$(aw resourcegroupstaggingapi get-resources --tag-filters "Key=pgvigil-proof,Values=$PGVIGIL_LAB_PROOF" --query 'ResourceTagMappingList[].ResourceARN' --output text)
  echo "read back: instances $LEFT_DB, security groups $LEFT_SG, automated backups $LEFT_BK, snapshots $LEFT_SN; tagged resources listed: ${LEFT_TAG:-none}"
  [ "$LEFT_DB|$LEFT_SG|$LEFT_BK|$LEFT_SN" = "0|0|0|0" ] || fail "something is left (above): the state file $STATE stays"
  # the tagging index lags a deletion by minutes: a listed ARN of a resource read as gone above is said, not hidden
  [ -z "$LEFT_TAG" ] || echo "note: the tagging index still lists the ARNs above; the services themselves read 0 (it catches up in minutes)"
  rm -f "$STATE"
  echo "down: 0 left"
  ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
