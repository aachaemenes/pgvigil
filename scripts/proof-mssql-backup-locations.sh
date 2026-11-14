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
#      compressed (compressed_bytes < size), key_algorithm as msdb holds it and not encrypted, copy-only false; folder
#      /backups/a/, family_count 4. (Changed after run 1: msdb held NULL, not Learn's 'NO_Encryption', for a backup that is
#      not encrypted on SQL Server 2022 16.0.4325.)
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
#  I   (L14) the pages in a headless Chromium with the binary's own bundle: #/mssqlbackups?i=<instance>&db=pgvbka draws the
#      Databases grid with full damaged .. log compression algorithm and full / differential / log to; the Last backup
#      panel's header = DBA Dash's 26 Last Backup columns in its order, then pgvigil's own; its Files grid one row per
#      stripe and mirror of pgvbka's kept sets, each path cell's data-full equal to its path and a Copy button in it; the
#      Backup files grid every file of the instance; #/backups the SQL Server section; axe-core 4.14.0 (WCAG 2.1 A and AA)
#      0 violation nodes on both pages in the light and the dark theme. Skipped (NOT PROVEN) without chromium and node.
#  J   (F10, only with PROOF_AG=1) rel-160's lab (scripts/dag/trial.sh, KEEP=1) forms a clusterless group ag1 (d1a primary,
#      d1b secondary, database dagdb): a full on d1a and a log on d1b, both instances read: from d1a the locations show
#      the full from d1a and the log from d1b, the log 'is partner backup' with d1b as its partner; from d1b the same
#      two sets; replicas_unseen false. Without PROOF_AG=1, or the lab refused: 'NOT PROVEN live: an availability group'.
#  NOT PROVEN HERE: a Windows path, a share, a mounted folder or Cluster Shared Volume on a live server (the containers are
#  Linux; the store test holds the rules); a real Azure URL row; a virtual-device row of a third-party tool; a live
#  availability group unless part J ran (the group merge: TestBackupLocationsOnAStore's stubbed rows); Amazon RDS; Managed Instance.
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
MADE_NET=; MADE_VOL=; MADE_DB=; SRVPID=; CHR=; AGTAG=
cleanup() {
  rc=$?
  set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  [ -n "$CHR" ] && kill "$CHR" 2>/dev/null
  docker rm -f -v "$SQL" "$SQL19" "$S3" "$PS" >/dev/null 2>&1
  [ -n "$AGTAG" ] && bash scripts/dag/trial.sh down "$AGTAG" >/dev/null 2>&1
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
S3OK=; S3WHY=
s3step() { local what=$1; shift; "$@" >"$WORK/s3.err" 2>&1 || { S3WHY="$what: $(tr '\n' ' ' < "$WORK/s3.err" | cut -c1-300)"; return 1; }; }
s3setup() {
  mkdir -p "$WORK/certs"
  s3step "the certificate" openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/certs/private.key" -out "$WORK/certs/public.crt" -days 2 \
    -subj "/CN=pgvbk-s3" -addext "subjectAltName=DNS:pgvbk-s3" || return 1
  chmod 644 "$WORK/certs/private.key"
  # MinIO's community images are gone from Docker Hub, quay.io and bitnami (run 2): an S3 server that serves its own TLS
  # certificate is tried in turn - MinIO, Versity's gateway, SeaweedFS - and the bucket made over its host port
  S3IMG=; S3P=
  for i in quay.io/minio/minio:latest minio/minio:RELEASE.2025-04-22T22-12-26Z versity/versitygw:latest chrislusf/seaweedfs:latest; do
    docker pull -q "$i" >/dev/null 2>&1 || continue
    case "$i" in
      *minio*) docker run -d --name "$S3" --label pgvigil-proof=inv301 --network "$NET" --network-alias pgvbk-s3 -p 127.0.0.1::9000 \
                 -e MINIO_ROOT_USER=pgvbk -e MINIO_ROOT_PASSWORD="$S3PW" -v "$WORK/certs:/root/.minio/certs:ro" --entrypoint minio "$i" server /data >"$WORK/s3.err" 2>&1 ;;
      *versitygw*) docker run -d --name "$S3" --label pgvigil-proof=inv301 --network "$NET" --network-alias pgvbk-s3 -p 127.0.0.1::9000 \
                 -e ROOT_ACCESS_KEY=pgvbk -e ROOT_SECRET_KEY="$S3PW" -v "$WORK/certs:/certs:ro" --tmpfs /data "$i" \
                 --port :9000 --cert /certs/public.crt --key /certs/private.key posix /data >"$WORK/s3.err" 2>&1 ;;
      *seaweedfs*) printf '{"identities":[{"name":"pgvbk","credentials":[{"accessKey":"pgvbk","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}' "$S3PW" > "$WORK/certs/s3.json" && chmod 644 "$WORK/certs/s3.json" \
                 && docker run -d --name "$S3" --label pgvigil-proof=inv301 --network "$NET" --network-alias pgvbk-s3 -p 127.0.0.1::9000 -v "$WORK/certs:/certs:ro" "$i" \
                 server -s3 -s3.port=9000 -s3.config=/certs/s3.json -s3.cert.file=/certs/public.crt -s3.key.file=/certs/private.key >"$WORK/s3.err" 2>&1 ;;
    esac || { docker rm -f -v "$S3" >/dev/null 2>&1; continue; }
    S3IMG=$i; break
  done
  [ -n "$S3IMG" ] || { S3WHY="no S3 stand-in could be pulled and started (MinIO, versity/versitygw, chrislusf/seaweedfs): $(tr '\n' ' ' < "$WORK/s3.err" | cut -c1-200)"; return 1; }
  sleep 5
  S3P=$(docker port "$S3" 9000/tcp | head -1 | sed 's/.*://')
  s3step "the certificate into the SQL Server container" docker cp "$WORK/certs/public.crt" "$SQL:/tmp/pgvbk-s3.crt" || return 1
  s3step "update-ca-certificates" docker exec -u root "$SQL" bash -c 'cp /tmp/pgvbk-s3.crt /usr/local/share/ca-certificates/pgvbk-s3.crt && update-ca-certificates' || return 1
  s3step "the restart of SQL Server" docker restart "$SQL" || return 1
  up "$SQL" || { S3WHY="SQL Server did not come back after its restart"; return 1; }
  sleep 3
  # the bucket: one signed PUT over the host port (curl's own SigV4)
  for _ in 1 2 3 4 5 6; do
    curl -sk -o "$WORK/s3.err" -w '%{http_code}' --aws-sigv4 "aws:amz:us-east-1:s3" --user "pgvbk:$S3PW" -X PUT "https://127.0.0.1:$S3P/pgvbk" > "$WORK/s3.code" 2>>"$WORK/s3.err" \
      && grep -qE '^(200|409)$' "$WORK/s3.code" && { S3OK=1; break; }
    sleep 3
  done
  [ -n "$S3OK" ] || S3WHY="the bucket on $S3IMG: HTTP $(cat "$WORK/s3.code" 2>/dev/null) $(tr '\n' ' ' < "$WORK/s3.err" | cut -c1-300)"
  echo "  the S3 stand-in: $S3IMG, bucket $([ -n "$S3OK" ] && echo made || echo 'not made')"
}
if [ -z "${PROOF_SKIP_S3:-}" ]; then
  s3setup || true
  [ -n "$S3OK" ] || echo "  the S3 stand-in did not stand up ($S3WHY): L3b will say NOT PROVEN"
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
# SF 'a;b;c' db type [copy]: the fields joined by '|', a NULL written NULL
SF() { local e; e=$(printf '%s' "$1" | tr ';' '\n' | sed "s/.*/coalesce((&)::text, 'NULL')/" | paste -sd, -); S "concat_ws('|', $e)" "$2" "$3" "${4:-false}"; }
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
G=$(SF "backup_set_id;user_name;set_name;description;has_checksums;compressed_bytes < size_bytes;key_algorithm;folder;family_count" pgvbka full)
# key_algorithm as msdb holds it (Learn names 'NO_Encryption'; SQL Server 2022 on Linux leaves NULL for a backup that is
# not encrypted, run 1): either way the set is not encrypted
KA=$(sq "SELECT ISNULL(NULLIF(key_algorithm, ''), 'NULL') FROM msdb.dbo.backupset WHERE backup_set_id = $ID")
[ "$G" = "$ID|sa|pgvbk stripe|four stripes|true|true|$KA|/backups/a/|4" ] && [ "$(L is_encrypted pgvbka full)" = f ] || fail "L1 set: $G (msdb's key_algorithm $KA; encrypted $(L is_encrypted pgvbka full))"
ok "L1: 4 files equal to msdb ($GOT); $G"

echo "== L2 a mirrored full"
sq "BACKUP DATABASE pgvbka TO DISK = N'/backups/m/m1a.bak', DISK = N'/backups/m/m1b.bak' MIRROR TO DISK = N'/backups2/m/m2a.bak', DISK = N'/backups2/m/m2b.bak' WITH FORMAT;" >/dev/null
read2 L2
G=$(q "select count(*) || '|' || string_agg(distinct mirror::text, ',') from pgvigil.mssql_backup_files where instance_id=$(iid) and database_name='pgvbka' and backup_type='full' and not is_copy_only")
R=$(SF "mirror_count;(select string_agg(r, ',' order by r collate \"C\") from unnest(roots) r)" pgvbka full)
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
G=$(SF "key_algorithm;encryptor_type" pgvbka full)
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
else notproven "L3b: a real URL row - the S3 stand-in did not stand up ($S3WHY)"; fi

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
G=$(SF "backup_set_id;folder" pgvbkr full)
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
echo "== I the pages in a headless Chromium"
if command -v chromium >/dev/null && command -v node >/dev/null && [ -z "${PROOF_SKIP_PAGE:-}" ]; then
  (cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "I: npm install axe-core failed"
  CDP=$((PORT + 1)); chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
  CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  NFILES=$(q "select count(*) from pgvigil.mssql_backup_locations l join pgvigil.mssql_backup_files f on f.instance_id = l.from_instance_id and f.database_name = l.database_name and f.backup_type = l.backup_type and f.is_copy_only = l.is_copy_only and f.backup_set_id = l.backup_set_id where l.instance_id=$(iid) and l.database_name='pgvbka'")
  NALL=$(q "select count(*) from pgvigil.mssql_backup_locations l join pgvigil.mssql_backup_files f on f.instance_id = l.from_instance_id and f.database_name = l.database_name and f.backup_type = l.backup_type and f.is_copy_only = l.is_copy_only and f.backup_set_id = l.backup_set_id where l.instance_id=$(iid)")
  cat > "$WORK/page.mjs" <<'JS'
const [port, U, axePath, inst] = process.argv.slice(2);
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
const out = {};
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(500);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const [name, hash, ready] of [['tab', `#/mssqlbackups?i=${inst}&db=pgvbka`, `!!document.querySelector('#mssql-backups-last-files table.grid')`],
                                     ['fleet', '#/backups', `!!document.querySelector('#mssql-backups-fleet-instances table.grid')`]]) {
    await cmd('Page.navigate', { url: U + hash }); await sleep(300);
    const drawn = await until(ready);
    const r = { drawn, errors: await ev(`document.querySelectorAll('main .error').length`) };
    if (name === 'tab' && theme === 'light') {
      r.db = await ev(heads('main section'));
      r.last = await ev(heads('#mssql-backups-last-grid'));
      r.files = await ev(`[...document.querySelectorAll('#mssql-backups-last-files table.grid > tbody > tr')].map(tr => { const c = tr.querySelector('[data-full]'); return c ? [c.getAttribute('data-full') === c.querySelector('code')?.textContent, !!c.querySelector('button')] : [false, false]; })`);
      r.all = await ev(`document.querySelectorAll('#mssql-backups-files-grid table.grid > tbody > tr').length`);
      r.picked = await ev(`document.querySelector('#mssql-backups-picked')?.textContent ?? ''`);
    }
    await cmd('Runtime.evaluate', { expression: axeSrc });
    const a = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(x => x.target.join(' ')) }))))`, true) ?? '[]');
    r.violations = a;
    out[`${name}-${theme}`] = r;
  }
}
console.log(JSON.stringify(out));
process.exit(0);
JS
  node "$WORK/page.mjs" "$CDP" "$U/" "$WORK/node_modules/axe-core/axe.min.js" "$(iid)" > "$WORK/page.json" 2> "$WORK/page.err" || fail "I: the page check did not run: $(tail -c 400 "$WORK/page.err")"
  kill "$CHR" 2>/dev/null || true
  NFILES=$NFILES NALL=$NALL python3 - "$WORK/page.json" <<'PYI' || fail "I: the pages"
import json, os, sys
d = json.load(open(sys.argv[1]))
dd = ["database", "recovery model", "type", "start date", "finish date", "duration", "backup size", "backup MB/s", "backup size (compressed)",
      "compression saving %", "backup write MB/s", "is partner backup", "partner", "is damaged", "checksum", "is compressed", "password protected",
      "encrypted", "snapshot backup", "has bulk logged data", "readonly", "force offline", "single user", "key algorithm", "encryptor type", "compression algorithm"]
own = ["to", "files", "mirrors", "device", "taken by", "machine", "set name", "description", "software", "copy-only", "incomplete metadata", "base", "media password", "on the database's volume"]
bad = []
for k, r in d.items():
    if not r["drawn"] or r["errors"]: bad.append(f"{k}: drawn {r['drawn']}, error boxes {r['errors']}")
    n = sum(v["n"] for v in r["violations"])
    if n: bad.append(f"{k}: {n} axe violation node(s): {r['violations']}")
t = d["tab-light"]
if t.get("last") != dd + own: bad.append(f"the Last backup header: {t.get('last')}")
need = ["full damaged", "differential damaged", "log damaged", "full checksum", "log compression algorithm", "full to", "differential to", "log to"]
miss = [h for h in need if h not in (t.get("db") or [])]
if miss: bad.append(f"the Databases grid lacks {miss}")
if len(t.get("files") or []) != int(os.environ["NFILES"]) or not all(a and b for a, b in t["files"]): bad.append(f"the Files grid: {t.get('files')} (want {os.environ['NFILES']} rows, each data-full = its path, a Copy button)")
if t.get("all") != int(os.environ["NALL"]): bad.append(f"the Backup files grid: {t.get('all')} rows, want {os.environ['NALL']}")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"ok   I: the tab with pgvbka's panel and the fleet page, light and dark: drawn, no error box, 0 axe violation nodes; the Last backup header = DBA Dash's 26 in order + pgvigil's 14; Files {len(t['files'])} rows each with data-full and Copy; Backup files {t['all']} rows")
PYI
else notproven "I: the pages - no chromium or node here (or PROOF_SKIP_PAGE)"; fi
echo "== J an availability group (F10)"
if [ -n "${PROOF_AG:-}" ]; then
  AGTAG=pgvbkag$(printf '%04x' "$SUF"); AGSA="S$(head -c 14 /dev/urandom | od -An -tx1 | tr -d ' \n')!a"
  if KEEP=1 PGVIGIL_DAG_TAG=$AGTAG PGVIGIL_DAG_SA=$AGSA bash scripts/dag/trial.sh > "$WORK/ag.log" 2>&1 && grep -q "DAG FORMED" "$WORK/ag.log"; then
    agq() { SQLCMDPASSWORD="$AGSA" docker exec -e SQLCMDPASSWORD "$AGTAG-$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -Q "SET NOCOUNT ON; $2"; }
    for n in d1a d1b; do
      printf "CREATE LOGIN pgvbk_mon WITH PASSWORD = N'%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvbk_mon; GRANT VIEW ANY DEFINITION TO pgvbk_mon;\n" "$PM" \
        | SQLCMDPASSWORD="$AGSA" docker exec -i -e SQLCMDPASSWORD "$AGTAG-$n" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -d master -i /dev/stdin >/dev/null
      agq $n "USE msdb; CREATE USER pgvbk_mon FOR LOGIN pgvbk_mon; ALTER ROLE db_datareader ADD MEMBER pgvbk_mon;" >/dev/null
      docker exec "$AGTAG-$n" mkdir -p /var/opt/mssql/bk
      IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AGTAG-$n")
      export "MSSQL_AG_${n^^}_DSN=sqlserver://pgvbk_mon:$PM@$IP:1433?database=master&encrypt=true&TrustServerCertificate=true"
      printf '  - name: pgvbk-ag-%s\n    engine: sqlserver\n    dsn: env:MSSQL_AG_%s_DSN\n    mssql_thresholds:\n      new_database_hours: 0\n' "$n" "${n^^}" >> "$CFG"
    done
    agq d1a "BACKUP DATABASE dagdb TO DISK = N'/var/opt/mssql/bk/dagdb_full.bak' WITH FORMAT;" >/dev/null
    sleep 2; agq d1b "BACKUP LOG dagdb TO DISK = N'/var/opt/mssql/bk/dagdb_log.trn' WITH FORMAT;" >/dev/null
    for n in d1a d1b; do for c in mssql_ag mssql_backups mssql_backup_files; do collect $c "pgvbk-ag-$n" || fail "J: $c on $n: $(cat "$OUT")"; done; done
    for n in d1a d1b; do
      IA=$(q "select instance_id from pgvigil.instances where name='pgvbk-ag-$n'")
      G=$(q "select string_agg(backup_type || '@' || replace(from_instance, 'pgvbk-ag-', '') || ':' || (from_instance_id <> instance_id), ',' order by backup_type) || '|' || bool_or(replicas_unseen) from pgvigil.mssql_backup_locations where instance_id=$IA and database_name='dagdb' and shown")
      W=$([ $n = d1a ] && echo "full@d1a:false,log@d1b:true|false" || echo "full@d1a:true,log@d1b:false|false")
      [ "$G" = "$W" ] || fail "J: from $n the group's sets: $G, want $W"
      P=$(curl -s "$U/api/mssql/backup_files?instance=$IA&db=dagdb" | python3 -c 'import json,sys; d=json.load(sys.stdin)["sets"]; c=d["columns"]; print(",".join("%s:%s:%s" % (r[c.index("backup_type")], r[c.index("is_partner")], r[c.index("partner")]) for r in d["rows"] if r[c.index("shown")]))')
      ok "J: from $n: $G; the panel's Is Partner Backup / Partner: $P"
    done
  else notproven "J: a live availability group - the lab did not form: $(grep -E 'FAIL|REFUSED' "$WORK/ag.log" | head -2 | tr '\n' ' ' | cut -c1-300)"; fi
else notproven "J: a live availability group (PROOF_AG unset): the merge rests on TestBackupLocationsOnAStore's stubbed rows"; fi
echo "ALL ROWS GREEN"
