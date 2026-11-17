#!/usr/bin/env bash
# proof-pmrows.sh - proof of the trend rows of parity set 2 (the sweep's M rows: L48 autovacuum over time, L47 the
# pooler's rates and traffic, L46 a table's scans / modifications / buffer hit and Most Disk I/O Reads) on a throwaway
# repository: the API's answers against this script's own reading of the stored rows.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a superuser (the proof makes a database with a random
#                      suffix and drops it at the end)
#   PGVIGIL_BIN        the build to prove; default bin/pgvigil
#   PGVIGIL_PROOF_OUT  a folder for the logs (default: removed with the work folder)
#
# The API (this proof pins it; the pages draw these answers - the drawing is graded by the wording and a11y walks):
#   GET /api/vacuum/trend?instance=<id>&from=&to=  {workers: [{at, n, max}], dead: [{table, points: [{at, v}]}],
#     pressure: [{at, n}], words: [..]} - workers: one point per minute sample the window holds (a vacuum_sample row of
#     any kind), n its autovacuum workers (distinct pids with is_auto), max autovacuum_max_workers as last read
#     (vacuum_state; the setting's history is not kept: the words say so); dead: the 5 tables with the most dead tuples
#     at the window's newest table_sizes read, each named schema.table (pgvigil.tables), a point per read; pressure: per
#     table_sizes read, the tables whose n_dead_tup is over autovacuum's trigger - vacuum_threshold + vacuum_scale_factor
#     x n_live_tup, capped by vacuum_max_threshold when it is not -1 - with the instance's settings as last read (the
#     words: per-table settings are not read).
#   GET /api/pooler/trend?instance=<id>&from=&to=  {series: [{at, tps, qps, avg_query_ms, avg_wait_ms, recv_bps,
#     sent_bps}]} - per pooler read of kind 'stats', over its databases: tps = sum(xact_rate), qps = sum(query_rate),
#     avg_query_ms = sum(avg_query_us x query_rate) / sum(query_rate) / 1000, avg_wait_ms the same weighted by xact_rate
#     (null when the weight is 0), recv_bps / sent_bps = sum(avg_recv) / sum(avg_sent) (null where not read).
#   GET /api/tables/io?instance=<id>&dbid=&relid=&from=&to=  {points: [{at, seq_scan, idx_scan, ins, upd, del,
#     hit_pct}], words: [..]} - per pgvigil.table_activity read (task 127's five-minute read; 0363 adds its six block
#     counters) after the first in the window, each counter's change since the read before it; a counter lower than
#     before (a stats reset) leaves that point's counts null and the words say 'reset'; hit_pct = 100 x (heap + idx
#     blks_hit change) / (that + heap + idx blks_read change), null when both are 0 or not read (a read before 0363); a
#     table pgvigil.tables lists with no table_activity read in the window: no point, and the words say it is outside
#     its database's busiest 100 (the lead 11-17 02:50's added check).
#   GET /api/tables/io_top?instance=<id>&from=&to=&top=<n>  {tables: [{table, dbid, relid, blks_read}]} - Most Disk I/O
#     Reads: each table's heap + idx + toast blks_read increases over the window (a reset's drop not counted), the
#     largest first, at most n.
#
# Expected (written 11-17 before the first run; CHANGED 11-17 02:5x before any run - the lead 02:50: the table history
# is table_activity's, extended by 0363, not a table_io; the RED run on rel-j16-last 65083820): the seed of the
# pooler's traffic and of table_activity's block counters FAIL ('column "avg_recv" ... does not exist', 'column
# "heap_blks_read" ... does not exist'); every row FAIL - the four routes answer 404 or the SPA's HTML, so no JSON
# (V1-V3, W1, W2, P1-P5, I1-I4). On the build, each row as named:
#   V1 workers   every point at a seeded minute, n = that minute's autovacuum workers (0 to 3; the manual VACUUM never
#                counted), max 3; W1: the words name autovacuum_max_workers as last read
#   V2 dead      the 5 tables with the most dead tuples at the newest read (by name), each a point per read equal to
#                its stored n_dead_tup
#   V3 pressure  each read's count of tables over the trigger, worked out here from table_sizes and vacuum_state; W2:
#                the words say per-table settings are not read
#   P1-P4        tps, qps, avg_query_ms (0.001), avg_wait_ms (0.001) per stats read, the pool rows never counted
#   P5 traffic   recv_bps and sent_bps per stats read
#   I1 io        t1's points: each change as stored, hit_pct within 0.05
#   I2 reset     t0's read after its reset: its counts null, the words 'reset'
#   I3 io_top    the tables in this script's order with its sums, top=3 three of them
#   I4 quiet     t6 (in pgvigil.tables, no table_activity read): no point, the words name its database's busiest 100
# 'proof-pmrows: <n> FAIL' last; exit 1 on any FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
SUF=$RANDOM; DB=pgvigil_pmrows_$SUF
WORK=$(mktemp -d); SRV=""
FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL: $*"; exit 1; }
cleanup() {
  [[ -n "${PGVIGIL_PROOF_OUT:-}" ]] && mkdir -p "$PGVIGIL_PROOF_OUT" && cp "$WORK"/*.log "$WORK"/*.json "$PGVIGIL_PROOF_OUT"/ 2>/dev/null
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in psql curl ss python3; do command -v $t >/dev/null || die "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 12000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  die "no free port"
}
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || die "create database $DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
CFG=$WORK/none.yaml
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"

# ---- the seed: one PostgreSQL instance, 36 reads ten minutes apart (k = 0 .. 35) ending a minute ago
P1=$(q "select pgvigil.ensure_instance('pmrows-p1-$SUF', 'onprem', '17.0', 170000, false, '{}')")
[[ $P1 =~ ^[0-9]+$ ]] || die "the instance: $P1"
T0=$(q "select date_trunc('minute', now()) - interval '1 minute'")
AT="('$T0'::timestamptz - (35 - k) * interval '10 minutes')"
for tb in vacuum_sample table_sizes pooler_sample; do
  q "select pgvigil.ensure_month_partition('$tb', d) from generate_series('$T0'::timestamptz - interval '1 day', '$T0'::timestamptz + interval '1 day', interval '1 day') d" > /dev/null || die "partitions of $tb"
done
q "insert into pgvigil.vacuum_state (instance_id, snapshot_at, max_workers, vacuum_threshold, vacuum_scale_factor, vacuum_max_threshold)
   values ($P1, now(), 3, 50, 0.2, 100000000)" > /dev/null || die "vacuum_state"
# autovacuum workers: k % 4 of them; every other read a manual VACUUM besides (never counted), so a read with no worker
# still holds a row
q "insert into pgvigil.vacuum_sample (instance_id, snapshot_at, kind, pid, is_auto)
   select $P1, $AT, 'vacuum', 1000 + w, true from generate_series(0, 35) k, generate_series(1, 3) w where w <= k % 4
   union all select $P1, $AT, 'vacuum', 9000 + k, false from generate_series(0, 35) k where k % 2 = 0 or k % 4 = 0" > /dev/null || die "vacuum_sample"
q "insert into pgvigil.tables (instance_id, dbid, relid, datname, schema_name, table_name, snapshot_at, first_seen)
   select $P1, 1, 100 + i, 'app', 'public', 't' || i, now(), now() from generate_series(0, 6) i" > /dev/null || die "tables"
q "insert into pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid, n_live_tup, n_dead_tup)
   select $P1, $AT, 1, 100 + i, 1000 * (i + 1), (k * 37 * (i + 1)) % (300 * (i + 2)) from generate_series(0, 35) k, generate_series(0, 5) i" > /dev/null || die "table_sizes"
q "insert into pgvigil.pooler_sample (instance_id, snapshot_at, kind, database, xact_rate, query_rate, avg_wait_us, avg_query_us)
   select $P1, $AT, 'stats', db, 10 * k + d, 25 * k + 3 * d, (k * 7 + d * 11) % 500, 1000 + (k * 13 + d) % 900
     from generate_series(0, 35) k, generate_series(1, 2) d, lateral (select 'db' || d) x(db)
   union all select $P1, $AT, 'pool', 'db1', null, null, null, null from generate_series(0, 35) k" > /dev/null || die "pooler_sample"
# the traffic and the table I/O history need task 4's migration: on the base each seed fails in its own words
q "update pgvigil.pooler_sample set avg_recv = 1000 + 17 * extract(minute from snapshot_at)::int, avg_sent = 4000 + 3 * extract(minute from snapshot_at)::int
   where instance_id = $P1 and kind = 'stats'" > "$WORK/seed-traffic.log" 2>&1 || bad "the traffic seed: $(head -1 "$WORK/seed-traffic.log")"
q "select pgvigil.ensure_month_partition('table_activity', d) from generate_series('$T0'::timestamptz - interval '1 day', '$T0'::timestamptz + interval '1 day', interval '1 day') d" > "$WORK/seed-io.log" 2>&1 &&
q "insert into pgvigil.table_activity (instance_id, snapshot_at, dbid, relid, datname, schema_name, table_name, seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del,
     heap_blks_read, heap_blks_hit, idx_blks_read, idx_blks_hit, toast_blks_read, toast_blks_hit)
   select $P1, $AT, 1, 100 + i, 'app', 'public', 't' || i,
     case when i = 0 and k >= 20 then k - 20 else 5 * k * (i + 1) end, 11 * k * (i + 1), 3 * k * i, 2 * k, k % 3 + k,
     case when i = 0 and k >= 20 then 2 * (k - 20) else 40 * k * (i + 1) + (k * k) % 7 end, 900 * k * (i + 1), 13 * k * i, 400 * k, 2 * k * (i % 2), 0
   from generate_series(0, 35) k, generate_series(0, 5) i" >> "$WORK/seed-io.log" 2>&1 || bad "the table I/O seed: $(grep -m1 -i 'error' "$WORK/seed-io.log")"

# ---- the hand read: the stored rows as they are, for python to work the expected answers out
dump() { q "select coalesce(json_agg(x), '[]') from ($1) x" > "$WORK/$2.json" 2>&1 || echo '[]' > "$WORK/$2.json"; }
dump "select snapshot_at, pid, is_auto from pgvigil.vacuum_sample where instance_id = $P1" vs
dump "select max_workers, vacuum_threshold, vacuum_scale_factor, vacuum_max_threshold from pgvigil.vacuum_state where instance_id = $P1" vst
dump "select s.snapshot_at, s.relid, s.n_live_tup, s.n_dead_tup, t.schema_name || '.' || t.table_name as name from pgvigil.table_sizes s
      join pgvigil.tables t using (instance_id, dbid, relid) where s.instance_id = $P1" ts
dump "select snapshot_at, kind, xact_rate, query_rate, avg_wait_us, avg_query_us, to_jsonb(p) -> 'avg_recv' as avg_recv, to_jsonb(p) -> 'avg_sent' as avg_sent
      from pgvigil.pooler_sample p where instance_id = $P1" ps
dump "select i.*, t.schema_name || '.' || t.table_name as name from pgvigil.table_activity i join pgvigil.tables t using (instance_id, dbid, relid) where i.instance_id = $P1" tio

# ---- the API
port=$(freeport); U="http://127.0.0.1:$port"
"$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$port" > "$WORK/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; kill -0 $SRV 2>/dev/null || die "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done
FROM=$(q "select to_char(('$T0'::timestamptz - interval '6 hours') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
TO=$(q "select to_char(('$T0'::timestamptz + interval '1 minute') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
W="instance=$P1&from=$FROM&to=$TO"
get() { local c; c=$(curl -s -o "$WORK/$2.json" -w '%{http_code}' "$U/api/$1"); echo "$c" > "$WORK/$2.code"; }
get "vacuum/trend?$W" a-vac
get "pooler/trend?$W" a-pool
get "tables/io?$W&dbid=1&relid=101" a-io1
get "tables/io?$W&dbid=1&relid=100" a-io0
get "tables/io_top?$W&top=3" a-top
get "tables/io?$W&dbid=1&relid=106" a-io6

python3 -I - "$WORK" <<'PY'
import json, sys, os
from datetime import datetime
W = sys.argv[1]
def load(n):
    try:
        with open(os.path.join(W, n + '.json')) as f: return json.load(f)
    except Exception as e: return None
def code(n):
    try: return open(os.path.join(W, n + '.code')).read().strip()
    except Exception: return '?'
def ts(s): return datetime.fromisoformat(str(s).replace('Z', '+00:00')).timestamp()
out = []
def say(ok, name, detail): out.append(('ok  ' if ok else 'FAIL') + ' ' + name + ': ' + detail)
def api(n):
    a = load(n)
    return a if isinstance(a, dict) else None
vs, vst, tsz, ps, tio = (load(x) or [] for x in ('vs', 'vst', 'ts', 'ps', 'tio'))
near = lambda a, b, t: a is None and b is None or (a is not None and b is not None and abs(float(a) - float(b)) <= t)

# V1 workers, W1
a = api('a-vac')
if a is None:
    for r in ('V1 workers', 'V2 dead', 'V3 pressure', 'W1 words', 'W2 words'): say(False, r, f"GET /api/vacuum/trend answered {code('a-vac')} with no JSON object")
else:
    mx = vst[0]['max_workers'] if vst else None
    want = {}
    for r in vs: want.setdefault(ts(r['snapshot_at']), set()); (r['is_auto'] and want[ts(r['snapshot_at'])].add(r['pid']))
    got = {ts(p['at']): p for p in a.get('workers') or []}
    diff = [f"{k}: {got.get(k)} want n {len(v)}" for k, v in sorted(want.items()) if k not in got or got[k].get('n') != len(v) or got[k].get('max') != mx]
    say(not diff and len(got) == len(want), 'V1 workers', f"{len(got)} points for {len(want)} reads, max {mx}; {'; '.join(diff[:3]) or 'every point as stored'}")
    words = ' '.join(a.get('words') or [])
    say('autovacuum_max_workers' in words, 'W1 words', repr(words[:300]))
    say('per-table' in words, 'W2 words', repr(words[:300]))
    newest = max(ts(r['snapshot_at']) for r in tsz) if tsz else None
    top = sorted([r for r in tsz if ts(r['snapshot_at']) == newest], key=lambda r: (-r['n_dead_tup'], r['name']))[:5]
    dead = {d.get('table'): d for d in a.get('dead') or []}
    dd = []
    for r in top:
        d = dead.get(r['name'])
        if not d: dd.append(f"{r['name']} missing"); continue
        pts = {ts(p['at']): p.get('v') for p in d.get('points') or []}
        wantp = {ts(x['snapshot_at']): x['n_dead_tup'] for x in tsz if x['relid'] == r['relid']}
        if pts != wantp: dd.append(f"{r['name']} points differ ({len(pts)} vs {len(wantp)})")
    say(not dd and len(dead) == len(top), 'V2 dead', f"tables {sorted(dead)} want {[r['name'] for r in top]}; {'; '.join(dd[:3]) or 'every point as stored'}")
    s = vst[0] if vst else {}
    def over(r):
        trig = s.get('vacuum_threshold', 0) + s.get('vacuum_scale_factor', 0) * r['n_live_tup']
        if s.get('vacuum_max_threshold') not in (None, -1): trig = min(trig, s['vacuum_max_threshold'])
        return r['n_dead_tup'] > trig
    wantpr = {}
    for r in tsz: wantpr[ts(r['snapshot_at'])] = wantpr.get(ts(r['snapshot_at']), 0) + (1 if over(r) else 0)
    gotpr = {ts(p['at']): p.get('n') for p in a.get('pressure') or []}
    say(gotpr == wantpr and any(wantpr.values()), 'V3 pressure', f"{len(gotpr)} points for {len(wantpr)} reads; first differences {[(k, gotpr.get(k), v) for k, v in sorted(wantpr.items()) if gotpr.get(k) != v][:3]}")

# P1-P5 the pooler
a = api('a-pool')
if a is None:
    for r in ('P1 tps', 'P2 qps', 'P3 avg_query_ms', 'P4 avg_wait_ms', 'P5 traffic'): say(False, r, f"GET /api/pooler/trend answered {code('a-pool')} with no JSON object")
else:
    by = {}
    for r in ps:
        if r['kind'] == 'stats': by.setdefault(ts(r['snapshot_at']), []).append(r)
    got = {ts(p['at']): p for p in a.get('series') or []}
    def wavg(rs, v, w):
        tw = sum(x[w] for x in rs)
        return None if tw == 0 else sum(x[v] * x[w] for x in rs) / tw / 1000
    def total(rs, k):
        vals = [x.get(k) for x in rs]
        return None if any(v is None for v in vals) else sum(vals)
    checks = [('P1 tps', 'tps', lambda rs: sum(x['xact_rate'] for x in rs), 0), ('P2 qps', 'qps', lambda rs: sum(x['query_rate'] for x in rs), 0),
              ('P3 avg_query_ms', 'avg_query_ms', lambda rs: wavg(rs, 'avg_query_us', 'query_rate'), 0.001), ('P4 avg_wait_ms', 'avg_wait_ms', lambda rs: wavg(rs, 'avg_wait_us', 'xact_rate'), 0.001)]
    for name, key, f, tol in checks:
        diff = [(k, got.get(k, {}).get(key), f(rs)) for k, rs in sorted(by.items()) if not near(got.get(k, {}).get(key), f(rs), tol)]
        say(not diff and len(got) == len(by), name, f"{len(got)} points for {len(by)} reads; {diff[:3] or 'every point as worked out'}")
    tr = [(k, got.get(k, {}).get('recv_bps'), total(rs, 'avg_recv'), got.get(k, {}).get('sent_bps'), total(rs, 'avg_sent')) for k, rs in sorted(by.items())]
    bad5 = [x for x in tr if x[2] is None or not near(x[1], x[2], 0) or not near(x[3], x[4], 0)]
    say(not bad5 and len(by) > 0, 'P5 traffic', f"{bad5[:3] or 'every read as stored'}")

# I1-I3 the table I/O history
def chg(rows):
    rows = sorted(rows, key=lambda r: ts(r['snapshot_at']))
    out = {}
    for a0, b0 in zip(rows, rows[1:]):
        ks = ['seq_scan', 'idx_scan', 'n_tup_ins', 'n_tup_upd', 'n_tup_del', 'heap_blks_read', 'heap_blks_hit', 'idx_blks_read', 'idx_blks_hit']
        if any(b0[k] < a0[k] for k in ks): out[ts(b0['snapshot_at'])] = None; continue
        d = {k: b0[k] - a0[k] for k in ks}
        hit, rd = d['heap_blks_hit'] + d['idx_blks_hit'], d['heap_blks_read'] + d['idx_blks_read']
        out[ts(b0['snapshot_at'])] = {'seq_scan': d['seq_scan'], 'idx_scan': d['idx_scan'], 'ins': d['n_tup_ins'], 'upd': d['n_tup_upd'], 'del': d['n_tup_del'], 'hit_pct': None if hit + rd == 0 else 100 * hit / (hit + rd)}
    return out
for name, n, rel in (('I1 io', 'a-io1', 101), ('I2 reset', 'a-io0', 100)):
    a = api(n)
    if a is None: say(False, name, f"GET /api/tables/io answered {code(n)} with no JSON object"); continue
    want = chg([r for r in tio if r['relid'] == rel])
    got = {ts(p['at']): p for p in a.get('points') or []}
    diff = []
    for k, w in sorted(want.items()):
        g = got.get(k)
        if g is None: diff.append(f"{k} missing"); continue
        if w is None:
            if any(g.get(x) is not None for x in ('seq_scan', 'idx_scan', 'ins', 'upd', 'del')): diff.append(f"{k} counts after a reset {g}")
            continue
        if any(g.get(x) != w[x] for x in ('seq_scan', 'idx_scan', 'ins', 'upd', 'del')) or not near(g.get('hit_pct'), w['hit_pct'], 0.05): diff.append(f"{k} {g} want {w}")
    words = ' '.join(a.get('words') or [])
    resets = sum(1 for w in want.values() if w is None)
    ok = not diff and len(got) == len(want) and len(want) > 0 and (resets == 0 or 'reset' in words) and (name != 'I2 reset' or resets == 1)
    say(ok, name, f"{len(got)} points for {len(want)} changes, {resets} reset(s), words {words[:120]!r}; {diff[:3] or 'every point as stored'}")
a = api('a-top')
if a is None: say(False, 'I3 io_top', f"GET /api/tables/io_top answered {code('a-top')} with no JSON object")
else:
    sums = {}
    for rel in sorted({r['relid'] for r in tio}):
        rows = sorted([r for r in tio if r['relid'] == rel], key=lambda r: ts(r['snapshot_at']))
        tot = 0
        for a0, b0 in zip(rows, rows[1:]):
            for k in ('heap_blks_read', 'idx_blks_read', 'toast_blks_read'):
                if b0[k] > a0[k]: tot += b0[k] - a0[k]
        sums[rows[0]['name']] = tot
    want = sorted(sums.items(), key=lambda x: (-x[1], x[0]))[:3]
    got = [(t.get('table'), t.get('blks_read')) for t in a.get('tables') or []]
    say(got == want and len(want) == 3, 'I3 io_top', f"got {got} want {want}")
a = api('a-io6')
if a is None: say(False, 'I4 quiet', f"GET /api/tables/io answered {code('a-io6')} with no JSON object")
else:
    words = ' '.join(a.get('words') or [])
    say(not a.get('points') and 'busiest 100' in words, 'I4 quiet', f"{len(a.get('points') or [])} points, words {words[:160]!r}")
print('\n'.join(out))
fails = sum(1 for l in out if l.startswith('FAIL'))
open(os.path.join(W, 'fails'), 'w').write(str(fails))
PY
FAILS=$((FAILS + $(cat "$WORK/fails" 2>/dev/null || echo 1)))
echo "proof-pmrows: $FAILS FAIL"
[[ $FAILS -eq 0 ]]
