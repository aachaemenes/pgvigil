#!/usr/bin/env bash
# Proof of task B24e: a login's password read from AWS Secrets Manager, on both engines, through a real secret.
# Runs on the machine that holds the AWS sign-in (no credential or token goes to a cloud box: the lab rule of
# 2026-11-14), against a PostgreSQL and a SQL Server it reaches (the cloud box's containers through a tunnel).
#
# Needs: aws (signed in: AWS_PROFILE or the default), psql, docker (sqlcmd from PGVIGIL_SQLCMD_IMAGE), python3, jq,
# unzip, PGVIGIL_BIN (a built pgvigil) or go, and
#   PGVIGIL_ADMIN_DSN     a superuser connection to a PostgreSQL in KEYWORD form, no dbname and NO password (trust,
#                         PGPASSWORD or ~/.pgpass: a password on psql's command line shows in the process list); the
#                         repository is made there, and the proof's login on it is the monitored PostgreSQL
#   PGVIGIL_PROOF_MS      host,port of a SQL Server the machine reaches, with MSSQL_SA_PASSWORD its sa password
#                         (handed to sqlcmd's container through the environment, never its command line)
#   PGVIGIL_PROOF_REGION  the AWS region of the lab secret (us-east-2)
#   PGVIGIL_SQLCMD_NET    optional: the docker network of the sqlcmd client container - 'host' when PGVIGIL_PROOF_MS is
#                         a tunnel on this machine's loopback (a container on the default bridge does not reach it)
#   PGVIGIL_PROOF_PG_LOG  optional: a command that prints the monitored PostgreSQL's server log (e.g. 'ssh box docker
#                         logs pg'); without it S2's PostgreSQL failed-login count is NOT PROVEN
# What it makes, and removes on every exit path it can catch: one secret pgvigil-proof/<n> (restored if a deletion is
# scheduled, then force-deleted, no recovery window: 'no charge for secrets ... marked for deletion'; about USD 0.001
# for the hour), a PostgreSQL role and a SQL login pgvproof_<n>, a repository database pgvigil_secproof_<n>, one
# long-lived collector process (stopped).
#
# Expected (rewritten for the review's fold before any run; red first: on a tree without B24e, password_secret is not
# a field and every connect fails with the login refused):
#  S1 both engines connect through the one JSON secret (username + password; the plain-string shape is the Go case
#     TestGetShapes - one lab secret, not two); the collection ok on each (collect -once).
#  S4 a refusal (collect -once, a fresh cache each run): a resource policy that denies GetSecretValue to the caller,
#     polled until AWS denies it: the collection's error names AccessDeniedException and the secret, the 'password
#     secret unreadable' finding is critical with the object 'AccessDeniedException, <secret>', no 'server
#     unreachable' row and no 'collection failing' streak; the policy removed and polled until allowed: the next
#     connect succeeds and the finding clears.
#  Then ONE long-lived collector (pgvigil run; activity and mssql_instance every 20 s):
#  S3 the bound: in its first 6 minutes the log has at most 2 'password secret read' lines for the secret (one at
#     start, one past 5 minutes) - both instances share one entry.
#  S2 a rotation in the real single-user order, the SQL login with CHECK_POLICY=ON: the database's passwords changed
#     first (ALTER ROLE / ALTER LOGIN), the secret 60 s later: both engines' rows are ok again, each a row stored after
#     the secret's change, within 4 minutes; SQL Server was refused in the window or held without a dial (both
#     instances share one cache entry: the first refusal holds that version for both, so SQL Server's runs may answer
#     LoginRefused from the cache and dial nothing - the lockout guard); SQL Server's error log's failed logins, those more than 15 s after
#     its first (past the burst of connects already dialling) are at most one a minute of the window plus one; the
#     PostgreSQL count the same through PGVIGIL_PROOF_PG_LOG (else NOT PROVEN). The lockout itself is NOT PROVEN
#     (a Windows lockout policy; the box's SQL Server runs on Linux).
#  S5 a revoke: the secret scheduled for deletion while the collector keeps a value: within 6 minutes the rows say
#     'secret: ' with InvalidRequestException (the secret then restored for S6).
#  S6 no leak: the password (it holds @ : / % ; } and a quote) appears - raw, URL-escaped (Python's and Go's userinfo
#     forms) or libpq-quoted - in none of the collector's output, the repository's collection notes, the findings,
#     the actions audit table, nor a report zip. NOT PROVEN here: the page's one-off connects (Cancel / Terminate,
#     EXPLAIN, Hypo, the advisor, the Test) need serve with a signed-in user: Go cases (TestFillPG, TestMSLogin).
set -Eeuo pipefail
trap 'echo "STOPPED: line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname, no password}"
: "${PGVIGIL_PROOF_MS:?host,port of a SQL Server}" "${MSSQL_SA_PASSWORD:?the sa password of that SQL Server}"
case " $PGVIGIL_ADMIN_DSN" in *" password="* | *" password ="*) echo "FAIL: PGVIGIL_ADMIN_DSN carries a password: use PGPASSWORD or ~/.pgpass (a command line shows in ps)" >&2; exit 1 ;; esac
REGION=${PGVIGIL_PROOF_REGION:-us-east-2}
IMG=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
for t in aws psql docker python3 jq unzip; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
SECRET=pgvigil-proof/$SUF; LOGIN=pgvproof_$SUF; REPO_DB=pgvigil_secproof_$SUF
pw() { printf "Pv9@:/%%;}'%s" "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PW1=$(pw); PW2=$(pw)
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/collector.out; : > "$OUT"
MADE_SECRET=; MADE_ROLE=; MADE_LOGIN=; MADE_DB=; RUN_PID=
FAILS=(); NOTPROVEN=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
# sqlcmd reads its password from SQLCMDPASSWORD in the environment (docker -e NAME passes it on without a value)
ms() { docker run --rm -i ${PGVIGIL_SQLCMD_NET:+--network "$PGVIGIL_SQLCMD_NET"} -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$PGVIGIL_PROOF_MS" -U sa -C -b -h -1 -W -i /dev/stdin <<<"SET NOCOUNT ON; $1"; }
sqlq() { python3 -c 'import sys; print("N\x27" + sys.argv[1].replace("\x27", "\x27\x27") + "\x27")' "$1"; }
pgq() { python3 -c 'import sys; print("\x27" + sys.argv[1].replace("\x27", "\x27\x27") + "\x27")' "$1"; }
# SQL that carries a password goes through stdin, never psql's command line
padmin() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -f - <<<"$1"; }
secretjson() { PW=$1 jq -n --arg u "$LOGIN" '{engine:"postgres",username:$u,password:env.PW}'; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  echo "cleanup (exit $rc): the collector, the secret, the logins, the repository"
  if [ "$rc" != 0 ] && [ -n "$MADE_DB" ] && [ -n "${TA:-}" ]; then
    echo "  the S2 window's collection_log rows (both instances):"
    q "SELECT to_char(l.snapshot_at, 'HH24:MI:SS') || ' ' || i.name || ' ' || l.collection || ' ' || l.status || ' ' || left(coalesce(l.note, ''), 160) FROM pgvigil.collection_log l JOIN pgvigil.instances i USING (instance_id) WHERE l.snapshot_at >= to_timestamp($TA) - interval '30 seconds' ORDER BY l.snapshot_at" 2>&1 | sed 's/^/    /' | head -60
    echo "  the collector's lines naming the secret or a refusal since the window:"
    grep -E 'secret|refused|28P01|18456|Login failed' "$OUT" 2>/dev/null | tail -40 | cut -c1-220 | sed 's/^/    /'
  fi
  [ -n "$RUN_PID" ] && kill "$RUN_PID" 2>/dev/null && wait "$RUN_PID" 2>/dev/null
  if [ -n "$MADE_SECRET" ]; then
    aws secretsmanager restore-secret --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1 # a deletion scheduled in S5: restored first
    aws secretsmanager delete-secret --region "$REGION" --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 \
      && echo "LAB GONE: the secret $SECRET force-deleted (read back: $(g=; for _ in $(seq 1 12); do e=$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" 2>&1 >/dev/null) || { case $e in *ResourceNotFoundException*) g=gone ;; *) g="the read-back failed: ${e:0:160}" ;; esac; break; }; sleep 5; done; echo "${g:-STILL THERE after 60 s}"))" \
      || echo "CLEANUP: the secret $SECRET was NOT deleted" >&2
  fi
  [ -n "$MADE_ROLE" ] && padmin "drop role if exists $LOGIN" >/dev/null 2>&1
  [ -n "$MADE_LOGIN" ] && ms "IF SUSER_ID(N'$LOGIN') IS NOT NULL DROP LOGIN [$LOGIN];" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && padmin "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi

echo "--- the logins and the secret"
padmin "create role $LOGIN login password $(pgq "$PW1")" >/dev/null; MADE_ROLE=1
ms "CREATE LOGIN [$LOGIN] WITH PASSWORD = $(sqlq "$PW1"), CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; ALTER SERVER ROLE ##MS_ServerStateReader## ADD MEMBER [$LOGIN];" >/dev/null 2>&1 \
  || ms "CREATE LOGIN [$LOGIN] WITH PASSWORD = $(sqlq "$PW1"), CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; GRANT VIEW SERVER STATE TO [$LOGIN];" >/dev/null; MADE_LOGIN=1
( umask 077; secretjson "$PW1" > "$WORK/s1.json" )
aws secretsmanager create-secret --region "$REGION" --name "$SECRET" --secret-string "file://$WORK/s1.json" --tags Key=pgvigil-proof,Value="$SUF" >/dev/null; MADE_SECRET=1
rm -f "$WORK/s1.json"
echo "LAB START: secret $SECRET in $REGION (tag pgvigil-proof=$SUF), about USD 0.001 for the hour"
padmin "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
PGHOSTPART=$(sed -E 's/(^| )user=[^ ]*//' <<<"$PGVIGIL_ADMIN_DSN")
IFS=, read -r MSH MSP <<<"$PGVIGIL_PROOF_MS"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: sec-pg-$SUF
    dsn: "$PGHOSTPART user=$LOGIN dbname=postgres"
    password_secret: {ref: "aws-secretsmanager:$SECRET", region: $REGION}
    schedules: {activity: 20s}
  - name: sec-ms-$SUF
    engine: sqlserver
    dsn: "sqlserver://$LOGIN@$MSH:$MSP?database=master&encrypt=true&TrustServerCertificate=true"
    password_secret: {ref: "aws-secretsmanager:$SECRET", region: $REGION}
    schedules: {mssql_instance: 20s}
EOF
"$BIN" migrate -config "$CFG" >/dev/null
once() { "$BIN" collect -config "$CFG" -once "$2" -instance "$1" >> "$OUT" 2>&1 || true; }
status() { q "SELECT d.status || '|' || coalesce(d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.collection = '$2'"; }
# wait_for <seconds> <instance> <collection> <glob>: polls the row until it matches the glob or the time is up
wait_for() { local end=$(( $(date +%s) + $1 )) v; while :; do v=$(status "$2" "$3"); [[ $v == $4 ]] && { echo "$v"; return 0; }; [ "$(date +%s)" -ge "$end" ] && { echo "$v"; return 1; }; sleep 5; done; }
# fresh <instance> <collection> <epoch>: the row's status and note when it was stored after <epoch>, else 'stale|...'
fresh() { q "SELECT CASE WHEN d.snapshot_at > to_timestamp($3) THEN d.status || '|' || coalesce(d.note, '') ELSE 'stale|' || d.status || ' at ' || to_char(d.snapshot_at, 'HH24:MI:SS') END FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.collection = '$2'"; }
# wait_fresh <seconds> <instance> <collection> <epoch>: polls until the row is ok and newer than <epoch>, or the time is up
wait_fresh() { local end=$(( $(date +%s) + $1 )) v; while :; do v=$(fresh "$2" "$3" "$4"); [[ $v == ok* ]] && { echo "$v"; return 0; }; [ "$(date +%s)" -ge "$end" ] && { echo "$v"; return 1; }; sleep 5; done; }

echo "--- S1 both engines through the secret"
once "sec-pg-$SUF" activity; once "sec-ms-$SUF" mssql_instance
S1P=$(status "sec-pg-$SUF" activity); S1M=$(status "sec-ms-$SUF" mssql_instance)
echo "  PostgreSQL: $S1P; SQL Server: $S1M"
[[ $S1P == ok* && $S1M == ok* ]] && echo "S1: OK" || bad "S1: '$S1P' '$S1M' (want ok on both)"

echo "--- S4 a refusal: a resource policy denying GetSecretValue to this caller"
ARN=$(aws sts get-caller-identity --query Arn --output text)
jq -n --arg a "$ARN" '{Version:"2012-10-17",Statement:[{Effect:"Deny",Principal:{AWS:$a},Action:"secretsmanager:GetSecretValue",Resource:"*"}]}' > "$WORK/deny.json"
aws secretsmanager put-resource-policy --region "$REGION" --secret-id "$SECRET" --resource-policy "file://$WORK/deny.json" >/dev/null
for _ in $(seq 1 12); do aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1 || break; sleep 5; done
once "sec-pg-$SUF" activity; D1=$(status "sec-pg-$SUF" activity)
F1=$(q "SELECT severity || '|' || object FROM pgvigil.secret_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-pg-$SUF'")
U1=$(q "SELECT count(*) FROM pgvigil.findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-pg-$SUF' AND (f.setting ILIKE '%unreachable%' OR f.setting ILIKE '%collection failing%')")
aws secretsmanager delete-resource-policy --region "$REGION" --secret-id "$SECRET" >/dev/null
for _ in $(seq 1 12); do aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1 && break; sleep 5; done
once "sec-pg-$SUF" activity; D2=$(status "sec-pg-$SUF" activity)
F2=$(q "SELECT count(*) FROM pgvigil.secret_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-pg-$SUF'")
echo "  denied: $D1 (finding $F1, unreachable / failing rows $U1); allowed again: $D2 (findings $F2)"
[[ $D1 == "error|secret: "*AccessDeniedException*"$SECRET"* && $F1 == "critical|AccessDeniedException, $SECRET" && $U1 == 0 && $D2 == ok* && $F2 == 0 ]] && echo "S4: OK" \
  || bad "S4: '$D1' '$F1' '$U1' then '$D2' '$F2'"

echo "--- one long-lived collector"
L0=$(wc -l < "$OUT")
"$BIN" run -config "$CFG" >> "$OUT" 2>&1 &
RUN_PID=$!

echo "--- S3 the bound: 6 minutes, at most 2 reads"
sleep 360
READS=$(tail -n +"$((L0 + 1))" "$OUT" | grep -c "password secret read.*secret=$SECRET" || true)
echo "  'password secret read' lines in 6 minutes: $READS"
[ "$READS" -ge 1 ] && [ "$READS" -le 2 ] && echo "S3: OK" || bad "S3: $READS reads in 6 minutes (want 1 or 2)"

echo "--- S2 a rotation (the database first, the secret 60 s later)"
T0=$(ms "SELECT CONVERT(varchar(23), SYSDATETIME(), 121);" | tr -d '\r')
pgfails() { bash -c "$PGVIGIL_PROOF_PG_LOG" 2>&1 | grep -c "password authentication failed for user \"$LOGIN\"" || true; }
PGL0=0; [ -n "${PGVIGIL_PROOF_PG_LOG:-}" ] && PGL0=$(pgfails)
TA=$(date +%s)
padmin "alter role $LOGIN password $(pgq "$PW2")" >/dev/null
ms "ALTER LOGIN [$LOGIN] WITH PASSWORD = $(sqlq "$PW2");" >/dev/null
sleep 60
( umask 077; secretjson "$PW2" > "$WORK/s2.json" )
aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" --secret-string "file://$WORK/s2.json" >/dev/null; rm -f "$WORK/s2.json"
TS=$(date +%s)
sleep 25 # past the 20 s rows of the window
R2=$(wait_fresh 240 "sec-pg-$SUF" activity "$TS") || true
R3=$(wait_fresh 60 "sec-ms-$SUF" mssql_instance "$TS") || true
echo "  after the secret's change ($(( $(date +%s) - TS )) s): PostgreSQL $R2, SQL Server $R3"
[[ $R2 == ok* && $R3 == ok* ]] && echo "S2 rows: OK" || bad "S2: '$R2' / '$R3' (want ok on both, each stored after the secret's change, within 4 minutes of it)"
MSF=$(ms "CREATE TABLE #pv_el (LogDate datetime, ProcessInfo nvarchar(64), Text nvarchar(max));
INSERT #pv_el EXEC sp_readerrorlog 0, 1, N'Login failed for user ''$LOGIN''';
DECLARE @t0 datetime = '$T0', @first datetime;
SELECT @first = MIN(LogDate) FROM #pv_el WHERE LogDate >= @t0;
SELECT CONCAT(COUNT(*), ',', SUM(CASE WHEN LogDate > DATEADD(second, 15, @first) THEN 1 ELSE 0 END), ',', ISNULL(DATEDIFF(second, @first, MAX(LogDate)), 0)) FROM #pv_el WHERE LogDate >= @t0;" | tr -d '\r' | tail -1)
IFS=, read -r MS_ALL MS_AFTER MS_SPAN <<<"$MSF"
MS_BOUND=$(( MS_SPAN / 60 + 2 ))
# held: SQL Server runs of the window answered LoginRefused from the shared cache entry (no dial, no error-log line)
HELD=$(q "SELECT count(*) FROM pgvigil.collection_log l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sec-ms-$SUF' AND l.snapshot_at >= to_timestamp($TA) AND l.snapshot_at <= to_timestamp($TS) AND l.note LIKE 'secret: %LoginRefused%'") || true
echo "  SQL Server failed logins in the window: ${MS_ALL:-?} (after the first 15 s: ${MS_AFTER:-0} over ${MS_SPAN:-0}s; bound $MS_BOUND); SQL Server runs held without a dial: ${HELD:-?}"
[ $(( ${MS_ALL:-0} + ${HELD:-0} )) -ge 1 ] && [ "${MS_AFTER:-0}" -le "$MS_BOUND" ] && echo "S2 SQL Server count: OK" || bad "S2: SQL Server's failed logins '$MSF', held '${HELD:-}' (want refused or held at least once, and at most $MS_BOUND refused past the first 15 s)"
if [ -n "${PGVIGIL_PROOF_PG_LOG:-}" ]; then
  PGL1=$(pgfails)
  echo "  PostgreSQL failed logins in the window: $(( PGL1 - PGL0 )) (the log's lines carry no time here: the total, bound $(( ( $(date +%s) - TS + 60 ) / 60 + 1 )) plus the burst)"
  NOTPROVEN+=("S2: PostgreSQL's failed logins are counted in total, not split from the burst (no time on the lines read)")
else
  NOTPROVEN+=("S2: PostgreSQL's failed logins a minute (no PGVIGIL_PROOF_PG_LOG)")
fi
NOTPROVEN+=("S2: the lockout itself (a Windows lockout policy; the box's SQL Server runs on Linux) - the failed-login count stands for it")

echo "--- S5 a revoke: the secret scheduled for deletion"
aws secretsmanager delete-secret --region "$REGION" --secret-id "$SECRET" --recovery-window-in-days 7 >/dev/null
V1=$(wait_for 360 "sec-pg-$SUF" activity "error|secret: *InvalidRequest*") || true
aws secretsmanager restore-secret --region "$REGION" --secret-id "$SECRET" >/dev/null
echo "  after the deletion was scheduled: $V1"
[[ $V1 == "error|secret: "*InvalidRequest* ]] && echo "S5: OK" || bad "S5: '$V1' (want InvalidRequestException within 6 minutes)"
kill "$RUN_PID" 2>/dev/null || true; wait "$RUN_PID" 2>/dev/null || true; RUN_PID=

echo "--- S6 no leak"
"$BIN" report -config "$CFG" -out "$WORK/report.zip" >/dev/null 2>&1 || bad "S6: the report zip was not written"
[ -f "$WORK/report.zip" ] && unzip -p "$WORK/report.zip" > "$WORK/report.txt" 2>/dev/null || : > "$WORK/report.txt"
q "SELECT coalesce(note, '') FROM pgvigil.collection_log" > "$WORK/notes.txt"
q "SELECT coalesce(detail, '') || ' ' || coalesce(value, '') FROM pgvigil.findings" > "$WORK/findings.txt"
q "SELECT coalesce(detail, '') || ' ' || coalesce(object, '') FROM pgvigil.secret_findings" >> "$WORK/findings.txt"
q "SELECT coalesce(detail, '') FROM pgvigil.actions_log" > "$WORK/audit.txt"
LEAK=0
for p in "$PW1" "$PW2"; do
  for form in "$p" \
    "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$p")" \
    "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="$&+,;="))' "$p")" \
    "$(python3 -c 'import sys; print("\x27" + sys.argv[1].replace("\\", "\\\\").replace("\x27", "\\\x27") + "\x27")' "$p")"; do
    for f in "$OUT" "$WORK/notes.txt" "$WORK/findings.txt" "$WORK/audit.txt" "$WORK/report.txt"; do
      grep -qF -- "$form" "$f" && { LEAK=$((LEAK + 1)); echo "  the password (a form of it) in $(basename "$f")"; }
    done
  done
done
[ "$LEAK" = 0 ] && echo "S6: OK" || bad "S6: the password appears $LEAK time(s)"
NOTPROVEN+=("S6: the page's one-off connects (Cancel / Terminate, EXPLAIN, Hypo, the advisor, the Test) - serve with a signed-in user; Go cases TestFillPG, TestMSLogin")

echo "=== NOT PROVEN: ${NOTPROVEN[*]:-none}"
if [ ${#FAILS[@]} -eq 0 ]; then echo "=== proof-secrets: PASS"; else printf '=== proof-secrets: FAIL (%s)\n' "${#FAILS[@]}"; printf '  %s\n' "${FAILS[@]}"; exit 1; fi
