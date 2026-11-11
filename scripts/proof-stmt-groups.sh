#!/usr/bin/env bash
# Proof of parity3 task 125 (migration 0078, internal/web/q_stmt_groups.go, q_stmt_trend.go, q_plans.go,
# internal/plans/suggest.go, web/src/stmt_filter.ts, stmt_trend.ts, plan.ts, pages.ts): the Statements page's filter
# panel with each value's share and its GROUP BY switch (PMM QAN 20-21), the share of the total beside a statement's
# time (pghero), the trend drill's buffers and its chosen-lag compare (pgwatch 52, Time Lag Comparison), and the
# suggested index checked by the planner through hypopg behind the actions door (pghero).
#
# Needs: docker with the image postgres:18 and network to apt.postgresql.org (the PGDG package postgresql-18-hypopg is
# installed into the throwaway container: this machine's PostgreSQL has no hypopg), psql, curl, python3, go; run at the
# repository root; PGVIGIL_REPO_DSN, a superuser keyword DSN of the PostgreSQL sandbox WITHOUT a password and without
# dbname (the password from ~/.pgpass).
#
# What it makes, and drops on every exit path: a throwaway container (postgres:18, published on 127.0.0.1 only, removed)
# and its own repository database on the sandbox. migrate also makes the cluster-wide roles pgvigil_collector,
# pgvigil_reader, pgvigil_alerter and pgvigil_auth where they are missing: those stay, as every pgvigil migrate leaves
# them. Nothing else is touched.
#
# The routes are the lead's lines in web.go, the switch hypo_index the lead's lines in config.go and serve.go: where
# the tree lacks them the proof builds a scratch copy with exactly those lines and says so (the report's WIRING BLOCK).
#
# Expected (written before the first run; T = the proof's start; the API window [T - 1 h, now + 1 min]):
#  A. 0078: the functions stmt_window_rows, stmt_client_label, stmt_groups, stmt_facets, stmt_trend_detail, stmt_lag
#     exist (6); pgvigil_reader may execute stmt_groups, stmt_facets, stmt_lag and stmt_trend_detail; import_actions_log
#     takes a 'hypo_index' row and stores its pid NULL (in a transaction rolled back).
#  B. The monitored server: databases appa (hypopg created) and appb (none), table big (200,000 rows, no index on n) in
#     each; logins ua and ub. Each workload statement runs once before the first statements read, then: Q1 (ua, appa,
#     n = 7) 20 times, Q3 (ua, appb, id < 100) 10 times, Q2 (ub, appb, n between 1 and 3) 15 times, and S (ua, appa,
#     pg_sleep(2)) twice at once, from inside the container over 127.0.0.1 and over the container's own address, with
#     one activity read while both sleep. Hand reads H1 / H2 of pg_stat_statements right after the two statements reads
#     give the differences per statement of appa and appb.
#     B1 /api/stmtgroups?db=appa&db=appb&group=db: two rows; each total_ms equals H2 - H1 of its database (within
#        0.05 ms) and each share_pct equals 100 x that / (appa + appb), rounded to 2 places (within 0.01).
#     B2 the same ticks, group=user: ua and ub, totals and shares equal the hand sums per user the same way.
#     B3 db=appa alone: the user facet lists ua only, share 100; the db facet still lists appa (ticked) and appb (not).
#     B4 group=query with the two ticks: Q1 20 calls, Q2 15, Q3 10, S 2 (each equal to the hand calls).
#     B5 db=appa, group=client: 127.0.0.1 and the container's address each hold S's total / 2 (within 0.05 ms); the
#        group '(not sampled)' holds appa's total - S's total; totals.sampled_pct is present and above 0.
#     B6 totals: total_ms equals the sum of the db facet's totals with no tick (within 0.05 ms).
#  C. The trend and the lag compare.
#     C1 /api/stmttrend for Q1 in appa: calls sum 20, shared_blks_hit + shared_blks_read sum = H2 - H1's (exact).
#     C2 imported deltas of a made-up queryid 4242 (interval 60 s; each with its statements_info row): T-20 min 10 calls
#        100 ms, T-10 min 20 calls 400 ms; T-80 min 5 calls 100 ms; T-1 d-15 min 7 calls 70 ms; T-3 d-20 min 3 calls
#        90 ms. Window [T-30 min, T]: lag=3600 gives three rows: the window 30 calls mean 16.667 ms, one day earlier 7
#        calls mean 10 ms, one hour earlier 5 calls mean 20 ms; each equal to a hand sum of statements_delta over that
#        window. at=T-3 d-30 min: the third row 3 calls mean 30 ms (a hand sum). lag=604800: the third row calls NULL,
#        snapshots 0, instance_snapshots 0 (the page's "no data").
#  D. The suggested index (a UI login; instance P with hypo_index: true, P2 the same server without it).
#     D1 POST /api/plans/explain on P, appa, "select count(*) from big where n = 42": a plan PA. GET plans/suggest?id=PA:
#        one suggestion, ddl "CREATE INDEX CONCURRENTLY ON big (n)", label 'not planner-checked', hypo true. The same
#        plan found under the statement: plans/suggest?instance=P&queryid=<Q1>&db=appa answers plan_id PA (by shape).
#     D2 POST /api/plans/hypo {PA, 0, reason}: 200, checked true, used true, cost_after < cost_before; actions_log:
#        one 'hypo_index' row, outcome done, pid NULL, datname appa, statement beginning with the ddl.
#     D3 the same in appb (no hypopg): plan PB, the same ddl; hypo 200, checked false, detail "not planner-checked:
#        hypopg is not installed in database appb"; audited refused.
#     D4 P2: plan PC; suggest says hypo false with "off by default"; hypo 409; audited refused.
#     D5 no reason on PA: 409 naming the reason, audited refused; without the X-Pgvigil header: 403, not audited.
#        actions_log hypo_index rows: done 1, refused 3.
#     D6 the suggestions' shapes: "n = 1 and id > 5" -> (n, id); "n = 1 or id = 2" -> no suggestion, skipped naming
#        the OR; "payload like 'x%'" -> no suggestion, skipped naming the LIKE. [the OR leg grades no suggestion only, as
#        written in the check before the first run: the planner may answer an OR with a BitmapOr and no seq scan]
#     D7 big in appa has no index after all of it (pg_indexes 0): pgvigil ran no CREATE.
#  E. 400s: stmtgroups group=bogus, limit=0, db 256 characters; stmtlag lag=10, lag and at both, at after from, no
#     queryid; plans/suggest with neither id nor instance; plans/hypo n=-1.
#
# Not proven here: the pages in a browser (the slice's report has the looks); PostgreSQL 13 (0078's migrate is applied
# on the pgv-pg13-proof container by hand, in the report; activity_sample.query_id is NULL on 13, so the client split
# finds no sample there).
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of the PostgreSQL sandbox, without dbname}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM; C=pgvsg$SUF
REPO_DB=pgvigil_sg_$SUF; PW=p$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SCRATCH=$WORK/scratch; JAR=$WORK/jar
UIUSER=proofuser; UIPW=ui$RANDOM$RANDOM$RANDOM
MADE_DB=; SRVPID=; BG1=; BG2=
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  local rc=$?
  set +e
  [ -n "$BG1" ] && kill "$BG1" 2>/dev/null
  [ -n "$BG2" ] && kill "$BG2" 2>/dev/null
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  docker rm -f "$C" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
for t in docker psql curl python3 go; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
PORT=$(freeport); API_PORT=$(freeport)

# ---- the binary: a scratch build with the lead's lines where the tree lacks them
mkdir -p "$SCRATCH"
git ls-files -z --cached --others --exclude-standard | grep -zv '^web/' | xargs -0 cp --parents -t "$SCRATCH"
if grep -q '/api/stmtgroups' internal/web/web.go; then
  WIRED="wired in the tree"
else
  python3 -I - "$SCRATCH" <<'PY' || fail "a wiring anchor is gone"
import sys
root = sys.argv[1]
def edit(path, old, new):
    p = root + "/" + path; s = open(p).read()
    if s.count(old) != 1: sys.exit("%s: anchor found %d times" % (path, s.count(old)))
    open(p, "w").write(s.replace(old, new))
edit("internal/web/web.go", '\tapi.HandleFunc("GET /api/stmttrend", s.StmtTrend)\n',
     '\tapi.HandleFunc("GET /api/stmttrend", s.StmtTrend)\n\tapi.HandleFunc("GET /api/stmtgroups", s.StmtGroups)\n'
     '\tapi.HandleFunc("GET /api/stmtlag", s.StmtLag)\n\tapi.HandleFunc("GET /api/plans/suggest", s.PlanSuggest)\n')
edit("internal/web/web.go", '\tapi.HandleFunc("POST /api/plans/analyze", s.actions.ExplainAnalyze)\n',
     '\tapi.HandleFunc("POST /api/plans/analyze", s.actions.ExplainAnalyze)\n\tapi.HandleFunc("POST /api/plans/hypo", s.actions.HypoIndex)\n')
edit("internal/config/config.go", '\tExplainAnalyze bool `yaml:"explain_analyze"`\n',
     '\tExplainAnalyze bool `yaml:"explain_analyze"`\n\t// HypoIndex turns on the suggested index\'s planner check (hypopg) for this instance; false (the default) = off.\n\tHypoIndex bool `yaml:"hypo_index"`\n')
edit("cmd/pgvigil/serve.go", 'pc := web.PlansConfig{Gates: map[string]actions.ExplainGate{}, QueryText: map[string]string{}}\n',
     'pc := web.PlansConfig{Gates: map[string]actions.ExplainGate{}, QueryText: map[string]string{}, Hypo: map[string]bool{}}\n')
edit("cmd/pgvigil/serve.go", '\t\tpc.QueryText[in.Name] = in.QueryText\n', '\t\tpc.QueryText[in.Name] = in.QueryText\n\t\tpc.Hypo[in.Name] = in.HypoIndex\n')
PY
  WIRED="wired in a scratch build (the join applies the same lines)"
fi
(cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$SCRATCH/pgvigil-wired" ./cmd/pgvigil) || fail "the scratch build"
BIN=$SCRATCH/pgvigil-wired
echo "binary: $WIRED"

# ---- the monitored server: a throwaway postgres:18 container with hypopg
docker run -d --name "$C" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$PORT:5432" postgres:18 \
  -c shared_preload_libraries=pg_stat_statements -c compute_query_id=on >/dev/null || fail "docker run"
docker exec "$C" bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq postgresql-18-hypopg >/dev/null 2>&1' || fail "the hypopg package"
for _ in $(seq 1 60); do docker exec "$C" pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null && break; sleep 1; done
SU="host=127.0.0.1 port=$PORT user=postgres password=$PW sslmode=disable"
for _ in $(seq 1 30); do psql "$SU dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
su() { psql "$SU dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
su "create extension pg_stat_statements"
su "create role mon login password '$PW' in role pg_monitor, pg_read_all_data"
su "create role ua login password '$PW'"; su "create role ub login password '$PW'"
for d in appa appb; do
  su "create database $d"
  su "create table big (id int primary key, n int, payload text); insert into big select g, g % 1000, md5(g::text) from generate_series(1, 200000) g; analyze big; grant select on big to ua, ub" $d
done
su "create extension hypopg" appa
CIP=$(docker exec "$C" hostname -i | awk '{print $1}')
export MON_DSN="host=127.0.0.1 port=$PORT user=mon password=$PW dbname=postgres sslmode=disable"

# ---- the repository and the two configurations (P only for the collector; P and P2 for serve)
psql "$ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO_DB" >/dev/null; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$WORK/collect.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-sg-$SUF
    dsn: env:MON_DSN
EOF
cat > "$WORK/serve.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-sg-$SUF
    dsn: env:MON_DSN
    hypo_index: true
  - name: proof-sg2-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$WORK/serve.yaml" >/dev/null 2>&1 || fail "migrate"
collect() { "$BIN" collect -config "$WORK/${2:-collect}.yaml" -once "$1" >/dev/null 2>&1 || fail "collect $1"; }

echo "--- A. 0078's objects"
got=$(q "select (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='pgvigil'
                  and p.proname in ('stmt_window_rows','stmt_client_label','stmt_groups','stmt_facets','stmt_trend_detail','stmt_lag'))
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.stmt_groups(int, timestamptz, timestamptz, text, text[], text[], text[], int)', 'execute')
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.stmt_facets(int, timestamptz, timestamptz, text[], text[], text[])', 'execute')
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.stmt_lag(int, bigint, text, timestamptz, timestamptz, float8[])', 'execute')
          || ',' || has_function_privilege('pgvigil_reader', 'pgvigil.stmt_trend_detail(int, bigint, text, timestamptz, timestamptz, int)', 'execute')")
[ "$got" = "6,true,true,true,true" ] || fail "A objects and grants: $got"
got=$(psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
begin;
select pgvigil.import_actions_log(null, now(), '[{"instance_name":"x","ui_user":"u","action":"hypo_index","pid":0,"reason":"proof","outcome":"done","datname":"d","statement":"CREATE INDEX CONCURRENTLY ON t (c)"}]');
select action || ',' || coalesce(pid::text, 'NULL') from pgvigil.actions_log where instance_name = 'x';
rollback;
SQL
)
got=$(tail -n 1 <<< "$got")   # [first run, explained: the void import call prints an empty line before the row]
[ "$got" = "hypo_index,NULL" ] || fail "A: the hypo_index audit row: $got"
ok "A. 0078's functions, grants and the hypo_index audit row"

echo "--- B. the workload, the hand reads and the groups"
T=$(date -u +%s); iso() { date -u -d "@$1" +%FT%TZ; }
collect instance serve
P=$(q "select instance_id from pgvigil.instances where name='proof-sg-$SUF'"); P2=$(q "select instance_id from pgvigil.instances where name='proof-sg2-$SUF'")
[ -n "$P" ] && [ -n "$P2" ] || fail "B: the two instances"
U() { psql "host=127.0.0.1 port=$PORT user=$1 password=$PW dbname=$2 sslmode=disable" -XAtq -v ON_ERROR_STOP=1 -c "$3" >/dev/null; }
Q1="select count(*) from big where n = 7"; Q3="select count(*) from big where id < 100"; Q2="select sum(n) from big where n between 1 and 3"
U ua appa "$Q1"; U ua appb "$Q3"; U ub appb "$Q2"; U ua appa "select pg_sleep(0)"   # [third run, explained: pg_sleep(0.01) is numeric and pg_sleep(2) integer: two entries; the prime has the same type]
collect statements
hand() {
  su "select d.datname, r.rolname, s.queryid, s.calls, s.total_exec_time, s.shared_blks_hit + s.shared_blks_read
        from pg_stat_statements s join pg_database d on d.oid = s.dbid join pg_roles r on r.oid = s.userid
       where d.datname in ('appa','appb') and s.toplevel" > "$1"
}
hand "$WORK/h1"
for _ in $(seq 1 20); do U ua appa "$Q1"; done
for _ in $(seq 1 10); do U ua appb "$Q3"; done
for _ in $(seq 1 15); do U ub appb "$Q2"; done
docker exec -e PGPASSWORD="$PW" "$C" psql -h 127.0.0.1 -U ua -d appa -XAtqc "select pg_sleep(2)" >/dev/null & BG1=$!
docker exec -e PGPASSWORD="$PW" "$C" psql -h "$CIP" -U ua -d appa -XAtqc "select pg_sleep(2)" >/dev/null & BG2=$!
sleep 1
collect activity
wait "$BG1"; BG1=; wait "$BG2"; BG2=
collect statements
hand "$WORK/h2"
QID1=$(su "select queryid from pg_stat_statements where query = 'select count(*) from big where n = \$1'")
QIDS=$(su "select queryid from pg_stat_statements s join pg_database d on d.oid = s.dbid where query = 'select pg_sleep(\$1)' and d.datname = 'appa'")
[ -n "$QID1" ] && [ -n "$QIDS" ] || fail "B: the queryids of Q1 and S"
[ "$(q "select count(*) from pgvigil.activity_sample where instance_id=$P and query_id='$QIDS'")" = 2 ] \
  || fail "B: S ($QIDS) was not sampled twice: $(q "select string_agg(coalesce(query_id::text, 'NULL') || ' ' || coalesce(client, '') || ' ' || state, '; ') from pgvigil.activity_sample where instance_id=$P")"
ok "B. workload run; container address $CIP; Q1 $QID1, S $QIDS"

# ---- serve with the login
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$WORK/serve.yaml" $UIUSER >/dev/null 2>&1 || fail "user add"
"$BIN" serve -config "$WORK/serve.yaml" -listen "127.0.0.1:$API_PORT" > "$WORK/serve.log" 2>&1 & SRVPID=$!
API="http://127.0.0.1:$API_PORT"
for _ in $(seq 1 60); do curl -sf -o /dev/null "$API/" && break; kill -0 $SRVPID 2>/dev/null || fail "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$API/api/login" >/dev/null
grep -q pgvigil_session "$JAR" || fail "no session cookie"
FROM=$(iso $((T - 3600))); TO=$(iso $(( $(date -u +%s) + 60 )))
W="instance=$P&from=$FROM&to=$TO"
get() { curl -s -b "$JAR" "$API/api/$1"; }
code() { curl -s -o "$WORK/body" -w '%{http_code}' -b "$JAR" "$@"; }
post() { curl -s -o "$WORK/body" -w '%{http_code}' -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$API/api/$1"; }

get "stmtgroups?$W&db=appa&db=appb&group=db" > "$WORK/b1.json"
get "stmtgroups?$W&db=appa&db=appb&group=user" > "$WORK/b2.json"
get "stmtgroups?$W&db=appa" > "$WORK/b3.json"
get "stmtgroups?$W&db=appa&db=appb&group=query" > "$WORK/b4.json"
get "stmtgroups?$W&db=appa&group=client" > "$WORK/b5.json"
get "stmtgroups?$W" > "$WORK/b6.json"
python3 -I - "$WORK" "$QID1" "$QIDS" "$CIP" <<'PY' || fail "B: the groups against the hand reads"
import json, sys
work, qid1, qids, cip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def read(p):
    out = {}
    for line in open(p):
        db, user, qid, calls, t, blks = line.strip().split('|')
        out[(db, user, qid)] = (int(calls), float(t), int(blks))
    return out
h1, h2 = read(work + '/h1'), read(work + '/h2')
diff = {k: (v[0] - h1[k][0], v[1] - h1[k][1]) for k, v in h2.items() if k in h1 and v[0] > h1[k][0]}
def rows(name, part):
    d = json.load(open('%s/%s.json' % (work, name)))
    if 'error' in d: sys.exit('%s: %s' % (name, d['error']))
    t = d[part]; return [dict(zip(t['columns'], r)) for r in t['rows']]
def near(a, b, tol, what):
    if abs(float(a) - float(b)) > tol: sys.exit('%s: %s, expected %s' % (what, a, b))
def by(i):
    s = {}
    for k, v in diff.items(): s[k[i]] = s.get(k[i], 0) + v[1]
    return s
for name, idx, label in (('b1', 0, 'B1 db'), ('b2', 1, 'B2 user')):
    hand = by(idx); whole = sum(hand.values()); got = {r['grp']: r for r in rows(name, 'groups')}
    if set(got) != set(hand): sys.exit('%s groups %s, expected %s' % (label, sorted(got), sorted(hand)))
    for k, v in hand.items():
        near(got[k]['total_ms'], v, 0.05, '%s %s total' % (label, k))
        near(got[k]['share_pct'], round(100 * v / whole, 2), 0.011, '%s %s share' % (label, k))
f = rows('b3', 'facets')
users = [(r['value'], float(r['share_pct'])) for r in f if r['dim'] == 'user']
if users != [('ua', 100.0)]: sys.exit('B3 user facet %s' % users)
dbs = {r['value']: r['ticked'] for r in f if r['dim'] == 'db'}
if dbs.get('appa') is not True or dbs.get('appb') is not False: sys.exit('B3 db facet %s' % dbs)
calls = {}
for k, v in diff.items(): calls[k[2]] = calls.get(k[2], 0) + v[0]
got = {str(r['queryid']): round(float(r['calls'])) for r in rows('b4', 'groups')}
if got != calls: sys.exit('B4 calls %s, expected %s' % (got, calls))
if sorted(calls.values()) != [2, 10, 15, 20]: sys.exit('B4 hand calls %s' % sorted(calls.values()))
s_total = sum(v[1] for k, v in diff.items() if k[2] == qids)
appa_total = sum(v[1] for k, v in diff.items() if k[0] == 'appa')
got = {r['grp']: float(r['total_ms']) for r in rows('b5', 'groups')}
if set(got) != {'127.0.0.1', cip, '(not sampled)'}: sys.exit('B5 clients %s' % sorted(got))
near(got['127.0.0.1'], s_total / 2, 0.05, 'B5 127.0.0.1'); near(got[cip], s_total / 2, 0.05, 'B5 ' + cip)
near(got['(not sampled)'], appa_total - s_total, 0.05, 'B5 not sampled')
tot = rows('b5', 'totals')[0]
if tot['sampled_pct'] is None or float(tot['sampled_pct']) <= 0: sys.exit('B5 sampled_pct %s' % tot['sampled_pct'])
tot6 = rows('b6', 'totals')[0]; dbsum = sum(float(r['total_ms']) for r in rows('b6', 'facets') if r['dim'] == 'db')
near(tot6['total_ms'], dbsum, 0.05, 'B6 totals')
print('B1-B6: appa+appb %.3f ms by db and user; calls %s; S %.3f ms split over 127.0.0.1 and %s' % (sum(by(0).values()), sorted(calls.values()), s_total, cip))
PY
ok "B. the groups, shares, facets, calls and the client split equal the hand reads"

echo "--- C. the trend and the lag compare"
get "stmttrend?$W&queryid=$QID1&db=appa" > "$WORK/c1.json"
python3 -I - "$WORK" "$QID1" <<'PY' || fail "C1"
import json, sys
work, qid = sys.argv[1], sys.argv[2]
d = json.load(open(work + '/c1.json')); t = d['trend']; rs = [dict(zip(t['columns'], r)) for r in t['rows']]
h = {}
for name in ('h1', 'h2'):
    for line in open('%s/%s' % (work, name)):
        db, user, q, calls, tt, blks = line.strip().split('|')
        if q == qid and db == 'appa': h[name] = int(blks)
calls = sum(int(r['calls']) for r in rs); blks = sum(int(r['shared_blks_hit']) + int(r['shared_blks_read']) for r in rs)
if calls != 20 or blks != h['h2'] - h['h1']: sys.exit('C1 calls %d blocks %d, expected 20 and %d' % (calls, blks, h['h2'] - h['h1']))
print('C1: calls 20, blocks %d' % blks)
PY
imp() {  # $1 seconds before T, $2 calls, $3 total ms
  local at; at=$(iso $((T - $1)))
  q "select pgvigil.ensure_month_partition('statements_delta', '$at');
     insert into pgvigil.statements_delta (instance_id, snapshot_at, interval_secs, dbid, datname, userid, usename, queryid, toplevel, calls, total_exec_ms, rows, shared_blks_hit, shared_blks_read)
     values ($P, '$at', 60, 1, 'lagdb', 1, 'lagu', 4242, true, $2, $3, $2, 10, 1);
     insert into pgvigil.statements_info (instance_id, snapshot_at) values ($P, '$at') on conflict do nothing" >/dev/null
}
imp 1200 10 100; imp 600 20 400; imp 4800 5 100; imp $((86400 + 900)) 7 70; imp $((3 * 86400 + 1200)) 3 90
LW="instance=$P&from=$(iso $((T - 1800)))&to=$(iso $T)&queryid=4242"
handlag() { q "select coalesce(sum(calls), 0) || '|' || coalesce(round((sum(total_exec_ms) / nullif(sum(calls), 0))::numeric, 3)::text, '')
                 from pgvigil.statements_delta where instance_id = $P and queryid = 4242
                  and snapshot_at > '$(iso $((T - 1800 - $1)))' and snapshot_at <= '$(iso $((T - $1)))'"; }
H0=$(handlag 0); H1D=$(handlag 86400); H1H=$(handlag 3600); H3D=$(handlag $((3 * 86400)))
[ "$H0|$H1D|$H1H|$H3D" = "30|16.667|7|10.000|5|20.000|3|30.000" ] || fail "C2: the hand reads $H0 $H1D $H1H $H3D"
lagrows() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); t=d["lag"]; c=t["columns"]
print(";".join("%s|%s|%s|%s" % (r[c.index("calls")] if r[c.index("calls")] is None else round(r[c.index("calls")]), "" if r[c.index("mean_ms")] is None else "%.3f" % r[c.index("mean_ms")], r[c.index("snapshots")], r[c.index("instance_snapshots")]) for r in t["rows"]))'; }
got=$(get "stmtlag?$LW&lag=3600" | lagrows)
[ "$got" = "30|16.667|2|2;7|10.000|1|1;5|20.000|1|1" ] || fail "C2 lag=3600: $got"
got=$(get "stmtlag?$LW&at=$(iso $((T - 3 * 86400 - 1800)))" | lagrows)
[ "${got##*;}" = "3|30.000|1|1" ] || fail "C2 at: $got"
got=$(get "stmtlag?$LW&lag=604800" | lagrows)
[ "${got##*;}" = "None|||0|0" ] || [ "${got##*;}" = "None||0|0" ] || fail "C2 lag=604800: $got"
ok "C. the trend's calls and buffers equal the hand reads; the lag compare equals the hand sums (window, 1 d, 1 h, a date, no data)"

echo "--- D. the suggested index"
explain() {  # $1 instance, $2 db, $3 statement -> plan_id
  local c; c=$(post plans/explain "$(python3 -I -c 'import json,sys; print(json.dumps({"instance_id": int(sys.argv[1]), "datname": sys.argv[2], "statement": sys.argv[3]}))' "$1" "$2" "$3")")
  [ "$c" = 200 ] || fail "EXPLAIN $3 in $2: $c $(cat "$WORK/body")"
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$WORK/body"
}
jq_() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$WORK/body"; }
PA=$(explain $P appa "select count(*) from big where n = 42")
[ "$(code "$API/api/plans/suggest?id=$PA")" = 200 ] || fail "D1 suggest"
got=$(jq_ '"%d|%s|%s|%s" % (len(d["suggestions"]), d["suggestions"][0]["ddl"], d["label"], d["hypo"])')
[ "$got" = "1|CREATE INDEX CONCURRENTLY ON big (n)|not planner-checked|True" ] || fail "D1: $got"
code "$API/api/plans/suggest?instance=$P&queryid=$QID1&db=appa" >/dev/null
[ "$(jq_ 'd["plan_id"]')" = "$PA" ] || fail "D1 under the statement: $(cat "$WORK/body")"
ok "D1 the suggestion of plan $PA, found under the statement too"
c=$(post plans/hypo "{\"plan_id\":$PA,\"n\":0,\"reason\":\"proof check of the index\"}")
got=$(jq_ '"%s|%s|%s" % (d["checked"], d["used"], d["cost_after"] < d["cost_before"])')
[ "$c|$got" = "200|True|True|True" ] || fail "D2: $c $(cat "$WORK/body")"
got=$(q "select outcome || '|' || coalesce(pid::text, 'NULL') || '|' || datname || '|' || (statement like 'CREATE INDEX CONCURRENTLY ON big (n)%')
           from pgvigil.actions_log where action = 'hypo_index' and instance_id = $P")
[ "$got" = "done|NULL|appa|true" ] || fail "D2 audit: $got"
ok "D2 planner-checked: $(jq_ 'd["detail"]')"
PB=$(explain $P appb "select count(*) from big where n = 42")
c=$(post plans/hypo "{\"plan_id\":$PB,\"n\":0,\"reason\":\"proof check of the index\"}")
got=$(jq_ '"%s|%s" % (d["checked"], d["detail"])')
[ "$c|$got" = "200|False|not planner-checked: hypopg is not installed in database appb" ] || fail "D3: $c $got"
ok "D3 $got"
PC=$(explain $P2 appa "select count(*) from big where n = 42")
code "$API/api/plans/suggest?id=$PC" >/dev/null
got=$(jq_ '"%s|%s" % (d["hypo"], "off by default" in d["hypo_reason"])')
[ "$got" = "False|True" ] || fail "D4 suggest: $got"
c=$(post plans/hypo "{\"plan_id\":$PC,\"n\":0,\"reason\":\"proof check of the index\"}")
[ "$c" = 409 ] && grep -q "off by default" "$WORK/body" || fail "D4 hypo: $c $(cat "$WORK/body")"
c=$(post plans/hypo "{\"plan_id\":$PA,\"n\":0}")
[ "$c" = 409 ] && grep -q "reason" "$WORK/body" || fail "D5 no reason: $c $(cat "$WORK/body")"
c=$(curl -s -o "$WORK/body" -w '%{http_code}' -b "$JAR" -H 'Content-Type: application/json' -d "{\"plan_id\":$PA,\"n\":0,\"reason\":\"proof check\"}" "$API/api/plans/hypo")
[ "$c" = 403 ] || fail "D5 no header: $c"
got=$(q "select string_agg(outcome || '=' || n, ' ' order by outcome) from (select outcome, count(*) n from pgvigil.actions_log where action = 'hypo_index' group by 1) x")
[ "$got" = "done=1 refused=3" ] || fail "D5 audit: $got"
ok "D4-D5 off by default, no reason and no header refused; audited: $got"
PM=$(explain $P appa "select * from big where n = 1 and id > 5")
code "$API/api/plans/suggest?id=$PM" >/dev/null
[ "$(jq_ 'd["suggestions"][0]["ddl"]')" = "CREATE INDEX CONCURRENTLY ON big (n, id)" ] || fail "D6 two columns: $(cat "$WORK/body")"
PO=$(explain $P appa "select * from big where n = 1 or id = 2")
code "$API/api/plans/suggest?id=$PO" >/dev/null
got=$(jq_ '"%d|%s" % (len(d["suggestions"]), any("OR" in s["reason"] for s in d["skipped"]))')
# the planner may answer the OR with a BitmapOr over the primary key and a seq scan elsewhere: what counts is no suggestion
[ "${got%%|*}" = 0 ] || fail "D6 OR: $(cat "$WORK/body")"
PL=$(explain $P appa "select count(*) from big where payload like 'x%'")
code "$API/api/plans/suggest?id=$PL" >/dev/null
got=$(jq_ '"%d|%s" % (len(d["suggestions"]), any("LIKE" in s["reason"] for s in d["skipped"]))')
[ "$got" = "0|True" ] || fail "D6 LIKE: $got $(cat "$WORK/body")"
ok "D6 two columns (n, id); the OR and the LIKE suggest nothing"
[ "$(su "select count(*) from pg_indexes where tablename = 'big' and indexdef like '%(n%'" appa)" = 0 ] || fail "D7: an index on big (n) exists"
ok "D7 no index was created"

echo "--- E. refusals"
for u in "stmtgroups?$W&group=bogus" "stmtgroups?$W&limit=0" "stmtgroups?$W&db=$(python3 -I -c 'print("x"*256)')" \
         "stmtlag?$LW&lag=10" "stmtlag?$LW&lag=3600&at=$(iso $((T - 7200)))" "stmtlag?$LW&at=$(iso $T)" "stmtlag?instance=$P&lag=3600" \
         "plans/suggest"; do
  c=$(code "$API/api/$u"); [ "$c" = 400 ] || fail "E: $u gave $c $(cat "$WORK/body")"
done
c=$(post plans/hypo "{\"plan_id\":$PA,\"n\":-1,\"reason\":\"proof check\"}"); [ "$c" = 400 ] || fail "E: hypo n=-1 gave $c"
ok "E. the 400s"
echo "PASS"
