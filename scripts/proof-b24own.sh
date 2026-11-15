#!/usr/bin/env bash
# Proof of B24 OWN, the server half (PerformanceMonitor Fixed 12: pgvigil's own sessions hidden on running queries and
# waiting tasks by default, with a switch, both engines; the design notes/projects/pdfp-sqltoolsbuild-s3/
# pdfp-sqltoolsbuild-s3-b24-own-design.md of the DBA repo, its FOLD; migration 0265). One SQL Server container
# (MSSQL_IMAGE, default 2022) and the box's PostgreSQL (PGVIGIL_ADMIN_DSN, keyword form, a superuser): a repository, a
# PostgreSQL target database and its logins of the proof's own, removed on every exit path the shell can catch.
# 'Own' is decided by the collector on the monitored server: SQL Server (program_name = PROGRAM_NAME() OR LIKE
# 'pgvigil%') AND login_name = SUSER_SNAME(); PostgreSQL application_name LIKE 'pgvigil%' AND usename = current_user.
#
# Expected (written before the first run):
#  S1 SQL Server, the stored flag (mssql_requests.is_own): sessions of pgvigil's login named pgvigil-proof (idle in a
#     WAITFOR), pgvigil-proof2 (blocked behind l1) and pgvigil-proof3 (a 120 s WAITFOR) are own; pgvigil-actions-proof is
#     NOT [refined after the red, before any green: the collector never marks an actions-door session own - it runs a
#     customer's statement, and waiting tasks store no program for a read-time rule]; a session named pgvigil-x under
#     ANOTHER login (l1) and l1's blocker are not.
#  S2 GET /api/mssql/running at that snapshot, own absent: pgvigil-proof and pgvigil-proof3 absent, pgvigil-x shown (the
#     lead's red: a pgvigil-labelled session not of pgvigil's login stays visible), own_hidden = the stored own rows less
#     the never-hidden ones (2); own=1 shows all, own_hidden 0.
#  S3 never hidden even when own: pgvigil-proof2 (blocked) and pgvigil-actions-proof (the actions door) shown and marked
#     own; S3b pgvigil-proof3 read again past 60 s: shown by default.
#  S4 a row stored before 0265 (is_own NULL) shown in both switch states.
#  S5 waiting tasks (mssql_waiting_tasks.is_own, GET /api/waiting part tasks): pgvigil-proof2's lock wait shown (blocked);
#     a stored own task with no blocker and a 1 s wait hidden by default, shown with own=1.
#  P1 PostgreSQL (activity_sample.is_own): a backend of the collector's login named pgvigil-proof in pg_sleep is own; one
#     named pgvigil-x under another login is not; P2 GET /api/activity: pgvigil-proof absent by default, pgvigil-x shown,
#     own=1 shows both; P3 an own backend waiting on a lock the other login holds is shown by default.
#  Red on 75c72186 (before 0265): S1 'no column is_own'.
set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?}"
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvb24-sql-$SUF; REPO=pgv_b24_$SUF; TGT=pgv_b24_tgt_$SUF; PGCOL=pgvb24col$SUF; PGOTHER=pgvb24oth$SUF
MON=pgvb24mon$SUF; USR=b24u$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
WORK=$(mktemp -d); SRV=""; BG=()
SA_PW=$(pw); MON_PW=$(pw); LP_PW=$(pw); UPW=$(pw); PGPW=p$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$WORK/sa.env"
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  docker rm -f -v "$SQL" >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" -c "drop database if exists $TGT with (force)" \
    -c "drop role if exists $PGCOL" -c "drop role if exists $PGOTHER" >/dev/null 2>&1 || echo "CLEANUP: $REPO / $TGT / roles not dropped" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in docker go psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
# the lead's file: web.go's activity handler (sqlSessionsOwn) - applied to this copy when the tree has the queries and
# web.go lacks them (PGVIGIL_WIRING=0 leaves it out)
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && grep -q 'const sqlSessionsOwn = ' internal/web/queries.go 2>/dev/null && ! grep -q 'sqlSessionsOwn' internal/web/web.go; then
  git apply scripts/proof-b24own-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-b24own-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (web.go's activity handler)"
fi
urlq() { V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["V"], safe=""))'; }

# ---- SQL Server ----------------------------------------------------------------------------------------------------------
docker run -d --name "$SQL" --label pgvigil-proof=b24own --memory 8g --env-file "$WORK/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null || fail "docker run"
SQLCMD=; for _ in $(seq 1 60); do for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do docker exec "$SQL" test -x "$c" 2>/dev/null && SQLCMD=$c && break 2; done; sleep 1; done
[[ -n "$SQLCMD" ]] || fail "no sqlcmd"; TRUST=; [[ "$SQLCMD" == *tools18* ]] && TRUST=-C
sq() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout 120 docker exec -i --env-file "$WORK/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
for _ in $(seq 1 150); do [[ "$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null)" == 1 ]] && break; sleep 2; done
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
sq "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];
    CREATE LOGIN [l1] WITH PASSWORD = '$LP_PW', CHECK_POLICY = OFF; CREATE DATABASE pgvb24;" >/dev/null || fail "SQL Server logins"
sq "CREATE TABLE dbo.hold (id int PRIMARY KEY, v int NOT NULL); INSERT dbo.hold VALUES (1, 0);
    CREATE USER [$MON] FOR LOGIN [$MON]; CREATE USER [l1] FOR LOGIN [l1]; GRANT SELECT, UPDATE ON dbo.hold TO [$MON], [l1];" pgvb24 >/dev/null || fail "dbo.hold"

# ---- PostgreSQL: the repository, the target, the collector's login and another --------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" -c "create database $TGT" \
  -c "create role $PGCOL login password '$PGPW' in role pg_monitor" -c "create role $PGOTHER login password '$PGPW'" >/dev/null || fail "PostgreSQL setup"
psql "$PGVIGIL_ADMIN_DSN dbname=$TGT" -XAtq -c "create table hold (id int primary key, v int); insert into hold values (1, 0);
  grant select, update on hold to $PGCOL, $PGOTHER" >/dev/null || fail "the target's table"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export PGV_B24_PG="$PGVIGIL_ADMIN_DSN dbname=$TGT user=$PGCOL password=$PGPW"
export PGV_B24_SS="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: ss\n    engine: sqlserver\n    dsn: env:PGV_B24_SS\n  - name: pg\n    dsn: env:PGV_B24_PG\n' > "$WORK/cfg.yaml"
CFG=$WORK/cfg.yaml
go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "go build"
go build -o "$WORK/hold" ./scripts/proof-b24own-hold || fail "go build the holder"
"$WORK/pgvigil" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out" >&2; fail "migrate"; }
col() { timeout 300 "$WORK/pgvigil" collect -config "$CFG" -instance "$1" -once "$2" > "$WORK/col.out" 2>&1 || { cat "$WORK/col.out" >&2; fail "collect $1 $2"; }; }
col ss mssql_instance; col pg activity
ISS=$(q "select instance_id from pgvigil.instances where name = 'ss'"); IPG=$(q "select instance_id from pgvigil.instances where name = 'pg'")
[[ -n "$ISS" && -n "$IPG" ]] || fail "setup: the instances"
ok "setup: SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"), PostgreSQL target $TGT; instances ss $ISS, pg $IPG"

# ---- the SQL Server sessions ----------------------------------------------------------------------------------------------
# hold <login> <password> <app> <seconds> <batch>: one session (the holder) in its own process group
hold() { PGV_HOLD_DSN="sqlserver://$1:$(urlq "$2")@127.0.0.1:$PORT_SQL?database=pgvb24&encrypt=true&TrustServerCertificate=true&app+name=$(urlq "$3")" \
  setsid "$WORK/hold" "$4" "$5" > "$WORK/hold-$3.out" 2>&1 & BG+=($!); }
hold l1 "$LP_PW" l1-blocker 300 "BEGIN TRAN; UPDATE dbo.hold SET v = v + 1 WHERE id = 1;"
sleep 2
hold "$MON" "$MON_PW" pgvigil-proof 300 "WAITFOR DELAY '00:00:50';"
hold "$MON" "$MON_PW" pgvigil-proof2 300 "UPDATE dbo.hold SET v = v + 1 WHERE id = 1;"
hold "$MON" "$MON_PW" pgvigil-actions-proof 300 "WAITFOR DELAY '00:00:50';"
hold "$MON" "$MON_PW" pgvigil-proof3 300 "WAITFOR DELAY '00:02:00';"
hold l1 "$LP_PW" pgvigil-x 300 "WAITFOR DELAY '00:00:50';"
for _ in $(seq 1 60); do [[ $(sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.program_name IN ('pgvigil-proof', 'pgvigil-proof2', 'pgvigil-actions-proof', 'pgvigil-proof3', 'pgvigil-x')") == 5 ]] && break; sleep 0.5; done
col ss mssql_requests; col ss mssql_waiting_tasks
SNAP=$(q "select max(snapshot_at) from pgvigil.mssql_requests where instance_id = $ISS")
OWNCOL=$(q "select count(*) from information_schema.columns where table_schema = 'pgvigil' and table_name = 'mssql_requests' and column_name = 'is_own'")
[[ $OWNCOL == 1 ]] || fail "S1: no column is_own on pgvigil.mssql_requests (red before 0265)"
GOT=$(q "select string_agg(program_name || '=' || coalesce(is_own::text, 'null'), ' ' order by program_name collate \"C\") from pgvigil.mssql_requests
          where instance_id = $ISS and snapshot_at = '$SNAP' and (program_name like 'pgvigil%' or program_name = 'l1-blocker')")
[[ $GOT == "l1-blocker=false pgvigil-actions-proof=false pgvigil-proof=true pgvigil-proof2=true pgvigil-proof3=true pgvigil-x=false" ]] || fail "S1: the stored flags: $GOT"
ok "S1: is_own stored by the collector: pgvigil's login's three sessions own; the actions door's, pgvigil-x under l1 and l1's blocker not ($GOT)"

# ---- serve -------------------------------------------------------------------------------------------------------------------
PGVIGIL_PASSWORD=$UPW "$WORK/pgvigil" user add -config "$CFG" "$USR" >/dev/null 2>&1 || fail "user add"
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
"$WORK/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 & SRV=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
J=$WORK/jar
[[ $(curl -s -o /dev/null -w '%{http_code}' -c "$J" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$USR\",\"password\":\"$UPW\"}" "$U/api/login") == 200 ]] || fail "the API login"
get() { curl -s -o "$WORK/out.json" -w '%{http_code}' -b "$J" -H 'X-Pgvigil: 1' "$U$1"; }
# progs <part> [table key]: the programs of a part's rows (program_name or application_name), sorted
progs() { python3 -c "
import json,sys; d=json.load(open('$WORK/out.json')); t=d[sys.argv[1]] if sys.argv[1] in d else d
rows=[dict(zip(t['columns'], r)) for r in (t.get('rows') or [])]
print(' '.join(sorted({r.get('program_name') or r.get('application_name') or '' for r in rows} - {''})))" "$1"; }
# hid <part>: own_hidden of the reply - a number, a {part: n} map, or a {columns, rows} part with a column per part
hid() { python3 -c "
import json,sys; d=json.load(open('$WORK/out.json')); v=d.get('own_hidden')
if isinstance(v, dict) and 'columns' in v: v = dict(zip(v['columns'], (v.get('rows') or [[None] * len(v['columns'])])[0]))
print(v.get(sys.argv[1]) if isinstance(v, dict) else v)" "$1"; }
SNAPU=$(q "select to_char('$SNAP'::timestamptz at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")

c=$(get "/api/mssql/running?instance=$ISS&at=$SNAPU"); [[ $c == 200 ]] || fail "S2: HTTP $c"
P=$(progs rows)
[[ " $P " == *" pgvigil-x "* && " $P " != *" pgvigil-proof "* && " $P " != *" pgvigil-proof3 "* ]] || fail "S2: the default's programs: $P"
[[ " $P " == *" pgvigil-proof2 "* && " $P " == *" pgvigil-actions-proof "* ]] || fail "S3: a never-hidden own session hidden: $P"
[[ $(hid rows) == 2 ]] || fail "S2: own_hidden $(hid rows), want 2 (pgvigil-proof, pgvigil-proof3)"
c=$(get "/api/mssql/running?instance=$ISS&at=$SNAPU&own=1"); [[ $c == 200 ]] || fail "S2 own=1: HTTP $c"
P1=$(progs rows); [[ " $P1 " == *" pgvigil-proof "* && " $P1 " == *" pgvigil-proof3 "* && " $P1 " == *" pgvigil-x "* && $(hid rows) == 0 ]] || fail "S2 own=1: $P1 / $(hid rows)"
ok "S2: by default pgvigil's own idle sessions hidden (own_hidden 2), pgvigil-x of another login shown; own=1 shows all. S3: the blocked and the actions-door own sessions shown"
python3 -c "
import json; d=json.load(open('$WORK/out.json')); t=d['rows']; rows=[dict(zip(t['columns'], r)) for r in t['rows']]
m={r['program_name']: r.get('is_own') for r in rows if r.get('program_name')}
import sys; sys.exit(0 if m.get('pgvigil-proof2') is True and m.get('pgvigil-x') is False else 1)" || fail "S3: the rows do not carry is_own (the page's mark)"
# S3b: pgvigil-proof3 past 60 s
sleep 62; col ss mssql_requests
SNAP2=$(q "select to_char(max(snapshot_at) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') from pgvigil.mssql_requests where instance_id = $ISS")
get "/api/mssql/running?instance=$ISS&at=$SNAP2" >/dev/null; P2=$(progs rows)
[[ " $P2 " == *" pgvigil-proof3 "* ]] || fail "S3b: pgvigil-proof3 past 60 s hidden: $P2"
ok "S3b: an own request past 60 s shown by default"
# S4: stored before 0265
q "update pgvigil.mssql_requests set is_own = null where instance_id = $ISS and snapshot_at = '$SNAP' and program_name = 'pgvigil-proof'" >/dev/null
get "/api/mssql/running?instance=$ISS&at=$SNAPU" >/dev/null; P4=$(progs rows)
[[ " $P4 " == *" pgvigil-proof "* ]] || fail "S4: a row with is_own NULL hidden: $P4"
ok "S4: a row stored before 0265 (is_own NULL) shown"
# S5: waiting tasks
# the waiting tasks' own read (collected just after the requests' read: its own time)
WS=$(q "select max(snapshot_at) from pgvigil.mssql_waiting_tasks where instance_id = $ISS")
WSU=$(q "select to_char('$WS'::timestamptz at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")
c=$(get "/api/waiting?instance=$ISS&part=tasks&at=$WSU"); [[ $c == 200 ]] || fail "S5: HTTP $c"
python3 -c "import json,sys; d=json.load(open('$WORK/out.json')); t=d['tasks']; rows=[dict(zip(t['columns'], r)) for r in (t['rows'] or [])]; sys.exit(0 if any(r.get('wait_type','').startswith('LCK') for r in rows) else 1)" || fail "S5: the blocked own task hidden"
q "insert into pgvigil.mssql_waiting_tasks (instance_id, snapshot_at, session_id, exec_context_id, wait_type, wait_ms, is_own)
   values ($ISS, '$WS', 9999, 0, 'PAGEIOLATCH_SH', 1000, true)" >/dev/null || fail "S5: the staged own task"
get "/api/waiting?instance=$ISS&part=tasks&at=$WSU" >/dev/null
python3 -c "import json,sys; d=json.load(open('$WORK/out.json')); t=d['tasks']; sys.exit(0 if all(r[t['columns'].index('session_id')] != 9999 for r in (t['rows'] or [])) else 1)" || fail "S5: the staged own task shown by default"
get "/api/waiting?instance=$ISS&part=tasks&at=$WSU&own=1" >/dev/null
python3 -c "import json,sys; d=json.load(open('$WORK/out.json')); t=d['tasks']; sys.exit(0 if any(r[t['columns'].index('session_id')] == 9999 for r in (t['rows'] or [])) else 1)" || fail "S5: own=1 does not show the staged own task"
ok "S5: waiting tasks: the blocked own task shown; a stored own task with no blocker hidden by default, shown with own=1"

# ---- PostgreSQL ---------------------------------------------------------------------------------------------------------------
pgbg() { PGAPPNAME=$1 setsid psql "$PGVIGIL_ADMIN_DSN dbname=$TGT user=$2 password=$PGPW" -XAtq -c "$3" > /dev/null 2>&1 & BG+=($!); }
pgbg pgvigil-x "$PGOTHER" "begin; lock table hold in access exclusive mode; select pg_sleep(60); commit"
sleep 1
pgbg pgvigil-proof "$PGCOL" "select pg_sleep(50)"
pgbg pgvigil-proof2 "$PGCOL" "select * from hold"
for _ in $(seq 1 30); do [[ $(psql "$PGVIGIL_ADMIN_DSN dbname=$TGT" -XAtq -c "select count(*) from pg_stat_activity where application_name in ('pgvigil-x', 'pgvigil-proof', 'pgvigil-proof2')") == 3 ]] && break; sleep 0.5; done
col pg activity
GOTP=$(q "select string_agg(application_name || '=' || coalesce(is_own::text, 'null'), ' ' order by application_name collate \"C\") from pgvigil.activity_sample
           where instance_id = $IPG and snapshot_at = (select max(snapshot_at) from pgvigil.activity_sample where instance_id = $IPG) and application_name like 'pgvigil-%'")
[[ $GOTP == "pgvigil-proof=true pgvigil-proof2=true pgvigil-x=false" ]] || fail "P1: the stored flags: $GOTP"
ok "P1: is_own stored: the collector's login's backends own, pgvigil-x under another login not"
get "/api/activity?instance=$IPG" >/dev/null; PA=$(progs sessions)
[[ " $PA " == *" pgvigil-x "* && " $PA " != *" pgvigil-proof "* && " $PA " == *" pgvigil-proof2 "* ]] || fail "P2/P3: the default's applications: $PA"
get "/api/activity?instance=$IPG&own=1" >/dev/null; PB=$(progs sessions)
[[ " $PB " == *" pgvigil-proof "* ]] || fail "P2: own=1: $PB"
ok "P2: by default the own backend in pg_sleep hidden, pgvigil-x shown, own=1 shows it; P3: the own backend waiting on the lock shown"
echo "PASS: proof-b24own"
