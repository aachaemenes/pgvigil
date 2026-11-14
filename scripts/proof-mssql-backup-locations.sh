#!/usr/bin/env bash
# Proof of task 301: where a SQL Server database's newest backups went (migration 0140, internal/mssql/backups.go's
# collection mssql_backup_files, /api/mssql/backup_files, the Backups tab's added cells through the lead's wiring).
#
# Needs: docker (it starts and removes its own containers: SQL Server 2022 and 2019 Developer, a MinIO S3 stand-in with
# its own TLS certificate, a PowerShell container for dbatools; a network and two volumes of its own), openssl, psql,
# curl, python3, a go toolchain at the repository root, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...);
#                      the proof makes its own database there and drops it.
# Optional: PGVIGIL_BIN (default bin/pgvigil, built here when missing), PROOF_SKIP_S3=1, PROOF_SKIP_DBATOOLS=1,
# PROOF_SKIP_2019=1 (each such row then prints NOT PROVEN). Part H needs the lead's wiring in the binary (web.go's route,
# sqlMSSQLBackups' join): on a tree that does not carry it yet, scripts/inv-301-wiring.patch is applied to the tree the
# binary is built from (patch -p1) before the run.
# Nothing it did not make is touched; every container, volume, network and the repository database go on every exit path.
#
# Expected (written before the first run):
#  L1  a full striped over 4 files (CHECKSUM, COMPRESSION, NAME, DESCRIPTION) of pgvbka: 4 file rows, family 1-4, mirror
#      0, each path equal to msdb's; the set's user_name sa, set name and description as given, checksum true,
#      compressed (compressed_bytes < size), key_algorithm NO_Encryption, copy-only false; folder /backups/a/, family_count 4.
#  L2  a mirrored full (2 families MIRROR TO 2 more, FORMAT): 4 file rows (families 1-2 x mirrors 0-1), mirror_count 2,
#      roots {/backups/m, /backups2/m}; the 'to' cell '/backups/m/, 2 files, mirrored'.
#  L6  an encrypted full (a certificate in master, AES_256): key_algorithm aes_256, encryptor_type CERTIFICATE.
#  L7  (F4) a copy-only full, then a differential: two full rows - the copy-only one shown, not judged; the encrypted
#      one judged, not shown; the differential's base 'the last full that is not copy-only'; printed: whether
#      differential_base_guid equals the base's backup_set_uuid and database_backup_lsn its checkpoint_lsn (both expected).
#  L5  a log to a path of 250 characters or more: stored whole, its length equal to msdb's LEN(physical_device_name).
#  L4  a log to NUL after it: the newest log stays the long path; no NUL path stored.
#  L3  a full of pgvbku whose media family row is hand-set to device_type 9 and an Azure URL: device kind url, root
#      https://pgvbkacct.blob.core.windows.net/pgvbk, the path whole. 'not proven: a real BACKUP TO URL to Azure - the lab
#      token never leaves the laptop'.
#  L3b (F8) one BACKUP TO URL 's3://...' against the MinIO stand-in with its own TLS: device kind url (by the scheme),
#      root s3://pgvbk-s3:9000/pgvbk, msdb's device_type printed; refused after one honest trial = 'NOT PROVEN: a real
#      URL row' with the server's message, the rest goes on.
#  L8  (F5) pgvbkw's logs: sa twice and a login with db_backupoperator once into /backups/w/ - one destination, users
#      {pgvbk_op, sa}, the panel's note, no finding; one more by the operator into /backups2/w/ and a full after it:
#      'log backups to two destinations' (warning) naming both; a copy-only log by sa into /backups2/c/ counts nowhere.
#      pgvbkw3 (its full gone from msdb by sp_delete_backuphistory, its two logs kept): one destination, 2 sets.
#  L9  (F3) pgvbkv: a full in its own data directory -> same_volume 'yes: ... is in /var/opt/mssql/data/, the directory
#      of ...' and 'a full backup on the volume of the database's own files'; then a full into /var/opt/mssql/pgvbk_sib/
#      (a sibling directory on the same filesystem) and one on another docker volume: each 'not judged: on Linux only ...',
#      no finding. The Windows mounted-folder and Cluster Shared Volume rows: TestBackupLocationsOnAStore.
#  L10 (F11) pgvbkr: fulls to /backups, then /backups2, then /backups again: roots seen 2; 'a backup destination not
#      seen before' (info) after the second; still 2 roots after the third.
#  L16 (F2) pgvbkd: a full now and a differential whose dates are hand-set 30 days back (another database's, before this
#      one was created): only the full stored. pgvbkg: backed up, then dropped: no row of it.
#  L18 (F14) pgvbkt: two logs a few seconds apart, the first hand-set to time_zone -8 (2 h behind UTC: the later by UTC):
#      the stored log is the first.
#  L11 (F15) dbatools 2.9.1 Get-DbaDbBackupHistory -IncludeCopyOnly with -LastFull, -LastDiff, -LastLog for pgvbka,
#      pgvbkw, pgvbkr, pgvbkv: the same backup_set_id and paths as pgvigil's shown rows, but for the differences seeded
#      on purpose, each a row: (a) pgvbka's log - dbatools takes the NUL log, pgvigil the real one before it; (b) pgvbkw's
#      log - a set whose server_name is hand-set to another server: dbatools takes it, pgvigil does not; (c) pgvbkr's full
#      - a partial backup (READ_WRITE_FILEGROUPS): dbatools' -LastFull takes it (type P), pgvigil the full before it.
#  L17 (F7) 60 logs of pgvbkf, a read, one log of pgvbka, a read: exactly two sets re-stored by the second read (pgvbkf's
#      and pgvbka's log rows; every other set keeps the first read's snapshot); the cursor = msdb's newest backup_set_id
#      with its mark. msdb replaced: its history deleted and backupset's identity reseeded, a full of pgvbkr taken (a
#      backup_set_id below the cursor): the next read stores it.
#  L12 the least-privilege login (a user in msdb with db_datareader, no server right) reads the same sets as the monitor
#      login; a login without a user in msdb: 'skipped', naming msdb.dbo.backupset and the missing right.
#  L15 (F9) SQL Server 2019: one read with no error, compression_algorithm and last_valid_restore_at NULL.
#  L20 msdb's indexes on backupset and backupmediafamily printed (sp_helpindex), the writers' backup_finish_date among them.
#  H   the API: /api/mssql/backup_files?instance= answers sets, files (every path of every set), writers, roots,
#      findings, read; &db=pgvbka its rows alone; no instance: by_instance with pgvbk's texts; /api/mssql/backups carries
#      full_to / log_to and the flags for pgvbka.
#  NOT PROVEN HERE: a Windows path, a share, a mounted folder or Cluster Shared Volume on a live server (the containers are
#  Linux; the store test holds the rules); a real Azure URL row; a virtual-device row of a third-party tool; a live
#  availability group (the group merge: TestBackupLocationsOnAStore's stubbed rows); Amazon RDS; Managed Instance.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of a PostgreSQL sandbox}"
SUF=$RANDOM
NET=pgvbk-net-$SUF; SQL=pgvbk-22-$SUF; SQL19=pgvbk-19-$SUF; S3=pgvbk-s3-$SUF; PS=pgvbk-ps-$SUF
VB1=pgvbk-b1-$SUF; VB2=pgvbk-b2-$SUF
IMG22=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}; IMG19=${PGVIGIL_MSSQL_IMAGE19:-mcr.microsoft.com/mssql/server:2019-latest}
REPO_DB=pgvigil_bkproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; LOG=$WORK/serve.log
pw() { printf 'Pv9%s!a' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); PM=$(pw); PL=$(pw); PB=$(pw); PO=$(pw); S3PW=$(pw)
export SAPW SQLCMDPASSWORD="$SAPW"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
MADE_NET=; MADE_VOL=; MADE_DB=; SRVPID=
cleanup() {
  rc=$?
  set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  docker rm -f -v "$SQL" "$SQL19" "$S3" "$PS" >/dev/null 2>&1
  [ -n "$MADE_VOL" ] && docker volume rm "$VB1" "$VB2" >/dev/null 2>&1
  [ -n "$MADE_NET" ] && docker network rm "$NET" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_REPO_DSN" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$WORK"
  echo "left: containers $(docker ps -aq --filter "name=pgvbk-.*-$SUF" | wc -l), volumes $(docker volume ls -q --filter "name=pgvbk-b.-$SUF" | wc -l)"
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

echo "== containers"
docker network create "$NET" >/dev/null; MADE_NET=1
docker volume create "$VB1" >/dev/null; docker volume create "$VB2" >/dev/null; MADE_VOL=1
ENVF=$WORK/sql.env; printf 'ACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_SA_PASSWORD=%s\n' "$SAPW" > "$ENVF"; chmod 600 "$ENVF"
docker run -d --name "$SQL" --label pgvigil-proof=inv301 --network "$NET" --network-alias sql22 --env-file "$ENVF" -v "$VB1:/backups" -v "$VB2:/backups2" -p 127.0.0.1::1433 "$IMG22" >/dev/null
[ -n "${PROOF_SKIP_2019:-}" ] || docker run -d --name "$SQL19" --label pgvigil-proof=inv301 --env-file "$ENVF" -p 127.0.0.1::1433 "$IMG19" >/dev/null
up "$SQL" || fail "SQL Server 2022 did not come up: $(docker logs --tail 20 "$SQL" 2>&1)"
docker exec -u root "$SQL" bash -c 'chown -R mssql /backups /backups2 && mkdir -p /var/opt/mssql/pgvbk_sib && chown mssql /var/opt/mssql/pgvbk_sib'
P22=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
echo "  SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) + ' ' + CAST(SERVERPROPERTY('Edition') AS varchar(60))") on 127.0.0.1:$P22"

# the MinIO stand-in with its own TLS certificate, trusted by the 2022 container (F8)
S3OK=
if [ -z "${PROOF_SKIP_S3:-}" ]; then
  mkdir -p "$WORK/certs"
  if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/certs/private.key" -out "$WORK/certs/public.crt" -days 2 -subj "/CN=pgvbk-s3" \
       -addext "subjectAltName=DNS:pgvbk-s3" >/dev/null 2>&1 && chmod 644 "$WORK/certs/private.key" \
     && docker run -d --name "$S3" --label pgvigil-proof=inv301 --network "$NET" --network-alias pgvbk-s3 -e MINIO_ROOT_USER=pgvbk -e MINIO_ROOT_PASSWORD="$S3PW" \
          -v "$WORK/certs:/root/.minio/certs:ro" minio/minio:latest server /data >/dev/null \
     && docker cp "$WORK/certs/public.crt" "$SQL:/tmp/pgvbk-s3.crt" \
     && docker exec -u root "$SQL" bash -c 'cp /tmp/pgvbk-s3.crt /usr/local/share/ca-certificates/pgvbk-s3.crt && update-ca-certificates >/dev/null' \
     && docker restart "$SQL" >/dev/null && up "$SQL"; then
    sleep 3
    if docker run --rm --network "$NET" -e MC_HOST_s3="https://pgvbk:$S3PW@pgvbk-s3:9000" minio/mc:latest --insecure mb s3/pgvbk >/dev/null 2>&1; then S3OK=1; fi
  fi
  [ -n "$S3OK" ] || echo "  the S3 stand-in did not stand up: L3b will say NOT PROVEN"
fi
up "$SQL" || fail "SQL Server 2022 is down after its restart"
P22=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')

echo "== logins and databases"
sqin "$SQL" >/dev/null <<SQL
CREATE LOGIN pgvbk_mon WITH PASSWORD = N'$PM', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO pgvbk_mon; GRANT VIEW ANY DEFINITION TO pgvbk_mon;
CREATE LOGIN pgvbk_least WITH PASSWORD = N'$PL', CHECK_POLICY = OFF;
CREATE LOGIN pgvbk_bare WITH PASSWORD = N'$PB', CHECK_POLICY = OFF;
CREATE LOGIN pgvbk_op WITH PASSWORD = N'$PO', CHECK_POLICY = OFF;
SQL
sq "CREATE USER pgvbk_mon FOR LOGIN pgvbk_mon; ALTER ROLE db_datareader ADD MEMBER pgvbk_mon; CREATE USER pgvbk_least FOR LOGIN pgvbk_least; ALTER ROLE db_datareader ADD MEMBER pgvbk_least;" msdb >/dev/null
for d in pgvbka pgvbkw pgvbkw3 pgvbkv pgvbkr pgvbku pgvbkd pgvbkg pgvbkf pgvbkt; do sq "CREATE DATABASE [$d]; ALTER DATABASE [$d] SET RECOVERY FULL;" >/dev/null; done
sq "CREATE USER pgvbk_op FOR LOGIN pgvbk_op; ALTER ROLE db_backupoperator ADD MEMBER pgvbk_op;" pgvbkw >/dev/null
sq "CREATE TABLE dbo.t (i int IDENTITY PRIMARY KEY, v char(800)); INSERT dbo.t (v) SELECT TOP (2000) 'x' FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvbka >/dev/null
docker exec "$SQL" mkdir -p /backups/a /backups/m /backups2/m /backups/w /backups2/w /backups2/c /backups/v /backups/u /backups/w3 /backups/f /backups/t /backups/d /backups/g

# pgvbkw3: its full leaves msdb (a trimmed history), its logs stay (F5's 'no full in msdb')
sq "BACKUP DATABASE pgvbkw3 TO DISK = N'/backups/w3/full.bak' WITH FORMAT;" >/dev/null; sleep 2
T0=$(sq "SELECT CONVERT(varchar(23), GETDATE(), 126)"); sleep 1
sq "BACKUP LOG pgvbkw3 TO DISK = N'/backups/w3/l1.trn' WITH FORMAT; BACKUP LOG pgvbkw3 TO DISK = N'/backups/w3/l2.trn' WITH FORMAT;" >/dev/null
sq "EXEC msdb.dbo.sp_delete_backuphistory @oldest_date = '$T0';" >/dev/null

repo() {
  psql "$PGVIGIL_REPO_DSN" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
  export PGVIGIL_REPO_DSN_PROOF="$RDSN"
  export MSSQL_M_DSN="sqlserver://pgvbk_mon:$PM@127.0.0.1:$P22?database=master&encrypt=true&TrustServerCertificate=true"
  export MSSQL_L_DSN="sqlserver://pgvbk_least:$PL@127.0.0.1:$P22?database=master&encrypt=true&TrustServerCertificate=true"
  export MSSQL_B_DSN="sqlserver://pgvbk_bare:$PB@127.0.0.1:$P22?database=master&encrypt=true&TrustServerCertificate=true"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN_PROOF
instances:
  - name: pgvbk-m
    engine: sqlserver
    dsn: env:MSSQL_M_DSN
    mssql_thresholds:
      new_database_hours: 0
  - name: pgvbk-l
    engine: sqlserver
    dsn: env:MSSQL_L_DSN
  - name: pgvbk-b
    engine: sqlserver
    dsn: env:MSSQL_B_DSN
EOF
  if [ -z "${PROOF_SKIP_2019:-}" ]; then
    P19=$(docker port "$SQL19" 1433/tcp | head -1 | sed 's/.*://')
    up "$SQL19" || fail "SQL Server 2019 did not come up"
    sqin "$SQL19" >/dev/null <<SQL
CREATE LOGIN pgvbk_mon WITH PASSWORD = N'$PM', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvbk_mon; GRANT VIEW ANY DEFINITION TO pgvbk_mon;
SQL
    sqn "$SQL19" msdb "CREATE USER pgvbk_mon FOR LOGIN pgvbk_mon; ALTER ROLE db_datareader ADD MEMBER pgvbk_mon;" >/dev/null
    sqn "$SQL19" master "CREATE DATABASE pgvbk19; BACKUP DATABASE pgvbk19 TO DISK = N'/var/opt/mssql/data/pgvbk19.bak' WITH FORMAT, COMPRESSION;" >/dev/null
    export MSSQL_19_DSN="sqlserver://pgvbk_mon:$PM@127.0.0.1:$P19?database=master&encrypt=true&TrustServerCertificate=true"
    printf '  - name: pgvbk-19\n    engine: sqlserver\n    dsn: env:MSSQL_19_DSN\n' >> "$CFG"
  fi
  [ -x "$BIN" ] || go build -o "$BIN" ./cmd/pgvigil
  "$BIN" migrate -config "$CFG" >/dev/null
}
repo
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT"; return 1; }; }
read2() { collect mssql_backups pgvbk-m && collect mssql_backup_files pgvbk-m || fail "$1: the read failed: $(cat "$OUT")"; grep -q "skipped\|partial" "$OUT" && fail "$1: the read is skipped or partial: $(cat "$OUT")"; return 0; }
I=; iid() { [ -n "$I" ] || I=$(q "select instance_id from pgvigil.instances where name='pgvbk-m'"); echo "$I"; }
S() { q "select $1 from pgvigil.mssql_backup_sets where instance_id=$(iid) and database_name='$2' and backup_type='$3' and is_copy_only=${4:-false}"; }
L() { q "select $1 from pgvigil.mssql_backup_locations where instance_id=$(iid) and database_name='$2' and backup_type='$3' and is_copy_only=${4:-false}"; }
setid() { sq "SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'$1' AND type = '$2'"; }
# one statement as the backup operator login (its password by name from the environment)
asop() { SQLCMDPASSWORD="$PO" docker exec -e SQLCMDPASSWORD "$SQL" /opt/mssql-tools18/bin/sqlcmd -S localhost -U pgvbk_op -C -b -I -Q "$1" >/dev/null; }

echo "== L1 a full striped over four files"
sq "BACKUP DATABASE pgvbka TO DISK = N'/backups/a/a1_1.bak', DISK = N'/backups/a/a1_2.bak', DISK = N'/backups/a/a1_3.bak', DISK = N'/backups/a/a1_4.bak' WITH FORMAT, INIT, CHECKSUM, COMPRESSION, NAME = N'pgvbk stripe', DESCRIPTION = N'four stripes';" >/dev/null
read2 L1
ID=$(setid pgvbka D)
WANT=$(sq "SELECT STRING_AGG(CAST(f.family_sequence_number AS varchar(3)) + ':' + CAST(f.mirror AS varchar(3)) + ':' + f.physical_device_name, ',') WITHIN GROUP (ORDER BY f.family_sequence_number) FROM msdb.dbo.backupmediafamily f JOIN msdb.dbo.backupset b ON b.media_set_id = f.media_set_id WHERE b.backup_set_id = $ID")
GOT=$(q "select string_agg(family || ':' || mirror || ':' || path, ',' order by family) from pgvigil.mssql_backup_files where instance_id=$(iid) and database_name='pgvbka' and backup_type='full' and not is_copy_only")
[ "$GOT" = "$WANT" ] || fail "L1 files: $GOT, want $WANT"
G=$(S "backup_set_id || '|' || user_name || '|' || set_name || '|' || description || '|' || has_checksums || '|' || (compressed_bytes < size_bytes) || '|' || key_algorithm || '|' || folder || '|' || family_count" pgvbka full)
[ "$G" = "$ID|sa|pgvbk stripe|four stripes|true|true|NO_Encryption|/backups/a/|4" ] || fail "L1 set: $G"
ok "L1: 4 files equal to msdb ($GOT); $G"

echo "== L2 a mirrored full"
sq "BACKUP DATABASE pgvbka TO DISK = N'/backups/m/m1a.bak', DISK = N'/backups/m/m1b.bak' MIRROR TO DISK = N'/backups2/m/m2a.bak', DISK = N'/backups2/m/m2b.bak' WITH FORMAT;" >/dev/null
read2 L2
G=$(q "select count(*) || '|' || string_agg(distinct mirror::text, ',') from pgvigil.mssql_backup_files where instance_id=$(iid) and database_name='pgvbka' and backup_type='full' and not is_copy_only")
R=$(S "mirror_count || '|' || array_to_string(roots, ',')" pgvbka full)
TO=$(q "select full_to from pgvigil.mssql_backup_loc_db where instance_id=$(iid) and database_name='pgvbka'")
[ "$G|$R|$TO" = "4|0,1|2|/backups/m,/backups2/m|/backups/m/, 2 files, mirrored" ] || fail "L2: $G|$R|$TO"
ok "L2: $G files and mirrors; mirror_count and roots $R; to '$TO'"

echo "== L6 an encrypted full"
sqin "$SQL" >/dev/null <<SQL
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'$(pw)';
CREATE CERTIFICATE pgvbk_cert WITH SUBJECT = N'pgvbk proof';
SQL
sq "BACKUP DATABASE pgvbka TO DISK = N'/backups/a/enc.bak' WITH FORMAT, ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = pgvbk_cert);" >/dev/null 2>&1
read2 L6
G=$(S "key_algorithm || '|' || encryptor_type" pgvbka full)
[ "$G" = "aes_256|CERTIFICATE" ] || fail "L6: $G (msdb: $(sq "SELECT TOP 1 key_algorithm + '|' + encryptor_type FROM msdb.dbo.backupset WHERE database_name = N'pgvbka' ORDER BY backup_set_id DESC"))"
ok "L6: $G"

echo "== L7 a copy-only full, then a differential"
sq "BACKUP DATABASE pgvbka TO DISK = N'/backups/a/copy.bak' WITH FORMAT, COPY_ONLY; BACKUP DATABASE pgvbka TO DISK = N'/backups/a/diff.bak' WITH FORMAT, DIFFERENTIAL;" >/dev/null
read2 L7
G="$(L "shown || '/' || judged" pgvbka full true) $(L "shown || '/' || judged" pgvbka full false) $(L "diff_base" pgvbka diff)"
[ "$G" = "true/false false/true the last full that is not copy-only" ] || fail "L7: $G"
BASE=$(sq "SELECT CASE WHEN d.differential_base_guid = f.backup_set_uuid THEN 'guid' ELSE 'no-guid' END + '|' + CASE WHEN d.database_backup_lsn = f.checkpoint_lsn THEN 'lsn' ELSE 'no-lsn' END FROM msdb.dbo.backupset d JOIN msdb.dbo.backupset f ON f.backup_set_id = (SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvbka' AND type = 'D' AND is_copy_only = 0) WHERE d.backup_set_id = $(setid pgvbka I)")
ok "L7: copy-only shown, the encrypted full judged, the differential's base named; msdb: differential_base_guid = base uuid and database_backup_lsn = checkpoint_lsn: $BASE"

echo "== L5 a long path, L4 then NUL"
# 255 characters: msdb's physical_device_name is nvarchar(260)
LONGD=/backups/$(printf 'pgvbk_long_directory_%02d/' $(seq 1 9) | tr -d '\n'); docker exec "$SQL" mkdir -p "$LONGD"; LONGP="${LONGD}pgvbka_log_with_long_name1.trn"
sq "BACKUP LOG pgvbka TO DISK = N'$LONGP' WITH FORMAT;" >/dev/null
sq "BACKUP LOG pgvbka TO DISK = N'NUL';" >/dev/null
read2 L5
MS=$(sq "SELECT LEN(f.physical_device_name) FROM msdb.dbo.backupmediafamily f JOIN msdb.dbo.backupset b ON b.media_set_id = f.media_set_id WHERE b.backup_set_id = (SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvbka' AND type = 'L' AND backup_set_id < $(setid pgvbka L))")
G=$(q "select length(path) || '|' || path from pgvigil.mssql_backup_files where instance_id=$(iid) and database_name='pgvbka' and backup_type='log'")
[ "$G" = "${#LONGP}|$LONGP" ] && [ "$MS" = "${#LONGP}" ] && [ "${#LONGP}" -ge 250 ] || fail "L5/L4: $G (msdb $MS, the path ${#LONGP})"
[ "$(q "select count(*) from pgvigil.mssql_backup_files where instance_id=$(iid) and upper(path) in ('NUL','NUL:')")" = 0 ] || fail "L4: a NUL path stored"
ok "L5: a ${#LONGP}-character path stored whole (msdb's LEN $MS); L4: the NUL log after it stored nowhere"

echo "== L3 a hand-set Azure URL row; L3b a real BACKUP TO URL to the S3 stand-in"
sq "BACKUP DATABASE pgvbku TO DISK = N'/backups/u/u.bak' WITH FORMAT;" >/dev/null
sq "UPDATE f SET device_type = 9, physical_device_name = N'https://pgvbkacct.blob.core.windows.net/pgvbk/2026/u.bak' FROM msdb.dbo.backupmediafamily f JOIN msdb.dbo.backupset b ON b.media_set_id = f.media_set_id WHERE b.backup_set_id = $(setid pgvbku D);" msdb >/dev/null
read2 L3
G=$(q "select device_kind || '|' || root || '|' || path from pgvigil.mssql_backup_files where instance_id=$(iid) and database_name='pgvbku' and backup_type='full'")
[ "$G" = "url|https://pgvbkacct.blob.core.windows.net/pgvbk|https://pgvbkacct.blob.core.windows.net/pgvbk/2026/u.bak" ] || fail "L3: $G"
ok "L3: $G"; notproven "L3: a real BACKUP TO URL to Azure - the lab token never leaves the laptop"
if [ -n "$S3OK" ]; then
  sqin "$SQL" >/dev/null <<SQL
CREATE CREDENTIAL [s3://pgvbk-s3:9000/pgvbk] WITH IDENTITY = 'S3 Access Key', SECRET = 'pgvbk:$S3PW';
SQL
  if sq "BACKUP DATABASE pgvbku TO URL = N's3://pgvbk-s3:9000/pgvbk/2026-11-14/u_s3.bak' WITH FORMAT, COMPRESSION;" > "$OUT" 2>&1; then
    read2 L3b
    G=$(q "select device_kind || '|' || root || '|' || path from pgvigil.mssql_backup_files where instance_id=$(iid) and database_name='pgvbku' and backup_type='full'")
    DT=$(sq "SELECT TOP 1 CAST(f.device_type AS varchar(5)) FROM msdb.dbo.backupmediafamily f JOIN msdb.dbo.backupset b ON b.media_set_id = f.media_set_id WHERE b.database_name = N'pgvbku' ORDER BY b.backup_set_id DESC")
    [ "$G" = "url|s3://pgvbk-s3:9000/pgvbk|s3://pgvbk-s3:9000/pgvbk/2026-11-14/u_s3.bak" ] || fail "L3b: $G (msdb device_type $DT)"
    ok "L3b: a real S3 row: $G; msdb's device_type $DT"
  else
    notproven "L3b: a real URL row - SQL Server refused the S3 stand-in: $(tr '\n' ' ' < "$OUT" | cut -c1-400)"
  fi
else notproven "L3b: a real URL row - the S3 stand-in did not stand up"; fi

echo "== L8 the log writers"
sq "BACKUP DATABASE pgvbkw TO DISK = N'/backups/w/full1.bak' WITH FORMAT; BACKUP LOG pgvbkw TO DISK = N'/backups/w/l1.trn' WITH FORMAT; BACKUP LOG pgvbkw TO DISK = N'/backups/w/l2.trn' WITH FORMAT;" >/dev/null
asop "BACKUP LOG pgvbkw TO DISK = N'/backups/w/l3.trn' WITH FORMAT;"
read2 L8a
G=$(q "select device_kind || '|' || root || '|' || array_to_string(users, ',') || '|' || sets from pgvigil.mssql_backup_writers where instance_id=$(iid) and database_name='pgvbkw'")
[ "$G" = "disk|/backups/w|pgvbk_op,sa|3" ] || fail "L8 one destination: $G"
[ "$(q "select count(*) from pgvigil.mssql_backup_loc_findings where instance_id=$(iid) and object='pgvbkw'")" = 0 ] || fail "L8: a finding for two logins to one destination"
asop "BACKUP LOG pgvbkw TO DISK = N'/backups2/w/l4.trn' WITH FORMAT;"
sq "BACKUP LOG pgvbkw TO DISK = N'/backups2/c/copy.trn' WITH FORMAT, COPY_ONLY; BACKUP DATABASE pgvbkw TO DISK = N'/backups/w/full2.bak' WITH FORMAT;" >/dev/null
read2 L8b
G=$(q "select string_agg(root || ':' || sets, ',' order by root) from pgvigil.mssql_backup_writers where instance_id=$(iid) and database_name='pgvbkw'")
F=$(q "select severity || '|' || check_name from pgvigil.mssql_backup_loc_findings where instance_id=$(iid) and object='pgvbkw'")
D=$(q "select detail from pgvigil.mssql_backup_loc_findings where instance_id=$(iid) and object='pgvbkw'")
[ "$G" = "/backups/w:3,/backups2/w:1" ] && [ "$F" = "warning|log backups to two destinations" ] && [[ "$D" == *"/backups/w"*"/backups2/w"* || "$D" == *"/backups2/w"*"/backups/w"* ]] || fail "L8 two destinations: $G | $F | $D"
G3=$(q "select root || '|' || sets from pgvigil.mssql_backup_writers where instance_id=$(iid) and database_name='pgvbkw3'")
[ "$G3" = "/backups/w3|2" ] || fail "L8 no full in msdb: $G3"
ok "L8: one destination with two logins = no finding; then $G = '$F' (the copy-only log counted nowhere; the logs before the newest full counted); pgvbkw3 with no full in msdb: $G3"

echo "== L9 the database's own directory, a sibling directory, another volume"
sq "BACKUP DATABASE pgvbkv TO DISK = N'/var/opt/mssql/data/pgvbkv_full.bak' WITH FORMAT;" >/dev/null
read2 L9a
V=$(L same_volume pgvbkv full); F=$(q "select check_name from pgvigil.mssql_backup_loc_findings where instance_id=$(iid) and object='pgvbkv' and severity='warning'")
[[ "$V" == "yes: /var/opt/mssql/data/pgvbkv_full.bak is in /var/opt/mssql/data/, the directory of /var/opt/mssql/data/pgvbkv"* ]] && [ "$F" = "a full backup on the volume of the database's own files" ] || fail "L9 own directory: $V | $F"
ok "L9: $V -> '$F'"
for P in /var/opt/mssql/pgvbk_sib/pgvbkv.bak /backups/v/pgvbkv.bak; do
  sleep 1; sq "BACKUP DATABASE pgvbkv TO DISK = N'$P' WITH FORMAT;" >/dev/null; read2 "L9 $P"
  V=$(L same_volume pgvbkv full)
  [[ "$V" == "not judged: on Linux only a backup in the directory of the database's own files is judged"* ]] || fail "L9 $P: $V"
  [ "$(q "select count(*) from pgvigil.mssql_backup_loc_findings where instance_id=$(iid) and object='pgvbkv' and severity='warning'")" = 0 ] || fail "L9 $P: a warning"
  ok "L9: $P - not judged, no warning"
done

echo "== L10 the roots seen"
sq "BACKUP DATABASE pgvbkr TO DISK = N'/backups/r1.bak' WITH FORMAT;" >/dev/null; read2 L10a
sq "BACKUP DATABASE pgvbkr TO DISK = N'/backups2/r2.bak' WITH FORMAT;" >/dev/null; read2 L10b
F=$(q "select severity || '|' || check_name from pgvigil.mssql_backup_loc_findings where instance_id=$(iid) and object='pgvbkr'")
[ "$F" = "info|a backup destination not seen before" ] || fail "L10: $F"
sq "BACKUP DATABASE pgvbkr TO DISK = N'/backups/r3.bak' WITH FORMAT;" >/dev/null; read2 L10c
G=$(q "select string_agg(root, ',' order by root) from pgvigil.mssql_backup_roots_seen where instance_id=$(iid) and database_name='pgvbkr' and backup_type='full'")
[ "$G" = "/backups,/backups2" ] || fail "L10 roots after the flip back: $G"
ok "L10: '$F' after the move to /backups2; after the move back the roots stay $G"

echo "== L16 a differential of another database's time; a dropped database"
sq "BACKUP DATABASE pgvbkd TO DISK = N'/backups/d/full.bak' WITH FORMAT; BACKUP DATABASE pgvbkd TO DISK = N'/backups/d/diff.bak' WITH FORMAT, DIFFERENTIAL;" >/dev/null
sq "UPDATE msdb.dbo.backupset SET backup_start_date = DATEADD(day, -30, backup_start_date), backup_finish_date = DATEADD(day, -30, backup_finish_date) WHERE database_name = N'pgvbkd' AND type = 'I';" >/dev/null
sq "BACKUP DATABASE pgvbkg TO DISK = N'/backups/g/full.bak' WITH FORMAT; DROP DATABASE pgvbkg;" >/dev/null
read2 L16
G=$(q "select coalesce(string_agg(database_name || ':' || backup_type, ',' order by database_name, backup_type), '') from pgvigil.mssql_backup_sets where instance_id=$(iid) and database_name in ('pgvbkd','pgvbkg')")
[ "$G" = "pgvbkd:full" ] || fail "L16: $G"
ok "L16: $G (the differential dated before the database's creation and the dropped database stored nowhere)"

echo "== L18 the ranking by the UTC finish"
sq "BACKUP DATABASE pgvbkt TO DISK = N'/backups/t/full.bak' WITH FORMAT; BACKUP LOG pgvbkt TO DISK = N'/backups/t/t1.trn' WITH FORMAT;" >/dev/null; sleep 2
sq "BACKUP LOG pgvbkt TO DISK = N'/backups/t/t2.trn' WITH FORMAT;" >/dev/null
T1=$(sq "SELECT MIN(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvbkt' AND type = 'L'")
sq "UPDATE msdb.dbo.backupset SET time_zone = -8 WHERE backup_set_id = $T1;" >/dev/null
read2 L18
G=$(S "backup_set_id" pgvbkt log)
[ "$G" = "$T1" ] || fail "L18: the stored log is $G, want $T1 (the later by UTC)"
ok "L18: the log 2 h later by UTC wins over the later local time ($G)"

echo "== L11 dbatools 2.9.1"
if [ -z "${PROOF_SKIP_DBATOOLS:-}" ]; then
  # the three differences on purpose, seeded first: pgvbka's newest log is the NUL one (above); pgvbkw's newest log is
  # another server's; pgvbkr's newest full-type set is a partial backup
  sq "BACKUP LOG pgvbkw TO DISK = N'/backups/w/other.trn' WITH FORMAT;" >/dev/null
  sq "UPDATE msdb.dbo.backupset SET server_name = N'PGVBK-OTHER' WHERE backup_set_id = $(setid pgvbkw L);" >/dev/null
  sq "BACKUP DATABASE pgvbkr READ_WRITE_FILEGROUPS TO DISK = N'/backups/r_partial.bak' WITH FORMAT;" >/dev/null
  read2 L11
  docker run -d --name "$PS" --label pgvigil-proof=inv301 --network "$NET" mcr.microsoft.com/powershell:latest sleep 3600 >/dev/null
  docker exec -e SAPW "$PS" pwsh -NoProfile -Command '
    $ErrorActionPreference = "Stop"
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module dbatools -RequiredVersion 2.9.1 -Scope CurrentUser -Force -AcceptLicense | Out-Null
    Import-Module dbatools
    Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true | Out-Null
    $c = [pscredential]::new("sa", (ConvertTo-SecureString $env:SAPW -AsPlainText -Force))
    foreach ($db in "pgvbka", "pgvbkw", "pgvbkr", "pgvbkv") { foreach ($k in "LastFull", "LastDiff", "LastLog") {
      $p = @{ SqlInstance = "sql22"; SqlCredential = $c; Database = $db; IncludeCopyOnly = $true; $k = $true }
      foreach ($b in @(Get-DbaDbBackupHistory @p)) { "{0}|{1}|{2}|{3}" -f $db, $k, $b.BackupSetID, (@($b.Path) -join ";") } } }' > "$WORK/dbatools.txt" 2> "$WORK/dbatools.err" || true
  if [ -s "$WORK/dbatools.txt" ]; then
    q "select l.database_name || '|' || case l.backup_type when 'full' then 'LastFull' when 'diff' then 'LastDiff' else 'LastLog' end || '|' || l.backup_set_id || '|' ||
              (select string_agg(f.path, ';' order by f.family) from pgvigil.mssql_backup_files f where f.instance_id = l.from_instance_id and f.database_name = l.database_name
                  and f.backup_type = l.backup_type and f.is_copy_only = l.is_copy_only and f.mirror = 0)
         from pgvigil.mssql_backup_locations l where l.instance_id=$(iid) and l.shown and l.database_name in ('pgvbka','pgvbkw','pgvbkr','pgvbkv') order by 1" > "$WORK/pgvigil.txt"
    sort -o "$WORK/dbatools.txt" "$WORK/dbatools.txt"
    DIFF=$(diff "$WORK/pgvigil.txt" "$WORK/dbatools.txt" | grep '^[<>]' | sed 's/^</pgvigil:/; s/^>/dbatools:/' | sort -t'|' -k1,2 || true)
    echo "$DIFF" | sed 's/^/     /'
    NULL_ID=$(setid pgvbka L); OTHER_ID=$(setid pgvbkw L); PART_ID=$(sq "SELECT MAX(backup_set_id) FROM msdb.dbo.backupset WHERE database_name = N'pgvbkr' AND type = 'P'")
    # what may differ, and only that: one line each side for pgvbka's log, pgvbkw's log, pgvbkr's full
    KEYS=$(echo "$DIFF" | cut -d: -f2- | cut -d'|' -f1,2 | sort -u | tr '\n' ' ')
    [ "$KEYS" = "pgvbka|LastLog pgvbkr|LastFull pgvbkw|LastLog " ] || fail "L11: the rows that differ are $KEYS, want exactly pgvbka's log, pgvbkr's full and pgvbkw's log"
    echo "$DIFF" | grep -q "^dbatools:pgvbka|LastLog|$NULL_ID|NUL" || fail "L11 (a): dbatools' pgvbka log is not the NUL one ($NULL_ID)"
    echo "$DIFF" | grep -q "^dbatools:pgvbkw|LastLog|$OTHER_ID|" || fail "L11 (b): dbatools' pgvbkw log is not the other server's ($OTHER_ID)"
    echo "$DIFF" | grep -q "^dbatools:pgvbkr|LastFull|$PART_ID|" || fail "L11 (c): dbatools' pgvbkr full is not the partial backup ($PART_ID)"
    ok "L11: dbatools 2.9.1 and pgvigil agree on $(wc -l < "$WORK/pgvigil.txt") shown rows but for the three seeded on purpose: (a) the NUL log, (b) another server's row (no server_name filter), (c) a partial backup (-LastFull takes type P)"
  else notproven "L11: dbatools did not answer: $(tail -c 400 "$WORK/dbatools.err" | tr '\n' ' ')"; fi
else notproven "L11: PROOF_SKIP_DBATOOLS"; fi

echo "== L17 the cursor"
sq "BACKUP DATABASE pgvbkf TO DISK = N'/backups/f/full.bak' WITH FORMAT;" >/dev/null
for k in $(seq 1 60); do echo "BACKUP LOG pgvbkf TO DISK = N'/backups/f/l$k.trn' WITH FORMAT;"; done | sqin "$SQL" >/dev/null
read2 L17a
R1=$(q "select snapshot_at from pgvigil.mssql_hadr_reads where instance_id=$(iid) and collection='mssql_backup_files'")
C=$(q "select last_set_id || '|' || mark from pgvigil.mssql_backup_files_cursor where instance_id=$(iid)")
W=$(sq "SELECT TOP 1 CAST(backup_set_id AS varchar(12)) + '|' + CAST(CAST(CHECKSUM(backup_set_uuid) AS bigint) AS varchar(20)) FROM msdb.dbo.backupset ORDER BY backup_set_id DESC")
[ "$C" = "$W" ] || fail "L17 the cursor: $C, msdb's newest $W"
sleep 1; sq "BACKUP LOG pgvbka TO DISK = N'/backups/a/after.trn' WITH FORMAT;" >/dev/null
read2 L17b
R2=$(q "select snapshot_at from pgvigil.mssql_hadr_reads where instance_id=$(iid) and collection='mssql_backup_files'")
G=$(q "select string_agg(database_name || ':' || backup_type, ',' order by database_name) from pgvigil.mssql_backup_sets where instance_id=$(iid) and snapshot_at = '$R2'")
N1=$(q "select count(*) from pgvigil.mssql_backup_sets where instance_id=$(iid) and snapshot_at < '$R2'")
[ "$G" = "pgvbka:log,pgvbkf:log" ] || fail "L17: the second read re-stored $G, want pgvbka:log,pgvbkf:log"
ok "L17: the cursor $C = msdb's newest; the read after one more log re-stored $G alone ($N1 sets keep an earlier read's snapshot)"
sq "EXEC msdb.dbo.sp_delete_backuphistory @oldest_date = '9999-12-31'; DBCC CHECKIDENT ('msdb.dbo.backupset', RESEED, 0) WITH NO_INFOMSGS;" >/dev/null
sq "BACKUP DATABASE pgvbkr TO DISK = N'/backups/r4.bak' WITH FORMAT;" >/dev/null
NEWID=$(setid pgvbkr D); read2 L17c
G=$(S "backup_set_id || '|' || folder" pgvbkr full)
[ "$G" = "$NEWID|/backups/" ] && [ "$NEWID" -lt "${C%%|*}" ] || fail "L17 msdb replaced: stored $G, the new full is $NEWID (the old cursor ${C%%|*})"
ok "L17: msdb's history deleted and its numbering restarted: the full numbered $NEWID (below the cursor ${C%%|*}) is stored"

echo "== L12 the least-privilege login, a login without msdb"
collect mssql_backup_files pgvbk-l || fail "L12: the least-privilege read failed: $(cat "$OUT")"; grep -q skipped "$OUT" && fail "L12: the least-privilege read was skipped: $(cat "$OUT")"
IL=$(q "select instance_id from pgvigil.instances where name='pgvbk-l'")
G=$(q "select count(*) from pgvigil.mssql_backup_sets where instance_id=$IL"); GM=$(q "select count(*) from pgvigil.mssql_backup_sets where instance_id=$(iid) and snapshot_at > now() - interval '1 hour'")
[ "$G" -gt 0 ] || fail "L12: the least-privilege login stored no set"
collect mssql_backup_files pgvbk-b || true
grep -q "skipped" "$OUT" && grep -q "msdb.dbo.backupset" "$OUT" || fail "L12: the login without msdb: $(cat "$OUT")"
ok "L12: the least-privilege login stored $G sets (the monitor login $GM after msdb was emptied); without msdb: $(tr '\n' ' ' < "$OUT" | cut -c1-200)"

echo "== L15 SQL Server 2019"
if [ -z "${PROOF_SKIP_2019:-}" ]; then
  collect mssql_backup_files pgvbk-19 || fail "L15: the 2019 read failed: $(cat "$OUT")"
  I19=$(q "select instance_id from pgvigil.instances where name='pgvbk-19'")
  G=$(q "select backup_type || '|' || coalesce(compression_algorithm, 'NULL') || '|' || coalesce(last_valid_restore_at::text, 'NULL') || '|' || family_count from pgvigil.mssql_backup_sets where instance_id=$I19 and database_name='pgvbk19'")
  [ "$G" = "full|NULL|NULL|1" ] || fail "L15: $G"
  ok "L15: SQL Server $(sqn "$SQL19" master "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"): $G"
else notproven "L15: PROOF_SKIP_2019"; fi

echo "== L20 msdb's indexes"
for t in backupset backupmediafamily; do echo "  $t: $(sq "EXEC sp_helpindex 'dbo.$t'" msdb | cut -d'|' -f1,3 | tr '\n' ';')"; done

echo "== H the API"
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN_PROOF -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
api() { local code; code=$(curl -s -o "$WORK/body" -w '%{http_code}' "$U/api/$1"); [ "$code" = 200 ] || fail "H: /api/$1 answered $code: $(head -c 300 "$WORK/body")"; cat "$WORK/body"; }
api "mssql/backup_files?instance=$(iid)" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in ("sets", "files", "writers", "roots", "findings", "read"):
    assert p in d, ("no part", p)
rows = lambda p: [dict(zip(d[p]["columns"], r)) for r in d[p]["rows"]]
assert any(r["database_name"] == "pgvbka" and r["backup_type"] == "log" for r in rows("sets")), "no pgvbka log"
assert any(len(r["path"]) >= 250 for r in rows("files")), "the long path"
assert any(r["check_name"] == "log backups to two destinations" for r in rows("findings")), "the writers finding"
print("ok   H: /api/mssql/backup_files: %d sets, %d files, %d writers, %d roots, %d findings" % tuple(len(d[p]["rows"]) for p in ("sets", "files", "writers", "roots", "findings")))'
N=$(api "mssql/backup_files?instance=$(iid)&db=pgvbka" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len({r[d["sets"]["columns"].index("database_name")] for r in d["sets"]["rows"]}))')
[ "$N" = 1 ] || fail "H: &db=pgvbka answered $N databases"
api "mssql/backup_files" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["by_instance"]["rows"], "no by_instance row"; print("ok   H: no instance: %d instance row(s)" % len(d["by_instance"]["rows"]))'
api "mssql/backups?instance=$(iid)" | python3 -c '
import json, sys
d = json.load(sys.stdin); c = d["databases"]["columns"]
r = [dict(zip(c, x)) for x in d["databases"]["rows"] if x[c.index("database_name")] == "pgvbka"]
assert r and "full_to" in r[0], "the Detail rows lack full_to (the wiring)"
print("ok   H: /api/mssql/backups pgvbka: full to %s, log to %s, full checksum %s" % (r[0]["full_to"], r[0]["log_to"], r[0]["full_checksum"]))'
echo "ALL ROWS GREEN"
