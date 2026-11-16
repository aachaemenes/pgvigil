#!/usr/bin/env bash
# Proof that a SQL Server Agent job step carrying a backup product's key is stored masked (S16; the rules of
# internal/jobmask, collect.MaskJobText, called by internal/mssql/jobs.go for every step's command before the row
# leaves the collector; the job's versions and scripts are built from the masked steps).
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
#  H (a run's output; outside S16's order, its own commit, asked for): a job whose step PRINTs a backup
#  command with its key, run once. Red run (maskred1, a NOTE then): the token in msdb's history 1, stored in
#  pgvigil.mssql_job_runs 1, in the step's version 1, the dump 3. Expected after the H commit (maskRunText in
#  internal/mssql/jobs.go): the history still holds it (1), stored nowhere (mssql_job_runs 0, the step's version 0,
#  dump 0) and <masked> in the stored run's message: 'ok H'. mssql_jobs.last_message is 0 before and after (the
#  Agent's job summary does not carry the step's text): this row is no evidence for it - TestMaskRunText is.
#  The review's fold (expected written before maskred2, on 6216f515's code with these rows): FAIL for cut1 (a step
#  over 8,000 characters cut by the read inside its key: the key's first characters stored), hcut (a step's printed
#  key cut by msdb's history inside it: stored), rg4 (sqbutility 1032's sixth argument), ls3 (@EncryptionKey as a bare
#  word), cli4 (-K ''...'' inside xp_cmdshell's string), rg5 (PASSWORD = [..]]..]): 6 FAIL, 'PROOF FAILED: 6'; every
#  older row ok, keep1-keep3 ok (each stored command equal to the command sent). After the fold: every row ok.
#  The switches by their tool (R9; expected written before its red run, on ee03c155's code): FAIL for
#  keep4 (a PowerShell -Path stored '-P<masked>') and keep5 (sqlcmd's -K ReadOnly stored '-K <masked>'): 2 FAIL,
#  'PROOF FAILED: 2'; ok for the controls os1 (osql's attached -P) and is1 (isql.exe's -P) and every older row. After
#  it: every row ok.
#  U, the upgrade (R1 (B), migration 0272; only with PGVIGIL_OLD_SRC, a source tree of the build
#  before S16, else 'NOT PROVEN U'): the same jobs read by that build into a repository of their own, then migrate with
#  this build. Expected written before its red run (on 432239a4's code, no 0272): FAIL - a secret still in
#  job_versions, mssql_jobs or mssql_job_runs - for the twelve forms the older build stored raw or in part (ola1, ola2,
#  ls1, ls2, rg1, rg2, rg3, mp1, dyn1, cli1-3) and for cut1, rg4, ls3, cli4, H and hcut: 18 FAIL; ok for ss1, mp2,
#  rs1, rgc, os1, is1 and rg5 (masked by the older build already); the dump row FAIL; ok for 'the migrate writes no
#  version' and 'the first read after it writes at most one version a job, the second none'. After 0272: every U row
#  ok.
#  U's guard row G1 (attempt 3; expected written before its red run, on 29c61eff's code): a step
#  command two levels of dynamic SQL deep (a form no rule reads), planted into one stored script's @command literal
#  before the migrate: red - its secret left in job_versions (FAIL G1); after the guard: the literal replaced whole by
#  '<masked: an older build stored this command unmasked>', the secret nowhere (ok G1). With it, the red run's four
#  FAIL U rows (cut1, cli4, H, hcut: job_versions only, by column) and the dump row: 'PROOF FAILED: 6'.
#  The fold's review (expected written before its red run, on 83bd45ce's code with these rows): this build's read
#  FAILs cn1 (-P on a line continued by cmd's ^), va1 / va2 (sqlcmd named through $sqlcmd / %SQLCMD%) and dsc1 (a
#  key in the job's description, stored as read); om1 (a key = value mark at its string's closing quote) and rg6
#  (PASSWORD = [..,..]) ok. U: FAIL om1 (the migrate drops the text after the mark: the command differs from this
#  build's own read), rg6 (the older build's '<masked>,<key>]' left), dsc1 (the description's key left in the stored
#  script), pk1 / pk2 (pg_cron's jobs and runs, planted as the older build's MaskJobText stores them, not masked
#  again), G1 (planted into the definition too: left there) and the dump row; ok for keep1-keep5 (the migrate changes
#  none of them), cn1, va1, va2 (the older build masked every -P) and every older U row: 'PROOF FAILED: 10'; the
#  step's cost a NOTE. After the fold: every row ok.
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
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtqc "drop database if exists ${REPO_DB}_u with (force)" >/dev/null 2>&1
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
os1 ~~ control ~~ EXEC xp_cmdshell 'osql -S localhost -U u -PS16os1@@SUF@@ -Q "SELECT 1"'
is1 ~~ control ~~ isql.exe -S localhost -U u -P S16is1@@SUF@@
keep1 ~~ keep ~~ EXECUTE dbo.DatabaseBackup @Encrypt = 'Y', @ServerCertificate = N'K16cert@@SUF@@', @KeyColumns = N'K16cols@@SUF@@', @EncryptionKeyPlaceholder = N'K16ph@@SUF@@'
keep2 ~~ keep ~~ Invoke-Thing -KeepAlive -Name K16name@@SUF@@ -Force
keep3 ~~ keep ~~ EXECUTE master..sqbutility 1032, N'K16db@@SUF@@', N'/b', 'D', '24h', NULL; EXECUTE dbo.DatabaseBackup @Databases = 'K16dbs@@SUF@@', @EncryptionKey = NULL, @Verify = 'Y'
keep4 ~~ keep ~~ Get-ChildItem -Path /var/opt/mssql/K16path@@SUF@@ -PassThru
keep5 ~~ keep ~~ sqlcmd -S localhost -E -K ReadOnly -Q "SELECT 'K16sq@@SUF@@'"
cut1 ~~ cut ~~ EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @Directory = N'/b/@@PADTO7990@@', @BackupType = 'FULL', @BackupSoftware = 'LITESPEED', @EncryptionKey = N'S16cut1@@SUF@@zzzzzzzzzzzzzzzzzzzz'
rg4 ~~ leak ~~ EXECUTE master..sqbutility 1032, N'db1', N'/b', 'D', '24h', 'S16rg4@@SUF@@'
ls3 ~~ leak ~~ EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @BackupSoftware = 'LITESPEED', @EncryptionKey = S16ls3@@SUF@@, @Verify = 'Y'
cli4 ~~ leak ~~ EXEC xp_cmdshell 'extractor.exe -F /b/db1.bak -K ''S16cli4@@SUF@@'' -E db1'
rg5 ~~ leak ~~ EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [ab]]S16rg5@@SUF@@] "'
H ~~ run ~~ PRINT N'Command: EXECUTE master.dbo.xp_backup_database @database = N''master'', @encryptionkey = N''S16hist@@SUF@@''';
hcut ~~ runcut ~~ PRINT N'Command: EXECUTE master.dbo.xp_backup_database @database = N''master'', @encryptionkey = N''S16hcut@@SUF@@@@ZPAD3900@@''';
om1 ~~ mark ~~ SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=localhost;Uid=u;Pwd=S16om1@@SUF@@', 'SELECT 1 AS K16om1@@SUF@@')
rg6 ~~ leak ~~ EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [ab,S16rg6@@SUF@@] "'
cn1 ~~ leak ~~ bcp db1.dbo.t out /b/t.dat -S localhost -U u ^@@NL@@-P S16cn1@@SUF@@ -c
va1 ~~ leak ~~ & $sqlcmd -S localhost -U u -P S16va1@@SUF@@ -Q "SELECT 1"
va2 ~~ leak ~~ "%SQLCMD%" -S localhost -U u -P S16va2@@SUF@@
dsc1 ~~ desc ~~ nightly copy: Server=localhost;Uid=u;Pwd=S16dsc1@@SUF@@;
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
    cmd = cmd.replace("@@SUF@@", suf).replace("@@ZPAD3900@@", "z" * 3900).replace("@@NL@@", "\r\n")
    if "@@PADTO7990@@" in cmd:
        head, tail = cmd.split("@@PADTO7990@@")
        pad = 7990 - len(head) - tail.index("S16" + fid)
        assert pad > 0, pad
        cmd = head + "x" * pad + tail
        assert cmd.index("S16" + fid) == 7990 and len(cmd) > 8000, (cmd.index("S16" + fid), len(cmd))
    cmd = cmd.replace("'", "''")
    name = "pgvjm %s %s" % (fid, suf)
    if cls == "desc":   # the text is the job's description, its step a plain SELECT
        print("EXEC msdb.dbo.sp_add_job @job_name = N'%s', @owner_login_name = N'sa', @description = N'%s';" % (name, cmd))
        cmd = "SELECT 1"
    else:
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
    desc)
      tok=S16$fid$SUF
      js=$(q "select count(*) from pgvigil.mssql_jobs j where j.instance_id=$IS and j::text like '%$tok%'")
      jv=$(q "select count(*) from pgvigil.job_versions v where v.instance_id=$IS and v::text like '%$tok%'")
      dm=$(grep -c "$tok" "$WORK/dump.sql" || true)
      dd=$(q "select description from pgvigil.mssql_jobs j where j.instance_id=$IS and j.name='$jn'")
      if [ "$js$jv$dm" = "000" ] && [[ $dd == *"<masked>"* ]]; then echo "ok $fid (a job's description): masked (mssql_jobs 0, job_versions 0, dump 0): $dd"
      else echo "FAIL $fid (a job's description): stored unmasked: mssql_jobs $js, job_versions $jv, dump $dm: $dd"; BAD=$((BAD+1)); fi ;;
    leak|control|cut|mark)
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
      line="msdb history rows holding the key cut $HCUT; stored: mssql_job_runs $rr, dump $dm; runs ending '<masked>' $mr"
      if [ "$HCUT" -lt 1 ]; then echo "FAIL hcut (a run's output cut inside its key): msdb did not cut it, the row proves nothing: $line"; BAD=$((BAD+1))
      elif [ "$rr$dm" = "00" ] && [ "$mr" -ge 1 ]; then echo "ok hcut (a run's output cut inside its key): $line"
      else echo "FAIL hcut (a run's output cut inside its key): $line"; BAD=$((BAD+1)); fi ;;
    run)
      tok=S16hist$SUF
      rr=$(q "select count(*) from pgvigil.mssql_job_runs r where r.instance_id=$IS and r::text like '%$tok%'")
      lm=$(q "select count(*) from pgvigil.mssql_jobs j where j.instance_id=$IS and j.last_message like '%$tok%'")
      st=$(q "select count(*) from pgvigil.job_versions v where v.instance_id=$IS and v.job_name='$jn' and v::text like '%$tok%'")
      dm=$(grep -c "$tok" "$WORK/dump.sql" || true)
      mr=$(q "select count(*) from pgvigil.mssql_job_runs r join pgvigil.mssql_jobs j on j.instance_id=r.instance_id and j.job_id=r.job_id where r.instance_id=$IS and j.name='$jn' and r.message like '%<masked>%'")
      line="msdb history rows holding the token $HRUN; stored: mssql_job_runs $rr, mssql_jobs.last_message $lm, the step in job_versions $st, dump $dm; runs with <masked> $mr"
      if [ "$HRUN" -ge 1 ] && [ "$rr$lm$st$dm" = "0000" ] && [ "$mr" -ge 1 ]; then echo "ok H (a run's output): $line"
      else echo "FAIL H (a run's output): $line"; BAD=$((BAD+1)); fi ;;
  esac
done < "$WORK/forms.txt"

# U: the upgrade - the same jobs read by the build before S16 into a repository of their own, then this build's migrate
if [ -z "${PGVIGIL_OLD_SRC:-}" ]; then
  echo "NOT PROVEN U: no older build's source given (PGVIGIL_OLD_SRC)"
else
  OLDBIN=$WORK/pgvigil-old; ( cd "$PGVIGIL_OLD_SRC" && go build -o "$OLDBIN" ./cmd/pgvigil ) || fail "the older build"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database ${REPO_DB}_u"
  export PGVIGIL_REPO_DSN_U="$PGVIGIL_ADMIN_DSN dbname=${REPO_DB}_u"
  sed 's/env:PGVIGIL_REPO_DSN$/env:PGVIGIL_REPO_DSN_U/' "$CFG" > "$WORK/pgvigil-u.yaml"
  grep -q 'env:PGVIGIL_REPO_DSN_U' "$WORK/pgvigil-u.yaml" || fail "the U configuration"
  qu() { psql "$PGVIGIL_REPO_DSN_U" -XAt -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
  # each job's version count, one 'name:count' a line
  vc() { qu "select coalesce(string_agg(job_name || ':' || n, E'\n' order by job_name), '') from (select job_name, count(*) n from pgvigil.job_versions where scheduler = 'sqlagent' group by job_name) x"; }
  "$OLDBIN" migrate -config "$WORK/pgvigil-u.yaml" >/dev/null
  "$OLDBIN" collect -config "$WORK/pgvigil-u.yaml" -once mssql_jobs -instance "$NS" >"$OUT" 2>&1 || { cat "$OUT"; fail "the older build's collect"; }
  # G1: a form no rule reads (two levels of dynamic SQL), planted into keep1's stored script as one more step
  python3 -I - "$SUF" <<'PY' | psql "$PGVIGIL_REPO_DSN_U" -XAtq -v ON_ERROR_STOP=1 >/dev/null || fail "the G1 plant"
import sys
suf = sys.argv[1]
content = "EXEC ('EXEC (''ALTER LOGIN a WITH PASSWORD = ''''S16g1" + suf + "'''''')')"
line = ("\nEXEC msdb.dbo.sp_add_jobstep @job_name = N'pgvjm keep1 " + suf + "', @step_id = 9, @step_name = N'planted', "
        "@subsystem = N'TSQL', @command = N'" + content.replace("'", "''") + "'")
assert "$pv$" not in line
print("UPDATE pgvigil.job_versions SET script = script || $pv$" + line + "$pv$ WHERE scheduler = 'sqlagent' AND job_name = 'pgvjm keep1 " + suf + "' AND script IS NOT NULL;")
# and into its definition as a step of its own (the guard covers every value the step masks: the review, 6)
assert "$pv$" not in content
print("UPDATE pgvigil.job_versions SET definition = jsonb_set(definition, '{steps,step 09}', jsonb_build_object('command', $pv$" + content + "$pv$)) WHERE scheduler = 'sqlagent' AND job_name = 'pgvjm keep1 " + suf + "';")
PY
  [ "$(qu "select count(*) from pgvigil.job_versions where script like '%S16g1$SUF%'")" -ge 1 ] || fail "G1 was not planted in the script"
  [ "$(qu "select count(*) from pgvigil.job_versions where definition::text like '%S16g1$SUF%'")" -ge 1 ] || fail "G1 was not planted in the definition"
  # pk1 / pk2: pg_cron commands and a run's output in pgvigil.jobs / job_runs, as the older build's own MaskJobText
  # stored them (run from its source: this proof has no pg_cron), each key in a libpq value quoted inside the SQL string
  OM=$PGVIGIL_OLD_SRC/cmd/pgvjm-oldmask; mkdir -p "$OM"
  cat > "$OM/main.go" <<'GO'
// The older build's job text masking of stdin, for the proof's pg plants (made and removed by the proof).
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func main() {
	b, err := io.ReadAll(os.Stdin)
	if err != nil {
		os.Exit(1)
	}
	fmt.Print(collect.MaskJobText(string(b)))
}
GO
  python3 -I - "$SUF" "$WORK" <<'PY'
import sys
suf, work = sys.argv[1], sys.argv[2]
open(work + "/pk1.raw", "w").write("SELECT dblink_exec('dbname=x password=''S16pk1" + suf + "'' host=K16pk1" + suf + "', 'VACUUM')")
open(work + "/pk2.raw", "w").write("SELECT dblink_exec('host=h password=''S16pk2" + suf + " zz''', 'SELECT 1')")
PY
  for k in pk1 pk2; do ( cd "$PGVIGIL_OLD_SRC" && go run ./cmd/pgvjm-oldmask ) < "$WORK/$k.raw" > "$WORK/$k.old" || fail "the older build's mask of $k"; done
  rm -f "$OM/main.go"; rmdir "$OM"
  for k in pk1 pk2; do grep -q "S16$k$SUF" "$WORK/$k.old" || fail "the older build masked $k whole: its plant would prove nothing"; done
  echo "NOTE U pk1 / pk2 as the older build stores them: $(cat "$WORK/pk1.old") | $(cat "$WORK/pk2.old")"
  IU=$(qu "select instance_id from pgvigil.instances where name='$NS'")
  python3 -I - "$IU" "$WORK" <<'PY' | psql "$PGVIGIL_REPO_DSN_U" -XAtq -v ON_ERROR_STOP=1 >/dev/null || fail "the pk plant"
import sys
iu, work = sys.argv[1], sys.argv[2]
m1, m2 = open(work + "/pk1.old").read(), open(work + "/pk2.old").read()
assert "$pv$" not in m1 + m2
print("INSERT INTO pgvigil.jobs (instance_id, scheduler, job_id, snapshot_at, first_seen, command) VALUES (%s, 'pg_cron', 9001, now(), now(), $pv$%s$pv$);" % (iu, m1))
print("INSERT INTO pgvigil.job_runs (instance_id, scheduler, job_id, run_id, command, return_message, snapshot_at) VALUES (%s, 'pg_cron', 9001, 1, $pv$%s$pv$, $pv$%s$pv$, now());" % (iu, m1, m2))
PY
  # each keep row's command before the migrate: the migrate must not change it (the review, 5)
  declare -A KB
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fid=${line%% ~~ *}; rest=${line#* ~~ }; cls=${rest%% ~~ *}
    [ "$cls" = keep ] && KB[$fid]=$(qu "select definition #>> '{steps,step 01,command}' from pgvigil.job_versions where job_name='pgvjm $fid $SUF' and version_no=1")
  done < "$WORK/forms.txt"
  V0=$(vc)
  "$BIN" migrate -config "$WORK/pgvigil-u.yaml" >"$OUT" 2>&1 || { cat "$OUT"; fail "this build's migrate over the older store"; }
  V1=$(vc)
  pg_dump "$PGVIGIL_REPO_DSN_U" --data-only -n pgvigil > "$WORK/dump-u.sql" 2>"$WORK/dump.err" || { cat "$WORK/dump.err"; fail "pg_dump of the U repository"; }
  DUMPLEFT=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fid=${line%% ~~ *}; rest=${line#* ~~ }; cls=${rest%% ~~ *}
    case $cls in
      leak|control|mark|desc) tok=S16$fid$SUF ;;
      cut) tok=S16$fid ;;
      run) tok=S16hist$SUF ;;
      runcut) tok=S16hcut$SUF ;;
      keep)
        ua=$(qu "select definition #>> '{steps,step 01,command}' from pgvigil.job_versions where job_name='pgvjm $fid $SUF' and version_no=1")
        q1="'"; enc="@command = N'${ua//$q1/$q1$q1}'"
        sc=$(qu "select count(*) from pgvigil.job_versions where job_name='pgvjm $fid $SUF' and version_no=1 and position(\$e\$${enc}\$e\$ in script) > 0")
        if [ -n "$ua" ] && [ "$ua" = "${KB[$fid]}" ] && [ "$sc" = 1 ]; then echo "ok U $fid (keep): the migrate changed nothing of it (the definition's command as before, the script holds it encoded)"
        else echo "FAIL U $fid (keep): the migrate changed it: before [${KB[$fid]}] after [$ua], the script holds it $sc"; BAD=$((BAD+1)); fi
        continue ;;
      *) continue ;;
    esac
    jv=$(qu "select count(*) from pgvigil.job_versions v where v::text like '%$tok%'")
    js=$(qu "select count(*) from pgvigil.mssql_jobs j where j::text like '%$tok%'")
    jr=$(qu "select count(*) from pgvigil.mssql_job_runs r where r::text like '%$tok%'")
    grep -q "$tok" "$WORK/dump-u.sql" && DUMPLEFT="$DUMPLEFT $fid"
    if [ "$jv$js$jr" = "000" ]; then echo "ok U $fid ($cls): no secret left after the migrate (job_versions 0, mssql_jobs 0, mssql_job_runs 0)"
    else jc=$(qu "select 'definition ' || count(*) filter (where definition::text like '%$tok%') || ', script ' || count(*) filter (where script like '%$tok%') || ', changes ' || count(*) filter (where changes::text like '%$tok%') from pgvigil.job_versions")
      echo "FAIL U $fid ($cls): the secret left after the migrate: job_versions $jv ($jc), mssql_jobs $js, mssql_job_runs $jr"; BAD=$((BAD+1)); fi
    if [ "$cls" = mark ]; then
      # both builds stored the same mark: after the migrate the command reads as this build's own read of it
      ua=$(qu "select definition #>> '{steps,step 01,command}' from pgvigil.job_versions where job_name='pgvjm $fid $SUF' and version_no=1")
      ra=$(q "select definition #>> '{steps,step 01,command}' from pgvigil.job_versions where job_name='pgvjm $fid $SUF' and version_no=1")
      q1="'"; enc="@command = N'${ra//$q1/$q1$q1}'"
      sc=$(qu "select count(*) from pgvigil.job_versions where job_name='pgvjm $fid $SUF' and version_no=1 and position(\$e\$${enc}\$e\$ in script) > 0")
      if [ -n "$ra" ] && [ "$ua" = "$ra" ] && [ "$sc" = 1 ]; then echo "ok U $fid (mark): no text lost - the command after the migrate is this build's own read of it: $ua"
      else echo "FAIL U $fid (mark): text lost by the migrate: after [$ua], this build's own [$ra], the script holds it $sc"; BAD=$((BAD+1)); fi
    fi
  done < "$WORK/forms.txt"
  # pk1 / pk2 (pgvigil.jobs, job_runs): no key left, the text after the key kept
  pj=$(qu "select count(*) from pgvigil.jobs where command like '%S16pk%$SUF%'")
  pr=$(qu "select count(*) from pgvigil.job_runs where command like '%S16pk%$SUF%' or return_message like '%S16pk%$SUF%'")
  pk=$(qu "select count(*) from pgvigil.jobs where job_id = 9001 and position(\$e\$host=K16pk1$SUF', 'VACUUM')\$e\$ in command) > 0")
  pm=$(qu "select count(*) from pgvigil.job_runs where job_id = 9001 and return_message like '%<masked>%' and position(\$e\$', 'SELECT 1')\$e\$ in return_message) > 0")
  grep -q "S16pk[12]$SUF" "$WORK/dump-u.sql" && DUMPLEFT="$DUMPLEFT pk"
  if [ "$pj$pr" = "00" ] && [ "$pk$pm" = "11" ]; then echo "ok U pk1 / pk2 (pg_cron's jobs and runs): no key left, the text after it kept"
  else echo "FAIL U pk1 / pk2 (pg_cron's jobs and runs): keys left in jobs $pj, job_runs $pr; text after the key kept: jobs $pk, the run's output $pm"; BAD=$((BAD+1)); fi
  g1=$(qu "select count(*) from pgvigil.job_versions v where v::text like '%S16g1$SUF%'")
  g1m=$(qu "select count(*) from pgvigil.job_versions where script like '%<masked: an older build stored this command unmasked>%'")
  if [ "$g1" = 0 ] && [ "$g1m" -ge 1 ]; then echo "ok U G1 a form no rule reads, planted in a stored script: the guard replaced its literal whole ($g1m)"
  else echo "FAIL U G1 a form no rule reads, planted in a stored script: the secret in job_versions $g1, guarded literals $g1m"; BAD=$((BAD+1)); fi
  if [ -z "$DUMPLEFT" ]; then echo "ok U no form's secret anywhere in a dump of the whole repository after the migrate"
  else echo "FAIL U the dump of the whole repository after the migrate still holds the secret of:$DUMPLEFT"; BAD=$((BAD+1)); fi
  if [ -n "$V0" ] && [ "$V0" = "$V1" ]; then echo "ok U the migrate writes no version ($(printf '%s\n' "$V0" | wc -l) jobs)"
  else echo "FAIL U the migrate changed the version counts (before / after): [$V0] [$V1]"; BAD=$((BAD+1)); fi
  "$BIN" collect -config "$WORK/pgvigil-u.yaml" -once mssql_jobs -instance "$NS" >"$OUT" 2>&1 || { cat "$OUT"; fail "this build's first collect after the upgrade"; }
  V2=$(vc)
  "$BIN" collect -config "$WORK/pgvigil-u.yaml" -once mssql_jobs -instance "$NS" >"$OUT" 2>&1 || { cat "$OUT"; fail "this build's second collect"; }
  V3=$(vc)
  VV=$(python3 -I - "$V1" "$V2" "$V3" <<'PY'
import sys
c = [dict(l.rsplit(":", 1) for l in a.splitlines() if l) for a in sys.argv[1:4]]
more = [j for j in c[1] if int(c[1][j]) - int(c[0].get(j, 0)) > 1]
again = [j for j in c[2] if c[2][j] != c[1].get(j)]
once = sum(1 for j in c[1] if int(c[1][j]) - int(c[0].get(j, 0)) == 1)
print("ok" if not more and not again else "bad", once, "more:" + ",".join(more), "again:" + ",".join(again))
PY
)
  case $VV in
    ok*) echo "ok U the first read after the upgrade writes at most one version a job, the second none (jobs with one: ${VV#ok })" ;;
    *) echo "FAIL U versions after the upgrade: ${VV#bad }"; BAD=$((BAD+1)) ;;
  esac
  # the step's cost (the review, 8; a NOTE, not graded): mssql_job_runs grown to about 100,000 rows, nine in ten a
  # plain run's output, then 0272 run again (its record removed; the step changes nothing it already masked)
  qu "insert into pgvigil.mssql_job_runs select r.* from pgvigil.mssql_job_runs r cross join generate_series(1, greatest(1, 100000 / greatest(1, (select count(*) from pgvigil.mssql_job_runs))::int)) g" >/dev/null
  qu "update pgvigil.mssql_job_runs set message = 'Executed as user: sa. The step succeeded.', failed_message = null where random() < 0.9" >/dev/null
  NR=$(qu "select count(*) || ' rows, ' || count(*) filter (where message like '%<masked>%') || ' holding a mark' from pgvigil.mssql_job_runs")
  qu "delete from pgvigil.schema_version where version = '0272_job_text_masked_again.sql'" >/dev/null
  T0=$(date +%s%N)
  "$BIN" migrate -config "$WORK/pgvigil-u.yaml" >"$OUT" 2>&1 || { cat "$OUT"; fail "0272 again over the grown mssql_job_runs"; }
  echo "NOTE U the 0272 step over mssql_job_runs of $NR: $(( ($(date +%s%N) - T0) / 1000000 )) ms (load $(cut -d' ' -f1 /proc/loadavg))"
fi
if [ "$BAD" = 0 ]; then echo "PROOF OK"; else echo "PROOF FAILED: $BAD"; exit 1; fi
