#!/usr/bin/env bash
# Proof of the SQL Server blocking charts by lead blocker (SQLMonitor G52 / G53) and the chain timeline (the Blocked
# reports page): internal/web/q_blocking_history.go (parts by_login, by_program, chains), web/src/blocking_history.ts,
# web/src/mssql_xe.ts.
#
# Runs on a box with docker and chromium (no local server): its own PostgreSQL container as the repository (removed on
# every exit path), pgvigil serve -no-login on a port of its own (stopped by its pid), the pages read with headless
# chromium's --dump-dom. Every row is on a SQL Server instance of its own (proof-b10c-*) whose snapshots the proof writes.
# Needs: docker, psql, curl, python3, chromium; PGVIGIL_BIN (default bin/pgvigil) of the tree under proof, its bundle current.
#
# The rows written: three requests snapshots (50, 30 and 10 minutes ago), each with ten chain heads 101..110; head 100+k
# runs as login lk and program pk, blocks k sessions, its longest victim waits k x 40 s, its transaction began at one
# time for the whole range - except head 101, whose transaction in the last snapshot began anew; and head 120 (login
# l20, program p20, no victims in the requests, its longest wait 10 s) with NO transaction start read, heading in the
# first and the last snapshot and not the middle one.
#
# Expected (written before the first run; RED = what the tree before this change does):
#  A. GET /api/blocking/history part=by_login: per step the blocked sessions behind each lead blocker's login (the most in
#     one snapshot of the step), the 8 logins with the most over the range by name (l3 .. l10) and the rest as 'Other'
#     (l1 + l2 = 3 per snapshot); at each snapshot's step the parts sum to the snapshot's blocked sessions (55); every
#     step of the window is there, the steps without a snapshot 0 for every name (the bands fall to zero, never bridge a
#     quiet stretch). RED: the part is refused (400) or absent.
#  B. part=by_program: the same by program (p3 .. p10, 'Other' 3). RED: as A.
#  C. the Running queries page's 'Blocking over the range' draws 'Blocked sessions by lead-blocker login' and 'Blocked
#     sessions by lead-blocker program', stacked (the chart's data-stacked), each with 9 series in its legend (8 and
#     Other; uPlot's u-series rows less the time). RED: neither title.
#  D. part=chains: one row per chain (a head and its transaction): 13 (ten heads, 101's second transaction, and head
#     120's two stretches: no transaction start, a snapshot passed without it), each with its first and last sight, its
#     longest wait (k x 40 s; 120's 10 s), the head's login and program; 101's first chain seen in two snapshots, its
#     second in one; 120's two in one each. RED: the part is refused or absent.
#  E. the Blocked reports page draws 'Chains over the range': one bar per chain (11), coloured by its longest wait as
#     'a blocking chain' judges one (over 300 s critical: 3; over 30 s warning: 8; 120's two neither), each bar's title
#     naming the head's login and program, and a grid of 13 rows under it; the drawing in a box that scrolls (its bars
#     keep their height however many chains), a time axis of 5 labelled ticks, and the grid's 'as a blocking chain'
#     column naming 3 critical and 8 warning. RED: no such section.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
PIMG=${PGVIGIL_B10_PG_IMAGE:-postgres:18}
SUF=$RANDOM; PCT=pgvb10c_$SUF; PPORT=$((30000 + SUF % 10000)); PORT=$((40000 + SUF % 10000)); SRVPID=
CFG=$(mktemp); OUT=$(mktemp); bad=0
fail() { echo "FAIL: $*" >&2; exit 1; }
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (got '$1', want '$2')"; bad=$((bad + 1)); fi; }
cleanup() {
  rc=$?; set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" >/dev/null 2>&1
  docker rm -f "$PCT" >/dev/null 2>&1 || echo "CLEANUP: container $PCT not removed" >&2
  rm -f "$CFG" "$OUT" "$OUT".*
  exit $rc
}
trap cleanup EXIT
docker run -d --name "$PCT" -e POSTGRES_HOST_AUTH_METHOD=trust -p "127.0.0.1:$PPORT:5432" "$PIMG" -c max_connections=300 >/dev/null
for i in $(seq 1 30); do psql "host=127.0.0.1 port=$PPORT user=postgres" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 2; done
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$PPORT user=postgres dbname=postgres"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
S=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
       values ('proof-b10c-$SUF', 'sqlserver', '{env:proofb10}', now(), now(), true, 'sqlserver') returning instance_id" | head -1)
# mssql_requests_summary is a plain table (0064); mssql_requests has a partition per UTC day and mssql_blocking one per
# UTC month (as import_mssql_requests makes them), each made at the oldest seed (51 minutes back: a run in the first
# hour of a UTC day or month seeds into the one before) and at now
q "select pgvigil.mssql_ensure_day_partition('mssql_requests', t), pgvigil.ensure_month_partition('mssql_blocking', t)
     from unnest(array[now() - interval '51 minutes', now()]) t" >/dev/null
q "with snaps(at, n) as (values (date_trunc('minute', now()) - interval '50 minutes', 1), (date_trunc('minute', now()) - interval '30 minutes', 2),
                                (date_trunc('minute', now()) - interval '10 minutes', 3))
   , heads as (select k, 100 + k as head from generate_series(1, 10) k)
   , i1 as (insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source, sessions, requests, blocked, heads, longest_wait_ms)
            select $S, at, 'dmv', 80, 65, 55, 10, 400000 from snaps returning 1)
   , i2 as (insert into pgvigil.mssql_blocking (instance_id, snapshot_at, head_session_id, victims, longest_wait_ms, in_snapshot, head_status,
                   head_open_tran, head_tran_start, head_login, head_program)
            select $S, s.at, h.head, h.k, h.k * 40000, true, 'sleeping', 1,
                   case when h.k = 1 and s.n = 3 then now() - interval '12 minutes' else now() - interval '2 hours' end, 'l' || h.k, 'p' || h.k
              from snaps s, heads h
            union all
            select $S, s.at, 120, 1, 10000, true, 'sleeping', 1, null, 'l20', 'p20' from snaps s where s.n in (1, 3) returning 1)
   , i3 as (insert into pgvigil.mssql_requests (instance_id, snapshot_at, session_id, request_id, status, wait_type, wait_ms, blocking_session_id,
                   head_session_id, is_user_process, login_name, program_name, database_name)
            select $S, s.at, 1000 + h.k * 20 + j, 0, 'suspended', 'LCK_M_X', h.k * 40000, h.head, h.head, true, 'victim', 'victimapp', 'b10'
              from snaps s, heads h, generate_series(1, 10) j where j <= h.k
            union all
            select $S, s.at, h.head, 0, 'sleeping', null, 0, 0, h.head, true, 'l' || h.k, 'p' || h.k, 'b10' from snaps s, heads h returning 1)
   select (select count(*) from i1), (select count(*) from i2), (select count(*) from i3)" >/dev/null
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login > "$OUT.serve" 2>&1 & SRVPID=$!
for i in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" && break; sleep 1; done
curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" || { tail -20 "$OUT.serve" >&2; fail "pgvigil serve did not answer on 127.0.0.1:$PORT within 60 s (its log above)"; }
FROM=$(q "select to_char((now() - interval '1 hour') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"); TO=$(q "select to_char(now() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
part() { curl -s -o "$OUT.$1" -w '%{http_code}' --get "http://127.0.0.1:$PORT/api/blocking/history" --data-urlencode "instance=$S" --data-urlencode "from=$FROM" --data-urlencode "to=$TO" --data-urlencode "part=$1" || true; }   # no answer = '000', a check's FAIL, not the proof's end
py() { python3 -I -c "$1" "${@:2}"; }
# a part's rows as a list of dicts (a Table: cols + rows, or a list), from the saved reply
ROWS='
import json, sys
d = json.load(open(sys.argv[1])); t = d.get(sys.argv[2]) if isinstance(d, dict) else d
rows = [dict(zip(t["columns"], r)) for r in t["rows"]] if isinstance(t, dict) and "columns" in t else (t or [])
'
page() { chromium --headless=new --no-sandbox --disable-gpu --virtual-time-budget=20000 --dump-dom "http://127.0.0.1:$PORT/#/$1?i=$S&from=$FROM&to=$TO" 2>/dev/null; }

echo "--- A / B. the blocked sessions by lead blocker"
for k in login program; do
  code=$(part "by_$k")
  if [ "$code" != 200 ]; then check "$code" 200 "$k: part by_$k answered"; continue; fi
  check "$(py "$ROWS
p = sys.argv[3][0]
names = sorted({r['who'] for r in rows})
want = sorted([p + str(i) for i in range(3, 11)] + ['Other'])
steps = {}
for r in rows: steps.setdefault(r['snapshot_at'], {})[r['who']] = r['blocked']
full = [s for s in steps.values() if sum(s.values()) > 0]
quiet = [s for s in steps.values() if sum(s.values()) == 0]
print('%s|%d|%s|%s|%s' % (names == want, len(full), all(sum(s.values()) == 55 and len(s) == 9 for s in full), all(s.get('Other') == 3 for s in full),
      len(quiet) > 0 and all(len(s) == 9 for s in quiet)))" "$OUT.by_$k" "by_$k" "$k")" "True|3|True|True|True" "$k: 8 by name and Other, 3 snapshot steps summing to 55, Other 3; the quiet steps there at 0 for every name"
done

echo "--- C. the two stacked charts on the Running queries page"
page mssql_running > "$OUT.run"
for k in login program; do
  check "$(py "
import re, sys
h = open(sys.argv[1]).read()
i = h.find('Blocked sessions by lead-blocker $k')
if i < 0: print('absent'); sys.exit()
a = h.rfind('<div class=\"chart\"', 0, i); b = h.find('<div class=\"chart\"', i)
box = h[a:b if b > 0 else len(h)]
head = box[:box.find('>') + 1]
print('found|%s|%d' % ('data-stacked=\"true\"' in head, len(re.findall(r'class=\"u-series', box)) - 1))" "$OUT.run")" "found|True|9" "C: 'Blocked sessions by lead-blocker $k' drawn stacked, 9 series in its legend"
done

echo "--- D. the chains of the range"
code=$(part chains)
if [ "$code" != 200 ]; then check "$code" 200 "D: part chains answered"; else
  check "$(py "$ROWS
r101 = sorted([r for r in rows if r['head_session_id'] == 101], key=lambda r: r['first_at'])
r120 = sorted([r for r in rows if r['head_session_id'] == 120], key=lambda r: r['first_at'])
print('%d|%s|%s|%s|%s' % (len(rows), [r['snapshots'] for r in r101], [r['snapshots'] for r in r120],
      sorted(r['longest_wait_ms'] for r in rows if r['head_session_id'] not in (101, 120)),
      sorted({(r['head_login'], r['head_program']) for r in rows})[:2]))" "$OUT.chains" chains)" \
    "13|[2, 1]|[1, 1]|[80000, 120000, 160000, 200000, 240000, 280000, 320000, 360000, 400000]|[('l1', 'p1'), ('l10', 'p10')]" "D: 13 chains, 101's two (2 and 1 snapshots), 120's two stretches (1 and 1), the waits k x 40 s, login and program"
fi

echo "--- E. the chain timeline on the Blocked reports page"
page mssql_blocked > "$OUT.blk"
check "$(py "
import re, sys
h = open(sys.argv[1]).read()
i = h.find('Chains over the range')
if i < 0: print('absent'); sys.exit()
s = h[i:]
s = s[:s.find('Findings over the range')] if 'Findings over the range' in s else s
bars = re.findall(r'<rect[^>]*class=\"chain-bar ([a-z]+)\"[^>]*>\s*<title>([^<]*)</title>', s)
extra = '%s|%d|%d|%d' % ('class=\"chain-scroll\"' in s, len(re.findall(r'class=\"chain-tick-label\"', s)),
                         len(re.findall(r'class=\"badge crit\">critical<', s)), len(re.findall(r'class=\"badge warn\">warning<', s)))
print('%d|%d|%d|%s|%s' % (len(bars), sum(b[0] == 'crit' for b in bars), sum(b[0] == 'warn' for b in bars), all(re.search(r'login l(\\d+), program p\\1\\b', b[1]) for b in bars), extra))" "$OUT.blk")" "13|3|8|True|True|5|3|8" "E: 13 bars, 3 critical, 8 warning (120's two neither), each titled 'login lk, program pk'; the scroll box, 5 ticks, the grid's band 3 critical / 8 warning"

echo
[ "$bad" = 0 ] && echo "proof-b10-charts: every row ok" || { echo "proof-b10-charts: $bad row(s) FAIL"; exit 1; }
