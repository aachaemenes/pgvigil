#!/usr/bin/env bash
# Proof of the serverlog collection and the 0025 slow views (task 36).
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN): the proof makes its own
#               repository database there (random suffix) and drops it at the end.
#   SLOW_PORT   the port of the monitored server (default 5496).
# The monitored server is a throwaway cluster this proof makes with initdb in a temporary directory (logging_collector
# on, log_line_prefix '%m [%p] %q%u@%d ', log_timezone America/Los_Angeles, TCP on localhost only) and removes at the
# end: the sandbox server runs with logging_collector off, and turning it on needs a restart of a shared server.
# initdb and pg_ctl of the sandbox's major version must be on PATH. Nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A. the monitoring login (pg_monitor only, then also pg_read_server_files): collect -once serverlog ends 'skipped',
#     collection_dates note naming "GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint,
#     boolean)"; no log_events row for the instance. (pg_read_server_files alone does not open pg_read_binary_file:
#     the function stays superuser-only.)
#  B. the EXECUTE grant given; in one superuser session SET log_min_duration_statement = 100 and run
#     select pg_sleep(0.3) /* <tag>-a */ three times (literals 0.3, 0.31, 0.32) and select pg_sleep(1.2) /* <tag>-b */
#     once; collect serverlog: status ok; log_events holds 3 slow rows marked -a (each >= 300 ms) and 1 marked -b
#     (>= 1200 ms), their source 'serverlog:log:postgresql-...log', datname postgres, usename the superuser;
#     log_cursor has the row 'serverlog:log' with read_to at or after the last statement's time.
#     A second collect adds no row (the overlap re-read dropped by the event key).
#  C. pg_rotate_logfile(), then select pg_sleep(0.25) /* <tag>-c */ in the new file: collect adds exactly that one row,
#     from the new file's name; the cursor moves forward.
#  D. the EXECUTE grant revoked: collect ends 'skipped' with the same reason; the stored rows stay.
#  [review 1 fold, expected before the rerun]
#  D2. the narrow door: as the cluster superuser create public.pgvigil_read_log (collect/serverlog.go's text), the wide
#     grant still revoked; select pg_sleep(0.25) /* <tag>-d */; collect: status ok, exactly one new row (-d). As the
#     login the door returns NULL for '../pg_hba.conf' and 'pg_hba.conf' (names pg_ls_logdir does not list). The door
#     dropped, a SECURITY DEFINER function of the same name and types owned by the login itself (a schema of its own)
#     is not taken: collect ends 'skipped' with the reason again.
#  D3. an absolute log_directory outside the data directory ('<tmp>/abslog'), the wide grant given again (no door):
#     select pg_sleep(0.25) /* <tag>-e */ written there; collect: one row from source 'serverlog:<tmp>/abslog:...'.
#  E. the views on the collected rows (instance P): slow_top(P, seed - 1 min, now, 0) at rank_count 1 is the -a shape
#     with statements 3 (the three literals are one shape), at rank_total 1 the -b shape; with p_min_ms 1000 one row
#     (-b); slow_events has 7 rows for P, reader 'server log', each with a shape_key; slow_totals(P, ...) = 7
#     statements, 5 shapes, 1 instance.
#  F. a seeded window on a scratch instance S (import_logs as the owner, times in UTC, 3 days before today 00:00 UTC):
#       day 1: 500 ms and 2,000 ms of "SELECT * FROM t WHERE id = 1" / "... id = 2" (one shape)
#       day 2: 15,000 ms of "UPDATE t SET v = 'x' WHERE id = 7", 70,000 ms and 70,000 ms of "SELECT pg_sleep(70)"
#       and a statement_text row (queryid 4242) "SELECT * FROM t WHERE id = $1" for S
#     slow_histogram(S, day1, day3, 0, 'UTC') = day1 2 statements (under_1s 1, s1_to_10 1, total 2,500, max 2,000),
#     day2 3 statements (s10_to_60 1, over_60s 2, total 155,000, max 70,000); with p_min_ms 1000: day1 1, day2 3;
#     with p_tz 'Not/AZone': the UTC days again.
#     slow_top(S, ...) by rank_count (the 'count' order until review 1; one call returns both ranks since): first the SELECT * shape (2, total 2,500, mean 1,250, queryid 4242), then
#     pg_sleep (2, 140,000); 'total': pg_sleep first (140,000), the UPDATE (15,000) second, SELECT * third;
#     [first run 2026-11-09: the count list came pg_sleep, SELECT *, UPDATE - the expectation missed that the two
#      shapes tie at 2, and slow_top breaks a tie by total time (its ORDER BY); graded against that order since]
#     slow_top(NULL, ...) (the fleet) includes the rows of S and of P; slow_top(S, ..., 1) returns 2 rows (the first
#     of each rank); [first run of the fold: 1 row - on S the first by count (the tie broken by total time) and the
#     first by total time are the same pg_sleep shape; graded as 1 since, with that shape]; the statement_text row's shape_key equals the SELECT * events' shape_key; slow_totals(S, ...) =
#     5 statements, 3 shapes, total 157,500, max 70,000.
#  G. rights: pgvigil_collector may run import_serverlog; pgvigil_reader may run slow_top, slow_totals and slow_histogram
#     and read slow_events and slow_sources; slow_sources lists P's serverlog reader 'ok' (its last run, D3).
#  K. a measurement, not graded: import_logs of 20,000 slow events into a scratch instance with the shape_key trigger
#     on, and of another 20,000 with it disabled (the time of each printed).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
PORT=${SLOW_PORT:-5496}
SUF=$RANDOM; TAG=pgvslow$SUF
REPO_DB=pgvigil_slowproof_$SUF; MON=pgvigil_slowmon_$SUF; MONPW=p$RANDOM$RANDOM
DIR=$(mktemp -d); CFG=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  pg_ctl -D "$DIR/data" stop -m fast -s >/dev/null 2>&1 || true
  rm -rf "$DIR" "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
command -v initdb >/dev/null && command -v pg_ctl >/dev/null || fail "initdb and pg_ctl must be on PATH"

echo "--- the monitored server: a throwaway cluster on port $PORT"
initdb -D "$DIR/data" -U postgres -A trust >/dev/null 2>&1 || fail "initdb"
cat >> "$DIR/data/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = ''
logging_collector = on
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'America/Los_Angeles'
EOF
pg_ctl -D "$DIR/data" -l "$DIR/server.out" -w -s start >/dev/null 2>&1 || { tail -5 "$DIR/server.out" >&2; fail "the cluster did not start"; }
SU="host=localhost port=$PORT user=postgres dbname=postgres sslmode=disable"
su() { psql "$SU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
su "create role $MON login password '$MONPW' in role pg_monitor"
export MON_DSN="host=localhost port=$PORT user=$MON password=$MONPW dbname=postgres sslmode=disable"

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-slow-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once serverlog >/dev/null || fail "collect serverlog"; }
GRANT_TXT='GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean)'

echo "--- A. no read grant: skipped with the reason"
"$BIN" collect -config "$CFG" -once instance >/dev/null || fail "collect instance"
P=$(q "select instance_id from pgvigil.instances where name='proof-slow-$SUF'")
st() { q "select status || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$P and collection='serverlog'"; }
collect
[[ $(st) == "skipped|"*"$GRANT_TXT"* ]] || fail "A pg_monitor only: $(st)"
su "grant pg_read_server_files to $MON"
collect
[[ $(st) == "skipped|"*"$GRANT_TXT"* ]] || fail "A with pg_read_server_files alone: $(st)"
[[ $(q "select count(*) from pgvigil.log_events where instance_id=$P") == 0 ]] || fail "A: rows without the grant"
echo "A ok: $(st)"

echo "--- B. the grant given: slow statements from the log files"
su "grant execute on function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) to $MON"
SEED=$(su "select now() - interval '1 second'")
psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<EOF
set log_min_duration_statement = 100;
select pg_sleep(0.3) /* $TAG-a */;
select pg_sleep(0.31) /* $TAG-a */;
select pg_sleep(0.32) /* $TAG-a */;
select pg_sleep(1.2) /* $TAG-b */;
EOF
LAST=$(su "select now()")
sleep 0.5   # the logging collector writes the file
collect
[[ $(st) == "ok|" ]] || fail "B status: $(st)"
c() { q "select count(*) from pgvigil.log_events where instance_id=$P and kind='slow' and $1"; }
[[ $(c "statement like '%$TAG-a%' and duration_ms >= 300 and source like 'serverlog:log:postgresql-%.log' and datname='postgres' and usename='postgres'") == 3 ]] \
  || fail "B -a rows: $(q "select string_agg(duration_ms || ' ' || source || ' ' || datname || ' ' || usename, '; ') from pgvigil.log_events where instance_id=$P")"
[[ $(c "statement like '%$TAG-b%' and duration_ms >= 1200") == 1 ]] || fail "B -b row"
[[ $(q "select read_to >= '$LAST'::timestamptz - interval '1 second' from pgvigil.log_cursor where instance_id=$P and source='serverlog:log'") == t ]] \
  || fail "B cursor: $(q "select source || ' ' || read_to from pgvigil.log_cursor where instance_id=$P") vs $LAST"
N1=$(q "select count(*) from pgvigil.log_events where instance_id=$P")
collect
[[ $(q "select count(*) from pgvigil.log_events where instance_id=$P") == "$N1" ]] || fail "B: the second read added rows"
CUR1=$(q "select read_to from pgvigil.log_cursor where instance_id=$P and source='serverlog:log'")
echo "B ok: $N1 events, cursor $CUR1"

echo "--- C. a rotated file"
OLDF=$(su "select name from pg_ls_logdir() order by modification desc, name desc limit 1")
su "select pg_rotate_logfile()" >/dev/null
for _ in $(seq 1 50); do [[ $(su "select name from pg_ls_logdir() order by modification desc, name desc limit 1") != "$OLDF" ]] && break; sleep 0.1; done
sleep 1.1   # the new file's name carries the second: the next statement lands after the rotation
psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null -c "set log_min_duration_statement = 100" -c "select pg_sleep(0.25) /* $TAG-c */"
sleep 0.5
NEWF=$(su "select name from pg_ls_logdir() order by modification desc, name desc limit 1")
[[ "$NEWF" != "$OLDF" ]] || fail "C: no new log file"
collect
[[ $(q "select count(*) from pgvigil.log_events where instance_id=$P") == $((N1 + 1)) ]] || fail "C: want exactly one new row"
[[ $(c "statement like '%$TAG-c%' and source = 'serverlog:log:$NEWF'") == 1 ]] || fail "C: the -c row from $NEWF"
[[ $(q "select read_to > '$CUR1' from pgvigil.log_cursor where instance_id=$P and source='serverlog:log'") == t ]] || fail "C: the cursor did not move"
echo "C ok: one row from $NEWF"

echo "--- D. the grant revoked"
su "revoke execute on function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) from $MON"
collect
[[ $(st) == "skipped|"*"$GRANT_TXT"* ]] || fail "D: $(st)"
[[ $(q "select count(*) from pgvigil.log_events where instance_id=$P") == $((N1 + 1)) ]] || fail "D: stored rows changed"
echo "D ok"

echo "--- D2. the narrow door"
DOOR=$(awk '/^const ServerlogDoorSQL = `/{f=1; sub(/^const ServerlogDoorSQL = `/, "")} f{ if (/`$/) { sub(/`$/, ""); print; exit } print }' internal/collect/serverlog.go)
[[ "$DOOR" == *"pgvigil_read_log"* ]] || fail "D2: the door's text was not found in serverlog.go"
printf '%s\n' "${DOOR//<login>/$MON}" | psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null
psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null -c "set log_min_duration_statement = 100" -c "select pg_sleep(0.25) /* $TAG-d */"
sleep 0.5
collect
[[ $(st) == "ok|" ]] || fail "D2 status with the door: $(st)"
[[ $(q "select count(*) from pgvigil.log_events where instance_id=$P") == $((N1 + 2)) ]] || fail "D2: want exactly one new row"
[[ $(c "statement like '%$TAG-d%'") == 1 ]] || fail "D2: the -d row"
for nm in ../pg_hba.conf pg_hba.conf; do
  [[ $(psql "$MON_DSN" -XAt -c "select public.pgvigil_read_log('$nm', 0, 100) is null") == t ]] || fail "D2: the door served $nm"
done
su "drop function public.pgvigil_read_log(text, bigint, bigint)"
su "create schema imp_$SUF authorization $MON"
psql "$MON_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create function imp_$SUF.pgvigil_read_log(p_name text, p_offset bigint, p_length bigint) returns bytea
  language sql security definer as 'select null::bytea'"
collect
[[ $(st) == "skipped|"*"$GRANT_TXT"* ]] || fail "D2: the login's own function was taken: $(st)"
su "drop schema imp_$SUF cascade"
echo "D2 ok"

echo "--- D3. an absolute log_directory outside the data directory"
su "grant execute on function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) to $MON"
mkdir -p "$DIR/abslog"
su "alter system set log_directory = '$DIR/abslog'"
su "select pg_reload_conf()" >/dev/null
for _ in $(seq 1 50); do [[ $(su "select count(*) from pg_ls_logdir()") -ge 1 ]] && break; sleep 0.1; done
sleep 1.1
psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null -c "set log_min_duration_statement = 100" -c "select pg_sleep(0.25) /* $TAG-e */"
sleep 0.5
collect
[[ $(st) == "ok|" ]] || fail "D3 status: $(st)"
[[ $(c "statement like '%$TAG-e%' and source like 'serverlog:$DIR/abslog:postgresql-%.log'") == 1 ]] \
  || fail "D3: the -e row: $(q "select string_agg(source, '; ') from pgvigil.log_events where instance_id=$P and statement like '%$TAG-e%'")"
su "alter system reset log_directory"
su "select pg_reload_conf()" >/dev/null
echo "D3 ok"

echo "--- E. the views on the collected rows"
W="'$SEED'::timestamptz - interval '1 minute', now()"
top1() { q "select statements || '|' || (example like '%$TAG-$1%') from pgvigil.slow_top($P, $W, $2) where $3 = 1"; }
[[ $(top1 a 0 rank_count) == "3|true" ]] || fail "E top by count: $(q "select rank_count, statements, example from pgvigil.slow_top($P, $W, 0)")"
[[ $(top1 b 0 rank_total) == "1|true" ]] || fail "E top by total"
[[ $(q "select count(*) || '|' || bool_and(example like '%$TAG-b%') from pgvigil.slow_top($P, $W, 1000)") == "1|true" ]] || fail "E threshold 1000"
[[ $(q "select count(*) || '|' || min(reader) || '|' || count(shape_key) from pgvigil.slow_events where instance_id=$P") == "7|server log|7" ]] || fail "E slow_events"
[[ $(q "select concat_ws(',', statements, shapes, instances) from pgvigil.slow_totals($P, $W, 0)") == "7,5,1" ]] || fail "E totals: $(q "select row(t.*) from pgvigil.slow_totals($P, $W, 0) t")"
echo "E ok"

echo "--- F. a seeded window"
q "insert into pgvigil.instances (name, platform) values ('proof-slow-seed-$SUF', 'onprem')" >/dev/null
S=$(q "select instance_id from pgvigil.instances where name='proof-slow-seed-$SUF'")
D0=$(q "select (date_trunc('day', now() at time zone 'UTC') - interval '3 days')::date")
ev() { echo "{\"kind\":\"event\",\"kind_of\":\"slow\",\"at\":\"$1\",\"pid\":1,\"usename\":\"app\",\"datname\":\"erp\",\"duration_ms\":$2,\"statement\":\"$3\",\"source\":\"seed\",\"event_key\":\"k$4\"}"; }
PAY="[$(ev "${D0}T01:00:00Z" 500 "SELECT * FROM t WHERE id = 1" 1),$(ev "${D0}T02:00:00Z" 2000 "SELECT * FROM t WHERE id = 2" 2),
$(ev "$(date -u -d "$D0 + 1 day" +%F)T03:00:00Z" 15000 "UPDATE t SET v = 'x' WHERE id = 7" 3),
$(ev "$(date -u -d "$D0 + 1 day" +%F)T04:00:00Z" 70000 "SELECT pg_sleep(70)" 4),$(ev "$(date -u -d "$D0 + 1 day" +%F)T05:00:00Z" 70000 "SELECT pg_sleep(70)" 5)]"
q "select pgvigil.import_logs($S, now(), \$j\$$PAY\$j\$::jsonb)" >/dev/null
q "insert into pgvigil.statement_text (instance_id, queryid, first_seen, last_seen, query) values ($S, 4242, now(), now(), 'SELECT * FROM t WHERE id = \$1')" >/dev/null
SW="('$D0'::timestamp at time zone 'UTC'), (('$D0'::date + 3)::timestamp at time zone 'UTC')"
H=$(q "select string_agg(concat_ws(',', day - '$D0'::date, statements, under_1s, s1_to_10, s10_to_60, over_60s, total_ms, max_ms), ' ' order by day) from pgvigil.slow_histogram($S, $SW, 0, 'UTC')")
[[ "$H" == "0,2,1,1,0,0,2500,2000 1,3,0,0,1,2,155000,70000" ]] || fail "F histogram: $H"
H=$(q "select string_agg(concat_ws(',', day - '$D0'::date, statements), ' ' order by day) from pgvigil.slow_histogram($S, $SW, 1000, 'UTC')")
[[ "$H" == "0,1 1,3" ]] || fail "F histogram min 1000: $H"
H=$(q "select string_agg(concat_ws(',', day - '$D0'::date, statements), ' ' order by day) from pgvigil.slow_histogram($S, $SW, 0, 'Not/AZone')")
[[ "$H" == "0,2 1,3" ]] || fail "F histogram unknown tz: $H"
T=$(q "select string_agg(concat_ws(',', left(example, 13), statements, total_ms, mean_ms, queryid), ' | ' order by rank_count) from pgvigil.slow_top($S, $SW, 0)")
[[ "$T" == "SELECT pg_sle,2,140000,70000 | SELECT * FROM,2,2500,1250,4242 | UPDATE t SET ,1,15000,15000" ]] || fail "F top by count: $T"
[[ $(q "select string_agg(left(example, 13), ',' order by rank_total) from pgvigil.slow_top($S, $SW, 0)") == "SELECT pg_sle,UPDATE t SET ,SELECT * FROM" ]] || fail "F top by total order"
[[ $(q "select count(*) || '|' || min(left(example, 13)) from pgvigil.slow_top($S, $SW, 0, 1)") == "1|SELECT pg_sle" ]] || fail "F limit 1: the first of each rank"
[[ $(q "select (select shape_key from pgvigil.statement_text where instance_id=$S and queryid=4242) = all (array(select shape_key from pgvigil.log_events where instance_id=$S and statement like 'SELECT * FROM t%'))") == t ]] || fail "F shape keys"
[[ $(q "select concat_ws(',', statements, shapes, total_ms, max_ms) from pgvigil.slow_totals($S, $SW, 0)") == "5,3,157500,70000" ]] || fail "F totals: $(q "select row(t.*) from pgvigil.slow_totals($S, $SW, 0) t")"
[[ $(q "select count(distinct instance_id) from pgvigil.slow_top(NULL, ('$D0'::timestamp at time zone 'UTC'), now(), 0, 500) where instance_id in ($S, $P)") == 2 ]] \
  || fail "F: the fleet read misses an instance"
echo "F ok"

echo "--- G. rights and the sources view"
[[ $(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_serverlog(int, timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "G collector"
[[ $(q "select has_function_privilege('pgvigil_reader', 'pgvigil.slow_top(int, timestamptz, timestamptz, float8, int)', 'EXECUTE')
          and has_function_privilege('pgvigil_reader', 'pgvigil.slow_totals(int, timestamptz, timestamptz, float8)', 'EXECUTE')
          and has_function_privilege('pgvigil_reader', 'pgvigil.slow_histogram(int, timestamptz, timestamptz, float8, text)', 'EXECUTE')
          and has_table_privilege('pgvigil_reader', 'pgvigil.slow_events', 'SELECT') and has_table_privilege('pgvigil_reader', 'pgvigil.slow_sources', 'SELECT')") == t ]] || fail "G reader"
[[ $(q "select reader || '|' || status from pgvigil.slow_sources where instance_id=$P") == "serverlog|ok" ]] \
  || fail "G sources: $(q "select row(s.*) from pgvigil.slow_sources s where instance_id=$P")"
echo "G ok"

echo "--- K. import_logs with and without the shape_key trigger (measured, not graded)"
q "insert into pgvigil.instances (name, platform) values ('proof-slow-cost-$SUF', 'onprem')" >/dev/null
K=$(q "select instance_id from pgvigil.instances where name='proof-slow-cost-$SUF'")
cost() {
  psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "
create temp table kp as
select jsonb_agg(jsonb_build_object('kind', 'event', 'kind_of', 'slow', 'at', now() - g * interval '1 second', 'pid', g,
         'duration_ms', 1000 + g, 'source', 'seed', 'event_key', '$1' || g,
         'statement', 'SELECT * FROM orders o JOIN lines l ON l.order_id = o.id WHERE o.customer = ' || g || ' AND o.note = ' || quote_literal('x' || g))) AS p
  from generate_series(1, 20000) g;" -c "
do \$\$ declare t0 timestamptz := clock_timestamp(); begin
  perform pgvigil.import_logs($K, now(), (select p from kp));
  raise notice 'ms %', round(extract(epoch from clock_timestamp() - t0) * 1000);
end \$\$;" 2>&1 | sed -n 's/.*NOTICE:  ms //p'
}
ON=$(cost on)
q "alter table pgvigil.log_events disable trigger log_events_shape" >/dev/null
OFF=$(cost off)
q "alter table pgvigil.log_events enable trigger log_events_shape" >/dev/null
[[ -n "$ON" && -n "$OFF" ]] || fail "K: no timing"
echo "K: 20,000 slow events through import_logs: trigger on $ON ms, trigger off $OFF ms"
echo "PASS proof-slow"
