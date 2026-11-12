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
#     Server row: commits_s, rollbacks_s, temp_bytes_s NULL (the statement selects NULL for them); cpu_samples over
#     0 with a cpu_hist of 10 buckets summing to it, cpu_avg <= cpu_max (task 119's mssql_cpu: part A3 holds the
#     values against a hand read); wait_source mssql_wait_sample;
#     signal_pct in 0..100. wait_source is 'wait_sample' on exactly demo-onprem-erp01 and demo-onprem-hr01 (the two
#     the demo gives pg_wait_sampling) and 'activity' on the other 10. Every row: total_ms_s >= lock_ms_s where both
#     are set; cpu_avg <= cpu_max; now_at set. tag=staging: 4 rows (aurora-reporting01, azure-portal02,
#     cloudsql-analytics02, azure-sql03); tag=untagged: 0 rows; part=nope: HTTP 400.
#  B. the thresholds: demo-onprem-erp01's cpu_max is over 90 (the demo's saturated host) and no other row's, PostgreSQL
#     or SQL Server (task 119 gave SQL Server its cpu_max), is over 75.
#  C. /api/performance over 6 hours (step 180 s) ending 15 minutes back (A3's reason): demo-onprem-erp01 and
#     demo-onprem-sql01 both have the parts meta grid cpu sessions waits db io (task 119 gave SQL Server its cpu, db
#     and io); the grid has 121 steps, every snapshot_at of every part is a
#     grid step, the meta's step_secs is 180; instance=0: HTTP 400.
#  [task 175, expected before the rerun: task 119 filled SQL Server's CPU, file IO and counter columns, so A no longer
#   expects them NULL and they are held against the tables they come from]
#  A3. over an explicit hour that ends 15 minutes back (the demo's live trickle stores the ring buffer's records up to
#     ten minutes behind its read, so a window ending now still moves): each of the 3 SQL Server rows of part mssql
#     against a hand read of the same tables, row by row in python: cpu_samples, cpu_max and the 10 buckets of
#     cpu_hist equal to the count, the highest and the tens of 100 - idle_pct (sql_pct where idle_pct is NULL) in
#     mssql_cpu_sample; cpu_avg and cpu_sql_avg equal to that mean and sql_pct's mean rounded half up to 0.1; tps
#     within 0.01 (or 0.1 %) of mssql_sched_sample's transactions/s weighted by interval_secs (interval_secs > 0);
#     read_ms and write_ms within the same of mssql_fileio_sample's stall over its operations, mb_s of its read and
#     write bytes over mssql_fileio_read's seconds in MB. The demo exercises the 100 - idle_pct branch only (every
#     demo record carries an idle figure) and has no NULL transactions_s in the window (its counters run from two days
#     back): the sql_pct fallback and the NULL-rate filter are copied into the hand read, not run by this proof.
#  C3. demo-onprem-sql01's cpu part from C: one row per 180 s step that mssql_cpu_sample has records in, the same
#     steps as a hand read of the table, cpu_max equal, cpu_avg, sql_avg and other_avg equal rounded half up to 0.1.
#  D. EXPLAIN (ANALYZE) of each fleet statement (1 h and 24 h): the execution time printed; every history table is
#     read through an index (no Seq Scan node on a *_2026* partition); the 1 h PostgreSQL statement under 500 ms here.
#  [review fold, expected before the rerun:]
#  A2. commits/s of every PostgreSQL row with dbstats over an explicit last hour is within 2 % of an independent
#     average: the sum of dbstats_rate()'s commit deltas over the sum of its distinct reads' seconds.
#  F. a scratch untagged instance fx-reset, 60 one-minute imports through pgvigil.import_dbstats over a window two
#     hours back: a restart at minute 30 (postmaster_start moves, xact_commit falls from 2740 to 0; 60 commits a minute
#     before, 120 after) and a pg_stat_io row whose stats_reset moves at minute 30 (12,800 reads a minute of 8 kB, read
#     time 0.5 ms each); plus a pgms_wait_sampling Lock row a minute with no time (wait_secs NULL). Over that window:
#     commits_s 1.50 and tps 1.50 (5,220 commits over the 3,480 s the two segments cover), read_ms 0.50, mb_s 1.67
#     (before the fold: 3.33, the two segments' bytes over one segment's seconds), wait_source NULL and lock_ms_s NULL
#     (before: 'wait_sample' and 0.00); tag=untagged then lists exactly fx-reset.
#  D (fold). The Seq Scan check names the tables (any partition year, and the two plain tables); each statement is
#     measured as the endpoint runs it (SET jit = off; the endpoint's own transaction) and once with the server's JIT
#     setting, both printed; the served /api/perfsummary time printed for 1 h and 24 h. With SCALE_N=185 (200
#     instances): the 1 h PostgreSQL statement without JIT about 150 ms, the endpoint under 0.5 s for 1 h.
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
T0=$SECONDS
for _ in $(seq 1 150); do grep -q "demo serving" "$WORK/demo.log" && break; kill -0 $SRV 2>/dev/null || fail "demo exited: $(tail -3 "$WORK/demo.log")"; sleep 2; done
grep -q "demo serving" "$WORK/demo.log" || fail "demo never served in $((SECONDS - T0)) s: $(tail -3 "$WORK/demo.log")"
echo "demo seeded (-days 2) and serving after $((SECONDS - T0)) s"
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
    for k in ('commits_s', 'rollbacks_s', 'temp_bytes_s'):
        if r[k] is not None: bad.append(('mssql not null', n, k))
    if not r['cpu_samples'] or r['cpu_hist'] is None or len(r['cpu_hist']) != 10 or sum(r['cpu_hist']) != r['cpu_samples']:
        bad.append(('mssql hist', n, r['cpu_hist'], r['cpu_samples']))
    elif float(r['cpu_avg']) > float(r['cpu_max']): bad.append(('mssql avg>max', n))
    if r['signal_pct'] is None or not 0 <= float(r['signal_pct']) <= 100: bad.append(('signal', n, r['signal_pct']))
for r in pg + ms:
    if r['now_at'] is None: bad.append(('now_at', r['instance']))
    if r['total_ms_s'] is not None and r['lock_ms_s'] is not None and float(r['total_ms_s']) < float(r['lock_ms_s']): bad.append(('total<lock', r['instance']))
# B
over = {r['instance'] for r in pg + ms if r['cpu_max'] is not None and float(r['cpu_max']) > 75}
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

# ---- A2: commits/s against an independent average from dbstats_rate()
H1=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ); H0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -fs "$U/perfsummary?part=pg&from=$H1&to=$H0" > "$WORK/a2.json"
psql "$REPO" -XAtq -F' ' -c "select i.name, (select round(sum(r.xact_commit)::numeric / nullif((select sum(x.iv) from (select distinct q.snapshot_at, q.interval_secs as iv
    from pgvigil.dbstats_rate(i.instance_id, '$H1', '$H0') q where not q.reset) x), 0), 2)
  from pgvigil.dbstats_rate(i.instance_id, '$H1', '$H0') r where not r.reset) from pgvigil.instances i where i.engine = 'postgres' and i.name like 'demo-%'" > "$WORK/a2.ref"
python3 - "$WORK/a2.json" "$WORK/a2.ref" <<'EOF' || fail "A2: commits/s differs from the dbstats_rate average"
import json, sys
d = json.load(open(sys.argv[1])); rows = {r[1]: dict(zip(d['pg']['columns'], r)) for r in d['pg']['rows']}
bad, n = [], 0
for line in open(sys.argv[2]):
    name, ref = line.split()
    if ref == '': continue
    got = rows[name]['commits_s']; n += 1
    if got is None or abs(float(got) - float(ref)) > 0.02 * float(ref): bad.append((name, got, ref))
print('A2:', n, 'instances within 2 % of the dbstats_rate average' if not bad else bad)
sys.exit(1 if bad or n == 0 else 0)
EOF

# ---- A3: the SQL Server columns against a hand read of their tables, over an hour that ends 15 minutes back
S1=$(date -u -d '-75 minutes' +%Y-%m-%dT%H:%M:%SZ); S0=$(date -u -d '-15 minutes' +%Y-%m-%dT%H:%M:%SZ)
curl -fs "$U/perfsummary?part=mssql&from=$S1&to=$S0" > "$WORK/a3.json" || fail "A3: perfsummary"
W="s.snapshot_at > '$S1' and s.snapshot_at <= '$S0' and i.engine = 'sqlserver'"
psql "$REPO" -XAtq -F'|' -c "select i.name, s.idle_pct, s.sql_pct from pgvigil.mssql_cpu_sample s join pgvigil.instances i using (instance_id) where $W" > "$WORK/a3.cpu"
psql "$REPO" -XAtq -F'|' -c "select i.name, s.transactions_s, s.interval_secs from pgvigil.mssql_sched_sample s join pgvigil.instances i using (instance_id) where $W and s.interval_secs > 0" > "$WORK/a3.sched"
psql "$REPO" -XAtq -F'|' -c "select i.name, s.reads, s.writes, s.read_stall_ms, s.write_stall_ms, s.read_bytes + s.write_bytes from pgvigil.mssql_fileio_sample s join pgvigil.instances i using (instance_id) where $W" > "$WORK/a3.io"
psql "$REPO" -XAtq -F'|' -c "select i.name, s.interval_secs from pgvigil.mssql_fileio_read s join pgvigil.instances i using (instance_id) where $W" > "$WORK/a3.secs"
python3 - "$WORK/a3.json" "$WORK/a3.cpu" "$WORK/a3.sched" "$WORK/a3.io" "$WORK/a3.secs" <<'EOF' || fail "A3: a SQL Server column differs from the hand read of its table"
import json, sys
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP
d = json.load(open(sys.argv[1])); got = {r[1]: dict(zip(d['mssql']['columns'], r)) for r in d['mssql']['rows']}
def lines(p): return [l.rstrip('\n').split('|') for l in open(p) if l.strip()]
num = lambda v: None if v == '' else Decimal(v)
half = lambda v, q: v.quantize(Decimal(q), rounding=ROUND_HALF_UP)
cpu, sql, sched, io, secs = defaultdict(list), defaultdict(list), defaultdict(list), defaultdict(list), defaultdict(Decimal)
for n, idle, s in lines(sys.argv[2]):
    cpu[n].append(Decimal(100) - num(idle) if idle != '' else num(s)); sql[n].append(num(s))
for n, t, iv in lines(sys.argv[3]): sched[n].append((num(t), num(iv)))
for n, *v in lines(sys.argv[4]): io[n].append([num(x) for x in v])
for n, iv in lines(sys.argv[5]): secs[n] += num(iv)
near = lambda a, b: a is not None and b is not None and abs(Decimal(str(a)) - b) <= max(Decimal('0.01'), abs(b) / 1000)
bad = []
for n in sorted(got):
    g, c = got[n], cpu[n]
    if not c: bad.append((n, 'no mssql_cpu_sample rows in the window')); continue
    hist = [0] * 10
    for v in c: hist[min(int(v // 10), 9)] += 1
    want = {'cpu_samples': len(c), 'cpu_max': max(c), 'cpu_hist': hist,
            'cpu_avg': half(sum(c) / len(c), '0.1'), 'cpu_sql_avg': half(sum(sql[n]) / len(sql[n]), '0.1')}
    for k, v in want.items():
        if (g[k] if k == 'cpu_hist' else (None if g[k] is None else Decimal(str(g[k])))) != v: bad.append((n, k, g[k], v))
    w = [(t, iv) for t, iv in sched[n] if t is not None]
    tps = sum(t * iv for t, iv in w) / sum(iv for _, iv in w) if w else None
    rd, wr, rs, ws, by = (sum(r[i] for r in io[n]) for i in range(5)) if io[n] else (0, 0, 0, 0, 0)
    ref = {'tps': tps, 'read_ms': rs / rd if rd else None, 'write_ms': ws / wr if wr else None,
           'mb_s': by / secs[n] / 1048576 if secs[n] else None}
    for k, v in ref.items():
        if (g[k] is not None if v is None else not near(g[k], v)): bad.append((n, k, g[k], None if v is None else round(v, 4)))
    if ref['tps'] is None or ref['mb_s'] is None: bad.append((n, 'the window holds no counter or file IO rows to compare'))
print('A3:', len(got), 'SQL Server rows equal to the hand read (cpu count, max, buckets, means; tps, read_ms, write_ms, mb_s)' if not bad else bad)
sys.exit(1 if bad or len(got) != 3 else 0)
EOF

# ---- F: a restart, a pg_stat_io reset and pgms rows without time on a scratch untagged instance
psql "$REPO" -XAtq -v ON_ERROR_STOP=1 <<'EOF' || fail "F: seeding"
insert into pgvigil.instances(name, platform, engine) values ('fx-reset', 'onprem', 'postgres');
do $$ declare m int; t timestamptz; b timestamptz := date_trunc('minute', now()) - interval '2 hours';
  fx int := (select instance_id from pgvigil.instances where name = 'fx-reset');
begin
  perform pgvigil.ensure_month_partition('wait_sample', b);
  for m in 0..59 loop
    t := b + make_interval(mins => m);
    perform pgvigil.import_dbstats(fx, t, jsonb_build_array(
      jsonb_build_object('kind', 'db', 'dbid', 1, 'datname', 'fx',
        'postmaster_start', case when m < 30 then '2026-01-01T00:00:00Z' else '2026-06-01T00:00:00Z' end,
        'xact_commit', case when m < 30 then 1000 + 60 * m else 120 * (m - 30) end, 'xact_rollback', 0, 'temp_bytes', 0,
        'deadlocks', 0, 'checksum_failures', 0),
      jsonb_build_object('kind', 'io', 'backend_type', 'client backend', 'object', 'relation', 'context', 'normal',
        'stats_reset', case when m < 30 then '2026-01-01T00:00:00Z' else '2026-06-01T00:00:00Z' end,
        'reads', case when m < 30 then 5000 + 12800 * m else 12800 * (m - 30) end,
        'read_time', 0.5 * case when m < 30 then 5000 + 12800 * m else 12800 * (m - 30) end,
        'writes', 0, 'write_time', 0, 'op_bytes', 8192)));
    insert into pgvigil.wait_sample (instance_id, snapshot_at, interval_secs, source, event_type, event, queryid, samples, wait_secs)
    values (fx, t, 60, 'pgms_wait_sampling', 'Lock', 'relation', 0, 50, null);
  end loop;
end $$;
EOF
FB=$(psql "$REPO" -XAtq -c "select to_char((date_trunc('minute', now()) - interval '2 hours 1 minute') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
FE=$(psql "$REPO" -XAtq -c "select to_char((date_trunc('minute', now()) - interval '1 hour') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
curl -fs "$U/perfsummary?tag=untagged&from=$FB&to=$FE" > "$WORK/f.json" || fail "F: perfsummary"
got=$(jq -c '.pg.columns as $c | [.pg.rows[] | [$c, .] | transpose | map({(.[0]): .[1]}) | add | {instance, commits_s, tps, read_ms, mb_s, wait_source, lock_ms_s}] | .[0], length' "$WORK/f.json" | tr '\n' ' ')
want='{"instance":"fx-reset","commits_s":1.50,"tps":1.50,"read_ms":0.50,"mb_s":1.67,"wait_source":null,"lock_ms_s":null} 1 '
[[ "$got" == "$want" ]] || fail "F: got $got want $want"
[[ $(jq '.mssql.rows | length' "$WORK/f.json") == 0 ]] || fail "F: an untagged SQL Server row"
echo "F: fx-reset commits_s 1.50, tps 1.50, read_ms 0.50, mb_s 1.67, no wait source; untagged lists fx-reset alone"

# ---- C
id() { psql "$REPO" -XAtq -c "select instance_id from pgvigil.instances where name = '$1'"; }
NOW=$(date -u +%s)   # one clock read: two date calls a second apart make a window of 21,599 s (step 179)
TO=$(date -u -d "@$((NOW - 900))" +%Y-%m-%dT%H:%M:%SZ); FROM=$(date -u -d "@$((NOW - 22500))" +%Y-%m-%dT%H:%M:%SZ)
for pair in "demo-onprem-erp01:cpu,db,grid,io,meta,sessions,waits" "demo-onprem-sql01:cpu,db,grid,io,meta,sessions,waits"; do
  n=${pair%%:*}; want=${pair#*:}
  curl -fs "$U/performance?instance=$(id $n)&from=$FROM&to=$TO" > "$WORK/p.json" || fail "performance $n"
  [[ $(jq -r 'keys | join(",")' "$WORK/p.json") == "$want" ]] || fail "C: $n parts $(jq -r 'keys | join(",")' "$WORK/p.json")"
  [[ $(jq '.grid.rows | length' "$WORK/p.json") == 121 ]] || fail "C: $n grid $(jq '.grid.rows | length' "$WORK/p.json")"
  [[ $(jq '.meta.rows[0][4]' "$WORK/p.json") == 180 ]] || fail "C: $n step"
  off=$(jq '(.grid.rows | map(.[0])) as $g | [to_entries[] | select(.key != "grid" and .key != "meta") | .value.rows[] | .[0] | select(. as $t | $g | index($t) | not)] | length' "$WORK/p.json")
  [[ $off == 0 ]] || fail "C: $n has $off points off the grid"
  [[ $n == demo-onprem-sql01 ]] && cp "$WORK/p.json" "$WORK/sql01.json"
done
[[ $(curl -s -o /dev/null -w '%{http_code}' "$U/performance?instance=0") == 400 ]] || fail "C: instance=0"
echo "C: parts per engine as expected, 121 steps of 180 s, every point on the grid, instance=0 400"
# ---- C3: sql01's cpu part against a hand read of mssql_cpu_sample per 180 s step
psql "$REPO" -XAtq -F'|' -c "select floor(extract(epoch from s.snapshot_at))::bigint, s.idle_pct, s.sql_pct, s.other_pct from pgvigil.mssql_cpu_sample s
  where s.instance_id = $(id demo-onprem-sql01) and s.snapshot_at > '$FROM' and s.snapshot_at <= '$TO'" > "$WORK/c3.cpu"
python3 - "$WORK/sql01.json" "$WORK/c3.cpu" <<'EOF' || fail "C3: sql01's cpu part differs from the hand read of mssql_cpu_sample"
import json, sys
from collections import defaultdict
from datetime import datetime
from decimal import Decimal, ROUND_HALF_UP
d = json.load(open(sys.argv[1])); step = int(d['meta']['rows'][0][4]); cols = d['cpu']['columns']
epoch = lambda t: int(datetime.fromisoformat(t.replace('Z', '+00:00')).timestamp())
got = {epoch(r[0]): dict(zip(cols, r)) for r in d['cpu']['rows']}
half = lambda v: v.quantize(Decimal('0.1'), rounding=ROUND_HALF_UP)
mean = lambda xs: half(sum(xs) / len(xs)) if xs else None
by = defaultdict(lambda: ([], [], []))
for line in open(sys.argv[2]):
    if not line.strip(): continue
    t, idle, s, other = line.rstrip('\n').split('|')
    tot, sq, ot = by[int(t) // step * step]
    tot.append(Decimal(100) - Decimal(idle) if idle != '' else Decimal(s)); sq.append(Decimal(s))
    if other != '': ot.append(Decimal(other))
dec = lambda v: None if v is None else Decimal(str(v))
bad = [] if set(got) == set(by) and by else [('steps', len(got), len(by), sorted(set(got) ^ set(by))[:5])]
for t in sorted(set(got) & set(by)):
    tot, sq, ot = by[t]; g = got[t]
    want = {'cpu_max': max(tot), 'cpu_avg': mean(tot), 'sql_avg': mean(sq), 'other_avg': mean(ot)}
    bad += [(t, k, g[k], v) for k, v in want.items() if dec(g[k]) != v]
print('C3:', len(by), 'steps of demo-onprem-sql01 equal to the hand read of mssql_cpu_sample' if not bad else bad[:10])
sys.exit(1 if bad else 0)
EOF

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
HIST='Seq Scan on (host_sample|activity_s\w*|wait_sample|dbstats|iostats|cloud_io_sample|mssql_\w+)'
measure() {  # $1 repository dsn, $2 label
  for q in sqlPerfSummaryPG:postgres sqlPerfSummaryMSSQL:sqlserver; do
    for w in "1 hour" "24 hours"; do
      { echo "SET jit = off;"; echo "EXPLAIN (ANALYZE, BUFFERS)"; sqlof "${q%%:*}" "$w" "${q#*:}"; } > "$WORK/e.sql"
      psql "$1" -XAtq -f "$WORK/e.sql" > "$WORK/e.out"
      ms=$(grep -oP 'Execution Time: \K[0-9.]+' "$WORK/e.out")
      # a node the executor pruned at run time prints '(never executed)': it reads nothing (a near-empty day partition
      # can be planned as a Seq Scan and is then never run); only a scan that ran is a full read of a history table
      # one process, no pipe: under pipefail a grep -q that matches early can SIGPIPE the writer and hide the match
      # (the pattern through the environment: awk -v would turn its \w into a plain w)
      HIST="$HIST" awk '$0 ~ ENVIRON["HIST"] && !/never executed/ { f = 1 } END { exit !f }' "$WORK/e.out" && fail "D: a Seq Scan on a history table ($q $w)"
      { echo "EXPLAIN (ANALYZE)"; sqlof "${q%%:*}" "$w" "${q#*:}"; } > "$WORK/j.sql"
      jit=$(psql "$1" -XAtq -f "$WORK/j.sql" | grep -oP 'Execution Time: \K[0-9.]+')
      echo "D $2: ${q%%:*} $w: $ms ms as served (jit off); $jit ms with the server's JIT setting"
      if [[ "$q" == sqlPerfSummaryPG:* && "$w" == "1 hour" && "$2" == "15" ]]; then
        python3 -c "import sys; sys.exit(0 if float('$ms') < 500 else 1)" || fail "D: over 500 ms"
      fi
    done
  done
  for w in 1 24; do
    t=$(curl -fs -o /dev/null -w '%{time_total}' "$U/perfsummary?from=$(date -u -d "-$w hours" +%Y-%m-%dT%H:%M:%SZ)&to=$(date -u +%Y-%m-%dT%H:%M:%SZ)") || fail "D: served read"
    echo "D $2: GET /api/perfsummary ${w} h: ${t} s"
  done
}
psql "$REPO" -XAtq -c "analyze"
measure "$REPO" 15
if [[ -n "${SCALE_N:-}" ]]; then
  "$BIN" demo -dsn "$REPO" -days 1 -instances "$SCALE_N" -prefix scale- > "$WORK/scale.log" 2>&1 || fail "scale seed: $(tail -3 "$WORK/scale.log")"
  psql "$REPO" -XAtq -c "analyze"
  measure "$REPO" "$((SCALE_N + 15))"
fi
echo "PROOF OK"
