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
#  E. the views on the collected rows (instance P): slow_top(P, seed - 1 min, now, 0, 'count') lists the -a shape
#     first with statements 3 (the three literals are one shape), slow_top(..., 'total') lists the -b shape first;
#     slow_top(P, ..., 1000, ...) has only the -b shape; slow_events has 5 rows for P, reader 'server log'.
#  F. a seeded window on a scratch instance S (import_logs as the owner, times in UTC, 3 days before today 00:00 UTC):
#       day 1: 500 ms and 2,000 ms of "SELECT * FROM t WHERE id = 1" / "... id = 2" (one shape)
#       day 2: 15,000 ms of "UPDATE t SET v = 'x' WHERE id = 7", 70,000 ms and 70,000 ms of "SELECT pg_sleep(70)"
#       and a statement_text row (queryid 4242) "SELECT * FROM t WHERE id = $1" for S
#     slow_histogram(S, day1, day3, 0, 'UTC') = day1 2 statements (under_1s 1, s1_to_10 1, total 2,500, max 2,000),
#     day2 3 statements (s10_to_60 1, over_60s 2, total 155,000, max 70,000); with p_min_ms 1000: day1 1, day2 3;
#     with p_tz 'Not/AZone': the UTC days again.
#     slow_top(S, ..., 0, 'count'): first the SELECT * shape (2, total 2,500, mean 1,250, queryid 4242), then
#     pg_sleep (2, 140,000); 'total': pg_sleep first (140,000), the UPDATE (15,000) second, SELECT * third;
#     [first run 2026-11-09: the count list came pg_sleep, SELECT *, UPDATE - the expectation missed that the two
#      shapes tie at 2, and slow_top breaks a tie by total time (its ORDER BY); graded against that order since]
#     slow_top(NULL, ...) (the fleet) includes the rows of S and of P.
#  G. rights: pgvigil_collector may run import_serverlog; pgvigil_reader may run slow_top and slow_histogram and read
#     slow_events and slow_sources; slow_sources lists P's serverlog reader 'skipped' with its reason.
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

echo "--- E. the views on the collected rows"
W="'$SEED'::timestamptz - interval '1 minute', now()"
top1() { q "select statements || '|' || (example like '%$TAG-$1%') from pgvigil.slow_top($P, $W, $2, '$3') limit 1"; }
[[ $(top1 a 0 count) == "3|true" ]] || fail "E top by count: $(q "select statements, example from pgvigil.slow_top($P, $W, 0, 'count')")"
[[ $(top1 b 0 total) == "1|true" ]] || fail "E top by total"
[[ $(q "select count(*) || '|' || bool_and(example like '%$TAG-b%') from pgvigil.slow_top($P, $W, 1000, 'count')") == "1|true" ]] || fail "E threshold 1000"
[[ $(q "select count(*) || '|' || min(reader) from pgvigil.slow_events where instance_id=$P") == "5|server log" ]] || fail "E slow_events"
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
T=$(q "select string_agg(concat_ws(',', left(example, 13), statements, total_ms, mean_ms, queryid), ' | ') from pgvigil.slow_top($S, $SW, 0, 'count')")
[[ "$T" == "SELECT pg_sle,2,140000,70000 | SELECT * FROM,2,2500,1250,4242 | UPDATE t SET ,1,15000,15000" ]] || fail "F top by count: $T"
T=$(q "select string_agg(left(example, 6), ',') from pgvigil.slow_top($S, $SW, 0, 'total')")
[[ "$T" == "SELECT,UPDATE,SELECT" ]] || fail "F top by total: $T"
[[ $(q "select string_agg(left(example, 13), ',') from pgvigil.slow_top($S, $SW, 0, 'total')") == "SELECT pg_sle,UPDATE t SET ,SELECT * FROM" ]] || fail "F top by total order"
[[ $(q "select count(distinct instance_id) from pgvigil.slow_top(NULL, ('$D0'::timestamp at time zone 'UTC'), now(), 0, 'count', 500) where instance_id in ($S, $P)") == 2 ]] \
  || fail "F: the fleet read misses an instance"
echo "F ok"

echo "--- G. rights and the sources view"
[[ $(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_serverlog(int, timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "G collector"
[[ $(q "select has_function_privilege('pgvigil_reader', 'pgvigil.slow_top(int, timestamptz, timestamptz, float8, text, int)', 'EXECUTE')
          and has_function_privilege('pgvigil_reader', 'pgvigil.slow_histogram(int, timestamptz, timestamptz, float8, text)', 'EXECUTE')
          and has_table_privilege('pgvigil_reader', 'pgvigil.slow_events', 'SELECT') and has_table_privilege('pgvigil_reader', 'pgvigil.slow_sources', 'SELECT')") == t ]] || fail "G reader"
[[ $(q "select reader || '|' || status || '|' || (note like '%$GRANT_TXT%') from pgvigil.slow_sources where instance_id=$P") == "serverlog|skipped|true" ]] \
  || fail "G sources: $(q "select row(s.*) from pgvigil.slow_sources s where instance_id=$P")"
echo "G ok"
echo "PASS proof-slow"
