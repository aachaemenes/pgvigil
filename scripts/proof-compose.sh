#!/usr/bin/env bash
# Proof of the composed panel's compiler and POST /api/compose/run (VIEWS slice C's server half; internal/web/compose.go,
# q_compose.go; the design notes/projects/pdfp-sqltoolsbuild-s3/pdfp-sqltoolsbuild-s3-views-design.md of the DBA repo,
# FOLD 4-6). Needs go, psql, curl, python3, ss and PGVIGIL_ADMIN_DSN (a keyword-form superuser connection to a PostgreSQL
# 13+ cluster; the proof makes its own repository database and drops it). PGVIGIL_WIRING=1 (default) applies
# scripts/proof-views-wiring.patch to this copy when the tree has the handlers and web.go lacks the routes; the
# repository then gets scripts/views-join-lines.sql (metric_catalog's grain).
#
# The data (the last 4 hours, the window the last 3): instance A (PostgreSQL, tag env:a) read every minute, sessions
# total 10 and one database 'appdb' whose deadlocks grow 1 a minute; B (PostgreSQL, env:b) read every 5 minutes, total
# 30, 'appdb' deadlocks +5 a read; C (SQL Server, env:c) with session rows of total 1000 - another engine, never in a
# PostgreSQL metric's panel.
# Expected (written before the first run):
#  C1 sessions.total (a gauge), over time, sum, hour buckets: every hour = 40 (A's hourly average 10 + B's 30 - not the
#     samples' sum, 60 x 10 + 12 x 30), equal bucket by bucket to a hand read of activity_summary (per instance per hour
#     averaged, then summed); C's 1000 in no bucket.
#  C2 the same, avg across the instances: every hour = 20.
#  C3 grouped by instance, avg: A 10 and B 30 in every hour.
#  C4 top 1 over time with '(other)', sum, by instance: series B (30) and (other) (10); each hour's series sum = C1's 40.
#  C5 ranked by the tag key env, avg: b 30 rank 1, a 10 rank 2.
#  C6 database.deadlocks (a count per interval), over time, sum, hour: each full hour = 120 (A 60 one-minute counts of
#     1, B 12 five-minute counts of 5 - summed per instance, then across), equal to a hand read of dbstats' differences.
#  C7 a single value, avg of sessions.total = 20; the reply's read names metric_points and 'averaged per instance per
#     the window'; bucket_secs = the window's seconds (refined after green2: a single value is one roll-up over the window,
#     not a bucket); an over-time panel of day buckets says utc_days true.
#  C8 database.deadlocks grouped by database on A alone: one series 'appdb' (60 a full hour); filtered is_not appdb: no row.
#  R1 refused 400 in words: a ratio summed (database.cache_hit_pct), a sum by tag, an unknown metric, a top of 9 over
#     time, a window of 2d.
#  R2 a window from 200 days ago: the reply's cut says the family's longest range, its from = to - that range.
#  R3 a dashboard of 13 panels saved through POST /api/views -> 400 'at most 12 panels'; 12 -> 200.
#  [review C fold, written before the rerun] The window starts on a bucket's edge and the reply says the scope's
#  instances (2) and whether its last bucket is partial: C1 and C6 compare EVERY bucket but a partial last one with the
#  hand reads over the reply's window (no edge cut), and no bucket the hand read lacks; C1b the same at bucket auto: 5-
#  minute buckets (a 1-minute family's floor), each 40 - no saw between A's minutes and B's 5-minute reads; C9 a single
#  value's sum of the gauge = 40 (each instance's window average, summed); R2 the cut is exactly 90 days (the scope
#  counts 2 instances: sessions' 7 days at 40 scale past the 90-day ceiling); R4 a panel by
#  database at fleet scope -> 400 'one instance'; R5 a minute bucket across instances -> 400.
#  Red on b0e9c414 (before the compiler): POST /api/compose/run answers 405 (no route).
set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?}"
cd "$(dirname "$0")/.."
SUF=$RANDOM; REPO=pgvigil_compose_$SUF; UU=cu$SUF; UPW=c$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || echo "CLEANUP: $REPO not dropped" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql curl python3 ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
HAVE=0; grep -q 'func (s \*Server) ComposeRun(' internal/web/*.go 2>/dev/null && HAVE=1
if [[ "${PGVIGIL_WIRING:-1}" == 1 && $HAVE == 1 ]] && ! grep -q '/api/compose/run' internal/web/web.go; then
  git apply scripts/proof-views-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-views-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy"
fi
BIN=$WORK/pgvigil
go build -o "$BIN" ./cmd/pgvigil || fail "go build"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null || fail "create database"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/cfg.yaml"; CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out" >&2; fail "migrate"; }
if [[ $HAVE == 1 ]]; then psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -f scripts/views-join-lines.sql >/dev/null || fail "the join lines"; fi
PGVIGIL_PASSWORD=$UPW "$BIN" user add -config "$CFG" "$UU" >/dev/null 2>&1 || fail "user add"

# ---- the data ------------------------------------------------------------------------------------------------------------
NOW=$(q "select extract(epoch from date_trunc('minute', now()))::bigint")
q "insert into pgvigil.instances (name, platform, engine, tags) values
     ('cmp-a-$SUF', 'onprem', 'postgres', '{env:a}'), ('cmp-b-$SUF', 'onprem', 'postgres', '{env:b}'),
     ('cmp-c-$SUF', 'onprem', 'sqlserver', '{env:c}')" >/dev/null || fail "the instances"
IA=$(q "select instance_id from pgvigil.instances where name = 'cmp-a-$SUF'"); IB=$(q "select instance_id from pgvigil.instances where name = 'cmp-b-$SUF'")
IC=$(q "select instance_id from pgvigil.instances where name = 'cmp-c-$SUF'")
q "select pgvigil.ensure_month_partition('dbstats', to_timestamp($NOW) - interval '5 hours'); select pgvigil.ensure_month_partition('dbstats', to_timestamp($NOW))" >/dev/null || fail "dbstats' partitions"
# A every minute, B every 5 minutes, C every minute; 4 hours back from the minute now
q "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
     active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
   select s.i, to_timestamp($NOW) - k * interval '1 minute', s.total, 1, s.total - 1, 0, 0, 0, 0, 1, 0, 1000, 500
     from generate_series(0, 240) k
     cross join (values ($IA, 10, 1), ($IB, 30, 5), ($IC, 1000, 1)) s(i, total, every)
    where k % s.every = 0" >/dev/null || fail "activity_summary"
q "insert into pgvigil.dbstats (instance_id, snapshot_at, dbid, datname, stats_reset, numbackends, xact_commit, xact_rollback,
     blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, conflicts, temp_files, temp_bytes,
     deadlocks, checksum_failures, blk_read_time, blk_write_time, session_time, active_time, idle_in_transaction_time,
     sessions, sessions_abandoned, sessions_fatal, sessions_killed, epoch)
   select s.i, to_timestamp($NOW) - k * interval '1 minute', 16384, 'appdb', to_timestamp($NOW) - interval '30 days', 5,
          (240 - k) * 100, 0, (240 - k) * 10, (240 - k) * 1000, 0, 0, 0, 0, 0, 0, 0, 0,
          240 - k, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
     from generate_series(0, 240) k
     cross join (values ($IA, 1), ($IB, 5)) s(i, every)
    where k % s.every = 0" >/dev/null || fail "dbstats"
FROM_ISO=$(q "select to_char((to_timestamp($NOW) - interval '3 hours') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
TO_ISO=$(q "select to_char(to_timestamp($NOW) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
[[ -n "$FROM_ISO" && -n "$TO_ISO" ]] || fail "setup: the window's ends"
ok "setup: A ($IA, every minute), B ($IB, every 5 minutes), C ($IC, SQL Server); the window $FROM_ISO .. $TO_ISO"

# ---- serve -----------------------------------------------------------------------------------------------------------------
PORT=$((20000 + RANDOM % 20000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 & SRV=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRV" 2>/dev/null || { tail -5 "$WORK/serve.log" >&2; fail "serve exited"; }
J=$WORK/jar
[[ $(curl -s -o /dev/null -w '%{http_code}' -c "$J" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UU\",\"password\":\"$UPW\"}" "$U/api/login") == 200 ]] || fail "the API login"
# run <panel json> [scope json] [from] [to] [database]: the HTTP code; the reply in $WORK/out.json
NOSCOPE='{}'
run() {
  python3 -c "import json,sys; print(json.dumps({'panel': json.loads(sys.argv[1]), 'scope': json.loads(sys.argv[2]), 'from': sys.argv[3], 'to': sys.argv[4], 'database': sys.argv[5]}))" \
    "$1" "${2:-$NOSCOPE}" "${3:-$FROM_ISO}" "${4:-$TO_ISO}" "${5:-}" > "$WORK/in.json"
  curl -s -o "$WORK/out.json" -w '%{http_code}' -b "$J" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/in.json" "$U/api/compose/run"
}
# rowsj: the reply's rows as [{column: value}] (bucket as epoch seconds)
rowsj() { python3 -c "
import json, datetime
d = json.load(open('$WORK/out.json')); t = d['rows']
def ep(v):
    return int(datetime.datetime.fromisoformat(v.replace('Z', '+00:00')).timestamp()) if isinstance(v, str) else v
print(json.dumps([{k: (ep(v) if k == 'bucket' else v) for k, v in zip(t['columns'], r)} for r in (t['rows'] or [])]))"; }
expect() { [[ $1 == "$2" ]] || fail "$3: HTTP $1, want $2: $(head -c 400 "$WORK/out.json")"; }

c=$(run '{"metric":"sessions.total","aggregate":"sum","shape":"over_time","bucket":"hour"}')
[[ $c == 404 || $c == 405 ]] && fail "C1: POST /api/compose/run: HTTP $c (red before the compiler: no route)"
expect "$c" 200 "C1"
RFROM=$(python3 -c "import json,datetime; print(int(datetime.datetime.fromisoformat(json.load(open('$WORK/out.json'))['from'].replace('Z','+00:00')).timestamp()))")
hand_sessions() {   # hand_sessions <bucket secs>: per instance per bucket averaged, then summed, over the reply's window
  q "select json_agg(json_build_array(b, v) order by b) from (select extract(epoch from b)::bigint b, sum(v)::float8 v from (
   select instance_id, to_timestamp(floor(extract(epoch from snapshot_at) / $1) * $1) b, avg(total) v from pgvigil.activity_summary
    where instance_id in ($IA, $IB) and snapshot_at >= to_timestamp($RFROM) and snapshot_at <= to_timestamp($NOW)
    group by 1, 2) x group by 1) y"; }
HAND=$(hand_sessions 3600)
check_buckets() {   # check_buckets <label> <want>: every bucket = the hand read's, no extra; every bucket but a partial last = want
python3 - "$(rowsj)" "$HAND" "$2" "$1" "$WORK/out.json" <<'PY' || fail "$1: see above"
import json, sys
d = json.load(open(sys.argv[5]))
api = {r['bucket']: r['value'] for r in json.loads(sys.argv[1])}; hand = {b: v for b, v in json.loads(sys.argv[2])}
bad = [b for b in hand if abs(api.get(b, -1) - hand[b]) > 1e-9] + [b for b in api if b not in hand]
keys = sorted(api)
whole = keys[:-1] if d.get('last_partial') else keys
if bad or not whole or any(abs(api[b] - float(sys.argv[3])) > 1e-9 for b in whole) or d.get('instances') != 2:
    print('DIFF', sys.argv[4], 'api', api, 'hand', hand, 'instances', d.get('instances'), 'last_partial', d.get('last_partial')); sys.exit(1)
print(f"     {sys.argv[4]} {len(api)} buckets of {d['bucket_secs']} s, every whole one {sys.argv[3]} (last partial: {d.get('last_partial')}), = the hand read")
PY
}
check_buckets C1 40
ok "C1: a gauge's fleet sum per hour = the per-instance hourly averages summed (40), every bucket equal to the hand read (no edge cut); the SQL Server instance in none"
c=$(run '{"metric":"sessions.total","aggregate":"sum","shape":"over_time","bucket":"auto"}'); expect "$c" 200 "C1b"
[[ $(python3 -c "import json; print(json.load(open('$WORK/out.json'))['bucket_secs'])") == 300 ]] || fail "C1b: auto's bucket: $(head -c 300 "$WORK/out.json")"
RFROM=$(python3 -c "import json,datetime; print(int(datetime.datetime.fromisoformat(json.load(open('$WORK/out.json'))['from'].replace('Z','+00:00')).timestamp()))")
HAND=$(hand_sessions 300); check_buckets C1b 40
ok "C1b: at bucket auto, 5-minute buckets each 40 - no saw between the 1- and 5-minute instances"
c=$(run '{"metric":"sessions.total","aggregate":"avg","shape":"over_time","bucket":"hour"}'); expect "$c" 200 "C2"
python3 -c "import json,sys; d=json.load(open('$WORK/out.json')); v=[r['value'] for r in json.loads(sys.argv[1])]; v=v[:-1] if d.get('last_partial') else v; sys.exit(0 if v and all(abs(x-20)<1e-9 for x in v) else 1)" "$(rowsj)" || fail "C2: $(rowsj)"
ok "C2: avg across the instances = 20 an hour"
c=$(run '{"metric":"sessions.total","aggregate":"avg","shape":"over_time","bucket":"hour","group_by":"instance"}'); expect "$c" 200 "C3"
python3 -c "
import json,sys; r=json.loads(sys.argv[1]); s={}
[s.setdefault(x['series'], set()).add(x['value']) for x in r]
sys.exit(0 if s == {'cmp-a-$SUF': {10.0}, 'cmp-b-$SUF': {30.0}} else 1)" "$(rowsj)" || fail "C3: $(rowsj)"
ok "C3: by instance: A 10, B 30 every hour"
c=$(run '{"metric":"sessions.total","aggregate":"sum","shape":"top_over_time","bucket":"hour","group_by":"instance","top":1,"other":true}'); expect "$c" 200 "C4"
python3 -c "
import json,sys,collections; r=json.loads(sys.argv[1]); t=collections.defaultdict(float); s={}
for x in r: t[x['bucket']] += x['value']; s.setdefault(x['series'], set()).add(x['value'])
full=[t[b] for b in sorted(t)][1:-1]
sys.exit(0 if s.get('cmp-b-$SUF') == {30.0} and s.get('(other)') == {10.0} and full and all(abs(v-40)<1e-9 for v in full) else 1)" "$(rowsj)" || fail "C4: $(rowsj)"
ok "C4: top 1 with (other): B 30 and (other) 10, each hour summing to C1's 40"
c=$(run '{"metric":"sessions.total","aggregate":"avg","shape":"ranked","group_by":"tag","tag_key":"env"}'); expect "$c" 200 "C5"
[[ $(python3 -c "import json,sys; print([(x['series'], float(x['value']), x['rank']) for x in json.loads(sys.argv[1])])" "$(rowsj)") == "[('b', 30.0, 1), ('a', 10.0, 2)]" ]] || fail "C5: $(rowsj)"
ok "C5: ranked by env: b 30 first, a 10 second"
c=$(run '{"metric":"database.deadlocks","aggregate":"sum","shape":"over_time","bucket":"hour"}'); expect "$c" 200 "C6"
RFROM=$(python3 -c "import json,datetime; print(int(datetime.datetime.fromisoformat(json.load(open('$WORK/out.json'))['from'].replace('Z','+00:00')).timestamp()))")
HAND=$(q "select json_agg(json_build_array(b, v) order by b) from (select extract(epoch from b)::bigint b, sum(v)::float8 v from (
   select instance_id, to_timestamp(floor(extract(epoch from snapshot_at) / 3600) * 3600) b, sum(d) v from (
     select instance_id, snapshot_at, deadlocks - lag(deadlocks) over (partition by instance_id order by snapshot_at) d from pgvigil.dbstats
      where instance_id in ($IA, $IB)) z
    where d is not null and snapshot_at >= to_timestamp($RFROM) and snapshot_at <= to_timestamp($NOW) group by 1, 2) x group by 1) y")
check_buckets C6 120
ok "C6: a count per interval summed per instance, then across (120 every whole hour), every bucket equal to the hand read of dbstats' differences"
c=$(run '{"metric":"sessions.total","aggregate":"avg","shape":"single","bucket":"hour"}'); expect "$c" 200 "C7"
python3 -c "
import json,sys; d=json.load(open('$WORK/out.json')); r=d['rows']; v=dict(zip(r['columns'], r['rows'][0]))
ok = abs(v['value']-20)<1e-9 and 'metric_points' in d['read'] and 'averaged per instance per the window' in d['read'] and d['bucket_secs']==3*3600 and d['utc_days'] is False
sys.exit(0 if ok else 1)" || fail "C7: $(head -c 400 "$WORK/out.json")"
c=$(run '{"metric":"sessions.total","aggregate":"avg","shape":"over_time","bucket":"day"}'); expect "$c" 200 "C7 day"
[[ $(python3 -c "import json; print(json.load(open('$WORK/out.json'))['utc_days'])") == True ]] || fail "C7: a day bucket not said UTC"
c2=$(run '{"metric":"sessions.total","aggregate":"sum","shape":"single"}'); expect "$c2" 200 "C9"
python3 -c "import json; d=json.load(open('$WORK/out.json')); v=dict(zip(d['rows']['columns'], d['rows']['rows'][0]))['value']; import sys; sys.exit(0 if abs(v-40)<1e-9 else 1)" || fail "C9: $(head -c 300 "$WORK/out.json")"
ok "C9: a single value's sum of the gauge = 40 (each instance's window average, summed)"
ok "C7: a single value 20; the read named ($(python3 -c "import json; print(json.load(open('$WORK/out.json'))['read'][:90])")); a day bucket said UTC"
c=$(run '{"metric":"database.deadlocks","aggregate":"sum","shape":"over_time","bucket":"hour","group_by":"database"}' "{\"kind\":\"instances\",\"instances\":[$IA]}"); expect "$c" 200 "C8"
python3 -c "
import json,sys; r=json.loads(sys.argv[1]); s={x['series'] for x in r}; full=[x['value'] for x in r][1:-1]
sys.exit(0 if s == {'appdb'} and full and all(abs(v-60)<1e-9 for v in full) else 1)" "$(rowsj)" || fail "C8: $(rowsj)"
c=$(run '{"metric":"database.deadlocks","aggregate":"sum","shape":"over_time","bucket":"hour","group_by":"database","filters":[{"dim":"database","op":"is_not","values":["appdb"]}]}' "{\"kind\":\"instances\",\"instances\":[$IA]}")
expect "$c" 200 "C8 filtered"; [[ $(rowsj) == "[]" ]] || fail "C8: is_not appdb kept rows: $(rowsj)"
ok "C8: by database on A: 'appdb' 60 a full hour; filtered is_not appdb: no row"

for bad in '{"metric":"database.cache_hit_pct","aggregate":"sum","shape":"over_time"}|ratio' \
           '{"metric":"sessions.total","aggregate":"sum","shape":"over_time","group_by":"tag","tag_key":"env"}|counts in both' \
           '{"metric":"nope.nothing","aggregate":"avg","shape":"over_time"}|no metric' \
           '{"metric":"sessions.total","aggregate":"avg","shape":"top_over_time","group_by":"instance","top":9}|at most 8' \
           '{"metric":"sessions.total","aggregate":"avg","shape":"over_time","window":"2d"}|window'; do
  c=$(run "${bad%|*}"); expect "$c" 400 "R1 ${bad%|*}"
  [[ $(python3 -c "import json; print(json.load(open('$WORK/out.json')).get('error', ''))") == *"${bad#*|}"* ]] || fail "R1: the words for ${bad%|*}: $(head -c 300 "$WORK/out.json")"
done
ok "R1: a ratio summed, a sum by tag, an unknown metric, a top of 9 over time, a 2d window: each refused 400 in words"
F200=$(q "select to_char((to_timestamp($NOW) - interval '200 days') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
c=$(run '{"metric":"sessions.total","aggregate":"avg","shape":"single"}' '{}' "$F200"); expect "$c" 200 "R2"
python3 -c "
import json,datetime; d=json.load(open('$WORK/out.json')); f=datetime.datetime.fromisoformat(d['from'].replace('Z','+00:00')); t=datetime.datetime.fromisoformat(d['to'].replace('Z','+00:00'))
import sys; sys.exit(0 if d['cut'] and 'at most' in d['cut'] and (t-f).total_seconds() == 90*86400 and d.get('instances') == 2 else 1)" || fail "R2: $(head -c 300 "$WORK/out.json")"
ok "R2: a 200-day window cut and said: $(python3 -c "import json; print(json.load(open('$WORK/out.json'))['cut'])")"
for n in 13 12; do
  python3 -c "import json; print(json.dumps({'kind':'dashboard','name':'d$n','state':{'panels':[{'kind':'composed','panel':{'metric':'sessions.total'}}]*$n}}))" > "$WORK/dash.json"
  c=$(curl -s -o "$WORK/out.json" -w '%{http_code}' -b "$J" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/dash.json" "$U/api/views")
  if [[ $n == 13 ]]; then expect "$c" 400 "R3 13 panels"; [[ $(cat "$WORK/out.json") == *"at most 12 panels"* ]] || fail "R3: the words"; else expect "$c" 200 "R3 12 panels"; fi
done
ok "R3: a dashboard of 13 panels refused in words, 12 saved"
c=$(run '{"metric":"database.deadlocks","aggregate":"sum","shape":"over_time","bucket":"hour","group_by":"database"}'); expect "$c" 400 "R4"
[[ $(cat "$WORK/out.json") == *"one instance"* ]] || fail "R4: the words: $(cat "$WORK/out.json")"
c=$(run '{"metric":"sessions.total","aggregate":"sum","shape":"over_time","bucket":"minute"}'); expect "$c" 400 "R5"
ok "R4: a panel by database at fleet scope refused (same-named databases are different databases); R5: a minute bucket across instances refused"
echo "PASS: proof-compose"
