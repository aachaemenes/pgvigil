#!/usr/bin/env bash
# proof-trend.sh - proof of the Trend report (task B20-1: GET /api/trend over raw samples of both engines; the reader
# pgvigil.trend_series in 0273_long_range_reports.sql; the page web/src/trend.ts) on a throwaway repository.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a superuser (the proof makes its databases with a random
#                      suffix and drops them at the end)
#   PGVIGIL_BIN        the build to prove; default bin/pgvigil
#   FLEET              1 (default) runs part F, the fleet-scale timing (100 instances x 40 files x 3 days, about 2.5 GB);
#                      0 skips it with a line
#
# The API (B20-1, the design's items; this proof pins it): GET /api/trend?metric=<m>&bucket=hour|day&stat=<s>&from=&to=
#   [&hour=<0-23>&tz=<zone>&top=<1-20>&engine=both|postgres|sqlserver&instance=<instance_id>&by=database]
#   metric: os_cpu, sql_cpu, latency, active, free_memory, connections; stat p50 / p95 / p98 / p99 / max (free_memory:
#   p50 / p5 / p2 / p1 / min, lowest first). The answer: {metric, bucket, stat, from, to (what it read), words: [..], series: [{instance_id,
#   name, engine, rank, reach, points: [{at, v, n}]}], none: [{instance_id, name, engine, why}]}; by=database: a series
#   per database (its 'database' field) of one instance (id). The reader under it: pgvigil.trend_series(p_metric text,
#   p_ids int[] (NULL = every instance of the engine), p_from timestamptz, p_to timestamptz, p_bucket text, p_stat text,
#   p_hour int, p_tz text, p_by text DEFAULT NULL) RETURNS TABLE (instance_id int, database_name text, at timestamptz,
#   v double precision, n int) - a row per bucket and a row with 'at' NULL per series (its statistic over every sample of
#   the range: the rank); the fleet file-IO window is the handler's (it moves p_from), never the function's.
#
# Expected (written before its first run; the RED run on rel-b20 = rel-roles f421753c, no Trend yet): every row FAIL
# for one reason - GET /api/trend answers 404 (or the SPA's HTML), so no JSON; part F's timing rows FAIL the same.
# On the build, each row as named:
#   V1-V6 (one per metric, hour buckets, p95 over 2 days, both engines): every point of every series equals the
#     script's own percentile_cont(0.95) over the seed for that instance and hour (0.01), n the seed's sample count:
#     V1 os_cpu (SQL Server 100 - idle_pct; PostgreSQL host_sample.cpu_pct), V2 sql_cpu (sql_pct), V3 latency (SQL Server
#     sum(stall) / sum(IO) over the files of a sample with 1 IO a second or more; PostgreSQL through iostats_rate's
#     deltas across a stats_reset, never the raw counters - the seed makes the two differ), V4 active (requests;
#     activity_summary.active), V5 free_memory as a percent (available_kb / physical_kb; (mem_free + mem_cache) /
#     mem_total) at p5, V6 connections (sessions - background; activity_summary.total).
#   W (the words): P1's and P2's sql_cpu in 'none' with 'PostgreSQL has no engine share of the host CPU'; P2's os_cpu,
#     free_memory with 'no host read'; P2's latency with its reason (no pg_stat_io read); S3 has no other_pct (Linux)
#     and still draws os_cpu from idle_pct; P3 (no sample at all) in 'none' with a reason; the latency words say
#     pg_stat_io's time is the call's and SQL Server's the stall, ranked within an engine.
#   K (top N, rank): top=2 os_cpu max: two series, the two highest ranks, rank = the statistic over every sample of the
#     range; free_memory: the two lowest; latency top=2: ranks within each engine (two of each).
#   H (hour of day): hour=3 tz=America/Los_Angeles: every point at 03:00 in that zone, the values as V1's in that hour.
#   D (buckets): bucket=day over 40 days: one point a day, n per point; bucket=hour over 40 days answers bucket 'day'
#     with 'hourly up to 31 days, daily beyond'.
#   R (reach): a 365-day range: words 'samples kept back to <the seed's oldest day>' and 'a year needs the hours (B21)'.
#   B (by database): instance=S1 by=database latency over 7 days: one series per database (db_a with its values, db_b idle =
#     no point); instance=P1 by=database: 'pg_stat_io has no database split'; the fleet (no instance) by=database: no series,
#     'file I/O by database across the fleet waits for hourly history; one instance's page shows it'.
#   C (the fleet latency cap): no instance, latency, a 7-day range: every point inside the newest window the words name
#     ('file I/O trends across the fleet read the newest <1 day|3 days> until hourly history lands').
#   F (FLEET=1; a database of its own, the collector's order): 100 SQL Server instances x 40 files x 3 days;
#     pgvigil.trend_series('latency', NULL, ...) with serve's session settings (read only, statement_timeout 15000, jit
#     off) over the newest 1 day and over 3 days, twice each, each EXPLAIN ANALYZE's time printed, then one GET
#     /api/trend of the fleet latency end to end (its curl time);
#     [inferred: box jobs A2's raw read 4.0-4.6 s at 1 day] 1 day under 10 s on both reads; 3 days [inferred: about
#     6 s] - the window the build takes (the lead 18:1x: 3 days if both reads under 10 s, else 1 day) printed as
#     'F: the window: <1 day|3 days>'; then C's words name that window.
#   The last line: 'proof-trend: <n> FAIL' and rc 1 when n > 0.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
FLEET=${FLEET:-1}
SUF=$RANDOM; DB=pgvigil_trendproof_$SUF; DB2=pgvigil_trendfleet_$SUF
WORK=$(mktemp -d); SRV=""; SRV2=""
FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL: $*"; exit 1; }
cleanup() {
  [[ -n "${PGVIGIL_PROOF_OUT:-}" ]] && mkdir -p "$PGVIGIL_PROOF_OUT" && cp "$WORK"/*.log "$PGVIGIL_PROOF_OUT"/ 2>/dev/null
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  wait 2>/dev/null || true
  for d in $DB $DB2; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
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
startserve() {   # startserve <cfg> <log>: a -no-login serve; prints its pid and sets URL
  local port; port=$(freeport); URL="http://127.0.0.1:$port"
  "$BIN" serve -config "$1" -no-login -listen "127.0.0.1:$port" > "$2" 2>&1 &
  local pid=$!
  for _ in $(seq 1 60); do curl -sf -o /dev/null "$URL/" && break; kill -0 $pid 2>/dev/null || die "serve died: $(tail -3 "$2")"; sleep 0.5; done
  SPID=$pid
}
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || die "create database $DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
CFG=$WORK/none.yaml
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"

# ---- the seed: three SQL Server instances (S1 and S3 every 5 minutes, S2 every minute: two sample rates; S3 on Linux,
# no other_pct), PostgreSQL P1 (host_sample, iostats with a stats_reset 10 days back, track_io_timing on), P2 (sessions
# only, track_io_timing off), P3 (no sample). 40 days back from the minute the seed starts.
S1=$(q "select pgvigil.ensure_instance('trend-s1-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
S2=$(q "select pgvigil.ensure_instance('trend-s2-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
S3=$(q "select pgvigil.ensure_instance('trend-s3-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
P1=$(q "select pgvigil.ensure_instance('trend-p1-$SUF', 'onprem', '17.0', 170000, false, '{}')")
P2=$(q "select pgvigil.ensure_instance('trend-p2-$SUF', 'onprem', '17.0', 170000, false, '{}')")
P3=$(q "select pgvigil.ensure_instance('trend-p3-$SUF', 'onprem', '17.0', 170000, false, '{}')")
for v in S1 S2 S3 P1 P2 P3; do [[ ${!v} =~ ^[0-9]+$ ]] || die "the instance $v: ${!v}"; done
T0=$(q "select date_trunc('minute', now())")
for tb in mssql_cpu_sample mssql_memory_sample mssql_session_summary mssql_fileio_sample mssql_fileio_read host_sample iostats; do
  q "select pgvigil.ensure_month_partition('$tb', d) from generate_series('$T0'::timestamptz - interval '41 days', '$T0'::timestamptz + interval '1 day', interval '1 day') d" > /dev/null || die "partitions of $tb"
done
q "insert into pgvigil.instance_state (instance_id, snapshot_at, track_io_timing) values ($P1, now(), 'on'), ($P2, now(), 'off')
   on conflict (instance_id) do update set track_io_timing = excluded.track_io_timing" > /dev/null || die "instance_state"
# every SQL Server table from one series of (instance, k, step) so the values are functions of the time
SER="(values ($S1, 1, 300), ($S2, 2, 60), ($S3, 3, 300)) s(iid, k, step)
     cross join lateral generate_series('$T0'::timestamptz - interval '40 days', '$T0'::timestamptz, make_interval(secs => s.step)) t"
HR="extract(hour from t at time zone 'UTC')::int"; MI="extract(minute from t)::int"
out=$(q "insert into pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
         select iid, t, (extract(epoch from t) / 60)::bigint, (k * 7 + $MI + $HR) % (55 + k), case when k = 3 then null else 5 end,
                100 - (k * 7 + $MI + $HR) % (55 + k) - case when k = 3 then 0 else 5 end - 3 from $SER;
       insert into pgvigil.mssql_memory_sample (instance_id, snapshot_at, physical_kb, available_kb)
         select iid, t, 16777216, 16777216 * (30 + ($MI + k) % 20) / 100 from $SER;
       insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source, sessions, requests)
         select iid, t, 'dmv', 50, ($HR + k) % 12 from $SER;
       insert into pgvigil.mssql_session_summary (instance_id, snapshot_at, sessions, background)
         select iid, t, 50 + ($HR + k) % 10, 20 from $SER;
       insert into pgvigil.mssql_fileio_read (instance_id, snapshot_at, interval_secs, files)
         select iid, t, step, 1 from $SER;
       -- db_a busy (2 IO a second, except the quiet hour 05 UTC: 0.2 a second = below the floor, no point), db_b idle
       insert into pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc,
                                                reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
         select iid, t, 5, 1, 'db_a', 'db_a_data', 'ROWS', r, r * 8192, r * (1 + ($HR + k) % 5), r / 2, r * 4096, r * ($MI % 4), step
           from (select iid, k, step, t, case when $HR = 5 then step / 5 else step * 2 end as r from $SER) x
         union all
         select iid, t, 6, 2, 'db_b', 'db_b_log', 'LOG', 0, 0, 0, 0, 0, 0, step from $SER;
       -- P1: host_sample every 5 minutes, activity every 5 minutes; P2 activity only
       insert into pgvigil.host_sample (instance_id, snapshot_at, source, cpu_pct, mem_total, mem_free, mem_cache)
         select $P1, t, 'system_stats', ($HR * 3 + $MI) % 70, 8589934592, 8589934592 * (10 + $MI % 15) / 100, 8589934592 * 20 / 100
           from generate_series('$T0'::timestamptz - interval '40 days', '$T0'::timestamptz, interval '5 minutes') t;
       insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle)
         select i, t, 30 + ($HR + i) % 7, ($HR + i) % 5, 10
           from (values ($P1), ($P2)) v(i) cross join generate_series('$T0'::timestamptz - interval '40 days', '$T0'::timestamptz, interval '5 minutes') t;
       -- P1's iostats: cumulative counters, 900 reads a sample, read_time growing by (0.5 + hour % 3) ms a read; the
       -- counters restart at the stats_reset 10 days back (raw read_time / reads then differs from the deltas)
       insert into pgvigil.iostats (instance_id, snapshot_at, backend_type, object, context, stats_reset, reads, read_time, writes, write_time, op_bytes)
         select $P1, t, 'client backend', 'relation', 'normal', case when t < '$T0'::timestamptz - interval '10 days' then '$T0'::timestamptz - interval '60 days' else '$T0'::timestamptz - interval '10 days' end,
                900 * n, sum(900 * (0.5 + $HR % 3)) over (partition by t < '$T0'::timestamptz - interval '10 days' order by t), 0, 0, 8192
           from (select t, row_number() over (partition by t < '$T0'::timestamptz - interval '10 days' order by t) as n
                   from generate_series('$T0'::timestamptz - interval '40 days', '$T0'::timestamptz, interval '5 minutes') t) x;
       analyze;" 2>&1) || die "the seed: $out"
echo "seed: $(q "select count(*) from pgvigil.mssql_cpu_sample") SQL Server CPU rows, $(q "select count(*) from pgvigil.iostats") iostats rows, from $(q "select min(snapshot_at) from pgvigil.mssql_cpu_sample")"

# the value of each sample, per metric, both engines (the script's own reader, written from the design's cells)
declare -A VAL
VAL[os_cpu]="select instance_id, snapshot_at as at, (100 - idle_pct)::float8 as v from pgvigil.mssql_cpu_sample
  union all select instance_id, snapshot_at, cpu_pct::float8 from pgvigil.host_sample"
VAL[sql_cpu]="select instance_id, snapshot_at as at, sql_pct::float8 as v from pgvigil.mssql_cpu_sample"
VAL[latency]="select instance_id, snapshot_at as at, sum(read_stall_ms + write_stall_ms)::float8 / sum(reads + writes) as v
    from pgvigil.mssql_fileio_sample group by 1, 2 having sum(reads + writes) / max(interval_secs) >= 1
  union all select instance_id, snapshot_at, sum(read_time + write_time) / sum(reads + writes)
    from pgvigil.iostats_rate($P1, '$T0'::timestamptz - interval '41 days', '$T0'::timestamptz + interval '1 minute')
   group by 1, 2 having sum(reads + writes) / max(interval_secs) >= 1"
VAL[active]="select instance_id, snapshot_at as at, requests::float8 as v from pgvigil.mssql_requests_summary
  union all select instance_id, snapshot_at, active::float8 from pgvigil.activity_summary"
VAL[free_memory]="select instance_id, snapshot_at as at, 100.0 * available_kb / physical_kb as v from pgvigil.mssql_memory_sample
  union all select instance_id, snapshot_at, 100.0 * (mem_free + mem_cache) / mem_total from pgvigil.host_sample"
VAL[connections]="select instance_id, snapshot_at as at, (sessions - background)::float8 as v from pgvigil.mssql_session_summary
  union all select instance_id, snapshot_at, total::float8 from pgvigil.activity_summary"
# the wrong reader for V3's trap: raw cumulative iostats (must differ from the deltas, or the trap proves nothing)
RAWLAT="select instance_id, snapshot_at as at, read_time / reads as v from pgvigil.iostats"

# expected <metric> <bucket> <fraction> <from> <to> [tz] [hour]: 'instance|bucket epoch|value|n' rows
expected() {
  local tz=${6:-UTC} hr=${7:-} frac=$3 f
  f="percentile_cont($frac) within group (order by v)"
  [[ $frac == max ]] && f="max(v)"; [[ $frac == min ]] && f="min(v)"
  q "select instance_id || '|' || extract(epoch from (date_trunc('$2', at at time zone '$tz') at time zone '$tz'))::bigint || '|' || round(($f)::numeric, 4) || '|' || count(*)
       from (${VAL[$1]}) x where at > '$4'::timestamptz and at <= '$5'::timestamptz
            ${hr:+and extract(hour from at at time zone '$tz') = $hr}
      group by instance_id, date_trunc('$2', at at time zone '$tz') order by 1"
}
# rankexp <metric> <fraction> <from> <to>: 'instance|rank' over every sample of the range
rankexp() {
  local f="percentile_cont($2) within group (order by v)"; [[ $2 == max ]] && f="max(v)"; [[ $2 == min ]] && f="min(v)"
  q "select instance_id || '|' || round(($f)::numeric, 4) from (${VAL[$1]}) x where at > '$3'::timestamptz and at <= '$4'::timestamptz group by instance_id order by 1"
}
startserve "$CFG" "$WORK/serve.log"; SRV=$SPID; U=$URL
api() {   # api <query string> <file>: the answer's code; the body in the file (no answer: the serve's last lines on stderr)
  local c; c=$(curl -s -o "$2" -w '%{http_code}' "$U/api/trend?$1")
  [[ $c == 000 ]] && { echo "  (no answer to $1; serve alive: $(kill -0 "$SRV" 2>/dev/null && echo yes || echo no); its log: $(tail -5 "$WORK/serve.log" | tr '\n' ' ' | cut -c1-600))" >&2; }
  echo "$c"
}
cat > "$WORK/chk.py" <<'PY'
import json, sys
# chk.py points <answer.json> <expected rows file>: every series point equals the expected row (0.01) and n matches;
# every expected row of an instance that has a series is drawn. Prints 'ok <detail>' or 'bad <detail>'.
# chk.py jq <answer.json> <python expression over d>: prints the expression's value
mode, f = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(f))
except Exception as e:
    # jq mode prints nothing for an answer that is not JSON (a row then fails on its own test, never passes on 'bad ...')
    if mode != 'jq':
        try:
            body = open(f, errors='replace').read(160).replace('\n', ' ')
        except OSError:
            body = '(no answer file)'
        print('bad the answer is not JSON (%s): %s' % (type(e).__name__, body))
    sys.exit(0)
if mode == 'jq':
    try:
        print(eval(sys.argv[3], {'d': d}))
    except Exception as e:
        print('ERR %s' % e)
    sys.exit(0)
from datetime import datetime
exp = {}
for l in open(sys.argv[3]):
    l = l.strip()
    if not l: continue
    i, b, v, n = l.split('|')
    exp[(int(i), int(b))] = (float(v), int(n))
got, bad = 0, []
drawn = set()
for s in d.get('series') or []:
    iid = int(s['instance_id']); drawn.add(iid)
    for p in s.get('points') or []:
        b = int(datetime.fromisoformat(p['at'].replace('Z', '+00:00')).timestamp())
        e = exp.get((iid, b))
        if e is None: bad.append('%s %s drawn, not in the seed' % (iid, p['at'])); continue
        if abs(float(p['v']) - e[0]) > 0.01 or int(p.get('n', -1)) != e[1]:
            bad.append('%s %s: %s n %s, expected %s n %s' % (iid, p['at'], p['v'], p.get('n'), e[0], e[1]))
        got += 1
missing = [k for k in exp if k[0] in drawn and not any(True for s in d['series'] if int(s['instance_id']) == k[0] for p in s['points'] if int(datetime.fromisoformat(p['at'].replace('Z', '+00:00')).timestamp()) == k[1])]
if bad or missing or got == 0:
    print('bad %d points checked, %d wrong (%s), %d expected not drawn' % (got, len(bad), '; '.join(bad[:3]), len(missing)))
else:
    print('ok %d points of %d series as the seed' % (got, len(drawn)))
PY
jq() { python3 "$WORK/chk.py" jq "$1" "$2"; }
FROM2=$(q "select '$T0'::timestamptz - interval '2 days'"); TO=$T0
ISO() { q "select to_char(($1) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"; }
F2=$(ISO "'$FROM2'::timestamptz"); TT=$(ISO "'$TO'::timestamptz")

# ---- V1-V6: every metric, hour buckets, p95 over 2 days ---------------------------------------------------------------
declare -A STAT=([os_cpu]=p95 [sql_cpu]=p95 [latency]=p95 [active]=p95 [free_memory]=p5 [connections]=p95)
declare -A FRAC=([p95]=0.95 [p5]=0.05)
n=0
for m in os_cpu sql_cpu latency active free_memory connections; do
  n=$((n + 1)); st=${STAT[$m]}
  c=$(api "metric=$m&bucket=hour&stat=$st&from=$F2&to=$TT&top=20&engine=both" "$WORK/v$n.json")
  # the range the answer says it read (the fleet latency's window moves from): the seed's percentiles over that range
  fa=$(jq "$WORK/v$n.json" "d.get('from') or ''"); ta=$(jq "$WORK/v$n.json" "d.get('to') or ''")
  expected "$m" hour "${FRAC[$st]}" "${fa:-$FROM2}" "${ta:-$TO}" > "$WORK/v$n.exp"
  r=$(python3 "$WORK/chk.py" points "$WORK/v$n.json" "$WORK/v$n.exp")
  [[ $c == 200 && $r == ok* ]] && ok "V$n $m $st by the hour: $r" || bad "V$n $m $st: $c $r"
done
# V3's trap: the raw cumulative reader gives other values for P1 than the deltas (else the row proves nothing)
fa=$(jq "$WORK/v3.json" "d.get('from') or ''"); ta=$(jq "$WORK/v3.json" "d.get('to') or ''")
VAL[rawlat]=$RAWLAT; expected rawlat hour 0.95 "${fa:-$FROM2}" "${ta:-$TO}" | grep "^$P1|" > "$WORK/raw.exp"
r=$(python3 "$WORK/chk.py" points "$WORK/v3.json" "$WORK/raw.exp" 2>/dev/null)
[[ $(jq "$WORK/v3.json" "any(int(s['instance_id']) == $P1 and s.get('points') for s in d.get('series') or [])") == True && $r == bad* ]] && ok "V3's trap: P1's latency is not the raw counters' ratio (the deltas read)" || bad "V3's trap: P1's latency matches the raw cumulative counters ($r)"

# ---- W: the words -----------------------------------------------------------------------------------------------------
why() { jq "$1" "next((x['why'] for x in d.get('none') or [] if int(x['instance_id']) == $2), '')"; }
[[ $(why "$WORK/v2.json" $P1) == *"PostgreSQL has no engine share of the host CPU"* && $(why "$WORK/v2.json" $P2) == *"PostgreSQL has no engine share of the host CPU"* ]] \
  && ok "W sql_cpu: both PostgreSQL instances say PostgreSQL has no engine share" || bad "W sql_cpu's words: P1 '$(why "$WORK/v2.json" $P1)', P2 '$(why "$WORK/v2.json" $P2)'"
[[ $(why "$WORK/v1.json" $P2) == *"no host read"* && $(why "$WORK/v5.json" $P2) == *"no host read"* ]] \
  && ok "W P2 (no host read): os_cpu and free_memory say 'no host read'" || bad "W P2's host words: '$(why "$WORK/v1.json" $P2)' / '$(why "$WORK/v5.json" $P2)'"
[[ -n $(why "$WORK/v3.json" $P2) ]] && ok "W P2's latency: '$(why "$WORK/v3.json" $P2)'" || bad "W P2's latency: no reason"
[[ $(jq "$WORK/v1.json" "any(int(s['instance_id']) == $S3 for s in d.get('series') or [])") == True ]] \
  && ok "W S3 (no other_pct): os_cpu drawn from idle_pct" || bad "W S3's os_cpu not drawn"
[[ -n $(why "$WORK/v1.json" $P3) ]] && ok "W P3 (no sample): '$(why "$WORK/v1.json" $P3)'" || bad "W P3: no reason"
w3=$(jq "$WORK/v3.json" "' '.join(d.get('words') or [])")
[[ $w3 == *"pg_stat_io"* && $w3 == *"stall"* ]] && ok "W latency's words name pg_stat_io's call time and SQL Server's stall" || bad "W latency's words: '$w3'"

# ---- K: top N and the rank --------------------------------------------------------------------------------------------
c=$(api "metric=os_cpu&bucket=hour&stat=max&from=$F2&to=$TT&top=2&engine=both" "$WORK/k1.json")
want=$(rankexp os_cpu max "$FROM2" "$TO" | sort -t'|' -k2 -g -r | head -2 | cut -d'|' -f1 | tr '\n' ' ')
got=$(jq "$WORK/k1.json" "' '.join(str(s['instance_id']) for s in d.get('series') or []) + ' '")
[[ $c == 200 && $got == "$want" ]] && ok "K os_cpu top 2 by max over the range: $got" || bad "K os_cpu top 2: $c got '$got' want '$want'"
c=$(api "metric=free_memory&bucket=hour&stat=p5&from=$F2&to=$TT&top=2&engine=both" "$WORK/k2.json")
want=$(rankexp free_memory 0.05 "$FROM2" "$TO" | sort -t'|' -k2 -g | head -2 | cut -d'|' -f1 | tr '\n' ' ')
got=$(jq "$WORK/k2.json" "' '.join(str(s['instance_id']) for s in d.get('series') or []) + ' '")
[[ $c == 200 && $got == "$want" ]] && ok "K free_memory: the two lowest first: $got" || bad "K free_memory top 2: $c got '$got' want '$want'"
c=$(api "metric=latency&bucket=hour&stat=p95&from=$F2&to=$TT&top=2&engine=both" "$WORK/k3.json")
got=$(jq "$WORK/k3.json" "sorted(s['engine'] for s in d.get('series') or [])")
[[ $c == 200 && $got == "['postgres', 'sqlserver', 'sqlserver']" ]] \
  && ok "K latency ranks within each engine: $got" || bad "K latency top 2 per engine: $c $got"

# ---- H: the hour of the day in the viewer's zone ----------------------------------------------------------------------
c=$(api "metric=os_cpu&bucket=hour&stat=p95&from=$F2&to=$TT&top=20&engine=both&hour=3&tz=America/Los_Angeles" "$WORK/h.json")
expected os_cpu hour 0.95 "$FROM2" "$TO" America/Los_Angeles 3 > "$WORK/h.exp"
r=$(python3 "$WORK/chk.py" points "$WORK/h.json" "$WORK/h.exp")
[[ $c == 200 && $r == ok* ]] && ok "H hour=3 America/Los_Angeles: $r" || bad "H: $c $r"

# ---- D: day buckets; hourly up to 31 days -----------------------------------------------------------------------------
F40=$(ISO "'$T0'::timestamptz - interval '40 days'"); FROM40=$(q "select '$T0'::timestamptz - interval '40 days'")
c=$(api "metric=active&bucket=day&stat=p95&from=$F40&to=$TT&top=20&engine=both" "$WORK/d1.json")
expected active day 0.95 "$FROM40" "$TO" > "$WORK/d1.exp"
r=$(python3 "$WORK/chk.py" points "$WORK/d1.json" "$WORK/d1.exp")
[[ $c == 200 && $r == ok* ]] && ok "D day buckets over 40 days: $r" || bad "D day buckets: $c $r"
c=$(api "metric=active&bucket=hour&stat=p95&from=$F40&to=$TT&top=20&engine=both" "$WORK/d2.json")
[[ $c == 200 && $(jq "$WORK/d2.json" "d.get('bucket')") == day && $(jq "$WORK/d2.json" "' '.join(d.get('words') or [])") == *"hourly up to 31 days, daily beyond"* ]] \
  && ok "D hour over 40 days answers by the day with the words" || bad "D hour over 40 days: $c bucket $(jq "$WORK/d2.json" "d.get('bucket')") words $(jq "$WORK/d2.json" "d.get('words')")"

# ---- R: the reach -----------------------------------------------------------------------------------------------------
F365=$(ISO "'$T0'::timestamptz - interval '365 days'")
c=$(api "metric=active&bucket=day&stat=p95&from=$F365&to=$TT&top=20&engine=both" "$WORK/r.json")
oldest=$(q "select to_char(min(snapshot_at) at time zone 'UTC', 'YYYY-MM-DD') from pgvigil.activity_summary")
wr=$(jq "$WORK/r.json" "' '.join(d.get('words') or [])")
[[ $c == 200 && $wr == *"samples kept back to $oldest"* && $wr == *"a year needs the hours (B21)"* ]] && ok "R a 365-day range: the reach words ($oldest)" || bad "R the reach: $c '$wr'"

# ---- B: by database ---------------------------------------------------------------------------------------------------
F7=$(ISO "'$T0'::timestamptz - interval '7 days'"); FROM7=$(q "select '$T0'::timestamptz - interval '7 days'")
c=$(api "metric=latency&bucket=hour&stat=p95&from=$F7&to=$TT&instance=$S1&by=database" "$WORK/b1.json")
dbs=$(jq "$WORK/b1.json" "sorted(s.get('database') for s in d.get('series') or [] if s.get('points'))")
VAL[latency_db]="select instance_id, snapshot_at as at, sum(read_stall_ms + write_stall_ms)::float8 / sum(reads + writes) as v
   from pgvigil.mssql_fileio_sample where instance_id = $S1 and database_name = 'db_a' group by 1, 2 having sum(reads + writes) / max(interval_secs) >= 1"
expected latency_db hour 0.95 "$FROM7" "$TO" > "$WORK/b1.exp"
python3 - "$WORK/b1.json" > "$WORK/b1a.json" <<'PY'
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
d['series'] = [s for s in d.get('series') or [] if s.get('database') == 'db_a']
print(json.dumps(d))
PY
r=$(python3 "$WORK/chk.py" points "$WORK/b1a.json" "$WORK/b1.exp")
[[ $c == 200 && $dbs == "['db_a']" && $r == ok* ]] && ok "B S1 by database over 7 days: db_a drawn as the seed, db_b idle no point ($r)" || bad "B S1 by database: $c $dbs $r"
c=$(api "metric=latency&bucket=hour&stat=p95&from=$F7&to=$TT&instance=$P1&by=database" "$WORK/b2.json")
[[ $c == 200 && $(jq "$WORK/b2.json" "' '.join(d.get('words') or [])") == *"pg_stat_io has no database split"* ]] && ok "B P1 by database: pg_stat_io has no database split" || bad "B P1 by database: $c $(jq "$WORK/b2.json" "d.get('words')")"
c=$(api "metric=latency&bucket=hour&stat=p95&from=$F7&to=$TT&by=database" "$WORK/b3.json")
[[ $c == 200 && $(jq "$WORK/b3.json" "len(d.get('series') or [])") == 0 && $(jq "$WORK/b3.json" "' '.join(d.get('words') or [])") == *"file I/O by database across the fleet waits for hourly history; one instance's page shows it"* ]] \
  && ok "B the fleet by database: off with its words" || bad "B the fleet by database: $c series $(jq "$WORK/b3.json" "len(d.get('series') or [])") words $(jq "$WORK/b3.json" "d.get('words')")"

# ---- C: the fleet latency reads the newest window -----------------------------------------------------------------------
c=$(api "metric=latency&bucket=hour&stat=p95&from=$F7&to=$TT&top=20&engine=both" "$WORK/c.json")
wc_=$(jq "$WORK/c.json" "' '.join(d.get('words') or [])")
WIN=""; [[ $wc_ == *"read the newest 1 day until hourly history lands"* ]] && WIN="1 day"; [[ $wc_ == *"read the newest 3 days until hourly history lands"* ]] && WIN="3 days"
if [[ $c != 200 || -z $WIN ]]; then bad "C the fleet latency's window words: $c '$wc_'"
else
  edge=$(q "select extract(epoch from '$T0'::timestamptz - interval '$WIN')::bigint")
  old=$(jq "$WORK/c.json" "min([int(__import__('datetime').datetime.fromisoformat(p['at'].replace('Z', '+00:00')).timestamp()) for s in d.get('series') or [] for p in s.get('points') or []] or [0])")
  [[ $old =~ ^[0-9]+$ && $old -ge $((edge - 3600)) ]] && ok "C the fleet latency over 7 days draws only the newest $WIN" || bad "C the fleet latency: a point at $old before the window's edge $edge ($WIN)"
fi

# ---- F: the fleet-scale timing (a database of its own, the collector's order) ----------------------------------------------
if [[ $FLEET != 1 ]]; then echo "F: skipped (FLEET=$FLEET)"
else
  DATADIR=$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtqc "show data_directory" 2>/dev/null)
  freegb() { df -BG --output=avail "${DATADIR:-$HOME}" 2>/dev/null | tail -1 | tr -dc '0-9'; }
  for _ in $(seq 1 30); do [[ $(freegb) -ge 9 ]] && break; echo "F: disk gate - $(freegb) GB free, 9 needed"; sleep 60; done
  if [[ $(freegb) -lt 9 ]]; then bad "F: disk gate - $(freegb) GB free after 30 min, 9 needed"
  else
    psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB2" >/dev/null || die "create database $DB2"
    CFG2=$WORK/fleet.yaml; printf 'repository:\n  dsn: "%s dbname=%s"\ninstances: []\n' "$PGVIGIL_ADMIN_DSN" "$DB2" > "$CFG2"
    "$BIN" migrate -config "$CFG2" > "$WORK/migrate2.log" 2>&1 || die "migrate (fleet): $(tail -3 "$WORK/migrate2.log")"
    q2() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB2" -XAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
    q2 "select pgvigil.ensure_instance('trend-f' || i || '-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver') from generate_series(1, 100) i" > /dev/null || die "the fleet's instances"
    q2 "select pgvigil.ensure_month_partition('mssql_fileio_sample', d) from generate_series(now() - interval '4 days', now() + interval '1 day', interval '1 day') d" > /dev/null
    t0=$(date +%s)
    for dd in 0 1 2; do
      out=$(q2 "insert into pgvigil.mssql_fileio_sample (instance_id, snapshot_at, database_id, file_id, database_name, file_name, type_desc,
                       reads, read_bytes, read_stall_ms, writes, write_bytes, write_stall_ms, interval_secs)
                select i.instance_id, t, db, f, 'db_' || db, 'db_' || db || '_' || f, case f when 1 then 'ROWS' else 'LOG' end,
                       r.rd, r.rd * 8192, (r.rd * random() * 20)::bigint, r.wr, r.wr * 8192, (r.wr * random() * 8)::bigint, 60
                  from generate_series(date_trunc('minute', now()) - make_interval(days => 3 - $dd), date_trunc('minute', now()) - make_interval(days => 2 - $dd) - interval '1 minute', interval '1 minute') t
                 cross join (select instance_id from pgvigil.instances where name like 'trend-f%') i
                 cross join generate_series(1, 20) db cross join generate_series(1, 2) f
                 cross join lateral (select 1 + (random() * 400)::bigint + 0 * db AS rd, 1 + (random() * 200)::bigint + 0 * f AS wr) r
                 order by t, i.instance_id, db, f") || die "the fleet's seed, day $dd: $out"
    done
    q2 "vacuum (analyze) pgvigil.mssql_fileio_sample" > /dev/null
    echo "F: seeded $(q2 "select count(*) from pgvigil.mssql_fileio_sample") rows ($(q2 "select pg_size_pretty(sum(pg_total_relation_size(c.oid))) from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'pgvigil.mssql_fileio_sample'::regclass")) in $(( $(date +%s) - t0 )) s; free $(freegb) GB"
    declare -A TIMES
    for win in 1 3; do
      TIMES[$win]=""
      for run in 1 2; do
        o=$(psql "$PGVIGIL_ADMIN_DSN dbname=$DB2" -XAt -c "set default_transaction_read_only = on; set statement_timeout = 15000; set jit = off;" \
              -c "explain (analyze) select * from pgvigil.trend_series('latency', null, now() - interval '$win days', now(), 'hour', 'p95', null, 'UTC')" 2>&1)
        x=$(grep -o -E 'Execution Time: [0-9.]+' <<<"$o" | awk '{printf "%.2f", $3 / 1000}')
        [[ -z $x ]] && x="(none: $(head -1 <<<"$o" | cut -c1-120))"
        echo "F: trend_series over $win day(s), read $run: $x s"; TIMES[$win]+=" $x"
      done
    done
    startserve "$CFG2" "$WORK/serve2.log"; SRV2=$SPID; U2=$URL
    res=$(curl -s -o "$WORK/f-api.json" -w '%{http_code} %{time_total}' "$U2/api/trend?metric=latency&engine=sqlserver&bucket=hour&stat=p95&top=5&from=$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ)&to=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    echo "F: GET /api/trend, the fleet latency end to end: $res s (series $(jq "$WORK/f-api.json" "len(d.get('series') or [])"))"
    under() { for x in $1; do [[ $x == *none* ]] && return 1; python3 -c "import sys; sys.exit(0 if float('$x') < 10 else 1)" || return 1; done; return 0; }
    if under "${TIMES[1]}"; then ok "F: 1 day under 10 s on both reads (${TIMES[1]} s)"; else bad "F: 1 day: ${TIMES[1]} s (10 s the bar)"; fi
    if under "${TIMES[3]}"; then FW="3 days"; else FW="1 day"; fi
    echo "F: the window: $FW (3 days: ${TIMES[3]} s; the lead 18:1x: 3 days if both reads under 10 s, else 1 day)"
    [[ -n $WIN && $WIN == "$FW" ]] && ok "F: C's words name the window the timing gives ($FW)" || bad "F: C's words name '${WIN:-none}', the timing gives $FW"
  fi
fi
echo "proof-trend: $FAILS FAIL"
(( FAILS == 0 ))
