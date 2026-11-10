#!/usr/bin/env bash
# Proof of the Performance summary (GET /api/perfsummary) and the instance Performance page (GET /api/performance),
# plan task 108, on the demo: a scratch repository seeded with -days 2 (15 instances: 12 PostgreSQL, 3 SQL Server) and
# served on a loopback port, both dropped on every exit path.
#   PGVIGIL_ADMIN_DSN  a superuser connection (creates and drops the scratch database)
#   PGVIGIL_BIN        the binary (default bin/pgvigil)
#   SCALE_N            optional: a second seed of SCALE_N instances (-days 1) for the timing of part D at that size
# Expected (written before the first run):
#  A. /api/perfsummary over the last hour: part pg 12 rows, all engine postgres; part mssql 3 rows, all sqlserver.
#     The 8 instances the demo gives a host collection (onprem x3, rds x2, aurora x3) carry cpu_avg, cpu_max and a
#     cpu_hist of 10 buckets summing to cpu_samples; the 4 without (azure x2, cloudsql x2) carry none. Every SQL
#     Server row: cpu_*, tps, commits_s, read_ms, write_ms, mb_s, temp_bytes_s NULL; wait_source mssql_wait_sample;
#     signal_pct in 0..100. wait_source is 'wait_sample' on exactly demo-onprem-erp01 and demo-onprem-hr01 (the two
#     the demo gives pg_wait_sampling) and 'activity' on the other 10. Every row: total_ms_s >= lock_ms_s where both
#     are set; cpu_avg <= cpu_max; now_at set. tag=staging: 4 rows (aurora-reporting01, azure-portal02,
#     cloudsql-analytics02, azure-sql03); tag=untagged: 0 rows; part=nope: HTTP 400.
#  B. the thresholds: demo-onprem-erp01's cpu_max is over 90 (the demo's saturated host) and no other row's is over 75.
#  C. /api/performance over 6 hours (step 180 s): demo-onprem-erp01 has the parts meta grid cpu sessions waits db io;
#     demo-onprem-sql01 has meta grid sessions waits only; the grid has 121 steps, every snapshot_at of every part is a
#     grid step, the meta's step_secs is 180; instance=0: HTTP 400.
#  D. EXPLAIN (ANALYZE) of each fleet statement (1 h and 24 h): the execution time printed; every history table is
#     read through an index (no Seq Scan node on a *_2026* partition); the 1 h PostgreSQL statement under 500 ms here.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
DB="pgvigil_it_perf_$RANDOM"; PORT=$((18000 + RANDOM % 1000)); CREATED=""; SRV=""; WORK=$(mktemp -d)
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null && wait "$SRV" 2>/dev/null || true
  [[ -n "$CREATED" ]] && psql "$PGVIGIL_ADMIN_DSN" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in psql curl jq python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
psql "$PGVIGIL_ADMIN_DSN" -XAtq -c "create database $DB"; CREATED=1
REPO="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$BIN" demo -dsn "$REPO" -days 2 -serve -listen 127.0.0.1:$PORT > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do grep -q "demo serving" "$WORK/demo.log" && break; kill -0 $SRV 2>/dev/null || fail "demo exited: $(tail -3 "$WORK/demo.log")"; sleep 2; done
grep -q "demo serving" "$WORK/demo.log" || fail "demo never served"
U="http://127.0.0.1:$PORT/api"
rows() { jq -r ".$2.columns as \$c | .$2.rows[] | [\$c, .] | transpose | map({(.[0]): .[1]}) | add | @json" "$1"; }

# ---- A
curl -fs "$U/perfsummary" > "$WORK/ps.json" || fail "perfsummary"
[[ $(jq '.pg.rows | length' "$WORK/ps.json") == 12 ]] || fail "A: pg rows $(jq '.pg.rows | length' "$WORK/ps.json")"
[[ $(jq '.mssql.rows | length' "$WORK/ps.json") == 3 ]] || fail "A: mssql rows"
python3 - "$WORK/ps.json" <<'EOF' || fail "A/B: the row checks"
import json, sys
d = json.load(open(sys.argv[1]))
def rows(p): return [dict(zip(d[p]['columns'], r)) for r in d[p]['rows']]
pg, ms = rows('pg'), rows('mssql')
host = {'onprem-erp01', 'onprem-erp02', 'onprem-hr01', 'rds-orders01', 'rds-billing01', 'aurora-crm01', 'aurora-dms01', 'aurora-reporting01'}
bad = []
for r in pg:
    n = r['instance'].removeprefix('demo-')
    if r['engine'] != 'postgres': bad.append(('engine', n))
    if (n in host) != (r['cpu_avg'] is not None): bad.append(('host', n, r['cpu_avg']))
    if r['cpu_avg'] is not None:
        if len(r['cpu_hist']) != 10 or sum(r['cpu_hist']) != r['cpu_samples']: bad.append(('hist', n, r['cpu_hist'], r['cpu_samples']))
        if float(r['cpu_avg']) > float(r['cpu_max']): bad.append(('avg>max', n))
    want = 'wait_sample' if n in ('onprem-erp01', 'onprem-hr01') else 'activity'
    if r['wait_source'] != want: bad.append(('wait_source', n, r['wait_source']))
for r in ms:
    n = r['instance']
    if r['engine'] != 'sqlserver' or r['wait_source'] != 'mssql_wait_sample': bad.append(('mssql src', n))
    for k in ('cpu_avg', 'cpu_max', 'cpu_hist', 'tps', 'commits_s', 'read_ms', 'write_ms', 'mb_s', 'temp_bytes_s'):
        if r[k] is not None: bad.append(('mssql not null', n, k))
    if r['signal_pct'] is None or not 0 <= float(r['signal_pct']) <= 100: bad.append(('signal', n, r['signal_pct']))
for r in pg + ms:
    if r['now_at'] is None: bad.append(('now_at', r['instance']))
    if r['total_ms_s'] is not None and r['lock_ms_s'] is not None and float(r['total_ms_s']) < float(r['lock_ms_s']): bad.append(('total<lock', r['instance']))
# B
over = {r['instance'] for r in pg if r['cpu_max'] is not None and float(r['cpu_max']) > 75}
if over != {'demo-onprem-erp01'} or float(next(r for r in pg if r['instance'] == 'demo-onprem-erp01')['cpu_max']) <= 90: bad.append(('thresholds', over))
print('A/B bad:', bad) if bad else print('A/B: 15 rows as expected; erp01 cpu_max over 90, no other over 75')
sys.exit(1 if bad else 0)
EOF
curl -fs "$U/perfsummary?tag=staging" > "$WORK/st.json"
got=$(jq -r '[.pg.rows[], .mssql.rows[]] | map(.[1]) | sort | join(",")' "$WORK/st.json")
[[ "$got" == "demo-aurora-reporting01,demo-azure-portal02,demo-azure-sql03,demo-cloudsql-analytics02" ]] || fail "A: tag=staging gave $got"
[[ $(curl -fs "$U/perfsummary?tag=untagged" | jq '[.pg.rows[], .mssql.rows[]] | length') == 0 ]] || fail "A: untagged"
[[ $(curl -s -o /dev/null -w '%{http_code}' "$U/perfsummary?part=nope") == 400 ]] || fail "A: part=nope"
echo "A: tag=staging 4 rows, untagged 0, part=nope 400"

# ---- C
id() { psql "$REPO" -XAtq -c "select instance_id from pgvigil.instances where name = '$1'"; }
TO=$(date -u +%Y-%m-%dT%H:%M:%SZ); FROM=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)
for pair in "demo-onprem-erp01:cpu,db,grid,io,meta,sessions,waits" "demo-onprem-sql01:grid,meta,sessions,waits"; do
  n=${pair%%:*}; want=${pair#*:}
  curl -fs "$U/performance?instance=$(id $n)&from=$FROM&to=$TO" > "$WORK/p.json" || fail "performance $n"
  [[ $(jq -r 'keys | join(",")' "$WORK/p.json") == "$want" ]] || fail "C: $n parts $(jq -r 'keys | join(",")' "$WORK/p.json")"
  [[ $(jq '.grid.rows | length' "$WORK/p.json") == 121 ]] || fail "C: $n grid $(jq '.grid.rows | length' "$WORK/p.json")"
  [[ $(jq '.meta.rows[0][4]' "$WORK/p.json") == 180 ]] || fail "C: $n step"
  off=$(jq '(.grid.rows | map(.[0])) as $g | [to_entries[] | select(.key != "grid" and .key != "meta") | .value.rows[] | .[0] | select(. as $t | $g | index($t) | not)] | length' "$WORK/p.json")
  [[ $off == 0 ]] || fail "C: $n has $off points off the grid"
done
[[ $(curl -s -o /dev/null -w '%{http_code}' "$U/performance?instance=0") == 400 ]] || fail "C: instance=0"
echo "C: parts per engine as expected, 121 steps of 180 s, every point on the grid, instance=0 400"

# ---- D
sqlof() {  # the statement from the Go source with literal arguments ($1 from, $2 to, $3 engine, $4 tag)
  python3 - "$1" "$2" "$3" <<'EOF'
import re, sys
src = open('internal/web/q_perfsummary.go').read()
c = dict(re.findall(r'const (\w+) = `([^`]*)`', src))
for m in re.finditer(r'const (\w+) = (\w+) \+ `([^`]*)`', src): c[m.group(1)] = c[m.group(2)] + m.group(3)
s = c[sys.argv[1]]
s = s.replace('$4::text', 'NULL::text').replace('$4', 'NULL::text').replace('$3', "'" + sys.argv[3] + "'")
print(s.replace('$1', "(now() - interval '" + sys.argv[2] + "')").replace('$2', 'now()'))
EOF
}
measure() {  # $1 repository dsn, $2 label
  for q in sqlPerfSummaryPG:postgres sqlPerfSummaryMSSQL:sqlserver; do
    for w in "1 hour" "24 hours"; do
      { echo "EXPLAIN (ANALYZE, BUFFERS)"; sqlof "${q%%:*}" "$w" "${q#*:}"; } > "$WORK/e.sql"
      psql "$1" -XAtq -f "$WORK/e.sql" > "$WORK/e.out"
      ms=$(grep -oP 'Execution Time: \K[0-9.]+' "$WORK/e.out")
      grep -qE 'Seq Scan on \w+_2026' "$WORK/e.out" && fail "D: a Seq Scan on a history partition ($q $w)"
      echo "D $2: ${q%%:*} $w: $ms ms"
      [[ "$q" == sqlPerfSummaryPG:* && "$w" == "1 hour" && "$2" == "15" ]] && python3 -c "import sys; sys.exit(0 if float('$ms') < 500 else 1)" || [[ ! ("$q" == sqlPerfSummaryPG:* && "$w" == "1 hour" && "$2" == "15") ]] || fail "D: over 500 ms"
    done
  done
}
psql "$REPO" -XAtq -c "analyze"
measure "$REPO" 15
if [[ -n "${SCALE_N:-}" ]]; then
  kill "$SRV"; wait "$SRV" 2>/dev/null || true; SRV=""
  "$BIN" demo -dsn "$REPO" -days 1 -instances "$SCALE_N" -prefix scale- > "$WORK/scale.log" 2>&1 || fail "scale seed: $(tail -3 "$WORK/scale.log")"
  psql "$REPO" -XAtq -c "analyze"
  measure "$REPO" "$((SCALE_N + 15))"
fi
echo "PROOF OK"
