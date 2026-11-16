#!/usr/bin/env bash
# Proof of `pgvigil purge` on a throwaway repository database. One import_dbstats call dated 100 days
# back makes the dbstats, serverstats and iostats partitions of that month; one dated now makes this
# month's three.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#                      (the proof creates pgvigil_proof_purge_<n> there and drops it at the end)
#
# Expected: `purge -days 0` exits 2 and drops nothing (6 partitions before and after); `purge -dry-run`
# names exactly the three old partitions (dbstats_, iostats_, serverstats_ of the month 100 days back)
# and leaves 6; `purge -days 30` prints "3 partitions and rows removed" (no row-level series holds a row
# older than 30 days here) and leaves the three current-month partitions; a second run removes 0.
# Then Query Store's retention (0088): 'ok   Query Store retention: plans 1,3 | queries 1,3,4 | recommendation T1 kept,
# the rest gone' (the cases in the script). Then the whole list: no partitioned parent of the schema unnamed by purge() (or mssql_running_purge(), the day
# partitions of mssql_requests, or an hours table of pgvigil.hours_retention, 0139, which its own function drops at its
# own age); an old-month partition made for every other parent, all dropped by purge -days 30, the hours tables' kept;
# the reader holds EXECUTE on none of the eight owner-only functions: 'ok   every partitioned parent named by purge() ...'.
# Last, a name ending in no month (the 22008 fault of 2026-11-14): a plain table public.proof_purge_100017 always, and a
# TOAST table pg_toast_<six digits> ending in no month (13-99 or 00) too when the cluster's OID counter already stands
# between 100,000 and 999,000; twice - under the plan the database picks, then with the database set to hash joins and
# scans only - an old dbstats month is made again, 'purge -dry-run' must name exactly dbstats_<old> and 'purge -days 30'
# must remove it, each ending 0: 'ok   a name ending in no month (...)'. Without the month guard: 'date/time field
# value out of range' (SQLSTATE 22008) - purge() under the forced plan (box job sqltb-s2-n4-2), PurgeCandidates too
# under some plans (t-pd-p1b).
# Until the join places scripts/n4-join-lines.sql, a rel-n4 tree applies scripts/n4-wiring.patch before its build
# (`git apply scripts/n4-wiring.patch`): without it 0190's purge() and 0139's job_stats_hourly_purge() are unguarded.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
DB=pgvigil_proof_purge_$RANDOM
CFG=$(mktemp)
cleanup() { rm -f "$CFG"; psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
iid=$(q "select pgvigil.ensure_instance('proof-purge', 'onprem', '18.0', 180000, false, '{}'::text[])")
old=$(q "select to_char((now() - interval '100 days') at time zone 'utc', 'YYYYMM')")
cur=$(q "select to_char(now() at time zone 'utc', 'YYYYMM')")
[ "$old" != "$cur" ] || fail "setup: the old month equals the current one"
q "select pgvigil.import_dbstats($iid, now() - interval '100 days', '[{\"kind\":\"server\",\"checkpoints_timed\":1}]'::jsonb)" >/dev/null
q "select pgvigil.import_dbstats($iid, now(), '[{\"kind\":\"server\",\"checkpoints_timed\":2}]'::jsonb)" >/dev/null
parts() { q "select string_agg(c.relname, ',' order by c.relname) from pg_inherits i join pg_class c on c.oid=i.inhrelid join pg_class p on p.oid=i.inhparent join pg_namespace n on n.oid=p.relnamespace where n.nspname='pgvigil' and p.relname in ('dbstats','serverstats','iostats')"; }
before=$(parts)
[ "$before" = "dbstats_$old,dbstats_$cur,iostats_$old,iostats_$cur,serverstats_$old,serverstats_$cur" ] || fail "setup partitions: $before"

set +e; "$BIN" purge -config "$CFG" -days 0 >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = "2" ] || fail "purge -days 0 exited $rc, want 2"
[ "$(parts)" = "$before" ] || fail "purge -days 0 changed the partitions"

dry=$("$BIN" purge -config "$CFG" -dry-run)
echo "$dry"
[ "$dry" = "purge -days 30 would drop 3 partition(s): dbstats_$old, iostats_$old, serverstats_$old" ] || fail "dry-run text"
[ "$(parts)" = "$before" ] || fail "dry-run changed the partitions"

out=$("$BIN" purge -config "$CFG" -days 30)
echo "$out"
case "$out" in "purge -days 30: 3 partitions and rows removed in "*) ;; *) fail "purge output: $out" ;; esac
after=$(parts)
[ "$after" = "dbstats_$cur,iostats_$cur,serverstats_$cur" ] || fail "partitions after the purge: $after"
out2=$("$BIN" purge -config "$CFG" -days 30)
case "$out2" in "purge -days 30: 0 partitions and rows removed in "*) ;; *) fail "second purge output: $out2" ;; esac
# Query Store retention (0088): database qsdb has a store row (in ERROR: the collector no longer reads it), database gone
# has none; every row below is 100 days old except the one runtime row (this month). Kept: plan 1 (its runtime row),
# plan 3 (forced, its store listed), query 1 (runtime), 3 (its plan), 4 (a present recommendation of a listed store),
# recommendation T1 (present, its store listed). Gone: plan 2, the forced plan 4 of gone, queries 2, 5, 6, T2 (not
# present), T3 (gone has no store row)
o="now() - interval '100 days'"
q "insert into pgvigil.mssql_qs_store (instance_id, database_name, snapshot_at, actual_state) values ($iid, 'qsdb', now(), 'ERROR')" >/dev/null
q "select pgvigil.ensure_month_partition('mssql_qs_runtime', now())" >/dev/null
q "insert into pgvigil.mssql_qs_plan (instance_id, database_name, plan_id, query_id, is_forced, first_seen, snapshot_at) values
  ($iid, 'qsdb', 1, 1, false, $o, $o), ($iid, 'qsdb', 2, 2, false, $o, $o), ($iid, 'qsdb', 3, 3, true, $o, $o), ($iid, 'gone', 4, 6, true, $o, $o)" >/dev/null
q "insert into pgvigil.mssql_qs_query (instance_id, database_name, query_id, first_seen, snapshot_at) values
  ($iid, 'qsdb', 1, $o, $o), ($iid, 'qsdb', 2, $o, $o), ($iid, 'qsdb', 3, $o, $o), ($iid, 'qsdb', 4, $o, $o), ($iid, 'qsdb', 5, $o, $o), ($iid, 'gone', 6, $o, $o)" >/dev/null
q "insert into pgvigil.mssql_qs_runtime (instance_id, snapshot_at, interval_end, database_name, plan_id, query_id, executions) values ($iid, now(), now(), 'qsdb', 1, 1, 1)" >/dev/null
q "insert into pgvigil.mssql_qs_tuning (instance_id, database_name, rec_name, query_id, is_present, first_seen, snapshot_at) values
  ($iid, 'qsdb', 'T1', 4, true, $o, $o), ($iid, 'qsdb', 'T2', 5, false, $o, $o), ($iid, 'gone', 'T3', 6, true, $o, $o)" >/dev/null
"$BIN" purge -config "$CFG" -days 30 >/dev/null
qsleft=$(q "select coalesce((select string_agg(plan_id::text, ',' order by plan_id) from pgvigil.mssql_qs_plan where instance_id = $iid), '') || '|'
  || coalesce((select string_agg(query_id::text, ',' order by query_id) from pgvigil.mssql_qs_query where instance_id = $iid), '') || '|'
  || coalesce((select string_agg(rec_name, ',' order by rec_name) from pgvigil.mssql_qs_tuning where instance_id = $iid), '')")
[ "$qsleft" = "1,3|1,3,4|T1" ] || fail "Query Store retention: plans|queries|recommendations left '$qsleft', want '1,3|1,3,4|T1'"
echo "ok   Query Store retention: plans 1,3 | queries 1,3,4 | recommendation T1 kept, the rest gone"

# the whole list: every partitioned parent of the schema is named by purge() or mssql_running_purge() (the day
# partitions of mssql_requests), or is an hours table of pgvigil.hours_retention (0139: its own function, called from
# purge()'s last block, drops its months at its own age - purge()'s text names none of them); an old-month partition of
# every other parent is dropped by purge -days 30, an hours table's (100 days old, under its 730) is kept and one older
# than its own age dropped (purge()'s last block); the reader may execute none of the owner-only functions
have_hours=$(q "select to_regclass('pgvigil.hours_retention') is not null")
hours="select h.table_name from pgvigil.hours_retention h"; [[ $have_hours == t ]] || hours="select null::text where false"
unnamed=$(q "select coalesce(string_agg(p.relname, ',' order by p.relname), '') from pg_class p join pg_namespace n on n.oid = p.relnamespace
  where n.nspname = 'pgvigil' and p.relkind = 'p' and p.relname not in ($hours)
    and position(quote_literal(p.relname) in pg_get_functiondef('pgvigil.purge(int)'::regprocedure)) = 0
    and position(quote_literal(p.relname) in pg_get_functiondef('pgvigil.mssql_running_purge(int)'::regprocedure)) = 0")
[ -z "$unnamed" ] || fail "partitioned parents purge() does not name: $unnamed"
nhours=$(q "select count(*) from pg_class p join pg_namespace n on n.oid = p.relnamespace where n.nspname = 'pgvigil' and p.relkind = 'p' and p.relname in ($hours)")
nparents=$(q "select count(*) from pg_class p join pg_namespace n on n.oid = p.relnamespace where n.nspname = 'pgvigil' and p.relkind = 'p' and p.relname <> 'mssql_requests' and p.relname not in ($hours)")
q "select count(pgvigil.ensure_month_partition(p.relname, now() - interval '100 days')) from pg_class p join pg_namespace n on n.oid = p.relnamespace
  where n.nspname = 'pgvigil' and p.relkind = 'p' and p.relname <> 'mssql_requests'" >/dev/null
# an hours table's month older than its own age too, which purge()'s last block must drop through its function
hours_old="select null::text where false"
if [[ $have_hours == t ]]; then
  hours_old="select h.table_name || '_' || to_char((now() - make_interval(days => h.days + 40)) at time zone 'utc', 'YYYYMM') from pgvigil.hours_retention h where to_regclass('pgvigil.' || h.table_name) is not null"
  q "select count(pgvigil.ensure_month_partition(h.table_name, now() - make_interval(days => h.days + 40))) from pgvigil.hours_retention h where to_regclass('pgvigil.' || h.table_name) is not null" >/dev/null
fi
hmade=$(q "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relname in ($hours_old)")
[ "$hmade" = "$nhours" ] || fail "an hours table's month older than its own age: $hmade of $nhours made"
made=$(q "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_inherits i on i.inhrelid = c.oid join pg_class p on p.oid = i.inhparent
  where n.nspname = 'pgvigil' and c.relispartition and c.relname like '%\_$old' and p.relname not in ($hours)")
[ "$made" = "$nparents" ] || fail "old-month partitions made: $made of $nparents parents"
"$BIN" purge -config "$CFG" -days 30 >/dev/null
left=$(q "select coalesce(string_agg(c.relname, ',' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_inherits i on i.inhrelid = c.oid join pg_class p on p.oid = i.inhparent
  where n.nspname = 'pgvigil' and c.relispartition and c.relname like '%\_$old' and p.relname not in ($hours)")
[ -z "$left" ] || fail "old-month partitions purge -days 30 left: $left"
kept=$(q "select count(*) from pg_class c join pg_inherits i on i.inhrelid = c.oid join pg_class p on p.oid = i.inhparent join pg_namespace n on n.oid = p.relnamespace
  where n.nspname = 'pgvigil' and c.relname like '%\_$old' and p.relname in ($hours)")
[ "$kept" = "$nhours" ] || fail "an hours table's 100-day-old partition: $kept of $nhours kept by purge -days 30 (their own age is longer)"
hleft=$(q "select coalesce(string_agg(c.relname, ',' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relname in ($hours_old)")
[ -z "$hleft" ] || fail "an hours table's month older than its own age, left by purge -days 30: $hleft (purge()'s last block drops it through its function)"
owner_only="'apply_roles', 'purge', 'ensure_month_partition', 'mssql_running_purge', 'mssql_ensure_day_partition', 'mssql_event_partition', 'mssql_hadr_read', 'mssql_reads_purge'"
found=$(q "select count(distinct proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname in ($owner_only)")
[ "$found" = "8" ] || fail "owner-only functions found: $found of 8"
granted=$(q "select coalesce(string_agg(distinct proname, ','), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname in ($owner_only) and has_function_privilege('pgvigil_reader', p.oid, 'EXECUTE')")
[ -z "$granted" ] || fail "the reader may execute owner-only functions: $granted"
echo "ok   every partitioned parent named by purge() (or an hours table: $nhours); $nparents old-month partitions made and dropped, the hours tables' $nhours kept at 100 days and $nhours dropped past their own age; the reader holds none of the 8 owner-only functions"

# a name in pg_class ending in six digits that are no month must never reach a month parse. Always a plain table named
# so (public.proof_purge_100017: the fault's shape - under the forced plan every pg_class row meets the month test before
# the join to pg_inherits); and a TOAST table pg_toast_<six digits> ending in no month as well when the cluster's OID
# counter already stands between 100,000 and 999,000 (never pushed: a fresh cluster is below, a long-lived one past it)
q "create table public.proof_purge_100017 ()" >/dev/null
names="proof_purge_100017"
lo=$(q "select lo_create(0)"); q "select lo_unlink($lo)" >/dev/null
toast=""; t=""
if [ "$lo" -ge 100000 ] && [ "$lo" -lt 999000 ]; then
  for k in $(seq 1 40); do
    q "create table public.proof_purge_toast_$k (t text)" >/dev/null
    t=$(q "select coalesce(c.reltoastrelid::regclass::text, '') from pg_class c where c.oid = 'public.proof_purge_toast_$k'::regclass")
    t=${t#pg_toast.}
    if [[ $t =~ ^pg_toast_[0-9]{6}$ ]]; then mm=${t: -2}; if [ "$((10#$mm))" -ge 13 ] || [ "$mm" = "00" ]; then toast=$t; break; fi; fi
  done
  [ -n "$toast" ] && names="$names, $toast"
fi
# both under the plan the database picks, then under hash joins and scans only (no evaluation order is promised for a
# WHERE's tests)
plan_off="enable_nestloop enable_mergejoin enable_indexscan enable_indexonlyscan enable_bitmapscan"
res=""; bad=0
for plan in natural forced; do
  if [ "$plan" = forced ]; then for g in $plan_off; do q "alter database $DB set $g = off" >/dev/null; done; fi
  q "select pgvigil.ensure_month_partition('dbstats', now() - interval '100 days')" >/dev/null
  set +e
  dr=$("$BIN" purge -config "$CFG" -dry-run 2>&1); drc=$?
  pr=$("$BIN" purge -config "$CFG" -days 30 2>&1); prc=$?
  set -e
  dr=${dr##*$'\n'}; pr=${pr##*$'\n'}   # the last line: the answer (purge -days 30 logs its INFO line before it)
  [ "$drc" = 0 ] && [ "$dr" = "purge -days 30 would drop 1 partition(s): dbstats_$old" ] || bad=1
  [ "$prc" = 0 ] && case "$pr" in "purge -days 30: 1 partitions and rows removed in "*) true ;; *) false ;; esac || bad=1
  res="$res | $plan: purge -dry-run rc $drc: $dr ; purge -days 30 rc $prc: $pr"
done
for g in $plan_off; do q "alter database $DB reset $g" >/dev/null; done
[ "$bad" = 0 ] || fail "a name ending in no month ($names; OID counter $lo)$res"
echo "ok   a name ending in no month ($names; OID counter $lo): under the database's plan and under hash joins and scans only, purge -dry-run named dbstats_$old and purge -days 30 removed it, rc 0 each"
echo "proof-purge: OK (old month $old dropped, current month $cur kept)"
