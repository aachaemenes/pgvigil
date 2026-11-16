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
#     RunningQueries_Get called with that exact literal, 1 row or more. A page's text columns (a statement, a job's
#     description, an alert's notification message: the list in internal/dbadash/pages.go, handed to this proof by
#     TestMaskCells) are shown through the credential mask, so the second client's cells of those columns pass the same
#     mask before the comparison (TestMaskCells again: the package's own mask, no second copy of it here), and a text
#     cell that differs is named by its column and its length, never printed.
#     C2 (the text a page shows passes the collection's credential mask) after the comparison, as sa: a new dbo.QueryText
#     handle on the first session of the instance's latest running-queries snapshot (its offsets NULL, so text is the
#     batch), a cursor of that session (dbo.RunningQueriesCursors, uniqueifier 1, created a minute before the snapshot)
#     on a second new handle, the description of the instance's first job (dbo.Jobs) and the notification message of its
#     first alert (dbo.Alerts), each holding one credential form with a token made at run time; the pages read again: the
#     sessions page's batch_text and text are "CREATE LOGIN pgv_c2 WITH PASSWORD = '<masked>'; SELECT 1", its
#     cursor_text "ALTER LOGIN pgv_c2 WITH PASSWORD = '<masked>'", the jobs page's
#     description "loads the warehouse; Server=db1;Database=app;User Id=etl;Password=<masked>;", the alerts page's
#     Notification Message 'page the DBA: sqlcmd -S db1 -U ops -P <masked> -Q "EXEC dbo.ack"', and no page's reply holds
#     a token; DBA Dash's tables still hold their four tokens (read as sa): the mask is the page's, not the source's. A
#     job or an alert name with a quote in it is seeded as it is; with PGVIGIL_DBADASH_BAK an instance without a job or
#     without an alert has that text said as not run.
#     C3 the comparison of C again for the sessions, jobs and alerts pages as C2 read them, the seeded credentials in
#     DBA Dash's tables: the three pages equal (the second client's text cells through the same mask), and no line the
#     comparison prints holds a token.
#  D. the actions, through the API of a running `pgvigil serve` as a signed-in UI user:
#     D1 the DBADash read (TestLive) stores the instance; GET /api/dbadash?repo=lab&id=<id>&part=pgvigil answers 200
#        with 0 rows while pgvigil monitors no SQL Server of that @@SERVERNAME;
#     D1w the Collection Errors cell (part=statuses): on 4.24.1 'DBA Dash Errors (24hrs)|<k> error(s) in 24 h'; on
#        4.25.0 'Collection Health|<k> collection(s) at warning or critical' (the instance has collection runs), then -
#        its runs removed, Summary_Upd again - 'Collection Health|<k2> error(s) in 24 h'. On 4.25.0 also (review 425's
#        fold, written before their first run): D1s a deploy row newer than the instance's Summary RefreshDate (a row
#        DBA Dash wrote before the upgrade) reads 'Collection Health|<k> error(s) in 24 h'; D1p a read login with VIEW
#        DEFINITION and SELECT on the four tables only (it sees dbo.CollectionRunStatus, may not read it) reads without
#        an error and gets the bare count 'Collection Health|<k>'. With PGVIGIL_DBADASH_BAK an instance without runs
#        takes the 24 h branch, and D1s / D1p are not run (a restored repository's history is the site's);
#     D1t (the instance's query_text on the statements a page shows; run on a tree whose internal/web/q_dbadash.go
#        calls Statements, or with PGVIGIL_DOOR_TEXTRULE=1, else said as not run) while no pgvigil instance matches
#        the DBA Dash instance (part=imported holds no row for it), serve under the file's query_text none with the
#        instance sqlbox at full (a wrong match would show the statements): the sessions page's batch_text, text and
#        cursor_text of C2's session all read '(not shown: this instance's query_text policy is none)';
#     D2 after `pgvigil collect -once mssql_instance` of a pgvigil SQL Server instance on the same server it returns
#        that instance (its instance_id and name); D2x a session named DBADash_T206 (stopped, a ring buffer) made on the
#        server, then `collect -once mssql_xe`: pgvigil.mssql_xe_foreign holds it 'false|ring_buffer' and the read's count
#        equals the server's own count of DBADash_% sessions; the session dropped;
#     D2t (as D1t) with the matched instance sqlbox: at query_text none under the file's full the three cells read the
#        same words; the same with the repository named in another case (repo=LAB: the page answers it, so the rule
#        must); the same with the door's stored row of the instance deleted (a server DBA Dash added after the door's
#        last read: the screen's own Instance is the server name pgvigil collects sqlbox under), the row then read
#        again by TestLive; at normalized under the file's none batch_text and text read 'CREATE LOGIN pgv_c2 WITH
#        PASSWORD = ?; SELECT ?' and cursor_text 'ALTER LOGIN pgv_c2 WITH PASSWORD = ?' (the masked text through the
#        collector's normalizer); serve then runs D3's configuration again;
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
#     E2 (task 206: serve's way) the first real run goes through a pool handed to the import (ImportOptions.Store): one
#     'progress' line per batch of 2 (ceil(source / 2) for each mapping, the last at inserted = source) and one final
#     line per mapping at inserted = source; the pool answers after the import (Import leaves it open); the second run
#     goes through the dsn as before; a pgvigil_reader login's pool is refused ('may not write') as its dsn is.
#     E3 (the import's texts pass collection's masks) before the dry run, as sa, the instance's first dbo.JobHistory row
#     gets a message holding three credential forms with tokens made at run time (a sqlcmd command line's password
#     switch, a connection string's password pair, a ConvertTo-SecureString string; an UPDATE, so E's counts stay);
#     after the import pgvigil.mssql_job_runs holds that run (its history_id) once, its message with none of the
#     tokens and each form's '<masked>', the text around them kept, its job_name and step_name equal to DBA Dash's.
#  F. the version pin: with a newer version row '9.9.9' in the repository, every page answers ok with proven=false and
#     the note 'not proven on source version 9.9.9'; the row is removed again.
#  G. the imported server's tabs (task 168), under `pgvigil serve` built from a copy of this tree with the join's wiring
#     (internal/dbadash/testdata/join-168.patch applied to the copy; already applied, or no patch file once the release
#     join carries the wiring = said and used as it is) and the
#     web bundle rebuilt, on a pgvigil repository of its own whose configuration names the DBA Dash repository and no
#     instance, in a headless Chromium signed in as a UI user:
#     G0 (before the walk, Node) web/src/move_address.test.mjs: the move's prefill rule - which DBA Dash connection is
#        a network address, its host and port apart, else DBA Dash's Instance with why - every row 'ok';
#     G1 before any import, the DBA Dash instance's own page (#/dbadash?dr=lab&di=<id>) lists every SQL Server tab (as many
#        as web/src/router.ts mssqlInstanceTabs holds in the tree: 33 at task 168, 53 at the release join);
#        each renders with no error box: summary, performance, mssql_running, mssqlbackups, mssqljobs (with the SQL
#        Agent alerts), mssqlstorage (the Drives screen: 0 rows on Linux, as C's), mssqlfiles, mssqlconfig and
#        mssqlproperties as the repository's screens with rows (mssqlstorage: as many as part C's DrivesReport_Get),
#        every other tab its one 'not read for an imported server' line and no grid row; no tab but the seven live
#        screens holds 'DBADash' or 'DBA Dash' text; the tree shows 'Imported: lab' and no such text; the Imported servers
#        page names the source product on its settings line only;
#     G2 `pgvigil import dbadash -config <it> -repo lab` (the join's subcommand) exits 0 and makes the imported server
#        under DBA Dash's display name;
#     G3 the imported server at its own pgvigil instance (#/summary?i=<id>) lists the same tabs (Availability
#        kept); mssqlcpu and jobstimeline render pgvigil's own pages over the imported rows (a grid row or a chart),
#        mssqlstorage the imported database sizes from pgvigil's store (a grid row) above the Drives screen, the eight
#        other screen tabs as in G1, every other tab its one line; the tree as in G1. [s168-proof2 expected pgvigil's own
#        Storage page there; it lists the databases of pgvigil's own file read, which an imported server has not.]
# NOT PROVEN HERE: the page's machine-name and latest-snapshot guards on the buttons in a browser; the imported-server match
# with two repositories under one display name, a repository removed from the configuration, or a collection attempt on
# the imported server's name (read in the code and the review, not run); the 'volumes' mapping with rows
# when DBA Dash collects none (Linux: run with PGVIGIL_DBADASH_BAK of a Windows-side repository); pgvigil's own
# collector run after an import (the duplicates the docs' -to rule is about); a DBA Dash version other than 4.24.1;
# Azure SQL Database rows of a repository.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
# the DBA Dash release the repository is built with: 4.24.1 (the default) or 4.25.0, each zip pinned by the SHA-256
# GitHub's release lists for it (read 2026-11-14)
DDV=${PGVIGIL_DBADASH_VERSION:-4.24.1}
case "$DDV" in
  4.24.1) ZIP_SHA=c04f3cd949f89d93f72269a1223bea2153b7017a80823064b585997e8d632033 ;;
  4.25.0) ZIP_SHA=e3da8b4312d8b5b829ba14ecdc34ba65b07d00fb1bc5b9d8fb059d69ddd16dd1 ;;
  *) echo "FAIL: PGVIGIL_DBADASH_VERSION is 4.24.1 or 4.25.0 (the releases whose SHA-256 this proof holds)" >&2; exit 1 ;;
esac
CACHE=${PGVIGIL_DBADASH_CACHE:-$HOME/.cache/pgvigil-dbadash-$DDV}
SVC_SECS=${SVC_SECS:-180}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest; IMG_NET=mcr.microsoft.com/dotnet/runtime:10.0; IMG_PY=python:3.12-slim
ZIP_URL=https://github.com/trimble-oss/dba-dash/releases/download/$DDV/DBADash_$DDV.zip
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
    [[ "$(sha256sum "$part/z.zip" | cut -c1-64)" == "$ZIP_SHA" ]] || { rm -rf "$part"; fail "A: the release zip's SHA-256 is not the one of DBADash_$DDV.zip"; }
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
[[ "$VER" == "$DDV" || "$VER" == "$DDV".* ]] || fail "A: the repository's version is '$VER' (this run is of $DDV)"
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
echo "page read at $(date +%s) (the page side; the doorage review, finding 2: the gap to the pymssql read)"
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
label, only, mode = os.environ.get("LABEL", "C"), os.environ.get("ONLY", "").split(), os.environ.get("MODE", "compare")
# the pages' text columns and (MODE=compare) the second client's cells of them through the page's own mask: both from
# the package (TestMaskCells), so this script holds no copy of the mask or of the list
mask = json.load(open(os.environ["MASK"]))
textcols = lambda page: set(mask["columns"].get(page.split("@")[0], []))
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
if only: calls = {p: c for p, c in calls.items() if p in only}
if mode == "cells":   # the distinct texts of the text columns as a JSON list on stdout, and nothing else
    seen = {}
    for page, sqltext in calls.items():
        tcs = textcols(page)
        if not tcs: continue
        cur = con.cursor()
        cur.execute("SET NOCOUNT ON; " + sqltext)
        while True:
            if cur.description:
                idx = [i for i, c in enumerate(cur.description) if c[0] in tcs]
                for r in cur.fetchall():
                    for i in idx:
                        if isinstance(r[i], str) and r[i]: seen[r[i]] = None
            if not cur.nextset(): break
    json.dump(list(seen), sys.stdout); sys.exit(0)
raw = json.load(open(os.environ["CELLS"]))
assert len(raw) == len(mask["masked"]), "the mask step answered another number of texts than it was given"
masked = dict(zip(raw, mask["masked"]))
UNSEEN = chr(0) + "a text the mask step did not see"
import re
DUR = re.compile(r"^S(\d+) (\d\d):(\d\d):(\d\d)$")
AGE = re.compile(r"^(?!.*(Count|Fails)).*(Age|Days|Mins|Minutes|Hours)$|^(TimeSinceLast(Failed|Succeeded)|Days since Last Occurrence)$")   # Alerts_Get.sql L39: DATEDIFF(d, last_occurrence_utc, GETUTCDATE()), its unit first in the name   # AgentJob7Day.sql L29-30: DATEDIFF(mi, ..., GETUTCDATE()) at the call; a count (FailCount7Days, JobStepFails7Days) is never an age
bad, nonempty, clockcells = [], 0, [0]
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
# near()'s self-test (the doorage review, finding 4): a count is never a clock age, a minute age is 1 apart at most
assert not near("N2", "N3", "FailCount7Days") and near("N4", "N3", "TimeSinceLastSucceeded") and not near("N5", "N3", "TimeSinceLastSucceeded") \
    and near("N4", "N3", "Days since Last Occurrence") and not near("N2", "N3", "JobStepFails7Days"), "near() self-test"
clockcells[0] = 0
print(f"read at {int(datetime.datetime.now(datetime.timezone.utc).timestamp())} (the pymssql side; the doorage review, finding 2: the gap to the page read)", flush=True)
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
        tcs = textcols(page)
        def py(v, t, c):   # the second client's value; a text column's through the mask the page's cell passed
            if c in tcs and isinstance(v, str) and v: return "S" + masked.get(v, UNSEEN)
            return canon_py(v, t)
        # a text cell is never printed: a restored repository's may hold a credential form the mask does not know
        hide = lambda v, c: v if c not in tcs or v == "NULL" else "<a text of %d characters, not printed>" % (len(v) - 1)
        a = sorted(tuple(py(v, t, c) for v, t, c in zip(r, types, cols)) for r in rows)
        b = sorted(tuple(canon_pg(v, t) for v, t in zip(r, types)) for r in ps["rows"])
        if a != b:
            # a clock-computed cell is equal within near()'s tolerance (above); every other cell must be equal as it is.
            # NOT COVERED (the doorage review, finding 3, 2026-11-14): a count summed over hour buckets with a GETUTCDATE()
            # window (AgentJob7Day.sql L6-17) and a status cell derived from a clock age flip when the two reads straddle a
            # bucket's or a threshold's edge; a back-to-back re-read of both sides before C fails would cover them - not
            # built until the two 'read at' lines give the measured gap
            if not (len(a) == len(b) and all(len(x) == len(y) and all(near(p, q, c) for p, q, c in zip(x, y, cols)) for x, y in zip(a, b))):
                # the first pair near() refuses (a pair differing only in accepted clock cells is not it), and only its
                # cells near() refuses, by column name (the whole pair is long: a cut log loses the cells)
                diff = next(((x, y) for x, y in zip(a, b) if not (len(x) == len(y) and all(near(p, q, c) for p, q, c in zip(x, y, cols)))), None)
                cells = [f"{c}: DBA Dash {hide(p, c)} / page {hide(q, c)}" for p, q, c in zip(diff[0], diff[1], cols) if not near(p, q, c)] if diff else []
                pair = tuple(tuple(hide(v, c) for v, c in zip(side, cols)) for side in diff) if diff else None
                bad.append(f"{page} set {n+1}: the rows differ in {'; '.join(cells) or 'their order'} - first pair: {pair}")
        rows_seen += len(rows)
    if page == "sessions@snapshot" and rows_seen == 0: bad.append(f"{page}: 0 rows for the snapshot {snap}")
    nonempty += rows_seen > 0
    print(f"ok   {label}: {page}: {len(sets)} set(s), rows {[len(r) for _, r in sets]}, equal" if not any(x.startswith(page) for x in bad) else f"FAIL {label}: {page}")
if bad: print("\n".join("FAIL " + x for x in bad)); sys.exit(1)
if only:
    print(f"ok   {label}: {len(calls)} page(s) ({', '.join(calls)}) equal to DBA Dash's own procedure output through pymssql, {len(raw)} text cell(s) of it through the page's mask; {nonempty} with rows; {clockcells[0]} clock-relative cell(s) equal within 300 s or 1 unit")
    sys.exit(0)
if nonempty < 7: print(f"FAIL C: only {nonempty - 1} of 9 pages and the snapshot call returned rows"); sys.exit(1)
print(f"ok   C: 9 pages and the exact snapshot {snap} equal to DBA Dash's own procedure output through pymssql, {len(raw)} text cell(s) of it through the page's mask; {nonempty} with rows; {clockcells[0]} clock-relative cell(s) equal within 300 s or 1 unit")
PY
# the second client's container stays for C and C3 (one install of pymssql) and goes after C3
docker run -d --name "$PYC" --network "$NET" --label "$LBL" --env-file "$TMPD/sa.env" -v "$TMPD:/w:ro" "$IMG_PY" sleep 3600 >/dev/null
docker exec "$PYC" pip install -q --disable-pip-version-check --root-user-action=ignore "pymssql>=2.3,<2.4" 2>&1 | tail -3 || true
docker exec "$PYC" python -c 'import pymssql' || fail "C: pymssql did not install in the second client's container"
# grids <label> <the pages' folder under $TMPD> [<pages>]: the second client's call of each page's procedure against the
# page's reply in that folder (every page and the exact snapshot, or the pages named); its lines in grids-<label>.out
# The pages' text columns are shown through the credential mask, so the second client's cells of those columns pass the
# same mask first: TestMaskCells names the columns, the second client's texts of them go to a file of this run's folder
# (as stored: never printed, gone with the folder), TestMaskCells masks them, and the comparison reads both files.
grids() {
  local e=(-e ID="$ID" -e FROM="$FROM" -e TO="$TO" -e SNAP="$SNAPTXT" -e SQLHOST="$SQL" -e DDB="$DDB" -e PAGES="/w/$2" -e LABEL="$1" -e ONLY="${3:-}")
  PGVIGIL_DBADASH_MASK_OUT="$TMPD/mask-$1-list.json" go test -count=1 -run '^TestMaskCells$' ./internal/dbadash >/dev/null 2>&1 || fail "$1: the pages' text columns (TestMaskCells)"
  docker exec "${e[@]}" -e MODE=cells -e MASK="/w/mask-$1-list.json" "$PYC" python /w/grids.py > "$TMPD/cells-$1.json" || fail "$1: the second client's read of the text columns"
  PGVIGIL_DBADASH_MASK_IN="$TMPD/cells-$1.json" PGVIGIL_DBADASH_MASK_OUT="$TMPD/mask-$1.json" go test -count=1 -run '^TestMaskCells$' ./internal/dbadash >/dev/null 2>&1 || fail "$1: the mask over the second client's text cells (TestMaskCells)"
  docker exec "${e[@]}" -e MODE=compare -e MASK="/w/mask-$1.json" -e CELLS="/w/cells-$1.json" "$PYC" python /w/grids.py | tee "$TMPD/grids-$1.out" || true
}
grids C pages
grep -q "^ok   C: 9 pages and the exact snapshot" "$TMPD/grids-C.out" || fail "C: the pages are not DBA Dash's grids (the lines above)"
# C2: the text a page shows passes the collection's credential mask (the seeds after the comparison; tokens made now)
C2A="tk$RANDOM$RANDOM"; C2B="tk$RANDOM$RANDOM"; C2C="tk$RANDOM$RANDOM"; C2D="tk$RANDOM$RANDOM"
C2SNAP=$(sq "SELECT CONVERT(varchar(33), MAX(SnapshotDateUTC), 126) FROM dbo.RunningQueries WHERE InstanceID = $ID" "$DDB")
[[ "$C2SNAP" =~ ^[0-9]{4}- ]] || fail "C2: no running-queries snapshot of instance $ID: '$C2SNAP'"
C2SID=$(sq "SELECT MIN(session_id) FROM dbo.RunningQueries WHERE InstanceID = $ID AND SnapshotDateUTC = '$C2SNAP'" "$DDB")
[[ "$C2SID" =~ ^[0-9]+$ ]] || fail "C2: no session in the snapshot $C2SNAP: '$C2SID'"
C2H="0x$(python3 -c 'import secrets; print(secrets.token_hex(20))')"; C2HC="0x$(python3 -c 'import secrets; print(secrets.token_hex(20))')"
sqok "C2: the statement" "INSERT INTO dbo.QueryText (sql_handle, text, SnapshotDate) VALUES ($C2H, N'CREATE LOGIN pgv_c2 WITH PASSWORD = ''$C2A''; SELECT 1', SYSUTCDATETIME());
  UPDATE dbo.RunningQueries SET sql_handle = $C2H, statement_start_offset = NULL, statement_end_offset = NULL
   WHERE InstanceID = $ID AND SnapshotDateUTC = '$C2SNAP' AND session_id = $C2SID" "$DDB"
# the session's first cursor (the screen shows uniqueifier 1, created at or before the snapshot): its statement by its
# own handle, the offsets NULL, so cursor_text is the whole text
sqok "C2: the cursor's statement" "INSERT INTO dbo.QueryText (sql_handle, text, SnapshotDate) VALUES ($C2HC, N'ALTER LOGIN pgv_c2 WITH PASSWORD = ''$C2D''', SYSUTCDATETIME());
  DELETE dbo.RunningQueriesCursors WHERE InstanceID = $ID AND SnapshotDateUTC = '$C2SNAP' AND session_id = $C2SID AND uniqueifier = 1;
  INSERT INTO dbo.RunningQueriesCursors (InstanceID, SnapshotDateUTC, session_id, uniqueifier, sql_handle, creation_time_utc)
  VALUES ($ID, '$C2SNAP', $C2SID, 1, $C2HC, DATEADD(minute, -1, CAST('$C2SNAP' AS datetime2(7))))" "$DDB"
C2JOB=$(sq "SELECT TOP (1) name FROM dbo.Jobs WHERE InstanceID = $ID AND IsActive = 1 ORDER BY name" "$DDB")
C2ALERT=$(sq "SELECT TOP (1) name FROM dbo.Alerts WHERE InstanceID = $ID ORDER BY name" "$DDB")
# a restored repository's instance may have no job or no alert: that text is said as not run (the lab's has both)
if [[ -z "$C2JOB" || -z "$C2ALERT" ]]; then
  [[ -n "${PGVIGIL_DBADASH_BAK:-}" ]] || fail "C2: instance $ID has no job ('$C2JOB') or no alert ('$C2ALERT') to carry a text"
  [[ -n "$C2JOB" ]] || echo "not run: C2's job description (instance $ID has no job in the restored repository)"
  [[ -n "$C2ALERT" ]] || echo "not run: C2's alert message (instance $ID has no alert in the restored repository)"
fi
# a name goes into the T-SQL with its quotes doubled
QT="'"; C2JOBQ=${C2JOB//$QT/$QT$QT}; C2ALERTQ=${C2ALERT//$QT/$QT$QT}; c2want=2
if [[ -n "$C2JOB" ]]; then
  sqok "C2: the job's description" "UPDATE dbo.Jobs SET description = N'loads the warehouse; Server=db1;Database=app;User Id=etl;Password=$C2B;' WHERE InstanceID = $ID AND name = N'$C2JOBQ'" "$DDB"; c2want=$((c2want + 1))
fi
if [[ -n "$C2ALERT" ]]; then
  sqok "C2: the alert's message" "UPDATE dbo.Alerts SET notification_message = N'page the DBA: sqlcmd -S db1 -U ops -P $C2C -Q \"EXEC dbo.ack\"' WHERE InstanceID = $ID AND name = N'$C2ALERTQ'" "$DDB"; c2want=$((c2want + 1))
fi
src=$(sq "SELECT (SELECT COUNT(*) FROM dbo.QueryText WHERE sql_handle = $C2H AND text LIKE N'%$C2A%') + (SELECT COUNT(*) FROM dbo.Jobs WHERE InstanceID = $ID AND description LIKE N'%$C2B%')
  + (SELECT COUNT(*) FROM dbo.Alerts WHERE InstanceID = $ID AND notification_message LIKE N'%$C2C%')
  + (SELECT COUNT(*) FROM dbo.RunningQueriesCursors C JOIN dbo.QueryText T ON T.sql_handle = C.sql_handle
      WHERE C.InstanceID = $ID AND C.SnapshotDateUTC = '$C2SNAP' AND C.session_id = $C2SID AND C.uniqueifier = 1 AND T.text LIKE N'%$C2D%')" "$DDB")
[[ "$src" == "$c2want" ]] || fail "C2: DBA Dash's tables hold $src of the $c2want seeded tokens"
mkdir -p "$TMPD/pages-c2"
pages "$TMPD/pages-c2" | grep -c ' ok ' | grep -qx 9 || fail "C2: not every page answered after the seeds"
c2=$(python3 - "$TMPD/pages-c2" "$C2SID" "$C2JOB" "$C2ALERT" "$C2A" "$C2B" "$C2C" "$C2D" <<'PY'
import json, os, sys
d, sid, job, alert, toks = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5:]
def cell(page, keycol, key, col):
    r = json.load(open(os.path.join(d, page + ".json")))["results"][0]
    n = [c["name"] for c in r["columns"]]
    for row in r["rows"]:
        if row[n.index(keycol)] == key:
            return row[n.index(col)]
    return "NO ROW"
stmt = "CREATE LOGIN pgv_c2 WITH PASSWORD = '<masked>'; SELECT 1"
want = {"sessions batch_text": stmt, "sessions text": stmt, "sessions cursor_text": "ALTER LOGIN pgv_c2 WITH PASSWORD = '<masked>'"}
got = {k: cell("sessions", "session_id", sid, k.split()[1]) for k in want}
if job:
    want["jobs description"] = "loads the warehouse; Server=db1;Database=app;User Id=etl;Password=<masked>;"
    got["jobs description"] = cell("jobs", "name", job, "description")
if alert:
    want["alerts Notification Message"] = 'page the DBA: sqlcmd -S db1 -U ops -P <masked> -Q "EXEC dbo.ack"'
    got["alerts Notification Message"] = cell("alerts", "Alert Name", alert, "Notification Message")
bad = ["%s reads %r" % (k, got[k]) for k in want if got[k] != want[k]]
for p in ("sessions", "jobs", "alerts"):
    raw = open(os.path.join(d, p + ".json")).read()
    bad += ["the %s page's reply holds a seeded token" % p for t in toks if t in raw]
print("ok" if not bad else "; ".join(bad))
PY
)
[[ "$c2" == ok ]] || fail "C2: $c2"
echo "ok   C2: session $C2SID's batch_text, text and cursor_text, job ${C2JOB:-(none)}'s description and alert ${C2ALERT:-(none)}'s Notification Message are shown with their credential as <masked> and the words around it; no page's reply holds a token; DBA Dash's tables hold all $c2want"
# C3: the comparison again over the seeded pages (the second client reads the credentials as stored, the pages show them masked)
grids C3 pages-c2 "sessions jobs alerts"
grep -q "^ok   C3: 3 page(s)" "$TMPD/grids-C3.out" || fail "C3: the seeded pages are not DBA Dash's grids (the lines above)"
for t in "$C2A" "$C2B" "$C2C" "$C2D"; do ! grep -qF -- "$t" "$TMPD/grids-C3.out" || fail "C3: a line of the comparison holds a seeded token"; done
docker rm -f "$PYC" >/dev/null
echo "ok   C3: the sessions, jobs and alerts pages with the seeded credentials equal DBA Dash's own procedure output, the second client's text cells through the page's mask; no line of the comparison holds a token"

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
# D1w (0138): the Collection Errors cell's header follows the repository's version, its count words what DBA Dash's
# Summary_Upd used for the instance (4.25.0: its collection health when it has collection runs, else the 24 h errors)
words() { local code; code=$(curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" "$U/api/dbadash?repo=lab&id=$ID&part=statuses")
  [[ "$code" == 200 ]] || fail "D1w: GET part=statuses answered $code: $(cat "$BODY")"
  python3 -c 'import json,sys; t=json.load(open(sys.argv[1])).get("statuses") or {}; c=t.get("columns") or []
r=[dict(zip(c, x)) for x in (t.get("rows") or [])]; r=[x for x in r if x.get("status_key") == "CollectionErrorStatus"]
print((r[0]["label"] + "|" + (r[0]["detail"] or "")) if r else "no CollectionErrorStatus row")' "$BODY"; }
runs=$(sq "IF OBJECT_ID(N'dbo.CollectionRunStatus') IS NULL SELECT -1 ELSE SELECT COUNT(*) FROM dbo.CollectionRunStatus WHERE InstanceID = $ID" "$DDB")
ecount=$(sq "SELECT ISNULL(CollectionErrorCount, 0) FROM dbo.Summary WHERE InstanceID = $ID" "$DDB")
w1=$(words)
if [[ "$runs" == -1 ]]; then
  [[ "$w1" == "DBA Dash Errors (24hrs)|$ecount error(s) in 24 h" ]] || fail "D1w: on $VER (no dbo.CollectionRunStatus) the cell reads '$w1' (want 'DBA Dash Errors (24hrs)|$ecount error(s) in 24 h')"
  echo "ok   D1w: on $VER the cell reads '$w1' (DBA Dash's 4.24.1 words; no collection runs recorded there)"
else
  if [[ "$runs" == 0 && -n "${PGVIGIL_DBADASH_BAK:-}" ]]; then
    # a restored repository's lowest active instance may be collected by a service older than 4.25.0 at its site
    [[ "$w1" == "Collection Health|$ecount error(s) in 24 h" ]] || fail "D1w: on $VER (restored) an instance without collection runs reads '$w1' (want 'Collection Health|$ecount error(s) in 24 h')"
    echo "ok   D1w: on $VER (restored) the cell reads '$w1' (an instance without collection runs: the 24 h errors)"
  else
  [[ "$runs" =~ ^[1-9][0-9]*$ ]] || fail "D1w: DBA Dash $VER's service recorded no collection run of the instance ($runs rows in dbo.CollectionRunStatus)"
  [[ "$w1" == "Collection Health|$ecount collection(s) at warning or critical" ]] || fail "D1w: on $VER with $runs collection runs the cell reads '$w1' (want 'Collection Health|$ecount collection(s) at warning or critical')"
  if [[ -z "${PGVIGIL_DBADASH_BAK:-}" ]]; then
    # D1s: dbo.Summary is DBA Dash's cache - a row written before the repository became 4.25.0 holds the 24 h errors
    # (a downgrade to 4.24.1 an hour on and the upgrade to $VER an hour after it: the repository is $VER from that deploy)
    # DeployDate is datetime2(3): the literals carry exactly its three digits, so the DELETE below finds the rows again
    DEP1=$(sq "SELECT CONVERT(varchar(23), CAST(DATEADD(hour, 1, SYSUTCDATETIME()) AS datetime2(3)), 121)" "$DDB")
    DEP2=$(sq "SELECT CONVERT(varchar(23), CAST(DATEADD(hour, 2, SYSUTCDATETIME()) AS datetime2(3)), 121)" "$DDB")
    sqok "D1s: two newer deploy rows" "INSERT INTO dbo.DBVersionHistory (DeployDate, Version) VALUES ('$DEP1', '4.24.1.0'), ('$DEP2', '$VER')" "$DDB"
    PGVIGIL_DBADASH_CONFIG="$TMPD/d.yaml" go test -count=1 -run '^TestLive$' ./internal/dbadash >/dev/null 2>&1 || fail "D1s: the door's read with the newer deploy rows"
    ws=$(words)
    sqok "D1s: the deploy rows removed" "DELETE FROM dbo.DBVersionHistory WHERE DeployDate IN ('$DEP1', '$DEP2')" "$DDB"
    left=$(sq "SELECT COUNT(*) FROM dbo.DBVersionHistory WHERE DeployDate > SYSUTCDATETIME()" "$DDB")
    [[ "$left" == 0 ]] || fail "D1s: $left deploy row(s) dated after now are left in dbo.DBVersionHistory (the removal missed them)"
    [[ "$ws" == "Collection Health|$ecount error(s) in 24 h" ]] || fail "D1s: a Summary row written before the $VER deploy reads '$ws' (want 'Collection Health|$ecount error(s) in 24 h')"
    echo "ok   D1s: a Summary row written before the repository's $VER deploy (4.24.1 at $DEP1, $VER at $DEP2) reads '$ws'; the rows removed"
    # D1p: a read login that sees dbo.CollectionRunStatus (VIEW DEFINITION) but may not SELECT it; the lab container
    # holds it until the container goes
    NAR=pgv_ddnar_$SUF; NAR_PW=$(pw)
    sqok "D1p: the narrow read login" "CREATE LOGIN [$NAR] WITH PASSWORD = '$NAR_PW', CHECK_POLICY = OFF; USE [$DDB]; CREATE USER [$NAR] FOR LOGIN [$NAR];
      GRANT VIEW DEFINITION TO [$NAR]; GRANT SELECT ON dbo.Instances TO [$NAR]; GRANT SELECT ON dbo.Summary TO [$NAR];
      GRANT SELECT ON dbo.CollectionDates TO [$NAR]; GRANT SELECT ON dbo.DBVersionHistory TO [$NAR];"
    PGV_DD_RO="sqlserver://$NAR:$(urlq "$NAR_PW")@127.0.0.1:$PORT_SQL?database=$DDB&encrypt=true&TrustServerCertificate=true" PGVIGIL_DBADASH_CONFIG="$TMPD/d.yaml" \
      go test -count=1 -run '^TestLive$' ./internal/dbadash >"$TMPD/d1p.out" 2>&1 || fail "D1p: the narrow login's read failed: $(grep -m1 -iE 'denied|error' "$TMPD/d1p.out" | cut -c1-300)"
    wp=$(words)
    [[ "$wp" == "Collection Health|$ecount" ]] || fail "D1p: the narrow login's cell reads '$wp' (want the bare count 'Collection Health|$ecount')"
    echo "ok   D1p: a login without SELECT on dbo.CollectionRunStatus reads the repository; the cell '$wp' (the count without its words)"
    PGVIGIL_DBADASH_CONFIG="$TMPD/d.yaml" go test -count=1 -run '^TestLive$' ./internal/dbadash >/dev/null 2>&1 || fail "D1p: the read login's read again"
  fi
  # the same instance as one a service older than 4.25.0 collects: its runs removed, DBA Dash's Summary_Upd again, the door's read again
  sqok "D1w: the runs removed" "DELETE dbo.CollectionRunStatus WHERE InstanceID = $ID; EXEC dbo.Summary_Upd;" "$DDB"
  ecount2=$(sq "SELECT ISNULL(CollectionErrorCount, 0) FROM dbo.Summary WHERE InstanceID = $ID" "$DDB")
  PGVIGIL_DBADASH_CONFIG="$TMPD/d.yaml" go test -count=1 -run '^TestLive$' ./internal/dbadash >/dev/null 2>&1 || fail "D1w: the door's read after Summary_Upd"
  w2=$(words)
  [[ "$w2" == "Collection Health|$ecount2 error(s) in 24 h" ]] || fail "D1w: with no collection runs the cell reads '$w2' (want 'Collection Health|$ecount2 error(s) in 24 h')"
  echo "ok   D1w: on $VER the cell reads '$w1' with $runs collection runs, and '$w2' once they were removed and Summary_Upd ran again (the 24 h errors, as DBA Dash chooses for an instance without runs)"
  fi
fi
# D1t / D2t: the instance's query_text on the statements a page shows (the read rule's wiring in q_dbadash.go)
textrule=0; grep -q 'Statements(' internal/web/q_dbadash.go 2>/dev/null && textrule=1; [[ "${PGVIGIL_DOOR_TEXTRULE:-}" == 1 ]] && textrule=1
# stmts <row> [<repo>]: the three statement cells of C2's session on the sessions page, as serve answers them
stmts() { local code; code=$(curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" "$U/api/dbadash?repo=${2:-lab}&id=$ID&page=sessions")
  [[ "$code" == 200 ]] || fail "$1: GET page=sessions (repo=${2:-lab}) answered $code: $(cat "$BODY")"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"][0]; n=[c["name"] for c in r["columns"]]
row=[x for x in r["rows"] if x[n.index("session_id")] == int(sys.argv[2])]
print("|".join(str(row[0][n.index(c)]) for c in ("batch_text", "text", "cursor_text")) if row else "NO ROW")' "$BODY" "$C2SID"; }
WORDS="(not shown: this instance's query_text policy is none)"; WORDS3="$WORDS|$WORDS|$WORDS"
if [[ $textrule == 1 ]]; then
  # the file at none, sqlbox at full: a wrong match of the instance to sqlbox would show the statements
  { echo "query_text: none"; cfg "    query_text: full"; } > "$TMPD/d-qt1.yaml"
  serve "$TMPD/d-qt1.yaml"
  code=$(curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" "$U/api/dbadash?repo=lab&part=imported")
  [[ "$code" == 200 ]] || fail "D1t: GET part=imported answered $code: $(cat "$BODY")"
  nimp=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
if "imported" not in d: print("NOKEY"); sys.exit(0)
t=d["imported"] or {}; c=t.get("columns") or []
print(sum(1 for r in (t.get("rows") or []) if r[c.index("source_id")] == int(sys.argv[2])))' "$BODY" "$ID")
  [[ "$nimp" == 0 ]] || fail "D1t: part=imported holds '$nimp' row(s) for instance $ID before pgvigil collects the server (want 0)"
  got=$(stmts D1t); [[ "$got" == "$WORDS3" ]] || fail "D1t: no pgvigil instance matches and the file's query_text is none: the cells read '$got' (want the words '$WORDS' in all three)"
  echo "ok   D1t: no pgvigil instance matches (part=imported: no row of instance $ID); under the file's query_text none, sqlbox at full, session $C2SID's batch_text, text and cursor_text read '$WORDS'"
  serve "$TMPD/d.yaml"
else
  echo "not run here: D1t and D2t (the instance's query_text on the statements a page shows) need a tree whose internal/web/q_dbadash.go calls Statements (scripts/importmasklive-wiring.patch over the read rule)"
fi
if [[ -n "${PGVIGIL_DBADASH_BAK:-}" ]]; then
  echo "not proven: D2-D4 (the restored repository's instance is another server than this run's container; run without PGVIGIL_DBADASH_BAK for them)"
else
"$BIN" collect -config "$TMPD/d.yaml" -instance sqlbox -once mssql_instance >"$TMPD/collect.out" 2>&1 || { cat "$TMPD/collect.out" >&2; fail "D2: collect"; }
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
p2=$(part); echo "$p2" | grep -qE "^1 .*instance_id=$SB( |$)" && echo "$p2" | grep -q 'name=sqlbox' || fail "D2: part=pgvigil after the collect: $p2 (want instance $SB sqlbox)"
echo "ok   D2: after pgvigil collected sqlbox ($SERVERNAME): part=pgvigil names instance $SB sqlbox"
# D2x (task 206, review 206f 1): the collector's own XE read stores the DBA Dash sessions it lists (xe.go's tail through
# import_mssql_xe), a stopped one with its ring buffer, and the count the server itself gives
sqok "D2x: a DBA Dash-named session" "CREATE EVENT SESSION [DBADash_T206] ON SERVER ADD EVENT sqlserver.error_reported ADD TARGET package0.ring_buffer;"
"$BIN" collect -config "$TMPD/d.yaml" -instance sqlbox -once mssql_xe >"$TMPD/collect-xe.out" 2>&1 || { cat "$TMPD/collect-xe.out" >&2; fail "D2x: collect mssql_xe"; }
xhand=$(sq "SELECT COUNT(*) FROM sys.server_event_sessions WHERE name LIKE N'DBADash[_]%'")
xgot=$(pq "SELECT coalesce((SELECT running::text || '|' || array_to_string(targets, ',') FROM pgvigil.mssql_xe_foreign WHERE instance_id = $SB AND name = 'DBADash_T206'), 'none') || '|' || coalesce((SELECT sessions::text FROM pgvigil.mssql_xe_foreign_read WHERE instance_id = $SB), 'no read')")
[[ "$xgot" == "false|ring_buffer|$xhand" ]] || fail "D2x: the stored DBA Dash sessions: '$xgot' (want 'false|ring_buffer|$xhand': DBADash_T206 stopped with its ring buffer, and the server's own count)"
sqok "D2x: the session dropped" "DROP EVENT SESSION [DBADash_T206] ON SERVER;"
echo "ok   D2x: the collector's XE read stored DBA Dash's sessions as the server lists them ($xhand, DBADash_T206 stopped with its ring_buffer); the session dropped"
if [[ $textrule == 1 ]]; then
  cfg "    query_text: none" > "$TMPD/d-qt2.yaml"
  serve "$TMPD/d-qt2.yaml"
  got=$(stmts D2t); [[ "$got" == "$WORDS3" ]] || fail "D2t: the matched sqlbox at query_text none under the file's full: the cells read '$got' (want the words in all three)"
  # the repository named in another case: the page answers it, so the rule finds the same instance
  got=$(stmts D2t LAB); [[ "$got" == "$WORDS3" ]] || fail "D2t: repo=LAB, the matched sqlbox at query_text none under the file's full: the cells read '$got' (want the words in all three)"
  # the door's stored row of the instance gone (a server DBA Dash added after the door's last read): the screen's own
  # Instance is the server name pgvigil collects sqlbox under
  pq "DELETE FROM pgvigil.dbadash_instances WHERE repository = 'lab' AND instance_id = $ID" >/dev/null
  [[ "$(pq "SELECT count(*) FROM pgvigil.dbadash_instances WHERE repository = 'lab' AND instance_id = $ID")" == 0 ]] || fail "D2t: the door's stored row of instance $ID was not deleted"
  got=$(stmts D2t); [[ "$got" == "$WORDS3" ]] || fail "D2t: the door's stored row of the instance deleted, sqlbox (collected as $SERVERNAME) at query_text none under the file's full: the cells read '$got' (want the words in all three)"
  PGVIGIL_DBADASH_CONFIG="$TMPD/d.yaml" go test -count=1 -run '^TestLive$' ./internal/dbadash >/dev/null 2>&1 || fail "D2t: the door's read again"
  [[ "$(pq "SELECT count(*) FROM pgvigil.dbadash_instances WHERE repository = 'lab' AND instance_id = $ID")" == 1 ]] || fail "D2t: the door's read did not store instance $ID again"
  { echo "query_text: none"; cfg "    query_text: normalized"; } > "$TMPD/d-qt3.yaml"
  serve "$TMPD/d-qt3.yaml"
  NORM="CREATE LOGIN pgv_c2 WITH PASSWORD = ?; SELECT ?"; NORMC="ALTER LOGIN pgv_c2 WITH PASSWORD = ?"
  got=$(stmts D2t); [[ "$got" == "$NORM|$NORM|$NORMC" ]] || fail "D2t: the matched sqlbox at query_text normalized under the file's none: the cells read '$got' (want '$NORM' twice, then '$NORMC')"
  echo "ok   D2t: the matched sqlbox at query_text none (the file's full): the words, also under repo=LAB and with the door's stored row of the instance deleted (read again after); at normalized (the file's none): '$NORM' and the cursor's '$NORMC'"
  serve "$TMPD/d.yaml"
fi
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
  PGVIGIL_DBADASH_IMPORT_STORE="${3:-0}" go test -count=1 -run '^TestLiveImport$' -v ./internal/dbadash 2>&1 | grep -E '^(import |progress |store open after: )' || true; }
declare -A want=([cpu]=$n_cpu [volumes]=$n_vol [dbsize]=$n_dbs [jobruns]=$n_job)
field() { echo "$1" | grep "^import $ID [0-9]* $2 " | sed -n "s/.* $3=\([0-9]*\).*/\1/p"; }
# E3: one run's message carries three credential forms (tokens made now)
HID=$(sq "SELECT TOP (1) CAST(instance_id AS bigint) FROM dbo.JobHistory WHERE InstanceID = $ID ORDER BY RunDateTime, instance_id" "$DDB")
[[ "$HID" =~ ^[0-9]+$ ]] || fail "E3: no dbo.JobHistory row of instance $ID: '$HID'"
E3A="tk$RANDOM$RANDOM"; E3B="tk$RANDOM$RANDOM"; E3C="tk$RANDOM$RANDOM"
E3MSG="Executed as user: proof. sqlcmd -S db1 -U agent -P $E3A -Q \"EXEC dbo.load\" then Server=db1;Database=app;User Id=agent;Password=$E3B; then \$p = ConvertTo-SecureString ''$E3C'' -AsPlainText -Force. The step succeeded."
sqok "E3: the message" "UPDATE dbo.JobHistory SET message = N'$E3MSG' WHERE InstanceID = $ID AND instance_id = $HID" "$DDB"
[[ "$(sq "SELECT COUNT(*) FROM dbo.JobHistory WHERE InstanceID = $ID AND message LIKE N'%$E3C%'" "$DDB")" == 1 ]] || fail "E3: the seeded message is not on exactly one row"
E3NAMES=$(sq "SELECT ISNULL(J.name, N'') + N'|' + ISNULL(H.step_name, N'') FROM dbo.JobHistory H LEFT JOIN dbo.Jobs J ON J.InstanceID = H.InstanceID AND J.job_id = H.job_id WHERE H.InstanceID = $ID AND H.instance_id = $HID" "$DDB")
dry=$(imp "$PGDSN" 1); echo "$dry"
for m in cpu volumes dbsize jobruns; do
  [[ "$(field "$dry" "$m" source)" == "${want[$m]}" && "$(field "$dry" "$m" inserted)" == 0 ]] || fail "E: the dry run of $m: $(echo "$dry" | grep " $m ") (want source=${want[$m]} inserted=0)"
done
one=$(imp "$PGDSN" 0 1); echo "$one" | grep -v '^progress '
for m in cpu volumes dbsize jobruns; do
  s=$(field "$one" "$m" source); i=$(field "$one" "$m" inserted); t=$(field "$one" "$m" stored)
  [[ "$s" == "${want[$m]}" && "$i" == "$s" && "$t" == "$s" ]] || fail "E: $m: source=$s inserted=$i stored=$t (want ${want[$m]} each)"
  # E2: Progress per batch of 2, then the mapping's final line
  nb=$(echo "$one" | grep -c "^progress $ID $m inserted=[0-9]* final=0$" || true)
  lastb=$(echo "$one" | grep "^progress $ID $m inserted=[0-9]* final=0$" | tail -1 | sed -n 's/.*inserted=\([0-9]*\).*/\1/p' || true)
  fin=$(echo "$one" | grep "^progress $ID $m inserted=[0-9]* final=1$" | sed -n 's/.*inserted=\([0-9]*\).*/\1/p' || true)
  [[ "$nb" == "$(( (${want[$m]} + 1) / 2 ))" && "$fin" == "${want[$m]}" && ( ${want[$m]} == 0 || "$lastb" == "${want[$m]}" ) ]] \
    || fail "E2: $m's progress: $nb batch line(s) ending at '${lastb}', final '${fin}' (want $(( (${want[$m]} + 1) / 2 )) ending at ${want[$m]}, final ${want[$m]})"
done
echo "$one" | grep -qx 'store open after: ok' || fail "E2: the pool handed to the import does not answer after it: $(echo "$one" | grep '^store open after')"
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
[[ "$(pq "SELECT count(*) FROM pgvigil.mssql_job_runs WHERE instance_id = $PID_IMP AND history_id = $HID")" == 1 ]] || fail "E3: pgvigil holds run $HID $(pq "SELECT count(*) FROM pgvigil.mssql_job_runs WHERE instance_id = $PID_IMP AND history_id = $HID") time(s) (want 1)"
E3GOT=$(pq "SELECT message FROM pgvigil.mssql_job_runs WHERE instance_id = $PID_IMP AND history_id = $HID")
for tk in "$E3A" "$E3B" "$E3C"; do [[ "$E3GOT" != *"$tk"* ]] || fail "E3: a credential token is stored: $E3GOT"; done
for w in '-P <masked> -Q' 'Password=<masked>;' 'ConvertTo-SecureString <masked>' 'Database=app' 'The step succeeded.'; do
  [[ "$E3GOT" == *"$w"* ]] || fail "E3: the stored message has no '$w': $E3GOT"
done
[[ "$(pq "SELECT coalesce(job_name, '') || '|' || coalesce(step_name, '') FROM pgvigil.mssql_job_runs WHERE instance_id = $PID_IMP AND history_id = $HID")" == "$E3NAMES" ]] || fail "E3: the run's names changed: want '$E3NAMES'"
echo "ok   E3: run $HID's message stored with its three credentials masked and the text around them kept: $E3GOT; names '$E3NAMES' as DBA Dash's"
psql "$ADMIN_DSN" -Xqc "CREATE ROLE $PGRO LOGIN IN ROLE pgvigil_reader" >/dev/null
ROPG="$PGDSN user=$PGRO"; ROPG="${ROPG/user=postgres /}"
bad=$(PGVIGIL_DBADASH_IMPORT_DSN="$PGV_DD_RO" PGVIGIL_DBADASH_IMPORT_REPO="$ROPG" go test -count=1 -run '^TestLiveImport$' -v ./internal/dbadash 2>&1 | grep '^import error' || true)
echo "$bad" | grep -q 'may not write' || fail "E: the import as a pgvigil_reader login was not refused: $bad"
bad=$(PGVIGIL_DBADASH_IMPORT_DSN="$PGV_DD_RO" PGVIGIL_DBADASH_IMPORT_REPO="$ROPG" PGVIGIL_DBADASH_IMPORT_STORE=1 go test -count=1 -run '^TestLiveImport$' -v ./internal/dbadash 2>&1 | grep '^import error' || true)
echo "$bad" | grep -q 'may not write' || fail "E2: the import through a pgvigil_reader login's pool was not refused: $bad"
echo "ok   E: dry run counts equal the source (cpu ${want[cpu]}, volumes ${want[volumes]}, dbsize ${want[dbsize]}, jobruns ${want[jobruns]}); the import (through a pool handed to it, one progress line per batch, the pool open after) inserted and pgvigil's tables hold exactly those, in batches of 2; a second run (its dsn) inserted 0; instance '$DISP' engine sqlserver with env:proof ($nsys DBA Dash system tag(s) left out); a pgvigil_reader login refused (dsn and pool)"

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
if [ ! -f "$GSRC/$JP" ]; then grep -q importedPage "$GSRC/web/src/main.ts" || fail "G: no $JP and the tree lacks the join's wiring (web/src/main.ts has no importedPage)"; echo "G: no wiring patch in the tree: the release join carries the wiring (the tree is used as it is)"
elif (cd "$GSRC" && git apply --check -R "$JP" 2>/dev/null); then echo "G: the join's wiring is already in this tree"
elif (cd "$GSRC" && git apply "$JP" 2>"$TMPD/g-apply.err"); then echo "G: the join's wiring applied to the run's copy"
else fail "G: $JP neither applies nor is applied: $(cat "$TMPD/g-apply.err")"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/g-web.log" 2>&1 && npm run build >>"$TMPD/g-web.log" 2>&1) || { tail -20 "$TMPD/g-web.log" >&2; fail "G: the web build"; }
# G0: the move's prefill rule (web/src/move_address.ts: which DBA Dash connection is a network address) in Node
"$GSRC/web/node_modules/.bin/esbuild" "$GSRC/web/src/move_address.ts" --format=esm --outfile="$TMPD/move_address.mjs" --log-level=warning || fail "G0: move_address.ts did not compile"
node "$GSRC/web/src/move_address.test.mjs" "$TMPD/move_address.mjs" > "$TMPD/g0-unit.out" 2>&1 || { cat "$TMPD/g0-unit.out"; fail "G0: the move's prefill unit tests"; }
echo "ok   G0: the move's prefill rule: $(tail -1 "$TMPD/g0-unit.out")"
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
// the app reads its session when it loads: a real load after the login (a hash change would keep the login screen)
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
await cmd('Page.navigate', { url: U + start }); await sleep(800);
const mainText = async () => (await ev(`(document.querySelector('main')?.innerText ?? '(no main)').replace(/\\s+/g, ' ').slice(0, 300)`)) ?? '';
if (!await settled()) { console.log(`FAIL render start: ${await mainText()}`); process.exit(1); }
const tabs = await ev(`(() => { const d = document.querySelector('main [data-all]') ?? document.querySelector('#tabs'); return d?.dataset.all ? JSON.parse(d.dataset.all) : null; })()`);
if (!Array.isArray(tabs)) { console.log(`FAIL no tab list: ${await mainText()}`); process.exit(1); }
// the tree: its Imported folder drawn (the read arrives after the first draw), no source-product name in it
let tree = '';
for (let i = 0; i < 40 && !/Imported: lab/.test(tree); i++) { await sleep(250); tree = await ev(`document.getElementById('tree')?.innerText ?? ''`); }
console.log(`tree ${/Imported: lab/.test(tree) ? 'folder' : 'nofolder'} ${/DBA ?Dash/.test(tree) ? 'named' : 'clean'}`);
// the Imported servers page: the source product only on its settings line
await cmd('Page.navigate', { url: U + '#/dbadash' }); await sleep(300);
if (!await settled()) { console.log(`FAIL render root: ${await mainText()}`); process.exit(1); }
const rootNamed = await ev(`(() => { const m = document.querySelector('main').cloneNode(true); m.querySelectorAll('[data-source-line]').forEach(e => e.remove()); return /DBA ?Dash/.test(m.innerText ?? m.textContent); })()`);
const lines = await ev(`[...document.querySelectorAll('main [data-source-line]')].filter(e => /DBA ?Dash/.test(e.textContent)).length`);
console.log(`root ${rootNamed ? 'named' : 'clean'} source-lines=${lines}`);
for (const h of tabs) {
  const key = /[?&]dp=([^&]+)/.exec(h)?.[1] ?? /^#\/([^?]+)/.exec(h)?.[1];
  await cmd('Page.navigate', { url: U + h }); await sleep(300);
  if (!await settled()) { console.log(`tab ${key} render=no: ${await mainText()}`); continue; }
  const r = await ev(`(() => { const m = document.querySelector('main'); const s = m.querySelector('[data-source]');
    const rows = [...m.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty') && tr.children.length > 0).length;
    return JSON.stringify({ src: s?.dataset.source ?? 'native', rows: s?.dataset.rows ?? '-', trs: rows, charts: m.querySelectorAll('canvas, svg').length,
      notread: m.querySelectorAll('p.notread').length, errors: m.querySelectorAll('.error:not([role=status])').length, named: /DBA ?Dash/.test(m.innerText) ? 1 : 0 }); })()`);
  const o = JSON.parse(r);
  console.log(`tab ${key} render=yes source=${o.src} rows=${o.rows} trs=${o.trs} charts=${o.charts} notread=${o.notread} named=${o.named} errors=${o.errors}`);
}
ws.close();
process.exit(0);
JS
gwalk() { G_USR="$USR" G_UPW="$UPW" node "$TMPD/g-check.mjs" "$CDP" "$U/" "$1"; }
# the SQL Server tab set the walk must find: the keys of mssqlInstanceTabs in the tree the run built (names, not only a
# count: the walk lists the same object, so a renamed or dropped tab must fail by name), and task 168's 33 among them
GKEYS=$(python3 - "$GSRC/web/src/router.ts" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
b = re.search(r"export const mssqlInstanceTabs: Record<string, string> = \{(.*?)\n\};", t, re.S)
body = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", b.group(1), flags=re.S)) if b else ""
print(" ".join(sorted(re.findall(r"(?m)(?:^|,|\{)\s*([A-Za-z_0-9]+)\s*:\s*['\"`]", body))))
PY
)
read -ra GK <<<"$GKEYS"; GWANT=${#GK[@]}
[[ "$GWANT" =~ ^[0-9]+$ && "$GWANT" -gt 0 ]] || fail "G: no mssqlInstanceTabs in $GSRC/web/src/router.ts"
G168="availability counters findings jobstimeline mssql_blocked mssql_deadlocks mssql_running mssql_slow mssql_waits mssqlactions mssqlaudit mssqlbackups mssqlchecks mssqlconfig mssqlcpu mssqlerrorlog mssqlfileio mssqlfiles mssqlhealth mssqlindexes mssqlindexlocks mssqljobs mssqlmemory mssqlplancache mssqlprocs mssqlproperties mssqlqs mssqlstorage mssqltempdb mssqltrace performance rowversions summary"
for k in $G168; do [[ " $GKEYS " == *" $k "* ]] || fail "G: task 168's SQL Server tab $k is no longer in router.ts mssqlInstanceTabs"; done
# gtabs <walk output> <store tabs> <screen tabs>: every listed tab as said, every other its one line
gtabs() {
  local out="$1" store=" $2 " screen=" $3 " data=" performance mssql_running mssqlbackups mssqljobs mssqlfiles mssqlconfig mssqlstorage " n line k
  n=$(echo "$out" | grep -c '^tab ' || true); [[ "$n" == "$GWANT" ]] || fail "$4: $n tabs walked (want $GWANT, router.ts mssqlInstanceTabs): $out"
  local walked; walked=$(echo "$out" | awk '/^tab /{print $2}' | LC_ALL=C sort | tr '\n' ' ')
  [[ "$walked" == "$(printf '%s\n' "${GK[@]}" | LC_ALL=C sort | tr '\n' ' ')" ]] || fail "$4: the walked tabs ($walked) are not router.ts mssqlInstanceTabs ($GKEYS)"
  for k in $2 $3; do [[ " $GKEYS " == *" $k "* ]] || fail "$4: $k is no longer a SQL Server tab in router.ts"; done
  echo "$out" | grep -q '^tree folder clean$' || fail "$4: the tree: $(echo "$out" | grep '^tree')"
  echo "$out" | grep -q '^root clean source-lines=1$' || fail "$4: the Imported servers page: $(echo "$out" | grep '^root')"
  while read -r line; do
    k=$(echo "$line" | awk '{print $2}')
    [[ "$line" == *" render=yes "* && "$line" == *" errors=0" ]] || fail "$4: $line"
    # pgvigil's own words name no source product; a live screen's rows are the source's data and may (a session's program name)
    [[ "$data" == *" $k "* || "$line" == *" named=0 "* ]] || fail "$4: $k names the source product in pgvigil's words: $line"
    if [[ "$store" == *" $k "* ]]; then
      [[ "$line" == *" source=store "* ]] || fail "$4: $k is not pgvigil's own page over the imported rows: $line"
      t=$(echo "$line" | sed -n 's/.* trs=\([0-9]*\) charts=\([0-9]*\) .*/\1 \2/p'); (( ${t% *} + ${t#* } > 0 )) || fail "$4: $k shows no imported row: $line"
    elif [[ "$screen" == *" $k "* ]]; then
      [[ "$line" == *" source=screen "* ]] || fail "$4: $k is not the repository's screen: $line"
      r=$(echo "$line" | sed -n 's/.* rows=\([0-9]*\) .*/\1/p')
      [[ "$k" == mssqlstorage ]] && { [[ "$r" == "$n_drv" ]] || fail "$4: the Drives screen shows $r rows (want $n_drv, part C's DrivesReport_Get)"; } || (( r > 0 )) || fail "$4: $k shows no row: $line"
    else
      [[ "$line" == *" source=none "* && "$line" == *" notread=1 "* && "$line" == *" trs=0 "* ]] || fail "$4: $k is not one 'not read' line: $line"
    fi
  done < <(echo "$out" | grep '^tab ')
}
SCREENS="summary performance mssql_running mssqlbackups mssqljobs mssqlfiles mssqlconfig mssqlproperties"
# the Drives screen's rows as part C read them (DrivesReport_Get through the read login)
n_drv=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(len(s.get("rows") or []) for s in d.get("results") or []))' "$TMPD/pages/drives.json")
g1=$(gwalk "#/dbadash?dr=lab&di=$ID") || fail "G1: the Chromium walk stopped: $g1"
gtabs "$g1" "" "$SCREENS mssqlstorage" G1
echo "ok   G1: the DBA Dash instance's own page: $GWANT tabs, $(echo "$g1" | grep -c 'source=screen') from the repository's screens, $(echo "$g1" | grep -c 'source=none') with their one 'not read' line, no error; the tree 'Imported: lab' and no source-product name"
"$BIN" import dbadash -config "$TMPD/g.yaml" -repo lab >"$TMPD/g-import.out" 2>&1 || { cat "$TMPD/g-import.out" >&2; fail "G2: pgvigil import dbadash"; }
GID=$(psql "$GDSN" -XAtq -c "SELECT instance_id FROM pgvigil.instances WHERE name = '$DISP' AND engine = 'sqlserver'")
[[ "$GID" =~ ^[1-9][0-9]*$ ]] || { cat "$TMPD/g-import.out" >&2; fail "G2: no imported server named $DISP"; }
echo "ok   G2: pgvigil import dbadash -repo lab: exit 0, the imported server $DISP is pgvigil instance $GID ($(tail -1 "$TMPD/g-import.out"))"
g3=$(gwalk "#/summary?i=$GID") || fail "G3: the Chromium walk stopped: $g3"
gtabs "$g3" "mssqlcpu mssqlstorage jobstimeline" "$SCREENS" G3
echo "ok   G3: the imported server at pgvigil instance $GID: $GWANT tabs, $(echo "$g3" | grep -c 'source=store') of pgvigil's own pages over the imported rows, $(echo "$g3" | grep -c 'source=screen') screens, $(echo "$g3" | grep -c 'source=none') 'not read' lines, no error; the tree as in G1"
kill "$CHRPID" 2>/dev/null || true; CHRPID=
kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=

echo "Not proven here: the buttons' machine-name and latest-snapshot guards in a browser;"
echo "the 'volumes' mapping with rows when DBA Dash collected none ($n_vol here); a DBA Dash version other than $VER; Azure SQL Database rows."
echo "proof-dbadash-door: OK (DBA Dash $VER; 9 pages equal to DBA Dash's grids; an action refused without the actions login, done with it; the import's counts equal the source's; every SQL Server tab of the door instance and of the imported server rendered in Chromium)"
