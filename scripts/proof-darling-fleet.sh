#!/usr/bin/env bash
# proof-darling-fleet (task 177 D29): Darling's PerformanceMonitor's Fleet Overview and server page header on pgvigil -
# the Summary's live columns and counts, the instance header, the daily health calendar, the findings' occurrences -
# each figure equal to a hand read of the same rows. Two scratch instances carry figures the demo's generators never
# touch: fx-pm-ms (SQL Server: a CPU read of 96 % - SQL 60 / other 36 -, 2 requests waiting for a worker, 3 memory
# grants pending, 6 blocked process reports in the hour with a longest wait of 75 s, 3 deadlocks, five collections -
# two healthy, one failing, one not collected, one without permission -, silenced, a finding sent in two episodes, and
# three past UTC days: 40 reads at 80 % or more, 8 such reads, none) and fx-pm-off (PostgreSQL, collected two hours
# ago: offline). Needs PGVIGIL_ADMIN_DSN (a superuser DSN of a scratch server, no dbname), chromium, node, psql, curl,
# python3, go.
#
# Expected (written before the first run, task 177 D29):
#   A  GET /api/ack?part=live: fx-pm-ms cpu_pct 96, cpu_sql 60, cpu_other 36; max_workers 512, current_workers 100,
#      work_queue 2; total_kb 8388608, buffer_pool_kb 4194304, grants_pending 3; blocking 6, longest_wait_s 75.0,
#      deadlocks 3, blocking_read and deadlocks_read true; coll healthy 2 / failing 1 / not collected 1 / no permission
#      1 / stale 0; silence_id the seeded silence. fx-pm-off: last_collect_at two hours back (offline). Every active
#      instance: its collections summed over the instances equal GET /api/frame/status's fleet counts (healthy,
#      failing, stale, not collected, no permission), and its blocking equal to a hand count of the same hour.
#   A2 the demo's Serverless v2 instance (demo-aurora-reporting01) on GET /api/ack?part=live&instance=: acu_pct and
#      max_acu equal a hand read (the newest ACUUtilization of serverless_sample in the 20 minutes up to live_at, rounded
#      to 0.1; serverless_scaling.max_acu, 8 in the demo), serverless true; erp01 (not serverless) null|null, false; two
#      scratch Serverless v2 instances written through import_serverless: fx-acu0 (paused: ACUUtilization 0 five
#      minutes back, max 4) 0.0|4.0, true; fx-acu-old (its only ACU read 25 minutes back) null|null, true.
#   B  GET /api/healthcal?instance=fx-pm-ms&month=<each seeded day's month>: the three days' high_cpu 40 / 8 / 0 and
#      errors 0 / 1 / 0 (an error and a skip logged through log_collection, as the collectors log them) with has_data
#      true (their CPU reads); the fourth day back has_data false; a hand count equals each.
#   C  GET /api/ack?part=seen&instance=fx-pm-ms: the seeded finding with occurrences 2, first_seen the first episode.
#   U  (headless Chromium) the Summary at the root: the counts line names the offline instances (a hand count of active
#      instances with no healthy collection for 30 minutes) and 'N blocking (recent)' (the live part's blocking summed
#      over every instance - each a hand count in A -, read just before or after the page);
#      fx-pm-ms's row: Total CPU '96%' critical, Threads '2 starved' critical, Memory '3 waiters' critical, Blocking '6'
#      critical (its title 'max wait 1.3 min'), Collectors '1 failing' warning (1 of 5 is not over 20 %), Measured '6 of
#      6', Alerts the bell ('Alerts silenced') and 'Unsilence', its tree node the bell too; fx-pm-off's row: Collection 'Offline · last collected
#      2h ago', Collectors 'Stale'. #/summary?i=fx-pm-ms: the header (its band word, the breadcrumb's dot, six chips with
#      the row's values, 'Total CPU' detail 'SQL 60% · other 36%') and the calendar: the three days Critical / Warning /
#      Healthy (a skip is no error), the fourth 'no data', a click on the first opens 'Why this day is Critical:' with '40 high-CPU samples';
#      Show as table lists the collected days. #/summary?i=fx-pm-off: every chip but Collectors 'n/a' with 'last
#      collected 2h ago'. #/summary?i=<the serverless instance>: the CPU chip's detail 'ACU <A2's figure>% of 8
#      configured', its band from ACU (80 / 95), its value the CPU figure of the same read; fx-acu0's 'ACU 0% of 4
#      configured' ok; fx-acu-old's 'no ACU read in the last 20 minutes' unknown (the chip's grey edge). #/performance?i=<the demo's sql01>: a 'Buffer pool (MB)' chart.
#      With the page's own reads held in the browser (CDP Fetch): sql01's buffer pool read (/api/mssql/memory) 1.5 s, and
#      on sql01 and erp01 the header's live read (/api/ack ... part=live) until the check releases it - every chart of
#      the Performance page drawn and the header absent while it is held, the header present after (a chart made
#      before a page is placed draws once it is; a slow header read holds no page up).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_darling_$RANDOM"; PORT=""; CDP=""; SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl python3 go ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || fail "no free port pair"; CDP=$((PORT + 1))

echo "== build, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up"; }
U="http://127.0.0.1:$PORT"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
j() { curl -fsS "$U/api/$1"; }
SQL1=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
[[ -n "$SQL1" ]] || fail "the demo's sql01 is missing"

echo "== F the fixture"
q "insert into pgvigil.instances (name, platform, engine) values ('fx-pm-ms', 'onprem', 'sqlserver'), ('fx-pm-off', 'onprem', 'postgres')" >/dev/null
MS=$(q "select instance_id from pgvigil.instances where name = 'fx-pm-ms'"); OFF=$(q "select instance_id from pgvigil.instances where name = 'fx-pm-off'")
q "insert into pgvigil.collection_dates (instance_id, collection, snapshot_at, duration_ms, status, note) values
   ($MS, 'mssql_xe', now(), 10, 'ok', null), ($MS, 'mssql_fx1', now(), 10, 'ok', null),
   ($MS, 'mssql_fx2', now(), 10, 'error', 'boom'), ($MS, 'mssql_fx3', now(), 10, 'skipped', 'not on this edition'),
   ($MS, 'mssql_fx4', now(), 10, 'error', 'The user does not have permission to perform this action: VIEW SERVER STATE'),
   ($OFF, 'activity', now() - interval '2 hours', 10, 'ok', null), ($OFF, 'dbstats', now() - interval '2 hours', 10, 'ok', null)" >/dev/null
q "insert into pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct) values ($MS, now() - interval '1 minute', 1, 60, 36, 4);
   insert into pgvigil.mssql_sched_sample (instance_id, snapshot_at, schedulers, cpu_count, runnable_tasks, work_queue, pending_io, current_workers, active_workers, max_workers)
     values ($MS, now() - interval '1 minute', 8, 8, 3, 2, 0, 100, 60, 512);
   insert into pgvigil.mssql_memory_sample (instance_id, snapshot_at, total_kb, target_kb, buffer_pool_kb, grants_pending, process_low)
     values ($MS, now() - interval '1 minute', 8388608, 8388608, 4194304, 3, false);
   insert into pgvigil.host_sample (instance_id, snapshot_at, source, cpu_pct, mem_total, mem_used) values ($OFF, now() - interval '2 hours', 'system_stats', 12, 8589934592, 4294967296)" >/dev/null
q "insert into pgvigil.mssql_blocked_reports (instance_id, event_at, snapshot_at, event_key, wait_ms, blocked_spid)
   select $MS, now() - make_interval(mins => 5 * g), now(), 'fx' || g, case g when 1 then 75000 else 2000 end, 50 + g from generate_series(1, 6) g;
   insert into pgvigil.mssql_deadlocks (instance_id, event_at, snapshot_at, event_key, source)
   select $MS, now() - make_interval(mins => 7 * g), now(), 'fx' || g, 'product' from generate_series(1, 3) g" >/dev/null 2>"$WORK/f.err" || { cat "$WORK/f.err"; fail "F: the blocking or deadlock rows"; }
[[ $(q "select pgvigil.import_ack(now(), '{\"op\":\"add\",\"kind\":\"silence\",\"instance_id\":$MS,\"instance_name\":\"fx-pm-ms\",\"ui_user\":\"proof\"}'::jsonb)->>'outcome'") == done ]] || fail "F: the silence"
SIL=$(q "select ack_id from pgvigil.acks where kind = 'silence' and instance_id = $MS and ended_at is null")
# the finding sent in two episodes, 9 and 6 days back (alert_state: one row per channel, finding and first send),
# before the calendar's seeded days (an alert makes a day Warning)
q "insert into pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity, first_sent_at, last_sent_at, send_count, cleared_at)
   values ('fx', pgvigil.alert_finding_key($MS, 'mssql_checks', 'last good CHECKDB', 'fxdb'), $MS, 'fx-pm-ms', 'mssql_checks', 'last good CHECKDB', 'fxdb', 'warning', now() - interval '9 days', now() - interval '8 days', 4, now() - interval '8 days'),
          ('fx', pgvigil.alert_finding_key($MS, 'mssql_checks', 'last good CHECKDB', 'fxdb'), $MS, 'fx-pm-ms', 'mssql_checks', 'last good CHECKDB', 'fxdb', 'warning', now() - interval '6 days', now() - interval '5 days', 2, now() - interval '5 days')" >/dev/null
# three past UTC days, each with CPU reads (a day with data): 40 at 85 % on the first (Critical: 30 for a whole day), 8
# on the second (Warning: 6) with a failed collection run, none on the third (Healthy) with a skipped one - logged
# through log_collection, the collectors' own writer (it keeps the runs that did not end well only)
D1=$(q "select (now() at time zone 'UTC')::date - 1"); D2=$(q "select (now() at time zone 'UTC')::date - 2"); D3=$(q "select (now() at time zone 'UTC')::date - 3"); D4=$(q "select (now() at time zone 'UTC')::date - 4")
q "select pgvigil.log_collection($MS, 'mssql_fx2', ('$D2'::date + interval '3 hours') at time zone 'UTC', 10, 'error', 'boom');
   select pgvigil.log_collection($MS, 'mssql_fx3', ('$D3'::date + interval '3 hours') at time zone 'UTC', 10, 'skipped', 'not on this edition')" >/dev/null
q "insert into pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
   select $MS, ('$D1'::date + make_interval(mins => 10 * g)) at time zone 'UTC', 100 + g, 70, 15, 15 from generate_series(1, 40) g
   union all select $MS, ('$D2'::date + make_interval(mins => 10 * g)) at time zone 'UTC', 200 + g, 70, 15, 15 from generate_series(1, 8) g
   union all select $MS, ('$D3'::date + make_interval(mins => 10 * g)) at time zone 'UTC', 300 + g, 10, 5, 85 from generate_series(1, 5) g" >/dev/null
# two Serverless v2 instances through the serverless collection's own writer: paused (ACU 0) and one whose only ACU
# read is older than the 20-minute window
q "insert into pgvigil.instances (name, platform, engine) values ('fx-acu0', 'aurora', 'postgres'), ('fx-acu-old', 'aurora', 'postgres')" >/dev/null
ACU0=$(q "select instance_id from pgvigil.instances where name = 'fx-acu0'"); ACUOLD=$(q "select instance_id from pgvigil.instances where name = 'fx-acu-old'")
q "select pgvigil.import_serverless($ACU0, now(), jsonb_build_array(
     jsonb_build_object('kind', 'metric', 'dim', 'fx-acu0', 'metric', 'ACUUtilization', 'stat', 'Average', 'unit', 'percent', 'at', date_trunc('minute', now()) - interval '5 minutes', 'value', 0),
     jsonb_build_object('kind', 'metric', 'dim', 'fx-acu0', 'metric', 'ServerlessDatabaseCapacity', 'stat', 'Maximum', 'unit', 'ACU', 'at', date_trunc('minute', now()) - interval '5 minutes', 'value', 0),
     jsonb_build_object('kind', 'scaling', 'db_instance', 'fx-acu0', 'cluster', 'fx-cluster', 'class', 'db.serverless', 'min_acu', 0, 'max_acu', 4)));
   select pgvigil.import_serverless($ACUOLD, now(), jsonb_build_array(
     jsonb_build_object('kind', 'metric', 'dim', 'fx-acu-old', 'metric', 'ACUUtilization', 'stat', 'Average', 'unit', 'percent', 'at', date_trunc('minute', now()) - interval '25 minutes', 'value', 50),
     jsonb_build_object('kind', 'scaling', 'db_instance', 'fx-acu-old', 'cluster', 'fx-cluster', 'class', 'db.serverless', 'min_acu', 0.5, 'max_acu', 4)))" >/dev/null
ok "F: fx-pm-ms ($MS) and fx-pm-off ($OFF); days $D1 / $D2 / $D3 seeded, $D4 not; fx-acu0 ($ACU0) and fx-acu-old ($ACUOLD)"

echo "== A the live part"
j "ack?part=live" > "$WORK/live.json"
j "frame/status" > "$WORK/frame.json"
HAND_BLOCK=$(q "select string_agg(i.instance_id || ':' || coalesce(case when i.engine = 'postgres' then
    (select count(distinct (a.pid, a.backend_start, a.query_start)) from pgvigil.activity_sample a where a.instance_id = i.instance_id and a.wait_event_type = 'Lock' and a.snapshot_at > x.at - interval '1 hour' and a.snapshot_at <= x.at)
  else (select count(*) from pgvigil.mssql_blocked_reports b where b.instance_id = i.instance_id and b.event_at > x.at - interval '1 hour' and b.event_at <= x.at) end, 0), ',' order by i.instance_id)
  from pgvigil.instances i cross join (select '$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); t=d['live']; print(t['rows'][0][t['columns'].index('live_at')])" "$WORK/live.json")'::timestamptz as at) x where i.is_active")
python3 - "$WORK/live.json" "$WORK/frame.json" "$MS" "$OFF" "$SIL" "$HAND_BLOCK" <<'PY' || fail "A (above)"
import json, sys, datetime
live, frame = json.load(open(sys.argv[1]))['live'], json.load(open(sys.argv[2]))
ms, off, sil, hand = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
rows = [dict(zip(live['columns'], r)) for r in live['rows']]
by = {r['instance_id']: r for r in rows}
bad = []
def want(r, k, v):
    got = r.get(k)
    if isinstance(v, float): good = got is not None and abs(float(got) - v) < 0.01
    else: good = got == v
    if not good: bad.append(f"{r['instance']} {k}: got {got!r}, want {v!r}")
m = by[ms]
for k, v in dict(cpu_pct=96.0, cpu_sql=60.0, cpu_other=36.0, max_workers=512, current_workers=100, work_queue=2, total_kb=8388608,
                 buffer_pool_kb=4194304, grants_pending=3, blocking=6, longest_wait_s=75.0, deadlocks=3, blocking_read=True, deadlocks_read=True,
                 coll_healthy=2, coll_failing=1, coll_not_collected=1, coll_no_permission=1, coll_stale=0, silence_id=sil).items():
    want(m, k, v)
o = by[off]
age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(str(o['last_collect_at']).replace('Z', '+00:00'))
if not (datetime.timedelta(minutes=110) < age < datetime.timedelta(minutes=130)): bad.append(f"fx-pm-off last_collect_at {o['last_collect_at']} ({age} back), want two hours")
f = dict(zip(frame['columns'], frame['rows'][0]))
for k in ('healthy', 'failing', 'stale', 'not_collected', 'no_permission'):
    s = sum(int(r['coll_' + k]) for r in rows)
    if s != int(f[k]): bad.append(f"the collections '{k}': {s} summed over the instances, the footer says {f[k]}")
hb = dict(x.split(':') for x in hand.split(','))
for r in rows:
    if str(r['instance_id']) in hb and int(r['blocking'] or 0) != int(hb[str(r['instance_id'])]): bad.append(f"{r['instance']} blocking {r['blocking']}, a hand count {hb[str(r['instance_id'])]}")
print('\n'.join(bad) if bad else f"A: fx-pm-ms's figures as seeded, fx-pm-off two hours back, {len(rows)} instances' collections = the footer's {dict((k, f[k]) for k in ('healthy','failing','stale','not_collected','no_permission'))}, blocking = a hand count on each")
sys.exit(1 if bad else 0)
PY
ok "A"

echo "== A2 the serverless CPU chip's ACU"
SLS=$(q "select instance_id from pgvigil.instances where name = 'demo-aurora-reporting01'")
ERP=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'")
[[ -n "$SLS" && -n "$ERP" ]] || fail "A2: the demo's aurora-reporting01 or erp01 is missing"
j "ack?part=live&instance=$SLS" > "$WORK/sls.json"; j "ack?part=live&instance=$ERP" > "$WORK/erp.json"
j "ack?part=live&instance=$ACU0" > "$WORK/acu0.json"; j "ack?part=live&instance=$ACUOLD" > "$WORK/acuold.json"
get() { python3 -c "import json,sys; t=json.load(open(sys.argv[1]))['live']; r=dict(zip(t['columns'],t['rows'][0])); print('|'.join('null' if r[k] is None else (str(r[k]).lower() if k in ('live_at', 'serverless') else ('%.1f' % float(r[k]))) for k in sys.argv[2:]))" "$@"; }
SLSAT=$(get "$WORK/sls.json" live_at); GOTACU=$(get "$WORK/sls.json" acu_pct max_acu); GOTERP=$(get "$WORK/erp.json" acu_pct max_acu serverless)
GOTSLS=$(get "$WORK/sls.json" serverless); GOT0=$(get "$WORK/acu0.json" acu_pct max_acu serverless); GOTOLD=$(get "$WORK/acuold.json" acu_pct max_acu serverless)
HANDACU=$(q "select coalesce((select to_char(round(s.value::numeric, 1), 'FM9990.0') from pgvigil.serverless_sample s where s.instance_id = $SLS and s.metric = 'ACUUtilization' and s.value is not null
    and s.snapshot_at > '$SLSAT'::timestamptz - interval '20 minutes' and s.snapshot_at <= '$SLSAT'::timestamptz order by s.snapshot_at desc limit 1), 'null')
  || '|' || coalesce((select to_char(max_acu::numeric, 'FM9990.0') from pgvigil.serverless_scaling where instance_id = $SLS), 'null')")
[[ $GOTACU == "$HANDACU" && $GOTACU != null* && $GOTSLS == true && $GOTERP == "null|null|false" ]] || fail "A2: aurora-reporting01 got $GOTACU ($GOTSLS), a hand read $HANDACU; erp01 got $GOTERP (want null|null|false)"
[[ $GOT0 == "0.0|4.0|true" && $GOTOLD == "null|null|true" ]] || fail "A2: fx-acu0 got $GOT0 (want 0.0|4.0|true), fx-acu-old got $GOTOLD (want null|null|true)"
ok "A2: aurora-reporting01 acu_pct|max_acu $GOTACU = a hand read, serverless; erp01 null|null, not serverless; fx-acu0 $GOT0; fx-acu-old $GOTOLD"

echo "== B the calendar"
for x in "$D1:40:0" "$D2:8:1" "$D3:0:0" "$D4:-:-"; do
  d=${x%%:*}; rest=${x#*:}; want=${rest%%:*}; werr=${rest#*:}; M=${d:0:7}
  j "healthcal?instance=$MS&month=$M" > "$WORK/cal.json"
  got=$(python3 -c "import json,sys; t=json.load(open(sys.argv[1]))['days']; r=[dict(zip(t['columns'],x)) for x in t['rows'] if str(x[t['columns'].index('day')])[:10]==sys.argv[2]]; print('none' if not r else ('%s|%s|%s' % (r[0]['has_data'], r[0]['high_cpu'], r[0]['errors'])))" "$WORK/cal.json" "$d")
  hand=$(q "select count(*) filter (where case when idle_pct is null then sql_pct else 100 - idle_pct end >= 80) from pgvigil.mssql_cpu_sample where instance_id = $MS and snapshot_at >= '$d'::date at time zone 'UTC' and snapshot_at < ('$d'::date + 1) at time zone 'UTC'")
  if [[ $want == - ]]; then [[ $got == False\|* ]] || fail "B: $d should have no data: $got"
  else herr=$(q "select count(*) from pgvigil.collection_log where instance_id = $MS and status = 'error' and snapshot_at >= '$d'::date at time zone 'UTC' and snapshot_at < ('$d'::date + 1) at time zone 'UTC'")
       [[ $got == "True|$want|$werr" && $hand == "$want" && $herr == "$werr" ]] || fail "B: $d: got $got, want True|$want|$werr, hand counts $hand / $herr"; fi
done
ok "B: $D1 40 hot reads, $D2 8 and 1 error, $D3 0 (a skip, no error), $D4 no data; hand counts equal"

echo "== C the findings' occurrences"
SEEN=$(j "ack?part=seen&instance=$MS" | python3 -c "
import json, sys, datetime
t = json.load(sys.stdin)['seen']; r = [dict(zip(t['columns'], x)) for x in t['rows'] if x[t['columns'].index('value')] == 'fxdb']
print(r[0]['occurrences'], datetime.datetime.fromisoformat(str(r[0]['first_seen']).replace('Z', '+00:00')).astimezone(datetime.timezone.utc).date()) if r else print('none')")
# a hand read: the episodes of each channel, the most of any; the first send in UTC
HANDSEEN=$(q "select max(n) || ' ' || to_char(min(f) at time zone 'UTC', 'YYYY-MM-DD') from (select channel, count(*) n, min(first_sent_at) f from pgvigil.alert_state where instance_id = $MS and value = 'fxdb' group by channel) c")
[[ $(curl -s -o /dev/null -w '%{http_code}' "$U/api/ack?part=seen") == 400 ]] || fail "C: part seen without instance= is not refused"

[[ "$SEEN" == "$HANDSEEN" && "${SEEN%% *}" == 2 ]] || fail "C: the finding's occurrences: $SEEN, a hand read $HANDSEEN"
ok "C: occurrences and first seen $SEEN (= a hand read)"

echo "== U the pages (headless Chromium on CDP $CDP)"
OFFN=$(q "select count(*) from pgvigil.instances i where i.is_active and exists (select 1 from pgvigil.collection_dates c where c.instance_id = i.instance_id and c.status = 'ok')
          and (select max(c.snapshot_at) from pgvigil.collection_dates c where c.instance_id = i.instance_id and c.status = 'ok') < now() - interval '30 minutes'")
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --window-size=1600,1000 about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
cat > "$WORK/u.mjs" <<'JS'
const [port, U, ms, off, sql1, offN, d1, d2, d3, d4, sls, acu0, acuOld, erp] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let n = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++n; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const bad = [];
const go = async (hash, ready) => {
  await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + '/' + hash });
  for (let i = 0; i < 120; i++) { if (await ev(ready)) return true; await sleep(250); }
  bad.push(`${hash}: not drawn (${ready})`); return false;
};
const check = (what, good, got) => { if (!good) bad.push(`${what}: ${got}`); else console.log(`ok   U ${what}: ${got}`); };
// the Summary at the root; 'N blocking (recent)' = the live part's blocking summed over every instance, read just
// before or just after the page (the demo keeps collecting)
const blockSum = async () => { const t = (await (await fetch(`${U}/api/ack?part=live`)).json()).live; const k = t.columns.indexOf('blocking');
  return t.rows.reduce((a, r) => a + Number(r[k] ?? 0), 0); };
const b1 = await blockSum();
if (await go('#/summary', `!!document.querySelector('main .summary-instances table.grid')`)) {
  const counts = await ev(`document.querySelector('main .counts')?.textContent ?? ''`);
  const b2 = await blockSum();
  const shown = Number((counts.match(/(\d+) blocking \(recent\)/) ?? [])[1]);
  check('the counts line', new RegExp(`(^|\\D)${offN} offline`).test(counts) && (shown === b1 || shown === b2), `${counts} (blocking summed over the live part: ${b1} before, ${b2} after)`);
  const row = name => ev(`(() => { const tr = [...document.querySelectorAll('main .summary-instances tbody tr')].find(t => t.querySelector('td')?.textContent.trim() === ${JSON.stringify(name)});
    if (!tr) return null; const ths = [...tr.closest('table').querySelectorAll('thead th')].map(t => t.textContent.replace(/[▾▴]/g, '').trim());
    return Object.fromEntries([...tr.children].map((td, i) => [ths[i], { text: td.querySelector('[data-text]')?.getAttribute('data-text') ?? td.textContent.trim(), cls: td.className, title: td.querySelector('[title]')?.getAttribute('title') ?? '', html: td.innerHTML.slice(0, 300), all: td.textContent.trim() }])); })()`);
  const m = await row('fx-pm-ms');
  if (!m) bad.push('fx-pm-ms has no row'); else {
    const cell = (k, text, cls) => check(`fx-pm-ms ${k}`, m[k] && m[k].text === text && m[k].cls.includes(cls), m[k] ? `${m[k].text} (${m[k].cls})` : 'no column');
    cell('Total CPU', '96%', 'crit'); cell('Threads', '2 starved', 'crit'); cell('Memory', '3 waiters', 'crit'); cell('Blocking', '6', 'crit'); cell('Collectors', '1 failing', 'warn');
    check('fx-pm-ms Blocking title', m.Blocking?.title === 'max wait 1.3 min', m.Blocking?.title);
    check('fx-pm-ms Measured', m.Measured?.text === '6 of 6', m.Measured?.text);
    check('fx-pm-ms Alerts', /Alerts silenced/.test(m.Alerts?.html ?? '') && m.Alerts.all.includes('Unsilence'), m.Alerts?.all);
  }
  const o = await row('fx-pm-off');
  check('fx-pm-off Collection', !!o && /^Offline · last collected 2h ago$/.test(o.Collection?.all ?? ''), o?.Collection?.all);
  check('fx-pm-off Collectors', !!o && o.Collectors?.text === 'Stale', o?.Collectors?.text);
}
// the tree: fx-pm-ms's node carries the silenced mark, fx-pm-off's none
{
  // the tree's search narrows it to the fixture's instances (their folder may be closed)
  await ev(`(() => { const i = document.querySelector('#tree input[type=search], #tree input[type=text], aside input'); if (!i) return false; i.value = 'fx-pm'; i.dispatchEvent(new Event('input', { bubbles: true })); return true; })()`);
  for (let i = 0; i < 20 && !(await ev(`!![...document.querySelectorAll('.tree-inst a.inst')].find(a => a.textContent.includes('fx-pm-ms'))?.querySelector('.silenced-bell')`)); i++) await sleep(250);
  const t = await ev(`(() => { const a = n => [...document.querySelectorAll('.tree-inst a.inst')].find(x => x.textContent.includes(n)); return [!!a('fx-pm-ms')?.querySelector('.silenced-bell'), !!a('fx-pm-off')?.querySelector('.silenced-bell'), !!a('fx-pm-ms')]; })()`);
  check("the tree's silenced mark", t[0] && !t[1], `fx-pm-ms ${t[0]}, fx-pm-off ${t[1]} (node found ${t[2]})`);
}
// the instance header and the calendar of fx-pm-ms
if (await go(`#/summary?i=${ms}`, `!!document.querySelector('main .inst-header') && !!document.querySelector('main .healthcal-grid')`)) {
  const h = await ev(`(() => { const s = document.querySelector('main .inst-header'); return { word: s.querySelector('.band-word')?.textContent, crumbDot: !!document.querySelector('#crumb .band-dot'),
    chips: [...s.querySelectorAll('.chip')].map(c => [c.querySelector('.chip-label')?.firstChild?.textContent, c.querySelector('.chip-value')?.textContent, c.querySelector('.chip-detail')?.textContent ?? '', c.className]) }; })()`);
  check('fx-pm-ms header', ['OK', 'Warning', 'Critical'].includes(h.word) && h.crumbDot && h.chips.length === 6, `${h.word}, the breadcrumb's dot ${h.crumbDot}, ${h.chips.length} chips`);
  const chip = Object.fromEntries(h.chips.map(c => [c[0], c]));
  check('fx-pm-ms header chips', chip['Total CPU']?.[1] === '96%' && chip['Total CPU']?.[2] === 'SQL 60% · other 36%' && chip.Threads?.[1] === '2 starved' && chip.Memory?.[1] === '3 waiters' && chip.Blocking?.[1] === '6' && chip.Collectors?.[1] === '1 failing',
    h.chips.map(c => `${c[0]} ${c[1]} (${c[2]})`).join('; '));
  const cal = await ev(`[...document.querySelectorAll('main .healthcal-cell')].map(b => b.getAttribute('aria-label'))`);
  const day = d => cal.find(x => x.includes(d)) ?? `${d}: no cell (another month)`;
  for (const [d, w] of [[d1, 'Critical'], [d2, 'Warning'], [d3, 'Healthy'], [d4, 'no data']]) {
    if (d.slice(0, 7) !== new Date().toISOString().slice(0, 7)) { console.log(`skip U calendar ${d}: in another month than the calendar opens on`); continue; }
    check(`calendar ${d}`, new RegExp(`^\\d+ ${w}, `).test(day(d)), day(d));
  }
  if (d1.slice(0, 7) === new Date().toISOString().slice(0, 7)) {
    const det = await ev(`(async () => { [...document.querySelectorAll('main .healthcal-cell')].find(b => b.getAttribute('aria-label').includes(${JSON.stringify(d1)}))?.click(); await new Promise(r => setTimeout(r, 300)); return document.querySelector('main .healthcal-day')?.textContent ?? ''; })()`);
    check('the day detail', det.includes('Why this day is Critical:') && det.includes('40 high-CPU samples'), det.slice(0, 200));
  }
  const tbl = await ev(`(async () => { [...document.querySelectorAll('main .healthcal-nav button')].find(b => b.textContent === 'Show as table')?.click();
    for (let i = 0; i < 40 && !document.querySelector('main .healthcal-body table.grid, main .healthcal-body p.empty'); i++) await new Promise(r => setTimeout(r, 100));
    return [...document.querySelectorAll('main .healthcal-body table.grid tbody tr')].map(r => r.firstElementChild.textContent.trim()); })()`);
  const inMonth = [d1, d2, d3].filter(d => d.slice(0, 7) === new Date().toISOString().slice(0, 7));
  if (!inMonth.length) console.log('skip U Show as table: no seeded day in this month');
  else check('Show as table', inMonth.every(d => tbl.includes(d)) && !tbl.includes(d4), tbl.join(', '));
}
// the offline instance's header
if (await go(`#/summary?i=${off}`, `!!document.querySelector('main .inst-header')`)) {
  const c = await ev(`[...document.querySelectorAll('main .inst-header .chip')].map(c => [c.querySelector('.chip-label')?.firstChild?.textContent, c.querySelector('.chip-value')?.textContent, c.querySelector('.chip-detail')?.textContent ?? ''])`);
  check('fx-pm-off header chips', c.length === 6 && c.filter(x => x[0] !== 'Collectors').every(x => x[1] === 'n/a' && x[2] === 'last collected 2h ago') && c.find(x => x[0] === 'Collectors')?.[1] === 'Stale', c.map(x => x.join(' ')).join('; '));
}
// the serverless instance's header: the CPU chip's detail and band from ACU (PerformanceMonitor's fleet.js #3281)
// (the API read just before and just after the page: a 5-minute datapoint may land in between; the chip's value is
// the CPU figure of the same read, never the ACU)
const liveNow = async (i) => { const t = (await (await fetch(`${U}/api/ack?part=live&instance=${i}`)).json()).live; const r = Object.fromEntries(t.columns.map((c, k) => [c, t.rows[0][k]]));
  return { acu: r.acu_pct == null ? null : Number(r.acu_pct), cpu: r.cpu_pct == null ? null : Number(r.cpu_pct) }; };
const cpuChip = () => ev(`(() => { const c = [...document.querySelectorAll('main .inst-header .chip')].find(x => x.querySelector('.chip-label')?.firstChild?.textContent === 'CPU');
  return c ? [c.querySelector('.chip-value')?.textContent ?? '', c.querySelector('.chip-detail')?.textContent ?? '', c.className] : null; })()`);
const bandOf = a => a >= 95 ? 'band-crit' : a >= 80 ? 'band-warn' : 'band-ok';
for (const [i, name, max] of [[sls, 'the serverless CPU chip', 8], [acu0, 'fx-acu0 (paused) CPU chip', 4]]) {
  const r1 = await liveNow(i);
  if (!(await go(`#/summary?i=${i}`, `!!document.querySelector('main .inst-header .chip')`))) continue;
  const c = await cpuChip(); const r2 = await liveNow(i);
  const wants = [r1, r2].filter(r => r.acu != null).map(r => [r.cpu == null ? 'n/a' : `${Math.round(r.cpu)}%`, `ACU ${Math.round(r.acu)}% of ${max} configured`, bandOf(r.acu)]);
  check(name, c && wants.some(([v, d, b]) => c[0] === v && c[1] === d && c[2].split(' ').includes(b)), `${c?.join(' | ')}, want one of ${wants.map(w => w.join(' ')).join(' / ')}`);
}
if (await go(`#/summary?i=${acuOld}`, `!!document.querySelector('main .inst-header .chip')`)) {
  const c = await cpuChip();
  check('fx-acu-old CPU chip', c && c[1] === 'no ACU read in the last 20 minutes' && c[2].split(' ').includes('band-none'), c?.join(' | '));
}
// the Performance page of a SQL Server instance: the buffer pool chart
if (await go(`#/performance?i=${sql1}`, `[...document.querySelectorAll('main .chart h3')].length > 3`)) {
  const t = await ev(`[...document.querySelectorAll('main .chart h3')].map(h => h.textContent)`);
  // a chart's heading also holds its menu buttons' glyphs: the title starts it
  check('Performance: Buffer pool (MB)', t.some(x => x.trim().startsWith('Buffer pool (MB)')), t.join(' | '));
}
// every chart drawn while the page's own reads are slow (CDP Fetch holds them): on sql01 the buffer pool read held
// 1.5 s, then released; on both the header's live read held until every chart is drawn - the header absent meanwhile -,
// then released and the header lands
const paused = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data);
  if (d.method === 'Fetch.requestPaused') paused.push({ id: d.params.requestId, url: d.params.request.url }); });
const release = async (re) => { for (const p of paused.filter(x => re.test(x.url) && !x.done)) { p.done = true; await cmd('Fetch.continueRequest', { requestId: p.id }); } };
const isMem = /\/api\/mssql\/memory/, isLive = /\/api\/ack\?.*part=live/;
await cmd('Fetch.enable', { patterns: [{ urlPattern: '*/api/mssql/memory*' }, { urlPattern: '*/api/ack*part=live*' }] });
const drawn = `(() => { const c = [...document.querySelectorAll('main .charts > .chart')]; return c.length > 3 && c.every(x => x.querySelector('.uplot, p.empty')); })()`;
const each = `[...document.querySelectorAll('main .charts > .chart')].map(x => (x.querySelector('h3')?.textContent ?? '').replace(/[⋯⤢]/g, '').trim().slice(0, 24) + (x.querySelector('.uplot') ? ' drawn' : x.querySelector('p.empty') ? ' empty' : ' BLANK'))`;
for (const [i, name, mem] of [[sql1, 'sql01', true], [erp, 'erp01', false]]) {
  paused.length = 0;
  await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: `${U}/#/performance?i=${i}` });
  for (let k = 0; k < 100 && !(paused.some(p => isLive.test(p.url)) && (!mem || paused.some(p => isMem.test(p.url)))); k++) await sleep(100);
  const held = `live ${paused.filter(p => isLive.test(p.url)).length}, memory ${paused.filter(p => isMem.test(p.url)).length}`;
  if (mem) { await sleep(1500); await release(isMem); }
  let ok0 = false;
  for (let k = 0; k < 60 && !(ok0 = await ev(drawn)); k++) await sleep(250);
  const noHeader = await ev(`!document.querySelector('main .inst-header')`);
  const charts = await ev(each);
  await release(isLive);
  let header = false;
  for (let k = 0; k < 50 && !(header = await ev(`!!document.querySelector('main .inst-header')`)); k++) await sleep(100);
  const heldOk = paused.some(p => isLive.test(p.url)) && (!mem || paused.some(p => isMem.test(p.url)));
  check(`${name} Performance: every chart drawn with its reads held`, heldOk && ok0 && noHeader && header,
    `held ${held}; while the header's read was held: header absent ${noHeader}, ${charts.join(' | ')}; after its release: header ${header}`);
}
await release(/./);
await cmd('Fetch.disable');
console.log(bad.length ? bad.map(b => 'FAIL ' + b).join('\n') : 'U: every page as expected');
ws.close();
process.exit(bad.length ? 1 : 0);
JS
node "$WORK/u.mjs" "$CDP" "$U" "$MS" "$OFF" "$SQL1" "$OFFN" "$D1" "$D2" "$D3" "$D4" "$SLS" "$ACU0" "$ACUOLD" "$ERP" || fail "U (above)"
echo "PROOF OK"
