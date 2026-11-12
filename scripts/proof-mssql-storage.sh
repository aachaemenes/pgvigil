#!/usr/bin/env bash
# Proof of SQL Server storage and the version store (migration 0067, internal/mssql/storage.go and versionstore.go):
# the collections mssql_storage and mssql_versionstore as a least-privilege login, against what sa reads.
#
# Needs: docker with a SQL Server container (PGVIGIL_MSSQL_CONTAINER, default mssql-sandbox) reachable from this
# machine on PGVIGIL_MSSQL_ADDR (default localhost:1433), its sa password in MSSQL_SA_PASSWORD, psql, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# The proof makes its own repository database, two SQL Server logins (random suffix, random passwords) and two SQL
# Server databases (<name> with two data files in two filegroups and a log, <name>_closed the login cannot enter),
# and drops them at the end, on every exit path. It changes no server setting. Its version store part holds one
# snapshot transaction open for 50 seconds in its own database and writes about 150 MB of row versions to tempdb.
#
# Expected (written before the first run):
#  A. as the login with VIEW SERVER STATE and VIEW ANY DEFINITION and a user in the proof's database: `collect -once
#     mssql_storage` stores the database's three files with the size, the used space, the maximum, the growth (a
#     size on two files, 10 per cent on one) and the filegroup sa reads in that database, used_read true; each
#     file's volume is the mount point sa reads, or on Linux (no mount point named) the file's directory; that
#     volume's total equals sa's and its free space is within 2 % of the total of sa's read; mssql_database_size
#     holds the database's data and log sizes; the run is not an error.
#  B. the database the login cannot enter is kept: its two files with sa's allocated sizes, used_read false, the
#     note starting 'used not read: the login cannot enter'.
#  C. a file grown by the proof (16 MB to 56 MB, one growth step short of its 64 MB maximum) is larger on the next
#     run: the new size, previous_size_bytes = the old one, size_changed_at = that run's time, a second, larger
#     row in mssql_database_size; and the finding 'a file within one growth of its max size' (warning) names it.
#  D. grown to its maximum: 'a file at its max size', critical, and no longer the warning.
#  E. a file the proof removes is marked not present on the next run; the other files stay present.
#  F. a login without VIEW SERVER STATE: mssql_storage says partial naming sys.dm_os_volume_stats, stores the files
#     and no volume; mssql_versionstore is skipped with the missing right named.
#  G. the import functions refuse a PostgreSQL instance.
#  H. the findings' thresholds, on rows imported for a second SQL Server instance of the proof (no server needed):
#     a volume with 8 % free: warning; with 4 %: critical; with 50 %: nothing; a 20 GiB file growing by per cent:
#     info; a 2 GiB log over a 1 GiB data file: info.
#  V. the version store, in the proof's database under snapshot isolation: a session holds a snapshot transaction
#     open while another updates rows in a loop. Across two reads the store's reserved size rises and the second
#     read carries a generation rate above zero; both reads name the holder: its session id, the proof's login it
#     runs as, a start time within 90 s of the transaction's own, and a last statement holding the proof's marker;
#     mssql_versionstore_db lists the proof's database. After the holder commits, within three minutes a read
#     shows a smaller store and no holder row for that session. mssql_pvs lists the closed database (accelerated
#     database recovery is on there: a database with it keeps its row versions in itself, not in tempdb) with a
#     size of zero or more.
#  Y. two instances' imports at the same time, sixty calls each, one writing into a month that exists and the other
#     opening a new month on every call (no server needed): no call fails (before the fixed lock order in
#     import_mssql_storage every few calls ended in "deadlock detected"), and sixty rows of each are stored.
#  W. the version store findings, on imported rows (no server needed): eleven reads a minute apart in which the
#     store grows, generation runs and cleanup stands at zero raise 'the version store grows while cleanup is at
#     zero' with the holder's session, age and last statement in the detail; one more read in which cleanup moved
#     ends it; a store over a third of tempdb raises its finding; a persistent version store of 2 GiB with aborted
#     transactions raises its finding, and none without aborted transactions.
#  X. the imports under a retry and out of order, on imported rows: a storage payload and a version store payload
#     imported twice at one snapshot time leave one size row per database, one volume sample and one version store
#     sample; a version store payload OLDER than a read that listed no database does not put its per-database rows
#     back (the state stays empty).
#  NOT PROVEN HERE: Windows volumes (drive letters and mounted folders: no Windows SQL Server in this proof), SQL
#     Server 2016-2019, Managed Instance and RDS, a server with thousands of databases, a FILESTREAM container.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_mssqlstorage_$SUF
L1=pgv_stor_$SUF; L2=pgv_storbare_$SUF; DB=pgvproof_stor_$SUF; DBC=${DB}_closed
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw)
CFG=$(mktemp); OUT=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MADE_REPO=; MADE_L1=; MADE_L2=; MADE_DB=; MADE_DBC=; BG=()
sqlcmd_() { docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -W -h -1 -s '|' "$@"; }
sq() { sqlcmd_ -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# as the proof's own login (its password through the environment, by name)
sq1() { SQLCMDPASSWORD="$P1" docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -W -h -1 -s '|' -U "$L1" -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
cleanup() {
  rc=$?
  for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  # only what THIS run created: a name that existed before the run stays
  for d in "$DB:$MADE_DB" "$DBC:$MADE_DBC"; do
    if [ -n "${d#*:}" ]; then
      sq "IF DB_ID('${d%%:*}') IS NOT NULL BEGIN ALTER DATABASE [${d%%:*}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [${d%%:*}]; END" >/dev/null 2>&1 || echo "CLEANUP: database ${d%%:*} not dropped" >&2
    fi
  done
  if [ -n "$MADE_L1" ]; then sq "IF SUSER_ID('$L1') IS NOT NULL DROP LOGIN [$L1];" >/dev/null 2>&1 || echo "CLEANUP: login $L1 not dropped" >&2; fi
  if [ -n "$MADE_L2" ]; then sq "IF SUSER_ID('$L2') IS NOT NULL DROP LOGIN [$L2];" >/dev/null 2>&1 || echo "CLEANUP: login $L2 not dropped" >&2; fi
  if [ -n "$MADE_REPO" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -f "$CFG" "$OUT"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

[ "$(sq "SELECT ISNULL(DB_ID('$DB'), 0) + ISNULL(DB_ID('$DBC'), 0) + ISNULL(SUSER_ID('$L1'), 0) + ISNULL(SUSER_ID('$L2'), 0)")" = 0 ] || fail "setup: a name of this run exists already (suffix $SUF): run again"
DATADIR=$(sq "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(260))")
[ -n "$DATADIR" ] || fail "setup: the server's default data path"
sq "CREATE DATABASE [$DB] ON PRIMARY (NAME = pv_data1, FILENAME = '${DATADIR}${DB}_1.mdf', SIZE = 16MB, FILEGROWTH = 8MB, MAXSIZE = 64MB),
      FILEGROUP FG2 (NAME = pv_data2, FILENAME = '${DATADIR}${DB}_2.ndf', SIZE = 8MB, FILEGROWTH = 10%)
      LOG ON (NAME = pv_log, FILENAME = '${DATADIR}${DB}_log.ldf', SIZE = 8MB, FILEGROWTH = 4MB, MAXSIZE = 1GB);"; MADE_DB=1
sq "ALTER DATABASE [$DB] SET RECOVERY SIMPLE; ALTER DATABASE [$DB] SET ALLOW_SNAPSHOT_ISOLATION ON;"
# accelerated database recovery on the closed database only: with it on, a database's row versions go to its own
# persistent version store and not to tempdb, and part V measures tempdb's
sq "CREATE DATABASE [$DBC];"; MADE_DBC=1
# (accelerated database recovery arrived in SQL Server 2019: before it the closed database stays a plain one and
# part V expects no persistent version store row at all)
MAJ=$(sq "SELECT CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 4) AS int)")
if [ "$MAJ" -ge 15 ]; then sq "ALTER DATABASE [$DBC] SET ACCELERATED_DATABASE_RECOVERY = ON;"; fi
sq "CREATE LOGIN [$L1] WITH PASSWORD = '$P1', CHECK_POLICY = OFF;"; MADE_L1=1
sq "GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1];"
sq "CREATE LOGIN [$L2] WITH PASSWORD = '$P2', CHECK_POLICY = OFF;"; MADE_L2=1
sq "GRANT VIEW ANY DEFINITION TO [$L2];"
# the read login enters the proof's database as a plain user; the holder and the writer of part V run as it too
sq "CREATE USER [$L1] FOR LOGIN [$L1]; CREATE TABLE dbo.pv_rows (id int NOT NULL PRIMARY KEY, pad char(4000) NOT NULL); CREATE TABLE dbo.pv_holder (spid int NOT NULL, started datetime2 NOT NULL);
    GRANT SELECT, INSERT, UPDATE ON dbo.pv_rows TO [$L1]; GRANT SELECT, INSERT ON dbo.pv_holder TO [$L1];
    INSERT dbo.pv_rows (id, pad) SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), 'a' FROM sys.all_columns;" "$DB"
export MSSQL_MON_DSN="sqlserver://$L1:$P1@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_BARE_DSN="sqlserver://$L2:$P2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export PG_MON_DSN="$ADMIN_DSN"
N1=proof-mssql-stor-$SUF; N2=proof-mssql-storbare-$SUF; NP=proof-pg-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_MON_DSN
  - name: $N2
    engine: sqlserver
    dsn: env:MSSQL_BARE_DSN
  - name: $NP
    dsn: env:PG_MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
# the drive thresholds this proof's fixtures were written for: 10 / 5 at the root (task 176b: the default is DBA Dash's
# 20 / 10, its edges proven in proof-clickmap.sh T1)
[[ $(psql "$PGVIGIL_REPO_DSN" -XAtq -c "select pgvigil.import_drive_threshold(now(), '{\"op\":\"set\",\"level\":\"root\",\"warn\":\"10\",\"crit\":\"5\",\"ui_user\":\"proof\"}'::jsonb)->>'outcome'") == done ]] || fail "the root drive threshold 10 / 5"
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "${2:-$N1}" | tee "$OUT"; }

# what sa reads of one database's files, in that database: file_id|size|used|max|growth_bytes|growth_pct|filegroup
sa_files() { sq "SELECT CAST(df.file_id AS varchar(10)) + '|' + CAST(CAST(df.size AS bigint) * 8192 AS varchar(20)) + '|' + ISNULL(CAST(CAST(FILEPROPERTY(df.name, 'SpaceUsed') AS bigint) * 8192 AS varchar(20)), '') + '|'
      + ISNULL(CAST(CASE WHEN df.max_size = -1 THEN NULL WHEN df.max_size = 0 THEN CAST(df.size AS bigint) * 8192 ELSE CAST(df.max_size AS bigint) * 8192 END AS varchar(20)), '') + '|'
      + CAST(CASE WHEN df.max_size = 0 OR df.is_percent_growth = 1 THEN 0 ELSE CAST(df.growth AS bigint) * 8192 END AS varchar(20)) + '|'
      + CAST(CASE WHEN df.max_size <> 0 AND df.is_percent_growth = 1 THEN df.growth ELSE 0 END AS varchar(10)) + '|' + ISNULL(fg.name, '')
      FROM sys.database_files df LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id ORDER BY df.file_id" "$1"; }
repo_files() { q "select file_id || '|' || size_bytes || '|' || coalesce(used_bytes::text, '') || '|' || coalesce(max_size_bytes::text, '') || '|' || growth_bytes || '|' || growth_pct || '|' || coalesce(filegroup, '')
      from pgvigil.mssql_files where instance_id = $iid and database_name = '$1' and is_present order by file_id"; }

echo "--- A. mssql_storage as the least-privilege login"
# sa reads the files before AND after the collector does: a database's used pages move by themselves (a new
# database's most of all), so the used bytes the collector stored are held between the two reads, each file's own;
# every other column is compared exactly with the read taken after it
SA0=$(sa_files "$DB")
collect mssql_storage
iid=$(q "select instance_id from pgvigil.instances where name='$N1'")
SA=$(sa_files "$DB"); GOT=$(repo_files "$DB")
echo "  sa reads (file|size|used|max|growth|growth %|filegroup), after the collector's read:"; echo "$SA" | sed 's/^/    /'
[ "$(echo "$SA" | wc -l)" = 3 ] || fail "A: sa lists $(echo "$SA" | wc -l) files, not 3"
but_used() { awk -F'|' -v OFS='|' '{ $3 = "-"; print }'; }
[ "$(echo "$GOT" | but_used)" = "$(echo "$SA" | but_used)" ] || { echo "  stored:"; echo "$GOT" | sed 's/^/    /'; fail "A: the stored files differ from sa's read"; }
USED_OFF=$(paste -d'|' <(echo "$SA0" | cut -d'|' -f1,3) <(echo "$SA" | cut -d'|' -f1,3) <(echo "$GOT" | cut -d'|' -f1,3) \
  | awk -F'|' '{ lo = ($2 + 0 < $4 + 0) ? $2 + 0 : $4 + 0; hi = ($2 + 0 < $4 + 0) ? $4 + 0 : $2 + 0
                 if ($1 != $3 || $1 != $5 || $2 == "" || $4 == "" || $6 == "" || $6 + 0 < lo || $6 + 0 > hi) printf " %s (stored %s, sa %s before and %s after)", $1, $6, $2, $4 }')
[ -z "$USED_OFF" ] || { echo "  stored:"; echo "$GOT" | sed 's/^/    /'; fail "A: the stored used bytes are not between sa's two reads: file$USED_OFF"; }
# the maximum, the growth and the filegroup against what the proof itself asked for in CREATE DATABASE (sa's read
# above shares the product's arithmetic; these constants do not): file 1 the data file (64 MB max, 8 MB steps), file
# 2 the log (1 GB max, 4 MB steps, no filegroup), file 3 the second data file (no maximum, 10 per cent, FG2)
WANT_DEF="1|$((64 * 1048576))|$((8 * 1048576))|0|PRIMARY|ROWS
2|$((1024 * 1048576))|$((4 * 1048576))|0||LOG
3||0|10|FG2|ROWS"
GOT_DEF=$(q "select file_id || '|' || coalesce(max_size_bytes::text, '') || '|' || growth_bytes || '|' || growth_pct || '|' || coalesce(filegroup, '') || '|' || type_desc from pgvigil.mssql_files where instance_id = $iid and database_name = '$DB' order by file_id")
[ "$GOT_DEF" = "$WANT_DEF" ] || { echo "$GOT_DEF" | sed 's/^/    /'; fail "A: the stored maximum, growth, filegroup or type is not what CREATE DATABASE asked for"; }
[ "$(q "select count(*) filter (where used_read) || '|' || count(*) filter (where used_note is not null) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'")" = "3|0" ] || fail "A: used_read"
[ "$(q "select string_agg(growth_pct::text, ',' order by file_id) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'")" = "0,0,10" ] \
  || fail "A: growth per cent by file: $(q "select string_agg(growth_pct::text, ',' order by file_id) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'")"
IFS='|' read -r MOUNT TOTAL FREE <<<"$(sq "SELECT ISNULL(vs.volume_mount_point, '') + '|' + CAST(vs.total_bytes AS varchar(20)) + '|' + CAST(vs.available_bytes AS varchar(20)) FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs WHERE mf.database_id = DB_ID('$DB') AND mf.file_id = 1")"
WANTVOL=${MOUNT:-$DATADIR}
echo "  sa reads the volume: mount point '${MOUNT}' (the files' directory $DATADIR), total $TOTAL, free $FREE"
[ "$(q "select count(distinct volume) || '|' || min(volume) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'")" = "1|$WANTVOL" ] \
  || fail "A: the files' volume: $(q "select distinct volume from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'") (want $WANTVOL)"
[ "$(q "select (total_bytes = $TOTAL) || '|' || (abs(free_bytes - $FREE) < 0.02 * $TOTAL) || '|' || (files >= 3) from pgvigil.mssql_volumes where instance_id=$iid and volume='$WANTVOL' and is_present")" = "true|true|true" ] \
  || fail "A: the volume row: $(q "select total_bytes, free_bytes, files from pgvigil.mssql_volumes where instance_id=$iid and volume='$WANTVOL'")"
[ "$(q "select count(*) from pgvigil.mssql_volume_sample where instance_id=$iid and volume='$WANTVOL'")" = 1 ] || fail "A: the volume sample"
# the log file is the row without a filegroup (the server may make it larger than asked: its size is sa's read)
SADATA=$(echo "$SA" | awk -F'|' '$7 != "" { n += $2 } END { print n }'); SALOG=$(echo "$SA" | awk -F'|' '$7 == "" { n += $2 } END { print n }')
[ "$SADATA" = "$((24 * 1048576))" ] || fail "A: sa's data files hold $SADATA bytes, not the 24 MB the proof created"
[ "$(q "select data_bytes || '|' || log_bytes || '|' || files || '|' || (data_used_bytes is not null) from pgvigil.mssql_database_size where instance_id=$iid and database_name='$DB'")" = "$SADATA|$SALOG|3|true" ] \
  || fail "A: mssql_database_size: $(q "select data_bytes, log_bytes, files, data_used_bytes from pgvigil.mssql_database_size where instance_id=$iid and database_name='$DB'")"
ST=$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='mssql_storage'")
[ "$ST" = ok ] || [ "$ST" = partial ] || fail "A: collection_dates says $ST"
[ "$ST" = ok ] || echo "  note: the run is partial on this server: $(q "select note from pgvigil.collection_dates where instance_id=$iid and collection='mssql_storage'")"
echo "A: OK"

echo "--- B. a database the login cannot enter is kept, used not read"
SAC=$(sq "SELECT CAST(file_id AS varchar(10)) + '|' + CAST(CAST(size AS bigint) * 8192 AS varchar(20)) FROM sys.master_files WHERE database_id = DB_ID('$DBC') ORDER BY file_id")
[ "$(q "select file_id || '|' || size_bytes from pgvigil.mssql_files where instance_id=$iid and database_name='$DBC' order by file_id")" = "$SAC" ] || fail "B: the closed database's files"
[ "$(q "select count(*) || '|' || count(*) filter (where not used_read and used_bytes is null and used_note like 'used not read: the login cannot enter%') from pgvigil.mssql_files where instance_id=$iid and database_name='$DBC'")" = "2|2" ] \
  || fail "B: used not read: $(q "select used_read, used_bytes, used_note from pgvigil.mssql_files where instance_id=$iid and database_name='$DBC'")"
[ "$(q "select (data_used_bytes is null) || '|' || (data_bytes > 0) from pgvigil.mssql_database_size where instance_id=$iid and database_name='$DBC'")" = "true|true" ] || fail "B: the closed database's size row"
echo "B: OK"

echo "--- C. a grown file is larger on the next run, one growth short of its maximum"
finding() { q "select severity from pgvigil.mssql_storage_findings where instance_id=$iid and check_name='$1' and object='$DB: pv_data1'"; }
# nfind <instance> <check>: how many findings of that name the instance has (a count: a failed query is not 'none')
nfind() { q "select count(*) from pgvigil.mssql_storage_findings where instance_id=$1 and check_name='$2'"; }
[ "$(nfind "$iid" 'a file within one growth of its max size')|$(nfind "$iid" 'a file at its max size')" = "0|0" ] || fail "C: a max size finding before the growth"
sq "ALTER DATABASE [$DB] MODIFY FILE (NAME = pv_data1, SIZE = 56MB);"
sleep 1
collect mssql_storage >/dev/null
[ "$(q "select size_bytes || '|' || previous_size_bytes || '|' || (size_changed_at = snapshot_at) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB' and file_id=1")" = "$((56 * 1048576))|$((16 * 1048576))|true" ] \
  || fail "C: the grown file: $(q "select size_bytes, previous_size_bytes, size_changed_at, snapshot_at from pgvigil.mssql_files where instance_id=$iid and database_name='$DB' and file_id=1")"
[ "$(q "select count(*) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB' and file_id<>1 and size_changed_at is not null")" = 0 ] || fail "C: a file that did not grow is marked changed"
[ "$(q "select string_agg(data_bytes::text, ',' order by snapshot_at) from pgvigil.mssql_database_size where instance_id=$iid and database_name='$DB'")" = "$((24 * 1048576)),$((64 * 1048576))" ] \
  || fail "C: the sizes over time: $(q "select string_agg(data_bytes::text, ',' order by snapshot_at) from pgvigil.mssql_database_size where instance_id=$iid and database_name='$DB'")"
[ "$(finding 'a file within one growth of its max size')" = warning ] || fail "C: the 'within one growth' finding"
echo "C: OK"

echo "--- D. at its maximum"
sq "ALTER DATABASE [$DB] MODIFY FILE (NAME = pv_data1, SIZE = 64MB);"
sleep 1
collect mssql_storage >/dev/null
[ "$(finding 'a file at its max size')|$(nfind "$iid" 'a file within one growth of its max size')" = "critical|0" ] || fail "D: $(q "select severity, check_name, detail from pgvigil.mssql_storage_findings where instance_id=$iid and object like '$DB:%'")"
echo "  $(q "select detail from pgvigil.mssql_storage_findings where instance_id=$iid and check_name='a file at its max size' and object='$DB: pv_data1'")"
echo "D: OK"

echo "--- E. a removed file is marked gone"
sq "ALTER DATABASE [$DB] REMOVE FILE pv_data2;"
sleep 1
collect mssql_storage >/dev/null
[ "$(q "select string_agg(file_id || ':' || is_present, ',' order by file_id) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'")" = "1:true,2:true,3:false" ] \
  || fail "E: $(q "select string_agg(file_id || ':' || is_present, ',' order by file_id) from pgvigil.mssql_files where instance_id=$iid and database_name='$DB'")"
echo "E: OK"

echo "--- F. a login without VIEW SERVER STATE"
collect mssql_storage "$N2"
grep -q "partial: sys.dm_os_volume_stats" "$OUT" || fail "F: the run does not say partial for the volumes"
bid=$(q "select instance_id from pgvigil.instances where name='$N2'")
[ "$(q "select (count(*) >= 4) from pgvigil.mssql_files where instance_id=$bid and database_name in ('$DB', '$DBC')")|$(q "select count(*) from pgvigil.mssql_volumes where instance_id=$bid")|$(q "select count(*) from pgvigil.mssql_files where instance_id=$bid and volume is not null")" = "t|0|0" ] \
  || fail "F: files of the proof's databases $(q "select count(*) from pgvigil.mssql_files where instance_id=$bid and database_name in ('$DB', '$DBC')") (want 4 or more), volumes $(q "select count(*) from pgvigil.mssql_volumes where instance_id=$bid") (want 0), files with a volume $(q "select count(*) from pgvigil.mssql_files where instance_id=$bid and volume is not null") (want 0)"
collect mssql_versionstore "$N2"
grep -q "skipped: the login lacks VIEW SERVER STATE" "$OUT" || fail "F: mssql_versionstore was not skipped with the missing right"
echo "F: OK"

echo "--- G. the import functions refuse a PostgreSQL instance"
pid=$(q "select pgvigil.ensure_instance('$NP', 'onprem', 'x', 170000, false, '{}')")
for fn in import_mssql_storage import_mssql_versionstore import_mssql_actions_log; do
  if q "select pgvigil.$fn($pid, now(), '[]'::jsonb)" >"$OUT" 2>&1; then fail "G: $fn accepted a PostgreSQL instance"; fi
  grep -q "is not a SQL Server instance" "$OUT" || { cat "$OUT"; fail "G: $fn: the refusal's text"; }
done
echo "G: OK"

echo "--- H. the findings' thresholds on imported rows"
sid=$(q "select pgvigil.ensure_instance('proof-mssql-synth-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
GI=$((1024 * 1024 * 1024))
q "select pgvigil.import_mssql_storage($sid, now(), '[
  {\"kind\":\"volume\",\"volume\":\"E:\\\\\",\"total_bytes\":$((100 * GI)),\"free_bytes\":$((8 * GI)),\"files\":2},
  {\"kind\":\"volume\",\"volume\":\"F:\\\\\",\"total_bytes\":$((100 * GI)),\"free_bytes\":$((4 * GI)),\"files\":1},
  {\"kind\":\"volume\",\"volume\":\"G:\\\\\",\"total_bytes\":$((100 * GI)),\"free_bytes\":$((50 * GI)),\"files\":1},
  {\"kind\":\"file\",\"database_id\":5,\"database_name\":\"big\",\"database_state\":\"ONLINE\",\"file_id\":1,\"file_name\":\"big_data\",\"type_desc\":\"ROWS\",\"physical_name\":\"E:\\\\big.mdf\",\"size_bytes\":$((20 * GI)),\"used_read\":0,\"growth_bytes\":0,\"growth_pct\":10,\"volume\":\"E:\\\\\"},
  {\"kind\":\"file\",\"database_id\":5,\"database_name\":\"big\",\"database_state\":\"ONLINE\",\"file_id\":2,\"file_name\":\"big_log\",\"type_desc\":\"LOG\",\"physical_name\":\"E:\\\\big.ldf\",\"size_bytes\":$((1 * GI)),\"used_read\":0,\"growth_bytes\":$((64 * 1048576)),\"growth_pct\":0,\"volume\":\"E:\\\\\"},
  {\"kind\":\"file\",\"database_id\":6,\"database_name\":\"loggy\",\"database_state\":\"ONLINE\",\"file_id\":1,\"file_name\":\"loggy_data\",\"type_desc\":\"ROWS\",\"physical_name\":\"F:\\\\loggy.mdf\",\"size_bytes\":$((1 * GI)),\"used_read\":0,\"growth_bytes\":$((64 * 1048576)),\"growth_pct\":0,\"volume\":\"F:\\\\\"},
  {\"kind\":\"file\",\"database_id\":6,\"database_name\":\"loggy\",\"database_state\":\"ONLINE\",\"file_id\":2,\"file_name\":\"loggy_log\",\"type_desc\":\"LOG\",\"physical_name\":\"G:\\\\loggy.ldf\",\"size_bytes\":$((2 * GI)),\"used_read\":0,\"growth_bytes\":$((64 * 1048576)),\"growth_pct\":0,\"volume\":\"G:\\\\\"}
 ]'::jsonb)" >/dev/null
WANT_H='critical|a volume under 10 % free|F:\
info|a log file larger than its data files|loggy
info|a percentage growth on a file over 10 GB|big: big_data
warning|a volume under 10 % free|E:\'
GOT_H=$(q "select severity || '|' || check_name || '|' || object from pgvigil.mssql_storage_findings where instance_id=$sid order by 1")
[ "$GOT_H" = "$WANT_H" ] || { echo "$GOT_H"; fail "H: the findings differ"; }
echo "H: OK"

echo "--- V. the version store: a holder, a writer, two reads, then the commit"
collect mssql_versionstore >/dev/null
[ "$(q "select count(*) || '|' || count(generation_kb_s) from pgvigil.mssql_versionstore_sample where instance_id=$iid")" = "1|0" ] || fail "V: the first read (one row, no rate yet)"
# the holder: its session id on record, then a snapshot transaction held open for 50 s; the marker is in its batch
sq1 "INSERT dbo.pv_holder (spid, started) VALUES (@@SPID, SYSUTCDATETIME()); SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRANSACTION; SELECT COUNT(*) FROM dbo.pv_rows /* pgvproof-holder-$SUF */; WAITFOR DELAY '00:00:50'; COMMIT;" "$DB" >/dev/null &
BG+=($!)
sleep 4
HSPID=$(sq "SELECT spid FROM dbo.pv_holder" "$DB")
[ -n "$HSPID" ] || fail "V: the holder did not start"
# the writer: 1000 rows of 4 KB rewritten every second for 25 s, each pass about 4 MB of row versions
sq1 "DECLARE @i int = 0; WHILE @i < 25 BEGIN UPDATE dbo.pv_rows SET pad = CAST(@i AS char(4000)); SET @i += 1; WAITFOR DELAY '00:00:01'; END" "$DB" >/dev/null &
BG+=($!)
sleep 6
collect mssql_versionstore >/dev/null
sleep 12
collect mssql_versionstore >/dev/null
q "select snapshot_at, reserved_bytes, store_bytes, generation_kb_s, cleanup_kb_s, holder_session_id, holder_login, holder_elapsed_s, left(holder_statement, 60) from pgvigil.mssql_versionstore_sample where instance_id=$iid order by snapshot_at" | sed 's/^/  /'
R=$(q "select string_agg(reserved_bytes::text, ' ' order by snapshot_at) from pgvigil.mssql_versionstore_sample where instance_id=$iid")
read -r R0 R1 R2 <<<"$R"
[ "$R2" -gt "$R1" ] && [ "$R1" -gt "$R0" ] || fail "V: the store did not rise across the reads: $R"
[ "$(q "select (generation_kb_s > 0) from pgvigil.mssql_versionstore_sample where instance_id=$iid order by snapshot_at desc limit 1")" = t ] || fail "V: no generation rate on the last read"
[ "$(q "select count(*) from pgvigil.mssql_versionstore_sample where instance_id=$iid and holder_session_id = $HSPID and holder_login = '$L1' and holder_is_snapshot and holder_statement like '%pgvproof-holder-$SUF%' and holder_database = '$DB'")" = 2 ] \
  || fail "V: the holder is not named on both reads (session $HSPID, login $L1)"
HSTART=$(sq "SELECT CONVERT(varchar(19), started, 126) FROM dbo.pv_holder" "$DB")
[ "$(q "select bool_and(abs(extract(epoch from holder_started_at - '${HSTART}Z'::timestamptz)) < 90 and holder_elapsed_s between 1 and 60) from pgvigil.mssql_versionstore_sample where instance_id=$iid and holder_session_id = $HSPID")" = t ] \
  || fail "V: the holder's start or elapsed time: $(q "select holder_started_at, holder_elapsed_s from pgvigil.mssql_versionstore_sample where instance_id=$iid and holder_session_id = $HSPID") against $HSTART"
[ "$(q "select (reserved_bytes > 0) from pgvigil.mssql_versionstore_db where instance_id=$iid and database_name='$DB'")" = t ] || fail "V: mssql_versionstore_db does not list the proof's database"
if [ "$MAJ" -ge 15 ]; then
  [ "$(q "select adr_on || '|' || (pvs_bytes >= 0) from pgvigil.mssql_pvs where instance_id=$iid and database_name='$DBC'")" = "true|true" ] || fail "V: mssql_pvs: $(q "select * from pgvigil.mssql_pvs where instance_id=$iid")"
else
  [ "$(q "select count(*) from pgvigil.mssql_pvs where instance_id=$iid")" = 0 ] || fail "V: mssql_pvs holds a row on a server before SQL Server 2019: $(q "select * from pgvigil.mssql_pvs where instance_id=$iid")"
  echo "  SQL Server $MAJ.x: no accelerated database recovery before 2019, mssql_pvs is empty as it must be"
fi
echo "  the holder commits (50 s after it started); cleanup runs once a minute"
wait "${BG[0]}" || fail "V: the holder's batch failed"
wait "${BG[1]}" || fail "V: the writer's batch failed"
BG=()
FELL=
for _ in $(seq 1 18); do
  sleep 10
  collect mssql_versionstore >/dev/null
  IFS='|' read -r RN HN <<<"$(q "select reserved_bytes || '|' || coalesce(holder_session_id::text, '') from pgvigil.mssql_versionstore_sample where instance_id=$iid order by snapshot_at desc limit 1")"
  if [ "$RN" -lt "$R2" ] && [ "$HN" != "$HSPID" ]; then FELL=1; break; fi
done
[ -n "$FELL" ] || fail "V: three minutes after the commit the store is $RN (was $R2) and the holder is '$HN'"
echo "  after the commit: the store fell from $R2 to $RN bytes, the holder row is ${HN:-gone}"
echo "V: OK"

echo "--- W. the version store findings on imported rows"
vs() { # minutes ago, reserved KB, generation raw, cleanup raw, holder (1|0)
  local h=''
  [ "$5" = 1 ] && h=",{\"kind\":\"holder\",\"session_id\":77,\"login_name\":\"app_login\",\"host_name\":\"apphost\",\"program_name\":\"the app\",\"database_name\":\"sales\",\"is_snapshot\":1,\"started_at_utc\":\"2026-01-01T00:00:00Z\",\"elapsed_s\":3600,\"statement\":\"SELECT held FROM dbo.orders\"}"
  q "select pgvigil.import_mssql_versionstore($sid, now() - interval '$1 minutes', '[{\"kind\":\"store\",\"store_kb\":$2,\"reserved_kb\":$2,\"tempdb_data_kb\":8388608,\"generation_raw_kb\":$3,\"cleanup_raw_kb\":$4,\"snapshot_tx_count\":$5}$h]'::jsonb)" >/dev/null
}
vfind() { q "select severity || '|' || detail from pgvigil.mssql_storage_findings where instance_id=$sid and check_name='$1'"; }
for m in 10 9 8 7 6 5 4 3 2 1; do vs "$m" $(( (11 - m) * 10240 )) $(( (11 - m) * 10240 )) 500 1; done
[ "$(nfind "$sid" 'the version store grows while cleanup is at zero')" = 0 ] || fail "W: the finding before ten minutes of reads"
vs 0 $((11 * 10240)) $((11 * 10240)) 500 1
D=$(vfind 'the version store grows while cleanup is at zero')
echo "  $D"
case "$D" in "warning|"*"session 77 (app_login, the app)"*"open for 3600 s"*"SELECT held FROM dbo.orders"*) ;; *) fail "W: the grows-while-cleanup-is-at-zero finding or its holder detail";; esac
[ "$(nfind "$sid" 'the version store over a third of tempdb')" = 0 ] || fail "W: a third-of-tempdb finding at 110 MB of 8 GB"
q "select pgvigil.import_mssql_versionstore($sid, now() + interval '20 seconds', '[{\"kind\":\"store\",\"store_kb\":3145728,\"reserved_kb\":3145728,\"tempdb_data_kb\":8388608,\"generation_raw_kb\":$((12 * 10240)),\"cleanup_raw_kb\":9000,\"snapshot_tx_count\":0}]'::jsonb)" >/dev/null
[ "$(nfind "$sid" 'the version store grows while cleanup is at zero')" = 0 ] || fail "W: the finding stayed after cleanup moved"
case "$(vfind 'the version store over a third of tempdb')" in "warning|"*"3072 MB"*"(37.5 %)"*) ;; *) fail "W: the third-of-tempdb finding: $(vfind 'the version store over a third of tempdb')";; esac
pvs() { q "select pgvigil.import_mssql_versionstore($sid, now() + interval '$1 seconds', '[{\"kind\":\"pvs\",\"database_name\":\"sales\",\"adr_on\":1,\"pvs_kb\":2097152,\"online_index_kb\":0,\"aborted_tx_count\":$2,\"oldest_active_tx_id\":0,\"oldest_aborted_tx_id\":0},{\"kind\":\"pvs\",\"database_name\":null}]'::jsonb)" >/dev/null; }
pvs 21 0
[ "$(nfind "$sid" 'the persistent version store over its threshold with aborted transactions')" = 0 ] || fail "W: a persistent version store finding without aborted transactions"
pvs 22 3
case "$(vfind 'the persistent version store over its threshold with aborted transactions')" in "warning|"*"2048 MB with 3 aborted"*) ;; *) fail "W: the persistent version store finding";; esac
echo "W: OK"

echo "--- X. the imports under a retry and out of order"
xid=$(q "select pgvigil.ensure_instance('proof-mssql-retry-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
XT=$(q "select date_trunc('second', now())")
for _ in 1 2; do
  q "select pgvigil.import_mssql_storage($xid, '$XT', '[{\"kind\":\"volume\",\"volume\":\"/data/\",\"total_bytes\":1000,\"free_bytes\":400,\"files\":1},
     {\"kind\":\"file\",\"database_id\":5,\"database_name\":\"one\",\"database_state\":\"ONLINE\",\"file_id\":1,\"file_name\":\"one_data\",\"type_desc\":\"ROWS\",\"size_bytes\":100,\"used_read\":0,\"growth_bytes\":0,\"growth_pct\":0,\"volume\":\"/data/\"}]'::jsonb)" >/dev/null
  q "select pgvigil.import_mssql_versionstore($xid, '$XT', '[{\"kind\":\"store\",\"store_kb\":10,\"reserved_kb\":10,\"tempdb_data_kb\":1000,\"generation_raw_kb\":5,\"cleanup_raw_kb\":5,\"snapshot_tx_count\":0}]'::jsonb)" >/dev/null
done
[ "$(q "select (select count(*) from pgvigil.mssql_database_size where instance_id=$xid) || '|' || (select count(*) from pgvigil.mssql_volume_sample where instance_id=$xid) || '|' || (select count(*) from pgvigil.mssql_versionstore_sample where instance_id=$xid) || '|' || (select count(*) from pgvigil.mssql_files where instance_id=$xid)")" = "1|1|1|1" ] \
  || fail "X: a payload imported twice left $(q "select (select count(*) from pgvigil.mssql_database_size where instance_id=$xid), (select count(*) from pgvigil.mssql_volume_sample where instance_id=$xid), (select count(*) from pgvigil.mssql_versionstore_sample where instance_id=$xid)") rows (size, volume, version store), want 1 each"
# a newer read that lists no database (the markers only), then an older payload with rows: the state stays empty
q "select pgvigil.import_mssql_versionstore($xid, '$XT'::timestamptz + interval '2 minutes', '[{\"kind\":\"store\",\"store_kb\":10,\"reserved_kb\":10,\"tempdb_data_kb\":1000,\"generation_raw_kb\":6,\"cleanup_raw_kb\":6,\"snapshot_tx_count\":0},{\"kind\":\"db\",\"database_name\":null},{\"kind\":\"pvs\",\"database_name\":null}]'::jsonb)" >/dev/null
q "select pgvigil.import_mssql_versionstore($xid, '$XT'::timestamptz + interval '1 minute', '[{\"kind\":\"store\",\"store_kb\":10,\"reserved_kb\":10,\"tempdb_data_kb\":1000,\"generation_raw_kb\":5,\"cleanup_raw_kb\":5,\"snapshot_tx_count\":0},{\"kind\":\"db\",\"database_name\":\"stale\",\"reserved_kb\":99},{\"kind\":\"pvs\",\"database_name\":\"stale\",\"adr_on\":1,\"pvs_kb\":4194304,\"online_index_kb\":0,\"aborted_tx_count\":9}]'::jsonb)" >/dev/null
[ "$(q "select (select count(*) from pgvigil.mssql_versionstore_db where instance_id=$xid) || '|' || (select count(*) from pgvigil.mssql_pvs where instance_id=$xid) || '|' || (select count(*) from pgvigil.mssql_versionstore_sample where instance_id=$xid)")" = "0|0|3" ] \
  || fail "X: an older payload put its per-database rows back: $(q "select (select count(*) from pgvigil.mssql_versionstore_db where instance_id=$xid), (select count(*) from pgvigil.mssql_pvs where instance_id=$xid), (select count(*) from pgvigil.mssql_versionstore_sample where instance_id=$xid)")"
echo "X: OK"

echo "--- Y. two instances import at once, one of them opening a new month on every call"
ya=$(q "select pgvigil.ensure_instance('proof-mssql-ya-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
yb=$(q "select pgvigil.ensure_instance('proof-mssql-yb-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
YP='[{"kind":"volume","volume":"/data/","total_bytes":1000,"free_bytes":400,"files":1},{"kind":"file","database_id":5,"database_name":"one","database_state":"ONLINE","file_id":1,"file_name":"one_data","type_desc":"ROWS","size_bytes":100,"used_read":0,"growth_bytes":0,"growth_pct":0,"volume":"/data/"}]'
YA=$(mktemp); YB=$(mktemp)
( for k in $(seq 1 60); do echo "select pgvigil.import_mssql_storage($ya, now() + interval '$k seconds', '$YP'::jsonb);"; done | psql "$PGVIGIL_REPO_DSN" -XAtq >"$YA" 2>&1 ) &
( for k in $(seq 1 60); do echo "select pgvigil.import_mssql_storage($yb, now() + interval '$k months', '$YP'::jsonb);"; done | psql "$PGVIGIL_REPO_DSN" -XAtq >"$YB" 2>&1 ) &
wait
YE=$(cat "$YA" "$YB" | grep -c ERROR || true); YD=$(cat "$YA" "$YB" | grep ERROR | sort | uniq -c | head -3 || true); rm -f "$YA" "$YB"
[ "$YE" = 0 ] || fail "Y: $YE import(s) failed: $YD"
[ "$(q "select (select count(*) from pgvigil.mssql_volume_sample where instance_id=$ya) || '|' || (select count(*) from pgvigil.mssql_volume_sample where instance_id=$yb) || '|' || (select count(*) from pgvigil.mssql_database_size where instance_id=$yb)")" = "60|60|60" ] || fail "Y: rows stored (want 60|60|60)"
echo "Y: OK"

echo "NOT PROVEN: Windows volumes, SQL Server 2016-2019, Managed Instance, RDS, thousands of databases, a FILESTREAM container"
echo "proof-mssql-storage: PASS (A-H, V, W, X, Y)"
