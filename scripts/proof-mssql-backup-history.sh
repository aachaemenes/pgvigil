#!/usr/bin/env bash
# Proof of task 301b: a SQL Server database's backup history and restore history, three checks of its backups and
# verify_backup (migration 0191; internal/mssql/backup_history.go's collections mssql_backup_history and
# mssql_backup_checks; internal/mssql/verify_backup.go and internal/web/actions_verify.go; /api/mssql/backup_files'
# parts; the Backups tab's grids; the Properties tab's default backup path).
#
# Needs: docker (it starts and removes its own containers: SQL Server 2022 Developer with TZ=America/Los_Angeles and a
# backup volume, SQL Server 2019 Developer), psql, curl, jq, python3, a go toolchain at the repository root, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...);
#                      the proof makes its own database there and drops it.
# The binary must carry the five WIRING patches (scripts/inv-301-, -304-, -301c-, -302-, -301b-wiring.patch applied in
# that order to the tree it is built from): the opt-ins reads.auto_close_databases and reads.backup_files, the verify
# routes, serve's sweep and shutdown, and the Properties row come with them. The proof applies
# scripts/inv-301b-joined-cursor.sql to its repository (mssql_hadr_cursor as the joined tree holds it).
# Optional: PGVIGIL_BIN (default bin/pgvigil, built here when missing), PROOF_SKIP_2019=1 (H7 NOT PROVEN),
# PROOF_SKIP_PAGE=1 (I NOT PROVEN).
# Nothing it did not make is touched; every container, volume and the repository database go on every exit path.
#
# Expected (written before the first run; the facts of probes 301bP1 and 301bP2 behind them):
#  AC  (the red row, FIRST; a timing row: red under load is rerun once before it is graded a fault) an
#      AUTO_CLOSE database pgbhac (FULL, no backup). First the control that 15 s idle closes it on this box: after
#      15 s the instance with reads.auto_close_databases on reads it - mssql_backup_checks raises the error log's count
#      of 'Starting up database 'pgbhac'' (sp_readerrorlog by sa) by one and its cell is read. Then, after the same
#      15 s, the count is the same after the collections mssql_backup_history and mssql_backup_checks of the instance
#      without the opt-in (n1 = n0), its cell 'not read: AUTO_CLOSE (reading would open it)'; the second control: sa's
#      USE pgbhac after 15 s raises it by one (it was closed). A line (not graded) prints the count around 301's
#      mssql_backups and mssql_backup_files.
#  H1  pgbh1: 12 fulls, then 70 logs, then a copy-only full: the first read stores the newest 10 fulls and the newest 10
#      logs (msdb's, by finish) and the copy-only one; the cursor = msdb's newest backup_set_id; one more log and a
#      second read: the 10 fulls keep the first read's read_at (they lie more than 50 sets behind the cursor: not read
#      again), the new log is stored and the logs are still 10; the newest log's row equals msdb's (path, position,
#      family count, device disk, size, first and last LSN).
#  H2  (container TZ=America/Los_Angeles: the server's offset -480 in November) pgbh2's full restored as pgbh2r WITH
#      NORECOVERY, then its log WITH RECOVERY: two restores stored for pgbh2r - D (recovery no) and L (recovery yes),
#      each with the uuid of the set it restored; restore_at = msdb's restore_date + 8 hours, and within 10 minutes of
#      the repository's now(). The monitoring login's msdb user DENIED SELECT on restorehistory: the next read says
#      'not read: no right (SELECT on msdb.dbo.restorehistory)' (the cursor row's restore_state), no error, the two
#      restores stay; the DENY revoked after. (Changed after run 301bp3: the want was the collector's payload word
#      'no right'; the import stores these words - TestBackupHistoryOnAStore asserts them.)
#  H3  (reads.backup_files on) pgbh3: a full in /backups/h3/, a differential in /backups/h3d/, a log in /backups/h3/; the log's
#      file removed and the folder /backups/h3d removed: cells full 'present', log 'the file is gone', differential 'the
#      folder /backups/h3d/ is gone'; findings 'backup file missing' for 'pgbh3 (diff)' and 'pgbh3 (log)' (warning).
#      The instance without the opt-in: every file cell 'not read: the file check is off', no file finding.
#  H4  pseudo-simple: pgbh4f (FULL, no backup) 'yes: FULL, but no log backup can be taken: no full or differential
#      backup since the log chain began'; pgbh4s (SIMPLE, a full, then FULL) the same; pgbh4b (BULK_LOGGED, no backup)
#      'yes: BULK_LOGGED, but ...'; pgbh4r (a restore WITH NORECOVERY) 'not judged: the database is restoring'; model
#      'not judged: model', msdb 'not judged: msdb'; pgbh2r (restored) and pgbh1 'no'; findings 'pseudo-simple recovery'
#      for pgbh4b, pgbh4f, pgbh4s. Then a full of pgbh4f and a differential of pgbh4s: both 'no', the findings pgbh4b's alone.
#  H6  verify_backup through `pgvigil serve` as a signed-in UI user (bh-m: actions_dsn a login with CREATE DATABASE in
#      master only, actions [verify_backup]):
#      a  a full with checksums: Preview ok, its one path, position 1, checksums yes, no path in the statement; a newer
#         full taken; Run (the typed database name) 202 'started', then 'done' in the actions log for THAT set, the
#         server message holding 'The backup set on file 1 is valid.', the statement with CHECKSUM and no path.
#      b  a full striped over two files: done, both paths in Preview. c  the second set of a file (position 2): done,
#         'The backup set on file 2 is valid.'. d  a full taken WITH NO_CHECKSUM: Preview 'checksums no', the statement
#         without CHECKSUM, done.
#      e  refusals, each 409 with one audit row 'refused' and nothing sent: a typed confirmation that is not the
#         database's name ('the typed confirmation is not the database's name'); a body whose shown paths are not the
#         set's ('... is not as shown ...'); the repository's lock held by another session ('one at a time'); bh-off
#         without actions_dsn ('has no actions_dsn'); bh-kill whose list lacks it ('verify_backup is not on the
#         instance's actions: list'); a sysadmin actions login ('sysadmin or holds CONTROL SERVER'); a dbcreator member
#         ('in dbcreator or holds ALTER ANY DATABASE'); a login without CREATE DATABASE ('has no CREATE DATABASE in
#         master'); a file overwritten WITH INIT after Preview ('the file now holds another backup set at position 1').
#      f  a removed file: 502 failed, 'RESTORE HEADERONLY failed: ' with the server's 'Cannot open backup device' and
#         'Operating system error 2'. g  an encrypted full: Preview not ok, 'not offered: the backup is encrypted'.
#      h  serve stopped (SIGTERM) one second into the verify of a 1 GB full: its end row 'cut by shutdown' (a timing
#         row: a verify that ended first says so and the row is NOT PROVEN for that run). i  a 'started' row three hours
#         old with no end, put in by hand: serve's next start writes 'ended unknown' for it.
#      k  (P3.4, RED) serve killed (SIGKILL: no end row, its lock gone with its session) one second into a
#         verify of the 1 GB full: its 'started' row, seconds old (inside verify_timeout), gets 'ended unknown' at the
#         next start (a timing row as h: a verify that ended first is NOT PROVEN for that run).
#      l  (P3.4, NEGATIVE CONTROL) a 'started' row a minute old while another session holds the instance's
#         lock (as a live verify does): serve's start leaves it 'started'; with the lock let go, the next start sweeps it.
#      j  every verify_backup row of the run: no '/backups' in its statement, and some hold RESTORE VERIFYONLY.
#  I   (the page, light and dark, signed in) #/mssqlbackups?i=<bh-m>&db=pgbh6: the Backup history grid's header =
#      DBA Dash's 24 Last Backup columns msdb's history holds, in order, then pgvigil's 15; one row per stored set of
#      pgbh6; set a's last verify cell 'done ...'; Verify buttons on disk rows; the grid's right-click menu on a row
#      holds 'Verify this backup...' (the j16 join, J16 GRIDMENU VERIFY: on a disk row; on the row of a log backup to a
#      URL, stored after the last read, the grid's menu is drawn without it); the Backup checks grid drawn, its read line (read while SELECT on restorehistory
#      is denied) 'the restores: not read: no right (SELECT on msdb.dbo.restorehistory) - the restores read before
#      stay'; db=pgbh2r: its Restore history 2 rows; axe-core
#      4.14.0 (WCAG 2.1 A and AA) 0 violation nodes. Skipped (NOT PROVEN) without chromium and node.
#  H5  the default backup path: '/var/opt/mssql/data' stored by mssql_properties (default_backup_path), reachable yes,
#      the API's Properties row 'Default backup path reachable' yes, no finding; mssql-conf filelocation.defaultbackupdir
#      set to /var/opt/mssql/pgbhbk (made, owned by mssql) and a restart: the property '/var/opt/mssql/pgbhbk' with its
#      change logged, reachable yes; the folder given to root with mode 700: still yes, no finding (a directory read
#      is no proof of access - 301bP1); the folder removed: reachable no, the finding 'default backup path not
#      reachable' with 'the default backup path /var/opt/mssql/pgbhbk is not a directory the service account sees', the
#      API's row no.
#  H7  SQL Server 2019: the history read with no error; the default path '/var/opt/mssql/data' reachable yes; a FULL
#      database without a backup pseudo-simple 'yes'; a verify of a full done ('The backup set on file 1 is valid.':
#      HEADERONLY's 56 columns read by name).
#  NOT PROVEN HERE: Windows (a share's root that does not answer, the service account on a share, the registry read of
#  SQL Server 2017), Azure SQL Managed Instance, Amazon RDS (their 'not judged' words are unit tests); a server-side
#  RESTORE of program 'pgvigil-actions' found running (the repository's lock is proven in H6e).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of a PostgreSQL sandbox}"
command -v jq >/dev/null || { echo "FAIL: jq is needed" >&2; exit 1; }
SUF=$RANDOM
SQL=pgbh-22-$SUF; SQL19=pgbh-19-$SUF; VB=pgbh-b-$SUF
IMG22=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}; IMG19=${PGVIGIL_MSSQL_IMAGE19:-mcr.microsoft.com/mssql/server:2019-latest}
REPO_DB=pgvigil_bhproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; LOG=$WORK/serve.log; CJ=$WORK/cookies; BODY=$WORK/body
pw() { printf 'Pv9%s!a' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); PM=$(pw); PA=$(pw); PS=$(pw); PD=$(pw); PN=$(pw); UPW=$(pw); USR=bhproof$SUF
export SAPW SQLCMDPASSWORD="$SAPW"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
MADE_VOL=; MADE_DB=; SRVPID=; SRV2=; CHR=; LOCKPID=
cleanup() {
  rc=$?
  set +e
  for p in "$SRVPID" "$SRV2" "$CHR" "$LOCKPID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  docker rm -f -v "$SQL" "$SQL19" >/dev/null 2>&1
  [ -n "$MADE_VOL" ] && docker volume rm "$VB" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_REPO_DSN" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$WORK"
  echo "left: containers $(docker ps -aq --filter "name=pgbh-.*-$SUF" | wc -l), volumes $(docker volume ls -q --filter "name=pgbh-b-$SUF" | wc -l)"
  exit $rc
}
trap cleanup EXIT

# sqlcmd as sa: the password by name from the environment, never on a command line
sqn() { local ct=$1 db=$2; shift 2; docker exec -e SQLCMDPASSWORD "$ct" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "$db" -Q "SET NOCOUNT ON; $1"; }
sq() { sqn "$SQL" "${2:-master}" "$1"; }
sqin() { docker exec -i -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }
RDSN=$(printf '%s' "$PGVIGIL_REPO_DSN" | sed -E "s/dbname=[^ ]+/dbname=$REPO_DB/"); [[ "$RDSN" == *"dbname=$REPO_DB"* ]] || RDSN="$PGVIGIL_REPO_DSN dbname=$REPO_DB"
q() { psql "$RDSN" -XAtqc "$1"; }
up() { local ct=$1; for _ in $(seq 1 90); do [ "$(sqn "$ct" master "SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" 2>/dev/null | tr -d '\r ')" = 1 ] && return 0; sleep 2; done; return 1; }
# the error log's count of the lines that say a database was started (opened)
starts() { sqn "$1" master "CREATE TABLE #el (d datetime, p nvarchar(50), t nvarchar(max)); INSERT #el EXEC sp_readerrorlog 0, 1, N'Starting up database ''$2'''; SELECT COUNT(*) FROM #el;" | tr -d ' \r' | grep -E '^[0-9]+$' | tail -1; }

echo "== containers"
docker volume create "$VB" >/dev/null; MADE_VOL=1
ENVF=$WORK/sql.env; printf 'ACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_SA_PASSWORD=%s\nTZ=America/Los_Angeles\n' "$SAPW" > "$ENVF"; chmod 600 "$ENVF"
docker run -d --name "$SQL" --label pgvigil-proof=inv301b --env-file "$ENVF" -v "$VB:/backups" -p 127.0.0.1::1433 "$IMG22" >/dev/null
[ -n "${PROOF_SKIP_2019:-}" ] || docker run -d --name "$SQL19" --label pgvigil-proof=inv301b --env-file "$ENVF" -p 127.0.0.1::1433 "$IMG19" >/dev/null
up "$SQL" || fail "SQL Server 2022 did not come up: $(docker logs --tail 20 "$SQL" 2>&1)"
docker exec -u root "$SQL" bash -c 'chown -R mssql /backups && mkdir -p /backups/h1 /backups/h2 /backups/h3 /backups/h3d /backups/h6 && chown -R mssql /backups'
P22=; port22() { P22=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); }
port22
TZOFF=$(sq "SELECT DATEPART(TZOFFSET, SYSDATETIMEOFFSET())")
echo "  SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))") on 127.0.0.1:$P22, its offset $TZOFF minutes"

echo "== logins"
# the monitoring login; the actions logins: CREATE DATABASE in master only (the one verify_backup takes), a sysadmin, a
# dbcreator member, one without CREATE DATABASE - each made here and gone with the container
sqin "$SQL" >/dev/null <<SQL
CREATE LOGIN pgbh_mon WITH PASSWORD = N'$PM', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO pgbh_mon; GRANT VIEW ANY DEFINITION TO pgbh_mon;
CREATE LOGIN pgbh_act WITH PASSWORD = N'$PA', CHECK_POLICY = OFF;
CREATE USER pgbh_act FOR LOGIN pgbh_act; GRANT CREATE DATABASE TO pgbh_act;
CREATE LOGIN pgbh_sys WITH PASSWORD = N'$PS', CHECK_POLICY = OFF; ALTER SERVER ROLE sysadmin ADD MEMBER pgbh_sys;
CREATE LOGIN pgbh_dbc WITH PASSWORD = N'$PD', CHECK_POLICY = OFF; ALTER SERVER ROLE dbcreator ADD MEMBER pgbh_dbc;
CREATE LOGIN pgbh_nocd WITH PASSWORD = N'$PN', CHECK_POLICY = OFF;
SQL
sq "CREATE USER pgbh_mon FOR LOGIN pgbh_mon; ALTER ROLE db_datareader ADD MEMBER pgbh_mon;" msdb >/dev/null

dsn() { echo "sqlserver://$1:$2@127.0.0.1:$3?database=master&encrypt=true&TrustServerCertificate=true"; }
dsns() {
  export BH_MON_DSN="$(dsn pgbh_mon "$PM" "$P22")" BH_ACT_DSN="$(dsn pgbh_act "$PA" "$P22")" BH_SYS_DSN="$(dsn pgbh_sys "$PS" "$P22")"
  export BH_DBC_DSN="$(dsn pgbh_dbc "$PD" "$P22")" BH_NOCD_DSN="$(dsn pgbh_nocd "$PN" "$P22")"
}
dsns
psql "$PGVIGIL_REPO_DSN" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
export PGVIGIL_REPO_DSN_PROOF="$RDSN"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN_PROOF
instances:
  - name: bh-m
    engine: sqlserver
    dsn: env:BH_MON_DSN
    actions_dsn: env:BH_ACT_DSN
    actions: [verify_backup]
    reads:
      backup_files: true
    mssql_thresholds:
      new_database_hours: 0
  - name: bh-off
    engine: sqlserver
    dsn: env:BH_MON_DSN
    mssql_thresholds:
      new_database_hours: 0
  - name: bh-ac
    engine: sqlserver
    dsn: env:BH_MON_DSN
    reads:
      auto_close_databases: true
  - name: bh-kill
    engine: sqlserver
    dsn: env:BH_MON_DSN
    actions_dsn: env:BH_ACT_DSN
    actions: [kill]
  - name: bh-sys
    engine: sqlserver
    dsn: env:BH_MON_DSN
    actions_dsn: env:BH_SYS_DSN
    actions: [verify_backup]
  - name: bh-dbc
    engine: sqlserver
    dsn: env:BH_MON_DSN
    actions_dsn: env:BH_DBC_DSN
    actions: [verify_backup]
  - name: bh-nocd
    engine: sqlserver
    dsn: env:BH_MON_DSN
    actions_dsn: env:BH_NOCD_DSN
    actions: [verify_backup]
EOF
if [ -z "${PROOF_SKIP_2019:-}" ]; then
  up "$SQL19" || fail "SQL Server 2019 did not come up"
  P19=$(docker port "$SQL19" 1433/tcp | head -1 | sed 's/.*://')
  sqin "$SQL19" >/dev/null <<SQL
CREATE LOGIN pgbh_mon WITH PASSWORD = N'$PM', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgbh_mon; GRANT VIEW ANY DEFINITION TO pgbh_mon;
CREATE LOGIN pgbh_act WITH PASSWORD = N'$PA', CHECK_POLICY = OFF; CREATE USER pgbh_act FOR LOGIN pgbh_act; GRANT CREATE DATABASE TO pgbh_act;
SQL
  sqn "$SQL19" msdb "CREATE USER pgbh_mon FOR LOGIN pgbh_mon; ALTER ROLE db_datareader ADD MEMBER pgbh_mon;" >/dev/null
  export BH_19_DSN="$(dsn pgbh_mon "$PM" "$P19")" BH_19A_DSN="$(dsn pgbh_act "$PA" "$P19")"
  printf '  - name: bh-19\n    engine: sqlserver\n    dsn: env:BH_19_DSN\n    actions_dsn: env:BH_19A_DSN\n    actions: [verify_backup]\n    mssql_thresholds:\n      new_database_hours: 0\n' >> "$CFG"
fi
[ -x "$BIN" ] || go build -o "$BIN" ./cmd/pgvigil
"$BIN" migrate -config "$CFG" >"$WORK/migrate.out" 2>&1 || fail "setup: migrate (a binary without the five WIRING patches refuses reads: and verify_backup): $(tail -5 "$WORK/migrate.out")"
psql "$RDSN" -XAtq -v ON_ERROR_STOP=1 -f scripts/inv-301b-joined-cursor.sql >/dev/null || fail "setup: the joined cursor"

collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT"; return 1; }; }
reads() { local i=$1; shift; for c in "$@"; do collect "$c" "$i" || fail "the read $c of $i failed: $(cat "$OUT")"; grep -qE 'skipped|partial' "$OUT" && fail "the read $c of $i is skipped or partial: $(cat "$OUT")"; done; return 0; }
declare -A IID
iid() { [ -n "${IID[$1]:-}" ] || IID[$1]=$(q "select instance_id from pgvigil.instances where name='$1'"); echo "${IID[$1]}"; }
cell() { q "select $3 from pgvigil.mssql_backup_check_cells where instance_id=$(iid "$1") and database_name='$2'"; }

echo "== AC an AUTO_CLOSE database is not opened by the read (the lead's red row)"
sq "CREATE DATABASE pgbhac; ALTER DATABASE pgbhac SET RECOVERY FULL; ALTER DATABASE pgbhac SET AUTO_CLOSE ON;" >/dev/null
# the control first: 15 s idle closes it on this box (the opt-in read opens it again: one more line)
sleep 15; N3=$(starts "$SQL" pgbhac)
reads bh-ac mssql_backup_checks
sleep 3; N4=$(starts "$SQL" pgbhac)
CA=$(cell bh-ac pgbhac pseudo_simple)
[ "$N4" = $((N3 + 1)) ] && [ "${CA#not read: AUTO_CLOSE}" = "$CA" ] || fail "AC opt-in: the count $N3 -> $N4 (want one more), the cell '$CA' (a timing row: rerun once)"
sleep 15; N0=$(starts "$SQL" pgbhac)
reads bh-off mssql_backup_history mssql_backup_checks
sleep 3; N1=$(starts "$SQL" pgbhac)
C=$(cell bh-off pgbhac pseudo_simple)
sleep 15; sq "USE pgbhac; SELECT DB_NAME();" >/dev/null
sleep 3; N2=$(starts "$SQL" pgbhac)
[ -n "$N0" ] && [ "$N0" -ge 1 ] && [ "$N1" = "$N0" ] && [ "$C" = "not read: AUTO_CLOSE (reading would open it)" ] && [ "$N2" = $((N1 + 1)) ] \
  || fail "AC: the error log's count $N0 before the read, $N1 after (want equal), $N2 after sa's USE (want $((N1 + 1))); the cell '$C' (a timing row: rerun once)"
ok "AC: 15 s idle closes it here (the opt-in read opened it: $N3 -> $N4, its cell '$CA'); after the same 15 s the closed AUTO_CLOSE database stayed closed through mssql_backup_history and mssql_backup_checks ($N0 -> $N1; the cell '$C'); sa's USE after 15 s opened it ($N2): it had been closed"
sleep 15; N5=$(starts "$SQL" pgbhac)
reads bh-off mssql_backups mssql_backup_files
sleep 3; N6=$(starts "$SQL" pgbhac)
echo "  (not graded) 301's mssql_backups and mssql_backup_files of the instance without the opt-in: the count $N5 -> $N6 ($([ "$N6" = "$N5" ] && echo 'not opened' || echo 'OPENED'))"

echo "== H1 the backup history"
sq "CREATE DATABASE pgbh1; ALTER DATABASE pgbh1 SET RECOVERY FULL;" >/dev/null
for k in $(seq 1 12); do echo "BACKUP DATABASE pgbh1 TO DISK = N'/backups/h1/f$k.bak' WITH FORMAT;"; done | sqin "$SQL" >/dev/null
for k in $(seq 1 70); do echo "BACKUP LOG pgbh1 TO DISK = N'/backups/h1/l$k.trn' WITH FORMAT;"; done | sqin "$SQL" >/dev/null
sq "BACKUP DATABASE pgbh1 TO DISK = N'/backups/h1/copy.bak' WITH FORMAT, COPY_ONLY;" >/dev/null
reads bh-m mssql_backups mssql_backup_history
I=$(iid bh-m)
newest() { sq "SELECT STUFF((SELECT ',' + CAST(backup_set_id AS varchar(12)) FROM (SELECT TOP (10) backup_set_id, backup_finish_date FROM msdb.dbo.backupset WHERE database_name = N'pgbh1' AND type = '$1' AND is_copy_only = 0 ORDER BY backup_finish_date DESC, backup_set_id DESC) x ORDER BY backup_set_id FOR XML PATH('')), 1, 1, '')"; }
stored() { q "select string_agg(backup_set_id::text, ',' order by backup_set_id) from pgvigil.mssql_backup_history where instance_id=$I and database_name='pgbh1' and backup_type='$1' and not is_copy_only"; }
[ "$(stored D)" = "$(newest D)" ] && [ "$(stored L)" = "$(newest L)" ] \
  && [ "$(q "select count(*) from pgvigil.mssql_backup_history where instance_id=$I and database_name='pgbh1' and is_copy_only")" = 1 ] \
  || fail "H1: stored fulls $(stored D) (msdb's newest $(newest D)), logs $(stored L) (msdb's $(newest L)), copy-only $(q "select count(*) from pgvigil.mssql_backup_history where instance_id=$I and database_name='pgbh1' and is_copy_only")"
CUR=$(q "select last_set_id from pgvigil.mssql_backup_history_cursor where instance_id=$I"); MX=$(sq "SELECT MAX(backup_set_id) FROM msdb.dbo.backupset")
[ "$CUR" = "$MX" ] || fail "H1: the cursor $CUR, msdb's newest $MX"
R1=$(q "select max(read_at) from pgvigil.mssql_backup_history where instance_id=$I")
ok "H1: the newest 10 fulls ($(stored D)) and 10 logs and the copy-only full stored; the cursor $CUR = msdb's newest"
sleep 1; sq "BACKUP LOG pgbh1 TO DISK = N'/backups/h1/l71.trn' WITH FORMAT;" >/dev/null
reads bh-m mssql_backup_history
NEWL=$(sq "SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE type = 'L'")
KEPT=$(q "select count(*) from pgvigil.mssql_backup_history where instance_id=$I and database_name='pgbh1' and backup_type='D' and not is_copy_only and read_at = '$R1'")
[ "$KEPT" = 10 ] && [ "$(stored L)" = "$(newest L)" ] && [[ ",$(stored L)," == *",$NEWL,"* ]] \
  || fail "H1 the cursor read: $KEPT fulls kept the first read's read_at (want 10); logs $(stored L), msdb's newest $(newest L), the new log $NEWL"
G=$(q "select concat_ws('|', path, position, family_count, device_kind, size_bytes, first_lsn, last_lsn) from pgvigil.mssql_backup_history where instance_id=$I and backup_set_id=$NEWL")
W=$(sq "SELECT f.physical_device_name + '|' + CAST(b.position AS varchar(9)) + '|' + CAST(m.media_family_count AS varchar(9)) + '|disk|' + CAST(CAST(b.backup_size AS bigint) AS varchar(20)) + '|' + CAST(b.first_lsn AS varchar(25)) + '|' + CAST(b.last_lsn AS varchar(25)) FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediaset m ON m.media_set_id = b.media_set_id JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id AND f.family_sequence_number = 1 AND f.mirror = 0 WHERE b.backup_set_id = $NEWL")
[ "$G" = "$W" ] || fail "H1: the newest log's row: $G, msdb's $W"
ok "H1: one more log and a cursor read: the 10 fulls kept the first read's read_at, the new log $NEWL stored, still 10 logs; its row = msdb's ($G)"

echo "== H2 the restore history"
sq "CREATE DATABASE pgbh2; ALTER DATABASE pgbh2 SET RECOVERY FULL;" >/dev/null
sq "BACKUP DATABASE pgbh2 TO DISK = N'/backups/h2/f.bak' WITH FORMAT; BACKUP LOG pgbh2 TO DISK = N'/backups/h2/l.trn' WITH FORMAT;" >/dev/null
sq "RESTORE DATABASE pgbh2r FROM DISK = N'/backups/h2/f.bak' WITH MOVE N'pgbh2' TO N'/var/opt/mssql/data/pgbh2r.mdf', MOVE N'pgbh2_log' TO N'/var/opt/mssql/data/pgbh2r_log.ldf', NORECOVERY;
    RESTORE LOG pgbh2r FROM DISK = N'/backups/h2/l.trn' WITH RECOVERY;" >/dev/null
reads bh-m mssql_backups mssql_backup_history
G=$(q "select string_agg(restore_type || '|' || is_recovery || '|' || upper(source_backup_set_uuid::text) || '|' || to_char(restore_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS') || '|' || (abs(extract(epoch from now() - restore_at)) < 600), ',' order by restore_history_id) from pgvigil.mssql_restore_history where instance_id=$I and destination_database_name='pgbh2r'")
W=$(sq "SELECT STUFF((SELECT ',' + r.restore_type + '|' + CASE r.recovery WHEN 1 THEN 'true' ELSE 'false' END + '|' + CAST(b.backup_set_uuid AS varchar(36)) + '|' + CONVERT(varchar(19), DATEADD(hour, 8, r.restore_date), 126) + '|true' FROM msdb.dbo.restorehistory r JOIN msdb.dbo.backupset b ON b.backup_set_id = r.backup_set_id WHERE r.destination_database_name = N'pgbh2r' ORDER BY r.restore_history_id FOR XML PATH('')), 1, 1, '')")
if [ "$TZOFF" = -480 ]; then
  [ "$G" = "$W" ] || fail "H2: stored $G, want (msdb's restore_date + 8 h) $W"
  ok "H2: pgbh2r's two restores (D without recovery, L with), each with its set's uuid; restore_at = msdb's local restore_date + 8 h (the offset -480), within 10 minutes of now()"
else
  [ "${G//|true/}" != "$G" ] || fail "H2: $G"
  notproven "H2's offset: the container's offset is $TZOFF, not -480 (TZ was not taken): the stored rows $G"
fi
sq "DENY SELECT ON OBJECT::dbo.restorehistory TO pgbh_mon;" msdb >/dev/null
reads bh-m mssql_backup_history
S=$(q "select restore_state from pgvigil.mssql_backup_history_cursor where instance_id=$I"); NR=$(q "select count(*) from pgvigil.mssql_restore_history where instance_id=$I and destination_database_name='pgbh2r'")
sq "REVOKE SELECT ON OBJECT::dbo.restorehistory FROM pgbh_mon;" msdb >/dev/null
[ "$S" = "not read: no right (SELECT on msdb.dbo.restorehistory)" ] && [ "$NR" = 2 ] || fail "H2 no right: the state '$S' (want 'not read: no right (SELECT on msdb.dbo.restorehistory)'), $NR restores kept (want 2): $(cat "$OUT")"
ok "H2: SELECT on restorehistory denied: the read said '$S' with no error and kept the $NR restores"

echo "== H3 the newest backups' files (Database#7)"
sq "CREATE DATABASE pgbh3; ALTER DATABASE pgbh3 SET RECOVERY FULL;" >/dev/null
sq "BACKUP DATABASE pgbh3 TO DISK = N'/backups/h3/f.bak' WITH FORMAT; BACKUP DATABASE pgbh3 TO DISK = N'/backups/h3d/d.bak' WITH FORMAT, DIFFERENTIAL; BACKUP LOG pgbh3 TO DISK = N'/backups/h3/l.trn' WITH FORMAT;" >/dev/null
docker exec -u root "$SQL" bash -c 'rm -f /backups/h3/l.trn && rm -rf /backups/h3d'
reads bh-m mssql_backups mssql_backup_checks
reads bh-off mssql_backups mssql_backup_checks
G=$(q "select concat_ws(' | ', file_full, file_log, file_diff) from pgvigil.mssql_backup_check_cells where instance_id=$I and database_name='pgbh3'")
F=$(q "select string_agg(object || '/' || severity, ',' order by object) from pgvigil.mssql_backup_check_findings where instance_id=$I and check_name='backup file missing' and object like 'pgbh3 %'")
GO=$(q "select concat_ws(' | ', file_full, file_log, file_diff) from pgvigil.mssql_backup_check_cells where instance_id=$(iid bh-off) and database_name='pgbh3'")
FO=$(q "select count(*) from pgvigil.mssql_backup_check_findings where instance_id=$(iid bh-off) and check_name='backup file missing'")
[ "$G" = "present | the file is gone | the folder /backups/h3d/ is gone" ] && [ "$F" = "pgbh3 (diff)/warning,pgbh3 (log)/warning" ] \
  || fail "H3: the cells '$G', the findings '$F'"
[ "$GO" = "not read: the file check is off | not read: the file check is off | not read: the file check is off" ] && [ "$FO" = 0 ] \
  || fail "H3 without the opt-in: the cells '$GO', $FO file findings"
ok "H3: '$G'; findings $F; without the opt-in every cell 'not read: the file check is off' and no file finding"

echo "== H4 pseudo-simple (Database#39)"
sq "CREATE DATABASE pgbh4f; ALTER DATABASE pgbh4f SET RECOVERY FULL;
    CREATE DATABASE pgbh4s; ALTER DATABASE pgbh4s SET RECOVERY SIMPLE;
    CREATE DATABASE pgbh4b; ALTER DATABASE pgbh4b SET RECOVERY BULK_LOGGED;" >/dev/null
sq "BACKUP DATABASE pgbh4s TO DISK = N'/backups/h2/s.bak' WITH FORMAT; ALTER DATABASE pgbh4s SET RECOVERY FULL;" >/dev/null
sq "RESTORE DATABASE pgbh4r FROM DISK = N'/backups/h2/f.bak' WITH MOVE N'pgbh2' TO N'/var/opt/mssql/data/pgbh4r.mdf', MOVE N'pgbh2_log' TO N'/var/opt/mssql/data/pgbh4r_log.ldf', NORECOVERY;" >/dev/null
reads bh-m mssql_backups mssql_backup_checks
Y="but no log backup can be taken: no full or differential backup since the log chain began"
for x in "pgbh4f|yes: FULL, $Y" "pgbh4s|yes: FULL, $Y" "pgbh4b|yes: BULK_LOGGED, $Y" "pgbh4r|not judged: the database is restoring" \
         "model|not judged: model" "msdb|not judged: msdb" "pgbh2r|no" "pgbh1|no"; do
  [ "$(cell bh-m "${x%%|*}" pseudo_simple)" = "${x#*|}" ] || fail "H4: ${x%%|*}: '$(cell bh-m "${x%%|*}" pseudo_simple)', want '${x#*|}'"
done
F=$(q "select string_agg(object, ',' order by object) from pgvigil.mssql_backup_check_findings where instance_id=$I and check_name='pseudo-simple recovery' and object like 'pgbh4%'")
[ "$F" = "pgbh4b,pgbh4f,pgbh4s" ] || fail "H4: the findings $F"
sq "BACKUP DATABASE pgbh4f TO DISK = N'/backups/h2/f4.bak' WITH FORMAT; BACKUP DATABASE pgbh4s TO DISK = N'/backups/h2/s4.bak' WITH FORMAT, DIFFERENTIAL;" >/dev/null
reads bh-m mssql_backups mssql_backup_checks
F2=$(q "select string_agg(object, ',' order by object) from pgvigil.mssql_backup_check_findings where instance_id=$I and check_name='pseudo-simple recovery' and object like 'pgbh4%'")
[ "$(cell bh-m pgbh4f pseudo_simple)|$(cell bh-m pgbh4s pseudo_simple)|$F2" = "no|no|pgbh4b" ] || fail "H4 after the full and the differential: pgbh4f '$(cell bh-m pgbh4f pseudo_simple)', pgbh4s '$(cell bh-m pgbh4s pseudo_simple)', findings $F2"
ok "H4: FULL and BULK_LOGGED without a backup and SIMPLE -> FULL after a full are pseudo-simple ($F), the restoring copy, model and msdb not judged, a restored database no; a full and a differential end it ($F2 left)"

echo "== H6 verify_backup through the actions door"
sq "CREATE DATABASE pgbh6; ALTER DATABASE pgbh6 SET RECOVERY FULL;" >/dev/null
sq "CREATE TABLE dbo.t (i int IDENTITY PRIMARY KEY, v char(800)); INSERT dbo.t (v) SELECT TOP (2000) 'x' FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgbh6 >/dev/null
sq "BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/a.bak' WITH FORMAT, CHECKSUM;
    BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/s1.bak', DISK = N'/backups/h6/s2.bak' WITH FORMAT, CHECKSUM;
    BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/ap.bak' WITH FORMAT, CHECKSUM;
    BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/ap.bak' WITH NOINIT, CHECKSUM;
    BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/n.bak' WITH FORMAT, NO_CHECKSUM;
    BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/gone.bak' WITH FORMAT, CHECKSUM;
    BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/i.bak' WITH FORMAT, CHECKSUM;" >/dev/null
# an encrypted full (a certificate in master)
sqin "$SQL" >/dev/null 2>&1 <<SQL || true
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'$(pw)'; CREATE CERTIFICATE pgbh_cert WITH SUBJECT = 'pgbh proof';
SQL
sq "BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/enc.bak' WITH FORMAT, ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = pgbh_cert);" >/dev/null 2>&1 || true
# the uuid of the newest set written to a file (and its position)
uuidof() { sq "SELECT TOP (1) CAST(b.backup_set_uuid AS varchar(36)) FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id WHERE f.physical_device_name = N'$1' ORDER BY b.backup_set_id DESC"; }
UA=$(uuidof /backups/h6/a.bak); UB=$(uuidof /backups/h6/s1.bak); UC=$(uuidof /backups/h6/ap.bak); UD=$(uuidof /backups/h6/n.bak); UE=$(uuidof /backups/h6/gone.bak); UF=$(uuidof /backups/h6/i.bak); UX=$(uuidof /backups/h6/enc.bak || true)
docker exec -u root "$SQL" rm -f /backups/h6/gone.bak
reads bh-m mssql_backups mssql_backup_history
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
for n in bh-kill bh-sys bh-dbc bh-nocd; do q "select pgvigil.ensure_instance('$n', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')" >/dev/null; done
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$CFG" "$USR" >/dev/null 2>&1 || fail "setup: user add"
# the UI login's body in a file of mode 600: no password on a command line (ps shows argv)
(umask 077; jq -nc --arg u "$USR" --arg p "$UPW" '{username: $u, password: $p}' > "$WORK/login.json") || fail "setup: the login body"
startserve() {
  "$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >>"$LOG" 2>&1 & SRVPID=$!
  for _ in $(seq 1 80); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.25; done
  kill -0 "$SRVPID" 2>/dev/null || fail "setup: serve exited: $(tail -5 "$LOG")"
  [ "$(curl -s -o "$BODY" -w '%{http_code}' -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/login.json" "$U/api/login")" = 200 ] || fail "setup: the UI login: $(cat "$BODY")"
}
startserve
post() { curl -s -o "$BODY" -w '%{http_code}' -b "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$2" "$U/api/mssql/actions/verify/$1"; }
jb() { jq -r "$1" "$BODY"; }
# preview <instance> <uuid>: the code; the set in $WORK/set.json
preview() { local c; c=$(post preview "$(jq -nc --argjson i "$(iid "$1")" --arg u "$2" '{instance_id: $i, backup_set_uuid: $u}')"); cp "$BODY" "$WORK/prev.json"; jq -c .set "$BODY" > "$WORK/set.json"; echo "$c"; }
# run <instance> <uuid> [confirm] [set file]: the code; the reply in $BODY
run() { post run "$(jq -nc --argjson i "$(iid "$1")" --arg u "$2" --arg c "${3:-pgbh6}" --slurpfile s "${4:-$WORK/set.json}" '{instance_id: $i, backup_set_uuid: $u, shown: $s[0], reason: "the 301b proof", confirm: $c}')"; }
# the end row of a verify of the set (not 'started'), waited for up to 120 s
endrow() { local r; for _ in $(seq 1 240); do r=$(q "select outcome || '|' || coalesce(server_message, '') || '|' || coalesce(statement, '') from pgvigil.actions_log where action='verify_backup' and target_id=upper('$1') and outcome <> 'started' order by at desc, action_id desc limit 1"); [ -n "$r" ] && { echo "$r"; return 0; }; sleep 0.5; done; echo "none"; }
audits() { q "select count(*) from pgvigil.actions_log where action='verify_backup' and target_id=upper('$1') and outcome='$2'"; }

# a: a full with checksums; a newer full before Run (the uuid names the set verified)
[ "$(preview bh-m "$UA")" = 200 ] || fail "H6a preview: $(cat "$WORK/prev.json")"
[ "$(jq -r '[.ok, (.set.paths | join(",")), .set.position, .set.has_checksums] | map(tostring) | join("|")' "$WORK/prev.json")" = "true|/backups/h6/a.bak|1|true" ] \
  && jq -r .statement "$WORK/prev.json" | grep -q 'RESTORE VERIFYONLY' && ! jq -r .statement "$WORK/prev.json" | grep -q /backups || fail "H6a preview: $(cat "$WORK/prev.json")"
sq "BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/newer.bak' WITH FORMAT, CHECKSUM;" >/dev/null; UNEW=$(uuidof /backups/h6/newer.bak)
[ "$(run bh-m "$UA")" = 202 ] && [ "$(jb .outcome)" = started ] || fail "H6a run: $(cat "$BODY")"
E=$(endrow "$UA")
[ "${E%%|*}" = done ] && [[ "$E" == *"The backup set on file 1 is valid."* ]] && [[ "$E" == *CHECKSUM* ]] && [[ "$E" != */backups* ]] || fail "H6a: the end row $E"
ok "H6a: Preview named /backups/h6/a.bak position 1 with checksums (no path in its statement); a newer full taken; Run 202 started; the set's end row done: $(cut -c1-160 <<<"$E")"
# b, c, d
[ "$(preview bh-m "$UB")" = 200 ] && [ "$(jq -r '.set.paths | join(",")' "$WORK/prev.json")" = "/backups/h6/s1.bak,/backups/h6/s2.bak" ] || fail "H6b preview: $(cat "$WORK/prev.json")"
[ "$(run bh-m "$UB")" = 202 ] || fail "H6b run: $(cat "$BODY")"; E=$(endrow "$UB"); [ "${E%%|*}" = done ] || fail "H6b: $E"
ok "H6b: the full striped over two files: both paths shown, done"
[ "$(preview bh-m "$UC")" = 200 ] && [ "$(jq -r .set.position "$WORK/prev.json")" = 2 ] || fail "H6c preview: $(cat "$WORK/prev.json")"
[ "$(run bh-m "$UC")" = 202 ] || fail "H6c run: $(cat "$BODY")"; E=$(endrow "$UC"); [ "${E%%|*}" = done ] && [[ "$E" == *"The backup set on file 2 is valid."* ]] || fail "H6c: $E"
ok "H6c: the second set of ap.bak (position 2): done, 'The backup set on file 2 is valid.'"
[ "$(preview bh-m "$UD")" = 200 ] && [ "$(jq -r .set.has_checksums "$WORK/prev.json")" = false ] || fail "H6d preview: $(cat "$WORK/prev.json")"
[ "$(run bh-m "$UD")" = 202 ] || fail "H6d run: $(cat "$BODY")"; E=$(endrow "$UD"); [ "${E%%|*}" = done ] && [[ "$E" == *"RESTORE VERIFYONLY"* ]] && [[ "$E" != *CHECKSUM* ]] || fail "H6d: $E"
ok "H6d: a full without checksums: the statement without CHECKSUM, done"

# e: refusals (each 409, one 'refused' row, nothing sent)
refused() { local name=$1 inst=$2 uuid=$3 confirm=$4 setf=$5 want=$6 before code; before=$(audits "$uuid" refused)
  code=$(run "$inst" "$uuid" "$confirm" "$setf")
  [ "$code" = 409 ] && [[ "$(jb .detail)" == *"$want"* ]] && [ "$(audits "$uuid" refused)" = $((before + 1)) ] || fail "H6e $name: $code $(cat "$BODY")"
  echo "  refused: $name - $(jb .detail | cut -c1-150)"; }
preview bh-m "$UD" >/dev/null; cp "$WORK/set.json" "$WORK/setD.json"
refused "a wrong confirmation" bh-m "$UD" pgbh6x "$WORK/setD.json" "the typed confirmation is not the database's name"
jq -c '.paths = ["/etc/passwd"]' "$WORK/setD.json" > "$WORK/crafted.json"
refused "a crafted body" bh-m "$UD" pgbh6 "$WORK/crafted.json" "is not as shown"
# lockhold: another session holds instance $I's verify lock (as a live verify does); lockfree ends that session (a
# killed psql leaves its backend in pg_sleep, the lock held, until the sleep ends) and waits until the lock is gone
lockheld() { q "select count(*) from pg_locks where locktype='advisory' and classid=30117 and objid=$I and objsubid=2 and granted"; }
lockhold() { PGAPPNAME=pgbh-lock psql "$RDSN" -XAtqc "select pg_advisory_lock(30117, $I), pg_sleep(300)" >/dev/null 2>&1 & LOCKPID=$!
  for _ in $(seq 1 40); do [ "$(lockheld)" = 1 ] && return 0; sleep 0.25; done; fail "the lock holder did not take the lock"; }
lockfree() { q "select count(pg_terminate_backend(pid)) from pg_stat_activity where application_name='pgbh-lock'" >/dev/null
  wait "$LOCKPID" 2>/dev/null || true; LOCKPID=
  for _ in $(seq 1 40); do [ "$(lockheld)" = 0 ] && return 0; sleep 0.25; done; fail "the lock holder's lock stayed"; }
lockhold; refused "the lock held" bh-m "$UD" pgbh6 "$WORK/setD.json" "one at a time"
lockfree
refused "no actions_dsn" bh-off "$UD" pgbh6 "$WORK/setD.json" "has no actions_dsn"
refused "not on the list" bh-kill "$UD" pgbh6 "$WORK/setD.json" "verify_backup is not on the instance's actions: list"
refused "a sysadmin login" bh-sys "$UD" pgbh6 "$WORK/setD.json" "is sysadmin or holds CONTROL SERVER"
refused "a dbcreator member" bh-dbc "$UD" pgbh6 "$WORK/setD.json" "is in dbcreator or holds ALTER ANY DATABASE"
refused "no CREATE DATABASE" bh-nocd "$UD" pgbh6 "$WORK/setD.json" "has no CREATE DATABASE in master"
preview bh-m "$UF" >/dev/null; cp "$WORK/set.json" "$WORK/setF.json"
sq "BACKUP DATABASE pgbh6 TO DISK = N'/backups/h6/i.bak' WITH INIT, FORMAT, CHECKSUM;" >/dev/null
refused "the file overwritten" bh-m "$UF" pgbh6 "$WORK/setF.json" "the file now holds another backup set at position 1"
ok "H6e: nine refusals, each 409 with one audit row"
# f: a removed file
preview bh-m "$UE" >/dev/null
C=$(run bh-m "$UE")
[ "$C" = 502 ] && [ "$(jb .outcome)" = failed ] && [[ "$(jb .detail)" == "RESTORE HEADERONLY failed: "* ]] && [[ "$(jb .detail)$(jb .server_message)" == *"Cannot open backup device"* ]] \
  && [[ "$(jb .detail)$(jb .server_message)" == *"Operating system error 2"* ]] && [ "$(audits "$UE" failed)" = 1 ] || fail "H6f: $C $(cat "$BODY")"
ok "H6f: the removed file: 502 failed - $(jb .detail | cut -c1-160)"
# g: an encrypted full
if [ -n "$UX" ]; then
  [ "$(preview bh-m "$UX")" = 200 ] && [ "$(jq -r .ok "$WORK/prev.json")" = false ] && [[ "$(jq -r '.reason // .set.not_offered' "$WORK/prev.json")" == "not offered: the backup is encrypted"* ]] || fail "H6g: $(cat "$WORK/prev.json")"
  ok "H6g: the encrypted full: $(jq -r .reason "$WORK/prev.json")"
else notproven "H6g: the encrypted full was not taken on this server"; fi

# h: serve stopped under a verify of a 1 GB full
sq "CREATE DATABASE pgbh6big; ALTER DATABASE pgbh6big SET RECOVERY SIMPLE;" >/dev/null
sq "CREATE TABLE dbo.t (v char(8000)); INSERT dbo.t WITH (TABLOCK) (v) SELECT TOP (130000) 'x' FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgbh6big >/dev/null
sq "BACKUP DATABASE pgbh6big TO DISK = N'/backups/h6/big.bak' WITH FORMAT, CHECKSUM;" >/dev/null
UBIG=$(uuidof /backups/h6/big.bak)
[ "$(preview bh-m "$UBIG")" = 200 ] || fail "H6h preview: $(cat "$WORK/prev.json")"
[ "$(run bh-m "$UBIG" pgbh6big)" = 202 ] || fail "H6h run: $(cat "$BODY")"
sleep 1; kill -TERM "$SRVPID"; wait "$SRVPID" 2>/dev/null || true; SRVPID=
E=$(endrow "$UBIG")
case "${E%%|*}" in
  "cut by shutdown") ok "H6h: serve stopped one second into the verify of the 1 GB full: its end row 'cut by shutdown'" ;;
  done) notproven "H6h: the verify of the 1 GB full ended before serve stopped (done): 'cut by shutdown' not seen in this run" ;;
  *) fail "H6h: the end row after the shutdown: $E" ;;
esac
# k (P3.4, RED): serve killed one second into a verify of the 1 GB full; the next start sweeps its row
startserve
T0=$(q "select now()")
[ "$(preview bh-m "$UBIG")" = 200 ] && [ "$(run bh-m "$UBIG" pgbh6big)" = 202 ] || fail "H6k run: $(cat "$BODY")"
sleep 1; kill -KILL "$SRVPID"; wait "$SRVPID" 2>/dev/null || true; SRVPID=
kseen() { q "select string_agg(outcome, ',' order by at, action_id) from pgvigil.actions_log where action='verify_backup' and target_id=upper('$UBIG') and at >= '$T0'"; }
K1=$(kseen)
# i: a 'started' row three hours old with no end; serve's start writes 'ended unknown'
q "select pgvigil.import_mssql_actions_log($I, now() - interval '3 hours', jsonb_build_array(jsonb_build_object('instance_name', 'bh-m', 'ui_user', '$USR',
   'action', 'verify_backup', 'target', 'pgbh6 full', 'target_id', upper('$UNEW'), 'reason', 'the 301b proof: a verify serve never ended', 'outcome', 'started')))" >/dev/null
startserve
G=$(q "select outcome || '|' || detail from pgvigil.actions_log where action='verify_backup' and target_id=upper('$UNEW') and outcome='ended unknown'")
[[ "$G" == "ended unknown|ended unknown: serve stopped"* ]] || fail "H6i: serve's start wrote '$G'"
ok "H6i: $G"
K2=$(kseen); KD=$(q "select detail from pgvigil.actions_log where action='verify_backup' and target_id=upper('$UBIG') and at >= '$T0' and outcome='ended unknown'")
if [ "$K1" = started ]; then
  [ "$K2" = "started,ended unknown" ] && [[ "$KD" == "ended unknown: serve stopped"* ]] || fail "H6k: after the kill '$K1', after the next start '$K2' ($KD)"
  ok "H6k: serve killed one second into the verify: its row '$K1' (seconds old, inside verify_timeout) swept at the next start: '$K2' - $KD"
else
  [ "${K1%%,*}" = started ] || fail "H6k: the rows after the kill: '$K1'"
  notproven "H6k: the verify of the 1 GB full ended before serve was killed ('$K1'): the sweep of a killed run's row not seen in this run"
fi
# l (P3.4, NEGATIVE CONTROL): no sweep while the instance's lock is held
LT=00000000-0000-0000-0000-0000000301B4
lseen() { q "select string_agg(outcome, ',' order by at, action_id) from pgvigil.actions_log where action='verify_backup' and target_id='$LT'"; }
q "select pgvigil.import_mssql_actions_log($I, now() - interval '1 minute', jsonb_build_array(jsonb_build_object('instance_name', 'bh-m', 'ui_user', '$USR',
   'action', 'verify_backup', 'target', 'pgbh6 full', 'target_id', '$LT', 'reason', 'the 301b proof: a verify that still runs', 'outcome', 'started')))" >/dev/null
lockhold
kill -TERM "$SRVPID"; wait "$SRVPID" 2>/dev/null || true; SRVPID=
startserve; sleep 2; L1=$(lseen)
lockfree
kill -TERM "$SRVPID"; wait "$SRVPID" 2>/dev/null || true; SRVPID=
startserve; sleep 2; L2=$(lseen)
[ "$L1" = started ] && [ "$L2" = "started,ended unknown" ] || fail "H6l: while the lock was held '$L1' (want started), after it was let go '$L2' (want started,ended unknown)"
ok "H6l: a minute-old 'started' row kept '$L1' through serve's start while another session held the instance's lock; with the lock let go the next start swept it: '$L2'"
# j: no path in any statement
NP=$(q "select count(*) from pgvigil.actions_log where action='verify_backup' and statement like '%/backups%'"); NA=$(q "select count(*) from pgvigil.actions_log where action='verify_backup'")
NS=$(q "select count(*) from pgvigil.actions_log where action='verify_backup' and statement like 'RESTORE VERIFYONLY%'")
[ "$NP" = 0 ] && [ "$NS" -gt 0 ] || fail "H6j: $NP of $NA verify_backup rows hold a path in their statement; $NS hold a RESTORE VERIFYONLY statement (want more than 0)"
ok "H6j: none of the $NA verify_backup rows holds a path in its statement ($(q "select string_agg(outcome || ' ' || n, ', ' order by outcome) from (select outcome, count(*) n from pgvigil.actions_log where action='verify_backup' group by outcome) x"))"

echo "== I the page in a headless Chromium"
if command -v chromium >/dev/null && command -v node >/dev/null && [ -z "${PROOF_SKIP_PAGE:-}" ]; then
  # the read line while SELECT on restorehistory is denied (7fe457f5's page line: it compared the payload word and so
  # never showed): the read stores the state, the page draws the stored one
  sq "DENY SELECT ON OBJECT::dbo.restorehistory TO pgbh_mon;" msdb >/dev/null
  reads bh-m mssql_backup_history mssql_backup_checks
  sq "REVOKE SELECT ON OBJECT::dbo.restorehistory FROM pgbh_mon;" msdb >/dev/null
  (cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "I: npm install axe-core failed"
  CDP=$((PORT + 1)); chromium --headless=new ${PGVIGIL_CHROMIUM_FLAGS:-} --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
  CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  # the menu check (J16 GRIDMENU VERIFY): one log backup of pgbh6 to a URL, stored after the last read (msdb has no such
  # set: the store keeps it until the next history read; a log, alone in its type, inside the newest 10 the page shows)
  UURL=$(python3 -c 'import uuid; print(uuid.uuid4())')
  q "insert into pgvigil.mssql_backup_history select (jsonb_populate_record(h, jsonb_build_object('backup_set_uuid', '$UURL',
      'backup_set_id', h.backup_set_id + 100000, 'backup_type', 'L', 'is_copy_only', false, 'device_kind', 'url',
      'path', 'https://pgbh.blob.core.windows.net/c/pgbh6.trn', 'family_count', 1, 'position', 1))).*
     from pgvigil.mssql_backup_history h where h.instance_id = $I and h.database_name = 'pgbh6' order by h.backup_set_id limit 1" >/dev/null \
    || fail "I: the stored URL backup of pgbh6"
  NH=$(q "select count(*) from pgvigil.mssql_backup_history where instance_id=$I and database_name='pgbh6'")
  cat > "$WORK/page.mjs" <<'JS'
const [port, U, axePath, inst, user, urlUuid] = process.argv.slice(2);
const pass = process.env.PGV_PROOF_UPW ?? '';
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => (await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, s = 30) => { for (let i = 0; i < s * 4; i++) { if (await ev(expr)) return true; await sleep(250); } return false; };
const heads = sel => `[...document.querySelectorAll('${sel} table.grid > thead > tr:first-child > th')].map(h => (h.childNodes[0]?.textContent ?? h.textContent).trim())`;
await cmd('Page.navigate', { url: U }); await sleep(800);
const login = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(user)}, password: ${JSON.stringify(pass)} }) }).then(r => r.status)`, true);
// the app read its session when it loaded (signed out): a whole reload, so it starts signed in (a hash change alone
// keeps the page it loaded)
await cmd('Page.reload'); await sleep(800);
const out = { login };
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const [name, hash, ready] of [['hist', `#/mssqlbackups?i=${inst}&db=pgbh6`, `!!document.querySelector('#mssql-backups-history-grid table.grid')`],
                                     ['rest', `#/mssqlbackups?i=${inst}&db=pgbh2r`, `!!document.querySelector('#mssql-backups-restores-grid table.grid')`]]) {
    await cmd('Page.navigate', { url: U + hash }); await sleep(300);
    const drawn = await until(ready);
    const r = { drawn, errors: await ev(`document.querySelectorAll('main .error').length`),
                errText: await ev(`[...document.querySelectorAll('main .error')].map(e => e.textContent.trim().slice(0, 300)).join(' | ')`) };
    if (theme === 'light' && name === 'hist') {
      r.head = await ev(heads('#mssql-backups-history-grid'));
      r.rows = await ev(`document.querySelectorAll('#mssql-backups-history-grid table.grid > tbody > tr').length`);
      r.verified = await ev(`[...document.querySelectorAll('#mssql-backups-history-grid [data-verify-uuid]')].map(e => e.getAttribute('data-full'))`);
      r.buttons = await ev(`document.querySelectorAll('#mssql-backups-history-grid button.act-verify').length`);
      r.checks = await ev(`!!document.querySelector('#mssql-backups-checks-grid table.grid')`);
      r.noright = await ev(`document.querySelector('main').innerText.includes('the restores: not read: no right (SELECT on msdb.dbo.restorehistory) - the restores read before stay')`);
      // the grid's right-click menu on a row's first cell: a disk row (it has a Verify button), then the stored URL row
      const menuAt = row => `(() => { const td = ${row}?.closest('tr')?.querySelector('td'); if (!td) return null;
        td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
        const m = [...document.querySelectorAll('.menu [role=menuitem]')].map(b => b.textContent); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); return m; })()`;
      r.menu = await ev(menuAt(`document.querySelector('#mssql-backups-history-grid button.act-verify')`));
      await sleep(200);
      r.menuUrl = await ev(menuAt(`document.querySelector('#mssql-backups-history-grid [data-verify-uuid="${urlUuid}"]')`));
    }
    if (theme === 'light' && name === 'rest') r.rows = await ev(`document.querySelectorAll('#mssql-backups-restores-grid table.grid > tbody > tr').length`);
    await cmd('Runtime.evaluate', { expression: axeSrc });
    r.violations = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(x => x.target.join(' ')) }))))`, true) ?? '[]');
    out[`${name}-${theme}`] = r;
  }
}
console.log(JSON.stringify(out));
process.exit(0);
JS
  PGV_PROOF_UPW="$UPW" node "$WORK/page.mjs" "$CDP" "$U/" "$WORK/node_modules/axe-core/axe.min.js" "$I" "$USR" "$UURL" > "$WORK/page.json" 2> "$WORK/page.err" || fail "I: the page check did not run: $(tail -c 400 "$WORK/page.err")"
  kill "$CHR" 2>/dev/null || true; CHR=
  NH=$NH python3 - "$WORK/page.json" <<'PYI' || fail "I: the page"
import json, os, sys
d = json.load(open(sys.argv[1]))
want = ["database", "recovery model", "type", "start date", "finish date", "duration", "backup size", "backup MB/s", "backup size (compressed)",
        "compression saving %", "backup write MB/s", "is damaged", "checksum", "is compressed", "password protected", "encrypted",
        "snapshot backup", "has bulk logged data", "readonly", "force offline", "single user", "key algorithm", "encryptor type",
        "compression algorithm", "last verify", "to (the first file)", "files", "position in the file", "device", "taken by", "machine", "set name",
        "copy-only", "first LSN", "last LSN", "checkpoint LSN", "database backup LSN", "base (a differential's full)", "backup set"]
bad = []
if d.pop("login", None) != 200: bad.append("the page's sign-in did not answer 200")
for k, r in d.items():
    if not r["drawn"] or r["errors"]: bad.append(f"{k}: drawn {r['drawn']}, error boxes {r['errors']}: {r.get('errText', '')}")
    n = sum(v["n"] for v in r["violations"])
    if n: bad.append(f"{k}: {n} axe violation node(s): {r['violations']}")
h = d["hist-light"]
if h.get("head") != want: bad.append(f"the Backup history header: {h.get('head')}")
if h.get("rows") != int(os.environ["NH"]): bad.append(f"the Backup history rows: {h.get('rows')}, want {os.environ['NH']}")
if not any(str(v).startswith("done ") for v in h.get("verified") or []): bad.append(f"no last verify cell 'done ...': {h.get('verified')}")
if not h.get("buttons"): bad.append("no Verify button")
if not h.get("checks"): bad.append("no Backup checks grid")
if not h.get("noright"): bad.append("the read line without 'the restores: not read: no right (SELECT on msdb.dbo.restorehistory) - the restores read before stay'")
if "Verify this backup..." not in (h.get("menu") or []): bad.append(f"the right-click menu on a disk row: {h.get('menu')}")
if not h.get("menuUrl") or "Verify this backup..." in h["menuUrl"]: bad.append(f"the right-click menu on the URL row (drawn, no Verify): {h.get('menuUrl')}")
if d["rest-light"].get("rows") != 2: bad.append(f"the Restore history of pgbh2r: {d['rest-light'].get('rows')} rows")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"ok   I: light and dark: drawn, no error box, 0 axe violation nodes; Backup history header = DBA Dash's 24 + pgvigil's 15 in order, {h['rows']} rows, {h['buttons']} Verify buttons, a 'done' last verify, the menu {h['menu']} (the URL row's without Verify); Backup checks drawn, the denied read's line shown; pgbh2r's Restore history 2 rows")
PYI
else notproven "I: the page - no chromium or node here (or PROOF_SKIP_PAGE)"; fi

echo "== H5 the default backup path (Instance#14)"
reads bh-m mssql_properties mssql_backup_checks
prop() { q "select coalesce(value, 'NULL') || '|' || coalesce(note, '') from pgvigil.mssql_property where instance_id=$I and name='default_backup_path'"; }
path() { q "select coalesce(default_backup_path, 'NULL') || '|' || coalesce(reachable, 'NULL') from pgvigil.mssql_backup_path_cells where instance_id=$I"; }
pfind() { q "select count(*) from pgvigil.mssql_backup_check_findings where instance_id=$I and check_name='default backup path not reachable'"; }
apirow() { curl -s -b "$CJ" "$U/api/mssql/properties?instance=$I" | jq -r '.properties as $p | [$p.rows[] | [$p.columns, .] | transpose | map({(.[0]): .[1]}) | add] | map(select(.name == "default_backup_path_reachable")) | .[0] | "\(.value)|\(.note)"'; }
[ "$(prop)" = "/var/opt/mssql/data|" ] && [ "$(path)" = "/var/opt/mssql/data|yes" ] && [ "$(pfind)" = 0 ] && [[ "$(apirow)" == "yes|a directory the service account sees"* ]] \
  || fail "H5: the property '$(prop)', the cell '$(path)', $(pfind) findings, the API's row '$(apirow)'"
ok "H5: default_backup_path /var/opt/mssql/data, reachable yes, no finding; the API's Properties row '$(apirow)'"
docker exec -u root "$SQL" bash -c 'mkdir -p /var/opt/mssql/pgbhbk && chown mssql /var/opt/mssql/pgbhbk && /opt/mssql/bin/mssql-conf set filelocation.defaultbackupdir /var/opt/mssql/pgbhbk' >"$WORK/conf.out" 2>&1 \
  || fail "H5: mssql-conf: $(cat "$WORK/conf.out")"
docker restart "$SQL" >/dev/null; up "$SQL" || fail "H5: SQL Server did not come back"; port22; dsns
reads bh-m mssql_properties mssql_backup_checks
CH=$(q "select old_value || ' -> ' || new_value from pgvigil.mssql_property_change where instance_id=$I and name='default_backup_path'")
[ "$(prop)" = "/var/opt/mssql/pgbhbk|" ] && [ "$(path)" = "/var/opt/mssql/pgbhbk|yes" ] && [ "$CH" = "/var/opt/mssql/data -> /var/opt/mssql/pgbhbk" ] \
  || fail "H5 after mssql-conf: '$(prop)', '$(path)', the change '$CH'"
docker exec -u root "$SQL" bash -c 'chown root:root /var/opt/mssql/pgbhbk && chmod 700 /var/opt/mssql/pgbhbk'
reads bh-m mssql_backup_checks
[ "$(path)" = "/var/opt/mssql/pgbhbk|yes" ] && [ "$(pfind)" = 0 ] || fail "H5 the folder given to root: '$(path)', $(pfind) findings"
docker exec -u root "$SQL" rm -rf /var/opt/mssql/pgbhbk
reads bh-m mssql_backup_checks
D=$(q "select detail from pgvigil.mssql_backup_check_findings where instance_id=$I and check_name='default backup path not reachable'")
[ "$(path)" = "/var/opt/mssql/pgbhbk|no" ] && [ "$D" = "the default backup path /var/opt/mssql/pgbhbk is not a directory the service account sees" ] && [ "$(apirow)" = "no|not a directory the service account sees" ] \
  || fail "H5 the folder removed: '$(path)', the finding '$D', the API's row '$(apirow)'"
ok "H5: mssql-conf's path stored with its change ($CH); given to root (mode 700) still a directory and no finding; removed: reachable no, the finding '$D', the API's row '$(apirow)'"

echo "== H7 SQL Server 2019"
if [ -z "${PROOF_SKIP_2019:-}" ]; then
  sqn "$SQL19" master "CREATE DATABASE pgbh7; ALTER DATABASE pgbh7 SET RECOVERY FULL; CREATE DATABASE pgbh7v; ALTER DATABASE pgbh7v SET RECOVERY SIMPLE;" >/dev/null
  sqn "$SQL19" master "BACKUP DATABASE pgbh7v TO DISK = N'/var/opt/mssql/data/pgbh7v.bak' WITH FORMAT, CHECKSUM;" >/dev/null
  reads bh-19 mssql_backups mssql_backup_history mssql_backup_checks
  I19=$(iid bh-19)
  G=$(q "select concat_ws('|', (select default_backup_path || '/' || reachable from pgvigil.mssql_backup_path_cells where instance_id=$I19),
        (select pseudo_simple from pgvigil.mssql_backup_check_cells where instance_id=$I19 and database_name='pgbh7'),
        (select count(*) from pgvigil.mssql_backup_history where instance_id=$I19 and database_name='pgbh7v'))")
  [ "$G" = "/var/opt/mssql/data/yes|yes: FULL, $Y|1" ] || fail "H7: $G"
  U19=$(sqn "$SQL19" master "SELECT TOP (1) CAST(backup_set_uuid AS varchar(36)) FROM msdb.dbo.backupset WHERE database_name = N'pgbh7v' ORDER BY backup_set_id DESC")
  [ "$(preview bh-19 "$U19")" = 200 ] || fail "H7 preview: $(cat "$WORK/prev.json")"
  [ "$(run bh-19 "$U19" pgbh7v)" = 202 ] || fail "H7 run: $(cat "$BODY")"
  E=$(endrow "$U19"); [ "${E%%|*}" = done ] && [[ "$E" == *"The backup set on file 1 is valid."* ]] || fail "H7 verify: $E"
  ok "H7: SQL Server $(sqn "$SQL19" master "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"): $G; the verify done (HEADERONLY's 56 columns read by name)"
else notproven "H7: PROOF_SKIP_2019"; fi

echo "NOT PROVEN: Windows (a share's root that does not answer, the service account on a share, SQL Server 2017's registry read), Azure SQL Managed Instance, Amazon RDS - their words are unit tests"
echo "ALL ROWS GREEN"
