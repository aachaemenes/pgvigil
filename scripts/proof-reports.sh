#!/usr/bin/env bash
# Proof of the Reports tree (task 169: migration 0105, the collections mssql_reports and reports, GET /api/reports,
# web/src/reports.ts): every stock report on SQL Server 2022 and PostgreSQL 16, its rows against a hand read of the
# server, its page in a headless browser, its export.
#
# Needs: docker, psql, curl, python3, go, node, npm, chromium and ss, at the repository root. It starts and removes two
# containers of its own - mcr.microsoft.com/mssql/server:2022-latest (a throwaway sa password made here, never
# printed) and postgres:16 (pg_stat_statements loaded, the log collector on, a throwaway superuser password) - and uses
# the PostgreSQL one as both the repository (database pgvigil_repo) and the monitored server (database postgres).
# The routes and the tabs are the lead's files (web.go, router.ts, main.ts): a tree without /api/reports is built
# with the patch named in PGVIGIL_REPORTS_WIRING applied to a scratch copy. PGVIGIL_REPORTS_SHOTS names a folder for
# the page shots (each report, light and dark); not set, none are kept. PGVIGIL_REPORTS_KEEP=1 leaves both containers
# (the repository database with them) and the scratch folder in place at the end, pass or fail, and prints their names,
# ports and the repository's DSN without its password, for a probe in place; serve and Chromium are stopped either way.
# The names never take an existing container's: a kept pair stays out of a later run's way.
#
# Expected (written before the first run; the review fold of run 1 changed B to E as marked [fold]):
#  A. migrate applies 0105; its eight tables exist; pgvigil_collector may execute import_mssql_reports and
#     import_reports and may not select mssql_sql_logins; pgvigil_reader may select every 0105 table and may not
#     execute the imports. import_mssql_reports refuses a PostgreSQL instance ("is not a SQL Server instance"),
#     import_reports a SQL Server one ("is not a PostgreSQL instance").
#  B. mssql_reports as sa on SQL Server 2022, the container's clock in America/Los_Angeles [fold] (no "partial"): the
#     role members stored equal sa's count of sys.server_role_members and its sysadmin list; the SQL logins equal
#     sys.sql_logins (no ##...## login); rp_old's password_set_at falls between the shell's UTC clock read just before
#     and just after its CREATE LOGIN (to the second) [fold: an independent clock, not the code's own conversion]; the
#     database properties equal sys.extended_properties class 0 summed over every database (rp169 carries two of its
#     own); rp169.dbo.rp_big's row count is 5,000 and its reserved KB equals sys.dm_db_partition_stats'; mssql_service_ext
#     holds one row per sys.dm_server_services row; every report_read_state part, failed_logins too, says 'read'.
#  C. rp-ms-vss read once as sa (its DSN swapped), then as a login with VIEW SERVER STATE only: "partial";
#     role_members, sql_logins, extended_properties and table_sizes say 'no right' naming VIEW ANY DEFINITION
#     [fold: table sizes need it too], services 'read'; the role members, logins and properties the sa read stored for
#     rp-ms-vss are kept, every one still present [fold: a check that can fail].
#  D. reports on PostgreSQL 16: as the superuser, the comment of database postgres is stored as property 'comment';
#     the methods of rp_md5 / rp_scram / rp_nopw are md5 / scram-sha-256 / none (equal to a hand read of pg_authid);
#     rp-pg-low read once as the superuser (its DSN swapped), then as a pg_monitor login that is no superuser:
#     passwords says 'no right' (not a failure, no "partial") and the methods stored by the first read are kept.
#  E. the API, each report against a hand read: props (SQL Server: the class-0 count; PostgreSQL: the commented
#     databases); finder (SQL Server: sys.databases without snapshots, with and without the system ones; PostgreSQL:
#     pg_database without templates, without and with 'postgres'; a search 'rp16' finds rp169 alone); deadlocks (two
#     SQL Server deadlocks of the same two statements, the second session the victim each time (DEADLOCK_PRIORITY
#     LOW); two PostgreSQL ones, the second session the victim each time (its deadlock_timeout 100 ms, the first's 10 s,
#     started once the first sleeps) [fold]); failed (rp_old's three wrong passwords on SQL Server = sa's count in the
#     error log, read by mssql_reports [fold: the error log reader passes these lines over]; rp_app's two on
#     PostgreSQL = the server log's count; the server summary for rp-ms says 'read' and counts every 'Login failed'
#     line of the current log [run 4: a fourth such line, not rp_old's], bounded by sa's count up to the collection's start
#     and up to a time after its end, and the Detail as many rows; a line not rp_old's after the server answered fails,
#     with its time [fold]); flushed (the default trace's rows
#     = its count of DBCC FREEPROCCACHE; the error log's 'cachestore flush' rows = xp_readerrorlog's count in the
#     current and the first archived log [fold]); killed (2) and actions (3) for the three seeded actions_log rows;
#     roles (sysadmin = sa's list; superuser = pg_roles' rolsuper list; pg_monitor = its members); pwage (the enabled
#     SQL logins, then with the disabled one; PostgreSQL rp_exp expired with scram-sha-256); services (=
#     sys.dm_server_services, each with its file name); tables (rp_big 5,000 rows, its reserved KB); querystats (the
#     marker statement run 5 times between two reads: 5 executions on PostgreSQL [run 6: pg_stat_statements reset before
#     the marker's first run, and the first read holds the marker]; on SQL Server 5, or 6 when the first
#     read did not take it as a candidate); qscharts (a series for each engine); recycle (the instance made inactive,
#     once). A wrong r= or days= is a 400.
#  F. every report page at the root and the Reports folder of each instance: the page renders its h2 (the report's
#     name), no exception, no error box, its grids named by their h3s (a heading's own text, not its chart menu's; a
#     chart's heading names no grid [run 7]); at the root the rows of the grids that are one
#     API part each equal that part's rows [fold: props, finder, the five failed-login grids, flushed, killed, actions,
#     services, recycle, new and deleted databases (rp169gone, a PostgreSQL database dropped between two reads [run 7:
#     none dropped left the page with no grid to export]), the role members of sysadmin / superuser]; the Deadlocks page shows
#     2 signatures with 2 occurrences each, 4 deadlocks and 8 participants, and a Graph draws 2 processes; the Deadlock
#     Charts page draws 6 rings, the five with data (all but Procedure) not empty [fold] (Procedure draws one slice,
#     '(none)': the deadlocks run no procedure); the Reports strip lists 17
#     pages at the root, 12 on a SQL Server instance and 10 on a PostgreSQL one [fold: the group's own strip].
#     [169b] The tree (tree.ts): the root's Reports folder lists the 17 stock pages in DBA Dash's order, then Custom
#     reports and Community tools; Custom reports holds the three seeded reports as DBA Dash's Reports folder holds
#     its own (sub folders first by name, then the reports by name: Ops > Daily > rp169 tree pg, Ops > rp169 tree
#     store, rp169 tree ms); under an instance its engine's and the repository's (PostgreSQL: Ops > Daily > rp169 tree
#     pg, Ops > rp169 tree store; SQL Server: Ops > rp169 tree store alone, rp169 tree ms); each report node clicked opens #/customreports?report=N (&i=<id> under an
#     instance) and the page's h2 is the report's name; Community tools opens #/community (?i= under an instance).
#     The Deadlock Charts and Query Stats Charts rings are rings with a hole half their radius (each slice an outer arc
#     and an inner one of radius 27, a whole slice a circle of radius 40.5 stroked 27 wide: DBA Dash's InnerRadius 0.5); the PostgreSQL instance's Databases by size stays a pie (each wedge from the centre).
#  G. each page's Export .xlsx (16: every page with a grid) gives a workbook that opens (openpyxl where the box has
#     it, else the zip's workbook.xml) with a sheet, after its own Summary sheet, for every grid heading of its page that
#     holds rows [fold: all 16; run 8: an empty grid (pgaudit's, not in the image) shows a note, not a table, and the
#     shell's export takes tables]; every grid F wants holds rows on this seed [fold]. [169b] An empty grid is a sheet
#     too, its header row alone with as many cells as the grid's columns, as DBA Dash exports one (CommonShared.cs
#     SaveDataGridViewsToXLSX); at least one such sheet (pgaudit's grid on User Actions).
#  H. NOT PROVEN HERE: SQL Server 2016-2019 and 2025 (the reads use no column newer than 2012 but LOGINPROPERTY's
#     values were read on 2022 only), Azure SQL Managed Instance and Amazon RDS (where sys.dm_server_services lists
#     little), PostgreSQL 13 / 18, a fleet over 25 PostgreSQL instances with deadlocks (the page reads 25), a pass
#     the deadline cuts (the rotation), an availability group secondary (not entered), a binary extended property,
#     pgaudit's ROLE / DDL grid with rows (pgaudit is not in the image), the query stats grids' rows against the API
#     (the page's range moves with now), the Query Stats Charts' four line charts drawn (the window holds one
#     5-minute point when both engines' deltas fall in one step: each chart then says it needs two; a run whose deltas
#     cross a step boundary draws them, unchecked), PostgreSQL query stats with pg_stat_statements over the collector's 500 + 200
#     pick (the proof resets it before the marker), and a statement's calls before its first pick (never a delta).
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$HOME/go/bin:/usr/local/go/bin:$PATH
for t in docker psql curl python3 go node npm chromium setsid ss; do command -v $t >/dev/null || { echo "FAIL: $t missing" >&2; exit 1; }; done
[ -f go.mod ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
SUF=$RANDOM; WORK=$(mktemp -d); PCT=; MCT=; SRVPID=; CHRPID=
while docker container inspect "pgv169-pg-$SUF" >/dev/null 2>&1 || docker container inspect "pgv169-ms-$SUF" >/dev/null 2>&1; do SUF=$RANDOM; done
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { local rc=$?; set +e; trap - EXIT INT TERM
  for p in "$SRVPID" "$CHRPID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "$SRVPID" "$CHRPID"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  if [ "${PGVIGIL_REPORTS_KEEP:-}" = 1 ]; then
    local up=
    [ -n "$PCT" ] && docker container inspect "$PCT" >/dev/null 2>&1 && up+=" $PCT (PostgreSQL 16 on 127.0.0.1:${PPORT:-?}; the repository: host=127.0.0.1 port=${PPORT:-?} user=postgres dbname=pgvigil_repo, its password in $WORK/pgenv)"
    [ -n "$MCT" ] && docker container inspect "$MCT" >/dev/null 2>&1 && up+=" $MCT (SQL Server 2022 on 127.0.0.1:${MPORT:-?}, sa's password in $WORK/msenv)"
    echo "KEEP: left up:${up:- no container}; the scratch folder $WORK; remove with: docker rm -f -v $PCT $MCT; rm -rf $WORK"
  else
    [ -n "$PCT" ] && docker rm -f -v "$PCT" >/dev/null 2>&1
    [ -n "$MCT" ] && docker rm -f -v "$MCT" >/dev/null 2>&1
    rm -rf "$WORK"
  fi
  exit $rc; }
trap cleanup EXIT INT TERM
echo "load: $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs (shared box; no check here measures time)"

# --- the scratch build: the tree, the wiring where it lacks it, the bundle, the binary
mkdir -p "$WORK/src"; tar --exclude=./web/node_modules --exclude=./.git --exclude=./bin -cf - . | tar -C "$WORK/src" -xf -
if grep -q '/api/reports' internal/web/web.go; then echo "binary: wired in this tree"
else
  : "${PGVIGIL_REPORTS_WIRING:?the tree lacks /api/reports: name the wiring patch in PGVIGIL_REPORTS_WIRING}"
  (cd "$WORK/src" && git apply "$(realpath "$PGVIGIL_REPORTS_WIRING")") || fail "the wiring patch does not apply"
  echo "binary: wired in a scratch build (the join applies the same patch)"
fi
(cd "$WORK/src/web" && npm ci --silent >/dev/null 2>&1 && npm run --silent build >/dev/null 2>&1) || fail "the bundle did not build"
(cd "$WORK/src" && CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil) || fail "the binary did not build"
BIN=$WORK/pgvigil

rnd() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# a port in [lo, hi] that no TCP socket on this host holds as its local port (listening or connected, any address).
# The callers' ranges sit below the kernel's ephemeral range (32768-60999 by default), where outgoing connections take
# their local ports. A port taken between this check and the bind is met by the callers' retry on a fresh port.
freeport() { local lo=$1 hi=$2 p used
  used=$(ss -Htan) || fail "ss -Htan failed: the ports in use cannot be read"
  used=$(awk '{n = split($4, a, ":"); print a[n]}' <<<"$used" | sort -u)
  for _ in $(seq 1 50); do
    p=$((lo + RANDOM % (hi - lo + 1)))
    grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }
  done
  fail "no free port in $lo-$hi"
}
# docker run with -p 127.0.0.1:<a free port>:<cport> and the rest of the arguments (options first, then the image);
# a port taken after the check ('port is already allocated', 'address already in use') = the container removed and a
# fresh port, 3 tries; prints the host port
dstart() { local name=$1 lo=$2 hi=$3 cport=$4 what=$5 p; shift 5
  for _ in 1 2 3; do
    p=$(freeport "$lo" "$hi") || exit 1   # a command substitution runs without set -e: an empty port would let docker pick one
    if docker run -d --name "$name" -p "127.0.0.1:$p:$cport" "$@" >/dev/null 2>"$WORK/drun.err"; then echo "$p"; return 0; fi
    docker rm -f -v "$name" >/dev/null 2>&1 || true
    grep -qiE 'already allocated|address already in use' "$WORK/drun.err" || break
  done
  fail "docker run $what: $(tail -2 "$WORK/drun.err")"
}
# --- the two servers
PW="pw$(rnd)"; LPW="lw$(rnd)"; MSPW="Pv9$(rnd)"; VPW="Vv9$(rnd)"
PCT="pgv169-pg-$SUF"; MCT="pgv169-ms-$SUF"
printf 'POSTGRES_PASSWORD=%s\n' "$PW" > "$WORK/pgenv"; printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nMSSQL_PID=Developer\nMSSQL_AGENT_ENABLED=true\nMSSQL_MEMORY_LIMIT_MB=2048\nTZ=America/Los_Angeles\n' "$MSPW" > "$WORK/msenv"
chmod 600 "$WORK/pgenv" "$WORK/msenv"   # the passwords off the command line
PPORT=$(dstart "$PCT" 21000 24999 5432 postgres:16 --env-file "$WORK/pgenv" postgres:16 \
  -c shared_preload_libraries=pg_stat_statements -c logging_collector=on -c log_directory=log \
  -c "log_line_prefix=%m [%p] %q%u@%d " -c deadlock_timeout=200ms)
MPORT=$(dstart "$MCT" 25000 28999 1433 'SQL Server 2022' --env-file "$WORK/msenv" mcr.microsoft.com/mssql/server:2022-latest)
export PGPASSWORD=$PW SQLCMDPASSWORD=$MSPW VPW
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
ADM="host=127.0.0.1 port=$PPORT user=postgres"
sq() { psql "$ADM dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
q() { psql "$ADM dbname=pgvigil_repo" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# the sa password reaches sqlcmd through the environment, by name; VPW, the seeded logins' password, the same way as the
# scripting variable $(VPW): never on a command line another user can list
ms() { docker exec -e SQLCMDPASSWORD -e VPW "$MCT" $SQLCMD -S localhost -U sa -C -I -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# SQL with a password in it goes to psql on stdin
sqin() { psql "$ADM dbname=${1:-postgres}" -XAtq -v ON_ERROR_STOP=1 -f -; }
for _ in $(seq 1 60); do sq "select 1" >/dev/null 2>&1 && break; sleep 1; done
sq "select 1" >/dev/null || fail "PostgreSQL 16 never answered"
for _ in $(seq 1 120); do ms "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
ms "SELECT 1" >/dev/null || fail "SQL Server 2022 never answered: $(docker logs "$MCT" 2>&1 | tail -3)"
TREADY=$(date -u +%s)   # SQL Server answers: a failed login not rp_old's after this is not the server's start
echo "servers: PostgreSQL $(sq "show server_version"), SQL Server $(ms "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))") (offset from UTC $(ms "SELECT DATEPART(TZOFFSET, SYSDATETIMEOFFSET())") min)"

# --- the seeds
sq "create database pgvigil_repo" >/dev/null
sq "create extension pg_stat_statements" >/dev/null
sq "comment on database postgres is 'the proof''s monitored database'" >/dev/null
printf "set password_encryption = 'md5'; create role rp_md5 login password 'md5%s';\n" "$(rnd)" | sqin >/dev/null
printf "create role rp_scram login password 'sc%s'; create role rp_nopw login; create role rp_exp login password 'ex%s' valid until '2020-01-01';\n" "$(rnd)" "$(rnd)" | sqin >/dev/null
printf "create role rp_app login password '%s'; create role rp_low login password '%s' in role pg_monitor;\n" "$LPW" "$LPW" | sqin >/dev/null
sq "create table public.rp_dl (id int primary key, v int); insert into public.rp_dl values (1, 0), (2, 0); create table public.rp_pgbig as select g as id, md5(g::text) as t from generate_series(1, 5000) g" >/dev/null
ms "CREATE DATABASE rp169" >/dev/null
ms "CREATE TABLE dbo.rp_big (id int IDENTITY PRIMARY KEY, t char(100) NOT NULL DEFAULT 'x'); INSERT dbo.rp_big (t) SELECT TOP (5000) 'x' FROM sys.all_columns a CROSS JOIN sys.all_columns b;
    CREATE TABLE dbo.dl_a (id int PRIMARY KEY, v int); CREATE TABLE dbo.dl_b (id int PRIMARY KEY, v int); INSERT dbo.dl_a VALUES (1, 0); INSERT dbo.dl_b VALUES (1, 0);
    EXEC sys.sp_addextendedproperty @name = N'Owner', @value = N'team-a'; EXEC sys.sp_addextendedproperty @name = N'Purpose', @value = N'the reports proof';" rp169 >/dev/null
T0=$(date -u +%s)
ms 'CREATE LOGIN rp_old WITH PASSWORD = '"'"'$(VPW)'"'"', CHECK_POLICY = OFF;' >/dev/null
T1=$(date -u +%s)
ms 'CREATE LOGIN rp_admin WITH PASSWORD = '"'"'$(VPW)'"'"', CHECK_POLICY = OFF; ALTER SERVER ROLE sysadmin ADD MEMBER rp_admin;
    CREATE LOGIN rp_dis WITH PASSWORD = '"'"'$(VPW)'"'"', CHECK_POLICY = OFF; ALTER LOGIN rp_dis DISABLE;
    CREATE LOGIN rp_vss WITH PASSWORD = '"'"'$(VPW)'"'"', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO rp_vss;' >/dev/null
[ "$(ms "SELECT COUNT(*) FROM sys.sql_logins WHERE name IN ('rp_old', 'rp_admin', 'rp_dis', 'rp_vss')")" = 4 ] || fail "setup: the four logins"
export PGVIGIL_REPO_DSN="$ADM password=$PW dbname=pgvigil_repo" MON_DSN="$ADM password=$PW dbname=postgres" \
       LOW_DSN="host=127.0.0.1 port=$PPORT user=rp_low password=$LPW dbname=postgres" \
       MS_DSN="sqlserver://sa:$MSPW@127.0.0.1:$MPORT?database=master&encrypt=true&TrustServerCertificate=true" \
       MSV_DSN="sqlserver://rp_vss:$VPW@127.0.0.1:$MPORT?database=master&encrypt=true&TrustServerCertificate=true"
CFG=$WORK/cfg.yaml
cat > "$CFG" <<'EOF'
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: rp-pg
    dsn: env:MON_DSN
  - name: rp-pg-low
    dsn: env:LOW_DSN
  - name: rp-gone
    dsn: env:MON_DSN
  - name: rp-ms
    engine: sqlserver
    dsn: env:MS_DSN
  - name: rp-ms-vss
    engine: sqlserver
    dsn: env:MSV_DSN
EOF
col() { local out; out=$("$BIN" collect -config "$CFG" -once "$1" -instance "$2" 2>&1) || fail "collect $1 on $2: $out"; printf '%s\n' "$out"; }

echo "--- A. migrate and the roles"
"$BIN" migrate -config "$CFG" >/dev/null || fail "A: migrate"
[ "$(q "select count(*) from pgvigil.schema_version where version = '0105_reports.sql'")" = 1 ] || fail "A: 0105 not applied"
T7="'pgvigil.report_read_state','pgvigil.mssql_server_role_members','pgvigil.mssql_sql_logins','pgvigil.mssql_service_ext','pgvigil.mssql_table_size','pgvigil.pg_role_passwords','pgvigil.report_db_properties','pgvigil.mssql_failed_logins'"
[ "$(q "select count(*) from pg_class where oid in (select x::regclass from unnest(array[$T7]) x)")" = 8 ] || fail "A: the eight tables"
[ "$(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_mssql_reports(int, timestamptz, jsonb)', 'execute') and has_function_privilege('pgvigil_collector', 'pgvigil.import_reports(int, timestamptz, jsonb)', 'execute') and not has_table_privilege('pgvigil_collector', 'pgvigil.mssql_sql_logins', 'select')")" = t ] || fail "A: the collector's rights"
[ "$(q "select bool_and(has_table_privilege('pgvigil_reader', x, 'select')) from unnest(array[$T7]) x")" = t ] || fail "A: the reader cannot select a 0105 table"
[ "$(q "select not has_function_privilege('pgvigil_reader', 'pgvigil.import_mssql_reports(int, timestamptz, jsonb)', 'execute') and not has_function_privilege('pgvigil_reader', 'pgvigil.import_reports(int, timestamptz, jsonb)', 'execute')")" = t ] || fail "A: the reader may execute an import"
for i in rp-pg rp-pg-low rp-gone; do col instance "$i" >/dev/null; done
for i in rp-ms rp-ms-vss; do col mssql_instance "$i" >/dev/null; done
IPG=$(q "select instance_id from pgvigil.instances where name = 'rp-pg'"); IPL=$(q "select instance_id from pgvigil.instances where name = 'rp-pg-low'")
IGONE=$(q "select instance_id from pgvigil.instances where name = 'rp-gone'"); IMS=$(q "select instance_id from pgvigil.instances where name = 'rp-ms'")
IMV=$(q "select instance_id from pgvigil.instances where name = 'rp-ms-vss'")
[ -n "$IPG" ] && [ -n "$IPL" ] && [ -n "$IGONE" ] && [ -n "$IMS" ] && [ -n "$IMV" ] || fail "A: the instances were not registered"
if OUT=$(q "select pgvigil.import_mssql_reports($IPG, now(), '[]'::jsonb)" 2>&1); then fail "A: import_mssql_reports took a PostgreSQL instance"; fi
[[ "$OUT" == *"is not a SQL Server instance"* ]] || fail "A: import_mssql_reports' refusal: $OUT"
if OUT=$(q "select pgvigil.import_reports($IMS, now(), '[]'::jsonb)" 2>&1); then fail "A: import_reports took a SQL Server instance"; fi
[[ "$OUT" == *"is not a PostgreSQL instance"* ]] || fail "A: import_reports' refusal: $OUT"
echo "A: OK"

echo "--- B. mssql_reports as sa"
OUT=$(col mssql_reports rp-ms); echo "  $OUT"
[[ "$OUT" == *partial* ]] && fail "B: the sa read is partial: $OUT"
[ "$(q "select count(*) from pgvigil.mssql_server_role_members where instance_id = $IMS and is_present")" = "$(ms "SELECT COUNT(*) FROM sys.server_role_members")" ] || fail "B: role members $(q "select count(*) from pgvigil.mssql_server_role_members where instance_id = $IMS") vs sa's $(ms "SELECT COUNT(*) FROM sys.server_role_members")"
SYSA=$(ms "SELECT STRING_AGG(m.name, ',') WITHIN GROUP (ORDER BY m.name COLLATE Latin1_General_BIN) FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id WHERE r.name = 'sysadmin'")
[ "$(q "select string_agg(login_name, ',' order by login_name collate \"C\") from pgvigil.mssql_server_role_members where instance_id = $IMS and role_name = 'sysadmin' and is_present")" = "$SYSA" ] || fail "B: the sysadmin list (sa: $SYSA)"
NLOG=$(ms "SELECT COUNT(*) FROM sys.sql_logins WHERE name NOT LIKE '##%##'")
[ "$(q "select count(*) from pgvigil.mssql_sql_logins where instance_id = $IMS and is_present")" = "$NLOG" ] || fail "B: SQL logins vs sa's $NLOG"
PSET=$(q "select floor(extract(epoch from password_set_at)) from pgvigil.mssql_sql_logins where instance_id = $IMS and login_name = 'rp_old'")
[ -n "$PSET" ] && [ "$PSET" -ge $((T0 - 1)) ] && [ "$PSET" -le $((T1 + 1)) ] || fail "B: rp_old's password_set_at $PSET (epoch) is not between the shell's $T0 and $T1 (the server's LOGINPROPERTY: $(ms "SELECT CONVERT(varchar(23), CAST(LOGINPROPERTY('rp_old', 'PasswordLastSetTime') AS datetime), 126)") local)"
[ "$(q "select is_disabled from pgvigil.mssql_sql_logins where instance_id = $IMS and login_name = 'rp_dis'")" = t ] || fail "B: rp_dis is not disabled"
NPROP=$(ms "DECLARE @n int = 0, @c int, @d sysname, @s nvarchar(400); DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE state = 0 AND database_id <> 2 AND source_database_id IS NULL;
  OPEN c; FETCH c INTO @d; WHILE @@FETCH_STATUS = 0 BEGIN SET @s = N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@d) + N'.sys.extended_properties WHERE class = 0'; EXEC sp_executesql @s, N'@c int OUTPUT', @c OUTPUT; SET @n += @c; FETCH c INTO @d; END; SELECT @n")
[ "$(q "select count(*) from pgvigil.report_db_properties where instance_id = $IMS and is_present")" = "$NPROP" ] || fail "B: properties $(q "select count(*) from pgvigil.report_db_properties where instance_id = $IMS") vs sa's $NPROP"
[ "$(q "select string_agg(property || '=' || value, ';' order by property) from pgvigil.report_db_properties where instance_id = $IMS and database_name = 'rp169'")" = "Owner=team-a;Purpose=the reports proof" ] || fail "B: rp169's properties"
RES=$(ms "SELECT SUM(reserved_page_count) * 8 FROM sys.dm_db_partition_stats WHERE object_id = OBJECT_ID('dbo.rp_big')" rp169)
[ "$(q "select row_count || '|' || reserved_kb from pgvigil.mssql_table_size where instance_id = $IMS and database_name = 'rp169' and table_name = 'rp_big'")" = "5000|$RES" ] || fail "B: rp_big's size: $(q "select row_count, reserved_kb from pgvigil.mssql_table_size where instance_id = $IMS and table_name = 'rp_big'") vs 5000|$RES"
[ "$(q "select count(*) from pgvigil.mssql_service_ext where instance_id = $IMS")" = "$(ms "SELECT COUNT(*) FROM sys.dm_server_services")" ] || fail "B: services"
[ "$(q "select string_agg(part || '=' || status, ',' order by part) from pgvigil.report_read_state where instance_id = $IMS")" = "extended_properties=read,failed_logins=read,role_members=read,services=read,sql_logins=read,table_sizes=read" ] || fail "B: the states: $(q "select string_agg(part || '=' || status, ',' order by part) from pgvigil.report_read_state where instance_id = $IMS")"
echo "B: OK"

echo "--- C. rp-ms-vss read as sa, then as a login with VIEW SERVER STATE only"
MSV_DSN="$MS_DSN" col mssql_reports rp-ms-vss >/dev/null
CNT() { q "select (select count(*) from pgvigil.mssql_server_role_members where instance_id = $IMV and is_present) || '|' || (select count(*) from pgvigil.mssql_sql_logins where instance_id = $IMV and is_present) || '|' || (select count(*) from pgvigil.report_db_properties where instance_id = $IMV and is_present)"; }
C_SA=$(CNT)
[[ "$C_SA" =~ ^[1-9][0-9]*\|[1-9][0-9]*\|[1-9][0-9]*$ ]] || fail "C: the sa read of rp-ms-vss stored no role member, login or property: $C_SA"
OUT=$(col mssql_reports rp-ms-vss); echo "  $OUT"
[[ "$OUT" == *partial*"VIEW ANY DEFINITION"* ]] || fail "C: not partial naming VIEW ANY DEFINITION: $OUT"
[ "$(q "select string_agg(part || '=' || status, ',' order by part) from pgvigil.report_read_state where instance_id = $IMV and part <> 'failed_logins'")" = "extended_properties=no right,role_members=no right,services=read,sql_logins=no right,table_sizes=no right" ] || fail "C: the states: $(q "select string_agg(part || '=' || status, ',' order by part) from pgvigil.report_read_state where instance_id = $IMV")"
[ "$(q "select count(*) from pgvigil.report_read_state where instance_id = $IMV and status = 'no right' and note like '%VIEW ANY DEFINITION%'")" = 4 ] || fail "C: the notes"
[ "$(CNT)" = "$C_SA" ] || fail "C: the rows the sa read stored were not kept: $C_SA before, $(CNT) after"
echo "C: OK"

echo "--- D. reports on PostgreSQL"
OUT=$(col reports rp-pg); echo "  $OUT"
[[ "$OUT" == *partial* ]] && fail "D: the superuser read is partial: $OUT"
[ "$(q "select value from pgvigil.report_db_properties where instance_id = $IPG and database_name = 'postgres' and property = 'comment' and is_present")" = "the proof's monitored database" ] || fail "D: the comment"
HAND=$(sq "select string_agg(rolname || '=' || case when rolpassword is null then 'none' when rolpassword like 'SCRAM-SHA-256\$%' then 'scram-sha-256' when rolpassword like 'md5%' then 'md5' else 'other' end, ',' order by rolname) from pg_authid where rolname in ('rp_md5', 'rp_scram', 'rp_nopw')")
[ "$HAND" = "rp_md5=md5,rp_nopw=none,rp_scram=scram-sha-256" ] || fail "D: the hand read itself: $HAND"
[ "$(q "select string_agg(role_name || '=' || method, ',' order by role_name) from pgvigil.pg_role_passwords where instance_id = $IPG and role_name in ('rp_md5', 'rp_scram', 'rp_nopw')")" = "$HAND" ] || fail "D: the methods"
[ "$(q "select count(*) from pgvigil.pg_role_passwords where instance_id = $IPG and is_present")" = "$(sq "select count(*) from pg_authid where rolcanlogin")" ] || fail "D: the login roles"
LOW_DSN="$MON_DSN" col reports rp-pg-low >/dev/null
D_SU=$(q "select count(*) from pgvigil.pg_role_passwords where instance_id = $IPL and is_present")
[ "$D_SU" -ge 3 ] || fail "D: the superuser read of rp-pg-low stored $D_SU methods"
OUT=$(col reports rp-pg-low); echo "  $OUT"
[[ "$OUT" == *partial* ]] && fail "D: the non-superuser read says partial: $OUT"
[ "$(q "select status from pgvigil.report_read_state where instance_id = $IPL and part = 'passwords'")" = "no right" ] || fail "D: the non-superuser's state"
[ "$(q "select status from pgvigil.report_read_state where instance_id = $IPL and part = 'comments'")" = "read" ] || fail "D: the non-superuser's comments"
[ "$(q "select count(*) from pgvigil.pg_role_passwords where instance_id = $IPL and is_present")" = "$D_SU" ] || fail "D: the methods the superuser read stored were not kept"
echo "D: OK"

echo "--- the other collections the reports read"
# a PostgreSQL database read once and then dropped: its next read (below, with the other collections) marks it gone
sq "create database rp169gone" >/dev/null; col databases rp-pg >/dev/null; sq "drop database rp169gone with (force)" >/dev/null
# the deadlocks: pgvigil's Extended Events sessions created by sa from the printed script, then two deadlocks of the same
# two statements, the second session the victim each time
"$BIN" mssql-xe -print -install-id "p$SUF" > "$WORK/xe.sql"
docker cp -q "$WORK/xe.sql" "$MCT:/tmp/pgv169xe.sql"
docker exec -e SQLCMDPASSWORD "$MCT" $SQLCMD -S localhost -U sa -C -I -b -d master -i /tmp/pgv169xe.sql >/dev/null || fail "the XE sessions"
col mssql_xe rp-ms >/dev/null
S1="BEGIN TRAN; UPDATE dbo.dl_a SET v = 1 WHERE id = 1; WAITFOR DELAY '00:00:02'; UPDATE dbo.dl_b SET v = 1 WHERE id = 1; COMMIT;"
S2="SET DEADLOCK_PRIORITY LOW; BEGIN TRAN; UPDATE dbo.dl_b SET v = 2 WHERE id = 1; WAITFOR DELAY '00:00:02'; UPDATE dbo.dl_a SET v = 2 WHERE id = 1; COMMIT;"
for _ in 1 2; do
  ( docker exec -e SQLCMDPASSWORD "$MCT" $SQLCMD -S localhost -U sa -C -I -d rp169 -Q "$S1" >/dev/null 2>&1 || true ) & W1=$!
  sleep 0.3
  ( docker exec -e SQLCMDPASSWORD "$MCT" $SQLCMD -S localhost -U sa -C -I -d rp169 -Q "$S2" >/dev/null 2>&1 || true ) & W2=$!
  wait $W1 $W2
done
# the first session never runs the deadlock check (10 s), the second does after 100 ms: the second is the victim
P1="set deadlock_timeout = '10s'; begin; update rp_dl set v = 1 where id = 1; select pg_sleep(1); update rp_dl set v = 1 where id = 2; commit;"
P2="set deadlock_timeout = '100ms'; begin; update rp_dl set v = 2 where id = 2; select pg_sleep(1); update rp_dl set v = 2 where id = 1; commit;"
for _ in 1 2; do
  ( PGAPPNAME=rp169a psql "$ADM dbname=postgres" -XAtq -c "$P1" >/dev/null 2>&1 || true ) & W1=$!
  for _ in $(seq 1 50); do [ "$(sq "select count(*) from pg_stat_activity where application_name = 'rp169a' and wait_event = 'PgSleep'")" = 1 ] && break; sleep 0.1; done
  ( PGAPPNAME=rp169b psql "$ADM dbname=postgres" -XAtq -c "$P2" >/dev/null 2>&1 || true ) & W2=$!
  wait $W1 $W2
done
# failed logins: three wrong passwords for rp_old on SQL Server, two for rp_app on PostgreSQL
for _ in 1 2 3; do docker exec -e SQLCMDPASSWORD=wrong "$MCT" $SQLCMD -S localhost -U rp_old -C -Q "SELECT 1" >/dev/null 2>&1 && fail "a wrong password logged in"; done
for _ in 1 2; do PGPASSWORD=wrong psql "host=127.0.0.1 port=$PPORT user=rp_app dbname=postgres" -XAtqc "select 1" >/dev/null 2>&1 && fail "a wrong password logged in"; done
# a plan cache flush by sa
ms "DBCC FREEPROCCACHE WITH NO_INFOMSGS" >/dev/null
# the marker statements: once before the first read of each engine's statements, five times between the two reads
MARK="DECLARE @x int = 10; SELECT /* rp169marker */ COUNT(*) FROM dbo.rp_big WHERE id > @x;"   # a variable: no simple parameterization to drop the comment
# pg_stat_statements on this server holds over a thousand statements by now (the migrations and the repository share
# it): a statement run once ranks outside the collector's picked set (the top 500 by time, the top 200 by calls), and a
# statement first seen at a read gets no delta until the read after. The reset empties it; no statements read of rp-pg
# comes before this one
sq "select pg_stat_statements_reset()" >/dev/null
ms "$MARK" rp169 >/dev/null
sq "select /* rp169marker */ count(*) from rp_pgbig where id > 10" >/dev/null
sleep 7
col mssql_plancache rp-ms >/dev/null; col statements rp-pg >/dev/null
# the marker's text split in two, so this read's own text never holds it
[ "$(q "select count(*) from pgvigil.statements_current c join pgvigil.statement_text t using (instance_id, queryid) where c.instance_id = $IPG and t.query like '%rp169' || 'marker%'")" = 1 ] \
  || fail "seed: the first statements read of rp-pg holds no row of the marker (its five later runs would leave no delta): statements_current $(q "select count(*) from pgvigil.statements_current where instance_id = $IPG") row(s), statement_text $(q "select count(*) from pgvigil.statement_text where instance_id = $IPG"); pg_stat_statements $(sq "select count(*) from pg_stat_statements") row(s), the marker's: $(sq "select coalesce(string_agg(queryid || ' calls ' || calls, '; '), 'none') from pg_stat_statements where query ilike '%rp169' || 'marker%' and query not ilike '%ilike%'")"
for _ in 1 2 3 4 5; do ms "$MARK" rp169 >/dev/null; sq "select /* rp169marker */ count(*) from rp_pgbig where id > 10" >/dev/null; done
sleep 7
for c in mssql_xe mssql_errorlog mssql_defaulttrace mssql_backups mssql_services mssql_plancache; do col "$c" rp-ms >/dev/null; done
col mssql_reports rp-ms >/dev/null; TEND=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)   # after the collector's error log read (%3N: datetimeoffset takes 7 digits at most)
for c in databases roles tables serverlog statements; do col "$c" rp-pg >/dev/null; done
col roles rp-pg-low >/dev/null
# the actions log: a kill (SQL Server), a terminate and a job start (PostgreSQL), written as the door writes them
q "insert into pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, engine, action, pid, target_user, target_host, target_app, reason, outcome, detail)
   values ($IMS, 'rp-ms', now() - interval '1 hour', 'proof169', '127.0.0.1', 'sqlserver', 'kill', 61, 'app_login', 'box-a', 'SQLCMD', 'the proof''s kill', 'done', NULL),
          ($IPG, 'rp-pg', now() - interval '2 hours', 'proof169', '127.0.0.1', 'postgres', 'terminate', 4242, 'rp_app', NULL, 'psql', 'the proof''s terminate', 'refused', 'not allowed'),
          ($IPG, 'rp-pg', now() - interval '3 hours', 'proof169', '127.0.0.1', 'postgres', 'job_start', NULL, NULL, NULL, NULL, 'the proof''s job start', 'done', NULL)" >/dev/null
# three saved custom reports (task 170's table, written as its door writes them), for the tree's Custom reports nodes
q "insert into pgvigil.custom_reports (name, description, folder, engine, kind, body, created_by, created_at, updated_by, updated_at)
   values ('rp169 tree pg', 'the proof''s PostgreSQL report', 'Ops/Daily', 'postgres', 'sql', 'select 1', 'proof169', now(), 'proof169', now()),
          ('rp169 tree store', 'the proof''s repository report', 'Ops', 'store', 'sql', 'select 1', 'proof169', now(), 'proof169', now()),
          ('rp169 tree ms', 'the proof''s SQL Server report', '', 'sqlserver', 'sql', 'select 1', 'proof169', now(), 'proof169', now())" >/dev/null
CRPG=$(q "select report_id from pgvigil.custom_reports where name = 'rp169 tree pg'"); CRMS=$(q "select report_id from pgvigil.custom_reports where name = 'rp169 tree ms'")
[ -n "$CRPG" ] && [ -n "$CRMS" ] || fail "seed: the custom reports"
q "update pgvigil.instances set is_active = false where instance_id = $IGONE" >/dev/null
echo "collections: done"

echo "--- E. the API against hand reads"
# serve on a free port (freeport); a bind refused after the check = a fresh port, 3 tries. The port counts as this
# run's only once this serve's own log says it listens there ('pgvigil serve started' url=..., written after its
# Listen): another job's server answering on a port taken after the check is never taken for this one
SPORT=
for _ in 1 2 3; do
  p=$(freeport 29000 32499)
  "$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$p" -no-login >"$WORK/serve.log" 2>&1 & SRVPID=$!
  for _ in $(seq 1 60); do
    kill -0 "$SRVPID" 2>/dev/null || break
    grep -q "url=http://127.0.0.1:$p/" "$WORK/serve.log" && curl -fs -m 5 "http://127.0.0.1:$p/api/health" >/dev/null 2>&1 && { SPORT=$p; break; }
    sleep 0.5
  done
  [ -n "$SPORT" ] && break
  kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=
  grep -q 'address already in use' "$WORK/serve.log" || break
done
if [ -z "$SPORT" ]; then
  grep -q 'address already in use' "$WORK/serve.log" && fail "E: serve: the port was taken 3 times: $(tail -3 "$WORK/serve.log")"
  fail "E: serve never answered: $(tail -5 "$WORK/serve.log")"
fi
U="http://127.0.0.1:$SPORT"
api() { local c; c=$(curl -s -m 60 -o "$WORK/b" -w '%{http_code}' "$U/api/reports?$1"); [ "$c" = 200 ] || fail "E: /api/reports?$1 -> $c $(head -c 300 "$WORK/b"); serve: $(tail -3 "$WORK/serve.log")"; }
js() { python3 -c "import json,sys
d=json.load(open('$WORK/b'))
def rows(p): return [dict(zip(d[p]['columns'], r)) for r in d[p]['rows']]
print($1)"; }
FROM=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)
api "r=props&instance=$IMS"; [ "$(js "len(rows('props'))")" = "$NPROP" ] || fail "E: props (SQL Server) $(js "len(rows('props'))") vs $NPROP"
api "r=props&instance=$IPG"; [ "$(js "len(rows('props'))")" = "$(sq "select count(*) from pg_database where not datistemplate and coalesce(shobj_description(oid, 'pg_database'), '') <> ''")" ] || fail "E: props (PostgreSQL)"
api "r=finder&instance=$IMS"; [ "$(js "len(rows('databases'))")" = "$(ms "SELECT COUNT(*) FROM sys.databases WHERE source_database_id IS NULL AND name NOT IN ('master', 'model', 'msdb', 'tempdb')")" ] || fail "E: finder (SQL Server, user databases): $(js "[r['database_name'] for r in rows('databases')]")"
api "r=finder&instance=$IMS&system=1"; MSALL=$(ms "SELECT COUNT(*) FROM sys.databases WHERE source_database_id IS NULL")
[ "$(js "len(rows('databases'))")" = "$MSALL" ] || fail "E: finder (SQL Server, with the system ones): $(js "[r['database_name'] for r in rows('databases')]") vs $MSALL"
api "r=finder&instance=$IPG"; [ "$(js "len(rows('databases'))")" = "$(sq "select count(*) from pg_database where not datistemplate and datname <> 'postgres'")" ] || fail "E: finder (PostgreSQL)"
api "r=finder&instance=$IPG&system=1"; [ "$(js "len(rows('databases'))")" = "$(sq "select count(*) from pg_database where not datistemplate")" ] || fail "E: finder (PostgreSQL, with postgres)"
api "r=finder&like=rp16"; [ "$(js "','.join(sorted(r['database_name'] for r in rows('databases')))")" = rp169 ] || fail "E: finder's LIKE: $(js "[r['database_name'] for r in rows('databases')]")"
api "r=deadlocks&from=$FROM&to=$TO&instance=$IMS"
[ "$(js "len([r for r in rows('deadlocks') if r['database_names'] == 'rp169'])")" = 2 ] || fail "E: SQL Server deadlocks: $(js "[(r['event_at'], r['database_names']) for r in rows('deadlocks')]")"
[ "$(js "sorted(set(p['statement'][:40] for r in rows('deadlocks') for p in r['processes'] if p['victim']))")" = "['SET DEADLOCK_PRIORITY LOW; BEGIN TRAN; U']" ] || fail "E: the victim is not the second session each time: $(js "[[p['statement'][:40] for p in r['processes'] if p['victim']] for r in rows('deadlocks')]")"
api "r=deadlocks&from=$FROM&to=$TO"; [ "$(js "[r['deadlocks'] for r in rows('pg') if r['instance_id'] == $IPG]")" = "[2]" ] || fail "E: the PostgreSQL deadlocks part: $(js "rows('pg')")"
curl -s -m 60 -o "$WORK/b" "$U/api/pg/deadlocks?instance=$IPG&from=$FROM&to=$TO"
# the log keeps the whole string psql sent (the SET first): the victim is the session whose deadlock_timeout is 100 ms
[ "$(python3 -c "import json; d=json.load(open('$WORK/b')); print(sorted(set(\"100ms\" in (p['statement'] or '') for x in d['deadlocks'] for p in x['processes'] if p['victim'])), len(d['deadlocks']))")" = "[True] 2" ] \
  || fail "E: the PostgreSQL victim is not the second session each time: $(python3 -c "import json; d=json.load(open('$WORK/b')); print([[(p['victim'], (p['statement'] or '')[:40]) for p in x['processes']] for x in d['deadlocks']])")"
api "r=failed&days=1&instance=$IMS"; HANDF=$(ms "CREATE TABLE #l (d datetime, p nvarchar(50), t nvarchar(4000)); INSERT #l EXEC xp_readerrorlog 0, 1, N'Login failed for user ''rp_old'''; SELECT COUNT(*) FROM #l") || fail "E: sa's read of rp_old's failed logins: $HANDF"
[ "$HANDF" = 3 ] || fail "E: the hand read of the error log says $HANDF failed logins of rp_old, not 3"
[ "$(js "len([r for r in rows('failed') if r['login_name'] == 'rp_old'])")" = "$HANDF" ] || fail "E: failed (SQL Server): $(js "rows('failed')[:3]")"
# the server summary counts every line of the server's current log that starts 'Login failed' (the collector's own
# match, case and all), not only rp_old's. The collector reads the log after the part's snapshot_at (its collection's
# start, in serve's zone) and before TEND: sa's count up to each bounds the summary
SNAPF=$(js "[r['snapshot_at'] for r in rows('server')][0]" 2>/dev/null) || fail "E: no server summary row for rp-ms: $(head -c 300 "$WORK/b")"
upto() { ms "DECLARE @e datetime = CONVERT(datetime, SWITCHOFFSET(CAST('$1' AS datetimeoffset), DATEPART(TZOFFSET, SYSDATETIMEOFFSET()))); CREATE TABLE #la (d datetime, p nvarchar(50), t nvarchar(4000)); INSERT #la EXEC xp_readerrorlog 0, 1, N'Login failed', NULL, NULL, @e; SELECT ${2:-COUNT(*)} FROM #la WHERE LEFT(t, 12) = N'Login failed' COLLATE Latin1_General_BIN2 ${3:-}"; }
HANDLO=$(upto "$SNAPF") || fail "E: sa's read of the error log up to $SNAPF: $HANDLO"
HANDHI=$(upto "$TEND") || fail "E: sa's read of the error log up to $TEND: $HANDHI"
SUMF=$(js "[(r['failed_logins'], r['read_status']) for r in rows('server')]")
OTHERS=$(q "select coalesce(string_agg(to_char(logged_at at time zone 'UTC', 'HH24:MI:SS') || ' ' || coalesce(login_name, '?') || ' ' || left(coalesce(reason, message), 70), '; ' order by logged_at), 'none') from pgvigil.mssql_failed_logins where instance_id = $IMS and login_name is distinct from 'rp_old'")
echo "  failed logins on rp-ms: the summary $SUMF; sa's read $HANDLO up to $SNAPF, $HANDHI up to $TEND; besides rp_old's (UTC): $OTHERS; the server answered at $(date -u -d "@$TREADY" +%H:%M:%S)"
[ "$HANDHI" -ge "$HANDF" ] || fail "E: sa's read of every failed login ($HANDHI) holds fewer than rp_old's ($HANDF)"
[ "$(js "[(r['read_status'], $HANDLO <= r['failed_logins'] <= $HANDHI) for r in rows('server')]")" = "[('read', True)]" ] || fail "E: failed's server summary $SUMF is not between sa's $HANDLO and $HANDHI line(s) ($SNAPF .. $TEND): $(upto "$TEND" "CONVERT(varchar(23), d, 126) + ' ' + LEFT(t, 90)" "ORDER BY d" | tr '\n' ';')"
[ "$(js "(lambda n: $HANDLO <= n <= $HANDHI and n == rows('server')[0]['failed_logins'])(len([r for r in rows('failed') if r['instance_id'] == $IMS]))")" = True ] || fail "E: failed's Detail holds $(js "len([r for r in rows('failed') if r['instance_id'] == $IMS])") rows of rp-ms, its summary $SUMF"
# held to the end of E, so the checks after it still run and print
LATE=$(q "select coalesce(string_agg(to_char(logged_at at time zone 'UTC', 'HH24:MI:SS') || ' ' || coalesce(login_name, '?') || ' ' || left(coalesce(reason, message), 70), '; ' order by logged_at), '') from pgvigil.mssql_failed_logins where instance_id = $IMS and login_name is distinct from 'rp_old' and logged_at > to_timestamp($TREADY)")
[ "$(js "[r['failed_logins'] for r in rows('logins') if r['value'] == 'rp_old']")" = "[3]" ] || fail "E: failed's login summary: $(js "rows('logins')")"
FA=$(q "select floor(extract(epoch from min(logged_at))) || ' ' || floor(extract(epoch from max(logged_at))) from pgvigil.mssql_failed_logins where instance_id = $IMS and login_name = 'rp_old'")
[ "${FA% *}" -ge "$T1" ] && [ "${FA#* }" -le "$(date -u +%s)" ] || fail "E: the failed logins' UTC times $FA are not inside the run ($T1 .. now)"
[ "$(js "len([r for r in rows('failed') if r['login_name'] == 'rp_old' and r['client'] and r['reason']])")" = 3 ] || fail "E: failed: the client and the reason were not taken apart"
api "r=failed&days=1&instance=$IPG"; HANDP=$(docker exec "$PCT" sh -c 'cat /var/lib/postgresql/data/log/*.log' | grep -c 'password authentication failed for user "rp_app"' || true)
[ "$HANDP" = 2 ] || fail "E: the hand read of the server log says $HANDP, not 2"
[ "$(js "len([r for r in rows('failed') if r['login_name'] == 'rp_app'])")" = "$HANDP" ] || fail "E: failed (PostgreSQL): $(js "rows('failed')[:3]")"
api "r=flushed&days=1&instance=$IMS"; HANDT=$(ms "SELECT COUNT(*) FROM sys.fn_trace_gettable((SELECT path FROM sys.traces WHERE is_default = 1), DEFAULT) WHERE EventClass = 116 AND CAST(TextData AS nvarchar(max)) LIKE N'%FREEPROCCACHE%'")
[ "$(js "len([r for r in rows('flushed') if r['source'] == 'default trace'])")" = "$HANDT" ] && [ "$HANDT" -ge 1 ] || fail "E: flushed (default trace) $(js "rows('flushed')") vs the trace's $HANDT"
HANDE=0; for a in 0 1; do n=$(ms "CREATE TABLE #l (d datetime, p nvarchar(50), t nvarchar(4000)); BEGIN TRY INSERT #l EXEC xp_readerrorlog $a, 1, N'cachestore flush'; END TRY BEGIN CATCH END CATCH; SELECT COUNT(*) FROM #l" 2>/dev/null || echo 0); HANDE=$((HANDE + ${n:-0})); done
[ "$(js "len([r for r in rows('flushed') if r['source'] == 'error log'])")" = "$HANDE" ] || fail "E: flushed (error log) $(js "len([r for r in rows('flushed') if r['source'] == 'error log'])") vs xp_readerrorlog's $HANDE"
api "r=killed&days=1"; [ "$(js "len([r for r in rows('killed') if r['ui_user'] == 'proof169'])")" = 2 ] || fail "E: killed"
api "r=actions&days=1"; [ "$(js "len([r for r in rows('actions') if r['ui_user'] == 'proof169'])")" = 3 ] || fail "E: actions"
api "r=actions&days=1&instance=$IMS"; [ "$(js "len(rows('actions'))")" = 1 ] || fail "E: actions of one instance"
api "r=roles&instance=$IMS"; [ "$(js "','.join(sorted((r['login_name'] for r in rows('members') if r['role_name'] == 'sysadmin'), key=lambda s: s.encode()))")" = "$SYSA" ] || fail "E: roles sysadmin"
api "r=roles&instance=$IPG"
[ "$(js "','.join(sorted(r['login_name'] for r in rows('members') if r['role_name'] == 'superuser'))")" = "$(sq "select string_agg(rolname, ',' order by rolname collate \"C\") from pg_roles where rolsuper")" ] || fail "E: roles superuser"
[ "$(js "','.join(sorted(r['login_name'] for r in rows('members') if r['role_name'] == 'pg_monitor'))")" = "$(sq "select string_agg(m.rolname, ',' order by m.rolname collate \"C\") from pg_auth_members a join pg_roles r on r.oid = a.roleid join pg_roles m on m.oid = a.member where r.rolname = 'pg_monitor'")" ] || fail "E: roles pg_monitor"
api "r=pwage&instance=$IMS"; [ "$(js "len(rows('logins'))")" = "$(ms "SELECT COUNT(*) FROM sys.sql_logins WHERE name NOT LIKE '##%##' AND is_disabled = 0")" ] || fail "E: pwage enabled logins"
api "r=pwage&instance=$IMS&disabled=1"; [ "$(js "len(rows('logins'))")" = "$NLOG" ] || fail "E: pwage with the disabled"
api "r=pwage&instance=$IPG"; [ "$(js "[(r['method'], r['days_until_expiration'] < 0) for r in rows('pg') if r['role_name'] == 'rp_exp']")" = "[('scram-sha-256', True)]" ] || fail "E: pwage rp_exp: $(js "[r for r in rows('pg') if r['role_name'] == 'rp_exp']")"
api "r=services&instance=$IMS"; [ "$(js "len(rows('services'))")" = "$(ms "SELECT COUNT(*) FROM sys.dm_server_services")" ] || fail "E: services"
[ "$(js "len(rows('services')) >= 1 and all(r['filename'] for r in rows('services'))")" = True ] || fail "E: a service without its file name: $(js "rows('services')")"
api "r=tables&instance=$IMS"; [ "$(js "[(r['row_count'], r['reserved_kb']) for r in rows('tables') if r['table_name'] == 'rp_big']")" = "[(5000, $RES)]" ] || fail "E: tables"
api "r=querystats&from=$FROM&to=$TO&instance=$IPG"; QPG=$(js "sum(r['executions'] for r in rows('stats') if 'rp169marker' in (r['query_text'] or ''))") || QPG="? (the body: $(head -c 200 "$WORK/b"))"
QPGL=$(js "[(r['executions'], (r['query_text'] or '')[:50]) for r in rows('stats') if 'rp169marker' in (r['query_text'] or '')]") || QPGL=?; QPGN=$(js "len(rows('stats'))") || QPGN=?
# the diagnostic print: the marker in pg_stat_statements itself and in the repository's statements store, the
# statements collections' times, and the marker's place among every row of the window (top=5000). A read whose own
# text holds 'like' is left out, so these reads never find themselves
MQ=$(sq "select coalesce(string_agg(queryid::text, ','), '') from pg_stat_statements where query ilike '%rp169marker%' and query not ilike '%like%'") || MQ=
echo "  querystats diag (PostgreSQL): the API's rows $QPGN, the marker's $QPGL"
echo "  pg_stat_statements: $(sq "select count(*) from pg_stat_statements") rows; the marker's: $(sq "select coalesce(string_agg(queryid || ' calls ' || calls || ' db ' || coalesce((select datname from pg_database where oid = dbid), dbid::text) || ' time ' || round(total_exec_time::numeric, 2) || ' ms: ' || left(query, 120), '; '), 'none') from pg_stat_statements where queryid = any('{$MQ}'::bigint[])")"
echo "  its rank now: by total time $(sq "select coalesce(string_agg(queryid || '=' || r, ',' order by queryid), '-') from (select queryid, rank() over (order by total_exec_time desc) r from pg_stat_statements) x where queryid = any('{$MQ}'::bigint[])"), by calls $(sq "select coalesce(string_agg(queryid || '=' || r, ',' order by queryid), '-') from (select queryid, rank() over (order by calls desc) r from pg_stat_statements) x where queryid = any('{$MQ}'::bigint[])")"
echo "  the statements collections (UTC): $(q "select coalesce(string_agg(to_char(snapshot_at at time zone 'UTC', 'HH24:MI:SS.MS'), ', ' order by snapshot_at), 'none') from pgvigil.statements_info where instance_id = $IPG")"
echo "  statement_text: $(q "select coalesce(string_agg(queryid || ' first ' || to_char(first_seen at time zone 'UTC', 'HH24:MI:SS.MS'), '; '), 'none') from pgvigil.statement_text where instance_id = $IPG and queryid = any('{$MQ}'::bigint[])")"
echo "  statements_current: $(q "select coalesce(string_agg(queryid || ' calls ' || calls || ' at ' || to_char(snapshot_at at time zone 'UTC', 'HH24:MI:SS.MS'), '; '), 'none') from pgvigil.statements_current where instance_id = $IPG and queryid = any('{$MQ}'::bigint[])")"
echo "  statements_delta: $(q "select coalesce(string_agg(queryid || ' calls ' || calls || ' at ' || to_char(snapshot_at at time zone 'UTC', 'HH24:MI:SS.MS'), '; '), 'none') from pgvigil.statements_delta where instance_id = $IPG and queryid = any('{$MQ}'::bigint[])"); the window's delta rows of rp-pg: $(q "select count(*) || ' (' || count(distinct queryid) || ' statements)' from pgvigil.statements_delta where instance_id = $IPG and snapshot_at > '$FROM' and snapshot_at <= '$TO'")"
api "r=querystats&from=$FROM&to=$TO&instance=$IPG&top=5000"
echo "  the marker's place in the window's $(js "len(rows('stats'))") rows (by CPU, else duration): $(js "[n for n, r in enumerate(rows('stats'), 1) if 'rp169marker' in (r['query_text'] or '')]"); the 100th row's duration $(js "rows('stats')[99]['duration_ms'] if len(rows('stats')) >= 100 else '-'") ms"
[ "$QPG" = 5 ] || fail "E: querystats (PostgreSQL): $QPGL"
api "r=querystats&from=$FROM&to=$TO&instance=$IMS"; MX=$(js "sum(r['executions'] for r in rows('stats') if 'rp169marker' in (r['query_text'] or ''))")
[ "$MX" = 5 ] || [ "$MX" = 6 ] || fail "E: querystats (SQL Server) $MX executions of the marker, not 5 (or 6)"
api "r=querystats&from=$FROM&to=$TO&group=database"; [ "$(js "len([r for r in rows('stats') if r['database_name'] == 'rp169'])")" -ge 1 ] || fail "E: querystats by database"
api "r=qscharts&from=$FROM&to=$TO"; [ "$(js "sorted(set(r['engine'] for r in rows('series')))")" = "['postgres', 'sqlserver']" ] || fail "E: qscharts' series: $(js "rows('series')[:3]")"
api "r=recycle"; [ "$(js "[r['instance_id'] for r in rows('instances') if not r['is_active']]")" = "[$IGONE]" ] || fail "E: recycle: $(js "rows('instances')")"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/reports?r=nope")" = 400 ] && [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/reports?r=failed&days=3")" = 400 ] || fail "E: a bad r= or days= is not a 400"
[ -z "$LATE" ] || fail "E: a failed login not rp_old's after SQL Server answered ($(date -u -d "@$TREADY" +%H:%M:%S) UTC): $LATE"
echo "E: OK"

echo "--- F, G. the pages and their exports"
rm -rf "$WORK/chrome"
setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHRPID=$!
CDP=
for _ in $(seq 1 60); do
  [ -s "$WORK/chrome/DevToolsActivePort" ] && CDP=$(head -1 "$WORK/chrome/DevToolsActivePort")
  [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5
done
[[ "$CDP" =~ ^[0-9]+$ ]] || fail "F: Chromium never answered: $(tail -3 "$WORK/chrome.log")"
mkdir -p "$WORK/xlsx"; SHOTS=${PGVIGIL_REPORTS_SHOTS:-}
[ -n "$SHOTS" ] && mkdir -p "$SHOTS"
# the API's rows per report and grid, for the page check to compare with (the root's scope: every active instance)
W="from=$FROM&to=$TO"
api "r=deadlocks&$W"; cp "$WORK/b" "$WORK/api-deadlocks.json"
cat > "$WORK/page.mjs" <<'PAGE'
import { writeFileSync } from 'node:fs';
const [port, base, ims, ipg, xdir, shots, crpg, crms] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the page check did not end in 600 s'); process.exit(2); }, 600000).unref();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); let thrown = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? d.params.exceptionDetails?.text ?? 'exception');
  if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') thrown.push('console.error: ' + d.params.args.map(a => a.value ?? a.description ?? '').join(' '));
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => { const d = await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }); return d.result?.result?.value; };
const until = async (expr, ms = 30000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(250); } return null; };
let failed = 0;
const check = (label, ok, what) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: ${what}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
// the grids of a page: each h3's name and the rows its grid holds (all, not only the ones drawn)
// (a heading's own text: a chart's heading also holds its menu button and its Top select; a chart's heading names no grid)
const gridsOf = `[...document.querySelectorAll('main section.report h3')].filter(h => !h.closest('.chart')).map(h => { let t = h.nextElementSibling;
  while (t && !t.querySelector?.('table.grid') && !t.matches?.('p.empty') && t.tagName !== 'H3') t = t.nextElementSibling;
  const tb = t?.querySelector?.('table.grid'); return [[...h.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('').trim(), tb ? Number(tb.dataset.rows) : t?.matches?.('p.empty') ? 0 : -1,
    !tb && t?.matches?.('p.empty') ? JSON.parse(t.dataset.cols || '[]').length : null]; })`;
const want = {
  rp_props: ['Database Extended Properties'], rp_finder: ['Database Finder'], rp_dlcharts: [], rp_deadlocks: ['Signatures', 'Grouped', 'Deadlocks', 'Participants'],
  rp_dbdeleted: ['Deleted Databases'], rp_failed: ['Server Summary', 'Login Summary', 'Client Summary', 'Message Summary', 'Detail'], rp_flushed: ['Flushed Plans'], rp_killed: ['Killed Sessions'], rp_dbnew: ['New Databases'],
  rp_qscharts: ['Top queries'], rp_qs: ['Query Stats'], rp_actions: ['User Actions'], rp_roles: ['Normal', 'Pivot By Instance', 'Pivot By User'], rp_services: ['Server Services'],
  rp_pwage: ['Summary', 'Oldest Passwords'], rp_tables: ['Table Size'], rp_recycle: ['Recycle Bin'],
};
const names = { rp_props: 'Database Extended Properties', rp_finder: 'Database Finder', rp_dlcharts: 'Deadlock Charts', rp_deadlocks: 'Deadlocks', rp_dbdeleted: 'Deleted Databases', rp_failed: 'Failed Logins', rp_flushed: 'Flushed Plans', rp_killed: 'Killed Sessions', rp_dbnew: 'New Databases', rp_qscharts: 'Query Stats Charts', rp_qs: 'Query Stats', rp_actions: 'User Actions', rp_roles: 'Server Role Members', rp_services: 'Server Services', rp_pwage: 'SQL Login Password Age', rp_tables: 'Table Size', rp_recycle: 'Recycle Bin' };
const open = async (hash, theme = 'light') => {
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150);
  await cmd('Page.navigate', { url: `${base}/${hash}` });
  await until(`!!document.querySelector('main')`);
  await ev(`localStorage.setItem('pgvigil.theme', '${theme}')`);
};
const settled = async () => until(`(() => { const s = document.querySelector('main section.report'); return s && s.querySelector('[aria-live] > *') ? true : null; })()`, 45000);
async function exportOf(tab) {
  await ev(`(() => { window.__blobs = []; const o = URL.createObjectURL.bind(URL); URL.createObjectURL = b => { window.__blobs.push(b); return o(b); }; })()`);
  const clicked = await ev(`(() => { const b = [...document.querySelectorAll('button')].find(x => x.textContent.trim() === 'Export .xlsx'); if (!b) return false; b.click(); return true; })()`);
  if (!clicked) return 'no Export .xlsx button';
  const b64 = await until(`(async () => { const b = (window.__blobs || []).find(x => x.type.includes('spreadsheet')); if (!b) return null;
    const u = new Uint8Array(await b.arrayBuffer()); let s = ''; for (let i = 0; i < u.length; i += 8192) s += String.fromCharCode(...u.subarray(i, i + 8192)); return btoa(s); })()`, 20000);
  if (!b64) return 'no workbook came out';
  writeFileSync(`${xdir}/${tab}.xlsx`, Buffer.from(b64, 'base64'));
  return 'ok';
}
const api = JSON.parse((await import('node:fs')).readFileSync(`${xdir}/../api-deadlocks.json`, 'utf8'));
// the grids that are one API part each, at the root's scope and the pickers' defaults: their rows equal the part's
const part = async (q, name) => { const d = await (await fetch(`${base}/api/${q}`)).json(); return d[name]?.rows?.length ?? -1; };
const admin = new Set(['sqlserver:sysadmin', 'postgres:superuser', 'postgres:rds_superuser', 'postgres:azure_pg_admin', 'postgres:cloudsqlsuperuser', 'postgres:alloydbsuperuser']);
const changes = async kind => { const d = await (await fetch(`${base}/api/dbchanges?days=30`)).json(); const i = d.changes.columns.indexOf('change'); return d.changes.rows.filter(r => r[i] === kind).length; };
const expect = {
  rp_props: async () => ({ 'Database Extended Properties': await part('reports?r=props', 'props') }),
  rp_finder: async () => ({ 'Database Finder': await part('reports?r=finder&top=1000', 'databases') }),
  rp_failed: async () => ({ 'Server Summary': await part('reports?r=failed&days=7', 'server'), 'Login Summary': await part('reports?r=failed&days=7', 'logins'),
    'Client Summary': await part('reports?r=failed&days=7', 'clients'), 'Message Summary': await part('reports?r=failed&days=7', 'messages'), Detail: await part('reports?r=failed&days=7', 'failed') }),
  rp_flushed: async () => ({ 'Flushed Plans': await part('reports?r=flushed&days=7', 'flushed') }),
  rp_killed: async () => ({ 'Killed Sessions': await part('reports?r=killed&days=7', 'killed') }),
  rp_actions: async () => ({ 'User Actions': await part('reports?r=actions&days=7', 'actions') }),
  rp_services: async () => ({ 'Server Services': await part('reports?r=services', 'services') }),
  rp_recycle: async () => ({ 'Recycle Bin': await part('reports?r=recycle', 'instances') }),
  rp_dbnew: async () => ({ 'New Databases': await changes('new') }),
  rp_dbdeleted: async () => ({ 'Deleted Databases': await changes('dropped') }),
  rp_roles: async () => { const d = await (await fetch(`${base}/api/reports?r=roles`)).json(); const e = d.members.columns.indexOf('engine'), r = d.members.columns.indexOf('role_name');
    return { Normal: d.members.rows.filter(x => admin.has(`${x[e]}:${x[r]}`)).length }; },
};
const allGrids = {}, emptyGrids = {};
// a ring: each slice two arcs (outer and inner), a whole slice a circle stroked as wide as the ring; a pie: each wedge
// from the centre, a whole slice a filled disc
const shapes = sel => ev(`[...document.querySelectorAll('${sel}')].filter(r => r.querySelector('svg')).map(r => {
  const ps = [...r.querySelectorAll('svg path')], cs = [...r.querySelectorAll('svg circle')];
  // a ring's inner arc has radius 27 (half the outer 54); a whole ring is a circle of radius 40.5 stroked 27 wide
  return { ring: ps.every(x => (x.getAttribute('d').match(/A/g) || []).length === 2 && x.getAttribute('d').includes(' A27 27 '))
             && cs.every(x => x.getAttribute('fill') === 'none' && x.getAttribute('r') === '40.5' && x.getAttribute('stroke-width') === '27'),
           pie: ps.every(x => x.getAttribute('d').startsWith('M60 60 ')) && cs.every(x => x.getAttribute('fill') !== 'none'), n: ps.length + cs.length }; })`);
// the root's Reports folder: every page
for (const [tab, name] of Object.entries(names)) {
  thrown = [];
  await open(`#/${tab}?w=4h`);
  await cmd('Page.navigate', { url: `${base}/#/${tab}?w=4h` });
  const ok = await settled();
  await sleep(400);
  const h2 = await ev(`document.querySelector('main section.report h2')?.textContent.trim() ?? ''`);
  const grids = await ev(gridsOf) ?? [];
  const errs = await ev(`[...document.querySelectorAll('main p.error')].map(p => p.textContent.trim())`) ?? [];
  const missing = want[tab].filter(h => !grids.some(g => g[0] === h));
  const bare = want[tab].filter(h => grids.some(g => g[0] === h && g[1] <= 0));   // every wanted grid holds rows on this seed
  check(`${tab} renders`, ok && h2.startsWith(name) && missing.length === 0 && bare.length === 0 && errs.length === 0 && thrown.length === 0 && grids.every(g => g[1] >= 0),
    `h2 '${h2}', grids ${JSON.stringify(grids)}${missing.length ? ', missing ' + missing : ''}${bare.length ? ', empty ' + bare : ''}${errs.length ? ', errors ' + errs.join(' | ') : ''}${thrown.length ? ', thrown ' + thrown.join(' | ') : ''}`);
  // every grid is a sheet, an empty one its header row alone (G reads it: the grid's column count from its note)
  allGrids[tab] = grids.map(g => g[0]);
  emptyGrids[tab] = grids.filter(g => g[1] === 0).map(g => [g[0], g[2] ?? 0]);
  if (expect[tab]) {
    const want = await expect[tab](), got = Object.fromEntries(grids);
    const bad = Object.entries(want).filter(([g, n]) => got[g] !== n);
    check(`${tab} rows = the API's`, bad.length === 0 && Object.values(want).every(n => n >= 0), `want ${JSON.stringify(want)}, page ${JSON.stringify(got)}`);
  }
  if (tab === 'rp_deadlocks') {
    const g = Object.fromEntries(grids);
    const occ = await ev(`[...document.querySelectorAll('main section.report h3')].find(h => h.textContent === 'Signatures').nextElementSibling.querySelectorAll('table.grid tbody tr')
      .length && [...[...document.querySelectorAll('main section.report h3')].find(h => h.textContent === 'Signatures').nextElementSibling.querySelectorAll('table.grid tbody tr')].map(tr => tr.children[1].textContent.trim())`);
    const nApi = api.deadlocks.rows.length;
    check('rp_deadlocks: the grids', g.Signatures === 2 && JSON.stringify(occ) === '["2","2"]' && g.Deadlocks === nApi + 2 && g.Participants === 2 * (nApi + 2),
      `${JSON.stringify(g)}, occurrences ${JSON.stringify(occ)}, the API's SQL Server deadlocks ${nApi} (+2 PostgreSQL)`);
    await ev(`[...document.querySelectorAll('main button.link')].find(b => b.textContent === 'Graph').click()`);
    const svg = await until(`document.querySelector('main .deadlock-panel svg.deadlock-graph') ? document.querySelectorAll('main .deadlock-panel svg .dl-process').length : null`, 10000);
    check('rp_deadlocks: a Graph draws', svg === 2, `processes drawn ${svg}`);
  }
  if (tab === 'rp_dlcharts') {
    const c = await ev(`(() => { const rings = [...document.querySelectorAll('main .chart.donut')];
      const name = r => [...r.querySelector('h3').childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('').trim();
      return { rings: rings.length, drawn: rings.filter(r => r.querySelector('svg')).map(name),
               empty: rings.filter(r => r.querySelector('p.empty')).map(name),
               line: document.querySelectorAll('main .chart:not(.donut) canvas, main .chart:not(.donut) .uplot').length }; })()`);
    const five = ['Signature', 'Application', 'Database', 'Login', 'Host'];
    check('rp_dlcharts: six rings, the five with data drawn, and the line', c && c.rings === 6 && five.every(x => c.drawn.includes(x)) && !c.empty.some(x => five.includes(x)) && c.line >= 1, JSON.stringify(c));
    const sh = await shapes('main .chart.donut') ?? [];
    check('rp_dlcharts: every drawn ring has its hole (DBA Dash: InnerRadius 0.5)', sh.length >= 5 && sh.every(x => x.ring && x.n > 0), JSON.stringify(sh));
  }
  if (tab === 'rp_qscharts') {
    const sh = await shapes('main .chart.donut') ?? [];
    check('rp_qscharts: the two rings have their hole', sh.length === 2 && sh.every(x => x.ring && x.n > 0), JSON.stringify(sh));
  }
  if (want[tab].length) { const x = await exportOf(tab); check(`${tab} export`, x === 'ok', x); }
  if (shots) for (const theme of ['light', 'dark']) {
    await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
    await ev(`localStorage.setItem('pgvigil.theme', '${theme}')`); await cmd('Page.reload'); await settled(); await sleep(600);
    const s = await cmd('Page.captureScreenshot', { format: 'png' });
    writeFileSync(`${shots}/pgvigil-${tab}-${theme}.png`, Buffer.from(s.result.data, 'base64'));
  }
}
// the tree's Reports folders (router.ts' Reports groups): the scope's every page is in the strip's data-all
const counts = async hash => { await open(hash); await cmd('Page.navigate', { url: `${base}/${hash}` }); await settled(); await sleep(500);
  // the strip of the page's group (router.ts' Reports group, the tree's folder): its tabs, not the way back
  return ev(`(() => { const t = document.querySelector('#tabs'); return { label: t?.getAttribute('aria-label'), n: [...(t?.querySelectorAll('a:not(.tab-back)') ?? [])].filter(a => /#\\/rp_/.test(a.getAttribute('href') ?? '')).length }; })()`); };
const nRoot = await counts('#/rp_props?w=4h'), nMs = await counts(`#/rp_props?i=${ims}&w=4h`), nPg = await counts(`#/rp_props?i=${ipg}&w=4h`);
check('the Reports folders (the strip of the Reports group)', [nRoot, nMs, nPg].every(x => x?.label === 'Reports pages') && nRoot.n === 17 && nMs.n === 12 && nPg.n === 10,
  `root ${JSON.stringify(nRoot)}, SQL Server instance ${JSON.stringify(nMs)}, PostgreSQL instance ${JSON.stringify(nPg)}`);
writeFileSync(`${xdir}/grids.json`, JSON.stringify({ grids: allGrids, empty: emptyGrids }));
// the instance folders' pages render too
for (const [inst, list] of [[ims, ['rp_props', 'rp_finder', 'rp_dbdeleted', 'rp_failed', 'rp_flushed', 'rp_killed', 'rp_dbnew', 'rp_actions', 'rp_roles', 'rp_services', 'rp_pwage', 'rp_tables']],
                            [ipg, ['rp_props', 'rp_finder', 'rp_dbdeleted', 'rp_failed', 'rp_killed', 'rp_dbnew', 'rp_actions', 'rp_roles', 'rp_pwage', 'rp_tables']]]) {
  for (const tab of list) {
    thrown = [];
    await open(`#/${tab}?i=${inst}&w=4h`); await cmd('Page.navigate', { url: `${base}/#/${tab}?i=${inst}&w=4h` });
    const ok = await settled(); await sleep(300);
    const errs = await ev(`[...document.querySelectorAll('main p.error')].map(p => p.textContent.trim())`) ?? [];
    const h2 = await ev(`document.querySelector('main section.report h2')?.textContent.trim() ?? ''`);
    check(`${tab} on instance ${inst}`, ok && h2.startsWith(names[tab]) && errs.length === 0 && thrown.length === 0, `h2 '${h2}'${errs.length ? ', errors ' + errs.join(' | ') : ''}${thrown.length ? ', thrown ' + thrown.join(' | ') : ''}`);
  }
}
// the tree's Reports folders (tree.ts): the stock pages in DBA Dash's order, then Custom reports (its sub folders first,
// then its reports, by name; under an instance its engine's only) and Community tools; a node clicked lands on its page
const kidsOf = key => ev(`(() => { const b = document.querySelector('#tree button.caret[data-key="${key}"]'); if (!b) return null;
  return [...b.closest('.tree-node, .tree-inst').parentElement.children].slice(1).map(c => (c.querySelector('a.inst, .folder-name, p') ?? c).textContent.trim()); })()`);
const openKey = async key => {
  for (let i = 0; i < 60; i++) {
    const st = await ev(`(() => { const b = document.querySelector('#tree button.caret[data-key="${key}"]'); if (!b) return 'none';
      if (b.getAttribute('aria-expanded') !== 'true') { b.click(); return 'clicked'; } return 'open'; })()`);
    if (st === 'open') { const k = await kidsOf(key); if (k && !k.includes('Loading...')) return k; }
    if (st === 'none') await ev(`[...document.querySelectorAll('#tree button.caret[data-key^="f:"][aria-expanded="false"]')].forEach(b => b.click())`);
    await sleep(250);
  }
  return null;
};
const clickIn = async (key, name) => ev(`(() => { const b = document.querySelector('#tree button.caret[data-key="${key}"]');
  const a = b && [...b.closest('.tree-node').parentElement.querySelectorAll(':scope > div a.inst')].find(x => x.textContent.trim() === '${name}');
  if (!a) return false; a.click(); return true; })()`);
const landed = async (want, h2) => { for (let i = 0; i < 80; i++) {
  const at = await ev(`location.hash`), h = await ev(`document.querySelector('main section h2')?.textContent.trim() ?? ''`);
  if (want(at) && h === h2) return { at, h }; await sleep(250); }
  return { at: await ev(`location.hash`), h: await ev(`document.querySelector('main section h2')?.textContent.trim() ?? ''`) }; };
const q = h => new URLSearchParams(h.split('?')[1] ?? '');
await open('#/rp_props?w=4h'); await cmd('Page.navigate', { url: `${base}/#/rp_props?w=4h` }); await settled();
const rootKids = await openKey('r/reports') ?? [];
check('tree: the root Reports folder - the 17 stock pages, then Custom reports and Community tools',
  JSON.stringify(rootKids.slice(0, 19)) === JSON.stringify([...Object.values(names), 'Custom reports', 'Community tools']), JSON.stringify(rootKids));
const crKids = await openKey('r/reports/cr'), opsKids = await openKey('r/reports/cr/Ops'), dayKids = await openKey('r/reports/cr/Ops/Daily');
check('tree: the root Custom reports - folders first, then reports, by name', JSON.stringify([crKids, opsKids, dayKids]) === JSON.stringify([['Ops', 'rp169 tree ms'], ['Daily', 'rp169 tree store'], ['rp169 tree pg']]),
  JSON.stringify([crKids, opsKids, dayKids]));
let to = (await clickIn('r/reports/cr/Ops/Daily', 'rp169 tree pg')) ? await landed(h => q(h).get('report') === crpg, 'rp169 tree pg') : { at: 'no node' };
check('tree: a root report node opens its report', to.at?.startsWith('#/customreports?') && q(to.at).get('report') === crpg && !q(to.at).get('i') && to.h === 'rp169 tree pg', JSON.stringify(to));
to = (await clickIn('r/reports', 'Community tools')) ? await landed(h => h.startsWith('#/community'), 'Community tools') : { at: 'no node' };
check('tree: the root Community tools node opens its page', to.at?.startsWith('#/community') && !q(to.at).get('i') && to.h === 'Community tools', JSON.stringify(to));
// under an instance: its engine's reports and the repository's (rp169 tree store, in Ops)
for (const [inst, eng, path, rep, id, wantSeen] of [[ipg, 'PostgreSQL', ['Ops', 'Daily'], 'rp169 tree pg', crpg, [['Ops'], ['Daily', 'rp169 tree store'], ['rp169 tree pg']]],
                                                    [ims, 'SQL Server', [], 'rp169 tree ms', crms, [['Ops', 'rp169 tree ms']]]]) {
  await openKey(`i${inst}`);
  const rk = await openKey(`i${inst}/reports`) ?? [];
  check(`tree: the ${eng} instance's Reports folder ends with Custom reports and Community tools`, JSON.stringify(rk.slice(-2)) === JSON.stringify(['Custom reports', 'Community tools']), JSON.stringify(rk));
  let key = `i${inst}/reports/cr`; const seen = [await openKey(key)];
  for (const part of path) { key += '/' + part; seen.push(await openKey(key)); }
  check(`tree: the ${eng} instance's Custom reports - its engine's report and the repository's`, JSON.stringify(seen) === JSON.stringify(wantSeen), JSON.stringify(seen));
  to = (await clickIn(key, rep)) ? await landed(h => q(h).get('report') === id && q(h).get('i') === inst, rep) : { at: 'no node' };
  check(`tree: the ${eng} instance's report node opens its report there`, q(to.at ?? '').get('report') === id && q(to.at ?? '').get('i') === inst && to.h === rep, JSON.stringify(to));
  to = (await clickIn(`i${inst}/reports`, 'Community tools')) ? await landed(h => h.startsWith('#/community') && q(h).get('i') === inst, 'Community tools') : { at: 'no node' };
  check(`tree: the ${eng} instance's Community tools node opens its page there`, to.at?.startsWith('#/community') && q(to.at).get('i') === inst && to.h === 'Community tools', JSON.stringify(to));
}
// the SQL Server instance's Ops folder: the repository's report alone (a PostgreSQL report there would be a leak)
const msOps = await openKey(`i${ims}/reports/cr/Ops`);
check("tree: the SQL Server instance's Custom reports > Ops - the repository's report alone", JSON.stringify(msOps) === JSON.stringify(['rp169 tree store']), JSON.stringify(msOps));
// every other pie stays a pie: the PostgreSQL instance's Databases by size
await open(`#/dbinfo?i=${ipg}&w=4h`); await cmd('Page.navigate', { url: `${base}/#/dbinfo?i=${ipg}&w=4h` });
let pies = null; for (let i = 0; i < 80 && !(pies && pies.length); i++) { await sleep(250); pies = await shapes('main .chart.donut'); }
check('a database pie stays a pie (Databases by size)', !!pies && pies.length >= 1 && pies.every(x => x.pie && x.n > 0), JSON.stringify(pies));
ws.close();
process.exit(failed ? 1 : 0);
PAGE
timeout 700 node "$WORK/page.mjs" "$CDP" "http://127.0.0.1:$SPORT" "$IMS" "$IPG" "$WORK/xlsx" "$SHOTS" "$CRPG" "$CRMS" || fail "F: a check of the pages failed"
echo "F: OK"
python3 - "$WORK/xlsx" <<'PY' || fail "G: a workbook did not open or lacks a sheet"
import sys, os, zipfile, re, json
d = sys.argv[1]
gj = json.load(open(os.path.join(d, 'grids.json'))); grids, empties = gj['grids'], gj['empty']; checked = 0
try:
    import openpyxl
except ImportError:
    openpyxl = None
files = sorted(f for f in os.listdir(d) if f.endswith('.xlsx'))
assert len(files) == 16, f'{len(files)} workbooks, want 16 (every report page with a grid)'
for f in files:
    p = os.path.join(d, f)
    if openpyxl:
        sheets = openpyxl.load_workbook(p).sheetnames
    else:
        sheets = re.findall(r'<sheet [^>]*name="([^"]+)"', zipfile.ZipFile(p).read('xl/workbook.xml').decode())
    tab = f[:-5]
    clean = lambda x: re.sub(r'[\\/?*\[\]:]', '', x)[:25].lower()
    for w in grids.get(tab, []):
        assert any(clean(s).startswith(clean(w)) or clean(w) in clean(s) for s in sheets[1:]), f'{f}: no sheet for the grid {w!r} in {sheets}'   # sheet 1 is the export's own Summary
    for w, ncols in empties.get(tab, []):
        k = next((i for i, s in enumerate(sheets) if i > 0 and (clean(s).startswith(clean(w)) or clean(w) in clean(s))), None)
        assert k is not None, f'{f}: no sheet for the empty grid {w!r} in {sheets}'
        xml = zipfile.ZipFile(p).read(f'xl/worksheets/sheet{k + 1}.xml').decode()
        rows = re.findall(r'<row [^>]*>(.*?)</row>', xml, re.S)
        assert ncols > 0 and len(rows) == 1 and len(re.findall(r'<c ', rows[0])) == ncols, f'{f}: the empty grid {w!r}: {len(rows)} row(s), {len(re.findall(chr(60) + "c ", rows[0])) if rows else 0} header cell(s), want its header row alone with {ncols}'
        checked += 1
        print(f'ok   {f}: the empty grid {w!r} is the sheet {sheets[k]!r}, its header row alone ({ncols} columns)')
    print(f'ok   {f}: {len(sheets)} sheet(s) {sheets}' + ('' if openpyxl else ' (read as a zip: openpyxl is not on this machine)'))
assert checked >= 1, 'no empty grid was exported (the seed leaves pgaudit\'s grid on User Actions empty)'
PY
[ -n "$SHOTS" ] && mkdir -p "$SHOTS/xlsx" && cp "$WORK"/xlsx/*.xlsx "$SHOTS/xlsx/"
echo "G: OK"
kill "$CHRPID" "$SRVPID" 2>/dev/null || true; wait "$CHRPID" "$SRVPID" 2>/dev/null || true; CHRPID=; SRVPID=
if [ "${PGVIGIL_REPORTS_KEEP:-}" != 1 ]; then
  docker rm -f -v "$PCT" "$MCT" >/dev/null; PCT=; MCT=
  ! docker container inspect "pgv169-pg-$SUF" >/dev/null 2>&1 && ! docker container inspect "pgv169-ms-$SUF" >/dev/null 2>&1 || fail "a container of this run is left"
fi
echo "PROOF OK: reports (A B C D E F G)"
