#!/usr/bin/env bash
# Proof of the Corruption column (task 34): the log reader's corruption and plan kinds, the corruption findings and
# the opt-in amcheck collection.
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN): the proof makes its own
#               repository database there (random suffix) and drops it at the end.
#   CORR_PORT   the first of two ports for the monitored servers (default 5487; the second is the next port).
# The monitored servers are two throwaway clusters this proof makes with initdb in a temporary directory and removes
# at the end (a page is damaged on purpose, which is never done to a shared server):
#   W  data checksums on, logging_collector on, log_line_prefix '%m [%p] %q%u@%d ', auto_explain preloaded: the
#      server log reader (serverlog) reads its damage and a plan;
#   N  data checksums off (--no-data-checksums), where an index and a heap page are edited for amcheck to find.
# initdb and pg_ctl of the sandbox's major version and python3 must be on PATH. Nothing that exists before the run
# is touched.
#
# The log_events kind CHECK: 0024 re-adds log_events_kind_check without 'plan' and 'corruption', and on a fresh
# repository it runs after 0023, so a fresh install relies on the wave's join migration (0042 onward) to carry both
# kinds. Until the join, this proof applies the join's line itself when the constraint lacks them and says which path
# it took (step 0).
#
# Expected (written before the first run):
#  0. after migrate: the constraint lacks 'corruption' on the slice branch (the proof prints "join line applied by
#     the proof") or carries it on the merged tree (prints "the constraint carries plan and corruption").
#  A. the recorded lines through both parsers: go test of internal/logparse (TestCorruptionRecorded: 9 corruption
#     events and 2 plans in each of the io_method worker and sync recordings; TestCorruptionConstructed: 8 of 11
#     entries) and of internal/collect (TestCorruptionBothReaders: the CloudWatch reader and the server log reader
#     each give corruption 9, plan 2) pass.
#  B. live on W through the serverlog collection: a heap page of table hp overwritten while W is stopped, the file
#     of table gone removed; then select count(*) from hp (ERROR), select count(*) from gone (ERROR) and, with
#     auto_explain.log_min_duration = 0, select count(*) from pg_class /* <tag> */. collect serverlog: status ok;
#     log_events for W: kind corruption exactly 3 rows (classes checksum, invalid page, missing file: one each), the
#     invalid page row's statement 'select count(*) from hp'; kind plan at least 1 row whose statement holds <tag>
#     and 'Query Text'. corruption_events gives the invalid page row relation_path base/<db oid>/<relfilenode>.
#  C. the settings: on W ALTER SYSTEM SET ignore_checksum_failure = on and zero_damaged_pages = on, reload; collect
#     instance (both servers): corruption_findings for W = exactly the rows ignore_checksum_failure (critical),
#     zero_damaged_pages (critical), 'corruption in the log' (critical, value starting '3 event(s)'); no
#     data_checksums row for W (checksums on); for N the data_checksums row (warning, value off) and nothing else
#     yet. corruption_summary for W: events_24h 3, ignore_checksum_failure on, zero_damaged_pages on.
#  D. amcheck on N, database amproof_<suf> with the extension created as the cluster superuser:
#     D1 no schedule in the instance config: collect -once amcheck says 'skipped' with "opt-in per instance"; no
#        amcheck_runs row.
#     D2 schedule amcheck: 24h, the login without EXECUTE: amproof rows bt_index_check and verify_heapam 'skipped',
#        each note naming its GRANT; the postgres database's rows 'skipped' "not installed in this database".
#     D3 the two grants given: amproof bt_index_check 'ok' with checked = total = the database's count of valid
#        B-tree indexes and corrupt 0; verify_heapam 'ok' with checked = total = its count of tables, matviews and
#        TOAST tables, corrupt 0 (a clean result).
#     D4 N stopped, the max key of index ai_idx rewritten from 168496141 to 1 in its file and line pointer 1 of the
#        heap ah's block 0 overwritten; N started:
#        [first run 2026-11-09: verify_heapam 'ok' - the all-ones pointer first written decodes as LP_DEAD, which
#         verify_heapam passes over; the seed is an LP_NORMAL pointer past the page's end since, the expectation unchanged] bt_index_check 'corrupt', corrupt 1, the problem on public.ai_idx;
#        verify_heapam 'corrupt', corrupt 1, the problem on public.ah; corruption_findings for N gains
#        'amcheck bt_index_check' and 'amcheck verify_heapam' (critical).
#  E. rights: pgvigil_collector may run import_amcheck; pgvigil_reader may read corruption_findings,
#     corruption_events, corruption_summary, amcheck_runs and amcheck_latest.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
PW=${CORR_PORT:-5487}; PN=$((PW + 1))
SUF=$RANDOM; TAG=pgvcorr$SUF
REPO_DB=pgvigil_corrproof_$SUF; MON=pgvigil_corrmon_$SUF; MONPW=p$RANDOM$RANDOM; AMDB=amproof_$SUF
DIR=$(mktemp -d); CFG=$(mktemp)
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  pg_ctl -D "$DIR/w" stop -m fast -s >/dev/null 2>&1 || true
  pg_ctl -D "$DIR/n" stop -m fast -s >/dev/null 2>&1 || true
  rm -rf "$DIR" "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
command -v initdb >/dev/null && command -v pg_ctl >/dev/null && command -v python3 >/dev/null || fail "initdb, pg_ctl and python3 must be on PATH"

echo "--- A. the recorded lines through both parsers"
go test -count=1 -run 'TestCorruption' ./internal/logparse/ >/dev/null || fail "A: logparse"
go test -count=1 -run 'TestCorruptionBothReaders|TestAmcheck' ./internal/collect/ >/dev/null || fail "A: the two readers"
echo "A ok"

echo "--- the monitored servers: W on $PW (checksums on), N on $PN (checksums off)"
initdb -k -D "$DIR/w" -U postgres -A trust >/dev/null 2>&1 || fail "initdb W"
cat >> "$DIR/w/postgresql.conf" <<EOF
port = $PW
listen_addresses = 'localhost'
unix_socket_directories = ''
logging_collector = on
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'UTC'
shared_preload_libraries = 'auto_explain'
EOF
initdb --no-data-checksums -D "$DIR/n" -U postgres -A trust >/dev/null 2>&1 || fail "initdb N"
cat >> "$DIR/n/postgresql.conf" <<EOF
port = $PN
listen_addresses = 'localhost'
unix_socket_directories = ''
EOF
start() { pg_ctl -D "$DIR/$1" -l "$DIR/$1.out" -w -s start >/dev/null 2>&1 || { tail -5 "$DIR/$1.out" >&2; fail "$1 did not start"; }; }
stop() { pg_ctl -D "$DIR/$1" -w -s stop -m fast >/dev/null 2>&1 || fail "$1 did not stop"; }
start w; start n
WSU="host=localhost port=$PW user=postgres dbname=postgres sslmode=disable"
NSU="host=localhost port=$PN user=postgres dbname=postgres sslmode=disable"
w() { psql "$WSU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
n() { psql "$NSU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
na() { psql "host=localhost port=$PN user=postgres dbname=$AMDB sslmode=disable" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
w "create role $MON login password '$MONPW' in role pg_monitor"
w "grant execute on function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) to $MON"
n "create role $MON login password '$MONPW' in role pg_monitor"
export W_DSN="host=localhost port=$PW user=$MON password=$MONPW dbname=postgres sslmode=disable"
export N_DSN="host=localhost port=$PN user=$MON password=$MONPW dbname=postgres sslmode=disable"

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
config() {   # $1: the N instance's extra lines
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-corr-w-$SUF
    dsn: env:W_DSN
  - name: proof-corr-n-$SUF
    dsn: env:N_DSN
$1
EOF
}
config ""
"$BIN" migrate -config "$CFG" >/dev/null

echo "--- 0. the log_events kind CHECK"
DEF=$(q "select pg_get_constraintdef(oid) from pg_constraint where conname = 'log_events_kind_check' and conrelid = 'pgvigil.log_events'::regclass")
if [[ $DEF == *"'corruption'"* && $DEF == *"'plan'"* ]]; then
  echo "0: the constraint carries plan and corruption"
else
  q "ALTER TABLE pgvigil.log_events DROP CONSTRAINT IF EXISTS log_events_kind_check;
     ALTER TABLE pgvigil.log_events ADD CONSTRAINT log_events_kind_check
       CHECK (kind IN ('slow', 'lock_wait', 'deadlock', 'auth_fail', 'autovacuum', 'plan', 'corruption'))" >/dev/null
  echo "0: join line applied by the proof (the constraint was: $DEF)"
fi

"$BIN" collect -config "$CFG" -once instance >/dev/null || fail "collect instance"
PW_ID=$(q "select instance_id from pgvigil.instances where name='proof-corr-w-$SUF'")
PN_ID=$(q "select instance_id from pgvigil.instances where name='proof-corr-n-$SUF'")

echo "--- B. damage on W, read through the serverlog collection"
w "create table hp(id int primary key, v text); insert into hp select g, repeat('x', 50) from generate_series(1, 2000) g;
   create table gone(id int); insert into gone select generate_series(1, 10); checkpoint"
HP=$(w "select pg_relation_filepath('hp')"); GO=$(w "select pg_relation_filepath('gone')")
stop w
printf 'garbagegarbagegarbage' | dd of="$DIR/w/$HP" bs=1 seek=4000 conv=notrunc 2>/dev/null
rm "$DIR/w/$GO"
start w
psql "$WSU" -XAtq -c "select count(*) from hp" >/dev/null 2>&1 && fail "B: the damaged page read without an error"
psql "$WSU" -XAtq -c "select count(*) from gone" >/dev/null 2>&1 && fail "B: the removed file read without an error"
psql "$WSU" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<EOF
set auto_explain.log_min_duration = 0;
select count(*) from pg_class /* $TAG */;
EOF
sleep 0.5   # the logging collector writes the file
"$BIN" collect -config "$CFG" -once serverlog >/dev/null || fail "collect serverlog"
ST=$(q "select status || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$PW_ID and collection='serverlog'")
[[ $ST == "ok|" ]] || fail "B status: $ST"
CL=$(q "select string_agg(class, ',' order by class) from pgvigil.corruption_events where instance_id=$PW_ID")
[[ $CL == "checksum,invalid page,missing file" ]] || fail "B classes: $CL"
[[ $(q "select statement from pgvigil.corruption_events where instance_id=$PW_ID and class='invalid page'") == "select count(*) from hp" ]] \
  || fail "B: the invalid page's statement"
RP=$(q "select relation_path from pgvigil.corruption_events where instance_id=$PW_ID and class='invalid page'")
[[ $RP == "$HP" ]] || fail "B: relation_path $RP, want $HP"
[[ $(q "select count(*) from pgvigil.log_events where instance_id=$PW_ID and kind='plan' and statement like '%$TAG%' and statement like '%Query Text%'") -ge 1 ]] \
  || fail "B: no plan row"
echo "B ok: classes $CL; the invalid page on $RP; plan rows $(q "select count(*) from pgvigil.log_events where instance_id=$PW_ID and kind='plan'")"

echo "--- C. the settings findings"
w "alter system set ignore_checksum_failure = on"; w "alter system set zero_damaged_pages = on"; w "select pg_reload_conf()" >/dev/null
sleep 0.3
"$BIN" collect -config "$CFG" -once instance >/dev/null || fail "collect instance"
FW=$(q "select string_agg(setting || ':' || severity, ',' order by setting) from pgvigil.corruption_findings where instance_id=$PW_ID")
[[ $FW == "corruption in the log:critical,ignore_checksum_failure:critical,zero_damaged_pages:critical" ]] || fail "C W findings: $FW"
[[ $(q "select value from pgvigil.corruption_findings where instance_id=$PW_ID and setting='corruption in the log'") == "3 event(s)"* ]] \
  || fail "C: the log finding's value"
FN=$(q "select string_agg(setting || ':' || severity || ':' || value, ',' order by setting) from pgvigil.corruption_findings where instance_id=$PN_ID")
[[ $FN == "data_checksums:warning:off" ]] || fail "C N findings: $FN"
SW=$(q "select events_24h || '|' || ignore_checksum_failure || '|' || zero_damaged_pages from pgvigil.corruption_summary where instance_id=$PW_ID")
[[ $SW == "3|on|on" ]] || fail "C W summary: $SW"
echo "C ok: W $FW; N $FN"

echo "--- D. amcheck on N"
n "create database $AMDB"
na "create extension amcheck;
    create table ai(id int); insert into ai select generate_series(1, 1000); insert into ai values (168496141); create index ai_idx on ai(id);
    create table ah(id int, v text); insert into ah select g, 'row ' || g from generate_series(1, 50) g;
    checkpoint"
runs() { q "select string_agg(datname || '/' || check_name || ':' || status, ',' order by datname, check_name) from pgvigil.amcheck_latest where instance_id=$PN_ID"; }
amcollect() { "$BIN" collect -config "$CFG" -once amcheck 2>&1 || true; }

OUT=$(amcollect)
[[ $OUT == *"opt-in per instance"* ]] || fail "D1: $OUT"
[[ $(q "select count(*) from pgvigil.amcheck_runs") == 0 ]] || fail "D1: rows without a schedule"
echo "D1 ok: skipped without a schedule"

config "    schedules:
      amcheck: 24h"
amcollect >/dev/null
note() { q "select note from pgvigil.amcheck_latest where instance_id=$PN_ID and datname='$1' and check_name='$2'"; }
[[ $(runs) == "$AMDB/bt_index_check:skipped,$AMDB/verify_heapam:skipped,postgres/bt_index_check:skipped,postgres/verify_heapam:skipped" ]] \
  || fail "D2 runs: $(runs)"
[[ $(note "$AMDB" bt_index_check) == *"GRANT EXECUTE ON FUNCTION public.bt_index_check(regclass, boolean)"* ]] || fail "D2 note: $(note "$AMDB" bt_index_check)"
[[ $(note "$AMDB" verify_heapam) == *"GRANT EXECUTE ON FUNCTION public.verify_heapam("* ]] || fail "D2 note: $(note "$AMDB" verify_heapam)"
[[ $(note postgres bt_index_check) == *"not installed in this database"* ]] || fail "D2 postgres note"
echo "D2 ok: $(runs)"

na "grant execute on function bt_index_check(regclass, boolean) to $MON;
    grant execute on function verify_heapam(regclass, boolean, boolean, text, bigint, bigint) to $MON"
sleep 1   # a new run time
amcollect >/dev/null
NIDX=$(na "select count(*) from pg_index i join pg_class c on c.oid = i.indexrelid join pg_am a on a.oid = c.relam
           where a.amname = 'btree' and i.indisvalid and i.indisready and c.relpersistence <> 't'")
NTAB=$(na "select count(*) from pg_class where relkind in ('r', 'm', 't') and relpersistence <> 't'")
row() { q "select status || '|' || checked || '|' || total || '|' || corrupt from pgvigil.amcheck_latest where instance_id=$PN_ID and datname='$AMDB' and check_name='$1'"; }
[[ $(row bt_index_check) == "ok|$NIDX|$NIDX|0" ]] || fail "D3 bt_index_check: $(row bt_index_check), want ok|$NIDX|$NIDX|0"
[[ $(row verify_heapam) == "ok|$NTAB|$NTAB|0" ]] || fail "D3 verify_heapam: $(row verify_heapam), want ok|$NTAB|$NTAB|0"
echo "D3 ok: bt_index_check $(row bt_index_check); verify_heapam $(row verify_heapam)"

IDX=$(na "select pg_relation_filepath('ai_idx')"); HEAP=$(na "select pg_relation_filepath('ah')")
stop n
python3 - "$DIR/n/$IDX" "$DIR/n/$HEAP" <<'PY'
import sys
idx, heap = sys.argv[1], sys.argv[2]
b = bytearray(open(idx, 'rb').read())
key = (168496141).to_bytes(4, 'little')
hits = [i for i in range(len(b)) if b[i:i+4] == key]
if len(hits) != 1:
    sys.exit(f"the key occurs {len(hits)} times in the index file")
b[hits[0]:hits[0]+4] = (1).to_bytes(4, 'little')
open(idx, 'wb').write(b)
h = bytearray(open(heap, 'rb').read())
# line pointer 1 of block 0 (after the 24-byte page header): LP_NORMAL, offset 8190, length 40 - a tuple that runs
# past the page's end (an all-ones pointer reads as LP_DEAD, which verify_heapam passes over)
h[24:28] = (8190 | (1 << 15) | (40 << 17)).to_bytes(4, 'little')
open(heap, 'wb').write(h)
PY
start n
sleep 1
amcollect >/dev/null
prob() { q "select problems->0->>'relation' from pgvigil.amcheck_latest where instance_id=$PN_ID and datname='$AMDB' and check_name='$1'"; }
[[ $(row bt_index_check) == "corrupt|$NIDX|$NIDX|1" && $(prob bt_index_check) == "public.ai_idx" ]] \
  || fail "D4 bt_index_check: $(row bt_index_check) $(prob bt_index_check)"
[[ $(row verify_heapam) == "corrupt|$NTAB|$NTAB|1" && $(prob verify_heapam) == "public.ah" ]] \
  || fail "D4 verify_heapam: $(row verify_heapam) $(prob verify_heapam)"
FN=$(q "select string_agg(setting || ':' || severity, ',' order by setting) from pgvigil.corruption_findings where instance_id=$PN_ID")
[[ $FN == "amcheck bt_index_check:critical,amcheck verify_heapam:critical,data_checksums:warning" ]] || fail "D4 findings: $FN"
echo "D4 ok: $(q "select check_name || ': ' || (problems->0->>'message') from pgvigil.amcheck_latest where instance_id=$PN_ID and datname='$AMDB' order by check_name")"

echo "--- E. rights"
[[ $(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_amcheck(int, timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "E collector"
for v in corruption_findings corruption_events corruption_summary amcheck_runs amcheck_latest; do
  [[ $(q "select has_table_privilege('pgvigil_reader', 'pgvigil.$v', 'SELECT')") == t ]] || fail "E reader $v"
done
echo "E ok"
echo "PASS"
