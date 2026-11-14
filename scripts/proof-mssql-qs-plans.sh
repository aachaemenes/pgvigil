#!/usr/bin/env bash
# Proof of task 406 (B12): Query Store and plans. One SQL Server container per run (MSSQL_IMAGE; the box job runs it
# once per version: 2017, 2019, 2022, 2025), a repository database of its own, pgvigil built from this tree.
# Needs: docker, go, psql, curl, python3, and:
#   ADMIN_DSN            a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1
#                        port=5432 user=postgres dbname=postgres'); the proof makes its own repository database and
#                        drops it.
#   MSSQL_IMAGE          the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PLAN_EXTRACT the plan plugin's extract.py (default .lab/extract.py, git-ignored; never fetched): the
#                        .sqlplan check of part B
#   PGVIGIL_PARTS        the parts to run (default every part this file has)
#   PGVIGIL_WIRING       1 (default) applies scripts/proof-mssql-qs-plans-wiring.patch (web.go: the lead's file) to
#                        this copy when the tree has the handlers and web.go lacks their routes; 0 = the tree as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written before the first run):
#  A. the container: a monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION, an msdb reader), database pgvqs with
#     dbo.t (5,000 rows), procedure dbo.p_two (two statements), dbo.p_enc WITH ENCRYPTION, a workload run; three
#     instances of the config on the one server: sqlfull (query_text full), sqlnone (none), sqlnorm (normalized);
#     mssql_plancache read twice for sqlfull and once each for the other two.
#  B. a cached plan by handle, on demand (rows O4b.10, F1, F4, F8):
#     B1 GET /api/mssql/plancache/entries for p_two's first statement (database id and query key) lists the cache
#        entry whose plan handle, start and end offsets and plan hash equal a hand read of sys.dm_exec_query_stats;
#        fetch_off '' on sqlfull;
#     B2 GET /api/mssql/plancache/plan at those offsets with the row's hash: state ok, plan_hash = the hand read's
#        query_plan_hash, objtype Proc, object dbo.p_two, the XML's root ShowPlanXML with one StmtSimple whose text is
#        the first statement's (not the second's); the file name ends .sqlplan; extract.py reads the saved file
#        (exit 0) and its digest names dbo.t; the batch read (0, -1) holds both statements;
#     B3 the same read with hash 0x1234: state changed, the words naming both hashes;
#     B4 p_enc's entry: state encrypted, no plan in the reply;
#     B5 the shell of a simple-parameterized statement (its handle read by hand from sys.dm_exec_cached_plans):
#        state parameterized, no plan;
#     B6 under full, a statement carrying PASSWORD = '<secret>' in a comment: the reply's plan holds '<masked>' and not
#        the secret and still parses as XML (when the raw showplan read by hand carries it; else NOT PROVEN with why);
#     B7 sqlnone and sqlnorm: entries' fetch_off names the policy ("none" / "normalized"), the plan read answers state
#        off with the same words and no plan;
#     B8 a handle evicted by hand (DBCC FREEPROCCACHE as sa) answers 404 with the 'no plan under this handle' words;
#     B9 a handle of odd length, one of 65 bytes, a bad key, an end before the start: 400 each;
#     B10 after the reads no session of the read login named pgvigil-plan stays open (each read closes its connection).
#     Red on f8e89d2: the two routes do not exist (B1 is not a JSON reply with entries).
#  C. the plans of running queries (rows N55 and SQLWATCH COL#27's capture, F6, F7, F18 P1); instances rpon (schedules:
#     mssql_running_plans and mssql_live_plans 1m), rpoff (no schedules), rpnone (query_text none, schedules on):
#     C1 one case per threshold, each alone, read by 'collect -once mssql_running_plans -instance rpon' while it runs:
#        a statement blocked 12 s (reasons 'duration'), a CPU-bound statement read at 3 s ('cpu'), two sessions blocked
#        on one plan for 3 s ('count'), a sort over dbo.big blocked while it holds its memory grant ('grant', when the
#        grant read by hand is 50 MB or more; else NOT PROVEN with the grant read); each row's key equals the hand read
#        of sys.dm_exec_requests (query hash, plan hash, offsets), its plan stored (plan_state read, ShowPlanXML);
#     C2 below every threshold (one session blocked 2 s, little CPU, a small grant): no row; the blocker's WAITFOR
#        (a zero plan hash): no row with plan hash 0x0000000000000000;
#     C3 rpnone (query_text none) during the 12 s block: its row stored with plan_state 'policy' and no plan;
#     C4 GET /api/mssql/runningplans lists rpon's rows with their reasons; /runningplans/plan returns the duration case's
#        ShowPlanXML (extract.py reads it); rpnone's answers state none with the policy words;
#     C5 live plan: on a build LivePlanBuildOK passes and SQL Server 2019 or later, a CPU-bound statement read past 61 s
#        of CPU by 'collect -once mssql_live_plans': one mssql_live_plan row whose XML holds RunTimeCountersPerThread; on
#        2017 (CU26 or later) with trace flag 7412 off: no row and mssql_live_read's note names trace flag 7412;
#     C6 the switch, under 'pgvigil run' for 150 s with the wiring applied: rpon and rppage (added on Admin > Instances
#        through POST /api/admin/instances) each store the 80 s blocked statement's plan and have an ok
#        mssql_running_plans run; rpoff has no mssql_running_plans run at all and no row.
#     Red on f8e89d2: no such collection (collect -once refuses mssql_running_plans).
#  D. the statistics a plan was compiled with (PerformanceMonitor 3.13 Added 1, F10, P5), database pgvqs2 with Query Store
#     on: four tables of 20,000 rows, each with a statistic on v made WITH FULLSCAN, 30 % of rows changed, then one query
#     each read through mssql_querystore (and mssql_indexes for the rows):
#     D0 AUTO_UPDATE_STATISTICS on, synchronous: the statistic is updated before the compile: stale_at_compile false;
#     D1 AUTO_UPDATE_STATISTICS off: stale true; D2 on with ASYNC: stale true (the compile uses the old statistic);
#     D3 on, the statistic made WITH NORECOMPUTE: stale true;
#     each row's modification_count equals the plan's own StatisticsInfo read by hand from sys.query_store_plan, table
#     rows 20,000, the auto-update line min(4,500, sqrt(1000 x 20,000)) = 4,472; the finding 'a plan compiled on stale
#     statistics' names D1-D3's plans and not D0's; GET /api/mssql/planstats answers D1's rows.
#     On a server whose plans carry no OptimizerStatsUsage (before 2017 / 2016 SP2) D is NOT PROVEN, said so.
#     Red on f8e89d2: no mssql_plan_stat table.
#  E. a forced plan's failures (PerformanceMonitor 3.13 Changed 15, F9, P6), in pgvqs2: a query (OPTION (RECOMPILE)) whose
#     plan seeks ix_f is forced, ix_f dropped, then each run is one failure; mssql_querystore read after each step:
#     E1 one failure in one read: the finding 'a forced plan fails' is info, its detail 'Held: it failed once';
#     E2 two more failures in the next read (one read saw 2): warning, 'one read saw 2 or more';
#     E3 the plan forced anew (count back to 0): a reset row; one failure after it: info again (a new window);
#     E4 one more failure in the next read: warning, 'two within 24 hours';
#     E5 the window's first failure moved 25 h back in the repository: info again (it starts over after 24 h);
#     GET /api/mssql/forcefail lists the plan with its reads.
#     Red on f8e89d2: no mssql_qs_force_fail table; 'a forced plan fails' is a warning at E1.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
EXTRACT=${PGVIGIL_PLAN_EXTRACT:-.lab/extract.py}
PARTS=${PGVIGIL_PARTS:-ABCDE}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvqs-sql-$SUF; LBL=pgvigil-proof=406
PGDB=pgv_qs_$SUF; MON=pgv_qmon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
part() { [[ "$PARTS" == *"$1"* ]]; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; RUNPID=; BG=()
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$RUNPID" ]] && kill "$RUNPID" 2>/dev/null || true
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 setsid; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
[[ -s "$EXTRACT" ]] || fail "needs $EXTRACT (the plan plugin's extract.py)"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && grep -q 'func (s \*Server) MSSQLPlanCachePlan' internal/web/*.go && ! grep -q 'mssql/plancache/plan' internal/web/web.go; then
  git apply scripts/proof-mssql-qs-plans-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-mssql-qs-plans-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (web.go)"
fi

echo "== A. the container ($IMG_SQL) =="
docker run -d --name "$SQL" --label "$LBL" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
SQLCMD=
for _ in $(seq 1 60); do
  for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do docker exec "$SQL" test -x "$c" 2>/dev/null && SQLCMD=$c && break 2; done
  sleep 1
done
[[ -n "$SQLCMD" ]] || fail "A: no sqlcmd in the image"
TRUST=; [[ "$SQLCMD" == *tools18* ]] && TRUST=-C
# sq: T-SQL as sa (stdin; -I: QUOTED_IDENTIFIER ON); sqok: loud
sq() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout "${3:-120}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
# sqbig: the same for one long value (a showplan): no column width cut (-y 0; sqlcmd takes neither -W nor -h with it)
sqbig() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -y 0 -l 60 -d master -i /dev/stdin'; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
up() { local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done
  docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "A: the SQL Server container did not come up in 300 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
VER=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")
sqok "A: the monitor login (docs/sqlserver.md's)" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON];"
sqok "A: the monitor's msdb user" "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb
sqok "A: the database" "CREATE DATABASE pgvqs; ALTER DATABASE pgvqs SET RECOVERY SIMPLE;"
sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NOT NULL, pad char(100) NOT NULL DEFAULT 'p');
  INSERT dbo.t (id, a) SELECT TOP (5000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE INDEX ix_a ON dbo.t (a) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);" pgvqs
sqok "A: dbo.big (the grant case of C)" "CREATE TABLE dbo.big (id int NOT NULL PRIMARY KEY, pad char(100) NOT NULL);
  INSERT dbo.big (id, pad) SELECT TOP (600000) n, CONVERT(char(100), NEWID()) FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y CROSS JOIN (SELECT TOP 10 1 z FROM sys.all_objects) w) q;" pgvqs
sqok "A: p_two" "CREATE PROCEDURE dbo.p_two AS
BEGIN
  SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a < 100;
  SELECT MAX(t1.pad) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id > 10;
END" pgvqs
sqok "A: p_enc" "CREATE PROCEDURE dbo.p_enc WITH ENCRYPTION AS SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a > 4000;" pgvqs
WORK="EXEC dbo.p_two; EXEC dbo.p_two; EXEC dbo.p_two; EXEC dbo.p_enc; EXEC dbo.p_enc;
SELECT /* PASSWORD = 'pgvsecret$SUF' */ COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.a = -1;
GO
SELECT a FROM dbo.t WHERE id = 7"
sqok "A: the workload" "$WORK" pgvqs

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_Q_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
cat > "$TMPD/m.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlfull
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: full
  - name: sqlnone
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: none
  - name: sqlnorm
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: normalized
  - name: rpon
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: full
    schedules:
      mssql_running_plans: 1m
      mssql_live_plans: 1m
  - name: rpoff
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: full
  - name: rpnone
    engine: sqlserver
    dsn: env:PGV_Q_MON
    query_text: none
    schedules:
      mssql_running_plans: 1m
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col() { local i=$1; shift; for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance "$i" -once "$c" >"$TMPD/col-$i-$c.out" 2>&1 || { cat "$TMPD/col-$i-$c.out" >&2; fail "collect $i $c"; }; done; }
col sqlfull mssql_instance mssql_plancache
sqok "A: the workload again" "$WORK" pgvqs
col sqlfull mssql_plancache
col sqlnone mssql_instance mssql_plancache
col sqlnorm mssql_instance mssql_plancache
IF=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlfull'"); IN=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlnone'"); IZ=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlnorm'")
echo "ok   A: SQL Server $VER, pgvqs, the workload, sqlfull $IF / sqlnone $IN / sqlnorm $IZ read"

PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "A: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "A: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "A: the API login"
# api <path?query> <out>: the reply's body in <out>, the HTTP code printed
api() { curl -s -o "$2" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/$1"; }

if part B; then
echo "== B. a cached plan by handle, on demand =="
DBID=$(sq "SELECT DB_ID('pgvqs')")
# the hand read: p_two's two statements and p_enc's, with their keys and handles as the collector writes them (0x, upper)
sq "SELECT CASE WHEN SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%t1.a < 100%' THEN 'first'
                WHEN SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%t1.id > 10%' THEN 'second'
                WHEN t.objectid = OBJECT_ID('pgvqs.dbo.p_enc') THEN 'enc'
                WHEN SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%pgvsecret%' THEN 'secret' END
  + '|' + CONVERT(varchar(140), qs.plan_handle, 1) + '|' + CAST(qs.statement_start_offset AS varchar(10)) + '|' + CAST(qs.statement_end_offset AS varchar(10))
  + '|' + CONVERT(varchar(40), qs.query_hash, 1) + '|' + CONVERT(varchar(40), qs.query_plan_hash, 1)
  FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 WHERE (t.dbid = DB_ID('pgvqs') AND t.objectid IN (OBJECT_ID('pgvqs.dbo.p_two'), OBJECT_ID('pgvqs.dbo.p_enc')))
    OR (SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%pgvsecret%' AND t.text NOT LIKE '%dm_exec%')" >"$TMPD/hand-stmts.out" || fail "B: the hand read"
sq "SELECT CONVERT(varchar(140), cp.plan_handle, 1) FROM sys.dm_exec_cached_plans cp CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) t
 WHERE cp.objtype = 'Adhoc' AND t.text LIKE 'SELECT a FROM dbo.t WHERE id = 7%'" >"$TMPD/hand-shell.out" || fail "B: the shell's handle"
sqbig "SELECT q.query_plan FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
 CROSS APPLY sys.dm_exec_text_query_plan(qs.plan_handle, qs.statement_start_offset, qs.statement_end_offset) q WHERE SUBSTRING(t.text, qs.statement_start_offset / 2 + 1, 400) LIKE '%pgvsecret%' AND t.text NOT LIKE '%dm_exec%'" >"$TMPD/hand-secret.out" 2>&1 || true
python3 - "$TMPD" "$U" "$IF" "$IN" "$IZ" "$DBID" "$EXTRACT" "$SUF" <<'PYEND' || fail "B: see above"
import json, os, subprocess, sys, urllib.parse
d, u, i_full, i_none, i_norm, dbid, extract, suf = sys.argv[1:]
bad = []
def api(path, **q):
    out = f"{d}/r.json"
    code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1',
                           f"{u}/api/{path}?{urllib.parse.urlencode(q)}"], capture_output=True, text=True).stdout
    try: body = json.load(open(out))
    except Exception: body = open(out, errors='replace').read()[:200]
    return int(code), body
hand = {}
for l in open(f"{d}/hand-stmts.out"):
    p = l.strip().split('|')
    hx = lambda v: '0x' + v[2:].upper()   # the collector's form: 0x and upper-case digits
    if len(p) == 6 and p[0]: hand[p[0]] = dict(handle=hx(p[1]), start=int(p[2]), end=int(p[3]), qhash=hx(p[4]), phash=hx(p[5]))
for k in ('first', 'second', 'enc', 'secret'):
    if k not in hand: bad.append(f"B the hand read has no {k} statement: {open(d + '/hand-stmts.out').read()[:400]}")
if bad: print('\n'.join('DIFF ' + b for b in bad)); sys.exit(1)
f = hand['first']
# B1
code, b = api('mssql/plancache/entries', instance=i_full, db=dbid, key=f['qhash'])
if code != 200 or not isinstance(b, dict) or 'entries' not in b:
    print(f"DIFF B1 entries: HTTP {code} {str(b)[:200]}"); sys.exit(1)
cols = b['entries']['columns']; rows = [dict(zip(cols, r)) for r in b['entries']['rows']]
mine = [r for r in rows if str(r['plan_handle']) == f['handle'] and r['stmt_start'] == f['start'] and r['stmt_end'] == f['end']]
if not mine: bad.append(f"B1 no entry equals the hand read {f}: {rows}")
elif str(mine[0]['plan_hash']) != f['phash']: bad.append(f"B1 plan hash {mine[0]['plan_hash']} != hand {f['phash']}")
if b.get('fetch_off'): bad.append(f"B1 fetch_off on sqlfull: {b['fetch_off']}")
# B2
code, b = api('mssql/plancache/plan', instance=i_full, handle=f['handle'], start=f['start'], end=f['end'], hash=f['phash'])
if code != 200 or b.get('state') != 'ok': bad.append(f"B2 state: HTTP {code} {str(b)[:300]}")
else:
    x = b.get('plan', '')
    if b.get('plan_hash', '') != f['phash']: bad.append(f"B2 plan_hash {b.get('plan_hash')} != {f['phash']}")
    if b.get('objtype') != 'Proc' or b.get('object') != 'dbo.p_two': bad.append(f"B2 objtype/object {b.get('objtype')} {b.get('object')}")
    if not x.lstrip().startswith('<ShowPlanXML') or x.count('<StmtSimple') != 1 or ('t1.a &lt; 100' not in x and 't1.a < 100' not in x) or 't1.id &gt; 10' in x or 't1.id > 10' in x:
        bad.append(f"B2 the statement's plan: root/StmtSimple/text wrong: {x[:300]}")
    if not str(b.get('file', '')).endswith('.sqlplan'): bad.append(f"B2 file {b.get('file')}")
    open(f"{d}/p.sqlplan", 'w', encoding='utf-8').write(x)
    r = subprocess.run([sys.executable, '-I', extract, f"{d}/p.sqlplan"], capture_output=True, text=True)
    if r.returncode != 0 or not ('ix_a' in r.stdout or 'PK__t' in r.stdout): bad.append(f"B2 extract.py rc {r.returncode}: {(r.stdout + r.stderr)[:400]}")
    else: print(f"B2 extract.py read the file: {r.stdout.splitlines()[0][:120] if r.stdout else ''}")
code, b = api('mssql/plancache/plan', instance=i_full, handle=f['handle'], start=0, end=-1)
if code != 200 or b.get('state') != 'ok' or b.get('plan', '').count('<StmtSimple') < 2: bad.append(f"B2 the batch read: HTTP {code} {b.get('state') if isinstance(b, dict) else b} statements {b.get('plan', '').count('<StmtSimple') if isinstance(b, dict) else '-'}")
# B3
code, b = api('mssql/plancache/plan', instance=i_full, handle=f['handle'], start=f['start'], end=f['end'], hash='0x1234')
if code != 200 or b.get('state') != 'changed' or f['phash'].upper() not in b.get('words', '').upper() or '0X1234' not in b.get('words', '').upper(): bad.append(f"B3 changed: HTTP {code} {str(b)[:300]}")
# B4
e = hand['enc']
code, b = api('mssql/plancache/plan', instance=i_full, handle=e['handle'], start=e['start'], end=e['end'])
if code != 200 or b.get('state') != 'encrypted' or b.get('plan'): bad.append(f"B4 encrypted: HTTP {code} {str(b)[:300]}")
# B5
sh = open(f"{d}/hand-shell.out").read().split()
if not sh: bad.append("B5 no shell plan was cached for 'SELECT a FROM dbo.t WHERE id = 7' (simple parameterization)")
else:
    code, b = api('mssql/plancache/plan', instance=i_full, handle='0x' + sh[0][2:].upper(), start=0, end=-1)
    if code != 200 or b.get('state') != 'parameterized' or b.get('plan'): bad.append(f"B5 parameterized: HTTP {code} {str(b)[:300]}")
# B6
s = hand['secret']; raw = open(f"{d}/hand-secret.out", errors='replace').read()
code, b = api('mssql/plancache/plan', instance=i_full, handle=s['handle'], start=s['start'], end=s['end'])
if 'pgvsecret' + suf in raw:
    if code != 200 or 'pgvsecret' in b.get('plan', '') or '<masked>' not in b.get('plan', '').replace('&lt;', '<').replace('&gt;', '>'):
        bad.append(f"B6 the mask: HTTP {code} state {b.get('state')} secret kept {'pgvsecret' in b.get('plan', '')}")
    else:
        import xml.etree.ElementTree as ET
        try: ET.fromstring(b['plan']); print("B6 the raw showplan carries the secret; the reply's plan holds <masked>, not the secret, and parses as XML")
        except Exception as e: bad.append(f"B6 the masked plan is not XML: {e}")
else: print("NOT PROVEN B6: the raw showplan read by hand does not carry the comment's PASSWORD = '...' (so there is nothing to mask): " + raw[:160].replace('\n', ' '))
# B7
for inst, word in ((i_none, 'none'), (i_norm, 'normalized')):
    code, b = api('mssql/plancache/entries', instance=inst, db=dbid, key=f['qhash'])
    if code != 200 or f'"{word}"' not in b.get('fetch_off', ''): bad.append(f"B7 {word} entries fetch_off: {str(b)[:300]}")
    code, b = api('mssql/plancache/plan', instance=inst, handle=f['handle'], start=f['start'], end=f['end'])
    if code != 200 or b.get('state') != 'off' or f'"{word}"' not in b.get('words', '') or b.get('plan'): bad.append(f"B7 {word} plan: HTTP {code} {str(b)[:300]}")
# B9
for q, why in ((dict(handle='0x123'), 'odd'), (dict(handle='0x' + '00' * 65), '65 bytes'), (dict(handle=f['handle'], start=100, end=50), 'end before start')):
    code, b = api('mssql/plancache/plan', instance=i_full, **q)
    if code != 400: bad.append(f"B9 {why}: HTTP {code}")
code, b = api('mssql/plancache/entries', instance=i_full, db=dbid, key="0x12;DROP")
if code != 400: bad.append(f"B9 bad key: HTTP {code}")
json.dump(hand, open(f"{d}/hand.json", 'w'))
for x in bad: print('DIFF', x)
sys.exit(1 if bad else 0)
PYEND
NPLAN=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name = 'pgvigil-plan' AND login_name = '$MON'")
[[ "$NPLAN" == 0 ]] || fail "B10: $NPLAN session(s) named pgvigil-plan still open after the reads"
# B8: evict the first statement's plan by hand, then read it
H1=$(python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["first"]; print(h["handle"], h["start"], h["end"])' "$TMPD/hand.json")
read -r HH HS HE <<<"$H1"
sqok "B8: the hand evict" "DBCC FREEPROCCACHE ($HH) WITH NO_INFOMSGS;"
CODE=$(api "mssql/plancache/plan?instance=$IF&handle=$HH&start=$HS&end=$HE" "$TMPD/b8.json")
[[ "$CODE" == 404 ]] && grep -q 'no plan under this handle' "$TMPD/b8.json" || fail "B8: an evicted handle: HTTP $CODE $(head -c 300 "$TMPD/b8.json")"
echo "ok   B: entries equal the hand read; the statement's plan (ok, its hash, Proc dbo.p_two, one statement, extract.py reads it), the batch's; changed; encrypted; parameterized; the mask; none / normalized refused with their words; 404 once evicted; 400 on bad input; no pgvigil-plan session left open"
fi

if part C; then
echo "== C. the plans of running queries =="
# bg <tag> <seconds> <batch>: sa runs the batch in pgvqs in a session of its own (program name pgvqs-<tag>), held open
cat > "$TMPD/bg.sh" <<'BGS'
{ printf 'SET NOCOUNT ON;\nGO\n%s\nGO\n' "$4"; sleep "$3"; } | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$SA_PW exec '"$5"' -S localhost -U sa '"$6"' -d pgvqs -H "$0" -l 120' "pgvqs-$7" >/dev/null 2>&1
BGS
bg() { setsid bash "$TMPD/bg.sh" "$SQL" "$TMPD/sa.env" "$2" "$3" "$SQLCMD" "$TRUST" "$1" & BG+=($!); }
stopbg() { for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || true; done; BG=()
  sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE host_name LIKE 'pgvqs-%' AND session_id <> @@SPID; EXEC (@s);" >/dev/null 2>&1 || true; sleep 1; }
# req <marker>: the hand read of a running request whose text holds the marker: query hash|plan hash|start|end|cpu|grant pages|running ms
req() { sq "SELECT TOP (1) CONVERT(varchar(40), r.query_hash, 1) + '|' + CONVERT(varchar(40), r.query_plan_hash, 1) + '|' + CAST(r.statement_start_offset AS varchar(10)) + '|' + CAST(r.statement_end_offset AS varchar(10))
  + '|' + CAST(r.cpu_time AS varchar(20)) + '|' + CAST(r.granted_query_memory AS varchar(20)) + '|' + CAST(DATEDIFF_BIG(millisecond, r.start_time, GETDATE()) AS varchar(20))
  FROM sys.dm_exec_requests r CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE t.text LIKE '%$1%' AND t.text NOT LIKE '%dm_exec_requests%' ORDER BY r.cpu_time DESC"; }
waitreq() { local v=; for _ in $(seq 1 60); do v=$(req "$1" 2>/dev/null || true); [[ -n "$v" ]] && { echo "$v"; return 0; }; sleep 0.5; done
  sq "SELECT s.host_name + '|' + s.status + '|' + ISNULL(r.status, '-') + '|' + ISNULL(r.wait_type, '-') + '|' + CAST(ISNULL(r.blocking_session_id, 0) AS varchar(10)) + '|' + ISNULL(LEFT(t.text, 120), '-')
    FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t WHERE s.host_name LIKE 'pgvqs-%'" >&2 || true
  req "$1" >&2 || true
  fail "C: no running request $1"; }
VICTIM="SELECT COUNT(*) FROM dbo.t t1 JOIN dbo.t t2 ON t2.id = t1.id WHERE t1.id ="
# held <tag>: until the blocker of that tag sits in its WAITFOR (its lock is taken)
held() { local n=; for _ in $(seq 1 60); do n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgvqs-$1' AND r.wait_type = 'WAITFOR'" 2>/dev/null || echo 0); [[ "$n" == 1 ]] && return 0; sleep 0.5; done; fail "C: the blocker $1 never held its lock"; }
hold() { bg "hold$1" "$2" "BEGIN TRAN; UPDATE dbo.t SET a = a + 1 WHERE id = $1; WAITFOR DELAY '00:03:00'; ROLLBACK;"; held "hold$1"; }
: >"$TMPD/cases.txt"
# C1 duration: blocked 12 s (and C3: rpnone reads the same moment)
hold 5 100; bg dur 100 "$VICTIM 5 /* pgvc-dur */"; waitreq pgvc-dur >/dev/null; sleep 12
echo "duration|$(req pgvc-dur)" >>"$TMPD/cases.txt"
col rpon mssql_running_plans; col rpnone mssql_running_plans
DURQ=$(req pgvc-dur); stopbg
# C1 cpu: a CPU-bound statement read at 3 s
bg cpu 60 "SELECT COUNT_BIG(*) FROM dbo.t a CROSS JOIN dbo.t b CROSS JOIN (SELECT TOP 8 1 x FROM dbo.t) c WHERE a.pad <> b.pad OR a.a > b.a OPTION (MAXDOP 1) /* pgvc-cpu */"
waitreq pgvc-cpu >/dev/null; sleep 3; echo "cpu|$(req pgvc-cpu)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
# C1 count: two sessions on one plan, blocked 3 s
hold 6 100; bg cnt1 100 "$VICTIM 6 /* pgvc-cnt */"; bg cnt2 100 "$VICTIM 6 /* pgvc-cnt */"; waitreq pgvc-cnt >/dev/null; sleep 3
echo "count|$(req pgvc-cnt)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
# C1 grant: a sort over dbo.big holding its grant while it waits on a locked row
bg holdbig 100 "BEGIN TRAN; UPDATE dbo.big SET pad = REVERSE(pad) WHERE id = 300000; WAITFOR DELAY '00:03:00'; ROLLBACK;"; held holdbig
bg grant 100 "SELECT TOP (550000) id, pad FROM dbo.big WHERE id > 0 ORDER BY pad DESC OPTION (MAXDOP 1) /* pgvc-grant */"; waitreq pgvc-grant >/dev/null; sleep 3
echo "grant|$(req pgvc-grant)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
# C2 below every threshold: one session blocked 2 s
hold 7 100; bg low 100 "$VICTIM 7 /* pgvc-low */"; waitreq pgvc-low >/dev/null; sleep 1
echo "low|$(req pgvc-low)" >>"$TMPD/cases.txt"; col rpon mssql_running_plans; stopbg
python3 - "$TMPD" "$PGDSN" "$U" "$EXTRACT" <<'PYEND' || fail "C1-C4: see above"
import json, subprocess, sys, urllib.parse
d, dsn, u, extract = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
def api(path, **qs):
    out = f"{d}/rc.json"
    code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1', f"{u}/api/{path}?{urllib.parse.urlencode(qs)}"], capture_output=True, text=True).stdout
    try: return int(code), json.load(open(out))
    except Exception: return int(code), {}
hx = lambda v: '0x' + v[2:].upper()
bad = []
iid = {n: i for n, i in q("SELECT name, instance_id FROM pgvigil.instances")}
cases = {}
for l in open(f"{d}/cases.txt"):
    k, rest = l.strip().split('|', 1)
    p = rest.split('|')
    if len(p) < 7: bad.append(f"C1 {k}: no hand read ({rest})"); continue
    cases[k] = dict(qh=hx(p[0]), ph=hx(p[1]), start=int(p[2]), end=int(p[3]), cpu=int(p[4]), grant=int(p[5]), running=int(p[6]))
rows = {(r[0], r[1], int(r[2]), int(r[3])): r for r in q(f"SELECT query_hash, plan_hash, stmt_start, stmt_end, reasons, coalesce(plan_state, ''), (plan_xml LIKE '<ShowPlanXML%')::text, max_requests FROM pgvigil.mssql_running_plan WHERE instance_id = {iid['rpon']}")}
want = {'duration': 'duration', 'cpu': 'cpu', 'count': 'count', 'grant': 'grant'}
for k, reason in want.items():
    c = cases.get(k)
    if not c: continue
    r = rows.get((c['qh'], c['ph'], c['start'], c['end']))
    if k == 'grant' and c['grant'] < 6400:
        print(f"NOT PROVEN C1 grant: the sort's grant read by hand was {c['grant']} pages (under 6,400)"); continue
    if not r: bad.append(f"C1 {k}: no row for the hand read {c}; rows {list(rows)[:6]}"); continue
    if reason not in r[4].split(','): bad.append(f"C1 {k}: reasons {r[4]} (want {reason}); hand {c}")
    if r[5] != 'read' or r[6] != 'true': bad.append(f"C1 {k}: plan_state {r[5]}, plan stored {r[6]}")
    others = set(r[4].split(',')) - {reason}
    if others: print(f"C1 {k}: also met {sorted(others)} (hand read cpu {c['cpu']} ms, grant {c['grant']} pages, running {c['running']} ms)")
low = cases.get('low')
if low and (low['qh'], low['ph'], low['start'], low['end']) in rows: bad.append(f"C2 below every threshold, yet stored: {low}")
z = q(f"SELECT count(*) FROM pgvigil.mssql_running_plan WHERE plan_hash ~ '^0x0+$'")
if z[0][0] != '0': bad.append(f"C2 a zero plan hash stored: {z}")
dur = cases.get('duration', {})
n = q(f"SELECT coalesce(plan_state, ''), (plan_xml IS NULL)::text FROM pgvigil.mssql_running_plan WHERE instance_id = {iid['rpnone']} AND query_hash = '{dur.get('qh')}' AND plan_hash = '{dur.get('ph')}'")
if n != [['policy', 'true']]: bad.append(f"C3 rpnone: {n} (want policy, no plan)")
code, b = api('mssql/runningplans', instance=iid['rpon'], **{'from': '2020-01-01T00:00:00Z', 'to': '2100-01-01T00:00:00Z'})
listed = [dict(zip(b['plans']['columns'], r)) for r in b.get('plans', {}).get('rows', [])] if code == 200 else []
if code != 200 or not any(x['query_hash'] == dur.get('qh') and 'duration' in (x['reasons'] or '') for x in listed): bad.append(f"C4 list: HTTP {code} {str(b)[:200]}")
code, b = api('mssql/runningplans/plan', instance=iid['rpon'], qh=dur.get('qh'), ph=dur.get('ph'), start=dur.get('start'), end=dur.get('end'))
if code != 200 or b.get('state') != 'ok' or not b.get('plan', '').startswith('<ShowPlanXML'): bad.append(f"C4 plan: HTTP {code} {str(b)[:200]}")
else:
    open(f"{d}/c.sqlplan", 'w', encoding='utf-8').write(b['plan'])
    r = subprocess.run([sys.executable, '-I', extract, f"{d}/c.sqlplan"], capture_output=True, text=True)
    if r.returncode != 0: bad.append(f"C4 extract.py rc {r.returncode}: {r.stderr[:300]}")
code, b = api('mssql/runningplans/plan', instance=iid['rpnone'], qh=dur.get('qh'), ph=dur.get('ph'), start=dur.get('start'), end=dur.get('end'))
if code != 200 or b.get('state') != 'none' or 'query_text' not in b.get('words', ''): bad.append(f"C4 rpnone plan: HTTP {code} {str(b)[:200]}")
for x in bad: print('DIFF', x)
print(f"C1-C4: cases {sorted(cases)}; rpon rows {len(rows)}")
sys.exit(1 if bad else 0)
PYEND
echo "ok   C1-C4: one row per threshold case with its plan, none below the thresholds or for a zero plan hash, rpnone kept no plan, the API's list and plan"

# C5 the live plan
MAJ=${VER%%.*}
bg live 200 "SELECT COUNT_BIG(*) FROM dbo.t a CROSS JOIN dbo.t b CROSS JOIN (SELECT TOP 100 1 x FROM dbo.t) c WHERE a.pad <> b.pad OR a.a > b.a OPTION (MAXDOP 1) /* pgvc-live */"
waitreq pgvc-live >/dev/null
for _ in $(seq 1 90); do C=$(req pgvc-live | cut -d'|' -f5); [[ -n "$C" && "$C" -ge 61000 ]] && break; sleep 1; done
[[ -n "$C" && "$C" -ge 61000 ]] || fail "C5: the CPU-bound statement did not reach 61 s of CPU (at $C ms)"
col rpon mssql_live_plans; stopbg
LV=$(pq "SELECT count(*) FILTER (WHERE live_xml LIKE '%RunTimeCountersPerThread%') FROM pgvigil.mssql_live_plan l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon'")
LN=$(pq "SELECT coalesce(r.note, '') FROM pgvigil.mssql_live_read r JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpon'")
if (( MAJ >= 15 )); then [[ "$LV" -ge 1 ]] || fail "C5: no live plan with operator counters on $VER (note: $LN)"; echo "ok   C5: a live plan with RunTimeCountersPerThread on $VER"
else [[ "$LV" == 0 && "$LN" == *7412* ]] || fail "C5: on $VER want no live plan and the trace flag 7412 note (live plans $LV, note '$LN')"; echo "ok   C5: on $VER no live plan, the note: $LN"; fi

# C6 the switch, under pgvigil run; rppage added on Admin > Instances
COL=pgv_qcol_$SUF; COL_PW=$(pw)
printf "CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_collector;\n" "$COL" "$COL_PW" | psql "$ADMIN_DSN" -Xq -v ON_ERROR_STOP=1 >/dev/null
export PGV_Q_COL="host=127.0.0.1 port=5432 user=$COL password=$COL_PW dbname=$PGDB"
sed "s|dsn: \"$PGDSN\"|dsn: env:PGV_Q_COL|" "$TMPD/m.yaml" | python3 -c 'import sys
out, skip = [], False
for l in sys.stdin.read().split("\n"):
    if l.startswith("  - name: "): skip = l.split(": ", 1)[1] not in ("rpon", "rpoff")
    if not skip: out.append(l)
print("\n".join(out))' > "$TMPD/collector.yaml"
export ADD_PW="$MON_PW"
python3 -c 'import json, os, sys; print(json.dumps({"op": "add", "name": "rppage", "engine": "sqlserver", "auth": "sql", "host": "127.0.0.1", "port": sys.argv[1], "login": sys.argv[2], "password": os.environ["ADD_PW"], "options": "encrypt=true&TrustServerCertificate=true"}))' "$PORT_SQL" "$MON" > "$TMPD/add.json"
CODE=$(curl -s -o "$TMPD/add.out" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/add.json" "$U/api/admin/instances")
[[ "$CODE" == 200 ]] || fail "C6: adding rppage on Admin > Instances: HTTP $CODE $(head -c 300 "$TMPD/add.out")"
hold 8 200; bg sw 200 "$VICTIM 8 /* pgvc-switch */"; waitreq pgvc-switch >/dev/null
"$TMPD/pgvigil" run -config "$TMPD/collector.yaml" >"$TMPD/run.log" 2>&1 & RUNPID=$!
sleep 150
kill "$RUNPID" 2>/dev/null || true; wait "$RUNPID" 2>/dev/null || true; RUNPID=
SWQ=$(req pgvc-switch | cut -d'|' -f1); SWQ="0x${SWQ:2}"; SWQ=${SWQ^^}; SWQ="0x${SWQ:2}"
stopbg
for n in rpon rppage rpoff; do
  R=$(pq "SELECT count(*) FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$n' AND p.query_hash = '$SWQ'")
  K=$(pq "SELECT count(*) FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$n' AND c.collection = 'mssql_running_plans' AND c.status = 'ok'")
  echo "C6 $n: rows $R, ok runs $K"
  case $n in
    rpoff) [[ "$R" == 0 ]] || fail "C6: rpoff (no schedules) stored a plan" ;;
    *) [[ "$R" -ge 1 && "$K" -ge 1 ]] || { tail -20 "$TMPD/run.log" >&2; fail "C6: $n did not read the running plan under pgvigil run"; } ;;
  esac
done
OFFRUN=$(pq "SELECT count(*) FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'rpoff' AND c.collection = 'mssql_running_plans'")
[[ "$OFFRUN" == 0 ]] || fail "C6: rpoff has an mssql_running_plans run"
echo "ok   C6: under pgvigil run rpon and rppage (added on the page) read the running plan; rpoff ran no mssql_running_plans"
fi

if part D || part E; then
  sqok "D: pgvqs2 with Query Store" "CREATE DATABASE pgvqs2; ALTER DATABASE pgvqs2 SET RECOVERY SIMPLE;
    ALTER DATABASE pgvqs2 SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, QUERY_CAPTURE_MODE = ALL, INTERVAL_LENGTH_MINUTES = 1, DATA_FLUSH_INTERVAL_SECONDS = 60);"
fi

if part D; then
echo "== D. the statistics a plan was compiled with =="
for c in d0 d1 d2 d3; do
  NR=; [[ $c == d3 ]] && NR=", NORECOMPUTE"
  sqok "D: table $c" "CREATE TABLE dbo.$c (id int NOT NULL PRIMARY KEY, v int NOT NULL);
    INSERT dbo.$c (id, v) SELECT TOP (20000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
    CREATE STATISTICS st_v ON dbo.$c (v) WITH FULLSCAN$NR;" pgvqs2
done
# each case under its own database setting, the change and the compile in that setting
dcase() { local c=$1 opt=$2
  sqok "D: $c setting" "$opt" pgvqs2
  sqok "D: $c change" "UPDATE dbo.$c SET v = v + 1 WHERE id % 10 < 3;" pgvqs2
  sqok "D: $c query" "SELECT COUNT(*) FROM dbo.$c WHERE v BETWEEN 100 AND 200 /* pgvd-$c */;" pgvqs2
  sleep 1; }
dcase d0 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS ON; ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS_ASYNC OFF;"
dcase d1 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS OFF;"
dcase d2 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS ON; ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS_ASYNC ON;"
dcase d3 "ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS ON; ALTER DATABASE pgvqs2 SET AUTO_UPDATE_STATISTICS_ASYNC OFF;"
sqok "D: the store flushed" "EXEC sys.sp_query_store_flush_db;" pgvqs2
sqbig "SELECT 'PLAN|' + qt.query_sql_text + '|' + CAST(p.plan_id AS varchar(20)) + '|' + CAST(p.query_plan AS nvarchar(max))
  FROM sys.query_store_plan p JOIN sys.query_store_query q ON q.query_id = p.query_id JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
 WHERE qt.query_sql_text LIKE '%pgvd-d%' AND qt.query_sql_text NOT LIKE '%query_store%'" 2>&1 | sed 's/^/X/' > "$TMPD/d-hand.out" || true
sed -i 's/^X//' "$TMPD/d-hand.out"
col sqlfull mssql_indexes mssql_querystore; col sqlfull mssql_querystore
python3 - "$TMPD" "$PGDSN" "$U" <<'PYEND' || fail "D: see above"
import json, re, subprocess, sys, urllib.parse
d, dsn, u = sys.argv[1:]
def q(s): return [l.split('|') for l in subprocess.run(['psql', dsn, '-XAtq', '-c', s], check=True, capture_output=True, text=True).stdout.splitlines() if l]
bad = []
raw = open(f"{d}/d-hand.out", errors='replace').read()
hand = {}
for m in re.finditer(r"PLAN\|.*?pgvd-(d\d).*?\|(\d+)\|(<ShowPlanXML.*?</ShowPlanXML>)", raw, re.S):
    c, plan_id, x = m.group(1), m.group(2), m.group(3)
    st = re.search(r'<StatisticsInfo[^>]*Table="\[' + c + r'\]"[^>]*Statistics="\[st_v\]"[^>]*>', x) or re.search(r'<StatisticsInfo[^>]*Statistics="\[st_v\]"[^>]*Table="\[' + c + r'\]"[^>]*>', x)
    mc = re.search(r'ModificationCount="(\d+)"', st.group(0)).group(1) if st else None
    hand[c] = (plan_id, mc)
if not hand:
    print("NOT PROVEN D: no plan of the four queries read by hand from sys.query_store_plan: " + raw[:300].replace('\n', ' ')); sys.exit(0)
if all(v[1] is None for v in hand.values()):
    print(f"NOT PROVEN D: the plans carry no OptimizerStatsUsage on this server ({hand})"); sys.exit(0)
iid = q("SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlfull'")[0][0]
want = {'d0': 'f', 'd1': 't', 'd2': 't', 'd3': 't'}
for c, stale in want.items():
    if c not in hand: bad.append(f"D {c}: no plan read by hand"); continue
    plan_id, mc = hand[c]
    rows = q(f"SELECT modification_count, table_rows, update_line, coalesce(stale_at_compile::text, ''), modified_pct FROM pgvigil.mssql_plan_stat_status WHERE instance_id = {iid} AND source = 'qs' AND database_name = 'pgvqs2' AND plan_id = {plan_id} AND stat_table = '{c}' AND stat_name = 'st_v'")
    if not rows: bad.append(f"D {c}: no stored statistic for plan {plan_id}"); continue
    r = rows[0]
    if r[0] != mc: bad.append(f"D {c}: modification_count {r[0]} != the plan's {mc}")
    if r[1] != '20000' or r[2] != '4472': bad.append(f"D {c}: table rows {r[1]} / line {r[2]} (want 20000 / 4472)")
    if r[3] != stale[0]: bad.append(f"D {c}: stale_at_compile {r[3]} (want {stale}; modification count {r[0]})")
    f = q(f"SELECT count(*) FROM pgvigil.mssql_querystore_findings WHERE instance_id = {iid} AND check_name = 'a plan compiled on stale statistics' AND object LIKE 'pgvqs2: query %, plan {plan_id}'")
    if (f[0][0] == '1') != (stale == 't'): bad.append(f"D {c}: the finding count {f[0][0]} (stale {stale})")
    print(f"D {c}: plan {plan_id} rows changed {r[0]} of {r[1]} ({r[4]} %), line {r[2]}, stale {r[3]}")
p1 = hand.get('d1', (None,))[0]
out = f"{d}/d.json"
code = subprocess.run(['curl', '-s', '-o', out, '-w', '%{http_code}', '-b', f"{d}/cj", '-H', 'X-Pgvigil: 1', f"{u}/api/mssql/planstats?" + urllib.parse.urlencode({'instance': iid, 'source': 'qs', 'db': 'pgvqs2', 'plan': p1})], capture_output=True, text=True).stdout
b = json.load(open(out)) if code == '200' else {}
rows = [dict(zip(b['stats']['columns'], r)) for r in b.get('stats', {}).get('rows', [])] if b else []
if not any(x['statistic'] == 'st_v' and x['stale_at_compile'] is True for x in rows): bad.append(f"D the API for d1: HTTP {code} {str(b)[:300]}")
for x in bad: print('DIFF', x)
sys.exit(1 if bad else 0)
PYEND
echo "ok   D: the statistics stored per plan equal the plans' own; stale at compile under AUTO_UPDATE off, ASYNC and NORECOMPUTE, not under synchronous updates; the finding and the API"
fi

if part E; then
echo "== E. a forced plan's failures =="
sqok "E: dbo.f" "CREATE TABLE dbo.f (id int NOT NULL PRIMARY KEY, k int NOT NULL, pad char(200) NOT NULL DEFAULT 'f');
  INSERT dbo.f (id, k) SELECT TOP (20000) n, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE INDEX ix_f ON dbo.f (k) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);" pgvqs2
QF="SELECT id FROM dbo.f WITH (INDEX (ix_f)) WHERE k = 5 OPTION (RECOMPILE) /* pgve-forced */;"
sqok "E: the query" "$QF $QF $QF" pgvqs2
sqok "E: flushed" "EXEC sys.sp_query_store_flush_db;" pgvqs2
QP=$(sq "SELECT TOP (1) CAST(q.query_id AS varchar(20)) + '|' + CAST(p.plan_id AS varchar(20)) FROM sys.query_store_query q JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
  JOIN sys.query_store_plan p ON p.query_id = q.query_id WHERE qt.query_sql_text LIKE '%pgve-forced%' AND qt.query_sql_text NOT LIKE '%query_store%' ORDER BY p.plan_id" pgvqs2)
QID=${QP%%|*}; PID=${QP##*|}; [[ -n "$QID" && -n "$PID" ]] || fail "E: the query's ids ($QP)"
sqok "E: forced" "EXEC sys.sp_query_store_force_plan @query_id = $QID, @plan_id = $PID;" pgvqs2
sqok "E: ix_f dropped" "DROP INDEX ix_f ON dbo.f;" pgvqs2
sleep 11   # the forced plan's last run is now more than 10 s before the query's next one
fail_runs() { local i; for i in $(seq 1 "$1"); do sq "SELECT id FROM dbo.f WHERE k = 5 OPTION (RECOMPILE) /* pgve-forced */;" pgvqs2 >/dev/null 2>&1 || true; done; sq "EXEC sys.sp_query_store_flush_db;" pgvqs2 >/dev/null; }
fcount() { sq "SELECT CAST(force_failure_count AS varchar(20)) FROM sys.query_store_plan WHERE plan_id = $PID" pgvqs2; }
judge() { pq "SELECT severity || '|' || detail FROM pgvigil.mssql_querystore_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'sqlfull' AND f.check_name = 'a forced plan fails' AND f.object = 'pgvqs2: query $QID, plan $PID'"; }
expect() { local got; got=$(judge); [[ "${got%%|*}" == "$2" && "$got" == *"$3"* ]] || fail "$1: want $2 with '$3', got '$got' (server count $(fcount))"; echo "ok   $1: $2 ($(fcount) failure(s) on the server)"; }
fail_runs 1; [[ "$(fcount)" == 1 ]] || echo "E1: the server's count after one run: $(fcount)"
col sqlfull mssql_querystore; expect E1 info "Held: it failed once"
fail_runs 2; col sqlfull mssql_querystore; expect E2 warning "one read saw 2 or more"
sqok "E3: forced anew" "EXEC sys.sp_query_store_unforce_plan @query_id = $QID, @plan_id = $PID; EXEC sys.sp_query_store_force_plan @query_id = $QID, @plan_id = $PID;" pgvqs2
col sqlfull mssql_querystore
[[ "$(pq "SELECT count(*) FROM pgvigil.mssql_qs_force_fail WHERE database_name = 'pgvqs2' AND plan_id = $PID AND reset")" -ge 1 ]] || fail "E3: no reset row after forcing anew (server count $(fcount))"
sleep 11; fail_runs 1; col sqlfull mssql_querystore; expect E3 info "Held: it failed once"
fail_runs 1; col sqlfull mssql_querystore; expect E4 warning "two within 24 hours"
pq "UPDATE pgvigil.mssql_qs_force_fail f SET seen_at = seen_at - interval '25 hours'
     WHERE f.database_name = 'pgvqs2' AND f.plan_id = $PID AND f.rise > 0
       AND f.seen_at = (SELECT min(x.seen_at) FROM pgvigil.mssql_qs_force_fail x WHERE x.database_name = 'pgvqs2' AND x.plan_id = $PID AND x.rise > 0
                         AND x.seen_at >= (SELECT max(y.seen_at) FROM pgvigil.mssql_qs_force_fail y WHERE y.database_name = 'pgvqs2' AND y.plan_id = $PID AND y.reset))" >/dev/null
expect E5 info "Held: it failed once"
CODE=$(api "mssql/forcefail?instance=$IF" "$TMPD/e.json"); [[ "$CODE" == 200 ]] && grep -q "\"$PID\"\|,$PID," "$TMPD/e.json" || fail "E: GET /api/mssql/forcefail: HTTP $CODE $(head -c 300 "$TMPD/e.json")"
echo "ok   E: held at one failure, paged at two in one read and at two within 24 h, a new window after forcing anew, held again past 24 h; the API lists it"
fi

echo "PASS: proof-mssql-qs-plans parts $PARTS on SQL Server $VER"
