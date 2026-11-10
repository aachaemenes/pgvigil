#!/usr/bin/env bash
# Proof of parity2 task 121 (migration 0076, internal/web/q_slow.go, q_stmt_trend.go, q_jobs_timeline.go,
# web/src/slow.ts, stmt_trend.ts, jobs_timeline.ts): Slow queries' Group By with DBA Dash's ten buckets, the events
# behind a count and the database filter (DBA Dash 04, 16, 81); a statement's trend under its row (Darling 13.8
# shot 92); the jobs timeline on both engines (DBA Dash 71, 90).
#
# Needs: initdb and pg_ctl (with pg_stat_statements in the install), psql, curl, python3, go, node and the web's
# node_modules (npm ci in web/: esbuild), run at the repository root; PGVIGIL_REPO_DSN, a superuser keyword DSN of
# the PostgreSQL sandbox WITHOUT a password and without dbname (the password from ~/.pgpass).
#
# What it makes, and drops on every exit path: a throwaway cluster (its own data directory, port SST_PORT, default
# 5497, no socket directory, stopped and removed) and its own repository database on the sandbox. Nothing else is
# touched.
#
# The PostgreSQL side is real: statements run on the throwaway cluster, read by the real collectors (instance,
# activity, statements, serverlog). The SQL Server side and the jobs of both engines are imported rows in the
# collectors' shape (import_mssql_xe, import_mssql_jobs, import_jobs): the slow capture and msdb's history are
# proven against a real SQL Server by proof-mssql-xe.sh and proof-jobs-history.sh.
#
# The routes are the lead's lines in web.go: where the tree lacks them the proof builds a scratch copy with exactly
# those four lines and says so.
#
# Expected (written before the first run; T = the proof's start, the API window [T - 1 h, now]):
#  A. 0076: the view slow_events_all and the functions slow_bucket, stmt_trend, slow_trend exist; pgvigil_reader may
#     select the view and execute the three. slow_bucket(4999)=0, (5000)=1, (25000)=3, (60000)=5, (400000)=6,
#     (3600000)=9, (NULL)=0.
#  B. The throwaway cluster (log_min_duration_statement set per session to 500 ms; nothing else logged): z five times
#     and y once (unlogged) before the first statements read, so the second read has their deltas; after the
#     first statements read, statement z (generate_series, 20 runs), y (pg_sleep(0.6), 3 runs, application
#     'pgv-report') and x (pg_sleep(2.5) with a second target entry, 1 run, application 'pgv-orders'; the activity
#     collection reads once while it runs); then statements and serverlog read. log_events holds 4 slow rows: x once
#     (>= 2500 ms), y three times (>= 600 ms).
#  C. Imported: a SQL Server instance S with three slow completions of one shape K (16 hex digits): 6 s OK in Sales,
#     25 s Abort in Sales, 400 s OK in Finance, program 'erp-app', host 'app1', login 'erp_login'.
#  [first run, explained: the requests sent no min, so the API's 1 s default hid y's 0.6 s events; the slow/ requests
#  now send min=500, the cluster's logging floor, as the page does at its 500 ms threshold. The counts below stand.]
#  D. /api/slow/groups (min=500), the fleet, group=instance: P total 4 (b0 4, failed 0), S total 3 (b1 1, b3 1, b6 1, failed 1,
#     total_duration_s 431.000); totals total 7 failed 1; dbs: postgres 4, Sales 2, Finance 1. group=result: OK 6,
#     Abort 1. db=Sales: one group (S) total 2. Instance P, group=text: 2 rows (y's shape 3, x's shape 1).
#     group=app on P: 'pgv-...' absent (the log names none): one NULL group, total 4.
#  E. /api/slow/events: S's Abort (instance=S, group=result, value=Abort): matched 1, duration 25000, application
#     'erp-app', client 'app1', user 'erp_login', failed true. P, group=text, x's shape: matched 1, application
#     'pgv-orders' from 'sample'; y's shape: matched 3, application NULL. Fleet bucket=6: matched 1 (the 400 s one).
#     Fleet failed=1 without a value: matched 1. Fleet without value (the Total row): matched 7. null=1 on P's app
#     group: matched 4.
#  F. /api/stmttrend: y's queryid on P: the calls summed 3, log_events summed 3, the largest log_max_ms >= 600; z's
#     queryid: the calls summed 20, log_events 0, every log_max_ms NULL. shape=K on S: events 3, failed 1, max_ms
#     400000. meta secs 60 for a one-hour window.
#  G. /api/jobs/timeline: P (pg_cron job 1 'nightly', imported): runs r1 (T-40..T-35 min, succeeded), r2
#     (T-38..T-37, failed), r3 (T-10, running, no end), r4 (T-70..T-65, ended before the window), r5 (T-90..T-50,
#     overlaps the window's start): listed r1, r2, r3, r5 = 4 runs, r3's end_time NULL, meta matched 4. S (SQL Agent
#     job J 'etl', imported): run 1 at T-50 min failed in step 2 (95 s; steps 1 ok 60 s, 2 failed 35 s), run 2 at
#     T-3 h (ended before the window): S lists 1 run, outcome failed, failed_step '2 load'; with scheduler=sqlagent
#     &job=J: steps 2 rows (1 succeeded, 2 failed). The fleet: 5 runs.
#  H. The page's arithmetic (jobs_timeline.ts atOnce, run under node): runs [0,10) [5,15) [20,30) -> peak 2; back to
#     back [0,10) [10,20) -> peak 1; one run -> peak 1; none -> peak 0.
#  I. 400s: slow/groups min=-1, group=bogus, top=0, tz with ';', db of 129 characters; slow/events value with
#     null=1, bucket=10, failed=2; stmttrend without queryid or shape, both, queryid=x, shape=XYZ; jobs/timeline
#     scheduler alone, scheduler=cron, a job on the fleet.
#
# Not proven here: a real SQL Server capture or Agent history (see above); the pages in a browser (the slice's
# report has the shots); pg_cron or pgAgent themselves (not installed on the sandbox).
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of the PostgreSQL sandbox, without dbname}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
BIN=${PGVIGIL_BIN:-bin/pgvigil}
PORT=${SST_PORT:-5497}; API_PORT=${SST_API_PORT:-8497}
SUF=$RANDOM; TAG=pgvsst$SUF
REPO_DB=pgvigil_sst_$SUF; MON=pgvigil_sstmon_$SUF; MONPW=p$RANDOM$RANDOM
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; SRVLOG=$WORK/serve.log; SCRATCH=$WORK/scratch
MADE_DB=; SRVPID=; BGPID=
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  local rc=$?
  set +e
  [ -n "$BGPID" ] && kill "$BGPID" 2>/dev/null
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  pg_ctl -D "$WORK/data" stop -m fast -s >/dev/null 2>&1
  [ -n "$MADE_DB" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
for t in initdb pg_ctl psql curl python3 go node; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for p in $PORT $API_PORT; do ss -ltn | grep -qE "(127\.0\.0\.1|\[::1\]|\*|0\.0\.0\.0):$p\b" && fail "port $p is taken"; done

# ---- the binary: the given one where the tree is wired, else a scratch build with the lead's four lines
if grep -q '/api/slow/groups' internal/web/web.go; then
  WIRED="wired in the tree"
else
  mkdir -p "$SCRATCH"
  git ls-files -z | grep -zv '^web/' | xargs -0 cp --parents -t "$SCRATCH"
  for f in internal/web/q_slow.go internal/web/q_stmt_trend.go internal/web/q_jobs_timeline.go internal/repo/sql/0076_slow_events.sql; do cp "$f" "$SCRATCH/$f"; done
  python3 -I - "$SCRATCH" <<'PY' || fail "the wiring's anchor line is gone from web.go"
import sys
p = sys.argv[1] + "/internal/web/web.go"; s = open(p).read()
old = '\tapi.HandleFunc("GET /api/jobs/history", s.JobsHistory)\n'
if s.count(old) != 1: sys.exit("web.go: anchor found %d times" % s.count(old))
s = s.replace(old, old + '\tapi.HandleFunc("GET /api/slow/groups", s.SlowGroups)\n\tapi.HandleFunc("GET /api/slow/events", s.SlowEvents)\n'
              '\tapi.HandleFunc("GET /api/stmttrend", s.StmtTrend)\n\tapi.HandleFunc("GET /api/jobs/timeline", s.JobsTimeline)\n')
open(p, "w").write(s)
PY
  (cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$SCRATCH/pgvigil-wired" ./cmd/pgvigil) || fail "the scratch build with the wiring"
  BIN=$SCRATCH/pgvigil-wired; WIRED="wired in a scratch build (the join applies the same four lines)"
fi
echo "binary: $WIRED"

# ---- the monitored server and the repository
initdb -D "$WORK/data" -U postgres -A trust >/dev/null 2>&1 || fail "initdb"
cat >> "$WORK/data/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = ''
shared_preload_libraries = 'pg_stat_statements'
logging_collector = on
log_line_prefix = '%m [%p] %q%u@%d '
EOF
pg_ctl -D "$WORK/data" -l "$WORK/server.out" -w -s start >/dev/null 2>&1 || { tail -5 "$WORK/server.out" >&2; fail "the cluster did not start"; }
SU="host=localhost port=$PORT user=postgres dbname=postgres sslmode=disable"
su() { psql "$SU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
su "create extension pg_stat_statements"
su "create role $MON login password '$MONPW' in role pg_monitor"
su "grant execute on function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) to $MON"
export MON_DSN="host=localhost port=$PORT user=$MON password=$MONPW dbname=postgres sslmode=disable"

psql "$ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO_DB" >/dev/null; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-sst-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -once "$1" >/dev/null 2>&1 || fail "collect $1"; }

echo "--- A. 0076's objects"
got=$(q "select (select count(*) from pg_views where schemaname='pgvigil' and viewname='slow_events_all')
          || ',' || (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgvigil' and p.proname in ('slow_bucket','stmt_trend','slow_trend'))
          || ',' || has_table_privilege('pgvigil_reader', 'pgvigil.slow_events_all', 'select')
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.slow_bucket(numeric)', 'execute')
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.stmt_trend(int, bigint, text, timestamptz, timestamptz, int)', 'execute')
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.slow_trend(int, text, timestamptz, timestamptz, int, numeric)', 'execute')")
[ "$got" = "1,3,true,true,true,true" ] || fail "A objects and grants: $got"
got=$(q "select string_agg(pgvigil.slow_bucket(v)::text, ',' order by o) from (values (1, 4999::numeric), (2, 5000), (3, 25000), (4, 60000), (5, 400000), (6, 3600000), (7, NULL)) x(o, v)")
[ "$got" = "0,1,3,5,6,9,0" ] || fail "A slow_bucket: $got"
echo "A ok"

echo "--- B. real statements on the throwaway cluster"
T=$(date -u +%s); ts() { date -u -d "@$1" +%FT%TZ; }
collect instance
P=$(q "select instance_id from pgvigil.instances where name='proof-sst-$SUF'")
Z="select count(*) from generate_series(1, 1000) g /* $TAG-z */"
for _ in 1 2 3 4 5; do su "$Z" >/dev/null; done
su "select pg_sleep(0.6) /* $TAG-y */" >/dev/null   # y and z in the first read (not logged: the cluster logs nothing by default), so the second read has their deltas
collect statements
sleep 1
for _ in $(seq 1 20); do su "$Z" >/dev/null; done
for _ in 1 2 3; do psql "$SU application_name=pgv-report" -XAtq -v ON_ERROR_STOP=1 -c "set log_min_duration_statement = 500" -c "select pg_sleep(0.6) /* $TAG-y */" >/dev/null; done
psql "$SU application_name=pgv-orders" -XAtq -v ON_ERROR_STOP=1 -c "set log_min_duration_statement = 500" -c "select pg_sleep(2.5), 'x' /* $TAG-x */" >/dev/null & BGPID=$!
sleep 1
collect activity
wait "$BGPID"; BGPID=
sleep 0.5   # the logging collector writes the file
collect statements
collect serverlog
got=$(q "select count(*) filter (where statement like '%$TAG-x%' and duration_ms >= 2500) || ',' || count(*) filter (where statement like '%$TAG-y%' and duration_ms >= 600) || ',' || count(*)
           from pgvigil.log_events where instance_id=$P and kind='slow'")
[ "$got" = "1,3,4" ] || fail "B slow rows (x, y, all): $got"
[ "$(q "select count(*) from pgvigil.activity_sample where instance_id=$P and application_name='pgv-orders'")" -ge 1 ] || fail "B: x was not sampled"
QY=$(su "select queryid from pg_stat_statements where query like '%$TAG-y%'"); QZ=$(su "select queryid from pg_stat_statements where query like '%$TAG-z%'")
[ -n "$QY" ] && [ -n "$QZ" ] || fail "B: the queryids of y and z"
SY=$(q "select distinct shape_key from pgvigil.log_events where instance_id=$P and statement like '%$TAG-y%'")
SX=$(q "select distinct shape_key from pgvigil.log_events where instance_id=$P and statement like '%$TAG-x%'")
echo "B ok: x shape $SX, y shape $SY, queryids y $QY z $QZ"

echo "--- C. the imported SQL Server instance and the jobs"
S=$(q "select pgvigil.ensure_instance('proof-sst-mssql-$SUF', 'onprem', '16.0', 160000, false, '{}', 'sqlserver')")
K=0123456789abcdef
ev() { echo "{\"kind\":\"slow\",\"event_at\":\"$(ts $((T - $1)))\",\"event_key\":\"sst-$1\",\"event_name\":\"rpc_completed\",\"session_name\":\"pgvigil_slow\",\"duration_us\":$2,\"cpu_us\":$(( $2 / 2 )),\"logical_reads\":100,\"physical_reads\":5,\"writes\":1,\"row_count\":7,\"result\":\"$3\",\"statement\":\"exec dbo.usp_load @id = 1\",\"object_name\":\"usp_load\",\"login_name\":\"erp_login\",\"host_name\":\"app1\",\"program_name\":\"erp-app\",\"database_name\":\"$4\",\"session_id\":71,\"shape\":\"usp_load\",\"shape_key\":\"$K\"}"; }
q "select pgvigil.import_mssql_xe($S, now(), \$j\$[$(ev 1500 6000000 OK Sales),$(ev 1200 25000000 Abort Sales),$(ev 900 400000000 OK Finance)]\$j\$::jsonb)" >/dev/null
[ "$(q "select count(*) from pgvigil.mssql_slow_events where instance_id=$S")" = 3 ] || fail "C: the slow completions were not stored"
# pg_cron job 1 on P: r1..r5 (start, end or empty, status)
run() { local e=""; [ -n "$3" ] && e=",\"end_time\":\"$(ts $((T - $3 * 60)))\",\"duration_secs\":$(( ($2 - $3) * 60 ))"; echo ",{\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"run_id\":$1,\"status\":\"$4\",\"return_message\":\"m$1\",\"start_time\":\"$(ts $((T - $2 * 60)))\"$e}"; }
JOB='{"kind":"job","scheduler":"pg_cron","job_id":1,"job_name":"nightly","schedule":"*/5 * * * *","command":"SELECT 1","datname":"postgres","run_as":"postgres","active":true}'
q "select pgvigil.import_jobs($P, now(), \$j\$[$JOB$(run 1 40 35 succeeded)$(run 2 38 37 failed)$(run 3 10 '' running)$(run 4 70 65 succeeded)$(run 5 90 50 succeeded)]\$j\$::jsonb)" >/dev/null
J=0b000000-0000-0000-0000-0000000000$((10 + SUF % 89))
mr() { echo ",{\"kind\":\"run\",\"history_id\":$1,\"job_id\":\"$J\",\"job_name\":\"etl\",\"step_id\":$2,\"step_name\":\"$3\",\"run_status\":$4,\"duration_s\":$5,\"run_utc\":\"$(ts $((T - $6)))\",\"message\":\"m$1\"}"; }
MJ="{\"kind\":\"job\",\"job_id\":\"$J\",\"name\":\"etl\",\"enabled\":1}"
q "select pgvigil.import_mssql_jobs($S, now(), \$j\$[$MJ$(mr 11 1 one 1 60 3000)$(mr 12 2 load 0 35 2940)$(mr 13 0 '(Job outcome)' 0 95 3000)$(mr 21 1 one 1 60 10800)$(mr 22 2 load 1 30 10740)$(mr 23 0 '(Job outcome)' 1 90 10800),{\"kind\":\"read\",\"cursor\":false}]\$j\$::jsonb)" >/dev/null
[ "$(q "select count(*) from pgvigil.mssql_job_runs where instance_id=$S")" = 6 ] || fail "C: the SQL Agent history was not stored"
echo "C ok: S=$S, job $J"

# ---- the API
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$API_PORT" -no-login >"$SRVLOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$API_PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$SRVLOG")"
FROM=$(ts $((T - 3600))); TO=$(ts $(( $(date -u +%s) + 5 )))
export API="http://127.0.0.1:$API_PORT/api/" FROM TO P S K SX SY QY QZ J
python3 -I - <<'PY' || fail "the API checks (above)"
import json, os, sys, urllib.parse, urllib.request
E = os.environ; bad = []
def get(path, **p):
    p.setdefault('from', E['FROM']); p.setdefault('to', E['TO'])
    if path.startswith('slow/'): p.setdefault('min', 500)   # the cluster's logging floor (the API's default threshold is 1 s)
    url = E['API'] + path + '?' + urllib.parse.urlencode(p)
    try:
        with urllib.request.urlopen(url) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e: return e.code, e.read().decode()
def rows(t): return [dict(zip(t['columns'], r)) for r in t['rows']] if t else []
def check(name, got, want):
    ok = got == want
    print(('ok   ' if ok else 'FAIL ') + f'{name}: {got!r}' + ('' if ok else f' (want {want!r})'))
    if not ok: bad.append(name)
P, S = int(E['P']), int(E['S'])

print('--- D. Group By')
st, d = get('slow/groups', group='instance')
g = {r['value']: r for r in rows(d['groups'])}
p = next(r for r in g.values() if r['instance_id'] == P); s = next(r for r in g.values() if r['instance_id'] == S)
check('D P', (p['total'], p['b0'], p['failed']), (4, 4, 0))
check('D S', (s['total'], s['b1'], s['b3'], s['b6'], s['failed'], float(s['total_duration_s'])), (3, 1, 1, 1, 1, 431.0))
t = rows(d['totals'])[0]; check('D totals', (t['total'], t['failed']), (7, 1))
check('D dbs', sorted((r['database'], r['events']) for r in rows(d['dbs'])), [('Finance', 1), ('Sales', 2), ('postgres', 4)])
st, d = get('slow/groups', group='result'); check('D result', sorted((r['value'], r['total']) for r in rows(d['groups'])), [('Abort', 1), ('OK', 6)])
st, d = get('slow/groups', group='instance', db='Sales'); check('D db=Sales', [(r['instance_id'], r['total']) for r in rows(d['groups'])], [(S, 2)])
st, d = get('slow/groups', instance=P, group='text'); check('D P text', sorted((r['value'], r['total']) for r in rows(d['groups'])), sorted([(E['SY'], 3), (E['SX'], 1)]))
st, d = get('slow/groups', instance=P, group='app'); check('D P app', [(r['value'], r['total']) for r in rows(d['groups'])], [(None, 4)])

print('--- E. the events behind a count')
st, d = get('slow/events', instance=S, group='result', value='Abort'); e = rows(d['events'])
check('E S Abort', (rows(d['meta'])[0]['matched'], [(float(x['duration_ms']), x['application'], x['client'], x['user_name'], x['failed']) for x in e]),
      (1, [(25000.0, 'erp-app', 'app1', 'erp_login', True)]))
st, d = get('slow/events', instance=P, group='text', value=E['SX']); e = rows(d['events'])
check('E P x', (rows(d['meta'])[0]['matched'], [(x['application'], x['application_from']) for x in e]), (1, [('pgv-orders', 'sample')]))
st, d = get('slow/events', instance=P, group='text', value=E['SY']); e = rows(d['events'])
check('E P y', (rows(d['meta'])[0]['matched'], sorted({x['application'] for x in e}, key=str)), (3, [None]))
st, d = get('slow/events', bucket=6); check('E bucket 6', [float(x['duration_ms']) for x in rows(d['events'])], [400000.0])
st, d = get('slow/events', failed=1); check('E failed', rows(d['meta'])[0]['matched'], 1)
st, d = get('slow/events'); check('E Total row', rows(d['meta'])[0]['matched'], 7)
st, d = get('slow/events', instance=P, group='app', null=1); check('E null', rows(d['meta'])[0]['matched'], 4)

print('--- F. the trend')
st, d = get('stmttrend', instance=P, queryid=E['QY']); r = rows(d['trend'])
check('F y', (sum(x['calls'] for x in r), sum(x['log_events'] for x in r), max((x['log_max_ms'] or 0) for x in r) >= 600, rows(d['meta'])[0]['secs']), (3, 3, True, 60))
st, d = get('stmttrend', instance=P, queryid=E['QZ']); r = rows(d['trend'])
check('F z', (sum(x['calls'] for x in r), sum(x['log_events'] for x in r), {x['log_max_ms'] for x in r}), (20, 0, {None}))
st, d = get('stmttrend', instance=S, shape=E['K']); r = rows(d['trend'])
check('F K', (sum(x['events'] for x in r), sum(x['failed'] for x in r), max(float(x['max_ms']) for x in r)), (3, 1, 400000.0))

print('--- G. the jobs timeline')
st, d = get('jobs/timeline', instance=P); r = rows(d['runs'])
check('G P', (sorted(x['run_id'] for x in r), [x['end_time'] for x in r if x['run_id'] == '3'], rows(d['meta'])[0]['matched']), (['1', '2', '3', '5'], [None], 4))
check('G P outcomes', sorted(x['outcome'] for x in r), ['failed', 'running', 'succeeded', 'succeeded'])
st, d = get('jobs/timeline', instance=S); r = rows(d['runs'])
check('G S', [(x['outcome'], x['failed_step'], x['duration_s']) for x in r], [('failed', '2 load', 95.0)])
st, d = get('jobs/timeline', instance=S, scheduler='sqlagent', job=E['J'])
check('G S steps', [(x['step_id'], x['outcome']) for x in rows(d['steps'])], [(1, 'succeeded'), (2, 'failed')])
st, d = get('jobs/timeline'); check('G fleet', len(rows(d['runs'])), 5)

print('--- I. the parameter checks')
for path, p, want in [
    ('slow/groups', dict(min=-1), 'min must be'), ('slow/groups', dict(group='bogus'), 'group must be'), ('slow/groups', dict(top=0), 'top must be'),
    ('slow/groups', dict(tz='Europe/Berlin;x'), 'tz must be'), ('slow/groups', dict(db='d' * 129), 'db must be'),
    ('slow/events', dict(value='x', null=1), 'do not go together'), ('slow/events', dict(bucket=10), 'bucket must be'), ('slow/events', dict(failed=2), 'failed must be'),
    ('stmttrend', dict(instance=P), 'queryid or shape'), ('stmttrend', dict(instance=P, queryid=1, shape=E['K']), 'do not go together'),
    ('stmttrend', dict(instance=P, queryid='x'), 'queryid must be'), ('stmttrend', dict(instance=P, shape='XYZ'), 'shape must be'),
    ('jobs/timeline', dict(instance=P, scheduler='pg_cron'), 'go together'), ('jobs/timeline', dict(instance=P, scheduler='cron', job=1), 'scheduler must be'),
    ('jobs/timeline', dict(scheduler='pg_cron', job=1), 'instance goes with job')]:
    st, body = get(path, **p)
    check(f'I {path} {sorted(p)}', (st, want in str(body)), (400, True))
sys.exit(1 if bad else 0)
PY

echo "--- H. the page's running-at-once arithmetic (jobs_timeline.ts, under node)"
[ -x web/node_modules/.bin/esbuild ] || fail "H: web/node_modules is missing (npm ci in web/)"
web/node_modules/.bin/esbuild web/src/jobs_timeline.ts --bundle --format=esm --platform=neutral --log-level=error --outfile="$WORK/tl.mjs" || fail "H: the bundle"
got=$(node -e "import('$WORK/tl.mjs').then(m => { const p = r => m.atOnce(r.map(([s, e]) => ({ s, e }))).peak;
  console.log([p([[0, 10], [5, 15], [20, 30]]), p([[0, 10], [10, 20]]), p([[3, 4]]), p([])].join(',')); })")
[ "$got" = "2,1,1,0" ] || fail "H peaks: $got"
echo "H ok: $got"
echo "PASS: proof-stmt-slow-timeline ($WIRED)"
