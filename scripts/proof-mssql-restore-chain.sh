#!/usr/bin/env bash
# Proof of task 304: the restore chain (migration 0147, internal/mssql/restore_chain.go's collection mssql_restore_chain,
# /api/mssql/restore through the lead's wiring, scripts/inv-304-wiring.patch on top of inv-301-wiring.patch).
#
# Needs: docker (its own SQL Server 2022 Developer container, a PowerShell container for dbatools 2.9.1, and with
# PROOF_AG=1 rel-160's clusterless group lab scripts/dag/trial.sh), psql, curl, python3, a go toolchain, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form; the proof makes its own database there.
# Optional: PGVIGIL_BIN (default bin/pgvigil), PROOF_SKIP_DBATOOLS=1. Everything it makes goes on every exit path.
#
# Expected (written before the first run). Each chain is read from the store after one mssql_backups and one
# mssql_restore_chain read; 'equal to dbatools' = the same BackupSetID list, in order, as Get-DbaDbBackupHistory -Last
# (-IncludeCopyOnly where the start set is a copy-only full) against the same server:
#  R1  pgvrc1: a full and three logs -> steps full, log, log, log; verdict 'restorable from these backups to <the third log's
#      finish>'; equal to dbatools.
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
#  R5  pgvrc5: a full and three logs, the second log's msdb rows deleted by hand -> steps full, log 1; verdict 'broken
#      before the log of ...'; the finding 'the log chain is broken' (warning); dbatools -Last lists the full and logs 1
#      and 3 and names no gap.
#  R6  pgvrc6: a full, a log, a log to NUL, a log -> steps full, log 1; verdict 'went to NUL at ...'.
#  R7  pgvrc7: a full striped over 3 files and a log over 2 -> the files part lists 3 and 2 paths for the two steps.
#  R8  pgvrc8: a full and a log into one file (NOINIT) -> the log step's media_position 2, its mark 'file 2 of its media'.
#  R9  pgvrc9: a full and a copy-only log -> the copy-only log is no step (F7); dbatools' default drops it too.
#  R10 the API: /api/mssql/restore?instance=&db=pgvrc2 answers the steps with first_lsn and last_lsn as JSON strings of
#      up to 25 digits (F5), equal to msdb's; the databases part lists pgvrc5 'broken' first.
#  R13 (PROOF_AG=1) the group lab: a full on d1a, a log on d1b, a log on d1a -> from either instance one chain full, log,
#      log with 'ran on' d1a, d1b, d1a; without PROOF_AG or the lab refused: NOT PROVEN live.
#  NOT PROVEN HERE: a forced failover's new recovery fork on a live pair (the store test holds the fork rule), a snapshot
#  or virtual-device full, SQL Server 2025's secondary fulls, RDS, Managed Instance, a distributed group.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of a PostgreSQL sandbox}"
SUF=$RANDOM; NET=pgvrc-net-$SUF; SQL=pgvrc-22-$SUF; PS=pgvrc-ps-$SUF; REPO_DB=pgvigil_rcproof_$SUF
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
  docker rm -f -v "$SQL" "$PS" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
  [ -n "$AGTAG" ] && bash scripts/dag/trial.sh down "$AGTAG" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_REPO_DSN" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$WORK"; echo "left: containers $(docker ps -aq --filter "name=pgvrc-.*-$SUF" | wc -l)"; exit $rc
}
trap cleanup EXIT
sq() { docker exec -e SQLCMDPASSWORD "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
up() { for _ in $(seq 1 90); do [ "$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" 2>/dev/null | tr -d '\r ')" = 1 ] && return 0; sleep 2; done; return 1; }
RDSN=$(printf '%s' "$PGVIGIL_REPO_DSN" | sed -E "s/dbname=[^ ]+/dbname=$REPO_DB/"); [[ "$RDSN" == *"dbname=$REPO_DB"* ]] || RDSN="$PGVIGIL_REPO_DSN dbname=$REPO_DB"
q() { psql "$RDSN" -XAtqc "$1"; }

echo "== containers and the store"
docker network create "$NET" >/dev/null
printf 'ACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_SA_PASSWORD=%s\n' "$SAPW" > "$WORK/sql.env"; chmod 600 "$WORK/sql.env"
docker run -d --name "$SQL" --label pgvigil-proof=inv304 --network "$NET" --network-alias sql22 --env-file "$WORK/sql.env" -p 127.0.0.1::1433 mcr.microsoft.com/mssql/server:2022-latest >/dev/null
up || fail "SQL Server did not come up"
P22=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
printf "CREATE LOGIN pgvrc_mon WITH PASSWORD = N'%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvrc_mon; GRANT VIEW ANY DEFINITION TO pgvrc_mon;\n" "$PM" \
  | docker exec -i -e SQLCMDPASSWORD "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -d master -i /dev/stdin >/dev/null
sq "CREATE USER pgvrc_mon FOR LOGIN pgvrc_mon; ALTER ROLE db_datareader ADD MEMBER pgvrc_mon;" msdb >/dev/null
docker exec "$SQL" mkdir -p /var/opt/mssql/bk
for d in pgvrc1 pgvrc2 pgvrc2b pgvrc3 pgvrc5 pgvrc6 pgvrc7 pgvrc8 pgvrc9; do sq "CREATE DATABASE [$d]; ALTER DATABASE [$d] SET RECOVERY FULL;" >/dev/null; done
psql "$PGVIGIL_REPO_DSN" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
export PGVIGIL_REPO_DSN_PROOF="$RDSN" MSSQL_M_DSN="sqlserver://pgvrc_mon:$PM@127.0.0.1:$P22?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN_PROOF
instances:
  - name: pgvrc-m
    engine: sqlserver
    dsn: env:MSSQL_M_DSN
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
bk() { sq "BACKUP $1 TO DISK = N'/var/opt/mssql/bk/$2' WITH FORMAT${3:-};" >/dev/null; }
# one row written in a database: a log backup after it has something to apply
wr() { sq "IF OBJECT_ID(N'dbo.pgvrc_w') IS NULL CREATE TABLE dbo.pgvrc_w (i int IDENTITY PRIMARY KEY, at datetime2 DEFAULT SYSDATETIME()); INSERT dbo.pgvrc_w DEFAULT VALUES;" "$1" >/dev/null; }

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
read2 "the read"

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

echo "== dbatools 2.9.1"
if [ -z "${PROOF_SKIP_DBATOOLS:-}" ]; then
  docker run -d --name "$PS" --label pgvigil-proof=inv304 --network "$NET" mcr.microsoft.com/powershell:latest sleep 3600 >/dev/null
  docker exec -e SAPW "$PS" pwsh -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module dbatools -RequiredVersion 2.9.1 -Scope CurrentUser -Force -AcceptLicense | Out-Null
    Import-Module dbatools; Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true | Out-Null
    $c = [pscredential]::new("sa", (ConvertTo-SecureString $env:SAPW -AsPlainText -Force))
    foreach ($row in @(@("pgvrc1", $false), @("pgvrc2", $false), @("pgvrc2b", $false), @("pgvrc3", $true), @("pgvrc3", $false), @("pgvrc5", $false), @("pgvrc9", $false))) {
      $b = @(Get-DbaDbBackupHistory -SqlInstance sql22 -SqlCredential $c -Database $row[0] -Last -IncludeCopyOnly:$row[1])
      "{0}|{1}|{2}" -f $row[0], $row[1], (($b | Sort-Object { [decimal]$_.LastLsn }, Type | ForEach-Object { $_.BackupSetID }) -join ",") }' 2>"$WORK/dbatools.err" | tr -d '\r' > "$WORK/dbatools.txt" || true
  if [ -s "$WORK/dbatools.txt" ]; then
    cat "$WORK/dbatools.txt" | sed 's/^/     dbatools: /'
    dt() { grep "^$1|$2|" "$WORK/dbatools.txt" | cut -d'|' -f3; }
    for x in "pgvrc1 False" "pgvrc2 False" "pgvrc3 True"; do set -- $x; [ "$(dt $1 $2)" = "$(ids $1)" ] || fail "R1-R3 vs dbatools: $1 (IncludeCopyOnly $2) dbatools $(dt $1 $2), pgvigil $(ids $1)"; done
    [ "$(dt pgvrc3 False)" != "$(ids pgvrc3)" ] || fail "R3: dbatools' default should start at the normal full"
    if [ -n "$R2B" ]; then
      [ "$(dt pgvrc2b False)" = "$(ids pgvrc2b),$LID2B" ] || fail "R2b vs dbatools: dbatools $(dt pgvrc2b False), want pgvigil's $(ids pgvrc2b) and the log $LID2B"
      ok "R2b: dbatools 2.9.1 -Last lists $(dt pgvrc2b False): pgvigil's $(ids pgvrc2b) and the log $LID2B that applies nothing - a difference on purpose"
    else [ "$(dt pgvrc2b False)" = "$(ids pgvrc2b)" ] || fail "R2b vs dbatools: dbatools $(dt pgvrc2b False), pgvigil $(ids pgvrc2b)"; fi
    [ "$(dt pgvrc9 False)" = "$(ids pgvrc9)" ] || fail "R9 vs dbatools: dbatools $(dt pgvrc9 False), pgvigil $(ids pgvrc9)"
    D5=$(dt pgvrc5 False); [ "$(echo "$D5" | tr ',' '\n' | wc -l)" = 3 ] || fail "R5: dbatools listed $D5 (want the full and logs 1 and 3, no gap named)"
    ok "R1, R2, R3 (-IncludeCopyOnly), R9 equal to dbatools 2.9.1; R3 differs from its default on purpose; R5: dbatools lists $D5 and names no gap"
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
  else notproven "R13: a live group - the lab did not form: $(grep -E 'FAIL|REFUSED' "$WORK/ag.log" | head -2 | tr '\n' ' ' | cut -c1-300)"; fi
else notproven "R13: a live availability group (PROOF_AG unset): TestRestoreChainOnAStore's stubbed rows hold the merge"; fi
echo "ALL ROWS GREEN"
