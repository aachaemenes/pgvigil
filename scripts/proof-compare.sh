#!/usr/bin/env bash
# Proof of the baseline compare (migration 0054, task 57): statement_compare, statement_history and compare_findings on
# a seeded statements history in a repository database of its own.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database (a random
#                      suffix) and drops it at the end.
#
# The seed: instance X, hourly statements_delta rows (interval 3600 s) ending at T - k hours, k = 0..191, with
# T = the current hour (so the last 24 hours are k = 0..23, one day earlier k = 24..47, seven days earlier k = 168..191):
#   101 the calls regression:  1,416 calls an hour (1,432 in one, 34,000 a day) at 1 ms and 10 pages a call before the
#                              last 24 hours, then 100,000 calls an hour (2,400,000 a day), the same 1 ms and 10 pages
#   102 the pages regression:  9 calls an hour (14 in one, 221 a day) at 2 ms and 50 pages a call before, then 109 an
#                              hour (125 in one, 2,632 a day) at 900 ms and 1,300,000 (even k) or 1,600,000 (odd k) pages
#   103 flat:                  208 calls an hour (4,992 a day) at 3 ms and 20 pages a call, all 8 days
#   104 quiet:                 1 call an hour before, then 30 (720 a day: a ratio of 30 under 1,000 calls; in the
#                              view's now-aligned window its 1-day ratio stays 13 or more at any minute of the hour, so
#                              only the 1,000-call gate keeps it silent)
#   105 new:                   only in the last 24 hours, 100 calls an hour
#   106 began at the baseline's end: one 600-second delta of 600 calls ending at T-24h (the 1-day baseline's end), then
#                              3,600 calls an hour (1 a second throughout: nothing regressed)
#   instance Y: 101 and 103 for the last 24 hours only (no earlier row, no collection_log row).
#
# Expected (written before the first run):
#  A. statement_compare(X, T-24h, T), as queryid|calls|d1_status|d1_calls|d1_calls_ratio|d7_calls_ratio|d1_ppc_ratio|max_ratio_of:
#     101|2400000|ok|34000|70.59|70.59|1.00|calls vs 1 day earlier
#     102|2632|ok|221|11.91|11.91|29018.24|pages per call vs 1 day earlier   (the window's pages: 12 even hours x 109 x 1.3M
#                                                                            + 11 odd x 109 x 1.6M + k=23 125 x 1.6M
#                                                                            = 3,818,800,000 / 2,632 = 1,450,911.9 a call; / 50)
#     103|4992|ok|4992|1.00|1.00|1.00|calls vs 1 day earlier
#     104|720|ok|24|30.00|30.00|1.00|calls vs 1 day earlier
#     106|86400|partial|600||||(max_ratio NULL)   (its first delta ends in the baseline's second half: no ratio)
#     105|2400|not run|||||(max_ratio NULL)   the last row (NULL ratios sort last, by total time)
#     The order: 102 first (29,018), 101, 104, 103, 106, 105.
#  [review fold, expected before the rerun: 104 reseeded 1 -> 30 an hour (A 104|720|ok|24|30.00|...), 106 added
#   ('partial'); B, F and G below read the cache that refresh_compare_findings fills.]
#  [first run, B failed on 105: the view's window (now()-24h) is not aligned to T, so the 1-day baseline caught a sliver of
#   105's first delta (k=23) and read a ratio of thousands. The fix in 0054: a baseline counts only when a delta of the
#   statement ends inside it. Expected before the rerun: A unchanged, B as below.]
#  B. refresh_compare_findings(X) returns 2; compare_findings for X: exactly two rows, setting 'statement 101' and 'statement 102', severity warning; the flat
#     (103), the quiet (104) and the new (105) do not fire. (The view's window is now()-24h..now(), up to an hour past T:
#     its 1-day baseline then holds part of the regressed hours and its ratios are lower than A's; the two still fire on
#     the 7-day baseline, and the three do not.)
#  C. statement_compare(Y, T-24h, T): 2 rows, d1_status and d7_status 'no baseline' on both, max_ratio NULL;
#     compare_findings for Y: 0 rows.
#  D. statement_history(X, 101, T-24h, T): 192 rows (one an hour over the 8 days), the last row's step end = T with
#     100000 calls, the first = T-191h with 1416 calls; statement_history(X, 999, ...) 0 rows.
#     [second run: the first row read 1432 - the expectation was wrong, not the function: k=191 is 191 mod 24 = 23, the
#     hour the seed gives 1,432 calls. Expected now: 1432.]
#  E. statement_baseline(X, T-30d, T-29d) = 'no baseline'; with one ok 'statements' collection_log row in that window,
#     'ok'.
#  F. the cache rows aged to 3 hours: compare_findings for X reads 0 rows (a stale refresh fires nothing).
#  G. the cache of X emptied, import_session_sets(X, now(), a state-only payload): the cache holds 2 rows again; emptied
#     again, import_session_sets(X, now() - 3 hours, ...): 0 rows (a historical import does not refresh).
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_cmpproof_$SUF
CFG=$(mktemp)
cleanup() {
  rm -f "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-compare-unused-$SUF
    dsn: env:PGVIGIL_REPO_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null

T=$(q "select date_trunc('hour', now())")
x=$(q "insert into pgvigil.instances (name, platform) values ('proof-compare-x-$SUF', 'onprem') returning instance_id" | head -1)
y=$(q "insert into pgvigil.instances (name, platform) values ('proof-compare-y-$SUF', 'onprem') returning instance_id" | head -1)
q "select pgvigil.ensure_month_partition('statements_delta', '$T'::timestamptz - make_interval(hours => h))
     from generate_series(0, 200, 24) h" >/dev/null

# seed(instance, queryid, k, calls, mean_ms, pages_per_call): one hourly delta ending at T - k hours
q "create function pg_temp.seed(i int, qid bigint, k int, c bigint, ms float8, ppc float8) returns void language sql as \$\$
     insert into pgvigil.statements_delta (instance_id, snapshot_at, interval_secs, dbid, datname, userid, usename, queryid,
                                           toplevel, calls, total_exec_ms, shared_blks_hit, shared_blks_read)
     values (i, '$T'::timestamptz - make_interval(hours => k), 3600, 5, 'app', 10, 'app_user', qid, true,
             c, c * ms, (c * ppc * 0.8)::bigint, (c * ppc)::bigint - (c * ppc * 0.8)::bigint) \$\$;
   select pg_temp.seed($x, 101, k, case when k < 24 then 100000 when k % 24 = 23 then 1432 else 1416 end, 1, 10)
     from generate_series(0, 191) k;
   select pg_temp.seed($x, 102, k, case when k < 24 then (case when k = 23 then 125 else 109 end) when k % 24 = 23 then 14 else 9 end,
                       case when k < 24 then 900 else 2 end,
                       case when k >= 24 then 50 when k % 2 = 0 then 1300000 else 1600000 end)
     from generate_series(0, 191) k;
   select pg_temp.seed($x, 103, k, 208, 3, 20) from generate_series(0, 191) k;
   select pg_temp.seed($x, 104, k, case when k < 24 then 30 else 1 end, 1, 5) from generate_series(0, 191) k;
   select pg_temp.seed($x, 105, k, 100, 1, 5) from generate_series(0, 23) k;
   select pg_temp.seed($x, 106, k, 3600, 1, 5) from generate_series(0, 23) k;
   insert into pgvigil.statements_delta (instance_id, snapshot_at, interval_secs, dbid, datname, userid, usename, queryid,
                                         toplevel, calls, total_exec_ms, shared_blks_hit, shared_blks_read)
   values ($x, '$T'::timestamptz - interval '24 hours', 600, 5, 'app', 10, 'app_user', 106, true, 600, 600, 2400, 600);
   select pg_temp.seed($y, 101, k, 100000, 1, 10) from generate_series(0, 23) k;
   select pg_temp.seed($y, 103, k, 208, 3, 20) from generate_series(0, 23) k;
   insert into pgvigil.statement_text (instance_id, queryid, dbid, first_seen, last_seen, query)
   select $x, qid, 5, now(), now(), 'select proof_compare_' || qid from unnest(array[101, 102, 103, 104, 105, 106]) qid" >/dev/null

echo "--- A. statement_compare on X"
A=$(q "select queryid || '|' || round(calls::numeric) || '|' || d1_status || '|' || coalesce(round(d1_calls::numeric)::text, '') || '|'
              || coalesce(round(d1_calls_ratio::numeric, 2)::text, '') || '|' || coalesce(round(d7_calls_ratio::numeric, 2)::text, '') || '|'
              || coalesce(round(d1_ppc_ratio::numeric, 2)::text, '') || '|' || coalesce(max_ratio_of, '(max_ratio NULL)')
         from pgvigil.statement_compare($x, '$T'::timestamptz - interval '1 day', '$T')")
echo "$A"
order=$(echo "$A" | cut -d'|' -f1 | paste -sd' ')
[[ $order == "102 101 104 103 106 105" ]] || fail "A: the order is '$order', not '102 101 104 103 106 105'"
grep -qx '101|2400000|ok|34000|70.59|70.59|1.00|calls vs 1 day earlier' <<<"$A" || fail "A: the calls regression row"
grep -qE '^102\|2632\|ok\|221\|11\.91\|11\.91\|29018\.24\|pages per call vs 1 day earlier$' <<<"$A" || fail "A: the pages regression row"
grep -qx '103|4992|ok|4992|1.00|1.00|1.00|calls vs 1 day earlier' <<<"$A" || fail "A: the flat row"
grep -qx '104|720|ok|24|30.00|30.00|1.00|calls vs 1 day earlier' <<<"$A" || fail "A: the quiet row"
grep -qx '106|86400|partial|600||||(max_ratio NULL)' <<<"$A" || fail "A: the partial-baseline row"
grep -qx '105|2400|not run|||||(max_ratio NULL)' <<<"$A" || fail "A: the new statement's row"
d7=$(q "select string_agg(d7_status, ',' order by queryid) from pgvigil.statement_compare($x, '$T'::timestamptz - interval '1 day', '$T')")
[[ $d7 == "ok,ok,ok,ok,not run,not run" ]] || fail "A: d7_status is '$d7'"

echo "--- B. compare_findings on X"
nref=$(q "select pgvigil.refresh_compare_findings($x)")
[[ $nref == 2 ]] || fail "B: refresh_compare_findings kept $nref rows, not 2"
B=$(q "select severity || '|' || setting from pgvigil.compare_findings where instance_id = $x order by setting")
echo "$B"
[[ $B == $'warning|statement 101\nwarning|statement 102' ]] || fail "B: compare_findings on X is not exactly 101 and 102"
q "select value || ' :: ' || detail from pgvigil.compare_findings where instance_id = $x order by setting"

echo "--- C. no baseline (Y)"
C=$(q "select queryid || '|' || d1_status || '|' || d7_status || '|' || coalesce(max_ratio::text, 'NULL')
         from pgvigil.statement_compare($y, '$T'::timestamptz - interval '1 day', '$T') order by queryid")
echo "$C"
[[ $C == $'101|no baseline|no baseline|NULL\n103|no baseline|no baseline|NULL' ]] || fail "C: the no-baseline rows"
[[ $(q "select count(*) from pgvigil.compare_findings where instance_id = $y") == 0 ]] || fail "C: Y fired a finding"

echo "--- D. statement_history"
D=$(q "select count(*) || '|' || (max(snapshot_at) = '$T'::timestamptz) || '|' || (array_agg(calls order by snapshot_at desc))[1]
              || '|' || (min(snapshot_at) = '$T'::timestamptz - interval '191 hours') || '|' || (array_agg(calls order by snapshot_at))[1]
         from pgvigil.statement_history($x, 101, '$T'::timestamptz - interval '1 day', '$T')")
echo "$D"
[[ $D == "192|true|100000|true|1432" ]] || fail "D: the history of 101 is '$D'"
[[ $(q "select count(*) from pgvigil.statement_history($x, 999, '$T'::timestamptz - interval '1 day', '$T')") == 0 ]] || fail "D: a history for an unknown queryid"

echo "--- E. statement_baseline from collection_log"
E1=$(q "select pgvigil.statement_baseline($x, '$T'::timestamptz - interval '30 days', '$T'::timestamptz - interval '29 days')")
q "insert into pgvigil.collection_log (instance_id, collection, snapshot_at, status)
   values ($x, 'statements', '$T'::timestamptz - interval '29 days 12 hours', 'ok')" >/dev/null
E2=$(q "select pgvigil.statement_baseline($x, '$T'::timestamptz - interval '30 days', '$T'::timestamptz - interval '29 days')")
echo "$E1 -> $E2"
[[ $E1 == "no baseline" && $E2 == "ok" ]] || fail "E: statement_baseline read '$E1' then '$E2'"

echo "--- F. a stale cache"
q "update pgvigil.compare_findings_cache set computed_at = now() - interval '3 hours' where instance_id = $x" >/dev/null
[[ $(q "select count(*) from pgvigil.compare_findings where instance_id = $x") == 0 ]] || fail "F: a stale cache fired"

echo "--- G. the hourly session_sets import refreshes the cache"
q "delete from pgvigil.compare_findings_cache where instance_id = $x" >/dev/null
q "select pgvigil.import_session_sets($x, now(), '[{\"kind\": \"state\", \"status\": \"ok\", \"track_utility\": \"on\"}]')" >/dev/null
G1=$(q "select count(*) from pgvigil.compare_findings where instance_id = $x")
q "delete from pgvigil.compare_findings_cache where instance_id = $x" >/dev/null
q "select pgvigil.import_session_sets($x, now() - interval '3 hours', '[{\"kind\": \"state\", \"status\": \"ok\", \"track_utility\": \"on\"}]')" >/dev/null
G2=$(q "select count(*) from pgvigil.compare_findings_cache where instance_id = $x")
echo "current import: $G1 finding(s); historical import: $G2 cache row(s)"
[[ $G1 == 2 && $G2 == 0 ]] || fail "G: the import refresh read $G1 then $G2"

echo "PASS: proof-compare (A ratios, order, partial; B the two regressions fire and the flat, quiet, new and partial do not; C no baseline; D history; E collection_log baseline; F stale cache; G the session_sets import refreshes)"
