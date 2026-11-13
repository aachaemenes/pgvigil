#!/usr/bin/env bash
# Proof of task 170 (migration 0106, internal/web/q_customreports.go and q_community.go, web/src/customreports.ts and
# community.ts): custom reports saved with a parameter, column formats and colour rules in folders, run on the
# repository and read-only on PostgreSQL and SQL Server instances, audited; the community tools on a SQL Server 2022
# with the First Responder Kit, Erik Darling's procedures and sp_WhoIsActive installed, and pgvigil's own PostgreSQL
# reads; the pages rendered in a headless Chromium with their colours, the Excel export and axe-core in both themes.
#
#   PGVIGIL_ADMIN_DSN       keyword-form connection to a PostgreSQL 14+ cluster as a superuser, no dbname. The proof
#                           makes a repository database, a target database and three logins named pgcr_*_<random>
#                           and drops them at the end (not the cluster-wide group roles pgvigil_*, which migrate makes).
#   PGVIGIL_COMMUNITY_DIR   a folder with the community scripts to install on the SQL Server: frk-install-all.sql
#                           (the First Responder Kit's Install-All-Scripts.sql), darlingdata.sql (DarlingData's
#                           Install-All/DarlingData.sql) and sp_WhoIsActive.sql. This script fetches nothing. A file
#                           missing: its tools' runs are NOT PROVEN, said so.
#   PGVIGIL_BIN             a binary with the wiring (the routes /api/customreports and /api/community); default: built
#                           here. The web bundle must carry the pages (internal/web/dist/app.js names 'Custom reports'):
#                           the page part U fails without.
#   PGVIGIL_SKIP_MSSQL=1    no SQL Server part (M, G, the SQL Server pages): printed NOT PROVEN ON SQL SERVER.
#   PGVIGIL_SKIP_PAGES=1    no page part (U): printed NOT PROVEN (PAGES).
#   PGVIGIL_PYLIB           a folder holding openpyxl when python3 has none (U's workbook open); none = said.
#   Needs: psql, curl, python3, ss, go (without PGVIGIL_BIN); docker (M, G); chromium, node, npm (U, axe-core 4.14.0).
#
# What it makes on SQL Server (a container of its own, removed at the end with its volume; a throwaway sa password made
# here, passed by name): the community scripts in master, the database pgcr_seed with the table t (2 rows) and the
# procedure dbo.pgcr_proc, the login pgcr_reader (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE, EXECUTE
# on the community procedures and pgcr_proc, db_datareader in msdb and pgcr_seed: docs/sqlserver.md's read login plus the
# grants docs/customreports.md names: EXECUTE on every procedure the kits installed in master). Instances: pgcr-a (the monitoring login pgcr_mon_<n>, pg_monitor, SELECT on the
# target's t), pgcr-su (the superuser), pgcr-long-instance-name-<n> (pg_monitor again: its long name is the colour
# rule's crit row), mssql pgcr-msr (the reader) and pgcr-msa (sa); tags env:pgcr on pgcr-a and pgcr-su.
#
# Expected (written before the first run):
#  R. roles: the collector login may EXECUTE import_custom_report and import_custom_report_run; an INSERT into
#     custom_reports or custom_report_log by it is refused (permission denied); the reader login reads all three tables.
#  B. the door: POST /api/customreports without a session 401, without X-Pgvigil 403; the -no-login serve answers GET
#     state.enabled false with '-no-login' in the reason and POST 403; the log is unchanged by all three.
#  V. validation (400, nothing logged): a parameter named 1x, a parameter named from, a rule condition zz, a rule status
#     blue, between without a second value, a procedure named a;b, timeout_secs 0, an unknown op. The import's
#     refusals (409, one 'refused' log row each): the same name in another case, an edit on a stale version ('changed
#     by'), folder_delete of a folder holding a report.
#  S. the store: report 'pgcr names' (store, sql: name and length(name) AS name_len of the active instances in
#     @instance_ids with length(name) >= @min_len; min_len int default 1; rules name_len gt 20 -> crit, then all -> ok;
#     format of name_len int, label 'name length'). target fleet: done, its rows equal a hand read of pgvigil.instances
#     (name, length) ordered by name, cell by cell; target instance pgcr-a: 1 row; min_len 1000: 0 rows. The serve on
#     the superuser repository login: refused, 'superuser'. A store report that INSERTs: failed, 'read-only
#     transaction', the folder table unchanged; 'select 1; select 2': failed, 'multiple commands'; 'select
#     pg_advisory_lock(424242)': done, and no advisory lock 424242 held after it (the run's connection is closed).
#     Each run wrote one log row op run, instance store, its statement and outcome.
#  P. PostgreSQL instances: report 'pgcr t' (postgres: count(*) AS n FROM t WHERE n >= @min_n) on pgcr-a with min_n 2:
#     done, n = 1 (t holds 1 and 2); on pgcr-su: refused, 'superuser'; on the tag env:pgcr: two runs, done and refused,
#     two log rows. 'insert into t values (9)' on pgcr-a: failed, 'read-only transaction', t still 2 rows. A function
#     report public.pgcr_fn with k = 7: one row k 7, sq 49. [review 1 fold] min_n 'abc': 400, nothing sent, one log row
#     run / refused naming the parameter.
#  F. folders: folder_add Ops; a report saved into Ops/Daily: the folders read lists Ops and Ops/Daily; move to Ops: its
#     folder Ops; folder_rename Ops -> Team/Ops: the report in Team/Ops and the folders Team, Team/Ops, Team/Ops/Daily;
#     folder_delete Team: refused (it holds a report) with one 'refused' log row; the report moved to the top,
#     folder_delete Team: done, no folder under Team left. Folders a_b, axb and axb/x: renaming a_b to c_d leaves axb and
#     axb/x as they are (the folders read: axb, axb/x, c_d). [review 1 fold] Up/B/B/x renamed up: Up/B -> Up leaves Up,
#     Up/B, Up/B/x.
#  M. SQL Server 2022 (community): the instance's tools: 14 (13 procedures and Glenn Berry's), every procedure installed
#     in master, enabled; in tempdb: every procedure not installed, each with its URL. sp_WhoIsActive's form: @filter in
#     the parameters with a help text, @destination_table, @return_schema, @schema and @help left out. Runs, each one log
#     row: sp_WhoIsActive (show_own_spid 1): done, one set, at least 1 row; sp_Blitz: done, at least 1 set with rows;
#     sp_BlitzFirst (Seconds 1): done, at least 1 set; sp_PressureDetector: done, at least 1 set; sp_BlitzIndex
#     (DatabaseName pgcr_seed): done, at least 1 set. Recorded, not graded (their outcome depends on the server's
#     contents and the reader's rights): sp_BlitzCache, sp_BlitzWho, sp_BlitzLock, sp_QuickieStore, sp_HealthParser,
#     sp_HumanEventsBlockViewer, sp_LogHunter, sp_IndexCleanup - each answers 200 with an outcome and a log row.
#     sp_BlitzFirst with OutputDatabaseName: 400, nothing run, one log row community_run / refused [review 1 fold];
#     sp_BlitzFirst's form leaves out @OutputDatabaseName and @LogMessage, sp_BlitzCache's @AI and @AIURL. sp_Blitz
#     looked for in tempdb: params 404 and the run
#     refused, both naming the First Responder Kit's URL. On pgcr-msa (sa): the tools page disabled with 'sysadmin',
#     a run refused 'sysadmin'.
#     Custom reports on SQL Server: 'pgcr dbs' (name, database_id of sys.databases with database_id <= @n, n 4) on
#     pgcr-msr: done, rows equal a hand read through sqlcmd as pgcr_reader; 'insert into pgcr_seed.dbo.t' on pgcr-msr:
#     failed with 'permission was denied', t still 2 rows; on pgcr-msa: refused 'sysadmin'; procedure report
#     pgcr_seed.dbo.pgcr_proc with k 7: one row 7, 49.
#  G. Glenn Berry's format (a script written here, pgvigil's own text, with a Windows-1252 byte in a comment): parse ->
#     3 queries (Version Info, Database List, Write Try), query 2's text without its GO line; query 2 run on pgcr-msr:
#     done, as many rows as sys.databases has; query 3 (an INSERT): failed, 'permission was denied', t still 2 rows; a
#     file without markers: 400.
#  Q. PostgreSQL community reads on pgcr-a: 10 tools, enabled; pg_running: done; pg_settings_changed: done, at least 1
#     row; pg_table_sizes on the target database: a row for t; any read on pgcr-su: refused, 'superuser'.
#  U. the pages (headless Chromium, the session cookie set, both themes): #/customreports lists the folders and the
#     report links; the store report's page runs on open: its grid has one row per active instance, the long name's
#     name_len cell is a status crit cell and every other one status ok; 'Export .xlsx' downloads a workbook whose
#     styles carry the crit fill FFAB1F26 and the ok fill FF006638, the long row's name length cell styled with the
#     crit fill and the others with the ok fill (openpyxl opens it where it is installed); axe-core (WCAG 2.1 A and
#     AA) finds 0 violations on the tree, the report page with its result, the editor, and the community page of
#     pgcr-msr with sp_WhoIsActive's form open and of pgcr-a, light and dark. [B3] On pgcr-msa's community page (sa):
#     the box 'Before a tool can run on pgcr-msa-<n>:' names sysadmin, every tool button is disabled with 'sysadmin'
#     in its hover text, and a disabled link button is drawn off (no underline, not the accent colour: the wiring's
#     app.css line); on pgcr-msr's: the column 'before it runs', sp_WhoIsActive 'ready'.
#  N. [B3] before the click (GET /api/community says what a tool lacks here and how to get it; nothing is run for it):
#     pgcr-msr: no instance need, enabled; sp_LogHunter one hard need naming xp_readerrorlog with 'GRANT EXECUTE ON
#     sys.xp_readerrorlog TO [pgcr_reader] in master'; sp_HumanEventsBlockViewer one soft need naming 'blocked process
#     threshold'; no other tool a need. sp_LogHunter run as it is: 200, outcome refused, 'sp_LogHunter refused: Current
#     user does not have EXECUTE permission on xp_readerrorlog' (the procedure's own RAISERROR, not 'failed'); the grant
#     made: its need gone and its run done. sp_HumanEventsBlockViewer with @session_name system_health: done. pgcr-msa
#     (sa): enabled false, one hard instance need naming sysadmin with 'without sysadmin'. The -no-login serve on
#     pgcr-msr: a hard instance need naming -no-login with 'pgvigil user add'. pgcr-a: Top statements one hard need
#     naming the pg_stat_statements extension in the target database with CREATE EXTENSION; the extension created
#     there: the need gone and Top statements done. pgcr-su: enabled false, a hard instance need naming superuser.
#  A. the audit: the log's run rows (run, community_run, community_help) = the runs this proof made.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
: "${PGVIGIL_ADMIN_DSN:?PGVIGIL_ADMIN_DSN (a superuser, keyword form) is required}"
N=$RANDOM$RANDOM
REPO=pgcr_repo_$N; TGT=pgcr_tgt_$N; COL=pgcr_col_$N; RDR=pgcr_rdr_$N; MON=pgcr_mon_$N
PW=p$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
UIUSER=pgcrui; UIPW=u$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
INSTA=pgcr-a-$N; INSTS=pgcr-su-$N; INSTL=pgcr-long-instance-name-$N; MSR=pgcr-msr-$N; MSA=pgcr-msa-$N; MSN=pgcr-msn-$N; INSTD=pgcr-down-$N
CT=pgcr-mssql-$N
WORK=$(mktemp -d)
SRV=""; SRV2=""; SRV3=""; SRV4=""; CHR=""; MADE_CT=""
# the runs this proof makes, one line each: a counter in a file (run and crun are called inside $(...), a subshell)
tick() { echo r >> "$WORK/runs"; }
nruns() { [[ -f "$WORK/runs" ]] && wc -l < "$WORK/runs" | tr -d ' ' || echo 0; }
NOTPROVEN=()
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  for p in "$SRV" "$SRV2" "$SRV3" "$SRV4" "$CHR"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -n "$MADE_CT" ]] && docker rm -f -v "$CT" >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" \
    -c "drop database if exists $TGT with (force)" -c "drop role if exists $COL" -c "drop role if exists $RDR" \
    -c "drop role if exists $MON" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in psql curl python3 ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}
echo "pgcr proof $N: repository $REPO, target $TGT, container $CT"

# ---- the binary ----------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$(realpath "$PGVIGIL_BIN"); else
  command -v go >/dev/null || fail "go is not on this machine (or give PGVIGIL_BIN)"
  BIN=$WORK/pgvigil; CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi

# ---- the repository, the target, the logins ------------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" -c "create database $TGT" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export TGT_SU="$PGVIGIL_ADMIN_DSN dbname=$TGT"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
tq() { psql "$TGT_SU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
tq "create table t (n int); insert into t values (1), (2);
    create function pgcr_fn(k int) returns table (k int, sq int) language sql as \$\$ select k, k * k \$\$;"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create role $MON login password '$PW' in role pg_monitor" >/dev/null
tq "grant select on t to $MON"
as_dsn() { echo "$PGVIGIL_ADMIN_DSN dbname=$1 user=$2 password=$PW"; }   # the admin's own route to the server, as another login
export TGT_MON; TGT_MON=$(as_dsn "$TGT" "$MON")
export TGT_DOWN; TGT_DOWN="host=127.0.0.1 port=$(freeport) dbname=postgres user=$MON password=$PW connect_timeout=2"   # nothing listens there

SKIP_MSSQL=${PGVIGIL_SKIP_MSSQL:-}
if [[ -z "$SKIP_MSSQL" ]] && ! command -v docker >/dev/null; then SKIP_MSSQL=1; NOTPROVEN+=("SQL Server: docker is not on this machine"); fi
CDIR=${PGVIGIL_COMMUNITY_DIR:-}
mssql_cfg=""
if [[ -z "$SKIP_MSSQL" ]]; then
  echo "--- the SQL Server 2022 container"
  MSSQL_SA_PASSWORD="Pg$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"; export MSSQL_SA_PASSWORD; export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  MPORT=$(freeport); ADDR=127.0.0.1:$MPORT
  MADE_CT=1
  docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MPORT:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "docker run of the SQL Server container"
  sq() {
    local o
    o=$(docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U "${3:-sa}" -d "${2:-master}" -Q "SET NOCOUNT ON; $1" 2>&1) || { printf 'sqlcmd failed: %s\n' "$o" >&2; return 1; }
    [ -z "$o" ] || printf '%s\n' "$o"
  }
  sqf() {   # a script file as sa
    local o
    o=$(docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -d master -i /dev/stdin < "$1" 2>&1) || { printf 'sqlcmd failed on %s: %s\n' "$1" "$(printf '%s' "$o" | tail -5)" >&2; return 1; }
  }
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server in $CT does not answer"
  ok "SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")"
  INSTALLED=()
  for f in frk-install-all.sql darlingdata.sql sp_WhoIsActive.sql; do
    if [[ -n "$CDIR" && -r "$CDIR/$f" ]]; then sqf "$CDIR/$f" || fail "M: $f did not install"; INSTALLED+=("$f"); else NOTPROVEN+=("M: $f was not given (PGVIGIL_COMMUNITY_DIR): its tools' runs"); fi
  done
  RPW="Rd$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!b2"
  sq "CREATE LOGIN pgcr_reader WITH PASSWORD = '$RPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgcr_reader; GRANT VIEW ANY DEFINITION TO pgcr_reader; GRANT CONNECT ANY DATABASE TO pgcr_reader;" >/dev/null
  sq "CREATE DATABASE pgcr_seed;" >/dev/null
  sq "CREATE TABLE dbo.t (n int); INSERT dbo.t VALUES (1), (2); CREATE USER pgcr_reader FOR LOGIN pgcr_reader; ALTER ROLE db_datareader ADD MEMBER pgcr_reader;" pgcr_seed >/dev/null
  sq "EXEC('CREATE PROCEDURE dbo.pgcr_proc @k int AS SELECT @k AS k, @k * @k AS sq'); GRANT EXECUTE ON dbo.pgcr_proc TO pgcr_reader;" pgcr_seed >/dev/null
  sq "CREATE USER pgcr_reader FOR LOGIN pgcr_reader;" >/dev/null
  sq "CREATE USER pgcr_reader FOR LOGIN pgcr_reader; ALTER ROLE db_datareader ADD MEMBER pgcr_reader;" msdb >/dev/null   # docs/sqlserver.md's read login reads msdb
  # EXECUTE on every procedure the kits installed, not only the ones pgvigil lists: sp_Blitz runs sp_BlitzBackups
  sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'GRANT EXECUTE ON dbo.' + QUOTENAME(name) + N' TO pgcr_reader; ' FROM sys.procedures WHERE is_ms_shipped = 0 AND schema_id = 1; EXEC (@s);" >/dev/null
  # the narrow login (B3): the read login's server rights but no CONNECT ANY DATABASE, a user in master only, no EXECUTE
  NPW="Nr$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!c3"
  sq "CREATE LOGIN pgcr_narrow WITH PASSWORD = '$NPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgcr_narrow; GRANT VIEW ANY DEFINITION TO pgcr_narrow;" >/dev/null
  sq "CREATE USER pgcr_narrow FOR LOGIN pgcr_narrow;" >/dev/null
  export MS_N="sqlserver://pgcr_narrow:$NPW@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
  export MS_R="sqlserver://pgcr_reader:$RPW@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
  export MS_SA="sqlserver://sa:$MSSQL_SA_PASSWORD@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
  mssql_cfg=$(printf '  - name: %s\n    engine: sqlserver\n    dsn: env:MS_R\n  - name: %s\n    engine: sqlserver\n    dsn: env:MS_SA\n  - name: %s\n    engine: sqlserver\n    dsn: env:MS_N\n' "$MSR" "$MSA" "$MSN")
else
  NOTPROVEN+=("NOT PROVEN ON SQL SERVER (PGVIGIL_SKIP_MSSQL or no docker): parts M, G and the SQL Server pages")
fi

cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $INSTA
    dsn: env:TGT_MON
    tags: [env:pgcr]
  - name: $INSTS
    dsn: env:TGT_SU
    tags: [env:pgcr]
  - name: $INSTL
    dsn: env:TGT_MON
  - name: $INSTD
    dsn: env:TGT_DOWN
$mssql_cfg
EOF
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" >"$WORK/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/migrate.log")"
[[ $(q "select to_regclass('pgvigil.custom_reports') is not null and to_regprocedure('pgvigil.import_custom_report_run(timestamptz, jsonb)') is not null") == t ]] || fail "0106 is not applied"
ok "migrate applied 0106"

# ---- R: the roles --------------------------------------------------------------------------------------------------
psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create role $COL login password '$PW' in role pgvigil_collector" \
  -c "create role $RDR login password '$PW' in role pgvigil_reader, pgvigil_auth" >/dev/null
as() { local who=$1; shift; psql "$(as_dsn "$REPO" "$who")" -XAtq "$@" 2>&1; }
[[ $(as "$COL" -c "select has_function_privilege('pgvigil.import_custom_report(timestamptz, jsonb)', 'EXECUTE') and has_function_privilege('pgvigil.import_custom_report_run(timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "R: the collector may not call the imports"
out=$(as "$COL" -c "insert into pgvigil.custom_reports (name, engine, kind, body, created_by, created_at, updated_by, updated_at) values ('x','store','sql','select 1','x',now(),'x',now())" || true)
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into custom_reports: $out"
out=$(as "$COL" -c "insert into pgvigil.custom_report_log (at, ui_user, op, outcome) values (now(), 'x', 'run', 'done')" || true)
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into custom_report_log: $out"
[[ $(as "$RDR" -c "select (select count(*) from pgvigil.custom_reports) + (select count(*) from pgvigil.custom_report_log) + (select count(*) from pgvigil.custom_report_folders)") == 0 ]] || fail "R: the reader cannot read the three tables"
ok "R: the collector writes only through the imports; the reader reads"

# ---- the instances, serve --------------------------------------------------------------------------------------------
"$BIN" collect -config "$CFG" -once activity >"$WORK/collect.log" 2>&1 || true
[[ -z "$SKIP_MSSQL" ]] && { "$BIN" collect -config "$CFG" -once mssql_instance >>"$WORK/collect.log" 2>&1 || true; }
id_of() { q "select instance_id from pgvigil.instances where name = '$1'"; }
AID=$(id_of "$INSTA"); SID=$(id_of "$INSTS"); LID=$(id_of "$INSTL")
[[ -n $AID && -n $SID && -n $LID ]] || fail "the PostgreSQL instances are not registered: $(tail -5 "$WORK/collect.log")"
if [[ -z "$SKIP_MSSQL" ]]; then MRID=$(id_of "$MSR"); MAID=$(id_of "$MSA"); MNID=$(id_of "$MSN"); [[ -n $MRID && -n $MAID && -n $MNID ]] || fail "the SQL Server instances are not registered: $(tail -5 "$WORK/collect.log")"; fi
DID=$(id_of "$INSTD")
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" $UIUSER >/dev/null 2>&1 || fail "user add"
export UI_DSN; UI_DSN=$(as_dsn "$REPO" "$RDR")
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" >"$WORK/serve.log" 2>&1 & SRV=$!
PORT2=$(freeport); U2="http://127.0.0.1:$PORT2"
"$BIN" serve -config "$CFG" -dsn env:UI_DSN -listen "127.0.0.1:$PORT2" -no-login >"$WORK/serve2.log" 2>&1 & SRV2=$!
PORT3=$(freeport); U3="http://127.0.0.1:$PORT3"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT3" >"$WORK/serve3.log" 2>&1 & SRV3=$!   # the superuser repository login
for pair in "$SRV $U serve.log" "$SRV2 $U2 serve2.log" "$SRV3 $U3 serve3.log"; do
  read -r pid url log <<<"$pair"
  for n in $(seq 1 60); do
    curl -sf -o /dev/null "$url/" && break
    kill -0 "$pid" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/$log")"
    [[ $n == 60 ]] && fail "serve did not answer on $url"; sleep 0.5
  done
done
JAR=$WORK/jar; JAR3=$WORK/jar3
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
for pair in "$U $JAR" "$U3 $JAR3"; do read -r url jar <<<"$pair"
  curl -s -c "$jar" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$url/api/login" >/dev/null
  [[ -n $(awk '$6 == "pgvigil_session" {print $7}' "$jar") ]] || fail "no session cookie from $url"
done
post() { code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$U/api/$1"; }
post3() { code -b "$JAR3" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$U3/api/$1"; }
getc() { code -b "$JAR" "$U/api/$1"; }
js() { python3 -c "import json,sys; d=json.load(open('$WORK/body')); print($1)"; }
logn() { q "select count(*) from pgvigil.custom_report_log"; }
runlog() { q "select count(*) from pgvigil.custom_report_log where op in ('run', 'community_run', 'community_help')"; }
[[ $(getc customreports) == 200 ]] || fail "GET /api/customreports: $(cat "$WORK/body") (the serve must carry the wiring)"

# ---- B: the door -----------------------------------------------------------------------------------------------------
L0=$(logn)
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"folder_add","folder":"X"}' "$U/api/customreports") == 401 ]] || fail "B: no session: $(cat "$WORK/body")"
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d '{"op":"folder_add","folder":"X"}' "$U/api/customreports") == 403 ]] || fail "B: no header: $(cat "$WORK/body")"
[[ $(code "$U2/api/customreports") == 200 ]] && [[ $(js "d['state']['enabled']") == False && $(js "d['state']['reason']") == *-no-login* ]] || fail "B: the -no-login serve's state: $(cat "$WORK/body")"
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"folder_add","folder":"X"}' "$U2/api/customreports") == 403 ]] || fail "B: the -no-login serve took a write"
[[ $(logn) == "$L0" ]] || fail "B: the log moved"
ok "B: 401 without a session, 403 without the header, the -no-login serve off; nothing logged"

# ---- V: validation ---------------------------------------------------------------------------------------------------
add() { python3 - "$@" <<'PY'
import json, sys
d = {"op": "add", "engine": "store", "kind": "sql", "body": "select 1", "timeout_secs": 30, "max_rows": 5000, "params": [], "columns": [], "rules": []}
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1)
    d[k] = json.loads(v) if v[:1] in "[{0123456789" or v in ("true", "false", "null") else v
print(json.dumps(d))
PY
}
for bad in 'params=[{"name":"1x","type":"int"}]' 'params=[{"name":"from","type":"int"}]' 'rules=[{"set":0,"column":"a","cond":"zz","value1":"1","status":"ok"}]' \
           'rules=[{"set":0,"column":"a","cond":"gt","value1":"1","status":"blue"}]' 'rules=[{"set":0,"column":"a","cond":"between","value1":"1","status":"ok"}]' \
           'kind=procedure' 'timeout_secs=0' 'op=frob'; do
  body=$(add "name=v-$N" "$bad"); [[ $bad == kind=procedure ]] && body=$(add "name=v-$N" kind=procedure 'body=a;b')
  [[ $(post customreports "$body") == 400 ]] || fail "V: $bad was not refused: $(cat "$WORK/body")"
done
[[ $(logn) == "$L0" ]] || fail "V: a refused definition was logged"
ok "V: eight bad definitions refused (400), nothing logged"

# ---- S: the store ----------------------------------------------------------------------------------------------------
SBODY='SELECT name, length(name) AS name_len FROM pgvigil.instances WHERE is_active AND instance_id = ANY (@instance_ids) AND length(name) >= @min_len ORDER BY name'
[[ $(post customreports "$(add "name=pgcr names" "body=$SBODY" 'params=[{"name":"min_len","type":"int","default":"1","label":"name at least"}]' \
     'columns=[{"set":0,"column":"name_len","label":"name length","format":"int"}]' \
     'rules=[{"set":0,"column":"name_len","cond":"gt","value1":"20","status":"crit"},{"set":0,"column":"name_len","cond":"all","status":"ok"}]')") == 200 ]] || fail "S: add: $(cat "$WORK/body")"
SREP=$(js "d['report_id']")
L1=$(logn)
[[ $(post customreports "$(add "name=PGCR NAMES")") == 409 && $(js "d['detail']") == *"exists already"* ]] || fail "S: the same name in another case: $(cat "$WORK/body")"
[[ $(post customreports "$(add op=edit "report_id=$SREP" version=7 "name=pgcr names" "body=$SBODY")") == 409 && $(js "d['detail']") == *"changed by"* ]] || fail "S: a stale edit: $(cat "$WORK/body")"
[[ $(q "select count(*) from pgvigil.custom_report_log where outcome = 'refused'") == 2 && $(logn) == $((L1 + 2)) ]] || fail "S: the two refusals are not two refused log rows"
run() { tick; post customreports/run "$1"; }
[[ $(run "{\"report_id\":$SREP,\"target\":\"fleet\",\"params\":{\"min_len\":\"1\"}}") == 200 ]] || fail "S: run: $(cat "$WORK/body")"
[[ $(js "d['runs'][0]['outcome']") == done ]] || fail "S: the store run: $(cat "$WORK/body")"
got=$(js "'\n'.join(str(r[0])+'|'+str(r[1]) for r in d['runs'][0]['sets'][0]['rows'])")
want=$(q "select name || '|' || length(name) from pgvigil.instances where is_active order by name")
[[ "$got" == "$want" ]] || fail "S: the rows are not the hand read: got [$got] want [$want]"
[[ $(run "{\"report_id\":$SREP,\"target\":\"instance\",\"instance_id\":$AID}") == 200 && $(js "len(d['runs'][0]['sets'][0]['rows'])") == 1 ]] || fail "S: one instance: $(cat "$WORK/body")"
[[ $(run "{\"report_id\":$SREP,\"target\":\"fleet\",\"params\":{\"min_len\":\"1000\"}}") == 200 && $(js "len(d['runs'][0]['sets'][0]['rows'])") == 0 ]] || fail "S: min_len 1000: $(cat "$WORK/body")"
tick; [[ $(post3 customreports/run "{\"report_id\":$SREP,\"target\":\"fleet\"}") == 200 && $(js "d['runs'][0]['outcome']") == refused && $(js "d['runs'][0]['error']") == *superuser* ]] || fail "S: the superuser serve: $(cat "$WORK/body")"
F0=$(q "select count(*) from pgvigil.custom_report_folders")
for pair in "pgcr write|insert into pgvigil.custom_report_folders values ('zz', 'x', now())|failed|read-only transaction" \
            "pgcr two|select 1; select 2|failed|multiple commands" "pgcr lock|select pg_advisory_lock(424242)|done|"; do
  IFS='|' read -r nm sqlb outc words <<<"$pair"
  [[ $(post customreports "$(add "name=$nm" "body=$sqlb")") == 200 ]] || fail "S: add $nm: $(cat "$WORK/body")"
  rid=$(js "d['report_id']")
  [[ $(run "{\"report_id\":$rid,\"target\":\"fleet\"}") == 200 ]] || fail "S: run $nm: $(cat "$WORK/body")"
  [[ $(js "d['runs'][0]['outcome']") == "$outc" && $(js "d['runs'][0].get('error','')") == *"$words"* ]] || fail "S: $nm: $(cat "$WORK/body")"
done
[[ $(q "select count(*) from pgvigil.custom_report_folders") == "$F0" ]] || fail "S: the write reached the folders"
[[ $(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "select count(*) from pg_locks where locktype = 'advisory' and objid = 424242") == 0 ]] || fail "S: the advisory lock outlived its run"
[[ $(q "select count(*) from pgvigil.custom_report_log where op = 'run' and instance = 'store' and statement is not null") == "$(nruns)" ]] || fail "S: not one store log row per run"
ok "S: the store report equals the hand read; one instance; no row; superuser refused; write, two statements refused; the lock gone; $(nruns) log rows"

# ---- P: PostgreSQL instances -----------------------------------------------------------------------------------------
[[ $(post customreports "$(add "name=pgcr t" engine=postgres 'body=select count(*) as n from t where n >= @min_n' 'params=[{"name":"min_n","type":"int"}]')") == 200 ]] || fail "P: add: $(cat "$WORK/body")"
PREP=$(js "d['report_id']")
[[ $(run "{\"report_id\":$PREP,\"target\":\"instance\",\"instance_id\":$AID,\"params\":{\"min_n\":\"2\"}}") == 200 && $(js "d['runs'][0]['outcome']") == done && $(js "d['runs'][0]['sets'][0]['rows'][0][0]") == 1 ]] || fail "P: on $INSTA: $(cat "$WORK/body")"
[[ $(run "{\"report_id\":$PREP,\"target\":\"instance\",\"instance_id\":$SID}") == 200 && $(js "d['runs'][0]['outcome']") == refused && $(js "d['runs'][0]['error']") == *superuser* ]] || fail "P: on the superuser: $(cat "$WORK/body")"
R0=$(runlog)
tick; [[ $(post customreports/run "{\"report_id\":$PREP,\"target\":\"tag\",\"tag\":\"env:pgcr\"}") == 200 ]] || fail "P: the tag: $(cat "$WORK/body")"
[[ $(js "sorted(r['outcome'] for r in d['runs'])") == "['done', 'refused']" && $(runlog) == $((R0 + 2)) ]] || fail "P: the tag's runs: $(cat "$WORK/body")"
tick   # the tag ran twice: two log rows
tick; [[ $(post customreports/run "{\"report_id\":$PREP,\"target\":\"instance\",\"instance_id\":$AID,\"params\":{\"min_n\":\"abc\"}}") == 400 ]] || fail "P: min_n abc: $(cat "$WORK/body")"
[[ $(q "select count(*) from pgvigil.custom_report_log where op = 'run' and outcome = 'refused' and detail like '%min_n%'") == 1 ]] || fail "P: the refused parameter is not one refused log row"
[[ $(post customreports "$(add "name=pgcr ins" engine=postgres 'body=insert into t values (9)')") == 200 ]] || fail "P: add the write"
rid=$(js "d['report_id']")
[[ $(run "{\"report_id\":$rid,\"target\":\"instance\",\"instance_id\":$AID}") == 200 && $(js "d['runs'][0]['outcome']") == failed && $(js "d['runs'][0]['error']") == *"read-only transaction"* ]] || fail "P: the write: $(cat "$WORK/body")"
[[ $(tq "select count(*) from t") == 2 ]] || fail "P: t changed"
[[ $(post customreports "$(add "name=pgcr fn" engine=postgres kind=procedure body=public.pgcr_fn 'params=[{"name":"k","type":"int"}]')") == 200 ]] || fail "P: add the function report: $(cat "$WORK/body")"
rid=$(js "d['report_id']")
[[ $(run "{\"report_id\":$rid,\"target\":\"instance\",\"instance_id\":$AID,\"params\":{\"k\":\"7\"}}") == 200 && $(js "d['runs'][0]['sets'][0]['rows']") == "[[7, 49]]" ]] || fail "P: the function report: $(cat "$WORK/body")"
ok "P: n = 1 on $INSTA, the superuser refused, the tag two runs, the write refused (t 2 rows), the function 7 49"

# ---- F: folders ------------------------------------------------------------------------------------------------------
folders() { getc customreports >/dev/null; js "','.join(r[0] for r in d['folders']['rows'])"; }
folder_of() { getc "customreports?report=$1" >/dev/null; js "d['report']['rows'][0][3]"; }
[[ $(post customreports '{"op":"folder_add","folder":"Ops"}') == 200 ]] || fail "F: folder_add: $(cat "$WORK/body")"
[[ $(post customreports "$(add "name=pgcr folder" folder=Ops/Daily)") == 200 ]] || fail "F: add into Ops/Daily: $(cat "$WORK/body")"
FREP=$(js "d['report_id']")
[[ $(folders) == "Ops,Ops/Daily" ]] || fail "F: the folders after the add: $(folders)"
[[ $(post customreports "{\"op\":\"move\",\"report_id\":$FREP,\"folder\":\"Ops\"}") == 200 && $(folder_of "$FREP") == Ops ]] || fail "F: move to Ops"
[[ $(post customreports '{"op":"folder_rename","folder":"Ops","new_folder":"Team/Ops"}') == 200 ]] || fail "F: rename: $(cat "$WORK/body")"
[[ $(folder_of "$FREP") == Team/Ops && $(folders) == "Team,Team/Ops,Team/Ops/Daily" ]] || fail "F: after the rename: $(folders) / $(folder_of "$FREP")"
[[ $(post customreports '{"op":"folder_delete","folder":"Team"}') == 409 && $(js "d['detail']") == *"holds reports"* ]] || fail "F: delete of a full folder: $(cat "$WORK/body")"
[[ $(q "select count(*) from pgvigil.custom_report_log where op = 'folder_delete' and outcome = 'refused'") == 1 ]] || fail "F: the refused folder_delete is not one refused log row"
[[ $(post customreports "{\"op\":\"move\",\"report_id\":$FREP,\"folder\":\"\"}") == 200 && $(post customreports '{"op":"folder_delete","folder":"Team"}') == 200 ]] || fail "F: empty then delete: $(cat "$WORK/body")"
[[ $(q "select count(*) from pgvigil.custom_report_folders where folder = 'Team' or folder like 'Team/%'") == 0 ]] || fail "F: a folder under Team is left"
post customreports '{"op":"folder_add","folder":"a_b"}' >/dev/null; post customreports '{"op":"folder_add","folder":"axb/x"}' >/dev/null
[[ $(post customreports '{"op":"folder_rename","folder":"a_b","new_folder":"c_d"}') == 200 && $(folders) == "axb,axb/x,c_d" ]] || fail "F: a_b, axb and axb/x: $(folders)"
post customreports '{"op":"folder_add","folder":"Up/B/B/x"}' >/dev/null
[[ $(post customreports '{"op":"folder_rename","folder":"Up/B","new_folder":"Up"}') == 200 ]] || fail "F: Up/B renamed up: $(cat "$WORK/body")"
[[ $(q "select string_agg(folder, ',' order by folder) from pgvigil.custom_report_folders where folder = 'Up' or folder like 'Up/%'") == "Up,Up/B,Up/B/x" ]] || fail "F: after Up/B -> Up: $(q "select string_agg(folder, ',' order by folder) from pgvigil.custom_report_folders where folder like 'Up%'")"
ok "F: add, move, rename with the subfolder, a full folder kept (refused, logged), the empty one deleted; a_b renamed alone; Up/B renamed up keeps its children"

# ---- M and G: SQL Server -----------------------------------------------------------------------------------------------
crun() { tick; post community/run "$1"; }
if [[ -z "$SKIP_MSSQL" ]]; then
  [[ $(getc "community?instance=$MRID") == 200 ]] || fail "M: GET community: $(cat "$WORK/body")"
  [[ $(js "d['enabled']") == True && $(js "len(d['tools'])") == 14 ]] || fail "M: the tools of $MSR: $(cat "$WORK/body")"
  if [[ ${#INSTALLED[@]} == 3 ]]; then
    [[ $(js "sum(1 for t in d['tools'] if t['kind']=='proc' and t['installed'])") == 13 ]] || fail "M: not every procedure installed: $(js "[t['name'] for t in d['tools'] if t['kind']=='proc' and not t['installed']]")"
  fi
  [[ $(getc "community?instance=$MRID&database=tempdb") == 200 && $(js "sum(1 for t in d['tools'] if t['kind']=='proc' and t['installed'] is False and t['url'])") == 13 ]] || fail "M: tempdb: $(cat "$WORK/body")"
  ok "M: 14 tools on $MSR, the procedures installed in master; none in tempdb, each with its URL"
  have() { for f in "${INSTALLED[@]}"; do [[ $f == "$1" ]] && return 0; done; return 1; }
  if have sp_WhoIsActive.sql; then
    tick; [[ $(post community/params "{\"instance_id\":$MRID,\"tool\":\"sp_WhoIsActive\"}") == 200 ]] || fail "M: the form: $(cat "$WORK/body")"
    [[ $(js "any(p['name'].lower()=='@filter' and p.get('help') for p in d['params'])") == True ]] || fail "M: @filter or its help missing: $(js "d['params'][:3]")"
    for p in @destination_table @return_schema @schema @help; do [[ $(js "'$p' in [x.lower() for x in d['left_out']]") == True ]] || fail "M: $p is not left out: $(js "d['left_out']")"; done
    [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"@show_own_spid\":\"1\"}}") == 200 && $(js "d['runs'][0]['outcome']") == done && $(js "len(d['runs'][0]['sets'][0]['rows']) >= 1") == True ]] || fail "M: sp_WhoIsActive: $(cat "$WORK/body" | head -c 600)"
    ok "M: sp_WhoIsActive's form (help, four left out) and a run with its own session"
  fi
  if have frk-install-all.sql; then
    for spec in 'sp_Blitz|{}' 'sp_BlitzFirst|{"@Seconds":"1"}' 'sp_BlitzIndex|{"@DatabaseName":"pgcr_seed"}'; do
      IFS='|' read -r tool pj <<<"$spec"
      [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"$tool\",\"params\":$pj}") == 200 && $(js "d['runs'][0]['outcome']") == done && $(js "len(d['runs'][0]['sets']) >= 1") == True ]] || fail "M: $tool: $(head -c 600 "$WORK/body")"
    done
    tick; [[ $(post community/run "{\"instance_id\":$MRID,\"tool\":\"sp_BlitzFirst\",\"params\":{\"@OutputDatabaseName\":\"pgcr_seed\"}}") == 400 ]] || fail "M: a writing parameter was passed: $(cat "$WORK/body")"
    [[ $(q "select count(*) from pgvigil.custom_report_log where op = 'community_run' and tool = 'sp_BlitzFirst' and outcome = 'refused'") == 1 ]] || fail "M: the refused writing parameter is not one refused log row"
    tick; [[ $(post community/params "{\"instance_id\":$MRID,\"tool\":\"sp_BlitzFirst\"}") == 200 ]] || fail "M: sp_BlitzFirst's form: $(cat "$WORK/body")"
    for x in @outputdatabasename @logmessage; do [[ $(js "'$x' in [p.lower() for p in d['left_out']]") == True ]] || fail "M: sp_BlitzFirst leaves $x in the form: $(js "d['left_out']")"; done
    tick; [[ $(post community/params "{\"instance_id\":$MRID,\"tool\":\"sp_BlitzCache\"}") == 200 ]] || fail "M: sp_BlitzCache's form: $(cat "$WORK/body")"
    for x in @ai @aiurl; do [[ $(js "'$x' in [p.lower() for p in d['left_out']]") == True ]] || fail "M: sp_BlitzCache leaves $x in the form: $(js "d['left_out']")"; done
    [[ $(post community/params "{\"instance_id\":$MRID,\"tool\":\"sp_Blitz\",\"database\":\"tempdb\"}") == 404 && $(cat "$WORK/body") == *SQL-Server-First-Responder-Kit* ]] || fail "M: sp_Blitz in tempdb: $(cat "$WORK/body")"
    [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_Blitz\",\"database\":\"tempdb\"}") == 200 && $(js "d['runs'][0]['outcome']") == refused && $(js "d['runs'][0]['error']") == *SQL-Server-First-Responder-Kit* ]] || fail "M: the run in tempdb: $(cat "$WORK/body")"
    ok "M: sp_Blitz, sp_BlitzFirst, sp_BlitzIndex grids; a writing parameter refused; a missing procedure says where to get it"
  fi
  if have darlingdata.sql; then
    [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_PressureDetector\",\"params\":{}}") == 200 && $(js "d['runs'][0]['outcome']") == done && $(js "len(d['runs'][0]['sets']) >= 1") == True ]] || fail "M: sp_PressureDetector: $(head -c 600 "$WORK/body")"
    ok "M: sp_PressureDetector's grids"
  fi
  for spec in 'sp_BlitzCache|{}' 'sp_BlitzWho|{}' 'sp_BlitzLock|{}' 'sp_QuickieStore|{"@database_name":"pgcr_seed"}' 'sp_HealthParser|{}' \
              'sp_HumanEventsBlockViewer|{}' 'sp_LogHunter|{}' 'sp_IndexCleanup|{"@database_name":"pgcr_seed"}'; do
    IFS='|' read -r tool pj <<<"$spec"
    c=$(crun "{\"instance_id\":$MRID,\"tool\":\"$tool\",\"params\":$pj}")
    [[ $c == 200 ]] || fail "M: $tool answered $c: $(head -c 400 "$WORK/body")"
    echo "rec  M: $tool: $(js "d['runs'][0]['outcome']"), $(js "len(d['runs'][0]['sets'])") sets, $(js "d['runs'][0]['rows']") rows $(js "(d['runs'][0].get('error') or '')[:140]")"
  done
  [[ $(getc "community?instance=$MAID") == 200 && $(js "d['enabled']") == False && $(js "d.get('reason','')") == *sysadmin* ]] || fail "M: the sa instance's page: $(cat "$WORK/body")"
  [[ $(crun "{\"instance_id\":$MAID,\"tool\":\"sp_Blitz\"}") == 200 && $(js "d['runs'][0]['outcome']") == refused && $(js "d['runs'][0]['error']") == *sysadmin* ]] || fail "M: a run as sa: $(cat "$WORK/body")"
  ok "M: sa refused (page and run)"
  # custom reports on SQL Server
  [[ $(post customreports "$(add "name=pgcr dbs" engine=sqlserver 'body=SELECT name, database_id FROM sys.databases WHERE database_id <= @n ORDER BY database_id' 'params=[{"name":"n","type":"int","default":"4"}]')") == 200 ]] || fail "M: add pgcr dbs: $(cat "$WORK/body")"
  rid=$(js "d['report_id']")
  [[ $(run "{\"report_id\":$rid,\"target\":\"instance\",\"instance_id\":$MRID}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "M: pgcr dbs: $(cat "$WORK/body")"
  got=$(js "'\n'.join(str(r[0])+'|'+str(r[1]) for r in d['runs'][0]['sets'][0]['rows'])")
  want=$(SQLCMDPASSWORD=$RPW docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -W -h -1 -s '|' -U pgcr_reader -Q "SET NOCOUNT ON; SELECT name, database_id FROM sys.databases WHERE database_id <= 4 ORDER BY database_id" 2>&1)
  [[ "$got" == "$want" ]] || fail "M: pgcr dbs is not the hand read: got [$got] want [$want]"
  [[ $(run "{\"report_id\":$rid,\"target\":\"instance\",\"instance_id\":$MAID}") == 200 && $(js "d['runs'][0]['outcome']") == refused && $(js "d['runs'][0]['error']") == *sysadmin* ]] || fail "M: pgcr dbs as sa: $(cat "$WORK/body")"
  [[ $(post customreports "$(add "name=pgcr msins" engine=sqlserver 'body=INSERT INTO pgcr_seed.dbo.t VALUES (9)')") == 200 ]] || fail "M: add the write"
  rid=$(js "d['report_id']")
  [[ $(run "{\"report_id\":$rid,\"target\":\"instance\",\"instance_id\":$MRID}") == 200 && $(js "d['runs'][0]['outcome']") == failed && $(js "d['runs'][0]['error']") == *"permission was denied"* ]] || fail "M: the write: $(cat "$WORK/body")"
  [[ $(sq "SELECT COUNT(*) FROM dbo.t" pgcr_seed) == 2 ]] || fail "M: t changed"
  [[ $(post customreports "$(add "name=pgcr msproc" engine=sqlserver kind=procedure body=pgcr_seed.dbo.pgcr_proc 'params=[{"name":"k","type":"int"}]')") == 200 ]] || fail "M: add the procedure report: $(cat "$WORK/body")"
  rid=$(js "d['report_id']")
  [[ $(run "{\"report_id\":$rid,\"target\":\"instance\",\"instance_id\":$MRID,\"params\":{\"k\":\"7\"}}") == 200 && $(js "d['runs'][0]['sets'][0]['rows']") == "[[7, 49]]" ]] || fail "M: the procedure report: $(cat "$WORK/body")"
  ok "M: pgcr dbs equals the hand read; sa refused; the write denied (t 2 rows); the procedure 7 49"
  # G: Glenn Berry's format, written here
  printf -- '-- pgcr script\r\n-- Server version (Query 1) (Version Info)\r\nSELECT @@VERSION AS v;\r\n------\r\n\r\n-- a note \xa9\r\n-- Every database (Query 2) (Database List)\r\nSELECT name FROM sys.databases ORDER BY name;\r\nGO\r\n------\r\n-- A write (Query 3) (Write Try)\r\nINSERT INTO pgcr_seed.dbo.t VALUES (8);\r\n------\r\n' > "$WORK/glenn.sql"
  python3 -c "import json,sys; print(json.dumps({'text': open(sys.argv[1], encoding='latin-1').read()}))" "$WORK/glenn.sql" > "$WORK/glenn.json"
  [[ $(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary @"$WORK/glenn.json" "$U/api/community/glenn/parse") == 200 ]] || fail "G: parse: $(cat "$WORK/body")"
  [[ $(js "[x['name'] for x in d['queries']]") == "['Version Info', 'Database List', 'Write Try']" && $(js "'GO' in d['queries'][1]['text']") == False ]] || fail "G: the queries: $(cat "$WORK/body")"
  Q2=$(js "json.dumps(d['queries'][1]['text'])"); Q3=$(js "json.dumps(d['queries'][2]['text'])")
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"glenn_berry\",\"text\":$Q2,\"query_name\":\"2 Database List\"}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "G: query 2: $(cat "$WORK/body")"
  [[ $(js "len(d['runs'][0]['sets'][0]['rows'])") == $(sq "SELECT COUNT(*) FROM sys.databases") ]] || fail "G: query 2's rows"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"glenn_berry\",\"text\":$Q3}") == 200 && $(js "d['runs'][0]['outcome']") == failed && $(js "d['runs'][0]['error']") == *"permission was denied"* ]] || fail "G: query 3: $(cat "$WORK/body")"
  [[ $(sq "SELECT COUNT(*) FROM dbo.t" pgcr_seed) == 2 ]] || fail "G: t changed"
  [[ $(post community/glenn/parse '{"text":"SELECT 1;"}') == 400 ]] || fail "G: a file without markers: $(cat "$WORK/body")"
  ok "G: 3 queries cut, GO dropped; the list run equals sys.databases; the write denied; no markers refused"
fi

# ---- Q: PostgreSQL community reads ------------------------------------------------------------------------------------
[[ $(getc "community?instance=$AID") == 200 && $(js "d['enabled']") == True && $(js "len(d['tools'])") == 10 ]] || fail "Q: the tools of $INSTA: $(cat "$WORK/body")"
[[ $(crun "{\"instance_id\":$AID,\"tool\":\"pg_running\",\"params\":{}}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "Q: pg_running: $(cat "$WORK/body")"
[[ $(crun "{\"instance_id\":$AID,\"tool\":\"pg_settings_changed\"}") == 200 && $(js "d['runs'][0]['outcome']") == done && $(js "len(d['runs'][0]['sets'][0]['rows']) >= 1") == True ]] || fail "Q: pg_settings_changed: $(cat "$WORK/body")"
[[ $(crun "{\"instance_id\":$AID,\"tool\":\"pg_table_sizes\",\"database\":\"$TGT\"}") == 200 && $(js "any(r[1]=='t' for r in d['runs'][0]['sets'][0]['rows'])") == True ]] || fail "Q: pg_table_sizes: $(cat "$WORK/body")"
[[ $(crun "{\"instance_id\":$SID,\"tool\":\"pg_running\"}") == 200 && $(js "d['runs'][0]['outcome']") == refused && $(js "d['runs'][0]['error']") == *superuser* ]] || fail "Q: the superuser: $(cat "$WORK/body")"
ok "Q: 10 reads; running, settings, table sizes (t); the superuser refused"

# ---- N: before the click (task B3 DONE-1) ----------------------------------------------------------------------------------
tl() { python3 -c "import json; d=json.load(open('$WORK/body')); t={x['id']: x for x in d['tools']}; print($1)"; }
fresh() { getc "community?instance=$1&fresh=1${2:+&database=$2}"; }   # past the 60 s keep: the checks run again
if [[ -z "$SKIP_MSSQL" ]]; then
  [[ $(fresh "$MRID") == 200 && $(tl "len(d['needs'])") == 0 && $(tl "d['enabled']") == True && $(tl "d['checked_at'] is not None") == True ]] || fail "N: $MSR's instance needs: $(head -c 600 "$WORK/body")"
  [[ $(tl "[(n['hard'], n['state']) for n in t['sp_LogHunter']['needs']]") == "[(True, 'needs')]" && $(tl "t['sp_LogHunter']['state']") == needs && $(tl "t['sp_LogHunter']['on']") == False \
     && $(tl "t['sp_LogHunter']['needs'][0]['what']") == *xp_readerrorlog* && $(tl "t['sp_LogHunter']['needs'][0]['how']") == "USE [master]; GRANT EXECUTE ON sys.xp_readerrorlog TO [pgcr_reader];" ]] \
     || fail "N: sp_LogHunter's need (the reader has a user in master: no CREATE USER): $(tl "t['sp_LogHunter']['needs']")"
  # blocked process threshold 0 (a new container): system_health preset, a note, the tool on
  [[ $(tl "t['sp_HumanEventsBlockViewer']['state']") == note && $(tl "t['sp_HumanEventsBlockViewer']['preset']") == "{'@session_name': 'system_health'}" \
     && $(tl "t['sp_HumanEventsBlockViewer']['needs'][0]['what']") == *"blocked process threshold 0"*system_health* ]] || fail "N: sp_HumanEventsBlockViewer at threshold 0: $(tl "t['sp_HumanEventsBlockViewer']")"
  qsdb=$(sq "SELECT TOP (1) name FROM sys.databases WHERE is_query_store_on = 1 AND state = 0 ORDER BY name")
  if [[ -n $qsdb ]]; then
    [[ $(tl "t['sp_QuickieStore']['state']") == note && $(tl "t['sp_QuickieStore']['preset']") == "{'@database_name': '$qsdb'}" ]] || fail "N: sp_QuickieStore's preset ($qsdb has Query Store on): $(tl "t['sp_QuickieStore']")"
  else
    [[ $(tl "t['sp_QuickieStore']['state']") == note && $(tl "t['sp_QuickieStore']['needs'][0]['what']") == *"Query Store is on in no database"* ]] || fail "N: sp_QuickieStore with no Query Store: $(tl "t['sp_QuickieStore']")"
  fi
  [[ $(tl "sorted(x['id'] for x in d['tools'] if x['needs'])") == "['sp_HumanEventsBlockViewer', 'sp_LogHunter', 'sp_QuickieStore']" ]] || fail "N: other tools with a need: $(tl "[(x['id'], x['needs']) for x in d['tools'] if x['needs']]")"
  [[ $(tl "sorted(x['id'] for x in d['tools'] if not x['on'])") == "['sp_LogHunter']" ]] || fail "N: tools off: $(tl "sorted(x['id'] for x in d['tools'] if not x['on'])")"
  ok "N: $MSR: sp_LogHunter off (xp_readerrorlog, the GRANT line); sp_HumanEventsBlockViewer preset system_health at threshold 0; sp_QuickieStore preset ${qsdb:-none}; 13 on"
  # declined: the procedure's own refusal is a failed run in the audit, declined in the answer, never 'refused'
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_LogHunter\",\"params\":{}}") == 200 && $(js "d['runs'][0]['outcome']") == failed && $(js "d['runs'][0].get('declined')") == True \
     && $(js "d['runs'][0]['error']") == "sp_LogHunter declined: Current user does not have EXECUTE permission on xp_readerrorlog"*"(msg 50000, severity 11)" ]] || fail "N: sp_LogHunter declined: $(head -c 600 "$WORK/body")"
  [[ $(q "select outcome || '|' || left(detail, 26) from pgvigil.custom_report_log where op = 'community_run' and tool = 'sp_LogHunter' order by log_id desc limit 1") == "failed|sp_LogHunter declined: Curr" ]] || fail "N: the declined run's log row"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_HumanEventsBlockViewer\",\"params\":{\"@session_name\":\"pgcr_none\"}}") == 200 && $(js "d['runs'][0].get('declined')") == True \
     && $(js "d['runs'][0]['error']") == *"lousy version in system_health"* ]] || fail "N: sp_HumanEventsBlockViewer on a session at threshold 0: $(head -c 600 "$WORK/body")"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_HumanEventsBlockViewer\",\"params\":{\"@session_name\":\"system_health\"}}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "N: sp_HumanEventsBlockViewer with its preset: $(head -c 600 "$WORK/body")"
  c=$(crun "{\"instance_id\":$MRID,\"tool\":\"sp_IndexCleanup\",\"params\":{\"@database_name\":\"pgcr_nosuchdb_$N\"}}")
  [[ $c == 200 && $(js "d['runs'][0].get('declined')") == True && $(js "d['runs'][0]['error']") == "sp_IndexCleanup declined: No valid databases found to process. (msg 50000, severity 16)" ]] || fail "N: sp_IndexCleanup on a database it cannot find: $(head -c 600 "$WORK/body")"
  ok "N: declined in the procedures' own words (sp_LogHunter severity 11, sp_IndexCleanup 16, sp_HumanEventsBlockViewer): outcome failed with the words, declined true; the preset run done"
  # a real failure inside a kit stays an error: SELECT on the index usage DMV denied in pgcr_seed, sp_BlitzIndex reads it
  sq "DENY SELECT ON sys.dm_db_index_usage_stats TO pgcr_reader;" pgcr_seed >/dev/null && sq "DENY SELECT ON sys.dm_db_index_usage_stats TO pgcr_reader;" >/dev/null || fail "N: the DENY"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_BlitzIndex\",\"params\":{\"@DatabaseName\":\"pgcr_seed\"}}") == 200 ]] || fail "N: sp_BlitzIndex with the DMV denied: $(head -c 400 "$WORK/body")"
  red=$(js "(d['runs'][0]['outcome'], bool(d['runs'][0].get('declined')), (d['runs'][0].get('error') or '')[:160])")
  sq "REVOKE SELECT ON sys.dm_db_index_usage_stats FROM pgcr_reader;" pgcr_seed >/dev/null && sq "REVOKE SELECT ON sys.dm_db_index_usage_stats FROM pgcr_reader;" >/dev/null || fail "N: the REVOKE of the DENY"
  [[ $red == "('failed', False, "* ]] || fail "N: a real failure inside sp_BlitzIndex is not an error: $red"
  ok "N: a real failure inside sp_BlitzIndex stays an error: $red"
  # the sibling pairs (the lead 15:50): EXECUTE revoked on the sibling, the tool run with the form's defaults; the code's
  # list says hard (a default run fails) or a note (it ends done) - a pair the run contradicts fails here
  for pair in sp_Blitz/sp_BlitzBackups sp_Blitz/sp_BlitzCache sp_Blitz/sp_BlitzFirst sp_Blitz/sp_BlitzIndex sp_Blitz/sp_BlitzLock sp_Blitz/sp_BlitzWho \
              sp_Blitz/sp_DatabaseRestore sp_Blitz/sp_ineachdb sp_BlitzFirst/sp_BlitzWho sp_BlitzFirst/sp_BlitzCache sp_BlitzIndex/sp_BlitzCache; do
    tool=${pair%/*}; sib=${pair#*/}
    sq "REVOKE EXECUTE ON dbo.$sib FROM pgcr_reader;" >/dev/null || fail "N: revoke $sib"
    [[ $(fresh "$MRID") == 200 ]] || fail "N: GET with $sib revoked"
    code_says=$(tl "[n['hard'] for n in t['$tool']['needs'] if '$sib ' in n['what']]")
    [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"$tool\",\"params\":{}}") == 200 ]] || fail "N: $tool with $sib revoked answered: $(head -c 300 "$WORK/body")"
    ran=$(js "d['runs'][0]['outcome']"); why=$(js "(d['runs'][0].get('error') or '')[:120]")
    sq "GRANT EXECUTE ON dbo.$sib TO pgcr_reader;" >/dev/null || fail "N: grant $sib back"
    echo "rec  N: pair $tool / $sib: the code says $code_says; the default run $ran $why"
    case "$code_says|$ran" in
      "[True]|failed"|"[False]|done") ;;
      *) fail "N: the pair $tool / $sib: the code says $code_says (hard = [True]) but the default run ended $ran: $why" ;;
    esac
  done
  ok "N: 11 sibling pairs: each one's hard / note agrees with a default run with the right revoked"
  # threshold 5, no session capturing the report: system_health preset with its note; a session made: its name preset
  sq "EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sys.sp_configure 'blocked process threshold (s)', 5; RECONFIGURE;" >/dev/null || fail "N: threshold 5"
  [[ $(fresh "$MRID") == 200 && $(tl "t['sp_HumanEventsBlockViewer']['preset']") == "{'@session_name': 'system_health'}" \
     && $(tl "t['sp_HumanEventsBlockViewer']['needs'][0]['what']") == "no running session captures the blocked process report"* ]] || fail "N: threshold 5 without a session: $(tl "t['sp_HumanEventsBlockViewer']")"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_HumanEventsBlockViewer\",\"params\":{\"@session_name\":\"system_health\"}}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "N: the state (c) default click: $(head -c 400 "$WORK/body")"
  XES=pgcr_bpr_$N
  sq "CREATE EVENT SESSION [$XES] ON SERVER ADD EVENT sqlserver.blocked_process_report ADD TARGET package0.ring_buffer; ALTER EVENT SESSION [$XES] ON SERVER STATE = START;" >/dev/null || fail "N: the session $XES"
  [[ $(fresh "$MRID") == 200 && $(tl "t['sp_HumanEventsBlockViewer']['preset']") == "{'@session_name': '$XES'}" && $(tl "t['sp_HumanEventsBlockViewer']['needs'][0]['what']") == *"the form reads $XES"* ]] || fail "N: the state (b) preset: $(tl "t['sp_HumanEventsBlockViewer']")"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_HumanEventsBlockViewer\",\"params\":{\"@session_name\":\"$XES\"}}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "N: the state (b) click: $(head -c 400 "$WORK/body")"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_HumanEventsBlockViewer\",\"params\":{\"@session_name\":\"pgcr_none\"}}") == 200 && $(js "d['runs'][0].get('declined')") == True \
     && $(js "d['runs'][0]['error']") == *"A session with the name pgcr_none does not exist or is not currently active."* ]] || fail "N: a typed session that does not exist: $(head -c 400 "$WORK/body")"
  sq "ALTER EVENT SESSION [$XES] ON SERVER STATE = STOP; DROP EVENT SESSION [$XES] ON SERVER; EXEC sys.sp_configure 'blocked process threshold (s)', 0; RECONFIGURE;" >/dev/null || fail "N: the session dropped"
  ok "N: sp_HumanEventsBlockViewer: threshold 5 with no session = system_health preset and its note, run done; a session made = its name preset, run done; a typed session that does not exist declined"
  # the grant: sp_LogHunter's need gone, a note on the archived logs (no securityadmin), its run done
  sq "GRANT EXECUTE ON sys.xp_readerrorlog TO pgcr_reader;" >/dev/null || fail "N: the grant"
  [[ $(fresh "$MRID") == 200 && $(tl "[(n['hard'], n['state']) for n in t['sp_LogHunter']['needs']]") == "[(False, 'note')]" && $(tl "t['sp_LogHunter']['on']") == True ]] || fail "N: sp_LogHunter after the grant: $(tl "t['sp_LogHunter']['needs']")"
  [[ $(crun "{\"instance_id\":$MRID,\"tool\":\"sp_LogHunter\",\"params\":{}}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "N: sp_LogHunter with the right: $(head -c 600 "$WORK/body")"
  ok "N: granted: sp_LogHunter on with its securityadmin note, done"
  # the narrow login (no CONNECT ANY DATABASE, a user in master only, no EXECUTE): every procedure off with its GRANT line,
  # sp_IndexCleanup also without a reachable user database; Glenn's file tool on
  [[ $(fresh "$MNID") == 200 && $(tl "sorted(x['id'] for x in d['tools'] if x['on'])") == "['glenn_berry']" \
     && $(tl "t['sp_Blitz']['needs'][0]['how']") == "USE [master]; GRANT EXECUTE ON dbo.[sp_Blitz] TO [pgcr_narrow];" \
     && $(tl "any('a user database the read login can reach' in n['what'] for n in t['sp_IndexCleanup']['needs'])") == True ]] || fail "N: the narrow login: $(tl "[(x['id'], x['state'], [n['what'][:60] for n in x['needs']]) for x in d['tools']]")"
  ok "N: $MSN (narrow login): 13 procedures off, each with its GRANT line; sp_IndexCleanup without a reachable database; Glenn's on"
  [[ $(fresh "$MAID") == 200 && $(tl "d['enabled']") == False && $(tl "[n['hard'] for n in d['needs']]") == "[True]" && $(tl "d['needs'][0]['what']") == *sysadmin* \
     && $(tl "sum(1 for x in d['tools'] if x['on'])") == 0 ]] || fail "N: the sa instance: $(tl "d['needs']")"
  [[ $(code "$U2/api/community?instance=$MRID") == 200 && $(tl "d['needs'][0]['what']") == "Running a tool needs a signed-in user: this server was started with -no-login." \
     && $(tl "d['needs'][0]['how']") == *"pgvigil user add"* && $(tl "sum(1 for x in d['tools'] if x['on'])") == 0 ]] || fail "N: the -no-login serve: $(head -c 600 "$WORK/body")"
  [[ $(code "$U2/api/customreports") == 200 && $(js "d['state']['reason']") == "Saving or running a report needs a signed-in user: this server was started with -no-login." ]] || fail "N: custom reports' words: $(head -c 300 "$WORK/body")"
  [[ $(code "$U2/api/reportmail") == 200 && $(js "d['door']['reason']") == "Sending or scheduling a mail needs a signed-in user: this server was started with -no-login." ]] || fail "N: report mail's words: $(head -c 300 "$WORK/body")"
  ok "N: sa: every tool off naming sysadmin; -no-login: each page's own words (Running a tool / Saving or running a report / Sending or scheduling a mail)"
  # the instance paused: the checks answer within the budget, every tool 'not checked', none on; unpaused: ready again
  docker pause "$CT" >/dev/null || fail "N: docker pause"
  t0=$(date +%s%N); c=$(fresh "$MRID"); ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  docker unpause "$CT" >/dev/null || fail "N: docker unpause"
  [[ $c == 200 && $ms -lt 7000 && $(tl "sorted(set(x['state'] for x in d['tools']))") == "['not_checked']" && $(tl "sum(1 for x in d['tools'] if x['on'])") == 0 ]] || fail "N: the paused instance ($ms ms): $(tl "[(x['id'], x['state']) for x in d['tools']][:4]"), $(tl "d['needs']")"
  ok "N: $MSR paused: answered in $ms ms, 14 of 14 tools 'not checked' ($(tl "d['needs'][0]['what'][:90]")), none on"
  for _ in $(seq 1 25); do [[ $(fresh "$MRID") == 200 && $(tl "t['sp_WhoIsActive']['state']") == ready ]] && break; sleep 2; done
  [[ $(tl "t['sp_WhoIsActive']['state']") == ready ]] || fail "N: $MSR unpaused is not ready again: $(tl "t['sp_WhoIsActive']")"
  ok "N: unpaused: sp_WhoIsActive ready again"
fi
if [[ -n "${DID:-}" ]]; then
  t0=$(date +%s%N); c=$(fresh "$DID"); ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  [[ $c == 200 && $ms -lt 7000 && $(tl "sorted(set(x['state'] for x in d['tools']))") == "['not_checked']" && $(tl "d['needs'][-1]['what']") == "not checked: the connection to $INSTD"* ]] || fail "N: the stopped instance: $(head -c 600 "$WORK/body")"
  ok "N: $INSTD (nothing listens on its port): answered in $ms ms, 10 of 10 tools 'not checked', none on"
else
  NOTPROVEN+=("N: the stopped PostgreSQL instance $INSTD was not registered by the collection, so its page was not read")
fi
[[ $(fresh "$AID") == 200 && $(tl "len(d['needs'])") == 0 && $(tl "[n['hard'] for n in t['pg_top_statements']['needs']]") == "[True]" \
   && $(tl "t['pg_top_statements']['needs'][0]['what']") == "pg_stat_statements is not created in the database $TGT" && $(tl "t['pg_top_statements']['needs'][0]['how']") == *"superuser-class role"*"CREATE EXTENSION pg_stat_statements"* \
   && $(tl "sorted(x['id'] for x in d['tools'] if x['needs'])") == "['pg_top_statements']" ]] || fail "N: $INSTA's needs: $(tl "(d['needs'], [(x['id'], x['needs']) for x in d['tools'] if x['needs']])")"
tq "create extension if not exists pg_stat_statements" || fail "N: create extension pg_stat_statements in $TGT"
[[ $(fresh "$AID") == 200 ]] || fail "N: GET after the extension"
if [[ $(tl "t['pg_top_statements']['state']") == ready ]]; then
  [[ $(crun "{\"instance_id\":$AID,\"tool\":\"pg_top_statements\",\"params\":{}}") == 200 && $(js "d['runs'][0]['outcome']") == done ]] || fail "N: Top statements with the extension: $(head -c 600 "$WORK/body")"
  ok "N: $INSTA: Top statements off (not created in $TGT, ask a superuser-class role); created: ready, done (schema-qualified)"
elif [[ $(tl "t['pg_top_statements']['needs'][0]['what']") == *"but not loaded"* ]]; then
  NOTPROVEN+=("N: this cluster does not load pg_stat_statements (55000 named: $(tl "t['pg_top_statements']['needs'][0]['what'][:120]")): Top statements' run")
else
  fail "N: Top statements after CREATE EXTENSION: $(tl "t['pg_top_statements']")"
fi
[[ $(fresh "$SID") == 200 && $(tl "d['enabled']") == False && $(tl "d['needs'][0]['what']") == *superuser* && $(tl "d['needs'][0]['hard']") == True ]] || fail "N: the superuser instance's need: $(tl "d['needs']")"
ok "N: $INSTS: the superuser named before the click"
# the keep: a second GET within 60 s answers the same checked_at, fresh=1 a newer one
getc "community?instance=$AID" >/dev/null; k1=$(tl "d['checked_at']"); getc "community?instance=$AID" >/dev/null; k2=$(tl "d['checked_at']"); fresh "$AID" >/dev/null; k3=$(tl "d['checked_at']")
[[ $k1 == "$k2" && $k3 > $k2 ]] || fail "N: the keep: $k1 / $k2 / $k3"
ok "N: kept 60 s (two GETs, one checked_at $k1), fresh=1 checks again ($k3)"

# ---- A: the audit --------------------------------------------------------------------------------------------------------
[[ $(runlog) == "$(nruns)" ]] || fail "A: $(runlog) run rows for $(nruns) runs"
ok "A: $(nruns) runs, $(nruns) run rows in the log"

# ---- U: the pages ----------------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_SKIP_PAGES:-}" ]]; then NOTPROVEN+=("NOT PROVEN (PAGES): PGVIGIL_SKIP_PAGES"); else
  for t in chromium node npm; do command -v $t >/dev/null || fail "U: $t is not on this machine (PGVIGIL_SKIP_PAGES=1 leaves the pages out)"; done
  grep -q 'Custom reports' internal/web/dist/app.js || fail "U: the web bundle has no custom reports page: apply the wiring and run 'npm run build' in web/"
  (cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "U: npm install axe-core"
  CDP=$(freeport); mkdir -p "$WORK/dl"
  chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  COOKIE=$(awk '$6 == "pgvigil_session" {print $7}' "$JAR")
  cat > "$WORK/pages.mjs" <<'JS'
const [port, U, axePath, dl, cookie, srep, msr, pga, msa] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const bws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise(r => bws.addEventListener('open', r));
bws.send(JSON.stringify({ id: 1, method: 'Browser.setDownloadBehavior', params: { behavior: 'allow', downloadPath: dl } }));
await new Promise(r => bws.addEventListener('message', r));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 20000) => { for (const t = Date.now(); Date.now() - t < ms; await sleep(200)) if (await ev(expr)) return true; return false; };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Network.setCookie', { name: 'pgvigil_session', value: cookie, url: U });
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const out = { pages: [], cells: null, xlsx: null };
const open = async (hash, ready) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  if (!await until(ready)) throw new Error('the page did not render: ' + hash + ' ' + await ev(`document.querySelector('main')?.innerText.slice(0, 300)`));
  await sleep(300);
};
const axe = async (label) => {
  await ev(axeSrc + '; 1');
  const r = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(x => x.target.join(' ')) }))))`));
  out.pages.push({ label, violations: r });
};
for (const theme of ['light', 'dark']) {
  await open('#/customreports', `!!document.querySelector('main h2')`);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 1`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await open('#/customreports', `[...document.querySelectorAll('main h3')].some(h => /Folder /.test(h.textContent)) && !!document.querySelector('main a[href*="report="]')`);
  await axe(`${theme} tree`);
  await open(`#/customreports?report=${srep}`, `!!document.querySelector('main .report-result table.grid')`);
  await axe(`${theme} report`);
  if (theme === 'light') {
    out.cells = JSON.parse(await ev(`JSON.stringify((() => { const t = document.querySelector('main .report-result table.grid'); const hs = [...t.querySelectorAll('thead tr:first-child th')].map(h => h.textContent.trim()); const ni = hs.findIndex(h => /^name length/.test(h)); return [...t.querySelectorAll('tbody tr')].map(tr => { const c = tr.children; return { name: c[0].textContent.trim(), len: c[ni].textContent.trim(), cls: c[ni].className }; }); })())`));
    const before = new Set(fs.readdirSync(dl));
    await ev(`[...document.querySelectorAll('#bar button')].find(b => /Export \\.xlsx/.test(b.textContent)).click(); 1`);
    for (let i = 0; i < 100 && !out.xlsx; i++) { await sleep(200); const f = fs.readdirSync(dl).find(x => !before.has(x) && x.endsWith('.xlsx')); if (f) out.xlsx = f; }
  }
  await open(`#/customreports?edit=${srep}`, `!!document.querySelector('main textarea')`);
  await axe(`${theme} editor`);
  if (msr) {
    await open(`#/community?i=${msr}`, `!!document.querySelector('main h3') && [...document.querySelectorAll('main button.link')].some(b => b.textContent === 'sp_WhoIsActive')`);
    await ev(`[...document.querySelectorAll('main button.link')].find(b => b.textContent === 'sp_WhoIsActive').click(); 1`);
    if (!await until(`[...document.querySelectorAll('main button')].some(b => b.textContent === 'Run sp_WhoIsActive')`)) throw new Error('the sp_WhoIsActive form did not open');
    await axe(`${theme} community sqlserver`);
  }
  if (msa && theme === 'light') {
    // B3: before the click - the reader's page has the 'before it runs' column; the sa page says why every tool is off
    await open(`#/community?i=${msr}`, `[...document.querySelectorAll('main th')].some(h => /before it runs/.test(h.textContent))`);
    out.msrReady = await ev(`(() => { const b = [...document.querySelectorAll('main button.link')].find(x => x.textContent === 'sp_WhoIsActive'); return b?.closest('tr')?.lastElementChild?.textContent.trim() ?? null; })()`);
    await open(`#/community?i=${msa}`, `!!document.querySelector('main .needs')`);
    out.msa = await ev(`(() => { const btns = [...document.querySelectorAll('main table.grid button.link')]; const cs = btns[0] ? getComputedStyle(btns[0]) : null;
      const probe = document.createElement('span'); probe.style.color = 'var(--accent)'; document.body.append(probe); const accent = getComputedStyle(probe).color; probe.remove();
      return { box: document.querySelector('main .needs')?.textContent ?? '', n: btns.length, off: btns.filter(b => b.getAttribute('aria-disabled') === 'true' && /sysadmin/.test(b.title)).length,
        deco: cs?.textDecorationLine ?? '', color: cs?.color ?? '', accent }; })()`);
  }
  await open(`#/community?i=${pga}`, `[...document.querySelectorAll('main h3')].some(h => h.textContent === 'pgvigil reads')`);
  await axe(`${theme} community postgres`);
}
console.log(JSON.stringify(out));
// the two CDP sockets keep node alive after the last line (Node 26's WebSocket): close them and exit, or the proof waits forever
ws.close(); bws.close(); process.exit(0);
JS
  timeout 900 node "$WORK/pages.mjs" "$CDP" "$U/" "$WORK/node_modules/axe-core/axe.min.js" "$WORK/dl" "$COOKIE" "$SREP" "${MRID:-}" "$AID" "${MAID:-}" > "$WORK/pages.json" 2>"$WORK/pages.err" || fail "U: the page driver: $(tail -5 "$WORK/pages.err")"
  python3 - "$WORK/pages.json" "$WORK/dl" "$INSTL" "${PGVIGIL_PYLIB:-}" <<'PY' || fail "U: see above"
import json, sys, zipfile, re, os
d = json.load(open(sys.argv[1])); dl = sys.argv[2]; long_name = sys.argv[3]; pylib = sys.argv[4]
bad = [p for p in d['pages'] if p['violations']]
for p in d['pages']:
    print(('viol ' if p['violations'] else 'ok   ') + 'U: axe ' + p['label'] + ': ' + (json.dumps(p['violations']) if p['violations'] else '0 violations'))
m = d.get('msa')
if m is not None:
    assert m['n'] == 14 and m['off'] == 14 and 'sysadmin' in m['box'] and m['box'].startswith('Before a tool can run on'), f"U: the sa page: {m['off']} of {m['n']} tool buttons off with 'sysadmin' on hover; its box: {m['box'][:200]!r}"
    assert m['deco'] == 'none' and m['color'] != m['accent'], f"U: a disabled tool button is drawn like a link: text-decoration {m['deco']!r}, colour {m['color']} (accent {m['accent']}) - the wiring's app.css line"
    assert (d.get('msrReady') or '').startswith('ready'), f"U: sp_WhoIsActive's 'before it runs' cell on pgcr-msr: {d.get('msrReady')!r}"
    print(f"ok   U: [B3] pgcr-msa: 'Before a tool can run' names sysadmin, {m['off']} of {m['n']} tool buttons off with it on hover, drawn off ({m['color']}, no underline); pgcr-msr: sp_WhoIsActive 'ready'")
cells = d['cells'] or []
assert cells, 'U: no rows read from the report grid'
for c in cells:
    want = 'crit' if c['name'] == long_name else 'ok'
    assert 'status' in c['cls'] and want in c['cls'].split(), f"U: {c['name']}'s name length cell is {c['cls']!r}, not status {want}"
print(f"ok   U: {len(cells)} rows; {long_name}'s name length crit, the others ok")
assert d['xlsx'], 'U: no .xlsx downloaded'
z = zipfile.ZipFile(os.path.join(dl, d['xlsx']))
styles = z.read('xl/styles.xml').decode()
fills = re.findall(r'<fill>(.*?)</fill>', styles)
fill_rgb = [re.search(r'fgColor rgb="(\w+)"', f).group(1) if 'fgColor' in f else None for f in fills]
assert 'FFAB1F26' in fill_rgb and 'FF006638' in fill_rgb, f'U: the workbook has no crit and ok fills: {fill_rgb}'
xfs = re.findall(r'<xf [^>]*?fillId="(\d+)"', re.search(r'<cellXfs[^>]*>(.*?)</cellXfs>', styles, re.S).group(1))
sheets = sorted(n for n in z.namelist() if n.startswith('xl/worksheets/sheet'))
ss = re.findall(r'<si><t[^>]*>(.*?)</t></si>', z.read('xl/sharedStrings.xml').decode()) if 'xl/sharedStrings.xml' in z.namelist() else []
found = None
for sh in sheets:
    x = z.read(sh).decode()
    rows = re.findall(r'<row [^>]*>(.*?)</row>', x, re.S)
    if not rows: continue
    def cellv(c):
        m = re.search(r'<v>(.*?)</v>', c); t = re.search(r't="(\w+)"', c); inl = re.search(r'<is><t[^>]*>(.*?)</t></is>', c)
        if inl: return inl.group(1)
        if not m: return ''
        return ss[int(m.group(1))] if t and t.group(1) == 's' else m.group(1)
    head = [cellv(c) for c in re.findall(r'<c [^>]*?(?:/>|>.*?</c>)', rows[0], re.S)]
    if 'name length' not in head: continue
    li = head.index('name length')
    found = []
    for r in rows[1:]:
        cs = re.findall(r'<c [^>]*?(?:/>|>.*?</c>)', r, re.S)
        sid = re.search(r' s="(\d+)"', cs[li]); fid = int(xfs[int(sid.group(1))]) if sid else 0
        found.append((cellv(cs[0]), fill_rgb[fid]))
assert found, 'U: no sheet with the name length column'
for name, rgb in found:
    want = 'FFAB1F26' if name == long_name else 'FF006638'
    assert rgb == want, f'U: the workbook colours {name} {rgb}, not {want}'
print(f"ok   U: {d['xlsx']}: {len(found)} rows, the long name crit FFAB1F26, the others ok FF006638")
if pylib: sys.path.insert(0, pylib)
try:
    import openpyxl
    wb = openpyxl.load_workbook(os.path.join(dl, d['xlsx'])); print(f"ok   U: openpyxl opens it ({len(wb.sheetnames)} sheets)")
except ImportError:
    print('note U: openpyxl is not installed here: the workbook open is not checked by it')
if bad: sys.exit(1)
PY
  # ---- U2 (B3 DONE-1): every tool clicked and run, keyboard and accessibility tree, the off look, the DOM check, the demo
  cat > "$WORK/buttons.mjs" <<'JS'
// B3 DONE-1's page rows (headless Chromium over CDP; written by proof-customreports.sh part U2 and run twice):
//   live <port> <U signed in> <cookie> <U2 -no-login> <msr> <msa> <pga> <report id> <glenn file> <shots dir>
//   demo <port> <U4 the demo serve> <demo SQL Server id> <demo PostgreSQL id> <the real msr id> <shots dir>
// Prints one JSON object; the shell grades it.
const [mode, port, ...a] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); const reqs = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
  if (d.method === 'Network.requestWillBeSent') reqs.push(d.params.request.url);
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 20000) => { for (const t = Date.now(); Date.now() - t < ms; await sleep(200)) if (await ev(expr)) return true; return false; };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable'); await cmd('DOM.enable'); await cmd('Accessibility.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const out = { mode, dom: [], selftest: null, rows: [] };
const open = async (url, ready) => {
  await cmd('Page.navigate', { url }); await sleep(300);
  if (!await until(ready, 30000)) throw new Error('the page did not render: ' + url + ' ' + await ev(`document.querySelector('main')?.innerText.slice(0, 300)`));
  await sleep(400);
};
const theme = async (t, U) => {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(t)}); 1`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: t }] });
};
const shot = async (dir, name) => {
  if (!dir) return;
  fs.mkdirSync(dir, { recursive: true });
  const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(`${dir}/${name}.png`, Buffer.from(s.result.data, 'base64'));
};
// every control that is off and shown has a visible, non-empty description (aria-describedby)
const offCheck = (label) => ev(`(() => {
  const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
  const ctl = [...document.querySelectorAll('main button, main input, main select, main textarea, dialog button')]
    .filter(e => (e.disabled || e.getAttribute('aria-disabled') === 'true') && vis(e));
  const bad = ctl.filter(e => { const ids = (e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean);
    return !ids.some(i => { const x = document.getElementById(i); return vis(x) && x.textContent.trim().length > 0; }); });
  return { label: ${JSON.stringify(label)}, off: ctl.length, bad: bad.map(e => (e.tagName + ' ' + (e.textContent || e.getAttribute('aria-label') || '').trim()).slice(0, 80)) };
})()`);
// the off tool buttons of a community page: text, described text, and what the accessibility tree reports
const axOff = async () => {
  const doc = await cmd('DOM.getDocument', { depth: -1 });
  const q = await cmd('DOM.querySelectorAll', { nodeId: doc.result.root.nodeId, selector: 'main table.grid button.link[aria-disabled="true"]' });
  const page = await ev(`[...document.querySelectorAll('main table.grid button.link[aria-disabled="true"]')].map(b => ({ name: b.textContent.trim(),
    desc: (b.getAttribute('aria-describedby') || '').split(/\\s+/).map(i => document.getElementById(i)?.textContent ?? '').join(' ') }))`);
  const rows = [];
  for (let i = 0; i < q.result.nodeIds.length; i++) {
    const ax = await cmd('Accessibility.getPartialAXTree', { nodeId: q.result.nodeIds[i], fetchRelatives: false });
    const n = (ax.result?.nodes ?? []).find(x => x.role?.value === 'button') ?? ax.result?.nodes?.[0] ?? {};
    const squash = s => String(s ?? '').replace(/\\s+/g, '');
    rows.push({ name: page[i]?.name, axName: n.name?.value ?? '', same: squash(n.description?.value) === squash(page[i]?.desc) && squash(page[i]?.desc).length > 0, axDesc: String(n.description?.value ?? '').slice(0, 100) });
  }
  return rows;
};
const tabWalk = async (max) => {
  // from the page's own heading (the bar and the tree come first in the document: not this page's controls)
  await ev(`(() => { const h = document.querySelector('main h2'); h.setAttribute('tabindex', '-1'); h.focus(); return 1; })()`);
  const reached = new Set();
  for (let i = 0; i < max; i++) {
    await cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 });
    await cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9, nativeVirtualKeyCode: 9 });
    const x = await ev(`(() => { const e = document.activeElement; return e && e.matches && e.matches('main table.grid button.link[aria-disabled="true"]') ? e.textContent.trim() : ''; })()`);
    if (x) reached.add(x);
  }
  return [...reached];
};
// a real mouse click on an off control: the page's requests to the community API before and after
const clickOff = async (sel) => {
  const r = await ev(`(() => { const b = document.querySelector(${JSON.stringify(sel)}); if (!b) return null; b.scrollIntoView({ block: 'center' }); const q = b.getBoundingClientRect(); return { x: q.x + q.width / 2, y: q.y + q.height / 2, t: b.textContent.trim() }; })()`);
  if (!r) return { clicked: null, sent: -1 };
  const n0 = reqs.filter(u => /\/api\/community\//.test(u)).length;
  for (const type of ['mousePressed', 'mouseReleased']) await cmd('Input.dispatchMouseEvent', { type, x: r.x, y: r.y, button: 'left', clickCount: 1 });
  await sleep(1000);
  return { clicked: r.t, sent: reqs.filter(u => /\/api\/community\//.test(u)).length - n0, error: await ev(`!!document.querySelector('main .error')`) };
};
const look = (sel) => ev(`(() => { const b = document.querySelector(${JSON.stringify(sel)}); if (!b) return null; const cs = getComputedStyle(b);
  const p = document.createElement('span'); p.style.color = 'var(--accent)'; document.body.append(p); const accent = getComputedStyle(p).color; p.style.color = 'GrayText'; const gray = getComputedStyle(p).color; p.remove();
  return { color: cs.color, deco: cs.textDecorationLine, cursor: cs.cursor, accent, gray }; })()`);
const communityReady = `!!document.querySelector('main table.grid button.link')`;

if (mode === 'live') {
  const [U, cookie, U2, msr, msa, pga, srep, glennFile, shots] = a;
  await cmd('Network.setCookie', { name: 'pgvigil_session', value: cookie, url: U });
  await open(U + '#/customreports', `!!document.querySelector('main h2')`); await theme('light');
  // (1) every tool clicked and run on the reader's SQL Server page and the PostgreSQL page (the 19 of B1 and its four)
  for (const [inst, label] of [[msr, 'sqlserver'], [pga, 'postgres']]) {
    await open(U + `#/community?i=${inst}`, communityReady);
    const names = await ev(`[...document.querySelectorAll('main table.grid button.link')].map(b => b.textContent.trim())`);
    for (const name of names) {
      const row = { inst: label, tool: name };
      const off = await ev(`(() => { const b = [...document.querySelectorAll('main table.grid button.link')].find(x => x.textContent.trim() === ${JSON.stringify(name)}); return b.getAttribute('aria-disabled') === 'true' ? b.title : ''; })()`);
      if (off) { row.result = 'off'; row.why = off.slice(0, 160); out.rows.push(row); continue; }
      await ev(`[...document.querySelectorAll('main table.grid button.link')].find(x => x.textContent.trim() === ${JSON.stringify(name)}).click(); 1`);
      if (name === 'SQL Server Diagnostic Queries') {
        if (!await until(`!!document.querySelector('main input[type=file]')`)) { row.result = 'no panel'; out.rows.push(row); continue; }
        const doc = await cmd('DOM.getDocument', { depth: -1 });
        const f = await cmd('DOM.querySelector', { nodeId: doc.result.root.nodeId, selector: 'main input[type=file]' });
        await cmd('DOM.setFileInputFiles', { files: [glennFile], nodeId: f.result.nodeId });
        if (!await until(`[...document.querySelectorAll('main button.link')].some(b => b.textContent === 'Database List')`)) { row.result = 'no queries'; row.text = await ev(`document.querySelector('main [role=status]')?.textContent`); out.rows.push(row); continue; }
        row.queries = [];
        for (const qn of ['Version Info', 'Database List']) {
          await ev(`[...document.querySelectorAll('main button.link')].find(b => b.textContent === ${JSON.stringify(qn)}).click(); 1`);
          const done = await until(`[...document.querySelectorAll('main summary')].some(s => /^Query \\d+: the text sent/.test(s.textContent)) && !!document.querySelector('main .report-result') && !/^Running query/.test(document.querySelector('main .report-result')?.closest('div')?.textContent ?? '')`, 60000);
          row.queries.push({ q: qn, done, badge: await ev(`document.querySelector('main .report-result .badge')?.textContent ?? ''`), grid: await ev(`!!document.querySelector('main .report-result table.grid')`), error: await ev(`!!document.querySelector('main .report-result .error')`) });
        }
        row.result = row.queries.every(x => x.done && x.badge === 'done' && x.grid && !x.error) ? 'ran' : 'not ran';
        out.rows.push(row); continue;
      }
      const runLabel = 'Run ' + name;
      if (!await until(`[...document.querySelectorAll('main button')].some(b => b.textContent === ${JSON.stringify(runLabel)})`, 30000)) { row.result = 'no form'; row.text = await ev(`document.querySelector('main .error')?.textContent ?? ''`); out.rows.push(row); continue; }
      row.filled = await ev(`document.querySelector('main .preset')?.textContent ?? ''`);
      row.sessionInput = await ev(`[...document.querySelectorAll('main input')].find(i => /^@session_name/.test(i.getAttribute('aria-label') || ''))?.value ?? null`);
      await ev(`[...document.querySelectorAll('main button')].find(b => b.textContent === ${JSON.stringify(runLabel)}).click(); 1`);
      const ran = await until(`/^Ran at/.test([...document.querySelectorAll('main [role=status]')].pop()?.textContent ?? '') || !!document.querySelector('main section .error')`, 75000);
      row.result = ran ? await ev(`/^Ran at/.test([...document.querySelectorAll('main [role=status]')].pop()?.textContent ?? '') ? 'ran' : 'error'`) : 'timeout';
      row.badge = await ev(`document.querySelector('main .report-result .badge')?.textContent ?? ''`);
      row.error = await ev(`document.querySelector('main section .error')?.textContent?.slice(0, 160) ?? ''`);
      row.note = await ev(`document.querySelector('main .report-result .refused')?.textContent?.slice(0, 160) ?? ''`);
      out.rows.push(row);
    }
    await shot(shots, `live-${label}-light`);
  }
  // (2) the sa page: every tool off; keyboard reach, the accessibility tree's description, a mouse click sends nothing; the look
  await open(U + `#/community?i=${msa}`, communityReady);
  out.msaTab = await tabWalk(220);
  out.msaAx = await axOff();
  out.msaClick = await clickOff('main table.grid button.link[aria-disabled="true"]');
  out.look = { light: await look('main table.grid button.link[aria-disabled="true"]') };
  await shot(shots, 'live-msa-light');
  await theme('dark'); await open(U + `#/community?i=${msa}`, communityReady);
  out.look.dark = await look('main table.grid button.link[aria-disabled="true"]');
  await shot(shots, 'live-msa-dark');
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }, { name: 'forced-colors', value: 'active' }] });
  await sleep(400);
  out.look.forced = await look('main table.grid button.link[aria-disabled="true"]');
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] }); await theme('light');
  // (3) the DOM check: wave 4's pages, signed in and on the -no-login serve; the self-test first
  await open(U + `#/community?i=${msa}`, communityReady);
  const before = await offCheck('selftest');
  await ev(`(() => { const b = document.createElement('button'); b.textContent = 'planted'; b.setAttribute('aria-disabled', 'true'); document.querySelector('main').append(b); return 1; })()`);
  const planted = await offCheck('selftest');
  out.selftest = { before: before.bad.length, after: planted.bad.length, names: planted.bad };
  for (const [base, tag] of [[U, 'signed in'], [U2, '-no-login']]) {
    for (const [hash, ready] of [['#/customreports', `!!document.querySelector('main h2')`], [`#/customreports?report=${srep}`, `[...document.querySelectorAll('main button')].some(b => b.textContent === 'Run')`],
      [`#/community?i=${msr}`, communityReady], [`#/community?i=${msa}`, communityReady], [`#/community?i=${pga}`, communityReady], ['#/reportmail', `[...document.querySelectorAll('main button')].some(b => /New schedule/.test(b.textContent))`]]) {
      await open(base + hash, ready);
      out.dom.push(await offCheck(`${tag} ${hash}`));
    }
  }
  await open(U2 + `#/community?i=${msr}`, communityReady);
  out.nologinClick = await clickOff('main table.grid button.link[aria-disabled="true"]');
  out.nologinAx = (await axOff()).slice(0, 3);
  await shot(shots, 'nologin-msr-light');
} else {
  const [U4, dms, dpg, realMsr, shots] = a;
  out.demo = [];
  for (const t of ['light', 'dark']) {
    await open(U4 + '#/summary', `!!document.querySelector('main')`); await theme(t);
    for (const [inst, label] of [[dms, 'sqlserver'], [dpg, 'postgres']]) {
      await open(U4 + `#/community?i=${inst}`, communityReady);
      const s = await ev(`(() => { const bs = [...document.querySelectorAll('main table.grid button.link')];
        const desc = b => (b.getAttribute('aria-describedby') || '').split(/\\s+/).map(i => document.getElementById(i)?.textContent ?? '').join(' ');
        return { n: bs.length, off: bs.filter(b => b.getAttribute('aria-disabled') === 'true' && /is a demo instance/.test(desc(b))).length,
          box: document.querySelector('main .needs')?.textContent?.slice(0, 200) ?? '', error: !!document.querySelector('main .error'), nologin: /-no-login/.test(document.querySelector('main')?.textContent ?? '') }; })()`);
      s.label = `${t} ${label}`;
      if (t === 'light') { s.click = await clickOff('main table.grid button.link[aria-disabled="true"]'); s.ax = (await axOff()).slice(0, 2); s.dom = await offCheck(`demo ${label}`); }
      out.demo.push(s);
      await shot(shots, `demo-${label}-${t}`);
    }
  }
  // the fleet page's picker reaches the same state
  await open(U4 + '#/community', `!!document.querySelector('main select')`);
  await ev(`(() => { const s = document.querySelector('main select'); s.value = ${JSON.stringify(String(dms))}; s.dispatchEvent(new Event('change')); return 1; })()`);
  await until(communityReady);
  out.picker = await ev(`(() => { const bs = [...document.querySelectorAll('main table.grid button.link')]; return { n: bs.length, off: bs.filter(b => b.getAttribute('aria-disabled') === 'true').length, box: document.querySelector('main .needs')?.textContent?.slice(0, 120) ?? '' }; })()`);
  // the real instance served beside the demo's: its own state, never the demo line
  await open(U4 + `#/community?i=${realMsr}`, communityReady);
  out.real = await ev(`(() => { const m = document.querySelector('main')?.textContent ?? ''; return { demoLine: /is a demo instance/.test(m), nologin: /-no-login/.test(m), off: [...document.querySelectorAll('main table.grid button.link')].filter(b => b.getAttribute('aria-disabled') === 'true').length }; })()`);
}
console.log(JSON.stringify(out));
ws.close(); process.exit(0);
JS
  SHOTS=${PGVIGIL_SHOTS:-$WORK/shots}
  if [[ -z "$SKIP_MSSQL" ]]; then
    timeout 1500 node "$WORK/buttons.mjs" live "$CDP" "$U/" "$COOKIE" "$U2/" "$MRID" "$MAID" "$AID" "$SREP" "$WORK/glenn.sql" "$SHOTS" > "$WORK/buttons.json" 2>"$WORK/buttons.err" || fail "U2: the live driver: $(tail -5 "$WORK/buttons.err")"
    python3 - "$WORK/buttons.json" <<'PY' || fail "U2: see above"
import json, sys
d = json.load(open(sys.argv[1])); rows = d['rows']; bad = []
for r in rows:
    tag = f"{r['inst']} {r['tool']}"
    good = r.get('result') == 'ran' and (r['tool'] == 'SQL Server Diagnostic Queries' or (r.get('badge') == 'done' and not r.get('error')))
    extra = json.dumps(r['queries']) if r.get('queries') else (r.get('error') or r.get('note') or r.get('why') or '')[:140]
    print(('ok   ' if good else 'FAIL ') + f"U2: {tag}: {r.get('result')} {r.get('badge', '')} {extra}")
    if not good: bad.append(tag)
n_ms = sum(1 for r in rows if r['inst'] == 'sqlserver'); n_pg = sum(1 for r in rows if r['inst'] == 'postgres')
assert n_ms == 14 and n_pg == 10, f"U2: {n_ms} SQL Server and {n_pg} PostgreSQL tools on the pages, not 14 and 10"
assert not bad, f"U2: {len(bad)} tool(s) did not end 'Ran at' with done: {bad}"
print(f"ok   U2: all {n_ms + n_pg} tools clicked and run on the rig: each ended 'Ran at' with done (Glenn's two fixture queries with their grids)")
bv = next(r for r in rows if r['tool'] == 'sp_HumanEventsBlockViewer')
assert bv.get('sessionInput') == 'system_health' and 'system_health' in (bv.get('filled') or ''), f"U2: sp_HumanEventsBlockViewer's default click: {bv}"
print(f"ok   U2: sp_HumanEventsBlockViewer's default click (threshold 0): @session_name filled system_health, said ('{bv['filled'][:90]}'), done")
ax, tab = d['msaAx'], d['msaTab']
assert len(ax) == 14 and all(x['same'] for x in ax), f"U2: the sa page's off tools in the accessibility tree: {[(x['name'], x['same'], x['axDesc'][:60]) for x in ax]}"
assert sorted(tab) == sorted(x['name'] for x in ax), f"U2: Tab reached {len(tab)} of the {len(ax)} off tools: {sorted(set(x['name'] for x in ax) - set(tab))} missing"
print(f"ok   U2: pgcr-msa: Tab reaches all {len(tab)} off tools; each one's accessibility-tree description is the reason beside it ('{ax[0]['axDesc'][:70]}')")
c = d['msaClick']; assert c['clicked'] and c['sent'] == 0 and not c['error'], f"U2: a mouse click on an off tool: {c}"
lk = d['look']
for t in ('light', 'dark'):
    x = lk[t]; assert x['deco'] == 'none' and x['color'] != x['accent'] and x['cursor'] == 'not-allowed', f"U2: the off look in {t}: {x}"
assert lk['forced']['color'] == lk['forced']['gray'], f"U2: under forced colours the off tool is {lk['forced']['color']}, GrayText is {lk['forced']['gray']}"
print(f"ok   U2: a mouse click on {c['clicked']} sent nothing; off drawn muted, no underline, not-allowed (light {lk['light']['color']}, dark {lk['dark']['color']}), GrayText under forced colours ({lk['forced']['color']})")
st = d['selftest']; assert st['after'] == st['before'] + 1 and any('planted' in n for n in st['names']), f"U2: the self-test: {st}"
print(f"ok   U2: the DOM check's self-test: a planted off button without a reason counted ({st['before']} -> {st['after']})")
for p in d['dom']:
    print(('ok   ' if not p['bad'] else 'FAIL ') + f"U2: DOM {p['label']}: {p['off']} off control(s), {len(p['bad'])} without a visible reason {p['bad'][:4]}")
domBad = [p for p in d['dom'] if p['bad']]
nl = [p for p in d['dom'] if p['label'].startswith('-no-login')]
assert all(p['off'] > 0 for p in nl), f"U2: a -no-login page with no off control: {[(p['label'], p['off']) for p in nl]}"
c = d['nologinClick']; assert c['clicked'] and c['sent'] == 0, f"U2: a click on the -no-login serve: {c}"
assert not domBad, f"U2: {len(domBad)} page(s) with an off control without its reason"
print(f"ok   U2: -no-login: a click on {c['clicked']} sent nothing")
PY
  else NOTPROVEN+=("U2: the live page rows need the SQL Server part"); fi
  # the demo seeded into this proof's repository beside its real instances, served by pgvigil demo (no login, no doors)
  PORT4=$(freeport); U4="http://127.0.0.1:$PORT4"
  "$BIN" demo -config "$CFG" -days 1 -serve -listen "127.0.0.1:$PORT4" > "$WORK/demo.log" 2>&1 & SRV4=$!
  for _ in $(seq 1 300); do grep -q 'pgvigil demo serving' "$WORK/demo.log" && break; kill -0 "$SRV4" 2>/dev/null || fail "U2: the demo serve died: $(tail -5 "$WORK/demo.log")"; sleep 1; done
  grep -q 'pgvigil demo serving' "$WORK/demo.log" || fail "U2: the demo did not come up in 300 s: $(tail -3 "$WORK/demo.log")"
  DMS=$(q "select instance_id from pgvigil.instances where 'demo' = any (tags) and engine = 'sqlserver' order by name limit 1")
  DPG=$(q "select instance_id from pgvigil.instances where 'demo' = any (tags) and engine = 'postgres' order by name limit 1")
  [[ -n $DMS && -n $DPG ]] || fail "U2: the demo seeded no SQL Server or no PostgreSQL instance"
  timeout 900 node "$WORK/buttons.mjs" demo "$CDP" "$U4/" "$DMS" "$DPG" "${MRID:-$AID}" "$SHOTS" > "$WORK/demo.json" 2>"$WORK/demo.err" || fail "U2: the demo driver: $(tail -5 "$WORK/demo.err")"
  python3 - "$WORK/demo.json" "${MRID:+sqlserver}" <<'PY' || fail "U2: see above"
import json, sys
d = json.load(open(sys.argv[1])); real_ms = sys.argv[2] == 'sqlserver'
for s in d['demo']:
    want = 14 if s['label'].endswith('sqlserver') else 10
    assert s['n'] == want and s['off'] == want and 'is a demo instance' in s['box'] and not s['error'] and not s['nologin'], f"U2: demo {s['label']}: {s}"
    if 'click' in s:
        assert s['click']['sent'] == 0 and all(x['same'] for x in s['ax']) and not s['dom']['bad'], f"U2: demo {s['label']}: click {s['click']}, ax {s['ax']}, dom {s['dom']}"
    print(f"ok   U2: demo {s['label']}: {s['off']} of {s['n']} tools off with the demo line beside them and as their description; no error box" + (f"; a click sent nothing" if 'click' in s else ''))
p = d['picker']; assert p['n'] == 14 and p['off'] == 14 and 'is a demo instance' in p['box'], f"U2: the fleet page's picker on the demo: {p}"
print(f"ok   U2: demo fleet page, picker: the same 14 off with the demo line")
r = d['real']
assert not r['demoLine'] and r['nologin'], f"U2: the real instance served beside the demo: {r}"
print(f"ok   U2: pgvigil demo -serve -config: the real instance shows its own state (-no-login, {r['off']} off), never the demo line")
PY
fi

echo
for n in "${NOTPROVEN[@]}"; do echo "NOT PROVEN: $n"; done
echo "PASS proof-customreports ($(nruns) runs)$([[ ${#NOTPROVEN[@]} -gt 0 ]] && echo ", with ${#NOTPROVEN[@]} part(s) not proven")"
