#!/usr/bin/env bash
# Proof of SQL Server log shipping read from restore history (task 384; migration 0143, internal/mssql/logshipping.go)
# and of the log shipping extras (task LSX, parts I-M: the jobs, msdb's own alert, a log backup outside log shipping,
# the primary's recovery model):
# a REAL pair of SQL Server 2022 containers sharing one Docker volume for the log backups, the primary on a clock
# eight hours off UTC (backupset.time_zone), log restores applied by hand and by SQL Server's own log shipping jobs.
#
# Needs: docker, psql, python3, a go toolchain at the repository root, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=...)
# Optional: PGVIGIL_MSSQL_IMAGE (default mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04: the release pin
# of the other SQL Server labs), PGVIGIL_BIN (default: built here into the run's own folder).
#
# What it makes, and removes on every exit path (only what this run made, by its tag pgvls<8 hex>): two containers
# <tag>-pri and <tag>-sec (hostname = name, so @@SERVERNAME = the name: checked), the network <tag>-net and the volume
# <tag>-ship mounted at /var/opt/mssql/ship in both, each labelled pgvls=<tag>; published on 127.0.0.1 only; its own
# repository database. The sa password is random, never printed, reaches sqlcmd through the environment by name.
#
# Expected (written before the first run):
#  A. the lab: both servers answer, @@SERVERNAME = <tag>-pri / <tag>-sec, SQL Server Agent running on both; the
#     primary's offset from UTC -480 or -420 minutes (TZ=America/Los_Angeles), the secondary's 0. If the primary
#     ignores TZ (offset 0) the line says 'time zone NOT PROVEN' and the rest goes on.
#  B. a manual pair lsm: a full backup on the primary restored WITH NORECOVERY on the secondary, then three log backups
#     restored WITH NORECOVERY. The secondary's read (as a login with VIEW SERVER STATE, VIEW ANY DEFINITION and
#     db_datareader in msdb) stores lsm as kind 'restore', RESTORING, FULL, not mirrored, not in a group; its last log
#     restore equal to sa's newest restorehistory row of type L for lsm (UTC, within 2 s); the pair's source server
#     <tag>-pri and source database lsm; the log backup's start equal to the primary's own backupset row converted
#     there by its own offset (within 2 s), backup_time_zone = the primary's offset / 15 (-32 or -28); the sample's
#     latency between 0 and 5 minutes (not 480 off). TestHADRS3StatementsLive passes against the secondary as that login.
#  C. tiers. The instance's logship_restore_age at 0.5 / 1 minute (rows of pg_thresholds inserted directly: the
#     Thresholds page's path, import_pg_threshold, takes a SQL Server instance only with 0142, and is not proven here)
#     while new_database_hours is the default 24: lsm raises nothing 35 s on (a new database: the exemption at work).
#     With new_database_hours 0 from the configuration and a log restore made right then (the age counts from it):
#     'log restores are behind' warning once more than 30 s pass after that restore, critical after 60 s. A log backup restored 40 s after it was taken, with
#     logship_restore_latency at 0.5 / 60 minutes and the age back to 60 / 120: the latency alone makes the warning,
#     its text naming a latency of 1 minute or less (rounded) - one finding for lsm, never two.
#  D. sp_Blitz check 111: lsr restored WITH NORECOVERY from a full backup and nothing after it. With restoring_days 2
#     (the default) nothing; with restoring_days 0.0005 (43 s) at the instance and 45 s waited: 'a database has been
#     restoring for days' warning naming lsr and 'a full restore'; with the age tiers at 0.5 / 1 minute meanwhile, lsr
#     never in 'log restores are behind' (it was never log-restored: judged by its full restore it would be).
#  F. SQL Server's own log shipping (msdb's procedures: a primary database lsw, its backup job, the secondary's copy and
#     restore jobs, restore_threshold 1 minute) on the same pair: the secondary's read stores lsw twice - msdb's monitor
#     row (kind secondary, its threshold 1) and the restore-history row - and after the restore job is disabled and
#     65 s pass: 'log shipping is behind its threshold' (msdb's, warning) and, with the age tiers at 0.5 / 60, no
#     'log restores are behind' warning for lsw (msdb's threshold is its warning); with the age critical at 1 minute
#     the critical 'log restores are behind' appears for lsw beside msdb's warning. Each job is waited on until its
#     outcome row is written. If msdb's procedures refuse on Linux, F prints 'msdb log shipping NOT PROVEN: <message>'
#     and the rest goes on; a restore job that restores no log fails the run.
#  G. a missing copy: lsm dropped on the secondary; the next read stores lsm as kind 'pair' (no database) with its source
#     and raises 'a log shipping copy is missing' (warning) for it; no 'restore' row of lsm is left.
#  H. the primary's read: none of its ONLINE databases is a restore row (the primary is not judged as a secondary).
#  The log shipping extras (task LSX), on F's pair lsw, the primary read too; skipped with F when msdb's procedures refuse:
#  I. log shipping's jobs: with the three jobs disabled (F left them so) 'a log shipping job is disabled' critical for
#     LSCopy_lsw and LSRestore_lsw on the secondary and for LSBackup_lsw on the primary, 'is disabled' in the detail;
#     the restore job enabled again with no schedule (msdb's procedures make the jobs without one: sa's own count 0)
#     still critical, 'has no enabled schedule'; a schedule every minute attached to each of the three and the jobs
#     enabled: no such finding, the stored interval 1 minute each. The statements pass live against the primary as
#     the monitoring login with the configuration present. The monitor's alert job, if msdb made one here, is printed
#     with the stored jobs, never asserted.
#  J. msdb's own alert: F made both configurations with the alert off: 'the log shipping alert is off' info on both;
#     the secondary's restore threshold 1 minute with its restore job every minute: 'a log shipping alert threshold is
#     under three times its job interval' info with Microsoft's words (error 14421); none for the primary (60 minutes,
#     the backup job every minute). The secondary's alert on and its threshold 45 minutes
#     (sp_change_log_shipping_secondary_database): both gone there.
#  K. a log backup outside log shipping: a COPY_ONLY log backup of lsw to another folder: no stored row, no finding
#     (none for log shipping's own backups either, at least one by then); a plain log backup there: 'a log backup
#     outside log shipping broke the chain' critical on the primary naming that file, '1 log backup', the log shipping
#     folder and the job 'not known' (this proof reads no job history); a second one: '2 log backups', the newest named.
#  L. the primary's recovery model: BULK_LOGGED -> 'a log-shipped database is in BULK_LOGGED recovery' warning; SIMPLE
#     -> 'a log-shipped database is in SIMPLE recovery' critical with Microsoft's sentence, the warning gone; FULL
#     again -> neither.
#  M. a job gone: the copy job deleted (sp_delete_job) while the configuration names it: 'a log shipping job is
#     missing' critical naming the copy job's id. If SQL Server refuses the delete, M prints 'M NOT PROVEN' with its words.
#  NOT PROVEN HERE: the SIMPLE-recovery exclusion of the tiers (DBA Dash's recovery_model <> 3: a SIMPLE database takes
#  no log backup, so no real one has a log restore to judge; the clause is kept as DBA Dash's); a mirrored database
#  (excluded: proven on the Windows mirroring lab, scripts/proof-mssql-mirroring.sh M8); an availability group secondary
#  that reads RESTORING (no lab here makes one: a group's secondary database reads ONLINE and the reader never reads it;
#  the exclusion is proven over stub rows, scripts/proof-mssql-hadr.sh stubs); the RECOVERING-after-a-log-restore
#  branch of the reader; backupset.time_zone 127 (unknown: this server's offset taken); the latency's critical tier; a STANDBY
#  (read-only) secondary of SQL Server's log shipping (the restore jobs here use NORECOVERY); a share between two
#  machines (one Docker volume stands in for it). Of the extras: Windows paths with a UNC backup_share (the folder test
#  runs on Linux paths here; Windows-shaped rows are in the store test only); the job named for a foreign log backup
#  (this proof reads no job history: 'not known' here, 'probably the job ...' in the store test only); the monitor's
#  alert job disabled; a monitor on a third server.
set -euo pipefail
IMAGE=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of the PostgreSQL sandbox}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
TAG=pgvls$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
PRI=$TAG-pri; SEC=$TAG-sec; NET=$TAG-net; VOL=$TAG-ship
REPO_DB=pgvigil_lsproof_${TAG#pgvls}
LM=pgvls_mon
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SA=$(pw); PM=$(pw)
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok $*"; }
MADE_LAB=; MADE_REPO=
cleanup() {
  rc=$?
  set +e
  if [ -n "$MADE_LAB" ]; then
    for c in $(docker ps -a -q --filter "label=pgvls=$TAG"); do docker rm -f -v "$c" >/dev/null 2>&1; done
    docker network rm "$NET" >/dev/null 2>&1; docker volume rm "$VOL" >/dev/null 2>&1
    left="$(docker ps -a -q --filter "label=pgvls=$TAG" | wc -l) containers, $(docker network ls -q --filter "label=pgvls=$TAG" | wc -l) networks, $(docker volume ls -q --filter "label=pgvls=$TAG" | wc -l) volumes"
    echo "cleanup of $TAG: left $left"
    [ "$left" = "0 containers, 0 networks, 0 volumes" ] || { echo "CLEANUP: the lab $TAG is not removed in full" >&2; [ $rc = 0 ] && rc=1; }
  fi
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || { echo "CLEANUP: database $REPO_DB not dropped" >&2; [ $rc = 0 ] && rc=1; }; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
command -v go >/dev/null 2>&1 && [ -f go.mod ] || fail "run from the repository root with a go toolchain"
command -v docker >/dev/null || fail "docker is not on this machine"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"; BIN=$WORK/pgvigil; fi

export SQLCMDPASSWORD=$SA
sqn() { local ct=$1 db=$2; shift 2; docker exec -e SQLCMDPASSWORD "$ct" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "$db" -Q "SET NOCOUNT ON; $1"; }
sp() { sqn "$PRI" "${2:-master}" "$1"; }
ss() { sqn "$SEC" "${2:-master}" "$1"; }
sqin() { docker exec -i -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

echo "--- A. the lab $TAG ($IMAGE)"
docker network create --label "pgvls=$TAG" "$NET" >/dev/null; MADE_LAB=1
docker volume create --label "pgvls=$TAG" "$VOL" >/dev/null
PPORT=$(freeport); SPORT=$(freeport)
export MSSQL_SA_PASSWORD=$SA   # docker run takes it from the environment by name (-e MSSQL_SA_PASSWORD), never as a value
docker run -d --name "$PRI" --hostname "$PRI" --network "$NET" --label "pgvls=$TAG" -p "127.0.0.1:$PPORT:1433" \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_AGENT_ENABLED=true -e MSSQL_MEMORY_LIMIT_MB=1536 -e TZ=America/Los_Angeles \
  -v "$VOL:/var/opt/mssql/ship" "$IMAGE" >/dev/null < /dev/null
docker run -d --name "$SEC" --hostname "$SEC" --network "$NET" --label "pgvls=$TAG" -p "127.0.0.1:$SPORT:1433" \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_AGENT_ENABLED=true -e MSSQL_MEMORY_LIMIT_MB=1536 \
  -v "$VOL:/var/opt/mssql/ship" "$IMAGE" >/dev/null < /dev/null
for ct in "$PRI" "$SEC"; do
  up=; for _ in $(seq 1 90); do sqn "$ct" master "SELECT 1" >/dev/null 2>&1 && { up=1; break; }; sleep 2; done
  [ -n "$up" ] || fail "A: $ct does not answer after 180 s"
done
docker exec -u 0 "$PRI" chown 10001:0 /var/opt/mssql/ship
[ "$(sp "SELECT @@SERVERNAME")" = "$PRI" ] || fail "A: @@SERVERNAME of $PRI is $(sp "SELECT @@SERVERNAME")"
[ "$(ss "SELECT @@SERVERNAME")" = "$SEC" ] || fail "A: @@SERVERNAME of $SEC is $(ss "SELECT @@SERVERNAME")"
for ct in "$PRI" "$SEC"; do
  ag=; for _ in $(seq 1 30); do [ "$(sqn "$ct" master "SELECT COUNT(*) FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status_desc = 'Running'")" = 1 ] && { ag=1; break; }; sleep 2; done
  [ -n "$ag" ] || fail "A: SQL Server Agent is not running on $ct"
done
POFF=$(sp "SELECT DATEPART(TZOFFSET, SYSDATETIMEOFFSET())"); SOFF=$(ss "SELECT DATEPART(TZOFFSET, SYSDATETIMEOFFSET())")
TZPROVEN=1
if [ "$POFF" = 0 ]; then TZPROVEN=; echo "  time zone NOT PROVEN: $PRI ignored TZ (offset 0)"; else
  [[ "$POFF" == -480 || "$POFF" == -420 ]] || fail "A: $PRI's offset is $POFF minutes"; fi
[ "$SOFF" = 0 ] || fail "A: $SEC's offset is $SOFF minutes"
ok "A: $PRI and $SEC answer, @@SERVERNAME as named, Agent running on both, offsets $POFF / $SOFF minutes"

# the monitoring login on both (the collections' least rights)
for ct in "$PRI" "$SEC"; do
  sqin "$ct" <<<"CREATE LOGIN [$LM] WITH PASSWORD = '$PM', CHECK_POLICY = OFF;"
  sqn "$ct" master "GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];"
  sqn "$ct" msdb "CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];"
done
export MSSQL_PRI_DSN="sqlserver://$LM:$PM@127.0.0.1:$PPORT?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_SEC_DSN="sqlserver://$LM:$PM@127.0.0.1:$SPORT?database=master&encrypt=true&TrustServerCertificate=true"
psql "$ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
NP=proof-ls-pri-${TAG#pgvls}; NS=proof-ls-sec-${TAG#pgvls}
config() {   # config <the secondary's mssql_thresholds block>
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $NP
    engine: sqlserver
    dsn: env:MSSQL_PRI_DSN
  - name: $NS
    engine: sqlserver
    dsn: env:MSSQL_SEC_DSN
$1
EOF
}
config ""
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once mssql_logshipping -instance "$1" > "$OUT" 2>&1 || { cat "$OUT"; fail "the read of $1"; }; grep -q 'partial\|skipped' "$OUT" && { cat "$OUT"; fail "the read of $1 is partial or skipped"; }; true; }
SHIP=/var/opt/mssql/ship
logback() { sp "BACKUP LOG [$1] TO DISK = '$SHIP/$2' WITH INIT, FORMAT;" >/dev/null; }
logrest() { ss "RESTORE LOG [$1] FROM DISK = '$SHIP/$2' WITH NORECOVERY;" >/dev/null; }
seed() {   # seed <db> <recovery>: made on the primary, a full backup restored WITH NORECOVERY on the secondary
  sp "CREATE DATABASE [$1]; ALTER DATABASE [$1] SET RECOVERY $2;" >/dev/null
  sp "CREATE TABLE dbo.t (id int IDENTITY PRIMARY KEY, at datetime2 DEFAULT SYSUTCDATETIME()); INSERT dbo.t DEFAULT VALUES;" "$1" >/dev/null
  sp "BACKUP DATABASE [$1] TO DISK = '$SHIP/$1_full.bak' WITH INIT, FORMAT;" >/dev/null
  ss "RESTORE DATABASE [$1] FROM DISK = '$SHIP/$1_full.bak' WITH NORECOVERY;" >/dev/null
}
setthr() {   # setthr <key> <warn> <crit>: the secondary's instance-level row, the previous one of that key ended
  q "update pgvigil.pg_thresholds set ended_at = now(), ended_by = 'proof' where ended_at is null and key = '$1' and level = 'instance' and instance_id = $IS;
     insert into pgvigil.pg_thresholds (key, level, instance_id, warn, crit, created_by, created_at) values ('$1', 'instance', $IS, $2, $3, 'proof', now())" >/dev/null
}
finding() {  # finding <check> <object prefix>: the severity of that finding of the secondary, or nothing
  q "select string_agg(severity, ',' order by severity) from pgvigil.mssql_hadr_findings where instance_id = $IS and check_name = '$1' and object like '$2%'"
}

echo "--- B. a manual pair lsm read from restore history"
seed lsm FULL
for n in 1 2 3; do sp "INSERT dbo.t DEFAULT VALUES;" lsm >/dev/null; logback lsm "lsm_$n.trn"; logrest lsm "lsm_$n.trn"; done
collect "$NS"
IS=$(q "select instance_id from pgvigil.instances where name = '$NS'")
row=$(q "select kind, database_state, recovery_model, is_mirrored, in_availability_group, source_server, source_database, backup_time_zone from pgvigil.mssql_logrestore_state where instance_id = $IS and database_name = 'lsm'")
echo "  stored: $row"
IFS='|' read -r kind st rm mir inag srv sdb tz <<<"$row"
[ "$kind|$st|$rm|$mir|$inag|$srv|$sdb" = "restore|RESTORING|FULL|f|f|$PRI|lsm" ] || fail "B: lsm stored as $row"
SA_RESTORE=$(ss "SELECT CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), MAX(restore_date)), 126) FROM msdb.dbo.restorehistory WHERE destination_database_name = 'lsm' AND restore_type = 'L'")
d=$(q "select abs(extract(epoch from last_log_restore_at - '${SA_RESTORE}Z'::timestamptz)) from pgvigil.mssql_logrestore_state where instance_id = $IS and database_name = 'lsm'")
python3 -c "import sys; sys.exit(0 if float('$d') <= 2 else 1)" || fail "B: the last log restore is $d s off sa's ${SA_RESTORE}Z"
PRI_START=$(sp "SELECT TOP (1) CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), backup_start_date), 126) FROM msdb.dbo.backupset WHERE database_name = 'lsm' AND type = 'L' ORDER BY backup_set_id DESC")
d=$(q "select abs(extract(epoch from last_log_backup_start_at - '${PRI_START}Z'::timestamptz)) from pgvigil.mssql_logrestore_state where instance_id = $IS and database_name = 'lsm'")
python3 -c "import sys; sys.exit(0 if float('$d') <= 2 else 1)" || fail "B: the log backup's start is $d s off the primary's own ${PRI_START}Z (time zone $tz)"
if [ -n "$TZPROVEN" ]; then [ "$tz" = $((POFF / 15)) ] || fail "B: backup_time_zone $tz, the primary's offset is $POFF minutes"; fi
lat=$(q "select latency_minutes from pgvigil.mssql_logrestore_sample where instance_id = $IS and database_name = 'lsm' order by snapshot_at desc limit 1")
python3 -c "import sys; sys.exit(0 if 0 <= float('$lat') <= 5 else 1)" || fail "B: the latency is $lat minutes"
ok "B: lsm restore row as sa reads it (restore and backup start within 2 s; time zone $tz; latency $lat min)"
echo "  the statements live against $SEC as $LM:"
PGVIGIL_MSSQL_TEST_DSN="$MSSQL_SEC_DSN" go test -count=1 -run 'TestHADRS3StatementsLive' ./internal/mssql/ > "$OUT" 2>&1 || { cat "$OUT"; fail "B: TestHADRS3StatementsLive"; }
ok "B: TestHADRS3StatementsLive passes against $SEC"

echo "--- C. the tiers"
setthr logship_restore_age 0.5 1; setthr logship_restore_latency 60 120
sleep 35; collect "$NS"
[ -z "$(finding 'log restores are behind' lsm)" ] || fail "C: lsm judged inside new_database_hours 24: '$(finding 'log restores are behind' lsm)'"
ok "C: inside new_database_hours 24 nothing, with the age at 0.5 / 1 minute and the last restore 35 s old"
config "    mssql_thresholds:
      new_database_hours: 0"
# a log restore now: the age counts from it (B's collect and go test would otherwise move it by their own time)
sp "INSERT dbo.t DEFAULT VALUES;" lsm >/dev/null; logback lsm lsm_3b.trn; logrest lsm lsm_3b.trn
sleep 35; collect "$NS"
[ "$(finding 'log restores are behind' lsm)" = warning ] || fail "C: after 35 s: '$(finding 'log restores are behind' lsm)', want warning"
sleep 30; collect "$NS"
[ "$(finding 'log restores are behind' lsm)" = critical ] || fail "C: after 65 s: '$(finding 'log restores are behind' lsm)', want critical"
ok "C: the age tiers: warning after 35 s, critical after 65 s"
setthr logship_restore_age 60 120; setthr logship_restore_latency 0.5 60
sp "INSERT dbo.t DEFAULT VALUES;" lsm >/dev/null; logback lsm lsm_4.trn; sleep 40; logrest lsm lsm_4.trn
collect "$NS"
sev=$(finding 'log restores are behind' lsm); det=$(q "select detail from pgvigil.mssql_hadr_findings where instance_id = $IS and check_name = 'log restores are behind' and object like 'lsm%'")
[ "$sev" = warning ] || fail "C: the late restore: '$sev', want one warning"
grep -q 'started 1 minutes before it ran\|started 0 minutes before it ran' <<<"$det" || fail "C: the detail does not name the latency: $det"
ok "C: the latency tier alone: one warning ($det)"

echo "--- D. sp_Blitz 111: lsr left RESTORING after a full restore"
seed lsr FULL
collect "$NS"
[ -z "$(finding 'a database has been restoring for days' lsr)" ] || fail "D: lsr judged with restoring_days 2"
setthr logship_restore_age 0.5 1   # a read of lsr by its full restore would show as 'log restores are behind'
setthr restoring_days 0.0005 null; sleep 45; collect "$NS"
[ "$(finding 'a database has been restoring for days' lsr)" = warning ] || fail "D: '$(finding 'a database has been restoring for days' lsr)', want warning"
q "select detail from pgvigil.mssql_hadr_findings where instance_id = $IS and check_name = 'a database has been restoring for days' and object = 'lsr'" | grep -q 'a full restore' || fail "D: the detail does not name the full restore"
[ -z "$(finding 'log restores are behind' lsr)" ] || fail "D: lsr also judged as log shipping"
ok "D: lsr warned once (sp_Blitz 111), not as log shipping"

echo "--- F. SQL Server's own log shipping (msdb's procedures)"
FOK=1
sp "CREATE DATABASE [lsw]; ALTER DATABASE [lsw] SET RECOVERY FULL;" >/dev/null
docker exec -u 0 "$PRI" mkdir -p "$SHIP/lsw" "$SHIP/lswcopy"; docker exec -u 0 "$PRI" chown -R 10001:0 "$SHIP/lsw" "$SHIP/lswcopy"
if ! sp "DECLARE @j uniqueidentifier, @p uniqueidentifier;
EXEC master.dbo.sp_add_log_shipping_primary_database @database = N'lsw', @backup_directory = N'$SHIP/lsw', @backup_share = N'$SHIP/lsw',
  @backup_job_name = N'LSBackup_lsw', @backup_retention_period = 4320, @backup_threshold = 60, @threshold_alert_enabled = 0,
  @history_retention_period = 5760, @backup_job_id = @j OUTPUT, @primary_id = @p OUTPUT, @overwrite = 1;
EXEC master.dbo.sp_add_log_shipping_primary_secondary @primary_database = N'lsw', @secondary_server = N'$SEC', @secondary_database = N'lsw', @overwrite = 1;" > "$OUT" 2>&1; then
  FOK=; echo "  msdb log shipping NOT PROVEN: the primary's procedures: $(tr '\n' ' ' < "$OUT" | cut -c1-300)"; fi
if [ -n "$FOK" ]; then
  sp "BACKUP DATABASE [lsw] TO DISK = '$SHIP/lsw_full.bak' WITH INIT, FORMAT;" >/dev/null
  ss "RESTORE DATABASE [lsw] FROM DISK = '$SHIP/lsw_full.bak' WITH NORECOVERY;" >/dev/null
  if ! ss "DECLARE @c uniqueidentifier, @r uniqueidentifier, @s uniqueidentifier;
EXEC master.dbo.sp_add_log_shipping_secondary_primary @primary_server = N'$PRI', @primary_database = N'lsw', @backup_source_directory = N'$SHIP/lsw',
  @backup_destination_directory = N'$SHIP/lswcopy', @copy_job_name = N'LSCopy_lsw', @restore_job_name = N'LSRestore_lsw', @file_retention_period = 4320,
  @overwrite = 1, @copy_job_id = @c OUTPUT, @restore_job_id = @r OUTPUT, @secondary_id = @s OUTPUT;
EXEC master.dbo.sp_add_log_shipping_secondary_database @secondary_database = N'lsw', @primary_server = N'$PRI', @primary_database = N'lsw',
  @restore_delay = 0, @restore_mode = 0, @disconnect_users = 0, @restore_threshold = 1, @threshold_alert_enabled = 0, @history_retention_period = 5760, @overwrite = 1;" > "$OUT" 2>&1; then
    FOK=; echo "  msdb log shipping NOT PROVEN: the secondary's procedures: $(tr '\n' ' ' < "$OUT" | cut -c1-300)"; fi
fi
if [ -n "$FOK" ]; then
  # each job started and waited on until its outcome row (step 0) is written: the next one needs its files
  jobruns() { $1 "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$2' AND h.step_id = 0"; }
  jobrun() { local n0; n0=$(jobruns "$1" "$2"); $1 "EXEC msdb.dbo.sp_start_job @job_name = N'$2';" >/dev/null
    for _ in $(seq 1 90); do [ "$(jobruns "$1" "$2")" -gt "$n0" ] && return 0; sleep 2; done; return 1; }
  jobrun sp LSBackup_lsw || fail "F: LSBackup_lsw did not end in 180 s"
  jobrun ss LSCopy_lsw || fail "F: LSCopy_lsw did not end in 180 s"
  jobrun ss LSRestore_lsw || fail "F: LSRestore_lsw did not end in 180 s"
  [ "$(ss "SELECT COUNT(*) FROM msdb.dbo.restorehistory WHERE destination_database_name = 'lsw' AND restore_type = 'L'")" -ge 1 ] \
    || fail "F: the restore job restored no log ($(ss "SELECT TOP (3) CONCAT(message, ' | ') FROM msdb.dbo.log_shipping_monitor_error_detail ORDER BY log_time DESC" | tr '\n' ' ' | cut -c1-300))"
fi
if [ -n "$FOK" ]; then
  ss "EXEC msdb.dbo.sp_update_job @job_name = N'LSRestore_lsw', @enabled = 0; EXEC msdb.dbo.sp_update_job @job_name = N'LSCopy_lsw', @enabled = 0;" >/dev/null
  sp "EXEC msdb.dbo.sp_update_job @job_name = N'LSBackup_lsw', @enabled = 0;" >/dev/null
  setthr logship_restore_age 0.5 60; setthr logship_restore_latency 60 120
  sleep 65; collect "$NS"
  [ "$(q "select count(*) from pgvigil.mssql_logshipping_state where instance_id = $IS and role = 'secondary' and database_name = 'lsw' and threshold_minutes = 1")" = 1 ] || fail "F: msdb's monitor row of lsw is not stored"
  [ "$(q "select kind from pgvigil.mssql_logrestore_state where instance_id = $IS and database_name = 'lsw'")" = restore ] || fail "F: lsw's restore-history row is not stored"
  [ "$(q "select count(*) from pgvigil.mssql_hadr_findings where instance_id = $IS and check_name = 'log shipping is behind its threshold' and object like 'secondary / lsw%'")" = 1 ] || fail "F: msdb's warning for lsw is missing"
  [ -z "$(finding 'log restores are behind' lsw)" ] || fail "F: a second warning for lsw: '$(finding 'log restores are behind' lsw)'"
  setthr logship_restore_age 0.5 1; collect "$NS"
  [ "$(finding 'log restores are behind' lsw)" = critical ] || fail "F: the critical tier for lsw: '$(finding 'log restores are behind' lsw)'"
  ok "F: msdb's own pair stored twice; msdb's warning alone, then the critical tier beside it"
fi

echo "--- G. a missing copy"
ss "DROP DATABASE [lsm];" >/dev/null
collect "$NS"
[ "$(q "select kind || '|' || coalesce(source_server, '') || '|' || coalesce(source_database, '') from pgvigil.mssql_logrestore_state where instance_id = $IS and database_name = 'lsm'")" = "pair|$PRI|lsm" ] || fail "G: lsm is not a pair row"
[ "$(finding 'a log shipping copy is missing' lsm)" = warning ] || fail "G: no 'a log shipping copy is missing' for lsm"
ok "G: lsm gone: a pair row and its warning"

echo "--- H. the primary is not read as a secondary"
collect "$NP"
IP=$(q "select instance_id from pgvigil.instances where name = '$NP'")   # the instance exists from its first read on
[ -n "$IP" ] || fail "H: the primary's read made no instance"
[ "$(q "select count(*) from pgvigil.mssql_logrestore_state where instance_id = $IP and kind = 'restore'")" = 0 ] || fail "H: the primary has restore rows"
ok "H: the primary stores no restore row"

MOK=1
if [ -n "$FOK" ]; then
  pfinding() { q "select string_agg(severity, ',' order by severity) from pgvigil.mssql_hadr_findings where instance_id = $IP and check_name = '$1' and object like '$2%'"; }
  detail() { q "select detail from pgvigil.mssql_hadr_findings where instance_id = $1 and check_name = '$2' and object like '$3%' limit 1"; }
  JD='a log shipping job is disabled'

  echo "--- I. log shipping's jobs"
  collect "$NS"; collect "$NP"
  echo "  stored jobs: $(q "select string_agg(role || ' ' || coalesce(nullif(database_name, ''), '-') || ' ' || job_role || ' ' || coalesce(job_name, '?') || ' exists ' || coalesce(job_exists::text, '-') || ' enabled ' || coalesce(job_enabled::text, '-') || ' schedules ' || coalesce(enabled_schedules::text, '-'), '; ' order by instance_id, role, job_role) from pgvigil.mssql_logship_config where instance_id in ($IS, $IP)")"
  for o in 'secondary / lsw / LSCopy_lsw' 'secondary / lsw / LSRestore_lsw'; do
    [ "$(finding "$JD" "$o")" = critical ] || fail "I: '$o' disabled: '$(finding "$JD" "$o")', want critical"
  done
  [ "$(pfinding "$JD" 'primary / lsw / LSBackup_lsw')" = critical ] || fail "I: the primary's backup job disabled: '$(pfinding "$JD" 'primary / lsw / LSBackup_lsw')', want critical"
  detail "$IS" "$JD" 'secondary / lsw / LSRestore_lsw' | grep -q 'is disabled' || fail "I: the detail does not say 'is disabled': $(detail "$IS" "$JD" 'secondary / lsw / LSRestore_lsw')"
  [ "$(ss "SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name = N'LSRestore_lsw'")" = 0 ] \
    || fail "I: LSRestore_lsw has a schedule (msdb's procedures were expected to make none)"
  ss "EXEC msdb.dbo.sp_update_job @job_name = N'LSRestore_lsw', @enabled = 1;" >/dev/null
  collect "$NS"
  [ "$(finding "$JD" 'secondary / lsw / LSRestore_lsw')" = critical ] || fail "I: enabled with no schedule: '$(finding "$JD" 'secondary / lsw / LSRestore_lsw')', want critical"
  detail "$IS" "$JD" 'secondary / lsw / LSRestore_lsw' | grep -q 'has no enabled schedule' || fail "I: the detail does not say 'has no enabled schedule': $(detail "$IS" "$JD" 'secondary / lsw / LSRestore_lsw')"
  addsched() {   # addsched <sp|ss> <job>: a schedule every minute attached, the job enabled
    $1 "EXEC msdb.dbo.sp_add_schedule @schedule_name = N'$2 every minute', @enabled = 1, @freq_type = 4, @freq_interval = 1, @freq_subday_type = 4, @freq_subday_interval = 1;
EXEC msdb.dbo.sp_attach_schedule @job_name = N'$2', @schedule_name = N'$2 every minute';
EXEC msdb.dbo.sp_update_job @job_name = N'$2', @enabled = 1;" >/dev/null
  }
  addsched sp LSBackup_lsw; addsched ss LSCopy_lsw; addsched ss LSRestore_lsw
  collect "$NS"; collect "$NP"
  [ -z "$(finding "$JD" 'secondary / lsw /')" ] || fail "I: scheduled and enabled, still: '$(finding "$JD" 'secondary / lsw /')'"
  [ -z "$(pfinding "$JD" 'primary / lsw /')" ] || fail "I: the primary's job scheduled and enabled, still: '$(pfinding "$JD" 'primary / lsw /')'"
  iv=$(q "select string_agg(job_role || ' ' || interval_min::float8, ',' order by job_role) from pgvigil.mssql_logship_config where instance_id in ($IS, $IP) and database_name = 'lsw'")
  [ "$iv" = "backup 1,copy 1,restore 1" ] || fail "I: the stored intervals: $iv"
  PGVIGIL_MSSQL_TEST_DSN="$MSSQL_PRI_DSN" go test -count=1 -run 'TestHADRS3StatementsLive' ./internal/mssql/ > "$OUT" 2>&1 || { cat "$OUT"; fail "I: TestHADRS3StatementsLive against the primary"; }
  ok "I: the three jobs disabled = critical; enabled with no schedule = critical; scheduled every minute = none (intervals $iv); the statements live against $PRI"

  echo "--- J. msdb's own alert"
  AO='the log shipping alert is off'; T3='a log shipping alert threshold is under three times its job interval'
  [ "$(finding "$AO" 'secondary / lsw')" = info ] || fail "J: the secondary's alert off: '$(finding "$AO" 'secondary / lsw')', want info"
  [ "$(pfinding "$AO" 'primary / lsw')" = info ] || fail "J: the primary's alert off: '$(pfinding "$AO" 'primary / lsw')', want info"
  [ "$(finding "$T3" 'secondary / lsw')" = info ] || fail "J: the restore threshold 1 minute with a job every minute: '$(finding "$T3" 'secondary / lsw')', want info"
  d=$(detail "$IS" "$T3" 'secondary / lsw')
  grep -q 'every 1 minute' <<<"$d" && grep -q 'at least three times the frequency of the restore job' <<<"$d" || fail "J: the detail: $d"
  [ -z "$(pfinding "$T3" 'primary / lsw')" ] || fail "J: the primary's threshold 60 with a job every minute judged: '$(pfinding "$T3" 'primary / lsw')'"
  ss "EXEC master.dbo.sp_change_log_shipping_secondary_database @secondary_database = N'lsw', @threshold_alert_enabled = 1, @restore_threshold = 45;" >/dev/null
  collect "$NS"
  [ -z "$(finding "$AO" 'secondary / lsw')" ] || fail "J: the alert on, still: '$(finding "$AO" 'secondary / lsw')'"
  [ -z "$(finding "$T3" 'secondary / lsw')" ] || fail "J: the threshold 45, still: '$(finding "$T3" 'secondary / lsw')'"
  ok "J: the alert off = info on both; a threshold under three intervals = info with Microsoft's words; both gone once changed"

  echo "--- K. a log backup outside log shipping"
  CH='a log backup outside log shipping broke the chain'
  docker exec -u 0 "$PRI" mkdir -p "$SHIP/other"; docker exec -u 0 "$PRI" chown 10001:0 "$SHIP/other"
  sp "BACKUP LOG [lsw] TO DISK = '$SHIP/other/lsw_copyonly.trn' WITH COPY_ONLY, INIT, FORMAT;" >/dev/null
  collect "$NP"
  [ "$(sp "SELECT COUNT(*) FROM msdb.dbo.backupset WHERE database_name = N'lsw' AND type = 'L' AND is_copy_only = 0")" -ge 1 ] || fail "K: log shipping has no log backup of its own yet"
  [ "$(q "select count(*) from pgvigil.mssql_logship_foreign_logs where instance_id = $IP")" = 0 ] \
    || fail "K: stored as foreign with only a copy-only backup and log shipping's own: $(q "select string_agg(file_name, ', ') from pgvigil.mssql_logship_foreign_logs where instance_id = $IP")"
  [ -z "$(pfinding "$CH" 'primary / lsw')" ] || fail "K: a finding with only a copy-only backup: '$(pfinding "$CH" 'primary / lsw')'"
  sp "BACKUP LOG [lsw] TO DISK = '$SHIP/other/lsw_foreign1.trn' WITH INIT, FORMAT;" >/dev/null
  collect "$NP"
  [ "$(pfinding "$CH" 'primary / lsw')" = critical ] || fail "K: after a plain log backup elsewhere: '$(pfinding "$CH" 'primary / lsw')', want critical"
  d=$(detail "$IP" "$CH" 'primary / lsw')
  for want in "$SHIP/other/lsw_foreign1.trn" '1 log backup that is' "folder $SHIP/lsw " 'is not known'; do
    grep -qF -- "$want" <<<"$d" || fail "K: the detail lacks '$want': $d"
  done
  sleep 2; sp "BACKUP LOG [lsw] TO DISK = '$SHIP/other/lsw_foreign2.trn' WITH INIT, FORMAT;" >/dev/null
  collect "$NP"
  d=$(detail "$IP" "$CH" 'primary / lsw')
  for want in "$SHIP/other/lsw_foreign2.trn" '2 log backups that are'; do
    grep -qF -- "$want" <<<"$d" || fail "K: the detail lacks '$want': $d"
  done
  [ "$(pfinding "$CH" 'primary / lsw')" = critical ] || fail "K: two files: '$(pfinding "$CH" 'primary / lsw')', want ONE critical"
  ok "K: copy-only and log shipping's own = none; a plain log backup elsewhere = critical naming it; two = one finding, the newest named"

  echo "--- L. the primary's recovery model"
  RB='a log-shipped database is in BULK_LOGGED recovery'; RS='a log-shipped database is in SIMPLE recovery'
  sp "ALTER DATABASE [lsw] SET RECOVERY BULK_LOGGED;" >/dev/null; collect "$NP"
  [ "$(pfinding "$RB" 'primary / lsw')" = warning ] && [ -z "$(pfinding "$RS" 'primary / lsw')" ] || fail "L: BULK_LOGGED: '$(pfinding "$RB" 'primary / lsw')' / '$(pfinding "$RS" 'primary / lsw')', want warning / none"
  sp "ALTER DATABASE [lsw] SET RECOVERY SIMPLE;" >/dev/null; collect "$NP"
  [ "$(pfinding "$RS" 'primary / lsw')" = critical ] && [ -z "$(pfinding "$RB" 'primary / lsw')" ] || fail "L: SIMPLE: '$(pfinding "$RS" 'primary / lsw')' / '$(pfinding "$RB" 'primary / lsw')', want critical / none"
  detail "$IP" "$RS" 'primary / lsw' | grep -q 'switching the database to simple recovery will cause log shipping to stop functioning' || fail "L: the detail lacks Microsoft's sentence"
  sp "ALTER DATABASE [lsw] SET RECOVERY FULL;" >/dev/null; collect "$NP"
  [ -z "$(pfinding "$RS" 'primary / lsw')" ] && [ -z "$(pfinding "$RB" 'primary / lsw')" ] || fail "L: FULL again: '$(pfinding "$RS" 'primary / lsw')' / '$(pfinding "$RB" 'primary / lsw')', want none"
  ok "L: BULK_LOGGED = warning, SIMPLE = critical with Microsoft's sentence, FULL = none"

  echo "--- M. a log shipping job deleted"
  CID=$(ss "SELECT CAST(copy_job_id AS varchar(36)) FROM msdb.dbo.log_shipping_secondary WHERE primary_database = N'lsw'")
  if ! ss "EXEC msdb.dbo.sp_delete_job @job_name = N'LSCopy_lsw';" > "$OUT" 2>&1; then
    MOK=; echo "  M NOT PROVEN: SQL Server refused the delete: $(tr '\n' ' ' < "$OUT" | cut -c1-300)"
  else
    collect "$NS"
    [ "$(finding 'a log shipping job is missing' "secondary / lsw / copy job $CID")" = critical ] \
      || fail "M: the copy job $CID deleted: '$(finding 'a log shipping job is missing' 'secondary / lsw')', want critical ($(q "select string_agg(check_name || ' | ' || object, '; ') from pgvigil.mssql_hadr_findings where instance_id = $IS and check_name like 'a log shipping job%'"))"
    ok "M: the copy job deleted = 'a log shipping job is missing' critical naming its id $CID"
  fi
fi
PROVEN="A-D, G, H"
if [ -n "$FOK" ]; then PROVEN="$PROVEN, F, I-L"; [ -n "$MOK" ] && PROVEN="$PROVEN, M" || PROVEN="$PROVEN; M NOT PROVEN"; else PROVEN="$PROVEN; F and I-M NOT PROVEN"; fi
echo "PROOF OK ($PROVEN)"
