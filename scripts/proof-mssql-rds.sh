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
# table, one procedure run in a loop by a session of the master user through the procedure reads (it ends by itself after
# 600 s), one row lock wait between two sessions of the master user just before the index lock reads (the locker holds
# 90 s; the waiting session is part B's mssql_waiting_tasks fixture), a user there
# for the collector's login) and the four
# Extended Events sessions of `pgvigil mssql-xe -print -form server -install-id p<n>` (dropped by the -drop script);
# one session of the master user that waits two minutes (part B's requests read); one 'Login failed for user
# 'pgvproof_nl_<n>'' line in the instance's error log (a login attempt under a name no login has: nothing to lock, and
# the line cannot be removed).
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
#  B. each of the 34 SQL Server collections (21 before the join of wave 1, 32 before the release join) (the list is checked against internal/mssql's Name() functions), status
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
#                          procedure is stored (from run 14: as a plan a read lists, see below)
#                          [Run 10: this db.t3.micro Express instance keeps no procedure in sys.dm_exec_procedure_stats,
#                           even inside the batch that ran it (one cached plan in all, read by the master user). From
#                           run 11 the per-procedure part holds where the master user's read shows the procedure, and
#                           is said NOT PROVEN where it shows none; the bracket over every stored row stays.]
#                          [Run 13: 0 stored, 0 before, 0 after, a FAIL ('nothing stored'). A probe the same hour: SQL
#                           Server's memory target on this db.t3.micro is 115 MB of 995 MB (70 MB free), the whole plan
#                           cache one plan; the proof's procedure is listed inside the batch that runs it and gone in the
#                           next session, and every read here is a session of its own. From run 14 a session runs the
#                           procedure in a loop through both reads and the collector's run; a plan is its handle and
#                           cached time (a recompile is a new plan, as mssql_proc_last keys it); the procedure's stored
#                           plan must be one a read lists, its count compared with each read that lists it; the other
#                           stored rows compare where a read lists them (a plan the cache dropped between the reads is
#                           not required, and their count is said); a stored set no read lists fails.]
#       mssql_indexlocks   per index with lock waits, the row lock waits bracketed by
#                          sys.dm_db_index_operational_stats; the proof's table's index is stored with one wait or more
#                          [Run 10: no wait was made - the locker's container connected after the proof's update ran;
#                           from run 11 the update starts once the master user reads the locker's granted X key lock.]
#                          [Run 13: two differences. (1) The hand read counted master's catalog tables (1:21, 1:28),
#                           which the collector never reads (indexlocks.go: object ids 1 to 100), and databases the
#                           collector's login cannot enter: from run 14 it mirrors both (the database list read as the
#                           collector's login). (2) The locker never held its row in 30 tries on a loaded box; the
#                           probe the same hour saw it hold its X key lock within a second. From run 14 it holds 45
#                           seconds, not 15, a locker that never holds is reported with its state and output, and the
#                           wait is made right before the index lock reads (an idle index's counters can leave the
#                           cache on this instance, and they then start again from 0).]
#       mssql_querystore   the proof's database stored with Query Store READ_WRITE, as its options read
#     [Added after the join of wave 1 (rel-join-w1, 11 collections more), written before their first run here; each
#      status ok and compared with the master user's read of the same view, the collector's filter mirrored:
#       mssql_traceflags   the global flags stored equal DBCC TRACESTATUS(-1)
#       mssql_audit        the server audits (name, type, switched on) and server specifications stored equal
#                          sys.server_audits and sys.server_audit_specifications (RDS's own; none made here)
#       mssql_checks       the server options stored (name, value in use, value set) equal sys.configurations
#       mssql_identity     the identity columns at 10 % of their range or more, per user database the login can enter,
#                          equal sys.identity_columns by the collector's formula; the proof's tinyint column (30) stored
#       mssql_indexes      dbo.big's indexes stored equal sys.indexes; ix_b's user_seeks between the reads before and
#                          after two hinted seeks (2 or more)
#       mssql_stats        st_bb's modifications (5,000 rows changed) and NORECOMPUTE equal sys.dm_db_stats_properties
#                          (the collector's user holds db_datareader in the proof's database: the RDS form gives it)
#       mssql_plancache    mssql_pc_last by the evict bracket against sys.dm_exec_query_stats while a session runs a
#                          parameterized statement in a loop; that statement stored
#       mssql_plancache_health  the proof's database's plans stored equal to both reads when they agree (cycles)
#       mssql_syshealth    the reader's state 'read'; the component results per component and state between the counts
#                          of sp_server_diagnostics_component_result in the session's event files before and after
#       mssql_errorlog     the reader's state 'read'; every stored line of the current log a line of the master user's
#                          read of it; the proof's marker (logged WITH LOG, the instance's own search string) stored
#       mssql_defaulttrace the reader's state 'read'; the DDL events of the proof's database stored equal the default
#                          trace read with the collector's filter
#      Part C: the collections behind each Summary cell run again right before it; no cell reads never, stale or
#      failed; the join's seven tabs render too.]
#     [Runs 16-18, every difference recorded: run 16 Msg 451 on the audit read (catalog collations; COLLATE DATABASE_DEFAULT on
#      every new hand read). Run 17: identity differed by sq's empty line for an empty result (dropped on both sides);
#      stats partial on rdsadmin (finding F8 in the slice report: the collector leaves rdsadmin out on RDS); defaulttrace
#      stored nothing - the RDS form had no ALTER TRACE (now granted: the master user holds it WITH GRANT OPTION; R wants
#      it); syshealth: this instance writes no sp_server_diagnostics_component_result (probe 3), so 0 stored = 0 read
#      with the reader's state 'read' is what is compared, a component row's content NOT PROVEN. Run 18: storage's hand
#      read took tempdb's start size from sys.master_files where the collector takes the database's own
#      sys.database_files (the fixture grew tempdb): mirrored. plancache: the proof's statement keeps its plan handle and
#      gets a new creation time every 2 or 3 seconds, so it is compared by identity (handle, offsets): the collector's
#      newest stored instance was created between the reads' instances, its count bounded by a read's where it is that
#      read's instance; up to five read-collect-read cycles, a cycle where the cache dropped it compares nothing.
#      plancache_health: a cycle passes when both reads agree for the proof's database and the stored counts equal them,
#      up to five cycles (the counts move within seconds here).]
#     [Task 165b, on the release join (written before its first run; s165-onjoin found the proof's list at 32 of 34 and
#      procstats and plancache failing on a cache that recompiled between the reads):
#       mssql_waiting_tasks the proof's own update, waiting LCK_M_X behind the locker in a session of its own: its task
#                          stored (session, wait type, blocker, database) equals the master user's read of the collector's
#                          query (darling_waiting.go: PerformanceMonitor's read and WHERE clause) before and after the run,
#                          the blocker being the locker's session
#       mssql_reports      each part the collector read equal to the master user's read of its query (reports.go): the
#                          server role members (role, login, type, disabled), the SQL logins (name, disabled, policy,
#                          expiration), the services (name, file), the proof's database's tables (rows); the failed logins
#                          of a login the proof attempts under a name no login has, as many stored as the error log
#                          holds within the collector's 3 hours; a part the login cannot read makes the collection
#                          partial: a FAIL with the collector's note (reports.go reads the error log through
#                          xp_readerrorlog / sp_readerrorlog only, not rds_read_error_log as errorlog.go does); the
#                          extended properties part is not compared (the proof's database has none)
#       F13: a procstats or plancache cycle in which the cache churned (nothing stored while it dropped plans between the
#            reads; the proof's procedure stored as a plan neither read lists while the reads list different plans of
#            it) is a dropped cycle and is run again, ten cycles at most for each; at the limit, FAIL with every cycle
#            named. A stored plan neither read lists while both reads list the same plan fails at once.]
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
MADE_DB=; MADE_XE=; MADE_FDB=; WAITER=; SRV=; LOCKER=; LOOPER=
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
# sqmon "<sql>": a read as the collector's login (the databases it can enter), in the form of sq
sqmon() { local out rc=0
  out=$(SQLCMDPASSWORD="$MON_PW" docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$MON_USER" \
  -d master -C -b -I -l 60 -h -1 -s '|' -y 8000 -i /dev/stdin <<<"SET NOCOUNT ON; $1" 2>&1) || rc=$?
  [ $rc -eq 0 ] || { echo "$1" >> "$WORK/sq-failed"; echo "FAIL: a read of the collector's login failed ($rc): $(tr '\n' ' ' <<<"$out" | cut -c1-600) -- the statement: $(tr '\n' ' ' <<<"$1" | cut -c1-300)" >&2; return $rc; }
  sed -E 's/ +\|/|/g; s/\| +/|/g; s/^ +//; s/ +$//' <<<"$out"; }
sqfile() { docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d master -C -b -l 60 -i /dev/stdin; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; }
  for c in $WAITER $LOCKER $LOOPER ${UPD:-}; do docker rm -f "$c" >/dev/null 2>&1 || true; done
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
[ "$R" = "ALTER TRACE,CONNECT SQL,VIEW ANY DEFINITION,VIEW SERVER STATE|0||sysjobactivity,sysjobhistory,sysjobs" ] && echo "R: OK (the RDS form: no CONNECT ANY DATABASE and no msdb db_datareader, which the master user cannot grant)" \
  || bad "R: the collector's login holds '$R' (want ALTER TRACE,CONNECT SQL,VIEW ANY DEFINITION,VIEW SERVER STATE|0||sysjobactivity,sysjobhistory,sysjobs)"

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
# for the join's collections: an identity column past the collector's floor (30 of tinyint's 255 = 11.76 %), a table with a
# nonclustered index and a NORECOMPUTE statistic, and db_datareader for the collector's user (sys.dm_db_stats_properties
# asks SELECT on the table: the stats collection reads partial without it)
sq "CREATE TABLE dbo.idt (id tinyint IDENTITY(1,1) NOT NULL CONSTRAINT pk_idt PRIMARY KEY, x int NOT NULL); INSERT dbo.idt (x) SELECT TOP (30) 0 FROM sys.all_objects;" "$FDB" >/dev/null
sq "CREATE TABLE dbo.big (id int NOT NULL CONSTRAINT pk_big PRIMARY KEY, b int NOT NULL);
  INSERT dbo.big (id, b) SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 0 FROM sys.all_columns a CROSS JOIN sys.all_columns c;
  CREATE INDEX ix_b ON dbo.big (b) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE); CREATE STATISTICS st_bb ON dbo.big (b) WITH NORECOMPUTE;" "$FDB" >/dev/null
sq "ALTER ROLE db_datareader ADD MEMBER [$MON_USER];" "$FDB" >/dev/null
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
  mssql_storage mssql_versionstore mssql_cpu mssql_memory mssql_fileio mssql_tempdb mssql_properties mssql_procstats mssql_indexlocks mssql_querystore
  mssql_audit mssql_checks mssql_defaulttrace mssql_errorlog mssql_identity mssql_indexes mssql_plancache mssql_plancache_health mssql_stats mssql_syshealth mssql_traceflags
  mssql_waiting_tasks mssql_reports)
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
# bracket <collection> <before> <after> <stored> [<key that must be stored>] [evict] [quiet]: every stored key lies between the
# reads before and after (each number), every key counted before is stored. evict, for a cache that drops entries
# between the reads: a stored key compares with each read that lists it, a key both reads list (not reset between
# them) must be stored, and the keys the cache dropped are counted, not required
bracket() {
  local out
  local rc=0
  out=$(python3 - "$2" "$3" "$4" "${5:-}" "${6:-}" <<'PY'
import sys
def rd(p):
    d = {}
    for line in open(p):
        k, *v = line.rstrip("\n").split("|")
        if k: d[k.lower()] = [int(x) for x in v]
    return d
b, a, s = (rd(p) for p in sys.argv[1:4])
must = sys.argv[4].lower()
note = ""
if sys.argv[5] == "evict":
    errs = [f"{k} stored {v}, before {b.get(k)}, after {a.get(k)}" for k, v in s.items()
            if (k in b and any(x < y for x, y in zip(v, b[k]))) or (k in a and any(x > y for x, y in zip(v, a[k])))]
    kept = [k for k in b if k in a and all(x <= y for x, y in zip(b[k], a[k]))]
    errs += [f"{k} listed before and after the run and not stored" for k in kept if k not in s]
    if s and not any(k in b or k in a for k in s) and not errs and not (must and must not in s):
        print(f"{len(s)} stored, {len(b)} before, {len(a)} after{note}"); print("no stored key is listed by either read"); sys.exit(2)
    gone = sum(1 for k in b if k not in a); unread = sum(1 for k in s if k not in b and k not in a)
    note = f"; {len(kept)} listed by both reads, {gone} dropped by the cache between them, {unread} stored and listed by neither"
    if not s and gone and not errs and not must:
        # the cache dropped what the collector could have stored between the reads: a dropped cycle (F13), not a verdict
        print(f"0 stored, {len(b)} before, {len(a)} after{note}"); print("nothing stored: the cache churned between the reads"); sys.exit(2)
else:
    errs = [f"{k} stored {v}, before {b.get(k)}, after {a.get(k)}" for k, v in s.items()
            if k not in a or any(x < y for x, y in zip(v, b.get(k, [0] * len(v)))) or any(x > y for x, y in zip(v, a[k]))]
    errs += [f"{k} counted before the run and not stored" for k in b if k not in s]
if must and must not in s: errs.append(f"{must} not stored")
if not s: errs.append("nothing stored")
print(f"{len(s)} stored, {len(b)} before, {len(a)} after{note}")
if errs: print("; ".join(errs[:8])); sys.exit(1)
PY
  ) || rc=$?
  if [ "${7:-}" = quiet ]; then BR_OUT=$out; return $rc; fi
  if [ $rc -eq 0 ]; then VERDICT[$1]="PASS ($out)"; else VERDICT[$1]="FAIL"; bad "B: $1: $out"; fi
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
PSQL_="SELECT CONVERT(varchar(130), plan_handle, 1) + '@' + CONVERT(varchar(23), cached_time, 121) + '|' + CAST(execution_count AS varchar(20)) FROM sys.dm_exec_procedure_stats WHERE database_id <> 32767"
FDBID=$(sq "SELECT DB_ID(N'$FDB')"); POBJ=$(sq "SELECT OBJECT_ID(N'dbo.pgvproof_p')" "$FDB")
# this instance keeps a procedure in sys.dm_exec_procedure_stats only while a batch runs it (run 13 and its probe: a
# 115 MB memory target, one cached plan): a session runs the proof's procedure in a loop through both reads and the
# collector's run, and is removed after the second read
LOOPER=pgvproof-loop-$SUF
docker run -d --name "$LOOPER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d "$FDB" -C -l 60 \
  -H "$LOOPER" -Q "SET NOCOUNT ON; DECLARE @end datetime2 = DATEADD(second, 600, SYSUTCDATETIME()); WHILE SYSUTCDATETIME() < @end BEGIN EXEC dbo.pgvproof_p; WAITFOR DELAY '00:00:00.050'; END" >/dev/null
HSQL="SELECT ISNULL(MAX(execution_count), 0) FROM sys.dm_exec_procedure_stats WHERE database_id = $FDBID AND object_id = $POBJ"
KSQL="SELECT ISNULL(MAX(CONVERT(varchar(130), plan_handle, 1) + '@' + CONVERT(varchar(23), cached_time, 121)), '') FROM sys.dm_exec_procedure_stats WHERE database_id = $FDBID AND object_id = $POBJ"
HB=0
for _ in $(seq 1 30); do HB=$(sq "$HSQL"); [ "$HB" -ge 1 ] && break; sleep 1; done
# a cycle (read, the collector's run, read) whose stored plan of the proof's procedure neither read lists while the two
# reads list different plans of it (the cache recompiled it between them) is a dropped cycle and is run again, ten
# cycles at most (F13; s165-onjoin: the plan stored at 03:52:38.483, compiled after the first read and gone before
# the second); a stored plan neither read lists while both reads list the same plan fails at once
PSDONE=; PSWHY=
if [ "$HB" -lt 1 ]; then VERDICT[mssql_procstats]="FAIL"; PSDONE=1; bad "B: mssql_procstats: the proof's procedure was never listed by the master user's read while a session ran it in a loop; the looper: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$LOOPER" 2>&1 | tr '\n' ' ') output '$(docker logs "$LOOPER" 2>&1 | tail -5 | tr -s ' \n' ' ' | cut -c1-300)'"; fi
for pcyc in $(seq 1 10); do
  [ -n "$PSDONE" ] && break
  HB=$(sq "$HSQL"); KB=$(sq "$KSQL"); sq "$PSQL_" > "$WORK/p-b.txt"   # the plan list last, right before the run
  run_ok mssql_procstats || { PSDONE=1; break; }
  sq "$PSQL_" > "$WORK/p-a.txt"; HA=$(sq "$HSQL"); KA=$(sq "$KSQL")
  q "select plan_handle || '@' || to_char(cached_time, 'YYYY-MM-DD HH24:MI:SS.MS') || '|' || execution_count from pgvigil.mssql_proc_last where instance_id=$iid" > "$WORK/p-s.txt"
  rc=0; bracket mssql_procstats "$WORK/p-b.txt" "$WORK/p-a.txt" "$WORK/p-s.txt" "" evict quiet || rc=$?
  PX=$(q "select coalesce(max(execution_count), 0) from pgvigil.mssql_proc_last where instance_id=$iid and database_id=$FDBID and object_id=$POBJ")
  PK=$(q "select plan_handle || '@' || to_char(cached_time, 'YYYY-MM-DD HH24:MI:SS.MS') from pgvigil.mssql_proc_last where instance_id=$iid and database_id=$FDBID and object_id=$POBJ order by execution_count desc limit 1")
  if [ $rc -eq 1 ]; then VERDICT[mssql_procstats]="FAIL"; bad "B: mssql_procstats (cycle $pcyc): $BR_OUT"; PSDONE=1; break; fi
  if [ -n "$PK" ] && grep -qiF -- "$PK|" "$WORK/p-b.txt" "$WORK/p-a.txt"; then
    if [ $rc -eq 0 ]; then
      VERDICT[mssql_procstats]="PASS ($(tr '\n' ' ' <<<"$BR_OUT" | cut -c1-200); cycle $pcyc of 10${PSWHY:+; dropped:$PSWHY}); the proof's procedure stored with $PX executions (read $HB before, $HA after$(if [ "$HB" = "$HA" ]; then echo '; the counter did not move between the reads'; fi))"
      PSDONE=1; break
    fi
  fi
  if [ "${KB,,}" != "${KA,,}" ] || [ -z "$KB" ] || [ -z "$KA" ]; then
    PSWHY="$PSWHY cycle $pcyc: stored '$PK' ($PX), read before '$KB', after '$KA': the cache recompiled it between the reads;"
    continue
  fi
  VERDICT[mssql_procstats]="FAIL"; PSDONE=1
  bad "B: mssql_procstats (cycle $pcyc): the proof's procedure (database $FDBID, object $POBJ) stored as '$PK' with $PX execution(s), a plan neither read lists while both list '$KB' (the master user read $HB executions before the run, $HA after it); $(tr '\n' ' ' <<<"$BR_OUT")"
done
if [ -z "$PSDONE" ]; then VERDICT[mssql_procstats]="FAIL"; bad "B: mssql_procstats: no cycle of ten met a stored plan of the proof's procedure in a read:$(cut -c1-900 <<<"$PSWHY")"; fi
docker rm -f "$LOOPER" >/dev/null 2>&1 || true; LOOPER=
# one row lock wait on pk_t: a session holds the row for 45 seconds, the proof's update waits for it
LOCKER=pgvproof-lock-$SUF
docker run -d --name "$LOCKER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d "$FDB" -C -l 60 \
  -H "$LOCKER" -Q "BEGIN TRAN; UPDATE dbo.t WITH (ROWLOCK) SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:01:30'; COMMIT;" >/dev/null
# the proof's update starts only once the locker holds its row (run 10: the container connected after it, no wait)
HELD=0
for _ in $(seq 1 30); do HELD=$(sq "SELECT COUNT(*) FROM sys.dm_tran_locks l JOIN sys.dm_exec_sessions s ON s.session_id = l.request_session_id
  WHERE s.host_name = N'$LOCKER' AND l.resource_type = 'KEY' AND l.request_mode = 'X' AND l.request_status = 'GRANT'"); [ "$HELD" -ge 1 ] && break; sleep 1; done
[ "$HELD" -ge 1 ] || bad "B: the proof's lock wait was not set up: the locker session never held its row; the locker: $(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$LOCKER" 2>&1 | tr '\n' ' ') output '$(docker logs "$LOCKER" 2>&1 | tr -s ' \n' ' ' | cut -c1-300)'; its session as the master user reads it: $(sq "SELECT ISNULL(STRING_AGG(CAST(s.session_id AS varchar(5)) + ':' + s.status + ':' + ISNULL(r.wait_type, '-') + ':' + CAST(ISNULL(r.blocking_session_id, 0) AS varchar(5)), ','), 'none') FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id WHERE s.host_name = N'$LOCKER'" 2>&1 | tr '\n' ' ' || true)"
# mssql_waiting_tasks (F12): the proof's update waits for the locker in a session of its own; the waiting task the
# collector stores for it equals the master user's read of the collector's own query (PerformanceMonitor's read,
# darling_waiting.go waitingSQL: its WHERE clause, the blocker that is the reader itself dropped) before and after the run
UPD=pgvproof-upd-$SUF
docker run -d --name "$UPD" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d "$FDB" -C -l 60 \
  -H "$UPD" -Q "UPDATE dbo.t WITH (ROWLOCK) SET v = v + 1 WHERE id = 1;" >/dev/null
US=
for _ in $(seq 1 30); do US=$(sq "SELECT r.session_id FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = N'$UPD' AND r.wait_type = N'LCK_M_X'"); [ -n "$US" ] && break; sleep 1; done
LBS=$(sq "SELECT MIN(session_id) FROM sys.dm_exec_sessions WHERE host_name = N'$LOCKER'")   # read while the locker surely holds
WTSQL="SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT CAST(wt.session_id AS varchar(9)) + '|' + CAST(wt.wait_type AS nvarchar(60)) COLLATE DATABASE_DEFAULT + '|'
  + ISNULL(CAST(NULLIF(wt.blocking_session_id, @@SPID) AS varchar(9)), '') + '|' + ISNULL(CAST(d.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT, '')
FROM sys.dm_os_waiting_tasks AS wt LEFT JOIN sys.dm_exec_requests AS er ON er.session_id = wt.session_id LEFT JOIN sys.databases AS d ON d.database_id = er.database_id
WHERE wt.session_id >= 50 AND wt.session_id <> @@SPID AND wt.wait_type IS NOT NULL AND er.database_id <> ISNULL(DB_ID(N'PerformanceMonitor'), 0) AND wt.session_id = ${US:-0}"
if [ -z "$US" ]; then VERDICT[mssql_waiting_tasks]="FAIL"; bad "B: mssql_waiting_tasks: the proof's update never waited LCK_M_X behind the locker (the locker held: $HELD)"
else
  sq "$WTSQL" > "$WORK/wt-b.txt"
  if run_ok mssql_waiting_tasks; then sq "$WTSQL" > "$WORK/wt-a.txt"
    q "select session_id || '|' || wait_type || '|' || coalesce(blocking_session_id::text, '') || '|' || coalesce(database_name, '') from pgvigil.mssql_waiting_tasks
       where instance_id=$iid and session_id=$US and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_waiting_summary where instance_id=$iid)" > "$WORK/wt-s.txt"
    sed -i '/^[[:space:]]*$/d' "$WORK/wt-b.txt" "$WORK/wt-a.txt"
    if [ -s "$WORK/wt-s.txt" ] && cmp -s <(LC_ALL=C sort "$WORK/wt-s.txt") <(LC_ALL=C sort "$WORK/wt-b.txt") && cmp -s <(LC_ALL=C sort "$WORK/wt-s.txt") <(LC_ALL=C sort "$WORK/wt-a.txt") \
       && grep -q "^$US|LCK_M_X|$LBS|$FDB\$" "$WORK/wt-s.txt"; then
      VERDICT[mssql_waiting_tasks]="PASS (the proof's update, session $US: $(head -1 "$WORK/wt-s.txt") stored, equal to the master user's read of the collector's query before and after the run; the blocker is the locker's session $LBS)"
    else VERDICT[mssql_waiting_tasks]="FAIL"; bad "B: mssql_waiting_tasks: stored [$(tr '\n' ' ' < "$WORK/wt-s.txt")], the master user read [$(tr '\n' ' ' < "$WORK/wt-b.txt")] before and [$(tr '\n' ' ' < "$WORK/wt-a.txt")] after (want '$US|LCK_M_X|$LBS|$FDB' on all three)"; fi
  fi
fi
docker wait "$UPD" >/dev/null 2>&1 || true; docker rm -f "$UPD" >/dev/null 2>&1 || true; UPD=
docker wait "$LOCKER" >/dev/null 2>&1 || true; docker rm -f "$LOCKER" >/dev/null 2>&1 || true; LOCKER=
# the collector reads only the online databases its login can enter, never the engine's catalog tables (object ids 1 to
# 100: indexlocks.go); the hand read mirrors both, the database list read as the collector's login
IDBS=$(sqmon "SELECT STRING_AGG(CAST(database_id AS varchar(9)), ',') FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1") || IDBS=
case $IDBS in ''|NULL) IDBS=0; bad "B: mssql_indexlocks: the collector's login read no database it can enter";; esac
ISQL="SELECT CAST(database_id AS varchar(9)) + ':' + CAST(object_id AS varchar(12)) + ':' + CAST(index_id AS varchar(9)) + ':' + CAST(partition_number AS varchar(9)) + '|' + CAST(row_lock_wait_count AS varchar(20)) + '|' + CAST(page_lock_wait_count AS varchar(20))
  FROM sys.dm_db_index_operational_stats(NULL, NULL, NULL, NULL) WHERE (row_lock_wait_count > 0 OR page_lock_wait_count > 0 OR index_lock_promotion_attempt_count > 0)
  AND object_id NOT BETWEEN 1 AND 100 AND database_id IN ($IDBS)"
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
# a file's size: sys.master_files, replaced by the database's own sys.database_files where the collector's login can enter it
# (storage.go; tempdb's master_files row keeps its start size) - mirrored from run 18, whose fixture grew tempdb
if run_ok mssql_storage; then
  sq "SELECT CAST(mf.database_id AS varchar(9)) + ':' + CAST(mf.file_id AS varchar(9)) + '=' + CAST(CAST(mf.size AS bigint) * 8192 AS varchar(20)) FROM sys.master_files mf JOIN sys.databases d ON d.database_id = mf.database_id WHERE d.source_database_id IS NULL" > "$WORK/st-mf.txt"
  : > "$WORK/st-df.txt"
  for d in $(sqmon "SELECT name FROM sys.databases WHERE state = 0 AND source_database_id IS NULL AND HAS_DBACCESS(name) = 1") ; do
    sq "SELECT CAST(DB_ID() AS varchar(9)) + ':' + CAST(file_id AS varchar(9)) + '=' + CAST(CAST(size AS bigint) * 8192 AS varchar(20)) FROM sys.database_files" "$d" >> "$WORK/st-df.txt"; done
  HAND=$(awk -F'=' 'NF == 2 { if (FILENAME ~ /st-df/) df[$1] = $2; else mf[$1] = $2 } END { for (k in mf) print k "=" ((k in df) ? df[k] : mf[k]) }' "$WORK/st-mf.txt" "$WORK/st-df.txt" | sort -t: -k1,1n -k2,2n | paste -sd, -)
  eq mssql_storage "$(q "select string_agg(database_id || ':' || file_id || '=' || size_bytes, ',' order by database_id, file_id) from pgvigil.mssql_files where instance_id=$iid and is_present")" "$HAND"
fi
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
# --- the eleven collections of the join of wave 1 (rel-join-w1), written before their first run here: each run as the
# collector's login and compared with the master user's read of the same view, filtered as the collector filters
setcmp() { # setcmp <collection> <stored> <read>: the two lists are equal (sorted in byte order); an empty pair fails
  sed -i '/^[[:space:]]*$/d' "$3"   # sq prints an empty line for an empty result (the read side only)
  if grep -q '^[[:space:]]*$' "$2"; then VERDICT[$1]="FAIL"; bad "B: $1: a stored row has a NULL column (an empty line)"; return; fi
  LC_ALL=C sort -o "$2" "$2"; LC_ALL=C sort -o "$3" "$3"
  if [ ! -s "$2" ] && [ ! -s "$3" ]; then VERDICT[$1]="FAIL"; bad "B: $1: nothing stored and nothing read"; return; fi
  if cmp -s "$2" "$3"; then VERDICT[$1]="PASS ($(wc -l < "$2") rows equal)"
  else VERDICT[$1]="FAIL"; bad "B: $1: stored (<) and read (>) differ: $(diff "$2" "$3" | grep '^[<>]' | head -6 | tr '\n' ' ' | cut -c1-700)"; fi; }
also() { # also <collection> <ok?> <text>: a second check of a collection that passed its first
  if [[ ${VERDICT[$1]:-} == PASS* ]]; then if [ "$2" = 1 ]; then VERDICT[$1]="${VERDICT[$1]}; $3"; else VERDICT[$1]="FAIL"; bad "B: $1: $3"; fi; fi; }
reader_of() { q "select state || '|' || coalesce(scanned::text, '-') || '|' || coalesce(stored::text, '-') || '|' || coalesce(note, '') from pgvigil.mssql_reader_state where instance_id=$iid and reader='$1'"; }
# the user databases the collector's login can enter (identity reads database_id > 4)
UDBS=$(sqmon "SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 AND source_database_id IS NULL AND HAS_DBACCESS(name) = 1 ORDER BY name") || UDBS=

# mssql_traceflags: the global flags stored equal the master user's DBCC TRACESTATUS(-1)
TFSQL="CREATE TABLE #pgvtf (f int, s int, g int, se int); INSERT #pgvtf EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS'); SELECT ISNULL(STRING_AGG(CAST(f AS varchar(6)), ',') WITHIN GROUP (ORDER BY f), '(none)') FROM #pgvtf WHERE g = 1;"
run_ok mssql_traceflags && eq mssql_traceflags "$(q "select coalesce(string_agg(trace_flag::text, ',' order by trace_flag), '(none)') from pgvigil.mssql_trace_flags where instance_id=$iid and is_global")" "$(sq "$TFSQL")"

# mssql_audit: the server audits (name, type, switched on) and server audit specifications (name, switched on) stored
# equal sys.server_audits and sys.server_audit_specifications
if run_ok mssql_audit; then
  { q "select 'audit|' || name || '|' || coalesce(type, '') || '|' || is_enabled::int from pgvigil.mssql_audit where instance_id=$iid and is_present"
    q "select distinct 'spec|' || name || '|' || is_enabled::int from pgvigil.mssql_audit_spec where instance_id=$iid and scope='server' and is_present"; } > "$WORK/au-s.txt"
  { sq "SELECT 'audit|' + name COLLATE DATABASE_DEFAULT + '|' + type COLLATE DATABASE_DEFAULT + '|' + CAST(is_state_enabled AS varchar(1)) FROM sys.server_audits"
    sq "SELECT 'spec|' + name COLLATE DATABASE_DEFAULT + '|' + CAST(is_state_enabled AS varchar(1)) FROM sys.server_audit_specifications"; } > "$WORK/au-h.txt"
  setcmp mssql_audit "$WORK/au-s.txt" "$WORK/au-h.txt"
fi

# mssql_checks: the server options stored (name, value in use, value set) equal sys.configurations
if run_ok mssql_checks; then
  q "select name || '=' || coalesce(value_in_use::text, 'NULL') || '/' || coalesce(value_set::text, 'NULL') from pgvigil.mssql_server_option where instance_id=$iid and is_present" > "$WORK/ck-s.txt"
  sq "SELECT CAST(name AS varchar(128)) COLLATE DATABASE_DEFAULT + '=' + CAST(CAST(value_in_use AS bigint) AS varchar(20)) + '/' + CAST(CAST(value AS bigint) AS varchar(20)) FROM sys.configurations" > "$WORK/ck-h.txt"
  setcmp mssql_checks "$WORK/ck-s.txt" "$WORK/ck-h.txt"
fi

# mssql_identity: the identity columns at 10 % of their type's range or more (dboptions.go's floor) in each user database the
# collector's login can enter equal the master user's read of sys.identity_columns there (the collector's own formula);
# the proof's tinyint column (30 of 255) is among them
if run_ok mssql_identity; then
  q "select database_name || '|' || schema_name || '.' || table_name || '.' || column_name || '|' || type_name || '|' || last_value || '|' || max_value || '|' || pct_used from pgvigil.mssql_identity_column where instance_id=$iid" > "$WORK/id-s.txt"
  : > "$WORK/id-h.txt"
  for d in $UDBS; do sq "SELECT DB_NAME() COLLATE DATABASE_DEFAULT + '|' + s.name COLLATE DATABASE_DEFAULT + '.' + o.name COLLATE DATABASE_DEFAULT + '.' + c.name COLLATE DATABASE_DEFAULT + '|' + ty.name COLLATE DATABASE_DEFAULT + '|' + CAST(CAST(c.last_value AS decimal(38, 0)) AS varchar(40)) + '|' + m.max_text COLLATE DATABASE_DEFAULT + '|'
      + CAST(CAST((CAST(CAST(c.last_value AS decimal(38, 0)) AS float) - b.base) * 100 / (m.max_value - b.base) AS decimal(9, 2)) AS varchar(12))
    FROM sys.identity_columns c JOIN sys.objects o ON o.object_id = c.object_id AND o.type = 'U' JOIN sys.schemas s ON s.schema_id = o.schema_id
    JOIN sys.types ty ON ty.user_type_id = c.system_type_id
    CROSS APPLY (SELECT CASE ty.name WHEN 'tinyint' THEN CAST(255 AS float) WHEN 'smallint' THEN CAST(32767 AS float) WHEN 'int' THEN CAST(2147483647 AS float)
        WHEN 'bigint' THEN CAST(9223372036854775807 AS float) ELSE POWER(CAST(10 AS float), c.precision) - 1 END AS max_value,
      CAST(CASE ty.name WHEN 'tinyint' THEN '255' WHEN 'smallint' THEN '32767' WHEN 'int' THEN '2147483647' WHEN 'bigint' THEN '9223372036854775807'
        ELSE REPLICATE('9', c.precision) END AS varchar(40)) AS max_text) m
    CROSS APPLY (SELECT CASE WHEN CAST(c.seed_value AS decimal(38, 0)) < 0 THEN CAST(CAST(c.seed_value AS decimal(38, 0)) AS float) ELSE CAST(0 AS float) END AS base) b
    WHERE c.last_value IS NOT NULL AND CAST(c.increment_value AS decimal(38, 0)) > 0
      AND (CAST(CAST(c.last_value AS decimal(38, 0)) AS float) - b.base) * 100 / (m.max_value - b.base) >= 10" "$d" >> "$WORK/id-h.txt"; done
  setcmp mssql_identity "$WORK/id-s.txt" "$WORK/id-h.txt"
  also mssql_identity "$(grep -c "^$FDB|dbo.idt.id|tinyint|30|255|11.76$" "$WORK/id-s.txt")" "the proof's column stored (30 of 255, 11.76 %)"
fi

# mssql_indexes: two hinted seeks on dbo.big's ix_b; its stored user_seeks lie between the master user's reads of
# sys.dm_db_index_usage_stats before and after the run (2 or more); the indexes stored for dbo.big equal sys.indexes
sq "SELECT COUNT(*) FROM dbo.big WITH (INDEX(ix_b)) WHERE b = 1; SELECT COUNT(*) FROM dbo.big WITH (INDEX(ix_b)) WHERE b = 2;" "$FDB" >/dev/null
USQL="SELECT CAST(ISNULL(SUM(u.user_seeks), 0) AS varchar(20)) FROM sys.dm_db_index_usage_stats u JOIN sys.indexes i ON i.object_id = u.object_id AND i.index_id = u.index_id
  WHERE u.database_id = DB_ID() AND u.object_id = OBJECT_ID(N'dbo.big') AND i.name = N'ix_b'"
UB=$(sq "$USQL" "$FDB")
if run_ok mssql_indexes; then UA=$(sq "$USQL" "$FDB")
  US=$(q "select coalesce(max(user_seeks), -1) from pgvigil.mssql_index where instance_id=$iid and database_name='$FDB' and table_name='big' and index_name='ix_b'")
  q "select coalesce(index_name, '(heap)') || '|' || index_type from pgvigil.mssql_index where instance_id=$iid and database_name='$FDB' and table_name='big'" > "$WORK/ix-s.txt"
  sq "SELECT ISNULL(name, '(heap)') COLLATE DATABASE_DEFAULT + '|' + type_desc COLLATE DATABASE_DEFAULT FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.big') AND index_id > 0" "$FDB" > "$WORK/ix-h.txt"
  setcmp mssql_indexes "$WORK/ix-s.txt" "$WORK/ix-h.txt"
  also mssql_indexes "$([ "$US" -ge "$UB" ] && [ "$US" -le "$UA" ] && [ "$UA" -ge 2 ] && echo 1 || echo 0)" "ix_b's user_seeks stored $US, the master user read $UB before the run and $UA after it"
fi

# mssql_stats: 5,000 of dbo.big's rows changed; the stored modifications of st_bb (NORECOMPUTE, on b) equal the master
# user's sys.dm_db_stats_properties, read before and after the run (equal both times)
sq "UPDATE dbo.big SET b = b + 1 WHERE id <= 5000;" "$FDB" >/dev/null
SSQL="SELECT CAST(p.modification_counter AS varchar(20)) + '|' + CAST(s.no_recompute AS varchar(1)) FROM sys.stats s CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) p WHERE s.object_id = OBJECT_ID(N'dbo.big') AND s.name = N'st_bb'"
SB=$(sq "$SSQL" "$FDB")
if run_ok mssql_stats; then SA=$(sq "$SSQL" "$FDB")
  eq mssql_stats "$(q "select modifications || '|' || no_recompute::int from pgvigil.mssql_stat where instance_id=$iid and database_name='$FDB' and stats_name='st_bb'")" "$SA"
  also mssql_stats "$([ "$SB" = "$SA" ] && echo 1 || echo 0)" "the counter read the same before and after the run ($SB)"
fi
[[ ${VERDICT[mssql_stats]:-} == PASS* ]] || echo "  the statistics' databases: $(q "select string_agg(database_name || ' ' || database_state || ' read=' || coalesce(read_at::text, '-') || ' ' || coalesce(note, ''), '; ') from pgvigil.mssql_stats_db where instance_id=$iid" | cut -c1-600)"

# mssql_plancache: a session runs a parameterized statement in a loop through both reads and the collector's run (this
# instance's cache keeps a plan only while it is used); mssql_pc_last (each statement's counters as read; a plan is its
# handle, the statement's offsets and its creation time) compares with sys.dm_exec_query_stats by the evict bracket, the
# collector's filter mirrored (the resource database's statements left out); the proof's statement stored
LOOPER=pgvproof-pc-$SUF
docker run -d --name "$LOOPER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$ADMIN_USER" -d "$FDB" -C -l 60 \
  -H "$LOOPER" -Q "SET NOCOUNT ON; DECLARE @end datetime2 = DATEADD(second, 600, SYSUTCDATETIME()); WHILE SYSUTCDATETIME() < @end BEGIN EXEC sys.sp_executesql N'SELECT COUNT(*) FROM dbo.big WHERE b = @b /* pgvproof_pc */', N'@b int', @b = 1; WAITFOR DELAY '00:00:00.050'; END" >/dev/null
QKEY="CONVERT(varchar(130), qs.plan_handle, 1) + '@' + CAST(qs.statement_start_offset AS varchar(12)) + '@' + CAST(qs.statement_end_offset AS varchar(12)) + '@' + CONVERT(varchar(23), qs.creation_time, 121)"
QSQL="SELECT $QKEY + '|' + CAST(qs.execution_count AS varchar(20)) FROM sys.dm_exec_query_stats qs
  OUTER APPLY (SELECT TOP (1) CAST(a.value AS int) AS dbid FROM sys.dm_exec_plan_attributes(qs.plan_handle) a WHERE a.attribute = N'dbid') pa WHERE ISNULL(pa.dbid, 0) <> 32767"
PKSQL="SELECT TOP (1) $QKEY FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE N'(@b int)%pgvproof[_]pc%' ORDER BY qs.execution_count DESC"
for _ in $(seq 1 30); do [ -n "$(sq "$PKSQL")" ] && break; sleep 1; done
# a cycle (read, the collector's run, read) is compared when the cache kept a stored plan across a read: any stored
# plan a read lists must lie between the reads (else FAIL at once); a cycle in which the cache dropped every stored
# plan between the reads compares nothing and is run again, five cycles at most
PCDONE=; PCWHY=; PCBETWEEN=
for cyc in $(seq 1 10); do
  sq "$QSQL" > "$WORK/pc-b.txt"; PKB=$(sq "$PKSQL")
  run_ok mssql_plancache || { PCDONE=1; break; }
  sq "$QSQL" > "$WORK/pc-a.txt"; PKA=$(sq "$PKSQL")
  q "select plan_handle || '@' || stmt_start || '@' || stmt_end || '@' || to_char(creation_time, 'YYYY-MM-DD HH24:MI:SS.MS') || '|' || execution_count from pgvigil.mssql_pc_last where instance_id=$iid" > "$WORK/pc-s.txt"
  rc=0; bracket mssql_plancache "$WORK/pc-b.txt" "$WORK/pc-a.txt" "$WORK/pc-s.txt" "" evict quiet || rc=$?
  if [ $rc -eq 1 ]; then VERDICT[mssql_plancache]="FAIL"; bad "B: mssql_plancache (cycle $cyc): $BR_OUT"; PCDONE=1; break; fi
  # the proof's statement by its plan's identity (handle and statement offsets; run 18: the same handle in every read, a new
  # creation time every 2 or 3 seconds): the collector's newest stored instance was created between the instances the
  # reads list (instances only get newer), and where it is a read's own instance its count respects that read's
  PRE=${PKB%@*}; [ -n "$PRE" ] || PRE=${PKA%@*}
  ST=$(python3 - "$WORK/pc-b.txt" "$WORK/pc-a.txt" "$WORK/pc-s.txt" "$PRE" <<'PY'
import sys
pre = sys.argv[4].lower()
def rows(p):
    out = []
    for line in open(p):
        k, _, v = line.strip().partition("|")
        if pre and k.lower().startswith(pre + "@"): out.append((k.lower()[len(pre) + 1:], int(v)))
    return out
b, a, s = (rows(p) for p in sys.argv[1:4])
if not pre or not b or not a: print("NC a read did not list the proof's statement"); sys.exit()
if not s: print("NC the proof's statement not stored in this cycle"); sys.exit()
(cs, v), (cb, nb), (ca, na) = max(s), max(b), max(a)
if cs < cb or cs > ca or v < 1:
    print(f"FAIL stored created {cs} with {v} execution(s), outside the reads' instances (created {cb} with {nb}, created {ca} with {na})"); sys.exit()
if cb < cs < ca:
    # an instance neither read lists: no count bound to compare; the cycle is run again (the pace bound is the fallback)
    from datetime import datetime
    f = lambda t: datetime.strptime(t, "%Y-%m-%d %H:%M:%S.%f")
    pace = int((f(ca) - f(cs)).total_seconds() / 0.04) + 1
    print(("BETWEEN " if v <= pace else "FAIL ") + f"stored created {cs} with {v} execution(s), an instance neither read lists (created {cb} with {nb}, created {ca} with {na}); the looper's pace allows at most {pace}"); sys.exit()
bad = (cs == cb and v < nb) or (cs == ca and v > na)
print(("FAIL " if bad else "PASS ") + f"stored created {cs} with {v} execution(s), the instance a read lists (created {cb} with {nb}, created {ca} with {na})")
PY
) || ST="FAIL the identity check did not run"
  case $ST in
    FAIL*) VERDICT[mssql_plancache]="FAIL"; bad "B: mssql_plancache (cycle $cyc): the proof's statement ${ST#FAIL }"; PCDONE=1; break;;
    PASS*) VERDICT[mssql_plancache]="PASS ($(tr '\n' ' ' <<<"$BR_OUT" | cut -c1-200); cycle $cyc of 10: the proof's statement ${ST#PASS })"; PCDONE=1; break;;
    BETWEEN*) PCBETWEEN="${ST#BETWEEN }";;
  esac
  PCWHY="$PCWHY cycle $cyc: ${ST#NC };"
done
if [ -z "$PCDONE" ] && [ -n "$PCBETWEEN" ]; then
  VERDICT[mssql_plancache]="PASS, counts NOT PROVEN (no cycle of ten met the collector's instance in a read; identity, creation-time order and the looper's pace checked: $PCBETWEEN)"
elif [ -z "$PCDONE" ]; then VERDICT[mssql_plancache]="FAIL"; bad "B: mssql_plancache: no cycle of ten compared a stored plan with the proof's statement:$(cut -c1-900 <<<"$PCWHY")"; fi

# mssql_plancache_health (the looper still running): the compiled plans per database (plans, single-use, ad hoc, prepared,
# procedure plans; planCachePlansSQL mirrored). The proof's database: stored equal to both reads when they agree; every
# other database both reads list is stored (this cache's counts move up and down between reads)
HPSQL="SELECT DB_NAME(pa.dbid) + '|' + CAST(COUNT_BIG(*) AS varchar(20)) + '|' + CAST(SUM(CASE WHEN cp.usecounts = 1 AND cp.objtype IN (N'Adhoc', N'Prepared') THEN 1 ELSE 0 END) AS varchar(20))
  + '|' + CAST(SUM(CASE WHEN cp.objtype = N'Adhoc' THEN 1 ELSE 0 END) AS varchar(20)) + '|' + CAST(SUM(CASE WHEN cp.objtype = N'Prepared' THEN 1 ELSE 0 END) AS varchar(20))
  + '|' + CAST(SUM(CASE WHEN cp.objtype = N'Proc' THEN 1 ELSE 0 END) AS varchar(20))
  FROM sys.dm_exec_cached_plans cp CROSS APPLY (SELECT TOP (1) CAST(a.value AS int) AS dbid FROM sys.dm_exec_plan_attributes(cp.plan_handle) a WHERE a.attribute = N'dbid') pa
  WHERE cp.cacheobjtype = N'Compiled Plan' AND pa.dbid <> 32767 GROUP BY pa.dbid"
# a cycle passes when both reads agree for the proof's database and the stored counts equal them; this cache's counts
# move within seconds (run 18: the looper's prepared plan absent at the collector's read), so up to five cycles
PHDONE=; PHWHY=
for cyc in 1 2 3 4 5; do
  sq "$HPSQL" > "$WORK/ph-b.txt"
  run_ok mssql_plancache_health || { PHDONE=1; break; }
  sq "$HPSQL" > "$WORK/ph-a.txt"
  q "select database_name || '|' || plans || '|' || single_use || '|' || adhoc_plans || '|' || prepared_plans || '|' || proc_plans from pgvigil.mssql_pc_health where instance_id=$iid" > "$WORK/ph-s.txt"
  prc=0
  out=$(python3 - "$WORK/ph-b.txt" "$WORK/ph-a.txt" "$WORK/ph-s.txt" "$FDB" <<'PY'
import sys
def rd(p):
    d = {}
    for line in open(p):
        k, *v = line.rstrip("\n").split("|")
        if k and v: d[k.lower()] = [int(x) for x in v]
    return d
b, a, s = (rd(p) for p in sys.argv[1:4])
fdb = sys.argv[4].lower()
missing = [k for k in b if k in a and k not in s]
head = f"{len(s)} database(s) stored, {len(b)} read before, {len(a)} after; the proof's database stored {s.get(fdb)}, read {b.get(fdb)} and {a.get(fdb)}"
if missing: print(head + "; read before and after the run and not stored: " + ", ".join(missing)); sys.exit(1)
if b.get(fdb) is None or b.get(fdb) != a.get(fdb): print(head + " (the reads disagree)"); sys.exit(2)
if s.get(fdb) != b[fdb]: print(head); sys.exit(1)
print(head)
PY
  ) || prc=$?
  if [ $prc -eq 0 ]; then VERDICT[mssql_plancache_health]="PASS ($out; cycle $cyc of 5${PHWHY:+; earlier:$PHWHY})"; PHDONE=1; break; fi
  PHWHY="$PHWHY cycle $cyc: $out;"
done
[ -n "$PHDONE" ] || { VERDICT[mssql_plancache_health]="FAIL"; bad "B: mssql_plancache_health: no cycle of five held:$(cut -c1-900 <<<"$PHWHY")"; }
docker rm -f "$LOOPER" >/dev/null 2>&1 || true; LOOPER=

# the three readers keep their own state (read, no right, off, failed): each must say read
# mssql_syshealth: the component results stored per component and state lie between the master user's counts of
# sp_server_diagnostics_component_result in the system_health session's event files before and after the run
XEPAT=$(sq "SELECT LEFT(f, LEN(f) - CHARINDEX('\\', REVERSE(f)) + 1) + 'system_health*.xel' FROM (SELECT CAST(t.target_data AS xml).value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)') AS f
  FROM sys.dm_xe_session_targets t JOIN sys.dm_xe_sessions s ON s.address = t.event_session_address WHERE s.name = N'system_health' AND t.target_name = N'event_file') x") || XEPAT=
SHSQL="SELECT UPPER(x.c) + ':' + UPPER(x.s) + '|' + CAST(COUNT(*) AS varchar(9)) FROM (SELECT e.x.value('(event/data[@name=\"component\"]/text)[1]', 'nvarchar(60)') AS c,
  e.x.value('(event/data[@name=\"state\"]/text)[1]', 'nvarchar(60)') AS s FROM sys.fn_xe_file_target_read_file(N'$XEPAT', NULL, NULL, NULL) f
  CROSS APPLY (SELECT CAST(f.event_data AS xml) AS x) e WHERE f.object_name = N'sp_server_diagnostics_component_result' AND f.timestamp_utc >= DATEADD(day, -45, SYSUTCDATETIME())) x GROUP BY x.c, x.s"
SHN="SELECT CAST(COUNT(*) AS varchar(12)) FROM sys.fn_xe_file_target_read_file(N'$XEPAT', NULL, NULL, NULL)"
sq "$SHSQL" > "$WORK/sh-b.txt" || : > "$WORK/sh-b.txt"; NB=$(sq "$SHN") || NB=0
if run_ok mssql_syshealth; then sq "$SHSQL" > "$WORK/sh-a.txt" || : > "$WORK/sh-a.txt"; NA=$(sq "$SHN") || NA=0
  q "select component || ':' || state || '|' || count(*) from pgvigil.mssql_health_components where instance_id=$iid group by component, state" > "$WORK/sh-s.txt"
  sed -i '/^[[:space:]]*$/d' "$WORK/sh-b.txt" "$WORK/sh-a.txt"
  RS=$(reader_of syshealth); SCN=$(cut -d'|' -f2 <<<"$RS")
  if [ ! -s "$WORK/sh-b.txt" ] && [ ! -s "$WORK/sh-a.txt" ] && [ ! -s "$WORK/sh-s.txt" ]; then
    # this instance writes no sp_server_diagnostics_component_result (probe 3: the session defines it, its files and its
    # ring buffer hold none): what is compared is the reader's own pass over the files
    # the reader's scanned and stored are the component events it kept (syshealth.go: new_events): 0 here, as the files hold
    # the reader went through the files: its cursor names a file of the session (it moves on every event, kept or not)
    CUR=$(q "select coalesce(file_name, '') || '|' || coalesce(file_offset::text, '') from pgvigil.mssql_cursor where instance_id=$iid and source='syshealth'")
    XEDIR=${XEPAT%system_health\*.xel}
    if [ "$RS" = 'read|0|0|' ] && [[ ${CUR,,} == "${XEDIR,,}system_health"*.xel\|[0-9]* ]] && [[ $NB =~ ^[0-9]+$ ]] && [ "$NB" -gt 0 ]; then
      VERDICT[mssql_syshealth]="PASS (0 component results stored, 0 in the session's files, which hold $NB to $NA events of other kinds; the reader's state 'read', 0 kept, its cursor at $CUR; a component row's content NOT PROVEN: this instance writes none)"
    else VERDICT[mssql_syshealth]="FAIL"; bad "B: mssql_syshealth: the reader's state '$RS', its cursor '$CUR', the session's files held $NB events before the run and $NA after ($XEPAT)"; fi
  else
    bracket mssql_syshealth "$WORK/sh-b.txt" "$WORK/sh-a.txt" "$WORK/sh-s.txt"
    [[ ${VERDICT[mssql_syshealth]} == PASS* ]] || echo "  mssql_syshealth: the reader's state '$RS' (the event files $XEPAT)"
    also mssql_syshealth "$([[ $RS == read\|* ]] && echo 1 || echo 0)" "the reader's state '$RS' (the event files $XEPAT)"
  fi
fi

# mssql_errorlog: the proof's marker is the instance's own search string (in the repository); the master user logs it
# (severity 10, WITH LOG); every stored line of the current log is a line of the master user's read of it (time to the
# second and the message's first 60 characters), the marker among them
MARK=pgvproof-marker-$SUF
q "select pgvigil.mssql_errorlog_search_set('$N', array['$MARK'], false)" >/dev/null
sq "RAISERROR(N'$MARK', 10, 1) WITH LOG;" >/dev/null
ELSQL="CREATE TABLE #pgvel (d datetime, p nvarchar(64), t nvarchar(max)); INSERT #pgvel EXEC sys.sp_readerrorlog 0, 1;
  SELECT CONVERT(varchar(19), d, 126) + '|' + LEFT(LTRIM(REPLACE(REPLACE(t, CHAR(13), ' '), CHAR(10), ' ')), 60) FROM #pgvel;"
if run_ok mssql_errorlog; then sq "$ELSQL" > "$WORK/el-h.txt"
  q "select to_char(logged_local, 'YYYY-MM-DD\"T\"HH24:MI:SS') || '|' || left(ltrim(replace(replace(message, chr(13), ' '), chr(10), ' ')), 60) from pgvigil.mssql_errorlog where instance_id=$iid and coalesce(archive, 0) = 0" > "$WORK/el-s.txt"
  sed -i -E 's/ +\|/|/g; s/\| +/|/g; s/^ +//; s/ +$//' "$WORK/el-s.txt"   # sq's own clean-up of the read side
  MISS=$(LC_ALL=C grep -vxFf "$WORK/el-h.txt" "$WORK/el-s.txt" | head -4 | tr '\n' ' ' || true)
  if [ ! -s "$WORK/el-s.txt" ]; then VERDICT[mssql_errorlog]="FAIL"; bad "B: mssql_errorlog: nothing stored of the current log"
  elif [ -n "$MISS" ]; then VERDICT[mssql_errorlog]="FAIL"; bad "B: mssql_errorlog: stored lines the master user's read of the current log does not hold: $(cut -c1-500 <<<"$MISS")"
  else VERDICT[mssql_errorlog]="PASS ($(wc -l < "$WORK/el-s.txt") stored lines, each a line of the master user's read of $(wc -l < "$WORK/el-h.txt"))"; fi
  also mssql_errorlog "$(grep -c -- "$MARK" "$WORK/el-s.txt" | grep -qx '[1-9][0-9]*' && echo 1 || echo 0)" "the marker stored"
  RS=$(reader_of errorlog); also mssql_errorlog "$([[ $RS == read\|* ]] && echo 1 || echo 0)" "the reader's state '$RS'"
fi

# mssql_defaulttrace: the DDL events of the proof's database stored (class, object, start to the second) equal the master
# user's read of the default trace with the collector's filter (defaulttrace.go: classes 46, 47, 164, subclass 1, not
# statistics or a temporary object)
DTP=$(sq "SELECT ISNULL((SELECT TOP (1) CAST(path AS nvarchar(260)) FROM sys.traces WHERE is_default = 1 AND path IS NOT NULL), '')")
DTSQL="SELECT CAST(t.EventClass AS varchar(4)) + '|' + ISNULL(CAST(t.ObjectName AS nvarchar(256)), '') + '|' + CONVERT(varchar(19), t.StartTime, 126) FROM sys.fn_trace_gettable(N'$DTP', DEFAULT) t
  WHERE t.DatabaseName = N'$FDB' AND t.EventClass IN (46, 47, 164) AND t.EventSubClass = 1 AND ISNULL(t.ObjectType, 0) NOT IN (21587, 17747)"
if run_ok mssql_defaulttrace; then sq "$DTSQL" > "$WORK/dt-h.txt"
  q "select event_class || '|' || coalesce(object_name, '') || '|' || to_char(logged_local, 'YYYY-MM-DD\"T\"HH24:MI:SS') from pgvigil.mssql_trace_events where instance_id=$iid and database_name='$FDB'" > "$WORK/dt-s.txt"
  RS=$(reader_of defaulttrace)
  setcmp mssql_defaulttrace "$WORK/dt-s.txt" "$WORK/dt-h.txt"
  [[ $RS == read\|* ]] || RS="$RS (the collector's login: ALTER TRACE $(sqmon "SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE'), 0) AS varchar(1))" || echo '?'); the master user's own: $(sq "SELECT ISNULL(STRING_AGG(state_desc, ','), 'none') FROM sys.server_permissions WHERE grantee_principal_id = SUSER_ID() AND permission_name = N'ALTER TRACE'" || echo '?'))"
  [[ ${VERDICT[mssql_defaulttrace]} == PASS* ]] || echo "  mssql_defaulttrace: the reader's state '$RS'"
  also mssql_defaulttrace "$([[ $RS == read\|* ]] && echo 1 || echo 0)" "the reader's state '$RS'"
fi
# mssql_reports (F12): each part the collector read equals the master user's read of the collector's own query
# (reports.go): the server role members, the SQL logins, the services, the proof's database's tables (rows), and the
# failed logins of a login the proof attempts with a name no login has, as many stored as the error log holds; the
# extended properties part is not compared (the proof's database has none). A part the login cannot read makes the
# collection partial (run_ok's FAIL with the collector's note).
NL=pgvproof_nl_$SUF
SQLCMDPASSWORD=Nx9$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')a! docker run --rm -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$RDS_HOST,$PORT_" -U "$NL" -C -l 30 -Q "SELECT 1" >/dev/null 2>&1 || true
if run_ok mssql_reports; then
  PARTS=$(q "select string_agg(part || '=' || status, ' ' order by part) from pgvigil.report_read_state where instance_id=$iid")
  FLST=$(q "select status || '|' || coalesce(note, '') from pgvigil.report_read_state where instance_id=$iid and part='failed_logins'")
  { q "select 'role|' || role_name || '|' || login_name || '|' || coalesce(login_type, '') || '|' || coalesce(is_disabled::int::text, '') from pgvigil.mssql_server_role_members where instance_id=$iid and is_present"
    q "select 'login|' || login_name || '|' || coalesce(is_disabled::int::text, '') || '|' || coalesce(is_policy_checked::int::text, '') || '|' || coalesce(is_expiration_checked::int::text, '') from pgvigil.mssql_sql_logins where instance_id=$iid and is_present"
    q "select 'service|' || service_name || '|' || coalesce(filename, '') from pgvigil.mssql_service_ext where instance_id=$iid"
    q "select 'table|' || schema_name || '.' || table_name || '|' || coalesce(row_count::text, '') from pgvigil.mssql_table_size where instance_id=$iid and database_name='$FDB' and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_table_size where instance_id=$iid and database_name='$FDB')"
    if [[ $FLST == read\|* ]]; then q "select 'failed|$NL|' || count(*) from pgvigil.mssql_failed_logins where instance_id=$iid and login_name='$NL'"; fi
  } > "$WORK/rp-s.txt"
  { sq "SELECT 'role|' + CAST(r.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '|' + CAST(m.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '|' + CAST(m.type AS nvarchar(2)) COLLATE DATABASE_DEFAULT + '|' + CAST(CAST(m.is_disabled AS int) AS varchar(1))
      FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id"
    sq "SELECT 'login|' + CAST(l.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '|' + CAST(CAST(l.is_disabled AS int) AS varchar(1)) + '|' + CAST(CAST(l.is_policy_checked AS int) AS varchar(1)) + '|' + CAST(CAST(l.is_expiration_checked AS int) AS varchar(1))
      FROM sys.sql_logins l WHERE l.name NOT LIKE '##%##'"
    sq "SELECT 'service|' + CAST(servicename AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '|' + ISNULL(CAST(filename AS nvarchar(512)) COLLATE DATABASE_DEFAULT, '') FROM sys.dm_server_services"
    sq "SELECT 'table|' + CAST(s.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '.' + CAST(o.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT + '|' + CAST(SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) AS varchar(20))
      FROM sys.dm_db_partition_stats ps JOIN sys.objects o ON o.object_id = ps.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
      WHERE o.type = 'U' AND o.is_ms_shipped = 0 GROUP BY s.name, o.name" "$FDB"
    if [[ $FLST == read\|* ]]; then sq "CREATE TABLE #pgvfl (d datetime, p nvarchar(64), t nvarchar(max)); INSERT #pgvfl EXEC sys.sp_readerrorlog 0, 1, N'Login failed', N'$NL';
      SELECT 'failed|$NL|' + CAST(COUNT(*) AS varchar(9)) FROM #pgvfl WHERE d >= DATEADD(hour, -3, GETDATE());"; fi
  } > "$WORK/rp-h.txt"
  setcmp mssql_reports "$WORK/rp-s.txt" "$WORK/rp-h.txt"
  also mssql_reports "$(grep -q '^table|dbo\.' "$WORK/rp-s.txt" && echo 1 || echo 0)" "the proof's database's tables stored"
  if [[ $FLST == read\|* ]]; then also mssql_reports "$(grep -q "^failed|$NL|[1-9]" "$WORK/rp-s.txt" && echo 1 || echo 0)" "the proof's failed login ($NL) stored"
  else also mssql_reports 0 "the failed_logins part not stored as read: '$FLST'"; fi
  also mssql_reports 1 "parts: $PARTS"
fi
echo "  the collections:"
for c in "${ALL[@]}"; do printf '    %-20s %s\n' "$c" "${VERDICT[$c]:-FAIL (no verdict)}"; done

echo "--- D. nothing of pgvigil created on the server"
snap > "$WORK/after.txt"
if diff "$WORK/before.txt" "$WORK/after.txt" > "$WORK/d.diff"; then echo "D: OK ($(wc -l < "$WORK/after.txt") principals, permissions, sessions, databases and objects unchanged)"
else bad "D: the server changed under the collector: $(tr '\n' ' ' < "$WORK/d.diff" | cut -c1-400)"; fi

echo "--- C. the pages"
if [ -n "${PGVIGIL_SKIP_PAGES:-}" ]; then echo "C: NOT RUN (PGVIGIL_SKIP_PAGES)"; FAILS+=("C: not run")
else
  # the collections behind each Summary cell run again now (q_mssql_summary.go's groups): the Summary calls a read older
  # than its window stale, and the proof's own order put minutes between B's first collections and this page
  for c in mssql_requests mssql_xe mssql_ag mssql_mirroring mssql_logshipping mssql_replication mssql_backups mssql_jobs mssql_storage mssql_versionstore \
           mssql_instance mssql_services mssql_querystore mssql_audit; do "$BIN" collect -config "$CFG" -once "$c" -instance "$N" > "$WORK/$c-c.out" 2>&1 || true; done
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  "$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
  for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -fs "http://127.0.0.1:$PORT/api/mssql/summary" > "$WORK/sum.json" || { cat "$WORK/serve.log" >&2; die "C: GET /api/mssql/summary"; }
  # cells is a table: {columns: [...], rows: [[...], ...]}
  GOT=$(jq -r --argjson i "$iid" '.cells as $t | ($t.columns | index("instance_id")) as $ci | ($t.columns | index("key")) as $ck | ($t.columns | index("state")) as $cs
    | [$t.rows[] | select(.[$ci] == $i) | "\(.[$ck])=\(.[$cs])"] | sort | join(" ")' "$WORK/sum.json")
  if grep -qE '=(never|stale|failed)' <<<"$GOT" || ! grep -qE 'availability=(ok|n/a)' <<<"$GOT"; then bad "C: the summary cells '$GOT' (want availability ok or n/a and no 'never', 'stale' or 'failed')"; else echo "  summary cells: OK ($GOT)"; fi
  if command -v chromium >/dev/null; then
    page() { timeout 60 chromium --headless=new --no-sandbox --disable-gpu --user-data-dir="$WORK/chrome" --virtual-time-budget=15000 --dump-dom "http://127.0.0.1:$PORT/#/$1?i=$iid&w=1h" 2>/dev/null; }
    page summary > "$WORK/p-summary.html" || true
    grep -q 'rdssqlserver' "$WORK/p-summary.html" || bad "C: the Summary page does not show the platform badge rdssqlserver"
    NTABS=0
    for tab in summary performance mssql_running mssql_slow mssql_waits mssql_deadlocks mssql_blocked findings availability mssqlbackups mssqljobs mssqlstorage mssqlfiles \
               rowversions mssqlconfig mssqlactions jobstimeline mssqlcpu mssqlmemory mssqlfileio mssqltempdb mssqlqs counters mssqlprocs mssqlindexlocks mssqlproperties \
               mssqlplancache mssqlindexes mssqlaudit mssqlchecks mssqlerrorlog mssqltrace mssqlhealth; do
      NTABS=$((NTABS + 1))
      page "$tab" > "$WORK/p-$tab.html" || true
      if [ ! -s "$WORK/p-$tab.html" ] || grep -q 'class="error"' "$WORK/p-$tab.html"; then bad "C: tab $tab did not render: $(grep -o 'class="error"[^<]*<' "$WORK/p-$tab.html" | head -1)"; fi
      # an unknown tab falls back to the Summary page: a tab of its own must not be that page
      if [ "$tab" != summary ] && grep -qF 'aria-current="page">Summary</a>' "$WORK/p-$tab.html"; then bad "C: tab $tab opened the Summary page (no route for it in the embedded app)"; fi
    done
    echo "  pages rendered: $NTABS tabs"
  else bad "C: chromium is not on this machine: the pages were not rendered"; fi
fi

[ ! -s "$WORK/sq-failed" ] || bad "a read of the setup login failed during the run (its message is above): $(head -c 300 "$WORK/sq-failed" | tr '\n' ' ')"
echo
if [ ${#FAILS[@]} -eq 0 ]; then
  NP=0; NS=0; for c in "${ALL[@]}"; do case ${VERDICT[$c]:-} in PASS*) NP=$((NP + 1));; SKIP*) NS=$((NS + 1));; esac; done
  echo "proof-mssql-rds: PASS (R, A, B: $NP collected and equal, $NS skipped by an RDS rule (mssql_ag: no Always On, mssql_logshipping: no log shipping on RDS, mssql_jobs: the msdb tables the master user cannot grant); C; D)"
else
  echo "the failed items:"; printf '  - %s\n' "${FAILS[@]}"
  echo "proof-mssql-rds: FAIL (${#FAILS[@]} item(s))"; exit 1
fi
