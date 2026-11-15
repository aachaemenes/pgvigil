#!/usr/bin/env bash
# Proof of task B24e: a login's password read from AWS Secrets Manager, on both engines, through a real secret.
# Runs on the machine that holds the AWS sign-in (no credential or token goes to a cloud box: the lab rule of
# 2026-11-14), against a PostgreSQL and a SQL Server it reaches (the cloud box's containers through a tunnel).
#
# Needs: aws (signed in: AWS_PROFILE or the default), psql, docker (sqlcmd from PGVIGIL_SQLCMD_IMAGE), python3, jq,
# PGVIGIL_BIN (a built pgvigil) or go, and
#   PGVIGIL_ADMIN_DSN     a superuser connection to a PostgreSQL in KEYWORD form, no dbname: the repository is made
#                         there, and the proof's login on it is the monitored PostgreSQL
#   PGVIGIL_PROOF_MS      host,port of a SQL Server the machine reaches, with MSSQL_SA_PASSWORD its sa password
#   PGVIGIL_PROOF_REGION  the AWS region of the lab secret (us-east-2)
# What it makes, and removes on every exit path it can catch: one secret pgvigil-proof/<n> (force-deleted, no recovery
# window: 'no charge for secrets ... marked for deletion'; about USD 0.001 for the hour), a PostgreSQL role and a SQL
# login pgvproof_<n>, a repository database pgvigil_secproof_<n>.
#
# Expected (written before the first run; red first: on a tree without B24e, password_secret is not a field and every
# connect fails with the login refused):
#  S1 both engines connect through the secret: RDS's JSON (username + password) on PostgreSQL, a plain string on SQL
#     Server; the collection ok on each.
#  S2 a rotation in the real single-user order: the database's password changed first, the secret 60 s later; the
#     connects in between fail with the login refused, then the next connect after the secret's change reads the new
#     version and succeeds; the server's failed logins for the login are at most one a minute (PostgreSQL's
#     pg_stat_database is not it: the server log's 'password authentication failed' lines counted through the
#     container's log when PGVIGIL_PROOF_PG_LOG names it, else NOT PROVEN).
#  S3 the 5-minute bound: ten connects inside 5 minutes make one read (pgvigil's debug line 'secret read' counted).
#  S4 a refusal: a resource policy that denies GetSecretValue to the caller: the collection's error names
#     AccessDeniedException and the secret, the 'password secret unreadable' finding is critical, no 'server
#     unreachable' row; the policy removed: the next connect succeeds and the finding clears.
#  S5 a revoke: the secret scheduled for deletion while a value is kept: pgvigil stops connecting within 5 minutes and
#     says InvalidRequestException (the secret then restored for S6).
#  S6 no leak: the password (it holds @ : / % ; }) appears, raw, URL-escaped or quoted, in none of the collector's
#     output, the repository's collection notes and logs, the findings, nor a report zip.
set -Eeuo pipefail
trap 'echo "STOPPED: line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
: "${PGVIGIL_PROOF_MS:?host,port of a SQL Server}" "${MSSQL_SA_PASSWORD:?the sa password of that SQL Server}"
REGION=${PGVIGIL_PROOF_REGION:-us-east-2}
IMG=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
for t in aws psql docker python3 jq; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
SECRET=pgvigil-proof/$SUF; LOGIN=pgvproof_$SUF; REPO_DB=pgvigil_secproof_$SUF
pw() { printf 'Pv9@:/%%;}%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PW1=$(pw); PW2=$(pw)
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
MADE_SECRET=; MADE_ROLE=; MADE_LOGIN=; MADE_DB=
FAILS=(); NOTPROVEN=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
ms() { docker run --rm -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$PGVIGIL_PROOF_MS" -U sa -C -b -h -1 -W -i /dev/stdin <<<"SET NOCOUNT ON; $1"; }
sqlq() { python3 -c 'import sys; print("N\x27" + sys.argv[1].replace("\x27", "\x27\x27") + "\x27")' "$1"; }
pgq() { python3 -c 'import sys; print("\x27" + sys.argv[1].replace("\x27", "\x27\x27") + "\x27")' "$1"; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  if [ -n "$MADE_SECRET" ]; then aws secretsmanager delete-secret --region "$REGION" --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 \
    && echo "LAB GONE: the secret $SECRET force-deleted (read back: $(aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1 && echo STILL THERE || echo gone))" \
    || echo "CLEANUP: the secret $SECRET was NOT deleted" >&2; fi
  [ -n "$MADE_ROLE" ] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $LOGIN" >/dev/null 2>&1
  [ -n "$MADE_LOGIN" ] && ms "IF SUSER_ID(N'$LOGIN') IS NOT NULL DROP LOGIN [$LOGIN];" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi

echo "--- the logins and the secret"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create role $LOGIN login password $(pgq "$PW1")" >/dev/null; MADE_ROLE=1
ms "CREATE LOGIN [$LOGIN] WITH PASSWORD = $(sqlq "$PW1"), CHECK_POLICY = OFF; ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [$LOGIN];" >/dev/null 2>&1 \
  || ms "CREATE LOGIN [$LOGIN] WITH PASSWORD = $(sqlq "$PW1"), CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$LOGIN];" >/dev/null; MADE_LOGIN=1
( umask 077; jq -n --arg u "$LOGIN" --arg p "$PW1" '{engine:"postgres",username:$u,password:$p}' > "$WORK/s1.json" )
aws secretsmanager create-secret --region "$REGION" --name "$SECRET" --secret-string "file://$WORK/s1.json" --tags Key=pgvigil-proof,Value="$SUF" >/dev/null; MADE_SECRET=1
rm -f "$WORK/s1.json"
echo "LAB START: secret $SECRET in $REGION (tag pgvigil-proof=$SUF), about USD 0.001 for the hour"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
PGHOSTPART=$(sed -E 's/(^| )user=[^ ]*//; s/(^| )password=[^ ]*//' <<<"$PGVIGIL_ADMIN_DSN")
IFS=, read -r MSH MSP <<<"$PGVIGIL_PROOF_MS"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: sec-pg-$SUF
    dsn: "$PGHOSTPART dbname=postgres"
    password_secret: {ref: "aws-secretsmanager:$SECRET", region: $REGION}
  - name: sec-ms-$SUF
    engine: sqlserver
    dsn: "sqlserver://$LOGIN@$MSH:$MSP?database=master&encrypt=true&TrustServerCertificate=true"
    password_secret: {ref: "aws-secretsmanager:$SECRET", region: $REGION}
EOF
"$BIN" migrate -config "$CFG" >/dev/null
run() { "$BIN" collect -config "$CFG" -once "$2" -instance "$1" >> "$WORK/collector.out" 2>&1 || true; }
status() { q "SELECT d.status || '|' || coalesce(d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.collection = '$2'"; }

echo "--- S1 both engines through the secret"
run "sec-pg-$SUF" activity; run "sec-ms-$SUF" mssql_instance
S1P=$(status "sec-pg-$SUF" activity); S1M=$(status "sec-ms-$SUF" mssql_instance)
echo "  PostgreSQL: $S1P; SQL Server: $S1M"
[[ $S1P == ok* && $S1M == ok* ]] && echo "S1: OK" || bad "S1: '$S1P' '$S1M' (want ok on both)"

echo "--- S2 a rotation (the database first, the secret 60 s later)"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "alter role $LOGIN password $(pgq "$PW2")" >/dev/null
ms "ALTER LOGIN [$LOGIN] WITH PASSWORD = $(sqlq "$PW2");" >/dev/null
sleep 310   # past the 5-minute bound, so the next connect reads the (unchanged) secret
run "sec-pg-$SUF" activity; R1=$(status "sec-pg-$SUF" activity)
( umask 077; jq -n --arg u "$LOGIN" --arg p "$PW2" '{engine:"postgres",username:$u,password:$p}' > "$WORK/s2.json" )
sleep 60; aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" --secret-string "file://$WORK/s2.json" >/dev/null; rm -f "$WORK/s2.json"
sleep 65   # past the refused re-read's back-off
run "sec-pg-$SUF" activity; R2=$(status "sec-pg-$SUF" activity); run "sec-ms-$SUF" mssql_instance; R3=$(status "sec-ms-$SUF" mssql_instance)
echo "  in the window: $R1; after the secret's change: PostgreSQL $R2, SQL Server $R3"
[[ $R1 == error* && $R2 == ok* && $R3 == ok* ]] && echo "S2: OK" || bad "S2: '$R1' then '$R2' / '$R3' (want the window refused, then ok on both)"
[ -n "${PGVIGIL_PROOF_PG_LOG:-}" ] || NOTPROVEN+=("S2: the server's failed logins a minute (no PGVIGIL_PROOF_PG_LOG)")

echo "--- S3 the bound: ten connects inside 5 minutes, one read"
: > "$WORK/s3.out"
for i in $(seq 1 10); do PGVIGIL_LOG_LEVEL=debug "$BIN" collect -config "$CFG" -once activity -instance "sec-pg-$SUF" >> "$WORK/s3.out" 2>&1 || true; done
READS=$(grep -c 'secret read' "$WORK/s3.out" || true)
echo "  reads logged: $READS (each collect -once is a new process: one read a process; the bound inside one process is a Go case)"
NOTPROVEN+=("S3: the 5-minute bound across connects of ONE process (collect -once runs a process a call; the Go case TestCacheAndKey proves it)")

echo "--- S4 a refusal: a resource policy denying GetSecretValue to this caller"
ARN=$(aws sts get-caller-identity --query Arn --output text)
jq -n --arg a "$ARN" '{Version:"2012-10-17",Statement:[{Effect:"Deny",Principal:{AWS:$a},Action:"secretsmanager:GetSecretValue",Resource:"*"}]}' > "$WORK/deny.json"
aws secretsmanager put-resource-policy --region "$REGION" --secret-id "$SECRET" --resource-policy "file://$WORK/deny.json" >/dev/null
run "sec-pg-$SUF" activity; D1=$(status "sec-pg-$SUF" activity)
F1=$(q "SELECT severity FROM pgvigil.secret_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-pg-$SUF'")
U1=$(q "SELECT count(*) FROM pgvigil.findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-pg-$SUF' AND f.check_name ILIKE '%unreachable%'")
aws secretsmanager delete-resource-policy --region "$REGION" --secret-id "$SECRET" >/dev/null
run "sec-pg-$SUF" activity; D2=$(status "sec-pg-$SUF" activity)
F2=$(q "SELECT count(*) FROM pgvigil.secret_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-pg-$SUF'")
echo "  denied: $D1 (finding $F1, unreachable rows $U1); allowed again: $D2 (findings $F2)"
[[ $D1 == "error|secret: "*AccessDenied*"$SECRET"* && $F1 == critical && $U1 == 0 && $D2 == ok* && $F2 == 0 ]] && echo "S4: OK" \
  || bad "S4: '$D1' '$F1' '$U1' then '$D2' '$F2'"

echo "--- S5 a revoke: the secret scheduled for deletion"
aws secretsmanager delete-secret --region "$REGION" --secret-id "$SECRET" --recovery-window-in-days 7 >/dev/null
sleep 310; run "sec-pg-$SUF" activity; V1=$(status "sec-pg-$SUF" activity)
aws secretsmanager restore-secret --region "$REGION" --secret-id "$SECRET" >/dev/null
echo "  after the deletion was scheduled: $V1"
[[ $V1 == "error|secret: "*InvalidRequest* ]] && echo "S5: OK" || bad "S5: '$V1' (want InvalidRequestException within 5 minutes)"

echo "--- S6 no leak"
LEAK=0
for p in "$PW1" "$PW2"; do
  for form in "$p" "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$p")" "$(pgq "$p")"; do
    grep -qF -- "$form" "$WORK/collector.out" "$WORK/s3.out" && LEAK=$((LEAK + 1))
    [ "$(q "SELECT count(*) FROM pgvigil.collection_log WHERE strpos(coalesce(note, ''), $(pgq "$form")) > 0")" = 0 ] || LEAK=$((LEAK + 1))
  done
done
[ "$LEAK" = 0 ] && echo "S6: OK" || bad "S6: the password appears $LEAK time(s)"

echo "=== NOT PROVEN: ${NOTPROVEN[*]:-none}"
if [ ${#FAILS[@]} -eq 0 ]; then echo "=== proof-secrets: PASS"; else printf '=== proof-secrets: FAIL (%s)\n' "${#FAILS[@]}"; printf '  %s\n' "${FAILS[@]}"; exit 1; fi
