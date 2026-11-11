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
# Then the whole list: no partitioned parent of the schema unnamed by purge() (or mssql_running_purge(), the day
# partitions of mssql_requests); an old-month partition made for every other parent, all dropped by purge -days 30; the
# reader holds EXECUTE on none of the eight owner-only functions: 'ok   every partitioned parent named by purge(); ...'.
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
# the whole list: every partitioned parent of the schema is named by purge() or mssql_running_purge() (the day
# partitions of mssql_requests); an old-month partition of every other parent is dropped by purge -days 30; the
# reader may execute none of the owner-only functions
unnamed=$(q "select coalesce(string_agg(p.relname, ',' order by p.relname), '') from pg_class p join pg_namespace n on n.oid = p.relnamespace
  where n.nspname = 'pgvigil' and p.relkind = 'p'
    and position(quote_literal(p.relname) in pg_get_functiondef('pgvigil.purge(int)'::regprocedure)) = 0
    and position(quote_literal(p.relname) in pg_get_functiondef('pgvigil.mssql_running_purge(int)'::regprocedure)) = 0")
[ -z "$unnamed" ] || fail "partitioned parents purge() does not name: $unnamed"
nparents=$(q "select count(*) from pg_class p join pg_namespace n on n.oid = p.relnamespace where n.nspname = 'pgvigil' and p.relkind = 'p' and p.relname <> 'mssql_requests'")
q "select count(pgvigil.ensure_month_partition(p.relname, now() - interval '100 days')) from pg_class p join pg_namespace n on n.oid = p.relnamespace
  where n.nspname = 'pgvigil' and p.relkind = 'p' and p.relname <> 'mssql_requests'" >/dev/null
made=$(q "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relispartition and c.relname like '%\_$old'")
[ "$made" = "$nparents" ] || fail "old-month partitions made: $made of $nparents parents"
"$BIN" purge -config "$CFG" -days 30 >/dev/null
left=$(q "select coalesce(string_agg(c.relname, ',' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relispartition and c.relname like '%\_$old'")
[ -z "$left" ] || fail "old-month partitions purge -days 30 left: $left"
owner_only="'apply_roles', 'purge', 'ensure_month_partition', 'mssql_running_purge', 'mssql_ensure_day_partition', 'mssql_event_partition', 'mssql_hadr_read', 'mssql_reads_purge'"
found=$(q "select count(distinct proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname in ($owner_only)")
[ "$found" = "8" ] || fail "owner-only functions found: $found of 8"
granted=$(q "select coalesce(string_agg(distinct proname, ','), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname in ($owner_only) and has_function_privilege('pgvigil_reader', p.oid, 'EXECUTE')")
[ -z "$granted" ] || fail "the reader may execute owner-only functions: $granted"
echo "ok   every partitioned parent named by purge(); $nparents old-month partitions made and dropped; the reader holds none of the 8 owner-only functions"
echo "proof-purge: OK (old month $old dropped, current month $cur kept)"
