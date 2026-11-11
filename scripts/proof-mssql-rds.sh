#!/usr/bin/env bash
# Proof of pgvigil's SQL Server engine on Amazon RDS for SQL Server: the platform and the engine edition are
# detected, every SQL Server collection either stores what the setup login (the RDS master user) reads from the same
# view or is skipped by a rule that says so, the instance's pages render, and the collector creates nothing on the
# monitored server.
#
# Needs, on the machine that reads the instance (its address admitted by the instance's security group): docker
# (sqlcmd runs from PGVIGIL_SQLCMD_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest; nothing is installed),
# psql, curl, jq, python3, chromium (the pages), a go toolchain at the repository root unless PGVIGIL_BIN names a
# built binary, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the repository is made there)
#   PGVIGIL_LAB_STATE   the lab's state file, default .lab/aws-rds-mssql.env (scripts/lab/aws-rds-mssql.sh up, allow,
#                       logins): the endpoint, the master user (the setup login) and the collector's login, with their
#                       passwords. Passwords reach sqlcmd and the collector through the environment by name; none is
#                       printed.
# Settings: PGVIGIL_SKIP_PAGES=1 leaves out part C (said as NOT RUN, and the verdict is then not PASS).
#
# What it makes, as the server's DBA would, and removes on every exit path the shell can catch: a repository
# database pgvigil_rdsproof_<n> on the PostgreSQL; on the instance a database pgvproof_<n> (AUTO_CLOSE off, Query Store on, one
# table, one procedure called five times just before the procedure read, one row lock wait between two sessions of the master user, a user there
# for the collector's login) and the four
# Extended Events sessions of `pgvigil mssql-xe -print -form server -install-id p<n>` (dropped by the -drop script);
# one session of the master user that waits two minutes (part B's requests read).
#
# Expected (written before the first run):
#  R. the rights: the collector's login holds exactly VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE
#     (and CONNECT SQL) at the server and db_datareader in msdb, is no sysadmin (docs/sqlserver.md's login).
#     [Run 2 graded FAIL: the RDS master user holds no CONNECT ANY DATABASE and cannot grant it (Msg 4613, Grantor
#      does not have GRANT permission; its own grantable rights hold VIEW SERVER STATE and VIEW ANY DEFINITION). The
#      login of docs/sqlserver.md cannot be made on RDS. Run 3: neither can its msdb part - the master user is in no
#      msdb role and may not add a member to db_datareader (Msg 15151); in msdb it may make a user and grant SELECT
#      on sysjobs, sysjobhistory and sysjobactivity only. From run 4 R checks the RDS form of the login
#      (docs/sqlserver-cloud.md): CONNECT SQL, VIEW ANY DEFINITION, VIEW SERVER STATE at the server, no sysadmin, a
#      user in msdb with SELECT on those three tables, and a user in each database it reads (here the proof's
#      database, made with it); what the collections cannot read with it shows in B as their own status.]
#  A. detection: `collect -once mssql_instance` stores the instance as engine sqlserver, platform rdssqlserver,
#     server_version_num = major * 10000 + minor of the master user's ProductVersion; mssql_instance holds that
#     ProductVersion, Edition (Express Edition (64-bit)), EngineEdition 4 and server name.
#  B. each of the 21 SQL Server collections (the list is checked against internal/mssql's Name() functions), status
#     ok and never partial, with rows equal to the master user's read of the same view:
#       mssql_instance     sys.configurations' row count and 'max server memory (MB)'; sysinfo_read, cpu_count
#       mssql_services     the services' names and states of sys.dm_server_services; Agent not expected (Express)
#       mssql_requests     the master user's session waiting on WAITFOR: session id, command, wait type
#       mssql_waits        sys.dm_os_wait_stats bracketed by a read just before and just after the run
#       mssql_xe           one state per capture equal to sys.server_event_sessions / sys.dm_xe_sessions for
#                          pgvigil_p<n>_<capture>: running for all four once the -form server script ran
#                          [Run 7: RDS refuses the script's sessions on Express (rds_extended_events_trigger: "RDS for
#                           SQL Server supports extended events only for the Enterprise and Standard editions"). On
#                           that refusal the captures must read 'not installed', equal to the master user's read,
#                           and 'running' is said NOT PROVEN (Express); any other failure of the script is a FAIL.]
#       mssql_mirroring    as many databases as sys.database_mirroring lists with a mirroring_guid (0)
#       mssql_logshipping  as many rows as msdb's log_shipping_monitor_primary and _secondary (0)
#                          [Run 9: skipped "the login has no access to msdb.dbo.log_shipping_monitor_primary (a user in
#                           msdb with db_datareader is the missing right)" - a right the RDS master user cannot grant,
#                           on a service with no log shipping. From run 10 the expectation is a skip by an Amazon RDS
#                           rule that says so (the change proposed for internal/mssql/logshipping.go); the
#                           missing-right skip is a FAIL.]
#       mssql_replication  as many distribution databases as sys.databases flags (0): no row
#       mssql_jobs         the job names of msdb.dbo.sysjobs
#                          [Run 9: an error, "The SELECT permission was denied on the object 'sysschedules'" (229): the
#                           read touches eleven msdb tables and checks two; the RDS master user can grant three. From
#                           run 10 the expectation is a skip whose note names the table and Amazon RDS (the change
#                           proposed for internal/mssql/jobs.go); an error or a skip that blames db_datareader is a FAIL.]
#       mssql_backups      one row per database of sys.databases; a last full backup where msdb.dbo.backupset has one
#                          [Run 9: the read counted backupset rows of every server name; the collector reads only this
#                           server's own (server_name = @@SERVERNAME or ServerName: a RESTORE brings another server's
#                           rows). The hand read mirrors that filter from run 10 - a proof-side fix. Run 10: the three
#                           full backups RDS writes while it builds the instance (msdb, model, rdsadmin) go to the NUL
#                           device, which the collector never counts as a last full backup (backups.go: no backup
#                           anyone can restore); the hand read mirrors that rule from run 11.]
#       mssql_storage      every file of sys.master_files (database id, file id, size in bytes)
#       mssql_versionstore the databases sys.dm_tran_version_store_space_usage lists with reserved pages
#       mssql_cpu          the CPU count and the VISIBLE ONLINE schedulers; the newest ring buffer record stored lies
#                          between the newest before and after the run
#       mssql_memory       physical memory and the memory model of sys.dm_os_sys_memory / sys.dm_os_sys_info
#       mssql_fileio       per file, reads and writes bracketed by sys.dm_io_virtual_file_stats before and after
#       mssql_tempdb       tempdb's files and sizes of tempdb.sys.database_files
#       mssql_properties   edition, version, collation, CPU count, max server memory, tempdb data files
#       mssql_procstats    per cached procedure, executions bracketed by sys.dm_exec_procedure_stats; the proof's
#                          procedure is stored with 5 executions or more
#                          [Run 10: this db.t3.micro Express instance keeps no procedure in sys.dm_exec_procedure_stats,
#                           even inside the batch that ran it (one cached plan in all, read by the master user). From
#                           run 11 the per-procedure part holds where the master user's read shows the procedure, and
#                           is said NOT PROVEN where it shows none; the bracket over every stored row stays.]
#       mssql_indexlocks   per index with lock waits, the row lock waits bracketed by
#                          sys.dm_db_index_operational_stats; the proof's table's index is stored with one wait or more
#                          [Run 10: no wait was made - the locker's container connected after the proof's update ran;
#                           from run 11 the update starts once the master user reads the locker's granted X key lock.]
#       mssql_querystore   the proof's database stored with Query Store READ_WRITE, as its options read
#     except mssql_ag: skipped, the note "Always On is not enabled on this server" (RDS Express has no availability
#     group; a rule of the server, said as skipped, never counted as collected or failed). A collection skipped for
#     a missing right, partial, or failed is a FAIL with its note (the statement and the file are named in the report).
#  C. the pages: GET /api/mssql/summary gives the instance availability as ok or n/a and every other cell a read
#     (no 'never'); the Summary renders (chromium) with the platform badge rdssqlserver; each SQL Server tab of the
#     instance renders without an error line.
#  D. nothing of pgvigil is created on the server: the server's principals, server permissions, event sessions,
#     and every database's objects (not shipped by Microsoft), principals and permissions, read by the master user
#     after the proof's own setup, equal the same read after every collector run.
#  The last line is "proof-mssql-rds: PASS (...)" and the exit code 0 only when R, A, B, C and D hold; else every
#  failed item is listed with its text, the last line says FAIL with their count, and the exit code is 1.
#  NOT PROVEN HERE: editions other than Express (Web, Standard, Enterprise: Agent and its jobs, Multi-AZ with
#  Always On or mirroring), RDS's own procedures (rds_* in msdb) beyond what the collections read, Windows
#  authentication (AWS Managed Microsoft AD), RDS Custom.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
STATE=${PGVIGIL_LAB_STATE:-.lab/aws-rds-mssql.env}
IMG=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
for t in docker psql curl jq python3; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
[ -r "$STATE" ] || { echo "FAIL: no lab state file $STATE (scripts/lab/aws-rds-mssql.sh up, allow, logins)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
: "${RDS_HOST:?the state file has no endpoint} ${ADMIN_USER:?} ${ADMIN_PW:?} ${MON_USER:?} ${MON_PW:?}"
PORT_=${RDS_PORT:-1433}
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_rdsproof_$SUF; XEID=p$SUF; N=proof-rds-$SUF; HOSTTAG=pgvproof-$SUF; FDB=pgvproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
export SQLCMDPASSWORD="$ADMIN_PW"
export RDS_MON_DSN="sqlserver://$MON_USER:$MON_PW@$RDS_HOST:$PORT_?database=master&encrypt=true&TrustServerCertificate=true"
MADE_DB=; MADE_XE=; MADE_FDB=; WAITER=; SRV=; LOCKER=
FAILS=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
# (sqlcmd: -I sets QUOTED_IDENTIFIER ON, which the xml methods need (Msg 1934 without it); -W cuts a value at 256 characters and cannot go with -y; -y 8000 pads each column, the padding is
# stripped around each separator and at both ends of the line - no value read here starts or ends with a space)
# sq "<sql>" [db]: rows as the master user, '|' between columns, NULL as NULL; the statement goes on stdin
sq() { local out rc=0
  out=$(docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" \
  -d "${2:-master}" -C -b -I -l 60 -h -1 -s '|' -y 8000 -i /dev/stdin <<<"SET NOCOUNT ON; $1" 2>&1) || rc=$?
  # a failed read stops the proof with sqlcmd's own message, never a silent empty value
  [ $rc -eq 0 ] || { echo "$1" >> "$WORK/sq-failed"; echo "FAIL: a read of the setup login failed ($rc): $(tr '\n' ' ' <<<"$out" | cut -c1-600) -- the statement: $(tr '\n' ' ' <<<"$1" | cut -c1-300)" >&2; return $rc; }
  sed -E 's/ +\|/|/g; s/\| +/|/g; s/^ +//; s/ +$//' <<<"$out"; }
sqfile() { docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d master -C -b -l 60 -i /dev/stdin; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; }
  for c in $WAITER $LOCKER; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  if [ -n "$MADE_XE" ]; then "$BIN" mssql-xe -print -drop -form server -install-id "$XEID" > "$WORK/xe-drop.sql" 2>/dev/null && sqfile < "$WORK/xe-drop.sql" >/dev/null 2>&1 \
    || echo "CLEANUP: the event sessions pgvigil_${XEID}_* were NOT dropped" >&2; fi
  if [ -n "$MADE_FDB" ]; then
    sq "IF DB_ID(N'$FDB') IS NOT NULL BEGIN ALTER DATABASE [$FDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$FDB]; END" >/dev/null 2>&1 \
      || sq "EXEC msdb.dbo.rds_drop_database N'$FDB'" >/dev/null 2>&1 || echo "CLEANUP: database $FDB on the instance NOT dropped" >&2
  fi
  if [ -n "$MADE_DB" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else
  command -v go >/dev/null || die "go is not on this machine and PGVIGIL_BIN names no binary"
  CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi

echo "--- the instance answers"
for i in $(seq 1 6); do sq "SELECT 1" >/dev/null 2>&1 && break; [ "$i" = 6 ] && die "the master user gets no answer from $RDS_HOST"; sleep 10; done
rm -f "$WORK/sq-failed"   # the tries before the first answer are the wait, not failed reads
IFS='|' read -r PV ED EE SN <<<"$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('EngineEdition') AS int), CAST(SERVERPROPERTY('ServerName') AS nvarchar(128))")"
echo "  the master user reads: $PV | $ED | engine edition $EE | $SN"

echo "--- R. the collector's rights"
# each piece COLLATE DATABASE_DEFAULT: the catalog's permission names and msdb's object names carry different
# collations on an RDS server (Msg 451 without it)
R=$(sq "SELECT ISNULL((SELECT STRING_AGG(permission_name, ',') WITHIN GROUP (ORDER BY permission_name) FROM sys.server_permissions WHERE grantee_principal_id = SUSER_ID(N'$MON_USER') AND state IN ('G', 'W')), '') COLLATE DATABASE_DEFAULT
  + '|' + CAST(IS_SRVROLEMEMBER('sysadmin', N'$MON_USER') AS varchar(2))
  + '|' + ISNULL((SELECT STRING_AGG(r.name, ',') FROM msdb.sys.database_role_members m JOIN msdb.sys.database_principals r ON r.principal_id = m.role_principal_id JOIN msdb.sys.database_principals u ON u.principal_id = m.member_principal_id WHERE u.name = N'$MON_USER'), '') COLLATE DATABASE_DEFAULT
  + '|' + ISNULL((SELECT STRING_AGG(o.name, ',') WITHIN GROUP (ORDER BY o.name) FROM msdb.sys.database_permissions p JOIN msdb.sys.objects o ON o.object_id = p.major_id JOIN msdb.sys.database_principals u ON u.principal_id = p.grantee_principal_id WHERE u.name = N'$MON_USER' AND p.permission_name = 'SELECT' AND p.state = 'G'), '') COLLATE DATABASE_DEFAULT")
echo "  $MON_USER: $R"
[ "$R" = "CONNECT SQL,VIEW ANY DEFINITION,VIEW SERVER STATE|0||sysjobactivity,sysjobhistory,sysjobs" ] && echo "R: OK (the RDS form: no CONNECT ANY DATABASE and no msdb db_datareader, which the master user cannot grant)" \
  || bad "R: the collector's login holds '$R' (want CONNECT SQL,VIEW ANY DEFINITION,VIEW SERVER STATE|0||sysjobactivity,sysjobhistory,sysjobs)"

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N
    engine: sqlserver
    dsn: env:RDS_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null

echo "--- the proof's own setup, as the server's DBA"
MADE_FDB=1
sq "CREATE DATABASE [$FDB];" >/dev/null
# Express makes a new database AUTO_CLOSE ON: each time its last session leaves it closes, and its closing empties the
# plan cache and resets its index statistics (each read here is a session of its own)
sq "ALTER DATABASE [$FDB] SET AUTO_CLOSE OFF;" >/dev/null
sq "ALTER DATABASE [$FDB] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);" >/dev/null
# the RDS form of the login reads a database through a user of its own there (no CONNECT ANY DATABASE on RDS)
sq "CREATE USER [$MON_USER] FOR LOGIN [$MON_USER];" "$FDB" >/dev/null
sq "CREATE TABLE dbo.t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY, v int NOT NULL); INSERT dbo.t VALUES (1, 0), (2, 0);" "$FDB" >/dev/null
sq "EXEC('CREATE PROCEDURE dbo.pgvproof_p AS SELECT COUNT(*) FROM dbo.t;');" "$FDB" >/dev/null
# one row lock wait on pk_t: a session holds the row for 8 seconds, the proof's update waits for it
LOCKER=pgvproof-lock-$SUF
docker run -d --name "$LOCKER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d "$FDB" -C -l 60 \
  -H "$LOCKER" -Q "BEGIN TRAN; UPDATE dbo.t WITH (ROWLOCK) SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:15'; COMMIT;" >/dev/null
# the proof's update starts only once the locker holds its row (run 10: the container connected after it, no wait)
HELD=0
for _ in $(seq 1 30); do HELD=$(sq "SELECT COUNT(*) FROM sys.dm_tran_locks l JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
  WHERE s.host_name = N'$LOCKER' AND l.resource_type = 'KEY' AND l.request_mode = 'X' AND l.request_status = 'GRANT'"); [ "$HELD" -ge 1 ] && break; sleep 1; done
[ "$HELD" -ge 1 ] || bad "B: the proof's lock wait was not set up: the locker session never held its row"
sq "UPDATE dbo.t WITH (ROWLOCK) SET v = v + 1 WHERE id = 1;" "$FDB" >/dev/null
docker wait "$LOCKER" >/dev/null 2>&1 || true; docker rm -f "$LOCKER" >/dev/null 2>&1 || true; LOCKER=
"$BIN" mssql-xe -print -form server -install-id "$XEID" > "$WORK/xe.sql"
MADE_XE=1
XE_REFUSED=
if ! sqfile < "$WORK/xe.sql" > "$WORK/xe.out" 2>&1; then
  if grep -qi 'supports extended events only for the Enterprise and Standard editions' "$WORK/xe.out"; then
    XE_REFUSED=1; echo "  the -form server script: RDS refuses event sessions on this edition (rds_extended_events_trigger)"
  else bad "B: pgvigil's -form server Extended Events script failed as the master user: $(tr '\n' ' ' < "$WORK/xe.out" | cut -c1-600)"; fi
fi
snap() {
  sq "SELECT 'srvprincipal|' + name + '|' + type COLLATE DATABASE_DEFAULT FROM sys.server_principals
    UNION ALL SELECT 'srvperm|' + ISNULL(SUSER_NAME(grantee_principal_id), '?') + '|' + permission_name + '|' + state_desc + '|' + class_desc COLLATE DATABASE_DEFAULT FROM sys.server_permissions
    UNION ALL SELECT 'xe|' + name COLLATE DATABASE_DEFAULT FROM sys.server_event_sessions
    UNION ALL SELECT 'db|' + name COLLATE DATABASE_DEFAULT FROM sys.databases ORDER BY 1"
  local dbs; dbs=$(sq "SELECT name FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1 ORDER BY name")
  for d in $dbs; do
    sq "SELECT '$d|obj|' + s.name + '.' + o.name + '|' + o.type COLLATE DATABASE_DEFAULT FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE o.is_ms_shipped = 0
      UNION ALL SELECT '$d|principal|' + name + '|' + type COLLATE DATABASE_DEFAULT FROM sys.database_principals
      UNION ALL SELECT '$d|perm|' + ISNULL(USER_NAME(grantee_principal_id), '?') + '|' + permission_name + '|' + state_desc + '|' + class_desc + '|' + CAST(major_id AS varchar(12)) COLLATE DATABASE_DEFAULT FROM sys.database_permissions
      UNION ALL SELECT '$d|member|' + USER_NAME(role_principal_id) + '|' + USER_NAME(member_principal_id) COLLATE DATABASE_DEFAULT FROM sys.database_role_members ORDER BY 1" "$d"
  done; }
snap > "$WORK/before.txt"

echo "--- A. detection"
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$N" | tee "$WORK/mssql_instance.out" || true
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
[ -n "$iid" ] || die "A: the instance was not stored (the run above says why)"
maj=${PV%%.*}; rest=${PV#*.}; min=${rest%%.*}
GOT=$(q "select i.engine || '|' || i.platform || '|' || i.server_version_num || '|' || m.product_version || '|' || m.edition || '|' || m.engine_edition || '|' || m.server_name from pgvigil.instances i join pgvigil.mssql_instance m using (instance_id) where instance_id=$iid")
WANT="sqlserver|rdssqlserver|$((maj * 10000 + 10#$min))|$PV|$ED|$EE|$SN"
[ "$GOT" = "$WANT" ] && [ "$EE" = 4 ] && echo "A: OK ($GOT)" || bad "A: stored '$GOT', want '$WANT' with engine edition 4"

echo "--- B. every collection"
mapfile -t KNOWN < <(grep -ho 'Name() string *{ return Prefix + "[a-z_]*"' $(ls internal/mssql/*.go | grep -v _test.go) | sed 's/.*Prefix + "\([a-z_]*\)"/mssql_\1/' | sort)
ALL=(mssql_instance mssql_services mssql_requests mssql_waits mssql_xe mssql_ag mssql_mirroring mssql_logshipping mssql_replication mssql_jobs mssql_backups
  mssql_storage mssql_versionstore mssql_cpu mssql_memory mssql_fileio mssql_tempdb mssql_properties mssql_procstats mssql_indexlocks mssql_querystore)
[ "$(printf '%s\n' "${KNOWN[@]}" | tr '\n' ' ')" = "$(printf '%s\n' "${ALL[@]}" | sort | tr '\n' ' ')" ] || bad "B: the collections of internal/mssql (${KNOWN[*]}) are not the proof's list"
declare -A VERDICT
status_of() { q "select coalesce(status, '') || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='$1'"; }
run_ok() { # run_ok <collection>: runs it, and says whether it stored a read with status ok
  "$BIN" collect -config "$CFG" -once "$1" -instance "$N" > "$WORK/$1.out" 2>&1 || true
  local st; st=$(status_of "$1")
  if [[ $st == ok\|* ]]; then return 0; fi
  VERDICT[$1]="FAIL"; bad "B: $1 status '$st' (want ok), the run said '$(tr '\n' ' ' < "$WORK/$1.out" | cut -c1-400)'"; return 1
}
eq() { # eq <collection> <stored> <hand>: the verdict of an exact comparison; an empty side is a failed read
  if [ -z "$2" ] || [ -z "$3" ]; then VERDICT[$1]="FAIL"; bad "B: $1: an empty side (stored '$2', the master user reads '$3')"; return; fi
  if [ "$2" = "$3" ]; then VERDICT[$1]="PASS"; if [ -n "${4:-}" ] && { [ "$2" = 0 ] || [ "$2" = "(none)" ]; }; then VERDICT[$1]="PASS (${4})"; fi; else VERDICT[$1]="FAIL"; bad "B: $1 stored '$(cut -c1-300 <<<"$2")', the master user reads '$(cut -c1-300 <<<"$3")'"; fi; }
# bracket <collection> <before> <after> <stored> [<key that must be stored>]: every stored key lies between the
# reads before and after (each number), every key counted before is stored
bracket() {
  local out
  if out=$(python3 - "$2" "$3" "$4" "${5:-}" <<'PY'
import sys
def rd(p):
    d = {}
    for line in open(p):
        k, *v = line.rstrip("\n").split("|")
        if k: d[k.lower()] = [int(x) for x in v]
    return d
b, a, s = (rd(p) for p in sys.argv[1:4])
must = sys.argv[4].lower()
errs = [f"{k} stored {v}, before {b.get(k)}, after {a.get(k)}" for k, v in s.items()
        if k not in a or any(x < y for x, y in zip(v, b.get(k, [0] * len(v)))) or any(x > y for x, y in zip(v, a[k]))]
errs += [f"{k} counted before the run and not stored" for k in b if k not in s]
if must and must not in s: errs.append(f"{must} not stored")
if not s: errs.append("nothing stored")
print(f"{len(s)} stored, {len(b)} before, {len(a)} after")
if errs: print("; ".join(errs[:8])); sys.exit(1)
PY
  ); then VERDICT[$1]="PASS ($out)"; else VERDICT[$1]="FAIL"; bad "B: $1: $out"; fi
}
# mssql_instance (run in A)
st=$(status_of mssql_instance)
if [[ $st == ok\|* ]]; then
  eq mssql_instance "$(q "select (select count(*) from pgvigil.mssql_config where instance_id=$iid) || '|' || coalesce((select value_in_use::text from pgvigil.mssql_config where instance_id=$iid and name='max server memory (MB)'), 'NULL') || '|' || (select sysinfo_read || '|' || coalesce(cpu_count::text, 'NULL') from pgvigil.mssql_instance where instance_id=$iid)")" \
    "$(sq "SELECT CAST((SELECT COUNT(*) FROM sys.configurations) AS varchar(9)) + '|' + CAST((SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)') AS varchar(20)) + '|true|' + CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS varchar(9))")"
else VERDICT[mssql_instance]="FAIL"; bad "B: mssql_instance status '$st' (want ok)"; fi
run_ok mssql_services && eq mssql_services \
  "$(q "select string_agg(service_name || '=' || coalesce(status, ''), ',' order by service_name) || '|' || (select coalesce(agent_expected::text, 'NULL') from pgvigil.mssql_health where instance_id=$iid) from pgvigil.mssql_service where instance_id=$iid and is_present")" \
  "$(sq "SELECT ISNULL(STRING_AGG(CAST(servicename AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '=' + CAST(status_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT, ',') WITHIN GROUP (ORDER BY servicename), '') + '|false' FROM sys.dm_server_services")"
# mssql_requests: a session of the master user that waits on WAITFOR
WAITER=pgvproof-wait-$SUF
docker run -d --name "$WAITER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d master -C -l 60 -H "$HOSTTAG" -Q "WAITFOR DELAY '00:02:00'" >/dev/null
WSID=
for _ in $(seq 1 30); do WSID=$(sq "SELECT r.session_id FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = N'$HOSTTAG' AND r.wait_type = N'WAITFOR'"); [ -n "$WSID" ] && break; sleep 2; done
if [ -z "$WSID" ]; then VERDICT[mssql_requests]="FAIL"; bad "B: mssql_requests: the waiting session never showed in the master user's read"
elif run_ok mssql_requests; then
  eq mssql_requests "$(q "select session_id || '|' || command || '|' || wait_type from pgvigil.mssql_requests where instance_id=$iid and session_id=$WSID order by snapshot_at desc limit 1")" \
    "$(sq "SELECT CAST(session_id AS varchar(9)) + '|' + command + '|' + wait_type FROM sys.dm_exec_requests WHERE session_id = $WSID")"
fi
docker rm -f "$WAITER" >/dev/null 2>&1 || true; WAITER=
# the bracketed collections: read before, run, read after
WSQL="SELECT wait_type + '|' + CAST(waiting_tasks_count AS varchar(20)) + '|' + CAST(wait_time_ms AS varchar(20)) FROM sys.dm_os_wait_stats WHERE waiting_tasks_count > 0 OR wait_time_ms > 0"
sq "$WSQL" > "$WORK/w-b.txt"
if run_ok mssql_waits; then sq "$WSQL" > "$WORK/w-a.txt"
  q "select wait_type || '|' || waiting_tasks || '|' || wait_ms from pgvigil.mssql_wait_last where instance_id=$iid" > "$WORK/w-s.txt"
  bracket mssql_waits "$WORK/w-b.txt" "$WORK/w-a.txt" "$WORK/w-s.txt"; fi
FSQL="SELECT CAST(database_id AS varchar(9)) + ':' + CAST(file_id AS varchar(9)) + '|' + CAST(num_of_reads AS varchar(20)) + '|' + CAST(num_of_writes AS varchar(20)) FROM sys.dm_io_virtual_file_stats(NULL, NULL)"
sq "$FSQL" > "$WORK/f-b.txt"
if run_ok mssql_fileio; then sq "$FSQL" > "$WORK/f-a.txt"
  q "select database_id || ':' || file_id || '|' || reads || '|' || writes from pgvigil.mssql_fileio_last where instance_id=$iid" > "$WORK/f-s.txt"
  bracket mssql_fileio "$WORK/f-b.txt" "$WORK/f-a.txt" "$WORK/f-s.txt"; fi
PSQL_="SELECT CONVERT(varchar(130), plan_handle, 1) + '|' + CAST(execution_count AS varchar(20)) FROM sys.dm_exec_procedure_stats WHERE database_id <> 32767"
FDBID=$(sq "SELECT DB_ID(N'$FDB')"); POBJ=$(sq "SELECT OBJECT_ID(N'dbo.pgvproof_p')" "$FDB")
# the procedure runs right before the read: a db.t3.micro's small plan cache let it go between the setup and here (run 9)
sq "EXEC dbo.pgvproof_p; EXEC dbo.pgvproof_p; EXEC dbo.pgvproof_p; EXEC dbo.pgvproof_p; EXEC dbo.pgvproof_p;" "$FDB" >/dev/null
sq "$PSQL_" > "$WORK/p-b.txt"
if run_ok mssql_procstats; then sq "$PSQL_" > "$WORK/p-a.txt"
  q "select plan_handle || '|' || execution_count from pgvigil.mssql_proc_last where instance_id=$iid" > "$WORK/p-s.txt"
  bracket mssql_procstats "$WORK/p-b.txt" "$WORK/p-a.txt" "$WORK/p-s.txt"
  PX=$(q "select coalesce(max(execution_count), 0) from pgvigil.mssql_proc_last where instance_id=$iid and database_id=$FDBID and object_id=$POBJ")
  HX=$(sq "SELECT ISNULL(MAX(execution_count), 0) FROM sys.dm_exec_procedure_stats WHERE database_id = $FDBID AND object_id = $POBJ")
  if [ "$HX" = 0 ] && [ "$PX" = 0 ]; then
    if [[ ${VERDICT[mssql_procstats]} == PASS* ]]; then VERDICT[mssql_procstats]="${VERDICT[mssql_procstats]}; the proof's procedure NOT PROVEN: the server kept no plan for it (the master user's own read shows none either)"; fi
  elif [ "$PX" -ge 5 ]; then :
  else VERDICT[mssql_procstats]="FAIL"; bad "B: mssql_procstats: the proof's procedure (database $FDBID, object $POBJ) stored with $PX execution(s), want 5 or more; stored for that database: '$(q "select string_agg(object_id || ':' || execution_count, ',') from pgvigil.mssql_proc_last where instance_id=$iid and database_id=$FDBID")'; the DMV: '$(sq "SELECT CAST(object_id AS varchar(12)) + ':' + CAST(execution_count AS varchar(20)) + ':' + CONVERT(varchar(130), plan_handle, 1) FROM sys.dm_exec_procedure_stats WHERE database_id = $FDBID" | tr '\n' ',')'"
  fi
fi
ISQL="SELECT CAST(database_id AS varchar(9)) + ':' + CAST(object_id AS varchar(12)) + ':' + CAST(index_id AS varchar(9)) + ':' + CAST(partition_number AS varchar(9)) + '|' + CAST(row_lock_wait_count AS varchar(20)) + '|' + CAST(page_lock_wait_count AS varchar(20))
  FROM sys.dm_db_index_operational_stats(NULL, NULL, NULL, NULL) WHERE row_lock_wait_count > 0 OR page_lock_wait_count > 0 OR index_lock_promotion_attempt_count > 0"
sq "$ISQL" > "$WORK/i-b.txt"
TOBJ=$(sq "SELECT OBJECT_ID(N'dbo.t')" "$FDB")
if run_ok mssql_indexlocks; then sq "$ISQL" > "$WORK/i-a.txt"
  q "select database_id || ':' || object_id || ':' || index_id || ':' || partition_number || '|' || row_lock_waits || '|' || page_lock_waits from pgvigil.mssql_indexlock_last where instance_id=$iid" > "$WORK/i-s.txt"
  bracket mssql_indexlocks "$WORK/i-b.txt" "$WORK/i-a.txt" "$WORK/i-s.txt" "$FDBID:$TOBJ:1:1"; fi
CSQL="SELECT MAX(CAST(record_id AS bigint)) FROM (SELECT CONVERT(xml, record).value('(./Record/@id)[1]', 'bigint') AS record_id FROM sys.dm_os_ring_buffers WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%') r"
CB=$(sq "$CSQL")
if run_ok mssql_cpu; then CA=$(sq "$CSQL")
  GOT=$(q "select coalesce(max(record_id), -1) from pgvigil.mssql_cpu_sample where instance_id=$iid")
  SCH=$(q "select coalesce(schedulers::text, 'NULL') || '|' || coalesce(cpu_count::text, 'NULL') from pgvigil.mssql_sched_sample where instance_id=$iid order by snapshot_at desc limit 1")
  HSCH=$(sq "SELECT CAST((SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = N'VISIBLE ONLINE') AS varchar(9)) + '|' + CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS varchar(9))")
  if [ "$GOT" -ge "$CB" ] && [ "$GOT" -le "$CA" ] && [ "$SCH" = "$HSCH" ]; then VERDICT[mssql_cpu]="PASS (newest record $GOT between $CB and $CA; schedulers|cpus $SCH)"
  else VERDICT[mssql_cpu]="FAIL"; bad "B: mssql_cpu newest record $GOT (before $CB, after $CA), schedulers|cpus stored '$SCH', read '$HSCH'"; fi
fi
run_ok mssql_memory && eq mssql_memory \
  "$(q "select physical_kb || '|' || coalesce(memory_model, 'NULL') from pgvigil.mssql_memory_sample where instance_id=$iid order by snapshot_at desc limit 1")" \
  "$(sq "SELECT CAST(sm.total_physical_memory_kb AS varchar(20)) + '|' + si.sql_memory_model_desc FROM sys.dm_os_sys_memory sm CROSS JOIN sys.dm_os_sys_info si")"
# the exact sets
run_ok mssql_mirroring && eq mssql_mirroring "$(q "select count(*) from pgvigil.mssql_mirroring_state where instance_id=$iid")" "$(sq "SELECT COUNT(*) FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL")" "0 rows: empty on both sides"
"$BIN" collect -config "$CFG" -once mssql_logshipping -instance "$N" > "$WORK/mssql_logshipping.out" 2>&1 || true
st=$(status_of mssql_logshipping)
if [[ $st == skipped\|*"Amazon RDS"* ]] && grep -q "skipped: " "$WORK/mssql_logshipping.out" && [ "$(q "select count(*) from pgvigil.mssql_logshipping_state where instance_id=$iid")" = 0 ]; then VERDICT[mssql_logshipping]="SKIP (${st#skipped|})"
else VERDICT[mssql_logshipping]="FAIL"; bad "B: mssql_logshipping status '$st' (want skipped by an Amazon RDS rule: RDS has no log shipping and its master user cannot grant msdb's log shipping tables)"; fi
run_ok mssql_replication && eq mssql_replication "$(q "select count(distinct distribution_db) from pgvigil.mssql_replication_state where instance_id=$iid")" "$(sq "SELECT COUNT(*) FROM sys.databases WHERE is_distributor = 1 AND state = 0")" "0 rows: empty on both sides"
"$BIN" collect -config "$CFG" -once mssql_jobs -instance "$N" > "$WORK/mssql_jobs.out" 2>&1 || true
st=$(status_of mssql_jobs)
if [[ $st == skipped\|*msdb.dbo.sys*"Amazon RDS master user cannot grant"* ]] && grep -q "skipped: " "$WORK/mssql_jobs.out" && [ "$(q "select count(*) from pgvigil.mssql_jobs where instance_id=$iid")" = 0 ]; then VERDICT[mssql_jobs]="SKIP (${st#skipped|})"
else VERDICT[mssql_jobs]="FAIL"; bad "B: mssql_jobs status '$st' (want skipped, naming the msdb table the RDS master user cannot grant)"; fi
echo "  msdb.dbo.backupset by server name (this server is $SN): $(sq "SELECT server_name + ' ' + type + ' x' + CAST(COUNT(*) AS varchar(9)) FROM msdb.dbo.backupset GROUP BY server_name, type ORDER BY 1" | tr '\n' ',')"
# the set of databases with a counted full backup, by every rule of the collector (backups.go: this server's own rows,
# the first media family, not the NUL device, not an availability group's seeding; 0066: finished no earlier than an
# hour before the database was made)
run_ok mssql_backups && eq mssql_backups \
  "$(q "select string_agg(database_name, ',' order by database_name) || '|' || coalesce(string_agg(database_name, ',' order by database_name) filter (where full_at is not null), '(none)') from pgvigil.mssql_backup_state where instance_id=$iid and is_present")" \
  "$(sq "SELECT (SELECT STRING_AGG(name, ',') WITHIN GROUP (ORDER BY name) FROM sys.databases) + '|' + ISNULL((SELECT STRING_AGG(n, ',') WITHIN GROUP (ORDER BY n) FROM (SELECT DISTINCT bs.database_name AS n
     FROM msdb.dbo.backupset bs JOIN sys.databases d ON d.name = bs.database_name
     OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number) mf
     WHERE bs.type = 'D' AND bs.backup_finish_date IS NOT NULL AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
       AND UPPER(ISNULL(mf.physical_device_name, N'')) NOT IN (N'NUL', N'NUL:')
       AND NOT (bs.is_copy_only = 1 AND bs.is_snapshot = 0 AND ISNULL(mf.device_type, 0) IN (7, 107) AND bs.name IS NULL AND ISNULL(mf.physical_device_name, N'') LIKE N'{________-____-____-____-____________}')
       AND bs.backup_finish_date >= DATEADD(hour, -1, d.create_date)) x), '(none)')")"
run_ok mssql_storage && eq mssql_storage \
  "$(q "select string_agg(database_id || ':' || file_id || '=' || size_bytes, ',' order by database_id, file_id) from pgvigil.mssql_files where instance_id=$iid and is_present")" \
  "$(sq "SELECT STRING_AGG(CAST(mf.database_id AS varchar(9)) + ':' + CAST(mf.file_id AS varchar(9)) + '=' + CAST(CAST(mf.size AS bigint) * 8192 AS varchar(20)), ',') WITHIN GROUP (ORDER BY mf.database_id, mf.file_id) FROM sys.master_files mf JOIN sys.databases d ON d.database_id = mf.database_id WHERE d.source_database_id IS NULL")"
run_ok mssql_versionstore && eq mssql_versionstore "$(q "select coalesce(string_agg(database_name, ',' order by database_name), '(none)') from pgvigil.mssql_versionstore_db where instance_id=$iid")" \
  "$(sq "SELECT ISNULL(STRING_AGG(DB_NAME(database_id), ',') WITHIN GROUP (ORDER BY DB_NAME(database_id)), '(none)') FROM sys.dm_tran_version_store_space_usage WHERE reserved_page_count > 0 AND DB_NAME(database_id) IS NOT NULL")"
run_ok mssql_tempdb && eq mssql_tempdb "$(q "select string_agg(file_id || '=' || size_bytes, ',' order by file_id) from pgvigil.mssql_tempdb_files where instance_id=$iid")" \
  "$(sq "SELECT STRING_AGG(CAST(file_id AS varchar(9)) + '=' + CAST(CAST(size AS bigint) * 8192 AS varchar(20)), ',') WITHIN GROUP (ORDER BY file_id) FROM sys.database_files" tempdb)"
run_ok mssql_properties && eq mssql_properties \
  "$(q "select string_agg(name || '=' || coalesce(value, 'NULL'), ',' order by name) from pgvigil.mssql_property where instance_id=$iid and name in ('collation', 'cpu_count', 'edition', 'max_memory_mb', 'product_version', 'tempdb_data_files')")" \
  "$(sq "SELECT 'collation=' + CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) + ',cpu_count=' + CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS varchar(9)) + ',edition=' + CAST(SERVERPROPERTY('Edition') AS nvarchar(128))
     + ',max_memory_mb=' + CAST((SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)') AS varchar(20)) + ',product_version=' + CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128))
     + ',tempdb_data_files=' + CAST((SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type = 0) AS varchar(9))")"
run_ok mssql_querystore && eq mssql_querystore "$(q "select coalesce(actual_state, 'NULL') from pgvigil.mssql_qs_store where instance_id=$iid and database_name='$FDB'")" \
  "$(sq "SELECT actual_state_desc FROM sys.database_query_store_options" "$FDB")"
if run_ok mssql_xe; then
  eq mssql_xe "$(q "select capture || '|' || state from pgvigil.mssql_xe_state where instance_id=$iid order by 1" | tr '\n' ' ')" \
    "$(sq "SELECT c.capture + '|' + CASE WHEN x.name IS NOT NULL THEN 'running' WHEN d.name IS NOT NULL THEN 'stopped' ELSE 'not installed' END
      FROM (VALUES ('attention'), ('blocked'), ('deadlocks'), ('slow')) c(capture) LEFT JOIN sys.server_event_sessions d ON d.name = N'pgvigil_${XEID}_' + c.capture
      LEFT JOIN sys.dm_xe_sessions x ON x.name = d.name ORDER BY 1" | tr '\n' ' ')"
  NRUN=$(q "select count(*) from pgvigil.mssql_xe_state where instance_id=$iid and state='running'")
  if [[ ${VERDICT[mssql_xe]} == PASS* ]] && [ -n "$XE_REFUSED" ]; then
    if [ "$NRUN" = 0 ]; then VERDICT[mssql_xe]="PASS (every capture 'not installed', equal to the master user's read; running sessions NOT PROVEN: RDS refuses them on Express)"
    else VERDICT[mssql_xe]="FAIL"; bad "B: mssql_xe: $NRUN capture(s) stored running where RDS refused every session"; fi
  elif [[ ${VERDICT[mssql_xe]} == PASS* ]] && [ "$NRUN" != 4 ]; then VERDICT[mssql_xe]="FAIL"; bad "B: mssql_xe: $NRUN of four captures running after the -form server script"; fi
fi
"$BIN" collect -config "$CFG" -once mssql_ag -instance "$N" > "$WORK/mssql_ag.out" 2>&1 || true
st=$(status_of mssql_ag)
if [[ $st == "skipped|Always On is not enabled on this server"* ]] && grep -q "skipped: " "$WORK/mssql_ag.out" && [ "$(sq "SELECT CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS int)")" = 0 ]; then VERDICT[mssql_ag]="SKIP (${st#skipped|})"
else VERDICT[mssql_ag]="FAIL"; bad "B: mssql_ag status '$st' (want skipped: Always On is not enabled on this server)"; fi
echo "  the collections:"
for c in "${ALL[@]}"; do printf '    %-20s %s\n' "$c" "${VERDICT[$c]:-FAIL (no verdict)}"; done

echo "--- D. nothing of pgvigil created on the server"
snap > "$WORK/after.txt"
if diff "$WORK/before.txt" "$WORK/after.txt" > "$WORK/d.diff"; then echo "D: OK ($(wc -l < "$WORK/after.txt") principals, permissions, sessions, databases and objects unchanged)"
else bad "D: the server changed under the collector: $(tr '\n' ' ' < "$WORK/d.diff" | cut -c1-400)"; fi

echo "--- C. the pages"
if [ -n "${PGVIGIL_SKIP_PAGES:-}" ]; then echo "C: NOT RUN (PGVIGIL_SKIP_PAGES)"; FAILS+=("C: not run")
else
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  "$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
  for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -fs "http://127.0.0.1:$PORT/api/mssql/summary" > "$WORK/sum.json" || { cat "$WORK/serve.log" >&2; die "C: GET /api/mssql/summary"; }
  # cells is a table: {columns: [...], rows: [[...], ...]}
  GOT=$(jq -r --argjson i "$iid" '.cells as $t | ($t.columns | index("instance_id")) as $ci | ($t.columns | index("key")) as $ck | ($t.columns | index("state")) as $cs
    | [$t.rows[] | select(.[$ci] == $i) | "\(.[$ck])=\(.[$cs])"] | sort | join(" ")' "$WORK/sum.json")
  if grep -q '=never' <<<"$GOT" || ! grep -qE 'availability=(ok|n/a)' <<<"$GOT"; then bad "C: the summary cells '$GOT' (want availability ok or n/a and no 'never')"; else echo "  summary cells: OK ($GOT)"; fi
  if command -v chromium >/dev/null; then
    page() { timeout 60 chromium --headless=new --no-sandbox --disable-gpu --user-data-dir="$WORK/chrome" --virtual-time-budget=15000 --dump-dom "http://127.0.0.1:$PORT/#/$1?i=$iid&w=1h" 2>/dev/null; }
    page summary > "$WORK/p-summary.html" || true
    grep -q 'rdssqlserver' "$WORK/p-summary.html" || bad "C: the Summary page does not show the platform badge rdssqlserver"
    for tab in summary performance mssql_running mssql_slow mssql_waits mssql_deadlocks mssql_blocked findings availability mssqlbackups mssqljobs mssqlstorage mssqlfiles \
               rowversions mssqlconfig mssqlactions jobstimeline mssqlcpu mssqlmemory mssqlfileio mssqltempdb mssqlqs counters mssqlprocs mssqlindexlocks mssqlproperties; do
      page "$tab" > "$WORK/p-$tab.html" || true
      if [ ! -s "$WORK/p-$tab.html" ] || grep -q 'class="error"' "$WORK/p-$tab.html"; then bad "C: tab $tab did not render: $(grep -o 'class="error"[^<]*<' "$WORK/p-$tab.html" | head -1)"; fi
    done
    echo "  pages rendered: 26 tabs"
  else bad "C: chromium is not on this machine: the pages were not rendered"; fi
fi

[ ! -s "$WORK/sq-failed" ] || bad "a read of the setup login failed during the run (its message is above): $(head -c 300 "$WORK/sq-failed" | tr '\n' ' ')"
echo
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "proof-mssql-rds: PASS (R, A, B: 18 collected and equal, mssql_ag skipped (no Always On), mssql_logshipping skipped (no log shipping on RDS), mssql_jobs skipped (the msdb tables the master user cannot grant); C; D)"
else
  echo "the failed items:"; printf '  - %s\n' "${FAILS[@]}"
  echo "proof-mssql-rds: FAIL (${#FAILS[@]} item(s))"; exit 1
fi
