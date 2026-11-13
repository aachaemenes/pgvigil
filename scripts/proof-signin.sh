#!/usr/bin/env bash
# Proof of SQL Server's sign-ins without a stored password (CLOUDSQL C1), the part a box can prove alone: auth windows
# on a collector that is not Windows, against a SQL Server 2022 container.
#   before (the string auth windows made before C1: no login, no authenticator): go-mssqldb's NTLM default, given no
#     DOMAIN\user, falls back to a SQL login with an empty user - the client reads "Login failed for user ''" and the
#     server's error log gains exactly one such line;
#   after (config.BuildDSN's auth windows now: authenticator=krb5): a krb5 error on the collector (no domain, no
#     keytab here) and NO line in the server's error log: no SQL login was attempted.
# The Entra sign-ins (entra, entra-identity) need an Azure server: their unit rows are internal/mssqlopen's tests.
# Needs docker (pulls mcr.microsoft.com/mssql/server:2022-latest) and go.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvsi-sql-$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
umask 077
TMPD=$(mktemp -d)
SA_PW=$(printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')")
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() { docker rm -f -v "$SQL" >/dev/null 2>&1 || true; rm -rf "$TMPD"; }
trap cleanup EXIT
docker run -d --name "$SQL" --label pgvigil-proof=c1 --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
up=0
for _ in $(seq 1 90); do
  r=$(docker exec --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN DATABASEPROPERTYEX(N'"'"'msdb'"'"', '"'"'Status'"'"') = '"'"'ONLINE'"'"' THEN 1 ELSE 0 END"' 2>/dev/null | tr -d '\r ' || true)
  [[ "$r" == 1 ]] && { up=1; break; }
  sleep 2
done
[[ $up == 1 ]] || fail "the SQL Server container did not come up"
PORT=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
export PGVIGIL_SIGNIN_HOST="127.0.0.1:$PORT"
PGVIGIL_SIGNIN_SA_DSN="sqlserver://sa:$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$SA_PW")@127.0.0.1:$PORT?encrypt=true&TrustServerCertificate=true"
export PGVIGIL_SIGNIN_SA_DSN
out=$(go test -count=1 -run '^TestWindowsOffWindowsLive$' -v ./internal/mssqlopen 2>&1) || { echo "$out"; fail "TestWindowsOffWindowsLive"; }
echo "$out" | grep -E '^(--- |ok)|before:|after:'
grep -q -- '--- PASS: TestWindowsOffWindowsLive' <<<"$out" || { echo "$out"; fail "TestWindowsOffWindowsLive did not pass (skipped?)"; }
echo "OK proof-signin: auth windows off Windows asks Kerberos; no SQL login with an empty user"
