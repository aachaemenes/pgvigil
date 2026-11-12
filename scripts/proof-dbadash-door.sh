#!/usr/bin/env bash
# Proof of the DBA Dash door (task 156 = tasks 75 + 92): pgvigil's pages over DBA Dash's own procedures equal DBA
# Dash's own grids for the same instance, an action is refused without the actions login (and done with it), and the
# import's counts equal the source's. Runs on a Linux box with docker (the project's build box).
#
# The DBA Dash repository: by default a real DBA Dash 4.24.1 repository that DBA Dash's OWN service builds and fills
# (the release zip's DBADashConfig and DBADashService, framework-dependent .NET, run under Microsoft's dotnet 10
# runtime image), monitoring the SQL Server 2022 container that also holds the repository. With PGVIGIL_DBADASH_BAK
# (a backup file of a DBA Dash repository, e.g. the Windows guest's DBADashDB) that backup is restored instead and
# the service step is skipped.
#
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest, mcr.microsoft.com/dotnet/runtime:10.0 and
# python:3.12-slim, whose pymssql is the second, independent client of part C), go, psql, curl, python3, unzip, and
#   ADMIN_DSN               a superuser connection to a PostgreSQL sandbox in KEYWORD form (default
#                           'host=127.0.0.1 port=5432 user=postgres dbname=postgres'); the proof makes its own pgvigil
#                           repository database there and drops it at the end.
#   PGVIGIL_DBADASH_BAK     (optional) a DBA Dash repository backup to restore instead of building one
#   PGVIGIL_DBADASH_CACHE   where the unzipped DBA Dash 4.24.1 release is kept between runs (default
#                           ~/.cache/pgvigil-dbadash-4.24.1); the zip is fetched from the trimble-oss/dba-dash release
#                           when missing and its SHA-256 checked; each run works on its OWN copy of it (the service writes
#                           its config, the config's backups and its logs there), so runs side by side share nothing
#   SVC_SECS                the seconds DBA Dash's service collects (default 180)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch: the
# containers and their network (label pgvigil-proof=s156), the pgvigil database and its login role, the run's copy of
# the release with the service's config (DBA Dash keeps the sa password in it, reversibly obfuscated on Linux) and its
# backups and logs; the cache itself must hold no ServiceConfig.json* after the run (checked). The cluster roles
# 'pgvigil migrate' creates (pgvigil_reader ...) are shared by every pgvigil repository and stay. Every password is
# made at run time and reaches the tools through environment files, stdin or a mode-600 file, never a command line;
# one exception, said: DBADashConfig takes its connection string as an argument, so the throwaway sa password of this
# run's container is in that tool's arguments (visible to this machine's ps) for the seconds it runs.
#
# Expected (written before the first run):
#  A. the repository: a SQL Server 2022 container (Agent on) seeded with a database and its full backup, an Agent
#     job run twice and an Agent alert; DBADashConfig SetDestination and Add print "Complete"; DBA Dash's service
#     collects for SVC_SECS s; the repository's version starts 4.24.1 and it holds 1 active instance whose Instance
#     is the container's @@SERVERNAME; dbo.CPU, dbo.JobHistory and dbo.DBFileSnapshot hold rows for it (more than
#     0 each; dbo.DriveSnapshot may hold 0: DBA Dash reads drives through WMI, which Linux has not); the instance
#     carries DBA Dash system tags ({...}). After the run the cache holds no ServiceConfig.json*. [PGVIGIL_DBADASH_BAK:
#     the restore, the version printed (a version other than 4.24.1 is a FAIL here: the proof is of 4.24.1), the
#     instance and the counts printed; D2-D4 are skipped (the restored instance is another server than this run's
#     container) and said.]
#  B. the read login gets SELECT on the dbo schema, EXECUTE on dbo.IDs and on the nine page procedures only; as that
#     login an INSERT into dbo.Settings, EXEC dbo.Summary_Upd and EXEC dbo.Summary_Get are each refused with a
#     permission error.
#  C. the pages: TestLivePages through the read login prints 9 lines 'page <key> ok ... proven=true'; the same nine
#     procedures called as sa by pymssql (FreeTDS: another driver, the GUI's parameters written out in T-SQL here)
#     return, page by page, the same number of result sets, the same column names in the same order, the same row
#     count and the same rows (compared as multisets, decimals by value, dates to the millisecond, GUIDs in capitals);
#     at least 6 of the 9 pages return 1 row or more (a page of 0 rows on both sides is equal and is said). DBA Dash
#     computes a few cells from the clock at the call (BackupStatus.SnapshotAge as 'dd hh:mm:ss', ages in whole
#     minutes or days): such a cell is equal within 300 s, or 1 unit, and their number is printed. The exact snapshot:
#     the sessions page called with one SnapshotDateUTC as pgvigil's page printed it (7 digits) returns the same rows as
#     RunningQueries_Get called with that exact literal, 1 row or more.
#  D. the actions, through the API of a running `pgvigil serve` as a signed-in UI user:
#     D1 the DBADash read (TestLive) stores the instance; GET /api/dbadash?repo=lab&id=<id>&part=pgvigil answers 200
#        with 0 rows while pgvigil monitors no SQL Server of that @@SERVERNAME;
#     D2 after `pgvigil collect -once mssql_instance` of a pgvigil SQL Server instance on the same server it returns
#        that instance (its instance_id and name);
#     D3 without an actions_dsn on it, a kill of the proof's own application session is 409, outcome refused, the
#        detail names 'actions_dsn', one audit row 'refused' is in pgvigil.actions_log and the session is still
#        connected;
#     D4 with an actions login (ALTER ANY CONNECTION only) and actions: [kill], the preview names the application
#        login, the run is 200 done, the session is gone and the audit row says done with 'KILL <id>'.
#  E. the import (TestLiveImport): the dry run prints 4 mappings with inserted=0 and source equal to the proof's own
#     count of each DBA Dash table (taken here through sqlcmd: the same row definitions as the import's, run apart
#     from it); the run as the repository's owner (batches of 2, so the database sizes, more than 2 rows, commit in
#     several transactions) prints inserted = source = stored for each mapping, and the proof's own count of each
#     pgvigil table for the instance equals the source; a second run inserts 0 and stored is unchanged; pgvigil holds
#     the instance under DBA Dash's display name, engine sqlserver, with the tag 'env:proof' added on DBA Dash's side
#     and none of DBA Dash's system tags; the run as a login in role pgvigil_reader is refused ('may not write').
#  F. the version pin: with a newer version row '9.9.9' in the repository, every page answers ok with proven=false and
#     the note 'not proven on source version 9.9.9'; the row is removed again.
#  G. the imported server's tabs (task 168), under `pgvigil serve` built from a copy of this tree with the join's wiring
#     (internal/dbadash/testdata/join-168.patch applied to the copy; already applied = said and used as it is) and the
#     web bundle rebuilt, on a pgvigil repository of its own whose configuration names the DBA Dash repository and no
#     instance, in a headless Chromium signed in as a UI user:
#     G1 before any import, the DBA Dash instance's own page (#/dbadash?dr=lab&di=<id>) lists the 33 SQL Server tabs;
#        each renders with no error box: summary, performance, mssql_running, mssqlbackups, mssqljobs (with the SQL
#        Agent alerts), mssqlstorage (the Drives screen: 0 rows on Linux, as C's), mssqlfiles, mssqlconfig and
#        mssqlproperties as the repository's screens with rows (mssqlstorage excepted), every other tab its one
#        'not read for an imported server' line and no grid row; the tree shows 'Imported: lab' and no 'DBADash' or
#        'DBA Dash' text;
#     G2 `pgvigil import dbadash -config <it> -repo lab` (the join's subcommand) exits 0 and makes the imported server
#        under DBA Dash's display name;
#     G3 the imported server at its own pgvigil instance (#/summary?i=<id>) lists the same 33 tabs (Availability
#        kept); mssqlcpu, mssqlstorage and jobstimeline render pgvigil's own pages over the imported rows (a grid row or
#        a chart), the eight other screen tabs as in G1, every other tab its one line; the tree as in G1.
# NOT PROVEN HERE: the page's machine-name and latest-snapshot guards on the buttons in a browser; the 'volumes' mapping with rows
# when DBA Dash collects none (Linux: run with PGVIGIL_DBADASH_BAK of a Windows-side repository); pgvigil's own
# collector run after an import (the duplicates the docs' -to rule is about); a DBA Dash version other than 4.24.1;
# Azure SQL Database rows of a repository.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
CACHE=${PGVIGIL_DBADASH_CACHE:-$HOME/.cache/pgvigil-dbadash-4.24.1}
SVC_SECS=${SVC_SECS:-180}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest; IMG_NET=mcr.microsoft.com/dotnet/runtime:10.0; IMG_PY=python:3.12-slim
ZIP_URL=https://github.com/trimble-oss/dba-dash/releases/download/4.24.1/DBADash_4.24.1.zip
ZIP_SHA=c04f3cd949f89d93f72269a1223bea2153b7017a80823064b585997e8d632033
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
NET=pgvdoor-net-$SUF; SQL=pgvdoor-sql-$SUF; SVC=pgvdoor-svc-$SUF; CFGC=pgvdoor-cfg-$SUF; PYC=pgvdoor-py-$SUF; HOSTN=pgvdoor$SUF; LBL=pgvigil-proof=s156
DDB=DBADash_pgv$SUF; PGDB=pgv_door_$SUF; PGRO=pgv_door_ro_$SUF
RO=pgv_ddro_$SUF; MON=pgv_ddmon_$SUF; ACT=pgv_ddact_$SUF; APP=pgv_ddapp_$SUF; USR=proofdba$SUF
PROCS="PerformanceSummary_Get RunningQueriesSummary_Get RunningQueries_Get BackupReport_Get AgentJobsReport_Get DrivesReport_Get DBFilesReport_Get Configuration_Get Alerts_Get"
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; APPPID=; CHRPID=; GDB=pgv_door_g_$SUF
SA_PW=$(pw); RO_PW=$(pw); MON_PW=$(pw); ACT_PW=$(pw); APP_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_AGENT_ENABLED=true\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
printf 'SQLCMDPASSWORD=%s\n' "$RO_PW" > "$TMPD/ro.env"; printf 'SQLCMDPASSWORD=%s\n' "$APP_PW" > "$TMPD/app.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$APPPID" ]] && kill "$APPPID" 2>/dev/null || true
  [[ -n "$CHRPID" ]] && kill "$CHRPID" 2>/dev/null || true
  docker rm -f "$SVC" "$CFGC" "$PYC" "$SQL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  if compgen -G "$CACHE/ServiceConfig.json*" >/dev/null; then echo "WARN: $CACHE holds a ServiceConfig.json* (remove it by hand)" >&2; fi
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $GDB WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP ROLE IF EXISTS $PGRO" >/dev/null 2>&1 || true
  rm -rf "$TMPD"
}
trap cleanup EXIT
# sq runs T-SQL as sa (the text on stdin, never on a command line); sqas as the login whose env file is $1
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
# sqok runs T-SQL as sa whose output is not wanted, and fails with sqlcmd's own text when it fails
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
sqas() { printf 'SET NOCOUNT ON;\n%s\n' "$4" | docker exec -i --env-file "$TMPD/$1.env" "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$2" -C -W -h -1 -d "$3" -i /dev/stdin 2>&1 || true; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$1"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else (d or {}).get(k)
print("" if d is None else d)' "$1" "$2"; }
for t in docker go psql curl python3 unzip chromium node npm git; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== A. the DBA Dash repository =="
docker network create --label "$LBL" "$NET" >/dev/null
docker run -d --name "$SQL" --hostname "$HOSTN" --network "$NET" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
# a login is accepted before msdb is online and before SQL Server Agent has connected: wait for both
ready=
for _ in $(seq 1 90); do
  ready=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' AND EXISTS (SELECT 1 FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%') THEN 1 ELSE 0 END" 2>/dev/null || true)
  [[ "$ready" == 1 ]] && break; sleep 2
done
[[ "$ready" == 1 ]] || fail "A: the SQL Server container did not come up with msdb online and SQL Server Agent connected in 180 s"
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
SERVERNAME=$(sq "SELECT @@SERVERNAME")
if [[ -n "${PGVIGIL_DBADASH_BAK:-}" ]]; then
  [[ -f "$PGVIGIL_DBADASH_BAK" ]] || fail "A: PGVIGIL_DBADASH_BAK is not a file"
  docker cp "$PGVIGIL_DBADASH_BAK" "$SQL:/var/opt/mssql/data/pgvdoor.bak"
  docker exec -u 0 "$SQL" chown mssql /var/opt/mssql/data/pgvdoor.bak 2>/dev/null || true
  moves=$(sq "DECLARE @f TABLE (LogicalName nvarchar(128), PhysicalName nvarchar(260), [Type] char(1), FileGroupName nvarchar(128), Size numeric(20,0), MaxSize numeric(20,0), FileId bigint, CreateLSN numeric(25,0), DropLSN numeric(25,0), UniqueId uniqueidentifier, ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint, SourceBlockSize int, FileGroupId int, LogGroupGUID uniqueidentifier, DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier, IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32), SnapshotUrl nvarchar(360));
INSERT @f EXEC ('RESTORE FILELISTONLY FROM DISK = ''/var/opt/mssql/data/pgvdoor.bak''');
SELECT STRING_AGG(CONCAT('MOVE ''', LogicalName, ''' TO ''/var/opt/mssql/data/$DDB', FileId, CASE [Type] WHEN 'L' THEN '.ldf' ELSE '.mdf' END, ''''), ', ') FROM @f")
  sqok "A: the restore" "RESTORE DATABASE [$DDB] FROM DISK = '/var/opt/mssql/data/pgvdoor.bak' WITH $moves, RECOVERY"
  echo "ok   A: restored $(basename "$PGVIGIL_DBADASH_BAK") as $DDB (the service step skipped)"
else
  sqok "A: the seed" "CREATE DATABASE pgvdoor_db; BACKUP DATABASE pgvdoor_db TO DISK = '/var/opt/mssql/data/pgvdoor_db.bak' WITH INIT;
      EXEC msdb.dbo.sp_add_job @job_name = 'pgvdoor_job'; EXEC msdb.dbo.sp_add_jobstep @job_name = 'pgvdoor_job', @step_name = 's1', @command = 'SELECT 1';
      EXEC msdb.dbo.sp_add_jobserver @job_name = 'pgvdoor_job'; EXEC msdb.dbo.sp_add_alert @name = 'pgvdoor_alert', @severity = 17;"
  # each run waited for until its outcome row (step 0) is in msdb's history: a start while one is pending is refused
  for run in 1 2; do
    sqok "A: the job's start" "EXEC msdb.dbo.sp_start_job @job_name = 'pgvdoor_job'"
    done_runs=0
    for _ in $(seq 1 60); do
      done_runs=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = 'pgvdoor_job' AND h.step_id = 0")
      (( done_runs >= run )) && break; sleep 1
    done
    (( done_runs >= run )) || fail "A: the job's run $run did not finish in 60 s"
  done
  echo "ok   A: the container seeded (pgvdoor_db and its full backup, pgvdoor_job run twice, pgvdoor_alert); @@SERVERNAME $SERVERNAME"
  if [[ ! -f "$CACHE/DBADashService.dll" ]]; then
    # fetched into a folder of this run's own and moved into place whole: two first runs never share a half-written zip
    part="$CACHE.part.$SUF"; mkdir -p "$part"
    curl -fsSL -o "$part/z.zip" "$ZIP_URL" || { rm -rf "$part"; fail "A: the release zip could not be fetched"; }
    [[ "$(sha256sum "$part/z.zip" | cut -c1-64)" == "$ZIP_SHA" ]] || { rm -rf "$part"; fail "A: the release zip's SHA-256 is not the one of DBADash_4.24.1.zip"; }
    (cd "$part" && unzip -q -o z.zip && rm -f z.zip) || { rm -rf "$part"; fail "A: unzip"; }
    mkdir -p "$(dirname "$CACHE")"; mv -T "$part" "$CACHE" 2>/dev/null || rm -rf "$part"
  fi
  # an earlier version of this proof ran the service in the cache itself: its configs and logs go
  rm -rf "$CACHE"/ServiceConfig.json* "$CACHE/Logs"
  DD="$TMPD/dd"; cp -a "$CACHE/." "$DD"
  dn() { docker run --rm --name "$CFGC" --network "$NET" --label "$LBL" --env-file "$TMPD/sa.env" --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$DD:/dd" -w /dd "$IMG_NET" bash -c "$1"; }
  a=$(dn "dotnet DBADashConfig.dll -a SetDestination -c \"Data Source=$SQL;Initial Catalog=$DDB;User ID=sa;Password=\$SA_PW;Encrypt=True;Trust Server Certificate=True\"" 2>&1 | tail -3 || true)
  echo "$a" | grep -q 'Complete' || fail "A: SetDestination: $a"
  b=$(dn "dotnet DBADashConfig.dll -a Add -c \"Data Source=$SQL;User ID=sa;Password=\$SA_PW;Encrypt=True;Trust Server Certificate=True\" --Replace" 2>&1 | tail -3 || true)
  echo "$b" | grep -q 'Complete' || fail "A: Add: $b"
  echo "ok   A: DBADashConfig SetDestination and Add: Complete"
  docker run -d --name "$SVC" --network "$NET" --label "$LBL" --env-file "$TMPD/sa.env" --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$DD:/dd" -w /dd "$IMG_NET" dotnet DBADashService.dll >/dev/null
  sleep "$SVC_SECS"
  docker logs "$SVC" 2>&1 | grep -E '\[(ERR|FTL)\]' | head -5 | sed 's/^/note /' || true
  docker rm -f "$SVC" >/dev/null
  rm -rf "$DD"
  ! compgen -G "$CACHE/ServiceConfig.json*" >/dev/null || fail "A: the cache holds a ServiceConfig.json*"
  echo "ok   A: DBA Dash's service collected for $SVC_SECS s as a console process in this run's own copy of the release, now removed; the cache holds no service config"
fi
VER=$(sq "SELECT TOP (1) Version FROM dbo.DBVersionHistory ORDER BY DeployDate DESC" "$DDB")
ID=$(sq "SELECT MIN(InstanceID) FROM dbo.Instances WHERE IsActive = 1 AND ISNULL(EngineEdition, 0) <> 5" "$DDB")
NI=$(sq "SELECT COUNT(*) FROM dbo.Instances WHERE IsActive = 1 AND ISNULL(EngineEdition, 0) <> 5" "$DDB")
INST=$(sq "SELECT Instance FROM dbo.Instances WHERE InstanceID = $ID" "$DDB")
DISP=$(sq "SELECT ISNULL(Alias, ConnectionID) FROM dbo.Instances WHERE InstanceID = $ID" "$DDB")
n_cpu=$(sq "SELECT COUNT(*) FROM dbo.CPU WHERE InstanceID = $ID" "$DDB")
n_vol=$(sq "SELECT COUNT(*) FROM dbo.DriveSnapshot S JOIN dbo.Drives D ON D.DriveID = S.DriveID WHERE D.InstanceID = $ID" "$DDB")
n_dbs=$(sq "SELECT COUNT(*) FROM (SELECT DISTINCT S.SnapshotDate, F.DatabaseID FROM dbo.DBFileSnapshot S JOIN dbo.DBFiles F ON F.FileID = S.FileID JOIN dbo.Databases D ON D.DatabaseID = F.DatabaseID WHERE D.InstanceID = $ID) g" "$DDB")
n_job=$(sq "SELECT COUNT(*) FROM dbo.JobHistory WHERE InstanceID = $ID" "$DDB")
[[ "$VER" == 4.24.1 || "$VER" == 4.24.1.* ]] || fail "A: the repository's version is '$VER' (the proof is of 4.24.1)"
[[ "$ID" =~ ^[0-9]+$ ]] || fail "A: no active SQL Server instance in the repository"
nsys=$(sq "SELECT COUNT(*) FROM dbo.InstanceIDsTags IT JOIN dbo.Tags T ON T.TagID = IT.TagID WHERE IT.InstanceID = $ID AND T.TagName LIKE N'{%'" "$DDB")
if [[ -z "${PGVIGIL_DBADASH_BAK:-}" ]]; then
  [[ "$NI" == 1 && "$INST" == "$SERVERNAME" ]] || fail "A: $NI active instance(s), Instance '$INST' (want 1 and $SERVERNAME)"
  (( n_cpu > 0 && n_job > 0 && n_dbs > 2 && nsys > 0 )) || fail "A: DBA Dash collected too little: CPU $n_cpu, JobHistory $n_job, DBFileSnapshot groups $n_dbs, system tags $nsys (want more than 0, 0, 2 and 0)"
fi
echo "ok   A: $DDB at DBA Dash $VER; instance $ID '$INST' (shown as '$DISP'), $NI active; CPU $n_cpu, DriveSnapshot $n_vol, DBFileSnapshot groups $n_dbs, JobHistory $n_job; $nsys DBA Dash system tag(s)"
sqok "A: DBA Dash's Summary refresh" "EXEC dbo.Summary_Get @ForceRefresh = 1" "$DDB"

echo "== B. the read login =="
grants=""
for p in $PROCS; do grants+="GRANT EXECUTE ON dbo.$p TO [$RO]; "; done
sqok "B: the read login" "CREATE LOGIN [$RO] WITH PASSWORD = '$RO_PW', CHECK_POLICY = OFF; USE [$DDB]; CREATE USER [$RO] FOR LOGIN [$RO];
    GRANT SELECT ON SCHEMA::dbo TO [$RO]; GRANT EXECUTE ON TYPE::dbo.IDs TO [$RO]; $grants"
w1=$(sqas ro "$RO" "$DDB" "INSERT INTO dbo.Settings (SettingName, SettingValue) VALUES ('pgvigil_proof', 1)")
w2=$(sqas ro "$RO" "$DDB" "EXEC dbo.Summary_Upd")
w3=$(sqas ro "$RO" "$DDB" "EXEC dbo.Summary_Get")
for w in "$w1" "$w2" "$w3"; do echo "$w" | grep -qi 'permission was denied' || fail "B: the read login was not refused: $w"; done
echo "ok   B: $RO reads only: INSERT into dbo.Settings, EXEC dbo.Summary_Upd and EXEC dbo.Summary_Get refused"

echo "== C. the pages against DBA Dash's own grids =="
FROM=$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$TMPD/pages"
export PGV_DD_RO="sqlserver://$RO:$(urlq "$RO_PW")@127.0.0.1:$PORT_SQL?database=$DDB&encrypt=true&TrustServerCertificate=true"
pages() { PGVIGIL_DBADASH_PAGE_DSN="$PGV_DD_RO" PGVIGIL_DBADASH_PAGE_ID="$ID" PGVIGIL_DBADASH_PAGE_FROM="$FROM" PGVIGIL_DBADASH_PAGE_TO="$TO" PGVIGIL_DBADASH_PAGE_DIR="${1:-$TMPD/pages}" \
  PGVIGIL_DBADASH_PAGE_SNAPSHOT="${2:-}" go test -count=1 -run '^TestLivePages$' -v ./internal/dbadash 2>&1 | grep '^page ' || true; }
res=$(pages); echo "$res"
[[ "$(echo "$res" | grep -c ' ok .*proven=true ')" == 9 ]] || fail "C: not every page answered ok and proven"
# the exact snapshot: one SnapshotDateUTC as the running page printed it, back through the sessions page
SNAPTXT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d["results"][0]; i=[c["name"] for c in s["columns"]].index("SnapshotDateUTC"); print(s["rows"][0][i] if s["rows"] else "")' "$TMPD/pages/running.json")
[[ -n "$SNAPTXT" ]] || fail "C: the running page holds no snapshot to call back"
mkdir -p "$TMPD/pages-snap"
pages "$TMPD/pages-snap" "${SNAPTXT/ /T}Z" | grep '^page sessions ' | grep -q ' ok ' || fail "C: the sessions page with the snapshot $SNAPTXT did not answer"
cat > "$TMPD/grids.py" <<'PY'
import datetime, decimal, glob, json, os, sys, uuid
import pymssql
idn, frm, to, snap = int(os.environ["ID"]), os.environ["FROM"][:19], os.environ["TO"][:19], os.environ["SNAP"]
ids = f"DECLARE @i dbo.IDs; INSERT @i VALUES ({idn}); "
st = "@IncludeCritical = 1, @IncludeWarning = 1, @IncludeNA = 1, @IncludeOK = 1"
calls = {  # DBA Dash GUI's parameters for one instance, every status ticked (DBADashGUI source, 4.24.1)
  "performance": f"EXEC dbo.PerformanceSummary_Get @InstanceIDs = '{idn}', @FromDate = '{frm}', @ToDate = '{to}', @ShowHidden = 1",
  "running": f"EXEC dbo.RunningQueriesSummary_Get @InstanceID = {idn}, @FromDate = '{frm}', @ToDate = '{to}', @MaxRows = 2000",
  "sessions": f"EXEC dbo.RunningQueries_Get @InstanceID = {idn}",
  "backups": ids + f"EXEC dbo.BackupReport_Get @InstanceIDs = @i, {st}, @ShowHidden = 1",
  "jobs": ids + f"EXEC dbo.AgentJobsReport_Get @InstanceIDs = @i, {st}, @IncludeACK = 1, @ShowHidden = 1",
  "drives": ids + f"EXEC dbo.DrivesReport_Get @InstanceIDs = @i, {st}, @ShowHidden = 1",
  "dbfiles": ids + f"EXEC dbo.DBFilesReport_Get @InstanceIDs = @i, {st}, @FilegroupLevel = 1, @ShowHidden = 1",
  "configuration": f"EXEC dbo.Configuration_Get @InstanceIDs = '{idn}', @ShowHidden = 1",
  "alerts": f"EXEC dbo.Alerts_Get @InstanceIDs = '{idn}', @ShowHidden = 1",
  "sessions@snapshot": f"EXEC dbo.RunningQueries_Get @InstanceID = {idn}, @SnapshotDateFrom = '{snap}', @SnapshotDateTo = '{snap}'",
}
def dec(s):
    try: return decimal.Decimal(s).normalize()
    except Exception: return None
def canon_py(v, typ):  # pymssql's value, with pgvigil's column type for the same column
    if v is None: return "NULL"
    # FreeTDS hands a sql_variant back as its base value's raw bytes: an integer is little-endian (600 = 0x58020000)
    if typ == "SQL_VARIANT" and isinstance(v, (bytes, bytearray)) and len(v) in (1, 2, 4, 8):
        return "N" + str(decimal.Decimal(int.from_bytes(bytes(v), "little", signed=True)).normalize())
    if isinstance(v, bool): return "B" + str(v)
    if isinstance(v, (int, decimal.Decimal)): return "N" + str(decimal.Decimal(v).normalize())
    if isinstance(v, float): return "F%.17g" % v
    if isinstance(v, datetime.datetime):
        if v.tzinfo: v = v.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        return "T" + v.strftime("%Y-%m-%d %H:%M:%S.%f")[:23]
    if isinstance(v, datetime.date): return "D" + v.isoformat()
    if isinstance(v, datetime.time): return "H" + v.strftime("%H:%M:%S.%f")[:12]
    if isinstance(v, uuid.UUID): return "S" + str(v).upper()
    if isinstance(v, (bytes, bytearray)): return "S0x" + bytes(v).hex().upper()
    return "S" + str(v)
def canon_pg(v, typ):  # pgvigil's JSON value with its column type
    if v is None: return "NULL"
    if isinstance(v, bool): return "B" + str(v)
    if typ in ("FLOAT", "REAL"): return "F%.17g" % float(v)
    if isinstance(v, int) or typ in ("DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY"): return "N" + str(dec(str(v)))
    if typ in ("DATETIME", "DATETIME2", "SMALLDATETIME"):
        d, _, f = v.partition("."); return "T" + d + "." + (f + "000000")[:3]
    if typ == "DATETIMEOFFSET":
        x = datetime.datetime.strptime(v[:19] + v[-7:].replace(":", ""), "%Y-%m-%d %H:%M:%S %z")
        f = (v[20:v.rfind(" ")] + "000000")[:3] if "." in v[:v.rfind(" ")] else "000"
        return "T" + x.astimezone(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S") + "." + f
    if typ == "DATE": return "D" + v
    if typ == "TIME":
        d, _, f = v.partition("."); return "H" + d + "." + (f + "000000")[:3]
    return "S" + str(v)
con = pymssql.connect(server=os.environ["SQLHOST"], user="sa", password=os.environ["SA_PW"], database=os.environ["DDB"], port=1433, tds_version="7.4")
import re
DUR = re.compile(r"^S(\d+) (\d\d):(\d\d):(\d\d)$")
AGE = re.compile(r"(Age|Days|Mins|Minutes|Hours)$")
bad, nonempty, clockcells = [], 0, [0]
for page, sqltext in calls.items():
    cur = con.cursor()
    cur.execute("SET NOCOUNT ON; " + sqltext)
    sets = []
    while True:
        if cur.description:
            sets.append(([c[0] for c in cur.description], cur.fetchall()))
        if not cur.nextset(): break
    if page == "sessions@snapshot":
        pg = json.load(open(os.path.join(os.environ["PAGES"] + "-snap", "sessions.json")))
    else:
        pg = json.load(open(os.path.join(os.environ["PAGES"], page + ".json")))
    pgsets = pg["results"]
    if len(sets) != len(pgsets):
        bad.append(f"{page}: {len(sets)} result set(s) from DBA Dash, {len(pgsets)} on the page"); continue
    rows_seen = 0
    for n, ((cols, rows), ps) in enumerate(zip(sets, pgsets)):
        pcols = [c["name"] for c in ps["columns"]]; types = [c["type"] for c in ps["columns"]]
        if cols != pcols: bad.append(f"{page} set {n+1}: columns {cols} vs {pcols}"); continue
        if len(rows) != len(ps["rows"]): bad.append(f"{page} set {n+1}: {len(rows)} rows vs {len(ps['rows'])}"); continue
        a = sorted(tuple(canon_py(v, t) for v, t in zip(r, types)) for r in rows)
        b = sorted(tuple(canon_pg(v, t) for v, t in zip(r, types)) for r in ps["rows"])
        if a != b:
            # DBA Dash computes some durations from the clock at the call (BackupStatus.SnapshotAge, 'dd hh:mm:ss'): the two
            # calls are seconds apart, so such a cell is equal within 300 s; every other cell must be equal as it is
            def near(x, y, col):
                if x == y: return True
                # an age in whole minutes, hours or days computed at the call: 1 unit apart when the calls straddle one
                if AGE.search(col) and x[:1] == y[:1] == "N":
                    try:
                        if abs(decimal.Decimal(x[1:]) - decimal.Decimal(y[1:])) <= 1:
                            clockcells[0] += 1; return True
                    except decimal.InvalidOperation: pass
                mx, my = DUR.match(x), DUR.match(y)
                if not (mx and my): return False
                sx = lambda m: int(m[1]) * 86400 + int(m[2]) * 3600 + int(m[3]) * 60 + int(m[4])
                ok = abs(sx(mx) - sx(my)) <= 300
                if ok and x != y: clockcells[0] += 1
                return ok
            if not (len(a) == len(b) and all(len(x) == len(y) and all(near(p, q, c) for p, q, c in zip(x, y, cols)) for x, y in zip(a, b))):
                diff = next(((x, y) for x, y in zip(a, b) if x != y), None)
                bad.append(f"{page} set {n+1}: the rows differ, first: {diff}")
        rows_seen += len(rows)
    if page == "sessions@snapshot" and rows_seen == 0: bad.append(f"{page}: 0 rows for the snapshot {snap}")
    nonempty += rows_seen > 0
    print(f"ok   C: {page}: {len(sets)} set(s), rows {[len(r) for _, r in sets]}, equal" if not any(x.startswith(page) for x in bad) else f"FAIL C: {page}")
if bad: print("\n".join("FAIL " + x for x in bad)); sys.exit(1)
if nonempty < 7: print(f"FAIL C: only {nonempty - 1} of 9 pages and the snapshot call returned rows"); sys.exit(1)
print(f"ok   C: 9 pages and the exact snapshot {snap} equal to DBA Dash's own procedure output through pymssql; {nonempty} with rows; {clockcells[0]} clock-relative cell(s) equal within 300 s or 1 unit")
PY
docker run --rm --name "$PYC" --network "$NET" --label "$LBL" --env-file "$TMPD/sa.env" -e ID="$ID" -e FROM="$FROM" -e TO="$TO" -e SNAP="$SNAPTXT" -e SQLHOST="$SQL" -e DDB="$DDB" -e PAGES=/w/pages \
  -v "$TMPD:/w:ro" "$IMG_PY" sh -c 'pip install -q --disable-pip-version-check --root-user-action=ignore "pymssql>=2.3,<2.4" 2>&1 | tail -3 && python /w/grids.py' | tee "$TMPD/grids.out" || true
grep -q "^ok   C: 9 pages and the exact snapshot" "$TMPD/grids.out" || fail "C: the pages are not DBA Dash's grids (the lines above)"

echo "== D. the actions, through pgvigil serve =="
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
BIN="$TMPD/pgvigil"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
sqok "D: the logins" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON];
    CREATE LOGIN [$ACT] WITH PASSWORD = '$ACT_PW', CHECK_POLICY = OFF; GRANT ALTER ANY CONNECTION TO [$ACT];
    CREATE LOGIN [$APP] WITH PASSWORD = '$APP_PW', CHECK_POLICY = OFF;"
export PGV_MS_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
export PGV_MS_ACT="sqlserver://$ACT:$(urlq "$ACT_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
cfg() { cat <<EOF
repository:
  dsn: "$PGDSN"
dbadash:
  - name: lab
    dsn: env:PGV_DD_RO
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_MS_MON
$1
EOF
}
cfg "" > "$TMPD/d.yaml"
cfg "    actions_dsn: env:PGV_MS_ACT
    actions: [kill]" > "$TMPD/d-act.yaml"
"$BIN" migrate -config "$TMPD/d.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "D: migrate"; }
live=$(PGVIGIL_DBADASH_CONFIG="$TMPD/d.yaml" go test -count=1 -run '^TestLive$' -v ./internal/dbadash 2>&1 | grep '^dbadash ' || true)
echo "$live" | grep -qE '^dbadash lab ok instances=[1-9]' || fail "D1: the door's read: $live"
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$TMPD/d.yaml" "$USR" >/dev/null 2>&1 || fail "D: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
CJ=$TMPD/cookies; BODY=$TMPD/body
serve() {
  [[ -n "$SRVPID" ]] && { kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; }
  "$BIN" serve -config "$1" -listen "127.0.0.1:$PORT" >"$TMPD/serve.log" 2>&1 & SRVPID=$!
  for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
  kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "D: serve exited"; }
  printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
  [[ "$(curl -s -o "$BODY" -w '%{http_code}' -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "D: the UI login"
}
post() { curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$2" "$U/api/mssql/actions/$1"; }
part() {
  local code; code=$(curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" "$U/api/dbadash?repo=lab&id=$ID&part=pgvigil")
  [[ "$code" == 200 ]] || fail "D: GET part=pgvigil answered $code: $(cat "$BODY")"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
if "pgvigil" not in d: print("NOKEY"); sys.exit(0)
t=d["pgvigil"] or {}; rows=t.get("rows") or []; cols=t.get("columns") or []
print(len(rows), *(("%s=%s" % (c, r[i])) for r in rows[:1] for i, c in enumerate(cols)))' "$BODY"; }
serve "$TMPD/d.yaml"
p1=$(part); [[ "$p1" == 0* ]] || fail "D1: part=pgvigil before pgvigil monitors the server: $p1 (want 0 rows)"
echo "ok   D1: the door read the repository; part=pgvigil: 0 rows while pgvigil monitors no SQL Server named $SERVERNAME"
if [[ -n "${PGVIGIL_DBADASH_BAK:-}" ]]; then
  echo "not proven: D2-D4 (the restored repository's instance is another server than this run's container; run without PGVIGIL_DBADASH_BAK for them)"
else
"$BIN" collect -config "$TMPD/d.yaml" -instance sqlbox -once mssql_instance >"$TMPD/collect.out" 2>&1 || { cat "$TMPD/collect.out" >&2; fail "D2: collect"; }
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
p2=$(part); echo "$p2" | grep -qE "^1 .*instance_id=$SB( |$)" && echo "$p2" | grep -q 'name=sqlbox' || fail "D2: part=pgvigil after the collect: $p2 (want instance $SB sqlbox)"
echo "ok   D2: after pgvigil collected sqlbox ($SERVERNAME): part=pgvigil names instance $SB sqlbox"
# the proof's own application session, an open transaction, waiting
printf "BEGIN TRAN; SELECT 1 AS pgvdoor_marker; WAITFOR DELAY '00:10:00';\n" | docker exec -i --env-file "$TMPD/app.env" "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$APP" -C -i /dev/stdin >/dev/null 2>&1 & APPPID=$!
for _ in $(seq 1 30); do S_ID=$(sq "SELECT MIN(session_id) FROM sys.dm_exec_sessions WHERE login_name = '$APP'"); [[ -n "$S_ID" && "$S_ID" != NULL ]] && break; sleep 0.5; done
[[ -n "$S_ID" && "$S_ID" != NULL ]] || fail "D3: the application session did not connect"
LT=$(sq "SELECT CONVERT(varchar(33), login_time, 126) FROM sys.dm_exec_sessions WHERE session_id = $S_ID")Z
req() { printf '{"instance_id":%s,"action":"kill","session_id":%s,"login_time":"%s","login":"%s","reason":"proof %s of the DBA Dash door","confirm":"%s"}' "$SB" "$S_ID" "$1" "$2" "$SUF" "$S_ID"; }
code=$(post run "$(req "$LT" "$APP")")
[[ "$code" == 409 && "$(jget "$BODY" outcome)" == refused ]] || fail "D3: without the actions login: HTTP $code $(cat "$BODY")"
jget "$BODY" detail | grep -q 'actions_dsn' || fail "D3: the refusal does not name actions_dsn: $(cat "$BODY")"
[[ "$(pq "SELECT count(*) FROM pgvigil.actions_log WHERE instance_id = $SB AND outcome = 'refused' AND action = 'kill'")" == 1 ]] || fail "D3: no refused audit row"
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE session_id = $S_ID AND login_name = '$APP'")" == 1 ]] || fail "D3: the session is gone after a refusal"
echo "ok   D3: without an actions login: 409 refused ($(jget "$BODY" detail)); 1 refused audit row; session $S_ID still connected"
serve "$TMPD/d-act.yaml"
code=$(post preview "{\"instance_id\":$SB,\"action\":\"kill\",\"session_id\":$S_ID}")
[[ "$code" == 200 && "$(jget "$BODY" ok)" == True && "$(jget "$BODY" target.login)" == "$APP" ]] || fail "D4: the preview: HTTP $code $(cat "$BODY")"
PLT=$(jget "$BODY" target.login_time)
code=$(post run "$(req "$PLT" "$APP")")
[[ "$code" == 200 && "$(jget "$BODY" outcome)" == done ]] || fail "D4: the kill: HTTP $code $(cat "$BODY")"
sleep 1
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE session_id = $S_ID AND login_name = '$APP'")" == 0 ]] || fail "D4: the session is still connected after the kill"
[[ "$(pq "SELECT outcome || '|' || statement FROM pgvigil.actions_log WHERE instance_id = $SB ORDER BY action_id DESC LIMIT 1")" == "done|KILL $S_ID" ]] || fail "D4: the audit row"
echo "ok   D4: with the actions login: preview names $APP, the kill 200 done, session $S_ID gone, the audit row 'done|KILL $S_ID'"
fi
kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=

echo "== E. the import =="
TAGID=$(sq "INSERT INTO dbo.Tags (TagName, TagValue) VALUES (N'env', N'proof'); SELECT SCOPE_IDENTITY();" "$DDB")
sqok "E: the tag" "INSERT INTO dbo.InstanceIDsTags (InstanceID, TagID) VALUES ($ID, $TAGID)" "$DDB"
imp() { PGVIGIL_DBADASH_IMPORT_DSN="$PGV_DD_RO" PGVIGIL_DBADASH_IMPORT_REPO="$1" PGVIGIL_DBADASH_IMPORT_DRY="${2:-0}" PGVIGIL_DBADASH_IMPORT_BATCH=2 \
  go test -count=1 -run '^TestLiveImport$' -v ./internal/dbadash 2>&1 | grep '^import ' || true; }
declare -A want=([cpu]=$n_cpu [volumes]=$n_vol [dbsize]=$n_dbs [jobruns]=$n_job)
field() { echo "$1" | grep "^import $ID [0-9]* $2 " | sed -n "s/.* $3=\([0-9]*\).*/\1/p"; }
dry=$(imp "$PGDSN" 1); echo "$dry"
for m in cpu volumes dbsize jobruns; do
  [[ "$(field "$dry" "$m" source)" == "${want[$m]}" && "$(field "$dry" "$m" inserted)" == 0 ]] || fail "E: the dry run of $m: $(echo "$dry" | grep " $m ") (want source=${want[$m]} inserted=0)"
done
one=$(imp "$PGDSN"); echo "$one"
for m in cpu volumes dbsize jobruns; do
  s=$(field "$one" "$m" source); i=$(field "$one" "$m" inserted); t=$(field "$one" "$m" stored)
  [[ "$s" == "${want[$m]}" && "$i" == "$s" && "$t" == "$s" ]] || fail "E: $m: source=$s inserted=$i stored=$t (want ${want[$m]} each)"
done
two=$(imp "$PGDSN")
for m in cpu volumes dbsize jobruns; do
  [[ "$(field "$two" "$m" inserted)" == 0 && "$(field "$two" "$m" stored)" == "${want[$m]}" ]] || fail "E: the second run of $m: $(echo "$two" | grep " $m ")"
done
PID_IMP=$(echo "$one" | grep "^import $ID " | head -1 | awk '{print $3}')
[[ "$PID_IMP" =~ ^[1-9][0-9]*$ ]] || fail "E: no pgvigil instance for DBA Dash instance $ID: $one"
# the proof's own count of each pgvigil table for the instance (not the import's)
got=$(pq "SELECT (SELECT count(*) FROM pgvigil.mssql_cpu_sample WHERE instance_id = $PID_IMP) || ' ' || (SELECT count(*) FROM pgvigil.mssql_volume_sample WHERE instance_id = $PID_IMP)
  || ' ' || (SELECT count(*) FROM pgvigil.mssql_database_size WHERE instance_id = $PID_IMP) || ' ' || (SELECT count(*) FROM pgvigil.mssql_job_runs WHERE instance_id = $PID_IMP)")
[[ "$got" == "${want[cpu]} ${want[volumes]} ${want[dbsize]} ${want[jobruns]}" ]] || fail "E: pgvigil's tables hold $got for the instance (want ${want[cpu]} ${want[volumes]} ${want[dbsize]} ${want[jobruns]})"
row=$(pq "SELECT name || '|' || engine || '|' || array_to_string(tags, ',') FROM pgvigil.instances WHERE instance_id = $PID_IMP")
[[ "$row" == "$DISP|sqlserver|"* && ",${row##*|}," == *",env:proof,"* && "${row##*|}" != *"{"* ]] || fail "E: the imported instance: $row"
psql "$ADMIN_DSN" -Xqc "CREATE ROLE $PGRO LOGIN IN ROLE pgvigil_reader" >/dev/null
ROPG="$PGDSN user=$PGRO"; ROPG="${ROPG/user=postgres /}"
bad=$(PGVIGIL_DBADASH_IMPORT_DSN="$PGV_DD_RO" PGVIGIL_DBADASH_IMPORT_REPO="$ROPG" go test -count=1 -run '^TestLiveImport$' -v ./internal/dbadash 2>&1 | grep '^import error' || true)
echo "$bad" | grep -q 'may not write' || fail "E: the import as a pgvigil_reader login was not refused: $bad"
echo "ok   E: dry run counts equal the source (cpu ${want[cpu]}, volumes ${want[volumes]}, dbsize ${want[dbsize]}, jobruns ${want[jobruns]}); the import inserted and pgvigil's tables hold exactly those, in batches of 2; a second run inserted 0; instance '$DISP' engine sqlserver with env:proof ($nsys DBA Dash system tag(s) left out); a pgvigil_reader login refused"

echo "== F. the version pin =="
sqok "F: the version row" "INSERT INTO dbo.DBVersionHistory (DeployDate, Version) VALUES (DATEADD(day, 1, SYSUTCDATETIME()), '9.9.9')" "$DDB"
res=$(pages)
sqok "F: the version row's removal" "DELETE FROM dbo.DBVersionHistory WHERE Version = '9.9.9'" "$DDB"
[[ "$(echo "$res" | grep -c ' ok version=9.9.9 proven=false ')" == 9 ]] || fail "F: not every page answered ok with proven=false on 9.9.9: $res"
for pj in "$TMPD"/pages/*.json; do jget "$pj" note | grep -q 'not proven on source version 9.9.9' || fail "F: the note of $(basename "$pj"): $(jget "$pj" note)"; done
echo "ok   F: on a repository at 9.9.9 every page says proven=false: '$(jget "$TMPD/pages/alerts.json" note)'; the row removed"

echo "== G. the imported server's tabs under pgvigil serve, in headless Chromium =="
GSRC=$TMPD/gsrc; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
JP=internal/dbadash/testdata/join-168.patch
if (cd "$GSRC" && git apply --check -R "$JP" 2>/dev/null); then echo "G: the join's wiring is already in this tree"
elif (cd "$GSRC" && git apply "$JP" 2>"$TMPD/g-apply.err"); then echo "G: the join's wiring applied to the run's copy"
else fail "G: $JP neither applies nor is applied: $(cat "$TMPD/g-apply.err")"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/g-web.log" 2>&1 && npm run build >>"$TMPD/g-web.log" 2>&1) || { tail -20 "$TMPD/g-web.log" >&2; fail "G: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil-g" ./cmd/pgvigil) || fail "G: the build"
BIN="$TMPD/pgvigil-g"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $GDB" >/dev/null
GDSN="$ADMIN_DSN"; GDSN="${GDSN/dbname=postgres/dbname=$GDB}"; [[ "$GDSN" == *"dbname=$GDB"* ]] || GDSN="$GDSN dbname=$GDB"
printf 'repository:\n  dsn: "%s"\ndbadash:\n  - name: lab\n    dsn: env:PGV_DD_RO\n' "$GDSN" > "$TMPD/g.yaml"
"$BIN" migrate -config "$TMPD/g.yaml" >"$TMPD/g-migrate.out" 2>&1 || { cat "$TMPD/g-migrate.out" >&2; fail "G: migrate"; }
glive=$(PGVIGIL_DBADASH_CONFIG="$TMPD/g.yaml" go test -count=1 -run '^TestLive$' -v ./internal/dbadash 2>&1 | grep '^dbadash ' || true)
echo "$glive" | grep -qE '^dbadash lab ok instances=[1-9]' || fail "G: the door's read: $glive"
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$TMPD/g.yaml" "$USR" >/dev/null 2>&1 || fail "G: user add"
serve "$TMPD/g.yaml"
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "G: chromium's CDP port never answered"
cat > "$TMPD/g-check.mjs" <<'JS'
// walks every SQL Server tab of one scope in the UI: prints 'tree <ok|...>' and one 'tab <key> ...' line per tab
const [port, U, start] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async (ms = 30000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0; })()`);
    if (ok) { await sleep(400); return true; }
    await sleep(200);
  }
  return false;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.G_USR)}, password: ${JSON.stringify(process.env.G_UPW)} }) }).then(r => r.status)`, true);
if (st !== 200) { console.log(`login ${st}`); process.exit(1); }
await cmd('Page.navigate', { url: U + start }); await sleep(500);
if (!await settled()) { console.log('FAIL render start'); process.exit(1); }
const tabs = await ev(`(() => { const d = document.querySelector('main [data-all]') ?? document.querySelector('#tabs'); return d?.dataset.all ? JSON.parse(d.dataset.all) : null; })()`);
if (!Array.isArray(tabs)) { console.log('FAIL no tab list'); process.exit(1); }
// the tree: its Imported folder drawn (the read arrives after the first draw), no source-product name in it
let tree = '';
for (let i = 0; i < 40 && !/Imported: lab/.test(tree); i++) { await sleep(250); tree = await ev(`document.getElementById('tree')?.innerText ?? ''`); }
console.log(`tree ${/Imported: lab/.test(tree) ? 'folder' : 'nofolder'} ${/DBA ?Dash/i.test(tree) ? 'named' : 'clean'}`);
for (const h of tabs) {
  const key = /[?&]dp=([^&]+)/.exec(h)?.[1] ?? /^#\/([^?]+)/.exec(h)?.[1];
  await cmd('Page.navigate', { url: U + h }); await sleep(300);
  if (!await settled()) { console.log(`tab ${key} render=no`); continue; }
  const r = await ev(`(() => { const m = document.querySelector('main'); const s = m.querySelector('[data-source]');
    const rows = [...m.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty') && tr.children.length > 0).length;
    return JSON.stringify({ src: s?.dataset.source ?? 'native', rows: s?.dataset.rows ?? '-', trs: rows, charts: m.querySelectorAll('canvas, svg').length,
      notread: m.querySelectorAll('p.notread').length, errors: m.querySelectorAll('.error:not([role=status])').length }); })()`);
  const o = JSON.parse(r);
  console.log(`tab ${key} render=yes source=${o.src} rows=${o.rows} trs=${o.trs} charts=${o.charts} notread=${o.notread} errors=${o.errors}`);
}
ws.close();
process.exit(0);
JS
gwalk() { G_USR="$USR" G_UPW="$UPW" node "$TMPD/g-check.mjs" "$CDP" "$U/" "$1"; }
# gtabs <walk output> <store tabs> <screen tabs>: every listed tab as said, every other its one line
gtabs() {
  local out="$1" store=" $2 " screen=" $3 " n line k
  n=$(echo "$out" | grep -c '^tab ' || true); [[ "$n" == 33 ]] || fail "$4: $n tabs walked (want 33): $out"
  echo "$out" | grep -q '^tree folder clean$' || fail "$4: the tree: $(echo "$out" | grep '^tree')"
  while read -r line; do
    k=$(echo "$line" | awk '{print $2}')
    [[ "$line" == *" render=yes "* && "$line" == *" errors=0" ]] || fail "$4: $line"
    if [[ "$store" == *" $k "* ]]; then
      [[ "$line" == *" source=store "* ]] || fail "$4: $k is not pgvigil's own page over the imported rows: $line"
      t=$(echo "$line" | sed -n 's/.* trs=\([0-9]*\) charts=\([0-9]*\) .*/\1 \2/p'); (( ${t% *} + ${t#* } > 0 )) || fail "$4: $k shows no imported row: $line"
    elif [[ "$screen" == *" $k "* ]]; then
      [[ "$line" == *" source=screen "* ]] || fail "$4: $k is not the repository's screen: $line"
      r=$(echo "$line" | sed -n 's/.* rows=\([0-9]*\) .*/\1/p')
      [[ "$k" == mssqlstorage ]] && { [[ "$r" == "$n_vol" ]] || fail "$4: the Drives screen shows $r rows (want $n_vol, as the source)"; } || (( r > 0 )) || fail "$4: $k shows no row: $line"
    else
      [[ "$line" == *" source=none "* && "$line" == *" notread=1 "* && "$line" == *" trs=0 "* ]] || fail "$4: $k is not one 'not read' line: $line"
    fi
  done < <(echo "$out" | grep '^tab ')
}
SCREENS="summary performance mssql_running mssqlbackups mssqljobs mssqlfiles mssqlconfig mssqlproperties"
g1=$(gwalk "#/dbadash?dr=lab&di=$ID"); echo "$g1" > "$TMPD/g1.txt"
gtabs "$g1" "" "$SCREENS mssqlstorage" G1
echo "ok   G1: the DBA Dash instance's own page: 33 tabs, $(echo "$g1" | grep -c 'source=screen') from the repository's screens, $(echo "$g1" | grep -c 'source=none') with their one 'not read' line, no error; the tree 'Imported: lab' and no source-product name"
"$BIN" import dbadash -config "$TMPD/g.yaml" -repo lab >"$TMPD/g-import.out" 2>&1 || { cat "$TMPD/g-import.out" >&2; fail "G2: pgvigil import dbadash"; }
GID=$(psql "$GDSN" -XAtq -c "SELECT instance_id FROM pgvigil.instances WHERE name = '$DISP' AND engine = 'sqlserver'")
[[ "$GID" =~ ^[1-9][0-9]*$ ]] || { cat "$TMPD/g-import.out" >&2; fail "G2: no imported server named $DISP"; }
echo "ok   G2: pgvigil import dbadash -repo lab: exit 0, the imported server $DISP is pgvigil instance $GID ($(tail -1 "$TMPD/g-import.out"))"
sleep 26   # the UI keeps the repositories' read 25 s: the next walk sees the import
g3=$(gwalk "#/summary?i=$GID"); echo "$g3" > "$TMPD/g3.txt"
gtabs "$g3" "mssqlcpu mssqlstorage jobstimeline" "$SCREENS" G3
echo "ok   G3: the imported server at pgvigil instance $GID: 33 tabs, $(echo "$g3" | grep -c 'source=store') of pgvigil's own pages over the imported rows, $(echo "$g3" | grep -c 'source=screen') screens, $(echo "$g3" | grep -c 'source=none') 'not read' lines, no error; the tree as in G1"
kill "$CHRPID" 2>/dev/null || true; CHRPID=
kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=

echo "Not proven here: the buttons' machine-name and latest-snapshot guards in a browser;"
echo "the 'volumes' mapping with rows when DBA Dash collected none ($n_vol here); a DBA Dash version other than $VER; Azure SQL Database rows."
echo "proof-dbadash-door: OK (DBA Dash $VER; 9 pages equal to DBA Dash's grids; an action refused without the actions login, done with it; the import's counts equal the source's; every SQL Server tab of the door instance and of the imported server rendered in Chromium)"
