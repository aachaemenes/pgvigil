#!/usr/bin/env bash
# Proof of task 407 (B13, SQL Server storage depth): migration 0158, internal/mssql/storage.go (the space split, the
# collections mssql_storage_depth and mssql_tables), fileio.go (the queued stall, the IOs pending), versionstore.go
# (tempdb's pages), dboptions.go (the log's holder), GET /api/mssql/storage_depth and /api/mssql/dbio - against hand
# reads of the same SQL Server at the same moments, and against hand computations on rows the proof writes into its
# own repository.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, the lead's wiring patch applied to the
# tree first (web.go's two routes, 0190's findings arm and purge lines, q_mssql_summary.go's Disk mapping: the API, P4's
# purge and the Summary rows read them; without it those rows fail as the branch's own fault), and
#   ADMIN_DSN        a superuser connection to a PostgreSQL in keyword form (default 'host=127.0.0.1 port=5432 user=postgres
#                    dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGES   the SQL Server images: the first the full run, the others the version run (default '2022-latest 2017-latest').
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment, never a command
# line. Only the collection a step names runs (pgvigil collect -once).
#
# Expected (written before the first run; red on f8e89d2 at A: 'unknown collection mssql_storage_depth'; rewritten
# before the run after the reviewer's pass 20261114-200720 and its fold):
#  A. the first image's container; tempdb's data files set to 16 MB each without growth (a restart: the host port read
#     again); a monitor login with VIEW SERVER STATE, VIEW ANY DEFINITION, a user in each proof database and
#     db_datareader in msdb (mssql_checks' jobs and backups read it); migrate ok; mssql_storage, mssql_versionstore,
#     mssql_fileio, mssql_storage_depth and mssql_tables each 'ok' as the monitor login (collection_dates).
#  P1 days until full (rows written for an instance of the proof's own): 30 days of hourly samples - E: +10 GB/day, 500
#     GB free -> 50.0 days, no finding; F: 20.0 days, warning; G: 5.0 days, critical; each within 0.2 days of a
#     least-squares slope computed here; H: one +300 GB step 4 days ago -> no finding although the 7-day figure is under
#     30 days; I: a weekly sawtooth -> none; J: shrinking -> NULL, none. One Linux file system of three directories (the
#     same total and free), the first in name order new with one day of samples -> ONE forecast row naming all three,
#     its 30-day figure 5.0 days read from every directory, ONE critical finding named by that first directory. K: 6
#     days of reads -> no 30-day figure, no finding, the 7-day figure 2.5 days (F7).
#  P2 the space split: sp_spaceused's reserved, data, index_size and unused (KB) and unallocated (MB) right before and
#     after one mssql_storage read, the two equal -> mssql_database_space's row equal to them.
#  P3 tempdb, judged on the newest read against its capacity: a: data files fixed; a session's #table of about 55 % ->
#     the user-object pages = a hand read within 64 KB, 'tempdb data files filling' a warning, the Summary holding no
#     depth arm; 85 % -> critical; released (the hand read under 40 %) -> no finding. b: the files allowed to grow without
#     max on a volume with gigabytes free, the hold at 50 % or more by a hand read -> no finding, capacity > size + 1 GB.
#     c (rows written): files growing without max, 10 MB free: 60 of 110 MB = 54.5 %, volume-limited, a warning; 95 of
#     110 MB critical; no volume read -> capacity unknown, no finding. d (rows written): the hourly sizes older than the
#     minute's read - four files of 2 GB, max 4 GB, the minute 15.2 GB used of 15.6 -> capacity 16 GB, 95.0 %, critical;
#     max 8 GB, 23.4 GB used of 24 -> 32 GB, 73.1 %, a warning; two Linux directories of one file system, 10 MB free ->
#     capacity 110 MB, 54.5 %; no tempdb file row -> capacity unknown, used_pct NULL, no finding; a tempdb log at
#     UNLIMITED (268435456 pages) is no 'max size', one at 1 GB is.
#  P4 every table: 1,190 heaps and the specials (PAGE, ROW, clustered columnstore, two partitions ROW and PAGE,
#     memory-optimized, system-versioned with its history, node and edge, a table with a primary XML index) -> every
#     table sys.tables lists, its type and compression = a hand read ('mixed: ROW 1, PAGE 1'); the memory-optimized
#     size > 0; the XML table's rows, reserved, data, index and unused KB = sp_spaceused 'dbo.x1'; no tempdb or model
#     row and no read marker for them; the start cursor stored (a whole pass: 0); a read with nothing changed -> no
#     sample; 3 tables changed -> exactly 3 samples; a dropped table marked gone, then removed by purge() past the
#     retention (purge() counting at least it, the read after it in its own statement). Growth (rows written): grown
#     +200 KB, still 0, a table new 3 days ago +50 KB from 0; unknown, dnot and dnew left out; one database only
#     (p_db) answers for it alone; an unchanged table with no sample -> a flat series of two points from the window's
#     start. P4b (through the import): one run in two imports at one snapshot keeps both tables and both samples; the
#     next run's list without a database marks its tables gone and removes its marker; the cursor stored.
#  P5 IO per database: two mssql_fileio reads around writes and reads on two databases -> reads, bytes, writes, bytes
#     and the read and write stalls per database = a hand diff of sys.dm_io_virtual_file_stats; latency = stall /
#     operations; the IOs pending stored at each read (never NULL). mssql_io_compare against rows written a day before =
#     the sums computed here. A database id reused on another volume: the old IO stays on its volume. The month's
#     partition holding 24 hours of 3,000 databases (4.3 million rows) and the window one hour of it: the app's two
#     reads as it sends them - the grid's totals and the series of a literal top 10 - each under 2 s and each through
#     the partition's index (an Index or Bitmap scan), their plans printed.
#  P6 the queued stall: a resource pool with MAX_IOPS_PER_VOLUME 20 for a login; its reads past the limit -> the queued
#     read stall stored between two reads = the server's delta (io_stall_queued_read_ms) by hand; a read during the
#     throttled scan sees IOs pending: pgvrg's files hold them (more than 0, at most the read's total) - or NOT PROVEN
#     when none was pending at that read (or the pool cannot be made, with the server's reason).
#  P7 the counters read per database: 401's mssql_counters_db - NOT PROVEN until 401 joins; 407 is DONE only after.
#  P8 the rules, each made, read, cleared and the clear read: two log files; a full 8 MB file (info); a filegroup of 8
#     and 16 MB (info); a 1 MB growth step; model growing 10 % and 1 MB; one tempdb data file with a max size -> exactly
#     'warning tempdb: <that file>'; the Summary holding none of these while they are live. A detached database's two
#     files -> orphans (warning; the Summary none), info with a second instance of the machine, none attached again. A
#     .mdf in a subfolder of the data folder -> no orphan, every folder listed. tempdb's paths kept from the first read
#     after the server's start (its start stored, the running data file among them); an older start stored (a stand-in
#     for a restart) -> taken again from the next read, the old paths gone. tempdb moved before its restart
#     (MODIFY FILE names the new path in sys.master_files and tempdb.sys.database_files at once) -> no orphan, every
#     folder listed. The kept paths wiped (pgvigil's first read after the start made after the move) -> the running
#     file is 'info', its text 'a tempdb file move may be pending (the files run until the restart)', never a plain
#     orphan. A tempdb-named file not written since the server's start (a finished move's leftover; mtime 2020) -> a
#     plain warning orphan. A folder holding only a memory-optimized container (a directory) -> the orphans read. A
#     folder that cannot be listed (mode 000; SQL Server on Linux lists it as empty, without an error) -> the orphans
#     not read this run, the note naming it, the stored list as it was. 'SMO and DMO XPs' 0 -> the drives and orphans 'not read: SMO and DMO XPs is
#     off on this server', 1 -> read. The C: rules (rows written for a Windows instance): one finding each, the Summary
#     none; none on the Linux container. No name of 0158's view, looked for as its SQL literal, in 0111's view.
#  P9 the log's holder: a SIMPLE database with a 32 MB log that does not grow, a login's open transaction past 82 %, a
#     CHECKPOINT -> ACTIVE_TRANSACTION, the rule names 'held by session <n> (<login>, ' and 'DBCC SQLPERF(LOGSPACE)';
#     committed -> no holder. tempdb's log (set not to grow for the row, then back) held by a session's #table, filled
#     to 82 % (the row polls for it up to 155 s, never a fixed wait; the filler stops at 150 s) -> the rule names that
#     session. The row first gives tempdb's log 35 % of committed work, not yet truncated (a state earlier rows may
#     leave: 34.3 % in one run). The CHECKPOINT after the fill (for the wait ACTIVE_TRANSACTION) frees the whole VLFs
#     before the one holding the holder's first log record, so without more the read is the fill minus those VLFs; a
#     CHECKPOINT before the holder truncates that work first and keeps the read at the fill, unless a VLF boundary falls
#     between that CHECKPOINT and the holder's first insert. The fixture (the seed without that CHECKPOINT) is red only
#     when the holder's first record lands in a later VLF than the oldest active one (every VLF smaller than the 35 %
#     seed gives that: 4 VLFs of 1.9 to 2.2 MB in the 8 MB log, the largest 27.3 %, in one run) and no automatic
#     checkpoint frees the seed during the fill. A read under the rule's 75 % (the stored log_used_pct, the
#     rule's own input) with no finding fails as 'the setup's fill fell to <n> %', never as the rule's fault. The row
#     prints, pass or fail, tempdb's VLFs before the holder (count, sizes, active, the largest as % of the log), the
#     active VLFs ahead of the holder's first record at the fill, the seconds the fill took (or 'not reached'), tempdb's log size and used %
#     at the read (sys.dm_db_log_space_usage before and after the collect, DBCC SQLPERF(LOGSPACE)'s tempdb row), the
#     open transactions in tempdb's log oldest first, mssql_checks' last run and what it stored for tempdb's log
#     (mssql_database_option). A FULL database with a full backup and no log backup, filled by committed work, an open
#     transaction in it -> the rule fires on LOG_BACKUP and names no holder.
#  P10 the version run: each further image repeats A, P2, P4, P5 and P8's two-log and orphan rows.
#  P11 the API: the storage depth with a database and a table gives exactly its 15 parts; ?parts=runs,space exactly
#     those; /api/mssql/dbio by volume against a week exactly grid, series and compare; the '/' drive's total null on the
#     API and the runs part holding mssql_tables and mssql_storage 'ok'; the API's compare (joined in Go) = the function.
#     The Summary: the forecast in Disk, no other depth arm in a cell.
#  P12 least privilege: on 2022 a login with VIEW SERVER PERFORMANCE STATE and VIEW ANY DEFINITION, no VIEW SERVER STATE
#     -> mssql_storage, mssql_storage_depth and mssql_tables ok, the split and the volumes read (NOT PROVEN on 2017: 2022 only); a
#     login with VIEW SERVER STATE and no VIEW ANY DEFINITION -> the paths and drives read, the orphans 'not read: the
#     login lacks VIEW ANY DEFINITION...', mssql_tables skipped naming it. 'disabled: [mssql_tables]' in an instance's
#     entry is a valid configuration; the scheduler run 30 s with it -> no new mssql_tables run, read marker or sample
#     while mssql_storage_depth is read again, and the depth API (a server on that configuration) gives mssql_tables
#     'off' (the page's 'off: ...' line), mssql_storage_depth 'ok'. Red first on 704c4d7: no 'off' status there.
#  NOT PROVEN HERE: SQL Server 2016 (no Linux image), Windows volumes, mount points, drive roots and the C: rules on a
#     real Windows server, Managed Instance and RDS, a distributed transaction holding a log (Go test only), the Windows
#     host's disk counters (no host door).
set -uo pipefail
cd "$(dirname "$0")/.."
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
read -r -a IMAGES <<<"${PGVIGIL_IMAGES:-2022-latest 2017-latest}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
PGDB=pgv_sd_$SUF; MON=pgv_mon_$SUF; HOLDER=pgv_hold_$SUF; RGL=pgv_rg_$SUF
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SA_PW=$(pw); MON_PW=$(pw); HOLD_PW=$(pw); RG_PW=$(pw); FAILS=0; NP=0; SQL=; SRV_PID=; BG=()
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nHOLD_PW=%s\nRG_PW=%s\n' "$SA_PW" "$SA_PW" "$HOLD_PW" "$RG_PW" > "$TMPD/sa.env"
cleanup() {
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null; done
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
  docker ps -aq --filter "label=pgv-sd-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
np() { echo "NOT PROVEN $*"; NP=$((NP + 1)); }
fail() { echo "FAIL $*"; exit 1; }
# sq: a statement as sa in the container (database $2, default master); sqh: as the holder login; sqr: as the pool's login
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${SQ_TIMEOUT:-300}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqv() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || bad "$1: $(tr '\n' ' ' <<<"$out" | head -c 300)"; }  # $1 label $2 statement [$3 db]
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
eqv() { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: got [$2] want [$3]"; fi; }
check() { local got; got=$(pq "$2" 2>&1); eqv "$1" "$got" "$3"; }
collect() { "$BIN" collect -config "$TMPD/m.yaml" -once "$1" -instance sqlbox > "$TMPD/collect.out" 2>&1 || { tail -5 "$TMPD/collect.out"; return 1; }; }
# lastrun: the collection's last run as pgvigil.log_collection keeps it (collection_dates: every status; collection_log: not ok only)
lastrun() { pq "SELECT d.status || coalesce(': ' || d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i ON i.instance_id = d.instance_id WHERE d.collection = '$1' AND i.name = '${2:-sqlbox}' ORDER BY d.snapshot_at DESC LIMIT 1"; }

for t in docker go psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
BIN=$TMPD/pgvigil
go build -o "$BIN" ./cmd/pgvigil || fail "build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null || fail "repository database"
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"

# ---- a container, its logins, the repository ----------------------------------------------------------------------
start_server() {  # $1 image tag
  SQL=pgv-sd-$SUF-${1%%-*}
  docker run -d --name "$SQL" --label "pgv-sd-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$1" >/dev/null || fail "docker run $1"
  SQLCMD=/opt/mssql-tools18/bin/sqlcmd
  for _ in $(seq 1 30); do docker exec "$SQL" test -e /opt >/dev/null 2>&1 && break; sleep 1; done
  docker exec "$SQL" test -x "$SQLCMD" || SQLCMD=/opt/mssql-tools/bin/sqlcmd
  wait_up || { docker logs --tail 15 "$SQL" 2>&1 | sed 's/^/     container: /'; fail "$1 did not come up (sqlcmd $SQLCMD)"; }
  MAJOR=$(sq "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS int)")
  sq "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];" >/dev/null || fail "monitor login"
  sq "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb >/dev/null
  set_dsn
  cat > "$TMPD/m.yaml" <<YAML
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_SD_MON
YAML
}
# set_dsn: the monitor login's DSN on the container's host port, read again after every restart (a port published as
# 127.0.0.1::1433 gets a new host port when the container restarts)
set_dsn() {
  PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
  export PGV_SD_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
}
wait_up() {
  local r=""
  for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" 2>/dev/null); [[ "$r" == 1 ]] && return 0; sleep 2; done
  return 1
}
mkdb() {  # $1 name [$2 extra CREATE DATABASE text]: a database with the monitor login's user
  sq "CREATE DATABASE [$1] ${2:-}; " >/dev/null && sq "CREATE USER [$MON] FOR LOGIN [$MON];" "$1" >/dev/null
}

echo "== A: ${IMAGES[0]}"
start_server "${IMAGES[0]}"
ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")"
# tempdb's data files: 16 MB each, no growth (a restart makes them so)
sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name) + N', SIZE = 16MB, FILEGROWTH = 0);' FROM tempdb.sys.database_files WHERE type = 0; EXEC (@s);" >/dev/null || bad "tempdb resize"
docker restart "$SQL" >/dev/null && wait_up || fail "restart"
set_dsn
"$BIN" migrate -config "$TMPD/m.yaml" > "$TMPD/migrate.out" 2>&1 && ok "migrate" || { tail -20 "$TMPD/migrate.out"; fail "migrate"; }
for c in mssql_storage mssql_versionstore mssql_fileio mssql_storage_depth mssql_tables; do
  collect "$c" || true
  eqv "A: $c runs as the monitor login" "$(lastrun "$c")" "ok"
done
IID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
PORT=$((20000 + RANDOM % 20000))
"$BIN" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.out" 2>&1 & SRV_PID=$!
for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$PORT/api/instances" >/dev/null 2>&1 && break; sleep 1; done
# summary_check: while some depth arms are live, the Summary's cells hold none of them (only the forecast maps, to Disk)
summary_check() {  # $1 label [$2 instance]
  local inst=${2:-$IID}
  curl -s "http://127.0.0.1:$PORT/api/mssql/summary?part=cells" > "$TMPD/sum.json"
  python3 - "$TMPD/sum.json" "$inst" <<'PY2' && ok "$1: no live depth arm in a Summary cell" || bad "$1: a depth arm in a Summary cell"
import json, sys
d = json.load(open(sys.argv[1])); iid = int(sys.argv[2])
t = d.get('cells') or {'columns': [], 'rows': []}
cells = [c for c in (dict(zip(t['columns'], r)) for r in t['rows']) if int(c.get('instance_id') or -1) == iid]
names = ['tempdb data files filling', 'more than one log file', 'a file under 20 % free inside it', "a filegroup's data files unbalanced",
         'a data file growth step under 64 MB', 'model grows by', 'a tempdb file', 'the default', 'an orphaned database file']
bad = False
for c in cells:
    for x in c.get('detail') or []:
        if any(str(x).startswith(n) for n in names):
            print('     in', c.get('key'), ':', x); bad = True
sys.exit(1 if bad else 0)
PY2
}
# live_count: how many rows of a depth arm are live now (a summary_check is only worth its row with one)
live_count() { pq "SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = ${2:-$IID} AND check_name LIKE '$1'"; }

# ---- P1 days until full ------------------------------------------------------------------------------------------------
echo "== P1: days until full"
FC=$(pq "SELECT pgvigil.ensure_instance('fc-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
python3 - "$TMPD/p1.sql" "$TMPD/p1.want" "$FC" <<'PY'
import sys
out, want, inst = sys.argv[1], sys.argv[2], int(sys.argv[3])
GB = 1024**3
T = 4000 * GB
def series(kind):
    pts = []
    for h in range(30 * 24, -1, -1):          # hourly, 30 days back to now
        d = h / 24.0
        if kind == 'E':  used = T - 500*GB - 10*GB*d
        elif kind == 'F': used = T - 400*GB - 20*GB*d
        elif kind == 'G': used = T - 100*GB - 20*GB*d
        elif kind == 'H': used = T - 300*GB - (300*GB if d > 4 else 0)
        elif kind == 'I': used = T - 1000*GB + (50*GB if int(d // 3.5) % 2 else 0)
        elif kind == 'J': used = T - 1000*GB + 5*GB*d
        elif kind == 'L': used = T - 100*GB - 20*GB*d
        pts.append((h, int(used)))
    return pts
vols = {'E': 'E:\\', 'F': 'F:\\', 'G': 'G:\\', 'H': 'H:\\', 'I': 'I:\\', 'J': 'J:\\'}
lines = ["SELECT pgvigil.ensure_month_partition('mssql_volume_sample', now() - interval '%d days');" % k for k in (0, 15, 31)]
wants = []
def slope(pts, days):
    xs = [-h/24.0 for h, u in pts if h/24.0 < days]; ys = [u for h, u in pts if h/24.0 < days]
    n = len(xs); mx = sum(xs)/n; my = sum(ys)/n
    return sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sum((x-mx)**2 for x in xs)
for k, pts in [(k, series(k)) for k in 'EFGHIJ'] + [('L', series('L'))]:
    names = [vols[k]] if k != 'L' else ['/var/opt/mssql/data/', '/var/opt/mssql/log/', '/var/opt/mssql/a_new/']
    free_now = T - pts[-1][1]
    for name in names:
        lines.append("INSERT INTO pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, files, snapshot_at, is_present) VALUES (%d, '%s', %d, %d, 1, now(), true);" % (inst, name.replace("'", "''"), T, free_now))
        # a directory new to the file system (it sorts first, so it names the group): one day of samples only
        for h, u in (pts if not name.endswith('a_new/') else [x for x in pts if x[0] <= 24]):
            lines.append("INSERT INTO pgvigil.mssql_volume_sample (instance_id, snapshot_at, volume, total_bytes, free_bytes) VALUES (%d, now() - interval '%d hours', '%s', %d, %d);" % (inst, h, name, T, T - u))
    g30 = slope(pts, 30); g7 = slope(pts, 7)
    d30 = round(free_now / g30, 1) if g30 > 0 else None
    d7 = round(free_now / g7, 1) if g7 > 0 else None
    wants.append("%s|%s|%s" % (min(names), d30, d7))   # a file system's row is named by its first directory
open(out, 'w').write("\n".join(lines) + "\n")
open(want, 'w').write("\n".join(wants) + "\n")
PY
psql "$PGDSN" -Xq -v ON_ERROR_STOP=1 -f "$TMPD/p1.sql" >/dev/null || bad "P1 rows"
while IFS='|' read -r vol d30 d7; do
  got=$(pq "SELECT coalesce(days_until_full::text, 'None') || '|' || coalesce(days_until_full_7::text, 'None') FROM pgvigil.mssql_volume_forecast($FC) WHERE volume = '$vol'")
  python3 - "$vol" "$got" "$d30" "$d7" <<'PY' && ok "P1 $vol: $got (hand $d30 / $d7)" || bad "P1 $vol: got $got, hand $d30 / $d7"
import sys
vol, got, d30, d7 = sys.argv[1:]
g = got.split('|')
def near(a, b):
    if a == 'None' or b == 'None': return a == b
    return abs(float(a) - float(b)) <= 0.2
sys.exit(0 if len(g) == 2 and near(g[0], d30) and near(g[1], d7) else 1)
PY
done < "$TMPD/p1.want"
check "P1 findings: F warning, G critical, the Linux file system critical (named by its first directory), nothing else" \
  "SELECT string_agg(object || ':' || severity, ' ' ORDER BY object) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $FC AND check_name = 'a volume full within 30 days'" \
  '/var/opt/mssql/a_new/:critical F:\:warning G:\:critical'
check "P1 one row for the three Linux directories, naming all three; its 30-day slope read from every directory (5.0 days, the new one has one day)" \
  "WITH f AS (SELECT * FROM pgvigil.mssql_volume_forecast($FC) WHERE volume LIKE '/%')
   SELECT (SELECT count(*) FROM f) || ' ' || (SELECT string_agg(x, ', ' ORDER BY x) FROM f, unnest(string_to_array(f.directories, ', ')) x) || ' ' || (SELECT max(days_until_full) FROM f)" \
  '1 /var/opt/mssql/a_new/, /var/opt/mssql/data/, /var/opt/mssql/log/ 5.0'
check "P1 H: the 7-day figure under 30 days, the 30-day one not" \
  "SELECT (days_until_full_7 < 30) || ' ' || (days_until_full IS NULL OR days_until_full >= 30) FROM pgvigil.mssql_volume_forecast($FC) WHERE volume = 'H:\'" 'true true'
# F7: under 7 days of samples there is no 30-day figure, so no severity, while the 7-day figure is shown
pq "INSERT INTO pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, files, snapshot_at, is_present) VALUES ($FC, 'K:\', 4000*1024^3, 50*1024^3, 1, now(), true);
INSERT INTO pgvigil.mssql_volume_sample (instance_id, snapshot_at, volume, total_bytes, free_bytes)
  SELECT $FC, now() - make_interval(hours => h), 'K:\', 4000*1024^3, (50 + 20 * h / 24.0) * 1024^3 FROM generate_series(0, 6 * 24 - 1) h" >/dev/null || bad "P1 K rows"
check "P1 K: 6 days of reads - no 30-day figure, no finding, the 7-day figure 2.5 days" \
  "SELECT coalesce(days_until_full::text, 'none') || ' ' || days_until_full_7 || ' ' || (SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $FC AND object = 'K:\') FROM pgvigil.mssql_volume_forecast($FC) WHERE volume = 'K:\'" 'none 2.5 0'

# ---- P2 the space split -----------------------------------------------------------------------------------------------
space_check() {  # $1 label
  mkdb pgvsd >/dev/null
  sq "CREATE TABLE dbo.heap1 (id int, pad char(2000)); CREATE TABLE dbo.clus1 (id int PRIMARY KEY, a int, b int, pad char(500));
INSERT dbo.heap1 SELECT TOP (3000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'x' FROM sys.all_objects a CROSS JOIN sys.all_objects b;
INSERT dbo.clus1 SELECT id, id % 97, id % 13, 'y' FROM dbo.heap1;
CREATE INDEX ix_a ON dbo.clus1 (a) INCLUDE (pad); CREATE INDEX ix_b ON dbo.clus1 (b);" pgvsd >/dev/null || bad "$1 P2 tables"
  local q="EXEC sp_spaceused @oneresultset = 1"
  local before after
  before=$(sq "$q" pgvsd); collect mssql_storage || bad "$1 P2 collect"; after=$(sq "$q" pgvsd)
  eqv "$1 P2 two hand reads equal around the read" "$([[ "$before" == "$after" ]] && echo same || echo differ)" same
  local hand got
  hand=$(python3 -c '
import sys
f = sys.argv[1].split("|")   # database_name|database_size|unallocated space|reserved|data|index_size|unused
kb = lambda s: int(s.strip().split()[0])
mb = lambda s: float(s.strip().split()[0])
print("%d %d %d %d %.2f" % (kb(f[3]), kb(f[4]), kb(f[5]), kb(f[6]), mb(f[2])))' "$after")
  got=$(pq "SELECT reserved_bytes/1024 || ' ' || data_bytes/1024 || ' ' || index_bytes/1024 || ' ' || unused_bytes/1024 || ' ' || to_char(round(unallocated_bytes/1048576.0, 2), 'FM999999990.00')
              FROM pgvigil.mssql_database_space WHERE instance_id = $IID AND database_name = 'pgvsd' ORDER BY snapshot_at DESC LIMIT 1")
  eqv "$1 P2 reserved data index unused (KB) unallocated (MB) = sp_spaceused" "$got" "$hand"
}
echo "== P2: the space split"
space_check "${IMAGES[0]}"

# ---- P3 tempdb ---------------------------------------------------------------------------------------------------------
echo "== P3: tempdb"
hold_temp() {  # $1 KB to hold in a #table, $2 seconds: a background session as sa
  printf 'SET NOCOUNT ON; CREATE TABLE #h (pad char(8000)); INSERT #h SELECT TOP (%d) %s FROM sys.all_objects a CROSS JOIN sys.all_objects b; WAITFOR DELAY %s;\n' \
    "$(( $1 / 8 ))" "'x'" "'00:00:$(printf %02d "$2")'" |
    docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -i /dev/stdin' > /dev/null 2>&1 &
  BG+=($!); HOLD_PID=$!
}
tempdb_kb=$(sq "SELECT SUM(size) * 8 FROM tempdb.sys.database_files WHERE type = 0")
collect mssql_storage >/dev/null
hold_temp $(( tempdb_kb * 55 / 100 )) 50; sleep 15
collect mssql_versionstore || bad "P3 collect"
hand=$(sq "SELECT SUM(user_object_reserved_page_count) * 8 FROM tempdb.sys.dm_db_file_space_usage")
got=$(pq "SELECT user_object_bytes / 1024 FROM pgvigil.mssql_versionstore_sample WHERE instance_id = $IID ORDER BY snapshot_at DESC LIMIT 1")
python3 -c 'import sys; a,b=int(sys.argv[1]),int(sys.argv[2]); sys.exit(0 if abs(a-b) <= 64 else 1)' "$got" "$hand" && ok "P3a user-object KB $got = the hand read $hand (within 64 KB, one extent per file)" || bad "P3a user-object KB $got, hand $hand"
check "P3a 55 %: warning" "SELECT severity FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = 'tempdb data files filling'" warning
summary_check "P3a tempdb filling live ($(live_count 'tempdb data files filling'))"
wait "$HOLD_PID" 2>/dev/null
hold_temp $(( tempdb_kb * 85 / 100 )) 40; sleep 18
collect mssql_versionstore
check "P3a 85 %: critical" "SELECT severity FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = 'tempdb data files filling'" critical
wait "$HOLD_PID" 2>/dev/null
for _ in $(seq 1 30); do hp=$(sq "SELECT CAST(100.0 * SUM(total_page_count - unallocated_extent_page_count) / SUM(total_page_count) AS int) FROM tempdb.sys.dm_db_file_space_usage"); [[ "${hp:-100}" -lt 40 ]] && break; sleep 2; done
echo "     tempdb used by the hand read before the released read: ${hp:-not read} %"
collect mssql_versionstore
check "P3a released: no finding" "SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = 'tempdb data files filling'" 0
sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name) + N', FILEGROWTH = 64MB, MAXSIZE = UNLIMITED);' FROM tempdb.sys.database_files WHERE type = 0; EXEC (@s);" >/dev/null
collect mssql_storage >/dev/null
hold_temp $(( tempdb_kb * 55 / 100 )) 40; sleep 15
collect mssql_versionstore
hp=$(sq "SELECT CAST(100.0 * SUM(user_object_reserved_page_count) / SUM(total_page_count) AS int) FROM tempdb.sys.dm_db_file_space_usage")
[[ "${hp:-0}" -ge 50 ]] && ok "P3b the hold fills ${hp} % of the files (hand read)" || bad "P3b the hold filled only ${hp:-not read} % of the files: the row below would prove nothing"
check "P3b growable on a volume with room: no finding at 55 % of the files" "SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = 'tempdb data files filling'" 0
check "P3b capacity includes the volume's free space" "SELECT capacity_bytes > size_bytes + 1024^3 FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $IID" t
wait "$HOLD_PID" 2>/dev/null
TC=$(pq "SELECT pgvigil.ensure_instance('tc-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
TU=$(pq "SELECT pgvigil.ensure_instance('tu-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "SELECT pgvigil.ensure_month_partition('mssql_versionstore_sample', now());
INSERT INTO pgvigil.mssql_versionstore_sample (instance_id, snapshot_at, reserved_bytes, tempdb_data_bytes, user_object_bytes, internal_object_bytes, mixed_extent_bytes, unallocated_bytes)
  VALUES ($TC, now(), 0, 100*1048576, 60*1048576, 0, 0, 40*1048576), ($TU, now(), 0, 100*1048576, 60*1048576, 0, 0, 40*1048576);
INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, type_desc, size_bytes, max_size_bytes, growth_bytes, growth_pct, volume, snapshot_at, first_seen)
  VALUES ($TC, 2, 1, 'tempdb', 'ROWS', 100*1048576, NULL, 64*1048576, 0, 'T:\', now(), now()), ($TU, 2, 1, 'tempdb', 'ROWS', 100*1048576, NULL, 64*1048576, 0, 'U:\', now(), now());
INSERT INTO pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, snapshot_at) VALUES ($TC, 'T:\', 200*1048576, 10*1048576, now());" >/dev/null || bad "P3c rows"
check "P3c volume-limited: 60 MB of 110 MB (54.5 %), a warning" "SELECT used_pct || ' ' || volume_limited || ' ' || (SELECT severity FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TC AND check_name = 'tempdb data files filling') FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $TC" '54.5 true warning'
pq "UPDATE pgvigil.mssql_versionstore_sample SET user_object_bytes = 95*1048576, unallocated_bytes = 5*1048576 WHERE instance_id = $TC" >/dev/null
check "P3c 95 MB of 110 MB: critical" "SELECT severity FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TC AND check_name = 'tempdb data files filling'" critical
check "P3c no volume read: capacity unknown, no finding" "SELECT capacity_unknown || ' ' || (SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TU) FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $TU" 'true 0'
# P3d (rows written): the hourly file sizes older than the minute's read - the capacity does not move with the growth
GB=1073741824
for k in 4 8; do
  TD=$(pq "SELECT pgvigil.ensure_instance('td$k-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
  pq "INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, type_desc, size_bytes, max_size_bytes, growth_bytes, growth_pct, volume, snapshot_at, first_seen)
        SELECT $TD, 2, f, 'tempdb', 'ROWS', 2::bigint*$GB, $k::bigint*$GB, 64*1048576, 0, 'D:\', now() - interval '40 minutes', now() FROM generate_series(1, 4) f;
      INSERT INTO pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, snapshot_at) VALUES ($TD, 'D:\', 200::bigint*$GB, 100::bigint*$GB, now() - interval '40 minutes');
      INSERT INTO pgvigil.mssql_versionstore_sample (instance_id, snapshot_at, reserved_bytes, tempdb_data_bytes, user_object_bytes, internal_object_bytes, mixed_extent_bytes, unallocated_bytes)
        VALUES ($TD, now(), 0, CASE $k WHEN 4 THEN 15.6 ELSE 24 END * $GB, 0, 0, 0, CASE $k WHEN 4 THEN 0.4 ELSE 0.6 END * $GB)" >/dev/null || bad "P3d rows $k"
  [[ $k == 4 ]] && check "P3d four files grown 2 -> 3.9 GB since the hourly read, max 4 GB: 15.2 of 16 GB, critical" \
    "SELECT (capacity_bytes / $GB)::float8 || ' ' || used_pct || ' ' || (SELECT severity FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TD AND check_name = 'tempdb data files filling') FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $TD" '16 95.0 critical'
  [[ $k == 8 ]] && check "P3d grown 2 -> 6 GB each, max 8 GB: 23.4 of 32 GB, a warning" \
    "SELECT (capacity_bytes / $GB)::float8 || ' ' || used_pct || ' ' || (SELECT severity FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TD AND check_name = 'tempdb data files filling') FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $TD" '32 73.1 warning'
done
TL=$(pq "SELECT pgvigil.ensure_instance('tl-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, type_desc, size_bytes, max_size_bytes, growth_bytes, growth_pct, volume, snapshot_at, first_seen)
      VALUES ($TL, 2, 1, 'tempdb', 'ROWS', 50*1048576, NULL, 64*1048576, 0, '/t/a/', now(), now()), ($TL, 2, 3, 'tempdb', 'ROWS', 50*1048576, NULL, 64*1048576, 0, '/t/b/', now(), now());
    INSERT INTO pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, snapshot_at) VALUES ($TL, '/t/a/', 100*1048576, 10*1048576, now()), ($TL, '/t/b/', 100*1048576, 10*1048576, now());
    INSERT INTO pgvigil.mssql_versionstore_sample (instance_id, snapshot_at, reserved_bytes, tempdb_data_bytes, user_object_bytes, internal_object_bytes, mixed_extent_bytes, unallocated_bytes)
      VALUES ($TL, now(), 0, 100*1048576, 60*1048576, 0, 0, 40*1048576)" >/dev/null || bad "P3d Linux rows"
check "P3d two Linux directories of one file system: its 10 MB free counted once (capacity 110 MB, 54.5 %)" \
  "SELECT (capacity_bytes / 1048576)::float8 || ' ' || used_pct FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $TL" '110 54.5'
TN=$(pq "SELECT pgvigil.ensure_instance('tn-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "INSERT INTO pgvigil.mssql_versionstore_sample (instance_id, snapshot_at, reserved_bytes, tempdb_data_bytes, user_object_bytes, internal_object_bytes, mixed_extent_bytes, unallocated_bytes)
      VALUES ($TN, now(), 0, 100*1048576, 90*1048576, 0, 0, 10*1048576)" >/dev/null
check "P3d tempdb's files not read: capacity unknown, no finding (never judged against the size alone)" \
  "SELECT capacity_unknown || ' ' || coalesce(used_pct::text, 'none') || ' ' || (SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TN) FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $TN" 'true none 0'
TG=$(pq "SELECT pgvigil.ensure_instance('tg-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, file_name, type_desc, size_bytes, max_size_bytes, growth_bytes, growth_pct, volume, snapshot_at, first_seen)
      VALUES ($TG, 2, 2, 'tempdb', 'templog', 'LOG', 8*1048576, 268435456::bigint * 8192, 64*1048576, 0, 'L:\', now(), now()),
             ($TG, 2, 3, 'tempdb', 'templog2', 'LOG', 8*1048576, 1024::bigint * 1048576, 64*1048576, 0, 'L:\', now(), now())" >/dev/null
check "P3d a tempdb log at UNLIMITED (2 TB in sys.master_files) is no max size; one at 1 GB is" \
  "SELECT coalesce(string_agg(object, ', '), 'none') FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $TG AND check_name = 'a tempdb file with a max size'" 'tempdb: templog2'

# ---- P4 every table ----------------------------------------------------------------------------------------------------
tables_check() {  # $1 label, $2 count of heaps
  local graph=1; [[ $MAJOR -lt 14 ]] && graph=0
  mkdb pgvst >/dev/null
  SQ_TIMEOUT=900 sq "DECLARE @i int = 1; DECLARE @t nvarchar(200); WHILE @i <= $2 BEGIN SET @t = N'CREATE TABLE dbo.h' + RIGHT('0000' + CAST(@i AS nvarchar(5)), 4) + N' (id int, v varchar(20))'; EXEC (@t); SET @i += 1; END;
CREATE TABLE dbo.pg1 (id int PRIMARY KEY, v char(100)) WITH (DATA_COMPRESSION = PAGE);
CREATE TABLE dbo.rw1 (id int PRIMARY KEY, v char(100)) WITH (DATA_COMPRESSION = ROW);
CREATE TABLE dbo.cs1 (id int, v int); CREATE CLUSTERED COLUMNSTORE INDEX ccs ON dbo.cs1;
CREATE PARTITION FUNCTION pf_sd (int) AS RANGE LEFT FOR VALUES (100); CREATE PARTITION SCHEME ps_sd AS PARTITION pf_sd ALL TO ([PRIMARY]);
CREATE TABLE dbo.pt1 (id int NOT NULL, v char(10)) ON ps_sd (id); CREATE CLUSTERED INDEX cx ON dbo.pt1 (id) ON ps_sd (id);
ALTER INDEX cx ON dbo.pt1 REBUILD PARTITION = 1 WITH (DATA_COMPRESSION = ROW); ALTER INDEX cx ON dbo.pt1 REBUILD PARTITION = 2 WITH (DATA_COMPRESSION = PAGE);
CREATE TABLE dbo.tv1 (id int PRIMARY KEY, v int, vf datetime2 GENERATED ALWAYS AS ROW START, vt datetime2 GENERATED ALWAYS AS ROW END, PERIOD FOR SYSTEM_TIME (vf, vt)) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.tv1_history));
INSERT dbo.pg1 SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'p' FROM sys.all_objects;" pgvst >/dev/null || bad "$1 P4 tables"
  sq "ALTER DATABASE pgvst ADD FILEGROUP mo CONTAINS MEMORY_OPTIMIZED_DATA; ALTER DATABASE pgvst ADD FILE (NAME = 'pgvst_mo', FILENAME = '/var/opt/mssql/data/pgvst_mo') TO FILEGROUP mo;" >/dev/null &&
    sq "CREATE TABLE dbo.mo1 (id int PRIMARY KEY NONCLUSTERED, v char(100)) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA); INSERT dbo.mo1 SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'm' FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvst >/dev/null || bad "$1 P4 memory-optimized"
  [[ $graph == 1 ]] && { sq "CREATE TABLE dbo.nd1 (id int) AS NODE; CREATE TABLE dbo.ed1 AS EDGE;" pgvst >/dev/null || bad "$1 P4 graph"; }
  # a table with a primary XML index: its internal table counts with it, as sp_spaceused counts it
  sqv "$1 P4 setup: the XML table" "CREATE TABLE dbo.x1 (id int PRIMARY KEY, doc xml);
INSERT dbo.x1 SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), CAST(N'<a><b>' + REPLICATE(N'x', 300) + N'</b><c>1</c></a>' AS xml) FROM sys.all_objects a CROSS JOIN sys.all_objects b;
CREATE PRIMARY XML INDEX px1 ON dbo.x1 (doc);" pgvst
  hold_temp 800 30; sleep 8
  collect mssql_tables || bad "$1 P4 collect"
  wait "$HOLD_PID" 2>/dev/null
  # the hand read: every user table, its type and its partitions' compression
  sq "SELECT s.name + '.' + t.name, CASE WHEN t.is_memory_optimized = 1 THEN 'memory-optimized' WHEN i.type = 5 THEN 'clustered columnstore' WHEN i.type = 1 THEN 'clustered' ELSE 'heap' END,
  (SELECT CAST(COUNT(*) AS varchar(5)) + ':' + p.data_compression_desc + ';' FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1) GROUP BY p.data_compression_desc ORDER BY MIN(p.data_compression) FOR XML PATH(''))
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id LEFT JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id IN (0, 1)
WHERE t.is_ms_shipped = 0 ORDER BY 1" pgvst > "$TMPD/hand.txt"
  pq "SELECT schema_name || '.' || table_name || '|' || table_type || '|' || coalesce(compression, '') FROM pgvigil.mssql_tables WHERE instance_id = $IID AND database_name = 'pgvst' AND is_present ORDER BY 1" > "$TMPD/got.txt"
  python3 - "$TMPD/hand.txt" "$TMPD/got.txt" <<'PY' && ok "$1 P4 every table, its type and compression = the hand read ($(wc -l < "$TMPD/got.txt") tables)" || bad "$1 P4 tables differ from the hand read"
import sys
order = ['NONE', 'ROW', 'PAGE', 'COLUMNSTORE', 'COLUMNSTORE_ARCHIVE']
hand = {}
for line in open(sys.argv[1]):
    f = line.rstrip('\n').split('|')
    if len(f) < 3 or not f[0]: continue
    parts = [p for p in f[2].split(';') if p]
    counts = {p.split(':')[1]: int(p.split(':')[0]) for p in parts}
    if not counts: comp = ''
    elif len(counts) == 1: comp = list(counts)[0]
    else: comp = 'mixed: ' + ', '.join('%s %d' % (k, counts[k]) for k in order if k in counts)
    hand[f[0]] = (f[1], comp)
got = {}
for line in open(sys.argv[2]):
    f = line.rstrip('\n').split('|')
    if len(f) == 3: got[f[0]] = (f[1], f[2])
bad = sorted(set(hand) ^ set(got)) + sorted(k for k in hand if k in got and hand[k] != got[k])
for k in bad[:10]: print('     differs:', k, hand.get(k), got.get(k))
sys.exit(1 if bad else 0)
PY
  check "$1 P4 'mixed: ROW 1, PAGE 1' on the two-partition table" "SELECT compression FROM pgvigil.mssql_tables WHERE instance_id = $IID AND database_name = 'pgvst' AND table_name = 'pt1'" 'mixed: ROW 1, PAGE 1'
  check "$1 P4 the memory-optimized table's size from its memory" "SELECT table_type || ' ' || (used_kb > 0) FROM pgvigil.mssql_tables WHERE instance_id = $IID AND database_name = 'pgvst' AND table_name = 'mo1'" 'memory-optimized true'
  [[ $graph == 1 ]] && check "$1 P4 node and edge" "SELECT string_agg(table_name || ':' || graph, ' ' ORDER BY table_name) FROM pgvigil.mssql_tables WHERE instance_id = $IID AND graph IS NOT NULL" 'ed1:edge nd1:node'
  check "$1 P4 temporal pair" "SELECT string_agg(table_name || ':' || temporal, ' ' ORDER BY table_name) FROM pgvigil.mssql_tables WHERE instance_id = $IID AND temporal IS NOT NULL" 'tv1:system-versioned tv1_history:history table'
  check "$1 P4 tempdb and model never read" "SELECT count(*) FROM pgvigil.mssql_tables WHERE instance_id = $IID AND database_name IN ('tempdb', 'model')" 0
  check "$1 P4 tempdb and model have no read marker either" "SELECT count(*) FROM pgvigil.mssql_tables_db_read WHERE instance_id = $IID AND database_name IN ('tempdb', 'model')" 0
  local sx gx
  sx=$(sq "EXEC sp_spaceused N'dbo.x1'" pgvst | python3 -c '
import sys
f = sys.stdin.read().strip().splitlines()[-1].split("|")   # name|rows|reserved|data|index_size|unused
kb = lambda s: s.strip().split()[0]
print(f[1].strip(), kb(f[2]), kb(f[3]), kb(f[4]), kb(f[5]))')
  gx=$(pq "SELECT row_count || ' ' || reserved_kb || ' ' || data_kb || ' ' || index_kb || ' ' || (reserved_kb - used_kb) FROM pgvigil.mssql_tables WHERE instance_id = $IID AND database_name = 'pgvst' AND table_name = 'x1'")
  eqv "$1 P4 a table with an XML index: rows, reserved, data, index, unused (KB) = sp_spaceused" "$gx" "$sx"
  check "$1 P4 the pass stores where the next one starts (a whole pass: the first database again)" "SELECT last_seq FROM pgvigil.mssql_cursor WHERE instance_id = $IID AND source = 'mssql_tables'" 0
  local t2 t3
  sleep 1; collect mssql_tables; t2=$(pq "SELECT max(read_at) FROM pgvigil.mssql_tables_db_read WHERE instance_id = $IID")
  check "$1 P4 a read with nothing changed stores no sample" "SELECT count(*) FROM pgvigil.mssql_table_sample WHERE instance_id = $IID AND database_name = 'pgvst' AND snapshot_at = '$t2'" 0
  sq "INSERT dbo.h0001 VALUES (1, 'a'); INSERT dbo.h0002 VALUES (1, 'a'); INSERT dbo.rw1 VALUES (1, 'r');" pgvst >/dev/null
  sleep 1; collect mssql_tables; t3=$(pq "SELECT max(read_at) FROM pgvigil.mssql_tables_db_read WHERE instance_id = $IID")
  check "$1 P4 three tables changed: three samples" "SELECT string_agg(table_name, ' ' ORDER BY table_name) FROM pgvigil.mssql_table_sample WHERE instance_id = $IID AND database_name = 'pgvst' AND snapshot_at = '$t3'" 'h0001 h0002 rw1'
  sq "DROP TABLE dbo.h0003;" pgvst >/dev/null; collect mssql_tables
  check "$1 P4 a dropped table is marked gone" "SELECT is_present FROM pgvigil.mssql_tables WHERE instance_id = $IID AND database_name = 'pgvst' AND table_name = 'h0003'" f
}
echo "== P4: every table"
tables_check "${IMAGES[0]}" 1190
GI=$(pq "SELECT pgvigil.ensure_instance('gr-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "SELECT pgvigil.ensure_month_partition('mssql_table_sample', now() - interval '8 days'); SELECT pgvigil.ensure_month_partition('mssql_table_sample', now());
INSERT INTO pgvigil.mssql_tables_db_read (instance_id, database_name, read_at, read_ok, first_read_at, ok_at) VALUES
  ($GI, 'd1', now(), true, now() - interval '20 days', now()), ($GI, 'dnot', now(), false, now() - interval '20 days', now() - interval '3 days'),
  ($GI, 'dnew', now(), true, now() - interval '1 day', now());
INSERT INTO pgvigil.mssql_tables (instance_id, database_name, schema_name, table_name, row_count, used_kb, reserved_kb, snapshot_at, first_seen, changed_at) VALUES
  ($GI, 'd1', 'dbo', 'grown', 30, 300, 320, now(), now() - interval '20 days', now() - interval '1 day'),
  ($GI, 'd1', 'dbo', 'still', 10, 100, 100, now(), now() - interval '20 days', now() - interval '10 days'),
  ($GI, 'd1', 'dbo', 'unknown', 10, 100, 100, now(), now() - interval '20 days', now() - interval '2 days'),
  ($GI, 'dnot', 'dbo', 'x', 10, 100, 100, now(), now() - interval '20 days', now() - interval '10 days'),
  ($GI, 'dnew', 'dbo', 'y', 10, 100, 100, now(), now() - interval '1 day', now() - interval '1 day'),
  ($GI, 'd1', 'dbo', 'fresh', 5, 50, 64, now(), now() - interval '3 days', now() - interval '3 days');
INSERT INTO pgvigil.mssql_table_sample (instance_id, snapshot_at, database_name, schema_name, table_name, row_count, used_kb) VALUES
  ($GI, now() - interval '8 days', 'd1', 'dbo', 'grown', 10, 100), ($GI, now() - interval '1 day', 'd1', 'dbo', 'grown', 30, 300),
  ($GI, now() - interval '2 days', 'd1', 'dbo', 'unknown', 10, 100), ($GI, now() - interval '3 days', 'd1', 'dbo', 'fresh', 5, 50);" >/dev/null || bad "P4 growth rows"
check "P4 growth over 7 days: fresh (new 3 days ago) +50 KB from 0, grown +200 KB, still 0; unknown, dnot and dnew left out" \
  "SELECT string_agg(table_name || ':' || used_kb_grown, ' ' ORDER BY table_name) FROM pgvigil.mssql_table_growth($GI, 7)" 'fresh:50 grown:200 still:0'
check "P4 growth of one database only (p_db)" "SELECT count(*) FROM pgvigil.mssql_table_growth($GI, 7, 'dnot')" 0
check "P4 the series of a table unchanged for 10 days with no sample: flat from the window's start" \
  "SELECT count(*) || ' ' || min(used_kb) || ' ' || max(used_kb) FROM pgvigil.mssql_table_series($GI, 'd1', 'dbo', 'still', now() - interval '7 days', now())" '2 100 100'
# P4b (rows through the import): one run in two imports at one snapshot - neither undoes the other; only the database
# list removes a database the server no longer lists; the next start is stored
BI=$(pq "SELECT pgvigil.ensure_instance('bt-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
tpart() { printf '{"kind":"table","database_name":"%s","schema_name":"dbo","table_name":"%s","row_count":%d,"reserved_kb":%d,"used_kb":%d,"data_kb":%d,"index_kb":0},{"kind":"dbread","database_name":"%s","read":1}' "$1" "$2" "$3" "$4" "$4" "$4" "$1"; }
BS=$(pq "SELECT now() - interval '1 hour'")
pq "SELECT pgvigil.import_mssql_tables($BI, '$BS', '[$(tpart dba ta 1 8)]')" >/dev/null || bad "P4b import 1"
pq "SELECT pgvigil.import_mssql_tables($BI, '$BS', '[$(tpart dbb tb 1 8),{\"kind\":\"dblist\",\"names\":[\"dba\",\"dbb\"]},{\"kind\":\"cursor\",\"source\":\"mssql_tables\",\"last_seq\":1}]')" >/dev/null || bad "P4b import 2"
check "P4b two imports of one run: both tables and both samples kept" \
  "SELECT (SELECT string_agg(table_name, ' ' ORDER BY table_name) FROM pgvigil.mssql_tables WHERE instance_id = $BI AND is_present) || ' ' || (SELECT count(*) FROM pgvigil.mssql_table_sample WHERE instance_id = $BI AND snapshot_at = '$BS')" 'ta tb 2'
pq "SELECT pgvigil.import_mssql_tables($BI, now(), '[$(tpart dba ta 1 8),{\"kind\":\"dblist\",\"names\":[\"dba\"]},{\"kind\":\"cursor\",\"source\":\"mssql_tables\",\"last_seq\":0}]')" >/dev/null || bad "P4b import 3"
check "P4b a database the list no longer names: its tables gone, its marker removed; the cursor stored" \
  "SELECT (SELECT string_agg(table_name || ':' || is_present, ' ' ORDER BY table_name) FROM pgvigil.mssql_tables WHERE instance_id = $BI) || ' ' || (SELECT string_agg(database_name, ' ') FROM pgvigil.mssql_tables_db_read WHERE instance_id = $BI) || ' ' || (SELECT last_seq FROM pgvigil.mssql_cursor WHERE instance_id = $BI AND source = 'mssql_tables')" 'ta:true tb:false dba 0'
pq "UPDATE pgvigil.mssql_tables SET snapshot_at = now() - interval '40 days' WHERE instance_id = $IID AND table_name = 'h0003'" >/dev/null
# purge() and the read in two statements: one statement reads one snapshot, taken before purge's DELETE
check "P4 purge() deletes at least the gone table" "SELECT pgvigil.purge(30) >= 1" t
check "P4 purge() removes a table gone past the retention" "SELECT NOT EXISTS (SELECT 1 FROM pgvigil.mssql_tables WHERE instance_id = $IID AND table_name = 'h0003')" t

# ---- P5 IO per database -----------------------------------------------------------------------------------------------
io_check() {  # $1 label
  mkdb pgvio1 >/dev/null; mkdb pgvio2 >/dev/null
  sq "CREATE TABLE dbo.t (id int IDENTITY PRIMARY KEY, pad char(4000));" pgvio1 >/dev/null; sq "CREATE TABLE dbo.t (id int IDENTITY PRIMARY KEY, pad char(4000));" pgvio2 >/dev/null
  local hq="SELECT DB_NAME(database_id) + ' ' + CAST(SUM(num_of_reads) AS varchar(20)) + ' ' + CAST(SUM(num_of_bytes_read) AS varchar(20)) + ' ' + CAST(SUM(num_of_writes) AS varchar(20)) + ' ' + CAST(SUM(num_of_bytes_written) AS varchar(20)) + ' ' + CAST(SUM(io_stall_read_ms) AS varchar(20)) + ' ' + CAST(SUM(io_stall_write_ms) AS varchar(20)) FROM sys.dm_io_virtual_file_stats(NULL, NULL) WHERE DB_NAME(database_id) IN ('pgvio1', 'pgvio2') GROUP BY database_id ORDER BY 1"
  collect mssql_fileio || bad "$1 P5 read 1"; local h1 h2 t1 t2
  h1=$(sq "$hq"); t1=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_fileio_last WHERE instance_id = $IID")
  sq "INSERT dbo.t (pad) SELECT TOP (3000) 'a' FROM sys.all_objects a CROSS JOIN sys.all_objects b; CHECKPOINT; DBCC DROPCLEANBUFFERS; SELECT COUNT(*) FROM dbo.t WITH (INDEX(1));" pgvio1 >/dev/null
  sq "INSERT dbo.t (pad) SELECT TOP (1000) 'b' FROM sys.all_objects a CROSS JOIN sys.all_objects b; CHECKPOINT;" pgvio2 >/dev/null
  sleep 50
  collect mssql_fileio || bad "$1 P5 read 2"
  h2=$(sq "$hq"); t2=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_fileio_last WHERE instance_id = $IID")
  local hand got
  hand=$(python3 -c '
import sys
a = {l.split()[0]: list(map(int, l.split()[1:])) for l in sys.argv[1].splitlines() if l.strip()}
b = {l.split()[0]: list(map(int, l.split()[1:])) for l in sys.argv[2].splitlines() if l.strip()}
for k in sorted(b):
    d = [y - x for x, y in zip(a.get(k, [0]*6), b[k])]
    print(k, *d[:6], end=" ")' "$h1" "$h2")
  got=$(pq "SELECT string_agg(name || ' ' || reads || ' ' || read_bytes || ' ' || writes || ' ' || write_bytes || ' ' || read_stall_ms || ' ' || write_stall_ms, ' ' ORDER BY name) || ' ' FROM pgvigil.mssql_io_totals($IID, '$t1', '$t2', 'database') WHERE name IN ('pgvio1', 'pgvio2')")
  eqv "$1 P5 reads, bytes read, writes, bytes written, read and write stall per database = the hand diff" "$got" "$hand"
  check "$1 P5 latency = stall / operations" "SELECT bool_and(read_latency_ms IS NOT DISTINCT FROM round(read_stall_ms::numeric / nullif(reads, 0), 2) AND write_latency_ms IS NOT DISTINCT FROM round(write_stall_ms::numeric / nullif(writes, 0), 2)) FROM pgvigil.mssql_io_totals($IID, '$t1', '$t2', 'database')" t
  check "$1 P5 the IOs pending stored at each read" "SELECT count(*) > 0 AND bool_and(pending_ios IS NOT NULL) FROM pgvigil.mssql_fileio_read WHERE instance_id = $IID AND snapshot_at >= '$t1'" t
}
echo "== P5: IO per database"
io_check "${IMAGES[0]}"
IC=$(pq "SELECT pgvigil.ensure_instance('io-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "SELECT pgvigil.ensure_month_partition('mssql_fileio_sample', now() - interval '1 day'); SELECT pgvigil.ensure_month_partition('mssql_fileio_read', now() - interval '1 day');
SELECT pgvigil.ensure_month_partition('mssql_fileio_sample', now()); SELECT pgvigil.ensure_month_partition('mssql_fileio_read', now());
INSERT INTO pgvigil.mssql_fileio_read (instance_id, snapshot_at, interval_secs, files) SELECT $IC, now() - interval '1 day' - make_interval(mins => m), 60, 1 FROM generate_series(1, 30) m;
INSERT INTO pgvigil.mssql_fileio_read (instance_id, snapshot_at, interval_secs, files) SELECT $IC, now() - make_interval(mins => m), 60, 1 FROM generate_series(1, 30) m;
INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
  SELECT $IC, now() - interval '1 day' - make_interval(mins => m), 5, 1, 'appdb', 10, 1048576, 50, 0, 0, 0, 60 FROM generate_series(1, 30) m;
INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
  SELECT $IC, now() - make_interval(mins => m), 5, 1, 'appdb', 20, 2097152, 400, 0, 0, 0, 60 FROM generate_series(1, 30) m;" >/dev/null || bad "P5 compare rows"
check "P5 compare: 2 MB/s now (1/60 x 2 MB) against 1 MB/s a day before; latency 20 ms against 5 ms" \
  "SELECT name || ' ' || mb_s || ' ' || mb_s_before || ' ' || read_latency_ms || ' ' || read_latency_ms_before FROM pgvigil.mssql_io_compare($IC, now() - interval '31 minutes', now(), interval '1 day', 'database')" \
  'appdb 0.033 0.017 20.00 5.00'
# a database id given to another database on another volume: the old IO stays on its volume
VI=$(pq "SELECT pgvigil.ensure_instance('vk-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
fio_payload() {  # $1 server_utc offset seconds, $2 database name, $3 reads
  printf '[{"kind":"state","server_utc":"%s","server_start":"2026-01-01T00:00:00Z"},{"kind":"file","database_id":7,"file_id":1,"database_name":"%s","file_name":"f","type_desc":"ROWS","physical_name":"x","reads":%d,"read_bytes":%d,"read_stall_ms":%d,"writes":0,"write_bytes":0,"write_stall_ms":0,"read_queued_ms":0,"write_queued_ms":0,"pending_ios":0,"pending_in_os":0},{"kind":"pending","read":1}]' \
    "$(date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$(( $3 * 8192 ))" "$3"
}
pq "INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, type_desc, size_bytes, volume, snapshot_at, first_seen) VALUES ($VI, 7, 1, 'olddb', 'ROWS', 1, 'E:\', now(), now())" >/dev/null
pq "SELECT pgvigil.import_mssql_fileio($VI, now() - interval '3 minutes', '$(fio_payload -180 olddb 100)')" >/dev/null
pq "SELECT pgvigil.import_mssql_fileio($VI, now() - interval '2 minutes', '$(fio_payload -120 olddb 200)')" >/dev/null || bad "P5 import (old)"
pq "UPDATE pgvigil.mssql_files SET database_name = 'newdb', volume = 'F:\' WHERE instance_id = $VI" >/dev/null
pq "SELECT pgvigil.import_mssql_fileio($VI, now() - interval '1 minute', '$(fio_payload -60 newdb 260)')" >/dev/null || bad "P5 import (new)"
check "P5 by volume: the old database's IO on E:, the new one's on F:" \
  "SELECT string_agg(name || ':' || reads, ' ' ORDER BY name) FROM pgvigil.mssql_io_totals($VI, now() - interval '10 minutes', now(), 'volume')" 'E:\:100 F:\:60'
# the chart's read on 3,000 databases x 60 minutes, in a month's partition that holds 24 hours of them (4.3 million rows,
# the window 4 % of it): the app's two statements as it sends them - the grid's totals (whose first names are the
# series' top 10) and the series with those names as a literal array
EX=$(pq "SELECT pgvigil.ensure_instance('ex-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "INSERT INTO pgvigil.mssql_fileio_read (instance_id, snapshot_at, interval_secs, files) SELECT $EX, now() - make_interval(mins => m), 60, 3000 FROM generate_series(1, 1440) m;
INSERT INTO pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
  SELECT $EX, now() - make_interval(mins => m), d, 1, 'db' || d, 5, 40960 + d, 3, 2, 16384, 1, 60 FROM generate_series(1, 1440) m, generate_series(1, 3000) d; ANALYZE pgvigil.mssql_fileio_sample;" >/dev/null || bad "P5 the month's rows"
TOPN=$(pq "SELECT string_agg(quote_literal(t.name), ',' ORDER BY t.read_bytes + t.write_bytes DESC, t.name) FROM (SELECT * FROM pgvigil.mssql_io_totals($EX, now() - interval '1 hour', now(), 'database') t ORDER BY t.read_bytes + t.write_bytes DESC, t.name LIMIT 10) t")
for form in grid series; do
  case $form in
    grid) sql="SELECT * FROM pgvigil.mssql_io_totals($EX, now() - interval '1 hour', now(), 'database') ORDER BY read_bytes + write_bytes DESC, name" ;;
    series) sql="SELECT io.* FROM pgvigil.mssql_db_io($EX, now() - interval '1 hour', now(), 60, ARRAY[$TOPN]::text[]) io" ;;
  esac
  psql "$PGDSN" -XAtq -c "EXPLAIN (ANALYZE, BUFFERS) $sql" > "$TMPD/explain-$form.txt" 2>&1
  sed 's/^/     plan: /' "$TMPD/explain-$form.txt" | grep -E 'Scan|Execution|Sort Method|rows=' | head -12
  ms=$(grep -oE 'Execution Time: [0-9.]+' "$TMPD/explain-$form.txt" | grep -oE '[0-9.]+$')
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2000 else 1)' "${ms:-99999}" && ok "P5 the $form read of one hour of 3,000 databases: ${ms} ms" || bad "P5 the $form read: ${ms:-no time} ms"
  grep -qE '(Index|Bitmap Index|Bitmap Heap) Scan .*mssql_fileio_sample_[0-9]+' "$TMPD/explain-$form.txt" \
    && ok "P5 the $form read takes the hour through the partition's index" || bad "P5 the $form read scans the month's partition whole"
done

# ---- P6 the queued stall ------------------------------------------------------------------------------------------------
echo "== P6: the queued stall"
mkdb pgvrg >/dev/null
if sq "CREATE LOGIN [$RGL] WITH PASSWORD = '$RG_PW', CHECK_POLICY = OFF; CREATE RESOURCE POOL pgv_rg_pool WITH (MIN_IOPS_PER_VOLUME = 1, MAX_IOPS_PER_VOLUME = 20);
CREATE WORKLOAD GROUP pgv_rg_group USING pgv_rg_pool;" >"$TMPD/rg.err" 2>&1 &&
   sq "GO
CREATE FUNCTION dbo.pgv_rg_classify() RETURNS sysname WITH SCHEMABINDING AS BEGIN RETURN CASE WHEN SUSER_SNAME() = N'$RGL' THEN N'pgv_rg_group' ELSE N'default' END END;" >>"$TMPD/rg.err" 2>&1 &&
   sq "ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.pgv_rg_classify); ALTER RESOURCE GOVERNOR RECONFIGURE;" >>"$TMPD/rg.err" 2>&1; then
  sq "CREATE USER [$RGL] FOR LOGIN [$RGL]; ALTER ROLE db_owner ADD MEMBER [$RGL]; CREATE TABLE dbo.t (id int IDENTITY PRIMARY KEY, pad char(4000)); INSERT dbo.t (pad) SELECT TOP (20000) 'q' FROM sys.all_objects a CROSS JOIN sys.all_objects b; CHECKPOINT;" pgvrg >/dev/null
  qsum="SELECT SUM(io_stall_queued_read_ms) FROM sys.dm_io_virtual_file_stats(DB_ID('pgvrg'), NULL)"
  collect mssql_fileio; q1=$(sq "$qsum"); t6a=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_fileio_last WHERE instance_id = $IID")
  printf 'SET NOCOUNT ON; DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS; SELECT COUNT_BIG(*) FROM dbo.t WITH (INDEX(1)) OPTION (MAXDOP 1);\n' |
    docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c "SQLCMDPASSWORD=\$RG_PW $SQLCMD -S localhost -U $RGL -C -d pgvrg -i /dev/stdin" >/dev/null 2>&1
  sq "DBCC DROPCLEANBUFFERS WITH NO_INFOMSGS;" >/dev/null
  # the second throttled scan runs in the background: a read during it sees its IOs pending (F4)
  printf 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.t WITH (INDEX(1)) OPTION (MAXDOP 1);\n' |
    docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c "SQLCMDPASSWORD=\$RG_PW $SQLCMD -S localhost -U $RGL -C -d pgvrg -i /dev/stdin" >/dev/null 2>&1 &
  SCAN=$!; BG+=($SCAN); sleep 4
  collect mssql_fileio
  pend=$(pq "SELECT pending_ios || ' ' || (SELECT coalesce(sum(l.pending_ios), 0) FROM pgvigil.mssql_fileio_last l WHERE l.instance_id = $IID AND l.database_name = 'pgvrg') FROM pgvigil.mssql_fileio_read WHERE instance_id = $IID ORDER BY snapshot_at DESC LIMIT 1")
  wait "$SCAN" 2>/dev/null
  if [[ "${pend%% *}" -gt 0 ]]; then
    eqv "P6 IOs pending during the throttled scan ($pend: the read's total, then pgvrg's files): pgvrg's files hold them, matched by handle" \
      "$(awk '{print ($2 > 0 && $2 <= $1) ? "matched" : "not matched"}' <<<"$pend")" matched
  else
    np "P6 IOs pending: none was pending at the read during the throttled scan ($pend); the handle match is the Go test's"
  fi
  hq=$(sq "$qsum")
  collect mssql_fileio; q2=$(sq "$qsum"); t6b=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_fileio_last WHERE instance_id = $IID")
  if [[ "${hq:-0}" -gt 0 ]]; then
    check "P6 the queued read stall stored between the two reads = the server's delta ($q1 -> $q2 ms)" \
      "SELECT coalesce(sum(read_queued_ms), 0) FROM pgvigil.mssql_fileio_sample WHERE instance_id = $IID AND database_name = 'pgvrg' AND snapshot_at > '$t6a' AND snapshot_at <= '$t6b'" "$(( q2 - q1 ))"
  else
    np "P6: the server counted no queued read stall for the pool's reads on this container (io_stall_queued_read_ms 0 by the hand read): stored 0 as read"
  fi
  sq "ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL); ALTER RESOURCE GOVERNOR RECONFIGURE;" >/dev/null
else
  np "P6: the resource pool could not be made: $(head -c 300 "$TMPD/rg.err" | tr '\n' ' ')"
fi
np "P7: Write Transactions/sec, Percent Log Used and Active Transactions per database are 401's mssql_counters_db: proven with 401's join"

# ---- P8 the rules -------------------------------------------------------------------------------------------------------
echo "== P8: the rules"
finding() { pq "SELECT coalesce(string_agg(severity || ' ' || object, ', ' ORDER BY object), 'none') FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = ${2:-$IID} AND check_name = '$1'"; }
rules_logs_orphans() {  # $1 label: the two-log and orphan rows (also the version run's)
  mkdb pgvchk >/dev/null
  sq "ALTER DATABASE pgvchk ADD LOG FILE (NAME = 'pgvchk_log2', FILENAME = '/var/opt/mssql/data/pgvchk_log2.ldf', SIZE = 8MB);" >/dev/null
  collect mssql_storage
  eqv "$1 P8 two log files" "$(finding 'more than one log file')" 'warning pgvchk'
  sq "ALTER DATABASE pgvchk REMOVE FILE pgvchk_log2;" >/dev/null; collect mssql_storage
  eqv "$1 P8 one log file again: clear" "$(finding 'more than one log file')" none
  mkdb pgvorph >/dev/null
  sq "ALTER DATABASE pgvorph SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC sp_detach_db 'pgvorph';" >/dev/null || bad "$1 P8 detach"
  collect mssql_storage_depth
  eqv "$1 P8 a detached database's two files are orphans" "$(finding 'an orphaned database file' | sed 's|/var/opt/mssql/data/||g')" 'warning pgvorph.mdf, warning pgvorph_log.ldf'
  [[ -n "$SRV_PID" ]] && summary_check "$1 P8 orphans live ($(live_count 'an orphaned database file'))"
  OI=$(pq "SELECT pgvigil.ensure_instance('or-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
  pq "INSERT INTO pgvigil.mssql_storage_paths (instance_id, snapshot_at, host_platform, machine_name) SELECT $OI, now(), 'Linux', machine_name FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID ON CONFLICT (instance_id) DO UPDATE SET machine_name = EXCLUDED.machine_name" >/dev/null
  eqv "$1 P8 a second instance known on the host: info" "$(finding 'an orphaned database file' | sed 's|/var/opt/mssql/data/||g')" 'info pgvorph.mdf, info pgvorph_log.ldf'
  pq "DELETE FROM pgvigil.instances WHERE instance_id = $OI" >/dev/null
  sq "CREATE DATABASE pgvorph ON (FILENAME = '/var/opt/mssql/data/pgvorph.mdf'), (FILENAME = '/var/opt/mssql/data/pgvorph_log.ldf') FOR ATTACH;" >/dev/null || bad "$1 P8 attach"
  collect mssql_storage_depth
  eqv "$1 P8 attached again: no orphan" "$(finding 'an orphaned database file')" none
}
rules_logs_orphans "${IMAGES[0]}"
docker exec "$SQL" bash -c 'mkdir -p /var/opt/mssql/data/pgvsub && head -c 8192 /dev/zero > /var/opt/mssql/data/pgvsub/other.mdf' || bad "P8 the subfolder file"
echo "     the server lists the subfolder's file when asked for the data folder: $(sq "SELECT COUNT(*) FROM sys.dm_os_enumerate_filesystem(N'/var/opt/mssql/data/', N'*') WHERE full_filesystem_path LIKE N'%pgvsub%other.mdf'") row(s)"
collect mssql_storage_depth
eqv "P8 a .mdf in a subfolder of the data folder is not this instance's orphan (every folder listed)" \
  "$(pq "SELECT orphans_read::text FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID") $(finding 'an orphaned database file')" 'true none'
docker exec "$SQL" rm -rf /var/opt/mssql/data/pgvsub
TP=$(sq "SELECT TOP (1) physical_name FROM tempdb.sys.database_files WHERE type = 0 ORDER BY file_id")
TF=$(sq "SELECT TOP (1) name FROM tempdb.sys.database_files WHERE type = 0 ORDER BY file_id")
check "P8 tempdb's paths kept from the first read after the server's start: its start stored, the running data file among them" \
  "SELECT (tempdb_paths_start IS NOT NULL) || ' ' || ('$TP' = ANY(tempdb_paths)) FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID" 'true true'
pq "UPDATE pgvigil.mssql_storage_paths SET tempdb_paths_start = '2000-01-01', tempdb_paths = '{/x/old/tempdb.mdf}' WHERE instance_id = $IID" >/dev/null || bad "P8 an older start written"
collect mssql_storage_depth
check "P8 a new server start (an older one stored): tempdb's paths taken again from this read, the old ones gone" \
  "SELECT (tempdb_paths_start <> '2000-01-01') || ' ' || ('$TP' = ANY(tempdb_paths)) || ' ' || ('/x/old/tempdb.mdf' = ANY(tempdb_paths)) FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID" 'true true false'
docker exec "$SQL" mkdir -p /var/opt/mssql/data/pgvmoved || bad "P8 the move's folder"
sqv "P8 setup: tempdb moved, not yet restarted" "ALTER DATABASE tempdb MODIFY FILE (NAME = [$TF], FILENAME = '/var/opt/mssql/data/pgvmoved/tempdb_moved.mdf');"
collect mssql_storage_depth
eqv "P8 tempdb moved before its restart: every folder listed, the files it runs on not orphans" \
  "$(pq "SELECT orphans_read::text FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID") $(finding 'an orphaned database file')" 'true none'
pq "UPDATE pgvigil.mssql_storage_paths SET tempdb_paths = NULL, tempdb_paths_start = NULL WHERE instance_id = $IID" >/dev/null || bad "P8 the kept paths wiped"
collect mssql_storage_depth
check "P8 a move made before pgvigil's first read after the start: tempdb's running file is info, 'a tempdb file move may be pending', never a plain orphan" \
  "SELECT coalesce(string_agg(severity || ' ' || object || ' ' || (detail LIKE '%a tempdb file move may be pending (the files run until the restart)%'), ', ' ORDER BY object), 'none') FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = 'an orphaned database file'" "info $TP true"
sqv "P8 setup: tempdb's move undone" "ALTER DATABASE tempdb MODIFY FILE (NAME = [$TF], FILENAME = '$TP');"
docker exec "$SQL" bash -c "head -c 8192 /dev/zero > /var/opt/mssql/data/tempdb_left.mdf && touch -d '2020-01-01 00:00:00' /var/opt/mssql/data/tempdb_left.mdf" || bad "P8 the left file"
collect mssql_storage_depth
check "P8 a tempdb-named file not written since the server's start (a finished move's leftover): a plain orphan" \
  "SELECT coalesce(string_agg(severity || ' ' || object || ' ' || (detail LIKE '%a tempdb file move may be pending%'), ', ' ORDER BY object), 'none') FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = 'an orphaned database file'" 'warning /var/opt/mssql/data/tempdb_left.mdf false'
docker exec "$SQL" rm -f /var/opt/mssql/data/tempdb_left.mdf
docker exec "$SQL" mkdir -p /var/opt/mssql/data/pgvimofs || bad "P8 the container's folder"
sqv "P8 setup: a memory-optimized container alone in its folder" "CREATE DATABASE pgvimo ON PRIMARY (NAME = 'pgvimo', FILENAME = '/var/opt/mssql/data/pgvimo.mdf'), FILEGROUP pgvimo_fg CONTAINS MEMORY_OPTIMIZED_DATA (NAME = 'pgvimo_c', FILENAME = '/var/opt/mssql/data/pgvimofs/c1') LOG ON (NAME = 'pgvimo_log', FILENAME = '/var/opt/mssql/data/pgvimo_log.ldf');"
collect mssql_storage_depth
check "P8 a folder holding only a memory-optimized container (a directory): the orphans read" \
  "SELECT orphans_read || ' ' || coalesce(orphans_note, 'no note') FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID" 'true no note'
sqv "P8 setup: pgvimo dropped" "DROP DATABASE pgvimo;"
docker exec "$SQL" mkdir -p /var/opt/mssql/data/pgvlock || bad "P8 the lock folder"
sqv "P8 setup: a database in its own folder" "CREATE DATABASE pgvlk ON (NAME = 'pgvlk', FILENAME = '/var/opt/mssql/data/pgvlock/pgvlk.mdf') LOG ON (NAME = 'pgvlk_log', FILENAME = '/var/opt/mssql/data/pgvlock/pgvlk_log.ldf');"
sqv "P8 setup: pgvorph detached again" "ALTER DATABASE pgvorph SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC sp_detach_db 'pgvorph';"
collect mssql_storage_depth
before=$(finding 'an orphaned database file')
docker exec -u 0 "$SQL" chmod 000 /var/opt/mssql/data/pgvlock || bad "P8 the folder locked"
collect mssql_storage_depth
check "P8 a folder that cannot be listed: the orphans not read this run, the note naming the folder" \
  "SELECT orphans_read || ' ' || (orphans_note LIKE '%pgvlock%') FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID" 'false true'
eqv "P8 ... and the stored list kept as it was ($before)" "$(finding 'an orphaned database file')" "$before"
docker exec -u 0 "$SQL" chmod 755 /var/opt/mssql/data/pgvlock
sqv "P8 setup: pgvorph attached again" "CREATE DATABASE pgvorph ON (FILENAME = '/var/opt/mssql/data/pgvorph.mdf'), (FILENAME = '/var/opt/mssql/data/pgvorph_log.ldf') FOR ATTACH;"
sqv "P8 setup: pgvlk dropped" "DROP DATABASE pgvlk;"
sqv "P8 setup: pgvful" "CREATE DATABASE pgvful ON (NAME = 'pgvful', FILENAME = '/var/opt/mssql/data/pgvful.mdf', SIZE = 8MB, FILEGROWTH = 1MB);"
sqv "P8 setup: pgvful's table" "CREATE USER [$MON] FOR LOGIN [$MON]; CREATE TABLE dbo.t (pad char(8000)); INSERT dbo.t SELECT TOP (760) 'f' FROM sys.all_objects;" pgvful
sqv "P8 setup: filegroup fg2" "ALTER DATABASE pgvful ADD FILEGROUP fg2;"
sqv "P8 setup: fg2's two files" "ALTER DATABASE pgvful ADD FILE (NAME = 'fg2a', FILENAME = '/var/opt/mssql/data/pgvful_fg2a.ndf', SIZE = 8MB, FILEGROWTH = 64MB), (NAME = 'fg2b', FILENAME = '/var/opt/mssql/data/pgvful_fg2b.ndf', SIZE = 16MB, FILEGROWTH = 64MB) TO FILEGROUP fg2;"
sqv "P8 setup: model by per cent" "ALTER DATABASE model MODIFY FILE (NAME = 'modeldev', FILEGROWTH = 10%);"
TF=$(sq "SELECT TOP (1) name FROM tempdb.sys.database_files WHERE type = 0 ORDER BY file_id")
sqv "P8 setup: a tempdb max size" "DECLARE @t nvarchar(400) = (SELECT TOP (1) N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name) + N', MAXSIZE = 4GB)' FROM tempdb.sys.database_files WHERE type = 0 ORDER BY file_id); EXEC (@t);"
collect mssql_storage
fobj() { pq "SELECT coalesce(string_agg(severity, ','), 'none') FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name = '$1' AND object = '$2'"; }
eqv "P8 a full 8 MB file: info" "$(fobj 'a file under 20 % free inside it' 'pgvful: pgvful')" info
eqv "P8 8 and 16 MB in one filegroup: info" "$(finding "a filegroup''s data files unbalanced")" 'info pgvful: fg2'
eqv "P8 a 1 MB growth step" "$(fobj 'a data file growth step under 64 MB' 'pgvful: pgvful')" warning
eqv "P8 model grows by per cent" "$(finding 'model grows by per cent')" 'warning model: modeldev'
eqv "P8 a tempdb file with a max size: that one file, no other (the log at UNLIMITED is none)" "$(finding 'a tempdb file with a max size')" "warning tempdb: $TF"
summary_check "P8 the file rules live ($(live_count 'a file under 20 % free inside it')/$(live_count 'a filegroup%')/$(live_count 'a data file growth step%')/$(live_count 'model grows by%')/$(live_count 'a tempdb file with a max size'))"
sq "ALTER DATABASE pgvful MODIFY FILE (NAME = 'pgvful', SIZE = 64MB, FILEGROWTH = 64MB); ALTER DATABASE pgvful MODIFY FILE (NAME = 'fg2a', SIZE = 16MB);
ALTER DATABASE model MODIFY FILE (NAME = 'modeldev', FILEGROWTH = 1MB);
DECLARE @t nvarchar(400) = (SELECT TOP (1) N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name) + N', MAXSIZE = UNLIMITED)' FROM tempdb.sys.database_files WHERE type = 0 ORDER BY file_id); EXEC (@t);" >/dev/null || bad "P8 clear setup"
collect mssql_storage
eqv "P8 grown to 64 MB: no file under 20 % free" "$(fobj 'a file under 20 % free inside it' 'pgvful: pgvful')" none
eqv "P8 balanced: clear" "$(finding "a filegroup''s data files unbalanced")" none
eqv "P8 a 64 MB step: clear" "$(fobj 'a data file growth step under 64 MB' 'pgvful: pgvful')" none
eqv "P8 model grows by 1 MB" "$(finding 'model grows by 1 MB')" 'warning model: modeldev'
eqv "P8 no tempdb max size: clear" "$(finding 'a tempdb file with a max size')" none
sq "ALTER DATABASE model MODIFY FILE (NAME = 'modeldev', FILEGROWTH = 64MB);" >/dev/null; collect mssql_storage
eqv "P8 model grows by 64 MB: clear" "$(finding 'model grows by 1 MB')$(finding 'model grows by per cent')" nonenone
sq "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'SMO and DMO XPs', 0; RECONFIGURE;" >/dev/null
collect mssql_storage_depth
check "P8 SMO and DMO XPs 0: the drives and folders not read, and why" "SELECT drives_read || ' ' || orphans_read || ' ' || drives_note FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID" 'false false not read: SMO and DMO XPs is off on this server'
sq "EXEC sp_configure 'SMO and DMO XPs', 1; RECONFIGURE;" >/dev/null; collect mssql_storage_depth
check "P8 SMO and DMO XPs 1: read again" "SELECT drives_read || ' ' || orphans_read FROM pgvigil.mssql_storage_paths WHERE instance_id = $IID" 'true true'
WI=$(pq "SELECT pgvigil.ensure_instance('win-$SUF', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
pq "INSERT INTO pgvigil.mssql_storage_paths (instance_id, snapshot_at, host_platform, machine_name, default_data_path, default_log_path, smo_xps)
  VALUES ($WI, now(), 'Windows', 'WINBOX', 'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\', 'C:\SQLLogs\', 1);
INSERT INTO pgvigil.mssql_files (instance_id, database_id, file_id, database_name, file_name, type_desc, physical_name, size_bytes, growth_bytes, growth_pct, snapshot_at, first_seen)
  VALUES ($WI, 2, 1, 'tempdb', 'tempdev', 'ROWS', 'C:\TempDB\tempdb.mdf', 8388608, 67108864, 0, now(), now());" >/dev/null
check "P8 the C: rules on a Windows instance" "SELECT string_agg(check_name, ', ' ORDER BY check_name) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $WI AND check_name LIKE '%C:%'" \
  'a tempdb file on C:, the default data path on C:, the default log path on C:'
check "P8 none of the C: rules on the Linux container" "SELECT count(*) FROM pgvigil.mssql_storage_depth_findings WHERE instance_id = $IID AND check_name LIKE '%C:%'" 0
summary_check "P8 the C: rules live on the Windows instance ($(live_count '%C:%' "$WI"))" "$WI"
check "P8 no name of 0158's view is one mssql_storage_findings raises (each name looked for as its SQL literal)" \
  "SELECT count(*) FROM unnest(ARRAY['a volume full within 30 days', 'tempdb data files filling', 'more than one log file', 'a file under 20 % free inside it',
     'a filegroup''s data files unbalanced', 'a data file growth step under 64 MB', 'model grows by per cent', 'model grows by 1 MB', 'a tempdb file on C:',
     'a tempdb file with a max size', 'the default data path on C:', 'the default log path on C:', 'an orphaned database file']) n
   WHERE position(quote_literal(n) IN pg_get_viewdef('pgvigil.mssql_storage_findings'::regclass)) > 0" 0

# ---- P9 the log's holder ------------------------------------------------------------------------------------------------
echo "== P9: the log's holder"
sq "CREATE DATABASE pgvlog ON (NAME = 'pgvlog', FILENAME = '/var/opt/mssql/data/pgvlog.mdf', SIZE = 64MB) LOG ON (NAME = 'pgvlog_log', FILENAME = '/var/opt/mssql/data/pgvlog_log.ldf', SIZE = 32MB, FILEGROWTH = 0);
ALTER DATABASE pgvlog SET RECOVERY SIMPLE; CREATE LOGIN [$HOLDER] WITH PASSWORD = '$HOLD_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$HOLDER];" >/dev/null || bad "P9 setup"
sq "CREATE USER [$MON] FOR LOGIN [$MON]; CREATE USER [$HOLDER] FOR LOGIN [$HOLDER]; ALTER ROLE db_owner ADD MEMBER [$HOLDER]; CREATE TABLE dbo.t (pad char(4000));" pgvlog >/dev/null
printf 'SET NOCOUNT ON; BEGIN TRAN; WHILE (SELECT used_log_space_in_percent FROM sys.dm_db_log_space_usage) < 82 INSERT dbo.t SELECT TOP (50) %s FROM sys.all_objects; WAITFOR DELAY %s; COMMIT;\n' "'h'" "'00:01:30'" |
  docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c "SQLCMDPASSWORD=\$HOLD_PW $SQLCMD -S localhost -U $HOLDER -C -d pgvlog -h -1 -W -i /dev/stdin" > "$TMPD/holder.out" 2>&1 &
BG+=($!); HP=$!
sleep 25
sq "CHECKPOINT;" pgvlog >/dev/null
SPID=$(sq "SELECT TOP (1) session_id FROM sys.dm_exec_sessions WHERE login_name = N'$HOLDER'")
eqv "P9 the log waits on the open transaction" "$(sq "SELECT log_reuse_wait_desc FROM sys.databases WHERE name = 'pgvlog'")" ACTIVE_TRANSACTION
collect mssql_checks
det=$(pq "SELECT detail FROM pgvigil.mssql_checks_findings WHERE instance_id = $IID AND check_name = 'log space used' AND object = 'pgvlog'")
[[ -n "$SPID" && "$det" == *"held by session $SPID ($HOLDER, "* && "$det" == *"DBCC SQLPERF(LOGSPACE)"* ]] && ok "P9 the log rule names session $SPID and its login" || bad "P9 the detail: [$det] (session ${SPID:-not read}; holder said: $(head -c 200 "$TMPD/holder.out"))"
wait "$HP" 2>/dev/null
[[ -s "$TMPD/holder.out" ]] && head -5 "$TMPD/holder.out" | cut -c1-250 | sed 's/^/     holder: /'
sq "CHECKPOINT;" pgvlog >/dev/null
collect mssql_checks
det=$(pq "SELECT coalesce(string_agg(detail, ' '), 'none') FROM pgvigil.mssql_checks_findings WHERE instance_id = $IID AND check_name = 'log space used' AND object = 'pgvlog'")
[[ "$det" != *"held by"* ]] && ok "P9 committed: no holder named ($(cut -c1-60 <<<"$det"))" || bad "P9 after the commit: [$det]"
# tempdb's log held by a session's open transaction on a #table (its log set not to grow while the row runs); the row
# waits for the fill by polling (up to 155 s) and prints what SQL Server and the collector each saw at the read
TLOG=$(sq "SELECT TOP (1) name + '|' + CAST(growth AS varchar(20)) + '|' + CAST(is_percent_growth AS varchar(1)) FROM tempdb.sys.database_files WHERE type = 1 ORDER BY file_id")
sqv "P9 setup: tempdb's log fixed" "ALTER DATABASE tempdb MODIFY FILE (NAME = [${TLOG%%|*}], FILEGROWTH = 0);"
p9_dmv() { sq "SELECT CAST(CAST(total_log_size_in_bytes / 1048576.0 AS decimal(12,1)) AS varchar(20)) + ' MB ' + CAST(CAST(used_log_space_in_percent AS decimal(5,1)) AS varchar(10)) + ' %' FROM sys.dm_db_log_space_usage" tempdb 2>&1 | tr '\n' ' '; }
p9_perf() { sq "CREATE TABLE #p9_ls (db sysname, size_mb float, used_pct float, status int); INSERT #p9_ls EXEC ('DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');
SELECT CAST(CAST(size_mb AS decimal(12,1)) AS varchar(20)) + ' MB ' + CAST(CAST(used_pct AS decimal(5,1)) AS varchar(10)) + ' %' FROM #p9_ls WHERE db = N'tempdb'; DROP TABLE #p9_ls;" 2>&1 | tr '\n' ' '; }
# tempdb's VLFs (the fixture's precondition: each smaller than the 35 % seed), and the active VLFs ahead of the
# holder's first record (an LSN's leading part is its VLF's sequence number): what a CHECKPOINT after the fill frees
p9_vlf() { sq "SELECT CAST(COUNT(*) AS varchar(10)) + ' VLFs of ' + CAST(CAST(MIN(vlf_size_mb) AS decimal(8,2)) AS varchar(20)) + '-' + CAST(CAST(MAX(vlf_size_mb) AS decimal(8,2)) AS varchar(20)) + ' MB, ' + CAST(SUM(CASE WHEN vlf_active = 1 THEN 1 ELSE 0 END) AS varchar(10)) + ' active, the largest ' + CAST(CAST(100.0 * MAX(vlf_size_mb) / NULLIF(SUM(vlf_size_mb), 0) AS decimal(5,1)) AS varchar(10)) + ' % of the log' FROM sys.dm_db_log_info(2)" tempdb 2>&1 | tr '\n' ' '; }
p9_vlf_ahead() { sq "DECLARE @p9_b bigint = (SELECT MIN(CAST(FLOOR(dt.database_transaction_begin_lsn / 1000000000000000) AS bigint)) FROM sys.dm_tran_database_transactions dt
  JOIN sys.dm_tran_session_transactions st ON st.transaction_id = dt.transaction_id JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
  WHERE dt.database_id = 2 AND s.login_name = N'$HOLDER' AND dt.database_transaction_begin_lsn > 0);
SELECT CASE WHEN @p9_b IS NULL THEN 'no holder transaction in tempdb' ELSE CAST(COUNT(*) AS varchar(10)) + ' active VLFs (' + CAST(CAST(ISNULL(SUM(vlf_size_mb), 0) AS decimal(8,2)) AS varchar(20)) + ' MB) ahead of the holder''s first record (its VLF ' + CAST(@p9_b AS varchar(20)) + ')' END
  FROM sys.dm_db_log_info(2) WHERE vlf_active = 1 AND vlf_sequence_number < @p9_b" tempdb 2>&1 | tr '\n' ' '; }
# committed work in tempdb's log before the holder, not yet truncated (one run met 34.3 % from earlier rows; made here
# on purpose so the row never rides on what ran before it)
sqv "P9 setup: tempdb's log carries committed work" "CREATE TABLE #p9_pre (pad char(4000)); WHILE (SELECT used_log_space_in_percent FROM sys.dm_db_log_space_usage) < 35 INSERT #p9_pre SELECT TOP (50) 'p' FROM sys.all_objects; DROP TABLE #p9_pre;" tempdb
p9_seed=$(p9_dmv)
# the fix: a CHECKPOINT truncates that committed work before the holder starts, so the CHECKPOINT after the fill (for
# the wait ACTIVE_TRANSACTION) frees no VLF the fill counted, unless a VLF boundary falls between this CHECKPOINT and
# the holder's first insert (the line at the fill names the active VLFs ahead of the holder's first record)
sqv "P9 setup: tempdb's CHECKPOINT before the holder" "CHECKPOINT;" tempdb
echo "     p9 tempdb's log before the holder: $p9_seed(after the seed) $(p9_dmv)(after the CHECKPOINT; sys.dm_db_log_space_usage); $(p9_vlf)(sys.dm_db_log_info; the fixture's red needs each smaller than the 35 % seed)"
printf 'SET NOCOUNT ON; DECLARE @p9_t0 datetime2 = SYSDATETIME(); BEGIN TRAN; CREATE TABLE #h (pad char(4000)); WHILE (SELECT used_log_space_in_percent FROM sys.dm_db_log_space_usage) < 82 AND DATEDIFF(second, @p9_t0, SYSDATETIME()) < 150 INSERT #h SELECT TOP (50) %s FROM sys.all_objects; WAITFOR DELAY %s; COMMIT;\n' "'t'" "'00:01:00'" |
  docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c "SQLCMDPASSWORD=\$HOLD_PW $SQLCMD -S localhost -U $HOLDER -C -d tempdb -h -1 -W -i /dev/stdin" > "$TMPD/holder2.out" 2>&1 &
BG+=($!); HP=$!
# the poll outlasts the filler's 150 s (a fill ending at 140 s is never read mid-fill); each poll read 10 s at most
p9_t0=$SECONDS; p9_fill="not reached in 155 s"
while (( SECONDS - p9_t0 < 155 )); do
  p9_u=$(SQ_TIMEOUT=10 sq "SELECT CAST(FLOOR(used_log_space_in_percent) AS int) FROM sys.dm_db_log_space_usage" tempdb 2>/dev/null)
  if [[ $p9_u =~ ^[0-9]+$ ]] && (( p9_u >= 82 )); then p9_fill="$(( SECONDS - p9_t0 )) s"; break; fi
  kill -0 "$HP" 2>/dev/null || { p9_fill="the holder ended first, at $(( SECONDS - p9_t0 )) s (used ${p9_u:-not read} %)"; break; }
  sleep 2
done
p9_ah=$(p9_vlf_ahead)  # what the CHECKPOINT below frees
sq "CHECKPOINT;" tempdb >/dev/null
SPID=$(sq "SELECT TOP (1) session_id FROM sys.dm_exec_sessions WHERE login_name = N'$HOLDER'")
p9_sess=$(sq "SELECT string_agg(CAST(session_id AS varchar(10)), ',') FROM sys.dm_exec_sessions WHERE login_name = N'$HOLDER'")
p9_wait=$(sq "SELECT log_reuse_wait_desc FROM sys.databases WHERE name = 'tempdb'")
p9_at0=$(p9_dmv); p9_lsp=$(p9_perf)
collect mssql_checks; p9_crc=$?
p9_at1=$(p9_dmv)
p9_tx=$(sq "SELECT string_agg(x, '; ') WITHIN GROUP (ORDER BY b) FROM (SELECT TOP (3) dt.database_transaction_begin_time AS b,
  ISNULL(CAST(st.session_id AS varchar(10)), 'no session') + ' ' + ISNULL(s.login_name, '-') + ' open '
  + CAST(DATEDIFF(second, dt.database_transaction_begin_time, GETDATE()) AS varchar(12)) + ' s, ' + CAST(CAST(dt.database_transaction_log_bytes_used / 1048576.0 AS decimal(12,1)) AS varchar(20)) + ' MB' AS x
  FROM sys.dm_tran_database_transactions dt LEFT JOIN sys.dm_tran_session_transactions st ON st.transaction_id = dt.transaction_id
  LEFT JOIN sys.dm_exec_sessions s ON s.session_id = st.session_id
  WHERE dt.database_id = 2 AND dt.database_transaction_begin_time IS NOT NULL ORDER BY dt.database_transaction_begin_time) t" 2>&1 | tr '\n' ' ')
# what the collector stored: the logspace area first (a run that did not read the logs keeps the earlier log values
# under a fresh snapshot_at, 0090), the values only when this run read them; ages, not clock times (two clocks)
p9_store=$(pq "SELECT CASE WHEN a.instance_id IS NULL THEN 'no logspace area row'
  WHEN NOT a.is_read THEN 'logspace not read this run: ' || coalesce(a.note, '(no note)')
  ELSE 'logspace read ' || round(extract(epoch FROM now() - a.read_at))::int || ' s ago; ' || coalesce((SELECT 'log_used_pct ' || coalesce(options->>'log_used_pct', '-')
    || ', log_size_mb ' || coalesce(options->>'log_size_mb', '-') || ', log_reuse_wait ' || coalesce(options->>'log_reuse_wait', '-') || ', present ' || is_present::text
    || ', row ' || round(extract(epoch FROM now() - snapshot_at))::int || ' s old'
    FROM pgvigil.mssql_database_option WHERE instance_id = $IID AND database_name = 'tempdb'), 'no tempdb row') END
  FROM (SELECT 1) one LEFT JOIN pgvigil.mssql_check_area a ON a.instance_id = $IID AND a.area = 'logspace'" 2>&1 | tr '\n' ' ')
p9_runs=$(pq "SELECT coalesce(string_agg(status || coalesce(': ' || left(note, 120), ''), '; '), 'none') FROM pgvigil.collection_log
  WHERE instance_id = $IID AND collection = 'mssql_checks' AND snapshot_at > now() - interval '5 minutes'" 2>&1 | tr '\n' ' ')
echo "     p9 tempdb's log: filled to 82 % in $p9_fill; at the fill $p9_ah; at the read $p9_at0(dmv) $p9_lsp(SQLPERF), after the collect $p9_at1(dmv); wait $p9_wait; the holder's sessions [$p9_sess]"
echo "     p9 tempdb's open transactions, oldest first: [$p9_tx]"
echo "     p9 mssql_checks: rc $p9_crc, last run $(lastrun mssql_checks 2>&1 | tr '\n' ' ' | cut -c1-150), not-ok runs in 5 min: $(cut -c1-150 <<<"$p9_runs")"
echo "     p9 mssql_checks stored for tempdb: $(cut -c1-250 <<<"$p9_store"); collect said: $(tail -1 "$TMPD/collect.out" | cut -c1-100)"
det=$(pq "SELECT detail FROM pgvigil.mssql_checks_findings WHERE instance_id = $IID AND check_name = 'log space used' AND object = 'tempdb'")
# the guard judges the value the rule judged: the stored log_used_pct (p9_store above says whether this run read it)
p9_su=$(pq "SELECT floor((options->>'log_used_pct')::numeric)::int FROM pgvigil.mssql_database_option WHERE instance_id = $IID AND database_name = 'tempdb'" 2>/dev/null)
if [[ -z "$det" && $p9_su =~ ^[0-9]+$ ]] && (( p9_su < 75 )); then
  bad "P9 tempdb's log: the setup's fill fell to $p9_su % at the read (the stored log_used_pct, the rule's input: under its 75, so the rule is right to stay silent; the row proves nothing) (fill: $p9_fill; at the fill $p9_ah; at the read $p9_at0)"
else [[ -n "$SPID" && "$det" == *"held by session $SPID ($HOLDER, "* ]] && ok "P9 tempdb's log: the rule names session $SPID (fill: $p9_fill)" \
  || bad "P9 tempdb's log: [$det] (session ${SPID:-not read}; wait $p9_wait; fill: $p9_fill; at the read $p9_at0/ $p9_lsp; stored: $(cut -d';' -f1-2 <<<"$p9_store" | cut -c1-120))"
fi
wait "$HP" 2>/dev/null
[[ -s "$TMPD/holder2.out" ]] && head -3 "$TMPD/holder2.out" | cut -c1-250 | sed 's/^/     holder: /'
IFS='|' read -r tl_name tl_growth tl_pct <<<"$TLOG"
if [[ $tl_pct == 1 ]]; then tl_set="FILEGROWTH = ${tl_growth}%"; else tl_set="FILEGROWTH = $(( tl_growth * 8 ))KB"; fi
sqv "P9 setup: tempdb's log growth back" "ALTER DATABASE tempdb MODIFY FILE (NAME = [$tl_name], $tl_set);"
# FULL recovery, a full backup and no log backup: the log waits on LOG_BACKUP; an open transaction there is not its holder
sqv "P9 setup: pgvlb" "CREATE DATABASE pgvlb ON (NAME = 'pgvlb', FILENAME = '/var/opt/mssql/data/pgvlb.mdf', SIZE = 64MB) LOG ON (NAME = 'pgvlb_log', FILENAME = '/var/opt/mssql/data/pgvlb_log.ldf', SIZE = 32MB, FILEGROWTH = 0);
ALTER DATABASE pgvlb SET RECOVERY FULL;"
sqv "P9 setup: pgvlb's table" "CREATE USER [$MON] FOR LOGIN [$MON]; CREATE USER [$HOLDER] FOR LOGIN [$HOLDER]; ALTER ROLE db_owner ADD MEMBER [$HOLDER]; CREATE TABLE dbo.t (pad char(4000));" pgvlb
sqv "P9 setup: pgvlb's full backup" "BACKUP DATABASE pgvlb TO DISK = '/var/opt/mssql/data/pgvlb.bak' WITH INIT;"
sqv "P9 setup: pgvlb's log filled by committed work" "WHILE (SELECT used_log_space_in_percent FROM sys.dm_db_log_space_usage) < 85 INSERT dbo.t SELECT TOP (50) 'c' FROM sys.all_objects;" pgvlb
printf 'SET NOCOUNT ON; BEGIN TRAN; INSERT dbo.t VALUES (%s); WAITFOR DELAY %s; COMMIT;\n' "'u'" "'00:00:40'" |
  docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c "SQLCMDPASSWORD=\$HOLD_PW $SQLCMD -S localhost -U $HOLDER -C -d pgvlb -h -1 -W -i /dev/stdin" >/dev/null 2>&1 &
BG+=($!); HP=$!
sleep 5; sq "CHECKPOINT;" pgvlb >/dev/null
collect mssql_checks
det=$(pq "SELECT coalesce(string_agg(detail, ' '), 'none') FROM pgvigil.mssql_checks_findings WHERE instance_id = $IID AND check_name = 'log space used' AND object = 'pgvlb'")
[[ "$det" == *"LOG_BACKUP"* && "$det" != *"held by"* && "$det" != *"holder"* ]] && ok "P9 a log waiting on LOG_BACKUP: the rule fires and names no holder, an open transaction there or not" \
  || bad "P9 the LOG_BACKUP log: [$det] (wait $(sq "SELECT log_reuse_wait_desc FROM sys.databases WHERE name = 'pgvlb'"))"
wait "$HP" 2>/dev/null

# ---- P11 the API ---------------------------------------------------------------------------------------------------------
echo "== P11: the API"
api_parts() {  # $1 label, $2 path, $3 the parts wanted (sorted, comma-separated)
  local code parts
  code=$(curl -s -o "$TMPD/api.json" -w '%{http_code}' "http://127.0.0.1:$PORT/api/$2")
  parts=$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$TMPD/api.json" 2>/dev/null)
  [[ $code == 200 && "$parts" == "$3" ]] && ok "P11 $1: 200 ($parts)" || bad "P11 $1: $code [$parts] want [$3] $(head -c 200 "$TMPD/api.json")"
}
api_parts "every part of the storage depth with a database and a table" "mssql/storage_depth?instance=$IID&db=pgvst&schema=dbo&table=h0001" \
  checks,drives,forecast,growth,orphans,paths,pending,runs,space,space_series,table_series,tables,tables_read,tempdb,tempdb_series
api_parts "?parts= gives those parts only" "mssql/storage_depth?instance=$IID&parts=runs,space" runs,space
api_parts "the IO by volume against a week" "mssql/dbio?instance=$IID&by=volume&compare=7d" compare,grid,series
curl -s "http://127.0.0.1:$PORT/api/mssql/storage_depth?instance=$IID&parts=drives,runs" > "$TMPD/api.json"
python3 - "$TMPD/api.json" <<'PY3' && ok "P11 the '/' drive's size not read (null on the API); a collection that ran ok has its run on the API" || bad "P11 drives / runs: $(head -c 400 "$TMPD/api.json")"
import json, sys
d = json.load(open(sys.argv[1]))
rows = lambda t: [dict(zip(d[t]['columns'], r)) for r in d[t]['rows']]
slash = [r for r in rows('drives') if r.get('drive') == '/']
runs = {r['collection']: r['status'] for r in rows('runs')}
sys.exit(0 if slash and slash[0].get('total_bytes') is None and runs.get('mssql_tables') == 'ok' and runs.get('mssql_storage') == 'ok' else 1)
PY3
F31=$(date -u -d '31 minutes ago' +%Y-%m-%dT%H:%M:%SZ); NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -s "http://127.0.0.1:$PORT/api/mssql/dbio?instance=$IC&from=$F31&to=$NOW&compare=1d" > "$TMPD/api.json"
want=$(pq "SELECT name || ' ' || mb_s || ' ' || mb_s_before || ' ' || read_latency_ms || ' ' || read_latency_ms_before FROM pgvigil.mssql_io_compare($IC, '$F31', '$NOW', interval '1 day', 'database')")
got=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["compare"]; r = dict(zip(d["columns"], d["rows"][0]))
f = lambda v: "%.3f" % float(v) if v is not None else "None"
g = lambda v: "%.2f" % float(v) if v is not None else "None"
print(r["name"], f(r["mb_s"]), f(r["mb_s_before"]), g(r["read_latency_ms"]), g(r["read_latency_ms_before"]))' "$TMPD/api.json" 2>&1)
eqv "P11 the IO compare on the API (joined in Go) = mssql_io_compare" "$got" "$want"
# the Summary: the forecast in Disk; every other new arm in no cell (pgvful's and model's warnings are raised now)
pq "SELECT pgvigil.ensure_month_partition('mssql_volume_sample', now() - interval '20 days');
INSERT INTO pgvigil.mssql_volume_sample (instance_id, snapshot_at, volume, total_bytes, free_bytes)
  SELECT $IID, now() - make_interval(hours => h), v.volume, v.total_bytes, v.free_bytes + (h * v.free_bytes / 240) FROM pgvigil.mssql_volumes v, generate_series(1, 20 * 24) h
   WHERE v.instance_id = $IID AND v.is_present" >/dev/null
sq "ALTER DATABASE pgvful MODIFY FILE (NAME = 'pgvful', FILEGROWTH = 1MB);" >/dev/null; collect mssql_storage
curl -s "http://127.0.0.1:$PORT/api/mssql/summary?part=cells" > "$TMPD/sum.json"
python3 - "$TMPD/sum.json" "$IID" <<'PY' && ok "P8 Summary: the forecast in Disk, no other depth arm in a cell" || bad "P8 Summary cells: $(head -c 600 "$TMPD/sum.json")"
import json, sys
d = json.load(open(sys.argv[1])); iid = int(sys.argv[2])
t = d.get('cells') or {'columns': [], 'rows': []}
cells = [c for c in (dict(zip(t['columns'], r)) for r in t['rows']) if int(c.get('instance_id') or -1) == iid]
names = ['tempdb data files filling', 'more than one log file', 'a file under 20 % free inside it', "a filegroup's data files unbalanced",
         'a data file growth step under 64 MB', 'model grows by', 'a tempdb file', 'the default', 'an orphaned database file']
disk = [c for c in cells if c.get('key') == 'disk']
ok = disk and any('a volume full within 30 days' in str(x) for x in (disk[0].get('detail') or []))
for c in cells:
    for x in c.get('detail') or []:
        if any(str(x).startswith(n) for n in names):
            print('     in', c.get('key'), ':', x); ok = False
sys.exit(0 if ok else 1)
PY

# ---- P12 least privilege (B3) and the off switch (F10) ----------------------------------------------------------------
echo "== P12: least privilege"
LPL=pgv_lp_$SUF; LVL=pgv_lv_$SUF; LP_PW=$(pw); LV_PW=$(pw)
sqv "P12 setup: the logins" "CREATE LOGIN [$LVL] WITH PASSWORD = '$LV_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$LVL];
CREATE LOGIN [$LPL] WITH PASSWORD = '$LP_PW', CHECK_POLICY = OFF; GRANT VIEW ANY DEFINITION TO [$LPL];"
[[ $MAJOR -ge 16 ]] && sqv "P12 setup: VIEW SERVER PERFORMANCE STATE alone" "GRANT VIEW SERVER PERFORMANCE STATE TO [$LPL];"
sqv "P12 setup: their users in pgvsd" "CREATE USER [$LPL] FOR LOGIN [$LPL]; CREATE USER [$LVL] FOR LOGIN [$LVL];" pgvsd
export PGV_SD_LP="sqlserver://$LPL:$(urlq "$LP_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
export PGV_SD_LV="sqlserver://$LVL:$(urlq "$LV_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
cat > "$TMPD/m2.yaml" <<YAML
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox_lp
    engine: sqlserver
    dsn: env:PGV_SD_LP
  - name: sqlbox_lv
    engine: sqlserver
    dsn: env:PGV_SD_LV
YAML
c2() { "$BIN" collect -config "$TMPD/m2.yaml" -once "$1" -instance "$2" > "$TMPD/collect2.out" 2>&1 || tail -3 "$TMPD/collect2.out"; }
if [[ $MAJOR -ge 16 ]]; then
  for c in mssql_storage mssql_storage_depth mssql_tables; do c2 "$c" sqlbox_lp; eqv "P12 2022, VIEW SERVER PERFORMANCE STATE (no VIEW SERVER STATE): $c runs" "$(lastrun "$c" sqlbox_lp)" ok; done
  check "P12 ... and the space split is read with it" "SELECT count(*) > 0 FROM pgvigil.mssql_database_space s JOIN pgvigil.instances i ON i.instance_id = s.instance_id WHERE i.name = 'sqlbox_lp' AND s.database_name = 'pgvsd'" t
  check "P12 ... and the volumes' total and free space with it" "SELECT count(*) > 0 AND bool_and(v.total_bytes IS NOT NULL AND v.free_bytes IS NOT NULL) FROM pgvigil.mssql_volumes v JOIN pgvigil.instances i ON i.instance_id = v.instance_id WHERE i.name = 'sqlbox_lp'" t
else
  np "P12 VIEW SERVER PERFORMANCE STATE: SQL Server 2022 and later only"
fi
c2 mssql_storage_depth sqlbox_lv
check "P12 without VIEW ANY DEFINITION: the paths and drives read, the orphans not, and why" \
  "SELECT p.drives_read || ' ' || p.orphans_read || ' ' || (p.orphans_note LIKE 'not read: the login lacks VIEW ANY DEFINITION%') FROM pgvigil.mssql_storage_paths p JOIN pgvigil.instances i ON i.instance_id = p.instance_id WHERE i.name = 'sqlbox_lv'" 'true false true'
c2 mssql_tables sqlbox_lv
eqv "P12 without VIEW ANY DEFINITION: mssql_tables skipped, naming the right" "$(lastrun mssql_tables sqlbox_lv | grep -o '^skipped.*VIEW ANY DEFINITION' | cut -c1-7)" skipped
# F10: an instance's off switch for mssql_tables is a valid configuration (the scheduler then gives it no interval:
# config.Interval); collect -once is a run by hand and is not the schedule
sed 's/^    dsn: env:PGV_SD_MON$/    dsn: env:PGV_SD_MON\n    disabled: [mssql_tables]/' "$TMPD/m.yaml" > "$TMPD/m3.yaml"
grep -q 'disabled: \[mssql_tables\]' "$TMPD/m3.yaml" && "$BIN" collect -config "$TMPD/m3.yaml" -once mssql_storage -instance sqlbox > "$TMPD/m3.out" 2>&1 \
  && ok "P12 'disabled: [mssql_tables]' in an instance's entry is a valid configuration" || bad "P12 the off switch's configuration: $(tail -2 "$TMPD/m3.out" 2>/dev/null)"
# the off switch's behaviour (the lead's 20:4x row): the scheduler with mssql_tables off for sqlbox runs 30 s - no new
# mssql_tables run, read marker or sample, while mssql_storage_depth (on) runs; the depth API says 'off' for it
offstate() { pq "SELECT coalesce((SELECT snapshot_at::text FROM pgvigil.collection_dates WHERE instance_id = $IID AND collection = 'mssql_tables'), '-') || ' '
  || coalesce((SELECT max(read_at)::text FROM pgvigil.mssql_tables_db_read WHERE instance_id = $IID), '-') || ' '
  || (SELECT count(*) FROM pgvigil.mssql_table_sample WHERE instance_id = $IID)"; }
off0=$(offstate); dep0=$(pq "SELECT snapshot_at FROM pgvigil.collection_dates WHERE instance_id = $IID AND collection = 'mssql_storage_depth'")
"$BIN" run -config "$TMPD/m3.yaml" > "$TMPD/run3.out" 2>&1 & RUNP=$!; BG+=($RUNP)
sleep 30; kill "$RUNP" 2>/dev/null; wait "$RUNP" 2>/dev/null
dep1=$(pq "SELECT snapshot_at FROM pgvigil.collection_dates WHERE instance_id = $IID AND collection = 'mssql_storage_depth'")
[[ "$dep1" > "$dep0" ]] && ok "P12 the scheduler ran with the switch off (mssql_storage_depth read again)" || bad "P12 the scheduler did not run: $(tail -3 "$TMPD/run3.out")"
eqv "P12 mssql_tables off: no new run, read marker or sample" "$(offstate)" "$off0"
P3PORT=$((PORT + 1))
"$BIN" serve -config "$TMPD/m3.yaml" -listen "127.0.0.1:$P3PORT" -no-login > "$TMPD/serve3.out" 2>&1 & S3=$!; BG+=($S3)
for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$P3PORT/api/instances" >/dev/null 2>&1 && break; sleep 1; done
off=$(curl -s "http://127.0.0.1:$P3PORT/api/mssql/storage_depth?instance=$IID&parts=runs" | python3 -c '
import json, sys
d = json.load(sys.stdin)["runs"]; r = {x[0]: x for x in d["rows"]}; k = d["columns"].index("status")
print(r.get("mssql_tables", [None] * 9)[k], r.get("mssql_storage_depth", [None] * 9)[k])' 2>&1)
eqv "P12 the depth API with the switch off: mssql_tables 'off' (the page says off), mssql_storage_depth as read" "$off" "off ok"
kill "$S3" 2>/dev/null

# ---- P10 the version run ---------------------------------------------------------------------------------------------
for img in "${IMAGES[@]:1}"; do
  echo "== P10: $img"
  kill "$SRV_PID" 2>/dev/null; SRV_PID=
  docker rm -f -v "$SQL" >/dev/null 2>&1
  pq "DELETE FROM pgvigil.instances WHERE name = 'sqlbox'" >/dev/null
  start_server "$img"
  ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")"
  for c in mssql_storage mssql_versionstore mssql_fileio mssql_storage_depth mssql_tables; do
    collect "$c" || true
    eqv "$img A: $c runs as the monitor login" "$(lastrun "$c")" "ok"
  done
  IID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'")
  space_check "$img"
  tables_check "$img" 40
  io_check "$img"
  rules_logs_orphans "$img"
done
np "SQL Server 2016: no Linux image (its drive and folder reads say 'not read: SQL Server 2017 and later list ...')"

echo "PROOF $( [[ $FAILS == 0 ]] && echo OK || echo FAILED ): mssql storage depth ($FAILS failed, $NP not proven)"
exit $FAILS
