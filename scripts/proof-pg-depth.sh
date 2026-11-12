#!/usr/bin/env bash
# Proof of the PostgreSQL depth collections (task 155, migration 0095): statements' new columns, the server state row of
# dbstats, functions, dbchecks, slru, index_bloat and pgvigil.pg_depth_findings. For each version in PGVIGIL_DEPTH_VERSIONS
# (default "13 16 18") it starts a throwaway postgres:<version> container on loopback ports (a random password made here,
# the container removed at the end, also on a failure), holding the repository database, two target databases and a
# monitoring login in pg_monitor (with pg_read_all_data on 14+, SELECT on the sequences on 13: a sequence's value needs
# it) and a pg_monitor-only login 'min' (D); the versions run side by side, each to its own log, printed in order at the end. Every finding is
# raised by a state seeded on the server and cleared by its undo there, except the 24-hour expiry of the timeline and
# system-identifier findings (a seeded import 25 hours later: said where it runs). Needs docker, psql and go (or
# PGVIGIL_BIN, a built binary).
#
# The container: shared_preload_libraries=pg_stat_statements, pg_stat_statements.track_planning=on, track_functions=all,
# max_connections=30 (superuser_reserved_connections 3: 27 client slots), archive_mode=on, checkpoint_timeout=30s,
# wal_level=replica; archive_command=/bin/false through ALTER SYSTEM (so W1's undo can change it).
#
# Expected (written before the first run), per version:
#  S  statements. Three statements run as postgres in tgt - an INSERT ... SELECT (7 times), a SELECT with every JIT cost
#     at 0 (3 times), a parallel count (2 times, parallel costs at 0) - then collect statements. For each of the three,
#     statements_current's new columns equal pg_stat_statements read by hand right after (to_jsonb of the row: a column
#     the version lacks reads NULL on both sides): calls, plans, wal_records, wal_fpi, wal_buffers_full, the five JIT
#     counts, workers to launch / launched, generic / custom plan calls, local blocks, and plan / JIT times to 3
#     decimals. Version marks: 13 - jit_* NULL, workers NULL, wal_buffers_full NULL, plans and wal_records set; 16 -
#     jit_functions > 0 for the JIT statement when pg_jit_available(), jit_deform_* and workers NULL; 18 - jit_deform set,
#     workers_to_launch >= 1 for the parallel count; generic / custom NULL on all three (not in pg_stat_statements 1.12).
#     The INSERT 3 more times, collect again: its statements_delta row reads calls 3, plans 3, and wal_records / wal_fpi
#     equal the hand differences; statement_depth over the hour returns it with calls 3.
#  W  the server state (collect dbstats). wal_state_sample's newest row: system_identifier and timeline_id equal the hand
#     read, checkpoint_timeout_s 30, max_connections 30, superuser_reserved 3, standbys 0, archive_mode 'on', client
#     backends 2 to 4 (the collector's own). Findings of the instance: 'no standby|info' present.
#     W1 archive: 12 WAL switches with the archiver failing -> archive_ready = the hand .ready count (>= 10) and
#        'archive backlog|warning'; archive_command /bin/true + reload, the backlog drains -> finding gone.
#     W2 connections: 23 sleeping sessions -> client_backends 25 or 26 of 27 (the collector's target connection and its
#        repository pool on the same server counted), 'connections near the limit|warning' with that value; ended -> gone.
#        [corrected before the first run: the repository database is on the same server, so the collector's own sessions
#        are two or more; the idle read's client_backends is 2 to 4, not 1]
#     W3 standby: a streaming standby made with pg_basebackup inside the container -> standbys 1, 'no standby' gone.
#     W4 timeline: a second instance 'tl' read on the primary (timeline 1), the standby promoted and 'tl' pointed at it ->
#        timeline_id 2 and 'timeline changed|warning' 'timeline 1 -> 2'; then 'tl' pointed at a third, freshly initdb'd
#        cluster -> 'system identifier changed|critical'. Seeded import 25 hours later -> both gone.
#     W5 checkpoint (last): the checkpointer stopped (SIGSTOP), 16 MB+ of WAL written, 125 s waited -> 'checkpoint
#        late|warning' and checkpoint_time equal to the hand read; SIGCONT + CHECKPOINT -> gone.
#  F  functions: f_work() in tgt called 5 times, g_other() in tgt2 twice -> function_stats' calls equal
#     pg_stat_user_functions (5 and 2), depth_databases' track_functions 'all' for tgt and tgt2; f_work 3 more times,
#     collect again -> function_top over the hour: f_work calls 3, total_ms equal to the hand difference (3 decimals).
#  D  dbchecks: seeded in tgt - integer sequence s_int at 2,000,000,000 (93.13 %), bigint sequence s_big behind an integer
#     column at 2,100,000,000 (97.79 % of the column), SECURITY DEFINER sd() without search_path, a NOT VALID check nv_pos,
#     50 rows in the DEFAULT partition ptd, CREATE on public granted to PUBLIC -> the tgt findings exactly
#       'CREATE on schema public|warning', 'NOT VALID constraint|info', 'SECURITY DEFINER without search_path|warning',
#       'rows in a DEFAULT partition|info', 'sequence near its maximum|warning' x2
#     and sequence_state's last_value / pct_used equal the hand read; the mon instance's run status 'ok' with no MD5 row.
#     Undo (ALTER SEQUENCE ... AS bigint, ALTER COLUMN ... TYPE bigint, SET search_path, VALIDATE, the rows deleted,
#     REVOKE) -> no tgt finding. MD5 on the superuser instance 'su': a role with an MD5 password -> 'MD5 password|warning';
#     re-set with SCRAM -> gone. [fold s155-proof4: on 13 'mon' and
#     'postgres' (and 'mon_min', review fold) too - 13 hashes with md5 by default - true hits]
#  L  slru: baseline read; a transaction with 200,000 subtransactions held open while another session scans its rows ->
#     the subtransaction cache's blks_read rises, slru_sample's newest value equals pg_stat_slru by hand and 'subtransaction
#     SLRU reads|warning'; the transaction ended, a read with no new reads -> gone. [fold s155-proof5:
#     max_locks_per_transaction=8000 so the lock table holds every subtransaction; the block's handler catches
#     division_by_zero only, so a short seed fails loudly]
#  B  index_bloat: bt (1,000,000 rows, primary key), 90 % deleted, VACUUM + ANALYZE -> bt_pkey's estimate within 15 points
#     of pgstatindex's (100 - avg_leaf_density x 100 / 90) and 'index bloat|info'; its own reindex_sql run -> the rebuilt
#     size within 25 % of the estimate made before, the row no longer present (under the 10 MB floor), finding gone.
#  X  dead rows: dr with autovacuum off, 300,000 rows, 150,000 deleted, collect tables -> 'dead rows|warning'; VACUUM -> gone.
#  every collect's collection_dates status is 'ok'.
#  NOT PROVEN on PostgreSQL 16 (the lead's ruling, 2026-11-11 15:47 PST): L, the subtransaction SLRU seed - three runs on 16 failed: about 12,000 of 200,000 subtransactions made (the lock table full, swallowed by the seed's handler),
#   then a precheck that cannot see the open transaction's pending counters, then 300,000 made but the scan touched the cache
#   8 times (cause unknown); it passed on 16 once (run 4).
#  PGVIGIL_DEPTH_SKIP=L leaves L out on every version run and says so: the version's log prints 'NOT PROVEN [pg<v>] L
#  (skipped)' and the last line reads 'PASS: proof-pg-depth on <versions>; L: NOT PROVEN (skipped)', never a bare PASS.
#  [review s155-1 fold, expected before its run: D also seeds a SECURITY DEFINER procedure p_sd and a NOT VALID domain check
#   posint_chk (so 8 tgt findings: NOT VALID x2, SECURITY DEFINER x2), their undo is each row's own fix_sql run as written
#   (ALTER ROUTINE, ALTER DOMAIN); a sequence counting down to 0 reads pct_used NULL and the read still succeeds; a
#   pg_monitor-only login 'min' reads dbchecks with status ok, s_int readable false / last_value NULL, no sequence finding,
#   both SECURITY DEFINER rows; L seeds 300,000 subtransactions (140+ pages) and the finding needs 50 pages read; W2 waits
#   for the earlier sessions to close; the standby gets max_locks_per_transaction 8000 (a hot standby needs the primary's)]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSIONS=${PGVIGIL_DEPTH_VERSIONS:-"13 16 18"}
# PGVIGIL_DEPTH_SKIP: parts left out, said in the last line; only L is accepted (the ruling of 2026-11-11)
SKIP=${PGVIGIL_DEPTH_SKIP:-}
[[ -z "$SKIP" || "$SKIP" == L ]] || { echo "FAIL: PGVIGIL_DEPTH_SKIP='$SKIP': only L can be left out"; exit 2; }
SUF=$RANDOM$RANDOM
WORK=$(mktemp -d)
LABEL="pgvigil-proof=depth-$SUF"
cleanup() {
  local ids; ids=$(docker ps -aq --filter "label=$LABEL" 2>/dev/null || true)
  # -v: the postgres image declares a data volume; without it every run left its volumes behind (the box's disk filled, 11/11)
  [[ -n "$ids" ]] && docker rm -f -v $ids >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in docker psql; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then
  command -v go >/dev/null || { echo "FAIL: neither PGVIGIL_BIN nor go" >&2; exit 1; }
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
  BIN=$WORK/pgvigil
fi
echo "load before the run: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
# about 1.5 GB is written in all (three servers, the WAL a failing archiver keeps, a million-row table): under 3 GB free on
# docker's disk the run stops before it starts, a full disk would read as wrong results
# PGVIGIL_DEPTH_PARALLEL=0 runs the versions one after another (about 1 GB at a time instead of 3)
PARALLEL=${PGVIGIL_DEPTH_PARALLEL:-1}
need_mb=$(( PARALLEL == 1 ? 3072 : 1536 ))
free_mb=$(df -Pm "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | awk 'NR == 2 {print $4}')
[[ -z "$free_mb" || "$free_mb" -ge $need_mb ]] || { echo "NOT RUN: $free_mb MB free on docker's disk, the proof needs $need_mb MB (PGVIGIL_DEPTH_PARALLEL=$PARALLEL)"; exit 2; }

run_version() (
  set -euo pipefail
  VER=$1
  fail() { echo "FAIL [pg$VER]: $*"; echo "     [pg$VER] the server log's last lines:"; docker logs --tail 40 "$CT" 2>&1 | sed "s/^/     [pg$VER] log: /"; exit 1; }
  ok() { echo "ok   [pg$VER] $*"; }
  CT=pgvigil-depth-$VER-$SUF
  # each version removes its own server (and its data volume) when it ends, passed or failed
  trap 'docker rm -f -v "$CT" >/dev/null 2>&1 || true' EXIT
  export POSTGRES_PASSWORD="p$RANDOM$RANDOM$RANDOM"
  MPW="m$RANDOM$RANDOM$RANDOM"
  docker run -d --name "$CT" --label "$LABEL" -e POSTGRES_PASSWORD -p 127.0.0.1::5432 -p 127.0.0.1::5433 -p 127.0.0.1::5434 "postgres:$VER" \
    -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track_planning=on -c track_functions=all \
    -c max_connections=30 -c superuser_reserved_connections=3 -c archive_mode=on \
    -c checkpoint_timeout=30s -c wal_level=replica -c max_wal_senders=5 -c max_locks_per_transaction=8000 >/dev/null || fail "docker run postgres:$VER"
  port() { docker port "$CT" "$1/tcp" | head -1 | sed 's/.*://'; }
  P=$(port 5432); P2=$(port 5433); P3=$(port 5434)
  ADMIN="host=127.0.0.1 port=$P user=postgres password=$POSTGRES_PASSWORD"
  for _ in $(seq 120); do psql "$ADMIN dbname=postgres" -XAtq -c "select 1" >/dev/null 2>&1 && break; sleep 1; done
  sql() { psql "$ADMIN dbname=$1" -XAtq -v ON_ERROR_STOP=1 -c "$2"; }
  t() { sql tgt "$1"; }
  q() { sql pgvigil_repo "$1"; }
  sql postgres "select 1" >/dev/null || fail "the server did not come up"
  # the failing archiver through ALTER SYSTEM, not the command line: a command-line setting outranks ALTER SYSTEM, so W1's
  # undo would never take (s155-proof1)
  sql postgres "alter system set archive_command = '/bin/false'" >/dev/null; sql postgres "select pg_reload_conf()" >/dev/null
  for d in pgvigil_repo tgt tgt2; do sql postgres "create database $d" >/dev/null; done
  sql postgres "create role mon login password '$MPW' in role pg_monitor" >/dev/null
  sql postgres "create role mon_min login password '$MPW' in role pg_monitor" >/dev/null   # pg_monitor alone: the documented minimum
  [[ $VER -ge 14 ]] && sql postgres "grant pg_read_all_data to mon" >/dev/null
  t "create extension pg_stat_statements; create extension pgstattuple" >/dev/null
  export REPO_DSN="$ADMIN dbname=pgvigil_repo"
  export TGT_DSN="host=127.0.0.1 port=$P user=mon password=$MPW dbname=tgt"
  export SU_DSN="$ADMIN dbname=tgt"
  export TL_DSN="$TGT_DSN"
  export MIN_DSN="host=127.0.0.1 port=$P user=mon_min password=$MPW dbname=tgt"
  CFG=$WORK/cfg-$VER.yaml
  cat > "$CFG" <<EOF
repository:
  dsn: env:REPO_DSN
instances:
  - name: depth-$VER
    dsn: env:TGT_DSN
  - name: su-$VER
    dsn: env:SU_DSN
  - name: tl-$VER
    dsn: env:TL_DSN
  - name: min-$VER
    dsn: env:MIN_DSN
EOF
  "$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
  col() { # collection, instance (default depth)
    local in=${2:-depth}-$VER st
    "$BIN" collect -config "$CFG" -once "$1" -instance "$in" >/dev/null 2>"$WORK/col-$VER.err" || fail "collect $1 $in: $(tr '\n' ' ' < "$WORK/col-$VER.err")"
    st=$(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates d join pgvigil.instances i using (instance_id) where i.name = '$in' and d.collection = '$1'")
    [[ $st == "ok " ]] || fail "collect $1 $in status: $st"
  }
  iid() { q "select instance_id from pgvigil.instances where name = '${1:-depth}-$VER'"; }
  # findings of an instance: setting|severity|value, one per line, sorted; $2 = a filter on value
  fnd() { q "select coalesce(string_agg(setting || '|' || severity || '|' || value, E'\n' order by setting, value), '') from pgvigil.pg_depth_findings where instance_id = $(iid "${3:-depth}") ${2:+and $2} ${1:+and setting = '$1'}"; }
  has() { [[ -n $(fnd "$1" "${2:-}" "${3:-}") ]]; }
  waitfor() { # sql on db, expected output, seconds
    local i; for i in $(seq $(( ${4:-20} * 2 ))); do [[ $(sql "$1" "$2") == "$3" ]] && return 0; sleep 0.5; done
    fail "waited for '$2' on $1 = '$3', got '$(sql "$1" "$2")'"
  }
  echo "--- [pg$VER] server $(sql postgres "show server_version"), port $P"

  echo "--- [pg$VER] S. statements"
  t "create table s1 (a int, b text)" >/dev/null
  for _ in $(seq 7); do t "insert into s1 select g, md5(g::text) from generate_series(1, 1000) g" >/dev/null; done
  for _ in $(seq 3); do psql "$ADMIN dbname=tgt" -XAtq -c "set jit_above_cost = 0" -c "set jit_inline_above_cost = 0" -c "set jit_optimize_above_cost = 0" -c "select sum(a) from s1" >/dev/null; done
  for _ in $(seq 2); do psql "$ADMIN dbname=tgt" -XAtq -c "set max_parallel_workers_per_gather = 2" -c "set parallel_setup_cost = 0" -c "set parallel_tuple_cost = 0" -c "set min_parallel_table_scan_size = 0" -c "select count(*) from s1" >/dev/null; done
  INTS="calls plans wal_records wal_fpi wal_buffers_full jit_functions jit_inlining_count jit_optimization_count jit_emission_count jit_deform_count parallel_workers_to_launch parallel_workers_launched generic_plan_calls custom_plan_calls local_blks_hit local_blks_read local_blks_dirtied local_blks_written"
  FLOATS="total_plan_time:total_plan_ms jit_generation_time:jit_generation_ms jit_inlining_time:jit_inlining_ms jit_optimization_time:jit_optimization_ms jit_emission_time:jit_emission_ms jit_deform_time:jit_deform_ms"
  hand_e=""; repo_e=""
  for c in $INTS; do hand_e+="coalesce(j->>'$c', 'NULL') || '|' || "; repo_e+="coalesce($c::text, 'NULL') || '|' || "; done
  for f in $FLOATS; do hand_e+="coalesce(round((j->>'${f%%:*}')::numeric, 3)::text, 'NULL') || '|' || "; repo_e+="coalesce(round(${f##*:}::numeric, 3)::text, 'NULL') || '|' || "; done
  hand_e+="''"; repo_e+="''"
  qid() { t "select queryid from pg_stat_statements where query like '$1%' order by calls desc limit 1"; }
  Q_INS=$(qid "insert into s1 select g, md5"); Q_JIT=$(qid "select sum(a) from s1"); Q_PAR=$(qid "select count(*) from s1")
  [[ -n $Q_INS && -n $Q_JIT && -n $Q_PAR ]] || fail "the seeded statements are not in pg_stat_statements"
  col statements
  IID=$(iid)
  hand() { t "select $hand_e from (select to_jsonb(s) j from pg_stat_statements s where queryid = $1 and userid = 'postgres'::regrole::oid) x"; }
  repo() { q "select $repo_e from pgvigil.statements_current where instance_id = $IID and queryid = $1"; }
  for x in INS:$Q_INS JIT:$Q_JIT PAR:$Q_PAR; do
    h=$(hand "${x#*:}"); r=$(repo "${x#*:}")
    [[ -n $h && $h == "$r" ]] || fail "statement ${x%%:*}: the repository '$r' is not the hand read '$h' ($INTS ${FLOATS//:/>})"
    echo "     [pg$VER] ${x%%:*}: $r"
  done
  ok "S: the three statements' new columns equal pg_stat_statements read by hand"
  rq() { q "select coalesce($1::text, 'NULL') from pgvigil.statements_current where instance_id = $IID and queryid = $2"; }
  case $VER in
    13) [[ $(rq jit_functions "$Q_JIT") == NULL && $(rq parallel_workers_to_launch "$Q_PAR") == NULL && $(rq plans "$Q_INS") != NULL && $(rq wal_records "$Q_INS") != NULL ]] || fail "13's NULL / set marks";;
    16) [[ $(rq jit_deform_count "$Q_JIT") == NULL && $(rq parallel_workers_to_launch "$Q_PAR") == NULL ]] || fail "16's NULL marks"
        if [[ $(t "select pg_jit_available()") == t ]]; then [[ $(rq jit_functions "$Q_JIT") -gt 0 ]] || fail "16: jit_functions 0 for the JIT statement"; else echo "     [pg$VER] no JIT in this image: jit_functions not asserted > 0"; fi;;
    18) [[ $(rq parallel_workers_to_launch "$Q_PAR") -ge 1 && $(rq jit_deform_count "$Q_JIT") != NULL ]] || fail "18: workers_to_launch / jit_deform";;
  esac
  [[ $(rq generic_plan_calls "$Q_INS") == NULL && $(rq custom_plan_calls "$Q_INS") == NULL ]] || fail "generic / custom plan calls should be NULL on $VER"
  ok "S: the version marks hold"
  before=$(t "select calls || ' ' || plans || ' ' || wal_records || ' ' || wal_fpi from pg_stat_statements where queryid = $Q_INS and userid = 'postgres'::regrole::oid")
  for _ in $(seq 3); do t "insert into s1 select g, md5(g::text) from generate_series(1, 1000) g" >/dev/null; done
  after=$(t "select calls || ' ' || plans || ' ' || wal_records || ' ' || wal_fpi from pg_stat_statements where queryid = $Q_INS and userid = 'postgres'::regrole::oid")
  col statements
  read -r b1 b2 b3 b4 <<<"$before"; read -r a1 a2 a3 a4 <<<"$after"
  want="$((a1 - b1)) $((a2 - b2)) $((a3 - b3)) $((a4 - b4))"
  got=$(q "select calls || ' ' || plans || ' ' || wal_records || ' ' || wal_fpi from pgvigil.statements_delta where instance_id = $IID and queryid = $Q_INS and snapshot_at = (select max(snapshot_at) from pgvigil.statements_delta where instance_id = $IID)")
  [[ $got == "$want" && $want == 3\ 3\ * ]] || fail "the INSERT's delta '$got', the hand differences '$want'"
  got=$(q "select calls || ' ' || plans || ' ' || wal_records from pgvigil.statement_depth($IID, now() - interval '1 hour', now() + interval '1 minute', 'wal', 500) where queryid = $Q_INS")
  [[ $got == "3 3 $((a3 - b3))" ]] || fail "statement_depth: '$got'"
  ok "S: the delta (calls plans wal_records wal_fpi) $got / $want and statement_depth agree"

  echo "--- [pg$VER] W. the server state"
  tl_expr="('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int"
  cb() { sql postgres "select count(*) from pg_stat_activity where backend_type = 'client backend'"; }
  col dbstats
  wal() { q "select $1 from pgvigil.wal_state_sample where instance_id = $(iid "${2:-depth}") order by snapshot_at desc limit 1"; }
  [[ $(wal system_identifier) == $(sql postgres "select system_identifier from pg_control_system()") ]] || fail "system_identifier"
  [[ $(wal timeline_id) == $(sql postgres "select $tl_expr") && $(wal timeline_id) == 1 ]] || fail "timeline_id $(wal timeline_id)"
  [[ $(wal "checkpoint_timeout_s || ' ' || max_connections || ' ' || superuser_reserved || ' ' || standbys || ' ' || archive_mode") == "30 30 3 0 on" ]] || fail "settings row: $(wal "checkpoint_timeout_s || ' ' || max_connections || ' ' || superuser_reserved || ' ' || standbys || ' ' || archive_mode")"
  # the collector's own sessions: its target connection and its repository pool (the repository is on this server too)
  [[ $(wal client_backends) -ge 2 && $(wal client_backends) -le 4 ]] || fail "client_backends $(wal client_backends) (the collector's own 2 to 4)"
  has 'no standby' || fail "no 'no standby' finding: $(fnd)"
  ok "W: the state row equals the hand read; 'no standby' raised"
  # W1 archive backlog
  for _ in $(seq 12); do t "insert into s1 values (1, 'x')" >/dev/null; t "select pg_switch_wal()" >/dev/null; done
  rdy() { sql postgres "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'"; }
  for _ in $(seq 40); do [[ $(rdy) -ge 10 ]] && break; sleep 0.5; done
  h1=$(rdy); col dbstats; h2=$(rdy)
  [[ $(wal archive_ready) == "$h1" && $h1 == "$h2" && $h1 -ge 10 ]] || fail "archive_ready $(wal archive_ready), by hand $h1 / $h2"
  has 'archive backlog' || fail "no 'archive backlog' finding"
  sql postgres "alter system set archive_command = '/bin/true'" >/dev/null; sql postgres "select pg_reload_conf()" >/dev/null
  waitfor postgres "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'" 0 150
  col dbstats
  has 'archive backlog' && fail "'archive backlog' still raised after the backlog drained"
  ok "W1: archive backlog raised at $h1 .ready files and cleared"
  # W2 connections
  # the sessions of the reads before are gone first (a just-closed backend still counted would read 27 of 27)
  waitfor postgres "select count(*) <= 3 from pg_stat_activity where backend_type = 'client backend'" t 30
  sleepers=()
  for _ in $(seq 23); do psql "$ADMIN dbname=tgt" -XAtq -c "select pg_sleep(600)" >/dev/null 2>&1 & sleepers+=($!); done
  waitfor postgres "select count(*) >= 23 from pg_stat_activity where backend_type = 'client backend' and query = 'select pg_sleep(600)'" t 30
  col dbstats
  cn=$(fnd 'connections near the limit')
  [[ $cn =~ ^'connections near the limit|warning|'(25|26)' of 27 ('(92.6|96.3)' %)'$ && ${cn##*|} == "$(wal client_backends) of 27"* ]] || fail "connections: '$cn' (client_backends $(wal client_backends))"
  kill "${sleepers[@]}" 2>/dev/null || true
  sql postgres "select pg_terminate_backend(pid) from pg_stat_activity where query = 'select pg_sleep(600)'" >/dev/null
  waitfor postgres "select count(*) from pg_stat_activity where query = 'select pg_sleep(600)'" 0 30
  col dbstats
  has 'connections near the limit' && fail "'connections near the limit' still raised"
  ok "W2: connections '${cn##*|}' raised and cleared"
  # W3 a standby
  docker exec -u postgres "$CT" bash -c 'pg_basebackup -h /var/run/postgresql -p 5432 -D /tmp/sb -R -X stream -c fast >/tmp/bb.log 2>&1 && printf "port = 5433\nmax_locks_per_transaction = 8000\n" >> /tmp/sb/postgresql.auto.conf && pg_ctl -D /tmp/sb -l /tmp/sb.log -w start >/dev/null' || fail "the standby: $(docker exec "$CT" cat /tmp/bb.log /tmp/sb.log 2>/dev/null | tail -5)"
  waitfor postgres "select count(*) from pg_stat_replication where state = 'streaming'" 1 60
  col dbstats
  [[ $(wal standbys) == 1 ]] || fail "standbys $(wal standbys)"
  has 'no standby' && fail "'no standby' still raised with a standby streaming"
  ok "W3: 'no standby' cleared by a streaming standby"
  # W4 timeline and system identifier, through the instance 'tl'
  col dbstats tl
  [[ $(wal timeline_id tl) == 1 ]] || fail "tl's first timeline $(wal timeline_id tl)"
  docker exec -u postgres "$CT" pg_ctl -D /tmp/sb promote -w >/dev/null || fail "promote"
  export TL_DSN="host=127.0.0.1 port=$P2 user=mon password=$MPW dbname=tgt"
  for _ in $(seq 60); do [[ $(psql "$TL_DSN" -XAtq -c "select not pg_is_in_recovery()" 2>/dev/null) == t ]] && break; sleep 0.5; done
  col dbstats tl
  [[ $(wal timeline_id tl) == 2 && $(wal timeline_id tl) == $(psql "$TL_DSN" -XAtq -c "select $tl_expr") ]] || fail "tl's timeline after the promotion: $(wal timeline_id tl)"
  [[ $(fnd 'timeline changed' '' tl) == 'timeline changed|warning|timeline 1 -> 2' ]] || fail "timeline finding: '$(fnd 'timeline changed' '' tl)'"
  echo "create role mon login password '$MPW' in role pg_monitor; create database tgt;" > "$WORK/other-$VER.sql"
  # md5 in its pg_hba: it takes an MD5 or a SCRAM password (13's initdb hashes with md5, s155-proof4)
  docker exec -u postgres "$CT" bash -c 'initdb -D /tmp/other -U postgres >/tmp/initdb.log 2>&1 && echo "host all all all md5" >> /tmp/other/pg_hba.conf && pg_ctl -D /tmp/other -o "-p 5434 -c listen_addresses=*" -l /tmp/other.log -w start >/dev/null' || fail "the other cluster"
  docker exec -i -u postgres "$CT" psql -h /var/run/postgresql -p 5434 -d postgres -XAtq < "$WORK/other-$VER.sql" >/dev/null || fail "the other cluster's login"
  export TL_DSN="host=127.0.0.1 port=$P3 user=mon password=$MPW dbname=tgt"
  col dbstats tl
  [[ $(fnd 'system identifier changed' '' tl) == "system identifier changed|critical|$(sql postgres "select system_identifier from pg_control_system()") -> $(psql "$TL_DSN" -XAtq -c "select system_identifier from pg_control_system()")" ]] || fail "system identifier finding: '$(fnd 'system identifier changed' '' tl)'"
  # the 24-hour expiry: a seeded import 25 hours on (no live undo exists for a timeline)
  TLID=$(iid tl)
  q "select pgvigil.import_dbstats($TLID, now() + interval '25 hours', jsonb_build_array(jsonb_build_object('kind', 'wal', 'in_recovery', false, 'timeline_id', $(wal timeline_id tl), 'system_identifier', '$(wal system_identifier tl)', 'checkpoint_timeout_s', 300)))" >/dev/null
  [[ -z $(fnd 'timeline changed' '' tl) && -z $(fnd 'system identifier changed' '' tl) ]] || fail "the timeline / system identifier findings outlived 24 hours"
  ok "W4: timeline 1 -> 2 and the system identifier change raised; gone 25 hours on (seeded import)"
  docker exec -u postgres "$CT" bash -c 'pg_ctl -D /tmp/other -m fast stop >/dev/null; pg_ctl -D /tmp/sb -m fast stop >/dev/null' || true

  echo "--- [pg$VER] F. functions"
  t "create function f_work(n int) returns bigint language plpgsql as \$\$ declare s bigint := 0; begin for i in 1..n loop s := s + i; end loop; return s; end \$\$" >/dev/null
  sql tgt2 "create function g_other() returns int language plpgsql as \$\$ begin return 1; end \$\$" >/dev/null
  for _ in $(seq 5); do t "select f_work(20000)" >/dev/null; done
  for _ in $(seq 2); do sql tgt2 "select g_other()" >/dev/null; done
  waitfor tgt "select calls from pg_stat_user_functions where funcname = 'f_work'" 5
  waitfor tgt2 "select calls from pg_stat_user_functions where funcname = 'g_other'" 2
  col functions
  fs() { q "select calls from pgvigil.function_stats where instance_id = $IID and func_name = '$1' order by snapshot_at desc limit 1"; }
  [[ $(fs f_work) == 5 && $(fs g_other) == 2 ]] || fail "function_stats calls: f_work $(fs f_work), g_other $(fs g_other)"
  [[ $(q "select string_agg(datname || '=' || track_functions, ',' order by datname) from pgvigil.depth_databases where instance_id = $IID and collection = 'functions' and datname in ('tgt', 'tgt2')") == "tgt=all,tgt2=all" ]] || fail "depth_databases for functions"
  t0=$(t "select total_time from pg_stat_user_functions where funcname = 'f_work'")
  for _ in $(seq 3); do t "select f_work(20000)" >/dev/null; done
  waitfor tgt "select calls from pg_stat_user_functions where funcname = 'f_work'" 8
  t1=$(t "select total_time from pg_stat_user_functions where funcname = 'f_work'")
  col functions
  got=$(q "select calls || ' ' || (abs(total_ms - (($t1)::float8 - ($t0)::float8)) < 0.001) from pgvigil.function_top($IID, now() - interval '1 hour', now() + interval '1 minute', 'total', 50) where func_name = 'f_work'")
  [[ $got == "3 true" ]] || fail "function_top f_work '$got' (calls, total_ms within 0.001 of the hand difference $t1 - $t0)"
  ok "F: calls 5 / 2 equal the hand read in two databases; function_top: 3 calls, total_ms equal to the hand difference"

  echo "--- [pg$VER] D. dbchecks"
  t "create sequence s_int as integer; select setval('s_int', 2000000000)" >/dev/null
  t "create sequence s_big; create table tc (id int default nextval('s_big')); alter sequence s_big owned by tc.id; select setval('s_big', 2100000000)" >/dev/null
  t "create function sd() returns int language sql security definer as 'select 1'" >/dev/null
  t "create procedure p_sd() language sql security definer as \$\$ select 1 \$\$" >/dev/null
  t "create domain posint as int; alter domain posint add constraint posint_chk check (value > 0) not valid" >/dev/null
  t "create sequence countdown increment -1 minvalue 0 maxvalue 100 start 100; select nextval('countdown')" >/dev/null
  t "create table nv (a int); insert into nv values (-1); alter table nv add constraint nv_pos check (a > 0) not valid" >/dev/null
  t "create table pt (a int) partition by range (a); create table pt1 partition of pt for values from (0) to (100); create table ptd partition of pt default" >/dev/null
  t "insert into pt select 500 + g from generate_series(1, 50) g" >/dev/null
  t "grant create on schema public to public" >/dev/null
  [[ $VER -lt 14 ]] && t "grant select on all sequences in schema public to mon" >/dev/null
  waitfor tgt "select n_live_tup from pg_stat_user_tables where relname = 'ptd'" 50
  col dbchecks
  dfnd() { fnd "" "value like 'tgt:%'" | cut -d'|' -f1,2 | LC_ALL=C sort | paste -sd, -; }
  [[ $(dfnd) == "CREATE on schema public|warning,NOT VALID constraint|info,NOT VALID constraint|info,SECURITY DEFINER without search_path|warning,SECURITY DEFINER without search_path|warning,rows in a DEFAULT partition|info,sequence near its maximum|warning,sequence near its maximum|warning" ]] || fail "dbchecks findings: $(dfnd)"
  sq() { q "select last_value || ' ' || pct_used from pgvigil.sequence_state where instance_id = $IID and datname = 'tgt' and seq_name = '$1' and is_present"; }
  [[ $(sq s_int) == "$(t "select last_value || ' ' || round(100 * last_value::numeric / 2147483647, 2) from pg_sequences where sequencename = 's_int'")" && $(sq s_int) == "2000000000 93.13" ]] || fail "s_int: $(sq s_int)"
  [[ $(sq s_big) == "$(t "select last_value || ' ' || round(100 * last_value::numeric / 2147483647, 2) from pg_sequences where sequencename = 's_big'")" && $(sq s_big) == "2100000000 97.79" ]] || fail "s_big: $(sq s_big)"
  [[ $(q "select count(*) from pgvigil.db_checks where instance_id = $IID and check_kind = 'md5'") == 0 ]] || fail "an md5 row on the pg_monitor instance"
  [[ $(q "select coalesce(pct_used::text, 'NULL') || ' ' || last_value from pgvigil.sequence_state where instance_id = $IID and datname = 'tgt' and seq_name = 'countdown' and is_present") == "NULL 100" ]] || fail "countdown (to 0): $(q "select pct_used, last_value from pgvigil.sequence_state where instance_id = $IID and seq_name = 'countdown'")"
  # the pg_monitor-only login: the read runs, a sequence's value is not readable, no sequence finding
  col dbchecks min
  MIN=$(iid min)
  [[ $(q "select readable || ' ' || coalesce(last_value::text, 'NULL') from pgvigil.sequence_state where instance_id = $MIN and datname = 'tgt' and seq_name = 's_int' and is_present") == "false NULL" ]] || fail "the pg_monitor-only login's s_int row: $(q "select readable, last_value from pgvigil.sequence_state where instance_id = $MIN and seq_name = 's_int'")"
  [[ -z $(fnd 'sequence near its maximum' '' min) ]] || fail "a sequence finding with no readable sequence"
  [[ $(fnd 'SECURITY DEFINER without search_path' "value like 'tgt:%'" min | wc -l) == 2 ]] || fail "the pg_monitor-only login's catalog checks"
  ok "D: the eight tgt findings raised; s_int / s_big equal the hand read"
  t "alter sequence s_int as bigint; alter table tc alter column id type bigint; delete from nv where a <= 0" >/dev/null
  # the SECURITY DEFINER and NOT VALID rows' own fix lines, run as written (a function, a procedure, a table, a domain)
  while IFS= read -r fix; do [[ -n $fix ]] && { t "$fix" >/dev/null || fail "the fix line '$fix' failed"; }; done < <(q "select fix_sql from pgvigil.db_checks where instance_id = $IID and datname = 'tgt' and check_kind in ('secdef', 'notvalid') and is_present order by check_kind, object")
  t "delete from pt where a >= 100; revoke create on schema public from public" >/dev/null
  waitfor tgt "select n_live_tup from pg_stat_user_tables where relname = 'ptd'" 0
  col dbchecks
  [[ -z $(dfnd) ]] || fail "dbchecks findings after the undo: $(dfnd)"
  ok "D: every tgt finding cleared by its undo"
  # 18 warns that MD5 passwords are deprecated (on stderr, kept): the role is still made
  sql postgres "set password_encryption = 'md5'; create role md5user login password 'pw1'" >/dev/null || fail "the MD5 role"
  col dbchecks su
  # 13 hashes with md5 by default, so the image's postgres and the proof's mon carry MD5 hashes there too (true hits)
  m5=$(fnd 'MD5 password' '' su | paste -sd, -)
  want=$([[ $VER -lt 14 ]] && echo 'MD5 password|warning|md5user,MD5 password|warning|mon,MD5 password|warning|mon_min,MD5 password|warning|postgres' || echo 'MD5 password|warning|md5user')
  [[ $m5 == "$want" ]] || fail "MD5: '$m5', want '$want'"
  sql postgres "set password_encryption = 'scram-sha-256'; alter role md5user password 'pw2'" >/dev/null
  col dbchecks su
  [[ -z $(fnd 'MD5 password' "value = 'md5user'" su) ]] || fail "MD5 still raised for md5user after SCRAM"
  ok "D: MD5 raised on the superuser instance and cleared"

  if [[ $SKIP == L ]]; then
    echo "NOT PROVEN [pg$VER] L (skipped by PGVIGIL_DEPTH_SKIP)"
  else
    echo "--- [pg$VER] L. slru"
    t "create table slru_t (a int) with (autovacuum_enabled = false)" >/dev/null
    sub="select coalesce(sum(blks_read), 0) from pg_stat_slru where lower(name) in ('subtrans', 'subtransaction')"
    col slru
    b0=$(sql postgres "$sub")
    psql "$ADMIN dbname=tgt" -XAtq -c "begin" -c "do \$\$ begin for i in 1..300000 loop begin insert into slru_t values (i); exception when division_by_zero then null; end; end loop; end \$\$" -c "select pg_sleep(120)" -c "commit" >/dev/null 2>&1 &
    holder=$!
    # the open transaction reached its sleep: its 300,000 subtransactions all exist (the handler catches division_by_zero
    # only, so any other error - 'out of shared memory' when the lock table cannot hold every subtransaction's xid lock,
    # s155-proof5 - aborts the block and the sleep never runs). Its own SLRU counters stay pending in its backend until
    # its transaction ends, so they cannot be read here (s155-final1).
    waitfor postgres "select count(*) from pg_stat_activity where query = 'select pg_sleep(120)' and state = 'active'" 1 60
    slru_all="select string_agg(name || ' read ' || blks_read || ' hit ' || blks_hit || ' zeroed ' || blks_zeroed || ' written ' || blks_written, '; ') from pg_stat_slru where lower(name) in ('subtrans', 'subtransaction')"
    for scan in 1 2; do
      [[ $(t "select count(*) from slru_t") == 0 ]] || fail "scan $scan saw the open transaction's rows"
      for _ in $(seq 20); do [[ $(sql postgres "$sub") -ge $((b0 + 50)) ]] && break; sleep 0.5; done
      [[ $(sql postgres "$sub") -ge $((b0 + 50)) ]] && break
    done
    b1=$(sql postgres "$sub")
    [[ $b1 -ge $((b0 + 50)) ]] || fail "under 50 subtransaction pages read from disk ($b0 -> $b1; $(sql postgres "$slru_all"); subtransaction_buffers $(sql postgres "select coalesce((select setting from pg_settings where name = 'subtransaction_buffers'), 'n/a')")): the seed did not produce the state"
    col slru
    [[ $(q "select sum(blks_read) from pgvigil.slru_sample where instance_id = $IID and lower(name) in ('subtrans', 'subtransaction') and snapshot_at = (select max(snapshot_at) from pgvigil.slru_sample where instance_id = $IID)") == "$(sql postgres "$sub")" ]] || fail "slru_sample's blks_read is not the hand read"
    [[ $(fnd 'subtransaction SLRU reads' | cut -d'|' -f1,2) == 'subtransaction SLRU reads|warning' ]] || fail "subtransaction finding: '$(fnd 'subtransaction SLRU reads')'"
    sql postgres "select pg_terminate_backend(pid) from pg_stat_activity where query = 'select pg_sleep(120)'" >/dev/null
    wait "$holder" 2>/dev/null || true
    waitfor postgres "select count(*) from pg_stat_activity where query = 'select pg_sleep(120)'" 0 30
    sleep 1
    col slru
    [[ -z $(fnd 'subtransaction SLRU reads') ]] || fail "subtransaction finding after the transaction ended: '$(fnd 'subtransaction SLRU reads')'"
    t "vacuum slru_t" >/dev/null
    ok "L: $((b1 - b0)) subtransaction pages read raised the finding; cleared after the transaction ended"

  fi

  echo "--- [pg$VER] B. index_bloat"
  t "create table bt (id int primary key, v int); insert into bt select g, g from generate_series(1, 1000000) g" >/dev/null
  t "delete from bt where id % 10 <> 0" >/dev/null
  t "vacuum bt" >/dev/null; t "analyze bt" >/dev/null
  col index_bloat
  br() { q "select $1 from pgvigil.index_bloat where instance_id = $IID and datname = 'tgt' and index_name = 'bt_pkey' and is_present"; }
  est=$(br bloat_pct); est_bytes=$(br est_bytes)
  meas=$(t "select round((100 - avg_leaf_density * 100 / 90)::numeric, 1) from pgstatindex('public.bt_pkey')")
  [[ -n $est ]] || fail "no bloat row for bt_pkey ($(q "select est_note from pgvigil.index_bloat where instance_id = $IID and index_name = 'bt_pkey'"))"
  [[ $(q "select abs($est - $meas) <= 15") == t ]] || fail "bt_pkey estimate $est % against pgstatindex's $meas %"
  [[ $(fnd 'index bloat' "value like 'tgt: public.bt_pkey %'" | cut -d'|' -f1,2) == 'index bloat|info' ]] || fail "bloat finding: '$(fnd 'index bloat')'"
  t "$(br reindex_sql)" >/dev/null
  newb=$(t "select pg_relation_size('public.bt_pkey')")
  [[ $(q "select abs($est_bytes - $newb) <= 0.25 * $newb") == t ]] || fail "the estimate $est_bytes bytes against the rebuilt $newb"
  col index_bloat
  [[ -z $(br index_name) && -z $(fnd 'index bloat' "value like 'tgt: public.bt_pkey %'") ]] || fail "bt_pkey still listed after its rebuild"
  ok "B: bt_pkey estimated $est % (pgstatindex $meas %), the estimate $est_bytes bytes against the rebuilt $newb; cleared by its own REINDEX line"

  echo "--- [pg$VER] X. dead rows"
  t "create table dr (id int, v int) with (autovacuum_enabled = false); insert into dr select g, g from generate_series(1, 300000) g" >/dev/null
  t "delete from dr where id % 2 = 0" >/dev/null
  waitfor tgt "select n_dead_tup >= 150000 from pg_stat_user_tables where relname = 'dr'" t
  col tables
  [[ $(fnd 'dead rows' "value like 'tgt: public.dr %'" | cut -d'|' -f1,2) == 'dead rows|warning' ]] || fail "dead rows: '$(fnd 'dead rows')'"
  t "vacuum dr" >/dev/null
  waitfor tgt "select n_dead_tup from pg_stat_user_tables where relname = 'dr'" 0
  col tables
  [[ -z $(fnd 'dead rows' "value like 'tgt: public.dr %'") ]] || fail "dead rows still raised after VACUUM"
  ok "X: dead rows raised and cleared by VACUUM"

  echo "--- [pg$VER] W5. checkpoint"
  CK=$(sql postgres "select pid from pg_stat_activity where backend_type = 'checkpointer'")
  [[ -n $CK ]] || fail "no checkpointer pid"
  docker exec "$CT" bash -c "kill -STOP $CK"
  t "create table big (a int, b text); insert into big select g, repeat('x', 400) from generate_series(1, 60000) g" >/dev/null
  for _ in $(seq 200); do [[ $(sql postgres "select extract(epoch from now() - checkpoint_time) > 125 from pg_control_checkpoint()") == t ]] && break; sleep 1; done
  hct=$(sql postgres "select checkpoint_time from pg_control_checkpoint()")
  col dbstats
  [[ $(q "select checkpoint_time = '$hct'::timestamptz and wal_since_redo >= 16777216 from pgvigil.wal_state_sample where instance_id = $IID order by snapshot_at desc limit 1") == t ]] || fail "checkpoint_time / wal_since_redo: $(wal "checkpoint_time || ' ' || wal_since_redo") against $hct"
  [[ $(fnd 'checkpoint late' | cut -d'|' -f1,2) == 'checkpoint late|warning' ]] || fail "checkpoint late: '$(fnd 'checkpoint late')'"
  docker exec "$CT" bash -c "kill -CONT $CK"
  sql postgres "checkpoint" >/dev/null
  col dbstats
  [[ -z $(fnd 'checkpoint late') ]] || fail "checkpoint late still raised after the checkpoint"
  ok "W5: checkpoint late raised with the checkpointer stopped and cleared by a checkpoint"
  echo "PASS [pg$VER]"
)

rc=0
if [[ $PARALLEL == 1 ]]; then
  pids=(); for v in $VERSIONS; do run_version "$v" > "$WORK/v$v.log" 2>&1 & pids+=("$v:$!"); done
  for p in "${pids[@]}"; do v=${p%%:*}; wait "${p#*:}" || rc=1; echo "===== PostgreSQL $v"; cat "$WORK/v$v.log"; done
else
  # a background job waited for at once: run_version on the left of || would run with set -e ignored inside it
  for v in $VERSIONS; do echo "===== PostgreSQL $v"; run_version "$v" & wait $! || rc=1; done
fi
echo "load after the run: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
note=""; [[ $SKIP == L ]] && note="; L: NOT PROVEN (skipped)"
[[ $rc == 0 ]] && echo "PASS: proof-pg-depth on $VERSIONS$note" || { echo "FAIL: proof-pg-depth (see the version logs above)$note"; exit 1; }
