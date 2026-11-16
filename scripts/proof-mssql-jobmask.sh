#!/usr/bin/env bash
# Proof that a SQL Server Agent job step carrying a backup product's key is stored masked (S16; collect.MaskJobText in
# internal/collect/jobs.go, called by internal/mssql/jobs.go for every step's command before the row leaves the
# collector; the job's versions and scripts are built from the masked steps).
#
# Needs: docker (it starts its own SQL Server container, SQL Server Agent on, a throwaway sa password made here and
# never printed; PGVIGIL_MSSQL_IMAGE, default mcr.microsoft.com/mssql/server:2022-latest), psql, pg_dump, python3, go
# at the repository root, and PGVIGIL_ADMIN_DSN, a superuser keyword DSN of a PostgreSQL WITHOUT a password and dbname.
# What it makes and removes on every exit path: the container and its repository database pgvigil_jobmask_<n>.
#
# Each form below is one job of one T-SQL step (never run, except H's and hcut's), its secret a token of its own. After one read
# of the collection mssql_jobs, each token is looked for in pgvigil.mssql_jobs, pgvigil.job_versions (the definition
# and the script) and in a data-only dump of the whole repository; the job itself must have been read (a version), or
# the row proves nothing. Where the syntax comes from: Ola Hallengren's DatabaseBackup page and source (EncryptionKey:
# LiteSpeed's @encryptionkey, Red Gate's PASSWORD inside the -SQL string and its clean-up sqbutility 1032 with the key
# as the sixth argument, Idera SQL Safe's @encryptedbackuppassword - SQL Safe's spelling from that source alone, its
# own pages could not be read), Red Gate's BACKUP command page (PASSWORD = { 'password' | 'FILE:path' }; in
# master..sqlbackup two single quotes, or square brackets), Microsoft's RESTORE page (MEDIAPASSWORD and PASSWORD =
# { literal | @variable }); LiteSpeed's spellings (@encryptionkey | @jobp; the tools' -K / --Key, --TgtKey, --JobP,
# -BackupKey, -jobp) from search results quoting Quest's pages, which answered an empty page to a fetch.
#
# Expected (written before the first run):
#  On main 32c7aace (the red run): FAIL - stored unmasked - for ola1, ola2 (@EncryptionKey, N'' and ''), ls1
#  (@encryptionkey), ls2 (@jobp), rg1, rg2 (PASSWORD = ''...'' and N''...'' inside the -SQL string: the regex ends
#  the value at the first doubled quote), rg3 (PASSWORD = [... ...]: the value cut at the space), mp1
#  (MEDIAPASSWORD = N'...': only the N is masked), dyn1 (PASSWORD = ''...'' inside EXEC (N'...')), cli1 (-BackupKey),
#  cli2 (--JobP), cli3 (-K): 12 FAIL; ok for the controls ss1 (@encryptedbackuppassword), mp2 (MEDIAPASSWORD = '...'),
#  rs1 (RESTORE ... PASSWORD = N'...'), rgc (SQLBackupC's -SQL "... PASSWORD = '...'") and for keep1 / keep2 (a
#  certificate's name, @KeyColumns, @EncryptionKeyPlaceholder, -KeepAlive: readable in the version); 'PROOF FAILED'.
#  After the fix: every row ok, 'PROOF OK'.
#  H and hcut (a run's output; NOTE rows, not graded: outside S16's order, asked of the lead): a job whose step PRINTs
#  a backup command with its key, run once, and one whose printed key msdb's history cuts: their tokens are in
#  pgvigil.mssql_job_runs (sysjobhistory.message is stored as read, while docs/jobs.md says a run's output is masked on
#  both engines).
#  The review's fold (expected written before the red run, on the code before the fold): FAIL for cut1 (a step over
#  8,000 characters cut by the read inside its key: the key's first characters stored), rg4 (sqbutility 1032's sixth
#  argument), ls3 (@EncryptionKey as a bare word), cli4 (-K ''...'' inside xp_cmdshell's string), rg5 (PASSWORD =
#  [..]]..]): 5 FAIL, 'PROOF FAILED: 5' (the red run maskred2 graded hcut too: 6); every older row ok, keep1-keep3 ok
#  (each stored command equal to the command sent). After the fold: every row ok.
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
: "${PGVIGIL_ADMIN_DSN:?a superuser keyword DSN of the PostgreSQL, no password, no dbname}"
for t in docker psql pg_dump python3 go; do command -v $t >/dev/null || { echo "FAIL: $t missing" >&2; exit 1; }; done
[ -f go.mod ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
SUF=$RANDOM; CT=pgvjm-$SUF; REPO_DB=pgvigil_jobmask_$SUF
IMAGE=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
MSSQL_SA_PASSWORD="Pv9$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; export MSSQL_SA_PASSWORD SQLCMDPASSWORD=$MSSQL_SA_PASSWORD
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; BIN=$WORK/pgvigil
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { local rc=$?; set +e
  docker rm -f -v "$CT" >/dev/null 2>&1
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtqc "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1
  rm -rf "$WORK"; exit $rc; }
trap cleanup EXIT INT TERM
PORT=$((21000 + RANDOM % 9000))
echo "load: $(cut -d' ' -f1-3 /proc/loadavg) (shared box)"
docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_AGENT_ENABLED=true -p 127.0.0.1:$PORT:1433 "$IMAGE" >/dev/null
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# T-SQL on stdin: a text holding quotes never passes through a shell argument
sqi() { docker exec -i -e SQLCMDPASSWORD "$CT" $SQLCMD -S localhost -U sa -C -b -I -W -h -1 -s '|' -d master -i /dev/stdin; }
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | sqi; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null || fail "SQL Server did not come up"
for _ in $(seq 1 60); do [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE 'SQLAgent%'")" -gt 0 ] 2>/dev/null && break; sleep 2; done
go build -o "$BIN" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
export MSSQL_DSN="sqlserver://sa:$MSSQL_SA_PASSWORD@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1" </dev/null; }   # never the loop's stdin
NS=jobmask-$SUF
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $NS
    engine: sqlserver
    dsn: env:MSSQL_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null

# id ~~ class (leak: masked only after the fix; control: masked before it too; keep: stored exactly as sent, its K16
# tokens readable; cut: a leak whose key the read cuts, looked for by its first characters S16<id>; run / runcut: run
# once, its output read) ~~ the step's command; @@SUF@@ is this run's number, @@PADTO7990@@ pads the text so that
# S16<id> begins at its 7,991st character (the read keeps 8,000), @@ZPAD3900@@ is 3,900 z's
cat > "$WORK/forms.txt" <<'FORMS'
ola1 ~~ leak ~~ EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @Directory = N'/var/opt/mssql/data', @BackupType = 'FULL', @BackupSoftware = 'LITESPEED', @Encrypt = 'Y', @EncryptionAlgorithm = 'AES_256', @EncryptionKey = N'S16ola1@@SUF@@'
ola2 ~~ leak ~~ EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @BackupSoftware = 'SQLBACKUP', @Encrypt = 'Y', @EncryptionAlgorithm = 'AES_256', @EncryptionKey = 'S16ola2@@SUF@@'
ls1 ~~ leak ~~ EXEC master.dbo.xp_backup_database @database = N'db1', @filename = N'/b/db1.bak', @encryptionkey = N'S16ls1@@SUF@@', @cryptlevel = 8
ls2 ~~ leak ~~ EXEC master.dbo.xp_backup_log @database = N'db1', @filename = N'/b/db1.trn', @jobp = N'S16ls2@@SUF@@'
rg1 ~~ leak ~~ EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = ''S16rg1@@SUF@@'', KEYSIZE = 256"'
rg2 ~~ leak ~~ DECLARE @ReturnCode int EXECUTE @ReturnCode = dbo.sqlbackup N'-SQL "BACKUP DATABASE [db1] TO DISK = N''/b/db1.sqb'' WITH CHECKSUM, PASSWORD = N''S16rg2@@SUF@@''"' IF @ReturnCode <> 0 RAISERROR('Error performing SQLBackup backup.', 16, 1)
rg3 ~~ leak ~~ EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [rg S16rg3@@SUF@@] "'
mp1 ~~ leak ~~ RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH MEDIAPASSWORD = N'S16mp1@@SUF@@', REPLACE
dyn1 ~~ leak ~~ EXEC (N'ALTER LOGIN app WITH PASSWORD = ''S16dyn1@@SUF@@'', CHECK_POLICY = OFF')
cli1 ~~ leak ~~ slssqlmaint.exe -BackupKey S16cli1@@SUF@@ -Verify
cli2 ~~ leak ~~ SLSFastCompression.exe -e 8 --JobP S16cli2@@SUF@@ -F x.bak
cli3 ~~ leak ~~ extractor.exe -F /b/db1.bak -K S16cli3@@SUF@@ -E db1
ss1 ~~ control ~~ EXEC master.dbo.xp_ss_backup @database = N'db1', @filename = N'/b/db1.safe', @encryptiontype = N'AES256', @encryptedbackuppassword = N'S16ss1@@SUF@@'
mp2 ~~ control ~~ BACKUP DATABASE db1 TO DISK = '/b/db1.bak' WITH MEDIAPASSWORD = 'S16mp2@@SUF@@', INIT
rs1 ~~ control ~~ RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH PASSWORD = N'S16rs1@@SUF@@', REPLACE
rgc ~~ control ~~ SQLBackupC.exe -I inst1 -SQL "BACKUP DATABASE db1 TO DISK = 'x.sqb' WITH PASSWORD = 'S16rgc@@SUF@@'"
keep1 ~~ keep ~~ EXECUTE dbo.DatabaseBackup @Encrypt = 'Y', @ServerCertificate = N'K16cert@@SUF@@', @KeyColumns = N'K16cols@@SUF@@', @EncryptionKeyPlaceholder = N'K16ph@@SUF@@'
keep2 ~~ keep ~~ Invoke-Thing -KeepAlive -Name K16name@@SUF@@ -Force
keep3 ~~ keep ~~ EXECUTE master..sqbutility 1032, N'K16db@@SUF@@', N'/b', 'D', '24h', NULL; EXECUTE dbo.DatabaseBackup @Databases = 'K16dbs@@SUF@@', @EncryptionKey = NULL, @Verify = 'Y'
cut1 ~~ cut ~~ EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @Directory = N'/b/@@PADTO7990@@', @BackupType = 'FULL', @BackupSoftware = 'LITESPEED', @EncryptionKey = N'S16cut1@@SUF@@zzzzzzzzzzzzzzzzzzzz'
rg4 ~~ leak ~~ EXECUTE master..sqbutility 1032, N'db1', N'/b', 'D', '24h', 'S16rg4@@SUF@@'
ls3 ~~ leak ~~ EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @BackupSoftware = 'LITESPEED', @EncryptionKey = S16ls3@@SUF@@, @Verify = 'Y'
cli4 ~~ leak ~~ EXEC xp_cmdshell 'extractor.exe -F /b/db1.bak -K ''S16cli4@@SUF@@'' -E db1'
rg5 ~~ leak ~~ EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [ab]]S16rg5@@SUF@@] "'
H ~~ run ~~ PRINT N'Command: EXECUTE master.dbo.xp_backup_database @database = N''master'', @encryptionkey = N''S16hist@@SUF@@''';
hcut ~~ runcut ~~ PRINT N'Command: EXECUTE master.dbo.xp_backup_database @database = N''master'', @encryptionkey = N''S16hcut@@SUF@@@@ZPAD3900@@''';
FORMS
# one job per form, the command's quotes doubled inside @command = N'...'
python3 - "$WORK/forms.txt" "$SUF" > "$WORK/jobs.sql" <<'PY'
import sys
suf = sys.argv[2]
print("SET NOCOUNT ON;")
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    fid, cls, cmd = line.split(" ~~ ", 2)
    cmd = cmd.replace("@@SUF@@", suf).replace("@@ZPAD3900@@", "z" * 3900)
    if "@@PADTO7990@@" in cmd:
        head, tail = cmd.split("@@PADTO7990@@")
        pad = 7990 - len(head) - tail.index("S16" + fid)
        assert pad > 0, pad
        cmd = head + "x" * pad + tail
        assert cmd.index("S16" + fid) == 7990 and len(cmd) > 8000, (cmd.index("S16" + fid), len(cmd))
    cmd = cmd.replace("'", "''")
    name = "pgvjm %s %s" % (fid, suf)
    print("EXEC msdb.dbo.sp_add_job @job_name = N'%s', @owner_login_name = N'sa';" % name)
    print("EXEC msdb.dbo.sp_add_jobstep @job_name = N'%s', @step_id = 1, @step_name = N'one', @subsystem = N'TSQL', @command = N'%s';" % (name, cmd))
    print("EXEC msdb.dbo.sp_add_jobserver @job_name = N'%s';" % name)
PY
sqi < "$WORK/jobs.sql" >/dev/null || fail "the jobs were not made"
N=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE N'pgvjm % $SUF'")
[ "$N" = "$(grep -c ' ~~ ' "$WORK/forms.txt")" ] || fail "made $N jobs of $(grep -c ' ~~ ' "$WORK/forms.txt")"
# H and hcut run once: a step's output lands in sysjobhistory.message and the job's last outcome message
for r in H hcut; do sq "EXEC msdb.dbo.sp_start_job @job_name = N'pgvjm $r $SUF';" >/dev/null; done
for _ in $(seq 1 45); do
  [ "$(sq "SELECT COUNT(DISTINCT j.name) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name IN (N'pgvjm H $SUF', N'pgvjm hcut $SUF') AND h.step_id = 0")" -ge 2 ] 2>/dev/null && break; sleep 2; done
HRUN=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'pgvjm H $SUF' AND h.message LIKE N'%S16hist$SUF%'")
# hcut's row proves the cut only where msdb kept its key without the closing quote (the z's run past 4,000 characters)
HCUT=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'pgvjm hcut $SUF' AND h.message LIKE N'%S16hcut$SUF%' AND h.message NOT LIKE N'%z''%'")
echo "NOTE msdb: $(sq "SELECT N'sysjobhistory.message ' + CAST(c.max_length / 2 AS nvarchar(9)) + N' characters, sysjobservers.last_outcome_message ' + CAST(c2.max_length / 2 AS nvarchar(9)) + N'; the history rows of hcut holding its key cut: $HCUT, their length ' + ISNULL((SELECT CAST(MAX(LEN(h.message)) AS nvarchar(9)) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'pgvjm hcut $SUF' AND h.step_id = 1), N'none') FROM msdb.sys.columns c, msdb.sys.columns c2 WHERE c.object_id = OBJECT_ID(N'msdb.dbo.sysjobhistory') AND c.name = N'message' AND c2.object_id = OBJECT_ID(N'msdb.dbo.sysjobservers') AND c2.name = N'last_outcome_message'")"
"$BIN" collect -config "$CFG" -once mssql_jobs -instance "$NS" >"$OUT" 2>&1 || { cat "$OUT"; fail "collect mssql_jobs"; }
IS=$(q "select instance_id from pgvigil.instances where name='$NS'")
pg_dump "$PGVIGIL_REPO_DSN" --data-only -n pgvigil > "$WORK/dump.sql" 2>"$WORK/dump.err" || { cat "$WORK/dump.err"; fail "pg_dump of the repository"; }

BAD=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  fid=${line%% ~~ *}; rest=${line#* ~~ }; cls=${rest%% ~~ *}; jn="pgvjm $fid $SUF"
  read_n=$(q "select count(*) from pgvigil.job_versions where instance_id=$IS and scheduler='sqlagent' and job_name='$jn'")
  if [ "$read_n" -lt 1 ]; then echo "FAIL $fid: the job was not read (no version)"; BAD=$((BAD+1)); continue; fi
  case $cls in
    leak|control|cut)
      tok=S16$fid$SUF; [ "$cls" = cut ] && tok=S16$fid   # a cut keeps only the key's first characters
      js=$(q "select count(*) from pgvigil.mssql_jobs j where j.instance_id=$IS and j::text like '%$tok%'")
      jv=$(q "select count(*) from pgvigil.job_versions v where v.instance_id=$IS and v::text like '%$tok%'")
      dm=$(grep -c "$tok" "$WORK/dump.sql" || true)
      mk=$(q "select count(*) from pgvigil.job_versions v where v.instance_id=$IS and v.job_name='$jn' and v.definition::text like '%<masked>%' and v.script like '%<masked>%'")
      cmd=$(q "select v.definition #>> '{steps,step 01,command}' from pgvigil.job_versions v where v.instance_id=$IS and v.job_name='$jn' and v.version_no=1")
      [ "$cls" = cut ] && cmd="(${#cmd} characters) ...${cmd: -90}"
      if [ "$js$jv$dm" = "000" ] && [ "$mk" -ge 1 ]; then echo "ok $fid ($cls): masked (mssql_jobs 0, job_versions 0, dump 0; <masked> in the definition and the script): $cmd"
      else echo "FAIL $fid ($cls): stored unmasked: mssql_jobs $js, job_versions $jv, dump $dm, <masked> $mk: $cmd"; BAD=$((BAD+1)); fi ;;
    keep)
      miss=""
      for tok in $(printf '%s\n' "$rest" | grep -o "K16[a-z]*@@SUF@@" | sed "s/@@SUF@@/$SUF/"); do
        [ "$(q "select count(*) from pgvigil.job_versions v where v.instance_id=$IS and v.job_name='$jn' and v.definition::text like '%$tok%' and v.script like '%$tok%'")" -ge 1 ] || miss="$miss $tok"
      done
      cmd=$(q "select v.definition #>> '{steps,step 01,command}' from pgvigil.job_versions v where v.instance_id=$IS and v.job_name='$jn' and v.version_no=1")
      sent=${rest#* ~~ }; sent=${sent//@@SUF@@/$SUF}
      [ "$cmd" = "$sent" ] || miss="$miss (the stored command differs from the one sent)"
      if [ -z "$miss" ]; then echo "ok $fid (keep): stored as sent, readable in the definition and the script: $cmd"
      else echo "FAIL $fid (keep): lost$miss: $cmd"; BAD=$((BAD+1)); fi ;;
    runcut)
      tok=S16hcut$SUF
      rr=$(q "select count(*) from pgvigil.mssql_job_runs r where r.instance_id=$IS and r::text like '%$tok%'")
      dm=$(grep -c "$tok" "$WORK/dump.sql" || true)
      mr=$(q "select count(*) from pgvigil.mssql_job_runs r join pgvigil.mssql_jobs j on j.instance_id=r.instance_id and j.job_id=r.job_id where r.instance_id=$IS and j.name='$jn' and r.message like '%<masked>'")
      echo "NOTE hcut (a run's output cut inside its key, not graded): msdb history rows holding the key cut $HCUT; stored: mssql_job_runs $rr, dump $dm; runs ending '<masked>' $mr" ;;
    run)
      tok=S16hist$SUF
      rr=$(q "select count(*) from pgvigil.mssql_job_runs r where r.instance_id=$IS and r::text like '%$tok%'")
      lm=$(q "select count(*) from pgvigil.mssql_jobs j where j.instance_id=$IS and j.last_message like '%$tok%'")
      st=$(q "select count(*) from pgvigil.job_versions v where v.instance_id=$IS and v.job_name='$jn' and v::text like '%$tok%'")
      dm=$(grep -c "$tok" "$WORK/dump.sql" || true)
      mr=$(q "select count(*) from pgvigil.mssql_job_runs r join pgvigil.mssql_jobs j on j.instance_id=r.instance_id and j.job_id=r.job_id where r.instance_id=$IS and j.name='$jn' and r.message like '%<masked>%'")
      echo "NOTE H (a run's output, not graded): msdb history rows holding the token $HRUN; stored: mssql_job_runs $rr, mssql_jobs.last_message $lm, the step in job_versions $st, dump $dm; runs with <masked> $mr" ;;
  esac
done < "$WORK/forms.txt"
if [ "$BAD" = 0 ]; then echo "PROOF OK"; else echo "PROOF FAILED: $BAD"; exit 1; fi
