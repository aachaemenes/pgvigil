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
#  B. each of the 34 SQL Server collections (21 before the join of wave 1, 32 before mssql_waiting_tasks and mssql_reports
#     joined) (the list is checked against internal/mssql's Name() functions):
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
#     A skip is never counted as collected or as failed; a RUN collection skipped for a missing right is a FAIL.
#  C. the pages: GET /api/mssql/summary gives the instance blocking, events and uptime as ok and every other cell
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
MADE_DB=; MADE_XE=; WAITER=; SRV=
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
EOF
"$BIN" migrate -config "$CFG" >/dev/null

# the proof's own setup, as the database's DBA: pgvigil's Extended Events script for this form
"$BIN" mssql-xe -print -form azuresqldb -install-id "$XEID" > "$WORK/xe.sql"
MADE_XE=1
if ! docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,${AZ_PORT:-1433}" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -i /dev/stdin < "$WORK/xe.sql" > "$WORK/xe.out" 2>&1; then
  bad "B: pgvigil's -form azuresqldb Extended Events script failed as the DBA: $(tr '\n' ' ' < "$WORK/xe.out" | cut -c1-600)"
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
[ "$GOT" = "$WANT" ] && [ "$EE" = 5 ] && [ "$((maj * 10000 + 10#$min))" = 120000 ] && echo "A: OK ($GOT)" || bad "A: stored '$GOT', want '$WANT' with engine edition 5 and 120000"

echo "--- B. every collection"
mapfile -t KNOWN < <(grep -ho 'Name() string *{ return Prefix + "[a-z_]*"' $(ls internal/mssql/*.go | grep -v _test.go) | sed 's/.*Prefix + "\([a-z_]*\)"/mssql_\1/' | sort)
RUNS=(mssql_instance mssql_requests mssql_waits mssql_xe mssql_waiting_tasks)
SKIPS=(mssql_services mssql_ag mssql_mirroring mssql_logshipping mssql_replication mssql_jobs mssql_backups mssql_storage mssql_versionstore mssql_cpu mssql_memory mssql_fileio mssql_tempdb mssql_properties mssql_procstats mssql_indexlocks mssql_querystore
  mssql_audit mssql_checks mssql_defaulttrace mssql_errorlog mssql_identity mssql_indexes mssql_plancache mssql_plancache_health mssql_stats mssql_syshealth mssql_traceflags
  mssql_reports)
[ "$(printf '%s\n' "${KNOWN[@]}" | tr '\n' ' ')" = "$(printf '%s\n' "${RUNS[@]}" "${SKIPS[@]}" | sort | tr '\n' ' ')" ] \
  || bad "B: the collections of internal/mssql (${KNOWN[*]}) are not the proof's list"
declare -A TABLES=([mssql_services]="mssql_service mssql_health" [mssql_ag]="mssql_ag_state mssql_ag_database_state" [mssql_mirroring]="mssql_mirroring_state"
  [mssql_logshipping]="mssql_logshipping_state" [mssql_replication]="mssql_replication_state" [mssql_jobs]="mssql_jobs mssql_job_runs" [mssql_backups]="mssql_backup_state"
  [mssql_storage]="mssql_files mssql_volumes" [mssql_versionstore]="mssql_versionstore_db mssql_versionstore_sample" [mssql_cpu]="mssql_cpu_sample mssql_sched_sample"
  [mssql_memory]="mssql_memory_sample mssql_memory_clerk" [mssql_fileio]="mssql_fileio_last" [mssql_tempdb]="mssql_tempdb mssql_tempdb_files"
  [mssql_properties]="mssql_property" [mssql_procstats]="mssql_proc_last" [mssql_indexlocks]="mssql_indexlock_last" [mssql_querystore]="mssql_qs_store"
  [mssql_audit]="mssql_audit mssql_audit_spec mssql_audit_events" [mssql_checks]="mssql_check_finding mssql_server_option mssql_database_option mssql_build"
  [mssql_defaulttrace]="mssql_trace_events" [mssql_errorlog]="mssql_errorlog" [mssql_identity]="mssql_identity_column mssql_identity_scan"
  [mssql_indexes]="mssql_index mssql_index_db mssql_missing_index" [mssql_plancache]="mssql_pc_last mssql_pc_sample" [mssql_plancache_health]="mssql_pc_health"
  [mssql_stats]="mssql_stat mssql_stats_db" [mssql_syshealth]="mssql_health_components" [mssql_traceflags]="mssql_trace_flags"
  [mssql_reports]="mssql_server_role_members mssql_sql_logins mssql_failed_logins mssql_service_ext mssql_table_size report_db_properties report_read_state")
declare -A VERDICT
status_of() { q "select coalesce(status, '') || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$iid and collection='$1'"; }
for c in "${SKIPS[@]}"; do
  "$BIN" collect -config "$CFG" -once "$c" -instance "$N" > "$WORK/$c.out" 2>&1 || true
  st=$(status_of "$c"); rows=0; cnt=ok
  for t in ${TABLES[$c]}; do
    n=$(q "select count(*) from pgvigil.$t where instance_id=$iid") || n=x
    [[ $n =~ ^[0-9]+$ ]] || { bad "B: $c: no count of pgvigil.$t"; n=0; cnt=no; }
    rows=$((rows + n))
  done
  if [[ $st == skipped\|*"Azure SQL Database"* ]] && grep -q "skipped: " "$WORK/$c.out" && [ "$rows" = 0 ]; then VERDICT[$c]="SKIP (${st#skipped|})"
  else VERDICT[$c]="FAIL"; bad "B: $c should be skipped by the Azure SQL Database rule: status '$st', $rows stored row(s), the run said '$(tr '\n' ' ' < "$WORK/$c.out" | cut -c1-300)'"; fi
  [ "$cnt" = ok ] || VERDICT[$c]="FAIL (no count of a table)"
done
run_ok() { # run_ok <collection>: runs it, and says whether it stored a read with status ok
  "$BIN" collect -config "$CFG" -once "$1" -instance "$N" > "$WORK/$1.out" 2>&1 || true
  local st; st=$(status_of "$1")
  if [[ $st == ok\|* ]]; then return 0; fi
  VERDICT[$1]="FAIL"; bad "B: $1 status '$st' (want ok), the run said '$(tr '\n' ' ' < "$WORK/$1.out" | cut -c1-300)'"; return 1
}
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
echo "  the collections:"
for c in "${RUNS[@]}" "${SKIPS[@]}"; do printf '    %-20s %s\n' "$c" "${VERDICT[$c]:-FAIL (no verdict)}"; done

echo "--- D. nothing of pgvigil created in the monitored database"
snap > "$WORK/after.txt"
if diff "$WORK/before.txt" "$WORK/after.txt" > "$WORK/d.diff"; then echo "D: OK ($(wc -l < "$WORK/after.txt") objects, principals, permissions, members and sessions unchanged)"
else bad "D: the monitored database changed under the collector: $(tr '\n' ' ' < "$WORK/d.diff" | cut -c1-400)"; fi

echo "--- C. the pages"
if [ -n "${PGVIGIL_SKIP_PAGES:-}" ]; then echo "C: NOT RUN (PGVIGIL_SKIP_PAGES)"; FAILS+=("C: not run")
else
  # the collections behind an ok cell run again now: the Summary calls a read older than its window stale
  for c in mssql_instance mssql_requests mssql_xe; do "$BIN" collect -config "$CFG" -once "$c" -instance "$N" > "$WORK/$c-c.out" 2>&1 || true; done
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
  OKCELLS="blocking events uptime"; CBAD=""
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
    if grep -qE 'not read yet:[^.]*(Availability|Log shipping|Mirroring|Full backups|Differential backups|Log backups|Agent Jobs|Drive space|File space|Files at their max size|Database state|SQL Server Agent|Database Mail|Memory dumps|Query Store|SQL Server Audit|Last good CHECKDB|Log space|Suspect pages|Agent alerts|Identity columns)' <<<"$T"; then
      bad "C: the Summary page lists groups that do not run on Azure SQL Database as 'not read yet': $(grep -oE 'not read yet:[^.]*' <<<"$T" | head -1)"; fi
    declare -A SKIPTABS=([availability]="mssql_ag" [mssqlbackups]="mssql_backups" [mssqljobs]="mssql_jobs" [jobstimeline]="mssql_jobs" [mssqlstorage]="mssql_storage"
      [mssqlfiles]="mssql_storage" [rowversions]="mssql_versionstore" [mssqltempdb]="mssql_tempdb" [mssqlcpu]="mssql_cpu" [mssqlmemory]="mssql_memory"
      [mssqlfileio]="mssql_fileio" [mssqlqs]="mssql_querystore" [mssqlprocs]="mssql_procstats" [mssqlindexlocks]="mssql_indexlocks" [mssqlproperties]="mssql_properties"
      [mssqlplancache]="mssql_plancache" [mssqlindexes]="mssql_indexes" [mssqlaudit]="mssql_audit" [mssqlchecks]="mssql_checks" [mssqlerrorlog]="mssql_errorlog"
      [mssqltrace]="mssql_defaulttrace" [mssqlhealth]="mssql_syshealth"
      [drives]="mssql_storage" [dbspace]="mssql_storage" [dbfiles]="mssql_storage" [driveperf]="mssql_fileio"
      [rp_props]="mssql_reports" [rp_failed]="mssql_reports" [rp_roles]="mssql_reports" [rp_services]="mssql_reports" [rp_pwage]="mssql_reports" [rp_tables]="mssql_reports")
    NTABS=0
    for tab in summary performance mssql_running mssql_slow mssql_waits mssql_deadlocks mssql_blocked findings availability mssqlbackups mssqljobs mssqlstorage mssqlfiles \
               rowversions mssqlconfig mssqlactions jobstimeline mssqlcpu mssqlmemory mssqlfileio mssqltempdb mssqlqs counters mssqlprocs mssqlindexlocks mssqlproperties \
               mssqlplancache mssqlindexes mssqlaudit mssqlchecks mssqlerrorlog mssqltrace mssqlhealth \
               drives dbspace dbfiles driveperf mssql_waiting \
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
if [ ${#FAILS[@]} -eq 0 ]; then
  echo "proof-mssql-azuresqldb: PASS (R, A, B: ${#RUNS[@]} collected and equal (mssql_waiting_tasks against a blocked pair), ${#SKIPS[@]} skipped by the platform rule; C; D)"
else
  echo "the failed items:"; printf '  - %s\n' "${FAILS[@]}"
  echo "proof-mssql-azuresqldb: FAIL (${#FAILS[@]} item(s))"; exit 1
fi
