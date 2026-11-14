#!/usr/bin/env bash
# Proof of pgvigil's SQL Server engine on Azure SQL Database: the platform and the engine edition are detected,
# every SQL Server collection either stores what the setup login reads from the same view or is skipped by a
# platform rule that says so, the instance's pages render with the platform's lines, and the collector creates
# nothing in the monitored database.
#
# Needs, on the machine that reads the database (its address admitted by the server's firewall): docker (sqlcmd
# runs from PGVIGIL_SQLCMD_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest; nothing is installed), psql,
# curl, jq, python3, chromium (the pages), a go toolchain at the repository root unless PGVIGIL_BIN names a built
# binary, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the repository is made there)
#   PGVIGIL_LAB_STATE   the lab's state file, default .lab/azure-sqldb.env (scripts/lab/azure-sqldb.sh up, allow,
#                       logins): the server, the database, the setup login (the server admin) and the collector's
#                       contained user, with their passwords. Passwords reach sqlcmd and the collector through the
#                       environment by name; none is printed.
# Settings: PGVIGIL_SKIP_PAGES=1 leaves out part C (said as NOT RUN, and the verdict is then not PASS).
#           PGVIGIL_PROOF_B2A_ONLY=1 runs R, A, the B2a rows and D only (a Basic / S0 / S1 / pooled database).
#
# What it makes, and removes on every exit path the shell can catch: a repository database pgvigil_azproof_<n> on
# the PostgreSQL; in the monitored database, as its DBA would (pgvigil prints the script, the DBA runs it), the four
# Extended Events sessions of `pgvigil mssql-xe -print -form azuresqldb -install-id p<n>` (dropped by the -drop
# script at the end); one session of the setup login that waits two minutes (part B's requests read); a global
# temporary table ##pgvproof_wt_<n> (tempdb, per database on Azure SQL Database) held 90 s by a holder session of the
# setup login, with a waiter session blocked on its row (part B's waiting tasks; both sessions removed after the read).
#
# Expected (written before the first run):
#  R. the rights: the collector's user is a contained database user (authentication DATABASE) holding CONNECT and
#     VIEW DATABASE STATE and nothing else, in no role (docs/sqlserver.md's Azure SQL Database line).
#  A. detection: `collect -once mssql_instance` as the collector stores the instance as engine sqlserver, platform
#     azuresqldb, server_version_num 120000 (Azure SQL Database answers 12.0 whatever engine it runs); mssql_instance
#     holds the setup login's ProductVersion, Edition ('SQL Azure'), EngineEdition 5 and server name.
#  B. each of the 38 SQL Server collections (21 before the join of wave 1, 32 before mssql_waiting_tasks and mssql_reports
#     joined, 34 before B2a: its two, and mssql_activity and mssql_pool, which joined without a row here) (the list is
#     checked against internal/mssql's Name() functions):
#     RUN - status ok, never partial, and rows equal to the setup login's read of the same view:
#       mssql_instance  sys.configurations' row count and 'max server memory (MB)' value_in_use; sysinfo_read true
#                       and cpu_count = sys.dm_os_sys_info's
#       mssql_requests  the setup login's session waiting on WAITFOR is stored with the session id, command and
#                       wait type the setup login reads for it in sys.dm_exec_requests
#       mssql_waits     source sys.dm_db_wait_stats; every wait type stored lies between the setup login's read just
#                       before and just after the run (waiting tasks and wait ms), and every type the read before
#                       counted is stored
#       mssql_xe        one state per capture (deadlocks, blocked, slow, attention) equal to the setup login's read of
#                       sys.database_event_sessions / sys.dm_xe_database_sessions for pgvigil_p<n>_<capture>:
#                       running for each of the four once the -form azuresqldb script ran
#       mssql_waiting_tasks  [added at the release join, written before its first run here] status ok, never partial,
#                       its read stored (one mssql_waiting_summary row) with as many task rows as the row says it kept;
#                       [165b, written before its first run:] a blocked pair the setup login makes on a global temp
#                       table (a holder's open UPDATE, a waiter's UPDATE of the same row waiting LCK_M_X): the waiter's
#                       task stored (session, wait type, blocker = the holder, database) equals the setup login's read of
#                       the collector's query (darling_waiting.go, PerformanceMonitor's WHERE clause) before and after
#     SKIP - status skipped, the note names Azure SQL Database, the run prints "skipped:", and the collection's own
#       tables hold no row for the instance: mssql_services, mssql_ag, mssql_mirroring, mssql_logshipping,
#       mssql_replication, mssql_jobs, mssql_backups, mssql_storage, mssql_versionstore, mssql_cpu, mssql_memory,
#       mssql_fileio, mssql_tempdb, mssql_properties, mssql_procstats, mssql_indexlocks, mssql_querystore.
#       [Added after the join of wave 1 (rel-join-w1, 11 collections more; written before their first run here): mssql_audit,
#        mssql_checks, mssql_defaulttrace, mssql_errorlog, mssql_identity, mssql_indexes, mssql_plancache,
#        mssql_plancache_health, mssql_stats, mssql_syshealth, mssql_traceflags - each skipped by its Azure SQL Database
#        rule, its own tables empty for the instance. Microsoft's pages for the five the platform has no object for:
#        audit (auditing writes to a storage account, Log Analytics or Event Hubs), default trace ('SQL Server trace' is
#        not supported), error log (sp_readerrorlog applies to SQL Server only), system_health (no built-in session),
#        trace flags (instance configuration not supported); docs/sqlserver-cloud.md cites each page.
#        Added at the release join: mssql_reports, skipped by its own rule (no server roles, SQL logins or service
#        list of its own to read), its seven tables empty for the instance.]
#       [B2a, written before their first run here: mssql_activity (skipped by its Azure SQL Database rule, its read
#        tables empty) and mssql_pool (on a database outside a pool skipped 'not in an elastic pool (service
#        objective ...)', no member row).]
#     A skip is never counted as collected or as failed; a RUN collection skipped for a missing right is a FAIL.
#     [B2a, written before the first run of these rows:]
#       mssql_storage   (RUN since B2a) the database's own files: file id, name, type, size, max size and filegroup
#                       equal to the setup login's read of sys.database_files; every file's used space read; no
#                       volume row; the 'max size' finding present only when the setup login's PRIMARY data files'
#                       allocated / max size is over 80 %
#       mssql_azuredb_governance  one current row whose 54 compared columns (pgvigil.mssql_azuredb_gov_compared)
#                       equal the setup login's read of sys.dm_user_db_resource_governance; edition and service
#                       objective equal to DATABASEPROPERTYEX; one history row, eleven Properties rows, no change
#                       row; a second read minutes later opens no history row
#       mssql_azuredb_resources  a 32 s CPU loop of the setup login (the burst), a first read, a second read from
#                       the cursor once the burst's minutes are complete: no minute missing between the two reads'
#                       newest minutes and no gap row; every stored minute whose 15-second rows are all still in
#                       the view equals the setup login's read of them (the averages within 0.00006, the maxima,
#                       DBA Dash's DTU %, the sample count and the four bucket lists exact; only the two oldest
#                       stored minutes may have lost rows in the view since; a stored minute with fewer samples
#                       than the view's rows is a FAIL); a minute of the burst holds max CPU >= 50 and over its
#                       average (on a DTU tier max DTU % >= 50 too); with the cursor set three hours back a third
#                       read is ok and stores one gap row from that minute's end
#       the missing rights, as a contained user of the proof holding CONNECT only (made before part D's first read,
#                       dropped at the end): mssql_azuredb_resources skipped 'the login lacks VIEW DATABASE STATE:
#                       the database's resource use is not readable', mssql_azuredb_governance skipped with its
#                       sentence, mssql_storage ok (any user of the database reads its files)
#     On Basic, S0, S1 and in an elastic pool the collector's least-privilege user lacks the server-level right the
#     other RUN rows need (NOT PROVEN HERE below): there PGVIGIL_PROOF_B2A_ONLY=1 runs R, A (the instance row), these
#     B2a rows and D only - mssql_azuredb_resources as the contained user (VIEW DATABASE STATE on every tier; the DTU
#     columns filled), mssql_azuredb_governance as the contained user skipped 'the login lacks
#     ##MS_ServerStateReader## (Basic, S0, S1 and elastic pools): the tier's limits are not readable' and as the
#     server admin ok with the tier's dtu_limit - and the last line says 'B2a rows only'.
#  C. the pages: GET /api/mssql/summary gives the instance blocking, events and uptime [B2a: and filespace, pctmax and
#     dbstate (mssql_storage runs; disk is n/a: no volumes)] as ok and every other cell
#     the tree's Summary has as n/a (every collection of the group skipped; the keys are read from the API, not
#     listed here: task P08 made them DBA Dash's, e.g. full/diff/log for backups) [the collections that feed an ok
#     cell run again right before C, so no cell reads stale from the proof's own order]; the Summary page renders (chromium) with the platform badge azuresqldb and names no n/a group as "not read
#     yet"; each SQL Server tab of the instance renders without an error line, and each tab whose collections are
#     all skipped here says so (the skip's own text, or "not on this platform") [at the release join: the Storage
#     folder's Drives, DB Space, Files and Drive Performance too, and Waiting tasks renders] [165b: the Reports folder's
#     fourteen tabs render; the six of mssql_reports (Database Extended Properties, Failed Logins, Server Role Members,
#     Server Services, SQL Login Password Age, Table Size) each say mssql_reports is skipped here (web/src/main.ts's
#     mssqlTabRuns holds the six since 43c3fbb, F14; reports.ts has no text naming Azure SQL Database, so the check
#     catches a lost mssqlTabRuns entry)].
#  D. nothing of pgvigil is created in the monitored database: its objects (not shipped by Microsoft), principals,
#     permissions, role members and event sessions read by the setup login after the proof's own setup equal the
#     same read after every collector run.
#  The last line is "proof-mssql-azuresqldb: PASS (...)" and the exit code 0 only when R, A, B, C and D hold; else
#  every failed item is listed with its text, the last line says FAIL with their count, and the exit code is 1.
#  NOT PROVEN HERE: Azure SQL Managed Instance, an elastic pool, the Basic / S0 / S1 tiers (where the server-state
#  DMVs ask for the server admin instead of VIEW DATABASE STATE), Microsoft Entra authentication, a geo-replica.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
STATE=${PGVIGIL_LAB_STATE:-.lab/azure-sqldb.env}
IMG=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
for t in docker psql curl jq python3; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
[ -r "$STATE" ] || { echo "FAIL: no lab state file $STATE (scripts/lab/azure-sqldb.sh up, allow, logins)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
: "${AZ_HOST:?} ${AZ_DB:?} ${ADMIN_USER:?} ${ADMIN_PW:?} ${MON_USER:?} ${MON_PW:?}"
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_azproof_$SUF; XEID=p$SUF; N=proof-azuresqldb-$SUF; HOSTTAG=pgvproof-$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
export SQLCMDPASSWORD="$ADMIN_PW"
export AZ_MON_DSN="sqlserver://$MON_USER:$MON_PW@$AZ_HOST:${AZ_PORT:-1433}?database=$AZ_DB&encrypt=true"
MADE_DB=; MADE_XE=; WAITER=; SRV=; MADE_NR=
B2A=${PGVIGIL_PROOF_B2A_ONLY:-}
NR_USER=pgvproof_nr_$SUF; NR_PW=$(printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')")
export AZ_NR_DSN="sqlserver://$NR_USER:$NR_PW@$AZ_HOST:${AZ_PORT:-1433}?database=$AZ_DB&encrypt=true"
export AZ_ADMIN_DSN="sqlserver://$ADMIN_USER:$ADMIN_PW@$AZ_HOST:${AZ_PORT:-1433}?database=$AZ_DB&encrypt=true"
FAILS=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
# (sqlcmd: -I sets QUOTED_IDENTIFIER ON, which the xml methods need (Msg 1934 without it); -W cuts a value at 256 characters and cannot go with -y; -y 8000 pads each column, the padding is
# stripped around each separator and at both ends of the line - no value read here starts or ends with a space)
# sq "<sql>": rows as the setup login, '|' between columns, NULL as NULL; the statement goes on stdin
sq() { local out rc=0
  out=$(docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" \
  -d "$AZ_DB" -C -b -I -l 60 -h -1 -s '|' -y 8000 -i /dev/stdin <<<"SET NOCOUNT ON; $1" 2>&1) || rc=$?
  # a failed read stops the proof with sqlcmd's own message, never a silent empty value
  [ $rc -eq 0 ] || { echo "$1" >> "$WORK/sq-failed"; echo "FAIL: a read of the setup login failed ($rc): $(tr '\n' ' ' <<<"$out" | cut -c1-600) -- the statement: $(tr '\n' ' ' <<<"$1" | cut -c1-300)" >&2; return $rc; }
  sed -E 's/ +\|/|/g; s/\| +/|/g; s/^ +//; s/ +$//' <<<"$out"; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null || true; }
  [ -n "$WAITER" ] && { docker rm -f "$WAITER" >/dev/null 2>&1 || true; }
  for c in ${HOLDER:-} ${WTR:-}; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  if [ -n "$MADE_XE" ]; then "$BIN" mssql-xe -print -drop -form azuresqldb -install-id "$XEID" > "$WORK/xe-drop.sql" 2>/dev/null \
    && docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -i /dev/stdin < "$WORK/xe-drop.sql" >/dev/null 2>&1 \
    || echo "CLEANUP: the event sessions pgvigil_${XEID}_* were NOT dropped" >&2; fi
  if [ -n "$MADE_NR" ]; then docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -i /dev/stdin <<<"DROP USER IF EXISTS [$NR_USER];" >/dev/null 2>&1 \
    || echo "CLEANUP: the proof's user $NR_USER was NOT dropped" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else
  command -v go >/dev/null || die "go is not on this machine and PGVIGIL_BIN names no binary"
  CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi

echo "--- the database answers (a paused serverless database wakes on the first login: up to 3 minutes)"
for i in $(seq 1 12); do sq "SELECT 1" >/dev/null 2>&1 && break; [ "$i" = 12 ] && die "the setup login gets no answer from $AZ_HOST/$AZ_DB"; sleep 15; done
rm -f "$WORK/sq-failed"   # the tries before the first answer are the wait, not failed reads
IFS='|' read -r PV ED EE SN <<<"$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), CAST(SERVERPROPERTY('Edition') AS nvarchar(128)), CAST(SERVERPROPERTY('EngineEdition') AS int), CAST(SERVERPROPERTY('ServerName') AS nvarchar(128))")"
echo "  the setup login reads: $PV | $ED | engine edition $EE | $SN"

echo "--- R. the collector's rights"
R=$(sq "SELECT p.authentication_type_desc + '|' + ISNULL((SELECT STRING_AGG(permission_name, ',') WITHIN GROUP (ORDER BY permission_name) FROM sys.database_permissions WHERE grantee_principal_id = p.principal_id AND state IN ('G', 'W')), '') + '|' + CAST((SELECT COUNT(*) FROM sys.database_role_members WHERE member_principal_id = p.principal_id) AS varchar(9)) FROM sys.database_principals p WHERE p.name = N'$MON_USER'")
echo "  $MON_USER: $R"
[ "$R" = "DATABASE|CONNECT,VIEW DATABASE STATE|0" ] && echo "R: OK" || bad "R: the collector's user holds '$R' (want DATABASE|CONNECT,VIEW DATABASE STATE|0)"

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N
    engine: sqlserver
    dsn: env:AZ_MON_DSN
  - name: $N-nr
    engine: sqlserver
    dsn: env:AZ_NR_DSN
  - name: $N-admin
    engine: sqlserver
    dsn: env:AZ_ADMIN_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
SO=$(sq "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(128))")
LOWTIER=; case "$SO" in Basic|S0|S1|ElasticPool) LOWTIER=1 ;; esac
echo "  service objective: $SO${LOWTIER:+ (the server-level right branch)}${B2A:+; B2a rows only}"
[ -z "$LOWTIER" ] || [ -n "$B2A" ] || die "the database is $SO: the collector's least-privilege user lacks the server-level right the other rows need there; run with PGVIGIL_PROOF_B2A_ONLY=1"
# the proof's own user for the missing-right rows: CONNECT only (a contained user gets CONNECT with CREATE USER);
# its statement goes through a mode-600 file, never a command line or the output
MADE_NR=1
( umask 077; printf "CREATE USER [%s] WITH PASSWORD = '%s';\n" "$NR_USER" "$NR_PW" > "$WORK/nr.sql" )
docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -i /dev/stdin < "$WORK/nr.sql" > "$WORK/nr.out" 2>&1 \
  || bad "B: the proof's CONNECT-only user was not made (sqlcmd exit $?; its output is not printed: it may name the statement)"
rm -f "$WORK/nr.sql"

# the proof's own setup, as the database's DBA: pgvigil's Extended Events script for this form
if [ -z "$B2A" ]; then
"$BIN" mssql-xe -print -form azuresqldb -install-id "$XEID" > "$WORK/xe.sql"
MADE_XE=1
if ! docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -i /dev/stdin < "$WORK/xe.sql" > "$WORK/xe.out" 2>&1; then
  bad "B: pgvigil's -form azuresqldb Extended Events script failed as the DBA: $(tr '\n' ' ' < "$WORK/xe.out" | cut -c1-600)"
fi
fi
snap() { sq "SELECT 'obj|' + s.name + '.' + o.name + '|' + o.type COLLATE DATABASE_DEFAULT FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id WHERE o.is_ms_shipped = 0
  UNION ALL SELECT 'principal|' + name + '|' + type COLLATE DATABASE_DEFAULT FROM sys.database_principals
  UNION ALL SELECT 'perm|' + ISNULL(USER_NAME(grantee_principal_id), '?') + '|' + permission_name + '|' + state_desc + '|' + class_desc + '|' + CAST(major_id AS varchar(12)) COLLATE DATABASE_DEFAULT FROM sys.database_permissions
  UNION ALL SELECT 'member|' + USER_NAME(role_principal_id) + '|' + USER_NAME(member_principal_id) COLLATE DATABASE_DEFAULT FROM sys.database_role_members
  UNION ALL SELECT 'xe|' + name COLLATE DATABASE_DEFAULT FROM sys.database_event_sessions
  ORDER BY 1"; }
snap > "$WORK/before.txt"

echo "--- A. detection"
"$BIN" collect -config "$CFG" -once mssql_instance -instance "$N" | tee "$WORK/mssql_instance.out" || true
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
[ -n "$iid" ] || die "A: the instance was not stored (the run above says why)"
maj=${PV%%.*}; rest=${PV#*.}; min=${rest%%.*}
GOT=$(q "select i.engine || '|' || i.platform || '|' || i.server_version_num || '|' || m.product_version || '|' || m.edition || '|' || m.engine_edition || '|' || m.server_name from pgvigil.instances i join pgvigil.mssql_instance m using (instance_id) where instance_id=$iid")
WANT="sqlserver|azuresqldb|$((maj * 10000 + 10#$min))|$PV|$ED|$EE|$SN"
if [ -n "$B2A" ]; then # on a low tier mssql_instance's own rows wait for the right: the instance row is the detection
  GOT=$(q "select engine || '|' || platform || '|' || server_version_num from pgvigil.instances where instance_id=$iid")
  [ "$GOT" = "sqlserver|azuresqldb|120000" ] && [ "$EE" = 5 ] && echo "A: OK ($GOT; the instance row only: B2a rows only)" || bad "A: stored '$GOT', want 'sqlserver|azuresqldb|120000' with engine edition 5"
else
[ "$GOT" = "$WANT" ] && [ "$EE" = 5 ] && [ "$((maj * 10000 + 10#$min))" = 120000 ] && echo "A: OK ($GOT)" || bad "A: stored '$GOT', want '$WANT' with engine edition 5 and 120000"
fi

echo "--- B. every collection"
mapfile -t KNOWN < <(grep -ho 'Name() string *{ return Prefix + "[a-z_]*"' $(ls internal/mssql/*.go | grep -v _test.go) | sed 's/.*Prefix + "\([a-z_]*\)"/mssql_\1/' | sort)
RUNS=(mssql_instance mssql_requests mssql_waits mssql_xe mssql_waiting_tasks mssql_azuredb_resources mssql_azuredb_governance mssql_storage)
B2ARUNS=(mssql_azuredb_resources mssql_azuredb_governance mssql_storage)
SKIPS=(mssql_services mssql_ag mssql_mirroring mssql_logshipping mssql_replication mssql_jobs mssql_backups mssql_versionstore mssql_cpu mssql_memory mssql_fileio mssql_tempdb mssql_properties mssql_procstats mssql_indexlocks mssql_querystore
  mssql_audit mssql_checks mssql_defaulttrace mssql_errorlog mssql_identity mssql_indexes mssql_plancache mssql_plancache_health mssql_stats mssql_syshealth mssql_traceflags
  mssql_reports mssql_activity mssql_pool)
# the word a skip's note must hold: the platform's name, or for mssql_pool on a database outside a pool its own reason
declare -A SKIPWORD=([mssql_pool]="not in an elastic pool")
[ "$(printf '%s\n' "${KNOWN[@]}" | tr '\n' ' ')" = "$(printf '%s\n' "${RUNS[@]}" "${SKIPS[@]}" | sort | tr '\n' ' ')" ] \
  || bad "B: the collections of internal/mssql (${KNOWN[*]}) are not the proof's list"
declare -A TABLES=([mssql_services]="mssql_service mssql_health" [mssql_ag]="mssql_ag_state mssql_ag_database_state" [mssql_mirroring]="mssql_mirroring_state"
  [mssql_logshipping]="mssql_logshipping_state" [mssql_replication]="mssql_replication_state" [mssql_jobs]="mssql_jobs mssql_job_runs" [mssql_backups]="mssql_backup_state"
  [mssql_versionstore]="mssql_versionstore_db mssql_versionstore_sample" [mssql_cpu]="mssql_cpu_sample mssql_sched_sample"
  [mssql_memory]="mssql_memory_sample mssql_memory_clerk" [mssql_fileio]="mssql_fileio_last" [mssql_tempdb]="mssql_tempdb mssql_tempdb_files"
  [mssql_properties]="mssql_property" [mssql_procstats]="mssql_proc_last" [mssql_indexlocks]="mssql_indexlock_last" [mssql_querystore]="mssql_qs_store"
  [mssql_audit]="mssql_audit mssql_audit_spec mssql_audit_events" [mssql_checks]="mssql_check_finding mssql_server_option mssql_database_option mssql_build"
  [mssql_defaulttrace]="mssql_trace_events" [mssql_errorlog]="mssql_errorlog" [mssql_identity]="mssql_identity_column mssql_identity_scan"
  [mssql_indexes]="mssql_index mssql_index_db mssql_missing_index" [mssql_plancache]="mssql_pc_last mssql_pc_sample" [mssql_plancache_health]="mssql_pc_health"
  [mssql_stats]="mssql_stat mssql_stats_db" [mssql_syshealth]="mssql_health_components" [mssql_traceflags]="mssql_trace_flags"
  [mssql_reports]="mssql_server_role_members mssql_sql_logins mssql_failed_logins mssql_service_ext mssql_table_size report_db_properties report_read_state"
  [mssql_activity]="mssql_activity_read mssql_counter_read mssql_session_summary" [mssql_pool]="mssql_pool_member")
declare -A VERDICT
status_of() { q "select coalesce(status, '') || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='$1'"; }
status_for() { q "select coalesce(status, '') || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$1 and collection='$2'"; }
run_ok() { # run_ok <collection>: runs it, and says whether it stored a read with status ok
  "$BIN" collect -config "$CFG" -once "$1" -instance "$N" > "$WORK/$1.out" 2>&1 || true
  local st; st=$(status_of "$1")
  if [[ $st == ok\|* ]]; then return 0; fi
  VERDICT[$1]="FAIL"; bad "B: $1 status '$st' (want ok), the run said '$(tr '\n' ' ' < "$WORK/$1.out" | cut -c1-300)'"; return 1
}
other_rows() { # every row but B2a's: not run with PGVIGIL_PROOF_B2A_ONLY
for c in "${SKIPS[@]}"; do
  "$BIN" collect -config "$CFG" -once "$c" -instance "$N" > "$WORK/$c.out" 2>&1 || true
  st=$(status_of "$c"); rows=0; cnt=ok
  for t in ${TABLES[$c]}; do
    n=$(q "select count(*) from pgvigil.$t where instance_id=$iid") || n=x
    [[ $n =~ ^[0-9]+$ ]] || { bad "B: $c: no count of pgvigil.$t"; n=0; cnt=no; }
    rows=$((rows + n))
  done
  word=${SKIPWORD[$c]:-Azure SQL Database}
  if [[ $st == skipped\|*"$word"* ]] && grep -q "skipped: " "$WORK/$c.out" && [ "$rows" = 0 ]; then VERDICT[$c]="SKIP (${st#skipped|})"
  else VERDICT[$c]="FAIL"; bad "B: $c should be skipped with a note holding '$word': status '$st', $rows stored row(s), the run said '$(tr '\n' ' ' < "$WORK/$c.out" | cut -c1-300)'"; fi
  [ "$cnt" = ok ] || VERDICT[$c]="FAIL (no count of a table)"
done
# mssql_instance (run in A): the configuration and the system info
st=$(status_of mssql_instance)
if [[ $st == ok\|* ]]; then
  IFS='|' read -r NCFG MAXMEM CPU <<<"$(sq "SELECT (SELECT COUNT(*) FROM sys.configurations), (SELECT CAST(value_in_use AS bigint) FROM sys.configurations WHERE name = 'max server memory (MB)'), (SELECT cpu_count FROM sys.dm_os_sys_info)")"
  GOT=$(q "select (select count(*) from pgvigil.mssql_config where instance_id=$iid) || '|' || coalesce((select value_in_use::text from pgvigil.mssql_config where instance_id=$iid and name='max server memory (MB)'), 'NULL') || '|' || (select sysinfo_read || '|' || coalesce(cpu_count::text, 'NULL') from pgvigil.mssql_instance where instance_id=$iid)")
  [ "$GOT" = "$NCFG|$MAXMEM|true|$CPU" ] && VERDICT[mssql_instance]="PASS" || { VERDICT[mssql_instance]="FAIL"; bad "B: mssql_instance stored '$GOT', the setup login reads '$NCFG|$MAXMEM|true|$CPU'"; }
else VERDICT[mssql_instance]="FAIL"; bad "B: mssql_instance status '$st' (want ok)"; fi
# mssql_requests: a session of the setup login that waits on WAITFOR
WAITER=pgvproof-wait-$SUF
docker run -d --name "$WAITER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -l 60 -H "$HOSTTAG" -Q "WAITFOR DELAY '00:02:00'" >/dev/null
WSID=
for _ in $(seq 1 30); do WSID=$(sq "SELECT r.session_id FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = N'$HOSTTAG' AND r.wait_type = N'WAITFOR'"); [ -n "$WSID" ] && break; sleep 2; done
if [ -z "$WSID" ]; then VERDICT[mssql_requests]="FAIL"; bad "B: mssql_requests: the waiting session never showed in the setup login's read"
elif run_ok mssql_requests; then
  HAND=$(sq "SELECT CAST(r.session_id AS varchar(9)) + '|' + r.command + '|' + r.wait_type FROM sys.dm_exec_requests r WHERE r.session_id = $WSID")
  GOT=$(q "select session_id || '|' || command || '|' || wait_type from pgvigil.mssql_requests where instance_id=$iid and session_id=$WSID order by snapshot_at desc limit 1")
  [ -n "$GOT" ] && [ "$GOT" = "$HAND" ] && VERDICT[mssql_requests]="PASS" || { VERDICT[mssql_requests]="FAIL"; bad "B: mssql_requests stored '$GOT' for session $WSID, the setup login reads '$HAND'"; }
fi
docker rm -f "$WAITER" >/dev/null 2>&1 || true; WAITER=
# mssql_waits: bracketed by the setup login's reads before and after the run
WSQL="SELECT wait_type + '|' + CAST(waiting_tasks_count AS varchar(20)) + '|' + CAST(wait_time_ms AS varchar(20)) FROM sys.dm_db_wait_stats WHERE waiting_tasks_count > 0 OR wait_time_ms > 0"
sq "$WSQL" > "$WORK/w-before.txt"
if run_ok mssql_waits; then
  sq "$WSQL" > "$WORK/w-after.txt"
  q "select wait_type || '|' || waiting_tasks || '|' || wait_ms from pgvigil.mssql_wait_last where instance_id=$iid" > "$WORK/w-stored.txt"
  SRC=$(q "select string_agg(distinct source, ',') from pgvigil.mssql_wait_state where instance_id=$iid" 2>/dev/null || echo '?')
  if OUT=$(python3 - "$WORK/w-before.txt" "$WORK/w-after.txt" "$WORK/w-stored.txt" <<'PY'
import sys
def rd(p):
    d = {}
    for line in open(p):
        k, *v = line.rstrip("\n").split("|")
        if k: d[k] = [int(x) for x in v]
    return d
b, a, s = (rd(p) for p in sys.argv[1:4])
errs = [f"{k} stored {v}, before {b.get(k)}, after {a.get(k)}" for k, v in s.items()
        if k not in a or any(x < y for x, y in zip(v, b.get(k, [0, 0]))) or any(x > y for x, y in zip(v, a[k]))]
errs += [f"{k} counted before the run and not stored" for k in b if k not in s]
if not s: errs.append("nothing stored")
print(f"{len(s)} wait types stored, {len(b)} before, {len(a)} after")
if errs: print("; ".join(errs[:8])); sys.exit(1)
PY
  ); then
    [[ $SRC == *sys.dm_db_wait_stats* ]] && VERDICT[mssql_waits]="PASS ($OUT)" || { VERDICT[mssql_waits]="FAIL"; bad "B: mssql_waits source '$SRC' (want sys.dm_db_wait_stats)"; }
  else VERDICT[mssql_waits]="FAIL"; bad "B: mssql_waits: $OUT"; fi
fi
# mssql_waiting_tasks (165b): a blocked pair the setup login makes on a global temp table (in tempdb, so nothing joins
# the database's own objects that part D compares): the holder updates its row in an open transaction, the waiter updates
# the same row and waits LCK_M_X; the waiter's task stored (session, wait type, blocker, database) equals the setup
# login's read of the collector's query (darling_waiting.go: PerformanceMonitor's read and WHERE clause, the blocker
# that is the reader itself dropped) before and after the run; the newest read's own counts agree (stored = its task rows)
GT="##pgvproof_wt_$SUF"; HOLDER=pgvproof-hold-$SUF; WTR=pgvproof-wtr-$SUF
docker run -d --name "$HOLDER" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -l 60 \
  -H "$HOLDER" -Q "SET NOCOUNT ON; CREATE TABLE $GT (id int PRIMARY KEY, v int); INSERT $GT VALUES (1, 0); BEGIN TRAN; UPDATE $GT SET v = 1 WHERE id = 1; WAITFOR DELAY '00:01:30'; COMMIT;" >/dev/null
HSID=
for _ in $(seq 1 45); do HSID=$(sq "SELECT r.session_id FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = N'$HOLDER' AND r.wait_type = N'WAITFOR'"); [ -n "$HSID" ] && break; sleep 2; done
WSID2=
if [ -n "$HSID" ]; then
  docker run -d --name "$WTR" -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -l 60 \
    -H "$WTR" -Q "UPDATE $GT SET v = 2 WHERE id = 1;" >/dev/null
  for _ in $(seq 1 30); do WSID2=$(sq "SELECT r.session_id FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = N'$WTR' AND r.wait_type = N'LCK_M_X'"); [ -n "$WSID2" ] && break; sleep 2; done
fi
WTSQL="SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT CAST(wt.session_id AS varchar(9)) + '|' + CAST(wt.wait_type AS nvarchar(60)) COLLATE DATABASE_DEFAULT + '|'
  + ISNULL(CAST(NULLIF(wt.blocking_session_id, @@SPID) AS varchar(9)), '') + '|' + ISNULL(CAST(d.name AS nvarchar(256)) COLLATE DATABASE_DEFAULT, '')
FROM sys.dm_os_waiting_tasks AS wt LEFT JOIN sys.dm_exec_requests AS er ON er.session_id = wt.session_id LEFT JOIN sys.databases AS d ON d.database_id = er.database_id
WHERE wt.session_id >= 50 AND wt.session_id <> @@SPID AND wt.wait_type IS NOT NULL AND er.database_id <> ISNULL(DB_ID(N'PerformanceMonitor'), 0) AND wt.session_id = ${WSID2:-0}"
if [ -z "$HSID" ] || [ -z "$WSID2" ]; then
  VERDICT[mssql_waiting_tasks]="FAIL"; bad "B: mssql_waiting_tasks: the blocked pair was not made (holder '$HSID' waiting WAITFOR, waiter '$WSID2' waiting LCK_M_X); the holder said '$(docker logs "$HOLDER" 2>&1 | tr -s ' \n' ' ' | cut -c1-300)', the waiter '$(docker logs "$WTR" 2>&1 | tr -s ' \n' ' ' | cut -c1-300)'"
else
  sq "$WTSQL" > "$WORK/wt-b.txt"
  if run_ok mssql_waiting_tasks; then sq "$WTSQL" > "$WORK/wt-a.txt"
    sed -i '/^[[:space:]]*$/d' "$WORK/wt-b.txt" "$WORK/wt-a.txt"
    q "select session_id || '|' || wait_type || '|' || coalesce(blocking_session_id::text, '') || '|' || coalesce(database_name, '') from pgvigil.mssql_waiting_tasks
       where instance_id=$iid and session_id=$WSID2 and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_waiting_summary where instance_id=$iid)" > "$WORK/wt-s.txt"
    GOT=$(q "select s.stored || '|' || s.tasks || '|' || (select count(*) from pgvigil.mssql_waiting_tasks t where t.instance_id=s.instance_id and t.snapshot_at=s.snapshot_at) from pgvigil.mssql_waiting_summary s where s.instance_id=$iid order by s.snapshot_at desc limit 1")
    IFS='|' read -r KEPT SEEN NT <<<"$GOT"
    if [ -s "$WORK/wt-s.txt" ] && cmp -s <(LC_ALL=C sort "$WORK/wt-s.txt") <(LC_ALL=C sort "$WORK/wt-b.txt") && cmp -s <(LC_ALL=C sort "$WORK/wt-s.txt") <(LC_ALL=C sort "$WORK/wt-a.txt") \
       && grep -q "^$WSID2|LCK_M_X|$HSID|$AZ_DB\$" "$WORK/wt-s.txt" && [ "$KEPT" = "$NT" ] && [ "$KEPT" -le "$SEEN" ]; then
      VERDICT[mssql_waiting_tasks]="PASS (the waiter, session $WSID2: $(head -1 "$WORK/wt-s.txt") stored, equal to the setup login's read of the collector's query before and after the run, the blocker the holder $HSID; the read $SEEN task(s) seen, $NT stored)"
    else VERDICT[mssql_waiting_tasks]="FAIL"; bad "B: mssql_waiting_tasks: stored [$(tr '\n' ' ' < "$WORK/wt-s.txt")], the setup login read [$(tr '\n' ' ' < "$WORK/wt-b.txt")] before and [$(tr '\n' ' ' < "$WORK/wt-a.txt")] after (want '$WSID2|LCK_M_X|$HSID|$AZ_DB' on all three); the newest read '$GOT'"; fi
  fi
fi
docker rm -f "$WTR" "$HOLDER" >/dev/null 2>&1 || true; WTR=; HOLDER=
# mssql_xe: one state per capture, as the setup login reads the sessions
if run_ok mssql_xe; then
  HAND=$(sq "SELECT c.capture + '|' + CASE WHEN x.name IS NOT NULL THEN 'running' WHEN d.name IS NOT NULL THEN 'stopped' ELSE 'not installed' END
    FROM (VALUES ('attention'), ('blocked'), ('deadlocks'), ('slow')) c(capture)
    LEFT JOIN sys.database_event_sessions d ON d.name = N'pgvigil_${XEID}_' + c.capture
    LEFT JOIN sys.dm_xe_database_sessions x ON x.name = d.name ORDER BY 1" | tr '\n' ' ')
  GOT=$(q "select capture || '|' || state from pgvigil.mssql_xe_state where instance_id=$iid order by 1" | tr '\n' ' ')
  [ "$GOT" = "$HAND" ] && [ "$HAND" = "attention|running blocked|running deadlocks|running slow|running " ] && VERDICT[mssql_xe]="PASS" \
    || { VERDICT[mssql_xe]="FAIL"; bad "B: mssql_xe stored '$GOT', the setup login reads '$HAND' (want all four running)"; }
fi
}
[ -n "$B2A" ] || other_rows

# ---- B2a's rows (the header's list)
run_as() { # run_as <instance name> <collection>: one run as that instance's login, its output kept
  "$BIN" collect -config "$CFG" -once "$2" -instance "$1" > "$WORK/$2.$1.out" 2>&1 || true; }
# mssql_storage: the database's own files, as the setup login reads them (a file set not to grow has its size as its max)
if run_ok mssql_storage; then
  FSQL="SELECT CAST(df.file_id AS varchar(9)) + '|' + df.name + '|' + CAST(df.type_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT + '|' + CAST(CAST(df.size AS bigint) * 8192 AS varchar(20)) + '|' + ISNULL(CAST(CASE WHEN df.max_size = -1 THEN NULL WHEN df.max_size = 0 THEN CAST(df.size AS bigint) * 8192 ELSE CAST(df.max_size AS bigint) * 8192 END AS varchar(20)), 'NULL') + '|' + ISNULL(fg.name, 'NULL') FROM sys.database_files df LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id ORDER BY df.file_id"
  sq "$FSQL" > "$WORK/files-hand.txt"; sed -i '/^[[:space:]]*$/d' "$WORK/files-hand.txt"
  q "select file_id || '|' || file_name || '|' || type_desc || '|' || size_bytes || '|' || coalesce(max_size_bytes::text, 'NULL') || '|' || coalesce(filegroup, 'NULL') from pgvigil.mssql_files where instance_id=$iid and is_present order by file_id" > "$WORK/files-stored.txt"
  NFILES=$(wc -l < "$WORK/files-hand.txt")
  USED=$(q "select count(*) filter (where used_read) || ' of ' || count(*) from pgvigil.mssql_files where instance_id=$iid and is_present")
  VOLS=$(q "select count(*) from pgvigil.mssql_volumes where instance_id=$iid")
  PCT=$(sq "SELECT CASE WHEN MIN(df.max_size) < 0 THEN 'unlimited' ELSE CAST(CAST(100.0 * SUM(CAST(df.size AS bigint)) / NULLIF(SUM(CAST(CASE WHEN df.max_size = 0 THEN df.size ELSE df.max_size END AS bigint)), 0) AS decimal(9,3)) AS varchar(20)) END FROM sys.database_files df WHERE df.type = 0 AND df.data_space_id = 1")
  NF=$(q "select count(*) from pgvigil.mssql_storage_findings where instance_id=$iid and check_name like '%max size%'")
  WANTF=0; if [ "$PCT" != unlimited ] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 80 else 1)' "$PCT"; then WANTF=1; fi
  if [ "$NFILES" -gt 0 ] && cmp -s "$WORK/files-hand.txt" "$WORK/files-stored.txt" && [ "$USED" = "$NFILES of $NFILES" ] && [ "$VOLS" = 0 ] && [ "$NF" = "$WANTF" ]; then
    VERDICT[mssql_storage]="PASS ($NFILES file(s) equal to the setup login's sys.database_files, the used space read on each, no volume row; the PRIMARY data files hold $PCT % of their max size allocated: $NF max size finding(s))"
  else VERDICT[mssql_storage]="FAIL"; bad "B: mssql_storage stored [$(tr '\n' ' ' < "$WORK/files-stored.txt")] (used read on $USED, $VOLS volume row(s), $NF max size finding(s)); the setup login reads [$(tr '\n' ' ' < "$WORK/files-hand.txt")] with $PCT % of the max size allocated (want $WANTF finding(s))"; fi
fi
# mssql_azuredb_governance: on a low tier the contained user is skipped with the tier's sentence and the server admin reads it
gov_state() { # the stored tier of instance $1 against the setup login's read in $WORK/gov-hand.json
  psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -v hand="$(cat "$WORK/gov-hand.json")" -v id="$1" <<'SQL' || true
select (pgvigil.mssql_azuredb_gov_compared(g.gov) = pgvigil.mssql_azuredb_gov_compared(:'hand'::jsonb)) || '|' ||
       (select count(*) from jsonb_object_keys(pgvigil.mssql_azuredb_gov_compared(g.gov))) || '|' || coalesce(g.edition, '') || '|' || coalesce(g.service_objective, '') || '|' ||
       (select count(*) from pgvigil.mssql_azuredb_governance_history h where h.instance_id = g.instance_id) || '|' ||
       (select count(*) from pgvigil.mssql_property p where p.instance_id = g.instance_id and p.grp = 'Azure SQL Database') || '|' ||
       (select count(*) from pgvigil.mssql_property_change c where c.instance_id = g.instance_id) || '|' || coalesce(g.dtu_limit::text, 'NULL') || '|' || coalesce(g.usage_mb::text, 'NULL')
  from pgvigil.mssql_azuredb_governance g where g.instance_id = :id
SQL
}
GOVN=$N; GOVID=$iid; LOWSKIP=
if [ -n "$LOWTIER" ]; then
  run_as "$N" mssql_azuredb_governance; st=$(status_of mssql_azuredb_governance)
  WANTS="skipped|the login lacks ##MS_ServerStateReader## (Basic, S0, S1 and elastic pools): the tier's limits are not readable"
  if [ "$st" = "$WANTS" ]; then LOWSKIP="; as the contained user skipped: ${st#skipped|}"; else LOWSKIP="; the contained user's skip FAILED"; bad "B: mssql_azuredb_governance as the contained user on $SO: '$st' (want '$WANTS')"; fi
  GOVN=$N-admin
fi
run_as "$GOVN" mssql_azuredb_governance
GOVID=$(q "select instance_id from pgvigil.instances where name='$GOVN'")
st=$(status_for "${GOVID:-0}" mssql_azuredb_governance)
GOVOK=
if [[ $st != ok\|* ]]; then VERDICT[mssql_azuredb_governance]="FAIL"; bad "B: mssql_azuredb_governance as $GOVN: status '$st' (want ok), the run said '$(tr '\n' ' ' < "$WORK/mssql_azuredb_governance.$GOVN.out" | cut -c1-300)'"
else
  sq "SELECT (SELECT * FROM sys.dm_user_db_resource_governance WHERE database_id = DB_ID() FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER)" > "$WORK/gov-hand.json"
  IFS='|' read -r HED HSO <<<"$(sq "SELECT CAST(DATABASEPROPERTYEX(DB_NAME(), 'Edition') AS nvarchar(128)) + '|' + CAST(DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective') AS nvarchar(128))")"
  GOV1=$(gov_state "$GOVID")
  IFS='|' read -r GEQ GKEYS GED GSO GHIST GPROPS GCHG GDTU GUSE1 <<<"$GOV1"
  if [ "$GEQ" = true ] && [ "$GED" = "$HED" ] && [ "$GSO" = "$HSO" ] && [ "$GHIST" = 1 ] && [ "$GPROPS" = 11 ] && [ "$GCHG" = 0 ] && { [ -z "$LOWTIER" ] || [[ $GDTU =~ ^[1-9][0-9]*$ ]]; }; then GOVOK=1
  else VERDICT[mssql_azuredb_governance]="FAIL"; bad "B: mssql_azuredb_governance as $GOVN stored '$GOV1' (compared columns equal | their count | edition | service objective | history rows | Properties rows | changes | dtu_limit | usage MB); want 'true|n|$HED|$HSO|1|11|0|${LOWTIER:+a DTU limit}|...'"; fi
fi
# mssql_azuredb_resources: the burst, a first read, a read from the cursor, the hand read, the forced gap
N1BAD=(); N1SAY=
sq "DECLARE @t datetime2 = SYSUTCDATETIME(), @i bigint = 0; WHILE DATEDIFF(second, @t, SYSUTCDATETIME()) < 32 SET @i += 1; SELECT 1" >/dev/null
B1=$(sq "SELECT CONVERT(varchar(19), SYSUTCDATETIME(), 126)")   # the burst's end, the server's UTC
if run_ok mssql_azuredb_resources; then
  NEW1=$(q "select coalesce(to_char(newest_minute at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS+00'), '') from pgvigil.mssql_azuredb_read where instance_id=$iid")
  # the burst's rows end by its end + 15 s: their minutes are complete (the collector's 30 s) 155 s after its end's minute began
  WAITS=$(sq "SELECT DATEDIFF(second, SYSUTCDATETIME(), DATEADD(second, 155, DATEADD(minute, DATEDIFF(minute, 0, CONVERT(datetime, '$B1', 126)), 0)))")
  if [[ $WAITS =~ ^[0-9]+$ ]] && [ "$WAITS" -gt 0 ]; then echo "  mssql_azuredb_resources: waiting $WAITS s for the burst's minutes to be complete"; sleep "$WAITS"; fi
  if run_ok mssql_azuredb_resources; then
    IFS='|' read -r CN CSPAN CGAPS NEW2 <<<"$(q "select count(*) || '|' || coalesce((extract(epoch from max(snapshot_at) - min(snapshot_at)) / 60 + 1)::int, 0) || '|' || (select count(*) from pgvigil.mssql_azuredb_gap g where g.instance_id=$iid) || '|' || coalesce(to_char(max(snapshot_at) at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS+00'), '') from pgvigil.mssql_azuredb_minute where instance_id=$iid ${NEW1:+and snapshot_at >= '$NEW1'}")"
    [ "$CN" -ge 2 ] && [ "$CN" = "$CSPAN" ] && [ "$CGAPS" = 0 ] || N1BAD+=("from the cursor: $CN minute(s) stored over a span of $CSPAN since the first read's newest (${NEW1:-none}), $CGAPS gap row(s); want no minute missing and no gap")
    sq "SELECT CONVERT(varchar(23), end_time, 126) + '|' + ISNULL(CAST(avg_cpu_percent AS varchar(20)), '') + '|' + ISNULL(CAST(avg_data_io_percent AS varchar(20)), '') + '|' + ISNULL(CAST(avg_log_write_percent AS varchar(20)), '') + '|' + ISNULL(CAST(avg_memory_usage_percent AS varchar(20)), '') + '|' + ISNULL(CAST(dtu_limit AS varchar(20)), '') FROM sys.dm_db_resource_stats" > "$WORK/rs-hand.txt"
    q "select to_char(snapshot_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI') || '|' || samples || '|' || coalesce(avg_cpu_percent::text, '') || '|' || coalesce(max_cpu_percent::text, '') || '|' || coalesce(avg_data_io_percent::text, '') || '|' || coalesce(max_data_io_percent::text, '') || '|' || coalesce(avg_log_write_percent::text, '') || '|' || coalesce(max_log_write_percent::text, '') || '|' || coalesce(avg_memory_usage_percent::text, '') || '|' || coalesce(max_memory_usage_percent::text, '') || '|' || coalesce(avg_dtu_percent::text, '') || '|' || coalesce(max_dtu_percent::text, '') || '|' || array_to_string(dtu_buckets, ',') || '|' || array_to_string(cpu_buckets, ',') || '|' || array_to_string(data_buckets, ',') || '|' || array_to_string(log_buckets, ',') from pgvigil.mssql_azuredb_minute where instance_id=$iid order by snapshot_at" > "$WORK/rs-stored.txt"
    if OUT=$(python3 - "$WORK/rs-hand.txt" "$WORK/rs-stored.txt" <<'PY'
import sys, datetime as D
from collections import defaultdict
def num(x): return None if x == "" else float(x)
hand = defaultdict(list)
for line in open(sys.argv[1]):
    p = line.rstrip("\n").split("|")
    if len(p) != 6 or not p[0]: continue
    m = (D.datetime.fromisoformat(p[0]) - D.timedelta(microseconds=1)).replace(second=0, microsecond=0)  # a row ending on the minute is the minute before's
    hand[m.strftime("%Y-%m-%dT%H:%M")].append([num(x) for x in p[1:]])
def bucket(v): return 0 if v < 10 else min(int(v // 10), 9)
def counts(vals):
    b = [0] * 10
    for v in vals: b[bucket(v)] += 1
    return b
def want(rows):
    w = {}
    for i, k in enumerate(("cpu", "data", "log", "mem")):
        vals = [r[i] for r in rows if r[i] is not None]
        w["avg_" + k], w["max_" + k] = (sum(vals) / len(vals), max(vals)) if vals else (None, None)
        if k != "mem": w["b_" + k] = counts(vals)
    dtu = [max(v for v in r[:3] if v is not None) for r in rows if r[4] is not None and r[4] > 0 and any(v is not None for v in r[:3])]
    w["avg_dtu"], w["max_dtu"] = (sum(dtu) / len(dtu), max(dtu)) if dtu else (None, None)
    w["b_dtu"] = counts(dtu)
    return w
stored = []
for line in open(sys.argv[2]):
    p = line.rstrip("\n").split("|")
    if len(p) != 16: continue
    g = dict(zip(("avg_cpu", "max_cpu", "avg_data", "max_data", "avg_log", "max_log", "avg_mem", "max_mem", "avg_dtu", "max_dtu"), (num(x) for x in p[2:12])))
    for k, x in zip(("b_dtu", "b_cpu", "b_data", "b_log"), p[12:16]): g[k] = [int(v) for v in x.split(",")]
    stored.append((p[0], int(p[1]), g))
errs, equal, trimmed = [], 0, 0
for i, (minute, samples, g) in enumerate(stored):
    rows = hand.get(minute, [])
    if len(rows) < samples:  # the view dropped rows of this minute since the collector's read
        trimmed += 1
        if i > 1: errs.append(f"{minute}: {samples} samples stored, {len(rows)} rows in the view, and it is not one of the two oldest stored minutes")
        continue
    if len(rows) > samples:
        errs.append(f"{minute}: stored short - {samples} samples, the view holds {len(rows)} rows"); continue
    w = want(rows)
    for k, v in w.items():
        s = g[k]
        if isinstance(v, list): ok = s == v
        elif v is None or s is None: ok = v is None and s is None
        else: ok = abs(s - v) <= (0.00006 if k.startswith("avg") else 0.005)
        if not ok: errs.append(f"{minute}: {k} stored {s}, the view's rows give {v}")
    equal += 1
print(f"{equal} minute(s) equal to the setup login's 15-second rows, {trimmed} no longer whole in the view, {len(stored)} stored")
if equal == 0: errs.append("no stored minute could be compared")
if errs: print("; ".join(errs[:8])); sys.exit(1)
PY
    ); then N1SAY=$OUT; else N1BAD+=("the minutes against the view: $(tr '\n' ' ' <<<"$OUT")"); fi
    IFS='|' read -r BMAX BHOT BDTU <<<"$(q "select coalesce(max(max_cpu_percent)::text, 'none') || '|' || count(*) filter (where max_cpu_percent >= 50 and max_cpu_percent > avg_cpu_percent) || '|' || coalesce(max(max_dtu_percent)::text, 'none') from pgvigil.mssql_azuredb_minute where instance_id=$iid and snapshot_at >= date_trunc('minute', '$B1+00'::timestamptz) - interval '2 minutes' and snapshot_at <= date_trunc('minute', '$B1+00'::timestamptz) + interval '1 minute'")"
    [ "${BHOT:-0}" -ge 1 ] || N1BAD+=("the burst ending $B1 UTC: no minute around it with max CPU >= 50 and over its average (the largest max CPU there: $BMAX)")
    if [ -n "$LOWTIER" ] && [ "$SO" != ElasticPool ]; then python3 -c 'import sys; sys.exit(0 if sys.argv[1] != "none" and float(sys.argv[1]) >= 50 else 1)' "$BDTU" || N1BAD+=("the burst on $SO: max DTU % $BDTU, want >= 50"); fi
    # the forced gap: the cursor three hours back, older than anything the view holds
    GF=$(q "update pgvigil.mssql_azuredb_read set newest_minute = newest_minute - interval '3 hours' where instance_id=$iid returning to_char((newest_minute + interval '1 minute') at time zone 'UTC', 'YYYY-MM-DD HH24:MI')" | head -1)
    if run_ok mssql_azuredb_resources; then
      GAP=$(q "select count(*) || '|' || coalesce(to_char(min(gap_from) at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), '') || '|' || (select (newest_minute >= '$NEW2')::text from pgvigil.mssql_azuredb_read where instance_id=$iid) from pgvigil.mssql_azuredb_gap where instance_id=$iid")
      [ "$GAP" = "1|$GF|true" ] || N1BAD+=("the forced gap: gap rows | the gap's start | the cursor back at the newest minute = '$GAP', want '1|$GF|true'")
    else N1BAD+=("the read after the forced gap was not ok"); fi
  else N1BAD+=("the read from the cursor was not ok"); fi
  if [ ${#N1BAD[@]} -eq 0 ]; then VERDICT[mssql_azuredb_resources]="PASS ($N1SAY; no minute missing from the cursor ($CN in a row); the burst's largest max CPU $BMAX${LOWTIER:+, max DTU % $BDTU}; the forced gap stored from $GF UTC)"
  else VERDICT[mssql_azuredb_resources]="FAIL"; for e in "${N1BAD[@]}"; do bad "B: mssql_azuredb_resources: $e"; done; fi
fi
# mssql_azuredb_governance again, minutes later: no new history row and no change row
if [ -n "$GOVOK" ]; then
  run_as "$GOVN" mssql_azuredb_governance
  GOV2=$(gov_state "$GOVID"); IFS='|' read -r _ _ _ _ GHIST2 _ GCHG2 _ GUSE2 <<<"$GOV2"
  if [ "$GHIST2" = 1 ] && [ "$GCHG2" = 0 ]; then VERDICT[mssql_azuredb_governance]="PASS (as $GOVN: $GKEYS compared column(s) equal to the setup login's read, $GED / $GSO, dtu_limit $GDTU, 11 Properties rows; one history row after a second read, no change row; usage $GUSE1 then $GUSE2 MB$LOWSKIP)"
  else VERDICT[mssql_azuredb_governance]="FAIL"; bad "B: mssql_azuredb_governance: a second read left '$GOV2' (want one history row and no change row)"; fi
fi
# the missing rights: the proof's CONNECT-only user
for c in mssql_azuredb_resources mssql_azuredb_governance mssql_storage; do run_as "$N-nr" "$c"; done
NRID=$(q "select instance_id from pgvigil.instances where name='$N-nr'")
W1="skipped|the login lacks VIEW DATABASE STATE: the database's resource use is not readable"
if [ -n "$LOWTIER" ]; then W2="skipped|the login lacks ##MS_ServerStateReader## (Basic, S0, S1 and elastic pools): the tier's limits are not readable"; else W2="skipped|the login lacks VIEW DATABASE STATE: the tier's limits are not readable"; fi
if [ -z "$NRID" ]; then RIGHTS="FAIL"; bad "B: the missing rights: the CONNECT-only user's instance was not stored, the run said '$(tr '\n' ' ' < "$WORK/mssql_azuredb_resources.$N-nr.out" | cut -c1-300)'"
else
  G1=$(status_for "$NRID" mssql_azuredb_resources); G2=$(status_for "$NRID" mssql_azuredb_governance); G3=$(status_for "$NRID" mssql_storage)
  NRF=$(q "select count(*) from pgvigil.mssql_files where instance_id=$NRID and is_present"); NRM=$(q "select count(*) from pgvigil.mssql_azuredb_minute where instance_id=$NRID")
  if [ "$G1" = "$W1" ] && [ "$G2" = "$W2" ] && [[ $G3 == ok\|* ]] && [ "$NRF" = "${NFILES:-x}" ] && [ "$NRM" = 0 ]; then RIGHTS="PASS (CONNECT only: mssql_azuredb_resources and mssql_azuredb_governance skipped with their sentences, nothing stored; mssql_storage ok with $NRF file(s))"
  else RIGHTS="FAIL"; bad "B: the missing rights as the CONNECT-only user: mssql_azuredb_resources '$G1' (want '$W1'), mssql_azuredb_governance '$G2' (want '$W2'), mssql_storage '$G3' with $NRF file(s) (want ok with ${NFILES:-?}), $NRM minute(s) stored (want 0)"; fi
fi
echo "  the collections:"
if [ -n "$B2A" ]; then for c in "${B2ARUNS[@]}"; do printf '    %-26s %s\n' "$c" "${VERDICT[$c]:-FAIL (no verdict)}"; done
else for c in "${RUNS[@]}" "${SKIPS[@]}"; do printf '    %-26s %s\n' "$c" "${VERDICT[$c]:-FAIL (no verdict)}"; done; fi
printf '    %-26s %s\n' "the missing rights" "$RIGHTS"

echo "--- D. nothing of pgvigil created in the monitored database"
snap > "$WORK/after.txt"
if diff "$WORK/before.txt" "$WORK/after.txt" > "$WORK/d.diff"; then echo "D: OK ($(wc -l < "$WORK/after.txt") objects, principals, permissions, members and sessions unchanged)"
else bad "D: the monitored database changed under the collector: $(tr '\n' ' ' < "$WORK/d.diff" | cut -c1-400)"; fi

echo "--- C. the pages"
if [ -n "$B2A" ]; then echo "C: NOT RUN (PGVIGIL_PROOF_B2A_ONLY: the pages are the whole proof's)"
elif [ -n "${PGVIGIL_SKIP_PAGES:-}" ]; then echo "C: NOT RUN (PGVIGIL_SKIP_PAGES)"; FAILS+=("C: not run")
else
  # the collections behind an ok cell run again now: the Summary calls a read older than its window stale
  for c in mssql_instance mssql_requests mssql_xe mssql_storage; do "$BIN" collect -config "$CFG" -once "$c" -instance "$N" > "$WORK/$c-c.out" 2>&1 || true; done
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  "$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
  for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
  curl -fs "http://127.0.0.1:$PORT/api/mssql/summary" > "$WORK/sum.json" || { cat "$WORK/serve.log" >&2; die "C: GET /api/mssql/summary"; }
  # cells is a table: {columns: [...], rows: [[...], ...]}
  GOT=$(jq -r --argjson i "$iid" '.cells as $t | ($t.columns | index("instance_id")) as $ci | ($t.columns | index("key")) as $ck | ($t.columns | index("state")) as $cs
    | [$t.rows[] | select(.[$ci] == $i) | "\(.[$ck])=\(.[$cs])"] | sort | join(" ")' "$WORK/sum.json")
  # the cell keys come from the tree's own Summary (task P08 set them one for one under DBA Dash's): the three cells
  # whose collections run here (blocking: mssql_requests, events: mssql_xe, uptime: mssql_instance) must say ok, every
  # other cell n/a (its collection skipped by the platform rule); a key with any other state fails by its name
  # [B2a: mssql_storage runs here: File space, % Max Size and Database state are ok; Disk is n/a (no volumes)]
  OKCELLS="blocking events uptime filespace pctmax dbstate"; CBAD=""
  for kv in $GOT; do k=${kv%%=*}; s=${kv#*=}
    if [[ " $OKCELLS " == *" $k "* ]]; then [ "$s" = ok ] || CBAD+=" $k=$s (want ok)"; else [ "$s" = n/a ] || CBAD+=" $k=$s (want n/a)"; fi
  done
  for k in $OKCELLS; do [[ " $GOT " == *" $k="* ]] || CBAD+=" $k missing"; done
  [ -z "$CBAD" ] && echo "  summary cells: OK ($(wc -w <<<"$GOT") cells: $OKCELLS ok, the rest n/a)" || bad "C: the summary cells:$CBAD (all: '$GOT')"
  if command -v chromium >/dev/null; then
    page() { timeout 60 chromium --headless=new --no-sandbox --disable-gpu --user-data-dir="$WORK/chrome" --virtual-time-budget=15000 --dump-dom "http://127.0.0.1:$PORT/#/$1?i=$iid&w=1h" 2>/dev/null; }
    text() { python3 -c 'import sys,re,html; t=re.sub(r"<(script|style)[^>]*>.*?</\1>","",sys.stdin.read(),flags=re.S); print(html.unescape(re.sub(r"<[^>]+>"," ",t)))'; }
    page summary > "$WORK/p-summary.html" || true
    T=$(text < "$WORK/p-summary.html")
    grep -q 'azuresqldb' <<<"$T" || bad "C: the Summary page does not show the platform badge azuresqldb"
    # the n/a groups by the page's own labels (web/src/fleet.ts: g.mssql[2] ?? g.label, task P08's set)
    if grep -qE 'not read yet:[^.]*(Availability|Log shipping|Mirroring|Full backups|Differential backups|Log backups|Agent Jobs|Drive space|SQL Server Agent|Database Mail|Memory dumps|Query Store|SQL Server Audit|Last good CHECKDB|Log space|Suspect pages|Agent alerts|Identity columns)' <<<"$T"; then
      bad "C: the Summary page lists groups that do not run on Azure SQL Database as 'not read yet': $(grep -oE 'not read yet:[^.]*' <<<"$T" | head -1)"; fi
    # [B2a: the storage tabs and the CPU tab read here now; Drives says the platform has no volumes]
    declare -A SKIPTABS=([availability]="mssql_ag" [mssqlbackups]="mssql_backups" [mssqljobs]="mssql_jobs" [jobstimeline]="mssql_jobs"
      [rowversions]="mssql_versionstore" [mssqltempdb]="mssql_tempdb" [mssqlmemory]="mssql_memory"
      [mssqlfileio]="mssql_fileio" [mssqlqs]="mssql_querystore" [mssqlprocs]="mssql_procstats" [mssqlindexlocks]="mssql_indexlocks" [mssqlproperties]="mssql_properties"
      [mssqlplancache]="mssql_plancache" [mssqlindexes]="mssql_indexes" [mssqlaudit]="mssql_audit" [mssqlchecks]="mssql_checks" [mssqlerrorlog]="mssql_errorlog"
      [mssqltrace]="mssql_defaulttrace" [mssqlhealth]="mssql_syshealth"
      [drives]="mssql_storage" [driveperf]="mssql_fileio"
      [rp_props]="mssql_reports" [rp_failed]="mssql_reports" [rp_roles]="mssql_reports" [rp_services]="mssql_reports" [rp_pwage]="mssql_reports" [rp_tables]="mssql_reports")
    NTABS=0
    for tab in summary performance mssql_running mssql_slow mssql_waits mssql_deadlocks mssql_blocked findings availability mssqlbackups mssqljobs mssqlstorage mssqlfiles \
               rowversions mssqlconfig mssqlactions jobstimeline mssqlcpu mssqlmemory mssqlfileio mssqltempdb mssqlqs counters mssqlprocs mssqlindexlocks mssqlproperties \
               mssqlplancache mssqlindexes mssqlaudit mssqlchecks mssqlerrorlog mssqltrace mssqlhealth \
               drives dbspace dbfiles driveperf mssql_waiting mssqlazure \
               rp_props rp_finder rp_dbdeleted rp_failed rp_flushed rp_killed rp_dbnew rp_actions rp_roles rp_services rp_pwage rp_tables customreports community; do
      NTABS=$((NTABS + 1))
      page "$tab" > "$WORK/p-$tab.html" || true
      T=$(text < "$WORK/p-$tab.html")
      if [ ! -s "$WORK/p-$tab.html" ] || grep -q 'class="error"' "$WORK/p-$tab.html"; then bad "C: tab $tab did not render: $(grep -o 'class="error"[^<]*<' "$WORK/p-$tab.html" | head -1)"; continue; fi
      # an unknown tab falls back to the Summary page: a tab of its own must not be that page
      if [ "$tab" != summary ] && grep -qF 'aria-current="page">Summary</a>' "$WORK/p-$tab.html"; then bad "C: tab $tab opened the Summary page (no route for it in the embedded app)"; fi
      if [ -n "${SKIPTABS[$tab]:-}" ] && ! grep -qiE 'not on this platform|Azure SQL Database' <<<"$T"; then
        bad "C: tab $tab (${SKIPTABS[$tab]}, skipped here) renders without a line saying it does not run on this platform"; fi
    done
    echo "  pages rendered: $NTABS tabs"
  else bad "C: chromium is not on this machine: the pages were not rendered"; fi
fi

[ ! -s "$WORK/sq-failed" ] || bad "a read of the setup login failed during the run (its message is above): $(head -c 300 "$WORK/sq-failed" | tr '\n' ' ')"
echo
if [ ${#FAILS[@]} -eq 0 ] && [ -n "$B2A" ]; then
  echo "proof-mssql-azuresqldb: PASS (B2a rows only, on $SO: R, A (the instance row), B: ${B2ARUNS[*]} and the missing rights; D; the other collections and the pages NOT RUN)"
elif [ ${#FAILS[@]} -eq 0 ]; then
  echo "proof-mssql-azuresqldb: PASS (R, A, B: ${#RUNS[@]} collected and equal (mssql_waiting_tasks against a blocked pair; B2a's three with the missing rights), ${#SKIPS[@]} skipped by the platform rule; C; D)"
else
  echo "the failed items:"; printf '  - %s\n' "${FAILS[@]}"
  echo "proof-mssql-azuresqldb: FAIL (${#FAILS[@]} item(s))"; exit 1
fi
