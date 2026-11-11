#!/usr/bin/env bash
# Proof of the SQL Server reads of task 130 (migration 0084_mssql_reads.sql; internal/mssql/properties.go,
# procstats.go, indexlocks.go and the wait descriptions of waits.go; internal/web/q_mssql_properties.go,
# q_mssql_procs.go, q_mssql_indexlocks.go and the SQL Server arm of q_running_fleet.go) against a real SQL Server
# and, for the rules no server can be made to show on demand (a restart, a cut list, a late read), on imported rows.
#
# Needs: go (the proof builds ONE binary into its temp folder and uses it throughout; PGVIGIL_BIN names a built one
# instead), psql, curl, jq, ss, docker where a container or the sandbox is used, and
#   PGVIGIL_ADMIN_DSN        a superuser connection to a PostgreSQL in KEYWORD form, no dbname (host=... user=...).
#                            It rides psql's command line: no password in it (PGPASSWORD or ~/.pgpass carries one).
#   PGVIGIL_MSSQL_CONTAINER  an existing SQL Server sandbox container, with PGVIGIL_MSSQL_ADDR (default
#                            localhost:1433) and its sa password in MSSQL_SA_PASSWORD. NOT set: the proof starts its
#                            own SQL Server container (MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest)
#                            with a throwaway sa password made here, and removes it at the end.
#   PGVIGIL_SKIP_PG13=1      leaves part M out (it starts and removes a postgres:13 container of its own).
#   PGVIGIL_SHOTS            a folder: part S runs (it needs chromium and node) and saves the five pages' screenshots
#                            there in both themes, 1600 wide, taken from the proof's own data. Not set: S is not run.
#                            PGVIGIL_CHROMIUM_FLAGS: more flags for Chromium (--no-sandbox where it runs as root).
#   PGVIGIL_NO_MSSQL=1       the parts that need no SQL Server only (the migration, D on stored rows, G, X, Y): no
#                            container, no login; the last line says so and is NOT the proof's PASS.
# The binary must carry the routes /api/mssql/properties, /waitinfo, /procs and /indexlocks (the lead's wiring in
# web.go): the proof stops at its first API read when it does not. Part S also needs the bundle built from this tree
# ('npm run build' in web/: the binary embeds internal/web/dist).
# The proof makes, and drops on every exit path: its own repository database (pgvigil_p4s2_reads_<n>), on the SQL
# Server one database (two tables, two procedures) and three logins (random suffix and passwords), its own
# containers. On an existing sandbox it changes no server setting; on its own container it sets max server memory
# once, to show a real change in the history.
#
# Expected (written before the first run; revised with the review fold of 2026-11-11, before the first run that
# reached a SQL Server):
#  M. the whole migration chain applies on PostgreSQL 13 (a fresh database of a postgres:13 container): migrate exits
#     0, the newest schema version equals the one of the main repository, and 0084's five functions exist there.
#  A. mssql_properties as the monitoring login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE): 35
#     properties are stored, and each of 33 values equals sa's own read of its source, taken beside the collector's:
#     sys.dm_os_sys_info (logical CPUs, sockets, cores per socket, hyperthread ratio, NUMA nodes, soft NUMA,
#     affinity, max workers, virtual machine, physical MB, memory model), sys.dm_os_schedulers (VISIBLE ONLINE,
#     VISIBLE OFFLINE), SERVERPROPERTY (edition, version, level, collation, clustered, Always On, machine, server
#     name), sys.configurations (MAXDOP, cost threshold, max and min server memory), tempdb.sys.database_files (data
#     files, data MB, one size, log files, log MB), sys.dm_os_host_info (platform, distribution, release); sa's value
#     is never empty (the distribution may be, off Linux). Max server memory as a per cent of the machine is 'no
#     limit' while the setting is at its default, else sa's own arithmetic in decimal (max MB x 100 / physical MB,
#     one decimal, a half away from zero). The power plan on a Linux host is not read and its note says 'SQL Server
#     on Linux'; on Windows the value is printed and NOT compared (no hand read of the registry here).
#     The first read logs no change; a second read of the unchanged server logs none, keeps every 'since' (the three
#     values that are shown and never logged, tempdb's two sizes and the per cent, left aside: tempdb may grow) and
#     moves every value's read time past the first read's.
#     On the proof's own container: after sa sets max server memory to 1536 MB, the next read logs exactly ONE
#     change (max_memory_mb 2147483647 > 1536: the per cent is derived and not logged), shows the per cent sa
#     computes, and moves 'since' on max_memory_mb alone among the logged values. On an existing sandbox this step is
#     NOT RUN (no server setting is changed there).
#     A login without VIEW SERVER STATE: the run is partial naming sys.dm_os_sys_info; edition and the five tempdb
#     rows have their values; cpu_count has none and its note says the right is missing.
#  B. mssql_procstats: a procedure run 3 times before the first read and 7 times between the first and the second:
#     the first read stores no sample and no read row; the second stores one sample for it with executions 7 and CPU,
#     duration and logical reads equal to the rise of sa's own read of sys.dm_exec_procedure_stats over the same
#     span (taken after the first read and before the second), under its database, schema and name. A second
#     procedure created after the second read and run 5 times: the third read stores its WHOLE count (5, with sa's
#     counters) and no row for the first procedure, which did not run. After sp_recompile of the first procedure
#     and 4 runs: the fourth read stores 4 (the new plan's whole count), not 4 minus 10. Three read rows with their
#     seconds; no figure below zero. A login with VIEW SERVER STATE alone: partial, naming the plans without a name.
#  C. mssql_indexlocks on a table of 20,000 rows with a clustered primary key: after the first read, a session
#     updates row 1 in a transaction it holds for 6 s; once its exclusive key lock shows in sys.dm_tran_locks a
#     second session updates the same row and waits: the second read stores, on that table's clustered index under
#     its schema, table, index name and type, the row lock waits and their milliseconds exactly as sa's read of
#     sys.dm_db_index_operational_stats rose (at least 1 wait and 2,000 ms). Then one UPDATE of all 20,000 rows WITH
#     (ROWLOCK): the third read stores the escalation attempts and escalations exactly as sa's read rose (at least 1
#     attempt and 1 escalation) and no new row lock wait. No figure below zero. (Corrected after the first run that
#     reached a server: the table had 6,000 rows, and an UPDATE of 6,000 rows gets three attempts and no escalation
#     on SQL Server 2022, on the proof's container and on the local sandbox alike. Measured on the sandbox: the
#     engine checks as a statement's locks grow and escalated the UPDATE of 20,000 rows, 4 attempts and 1
#     escalation; the 6,000-row statement ends before the check that would escalate it.)
#  D. the fleet Running queries row. Stored rows (4 requests of one snapshot: grants of 1,024 and 4,096 KB, a
#     PAGELATCH_UP wait of 500 ms on 2:1:1, a PAGELATCH_EX wait of 300 ms on 2:1:120, a PAGEIOLATCH_SH wait on 2:1:1,
#     a lock wait): /api/running/fleet gives max grant 4096, sum 5120, tempdb latch waits 2 with 800 ms, allocation
#     waits 1 with 500 ms; a PostgreSQL instance's row has all six empty. On the server: a session sorting a million
#     rows whose client reads slowly holds a memory grant; the snapshot taken then stores, for that session, the
#     figure sa reads in sys.dm_exec_query_memory_grants (the collector reads sys.dm_exec_requests), and the
#     instance's fleet row has max grant = the largest stored grant of the snapshot (at least that figure) and sum =
#     their sum. Where the sort shows no grant within 40 s this step prints NOT PROVEN and the proof goes on (the
#     arithmetic is proven on the stored rows).
#  E. the Waits page's additions: with a first mssql_waits read before C and a second after it, and one mssql_cpu
#     read: /api/mssql/waitinfo's cores equal sa's count of VISIBLE ONLINE schedulers; the largest lock wait of the
#     window (C's, on the proof's own container; on a shared sandbox it may be another session's) is in rates under
#     an LCK_M_ type with at least 2,000 ms, and its ms_per_sec and ms_per_sec_core equal a division done here (wait
#     ms / the read's seconds, and that / the schedulers) within 0.002; types carries THREADPOOL with a text that
#     says 'worker'; families carries LCK_M_, PAGEIOLATCH_ and PAGELATCH_.
#  F. a login with neither right: mssql_procstats and mssql_indexlocks are skipped naming VIEW SERVER STATE.
#  G. the three import functions refuse a PostgreSQL instance.
#  X. without a server, on imported rows:
#     procedures, ten reads five minutes apart, one row per plan: the first sets; grown 10 > 25 gives 15; an idle
#     read stores no sample and a read row with 0 procedures; three plans the complete read before did not hold (a
#     recompile, a new procedure, and one with an old cached time) give their whole counts 4, 6 and 3; after a
#     RESTART (the start time moved) the same plan with LOWER counters gives its whole count 1, never -3, the same
#     plan with HIGHER counters (6 > 8) its whole count 8, not the difference 2, and a new plan 2; grown 1 > 5 gives 4; lower in the same run 5 > 2 gives 2, in a read marked CUT; after that cut read a
#     plan cached before it gives nothing (it may have been past the cut) and one cached after it its whole count
#     7; the plan that gave nothing gives its difference 10 on the next read; the second read arriving again, late,
#     changes nothing: the state keeps the ninth read's clock and the plan's 60, and a tenth read gives 10 more. In
#     all: 100:15:1500,100:4:400,101:6:60,104:3:30,100:1:100,101:8:80,102:2:20,100:4:400,100:2:200,105:7:70,
#     103:10:1000,103:10:1000 (object:executions:CPU us) and read rows with 1,0,3,3,1,1,1,1,1 procedures, 300 s each.
#     indexes, eight reads, one row per rowset: the first sets; grown 2 > 5 waits gives 3 (300 ms) and an index new
#     to the list its whole count with its escalations; after a RESTART lower counters give the whole count 1, never
#     -4, and HIGHER counters (3 > 4 waits) their whole count 4, not the difference 1; a read marked cut gives its
#     difference; an index new AFTER the cut read gives nothing, and its difference 2 on the next read; two
#     partitions of one index, new after a complete read, are summed (3 waits, 11 ms); two rowsets of one partition
#     (a columnstore's) are summed (10 waits), and when one of them is gone the other's difference is 1, not the
#     whole 5 a dropped sum would give; an index of a second database gives 8, then that database is SKIPPED for a
#     read (its call failed) and at the next read the index gives its difference 3, not its whole 11, while an
#     index new there gives its whole 2. In all:
#     200:3:300:0:0,201:3:30:2:1,200:1:10:0:0,201:4:40:3:2,200:1:10:0:0,202:2:20:0:0,203:3:11:0:0,204:10:100:0:0,
#     300:8:80:0:0,204:1:10:0:0,300:3:30:0:0,301:2:20:0:0 (object:row lock waits:ms:escalation attempts:escalations)
#     and read rows with 2,2,1,0,4,1,2 indexes.
#     No row of either store carries a figure below zero.
#     properties, four reads: the first logs nothing; the second logs exactly cpu_count 4 > 8 (tempdb's size moved
#     100 > 200 and is not logged: track false; MAXDOP did not move and keeps its 'since'); a third read without a
#     value for cpu_count keeps 8, takes the note and keeps the time of the read that gave the value, and gives the
#     power plan, stored without a value until then, its first value: set, not logged as a change; the first read
#     arriving again, late, changes nothing; after a fourth read that gave no value at all, the second read
#     arriving again with another value is still late and changes nothing.
#     mssql_tempdb_page_kind: pfs for 2:1:1, 2:3:8088 and 2:1:16176; gam for 2:1:2 and 2:1:511232; sgam for 2:1:3 and
#     2:1:511233; page for 2:1:0, 2:1:120 and 'PAGE: 2:1:120'; NULL for a PAGEIOLATCH wait, a page of database 5, a
#     NULL wait type, a NULL resource and a lock wait.
#     mssql_reads_purge(30): a change 40 days old and the counters of an instance last read 40 days ago go, today's
#     stay; it returns the rows it removed (3).
#  Y. the API on X's imported rows (no server needed, so every statement of the four handlers runs in the short
#     mode too): /api/mssql/procs gives p100 26 executions and 2.6 ms of CPU, p103 20, p101 14, p105 7, p104 3, p102
#     2, the most duration first; p100 at 0.58 executions a minute over the 2,700 s the instance's nine reads cover,
#     3.00 a minute in its busiest read, 0.100 ms of CPU a run, in 5 of the reads; one database (id 5, appdb) with 6
#     procedures and 72 executions; totals of 6 procedures, 72 executions, 4.9 ms of CPU, 9.7 ms of duration and
#     720 logical reads; a series of 9 steps whose executions per second add up to 72 / 300; db=5 keeps the 6 rows,
#     an unknown database id none and a series of 9 zeros; db_id= and object= give p100's reads newest first (2, 4,
#     1, 4, 15); a db that is no number, a db_id that is no number and an unknown part are refused with 400.
#     /api/mssql/indexlocks gives t200.ix1 5 waits and 320 ms, t204.ix1 and t300.ix1 11 and 110 each, t201.ix2 7
#     waits, 70 ms, 5 attempts and 3 escalations (10.0 ms a wait), t202.ix1 and t301.ix1 2 and 20 each, t203.ix1 3
#     and 11, the most lock wait first; two databases (appdb 5 indexes and 531 ms, otherdb 2 and 130); totals of 7
#     indexes, 41 waits, 661 ms, 5 attempts, 3 escalations; 7 reads over 2,100 s; a series of 7 steps adding up to
#     661 ms and 3 escalations; db=6 keeps otherdb's 2 rows. /api/mssql/properties gives the four properties and
#     the one change. /api/mssql/waitinfo for an instance without waits gives no cores, no rates, at least 40
#     described types and 7 families with LCK_M_ first; after a wait sample of 6,000 ms (LCK_M_U) and 300 ms
#     (WRITELOG) over one 60 s read and a schedulers row of 4 are put in by hand: 100 and 25 ms/sec for the first,
#     5 and 1.25 for the second.
#  P. the API on the server's rows: /api/mssql/properties holds the 35 properties and the changes (none on a shared
#     sandbox, where no setting is changed); /api/mssql/procs lists the proof's procedure with executions 11 (7 + 4)
#     and executions per minute = 11 x 60 / the covered seconds; db=<its database's id> keeps only that database's
#     two procedures; db_id= and object= give the procedure's two reads. /api/mssql/indexlocks lists the clustered
#     index with the stored sums; db= keeps that database's rows.
#  S. (only with PGVIGIL_SHOTS) in a headless Chromium at 1600 wide, in the light and the dark theme, each page is
#     found by its grid's column names, never by position: Properties shows 35 rows with the logical CPUs a number
#     and the power plan's cell 'not read' on a Linux host; Procedures shows the proof's procedure with 11
#     executions under dbo, and its name opens it read by read (2 reads); Index locks shows PK_pv_lock on pv_lock
#     with at least 1 row lock wait, 1 escalation attempt and 1 escalation; Waits shows the forced lock wait's type with both
#     rates and a description, the grid has one row per wait type of the window, no row taller than 320 px and a
#     description column at least 300 px wide (corrected after the first look: the column had collapsed to one
#     character and a row was thousands of pixels tall; the first run's checks did not see it); the fleet Running
#     queries row of the stored snapshot reads 4.0 MB, 5.0 MB, 2, 800, 1, 500 and a PostgreSQL row's six cells are
#     empty. Fourteen screenshots are saved (reads-<page>-<theme>.png; the Waits grid and the fleet grid's right end
#     have a picture of their own) for the look against the tools' shots.
#  NOT PROVEN HERE: a real power plan (a Windows SQL Server), a real tempdb page latch wait, SQL Server 2016-2019
#  (the older sys.dm_os_sys_info), Amazon RDS, Azure SQL Managed Instance, a list long enough to be cut on a real
#  server, a database skipped on a real server (a schema change held across the read), a columnstore rowset with
#  lock waits, the pages' accessibility (proof-a11y) and, without PGVIGIL_SHOTS, the pages in a browser.
set -euo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
for t in psql curl jq ss; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
# docker only where a container (the proof's own SQL Server, PostgreSQL 13) or the sandbox container is used
if [ -z "${PGVIGIL_NO_MSSQL:-}" ] || [ "${PGVIGIL_SKIP_PG13:-}" != 1 ]; then
  command -v docker >/dev/null || { echo "FAIL: docker is not on this machine" >&2; exit 1; }
fi
# the pages are asked for (PGVIGIL_SHOTS): their tools are checked now, not after every other part has passed
if [ -n "${PGVIGIL_SHOTS:-}" ] && [ -z "${PGVIGIL_NO_MSSQL:-}" ]; then
  for t in chromium node; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine (PGVIGIL_SHOTS asks for the pages)" >&2; exit 1; }; done
fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUF=$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_p4s2_reads_$SUF
DB=pgvproof_reads_$SUF
L1=pgv_reads_$SUF; L2=pgv_readsbare_$SUF; L3=pgv_readsvss_$SUF
N=proof-reads-$SUF; NB=proof-readsbare-$SUF; NV=proof-readsvss-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw)
fail() { echo "FAIL: $*" >&2; exit 1; }
freeport() { for p in $(seq "$1" "$2"); do ss -ltn | grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_DB=; MADE_L=(); MADE_CT=; MADE_PG13=; SRV_PID=; GRANT_PID=; HOLD_PID=; CHR_PID=; SORTING=
CT=${PGVIGIL_MSSQL_CONTAINER:-}; OWN=; NOMS=${PGVIGIL_NO_MSSQL:-}
PG13=pgv-p4s2-pg13-$SUF
# sq <sql> [database]: as sa, the password through the environment by name
sq() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# sqs: as sa, the batch on stdin (a login's password never rides a command line)
sqs() { docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -i /dev/stdin; }
# mkproc <CREATE PROCEDURE ...>: in the proof's database, as a batch of its own (CREATE PROCEDURE must be the first
# statement of its batch, and sq puts SET NOCOUNT ON in front of everything)
mkproc() { printf 'USE [%s];\nGO\n%s\nGO\n' "$DB" "$1" | sqs >/dev/null; }
# kill_sort: part D's sorting session, found by the host name it logged in with
kill_sort() { sq "DECLARE @k nvarchar(max) = N''; SELECT @k += N'KILL ' + CAST(session_id AS nvarchar(10)) + N';' FROM sys.dm_exec_sessions WHERE host_name = 'pgvgrant$SUF'; EXEC (@k);" >/dev/null 2>&1 || true; }
cleanup() {
  rc=$?
  for p in "$SRV_PID" "$GRANT_PID" "$HOLD_PID" "$CHR_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  [ -n "$CHR_PID" ] && { wait "$CHR_PID" 2>/dev/null || true; }   # Chromium writes its profile folder until it is gone
  if [ -n "$MADE_CT" ]; then
    docker rm -f "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2   # only the container this run made
  else
    # on a sandbox that stays: the sorting session outlives its docker client
    [ -n "$SORTING" ] && kill_sort
    if [ -n "$MADE_DB" ]; then sq "IF DB_ID('$DB') IS NOT NULL BEGIN ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $DB not dropped" >&2; fi
    for l in "${MADE_L[@]:-}"; do
      [ -n "$l" ] || continue
      sq "IF SUSER_ID('$l') IS NOT NULL DROP LOGIN [$l];" >/dev/null 2>&1 || echo "CLEANUP: login $l not dropped" >&2
    done
  fi
  [ -n "$MADE_PG13" ] && { docker rm -f "$PG13" >/dev/null 2>&1 || echo "CLEANUP: container $PG13 not removed" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || echo "CLEANUP: $WORK not removed" >&2
  exit $rc
}
trap cleanup EXIT

echo "--- the binary"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN names no binary"
  BIN=$WORK/pgvigil
  (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || fail "the build"
fi
[ -x "$BIN" ] || fail "no binary at $BIN"

echo "--- the SQL Server"
if [ -n "$NOMS" ]; then
  echo "  NOT USED (PGVIGIL_NO_MSSQL=1): the parts A, B, C, E, F, P, S and D's real grant are not run"
  ADDR=none
elif [ -n "$CT" ]; then
  ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
  : "${MSSQL_SA_PASSWORD:?the sa password of the sandbox PGVIGIL_MSSQL_CONTAINER names}"
  echo "  the existing sandbox $CT ($ADDR)"
else
  CT=pgv-p4s2-mssql-$SUF; OWN=1
  MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
  MPORT=$(freeport 21433 21499) || fail "no free port for the SQL Server container"
  ADDR=127.0.0.1:$MPORT
  MADE_CT=1   # before the run: a container made and then failing (a port taken) is still this run's to remove
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server container"
  echo "  its own container $CT ($ADDR)"
fi
if [ -z "$NOMS" ]; then
  export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
  echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(80))")"
fi

adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# the three logins, the proof database with its tables and its first procedure
mklogin() { printf "CREATE LOGIN [%s] WITH PASSWORD = '%s', CHECK_POLICY = OFF;\n" "$1" "$2" | sqs >/dev/null; MADE_L+=("$1"); }
if [ -z "$NOMS" ]; then
  mklogin "$L1" "$P1"; mklogin "$L2" "$P2"; mklogin "$L3" "$P3"
  sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1]; GRANT VIEW SERVER STATE TO [$L3];" >/dev/null
fi
export MS_MON="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_BARE="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MS_VSS="sqlserver://$L3:$P3@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_MON\n' "$N"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_BARE\n' "$NB"
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_VSS\n' "$NV"
} > "$CFG"
if [ -z "$NOMS" ]; then
sq "CREATE DATABASE [$DB]; ALTER DATABASE [$DB] SET RECOVERY SIMPLE;" >/dev/null; MADE_DB=1
sq "CREATE TABLE dbo.pv_rows (id int IDENTITY PRIMARY KEY, pad char(100) NOT NULL DEFAULT 'x');
    INSERT dbo.pv_rows (pad) SELECT TOP (2000) 'a' FROM sys.all_columns a CROSS JOIN sys.all_columns b;
    CREATE TABLE dbo.pv_lock (id int NOT NULL CONSTRAINT PK_pv_lock PRIMARY KEY CLUSTERED, v int NOT NULL, pad char(200) NOT NULL DEFAULT 'x');
    INSERT dbo.pv_lock (id, v) SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 0 FROM sys.all_columns a CROSS JOIN sys.all_columns b;" "$DB" >/dev/null
mkproc "CREATE PROCEDURE dbo.pv_work @n int AS BEGIN SET NOCOUNT ON; DECLARE @c int; SELECT @c = COUNT(*) FROM dbo.pv_rows WHERE id <= @n; END"
fi
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate on the main repository"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT" >&2; return 1; }; cat "$OUT"; }

if [ "${PGVIGIL_SKIP_PG13:-}" = 1 ]; then
  echo "--- M. PostgreSQL 13: NOT RUN (PGVIGIL_SKIP_PG13=1)"; M_NOTE="M NOT RUN"
else
  echo "--- M. the migration chain on PostgreSQL 13"
  PG13PW=$(pw); export PG13PW
  P13=$(freeport 25432 25499) || fail "M: no free port for the PostgreSQL 13 container"
  # the password reaches docker through the environment, by name
  MADE_PG13=1
  POSTGRES_PASSWORD="$PG13PW" docker run -d --name "$PG13" -e POSTGRES_PASSWORD -p "127.0.0.1:$P13:5432" postgres:13 >/dev/null || fail "M: docker run postgres:13"
  p13() { PGPASSWORD="$PG13PW" psql "host=127.0.0.1 port=$P13 user=postgres dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
  for _ in $(seq 1 60); do p13 "select 1" >/dev/null 2>&1 && break; sleep 1; done
  sleep 2; p13 "select 1" >/dev/null || fail "M: PostgreSQL 13 does not answer"   # the image restarts once after its init
  p13 "create database pgvigil_p4s2_pg13_$SUF" >/dev/null
  export PG13_DSN="host=127.0.0.1 port=$P13 user=postgres password=$PG13PW dbname=pgvigil_p4s2_pg13_$SUF"
  sed 's/env:PGVIGIL_REPO_DSN/env:PG13_DSN/' "$CFG" > "$WORK/pg13.yaml"   # the same file, the other repository
  "$BIN" migrate -config "$WORK/pg13.yaml" > "$WORK/pg13.out" 2>&1 || { tail -20 "$WORK/pg13.out" >&2; fail "M: migrate on PostgreSQL 13"; }
  V13=$(p13 "select current_setting('server_version_num')::int / 10000 || '|' || (select max(version) from pgvigil.schema_version)" "pgvigil_p4s2_pg13_$SUF")
  VMAIN=$(q "select max(version) from pgvigil.schema_version")
  [ "$V13" = "13|$VMAIN" ] || fail "M: PostgreSQL major|schema version $V13, want 13|$VMAIN"
  F13=$(p13 "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname in ('import_mssql_properties', 'import_mssql_procstats', 'import_mssql_indexlocks', 'mssql_tempdb_page_kind', 'mssql_reads_purge')" "pgvigil_p4s2_pg13_$SUF")
  [ "$F13" = 5 ] || fail "M: $F13 of 0084's 5 functions exist on PostgreSQL 13"
  docker rm -f "$PG13" >/dev/null 2>&1 && MADE_PG13=
  echo "M: OK (schema version $VMAIN on PostgreSQL 13)"; M_NOTE="M"
fi

echo "--- the API"
PORT=$(freeport 18290 18330) || fail "no free port for the UI"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRV_PID=$!
U=http://127.0.0.1:$PORT/api
for _ in $(seq 1 40); do curl -fs "$U/health" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "$U/health" >/dev/null || { cat "$WORK/serve.log" >&2; fail "the UI did not serve"; }
for r in properties waitinfo procs indexlocks; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/$r?instance=1")" != 404 ] || fail "the binary has no route /api/mssql/$r (the lead's wiring in web.go)"
done
win() { echo "from=$(date -u -d '-6 hours' +%FT%TZ)&to=$(date -u -d '+1 minute' +%FT%TZ)"; }
# objs <file> <part>: the part's rows as objects
objs() { jq -c --arg p "$2" '.[$p] as $t | [$t.rows[] | [$t.columns, .] | transpose | map({(.[0]): .[1]}) | add]' "$1"; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.002}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; }

if [ -z "$NOMS" ]; then   # A, B and C need the server
echo "--- A. mssql_properties as the monitoring login"
# hand <T-SQL scalar>: sa's own read, NULL as nothing
hand() { sq "SELECT ISNULL(CAST(($1) AS varchar(256)), '')"; }
SI="FROM sys.dm_os_sys_info"; TF="FROM tempdb.sys.database_files"; CF="FROM sys.configurations WHERE name ="
HOSTP=$(hand "SELECT host_platform FROM sys.dm_os_host_info")
collect mssql_properties "$N" >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='$N'")
pv() { q "select coalesce(value, '') from pgvigil.mssql_property where instance_id=$iid and name='$1'"; }
checked=0
while IFS='~' read -r name expr; do
  [ -n "$name" ] || continue
  want=$(hand "$expr"); got=$(pv "$name")
  # sa must have read something, or two empty values would agree (the distribution is empty off Linux)
  [ -n "$want" ] || [ "$name" = host_distribution ] || fail "A: sa read nothing for $name"
  [ "$got" = "$want" ] || fail "A: $name is '$got', sa reads '$want'"
  checked=$((checked + 1))
done <<EOF
cpu_count~SELECT cpu_count $SI
socket_count~SELECT socket_count $SI
cores_per_socket~SELECT cores_per_socket $SI
hyperthread_ratio~SELECT hyperthread_ratio $SI
numa_nodes~SELECT numa_node_count $SI
soft_numa~SELECT softnuma_configuration_desc $SI
affinity~SELECT affinity_type_desc $SI
max_workers~SELECT max_workers_count $SI
virtual_machine~SELECT virtual_machine_type_desc $SI
physical_memory_mb~SELECT physical_memory_kb / 1024 $SI
memory_model~SELECT sql_memory_model_desc $SI
schedulers_online~SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE'
schedulers_offline~SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE OFFLINE'
edition~SELECT SERVERPROPERTY('Edition')
product_version~SELECT SERVERPROPERTY('ProductVersion')
product_level~SELECT LTRIM(RTRIM(ISNULL(CAST(SERVERPROPERTY('ProductLevel') AS varchar(60)), '') + ' ' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(60)), '')))
collation~SELECT SERVERPROPERTY('Collation')
is_clustered~SELECT CASE CAST(SERVERPROPERTY('IsClustered') AS int) WHEN 1 THEN 'yes' ELSE 'no' END
hadr_enabled~SELECT CASE CAST(SERVERPROPERTY('IsHadrEnabled') AS int) WHEN 1 THEN 'yes' ELSE 'no' END
machine_name~SELECT SERVERPROPERTY('MachineName')
server_name~SELECT SERVERPROPERTY('ServerName')
maxdop~SELECT value_in_use $CF 'max degree of parallelism'
cost_threshold~SELECT value_in_use $CF 'cost threshold for parallelism'
max_memory_mb~SELECT value_in_use $CF 'max server memory (MB)'
min_memory_mb~SELECT value_in_use $CF 'min server memory (MB)'
tempdb_data_files~SELECT COUNT(*) $TF WHERE type_desc = 'ROWS'
tempdb_data_mb~SELECT SUM(CAST(size AS bigint)) * 8 / 1024 $TF WHERE type_desc = 'ROWS'
tempdb_even_size~SELECT CASE WHEN MIN(size) = MAX(size) THEN 'yes' ELSE 'no' END $TF WHERE type_desc = 'ROWS'
tempdb_log_files~SELECT COUNT(*) $TF WHERE type_desc = 'LOG'
tempdb_log_mb~SELECT SUM(CAST(size AS bigint)) * 8 / 1024 $TF WHERE type_desc = 'LOG'
host_platform~SELECT host_platform FROM sys.dm_os_host_info
host_distribution~SELECT host_distribution FROM sys.dm_os_host_info
host_release~SELECT host_release FROM sys.dm_os_host_info
EOF
# max server memory as a per cent of the machine, by sa's own arithmetic: decimal, a half away from zero (the
# collector computes it in whole numbers)
PCTSQL="SELECT CASE WHEN CAST(c.value_in_use AS bigint) = 2147483647 THEN 'no limit' ELSE CAST(CAST(ROUND(CAST(c.value_in_use AS decimal(38, 10)) * 100 / (si.physical_memory_kb / 1024), 1) AS decimal(20, 1)) AS varchar(30)) END FROM sys.configurations c CROSS JOIN sys.dm_os_sys_info si WHERE c.name = 'max server memory (MB)'"
MAXMB=$(hand "SELECT value_in_use $CF 'max server memory (MB)'")
WANTPCT=$(hand "$PCTSQL")
[ -n "$WANTPCT" ] && [ "$(pv max_memory_pct)" = "$WANTPCT" ] || fail "A: max_memory_pct is '$(pv max_memory_pct)', sa computes '$WANTPCT' (max server memory $MAXMB MB)"
checked=$((checked + 1))
PLAN=$(q "select coalesce(value, '') || '|' || coalesce(note, '') from pgvigil.mssql_property where instance_id=$iid and name='power_plan'")
if [ "$HOSTP" = Linux ]; then
  case "$PLAN" in "|not read: SQL Server on Linux"*) ;; *) fail "A: the power plan on a Linux host: $PLAN";; esac
  checked=$((checked + 1))
else
  echo "  the power plan on $HOSTP (printed, NOT compared): $PLAN"
fi
NPROP=$(q "select count(*) from pgvigil.mssql_property where instance_id=$iid")
echo "  $checked values checked (33 against sa's reads, the per cent, the power plan); $NPROP properties stored; max server memory, % of the machine: $(pv max_memory_pct)"
[ "$checked" = 35 ] || [ "$HOSTP" != Linux ] || fail "A: $checked values checked, want 35 (33 against sa, the per cent, the power plan's note)"
[ "$NPROP" = 35 ] || fail "A: $NPROP properties stored, want 35"
[ "$(q "select count(*) from pgvigil.mssql_property_change where instance_id=$iid")" = 0 ] || fail "A: the first read logged a change"
# the three values that are shown and never logged move by themselves (tempdb may grow between two reads): their
# 'since' is left out of the comparisons
UNTRACKED="'tempdb_data_mb', 'tempdb_log_mb', 'max_memory_pct'"
since_of() { q "select string_agg(name || '=' || since, ',' order by name) from pgvigil.mssql_property where instance_id=$iid and name not in ($UNTRACKED)"; }
SINCE1=$(since_of)
SNAP1=$(q "select max(snapshot_at) from pgvigil.mssql_property where instance_id=$iid")
sleep 1
collect mssql_properties "$N" >/dev/null
[ "$(q "select count(*) from pgvigil.mssql_property_change where instance_id=$iid")" = 0 ] \
  || fail "A: a second read of the unchanged server logged $(q "select string_agg(name || ':' || coalesce(old_value, '') || '>' || coalesce(new_value, ''), ',') from pgvigil.mssql_property_change where instance_id=$iid")"
[ "$(since_of)" = "$SINCE1" ] || fail "A: a second read moved a 'since'"
# the second read was stored: every value's read time is past the first read's
[ "$(q "select (count(*) filter (where value is not null) > 30) || '|' || count(*) filter (where value is not null and snapshot_at <= '$SNAP1') from pgvigil.mssql_property where instance_id=$iid")" = "true|0" ] \
  || fail "A: the second read was not stored on every value"
if [ -n "$OWN" ] && [ "$MAXMB" = 2147483647 ]; then
  sq "EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sys.sp_configure 'max server memory (MB)', 1536; RECONFIGURE;" >/dev/null
  sleep 1
  collect mssql_properties "$N" >/dev/null
  WANTCH="max_memory_mb:2147483647>1536"
  GOTCH=$(q "select string_agg(name || ':' || old_value || '>' || new_value, ',' order by name) from pgvigil.mssql_property_change where instance_id=$iid")
  [ "$GOTCH" = "$WANTCH" ] || fail "A: the changes after max server memory was set: '$GOTCH', want '$WANTCH'"
  NEWPCT=$(hand "$PCTSQL")
  [ -n "$NEWPCT" ] && [ "$NEWPCT" != "no limit" ] && [ "$(pv max_memory_pct)" = "$NEWPCT" ] || fail "A: the per cent after the change is '$(pv max_memory_pct)', sa computes '$NEWPCT'"
  [ "$(q "select string_agg(name, ',' order by name) from pgvigil.mssql_property p where instance_id=$iid and name not in ($UNTRACKED) and since > (select min(since) from pgvigil.mssql_property where instance_id=$iid)")" = "max_memory_mb" ] \
    || fail "A: 'since' moved on other logged rows than the one that changed"
  echo "  a real change: $GOTCH; the per cent now $NEWPCT"; A_NOTE="A with a real change"
else
  echo "  a real change: NOT RUN (an existing sandbox: no server setting is changed there; the history is proven on imported rows, X)"; A_NOTE="A without a real change"
fi
collect mssql_properties "$NB" > "$WORK/bare.out"
grep -q "partial: sys.dm_os_sys_info" "$WORK/bare.out" || fail "A: the bare login's run: $(cat "$WORK/bare.out")"
ib=$(q "select instance_id from pgvigil.instances where name='$NB'")
BARE=$(q "select string_agg(name || '=' || (value is not null), ';' order by name) from pgvigil.mssql_property where instance_id=$ib and name in ('cpu_count', 'edition', 'tempdb_data_files', 'tempdb_data_mb', 'tempdb_even_size', 'tempdb_log_files', 'tempdb_log_mb')")
[ "$BARE" = "cpu_count=false;edition=true;tempdb_data_files=true;tempdb_data_mb=true;tempdb_even_size=true;tempdb_log_files=true;tempdb_log_mb=true" ] || fail "A: the bare login stored $BARE"
[ "$(q "select note from pgvigil.mssql_property where instance_id=$ib and name='cpu_count'")" = "not read: the login lacks VIEW SERVER STATE" ] || fail "A: the bare login's cpu_count note"
echo "A: OK"

echo "--- E (first half). the waits' first read and the schedulers"
collect mssql_waits "$N" >/dev/null
collect mssql_cpu "$N" >/dev/null

echo "--- B. mssql_procstats"
PS() { sq "SELECT ISNULL(CAST(SUM(execution_count) AS varchar(20)) + '|' + CAST(SUM(total_worker_time) AS varchar(20)) + '|' + CAST(SUM(total_elapsed_time) AS varchar(20)) + '|' + CAST(SUM(total_logical_reads) AS varchar(20)), '0|0|0|0') FROM sys.dm_exec_procedure_stats WHERE database_id = DB_ID('$DB') AND object_id = OBJECT_ID('$DB.dbo.$1')"; }
run_proc() { sq "DECLARE @i int = 0; WHILE @i < $2 BEGIN EXEC dbo.$1 $3; SET @i += 1; END" "$DB" >/dev/null; }
# diff4 <after> <before>: the rise of four '|' separated counters
diff4() { local a b; IFS='|' read -r -a a <<<"$1"; IFS='|' read -r -a b <<<"$2"; echo "$((a[0] - b[0]))|$((a[1] - b[1]))|$((a[2] - b[2]))|$((a[3] - b[3]))"; }
psample() { q "select coalesce((select executions || '|' || cpu_us || '|' || duration_us || '|' || logical_reads from pgvigil.mssql_proc_sample where instance_id=$iid and database_name='$DB' and object_name='$1' and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_proc_state where instance_id=$iid)), 'none')"; }
run_proc pv_work 3 "@n = 500"
collect mssql_procstats "$N" >/dev/null
[ "$(q "select (select count(*) from pgvigil.mssql_proc_sample where instance_id=$iid) || '|' || (select count(*) from pgvigil.mssql_proc_read where instance_id=$iid)")" = "0|0" ] || fail "B: the first read stored a sample or a read row"
S0=$(PS pv_work)
run_proc pv_work 7 "@n = 500"
S1=$(PS pv_work)
sleep 1
collect mssql_procstats "$N"
WANT=$(diff4 "$S1" "$S0"); GOT=$(psample pv_work)
echo "  pv_work between the first and the second read (executions|CPU us|duration us|logical reads): stored $GOT, sa's rise $WANT"
[ "$GOT" = "$WANT" ] && [ "${WANT%%|*}" = 7 ] || fail "B: the second read: stored $GOT, sa's rise $WANT"
[ "$(q "select schema_name || '|' || type_desc from pgvigil.mssql_proc_sample where instance_id=$iid and database_name='$DB' and object_name='pv_work'")" = "dbo|SQL_STORED_PROCEDURE" ] || fail "B: the procedure's schema and type"
mkproc "CREATE PROCEDURE dbo.pv_new AS BEGIN SET NOCOUNT ON; DECLARE @c int; SELECT @c = COUNT(*) FROM dbo.pv_rows; END"
run_proc pv_new 5 ""
SN=$(PS pv_new)
sleep 1
collect mssql_procstats "$N" >/dev/null
GOT=$(psample pv_new)
echo "  pv_new, cached since the read before (whole count): stored $GOT, sa reads $SN"
[ "$GOT" = "$SN" ] && [ "${SN%%|*}" = 5 ] || fail "B: the new procedure: stored $GOT, sa reads $SN"
[ "$(psample pv_work)" = none ] || fail "B: pv_work did not run and has a sample: $(psample pv_work)"
sq "EXEC sp_recompile N'dbo.pv_work';" "$DB" >/dev/null
run_proc pv_work 4 "@n = 500"
SR=$(PS pv_work)
sleep 1
collect mssql_procstats "$N" >/dev/null
GOT=$(psample pv_work)
echo "  pv_work after sp_recompile and 4 runs: stored $GOT, sa reads $SR"
[ "$GOT" = "$SR" ] && [ "${SR%%|*}" = 4 ] || fail "B: after the recompile: stored $GOT, sa reads $SR"
[ "$(q "select count(*) || '|' || count(*) filter (where interval_secs > 0) from pgvigil.mssql_proc_read where instance_id=$iid")" = "3|3" ] || fail "B: the read rows"
[ "$(q "select count(*) from pgvigil.mssql_proc_sample where instance_id=$iid and (executions <= 0 or cpu_us < 0 or duration_us < 0 or logical_reads < 0 or physical_reads < 0 or logical_writes < 0)")" = 0 ] || fail "B: a figure below zero"
collect mssql_procstats "$NV" > "$WORK/vss.out"
grep -q "partial: OBJECT_NAME: .* procedure plans are stored without a name" "$WORK/vss.out" || fail "B: VIEW SERVER STATE alone: $(cat "$WORK/vss.out")"
echo "B: OK"

echo "--- C. mssql_indexlocks"
IX() { sq "SELECT ISNULL(CAST(SUM(row_lock_wait_count) AS varchar(20)) + '|' + CAST(SUM(row_lock_wait_in_ms) AS varchar(20)) + '|' + CAST(SUM(index_lock_promotion_attempt_count) AS varchar(20)) + '|' + CAST(SUM(index_lock_promotion_count) AS varchar(20)), '0|0|0|0') FROM sys.dm_db_index_operational_stats(DB_ID('$DB'), OBJECT_ID('$DB.dbo.pv_lock'), 1, NULL)"; }
isample() { q "select coalesce((select row_lock_waits || '|' || row_lock_wait_ms || '|' || escalation_attempts || '|' || escalations from pgvigil.mssql_indexlock_sample where instance_id=$iid and database_name='$DB' and table_name='pv_lock' and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_indexlock_state where instance_id=$iid)), 'none')"; }
collect mssql_indexlocks "$N" >/dev/null
[ "$(q "select (select count(*) from pgvigil.mssql_indexlock_sample where instance_id=$iid) || '|' || (select count(*) from pgvigil.mssql_indexlock_read where instance_id=$iid)")" = "0|0" ] || fail "C: the first read stored a sample or a read row"
I0=$(IX)
sq "BEGIN TRAN; UPDATE dbo.pv_lock SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:06'; COMMIT;" "$DB" >/dev/null & HOLD_PID=$!
# the waiter starts once the holder HOLDS the row (its exclusive key lock is granted), never on a guessed delay
HELD=0
for _ in $(seq 1 40); do
  HELD=$(sq "SELECT COUNT(*) FROM sys.dm_tran_locks WHERE resource_database_id = DB_ID('$DB') AND resource_type = 'KEY' AND request_mode = 'X' AND request_status = 'GRANT'")
  [ "$HELD" -ge 1 ] && break; sleep 0.2
done
[ "$HELD" -ge 1 ] || fail "C: the holder never took its row lock"
sq "SET LOCK_TIMEOUT 30000; UPDATE dbo.pv_lock SET v = v + 1 WHERE id = 1;" "$DB" >/dev/null
wait "$HOLD_PID"; HOLD_PID=
I1=$(IX)
sleep 1
collect mssql_indexlocks "$N"
WANT=$(diff4 "$I1" "$I0"); GOT=$(isample)
echo "  the forced row lock wait (waits|ms|escalation attempts|escalations): stored $GOT, sa's rise $WANT"
IFS='|' read -r W_N W_MS _ _ <<<"$WANT"
[ "$GOT" = "$WANT" ] && [ "$W_N" -ge 1 ] && [ "$W_MS" -ge 2000 ] || fail "C: the lock wait: stored $GOT, sa's rise $WANT"
[ "$(q "select schema_name || '|' || index_name || '|' || index_type || '|' || index_id from pgvigil.mssql_indexlock_sample where instance_id=$iid and database_name='$DB' and table_name='pv_lock'")" = "dbo|PK_pv_lock|CLUSTERED|1" ] \
  || fail "C: the index's names: $(q "select schema_name, table_name, index_name, index_type, index_id from pgvigil.mssql_indexlock_sample where instance_id=$iid and database_name='$DB'")"
sq "UPDATE dbo.pv_lock WITH (ROWLOCK) SET v = v + 1;" "$DB" >/dev/null
I2=$(IX)
sleep 1
collect mssql_indexlocks "$N" >/dev/null
WANT=$(diff4 "$I2" "$I1"); GOT=$(isample)
echo "  the forced escalation (waits|ms|escalation attempts|escalations): stored $GOT, sa's rise $WANT"
IFS='|' read -r E_W _ E_ATT E_ESC <<<"$WANT"
[ "$GOT" = "$WANT" ] && [ "$E_W" = 0 ] && [ "$E_ATT" -ge 1 ] && [ "$E_ESC" -ge 1 ] || fail "C: the escalation: stored $GOT, sa's rise $WANT (want the same figures, with an attempt and an escalation)"
[ "$(q "select count(*) from pgvigil.mssql_indexlock_sample where instance_id=$iid and least(row_lock_waits, row_lock_wait_ms, page_lock_waits, page_lock_wait_ms, escalation_attempts, escalations) < 0")" = 0 ] || fail "C: a figure below zero"
collect mssql_indexlocks "$NV" > "$WORK/vssix.out"
echo "  VIEW SERVER STATE alone: $(tr '\n' ' ' < "$WORK/vssix.out")"
echo "C: OK"
fi

echo "--- D. the fleet Running queries row"
xf=$(q "select pgvigil.ensure_instance('proof-reads-fleet-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
pgi=$(q "select pgvigil.ensure_instance('proof-reads-pg-$SUF', 'postgres', 'x', 170000, false, '{}', 'postgres')")
q "select pgvigil.mssql_ensure_day_partition('mssql_requests', now())" >/dev/null
q "insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, server_utc, source, sessions, requests) values ($xf, date_trunc('second', now()), now(), 'dmv', 4, 4);
   insert into pgvigil.mssql_requests (instance_id, snapshot_at, session_id, request_id, wait_type, wait_ms, wait_resource, granted_memory_kb)
   select $xf, s.snapshot_at, v.* from pgvigil.mssql_requests_summary s,
     (values (61, 0, 'PAGELATCH_UP', 500::bigint, '2:1:1', 1024::bigint), (62, 0, 'PAGELATCH_EX', 300, '2:1:120', 4096),
             (63, 0, 'PAGEIOLATCH_SH', 9000, '2:1:1', NULL), (64, 0, 'LCK_M_X', 7000, 'KEY: 2:72057594041270272 (8194443284a0)', 0)) v
    where s.instance_id = $xf" >/dev/null
curl -fs "$U/running/fleet" > "$WORK/fleet.json" || fail "D: /api/running/fleet"
frow() { objs "$WORK/fleet.json" rows | jq -r --argjson i "$1" '.[] | select(.instance_id == $i) | [.max_grant_kb, .sum_grant_kb, .tempdb_waits, .tempdb_wait_ms, .tempdb_alloc_waits, .tempdb_alloc_wait_ms] | map(if . == null then "null" else tostring end) | join("|")'; }
[ "$(frow "$xf")" = "4096|5120|2|800|1|500" ] || fail "D: the stored snapshot's row: $(frow "$xf"), want 4096|5120|2|800|1|500"
[ "$(frow "$pgi")" = "null|null|null|null|null|null" ] || fail "D: a PostgreSQL row: $(frow "$pgi")"
D_NOTE="D on stored rows only"
if [ -z "$NOMS" ]; then   # the real grant, E and F need the server
# a sort of exactly a million rows (1,000 x 1,000) whose client reads slowly: it holds its grant while it waits for the client
SORTING=1
docker exec -e SQLCMDPASSWORD "$CT" bash -c "/opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -U sa -H pgvgrant$SUF -h -1 -Q 'SET NOCOUNT ON; SELECT a.object_id, NEWID() AS n FROM (SELECT TOP (1000) object_id FROM sys.all_columns) a CROSS JOIN (SELECT TOP (1000) column_id FROM sys.all_columns) b ORDER BY n' | (sleep 60; cat >/dev/null)" >/dev/null 2>&1 & GRANT_PID=$!
# sa's own figure of the session's grant, from the grants view (the collector reads sys.dm_exec_requests)
grant_now() { sq "SELECT ISNULL(MAX(CAST(g.granted_memory_kb AS bigint)), 0) FROM sys.dm_exec_query_memory_grants g JOIN sys.dm_exec_sessions s ON s.session_id = g.session_id JOIN sys.dm_exec_requests r ON r.session_id = g.session_id WHERE s.host_name = 'pgvgrant$SUF' AND r.wait_type = 'ASYNC_NETWORK_IO'"; }
H=0; for _ in $(seq 1 40); do H=$(grant_now); [ "$H" -gt 0 ] && break; sleep 1; done
if [ "$H" -gt 0 ]; then
  collect mssql_requests "$N" >/dev/null
  H2=$(grant_now)
  STORED=$(q "select coalesce(max(granted_memory_kb), -1) from pgvigil.mssql_requests_v where instance_id=$iid and host_name='pgvgrant$SUF' and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_requests_summary where instance_id=$iid)")
  [ "$STORED" = "$H" ] && [ "$H2" = "$H" ] || fail "D: the sorting session's grant: stored $STORED KB, sa reads $H KB before and $H2 KB after the snapshot"
  curl -fs "$U/running/fleet" > "$WORK/fleet2.json"
  SNAP=$(q "select coalesce(max(granted_memory_kb) filter (where granted_memory_kb > 0), 0) || '|' || coalesce(sum(granted_memory_kb) filter (where granted_memory_kb > 0), 0) from pgvigil.mssql_requests_v where instance_id=$iid and snapshot_at = (select max(snapshot_at) from pgvigil.mssql_requests_summary where instance_id=$iid)")
  API=$(objs "$WORK/fleet2.json" rows | jq -r --argjson i "$iid" '.[] | select(.instance_id == $i) | "\(.max_grant_kb)|\(.sum_grant_kb)"')
  echo "  a real grant: the session holds $H KB (sys.dm_exec_query_memory_grants); the snapshot's largest|summed grant $SNAP; the fleet row $API"
  [ "$API" = "$SNAP" ] && [ "${SNAP%%|*}" -ge "$H" ] || fail "D: the fleet row $API, the snapshot $SNAP, the session $H"
  D_NOTE="D with a real grant"
else
  echo "  a real memory grant: NOT PROVEN (the sort showed no grant within 40 s); the arithmetic is proven on the stored rows"
  D_NOTE="D on stored rows only"
fi
kill "$GRANT_PID" 2>/dev/null || true; GRANT_PID=
kill_sort; SORTING=
echo "D: OK"

echo "--- E. the Waits page's rates and descriptions"
collect mssql_waits "$N" >/dev/null
curl -fs "$U/mssql/waitinfo?instance=$iid&$(win)" > "$WORK/wi.json" || fail "E: /api/mssql/waitinfo"
SCHED=$(hand "SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE'")
[ "$(objs "$WORK/wi.json" cores | jq -r '.[0].schedulers')" = "$SCHED" ] || fail "E: cores $(objs "$WORK/wi.json" cores), sa counts $SCHED schedulers"
LCK=$(q "select wait_type || '|' || wait_ms || '|' || interval_secs from pgvigil.mssql_wait_sample where instance_id=$iid and wait_type like 'LCK\_M\_%' order by wait_ms desc limit 1")
[ -n "$LCK" ] || fail "E: no lock wait in the waits' second read"
IFS='|' read -r LT LMS LSECS <<<"$LCK"
[ "$LMS" -ge 2000 ] || fail "E: the lock wait $LT has $LMS ms, want at least 2000"
RATE=$(objs "$WORK/wi.json" rates | jq -r --arg w "$LT" '.[] | select(.wait_type == $w) | "\(.ms_per_sec)|\(.ms_per_sec_core)|\(.covered_secs)|\(.schedulers)"')
IFS='|' read -r R_S R_C R_COV R_N <<<"$RATE"
HS=$(awk -v m="$LMS" -v s="$LSECS" 'BEGIN { printf "%.4f", m / s }'); HC=$(awk -v m="$LMS" -v s="$LSECS" -v n="$SCHED" 'BEGIN { printf "%.4f", m / s / n }')
echo "  $LT: $LMS ms over $LSECS s on $SCHED schedulers = $HS ms/sec, $HC ms/sec/core by hand; the API $R_S and $R_C"
near "$R_S" "$HS" && near "$R_C" "$HC" && near "$R_COV" "$LSECS" 0.01 && [ "$R_N" = "$SCHED" ] || fail "E: the rates $RATE, by hand $HS and $HC over $LSECS s on $SCHED"
objs "$WORK/wi.json" types | jq -e '.[] | select(.wait_type == "THREADPOOL") | .description | test("worker")' >/dev/null || fail "E: THREADPOOL has no description"
[ "$(objs "$WORK/wi.json" families | jq -r '[.[] | select(.prefix == "LCK_M_" or .prefix == "PAGEIOLATCH_" or .prefix == "PAGELATCH_") | select(.description | length > 40)] | length')" = 3 ] || fail "E: the families: $(objs "$WORK/wi.json" families | jq -c '[.[].prefix]')"
echo "E: OK"

echo "--- F. a login with neither right"
for c in mssql_procstats mssql_indexlocks; do
  collect $c "$NB" | grep -q "skipped: the login lacks VIEW SERVER STATE" || fail "F: $c on the bare login: $(cat "$OUT")"
done
echo "F: OK"
else
  echo "D: OK (stored rows; the real grant NOT RUN)"
fi

echo "--- G. the imports refuse a PostgreSQL instance"
for c in properties procstats indexlocks; do
  if q "select pgvigil.import_mssql_$c($pgi, now(), '[{\"kind\":\"state\",\"server_utc\":\"2026-01-01T00:00:00Z\"}]'::jsonb)" >/dev/null 2>"$OUT"; then
    fail "G: import_mssql_$c took a PostgreSQL instance"
  fi
  grep -q "is not a SQL Server instance" "$OUT" || fail "G: import_mssql_$c: $(cat "$OUT")"
done
echo "G: OK"

echo "--- X. imported rows: restarts, cut lists, a skipped database, late reads"
NOW=$(date -u +%s)
UT() { date -u -d "@$((NOW - $1))" +%FT%TZ; }             # an instant, $1 seconds ago
LT_() { date -u -d "@$((NOW - $1 - 28800))" +%FT%T; }      # the same instant on a server eight hours behind UTC, no zone
ST1=2026-01-01T00:00:00Z; ST2=2026-06-01T00:00:00Z
xp=$(q "select pgvigil.ensure_instance('proof-reads-xp-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
# pimp <seconds ago> <server start> <capped> <rows>
pimp() { q "select pgvigil.import_mssql_procstats($xp, '$(UT "$1")', ('[{\"kind\":\"state\",\"server_utc\":\"$(UT "$1")\",\"server_start\":\"$2\",\"server_local\":\"$(LT_ "$1")\",\"capped\":$3}' || '$4' || ']')::jsonb)" >/dev/null; }
# prow <plan> <object> <cached, seconds ago> <executions> <CPU us>: one cached plan
prow() { echo ",{\"kind\":\"proc\",\"plan_handle\":\"$(printf '0x0500%036X' "$1")\",\"cached_time\":\"$(LT_ "$3")\",\"database_id\":5,\"object_id\":$2,\"database_name\":\"appdb\",\"schema_name\":\"dbo\",\"object_name\":\"p$2\",\"type_desc\":\"SQL_STORED_PROCEDURE\",\"execution_count\":$4,\"worker_us\":$5,\"elapsed_us\":$(($5 * 2)),\"logical_reads\":$(($4 * 10)),\"physical_reads\":0,\"logical_writes\":$4}"; }
pimp 3300 $ST1 false "$(prow 1 100 4000 10 1000)"
pimp 3000 $ST1 false "$(prow 1 100 4000 25 2500)"
pimp 2700 $ST1 false "$(prow 1 100 4000 25 2500)"
pimp 2400 $ST1 false "$(prow 2 100 2500 4 400)$(prow 3 101 2600 6 60)$(prow 4 104 9000 3 30)"
pimp 2100 $ST2 false "$(prow 2 100 2500 1 100)$(prow 3 101 2600 8 80)$(prow 5 102 2200 2 20)"
pimp 1800 $ST2 false "$(prow 2 100 2500 5 500)$(prow 5 102 2200 2 20)"
pimp 1500 $ST2 true "$(prow 2 100 2500 2 200)"
pimp 1200 $ST2 false "$(prow 2 100 2500 2 200)$(prow 6 103 2000 50 5000)$(prow 7 105 1300 7 70)"
pimp 900 $ST2 false "$(prow 2 100 2500 2 200)$(prow 6 103 2000 60 6000)$(prow 7 105 1300 7 70)"
pimp 3000 $ST1 false "$(prow 1 100 4000 999 99999)"   # the second read again, late
# the late read left the state alone: the ninth read's clock, and plan 6 at its 60
[ "$(q "select (s.server_utc = '$(UT 900)') || '|' || (select execution_count from pgvigil.mssql_proc_last l where l.instance_id = $xp and l.object_id = 103) from pgvigil.mssql_proc_state s where s.instance_id = $xp")" = "true|60" ] \
  || fail "X: the late procedure read changed the state: $(q "select s.server_utc, (select string_agg(object_id || ':' || execution_count, ',') from pgvigil.mssql_proc_last l where l.instance_id = $xp) from pgvigil.mssql_proc_state s where s.instance_id = $xp")"
pimp 600 $ST2 false "$(prow 6 103 2000 70 7000)"
GOT=$(q "select string_agg(object_id || ':' || executions || ':' || cpu_us, ',' order by snapshot_at, object_id) from pgvigil.mssql_proc_sample where instance_id=$xp")
WANT="100:15:1500,100:4:400,101:6:60,104:3:30,100:1:100,101:8:80,102:2:20,100:4:400,100:2:200,105:7:70,103:10:1000,103:10:1000"
[ "$GOT" = "$WANT" ] || fail "X: procedures: $GOT, want $WANT"
GOT=$(q "select string_agg(procs || '/' || round(interval_secs), ',' order by snapshot_at) from pgvigil.mssql_proc_read where instance_id=$xp")
[ "$GOT" = "1/300,0/300,3/300,3/300,1/300,1/300,1/300,1/300,1/300" ] || fail "X: the procedures' read rows: $GOT"
xi=$(q "select pgvigil.ensure_instance('proof-reads-xi-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
# iimp <seconds ago> <server start> <capped> <skipped database ids, a JSON array> <rows>
iimp() { q "select pgvigil.import_mssql_indexlocks($xi, '$(UT "$1")', ('[{\"kind\":\"state\",\"server_utc\":\"$(UT "$1")\",\"server_start\":\"$2\",\"capped\":$3,\"skipped\":$4}' || '$5' || ']')::jsonb)" >/dev/null; }
# irow <database> <object> <index> <partition> <rowset> <row lock waits> <ms> <escalation attempts> <escalations>: one rowset
irow() { local dbn=appdb; [ "$1" = 6 ] && dbn=otherdb; echo ",{\"kind\":\"index\",\"database_id\":$1,\"object_id\":$2,\"index_id\":$3,\"partition_number\":$4,\"hobt_id\":$5,\"database_name\":\"$dbn\",\"schema_name\":\"dbo\",\"table_name\":\"t$2\",\"index_name\":\"ix$3\",\"index_type\":\"CLUSTERED\",\"row_lock_waits\":$6,\"row_lock_wait_ms\":$7,\"page_lock_waits\":0,\"page_lock_wait_ms\":0,\"escalation_attempts\":$8,\"escalations\":$9}"; }
iimp 3300 $ST1 false '[]' "$(irow 5 200 1 1 9001 2 100 0 0)"
iimp 3000 $ST1 false '[]' "$(irow 5 200 1 1 9001 5 400 0 0)$(irow 5 201 2 1 9002 3 30 2 1)"
iimp 2700 $ST2 false '[]' "$(irow 5 200 1 1 9001 1 10 0 0)$(irow 5 201 2 1 9002 4 40 3 2)"
iimp 2400 $ST2 true '[]' "$(irow 5 200 1 1 9001 2 20 0 0)"
iimp 2100 $ST2 false '[]' "$(irow 5 200 1 1 9001 2 20 0 0)$(irow 5 202 1 1 9003 7 70 0 0)"
iimp 1800 $ST2 false '[]' "$(irow 5 200 1 1 9001 2 20 0 0)$(irow 5 202 1 1 9003 9 90 0 0)$(irow 5 203 1 1 9004 1 5 0 0)$(irow 5 203 1 2 9005 2 6 0 0)$(irow 5 204 1 1 9006 4 40 0 0)$(irow 5 204 1 1 9007 6 60 0 0)$(irow 6 300 1 1 9100 8 80 0 0)"
iimp 1500 $ST2 false '[6]' "$(irow 5 204 1 1 9006 5 50 0 0)"   # one rowset of 204 is gone; database 6 was not reached
[ "$(q "select count(*) from pgvigil.mssql_indexlock_last where instance_id=$xi and database_id=6")" = 1 ] || fail "X: the skipped database's counters were not kept"
iimp 1200 $ST2 false '[]' "$(irow 6 300 1 1 9100 11 110 0 0)$(irow 6 301 1 1 9101 2 20 0 0)"
GOT=$(q "select string_agg(object_id || ':' || row_lock_waits || ':' || row_lock_wait_ms || ':' || escalation_attempts || ':' || escalations, ',' order by snapshot_at, object_id) from pgvigil.mssql_indexlock_sample where instance_id=$xi")
WANT="200:3:300:0:0,201:3:30:2:1,200:1:10:0:0,201:4:40:3:2,200:1:10:0:0,202:2:20:0:0,203:3:11:0:0,204:10:100:0:0,300:8:80:0:0,204:1:10:0:0,300:3:30:0:0,301:2:20:0:0"
[ "$GOT" = "$WANT" ] || fail "X: indexes: $GOT, want $WANT"
GOT=$(q "select string_agg(indexes::text, ',' order by snapshot_at) from pgvigil.mssql_indexlock_read where instance_id=$xi")
[ "$GOT" = "2,2,1,0,4,1,2" ] || fail "X: the indexes' read rows: $GOT"
NEG=$(q "select (select count(*) from pgvigil.mssql_proc_sample where least(executions, cpu_us, duration_us, logical_reads, physical_reads, logical_writes) < 0)
              + (select count(*) from pgvigil.mssql_indexlock_sample where least(row_lock_waits, row_lock_wait_ms, page_lock_waits, page_lock_wait_ms, escalation_attempts, escalations) < 0)")
[ "$NEG" = 0 ] || fail "X: $NEG rows carry a figure below zero"
xr=$(q "select pgvigil.ensure_instance('proof-reads-xr-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
# prop <name> <value json> <note json> [track]
prop() { echo "{\"kind\":\"property\",\"name\":\"$1\",\"grp\":\"G\",\"label\":\"$1\",\"ord\":1,\"value\":$2,\"note\":$3,\"track\":${4:-true}}"; }
rimp() { q "select pgvigil.import_mssql_properties($xr, '$(UT "$1")', '[$2]'::jsonb)" >/dev/null; }
rimp 7200 "$(prop cpu_count '"4"' null),$(prop maxdop '"0"' null),$(prop tempdb_data_mb '"100"' null false),$(prop power_plan null '"not read: a"')"
rimp 3600 "$(prop cpu_count '"8"' null),$(prop maxdop '"0"' null),$(prop tempdb_data_mb '"200"' null false),$(prop power_plan null '"not read: b"')"
T3=$(q "select '$(UT 1800)'::timestamptz"); T2=$(q "select '$(UT 3600)'::timestamptz"); T1=$(q "select '$(UT 7200)'::timestamptz")
[ "$(q "select string_agg(name || ':' || old_value || '>' || new_value || '@' || changed_at, ',') from pgvigil.mssql_property_change where instance_id=$xr")" = "cpu_count:4>8@$T2" ] \
  || fail "X: the property changes: $(q "select string_agg(name || ':' || old_value || '>' || new_value, ',') from pgvigil.mssql_property_change where instance_id=$xr")"
GOT=$(q "select string_agg(name || '=' || coalesce(value, 'null') || '/' || coalesce(note, '') || '/' || since, ';' order by name) from pgvigil.mssql_property where instance_id=$xr")
WANT="cpu_count=8//$T2;maxdop=0//$T1;power_plan=null/not read: b/$T1;tempdb_data_mb=200//$T2"
[ "$GOT" = "$WANT" ] || fail "X: the properties after the second read: $GOT, want $WANT"
rimp 1800 "$(prop cpu_count null '"not read: c"'),$(prop power_plan '"Balanced"' null)"
[ "$(q "select value || '/' || note || '/' || snapshot_at || '/' || since from pgvigil.mssql_property where instance_id=$xr and name='cpu_count'")" = "8/not read: c/$T2/$T2" ] \
  || fail "X: a read without a value: $(q "select value, note, snapshot_at, since from pgvigil.mssql_property where instance_id=$xr and name='cpu_count'")"
# a first value after 'not read' is set, not a change
[ "$(q "select value || '/' || coalesce(note, '') || '/' || since from pgvigil.mssql_property where instance_id=$xr and name='power_plan'")|$(q "select count(*) from pgvigil.mssql_property_change where instance_id=$xr")" = "Balanced//$T3|1" ] \
  || fail "X: a first value after 'not read': $(q "select value, note, since from pgvigil.mssql_property where instance_id=$xr and name='power_plan'"), $(q "select count(*) from pgvigil.mssql_property_change where instance_id=$xr") change(s)"
rimp 7200 "$(prop cpu_count '"2"' null)"   # the first read again, late
[ "$(q "select (select value from pgvigil.mssql_property where instance_id=$xr and name='cpu_count') || '|' || (select count(*) from pgvigil.mssql_property_change where instance_id=$xr)")" = "8|1" ] || fail "X: a late property read changed something"
rimp 900 "$(prop cpu_count null '"not read: d"')"         # a read that gave no value at all
rimp 3600 "$(prop cpu_count '"16"' null)"                  # the second read again, with another value: still late
[ "$(q "select (select value || '/' || note from pgvigil.mssql_property where instance_id=$xr and name='cpu_count') || '|' || (select count(*) from pgvigil.mssql_property_change where instance_id=$xr)")" = "8/not read: d|1" ] \
  || fail "X: a late read after a read without values got in: $(q "select value, note from pgvigil.mssql_property where instance_id=$xr and name='cpu_count'")"
GOT=$(q "select string_agg(coalesce(pgvigil.mssql_tempdb_page_kind(w, r), 'null'), ',' order by n) from (values
  (1, 'PAGELATCH_UP', '2:1:1'), (2, 'PAGELATCH_EX', '2:3:8088'), (3, 'PAGELATCH_SH', '2:1:16176'), (4, 'PAGELATCH_UP', '2:1:2'), (5, 'PAGELATCH_UP', '2:1:511232'),
  (6, 'PAGELATCH_UP', '2:1:3'), (7, 'PAGELATCH_UP', '2:1:511233'), (8, 'PAGELATCH_EX', '2:1:0'), (9, 'PAGELATCH_EX', '2:1:120'), (10, 'PAGEIOLATCH_SH', '2:1:1'),
  (11, 'PAGELATCH_EX', '5:1:1'), (12, NULL, '2:1:1'), (13, 'PAGELATCH_SH', NULL), (14, 'LCK_M_X', 'KEY: 2:72057594041270272 (8194443284a0)'),
  (15, 'PAGELATCH_EX', 'PAGE: 2:1:120')) v(n, w, r)")
[ "$GOT" = "pfs,pfs,pfs,gam,gam,sgam,sgam,page,page,null,null,null,null,null,page" ] || fail "X: the tempdb page kinds: $GOT"
xo=$(q "select pgvigil.ensure_instance('proof-reads-xo-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
OLD=$((40 * 86400))
q "select pgvigil.import_mssql_procstats($xo, '$(UT $OLD)', ('[{\"kind\":\"state\",\"server_utc\":\"$(UT $OLD)\",\"server_start\":\"$ST1\",\"server_local\":\"$(LT_ $OLD)\",\"capped\":false}' || '$(prow 1 100 $((OLD + 100)) 10 1000)' || ']')::jsonb)" >/dev/null
q "insert into pgvigil.mssql_property_change (instance_id, name, label, old_value, new_value, changed_at) values ($xr, 'maxdop', 'maxdop', '8', '0', now() - interval '40 days')" >/dev/null
PURGED=$(q "select pgvigil.mssql_reads_purge(30)")
KEPT=$([ -n "$NOMS" ] && echo 1 || echo 2)   # the states read today: X's own, and the server's from B
AFTER=$(q "select (select count(*) from pgvigil.mssql_property_change where instance_id=$xr) || '|' || (select count(*) from pgvigil.mssql_proc_state where instance_id=$xo) || '|' || (select count(*) from pgvigil.mssql_proc_last where instance_id=$xo) || '|' || (select count(*) from pgvigil.mssql_proc_state where instance_id in ($xp, ${iid:-0})) || '|' || (select count(*) > 0 from pgvigil.mssql_proc_last where instance_id=$xp)")
[ "$PURGED|$AFTER" = "3|1|0|0|$KEPT|true" ] || fail "X: the purge removed $PURGED rows and left $AFTER (want 3 and 1|0|0|$KEPT|true)"
echo "X: OK"

echo "--- Y. the API on the imported rows"
W=$(win)
curl -fs "$U/mssql/procs?instance=$xp&$W" > "$WORK/yprocs.json" || fail "Y: /api/mssql/procs"
# a figure with decimals is compared as a whole number of its last digit (jq versions print 1.0 as 1.0 or as 1)
GOT=$(objs "$WORK/yprocs.json" procs | jq -r '[.[] | "\(.object_name):\(.executions):\(.cpu_ms * 10 | round)"] | join(",")')
[ "$GOT" = "p100:26:26,p103:20:20,p101:14:1,p105:7:1,p104:3:0,p102:2:0" ] || fail "Y: the procedures (name:executions:CPU in tenths of a ms): $GOT"
YP=$(objs "$WORK/yprocs.json" procs | jq -r '.[] | select(.object_name == "p100") | "\(.executions_min * 100 | round)|\(.max_executions_min * 100 | round)|\(.avg_cpu_ms * 1000 | round)|\(.intervals)|\(.database)|\(.schema_name)"')
[ "$YP" = "58|300|100|5|appdb|dbo" ] || fail "Y: p100's rates: $YP (want 0.58 a minute over 2,700 s, 3.00 in its busiest read, 0.100 ms a run, 5 reads)"
[ "$(objs "$WORK/yprocs.json" reads | jq -r '.[0] | "\(.reads)|\(.covered_secs | round)"')" = "9|2700" ] || fail "Y: the procedures' reads: $(objs "$WORK/yprocs.json" reads)"
[ "$(objs "$WORK/yprocs.json" databases | jq -r '[.[] | "\(.database_id):\(.database):\(.procs):\(.executions)"] | join(",")')" = "5:appdb:6:72" ] || fail "Y: the procedures' databases: $(objs "$WORK/yprocs.json" databases)"
[ "$(objs "$WORK/yprocs.json" totals | jq -r '.[0] | "\(.procs)|\(.executions)|\(.cpu_ms * 10 | round)|\(.duration_ms * 10 | round)|\(.logical_reads)"')" = "6|72|49|97|720" ] || fail "Y: the procedures' totals: $(objs "$WORK/yprocs.json" totals)"
YS=$(objs "$WORK/yprocs.json" series | jq -r '(length | tostring) + "|" + ([.[] | .executions_s] | add | tostring)')
[ "${YS%%|*}" = 9 ] && near "${YS#*|}" "$(awk 'BEGIN { printf "%.5f", 72 / 300 }')" 0.005 || fail "Y: the procedures' series: $YS (want 9 steps whose executions per second add up to 72 / 300)"
[ "$(curl -fs "$U/mssql/procs?instance=$xp&$W&db=5" | jq '.procs.rows | length')" = 6 ] || fail "Y: db=5"
[ "$(curl -fs "$U/mssql/procs?instance=$xp&$W&db=999999" | jq -r '"\(.procs.rows | length)|\(.series.rows | length)|\([.series.rows[] | .[1]] | add // 0 | . * 1000 | round)|\(.totals.rows[0][1])"')" = "0|9|0|0" ] || fail "Y: an unknown database: rows|steps|the series' sum|the totals' executions is not 0|9|0|0"
[ "$(curl -fs "$U/mssql/procs?instance=$xp&$W&db_id=5&object=100&part=intervals" | jq -r '.intervals as $t | ($t.columns | index("executions")) as $i | [$t.rows[] | .[$i]] | map(tostring) | join(",")')" = "2,4,1,4,15" ] || fail "Y: p100 read by read (newest first)"
for bad in "db=x" "db_id=x&object=1" "part=nope"; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/mssql/procs?instance=$xp&$W&$bad")" = 400 ] || fail "Y: /api/mssql/procs?$bad was not refused"
done
curl -fs "$U/mssql/indexlocks?instance=$xi&$W" > "$WORK/yixl.json" || fail "Y: /api/mssql/indexlocks"
GOT=$(objs "$WORK/yixl.json" indexes | jq -r '[.[] | "\(.table_name).\(.index_name):\(.row_lock_waits):\(.row_lock_wait_ms):\(.escalation_attempts):\(.escalations)"] | join(",")')
[ "$GOT" = "t200.ix1:5:320:0:0,t204.ix1:11:110:0:0,t300.ix1:11:110:0:0,t201.ix2:7:70:5:3,t202.ix1:2:20:0:0,t301.ix1:2:20:0:0,t203.ix1:3:11:0:0" ] || fail "Y: the indexes: $GOT"
[ "$(objs "$WORK/yixl.json" reads | jq -r '.[0] | "\(.reads)|\(.covered_secs | round)"')" = "7|2100" ] || fail "Y: the indexes' reads: $(objs "$WORK/yixl.json" reads)"
[ "$(objs "$WORK/yixl.json" databases | jq -r '[.[] | "\(.database_id):\(.database):\(.indexes):\(.lock_wait_ms)"] | join(",")')" = "5:appdb:5:531,6:otherdb:2:130" ] || fail "Y: the indexes' databases: $(objs "$WORK/yixl.json" databases)"
[ "$(objs "$WORK/yixl.json" totals | jq -r '.[0] | "\(.indexes)|\(.row_lock_waits)|\(.row_lock_wait_ms)|\(.escalation_attempts)|\(.escalations)"')" = "7|41|661|5|3" ] || fail "Y: the indexes' totals: $(objs "$WORK/yixl.json" totals)"
YT=$(objs "$WORK/yixl.json" indexes | jq -r '.[] | select(.table_name == "t201") | "\(.avg_row_lock_wait_ms * 10 | round)|\(.lock_wait_ms)|\(.named)|\(.index_type)"')
[ "$YT" = "100|70|true|CLUSTERED" ] || fail "Y: t201's row: $YT (want 10.0 ms a wait, 70 ms, named, CLUSTERED)"
YI=$(objs "$WORK/yixl.json" series | jq -r '(length | tostring) + "|" + ([.[] | .row_lock_ms_s] | add | tostring) + "|" + ([.[] | .escalations] | add | tostring)')
IFS='|' read -r YI_N YI_MS YI_ESC <<<"$YI"
[ "$YI_N" = 7 ] && near "$YI_MS" "$(awk 'BEGIN { printf "%.5f", 661 / 300 }')" 0.005 && [ "$YI_ESC" = 3 ] || fail "Y: the indexes' series: $YI (want 7 steps, 661 ms over steps of 300 s, 3 escalations)"
[ "$(curl -fs "$U/mssql/indexlocks?instance=$xi&$W&db=6" | jq -r '.indexes as $t | ($t.columns | index("database")) as $i | [$t.rows[] | .[$i]] | join(",")')" = "otherdb,otherdb" ] || fail "Y: db=6 on the index locks"
[ "$(curl -fs "$U/mssql/indexlocks?instance=$xi&$W&db=999999" | jq '.indexes.rows | length')" = 0 ] || fail "Y: an unknown database keeps index rows"
curl -fs "$U/mssql/properties?instance=$xr" > "$WORK/yprops.json" || fail "Y: /api/mssql/properties"
[ "$(objs "$WORK/yprops.json" properties | jq -r '[.[] | "\(.name)=\(.value)"] | sort | join(",")')" = "cpu_count=8,maxdop=0,power_plan=Balanced,tempdb_data_mb=200" ] || fail "Y: the properties: $(objs "$WORK/yprops.json" properties | jq -c '[.[] | [.name, .value]]')"
[ "$(objs "$WORK/yprops.json" changes | jq -r '[.[] | "\(.name):\(.old_value)>\(.new_value)"] | join(",")')" = "cpu_count:4>8" ] || fail "Y: the changes: $(objs "$WORK/yprops.json" changes)"
curl -fs "$U/mssql/waitinfo?instance=$xp&$W" > "$WORK/ywi.json" || fail "Y: /api/mssql/waitinfo"
YW=$(jq -r '"\(.cores.rows | length)|\(.rates.rows | length)|\(.types.rows | length >= 40)|\(.families.rows | length)"' "$WORK/ywi.json")
[ "$YW" = "0|0|true|7" ] || fail "Y: waitinfo for an instance without waits or schedulers: $YW (want 0|0|true|7)"
[ "$(objs "$WORK/ywi.json" families | jq -r '.[0].prefix')" = LCK_M_ ] || fail "Y: the families' order"
# a wait sample and a schedulers row by hand: 6,000 ms over a 60 s read on 4 schedulers = 100 ms/sec, 25 per core
q "select pgvigil.ensure_month_partition('mssql_wait_sample', now() - interval '5 minutes'), pgvigil.ensure_month_partition('mssql_sched_sample', now() - interval '6 minutes')" >/dev/null
q "insert into pgvigil.mssql_wait_sample (instance_id, snapshot_at, wait_type, is_benign, waiting_tasks, wait_ms, signal_ms, interval_secs) values
     ($xp, now() - interval '5 minutes', 'LCK_M_U', false, 2, 6000, 10, 60), ($xp, now() - interval '5 minutes', 'WRITELOG', false, 9, 300, 3, 60);
   insert into pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, cpu_count) values ($xp, now() - interval '6 minutes', 4, 4)" >/dev/null
curl -fs "$U/mssql/waitinfo?instance=$xp&$(win)" > "$WORK/ywi2.json" || fail "Y: /api/mssql/waitinfo with a wait sample"
YR=$(objs "$WORK/ywi2.json" rates | jq -r '[.[] | "\(.wait_type):\(.ms_per_sec * 1000 | round):\(.ms_per_sec_core * 1000 | round):\(.covered_secs | round):\(.schedulers)"] | join(",")')
[ "$YR" = "LCK_M_U:100000:25000:60:4,WRITELOG:5000:1250:60:4" ] || fail "Y: the rates in thousandths: $YR (want LCK_M_U 100 and 25 ms/sec, WRITELOG 5 and 1.25, over 60 s on 4 schedulers)"
[ "$(objs "$WORK/ywi2.json" cores | jq -r '.[0].schedulers')" = 4 ] || fail "Y: the cores"
echo "Y: OK"

if [ -n "$NOMS" ]; then
  echo "NOT RUN (PGVIGIL_NO_MSSQL=1): A, B, C, E, F, P, S and D's real grant, every one of which needs a SQL Server"
  echo "proof-mssql-reads: the parts without a SQL Server passed ($M_NOTE, D on stored rows, G, X, Y); this is NOT the proof's PASS"
  exit 0
fi
echo "--- P. the API"
W=$(win)
curl -fs "$U/mssql/properties?instance=$iid" > "$WORK/props.json" || fail "P: /api/mssql/properties"
[ "$(objs "$WORK/props.json" properties | jq 'length')" = 35 ] || fail "P: the properties part has $(objs "$WORK/props.json" properties | jq 'length') rows"
[ "$(objs "$WORK/props.json" changes | jq 'length')" = "$(q "select count(*) from pgvigil.mssql_property_change where instance_id=$iid")" ] || fail "P: the changes part"
[ "$(objs "$WORK/props.json" state | jq -r '.[0].collection')" = mssql_properties ] || fail "P: the state part"
curl -fs "$U/mssql/procs?instance=$iid&$W" > "$WORK/procs.json" || fail "P: /api/mssql/procs"
PROW=$(objs "$WORK/procs.json" procs | jq -c --arg d "$DB" '.[] | select(.database == $d and .object_name == "pv_work")')
COV=$(objs "$WORK/procs.json" reads | jq -r '.[0].covered_secs')
[ "$(jq -r '.executions' <<<"$PROW")" = 11 ] || fail "P: pv_work's row: $PROW"
near "$(jq -r '.executions_min' <<<"$PROW")" "$(awk -v s="$COV" 'BEGIN { printf "%.4f", 11 * 60 / s }')" 0.01 || fail "P: executions per minute $(jq -r '.executions_min' <<<"$PROW") over $COV s"
DBID=$(jq -r '.database_id' <<<"$PROW"); OBJ=$(jq -r '.object_id' <<<"$PROW")
curl -fs "$U/mssql/procs?instance=$iid&$W&db=$DBID" > "$WORK/procs_db.json"
[ "$(objs "$WORK/procs_db.json" procs | jq -r --arg d "$DB" '[.[] | .database == $d] | (length | tostring) + ":" + (all | tostring)')" = "2:true" ] || fail "P: db=$DBID keeps $(objs "$WORK/procs_db.json" procs | jq -c '[.[] | .database + "." + .object_name]')"
[ "$(curl -fs "$U/mssql/procs?instance=$iid&$W&db_id=$DBID&object=$OBJ&part=intervals" | jq -r '[.intervals.rows[]] | length')" = 2 ] || fail "P: pv_work's reads"
curl -fs "$U/mssql/indexlocks?instance=$iid&$W" > "$WORK/ixl.json" || fail "P: /api/mssql/indexlocks"
IROW=$(objs "$WORK/ixl.json" indexes | jq -r --arg d "$DB" '.[] | select(.database == $d and .index_name == "PK_pv_lock") | "\(.table_name)|\(.row_lock_waits)|\(.row_lock_wait_ms)|\(.escalation_attempts)|\(.escalations)"')
SUMS=$(q "select 'pv_lock|' || sum(row_lock_waits) || '|' || sum(row_lock_wait_ms) || '|' || sum(escalation_attempts) || '|' || sum(escalations) from pgvigil.mssql_indexlock_sample where instance_id=$iid and database_name='$DB' and table_name='pv_lock'")
[ -n "$IROW" ] && [ "$IROW" = "$SUMS" ] || fail "P: the index's row '$IROW', the stored sums '$SUMS'"
[ "$(curl -fs "$U/mssql/indexlocks?instance=$iid&$W&db=$DBID" | jq -r --arg d "$DB" '.indexes as $t | ($t.columns | index("database")) as $i | [$t.rows[] | .[$i] == $d] | (length > 0) and all')" = true ] || fail "P: db=$DBID on the index locks"
echo "P: OK"

if [ -n "${PGVIGIL_SHOTS:-}" ]; then
  echo "--- S. the pages in a headless Chromium, both themes, 1600 wide"
  # the binary embeds internal/web/dist: a bundle built before the pages existed serves none of them
  curl -fs "http://127.0.0.1:$PORT/app.js" | grep -q 'max executions /min' || fail "S: the served bundle has no Procedures page: run 'npm run build' in web/ before the proof (the binary embeds internal/web/dist)"
  mkdir -p "$PGVIGIL_SHOTS"
  CDP=$(freeport 19222 19260) || fail "S: no free port for Chromium"
  # shellcheck disable=SC2086  # PGVIGIL_CHROMIUM_FLAGS is a list of flags (--no-sandbox where Chromium runs as root)
  chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu ${PGVIGIL_CHROMIUM_FLAGS:-} about:blank > "$WORK/chrome.log" 2>&1 & CHR_PID=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || { tail -5 "$WORK/chrome.log" >&2; fail "S: Chromium's CDP port never answered"; }
  cat > "$WORK/ui.mjs" <<'JS'
const a = JSON.parse(process.argv[2]);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${a.cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 15000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(expr)) return true; await sleep(150); } return false; };
let fails = 0;
const check = (cond, what) => { console.log((cond ? '  ok   ' : '  FAIL ') + what); if (!cond) fails++; };
// a grid is found by the name of one of its columns and a cell by its column's name and its row's key: never by position
const fns = `
  const gridOf = name => [...document.querySelectorAll('main table')].find(t => [...t.querySelectorAll('thead th')].some(h => h.textContent.trim() === name));
  const heads = t => [...t.querySelectorAll('thead th')].map(h => h.textContent.trim());
  const rowsOf = t => t ? [...t.querySelectorAll('tbody tr')] : [];
  const cell = (t, tr, col) => tr ? tr.cells[heads(t).indexOf(col)] : undefined;
  const rowWith = (t, col, text) => rowsOf(t).find(tr => cell(t, tr, col)?.textContent.trim() === text);
  const text = (t, tr, col) => cell(t, tr, col)?.textContent.trim() ?? null;
`;
const pv = body => ev(`(() => { ${fns} ${body} })()`);
const go = async (hash, col) => {
  await ev(`document.querySelector('main')?.replaceChildren(); 'ok'`);
  await cmd('Page.navigate', { url: a.u + '/' + hash }); await sleep(400);
  return until(`(() => { ${fns} return !!gridOf(${JSON.stringify(col)}); })()`);
};
const shot = async (name, theme) => {
  const d = await cmd('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${a.shots}/reads-${name}-${theme}.png`, Buffer.from(d.result.data, 'base64'));
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1200, deviceScaleFactor: 1, mobile: false });
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: a.u + '/#/summary' }); await until(`!!document.querySelector('main table')`);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); sessionStorage.clear(); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  const T = `[${theme}] `;

  check(await go(`#/mssqlproperties?i=${a.iid}&w=6h`, 'property'), T + 'Properties rendered');
  const p = await pv(`const t = gridOf('property'); return { n: rowsOf(t).length, cpu: text(t, rowWith(t, 'property', 'Logical CPUs'), 'value'), plan: text(t, rowWith(t, 'property', 'Power plan'), 'value') };`);
  // on a Linux host the power plan is not read and the cell says so; elsewhere it names a plan
  check(p.n === 35 && /^[\d,.\s]+$/.test(p.cpu ?? '') && (a.linux ? p.plan === 'not read' : !!p.plan && p.plan !== 'not read'), T + `Properties: ${p.n} rows, logical CPUs '${p.cpu}', power plan '${p.plan}'`);
  await shot('properties', theme);

  check(await go(`#/mssqlprocs?i=${a.iid}&w=6h`, 'total duration (sec)'), T + 'Procedures rendered');
  const pr = await pv(`const t = gridOf('total duration (sec)'); const tr = rowsOf(t).find(r => text(t, r, 'name') === 'pv_work' && text(t, r, 'database') === ${JSON.stringify(a.db)}); return tr ? { ex: text(t, tr, 'executions'), sch: text(t, tr, 'schema') } : null;`);
  check(pr && pr.ex === '11' && pr.sch === 'dbo', T + `Procedures: pv_work's row ${JSON.stringify(pr)} (want 11 executions under dbo)`);
  await pv(`const t = gridOf('total duration (sec)'); const tr = rowsOf(t).find(r => text(t, r, 'name') === 'pv_work' && text(t, r, 'database') === ${JSON.stringify(a.db)}); cell(t, tr, 'name')?.querySelector('button')?.click(); return 'ok';`);
  const drilled = await until(`(() => { ${fns} return rowsOf(gridOf('interval')).length === 2 && [...document.querySelectorAll('main h3')].some(h => h.textContent.includes('pv_work, read by read')); })()`);
  check(drilled, T + 'Procedures: the name opens the procedure read by read (2 reads)');
  await shot('procedures', theme);

  check(await go(`#/mssqlindexlocks?i=${a.iid}&w=6h`, 'row lock waits'), T + 'Index locks rendered');
  const ix = await pv(`const t = gridOf('row lock waits'); const tr = rowsOf(t).find(r => text(t, r, 'index') === 'PK_pv_lock' && text(t, r, 'database') === ${JSON.stringify(a.db)}); return tr ? { table: text(t, tr, 'table'), waits: text(t, tr, 'row lock waits'), att: text(t, tr, 'escalation attempts'), esc: text(t, tr, 'escalations') } : null;`);
  const num = v => Number(String(v ?? '').replace(/[^0-9]/g, '') || NaN);   // a count as the page groups it (1,000)
  check(ix && ix.table === 'pv_lock' && num(ix.waits) >= 1 && num(ix.att) >= 1 && num(ix.esc) >= 1, T + `Index locks: PK_pv_lock's row ${JSON.stringify(ix)}`);
  await shot('indexlocks', theme);

  check(await go(`#/mssql_waits?i=${a.iid}&w=6h`, 'wait time (ms/sec/core)'), T + 'Waits rendered with the rate columns');
  const w = await pv(`const t = gridOf('wait time (ms/sec/core)'); const tr = rowWith(t, 'wait type', ${JSON.stringify(a.lck)}); return tr ? { rate: text(t, tr, 'wait time (ms/sec)'), core: text(t, tr, 'wait time (ms/sec/core)'), desc: text(t, tr, 'description') } : null;`);
  check(w && w.rate !== '' && w.core !== '' && (w.desc ?? '').length > 40, T + `Waits: ${a.lck} ${JSON.stringify(w)?.slice(0, 160)}`);
  await shot('waits', theme);
  // the grid's layout: every wait type of the window is a row, and no row is taller than a wrapped description needs
  // (a description column squeezed to one character made a row thousands of pixels tall: the first look found it)
  const lay = await pv(`const t = gridOf('wait time (ms/sec/core)'); const rs = rowsOf(t); const d = cell(t, rs[0], 'description');
    return { n: rs.length, tallest: Math.max(0, ...rs.map(r => r.getBoundingClientRect().height)), desc: d ? d.getBoundingClientRect().width : 0 };`);
  check(lay.n === a.waits && lay.tallest <= 320 && lay.desc >= 300, T + `Waits: ${lay.n} rows (the API has ${a.waits}), the tallest ${Math.round(lay.tallest)} px, the description column ${Math.round(lay.desc)} px wide`);
  await pv(`const t = gridOf('wait time (ms/sec/core)'); t.scrollIntoView({ block: 'start' }); const w = t.closest('.grid-wrap'); if (w) w.scrollLeft = w.scrollWidth; return 'ok';`);
  await sleep(200); await shot('waits-grid', theme);

  check(await go('#/running', 'max memory grant'), T + 'the fleet Running queries page rendered with the grant columns');
  const f = await pv(`const t = gridOf('max memory grant'); const tr = rowWith(t, 'instance', ${JSON.stringify(a.fleet)}); const pg = rowWith(t, 'instance', ${JSON.stringify(a.pg)});
    const six = ['max memory grant', 'sum of memory grants', 'tempdb latch waits', 'tempdb latch wait (ms)', 'tempdb allocation waits', 'tempdb allocation wait (ms)'];
    return { ms: tr ? six.map(c => text(t, tr, c)).join('|') : null, pg: pg ? six.map(c => text(t, pg, c)).join('|') : null };`);
  check(f.ms === '4.0 MB|5.0 MB|2|800|1|500' && f.pg === '|||||', T + `the fleet row of the stored snapshot '${f.ms}' (want 4.0 MB|5.0 MB|2|800|1|500), a PostgreSQL row '${f.pg}' (want six empty cells)`);
  await shot('fleet', theme);
  // the new columns stand at the right end of a wide grid: a second picture with the grid scrolled to them
  await pv(`const w = gridOf('max memory grant').closest('.grid-wrap'); if (w) w.scrollLeft = w.scrollWidth; return 'ok';`);
  await sleep(200); await shot('fleet-right', theme);
}
ws.close();
process.exit(fails ? 1 : 0);
JS
  ARGS=$(jq -nc --arg cdp "$CDP" --arg u "http://127.0.0.1:$PORT" --arg shots "$PGVIGIL_SHOTS" --arg db "$DB" --argjson iid "$iid" --arg fleet "proof-reads-fleet-$SUF" --arg pg "proof-reads-pg-$SUF" --arg lck "$LT" \
    --argjson linux "$([ "$HOSTP" = Linux ] && echo true || echo false)" \
    --argjson waits "$(curl -fs "$U/mssql/waits?instance=$iid&$(win)" | jq '.events.rows | length')" \
    '{cdp: $cdp, u: $u, shots: $shots, db: $db, iid: $iid, fleet: $fleet, pg: $pg, lck: $lck, linux: $linux, waits: $waits}')
  node "$WORK/ui.mjs" "$ARGS" || fail "S: the pages"
  kill "$CHR_PID" 2>/dev/null || true; wait "$CHR_PID" 2>/dev/null || true; CHR_PID=
  echo "S: OK (fourteen screenshots in $PGVIGIL_SHOTS: reads-<page>-<theme>.png)"; S_NOTE=", S"
else
  echo "--- S. the pages in a browser: NOT RUN (PGVIGIL_SHOTS names no folder)"; S_NOTE=""
fi
[ -n "$S_NOTE" ] && PAGES="" || PAGES=", the pages in a browser (part S was not run)"

echo "NOT PROVEN HERE: a real power plan (Windows), a real tempdb page latch wait, SQL Server 2016-2019, RDS, Managed Instance, a list cut and a database skipped on a real server, a columnstore rowset with lock waits, the pages' accessibility (proof-a11y)$PAGES"
echo "proof-mssql-reads: PASS ($M_NOTE, $A_NOTE, B, C, $D_NOTE, E, F, G, X, Y, P$S_NOTE; SQL Server $([ -n "$OWN" ] && echo "in its own container" || echo "sandbox $CT"))"
