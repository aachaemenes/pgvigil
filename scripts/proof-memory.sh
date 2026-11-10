#!/usr/bin/env bash
# Proof of memory and poolers (migration 0061, internal/collect/buffercache.go, tempfiles.go, pgbouncer.go, task 62) on
# the sandbox: a monitored database with pg_buffercache and pg_stat_statements read as a pg_monitor login, a second
# monitored database with neither and no pooler, and a PgBouncer container in front of the first.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox (pg_stat_statements preloaded); the proof makes its own
#                      repository database, two monitored databases, a pg_monitor login and an application role, all
#                      with a random suffix, and drops them at the end.
#   PGB_IMAGE          the PgBouncer image (default edoburu/pgbouncer:v1.24.1-p1); the container runs on the host
#                      network with the proof's own pgbouncer.ini and is killed by its own name at the end.
#
# Expected (written before the first run):
#  A. buffercache on the first instance (pg_buffercache created by the sandbox superuser in the monitored database,
#     read as the pg_monitor login): the total row 'ok' with total_buffers = shared_buffers in pages and used > 0;
#     the proof's table pgv_mem_hot (read whole just before) among the relations with buffers > 0 and its schema and
#     name resolved. On the second instance: 'not available', the reason starting 'pg_buffercache is not installed'.
#  B. temp spills: the sort once, a baseline statements read (a statement's delta starts at its second sighting), the
#     application role runs the sort again with work_mem 64kB over 3000000 rows (above the statements collection's top-500 cut on a shared sandbox)
#     (tagged pgv_spill), a second statements read, then temp_files: a 'statement' row for that queryid whose
#     temp_written_bytes > 0 and = its statements_delta temp_blks_written x block_size; the hour row carries the
#     instance's data size. Then a log event of kind temp_file whose size is 20 % of that data size (import_logs, the
#     log readers' row shape) and a statements_delta row of 200000 temp blocks written (1.5 GiB at 8 kB) for queryid
#     4242: after temp_files the hour row has log_files 1 and log_max_file_bytes = that size, and memory_findings for
#     the instance holds 'temp-file spills' twice: info (queryid 4242, over 1 GB in an hour) and warning (the hour
#     over 10 % of the data).
#     [review fold] A late import_temp_files (three hours back) leaves the hour rows from its own hour onward as they
#     were and adds the 3 older hours its window reaches.
#  C. the pooler: PgBouncer with pool_size 2 in session mode in front of the first database; four clients of the
#     application role each hold a session (pg_sleep), so two wait. After about 7 s, collect -once pgbouncer through
#     the stats_users login: pooler_state 'ok' with the version 'PgBouncer 1.24.1'; one pool row with cl_waiting 2,
#     sv_active 2, pool_size 2 and maxwait_ms >= 5000; a 'stats' row for the database; pooler_state.databases names
#     the pool with pool_size 2 and config holds max_client_conn. memory_findings: 'clients waiting on the pooler'
#     critical (maxwait over 5 s). The 5-minute rules need five minutes of reads: the real read's pool row is copied
#     to the five minutes before it (the same figures, earlier times), and then 'clients waiting on the pooler' warning
#     and 'a pool at its size' warning are there too. PAUSE through the same stats_users login is refused by PgBouncer
#     (psql exits non-zero, the error says admin access).
#  D. the second instance has no pgbouncer: DSN: collect -once pgbouncer for it says skipped and stores no
#     pooler_state row. A synthetic buffercache read for it (one relation at 60 % of 1000 buffers) gives 'one relation
#     holds over half of shared_buffers' info.
#  E. the API (the routes are the join's: a scratch build with the wiring block's two lines when this build has no
#     /api/memory): /api/memory for the first instance: buffer_state ok, pgv_mem_hot in buffer_rels, the spill's
#     queryid in temp_statements, at least one temp_hours row, findings 2 (the pooler's left to the Pooler tab);
#     /api/pooler: state ok, one pool with cl_waiting 2, findings 3; /api/pooler?part=state for the second instance: 0
#     rows (the shell shows no Pooler tab).
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
PGB_IMAGE=${PGB_IMAGE:-edoburu/pgbouncer:v1.24.1-p1}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_memproof_$SUF; MDB=pgvigil_memmon_db_$SUF; MDB2=pgvigil_memmon2_db_$SUF
MON=pgvigil_memmon_$SUF; MONPW=p$RANDOM$RANDOM; APP=pgvigil_memapp_$SUF; APPPW=p$RANDOM$RANDOM
STATSU=pgvigil_memstats_$SUF; STATSPW=p$RANDOM$RANDOM
PGBNAME=pgvigil-proof-pgb-$SUF; PGBPORT=$((30000 + RANDOM % 20000))
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; LOG=$WORK/serve.log; SCRATCH=$WORK/scratch; mkdir -p "$SCRATCH"
SRVPID=; CLIENTS=()
cleanup() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  for p in "${CLIENTS[@]}"; do kill "$p" 2>/dev/null || true; done
  docker kill "$PGBNAME" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $MDB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $MDB2 with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" -c "drop role if exists $APP" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" -c "create database $MDB" -c "create database $MDB2" \
  -c "create role $MON login password '$MONPW' in role pg_monitor" -c "create role $APP login password '$APPPW'" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "create extension pg_stat_statements" -c "create extension pg_buffercache" \
  -c "create table public.pgv_mem_hot as select g as id, repeat('x', 200) as pad from generate_series(1, 20000) g" \
  -c "grant select on public.pgv_mem_hot to $APP" -c "grant connect on database $MDB to $APP" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export SBX_DSN="$ADMIN_DSN dbname=$MDB user=$MON password=$MONPW"
export SBX2_DSN="$ADMIN_DSN dbname=$MDB2 user=$MON password=$MONPW"
export PGB_DSN="host=127.0.0.1 port=$PGBPORT dbname=pgbouncer user=$STATSU password=$STATSPW sslmode=disable"
APP_DSN="$ADMIN_DSN dbname=$MDB user=$APP password=$APPPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-mem-$SUF
    dsn: env:SBX_DSN
    pgbouncer: env:PGB_DSN
  - name: proof-mem2-$SUF
    dsn: env:SBX2_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -instance "$1" -once "$2" 2>&1 || fail "collect -once $2 on $1 failed"; }

echo "--- A. buffercache"
psql "$APP_DSN" -XAtq -c "select count(*) from public.pgv_mem_hot" >/dev/null
collect "proof-mem-$SUF" buffercache >/dev/null
collect "proof-mem2-$SUF" buffercache >/dev/null
I=$(q "select instance_id from pgvigil.instances where name = 'proof-mem-$SUF'")
I2=$(q "select instance_id from pgvigil.instances where name = 'proof-mem2-$SUF'")
SB=$(psql "$ADMIN_DSN dbname=$MDB" -XAt -c "select setting from pg_settings where name = 'shared_buffers'")
T=$(q "select status || '|' || total_buffers || '|' || (used_buffers > 0) from pgvigil.buffercache_sample where instance_id = $I and kind = 'total'")
echo "total: $T (shared_buffers $SB pages)"; [[ $T == "ok|$SB|true" ]] || fail "A: the total row"
H=$(q "select schemaname || '.' || relname || '|' || (buffers > 0) from pgvigil.buffercache_sample where instance_id = $I and kind = 'rel' and relname = 'pgv_mem_hot'")
echo "pgv_mem_hot: $H"; [[ $H == "public.pgv_mem_hot|true" ]] || fail "A: the proof's table among the relations"
T2=$(q "select status || '|' || reason from pgvigil.buffercache_sample where instance_id = $I2 and kind = 'total'")
echo "second instance: $T2"; [[ $T2 == "not available|pg_buffercache is not installed"* ]] || fail "A: the second instance's state"

echo "--- B. temp spills"
spill() { psql "$APP_DSN" -XAtq -c "set work_mem = '64kB'" \
  -c "select count(*) from (select g as pgv_spill from generate_series(1, 3000000) g order by g desc) x" >/dev/null; }
spill   # first sighting: the baseline read stores the statement, its delta starts at the next read
collect "proof-mem-$SUF" statements >/dev/null
spill
sleep 1
collect "proof-mem-$SUF" statements >/dev/null
collect "proof-mem-$SUF" temp_files >/dev/null
QID=$(q "select queryid from pgvigil.statement_text where instance_id = $I and query like '%pgv_spill%' and query not like '%statement_text%' limit 1")
[ -n "$QID" ] || fail "B: the spill's statement is not in statement_text"
S=$(q "select (t.temp_written_bytes > 0)::text || '|' || (t.temp_written_bytes = (select sum(d.temp_blks_written) * current_setting('block_size')::numeric
          from pgvigil.statements_delta d where d.instance_id = $I and d.queryid = $QID and date_trunc('hour', d.snapshot_at) = t.snapshot_at))::text
        from pgvigil.temp_sample t where t.instance_id = $I and t.source = 'statement' and t.queryid = $QID")
echo "spill $QID: $S"; [[ $S == "true|true" ]] || fail "B: the spill's temp row"
DATA=$(q "select data_bytes from pgvigil.temp_sample where instance_id = $I and source = 'hour' order by snapshot_at desc limit 1")
[[ $DATA =~ ^[0-9]+$ ]] && [ "$DATA" -gt 0 ] || fail "B: the hour row has no data size ($DATA)"
SIZE=$((DATA / 5))
DBID=$(psql "$ADMIN_DSN dbname=$MDB" -XAt -c "select oid from pg_database where datname = current_database()")
q "select pgvigil.import_logs($I, now(), '[{\"kind\":\"event\",\"kind_of\":\"temp_file\",\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"detail\":\"temporary file: path \\\"base/pgsql_tmp/pgsql_tmp99.0\\\", size $SIZE\",\"source\":\"proof\",\"event_key\":\"proof-temp-$SUF\"},{\"kind\":\"cursor\",\"source\":\"proof\",\"read_to\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]'::jsonb)" >/dev/null
q "insert into pgvigil.statements_delta (instance_id, snapshot_at, interval_secs, dbid, datname, userid, usename, queryid, toplevel, calls, temp_blks_read, temp_blks_written)
   values ($I, now() - interval '1 second', 60, $DBID, '$MDB', 10, '$APP', 4242, true, 1, 0, 200000)" >/dev/null
collect "proof-mem-$SUF" temp_files >/dev/null
L=$(q "select log_files || '|' || log_max_file_bytes from pgvigil.temp_sample where instance_id = $I and source = 'hour' order by snapshot_at desc limit 1")
echo "hour: $L (size $SIZE)"; [[ $L == "1|$SIZE" ]] || fail "B: the hour's log figures"
F=$(q "select string_agg(severity || '|' || setting, ',' order by severity) from pgvigil.memory_findings where instance_id = $I")
echo "findings: $F"; [[ $F == "info|temp-file spills,warning|temp-file spills" ]] || fail "B: the temp findings"
q "select detail from pgvigil.memory_findings where instance_id = $I and severity = 'info'" | grep -q 'statement 4242 ' || fail "B: the info finding names queryid 4242"
# [review fold, expected before the run] a late read (stamped three hours back) rebuilds its own six hours only: the
# hour rows from its own hour onward stay as they were. [first run: the count went 7 -> 10 - the late read's window
# reaches three hours further back and adds those hours, which is right; the newer rows were unchanged. Expected now:
# the rows from the late read's hour onward identical, exactly 3 rows added.]
NEWER="select string_agg(snapshot_at || ':' || coalesce(data_bytes, 0) || ':' || coalesce(temp_written_bytes, 0) || ':' || coalesce(log_files, 0), ',' order by snapshot_at)
         from pgvigil.temp_sample where instance_id = $I and source = 'hour' and snapshot_at >= date_trunc('hour', now() - interval '3 hours')"
BEFORE=$(q "$NEWER"); NB=$(q "select count(*) from pgvigil.temp_sample where instance_id = $I and source = 'hour'")
q "select pgvigil.import_temp_files($I, now() - interval '3 hours', '[{\"kind\":\"state\",\"data_bytes\":1,\"block_size\":8192}]'::jsonb)" >/dev/null
AFTER=$(q "$NEWER"); NA=$(q "select count(*) from pgvigil.temp_sample where instance_id = $I and source = 'hour'")
echo "late read: hour rows $NB -> $NA; the rows from its hour onward unchanged: $([[ $AFTER == "$BEFORE" ]] && echo yes || echo no)"
[[ $AFTER == "$BEFORE" && $NA == $((NB + 3)) ]] || fail "B: a late read changed the newer hours"

echo "--- C. the pooler"
cat > "$WORK/pgbouncer.ini" <<EOF
[databases]
$MDB = host=127.0.0.1 port=5432 dbname=$MDB pool_size=2
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGBPORT
auth_type = plain
auth_file = /etc/pgbouncer-proof/userlist.txt
pool_mode = session
default_pool_size = 2
max_client_conn = 50
stats_users = $STATSU
ignore_startup_parameters = extra_float_digits,options
EOF
printf '"%s" "%s"\n"%s" "%s"\n' "$APP" "$APPPW" "$STATSU" "$STATSPW" > "$WORK/userlist.txt"
chmod 644 "$WORK/pgbouncer.ini" "$WORK/userlist.txt"; chmod 755 "$WORK"
docker run -d --rm --name "$PGBNAME" --network host -v "$WORK:/etc/pgbouncer-proof:ro" --entrypoint pgbouncer "$PGB_IMAGE" /etc/pgbouncer-proof/pgbouncer.ini >/dev/null
for _ in $(seq 1 50); do psql "$PGB_DSN" -XAtq -c "show version" >/dev/null 2>&1 && break; sleep 0.2; done
psql "$PGB_DSN" -XAtq -c "show version" >/dev/null 2>&1 || fail "C: the pooler did not start: $(docker logs "$PGBNAME" 2>&1 | tail -5)"
for _ in 1 2 3 4; do
  psql "host=127.0.0.1 port=$PGBPORT dbname=$MDB user=$APP password=$APPPW sslmode=disable" -XAtq -c "select pg_sleep(90)" >/dev/null 2>&1 & CLIENTS+=($!)
done
sleep 7
collect "proof-mem-$SUF" pgbouncer >/dev/null
P=$(q "select status || '|' || version from pgvigil.pooler_state where instance_id = $I")
echo "state: $P"; [[ $P == "ok|PgBouncer 1.24.1"* ]] || fail "C: pooler_state"
R=$(q "select cl_waiting || '|' || sv_active || '|' || pool_size || '|' || (maxwait_ms >= 5000) from pgvigil.pooler_sample where instance_id = $I and kind = 'pool' and database = '$MDB'")
echo "pool: $R"; [[ $R == "2|2|2|true" ]] || fail "C: the pool row"
[[ $(q "select count(*) from pgvigil.pooler_sample where instance_id = $I and kind = 'stats' and database = '$MDB'") == 1 ]] || fail "C: the stats row"
DBS=$(q "select (select x->>'pool_size' from jsonb_array_elements(databases) x where x->>'name' = '$MDB') || '|' ||
              (select count(*) from jsonb_array_elements(config) x where x->>'key' = 'max_client_conn') from pgvigil.pooler_state where instance_id = $I")
echo "databases/config: $DBS"; [[ $DBS == "2|1" ]] || fail "C: SHOW DATABASES / SHOW CONFIG as read"
F=$(q "select string_agg(severity || '|' || setting, ',' order by severity, setting) from pgvigil.memory_findings where instance_id = $I and source = 'pgvigil memory' and setting in ('clients waiting on the pooler', 'a pool at its size')")
echo "pooler findings after one read: $F"; [[ $F == "critical|clients waiting on the pooler" ]] || fail "C: one read fires the maxwait rule only"
q "insert into pgvigil.pooler_sample select instance_id, snapshot_at - make_interval(mins => m), kind, database, usr, cl_active, cl_waiting, sv_active,
     sv_idle, sv_used, sv_tested, sv_login, maxwait_ms, pool_mode, pool_size, xact_rate, query_rate, avg_wait_us, avg_query_us, total_xact_count,
     total_query_count, total_wait_us
     from pgvigil.pooler_sample, generate_series(1, 5) m where instance_id = $I and kind = 'pool'" >/dev/null
F=$(q "select string_agg(severity || '|' || setting, ',' order by severity, setting) from pgvigil.memory_findings where instance_id = $I and setting in ('clients waiting on the pooler', 'a pool at its size')")
echo "pooler findings over five minutes: $F"
[[ $F == "critical|clients waiting on the pooler,warning|a pool at its size,warning|clients waiting on the pooler" ]] || fail "C: the 5-minute rules"
if psql "$PGB_DSN" -XAtq -c "PAUSE" >"$WORK/pause.out" 2>&1; then fail "C: PAUSE through the stats_users login was accepted"; fi
echo "PAUSE: $(tr '\n' ' ' < "$WORK/pause.out")"; grep -qi 'admin' "$WORK/pause.out" || fail "C: PAUSE refused, but not for admin access"

echo "--- D. no pgbouncer: DSN"
N=$(collect "proof-mem2-$SUF" pgbouncer)
echo "second instance: $N"; [[ $N == *skipped* ]] || fail "D: the collection was not skipped"
[[ $(q "select count(*) from pgvigil.pooler_state where instance_id = $I2") == 0 ]] || fail "D: a pooler_state row for the instance without the DSN"
q "select pgvigil.import_buffercache($I2, now(), '[{\"kind\":\"total\",\"status\":\"ok\",\"total_buffers\":1000,\"used_buffers\":900,\"dirty_buffers\":10,\"block_size\":8192},
   {\"kind\":\"rel\",\"datname\":\"$MDB2\",\"schemaname\":\"public\",\"relname\":\"big\",\"relkind\":\"r\",\"relfilenode\":1,\"buffers\":600,\"dirty\":0,\"usage_avg\":4,\"usage_hot\":600}]'::jsonb)" >/dev/null
F=$(q "select severity || '|' || setting || '|' || value from pgvigil.memory_findings where instance_id = $I2")
echo "second instance findings: $F"; [[ $F == "info|one relation holds over half of shared_buffers|60.0 %" ]] || fail "D: the buffer finding"

echo "--- E. the API"
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
start_serve() {
  "$1" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
  for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
  kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
}
start_serve "$BIN"
SERVER="routed in this build"
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/memory?instance=$I")" = 404 ]; then
  kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=
  tar --exclude=./web/node_modules --exclude=./bin --exclude=./.git -cf - . | tar -C "$SCRATCH" -xf -
  grep -q 'api.HandleFunc("GET /api/sessionsets", s.SessionSets)' "$SCRATCH/internal/web/web.go" || fail "the anchor line of the wiring is gone from web.go"
  sed -i 's|^\(\t*\)api.HandleFunc("GET /api/sessionsets", s.SessionSets)$|&\n\1api.HandleFunc("GET /api/memory", s.Memory)\n\1api.HandleFunc("GET /api/pooler", s.Pooler)|' "$SCRATCH/internal/web/web.go"
  (cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$SCRATCH/pgvigil-wired" ./cmd/pgvigil) || fail "the scratch build with the routes"
  SERVER="routed in a scratch build (the join wires them)"
  start_serve "$SCRATCH/pgvigil-wired"
fi
echo "server: $SERVER"
api() { local code; code=$(curl -s -o "$LOG.body" -w '%{http_code}' "$U/api/$1"); [ "$code" = 200 ] || fail "/api/$1 answered $code: $(cat "$LOG.body")"; cat "$LOG.body"; }
FROM=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ)
api "memory?instance=$I&from=$FROM" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); qid = sys.argv[1]
rows = lambda k: [dict(zip(d[k]["columns"], r)) for r in (d.get(k) or {}).get("rows") or []]
print("api/memory:", {k: len(rows(k)) for k in d})
assert rows("buffer_state")[0]["status"] == "ok"
assert any(r["relname"] == "pgv_mem_hot" for r in rows("buffer_rels")), "pgv_mem_hot"
assert any(str(r["queryid"]) == qid for r in rows("temp_statements")), "the spill"
assert len(rows("temp_hours")) >= 1 and len(rows("findings")) == 2, (rows("temp_hours"), rows("findings"))' "$QID" || fail "E: /api/memory"
api "pooler?instance=$I&from=$FROM" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
rows = lambda k: [dict(zip(d[k]["columns"], r)) for r in (d.get(k) or {}).get("rows") or []]
print("api/pooler:", {k: len(rows(k)) for k in d})
assert rows("state")[0]["status"] == "ok"
p = rows("pools"); assert len(p) == 1 and p[0]["cl_waiting"] == 2 and p[0]["user"], p
assert len(rows("findings")) == 3, rows("findings")' || fail "E: /api/pooler"
N=$(api "pooler?instance=$I2&part=state" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(len(d["state"]["rows"] or []))')
echo "api/pooler part=state, second instance: $N rows"; [ "$N" = 0 ] || fail "E: the second instance has a pooler state"
echo "PASS proof-memory ($SERVER)"
