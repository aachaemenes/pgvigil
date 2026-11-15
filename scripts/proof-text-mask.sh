#!/usr/bin/env bash
# Proof of the credential mask on stored statement text (task 415; internal/collect/textpolicy.go): under every
# query_text policy, full included, a credential a running statement carries never reaches the repository. Both
# engines, through `pgvigil collect -once` (RunOnce: the collector, then the text policy, then the import), never a
# unit call: a real SQL Server request caught by the minute requests sample, a real PostgreSQL session caught by the
# activity sample.
#
# Needs: docker, go, psql, pg_dump, and
#   ADMIN_DSN    a superuser connection to a PostgreSQL in KEYWORD form, no dbname given beyond postgres (default
#                'host=127.0.0.1 port=5432 user=postgres dbname=postgres'); the proof makes its own repository
#                database there and drops it. It rides psql's command line: no password in it (PGPASSWORD or
#                ~/.pgpass carries one).
#   MSSQL_IMAGE  the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PG_IMAGE     the monitored PostgreSQL's image (default postgres:16; its contrib holds pgcrypto)
#   PGVIGIL_BIN  a built pgvigil (default: built here from this tree into the proof's temp folder)
# The proof makes, and removes on every exit path: its repository database, one SQL Server container and one
# PostgreSQL container (both its own, throwaway passwords made here), the sessions it starts inside them. It changes
# nothing else.
#
# SQL Server on Linux has no xp_cmdshell, so the sqlcmd command line rides in a string literal of the running
# statement: the statement text the requests sample stores is the same text an xp_cmdshell call would carry.
#
# Expected (written before the first run; the base f8e89d2 is RED on A1, A3, A4, A5 and B1-B6). Part A's way of
# keeping a request running changed after the first three red runs, its expected outcome did not: a CROSS JOIN
# statement holding a passphrase function had its whole text withheld by the server (now A2), and one without it
# finished before the read, so A gave no evidence either way; a request waiting on a lock stays until it is read.
#  A. SQL Server, query_text full (the default): one session runs an UPDATE that waits behind a holder's row lock
#     and carries, in its text,
#     'sqlcmd -S . -U app -P <S1>', the T-SQL doubled-quote form -P''<S3>'' and 'SQLCMDPASSWORD = <S4>' (spaces
#     around =). `collect -once mssql_requests` stores the request (one row of that session with a statement) and a
#     dump of the whole repository holds none of S1, S3, S4 (A1, A3, A4: grep 0 each) and holds '<masked>' in that
#     statement (A5).
#  A2. a second waiting UPDATE carries ENCRYPTBYPASSPHRASE('<S2>', ...): SQL Server itself withholds the
#     text of a batch that calls a passphrase function (sys.dm_exec_sql_text answers no text; first seen in this
#     proof's red run, where it hid the whole statement of the first draft). Expected: its row is stored with no
#     statement and S2 is not in the dump - the server's own redaction, written down so a change of it shows.
#  A6. the same server read as an instance under query_text normalized and one under none: neither stores S1-S4.
#  A7 (the 415 review's fold, written before its first run): the stored statement holds each masked form - '-P <masked>',
#     '-P<masked>' (the doubled-quote form) and 'SQLCMDPASSWORD = <masked>' - so a cut text cannot pass A1-A4 by itself.
#  X (the fold): Extended Events. Before part A the proof sets 'blocked process threshold (s)' to 5 on its container
#     and runs `pgvigil mssql-xe -print` there; part A's two waiting UPDATEs then raise blocked process reports, which
#     hold each blocked session's input buffer. `collect -once mssql_xe` stores them: X1 at least one report of the
#     -P session is stored, and each such report holds '&lt;masked&gt;' and is a well-formed XML document (the join
#     with task 406, written before its first run: the mask writes <masked> escaped inside an XML document - a raw
#     <masked> in an input buffer was an unclosed tag, and the report page could not parse it); the dump checks of
#     A1-A4 then cover the reports too. A
#     report of the passphrase session is written down as the server gives it (the server withheld its text in the
#     requests sample).
#  B. PostgreSQL, query_text full: one session runs SELECT pg_sleep(...) with pgp_sym_encrypt(..., '<P1>'),
#     pgp_sym_decrypt(..., $k$<P2>$k$), encrypt(..., E'<P3>', 'aes'), crypt('<P4>', gen_salt('bf')) and a literal
#     holding '-----BEGIN PGP PRIVATE KEY BLOCK-----' + <P5> + a body longer than track_activity_query_size, so the
#     server cuts the text before -----END. `collect -once activity` stores that session's query and a dump holds
#     none of P1-P5 (B1-B5) and holds '<masked>' (B6).
#  C. nothing else of the statements changes: the SQL Server row keeps its UPDATE text, the PostgreSQL row pg_sleep.
set -u
SUF=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
S1="S3cretA$SUF"; S2="k3yB$SUF"; S3="Sup3rC$SUF"; S4="PwD$SUF"
P1="k3yP$SUF"; P2="dollarQ$SUF"; P3="escE$SUF"; P4="cryptW$SUF"; P5="pgpK$SUF"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
IMG_PG=${PG_IMAGE:-postgres:16}
REPO_DB=pgvigil_mask_$SUF
SQL=pgv-mask-sql-$SUF; PGC=pgv-mask-pg-$SUF
TMPD=$(mktemp -d)
FAILS=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL (setup) $*"; exit 1; }
MADE_DB=
cleanup() {
  rc=$?
  docker rm -f "$SQL" "$PGC" >/dev/null 2>&1
  if [ -n "$MADE_DB" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped"; fi
  rm -rf "$TMPD"
  exit $rc
}
trap cleanup EXIT

BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  go build -o "$TMPD/pgvigil" ./cmd/pgvigil || die "go build"
  BIN=$TMPD/pgvigil
fi

pw() { printf 'Pm9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); MONPW=$(pw); PGPW=$(pw)
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$SAPW"
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nMSSQL_MEMORY_LIMIT_MB=2048\n' "$SAPW" > "$TMPD/sa.env"
docker run -d --name "$SQL" --memory 3g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null || die "docker run $IMG_SQL"
printf 'POSTGRES_PASSWORD=%s\n' "$PGPW" > "$TMPD/pg.env"
docker run -d --name "$PGC" --env-file "$TMPD/pg.env" -p 127.0.0.1::5432 "$IMG_PG" >/dev/null || die "docker run $IMG_PG"
SQLPORT=$(docker port "$SQL" 1433 | head -1 | sed 's/.*://'); PGPORT=$(docker port "$PGC" 5432 | head -1 | sed 's/.*://')
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -b -W -h -1 -Q "SET NOCOUNT ON; $1"; }
# a statement that carries a password goes in through stdin, never on a command line another user can list
sqs() { docker exec -i -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -b -W -h -1 -i /dev/stdin; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || die "SQL Server did not answer"
for _ in $(seq 1 60); do PGPASSWORD=$PGPW psql -h 127.0.0.1 -p "$PGPORT" -U postgres -XAtq -c "select 1" >/dev/null 2>&1 && break; sleep 1; done
pgq() { PGPASSWORD=$PGPW psql -h 127.0.0.1 -p "$PGPORT" -U postgres -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
pgq "select 1" >/dev/null || die "PostgreSQL did not answer"
pgq "create extension if not exists pgcrypto" >/dev/null || die "pgcrypto"

printf "CREATE LOGIN pgv_mask_mon WITH PASSWORD = '%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgv_mask_mon; GRANT VIEW ANY DEFINITION TO pgv_mask_mon;" "$MONPW" | sqs >/dev/null || die "the monitoring login"
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" || die "the repository database"; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export MSSQL_MON_DSN="sqlserver://pgv_mask_mon:$MONPW@127.0.0.1:$SQLPORT?database=master&encrypt=true&TrustServerCertificate=true"
export PG_MON_DSN="host=127.0.0.1 port=$PGPORT user=postgres password=$PGPW dbname=postgres sslmode=disable"
CFG=$TMPD/pgvigil.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: mask-sql-full
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
  - name: mask-sql-norm
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
    query_text: normalized
  - name: mask-sql-none
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
    query_text: none
  - name: mask-pg-full
    dsn: env:PG_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null || die "migrate"
dump() { pg_dump -d "$PGVIGIL_REPO_DSN" --data-only > "$TMPD/dump.sql" 2>/dev/null || die "pg_dump"; }
hits() { grep -c -- "$1" "$TMPD/dump.sql"; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- X0. Extended Events: the blocked process threshold and pgvigil's sessions"
sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'blocked process threshold (s)', 5; RECONFIGURE;" >/dev/null || die "the blocked process threshold"
"$BIN" mssql-xe -print -install-id mask > "$TMPD/xe.sql" || die "mssql-xe -print"
sqs < "$TMPD/xe.sql" > "$TMPD/xe.out" 2>&1 || die "the XE script: $(tail -3 "$TMPD/xe.out")"
echo "--- A. SQL Server: two waiting requests carry four credentials"
# a holder takes a row lock and waits; the two statements that carry the credentials update the same row and wait
# behind it, so each stays a running request with its text for as long as the holder waits (a statement that
# finishes before the read leaves nothing to read). Each carries a subquery so the server does not
# auto-parameterise it (a parameterised form would hold @1 instead of the literals).
MDB=pgvmask_$SUF
sq "CREATE DATABASE [$MDB];" >/dev/null || die "the proof's database"
docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -b -d "$MDB" -Q "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.t VALUES (1, 0);" >/dev/null || die "the proof's table"
docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -d "$MDB" -H "pgvmaskh$SUF" -Q "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:01:30'; ROLLBACK;" > "$TMPD/h.out" 2>&1 &
for _ in $(seq 1 50); do [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name = 'pgvmaskh$SUF' AND open_transaction_count = 1")" = 1 ] && break; sleep 0.2; done
STMT="UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1) AND N'sqlcmd -S . -U app -P $S1 -Q x' <> N'' AND N'sqlcmd -S . -P''$S3'' -Q x' <> N'' AND N'SQLCMDPASSWORD = $S4' <> N''"
STMT2="UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1) AND ENCRYPTBYPASSPHRASE('$S2', N'x') IS NOT NULL"
docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -d "$MDB" -H "pgvmask$SUF" -Q "$STMT" > "$TMPD/a.out" 2>&1 &
docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -d "$MDB" -H "pgvmaskp$SUF" -Q "$STMT2" > "$TMPD/a2.out" 2>&1 &
for _ in $(seq 1 50); do
  [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name IN ('pgvmask$SUF', 'pgvmaskp$SUF') AND r.blocking_session_id > 0")" = 2 ] && break; sleep 0.2
done
SID=$(sq "SELECT TOP (1) session_id FROM sys.dm_exec_sessions WHERE host_name = 'pgvmask$SUF'")
SID2=$(sq "SELECT TOP (1) session_id FROM sys.dm_exec_sessions WHERE host_name = 'pgvmaskp$SUF'")
[ -n "$SID" ] && [ -n "$SID2" ] || die "the SQL Server sessions did not start: $(cat "$TMPD/h.out" "$TMPD/a.out" "$TMPD/a2.out")"
[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id IN ($SID, $SID2) AND blocking_session_id > 0")" = 2 ] || die "the two statements are not waiting behind the holder: $(cat "$TMPD/h.out" "$TMPD/a.out" "$TMPD/a2.out")"
# the blocked process monitor reports every 5 s: two rounds before the read
sleep 12
for inst in mask-sql-full mask-sql-norm mask-sql-none; do
  "$BIN" collect -config "$CFG" -once mssql_requests -instance "$inst" > "$TMPD/c-$inst.out" 2>&1 || bad "A: collect -once mssql_requests on $inst: $(tail -3 "$TMPD/c-$inst.out")"
done
"$BIN" collect -config "$CFG" -once mssql_xe -instance mask-sql-full > "$TMPD/c-xe.out" 2>&1 || bad "X: collect -once mssql_xe: $(tail -3 "$TMPD/c-xe.out")"
dump
for k in 1 3 4; do eval "s=\$S$k"; n=$(hits "$s"); [ "$n" = 0 ] && pass "A$k: secret $k not in the repository" || bad "A$k: secret $k is stored $n time(s) in the repository"; done
A2ROWS=$(q "select count(*) || '|' || count(statement) from pgvigil.mssql_requests_v where instance_id = (select instance_id from pgvigil.instances where name = 'mask-sql-full') and session_id = $SID2")
if [ "$(hits "$S2")" = 0 ] && [ "$A2ROWS" = "1|0" ]; then pass "A2: the passphrase statement: SQL Server withheld its text (row stored, no statement), secret 2 not in the repository"
else bad "A2: the passphrase statement: rows|with text = $A2ROWS (want 1|0), secret 2 stored $(hits "$S2") time(s)"; fi
FULL_ID=$(q "select instance_id from pgvigil.instances where name = 'mask-sql-full'")
ROW=$(q "select count(*) from pgvigil.mssql_requests_v where instance_id = $FULL_ID and statement like 'UPDATE dbo.t%' and statement like '%<masked>%'")
if [ "$ROW" -ge 1 ]; then pass "A5: the request's statement is stored, masked"
else
  bad "A5: no stored statement of the request holds <masked> (rows of the UPDATE: $(q "select count(*) from pgvigil.mssql_requests_v where instance_id = $FULL_ID and statement like 'UPDATE dbo.t%'"))"
  echo "  what each instance stored for session $SID (name | rows | rows with text | the first 120 characters):"
  q "select i.name, count(r.*), count(r.statement), left(max(r.statement), 120) from pgvigil.instances i left join pgvigil.mssql_requests_v r on r.instance_id = i.instance_id and r.session_id = $SID where i.engine = 'sqlserver' group by i.name order by i.name" | sed 's/^/    /'
  echo "  mssql_statement_text rows per instance: $(q "select string_agg(instance_id || ':' || n, ' ') from (select instance_id, count(*) n from pgvigil.mssql_statement_text group by 1) x")"
  for inst in mask-sql-full mask-sql-norm; do echo "  collect $inst:"; tail -5 "$TMPD/c-$inst.out" | sed 's/^/    /'; done
  echo "  the statement's own output: $(cat "$TMPD/a.out")"
fi
N_NORM=$(q "select count(distinct r.instance_id) from pgvigil.mssql_requests_v r join pgvigil.instances i using (instance_id) where i.name in ('mask-sql-norm', 'mask-sql-none') and r.session_id = $SID")
[ "$N_NORM" = 2 ] && pass "A6: normalized and none stored the same request, and the dump holds none of the four" || bad "A6: the request is stored for $N_NORM of the normalized / none instances (want 2)"
STORED=$(q "select statement from pgvigil.mssql_requests_v where instance_id = $FULL_ID and session_id = $SID and statement is not null limit 1")
case "$STORED" in *"-P <masked> -Q"*"-P<masked> -Q"*"SQLCMDPASSWORD = <masked>"*) pass "A7: the stored statement holds the three masked forms" ;;
  *) bad "A7: the stored statement: $STORED" ;; esac
NREP=$(q "select count(*) || '|' || count(*) filter (where report like '%&lt;masked&gt;%' and xml_is_well_formed_document(report)) from pgvigil.mssql_blocked_reports where instance_id = $FULL_ID and report like '%sqlcmd%'")
case "$NREP" in 0\|*) bad "X1: no blocked process report of the -P session stored ($(tail -2 "$TMPD/c-xe.out"))" ;;
  *) [ "${NREP%%|*}" = "${NREP##*|}" ] && pass "X1: the -P session's blocked process reports are stored, masked and well-formed XML ($NREP)" || bad "X1: reports|masked and well-formed = $NREP" ;; esac
echo "  the passphrase session's report as stored: $(q "select coalesce(left(substring(report from 'ENCRYPTBYPASSPHRASE.{0,40}'), 60), '(no report holds the call)') from pgvigil.mssql_blocked_reports where instance_id = $FULL_ID and report like '%ENCRYPTBYPASSPHRASE%' limit 1")"
sq "KILL $SID; KILL $SID2;" >/dev/null 2>&1

echo "--- B. PostgreSQL: a running session carries five credentials"
PAD=$(head -c 1500 /dev/zero | tr '\0' 'x')
PGSTMT="select pg_sleep(40), pgp_sym_encrypt('data', '$P1'), pgp_sym_decrypt(pgp_sym_encrypt('d', \$k\$$P2\$k\$), \$k\$$P2\$k\$) is null, encrypt('data'::bytea, E'$P3'::bytea, 'aes'), crypt('$P4', gen_salt('bf')), length('-----BEGIN PGP PRIVATE KEY BLOCK----- $P5 $PAD -----END PGP PRIVATE KEY BLOCK-----')"
PGPASSWORD=$PGPW psql -h 127.0.0.1 -p "$PGPORT" -U postgres -XAtq -c "$PGSTMT" > "$TMPD/b.out" 2>&1 &
for _ in $(seq 1 50); do [ "$(pgq "select count(*) from pg_stat_activity where query like 'select pg_sleep(40)%'")" = 1 ] && break; sleep 0.2; done
"$BIN" collect -config "$CFG" -once activity -instance mask-pg-full > "$TMPD/c-pg.out" 2>&1 || bad "B: collect -once activity: $(tail -3 "$TMPD/c-pg.out")"
dump
for k in 1 2 3 4 5; do eval "s=\$P$k"; n=$(hits "$s"); [ "$n" = 0 ] && pass "B$k: secret $k not in the repository" || bad "B$k: secret $k is stored $n time(s) in the repository"; done
[ "$(grep -c 'pg_sleep(40).*<masked>' "$TMPD/dump.sql")" -ge 1 ] && pass "B6: the session's query is stored, masked" || bad "B6: no stored query of the session holds <masked> (pg_sleep rows: $(grep -c 'pg_sleep(40)' "$TMPD/dump.sql"))"

echo "--- C. the rest of each statement is kept"
[ "$(q "select count(*) from pgvigil.mssql_requests_v where instance_id = $FULL_ID and statement like 'UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1) AND N''sqlcmd%'")" -ge 1 ] && pass "C1: the SQL Server statement keeps its text" || bad "C1: the SQL Server statement lost its text"
[ "$(grep -c 'select pg_sleep(40), pgp_sym_encrypt' "$TMPD/dump.sql")" -ge 1 ] && pass "C2: the PostgreSQL query keeps its text" || bad "C2: the PostgreSQL query lost its text"

if [ "$FAILS" = 0 ]; then echo "PROOF OK: proof-text-mask (every secret masked under full, both engines)"; exit 0; fi
echo "PROOF FAILED: $FAILS check(s)"; exit 1
