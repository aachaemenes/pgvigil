#!/usr/bin/env bash
# Scale measurement for the sizing note: (A) the demo seeder at SCALE_N instances x SCALE_DAYS days into a
# scratch repository, then row counts, sizes and the UI's read times over it; (B) one collector process
# polling POLL_N instances on its real schedules for POLL_SECS, sampled every 5 s: RSS, CPU, socket bytes,
# its connections to the targets and to the repository, the repository's growth, collection outcomes.
#   PGVIGIL_ADMIN_DSN  a superuser connection without dbname (scratch databases, dropped at the end)
#   PGVIGIL_PGBIN      bin folder with initdb/pg_ctl: (B) polls a throwaway cluster started from it with
#                      max_connections 1500 and pg_stat_statements (the shared sandbox allows 100 connections)
#   SCALE_N 1000, SCALE_DAYS 7, SCALE_WORKERS 16, POLL_N 1000, POLL_SECS 360, PART=AB (A, B or AB)
#   RESULT_DIR         where results.txt and the samples go (default a temp folder, printed)
# One target cluster stands in for POLL_N servers: every instance entry names the same server, so the
# target-side load is the whole fleet's on one box (a real fleet spreads it); the collector side is real.
# Predictions (written before the first run; graded in the sizing note):
#   A  seed completes; rows ~ 59.7 M (716,385 per 12 instances x 1000/12, within 2 %); repository
#      ~ 33 GB (12 instances took about 400 MB of base: 20-45 GB); seed 15-40 min at 16 workers;
#      /api/overview under 15 s (serve's statement timeout) on the 1,000-instance repository;
#      /api/instances under 2 s; one instance's activity, statements (24 h) and counters (24 h) under 2 s
#   B  every instance's minute collections run every minute after the first 10 s jitter; collector RSS
#      under 500 MB; peak connections to the target under 300 (each run holds one connection for
#      ~50-150 ms, jitter spreads 6,000 a minute over 10 s); repository connections at most the pool
#      default (max(4, CPUs)); no collection error (neither in collection_log nor a 'collection failed'
#      line in the collector's log)
# Measures: the target's connection peak comes from its own connection log (log_connections, pid-paired),
# the 5 s samples only show the level; io bytes are the collector's read/write syscalls (sockets plus its
# own log), their rate over the steady rows (t >= 60 s); repository growth is pg_database_size (no WAL);
# API times are first call, warm, warm (the vacuum just before leaves the data in the OS cache)
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
N=${SCALE_N:-1000}; DAYS=${SCALE_DAYS:-7}; WORKERS=${SCALE_WORKERS:-16}; PN=${POLL_N:-1000}; PSECS=${POLL_SECS:-360}; PART=${PART:-AB}
OUT=${RESULT_DIR:-$(mktemp -d)}; mkdir -p "$OUT"; R="$OUT/results.txt"; : > "$R"
SDB="pgvigil_it_scale_$RANDOM"; PDB="pgvigil_it_poll_$RANDOM"; WORK=$(mktemp -d); CREATED=(); SPID=""; CPID=""
PGBIN=${PGVIGIL_PGBIN:-$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent/initdb)")}
cleanup() {
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null || true
  [[ -n "$CPID" ]] && kill -INT "$CPID" 2>/dev/null && wait "$CPID" 2>/dev/null || true
  [[ -f "$WORK/target/postmaster.pid" ]] && "$PGBIN/pg_ctl" -D "$WORK/target" -m fast -w stop >/dev/null 2>&1 || true
  for d in "${CREATED[@]}"; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
rec() { echo "$1=$2" | tee -a "$R"; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
rec machine "$(nproc) CPUs, $(free -g | awk '/Mem:/{print $2}') GB RAM, $(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtc 'select version()' | cut -d' ' -f1-2)"
rec sandbox_settings "$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtc "select string_agg(name||'='||setting||coalesce(unit,''), ' ' order by name) from pg_settings where name in ('shared_buffers','max_connections','max_wal_size','work_mem')")"

if [[ "$PART" == *A* ]]; then
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $SDB"; CREATED+=("$SDB")
  DSN="$PGVIGIL_ADMIN_DSN dbname=$SDB"
  P() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
  echo "A: seeding $N instances x $DAYS days with $WORKERS workers (cmd: $BIN demo -dsn <scratch> -instances $N -days $DAYS -workers $WORKERS -prefix scale-)"
  t0=$(date +%s)
  "$BIN" demo -dsn "$DSN" -instances "$N" -days "$DAYS" -workers "$WORKERS" -prefix scale- 2>"$OUT/seed.log" | tee "$OUT/seed.out" || { tail "$OUT/seed.log" >&2; fail seed; }
  rec seed_secs $(( $(date +%s) - t0 ))
  rec seed_line "$(cat "$OUT/seed.out")"
  P -c "vacuum analyze" >/dev/null
  rec repo_bytes "$(P -c "select pg_database_size(current_database())")"
  rec repo_pretty "$(P -c "select pg_size_pretty(pg_database_size(current_database()))")"
  # rows and bytes per table, partitions summed into their parent
  P -F '|' -c "select coalesce(pp.relname, c.relname) as t, sum(c.reltuples)::bigint, sum(pg_total_relation_size(c.oid))
                 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 left join pg_inherits i on i.inhrelid = c.oid left join pg_class pp on pp.oid = i.inhparent
                where n.nspname = 'pgvigil' and c.relkind = 'r' group by 1 order by 3 desc" > "$OUT/tables.txt"
  rec rows_total "$(awk -F'|' '{s+=$2} END {print s}' "$OUT/tables.txt")"
  echo "tables (name|rows|bytes):"; cat "$OUT/tables.txt"
  PORT=$(freeport)
  printf 'repository:\n  dsn: env:SCALE_DSN\n' > "$WORK/a.yaml"
  SCALE_DSN="$DSN" "$BIN" serve -config "$WORK/a.yaml" -no-login -listen "127.0.0.1:$PORT" 2>"$OUT/serve.log" & SPID=$!
  for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
  tm() { curl -fsS -o "$WORK/body" -w '%{time_total}' "http://127.0.0.1:$PORT/api/$1"; }
  ID=$(P -c "select instance_id from pgvigil.instances where name = 'scale-onprem-erp01'")
  FROM=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  for ep in overview instances "activity?instance=$ID" "statements?instance=$ID&from=$FROM" "counters?kind=db&instance=$ID&from=$FROM" "dms"; do
    times=""; for k in 1 2 3; do times="$times $(tm "$ep")"; done
    rows=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["rows"]) if "rows" in d else (len(d["tasks"]["rows"]) if "tasks" in d else len((d.get("sessions") or {}).get("rows", []))))' "$WORK/body")
    rec "api_${ep%%\?*}" "seconds(first,warm,warm)=${times# } rows=$rows"
  done
  grep -q '"check could not run"' <(curl -fsS "http://127.0.0.1:$PORT/api/overview") && rec overview_note "a check could not run (timeout)" || rec overview_note "every check ran"
  kill "$SPID"; wait "$SPID" 2>/dev/null || true; SPID=""
  [[ -n "${KEEP_SCALE_DB:-}" ]] && { rec kept_db "$SDB"; CREATED=("${CREATED[@]/$SDB}"); }
fi

if [[ "$PART" == *B* ]]; then
  [[ -x "$PGBIN/initdb" ]] || fail "no initdb in $PGBIN for the poll target (set PGVIGIL_PGBIN)"
  TP=$(freeport); mkdir -p "$WORK/sock"
  "$PGBIN/initdb" -D "$WORK/target" -U postgres -A trust -E UTF8 --no-locale >/dev/null
  "$PGBIN/pg_ctl" -D "$WORK/target" -l "$WORK/target.log" -w -o "-p $TP -k $WORK/sock -c listen_addresses=127.0.0.1 -c max_connections=1500 -c shared_buffers=256MB -c shared_preload_libraries=pg_stat_statements -c log_connections=on -c log_disconnections=on -c log_line_prefix='%m [%p] '" start >/dev/null
  psql "host=127.0.0.1 port=$TP user=postgres dbname=postgres" -XAtq -c "create extension pg_stat_statements"
  export SCALE_TARGET_DSN="host=127.0.0.1 port=$TP user=postgres dbname=postgres sslmode=disable"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $PDB"; CREATED+=("$PDB")
  export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$PDB"
  { printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n'
    for i in $(seq -w 1 "$PN"); do printf '  - name: poll-%s\n    dsn: env:SCALE_TARGET_DSN\n' "$i"; done; } > "$WORK/b.yaml"
  "$BIN" migrate -config "$WORK/b.yaml" >/dev/null 2>&1 || fail "migrate poll repo"
  Q() { psql "$PGVIGIL_REPO_DSN" -XAtq "$@"; }
  base_size=$(Q -c "select pg_database_size(current_database())")
  echo "B: one collector, $PN instances on one target, $PSECS s (cmd: $BIN run -config <$PN instances>)"
  "$BIN" run -config "$WORK/b.yaml" 2>"$OUT/collector.log" & CPID=$!
  echo "t_secs,rss_kb,threads,cpu_ticks,rchar,wchar,target_conns_5s,repo_conns" > "$OUT/samples.csv"
  t0=$(date +%s)
  while (( $(date +%s) - t0 < PSECS )); do
    kill -0 "$CPID" 2>/dev/null || fail "collector exited: $(tail -3 "$OUT/collector.log")"
    rss=$(awk '/VmRSS/{print $2}' /proc/$CPID/status); thr=$(awk '/Threads/{print $2}' /proc/$CPID/status)
    cpu=$(awk '{print $14+$15}' /proc/$CPID/stat); rch=$(awk '/rchar/{print $2}' /proc/$CPID/io); wch=$(awk '/wchar/{print $2}' /proc/$CPID/io)
    tc=$(psql "$SCALE_TARGET_DSN" -XAtq -c "select count(*) from pg_stat_activity where application_name = 'pgvigil'")
    rc=$(psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "select count(*) from pg_stat_activity where datname = '$PDB' and application_name = 'pgvigil-repo'")
    echo "$(( $(date +%s) - t0 )),$rss,$thr,$cpu,$rch,$wch,$tc,$rc" >> "$OUT/samples.csv"
    sleep 5
  done
  kill -INT "$CPID"; wait "$CPID" 2>/dev/null || true; CPID=""
  python3 - "$OUT/samples.csv" "$PSECS" "$PN" <<'PY' | tee -a "$R"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1]))); n = int(sys.argv[3])
f = lambda k: [int(r[k]) for r in rows]
steady = [r for r in rows if int(r["t_secs"]) >= 60] or rows
s = lambda k: [int(r[k]) for r in steady]
dt = int(rows[-1]["t_secs"]) - int(rows[0]["t_secs"]) or 1
mins = dt / 60
tick = 100  # USER_HZ
print(f"poll_rss_mb=max {max(f('rss_kb'))/1024:.0f}, steady median {sorted(s('rss_kb'))[len(steady)//2]/1024:.0f}")
print(f"poll_threads=max {max(f('threads'))}")
print(f"poll_cpu=avg {(f('cpu_ticks')[-1]-f('cpu_ticks')[0])/tick/dt:.2f} cores")
io = (f('rchar')[-1]-f('rchar')[0]) + (f('wchar')[-1]-f('wchar')[0])
st_dt = (int(steady[-1]["t_secs"]) - int(steady[0]["t_secs"])) or 1
st_io = (s('rchar')[-1]-s('rchar')[0]) + (s('wchar')[-1]-s('wchar')[0])
print(f"poll_io_syscall_bytes=total {io}, steady per instance-minute {st_io/n/(st_dt/60):.0f} (targets, repository and its own log)")
print(f"poll_target_conns_5s_sample=max {max(f('target_conns_5s'))}, steady median {sorted(s('target_conns_5s'))[len(steady)//2]} (point samples: the level, not the peak)")
print(f"poll_repo_conns=max {max(f('repo_conns'))}")
PY
  cp "$WORK/target.log" "$OUT/target.log"
  python3 - "$OUT/target.log" <<'PEAK' | tee -a "$R"
import re, sys
live, peak, n = set(), 0, 0
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"\S+ \S+ \S+ \[(\d+)\] LOG:  (connection authorized|disconnection)", line)
    if not m: continue
    if m.group(2) == "connection authorized": live.add(m.group(1)); n += 1; peak = max(peak, len(live))
    else: live.discard(m.group(1))
print(f"poll_target_conns_peak={peak} concurrent (from the target's connection log; {n} connections, the sampler's included)")
PEAK
  rec poll_failed_runs_in_log "$(grep -c 'msg="collection failed"' "$OUT/collector.log" || true)"
  { grep 'msg="collection failed"' "$OUT/collector.log" | grep -o 'err=.*' | cut -c1-160 | sort | uniq -c | sort -rn | head -5; } > "$OUT/failed-runs.txt" || true
  rec poll_repo_growth_bytes "$(( $(Q -c "select pg_database_size(current_database())") - base_size ))"
  Q -c "analyze" >/dev/null
  Q -F '|' -c "select coalesce(pp.relname, c.relname) as t, sum(c.reltuples)::bigint, sum(pg_total_relation_size(c.oid))
                 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 left join pg_inherits i on i.inhrelid = c.oid left join pg_class pp on pp.oid = i.inhparent
                where n.nspname = 'pgvigil' and c.relkind = 'r' group by 1 order by 3 desc limit 12" > "$OUT/poll-tables.txt"
  echo "poll repository tables (name|rows|bytes):"; cat "$OUT/poll-tables.txt"
  rec poll_statement_rows_per_instance_interval "$(Q -c "select coalesce(round(avg(n))::text, 'none (no delta yet: POLL_SECS under about 320)') from (select instance_id, snapshot_at, count(*) n from pgvigil.statements_delta group by 1, 2) x")"
  rec poll_minutes "$(python3 -c "print(round($PSECS/60,1))")"
  Q -F '|' -c "select collection, status, count(*), percentile_disc(0.5) within group (order by duration_ms), percentile_disc(0.95) within group (order by duration_ms), max(duration_ms)
                 from pgvigil.collection_dates group by 1, 2 order by 1, 2" > "$OUT/collections.txt"
  echo "collections (name|status|instances|p50 ms|p95 ms|max ms):"; cat "$OUT/collections.txt"
  rec poll_errors "$(Q -c "select count(*) from pgvigil.collection_log where status = 'error'")"
  Q -c "select left(note, 160), count(*) from pgvigil.collection_log where status = 'error' group by 1 order by 2 desc limit 5" > "$OUT/errors.txt"
  rec poll_activity_runs_per_instance_minute "$(Q -c "select round(count(*)::numeric / $PN / ($PSECS / 60.0), 2) from pgvigil.activity_summary")"
fi
echo "results: $R"
