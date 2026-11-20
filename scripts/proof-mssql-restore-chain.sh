#!/usr/bin/env bash
# Proof of task 304: the restore chain (migration 0147, internal/mssql/restore_chain.go's collection mssql_restore_chain,
# /api/mssql/restore through its wiring: web.go, the summary and the pages).
#
# Needs: docker (its own SQL Server 2022 Developer container, a PowerShell container for dbatools 2.9.1, and with
# PROOF_AG=1 the clusterless group lab scripts/dag/trial.sh), psql, curl, python3, a go toolchain, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form; the proof makes its own database there.
# Optional: PGVIGIL_BIN (default bin/pgvigil), PROOF_SKIP_DBATOOLS=1. Everything it makes goes on every exit path.
#
# Expected (written before the first run). Each chain is read from the store after one mssql_backups and one
# mssql_restore_chain read; 'equal to dbatools' = the same BackupSetID list, in order, as Get-DbaDbBackupHistory -Last
# (-IncludeCopyOnly where the start set is a copy-only full) against the same server:
#  R1  pgvrc1: a full and three logs -> steps full, log, log, log; verdict 'restorable from these backups to <the third log's
#      last_valid_restore_time, else its start, to the minute> UTC; ...' (the time checked, not only the words); equal to
#      dbatools.
#  R2  pgvrc2: a full, two logs, a differential, two logs, a row written before each log -> full, differential, then the
#      logs whose last_lsn passes the differential's (the two after it); equal to dbatools. (Changed after run 304p2: with
#      no write between, msdb's first log after the differential ended at the differential's last_lsn - R2b.)
#  R2b pgvrc2b: a full, a row, a differential and a log right after it with no write between: when msdb's log ends at
#      the differential's last_lsn (304p2: log 344..440, differential ..440) it applies nothing -> steps full,
#      differential; dbatools -Last lists that log too (its last_lsn passes the start's first_lsn) - a difference on
#      purpose, a named row; when the log runs past it this run, steps full, differential, log equal to dbatools and the
#      difference NOT PROVEN that run.
#  R3  pgvrc3: R2's shape (a row before each log) and then a copy-only full, a row and one log -> the start set is the
#      copy-only full (F1), then the log;
#      equal to dbatools -Last -IncludeCopyOnly; differs from dbatools' default (which starts at the normal full) - on
#      purpose, a named row.
#  R4  pgvrc4: only a copy-only full, a row, a log -> steps copy_full, log; equal to dbatools -IncludeCopyOnly; dbatools'
#      default lists nothing (no full that is not copy-only) - a difference on purpose, a named row. (Added after run
#      304p4 stopped in the backups with no message: if SQL Server refuses a log backup after a copy-only full alone -
#      Msg 4214, the design pass's open question - the row prints the refusal and expects steps copy_full with
#      'restorable to the full of <t> UTC only'.)
#  R5  pgvrc5: a full and three logs, the second log's msdb rows deleted by hand -> steps full, log 1; verdict 'broken
#      before the log of ...; restorable to <log 1's restore time> UTC'; the finding 'the log chain is broken' (warning);
#      dbatools -Last lists the full and logs 1 and 3 and names no gap.
#  R6  pgvrc6: a full, a log, a log to NUL, a log -> steps full, log 1; verdict 'went to NUL at ...'; gaps on this server
#      0 (a NUL log is a hole, the log after it no gap).
#  R7  pgvrc7: a full striped over 3 files and a log over 2 -> the files part lists 3 and 2 paths for the two steps.
#  R8  pgvrc8: a full and a log into one file (NOINIT) -> the log step's media_position 2, its mark 'file 2 of its media'.
#  R9  pgvrc9: a full and a copy-only log -> the copy-only log is no step (F7); dbatools' default drops it too.
#  R10 the API: /api/mssql/restore?instance=&db=pgvrc2 answers the steps with first_lsn and last_lsn as JSON strings of
#      up to 25 digits (F5), equal to msdb's; the databases part lists pgvrc5 'broken' first.
#  R11 pgvrc11, a restore over the database: full A, a row, log 1, rows, log 2, rows, a safety COPY-ONLY full S (its
#      last_lsn the greatest), then RESTORE ... FROM A WITH REPLACE, RECOVERY (create_date, database_guid and the forks
#      printed before and after), a row, log 3 -> R11a: steps full (A), log (log 3) - the parent fork's full up to the
#      fork point and the new fork's log, verdict 'restorable from these backups'; then a new full N, a row, log 4 ->
#      R11b: steps full (N), log (log 4), S in no step; N's last_lsn below S's printed (the overlapping LSNs the fork
#      rule is for; if N's is not below, the row says so); equal to dbatools.
#  R14 pgvrc14: a full and a log, then both restored on the same server as pgvrc14c: msdb's backup_set_uuid seen twice
#      printed; the read whole (no error); pgvrc14's steps full, log, each set stored once.
#  R15 SQL Server 2019 (its own container, pgvrc-19): a full and two logs with rows -> steps full, log, log; the verdict's
#      time the last log's START to the minute (2019 has no last_valid_restore_time).
#  R16 pgvrc16 in SIMPLE recovery: a full, a row, a differential -> steps full, diff; verdict 'restorable to the
#      differential of <t> UTC only'.
#  R17 pgvrc17: a full and a log read, then the database dropped and created again, a full and a log -> steps full, log
#      of the new sets only; 2 sets stored; equal to dbatools.
#  R18 pgvrc18: a full, a row, a log, a full to NUL, a row, a log -> steps full, log, log; step 1 marked 'a newer full
#      went to NUL at ...'.
#  R13 (PROOF_AG=1) the group lab: a full on d1a, a log on d1b, a log on d1a -> from either instance one chain full, log,
#      log with 'ran on' d1a, d1b, d1a; without PROOF_AG or the lab refused: NOT PROVEN live.
#  R13b (F3's read skew) a log on d1b, then a log on d1a, d1a read alone -> from d1a the chain held 'not yet read from
#      pgvrc-ag-d1b'; then d1b read -> whole, five steps d1a, d1b, d1a, d1b, d1a.
#  R13c three logs on d1a, the middle one's msdb rows deleted by hand, both read -> held 'not judged (the distributed
#      availability group dag1...' (the lab's ag1 is in dag1), state held, no finding for dagdb.
#  R12 LAST (it reads with a cap): pgvrc12, a full and five logs with rows; PGVIGIL_RESTORE_LOG_KEEP=3 for one read ->
#      logs since 5, sent 3, verdict 'not read whole: ...', state held, no finding; the API says capped.
#  NOT PROVEN HERE: a forced failover's new recovery fork on a live pair (the store test holds the fork rule), a snapshot
#  or virtual-device full (the store test's stored rows hold the marks), SQL Server 2025's secondary fulls, RDS, Managed
#  Instance, a distributed group's other side (never merged: its gaps are held).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of a PostgreSQL sandbox}"
# a password in the DSN goes to PGPASSWORD, never onto psql's command line (ps shows it); a quoted password is not handled
if [[ " $PGVIGIL_REPO_DSN" =~ [[:space:]]password=([^[:space:]]+) ]]; then
  export PGPASSWORD="${BASH_REMATCH[1]}"; PGVIGIL_REPO_DSN=$(printf '%s' " $PGVIGIL_REPO_DSN" | sed -E 's/[[:space:]]password=[^[:space:]]+//; s/^ //')
fi
SUF=$RANDOM; NET=pgvrc-net-$SUF; SQL=pgvrc-22-$SUF; SQL19=pgvrc-19-$SUF; PS=pgvrc-ps-$SUF; REPO_DB=pgvigil_rcproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
pw() { printf 'Pv9%s!a' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); PM=$(pw); export SAPW SQLCMDPASSWORD="$SAPW"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
MADE_DB=; SRVPID=; AGTAG=
cleanup() {
  rc=$?; set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  docker rm -f -v "$SQL" "$SQL19" "$PS" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
  [ -n "$AGTAG" ] && bash scripts/dag/trial.sh down "$AGTAG" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_REPO_DSN" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$WORK"; echo "left: containers $(docker ps -aq --filter "name=pgvrc-.*-$SUF" | wc -l)"; exit $rc
}
trap cleanup EXIT
sq() { docker exec -e SQLCMDPASSWORD "${C:-$SQL}" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
up() { for _ in $(seq 1 90); do [ "$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" 2>/dev/null | tr -d '\r ')" = 1 ] && return 0; sleep 2; done; return 1; }
s19() { C=$SQL19 sq "$@"; }
RDSN=$(printf '%s' "$PGVIGIL_REPO_DSN" | sed -E "s/dbname=[^ ]+/dbname=$REPO_DB/"); [[ "$RDSN" == *"dbname=$REPO_DB"* ]] || RDSN="$PGVIGIL_REPO_DSN dbname=$REPO_DB"
q() { psql "$RDSN" -XAtqc "$1"; }

echo "== containers and the store"
docker network create "$NET" >/dev/null
printf 'ACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_SA_PASSWORD=%s\n' "$SAPW" > "$WORK/sql.env"; chmod 600 "$WORK/sql.env"
docker run -d --name "$SQL" --label pgvigil-proof=inv304 --network "$NET" --network-alias sql22 --env-file "$WORK/sql.env" -p 127.0.0.1::1433 mcr.microsoft.com/mssql/server:2022-latest >/dev/null
docker run -d --name "$SQL19" --label pgvigil-proof=inv304 --network "$NET" --env-file "$WORK/sql.env" -p 127.0.0.1::1433 mcr.microsoft.com/mssql/server:2019-latest >/dev/null
up || fail "SQL Server did not come up"
C=$SQL19 up || fail "SQL Server 2019 did not come up"
P22=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); P19=$(docker port "$SQL19" 1433/tcp | head -1 | sed 's/.*://')
printf "CREATE LOGIN pgvrc_mon WITH PASSWORD = N'%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvrc_mon; GRANT VIEW ANY DEFINITION TO pgvrc_mon;\n" "$PM" \
  | docker exec -i -e SQLCMDPASSWORD "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -d master -i /dev/stdin >/dev/null
sq "CREATE USER pgvrc_mon FOR LOGIN pgvrc_mon; ALTER ROLE db_datareader ADD MEMBER pgvrc_mon;" msdb >/dev/null
printf "CREATE LOGIN pgvrc_mon WITH PASSWORD = N'%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvrc_mon; GRANT VIEW ANY DEFINITION TO pgvrc_mon;\n" "$PM" \
  | docker exec -i -e SQLCMDPASSWORD "$SQL19" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -d master -i /dev/stdin >/dev/null
s19 "CREATE USER pgvrc_mon FOR LOGIN pgvrc_mon; ALTER ROLE db_datareader ADD MEMBER pgvrc_mon;" msdb >/dev/null
docker exec "$SQL" mkdir -p /var/opt/mssql/bk; docker exec "$SQL19" mkdir -p /var/opt/mssql/bk
for d in pgvrc1 pgvrc2 pgvrc2b pgvrc3 pgvrc4 pgvrc5 pgvrc6 pgvrc7 pgvrc8 pgvrc9 pgvrc11 pgvrc12 pgvrc14 pgvrc17 pgvrc18; do sq "CREATE DATABASE [$d]; ALTER DATABASE [$d] SET RECOVERY FULL;" >/dev/null; done
sq "CREATE DATABASE [pgvrc16]; ALTER DATABASE [pgvrc16] SET RECOVERY SIMPLE;" >/dev/null
s19 "CREATE DATABASE [pgvrc19]; ALTER DATABASE [pgvrc19] SET RECOVERY FULL;" >/dev/null
psql "$PGVIGIL_REPO_DSN" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
export PGVIGIL_REPO_DSN_PROOF="$RDSN" MSSQL_M_DSN="sqlserver://pgvrc_mon:$PM@127.0.0.1:$P22?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_19_DSN="sqlserver://pgvrc_mon:$PM@127.0.0.1:$P19?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN_PROOF
instances:
  - name: pgvrc-m
    engine: sqlserver
    dsn: env:MSSQL_M_DSN
    mssql_thresholds:
      new_database_hours: 0
  - name: pgvrc-19
    engine: sqlserver
    dsn: env:MSSQL_19_DSN
    mssql_thresholds:
      new_database_hours: 0
EOF
[ -x "$BIN" ] || go build -o "$BIN" ./cmd/pgvigil
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT"; return 1; }; }
read2() { collect mssql_backups "${2:-pgvrc-m}" && collect mssql_restore_chain "${2:-pgvrc-m}" || fail "$1: the read: $(cat "$OUT")"; grep -q "skipped\|partial" "$OUT" && fail "$1: $(cat "$OUT")"; return 0; }
I=$(q "select instance_id from pgvigil.instances where name='pgvrc-m'" 2>/dev/null || true)
iid() { [ -n "$I" ] || I=$(q "select instance_id from pgvigil.instances where name='pgvrc-m'"); echo "$I"; }
steps() { q "select string_agg(role || ':' || coalesce(from_instance, ''), ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='$1' and step > 0"; }
ids() { q "select string_agg(s.backup_set_id::text, ',' order by c.step) from pgvigil.mssql_restore_steps c join pgvigil.mssql_restore_sets s on s.backup_set_uuid = c.backup_set_uuid where c.instance_id=$(iid) and c.database_name='$1' and c.step > 0"; }
verdict() { q "select verdict from pgvigil.mssql_restore_verdicts where instance_id=$(iid) and database_name='$1'"; }
bk() { local o; o=$(sq "BACKUP $1 TO DISK = N'/var/opt/mssql/bk/$2' WITH FORMAT${3:-};" 2>&1) || fail "BACKUP $1 to $2: $o"; }
# a statement whose failure stops the proof with SQL Server's message (never a silent set -e exit)
run() { local o; o=$(sq "$@" 2>&1) || fail "the statement failed ($(printf '%s' "$1" | head -c 100)): $o"; }
# one row written in a database: a log backup after it has something to apply
wr() { run "IF OBJECT_ID(N'dbo.pgvrc_w') IS NULL CREATE TABLE dbo.pgvrc_w (i int IDENTITY PRIMARY KEY, at datetime2 DEFAULT SYSDATETIME()); INSERT dbo.pgvrc_w DEFAULT VALUES;" "$1"; }
# a database's newest set of a type (msdb's backup_set_id) and a set's restore time to the minute, as the chain words it
lastid() { sq "SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'$1' AND type = '$2'" | tr -d '\r '; }
rtime() { sq "SELECT FORMAT(COALESCE(last_valid_restore_time, backup_start_date), 'yyyy-MM-dd HH:mm') FROM msdb.dbo.backupset WHERE backup_set_id = $1" | tr -d '\r'; }
roles() { q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='$1' and step > 0"; }
forks() { sq "SELECT d.create_date, rs.database_guid, rs.family_guid, rs.recovery_fork_guid FROM sys.databases d JOIN sys.database_recovery_status rs ON rs.database_id = d.database_id WHERE d.name = N'$1'" | tr -d '\r'; }

echo "== the backups"
bk "DATABASE pgvrc1" r1f.bak; for k in 1 2 3; do bk "LOG pgvrc1" r1l$k.trn; done
bk "DATABASE pgvrc2" r2f.bak; wr pgvrc2; bk "LOG pgvrc2" r2l1.trn; wr pgvrc2; bk "LOG pgvrc2" r2l2.trn; wr pgvrc2; bk "DATABASE pgvrc2" r2d.bak ", DIFFERENTIAL"
wr pgvrc2; bk "LOG pgvrc2" r2l3.trn; wr pgvrc2; bk "LOG pgvrc2" r2l4.trn
bk "DATABASE pgvrc2b" r2bf.bak; wr pgvrc2b; bk "DATABASE pgvrc2b" r2bd.bak ", DIFFERENTIAL"; bk "LOG pgvrc2b" r2bl.trn
bk "DATABASE pgvrc3" r3f.bak; wr pgvrc3; bk "LOG pgvrc3" r3l1.trn; wr pgvrc3; bk "DATABASE pgvrc3" r3d.bak ", DIFFERENTIAL"; wr pgvrc3; bk "LOG pgvrc3" r3l2.trn
wr pgvrc3; bk "DATABASE pgvrc3" r3c.bak ", COPY_ONLY"; wr pgvrc3; bk "LOG pgvrc3" r3l3.trn
bk "DATABASE pgvrc5" r5f.bak; for k in 1 2 3; do bk "LOG pgvrc5" r5l$k.trn; done
GONE=$(sq "SELECT backup_set_id FROM msdb.dbo.backupset WHERE database_name = N'pgvrc5' AND type = 'L' ORDER BY backup_set_id OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY")
sq "DECLARE @m int = (SELECT media_set_id FROM msdb.dbo.backupset WHERE backup_set_id = $GONE);
    DELETE FROM msdb.dbo.backupfilegroup WHERE backup_set_id = $GONE; DELETE FROM msdb.dbo.backupfile WHERE backup_set_id = $GONE;
    DELETE FROM msdb.dbo.restorefile WHERE restore_history_id IN (SELECT restore_history_id FROM msdb.dbo.restorehistory WHERE backup_set_id = $GONE);
    DELETE FROM msdb.dbo.restorehistory WHERE backup_set_id = $GONE; DELETE FROM msdb.dbo.backupset WHERE backup_set_id = $GONE;
    DELETE FROM msdb.dbo.backupmediafamily WHERE media_set_id = @m; DELETE FROM msdb.dbo.backupmediaset WHERE media_set_id = @m;" msdb >/dev/null
bk "DATABASE pgvrc6" r6f.bak; bk "LOG pgvrc6" r6l1.trn; sq "BACKUP LOG pgvrc6 TO DISK = N'NUL';" >/dev/null; bk "LOG pgvrc6" r6l3.trn
sq "BACKUP DATABASE pgvrc7 TO DISK = N'/var/opt/mssql/bk/r7a.bak', DISK = N'/var/opt/mssql/bk/r7b.bak', DISK = N'/var/opt/mssql/bk/r7c.bak' WITH FORMAT;
    BACKUP LOG pgvrc7 TO DISK = N'/var/opt/mssql/bk/r7la.trn', DISK = N'/var/opt/mssql/bk/r7lb.trn' WITH FORMAT;" >/dev/null
sq "BACKUP DATABASE pgvrc8 TO DISK = N'/var/opt/mssql/bk/r8.bak' WITH FORMAT; BACKUP LOG pgvrc8 TO DISK = N'/var/opt/mssql/bk/r8.bak' WITH NOINIT;" >/dev/null
bk "DATABASE pgvrc9" r9f.bak; bk "LOG pgvrc9" r9c.trn ", COPY_ONLY"
bk "DATABASE pgvrc4" r4c.bak ", COPY_ONLY"; wr pgvrc4
R4L=; R4MSG=$(sq "BACKUP LOG pgvrc4 TO DISK = N'/var/opt/mssql/bk/r4l.trn' WITH FORMAT;" 2>&1) && R4L=1
# R11 part a: a safety copy-only full after the rows, then a restore over the database from the first full, a row, a log
bk "DATABASE pgvrc11" r11a.bak; wr pgvrc11; bk "LOG pgvrc11" r11l1.trn; for k in 1 2 3; do wr pgvrc11; done; bk "LOG pgvrc11" r11l2.trn
for k in 1 2 3; do wr pgvrc11; done; bk "DATABASE pgvrc11" r11s.bak ", COPY_ONLY"; R11S=$(lastid pgvrc11 D)
echo "     R11 before the restore: $(forks pgvrc11)"
run "RESTORE DATABASE pgvrc11 FROM DISK = N'/var/opt/mssql/bk/r11a.bak' WITH REPLACE, RECOVERY;"
echo "     R11 after the restore:  $(forks pgvrc11)"
wr pgvrc11; bk "LOG pgvrc11" r11l3.trn
R11A=$(sq "SELECT backup_set_id FROM msdb.dbo.backupset WHERE database_name = N'pgvrc11' AND type = 'D' AND is_copy_only = 0 ORDER BY backup_set_id OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY" | tr -d '\r '); R11L3=$(lastid pgvrc11 L)
bk "DATABASE pgvrc12" r12f.bak; for k in 1 2 3 4 5; do wr pgvrc12; bk "LOG pgvrc12" r12l$k.trn; done
bk "DATABASE pgvrc14" r14f.bak; wr pgvrc14; bk "LOG pgvrc14" r14l.trn
run "RESTORE DATABASE pgvrc14c FROM DISK = N'/var/opt/mssql/bk/r14f.bak' WITH MOVE N'pgvrc14' TO N'/var/opt/mssql/data/pgvrc14c.mdf', MOVE N'pgvrc14_log' TO N'/var/opt/mssql/data/pgvrc14c_log.ldf', NORECOVERY;
    RESTORE LOG pgvrc14c FROM DISK = N'/var/opt/mssql/bk/r14l.trn' WITH RECOVERY;"
DUPS=$(sq "SELECT COUNT(*) FROM (SELECT backup_set_uuid FROM msdb.dbo.backupset WHERE database_name = N'pgvrc14' GROUP BY backup_set_uuid HAVING COUNT(*) > 1) x" | tr -d '\r ')
bk "DATABASE pgvrc16" r16f.bak; wr pgvrc16; bk "DATABASE pgvrc16" r16d.bak ", DIFFERENTIAL"
bk "DATABASE pgvrc17" r17a.bak; wr pgvrc17; bk "LOG pgvrc17" r17l.trn
bk "DATABASE pgvrc18" r18f.bak; wr pgvrc18; bk "LOG pgvrc18" r18l1.trn; run "BACKUP DATABASE pgvrc18 TO DISK = N'NUL';"; wr pgvrc18; bk "LOG pgvrc18" r18l2.trn
w19() { C=$SQL19 run "IF OBJECT_ID(N'dbo.pgvrc_w') IS NULL CREATE TABLE dbo.pgvrc_w (i int IDENTITY PRIMARY KEY); INSERT dbo.pgvrc_w DEFAULT VALUES;" pgvrc19; }
C=$SQL19 run "BACKUP DATABASE pgvrc19 TO DISK = N'/var/opt/mssql/bk/r19f.bak' WITH FORMAT;"
for k in 1 2; do w19; C=$SQL19 run "BACKUP LOG pgvrc19 TO DISK = N'/var/opt/mssql/bk/r19l$k.trn' WITH FORMAT;"; done
read2 "the read"; read2 "the 2019 read" pgvrc-19

echo "== the chains"
G=$(steps pgvrc1); V=$(verdict pgvrc1)
[ "$G" = "full:pgvrc-m,log:pgvrc-m,log:pgvrc-m,log:pgvrc-m" ] && [[ "$V" == "restorable from these backups to "* ]] || fail "R1: $G | $V"; ok "R1: $G | $V"
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc2' and step > 0")
[ "$G" = "full,diff,log,log" ] || fail "R2: $G | $(verdict pgvrc2) | sets: $(q "select string_agg(role || ' ' || backup_set_id || ' ' || first_lsn || '-' || last_lsn || coalesce(' db ' || database_backup_lsn, '') || ' ' || sink, '; ' order by last_lsn) from pgvigil.mssql_restore_sets where instance_id=$(iid) and database_name='pgvrc2'") | msdb: $(sq "SELECT STRING_AGG(type + ' ' + CAST(backup_set_id AS varchar(9)) + ' ' + CAST(first_lsn AS varchar(25)) + '-' + CAST(last_lsn AS varchar(25)), '; ') WITHIN GROUP (ORDER BY backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvrc2'")"; ok "R2: $G"
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc2b' and step > 0")
IFS='|' read -r LL2B DL2B LID2B <<<"$(sq "SELECT CAST(l.last_lsn AS varchar(25)) + '|' + CAST(d.last_lsn AS varchar(25)) + '|' + CAST(l.backup_set_id AS varchar(12)) FROM msdb.dbo.backupset l JOIN msdb.dbo.backupset d ON d.database_name = l.database_name AND d.type = 'I' WHERE l.database_name = N'pgvrc2b' AND l.type = 'L'" | tr -d '\r')"
R2B=
if [ -n "$LL2B" ] && [ "$LL2B" = "$DL2B" ]; then
  [ "$G" = "full,diff" ] || fail "R2b: $G, want full,diff (the log $LID2B ends at the differential's last_lsn $DL2B: it applies nothing)"
  R2B=1; ok "R2b: the log $LID2B ends at the differential's last_lsn $DL2B and is no step: $G"
else
  [ "$G" = "full,diff,log" ] || fail "R2b: $G (the log ends at $LL2B, the differential at $DL2B)"
  notproven "R2b: the named difference from dbatools - this run's log ran past the differential ($LL2B > $DL2B): $G"
fi
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc3' and step > 0")
[ "$G" = "copy_full,log" ] || fail "R3: $G"; ok "R3: the copy-only full is the start set: $G"
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc5' and step > 0"); V=$(verdict pgvrc5)
F=$(q "select severity || '|' || check_name from pgvigil.mssql_restore_findings where instance_id=$(iid) and object='pgvrc5'")
[ "$G" = "full,log" ] && [[ "$V" == "broken before the log of "* ]] && [ "$F" = "warning|the log chain is broken" ] || fail "R5: $G | $V | $F"; ok "R5: $G | $V | $F"
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc6' and step > 0"); V=$(verdict pgvrc6)
[ "$G" = "full,log" ] && [[ "$V" == "went to NUL at "* ]] || fail "R6: $G | $V"; ok "R6: $G | $V"
G=$(q "select string_agg(n::text, ',' order by step) from (select c.step, count(f.*) n from pgvigil.mssql_restore_steps c join pgvigil.mssql_restore_files f on f.backup_set_uuid = c.backup_set_uuid where c.instance_id=$(iid) and c.database_name='pgvrc7' and c.step > 0 group by c.step) x")
[ "$G" = "3,2" ] || fail "R7: $G"; ok "R7: files per step $G"
G=$(q "select media_position || '|' || marks from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc8' and step = 2")
[ "$G" = "2|file 2 of its media" ] || fail "R8: $G"; ok "R8: $G"
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc9' and step > 0")
[ "$G" = "full" ] || fail "R9: $G"; ok "R9: the copy-only log is no step: $G"
T1=$(rtime "$(lastid pgvrc1 L)"); [[ "$(verdict pgvrc1)" == "restorable from these backups to $T1 UTC;"* ]] || fail "R1 time: $(verdict pgvrc1) (msdb: $T1)"; ok "R1: restorable to $T1 UTC, msdb's last log"
L1=$(sq "SELECT MIN(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvrc5' AND type = 'L'" | tr -d '\r '); T5=$(rtime "$L1")
[[ "$(verdict pgvrc5)" == *"; restorable to $T5 UTC" ]] || fail "R5 time: $(verdict pgvrc5) (log 1: $T5)"; ok "R5: restorable to $T5 UTC, log 1's time"
G=$(q "select server_gaps from pgvigil.mssql_restore_reads where instance_id=$(iid) and database_name='pgvrc6'"); [ "$G" = 0 ] || fail "R6: gaps on this server $G, want 0"; ok "R6: gaps on this server 0"
G=$(roles pgvrc4)
if [ -n "$R4L" ]; then [ "$G" = "copy_full,log" ] || fail "R4: $G"; ok "R4: only a copy-only full, then a log: $G"
else [ "$G" = "copy_full" ] && [[ "$(verdict pgvrc4)" == "restorable to the full of "*" UTC only" ]] || fail "R4: $G | $(verdict pgvrc4) (the log was refused: $R4MSG)"
  ok "R4: SQL Server refused a log backup after a copy-only full alone ($(printf '%s' "$R4MSG" | tr '\n' ' ' | grep -o 'Msg [0-9]*' | head -1)): $G | $(verdict pgvrc4)"; fi
G=$(ids pgvrc11); [ "$G" = "$R11A,$R11L3" ] && [[ "$(verdict pgvrc11)" == "restorable from these backups to "* ]] || fail "R11a: $G, want $R11A,$R11L3 | $(verdict pgvrc11) | sets: $(q "select string_agg(role || ' ' || backup_set_id || ' ' || last_lsn || ' ' || coalesce(last_recovery_fork_guid, '-'), '; ' order by finish_at) from pgvigil.mssql_restore_sets where instance_id=$(iid) and database_name='pgvrc11'")"
ok "R11a: after the restore over with a log only: the first full $R11A (parent fork, up to the fork point) and the new fork's log $R11L3"
G=$(roles pgvrc14); N=$(q "select count(*) from pgvigil.mssql_restore_sets where instance_id=$(iid) and database_name='pgvrc14'")
[ "$G" = "full,log" ] && [ "$N" = 2 ] || fail "R14: $G, $N sets stored (msdb's uuids seen twice: $DUPS)"
if [ "${DUPS:-0}" -gt 0 ]; then ok "R14: msdb holds $DUPS backup_set_uuid twice after the same-server restore; the read whole, $G, each set stored once"
else ok "R14: $G, 2 sets stored"; notproven "R14: msdb wrote no second row for the restored sets on this run (the store test holds the dedupe)"; fi
G=$(roles pgvrc16); V=$(verdict pgvrc16); [ "$G" = "full,diff" ] && [[ "$V" == "restorable to the differential of "*" UTC only" ]] || fail "R16: $G | $V"; ok "R16: SIMPLE: $G | $V"
G=$(roles pgvrc18); M=$(q "select marks from pgvigil.mssql_restore_steps where instance_id=$(iid) and database_name='pgvrc18' and step = 1")
[ "$G" = "full,log,log" ] && [[ "$M" == *"a newer full went to NUL at "* ]] || fail "R18: $G | $M"; ok "R18: $G | step 1: $M"
I19=$(q "select instance_id from pgvigil.instances where name='pgvrc-19'"); V19=$(q "select verdict from pgvigil.mssql_restore_verdicts where instance_id=$I19 and database_name='pgvrc19'")
G=$(q "select string_agg(role, ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$I19 and database_name='pgvrc19' and step > 0")
T19=$(s19 "SELECT FORMAT(backup_start_date, 'yyyy-MM-dd HH:mm') FROM msdb.dbo.backupset WHERE backup_set_id = (SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvrc19' AND type = 'L')" | tr -d '\r')
[ "$G" = "full,log,log" ] && [[ "$V19" == "restorable from these backups to $T19 UTC;"* ]] || fail "R15: $G | $V19 (the last log's start: $T19)"
ok "R15: SQL Server $(s19 "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))" | tr -d '\r '): $G, restorable to the last log's start $T19 UTC"

echo "== R11b and R17: the restore over gets a new full; a database dropped and created again"
wr pgvrc11; bk "DATABASE pgvrc11" r11n.bak; R11N=$(lastid pgvrc11 D); wr pgvrc11; bk "LOG pgvrc11" r11l4.trn; R11L4=$(lastid pgvrc11 L)
LN=$(sq "SELECT CAST(last_lsn AS varchar(25)) FROM msdb.dbo.backupset WHERE backup_set_id = $R11N" | tr -d '\r '); LS=$(sq "SELECT CAST(last_lsn AS varchar(25)) FROM msdb.dbo.backupset WHERE backup_set_id = $R11S" | tr -d '\r ')
run "DROP DATABASE pgvrc17; CREATE DATABASE pgvrc17; ALTER DATABASE pgvrc17 SET RECOVERY FULL;"
bk "DATABASE pgvrc17" r17b.bak; R17B=$(lastid pgvrc17 D); wr pgvrc17; bk "LOG pgvrc17" r17m.trn; R17M=$(lastid pgvrc17 L)
read2 "the second read"
G=$(ids pgvrc11); [ "$G" = "$R11N,$R11L4" ] || fail "R11b: $G, want $R11N,$R11L4 (S $R11S: last_lsn $LS, N's $LN)"
if python3 -c "import sys; sys.exit(0 if int('$LN') < int('$LS') else 1)"; then ok "R11b: the new full $R11N and log $R11L4; the safety full $R11S (last_lsn $LS) above the new fork's full ($LN) is no step"
else ok "R11b: $G"; notproven "R11b: the new fork's full ($LN) is not below the safety full's last_lsn ($LS) on this run: the overlap the fork rule is for did not occur (the store test's db7 holds it)"; fi
G=$(ids pgvrc17); N=$(q "select count(*) from pgvigil.mssql_restore_sets where instance_id=$(iid) and database_name='pgvrc17'")
[ "$G" = "$R17B,$R17M" ] && [ "$N" = 2 ] || fail "R17: $G ($N stored), want $R17B,$R17M"; ok "R17: dropped and created again: only the new sets $G, 2 stored"

echo "== dbatools 2.9.1"
if [ -z "${PROOF_SKIP_DBATOOLS:-}" ]; then
  docker run -d --name "$PS" --label pgvigil-proof=inv304 --network "$NET" mcr.microsoft.com/powershell:latest sleep 3600 >/dev/null
  docker exec -e SAPW "$PS" pwsh -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module dbatools -RequiredVersion 2.9.1 -Scope CurrentUser -Force -AcceptLicense | Out-Null
    Import-Module dbatools; Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true | Out-Null
    $c = [pscredential]::new("sa", (ConvertTo-SecureString $env:SAPW -AsPlainText -Force))
    foreach ($row in @(@("pgvrc1", $false), @("pgvrc2", $false), @("pgvrc2b", $false), @("pgvrc3", $true), @("pgvrc3", $false), @("pgvrc4", $true), @("pgvrc4", $false), @("pgvrc5", $false), @("pgvrc9", $false), @("pgvrc11", $false), @("pgvrc17", $false))) {
      $b = @(Get-DbaDbBackupHistory -SqlInstance sql22 -SqlCredential $c -Database $row[0] -Last -IncludeCopyOnly:$row[1])
      "{0}|{1}|{2}" -f $row[0], $row[1], (($b | Sort-Object { [decimal]$_.LastLsn }, Type | ForEach-Object { $_.BackupSetID }) -join ",") }' 2>"$WORK/dbatools.err" | tr -d '\r' > "$WORK/dbatools.txt" || true
  if [ -s "$WORK/dbatools.txt" ]; then
    cat "$WORK/dbatools.txt" | sed 's/^/     dbatools: /'
    dt() { grep "^$1|$2|" "$WORK/dbatools.txt" | cut -d'|' -f3; }
    for x in "pgvrc1 False" "pgvrc2 False" "pgvrc3 True" "pgvrc4 True" "pgvrc11 False" "pgvrc17 False"; do set -- $x; [ "$(dt $1 $2)" = "$(ids $1)" ] || fail "R1-R4, R11, R17 vs dbatools: $1 (IncludeCopyOnly $2) dbatools $(dt $1 $2), pgvigil $(ids $1)"; done
    [ -z "$(dt pgvrc4 False)" ] || fail "R4: dbatools' default listed $(dt pgvrc4 False) (want nothing: no full that is not copy-only)"
    ok "R4: dbatools' default lists nothing for a copy-only full alone; pgvigil starts at it - a difference on purpose"
    [ "$(dt pgvrc3 False)" != "$(ids pgvrc3)" ] || fail "R3: dbatools' default should start at the normal full"
    if [ -n "$R2B" ]; then
      [ "$(dt pgvrc2b False)" = "$(ids pgvrc2b),$LID2B" ] || fail "R2b vs dbatools: dbatools $(dt pgvrc2b False), want pgvigil's $(ids pgvrc2b) and the log $LID2B"
      ok "R2b: dbatools 2.9.1 -Last lists $(dt pgvrc2b False): pgvigil's $(ids pgvrc2b) and the log $LID2B that applies nothing - a difference on purpose"
    else [ "$(dt pgvrc2b False)" = "$(ids pgvrc2b)" ] || fail "R2b vs dbatools: dbatools $(dt pgvrc2b False), pgvigil $(ids pgvrc2b)"; fi
    [ "$(dt pgvrc9 False)" = "$(ids pgvrc9)" ] || fail "R9 vs dbatools: dbatools $(dt pgvrc9 False), pgvigil $(ids pgvrc9)"
    D5=$(dt pgvrc5 False); [ "$(echo "$D5" | tr ',' '\n' | wc -l)" = 3 ] || fail "R5: dbatools listed $D5 (want the full and logs 1 and 3, no gap named)"
    ok "R1, R2, R3 and R4 (-IncludeCopyOnly), R9, R11, R17 equal to dbatools 2.9.1; R3 differs from its default on purpose; R5: dbatools lists $D5 and names no gap"
  else notproven "the dbatools rows: $(tail -c 300 "$WORK/dbatools.err" | tr '\n' ' ')"; fi
else notproven "the dbatools rows (PROOF_SKIP_DBATOOLS)"; fi

echo "== R10 the API"
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN_PROOF -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
WANT=$(sq "SELECT STRING_AGG(CAST(last_lsn AS varchar(25)), ',') WITHIN GROUP (ORDER BY last_lsn) FROM msdb.dbo.backupset WHERE database_name = N'pgvrc2' AND (type = 'L' AND backup_set_id > (SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvrc2' AND type = 'I') OR backup_set_id IN (SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvrc2' AND type IN ('D', 'I') GROUP BY type))")
curl -s "$U/api/mssql/restore?instance=$(iid)&db=pgvrc2" | WANT="$WANT" python3 -c '
import json, os, sys
d = json.load(sys.stdin); c = d["steps"]["columns"]; rows = [dict(zip(c, r)) for r in d["steps"]["rows"] if r[c.index("step")] > 0]
assert all(isinstance(r["last_lsn"], str) and isinstance(r["first_lsn"], str) for r in rows), "an LSN is not a string"
got = ",".join(r["last_lsn"] for r in rows); assert got == os.environ["WANT"], (got, os.environ["WANT"])
dc = d["databases"]["columns"]; first = d["databases"]["rows"][0]
assert first[dc.index("state")] == "broken" and first[dc.index("database_name")] == "pgvrc5", first
print("ok   R10: the steps last_lsn as strings equal to msdb (%s); pgvrc5 broken first" % got)'

echo "== R13 the group"
if [ -n "${PROOF_AG:-}" ]; then
  AGTAG=pgvrcag$(printf '%04x' "$SUF"); AGSA="S$(head -c 14 /dev/urandom | od -An -tx1 | tr -d ' \n')!a"
  if KEEP=1 PGVIGIL_DAG_TAG=$AGTAG PGVIGIL_DAG_SA=$AGSA bash scripts/dag/trial.sh > "$WORK/ag.log" 2>&1 && grep -q "DAG FORMED" "$WORK/ag.log"; then
    agrun() { local o; o=$(agq "$@" 2>&1) || fail "the lab statement failed on $1 ($(printf '%s' "$2" | head -c 80)): $o"; }
    agq() { SQLCMDPASSWORD="$AGSA" docker exec -e SQLCMDPASSWORD "$AGTAG-$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -Q "SET NOCOUNT ON; $2"; }
    for n in d1a d1b; do
      printf "CREATE LOGIN pgvrc_mon WITH PASSWORD = N'%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvrc_mon; GRANT VIEW ANY DEFINITION TO pgvrc_mon;\n" "$PM" \
        | SQLCMDPASSWORD="$AGSA" docker exec -i -e SQLCMDPASSWORD "$AGTAG-$n" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -d master -i /dev/stdin >/dev/null
      agq $n "USE msdb; CREATE USER pgvrc_mon FOR LOGIN pgvrc_mon; ALTER ROLE db_datareader ADD MEMBER pgvrc_mon;" >/dev/null
      docker exec "$AGTAG-$n" mkdir -p /var/opt/mssql/bk
      IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AGTAG-$n")
      export "MSSQL_AG_${n^^}_DSN=sqlserver://pgvrc_mon:$PM@$IP:1433?database=master&encrypt=true&TrustServerCertificate=true"
      printf '  - name: pgvrc-ag-%s\n    engine: sqlserver\n    dsn: env:MSSQL_AG_%s_DSN\n    mssql_thresholds:\n      new_database_hours: 0\n' "$n" "${n^^}" >> "$CFG"
    done
    agq d1a "BACKUP DATABASE dagdb TO DISK = N'/var/opt/mssql/bk/f.bak' WITH FORMAT;" >/dev/null; sleep 1
    agq d1b "BACKUP LOG dagdb TO DISK = N'/var/opt/mssql/bk/l1.trn' WITH FORMAT;" >/dev/null; sleep 1
    agq d1a "BACKUP LOG dagdb TO DISK = N'/var/opt/mssql/bk/l2.trn' WITH FORMAT;" >/dev/null
    for n in d1a d1b; do collect mssql_ag "pgvrc-ag-$n" && read2 "R13 $n" "pgvrc-ag-$n"; done
    collect mssql_restore_chain pgvrc-ag-d1a || fail "R13: the second read of d1a"
    for n in d1a d1b; do
      IA=$(q "select instance_id from pgvigil.instances where name='pgvrc-ag-$n'")
      G=$(q "select string_agg(role || '@' || replace(from_instance, 'pgvrc-ag-', ''), ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$IA and database_name='dagdb' and step > 0")
      [ "$G" = "full@d1a,log@d1b,log@d1a" ] || fail "R13: from $n the chain $G | $(q "select verdict from pgvigil.mssql_restore_verdicts where instance_id=$IA and database_name='dagdb'")"
      ok "R13: from $n one chain $G"
    done
    IA=$(q "select instance_id from pgvigil.instances where name='pgvrc-ag-d1a'"); IB=$(q "select instance_id from pgvigil.instances where name='pgvrc-ag-d1b'")
    agrun d1b "BACKUP LOG dagdb TO DISK = N'/var/opt/mssql/bk/l3.trn' WITH FORMAT;"; sleep 1
    agrun d1a "BACKUP LOG dagdb TO DISK = N'/var/opt/mssql/bk/l4.trn' WITH FORMAT;"
    collect mssql_restore_chain pgvrc-ag-d1a || fail "R13b: the read of d1a"
    V=$(q "select verdict from pgvigil.mssql_restore_verdicts where instance_id=$IA and database_name='dagdb'")
    [[ "$V" == "not yet read from pgvrc-ag-d1b"* ]] || fail "R13b: d1a read alone: $V"; ok "R13b: d1a read alone: $V"
    collect mssql_restore_chain pgvrc-ag-d1b || fail "R13b: the read of d1b"
    G=$(q "select string_agg(replace(from_instance, 'pgvrc-ag-', ''), ',' order by step) from pgvigil.mssql_restore_steps where instance_id=$IA and database_name='dagdb' and step > 0")
    [ "$G" = "d1a,d1b,d1a,d1b,d1a" ] || fail "R13b: after d1b's read: $G | $(q "select verdict from pgvigil.mssql_restore_verdicts where instance_id=$IA and database_name='dagdb'")"; ok "R13b: after d1b's read one chain $G"
    for k in 5 6 7; do agrun d1a "BACKUP LOG dagdb TO DISK = N'/var/opt/mssql/bk/l$k.trn' WITH FORMAT;"; sleep 1; done
    GONE=$(agq d1a "SELECT b.backup_set_id FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id WHERE b.database_name = N'dagdb' AND f.physical_device_name = N'/var/opt/mssql/bk/l6.trn'" | tr -d '\r ')
    agrun d1a "USE msdb; DECLARE @m int = (SELECT media_set_id FROM dbo.backupset WHERE backup_set_id = $GONE);
      DELETE FROM dbo.backupfilegroup WHERE backup_set_id = $GONE; DELETE FROM dbo.backupfile WHERE backup_set_id = $GONE;
      DELETE FROM dbo.backupset WHERE backup_set_id = $GONE; DELETE FROM dbo.backupmediafamily WHERE media_set_id = @m; DELETE FROM dbo.backupmediaset WHERE media_set_id = @m;"
    for n in d1a d1b; do collect mssql_ag "pgvrc-ag-$n" && collect mssql_restore_chain "pgvrc-ag-$n" || fail "R13c: the read of $n"; done
    V=$(q "select state || '|' || verdict from pgvigil.mssql_restore_verdicts where instance_id=$IA and database_name='dagdb'")
    F=$(q "select count(*) from pgvigil.mssql_restore_findings where instance_id in ($IA, $IB) and object='dagdb'")
    [[ "$V" == "held|not judged (the distributed availability group dag1"* ]] && [ "$F" = 0 ] || fail "R13c: $V | findings $F | ag rows: $(q "select string_agg(group_name || '/' || replica_server || '/' || coalesce(is_distributed::text, '-'), ', ') from pgvigil.mssql_ag_state where instance_id=$IA")"
    ok "R13c: a gap in dag1's member group: $V; findings 0"
  else notproven "R13: a live group - the lab did not form: $(grep -E 'FAIL|REFUSED' "$WORK/ag.log" | head -2 | tr '\n' ' ' | cut -c1-300)"; fi
else notproven "R13: a live availability group (PROOF_AG unset): TestRestoreChainOnAStore's stubbed rows hold the merge"; fi

echo "== R12 the cap (last: it reads with a keep of 3)"
PGVIGIL_RESTORE_LOG_KEEP=3 collect mssql_restore_chain pgvrc-m || fail "R12: the capped read: $(cat "$OUT")"
R=$(q "select logs_since || '|' || logs_sent || '|' || v.state from pgvigil.mssql_restore_reads r join pgvigil.mssql_restore_verdicts v using (instance_id, database_name) where r.instance_id=$(iid) and r.database_name='pgvrc12'")
V=$(verdict pgvrc12); F=$(q "select count(*) from pgvigil.mssql_restore_findings where instance_id=$(iid) and object='pgvrc12'")
CAP=$(curl -s "$U/api/mssql/restore?instance=$(iid)" | python3 -c 'import json,sys; d=json.load(sys.stdin)["databases"]; c=d["columns"]; print([r[c.index("capped")] for r in d["rows"] if r[c.index("database_name")]=="pgvrc12"][0])')
[ "$R" = "5|3|held" ] && [[ "$V" == "not read whole: pgvrc-m's read lists its log backups since "* ]] && [ "$F" = 0 ] && [ "$CAP" = True ] || fail "R12: $R | $V | findings $F | capped $CAP"
ok "R12: logs since 5, sent 3, held: $V; findings 0; the API says capped"
echo "ALL ROWS GREEN"
